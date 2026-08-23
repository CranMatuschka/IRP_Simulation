function test_inter_satellite_four_timestamp_observation_record()
% test_inter_satellite_four_timestamp_observation_record  Plan Section 4.4, Stage-4 named test.
% revgnss.InterSatelliteFourTimestampObservationRecord -- the immutable processed ISL
% four-timestamp clock datum. Unlike revgnss.InterSatelliteTimeTransferObservationRecord, this
% record: (a) is NEVER validated via revgnss.ReciprocalTimeTransferModel.validateMode,
% (b) always has rawTimestampTagsAvailable=true (inverse convention), (c) always has
% reciprocityTermIncluded=false, (d) carries a full tx/rx terminal+antenna quadruple per side.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
addpath(rootDir);

fprintf('=== test_inter_satellite_four_timestamp_observation_record ===\n');
i_test_valid_construction_and_toStruct_roundtrip_();
i_test_rejects_unknown_field_();
i_test_rejects_missing_field_();
i_test_rejects_wrong_protocol_();
i_test_rejects_wrong_mode_();
i_test_rejects_wrong_referenceEpochRule_();
i_test_rejects_wrong_processedObservableType_or_units_();
i_test_rejects_nonfinite_epoch_or_value_();
i_test_rejects_rawTimestampTagsAvailable_false_();
i_test_rejects_nonmonotonic_timestampTags_();
i_test_rejects_asymmetric_covariance_();
i_test_rejects_indefinite_covariance_();
i_test_rejects_out_of_range_covarianceRowIndex_();
i_test_rejects_nontext_calibrationProductIdentifiers_();
i_test_rejects_inverted_calibration_validity_();
i_test_rejects_reciprocityTermIncluded_true_();
fprintf('=== test_inter_satellite_four_timestamp_observation_record: ALL PASS ===\n');
end

% ================================================================================================
function i_test_valid_construction_and_toStruct_roundtrip_()
record = i_validRecordFields_();
obs = revgnss.InterSatelliteFourTimestampObservationRecord(record);
s = obs.toStruct();
assert(strcmp(s.observationIdentifier,'obs:1'));
assert(strcmp(s.protocolIdentifier,'directFourTimestampTwoWay'));
assert(strcmp(s.modeIdentifier,'fourTimestampClockDifference'));
assert(s.rawTimestampTagsAvailable==true);
assert(s.reciprocityTermIncluded==false);
assert(isequal(s.timestampTags_s,[1 2 3 10]));
% Reconstructing from the round-tripped struct must succeed and be equal.
obs2 = revgnss.InterSatelliteFourTimestampObservationRecord(s);
assert(isequal(obs2.toStruct(),s));
fprintf('  PASS valid construction + toStruct roundtrip is stable under reconstruction\n');
end

% ================================================================================================
function i_test_rejects_unknown_field_()
record = i_validRecordFields_();
record.notARealField = 1; %#ok<STRNU>
i_expectError_(record,'InterSatelliteFourTimestampObservationRecord:unknownField', ...
    'an unknown field');
end

% ================================================================================================
function i_test_rejects_missing_field_()
record = i_validRecordFields_();
record = rmfield(record,'channelIdentifier');
i_expectError_(record,'InterSatelliteFourTimestampObservationRecord:missingField', ...
    'a missing required field');
end

% ================================================================================================
function i_test_rejects_wrong_protocol_()
record = i_validRecordFields_();
record.protocolIdentifier = 'reciprocalTwoWayTimeTransfer';
i_expectError_(record,'InterSatelliteFourTimestampObservationRecord:protocol', ...
    'the first-order protocol string');
end

% ================================================================================================
function i_test_rejects_wrong_mode_()
record = i_validRecordFields_();
record.modeIdentifier = 'fourTimestampPhysical';
i_expectError_(record,'InterSatelliteFourTimestampObservationRecord:mode', ...
    'the reserved-but-unimplemented fourTimestampPhysical mode string');
end

% ================================================================================================
function i_test_rejects_wrong_referenceEpochRule_()
record = i_validRecordFields_();
record.referenceEpochRule = 'commonCoordinateEpoch';
i_expectError_(record,'InterSatelliteFourTimestampObservationRecord:referenceEpoch', ...
    'the first-order-only epoch rule');
end

% ================================================================================================
function i_test_rejects_wrong_processedObservableType_or_units_()
record = i_validRecordFields_();
record.processedUnits = 's';
i_expectError_(record,'InterSatelliteFourTimestampObservationRecord:observable', ...
    'non-metre processedUnits');
end

% ================================================================================================
function i_test_rejects_nonfinite_epoch_or_value_()
record = i_validRecordFields_();
record.processedValue = NaN;
i_expectError_(record,'InterSatelliteFourTimestampObservationRecord:value', ...
    'a non-finite processedValue');
end

