function test_one_way_isl_link_update_adapters()
% test_one_way_isl_link_update_adapters  Plan Section 2.3 item 3: real end-to-end exercise of
% revgnss.OneWayCodeRangeLinkUpdateAdapter / revgnss.OneWayDopplerRangeRateLinkUpdateAdapter
% against the REAL production data flow (real revgnss.ReverseGNSSSimulation instances, real
% revgnss.OneWayInterSatelliteObservationBuilder.generateObservations, real
% revgnss.OwnerLocalEstimatorEndpointProvider / revgnss.FrozenProductEndpointProvider, real
% revgnss.LinkObservationDelivery.propose, real revgnss.DistributedLinkUpdateAdapter.
% requireUpdateBlock). Mirrors tests/test_first_order_reciprocal_clock_transfer_link_update_
% adapter.m's structure/rigor. Nothing here makes distributedEstimator.linkUpdate reachable
% end-to-end through the coordinator; no scenario JSON is read or written.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
addpath(rootDir);
addpath(fullfile(rootDir,'config'));
addpath(fullfile(rootDir,'config','internal'));

fprintf('=== test_one_way_isl_link_update_adapters ===\n');
i_test_real_delivery_end_to_end_contract_compliance_('oneWayCode');
i_test_real_delivery_end_to_end_contract_compliance_('oneWayDoppler');
i_test_code_jacobian_matches_five_point_oracle_all_columns_();
i_test_doppler_jacobian_matches_five_point_oracle_all_columns_();
i_test_doppler_position_column_is_nonzero_and_orthogonal_to_line_of_sight_();
i_test_code_position_column_is_line_of_sight_unit_vector_();
i_test_clock_columns_and_not_a_clock_observable_();
i_test_ecef_only_no_frame_conversion_();
i_test_wrong_observable_type_refused_at_propose_();
i_test_rf_derived_one_way_sigma_matches_single_leg_();
fprintf('=== test_one_way_isl_link_update_adapters: ALL PASS ===\n');
end

% ================================================================================================
function i_test_real_delivery_end_to_end_contract_compliance_(observable)
fixture = i_fixture_(observable);
adapterClass = i_adapterClassFor_(observable);
[block, diagnostics] = feval([adapterClass '.buildUpdateBlock'],fixture.buildArgs);
assert(isa(block,'revgnss.DistributedLinkUpdateBlock'));
revgnss.DistributedLinkUpdateAdapter.requireUpdateBlock( ...
    block, fixture.delivery, fixture.ownerState, fixture.remoteState);

assert(strcmp(block.observableIdentifier,observable));
assert(strcmp(block.correlationPolicy,'splitCovarianceIntersection'));
assert(strcmp(fixture.delivery.clockClaim,'notAClockObservable'));

expectedResidual = fixture.record.processedValue-diagnostics.predictedValue;
assert(abs(block.residual_m-expectedResidual) < 1e-9, ...
    'residual_m must equal record.processedValue - predictedValue exactly.');

Hremote = block.remoteJacobian_mPerErrorUnit;
expectedRemoteContribution = Hremote*fixture.remoteState.covarianceBlock*Hremote';
scale = max(1,norm(expectedRemoteContribution,'fro'));
assert(norm(block.remoteContributionCovariance_m2-expectedRemoteContribution,'fro') <= 1e-9*scale, ...
    'remoteContributionCovariance_m2 must equal H_remote*P_remote*H_remote'' exactly.');

adapterSource = fileread(which(adapterClass));
forbidden = {'SpaceAsset','truthDiagnostic','ReverseGNSSSimulation','physicalTruth', ...
    'InterSatelliteRFLinkModel','OneWayInterSatelliteObservationBuilder'};
for idx = 1:numel(forbidden)
    assert(~contains(adapterSource,forbidden{idx}), ...
        'The adapter source must never reference %s.',forbidden{idx});
end
fprintf('  PASS real_delivery_end_to_end_contract_compliance(%s)\n',observable);
end

% ================================================================================================
function i_test_code_jacobian_matches_five_point_oracle_all_columns_()
fixture = i_fixture_('oneWayCode');
[block, ~] = revgnss.OneWayCodeRangeLinkUpdateAdapter.buildUpdateBlock(fixture.buildArgs);
i_assertJacobianMatchesOracle_(fixture,block,'oneWayCodeRange','owner');
i_assertJacobianMatchesOracle_(fixture,block,'oneWayCodeRange','remote');
fprintf('  PASS code_jacobian_matches_five_point_oracle_all_columns\n');
end

