function test_four_timestamp_direct_isl_finite_difference_jacobian()
% test_four_timestamp_direct_isl_finite_difference_jacobian  Plan Section 4.3, Stage-4 named test.
% revgnss.FourTimestampObservableLinearization.islTwoEndpointJacobian's H_owner/H_remote (14
% columns each: position3, velocity3, attitude3, angularRate3, clockBias, clockDrift) must match
% an INDEPENDENT oracle -- revgnss.ConstantVelocityFourEventLightTimeOracle's closed-form
% quadratic solve, re-implemented locally in this test (never calling through to
% revgnss.FourTimestampObservableBuilder/revgnss.ReciprocalTimestampEventModel's own solver, and
% never through revgnss.FourTimestampObservableLinearization's own production stencil code) --
% exactly matching the structural template tests/test_coherent_two_way_code_physical_jacobian.m
% established, and the SAME independent oracle tests/test_four_timestamp_static_symmetric_limit.m
% and tests/test_four_timestamp_moving_endpoint_asymmetry.m (Section 4.2) already use.
%
% Fixture uses a DELIBERATELY NONZERO lever arm on both endpoints -- every Section 4.2 test fixture
% used a zero lever arm and therefore never exercised attitude/lever-arm sensitivity for this
% physics family at all; this is the first test in the whole Stage-4 suite that does.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
addpath(rootDir);
addpath(fullfile(rootDir,'config'));
addpath(fullfile(rootDir,'config','internal'));

fprintf('=== test_four_timestamp_direct_isl_finite_difference_jacobian ===\n');
fixture = i_fixture_();
i_test_owner_and_remote_jacobian_match_oracle_(fixture);
i_test_angular_rate_columns_are_zero_(fixture);
i_test_clock_bias_partials_have_opposite_sign_(fixture);
i_test_calibration_mapping_matches_closed_form_and_oracle_(fixture);
fprintf('=== test_four_timestamp_direct_isl_finite_difference_jacobian: ALL PASS ===\n');
end

% ================================================================================================
function i_test_owner_and_remote_jacobian_match_oracle_(fixture)
[H_owner, H_remote, ownerKinds, remoteKinds, nominalValue_m] = ...
    revgnss.FourTimestampObservableLinearization.islTwoEndpointJacobian( ...
    fixture.ownerState, fixture.remoteState, 'origin', fixture.hardware, fixture.t4_s);
assert(numel(H_owner)==14 && numel(H_remote)==14);
assert(numel(ownerKinds)==14 && numel(remoteKinds)==14);
assert(isfinite(nominalValue_m));

oracleH_owner = i_oracleJacobian_(fixture,'owner',fixture.ownerColumnSteps);
oracleH_remote = i_oracleJacobian_(fixture,'remote',fixture.remoteColumnSteps);

absTol = fixture.cfg.validation.manifest.jacobian.maximumAbsoluteError;
relTol = fixture.cfg.validation.manifest.jacobian.maximumRelativeError;
% The STRICT global tolerance applies to every column, including attitude (7-9) -- no per-column
% widening. Attitude columns 7-9 previously needed a widened tolerance at
% revgnss.FourTimestampObservableLinearization.DefaultLinearizationSteps.attitudeStep_rad=5e-4;
% the Stage 4.3 combined review measured that this specific observable's attitude-column FD is
% noise-dominated (~1.8e-5 relative wobble) at that step, not converged as originally believed.
% The correct fix (applied in DefaultLinearizationSteps, not here) was to widen the FD step itself
% (5e-3) rather than loosen this comparison -- at 5e-3 the shipped Jacobian agrees with this
% test's independent oracle comfortably inside the ORIGINAL strict global tolerance.

scaleOwner = max(abs(H_owner),abs(oracleH_owner));
errOwner = abs(H_owner-oracleH_owner);
tolOwner = absTol+relTol.*scaleOwner;
if any(errOwner > tolOwner)
    disp(table((1:14)',H_owner',oracleH_owner',errOwner',tolOwner','VariableNames', ...
        {'column','shipped','oracle','absError','tolerance'}));
end
assert(all(errOwner <= tolOwner), 'H_owner disagrees with the independent oracle.');

scaleRemote = max(abs(H_remote),abs(oracleH_remote));
errRemote = abs(H_remote-oracleH_remote);
tolRemote = absTol+relTol.*scaleRemote;
if any(errRemote > tolRemote)
    disp(table((1:14)',H_remote',oracleH_remote',errRemote',tolRemote','VariableNames', ...
        {'column','shipped','oracle','absError','tolerance'}));
end
assert(all(errRemote <= tolRemote), 'H_remote disagrees with the independent oracle.');

% The nonzero lever arm must actually be exercised: attitude columns must be nonzero.
assert(any(abs(H_owner(7:9))>0) && any(abs(H_remote(7:9))>0), ...
    'FAIL: attitude columns must be nonzero given the nonzero lever arm fixture.');
fprintf('  PASS H_owner/H_remote match the independent oracle (lever arm exercised)\n');
end

% ================================================================================================
function i_test_angular_rate_columns_are_zero_(fixture)
[H_owner, H_remote, ~, ~, ~] = revgnss.FourTimestampObservableLinearization.islTwoEndpointJacobian( ...
    fixture.ownerState, fixture.remoteState, 'origin', fixture.hardware, fixture.t4_s);
assert(all(H_owner(10:12)==0) && all(H_remote(10:12)==0), ...
    'FAIL: angularRate columns must be declared and structurally zero (constant-attitude endpoints).');
fprintf('  PASS angularRate columns are structurally zero\n');
end

% ================================================================================================
function i_test_clock_bias_partials_have_opposite_sign_(fixture)
[H_owner, H_remote, ~, ~, ~] = revgnss.FourTimestampObservableLinearization.islTwoEndpointJacobian( ...
    fixture.ownerState, fixture.remoteState, 'origin', fixture.hardware, fixture.t4_s);
% owner==origin here: predictFromEndpointModels' value_s = 0.5*((tag2-tag1)-(tag4-tag3)), and
% tag1/tag4 come from origin's own clock -- a bias increase at the ORIGIN must move t1 tag AND t4
% tag the same way, so its net effect on value has the OPPOSITE sign to a bias increase at the
% DESTINATION (which only shifts tag2/tag3), matching
% revgnss.ReciprocalTimeTransferModel.evaluate's own referenceClockPartial=-1/remoteClockPartial=+1
% sign convention.
assert(sign(H_owner(13)) ~= sign(H_remote(13)), ...
    'FAIL: origin and destination clockBias partials must have opposite sign');
fprintf('  PASS origin/destination clockBias partials have opposite sign\n');
end

% ================================================================================================
function i_test_calibration_mapping_matches_closed_form_and_oracle_(fixture)
originModel = revgnss.FourTimestampEstimatorEndpointBridge.fromCommunicationEndpointState( ...
    fixture.ownerState,'origin');
destinationModel = revgnss.FourTimestampEstimatorEndpointBridge.fromCommunicationEndpointState( ...
    fixture.remoteState,'destination');
[dO,dA,dOD,dAD] = revgnss.FourTimestampObservableLinearization.calibrationMappingJacobian( ...
    originModel, destinationModel, fixture.hardware, fixture.t4_s);
% DIMENSIONLESS closed form (m of clockDifferenceValue_m per m of calibration-state delay),
% matching revgnss.DistributedLinkUpdateBlock.calibrationStateUnits=='m' -- NOT m/s (an earlier
% revision returned +-0.5*c here, off by exactly a factor of c; Stage 4.3 combined review
% blocking finding 2).
assert(abs(dO-(-0.5)) < 1e-9, 'FAIL: dValue/dOrigin must match the closed-form receiveEvent table');
assert(abs(dA-0.5) < 1e-9, 'FAIL: dValue/dAnchor must match the closed-form receiveEvent table');
assert(abs(dOD-1) < 1e-9 && abs(dAD-(-1)) < 1e-9, ...
    'FAIL: the allocation-invariant diagnostic sensitivities must be exactly +1/-1');
assert(abs(dO+dA) < 1e-12, ...
    'FAIL: origin and anchor sensitivities must be exact opposites under receiveEvent (Section 3.2)');

% Independent cross-check against predictFromEndpointModels' own finite difference (never trust
% the closed form blindly): a genuinely independent forward-difference, local to this test only,
% against a hand-built shifted-hardware copy -- exercised at a REALISTIC nonzero t4_s (not the 0
% this fixture's own epoch happens to be, which the Stage 4.3 review noted would have hidden the
% original m/s-units bug from a naive m/m check).
c = revgnss.Constants.SPEED_OF_LIGHT_MPS;
step_s = 1e-6;
t4Realistic_s = fixture.t4_s + 3600;
baseHardware = fixture.hardware;
shiftedOriginHardware = revgnss.ReciprocalLinkHardwareModel( ...
    'parameterSource',baseHardware.parameterSource, ...
    'physicalChainIdentifier',baseHardware.physicalChainIdentifier, ...
    'calibrationProductIdentifier',baseHardware.calibrationProductIdentifier, ...
    'turnaroundProperTime_s',baseHardware.turnaroundProperTime_s, ...
    'originTerminalGroupDelay_s',baseHardware.originTerminalGroupDelay_s+step_s, ...
    'anchorTerminalGroupDelay_s',baseHardware.anchorTerminalGroupDelay_s);
