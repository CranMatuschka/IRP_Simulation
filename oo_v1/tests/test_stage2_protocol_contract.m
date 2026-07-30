function test_stage2_protocol_contract()
% test_stage2_protocol_contract  Stage-2 Section 2.0 frozen protocol contract.
%
% Covers: correlation/clock-claim vocabulary defaults and manifest visibility,
% validateConfig rejection of any non-default vocabulary value, the canonical
% 'spacecraft:N' vs 'asset:N' endpoint identity resolver, the same-epoch-scope
% gate, the frozen EndpointStateProduct state-schema-version contract, and a
% regression smoke check that the additive per-epoch link-phase hooks leave
% Stage-1 behaviour unchanged.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
addpath(rootDir);
addpath(fullfile(rootDir,'config'));
addpath(fullfile(rootDir,'config','internal'));

fprintf('=== test_stage2_protocol_contract ===\n');
i_configDefaultsAndManifest_();
i_validateConfigRejectsNonDefaultVocabulary_();
i_canonicalEndpointIdentity_();
i_sameEpochScopeGuard_();
i_commonSourceTreatmentAndClockClaimDirect_();
i_stateSchemaAndDeliveryProvenance_();
i_covarianceGroupAndCalibrationProvenance_();
i_immutabilityInvariant_();
i_epochPhaseOrderAndRegressionSmoke_();
fprintf('=== test_stage2_protocol_contract: ALL PASS ===\n');
end

function i_configDefaultsAndManifest_()
cfg = masterConfig();
linkUpdate = cfg.multiAsset.distributedEstimator.linkUpdate;
expectedCommon = {'towerClockProduct','terminalCalibration','transmittedStateProduct', ...
    'sessionTimingProduct','sharedForceAtmosphericProduct'};
for index = 1:numel(expectedCommon)
    assert(strcmp(linkUpdate.commonSourceTreatment.(expectedCommon{index}),'rejected'), ...
        'Every Stage-2 common-source treatment must default to rejected.');
end
assert(strcmp(linkUpdate.timeTransferClockClaim,'relativeBiasOnly'), ...
    'The Stage-2 clock claim must default to relativeBiasOnly.');

resolvedDefault = revgnss.ConfigFactory.defaultConfig();
resolvedMaster = revgnss.ConfigFactory.finalizeConfig(masterConfig());
assert(isequaln(resolvedDefault.multiAsset.distributedEstimator.linkUpdate, ...
    resolvedMaster.multiAsset.distributedEstimator.linkUpdate), ...
    'The Stage-2 protocol-contract fields must resolve identically from every master-config entry path.');

manifest = revgnss.SimulationToggleManifest.fromConfig(cfg);
paths = {manifest.cfgPath};
required = { ...
    'cfg.multiAsset.distributedEstimator.linkUpdate.commonSourceTreatment.towerClockProduct', ...
    'cfg.multiAsset.distributedEstimator.linkUpdate.commonSourceTreatment.terminalCalibration', ...
    'cfg.multiAsset.distributedEstimator.linkUpdate.commonSourceTreatment.transmittedStateProduct', ...
    'cfg.multiAsset.distributedEstimator.linkUpdate.commonSourceTreatment.sessionTimingProduct', ...
    'cfg.multiAsset.distributedEstimator.linkUpdate.commonSourceTreatment.sharedForceAtmosphericProduct', ...
    'cfg.multiAsset.distributedEstimator.linkUpdate.timeTransferClockClaim'};
assert(all(ismember(required,paths)), ...
    'Every Stage-2 protocol-contract control must be visible in the toggle manifest.');
end

function i_validateConfigRejectsNonDefaultVocabulary_()
invalid = i_fleetConfig_(3);
invalid.multiAsset.distributedEstimator.linkUpdate.commonSourceTreatment.towerClockProduct = ...
    'covarianceGroup';
i_expectError_(@() revgnss.ConfigFactory.finalizeConfig(invalid), ...
    'IndependentFleetCoordinator:linkUpdateUnavailable');

