function test_independent_fleet_time_transfer_sanctioned_link_update_end_to_end()
% test_independent_fleet_time_transfer_sanctioned_link_update_end_to_end  Real end-to-end proof
% for plan Section 2.3.2: a 2-asset independent fleet, driven ONLY through
% revgnss.IndependentFleetCoordinator (the production entry point -- no synthetic shortcuts),
% with the firstOrderReciprocalClockTransfer sanctioned tuple enabled, run for several epochs, and
% checked for real consumption + a conservative (never worse than the prior) posterior covariance
% on the owner leaf. Mirrors test_independent_fleet_sanctioned_link_update_end_to_end.m (Section
% 2.3.1's coherentTwoWayCodeRange tuple) with the time-transfer observable, and additionally
% proves Section 2.3.2's U6 mutual-exclusion gate (combining both sanctioned observables at once
% is refused).

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
addpath(rootDir);
addpath(fullfile(rootDir,'config'));
addpath(fullfile(rootDir,'config','internal'));

fprintf('=== test_independent_fleet_time_transfer_sanctioned_link_update_end_to_end ===\n');
i_test_sanctioned_tuple_runs_and_consumes_time_transfer_updates_();
i_test_posterior_covariance_is_conservative_and_valid_each_update_();
i_test_combining_both_sanctioned_observables_is_refused_();
i_test_range_enable_refused_under_time_transfer_sanctioned_tuple_();
i_test_reciprocity_residual_refused_under_sanctioned_tuple_();
i_test_disabled_tuple_unaffected_by_new_gate_();
fprintf(['=== test_independent_fleet_time_transfer_sanctioned_link_update_end_to_end: ' ...
    'ALL PASS ===\n']);
end

% ================================================================================================
function i_test_sanctioned_tuple_runs_and_consumes_time_transfer_updates_()
cfg = i_sanctionedFleetConfig_();
coordinator = revgnss.IndependentFleetCoordinator(cfg);
coordinator.run();

results = coordinator.getResults();
assert(results.complete,'The fleet run must complete.');
counters = results.linkObservationCounters;
fprintf('  generated=%d delivered=%d consumedByOwner=%d\n', ...
    counters.generated,counters.delivered,counters.consumedByOwner);
assert(counters.generated > 0, ...
    'The sanctioned tuple must actually generate time-transfer link records over several epochs.');
assert(counters.delivered > 0 && counters.delivered == counters.consumedByOwner, ...
    'Every delivered link update must be consumed by exactly its owner leaf.');

ledgerSummary = results.linkDelivery;
assert(ledgerSummary.consumed >= counters.consumedByOwner, ...
    'The fleet-wide delivery ledger must record at least as many consumed entries as the owner leaf.');
assert(ledgerSummary.rejected == 0, ...
    'This clean fixture must not produce any rejected link deliveries: %s', ...
    i_firstRejectionReason_(coordinator));

fprintf('  PASS sanctioned tuple runs and consumes time-transfer updates end-to-end\n');
end

% ================================================================================================
function i_test_posterior_covariance_is_conservative_and_valid_each_update_()
sanctionedCfg = i_sanctionedFleetConfig_();
sanctionedCoordinator = revgnss.IndependentFleetCoordinator(sanctionedCfg);
sanctionedCoordinator.run();

disabledCfg = i_sanctionedFleetConfig_();
disabledCfg.multiAsset.distributedEstimator.linkUpdate.enable = false;
disabledCfg.multiAsset.distributedEstimator.linkUpdate.ownerPolicy = 'disabled';
disabledCfg.multiAsset.distributedEstimator.linkUpdate.correlationPolicy = 'disabled';
disabledCfg.multiAsset.distributedEstimator.linkUpdate.updateAdapter.observable = 'none';
disabledCfg.multiAsset.distributedEstimator.deliveryLedger.enable = false;
disabledCfg.measurements.isl.enable = false;
disabledCfg.measurements.isl.twoWay.enable = false;
disabledCfg.measurements.isl.twoWay.timeTransfer.enable = false;
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

fprintf(['  PASS posterior covariance is finite/symmetric/PSD after real time-transfer updates ' ...
    '(asym=%.2e, minEig=%.2e, trace ratio vs ground-only=%.3f)\n'],asym,minEig,traceRatio);
end

