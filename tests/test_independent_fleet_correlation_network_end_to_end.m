function test_independent_fleet_correlation_network_end_to_end()
% test_independent_fleet_correlation_network_end_to_end  Plan Stage 3.1, required reference test
% 5: the correlation network driven ONLY through the real revgnss.IndependentFleetCoordinator
% entry point (no synthetic shortcuts). Golden-safety, phase wiring, the third-member
% correlation signature on a real 3-asset fleet, ledger route recording, failure gates, and a
% stale-prior corruption guard.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
addpath(rootDir);
addpath(fullfile(rootDir,'config'));
addpath(fullfile(rootDir,'config','internal'));

fprintf('=== test_independent_fleet_correlation_network_end_to_end ===\n');
i_test_golden_safety_and_basic_summary_();
i_test_ledger_route_recording_();
i_test_three_asset_third_member_signature_();
i_test_failure_gates_();
fprintf('=== test_independent_fleet_correlation_network_end_to_end: ALL PASS ===\n');
end

% ================================================================================================
function i_test_golden_safety_and_basic_summary_()
cfgOff = i_sanctionedFleetConfig_(2);
cfgOn = i_sanctionedFleetConfig_(2);
cfgOn.multiAsset.distributedEstimator.correlationNetwork.policy = 'exactPairwiseCrossCovariance';
cfgOn.multiAsset.distributedEstimator.correlationNetwork.maximumFleetSize = 2;
cfgOn.multiAsset.distributedEstimator.correlationNetwork.audit.enable = true;
cfgOn.multiAsset.distributedEstimator.correlationNetwork.audit.everyNEpochs = 1;

coordOff = revgnss.IndependentFleetCoordinator(cfgOff);
coordOff.run();
resultsOff = coordOff.getResults();

coordOn = revgnss.IndependentFleetCoordinator(cfgOn);
coordOn.run();
resultsOn = coordOn.getResults();

for k = 1:2
    assert(isequal(resultsOff.asset{k}.x,resultsOn.asset{k}.x), ...
        'E1 golden-safety: asset %d x must be untouched by the network',k);
    assert(isequal(resultsOff.asset{k}.P,resultsOn.asset{k}.P), ...
        'E1 golden-safety: asset %d P must be untouched by the network',k);
    assert(isequaln(resultsOff.asset{k}.history,resultsOn.asset{k}.history), ...
        'E1 golden-safety: asset %d per-epoch history must be untouched by the network', k);
end
assert(isequal(resultsOff.linkObservationCounters,resultsOn.linkObservationCounters), ...
    'E1: link observation counters must be untouched by the network');

net = resultsOn.correlationNetwork;
fprintf('  fleetSize=%d epochsAdvanced=%d claim=%s\n',net.fleetSize,net.epochsAdvanced,net.centralReferenceEquivalenceClaim);
assert(net.fleetSize == 2,'E2: expected fleetSize==2');
assert(net.epochsAdvanced == numel(coordOn.tVec)-1,'E2: epochsAdvanced must equal numel(tVec)-1');
assert(any(strcmp(net.centralReferenceEquivalenceClaim, ...
    {'exactLinearPropagationOfDeclaredLocalCovariances', ...
     'conditionedOnConservativeOwnerOnlyUpdatesNoFleetBoundClaimed', ...
     'notEquivalentUnappliedCorrelatedLocalUpdates'})), ...
    'E7: centralReferenceEquivalenceClaim must be one of the frozen allowed claims');

netOff = resultsOff.correlationNetwork;
assert(strcmp(netOff.policyIdentifier,'disabled'),'expected a disabled network summary when off');
fprintf('  PASS E1/E2/E7: golden-safety holds; network summary is well-formed on and off\n');
end

% ================================================================================================
function i_test_ledger_route_recording_()
cfg = i_sanctionedFleetConfig_(2);
cfg.multiAsset.distributedEstimator.correlationNetwork.policy = 'exactPairwiseCrossCovariance';
cfg.multiAsset.distributedEstimator.correlationNetwork.maximumFleetSize = 2;
coordinator = revgnss.IndependentFleetCoordinator(cfg);
coordinator.run();
rows = coordinator.deliveryLedger.export();
assert(~isempty(rows),'expected at least one ledger entry');
consumedRows = rows(strcmp({rows.state},'consumed'));
assert(~isempty(consumedRows),'expected at least one consumed delivery');
for k = 1:numel(consumedRows)
    assert(any(strcmp(consumedRows(k).correlationNetworkRoute, ...
        revgnss.DistributedCovarianceNetworkContract.AllowedLinkUpdateRoutes)), ...
        'every consumed entry must carry a frozen route');
    assert(strcmp(consumedRows(k).correlationNetworkRoute,'conservativeBound'), ...
        'Stage 3.1 must always route conservativeBound (pairExact is unreachable this stage)');
    assert(strcmp(consumedRows(k).correlationNetworkRouteReasonCode, ...
        'pairExactRouteRequiresSynchronizedDeliveryStage'), ...
        'expected the frozen reason code for the unreachable pairExact route');
