classdef StarTrackerMeasurementModel < handle
    % StarTrackerMeasurementModel  Quaternion observation generator and model.
    %
    % q_I_B maps body coordinates into the inertial catalogue frame and
    % q_B_S maps sensor coordinates into body coordinates. The tracker reports
    % q_I_S = q_I_B (x) q_B_S with right-multiplicative angular noise.
    % Calibration covariance is for q_B_S,true = q_B_S,cal (x) Exp(deltaAlpha_S);
    % its stable identifier preserves the resulting cross-epoch correlation.

    properties (SetAccess = private)
        sensorIdentifier
        updatePeriod_s
        updatePhase_s
        whiteAngularCovariance_rad2
        fixedAlignmentBias_rad
        alignmentDriftRate_radps
        alignmentDriftRandomWalk_rad_per_sqrt_s
        drawAlignmentFromCalibrationCovariance
        seed
        alignmentCalibration
    end

    properties (Access = private)
        noiseStream
        alignmentErrorQuaternion
        lastTime_s
        nextMeasurementTime_s
    end

    methods
        function obj = StarTrackerMeasurementModel(sensorCfg, calibrationProduct)
            if nargin < 1
                sensorCfg = struct();
            end
            if nargin < 2
                calibrationProduct = struct();
            end
            obj.sensorIdentifier = char(i_field(sensorCfg, ...
                'sensorIdentifier', 'star-tracker-1'));
            obj.updatePeriod_s = i_field(sensorCfg, 'updatePeriod_s', 1);
            obj.updatePhase_s = i_field(sensorCfg, 'updatePhase_s', 0);
            sigma = i_field(sensorCfg, 'whiteAngularSigma_rad', 10e-6);
            obj.whiteAngularCovariance_rad2 = i_field(sensorCfg, ...
                'whiteAngularCovariance_rad2', sigma^2*eye(3));
            obj.fixedAlignmentBias_rad = i_vector(sensorCfg, ...
                'fixedAlignmentBias_rad', zeros(3,1));
            obj.alignmentDriftRate_radps = i_vector(sensorCfg, ...
                'alignmentDriftRate_radps', zeros(3,1));
            obj.alignmentDriftRandomWalk_rad_per_sqrt_s = i_field(sensorCfg, ...
                'alignmentDriftRandomWalk_rad_per_sqrt_s', 0);
            obj.drawAlignmentFromCalibrationCovariance = logical(i_field(sensorCfg, ...
                'drawAlignmentFromCalibrationCovariance', false));
            obj.seed = i_field(sensorCfg, 'seed', 1201);
            obj.alignmentCalibration = obj.canonicalCalibration_(calibrationProduct);
            obj.validateConfiguration_();
            obj.reset();
        end

        function reset(obj)
            obj.noiseStream = RandStream('mt19937ar', 'Seed', obj.seed);
            obj.alignmentErrorQuaternion = ...
                revgnss.AttitudeQuaternion.fromRotationVector( ...
                obj.fixedAlignmentBias_rad);
            if obj.drawAlignmentFromCalibrationCovariance
                calibrationDraw = obj.gaussianDraw_( ...
                    obj.alignmentCalibration.covariance_rad2);
                obj.alignmentErrorQuaternion = ...
                    revgnss.AttitudeQuaternion.multiply( ...
                    obj.alignmentErrorQuaternion, ...
                    revgnss.AttitudeQuaternion.fromRotationVector(calibrationDraw));
            end
            obj.lastTime_s = NaN;
            obj.nextMeasurementTime_s = obj.updatePhase_s;
        end

        function observation = sampleFromEarthFixedAttitude(obj, q_E_B, time_s, available)
            if nargin < 4
                available = true;
            end
            q_I_B = revgnss.AttitudeQuaternion.ecefBodyToInertial(q_E_B, time_s);
            observation = obj.sampleFromInertialAttitude(q_I_B, time_s, available);
        end

        function observation = sampleFromInertialAttitude(obj, q_I_B_truth, time_s, available)
            if nargin < 4
                available = true;
            end
            obj.advanceAlignment_(time_s);
            due = time_s + 10*eps(max(1,abs(time_s))) >= obj.nextMeasurementTime_s;
            if due
                while obj.nextMeasurementTime_s <= time_s + ...
                        10*eps(max(1,abs(time_s)))
                    obj.nextMeasurementTime_s = obj.nextMeasurementTime_s + ...
                        obj.updatePeriod_s;
                end
            end

            productValid = time_s >= obj.alignmentCalibration.validFrom_s && ...
                time_s <= obj.alignmentCalibration.validUntil_s;
            if ~due
                observation = obj.invalidObservation_(time_s, 'notScheduled');
                return
            elseif ~logical(available)
                observation = obj.invalidObservation_(time_s, 'excludedOrOutage');
                return
            elseif ~productValid
                observation = obj.invalidObservation_(time_s, ...
                    'alignmentCalibrationOutsideValidity');
                return
            end

            q_B_S_truth = revgnss.AttitudeQuaternion.multiply( ...
                obj.alignmentCalibration.q_B_S_wxyz, ...
                obj.alignmentErrorQuaternion);
            q_I_S_truth = revgnss.AttitudeQuaternion.multiply( ...
                q_I_B_truth, q_B_S_truth);
            angularNoise = obj.gaussianDraw_(obj.whiteAngularCovariance_rad2);
            q_I_S_measured = revgnss.AttitudeQuaternion.multiply( ...
                q_I_S_truth, ...
                revgnss.AttitudeQuaternion.fromRotationVector(angularNoise));
            observation = models.sensors.StarTrackerObservation( ...
                obj.sensorIdentifier, time_s, q_I_S_measured, ...
                obj.whiteAngularCovariance_rad2, true, 'valid', ...
                obj.alignmentCalibration);
        end

        function [innovation_rad, model] = linearizedResidual(~, q_I_B_estimate, ...
                observation, nominalAlignmentCorrection_rad)
            if nargin < 4 || isempty(nominalAlignmentCorrection_rad)
                nominalAlignmentCorrection_rad = zeros(3,1);
            end
            [innovation_rad,model] = ...
                models.sensors.StarTrackerObservationModel.linearizedResidual( ...
                q_I_B_estimate,observation,nominalAlignmentCorrection_rad);
        end
    end

    methods (Access = private)
        function calibration = canonicalCalibration_(obj, supplied)
            calibration.identifier = char(i_field(supplied, 'identifier', ...
                [obj.sensorIdentifier ':body-alignment']));
            calibration.q_B_S_wxyz = revgnss.AttitudeQuaternion.normalize( ...
                i_field(supplied, 'q_B_S_wxyz', [1;0;0;0]));
            calibration.covariance_rad2 = i_field(supplied, ...
                'covariance_rad2', zeros(3));
            calibration.validFrom_s = i_field(supplied, 'validFrom_s', -inf);
            calibration.validUntil_s = i_field(supplied, 'validUntil_s', inf);
            calibration.treatment = char(i_field(supplied, ...
                'treatment', 'considerParameter'));
            calibration.driftProcessNoise_rad2ps = i_field(supplied, ...
                'driftProcessNoise_rad2ps', zeros(3));
        end

        function validateConfiguration_(obj)
            assert(isscalar(obj.updatePeriod_s) && isfinite(obj.updatePeriod_s) && ...
                obj.updatePeriod_s > 0, ...
                'StarTrackerMeasurementModel:invalidUpdatePeriod', ...
                'Star-tracker update period must be finite and positive.');
            assert(isscalar(obj.updatePhase_s) && isfinite(obj.updatePhase_s) && ...
                obj.updatePhase_s >= 0 && obj.updatePhase_s < obj.updatePeriod_s, ...
                'StarTrackerMeasurementModel:invalidUpdatePhase', ...
                'Update phase must lie in [0, updatePeriod).');
            i_validateCovariance(obj.whiteAngularCovariance_rad2, ...
                'white angular covariance');
            i_validateCovariance(obj.alignmentCalibration.covariance_rad2, ...
                'alignment calibration covariance');
            i_validateCovariance(obj.alignmentCalibration.driftProcessNoise_rad2ps, ...
                'alignment drift process-noise PSD');
            assert(obj.alignmentCalibration.validUntil_s >= ...
                obj.alignmentCalibration.validFrom_s, ...
                'StarTrackerMeasurementModel:invalidCalibrationValidity', ...
                'Alignment calibration validity interval is empty.');
            allowed = {'fixedCalibration','considerParameter','estimatedState'};
            assert(any(strcmp(obj.alignmentCalibration.treatment, allowed)), ...
                'StarTrackerMeasurementModel:invalidAlignmentTreatment', ...
                'Alignment treatment must be fixedCalibration, considerParameter, or estimatedState.');
            if strcmp(obj.alignmentCalibration.treatment, 'fixedCalibration')
                assert(norm(obj.alignmentCalibration.covariance_rad2, 'fro') == 0 && ...
                    norm(obj.alignmentCalibration.driftProcessNoise_rad2ps, 'fro') == 0, ...
                    'StarTrackerMeasurementModel:uncertainFixedCalibration', ...
                    'A fixed calibration cannot silently carry nonzero uncertainty or drift.');
            end
            assert(isscalar(obj.alignmentDriftRandomWalk_rad_per_sqrt_s) && ...
                isfinite(obj.alignmentDriftRandomWalk_rad_per_sqrt_s) && ...
                obj.alignmentDriftRandomWalk_rad_per_sqrt_s >= 0, ...
                'StarTrackerMeasurementModel:invalidTruthDrift', ...
                'Truth alignment random walk must be finite and nonnegative.');
        end

        function advanceAlignment_(obj, time_s)
            assert(isscalar(time_s) && isfinite(time_s), ...
                'StarTrackerMeasurementModel:invalidEpoch', ...
                'Star-tracker epoch must be finite.');
            if isnan(obj.lastTime_s)
                obj.lastTime_s = time_s;
                return
            end
            dt_s = time_s - obj.lastTime_s;
            assert(dt_s >= 0, 'StarTrackerMeasurementModel:nonMonotonicTime', ...
                'Star-tracker samples must be generated in nondecreasing time order.');
            if dt_s > 0
                driftIncrement = obj.alignmentDriftRate_radps*dt_s + ...
                    obj.alignmentDriftRandomWalk_rad_per_sqrt_s*sqrt(dt_s)* ...
                    randn(obj.noiseStream, 3, 1);
                obj.alignmentErrorQuaternion = ...
                    revgnss.AttitudeQuaternion.multiply( ...
                    obj.alignmentErrorQuaternion, ...
                    revgnss.AttitudeQuaternion.fromRotationVector(driftIncrement));
            end
            obj.lastTime_s = time_s;
        end

        function observation = invalidObservation_(obj, time_s, status)
            observation = models.sensors.StarTrackerObservation( ...
                obj.sensorIdentifier, time_s, nan(4,1), ...
                obj.whiteAngularCovariance_rad2, false, status, ...
                obj.alignmentCalibration);
        end

        function sample = gaussianDraw_(obj, covariance)
            covariance = (covariance + covariance.')/2;
            [V,D] = eig(covariance);
            eigenvalues = max(0, diag(D));
            sample = V*diag(sqrt(eigenvalues))*randn(obj.noiseStream, 3, 1);
        end
    end
end

function value = i_field(s, name, defaultValue)
    value = defaultValue;
    if isstruct(s) && isfield(s, name) && ~isempty(s.(name))
        value = s.(name);
    end
end

function value = i_vector(s, name, defaultValue)
    value = i_field(s, name, defaultValue);
    value = value(:);
    assert(numel(value) == 3 && all(isfinite(value)), ...
        'StarTrackerMeasurementModel:invalidVector', ...
        '%s must contain three finite components.', name);
end

function i_validateCovariance(P, label)
    assert(isequal(size(P), [3,3]) && all(isfinite(P(:))), ...
        'StarTrackerMeasurementModel:invalidCovariance', ...
        '%s must be a finite 3-by-3 matrix.', label);
    Ps = (P+P.')/2;
    tolerance = 1e-12*max(1e-30, norm(Ps,2));
    assert(norm(P-P.','fro') <= tolerance && min(eig(Ps)) >= -tolerance, ...
        'StarTrackerMeasurementModel:invalidCovariance', ...
        '%s must be symmetric positive semidefinite.', label);
end
