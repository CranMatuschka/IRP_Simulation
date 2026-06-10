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
    % Truth measurement equation (no integer ambiguity in pseudorange):
    %   z_i = rho_ant_i
    %         + b_rx_true
    %         - b_tower_true_i
    %         + d_trop_truth_i
    %         + d_iono_truth_i
    %         + d_hw_truth_i
    %         + d_mp_truth_i
    %         + eps_code_i
    %
    % Estimator prediction:
    %   h_i = rho_ant_est_i
    %         + b_rx_est
    %         - b_tower_model_or_est_i
    %         + d_trop_model_i
    %         + d_iono_model_i
    %         + d_hw_model_i
    %
    % Jacobian:
    %   Position:  d rho / d r_cm = u'  (unit LOS from antenna to tower)
    %   Velocity:  zeros (no Doppler in v1)
    %   Attitude:  finite-difference  (d rho / d euler)
    %   Omega:     zeros
    %   b_rx:      +1
    %   bdot_rx:   0
    %   b_tower_i: -1  (if estimated)
    %   bdot_tower_i: 0

    properties
        cfg             (1,1) struct
        errorChain      revgnss.ErrorChain
        elevMask_rad    (1,1) double = 5 * pi/180   % minimum elevation [rad]
        attitudeJacStep_rad (1,1) double = 1e-6     % FD step for attitude Jacobian
    end

    methods
        function obj = MeasurementModel(cfg, errorChain)
            if nargin == 0; return; end
            obj.cfg        = cfg;
            obj.errorChain = errorChain;
            if isfield(cfg,'elevationMask_rad')
                obj.elevMask_rad = cfg.elevationMask_rad;
            end
            if isfield(cfg.estimator,'attitudeJacobianStep_rad')
                obj.attitudeJacStep_rad = cfg.estimator.attitudeJacobianStep_rad;
            end
        end

        % ----------------------------------------------------------------
        function [visible, elevations_rad] = computeVisibility(obj, towers, r_ant_ecef_m)
            % computeVisibility  Return logical mask and elevations for all towers.
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
            % computeMeasurements  Main measurement function.
            %
            % Inputs:
            %   asset     SpaceAsset (truth state)
            %   towers    cell array of GroundTower objects
            %   x_est     current EKF state vector
            %   t_s       current time [s]
            %   stateMap  struct with index assignments in state vector
            %
            % Outputs:
            %   z         [M x 1] truth pseudoranges
            %   h         [M x 1] predicted pseudoranges
            %   H         [M x nx] measurement Jacobian
            %   R         [M x M] diagonal measurement covariance
            %   errStruct struct with full error breakdown

            % ----- Truth quantities from state -------------------------
            r_cm_true  = asset.r_ecef_m;
            euler_true = asset.attitude_euler_rad;
            lever      = asset.receiverLeverArm_body_m;
            r_ant_true = revgnss.AttitudeKinematics.applyLeverArm( ...
                r_cm_true, euler_true, lever);

            % ----- EKF state extraction --------------------------------
            r_est   = x_est(stateMap.r_idx);
            euler_est = x_est(stateMap.euler_idx);
            b_rx_est  = x_est(stateMap.b_rx_idx);
            r_ant_est = revgnss.AttitudeKinematics.applyLeverArm( ...
                r_est, euler_est, lever);

            % ----- Visibility mask (based on truth antenna) -------------
            [visible, elevations_rad] = obj.computeVisibility(towers, r_ant_true);
            visIdx = find(visible);
            M      = numel(visIdx);
            nx     = numel(x_est);

            if M == 0
                z = []; h = []; H = zeros(0,nx); R = []; errStruct = [];
                return
            end

            % ----- Gather inputs for ErrorChain ------------------------
            towerIds  = cellfun(@(t) t.id, towers(visIdx))';
            towerIdx  = visIdx;
            elv       = elevations_rad(visIdx);

            errStruct = obj.errorChain.compute(elv, towerIds, towerIdx, t_s);

            z = zeros(M,1);
            h = zeros(M,1);
            R_diag = zeros(M,1);

            for mi = 1:M
                ti = visIdx(mi);
                twr = towers{ti};

                % --- Truth range (antenna to tower antenna) -------------
                r_twr = twr.getAntennaPositionECEF();
                rho_true = norm(r_ant_true - r_twr);

                % Tower clock truth
                b_twr_true = twr.getClockBiasMeters();

                % Receiver clock truth
                b_rx_true = asset.clock.getBiasMeters();

                % Assemble truth pseudorange
                z(mi) = rho_true ...
                    + b_rx_true ...
                    - b_twr_true ...
                    + errStruct.truthTotal_m(mi);

                % --- Predicted range (estimated antenna to tower) -------
                rho_est = norm(r_ant_est - r_twr);

                % Tower clock model/estimate
                % Guard: only index into state if tower clocks are actually estimated
                % (stateMap.towerClockIdx(ti,1) == 0 when estimateTowerClocks = false).
                if isfield(stateMap,'towerClockIdx') && ti <= size(stateMap.towerClockIdx,1) && ...
                        stateMap.towerClockIdx(ti,1) > 0
                    b_twr_est = x_est(stateMap.towerClockIdx(ti,1));
                else
                    b_twr_est = obj.getTowerClockModel_(twr, obj.cfg);
                end

                % Assemble predicted pseudorange
                h(mi) = rho_est ...
                    + b_rx_est ...
                    - b_twr_est ...
                    + errStruct.modelTotal_m(mi);

                % Measurement noise variance — apply floor to prevent R = 0
                sigmaFloor = 1e-3;
                if isfield(obj.cfg, 'measurement') && isfield(obj.cfg.measurement, 'sigmaFloor_m')
                    sigmaFloor = obj.cfg.measurement.sigmaFloor_m;
                end
                R_diag(mi) = max(errStruct.sigmaTotal_m(mi), sigmaFloor)^2;
            end

            % ----- Jacobian H ------------------------------------------
            H = obj.computeJacobian_(towers, visIdx, r_est, euler_est, ...
                lever, x_est, stateMap, nx);

            R = diag(R_diag);
        end

        % ----------------------------------------------------------------
        function H = computeJacobian_(obj, towers, visIdx, r_cm_est, ...
                euler_est, lever, x_est, stateMap, nx)
            % computeJacobian_  Build measurement Jacobian for visible towers.

            M = numel(visIdx);
            H = zeros(M, nx);

            r_ant_est = revgnss.AttitudeKinematics.applyLeverArm( ...
                r_cm_est, euler_est, lever);

            for mi = 1:M
                ti  = visIdx(mi);
                r_twr = towers{ti}.getAntennaPositionECEF();

                delta = r_ant_est - r_twr;
                rho   = norm(delta);
                if rho < 1; rho = 1; end   % guard against degenerate geometry

                u = delta / rho;  % unit LOS vector [3x1]

                % --- Position Jacobian: d_rho/d_r_cm ---
                % r_ant = r_cm + C * lever
                % d rho / d r_cm = u' * d r_ant / d r_cm = u' * I = u'
                H(mi, stateMap.r_idx) = u';

                % --- Velocity Jacobian: zeros in v1 ---------------------
                % (already zero from initialization)

                % --- Attitude Jacobian: finite-difference ---------------
                step = obj.attitudeJacStep_rad;
                euler_idx = stateMap.euler_idx;
                for ai = 1:3
                    eul_p = euler_est; eul_p(ai) = eul_p(ai) + step;
                    eul_m = euler_est; eul_m(ai) = eul_m(ai) - step;

                    r_ant_p = revgnss.AttitudeKinematics.applyLeverArm( ...
                        r_cm_est, eul_p, lever);
                    r_ant_m = revgnss.AttitudeKinematics.applyLeverArm( ...
                        r_cm_est, eul_m, lever);

                    rho_p = norm(r_ant_p - r_twr);
                    rho_m = norm(r_ant_m - r_twr);

                    H(mi, euler_idx(ai)) = (rho_p - rho_m) / (2 * step);
                end

                % --- Receiver clock bias: +1 ----------------------------
                H(mi, stateMap.b_rx_idx) = 1;

                % --- Tower clock states (if estimated) ------------------
                if isfield(stateMap,'towerClockIdx') && ...
                        ti <= size(stateMap.towerClockIdx,1) && ...
                        stateMap.towerClockIdx(ti,1) > 0
                    H(mi, stateMap.towerClockIdx(ti,1)) = -1;
                end
            end
        end

        % ----------------------------------------------------------------
        function b_model = getTowerClockModel_(obj, twr, cfg)
            % Choose tower clock correction based on cfg.estimator.towerClockMode.
            towerClockMode = 'none';
            if isfield(cfg, 'estimator') && isfield(cfg.estimator, 'towerClockMode')
                towerClockMode = cfg.estimator.towerClockMode;
            elseif isfield(cfg, 'towerClockMode')
                towerClockMode = cfg.towerClockMode;
            end
            switch towerClockMode
                case 'none'
                    b_model = 0;
                case 'perfectCorrection'
                    b_model = twr.getClockBiasMeters();
                case 'noisyCorrection'
                    sigma = 0.1;
                    if isfield(cfg,'towerClockCorrectionSigma_m')
                        sigma = cfg.towerClockCorrectionSigma_m;
                    end
                    b_model = twr.getClockBiasMeters() + sigma * randn;
                otherwise
                    b_model = 0;
            end
        end
    end
end