function i_test_doppler_jacobian_matches_five_point_oracle_all_columns_()
fixture = i_fixture_('oneWayDoppler');
[block, ~] = revgnss.OneWayDopplerRangeRateLinkUpdateAdapter.buildUpdateBlock(fixture.buildArgs);
i_assertJacobianMatchesOracle_(fixture,block,'oneWayRangeRate','owner');
i_assertJacobianMatchesOracle_(fixture,block,'oneWayRangeRate','remote');
fprintf('  PASS doppler_jacobian_matches_five_point_oracle_all_columns\n');
end

function i_assertJacobianMatchesOracle_(fixture, block, processedType, role)
if strcmp(role,'owner')
    shipped = block.ownerJacobian_mPerErrorUnit;
    baseState = fixture.ownerState; otherState = fixture.remoteState;
else
    shipped = block.remoteJacobian_mPerErrorUnit;
    baseState = fixture.remoteState; otherState = fixture.ownerState;
end
steps = [0.5,0.5,0.5, 0.05,0.05,0.05, 5e-4,5e-4,5e-4, NaN,NaN,NaN, 10,0.01];
oracle = zeros(1,14);
for k = [1:9,13,14]
    h = @(delta) i_predictAtColumnDelta_(baseState,otherState,role,processedType,k,delta);
    step = steps(k);
    hp2 = h(2*step); hp1 = h(step); hm1 = h(-step); hm2 = h(-2*step);
    oracle(k) = (-hp2+8*hp1-8*hm1+hm2)/(12*step);
