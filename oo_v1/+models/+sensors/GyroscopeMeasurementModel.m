classdef GyroscopeMeasurementModel < handle
    % GyroscopeMeasurementModel  Inertial angular-rate sensor truth model.
    %
    % The measured quantity is omega_B/I^B:
    %   omega_meas^B = omega_B/I^B + b_g + n_g.
    % If the attitude law supplies omega_B/E^B, Earth rate is added as
    %   omega_B/I^B = omega_B/E^B + C_B_E omega_E/I^E.

    properties (SetAccess = private)
        sensorIdentifier
        biasStateIdentifier
        angleRandomWalk_rad_per_sqrt_s
        biasRandomWalk_radps_per_sqrt_s
        initialBiasSigma_radps
        seed
    end

    properties (Access = private)
        biasTruth_radps
        noiseStream
        lastSampleTime_s
    end

    methods
        function obj = GyroscopeMeasurementModel(cfg)
            if nargin < 1
                cfg = struct();
            end
            obj.sensorIdentifier = char(i_field(cfg, 'sensorIdentifier', 'gyro-1'));
            obj.biasStateIdentifier = char(i_field(cfg, 'biasStateIdentifier', ...
                [obj.sensorIdentifier ':bias']));
            obj.angleRandomWalk_rad_per_sqrt_s = ...
                i_field(cfg, 'angleRandomWalk_rad_per_sqrt_s', 1e-4);
            obj.biasRandomWalk_radps_per_sqrt_s = ...
                i_field(cfg, 'biasRandomWalk_radps_per_sqrt_s', 1e-6);
            obj.initialBiasSigma_radps = ...
                i_field(cfg, 'initialBiasSigma_radps', 1e-5);
            obj.seed = i_field(cfg, 'seed', 909);
            obj.validateConfiguration_();
            obj.reset();
        end

        function reset(obj)
            obj.noiseStream = RandStream('mt19937ar', 'Seed', obj.seed);
            obj.biasTruth_radps = obj.initialBiasSigma_radps * ...
                randn(obj.noiseStream, 3, 1);
            obj.lastSampleTime_s = NaN;
        end

        function observation = sampleFromEarthRelative(obj, omega_B_E_body_radps, ...
                q_E_B, dt_s, time_s, omega_E_I_ecef_radps)
            if nargin < 6 || isempty(omega_E_I_ecef_radps)
                omega_E_I_ecef_radps = models.frames.FrameTimeUtils.omegaEcef_radps();
            end
            omega_B_I_body_radps = ...
                models.sensors.GyroscopeMeasurementModel.inertialRateFromEarthRelative( ...
                omega_B_E_body_radps, q_E_B, omega_E_I_ecef_radps);
            observation = obj.sampleFromInertial(omega_B_I_body_radps, dt_s, time_s);
        end

        function observation = sampleFromInertial(obj, omega_B_I_body_radps, dt_s, time_s)
            assert(isscalar(dt_s) && isfinite(dt_s) && dt_s > 0, ...
                'GyroscopeMeasurementModel:invalidTimeStep', ...
                'Gyroscope sample interval must be finite and positive.');
            assert(isscalar(time_s) && isfinite(time_s), ...
                'GyroscopeMeasurementModel:invalidEpoch', ...
                'Gyroscope sample epoch must be finite.');
            omega = omega_B_I_body_radps(:);
            assert(numel(omega) == 3 && all(isfinite(omega)), ...
                'GyroscopeMeasurementModel:invalidBodyRate', ...
                'Inertial body rate must contain three finite components.');

            biasStep_s = 0;
            if isfinite(obj.lastSampleTime_s)
                biasStep_s = time_s - obj.lastSampleTime_s;
                assert(biasStep_s >= 0, ...
                    'GyroscopeMeasurementModel:nonMonotonicTime', ...
                    'Gyroscope samples must be generated in nondecreasing time order.');
            end
            if biasStep_s > 0
                obj.biasTruth_radps = obj.biasTruth_radps + ...
                    obj.biasRandomWalk_radps_per_sqrt_s*sqrt(biasStep_s)* ...
                    randn(obj.noiseStream, 3, 1);
            end
            obj.lastSampleTime_s = time_s;
            sigmaRate = obj.angleRandomWalk_rad_per_sqrt_s/sqrt(dt_s);
            omegaMeasured = omega + obj.biasTruth_radps + ...
                sigmaRate*randn(obj.noiseStream, 3, 1);
            R = sigmaRate^2*eye(3);
            biasPsd = obj.biasRandomWalk_radps_per_sqrt_s^2*eye(3);

            observation = models.sensors.GyroscopeObservation( ...
                obj.sensorIdentifier, obj.biasStateIdentifier, time_s, ...
                omegaMeasured, R, biasPsd, true, 'valid');
        end

        function [omegaCorrected_radps, model] = estimatorInput(~, observation, ...
                estimatedBias_radps)
            assert(isa(observation, 'models.sensors.GyroscopeObservation') && ...
                observation.valid, ...
                'GyroscopeMeasurementModel:invalidObservation', ...
                'A valid GyroscopeObservation is required.');
            estimatedBias_radps = estimatedBias_radps(:);
            assert(numel(estimatedBias_radps) == 3 && all(isfinite(estimatedBias_radps)), ...
                'GyroscopeMeasurementModel:invalidBiasEstimate', ...
                'Estimated gyroscope bias must contain three finite components.');
            omegaCorrected_radps = observation.omega_B_I_meas_body_radps - ...
                estimatedBias_radps;
            model.biasJacobian = -eye(3);
            model.directInitialAttitudeJacobian = zeros(3);
            model.whiteNoiseCovariance_rad2ps2 = ...
                observation.whiteNoiseCovariance_rad2ps2;
            model.biasRandomWalkPsd_rad2ps3 = ...
                observation.biasRandomWalkPsd_rad2ps3;
            model.rateConvention = 'omega_B/I expressed in B';
            model.absoluteAttitudeInformation = 'none without an external attitude observation';
        end
    end

    methods (Static)
        function omega_B_I_body_radps = inertialRateFromEarthRelative( ...
                omega_B_E_body_radps, q_E_B, omega_E_I_ecef_radps)
            if nargin < 3
                omega_E_I_ecef_radps = [];
            end
            omega_B_I_body_radps = ...
                models.sensors.IMUModel.inertialRateFromEarthRelative( ...
                omega_B_E_body_radps,q_E_B,omega_E_I_ecef_radps);
        end
    end

    methods (Access = private)
        function validateConfiguration_(obj)
            values = [obj.angleRandomWalk_rad_per_sqrt_s, ...
                obj.biasRandomWalk_radps_per_sqrt_s, obj.initialBiasSigma_radps];
            assert(numel(values) == 3 && all(isfinite(values)) && all(values >= 0), ...
                'GyroscopeMeasurementModel:invalidNoise', ...
                'Gyroscope noise parameters must be finite nonnegative scalars.');
            assert(isscalar(obj.seed) && isfinite(obj.seed) && obj.seed >= 0, ...
                'GyroscopeMeasurementModel:invalidSeed', ...
                'Gyroscope seed must be a finite nonnegative scalar.');
        end
    end
end

function value = i_field(s, name, defaultValue)
    value = defaultValue;
    if isstruct(s) && isfield(s, name) && ~isempty(s.(name))
        value = s.(name);
    end
end