[valueNominal_m,~] = revgnss.FourTimestampObservableBuilder.predictFromEndpointModels( ...
    originModel, destinationModel, baseHardware, t4Realistic_s);
[valueShiftedOrigin_m,~] = revgnss.FourTimestampObservableBuilder.predictFromEndpointModels( ...
    originModel, destinationModel, shiftedOriginHardware, t4Realistic_s);
dValueDOriginFD_mPerS = (valueShiftedOrigin_m-valueNominal_m)/step_s;
dValueDOriginFD = dValueDOriginFD_mPerS/c; % m/s -> dimensionless (per m of calibration state)
assert(abs(dValueDOriginFD-dO) < 1e-3, ...
    'FAIL: closed-form dValue/dOrigin disagrees with an independent finite difference at a realistic epoch.');
fprintf('  PASS calibrationMappingJacobian matches the closed-form table and an independent FD cross-check\n');
end

% ================================================================================================
function fixture = i_fixture_()
cfg = masterConfig();
cfg.simulation.duration_s = 4;
cfg.simulation.dt_s = 1;
cfg.report.writePdf = false;
cfg.report.writeMat = false;
cfg.report.compileTex = 'never';
cfg.plots.enable = false;
cfg.plots.showFigures = false;

fleetCfg = cfg;
fleetCfg.scenario.nSpaceAssets = 2;
setup = revgnss.IndependentFleetScenarioFactory.federatedSetup(fleetCfg, false);
cfg1 = revgnss.IndependentFleetScenarioFactory.stageOneLeafConfigForIndex(setup, fleetCfg, 1);
cfg2 = revgnss.IndependentFleetScenarioFactory.stageOneLeafConfigForIndex(setup, fleetCfg, 2);
sim1 = revgnss.ReverseGNSSSimulation(cfg1);
sim1.initialize(); sim1.advanceTruthEpoch(1); sim1.runLocalEstimationEpoch(1);
sim2 = revgnss.ReverseGNSSSimulation(cfg2);
sim2.initialize(); sim2.advanceTruthEpoch(1); sim2.runLocalEstimationEpoch(1);

