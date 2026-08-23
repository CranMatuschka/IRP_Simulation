classdef CoherentTwoWayCodeDiagnostic
    % CoherentTwoWayCodeDiagnostic  Truth-only four-event validation record.

    properties (SetAccess = immutable)
        diagnosticIdentifier (1,:) char
        t1TransmitCoordinateTime_s (1,1) double
        t2TransponderReceiveCoordinateTime_s (1,1) double
        t3TransponderTransmitCoordinateTime_s (1,1) double
        t4FinalReceptionCoordinateTime_s (1,1) double
        initiatorTransmitPhaseCentreAtT1_m (3,1) double
        transponderReceivePhaseCentreAtT2_m (3,1) double
        transponderTransmitPhaseCentreAtT3_m (3,1) double
        initiatorReceivePhaseCentreAtT4_m (3,1) double
        forwardGeometricRange_m (1,1) double
        returnGeometricRange_m (1,1) double
        forwardLightTimeResidual_s (1,1) double
        returnLightTimeResidual_s (1,1) double
        forwardIterationCount (1,1) double
        returnIterationCount (1,1) double
        physicalTurnaroundProperTime_s (1,1) double
        turnaroundDelayDefinition (1,:) char
        trueInitiatorTerminalGroupDelay_s (1,1) double
        initiatorTerminalDelayDefinition (1,:) char
        trackingError_s (1,1) double
        propagationGroupDelay_s (1,1) double
        trackedIncomingCodePhase_chips (1,1) double
        transmittedReturnCodePhase_chips (1,1) double
        codeRateTurnaroundRatio (1,1) double
        carrierFrequencyTurnaroundRatio (1,1) double
        errorDecomposition_s (1,1) struct
        referenceEpochRule (1,:) char
    end

    methods
        function obj = CoherentTwoWayCodeDiagnostic(values)
            arguments
                values (1,1) struct
            end
            names = properties(obj);
            supplied = fieldnames(values);
            missing = setdiff(names, supplied);
            unknown = setdiff(supplied, names);
            if ~isempty(missing)
                error('CoherentTwoWayCodeDiagnostic:missingField', ...
                    'Truth diagnostic is missing field %s.', missing{1});
            end
            if ~isempty(unknown)
                error('CoherentTwoWayCodeDiagnostic:unknownField', ...
                    'Truth diagnostic contains unsupported field %s.', unknown{1});
            end
            for k = 1:numel(names)
                obj.(names{k}) = values.(names{k});
            end
        end

        function values = toStruct(obj)
            names = properties(obj);
            values = struct();
            for fieldIdx = 1:numel(names)
                values.(names{fieldIdx}) = obj.(names{fieldIdx});
            end
        end
    end
end
