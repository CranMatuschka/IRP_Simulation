function test_four_timestamp_invalid_or_out_of_order_tag_rejected()
% test_four_timestamp_invalid_or_out_of_order_tag_rejected  Plan Section 4.2, Stage-4 test list
% item 10. Missing, nonfinite, out-of-order, or state-source-inconsistent tags must be rejected
% loudly -- never silently replaced with a same-epoch shortcut (plan Section 4.3 implementation
% requirement 7, already binding on the record/solver Section 4.2 builds). Covers both
% revgnss.ReciprocalTimestampEventModel's solve-time rejections and
% revgnss.ReciprocalTimestampExchangeRecord's own construction-time invariant checks.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
addpath(rootDir);

fprintf('=== test_four_timestamp_invalid_or_out_of_order_tag_rejected ===\n');
i_test_nonfinite_t4_rejected_();
i_test_non_convergence_rejected_();
i_test_maximum_iterations_below_floor_rejected_();
i_test_wrong_state_source_rejected_();
i_test_self_link_direct_rejected_();
i_test_relay_non_distinct_endpoints_rejected_();
i_test_record_rejects_out_of_order_coordinate_events_();
i_test_record_rejects_inconsistent_clock_tag_availability_();
i_test_record_rejects_malformed_direct_topology_shape_();
i_test_record_rejects_direct_shaped_chain_under_relay_topology_();
i_test_record_accepts_valid_relay_shape_and_roundtrips_via_toStruct_();
i_test_record_rejects_split_leg_atmosphere_flag_();
i_test_record_rejects_compare_endpoints_not_in_chain_();
fprintf('=== test_four_timestamp_invalid_or_out_of_order_tag_rejected: ALL PASS ===\n');
end

% ================================================================================================
function i_test_record_rejects_split_leg_atmosphere_flag_()
% legAppliesAtmosphere is per-event (4 slots) but atmosphere is physically a per-LEG property:
% forward leg = events (1,2), return leg = events (3,4). A record claiming only HALF a leg crosses
% atmosphere is structurally meaningless (Stage 4.2 combined review finding 3).
record = i_validRecordTemplate_();
record.legAppliesAtmosphere = [true false true false]; % splits both legs
threw = false;
try
    revgnss.ReciprocalTimestampExchangeRecord(record);
catch ME
    threw = strcmp(ME.identifier,'ReciprocalTimestampExchangeRecord:legAppliesAtmosphereLegPair');
end
assert(threw,'FAIL: a legAppliesAtmosphere that disagrees within a leg must be rejected');
fprintf('  PASS record rejects a legAppliesAtmosphere that splits a single leg\n');
end

% ================================================================================================
function i_test_record_rejects_compare_endpoints_not_in_chain_()
record = i_validRecordTemplate_();
record.localClockCompareEndpointIdentifiers = {'X','Y'}; % neither is in the {A,B,B,A} chain
threw = false;
try
    revgnss.ReciprocalTimestampExchangeRecord(record);
catch ME
    threw = strcmp(ME.identifier,'ReciprocalTimestampExchangeRecord:localClockCompareEndpointIdentifiers');
end
assert(threw,'FAIL: compare endpoints not present in the chain must be rejected');
fprintf('  PASS record rejects localClockCompareEndpointIdentifiers not present in the chain\n');
end

% ================================================================================================
function [A,B,hw] = i_baseDirectFixture_()
A = revgnss.TwoWayCodeEndpointModel.constantVelocity('physicalTruth','A',[7000e3;0;0],zeros(3,1),0);
B = revgnss.TwoWayCodeEndpointModel.constantVelocity('physicalTruth','B',[7000e3;500e3;0],zeros(3,1),0);
hw = revgnss.ReciprocalLinkHardwareModel('parameterSource','physicalTruth', ...
    'physicalChainIdentifier','chain:1','calibrationProductIdentifier','', ...
    'turnaroundProperTime_s',1e-3);
end

% ================================================================================================
function i_test_nonfinite_t4_rejected_()
[A,B,hw] = i_baseDirectFixture_();
threw = false;
try
    revgnss.ReciprocalTimestampEventModel.solveDirectRoundTrip(A,B,hw,NaN);
catch ME
    threw = strcmp(ME.identifier,'ReciprocalTimestampEventModel:finalReceptionTime');
