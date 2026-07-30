function test_independent_fleet_stage1()
% test_independent_fleet_stage1  Stage-1 independent local-EKF contracts.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
addpath(rootDir);
addpath(fullfile(rootDir,'config'));
addpath(fullfile(rootDir,'config','internal'));

fprintf('=== test_independent_fleet_stage1 ===\n');
i_defaultsAndGuards_();
i_factoryAndEpochParity_();
i_legacyFanoutCharacterization_();
i_coordinatorAndJournal_();
i_reportRouting_();
fprintf('=== test_independent_fleet_stage1: ALL PASS ===\n');
end

function i_defaultsAndGuards_()
cfg = masterConfig();
settings = cfg.multiAsset.distributedEstimator;
assert(~settings.enable && ~settings.stateExchange.enable && ...
    ~settings.linkUpdate.enable, ...
    'Stage-1 runtime and every estimator-link update must default disabled.');
assert(strcmp(settings.executionMode,'epochSynchronous') && ...
    strcmp(settings.outOfSequencePolicy,'reject') && ...
    strcmp(settings.linkUpdate.ownerPolicy,'disabled') && ...
    strcmp(settings.linkUpdate.correlationPolicy,'disabled'), ...
    'Stage-1 disabled defaults must still declare their exact guarded policy.');
resolvedDefault = revgnss.ConfigFactory.defaultConfig();
resolvedMaster = revgnss.ConfigFactory.finalizeConfig(masterConfig());
assert(isequaln(resolvedDefault.multiAsset.distributedEstimator, ...
    resolvedMaster.multiAsset.distributedEstimator), ...
    'Independent-fleet controls must resolve identically from every master-config entry path.');

manifest = revgnss.SimulationToggleManifest.fromConfig(cfg);
paths = {manifest.cfgPath};
required = { ...
    'cfg.multiAsset.distributedEstimator.enable', ...
    'cfg.multiAsset.distributedEstimator.executionMode', ...
    'cfg.multiAsset.distributedEstimator.stateExchange.enable', ...
    'cfg.multiAsset.distributedEstimator.stateExchange.maximumAge_s', ...
    'cfg.multiAsset.distributedEstimator.stateExchange.deliveryDelay_s', ...
    'cfg.multiAsset.distributedEstimator.linkUpdate.enable', ...
    'cfg.multiAsset.distributedEstimator.linkUpdate.ownerPolicy', ...
    'cfg.multiAsset.distributedEstimator.linkUpdate.correlationPolicy', ...
    'cfg.multiAsset.distributedEstimator.outOfSequencePolicy'};
assert(all(ismember(required,paths)), ...
    'Every public Stage-1 control must be visible in the toggle manifest.');

invalid = i_fleetConfig_(1);
i_expectError_(@() revgnss.ConfigFactory.finalizeConfig(invalid), ...
    'IndependentFleetCoordinator:assetCount');

invalid = i_fleetConfig_(3);
invalid.multiAsset.distributedEstimator.linkUpdate.enable = true;
i_expectError_(@() revgnss.ConfigFactory.finalizeConfig(invalid), ...
    'IndependentFleetCoordinator:linkUpdateUnavailable');

invalid = i_fleetConfig_(3);
invalid.measurements.isl.enable = true;
invalid.measurements.isl.code.enable = true;
invalid.measurements.isl.code.useInEKF = true;
i_expectError_(@() revgnss.ConfigFactory.finalizeConfig(invalid), ...
    'IndependentFleetCoordinator:islUpdateUnavailable');

invalid = i_fleetConfig_(3);
invalid.measurements.isl.enable = true;
invalid.measurements.isl.code.enable = true;
i_expectError_(@() revgnss.ConfigFactory.finalizeConfig(invalid), ...
    'IndependentFleetCoordinator:islUpdateUnavailable');

invalid = i_fleetConfig_(3);
invalid.measurements.isl.enable = true;
invalid.measurements.isl.twoWay.enable = true;
invalid.measurements.isl.twoWay.doppler.enable = true;
i_expectError_(@() revgnss.ConfigFactory.finalizeConfig(invalid), ...
    'IndependentFleetCoordinator:islUpdateUnavailable');