epoch_s = sim1.tVec(sim1.lastEstimatedEpoch);
assert(isequal(sim1.tVec,sim2.tVec));

% Deliberately nonzero AND DISTINCT tx/rx lever arms -- see file header. A real, verified physical
% finding during implementation: with EQUAL tx/rx offsets, this observable's sensitivity to the
% ORIGIN's own attitude nearly cancels (the forward leg's TX-arm shift and the return leg's RX-arm
% shift partially cancel in the classical two-way combination 0.5*[(tag2-tag1)-(tag4-tag3)]),
% making H(7:9) noise-dominated at any achievable FD step (confirmed empirically: production's own
% H_owner(7:9) failed to CONVERGE across step sizes 5e-4/1e-4/5e-5 when tx==rx, varying by >5x --
% not a bug, a genuine near-degeneracy). Distinct tx/rx offsets (realistic: separate TX/RX
% apertures) break the cancellation and give a robust, step-size-STABLE signal (confirmed:
% H_owner(7) agrees to 5 significant figures across the same three step sizes once tx~=rx).
txArm = [0.9;0.3;0.4];
rxArm = [-0.5;0.7;-0.2];
ownerTerminal = struct('declared',true, ...
    'transmitTerminalIdentifier','terminal:tx1','receiveTerminalIdentifier','terminal:rx1', ...
    'transmitAntennaIdentifier','antenna:tx1','receiveAntennaIdentifier','antenna:rx1', ...
    'transmitPhaseCentreOffset_body_m',txArm,'receivePhaseCentreOffset_body_m',rxArm);
