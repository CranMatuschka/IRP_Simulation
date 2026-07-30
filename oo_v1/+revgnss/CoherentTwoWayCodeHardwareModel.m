classdef CoherentTwoWayCodeHardwareModel
    % CoherentTwoWayCodeHardwareModel  Physical chain or calibration product.

    properties (SetAccess = immutable)
        parameterSource (1,:) char
        physicalChainIdentifier (1,:) char
        calibrationProductIdentifier (1,:) char
        turnaroundProperTime_s (1,1) double
        initiatorTerminalGroupDelay_s (1,1) double
        turnaroundDelayDefinition (1,:) char
        initiatorTerminalDelayDefinition (1,:) char
        carrierFrequencyTurnaroundRatio (1,1) double
        codeRateTurnaroundRatio (1,1) double
        codeChipRate_Hz (1,1) double
        codeLength_chips (1,1) double
        codePhaseCalibration_chips (1,1) double
        calibrationCovariance_s2 (:,:) double
        validFromLocalTag_s (1,1) double
        validUntilLocalTag_s (1,1) double
    end

    methods
        function obj = CoherentTwoWayCodeHardwareModel(args)
            arguments
                args.parameterSource (1,:) char
                args.physicalChainIdentifier (1,:) char
                args.calibrationProductIdentifier (1,:) char
                args.turnaroundProperTime_s (1,1) double
                args.initiatorTerminalGroupDelay_s (1,1) double = 0
                args.turnaroundDelayDefinition (1,:) char = ...
                    'transponderReceiveCodeEpochToTransmitCodeEpochProperTime'
                args.initiatorTerminalDelayDefinition (1,:) char = ...
                    'sumOfInitiatorTransmitAndReceiveGroupDelays'
                args.carrierFrequencyTurnaroundRatio (1,1) double = 1
                args.codeRateTurnaroundRatio (1,1) double = 1
                args.codeChipRate_Hz (1,1) double = 1.023e6
                args.codeLength_chips (1,1) double = 1023
                args.codePhaseCalibration_chips (1,1) double = 0
                args.calibrationCovariance_s2 (:,:) double = zeros(2)
                args.validFromLocalTag_s (1,1) double = -Inf
                args.validUntilLocalTag_s (1,1) double = Inf
            end

            if ~ismember(args.parameterSource, {'physicalTruth','calibrationProduct'})
                error('CoherentTwoWayCodeHardwareModel:parameterSource', ...
                    'parameterSource must be physicalTruth or calibrationProduct.');
            end
            if ~(isfinite(args.turnaroundProperTime_s) && args.turnaroundProperTime_s >= 0)
                error('CoherentTwoWayCodeHardwareModel:turnaroundDelay', ...
                    'turnaroundProperTime_s must be finite and nonnegative.');
            end
            if ~(isfinite(args.initiatorTerminalGroupDelay_s) && ...
                    args.initiatorTerminalGroupDelay_s >= 0)
                error('CoherentTwoWayCodeHardwareModel:terminalDelay', ...
                    'initiatorTerminalGroupDelay_s must be finite and nonnegative.');
            end
            if ~strcmp(args.turnaroundDelayDefinition, ...
                    'transponderReceiveCodeEpochToTransmitCodeEpochProperTime') || ...
                    ~strcmp(args.initiatorTerminalDelayDefinition, ...
                    'sumOfInitiatorTransmitAndReceiveGroupDelays')
                error('CoherentTwoWayCodeHardwareModel:delayDefinition', ...
                    'The active observable requires the declared aggregate delay definitions.');
            end
            if args.codeRateTurnaroundRatio ~= 1
                error('CoherentTwoWayCodeHardwareModel:codeRateRatio', ...
                    'The coherent tracked-code protocol requires codeRateTurnaroundRatio = 1.');
            end
            if ~(isfinite(args.carrierFrequencyTurnaroundRatio) && ...
                    args.carrierFrequencyTurnaroundRatio > 0)
                error('CoherentTwoWayCodeHardwareModel:carrierRatio', ...
                    'carrierFrequencyTurnaroundRatio must be finite and positive.');
            end
            if ~(isfinite(args.codeChipRate_Hz) && args.codeChipRate_Hz > 0)
                error('CoherentTwoWayCodeHardwareModel:chipRate', ...
                    'codeChipRate_Hz must be finite and positive.');
            end
            if ~(isfinite(args.codeLength_chips) && args.codeLength_chips >= 1 && ...
                    args.codeLength_chips == round(args.codeLength_chips))
                error('CoherentTwoWayCodeHardwareModel:codeLength', ...
                    'codeLength_chips must be a positive integer.');
            end
            covariance = args.calibrationCovariance_s2;
            if ~isequal(size(covariance), [2 2]) || any(~isfinite(covariance), 'all') || ...
                    norm(covariance - covariance', 'fro') > 1e-15 || ...
                    min(eig((covariance + covariance') / 2)) < -1e-18
                error('CoherentTwoWayCodeHardwareModel:covariance', ...
                    'Calibration covariance must be a finite, symmetric, positive-semidefinite 2-by-2 matrix.');
            end
            if args.validUntilLocalTag_s < args.validFromLocalTag_s
                error('CoherentTwoWayCodeHardwareModel:validity', ...
                    'Calibration validity interval is reversed.');
            end

            obj.parameterSource = args.parameterSource;
            obj.physicalChainIdentifier = args.physicalChainIdentifier;
            obj.calibrationProductIdentifier = args.calibrationProductIdentifier;
            obj.turnaroundProperTime_s = args.turnaroundProperTime_s;
            obj.initiatorTerminalGroupDelay_s = args.initiatorTerminalGroupDelay_s;
            obj.turnaroundDelayDefinition = args.turnaroundDelayDefinition;
            obj.initiatorTerminalDelayDefinition = ...
                args.initiatorTerminalDelayDefinition;
            obj.carrierFrequencyTurnaroundRatio = args.carrierFrequencyTurnaroundRatio;
            obj.codeRateTurnaroundRatio = args.codeRateTurnaroundRatio;
            obj.codeChipRate_Hz = args.codeChipRate_Hz;
            obj.codeLength_chips = args.codeLength_chips;
            obj.codePhaseCalibration_chips = args.codePhaseCalibration_chips;
            obj.calibrationCovariance_s2 = covariance;
            obj.validFromLocalTag_s = args.validFromLocalTag_s;
            obj.validUntilLocalTag_s = args.validUntilLocalTag_s;
        end

        function assertParameterSource(obj, expectedSource)
            if ~strcmp(obj.parameterSource, expectedSource)
                error('CoherentTwoWayCodeHardwareModel:sourceSeparation', ...
                    'Expected hardware source %s, received %s.', ...
                    expectedSource, obj.parameterSource);
            end
        end

        function assertValidAt(obj, localClockTag_s)
            if localClockTag_s < obj.validFromLocalTag_s || ...
                    localClockTag_s > obj.validUntilLocalTag_s
                error('CoherentTwoWayCodeHardwareModel:outsideValidity', ...
                    'The calibration product is not valid at the observation tag.');
            end
        end

        function returnedPhase_chips = returnedCodePhase(obj, trackedIncomingPhase_chips)
            returnedPhase_chips = mod(trackedIncomingPhase_chips + ...
                obj.codePhaseCalibration_chips, obj.codeLength_chips);
        end
    end
end