invalid = i_fleetConfig_(3);
invalid.multiAsset.distributedEstimator.linkUpdate.commonSourceTreatment.terminalCalibration = ...
    'unknownWord';
i_expectError_(@() revgnss.ConfigFactory.finalizeConfig(invalid), ...
    'DistributedLinkProtocolContract:commonSourceValue');

invalid = i_fleetConfig_(3);
invalid.multiAsset.distributedEstimator.linkUpdate.timeTransferClockClaim = 'absolute';
i_expectError_(@() revgnss.ConfigFactory.finalizeConfig(invalid), ...
    'DistributedLinkProtocolContract:clockClaim');

invalid = i_fleetConfig_(3);
invalid.multiAsset.distributedEstimator.linkUpdate = rmfield( ...
    invalid.multiAsset.distributedEstimator.linkUpdate,'commonSourceTreatment');
i_expectError_(@() revgnss.ConfigFactory.finalizeConfig(invalid), ...
    'IndependentFleetCoordinator:linkUpdateSchema');

valid = i_fleetConfig_(3);
resolved = revgnss.ConfigFactory.finalizeConfig(valid);
assert(isstruct(resolved), ...
    'A Stage-1-legal fleet config with the frozen Stage-2 defaults must still resolve.');
end

function i_canonicalEndpointIdentity_()
productId = revgnss.CanonicalEndpointIdentity.fromProductIdentifier('spacecraft:3');
assert(productId.physicalAssetIndex == 3 && ...
    strcmp(productId.sourceIdentifierScheme,'productSpacecraftIndex'), ...
    'A well-formed spacecraft:N identifier must resolve to physical index N.');

recordId = revgnss.CanonicalEndpointIdentity.fromRecordIdentifier('asset:3');
assert(recordId.physicalAssetIndex == 3 && ...
    strcmp(recordId.sourceIdentifierScheme,'recordAssetIndex'), ...
    'A well-formed asset:N identifier must resolve to physical index N.');

revgnss.CanonicalEndpointIdentity.requireReconciled('spacecraft:3','asset:3');

i_expectError_(@() revgnss.CanonicalEndpointIdentity.requireReconciled('spacecraft:3','asset:4'), ...
    'CanonicalEndpointIdentity:unreconciled');
i_expectError_(@() revgnss.CanonicalEndpointIdentity.fromProductIdentifier('asset:3'), ...
    'CanonicalEndpointIdentity:unknownScheme');
i_expectError_(@() revgnss.CanonicalEndpointIdentity.fromRecordIdentifier('spacecraft:3'), ...
    'CanonicalEndpointIdentity:unknownScheme');
i_expectError_(@() revgnss.CanonicalEndpointIdentity.fromProductIdentifier('tower:003'), ...
    'CanonicalEndpointIdentity:unknownScheme');
i_expectError_(@() revgnss.CanonicalEndpointIdentity.fromProductIdentifier('spacecraft:0'), ...
    'CanonicalEndpointIdentity:invalidIndex');
end

function i_sameEpochScopeGuard_()
revgnss.DistributedLinkProtocolContract.requireSameEpochScope( ...
    struct('maximumAge_s',0,'deliveryDelay_s',0));
i_expectError_(@() revgnss.DistributedLinkProtocolContract.requireSameEpochScope( ...
    struct('maximumAge_s',1,'deliveryDelay_s',0)), ...
    'DistributedLinkProtocolContract:maximumAge');
i_expectError_(@() revgnss.DistributedLinkProtocolContract.requireSameEpochScope( ...
    struct('maximumAge_s',0,'deliveryDelay_s',2)), ...
    'DistributedLinkProtocolContract:deliveryDelay');

revgnss.DistributedLinkProtocolContract.requireOutOfSequenceRejected('reject');
i_expectError_(@() revgnss.DistributedLinkProtocolContract.requireOutOfSequenceRejected( ...
    'acceptDelayed'),'DistributedLinkProtocolContract:outOfSequencePolicy');
end