remoteTerminal = struct('declared',true, ...
    'transmitTerminalIdentifier','terminal:tx2','receiveTerminalIdentifier','terminal:rx2', ...
    'transmitAntennaIdentifier','antenna:tx2','receiveAntennaIdentifier','antenna:rx2', ...
    'transmitPhaseCentreOffset_body_m',txArm,'receivePhaseCentreOffset_body_m',rxArm);

ownerProvider = revgnss.OwnerLocalEstimatorEndpointProvider.fromLocalSimulation(sim1,1,epoch_s,ownerTerminal);
diagnosticProduct2 = revgnss.EndpointStateProduct.fromLocalEstimator( ...
    sim2,2,epoch_s,0,'spacecraft:2:epoch:fourtimestamp-jacobian-test');
commonSourceTreatment = struct('towerClockProduct','rejected','terminalCalibration','rejected', ...
    'transmittedStateProduct','rejected','sessionTimingProduct','rejected', ...
    'sharedForceAtmosphericProduct','rejected');
eligibleProduct2 = revgnss.EstimatorEligibleEndpointStateProduct.fromDiagnosticProduct( ...
    diagnosticProduct2,commonSourceTreatment);
remoteProvider = revgnss.FrozenProductEndpointProvider.fromEstimatorEligibleProduct( ...
    eligibleProduct2,epoch_s,remoteTerminal);

ownerState = revgnss.CommunicationEndpointStateProvider.requireStateAt(ownerProvider,epoch_s);
remoteState = revgnss.CommunicationEndpointStateProvider.requireStateAt(remoteProvider,epoch_s);

hardware = revgnss.ReciprocalLinkHardwareModel('parameterSource','calibrationProduct', ...
    'physicalChainIdentifier','chain:fourtimestamp-jacobian-test', ...
    'calibrationProductIdentifier','cal:fourtimestamp-jacobian-test:001', ...
    'turnaroundProperTime_s',1e-3,'originTerminalGroupDelay_s',2e-7,'anchorTerminalGroupDelay_s',3e-7);

steps = revgnss.FourTimestampObservableLinearization.DefaultLinearizationSteps;
ownerColumnSteps = [repmat(steps.positionStep_m,1,3),repmat(steps.velocityStep_mps,1,3), ...
    repmat(steps.attitudeStep_rad,1,3),0,0,0,steps.clockBiasStep_m,steps.clockDriftStep_mps];
remoteColumnSteps = ownerColumnSteps;

fixture = struct('cfg',cfg,'sim1',sim1,'sim2',sim2,'ownerState',ownerState,'remoteState',remoteState, ...
    'hardware',hardware,'t4_s',epoch_s,'ownerColumnSteps',ownerColumnSteps, ...
    'remoteColumnSteps',remoteColumnSteps,'txArm',txArm,'rxArm',rxArm);
end

% ================================================================================================
function oracleH = i_oracleJacobian_(fixture, role, columnSteps)
% Independent oracle: for each of the 14 columns, perturb the SAME CommunicationEndpointState
% field the shipped path perturbs, rebuild BOTH endpoints' phase-centre position/velocity structs
% from scratch, and call revgnss.ConstantVelocityFourEventLightTimeOracle.solve directly --
% completely independent of revgnss.ReciprocalTimestampEventModel,
% revgnss.FourTimestampObservableBuilder, and revgnss.FourTimestampObservableLinearization's own
% production code.
c = revgnss.Constants.SPEED_OF_LIGHT_MPS;
oracleH = zeros(1,14);
for k = 1:14
    step = columnSteps(k);
    if step == 0
        continue % angularRate columns: declared zero, not oracle-checked (no rotation-rate model exists)
    end
    plus = i_perturbedPrediction_(fixture,role,k,step,c);
    minus = i_perturbedPrediction_(fixture,role,k,-step,c);
    plus2 = i_perturbedPrediction_(fixture,role,k,2*step,c);
    minus2 = i_perturbedPrediction_(fixture,role,k,-2*step,c);
    oracleH(k) = (-plus2+8*plus-8*minus+minus2)/(12*step);
end
end

