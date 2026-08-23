classdef StarTrackerObservation
    % StarTrackerObservation  Estimator-facing sensor-to-inertial attitude.
    %
    % The quaternion q_I_S_meas maps star-tracker sensor coordinates into
    % the inertial catalogue frame. Its uncertainty is a 3-by-3 tangent-space
    % angular covariance, never a four-component quaternion covariance.

    properties (SetAccess = private)
        sensorIdentifier
        time_s
        q_I_S_meas_wxyz
        whiteAngularCovariance_rad2
        valid
        status
        alignmentCalibration
    end

    methods
        function obj = StarTrackerObservation(sensorIdentifier, time_s, ...
                qMeasured, whiteAngularCovariance, valid, status, calibration)
            obj.sensorIdentifier = char(sensorIdentifier);
            obj.time_s = time_s;
            obj.valid = logical(valid);
            obj.status = char(status);
            obj.whiteAngularCovariance_rad2 = whiteAngularCovariance;
            obj.alignmentCalibration = calibration;
            if obj.valid
                obj.q_I_S_meas_wxyz = ...
                    revgnss.AttitudeQuaternion.normalize(qMeasured);
            else
                obj.q_I_S_meas_wxyz = nan(4,1);
            end

            assert(isequal(size(whiteAngularCovariance), [3,3]), ...
                'StarTrackerObservation:invalidCovariance', ...
                'Star-tracker angular covariance must be 3-by-3.');
        end
    end
end
