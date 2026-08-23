classdef GyroscopeObservation
    % GyroscopeObservation  Estimator-facing inertial body-rate observation.

    properties (SetAccess = private)
        sensorIdentifier
        biasStateIdentifier
        time_s
        omega_B_I_meas_body_radps
        whiteNoiseCovariance_rad2ps2
        biasRandomWalkPsd_rad2ps3
        valid
        status
    end

    methods
        function obj = GyroscopeObservation(sensorIdentifier, biasStateIdentifier, ...
                time_s, omegaMeasured_radps, whiteCovariance, biasRandomWalkPsd, ...
                valid, status)
            obj.sensorIdentifier = char(sensorIdentifier);
            obj.biasStateIdentifier = char(biasStateIdentifier);
            obj.time_s = time_s;
            obj.omega_B_I_meas_body_radps = omegaMeasured_radps(:);
            obj.whiteNoiseCovariance_rad2ps2 = whiteCovariance;
            obj.biasRandomWalkPsd_rad2ps3 = biasRandomWalkPsd;
            obj.valid = logical(valid);
            obj.status = char(status);

            assert(numel(obj.omega_B_I_meas_body_radps) == 3, ...
                'GyroscopeObservation:invalidMeasurement', ...
                'A gyroscope observation must contain three axes.');
            assert(isequal(size(whiteCovariance), [3,3]), ...
                'GyroscopeObservation:invalidCovariance', ...
                'Gyroscope white-noise covariance must be 3-by-3.');
        end
    end
end
