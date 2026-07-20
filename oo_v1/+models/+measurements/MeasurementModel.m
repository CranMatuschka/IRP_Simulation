classdef MeasurementModel < handle
    % MeasurementModel  Pseudorange measurement equations for reverse-GNSS.
    %
    % Responsibilities:
    %   - Compute truth pseudorange z from truth state + ErrorChain + effects
    %   - Compute predicted pseudorange h from estimated state
    %   - Compute measurement Jacobian H (analytic or finite-difference)
    %   - Compute visibility mask (elevation filter)
    %   - Assemble measurement covariance R (diagonal or correlated)
    %
    % -----------------------------------------------------------------------
    % TRUTH/MODEL SEPARATION
    %
    % Truth measurement:
    %   z_i = rho_ant_true_i + b_rx_true - b_twr_true_i + eps_chain_i
    %         + truth-side corrections (Sagnac, Shapiro, PCO, PCV, survey)
    %
    % Predicted measurement:
    %   h_i = rho_ant_est_i  + b_rx_est  - b_twr_model_i + model_chain_i
    %         + model-side corrections
    %
    % Truth effects affect z only; model effects affect h (and H via FD when enabled).
    % If truth=true and model=false, innovation shows the mismatch deterministically.
    %
    % Tower clock corrections are computed ONCE per epoch (at the start of
    % computeMeasurements) and stored in errStruct to prevent repeated noise draws.
    %
    % -----------------------------------------------------------------------
    % JACOBIAN
    %   Default (no corrections): analytic  H(r_idx) = u'
    %   Any model-side correction on: finite-difference H(r_idx) and H(euler_idx)
    %   cfg.estimator.forceFiniteDifferenceH = true: always use FD
    %   Clock columns: b_rx = +1, tower clock = -1 (always analytic)
    %   Doppler columns: H_v = u', H_bdot = 1 (always analytic)

    properties
        cfg             (1,1) struct
        errorChain      models.errors.ErrorChain
        elevMask_rad    (1,1) double = 5 * pi/180
        attitudeJacStep_rad (1,1) double = 1e-6
        ambiguityMap                       % containers.Map: (tower*1000+antenna) → integer N (diagnostic)
        floatAmbiguityTruth_m              % containers.Map: (tower*1000+ant) → float B_phi [m] (ekfFloat)
        rngCorr                            % RandStream for correlated noise
    end

    methods
        function obj = MeasurementModel(cfg, errorChain)
            if nargin == 0; return; end
            obj.cfg          = cfg;
            obj.errorChain   = errorChain;
            obj.ambiguityMap = [];
            if isfield(cfg,'elevationMask_rad')
                obj.elevMask_rad = cfg.elevationMask_rad;
            end
            if isfield(cfg.estimator,'attitudeJacobianStep_rad')
                obj.attitudeJacStep_rad = cfg.estimator.attitudeJacobianStep_rad;
            end
            % Correlated noise RNG
            if isfield(cfg,'effects') && isfield(cfg.effects,'correlatedNoise') && ...
                    isfield(cfg.effects.correlatedNoise,'seed')
                obj.rngCorr = RandStream('mt19937ar','Seed', cfg.effects.correlatedNoise.seed);
            end
        end

        % ----------------------------------------------------------------
        function [visible, elevations_rad] = computeVisibility(obj, towers, r_ant_ecef_m)
            % computeVisibility  Return logical mask and elevation angles.
            N = numel(towers);
            elevations_rad = zeros(N,1);
            for k = 1:N
                elevations_rad(k) = models.frames.GeometryUtils.elevationAngle( ...
                    towers{k}.r_ecef_m, r_ant_ecef_m);
            end
            visible = elevations_rad >= obj.elevMask_rad;
        end

        % ----------------------------------------------------------------
        function [z, h, H, R, errStruct] = computeMeasurements(obj, ...
                asset, towers, x_est, t_s, stateMap, assetIdx)
            % computeMeasurements  Main measurement function (multi-antenna capable).
            %
            % Loops over all visible (tower, antenna) pairs.  Default config has
            % N_ant=1 with a zero lever arm, recovering the single-antenna case.
            %
            % assetIdx (optional, default 1): which satellite this call measures (chief=1).
            % Phase 3b-1: per-asset indices are resolved via AssetStateBlock.forAsset and threaded
            % down to the Code/Carrier builders; at assetIdx=1 the block aliases the chief stateMap
            % fields exactly, so this is byte-identical.
            if nargin < 7 || isempty(assetIdx); assetIdx = 1; end
            blk = revgnss.AssetStateBlock.forAsset(stateMap, assetIdx);

            % ----- All lever arms (3 x N_ant) --------------------------
            leverArms = asset.receiverLeverArms_body_m;
            N_ant = size(leverArms, 2);

            % ----- Truth state -----------------------------------------
            r_cm_true  = asset.r_ecef_m;
            euler_true = asset.attitude_euler_rad;

            % ----- EKF state extraction --------------------------------
            r_est     = x_est(blk.r);
            euler_est = revgnss.AssetStateBlock.eulerEst(blk, x_est);

            % ----- Effective lever arms with PCO offset ----------------
            % receiverOffset_body_m is extra common body-frame offset
            % added to all antennas on truth/model side independently.
            leverArms_truth = leverArms;
            leverArms_model = leverArms;
            if isfield(obj.cfg,'effects') && isfield(obj.cfg.effects,'antennaPCO')
                pco = obj.cfg.effects.antennaPCO;
                if isfield(pco,'truth') && pco.truth.enable
                    off = pco.receiverOffset_body_m(:);
                    % Optional gated truth-only PCO calibration residual -- an antenna
                    % phase-centre mis-calibration the estimator does NOT know (the model side
                    % below is unchanged), so it survives z-h as a real imperfection rather than
                    % cancelling. Default off -> off unchanged -> golden byte-identical.
                    if isfield(pco,'calibrationResidual') && isfield(pco.calibrationResidual,'enable') && ...
                            pco.calibrationResidual.enable && isfield(pco.calibrationResidual,'receiverOffset_body_m')
                        off = off + pco.calibrationResidual.receiverOffset_body_m(:);
                    end
                    leverArms_truth = leverArms + off * ones(1, N_ant);
                end
                if isfield(pco,'model') && pco.model.enable
                    off = pco.receiverOffset_body_m(:);
                    leverArms_model = leverArms + off * ones(1, N_ant);
                end
            end

            % ----- Truth and estimated antenna positions ---------------
            r_ants_truth = asset.getAntennaPositionsECEF(r_cm_true, euler_true, leverArms_truth);
            r_ants_est   = asset.getAntennaPositionsECEF(r_est,     euler_est,  leverArms_model);

            nx    = numel(x_est);
            N_twr = numel(towers);

            % ----- Build (tower, antenna) pair visibility list ---------
            twr_list = zeros(N_twr * N_ant, 1);
            ant_list = zeros(N_twr * N_ant, 1);
            elv_list = zeros(N_twr * N_ant, 1);
            cnt = 0;
            for ti = 1:N_twr
                r_twr_nom = towers{ti}.getAntennaPositionECEF();
                for ai = 1:N_ant
                    elv = models.frames.GeometryUtils.elevationAngle(r_twr_nom, r_ants_truth(:,ai));
                    if elv >= obj.elevMask_rad
                        cnt = cnt + 1;
                        twr_list(cnt) = ti;
                        ant_list(cnt) = ai;
                        elv_list(cnt) = elv;
                    end
                end
            end
            twr_list = twr_list(1:cnt);
            ant_list = ant_list(1:cnt);
            elv_list = elv_list(1:cnt);
            M = cnt;

            if M == 0
                z = []; h = []; H = zeros(0,nx); R = []; errStruct = [];
                return
            end

            % ----- Error chain (per measurement) -----------------------
            towerIds = arrayfun(@(ti) towers{ti}.id, twr_list);
            % Pass ant_list so coloured multipath can key its GM state per link.
            errStruct = obj.errorChain.compute(elv_list, towerIds, twr_list, t_s, ant_list);

            % ----- Tower clock corrections — generated ONCE per epoch --
            [towerClkTruth, towerClkModel, towerClkSigma, corrNoise_m, t_prod, towerClkMode] = ...
                models.clocks.TowerClockCorrectionProvider.compute( ...
                    obj.cfg, obj.errorChain, towers, twr_list, t_s);

            errStruct.towerClockTruth_m      = towerClkTruth;
            errStruct.towerClockModel_m      = towerClkModel;
            errStruct.towerClockModelSigma_m = towerClkSigma;
            errStruct.towerIdx_perMeas       = twr_list;
            errStruct.antennaIdx_perMeas     = ant_list;
            errStruct.nPseudorange           = M;   % 0.4: for postfit split

            % CHANGED: v3→v4 — Issue 6: extended product correction cache.
            % Postfit recomputation must reuse exactly these values (not re-query or re-draw).
            errStruct.towerClockCorrection_m      = towerClkModel;    % correction applied
            errStruct.towerClockCorrectionSigma_m = towerClkSigma;    % sigma used in R
            errStruct.towerClockCorrNoise_m       = corrNoise_m;      % noise realization

            errStruct.towerClockProductEpoch_s = t_prod;
            errStruct.towerClockProductAge_s   = t_s - t_prod;

            % ----- Code/pseudorange measurements ----------------------
            [z, h, R, errStruct, twr_list, ant_list, M, N_sig] = ...
                models.measurements.CodeMeasurementBuilder.build( ...
                    obj.cfg, obj.errorChain, obj.rngCorr, asset, towers, ...
                    twr_list, ant_list, elv_list, leverArms, leverArms_model, ...
                    r_ants_truth, r_ants_est, x_est, stateMap, ...
                    towerClkTruth, towerClkModel, towerClkSigma, towerClkMode, t_prod, ...
                    errStruct, t_s, assetIdx);


            % ----- Jacobian H (pseudorange) ----------------------------
            H_pr = models.measurements.CodeJacobianBuilder.build( ...
                obj.cfg, obj.attitudeJacStep_rad, towers, twr_list, ant_list, ...
                r_est, euler_est, leverArms_model, x_est, stateMap, nx, assetIdx);

            % ZWD Jacobian columns (perTowerZwd): H(mi, zwdIdx(ti)) = mf(elv)
            if isfield(stateMap,'zwdIdx') && ~isempty(blk.zwd)
                mfKind = models.measurements.MeasurementModelUtils.zwdMappingKind(obj.cfg);
                for mi_z = 1:M
                    ti_z = twr_list(mi_z);
                    if ti_z <= numel(blk.zwd) && blk.zwd(ti_z) > 0
                        mf_z = models.atmosphere.MappingFunctions.troposphere( ...
                            errStruct.elevations_rad(mi_z), mfKind);
                        H_pr(mi_z, blk.zwd(ti_z)) = mf_z;
                    end
                end
            end

            % Slant-iono Jacobian columns (perTowerSlant): H(mi, ionoIdx(ti)) = (f_L1/f_row)^2
            % Code group delay is +iono, so the code partial is the positive 1/f^2 dispersion.
            % Guard on dispersion (>=2 frequencies): CodeMeasurementBuilder adds the iono
            % STATE to h ONLY in the multi-signal path, and with a single frequency the iono
            % is unobservable (it aliases with the receiver clock). Setting H without the
            % matching h term would be an H/h mismatch; with L1 only, neither is set and the
            % iono is (correctly) absorbed by the clock. No effect on the default L1+L2
            % estimateIono path (dispersion present) or the golden (no iono state).
            hasDispersion_io = false;
            try; hasDispersion_io = revgnss.SignalConfigResolver.hasL2(obj.cfg); catch; end
            if hasDispersion_io && isfield(stateMap,'ionoIdx') && ~isempty(blk.iono) && any(blk.iono > 0)
                f_L1_io = revgnss.SignalDefinition.get('L1').frequency_Hz;
                if isfield(obj.cfg,'signals') && isfield(obj.cfg.signals,'L1') && ...
                        isfield(obj.cfg.signals.L1,'frequency_Hz')
                    f_L1_io = obj.cfg.signals.L1.frequency_Hz;
                end
                for mi_i = 1:M
                    ti_i = twr_list(mi_i);
                    if ti_i <= numel(blk.iono) && blk.iono(ti_i) > 0
                        f_row = f_L1_io;
                        if isfield(errStruct,'frequencyHz_perMeas') && mi_i <= numel(errStruct.frequencyHz_perMeas)
                            f_row = errStruct.frequencyHz_perMeas(mi_i);
                        end
                        H_pr(mi_i, blk.iono(ti_i)) = (f_L1_io / f_row)^2;
                    end
                end
            end

            % ----- Doppler rows (0.5 + 0.6) ----------------------------
            [dopplerRows, dopplerInfo] = models.measurements.DopplerMeasurementBuilder.build( ...
                obj.cfg, obj.errorChain, asset, towers, twr_list, ant_list, ...
                r_ants_truth, r_ants_est, x_est, stateMap, towerClkMode, t_s, assetIdx);
            errStruct.doppler = dopplerInfo;
            if dopplerRows.ionoRateExclusion
                H = H_pr;
                return
            end
            if dopplerRows.useInEKF && ~isempty(dopplerRows.z)
                z    = [z;    dopplerRows.z];
                h    = [h;    dopplerRows.h];
                H_pr = [H_pr; dopplerRows.H];
                if size(R,1) == M
                    R = blkdiag(R, dopplerRows.R);
                else
                    R = diag([diag(R); diag(dopplerRows.R)]);
                end
            end

            H = H_pr;

            % ----- Carrier phase (ekfFloat or diagnostic) --------------
            carrierMode_v = 'none';
            if isfield(obj.cfg,'measurements')
                if isfield(obj.cfg.measurements,'carrierMode')
                    carrierMode_v = obj.cfg.measurements.carrierMode;
                elseif isfield(obj.cfg.measurements,'carrierPhase') && ...
                        isfield(obj.cfg.measurements.carrierPhase,'enable') && ...
                        obj.cfg.measurements.carrierPhase.enable
                    carrierMode_v = 'diagnostic';
                end
            end

            M_pairs_c = round(M / max(N_sig, 1));

            switch carrierMode_v
                case 'ekfFloat'
                    if isempty(obj.floatAmbiguityTruth_m)
                        obj.floatAmbiguityTruth_m = containers.Map('KeyType','int32','ValueType','double');
                    end
                    [z_phi, h_phi, H_phi, R_phi, cpInfo] = models.measurements.CarrierMeasurementBuilder.buildEkfRows( ...
                        obj.cfg, obj.errorChain, obj.floatAmbiguityTruth_m, ...
                        asset, towers, twr_list(1:M_pairs_c), ant_list(1:M_pairs_c), ...
                        r_ants_truth, r_ants_est, leverArms_model, x_est, stateMap, nx, ...
                        errStruct, towerClkTruth, towerClkModel, towerClkSigma, t_s, assetIdx);
                    if ~isempty(z_phi)
                        z = [z; z_phi];
                        h = [h; h_phi];
                        H = [H; H_phi];
                        R = blkdiag(R, R_phi);
                    end
                    errStruct.carrierPhase = cpInfo;

                case 'diagnostic'
                    doCpCfg = isfield(obj.cfg.measurements,'carrierPhase') && ...
                              isfield(obj.cfg.measurements.carrierPhase,'enable') && ...
                              obj.cfg.measurements.carrierPhase.enable;
                    if doCpCfg
                        % carrierMode='diagnostic': carrier for diagnostics only.
                        % finalizeConfig resets legacy useInEKF=true to false when
                        % carrierMode is set. MeasurementModel does not re-check it.
                        [errStruct.carrierPhase, obj.ambiguityMap] = ...
                            models.measurements.CarrierMeasurementBuilder.buildDiagnostic( ...
                                obj.cfg, obj.errorChain, obj.ambiguityMap, ...
                                asset, towers, twr_list, ant_list, r_ants_truth);
                    else
                        errStruct.carrierPhase = struct();
                    end

                otherwise  % 'none' or unknown
                    errStruct.carrierPhase = struct();
            end

            % Restore cross-observable covariance for shared clock
            % product errors after code/Doppler/carrier rows have been stacked.
            [R, stackCovInfo] = models.clocks.ProductClockCovarianceBuilder.addSharedProductClockStack( ...
                R, errStruct, obj.cfg);
            errStruct.productClockStackCov = stackCovInfo;

            % ----- Stack metadata and observability --------------------
            errStruct = revgnss.MeasurementStackMetadata.annotate( ...
                obj.cfg, H, M, errStruct, stateMap);
        end

        % ----------------------------------------------------------------
        function h_pr = computePseudorangeModelOnly(obj, asset, towers, x_state, errStruct, stateMap, t_s)
            % computePseudorangeModelOnly  Thin wrapper — implementation in PseudorangeModelOnlyBuilder.
            if nargin < 7 || isempty(t_s); t_s = 0; end
            h_pr = revgnss.PseudorangeModelOnlyBuilder.compute( ...
                obj.cfg, asset, towers, x_state, errStruct, stateMap, t_s);
        end

        % ----------------------------------------------------------------
        function h_phi = computeCarrierModelOnly(obj, asset, towers, x_state, errStruct, stateMap, t_s)
            % computeCarrierModelOnly  Thin wrapper — implementation in CarrierModelOnlyBuilder.
            if nargin < 7 || isempty(t_s); t_s = 0; end
            h_phi = revgnss.CarrierModelOnlyBuilder.compute( ...
                obj.cfg, asset, towers, x_state, errStruct, stateMap, t_s);
        end

        % ----------------------------------------------------------------
        function [zAdd, hAdd, HAdd, RAdd, info] = computeSecondaryGroundRows(obj, ...
                assets, towers, x, stateMap, nx, t_s)
            % computeSecondaryGroundRows  Tower->secondary ground pseudorange + carrier rows.
            %
            % Phase 3b-2: folds revgnss.SecondaryGroundMeasurementBuilder into the shared
            % measurement class -- reproducing its rows EXACTLY, but sourcing per-asset state
            % indices via revgnss.AssetStateBlock, per-asset behaviour via
            % models.measurements.SecondaryMeasurementProfile, and Guard-A atmosphere via
            % models.atmosphere.SecondaryUplinkAtmosphere. Reverse-GNSS (tower TRANSMITS, secondary
            % RECEIVES) -> H(b_tx)=+1; NO primary-state columns (empty at nSpaceAssets=1). Emits
            % [all secondary CODE rows] then [all secondary CARRIER rows] (grouped, not interleaved
            % -- the batch update S=HPH'+R is not row-order-invariant). Bit-identical to the retired
            % builder (parallel-diff gated in runEstimation_, §15 C3).
            if nargin < 7; t_s = 0; end
            ec = obj.errorChain;
            g  = @(pth, d) models.measurements.MeasurementModel.secGetNum_(obj.cfg, pth, d);
            gb = @(pth)    models.measurements.MeasurementModel.secGetBool_(obj.cfg, pth, false);

            info = struct('enabled', false, 'nRows', 0, 'rowAsset', [], 'rowTower', [], 'prefitRms', NaN);
            zAdd = []; hAdd = []; HAdd = zeros(0, nx); RAdd = zeros(0, 0);

            % Gate: WP5 on AND WP3 secondary-clock states present (mirrors the retired builder).
            nSec = revgnss.MultiAssetConfig.groundSecondaryRowCount(obj.cfg);
            if nSec < 1 || ~isfield(stateMap, 'secondaryClockIdx') || isempty(stateMap.secondaryClockIdx)
                return;
            end
            info.enabled = true;

            elevMask = g({'estimator','elevationMask_rad'}, 5*pi/180);
            dt       = g({'simulation','dt_s'}, 1);
            epochIdx = 0; if dt > 0; epochIdx = round(t_s / dt); end
            elvFloor = revgnss.Constants.ELEVATION_FLOOR_RAD;

            % Guard-A atmosphere detail params (mode chosen by the profile per asset below).
            aTropZen = g({'multiAsset','towerSecondary','atmosphere','sigmaTropZen_m'}, 0.05);
            aIonoZen = g({'multiAsset','towerSecondary','atmosphere','sigmaIonoZen_m'}, 0.20);
            aTauTrop = g({'multiAsset','towerSecondary','atmosphere','tauTrop_s'}, 1800);
            aTauIono = g({'multiAsset','towerSecondary','atmosphere','tauIono_s'}, 600);
            aShellH  = g({'multiAsset','towerSecondary','atmosphere','ionoShellHeight_m'}, 350e3);
            aNCap    = g({'multiAsset','towerSecondary','atmosphere','nCorrCap'}, 60);
            aChargeR = gb({'multiAsset','towerSecondary','atmosphere','chargeR'});

            carrierOn = revgnss.MultiAssetConfig.secondaryCarrierCount(obj.cfg) > 0;

            nAssets = numel(assets);
            % RngRegistry node is 16-bit (mod 65536); the secondary node encoding is ti*32+ai.
            if numel(towers) * 32 + nAssets >= 65536
                error('MeasurementModel:secondaryNodeBudget', ...
                    ['tower*32+asset node exceeds the 16-bit RngRegistry budget ' ...
                     '(towers=%d, assets=%d) -- secondary draws would collide.'], numel(towers), nAssets);
            end
            rowAsset = []; rowTower = [];
            % Row blocks are grouped, NOT interleaved (the batch update S=HPH'+R is not row-order-
            % invariant): [all CODE] then [all DOPPLER] then [all CARRIER]. Doppler + carrier are
            % collected separately here and appended after all code rows.
            zCar = []; hCar = []; HCar = zeros(0, nx); RCar = zeros(0,0); carAsset = []; carTower = [];
            zDop = []; hDop = []; HDop = zeros(0, nx); RDop = zeros(0,0); dopAsset = []; dopTower = [];
            for ai = 2:nAssets
                si = ai - 1;
                if si > size(stateMap.secondaryClockIdx, 1); continue; end
                blk = revgnss.AssetStateBlock.forAsset(stateMap, ai);
                bTxIdx = blk.b;
                if isempty(bTxIdx) || bTxIdx <= 0; continue; end

                p        = models.measurements.SecondaryMeasurementProfile.forAsset(obj.cfg, ai);
                sigma    = p.code.flatSigma_m;
                nCorr    = max(1, p.rPad.nCorr);
                twClkSig = p.rPad.towerClkSigma_m;
                Rprod    = nCorr * (p.rPad.productSigmaPos_m^2 + twClkSig^2);
                atmoOn   = strcmp(p.atmosphereMode, 'guardAUplink');
                sigmaCarr = p.carrier.sigma_m; ambStd = p.carrier.ambStd_m; lambda = p.carrier.lambda_m;
                Rtwr     = nCorr * twClkSig^2;

                sec       = assets{ai};
                rSecTruth = sec.getAntennaPositionECEF();
                orbPosIdx = blk.r;    % [3x1] estimated-position indices (position mode), or [] (clocks mode)
                if ~isempty(orbPosIdx)
                    rSecModel = x(orbPosIdx); rSecModel = rSecModel(:);
                    RprodRow  = sigma^2;
                else
                    pb        = revgnss.ISLMeasurementBuilder.productBiasForAsset(obj.cfg, ai, t_s);
                    rSecModel = rSecTruth + pb.pos;
                    RprodRow  = sigma^2 + Rprod;
                end
                bTxTruth = sec.clock.getBiasMeters();

                % Phase 3b-3 Axis 4: secondary Doppler is emitted only in position mode (needs the
                % velocity state blk.v). vSecTruth/bDotTruth are the truth range-rate + clock-drift.
                emitDop = p.emitDoppler && ~isempty(blk.v);
                if emitDop
                    vSecTruth = sec.v_ecef_mps;
                    vSecModel = x(blk.v); vSecModel = vSecModel(:);
                    bDotTruth = sec.clock.getDriftMetersPerSecond();
                    sigmaDop  = p.doppler.sigma_mps;
                    RdopPad   = nCorr * p.doppler.towerClkDriftSigma_mps^2;   % matched tower-drift pad (mirrors the bias pad)
                end

                for ti = 1:numel(towers)
                    elev = towers{ti}.computeElevationTo(rSecTruth);
                    if ~(elev >= elevMask); continue; end
                    rTwrT = models.measurements.MeasurementModelUtils.towerPositionEcef(obj.cfg, towers{ti}, ti, 'truth', t_s);
                    rTwrM = models.measurements.MeasurementModelUtils.towerPositionEcef(obj.cfg, towers{ti}, ti, 'model');
                    [rhoT, ~] = models.corrections.RangeCorrections.correctedPseudorange(rSecTruth, rTwrT, obj.cfg, 'truth', elev, t_s);
                    [rhoM, ~] = models.corrections.RangeCorrections.correctedPseudorange(rSecModel, rTwrM, obj.cfg, 'model', elev, t_s);
                    bTwr = towers{ti}.getClockBiasMeters();                % matched tower clock (mean)
                    node = ti*32 + ai;                                     % packed into the mod-65536 node field
                    nz   = sigma * ec.drawKeyed(p.code.source, node, 0, 1, epochIdx, 1, 1);
                    dAtmo = 0; Ratmo = 0;
                    if atmoOn && dt > 0
                        [dAtmo, Ratmo] = models.atmosphere.SecondaryUplinkAtmosphere.losUplink( ...
                            ec, ti, elev, t_s, dt, elvFloor, aTropZen, aIonoZen, aTauTrop, aTauIono, aShellH, aNCap, aChargeR);
                    end
                    z = rhoT + bTxTruth  - bTwr + nz + dAtmo;
                    h = rhoM + x(bTxIdx) - bTwr;
                    Rii = RprodRow + Ratmo;
                    row = zeros(1, nx); row(bTxIdx) = 1;                   % receiver clock -> +1
                    if ~isempty(orbPosIdx)
                        d = rSecModel - rTwrM; nd = norm(d); if nd < 1; nd = 1; end
                        row(orbPosIdx) = (d / nd)';                        % dh/dr_sec = +u_ts'
                    end
                    if ~isempty(blk.zwd) && ti <= numel(blk.zwd)
                        zwdIdx = blk.zwd(ti);
                        if zwdIdx > 0
                            m_w = 1 / max(sin(elev), sin(elvFloor));
                            h = h + m_w * x(zwdIdx);
                            row(zwdIdx) = m_w;
                        end
                    end
                    zAdd(end+1,1) = z;      %#ok<AGROW>
                    hAdd(end+1,1) = h;      %#ok<AGROW>
                    HAdd(end+1,:) = row;    %#ok<AGROW>
                    RAdd = blkdiag(RAdd, Rii);
                    rowAsset(end+1) = ai;   %#ok<AGROW>
                    rowTower(end+1) = ti;   %#ok<AGROW>

                    % Phase 3b-3 Axis 4: tower->secondary Doppler row (range-rate). Reuses the chief
                    % OneWayRangeRateModel with the secondary r/v; matched tower-clock DRIFT (mean-
                    % cancels, like the bias); H on velocity (u_los') + secondary clock-drift (+1).
                    % R = sigma_dop^2 + matched-drift pad (block-diagonal -> never shrinks legacy R).
                    if emitDop
                        [rhoDotT, ~]    = revgnss.OneWayRangeRateModel.compute(rSecTruth, vSecTruth, rTwrT, obj.cfg);
                        [rhoDotM, uLos] = revgnss.OneWayRangeRateModel.compute(rSecModel, vSecModel, rTwrM, obj.cfg);
                        twrDrift = towers{ti}.getClockDriftMetersPerSecond();
                        nzd  = sigmaDop * ec.drawKeyed(p.doppler.source, node, 0, 1, epochIdx, 1, 1);
                        rowd = zeros(1, nx);
                        rowd(blk.v)    = uLos';           % d(rhoDot)/dv = u_los'
                        rowd(blk.bdot) = 1;               % receiver clock drift -> +1
                        % d(rhoDot)/dr position partial. The chief OMITS this (negligible for a
                        % well-observed chief position), but the SECONDARY position is wall-limited /
                        % poorly observed, so the range-rate innovation is position-DRIVEN (via the
                        % LOS + Sagnac geometry). Without this column the filter mis-attributes that
                        % position error to velocity/drift and corrupts them. blk.r is non-empty here
                        % (emitDop already required ~isempty(blk.v) => position mode).
                        rowd(blk.r) = revgnss.OneWayRangeRateModel.positionPartial(rSecModel, vSecModel, rTwrM, obj.cfg);
                        zDop(end+1,1) = rhoDotT + bDotTruth   - twrDrift + nzd; %#ok<AGROW>
                        hDop(end+1,1) = rhoDotM + x(blk.bdot) - twrDrift;       %#ok<AGROW>
                        HDop(end+1,:) = rowd;                                   %#ok<AGROW>
                        RDop = blkdiag(RDop, sigmaDop^2 + RdopPad);
                        dopAsset(end+1) = ai;   %#ok<AGROW>
                        dopTower(end+1) = ti;   %#ok<AGROW>
                    end

                    if carrierOn && ~isempty(orbPosIdx) && ~isempty(blk.ambiguity) && ti <= numel(blk.ambiguity)
                        ambIdx = blk.ambiguity(ti);
                        if ambIdx > 0
                            nCyc  = round((ambStd / lambda) * ec.drawKeyedInterval(p.carrier.ambSource, node, 0, 0, 0));
                            Btrue = nCyc * lambda;
                            nzc   = sigmaCarr * ec.drawKeyed(p.carrier.phaseSource, node, 0, 1, epochIdx, 1, 1);
                            rowc = zeros(1, nx);
                            rowc(orbPosIdx) = row(orbPosIdx);
                            rowc(bTxIdx)    = 1;
                            rowc(ambIdx)    = 1;
                            zCar(end+1,1) = rhoT + bTxTruth  - bTwr + Btrue + nzc; %#ok<AGROW>
                            hCar(end+1,1) = rhoM + x(bTxIdx) - bTwr + x(ambIdx);   %#ok<AGROW>
                            HCar(end+1,:) = rowc;                                  %#ok<AGROW>
                            RCar = blkdiag(RCar, sigmaCarr^2 + Rtwr);
                            carAsset(end+1) = ai;   %#ok<AGROW>
                            carTower(end+1) = ti;   %#ok<AGROW>
                        end
                    end
                end
            end
            % Append DOPPLER block after all code rows, then CARRIER block (grouped order).
            if ~isempty(zDop)
                zAdd = [zAdd; zDop];
                hAdd = [hAdd; hDop];
                HAdd = [HAdd; HDop];
                RAdd = blkdiag(RAdd, RDop);
                rowAsset = [rowAsset, dopAsset];
                rowTower = [rowTower, dopTower];
            end
            if ~isempty(zCar)
                zAdd = [zAdd; zCar];
                hAdd = [hAdd; hCar];
                HAdd = [HAdd; HCar];
                RAdd = blkdiag(RAdd, RCar);
                rowAsset = [rowAsset, carAsset];
                rowTower = [rowTower, carTower];
            end
            info.nRows    = numel(zAdd);
            info.rowAsset = rowAsset;
            info.rowTower = rowTower;
            if info.nRows > 0; info.prefitRms = sqrt(mean((zAdd - hAdd).^2)); end
        end

    end  % public methods

    methods (Static)

        % Implementations live in MeasurementModelUtils.
        % These one-line wrappers preserve backward compatibility.

        function varargout = computeISLMeasurements(varargin)
            [varargout{1:nargout}] = models.measurements.MeasurementModelUtils.computeISLMeasurements(varargin{:});
        end
        function need = needsFiniteDiffH_(cfg)
            need = models.measurements.MeasurementModelUtils.needsFiniteDiffH_(cfg);
        end
        function r_twr = towerPositionEcef(cfg, tower, towerIdx, side)
            r_twr = models.measurements.MeasurementModelUtils.towerPositionEcef(cfg, tower, towerIdx, side);
        end
        function kind = zwdMappingKind(cfg)
            kind = models.measurements.MeasurementModelUtils.zwdMappingKind(cfg);
        end
        function rho = modelRangeOnly(cfg, towers, ti, ai, r_cm, euler, leverArms_model)
            rho = models.measurements.MeasurementModelUtils.modelRangeOnly(cfg, towers, ti, ai, r_cm, euler, leverArms_model);
        end
        function sigma = codeSignalSigma(sigCfg, elv, cfg)
            sigma = models.measurements.MeasurementModelUtils.codeSignalSigma(sigCfg, elv, cfg);
        end
        function d = rxCodeBiasModel(cfg)
            d = models.measurements.MeasurementModelUtils.rxCodeBiasModel(cfg);
        end
        function [z_out, R_out, noiseComp] = correlatedNoise(cfg, rngCorr, z_in, R_diag, twr_list, M)
            [z_out, R_out, noiseComp] = models.measurements.MeasurementModelUtils.correlatedNoise( ...
                cfg, rngCorr, z_in, R_diag, twr_list, M);
        end

        function validateSecondaryConfig(cfg)
            % validateSecondaryConfig  Guards for the tower->secondary CARRIER rows.
            % Relocated from revgnss.SecondaryGroundMeasurementBuilder.validateConfig (Phase 3b-2 C5)
            % into the class that now owns the secondary rows. No-op when carrier is off.
            gb = @(p) models.measurements.MeasurementModel.secGetBool_(cfg, p, false);
            if ~gb({'multiAsset','towerSecondary','carrier','enable'}); return; end
            mode = 'off';
            if isfield(cfg,'multiAsset') && isfield(cfg.multiAsset,'estimateMode')
                mode = char(cfg.multiAsset.estimateMode);
            end
            if ~strcmp(mode, 'position')
                error('MeasurementModel:secondaryCarrierNeedsPosition', ...
                    ['towerSecondary.carrier.enable requires cfg.multiAsset.estimateMode=''position'' ' ...
                     '(the carrier row needs the secondary''s estimated r/v geometric column).']);
            end
            if ~gb({'multiAsset','towersObserveSecondaries'})
                error('MeasurementModel:secondaryCarrierNeedsGroundRows', ...
                    'towerSecondary.carrier.enable requires cfg.multiAsset.towersObserveSecondaries=true.');
            end
            s = models.measurements.MeasurementModel.secGetNum_(cfg, {'multiAsset','towerSecondary','carrier','sigma_m'}, 0.005);
            if ~(isfinite(s) && s > 0)
                error('MeasurementModel:secondaryCarrierSigma', 'towerSecondary.carrier.sigma_m must be a positive scalar.');
            end
        end

        function v = secGetNum_(cfg, path, dflt)
            % Safe nested numeric-scalar cfg read (copy of the retired builder's getNum_) for the
            % tower->secondary rows. Returns dflt if any level is missing or the value is not scalar.
            v = cfg;
            for k = 1:numel(path)
                if isstruct(v) && isfield(v, path{k}); v = v.(path{k}); else; v = dflt; return; end
            end
            if ~(isnumeric(v) && isscalar(v)); v = dflt; end
        end

        function tf = secGetBool_(cfg, path, dflt)
            % Safe nested logical-scalar cfg read (copy of the retired builder's getBool_).
            v = cfg;
            for k = 1:numel(path)
                if isstruct(v) && isfield(v, path{k}); v = v.(path{k}); else; tf = dflt; return; end
            end
            tf = islogical(v) && isscalar(v) && v;
        end

    end  % static methods

end
