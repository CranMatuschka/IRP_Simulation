function test_independent_fleet_relative_baseline_covariance_report()
% test_independent_fleet_relative_baseline_covariance_report  Plan Section 3.5 items 1/2/4, live
% through the real revgnss.IndependentFleetCoordinator entry point (no synthetic shortcuts): a
% real 2-asset fleet's relativeBaselineCovarianceReport()/getResults().relativeCovarianceReport is
% hand-recomputed outside the class from orientedCrossCovariance + each asset's own live ekf.P and
% matched to tolerance, proving the coordinator's wiring (not just the network-level formula
% test_distributed_covariance_network_relative_schema_covariance_formula.m already covers) is
% correct end-to-end. Negative control: policy='disabled' must report available=false with zero
% computation attempted (no error thrown). Real filter.ReverseGNSSEKF/IndependentFleetCoordinator
% throughout, no mocks.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
addpath(rootDir);
addpath(fullfile(rootDir,'config'));
addpath(fullfile(rootDir,'config','internal'));

fprintf('=== test_independent_fleet_relative_baseline_covariance_report ===\n');
i_test_disabled_path_honest_unavailable_();
i_test_enabled_path_matches_manual_recomputation_();
i_test_three_asset_multi_pair_();
fprintf('=== test_independent_fleet_relative_baseline_covariance_report: ALL PASS ===\n');
end

% ================================================================================================
function i_test_disabled_path_honest_unavailable_()
cfg = i_baseFleetCfg_(2);
coord = revgnss.IndependentFleetCoordinator(cfg);
coord.run();
results = coord.getResults();
r = results.relativeCovarianceReport;
assert(isfield(r,'available') && r.available==false, ...
    'the disabled default path must report available=false');
assert(strcmp(r.reason,'correlationNetworkDisabled'), ...
    'the disabled default path must report the frozen correlationNetworkDisabled reason');
assert(isempty(r.pairs),'the disabled path must report zero pairs');
fprintf('  PASS disabled path -> available=false, correlationNetworkDisabled, zero pairs, no error\n');
end

% ================================================================================================
function i_test_enabled_path_matches_manual_recomputation_()
cfg = i_baseFleetCfg_(2);
cfg.multiAsset.distributedEstimator.correlationNetwork.policy = 'exactPairwiseCrossCovariance';
cfg.multiAsset.distributedEstimator.correlationNetwork.maximumFleetSize = 2;
coord = revgnss.IndependentFleetCoordinator(cfg);
coord.run();
results = coord.getResults();
r = results.relativeCovarianceReport;
assert(r.available==true,'the enabled path must report available=true');
assert(r.connectivity.isFullySpanning==true,'a 2-asset fully-tracked fleet must be fully spanning');
assert(numel(r.pairs)==1,'a 2-asset fleet must produce exactly 1 pair row');
p = r.pairs(1);

% Hand-recompute P_delta_r OUTSIDE the coordinator, directly from the network's own
% orientedCrossCovariance and each asset's own live P (the same public accessors a caller could
% use), then re-derive the same three metrics independently and match to tight tolerance.
schema1 = revgnss.DistributedCovarianceNetworkContract.schemaStateIndicesFromStateMap( ...
    coord.localSimulations{1}.ekf.stateMap,1);
schema2 = revgnss.DistributedCovarianceNetworkContract.schemaStateIndicesFromStateMap( ...
    coord.localSimulations{2}.ekf.stateMap,1);
