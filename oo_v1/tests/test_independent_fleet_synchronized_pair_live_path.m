function test_independent_fleet_synchronized_pair_live_path()
% test_independent_fleet_synchronized_pair_live_path  Plan Stage 3.2, the real end-to-end proof:
% driven ONLY through revgnss.IndependentFleetCoordinator (no synthetic shortcuts), with
% correlationNetwork.linkUpdateRouting='pairExactWhenBothEndpointsTracked' and the sanctioned
% coherentTwoWayCodeRange tuple. Confirms every consumed delivery actually routes pairExact and
% actually moves BOTH endpoint filters (not just the owner), the fleet-wide ledger records the
% remote endpoint/message identifiers, the network's own counters/claims are consistent, a
% 3-asset fleet exercises third-member conditioning end-to-end, and -- critically -- that the
% Stage 3.1 default (linkUpdateRouting left at 'conservativeBoundOnly') remains completely
% unaffected by any of this Stage 3.2 wiring (golden safety).

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
addpath(rootDir);
addpath(fullfile(rootDir,'config'));
addpath(fullfile(rootDir,'config','internal'));

fprintf('=== test_independent_fleet_synchronized_pair_live_path ===\n');
i_test_two_asset_synchronized_path_moves_both_endpoints_();
i_test_three_asset_third_member_conditioning_via_live_coordinator_();
i_test_default_conservative_routing_is_golden_safe_();
fprintf('=== test_independent_fleet_synchronized_pair_live_path: ALL PASS ===\n');
end

% ================================================================================================
function i_test_two_asset_synchronized_path_moves_both_endpoints_()
cfg = i_pairExactFleetConfig_(2);
coordinator = revgnss.IndependentFleetCoordinator(cfg);
coordinator.run();
results = coordinator.getResults();
assert(results.complete,'the fleet run must complete');

rows = coordinator.deliveryLedger.export();
assert(~isempty(rows),'expected at least one ledger entry');
assert(all(strcmp({rows.state},'consumed')),'this clean 2-asset fixture must produce no rejections: %s', ...
    i_firstRejectionReason_(rows));
for k = 1:numel(rows)
    assert(strcmp(rows(k).correlationNetworkRoute,'pairExact'), ...
        'every consumed delivery must route pairExact under this configuration');
    assert(strcmp(rows(k).correlationNetworkRouteReasonCode,'pairExactRouteAvailable'), ...
        'every pairExact route must carry the frozen availability reason code');
    assert(rows(k).remoteEndpointCorrectionApplied, ...
        'every pairExact-routed delivery must record remoteEndpointCorrectionApplied=true');
    assert(strcmp(rows(k).remoteEndpointIdentifier,'spacecraft:2'), ...
        'the remote endpoint identifier must be recorded correctly');
    assert(~isempty(rows(k).synchronizedMessageIdentifier) && ~isempty(rows(k).synchronizedMessageSignature_hex), ...
        'the signed message identifier/signature must be recorded');
end

% The remote leaf's OWN local consumption ledger must show the non-owner trace, NOT a real
% consume -- linkObservationCounters must not double-count a single physical observation.
remoteSim = coordinator.localSimulations{2};
ownerSim = coordinator.localSimulations{1};
assert(ownerSim.observationLedger.numberConsumed() == numel(rows), ...
    'the owner leaf must show a real consume for every delivered observation');
assert(remoteSim.observationLedger.numberConsumed() == 0, ...
    'the remote leaf must show ZERO real consumes (invariant 9: one consumer of record)');
assert(remoteSim.observationLedger.numberAppliedAsNonOwner() == numel(rows), ...
    'the remote leaf must show the non-counting non-owner application trace instead');
counters = results.linkObservationCounters;
assert(counters.consumedByOwner == numel(rows), ...
    'linkObservationCounters.consumedByOwner must equal the delivered count exactly once, not twice');

