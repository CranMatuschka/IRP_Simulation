function test_four_timestamp_processed_observable_from_record()
% test_four_timestamp_processed_observable_from_record  Plan Section 4.3, Stage-4 test coverage.
% revgnss.FourTimestampObservableBuilder.fromExchangeRecord and
% revgnss.FourTimestampClockDifferenceObservable (item 5's one processed observable, built from a
% FINISHED, already-solved revgnss.ReciprocalTimestampExchangeRecord -- no re-solve) had ZERO test
% coverage prior to this file (Stage 4.3 combined review finding 5). Also covers the self-link and
% calibration-validity guards added to revgnss.FourTimestampObservableBuilder.
% predictFromEndpointModels itself during the Stage 4.3 review fix pass (findings 6 and 7).

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
addpath(rootDir);

fprintf('=== test_four_timestamp_processed_observable_from_record ===\n');
i_test_happy_path_matches_closed_form_and_roundtrips_via_toStruct_();
i_test_unavailable_record_rejected_();
i_test_incomplete_local_tags_rejected_();
i_test_wrong_topology_kind_rejected_();
i_test_wrong_reference_epoch_rule_rejected_();
i_test_hardware_validity_window_rejected_();
i_test_predict_from_endpoint_models_self_link_rejected_();
i_test_predict_from_endpoint_models_expired_calibration_rejected_();
fprintf('=== test_four_timestamp_processed_observable_from_record: ALL PASS ===\n');
end

% ================================================================================================
function i_test_happy_path_matches_closed_form_and_roundtrips_via_toStruct_()
c = revgnss.Constants.SPEED_OF_LIGHT_MPS;
record = i_validRecordTemplate_();
rec = revgnss.ReciprocalTimestampExchangeRecord(record);
hardware = revgnss.ReciprocalLinkHardwareModel('parameterSource','calibrationProduct', ...
    'physicalChainIdentifier','chain:from-record-test','calibrationProductIdentifier','cal:001', ...
    'turnaroundProperTime_s',1e-3,'originTerminalGroupDelay_s',2e-7,'anchorTerminalGroupDelay_s',3e-7);

observable = revgnss.FourTimestampObservableBuilder.fromExchangeRecord(rec, hardware);
assert(isa(observable,'revgnss.FourTimestampClockDifferenceObservable'));