% ================================================================================================
function i_test_rejects_rawTimestampTagsAvailable_false_()
record = i_validRecordFields_();
record.rawTimestampTagsAvailable = false;
i_expectError_(record,'InterSatelliteFourTimestampObservationRecord:rawTimestampTagsAvailable', ...
    'rawTimestampTagsAvailable=false (this observable requires raw tags)');
end

% ================================================================================================
function i_test_rejects_nonmonotonic_timestampTags_()
record = i_validRecordFields_();
record.timestampTags_s = [1 5 3 10];
i_expectError_(record,'InterSatelliteFourTimestampObservationRecord:timestampTags', ...
    'non-time-ordered timestampTags_s');
end

% ================================================================================================
function i_test_rejects_asymmetric_covariance_()
record = i_validRecordFields_();
record.covarianceBlock = [0.02 0.01; 0.03 0.02];
record.covarianceRowIndex = 1;
i_expectError_(record,'InterSatelliteFourTimestampObservationRecord:covariance', ...
    'an asymmetric covarianceBlock');
end

% ================================================================================================
function i_test_rejects_indefinite_covariance_()
record = i_validRecordFields_();
record.covarianceBlock = [1 2; 2 1];
record.covarianceRowIndex = 1;
i_expectError_(record,'InterSatelliteFourTimestampObservationRecord:covariance', ...
    'an indefinite covarianceBlock');
end

% ================================================================================================
function i_test_rejects_out_of_range_covarianceRowIndex_()
record = i_validRecordFields_();
record.covarianceRowIndex = 2;
i_expectError_(record,'InterSatelliteFourTimestampObservationRecord:covarianceRow', ...
    'a covarianceRowIndex outside the covarianceBlock');
end

% ================================================================================================
function i_test_rejects_nontext_calibrationProductIdentifiers_()
record = i_validRecordFields_();
record.calibrationProductIdentifiers = {1};
i_expectError_(record,'InterSatelliteFourTimestampObservationRecord:calibration', ...
    'a non-text calibrationProductIdentifiers entry');
end

% ================================================================================================
function i_test_rejects_inverted_calibration_validity_()
record = i_validRecordFields_();
record.calibrationValidFromLocalTag_s = 20;
record.calibrationValidUntilLocalTag_s = 10;
i_expectError_(record,'InterSatelliteFourTimestampObservationRecord:calibrationValidity', ...
    'calibrationValidFromLocalTag_s > calibrationValidUntilLocalTag_s');
end

% ================================================================================================
function i_test_rejects_reciprocityTermIncluded_true_()
record = i_validRecordFields_();
record.reciprocityTermIncluded = true;
i_expectError_(record,'InterSatelliteFourTimestampObservationRecord:reciprocityTermIncluded', ...
    'reciprocityTermIncluded=true (this observable has no reciprocity term)');
end

% ================================================================================================
function i_expectError_(record, expectedIdentifier, label)
threw = false;
try
    revgnss.InterSatelliteFourTimestampObservationRecord(record);
catch ME
    threw = strcmp(ME.identifier,expectedIdentifier);
    assert(threw,'FAIL: expected identifier %s for %s, got %s (%s).', ...
        expectedIdentifier,label,ME.identifier,ME.message);
end
assert(threw,'FAIL: construction must reject %s.',label);
fprintf('  PASS rejects %s (%s)\n',label,expectedIdentifier);
end

% ================================================================================================
function record = i_validRecordFields_()
record = struct( ...
    'observationIdentifier','obs:1','sessionIdentifier','sess:1','linkIdentifier','link:1', ...
    'referenceAssetIdentifier','asset:1','remoteAssetIdentifier','asset:2', ...
    'referenceTransmitTerminalIdentifier','a','referenceReceiveTerminalIdentifier','b', ...
    'referenceTransmitAntennaIdentifier','c','referenceReceiveAntennaIdentifier','d', ...
    'remoteTransmitTerminalIdentifier','e','remoteReceiveTerminalIdentifier','f', ...
    'remoteTransmitAntennaIdentifier','g','remoteReceiveAntennaIdentifier','h', ...
    'protocolIdentifier','directFourTimestampTwoWay','modeIdentifier','fourTimestampClockDifference', ...
    'signalIdentifier','sig','channelIdentifier','chan','referenceEpoch_s',10, ...
    'referenceEpochRule','finalReception','rawTimestampTagsAvailable',true, ...
    'timestampTags_s',[1 2 3 10],'processedObservableType','fourTimestampClockDifference', ...
    'processedValue',5.0,'processedUnits','m','covarianceGroupIdentifier','cg:1', ...
    'covarianceRowIndex',1,'covarianceBlock',0.01,'covarianceUnits','m^2', ...
    'calibrationProductIdentifiers',{{}},'available',true,'qualityFlags',struct(), ...
    'truthDiagnosticIdentifier','','referenceLocalClockTag_s',10, ...
    'calibrationValidFromLocalTag_s',10,'calibrationValidUntilLocalTag_s',10, ...
    'reciprocityTermIncluded',false);
end
