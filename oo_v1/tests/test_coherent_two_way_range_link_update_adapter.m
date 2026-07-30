function test_coherent_two_way_range_link_update_adapter()
% test_coherent_two_way_range_link_update_adapter  Plan Section 2.3.1: real end-to-end exercise
% of revgnss.CoherentTwoWayRangeLinkUpdateAdapter against the REAL production data flow (real
% revgnss.ReverseGNSSSimulation instances, real revgnss.OwnerLocalEstimatorEndpointProvider /
% revgnss.FrozenProductEndpointProvider, real revgnss.LinkObservationDelivery.propose, real
% revgnss.DistributedLinkUpdateAdapter.requireUpdateBlock), same style/fixture conventions as
% tests/test_stage2_communication_interfaces.m. Nothing here makes
% distributedEstimator.linkUpdate reachable end-to-end through the coordinator; no scenario JSON
% or masterConfig.m is read or written.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
addpath(rootDir);
addpath(fullfile(rootDir,'config'));
addpath(fullfile(rootDir,'config','internal'));

fprintf('=== test_coherent_two_way_range_link_update_adapter ===\n');
i_test_real_delivery_end_to_end_contract_compliance_();
i_test_jacobian_independent_finite_difference_oracle_();
i_test_attitude_tangent_vs_euler_anti_conflation_();
i_test_declared_zero_sensitivity_and_structure_();
fprintf('=== test_coherent_two_way_range_link_update_adapter: ALL PASS ===\n');
end

% ================================================================================================
function i_test_real_delivery_end_to_end_contract_compliance_()
% Builds a REAL revgnss.LinkObservationDelivery via propose() (not a hand-rolled struct), REAL
% CommunicationEndpointState objects via the real providers, calls the adapter's buildUpdateBlock,
% and confirms the resulting block passes the FULL DistributedLinkUpdateAdapter.requireUpdateBlock
% contract check -- proving the adapter plugs into the real production pipeline, not a synthetic
% shortcut.
fixture = i_fixture_();

[block, diagnostics] = revgnss.CoherentTwoWayRangeLinkUpdateAdapter.buildUpdateBlock(fixture.buildArgs);
assert(isa(block,'revgnss.DistributedLinkUpdateBlock'));
revgnss.DistributedLinkUpdateAdapter.requireUpdateBlock( ...
    block, fixture.delivery, fixture.ownerState, fixture.remoteState);

assert(strcmp(block.observableIdentifier,'coherentTwoWayCodeRange'));
assert(strcmp(block.correlationPolicy,'splitCovarianceIntersection'));
expectedResidual = fixture.delivery.physicalObservationRecord.processedValue - diagnostics.predictedRange_m;
assert(abs(block.residual_m - expectedResidual) < 1e-9, ...
    'residual_m must equal record.processedValue - predictedRange_m exactly.');

Hremote = block.remoteJacobian_mPerErrorUnit;
expectedRemoteContribution = Hremote * fixture.remoteState.covarianceBlock * Hremote';
scale = max(1,norm(expectedRemoteContribution,'fro'));
assert(norm(block.remoteContributionCovariance_m2-expectedRemoteContribution,'fro') <= 1e-9*scale, ...
    'remoteContributionCovariance_m2 must equal H_remote*P_remote*H_remote'' exactly.');

% Truth-free by construction: the adapter never touches truth (no SpaceAsset/clock/truth handle
% anywhere in its inputs) -- verified here by source inspection of the class file itself.
adapterSource = fileread(which('revgnss.CoherentTwoWayRangeLinkUpdateAdapter'));
forbidden = {'SpaceAsset','truthDiagnostic','ReverseGNSSSimulation','physicalTruth'};
for idx = 1:numel(forbidden)
    assert(~contains(adapterSource,forbidden{idx}), ...
        'The adapter source must never reference %s.',forbidden{idx});
end

fprintf('  PASS real_delivery_end_to_end_contract_compliance\n');
end

