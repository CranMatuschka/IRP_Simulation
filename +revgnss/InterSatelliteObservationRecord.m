classdef InterSatelliteObservationRecord
    % InterSatelliteObservationRecord  Immutable estimator-facing ISL datum.

    properties (SetAccess = immutable)
        observationIdentifier (1,:) char
        sessionIdentifier (1,:) char
        initiatorAssetIdentifier (1,:) char
        transponderAssetIdentifier (1,:) char
        initiatorTransmitTerminalIdentifier (1,:) char
        initiatorReceiveTerminalIdentifier (1,:) char
        transponderReceiveTerminalIdentifier (1,:) char
        transponderTransmitTerminalIdentifier (1,:) char
        initiatorTransmitAntennaIdentifier (1,:) char
        initiatorReceiveAntennaIdentifier (1,:) char
        transponderReceiveAntennaIdentifier (1,:) char
        transponderTransmitAntennaIdentifier (1,:) char
        protocolIdentifier (1,:) char
        signalIdentifier (1,:) char
        channelIdentifier (1,:) char
        forwardCarrierFrequency_Hz (1,1) double
        returnCarrierFrequency_Hz (1,1) double
        codeChipRate_Hz (1,1) double
        initiatorTransmitLocalClockTag_s (1,1) double
        initiatorReceiveLocalClockTag_s (1,1) double
        measuredLocalRoundTripDelay_s (1,1) double
        referenceLocalClockTag_s (1,1) double
        referenceEpochRule (1,:) char
        localTimeSystemIdentifier (1,:) char
        timestampReferencePointIdentifier (1,:) char
        commandedScheduleIdentifier (1,:) char
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
        carrierToNoiseDensity_dBHz (1,1) double
        effectiveRangingBandwidth_Hz (1,1) double
        roundTripLinkMargin_dB (1,1) double
        available (1,1) logical
        qualityFlags (1,1) struct
        truthDiagnosticIdentifier (1,:) char
    end

    methods
        function obj = InterSatelliteObservationRecord(record)
            arguments
                record (1,1) struct
            end

            allowed = { ...
                'observationIdentifier','sessionIdentifier', ...
                'initiatorAssetIdentifier','transponderAssetIdentifier', ...
                'initiatorTransmitTerminalIdentifier','initiatorReceiveTerminalIdentifier', ...
                'transponderReceiveTerminalIdentifier','transponderTransmitTerminalIdentifier', ...
                'initiatorTransmitAntennaIdentifier','initiatorReceiveAntennaIdentifier', ...
                'transponderReceiveAntennaIdentifier','transponderTransmitAntennaIdentifier', ...
                'protocolIdentifier','signalIdentifier','channelIdentifier', ...
                'forwardCarrierFrequency_Hz','returnCarrierFrequency_Hz', ...
                'codeChipRate_Hz', ...
                'initiatorTransmitLocalClockTag_s','initiatorReceiveLocalClockTag_s', ...
                'measuredLocalRoundTripDelay_s','referenceLocalClockTag_s','referenceEpochRule', ...
                'localTimeSystemIdentifier','timestampReferencePointIdentifier', ...
                'commandedScheduleIdentifier', ...
                'processedObservableType','processedValue','processedUnits', ...
                'covarianceGroupIdentifier','covarianceRowIndex','covarianceBlock', ...
                'covarianceUnits','calibrationProductIdentifiers', ...
                'calibrationValidFromLocalTag_s','calibrationValidUntilLocalTag_s', ...
                'carrierToNoiseDensity_dBHz','effectiveRangingBandwidth_Hz', ...
                'roundTripLinkMargin_dB','available','qualityFlags', ...
                'truthDiagnosticIdentifier'};
            supplied = fieldnames(record);
            unknown = setdiff(supplied, allowed);
            missing = setdiff(allowed, supplied);
            if ~isempty(unknown)
                error('InterSatelliteObservationRecord:unknownField', ...
                    'Observation record contains unsupported field %s.', unknown{1});
            end
            if ~isempty(missing)
                error('InterSatelliteObservationRecord:missingField', ...
                    'Observation record is missing field %s.', missing{1});
            end

            covariance = record.covarianceBlock;
            if ~isnumeric(covariance) || isempty(covariance) || ...
                    size(covariance,1) ~= size(covariance,2) || ...
                    any(~isfinite(covariance), 'all') || ...
                    norm(covariance - covariance', 'fro') > 1e-12 || ...
                    min(eig((covariance + covariance') / 2)) < -1e-12
                error('InterSatelliteObservationRecord:covariance', ...
                    'covarianceBlock must be finite, symmetric, and positive semidefinite.');
            end
            rowIndex = record.covarianceRowIndex;
            if ~(isscalar(rowIndex) && rowIndex == round(rowIndex) && ...
                    rowIndex >= 1 && rowIndex <= size(covariance,1))
                error('InterSatelliteObservationRecord:covarianceRow', ...
                    'covarianceRowIndex must select a row of covarianceBlock.');
            end
            if ~strcmp(char(record.referenceEpochRule), 'finalReception')
                error('InterSatelliteObservationRecord:referenceEpoch', ...
                    'Coherent two-way code observations use finalReception as their reference epoch.');
            end
            if ~strcmp(char(record.processedObservableType), 'twoWayCodeRange') || ...
                    ~strcmp(char(record.processedUnits), 'm')
                error('InterSatelliteObservationRecord:observable', ...
                    'This record must carry a twoWayCodeRange observable in metres.');
            end
            calibrationIds = record.calibrationProductIdentifiers;
            if isstring(calibrationIds)
                calibrationIds = cellstr(calibrationIds);
            end
            if ~iscell(calibrationIds) || any(~cellfun(@(x) ischar(x) || ...
                    (isstring(x) && isscalar(x)), calibrationIds))
                error('InterSatelliteObservationRecord:calibrationIdentifiers', ...
                    'calibrationProductIdentifiers must be a cell array of text identifiers.');
            end

            obj.observationIdentifier = char(record.observationIdentifier);
            obj.sessionIdentifier = char(record.sessionIdentifier);
            obj.initiatorAssetIdentifier = char(record.initiatorAssetIdentifier);
            obj.transponderAssetIdentifier = char(record.transponderAssetIdentifier);
            obj.initiatorTransmitTerminalIdentifier = char(record.initiatorTransmitTerminalIdentifier);
            obj.initiatorReceiveTerminalIdentifier = char(record.initiatorReceiveTerminalIdentifier);
            obj.transponderReceiveTerminalIdentifier = char(record.transponderReceiveTerminalIdentifier);
            obj.transponderTransmitTerminalIdentifier = char(record.transponderTransmitTerminalIdentifier);
            obj.initiatorTransmitAntennaIdentifier = char(record.initiatorTransmitAntennaIdentifier);
            obj.initiatorReceiveAntennaIdentifier = char(record.initiatorReceiveAntennaIdentifier);
            obj.transponderReceiveAntennaIdentifier = char(record.transponderReceiveAntennaIdentifier);
            obj.transponderTransmitAntennaIdentifier = char(record.transponderTransmitAntennaIdentifier);
            obj.protocolIdentifier = char(record.protocolIdentifier);
            obj.signalIdentifier = char(record.signalIdentifier);
            obj.channelIdentifier = char(record.channelIdentifier);
            obj.forwardCarrierFrequency_Hz = record.forwardCarrierFrequency_Hz;
            obj.returnCarrierFrequency_Hz = record.returnCarrierFrequency_Hz;
            obj.codeChipRate_Hz = record.codeChipRate_Hz;
            obj.initiatorTransmitLocalClockTag_s = record.initiatorTransmitLocalClockTag_s;
            obj.initiatorReceiveLocalClockTag_s = record.initiatorReceiveLocalClockTag_s;
            obj.measuredLocalRoundTripDelay_s = record.measuredLocalRoundTripDelay_s;
            obj.referenceLocalClockTag_s = record.referenceLocalClockTag_s;
            obj.referenceEpochRule = char(record.referenceEpochRule);
            obj.localTimeSystemIdentifier = char(record.localTimeSystemIdentifier);
            obj.timestampReferencePointIdentifier = ...
                char(record.timestampReferencePointIdentifier);
            obj.commandedScheduleIdentifier = ...
                char(record.commandedScheduleIdentifier);
            obj.processedObservableType = char(record.processedObservableType);
            obj.processedValue = record.processedValue;
            obj.processedUnits = char(record.processedUnits);
            obj.covarianceGroupIdentifier = char(record.covarianceGroupIdentifier);
            obj.covarianceRowIndex = rowIndex;
            obj.covarianceBlock = covariance;
            obj.covarianceUnits = char(record.covarianceUnits);
            obj.calibrationProductIdentifiers = cellfun(@char, calibrationIds, 'UniformOutput', false);
            obj.calibrationValidFromLocalTag_s = ...
                record.calibrationValidFromLocalTag_s;
            obj.calibrationValidUntilLocalTag_s = ...
                record.calibrationValidUntilLocalTag_s;
            obj.carrierToNoiseDensity_dBHz = record.carrierToNoiseDensity_dBHz;
            obj.effectiveRangingBandwidth_Hz = record.effectiveRangingBandwidth_Hz;
            obj.roundTripLinkMargin_dB = record.roundTripLinkMargin_dB;
            obj.available = logical(record.available);
            obj.qualityFlags = record.qualityFlags;
            obj.truthDiagnosticIdentifier = char(record.truthDiagnosticIdentifier);

            obj.validateFiniteScalars_();
        end

        function record = toStruct(obj)
            names = properties(obj);
            record = struct();
            for fieldIdx = 1:numel(names)
                record.(names{fieldIdx}) = obj.(names{fieldIdx});
            end
        end
    end

    methods (Access = private)
        function validateFiniteScalars_(obj)
            values = [obj.initiatorTransmitLocalClockTag_s, ...
                obj.initiatorReceiveLocalClockTag_s, obj.measuredLocalRoundTripDelay_s, ...
                obj.referenceLocalClockTag_s, obj.processedValue];
            if any(~isfinite(values))
                error('InterSatelliteObservationRecord:numericValue', ...
                    'Observation timing and processed values must be finite.');
            end
            if obj.measuredLocalRoundTripDelay_s < 0
                error('InterSatelliteObservationRecord:roundTripDelay', ...
                    'Measured round-trip delay must be nonnegative.');
            end
            if obj.referenceLocalClockTag_s ~= obj.initiatorReceiveLocalClockTag_s
                error('InterSatelliteObservationRecord:referenceTag', ...
                    'The final-reception reference tag must equal the receive clock tag.');
            end
            if obj.calibrationValidUntilLocalTag_s < ...
                    obj.calibrationValidFromLocalTag_s
                error('InterSatelliteObservationRecord:calibrationValidity', ...
                    'The calibration validity interval is reversed.');
            end
            if obj.referenceLocalClockTag_s < obj.calibrationValidFromLocalTag_s || ...
                    obj.referenceLocalClockTag_s > obj.calibrationValidUntilLocalTag_s
                error('InterSatelliteObservationRecord:calibrationValidity', ...
                    'The observation reference tag is outside the calibration validity interval.');
            end
            if ~(isnan(obj.carrierToNoiseDensity_dBHz) || ...
                    isfinite(obj.carrierToNoiseDensity_dBHz))
                error('InterSatelliteObservationRecord:carrierToNoiseDensity', ...
                    'carrierToNoiseDensity_dBHz must be finite or NaN when unavailable.');
            end
            if ~(isnan(obj.effectiveRangingBandwidth_Hz) || ...
                    (isfinite(obj.effectiveRangingBandwidth_Hz) && ...
                    obj.effectiveRangingBandwidth_Hz > 0))
                error('InterSatelliteObservationRecord:rangingBandwidth', ...
                    'effectiveRangingBandwidth_Hz must be positive or NaN when unavailable.');
            end
            if ~(isnan(obj.roundTripLinkMargin_dB) || ...
                    isfinite(obj.roundTripLinkMargin_dB))
                error('InterSatelliteObservationRecord:linkMargin', ...
                    'roundTripLinkMargin_dB must be finite or NaN when unavailable.');
            end
            signalValues = [obj.forwardCarrierFrequency_Hz, ...
                obj.returnCarrierFrequency_Hz,obj.codeChipRate_Hz];
            if any(~isnan(signalValues) & ...
                    (~isfinite(signalValues) | signalValues <= 0))
                error('InterSatelliteObservationRecord:signalParameters', ...
                    'Signal frequencies and chip rate must be positive or NaN when unavailable.');
            end
        end
    end
end