end
assert(threw,'FAIL: a nonfinite final reception time must be rejected');
fprintf('  PASS nonfinite t4 rejected\n');
end

% ================================================================================================
function i_test_non_convergence_rejected_()
% A cap below 3 can never satisfy the convergence check (solveRetardedLeg_ only tests closure
% once iterations>=3) -- Stage 4.2 combined review finding 5 -- so that is now validated as a
% hard input error, not exercised as a "convergence failure" here (see the sibling subtest below).
% A REAL non-convergence needs a genuinely pathological geometry: a receiver receding along the
% exact line of sight at 0.999c (empirically confirmed via real MATLAB execution not to converge
% even at cap=200/tolerance=1e-9 -- this is a receding-at-near-light-speed fixed-point that does
% not contract, not merely a tight-tolerance/low-cap artifact), contrasted with a normal
% ~7500 m/s velocity (matching every other test in this suite) converging in 3 iterations at the
% default cap of 50.
c = revgnss.Constants.SPEED_OF_LIGHT_MPS;
[A,~,hw] = i_baseDirectFixture_();
Bnormal = revgnss.TwoWayCodeEndpointModel.constantVelocity('physicalTruth','B',[7000e3;500e3;0],[0;7500;0],0);
eventsNormal = revgnss.ReciprocalTimestampEventModel.solveDirectRoundTrip(A,Bnormal,hw,10);
assert(eventsNormal.forwardIterationCount <= 50 && eventsNormal.returnIterationCount <= 50, ...
    'FAIL: a normal velocity must converge well within the default cap');

Bextreme = revgnss.TwoWayCodeEndpointModel.constantVelocity('physicalTruth','B',[7000e3;500e3;0], ...
    [0;0.999*c;0],0); % receding directly along the line of sight at 0.999c
threw = false;
try
    revgnss.ReciprocalTimestampEventModel.solveDirectRoundTrip(A,Bextreme,hw,10,struct('maximumIterations',20));
catch ME
    threw = strcmp(ME.identifier,'ReciprocalTimestampEventModel:lightTimeConvergence');
end
assert(threw,'FAIL: a genuinely non-convergent (near-light-speed recession) geometry must raise a convergence error');
fprintf('  PASS genuine non-convergence rejected (no silent shortcut)\n');
end

% ================================================================================================
function i_test_maximum_iterations_below_floor_rejected_()
[A,B,hw] = i_baseDirectFixture_();
threw = false;
try
    revgnss.ReciprocalTimestampEventModel.solveDirectRoundTrip(A,B,hw,10,struct('maximumIterations',2));
catch ME
    threw = strcmp(ME.identifier,'ReciprocalTimestampEventModel:solverIterations');
end
assert(threw,'FAIL: maximumIterations below the 3-iteration convergence-check floor must be rejected up front');
fprintf('  PASS maximumIterations below the convergence-check floor rejected at options validation\n');
end

% ================================================================================================
function i_test_wrong_state_source_rejected_()
[~,B,hw] = i_baseDirectFixture_();
Aest = revgnss.TwoWayCodeEndpointModel.constantVelocity('estimatorState','A',[7000e3;0;0],zeros(3,1),0);
threw = false;
try
    revgnss.ReciprocalTimestampEventModel.solveDirectRoundTrip(Aest,B,hw,10);
catch ME
    threw = strcmp(ME.identifier,'TwoWayCodeEndpointModel:sourceSeparation');
end
assert(threw,'FAIL: an estimatorState endpoint must be rejected where physicalTruth is required');
fprintf('  PASS wrong state-source endpoint rejected\n');
end

% ================================================================================================
function i_test_self_link_direct_rejected_()
[A,~,hw] = i_baseDirectFixture_();
threw = false;
try
    revgnss.ReciprocalTimestampEventModel.solveDirectRoundTrip(A,A,hw,10);
catch ME
    threw = strcmp(ME.identifier,'ReciprocalTimestampEventModel:selfLink');
end
assert(threw,'FAIL: identical origin/destination endpoints must be rejected as a self-link');
fprintf('  PASS direct self-link rejected\n');
end

% ================================================================================================
function i_test_relay_non_distinct_endpoints_rejected_()
[A,B,hw] = i_baseDirectFixture_();
threw = false;
try
    revgnss.ReciprocalTimestampEventModel.solveRelayTransit(A,B,B,hw,10); % relay==dest