% ================================================================================================
function i_test_jacobian_independent_finite_difference_oracle_()
% INDEPENDENT oracle: this test builds its OWN 5-point stencil directly against
% predictProcessedRangeFromEndpointStates, perturbing the SAME CommunicationEndpointState fields
% the adapter perturbs but via a completely separate code path (no use of the adapter's own
% jacobianRow_/columnPerturbationKinds/stepAndPerturbFn_ dispatch), and compares the result to
% block.ownerJacobian_mPerErrorUnit / remoteJacobian_mPerErrorUnit.
fixture = i_fixture_();
[block, ~] = revgnss.CoherentTwoWayRangeLinkUpdateAdapter.buildUpdateBlock(fixture.buildArgs);

steps = fixture.buildArgs.linearizationSteps;
stepSizes = [repmat(steps.positionStep_m,1,3), repmat(steps.velocityStep_mps,1,3), ...
    repmat(steps.attitudeStep_rad,1,3), NaN(1,3), steps.clockBiasStep_m, steps.clockDriftStep_mps];

Howner_oracle = i_ownSidedFiveStencil_(fixture,'owner',stepSizes);
Hremote_oracle = i_ownSidedFiveStencil_(fixture,'remote',stepSizes);

i_assertJacobianClose_(block.ownerJacobian_mPerErrorUnit,Howner_oracle,'owner');
i_assertJacobianClose_(block.remoteJacobian_mPerErrorUnit,Hremote_oracle,'remote');
fprintf('  PASS jacobian_independent_finite_difference_oracle\n');
end

function i_assertJacobianClose_(shipped, oracle, label)
for k = [1:9,13,14]
    scale = max(1,abs(oracle(k)));
    assert(abs(shipped(k)-oracle(k)) <= 1e-5*scale, ...
        '%s column %d: shipped=%.8g oracle=%.8g disagree beyond tolerance.',label,k,shipped(k),oracle(k));
end
end

function H = i_ownSidedFiveStencil_(fixture, role, stepSizes)
if strcmp(role,'owner')
    baseState = fixture.ownerState; otherState = fixture.remoteState;
    ownerIdentifier = fixture.delivery.ownerRecordEndpointIdentifier;
    remoteIdentifier = fixture.delivery.remoteRecordEndpointIdentifier;
else
    baseState = fixture.remoteState; otherState = fixture.ownerState;
    ownerIdentifier = fixture.delivery.ownerRecordEndpointIdentifier;
    remoteIdentifier = fixture.delivery.remoteRecordEndpointIdentifier;
end
otherModel = revgnss.CoherentTwoWayRangeLinkUpdateAdapter.estimatorEndpointModelFromState( ...
    otherState, i_otherIdentifier_(role,ownerIdentifier,remoteIdentifier));

H = zeros(1,14);
for k = 1:14
    if k >= 10 && k <= 12
        H(k) = 0; % angular rate: declared and structurally zero, checked separately
        continue
    end
    step = stepSizes(k);
    h = @(delta) i_predictAtColumnDelta_(fixture,role,baseState,otherModel,k,delta, ...
        ownerIdentifier,remoteIdentifier);
    hp2 = h(2*step); hp1 = h(step); hm1 = h(-step); hm2 = h(-2*step);
    H(k) = (-hp2+8*hp1-8*hm1+hm2)/(12*step);
end
end

function identifier = i_otherIdentifier_(role, ownerIdentifier, remoteIdentifier)
if strcmp(role,'owner')
    identifier = remoteIdentifier;
else
    identifier = ownerIdentifier;
end
end

function value = i_predictAtColumnDelta_(fixture, role, baseState, otherModel, columnIdx, delta, ...
    ownerIdentifier, remoteIdentifier)
pos = baseState.positionEcef_m;
vel = baseState.velocityEcef_mps;
euler = baseState.attitudeEulerZyx_rad;
bias = baseState.clockBias_m;
drift = baseState.clockDriftRate_mps;
if columnIdx <= 3
    pos = pos + delta*i_e_(columnIdx,3);
elseif columnIdx <= 6
    vel = vel + delta*i_e_(columnIdx-3,3);
