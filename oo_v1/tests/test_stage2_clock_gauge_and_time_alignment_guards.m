function test_stage2_clock_gauge_and_time_alignment_guards()
% test_stage2_clock_gauge_and_time_alignment_guards  Plan Section 2.4 acceptance test.
%
% Covers: revgnss.EndpointClockAnchorDeclaration's config classification (real masterConfig
% plus deliberately varied clock/gauge/tower settings), revgnss.DistributedClockGaugeContract's
% pair-anchor/datum/clock-claim/remote-state-provenance checks against REAL endpoint states
% built through a real 2-asset independent fleet (no mocks), and the proof that Section 2.4
% itself enabled nothing new: RegisteredAdapterClasses/AllowedObservables carry exactly the
% observables each SANCTIONED by its own adapter's stage (Section 2.3.1's coherentTwoWayCodeRange,
% Section 2.3.2's firstOrderReciprocalClockTransfer), never a Section-2.4-added one.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
addpath(rootDir);
addpath(fullfile(rootDir,'config'));
addpath(fullfile(rootDir,'config','internal'));

fprintf('=== test_stage2_clock_gauge_and_time_alignment_guards ===\n');
i_test_anchor_classification_against_real_masterConfig_();
i_test_anchor_declaration_construction_rules_();
i_test_clock_claim_declared_();
i_test_pair_anchor_checks_against_real_endpoint_states_();
i_test_remote_state_provenance_();
i_test_section24_enables_nothing_new_();
fprintf('=== test_stage2_clock_gauge_and_time_alignment_guards: ALL PASS ===\n');
end

% ================================================================================================
function i_test_anchor_classification_against_real_masterConfig_()
cfg = masterConfig();
cfg = revgnss.ConfigFactory.finalizeConfig(cfg);
d = revgnss.EndpointClockAnchorDeclaration.fromLocalEstimatorConfig(cfg,'spacecraft:1',1);
assert(strcmp(d.anchorKind,'absoluteFromExternalTowerClockProduct'), ...
    'The real default masterConfig (5 towers, spacecraftReceiverClockOnly) must be anchored.');
assert(d.isAbsolutelyAnchored());
assert(contains(d.anchorDatumIdentifier,cfg.estimator.towerClockMode), ...
    'The anchor datum must be derived from the RESOLVED estimator.towerClockMode, not a raw pre-resolution knob.');

cfgFree = cfg;
cfgFree.clock.mode = 'includeTowerClocksInEKF';
cfgFree.clock.gauge.mode = 'free';
dFree = revgnss.EndpointClockAnchorDeclaration.fromLocalEstimatorConfig(cfgFree,'spacecraft:1',1);
assert(strcmp(dFree.anchorKind,'unanchoredRelativeOnly') && ~dFree.isAbsolutelyAnchored());
assert(strcmp(dFree.anchorDatumIdentifier, ...
    revgnss.EndpointClockAnchorDeclaration.UndeclaredDatumIdentifier));

cfgFix = cfg;
cfgFix.clock.mode = 'includeTowerClocksInEKF';
cfgFix.clock.gauge.mode = 'fixReferenceTower';
cfgFix.clock.gauge.referenceTowerIndex = 3;
dFix = revgnss.EndpointClockAnchorDeclaration.fromLocalEstimatorConfig(cfgFix,'spacecraft:1',1);
assert(strcmp(dFix.anchorKind,'absoluteFromEstimatedTowerClockGauge') && dFix.isAbsolutelyAnchored());
assert(contains(dFix.anchorDatumIdentifier,'tower3'), ...
    'fixReferenceTower''s datum must encode the actual reference tower index.');

cfgNoTower = cfg;
cfgNoTower.scenario.nTowers = 0;
dNoTower = revgnss.EndpointClockAnchorDeclaration.fromLocalEstimatorConfig(cfgNoTower,'spacecraft:1',1);
assert(strcmp(dNoTower.anchorKind,'unanchoredRelativeOnly'), ...
    'nTowers=0 must be unanchored even though clock.mode/gauge.mode look nominal.');

