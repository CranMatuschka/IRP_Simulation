function test_four_timestamp_static_symmetric_limit()
% test_four_timestamp_static_symmetric_limit  Plan Section 4.2, Stage-4 test list item 1.
% revgnss.ReciprocalTimestampEventModel's static (zero-velocity) limit must (a) give
% forward==return propagation delay to numerical precision and (b) agree with the pre-existing,
% independent revgnss.ConstantVelocityFourEventLightTimeOracle closed-form quadratic solver --
% not just be internally residual-consistent. The oracle's 4 phase-centre trajectories are
% declared independently of any "same body twice" assumption, so the SAME oracle validates both
% the 2-node directRoundTrip topology (chainEndpoints{1}==chainEndpoints{4}) and the 3-node
% relayTransit topology (all three distinct) with no relay-specific oracle code needed.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
addpath(rootDir);

fprintf('=== test_four_timestamp_static_symmetric_limit ===\n');
i_test_direct_static_symmetric_vs_oracle_();
i_test_relay_static_vs_oracle_();
fprintf('=== test_four_timestamp_static_symmetric_limit: ALL PASS ===\n');
end

% ================================================================================================
function i_test_direct_static_symmetric_vs_oracle_()
rA_m = [7000e3;0;0];
rB_m = [7000e3;500e3;0];
hw = revgnss.ReciprocalLinkHardwareModel('parameterSource','physicalTruth', ...
    'physicalChainIdentifier','chain:1','calibrationProductIdentifier','', ...
    'turnaroundProperTime_s',1e-3);
A = revgnss.TwoWayCodeEndpointModel.constantVelocity('physicalTruth','A',rA_m,zeros(3,1),0);
B = revgnss.TwoWayCodeEndpointModel.constantVelocity('physicalTruth','B',rB_m,zeros(3,1),0);
t4_s = 10;

events = revgnss.ReciprocalTimestampEventModel.solveDirectRoundTrip(A,B,hw,t4_s);
assert(abs(events.forwardPropagationDelay_s-events.returnPropagationDelay_s) < 1e-12, ...
    'FAIL: stationary endpoints must give forward==return delay');

oracleSpec = struct('referenceCoordinateTime_s',0,'finalReceptionCoordinateTime_s',t4_s, ...
    'coordinateTurnaroundDelay_s',hw.turnaroundProperTime_s, ...
    'initiatorTransmit',i_phaseCentre_(rA_m,zeros(3,1)), ...
    'initiatorReceive',i_phaseCentre_(rA_m,zeros(3,1)), ...
    'transponderReceive',i_phaseCentre_(rB_m,zeros(3,1)), ...
    'transponderTransmit',i_phaseCentre_(rB_m,zeros(3,1)));
oracle = revgnss.ConstantVelocityFourEventLightTimeOracle.solve(oracleSpec);

modelTimes = [events.t1_s,events.t2_s,events.t3_s,events.t4_s];
oracleTimes = [oracle.t1_s,oracle.t2_s,oracle.t3_s,oracle.t4_s];
assert(max(abs(modelTimes-oracleTimes)) < 1e-10, ...
    'FAIL: direct static event times must match the independent oracle');
assert(abs(events.forwardRange_m-oracle.forwardRange_m) < 1e-8, ...
    'FAIL: direct static forward range must match the independent oracle');
assert(abs(events.returnRange_m-oracle.returnRange_m) < 1e-8, ...
    'FAIL: direct static return range must match the independent oracle');
fprintf('  PASS direct static symmetric limit matches independent oracle\n');
end

% ================================================================================================
function i_test_relay_static_vs_oracle_()
rSource_m = [7000e3;0;0];
rRelay_m = [7000e3;500e3;0];
rDest_m = [7000e3;1000e3;0];
hw = revgnss.ReciprocalLinkHardwareModel('parameterSource','physicalTruth', ...
    'physicalChainIdentifier','chain:relay','calibrationProductIdentifier','', ...
    'turnaroundProperTime_s',2e-3);
Source = revgnss.TwoWayCodeEndpointModel.constantVelocity('physicalTruth','S',rSource_m,zeros(3,1),0);
Relay = revgnss.TwoWayCodeEndpointModel.constantVelocity('physicalTruth','R',rRelay_m,zeros(3,1),0);
Dest = revgnss.TwoWayCodeEndpointModel.constantVelocity('physicalTruth','D',rDest_m,zeros(3,1),0);
t4_s = 12;

events = revgnss.ReciprocalTimestampEventModel.solveRelayTransit(Source,Relay,Dest,hw,t4_s);

oracleSpec = struct('referenceCoordinateTime_s',0,'finalReceptionCoordinateTime_s',t4_s, ...
    'coordinateTurnaroundDelay_s',hw.turnaroundProperTime_s, ...
    'initiatorTransmit',i_phaseCentre_(rSource_m,zeros(3,1)), ...
    'initiatorReceive',i_phaseCentre_(rDest_m,zeros(3,1)), ...
    'transponderReceive',i_phaseCentre_(rRelay_m,zeros(3,1)), ...
    'transponderTransmit',i_phaseCentre_(rRelay_m,zeros(3,1)));
oracle = revgnss.ConstantVelocityFourEventLightTimeOracle.solve(oracleSpec);

modelTimes = [events.t1_s,events.t2_s,events.t3_s,events.t4_s];
oracleTimes = [oracle.t1_s,oracle.t2_s,oracle.t3_s,oracle.t4_s];
assert(max(abs(modelTimes-oracleTimes)) < 1e-10, ...
    'FAIL: relay static event times must match the independent oracle');
assert(abs(events.forwardRange_m-oracle.forwardRange_m) < 1e-8, ...
    'FAIL: relay static forward (source->relay) range must match the independent oracle');
assert(abs(events.returnRange_m-oracle.returnRange_m) < 1e-8, ...
    'FAIL: relay static return (relay->dest) range must match the independent oracle');
% Symmetric equilateral-collinear-equal-spacing geometry -> forward leg length == return leg
% length -> forward and return propagation delay must agree.
assert(abs(events.forwardPropagationDelay_s-events.returnPropagationDelay_s) < 1e-12, ...
    'FAIL: symmetric relay leg geometry must give forward==return delay');
fprintf('  PASS relay static transit matches independent oracle\n');
end

% ================================================================================================
function phaseCentre = i_phaseCentre_(position_m, velocity_mps)
phaseCentre = struct('positionAtReference_m',position_m,'velocity_mps',velocity_mps);
end