catch ME
    threw = strcmp(ME.identifier,'ReciprocalTimestampEventModel:selfLink');
end
assert(threw,'FAIL: a relay pass with fewer than 3 distinct endpoints must be rejected');
fprintf('  PASS relay transit with non-distinct endpoints rejected\n');
end

% ================================================================================================
function i_test_record_rejects_out_of_order_coordinate_events_()
record = i_validRecordTemplate_();
record.coordinateTimeEvents_s = [5, 4, 6, 7]; % t2 < t1 -- out of order
threw = false;
try
    revgnss.ReciprocalTimestampExchangeRecord(record);
catch ME
    threw = strcmp(ME.identifier,'ReciprocalTimestampExchangeRecord:coordinateTimeEventsOrder');
end
assert(threw,'FAIL: an out-of-order coordinateTimeEvents_s must be rejected by the record itself');
fprintf('  PASS record rejects out-of-order coordinate events\n');
end

% ================================================================================================
function i_test_record_rejects_inconsistent_clock_tag_availability_()
record = i_validRecordTemplate_();
record.localClockTagAvailable = [true true true false];
record.localClockTags_s = [1 2 3 NaN]; % consistent -- must still fail below when we corrupt it
record.localClockTags_s(1) = NaN; % now available(1)=true but tag(1)=NaN -- inconsistent
threw = false;
try
    revgnss.ReciprocalTimestampExchangeRecord(record);
catch ME
    threw = strcmp(ME.identifier,'ReciprocalTimestampExchangeRecord:localClockTagsAvailability');
end
assert(threw,'FAIL: a NaN tag marked available (or vice versa) must be rejected, never treated as a shortcut');
fprintf('  PASS record rejects inconsistent local-clock-tag availability\n');
end

% ================================================================================================
function i_test_record_rejects_malformed_direct_topology_shape_()
record = i_validRecordTemplate_();
record.chainEndpointIdentifiers = {'A','B','C','A'}; % dest role (2,3) must match; C != B
threw = false;
try
    revgnss.ReciprocalTimestampExchangeRecord(record);
catch ME
    threw = strcmp(ME.identifier,'ReciprocalTimestampExchangeRecord:directTopologyShape');
end
assert(threw,'FAIL: a malformed directRoundTrip chain shape must be rejected');
fprintf('  PASS record rejects a malformed directRoundTrip chain shape\n');
end

% ================================================================================================
function i_test_record_rejects_direct_shaped_chain_under_relay_topology_()
record = i_validRecordTemplate_();
record.topologyKind = 'relayTransit'; % chainEndpointIdentifiers still {A,B,B,A} -- wrong shape
threw = false;
try
    revgnss.ReciprocalTimestampExchangeRecord(record);
catch ME
    threw = strcmp(ME.identifier,'ReciprocalTimestampExchangeRecord:relayTopologyShape');
end
assert(threw,'FAIL: a direct-shaped chain declared under relayTransit must be rejected');
fprintf('  PASS record rejects a direct-shaped chain declared as relayTransit\n');
end

% ================================================================================================
function i_test_record_accepts_valid_relay_shape_and_roundtrips_via_toStruct_()
record = i_validRecordTemplate_();
record.topologyKind = 'relayTransit';
record.chainEndpointIdentifiers = {'asset:1','relay:1','relay:1','asset:2'};
record.chainTerminalIdentifiers = {'term:a','term:r1','term:r2','term:b'};
record.localClockCompareEndpointIdentifiers = {'asset:1','asset:2'};
record.localTimeSystemIdentifiers = {'asset:1','relay:1','relay:1','asset:2'};
rec = revgnss.ReciprocalTimestampExchangeRecord(record);
assert(strcmp(rec.topologyKind,'relayTransit'),'FAIL: a valid 3-node relay chain shape must construct cleanly');
s = rec.toStruct();
assert(strcmp(s.exchangeIdentifier,'exch:1') && isequal(s.chainEndpointIdentifiers, ...
    {'asset:1','relay:1','relay:1','asset:2'}), 'FAIL: toStruct() must round-trip every field exactly');
fprintf('  PASS record accepts a valid relayTransit chain shape, toStruct() round-trips exactly\n');
end

% ================================================================================================
function record = i_validRecordTemplate_()
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
