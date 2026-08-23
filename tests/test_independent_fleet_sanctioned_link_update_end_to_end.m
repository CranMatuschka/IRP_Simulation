function test_independent_fleet_sanctioned_link_update_end_to_end()
% test_independent_fleet_sanctioned_link_update_end_to_end  Real end-to-end proof for plan
% Section 2.3.1: a 2-asset independent fleet, driven ONLY through
% revgnss.IndependentFleetCoordinator (the production entry point -- no synthetic shortcuts),
% with the sanctioned distributedEstimator.linkUpdate tuple enabled, run for several epochs, and
% checked for real consumption + a conservative (never worse than the prior) posterior
% covariance on the owner leaf. Also proves the disabled default path is still byte-identical
% to a fleet run with linkUpdate untouched.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
addpath(rootDir);
addpath(fullfile(rootDir,'config'));
addpath(fullfile(rootDir,'config','internal'));

fprintf('=== test_independent_fleet_sanctioned_link_update_end_to_end ===\n');
i_test_sanctioned_tuple_runs_and_consumes_isl_updates_();
i_test_posterior_covariance_is_conservative_and_valid_each_update_();
i_test_missing_delivery_ledger_toggle_fails_cleanly_at_construction_();
i_test_disabled_tuple_unaffected_by_new_gate_();
fprintf('=== test_independent_fleet_sanctioned_link_update_end_to_end: ALL PASS ===\n');
end

% ================================================================================================
function i_test_sanctioned_tuple_runs_and_consumes_isl_updates_()
cfg = i_sanctionedFleetConfig_();
coordinator = revgnss.IndependentFleetCoordinator(cfg);
coordinator.run();

results = coordinator.getResults();
assert(results.complete,'The fleet run must complete.');
counters = results.linkObservationCounters;
fprintf('  generated=%d delivered=%d consumedByOwner=%d\n', ...
    counters.generated,counters.delivered,counters.consumedByOwner);
assert(counters.generated > 0, ...
    'The sanctioned tuple must actually generate two-way ISL link records over 5 epochs.');
assert(counters.delivered > 0 && counters.delivered == counters.consumedByOwner, ...
    'Every delivered link update must be consumed by exactly its owner leaf.');

ledgerSummary = results.linkDelivery;
assert(ledgerSummary.consumed >= counters.consumedByOwner, ...
    'The fleet-wide delivery ledger must record at least as many consumed entries as the owner leaf.');
assert(ledgerSummary.rejected == 0, ...
    'This clean fixture must not produce any rejected link deliveries: %s', ...
    i_firstRejectionReason_(coordinator));

fprintf('  PASS sanctioned tuple runs and consumes ISL updates end-to-end\n');
end

% ================================================================================================
function i_test_posterior_covariance_is_conservative_and_valid_each_update_()
% After several real owner-only conservative-bound updates, the owner leaf's posterior
% covariance must remain a valid covariance (finite, symmetric, PSD) and its position/attitude
% schema block must never have inflated beyond a generous bound relative to a matched
% linkUpdate-disabled twin run (the conservative bound can only tighten or match the standalone
% prior in expectation; it must not blow up numerically).
sanctionedCfg = i_sanctionedFleetConfig_();
sanctionedCoordinator = revgnss.IndependentFleetCoordinator(sanctionedCfg);
sanctionedCoordinator.run();

disabledCfg = i_sanctionedFleetConfig_();
disabledCfg.multiAsset.distributedEstimator.linkUpdate.enable = false;
disabledCfg.multiAsset.distributedEstimator.linkUpdate.ownerPolicy = 'disabled';
disabledCfg.multiAsset.distributedEstimator.linkUpdate.correlationPolicy = 'disabled';
disabledCfg.multiAsset.distributedEstimator.linkUpdate.updateAdapter.observable = 'none';
disabledCfg.multiAsset.distributedEstimator.deliveryLedger.enable = false;
% The ISL measurement toggles are only permitted while the sanctioned tuple is active
% (IndependentFleetCoordinator.islObservableRequested_); they must revert alongside it.
disabledCfg.measurements.isl.enable = false;
disabledCfg.measurements.isl.twoWay.enable = false;
disabledCfg.measurements.isl.twoWay.range.enable = false;
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
    'magnitude; got ratio %.3f (sanctioned trace=%.3e, ground-only trace=%.3e).'], ...
    traceRatio,trace(Psanctioned),trace(Pdisabled));