elseif columnIdx <= 9
    if strcmp(baseState.attitudeErrorCoordinateConvention,'rightMultiplicativeLocalTangent_rad')
        Cnominal = revgnss.AttitudeKinematics.bodyToEcefRotation(euler);
        Cpert = revgnss.AttitudeErrorStateKinematics.smallAnglePerturbedDcm( ...
            Cnominal,delta*i_e_(columnIdx-6,3));
        rotationOverride = Cpert;
    else
        euler = euler + delta*i_e_(columnIdx-6,3);
        rotationOverride = [];
    end
elseif columnIdx == 13
    bias = bias + delta;
elseif columnIdx == 14
    drift = drift + delta;
end

if columnIdx >= 7 && columnIdx <= 9 && strcmp(baseState.attitudeErrorCoordinateConvention, ...
        'rightMultiplicativeLocalTangent_rad')
    rotation = rotationOverride;
else
    rotation = revgnss.AttitudeKinematics.bodyToEcefRotation(euler);
end

if strcmp(role,'owner')
    identifier = ownerIdentifier;
else
    identifier = remoteIdentifier;
end
perturbedModel = i_buildModelDirect_(baseState, identifier, pos, vel, rotation, bias, drift);
if strcmp(role,'owner')
    initiatorModel = perturbedModel; transponderModel = otherModel;
else
    initiatorModel = otherModel; transponderModel = perturbedModel;
end
record = i_fixture_record_placeholder_();
[value, ~] = revgnss.CoherentTwoWayCodeRangingModel.predictProcessedRange( ...
    record, initiatorModel, transponderModel, i_fixture_calibration_placeholder_(), struct(), 0);
end

function e = i_e_(idx,n)
e = zeros(n,1); e(idx) = 1;
end

function endpointModel = i_buildModelDirect_(endpointState, recordEndpointIdentifier, ...
        positionEcef_m, velocityEcef_mps, bodyToEcefRotation, clockBias_m, clockDriftRate_mps)
% Independent re-implementation of the same ECEF->ECI bridge, deliberately NOT calling the
% adapter's own buildEndpointModel_ (private), so this oracle shares no code path with the
% adapter's column loop beyond the physics classes both must legitimately reuse.
t0 = endpointState.coordinateEpoch_s;
[rI, vI] = models.frames.FrameTimeUtils.ecefStateToInertial(positionEcef_m, velocityEcef_mps, t0);
bodyToInertial = models.frames.FrameTimeUtils.rotMatEcefToInertial(t0) * bodyToEcefRotation;
c = revgnss.CoherentTwoWayCodeRangingModel.SpeedOfLight_mps;
bias_s = clockBias_m / c;
localClockRate = 1 + clockDriftRate_mps / c;
radius_m = norm(rI);
properTimeRate = 1 - (revgnss.Constants.EARTH_GM_M3PS2/radius_m + 0.5*dot(vI,vI))/c^2;
terminal = endpointState.terminalGeometry;
endpointModel = revgnss.TwoWayCodeEndpointModel.constantVelocity( ...
    'estimatorState', recordEndpointIdentifier, rI, vI, t0, ...
    bodyToInertialRotation=bodyToInertial, ...
    transmitPhaseCentreOffset_body_m=terminal.transmitPhaseCentreOffset_body_m, ...
    receivePhaseCentreOffset_body_m=terminal.receivePhaseCentreOffset_body_m, ...
    transmitTerminalIdentifier=terminal.transmitTerminalIdentifier, ...
    receiveTerminalIdentifier=terminal.receiveTerminalIdentifier, ...
    transmitAntennaIdentifier=terminal.transmitAntennaIdentifier, ...
    receiveAntennaIdentifier=terminal.receiveAntennaIdentifier, ...
    clockLocalTimeAtReference_s=t0+bias_s, ...
    localClockRate=localClockRate, ...
    properTimeRate=properTimeRate);
end

% i_fixture_record_placeholder_/i_fixture_calibration_placeholder_ are set by i_fixture_ into
% persistent storage so the oracle helpers above (which must match the adapter's own call
% signature shape) can reach the SAME record/calibration product without threading them through
% every stencil call site.
function record = i_fixture_record_placeholder_()
record = i_fixtureCache_('get_record');
end
function calibrationProduct = i_fixture_calibration_placeholder_()
calibrationProduct = i_fixtureCache_('get_calibration');
end
function out = i_fixtureCache_(action, value)
persistent cache
if strcmp(action,'set_record')
    cache.record = value; out = [];