cfgNoCorrection = cfg;
cfgNoCorrection.estimator.towerClockMode = 'none';
dNoCorrection = revgnss.EndpointClockAnchorDeclaration.fromLocalEstimatorConfig( ...
    cfgNoCorrection,'spacecraft:1',1);
assert(strcmp(dNoCorrection.anchorKind,'unanchoredRelativeOnly'), ...
    ['estimator.towerClockMode=''none'' (no tower clock correction reaches the estimator) must ' ...
    'be unanchored -- fails closed even with 5 towers physically present.']);

i_expectError_(@() revgnss.EndpointClockAnchorDeclaration.fromLocalEstimatorConfig( ...
    setfield(cfg,'clock',setfield(cfg.clock,'gauge',setfield(cfg.clock.gauge,'mode','bogusGauge'))), ...
    'spacecraft:1',1),'EndpointClockAnchorDeclaration:unclassifiedConfiguration');
i_expectError_(@() revgnss.EndpointClockAnchorDeclaration.fromLocalEstimatorConfig( ...
    setfield(cfg,'clock',setfield(cfg.clock,'mode','bogusClockMode')), ...
    'spacecraft:1',1),'EndpointClockAnchorDeclaration:unclassifiedConfiguration');
fprintf('  PASS anchor classification against real masterConfig and deliberate variations\n');
end

% ================================================================================================
function i_test_anchor_declaration_construction_rules_()
% The private constructor cannot be reached directly; only fromLocalEstimatorConfig builds one.
mc = meta.class.fromName('revgnss.EndpointClockAnchorDeclaration');
ctorMeta = mc.MethodList(strcmp({mc.MethodList.Name},'EndpointClockAnchorDeclaration'));
assert(strcmp(ctorMeta.Access,'private'), ...
    'The constructor must stay private: a caller must never be able to assert an anchor.');
fprintf('  PASS anchor declaration has no public constructor\n');
end

% ================================================================================================
function i_test_clock_claim_declared_()
assert(strcmp(revgnss.DistributedClockGaugeContract.requireObservableClockClaimDeclared( ...
    'coherentTwoWayCodeRange'),'notAClockObservable'));
assert(strcmp(revgnss.DistributedClockGaugeContract.requireObservableClockClaimDeclared( ...
    'none'),'notAClockObservable'));
assert(strcmp(revgnss.DistributedClockGaugeContract.requireObservableClockClaimDeclared( ...
    'firstOrderReciprocalClockTransfer'),'relativeBiasOnly'));
i_expectError_(@() revgnss.DistributedClockGaugeContract.requireObservableClockClaimDeclared( ...
    'oneWayDoppler'),'DistributedClockGaugeContract:observableClockClaimUndeclared');
fprintf('  PASS clock claim declared per observable\n');
end

% ================================================================================================
function i_test_pair_anchor_checks_against_real_endpoint_states_()
[ownerState,remoteState] = i_realEndpointStatePair_();

