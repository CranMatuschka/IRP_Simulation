% test_swarm_two_way_isl_gating
%
% Verifies that the solved formation-shape layer is an observation result only
% when cfg.multiAsset.twoWayISL.enable is true. Raw relative geometry remains a
% diagnostic in both cases.

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_swarm_two_way_isl_gating ===\n');

results = syntheticResults_();
cfgOff = baseCfg_(false);
relOff = revgnss.SwarmRelativeSolver.solve(cfgOff, results);

assert(relOff.applicable, 'T1 FAILED: multi-asset relative diagnostic should be applicable.');
assert(~relOff.shapeGateOn, 'T1 FAILED: shapeGateOn must be false when twoWayISL is disabled.');
assert(strcmp(relOff.shapeObservationSource, 'disabled'), ...
    'T1 FAILED: disabled shape source must be labelled disabled.');
assert(isfinite(relOff.baselineErrRaw_m) && isfinite(relOff.shapeErrRaw_m), ...
    'T1 FAILED: raw relative geometry diagnostics must remain finite.');
assert(isnan(relOff.baselineErrSolved_m) && isnan(relOff.shapeErrSolved_m), ...
    'T1 FAILED: solved-shape metrics must be NaN when the gate is off.');
assert(isempty(relOff.solvedPos), 'T1 FAILED: solved positions must not be generated when gate is off.');
assert(all(isnan(relOff.perEpoch.baselineErrSolved_m)) && all(isnan(relOff.perEpoch.shapeErrSolved_m)), ...
    'T1 FAILED: disabled solved per-epoch series must be NaN.');
summOff = revgnss.FederatedSwarmSummary.build(cfgOff, results, relOff, 1);
assert(~summOff.formation.shapeGateOn, 'T1 FAILED: summary must expose disabled shape gate.');
assert(isnan(summOff.formation.shapeErr_m), 'T1 FAILED: disabled summary shape error must be NaN.');
assert(all(isnan([summOff.perAsset.relPosSolvedErr_m])), ...
    'T1 FAILED: summary must not report solved relative-position errors when gate is off.');
fprintf('  T1 twoWayISL disabled -> raw diagnostics only, solved metrics suppressed: PASS\n');

cfgOn = baseCfg_(true);
relOn = revgnss.SwarmRelativeSolver.solve(cfgOn, results);
assert(relOn.applicable && relOn.shapeGateOn, 'T2 FAILED: shapeGateOn must be true when enabled.');
assert(strcmp(relOn.shapeObservationSource, 'syntheticTwoWayISL'), ...
    'T2 FAILED: enabled shape source must be syntheticTwoWayISL.');
assert(isfinite(relOn.baselineErrSolved_m) && isfinite(relOn.shapeErrSolved_m), ...
    'T2 FAILED: solved-shape metrics must be finite when gate is on.');
assert(~isempty(relOn.solvedPos), 'T2 FAILED: solved positions must be generated when gate is on.');
summOn = revgnss.FederatedSwarmSummary.build(cfgOn, results, relOn, 1);
assert(summOn.formation.shapeGateOn, 'T2 FAILED: summary must expose enabled shape gate.');
assert(any(isfinite([summOn.perAsset.relPosSolvedErr_m])), ...
    'T2 FAILED: summary should report solved relative-position diagnostics when gate is on.');
fprintf('  T2 twoWayISL enabled -> synthetic two-way ISL solved shape active: PASS\n');

fprintf('=== test_swarm_two_way_isl_gating: ALL PASS ===\n');

function cfg = baseCfg_(shapeOn)
cfg = struct();
cfg.simulation.seed = 99;
cfg.simulation.dt_s = 10;
cfg.multiAsset.twoWayISL.enable = shapeOn;
cfg.multiAsset.twoWayISL.sigma_m = 0.001;
cfg.multiAsset.twoWayISL.delayCal.sigma_const_m = 0.001;
cfg.multiAsset.twoWayISL.delayCal.sigma_rw_m = 0;
cfg.multiAsset.twoWayISL.delayCal.tau_s = 100;
cfg.multiAsset.twoWayISL.delayCal.nCorrCap = 3;
cfg.multiAsset.twoWayTimeTransferISL.enable = false;
end

function results = syntheticResults_()
N = 3;
t = 0:10:40;
nEp = numel(t);
truth0 = [0 1000 450; 0 0 800; 0 120 240];
estBias = [12 -5 8; -4 7 3; 2 -6 4];
results = struct('N', N, 'asset', {cell(1,N)});
for i = 1:N
    truth = repmat(truth0(:,i), 1, nEp);
    truth(1,:) = truth(1,:) + 0.3 * t;
    est = truth + repmat(estBias(:,i), 1, nEp);
    est(2,:) = est(2,:) + 0.1 * i * sin(t/20);
    x = zeros(4, nEp);
    x(1:3,:) = est;
    x(4,:) = 0.01 * i;
    results.asset{i} = struct( ...
        'history', struct('x', x, 'time_s', t, 'P_diag', ones(4,nEp)), ...
        'truthTraj', truth, ...
        'truthClkTraj_m', zeros(1,nEp), ...
        'truthClkTime_s', t, ...
        'stateMap', struct('r_idx', 1:3, 'b_rx_idx', 4), ...
        'x', x(:,end));
end
end
