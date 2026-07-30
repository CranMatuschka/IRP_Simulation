function test_first_order_reciprocal_clock_transfer_link_update_adapter()
% test_first_order_reciprocal_clock_transfer_link_update_adapter  Plan Section 2.3.2: real
% end-to-end exercise of revgnss.FirstOrderReciprocalClockTransferLinkUpdateAdapter against the
% REAL production data flow (real revgnss.ReverseGNSSSimulation instances, real
% revgnss.InterSatelliteTimeTransferBuilder.generateObservations, real
% revgnss.OwnerLocalEstimatorEndpointProvider / revgnss.FrozenProductEndpointProvider, real
% revgnss.LinkObservationDelivery.propose -- including, for the FIRST time, its relativeBiasOnly
% clock-guard branch -- and real revgnss.DistributedLinkUpdateAdapter.requireUpdateBlock). Nothing
% here makes distributedEstimator.linkUpdate reachable end-to-end through the coordinator; no
% scenario JSON is read or written.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
addpath(rootDir);
addpath(fullfile(rootDir,'config'));
addpath(fullfile(rootDir,'config','internal'));

fprintf('=== test_first_order_reciprocal_clock_transfer_link_update_adapter ===\n');
i_test_real_delivery_end_to_end_contract_compliance_();
i_test_analytic_partials_match_independent_perturbation_oracle_();
i_test_position_velocity_have_zero_effect_on_residual_and_jacobian_();
i_test_clock_observability_audit_is_common_mode_blind_();
i_test_reciprocity_term_and_raw_timestamps_refused_();
i_test_wrong_record_class_and_terminal_mismatch_refused_();
fprintf('=== test_first_order_reciprocal_clock_transfer_link_update_adapter: ALL PASS ===\n');
end

% ================================================================================================
function i_test_real_delivery_end_to_end_contract_compliance_()
fixture = i_fixture_();
[block, diagnostics] = revgnss.FirstOrderReciprocalClockTransferLinkUpdateAdapter.buildUpdateBlock( ...
    fixture.buildArgs);
assert(isa(block,'revgnss.DistributedLinkUpdateBlock'));
revgnss.DistributedLinkUpdateAdapter.requireUpdateBlock( ...
    block, fixture.delivery, fixture.ownerState, fixture.remoteState);

assert(strcmp(block.observableIdentifier,'firstOrderReciprocalClockTransfer'));
assert(strcmp(block.correlationPolicy,'splitCovarianceIntersection'));
assert(strcmp(fixture.delivery.clockClaim,'relativeBiasOnly'), ...
    'The delivery must have reached the relativeBiasOnly clock-guard branch of propose().');

expectedResidual = fixture.record.processedValue - diagnostics.predictedValue_m;
assert(abs(block.residual_m-expectedResidual) < 1e-9, ...
    'residual_m must equal record.processedValue - predictedValue_m exactly.');

Hremote = block.remoteJacobian_mPerErrorUnit;
expectedRemoteContribution = Hremote*fixture.remoteState.covarianceBlock*Hremote';
scale = max(1,norm(expectedRemoteContribution,'fro'));
assert(norm(block.remoteContributionCovariance_m2-expectedRemoteContribution,'fro') <= 1e-9*scale, ...
    'remoteContributionCovariance_m2 must equal H_remote*P_remote*H_remote'' exactly.');

assert(abs(block.independentMeasurementCovariance_m2-fixture.record.covarianceBlock(1,1)) < 1e-15, ...
    'independentMeasurementCovariance_m2 must equal the record''s own-row covariance exactly.');

% Truth-free by construction.
adapterSource = fileread(which('revgnss.FirstOrderReciprocalClockTransferLinkUpdateAdapter'));
forbidden = {'SpaceAsset','truthDiagnostic','ReverseGNSSSimulation','physicalTruth'};
for idx = 1:numel(forbidden)
    assert(~contains(adapterSource,forbidden{idx}), ...
        'The adapter source must never reference %s.',forbidden{idx});
end

fprintf('  PASS real_delivery_end_to_end_contract_compliance\n');
end