% Both real-fleet endpoints are anchored by default (masterConfig's 5-tower default): the pair
% check must pass for both clock claims, recording pairAbsolutelyAnchored=true.
revgnss.DistributedClockGaugeContract.requireEndpointPairTimeFrameDatumCompatible( ...
    ownerState,remoteState);
summaryRelative = revgnss.DistributedClockGaugeContract.requireDeclaredClockAnchorPair( ...
    ownerState,remoteState,'relativeBiasOnly');
assert(summaryRelative.pairAbsolutelyAnchored);
summaryRange = revgnss.DistributedClockGaugeContract.requireDeclaredClockAnchorPair( ...
    ownerState,remoteState,'notAClockObservable');
assert(summaryRange.pairAbsolutelyAnchored);

% Forge both endpoints unanchored (copy real states, replace only clockAnchorDeclaration via a
% zero-tower cfg): relativeBiasOnly must now be REJECTED; notAClockObservable must NOT be.
unanchoredDecl1 = i_unanchoredDeclaration_('spacecraft:1',1);
unanchoredDecl2 = i_unanchoredDeclaration_('spacecraft:2',2);
ownerUnanchored = i_withClockAnchorDeclaration_(ownerState,unanchoredDecl1);
remoteUnanchored = i_withClockAnchorDeclaration_(remoteState,unanchoredDecl2);
i_expectError_(@() revgnss.DistributedClockGaugeContract.requireDeclaredClockAnchorPair( ...
    ownerUnanchored,remoteUnanchored,'relativeBiasOnly'), ...
    'DistributedClockGaugeContract:unanchoredClockPair');
summaryUnanchoredRange = revgnss.DistributedClockGaugeContract.requireDeclaredClockAnchorPair( ...
    ownerUnanchored,remoteUnanchored,'notAClockObservable');
assert(~summaryUnanchoredRange.pairAbsolutelyAnchored, ...
    'A two-way range delivery between two unanchored endpoints must be RECORDED, never rejected.');

% Anchor-datum mismatch: both anchored but to different datums. Rejected under relativeBiasOnly,
% recorded (not rejected) under notAClockObservable -- the anchor-datum-equality rule is
% deliberately clock-claim-specific (a two-way range between different clock datums is
% physically fine; the biases cancel in the round-trip formula).
mismatchedDecl2 = i_fixReferenceTowerDeclaration_('spacecraft:2',2,5);
remoteMismatched = i_withClockAnchorDeclaration_(remoteState,mismatchedDecl2);
i_expectError_(@() revgnss.DistributedClockGaugeContract.requireDeclaredClockAnchorPair( ...
    ownerState,remoteMismatched,'relativeBiasOnly'), ...
    'DistributedClockGaugeContract:clockAnchorDatumMismatch');
summaryMismatchedRange = revgnss.DistributedClockGaugeContract.requireDeclaredClockAnchorPair( ...
    ownerState,remoteMismatched,'notAClockObservable');
assert(summaryMismatchedRange.pairAbsolutelyAnchored, ...
    'Two differently-anchored endpoints are still jointly anchored for a non-clock observable.');

% A missing/forged clockAnchorDeclaration cannot even reach requireDeclaredClockAnchorPair:
% revgnss.CommunicationEndpointState's own constructor already refuses a non-
% EndpointClockAnchorDeclaration value structurally (defense-in-depth, tested directly here
% rather than via a CommunicationEndpointState that could never exist with a bad value).
rawRecord = ownerState.toStruct();
rawRecord.clockAnchorDeclaration = struct('notAnObject',true);
i_expectError_(@() revgnss.CommunicationEndpointState(rawRecord), ...
    'CommunicationEndpointState:clockAnchorDeclarationType');

fprintf('  PASS pair anchor checks against real fleet endpoint states\n');
end

% ================================================================================================
function i_test_remote_state_provenance_()
[~,remoteState] = i_realEndpointStatePair_();
kind = revgnss.DistributedClockGaugeContract.requireRemoteStateProvenance(remoteState);
assert(strcmp(kind,'frozenSameEpochPeerEstimate'));

rec = remoteState.toStruct();
rec.clockAnchorDeclaration = remoteState.clockAnchorDeclaration;
rec.productProvenance.sourceKind = 'bogusSource';
badProvenance = revgnss.CommunicationEndpointState(rec);
i_expectError_(@() revgnss.DistributedClockGaugeContract.requireRemoteStateProvenance( ...
    badProvenance),'DistributedClockGaugeContract:remoteStateProvenanceUndeclared');
fprintf('  PASS remote state provenance\n');
end

% ================================================================================================
function i_test_section24_enables_nothing_new_()
% Section 2.4 itself added neither vocabulary; the two entries present here are Section
% 2.3.1's (coherentTwoWayCodeRange) and Section 2.3.2's (firstOrderReciprocalClockTransfer)
% own sanctioned widenings, each with its own dedicated adapter and stage-acceptance test.
assert(isequal(revgnss.DistributedLinkUpdateAdapter.AllowedObservables, ...
    {'none','coherentTwoWayCodeRange','firstOrderReciprocalClockTransfer'}), ...
    'AllowedObservables must carry exactly the observables sanctioned through Section 2.3.2.');
assert(isequal(revgnss.DistributedLinkUpdateAdapter.RegisteredAdapterClasses, ...
    {'revgnss.CoherentTwoWayRangeLinkUpdateAdapter', ...
    'revgnss.FirstOrderReciprocalClockTransferLinkUpdateAdapter'}), ...
    'RegisteredAdapterClasses must carry exactly the two sanctioned adapters.');
fprintf('  PASS Section 2.4 enables nothing new beyond Section 2.3.1/2.3.2''s own widenings\n');
end

% ================================================================================================
function [ownerState, remoteState] = i_realEndpointStatePair_()
cfg = i_baseConfig_();
cfg.scenario.nSpaceAssets = 2;
setup = revgnss.IndependentFleetScenarioFactory.federatedSetup(cfg,false);
cfg1 = revgnss.IndependentFleetScenarioFactory.stageOneLeafConfigForIndex(setup,cfg,1);
cfg2 = revgnss.IndependentFleetScenarioFactory.stageOneLeafConfigForIndex(setup,cfg,2);
sim1 = revgnss.ReverseGNSSSimulation(cfg1);
sim1.initialize(); sim1.advanceTruthEpoch(1); sim1.runLocalEstimationEpoch(1);
sim2 = revgnss.ReverseGNSSSimulation(cfg2);
sim2.initialize(); sim2.advanceTruthEpoch(1); sim2.runLocalEstimationEpoch(1);
epoch_s = sim1.tVec(sim1.lastEstimatedEpoch);

ownerProvider = revgnss.OwnerLocalEstimatorEndpointProvider.fromLocalSimulation(sim1,1,epoch_s);
ownerState = ownerProvider.stateAtCoordinateEpoch(epoch_s);

diag2 = revgnss.EndpointStateProduct.fromLocalEstimator(sim2,2,epoch_s,0,'seq:clock-gauge-test');
commonTreat = i_allRejectedCommonSourceTreatment_();
eligible2 = revgnss.EstimatorEligibleEndpointStateProduct.fromDiagnosticProduct(diag2,commonTreat);
remoteProvider = revgnss.FrozenProductEndpointProvider.fromEstimatorEligibleProduct(eligible2,epoch_s);
remoteState = remoteProvider.stateAtCoordinateEpoch(epoch_s);
end

function state = i_withClockAnchorDeclaration_(state, declaration)
rec = state.toStruct();
rec.clockAnchorDeclaration = declaration;
state = revgnss.CommunicationEndpointState(rec);
end

function declaration = i_unanchoredDeclaration_(endpointIdentifier, canonicalIdx)
cfg = struct('scenario',struct('nTowers',0), ...
    'estimator',struct('towerClockMode','none'), ...
    'clock',struct('mode','spacecraftReceiverClockOnly', ...
        'gauge',struct('mode','externalTowerCorrections','referenceTowerIndex',1)));
declaration = revgnss.EndpointClockAnchorDeclaration.fromLocalEstimatorConfig( ...
    cfg,endpointIdentifier,canonicalIdx);
end

function declaration = i_fixReferenceTowerDeclaration_(endpointIdentifier, canonicalIdx, refTower)
cfg = struct('scenario',struct('nTowers',5), ...
    'estimator',struct('towerClockMode','perfectCorrection'), ...
    'clock',struct('mode','includeTowerClocksInEKF', ...
        'gauge',struct('mode','fixReferenceTower','referenceTowerIndex',refTower)));
declaration = revgnss.EndpointClockAnchorDeclaration.fromLocalEstimatorConfig( ...
    cfg,endpointIdentifier,canonicalIdx);
end

function treatment = i_allRejectedCommonSourceTreatment_()
treatment = struct('towerClockProduct','rejected','terminalCalibration','rejected', ...
    'transmittedStateProduct','rejected','sessionTimingProduct','rejected', ...
    'sharedForceAtmosphericProduct','rejected');
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

function i_expectError_(action, identifier)
try
    action();
catch ME
    assert(strcmp(ME.identifier,identifier), ...
        'Expected %s, received %s (%s).',identifier,ME.identifier,ME.message);
    return
end
error('test_stage2_clock_gauge_and_time_alignment_guards:missingError', ...
    'Expected error %s was not raised.',identifier);
end
