classdef ReciprocalTimestampExchangeRecord
    % ReciprocalTimestampExchangeRecord  Plan Section 4.2 interface #1: an immutable, RAW-TAGS-
    % ONLY four-event timestamp exchange, deliberately distinct from
    % revgnss.InterSatelliteObservationRecord (2 local-clock tags, both on the initiator's own
    % clock, one processed 'twoWayCodeRange' observable) and
    % revgnss.InterSatelliteTimeTransferObservationRecord (a timestampTags_s(1,4) slot that
    % exists in schema but is always nan(1,4) at every production construction site today). This
    % record carries no processedValue/processedUnits field at all -- a genuinely populated
    % four-tag record cannot be confused with, or create rename/reuse pressure on, either frozen
    % schema. Plan Section 4.3 owns building a processed clock-difference observable FROM a
    % finished record of this type; it is a separate, later record this class does not define.
    %
    % chainEndpointIdentifiers is the one field that generalizes a direct round-trip
    % ({origin,destination,destination,origin}) and a 3-node relay transit
    % ({origin,relay,relay,destination}, plan Section 4.5) under one schema with no change
    % between them -- topologyKind names which shape is in use. No new code anywhere may index a
    % collection of these records positionally (e.g. record(1), events(1)): every record carries
    % its own exchangeIdentifier/sessionIdentifier, exactly because Section 4.1's own completion
    % record flagged +revgnss/ISLTimingModel.m's unguarded positional indexing
    % (linkEvents(1)/twoWay(1)/twoWay(2)) as a defect the neutral event core must not inherit.

    properties (Constant)
        AllowedTopologyKinds = {'directRoundTrip','relayTransit'};
        AllowedReferenceEpochRules = {'finalReception','commonCoordinateEpoch'};
    end

    properties (SetAccess = immutable)
        exchangeIdentifier (1,:) char
        sessionIdentifier (1,:) char
        topologyKind (1,:) char
        chainEndpointIdentifiers (1,4) cell
        chainTerminalIdentifiers (1,4) cell
        localClockCompareEndpointIdentifiers (1,2) cell
        referenceEpochRule (1,:) char
        referenceCoordinateEpoch_s (1,1) double
        coordinateTimeEvents_s (1,4) double
        localClockTags_s (1,4) double
        localClockTagAvailable (1,4) logical
        localTimeSystemIdentifiers (1,4) cell
        protocolIdentifier (1,:) char
        signalIdentifier (1,:) char
        channelIdentifier (1,:) char
        chainCarrierFrequency_Hz (1,4) double
        legAppliesAtmosphere (1,4) logical
        calibrationProductIdentifiers (1,:) cell
        covarianceGroupIdentifiers (1,:) cell
        covarianceBlock (:,:) double
        covarianceComponentOrder (1,:) cell
        covarianceUnits (1,:) char
        qualityFlags (1,1) struct
        availability (1,1) logical
        truthDiagnosticIdentifier (1,:) char
    end

    methods
        function obj = ReciprocalTimestampExchangeRecord(record)
            required = {'exchangeIdentifier','sessionIdentifier','topologyKind', ...
                'chainEndpointIdentifiers','chainTerminalIdentifiers', ...
                'localClockCompareEndpointIdentifiers','referenceEpochRule', ...
                'referenceCoordinateEpoch_s','coordinateTimeEvents_s','localClockTags_s', ...
                'localClockTagAvailable','localTimeSystemIdentifiers','protocolIdentifier', ...
                'signalIdentifier','channelIdentifier','chainCarrierFrequency_Hz', ...
                'legAppliesAtmosphere','calibrationProductIdentifiers', ...
                'covarianceGroupIdentifiers','covarianceBlock','covarianceComponentOrder', ...
                'covarianceUnits','qualityFlags','availability','truthDiagnosticIdentifier'};
            supplied = fieldnames(record);
            missing = setdiff(required,supplied);
            unknown = setdiff(supplied,required);
            if ~isempty(missing)
                error('ReciprocalTimestampExchangeRecord:missingField', ...
                    'ReciprocalTimestampExchangeRecord is missing %s.',missing{1});
            end
            if ~isempty(unknown)
                error('ReciprocalTimestampExchangeRecord:unknownField', ...
                    'ReciprocalTimestampExchangeRecord contains unsupported field %s.',unknown{1});
            end

            if isempty(strtrim(char(record.exchangeIdentifier)))
                error('ReciprocalTimestampExchangeRecord:exchangeIdentifier', ...
                    'exchangeIdentifier must be nonempty text.');
            end
            if isempty(strtrim(char(record.sessionIdentifier)))
                error('ReciprocalTimestampExchangeRecord:sessionIdentifier', ...
                    'sessionIdentifier must be nonempty text.');
            end
            topologyKind = char(record.topologyKind);
            if ~any(strcmp(topologyKind, ...
                    revgnss.ReciprocalTimestampExchangeRecord.AllowedTopologyKinds))
                error('ReciprocalTimestampExchangeRecord:topologyKind', ...
                    'topologyKind must be a frozen allowed topology kind.');
            end

            chainEndpoints = record.chainEndpointIdentifiers;
            if ~iscell(chainEndpoints) || numel(chainEndpoints) ~= 4 || ...
                    any(cellfun(@(v) ~(ischar(v)||isstring(v)) || isempty(strtrim(char(v))), ...
                    chainEndpoints))
                error('ReciprocalTimestampExchangeRecord:chainEndpointIdentifiers', ...
                    'chainEndpointIdentifiers must be a 1-by-4 cell of nonempty identifiers.');
            end
            if strcmp(topologyKind,'directRoundTrip')
                if ~strcmp(char(chainEndpoints{1}),char(chainEndpoints{4})) || ...
                        ~strcmp(char(chainEndpoints{2}),char(chainEndpoints{3})) || ...
                        strcmp(char(chainEndpoints{1}),char(chainEndpoints{2}))
                    error('ReciprocalTimestampExchangeRecord:directTopologyShape', ...
                        ['directRoundTrip requires chainEndpointIdentifiers = {origin,dest,dest,' ...
                        'origin} with origin ~= dest.']);
                end
            else
                if ~strcmp(char(chainEndpoints{2}),char(chainEndpoints{3})) || ...
                        strcmp(char(chainEndpoints{1}),char(chainEndpoints{2})) || ...
                        strcmp(char(chainEndpoints{2}),char(chainEndpoints{4})) || ...
                        strcmp(char(chainEndpoints{1}),char(chainEndpoints{4}))
                    error('ReciprocalTimestampExchangeRecord:relayTopologyShape', ...
                        ['relayTransit requires chainEndpointIdentifiers = {origin,relay,relay,' ...
                        'destination} with all three of origin/relay/destination distinct.']);
                end
            end

            chainTerminals = record.chainTerminalIdentifiers;
            if ~iscell(chainTerminals) || numel(chainTerminals) ~= 4 || ...
                    any(cellfun(@(v) ~(ischar(v)||isstring(v)) || isempty(strtrim(char(v))), ...
                    chainTerminals))
                error('ReciprocalTimestampExchangeRecord:chainTerminalIdentifiers', ...
                    'chainTerminalIdentifiers must be a 1-by-4 cell of nonempty identifiers.');
            end

            compareEndpoints = record.localClockCompareEndpointIdentifiers;
            if ~iscell(compareEndpoints) || numel(compareEndpoints) ~= 2 || ...
                    any(cellfun(@(v) ~(ischar(v)||isstring(v)) || isempty(strtrim(char(v))), ...
                    compareEndpoints)) || strcmp(char(compareEndpoints{1}),char(compareEndpoints{2}))
                error('ReciprocalTimestampExchangeRecord:localClockCompareEndpointIdentifiers', ...
                    'localClockCompareEndpointIdentifiers must be 2 distinct nonempty identifiers.');
            end
            % Both compared endpoints must actually be members of the chain this record describes
            % (Stage 4.2 combined review finding 14) -- the whole point of the record is a
            % processed clock difference BETWEEN two of its own chain endpoints, not an arbitrary
            % unrelated pair of identifiers.
            if ~any(cellfun(@(v) strcmp(char(compareEndpoints{1}),char(v)),chainEndpoints)) || ...
                    ~any(cellfun(@(v) strcmp(char(compareEndpoints{2}),char(v)),chainEndpoints))
                error('ReciprocalTimestampExchangeRecord:localClockCompareEndpointIdentifiers', ...
                    'Both localClockCompareEndpointIdentifiers must appear in chainEndpointIdentifiers.');
            end

            referenceEpochRule = char(record.referenceEpochRule);
            if ~any(strcmp(referenceEpochRule, ...
                    revgnss.ReciprocalTimestampExchangeRecord.AllowedReferenceEpochRules))
                error('ReciprocalTimestampExchangeRecord:referenceEpochRule', ...
                    'referenceEpochRule must be a frozen allowed reference-epoch rule.');
            end
            if ~(isnumeric(record.referenceCoordinateEpoch_s) && ...
                    isscalar(record.referenceCoordinateEpoch_s) && ...
                    isfinite(record.referenceCoordinateEpoch_s))
                error('ReciprocalTimestampExchangeRecord:referenceCoordinateEpoch', ...
                    'referenceCoordinateEpoch_s must be a finite scalar.');
            end

            events_s = record.coordinateTimeEvents_s;
            if ~isnumeric(events_s) || ~isequal(size(events_s),[1 4]) || any(~isfinite(events_s))
                error('ReciprocalTimestampExchangeRecord:coordinateTimeEvents', ...
                    'coordinateTimeEvents_s must be a finite 1-by-4 vector.');
            end
            if ~(events_s(1) <= events_s(2) && events_s(2) <= events_s(3) && ...
                    events_s(3) <= events_s(4))
                error('ReciprocalTimestampExchangeRecord:coordinateTimeEventsOrder', ...
                    'coordinateTimeEvents_s must be time-ordered t1 <= t2 <= t3 <= t4.');
            end

            available = record.localClockTagAvailable;
            if ~islogical(available) || ~isequal(size(available),[1 4])
                error('ReciprocalTimestampExchangeRecord:localClockTagAvailable', ...
                    'localClockTagAvailable must be a 1-by-4 logical vector.');
            end
            tags_s = record.localClockTags_s;
            if ~isnumeric(tags_s) || ~isequal(size(tags_s),[1 4])
                error('ReciprocalTimestampExchangeRecord:localClockTags', ...
                    'localClockTags_s must be a 1-by-4 numeric vector.');
            end
            if any(~isfinite(tags_s(available))) || any(~isnan(tags_s(~available)))
                error('ReciprocalTimestampExchangeRecord:localClockTagsAvailability', ...
                    ['localClockTags_s must be finite where localClockTagAvailable is true and ' ...
                    'NaN where it is false.']);
            end

            timeSystems = record.localTimeSystemIdentifiers;
            if ~iscell(timeSystems) || numel(timeSystems) ~= 4 || ...
                    any(cellfun(@(v) ~(ischar(v)||isstring(v)) || isempty(strtrim(char(v))), ...
                    timeSystems))
                error('ReciprocalTimestampExchangeRecord:localTimeSystemIdentifiers', ...
                    'localTimeSystemIdentifiers must be a 1-by-4 cell of nonempty identifiers.');
            end

            if isempty(strtrim(char(record.protocolIdentifier)))
                error('ReciprocalTimestampExchangeRecord:protocolIdentifier', ...
                    'protocolIdentifier must be nonempty text.');
            end
            if isempty(strtrim(char(record.signalIdentifier)))
                error('ReciprocalTimestampExchangeRecord:signalIdentifier', ...
                    'signalIdentifier must be nonempty text.');
            end
            if isempty(strtrim(char(record.channelIdentifier)))
                error('ReciprocalTimestampExchangeRecord:channelIdentifier', ...
                    'channelIdentifier must be nonempty text.');
            end

            freq_Hz = record.chainCarrierFrequency_Hz;
            if ~isnumeric(freq_Hz) || ~isequal(size(freq_Hz),[1 4]) || ...
                    any(~isfinite(freq_Hz)) || any(freq_Hz <= 0)
                error('ReciprocalTimestampExchangeRecord:chainCarrierFrequency', ...
                    'chainCarrierFrequency_Hz must be a 1-by-4 vector of finite positive frequencies.');
            end

            legAtmosphere = record.legAppliesAtmosphere;
            if ~islogical(legAtmosphere) || ~isequal(size(legAtmosphere),[1 4])
                error('ReciprocalTimestampExchangeRecord:legAppliesAtmosphere', ...
                    'legAppliesAtmosphere must be a 1-by-4 logical vector.');
            end
            % legAppliesAtmosphere is declared per COORDINATE EVENT (4 slots) but atmosphere is
            % physically a per-LEG property: the forward leg is t1->t2 (events 1,2), the return
            % leg is t3->t4 (events 3,4). Nothing upstream of this check enforced the two events
            % sharing one leg to agree, so [true false true false] previously constructed cleanly
            % -- a structurally meaningless "half a leg crosses atmosphere" claim (Stage 4.2
            % combined review finding 3).
            if legAtmosphere(1) ~= legAtmosphere(2) || legAtmosphere(3) ~= legAtmosphere(4)
                error('ReciprocalTimestampExchangeRecord:legAppliesAtmosphereLegPair', ...
                    ['legAppliesAtmosphere must agree within each leg: (1)==(2) for the forward ' ...
                    'leg t1->t2, and (3)==(4) for the return leg t3->t4.']);
            end

            calibIds = record.calibrationProductIdentifiers;
            if isstring(calibIds); calibIds = cellstr(calibIds); end
            if ~iscell(calibIds) || any(~cellfun(@(v) ischar(v) || (isstring(v)&&isscalar(v)),calibIds))
                error('ReciprocalTimestampExchangeRecord:calibrationProductIdentifiers', ...
                    'calibrationProductIdentifiers must be a cell array of text.');
            end
            covGroupIds = record.covarianceGroupIdentifiers;
            if isstring(covGroupIds); covGroupIds = cellstr(covGroupIds); end
            if ~iscell(covGroupIds) || any(~cellfun(@(v) ischar(v) || (isstring(v)&&isscalar(v)),covGroupIds))
                error('ReciprocalTimestampExchangeRecord:covarianceGroupIdentifiers', ...
                    'covarianceGroupIdentifiers must be a cell array of text.');
            end

            covariance = record.covarianceBlock;
            if ~isnumeric(covariance) || isempty(covariance) || ...
                    size(covariance,1) ~= size(covariance,2) || any(~isfinite(covariance),'all') || ...
                    norm(covariance-covariance','fro') > 1e-12*max(1,norm(covariance,'fro')) || ...
                    min(eig((covariance+covariance')/2)) < -1e-12*max(1,norm(covariance,'fro'))
                error('ReciprocalTimestampExchangeRecord:covarianceBlock', ...
                    'covarianceBlock must be finite, symmetric, and positive semidefinite.');
            end
            componentOrder = record.covarianceComponentOrder;
            if ~iscell(componentOrder) || numel(componentOrder) ~= size(covariance,1) || ...
                    any(cellfun(@(v) ~(ischar(v)||isstring(v)) || isempty(strtrim(char(v))),componentOrder))
                error('ReciprocalTimestampExchangeRecord:covarianceComponentOrder', ...
                    'covarianceComponentOrder must have one nonempty text entry per covarianceBlock row.');
            end
            if isempty(strtrim(char(record.covarianceUnits)))
                error('ReciprocalTimestampExchangeRecord:covarianceUnits', ...
                    'covarianceUnits must be nonempty text.');
            end

            if ~isstruct(record.qualityFlags) || ~isscalar(record.qualityFlags)
                error('ReciprocalTimestampExchangeRecord:qualityFlags', ...
                    'qualityFlags must be a scalar struct.');
            end
            if ~islogical(record.availability) || ~isscalar(record.availability)
                error('ReciprocalTimestampExchangeRecord:availability', ...
                    'availability must be a logical scalar.');
            end
            % truthDiagnosticIdentifier may legitimately be empty text (many callers have no
            % diagnostic identifier to attach), but it must still BE text -- previously any value
            % silently passed through char() with no type check at all (Stage 4.2 combined review
            % finding 12), so e.g. a numeric 65 would silently become 'A'.
            if ~(ischar(record.truthDiagnosticIdentifier) || isstring(record.truthDiagnosticIdentifier))
                error('ReciprocalTimestampExchangeRecord:truthDiagnosticIdentifier', ...
                    'truthDiagnosticIdentifier must be text (may be empty).');
            end

            obj.exchangeIdentifier = char(record.exchangeIdentifier);
            obj.sessionIdentifier = char(record.sessionIdentifier);
            obj.topologyKind = topologyKind;
            obj.chainEndpointIdentifiers = cellfun(@char,chainEndpoints,'UniformOutput',false);
            obj.chainTerminalIdentifiers = cellfun(@char,chainTerminals,'UniformOutput',false);
            obj.localClockCompareEndpointIdentifiers = cellfun(@char,compareEndpoints,'UniformOutput',false);
            obj.referenceEpochRule = referenceEpochRule;
            obj.referenceCoordinateEpoch_s = double(record.referenceCoordinateEpoch_s);
            obj.coordinateTimeEvents_s = events_s;
            obj.localClockTags_s = tags_s;
            obj.localClockTagAvailable = available;
            obj.localTimeSystemIdentifiers = cellfun(@char,timeSystems,'UniformOutput',false);
            obj.protocolIdentifier = char(record.protocolIdentifier);
            obj.signalIdentifier = char(record.signalIdentifier);
            obj.channelIdentifier = char(record.channelIdentifier);
            obj.chainCarrierFrequency_Hz = freq_Hz;
            obj.legAppliesAtmosphere = legAtmosphere;
            obj.calibrationProductIdentifiers = cellfun(@char,calibIds,'UniformOutput',false);
            obj.covarianceGroupIdentifiers = cellfun(@char,covGroupIds,'UniformOutput',false);
            obj.covarianceBlock = (covariance+covariance')/2;
            obj.covarianceComponentOrder = cellfun(@char,componentOrder,'UniformOutput',false);
            obj.covarianceUnits = char(record.covarianceUnits);
            obj.qualityFlags = record.qualityFlags;
            obj.availability = logical(record.availability);
            obj.truthDiagnosticIdentifier = char(record.truthDiagnosticIdentifier);
        end

        function output = toStruct(obj)
            % toStruct  Deliberately hand-lists SetAccess=immutable field names rather than
            % using properties(obj): this class has a properties(Constant) block
            % (AllowedTopologyKinds/AllowedReferenceEpochRules), and properties(obj) includes
            % Constant properties in its result -- the exact footgun already hit twice this
            % session (OneWayInterSatelliteObservationRecord's constructor,
            % EstimatorEligibleEndpointStateProduct's toStruct()), avoided here by construction.
            names = {'exchangeIdentifier','sessionIdentifier','topologyKind', ...
                'chainEndpointIdentifiers','chainTerminalIdentifiers', ...
                'localClockCompareEndpointIdentifiers','referenceEpochRule', ...
                'referenceCoordinateEpoch_s','coordinateTimeEvents_s','localClockTags_s', ...
                'localClockTagAvailable','localTimeSystemIdentifiers','protocolIdentifier', ...
                'signalIdentifier','channelIdentifier','chainCarrierFrequency_Hz', ...
                'legAppliesAtmosphere','calibrationProductIdentifiers', ...
                'covarianceGroupIdentifiers','covarianceBlock','covarianceComponentOrder', ...
                'covarianceUnits','qualityFlags','availability','truthDiagnosticIdentifier'};
            output = struct();
            for fieldIndex = 1:numel(names)
                output.(names{fieldIndex}) = obj.(names{fieldIndex});
            end
        end
    end
end
