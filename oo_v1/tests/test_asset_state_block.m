% test_asset_state_block
%
% Phase 3b-1 foundation: revgnss.AssetStateBlock.forAsset(sm,i) is the per-asset state-index
% resolver the measurement builders will read instead of the hard-coded chief stateMap fields.
% The load-bearing invariant is T1: forAsset(sm,1) reproduces today's chief indices EXACTLY
% (value AND shape) -- that is what makes routing the frozen-core builders through it at
% assetIndex=1 byte-identical.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir, '..');
addpath(rootDir); addpath(fullfile(rootDir, 'config'));
fprintf('=== test_asset_state_block ===\n');

% ---------------------------------------------------------------------
% T1: forAsset(sm,1) reproduces the chief stateMap fields EXACTLY (byte-identical substitution)
% ---------------------------------------------------------------------
fprintf('  T1: chief block == today''s stateMap indices (exact) ...\n');
[sm1, x1] = i_state(i_cfg1());
b = revgnss.AssetStateBlock.forAsset(sm1, 1);
assert(isequal(b.r, sm1.r_idx),         'T1 FAILED: .r ~= r_idx (value/shape)');
assert(isequal(b.v, sm1.v_idx),         'T1 FAILED: .v ~= v_idx');
assert(isequal(b.euler, sm1.euler_idx), 'T1 FAILED: .euler ~= euler_idx');
assert(isequal(b.b, sm1.b_rx_idx),      'T1 FAILED: .b ~= b_rx_idx');
assert(isequal(b.bdot, sm1.bdot_rx_idx),'T1 FAILED: .bdot ~= bdot_rx_idx');
assert(isequal(b.ambiguity3d, i_field(sm1,'ambiguityIdx3d')), 'T1 FAILED: .ambiguity3d ~= ambiguityIdx3d');
assert(isequal(b.ambiguity,   i_field(sm1,'ambiguityIdx')),   'T1 FAILED: .ambiguity ~= ambiguityIdx');
assert(isequal(b.zwd,  i_field(sm1,'zwdIdx')),  'T1 FAILED: .zwd ~= zwdIdx');
assert(isequal(b.iono, i_field(sm1,'ionoIdx')), 'T1 FAILED: .iono ~= ionoIdx');
% the actual read the builders do must be identical
assert(isequal(x1(b.r), x1(sm1.r_idx)) && isequal(x1(b.euler), x1(sm1.euler_idx)), ...
    'T1 FAILED: x-indexing through the block differs from the chief read');
fprintf('    PASS\n');

% ---------------------------------------------------------------------
% T2: forAsset(sm,i>1) maps the secondary blocks; no attitude/iono/3d-ambiguity yet
% ---------------------------------------------------------------------
fprintf('  T2: secondary blocks ...\n');
sm2 = i_state(i_cfgSwarm(3));
for i = 2:3
    si = i - 1;
    a = revgnss.AssetStateBlock.forAsset(sm2, i);
    assert(isequal(a.r, sm2.secondaryOrbitIdx(si,1:3)'), 'T2 FAILED: secondary .r');
    assert(isequal(a.v, sm2.secondaryOrbitIdx(si,4:6)'), 'T2 FAILED: secondary .v');
    assert(isequal(a.b, sm2.secondaryClockIdx(si,1)),    'T2 FAILED: secondary .b');
    assert(isequal(a.bdot, sm2.secondaryClockIdx(si,2)), 'T2 FAILED: secondary .bdot');
    assert(isempty(a.euler) && isempty(a.iono) && isempty(a.ambiguity3d), ...
        'T2 FAILED: secondary should have no attitude/iono/3d-ambiguity yet');
end
fprintf('    PASS\n');

% ---------------------------------------------------------------------
% T3: chief position/clock indices are disjoint from any secondary block (sanity)
% ---------------------------------------------------------------------
fprintf('  T3: chief vs secondary indices disjoint ...\n');
bc = revgnss.AssetStateBlock.forAsset(sm2, 1);
chief = [bc.r(:); bc.b];
sec = [];
for i = 2:3
    a = revgnss.AssetStateBlock.forAsset(sm2, i);
    sec = [sec; a.r(:); a.b]; %#ok<AGROW>
end
assert(isempty(intersect(chief, sec)), 'T3 FAILED: chief/secondary index overlap');
fprintf('    PASS\n');

fprintf('=== test_asset_state_block: ALL PASS ===\n');

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

function [sm, x] = i_state(cfg)
    sim = revgnss.ReverseGNSSSimulation(revgnss.ConfigFactory.finalizeConfig(cfg)); sim.initialize();
    sm = sim.ekf.stateMap; x = sim.ekf.x;
end

function v = i_field(sm, f)
    v = [];
    if isfield(sm, f); v = sm.(f); end
end
