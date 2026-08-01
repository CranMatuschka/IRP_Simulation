function test_four_timestamp_ground_space_finite_difference_jacobian()
% test_four_timestamp_ground_space_finite_difference_jacobian  Plan Section 4.3, Stage-4 named
% test. revgnss.FourTimestampObservableLinearization.groundSpaceJacobian's H_spacecraft (11
% columns: position3, velocity3, attitudeTangent3, clockBias, clockDrift -- NO angularRate columns
% at all, structurally, since a local single-asset EKF's revgnss.AssetStateBlock has no such
% state) must match an INDEPENDENT oracle: revgnss.ConstantVelocityFourEventLightTimeOracle's
% closed-form quadratic solve, re-implemented locally in this test with hand-rolled tag
% construction/terminal-delay allocation/clock-difference reduction -- NEVER calling through to
% revgnss.FourTimestampObservableBuilder/revgnss.ReciprocalTimestampEventModel's own solver, and
% never through revgnss.FourTimestampObservableLinearization/
% revgnss.FourTimestampEstimatorEndpointBridge's own production code. An earlier revision of this
% test built its "oracle" by calling revgnss.FourTimestampObservableBuilder.
% predictFromEndpointModels directly (the SAME production physics core the shipped path uses),
% which the Stage 4.3 combined review flagged (finding 9) as non-independent for the light-time
% physics itself -- only independent of fromAssetStateBlock's state-to-endpoint conversion. This
% revision fixes that: the oracle below never imports predictFromEndpointModels at all, matching
% the SAME independent-oracle structural template
% tests/test_four_timestamp_direct_isl_finite_difference_jacobian.m established.
%
% Attitude perturbation is TANGENT-SPACE (revgnss.AttitudeErrorStateKinematics.
% smallAnglePerturbedDcm), matching groundSpaceJacobian's default
% options.attitudeParameterization='quaternionErrorState' (repo default,
% config/masterConfig.m:239) -- an earlier revision of both the shipped code and this test's own
% oracle used plain additive Euler perturbation unconditionally, which the Stage 4.3 combined
% review found was WRONG for the repo's own default EKF convention (blocking finding 1).
%
% Only the spacecraft is dynamic here (v1 scope, plan item 6's "attitude/lever arm where active");
% the tower is fixed truth/broadcast-product, matching
% revgnss.DirectReciprocalTimeTransferBuilder.buildFromGroundToSpace's own role convention
% (origin=tower, destination=spacecraft).

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
addpath(rootDir);

fprintf('=== test_four_timestamp_ground_space_finite_difference_jacobian ===\n');
fixture = i_fixture_();
i_test_jacobian_matches_independent_oracle_(fixture);
i_test_no_angular_rate_columns_exist_structurally_(fixture);
i_test_clock_bias_partial_is_nonzero_and_correct_sign_(fixture);
i_test_gimbal_guard_rejects_near_singular_pitch_(fixture);
i_test_legacy_euler_option_still_works_(fixture);
fprintf('=== test_four_timestamp_ground_space_finite_difference_jacobian: ALL PASS ===\n');
end

% ================================================================================================
function i_test_jacobian_matches_independent_oracle_(fixture)
[H, kinds, nominalValue_m] = revgnss.FourTimestampObservableLinearization.groundSpaceJacobian( ...
    fixture.x, fixture.stateMap, 1, fixture.geom, fixture.towerEndpoint, fixture.hardware, fixture.t4_s);
assert(numel(H)==11 && numel(kinds)==11);
% Default options.attitudeParameterization='quaternionErrorState' -> 'attitudeTangent', matching
% this class's ISL-path naming convention for the SAME right-multiplicative tangent perturbation
% (not 'attitudeEuler', which is now only reported under the legacy eulerZYX opt-in -- see
% i_test_legacy_euler_option_still_works_ below).
assert(isequal(kinds,{'position','position','position','velocity','velocity','velocity', ...
    'attitudeTangent','attitudeTangent','attitudeTangent','clockBias','clockDrift'}));
assert(isfinite(nominalValue_m));

oracleH = zeros(1,11);
for k = 1:11
    step = fixture.columnSteps(k);
    plus2 = i_oraclePrediction_(fixture,k,2*step);
    plus1 = i_oraclePrediction_(fixture,k,step);
    minus1 = i_oraclePrediction_(fixture,k,-step);
    minus2 = i_oraclePrediction_(fixture,k,-2*step);
    oracleH(k) = (-plus2+8*plus1-8*minus1+minus2)/(12*step);
end

absTol = fixture.cfg.validation.manifest.jacobian.maximumAbsoluteError;
relTol = fixture.cfg.validation.manifest.jacobian.maximumRelativeError;
scale = max(abs(H),abs(oracleH));
err = abs(H-oracleH);
tol = absTol+relTol.*scale;
if any(err > tol)
    disp(table((1:11)',H',oracleH',err',tol','VariableNames',{'column','shipped','oracle','absError','tolerance'}));
end
assert(all(err <= tol), 'H_spacecraft disagrees with the independent oracle.');
assert(any(abs(H(7:9))>0), 'FAIL: attitude columns must be nonzero given the nonzero lever arm.');
fprintf('  PASS H_spacecraft matches the independent oracle (max abs error %.3e)\n',max(err));
end

% ================================================================================================
function i_test_no_angular_rate_columns_exist_structurally_(fixture)
[H, kinds, ~] = revgnss.FourTimestampObservableLinearization.groundSpaceJacobian( ...
    fixture.x, fixture.stateMap, 1, fixture.geom, fixture.towerEndpoint, fixture.hardware, fixture.t4_s);
assert(numel(H)==11, 'FAIL: H_spacecraft must be exactly 11 columns wide -- no angularRate slot exists at all.');
assert(~any(strcmp(kinds,'angularRate')), ...
    'FAIL: groundSpaceJacobian must never report an angularRate column kind.');
fprintf('  PASS no angularRate columns exist structurally (11 wide, not padded to 14)\n');
end

% ================================================================================================
function i_test_clock_bias_partial_is_nonzero_and_correct_sign_(fixture)
[H, ~, ~] = revgnss.FourTimestampObservableLinearization.groundSpaceJacobian( ...
    fixture.x, fixture.stateMap, 1, fixture.geom, fixture.towerEndpoint, fixture.hardware, fixture.t4_s);
% origin=tower (fixed, no clock state here), destination=spacecraft: a positive spacecraft clock
% bias increase must move the destination's own tag2/tag3 the same way the classical formula's
% remoteClockPartial=+1 convention predicts -- H(10) (clockBias) must be positive.
assert(H(10) > 0, 'FAIL: spacecraft clockBias partial must be positive (destination/remote role).');
assert(abs(H(10)-1) < 1e-6, 'FAIL: spacecraft clockBias partial must equal +1 exactly (units: m per m of bias).');
fprintf('  PASS spacecraft clockBias partial is +1 (correct sign and units)\n');
end

% ================================================================================================
function i_test_gimbal_guard_rejects_near_singular_pitch_(fixture)
% Stage 4.3 combined review finding 8 (ties to finding 1): groundSpaceJacobian had no gimbal guard
% at all prior to this fix, unlike islTwoEndpointJacobian's requireLinearizableAttitude_.
guardedFixture = fixture;
guardedFixture.x(fixture.stateMap.euler_idx(2)) = 1.45; % > AttitudePitchGuard_rad (80 deg = 1.3963 rad)
threw = false;
try
    revgnss.FourTimestampObservableLinearization.groundSpaceJacobian( ...
        guardedFixture.x, guardedFixture.stateMap, 1, guardedFixture.geom, ...
        guardedFixture.towerEndpoint, guardedFixture.hardware, guardedFixture.t4_s);
catch ME
    threw = true;
    assert(strcmp(ME.identifier,'FourTimestampObservableLinearization:attitudeNotLinearizable'), ...
        'FAIL: wrong error identifier for the near-singular-pitch guard.');
end
assert(threw, 'FAIL: groundSpaceJacobian must reject a near-gimbal-singular spacecraft pitch.');
fprintf('  PASS gimbal guard rejects a near-singular spacecraft pitch\n');
end

% ================================================================================================
function i_test_legacy_euler_option_still_works_(fixture)
% options.attitudeParameterization='eulerZYX' is the pre-fix behavior, preserved as an explicit
% opt-in (not the default) for a caller whose local EKF genuinely uses the legacy Euler-additive
% parameterization.
options = struct('attitudeParameterization','eulerZYX');
[H, kinds, ~] = revgnss.FourTimestampObservableLinearization.groundSpaceJacobian( ...
    fixture.x, fixture.stateMap, 1, fixture.geom, fixture.towerEndpoint, fixture.hardware, ...
    fixture.t4_s, options);
assert(isequal(kinds,{'position','position','position','velocity','velocity','velocity', ...
    'attitudeEuler','attitudeEuler','attitudeEuler','clockBias','clockDrift'}));
assert(any(abs(H(7:9))>0), 'FAIL: legacy Euler attitude columns must still be nonzero.');
fprintf('  PASS legacy eulerZYX option still dispatches additive-Euler perturbation\n');
end

% ================================================================================================
function fixture = i_fixture_()
cfg = masterConfig();
fixture.cfg = cfg;

fixture.geom = struct('transmitPhaseCentreOffset_body_m',[0.3;-0.1;0.2], ...
    'receivePhaseCentreOffset_body_m',[-0.4;0.5;0.1], ... % deliberately distinct tx/rx, see ISL test
    'transmitTerminalIdentifier','S:tx','receiveTerminalIdentifier','S:rx', ...
    'transmitAntennaIdentifier','S:tx-pc','receiveAntennaIdentifier','S:rx-pc');

fixture.stateMap = struct('r_idx',1:3,'v_idx',4:6,'euler_idx',7:9,'b_rx_idx',10,'bdot_rx_idx',11);
x = zeros(11,1);
x(1:3) = [42164e3;3000e3;500e3];
x(4:6) = [-50;3050;20];
x(7:9) = [0.05;-0.03;0.08];
x(10) = 3.0;
x(11) = 0.05;
fixture.x = x;
fixture.t4_s = 100;

fixture.towerEcef_m = [6378e3;0;0];
fixture.towerClockBiasMeters = 1.0;
fixture.towerClockDriftMetersPerSecond = 0.0;
fixture.towerEndpoint = revgnss.FourTimestampEstimatorEndpointBridge.fromTowerBroadcastProduct( ...
    fixture.towerEcef_m, fixture.towerClockBiasMeters, fixture.towerClockDriftMetersPerSecond, ...
    'tower:1', fixture.geom, fixture.t4_s);
[fixture.rTowerI_m,fixture.vTowerI_mps] = models.frames.FrameTimeUtils.ecefStateToInertial( ...
    fixture.towerEcef_m,zeros(3,1),fixture.t4_s);

fixture.hardware = revgnss.ReciprocalLinkHardwareModel('parameterSource','calibrationProduct', ...
    'physicalChainIdentifier','chain:g2s-jacobian-test','calibrationProductIdentifier','', ...
    'turnaroundProperTime_s',1e-3,'originTerminalGroupDelay_s',1e-7,'anchorTerminalGroupDelay_s',2e-7);

steps = revgnss.FourTimestampObservableLinearization.DefaultLinearizationSteps;
fixture.columnSteps = [steps.positionStep_m,steps.positionStep_m,steps.positionStep_m, ...
    steps.velocityStep_mps,steps.velocityStep_mps,steps.velocityStep_mps, ...
    steps.attitudeStep_rad,steps.attitudeStep_rad,steps.attitudeStep_rad, ...
    steps.clockBiasStep_m,steps.clockDriftStep_mps];
end

% ================================================================================================
function value_m = i_oraclePrediction_(fixture, columnIdx, delta)
% Independent oracle: rebuild both phase-centre position/velocity structs from scratch using only
% public conversion primitives (models.frames.FrameTimeUtils.ecefStateToInertial/
% rotMatEcefToInertial, revgnss.AttitudeKinematics.bodyToEcefRotation,
% revgnss.AttitudeErrorStateKinematics.smallAnglePerturbedDcm) and call
% revgnss.ConstantVelocityFourEventLightTimeOracle.solve directly -- completely independent of
% revgnss.ReciprocalTimestampEventModel, revgnss.FourTimestampObservableBuilder, and
% revgnss.FourTimestampObservableLinearization/revgnss.FourTimestampEstimatorEndpointBridge's own
% production code. Terminal-delay allocation (receiveEvent, this fixture's default) and the
% clock-difference reduction are hand-rolled here too, mirroring
% revgnss.FourTimestampObservableBuilder.applyTerminalDelayAllocation_/reduceClockDifference_'s
% own documented formulas rather than calling them.
c = revgnss.Constants.SPEED_OF_LIGHT_MPS;
x = fixture.x;
sm = fixture.stateMap;
t4_s = fixture.t4_s;
eulerNominal_rad = x(sm.euler_idx);

if columnIdx >= 1 && columnIdx <= 6
    x(columnIdx) = x(columnIdx) + delta;
    rotationSpacecraftBody = revgnss.AttitudeKinematics.bodyToEcefRotation(eulerNominal_rad);
elseif columnIdx >= 7 && columnIdx <= 9
    axisIdx = columnIdx-6;
    deltaTheta_rad = zeros(3,1); deltaTheta_rad(axisIdx) = delta;
    nominalBodyToEcef = revgnss.AttitudeKinematics.bodyToEcefRotation(eulerNominal_rad);
    rotationSpacecraftBody = revgnss.AttitudeErrorStateKinematics.smallAnglePerturbedDcm( ...
        nominalBodyToEcef, deltaTheta_rad);
elseif columnIdx == 10
    x(sm.b_rx_idx) = x(sm.b_rx_idx) + delta;
    rotationSpacecraftBody = revgnss.AttitudeKinematics.bodyToEcefRotation(eulerNominal_rad);
else
    x(sm.bdot_rx_idx) = x(sm.bdot_rx_idx) + delta;
    rotationSpacecraftBody = revgnss.AttitudeKinematics.bodyToEcefRotation(eulerNominal_rad);
end

r_ecef = x(sm.r_idx); v_ecef = x(sm.v_idx);
bBias_m = x(sm.b_rx_idx); bDrift_mps = x(sm.bdot_rx_idx);

[rI_m,vI_mps] = models.frames.FrameTimeUtils.ecefStateToInertial(r_ecef,v_ecef,t4_s);
eciFactor = models.frames.FrameTimeUtils.rotMatEcefToInertial(t4_s);
bodyToInertialSpacecraft = eciFactor*rotationSpacecraftBody;

txArmSpacecraft_m = bodyToInertialSpacecraft*fixture.geom.transmitPhaseCentreOffset_body_m;
rxArmSpacecraft_m = bodyToInertialSpacecraft*fixture.geom.receivePhaseCentreOffset_body_m;
txArmTower_m = eciFactor*fixture.geom.transmitPhaseCentreOffset_body_m;
rxArmTower_m = eciFactor*fixture.geom.receivePhaseCentreOffset_body_m;

% Spacecraft proper-time rate: independently re-derived first post-Newtonian spherical-Earth
% formula, matching revgnss.FourTimestampEstimatorEndpointBridge.properTimeRate_ (that method is
% Access=private to its own class -- re-derived here, not called through, exactly as
% i_perturbedPrediction_ in the ISL sibling test does).
rate = 1 - (revgnss.Constants.EARTH_GM_M3PS2/norm(rI_m)+0.5*dot(vI_mps,vI_mps))/c^2;

spec.referenceCoordinateTime_s = t4_s;
spec.finalReceptionCoordinateTime_s = t4_s;
spec.coordinateTurnaroundDelay_s = fixture.hardware.turnaroundProperTime_s/rate;
spec.initiatorTransmit = struct('positionAtReference_m',fixture.rTowerI_m+txArmTower_m, ...
    'velocity_mps',fixture.vTowerI_mps);
spec.initiatorReceive = struct('positionAtReference_m',fixture.rTowerI_m+rxArmTower_m, ...
    'velocity_mps',fixture.vTowerI_mps);
spec.transponderReceive = struct('positionAtReference_m',rI_m+rxArmSpacecraft_m,'velocity_mps',vI_mps);
spec.transponderTransmit = struct('positionAtReference_m',rI_m+txArmSpacecraft_m,'velocity_mps',vI_mps);
events = revgnss.ConstantVelocityFourEventLightTimeOracle.solve(spec);

towerBias_s = fixture.towerClockBiasMeters/c;
towerRate = 1+fixture.towerClockDriftMetersPerSecond/c;
scBias_s = bBias_m/c;
scRate = 1+bDrift_mps/c;
% localTimeAt(t) = t4_s + bias_s + rate*(t-t4_s) (reference epoch is t4_s throughout this fixture)
tag1 = t4_s + towerBias_s + towerRate*(events.t1_s-t4_s);
tag2 = t4_s + scBias_s + scRate*(events.t2_s-t4_s);
tag3 = t4_s + scBias_s + scRate*(events.t3_s-t4_s);
tag4 = t4_s + towerBias_s + towerRate*(events.t4_s-t4_s);

originDelay_s = fixture.hardware.originTerminalGroupDelay_s;
anchorDelay_s = fixture.hardware.anchorTerminalGroupDelay_s;
% receiveEvent allocation (this fixture's default): tags + [0, anchorDelay, 0, originDelay]
tag2 = tag2 + anchorDelay_s;
tag4 = tag4 + originDelay_s;

value_s = 0.5*((tag2-tag1)-(tag4-tag3));
value_m = c*value_s;
end
