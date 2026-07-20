% test_asset_symmetry_view
%
% Phase 1 of the asset-symmetry generalization: sm.asset(i) is a uniform per-asset VIEW that
% ALIASES the existing state-map indices (chief = asset 1, secondaries 2..N). It allocates no
% state and moves nothing -> golden byte-identical (verified by the smoke gates separately).
% This test asserts the aliasing is exact.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir, '..');
addpath(rootDir); addpath(fullfile(rootDir, 'config'));
fprintf('=== test_asset_symmetry_view ===\n');

% ---------------------------------------------------------------------
% T1: single-asset -> asset(1) reproduces today's literal chief indices
% ---------------------------------------------------------------------
fprintf('  T1: single-asset asset(1) aliases the chief block ...\n');
sm1 = i_stateMap(i_cfg1());
assert(isscalar(sm1.asset), 'T1 FAILED: single-asset view is not 1x1');
a = sm1.asset(1);
assert(isequal(a.r, sm1.r_idx(:)'),     'T1 FAILED: asset(1).r ~= r_idx');
assert(isequal(a.v, sm1.v_idx(:)'),     'T1 FAILED: asset(1).v ~= v_idx');
assert(isequal(a.euler, sm1.euler_idx(:)'), 'T1 FAILED: asset(1).euler ~= euler_idx');
assert(isequal(a.omega, sm1.omega_idx(:)'), 'T1 FAILED: asset(1).omega ~= omega_idx');
assert(isequal(a.b, sm1.b_rx_idx),      'T1 FAILED: asset(1).b ~= b_rx_idx');
assert(isequal(a.bdot, sm1.bdot_rx_idx),'T1 FAILED: asset(1).bdot ~= bdot_rx_idx');
fprintf('    PASS\n');

% ---------------------------------------------------------------------
% T2: swarm (honest 3-asset position) -> asset(2..N) alias the secondary blocks
% ---------------------------------------------------------------------
fprintf('  T2: swarm asset(2..N) alias secondary blocks ...\n');
sm2 = i_stateMap(i_cfgSwarm(3));
assert(numel(sm2.asset) == 3, 'T2 FAILED: view length ~= 3');
assert(isequal(sm2.asset(1).r, sm2.r_idx(:)'), 'T2 FAILED: chief alias broke in swarm');
for si = 1:2
    aj = si + 1;
    assert(isequal(sm2.asset(aj).r, sm2.secondaryOrbitIdx(si,1:3)), 'T2 FAILED: asset r alias');
    assert(isequal(sm2.asset(aj).v, sm2.secondaryOrbitIdx(si,4:6)), 'T2 FAILED: asset v alias');
    assert(isequal(sm2.asset(aj).b, sm2.secondaryClockIdx(si,1)),   'T2 FAILED: asset b alias');
    assert(isequal(sm2.asset(aj).bdot, sm2.secondaryClockIdx(si,2)),'T2 FAILED: asset bdot alias');
    assert(isempty(sm2.asset(aj).euler), 'T2 FAILED: secondary has no attitude yet -> euler should be empty');
end
fprintf('    PASS\n');

% ---------------------------------------------------------------------
% T3: every aliased index is valid (in [1,nx]) and disjoint across assets
% ---------------------------------------------------------------------
fprintf('  T3: view indices valid + disjoint across assets ...\n');
nx = i_nx(i_cfgSwarm(3));
allIdx = [];
for i = 1:numel(sm2.asset)
    v = [sm2.asset(i).r(:); sm2.asset(i).v(:); sm2.asset(i).b(:); sm2.asset(i).bdot(:)];
    assert(all(v >= 1 & v <= nx), 'T3 FAILED: view index out of [1,nx]');
    allIdx = [allIdx; v]; %#ok<AGROW>
end
assert(numel(unique(allIdx)) == numel(allIdx), 'T3 FAILED: asset position/clock indices overlap');
fprintf('    PASS\n');

fprintf('=== test_asset_symmetry_view: ALL PASS ===\n');

% =====================================================================
function cfg = i_cfg1()
    cfg = masterConfig();
    cfg.simulation.duration_s = 10;
    cfg.report.writePdf=false; cfg.report.writeMat=false; cfg.report.compileTex='never';
    cfg.plots.showFigures=false; cfg.plots.enable=false;
end

function cfg = i_cfgSwarm(nA)
    cfg = i_cfg1();
    cfg.scenario.nSpaceAssets = nA; cfg.scenario.nReceivers = 1; cfg.scenario.nTowers = 5;
    cfg.multiAsset.mode = 'honest';
end

function sm = i_stateMap(cfg)
    sim = revgnss.ReverseGNSSSimulation(revgnss.ConfigFactory.finalizeConfig(cfg)); sim.initialize();
    sm = sim.ekf.stateMap;
end

function nx = i_nx(cfg)
    sim = revgnss.ReverseGNSSSimulation(revgnss.ConfigFactory.finalizeConfig(cfg)); sim.initialize();
    nx = sim.ekf.nx;
end
