classdef FourTimestampClockDifferenceObservable
    % FourTimestampClockDifferenceObservable  Plan Section 4.3 interface (item 5): the processed
    % clock-difference observable built FROM a finished revgnss.ReciprocalTimestampExchangeRecord
    % -- constructed only via revgnss.FourTimestampObservableBuilder.fromExchangeRecord, never a
    % bare constructor call from arbitrary caller data (same discipline as
    % revgnss.DistributedLinkUpdateBlock / revgnss.ReciprocalTimestampExchangeRecord).
    %
    % Deliberately NOT named/shaped to collide with either frozen/gated vocabulary this stage
    % builds alongside: 'twoWayClockDifference' is already
    % revgnss.FirstOrderReciprocalClockTransferLinkUpdateAdapter.SupportedProcessedObservableType,
    % 'twoWayCodeRange' is already revgnss.CoherentTwoWayRangeLinkUpdateAdapter's; neither
    % revgnss.ReciprocalTimeTransferModel (PhysicalTimestampMode='fourTimestampPhysical' is
    % actively rejected by that class's own validateMode) nor
    % revgnss.InterSatelliteTimeTransferObservationRecord (on the plan's explicit do-not-rename
    % list, and itself gated via the same validateMode call) may be reused for this purpose --
    % revgnss.ReciprocalTimestampExchangeRecord's own header states directly that Section 4.3
    % owns building this observable, as a separate, later record that class does not define.
    %
    % Units are never conflated (item 5's explicit requirement), structurally, not just by naming
    % convention: clockDifferenceValue_* is the CROSS-clock quantity (destination clock relative
    % to origin clock); originRoundTripLocalDelay_s/anchorTurnaroundLocalDelay_s are SAME-clock
    % diagnostics, with no metres-domain sibling field and no shared schema slot with
    % clockDifferenceValue_*.
    %
    % clockDifferenceVariance_m2 is NaN whenever ~clockDifferenceVarianceDeclared -- "undeclared,
    % not fabricated zero" (matches revgnss.ReciprocalLinkHardwareModel's own zeros(0,0)
    % convention for an undeclared calibration covariance). Section 4.3 itself always constructs
    % this observable with clockDifferenceVarianceDeclared=false: reducing rawCovarianceBlock (a
    % free-text-labelled, caller-chosen componentOrder, not a frozen positional schema) into a
    % single scalar variance requires a caller-supplied combination-weight vector this stage does
    % not invent; a future Section 4.4 adapter, which itself chooses those labels, is the natural,
    % lowest-risk owner of that mapping.

    properties (Constant)
        ObservableIdentifier = 'fourTimestampClockDifference';
        AllowedTopologyKinds = {'directRoundTrip'}; % relayTransit: Section 4.5, refused by name
        AllowedTerminalDelayAllocations = {'receiveEvent','transmitEvent','splitEvenly'};
        SpeedOfLight_mps = 299792458;
    end

    properties (SetAccess = immutable)
        sourceExchangeIdentifier (1,:) char
        sourceSessionIdentifier (1,:) char
        topologyKind (1,:) char
        referenceEndpointIdentifier (1,:) char
        remoteEndpointIdentifier (1,:) char
        referenceEpochRule (1,:) char
        referenceCoordinateEpoch_s (1,1) double

        terminalDelayAllocation (1,:) char
        originTerminalGroupDelayApplied_s (1,1) double
        anchorTerminalGroupDelayApplied_s (1,1) double

        clockDifferenceValue_s (1,1) double
        clockDifferenceValue_m (1,1) double
        clockDifferenceVarianceDeclared (1,1) logical
        clockDifferenceVariance_m2 (1,1) double

        originRoundTripLocalDelay_s (1,1) double
        anchorTurnaroundLocalDelay_s (1,1) double

        rawCovarianceBlock (:,:) double
        rawCovarianceComponentOrder (1,:) cell
        rawCovarianceUnits (1,:) char

        calibrationProductIdentifiers (1,:) cell
        availability (1,1) logical
        truthDiagnosticIdentifier (1,:) char
    end

    methods
        function obj = FourTimestampClockDifferenceObservable(record)
            required = {'sourceExchangeIdentifier','sourceSessionIdentifier','topologyKind', ...
                'referenceEndpointIdentifier','remoteEndpointIdentifier','referenceEpochRule', ...
                'referenceCoordinateEpoch_s','terminalDelayAllocation', ...
                'originTerminalGroupDelayApplied_s','anchorTerminalGroupDelayApplied_s', ...
                'clockDifferenceValue_s','clockDifferenceValue_m','clockDifferenceVarianceDeclared', ...
                'clockDifferenceVariance_m2','originRoundTripLocalDelay_s', ...
                'anchorTurnaroundLocalDelay_s','rawCovarianceBlock','rawCovarianceComponentOrder', ...
                'rawCovarianceUnits','calibrationProductIdentifiers','availability', ...
                'truthDiagnosticIdentifier'};
            supplied = fieldnames(record);
            missing = setdiff(required,supplied);
            unknown = setdiff(supplied,required);
            if ~isempty(missing)
                error('FourTimestampClockDifferenceObservable:missingField', ...
                    'FourTimestampClockDifferenceObservable is missing %s.',missing{1});
            end
            if ~isempty(unknown)
                error('FourTimestampClockDifferenceObservable:unknownField', ...
                    'FourTimestampClockDifferenceObservable contains unsupported field %s.',unknown{1});
            end

            if isempty(strtrim(char(record.sourceExchangeIdentifier))) || ...
                    isempty(strtrim(char(record.sourceSessionIdentifier)))
                error('FourTimestampClockDifferenceObservable:identifiers', ...
                    'sourceExchangeIdentifier and sourceSessionIdentifier must be nonempty text.');
            end
            topologyKind = char(record.topologyKind);
            if ~any(strcmp(topologyKind, ...
                    revgnss.FourTimestampClockDifferenceObservable.AllowedTopologyKinds))
                error('FourTimestampClockDifferenceObservable:relayTopologyUnsupported', ...
                    'Only directRoundTrip is supported (relayTransit: Section 4.5).');
            end
            referenceId = char(record.referenceEndpointIdentifier);
            remoteId = char(record.remoteEndpointIdentifier);
            if isempty(strtrim(referenceId)) || isempty(strtrim(remoteId)) || ...
                    strcmp(referenceId,remoteId)
                error('FourTimestampClockDifferenceObservable:endpointIdentifiers', ...
                    'referenceEndpointIdentifier and remoteEndpointIdentifier must be distinct nonempty text.');
            end
            if ~(isnumeric(record.referenceCoordinateEpoch_s) && ...
                    isscalar(record.referenceCoordinateEpoch_s) && ...
                    isfinite(record.referenceCoordinateEpoch_s))
                error('FourTimestampClockDifferenceObservable:referenceCoordinateEpoch', ...
                    'referenceCoordinateEpoch_s must be a finite scalar.');
            end

            allocation = char(record.terminalDelayAllocation);
            if ~any(strcmp(allocation, ...
                    revgnss.FourTimestampClockDifferenceObservable.AllowedTerminalDelayAllocations))
                error('FourTimestampClockDifferenceObservable:terminalDelayAllocation', ...
                    'terminalDelayAllocation must be a frozen allocation.');
            end
            if ~(isnumeric(record.originTerminalGroupDelayApplied_s) && ...
                    isscalar(record.originTerminalGroupDelayApplied_s) && ...
                    isfinite(record.originTerminalGroupDelayApplied_s) && ...
                    record.originTerminalGroupDelayApplied_s >= 0 && ...
                    isnumeric(record.anchorTerminalGroupDelayApplied_s) && ...
                    isscalar(record.anchorTerminalGroupDelayApplied_s) && ...
                    isfinite(record.anchorTerminalGroupDelayApplied_s) && ...
                    record.anchorTerminalGroupDelayApplied_s >= 0)
                error('FourTimestampClockDifferenceObservable:terminalGroupDelayApplied', ...
                    'originTerminalGroupDelayApplied_s/anchorTerminalGroupDelayApplied_s must be finite and nonnegative.');
            end

            c = revgnss.FourTimestampClockDifferenceObservable.SpeedOfLight_mps;
            if ~(isnumeric(record.clockDifferenceValue_s) && isscalar(record.clockDifferenceValue_s) && ...
                    isfinite(record.clockDifferenceValue_s))
                error('FourTimestampClockDifferenceObservable:clockDifferenceValue', ...
                    'clockDifferenceValue_s must be a finite scalar.');
            end
            if abs(record.clockDifferenceValue_m - c*record.clockDifferenceValue_s) > ...
                    1e-6*max(1,abs(record.clockDifferenceValue_m))
                error('FourTimestampClockDifferenceObservable:clockDifferenceUnitsMismatch', ...
                    'clockDifferenceValue_m must equal SpeedOfLight_mps * clockDifferenceValue_s.');
            end
            if ~(islogical(record.clockDifferenceVarianceDeclared) && ...
                    isscalar(record.clockDifferenceVarianceDeclared))
                error('FourTimestampClockDifferenceObservable:varianceDeclared', ...
                    'clockDifferenceVarianceDeclared must be a logical scalar.');
            end
            if record.clockDifferenceVarianceDeclared
                if ~(isnumeric(record.clockDifferenceVariance_m2) && ...
                        isscalar(record.clockDifferenceVariance_m2) && ...
                        isfinite(record.clockDifferenceVariance_m2) && ...
                        record.clockDifferenceVariance_m2 > 0)
                    error('FourTimestampClockDifferenceObservable:variance', ...
                        'clockDifferenceVariance_m2 must be finite and positive when declared.');
                end
            elseif ~isnan(record.clockDifferenceVariance_m2)
                error('FourTimestampClockDifferenceObservable:variance', ...
                    'clockDifferenceVariance_m2 must be exactly NaN when not declared.');
            end

            if ~(isnumeric(record.originRoundTripLocalDelay_s) && ...
                    isscalar(record.originRoundTripLocalDelay_s) && ...
                    isfinite(record.originRoundTripLocalDelay_s) && ...
                    isnumeric(record.anchorTurnaroundLocalDelay_s) && ...
                    isscalar(record.anchorTurnaroundLocalDelay_s) && ...
                    isfinite(record.anchorTurnaroundLocalDelay_s))
                error('FourTimestampClockDifferenceObservable:diagnostics', ...
                    'originRoundTripLocalDelay_s/anchorTurnaroundLocalDelay_s must be finite scalars.');
            end

            covariance = record.rawCovarianceBlock;
            if ~isnumeric(covariance) || isempty(covariance) || ...
                    size(covariance,1) ~= size(covariance,2) || any(~isfinite(covariance),'all') || ...
                    norm(covariance-covariance','fro') > 1e-12*max(1,norm(covariance,'fro')) || ...
                    min(eig((covariance+covariance')/2)) < -1e-12*max(1,norm(covariance,'fro'))
                error('FourTimestampClockDifferenceObservable:rawCovarianceBlock', ...
                    'rawCovarianceBlock must be finite, symmetric, and positive semidefinite.');
            end
            componentOrder = record.rawCovarianceComponentOrder;
            if ~iscell(componentOrder) || numel(componentOrder) ~= size(covariance,1) || ...
                    any(cellfun(@(v) ~(ischar(v)||isstring(v)) || isempty(strtrim(char(v))),componentOrder))
                error('FourTimestampClockDifferenceObservable:rawCovarianceComponentOrder', ...
                    'rawCovarianceComponentOrder must have one nonempty text entry per rawCovarianceBlock row.');
            end
            if isempty(strtrim(char(record.rawCovarianceUnits)))
                error('FourTimestampClockDifferenceObservable:rawCovarianceUnits', ...
                    'rawCovarianceUnits must be nonempty text.');
            end

            calibIds = record.calibrationProductIdentifiers;
            if isstring(calibIds); calibIds = cellstr(calibIds); end
            if ~iscell(calibIds) || any(~cellfun(@(v) ischar(v) || (isstring(v)&&isscalar(v)),calibIds))
                error('FourTimestampClockDifferenceObservable:calibrationProductIdentifiers', ...
                    'calibrationProductIdentifiers must be a cell array of text.');
            end
            if ~(islogical(record.availability) && isscalar(record.availability))
                error('FourTimestampClockDifferenceObservable:availability', ...
                    'availability must be a logical scalar.');
            end
            if ~(ischar(record.truthDiagnosticIdentifier) || isstring(record.truthDiagnosticIdentifier))
                error('FourTimestampClockDifferenceObservable:truthDiagnosticIdentifier', ...
                    'truthDiagnosticIdentifier must be text (may be empty).');
            end

            obj.sourceExchangeIdentifier = char(record.sourceExchangeIdentifier);
            obj.sourceSessionIdentifier = char(record.sourceSessionIdentifier);
            obj.topologyKind = topologyKind;
            obj.referenceEndpointIdentifier = referenceId;
            obj.remoteEndpointIdentifier = remoteId;
            obj.referenceEpochRule = char(record.referenceEpochRule);
            obj.referenceCoordinateEpoch_s = double(record.referenceCoordinateEpoch_s);
            obj.terminalDelayAllocation = allocation;
            obj.originTerminalGroupDelayApplied_s = double(record.originTerminalGroupDelayApplied_s);
            obj.anchorTerminalGroupDelayApplied_s = double(record.anchorTerminalGroupDelayApplied_s);
            obj.clockDifferenceValue_s = double(record.clockDifferenceValue_s);
            obj.clockDifferenceValue_m = double(record.clockDifferenceValue_m);
            obj.clockDifferenceVarianceDeclared = logical(record.clockDifferenceVarianceDeclared);
            obj.clockDifferenceVariance_m2 = double(record.clockDifferenceVariance_m2);
            obj.originRoundTripLocalDelay_s = double(record.originRoundTripLocalDelay_s);
            obj.anchorTurnaroundLocalDelay_s = double(record.anchorTurnaroundLocalDelay_s);
            obj.rawCovarianceBlock = (covariance+covariance')/2;
            obj.rawCovarianceComponentOrder = cellfun(@char,componentOrder,'UniformOutput',false);
            obj.rawCovarianceUnits = char(record.rawCovarianceUnits);
            obj.calibrationProductIdentifiers = cellfun(@char,calibIds,'UniformOutput',false);
            obj.availability = logical(record.availability);
            obj.truthDiagnosticIdentifier = char(record.truthDiagnosticIdentifier);
        end

        function output = toStruct(obj)
            % Hand-lists SetAccess=immutable field names rather than using properties(obj): this
            % class has a properties(Constant) block (the two Allowed* lists), and properties(obj)
            % would silently include those too (the established, twice-previously-hit footgun).
            names = {'sourceExchangeIdentifier','sourceSessionIdentifier','topologyKind', ...
                'referenceEndpointIdentifier','remoteEndpointIdentifier','referenceEpochRule', ...
                'referenceCoordinateEpoch_s','terminalDelayAllocation', ...
                'originTerminalGroupDelayApplied_s','anchorTerminalGroupDelayApplied_s', ...
                'clockDifferenceValue_s','clockDifferenceValue_m','clockDifferenceVarianceDeclared', ...
                'clockDifferenceVariance_m2','originRoundTripLocalDelay_s', ...
                'anchorTurnaroundLocalDelay_s','rawCovarianceBlock','rawCovarianceComponentOrder', ...
                'rawCovarianceUnits','calibrationProductIdentifiers','availability', ...
                'truthDiagnosticIdentifier'};
            output = struct();
            for k = 1:numel(names)
                output.(names{k}) = obj.(names{k});
            end
        end
    end
end