function i_commonSourceTreatmentAndClockClaimDirect_()
allRejected = struct('towerClockProduct','rejected','terminalCalibration','rejected', ...
    'transmittedStateProduct','rejected','sessionTimingProduct','rejected', ...
    'sharedForceAtmosphericProduct','rejected');
revgnss.DistributedLinkProtocolContract.requireCommonSourceTreatmentDeclared(allRejected);
assert(revgnss.DistributedLinkProtocolContract.isFullyRejectedCommonSourceTreatment(allRejected), ...
    'A fully-rejected common-source treatment struct must report as fully rejected.');

missingField = rmfield(allRejected,'sessionTimingProduct');
i_expectError_(@() revgnss.DistributedLinkProtocolContract.requireCommonSourceTreatmentDeclared( ...
    missingField),'DistributedLinkProtocolContract:commonSourceMissing');

badValue = allRejected;
badValue.terminalCalibration = 'notAWord';
i_expectError_(@() revgnss.DistributedLinkProtocolContract.requireCommonSourceTreatmentDeclared( ...
    badValue),'DistributedLinkProtocolContract:commonSourceValue');

oneDeclared = allRejected;
oneDeclared.towerClockProduct = 'covarianceGroup';
revgnss.DistributedLinkProtocolContract.requireCommonSourceTreatmentDeclared(oneDeclared);
assert(~revgnss.DistributedLinkProtocolContract.isFullyRejectedCommonSourceTreatment(oneDeclared), ...
    'A declared (non-rejected) common source must not report as fully rejected.');

revgnss.DistributedLinkProtocolContract.requireClockClaim('relativeBiasOnly');
i_expectError_(@() revgnss.DistributedLinkProtocolContract.requireClockClaim('absolute'), ...
    'DistributedLinkProtocolContract:clockClaim');
i_expectError_(@() revgnss.DistributedLinkProtocolContract.requireClockClaim('drift'), ...
    'DistributedLinkProtocolContract:clockClaim');
end

function i_stateSchemaAndDeliveryProvenance_()
cfg = i_fleetConfig_(2);
cfg.multiAsset.distributedEstimator.stateExchange.enable = true;
coordinator = revgnss.IndependentFleetCoordinator(cfg);
coordinator.initialize();
coordinator.run();
products = coordinator.exchangeJournal.products();
assert(~isempty(products),'A Stage-2 test fleet run must publish at least one state product.');
product = products{1};

variant = revgnss.DistributedLinkProtocolContract.requireStateSchemaVersion(product);
assert(any(strcmp(variant,{'euler','tangent'})), ...
    'requireStateSchemaVersion must report which attitude-covariance variant matched.');
revgnss.DistributedLinkProtocolContract.requireDiagnosticOnlyProduct(product);
revgnss.DistributedLinkProtocolContract.requireDeliveryProvenance(product,product.validAtEpoch_s);

record = product.toStruct();
record.qualityFlags.diagnosticOnly = false;
forgedNotDiagnostic = revgnss.EndpointStateProduct(record);
i_expectError_(@() revgnss.DistributedLinkProtocolContract.requireDiagnosticOnlyProduct( ...
    forgedNotDiagnostic),'DistributedLinkProtocolContract:notDiagnosticOnly');
i_expectError_(@() revgnss.DistributedLinkProtocolContract.requireDeliveryProvenance( ...
    forgedNotDiagnostic,forgedNotDiagnostic.validAtEpoch_s), ...
    'DistributedLinkProtocolContract:notDiagnosticOnly');

record = product.toStruct();
record.qualityFlags.consumedByEstimator = true;
forgedConsumed = revgnss.EndpointStateProduct(record);
i_expectError_(@() revgnss.DistributedLinkProtocolContract.requireDiagnosticOnlyProduct( ...
    forgedConsumed),'DistributedLinkProtocolContract:notDiagnosticOnly');

record = product.toStruct();
record.stateComponentOrder{1} = 'wrongLabel';
forgedStateOrder = revgnss.EndpointStateProduct(record);
i_expectError_(@() revgnss.DistributedLinkProtocolContract.requireStateSchemaVersion( ...
    forgedStateOrder),'DistributedLinkProtocolContract:stateComponentOrder');