elseif strcmp(action,'set_calibration')
    cache.calibration = value; out = [];
elseif strcmp(action,'get_record')
    out = cache.record;
elseif strcmp(action,'get_calibration')
    out = cache.calibration;
end
end

function T = i_eulerRateMatrix_(euler_rad)
% i_eulerRateMatrix_  T such that d(euler)/dt = T*omega_body (ZYX sequence), reproduced directly
% from revgnss.AttitudeKinematics.eulerRatesFromBodyRates's own documented formula -- an
% independent restatement, not a call into the adapter or into that function itself.
roll = euler_rad(1); pitch = euler_rad(2);
cr = cos(roll); sr = sin(roll); cp = cos(pitch); tp = tan(pitch);
T = [1, sr*tp, cr*tp; 0, cr, -sr; 0, sr/cp, cr/cp];
end

% ================================================================================================
function i_test_attitude_tangent_vs_euler_anti_conflation_()
% Anti-conflation test: a deliberately large attitude (far from small-angle) with a nonzero
% lever arm. The RIGOROUS check is analytic, not a magnitude guess: for ZYX Euler angles,
% delta_euler = T(euler)*delta_theta_body to first order (revgnss.AttitudeKinematics.
% eulerRatesFromBodyRates's own T matrix), so by the chain rule H_tangent = H_euler*T(euler),
% i.e. H_euler = H_tangent/T(euler) EXACTLY at this nominal attitude, regardless of the
% observable's own geometry. This is checked directly below -- a naive Euler-angle bump (i.e.
% an adapter that silently ignored the convention and used H_euler=H_tangent) would fail this
% assertion by exactly the gap between T(euler) and the identity matrix.
fixtureTangent = i_fixture_('rightMultiplicativeLocalTangent_rad', [0.6;-0.4;1.1]);
fixtureEuler = i_fixture_('eulerZYXError_rad', [0.6;-0.4;1.1]);

[blockTangent, ~] = revgnss.CoherentTwoWayRangeLinkUpdateAdapter.buildUpdateBlock(fixtureTangent.buildArgs);
[blockEuler, ~] = revgnss.CoherentTwoWayRangeLinkUpdateAdapter.buildUpdateBlock(fixtureEuler.buildArgs);

HtangentOwn = blockTangent.ownerJacobian_mPerErrorUnit(7:9);
HeulerOwn = blockEuler.ownerJacobian_mPerErrorUnit(7:9);

eulerNominal = fixtureTangent.ownerState.attitudeEulerZyx_rad;
assert(norm(eulerNominal-fixtureEuler.ownerState.attitudeEulerZyx_rad) < 1e-6, ...
    'Both fixtures must share the SAME nominal attitude for the analytic cross-check to be valid.');
Tmat = i_eulerRateMatrix_(eulerNominal);
HeulerPredicted = HtangentOwn / Tmat;
scale = max(1,norm(HeulerPredicted));
assert(norm(HeulerOwn-HeulerPredicted) <= 1e-3*scale, ...
    ['Euler-mode attitude columns must equal H_tangent/T(euler) (the analytic kinematic ' ...
    'transform), not H_tangent itself: predicted=%s shipped=%s.'], ...
    mat2str(HeulerPredicted,6),mat2str(HeulerOwn,6));

% Secondary, coarser sanity check: at this attitude T(euler) is far enough from identity that
% a naive (conflated) implementation -- one that shipped H_tangent unchanged as H_euler -- would
% miss the analytic prediction by a margin that is clearly not FD/estimation noise (which is
% orders of magnitude smaller, ~1e-5 relative for these step sizes).
diffFromNaive = norm(HtangentOwn-HeulerPredicted);
assert(diffFromNaive > 1e-3*scale, ...
    ['This attitude must be far enough from small-angle that a naive Euler bump (H_euler=H_tangent) ' ...
    'would be clearly distinguishable from the correct analytic prediction; got relative gap %.3e.'], ...
    diffFromNaive/scale);

