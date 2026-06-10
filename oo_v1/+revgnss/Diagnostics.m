classdef Diagnostics < handle
    % Diagnostics  Accumulates per-epoch simulation diagnostics.
    %
    % Stores truth, estimate, measurement, and error data each epoch
    % for post-simulation analysis and plotting.

    properties
        log (:,1) struct   % array of per-epoch log entries
        nEpochs (1,1) double = 0
    end

    methods
        function obj = Diagnostics()
            obj.log = struct([]);
        end

        function record(obj, t_s, asset, ekf, z, h, H, R, NIS, errStruct, ...
                visibleTowerIds, elevations_rad)
            % record  Append one epoch of data.

            sm = ekf.stateMap;
            x  = ekf.x;

            entry.time_s = t_s;

            % Truth
            entry.truth.r_cm_ecef_m       = asset.r_ecef_m;
            entry.truth.v_cm_ecef_mps     = asset.v_ecef_mps;
            entry.truth.euler_rad         = asset.attitude_euler_rad;
            entry.truth.omega_body_radps  = asset.angularRate_body_radps;
            entry.truth.r_ant_ecef_m      = asset.getAntennaPositionECEF();
            entry.truth.rxClockBias_m     = asset.clock.getBiasMeters();
            entry.truth.rxClockBias_s     = asset.clock.getBiasSeconds();
            entry.truth.rxFracFreq        = asset.clock.getFractionalFrequency();

            % Estimate
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

            % Measurements
            if ~isempty(z)
                entry.measurements.z                = z;
                entry.measurements.h                = h;
                entry.measurements.prefitInnovation = z - h;
                % Postfit residual: (I - H*K)*nu, approximated here as zero
                % because we do not have K available in Diagnostics.
                % For filter health use prefitInnovation; postfit = 0 is a v1 limitation.
                entry.measurements.postfitResidual  = zeros(size(z));
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

            % Errors
            if ~isempty(errStruct)
                entry.errors.truthTotal_m  = errStruct.truthTotal_m;
                entry.errors.modelTotal_m  = errStruct.modelTotal_m;
                entry.errors.bySource      = errStruct.bySource;
            else
                entry.errors.truthTotal_m = [];
                entry.errors.modelTotal_m = [];
                entry.errors.bySource     = struct();
            end

            entry.R   = R;
            entry.H   = H;
            entry.NIS = NIS;

            % Error metrics
            r_err = x(sm.r_idx) - asset.r_ecef_m;
            entry.positionError_m         = norm(r_err);
            entry.positionErrorVec_m      = r_err;

            eul_err = revgnss.AttitudeKinematics.wrapEuler( ...
                x(sm.euler_idx) - asset.attitude_euler_rad);
            entry.attitudeError_rad       = eul_err;

            entry.clockBiasError_m        = x(sm.b_rx_idx) - asset.clock.getBiasMeters();
            entry.numVisibleTowers        = numel(visibleTowerIds);

            % 1-sigma position bound from P diagonal
            Pdiag = diag(ekf.P);
            entry.estimatedPositionSigma_m  = sqrt(sum(Pdiag(sm.r_idx)));
            entry.estimatedAttitudeSigma_rad = sqrt(sum(Pdiag(sm.euler_idx)));

            obj.nEpochs = obj.nEpochs + 1;
            if obj.nEpochs == 1
                obj.log = entry;
            else
                obj.log(obj.nEpochs) = entry;
            end
        end

        % ----------------------------------------------------------------
        function t = getTimeVector(obj)
            t = [obj.log.time_s]';
        end

        function e = getPositionErrors(obj)
            e = [obj.log.positionError_m]';
        end

        function e = getPositionErrorVecs(obj)
            e = cell2mat({obj.log.positionErrorVec_m});  % 3 x N
        end

        function e = getClockBiasErrors(obj)
            e = [obj.log.clockBiasError_m]';
        end

        function n = getNIS(obj)
            n = [obj.log.NIS]';
        end

        function nu = getPrefitInnovationRMS(obj)
            nu = zeros(obj.nEpochs, 1);
            for k = 1:obj.nEpochs
                inn = obj.log(k).measurements.prefitInnovation;
                if ~isempty(inn)
                    nu(k) = sqrt(mean(inn.^2));
                end
            end
        end

        function nv = getNumVisibleTowers(obj)
            nv = [obj.log.numVisibleTowers]';
        end
    end
end