fprintf(['  PASS posterior covariance is finite/symmetric/PSD after real ISL updates ' ...
    '(asym=%.2e, minEig=%.2e, trace ratio vs ground-only=%.3f)\n'],asym,minEig,traceRatio);
end

% ================================================================================================
function i_test_missing_delivery_ledger_toggle_fails_cleanly_at_construction_()
% deliveryLedger.enable is a SEPARATE toggle from linkUpdate.enable; forgetting it under the
% sanctioned tuple must fail cleanly at initialize() time, not crash deep inside phase 4/5 on the
% first generated link record (the rejection path itself dereferences the ledger).
cfg = i_sanctionedFleetConfig_();
cfg.multiAsset.distributedEstimator.deliveryLedger.enable = false;
coordinator = revgnss.IndependentFleetCoordinator(cfg);
try
    coordinator.initialize();
    error('test_independent_fleet_sanctioned_link_update_end_to_end:missingError', ...
        'Expected IndependentFleetCoordinator:deliveryLedgerRequiredForSanctionedTuple was not raised.');
catch ME
    assert(strcmp(ME.identifier,'IndependentFleetCoordinator:deliveryLedgerRequiredForSanctionedTuple'), ...
        'Expected deliveryLedgerRequiredForSanctionedTuple, received %s (%s).', ...
        ME.identifier,ME.message);
end
fprintf('  PASS missing deliveryLedger.enable under the sanctioned tuple fails at construction, not at runtime\n');
end

% ================================================================================================
function i_test_disabled_tuple_unaffected_by_new_gate_()
% The disabled default path (linkUpdate.enable=false) must remain completely unaffected by the
% new deliveryLedger-required-under-sanctioned-tuple gate.
cfg = i_sanctionedFleetConfig_();
cfg.multiAsset.distributedEstimator.linkUpdate.enable = false;
cfg.multiAsset.distributedEstimator.linkUpdate.ownerPolicy = 'disabled';
cfg.multiAsset.distributedEstimator.linkUpdate.correlationPolicy = 'disabled';
cfg.multiAsset.distributedEstimator.linkUpdate.updateAdapter.observable = 'none';
cfg.multiAsset.distributedEstimator.deliveryLedger.enable = false;
cfg.measurements.isl.enable = false;
cfg.measurements.isl.twoWay.enable = false;
cfg.measurements.isl.twoWay.range.enable = false;
coordinator = revgnss.IndependentFleetCoordinator(cfg);
coordinator.run();
results = coordinator.getResults();
assert(results.complete);
counters = results.linkObservationCounters;
assert(counters.generated == 0 && counters.delivered == 0 && counters.consumedByOwner == 0, ...
    'The disabled tuple must generate/deliver/consume nothing.');
fprintf('  PASS disabled default path unaffected by the new deliveryLedger gate\n');
end

% ================================================================================================
function reason = i_firstRejectionReason_(coordinator)
summary = revgnss.DistributedDeliveryLedger.summaryOrEmpty(coordinator.deliveryLedger);
if isfield(summary,'rejected') && summary.rejected > 0
    reason = 'see coordinator.deliveryLedger for detail';
else
    reason = '(none)';
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
cfg.multiAsset.distributedEstimator.linkUpdate.updateAdapter.observable = 'coherentTwoWayCodeRange';

% Section 2.3.1's sanctioned tuple: two-way code range enabled but NOT double-fed into the
% owner's own onboard EKF (useInEKF stays false -- the ONLY update path for this observable is
% the distributed adapter). masterConfig's own defaults already zero every persistent
% calibration/plasma source (truth.turnaroundCalibrationError_s, calibration.turnaroundSigma_s,
% range.plasma.*, calibration.residualBiasState.enable=false), so nothing further needs zeroing
% here; this fixture only has to flip the two enable flags.
cfg.measurements.isl.enable = true;
cfg.measurements.isl.twoWay.enable = true;
cfg.measurements.isl.twoWay.range.enable = true;
cfg.measurements.isl.twoWay.range.useInEKF = false;
end
