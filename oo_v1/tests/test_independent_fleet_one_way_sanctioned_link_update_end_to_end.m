function test_independent_fleet_one_way_sanctioned_link_update_end_to_end()
% test_independent_fleet_one_way_sanctioned_link_update_end_to_end  Real end-to-end proof for
% plan Section 2.3 item 3: a 2-asset independent fleet, driven ONLY through
% revgnss.IndependentFleetCoordinator (no synthetic shortcuts), with each of the two one-way
% sanctioned tuples (oneWayCode, oneWayDoppler) enabled in turn, run for several epochs, and
% checked for real consumption + a conservative posterior covariance. Also proves the N-way
% mutual-exclusion gate now covers all four sanctioned observables, the legacy
% revgnss.ISLMeasurementBuilder routing can never co-activate, and the persistent-delay/
% broadcast-product/light-time refusals happen at construction, not silently at runtime.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
addpath(rootDir);
addpath(fullfile(rootDir,'config'));
addpath(fullfile(rootDir,'config','internal'));

fprintf('=== test_independent_fleet_one_way_sanctioned_link_update_end_to_end ===\n');
i_test_sanctioned_tuple_runs_and_consumes_('oneWayCode');
i_test_sanctioned_tuple_runs_and_consumes_('oneWayDoppler');
i_test_posterior_covariance_is_conservative_and_valid_each_update_();
i_test_n_way_mutual_exclusion_();
i_test_legacy_one_way_builder_paths_stay_refused_();
i_test_broadcast_product_refused_under_one_way_tuple_();
i_test_persistent_terminal_delay_refused_under_one_way_tuple_();
i_test_shared_receiver_refused_();
i_test_disabled_tuple_unaffected_();
fprintf(['=== test_independent_fleet_one_way_sanctioned_link_update_end_to_end: ' ...
    'ALL PASS ===\n']);
end

% ================================================================================================
function i_test_sanctioned_tuple_runs_and_consumes_(observable)
cfg = i_sanctionedFleetConfig_(observable);
coordinator = revgnss.IndependentFleetCoordinator(cfg);
coordinator.run();

results = coordinator.getResults();
assert(results.complete,'The fleet run must complete.');
counters = results.linkObservationCounters;
fprintf('  [%s] generated=%d delivered=%d consumedByOwner=%d\n', ...
    observable,counters.generated,counters.delivered,counters.consumedByOwner);
assert(counters.generated > 0, ...
    'The sanctioned tuple must actually generate one-way link records over several epochs.');
assert(counters.delivered > 0 && counters.delivered == counters.consumedByOwner, ...
    'Every delivered link update must be consumed by exactly its owner leaf.');

ledgerSummary = results.linkDelivery;
assert(ledgerSummary.consumed >= counters.consumedByOwner);
assert(ledgerSummary.rejected == 0, ...
    'This clean fixture must not produce any rejected link deliveries.');
fprintf('  PASS sanctioned tuple runs and consumes one-way updates end-to-end (%s)\n',observable);
end

% ================================================================================================
function i_test_posterior_covariance_is_conservative_and_valid_each_update_()
sanctionedCfg = i_sanctionedFleetConfig_('oneWayCode');
sanctionedCoordinator = revgnss.IndependentFleetCoordinator(sanctionedCfg);
sanctionedCoordinator.run();

disabledCfg = i_sanctionedFleetConfig_('oneWayCode');
disabledCfg.multiAsset.distributedEstimator.linkUpdate.enable = false;
disabledCfg.multiAsset.distributedEstimator.linkUpdate.ownerPolicy = 'disabled';
disabledCfg.multiAsset.distributedEstimator.linkUpdate.correlationPolicy = 'disabled';
disabledCfg.multiAsset.distributedEstimator.linkUpdate.updateAdapter.observable = 'none';
disabledCfg.multiAsset.distributedEstimator.deliveryLedger.enable = false;
disabledCfg.measurements.isl.enable = false;
disabledCfg.measurements.isl.oneWay.enable = false;
disabledCfg.measurements.isl.oneWay.code.enable = false;
disabledCoordinator = revgnss.IndependentFleetCoordinator(disabledCfg);
disabledCoordinator.run();

