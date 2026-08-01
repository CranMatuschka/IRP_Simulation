classdef InterSatelliteFourTimestampObservationRecord
    % InterSatelliteFourTimestampObservationRecord  Plan Section 4.4: the immutable processed
    % ISL four-timestamp clock datum, mirroring revgnss.InterSatelliteTimeTransferObservationRecord's
    % field vocabulary where it is shared, with genuine differences where the physics differs:
    %
    %   - NO delegation to revgnss.ReciprocalTimeTransferModel.validateMode: that class stays
    %     entirely untouched by this section (its own PhysicalTimestampMode='fourTimestampPhysical'
    %     names a DIFFERENT, still-unimplemented raw-tag scheme -- see
    %     revgnss.FourTimestampClockDifferenceObservable's own header). modeIdentifier here is
    %     always the frozen literal 'fourTimestampClockDifference'.
    %   - protocolIdentifier is always 'directFourTimestampTwoWay' (not 'reciprocalTwoWayTimeTransfer',
    %     the first-order-only protocol string).
    %   - referenceEpochRule is always 'finalReception' (not 'commonCoordinateEpoch'): the
    %     four-timestamp physics has a genuine t1..t4 event chain, not a single shared epoch.
    %   - rawTimestampTagsAvailable is ALWAYS true (the inverse of the first-order record's
    %     always-false convention) and reciprocityTermIncluded is ALWAYS false (this observable has
    %     no reciprocity-residual concept at all).
    %   - the terminal identity is a FULL tx/rx terminal+antenna quadruple per side (not one bare
    %     terminal identifier per side), since this observable's Jacobian genuinely is sensitive to
    %     lever arm (revgnss.FourTimestampObservableLinearization.islTwoEndpointJacobian), unlike
    %     revgnss.ReciprocalTimeTransferModel's always-zero position/velocity partials.

    properties (SetAccess = immutable)
        observationIdentifier (1,:) char
        sessionIdentifier (1,:) char
        linkIdentifier (1,:) char
        referenceAssetIdentifier (1,:) char
        remoteAssetIdentifier (1,:) char
        referenceTransmitTerminalIdentifier (1,:) char
        referenceReceiveTerminalIdentifier (1,:) char
        referenceTransmitAntennaIdentifier (1,:) char
        referenceReceiveAntennaIdentifier (1,:) char
        remoteTransmitTerminalIdentifier (1,:) char
        remoteReceiveTerminalIdentifier (1,:) char
        remoteTransmitAntennaIdentifier (1,:) char
        remoteReceiveAntennaIdentifier (1,:) char
        protocolIdentifier (1,:) char
        modeIdentifier (1,:) char
        signalIdentifier (1,:) char
        channelIdentifier (1,:) char
        referenceEpoch_s (1,1) double
        referenceEpochRule (1,:) char
        rawTimestampTagsAvailable (1,1) logical
        timestampTags_s (1,4) double
        processedObservableType (1,:) char
        processedValue (1,1) double
        processedUnits (1,:) char
        covarianceGroupIdentifier (1,:) char
        covarianceRowIndex (1,1) double
        covarianceBlock (:,:) double
        covarianceUnits (1,:) char
        calibrationProductIdentifiers (1,:) cell
        available (1,1) logical
        qualityFlags (1,1) struct
        truthDiagnosticIdentifier (1,:) char
        referenceLocalClockTag_s (1,1) double
        calibrationValidFromLocalTag_s (1,1) double
        calibrationValidUntilLocalTag_s (1,1) double
        reciprocityTermIncluded (1,1) logical
    end

    methods
        function obj = InterSatelliteFourTimestampObservationRecord(record)
            arguments
                record (1,1) struct
            end
            fields = properties(obj);
            supplied = fieldnames(record);
            unknown = setdiff(supplied,fields);
            missing = setdiff(fields,supplied);
            if ~isempty(unknown)
                error('InterSatelliteFourTimestampObservationRecord:unknownField', ...
                    'Observation record contains unsupported field %s.',unknown{1});
            end
            if ~isempty(missing)
                error('InterSatelliteFourTimestampObservationRecord:missingField', ...
                    'Observation record is missing field %s.',missing{1});
            end
            if ~strcmp(char(record.protocolIdentifier),'directFourTimestampTwoWay')
                error('InterSatelliteFourTimestampObservationRecord:protocol', ...
                    'The protocol must be directFourTimestampTwoWay.');
            end
            if ~strcmp(char(record.modeIdentifier),'fourTimestampClockDifference')
                error('InterSatelliteFourTimestampObservationRecord:mode', ...
                    'The mode must be fourTimestampClockDifference.');
            end
            if ~strcmp(char(record.referenceEpochRule),'finalReception')
                error('InterSatelliteFourTimestampObservationRecord:referenceEpoch', ...
                    'The four-timestamp observable uses finalReception.');
            end
            if ~strcmp(char(record.processedObservableType),'fourTimestampClockDifference') || ...
                    ~strcmp(char(record.processedUnits),'m')
                error('InterSatelliteFourTimestampObservationRecord:observable', ...
                    'The record must contain a fourTimestampClockDifference in metres.');
            end
            if ~(isnumeric(record.referenceEpoch_s) && isscalar(record.referenceEpoch_s) && ...
                    isfinite(record.referenceEpoch_s) && ...
                    isnumeric(record.processedValue) && isscalar(record.processedValue) && ...
                    isfinite(record.processedValue))
                error('InterSatelliteFourTimestampObservationRecord:value', ...
                    'Epoch and processed value must be finite scalars.');
            end
            if ~(islogical(record.rawTimestampTagsAvailable) && isscalar(record.rawTimestampTagsAvailable)) || ...
                    ~record.rawTimestampTagsAvailable
                error('InterSatelliteFourTimestampObservationRecord:rawTimestampTagsAvailable', ...
                    'rawTimestampTagsAvailable must be true for this observable.');
            end
            if ~isnumeric(record.timestampTags_s) || ~isequal(size(record.timestampTags_s),[1 4]) || ...
                    any(~isfinite(record.timestampTags_s)) || ...
                    ~(record.timestampTags_s(1) <= record.timestampTags_s(2) && ...
                    record.timestampTags_s(2) <= record.timestampTags_s(3) && ...
                    record.timestampTags_s(3) <= record.timestampTags_s(4))
                error('InterSatelliteFourTimestampObservationRecord:timestampTags', ...
                    'timestampTags_s must be four finite, time-ordered values.');
            end
            covariance = record.covarianceBlock;
            if ~isnumeric(covariance) || isempty(covariance) || ...
                    size(covariance,1) ~= size(covariance,2) || any(~isfinite(covariance),'all') || ...
                    norm(covariance-covariance','fro') > 1e-12 || ...
                    min(eig((covariance+covariance')/2)) < -1e-12
                error('InterSatelliteFourTimestampObservationRecord:covariance', ...
                    'covarianceBlock must be finite, symmetric, and positive semidefinite.');
            end
            rowIndex = record.covarianceRowIndex;
            if ~(isscalar(rowIndex) && rowIndex == round(rowIndex) && ...
                    rowIndex >= 1 && rowIndex <= size(covariance,1))
                error('InterSatelliteFourTimestampObservationRecord:covarianceRow', ...
                    'covarianceRowIndex must select a covariance row.');
            end
            calibrationIdentifiers = record.calibrationProductIdentifiers;
            if isstring(calibrationIdentifiers); calibrationIdentifiers = cellstr(calibrationIdentifiers); end
            if ~iscell(calibrationIdentifiers) || ...
                    any(~cellfun(@(value) ischar(value) || (isstring(value) && isscalar(value)), ...
                    calibrationIdentifiers))
                error('InterSatelliteFourTimestampObservationRecord:calibration', ...
                    'Calibration product identifiers must be text.');
            end
            if ~(isnumeric(record.referenceLocalClockTag_s) && isscalar(record.referenceLocalClockTag_s) && ...
                    isfinite(record.referenceLocalClockTag_s) && ...
                    isnumeric(record.calibrationValidFromLocalTag_s) && ...
                    isscalar(record.calibrationValidFromLocalTag_s) && ...
                    isfinite(record.calibrationValidFromLocalTag_s) && ...
                    isnumeric(record.calibrationValidUntilLocalTag_s) && ...
                    isscalar(record.calibrationValidUntilLocalTag_s) && ...
                    isfinite(record.calibrationValidUntilLocalTag_s) && ...
                    record.calibrationValidFromLocalTag_s <= record.calibrationValidUntilLocalTag_s)
                error('InterSatelliteFourTimestampObservationRecord:calibrationValidity', ...
                    ['referenceLocalClockTag_s and the calibration validity interval must be finite ' ...
                    'scalars with calibrationValidFromLocalTag_s <= calibrationValidUntilLocalTag_s.']);
            end
            if ~(islogical(record.reciprocityTermIncluded) && isscalar(record.reciprocityTermIncluded)) || ...
                    record.reciprocityTermIncluded
                error('InterSatelliteFourTimestampObservationRecord:reciprocityTermIncluded', ...
                    'reciprocityTermIncluded must be false: this observable has no reciprocity term.');
            end

            for fieldIndex = 1:numel(fields)
                fieldName = fields{fieldIndex};
                value = record.(fieldName);
                if ischar(obj.(fieldName)); value = char(value); end
                obj.(fieldName) = value;
            end
            obj.calibrationProductIdentifiers = cellfun(@char,calibrationIdentifiers,'UniformOutput',false);
        end

        function output = toStruct(obj)
            names = properties(obj);
            output = struct();
            for fieldIndex = 1:numel(names)
                output.(names{fieldIndex}) = obj.(names{fieldIndex});
            end
        end
    end
end