invalid = i_fleetConfig_(3);
invalid.orbit.mode = 'circularAnalytic';
i_expectError_(@() revgnss.ConfigFactory.finalizeConfig(invalid), ...
    'IndependentFleetCoordinator:orbitMode');
end

function i_factoryAndEpochParity_()
cfgFleet = i_baseConfig_();
cfgFleet.scenario.nSpaceAssets = 3;
legacySetup = revgnss.ReportRunner.federatedSetup_(cfgFleet);
sharedSetup = revgnss.IndependentFleetScenarioFactory.federatedSetup(cfgFleet,false);
assert(isequaln(legacySetup,sharedSetup), ...
    'Extracted per-asset factory changed the legacy federated setup.');
for assetIndex = 1:legacySetup.N
    legacyLeaf = revgnss.ReportRunner.assetConfigForIndex_(legacySetup,assetIndex);
    sharedLeaf = revgnss.IndependentFleetScenarioFactory.assetConfigForIndex( ...
        sharedSetup,assetIndex);
    assert(isequaln(legacyLeaf,sharedLeaf), ...
        'Extracted per-asset factory changed a legacy leaf configuration.');
end
i_assertCustomClockSeedPreservation_();

cfgOne = i_baseConfig_();
oneSetup = revgnss.IndependentFleetScenarioFactory.federatedSetup(cfgOne,false);
oneLeaf = revgnss.IndependentFleetScenarioFactory.stageOneLeafConfigForIndex( ...
    oneSetup,cfgOne,1);
assert(isequaln(oneLeaf,cfgOne), ...
    'N=1 Stage-1 factory path must be an identity transformation.');

reference = revgnss.ReverseGNSSSimulation(cfgOne);
reference.initialize();
reference.run();

phased = revgnss.ReverseGNSSSimulation(cfgOne);
phased.initialize();
for epochIndex = 1:phased.nEpochs
    phased.advanceTruthEpoch(epochIndex);
    phased.runLocalEstimationEpoch(epochIndex);
end
phased.finishRun(false);
assert(isequaln(reference.ekf.x,phased.ekf.x) && ...
    isequaln(reference.ekf.P,phased.ekf.P) && ...
    isequaln(reference.ekf.history,phased.ekf.history), ...
    'Epoch-phase execution changed a single local EKF result.');
assert(isequaln(reference.simData.getNumMeasurementRows(), ...
    phased.simData.getNumMeasurementRows()), ...
    'Epoch-phase execution changed local measurement-row accounting.');
i_expectError_(@() revgnss.EndpointStateProduct.fromLocalEstimator( ...
    phased,1,phased.tVec(end)+phased.cfg.simulation.dt_s,0,'wrong-epoch'), ...
    'EndpointStateProduct:sourceEpoch');

notUpdated = revgnss.ReverseGNSSSimulation(cfgOne);
notUpdated.initialize();
i_expectError_(@() revgnss.EndpointStateProduct.fromLocalEstimator( ...
    notUpdated,1,notUpdated.tVec(1),0,'before-update'), ...
    'EndpointStateProduct:localUpdate');
end

function i_legacyFanoutCharacterization_()
cfg = i_baseConfig_();
cfg.scenario.nSpaceAssets = 3;
cfg.multiAsset.mode = 'fast';
cfg.multiAsset.distributedEstimator.enable = false;
opts = struct('savePerAsset',false,'folder','','stem','', ...
    'writePdf',false,'writeMat',false);
legacy = revgnss.ReportRunner.runFederatedEstimation(cfg,opts);
assert(legacy.N == 3 && isfield(legacy,'asset') && ...
    ~isfield(legacy,'endpointStateProducts') && ~isfield(legacy,'stateExchange'), ...
    ['Legacy federation must remain a completed-run result collection with no ' ...
     'epoch-synchronous product journal.']);
end

function i_coordinatorAndJournal_()
cfgOff = i_fleetConfig_(6);
cfgOff.multiAsset.distributedEstimator.stateExchange.enable = false;
off = revgnss.IndependentFleetCoordinator(cfgOff);
off.initialize();
off.run();
offResults = off.getResults();
assert(offResults.stateExchange.generatedProducts == 0, ...
    'Disabled state exchange emitted a state product.');