end
fprintf('  PASS E5: every consumed ledger entry records route=conservativeBound with the frozen reason code\n');
end

% ================================================================================================
function i_test_three_asset_third_member_signature_()
% E6 (topology check only): a real 3-asset fleet under this fixture's sanctioned tuple only ever
% generates a pairwise two-way ISL link between assets 1<->2, so it cannot itself exercise
% applyConservativeOwnerOnlyLinkTransform's third-member branch end-to-end through the
% coordinator. This subtest is deliberately scoped to confirming the real coordinator builds
% and advances a genuine 3-member network (fleetSize/epochsAdvanced). The actual third-member
% mathematical proof -- a real owner-only conditioning against member 3's cross block, checked
% exactly against the design formula P_ik+ = A_i*P_ik + B_i*P_jk(S_j,:) -- lives in
% tests/test_distributed_covariance_network_prediction_cross_block.m's
% i_test_conservative_owner_only_conditioning_and_third_member_signature_ subtest, which is the
% ONLY test anywhere that calls applyConservativeOwnerOnlyLinkTransform/
% conservativeOwnerOnlyErrorTransforms.
cfg = i_sanctionedFleetConfig_(3);
cfg.multiAsset.distributedEstimator.correlationNetwork.policy = 'exactPairwiseCrossCovariance';
cfg.multiAsset.distributedEstimator.correlationNetwork.maximumFleetSize = 3;
coordinator = revgnss.IndependentFleetCoordinator(cfg);
% correlationNetwork_ is private; use the public accounting surface (getResults) instead: run
% the real coordinator and confirm the network summary is populated for 3 members.
coordinator.run();
results = coordinator.getResults();
net = results.correlationNetwork;
assert(net.fleetSize == 3,'expected a real 3-member network from the coordinator');
assert(net.epochsAdvanced > 0,'expected the 3-member network to have propagated real epochs');
fprintf('  PASS E6 (topology check): a real 3-asset coordinator run builds and advances a 3-member network\n');
end

% ================================================================================================
function i_test_failure_gates_()
base = i_sanctionedFleetConfig_(2);

cfg1 = base;
cfg1.multiAsset.distributedEstimator.correlationNetwork.policy = 'exactPairwiseCrossCovariance';
cfg1.multiAsset.distributedEstimator.correlationNetwork.maximumFleetSize = 1;
i_assertConstructThrows_(cfg1,'IndependentFleetCoordinator:correlationNetworkFleetSize');

cfg2 = base;
cfg2.multiAsset.distributedEstimator.correlationNetwork.maximumFleetSize = 5;   % policy stays 'disabled'
i_assertConstructThrows_(cfg2,'IndependentFleetCoordinator:correlationNetworkPartialConfiguration');

% Section 3.2: 'pairExactWhenBothEndpointsTracked' is now a legal routing word (this fixture's
% own updateAdapter.observable is 'coherentTwoWayCodeRange', the one pair-exact-eligible
% observable) -- see test_independent_fleet_synchronized_pair_live_path.m for the real live-path
% proof. What remains refused is an UNRECOGNISED routing word, and pairing the pair-exact route
% with an observable outside revgnss.SynchronizedDeliveryContract.PairExactEligibleObservables.
cfg3 = base;
cfg3.multiAsset.distributedEstimator.correlationNetwork.policy = 'exactPairwiseCrossCovariance';
cfg3.multiAsset.distributedEstimator.correlationNetwork.maximumFleetSize = 2;
cfg3.multiAsset.distributedEstimator.correlationNetwork.linkUpdateRouting = 'notARealRoutingWord';
i_assertConstructThrows_(cfg3,'IndependentFleetCoordinator:correlationNetworkRoutingUnavailable');

