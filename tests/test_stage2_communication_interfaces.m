function test_stage2_communication_interfaces()
% test_stage2_communication_interfaces  Stage-2 Section 2.1 generic communication interfaces.
%
% Covers: every new class's construction/validation rules (positive and negative), the
% coordinator-owned fleet delivery ledger's exactly-once/atomicity guarantee,
% CanonicalEndpointIdentity.requireReconciled actually being used by LinkObservationDelivery,
% DistributedLinkProtocolContract.requireDeliveryProvenance/requireSameEpochScope actually
% being invoked by the estimator-eligible path, and a byte-identical-when-disabled regression
% check.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
addpath(rootDir);
addpath(fullfile(rootDir,'config'));
addpath(fullfile(rootDir,'config','internal'));

fprintf('=== test_stage2_communication_interfaces ===\n');
i_allNewClassesInstantiate_();
i_configDefaultsAndManifest_();
i_validateConfigRejectsSection21Vocabulary_();
i_validateConfigRejectsUnsupportedCombinations_();
i_leafConfigForcesNewSubTogglesOff_();
i_communicationEndpointStateConstructionRules_();
i_ownerProviderFromRealSimulation_();
i_ownerProviderRejectsJointStateMap_();
i_remoteProductProfileAndProvider_();
i_deliveryCanonicalIdentityAndLifecycle_();
i_deliveryRejectionReasonMapping_();
i_ledgerReconciliationWithLocalLedgers_();
i_updateAdapterContractShapeOnly_();
i_updateBlockKeepsRemoteContributionSeparate_();
i_calibrationSingleOwnerRegistry_();
i_disabledTogglesLeaveStageOneUnchanged_();
i_stageOneJournalAndProductPreserved_();
i_epochPhaseOrderUnchangedAndCommitOrderingClosed_();
fprintf('=== test_stage2_communication_interfaces: ALL PASS ===\n');
end

% ================================================================================================
function i_allNewClassesInstantiate_()
classNames = { ...
    'revgnss.CommunicationEndpointState','revgnss.CommunicationEndpointStateProvider', ...
    'revgnss.OwnerLocalEstimatorEndpointProvider','revgnss.FrozenProductEndpointProvider', ...
    'revgnss.EstimatorEligibleEndpointStateProduct','revgnss.LinkObservationDelivery', ...
    'revgnss.DistributedDeliveryLedger','revgnss.DistributedLinkUpdateBlock', ...
    'revgnss.DistributedLinkUpdateAdapter','revgnss.DistributedLinkCalibrationState', ...
    'revgnss.DistributedLinkCalibrationRegistry'};
for index = 1:numel(classNames)
    classMeta = meta.class.fromName(classNames{index});
    assert(~isempty(classMeta), ...
        'Class %s could not be defined/introspected -- check for a MATLAB:class:DefaultPropertyValueRequired.', ...
        classNames{index});
end
% The two handle classes with zero-argument constructors must actually construct.
ledger = revgnss.DistributedDeliveryLedger(); %#ok<NASGU>
registry = revgnss.DistributedLinkCalibrationRegistry(); %#ok<NASGU>
end

% ================================================================================================
function i_configDefaultsAndManifest_()
cfg = masterConfig();
de = cfg.multiAsset.distributedEstimator;
assert(~de.stateExchange.estimatorEligibleProfile.enable && ~de.deliveryLedger.enable, ...
    'Section 2.1 logical toggles must default disabled.');
assert(strcmp(de.linkUpdate.remoteProductPropagationPolicy,'frozenSameEpochOnly') && ...
    strcmp(de.linkUpdate.roleReversalPolicy,'disabled') && ...
    strcmp(de.linkUpdate.calibrationOwnership.policy,'undeclared') && ...
    strcmp(de.linkUpdate.updateAdapter.observable,'none'), ...
    'Section 2.1 word toggles must default to their single frozen legal value.');

resolvedDefault = revgnss.ConfigFactory.defaultConfig();
resolvedMaster = revgnss.ConfigFactory.finalizeConfig(masterConfig());
assert(isequaln(resolvedDefault.multiAsset.distributedEstimator, ...
    resolvedMaster.multiAsset.distributedEstimator), ...
    'Section 2.1 controls must resolve identically from every master-config entry path.');

manifest = revgnss.SimulationToggleManifest.fromConfig(cfg);
paths = {manifest.cfgPath};
required = { ...
    'cfg.multiAsset.distributedEstimator.stateExchange.estimatorEligibleProfile.enable', ...
    'cfg.multiAsset.distributedEstimator.deliveryLedger.enable', ...
    'cfg.multiAsset.distributedEstimator.linkUpdate.remoteProductPropagationPolicy', ...
    'cfg.multiAsset.distributedEstimator.linkUpdate.roleReversalPolicy', ...
    'cfg.multiAsset.distributedEstimator.linkUpdate.calibrationOwnership.policy', ...
    'cfg.multiAsset.distributedEstimator.linkUpdate.updateAdapter.observable'};
assert(all(ismember(required,paths)), ...
    'Every Section 2.1 toggle must be visible in the toggle manifest.');

plainCfg = masterConfig();
assert(~(isfield(plainCfg,'multiAsset') && isfield(plainCfg.multiAsset,'perAssetLeaf')), ...
    'masterConfig must not declare perAssetLeaf; it is internal plumbing, not a user knob.');
end

% ================================================================================================
function i_validateConfigRejectsSection21Vocabulary_()
invalid = i_fleetConfig_(3);
invalid.multiAsset.distributedEstimator.linkUpdate.remoteProductPropagationPolicy = ...
    'shortArcKinematicWithDeclaredProcessNoise';
i_expectError_(@() revgnss.ConfigFactory.finalizeConfig(invalid), ...
    'IndependentFleetCoordinator:section21ControlsUnavailable');

invalid = i_fleetConfig_(3);
invalid.multiAsset.distributedEstimator.linkUpdate.roleReversalPolicy = 'separateScheduledSession';
i_expectError_(@() revgnss.ConfigFactory.finalizeConfig(invalid), ...
    'IndependentFleetCoordinator:section21ControlsUnavailable');

invalid = i_fleetConfig_(3);
invalid.multiAsset.distributedEstimator.linkUpdate.calibrationOwnership.policy = 'singleOwnerRegistry';
i_expectError_(@() revgnss.ConfigFactory.finalizeConfig(invalid), ...
    'IndependentFleetCoordinator:section21ControlsUnavailable');

% Section 2.3.1 implements 'coherentTwoWayCodeRange', but only as part of the sanctioned
% tuple (enable/ownerPolicy/correlationPolicy all flipped together); setting the observable
% alone is a partial/mixed combination, caught by the tuple gate before the vocabulary gate.
invalid = i_fleetConfig_(3);
invalid.multiAsset.distributedEstimator.linkUpdate.updateAdapter.observable = 'coherentTwoWayCodeRange';
i_expectError_(@() revgnss.ConfigFactory.finalizeConfig(invalid), ...
    'IndependentFleetCoordinator:linkUpdateUnavailable');

% The pre-existing linkUpdate.enable rejection is untouched by the new gate.
invalid = i_fleetConfig_(3);
invalid.multiAsset.distributedEstimator.linkUpdate.enable = true;
i_expectError_(@() revgnss.ConfigFactory.finalizeConfig(invalid), ...
    'IndependentFleetCoordinator:linkUpdateUnavailable');

valid = i_fleetConfig_(3);
resolved = revgnss.ConfigFactory.finalizeConfig(valid);
assert(isstruct(resolved), ...
    'A Stage-1-legal fleet config with the frozen Section 2.1 defaults must still resolve.');
end

% ================================================================================================
function i_validateConfigRejectsUnsupportedCombinations_()
invalid = i_fleetConfig_(3);
invalid.multiAsset.distributedEstimator.stateExchange.enable = false;
invalid.multiAsset.distributedEstimator.stateExchange.estimatorEligibleProfile.enable = true;
i_expectError_(@() revgnss.ConfigFactory.finalizeConfig(invalid), ...
    'IndependentFleetCoordinator:estimatorEligibleProfileRequiresStateExchange');