cfgOn = i_fleetConfig_(6);
cfgOn.multiAsset.distributedEstimator.stateExchange.enable = true;
cfgOn.multiAsset.distributedEstimator.stateExchange.maximumAge_s = 0;
cfgOn.multiAsset.distributedEstimator.stateExchange.deliveryDelay_s = 1;
on = revgnss.IndependentFleetCoordinator(cfgOn);
on.initialize();
on.run();
onResults = on.getResults();

assert(onResults.N == 6 && numel(on.localSimulations) == 6, ...
    'Stage 1 must instantiate one local simulation per configured spacecraft.');
for firstIndex = 1:onResults.N
    for secondIndex = firstIndex+1:onResults.N
        assert(on.localSimulations{firstIndex}.ekf ~= ...
            on.localSimulations{secondIndex}.ekf, ...
            'Each Stage-1 local simulation must own a distinct EKF handle.');
    end
end
clockSeeds = cellfun(@(sim) sim.asset.clock.seed,on.localSimulations);
assert(numel(unique(clockSeeds)) == onResults.N, ...
    'Each Stage-1 local spacecraft must retain an independent receiver-clock stream.');
i_assertCommonFleetEphemeris_(on);
assert(onResults.stateExchange.generatedProducts == onResults.N*numel(on.tVec), ...
    'Exactly one local-estimator product per spacecraft and epoch is required.');
assert(onResults.stateExchange.staleDiagnosticOnly > 0 && ...
    onResults.stateExchange.pendingDelivery == onResults.N, ...
    'Delayed products must remain diagnostic-only and become stale under maximumAge_s=0.');
assert(onResults.linkObservationCounters.generated == 0 && ...
    onResults.linkObservationCounters.delivered == 0 && ...
    onResults.linkObservationCounters.consumedByOwner == 0, ...
    'Stage 1 must generate, deliver, and consume zero ISL estimator observations.');

for assetIndex = 1:onResults.N
    assert(on.localSimulations{assetIndex}.observationLedger.numberConsumed() == 0, ...
        'A local Stage-1 EKF consumed an inter-satellite observation.');
    assert(onResults.asset{assetIndex}.cfg.scenario.nSpaceAssets == 1, ...
        'A Stage-1 leaf retained a regenerated neighbour constellation.');
    assert(numel(on.localSimulations{assetIndex}.ekf.stateMap.asset) == 1 && ...
        sum(on.localSimulations{assetIndex}.simData.getNumMeasurementRows()) > 0, ...
        'Each fleet member must retain one complete local EKF and its ground/onboard rows.');
    assert(isequaln(offResults.asset{assetIndex}.x,onResults.asset{assetIndex}.x) && ...
        isequaln(offResults.asset{assetIndex}.P,onResults.asset{assetIndex}.P) && ...
        isequaln(offResults.asset{assetIndex}.history,onResults.asset{assetIndex}.history), ...
        'Journal-only state exchange changed a local estimate or covariance.');
end

products = on.exchangeJournal.products();
assert(~isempty(products) && products{1}.qualityFlags.estimatorDerived && ...
    ~products{1}.qualityFlags.truthUsed && products{1}.qualityFlags.diagnosticOnly, ...
    'A state product must be estimator-derived provenance, never truth or a measurement.');
assert(numel(products{1}.stateComponentOrder) == numel(products{1}.covarianceComponentOrder) && ...
    strcmp(products{1}.covarianceComponentOrder{7},'attitudeTangentErrorX_rad'), ...
    'An MEKF state product must identify its local-tangent attitude covariance coordinates.');