function value_m = i_perturbedPrediction_(fixture, role, columnIdx, delta, c)
ownerState = fixture.ownerState;
remoteState = fixture.remoteState;
% Attitude perturbation convention (columns 7-9) is resolved from the endpoint's OWN declared
% attitudeErrorCoordinateConvention, matching what revgnss.FourTimestampObservableLinearization's
% own columnPerturbationKinds_ dispatches on -- NOT assumed to be plain-additive Euler. This
% fixture's default masterConfig sets cfg.estimator.attitude.parameterization=
% 'quaternionErrorState' (config/masterConfig.m:239), which
% revgnss.OwnerLocalEstimatorEndpointProvider maps to 'rightMultiplicativeLocalTangent_rad'
% (+revgnss/OwnerLocalEstimatorEndpointProvider.m:112-116) -- a tangent-space perturbation via
% revgnss.AttitudeErrorStateKinematics.smallAnglePerturbedDcm (a general, pre-existing kinematics
% primitive the MEKF itself uses, not part of what this test verifies -- reused here exactly as
% tests/test_coherent_two_way_code_physical_jacobian.m's own oracle reuses
% models.frames.FrameTimeUtils/revgnss.AttitudeKinematics directly), never a naive Euler bump.
eciFactor = models.frames.FrameTimeUtils.rotMatEcefToInertial(fixture.t4_s);
if strcmp(role,'owner')
    [position_m,velocity_mps,clockBias_m,clockDrift_mps] = i_perturbedComponents_(ownerState,columnIdx,delta);
    rotationSelf = eciFactor*i_perturbedRotation_(ownerState,columnIdx,delta);
    rotationOther = eciFactor*i_perturbedRotation_(remoteState,0,0);
    otherState = remoteState;
else
    [position_m,velocity_mps,clockBias_m,clockDrift_mps] = i_perturbedComponents_(remoteState,columnIdx,delta);
    rotationSelf = eciFactor*i_perturbedRotation_(remoteState,columnIdx,delta);
    rotationOther = eciFactor*i_perturbedRotation_(ownerState,0,0);
    otherState = ownerState;
end
% This test always calls islTwoEndpointJacobian with ownerRole='origin', so 'owner' role here
% always maps to origin (A) and 'remote' always maps to destination (B) -- resolved directly
% below via strcmp(role,'owner') rather than via a separate ownerIsOrigin flag.

[rSelf_m,vSelf_mps] = models.frames.FrameTimeUtils.ecefStateToInertial(position_m,velocity_mps, ...
    fixture.t4_s);
[rOther_m,vOther_mps] = models.frames.FrameTimeUtils.ecefStateToInertial( ...
    otherState.positionEcef_m,otherState.velocityEcef_mps,fixture.t4_s);

txArmSelf = rotationSelf*fixture.txArm; rxArmSelf = rotationSelf*fixture.rxArm;
txArmOther = rotationOther*fixture.txArm; rxArmOther = rotationOther*fixture.rxArm;

if strcmp(role,'owner')
    rA_tx = rSelf_m+txArmSelf; rA_rx = rSelf_m+rxArmSelf; vA = vSelf_mps;
    rB_rx = rOther_m+rxArmOther; rB_tx = rOther_m+txArmOther; vB = vOther_mps;
else
    rA_tx = rOther_m+txArmOther; rA_rx = rOther_m+rxArmOther; vA = vOther_mps;
    rB_rx = rSelf_m+rxArmSelf; rB_tx = rSelf_m+txArmSelf; vB = vSelf_mps;
end
% Origin (A) = owner (this test always calls islTwoEndpointJacobian with ownerRole='origin');
% Destination (B) = remote. Resolve clock bias/drift for whichever side was perturbed directly.
if strcmp(role,'owner')
    biasOrigin_m = clockBias_m; driftOrigin_mps = clockDrift_mps;
    biasDest_m = remoteState.clockBias_m; driftDest_mps = remoteState.clockDriftRate_mps;
else
    biasOrigin_m = ownerState.clockBias_m; driftOrigin_mps = ownerState.clockDriftRate_mps;
    biasDest_m = clockBias_m; driftDest_mps = clockDrift_mps;
end