invalid = i_fleetConfig_(3);
invalid.multiAsset.distributedEstimator.stateExchange.enable = true;
invalid.multiAsset.distributedEstimator.stateExchange.deliveryDelay_s = 1;
invalid.multiAsset.distributedEstimator.stateExchange.estimatorEligibleProfile.enable = true;
i_expectError_(@() revgnss.ConfigFactory.finalizeConfig(invalid), ...
    'DistributedLinkProtocolContract:deliveryDelay');

invalid = i_fleetConfig_(3);
invalid.multiAsset.distributedEstimator.enable = false;
invalid.multiAsset.distributedEstimator.deliveryLedger.enable = true;
i_expectError_(@() revgnss.ConfigFactory.finalizeConfig(invalid), ...
    'IndependentFleetCoordinator:deliveryLedgerRequiresFleet');
end

% ================================================================================================
function i_leafConfigForcesNewSubTogglesOff_()
parentCfg = i_fleetConfig_(3);
parentCfg.multiAsset.distributedEstimator.stateExchange.enable = true;
parentCfg.multiAsset.distributedEstimator.stateExchange.estimatorEligibleProfile.enable = true;
parentCfg.multiAsset.distributedEstimator.deliveryLedger.enable = true;

setup = revgnss.IndependentFleetScenarioFactory.federatedSetup(parentCfg,false);
for assetIndex = 1:setup.N
    leaf = revgnss.IndependentFleetScenarioFactory.stageOneLeafConfigForIndex( ...
        setup,parentCfg,assetIndex);
    assert(~leaf.multiAsset.distributedEstimator.stateExchange.estimatorEligibleProfile.enable && ...
        ~leaf.multiAsset.distributedEstimator.deliveryLedger.enable, ...
        'A per-asset leaf must have both new Section 2.1 sub-toggles forced off.');
    finalized = revgnss.ConfigFactory.finalizeConfig(leaf);
    assert(isstruct(finalized), ...
        'A correctly-forced leaf must still resolve through the exact call chain ReverseGNSSSimulation.initialize performs.');
end

leafBase = revgnss.IndependentFleetScenarioFactory.singleAssetBase(parentCfg,false);
assert(~leafBase.multiAsset.distributedEstimator.stateExchange.estimatorEligibleProfile.enable && ...
    ~leafBase.multiAsset.distributedEstimator.deliveryLedger.enable, ...
    'singleAssetBase must also force both new sub-toggles off.');

badLeaf = revgnss.IndependentFleetScenarioFactory.stageOneLeafConfigForIndex(setup,parentCfg,1);
badLeaf.multiAsset.distributedEstimator.deliveryLedger.enable = true;
i_expectError_(@() revgnss.ConfigFactory.finalizeConfig(badLeaf), ...
    'IndependentFleetCoordinator:perAssetLeafSubToggleUnavailable');
end

% ================================================================================================
function i_communicationEndpointStateConstructionRules_()
record = i_validEndpointStateRecord_();
state = revgnss.CommunicationEndpointState(record);
assert(strcmp(state.stateSource,'estimatorState') && ~state.qualityFlags.truthUsed);

bad = record; bad.qualityFlags.truthUsed = true;
i_expectError_(@() revgnss.CommunicationEndpointState(bad),'CommunicationEndpointState:truthUsed');

bad = record; bad.frameIdentifier = 'ECI';
i_expectError_(@() revgnss.CommunicationEndpointState(bad),'CommunicationEndpointState:frameIdentifier');

bad = record; bad.covarianceBlock = -eye(14);
i_expectError_(@() revgnss.CommunicationEndpointState(bad),'CommunicationEndpointState:covariance');

bad = record; bad.endpointIdentifier = 'spacecraft:2';
i_expectError_(@() revgnss.CommunicationEndpointState(bad),'CommunicationEndpointState:identityMismatch');

bad = record; bad.positionEcef_m = record.positionEcef_m + 1;
i_expectError_(@() revgnss.CommunicationEndpointState(bad), ...
    'CommunicationEndpointState:componentConsistency');

bad = record; bad.productProvenance.productAge_s = 1;
i_expectError_(@() revgnss.CommunicationEndpointState(bad),'CommunicationEndpointState:productAge');

bad = record;
bad.covarianceComponentOrder = ...
    revgnss.DistributedLinkProtocolContract.StateSchemaV1CovarianceComponentOrderEuler;
i_expectError_(@() revgnss.CommunicationEndpointState(bad), ...
    'CommunicationEndpointState:attitudeConventionMismatch');

% A declared terminal geometry is validated with the same rigor as the undeclared case
% (Section 2.3's adapter feeds these metre-valued lever arms directly into the range
% equation): finite 3x1 offsets and nonempty identifiers are required, not merely assigned.
declaredGeometry = record.terminalGeometry;
declaredGeometry.declared = true;
declaredGeometry.transmitTerminalIdentifier = 'terminal:isl-tx';
declaredGeometry.receiveTerminalIdentifier = 'terminal:isl-rx';
declaredGeometry.transmitAntennaIdentifier = 'antenna:isl-tx';
declaredGeometry.receiveAntennaIdentifier = 'antenna:isl-rx';
declaredGeometry.transmitPhaseCentreOffset_body_m = [0.1;0.2;0.3];
declaredGeometry.receivePhaseCentreOffset_body_m = [-0.1;-0.2;-0.3];
good = record; good.terminalGeometry = declaredGeometry;
declaredState = revgnss.CommunicationEndpointState(good);
assert(declaredState.terminalGeometry.declared && ...
    isequal(declaredState.terminalGeometry.transmitPhaseCentreOffset_body_m,[0.1;0.2;0.3]));

bad = good; bad.terminalGeometry.transmitPhaseCentreOffset_body_m = [0.1;0.2;NaN];
i_expectError_(@() revgnss.CommunicationEndpointState(bad),'CommunicationEndpointState:terminalGeometry');

bad = good; bad.terminalGeometry.receivePhaseCentreOffset_body_m = [0.1;0.2];
i_expectError_(@() revgnss.CommunicationEndpointState(bad),'CommunicationEndpointState:terminalGeometry');

bad = good; bad.terminalGeometry.transmitTerminalIdentifier = '';
i_expectError_(@() revgnss.CommunicationEndpointState(bad),'CommunicationEndpointState:terminalGeometry');
end

% ================================================================================================
function i_ownerProviderFromRealSimulation_()
sim = i_singleAssetSim_(1);
epoch_s = sim.tVec(sim.lastEstimatedEpoch);
provider = revgnss.OwnerLocalEstimatorEndpointProvider.fromLocalSimulation(sim,1,epoch_s);
assert(strcmp(provider.endpointIdentifier,'spacecraft:1'));

state = provider.stateAtCoordinateEpoch(epoch_s);
assert(isa(state,'revgnss.CommunicationEndpointState') && ~state.qualityFlags.truthUsed);

sm = sim.ekf.stateMap;
xMeasurement = sim.ekf.getMeasurementState();
assert(isequal(state.positionEcef_m,xMeasurement(sm.r_idx)) && ...
    isequal(state.clockBias_m,xMeasurement(sm.b_rx_idx)), ...
    'The owner provider must read the ESTIMATE, at the exact stateMap indices.');
assert(~isequal(state.positionEcef_m,sim.asset.r_ecef_m(:)), ...
    'The owner provider state must differ from truth (it is the estimator state, not truth).');

% Structural: no property of the provider is a simulation/asset/clock handle.
props = properties(provider);
for index = 1:numel(props)
    value = provider.(props{index});
    assert(~isa(value,'revgnss.ReverseGNSSSimulation') && ~isa(value,'revgnss.SpaceAsset'), ...
        'OwnerLocalEstimatorEndpointProvider must retain no simulation or asset handle.');
end

i_expectError_(@() revgnss.OwnerLocalEstimatorEndpointProvider.fromLocalSimulation(sim,2,epoch_s), ...
    'OwnerLocalEstimatorEndpointProvider:sourceAsset');
i_expectError_(@() provider.stateAtCoordinateEpoch(epoch_s+sim.cfg.simulation.dt_s), ...
    'OwnerLocalEstimatorEndpointProvider:epochOutsideFrozenScope');

notUpdated = revgnss.ReverseGNSSSimulation(i_baseConfig_());
notUpdated.initialize();
i_expectError_(@() revgnss.OwnerLocalEstimatorEndpointProvider.fromLocalSimulation( ...
    notUpdated,1,notUpdated.tVec(1)),'OwnerLocalEstimatorEndpointProvider:localUpdate');