cfg3b = base;
cfg3b.multiAsset.distributedEstimator.correlationNetwork.policy = 'exactPairwiseCrossCovariance';
cfg3b.multiAsset.distributedEstimator.correlationNetwork.maximumFleetSize = 2;
cfg3b.multiAsset.distributedEstimator.correlationNetwork.linkUpdateRouting = 'pairExactWhenBothEndpointsTracked';
cfg3b.multiAsset.distributedEstimator.linkUpdate.updateAdapter.observable = 'oneWayCode';
cfg3b.measurements.isl.oneWay.enable = true;
cfg3b.measurements.isl.oneWay.code.enable = true;
cfg3b.measurements.isl.twoWay.range.enable = false;
i_assertConstructThrows_(cfg3b,'IndependentFleetCoordinator:correlationNetworkRoutingObservableNotEligible');

% deliveryLedgerRequiresFleet's sanctioned-tuple check would fire first if the linkUpdate tuple
% were active, so this gate is proven from a fleet WITHOUT it: distributedEstimator.enable=true,
% linkUpdate fully disabled, correlationNetwork enabled, deliveryLedger.enable=false.
cfg4 = masterConfig();
cfg4.scenario.nSpaceAssets = 2;
cfg4.multiAsset.mode = 'fast';
cfg4.multiAsset.distributedEstimator.enable = true;
cfg4.multiAsset.distributedEstimator.deliveryLedger.enable = false;
cfg4.multiAsset.distributedEstimator.correlationNetwork.policy = 'exactPairwiseCrossCovariance';
cfg4.multiAsset.distributedEstimator.correlationNetwork.maximumFleetSize = 2;
i_assertConstructThrows_(cfg4,'IndependentFleetCoordinator:correlationNetworkRequiresDeliveryLedger');

cfg5 = base;
cfg5.multiAsset.distributedEstimator.correlationNetwork.policy = 'exactPairwiseCrossCovariance';
cfg5.multiAsset.distributedEstimator.correlationNetwork.maximumFleetSize = 2;
cfg5.rng.independentStreams.enable = false;
i_assertConstructThrows_(cfg5,'IndependentFleetCoordinator:correlationNetworkRequiresIndependentStreams');

cfg6 = base;
cfg6.multiAsset.perAssetLeaf = true;
cfg6.multiAsset.distributedEstimator.correlationNetwork.policy = 'exactPairwiseCrossCovariance';
cfg6.multiAsset.distributedEstimator.correlationNetwork.maximumFleetSize = 2;
i_assertConstructThrows_(cfg6,'IndependentFleetCoordinator:perAssetLeafSubToggleUnavailable');

fprintf('  PASS E8: failure gates each fire with their own frozen identifier\n');
end

function i_assertConstructThrows_(cfg, expectedIdentifier)
threw = false;
try
    revgnss.IndependentFleetCoordinator.validateConfig(revgnss.ConfigFactory.finalizeConfig(cfg));
catch ME
    threw = strcmp(ME.identifier,expectedIdentifier);
    if ~threw
        fprintf('  (got %s, expected %s)\n',ME.identifier,expectedIdentifier);
    end
end
assert(threw,'expected %s to be refused',expectedIdentifier);
end

% ================================================================================================
function cfg = i_sanctionedFleetConfig_(nAssets)
cfg = masterConfig();
% Section 3.3's towerClockProductReachableButRejected guard refuses nSpaceAssets>1 with an
% enabled correlation network unless towerClockMode='perfectCorrection'; this fixture's whole
% point is the network itself, not the tower-clock-product gap, so opt into the one safe mode.
% Use the LEGACY knob, not clocks.tower.product.mode: the latter is arbitrated by
% cfg.provenance.explicit, which only resolveSimulationConfig produces, so setting it
% on a masterConfig() struct is INERT and this opt-in silently did not take.
cfg.towerClock.correctionMode = 'perfectTruth';
cfg.simulation.duration_s = 4;
cfg.simulation.dt_s = 1;
cfg.report.writePdf = false; cfg.report.writeMat = false; cfg.report.compileTex = 'never';
cfg.plots.enable = false; cfg.plots.showFigures = false;
cfg.scenario.nSpaceAssets = nAssets;
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
cfg.measurements.isl.enable = true;
cfg.measurements.isl.twoWay.enable = true;
cfg.measurements.isl.twoWay.range.enable = true;
cfg.measurements.isl.twoWay.range.useInEKF = false;
end