net = results.correlationNetwork;
assert(net.pairExactSynchronizedUpdateCount == numel(rows), ...
    'the network must have committed exactly one pair-exact update per consumed delivery');
assert(strcmp(net.linkUpdateConditioningClaim,'exactPairSynchronizedOnly'), ...
    'no conservative conditioning ever ran in this fixture');
assert(~net.isSealed,'a clean run must never seal the network');
fprintf('  PASS: every delivery routes pairExact, moves BOTH endpoints, and is ledgered without double-counting\n');
end

% ================================================================================================
function i_test_three_asset_third_member_conditioning_via_live_coordinator_()
% This fixture's sanctioned tuple generates exactly ONE two-way ISL link per epoch, A1<->A2
% (measured: 7 records over 7 epochs, asset 3 never an endpoint) -- NOT a link to every other
% asset. Asset 3 is still a genuine THIRD MEMBER of every A1<->A2 delivery (present in the
% network but not itself an endpoint), so pairExactThirdMemberConditioningCount must be nonzero:
% this proves the third-member cross-block CONDITIONING PATH is genuinely exercised end-to-end
% through the real coordinator (staging/committing a P_13/P_23 replacement, not skipping it).
%
% What this subtest does NOT prove: nonzero third-member ARITHMETIC. correlationNetwork.
% commonProcessNoiseTreatment stays 'rejected' on the live path (refused by
% requireCorrelationNetworkConfiguration_ -- see its own comment), so P_13/P_23 start at zero
% (declareIndependentPriorPairs) and are NEVER driven away from zero (pairExactThirdMember
% CrossTransforms' own formula: G*(0-K*(Hi*0+Hj*0)) = 0). The omission ratio is therefore an
% honest, structural 0/0 -> 0, not a numerically-exercised nonzero case. That nonzero-math case
% -- an independently hand-recomputed reference against real nonzero P_ik/P_jk -- is covered by
% tests/test_distributed_covariance_network_pair_exact_staging_and_commit.m's own
% i_test_stage_commit_third_member_and_claims_ subtest instead.
cfg = i_pairExactFleetConfig_(3);
coordinator = revgnss.IndependentFleetCoordinator(cfg);
coordinator.run();
results = coordinator.getResults();
rows = coordinator.deliveryLedger.export();
assert(~isempty(rows) && all(strcmp({rows.state},'consumed')), ...
    'this clean 3-asset fixture must also produce no rejections: %s',i_firstRejectionReason_(rows));

net = results.correlationNetwork;
assert(net.fleetSize == 3,'expected a real 3-member network');
assert(net.pairExactSynchronizedUpdateCount > 0,'expected real pair-exact commits on a 3-asset fleet');
assert(net.pairExactThirdMemberConditioningCount > 0, ...
    'a 3-asset fleet must exercise third-member cross-block conditioning at least once');
assert(net.maximumOmittedThirdMemberVarianceRatio == 0, ...
    ['this fixture''s third-member cross blocks start and stay exactly zero (commonProcessNoise ' ...
    'Treatment=''rejected'' on the live path), so the omission ratio must be the honest ' ...
    'structural 0, not a numerically-exercised value -- see this subtest''s own header comment']);
% centralReferenceEquivalenceClaim's precedence (worst-first, see revgnss.DistributedCovariance
% Network's own header) means unappliedCorrelatedLocalUpdateCount -- set whenever ANY leaf's own
% local ground update ran while cross blocks were nonzero, which a real fleet with independent
% ground receivers essentially always triggers -- can outrank the third-member-specific claims
% below it; this mirrors test_independent_fleet_correlation_network_end_to_end.m's own E7
% assertion for exactly the same reason on the Stage 3.1 conservativeBound path.
assert(any(strcmp(net.centralReferenceEquivalenceClaim, ...
    {'notEquivalentUnappliedCorrelatedLocalUpdates','notEquivalentUnappliedThirdMemberCorrections', ...
    'exactPairConditionedNonPairLinksRemainConservative'})), ...
    'a >2-member fleet after pair-exact commits can never claim full central-reference equivalence, got %s', ...
    net.centralReferenceEquivalenceClaim);
fprintf('  PASS: a real 3-asset coordinator run exercises third-member conditioning (count=%d)\n', ...
    net.pairExactThirdMemberConditioningCount);
end

% ================================================================================================
function i_test_default_conservative_routing_is_golden_safe_()
% Stage 3.1's own golden-safety claim (network enabled, routing left at its default
% 'conservativeBoundOnly') must be COMPLETELY unaffected by every Stage 3.2 coordinator change in
% this session: route computation was reordered to run before the mutation (correlationNetwork
% RouteFor_'s own header), and the phase-5 loop now branches on route -- neither may perturb the
% conservativeBound branch's result.
cfgOff = i_pairExactFleetConfig_(2);
cfgOff.multiAsset.distributedEstimator.correlationNetwork.linkUpdateRouting = 'conservativeBoundOnly';
coordOff = revgnss.IndependentFleetCoordinator(cfgOff);
coordOff.run();
resultsOff = coordOff.getResults();

cfgNoNetwork = i_pairExactFleetConfig_(2);
cfgNoNetwork.multiAsset.distributedEstimator.correlationNetwork.policy = 'disabled';
cfgNoNetwork.multiAsset.distributedEstimator.correlationNetwork.maximumFleetSize = 0;
cfgNoNetwork.multiAsset.distributedEstimator.correlationNetwork.linkUpdateRouting = 'conservativeBoundOnly';
coordNoNetwork = revgnss.IndependentFleetCoordinator(cfgNoNetwork);
coordNoNetwork.run();
resultsNoNetwork = coordNoNetwork.getResults();

for k = 1:2
    assert(isequal(resultsOff.asset{k}.x,resultsNoNetwork.asset{k}.x), ...
        'conservativeBoundOnly routing must leave asset %d''s state byte-identical to the network-disabled run',k);
    assert(isequal(resultsOff.asset{k}.P,resultsNoNetwork.asset{k}.P), ...
        'conservativeBoundOnly routing must leave asset %d''s covariance byte-identical to the network-disabled run',k);
end
rowsOff = coordOff.deliveryLedger.export();
assert(all(strcmp({rowsOff.correlationNetworkRoute},'conservativeBound')), ...
    'every delivery must still route conservativeBound when routing is left at its default');
assert(all(~[rowsOff.remoteEndpointCorrectionApplied]), ...
    'no delivery may report a remote endpoint correction under conservativeBoundOnly routing');
fprintf('  PASS: the default conservativeBoundOnly routing remains golden-safe against Stage 3.2''s coordinator changes\n');
end

% ================================================================================================
function cfg = i_pairExactFleetConfig_(nAssets)
cfg = masterConfig();
% Section 3.3's towerClockProductReachableButRejected guard refuses nSpaceAssets>1 with an
% enabled correlation network unless towerClockMode='perfectCorrection'; this fixture's whole
% point is the synchronized pair-exact live path, not the tower-clock-product gap.
cfg.clocks.tower.product.mode = 'perfectCorrection';
cfg.simulation.duration_s = 6;
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
cfg.multiAsset.distributedEstimator.correlationNetwork.policy = 'exactPairwiseCrossCovariance';
cfg.multiAsset.distributedEstimator.correlationNetwork.maximumFleetSize = nAssets;
cfg.multiAsset.distributedEstimator.correlationNetwork.linkUpdateRouting = 'pairExactWhenBothEndpointsTracked';
end

function reason = i_firstRejectionReason_(rows)
reason = 'none';
rejected = rows(strcmp({rows.state},'rejected'));
if ~isempty(rejected)
    reason = sprintf('%s / %s',rejected(1).rejectionReasonCode,rejected(1).rejectionReasonMessage);
end
end