end

% ================================================================================================
function i_ownerProviderRejectsJointStateMap_()
sim = i_singleAssetSim_(1);
assert(isscalar(sim.ekf.stateMap.asset), ...
    'Every EKF stateMap carries an asset field; a single-asset filter must be width 1.');
provider = revgnss.OwnerLocalEstimatorEndpointProvider.fromLocalSimulation( ...
    sim,1,sim.tVec(sim.lastEstimatedEpoch));
assert(isa(provider,'revgnss.OwnerLocalEstimatorEndpointProvider'));

jointSim = i_jointSim_(2);
assert(jointSim.ekf.nSecondaryAssets > 0 && numel(jointSim.ekf.stateMap.asset) > 1, ...
    'A joint 2-asset EKF must carry a joint state map (both discriminators positive).');
i_expectError_(@() revgnss.OwnerLocalEstimatorEndpointProvider.fromLocalSimulation( ...
    jointSim,1,jointSim.tVec(jointSim.lastEstimatedEpoch)), ...
    'OwnerLocalEstimatorEndpointProvider:jointStateMapRejected');
end

% ================================================================================================
function i_remoteProductProfileAndProvider_()
sim = i_singleAssetSim_(2);
epoch_s = sim.tVec(sim.lastEstimatedEpoch);
diagnosticProduct = revgnss.EndpointStateProduct.fromLocalEstimator( ...
    sim,2,epoch_s,0,'spacecraft:2:epoch:s21-remote');

i_expectError_(@() revgnss.FrozenProductEndpointProvider.fromEstimatorEligibleProduct( ...
    diagnosticProduct,epoch_s),'FrozenProductEndpointProvider:productType');

commonSourceTreatment = i_allRejectedCommonSourceTreatment_();
eligibleProduct = revgnss.EstimatorEligibleEndpointStateProduct.fromDiagnosticProduct( ...
    diagnosticProduct,commonSourceTreatment);
assert(eligibleProduct.qualityFlags.estimatorEligible && ~eligibleProduct.qualityFlags.diagnosticOnly);

remoteProvider = revgnss.FrozenProductEndpointProvider.fromEstimatorEligibleProduct( ...
    eligibleProduct,epoch_s);
assert(strcmp(remoteProvider.endpointIdentifier,'spacecraft:2'));
remoteState = remoteProvider.stateAtCoordinateEpoch(epoch_s);
assert(remoteState.productProvenance.productAge_s == 0);

% requireDeliveryProvenance/requireSameEpochScope are actually invoked by the estimator-
% eligible remote-provider path: a delayed offer is rejected with a stated reason, never
% silently treated as current.
i_expectError_(@() revgnss.FrozenProductEndpointProvider.fromEstimatorEligibleProduct( ...
    eligibleProduct,epoch_s+sim.cfg.simulation.dt_s),'DistributedLinkProtocolContract:staleProduct');

% A forged not-diagnostic-only product cannot become estimator-eligible.
record = diagnosticProduct.toStruct();
record.qualityFlags.diagnosticOnly = false;
record.clockAnchorDeclaration = diagnosticProduct.clockAnchorDeclaration;
forgedNotDiagnostic = revgnss.EndpointStateProduct(record);
i_expectError_(@() revgnss.EstimatorEligibleEndpointStateProduct.fromDiagnosticProduct( ...
    forgedNotDiagnostic,commonSourceTreatment),'DistributedLinkProtocolContract:notDiagnosticOnly');

% consumedFlagForbidden is reachable (see EstimatorEligibleEndpointStateProduct order-of-checks
% note): the direct constructor is required to inject a fifth qualityFlags field.
eligibleRecord = eligibleProduct.toStruct();
eligibleRecord.diagnosticProduct = diagnosticProduct;
eligibleRecord.clockAnchorDeclaration = eligibleProduct.clockAnchorDeclaration;
eligibleRecord.qualityFlags.consumedByOwner = false;
i_expectError_(@() revgnss.EstimatorEligibleEndpointStateProduct(eligibleRecord), ...
    'EstimatorEligibleEndpointStateProduct:consumedFlagForbidden');

nonRejected = commonSourceTreatment;
nonRejected.towerClockProduct = 'covarianceGroup';
i_expectError_(@() revgnss.EstimatorEligibleEndpointStateProduct.fromDiagnosticProduct( ...
    diagnosticProduct,nonRejected),'EstimatorEligibleEndpointStateProduct:commonSourceNotRejected');
end

% ================================================================================================
function i_deliveryCanonicalIdentityAndLifecycle_()
sim1 = i_singleAssetSim_(1);
sim2 = i_singleAssetSim_(2);
assert(isequal(sim1.tVec,sim2.tVec), ...
    'Both single-asset fixtures must share one coordinate-time epoch grid.');
epoch_s = sim1.tVec(sim1.lastEstimatedEpoch);
commonSourceTreatment = i_allRejectedCommonSourceTreatment_();

ownerProvider = revgnss.OwnerLocalEstimatorEndpointProvider.fromLocalSimulation(sim1,1,epoch_s);
diagnosticProduct2 = revgnss.EndpointStateProduct.fromLocalEstimator( ...
    sim2,2,epoch_s,0,'spacecraft:2:epoch:s21-delivery');
eligibleProduct2 = revgnss.EstimatorEligibleEndpointStateProduct.fromDiagnosticProduct( ...
    diagnosticProduct2,commonSourceTreatment);
remoteProvider = revgnss.FrozenProductEndpointProvider.fromEstimatorEligibleProduct( ...
    eligibleProduct2,epoch_s);

registry = revgnss.DistributedLinkCalibrationRegistry('singleOwnerRegistry');
registry.declareOwner(i_calibrationDeclaration_('cal:contract-test:X:001','spacecraft:1',1));

record = i_twoWayRangeRecord_('obs:1-2:s21','asset:1','asset:2');
baseArgs = struct( ...
    'physicalObservationRecord',record, ...
    'ownerProvider',ownerProvider, ...
    'remoteProvider',remoteProvider, ...
    'ownerPolicy','initiator', ...
    'roleReversalPolicy','disabled', ...
    'remoteProductPropagationPolicy','frozenSameEpochOnly', ...
    'stateExchangeSettings',struct('maximumAge_s',0,'deliveryDelay_s',0), ...
    'outOfSequencePolicy','reject', ...
    'commonSourceTreatment',commonSourceTreatment, ...
    'correlationPolicy','disabled', ...
    'calibrationRegistry',registry, ...
    'deliveryEpoch_s',epoch_s, ...
    'coordinateEventEpoch_s',epoch_s, ...
    'observableIdentifier','none', ...
    'persistentCalibrationTreatment','externalCalibrationProduct');

[delivery,rejection] = revgnss.LinkObservationDelivery.tryPropose(baseArgs);
assert(~rejection.rejected && isa(delivery,'revgnss.LinkObservationDelivery'), ...
    'A well-formed same-epoch two-way-range delivery must be accepted.');
assert(delivery.ownerCanonicalIndex == 1 && delivery.remoteCanonicalIndex == 2 && ...
    strcmp(delivery.ownerAssetIdentifier,'spacecraft:1') && ...
    strcmp(delivery.remoteAssetIdentifier,'spacecraft:2'));

% CanonicalEndpointIdentity.requireReconciled is actually used, not bypassed: a record whose
% transponder endpoint disagrees with the remote provider's canonical index is rejected.
mismatchedRecord = i_twoWayRangeRecord_('obs:1-9:s21','asset:1','asset:9');
mismatchedArgs = baseArgs;
mismatchedArgs.physicalObservationRecord = mismatchedRecord;
[mismatchedDelivery,mismatchedRejection] = revgnss.LinkObservationDelivery.tryPropose(mismatchedArgs);
assert(isempty(mismatchedDelivery) && mismatchedRejection.rejected && ...
    strcmp(mismatchedRejection.reasonCode,'endpointIdentityUnreconciled'), ...
    'CanonicalEndpointIdentity.requireReconciled must actually reject a mismatched endpoint.');

