classdef CodeMeasurementBuilder
    % CodeMeasurementBuilder  Builds pseudorange EKF rows (z, h, R).
    %
    % Extracted from MeasurementModel.computeMeasurements.
    % Covers: single-signal pseudorange loop, multi-signal expansion,
    % ionosphere-free IF combination, and correlated noise application.
    % All physics are preserved exactly — pure structural refactor.

    methods (Static)

        function tf = rBudgetEnabled(cfg)
            % rBudgetEnabled  Gate for the code-R budget accounting. Default FALSE.
            tf = false;
            try; tf = logical(cfg.diagnostics.codeRBudget.enable); catch; end
        end

        function out = rBudgetAccumulate(terms)
            % rBudgetAccumulate  Sum the AS-CHARGED R terms across rows and epochs.
            %   rBudgetAccumulate(terms)  accumulate one row
            %   rBudgetAccumulate('reset') clear
            %   out = rBudgetAccumulate('get') retrieve the running sums
            persistent ACC
            if isempty(ACC); ACC = struct('n', 0); end
            out = [];
            if ischar(terms) || isstring(terms)
                switch char(terms)
                    case 'reset'; ACC = struct('n', 0);
                    case 'get';   out = ACC;
                end
                return
            end
            fn = fieldnames(terms);
            for k = 1:numel(fn)
                f = fn{k};
                if ~isfield(ACC, f); ACC.(f) = 0; end
                ACC.(f) = ACC.(f) + terms.(f);
            end
            ACC.n = ACC.n + 1;
        end

        function [z, h, R, errStruct, twr_list, ant_list, M, N_sig] = build( ...
                cfg, errorChain, rngCorr, asset, towers, ...
                twr_list, ant_list, elv_list, leverArms, leverArms_model, ...
                r_ants_truth, r_ants_est, x_est, stateMap, ...
                towerClkTruth, towerClkModel, towerClkSigma, towerClkMode, t_prod, ...
                errStruct, t_s, assetIdx)
            % build  Build pseudorange measurement rows [z, h, R] and updated errStruct.
            %
            % Handles single-frequency, multi-frequency, and ionosphere-free combination.
            % Returns updated twr_list/ant_list/M/N_sig (may differ from input for multi-sig).
            %
            % assetIdx (optional, default 1): which satellite's state block to read (chief=1).
            % The per-asset indices (r/euler/b/zwd/iono) are resolved via
            % AssetStateBlock.forAsset; at assetIdx=1 the block aliases the chief stateMap fields
            % exactly, so this is byte-identical. Tower-level indices (towerClockIdx, txCodeBias)
            % stay on stateMap -- they are shared, not per-asset.
            if nargin < 22; assetIdx = 1; end
            blk = revgnss.AssetStateBlock.forAsset(stateMap, assetIdx);

            M  = numel(twr_list);

            r_cm_true = asset.r_ecef_m;
            euler_true = asset.attitude_euler_rad;
            b_rx_true = asset.clock.getBiasMeters();

            r_est     = x_est(blk.r);
            euler_est = revgnss.AssetStateBlock.eulerEst(blk, x_est);
            % Model-side relativistic clock correction (gated; exactly 0 when off). It is a
            % published constant derivable from the broadcast orbit, so the estimator may
            % apply it: the clock STATE then carries only the oscillator's own residual
            % instead of a 581 m relativistic ramp. H is unchanged -- the correction is a
            % known additive term, so d/dx(b_rx) is still 1.
            b_rx_relModel_m = models.clocks.RelativisticClockCorrection.bias_m(cfg, t_s);
            b_rx_est  = x_est(blk.b) + b_rx_relModel_m;

            sigmaFloor = cfg.measurement.sigmaFloor_m;

            % ----- Build z, h, R_diag (single-signal pseudoranges) --------
            z      = zeros(M,1);
            h      = zeros(M,1);
            R_diag = zeros(M,1);

            sagnacTruth_m  = zeros(M,1);
            sagnacModel_m  = zeros(M,1);
            shapiroTruth_m = zeros(M,1);
            shapiroModel_m = zeros(M,1);
            pcvTruth_m     = zeros(M,1);
            pcvModel_m     = zeros(M,1);
            towerSurveyTruth_m  = zeros(M,1);
            towerSurveyModel_m  = zeros(M,1);
            receiverPCOTruth_m  = zeros(M,1);
            receiverPCOModel_m  = zeros(M,1);
            towerPCOTruth_m     = zeros(M,1);
            towerPCOModel_m     = zeros(M,1);
            lightTimeTruth_s    = zeros(M,1);
            lightTimeModel_s    = zeros(M,1);
            transmitTimeTruth_s = NaN(M,1);
            transmitTimeModel_s = NaN(M,1);

            % MODEL-side tower-clock drift, for back-propagating the applied correction to
            % TRANSMIT time (see the model-side block further down). Taken from the same
            % provider the one-way h uses, so the model never borrows the truth's drift.
            % productNoise_ is a memoised deterministic function of (tower, productEpoch),
            % so re-entering computeDrift here returns the same realisation and draws
            % nothing new.
            bdotModelVec_ = zeros(M,1);
            try
                [~, bdotModelVec_] = models.clocks.TowerClockCorrectionProvider.computeDrift( ...
                    cfg, towers, twr_list, t_s);
                if numel(bdotModelVec_) ~= M
                    errStruct.suppressed.codeTransmitTimeDrift = 'lengthMismatch';
                    warning('CodeMeasurementBuilder:driftUnavailable', ...
                        ['computeDrift returned %d rows, expected %d; transmit-time ' ...
                         'back-propagation reverts to zero for this epoch.'], ...
                        numel(bdotModelVec_), M);
                    bdotModelVec_ = zeros(M,1);
                end
            catch ME_codeDrift_
                % D12: this fallback silently reverts the 7c65e30 transmit-time
                % back-propagation fix for the WHOLE epoch with no configuration change
                % and no record -- and the identical construct exists in
                % CarrierMeasurementBuilder and DopplerMeasurementBuilder, so one
                % computeDrift failure can de-model the tower clock across all three
                % observables while each builder reports only its own all-clear.
                errStruct.suppressed.codeTransmitTimeDrift = ME_codeDrift_.identifier;
                warning('CodeMeasurementBuilder:driftUnavailable', ...
                    ['Tower-clock drift unavailable (%s); transmit-time ' ...
                     'back-propagation reverts to zero for this epoch.'], ...
                    ME_codeDrift_.identifier);
                bdotModelVec_ = zeros(M,1);
            end

            for mi = 1:M
                ti  = twr_list(mi);
                ai  = ant_list(mi);
                elv = elv_list(mi);

                % Nominal tower position (no survey, no PCO) for contribution baseline
                r_twr_nom = towers{ti}.getAntennaPositionECEF();

                % Truth and model tower positions (survey error only, no PCO yet)
                r_twr_survey_truth = models.measurements.MeasurementModelUtils.towerPositionEcef(cfg, towers{ti}, ti, 'truth', t_s);
                r_twr_survey_model = models.measurements.MeasurementModelUtils.towerPositionEcef(cfg, towers{ti}, ti, 'model');

                % Tower survey range contribution (truth-model mismatch in range domain)
                towerSurveyTruth_m(mi) = norm(r_ants_truth(:,ai) - r_twr_survey_truth) - ...
                                         norm(r_ants_truth(:,ai) - r_twr_nom);
                towerSurveyModel_m(mi) = norm(r_ants_est(:,ai)   - r_twr_survey_model) - ...
                                         norm(r_ants_est(:,ai)   - r_twr_nom);

                % Start with survey-shifted positions for PCO application
                r_twr_truth = r_twr_survey_truth;
                r_twr_model = r_twr_survey_model;

                % Tower PCO on top of survey-shifted position
                if isfield(cfg,'effects') && isfield(cfg.effects,'antennaPCO')
                    pco = cfg.effects.antennaPCO;
                    if isfield(pco,'truth') && pco.truth.enable
                        tOff = pco.towerOffset_enu_m(:);
                        R_ENU = models.frames.GeometryUtils.enu2ecef(towers{ti}.lat_rad, towers{ti}.lon_rad);
                        r_twr_truth = r_twr_truth + R_ENU * tOff;
                    end
                    if isfield(pco,'model') && pco.model.enable
                        tOff = pco.towerOffset_enu_m(:);
                        R_ENU = models.frames.GeometryUtils.enu2ecef(towers{ti}.lat_rad, towers{ti}.lon_rad);
                        r_twr_model = r_twr_model + R_ENU * tOff;
                    end
                end

                % Tower PCO range contribution (before PCO vs after PCO positions)
                towerPCOTruth_m(mi) = norm(r_ants_truth(:,ai) - r_twr_truth) - ...
                                      norm(r_ants_truth(:,ai) - r_twr_survey_truth);
                towerPCOModel_m(mi) = norm(r_ants_est(:,ai)   - r_twr_model) - ...
                                      norm(r_ants_est(:,ai)   - r_twr_survey_model);

                % Receiver PCO range contribution (antenna with vs without PCO offset)
                if isfield(cfg,'effects') && isfield(cfg.effects,'antennaPCO')
                    pco = cfg.effects.antennaPCO;
                    if isfield(pco,'truth') && pco.truth.enable
                        r_ant_no_pco = revgnss.AttitudeKinematics.applyLeverArm( ...
                            r_cm_true, euler_true, leverArms(:,ai));
                        receiverPCOTruth_m(mi) = norm(r_ants_truth(:,ai) - r_twr_truth) - ...
                                                  norm(r_ant_no_pco      - r_twr_truth);
                    end
                    if isfield(pco,'model') && pco.model.enable
                        r_ant_no_pco_est = revgnss.AttitudeKinematics.applyLeverArm( ...
                            r_est, euler_est, leverArms(:,ai));
                        receiverPCOModel_m(mi) = norm(r_ants_est(:,ai)  - r_twr_model) - ...
                                                  norm(r_ant_no_pco_est - r_twr_model);
                    end
                end

                % Truth pseudorange with corrections + toy PCV
                [rho_true, cTruth] = models.corrections.RangeCorrections.correctedPseudorange( ...
                    r_ants_truth(:,ai), r_twr_truth, cfg, 'truth', elv, t_s);
                sagnacTruth_m(mi)  = cTruth.sagnac;
                shapiroTruth_m(mi) = cTruth.shapiro;
                pcvTruth_m(mi)     = cTruth.pcv;
                lightTimeTruth_s(mi) = cTruth.tau_s;
                if ~isempty(cTruth.t_tx_s); transmitTimeTruth_s(mi) = cTruth.t_tx_s; end

                % Transmit-time tower clock for truth side
                b_twr_truth_h = towerClkTruth(mi);
                if ~isempty(cTruth.t_tx_s)
                    tau_truth = t_s - cTruth.t_tx_s;
                    bdot_twr  = towers{ti}.getClockDriftMetersPerSecond();
                    b_twr_truth_h = b_twr_truth_h - bdot_twr * tau_truth;
                end
                z(mi) = rho_true + b_rx_true - b_twr_truth_h + errStruct.truthTotal_m(mi);

                % Predicted pseudorange with corrections
                [rho_est, cModel] = models.corrections.RangeCorrections.correctedPseudorange( ...
                    r_ants_est(:,ai), r_twr_model, cfg, 'model', elv, t_s);
                sagnacModel_m(mi)  = cModel.sagnac;
                shapiroModel_m(mi) = cModel.shapiro;
                pcvModel_m(mi)     = cModel.pcv;
                lightTimeModel_s(mi) = cModel.tau_s;
                if ~isempty(cModel.t_tx_s); transmitTimeModel_s(mi) = cModel.t_tx_s; end

                % Transmit-time tower clock for model side
                if ~isempty(cModel.t_tx_s) && ...
                        ~(isfield(stateMap,'towerClockIdx') && ti <= size(stateMap.towerClockIdx,1) && ...
                          stateMap.towerClockIdx(ti,1) > 0)
                    t_tx_model = cModel.t_tx_s;
                    switch towerClkMode
                        case {'product', 'productNoisy'}
                            % Re-evaluate the BIAS at transmit time only. The SIGMA stays
                            % whatever compute() installed -- for BOTH modes that already
                            % includes explicitProductWanderVar_ (TowerClockCorrectionProvider
                            % .m:175-177,199-201), which for productNoisy is orders of
                            % magnitude larger than evalProductStruct's own
                            % sqrt(sigmaBias^2+dt^2*sigmaDrift^2) term: at t=120s with a
                            % RWFM-dominated crystal the discarded wander is ~143 m against a
                            % surviving ~0.1 m, a ~2e6x variance hole (measured NIS 735 to
                            % 5.08e18 across the sweep -- the top of that band is EKF
                            % divergence from the first uncharged residual, not the ratio
                            % itself). 'product' never wrote this field at all, so it was
                            % always silently correct; 'productNoisy' used to overwrite it
                            % with evalProductStruct's OWN return, discarding the wander term.
                            % The light-time between t_s and t_tx_model (~0.12 s at GEO) is
                            % negligible against wander of that size, so re-anchoring the bias
                            % here and leaving the sigma untouched is not an approximation.
                            if isfield(cfg,'towerClock') && ...
                                    isfield(cfg.towerClock,'products') && ...
                                    ti <= numel(cfg.towerClock.products)
                                [b_reev, ~] = models.clocks.TowerClockCorrectionProvider.evalProductStruct( ...
                                    cfg, ti, t_tx_model);
                                towerClkModel(mi) = b_reev;
                            end
                        case 'truthProduct'
                            [b_p, bd_p] = models.clocks.TowerClockCorrectionProvider.clockAtProductEpoch( ...
                                towers{ti}, t_prod);
                            towerClkModel(mi) = b_p + bd_p * (t_tx_model - t_prod);

                        case {'perfectCorrection', 'noisyCorrection'}
                            % ORACLE modes: the correction IS the truth clock (plus, for
                            % noisyCorrection, an injected error). So it back-propagates with
                            % the TRUTH drift, exactly as the truth side above -- that is what
                            % keeps perfectCorrection's residual identically zero and
                            % noisyCorrection's residual exactly minus the injected noise,
                            % which is each mode's defining property.
                            towerClkModel(mi) = towerClkModel(mi) - ...
                                towers{ti}.getClockDriftMetersPerSecond() * (t_s - t_tx_model);

                        case 'truthHistoryProductNoisy'
                            % The DEFAULT mode, and the one this omission actually bit. The
                            % applied correction is a linear prediction from the product
                            % epoch, M(t) = (b_p + b_noise) + (bd_p + d_noise)*(t - t_prod).
                            % Evaluating it at TRANSMIT time instead of measurement time is
                            % therefore just M(t_s) - (bd_p + d_noise)*tau, and (bd_p +
                            % d_noise) is precisely the model drift computeDrift returns.
                            towerClkModel(mi) = towerClkModel(mi) - ...
                                bdotModelVec_(mi) * (t_s - t_tx_model);

                        % 'none' applies no correction, so there is nothing to
                        % back-propagate; its zero stays zero.
                    end
                end

                % Tower clock model — use EKF state if estimated, else product
                if isfield(stateMap,'towerClockIdx') && ti <= size(stateMap.towerClockIdx,1) && ...
                        stateMap.towerClockIdx(ti,1) > 0
                    b_twr_h = x_est(stateMap.towerClockIdx(ti,1));
                else
                    b_twr_h = towerClkModel(mi);
                end

                h(mi) = rho_est + b_rx_est - b_twr_h + errStruct.modelTotal_m(mi);

                % ZWD state contribution to predicted pseudorange
                if isfield(blk,'zwd') && ti <= numel(blk.zwd) && ...
                        blk.zwd(ti) > 0
                    mf_h = models.atmosphere.MappingFunctions.troposphere(elv, ...
                        models.measurements.MeasurementModelUtils.zwdMappingKind(cfg));
                    h(mi) = h(mi) + mf_h * x_est(blk.zwd(ti));
                end

                % Tx code hardware-delay state contribution (+1 sign: delay increases PR)
                if isfield(stateMap,'txCodeBiasIdx') && ti <= numel(stateMap.txCodeBiasIdx) && ...
                        stateMap.txCodeBiasIdx(ti) > 0
                    h(mi) = h(mi) + x_est(stateMap.txCodeBiasIdx(ti));
                end

                % Receiver code hardware-delay model correction
                d_rx_code_h = models.measurements.MeasurementModelUtils.rxCodeBiasModel(cfg);
                if d_rx_code_h ~= 0
                    h(mi) = h(mi) + d_rx_code_h;
                end

                % Tower-clock R guard (variance double-count): when this tower's clock is
                % an estimated EKF state (towerClockIdx>0, i.e. estimateTowerClocks=true)
                % its uncertainty already lives in the state covariance, so the broadcast-
                % product sigma must NOT also be charged into R. Mirror the h-side (which
                % reads the state instead of the product). Default estimateTowerClocks=false
                % -> towerClockIdx=0 -> no-op (golden-safe, byte-identical).
                twrClkSig_mi = towerClkSigma(mi);
                if isfield(stateMap,'towerClockIdx') && size(stateMap.towerClockIdx,1) >= ti ...
                        && stateMap.towerClockIdx(ti,1) > 0
                    twrClkSig_mi = 0;
                end
                sigma_i = sqrt(errStruct.sigmaTotal_m(mi)^2 + twrClkSig_mi^2);
                R_diag(mi) = max(sigma_i, sigmaFloor)^2;
            end

            % Deterministic per-signal code DCB contribution. This is code-only and
            % sigma-free unless an explicit stochastic DCB model is later introduced.
            % The base rows are L1; L2 rows are reconstructed below with their own DCB.
            [dcbTruthL1_, dcbModelL1_] = models.measurements.CodeMeasurementBuilder.codeDcbForSignal_(cfg, 'L1');
            dcbTruthVec_ = dcbTruthL1_ * ones(M,1);
            dcbModelVec_ = dcbModelL1_ * ones(M,1);
            z = z + dcbTruthVec_;
            h = h + dcbModelVec_;
            errStruct.truthTotal_m = errStruct.truthTotal_m + dcbTruthVec_;
            errStruct.modelTotal_m = errStruct.modelTotal_m + dcbModelVec_;
            errStruct.bySource.truth_m.dcb = dcbTruthVec_;
            errStruct.bySource.model_m.dcb = dcbModelVec_;
            errStruct.bySource.sigma_m.dcb = zeros(M,1);
            if isfield(errStruct,'labels') && ~any(strcmp(errStruct.labels, 'dcb'))
                errStruct.labels{end+1} = 'dcb';
            end

            % Complete the tower-clock product-sigma R double-count guard. The
            % single-freq diagonal above (lines 209-213) guards only a LOCAL copy; the
            % downstream L2/multi-sig diagonal, ionosphere-free R rebuild, and shared-tower
            % off-diagonal block read the RAW towerClkSigma / errStruct.towerClockModelSigma_m
            % and would re-charge the product variance while the tower BIAS state already
            % carries it in P (F1 double-count -- reachable via includeTowerClocksInEKF + a
            % noisy product mode). Mask the BIAS product sigma in place here (twr_list is
            % still the original per-row list, aligned with towerClkSigma) so lines 344/526
            % inherit the guard; the shared-tower block masks errStruct.towerClockModelSigma_m
            % locally below. Guard on column 1 (bias); errStruct.towerClockModelSigma_m is
            % left UNMASKED so diagnostics report the true product sigma. Gauge/reference
            % towers and non-estimated towers keep towerClockIdx==0 -> product sigma retained
            % (no under-count). Default estimateTowerClocks=false -> no-op (golden byte-identical).
            towerClkSigma = models.measurements.CodeMeasurementBuilder.maskStateTowerSigma_( ...
                towerClkSigma, twr_list, stateMap, 1);

            % Attach diagnostics
            errStruct.sagnacTruth_m  = sagnacTruth_m;
            errStruct.sagnacModel_m  = sagnacModel_m;
            errStruct.shapiroTruth_m = shapiroTruth_m;
            errStruct.shapiroModel_m = shapiroModel_m;
            errStruct.pcvTruth_m     = pcvTruth_m;
            errStruct.pcvModel_m     = pcvModel_m;
            errStruct.towerSurveyTruth_m  = towerSurveyTruth_m;
            errStruct.towerSurveyModel_m  = towerSurveyModel_m;
            errStruct.receiverPCOTruth_m  = receiverPCOTruth_m;
            errStruct.receiverPCOModel_m  = receiverPCOModel_m;
            errStruct.towerPCOTruth_m     = towerPCOTruth_m;
            errStruct.towerPCOModel_m     = towerPCOModel_m;
            errStruct.lightTimeTruth_s    = lightTimeTruth_s;
            errStruct.lightTimeModel_s    = lightTimeModel_s;
            errStruct.transmitTimeTruth_s = transmitTimeTruth_s;
            errStruct.transmitTimeModel_s = transmitTimeModel_s;

            % ----- Multi-signal expansion ----------------------------------
            signals = revgnss.SignalUtils.getEnabledSignals(cfg);
            N_sig   = numel(signals);

            % Canonical cfg.signals.frequencyHz (set by finalizeConfig); the else-branch
            % resolves the same owner rather than a name-keyed catalogue.
            if isfield(cfg,'signals') && isfield(cfg.signals,'frequencyHz') && ...
                    numel(cfg.signals.frequencyHz) >= 1
                f_L1 = cfg.signals.frequencyHz(1);
            else
                f_L1 = revgnss.SignalUtils.frequency(cfg, 'L1');
            end

            if N_sig > 1
                % NOTE on hardware/code biases (DCB):
                % Configured deterministic code DCB is applied per signal and survives
                % IF as alpha*DCB_L1 + beta*DCB_L2. This is not a calibrated external
                % DCB product or per-tower/receiver DCB state model.
                M_pairs = M;
                M       = M_pairs * N_sig;

                z_new      = zeros(M,1);
                h_new      = zeros(M,1);
                R_diag_new = zeros(M,1);

                flds  = {'code','trop','iono','ionoHO','hwDelay','dcb','mp','scintillation'};
                btOut = struct(); bmOut = struct(); bsOut = struct();
                for fi = 1:numel(flds)
                    btOut.(flds{fi}) = zeros(M,1);
                    bmOut.(flds{fi}) = zeros(M,1);
                end
                bsOut.code = zeros(M,1);
                bsOut.ionoHO = zeros(M,1);

                sigIdx   = zeros(M,1);
                sigNames = cell(M,1);
                freqHz   = zeros(M,1);

                scintExpF = 1.0;
                if isfield(cfg,'errors') && isfield(cfg.errors,'ionosphere') && ...
                        isfield(cfg.errors.ionosphere,'scintillation') && ...
                        isfield(cfg.errors.ionosphere.scintillation,'frequencyExponent')
                    scintExpF = cfg.errors.ionosphere.scintillation.frequencyExponent;
                end

                for si = 1:N_sig
                    sigCfg    = signals(si);
                    freqScale = (f_L1 / sigCfg.frequency_Hz)^2;
                    offset    = (si-1) * M_pairs;

                    for pi = 1:M_pairs
                        mi = offset + pi;
                        sigIdx(mi)   = si;
                        sigNames{mi} = sigCfg.name;
                        freqHz(mi)   = sigCfg.frequency_Hz;

                        scintSigL1_pi = errStruct.scintSigmaL1_m(pi);
                        scintSig_si   = scintSigL1_pi * (f_L1 / sigCfg.frequency_Hz)^scintExpF;
                        % Atmosphere-rooted: shares the formation-wide root when
                        % cfg.atmosphere.sharedAcrossFormation is on (the ionospheric
                        % irregularities are inside the L-band Fresnel scale for a
                        % sub-10 km cluster), plain drawKeyed otherwise. antennaKey()
                        % additionally collapses the antenna field when
                        % cfg.atmosphere.sharedAcrossAntennas is on -- a 2 m antenna cross
                        % is <= 8e-3 Fresnel scales across, so its phase centres see one
                        % diffraction pattern, not four independent ones.
                        scint_t       = scintSig_si * errorChain.drawKeyedAtmosphere( ...
                            models.noise.RngSource.SCINT_TRUTH, twr_list(pi), ...
                            errorChain.antennaKey(ant_list(pi)), si, errorChain.epochIdx_, 1, 1);

                        if si == 1
                            z_new(mi)      = z(pi) + scint_t;
                            h_new(mi)      = h(pi);
                            R_diag_new(mi) = R_diag(pi) + scintSig_si^2;

                            % Same accounting as the si>1 branch below. The PRIMARY signal
                            % takes this path, so instrumenting only the other one would
                            % have measured the L2 rows and reported them as the budget.
                            % Here R_diag(pi) is already assembled (sigmaTotal^2 +
                            % towerClk^2, floored), so its parts are re-read from the error
                            % chain at the same row index rather than recomputed.
                            if models.measurements.CodeMeasurementBuilder.rBudgetEnabled(cfg)
                                gs_ = @(f) i_sigSq(errStruct, f, pi);
                                models.measurements.CodeMeasurementBuilder.rBudgetAccumulate( ...
                                    struct( ...
                                      'codeNoise',  gs_('code'), ...
                                      'scint',      scintSig_si^2, ...
                                      'extraTotal', gs_('trop') + gs_('iono') + gs_('hwDelay') ...
                                                    + gs_('mp') + gs_('ionoHO'), ...
                                      'towerClock', towerClkSigma(pi)^2, ...
                                      'trop',       gs_('trop'), ...
                                      'ionoScaled', gs_('iono'), ...
                                      'ionoL1',     gs_('iono'), ...
                                      'mp',         gs_('mp'), ...
                                      'hwDelay',    gs_('hwDelay'), ...
                                      'ionoHOScaled', gs_('ionoHO'), ...
                                      'total',      R_diag_new(mi), ...
                                      'nPrimary',   1, ...
                                      'floorHit',   0));
                            end
                            for fi = 1:numel(flds)
                                fn = flds{fi};
                                if isfield(errStruct.bySource.truth_m, fn)
                                    btOut.(fn)(mi) = errStruct.bySource.truth_m.(fn)(pi);
                                end
                                if isfield(errStruct.bySource.model_m, fn)
                                    bmOut.(fn)(mi) = errStruct.bySource.model_m.(fn)(pi);
                                end
                            end
                            btOut.scintillation(mi) = scint_t;
                            elv_pi = errStruct.elevations_rad(pi);
                            zwd_pi = models.measurements.CodeMeasurementBuilder.towerZwd_(errorChain, twr_list(pi));
                            sigma_code_si = models.measurements.MeasurementModelUtils.codeSignalSigma(sigCfg, elv_pi, cfg, zwd_pi);
                            bsOut.code(mi) = sigma_code_si;
                            if isfield(errStruct.bySource.sigma_m,'ionoHO')
                                bsOut.ionoHO(mi) = errStruct.bySource.sigma_m.ionoHO(pi);
                            end
                        else
                            elv_pi        = errStruct.elevations_rad(pi);
                            zwd_pi        = models.measurements.CodeMeasurementBuilder.towerZwd_(errorChain, twr_list(pi));
                            sigma_code_si = models.measurements.MeasurementModelUtils.codeSignalSigma(sigCfg, elv_pi, cfg, zwd_pi);
                            code_t        = sigma_code_si * errorChain.drawKeyed( ...
                                models.noise.RngSource.CODE_MULTISIG, twr_list(pi), ant_list(pi), si, errorChain.epochIdx_, 1, 1);

                            iono_t_si = 0; iono_m_si = 0;
                            if isfield(errStruct.bySource.truth_m,'iono')
                                iono_t_si = errStruct.bySource.truth_m.iono(pi) * freqScale;
                            end
                            if isfield(errStruct.bySource.model_m,'iono')
                                iono_m_si = errStruct.bySource.model_m.iono(pi) * freqScale;
                            end

                            ionoHO_t_si = 0; ionoHO_m_si = 0; ionoHO_sig_si = 0;
                            if isfield(errStruct.bySource.truth_m,'ionoHO')
                                ionoL1_t = 0;
                                if isfield(errStruct.bySource.truth_m,'iono')
                                    ionoL1_t = errStruct.bySource.truth_m.iono(pi);
                                end
                                ionoHO_t_si = models.measurements.CodeMeasurementBuilder.higherOrderIonoAtFrequency_( ...
                                    cfg, errStruct.bySource.truth_m.ionoHO(pi), ionoL1_t, sigCfg.frequency_Hz, f_L1);
                            end
                            if isfield(errStruct.bySource.model_m,'ionoHO')
                                ionoL1_m = 0;
                                if isfield(errStruct.bySource.model_m,'iono')
                                    ionoL1_m = errStruct.bySource.model_m.iono(pi);
                                end
                                ionoHO_m_si = models.measurements.CodeMeasurementBuilder.higherOrderIonoAtFrequency_( ...
                                    cfg, errStruct.bySource.model_m.ionoHO(pi), ionoL1_m, sigCfg.frequency_Hz, f_L1);
                            end
                            if isfield(errStruct.bySource.sigma_m,'ionoHO')
                                sigmaIonoHOL1_pi = errStruct.bySource.sigma_m.ionoHO(pi);
                                % Scale the SIGMA on the MODEL ionosphere, not the truth.
                                % The sigma itself is now model-derived (see
                                % ErrorChain.higherOrderIono_), so using the truth slant as
                                % the frequency-scaling reference would put truth back into
                                % R through the cap interaction.
                                ionoL1_sig = 0;
                                if isfield(errStruct.bySource.model_m,'iono')
                                    ionoL1_sig = errStruct.bySource.model_m.iono(pi);
                                end
                                ionoHO_sig_si = models.measurements.CodeMeasurementBuilder.higherOrderIonoSigmaAtFrequency_( ...
                                    cfg, sigmaIonoHOL1_pi, ionoL1_sig, sigCfg.frequency_Hz, f_L1);
                            end

                            trop_t = 0; trop_m = 0; hw_t = 0; hw_m = 0; mp_t = 0;
                            [dcb_t, dcb_m] = models.measurements.CodeMeasurementBuilder.codeDcbForSignal_(cfg, sigCfg.name);
                            if isfield(errStruct.bySource.truth_m,'trop'),    trop_t = errStruct.bySource.truth_m.trop(pi);    end
                            if isfield(errStruct.bySource.model_m,'trop'),    trop_m = errStruct.bySource.model_m.trop(pi);    end
                            if isfield(errStruct.bySource.truth_m,'hwDelay'), hw_t   = errStruct.bySource.truth_m.hwDelay(pi); end
                            if isfield(errStruct.bySource.model_m,'hwDelay'), hw_m   = errStruct.bySource.model_m.hwDelay(pi); end
                            if isfield(errStruct.bySource.truth_m,'mp'),      mp_t   = errStruct.bySource.truth_m.mp(pi);      end
                            % Multipath is frequency-DEPENDENT and was the one error on this
                            % row that ignored that: the ionosphere is frequency-scaled, the
                            % DCB is per-signal and the thermal noise is drawn per-signal,
                            % but mp_t was the SAME base-row realisation copied verbatim onto
                            % every signal. One reflection geometry, but a different path
                            % length in CYCLES per wavelength, so L1 and L2 are different
                            % realisations of the same statistics.
                            % si == 1 keeps multipath_'s chain, so single-frequency runs and
                            % the first signal of a dual-frequency run stay byte-identical;
                            % additional signals get their own (tower, antenna, signal) chain
                            % and RNG stream. Returns empty whenever multipath or its
                            % coloured-GM branch is off, so every existing gate still
                            % disables it completely.
                            dtMp_ = 1; try; dtMp_ = cfg.simulation.dt_s; catch; end %#ok<NASGU>
                            mpSi_ = errorChain.multipathForSignal(twr_list(pi), ant_list(pi), ...
                                si, errStruct.elevations_rad(pi), dtMp_);
                            if ~isempty(mpSi_); mp_t = mpSi_; end

                            % Geometry + clocks (strips L1 error terms from z/h)
                            z_geom_pi = z(pi) - errStruct.truthTotal_m(pi);
                            h_geom_pi = h(pi) - errStruct.modelTotal_m(pi);

                            z_new(mi) = z_geom_pi + trop_t + iono_t_si + ionoHO_t_si + hw_t + dcb_t + mp_t + code_t + scint_t;
                            h_new(mi) = h_geom_pi + trop_m + iono_m_si + ionoHO_m_si + hw_m + dcb_m;

                            sigma_extra_pi = errStruct.sigmaExtra_m(pi);
                            sigmaIonoHOL1_pi = 0;
                            if isfield(errStruct.bySource.sigma_m,'ionoHO')
                                sigmaIonoHOL1_pi = errStruct.bySource.sigma_m.ionoHO(pi);
                            end
                            % First-order ionosphere is DISPERSIVE: the truth and model
                            % values on this row were both scaled by freqScale above
                            % (iono_t_si/iono_m_si), so its sigma must be scaled too.
                            % sigmaExtra_m carries the L1-level value; swap it for the
                            % signal-scaled one exactly as the higher-order term is
                            % swapped. Without this the L2 row charges the L1 iono sigma
                            % against an error freqScale times larger -> R short by
                            % freqScale^2 (2.712x for GPS L1/L2) on the dominant term.
                            sigmaIono1L1_pi = 0;
                            if isfield(errStruct.bySource.sigma_m,'iono')
                                sigmaIono1L1_pi = errStruct.bySource.sigma_m.iono(pi);
                            end
                            sigmaIono1_si = sigmaIono1L1_pi * freqScale;
                            sigma_extra_si2 = max(sigma_extra_pi^2 ...
                                                  - sigmaIonoHOL1_pi^2 + ionoHO_sig_si^2 ...
                                                  - sigmaIono1L1_pi^2 + sigmaIono1_si^2, 0);
                            R_diag_new(mi) = max(sigma_code_si, sigmaFloor)^2 + ...
                                             scintSig_si^2 + sigma_extra_si2 + towerClkSigma(pi)^2;

                            % Gated R-budget accounting, default OFF and byte-identical.
                            % WHY IT EXISTS: a budget measured on ErrorChain alone is NOT
                            % this R. ErrorChain reports six sources; the row actually
                            % charged here adds scintillation and the tower clock on top,
                            % and frequency-scales the ionosphere per signal. Measuring the
                            % chain in isolation attributed 87% of code R to the ionosphere
                            % when scaling it moved the channel by only 13% -- the missing
                            % terms were the story. This accumulates the terms AS CHARGED,
                            % so the decomposition can never disagree with the R the filter
                            % actually inverts.
                            if models.measurements.CodeMeasurementBuilder.rBudgetEnabled(cfg)
                                models.measurements.CodeMeasurementBuilder.rBudgetAccumulate( ...
                                    struct( ...
                                      'codeNoise',  max(sigma_code_si, sigmaFloor)^2, ...
                                      'scint',      scintSig_si^2, ...
                                      'extraTotal', sigma_extra_si2, ...
                                      'towerClock', towerClkSigma(pi)^2, ...
                                      'ionoL1',     sigmaIono1L1_pi^2, ...
                                      'ionoScaled', sigmaIono1_si^2, ...
                                      'ionoHOScaled', ionoHO_sig_si^2, ...
                                      'trop',       i_sigSq(errStruct,'trop',pi), ...
                                      'mp',         i_sigSq(errStruct,'mp',pi), ...
                                      'hwDelay',    i_sigSq(errStruct,'hwDelay',pi), ...
                                      'total',      R_diag_new(mi), ...
                                      'nPrimary',   0, ...
                                      'floorHit',   double(sigma_code_si < sigmaFloor)));
                            end

                            btOut.trop(mi)          = trop_t;
                            bmOut.trop(mi)          = trop_m;
                            btOut.iono(mi)          = iono_t_si;
                            bmOut.iono(mi)          = iono_m_si;
                            btOut.ionoHO(mi)        = ionoHO_t_si;
                            bmOut.ionoHO(mi)        = ionoHO_m_si;
                            btOut.hwDelay(mi)       = hw_t;
                            bmOut.hwDelay(mi)       = hw_m;
                            btOut.dcb(mi)           = dcb_t;
                            bmOut.dcb(mi)           = dcb_m;
                            btOut.mp(mi)            = mp_t;
                            btOut.code(mi)          = code_t;
                            btOut.scintillation(mi) = scint_t;
                            bsOut.code(mi)          = sigma_code_si;
                            bsOut.ionoHO(mi)        = ionoHO_sig_si;
                        end

                        % Per-tower slant-iono EKF state (prototype): the state supplies the
                        % model ionosphere (pair with model.correction='none' so it is not
                        % double-counted). It enters each signal through its 1/f^2 dispersion
                        % (freqScale = (f_L1/f_sig)^2), which is what makes it observable from L1/L2.
                        ti_io = twr_list(pi);
                        if isfield(blk,'iono') && ti_io <= numel(blk.iono) && ...
                                blk.iono(ti_io) > 0
                            h_new(mi) = h_new(mi) + freqScale * x_est(blk.iono(ti_io));
                        end
                    end
                end

                z        = z_new;
                h        = h_new;
                R_diag   = R_diag_new;
                twr_list = repmat(twr_list, N_sig, 1);
                ant_list = repmat(ant_list, N_sig, 1);

                errStruct.bySource.truth_m = btOut;
                errStruct.bySource.model_m = bmOut;

                % Tile non-code sigma fields; override code sigma with signal-specific
                sigFlds = fieldnames(errStruct.bySource.sigma_m);
                for fi2 = 1:numel(sigFlds)
                    fn = sigFlds{fi2};
                    if ~isempty(errStruct.bySource.sigma_m.(fn))
                        errStruct.bySource.sigma_m.(fn) = repmat(errStruct.bySource.sigma_m.(fn)(:), N_sig, 1);
                    end
                end
                errStruct.bySource.sigma_m.code = bsOut.code;
                if isfield(errStruct.bySource.sigma_m,'ionoHO')
                    errStruct.bySource.sigma_m.ionoHO = bsOut.ionoHO;
                end
                % First-order ionosphere is dispersive, so the plain tiling above leaves
                % the L1 sigma on every signal's row while the truth/model values were
                % scaled by freqScale. Rescale per row so the reported per-source sigma
                % agrees with both the injected error and the R built above. Signal 1
                % scales by 1.0 and is unchanged.
                if isfield(errStruct.bySource.sigma_m,'iono') && ...
                        numel(errStruct.bySource.sigma_m.iono) == M
                    ionoFreqScale_ = (f_L1 ./ freqHz(:)).^2;
                    errStruct.bySource.sigma_m.iono = ...
                        errStruct.bySource.sigma_m.iono(:) .* ionoFreqScale_;
                end

                % Tile scalar errStruct arrays
                tileFields = {'towerClockTruth_m','towerClockModel_m','towerClockModelSigma_m', ...
                              'towerClockProductEpoch_s','towerClockProductAge_s', ...
                              'sagnacTruth_m','sagnacModel_m','shapiroTruth_m','shapiroModel_m', ...
                              'pcvTruth_m','pcvModel_m','towerSurveyTruth_m','towerSurveyModel_m', ...
                              'receiverPCOTruth_m','receiverPCOModel_m','towerPCOTruth_m','towerPCOModel_m', ...
                              'elevations_rad','scintSigmaL1_m','sigmaExtra_m','sigmaTotal_m'};
                for fi2 = 1:numel(tileFields)
                    fn = tileFields{fi2};
                    if isfield(errStruct, fn) && ~isempty(errStruct.(fn))
                        vTile_ = errStruct.(fn)(:);
                        if numel(vTile_) == 1
                            errStruct.(fn) = repmat(vTile_, M, 1);
                        else
                            errStruct.(fn) = repmat(vTile_, N_sig, 1);
                        end
                    end
                end

                errStruct.towerIdx_perMeas   = twr_list;
                errStruct.antennaIdx_perMeas = ant_list;
                errStruct.nPseudorange       = M;

                % Rebuild truthTotal and modelTotal at M level
                errStruct.truthTotal_m = zeros(M,1);
                errStruct.modelTotal_m = zeros(M,1);
                for fi2 = 1:numel(flds)
                    fn = flds{fi2};
                    errStruct.truthTotal_m = errStruct.truthTotal_m + btOut.(fn);
                    if isfield(bmOut, fn)
                        errStruct.modelTotal_m = errStruct.modelTotal_m + bmOut.(fn);
                    end
                end

                errStruct.signalIdx_perMeas   = sigIdx;
                errStruct.signalName_perMeas  = sigNames;
                errStruct.frequencyHz_perMeas = freqHz;
            else
                % Single frequency: add signal metadata, keep everything else unchanged
                errStruct.signalIdx_perMeas   = ones(M,1);
                errStruct.signalName_perMeas  = repmat({'L1'}, M, 1);
                if isfield(cfg,'signals') && isfield(cfg.signals,'L1')
                    errStruct.frequencyHz_perMeas = ...
                        cfg.signals.L1.frequency_Hz * ones(M,1);
                else
                    errStruct.frequencyHz_perMeas = f_L1 * ones(M,1);
                end

                % Add scintillation to bySource (L1 only)
                if isfield(errStruct,'scintSigmaL1_m') && any(errStruct.scintSigmaL1_m > 0)
                    if errorChain.useIndependentStreams || errorChain.sharedAtmosphere
                        % drawKeyedAtmosphere roots this at the FORMATION-WIDE seed when
                        % cfg.atmosphere.sharedAcrossFormation is on (so swarm members see
                        % one common scintillation realisation) and is byte-identical to
                        % the previous drawKeyed call when it is off. antennaKey() likewise
                        % collapses the antenna field when cfg.atmosphere.sharedAcrossAntennas
                        % is on, and is the identity when it is off.
                        scintTruth = zeros(M,1);
                        for miS = 1:M
                            scintTruth(miS) = errStruct.scintSigmaL1_m(miS) * errorChain.drawKeyedAtmosphere( ...
                                models.noise.RngSource.SCINT_TRUTH, twr_list(miS), ...
                                errorChain.antennaKey(ant_list(miS)), 1, errorChain.epochIdx_, 1, 1);
                        end
                    else
                        scintTruth = errStruct.scintSigmaL1_m .* randn(errorChain.rngStream, M, 1);
                    end
                    z = z + scintTruth;
                    errStruct.bySource.truth_m.scintillation = scintTruth;
                    errStruct.bySource.model_m.scintillation = zeros(M,1);
                    R_diag = R_diag + errStruct.scintSigmaL1_m.^2;
                else
                    errStruct.bySource.truth_m.scintillation = zeros(M,1);
                    errStruct.bySource.model_m.scintillation = zeros(M,1);
                end
            end

            % ----- IF combination (ionosphereFree codeMode) ---------------
            % When codeMode='ionosphereFree' and N_sig==2: combine stacked L1+L2
            % rows into M_pairs IF rows.
            codeMode_v = '';
            if isfield(cfg,'measurements') && isfield(cfg.measurements,'codeMode')
                codeMode_v = cfg.measurements.codeMode;
            end
            % ionosphereFreeRows toggle maps to existing codeMode path. This fallback is
            % DEAD in every shipped config (codeMode is never empty), but read the two
            % leaves INDEPENDENTLY anyway (D12): sharing one try meant a cfg with .enable
            % present but .useInEkf missing threw on the second read and silently
            % discarded the first too -- the code-side twin of the same sharedErrors
            % pattern fixed above.
            if isempty(codeMode_v) && N_sig == 2
                ifEnable_ = false;
                try; ifEnable_ = logical(cfg.measurements.code.ionosphereFreeRows.enable); catch; end
                ifInEkf_ = false;
                try; ifInEkf_ = logical(cfg.measurements.code.ionosphereFreeRows.useInEkf); catch; end
                if ifEnable_ && ifInEkf_; codeMode_v = 'ionosphereFree'; end
            end
            M_pairs_if = round(M / max(N_sig, 1));
            % Always set, not only on success (D12): a consumer must never be able to
            % infer IF rows exist just because this field is unset.
            errStruct.ifCombination = false;
            if strcmp(codeMode_v,'ionosphereFree') && N_sig == 2 && M ~= M_pairs_if * 2
                % Requested but the row shape can't pair into M_pairs_if IF rows (e.g. an
                % elevation-mask asymmetry broke L1/L2 pairing) -- record it LOUDLY rather
                % than silently falling through to raw per-signal rows below.
                errStruct.suppressed.codeIonoFreeRows = sprintf( ...
                    'rowShape(M=%d, pairs=%d, nSig=%d)', M, M_pairs_if, N_sig);
                warning('CodeMeasurementBuilder:ifRowShapeMismatch', ...
                    ['codeMode=ionosphereFree requested but the row shape (M=%d, nSig=%d) ' ...
                     'does not support pairing into %d IF rows; raw per-signal code rows ' ...
                     'enter the EKF instead.'], M, N_sig, M_pairs_if);
            end
            if strcmp(codeMode_v,'ionosphereFree') && N_sig == 2 && M == M_pairs_if * 2
                signals_if = revgnss.SignalUtils.getEnabledSignals(cfg);
                f_L2_if    = signals_if(2).frequency_Hz;
                [alpha_if, beta_if] = revgnss.IonoFreeCombination.coefficients(f_L1, f_L2_if);

                idx1 = 1:M_pairs_if;
                idx2 = M_pairs_if+1 : 2*M_pairs_if;

                z_if    = alpha_if * z(idx1)         + beta_if * z(idx2);
                h_if    = alpha_if * h(idx1)         + beta_if * h(idx2);

                % ----- Correlation-aware IF measurement variance (R_if) -----
                % The naive R_if = alpha^2*R(L1) + beta^2*R(L2) charges EVERY error
                % source at (alpha^2+beta^2) ~= 8.9x. That gain is correct ONLY for
                % sources that are statistically INDEPENDENT between L1 and L2. Two
                % classes of source are mishandled by that formula:
                %   * Non-dispersive sources (troposphere, tower-clock) are IDENTICAL on
                %     L1 and L2 (100% correlated), so they pass the IF at unit gain
                %     (alpha+beta = 1) and their IF variance is (alpha+beta)^2*sigma^2 =
                %     sigma^2, NOT (alpha^2+beta^2)*sigma^2.
                %   * The first-order ionosphere is DETERMINISTICALLY CANCELLED by
                %     construction (alpha/f1^2 + beta/f2^2 = 0). Its stochastic-TEC
                %     uncertainty is the SAME physical TEC scaled by 1/f^2, so it cancels
                %     too. It contributes EXACTLY ZERO to the IF innovation and must
                %     contribute zero to R_if.
                % We therefore rebuild R_if per source with source-appropriate IF gains:
                %   code / multipath / scintillation / signal-dependent HW delay
                %       -> INDEPENDENT per signal: alpha^2*sigmaL1^2 + beta^2*sigmaL2^2
                %   troposphere, tower-clock (non-dispersive, equal on L1/L2)
                %       -> CORRELATED unit gain: (alpha+beta)^2*sigma^2 = sigma^2
                %   first-order ionosphere (dispersive 1/f^2, same physical TEC)
                %       -> CANCELS: 0
                %   higher-order ionosphere (dispersive f^-3/f^-4, same physical TEC)
                %       -> SURVIVES as the signed alpha/beta combination of the raw rows
                %
                % Implementation: the four independent-per-signal sources all share the
                % SAME alpha^2/beta^2 gain, so we keep them bundled. We strip only the
                % correlated + cancelled variance (trop + iono-1st + iono-HO + tower-clock)
                % out of R_diag; higher-order sigmas are signal-scaled and therefore stripped
                % separately per row. Apply alpha^2/beta^2 to the independent remainder, then
                % re-add the correlated and higher-order terms with their correct gains.
                % Keeping the independent remainder inside
                % R_diag preserves the per-signal code/scintillation frequency scaling
                % byte-identically (no re-derivation of those sigmas here).
                smSig_    = errStruct.bySource.sigma_m;
                sigTrop_  = zeros(M_pairs_if,1);
                sigIono1_ = zeros(M_pairs_if,1);
                sigIonoHO_L1_= zeros(M_pairs_if,1);
                sigIonoHO_L2_= zeros(M_pairs_if,1);
                if isfield(smSig_,'trop')   && numel(smSig_.trop)   >= M_pairs_if; sigTrop_   = smSig_.trop(idx1);   end
                if isfield(smSig_,'iono')   && numel(smSig_.iono)   >= M_pairs_if; sigIono1_  = smSig_.iono(idx1);   end
                if isfield(smSig_,'ionoHO') && numel(smSig_.ionoHO) >= 2*M_pairs_if
                    sigIonoHO_L1_ = smSig_.ionoHO(idx1);
                    sigIonoHO_L2_ = smSig_.ionoHO(idx2);
                elseif isfield(smSig_,'ionoHO') && numel(smSig_.ionoHO) >= M_pairs_if
                    sigIonoHO_L1_ = smSig_.ionoHO(idx1);
                    sigIonoHO_L2_ = smSig_.ionoHO(idx1);
                end
                sigTwr_if_ = zeros(M_pairs_if,1);
                if numel(towerClkSigma) >= M_pairs_if; sigTwr_if_ = towerClkSigma(1:M_pairs_if); end
                % Hardware delay is emitted NON-DISPERSIVE by this simulator (one per-tower
                % value copied unscaled onto the L2 row), so like troposphere/tower-clock it
                % passes the IF at unit gain, NOT (alpha^2+beta^2). Strip it from the
                % independent remainder and re-add at unit gain below. (Latent today:
                % hardwareDelay.sigma_m defaults to 0; this prevents a silent x8.9 over-count
                % if a hardware-delay sigma is ever enabled.)
                sigHw_ = zeros(M_pairs_if,1);
                if isfield(smSig_,'hwDelay') && numel(smSig_.hwDelay) >= M_pairs_if; sigHw_ = smSig_.hwDelay(idx1); end
                % Multipath is CORRELATED, not independent per signal (fixed 2026-08-09).
                % This simulator copies ONE realisation onto both rows unscaled -- the L2
                % row is built with `+ mp_t +` straight from the L1 draw (:424) and takes
                % its sigma from the same sigmaExtra_m(pi) (:427) -- so the two rows carry
                % a bit-identical multipath error. A perfectly correlated source passes
                % the IF at (alpha+beta) = 1, so its IF variance is sigma^2, but leaving
                % it in the independent bundle charged it (alpha^2+beta^2) = 8.870x. At
                % the shipped 0.30/sin(el) that is 0.798 m^2 instead of 0.090 m^2 at
                % zenith. Strip it here and re-add at unit gain below, exactly as
                % troposphere, tower-clock and hardware delay are handled.
                % (If multipath is ever drawn per signal, move it back into the bundle.)
                sigMp_ = zeros(M_pairs_if,1);
                if isfield(smSig_,'mp') && numel(smSig_.mp) >= M_pairs_if; sigMp_ = smSig_.mp(idx1); end

                % Correlated + cancelled variance baked into each raw row of R_diag.
                % Higher-order ionosphere is signal-scaled; the other listed terms are
                % common to the pair in the current source model.
                %
                % First-order ionosphere is signal-scaled too: the L2 row of R_diag now
                % carries (freqScale*sigIono1_)^2, so the L2 strip must remove that same
                % scaled variance. Stripping the unscaled L1 value here would leave the
                % difference inside Rindep_L2_ and then re-charge it at beta^2 instead of
                % the zero gain the cancellation demands.
                ionoFreqScale_if_ = (f_L1 / f_L2_if)^2;
                sigIono1_L2_      = sigIono1_ * ionoFreqScale_if_;
                corrBaked_L1_ = sigTrop_.^2 + sigIono1_.^2    + sigIonoHO_L1_.^2 + sigTwr_if_.^2 + sigHw_.^2 + sigMp_.^2;
                corrBaked_L2_ = sigTrop_.^2 + sigIono1_L2_.^2 + sigIonoHO_L2_.^2 + sigTwr_if_.^2 + sigHw_.^2 + sigMp_.^2;

                % Independent-per-signal remainder still carries the native per-signal
                % L1/L2 sigmas (code + multipath + scintillation + signal-dependent HW
                % delay). Non-negative BY CONSTRUCTION as long as sigTwr_if_ was stripped
                % from the SAME masked towerClkSigma R_diag was built from -- towerClkSigma
                % is reassigned in place to its state-masked form at the guard above
                % (maskStateTowerSigma_, col=1) BEFORE this IF block runs, so sigTwr_if_ at
                % :727 already reads it. If a future refactor ever breaks that ordering, the
                % max(...,0) would silently clamp away the independent code/multipath/
                % scintillation variance instead of just floating-point dust -- so verify the
                % shortfall LOUDLY rather than trust the comment.
                short_L1_ = corrBaked_L1_ - R_diag(idx1);
                short_L2_ = corrBaked_L2_ - R_diag(idx2);
                if any(short_L1_ > 1e-9) || any(short_L2_ > 1e-9)
                    errStruct.suppressed.ifIndependentRemainder = sprintf( ...
                        'clampedRowsL1=%d clampedRowsL2=%d maxShortfall_m2=%.3e', ...
                        sum(short_L1_ > 1e-9), sum(short_L2_ > 1e-9), ...
                        max([short_L1_; short_L2_]));
                    warning('CodeMeasurementBuilder:ifRemainderClamped', ...
                        ['corrBaked exceeds R_diag on %d ionosphere-free code row(s); the ' ...
                         'independent (code+multipath+scintillation) remainder was clamped ' ...
                         'to zero instead of going negative -- towerClkSigma masking has ' ...
                         'diverged between R_diag and sigTwr_if_.'], ...
                        sum(short_L1_ > 1e-9) + sum(short_L2_ > 1e-9));
                end
                Rindep_L1_ = max(R_diag(idx1) - corrBaked_L1_, 0);
                Rindep_L2_ = max(R_diag(idx2) - corrBaked_L2_, 0);

                % Fully correlated signed-source propagation: L1/L2 higher-order terms
                % are deterministic functions of the same ionosphere ray path, so the IF
                % one-sigma magnitude follows the signed alpha/beta source combination.
                %
                % The sigma fields are used here, NOT bySource.truth_m.ionoHO. An earlier
                % override read the REALISED higher-order truth straight into R, which is
                % the same truth leakage just removed from ErrorChain.higherOrderIono_:
                % it makes the higher-order residual exactly a 1-sigma event by
                % construction and is information no receiver possesses. sigIonoHO_L1_/L2_
                % are now model-ionosphere-derived, so the signed combination below is the
                % correct correlated propagation with no truth in it.
                sigIonoHO_IF_ = abs(alpha_if * sigIonoHO_L1_ + beta_if * sigIonoHO_L2_);

                R_if = alpha_if^2 * Rindep_L1_ + beta_if^2 * Rindep_L2_ ... % independent per signal
                     + sigTrop_.^2 ...                                      % troposphere: unit gain
                     + 0 * sigIono1_.^2 ...                                 % first-order iono: cancels -> 0
                     + sigIonoHO_IF_.^2 ...                                  % higher-order iono: correlated signed source
                     + sigMp_.^2 ...                                        % multipath: one realisation on both rows -> unit gain
                     + sigTwr_if_.^2 ...                                    % tower-clock: unit gain
                     + sigHw_.^2;                                           % hardware delay: unit gain (non-dispersive)

                % Postfit consistency: computePostfitResiduals_ rebuilds h from
                % errStruct.modelTotal_m, so store the IF-COMBINED totals (first-order iono
                % cancelled: alpha*I + beta*I*(f1/f2)^2 = 0) rather than the L1-only values.
                % Otherwise the postfit reintroduces the single-frequency model ionosphere
                % and the reported postfit RMS is spuriously inflated (> prefit).
                modelTotal_if = [];
                truthTotal_if = [];
                if isfield(errStruct,'modelTotal_m') && numel(errStruct.modelTotal_m) >= 2*M_pairs_if
                    modelTotal_if = alpha_if * errStruct.modelTotal_m(idx1) + beta_if * errStruct.modelTotal_m(idx2);
                end
                if isfield(errStruct,'truthTotal_m') && numel(errStruct.truthTotal_m) >= 2*M_pairs_if
                    truthTotal_if = alpha_if * errStruct.truthTotal_m(idx1) + beta_if * errStruct.truthTotal_m(idx2);
                end

                [btIf_, bmIf_, bsIf_] = models.measurements.CodeMeasurementBuilder.combineIfSources_( ...
                    errStruct.bySource, idx1, idx2, alpha_if, beta_if, sigIonoHO_IF_);

                z = z_if;
                h = h_if;
                R_diag   = R_if;
                twr_list = twr_list(idx1);
                ant_list = ant_list(idx1);
                M        = M_pairs_if;
                N_sig    = 1;

                % Compress errStruct per-row fields to M_pairs IF rows
                ifTileFields = {'towerClockTruth_m','towerClockModel_m','towerClockModelSigma_m', ...
                    'towerClockProductEpoch_s','towerClockProductAge_s', ...
                    'sagnacTruth_m','sagnacModel_m','shapiroTruth_m','shapiroModel_m', ...
                    'pcvTruth_m','pcvModel_m','towerSurveyTruth_m','towerSurveyModel_m', ...
                    'receiverPCOTruth_m','receiverPCOModel_m','towerPCOTruth_m','towerPCOModel_m', ...
                    'elevations_rad','scintSigmaL1_m','sigmaExtra_m','sigmaTotal_m', ...
                    'truthTotal_m','modelTotal_m','signalIdx_perMeas','frequencyHz_perMeas'};
                for fi3 = 1:numel(ifTileFields)
                    fn = ifTileFields{fi3};
                    if isfield(errStruct,fn) && numel(errStruct.(fn)) >= M_pairs_if
                        errStruct.(fn) = errStruct.(fn)(idx1);
                    end
                end
                if isfield(errStruct,'signalName_perMeas') && numel(errStruct.signalName_perMeas) >= M_pairs_if
                    errStruct.signalName_perMeas = repmat({'IF'}, M_pairs_if, 1);
                end
                errStruct.bySource.truth_m = btIf_;
                errStruct.bySource.model_m = bmIf_;
                errStruct.bySource.sigma_m = bsIf_;
                % Override the idx1-compressed totals with the IF-combined values (above).
                if ~isempty(modelTotal_if); errStruct.modelTotal_m = modelTotal_if; end
                if ~isempty(truthTotal_if); errStruct.truthTotal_m = truthTotal_if; end
                errStruct.towerIdx_perMeas   = twr_list;
                errStruct.antennaIdx_perMeas = ant_list;
                errStruct.nPseudorange       = M;
                errStruct.ifCombination      = true;
            end

            % ----- Correlated noise + full R matrix -----------------------
            [z, R, correlNoise] = models.measurements.MeasurementModelUtils.correlatedNoise( ...
                cfg, rngCorr, z, R_diag, twr_list, M);
            errStruct.correlatedNoise = correlNoise;

            % Block covariance for shared tower clock product errors.
            % The same tower clock product error is common to all code rows that
            % reference the same tower at the same product epoch.  Treating it as
            % independent (diagonal-only) makes the EKF too confident.
            % Fix: R_ij += sigma_twr^2 for all (i,j) pairs from the same tower
            % (i != j only — diagonal already contains sigma_twr^2 from R_diag).
            % Result: R = diag(sigma_tracking^2) + sum_t(sigma_t^2 * ones(k_t))
            % which is symmetric positive definite whenever all sigma_tracking > 0.
            % Two INDEPENDENT reads, each with its OWN try/catch (D12). Sharing one try
            % meant that a cfg carrying sharedErrors.enable but missing
            % applyTowerClockToCode threw on the SECOND assignment and discarded the
            % FIRST too -- a missing leaf silently disabled the whole master, fail-open
            % toward the optimistic (lower) R. Record which leaf, if any, fell back.
            cbc_.configFallback = {};
            sharedErrEnable_ = true;
            try
                sharedErrEnable_ = logical(cfg.covariance.sharedErrors.enable);
            catch
                sharedErrEnable_ = false;
                cbc_.configFallback{end+1} = 'covariance.sharedErrors.enable missing -> false';
            end
            sharedErrCode_ = true;
            try
                sharedErrCode_ = logical(cfg.covariance.sharedErrors.applyTowerClockToCode);
            catch
                sharedErrCode_ = false;
                cbc_.configFallback{end+1} = 'covariance.sharedErrors.applyTowerClockToCode missing -> false';
            end
            if ~isempty(cbc_.configFallback)
                warning('CodeMeasurementBuilder:sharedErrorsConfigFallback', ...
                    'cfg.covariance.sharedErrors leaf missing, defaulted to false: %s', ...
                    strjoin(cbc_.configFallback, '; '));
            end
            % Atmosphere L1<->L2 common-mode block (below) has NOTHING to do with the
            % tower clock -- it was nested inside the applyTowerClockToCode gate purely
            % by accident of file history, so toggling applyTowerClockToCode also
            % silently deleted it (D12). Own leaf, default true so the default R is
            % unchanged; still under the sharedErrors MASTER (sharedErrEnable_).
            applyAtmosCommon_ = true;
            try
                applyAtmosCommon_ = logical(cfg.covariance.sharedErrors.applyAtmosphereCommonModeAcrossSignals);
            catch; end
            % ensureSPD (Diagnosis A #6): gates whether the jitter REPAIR is applied, not
            % whether the chol() diagnostic runs -- the diagnostic must always run so a
            % non-PD R is reported either way. Previously unread; a reviewer setting this
            % false to see whether R was genuinely PD always got a silently-repaired R.
            ensureSPD_ = true;
            try; ensureSPD_ = logical(cfg.covariance.sharedErrors.ensureSPD); catch; end
            cbc_.applied     = false;
            cbc_.nBlocks     = 0;
            cbc_.blockSizes  = zeros(0,1);
            cbc_.jitterAdded = false;
            cbc_.spd         = true;
            cbc_.spdGuardSuppressed = false;
            cbc_.atmosphereCommonModeApplied = false;
            cbc_.atmosphereCommonModeSources = {};
            cbc_.atmosphereCommonModeSuppressed = false;
            % Towers that actually RECEIVED an off-diagonal block, not merely those the gate
            % let through. cbc_.applied is set below whenever the gate passed, even if every
            % group hit numel(idx_) < 2 or sig_t_ <= 0 and nothing was written. The
            % code-carrier cross term in ProductClockCovarianceBuilder needs actual presence:
            % its rank-1 identity is only PSD if the code off-diagonal block is really there.
            cbc_.towersWithOffDiag = zeros(0,1);
            % Per-final-row tower-clock sigma AS INSTALLED (post state-mask). Published so the
            % cross-observable term is built from what R actually carries rather than from a
            % nominal recomputation. Always present, so consumers need no isfield dance.
            errStruct.towerClockSharedSigma_m = zeros(M,1);
            if sharedErrEnable_ && sharedErrCode_
                % Per-row tower clock sigma after multi-signal expansion
                sigTwr_ = zeros(M,1);
                if isfield(errStruct,'towerClockModelSigma_m') && ...
                        numel(errStruct.towerClockModelSigma_m) == M
                    sigTwr_ = errStruct.towerClockModelSigma_m;
                end
                % Same bias-state guard for the shared-tower off-diagonal block --
                % a tower whose bias is an EKF state must contribute no product-sigma
                % correlation here (its uncertainty is in P). twr_list is the post-expansion
                % per-row list; guard on column 1 (bias). No-op when estimateTowerClocks=false.
                sigTwr_ = models.measurements.CodeMeasurementBuilder.maskStateTowerSigma_( ...
                    sigTwr_, twr_list, stateMap, 1);
                errStruct.towerClockSharedSigma_m = sigTwr_;
                uniqT_ = unique(twr_list);
                for kt_ = 1:numel(uniqT_)
                    idx_ = find(twr_list == uniqT_(kt_));
                    if numel(idx_) < 2; continue; end
                    sig_t_ = mean(sigTwr_(idx_));
                    if sig_t_ <= 0; continue; end
                    % Off-diagonal only: diagonal already has sigma_twr^2 in R_diag
                    cov_add_ = sig_t_^2 * (ones(numel(idx_)) - eye(numel(idx_)));
                    R(idx_,idx_) = R(idx_,idx_) + cov_add_;
                    cbc_.nBlocks = cbc_.nBlocks + 1;
                    cbc_.blockSizes(end+1) = numel(idx_);
                    cbc_.towersWithOffDiag(end+1,1) = uniqT_(kt_);
                end
                cbc_.applied = true;
            end
            % ---- L1 <-> L2 atmospheric common mode ---------------------------------
            % D12: this used to be NESTED inside the tower-clock `if` above purely by
            % accident of file history -- a toggle named applyTowerClockToCode also
            % silently deleted a term that has nothing to do with the tower clock.
            % Own leaf (applyAtmosCommon_, default true -> default R unchanged), still
            % under the sharedErrors MASTER so a global opt-out still reaches it.
            %
            % The troposphere is copied VERBATIM onto every signal's row and the
            % first-order ionosphere is a fixed deterministic multiple of the L1 value
            % (freqScale), so the two rows of a (tower, antenna) pair carry the SAME
            % physical atmosphere at correlation rho = +1. With no off-diagonal the EKF
            % treats them as two independent samples and averages the atmosphere down
            % by sqrt(2) -- which it cannot do, because there is only one realisation.
            %
            % hwDelay belongs in this list for exactly the same reason, and was missing.
            % ErrorChain.hardwareDelay_ draws it with an EMPTY antenna argument, so
            % drawWhiteVec_ -> registry.epochStream(src, node, 0, 0, ep) returns a
            % bit-identical draw for every row of a tower; the builder then reuses hw_t
            % unchanged on every signal row (deliberately -- the dispersive part is the
            % separate DCB channel). So the signal rows of a pair carry ONE realisation at
            % rho = +1, exactly like the troposphere, while R charged them as independent.
            % The IF path already states the intended treatment ("passes the IF at unit
            % gain, NOT (alpha^2+beta^2)") and applies it; the raw dual-frequency path did
            % not. Scope: this block pairs rows across the SIGNAL axis only, so it closes
            % the sqrt(2) the EKF could take across L1/L2. The ANTENNA axis stays
            % uncorrelated in R for hwDelay and for trop/iono alike -- a pre-existing
            % limitation of this block, not one introduced here.
            %
            % For a fully correlated source, Cov(i,j) = sigma_s(i)*sigma_s(j). The iono
            % sigmas are already signal-scaled (see the per-signal swap above), so the
            % product carries the freqScale factor automatically. hwDelay is
            % non-dispersive and its sigma is tiled UNSCALED, which is the correct
            % unit-gain treatment for a common-mode term.
            %
            % Diagonal is untouched: R_diag already holds sigma_s^2 on each row.
            if sharedErrEnable_ && applyAtmosCommon_
                if N_sig > 1
                    smX_ = errStruct.bySource.sigma_m;
                    corrSrcs_ = {'trop','iono','hwDelay'};
                    M_pairs_x_ = round(M / N_sig);
                    for cs_ = 1:numel(corrSrcs_)
                        fn_ = corrSrcs_{cs_};
                        if ~isfield(smX_, fn_) || numel(smX_.(fn_)) ~= M; continue; end
                        sVec_ = smX_.(fn_)(:);
                        if ~any(sVec_ > 0); continue; end
                        for p_ = 1:M_pairs_x_
                            rows_ = p_ : M_pairs_x_ : M;      % same (tower,antenna), all signals
                            if numel(rows_) < 2; continue; end
                            s_ = sVec_(rows_);
                            blk_ = (s_ * s_') .* (ones(numel(rows_)) - eye(numel(rows_)));
                            R(rows_, rows_) = R(rows_, rows_) + blk_;
                        end
                        cbc_.atmosphereCommonModeSources{end+1} = fn_;
                    end
                    cbc_.atmosphereCommonModeApplied = ...
                        ~isempty(cbc_.atmosphereCommonModeSources);
                end
            elseif sharedErrEnable_ && N_sig > 1
                cbc_.atmosphereCommonModeSuppressed = true;
            end

            % SPD guard. The chol() DIAGNOSTIC always runs whenever either block above
            % could plausibly have touched R (mirrors the prior gate); ensureSPD_ governs
            % only whether the jitter REPAIR is applied (Diagnosis A #6) -- previously
            % unread, so disabling it never stopped the silent repair a reviewer wanted
            % to see through.
            if sharedErrEnable_ && (sharedErrCode_ || applyAtmosCommon_)
                jitter_m2_ = 1e-12;
                try; jitter_m2_ = cfg.covariance.sharedErrors.jitter_m2; catch; end
                [~, pfail_] = chol(R);
                if pfail_ ~= 0
                    if ensureSPD_
                        R = R + jitter_m2_ * eye(size(R,1));
                        cbc_.jitterAdded = true;
                        [~, pfail2_] = chol(R);
                        cbc_.spd = (pfail2_ == 0);
                    else
                        cbc_.spd = false;
                        cbc_.spdGuardSuppressed = true;
                        warning('CodeMeasurementBuilder:spdGuardSuppressed', ...
                            ['R failed the chol() SPD test and ensureSPD=false: the jitter ' ...
                             'repair was NOT applied. R remains non-positive-definite.']);
                    end
                else
                    cbc_.spd = true;
                end
            end
            errStruct.codeBlockCov = cbc_;

            % R validity guard
            rDiag = diag(R);
            if any(~isfinite(rDiag)) || any(rDiag <= 0)
                nBad = sum(~isfinite(rDiag) | rDiag <= 0);
                error('MeasurementModel:invalidR', ...
                    ['R has %d invalid diagonal values (NaN/Inf/<=0). ' ...
                     'Check cfg.errors.codeNoise.sigma_m, cfg.effects, and cfg.errors toggles.'], nBad);
            end
        end

        % ----------------------------------------------------------------
        function s = maskStateTowerSigma_(sigVec, towerList, stateMap, col)
            % maskStateTowerSigma_  Zero broadcast-product sigma entries for towers whose
            % clock quantity is an EKF state (double-count guard).
            %   col=1 -> tower BIAS state (stateMap.towerClockIdx(ti,1)>0)
            %   col=2 -> tower DRIFT state (stateMap.towerClockIdx(ti,2)>0)
            % When the quantity is a free state its uncertainty lives in P, so its product
            % sigma must not also enter R. Per-tower / per-column so gauge-reference towers
            % and non-estimated (towerClockIdx==0) towers correctly RETAIN their sigma (no
            % under-count). No-op (identity) when no tower clock states exist.
            s = sigVec;
            if isempty(sigVec) || ~isstruct(stateMap) || ~isfield(stateMap,'towerClockIdx') ...
                    || isempty(stateMap.towerClockIdx)
                return
            end
            nT = size(stateMap.towerClockIdx, 1);
            for k = 1:numel(towerList)
                ti = towerList(k);
                if ti >= 1 && ti <= nT && stateMap.towerClockIdx(ti, col) > 0
                    s(k) = 0;
                end
            end
        end

        % ----------------------------------------------------------------
        function v = higherOrderIonoAtFrequency_(cfg, sourceL1_m, ionoL1_slant_m, freqHz, f_L1)
            % higherOrderIonoAtFrequency_  Re-evaluate the configured f^-3/f^-4 model.
            v = zeros(size(sourceL1_m));
            if isempty(sourceL1_m) || all(sourceL1_m == 0)
                return
            end
            try
                ho = cfg.errors.ionosphere.higherOrder;
                if ~isfield(ho,'enable') || ~ho.enable
                    return
                end
                v = models.errors.HigherOrderIonosphere.totalDelay( ...
                    ionoL1_slant_m(:), freqHz, f_L1, ho);
                v = reshape(v, size(sourceL1_m));
                v(sourceL1_m == 0) = 0;
            catch ME_hoIono_
                % D12: silent MODEL SUBSTITUTION, not a deletion -- if the configured
                % higher-order model throws, both truth and model quietly switch to a
                % hard-coded pure f^-3 law that was never requested, making any
                % higher-order-ionosphere ablation unverifiable. persistent one-shot
                % warning (this runs per-row, per-epoch; do not flood the log).
                persistent warnedHO_
                if isempty(warnedHO_); warnedHO_ = false; end
                if ~warnedHO_
                    warning('CodeMeasurementBuilder:higherOrderIonoFallback', ...
                        ['Configured higher-order ionosphere model failed (%s); using the ' ...
                         'fixed f^-3 approximation instead for the rest of this run.'], ...
                        ME_hoIono_.identifier);
                    warnedHO_ = true;
                end
                v = sourceL1_m .* (f_L1 ./ freqHz).^3;
            end
        end

        % ----------------------------------------------------------------
        function s = higherOrderIonoSigmaAtFrequency_(cfg, sigmaL1_m, ionoL1_slant_m, freqHz, f_L1)
            % higherOrderIonoSigmaAtFrequency_  Sigma follows the same signed source path.
            if isempty(sigmaL1_m) || all(sigmaL1_m == 0)
                s = zeros(size(sigmaL1_m));
                return
            end
            signed = models.measurements.CodeMeasurementBuilder.higherOrderIonoAtFrequency_( ...
                cfg, sigmaL1_m, abs(ionoL1_slant_m), freqHz, f_L1);
            if any(signed ~= 0)
                s = abs(signed);
            else
                s = abs(sigmaL1_m) .* abs(f_L1 ./ freqHz).^3;
            end
        end

        % ----------------------------------------------------------------
        function [btIf, bmIf, bsIf] = combineIfSources_(bySource, idx1, idx2, alpha, beta, sigIonoHO_IF)
            btIf = models.measurements.CodeMeasurementBuilder.combineIfValueStruct_( ...
                bySource.truth_m, idx1, idx2, alpha, beta);
            bmIf = models.measurements.CodeMeasurementBuilder.combineIfValueStruct_( ...
                bySource.model_m, idx1, idx2, alpha, beta);
            bsIf = struct();
            sigFields = fieldnames(bySource.sigma_m);
            for k = 1:numel(sigFields)
                fn = sigFields{k};
                v = bySource.sigma_m.(fn);
                if isempty(v)
                    bsIf.(fn) = v;
                    continue
                end
                if numel(v) < max(idx2)
                    bsIf.(fn) = v(1:min(numel(v), numel(idx1)));
                    continue
                end
                s1 = v(idx1);
                s2 = v(idx2);
                switch fn
                    case {'trop','hwDelay'}
                        bsIf.(fn) = abs(alpha * s1 + beta * s2);
                    case 'iono'
                        bsIf.(fn) = zeros(size(s1));
                    case 'ionoHO'
                        bsIf.(fn) = sigIonoHO_IF;
                    otherwise
                        bsIf.(fn) = sqrt(alpha^2 * s1.^2 + beta^2 * s2.^2);
                end
            end
        end

        % ----------------------------------------------------------------
        function zwd_m = towerZwd_(errorChain, towerIdx)
            % towerZwd_  This tower's climatological zenith wet delay [m], or [].
            %
            % Feeds gaseous absorption's water-vapour column so it uses the SAME humidity
            % the troposphere uses at this site, rather than the frozen ITU-R P.676
            % table's P.835 reference. Returns [] when there is no environment model to
            % ask, in which case the reference is assumed and the caller is unchanged.
            zwd_m = [];
            if isempty(errorChain) || ~isprop(errorChain, 'envModel') || isempty(errorChain.envModel)
                return;
            end
            zwd_m = errorChain.envModel.zenithWetDelay_m(towerIdx);
        end

        function [truth_m, model_m] = codeDcbForSignal_(cfg, signalName)
            truth_m = models.measurements.CodeMeasurementBuilder.oneCodeDcb_(cfg, 'truth', signalName);
            model_m = models.measurements.CodeMeasurementBuilder.oneCodeDcb_(cfg, 'model', signalName);
        end

        % ----------------------------------------------------------------
        function v = oneCodeDcb_(cfg, side, signalName)
            v = 0;
            if isstring(signalName); signalName = char(signalName); end
            if ~ischar(signalName) || isempty(signalName)
                return
            end
            fld = sprintf('%s_m', signalName);
            try
                b = cfg.biases.interFrequency.code.(side);
                if isfield(b, fld)
                    v = b.(fld);
                elseif isfield(b, signalName)
                    v = b.(signalName);
                end
            catch
                v = 0;
            end
            if ~isnumeric(v) || ~isscalar(v) || ~isfinite(v)
                v = 0;
            end
        end

        % ----------------------------------------------------------------
        function out = combineIfValueStruct_(src, idx1, idx2, alpha, beta)
            out = struct();
            fns = fieldnames(src);
            for k = 1:numel(fns)
                fn = fns{k};
                v = src.(fn);
                if isempty(v)
                    out.(fn) = v;
                elseif numel(v) >= max(idx2)
                    out.(fn) = alpha * v(idx1) + beta * v(idx2);
                elseif numel(v) >= numel(idx1)
                    out.(fn) = v(idx1);
                else
                    out.(fn) = v;
                end
            end
        end

    end  % Static methods
end

function v = i_sigSq(errStruct, fname, idx)
% i_sigSq  Squared per-source sigma at one row, 0 when the source is absent.
%   Used only by the gated code-R budget accounting.
    v = 0;
    if isfield(errStruct,'bySource') && isfield(errStruct.bySource,'sigma_m') && ...
            isfield(errStruct.bySource.sigma_m, fname)
        x = errStruct.bySource.sigma_m.(fname);
        if numel(x) >= idx; v = x(idx)^2; end
    end
end
