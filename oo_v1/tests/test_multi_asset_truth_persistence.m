% test_multi_asset_truth_persistence
%
% WP1: ReportRunner persists every asset's truth trajectory (multiAssetTruth)
% for swarm runs (nSpaceAssets>1) so per-satellite truth-vs-truth geometry --
% inter-asset baselines (relative) and each asset's absolute position vs Earth --
% can be compared offline. A single-asset run must leave the .mat variable list
% byte-identical to the pre-WP1 contract (no multiAssetTruth), which keeps the
% frozen golden safe.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir, '..');
addpath(rootDir); addpath(fullfile(rootDir, 'config'));

fprintf('=== test_multi_asset_truth_persistence ===\n');

tmpRoot = tempname;
mkdir(tmpRoot);
cleanup = onCleanup(@() i_tryRmdir(tmpRoot)); %#ok<NASGU>

nAssets  = 6;
duration = 120;
stride   = 30;   % 120 s / 30 s -> decimated epochs {0,30,60,90,120}

% ---------------------------------------------------------------------
% T1: swarm run writes multiAssetTruth with the expected structure
% ---------------------------------------------------------------------
fprintf('  T1: swarm run persists per-asset truth ...\n');
cfgM = i_shortReportCfg(nAssets, duration, stride, fullfile(tmpRoot,'swarm'));
outM = revgnss.ReportRunner.runSingle(cfgM);
assert(exist(outM.matPath,'file') == 2, 'T1 FAILED: swarm .mat not written');

vars = who('-file', outM.matPath);
assert(ismember('multiAssetTruth', vars), 'T1 FAILED: multiAssetTruth absent from swarm .mat');

S   = load(outM.matPath, 'multiAssetTruth');
mat = S.multiAssetTruth;
assert(mat.nAssets == nAssets,          'T1 FAILED: nAssets mismatch');
assert(numel(mat.asset) == nAssets,     'T1 FAILED: asset struct count');
assert(mat.estimatedIndex == 1,         'T1 FAILED: estimatedIndex');
assert(abs(mat.stride_s - stride) < 1e-9,'T1 FAILED: stride_s');
fprintf('    PASS (%d assets, %d epochs, stride %g s)\n', ...
    mat.nAssets, numel(mat.time_s), mat.stride_s);

% ---------------------------------------------------------------------
% T2: every asset trajectory is finite and correctly shaped
% ---------------------------------------------------------------------
fprintf('  T2: per-asset trajectories finite/shaped ...\n');
K = numel(mat.time_s);
for ai = 1:nAssets
    r = mat.asset(ai).r_ecef_m;
    v = mat.asset(ai).v_ecef_mps;
    assert(size(r,1) == 3 && size(r,2) == K, 'T2 FAILED: r_ecef_m shape');
    assert(size(v,1) == 3 && size(v,2) == K, 'T2 FAILED: v_ecef_mps shape');
    assert(all(isfinite(r(:))) && all(isfinite(v(:))), 'T2 FAILED: non-finite truth');
    % GEO radius sanity: ~42164 km
    rad = vecnorm(r, 2, 1);
    assert(all(rad > 4.0e7 & rad < 4.4e7), 'T2 FAILED: asset not at GEO radius');
end
assert(abs(mat.time_s(end) - duration) < 1e-6, 'T2 FAILED: last truth epoch not kept');
fprintf('    PASS\n');

% ---------------------------------------------------------------------
% T3: relative geometry to the primary respects the helix separation bound
%     (helix separation stays in [baseline, 1.118*baseline], baseline=1000 m)
% ---------------------------------------------------------------------
fprintf('  T3: inter-asset baselines within helix bound ...\n');
assert(numel(mat.baselineToPrimary) == nAssets - 1, 'T3 FAILED: baseline count');
baseline = cfgM.formation.baseline_m;   % 1000 m
lo = 0.9 * baseline;
hi = 1.2 * baseline;                     % 1.118*baseline + margin
for b = 1:numel(mat.baselineToPrimary)
    rng_m = mat.baselineToPrimary(b).range_m;
    assert(mat.baselineToPrimary(b).toAsset == b + 1, 'T3 FAILED: toAsset index');
    assert(all(isfinite(rng_m)),           'T3 FAILED: non-finite baseline');
    assert(all(rng_m > lo & rng_m < hi),   'T3 FAILED: baseline outside helix bound');
end
fprintf('    PASS (baseline %g m, ranges in [%g, %g] m)\n', baseline, lo, hi);

% ---------------------------------------------------------------------
% T4: single-asset run leaves the .mat variable list unchanged (golden-safe)
% ---------------------------------------------------------------------
fprintf('  T4: single-asset .mat has no multiAssetTruth ...\n');
cfgS = i_shortReportCfg(1, duration, stride, fullfile(tmpRoot,'single'));
outS = revgnss.ReportRunner.runSingle(cfgS);
assert(exist(outS.matPath,'file') == 2, 'T4 FAILED: single-asset .mat not written');
varsS = who('-file', outS.matPath);
assert(~ismember('multiAssetTruth', varsS), ...
    'T4 FAILED: multiAssetTruth leaked into single-asset .mat');
fprintf('    PASS\n');

fprintf('=== test_multi_asset_truth_persistence: ALL PASS ===\n');

% =====================================================================
function cfg = i_shortReportCfg(nAssets, duration_s, stride_s, folder)
    cfg = masterConfig();
    cfg.scenario.nSpaceAssets    = nAssets;
    cfg.simulation.duration_s    = duration_s;
    cfg.simulation.dt_s          = 1;
    cfg.report.writePdf          = false;   % skips all figure/LaTeX generation
    cfg.report.writeMat          = true;
    cfg.report.compileTex        = 'never';
    cfg.plots.showFigures        = false;
    cfg.report.reportFolder      = folder;  % bypass per-run folder (test harness)
    cfg.multiAsset.recordTruth   = true;
    cfg.multiAsset.truthStride_s = stride_s;
end

function i_tryRmdir(d)
    try
        if exist(d,'dir'); rmdir(d, 's'); end
    catch
    end
end
