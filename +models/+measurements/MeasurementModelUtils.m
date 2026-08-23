classdef MeasurementModelUtils
    % MeasurementModelUtils  Static utility helpers for measurement builders.
    %
    % Extracted from MeasurementModel.m.
    % All physics preserved exactly — pure structural refactor.
    %
    % These methods are called by: CodeMeasurementBuilder, CodeJacobianBuilder,
    % CarrierMeasurementBuilder, DopplerMeasurementBuilder,
    % PseudorangeModelOnlyBuilder, CarrierModelOnlyBuilder.

    methods (Static)

        function [z_isl, h_isl, H_isl] = computeISLMeasurements(asset_rx, asset_tx, ~, ~)
            % computeISLMeasurements  Legacy compatibility helper, not the active ISL router.
            %
            % This helper intentionally returns empty z/h/H so old callers keep zero
            % EKF effect. Active ISL layers are built elsewhere:
            %   * revgnss.ISLMeasurementBuilder: one-way secondary-to-primary ISL rows
            %   * revgnss.TwoWayISLMeasurementBuilder: coherent four-event
            %     transponded PN two-way code range rows
            %   * revgnss.InterSatelliteTimeTransferBuilder: processed reciprocal
            %     inter-satellite clock-difference rows
            %   * revgnss.SwarmRelativeSolver: synthetic two-way-ISL formation shape and
            %     legacy relative-clock post-processing
            %
            % Use those routed builders/solver for supported ISL physics instead of this
            % legacy no-row hook.
            z_isl = [];
            h_isl = [];
            H_isl = zeros(0, 0);
        end

        function need = needsFiniteDiffH_(cfg)
            % needsFiniteDiffH_  True when any model-side position-affecting correction is on.
            %
            % Sagnac and Shapiro add explicit terms to dh/dr.  PCO and PCV change the
            % effective antenna positions used in the range computation.
            % Tower survey offsets do NOT require FD (they shift the baseline h but the
            % Jacobian structure d(rho)/d(r) = u' is unchanged).
            need = false;
            if isfield(cfg,'estimator') && isfield(cfg.estimator,'forceFiniteDifferenceH') && ...
                    cfg.estimator.forceFiniteDifferenceH
                need = true; return;
            end
            if isfield(cfg,'physics')
                if isfield(cfg.physics,'sagnac') && isfield(cfg.physics.sagnac,'model') && ...
                        cfg.physics.sagnac.model.enable
                    need = true; return;
                end
                if isfield(cfg.physics,'relativity') && ...
                        isfield(cfg.physics.relativity,'shapiro') && ...
                        isfield(cfg.physics.relativity.shapiro,'model') && ...
                        cfg.physics.relativity.shapiro.model.enable
                    need = true; return;
                end
            end
            if isfield(cfg,'effects')
                if isfield(cfg.effects,'antennaPCO') && ...
                        isfield(cfg.effects.antennaPCO,'model') && ...
                        cfg.effects.antennaPCO.model.enable
                    need = true; return;
                end
                if isfield(cfg.effects,'antennaPCV') && ...
                        isfield(cfg.effects.antennaPCV,'model') && ...
                        cfg.effects.antennaPCV.model.enable
                    need = true; return;
                end
                % Iterative light-time rotates the tower position by
                % omega_E*tau; the geometric Jacobian dρ/dr = u' is then wrong.
                % Use finite-difference H when iterative light-time is active.
                if isfield(cfg.effects,'lightTime') && ...
                        isfield(cfg.effects.lightTime,'model') && ...
                        strcmp(cfg.effects.lightTime.model,'iterative')
                    need = true; return;
                end
            end
        end

        function r_twr = towerPositionEcef(cfg, tower, towerIdx, side, t_s)
            % towerPositionEcef  Tower ECEF with optional static survey offset, plus (on the
            %   TRUTH side, when t_s is supplied) the gated time-varying truth-only
            %   displacements (R-8): solid-Earth tide + uncorrected EOP. Both default OFF ->
            %   zero displacement -> byte-identical to the 4-arg call. t_s omitted -> no
            %   time-varying term (the existing model/golden path is unchanged).
            if nargin < 5; t_s = []; end
            r_twr = tower.getAntennaPositionECEF();

            % Static survey offset (existing behaviour).
            if isfield(cfg,'effects') && isfield(cfg.effects,'towerSurvey')
                ts = cfg.effects.towerSurvey;
                if isfield(ts, side) && ts.(side).enable && ...
                        towerIdx <= numel(cfg.towers) && isfield(cfg.towers(towerIdx),'surveyError_ENU_m')
                    enu_err = cfg.towers(towerIdx).surveyError_ENU_m;
                    r_twr = r_twr + models.frames.GeometryUtils.enu2ecef_vector( ...
                        tower.lat_rad, tower.lon_rad, enu_err);
                end
            end

            % Truth-only time-varying displacements (R-8): solid-Earth tide + EOP. Gated
            % (both default off -> zero) and applied only on the truth side with a time stamp.
            if strcmpi(side,'truth') && ~isempty(t_s)
                r_twr = r_twr ...
                    + models.frames.SolidEarthTide.towerDisplacement(r_twr, t_s, cfg) ...
                    + models.frames.TruthEarthOrientation.towerDisplacement(r_twr, t_s, cfg);
            elseif strcmpi(side,'model')
                % Estimator-side EOP correction (cfg.frames.eopModel, default off). The
                % residual geometry error is (phi_truth - phi_model) x r_tower, so this
                % is the honest fix for the polar-motion cross-track error rather than
                % switching the truth off. t_s may be empty on some model-side callers;
                % displacementFor_ then treats it as 0, which is exact for polar motion
                % (time-independent) and drops only the UT1 spin term (~1 mm at 3600 s).
                r_twr = r_twr ...
                    + models.frames.TruthEarthOrientation.towerDisplacementModel(r_twr, t_s, cfg);
            end
        end

        function kind = zwdMappingKind(cfg)
            % zwdMappingKind  Return the configured ZWD troposphere mapping kind.
            %
            % Reads cfg.effects.troposphere.mappingModel (preferred) or
            % cfg.errors.troposphere.mappingModel (legacy path).
            % Defaults to 'simple'. Valid values: 'simple' | 'continuedFraction'
            kind = 'simple';
            if isfield(cfg,'effects') && isfield(cfg.effects,'troposphere') && ...
                    isfield(cfg.effects.troposphere,'mappingModel')
                kind = cfg.effects.troposphere.mappingModel;
            elseif isfield(cfg,'errors') && isfield(cfg.errors,'troposphere') && ...
                    isfield(cfg.errors.troposphere,'mappingModel')
                kind = cfg.errors.troposphere.mappingModel;
            end
        end

        function rho = modelRangeOnly(cfg, towers, ti, ai, r_cm, euler, leverArms_model)
            % modelRangeOnly  Model geometric range for FD Jacobian.
            %
            % Includes model-side corrections (Sagnac, Shapiro, PCV) but NOT
            % clock terms or ErrorChain corrections (constants w.r.t. position/attitude).
            lever = leverArms_model(:, ai);
            r_ant = revgnss.AttitudeKinematics.applyLeverArm(r_cm, euler, lever);
            r_twr = models.measurements.MeasurementModelUtils.towerPositionEcef(cfg, towers{ti}, ti, 'model');
            if isfield(cfg,'effects') && isfield(cfg.effects,'antennaPCO')
                pco = cfg.effects.antennaPCO;
                if isfield(pco,'model') && pco.model.enable
                    tOff = pco.towerOffset_enu_m(:);
                    R_ENU = models.frames.GeometryUtils.enu2ecef(towers{ti}.lat_rad, towers{ti}.lon_rad);
                    r_twr = r_twr + R_ENU * tOff;
                end
            end
            elv = models.frames.GeometryUtils.elevationAngle(r_twr, r_ant);
            rho = models.corrections.RangeCorrections.correctedPseudorange(r_ant, r_twr, cfg, 'model', elv);
        end

        function sigma = codeSignalSigma(sigCfg, elv, cfg, zwd_m)
            % codeSignalSigma  Per-signal code noise sigma at given elevation.
            %
            % zwd_m (optional) is the zenith wet delay [m] of the tower this row belongs
            % to, used only by the 'cn0' model to scale gaseous absorption's water-vapour
            % column to this site's humidity. Omit it and the frozen table's reference
            % humidity is assumed instead.
            if nargin < 4; zwd_m = []; end
            elvFloor  = revgnss.Constants.ELEVATION_FLOOR_RAD;
            sigma0    = sigCfg.codeSigma0_m;
            codeModel = 'constant';
            if isfield(cfg,'measurements') && isfield(cfg.measurements,'codeNoise') && ...
                    isfield(cfg.measurements.codeNoise,'model')
                codeModel = cfg.measurements.codeNoise.model;
            end
            switch lower(codeModel)
                case 'constant'
                    sigma = sigma0;
                case 'elevation'
                    p = 1.0;
                    if isfield(cfg,'measurements') && ...
                            isfield(cfg.measurements,'codeNoise') && ...
                            isfield(cfg.measurements.codeNoise,'elevationExponent')
                        p = cfg.measurements.codeNoise.elevationExponent;
                    end
                    mapping = 1 / max(sin(elv), sin(elvFloor));
                    sigma   = sigma0 * mapping^p;
                case 'cn0'
                    % Delegates to the ONE shared C/N0 implementation -- see cn0CodeSigma.
                    % This branch and ErrorChain.computeCodeSigmaVec_ used to carry two
                    % copies of the same arithmetic, which had already drifted (this one
                    % floors the elevation, that one does not).
                    f_Hz = [];
                    if isstruct(sigCfg) && isfield(sigCfg,'frequency_Hz')
                        f_Hz = sigCfg.frequency_Hz;
                    end
                    elC   = max(elv, elvFloor);
                    sigma = models.measurements.MeasurementModelUtils.cn0CodeSigma( ...
                                sigma0, elC, cfg, f_Hz, zwd_m);
                otherwise
                    sigma = sigma0;
            end
        end

        function [sigma, cn0_dBHz, A_gas_dB] = cn0CodeSigma(sigma0_m, elevation_rad, cfg, f_Hz, zwd_m)
            % cn0CodeSigma  Code sigma from a C/N0 link model. THE single implementation.
            %
            %   C/N0  = base_dBHz + elevationGain_dB*sin(el) - A_gas(f, el)
            %   sigma = sigma0_m * 10^(-(C/N0 - 45)/20)
            %
            % sigma0_m is the sigma at 45 dB-Hz, so a better link (more gain, lower system
            % temperature, less absorption) LOWERS the code noise and high-elevation links
            % are favoured over low ones.
            %
            % WHY THIS IS SHARED. Two call sites computed this independently --
            % codeSignalSigma above and ErrorChain.computeCodeSigmaVec_ -- and they had
            % ALREADY DRIFTED before absorption was ever added. Any new term would have had
            % to be written twice and would eventually have been written differently.
            %
            % ⚠ elevation_rad is used AS GIVEN. The caller decides whether to floor it,
            % because the two callers genuinely differ: codeSignalSigma passes
            % max(elv, ELEVATION_FLOOR_RAD) and ErrorChain passes the raw elevation. That
            % difference is PRESERVED here rather than silently unified, because unifying
            % it would move results below the floor elevation. It is unreachable under the
            % golden's 10 deg mask, so it is a latent inconsistency, not a live one.
            %
            % sigma0_m also differs by caller by design: per-signal codeSigma0_m in one,
            % cn0.sigmaAt45dBHz_m in the other. It is therefore an ARGUMENT, not a lookup.
            %
            % ABSORPTION is gated OFF by default and contributes exactly 0 dB when off, so
            % goldens are bit-identical. f_Hz may be empty, in which case the primary
            % signal's frequency is resolved from cfg.
            %
            % zwd_m is THIS TOWER's zenith wet delay [m], from
            % EnvironmentModel.zenithWetDelay_m. It scales the frozen table's water-vapour
            % column so absorption and the troposphere describe ONE atmosphere rather than
            % two. Empty means "assume the table's own reference humidity", which is only
            % right if the run happens to use P.835's 7.5 g/m^3 -- it does not by default,
            % so callers that can supply it should.
            if nargin < 4; f_Hz  = []; end
            if nargin < 5; zwd_m = []; end

            base_dBHz = 45; elevGain_dB = 6;
            if isfield(cfg,'measurements') && isfield(cfg.measurements,'codeNoise') && ...
                    isfield(cfg.measurements.codeNoise,'cn0')
                cn0c = cfg.measurements.codeNoise.cn0;
                if isfield(cn0c,'base_dBHz');        base_dBHz   = cn0c.base_dBHz;        end
                if isfield(cn0c,'elevationGain_dB'); elevGain_dB = cn0c.elevationGain_dB; end
            end

            A_gas_dB = models.measurements.MeasurementModelUtils.gaseousAbsorption_( ...
                           cfg, elevation_rad, f_Hz, zwd_m);

            cn0_dBHz = base_dBHz + elevGain_dB * sin(elevation_rad) - A_gas_dB;
            sigma    = sigma0_m * 10^(-(cn0_dBHz - 45)/20);
        end

        function A_dB = gaseousAbsorption_(cfg, elevation_rad, f_Hz, zwd_m)
            % gaseousAbsorption_  ITU-R P.676 slant absorption [dB], or exactly 0 when off.
            %
            % Returns a HARD ZERO unless cfg.atmosphere.gaseousAbsorption.enable is true,
            % so every existing result is bit-identical and the gate cannot leak. Nothing
            % below this line runs in the default configuration -- not even the frequency
            % resolution, which would otherwise error on the reduced cfg structs some unit
            % tests build.
            A_dB = 0;

            if ~isfield(cfg,'atmosphere') || ~isfield(cfg.atmosphere,'gaseousAbsorption')
                return;
            end
            ga = cfg.atmosphere.gaseousAbsorption;
            if ~isfield(ga,'enable') || ~ga.enable
                return;
            end

            if isempty(f_Hz)
                f_Hz = revgnss.SignalUtils.frequency(cfg, revgnss.SignalUtils.primaryName(cfg));
            end

            opts = struct();
            if isfield(ga,'mappingKind') && ~isempty(ga.mappingKind)
                opts.mappingKind = ga.mappingKind;
            end
            % PER-TOWER WATER VAPOUR. The frozen table's wet column is scaled by this
            % tower's own ZWD over the table's reference, so absorption and the troposphere
            % share ONE atmosphere and one humidity per site. Without it the wet column
            % silently assumes P.835's 7.5 g/m^3, which the repo's default RH = 0.50 is 22%
            % drier than -- a ~18% overstatement of total absorption at 24.125 GHz.
            % Omitted only when the caller genuinely has no tower context.
            if ~isempty(zwd_m)
                opts.ZWD_m = zwd_m;
            end
            A_dB = models.atmosphere.GaseousAbsorption.slantAttenuation_dB( ...
                       f_Hz, elevation_rad, opts);
        end

        function d = rxCodeBiasModel(cfg)
            % rxCodeBiasModel  Receiver code hardware-delay model correction [m].
            %
            % Returns 0 for 'off', 'absorbedInReceiverClock', and 'notImplemented'.
            % Returns cfg.hardware.rxCodeBias.fixedValue_m for 'fixed' and
            % 'externalCalibration' modes.
            d = 0;
            if ~isfield(cfg,'hardware') || ~isfield(cfg.hardware,'rxCodeBias')
                return;
            end
            rxcb = cfg.hardware.rxCodeBias;
            if ~isfield(rxcb,'mode'); return; end
            switch rxcb.mode
                case {'fixed','externalCalibration'}
                    if isfield(rxcb,'fixedValue_m') && ~isnan(rxcb.fixedValue_m)
                        d = rxcb.fixedValue_m;
                    end
                otherwise
                    d = 0;
            end
        end

        function [z_out, R_out, noiseComp] = correlatedNoise(cfg, rngCorr, z_in, R_diag, twr_list, M)
            % correlatedNoise  Apply correlated truth noise and build full R matrix.
            %
            % If cfg.effects.correlatedNoise.enable=false, returns z unchanged and
            % R = diag(R_diag) with zero noiseComp arrays.
            noiseComp.common_m      = zeros(M,1);
            noiseComp.sameTower_m   = zeros(M,1);
            noiseComp.independent_m = zeros(M,1);
            z_out = z_in;
            if ~isfield(cfg,'effects') || ~isfield(cfg.effects,'correlatedNoise') || ...
                    ~cfg.effects.correlatedNoise.enable
                R_out = diag(R_diag);
                return
            end
            cn  = cfg.effects.correlatedNoise;
            rng = rngCorr;
            if cn.commonModeSigma_m > 0
                common = cn.commonModeSigma_m * randn(rng, 1, 1);
                noiseComp.common_m = common * ones(M,1);
                z_out = z_out + noiseComp.common_m;
            end
            if cn.sameTowerSigma_m > 0
                uniqTwrs = unique(twr_list);
                for k = 1:numel(uniqTwrs)
                    tNoise = cn.sameTowerSigma_m * randn(rng, 1, 1);
                    mask = (twr_list == uniqTwrs(k));
                    noiseComp.sameTower_m(mask) = tNoise;
                    z_out(mask) = z_out(mask) + tNoise;
                end
            end
            if cn.independentSigma_m > 0
                noiseComp.independent_m = cn.independentSigma_m * randn(rng, M, 1);
                z_out = z_out + noiseComp.independent_m;
            end
            R_out = diag(R_diag + cn.independentSigma_m^2 * ones(M,1));
            R_out = R_out + cn.commonModeSigma_m^2 * ones(M,M);
            if cn.sameTowerSigma_m > 0
                uniqTwrs = unique(twr_list);
                for k = 1:numel(uniqTwrs)
                    idx = find(twr_list == uniqTwrs(k));
                    R_out(idx,idx) = R_out(idx,idx) + cn.sameTowerSigma_m^2 * ones(numel(idx));
                end
            end
        end

    end  % Static methods
end