turnaround_s = fixture.hardware.turnaroundProperTime_s; % properTimeRate~1 to first order at LEO/GEO speeds is NOT assumed here
% properRateB MUST use B's own CENTRE position/velocity (rCentreB/vCentreB), never a lever-arm-
% shifted phase-centre position: production's properTimeRate is computed exactly once, at
% endpoint construction, from the centre state only (FourTimestampEstimatorEndpointBridge.
% properTimeRate_(rI,vI), called on rI/vI straight out of ecefStateToInertial, before any
% offset_body_m is ever applied) -- using rB_rx/vB here (this oracle's lever-arm-shifted position)
% would silently make properRateB depend on the destination's own attitude, which production's
% properTimeRate never does.
if strcmp(role,'owner')
    rCentreB = rOther_m; vCentreB = vOther_mps;
else
    rCentreB = rSelf_m; vCentreB = vSelf_mps;
end
properRateB = 1-(3.986004418e14/norm(rCentreB)+0.5*dot(vCentreB,vCentreB))/c^2;

spec.referenceCoordinateTime_s = fixture.t4_s;
spec.finalReceptionCoordinateTime_s = fixture.t4_s;
spec.coordinateTurnaroundDelay_s = turnaround_s/properRateB;
spec.initiatorTransmit = struct('positionAtReference_m',rA_tx,'velocity_mps',vA);
spec.initiatorReceive = struct('positionAtReference_m',rA_rx,'velocity_mps',vA);
spec.transponderReceive = struct('positionAtReference_m',rB_rx,'velocity_mps',vB);
spec.transponderTransmit = struct('positionAtReference_m',rB_tx,'velocity_mps',vB);
events = revgnss.ConstantVelocityFourEventLightTimeOracle.solve(spec);

biasOrigin_s = biasOrigin_m/c; rateOrigin = 1+driftOrigin_mps/c;
biasDest_s = biasDest_m/c; rateDest = 1+driftDest_mps/c;
t4_s = fixture.t4_s;
% localTimeAt(t) = t4_s + bias_s + rate*(t-t4_s) (reference epoch is t4_s throughout this fixture)
tag1 = t4_s + biasOrigin_s + rateOrigin*(events.t1_s-t4_s);
tag2 = t4_s + biasDest_s + rateDest*(events.t2_s-t4_s);
tag3 = t4_s + biasDest_s + rateDest*(events.t3_s-t4_s);
tag4 = t4_s + biasOrigin_s + rateOrigin*(events.t4_s-t4_s);

originDelay_s = fixture.hardware.originTerminalGroupDelay_s;
anchorDelay_s = fixture.hardware.anchorTerminalGroupDelay_s;
% receiveEvent allocation (this fixture's default): tags + [0, anchorDelay, 0, originDelay]
tag2 = tag2 + anchorDelay_s;
tag4 = tag4 + originDelay_s;

value_s = 0.5*((tag2-tag1)-(tag4-tag3));
value_m = c*value_s;
end

function rotation = i_perturbedRotation_(endpointState, columnIdx, delta)
% Rebuilds the BODY->ECEF rotation only (the caller separately left-multiplies by the ECEF->ECI
% factor to get body->inertial, matching FourTimestampEstimatorEndpointBridge.buildEstimatorEndpoint_'s
% own bodyToInertial = rotMatEcefToInertial(t0) * bodyToEcefRotation composition -- associativity
% makes applying the tangent perturbation before or after that left-multiplication equivalent).
% Unperturbed unless columnIdx is one of the 3 attitude columns (7-9), in which case a right-
% multiplicative tangent-space perturbation is applied -- matching this fixture's actual
% attitudeErrorCoordinateConvention ('rightMultiplicativeLocalTangent_rad', see
% i_perturbedPrediction_'s header comment).
nominalRotation = revgnss.AttitudeKinematics.bodyToEcefRotation(endpointState.attitudeEulerZyx_rad);
if columnIdx >= 7 && columnIdx <= 9
    axisIdx = columnIdx-6;
    deltaTheta_rad = zeros(3,1); deltaTheta_rad(axisIdx) = delta;
    rotation = revgnss.AttitudeErrorStateKinematics.smallAnglePerturbedDcm(nominalRotation,deltaTheta_rad);
else
    rotation = nominalRotation;
end
end

function [position_m,velocity_mps,clockBias_m,clockDrift_mps] = ...
        i_perturbedComponents_(endpointState, columnIdx, delta)
position_m = endpointState.positionEcef_m;
velocity_mps = endpointState.velocityEcef_mps;
clockBias_m = endpointState.clockBias_m;
clockDrift_mps = endpointState.clockDriftRate_mps;
if columnIdx <= 3
    position_m(columnIdx) = position_m(columnIdx)+delta;
elseif columnIdx <= 6
    velocity_mps(columnIdx-3) = velocity_mps(columnIdx-3)+delta;
elseif columnIdx == 13
    clockBias_m = clockBias_m+delta;
elseif columnIdx == 14
    clockDrift_mps = clockDrift_mps+delta;
end
end