% ownerPolicy='disabled' cannot propose; roleReversalPolicy other than 'disabled' is refused;
% a time-transfer record has no defined initiator/transponder role.
disabledArgs = baseArgs; disabledArgs.ownerPolicy = 'disabled';
i_expectError_(@() revgnss.LinkObservationDelivery.propose(disabledArgs), ...
    'LinkObservationDelivery:ownerPolicyUnsupported');
reversalArgs = baseArgs; reversalArgs.roleReversalPolicy = 'separateScheduledSession';
i_expectError_(@() revgnss.LinkObservationDelivery.propose(reversalArgs), ...
    'LinkObservationDelivery:roleReversalUnsupported');

% Calibration ownership must be declared for a delivery whose record carries calibration
% product identifiers.
noRegistryArgs = baseArgs; noRegistryArgs.calibrationRegistry = [];
i_expectError_(@() revgnss.LinkObservationDelivery.propose(noRegistryArgs), ...
    'LinkObservationDelivery:calibrationOwnerUndeclared');

% The DEFAULT production registry policy ('undeclared') must reach tryPropose as a precise,
% mapped rejection reason, not escape as rejectionReasonUnmapped -- this is the path every
% currently-legal cfg actually takes (IndependentFleetCoordinator pins policy='undeclared').
defaultPolicyArgs = baseArgs;
defaultPolicyArgs.calibrationRegistry = revgnss.DistributedLinkCalibrationRegistry();
[undeclaredDelivery,undeclaredRejection] = ...
    revgnss.LinkObservationDelivery.tryPropose(defaultPolicyArgs);
assert(isempty(undeclaredDelivery) && undeclaredRejection.rejected && ...
    strcmp(undeclaredRejection.reasonCode,'calibrationOwnerUndeclared') && ...
    strcmp(undeclaredRejection.sourceErrorIdentifier,'DistributedLinkCalibrationRegistry:policyDisabled'), ...
    'The default calibrationOwnership.policy=''undeclared'' path must be a mapped rejection.');

% A singleOwnerRegistry policy with the calibration identifier never declared must also be a
% mapped rejection, not an uncaught throw.
undeclaredStateArgs = baseArgs;
undeclaredStateArgs.calibrationRegistry = revgnss.DistributedLinkCalibrationRegistry('singleOwnerRegistry');
[unknownDelivery,unknownRejection] = revgnss.LinkObservationDelivery.tryPropose(undeclaredStateArgs);
assert(isempty(unknownDelivery) && unknownRejection.rejected && ...
    strcmp(unknownRejection.reasonCode,'calibrationOwnerUndeclared') && ...
    strcmp(unknownRejection.sourceErrorIdentifier, ...
    'DistributedLinkCalibrationRegistry:unknownCalibrationState'), ...
    'An undeclared calibration state under an enabled registry policy must be a mapped rejection.');

% --- Fleet-wide exactly-once ledger, built on this real delivery -------------------------------
ledger = revgnss.DistributedDeliveryLedger();
ledger.recordEligible(delivery);
assert(ledger.numberEligible() == 1 && ledger.numberConsumed() == 0);

i_expectError_(@() ledger.recordEligible(delivery),'DistributedDeliveryLedger:duplicateObservation');
assert(ledger.numberEligible() == 1 && ledger.numberConsumed() == 0, ...
    'A failed recordEligible must leave the ledger unchanged (atomicity).');

i_expectError_(@() ledger.recordConsumed(delivery.observationIdentifier,'spacecraft:99', ...
    delivery.deliveryEpoch_s),'DistributedDeliveryLedger:ownerMismatch');
assert(ledger.numberEligible() == 1 && ledger.numberConsumed() == 0, ...
    'A failed recordConsumed (owner mismatch) must leave the ledger unchanged.');

i_expectError_(@() ledger.recordConsumed(delivery.observationIdentifier,delivery.ownerAssetIdentifier, ...
    delivery.deliveryEpoch_s+1),'DistributedDeliveryLedger:epochMismatch');
assert(ledger.numberEligible() == 1 && ledger.numberConsumed() == 0, ...
    'A failed recordConsumed (epoch mismatch) must leave the ledger unchanged.');

ledger.recordConsumed(delivery.observationIdentifier,delivery.ownerAssetIdentifier, ...
    delivery.deliveryEpoch_s);
assert(ledger.numberEligible() == 0 && ledger.numberConsumed() == 1 && ...
    ledger.isConsumed(delivery.observationIdentifier));

% A second consumption attempt of the SAME physical observation identifier cannot succeed.
i_expectError_(@() ledger.recordConsumed(delivery.observationIdentifier,delivery.ownerAssetIdentifier, ...
    delivery.deliveryEpoch_s),'DistributedDeliveryLedger:alreadyConsumed');
assert(ledger.numberConsumed() == 1, ...
    'A rejected duplicate consumption must not create a second consumption record.');

rejectionRecord = struct('observationIdentifier','obs:rejected:s21','ownerAssetIdentifier', ...
    'spacecraft:1','remoteAssetIdentifier','spacecraft:2', ...
    'remoteProductIdentifier','estimatorProduct:none','sourceEpoch_s',epoch_s, ...
    'deliveryEpoch_s',epoch_s,'reasonCode','remoteProductStale','reasonMessage','stale', ...
    'sourceErrorIdentifier','DistributedLinkProtocolContract:staleProduct', ...
    'physicalRecordClass','revgnss.InterSatelliteObservationRecord', ...
    'observableIdentifier','coherentTwoWayCodeRange','processedObservableType','twoWayCodeRange', ...
    'processedUnits','m','ownerAttributionSource','recordDeclaredEndpointLabel');
ledger.recordRejected(rejectionRecord);
assert(ledger.numberRejected() == 1);
i_expectError_(@() ledger.recordConsumed('obs:rejected:s21','spacecraft:1',epoch_s), ...
    'DistributedDeliveryLedger:alreadyRejected');
i_expectError_(@() ledger.recordEligible(delivery),'DistributedDeliveryLedger:duplicateObservation');

exported = ledger.export();
assert(numel(exported) == 2);
summary = ledger.summary();
assert(summary.consumed == 1 && summary.rejected == 1 && summary.eligible == 0);
end

% ================================================================================================
function i_deliveryRejectionReasonMapping_()
for index = 1:numel(revgnss.LinkObservationDelivery.AllowedRejectionReasonCodes)
    code = revgnss.LinkObservationDelivery.AllowedRejectionReasonCodes{index};
    assert(ischar(code) && ~isempty(code));
end
code = revgnss.LinkObservationDelivery.reasonCodeForIdentifier('CanonicalEndpointIdentity:unreconciled');
assert(strcmp(code,'endpointIdentityUnreconciled'));
i_expectError_(@() revgnss.LinkObservationDelivery.reasonCodeForIdentifier('Not:AMappedIdentifier'), ...
    'LinkObservationDelivery:rejectionReasonUnmapped');

% The two rows a prior review round found pointing at the WRONG reason code (reused
% ownerPolicyUnsupported / propagationPolicyUnsupported instead of their own dedicated codes)
% must now map to their own frozen, distinct codes.
assert(strcmp(revgnss.LinkObservationDelivery.reasonCodeForIdentifier( ...
    'LinkObservationDelivery:commonSourceNotRejected'),'commonSourceNotRejected'));
assert(strcmp(revgnss.LinkObservationDelivery.reasonCodeForIdentifier( ...
    'LinkObservationDelivery:correlationPolicyUnsupported'),'correlationPolicyUnsupported'));
% Previously-unmapped identifiers reachable from propose() (a prior review round found these
% would have escaped tryPropose as rejectionReasonUnmapped instead of a recorded rejection).
assert(strcmp(revgnss.LinkObservationDelivery.reasonCodeForIdentifier( ...
    'LinkObservationDelivery:ownerProviderType'),'providerClassNotSanctioned'));
assert(strcmp(revgnss.LinkObservationDelivery.reasonCodeForIdentifier( ...
    'LinkObservationDelivery:remoteProviderType'),'providerClassNotSanctioned'));
assert(strcmp(revgnss.LinkObservationDelivery.reasonCodeForIdentifier( ...
    'OwnerLocalEstimatorEndpointProvider:epochOutsideFrozenScope'),'productAgeNonZero'));
assert(strcmp(revgnss.LinkObservationDelivery.reasonCodeForIdentifier( ...
    'FrozenProductEndpointProvider:epochOutsideFrozenScope'),'productAgeNonZero'));
