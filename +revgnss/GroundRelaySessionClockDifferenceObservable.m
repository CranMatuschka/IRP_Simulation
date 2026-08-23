classdef GroundRelaySessionClockDifferenceObservable
    % GroundRelaySessionClockDifferenceObservable  Plan Section 4.5: the processed session-level
    % clock-difference observable built FROM two revgnss.ReciprocalTimestampExchangeRecord
    % (topologyKind='relayTransit') by revgnss.GroundRelaySessionObservableBuilder.combine --
    % constructed only there, never a bare constructor call from arbitrary caller data (same
    % discipline as revgnss.FourTimestampClockDifferenceObservable/
    % revgnss.DistributedLinkUpdateBlock).
    %
    % topologyKind is its own frozen literal 'groundRelaySession' -- never collides with
    % revgnss.ReciprocalTimestampExchangeRecord.AllowedTopologyKinds ('directRoundTrip'/
    % 'relayTransit', the RAW per-pass records this observable is built FROM) or
    % revgnss.FourTimestampClockDifferenceObservable.AllowedTopologyKinds ('directRoundTrip'
    % only, a wholly separate 2-endpoint pipeline this class shares no code with).
    %
    % clockClaim is a HARDCODED string literal 'relativeBiasOnly', not a
    % revgnss.DistributedClockGaugeContract registry lookup: that contract's gating methods
    % require revgnss.CommunicationEndpointState/revgnss.DistributedLinkUpdateBlock
    % infrastructure this truth-side, non-LinkObservationDelivery-routed session processor does
    % not have (confirmed by direct read during design -- not reachable this stage, by design,
    % not oversight). The classification is instead justified by 3 real, structural,
    % mathematically-proven properties, each independently tested by
    % tests/test_relay_twstft_clock_gauge.m: (1) common-mode blindness -- shifting both station
    % clock biases by the same constant leaves clockDifferenceValue_s unchanged; (2) differential
    % sensitivity -- shifting only the remote (station B) bias by delta changes the output by
    % exactly +delta; (3) the relay is marginalized out STRUCTURALLY -- its own clock bias/group
    % delay never enters the combiner formula at all (the relay's own t2/t3 local tags are
    % computed for chain-shape compliance but discarded, not merely small).
    %
    % TWO reported clock-difference values, a distinction added by combined review B1 (an
    % un-reviewed first cut reported only the truth-assisted value and mislabeled it "exact"):
    %   clockDifferenceValue_s   -- a TRUTH-GEOMETRY-ASSISTED reference value: subtracts the
    %                               truth-solved coordinate-time transit tauF/tauR from each raw
    %                               local-tag difference before combining. This is an EXACT
    %                               closed-form recovery of the station clock difference (see
    %                               below for the precision of that claim), but it requires
    %                               tauF/tauR -- ground truth no real station-pair receiver has
    %                               access to. It is a validation/diagnostic reference, not what a
    %                               real relay-TWSTFT session reports.
    %   classicalReciprocityValue_s -- the REALIZABLE classical relay-TWSTFT combination
    %                               0.5*(DeltaF-DeltaR): built from the two stations' own
    %                               exchanged local tags alone (already corrected for station
    %                               modem delay and atmosphere -- see
    %                               revgnss.GroundRelaySessionObservableBuilder.combine), with NO
    %                               geometry/coordinate-time knowledge. This is what a real
    %                               station pair actually reports; it carries the true relay
    %                               non-reciprocity and relay-group-delay-asymmetry residuals that
    %                               clockDifferenceValue_s's tau-subtraction removes by
    %                               construction. The two differ by exactly
    %                               classicalReciprocityValue_s - clockDifferenceValue_s ==
    %                               0.5*coordinateAsymmetry_s.
    % cfg.measurements.groundRelayTimeTransfer.hardware.relayGroupDelayAsymmetry_s moves
    % classicalReciprocityValue_s (by +asymmetry/2), NOT clockDifferenceValue_s (structurally
    % inert there -- see tests/test_relay_twstft_clock_gauge.m's "relay marginalized out"
    % coverage) -- do not read a nonzero effect on clockDifferenceValue_s as a bug.
    %
    % EXACTNESS of clockDifferenceValue_s, precisely stated (combined review M2): the affine-clock
    % identity used to derive it gives clockDifferenceValue_s == delta_B(stationBEffectiveEpoch_s)
    % - delta_A(stationAEffectiveEpoch_s) EXACTLY, where delta_X(t) := X.localTimeAt(t)-t and
    % stationAEffectiveEpoch_s/stationBEffectiveEpoch_s are the two (generally DIFFERENT) midpoint
    % coordinate epochs exposed below. This equals a single, epoch-independent bias_B - bias_A
    % ONLY when both stations are driftless (localClockRate==1) OR when
    % stationAEffectiveEpoch_s==stationBEffectiveEpoch_s (equivalently coordinateAsymmetry_s==0) --
    % under nonzero clock drift and a moving relay the two effective epochs genuinely differ.

    properties (Constant)
        TopologyKind = 'groundRelaySession';
        ClockClaim = 'relativeBiasOnly';
        SignConvention = 'remoteMinusOwner';
        SpeedOfLight_mps = 299792458;
    end

    properties (SetAccess = immutable)
        sessionIdentifier (1,:) char
        sourceForwardExchangeIdentifier (1,:) char
        sourceReturnExchangeIdentifier (1,:) char
        stationAIdentifier (1,:) char
        stationBIdentifier (1,:) char
        relayIdentifier (1,:) char
        forwardReceptionEpoch_s (1,1) double
        returnReceptionEpoch_s (1,1) double
        stationAEffectiveEpoch_s (1,1) double
        stationBEffectiveEpoch_s (1,1) double

        clockDifferenceValue_s (1,1) double
        clockDifferenceValue_m (1,1) double
        classicalReciprocityValue_s (1,1) double
        classicalReciprocityValue_m (1,1) double
        rawCombination_s (1,1) double
        coordinateAsymmetry_s (1,1) double

        stationTerminalDelayCorrectionForward_s (1,1) double
        stationTerminalDelayCorrectionReturn_s (1,1) double
        atmosphereDelayForward_s (1,1) double
        atmosphereDelayReturn_s (1,1) double

        sessionCommonCovariance_s2 (:,:) double
        sessionCommonComponentOrder (1,:) cell
        sessionCommonTemporalModels (1,:) cell
        independentVariance_s2 (1,1) double

        availability (1,1) logical
        truthDiagnosticIdentifier (1,:) char
    end

    methods
        function obj = GroundRelaySessionClockDifferenceObservable(record)
            required = {'sessionIdentifier','sourceForwardExchangeIdentifier', ...
                'sourceReturnExchangeIdentifier','stationAIdentifier','stationBIdentifier', ...
                'relayIdentifier','forwardReceptionEpoch_s','returnReceptionEpoch_s', ...
                'stationAEffectiveEpoch_s','stationBEffectiveEpoch_s', ...
                'clockDifferenceValue_s','clockDifferenceValue_m', ...
                'classicalReciprocityValue_s','classicalReciprocityValue_m','rawCombination_s', ...
                'coordinateAsymmetry_s','stationTerminalDelayCorrectionForward_s', ...
                'stationTerminalDelayCorrectionReturn_s','atmosphereDelayForward_s', ...
                'atmosphereDelayReturn_s','sessionCommonCovariance_s2', ...
                'sessionCommonComponentOrder','sessionCommonTemporalModels','independentVariance_s2', ...
                'availability','truthDiagnosticIdentifier'};
            supplied = fieldnames(record);
            missing = setdiff(required,supplied);
            unknown = setdiff(supplied,required);
            if ~isempty(missing)
                error('GroundRelaySessionClockDifferenceObservable:missingField', ...
                    'GroundRelaySessionClockDifferenceObservable is missing %s.',missing{1});
            end
            if ~isempty(unknown)
                error('GroundRelaySessionClockDifferenceObservable:unknownField', ...
                    'GroundRelaySessionClockDifferenceObservable contains unsupported field %s.',unknown{1});
            end

            textFields = {'sessionIdentifier','sourceForwardExchangeIdentifier', ...
                'sourceReturnExchangeIdentifier','stationAIdentifier','stationBIdentifier', ...
                'relayIdentifier'};
            for k = 1:numel(textFields)
                if isempty(strtrim(char(record.(textFields{k}))))
                    error('GroundRelaySessionClockDifferenceObservable:identifiers', ...
                        '%s must be nonempty text.',textFields{k});
                end
            end
            ids = {char(record.stationAIdentifier),char(record.stationBIdentifier), ...
                char(record.relayIdentifier)};
            if numel(unique(ids)) ~= 3
                error('GroundRelaySessionClockDifferenceObservable:distinctEndpoints', ...
                    'stationAIdentifier/stationBIdentifier/relayIdentifier must be three distinct identifiers.');
            end
            if strcmp(char(record.sourceForwardExchangeIdentifier), ...
                    char(record.sourceReturnExchangeIdentifier))
                error('GroundRelaySessionClockDifferenceObservable:distinctExchanges', ...
                    'sourceForwardExchangeIdentifier and sourceReturnExchangeIdentifier must be distinct.');
            end

            numericFields = {'forwardReceptionEpoch_s','returnReceptionEpoch_s', ...
                'stationAEffectiveEpoch_s','stationBEffectiveEpoch_s', ...
                'clockDifferenceValue_s','clockDifferenceValue_m', ...
                'classicalReciprocityValue_s','classicalReciprocityValue_m','rawCombination_s', ...
                'coordinateAsymmetry_s','stationTerminalDelayCorrectionForward_s', ...
                'stationTerminalDelayCorrectionReturn_s','atmosphereDelayForward_s', ...
                'atmosphereDelayReturn_s'};
            for k = 1:numel(numericFields)
                v = record.(numericFields{k});
                if ~(isnumeric(v) && isscalar(v) && isfinite(v))
                    error('GroundRelaySessionClockDifferenceObservable:numericField', ...
                        '%s must be a finite scalar.',numericFields{k});
                end
            end
            if ~(isnumeric(record.independentVariance_s2) && isscalar(record.independentVariance_s2) && ...
                    isfinite(record.independentVariance_s2) && record.independentVariance_s2 >= 0)
                error('GroundRelaySessionClockDifferenceObservable:independentVariance', ...
                    'independentVariance_s2 must be a finite, nonnegative scalar.');
            end
            if record.forwardReceptionEpoch_s == record.returnReceptionEpoch_s
                error('GroundRelaySessionClockDifferenceObservable:distinctEpochs', ...
                    'forwardReceptionEpoch_s and returnReceptionEpoch_s must be distinct.');
            end
            c = revgnss.GroundRelaySessionClockDifferenceObservable.SpeedOfLight_mps;
            if abs(record.clockDifferenceValue_m - c*record.clockDifferenceValue_s) > ...
                    1e-6*max(1,abs(record.clockDifferenceValue_m))
                error('GroundRelaySessionClockDifferenceObservable:unitsMismatch', ...
                    'clockDifferenceValue_m must equal SpeedOfLight_mps * clockDifferenceValue_s.');
            end
            if abs(record.classicalReciprocityValue_m - c*record.classicalReciprocityValue_s) > ...
                    1e-6*max(1,abs(record.classicalReciprocityValue_m))
                error('GroundRelaySessionClockDifferenceObservable:unitsMismatch', ...
                    'classicalReciprocityValue_m must equal SpeedOfLight_mps * classicalReciprocityValue_s.');
            end

            covariance = record.sessionCommonCovariance_s2;
            if ~isnumeric(covariance) || size(covariance,1) ~= size(covariance,2) || ...
                    (~isempty(covariance) && (any(~isfinite(covariance),'all') || ...
                    norm(covariance-covariance','fro') > 1e-12*max(1,norm(covariance,'fro')) || ...
                    min(eig((covariance+covariance')/2)) < -1e-12*max(1,norm(covariance,'fro'))))
                error('GroundRelaySessionClockDifferenceObservable:sessionCommonCovariance', ...
                    'sessionCommonCovariance_s2 must be finite, symmetric, and positive semidefinite.');
            end
            componentOrder = record.sessionCommonComponentOrder;
            if ~iscell(componentOrder) || numel(componentOrder) ~= size(covariance,1)
                error('GroundRelaySessionClockDifferenceObservable:sessionCommonComponentOrder', ...
                    'sessionCommonComponentOrder must have one entry per sessionCommonCovariance_s2 row.');
            end
            temporalModels = record.sessionCommonTemporalModels;
            if ~iscell(temporalModels) || numel(temporalModels) ~= numel(componentOrder)
                error('GroundRelaySessionClockDifferenceObservable:sessionCommonTemporalModels', ...
                    'sessionCommonTemporalModels must have one entry per sessionCommonComponentOrder label.');
            end
            if ~(islogical(record.availability) && isscalar(record.availability))
                error('GroundRelaySessionClockDifferenceObservable:availability', ...
                    'availability must be a logical scalar.');
            end
            if ~(ischar(record.truthDiagnosticIdentifier) || isstring(record.truthDiagnosticIdentifier))
                error('GroundRelaySessionClockDifferenceObservable:truthDiagnosticIdentifier', ...
                    'truthDiagnosticIdentifier must be text (may be empty).');
            end

            obj.sessionIdentifier = char(record.sessionIdentifier);
            obj.sourceForwardExchangeIdentifier = char(record.sourceForwardExchangeIdentifier);
            obj.sourceReturnExchangeIdentifier = char(record.sourceReturnExchangeIdentifier);
            obj.stationAIdentifier = char(record.stationAIdentifier);
            obj.stationBIdentifier = char(record.stationBIdentifier);
            obj.relayIdentifier = char(record.relayIdentifier);
            obj.forwardReceptionEpoch_s = double(record.forwardReceptionEpoch_s);
            obj.returnReceptionEpoch_s = double(record.returnReceptionEpoch_s);
            obj.stationAEffectiveEpoch_s = double(record.stationAEffectiveEpoch_s);
            obj.stationBEffectiveEpoch_s = double(record.stationBEffectiveEpoch_s);
            obj.clockDifferenceValue_s = double(record.clockDifferenceValue_s);
            obj.clockDifferenceValue_m = double(record.clockDifferenceValue_m);
            obj.classicalReciprocityValue_s = double(record.classicalReciprocityValue_s);
            obj.classicalReciprocityValue_m = double(record.classicalReciprocityValue_m);
            obj.rawCombination_s = double(record.rawCombination_s);
            obj.coordinateAsymmetry_s = double(record.coordinateAsymmetry_s);
            obj.stationTerminalDelayCorrectionForward_s = double(record.stationTerminalDelayCorrectionForward_s);
            obj.stationTerminalDelayCorrectionReturn_s = double(record.stationTerminalDelayCorrectionReturn_s);
            obj.atmosphereDelayForward_s = double(record.atmosphereDelayForward_s);
            obj.atmosphereDelayReturn_s = double(record.atmosphereDelayReturn_s);
            obj.sessionCommonCovariance_s2 = (covariance+covariance')/2;
            obj.sessionCommonComponentOrder = cellfun(@char,componentOrder,'UniformOutput',false);
            obj.sessionCommonTemporalModels = cellfun(@char,temporalModels,'UniformOutput',false);
            obj.independentVariance_s2 = double(record.independentVariance_s2);
            obj.availability = logical(record.availability);
            obj.truthDiagnosticIdentifier = char(record.truthDiagnosticIdentifier);
        end

        function output = toStruct(obj)
            % Hand-lists SetAccess=immutable field names rather than properties(obj): this class
            % has a properties(Constant) block, and properties(obj) would silently include those
            % too (the established, repeatedly-hit footgun in this project).
            names = {'sessionIdentifier','sourceForwardExchangeIdentifier', ...
                'sourceReturnExchangeIdentifier','stationAIdentifier','stationBIdentifier', ...
                'relayIdentifier','forwardReceptionEpoch_s','returnReceptionEpoch_s', ...
                'stationAEffectiveEpoch_s','stationBEffectiveEpoch_s', ...
                'clockDifferenceValue_s','clockDifferenceValue_m', ...
                'classicalReciprocityValue_s','classicalReciprocityValue_m','rawCombination_s', ...
                'coordinateAsymmetry_s','stationTerminalDelayCorrectionForward_s', ...
                'stationTerminalDelayCorrectionReturn_s','atmosphereDelayForward_s', ...
                'atmosphereDelayReturn_s','sessionCommonCovariance_s2', ...
                'sessionCommonComponentOrder','sessionCommonTemporalModels','independentVariance_s2', ...
                'availability','truthDiagnosticIdentifier'};
            output = struct();
            for k = 1:numel(names)
                output.(names{k}) = obj.(names{k});
            end
        end
    end
end