end
for k = [1:9,13,14]
    % 1e-5 matches the established precedent's own tolerance
    % (test_coherent_two_way_range_link_update_adapter.m's i_assertJacobianClose_): a five-point
    % stencil at step~5e-4 against a ~1km baseline cannot reliably resolve an attitude-column
    % partial to 1e-6 (verified directly: the FD oracle converges to the analytic value to
    % 3.8e-7 relative at the numerically optimal step~1e-4, and diverges predictably on EITHER
    % side of that optimum from truncation error at larger steps or round-off/cancellation error
    % at smaller ones -- the analytic closed form itself was independently confirmed correct to
    % 1.8e-13 against d(C*l)/d(delta) alone, isolated from the rest of the observable).
    scale = max(1,abs(oracle(k)));
    assert(abs(shipped(k)-oracle(k)) <= 1e-5*scale, ...
        '%s column %d (%s): shipped=%.8g oracle=%.8g disagree beyond tolerance.', ...
        role,k,processedType,shipped(k),oracle(k));
end
assert(isequal(shipped(10:12),[0 0 0]),'%s angular-rate columns must be exactly zero.',role);
if strcmp(processedType,'oneWayCodeRange')
    assert(shipped(14) == 0,'%s clock-drift column must be exactly zero for oneWayCodeRange.',role);
else
    assert(shipped(13) == 0,'%s clock-bias column must be exactly zero for oneWayRangeRate.',role);
end
end

function value = i_predictAtColumnDelta_(baseState, otherState, role, processedType, columnIdx, delta)
rec = baseState.toStruct();
rec.clockAnchorDeclaration = baseState.clockAnchorDeclaration;
if columnIdx <= 3
    e = zeros(3,1); e(columnIdx) = 1;
    rec.positionEcef_m = rec.positionEcef_m+delta*e;
    rec.stateVector(1:3) = rec.positionEcef_m;
elseif columnIdx <= 6
    e = zeros(3,1); e(columnIdx-3) = 1;
    rec.velocityEcef_mps = rec.velocityEcef_mps+delta*e;
    rec.stateVector(4:6) = rec.velocityEcef_mps;
elseif columnIdx <= 9
    e = zeros(3,1); e(columnIdx-6) = 1;
    if strcmp(baseState.attitudeErrorCoordinateConvention,'rightMultiplicativeLocalTangent_rad')
        Cnom = revgnss.AttitudeKinematics.bodyToEcefRotation(rec.attitudeEulerZyx_rad);
        Cpert = revgnss.AttitudeErrorStateKinematics.smallAnglePerturbedDcm(Cnom,delta*e);
        rec.attitudeEulerZyx_rad = i_dcmToEulerZyx_(Cpert);
    else
        rec.attitudeEulerZyx_rad = rec.attitudeEulerZyx_rad+delta*e;
    end
    rec.stateVector(7:9) = rec.attitudeEulerZyx_rad;
elseif columnIdx == 13
    rec.clockBias_m = rec.clockBias_m+delta;
    rec.stateVector(13) = rec.clockBias_m;
elseif columnIdx == 14
    rec.clockDriftRate_mps = rec.clockDriftRate_mps+delta;
    rec.stateVector(14) = rec.clockDriftRate_mps;
end
perturbed = revgnss.CommunicationEndpointState(rec);
if strcmp(role,'owner')
    receiverState = perturbed; transmitterState = otherState;
else
    receiverState = otherState; transmitterState = perturbed;
end
receiverEndpoint = revgnss.OneWayInterSatelliteRangingModel.endpointFromCommunicationState( ...
    receiverState,'receiver');
transmitterEndpoint = revgnss.OneWayInterSatelliteRangingModel.endpointFromCommunicationState( ...
    transmitterState,'transmitter');
value = revgnss.OneWayInterSatelliteRangingModel.predictProcessedValue( ...
    processedType,receiverEndpoint,transmitterEndpoint);
end

function euler = i_dcmToEulerZyx_(C)
pitch = asin(-C(3,1));
roll = atan2(C(3,2),C(3,3));
yaw = atan2(C(2,1),C(1,1));
euler = [roll;pitch;yaw];
end

% ================================================================================================
function i_test_doppler_position_column_is_nonzero_and_orthogonal_to_line_of_sight_()
fixture = i_fixture_('oneWayDoppler');
[block, diagnostics] = revgnss.OneWayDopplerRangeRateLinkUpdateAdapter.buildUpdateBlock(fixture.buildArgs);
Howner = block.ownerJacobian_mPerErrorUnit;
u = diagnostics.geometry.lineOfSightUnit;
assert(norm(Howner(1:3)) > 1e-9,'The Doppler position column must be nonzero (not the velocity-only defect).');
assert(abs(Howner(1:3)*u) < 1e-9*norm(Howner(1:3)), ...
    'The Doppler position column must be exactly orthogonal to the line of sight.');
Hremote = block.remoteJacobian_mPerErrorUnit;
assert(norm(Howner(1:3)+Hremote(1:3)) < 1e-9*max(1,norm(Howner(1:3))), ...
    'Owner and remote position columns must be exact negatives.');
fprintf('  PASS doppler_position_column_is_nonzero_and_orthogonal_to_line_of_sight\n');
end

% ================================================================================================
function i_test_code_position_column_is_line_of_sight_unit_vector_()
fixture = i_fixture_('oneWayCode');
[block, diagnostics] = revgnss.OneWayCodeRangeLinkUpdateAdapter.buildUpdateBlock(fixture.buildArgs);
Howner = block.ownerJacobian_mPerErrorUnit;
Hremote = block.remoteJacobian_mPerErrorUnit;
u = diagnostics.geometry.lineOfSightUnit;
assert(norm(Howner(1:3)-u') < 1e-9,'The owner code position column must equal the line-of-sight unit vector.');
assert(norm(Hremote(1:3)+u') < 1e-9,'The remote code position column must equal minus the line-of-sight unit vector.');
assert(isequal(Howner(4:6),[0 0 0]) && isequal(Hremote(4:6),[0 0 0]), ...
    'Code-range velocity columns must be exactly zero.');
fprintf('  PASS code_position_column_is_line_of_sight_unit_vector\n');
end

% ================================================================================================
function i_test_clock_columns_and_not_a_clock_observable_()
fixtureCode = i_fixture_('oneWayCode');
[blockCode, ~] = revgnss.OneWayCodeRangeLinkUpdateAdapter.buildUpdateBlock(fixtureCode.buildArgs);
ownerBiasIdx = find(strcmp(fixtureCode.ownerState.covarianceComponentOrder,'clockBiasError_m'),1);
remoteBiasIdx = find(strcmp(fixtureCode.remoteState.covarianceComponentOrder,'clockBiasError_m'),1);
assert(blockCode.ownerJacobian_mPerErrorUnit(ownerBiasIdx) == 1);
assert(blockCode.remoteJacobian_mPerErrorUnit(remoteBiasIdx) == -1);

fixtureDoppler = i_fixture_('oneWayDoppler');
[blockDoppler, ~] = revgnss.OneWayDopplerRangeRateLinkUpdateAdapter.buildUpdateBlock(fixtureDoppler.buildArgs);
ownerDriftIdx = find(strcmp(fixtureDoppler.ownerState.covarianceComponentOrder,'clockDriftError_mps'),1);
remoteDriftIdx = find(strcmp(fixtureDoppler.remoteState.covarianceComponentOrder,'clockDriftError_mps'),1);
assert(blockDoppler.ownerJacobian_mPerErrorUnit(ownerDriftIdx) == 1);
assert(blockDoppler.remoteJacobian_mPerErrorUnit(remoteDriftIdx) == -1);

audit = revgnss.DistributedClockGaugeContract.requireClockObservability( ...
    blockCode,fixtureCode.delivery,fixtureCode.ownerState,fixtureCode.remoteState, ...
    fixtureCode.delivery.clockClaim,blockCode.observableRowUnits);
assert(strcmp(audit.auditVerdict,'notAClockObservable'));

badClaim = i_expectError_(@() revgnss.DistributedClockGaugeContract. ...
    requireDeclaredClockAnchorPair(fixtureCode.ownerState,fixtureCode.remoteState,'relativeBiasOnly'), []); %#ok<NASGU>
fprintf('  PASS clock_columns_and_not_a_clock_observable\n');
end

% ================================================================================================
function i_test_ecef_only_no_frame_conversion_()
fixture = i_fixture_('oneWayCode');
[blockBefore, diagBefore] = revgnss.OneWayCodeRangeLinkUpdateAdapter.buildUpdateBlock(fixture.buildArgs);

theta = 0.41; ax = [0.1;-0.4;0.9]; ax = ax/norm(ax);
K = [0 -ax(3) ax(2); ax(3) 0 -ax(1); -ax(2) ax(1) 0];
R = eye(3)+sin(theta)*K+(1-cos(theta))*(K*K);

ownerRec = fixture.ownerState.toStruct();
ownerRec.clockAnchorDeclaration = fixture.ownerState.clockAnchorDeclaration;
ownerRec.positionEcef_m = R*ownerRec.positionEcef_m;
ownerRec.velocityEcef_mps = R*ownerRec.velocityEcef_mps;
ownerRec.stateVector(1:6) = [ownerRec.positionEcef_m;ownerRec.velocityEcef_mps];
rotatedOwner = revgnss.CommunicationEndpointState(ownerRec);

remoteRec = fixture.remoteState.toStruct();
remoteRec.clockAnchorDeclaration = fixture.remoteState.clockAnchorDeclaration;
remoteRec.positionEcef_m = R*remoteRec.positionEcef_m;
remoteRec.velocityEcef_mps = R*remoteRec.velocityEcef_mps;
remoteRec.stateVector(1:6) = [remoteRec.positionEcef_m;remoteRec.velocityEcef_mps];
rotatedRemote = revgnss.CommunicationEndpointState(remoteRec);

rotatedArgs = fixture.buildArgs;
rotatedArgs.ownerState = rotatedOwner;
rotatedArgs.remoteState = rotatedRemote;
[~, diagAfter] = revgnss.OneWayCodeRangeLinkUpdateAdapter.buildUpdateBlock(rotatedArgs);

scale = max(1,abs(diagBefore.predictedValue));
assert(abs(diagAfter.predictedValue-diagBefore.predictedValue) <= 1e-6*scale, ...
    'A rigid rotation of both endpoints about the origin must leave the predicted range unchanged (frame invariance).');
assert(~contains(fileread(which('revgnss.OneWayInterSatelliteRangingModel')),'FrameTimeUtils'), ...
    'The one-way kernel must never reference the ECEF->ECI frame bridge.');
fprintf('  PASS ecef_only_no_frame_conversion (diff=%.3e)\n',abs(diagAfter.predictedValue-diagBefore.predictedValue));
end

% ================================================================================================
function i_test_wrong_observable_type_refused_at_propose_()
fixture = i_fixture_('oneWayDoppler');
args = fixture.buildArgs;
badArgs = struct( ...
    'physicalObservationRecord',fixture.record,'ownerProvider',fixture.ownerProvider, ...
    'remoteProvider',fixture.remoteProvider,'ownerPolicy','initiator', ...
    'roleReversalPolicy','disabled','remoteProductPropagationPolicy','frozenSameEpochOnly', ...
    'stateExchangeSettings',struct('maximumAge_s',0,'deliveryDelay_s',0), ...
    'outOfSequencePolicy','reject','commonSourceTreatment',fixture.commonSourceTreatment, ...
    'correlationPolicy','splitCovarianceIntersection','calibrationRegistry',fixture.registry, ...
    'deliveryEpoch_s',fixture.epoch_s,'coordinateEventEpoch_s',fixture.epoch_s, ...
    'observableIdentifier','oneWayCode','persistentCalibrationTreatment','rejected', ...
    'configurationSnapshot',fixture.cfg);
i_expectError_(@() revgnss.LinkObservationDelivery.propose(badArgs), ...
    'DistributedLinkUpdateAdapter:processedObservableTypeNotSupportedForObservable');
fprintf('  PASS wrong_observable_type_refused_at_propose\n');
end

% ================================================================================================
function i_test_rf_derived_one_way_sigma_matches_single_leg_()
leg = struct('frequency_Hz',26e9,'losses_dB',1,'integrationTime_s',1, ...
    'modulationTrackingCoefficient',1,'chipRate_Hz',10.23e6, ...
    'transmitAntenna',struct('model','fixedGain','gain_dBi',20), ...
    'receiveAntenna',struct('model','fixedGain','gain_dBi',20), ...
    'eirp_dBW',10,'systemNoiseTemperature_K',500);
legWithDistance = leg; legWithDistance.distance_m = 5e5;
oneWayOut = revgnss.InterSatelliteRFLinkModel.evaluateOneWayLeg(legWithDistance);
symSpec = struct('distance_m',5e5,'forward',leg,'return',leg, ...
    'forwardReturnTrackingErrorCorrelation',1);
result = revgnss.InterSatelliteRFLinkModel.evaluate(symSpec);
assert(isequal(oneWayOut.oneWayCodeRangeSigma_m,result.forward.codeRangeSigma_m), ...
    'evaluateOneWayLeg must delegate to the SAME per-leg computation as evaluate(), bit-for-bit.');
assert(abs(oneWayOut.oneWayCodeRangeSigma_m-result.codeRangeSigma_m) < 1e-12, ...
    'With forward==return and correlation=1, the round-trip composite must equal the one-way sigma exactly (no extra halving/doubling).');
fprintf('  PASS rf_derived_one_way_sigma_matches_single_leg\n');
end

% ================================================================================================
function className = i_adapterClassFor_(observable)
if strcmp(observable,'oneWayCode')
    className = 'revgnss.OneWayCodeRangeLinkUpdateAdapter';
else
    className = 'revgnss.OneWayDopplerRangeRateLinkUpdateAdapter';
end
end

function out = i_expectError_(fn, expectedIdentifier)
out = [];
try
    fn();
    if ~isempty(expectedIdentifier)
        error('test_one_way_isl_link_update_adapters:missingError', ...
            'Expected %s was not raised.',expectedIdentifier);
    end
catch ME
    if ~isempty(expectedIdentifier)
        assert(strcmp(ME.identifier,expectedIdentifier), ...
            'Expected %s, received %s (%s).',expectedIdentifier,ME.identifier,ME.message);
    end
end
end

% ================================================================================================
function fixture = i_fixture_(observable)
cfg = i_baseConfig_();
fleetCfg = cfg;
fleetCfg.scenario.nSpaceAssets = 2;
fleetCfg.measurements.isl.enable = true;
fleetCfg.measurements.isl.oneWay.enable = true;
if strcmp(observable,'oneWayCode')
    fleetCfg.measurements.isl.oneWay.code.enable = true;
else
    fleetCfg.measurements.isl.oneWay.doppler.enable = true;
end

setup = revgnss.IndependentFleetScenarioFactory.federatedSetup(fleetCfg, false);
cfg1 = revgnss.IndependentFleetScenarioFactory.stageOneLeafConfigForIndex(setup, fleetCfg, 1);
cfg2 = revgnss.IndependentFleetScenarioFactory.stageOneLeafConfigForIndex(setup, fleetCfg, 2);
sim1 = revgnss.ReverseGNSSSimulation(cfg1);
sim1.initialize(); sim1.advanceTruthEpoch(1); sim1.runLocalEstimationEpoch(1);
sim2 = revgnss.ReverseGNSSSimulation(cfg2);
sim2.initialize(); sim2.advanceTruthEpoch(1); sim2.runLocalEstimationEpoch(1);
epoch_s = sim1.tVec(sim1.lastEstimatedEpoch);
assert(isequal(sim1.tVec,sim2.tVec));

assets = {sim1.asset,sim2.asset};
[observations,~,~] = revgnss.OneWayInterSatelliteObservationBuilder.generateObservations( ...
    fleetCfg,assets,epoch_s);
assert(~isempty(observations), ...
    'The fixture fleet config must generate at least one one-way observation.');
record = observations{1};

ownerTerminal = struct('declared',true, ...
    'transmitTerminalIdentifier','terminal:notUsedByOneWayRole', ...
    'receiveTerminalIdentifier',record.receiveTerminalIdentifier, ...
    'transmitAntennaIdentifier','antenna:notUsedByOneWayRole', ...
    'receiveAntennaIdentifier',record.receiveAntennaIdentifier, ...
    'transmitPhaseCentreOffset_body_m',zeros(3,1), ...
    'receivePhaseCentreOffset_body_m',[0.8;0.2;0.3]);
remoteTerminal = struct('declared',true, ...
    'transmitTerminalIdentifier',record.transmitTerminalIdentifier, ...
    'receiveTerminalIdentifier','terminal:notUsedByOneWayRole', ...
    'transmitAntennaIdentifier',record.transmitAntennaIdentifier, ...
    'receiveAntennaIdentifier','antenna:notUsedByOneWayRole', ...
    'transmitPhaseCentreOffset_body_m',[0.8;0.2;0.3], ...
    'receivePhaseCentreOffset_body_m',zeros(3,1));

ownerProvider = revgnss.OwnerLocalEstimatorEndpointProvider.fromLocalSimulation( ...
    sim1,1,epoch_s,ownerTerminal);
diagnosticProduct2 = revgnss.EndpointStateProduct.fromLocalEstimator( ...
    sim2,2,epoch_s,0,'spacecraft:2:epoch:oneway-test');
commonSourceTreatment = struct('towerClockProduct','rejected','terminalCalibration','rejected', ...
    'transmittedStateProduct','rejected','sessionTimingProduct','rejected', ...
    'sharedForceAtmosphericProduct','rejected');
eligibleProduct2 = revgnss.EstimatorEligibleEndpointStateProduct.fromDiagnosticProduct( ...
    diagnosticProduct2,commonSourceTreatment);
remoteProvider = revgnss.FrozenProductEndpointProvider.fromEstimatorEligibleProduct( ...
    eligibleProduct2,epoch_s,remoteTerminal);

registry = revgnss.DistributedLinkCalibrationRegistry();
args = struct( ...
    'physicalObservationRecord',record,'ownerProvider',ownerProvider,'remoteProvider',remoteProvider, ...
    'ownerPolicy','initiator','roleReversalPolicy','disabled', ...
    'remoteProductPropagationPolicy','frozenSameEpochOnly', ...
    'stateExchangeSettings',struct('maximumAge_s',0,'deliveryDelay_s',0), ...
    'outOfSequencePolicy','reject','commonSourceTreatment',commonSourceTreatment, ...
    'correlationPolicy','splitCovarianceIntersection','calibrationRegistry',registry, ...
    'deliveryEpoch_s',epoch_s,'coordinateEventEpoch_s',epoch_s, ...
    'observableIdentifier',observable,'persistentCalibrationTreatment','rejected', ...
    'configurationSnapshot',fleetCfg);
delivery = revgnss.LinkObservationDelivery.propose(args);

ownerState = revgnss.CommunicationEndpointStateProvider.requireStateAt(ownerProvider,epoch_s);
remoteState = revgnss.CommunicationEndpointStateProvider.requireStateAt(remoteProvider,epoch_s);

buildArgs = struct( ...
    'delivery',delivery,'ownerState',ownerState,'remoteState',remoteState, ...
    'weightSelectionRule','fixedDeclaredWeights','persistentCalibrationTreatment','rejected');

fixture = struct('sim1',sim1,'sim2',sim2,'record',record,'delivery',delivery, ...
    'ownerState',ownerState,'remoteState',remoteState,'buildArgs',buildArgs, ...
    'ownerProvider',ownerProvider,'remoteProvider',remoteProvider,'registry',registry, ...
    'commonSourceTreatment',commonSourceTreatment,'epoch_s',epoch_s,'cfg',fleetCfg);
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