% Each mode must match ITS OWN independent oracle (not the other mode's).
stepsT = fixtureTangent.buildArgs.linearizationSteps;
stepSizesT = [repmat(stepsT.positionStep_m,1,3), repmat(stepsT.velocityStep_mps,1,3), ...
    repmat(stepsT.attitudeStep_rad,1,3), NaN(1,3), stepsT.clockBiasStep_m, stepsT.clockDriftStep_mps];
i_fixtureCache_('set_record',fixtureTangent.delivery.physicalObservationRecord);
i_fixtureCache_('set_calibration',fixtureTangent.buildArgs.calibrationProduct);
HownerOracleTangent = i_ownSidedFiveStencil_(fixtureTangent,'owner',stepSizesT);
assert(norm(HownerOracleTangent(7:9)-HtangentOwn) <= 1e-4*max(1,norm(HtangentOwn)), ...
    'Tangent-mode columns must match the tangent-mode oracle.');

stepsE = fixtureEuler.buildArgs.linearizationSteps;
stepSizesE = stepSizesT;
i_fixtureCache_('set_record',fixtureEuler.delivery.physicalObservationRecord);
i_fixtureCache_('set_calibration',fixtureEuler.buildArgs.calibrationProduct);
HownerOracleEuler = i_ownSidedFiveStencil_(fixtureEuler,'owner',stepSizesE);
assert(norm(HownerOracleEuler(7:9)-HeulerOwn) <= 1e-4*max(1,norm(HeulerOwn)), ...
    'Euler-mode columns must match the Euler-mode oracle.');

fprintf('  PASS attitude_tangent_vs_euler_anti_conflation\n');
end

% ================================================================================================
function i_test_declared_zero_sensitivity_and_structure_()
fixture = i_fixture_();
[block, diagnostics] = revgnss.CoherentTwoWayRangeLinkUpdateAdapter.buildUpdateBlock(fixture.buildArgs);

assert(isequal(block.ownerJacobian_mPerErrorUnit(10:12),[0 0 0]), ...
    'Owner angular-rate columns must be exactly zero.');
assert(isequal(block.remoteJacobian_mPerErrorUnit(10:12),[0 0 0]), ...
    'Remote angular-rate columns must be exactly zero.');
% The transponder clock is never read by predictProcessedRange, so these columns are
% STRUCTURALLY zero -- but they are still computed via the generic finite-difference stencil
% (unlike angular rate, which is hard-set to literal 0), so the shipped value is round-off-scale
% relative to the predicted range, not necessarily bit-exact zero.
scaleRange = max(1,abs(diagnostics.predictedRange_m));
assert(abs(block.remoteJacobian_mPerErrorUnit(13)) < 1e-9*scaleRange && ...
    abs(block.remoteJacobian_mPerErrorUnit(14)) < 1e-9*scaleRange, ...
    'Remote clock bias/drift columns must be round-off-scale (the transponder clock never enters predictProcessedRange).');

% dRho/db_owner ~ rho_dot/c (bias cancels in the round trip up to relative range-rate) while
% dRho/dbdot_owner ~ 0.5*(tau_fwd+tau_ret) (the round-trip light time itself) -- the bias
% column is therefore always several orders smaller than the drift column, though the exact
% ratio depends on the fixture's own (small, formation-scale) relative range rate, so this is a
% relative-magnitude check, not a fixed physical constant.
Howner = block.ownerJacobian_mPerErrorUnit;
assert(abs(Howner(13)) < 1e-3*abs(Howner(14)), ...
    'Owner clock bias sensitivity must be negligible relative to clock drift sensitivity.');
assert(Howner(14) > 0,'Owner clock drift sensitivity must be positive.');

kinds = diagnostics.ownerColumnPerturbationKinds;
assert(strcmp(kinds{10},'angularRate') && strcmp(kinds{13},'clockBias') && strcmp(kinds{14},'clockDrift'));

fprintf('  PASS declared_zero_sensitivity_and_structure\n');
end

% ================================================================================================
function fixture = i_fixture_(attitudeConventionOverride, eulerOverride)
if nargin < 1
    attitudeConventionOverride = '';
end
cfg = i_baseConfig_();
if strcmp(attitudeConventionOverride,'eulerZYXError_rad')
    cfg.estimator.attitude.parameterization = 'eulerZYX';
    % Both inertial gyro aiding and star-tracker EKF rows require quaternionErrorState.
    cfg.estimator.imu.enable = false;
    cfg.estimator.starTracker.enable = false;
end
if nargin >= 2 && ~isempty(eulerOverride)
    % Drive the TRUTH attitude to a large, away-from-small-angle value, zero the initial
    % attitude ERROR, and disable IMU/star-tracker aiding on BOTH fixtures (not only the
    % Euler-mode one, which is REQUIRED to disable them) -- so the resulting EKF estimate
    % equals the large truth value EXACTLY on both sides, with no aiding-driven perturbation
    % on one side only, making the tangent-vs-Euler comparison a clean same-attitude
    % comparison rather than a comparison across two slightly different estimates.
    cfg.asset.attitude_euler_rad = eulerOverride(:);
    cfg.validation.manifest.attitude.initialError_deg = [0;0;0];
    cfg.estimator.imu.enable = false;
    cfg.estimator.starTracker.enable = false;
end

% Two independent leaves built from a COMMON fleet context (revgnss.IndependentFleetScenario
% Factory), exactly as the real independent-fleet coordinator constructs them -- this is what
% gives the two assets a genuine, non-degenerate helix-formation baseline (a naive pair of
% default single-asset configs distinguished only by physicalAssetIndex are co-located, since
% physicalAssetIndex alone does not select a distinct orbital slot).
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

leverArm = [0.8;0.2;0.3];
ownerTerminal = struct('declared',true, ...
    'transmitTerminalIdentifier','terminal:tx1','receiveTerminalIdentifier','terminal:rx1', ...
    'transmitAntennaIdentifier','antenna:tx1','receiveAntennaIdentifier','antenna:rx1', ...
    'transmitPhaseCentreOffset_body_m',leverArm,'receivePhaseCentreOffset_body_m',leverArm);
remoteTerminal = struct('declared',true, ...
    'transmitTerminalIdentifier','terminal:tx2','receiveTerminalIdentifier','terminal:rx2', ...
    'transmitAntennaIdentifier','antenna:tx2','receiveAntennaIdentifier','antenna:rx2', ...
    'transmitPhaseCentreOffset_body_m',leverArm,'receivePhaseCentreOffset_body_m',leverArm);

ownerProvider = revgnss.OwnerLocalEstimatorEndpointProvider.fromLocalSimulation(sim1,1,epoch_s,ownerTerminal);

diagnosticProduct2 = revgnss.EndpointStateProduct.fromLocalEstimator( ...
    sim2,2,epoch_s,0,'spacecraft:2:epoch:adapter-test');
commonSourceTreatment = struct('towerClockProduct','rejected','terminalCalibration','rejected', ...
    'transmittedStateProduct','rejected','sessionTimingProduct','rejected', ...
    'sharedForceAtmosphericProduct','rejected');
eligibleProduct2 = revgnss.EstimatorEligibleEndpointStateProduct.fromDiagnosticProduct( ...
    diagnosticProduct2,commonSourceTreatment);
remoteProvider = revgnss.FrozenProductEndpointProvider.fromEstimatorEligibleProduct( ...
    eligibleProduct2,epoch_s,remoteTerminal);

initiatorTruth = revgnss.TwoWayCodeEndpointModel.constantVelocity('physicalTruth','asset:1', ...
    [0;0;0],zeros(3,1),epoch_s, ...
    transmitTerminalIdentifier='terminal:tx1',receiveTerminalIdentifier='terminal:rx1', ...
    transmitAntennaIdentifier='antenna:tx1',receiveAntennaIdentifier='antenna:rx1', ...
    transmitPhaseCentreOffset_body_m=leverArm,receivePhaseCentreOffset_body_m=leverArm);
transponderTruth = revgnss.TwoWayCodeEndpointModel.constantVelocity('physicalTruth','asset:2', ...
    [5e5;0;0],zeros(3,1),epoch_s, ...
    transmitTerminalIdentifier='terminal:tx2',receiveTerminalIdentifier='terminal:rx2', ...
    transmitAntennaIdentifier='antenna:tx2',receiveAntennaIdentifier='antenna:rx2', ...
    transmitPhaseCentreOffset_body_m=leverArm,receivePhaseCentreOffset_body_m=leverArm);
physical = revgnss.CoherentTwoWayCodeHardwareModel(parameterSource='physicalTruth', ...
    physicalChainIdentifier='chain:adapter-test',calibrationProductIdentifier='cal:adapter-test:001', ...
    turnaroundProperTime_s=1e-6,codeRateTurnaroundRatio=1);
calibrationProduct = revgnss.CoherentTwoWayCodeHardwareModel(parameterSource='calibrationProduct', ...
    physicalChainIdentifier='chain:adapter-test',calibrationProductIdentifier='cal:adapter-test:001', ...
    turnaroundProperTime_s=1e-6,codeRateTurnaroundRatio=1);
observationId = sprintf('obs:adapter-test:%.0f',rand()*1e9);
metadata = struct('observationIdentifier',observationId, ...
    'sessionIdentifier','session:adapter-test','signalIdentifier','PN1', ...
    'covarianceGroupIdentifier',observationId,'covarianceRowIndex',1,'covarianceBlock_m2',0.0625, ...
    'carrierToNoiseDensity_dBHz',45,'available',true,'qualityFlags',struct('codeLock',true), ...
    'truthDiagnosticIdentifier','truth:adapter-test');
record = revgnss.CoherentTwoWayCodeRangingModel.simulateObservation( ...
    initiatorTruth,transponderTruth,physical,calibrationProduct,epoch_s,metadata,0);

registry = revgnss.DistributedLinkCalibrationRegistry();

args = struct( ...
    'physicalObservationRecord',record,'ownerProvider',ownerProvider,'remoteProvider',remoteProvider, ...
    'ownerPolicy','initiator','roleReversalPolicy','disabled', ...
    'remoteProductPropagationPolicy','frozenSameEpochOnly', ...
    'stateExchangeSettings',struct('maximumAge_s',0,'deliveryDelay_s',0), ...
    'outOfSequencePolicy','reject','commonSourceTreatment',commonSourceTreatment, ...
    'correlationPolicy','splitCovarianceIntersection','calibrationRegistry',registry, ...
    'deliveryEpoch_s',epoch_s,'coordinateEventEpoch_s',epoch_s, ...
    'observableIdentifier','coherentTwoWayCodeRange','persistentCalibrationTreatment','rejected');
delivery = revgnss.LinkObservationDelivery.propose(args);

ownerState = revgnss.CommunicationEndpointStateProvider.requireStateAt(ownerProvider,epoch_s);
remoteState = revgnss.CommunicationEndpointStateProvider.requireStateAt(remoteProvider,epoch_s);

linearizationSteps = struct('positionStep_m',0.5,'velocityStep_mps',0.05, ...
    'attitudeStep_rad',5e-4,'clockBiasStep_m',10,'clockDriftStep_mps',0.01);
buildArgs = struct( ...
    'delivery',delivery,'ownerState',ownerState,'remoteState',remoteState, ...
    'calibrationProduct',calibrationProduct,'linearizationSteps',linearizationSteps, ...
    'solverOptions',struct(),'modeledPropagationGroupDelay_s',0, ...
    'weightSelectionRule','fixedDeclaredWeights','persistentCalibrationTreatment','rejected');

i_fixtureCache_('set_record',record);
i_fixtureCache_('set_calibration',calibrationProduct);

fixture = struct('sim1',sim1,'sim2',sim2,'delivery',delivery,'ownerState',ownerState, ...
    'remoteState',remoteState,'buildArgs',buildArgs);
end

function cfg = i_baseConfig_()
cfg = masterConfig();
cfg.simulation.duration_s = 4;
cfg.simulation.dt_s = 1;
cfg.report.writePdf = false;
cfg.report.writeMat = false;
cfg.report.compileTex = 'never';
cfg.plots.enable = false;
cfg.plots.showFigures = false;
end
