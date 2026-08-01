function test_four_timestamp_clock_offset_sign_and_units()
% test_four_timestamp_clock_offset_sign_and_units  Plan Section 4.2, Stage-4 test list item 3.
% revgnss.ReciprocalTimestampEventModel.localClockTags must tag t1/t4 with the ORIGIN's own
% clock and t2/t3 with the transponder/relay's own clock (never mixed), with the correct SIGN
% (a positive clock bias means the local clock reads AHEAD of coordinate time) and UNITS (seconds,
% via revgnss.ReciprocalEndpointTruthProvider's metres/c conversion, matching
% revgnss.TwoWayISLMeasurementBuilder.truthEndpoint_'s own bias_s = clock.getBiasMeters()/c
% convention exactly -- this is the SAME sign convention this test independently re-derives by
% hand, not a call-through to that private method).

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
addpath(rootDir);

fprintf('=== test_four_timestamp_clock_offset_sign_and_units ===\n');
i_test_direct_sign_and_units_();
i_test_relay_transponder_clock_not_endpoint_clocks_();
fprintf('=== test_four_timestamp_clock_offset_sign_and_units: ALL PASS ===\n');
end

% ================================================================================================
function i_test_direct_sign_and_units_()
c = revgnss.Constants.SPEED_OF_LIGHT_MPS;
geom = i_geometry_();
clockA = struct('getBiasMeters',@() 30.0,'getDriftMetersPerSecond',@() 1e-3); % +30 m -> ahead
clockB = struct('getBiasMeters',@() -15.0,'getDriftMetersPerSecond',@() -2e-3); % -15 m -> behind
assetA = struct('r_ecef_m',[7000e3;0;0],'v_ecef_mps',[0;0;0],'attitude_euler_rad',[0;0;0],'clock',clockA);
assetB = struct('r_ecef_m',[7000e3;500e3;0],'v_ecef_mps',[0;0;0],'attitude_euler_rad',[0;0;0],'clock',clockB);
t4_s = 10;

A = revgnss.ReciprocalEndpointTruthProvider.spacecraft(assetA,1,geom,t4_s);
B = revgnss.ReciprocalEndpointTruthProvider.spacecraft(assetB,2,geom,t4_s);
hw = revgnss.ReciprocalLinkHardwareModel('parameterSource','physicalTruth', ...
    'physicalChainIdentifier','chain:1','calibrationProductIdentifier','', ...
    'turnaroundProperTime_s',1e-3);
events = revgnss.ReciprocalTimestampEventModel.solveDirectRoundTrip(A,B,hw,t4_s);
tags_s = revgnss.ReciprocalTimestampEventModel.localClockTags(events,{A,B,B,A});

% Hand-derived expectation, independent of ReciprocalEndpointTruthProvider's own internals:
% localTime(t) = t_s + bias_s + (drift/c)*(t_s-t4_s), where bias_s = biasMeters/c (SAME
% convention as TwoWayISLMeasurementBuilder.truthEndpoint_, re-derived not called through).
biasA_s = clockA.getBiasMeters()/c;
rateA = clockA.getDriftMetersPerSecond()/c;
biasB_s = clockB.getBiasMeters()/c;
rateB = clockB.getDriftMetersPerSecond()/c;
expectedT1 = events.t1_s + biasA_s + rateA*(events.t1_s-t4_s);
expectedT2 = events.t2_s + biasB_s + rateB*(events.t2_s-t4_s);
expectedT3 = events.t3_s + biasB_s + rateB*(events.t3_s-t4_s);
expectedT4 = events.t4_s + biasA_s + rateA*(events.t4_s-t4_s);

assert(abs(tags_s(1)-expectedT1) < 1e-12,'FAIL: t1 tag sign/units mismatch (origin clock)');
assert(abs(tags_s(2)-expectedT2) < 1e-12,'FAIL: t2 tag sign/units mismatch (destination clock)');
assert(abs(tags_s(3)-expectedT3) < 1e-12,'FAIL: t3 tag sign/units mismatch (destination clock)');
assert(abs(tags_s(4)-expectedT4) < 1e-12,'FAIL: t4 tag sign/units mismatch (origin clock)');

% A positive bias (clock ahead of coordinate time) must make the local tag EXCEED the coordinate
% event time; a negative bias must make it fall short. Sign, not just magnitude.
assert(tags_s(1) > events.t1_s,'FAIL: a positive clock bias must read AHEAD of coordinate time');
assert(tags_s(2) < events.t2_s,'FAIL: a negative clock bias must read BEHIND coordinate time');
fprintf('  PASS direct-topology clock tag sign and units match the hand-derived expectation\n');

