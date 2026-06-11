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
        ambiguityMap                       % containers.Map: (tower*1000+antenna) → integer N
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
            towerClkMode  = obj.getTowerClockMode_();
            towerClkTruth = zeros(M,1);
            towerClkModel = zeros(M,1);
            towerClkSigma = zeros(M,1);

            noiseSigma = obj.cfg.estimator.towerClockCorrectionSigma_m;
            if isfield(obj.cfg,'towerClockCorrectionSigma_m')
                noiseSigma = obj.cfg.towerClockCorrectionSigma_m;
            end
            if strcmp(towerClkMode,'noisyCorrection')
                corrNoise_m = noiseSigma * obj.errorChain.drawNormal(M, 1);
            else
                corrNoise_m = zeros(M,1);
            end

            for mi = 1:M
                ti  = twr_list(mi);
                b_t = towers{ti}.getClockBiasMeters();
                towerClkTruth(mi) = b_t;
                switch towerClkMode
                    case 'none'
                        towerClkModel(mi) = 0;
                    case 'perfectCorrection'
                        towerClkModel(mi) = b_t;
                    case 'noisyCorrection'
                        towerClkModel(mi) = b_t + corrNoise_m(mi);
                        towerClkSigma(mi) = noiseSigma;
                    otherwise
                        towerClkModel(mi) = 0;
                end
            end

            errStruct.towerClockTruth_m      = towerClkTruth;
            errStruct.towerClockModel_m      = towerClkModel;
            errStruct.towerClockModelSigma_m = towerClkSigma;
            errStruct.towerIdx_perMeas       = twr_list;
            errStruct.antennaIdx_perMeas     = ant_list;
            errStruct.nPseudorange           = M;   % 0.4: for postfit split

            % ----- Build z, h, R_diag ----------------------------------
            z      = zeros(M,1);
            h      = zeros(M,1);
            R_diag = zeros(M,1);

            sigmaFloor = obj.cfg.measurement.sigmaFloor_m;

            sagnacTruth_m  = zeros(M,1);
            sagnacModel_m  = zeros(M,1);
            shapiroTruth_m = zeros(M,1);
            shapiroModel_m = zeros(M,1);
            pcvTruth_m     = zeros(M,1);
            pcvModel_m     = zeros(M,1);

            for mi = 1:M
                ti  = twr_list(mi);
                ai  = ant_list(mi);
                elv = elv_list(mi);

                % Stage 2: truth and model tower positions (survey error)
                r_twr_truth = obj.getTowerPosition_(towers{ti}, ti, 'truth');
                r_twr_model = obj.getTowerPosition_(towers{ti}, ti, 'model');

                % Stage 3: tower PCO on top of survey-shifted position
                if isfield(obj.cfg,'effects') && isfield(obj.cfg.effects,'antennaPCO')
                    pco = obj.cfg.effects.antennaPCO;
                    if isfield(pco,'truth') && pco.truth.enable
                        tOff = pco.towerOffset_enu_m(:);
                        R_ENU = revgnss.GeometryUtils.enu2ecef(towers{ti}.lat_rad, towers{ti}.lon_rad);
                        r_twr_truth = r_twr_truth + R_ENU * tOff;
                    end
                    if isfield(pco,'model') && pco.model.enable
                        tOff = pco.towerOffset_enu_m(:);
                        R_ENU = revgnss.GeometryUtils.enu2ecef(towers{ti}.lat_rad, towers{ti}.lon_rad);
                        r_twr_model = r_twr_model + R_ENU * tOff;
                    end
                end

                % Truth pseudorange with corrections + toy PCV (Stage 3)
                [rho_true, cTruth] = revgnss.RangeCorrections.correctedPseudorange( ...
                    r_ants_truth(:,ai), r_twr_truth, obj.cfg, 'truth', elv);
                sagnacTruth_m(mi)  = cTruth.sagnac;
                shapiroTruth_m(mi) = cTruth.shapiro;
                pcvTruth_m(mi)     = cTruth.pcv;
                z(mi) = rho_true + b_rx_true - towerClkTruth(mi) + errStruct.truthTotal_m(mi);

                % Predicted pseudorange with corrections + toy PCV
                [rho_est, cModel] = revgnss.RangeCorrections.correctedPseudorange( ...
                    r_ants_est(:,ai), r_twr_model, obj.cfg, 'model', elv);
                sagnacModel_m(mi)  = cModel.sagnac;
                shapiroModel_m(mi) = cModel.shapiro;
                pcvModel_m(mi)     = cModel.pcv;

                % Tower clock model
                if isfield(stateMap,'towerClockIdx') && ti <= size(stateMap.towerClockIdx,1) && ...
                        stateMap.towerClockIdx(ti,1) > 0
                    b_twr_h = x_est(stateMap.towerClockIdx(ti,1));
                else
                    b_twr_h = towerClkModel(mi);
                end

                h(mi) = rho_est + b_rx_est - b_twr_h + errStruct.modelTotal_m(mi);

                sigma_i = sqrt(errStruct.sigmaTotal_m(mi)^2 + towerClkSigma(mi)^2);
                R_diag(mi) = max(sigma_i, sigmaFloor)^2;
            end

            % Attach diagnostics
            errStruct.sagnacTruth_m  = sagnacTruth_m;
            errStruct.sagnacModel_m  = sagnacModel_m;
            errStruct.shapiroTruth_m = shapiroTruth_m;
            errStruct.shapiroModel_m = shapiroModel_m;
            errStruct.pcvTruth_m     = pcvTruth_m;
            errStruct.pcvModel_m     = pcvModel_m;

            % ----- Stage 4: correlated measurement noise ---------------
            % Adds truth-side correlated noise to z and builds full R.
            [z, R] = obj.applyCorrelatedNoise_(z, R_diag, twr_list, M);

            % ----- Jacobian H (pseudorange) ----------------------------
            H_pr = obj.computeJacobian_(towers, twr_list, ant_list, ...
                r_est, euler_est, leverArms_model, x_est, stateMap, nx);

            % ----- Doppler rows (0.5 + 0.6) ----------------------------
            doCfg = isfield(obj.cfg,'measurements') && ...
                    isfield(obj.cfg.measurements,'doppler') && ...
                    obj.cfg.measurements.doppler.enable;

            if doCfg
                % 0.5: physics flag checks
                doTruth = isfield(obj.cfg,'physics') && isfield(obj.cfg.physics,'doppler') && ...
                          isfield(obj.cfg.physics.doppler,'truth') && obj.cfg.physics.doppler.truth.enable;
                doModel = isfield(obj.cfg,'physics') && isfield(obj.cfg.physics,'doppler') && ...
                          isfield(obj.cfg.physics.doppler,'model') && obj.cfg.physics.doppler.model.enable;
                useInEKF = obj.cfg.measurements.doppler.useInEKF;

                if ~doTruth && mod(round(t_s), 300) == 0
                    warning('MeasurementModel:dopplerNoTruth', ...
                        ['Doppler enabled but physics.doppler.truth.enable=false. ' ...
                         'Doppler z will be zeros. Enable physics.doppler.truth for realistic Doppler.']);
                end
                if ~doModel && useInEKF
                    error('MeasurementModel:dopplerNoModel', ...
                        ['Doppler useInEKF=true requires physics.doppler.model.enable=true. ' ...
                         'Cannot build h model without physics.doppler.model.enable.']);
                end

                v_rx_true = asset.v_ecef_mps;
                v_rx_est  = x_est(stateMap.v_idx);
                bdot_rx_true = asset.clock.getDriftMetersPerSecond();
                bdot_rx_est  = x_est(stateMap.bdot_rx_idx);
                sigma_dop = obj.cfg.measurements.doppler.sigma_mps;

                zd      = zeros(M,1);
                hd      = zeros(M,1);
                Hd      = zeros(M,nx);
                Rd_diag = sigma_dop^2 * ones(M,1);
                towerClockDriftTruth_mps = zeros(M,1);
                towerClockDriftModel_mps = zeros(M,1);

                for mi = 1:M
                    ti  = twr_list(mi);
                    ai  = ant_list(mi);

                    % 0.6: tower clock drift in Doppler
                    bdot_twr = towers{ti}.getClockDriftMetersPerSecond();
                    towerClockDriftTruth_mps(mi) = bdot_twr;
                    if strcmp(towerClkMode, 'perfectCorrection')
                        bdot_twr_model = bdot_twr;   % known drift → cancel in h
                    else
                        bdot_twr_model = 0;  % drift correction unavailable
                    end
                    towerClockDriftModel_mps(mi) = bdot_twr_model;

                    r_twr_t = obj.getTowerPosition_(towers{ti}, ti, 'truth');
                    delta_t = r_ants_truth(:,ai) - r_twr_t;
                    rho_t   = norm(delta_t); if rho_t < 1; rho_t = 1; end
                    u_t     = delta_t / rho_t;

                    if doTruth
                        rhoDot_true = u_t' * v_rx_true;
                        zd(mi) = rhoDot_true + bdot_rx_true - bdot_twr + ...
                                 sigma_dop * obj.errorChain.drawNormal(1,1);
                    % else: zd(mi) = 0 (zero-filled, warned above)
                    end

                    r_twr_e = obj.getTowerPosition_(towers{ti}, ti, 'model');
                    delta_e = r_ants_est(:,ai) - r_twr_e;
                    rho_e   = norm(delta_e); if rho_e < 1; rho_e = 1; end
                    u_e     = delta_e / rho_e;

                    if doModel
                        rhoDot_est = u_e' * v_rx_est;
                        hd(mi) = rhoDot_est + bdot_rx_est - bdot_twr_model;
                    end

                    Hd(mi, stateMap.v_idx)       = u_e';
                    Hd(mi, stateMap.bdot_rx_idx) = 1;
                end

                errStruct.doppler.z     = zd;
                errStruct.doppler.h     = hd;
                errStruct.doppler.prefit = zd - hd;
                errStruct.doppler.towerClockDriftTruth_mps = towerClockDriftTruth_mps;
                errStruct.doppler.towerClockDriftModel_mps = towerClockDriftModel_mps;

                if useInEKF
                    % Extend z/h/H/R with Doppler rows (Doppler R stays diagonal)
                    z    = [z;    zd];
                    h    = [h;    hd];
                    H_pr = [H_pr; Hd];
                    % Append diagonal Doppler variances to whatever R shape was built
                    if size(R,1) == M
                        R = blkdiag(R, diag(Rd_diag));
                    else
                        R = diag([diag(R); Rd_diag]);
                    end
                end
            else
                errStruct.doppler = struct();
            end

            H = H_pr;

            % ----- Carrier phase (diagnostic only; never in EKF v1) ----
            doCpCfg = isfield(obj.cfg,'measurements') && ...
                      isfield(obj.cfg.measurements,'carrierPhase') && ...
                      obj.cfg.measurements.carrierPhase.enable;

            if doCpCfg
                if obj.cfg.measurements.carrierPhase.useInEKF
                    doAmb = isfield(obj.cfg.estimator,'estimateCarrierAmbiguities') && ...
                            obj.cfg.estimator.estimateCarrierAmbiguities;
                    if ~doAmb
                        error('MeasurementModel:carrierPhaseNoAmbiguity', ...
                            ['carrierPhase.useInEKF=true requires ' ...
                             'cfg.estimator.estimateCarrierAmbiguities=true. ' ...
                             'Float ambiguity states are not implemented. ' ...
                             'Set useInEKF=false for diagnostic-only mode.']);
                    end
                end
                errStruct.carrierPhase = obj.computeCarrierPhase_( ...
                    asset, towers, twr_list, ant_list, r_ants_truth);
            else
                errStruct.carrierPhase = struct();
            end
        end

        % ----------------------------------------------------------------
        function H = computeJacobian_(obj, towers, twr_list, ant_list, ...
                r_cm_est, euler_est, leverArms_model, x_est, stateMap, nx)
            % computeJacobian_  Measurement Jacobian (analytic or FD).
            %
            % Stage 5: if any model-side correction is on (Sagnac, Shapiro, PCV, PCO)
            % OR cfg.estimator.forceFiniteDifferenceH=true, use FD for r and euler columns.
            % Clock columns remain analytic: b_rx=+1, b_twr=-1.

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
            end
        end

        % ----------------------------------------------------------------
        function mode = getTowerClockMode_(obj)
            mode = 'none';
            if isfield(obj.cfg,'estimator') && isfield(obj.cfg.estimator,'towerClockMode')
                mode = obj.cfg.estimator.towerClockMode;
            elseif isfield(obj.cfg,'towerClockMode')
                mode = obj.cfg.towerClockMode;
            end
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
                    b_model = twr.getClockBiasMeters() + noiseSigma * obj.errorChain.drawNormal(1,1);
                otherwise
                    b_model = 0;
            end
        end

    end  % public methods

    methods (Access = private)

        % ----------------------------------------------------------------
        function r_twr = getTowerPosition_(obj, tower, towerIdx, side)
            % getTowerPosition_  Tower antenna position for truth or model side.
            %
            % Stage 2: if cfg.effects.towerSurvey.(side).enable, adds the
            % survey ENU error stored in cfg.towers(towerIdx).surveyError_ENU_m.
            % Does NOT mutate tower.r_ecef_m — computes on-the-fly.

            r_nom = tower.getAntennaPositionECEF();

            if ~isfield(obj.cfg,'effects') || ~isfield(obj.cfg.effects,'towerSurvey')
                r_twr = r_nom; return;
            end
            ts = obj.cfg.effects.towerSurvey;
            if ~isfield(ts, side) || ~ts.(side).enable
                r_twr = r_nom; return;
            end

            % Survey error (generated once in finalizeConfig, same for truth+model)
            if towerIdx <= numel(obj.cfg.towers) && ...
                    isfield(obj.cfg.towers(towerIdx),'surveyError_ENU_m')
                enu_err = obj.cfg.towers(towerIdx).surveyError_ENU_m;
                r_twr = r_nom + revgnss.GeometryUtils.enu2ecef_vector( ...
                    tower.lat_rad, tower.lon_rad, enu_err);
            else
                r_twr = r_nom;
            end
        end

        % ----------------------------------------------------------------
        function [z_out, R_out] = applyCorrelatedNoise_(obj, z_in, R_diag, twr_list, M)
            % applyCorrelatedNoise_  Stage 4: add correlated truth noise and build full R.
            %
            % If cfg.effects.correlatedNoise.enable=false, returns z unchanged and
            % R = diag(R_diag).
            %
            % If enabled:
            %   Truth noise draws (added to z only):
            %     commonMode: one sample shared by all M measurements.
            %     sameTower:  one sample per unique tower, shared across antennas.
            %     independent: one sample per measurement.
            %   Full R = diag(R_diag + independentSigma^2)
            %            + commonModeSigma^2 * ones(M,M)
            %            + sameTowerSigma^2 blocks per tower group.

            z_out = z_in;
            if ~isfield(obj.cfg,'effects') || ~isfield(obj.cfg.effects,'correlatedNoise') || ...
                    ~obj.cfg.effects.correlatedNoise.enable
                R_out = diag(R_diag);
                return
            end

            cn = obj.cfg.effects.correlatedNoise;
            rng = obj.rngCorr;

            % Common-mode noise
            if cn.commonModeSigma_m > 0
                common = cn.commonModeSigma_m * randn(rng, 1, 1);
                z_out = z_out + common * ones(M,1);
            end

            % Same-tower noise
            if cn.sameTowerSigma_m > 0
                uniqTwrs = unique(twr_list);
                for k = 1:numel(uniqTwrs)
                    tNoise = cn.sameTowerSigma_m * randn(rng, 1, 1);
                    mask = (twr_list == uniqTwrs(k));
                    z_out(mask) = z_out(mask) + tNoise;
                end
            end

            % Independent correlated-noise component
            if cn.independentSigma_m > 0
                z_out = z_out + cn.independentSigma_m * randn(rng, M, 1);
            end

            % Build full R
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

        % ----------------------------------------------------------------
        function rho = computeModelRangeOnly_(obj, towers, ti, ai, r_cm, euler, leverArms_model)
            % computeModelRangeOnly_  Model geometric range for FD Jacobian.
            %
            % Includes model-side corrections (Sagnac, Shapiro, PCV) but NOT
            % clock terms or ErrorChain corrections (constants w.r.t. position/attitude).
            lever = leverArms_model(:, ai);
            r_ant = revgnss.AttitudeKinematics.applyLeverArm(r_cm, euler, lever);
            r_twr = obj.getTowerPosition_(towers{ti}, ti, 'model');

            % Tower PCO (model side)
            if isfield(obj.cfg,'effects') && isfield(obj.cfg.effects,'antennaPCO')
                pco = obj.cfg.effects.antennaPCO;
                if isfield(pco,'model') && pco.model.enable
                    tOff = pco.towerOffset_enu_m(:);
                    R_ENU = revgnss.GeometryUtils.enu2ecef(towers{ti}.lat_rad, towers{ti}.lon_rad);
                    r_twr = r_twr + R_ENU * tOff;
                end
            end

            % Use PCV with elevation from current geometry
            elv = revgnss.GeometryUtils.elevationAngle(r_twr, r_ant);
            rho = revgnss.RangeCorrections.correctedPseudorange(r_ant, r_twr, obj.cfg, 'model', elv);
        end

    end  % private methods

    methods (Static)

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
            end
        end

    end  % static methods

end