assert(strcmp(revgnss.LinkObservationDelivery.reasonCodeForIdentifier( ...
    'DistributedLinkCalibrationRegistry:policyDisabled'),'calibrationOwnerUndeclared'));
assert(strcmp(revgnss.LinkObservationDelivery.reasonCodeForIdentifier( ...
    'DistributedLinkCalibrationRegistry:unknownCalibrationState'),'calibrationOwnerUndeclared'));

% ownerProviderType/remoteProviderType are live-reachable, not just mapped in the abstract.
liveArgs = struct('physicalObservationRecord',i_twoWayRangeRecord_('obs:1-2:providertype', ...
    'asset:1','asset:2'),'ownerProvider',7,'remoteProvider',[], ...
    'ownerPolicy','initiator','roleReversalPolicy','disabled', ...
    'remoteProductPropagationPolicy','frozenSameEpochOnly', ...
    'stateExchangeSettings',struct('maximumAge_s',0,'deliveryDelay_s',0), ...
    'outOfSequencePolicy','reject','commonSourceTreatment',i_allRejectedCommonSourceTreatment_(), ...
    'correlationPolicy','disabled','calibrationRegistry',[],'deliveryEpoch_s',0, ...
    'coordinateEventEpoch_s',0,'observableIdentifier','none', ...
    'persistentCalibrationTreatment','rejected');
[providerTypeDelivery,providerTypeRejection] = revgnss.LinkObservationDelivery.tryPropose(liveArgs);
assert(isempty(providerTypeDelivery) && providerTypeRejection.rejected && ...
    strcmp(providerTypeRejection.reasonCode,'providerClassNotSanctioned'));

% tryPropose must rethrow an unrelated (non-protocol) error rather than disguise it as a
% rejection.
badArgs = struct('physicalObservationRecord',7,'ownerProvider',[],'remoteProvider',[], ...
    'ownerPolicy','initiator','roleReversalPolicy','disabled', ...
    'remoteProductPropagationPolicy','frozenSameEpochOnly', ...
    'stateExchangeSettings',struct('maximumAge_s',0,'deliveryDelay_s',0), ...
    'outOfSequencePolicy','reject','commonSourceTreatment',i_allRejectedCommonSourceTreatment_(), ...
    'correlationPolicy','disabled','calibrationRegistry',[],'deliveryEpoch_s',0, ...
    'coordinateEventEpoch_s',0,'observableIdentifier','none', ...
    'persistentCalibrationTreatment','rejected');
[delivery,rejection] = revgnss.LinkObservationDelivery.tryPropose(badArgs);
assert(isempty(delivery) && rejection.rejected && ...
    strcmp(rejection.reasonCode,'recordClassNotSanctioned'));
end

% ================================================================================================
function i_ledgerReconciliationWithLocalLedgers_()
record = i_twoWayRangeRecord_('obs:1-2:reconcile','asset:1','asset:2');
epoch_s = 0;
localLedger = revgnss.ObservationConsumptionLedger();
localLedger.markEligible(record,epoch_s);
localLedger.consume(record,epoch_s);
assert(any(strcmp(localLedger.consumedIdentifiers(),record.observationIdentifier)));

freshFleetLedger = revgnss.DistributedDeliveryLedger();
report = freshFleetLedger.reconcileWithLocalLedgers({localLedger});
assert(~report.isReconciled && ...
    any(strcmp(report.consumedLocallyWithoutFleetRecord,record.observationIdentifier)), ...
    'A local consumption absent from the fleet-wide ledger must be flagged, not silently ignored.');
i_expectError_(@() revgnss.DistributedDeliveryLedger.requireReconciled(report), ...
    'DistributedDeliveryLedger:reconciliationMismatch');
assert(freshFleetLedger.numberConsumed() == 0 && freshFleetLedger.numberEligible() == 0, ...
    'Reconciliation must be read-only and must not mutate either ledger.');

i_expectError_(@() freshFleetLedger.reconcileWithLocalLedgers({7}), ...
    'DistributedDeliveryLedger:localLedgerType');
end

% ================================================================================================
function i_updateAdapterContractShapeOnly_()
% As of plan Section 4.4, FIVE concrete per-observable adapters are registered
% (coherentTwoWayCodeRange, firstOrderReciprocalClockTransfer, oneWayCode, oneWayDoppler,
% fourTimestampClockDifference -- Sections 2.3.1/2.3.2/2.3-item-3/4.4 respectively); every other
% real observable identifier remains refused, ReservedFutureObservables is empty (every former
% entry is implemented), and an unrelated adapter class name remains unregistered.
assert(isequal(revgnss.DistributedLinkUpdateAdapter.RegisteredAdapterClasses, ...
    {'revgnss.CoherentTwoWayRangeLinkUpdateAdapter', ...
    'revgnss.FirstOrderReciprocalClockTransferLinkUpdateAdapter', ...
    'revgnss.OneWayCodeRangeLinkUpdateAdapter', ...
    'revgnss.OneWayDopplerRangeRateLinkUpdateAdapter', ...
    'revgnss.FourTimestampClockDifferenceLinkUpdateAdapter'}), ...
    'Exactly five concrete per-observable adapters must be registered.');
i_expectError_(@() revgnss.DistributedLinkUpdateAdapter.requireRegisteredAdapter('anything'), ...
    'DistributedLinkUpdateAdapter:adapterNotRegistered');
revgnss.DistributedLinkUpdateAdapter.requireRegisteredAdapter( ...
    'revgnss.CoherentTwoWayRangeLinkUpdateAdapter');
revgnss.DistributedLinkUpdateAdapter.requireObservableSelectable('none');
revgnss.DistributedLinkUpdateAdapter.requireObservableSelectable('coherentTwoWayCodeRange');
revgnss.DistributedLinkUpdateAdapter.requireObservableSelectable('firstOrderReciprocalClockTransfer');
revgnss.DistributedLinkUpdateAdapter.requireObservableSelectable('oneWayCode');
revgnss.DistributedLinkUpdateAdapter.requireObservableSelectable('oneWayDoppler');
revgnss.DistributedLinkUpdateAdapter.requireObservableSelectable('fourTimestampClockDifference');
reserved = revgnss.DistributedLinkUpdateAdapter.ReservedFutureObservables;
assert(isempty(reserved), ...
    'Every previously-reserved observable is now implemented; ReservedFutureObservables must be empty.');
i_expectError_(@() revgnss.DistributedLinkUpdateAdapter.requireObservableSelectable( ...
    'somethingUnknown'),'DistributedLinkUpdateAdapter:observableNotSelectable');

record = i_contractFixtureRecord_();
block = revgnss.DistributedLinkUpdateBlock(record); %#ok<NASGU>

badR = record; badR.independentMeasurementCovariance_m2 = [1 2;3 -4];
i_expectError_(@() revgnss.DistributedLinkUpdateBlock(badR),'DistributedLinkUpdateBlock:measurementCovariance');

badS = record; badS.remoteContributionCovariance_m2 = [-1 0;0 -1];
i_expectError_(@() revgnss.DistributedLinkUpdateBlock(badS), ...
    'DistributedLinkUpdateBlock:remoteContributionCovariance');

badJ = record; badJ.ownerJacobian_mPerErrorUnit = eye(3);
i_expectError_(@() revgnss.DistributedLinkUpdateBlock(badJ),'DistributedLinkUpdateBlock:jacobianDimension');

badComponent = record;
corrupted = badComponent.ownerCovarianceComponentOrder;
corrupted{7} = 'bogusAttitudeErrorLabel';
badComponent.ownerCovarianceComponentOrder = corrupted;
i_expectError_(@() revgnss.DistributedLinkUpdateBlock(badComponent), ...
    'DistributedLinkUpdateBlock:attitudeConvention');

badAssembly = record; badAssembly.residualCovarianceAssembly = 'summed';
i_expectError_(@() revgnss.DistributedLinkUpdateBlock(badAssembly), ...
    'DistributedLinkUpdateBlock:residualCovarianceAssembly');