% Stage 4.2 combined review finding 15: at the t1/t4 separation actually reachable near a solved
% event chain (bounded by light time, ~ms here), this drift's contribution to the tag is ~1e-14 s
% -- 34x BELOW the assertions above's 1e-12 s tolerance, so a full drift-RATE sign flip would go
% undetected there. Probing localTimeAt directly at a deliberately distant coordinate time (not
% tied to the light-time-bounded event chain) isolates the rate term at a magnitude that clears
% tolerance by many orders of magnitude, without touching the bias-dominated assertions above.
farTime_s = t4_s + 1000; % 1000 s past the clock's own reference epoch (t4_s)
farTag_s = A.localTimeAt(farTime_s);
expectedFarTag = farTime_s + biasA_s + rateA*(farTime_s-t4_s);
assert(abs(farTag_s-expectedFarTag) < 1e-12, ...
    'FAIL: localTimeAt at a distant coordinate time must match bias+rate exactly');
% clockA's drift is POSITIVE (clock runs fast): a later coordinate time must accumulate a LARGER
% rate-driven offset above the bias-only baseline, not a smaller or negative one.
biasOnlyFarTag = farTime_s + biasA_s;
assert(farTag_s-biasOnlyFarTag > 1e-10, ... % actual magnitude ~3.3e-9 s; 1e-10 clears both zero and tolerance noise
    'FAIL: a positive clock drift must accumulate a growing positive offset over a long coordinate-time gap');
fprintf('  PASS clock drift-RATE sign is independently verified at a distant, tolerance-clearing probe time\n');
end

% ================================================================================================
function i_test_relay_transponder_clock_not_endpoint_clocks_()
% The concrete regression proof (also exercised via the smoke test during implementation, now a
% permanent test): t2/t3 must be tagged with the RELAY's own clock, never the source's or dest's.
geom = i_geometry_();
clockSource = struct('getBiasMeters',@() 100*revgnss.Constants.SPEED_OF_LIGHT_MPS, ...
    'getDriftMetersPerSecond',@() 0);
clockRelay = struct('getBiasMeters',@() 200*revgnss.Constants.SPEED_OF_LIGHT_MPS, ...
    'getDriftMetersPerSecond',@() 0);
clockDest = struct('getBiasMeters',@() 300*revgnss.Constants.SPEED_OF_LIGHT_MPS, ...
    'getDriftMetersPerSecond',@() 0);
assetSource = struct('r_ecef_m',[7000e3;0;0],'v_ecef_mps',[0;7500;0], ...
    'attitude_euler_rad',[0;0;0],'clock',clockSource);
assetRelay = struct('r_ecef_m',[7000e3;500e3;0],'v_ecef_mps',[0;0;0], ...
    'attitude_euler_rad',[0;0;0],'clock',clockRelay);
assetDest = struct('r_ecef_m',[7000e3;1000e3;0],'v_ecef_mps',[0;-7500;0], ...
    'attitude_euler_rad',[0;0;0],'clock',clockDest);
t4_s = 12;

Source = revgnss.ReciprocalEndpointTruthProvider.spacecraft(assetSource,1,geom,t4_s);
Relay = revgnss.ReciprocalEndpointTruthProvider.spacecraft(assetRelay,2,geom,t4_s);
Dest = revgnss.ReciprocalEndpointTruthProvider.spacecraft(assetDest,3,geom,t4_s);
hw = revgnss.ReciprocalLinkHardwareModel('parameterSource','physicalTruth', ...
    'physicalChainIdentifier','chain:relay','calibrationProductIdentifier','', ...
    'turnaroundProperTime_s',1e-3);
events = revgnss.ReciprocalTimestampEventModel.solveRelayTransit(Source,Relay,Dest,hw,t4_s);
tags_s = revgnss.ReciprocalTimestampEventModel.localClockTags(events,{Source,Relay,Relay,Dest});

assert(abs(tags_s(2)-200) < abs(tags_s(2)-100) && abs(tags_s(2)-200) < abs(tags_s(2)-300), ...
    'FAIL: t2 must be tagged with the RELAY''s own clock reference, not source''s or dest''s');
assert(abs(tags_s(3)-200) < abs(tags_s(3)-100) && abs(tags_s(3)-200) < abs(tags_s(3)-300), ...
    'FAIL: t3 must be tagged with the RELAY''s own clock reference, not source''s or dest''s');
assert(abs(tags_s(1)-100) < abs(tags_s(1)-200),'FAIL: t1 must be tagged with the source''s own clock');
assert(abs(tags_s(4)-300) < abs(tags_s(4)-200),'FAIL: t4 must be tagged with the dest''s own clock');
fprintf('  PASS relay transit tags t2/t3 with the relay''s own clock, never source''s or dest''s\n');
end

% ================================================================================================
function geom = i_geometry_()
geom = struct('transmitOffset_body_m',zeros(3,1),'receiveOffset_body_m',zeros(3,1), ...
    'transmitTerminalIdentifier','terminal:tx','receiveTerminalIdentifier','terminal:rx', ...
    'transmitAntennaIdentifier','antenna:tx','receiveAntennaIdentifier','antenna:rx');
end
