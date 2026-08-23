function test_four_timestamp_independent_fleet_coordinator_sanctioned_tuple()
% test_four_timestamp_independent_fleet_coordinator_sanctioned_tuple  Plan Section 4.4, Stage-4
% named test. Real end-to-end proof for the fourTimestampClockDifference sanctioned tuple: a
% 2-asset independent fleet, driven ONLY through revgnss.IndependentFleetCoordinator (the
% production entry point -- no synthetic shortcuts, unlike
% test_four_timestamp_clock_difference_link_update_adapter.m's direct
% LinkObservationDelivery.tryPropose calls), run for several epochs, and checked for real
% consumption + a conservative posterior covariance on the owner leaf. Mirrors
% test_independent_fleet_time_transfer_sanctioned_link_update_end_to_end.m (Section 2.3.2's
% firstOrderReciprocalClockTransfer tuple) with the new observable.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
addpath(rootDir);
addpath(fullfile(rootDir,'config'));
addpath(fullfile(rootDir,'config','internal'));

fprintf('=== test_four_timestamp_independent_fleet_coordinator_sanctioned_tuple ===\n');
i_test_sanctioned_tuple_runs_and_consumes_four_timestamp_updates_();
i_test_posterior_covariance_is_conservative_and_valid_();
i_test_combining_with_first_order_time_transfer_is_refused_();
i_test_two_way_not_enabled_is_refused_();
i_test_disabled_tuple_unaffected_by_new_gate_();
fprintf(['=== test_four_timestamp_independent_fleet_coordinator_sanctioned_tuple: ' ...
    'ALL PASS ===\n']);
end

% ================================================================================================
function i_test_sanctioned_tuple_runs_and_consumes_four_timestamp_updates_()
cfg = i_sanctionedFleetConfig_();
coordinator = revgnss.IndependentFleetCoordinator(cfg);
coordinator.run();

results = coordinator.getResults();
assert(results.complete,'The fleet run must complete.');
counters = results.linkObservationCounters;
fprintf('  generated=%d delivered=%d consumedByOwner=%d\n', ...
    counters.generated,counters.delivered,counters.consumedByOwner);
assert(counters.generated > 0, ...
    'The sanctioned tuple must actually generate four-timestamp link records over several epochs.');
assert(counters.delivered > 0 && counters.delivered == counters.consumedByOwner, ...
    'Every delivered link update must be consumed by exactly its owner leaf.');

ledgerSummary = results.linkDelivery;
assert(ledgerSummary.consumed >= counters.consumedByOwner);
assert(ledgerSummary.rejected == 0, ...
    'This clean fixture must not produce any rejected link deliveries.');

fprintf('  PASS sanctioned tuple runs and consumes fourTimestampClockDifference updates end-to-end\n');
end

% ================================================================================================
function i_test_posterior_covariance_is_conservative_and_valid_()
sanctionedCfg = i_sanctionedFleetConfig_();
sanctionedCoordinator = revgnss.IndependentFleetCoordinator(sanctionedCfg);
sanctionedCoordinator.run();

disabledCfg = i_disabledFleetConfig_();
disabledCoordinator = revgnss.IndependentFleetCoordinator(disabledCfg);
disabledCoordinator.run();

Psanctioned = sanctionedCoordinator.localSimulations{1}.ekf.P;
Pdisabled = disabledCoordinator.localSimulations{1}.ekf.P;