% record.localClockTags_s = [1 2 3 10] (i_validRecordTemplate_'s own fixed tags); receiveEvent
% allocation (default): correctedTags = tags + [0, anchorDelay, 0, originDelay].
originDelay_s = hardware.originTerminalGroupDelay_s;
anchorDelay_s = hardware.anchorTerminalGroupDelay_s;
tags_s = record.localClockTags_s + [0, anchorDelay_s, 0, originDelay_s];
expectedValue_s = 0.5*((tags_s(2)-tags_s(1))-(tags_s(4)-tags_s(3)));
expectedOriginRoundTrip_s = tags_s(4)-tags_s(1);
expectedAnchorTurnaround_s = tags_s(3)-tags_s(2);

assert(abs(observable.clockDifferenceValue_s-expectedValue_s) < 1e-15, ...
    'FAIL: clockDifferenceValue_s must match the closed-form reduceClockDifference_ formula exactly.');
assert(abs(observable.clockDifferenceValue_m-c*expectedValue_s) < 1e-9, ...
    'FAIL: clockDifferenceValue_m must equal c*clockDifferenceValue_s.');
assert(abs(observable.originRoundTripLocalDelay_s-expectedOriginRoundTrip_s) < 1e-15 && ...
    abs(observable.anchorTurnaroundLocalDelay_s-expectedAnchorTurnaround_s) < 1e-15, ...
    'FAIL: diagnostic delays must match the closed-form t4-t1/t3-t2 formulas.');
assert(strcmp(observable.topologyKind,'directRoundTrip') && ...
    strcmp(observable.terminalDelayAllocation,'receiveEvent') && ...
    strcmp(observable.referenceEndpointIdentifier,'A') && ...
    strcmp(observable.remoteEndpointIdentifier,'B') && ...
    observable.availability==true && ~observable.clockDifferenceVarianceDeclared && ...
    isnan(observable.clockDifferenceVariance_m2), ...
    'FAIL: pass-through record fields must be carried onto the observable exactly.');

s = observable.toStruct();
assert(strcmp(s.sourceExchangeIdentifier,'exch:1') && ...
    abs(s.clockDifferenceValue_s-expectedValue_s) < 1e-15, ...
    'FAIL: toStruct() must round-trip the computed fields exactly.');
fprintf('  PASS fromExchangeRecord matches the closed-form reduction and toStruct() round-trips exactly\n');
end

% ================================================================================================
function i_test_unavailable_record_rejected_()
record = i_validRecordTemplate_();
record.availability = false;
rec = revgnss.ReciprocalTimestampExchangeRecord(record);
hardware = i_defaultHardware_();
threw = false;
try
    revgnss.FourTimestampObservableBuilder.fromExchangeRecord(rec, hardware);
catch ME
    threw = strcmp(ME.identifier,'FourTimestampObservableBuilder:recordUnavailable');
end
assert(threw, 'FAIL: an unavailable record must be rejected, never silently substituted.');
fprintf('  PASS unavailable record rejected\n');
end

% ================================================================================================
function i_test_incomplete_local_tags_rejected_()
record = i_validRecordTemplate_();
record.localClockTagAvailable = [true true true false];
record.localClockTags_s(4) = NaN;
rec = revgnss.ReciprocalTimestampExchangeRecord(record);
hardware = i_defaultHardware_();
threw = false;
try
    revgnss.FourTimestampObservableBuilder.fromExchangeRecord(rec, hardware);
catch ME
    threw = strcmp(ME.identifier,'FourTimestampObservableBuilder:incompleteLocalTags');
end
assert(threw, 'FAIL: a record missing any of the 4 local clock tags must be rejected.');
fprintf('  PASS incomplete local clock tags rejected\n');
end

% ================================================================================================
function i_test_wrong_topology_kind_rejected_()
record = i_validRecordTemplate_();
record.topologyKind = 'relayTransit';
record.chainEndpointIdentifiers = {'asset:1','relay:1','relay:1','asset:2'};
record.chainTerminalIdentifiers = {'term:a','term:r1','term:r2','term:b'};
record.localClockCompareEndpointIdentifiers = {'asset:1','asset:2'};
record.localTimeSystemIdentifiers = {'asset:1','relay:1','relay:1','asset:2'};
rec = revgnss.ReciprocalTimestampExchangeRecord(record);
hardware = i_defaultHardware_();
threw = false;
try
    revgnss.FourTimestampObservableBuilder.fromExchangeRecord(rec, hardware);
catch ME
    threw = strcmp(ME.identifier,'FourTimestampObservableBuilder:relayTopologyUnsupported');
end
assert(threw, 'FAIL: relayTransit records must be rejected this stage (Section 4.5 scope).');
fprintf('  PASS relayTransit topology rejected (Section 4.5 scope, not this stage)\n');
end

% ================================================================================================
function i_test_wrong_reference_epoch_rule_rejected_()
record = i_validRecordTemplate_();
record.referenceEpochRule = 'commonCoordinateEpoch'; % the OTHER frozen-allowed rule -- not
                                                       % finalReception, so fromExchangeRecord
                                                       % must reject it (only finalReception is
                                                       % verified for this reduction, this stage).
rec = revgnss.ReciprocalTimestampExchangeRecord(record);
hardware = i_defaultHardware_();
threw = false;
try
    revgnss.FourTimestampObservableBuilder.fromExchangeRecord(rec, hardware);
catch ME
    threw = strcmp(ME.identifier,'FourTimestampObservableBuilder:referenceEpochRule');
end
assert(threw, 'FAIL: a non-finalReception referenceEpochRule must be rejected this stage.');
fprintf('  PASS non-finalReception referenceEpochRule rejected\n');
end

% ================================================================================================
function i_test_hardware_validity_window_rejected_()
record = i_validRecordTemplate_(); % localClockTags_s(4)=10
rec = revgnss.ReciprocalTimestampExchangeRecord(record);
hardware = revgnss.ReciprocalLinkHardwareModel('parameterSource','calibrationProduct', ...
    'physicalChainIdentifier','chain:validity-test','calibrationProductIdentifier','cal:001', ...
    'turnaroundProperTime_s',1e-3,'validFromLocalTag_s',20,'validUntilLocalTag_s',30);
threw = false;
try
    revgnss.FourTimestampObservableBuilder.fromExchangeRecord(rec, hardware);
catch ME
    threw = strcmp(ME.identifier,'ReciprocalLinkHardwareModel:outsideValidity');
end
assert(threw, 'FAIL: a calibration product not valid at the final-reception local tag must be rejected.');
fprintf('  PASS expired/not-yet-valid calibration product rejected by fromExchangeRecord\n');
end

% ================================================================================================
function i_test_predict_from_endpoint_models_self_link_rejected_()
% Stage 4.3 combined review finding 6: predictFromEndpointModels' estimatorState branch had no
% self-link guard at all prior to this fix (unlike the physicalTruth branch, protected internally
% by revgnss.ReciprocalTimestampEventModel.solveDirectRoundTrip's own check) -- fixed by adding one
% shared guard covering both branches.
A = revgnss.TwoWayCodeEndpointModel.constantVelocity('estimatorState','same-asset', ...
    [7000e3;0;0],zeros(3,1),0);
Aagain = revgnss.TwoWayCodeEndpointModel.constantVelocity('estimatorState','same-asset', ...
    [7000e3;1;0],zeros(3,1),0); % same assetIdentifier, different position -- still a self-link
hardware = revgnss.ReciprocalLinkHardwareModel('parameterSource','calibrationProduct', ...
    'physicalChainIdentifier','chain:self-link-test','calibrationProductIdentifier','', ...
    'turnaroundProperTime_s',1e-3);
threw = false;
try
    revgnss.FourTimestampObservableBuilder.predictFromEndpointModels(A,Aagain,hardware,10);
catch ME
    threw = strcmp(ME.identifier,'FourTimestampObservableBuilder:selfLink');
end
assert(threw, 'FAIL: identical origin/destination assetIdentifier must be rejected for estimatorState endpoints too.');
fprintf('  PASS predictFromEndpointModels rejects a self-link on the estimatorState branch\n');
end

% ================================================================================================
function i_test_predict_from_endpoint_models_expired_calibration_rejected_()
% Stage 4.3 combined review finding 7: predictFromEndpointModels never called hardware.
% assertValidAt at all prior to this fix (unlike fromExchangeRecord, which already did) -- an
% expired-validity-window calibration product was silently accepted.
A = revgnss.TwoWayCodeEndpointModel.constantVelocity('estimatorState','A',[7000e3;0;0],zeros(3,1),0);
B = revgnss.TwoWayCodeEndpointModel.constantVelocity('estimatorState','B',[7000e3;500e3;0],zeros(3,1),0);
hardware = revgnss.ReciprocalLinkHardwareModel('parameterSource','calibrationProduct', ...
    'physicalChainIdentifier','chain:expired-cal-test','calibrationProductIdentifier','cal:001', ...
    'turnaroundProperTime_s',1e-3,'validFromLocalTag_s',-1e6,'validUntilLocalTag_s',-1);
threw = false;
try
    revgnss.FourTimestampObservableBuilder.predictFromEndpointModels(A,B,hardware,10);
catch ME
    threw = strcmp(ME.identifier,'ReciprocalLinkHardwareModel:outsideValidity');
end
assert(threw, 'FAIL: a calibration product expired before the final-reception tag must be rejected.');
fprintf('  PASS predictFromEndpointModels rejects an expired calibration product\n');
end

% ================================================================================================
function hardware = i_defaultHardware_()
hardware = revgnss.ReciprocalLinkHardwareModel('parameterSource','calibrationProduct', ...
    'physicalChainIdentifier','chain:from-record-test','calibrationProductIdentifier','cal:001', ...
    'turnaroundProperTime_s',1e-3,'originTerminalGroupDelay_s',2e-7,'anchorTerminalGroupDelay_s',3e-7);
end

% ================================================================================================
function record = i_validRecordTemplate_()
% Matches tests/test_four_timestamp_invalid_or_out_of_order_tag_rejected.m's own
% i_validRecordTemplate_ exactly (the established Section 4.2 fixture shape for this record type).
record = struct( ...
    'exchangeIdentifier','exch:1','sessionIdentifier','sess:1','topologyKind','directRoundTrip', ...
    'chainEndpointIdentifiers',{{'A','B','B','A'}}, ...
    'chainTerminalIdentifiers',{{'A:tx','B:rx','B:tx','A:rx'}}, ...
    'localClockCompareEndpointIdentifiers',{{'A','B'}}, ...
    'referenceEpochRule','finalReception','referenceCoordinateEpoch_s',10, ...
    'coordinateTimeEvents_s',[1 2 3 10], ...
    'localClockTags_s',[1 2 3 10],'localClockTagAvailable',true(1,4), ...
    'localTimeSystemIdentifiers',{{'A','B','B','A'}}, ...
    'protocolIdentifier','proto:1','signalIdentifier','sig:1','channelIdentifier','chan:1', ...
    'chainCarrierFrequency_Hz',[1e9 1e9 1e9 1e9],'legAppliesAtmosphere',false(1,4), ...
    'calibrationProductIdentifiers',{{}},'covarianceGroupIdentifiers',{{}}, ...
    'covarianceBlock',1e-18,'covarianceComponentOrder',{{'a'}},'covarianceUnits','s^2', ...
    'qualityFlags',struct(),'availability',true,'truthDiagnosticIdentifier','');
end
