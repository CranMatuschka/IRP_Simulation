classdef InterSatelliteTimeTransferObservationRecord
    % InterSatelliteTimeTransferObservationRecord  Immutable processed ISL clock datum.

    properties (SetAccess = immutable)
        observationIdentifier (1,:) char
        sessionIdentifier (1,:) char
        linkIdentifier (1,:) char
        referenceAssetIdentifier (1,:) char
        remoteAssetIdentifier (1,:) char
        referenceTerminalIdentifier (1,:) char
        remoteTerminalIdentifier (1,:) char
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
        function obj = InterSatelliteTimeTransferObservationRecord(record)
            arguments
                record (1,1) struct
            end
            fields = properties(obj);
            supplied = fieldnames(record);
            unknown = setdiff(supplied,fields);
            missing = setdiff(fields,supplied);
            if ~isempty(unknown)
                error('InterSatelliteTimeTransferObservationRecord:unknownField', ...
                    'Observation record contains unsupported field %s.',unknown{1});
            end
            if ~isempty(missing)
                error('InterSatelliteTimeTransferObservationRecord:missingField', ...
                    'Observation record is missing field %s.',missing{1});
            end
            revgnss.ReciprocalTimeTransferModel.validateMode( ...
                record.modeIdentifier);
            if ~strcmp(char(record.protocolIdentifier), ...
                    'reciprocalTwoWayTimeTransfer')
                error('InterSatelliteTimeTransferObservationRecord:protocol', ...
                    'The protocol must be reciprocalTwoWayTimeTransfer.');
            end
            if ~strcmp(char(record.referenceEpochRule), ...
                    'commonCoordinateEpoch')
                error('InterSatelliteTimeTransferObservationRecord:referenceEpoch', ...
                    'The first-order observable uses commonCoordinateEpoch.');
            end
            if ~strcmp(char(record.processedObservableType), ...
                    'twoWayClockDifference') || ...
                    ~strcmp(char(record.processedUnits),'m')
                error('InterSatelliteTimeTransferObservationRecord:observable', ...
                    'The record must contain a twoWayClockDifference in metres.');
            end
            if ~(isnumeric(record.referenceEpoch_s) && ...
                    isscalar(record.referenceEpoch_s) && ...
                    isfinite(record.referenceEpoch_s) && ...
                    isnumeric(record.processedValue) && ...
                    isscalar(record.processedValue) && ...
                    isfinite(record.processedValue))
                error('InterSatelliteTimeTransferObservationRecord:value', ...
                    'Epoch and processed value must be finite scalars.');
            end
            if ~(islogical(record.rawTimestampTagsAvailable) && ...
                    isscalar(record.rawTimestampTagsAvailable)) || ...
                    ~isnumeric(record.timestampTags_s) || ...
                    ~isequal(size(record.timestampTags_s),[1 4])
                error('InterSatelliteTimeTransferObservationRecord:timestampTags', ...
                    'Timestamp availability and the four-tag vector are invalid.');
            end
            if record.rawTimestampTagsAvailable
                if any(~isfinite(record.timestampTags_s))
                    error('InterSatelliteTimeTransferObservationRecord:timestampTags', ...
                        'Available timestamp tags must be finite.');
                end
            elseif any(~isnan(record.timestampTags_s))
                error('InterSatelliteTimeTransferObservationRecord:timestampTags', ...
                    'Unavailable timestamp tags must be represented by NaN.');
            end
            covariance = record.covarianceBlock;
            if ~isnumeric(covariance) || isempty(covariance) || ...
                    size(covariance,1) ~= size(covariance,2) || ...
                    any(~isfinite(covariance),'all') || ...
                    norm(covariance-covariance','fro') > 1e-12 || ...
                    min(eig((covariance+covariance')/2)) < -1e-12
                error('InterSatelliteTimeTransferObservationRecord:covariance', ...
                    'covarianceBlock must be finite, symmetric, and positive semidefinite.');
            end
            rowIndex = record.covarianceRowIndex;
            if ~(isscalar(rowIndex) && rowIndex == round(rowIndex) && ...
                    rowIndex >= 1 && rowIndex <= size(covariance,1))
                error('InterSatelliteTimeTransferObservationRecord:covarianceRow', ...
                    'covarianceRowIndex must select a covariance row.');
            end
            calibrationIdentifiers = record.calibrationProductIdentifiers;
            if isstring(calibrationIdentifiers)
                calibrationIdentifiers = cellstr(calibrationIdentifiers);
            end
            if ~iscell(calibrationIdentifiers) || ...
                    any(~cellfun(@(value) ischar(value) || ...
                    (isstring(value) && isscalar(value)), ...
                    calibrationIdentifiers))
                error('InterSatelliteTimeTransferObservationRecord:calibration', ...
                    'Calibration product identifiers must be text.');
            end
            if ~(isnumeric(record.referenceLocalClockTag_s) && ...
                    isscalar(record.referenceLocalClockTag_s) && ...
                    isfinite(record.referenceLocalClockTag_s) && ...
                    isnumeric(record.calibrationValidFromLocalTag_s) && ...
                    isscalar(record.calibrationValidFromLocalTag_s) && ...
                    isfinite(record.calibrationValidFromLocalTag_s) && ...
                    isnumeric(record.calibrationValidUntilLocalTag_s) && ...
                    isscalar(record.calibrationValidUntilLocalTag_s) && ...
                    isfinite(record.calibrationValidUntilLocalTag_s) && ...
                    record.calibrationValidFromLocalTag_s <= record.calibrationValidUntilLocalTag_s)
                error('InterSatelliteTimeTransferObservationRecord:calibrationValidity', ...
                    ['referenceLocalClockTag_s and the calibration validity interval must be ' ...
                    'finite scalars with calibrationValidFromLocalTag_s <= ' ...
                    'calibrationValidUntilLocalTag_s.']);
            end
            if ~(islogical(record.reciprocityTermIncluded) && ...
                    isscalar(record.reciprocityTermIncluded))
                error('InterSatelliteTimeTransferObservationRecord:reciprocityTermIncluded', ...
                    'reciprocityTermIncluded must be a logical scalar.');
            end

            for fieldIndex = 1:numel(fields)
                fieldName = fields{fieldIndex};
                value = record.(fieldName);
                if ischar(obj.(fieldName))
                    value = char(value);
                end
                obj.(fieldName) = value;
            end
            obj.calibrationProductIdentifiers = ...
                cellfun(@char,calibrationIdentifiers,'UniformOutput',false);
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