assert(all(isfinite(Psanctioned(:))),'Owner posterior covariance must be finite.');
asym = norm(Psanctioned-Psanctioned','fro')/max(1,norm(Psanctioned,'fro'));
assert(asym < 1e-9,'Owner posterior covariance must be symmetric to numerical precision (asym=%.3e).',asym);
minEig = min(eig((Psanctioned+Psanctioned')/2));
assert(minEig > -1e-8,'Owner posterior covariance must be PSD (min eig=%.3e).',minEig);

traceRatio = trace(Psanctioned)/trace(Pdisabled);
assert(traceRatio < 10, ...
    'A conservative bound must not multiply the ground-only posterior trace by an order of magnitude; got %.3f.', ...
    traceRatio);

fprintf(['  PASS posterior covariance is finite/symmetric/PSD after real fourTimestampClockDifference ' ...
    'updates (asym=%.2e, minEig=%.2e, trace ratio vs ground-only=%.3f)\n'],asym,minEig,traceRatio);
end

% ================================================================================================
function i_test_combining_with_first_order_time_transfer_is_refused_()
cfg = i_sanctionedFleetConfig_();
cfg.measurements.isl.twoWay.timeTransfer.enable = true;
coordinator = revgnss.IndependentFleetCoordinator(cfg);
i_expectError_(@() coordinator.initialize(),'IndependentFleetCoordinator:islUpdateUnavailable');
fprintf('  PASS combining fourTimestampClockDifference with firstOrderReciprocalClockTransfer''s own enable is refused\n');
end

% ================================================================================================
function i_test_two_way_not_enabled_is_refused_()
cfg = i_sanctionedFleetConfig_();
cfg.measurements.isl.twoWay.enable = false;
coordinator = revgnss.IndependentFleetCoordinator(cfg);
i_expectError_(@() coordinator.initialize(),'IndependentFleetCoordinator:twoWayNotEnabled');
fprintf('  PASS fourTimestampClockDifference without measurements.isl.twoWay.enable=true is refused\n');
end

% ================================================================================================
function i_test_disabled_tuple_unaffected_by_new_gate_()
cfg = i_disabledFleetConfig_();
coordinator = revgnss.IndependentFleetCoordinator(cfg);
coordinator.run();
results = coordinator.getResults();
assert(results.complete);
counters = results.linkObservationCounters;
assert(counters.generated == 0 && counters.delivered == 0 && counters.consumedByOwner == 0, ...
    'The disabled tuple must generate/deliver/consume nothing.');
fprintf('  PASS disabled default path unaffected by the new gate\n');
end

% ================================================================================================
function i_expectError_(fn, expectedIdentifier)
try
    fn();
    error('test_four_timestamp_independent_fleet_coordinator_sanctioned_tuple:missingError', ...
        'Expected %s was not raised.',expectedIdentifier);
catch ME
    assert(strcmp(ME.identifier,expectedIdentifier), ...
        'Expected %s, received %s (%s).',expectedIdentifier,ME.identifier,ME.message);
end
end

% ================================================================================================
function cfg = i_sanctionedFleetConfig_()
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
cfg.multiAsset.distributedEstimator.linkUpdate.updateAdapter.observable = 'fourTimestampClockDifference';

cfg.measurements.isl.enable = true;
cfg.measurements.isl.twoWay.enable = true;
cfg.measurements.isl.twoWay.links = struct( ...
    'enable',true,'linkIdentifier','isl-link-1-2','initiatorAssetIndex',1,'transponderAssetIndex',2, ...
    'signalIdentifier','ISL-PN','channelIdentifier','PN-1', ...
    'schedule',struct('updatePhase_s',0,'commandIdentifier','scenario-open-loop'), ...
    'turnaroundCalibrationError_s',0,'terminalCalibrationError_s',0, ...
    'physicalChainIdentifier','isl-two-way-code-chain', ...
    'calibrationProductIdentifier','isl-two-way-code-calibration');
cfg.measurements.isl.twoWay.schedule.updatePeriod_s = 1;
cfg.measurements.isl.twoWay.schedule.start_s = 0;
cfg.measurements.isl.twoWay.schedule.stop_s = 1e6;
end

% ================================================================================================
function cfg = i_disabledFleetConfig_()
cfg = i_sanctionedFleetConfig_();
cfg.multiAsset.distributedEstimator.linkUpdate.enable = false;
cfg.multiAsset.distributedEstimator.linkUpdate.ownerPolicy = 'disabled';
cfg.multiAsset.distributedEstimator.linkUpdate.correlationPolicy = 'disabled';
cfg.multiAsset.distributedEstimator.linkUpdate.updateAdapter.observable = 'none';
cfg.multiAsset.distributedEstimator.deliveryLedger.enable = false;
cfg.measurements.isl.enable = false;
cfg.measurements.isl.twoWay.enable = false;
end