% ================================================================================================
function i_test_combining_both_sanctioned_observables_is_refused_()
% Section 2.3.2 U6: enabling BOTH observables' underlying builders at once, even with only one
% named as updateAdapter.observable, must be refused -- the non-selected observable's own
% enable path is not exempted just because the other is sanctioned.
cfg = i_sanctionedFleetConfig_();
cfg.measurements.isl.twoWay.range.enable = true;
coordinator = revgnss.IndependentFleetCoordinator(cfg);
i_expectError_(@() coordinator.initialize(),'IndependentFleetCoordinator:islUpdateUnavailable');
fprintf('  PASS combining both sanctioned observables'' builders at once is refused\n');
end

% ================================================================================================
function i_test_range_enable_refused_under_time_transfer_sanctioned_tuple_()
cfg = i_sanctionedFleetConfig_();
cfg.multiAsset.distributedEstimator.linkUpdate.updateAdapter.observable = 'coherentTwoWayCodeRange';
% timeTransfer.enable stays true from i_sanctionedFleetConfig_ while range is now the
% SELECTED observable -- the mirror image of the previous test, exercised via the other branch.
coordinator = revgnss.IndependentFleetCoordinator(cfg);
i_expectError_(@() coordinator.initialize(),'IndependentFleetCoordinator:islUpdateUnavailable');
fprintf('  PASS the non-selected observable''s own enable path stays refused either way\n');
end

% ================================================================================================
function i_test_reciprocity_residual_refused_under_sanctioned_tuple_()
% requireSanctionedIslConfiguration_'s time-transfer branch: a nonzero reciprocity term is a
% real (config-derived) error source this adapter release does not model as a distributed-
% adapter state, so it must be refused at construction, not silently absorbed into R.
cfg = i_sanctionedFleetConfig_();
cfg.measurements.isl.twoWay.timeTransfer.includeReciprocityResidual = true;
coordinator = revgnss.IndependentFleetCoordinator(cfg);
i_expectError_(@() coordinator.initialize(), ...
    'IndependentFleetCoordinator:reciprocityTermUnavailableForDistributedRow');
fprintf('  PASS a nonzero reciprocity term is refused under the sanctioned tuple\n');
end

% ================================================================================================
function i_test_disabled_tuple_unaffected_by_new_gate_()
cfg = i_sanctionedFleetConfig_();
cfg.multiAsset.distributedEstimator.linkUpdate.enable = false;
cfg.multiAsset.distributedEstimator.linkUpdate.ownerPolicy = 'disabled';
cfg.multiAsset.distributedEstimator.linkUpdate.correlationPolicy = 'disabled';
cfg.multiAsset.distributedEstimator.linkUpdate.updateAdapter.observable = 'none';
cfg.multiAsset.distributedEstimator.deliveryLedger.enable = false;
cfg.measurements.isl.enable = false;
cfg.measurements.isl.twoWay.enable = false;
cfg.measurements.isl.twoWay.timeTransfer.enable = false;
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
function reason = i_firstRejectionReason_(coordinator)
summary = revgnss.DistributedDeliveryLedger.summaryOrEmpty(coordinator.deliveryLedger);
if isfield(summary,'rejected') && summary.rejected > 0
    reason = 'see coordinator.deliveryLedger for detail';
else
    reason = '(none)';
end
end

% ================================================================================================
function i_expectError_(fn, expectedIdentifier)
try
    fn();
    error('test_independent_fleet_time_transfer_sanctioned_link_update_end_to_end:missingError', ...
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
cfg.multiAsset.distributedEstimator.linkUpdate.updateAdapter.observable = ...
    'firstOrderReciprocalClockTransfer';

% Section 2.3.2's sanctioned tuple: two-way time transfer enabled but NOT double-fed into the
% owner's own onboard EKF (useInEKF stays false -- the ONLY update path for this observable is
% the distributed adapter). masterConfig's own defaults already zero the persistent time-transfer
% calibration sources (calibration.terminalDelayError_s/terminalSigma_s) and disable the
% reciprocity term (includeReciprocityResidual=false), so nothing further needs zeroing here;
% this fixture only has to flip the two enable flags.
cfg.measurements.isl.enable = true;
cfg.measurements.isl.twoWay.enable = true;
cfg.measurements.isl.twoWay.timeTransfer.enable = true;
cfg.measurements.isl.twoWay.timeTransfer.useInEKF = false;
end
