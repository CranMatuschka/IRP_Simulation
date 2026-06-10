classdef MeasurementModel < handle
    % MeasurementModel  Pseudorange measurement equations for reverse-GNSS.
    %
    % Responsibilities:
    %   - Compute truth pseudorange z from truth state + ErrorChain
    %   - Compute predicted pseudorange h from estimated state
    %   - Compute measurement Jacobian H
    %   - Compute visibility mask (elevation filter)
    %   - Assemble diagonal measurement covariance R
    %
    % -----------------------------------------------------------------------
    % TRUTH/MODEL SEPARATION
    %
    % Truth measurement:
    %   z_i = rho_ant_true_i + b_rx_true - b_twr_true_i + eps_chain_i
    %
    % Predicted measurement:
    %   h_i = rho_ant_est_i  + b_rx_est  - b_twr_model_i + model_chain_i
    %
    % Tower clock corrections are computed ONCE per epoch (at the start of
    % computeMeasurements) and stored in errStruct.  This prevents multiple
    % randn() calls when h is recomputed for postfit residuals — the same
    % correction product is reused.
    %
    % -----------------------------------------------------------------------
    % JACOBIAN
    %   Position:  d rho / d r_cm = u'  (unit LOS, tower -> antenna)
    %   Velocity:  zeros (no Doppler in v1)
    %   Attitude:  finite-difference (d rho / d euler)
    %   Omega:     zeros
    %   b_rx:      +1
    %   b_tower_i: -1  (if estimated)

    properties
        cfg             (1,1) struct
        errorChain      revgnss.ErrorChain
        elevMask_rad    (1,1) double = 5 * pi/180
        attitudeJacStep_rad (1,1) double = 1e-6
        ambiguityMap                       % containers.Map: (tower*1000+antenna) → integer N
    end

    methods
        function obj = MeasurementModel(cfg, errorChain)
            if nargin == 0; return; end
            obj.cfg          = cfg;
            obj.errorChain   = errorChain;
            obj.ambiguityMap = [];   % populated lazily on first carrier phase call
            if isfield(cfg,'elevationMask_rad')
                obj.elevMask_rad = cfg.elevationMask_rad;
            end
            if isfield(cfg.estimator,'attitudeJacobianStep_rad')
                obj.attitudeJacStep_rad = cfg.estimator.attitudeJacobianStep_rad;
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
            %
            % Tower clock corrections are generated ONCE and stored in errStruct
            % so postfit residuals reuse the same samples.

            % ----- All lever arms (3 x N_ant) --------------------------
            leverArms = asset.receiverLeverArms_body_m;   % 3 x N_ant
            N_ant = size(leverArms, 2);

            % ----- Truth state -----------------------------------------
            r_cm_true  = asset.r_ecef_m;
            euler_true = asset.attitude_euler_rad;
            b_rx_true  = asset.clock.getBiasMeters();

            % ----- EKF state extraction --------------------------------
            r_est     = x_est(stateMap.r_idx);
            euler_est = x_est(stateMap.euler_idx);
            b_rx_est  = x_est(stateMap.b_rx_idx);

            % ----- All truth/estimated antenna positions ---------------
            r_ants_true = asset.getAntennaPositionsECEF(r_cm_true, euler_true);  % 3xN_ant
            r_ants_est  = asset.getAntennaPositionsECEF(r_est,     euler_est);   % 3xN_ant

            nx     = numel(x_est);
            N_twr  = numel(towers);

            % ----- Build (tower, antenna) pair visibility list ----------
            % Each visible pair contributes one pseudorange measurement.
            twr_list = zeros(N_twr * N_ant, 1);
            ant_list = zeros(N_twr * N_ant, 1);
            elv_list = zeros(N_twr * N_ant, 1);
            cnt = 0;
            for ti = 1:N_twr
                r_twr = towers{ti}.getAntennaPositionECEF();
                for ai = 1:N_ant
                    elv = revgnss.GeometryUtils.elevationAngle(r_twr, r_ants_true(:,ai));
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

            % ----- Error chain (per measurement, i.e. per tower-ant pair) --
            towerIds = arrayfun(@(ti) towers{ti}.id, twr_list);
            errStruct = obj.errorChain.compute(elv_list, towerIds, twr_list, t_s);

            % ----- Tower clock corrections — generated ONCE per epoch ------
            towerClkMode  = obj.getTowerClockMode_();
            towerClkTruth = zeros(M,1);
            towerClkModel = zeros(M,1);
            towerClkSigma = zeros(M,1);

            noiseSigma = obj.cfg.estimator.towerClockCorrectionSigma_m;
            if isfield(obj.cfg,'towerClockCorrectionSigma_m')
                noiseSigma = obj.cfg.towerClockCorrectionSigma_m;
            end
            % Use stream-based draw so global rng state is never touched
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

            % Attach to errStruct for postfit residuals / diagnostics
            errStruct.towerClockTruth_m      = towerClkTruth;
            errStruct.towerClockModel_m      = towerClkModel;
            errStruct.towerClockModelSigma_m = towerClkSigma;
            errStruct.towerIdx_perMeas       = twr_list;   % [M x 1]
            errStruct.antennaIdx_perMeas     = ant_list;   % [M x 1]

            % ----- Build z, h, R ----------------------------------------
            z      = zeros(M,1);
            h      = zeros(M,1);
            R_diag = zeros(M,1);

            sigmaFloor = obj.cfg.measurement.sigmaFloor_m;

            % Storage for per-correction diagnostics
            sagnacTruth_m  = zeros(M,1);
            sagnacModel_m  = zeros(M,1);
            shapiroTruth_m = zeros(M,1);
            shapiroModel_m = zeros(M,1);

            for mi = 1:M
                ti  = twr_list(mi);
                ai  = ant_list(mi);
                twr = towers{ti};
                r_twr = twr.getAntennaPositionECEF();

                % Truth pseudorange with corrections
                [rho_true, cTruth] = revgnss.RangeCorrections.correctedPseudorange( ...
                    r_ants_true(:,ai), r_twr, obj.cfg, 'truth');
                sagnacTruth_m(mi)  = cTruth.sagnac;
                shapiroTruth_m(mi) = cTruth.shapiro;
                z(mi) = rho_true + b_rx_true - towerClkTruth(mi) + errStruct.truthTotal_m(mi);

                % Predicted pseudorange with corrections
                [rho_est, cModel] = revgnss.RangeCorrections.correctedPseudorange( ...
                    r_ants_est(:,ai), r_twr, obj.cfg, 'model');
                sagnacModel_m(mi)  = cModel.sagnac;
                shapiroModel_m(mi) = cModel.shapiro;

                % Tower clock model: EKF state if estimating, else pre-computed correction
                if isfield(stateMap,'towerClockIdx') && ti <= size(stateMap.towerClockIdx,1) && ...
                        stateMap.towerClockIdx(ti,1) > 0
                    b_twr_h = x_est(stateMap.towerClockIdx(ti,1));
                else
                    b_twr_h = towerClkModel(mi);
                end

                h(mi) = rho_est + b_rx_est - b_twr_h + errStruct.modelTotal_m(mi);

                % Measurement noise variance: stochastic uncertainty only
                sigma_i = sqrt(errStruct.sigmaTotal_m(mi)^2 + towerClkSigma(mi)^2);
                R_diag(mi) = max(sigma_i, sigmaFloor)^2;
            end

            % Attach correction diagnostics to errStruct
            errStruct.sagnacTruth_m  = sagnacTruth_m;
            errStruct.sagnacModel_m  = sagnacModel_m;
            errStruct.shapiroTruth_m = shapiroTruth_m;
            errStruct.shapiroModel_m = shapiroModel_m;

            % ----- Jacobian H (pseudorange only) -----------------------
            H_pr = obj.computeJacobian_(towers, twr_list, ant_list, ...
                r_est, euler_est, leverArms, x_est, stateMap, nx);

            % ----- Doppler (pseudorange-rate) rows ----------------------
            doCfg = isfield(obj.cfg,'measurements') && ...
                    isfield(obj.cfg.measurements,'doppler') && ...
                    obj.cfg.measurements.doppler.enable;

            if doCfg
                v_rx_true = asset.v_ecef_mps;
                v_rx_est  = x_est(stateMap.v_idx);
                bdot_rx_true = asset.clock.getDriftMetersPerSecond();
                bdot_rx_est  = x_est(stateMap.bdot_rx_idx);
                sigma_dop = obj.cfg.measurements.doppler.sigma_mps;

                zd     = zeros(M,1);
                hd     = zeros(M,1);
                Hd     = zeros(M,nx);
                Rd_diag = sigma_dop^2 * ones(M,1);

                for mi = 1:M
                    ti  = twr_list(mi);
                    ai  = ant_list(mi);
                    r_twr = towers{ti}.getAntennaPositionECEF();

                    % Truth range rate
                    delta_t = r_ants_true(:,ai) - r_twr;
                    rho_t   = norm(delta_t); if rho_t < 1; rho_t = 1; end
                    u_t     = delta_t / rho_t;
                    rhoDot_true = u_t' * v_rx_true;   % v_twr = 0
                    zd(mi) = rhoDot_true + bdot_rx_true + ...
                             sigma_dop * obj.errorChain.drawNormal(1,1);

                    % Model range rate + Jacobian
                    delta_e = r_ants_est(:,ai) - r_twr;
                    rho_e   = norm(delta_e); if rho_e < 1; rho_e = 1; end
                    u_e     = delta_e / rho_e;
                    rhoDot_est = u_e' * v_rx_est;
                    hd(mi) = rhoDot_est + bdot_rx_est;

                    % H: velocity = u', clock drift = 1, others = 0
                    Hd(mi, stateMap.v_idx)       = u_e';
                    Hd(mi, stateMap.bdot_rx_idx) = 1;
                end

                useInEKF = obj.cfg.measurements.doppler.useInEKF;
                errStruct.doppler.z     = zd;
                errStruct.doppler.h     = hd;
                errStruct.doppler.prefit = zd - hd;

                if useInEKF
                    z = [z; zd];
                    h = [h; hd];
                    H_pr = [H_pr; Hd];
                    R_diag = [R_diag; Rd_diag];
                end
            else
                errStruct.doppler = struct();
            end

            H = H_pr;
            R = diag(R_diag);

            % ----- Carrier phase (diagnostic only; never used in EKF v1) --
            doCpCfg = isfield(obj.cfg,'measurements') && ...
                      isfield(obj.cfg.measurements,'carrierPhase') && ...
                      obj.cfg.measurements.carrierPhase.enable;

            if doCpCfg
                if obj.cfg.measurements.carrierPhase.useInEKF
                    % Check for ambiguity states (Stage 4)
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
                    asset, towers, twr_list, ant_list, r_ants_true);
            else
                errStruct.carrierPhase = struct();
            end
        end

        % ----------------------------------------------------------------
        function H = computeJacobian_(obj, towers, twr_list, ant_list, ...
                r_cm_est, euler_est, leverArms, x_est, stateMap, nx)
            % computeJacobian_  Measurement Jacobian for visible tower-antenna pairs.
            %
            % Attitude H columns are nonzero ONLY when:
            %   estimateAttitudeFromPseudorange == true  AND  norm(lever) > 0.
            % Otherwise attitude states are unobservable by design (default).

            M = numel(twr_list);
            H = zeros(M, nx);

            % Gate attitude Jacobian: both estimateAttitude AND estimateAttitudeFromPseudorange
            doAttJac = isfield(obj.cfg.estimator, 'estimateAttitude') && ...
                       obj.cfg.estimator.estimateAttitude && ...
                       isfield(obj.cfg.estimator, 'estimateAttitudeFromPseudorange') && ...
                       obj.cfg.estimator.estimateAttitudeFromPseudorange;

            step    = obj.attitudeJacStep_rad;
            eul_idx = stateMap.euler_idx;

            for mi = 1:M
                ti  = twr_list(mi);
                ai  = ant_list(mi);
                lever = leverArms(:, ai);

                r_twr     = towers{ti}.getAntennaPositionECEF();
                r_ant_est = revgnss.AttitudeKinematics.applyLeverArm( ...
                    r_cm_est, euler_est, lever);

                delta = r_ant_est - r_twr;
                rho   = norm(delta);
                if rho < 1; rho = 1; end

                u = delta / rho;   % unit LOS vector [3x1]

                % Position Jacobian: d_rho / d_r_cm = u'
                H(mi, stateMap.r_idx) = u';

                % Attitude Jacobian: finite-difference, gated by config + lever arm
                if doAttJac && norm(lever) > 1e-9
                    for ai2 = 1:3
                        eul_p = euler_est; eul_p(ai2) = eul_p(ai2) + step;
                        eul_m = euler_est; eul_m(ai2) = eul_m(ai2) - step;
                        r_p = revgnss.AttitudeKinematics.applyLeverArm(r_cm_est, eul_p, lever);
                        r_m = revgnss.AttitudeKinematics.applyLeverArm(r_cm_est, eul_m, lever);
                        H(mi, eul_idx(ai2)) = (norm(r_p - r_twr) - norm(r_m - r_twr)) / (2*step);
                    end
                end
                % omega columns remain zero (no Doppler v1; attitude rates
                % only appear when attitude itself is observed).

                % Receiver clock bias: +1
                H(mi, stateMap.b_rx_idx) = 1;

                % Tower clock state (if estimated): -1
                if isfield(stateMap,'towerClockIdx') && ...
                        ti <= size(stateMap.towerClockIdx,1) && ...
                        stateMap.towerClockIdx(ti,1) > 0
                    H(mi, stateMap.towerClockIdx(ti,1)) = -1;
                end
            end
        end

        % ----------------------------------------------------------------
        function mode = getTowerClockMode_(obj)
            % getTowerClockMode_  Return tower clock mode string from config.
            mode = 'none';
            if isfield(obj.cfg,'estimator') && isfield(obj.cfg.estimator,'towerClockMode')
                mode = obj.cfg.estimator.towerClockMode;
            elseif isfield(obj.cfg,'towerClockMode')
                mode = obj.cfg.towerClockMode;
            end
        end

        % ----------------------------------------------------------------
        function cp = computeCarrierPhase_(obj, asset, towers, twr_list, ant_list, r_ants_true)
            % computeCarrierPhase_  Generate truth carrier phase observables (diagnostic).
            %
            % z_phi_cycles = (rho + b_rx - b_twr)/lambda + N_ia
            % N_ia is a constant integer ambiguity per (tower, antenna) arc.
            % No cycle slips in v1.
            cpc    = obj.cfg.measurements.carrierPhase;
            lambda = cpc.lambda_m;
            sigma  = cpc.sigma_cycles;
            M      = numel(twr_list);

            % Initialise ambiguity map lazily (persistent across epochs via property)
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
            phi    = zeros(M,1);
            ambig  = zeros(M,1);
            for mi = 1:M
                ti   = twr_list(mi);
                ai   = ant_list(mi);
                r_twr = towers{ti}.getAntennaPositionECEF();
                b_twr = towers{ti}.getClockBiasMeters();
                rho   = norm(r_ants_true(:,ai) - r_twr);
                key   = int32(ti * 1000 + ai);
                N_ia  = obj.ambiguityMap(key);
                ambig(mi) = N_ia;
                phi(mi) = (rho + b_rx_true - b_twr) / lambda + N_ia + ...
                          sigma * obj.errorChain.drawNormal(1,1);
            end
            cp.phi_cycles      = phi;
            cp.ambiguity_int   = ambig;
            cp.lambda_m        = lambda;
            cp.towerIdx        = twr_list;
            cp.antennaIdx      = ant_list;
        end

        % ----------------------------------------------------------------
        function b_model = getTowerClockModel_(obj, twr, cfg)
            % getTowerClockModel_  Legacy single-tower clock correction helper.
            %
            % NOTE: This method calls randn when mode = 'noisyCorrection'.
            %       For the main simulation, use the stored towerClockModel_m
            %       from errStruct instead, to avoid repeated noise draws.
            %       This method remains for test/standalone use only.
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

    end
end
