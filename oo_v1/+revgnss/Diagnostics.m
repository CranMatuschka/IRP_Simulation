classdef Diagnostics < handle
    % Diagnostics  Accumulates per-epoch simulation diagnostics.
    %
    % Each call to record() appends one entry to obj.log.
    %
    % Stored per epoch (entry fields):
    %   time_s
    %   truth.*              truth state
    %   estimate.*           EKF state
    %   measurements.*       z, h, innovations, residuals
    %   errors.*             per-source error chain breakdown
    %   R, H, NIS
    %   positionError_m        scalar position error norm
    %   positionErrorVec_m     [3x1] ECEF position error components
    %   attitudeError_rad      [3x1] attitude error components
    %   clockBiasError_m       scalar
    %   clockDriftError_mps    scalar
    %   fracFreqError          scalar
    %   numVisibleTowers       scalar
    %   prefitInnovationRMS    scalar
    %   postfitResidualRMS     scalar
    %   perSourceTruthRMS      struct with one field per error source
    %   perSourceModelRMS      struct
    %   towerClockTruth_m      [M x 1] (visible towers this epoch)
    %   towerClockModel_m      [M x 1]
    %   towerClockCorrectionError_m [M x 1]
    %   attitudeJacobianNorm   scalar (Frobenius norm of H attitude columns)
    %   measurementRank        scalar
    %   conditionNumberS       scalar
    %   estimatedPositionSigma_m  scalar  1-sigma from P diagonal
    %   estimatedAttitudeSigma_rad scalar

    properties
        log     (:,1) struct
        nEpochs (1,1) double = 0
    end

    methods
        function obj = Diagnostics()
            obj.log = struct([]);
        end

        % ----------------------------------------------------------------
        function record(obj, t_s, asset, ekf, z, h, H, R, NIS, errStruct, ...
                visibleTowerIds, elevations_rad, postfitResidual)

            sm = ekf.stateMap;
            x  = ekf.x;
            c  = revgnss.Constants.SPEED_OF_LIGHT_MPS;

            entry.time_s = t_s;

            % --- Truth state -------------------------------------------
            entry.truth.r_cm_ecef_m       = asset.r_ecef_m;
            entry.truth.v_cm_ecef_mps     = asset.v_ecef_mps;
            entry.truth.euler_rad         = asset.attitude_euler_rad;
            entry.truth.omega_body_radps  = asset.angularRate_body_radps;
            entry.truth.r_ant_ecef_m      = asset.getAntennaPositionECEF();
            entry.truth.rxClockBias_m     = asset.clock.getBiasMeters();
            entry.truth.rxClockBias_s     = asset.clock.getBiasSeconds();
            entry.truth.rxFracFreq        = asset.clock.getFractionalFrequency();
            entry.truth.rxClockDrift_mps  = asset.clock.getDriftMetersPerSecond();

            % --- Estimate state ----------------------------------------
            entry.estimate.x                 = x;
            entry.estimate.P                 = ekf.P;
            entry.estimate.r_cm_ecef_m       = x(sm.r_idx);
            entry.estimate.v_cm_ecef_mps     = x(sm.v_idx);
            entry.estimate.euler_rad         = x(sm.euler_idx);
            entry.estimate.omega_body_radps  = x(sm.omega_idx);
            entry.estimate.rxClockBias_m     = x(sm.b_rx_idx);
            entry.estimate.rxClockDrift_mps  = x(sm.bdot_rx_idx);
            entry.estimate.r_ant_ecef_m      = revgnss.AttitudeKinematics.applyLeverArm( ...
                x(sm.r_idx), x(sm.euler_idx), asset.receiverLeverArm_body_m);

            % --- Measurements ------------------------------------------
            if ~isempty(z)
                entry.measurements.z                = z;
                entry.measurements.h                = h;
                entry.measurements.prefitInnovation = z - h;
                if nargin >= 13 && ~isempty(postfitResidual)
                    entry.measurements.postfitResidual = postfitResidual;
                else
                    entry.measurements.postfitResidual = z - h;  % fallback
                end
                entry.measurements.visibleTowerIds  = visibleTowerIds;
                entry.measurements.elevation_rad    = elevations_rad;
            else
                entry.measurements.z                = [];
                entry.measurements.h                = [];
                entry.measurements.prefitInnovation = [];
                entry.measurements.postfitResidual  = [];
                entry.measurements.visibleTowerIds  = [];
                entry.measurements.elevation_rad    = [];
            end

            % --- Error chain -------------------------------------------
            if ~isempty(errStruct)
                entry.errors.truthTotal_m = errStruct.truthTotal_m;
                entry.errors.modelTotal_m = errStruct.modelTotal_m;
                entry.errors.bySource     = errStruct.bySource;

                % Tower clock truth/model corrections (stored per visible tower)
                if isfield(errStruct,'towerClockTruth_m')
                    entry.towerClockTruth_m  = errStruct.towerClockTruth_m;
                    entry.towerClockModel_m  = errStruct.towerClockModel_m;
                    entry.towerClockCorrectionError_m = ...
                        errStruct.towerClockTruth_m - errStruct.towerClockModel_m;
                else
                    entry.towerClockTruth_m  = [];
                    entry.towerClockModel_m  = [];
                    entry.towerClockCorrectionError_m = [];
                end

                % Per-source RMS for this epoch (truth - model residual)
                labels = {'code','trop','iono','hwDelay','mp'};
                for j = 1:numel(labels)
                    lbl = labels{j};
                    if isfield(errStruct.bySource,'truth_m') && ...
                            isfield(errStruct.bySource.truth_m, lbl)
                        t_k = errStruct.bySource.truth_m.(lbl);
                        m_k = errStruct.bySource.model_m.(lbl);
                        if ~isempty(t_k)
                            entry.perSourceTruthRMS.(lbl) = sqrt(mean(t_k.^2));
                            entry.perSourceModelRMS.(lbl) = sqrt(mean(m_k.^2));
                        else
                            entry.perSourceTruthRMS.(lbl) = 0;
                            entry.perSourceModelRMS.(lbl) = 0;
                        end
                    else
                        entry.perSourceTruthRMS.(lbl) = 0;
                        entry.perSourceModelRMS.(lbl) = 0;
                    end
                end
            else
                entry.errors.truthTotal_m = [];
                entry.errors.modelTotal_m = [];
                entry.errors.bySource     = struct();
                entry.towerClockTruth_m   = [];
                entry.towerClockModel_m   = [];
                entry.towerClockCorrectionError_m = [];
                labels = {'code','trop','iono','hwDelay','mp'};
                for j = 1:numel(labels)
                    entry.perSourceTruthRMS.(labels{j}) = 0;
                    entry.perSourceModelRMS.(labels{j}) = 0;
                end
            end

            entry.R   = R;
            entry.H   = H;
            entry.NIS = NIS;

            % --- Scalar error metrics ----------------------------------
            r_err = x(sm.r_idx) - asset.r_ecef_m;
            entry.positionError_m    = norm(r_err);
            entry.positionErrorVec_m = r_err;

            eul_err = revgnss.AttitudeKinematics.wrapEuler( ...
                x(sm.euler_idx) - asset.attitude_euler_rad);
            entry.attitudeError_rad = eul_err;

            entry.clockBiasError_m     = x(sm.b_rx_idx) - asset.clock.getBiasMeters();
            entry.clockDriftError_mps  = x(sm.bdot_rx_idx) - asset.clock.getDriftMetersPerSecond();
            entry.fracFreqError        = entry.clockDriftError_mps / c;

            entry.numVisibleTowers = numel(visibleTowerIds);

            % --- Innovation / residual RMS per epoch -------------------
            if ~isempty(z)
                inn = z - h;
                entry.prefitInnovationRMS = sqrt(mean(inn.^2));
            else
                entry.prefitInnovationRMS = 0;
            end

            if nargin >= 13 && ~isempty(postfitResidual)
                entry.postfitResidualRMS = sqrt(mean(postfitResidual.^2));
            else
                entry.postfitResidualRMS = 0;
            end

            % --- Jacobian diagnostics ----------------------------------
            if ~isempty(H) && size(H,2) >= 9
                H_att = H(:, sm.euler_idx);
                entry.attitudeJacobianNorm = norm(H_att, 'fro');
                % Warn if attitude columns are near-zero (lever arm ~ 0 or bad geometry)
                if entry.attitudeJacobianNorm < 1e-10 && ~isempty(H) && mod(obj.nEpochs+1,500)==1
                    warning('Diagnostics:zeroAttJac', ...
                        'Attitude Jacobian is near-zero at t=%.0f s. Check lever arm.', t_s);
                end
            else
                entry.attitudeJacobianNorm = 0;
            end

            if ~isempty(H)
                entry.measurementRank = rank(H);
            else
                entry.measurementRank = 0;
            end

            if ~isempty(H) && ~isempty(R)
                S_mat = H * ekf.P * H' + R;
                entry.conditionNumberS = cond(S_mat);
            else
                entry.conditionNumberS = NaN;
            end

            % --- 1-sigma position bound from P diagonal ---------------
            Pdiag = diag(ekf.P);
            entry.estimatedPositionSigma_m   = sqrt(sum(Pdiag(sm.r_idx)));
            entry.estimatedAttitudeSigma_rad = sqrt(sum(Pdiag(sm.euler_idx)));

            % --- Append to log ----------------------------------------
            obj.nEpochs = obj.nEpochs + 1;
            if obj.nEpochs == 1
                obj.log = entry;
            else
                obj.log(obj.nEpochs) = entry;
            end
        end

        % ================================================================
        %  GETTERS
        % ================================================================

        function t = getTimeVector(obj)
            t = [obj.log.time_s]';
        end

        function e = getPositionErrors(obj)
            e = [obj.log.positionError_m]';
        end

        function e = getPositionErrorVecs(obj)
            % Returns [3 x nEpochs] matrix
            e = cell2mat({obj.log.positionErrorVec_m});
        end

        function e = getClockBiasErrors(obj)
            e = [obj.log.clockBiasError_m]';
        end

        function e = getClockDriftErrors(obj)
            e = [obj.log.clockDriftError_mps]';
        end

        function e = getFractionalFrequencyErrors(obj)
            e = [obj.log.fracFreqError]';
        end

        function n = getNIS(obj)
            n = [obj.log.NIS]';
        end

        function nu = getPrefitInnovationRMS(obj)
            nu = [obj.log.prefitInnovationRMS]';
        end

        function res = getPostfitResidualRMS(obj)
            res = [obj.log.postfitResidualRMS]';
        end

        function nv = getNumVisibleTowers(obj)
            nv = [obj.log.numVisibleTowers]';
        end

        function e = getAttitudeErrorVecs(obj)
            % Returns [3 x nEpochs] matrix of attitude errors [rad]
            e = cell2mat({obj.log.attitudeError_rad});
        end

        function perSrc = getPerSourceErrorRMS(obj)
            % Returns struct of [nEpochs x 1] vectors, one per error source.
            % Field values = truth-model residual RMS per epoch [m].
            labels = {'code','trop','iono','hwDelay','mp'};
            for j = 1:numel(labels)
                lbl = labels{j};
                vals = zeros(obj.nEpochs, 1);
                for k = 1:obj.nEpochs
                    ps = obj.log(k).perSourceTruthRMS;
                    if isfield(ps, lbl)
                        vals(k) = ps.(lbl);
                    end
                end
                perSrc.(lbl) = vals;
            end
        end

        function M = getTowerClockBiasMatrix(obj)
            % Returns cell array [nEpochs x 1] of tower clock truth biases [m].
            % Each cell contains [M_visible x 1] vector (visible towers that epoch).
            M = cell(obj.nEpochs, 1);
            for k = 1:obj.nEpochs
                M{k} = obj.log(k).towerClockTruth_m;
            end
        end

    end
end