% 'estimatedOwnerState' is the DistributedLinkProtocolContract vocabulary's spelling, not
% DistributedLinkCalibrationState's ('ownerEstimatedState'); it is simply not a member of
% AllowedPersistentCalibrationTreatments and must keep failing this GENERIC check (Section 2.2
% adds a distinct by-name refusal for the OTHER spelling, tested separately below).
badCalibration = record; badCalibration.persistentCalibrationTreatment = 'estimatedOwnerState';
i_expectError_(@() revgnss.DistributedLinkUpdateBlock(badCalibration), ...
    'DistributedLinkUpdateBlock:persistentCalibrationTreatment');

% Section 2.2: the calibration-state spelling 'ownerEstimatedState' is refused BY NAME, before
% the generic vocabulary check, with the frozen v1-schema reason.
badOwnerEstimated = record; badOwnerEstimated.persistentCalibrationTreatment = 'ownerEstimatedState';
i_expectError_(@() revgnss.DistributedLinkUpdateBlock(badOwnerEstimated), ...
    'DistributedLinkUpdateBlock:ownerEstimatedCalibrationSchemaUnavailable');

% Section 2.2: correlationPolicy is now a two-value frozen set, but 'splitCovarianceIntersection'
% remains EXPRESSIBLE-not-REACHABLE; only the assembly<->policy coupling and inert-sentinel
% rules are exercised here (reachability is tested in
% tests/test_stage2_conservative_correlation_policy.m).
badPolicy = record; badPolicy.correlationPolicy = 'somethingElse';
i_expectError_(@() revgnss.DistributedLinkUpdateBlock(badPolicy), ...
    'DistributedLinkUpdateBlock:correlationPolicyUnsupported');

badCoupling = record; badCoupling.correlationPolicy = 'splitCovarianceIntersection';
i_expectError_(@() revgnss.DistributedLinkUpdateBlock(badCoupling), ...
    'DistributedLinkUpdateBlock:assemblyPolicyMismatch');

badSentinel = record; badSentinel.weightSelectionRule = 'traceMinimisingBoundedSimplexCoordinateDescent';
i_expectError_(@() revgnss.DistributedLinkUpdateBlock(badSentinel), ...
    'DistributedLinkUpdateBlock:inertFieldsNotSentinel');
end

% ================================================================================================
function i_updateBlockKeepsRemoteContributionSeparate_()
block = revgnss.DistributedLinkUpdateBlock(i_contractFixtureRecord_());
props = properties(block);
assert(ismember('independentMeasurementCovariance_m2',props) && ...
    ismember('remoteContributionCovariance_m2',props), ...
    'The two covariance contributions must be distinct, separately reported fields.');
forbiddenSummedNames = {'residualCovariance_m2','innovationCovariance_m2','S_m2', ...
    'combinedRemoteAndCommonCovariance_m2'};
assert(~any(ismember(forbiddenSummedNames,props)), ...
    'No pre-summed residual/innovation covariance field may exist (Section 2.2.2 shortcut).');
assert(strcmp(block.residualCovarianceAssembly,'notAssembledInSection21'), ...
    'The only legal assembly value must assert that no assembly happened.');
end

% ================================================================================================
function i_calibrationSingleOwnerRegistry_()
undeclared = revgnss.DistributedLinkCalibrationRegistry();
i_expectError_(@() undeclared.numberDeclared(),'DistributedLinkCalibrationRegistry:policyDisabled');

registry = revgnss.DistributedLinkCalibrationRegistry('singleOwnerRegistry');
declarationA = i_calibrationDeclaration_('cal:X','spacecraft:1',1);
registry.declareOwner(declarationA);
registry.declareOwner(declarationA);
assert(registry.numberDeclared() == 1, ...
    'An identical re-declaration for the same identifier must be idempotent.');

declarationB = i_calibrationDeclaration_('cal:X','spacecraft:2',2);
i_expectError_(@() registry.declareOwner(declarationB), ...
    'DistributedLinkCalibrationRegistry:duplicateOwner');

i_expectError_(@() registry.requireDeclaredOwnerFor({'cal:X'},'spacecraft:2'), ...
    'DistributedLinkCalibrationRegistry:ownerConflict');
registry.requireDeclaredOwnerFor({'cal:X'},'spacecraft:1');

i_expectError_(@() registry.requireDeclaredOwnerFor({'cal:unknown'},'spacecraft:1'), ...
    'DistributedLinkCalibrationRegistry:unknownCalibrationState');

externalRecord = i_calibrationRecord_('cal:external','',NaN);
externalRecord.ownershipKind = 'externalCalibrationProduct';
externalRecord.externalProductIdentifier = 'product:ext:1';
externalDeclaration = revgnss.DistributedLinkCalibrationState(externalRecord);
registry.declareOwner(externalDeclaration);
i_expectError_(@() registry.requireDeclaredOwnerFor({'cal:external'},'spacecraft:1'), ...
    'DistributedLinkCalibrationRegistry:externalProductOwnerMismatch');

% invariant 8: white-per-row is refused BY NAME, reachably (checked before the generic
% vocabulary error).
whiteRecord = i_calibrationRecord_('cal:white','spacecraft:1',1);
whiteRecord.temporalCovarianceModel = 'whitePerRow';
i_expectError_(@() revgnss.DistributedLinkCalibrationState(whiteRecord), ...
    'DistributedLinkCalibrationState:whiteNoiseTreatmentForbidden');

unknownModelRecord = i_calibrationRecord_('cal:unknownmodel','spacecraft:1',1);
unknownModelRecord.temporalCovarianceModel = 'notAModel';
i_expectError_(@() revgnss.DistributedLinkCalibrationState(unknownModelRecord), ...
    'DistributedLinkCalibrationState:temporalCovarianceModel');

exclusivityRecord = i_calibrationRecord_('cal:both','spacecraft:1',1);
exclusivityRecord.externalProductIdentifier = 'product:conflict';
i_expectError_(@() revgnss.DistributedLinkCalibrationState(exclusivityRecord), ...
    'DistributedLinkCalibrationState:ownerExclusivity');

estimatedRecord = i_calibrationRecord_('cal:estimated','spacecraft:1',1);
estimatedRecord.estimationStatus = 'estimated';
i_expectError_(@() revgnss.DistributedLinkCalibrationState(estimatedRecord), ...
    'DistributedLinkCalibrationState:estimationStatusUnsupported');

% processNoisePsdUnits must match the state-kind-derived units, the same way
% priorVarianceUnits already does; the two are numerically incomparable otherwise.
psdUnitsRecord = i_calibrationRecord_('cal:psdunits','spacecraft:1',1);
psdUnitsRecord.processNoisePsdUnits = 's^2/s';
i_expectError_(@() revgnss.DistributedLinkCalibrationState(psdUnitsRecord), ...
    'DistributedLinkCalibrationState:processNoisePsdUnits');

% An unbounded validity interval is operationally equivalent to no interval at all and must
% be rejected, not silently accepted as it was before this fix.
unboundedRecord = i_calibrationRecord_('cal:unbounded','spacecraft:1',1);
unboundedRecord.validFromLocalTag_s = -Inf;
i_expectError_(@() revgnss.DistributedLinkCalibrationState(unboundedRecord), ...
    'DistributedLinkCalibrationState:validityInterval');
unboundedRecord = i_calibrationRecord_('cal:unbounded2','spacecraft:1',1);
unboundedRecord.validUntilLocalTag_s = Inf;
i_expectError_(@() revgnss.DistributedLinkCalibrationState(unboundedRecord), ...
    'DistributedLinkCalibrationState:validityInterval');
end

% ================================================================================================
function i_disabledTogglesLeaveStageOneUnchanged_()
cfgOff = i_fleetConfig_(3);
cfgOff.multiAsset.distributedEstimator.stateExchange.enable = true;
coordinatorOff = revgnss.IndependentFleetCoordinator(cfgOff);
coordinatorOff.initialize();
coordinatorOff.run();
resultsOff = coordinatorOff.getResults();

cfgOn = i_fleetConfig_(3);
cfgOn.multiAsset.distributedEstimator.stateExchange.enable = true;
cfgOn.multiAsset.distributedEstimator.stateExchange.estimatorEligibleProfile.enable = true;
cfgOn.multiAsset.distributedEstimator.deliveryLedger.enable = true;
coordinatorOn = revgnss.IndependentFleetCoordinator(cfgOn);
coordinatorOn.initialize();
coordinatorOn.run();
resultsOn = coordinatorOn.getResults();