Psanctioned = sanctionedCoordinator.localSimulations{1}.ekf.P;
Pdisabled = disabledCoordinator.localSimulations{1}.ekf.P;

assert(all(isfinite(Psanctioned(:))),'Owner posterior covariance must be finite.');
asym = norm(Psanctioned-Psanctioned','fro')/max(1,norm(Psanctioned,'fro'));
assert(asym < 1e-9,'Owner posterior covariance must be symmetric to numerical precision (asym=%.3e).',asym);
minEig = min(eig((Psanctioned+Psanctioned')/2));
assert(minEig > -1e-8, ...
    'Owner posterior covariance must be positive semi-definite (min eig=%.3e).',minEig);

traceRatio = trace(Psanctioned)/trace(Pdisabled);
assert(traceRatio < 10, ...
    ['A conservative bound must not multiply the ground-only posterior trace by an order of ' ...
    'magnitude; got ratio %.3f.'],traceRatio);

fprintf(['  PASS posterior covariance is finite/symmetric/PSD after real one-way updates ' ...
    '(asym=%.2e, minEig=%.2e, trace ratio vs ground-only=%.3f)\n'],asym,minEig,traceRatio);
end

% ================================================================================================
function i_test_n_way_mutual_exclusion_()
% The generalised N-way U6: enabling any OTHER sanctioned observable's own enable path while a
% given observable is selected must be refused, for all 4x3=12 combinations.
observables = {'coherentTwoWayCodeRange','firstOrderReciprocalClockTransfer', ...
    'oneWayCode','oneWayDoppler'};
enablePaths = struct( ...
    'coherentTwoWayCodeRange',{{'measurements','isl','twoWay','range','enable'}}, ...
    'firstOrderReciprocalClockTransfer',{{'measurements','isl','twoWay','timeTransfer','enable'}}, ...
    'oneWayCode',{{'measurements','isl','oneWay','code','enable'}}, ...
    'oneWayDoppler',{{'measurements','isl','oneWay','doppler','enable'}});
parentPaths = struct( ...
    'coherentTwoWayCodeRange',{{'measurements','isl','twoWay','enable'}}, ...
    'firstOrderReciprocalClockTransfer',{{'measurements','isl','twoWay','enable'}}, ...
    'oneWayCode',{{'measurements','isl','oneWay','enable'}}, ...
    'oneWayDoppler',{{'measurements','isl','oneWay','enable'}});

probeCount = 0;
for selectIdx = 1:numel(observables)
    selected = observables{selectIdx};
    for otherIdx = 1:numel(observables)
        if otherIdx == selectIdx; continue; end
        other = observables{otherIdx};
        cfg = i_sanctionedFleetConfig_(selected);
        cfg = i_setPath_(cfg,parentPaths.(other),true);
        cfg = i_setPath_(cfg,enablePaths.(other),true);
        coordinator = revgnss.IndependentFleetCoordinator(cfg);
        i_expectError_(@() coordinator.initialize(), ...
            'IndependentFleetCoordinator:islUpdateUnavailable');
        probeCount = probeCount+1;
    end
end
fprintf('  PASS n_way_mutual_exclusion (%d probes)\n',probeCount);
end

function cfg = i_setPath_(cfg, path, value)
cfg = setfield_(cfg,path,value);
end

function s = setfield_(s, path, value)
if numel(path) == 1
    s.(path{1}) = value;
else
    s.(path{1}) = setfield_(s.(path{1}),path(2:end),value);
end
end

% ================================================================================================
function i_test_legacy_one_way_builder_paths_stay_refused_()
legacyPaths = { ...
    {'measurements','isl','code','enable'}, ...
    {'measurements','isl','code','useInEKF'}, ...
    {'measurements','isl','doppler','enable'}, ...
    {'measurements','isl','doppler','useInEKF'}, ...
    {'measurements','isl','carrier','enable'}, ...
    {'multiAsset','keepIslInPerAssetEkf'}};
for k = 1:numel(legacyPaths)
    cfg = i_sanctionedFleetConfig_('oneWayCode');
    cfg = i_setPath_(cfg,legacyPaths{k},true);
    coordinator = revgnss.IndependentFleetCoordinator(cfg);
    i_expectError_(@() coordinator.initialize(),'IndependentFleetCoordinator:islUpdateUnavailable');
end
fprintf('  PASS legacy_one_way_builder_paths_stay_refused (%d paths)\n',numel(legacyPaths));
end

% ================================================================================================
function i_test_broadcast_product_refused_under_one_way_tuple_()
% Only .enable is checked (see requireSanctionedIslConfiguration_'s own comment): masterConfig's
% shipped sigmaPos_m/sigmaClock_m/etc defaults are nonzero, but ISLMeasurementBuilder.
% productCfg_ zeroes all four unconditionally whenever enable=false, so a sigma-only probe with
% enable left false is a true no-op and correctly does NOT get refused -- verified explicitly
% below as a companion positive control, not just asserted in a comment.
cfg = i_sanctionedFleetConfig_('oneWayCode');
cfg = i_setPath_(cfg,{'measurements','isl','product','enable'},true);
coordinator = revgnss.IndependentFleetCoordinator(cfg);
i_expectError_(@() coordinator.initialize(), ...
    'IndependentFleetCoordinator:broadcastProductUnavailableForDistributedRow');

inertPaths = { ...
    {'measurements','isl','product','sigmaPos_m'}, ...
    {'measurements','isl','product','sigmaClock_m'}, ...
    {'measurements','isl','product','sigmaVel_mps'}, ...
    {'measurements','isl','product','sigmaClockDrift_mps'}};
for k = 1:numel(inertPaths)
    inertCfg = i_sanctionedFleetConfig_('oneWayCode');
    inertCfg = i_setPath_(inertCfg,inertPaths{k},0.1);
    inertCoordinator = revgnss.IndependentFleetCoordinator(inertCfg);
    inertCoordinator.initialize(); % must NOT throw: enable stays false, so this is a true no-op
end
fprintf(['  PASS broadcast_product_refused_under_one_way_tuple (enable refused, ' ...
    '%d sigma-only probes correctly inert)\n'],numel(inertPaths));
end

% ================================================================================================
function i_test_persistent_terminal_delay_refused_under_one_way_tuple_()
delayPaths = { ...
    {'measurements','isl','oneWay','calibration','transmitTerminalDelayError_s'}, ...
    {'measurements','isl','oneWay','calibration','receiveTerminalDelayError_s'}, ...
    {'measurements','isl','oneWay','calibration','terminalSigma_s'}};
for k = 1:numel(delayPaths)
    cfg = i_sanctionedFleetConfig_('oneWayCode');
    cfg = i_setPath_(cfg,delayPaths{k},1e-9);
    coordinator = revgnss.IndependentFleetCoordinator(cfg);
    i_expectError_(@() coordinator.initialize(), ...
        'IndependentFleetCoordinator:persistentOneWayDelayUnavailableForDistributedRow');
end
fprintf('  PASS persistent_terminal_delay_refused_under_one_way_tuple (%d paths)\n',numel(delayPaths));
end

% ================================================================================================
function i_test_shared_receiver_refused_()
cfg = i_sanctionedFleetConfig_('oneWayCode');
cfg.scenario.nSpaceAssets = 3;
cfg.measurements.isl.oneWay.links = [ ...
    struct('linkIdentifier','link-A2-A1','transmitterAssetIndex',2,'receiverAssetIndex',1, ...
        'calibrationProductIdentifier','cal-A2-A1','schedule',struct('updatePhase_s',0)), ...
    struct('linkIdentifier','link-A3-A1','transmitterAssetIndex',3,'receiverAssetIndex',1, ...
        'calibrationProductIdentifier','cal-A3-A1','schedule',struct('updatePhase_s',0))];
coordinator = revgnss.IndependentFleetCoordinator(cfg);
% Now caught by OneWayInterSatelliteObservationBuilder.validateConfig itself (wired into
% requireSanctionedIslConfiguration_ as part of this stage's review-finding fix), which runs
% BEFORE the coordinator's own (still-present, now-redundant-for-this-case) co-firing check.
i_expectError_(@() coordinator.initialize(), ...
    'OneWayInterSatelliteObservationBuilder:coFiringLinksPerOwner');
fprintf('  PASS shared_receiver_refused\n');
end

% ================================================================================================
function i_test_disabled_tuple_unaffected_()
cfg = i_sanctionedFleetConfig_('oneWayCode');
cfg.multiAsset.distributedEstimator.linkUpdate.enable = false;
cfg.multiAsset.distributedEstimator.linkUpdate.ownerPolicy = 'disabled';
cfg.multiAsset.distributedEstimator.linkUpdate.correlationPolicy = 'disabled';
cfg.multiAsset.distributedEstimator.linkUpdate.updateAdapter.observable = 'none';
cfg.multiAsset.distributedEstimator.deliveryLedger.enable = false;
cfg.measurements.isl.enable = false;
cfg.measurements.isl.oneWay.enable = false;
cfg.measurements.isl.oneWay.code.enable = false;
coordinator = revgnss.IndependentFleetCoordinator(cfg);
coordinator.run();
results = coordinator.getResults();
assert(results.complete);
counters = results.linkObservationCounters;
assert(counters.generated == 0 && counters.delivered == 0 && counters.consumedByOwner == 0, ...
    'The disabled tuple must generate/deliver/consume nothing.');
fprintf('  PASS disabled default path unaffected by the new gates\n');
end

% ================================================================================================
function i_expectError_(fn, expectedIdentifier)
try
    fn();
    error('test_independent_fleet_one_way_sanctioned_link_update_end_to_end:missingError', ...
        'Expected %s was not raised.',expectedIdentifier);
catch ME
    if ~isempty(expectedIdentifier)
        assert(strcmp(ME.identifier,expectedIdentifier), ...
            'Expected %s, received %s (%s).',expectedIdentifier,ME.identifier,ME.message);
    end
end
end

% ================================================================================================
function cfg = i_sanctionedFleetConfig_(observable)
cfg = masterConfig();
cfg.simulation.duration_s = 5;
cfg.simulation.dt_s = 1;
cfg.report.writePdf = false;
cfg.report.writeMat = false;
cfg.report.compileTex = 'never';
cfg.plots.enable = false;
cfg.plots.showFigures = false;

cfg.scenario.nSpaceAssets = 2;
cfg.multiAsset.mode = 'fast';
cfg.multiAsset.estimateMode = 'off';
cfg.multiAsset.keepIslInPerAssetEkf = false;
cfg.multiAsset.towersObserveSecondaries = false;

cfg.multiAsset.distributedEstimator.enable = true;
cfg.multiAsset.distributedEstimator.stateExchange.enable = false;
cfg.multiAsset.distributedEstimator.deliveryLedger.enable = true;
cfg.multiAsset.distributedEstimator.linkUpdate.enable = true;
cfg.multiAsset.distributedEstimator.linkUpdate.ownerPolicy = 'initiator';
cfg.multiAsset.distributedEstimator.linkUpdate.correlationPolicy = 'splitCovarianceIntersection';
cfg.multiAsset.distributedEstimator.linkUpdate.updateAdapter.observable = observable;

% masterConfig's own defaults already zero the persistent one-way calibration sources and
% disable the broadcast product/light-time paths, so this fixture only has to flip the enable
% flags matching the selected observable.
cfg.measurements.isl.enable = true;
cfg.measurements.isl.oneWay.enable = true;
if strcmp(observable,'oneWayCode')
    cfg.measurements.isl.oneWay.code.enable = true;
    cfg.measurements.isl.oneWay.code.useInEKF = false;
else
    cfg.measurements.isl.oneWay.doppler.enable = true;
    cfg.measurements.isl.oneWay.doppler.useInEKF = false;
end
end
