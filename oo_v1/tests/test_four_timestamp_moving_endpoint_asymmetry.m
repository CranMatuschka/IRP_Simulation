function test_four_timestamp_moving_endpoint_asymmetry()
% test_four_timestamp_moving_endpoint_asymmetry  Plan Section 4.2, Stage-4 test list item 2.
% For moving endpoints, forward and return light time must never be assumed equal (plan Section
% 4.3 implementation requirement 1, already binding on the Section 4.2 solver it builds on).
% Cross-validated against the independent revgnss.ConstantVelocityFourEventLightTimeOracle
% closed-form quadratic solver for both the directRoundTrip and relayTransit topologies -- this
% is the strong, non-tautological check: revgnss.ReciprocalTimestampEventModel's own residual
% closure only proves internal self-consistency, not correctness against an independent method.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
addpath(rootDir);

fprintf('=== test_four_timestamp_moving_endpoint_asymmetry ===\n');
i_test_direct_moving_vs_oracle_();
i_test_relay_moving_vs_oracle_();
fprintf('=== test_four_timestamp_moving_endpoint_asymmetry: ALL PASS ===\n');
end

% ================================================================================================
function i_test_direct_moving_vs_oracle_()
rA_m = [7000e3;0;0]; vA_mps = [0;7500;0];
rB_m = [7000e3;500e3;0]; vB_mps = [0;-7500;0];
hw = revgnss.ReciprocalLinkHardwareModel('parameterSource','physicalTruth', ...
    'physicalChainIdentifier','chain:1','calibrationProductIdentifier','', ...
    'turnaroundProperTime_s',1e-3);
A = revgnss.TwoWayCodeEndpointModel.constantVelocity('physicalTruth','A',rA_m,vA_mps,0);
B = revgnss.TwoWayCodeEndpointModel.constantVelocity('physicalTruth','B',rB_m,vB_mps,0);
t4_s = 10;

events = revgnss.ReciprocalTimestampEventModel.solveDirectRoundTrip(A,B,hw,t4_s);
assert(abs(events.forwardPropagationDelay_s-events.returnPropagationDelay_s) > 1e-9, ...
    'FAIL: moving endpoints must give a real forward/return asymmetry, not a static-limit equality');

oracleSpec = struct('referenceCoordinateTime_s',0,'finalReceptionCoordinateTime_s',t4_s, ...
    'coordinateTurnaroundDelay_s',hw.turnaroundProperTime_s, ...
    'initiatorTransmit',i_phaseCentre_(rA_m,vA_mps), ...
    'initiatorReceive',i_phaseCentre_(rA_m,vA_mps), ...
    'transponderReceive',i_phaseCentre_(rB_m,vB_mps), ...
    'transponderTransmit',i_phaseCentre_(rB_m,vB_mps));
oracle = revgnss.ConstantVelocityFourEventLightTimeOracle.solve(oracleSpec);

modelTimes = [events.t1_s,events.t2_s,events.t3_s,events.t4_s];
oracleTimes = [oracle.t1_s,oracle.t2_s,oracle.t3_s,oracle.t4_s];
assert(max(abs(modelTimes-oracleTimes)) < 1e-10, ...
    'FAIL: direct moving event times must match the independent oracle');
assert(abs(events.forwardRange_m-oracle.forwardRange_m) < 1e-8, ...
    'FAIL: direct moving forward range must match the independent oracle');
assert(abs(events.returnRange_m-oracle.returnRange_m) < 1e-8, ...
    'FAIL: direct moving return range must match the independent oracle');
assert(max(abs([events.forwardResidual_s,events.returnResidual_s])) < 1e-11, ...
    'FAIL: light-time residuals must close to tolerance');
fprintf('  PASS direct moving-endpoint asymmetry matches independent oracle\n');
end

% ================================================================================================
function i_test_relay_moving_vs_oracle_()
rSource_m = [7000e3;0;0]; vSource_mps = [0;7500;0];
rRelay_m = [7000e3;500e3;0]; vRelay_mps = [50;0;30];
rDest_m = [7000e3;1000e3;0]; vDest_mps = [0;-7500;0];
hw = revgnss.ReciprocalLinkHardwareModel('parameterSource','physicalTruth', ...
    'physicalChainIdentifier','chain:relay','calibrationProductIdentifier','', ...
    'turnaroundProperTime_s',2e-3);
Source = revgnss.TwoWayCodeEndpointModel.constantVelocity('physicalTruth','S',rSource_m,vSource_mps,0);
Relay = revgnss.TwoWayCodeEndpointModel.constantVelocity('physicalTruth','R',rRelay_m,vRelay_mps,0);
Dest = revgnss.TwoWayCodeEndpointModel.constantVelocity('physicalTruth','D',rDest_m,vDest_mps,0);
t4_s = 12;

events = revgnss.ReciprocalTimestampEventModel.solveRelayTransit(Source,Relay,Dest,hw,t4_s);
assert(abs(events.forwardPropagationDelay_s-events.returnPropagationDelay_s) > 1e-9, ...
    'FAIL: a moving relay pass must give a real forward/return leg asymmetry');

oracleSpec = struct('referenceCoordinateTime_s',0,'finalReceptionCoordinateTime_s',t4_s, ...
    'coordinateTurnaroundDelay_s',hw.turnaroundProperTime_s, ...
    'initiatorTransmit',i_phaseCentre_(rSource_m,vSource_mps), ...
    'initiatorReceive',i_phaseCentre_(rDest_m,vDest_mps), ...
    'transponderReceive',i_phaseCentre_(rRelay_m,vRelay_mps), ...
    'transponderTransmit',i_phaseCentre_(rRelay_m,vRelay_mps));
oracle = revgnss.ConstantVelocityFourEventLightTimeOracle.solve(oracleSpec);

modelTimes = [events.t1_s,events.t2_s,events.t3_s,events.t4_s];
oracleTimes = [oracle.t1_s,oracle.t2_s,oracle.t3_s,oracle.t4_s];
assert(max(abs(modelTimes-oracleTimes)) < 1e-10, ...
    'FAIL: relay moving event times must match the independent oracle');
assert(abs(events.forwardRange_m-oracle.forwardRange_m) < 1e-8, ...
    'FAIL: relay moving forward (source->relay) range must match the independent oracle');
assert(abs(events.returnRange_m-oracle.returnRange_m) < 1e-8, ...
    'FAIL: relay moving return (relay->dest) range must match the independent oracle');
fprintf('  PASS relay moving transit matches independent oracle\n');
end

% ================================================================================================
function phaseCentre = i_phaseCentre_(position_m, velocity_mps)
phaseCentre = struct('positionAtReference_m',position_m,'velocity_mps',velocity_mps);
end