for assetIndex = 1:3
    assert(isequaln(resultsOff.asset{assetIndex}.x,resultsOn.asset{assetIndex}.x) && ...
        isequaln(resultsOff.asset{assetIndex}.P,resultsOn.asset{assetIndex}.P) && ...
        isequaln(resultsOff.asset{assetIndex}.history,resultsOn.asset{assetIndex}.history), ...
        'Enabling the two new Section 2.1 toggles must not change any local estimate.');
end
assert(isequal(resultsOff.stateExchange.generatedProducts,resultsOn.stateExchange.generatedProducts), ...
    'Enabling the two new toggles must not change Stage-1 product counts.');
assert(isequal(resultsOff.linkDelivery,revgnss.DistributedDeliveryLedger.emptySummary()), ...
    'With deliveryLedger.enable=false, results.linkDelivery must be the fixed empty summary.');
assert(resultsOn.linkDelivery.consumed == 0 && resultsOn.linkDelivery.eligible == 0, ...
    'No adapter exists in Section 2.1; the fleet-wide ledger must record zero deliveries.');
assert(isempty(coordinatorOff.estimatorEligibleProducts()) && ...
    ~isempty(coordinatorOn.estimatorEligibleProducts()), ...
    'The estimator-eligible publication path must be additive and toggle-selected.');
end

% ================================================================================================
function i_stageOneJournalAndProductPreserved_()
cfgOff = i_fleetConfig_(2);
cfgOff.multiAsset.distributedEstimator.stateExchange.enable = true;
coordinatorOff = revgnss.IndependentFleetCoordinator(cfgOff);
coordinatorOff.initialize();
coordinatorOff.run();

cfgOn = i_fleetConfig_(2);
cfgOn.multiAsset.distributedEstimator.stateExchange.enable = true;
cfgOn.multiAsset.distributedEstimator.stateExchange.estimatorEligibleProfile.enable = true;
coordinatorOn = revgnss.IndependentFleetCoordinator(cfgOn);
coordinatorOn.initialize();
coordinatorOn.run();

assert(isequaln(coordinatorOff.exchangeJournal.export(),coordinatorOn.exchangeJournal.export()), ...
    'The Stage-1 journal export must be unaffected by the estimator-eligible profile toggle.');
assert(isequaln(coordinatorOff.exchangeJournal.summary(),coordinatorOn.exchangeJournal.summary()));

products = coordinatorOn.exchangeJournal.products();
for index = 1:numel(products)
    revgnss.DistributedLinkProtocolContract.requireDiagnosticOnlyProduct(products{index});
end
eligibleProducts = coordinatorOn.estimatorEligibleProducts();
assert(numel(eligibleProducts) == numel(products), ...
    'One additional estimator-eligible product must exist per Stage-1 diagnostic product.');
end

% ================================================================================================
function i_epochPhaseOrderUnchangedAndCommitOrderingClosed_()
% Formerly i_epochPhaseOrderUnchangedAndBlockerStillOpen_: the local-history-commit
% ordering blocker it asserted is now CLOSED in code, so the assertion is inverted from
% "the open-blocker comment must remain visible" to "the resolved order must remain in
% force". The phase-order freeze itself is unchanged, and nothing here relaxes the
% linkUpdate rejection (covered by i_validateConfigRejectsUnsupportedCombinations_).
expectedOrder = { ...
    'advanceSharedTruthAndLocalPrediction', ...
    'localGroundOnboardUpdate', ...
    'publishAndFreezeEstimatorProducts', ...
    'generateValidateDeliverLinkRecords', ...
    'ownerOnlyLinkUpdate', ...
    'commitLocalHistoryAndConsumption'};
assert(isequal(revgnss.DistributedLinkProtocolContract.EpochFinalizationPhaseOrder,expectedOrder), ...
    'The frozen Section 2.0.1 epoch finalization phase order must not silently change.');

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
src = fileread(fullfile(rootDir,'+revgnss','IndependentFleetCoordinator.m'));
assert(isempty(regexp(src,'OPEN SECTION 2\.1 BLOCKER','once')), ...
    'The local-history-commit ordering blocker is closed; its open-blocker comment must not return.');
deferredCall = strfind(src,'runLocalEstimationEpochWithoutHistoryCommit(epochIndex)');
deliverCall = strfind(src,'generateValidateDeliverLinkRecords_(epochIndex,settings)');
updateCall = strfind(src,'applyOwnerOnlyLinkUpdate_(epochIndex,settings)');
commitCall = strfind(src,'commitPendingEpochHistory()');
assert(isscalar(deferredCall) && isscalar(deliverCall) && isscalar(updateCall) && ...
    isscalar(commitCall) && ~contains(src,'runLocalEstimationEpoch(epochIndex)'), ...
    ['The per-epoch loop must call the deferred-commit local estimation entry point once ' ...
     'and release it once, never the immediate-commit variant.']);
assert(deferredCall < deliverCall && deliverCall < updateCall && updateCall < commitCall, ...
    ['The local history/report-data commit must run AFTER the link-record delivery and ' ...
     'owner-only link-update phases, so a future update is described by the same epoch row.']);
end

% ================================================================================================
% Fixtures and helpers
% ================================================================================================

function sim = i_singleAssetSim_(physicalAssetIndex)
cfg = i_baseConfig_();
cfg.asset.physicalAssetIndex = physicalAssetIndex;
cfg.assets = cfg.asset;  % keep cfg.assets/cfg.asset field-homogeneous (MultiAssetConfig.normalize)
sim = revgnss.ReverseGNSSSimulation(cfg);
sim.initialize();
sim.advanceTruthEpoch(1);
sim.runLocalEstimationEpoch(1);
end

function sim = i_jointSim_(nAssets)
cfg = revgnss.ConfigFactory.defaultConfig();
cfg.simulation.duration_s = 2;
cfg.simulation.dt_s = 1;
cfg.scenario.nSpaceAssets = nAssets;
cfg.multiAsset.mode = 'joint';
cfg.estimator.starTracker.enable = false;
cfg.estimator.imu.enable = false;
sim = revgnss.ReverseGNSSSimulation(cfg);
sim.initialize();
sim.advanceTruthEpoch(1);
sim.runLocalEstimationEpoch(1);
end

function record = i_validEndpointStateRecord_()
x = (1:14)'*1.0;
x(7:9) = [0.01;0.02;0.03];
P = eye(14);
order = revgnss.DistributedLinkProtocolContract.StateSchemaV1CovarianceComponentOrderTangent;
record = struct( ...
    'endpointIdentifier','spacecraft:1', ...
    'canonicalPhysicalAssetIndex',1, ...
    'stateSource','estimatorState', ...
    'stateOrigin','ownerLocalEstimator', ...
    'coordinateEpoch_s',0, ...
    'stateEvaluationPolicy','frozenSameEpochOnly', ...
    'coordinateTimeScale',revgnss.DistributedLinkProtocolContract.CoordinateTimeScale, ...
    'frameIdentifier',revgnss.DistributedLinkProtocolContract.FrameIdentifier, ...
    'clockDatumIdentifier',revgnss.DistributedLinkProtocolContract.ClockDatumIdentifier, ...
    'stateSchemaVersion',revgnss.DistributedLinkProtocolContract.StateSchemaVersion, ...
    'attitudeErrorCoordinateConvention','rightMultiplicativeLocalTangent_rad', ...
    'stateComponentOrder',{revgnss.DistributedLinkProtocolContract.StateSchemaV1StateComponentOrder}, ...
    'covarianceComponentOrder',{order}, ...
    'stateVector',x, ...
    'covarianceBlock',P, ...
    'positionEcef_m',x(1:3), ...
    'velocityEcef_mps',x(4:6), ...
    'attitudeEulerZyx_rad',x(7:9), ...
    'angularRateBody_radps',x(10:12), ...
    'clockBias_m',x(13), ...
    'clockDriftRate_mps',x(14), ...
    'terminalGeometry',struct('declared',false, ...
        'transmitTerminalIdentifier','terminal:undeclared', ...
        'receiveTerminalIdentifier','terminal:undeclared', ...
        'transmitAntennaIdentifier','antenna:undeclared', ...
        'receiveAntennaIdentifier','antenna:undeclared', ...
        'transmitPhaseCentreOffset_body_m',zeros(3,1), ...
        'receivePhaseCentreOffset_body_m',zeros(3,1)), ...
    'productProvenance',struct('sourceKind','ownerLocalEstimator','productIdentifier','', ...
        'sequenceIdentifier','','sourceEpoch_s',0,'deliveryEpoch_s',0,'productAge_s',0, ...
        'dynamicsMode','unspecified','clockModel','unspecified','timeStep_s',1), ...
    'qualityFlags',struct('estimatorDerived',true,'truthUsed',false,'diagnosticOnly',false, ...
        'estimatorEligible',true), ...
    'clockAnchorDeclaration',i_anchoredClockDeclaration_('spacecraft:1',1));
