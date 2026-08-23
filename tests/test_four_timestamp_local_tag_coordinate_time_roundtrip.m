function test_four_timestamp_local_tag_coordinate_time_roundtrip()
% test_four_timestamp_local_tag_coordinate_time_roundtrip  Plan Section 4.2, Stage-4 test list
% item 5. Every local clock tag revgnss.ReciprocalTimestampEventModel.localClockTags produces
% must round-trip exactly back to its originating coordinate event time through that SAME
% endpoint's own revgnss.TwoWayCodeEndpointModel.coordinateTimeAtLocalTag -- proving the four
% tags are genuinely invertible per-endpoint conversions, not some lossy or cross-endpoint-mixed
% approximation. Exercised for both directRoundTrip and relayTransit, and for clock rates != 1
% (drifting clocks), which is the case where a naive tag/roundtrip implementation is most likely
% to silently swap bias and rate.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
addpath(rootDir);

fprintf('=== test_four_timestamp_local_tag_coordinate_time_roundtrip ===\n');
i_test_direct_roundtrip_with_drifting_clocks_();
i_test_relay_roundtrip_with_drifting_clocks_();
fprintf('=== test_four_timestamp_local_tag_coordinate_time_roundtrip: ALL PASS ===\n');
end

% ================================================================================================
function i_test_direct_roundtrip_with_drifting_clocks_()
A = revgnss.TwoWayCodeEndpointModel.constantVelocity('physicalTruth','A', ...
    [7000e3;0;0],[0;7500;0],0,clockLocalTimeAtReference_s=5,localClockRate=1+3e-8);
B = revgnss.TwoWayCodeEndpointModel.constantVelocity('physicalTruth','B', ...
    [7000e3;500e3;0],[0;-7500;0],0,clockLocalTimeAtReference_s=-3,localClockRate=1-2e-8);
hw = revgnss.ReciprocalLinkHardwareModel('parameterSource','physicalTruth', ...
    'physicalChainIdentifier','chain:1','calibrationProductIdentifier','', ...
    'turnaroundProperTime_s',1e-3);
t4_s = 10;
events = revgnss.ReciprocalTimestampEventModel.solveDirectRoundTrip(A,B,hw,t4_s);
tags_s = revgnss.ReciprocalTimestampEventModel.localClockTags(events,{A,B,B,A});
eventTimes_s = [events.t1_s,events.t2_s,events.t3_s,events.t4_s];
chainEndpoints = {A,B,B,A};
for k = 1:4
    recovered_s = chainEndpoints{k}.coordinateTimeAtLocalTag(tags_s(k));
    assert(abs(recovered_s-eventTimes_s(k)) < 1e-9, ...
        'FAIL: local tag %d must round-trip exactly back to its coordinate event time',k);
end
fprintf('  PASS direct-topology local tags round-trip exactly with drifting clocks\n');
end

% ================================================================================================
function i_test_relay_roundtrip_with_drifting_clocks_()
Source = revgnss.TwoWayCodeEndpointModel.constantVelocity('physicalTruth','S', ...
    [7000e3;0;0],[0;7500;0],0,clockLocalTimeAtReference_s=7,localClockRate=1+1e-8);
Relay = revgnss.TwoWayCodeEndpointModel.constantVelocity('physicalTruth','R', ...
    [7000e3;500e3;0],[50;0;30],0,clockLocalTimeAtReference_s=-11,localClockRate=1-5e-8);
Dest = revgnss.TwoWayCodeEndpointModel.constantVelocity('physicalTruth','D', ...
    [7000e3;1000e3;0],[0;-7500;0],0,clockLocalTimeAtReference_s=2,localClockRate=1+4e-8);
hw = revgnss.ReciprocalLinkHardwareModel('parameterSource','physicalTruth', ...
    'physicalChainIdentifier','chain:relay','calibrationProductIdentifier','', ...
    'turnaroundProperTime_s',2e-3);
t4_s = 12;
events = revgnss.ReciprocalTimestampEventModel.solveRelayTransit(Source,Relay,Dest,hw,t4_s);
chainEndpoints = {Source,Relay,Relay,Dest};
tags_s = revgnss.ReciprocalTimestampEventModel.localClockTags(events,chainEndpoints);
eventTimes_s = [events.t1_s,events.t2_s,events.t3_s,events.t4_s];
for k = 1:4
    recovered_s = chainEndpoints{k}.coordinateTimeAtLocalTag(tags_s(k));
    assert(abs(recovered_s-eventTimes_s(k)) < 1e-9, ...
        'FAIL: relay-topology local tag %d must round-trip exactly back to its coordinate event time',k);
end
% Cross-endpoint sanity: applying the WRONG endpoint's inverse must NOT generally recover the
% same event time (proves the roundtrip above is not vacuously true for any endpoint).
mismatchRecovered_s = Dest.coordinateTimeAtLocalTag(tags_s(2));
assert(abs(mismatchRecovered_s-eventTimes_s(2)) > 1e-6, ...
    'FAIL: the relay''s own t2 tag must not also round-trip through the destination''s clock model');
fprintf('  PASS relay-topology local tags round-trip exactly, and only through their own endpoint\n');
end