record = product.toStruct();
record.covarianceComponentOrder{7} = 'bogusAttitudeErrorLabel';
forgedCovOrder = revgnss.EndpointStateProduct(record);
i_expectError_(@() revgnss.DistributedLinkProtocolContract.requireStateSchemaVersion( ...
    forgedCovOrder),'DistributedLinkProtocolContract:covarianceComponentOrder');

record = product.toStruct();
record.processModelProvenance.attitudeCovarianceCoordinates = 'unknownConvention';
forgedAttitude = revgnss.EndpointStateProduct(record);
i_expectError_(@() revgnss.DistributedLinkProtocolContract.requireDeliveryProvenance( ...
    forgedAttitude,forgedAttitude.validAtEpoch_s),'DistributedLinkProtocolContract:attitudeConvention');

% The declared convention is a known word, but it disagrees with the covariance labels this
% product actually carries -- must be rejected as a mismatch, not accepted as "a known word".
record = product.toStruct();
if strcmp(variant,'euler')
    record.processModelProvenance.attitudeCovarianceCoordinates = ...
        'rightMultiplicativeLocalTangent_rad';
else
    record.processModelProvenance.attitudeCovarianceCoordinates = 'eulerZYXError_rad';
end
forgedConventionMismatch = revgnss.EndpointStateProduct(record);
i_expectError_(@() revgnss.DistributedLinkProtocolContract.requireDeliveryProvenance( ...
    forgedConventionMismatch,forgedConventionMismatch.validAtEpoch_s), ...
    'DistributedLinkProtocolContract:attitudeConventionMismatch');

record = product.toStruct();
record.sourceAssetIdentifier = 'spacecraft:99';
forgedIdentity = revgnss.EndpointStateProduct(record);
i_expectError_(@() revgnss.DistributedLinkProtocolContract.requireDeliveryProvenance( ...
    forgedIdentity,forgedIdentity.validAtEpoch_s),'DistributedLinkProtocolContract:identityMismatch');

i_expectError_(@() revgnss.DistributedLinkProtocolContract.requireDeliveryProvenance( ...
    product,product.validAtEpoch_s-1),'DistributedLinkProtocolContract:notYetDelivered');
if product.deliveryEpoch_s ~= product.validAtEpoch_s
    i_expectError_(@() revgnss.DistributedLinkProtocolContract.requireDeliveryProvenance( ...
        product,product.deliveryEpoch_s),'DistributedLinkProtocolContract:staleProduct');
end
i_expectError_(@() revgnss.DistributedLinkProtocolContract.requireDeliveryProvenance( ...
    product,product.validAtEpoch_s+1),'DistributedLinkProtocolContract:staleProduct');
end

function i_covarianceGroupAndCalibrationProvenance_()
initiatorTruth = revgnss.TwoWayCodeEndpointModel.constantVelocity( ...
    'physicalTruth','spacecraft:A',[0;0;0],zeros(3,1),0);
transponderTruth = revgnss.TwoWayCodeEndpointModel.constantVelocity( ...
    'physicalTruth','spacecraft:B',[5e5;0;0],zeros(3,1),0);
physical = i_twoWayHardware_('physicalTruth');
calibration = i_twoWayHardware_('calibrationProduct');
metadata = i_twoWayMetadata_('obs:A-B:contract-test');
observation = revgnss.CoherentTwoWayCodeRangingModel.simulateObservation( ...
    initiatorTruth,transponderTruth,physical,calibration,20,metadata);

revgnss.DistributedLinkProtocolContract.requireSingletonCovarianceGroup(observation);
revgnss.DistributedLinkProtocolContract.requireCalibrationProvenance(observation);

sharedGroupMetadata = i_twoWayMetadata_('cov:shared-group-not-implemented');
sharedGroupObservation = revgnss.CoherentTwoWayCodeRangingModel.simulateObservation( ...
    initiatorTruth,transponderTruth,physical,calibration,20,sharedGroupMetadata);