% ================================================================================================
function i_test_analytic_partials_match_independent_perturbation_oracle_()
% INDEPENDENT oracle: perturbs clockBias_m directly on a REBUILT CommunicationEndpointState (via
% toStruct/override/reconstruct, never via the adapter's own jacobianRow_) and finite-differences
% revgnss.ReciprocalTimeTransferModel.evaluate directly -- a separate code path from the adapter's
% label-lookup H_owner(clockBiasIdx)=referenceClockPartial=-1 / H_remote(...)=remoteClockPartial=+1.
fixture = i_fixture_();
[block, ~] = revgnss.FirstOrderReciprocalClockTransferLinkUpdateAdapter.buildUpdateBlock(fixture.buildArgs);

step = 10; % metres
ownerIdx = find(strcmp(fixture.ownerState.covarianceComponentOrder,'clockBiasError_m'),1);
remoteIdx = find(strcmp(fixture.remoteState.covarianceComponentOrder,'clockBiasError_m'),1);

hOwnerOracle = i_centralDiffClockBias_(fixture,'owner',step);
hRemoteOracle = i_centralDiffClockBias_(fixture,'remote',step);

assert(abs(block.ownerJacobian_mPerErrorUnit(ownerIdx)-hOwnerOracle) < 1e-6, ...
    'Owner clock-bias column must match the independent central-difference oracle (shipped=%.6f oracle=%.6f).', ...
    block.ownerJacobian_mPerErrorUnit(ownerIdx),hOwnerOracle);
assert(abs(block.remoteJacobian_mPerErrorUnit(remoteIdx)-hRemoteOracle) < 1e-6, ...
    'Remote clock-bias column must match the independent central-difference oracle (shipped=%.6f oracle=%.6f).', ...
    block.remoteJacobian_mPerErrorUnit(remoteIdx),hRemoteOracle);
assert(isequal(block.ownerJacobian_mPerErrorUnit(ownerIdx),-1) && ...
    isequal(block.remoteJacobian_mPerErrorUnit(remoteIdx),1), ...
    'The model''s partials are EXACT (-1/+1), not merely close.');

% Every non-clock-bias column is exactly zero (attitude/angular-rate/clock-drift/position/
% velocity): the model is closed-form linear-in-clock-bias-only while includeReciprocity=false.
Howner = block.ownerJacobian_mPerErrorUnit; Howner(ownerIdx) = 0;
Hremote = block.remoteJacobian_mPerErrorUnit; Hremote(remoteIdx) = 0;
assert(all(Howner == 0) && all(Hremote == 0), ...
    'Every column but clockBiasError_m must be exactly zero.');

fprintf('  PASS analytic_partials_match_independent_perturbation_oracle\n');
end

function h = i_centralDiffClockBias_(fixture, role, step)
if strcmp(role,'owner')
    baseState = fixture.ownerState; otherState = fixture.remoteState;
else
    baseState = fixture.remoteState; otherState = fixture.ownerState;
end
predictAt = @(delta) i_predictWithClockBiasDelta_(baseState,otherState,role,delta);
hp2 = predictAt(2*step); hp1 = predictAt(step);
hm1 = predictAt(-step); hm2 = predictAt(-2*step);
h = (-hp2+8*hp1-8*hm1+hm2)/(12*step);
end

function value = i_predictWithClockBiasDelta_(baseState, otherState, role, delta)
rec = baseState.toStruct();
rec.clockAnchorDeclaration = baseState.clockAnchorDeclaration;
rec.clockBias_m = rec.clockBias_m+delta;
rec.stateVector(end-1) = rec.clockBias_m;
perturbed = revgnss.CommunicationEndpointState(rec);
if strcmp(role,'owner')
    referenceState = perturbed; remoteState = otherState;
else
    referenceState = otherState; remoteState = perturbed;
end
referenceModelState = struct('position_m',referenceState.positionEcef_m, ...
    'velocity_mps',referenceState.velocityEcef_mps,'clockBias_m',referenceState.clockBias_m);
remoteModelState = struct('position_m',remoteState.positionEcef_m, ...
    'velocity_mps',remoteState.velocityEcef_mps,'clockBias_m',remoteState.clockBias_m);
result = revgnss.ReciprocalTimeTransferModel.evaluate( ...
    referenceModelState,remoteModelState,'firstOrderReciprocal',false);
value = result.value_m;
end

% ================================================================================================
function i_test_position_velocity_have_zero_effect_on_residual_and_jacobian_()
% Direct test of the adapter's core architectural claim: since includeReciprocity=false always,
% revgnss.ReciprocalTimeTransferModel's position/velocity partials are identically zero and
% clockDifference_m does not depend on position/velocity at all -- so perturbing the owner's
% ECEF position/velocity by a large, physically arbitrary amount must leave the residual and
% EVERY Jacobian column bit-for-bit unchanged (as long as minimum endpoint separation still
% holds), with no ECEF->ECI bridge or phase-centre lever arm ever entering the computation.
fixture = i_fixture_();
[blockBefore, diagBefore] = revgnss.FirstOrderReciprocalClockTransferLinkUpdateAdapter. ...
    buildUpdateBlock(fixture.buildArgs);

rec = fixture.ownerState.toStruct();
rec.clockAnchorDeclaration = fixture.ownerState.clockAnchorDeclaration;
rec.positionEcef_m = rec.positionEcef_m+[1e5;-2e5;3e4];
rec.velocityEcef_mps = rec.velocityEcef_mps+[50;-30;10];
rec.stateVector(1:6) = [rec.positionEcef_m;rec.velocityEcef_mps];
perturbedOwnerState = revgnss.CommunicationEndpointState(rec);

perturbedArgs = fixture.buildArgs;
perturbedArgs.ownerState = perturbedOwnerState;
[blockAfter, diagAfter] = revgnss.FirstOrderReciprocalClockTransferLinkUpdateAdapter. ...
    buildUpdateBlock(perturbedArgs);

assert(isequal(diagBefore.predictedValue_m,diagAfter.predictedValue_m), ...
    'predictedValue_m must be bit-for-bit unchanged by an owner position/velocity perturbation.');
assert(isequal(blockBefore.residual_m,blockAfter.residual_m), ...
    'residual_m must be bit-for-bit unchanged by an owner position/velocity perturbation.');
assert(isequal(blockBefore.ownerJacobian_mPerErrorUnit,blockAfter.ownerJacobian_mPerErrorUnit), ...
    'ownerJacobian_mPerErrorUnit must be bit-for-bit unchanged by an owner position/velocity perturbation.');

fprintf('  PASS position_velocity_have_zero_effect_on_residual_and_jacobian\n');
end

% ================================================================================================
function i_test_clock_observability_audit_is_common_mode_blind_()
fixture = i_fixture_();
[block, ~] = revgnss.FirstOrderReciprocalClockTransferLinkUpdateAdapter.buildUpdateBlock(fixture.buildArgs);
audit = revgnss.DistributedClockGaugeContract.requireClockObservability( ...
    block,fixture.delivery,fixture.ownerState,fixture.remoteState,fixture.delivery.clockClaim);
assert(strcmp(audit.auditVerdict,'relativeBiasOnlyCertified'));
assert(audit.rowClockInformationRank == 1);
assert(abs(audit.commonModeSensitivity_mPerM) < 1e-12, ...
    'ownerClockBiasColumn(-1)+remoteClockBiasColumn(+1) must be exactly common-mode blind.');
assert(abs(audit.differentialModeSensitivity_mPerM-2) < 1e-12, ...
    'remoteClockBiasColumn(+1)-ownerClockBiasColumn(-1) must equal 2 exactly.');
fprintf('  PASS clock_observability_audit_is_common_mode_blind\n');
end

% ================================================================================================
function i_test_reciprocity_term_and_raw_timestamps_refused_()
fixture = i_fixture_();
badReciprocity = i_recordWithField_(fixture.record,'reciprocityTermIncluded',true);
i_expectError_(@() revgnss.FirstOrderReciprocalClockTransferLinkUpdateAdapter.requireSupportedRecord( ...
    badReciprocity),'FirstOrderReciprocalClockTransferLinkUpdateAdapter:reciprocityTermUnsupported');

badTimestamps = i_recordWithField_(fixture.record,'rawTimestampTagsAvailable',true, ...
    'timestampTags_s',[1 2 3 4]);
i_expectError_(@() revgnss.FirstOrderReciprocalClockTransferLinkUpdateAdapter.requireSupportedRecord( ...
    badTimestamps),'FirstOrderReciprocalClockTransferLinkUpdateAdapter:rawTimestampTagsUnsupported');
fprintf('  PASS reciprocity_term_and_raw_timestamps_refused\n');
end

function record = i_recordWithField_(record, varargin)
s = record.toStruct();
for k = 1:2:numel(varargin)
    s.(varargin{k}) = varargin{k+1};
end
record = revgnss.InterSatelliteTimeTransferObservationRecord(s);
end

% ================================================================================================
function i_test_wrong_record_class_and_terminal_mismatch_refused_()
fixture = i_fixture_();
i_expectError_(@() revgnss.FirstOrderReciprocalClockTransferLinkUpdateAdapter.requireSupportedRecord( ...
    struct('foo',1)),'FirstOrderReciprocalClockTransferLinkUpdateAdapter:recordType');

badTerminalState = fixture.ownerState;
mismatchedRecord = i_recordWithField_(fixture.record,'referenceTerminalIdentifier','terminal:not-the-one');
i_expectError_(@() revgnss.FirstOrderReciprocalClockTransferLinkUpdateAdapter. ...
    requireTerminalIdentityMatchesRecord(badTerminalState,mismatchedRecord,'owner'), ...
    'FirstOrderReciprocalClockTransferLinkUpdateAdapter:terminalGeometryMismatch');
fprintf('  PASS wrong_record_class_and_terminal_mismatch_refused\n');
end

function i_expectError_(fn, expectedIdentifier)
try
    fn();
    error('test_first_order_reciprocal_clock_transfer_link_update_adapter:missingError', ...
        'Expected %s was not raised.',expectedIdentifier);
catch ME
    assert(strcmp(ME.identifier,expectedIdentifier), ...
        'Expected %s, received %s (%s).',expectedIdentifier,ME.identifier,ME.message);
end
end

% ================================================================================================
function fixture = i_fixture_()
cfg = i_baseConfig_();
fleetCfg = cfg;
fleetCfg.scenario.nSpaceAssets = 2;
fleetCfg.measurements.isl.enable = true;
fleetCfg.measurements.isl.twoWay.enable = true;
fleetCfg.measurements.isl.twoWay.timeTransfer.enable = true;

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
[observations,~,~] = revgnss.InterSatelliteTimeTransferBuilder.generateObservations( ...
    fleetCfg,assets,epoch_s);
assert(~isempty(observations), ...
    'The fixture fleet config must generate at least one time-transfer observation.');
record = observations{1};

ownerTerminal = struct('declared',true, ...
    'transmitTerminalIdentifier',record.referenceTerminalIdentifier, ...
    'receiveTerminalIdentifier',record.referenceTerminalIdentifier, ...
    'transmitAntennaIdentifier','antenna:notCarriedByTimeTransferRecord', ...
    'receiveAntennaIdentifier','antenna:notCarriedByTimeTransferRecord', ...
    'transmitPhaseCentreOffset_body_m',zeros(3,1),'receivePhaseCentreOffset_body_m',zeros(3,1));
remoteTerminal = struct('declared',true, ...
    'transmitTerminalIdentifier',record.remoteTerminalIdentifier, ...
    'receiveTerminalIdentifier',record.remoteTerminalIdentifier, ...
    'transmitAntennaIdentifier','antenna:notCarriedByTimeTransferRecord', ...
    'receiveAntennaIdentifier','antenna:notCarriedByTimeTransferRecord', ...
    'transmitPhaseCentreOffset_body_m',zeros(3,1),'receivePhaseCentreOffset_body_m',zeros(3,1));

ownerProvider = revgnss.OwnerLocalEstimatorEndpointProvider.fromLocalSimulation(sim1,1,epoch_s,ownerTerminal);
diagnosticProduct2 = revgnss.EndpointStateProduct.fromLocalEstimator( ...
    sim2,2,epoch_s,0,'spacecraft:2:epoch:reciprocal-test');
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
    'observableIdentifier','firstOrderReciprocalClockTransfer', ...
    'persistentCalibrationTreatment','rejected','configurationSnapshot',fleetCfg);
delivery = revgnss.LinkObservationDelivery.propose(args);

ownerState = revgnss.CommunicationEndpointStateProvider.requireStateAt(ownerProvider,epoch_s);
remoteState = revgnss.CommunicationEndpointStateProvider.requireStateAt(remoteProvider,epoch_s);

buildArgs = struct( ...
    'delivery',delivery,'ownerState',ownerState,'remoteState',remoteState, ...
    'weightSelectionRule','fixedDeclaredWeights','persistentCalibrationTreatment','rejected');

fixture = struct('sim1',sim1,'sim2',sim2,'record',record,'delivery',delivery, ...
    'ownerState',ownerState,'remoteState',remoteState,'buildArgs',buildArgs);
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
