% test_multiasset_mode_switch
%
% cfg.multiAsset.mode convenience switch: 'fast' (passthrough, default) vs 'honest'
% (joint per-satellite estimation bundle). Resolved by
% revgnss.ConfigFactory.applyMultiAssetMode in BOTH masterConfig and finalizeConfig
% (ordering-safe). The switch must be golden-safe (passthrough by default) and must not
% disturb configs/tests that set the granular toggles directly.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir, '..');
addpath(rootDir); addpath(fullfile(rootDir, 'config'));

fprintf('=== test_multiasset_mode_switch ===\n');

% ---------------------------------------------------------------------
% T1: default is 'fast' and a passthrough (single-asset, byte-safe)
% ---------------------------------------------------------------------
fprintf('  T1: default mode=fast is a passthrough ...\n');
c = masterConfig();
assert(strcmp(c.multiAsset.mode,'fast'), 'T1 FAILED: default mode not fast');
assert(strcmp(c.multiAsset.estimateMode,'off'), 'T1 FAILED: fast changed estimateMode');
% applyMultiAssetMode on a fast cfg returns it unchanged
c2 = revgnss.ConfigFactory.applyMultiAssetMode(c);
assert(isequaln(c, c2), 'T1 FAILED: fast mode is not a pure passthrough');
fprintf('    PASS\n');

% ---------------------------------------------------------------------
% T2: 'honest' expands the bundle (pure resolution, no sim)
% ---------------------------------------------------------------------
fprintf('  T2: honest expands estimateMode/towers/twoWayISL/ISL ...\n');
h = masterConfig();
h.scenario.nSpaceAssets = 6; h.multiAsset.mode = 'honest';
h = revgnss.ConfigFactory.applyMultiAssetMode(h);
assert(strcmp(h.multiAsset.estimateMode,'position'), 'T2 FAILED: estimateMode not position');
assert(h.multiAsset.towersObserveSecondaries, 'T2 FAILED: towersObserveSecondaries not set');
assert(h.multiAsset.twoWayISL.enable, 'T2 FAILED: twoWayISL not enabled');
assert(h.measurements.isl.enable && h.measurements.isl.code.useInEKF && h.measurements.isl.doppler.useInEKF, ...
    'T2 FAILED: ISL observability not ensured');
fprintf('    PASS\n');

% ---------------------------------------------------------------------
% T3: honest at nSpaceAssets<2 is an error (no secondaries to estimate)
% ---------------------------------------------------------------------
fprintf('  T3: honest + single-asset -> error ...\n');
b = masterConfig(); b.scenario.nSpaceAssets = 1; b.multiAsset.mode = 'honest';
assert(i_throws(@() revgnss.ConfigFactory.applyMultiAssetMode(b)), 'T3 FAILED: no error for honest@N=1');
% unknown mode is also an error
u = masterConfig(); u.multiAsset.mode = 'medium';
assert(i_throws(@() revgnss.ConfigFactory.applyMultiAssetMode(u)), 'T3 FAILED: no error for bad mode');
fprintf('    PASS\n');

% ---------------------------------------------------------------------
% T4: backward-compat -- fast does NOT clobber a directly-set estimateMode
% ---------------------------------------------------------------------
fprintf('  T4: fast passthrough respects a hand-set estimateMode ...\n');
d = masterConfig(); d.scenario.nSpaceAssets = 6;
d.multiAsset.estimateMode = 'position'; d.multiAsset.towersObserveSecondaries = true;  % mode stays 'fast'
d = revgnss.ConfigFactory.applyMultiAssetMode(d);
assert(strcmp(d.multiAsset.estimateMode,'position'), 'T4 FAILED: fast clobbered a hand-set estimateMode');
fprintf('    PASS\n');

% ---------------------------------------------------------------------
% T5: ordering-safe -- honest set AFTER masterConfig still allocates states
%     (finalizeConfig re-resolves; state dim jumps 59 -> 99 for N=6/R4)
% ---------------------------------------------------------------------
fprintf('  T5: honest via switch allocates secondary states (nx) ...\n');
nxFast = i_nx(i_swarm('fast'));
nxHon  = i_nx(i_swarm('honest'));
fprintf('    fast nx=%d, honest nx=%d\n', nxFast, nxHon);
assert(nxFast == 59, 'T5 FAILED: fast swarm nx expected 59');
assert(nxHon == 59 + 8*5, 'T5 FAILED: honest swarm nx expected 99 (8 states x 5 secondaries)');
fprintf('    PASS\n');

fprintf('=== test_multiasset_mode_switch: ALL PASS ===\n');

% =====================================================================
function cfg = i_swarm(mode)
    % 6-asset / 4-rx swarm with mode set POST-masterConfig (the footgun path).
    cfg = masterConfig();
    cfg.scenario.nSpaceAssets = 6; cfg.scenario.nReceivers = 4; cfg.scenario.nTowers = 5;
    cfg.simulation.duration_s = 120;
    cfg.multiAsset.mode = mode;
    if strcmp(mode,'honest'); cfg.asset.clock.deterministic = false; end
    cfg.report.writePdf=false; cfg.report.writeMat=false; cfg.report.compileTex='never'; cfg.plots.showFigures=false;
end

function nx = i_nx(cfg)
    sim = revgnss.ReverseGNSSSimulation(revgnss.ConfigFactory.finalizeConfig(cfg));
    sim.initialize();
    nx = sim.ekf.nx;
end

function tf = i_throws(f)
    tf = false;
    try
        f();
    catch
        tf = true;
    end
end