for productIndex = 1:numel(products)
    product = products{productIndex};
    assert(any(product.sourceEpoch_s == on.tVec) && ...
        product.validAtEpoch_s == product.sourceEpoch_s && ...
        product.deliveryEpoch_s-product.sourceEpoch_s == 1 && ...
        product.sourceAssetIndex >= 1 && product.sourceAssetIndex <= onResults.N, ...
        'Every endpoint state product must retain its exact source/valid/delivery epoch.');
    provenance = product.processModelProvenance;
    assert(isfield(provenance,'stateDefinition') && ...
        isfield(provenance,'attitudeCovarianceCoordinates') && ...
        isfield(provenance,'dynamicsMode') && isfield(provenance,'clockModel') && ...
        isfield(provenance,'timeStep_s'), ...
        'Every endpoint state product must carry process-model provenance.');
end
i_expectError_(@() on.exchangeJournal.record(products{1},products{1}.sourceEpoch_s), ...
    'CommunicationExchangeJournal:duplicateProduct');
end

function i_reportRouting_()
cfg = i_fleetConfig_(3);
cfg.multiAsset.distributedEstimator.stateExchange.enable = true;
cfg.report.writePdf = true;
cfg.report.compileTex = 'never';
cfg.report.reportFolder = tempname;
cfg.report.stem = 'independent_fleet_diagnostic';
out = [];
evalc('out = revgnss.ReportRunner.runSingle(cfg);');
assert(strcmp(out.summary.architectureLabel,'independentLocalEkfsGroundOnly') && ...
    strcmp(out.summary.reportDataLabel,'independentLocalEkfsGroundOnly') && ...
    strcmp(out.summary.reportStatus,'diagnosticOnlyIndependentFleet'), ...
    'Independent-fleet reporting must expose a diagnostic-only data label.');
assert(out.fleetResults.complete && out.summary.linkObservationCounters.consumedByOwner == 0, ...
    'Independent-fleet reporting must retain complete local results and zero link consumption.');
assert(~isfield(out,'rel'), ...
    'Independent-fleet routing must not present a relative-fusion result.');
assert(out.diagnosticReport.success && isfile(out.texPath) && ...
    isfile(fullfile(cfg.report.reportFolder,out.diagnosticReport.absoluteFigure)) && ...
    isfile(fullfile(cfg.report.reportFolder,out.diagnosticReport.kabschFigure)), ...
    'The diagnostic route must emit labelled absolute and Kabsch report artifacts.');
end

function i_assertCommonFleetEphemeris_(coordinator)
setup = revgnss.IndependentFleetScenarioFactory.federatedSetup(coordinator.cfg,false);
chiefOrbit = models.orbit.OrbitPropagator(coordinator.cfg.orbit);
for assetIndex = 1:coordinator.nAssets
    if assetIndex == 1
        [rExpected,vExpected] = chiefOrbit.propagate(coordinator.tVec);
    else
        [rExpected,vExpected] = chiefOrbit.propagateFromEciState( ...
            setup.r0Cells{assetIndex-1},setup.v0Cells{assetIndex-1},coordinator.tVec);
    end
    cache = coordinator.localSimulations{assetIndex}.orbitTruthCache;
    assert(norm(cache.r_ecef_m-rExpected,'fro') < 1e-7 && ...
        norm(cache.v_ecef_mps-vExpected,'fro') < 1e-10, ...
        'A local fleet member did not retain the common physical formation ephemeris.');
end
end

function i_assertCustomClockSeedPreservation_()
cfg = i_fleetConfig_(3);
cfg = revgnss.ConfigFactory.finalizeConfig(cfg);
clockSeeds = [701,702,703];
for assetIndex = 1:numel(clockSeeds)
    cfg.assets(assetIndex).clock.seed = clockSeeds(assetIndex);
end
cfg.asset = cfg.assets(1);
setup = revgnss.IndependentFleetScenarioFactory.federatedSetup(cfg,false);
for assetIndex = 1:numel(clockSeeds)
    leaf = revgnss.IndependentFleetScenarioFactory.stageOneLeafConfigForIndex( ...
        setup,cfg,assetIndex);
    leaf = revgnss.ConfigFactory.finalizeConfig(leaf);
    assert(leaf.asset.clock.seed == clockSeeds(assetIndex), ...
        'Stage-1 leaf construction overwrote a configured receiver-clock seed.');
end
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
error('test_independent_fleet_stage1:missingError', ...
    'Expected error %s was not raised.',identifier);
end
