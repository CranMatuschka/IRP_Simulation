classdef OneWayInterSatelliteObservationRecord
    % OneWayInterSatelliteObservationRecord  Immutable processed one-way ISL observation (plan
    % Section 2.3 item 3). ONE record class for TWO observables (oneWayCodeRange in metres,
    % oneWayRangeRate in metres/second): both are processed products of one physical one-way
    % transmission, on one link, at one epoch, sharing every identity/terminal/timing/
    % calibration field, so a frozen two-entry processedObservableType<->units<->covarianceUnits
    % triple keeps the record class shared while the observable-level separation that matters
    % (owner, consumption, Jacobian, bound admission) is enforced where that machinery already
    % lives (revgnss.DistributedLinkUpdateAdapter's per-observable dispatch).
    %
    % Fields lightTimeCorrectionApplied/leverArmRateTermApplied/broadcastEphemerisProductApplied
    % are fail-closed model declarations (constructor-required false): a distributed adapter
    % cannot silently consume a record generated under a different physical kernel, and the
    % "no piecewise-constant broadcast-product error" claim (invariant 8) is carried by the
    % datum itself, not by a comment.

    properties (SetAccess = immutable)
        observationIdentifier (1,:) char
        sessionIdentifier (1,:) char
        linkIdentifier (1,:) char
        transmitterAssetIdentifier (1,:) char
        receiverAssetIdentifier (1,:) char
        transmitTerminalIdentifier (1,:) char
        receiveTerminalIdentifier (1,:) char
        transmitAntennaIdentifier (1,:) char
        receiveAntennaIdentifier (1,:) char
        protocolIdentifier (1,:) char
        signalIdentifier (1,:) char
        channelIdentifier (1,:) char
        sessionInitiatorRole (1,:) char
        carrierFrequency_Hz (1,1) double
        codeChipRate_Hz (1,1) double
        referenceLocalClockTag_s (1,1) double
        referenceEpoch_s (1,1) double
        referenceEpochRule (1,:) char
        processedObservableType (1,:) char
        processedValue (1,1) double
        processedUnits (1,:) char
        covarianceGroupIdentifier (1,:) char
        covarianceRowIndex (1,1) double
        covarianceBlock (:,:) double
        covarianceUnits (1,:) char
        calibrationProductIdentifiers (1,:) cell
        calibrationValidFromLocalTag_s (1,1) double
        calibrationValidUntilLocalTag_s (1,1) double
        transmitPhaseCentreOffset_body_m (3,1) double
        receivePhaseCentreOffset_body_m (3,1) double
        geometryKernelIdentifier (1,:) char
        lightTimeCorrectionApplied (1,1) logical
        leverArmRateTermApplied (1,1) logical
        broadcastEphemerisProductApplied (1,1) logical
        available (1,1) logical
        qualityFlags (1,1) struct
        truthDiagnosticIdentifier (1,:) char
    end

    methods
        function obj = OneWayInterSatelliteObservationRecord(record)
            arguments
                record (1,1) struct
            end
            fields = properties(obj);
            supplied = fieldnames(record);
            unknown = setdiff(supplied,fields);
            missing = setdiff(fields,supplied);
            if ~isempty(unknown)
                error('OneWayInterSatelliteObservationRecord:unknownField', ...
                    'Observation record contains unsupported field %s.',unknown{1});
            end
            if ~isempty(missing)
                error('OneWayInterSatelliteObservationRecord:missingField', ...
                    'Observation record is missing field %s.',missing{1});
            end

            if ~strcmp(char(record.transmitterAssetIdentifier),'') && ...
                    strcmp(char(record.transmitterAssetIdentifier),char(record.receiverAssetIdentifier))
                error('OneWayInterSatelliteObservationRecord:endpointsNotDistinct', ...
                    'transmitterAssetIdentifier and receiverAssetIdentifier must be distinct.');
            end
            if ~strcmp(char(record.protocolIdentifier),'oneWayBroadcastPnRanging')
                error('OneWayInterSatelliteObservationRecord:protocol', ...
                    'The protocol must be oneWayBroadcastPnRanging.');
            end
            if ~strcmp(char(record.sessionInitiatorRole),'receiver')
                error('OneWayInterSatelliteObservationRecord:sessionInitiatorRole', ...
                    'sessionInitiatorRole must be ''receiver'': the receiver forms this row against its own local clock.');
            end
            if ~strcmp(char(record.referenceEpochRule),'commonCoordinateEpoch')
                error('OneWayInterSatelliteObservationRecord:referenceEpoch', ...
                    'The one-way observable uses commonCoordinateEpoch.');
            end
            if ~strcmp(char(record.geometryKernelIdentifier), ...
                    revgnss.OneWayInterSatelliteRangingModel.GeometryKernelIdentifier)
                error('OneWayInterSatelliteObservationRecord:geometryKernel', ...
                    'geometryKernelIdentifier must match the frozen instantaneous-coordinate-epoch kernel.');
            end
            if record.lightTimeCorrectionApplied
                error('OneWayInterSatelliteObservationRecord:lightTimeCorrectionUnsupported', ...
                    'A light-time-corrected one-way observable is not supported by this record.');
            end
            if record.leverArmRateTermApplied
                error('OneWayInterSatelliteObservationRecord:leverArmRateTermUnsupported', ...
                    'A lever-arm-rate-corrected one-way observable is not supported by this record.');
            end
            if record.broadcastEphemerisProductApplied
                error('OneWayInterSatelliteObservationRecord:broadcastEphemerisProductApplied', ...
                    ['A broadcast-ephemeris-product-aided one-way observable is not supported by ' ...
                    'this record (invariant 8: no persistent/piecewise-constant product error may ' ...
                    'be represented on this path).']);
            end

            triples = { ...
                'oneWayCodeRange','m','m^2'; ...
                'oneWayRangeRate','m/s','m^2/s^2'};
            triplesMatch = strcmp(triples(:,1),char(record.processedObservableType)) & ...
                strcmp(triples(:,2),char(record.processedUnits));
            row = find(triplesMatch,1);
            if isempty(row)
                error('OneWayInterSatelliteObservationRecord:observable', ...
                    'processedObservableType/processedUnits must be a frozen (oneWayCodeRange,m) or (oneWayRangeRate,m/s) pair.');
            end
            expectedCovarianceUnits = triples{row,3};

            if ~(isnumeric(record.referenceEpoch_s) && isscalar(record.referenceEpoch_s) && ...
                    isfinite(record.referenceEpoch_s) && ...
                    isnumeric(record.processedValue) && isscalar(record.processedValue) && ...
                    isfinite(record.processedValue))
                error('OneWayInterSatelliteObservationRecord:value', ...
                    'Epoch and processed value must be finite scalars.');
            end
            if ~(isnan(record.carrierFrequency_Hz) || record.carrierFrequency_Hz > 0) || ...
                    ~(isnan(record.codeChipRate_Hz) || record.codeChipRate_Hz > 0)
                error('OneWayInterSatelliteObservationRecord:rfParameters', ...
                    'carrierFrequency_Hz and codeChipRate_Hz must each be positive or NaN.');
            end

            covariance = record.covarianceBlock;
            if ~isnumeric(covariance) || isempty(covariance) || ...
                    size(covariance,1) ~= size(covariance,2) || ...
                    any(~isfinite(covariance),'all') || ...
                    norm(covariance-covariance','fro') > 1e-12 || ...
                    min(eig((covariance+covariance')/2)) < -1e-12
                error('OneWayInterSatelliteObservationRecord:covariance', ...
                    'covarianceBlock must be finite, symmetric, and positive semidefinite.');
            end
            rowIndex = record.covarianceRowIndex;
            if ~(isscalar(rowIndex) && rowIndex == round(rowIndex) && ...
                    rowIndex >= 1 && rowIndex <= size(covariance,1))
                error('OneWayInterSatelliteObservationRecord:covarianceRow', ...
                    'covarianceRowIndex must select a covariance row.');
            end
            if ~strcmp(char(record.covarianceUnits),expectedCovarianceUnits)
                error('OneWayInterSatelliteObservationRecord:covarianceUnits', ...
                    'covarianceUnits must match the frozen triple for this processedObservableType.');
            end
            if ~strcmp(char(record.covarianceGroupIdentifier),char(record.observationIdentifier))
                error('OneWayInterSatelliteObservationRecord:covarianceGroup', ...
                    'covarianceGroupIdentifier must equal observationIdentifier (no shared-covariance treatment exists).');
            end

            calibrationIdentifiers = record.calibrationProductIdentifiers;
            if isstring(calibrationIdentifiers)
                calibrationIdentifiers = cellstr(calibrationIdentifiers);
            end
            if ~iscell(calibrationIdentifiers) || isempty(calibrationIdentifiers) || ...
                    any(~cellfun(@(value) ischar(value) || ...
                    (isstring(value) && isscalar(value)), ...
                    calibrationIdentifiers))
                error('OneWayInterSatelliteObservationRecord:calibration', ...
                    'calibrationProductIdentifiers must be a nonempty cell array of text.');
            end
            if ~(isnumeric(record.calibrationValidFromLocalTag_s) && ...
                    isscalar(record.calibrationValidFromLocalTag_s) && ...
                    isfinite(record.calibrationValidFromLocalTag_s) && ...
                    isnumeric(record.calibrationValidUntilLocalTag_s) && ...
                    isscalar(record.calibrationValidUntilLocalTag_s) && ...
                    isfinite(record.calibrationValidUntilLocalTag_s) && ...
                    record.calibrationValidFromLocalTag_s <= record.calibrationValidUntilLocalTag_s && ...
                    isnumeric(record.referenceLocalClockTag_s) && ...
                    isscalar(record.referenceLocalClockTag_s) && ...
                    isfinite(record.referenceLocalClockTag_s) && ...
                    record.referenceLocalClockTag_s >= record.calibrationValidFromLocalTag_s && ...
                    record.referenceLocalClockTag_s <= record.calibrationValidUntilLocalTag_s)
                error('OneWayInterSatelliteObservationRecord:calibrationValidity', ...
                    ['referenceLocalClockTag_s and the calibration validity interval must be finite ' ...
                    'scalars, with calibrationValidFromLocalTag_s <= calibrationValidUntilLocalTag_s ' ...
                    'and referenceLocalClockTag_s inside that interval.']);
            end

            if ~isnumeric(record.transmitPhaseCentreOffset_body_m) || ...
                    ~isequal(size(record.transmitPhaseCentreOffset_body_m(:)),[3 1]) || ...
                    any(~isfinite(record.transmitPhaseCentreOffset_body_m(:))) || ...
                    ~isnumeric(record.receivePhaseCentreOffset_body_m) || ...
                    ~isequal(size(record.receivePhaseCentreOffset_body_m(:)),[3 1]) || ...
                    any(~isfinite(record.receivePhaseCentreOffset_body_m(:)))
                error('OneWayInterSatelliteObservationRecord:phaseCentre', ...
                    'transmit/receivePhaseCentreOffset_body_m must be finite 3-by-1 vectors.');
            end

            for fieldIndex = 1:numel(fields)
                fieldName = fields{fieldIndex};
                value = record.(fieldName);
                if ischar(obj.(fieldName))
                    value = char(value);
                elseif isnumeric(obj.(fieldName)) && numel(obj.(fieldName)) == 3
                    value = value(:);
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