i_expectError_(@() revgnss.DistributedLinkProtocolContract.requireSingletonCovarianceGroup( ...
    sharedGroupObservation),'DistributedLinkProtocolContract:covarianceGroupNotSingleton');

record = observation.toStruct();
record.calibrationProductIdentifiers = {};
noCalibration = revgnss.InterSatelliteObservationRecord(record);
i_expectError_(@() revgnss.DistributedLinkProtocolContract.requireCalibrationProvenance( ...
    noCalibration),'DistributedLinkProtocolContract:calibrationMissing');
end

function i_immutabilityInvariant_()
cfg = i_fleetConfig_(2);
cfg.multiAsset.distributedEstimator.stateExchange.enable = true;
coordinator = revgnss.IndependentFleetCoordinator(cfg);
coordinator.initialize();
coordinator.run();
product = coordinator.exchangeJournal.products();
product = product{1};
try
    product.sourceAssetIndex = 99; %#ok<NASGU>
    error('test_stage2_protocol_contract:mutableProduct', ...
        'An EndpointStateProduct must not accept a post-construction mutation.');
catch ME
    assert(~strcmp(ME.identifier,'test_stage2_protocol_contract:mutableProduct'), ...
        'A frozen remote product must be structurally immutable.');
end
end

function i_epochPhaseOrderAndRegressionSmoke_()
expectedOrder = { ...
    'advanceSharedTruthAndLocalPrediction', ...
    'localGroundOnboardUpdate', ...
    'publishAndFreezeEstimatorProducts', ...
    'generateValidateDeliverLinkRecords', ...
    'ownerOnlyLinkUpdate', ...
    'commitLocalHistoryAndConsumption'};
assert(isequal(revgnss.DistributedLinkProtocolContract.EpochFinalizationPhaseOrder, ...
    expectedOrder), ...
    'The frozen Section 2.0.1 epoch finalization phase order must not silently change.');

cfg = i_fleetConfig_(6);
cfg.multiAsset.distributedEstimator.stateExchange.enable = true;
cfg.multiAsset.distributedEstimator.stateExchange.deliveryDelay_s = 1;
coordinator = revgnss.IndependentFleetCoordinator(cfg);
coordinator.initialize();
coordinator.run();
results = coordinator.getResults();
assert(results.N == 6 && results.linkObservationCounters.generated == 0 && ...
    results.linkObservationCounters.delivered == 0 && ...
    results.linkObservationCounters.consumedByOwner == 0, ...
    ['Adding the additive per-epoch link-delivery phase hooks must not change Stage-1 ' ...
    'link-observation accounting.']);
assert(results.stateExchange.generatedProducts == results.N*numel(coordinator.tVec), ...
    'Adding the additive per-epoch link-delivery phase hooks must not change product counts.');
end

function hardware = i_twoWayHardware_(source)
hardware = revgnss.CoherentTwoWayCodeHardwareModel( ...
    parameterSource=source,physicalChainIdentifier='chain:contract-test:X', ...
    calibrationProductIdentifier='cal:contract-test:X:001', ...
    turnaroundProperTime_s=1e-6,codeRateTurnaroundRatio=1);
end

function metadata = i_twoWayMetadata_(covarianceGroupIdentifier)
metadata = struct( ...
    'observationIdentifier','obs:A-B:contract-test', ...
    'sessionIdentifier','session:A-B:contract-test', ...
    'signalIdentifier','PN1', ...
    'covarianceGroupIdentifier',covarianceGroupIdentifier, ...
    'covarianceRowIndex',1,'covarianceBlock_m2',1, ...
    'carrierToNoiseDensity_dBHz',45,'available',true, ...
    'qualityFlags',struct('codeLock',true), ...
    'truthDiagnosticIdentifier','truth:A-B:contract-test');
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
        'Expected %s, received %s.',identifier,ME.identifier);
    return
end
error('test_stage2_protocol_contract:missingError', ...
    'Expected error %s was not raised.',identifier);
end
