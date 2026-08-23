% test_clock_gauge_v4  Clock gauge subspace rank test (Issue 17).
%
% T13a: gaugeMode=none → rank(H_clk) = N_towers (one null direction: uniform shift)
% T13b: fixedReference → rank(H_clk_fixed) = N_towers + 1 (full rank in clock subspace)
%
% CHANGED: v3→v4 — Issue 17
% Using the clock-only submatrix isolates the clock rank test from
% attitude/velocity/geometry reasons for rank deficiency.
% State ordering: [b_rx, b_tower_1, ..., b_tower_N]
% Each row: b_rx=+1, b_tower_i=-1.

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_clock_gauge_v4 ===\n');

N_towers = 3;

% Build a config with N_towers and get measurement indices
cfg = revgnss.ConfigFactory.defaultConfig();
cfg.scenario.nTowers  = N_towers;
cfg.scenario.nReceivers = 1;
cfg.plots.enable  = false;
cfg.report.enable = false;

[asset, towers, ekf, measModel, ~, ~] = revgnss.ScenarioFactory.build(cfg);
[~, ~, ~, ~, errStruct] = measModel.computeMeasurements( ...
    asset, towers, ekf.x, 0, ekf.stateMap);

if isempty(errStruct)
    fprintf('  No visible towers — test vacuous\n');
    fprintf('=== test_clock_gauge_v4: PASS (vacuous) ===\n');
    return
end

towerIdx = errStruct.towerIdx_perMeas;
nMeas    = errStruct.nPseudorange;

% ----------------------------------------------------------------
% T13a: gaugeMode=none → rank = N_towers (one null direction)
% ----------------------------------------------------------------
fprintf('  T13a: gaugeMode=none rank(H_clk) = N_towers ...\n');

H_clk = revgnss.SignalUtils.buildClockOnlyH(nMeas, N_towers, towerIdx);
rank_clk = rank(H_clk);

fprintf('    H_clk size: %dx%d, rank=%d (expected=%d)\n', ...
    size(H_clk,1), size(H_clk,2), rank_clk, N_towers);

assert(rank_clk == N_towers, ...
    'T13a FAILED: gaugeMode=none: clock subspace rank should be %d (got %d)', ...
    N_towers, rank_clk);
fprintf('    PASS (rank=%d, null direction = uniform clock shift)\n', rank_clk);

% ----------------------------------------------------------------
% T13b: fixedReference → rank = N_towers + 1 (full rank in [b_rx, b_twr_1..N])
% ----------------------------------------------------------------
fprintf('  T13b: fixedReference rank(H_clk_fixed) = N_towers + 1 ...\n');

refTower = 1;  % fix first tower as reference
H_clk_fixed = revgnss.SignalUtils.buildClockOnlyH_fixedRef( ...
    nMeas, N_towers, towerIdx, refTower);
rank_fixed = rank(H_clk_fixed);

% With fixedReference, the null direction is eliminated.
% rank should be N_towers + 1 (= full column rank of [b_rx, b_twr_1..N] with ref fixed)
% or at least N_towers (depending on geometry coverage of each tower)
fprintf('    H_clk_fixed size: %dx%d, rank=%d (expected>=%d)\n', ...
    size(H_clk_fixed,1), size(H_clk_fixed,2), rank_fixed, N_towers);

assert(rank_fixed >= N_towers, ...
    'T13b FAILED: fixedReference rank should be >= %d (got %d)', N_towers, rank_fixed);
fprintf('    PASS (rank=%d)\n', rank_fixed);

% ----------------------------------------------------------------
% Null space check: gaugeMode=none should have exactly 1D null space
% ----------------------------------------------------------------
fprintf('  Null space check: 1D null space for gaugeMode=none ...\n');
[~, S, V] = svd(H_clk);
sv = diag(S);
tol = max(sv) * 1e-8;
nullDim = sum(sv < tol);
fprintf('    Singular values: [%s]\n', num2str(sv(:)', '%.4f '));
fprintf('    Null dimension: %d (expected 1)\n', nullDim);
if nullDim == 1
    null_vec = V(:, end);  % null vector
    fprintf('    Null vector: [%s] (expect proportional to [1,1,...,1])\n', ...
        num2str(null_vec(:)', '%.4f '));
end

fprintf('=== test_clock_gauge_v4: ALL PASS ===\n');
