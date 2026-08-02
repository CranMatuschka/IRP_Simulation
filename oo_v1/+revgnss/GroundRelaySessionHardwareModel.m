classdef GroundRelaySessionHardwareModel
    % GroundRelaySessionHardwareModel  Plan Section 4.5 hardware/delay-chain value class for the
    % classical relay TWSTFT session processor. Sibling to (NOT derived from, NOT touching)
    % revgnss.ReciprocalLinkHardwareModel: that class's own solveEventChain_ reads only
    % turnaroundProperTime_s (+revgnss/ReciprocalTimestampEventModel.m:114-115) -- it never reads
    % originTerminalGroupDelay_s/anchorTerminalGroupDelay_s -- so a relay session's genuinely
    % DIFFERENT delay-source set (2 station modems, each with its own TX/RX delay, plus the
    % relay's own group delay) cannot be expressed through that class's 2-term shape.
    %
    % A single combined (TX==RX) delay per station is PROVABLY INERT to the reported session
    % clock difference (derived algebraically during design: only each station's own
    % TX-minus-RX asymmetry survives the two-pass combination in
    % revgnss.GroundRelaySessionObservableBuilder.combine -- classical TWSTFT's own celebrated
    % cancellation of symmetric equipment delay). stationATransmitDelay_s/stationAReceiveDelay_s
    % (and the B pair) are therefore tracked SEPARATELY, not as one number, so the corresponding
    % config leaves and truth-injection tests are genuinely non-vacuous.
    %
    % relayGroupDelayNominal_s reuses the EXISTING, already-tested
    % revgnss.ReciprocalLinkHardwareModel.turnaroundProperTime_s mechanism verbatim via
    % asEventSolverHardware -- for revgnss.ReciprocalTimestampEventModel.solveRelayTransit, the
    % "turnaround" role is literally the relay endpoint, so no new solver concept is needed.
    % relayGroupDelayAsymmetry_s is an optional forward/return split for testing non-reciprocal
    % relay hardware (default 0 = perfectly reciprocal relay).
    %
    % Deliberately carries NO calibrationCovariance_s2 field: all declared session-common
    % uncertainty (relay group delay, both stations' terminal delay, shared atmosphere) lives
    % exactly once, in revgnss.GroundRelaySessionCommonCovarianceGroup, never duplicated here.
    %
    % relayFrequencyTranslationRatio/relayOscillatorStateIdentifier are declarative-only (plan
    % item 3's "any frequency translation/relay oscillator state"): revgnss.
    % ReciprocalTimestampEventModel is coordinate-time-only and frequency-agnostic, so a
    % translation ratio other than 1.0 has no physics to apply it to -- refused, not silently
    % accepted, by revgnss.GroundRelayPhysicalLinkConfig.requireCompleteSessionConfig.

    properties (SetAccess = immutable)
        parameterSource (1,:) char
        physicalChainIdentifier (1,:) char
        calibrationProductIdentifier (1,:) char
        stationATransmitDelay_s (1,1) double
        stationAReceiveDelay_s (1,1) double
        stationBTransmitDelay_s (1,1) double
        stationBReceiveDelay_s (1,1) double
        relayGroupDelayNominal_s (1,1) double
        relayGroupDelayAsymmetry_s (1,1) double
        relayFrequencyTranslationRatio (1,1) double
        relayOscillatorStateIdentifier (1,:) char
        validFromLocalTag_s (1,1) double
        validUntilLocalTag_s (1,1) double
    end

    methods
        function obj = GroundRelaySessionHardwareModel(args)
            arguments
                args.parameterSource (1,:) char = ''
                args.physicalChainIdentifier (1,:) char = ''
                args.calibrationProductIdentifier (1,:) char = ''
                args.stationATransmitDelay_s (1,1) double = 0
                args.stationAReceiveDelay_s (1,1) double = 0
                args.stationBTransmitDelay_s (1,1) double = 0
                args.stationBReceiveDelay_s (1,1) double = 0
                args.relayGroupDelayNominal_s (1,1) double = NaN
                args.relayGroupDelayAsymmetry_s (1,1) double = 0
                args.relayFrequencyTranslationRatio (1,1) double = 1.0
                args.relayOscillatorStateIdentifier (1,:) char = ''
                args.validFromLocalTag_s (1,1) double = -Inf
                args.validUntilLocalTag_s (1,1) double = Inf
            end

            if isempty(args.parameterSource)
                error('GroundRelaySessionHardwareModel:parameterSourceRequired', ...
                    'parameterSource is required and was not supplied.');
            end
            if ~ismember(args.parameterSource, {'physicalTruth','calibrationProduct'})
                error('GroundRelaySessionHardwareModel:parameterSource', ...
                    'parameterSource must be physicalTruth or calibrationProduct.');
            end
            if isempty(args.physicalChainIdentifier)
                error('GroundRelaySessionHardwareModel:physicalChainIdentifierRequired', ...
                    'physicalChainIdentifier is required and was not supplied.');
            end
            if isnan(args.relayGroupDelayNominal_s)
                error('GroundRelaySessionHardwareModel:relayGroupDelayRequired', ...
                    'relayGroupDelayNominal_s is required and was not supplied.');
            end
            delayFields = {'stationATransmitDelay_s','stationAReceiveDelay_s', ...
                'stationBTransmitDelay_s','stationBReceiveDelay_s'};
            for k = 1:numel(delayFields)
                v = args.(delayFields{k});
                if ~(isfinite(v) && v >= 0)
                    error('GroundRelaySessionHardwareModel:stationDelay', ...
                        '%s must be finite and nonnegative.',delayFields{k});
                end
            end
            if ~(isfinite(args.relayGroupDelayNominal_s) && args.relayGroupDelayNominal_s >= 0)
                error('GroundRelaySessionHardwareModel:relayGroupDelay', ...
                    'relayGroupDelayNominal_s must be finite and nonnegative.');
            end
            if ~isfinite(args.relayGroupDelayAsymmetry_s)
                error('GroundRelaySessionHardwareModel:relayGroupDelayAsymmetry', ...
                    'relayGroupDelayAsymmetry_s must be finite.');
            end
            if args.relayGroupDelayNominal_s - abs(args.relayGroupDelayAsymmetry_s)/2 < 0
                error('GroundRelaySessionHardwareModel:relayGroupDelayAsymmetry', ...
                    'relayGroupDelayAsymmetry_s must not drive either directional relay delay negative.');
            end
            if ~(isfinite(args.relayFrequencyTranslationRatio) && args.relayFrequencyTranslationRatio > 0)
                error('GroundRelaySessionHardwareModel:relayFrequencyTranslationRatio', ...
                    'relayFrequencyTranslationRatio must be finite and positive.');
            end
            if args.validUntilLocalTag_s < args.validFromLocalTag_s
                error('GroundRelaySessionHardwareModel:validity', ...
                    'Calibration validity interval is reversed.');
            end

            obj.parameterSource = args.parameterSource;
            obj.physicalChainIdentifier = args.physicalChainIdentifier;
            obj.calibrationProductIdentifier = args.calibrationProductIdentifier;
            obj.stationATransmitDelay_s = args.stationATransmitDelay_s;
            obj.stationAReceiveDelay_s = args.stationAReceiveDelay_s;
            obj.stationBTransmitDelay_s = args.stationBTransmitDelay_s;
            obj.stationBReceiveDelay_s = args.stationBReceiveDelay_s;
            obj.relayGroupDelayNominal_s = args.relayGroupDelayNominal_s;
            obj.relayGroupDelayAsymmetry_s = args.relayGroupDelayAsymmetry_s;
            obj.relayFrequencyTranslationRatio = args.relayFrequencyTranslationRatio;
            obj.relayOscillatorStateIdentifier = args.relayOscillatorStateIdentifier;
            obj.validFromLocalTag_s = args.validFromLocalTag_s;
            obj.validUntilLocalTag_s = args.validUntilLocalTag_s;
        end

        function assertParameterSource(obj, expectedSource)
            if ~strcmp(obj.parameterSource, expectedSource)
                error('GroundRelaySessionHardwareModel:sourceSeparation', ...
                    'Expected hardware source %s, received %s.', ...
                    expectedSource, obj.parameterSource);
            end
        end

        function assertValidAt(obj, localClockTag_s)
            if ~(isnumeric(localClockTag_s) && isscalar(localClockTag_s) && isfinite(localClockTag_s))
                error('GroundRelaySessionHardwareModel:outsideValidity', ...
                    'The observation tag must be a finite scalar to check calibration validity.');
            end
            if localClockTag_s < obj.validFromLocalTag_s || ...
                    localClockTag_s > obj.validUntilLocalTag_s
                error('GroundRelaySessionHardwareModel:outsideValidity', ...
                    'The calibration product is not valid at the observation tag.');
            end
        end

        function hw = asEventSolverHardware(obj, direction)
            % asEventSolverHardware  Returns an EPHEMERAL, unmodified revgnss.
            % ReciprocalLinkHardwareModel for revgnss.ReciprocalTimestampEventModel.solveRelayTransit
            % -- turnaroundProperTime_s = relayGroupDelayNominal_s +- relayGroupDelayAsymmetry_s/2
            % (sign +1 forward, -1 return). originTerminalGroupDelay_s/anchorTerminalGroupDelay_s
            % are deliberately zeroed here (never repurposed): station terminal-delay correction
            % happens separately, in revgnss.GroundRelaySessionObservableBuilder.combine, applied
            % only to the raw local tags -- this method's job is only to feed the SOLVER's own
            % relay-repeater-delay term, matching the ISL/ground-space precedents' own
            % "hardware->solver" boundary.
            if ~ismember(direction, {'forward','return'})
                error('GroundRelaySessionHardwareModel:direction', ...
                    'direction must be ''forward'' or ''return''.');
            end
            sign = 1;
            if strcmp(direction,'return'); sign = -1; end
            turnaround_s = obj.relayGroupDelayNominal_s + sign*obj.relayGroupDelayAsymmetry_s/2;
            hw = revgnss.ReciprocalLinkHardwareModel( ...
                'parameterSource',obj.parameterSource, ...
                'physicalChainIdentifier',obj.physicalChainIdentifier, ...
                'calibrationProductIdentifier',obj.calibrationProductIdentifier, ...
                'turnaroundProperTime_s',turnaround_s, ...
                'originTerminalGroupDelay_s',0, ...
                'anchorTerminalGroupDelay_s',0, ...
                'validFromLocalTag_s',obj.validFromLocalTag_s, ...
                'validUntilLocalTag_s',obj.validUntilLocalTag_s);
        end
    end
end
