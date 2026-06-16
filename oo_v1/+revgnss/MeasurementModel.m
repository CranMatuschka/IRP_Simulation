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
        errorChain      revgnss.ErrorChain
        elevMask_rad    (1,1) double = 5 * pi/180
        attitudeJacStep_rad (1,1) double = 1e-6
        ambiguityMap                       % containers.Map: (tower*1000+antenna) → integer N (diagnostic)
        floatAmbiguityTruth_m              % containers.Map: (tower*1000+ant) → float B_phi [m] (ekfFloat)
        rngCorr                            % RandStream for correlated noise (Stage 4)
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
            % Stage 4: correlated noise RNG
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
                elevations_rad(k) = revgnss.GeometryUtils.elevationAngle( ...
                    towers{k}.r_ecef_m, r_ant_ecef_m);
            end
            visible = elevations_rad >= obj.elevMask_rad;
        end

        % ----------------------------------------------------------------
        function [z, h, H, R, errStruct] = computeMeasurements(obj, ...
                asset, towers, x_est, t_s, stateMap)
            % computeMeasurements  Main measurement function (multi-antenna capable).
            %
            % Loops over all visible (tower, antenna) pairs.  Default config has
            % N_ant=1 with a zero lever arm, recovering the single-antenna case.

            % ----- All lever arms (3 x N_ant) --------------------------
            leverArms = asset.receiverLeverArms_body_m;
            N_ant = size(leverArms, 2);

            % ----- Truth state -----------------------------------------
            r_cm_true  = asset.r_ecef_m;
            euler_true = asset.attitude_euler_rad;
            b_rx_true  = asset.clock.getBiasMeters();

            % ----- EKF state extraction --------------------------------
            r_est     = x_est(stateMap.r_idx);
            euler_est = x_est(stateMap.euler_idx);
            b_rx_est  = x_est(stateMap.b_rx_idx);

            % ----- Effective lever arms with PCO offset ----------------
            % Stage 3: receiverOffset_body_m is extra common body-frame offset
            % added to all antennas on truth/model side independently.
            leverArms_truth = leverArms;
            leverArms_model = leverArms;
            if isfield(obj.cfg,'effects') && isfield(obj.cfg.effects,'antennaPCO')
                pco = obj.cfg.effects.antennaPCO;
                if isfield(pco,'truth') && pco.truth.enable
                    off = pco.receiverOffset_body_m(:);
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
                    elv = revgnss.GeometryUtils.elevationAngle(r_twr_nom, r_ants_truth(:,ai));
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
            errStruct = obj.errorChain.compute(elv_list, towerIds, twr_list, t_s);

            % ----- Tower clock corrections — generated ONCE per epoch --
            [towerClkTruth, towerClkModel, towerClkSigma, corrNoise_m, t_prod, towerClkMode] = ...
                revgnss.TowerClockCorrectionProvider.compute( ...
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
                revgnss.CodeMeasurementBuilder.build( ...
                    obj.cfg, obj.errorChain, obj.rngCorr, asset, towers, ...
                    twr_list, ant_list, elv_list, leverArms, leverArms_model, ...
                    r_ants_truth, r_ants_est, x_est, stateMap, ...
                    towerClkTruth, towerClkModel, towerClkSigma, towerClkMode, t_prod, ...
                    errStruct, t_s);


            % ----- Jacobian H (pseudorange) ----------------------------
            H_pr = obj.computeJacobian_(towers, twr_list, ant_list, ...
                r_est, euler_est, leverArms_model, x_est, stateMap, nx);

            % ZWD Jacobian columns (perTowerZwd): H(mi, zwdIdx(ti)) = mf(elv)
            if isfield(stateMap,'zwdIdx') && ~isempty(stateMap.zwdIdx)
                mfKind = obj.zwdMappingKind_();
                for mi_z = 1:M
                    ti_z = twr_list(mi_z);
                    if ti_z <= numel(stateMap.zwdIdx) && stateMap.zwdIdx(ti_z) > 0
                        mf_z = revgnss.MappingFunctions.troposphere( ...
                            errStruct.elevations_rad(mi_z), mfKind);
                        H_pr(mi_z, stateMap.zwdIdx(ti_z)) = mf_z;
                    end
                end
            end

            % ----- Doppler rows (0.5 + 0.6) ----------------------------
            [dopplerRows, dopplerInfo] = revgnss.DopplerMeasurementBuilder.build( ...
                obj.cfg, obj.errorChain, asset, towers, twr_list, ant_list, ...
                r_ants_truth, r_ants_est, x_est, stateMap, towerClkMode, t_s);
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
                    [z_phi, h_phi, H_phi, R_phi, cpInfo] = revgnss.CarrierMeasurementBuilder.buildEkfRows( ...
                        obj.cfg, obj.errorChain, obj.floatAmbiguityTruth_m, ...
                        asset, towers, twr_list(1:M_pairs_c), ant_list(1:M_pairs_c), ...
                        r_ants_truth, r_ants_est, leverArms_model, x_est, stateMap, nx, ...
                        errStruct, towerClkTruth, towerClkModel, towerClkSigma, t_s);
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
                        errStruct.carrierPhase = obj.computeCarrierPhase_( ...
                            asset, towers, twr_list, ant_list, r_ants_truth);
                    else
                        errStruct.carrierPhase = struct();
                    end

                otherwise  % 'none' or unknown
                    errStruct.carrierPhase = struct();
            end

            % ----- Observability diagnostics ---------------------------
            if isfield(obj.cfg,'diagnostics') && ...
                    isfield(obj.cfg.diagnostics,'observability') && ...
                    obj.cfg.diagnostics.observability.enabled
                % Build measType_perRow before passing so diagnostics see row types
                M_rows_obs = size(H, 1);
                M_dop_obs  = 0;
                if isfield(errStruct,'doppler') && isstruct(errStruct.doppler) && ...
                        isfield(errStruct.doppler,'z') && ~isempty(errStruct.doppler.z) && ...
                        isfield(obj.cfg,'measurements') && isfield(obj.cfg.measurements,'doppler') && ...
                        obj.cfg.measurements.doppler.useInEKF
                    M_dop_obs = numel(errStruct.doppler.z);
                end
                % Stage 7A.1: label IF-combined code rows as 'ifCode' so
                % ObservabilityDiagnostics.nIFCodeRows is non-zero in IF mode.
                isIFCodeObs = isfield(errStruct,'ifCombination') && errStruct.ifCombination;
                mTypeObs = cell(M_rows_obs, 1);
                for mi_o = 1:M_rows_obs
                    if mi_o <= M
                        if isIFCodeObs
                            mTypeObs{mi_o} = 'ifCode';
                        else
                            mTypeObs{mi_o} = 'code';
                        end
                    elseif mi_o <= M + M_dop_obs
                        mTypeObs{mi_o} = 'doppler';
                    else
                        mTypeObs{mi_o} = 'carrier';
                    end
                end
                errStruct.observability = revgnss.ObservabilityDiagnostics.analyze( ...
                    H, stateMap, obj.cfg, mTypeObs);
            else
                errStruct.observability = struct();
            end

            % ----- Measurement type metadata per EKF row ---------------
            M_rows     = size(H, 1);
            M_dop_rows = 0;
            if isfield(errStruct,'doppler') && isstruct(errStruct.doppler) && ...
                    isfield(errStruct.doppler,'z') && ~isempty(errStruct.doppler.z) && ...
                    isfield(obj.cfg,'measurements') && isfield(obj.cfg.measurements,'doppler') && ...
                    obj.cfg.measurements.doppler.useInEKF
                M_dop_rows = numel(errStruct.doppler.z);
            end
            % Stage 7A.1: label IF rows as 'ifCode' so downstream diagnostics count them.
            isIFCode = isfield(errStruct,'ifCombination') && errStruct.ifCombination;
            mType = cell(M_rows, 1);
            for mi_t = 1:M_rows
                if mi_t <= M
                    if isIFCode
                        mType{mi_t} = 'ifCode';
                    else
                        mType{mi_t} = 'code';
                    end
                elseif mi_t <= M + M_dop_rows
                    mType{mi_t} = 'doppler';
                else
                    mType{mi_t} = 'carrier';
                end
            end
            errStruct.measType_perRow = mType;
        end

        % ----------------------------------------------------------------
        function H = computeJacobian_(obj, towers, twr_list, ant_list, ...
                r_cm_est, euler_est, leverArms_model, x_est, stateMap, nx)
            % computeJacobian_  Measurement Jacobian (analytic or FD).
            %
            % Stage 5: if any model-side correction is on (Sagnac, Shapiro, PCV, PCO)
            % OR cfg.estimator.forceFiniteDifferenceH=true, use FD for r and euler columns.
            % Clock columns remain analytic: b_rx=+1, b_twr=-1.
            %
            % CHANGED: v3→v4 — Issue 13
            % V1 APPROXIMATION: Attitude derivatives of tropospheric and
            % ionospheric corrections through lever-arm-induced elevation changes
            % are ignored.  This is valid when:
            %     leverArmLength_m << slantRange_m   AND
            %     atmospheric correction gradient is small.
            % Add a diagnostic warning if leverArmLength / slantRange > 1e-4.

            M = numel(twr_list);
            H = zeros(M, nx);

            doFD = revgnss.MeasurementModel.needsFiniteDiffH_(obj.cfg);

            doAttJac = isfield(obj.cfg.estimator, 'estimateAttitude') && ...
                       obj.cfg.estimator.estimateAttitude && ...
                       isfield(obj.cfg.estimator, 'estimateAttitudeFromPseudorange') && ...
                       obj.cfg.estimator.estimateAttitudeFromPseudorange;

            step_e = obj.attitudeJacStep_rad;

            for mi = 1:M
                ti    = twr_list(mi);
                ai    = ant_list(mi);
                lever = leverArms_model(:, ai);

                if doFD
                    % Finite-difference position columns (accounts for all corrections)
                    step_r = 1.0;   % 1 m FD step for position
                    for ki = 1:3
                        r_p = r_cm_est; r_p(ki) = r_p(ki) + step_r;
                        r_m = r_cm_est; r_m(ki) = r_m(ki) - step_r;
                        hp = obj.computeModelRangeOnly_(towers, ti, ai, r_p, euler_est, leverArms_model);
                        hm = obj.computeModelRangeOnly_(towers, ti, ai, r_m, euler_est, leverArms_model);
                        H(mi, stateMap.r_idx(ki)) = (hp - hm) / (2*step_r);
                    end
                else
                    % Analytic position Jacobian: u' using model tower position + PCO lever
                    r_twr = obj.getTowerPosition_(towers{ti}, ti, 'model');
                    r_ant = revgnss.AttitudeKinematics.applyLeverArm(r_cm_est, euler_est, lever);
                    delta = r_ant - r_twr;
                    rho   = norm(delta); if rho < 1; rho = 1; end
                    H(mi, stateMap.r_idx) = (delta / rho)';
                end

                % Lever-arm ratio diagnostic (Issue 13)
                r_twr_diag = obj.getTowerPosition_(towers{ti}, ti, 'model');
                r_ant_diag = revgnss.AttitudeKinematics.applyLeverArm(r_cm_est, euler_est, lever);
                slantRange_diag = norm(r_ant_diag - r_twr_diag);
                leverNorm_diag  = norm(lever);
                if slantRange_diag > 0 && leverNorm_diag / slantRange_diag > 1e-4 && ...
                        leverNorm_diag > 1e-9 && mod(mi, max(1, numel(twr_list))) == 1
                    warning('revgnss:leverArmRatio', ...
                        'Lever arm / slant range = %.2e; atmosphere attitude derivatives may not be negligible.', ...
                        leverNorm_diag / slantRange_diag);
                end

                % Attitude FD (gated by config + non-zero lever)
                if doAttJac && norm(lever) > 1e-9
                    for ke = 1:3
                        eul_p = euler_est; eul_p(ke) = eul_p(ke) + step_e;
                        eul_m = euler_est; eul_m(ke) = eul_m(ke) - step_e;
                        hp = obj.computeModelRangeOnly_(towers, ti, ai, r_cm_est, eul_p, leverArms_model);
                        hm = obj.computeModelRangeOnly_(towers, ti, ai, r_cm_est, eul_m, leverArms_model);
                        H(mi, stateMap.euler_idx(ke)) = (hp - hm) / (2*step_e);
                    end
                end

                % Receiver clock: +1 (analytic, independent of corrections)
                H(mi, stateMap.b_rx_idx) = 1;

                % Tower clock state: -1 if estimated
                if isfield(stateMap,'towerClockIdx') && ...
                        ti <= size(stateMap.towerClockIdx,1) && ...
                        stateMap.towerClockIdx(ti,1) > 0
                    H(mi, stateMap.towerClockIdx(ti,1)) = -1;
                end

                % Tx code hardware-delay Jacobian: +1 (not on Doppler or carrier rows)
                if isfield(stateMap,'txCodeBiasIdx') && ...
                        ti <= numel(stateMap.txCodeBiasIdx) && ...
                        stateMap.txCodeBiasIdx(ti) > 0
                    H(mi, stateMap.txCodeBiasIdx(ti)) = 1;
                end
            end
        end

        % ----------------------------------------------------------------
        function mode = getTowerClockMode_(obj)
            mode = revgnss.TowerClockCorrectionProvider.towerClockMode(obj.cfg);
        end

        % ----------------------------------------------------------------
        function cp = computeCarrierPhase_(obj, asset, towers, twr_list, ant_list, r_ants_true)
            % computeCarrierPhase_  Truth carrier phase observables (diagnostic only).
            %
            % z_phi_cycles = (rho + b_rx - b_twr) / lambda + N_ia + noise
            % N_ia: constant integer ambiguity per (tower, antenna) arc.
            %
            % What is included: geometry + clocks + ambiguity + carrier noise.
            % What is NOT included: atmosphere.
            %   Troposphere delays carrier like code (same sign).
            %   Ionosphere ADVANCES carrier (OPPOSITE sign to code, sign = -1).
            % ErrorChain truthTotal_m is NOT used here to avoid applying iono
            % with wrong sign.  If atmosphere is later added, apply:
            %   rho + trop_m - iono_m   (trop positive, iono negative for carrier).
            % No cycle slips in v1.
            cpc    = obj.cfg.measurements.carrierPhase;
            lambda = cpc.lambda_m;
            sigma  = cpc.sigma_cycles;
            M      = numel(twr_list);

            if isempty(obj.ambiguityMap)
                rngAmb = RandStream('mt19937ar','Seed', cpc.seed);
                obj.ambiguityMap = containers.Map('KeyType','int32','ValueType','double');
                for mi2 = 1:M
                    key = int32(twr_list(mi2) * 1000 + ant_list(mi2));
                    if ~isKey(obj.ambiguityMap, key)
                        switch cpc.initialAmbiguityMode
                            case 'randomInteger'
                                obj.ambiguityMap(key) = round(randn(rngAmb,1,1) * 1e4);
                            otherwise
                                obj.ambiguityMap(key) = 0;
                        end
                    end
                end
            end

            b_rx_true = asset.clock.getBiasMeters();
            phi   = zeros(M,1);
            ambig = zeros(M,1);
            for mi = 1:M
                ti    = twr_list(mi);
                ai    = ant_list(mi);
                r_twr = towers{ti}.getAntennaPositionECEF();
                b_twr = towers{ti}.getClockBiasMeters();
                rho   = norm(r_ants_true(:,ai) - r_twr);
                key   = int32(ti * 1000 + ai);
                N_ia  = obj.ambiguityMap(key);
                ambig(mi) = N_ia;
                % Geometry + clocks + ambiguity + carrier noise (no atmosphere).
                phi(mi) = (rho + b_rx_true - b_twr) / lambda + N_ia + ...
                          sigma * obj.errorChain.drawNormal(1,1);
            end
            cp.phi_cycles    = phi;
            cp.ambiguity_int = ambig;
            cp.lambda_m      = lambda;
            cp.towerIdx      = twr_list;
            cp.antennaIdx    = ant_list;
        end

        % ----------------------------------------------------------------
        function b_model = getTowerClockModel_(obj, twr, cfg)
            % getTowerClockModel_  Legacy single-tower clock correction helper.
            % NOTE: use stored errStruct.towerClockModel_m in main loop to avoid
            % repeated noise draws.  This method is for test/standalone use only.
            towerClockMode = obj.getTowerClockMode_();
            noiseSigma = 0.5;
            if isfield(cfg,'estimator') && isfield(cfg.estimator,'towerClockCorrectionSigma_m')
                noiseSigma = cfg.estimator.towerClockCorrectionSigma_m;
            end
            switch towerClockMode
                case 'none'
                    b_model = 0;
                case 'perfectCorrection'
                    b_model = twr.getClockBiasMeters();
                case 'noisyCorrection'
                    % CHANGED: v3→v4 — Issue 5
                    % SIMULATION NOTE: noisyCorrection is a truth-based simulated external
                    % correction product.  It is NOT a model of what a real receiver
                    % produces; it adds zero-mean Gaussian noise to the true tower clock.
                    % Use for Monte Carlo bias/sigma studies only.
                    b_model = twr.getClockBiasMeters() + noiseSigma * obj.errorChain.drawNormal(1,1);
                otherwise
                    b_model = 0;
            end
        end

        % ----------------------------------------------------------------
        function h_pr = computePseudorangeModelOnly(obj, asset, towers, x_state, errStruct, stateMap, t_s)
            % computePseudorangeModelOnly  Recompute h_pr with updated EKF state.
            if nargin < 7 || isempty(t_s); t_s = 0; end
            %
            % Exact same model-side path as computeMeasurements (h side):
            %   - PCO-adjusted lever arms (model)
            %   - getTowerPosition_(..., 'model') with survey error
            %   - Model tower PCO if enabled
            %   - correctedPseudorange(..., 'model', el) — Sagnac, Shapiro, PCV
            %   - Receiver + tower clock from state / errStruct
            %   - errStruct.modelTotal_m — frozen ErrorChain corrections
            %
            % Used by ReverseGNSSSimulation.computePostfitResiduals_ so postfit
            % uses the exact same model path as the EKF h, not a simplified version.

            leverArms = asset.receiverLeverArms_body_m;
            N_ant = size(leverArms, 2);

            % Model-side lever arms with receiver PCO if enabled
            leverArms_model = leverArms;
            if isfield(obj.cfg,'effects') && isfield(obj.cfg.effects,'antennaPCO')
                pco = obj.cfg.effects.antennaPCO;
                if isfield(pco,'model') && pco.model.enable
                    off = pco.receiverOffset_body_m(:);
                    leverArms_model = leverArms + off * ones(1, N_ant);
                end
            end

            r_est     = x_state(stateMap.r_idx);
            euler_est = x_state(stateMap.euler_idx);
            b_rx_est  = x_state(stateMap.b_rx_idx);

            r_ants_est = asset.getAntennaPositionsECEF(r_est, euler_est, leverArms_model);

            twr_list = errStruct.towerIdx_perMeas;
            ant_list = errStruct.antennaIdx_perMeas;
            M_pr     = errStruct.nPseudorange;

            h_pr = zeros(M_pr, 1);

            for mi = 1:M_pr
                ti = twr_list(mi);
                ai = ant_list(mi);

                % Model tower position (with survey error if model.enable)
                r_twr_model = obj.getTowerPosition_(towers{ti}, ti, 'model');

                % Tower PCO (model side)
                if isfield(obj.cfg,'effects') && isfield(obj.cfg.effects,'antennaPCO')
                    pco = obj.cfg.effects.antennaPCO;
                    if isfield(pco,'model') && pco.model.enable
                        tOff = pco.towerOffset_enu_m(:);
                        R_ENU = revgnss.GeometryUtils.enu2ecef( ...
                            towers{ti}.lat_rad, towers{ti}.lon_rad);
                        r_twr_model = r_twr_model + R_ENU * tOff;
                    end
                end

                % Elevation angle from updated positions (for PCV)
                r_ant = r_ants_est(:, ai);
                elv = revgnss.GeometryUtils.elevationAngle(r_twr_model, r_ant);

                % Corrected range (Sagnac, Shapiro, PCV all on model side)
                rho_est = revgnss.RangeCorrections.correctedPseudorange( ...
                    r_ant, r_twr_model, obj.cfg, 'model', elv, t_s);

                % Tower clock: EKF state if estimated, else frozen model correction
                if isfield(stateMap,'towerClockIdx') && ti <= size(stateMap.towerClockIdx,1) && ...
                        stateMap.towerClockIdx(ti,1) > 0
                    b_twr = x_state(stateMap.towerClockIdx(ti,1));
                elseif mi <= numel(errStruct.towerClockModel_m)
                    b_twr = errStruct.towerClockModel_m(mi);
                else
                    b_twr = 0;
                end

                % Frozen ErrorChain model correction (same realization as original h)
                model_total = 0;
                if isfield(errStruct,'modelTotal_m') && mi <= numel(errStruct.modelTotal_m)
                    model_total = errStruct.modelTotal_m(mi);
                end

                h_pr(mi) = rho_est + b_rx_est - b_twr + model_total;

                % TASK 2: ZWD state contribution (same as in computeMeasurements h path)
                if isfield(stateMap,'zwdIdx') && ti <= numel(stateMap.zwdIdx) && ...
                        stateMap.zwdIdx(ti) > 0
                    mf_h = revgnss.MappingFunctions.troposphere(elv, obj.zwdMappingKind_());
                    h_pr(mi) = h_pr(mi) + mf_h * x_state(stateMap.zwdIdx(ti));
                end

                % TASK 3: Tx code hardware-delay postfit contribution (+1 sign)
                if isfield(stateMap,'txCodeBiasIdx') && ti <= numel(stateMap.txCodeBiasIdx) && ...
                        stateMap.txCodeBiasIdx(ti) > 0
                    h_pr(mi) = h_pr(mi) + x_state(stateMap.txCodeBiasIdx(ti));
                end

                % TASK 4: Receiver code hardware-delay postfit correction (code rows only)
                d_rx_code_pr = obj.getRxCodeBiasModel_();
                if d_rx_code_pr ~= 0
                    h_pr(mi) = h_pr(mi) + d_rx_code_pr;
                end
            end
        end

        % ----------------------------------------------------------------
        function h_phi = computeCarrierModelOnly(obj, asset, towers, x_state, errStruct, stateMap, t_s)
            % computeCarrierModelOnly  Recompute carrier h with updated EKF state.
            if nargin < 7 || isempty(t_s); t_s = 0; end
            %
            % Returns h_phi for each carrier row (one per visible tower) evaluated
            % at x_state (the post-update EKF state).  Used by
            % ReverseGNSSSimulation.computePostfitResiduals_ to produce true
            % postfit residuals rather than prefit residuals.
            %
            % Formula (Phase 2):
            %   h_phi = rho_est + b_rx_est - b_twr_model
            %           + trop_model - iono_model + B_est + zwd_contribution
            %
            % All error-chain corrections are frozen from errStruct (same realization
            % as original h).  Only the state-dependent terms (r, b_rx, B, ZWD) are
            % re-evaluated from x_state.

            if ~isfield(errStruct,'carrierPhase') || ...
                    ~isstruct(errStruct.carrierPhase) || ...
                    ~isfield(errStruct.carrierPhase,'towerIdx') || ...
                    isempty(errStruct.carrierPhase.towerIdx)
                h_phi = [];
                return
            end

            cp = errStruct.carrierPhase;
            twr_pairs = cp.towerIdx;
            ant_pairs = cp.antennaIdx;
            Mp = numel(twr_pairs);

            leverArms = asset.receiverLeverArms_body_m;
            N_ant = size(leverArms, 2);

            % Model-side lever arms with receiver PCO if enabled
            leverArms_model = leverArms;
            if isfield(obj.cfg,'effects') && isfield(obj.cfg.effects,'antennaPCO')
                pco = obj.cfg.effects.antennaPCO;
                if isfield(pco,'model') && pco.model.enable
                    off = pco.receiverOffset_body_m(:);
                    leverArms_model = leverArms + off * ones(1, N_ant);
                end
            end

            r_est     = x_state(stateMap.r_idx);
            euler_est = x_state(stateMap.euler_idx);
            b_rx_est  = x_state(stateMap.b_rx_idx);

            r_ants_est = asset.getAntennaPositionsECEF(r_est, euler_est, leverArms_model);

            sigIdx = 1;   % L1 only in v1
            h_phi  = zeros(Mp, 1);
            mfKind = obj.zwdMappingKind_();

            for mi = 1:Mp
                ti  = twr_pairs(mi);
                ai  = ant_pairs(mi);

                % Model tower position (survey + PCO, same as computeMeasurements)
                r_twr_e = obj.getTowerPosition_(towers{ti}, ti, 'model');
                if isfield(obj.cfg,'effects') && isfield(obj.cfg.effects,'antennaPCO')
                    pco = obj.cfg.effects.antennaPCO;
                    if isfield(pco,'model') && pco.model.enable
                        tOff = pco.towerOffset_enu_m(:);
                        R_ENU = revgnss.GeometryUtils.enu2ecef(towers{ti}.lat_rad, towers{ti}.lon_rad);
                        r_twr_e = r_twr_e + R_ENU * tOff;
                    end
                end

                % Updated elevation for ZWD mapping
                elv = revgnss.GeometryUtils.elevationAngle(r_twr_e, r_ants_est(:, ai));

                % Corrected geometric range (same path as code)
                rho_e = revgnss.RangeCorrections.correctedPseudorange( ...
                    r_ants_est(:, ai), r_twr_e, obj.cfg, 'model', elv, t_s);

                % Tower clock: EKF state if estimated, else frozen model correction
                if isfield(stateMap,'towerClockIdx') && ti <= size(stateMap.towerClockIdx,1) && ...
                        stateMap.towerClockIdx(ti,1) > 0
                    b_twr = x_state(stateMap.towerClockIdx(ti,1));
                elseif isfield(errStruct,'towerClockModel_m') && mi <= numel(errStruct.towerClockModel_m)
                    b_twr = errStruct.towerClockModel_m(mi);
                else
                    b_twr = 0;
                end

                % Float ambiguity state (updated)
                B_est = 0;
                if isfield(stateMap,'ambiguityIdx') && ...
                        ti <= size(stateMap.ambiguityIdx,1) && ...
                        sigIdx <= size(stateMap.ambiguityIdx,2) && ...
                        stateMap.ambiguityIdx(ti,sigIdx) > 0
                    B_est = x_state(stateMap.ambiguityIdx(ti,sigIdx));
                end

                % Frozen troposphere and ionosphere (same realization as original h)
                trop_m = 0; iono_m = 0;
                if isfield(errStruct,'bySource')
                    bm = errStruct.bySource.model_m;
                    if isfield(bm,'trop') && mi <= numel(bm.trop); trop_m = bm.trop(mi); end
                    if isfield(bm,'iono') && mi <= numel(bm.iono); iono_m = bm.iono(mi); end
                end

                h_phi(mi) = rho_e + b_rx_est - b_twr + trop_m - iono_m + B_est;

                % ZWD state (updated)
                if isfield(stateMap,'zwdIdx') && ti <= numel(stateMap.zwdIdx) && ...
                        stateMap.zwdIdx(ti) > 0
                    mf = revgnss.MappingFunctions.troposphere(elv, mfKind);
                    h_phi(mi) = h_phi(mi) + mf * x_state(stateMap.zwdIdx(ti));
                end
            end
        end

    end  % public methods

    methods (Access = private)

        % ----------------------------------------------------------------
        function sigma = computeCodeSigmaForSignal_(obj, sigCfg, elv, cfg) %#ok<INUSL>
            sigma = revgnss.MeasurementModel.codeSignalSigma(sigCfg, elv, cfg);
        end

        % ----------------------------------------------------------------
        function r_twr = getTowerPosition_(obj, tower, towerIdx, side)
            r_twr = revgnss.MeasurementModel.towerPositionEcef(obj.cfg, tower, towerIdx, side);
        end

        % ----------------------------------------------------------------
        function [b_m, bdot_mps] = getClockAtProductEpoch_(obj, tower, t_prod_s) %#ok<INUSL>
            [b_m, bdot_mps] = revgnss.TowerClockCorrectionProvider.clockAtProductEpoch(tower, t_prod_s);
        end

        % ----------------------------------------------------------------
        function [b_hat, sigma_corr] = evalProductStruct_(obj, ti, t_eval_s)
            [b_hat, sigma_corr] = revgnss.TowerClockCorrectionProvider.evalProductStruct( ...
                obj.cfg, ti, t_eval_s);
        end

        % ----------------------------------------------------------------
        function [z_out, R_out, noiseComp] = applyCorrelatedNoise_(obj, z_in, R_diag, twr_list, M)
            [z_out, R_out, noiseComp] = revgnss.MeasurementModel.correlatedNoise( ...
                obj.cfg, obj.rngCorr, z_in, R_diag, twr_list, M);
        end

        % ----------------------------------------------------------------
        function rho = computeModelRangeOnly_(obj, towers, ti, ai, r_cm, euler, leverArms_model)
            rho = revgnss.MeasurementModel.modelRangeOnly(obj.cfg, towers, ti, ai, r_cm, euler, leverArms_model);
        end

    end  % private methods

    methods (Access = private)

        % ----------------------------------------------------------------
        function d = getRxCodeBiasModel_(obj)
            d = revgnss.MeasurementModel.rxCodeBiasModel(obj.cfg);
        end

        % ----------------------------------------------------------------
        function kind = zwdMappingKind_(obj)
            kind = revgnss.MeasurementModel.zwdMappingKind(obj.cfg);
        end

    end  % private (ZWD helper) methods

    methods (Static)

        function [z_isl, h_isl, H_isl] = computeISLMeasurements(asset_rx, asset_tx, ~, ~)
            % computeISLMeasurements  Future-work stub. ISL is NOT implemented in oo_v1.
            %
            % Returns empty z/h/H — no EKF rows, no measurement effect.
            % Do NOT advertise ISL as supported functionality.
            %
            % Candidate future one-way range observable:
            %   z_{rx,tx} = rho_{rx,tx} + b_rx - b_tx + noise
            % Sign convention: receiver clock adds positively, transmitter subtracts.
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
                % Stage 7A.1: iterative light-time rotates the tower position by
                % omega_E*tau; the geometric Jacobian dρ/dr = u' is then wrong.
                % Use finite-difference H when iterative light-time is active.
                if isfield(cfg.effects,'lightTime') && ...
                        isfield(cfg.effects.lightTime,'model') && ...
                        strcmp(cfg.effects.lightTime.model,'iterative')
                    need = true; return;
                end
            end
        end

        function r_twr = towerPositionEcef(cfg, tower, towerIdx, side)
            % towerPositionEcef  Tower ECEF with optional survey offset.
            %
            % Public static for use by external measurement builders (e.g. DopplerMeasurementBuilder).
            % Logic identical to private getTowerPosition_ instance method.
            r_nom = tower.getAntennaPositionECEF();
            if ~isfield(cfg,'effects') || ~isfield(cfg.effects,'towerSurvey')
                r_twr = r_nom; return;
            end
            ts = cfg.effects.towerSurvey;
            if ~isfield(ts, side) || ~ts.(side).enable
                r_twr = r_nom; return;
            end
            if towerIdx <= numel(cfg.towers) && isfield(cfg.towers(towerIdx),'surveyError_ENU_m')
                enu_err = cfg.towers(towerIdx).surveyError_ENU_m;
                r_twr = r_nom + revgnss.GeometryUtils.enu2ecef_vector( ...
                    tower.lat_rad, tower.lon_rad, enu_err);
            else
                r_twr = r_nom;
            end
        end

        function kind = zwdMappingKind(cfg)
            % zwdMappingKind  Return the configured ZWD troposphere mapping kind.
            %
            % Public static for use by external measurement builders.
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
            % Public static for use by external measurement builders.
            % Includes model-side corrections (Sagnac, Shapiro, PCV) but NOT
            % clock terms or ErrorChain corrections (constants w.r.t. position/attitude).
            lever = leverArms_model(:, ai);
            r_ant = revgnss.AttitudeKinematics.applyLeverArm(r_cm, euler, lever);
            r_twr = revgnss.MeasurementModel.towerPositionEcef(cfg, towers{ti}, ti, 'model');
            if isfield(cfg,'effects') && isfield(cfg.effects,'antennaPCO')
                pco = cfg.effects.antennaPCO;
                if isfield(pco,'model') && pco.model.enable
                    tOff = pco.towerOffset_enu_m(:);
                    R_ENU = revgnss.GeometryUtils.enu2ecef(towers{ti}.lat_rad, towers{ti}.lon_rad);
                    r_twr = r_twr + R_ENU * tOff;
                end
            end
            elv = revgnss.GeometryUtils.elevationAngle(r_twr, r_ant);
            rho = revgnss.RangeCorrections.correctedPseudorange(r_ant, r_twr, cfg, 'model', elv);
        end

        function sigma = codeSignalSigma(sigCfg, elv, cfg)
            % codeSignalSigma  Per-signal code noise sigma at given elevation.
            %
            % Public static for use by external measurement builders.
            elvFloor = revgnss.Constants.ELEVATION_FLOOR_RAD;
            sigma0   = sigCfg.codeSigma0_m;
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
                otherwise
                    sigma = sigma0;
            end
        end

        function d = rxCodeBiasModel(cfg)
            % rxCodeBiasModel  Receiver code hardware-delay model correction [m].
            %
            % Public static for use by external measurement builders.
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
            % Public static for use by external measurement builders.
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

    end  % static methods

end