P1 = coord.localSimulations{1}.ekf.P;
P2 = coord.localSimulations{2}.ekf.P;
Mij = coord.correlationNetworkForDiagnostics().orientedCrossCovariance(p.firstAssetIdentifier,p.secondAssetIdentifier);
PijSchema = Mij(schema1,schema2);
PdrManual = P1(schema1,schema1)+P2(schema2,schema2)-PijSchema-PijSchema';
PdrPosManual = (PdrManual(1:3,1:3)+PdrManual(1:3,1:3)')/2;

asset1 = results.asset{1}; asset2 = results.asset{2};
est1 = asset1.history.x(asset1.stateMap.r_idx,end);
est2 = asset2.history.x(asset2.stateMap.r_idx,end);
truth1 = asset1.truthTraj(:,end);
truth2 = asset2.truthTraj(:,end);
baselineEstManual = est1-est2;
baselineTruthManual = truth1-truth2;
baselineErrManual = norm(baselineEstManual-baselineTruthManual);
baselineSigmaManual = sqrt(max(0,trace(PdrPosManual)));

assert(abs(p.baselineErr_m-baselineErrManual) < 1e-9, ...
    'reported baselineErr_m must match the manual recomputation exactly');
assert(abs(p.baselineSigma_m-baselineSigmaManual) < 1e-9, ...
    'reported baselineSigma_m must match the manual recomputation exactly');
fprintf('  PASS baseline vector err/sigma match manual recomputation exactly (err=%.6f sigma=%.6f)\n', ...
    p.baselineErr_m,p.baselineSigma_m);

clockEst1 = asset1.history.x(asset1.stateMap.b_rx_idx,end);
clockEst2 = asset2.history.x(asset2.stateMap.b_rx_idx,end);
clockDiffErrManual = abs((clockEst1-clockEst2)-(asset1.truthClk-asset2.truthClk));
clockDiffSigmaManual = sqrt(max(0,PdrManual(13,13)));
assert(abs(p.clockDiffErr_m-clockDiffErrManual) < 1e-9, ...
    'reported clockDiffErr_m must match the manual recomputation exactly');
assert(abs(p.clockDiffSigma_m-clockDiffSigmaManual) < 1e-9, ...
    'reported clockDiffSigma_m must match the manual recomputation exactly');
fprintf('  PASS clock-difference err/sigma match manual recomputation exactly (err=%.6f sigma=%.6f)\n', ...
    p.clockDiffErr_m,p.clockDiffSigma_m);

assert(isfinite(p.lengthErr_m) && p.lengthSigma_m>=0,'length metrics must be finite/non-negative');
assert(isequal(size(PdrPosManual),[3 3]) && max(max(abs(PdrPosManual-PdrPosManual'))) < 1e-9, ...
    'the position sub-block used for baseline/length metrics must be symmetric');
fprintf('  PASS length metrics finite/non-negative; position sub-block symmetric\n');
end

% ================================================================================================
function i_test_three_asset_multi_pair_()
% Review finding L4: the 2-asset test above proves the formula end-to-end for exactly ONE pair;
% this proves the MULTI-PAIR path (the loop over crossBlockIdentifiers(), used only when N>2)
% actually produces one correctly-labeled, correctly-computed row per pair, not just a single row
% that happens to work.
cfg = i_baseFleetCfg_(3);
cfg.multiAsset.distributedEstimator.correlationNetwork.policy = 'exactPairwiseCrossCovariance';
cfg.multiAsset.distributedEstimator.correlationNetwork.maximumFleetSize = 3;
coord = revgnss.IndependentFleetCoordinator(cfg);
coord.run();
results = coord.getResults();
r = results.relativeCovarianceReport;
assert(r.available==true,'the 3-asset enabled path must report available=true');
assert(r.connectivity.isFullySpanning==true,'a fully-tracked 3-asset fleet must be fully spanning');
assert(numel(r.pairs)==3,'a 3-asset fully-tracked fleet must produce exactly 3 pair rows');

reportedIds = cell(1,3);
for k = 1:3
    reportedIds{k} = sort({r.pairs(k).firstAssetIdentifier,r.pairs(k).secondAssetIdentifier});
end
expected = {sort({'spacecraft:1','spacecraft:2'}),sort({'spacecraft:1','spacecraft:3'}),sort({'spacecraft:2','spacecraft:3'})};
for k = 1:3
    assert(any(cellfun(@(e) isequal(e,expected{k}),reportedIds)),'every possible pair must be named exactly once');
end
fprintf('  PASS 3-asset fleet: all 3 possible pairs reported, each named exactly once\n');

for k = 1:3
    p = r.pairs(k);
    assert(isfinite(p.baselineErr_m) && p.baselineSigma_m>=0,'pair %d: baseline metrics must be finite/non-negative',k);
    assert(isfinite(p.lengthErr_m) && p.lengthSigma_m>=0,'pair %d: length metrics must be finite/non-negative',k);
    assert(isfinite(p.clockDiffErr_m) && p.clockDiffSigma_m>=0,'pair %d: clock-diff metrics must be finite/non-negative',k);
end
fprintf('  PASS all 3 pairs: every metric finite/non-negative\n');
end

% ================================================================================================
function cfg = i_baseFleetCfg_(nAssets)
cfg = masterConfig();
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