end

function declaration = i_anchoredClockDeclaration_(endpointIdentifier, canonicalPhysicalAssetIndex)
minimalCfg = struct('scenario',struct('nTowers',5), ...
    'estimator',struct('towerClockMode','perfectCorrection'), ...
    'clock',struct('mode','spacecraftReceiverClockOnly', ...
        'gauge',struct('mode','externalTowerCorrections','referenceTowerIndex',1)));
declaration = revgnss.EndpointClockAnchorDeclaration.fromLocalEstimatorConfig( ...
    minimalCfg,endpointIdentifier,canonicalPhysicalAssetIndex);
end

function treatment = i_allRejectedCommonSourceTreatment_()
treatment = struct('towerClockProduct','rejected','terminalCalibration','rejected', ...
    'transmittedStateProduct','rejected','sessionTimingProduct','rejected', ...
    'sharedForceAtmosphericProduct','rejected');
end

function hardware = i_twoWayHardware_(source)
hardware = revgnss.CoherentTwoWayCodeHardwareModel( ...
    parameterSource=source,physicalChainIdentifier='chain:s21-test:X', ...
    calibrationProductIdentifier='cal:contract-test:X:001', ...
    turnaroundProperTime_s=1e-6,codeRateTurnaroundRatio=1);
end

function record = i_twoWayRangeRecord_(observationId, initiatorAssetId, transponderAssetId)
initiatorTruth = revgnss.TwoWayCodeEndpointModel.constantVelocity( ...
    'physicalTruth',initiatorAssetId,[0;0;0],zeros(3,1),0);
transponderTruth = revgnss.TwoWayCodeEndpointModel.constantVelocity( ...
    'physicalTruth',transponderAssetId,[5e5;0;0],zeros(3,1),0);
physical = i_twoWayHardware_('physicalTruth');
calibration = i_twoWayHardware_('calibrationProduct');
metadata = struct( ...
    'observationIdentifier',observationId, ...
    'sessionIdentifier',['session:' observationId], ...
    'signalIdentifier','PN1', ...
    'covarianceGroupIdentifier',observationId, ...
    'covarianceRowIndex',1,'covarianceBlock_m2',1, ...
    'carrierToNoiseDensity_dBHz',45,'available',true, ...
    'qualityFlags',struct('codeLock',true), ...
    'truthDiagnosticIdentifier',['truth:' observationId]);
record = revgnss.CoherentTwoWayCodeRangingModel.simulateObservation( ...
    initiatorTruth,transponderTruth,physical,calibration,20,metadata);
end

function declaration = i_calibrationDeclaration_(identifier, ownerAssetIdentifier, ownerCanonicalIndex)
declaration = revgnss.DistributedLinkCalibrationState( ...
    i_calibrationRecord_(identifier,ownerAssetIdentifier,ownerCanonicalIndex));
end

function record = i_calibrationRecord_(identifier, ownerAssetIdentifier, ownerCanonicalIndex)
record = struct( ...
    'calibrationStateIdentifier',identifier, ...
    'scopeIdentifier',['link:' identifier], ...
    'stateKind','linkRangeBiasResidual_m', ...
    'ownershipKind','ownerEstimatedState', ...
    'ownerAssetIdentifier',ownerAssetIdentifier, ...
    'ownerCanonicalIndex',ownerCanonicalIndex, ...
    'externalProductIdentifier','', ...
    'temporalCovarianceModel','notDeclared', ...
    'correlationTime_s',NaN, ...
    'processNoisePsd_perS',0, ...
    'processNoisePsdUnits','m^2/s', ...
    'priorVariance',1, ...
    'priorVarianceUnits','m^2', ...
    'validFromLocalTag_s',-1e6, ...
    'validUntilLocalTag_s',1e6, ...
    'estimationStatus','notEstimated');
end

function record = i_contractFixtureRecord_()
order = revgnss.DistributedLinkProtocolContract.StateSchemaV1CovarianceComponentOrderTangent;
n = numel(order);
record = struct( ...
    'observationIdentifier','obs:contract-fixture', ...
    'deliveryIdentifier','delivery:contract-fixture', ...
    'ownerAssetIdentifier','spacecraft:1', ...
    'remoteAssetIdentifier','spacecraft:2', ...
    'remoteProductIdentifier','estimatorProduct:contract-fixture', ...
    'coordinateEventEpoch_s',0, ...
    'observableIdentifier','contractFixtureObservable', ...
    'residual_m',[0;0], ...
    'ownerCovarianceComponentOrder',{order}, ...
    'remoteCovarianceComponentOrder',{order}, ...
    'ownerAttitudeErrorCoordinateConvention','rightMultiplicativeLocalTangent_rad', ...
    'remoteAttitudeErrorCoordinateConvention','rightMultiplicativeLocalTangent_rad', ...
    'ownerJacobian_mPerErrorUnit',[eye(2),zeros(2,n-2)], ...
    'remoteJacobian_mPerErrorUnit',[eye(2),zeros(2,n-2)], ...
    'independentMeasurementCovariance_m2',eye(2), ...
    'remoteContributionCovariance_m2',eye(2), ...
    'residualCovarianceAssembly','notAssembledInSection21', ...
    'persistentCalibrationTreatment','rejected', ...
    'calibrationStateIdentifiers',{{}}, ...
    'covarianceGroupIdentifiers',{{}}, ...
    'correlationPolicy','disabled', ...
    'weightSelectionRule','notApplicable', ...
    'commonSourceContributionCovariances_m2',{{}}, ...
    'calibrationMappingJacobian_mPerCalibrationUnit',zeros(2,0), ...
    'calibrationStateUnits',{{}}, ...
    'persistentCalibrationReferenceLocalTag_s',NaN, ...
    'observableRowUnits','m');
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

function cfg = i_fleetConfig_(nAssets)
cfg = i_baseConfig_();
cfg.scenario.nSpaceAssets = nAssets;
cfg.multiAsset.mode = 'fast';
cfg.multiAsset.estimateMode = 'off';
cfg.multiAsset.keepIslInPerAssetEkf = false;
cfg.multiAsset.towersObserveSecondaries = false;
cfg.multiAsset.distributedEstimator.enable = true;
cfg.multiAsset.distributedEstimator.stateExchange.enable = false;
cfg.multiAsset.distributedEstimator.linkUpdate.enable = false;
cfg.multiAsset.distributedEstimator.linkUpdate.ownerPolicy = 'disabled';
cfg.multiAsset.distributedEstimator.linkUpdate.correlationPolicy = 'disabled';
cfg.measurements.isl.enable = false;
cfg.measurements.isl.code.enable = false;
cfg.measurements.isl.code.useInEKF = false;
cfg.measurements.isl.doppler.enable = false;
cfg.measurements.isl.doppler.useInEKF = false;
cfg.measurements.isl.carrier.enable = false;
cfg.measurements.isl.carrier.useInEKF = false;
cfg.measurements.isl.timing.enable = false;
cfg.measurements.isl.twoWay.enable = false;
cfg.measurements.isl.twoWay.range.enable = false;
cfg.measurements.isl.twoWay.range.useInEKF = false;
cfg.measurements.isl.twoWay.doppler.enable = false;
cfg.measurements.isl.twoWay.doppler.useInEKF = false;
cfg.measurements.isl.twoWay.timeTransfer.enable = false;
cfg.measurements.isl.twoWay.timeTransfer.useInEKF = false;
end

function i_expectError_(action,identifier)
try
    action();
catch ME
    assert(strcmp(ME.identifier,identifier), ...
        'Expected %s, received %s (%s).',identifier,ME.identifier,ME.message);
    return
end
error('test_stage2_communication_interfaces:missingError', ...
    'Expected error %s was not raised.',identifier);
end
