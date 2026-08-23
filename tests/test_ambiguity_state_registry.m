% test_ambiguity_state_registry
% Phase 1a (feature/ISL-LAMBDA): link-agnostic ambiguity addressing.
%
% Proves the AmbiguityKey / AmbiguityStateRegistry pair upholds the three
% golden-safety invariants that let a NEW link family (ISL) own ambiguity states
% without renumbering the legacy ground block:
%
%   1. ORDER REPRODUCTION -- the registry allocates the ground family in exactly
%      the order the live EKF does (cross-checked against a REAL ekf.stateMap,
%      not against a restatement of the loop, so the test cannot drift from
%      ReverseGNSSEKF.m).
%   2. APPEND-ONLY        -- registering ISL never moves a ground index.
%   3. IDEMPOTENCE        -- re-registering a key is a no-op.
%
% Nothing here is wired into the EKF yet; these are standalone classes.

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_ambiguity_state_registry ===\n');

% ----------------------------------------------------------------
% T1: ground key char is byte-identical to the legacy tracker key
% ----------------------------------------------------------------
fprintf('  T1: ground key matches legacy CarrierTrackManager format ...\n');

k_g = revgnss.AmbiguityKey.ground(7, 3, 2);
legacy_g = sprintf('T%03d_A%03d_S%02d', 7, 3, 2);
assert(strcmp(k_g.key, legacy_g), ...
    'T1 FAILED: ground key ''%s'' != legacy ''%s''', k_g.key, legacy_g);
assert(revgnss.AmbiguityKey.isGround(k_g), 'T1 FAILED: isGround false');
fprintf('    ''%s'': PASS\n', k_g.key);

% ----------------------------------------------------------------
% T2: ISL key is distinct and well-formed
% ----------------------------------------------------------------
fprintf('  T2: ISL key distinct from ground ...\n');

k_i = revgnss.AmbiguityKey.islOneWay(2, 1, 1);
assert(revgnss.AmbiguityKey.isIsl(k_i), 'T2 FAILED: isIsl false');
assert(~strcmp(k_i.key, k_g.key), 'T2 FAILED: ISL key collides with ground');
assert(contains(k_i.key, 'ISL'), 'T2 FAILED: ISL key lacks ISL tag: %s', k_i.key);
fprintf('    ''%s'': PASS\n', k_i.key);

% ----------------------------------------------------------------
% T3: idempotence -- re-registering returns the same index, count flat
% ----------------------------------------------------------------
fprintf('  T3: register() is idempotent ...\n');

reg_idem = revgnss.AmbiguityStateRegistry(1);
i1 = reg_idem.register(revgnss.AmbiguityKey.ground(1,1,1));
i2 = reg_idem.register(revgnss.AmbiguityKey.ground(1,1,1));
assert(i1 == i2, 'T3 FAILED: second register returned %d, expected %d', i2, i1);
assert(reg_idem.count() == 1, 'T3 FAILED: count=%d after duplicate register', ...
    reg_idem.count());
fprintf('    idx stable at %d, count=1: PASS\n', i1);

% ----------------------------------------------------------------
% T4: CROSS-CHECK vs a REAL EKF -- 2-D mode (floatPerTowerSignal)
% ----------------------------------------------------------------
fprintf('  T4: registry order == live EKF stateMap (2-D floatPerTowerSignal) ...\n');

cfg_reg2 = revgnss.ConfigFactory.defaultConfig();
cfg_reg2.measurements.carrierMode  = 'ekfFloat';
cfg_reg2.estimation.ambiguityMode  = 'floatPerTowerSignal';
cfg_reg2.plots.enable  = false;
cfg_reg2.report.enable = false;

[~, ~, ekf_reg2] = revgnss.ScenarioFactory.build(cfg_reg2);
sm_reg2   = ekf_reg2.stateMap;
nT_reg2   = ekf_reg2.nTowers;
nSig_reg2 = ekf_reg2.ambiguityNSignals;

% Base index = the smallest ambiguity index the EKF actually allocated.
base_reg2 = min(sm_reg2.ambiguityIdx(sm_reg2.ambiguityIdx > 0));
reg2 = revgnss.AmbiguityStateRegistry(base_reg2);
got_reg2 = reg2.registerGroundBlock(nT_reg2, 1, nSig_reg2, 'floatPerTowerSignal');

assert(isequal(size(got_reg2), size(sm_reg2.ambiguityIdx)), ...
    'T4 FAILED: shape %s != EKF %s', mat2str(size(got_reg2)), ...
    mat2str(size(sm_reg2.ambiguityIdx)));
assert(isequal(got_reg2, sm_reg2.ambiguityIdx), ...
    'T4 FAILED: registry order != EKF order\n  registry: %s\n  ekf     : %s', ...
    mat2str(got_reg2(:)'), mat2str(sm_reg2.ambiguityIdx(:)'));
fprintf('    %d towers x %d signals, base=%d, %d indices identical: PASS\n', ...
    nT_reg2, nSig_reg2, base_reg2, numel(got_reg2));

% ----------------------------------------------------------------
% T5: CROSS-CHECK vs a REAL EKF -- 3-D mode (floatPerTowerReceiverSignal)
% ----------------------------------------------------------------
fprintf('  T5: registry order == live EKF stateMap (3-D perTowerReceiverSignal) ...\n');

cfg_reg3 = revgnss.ConfigFactory.defaultConfig();
cfg_reg3.measurements.carrierMode  = 'ekfFloat';
cfg_reg3.estimation.ambiguityMode  = 'floatPerTowerReceiverSignal';
cfg_reg3.scenario.nReceivers       = 4;
cfg_reg3.plots.enable  = false;
cfg_reg3.report.enable = false;

[~, ~, ekf_reg3] = revgnss.ScenarioFactory.build(cfg_reg3);
sm_reg3 = ekf_reg3.stateMap;

if isfield(sm_reg3, 'ambiguityIdx3d') && ~isempty(sm_reg3.ambiguityIdx3d) && ...
        any(sm_reg3.ambiguityIdx3d(:) > 0)
    nT_reg3   = ekf_reg3.nTowers;
    nRx_reg3  = ekf_reg3.ambiguityNReceivers;
    nSig_reg3 = ekf_reg3.ambiguityNSignals;
    base_reg3 = min(sm_reg3.ambiguityIdx3d(sm_reg3.ambiguityIdx3d > 0));

    reg3 = revgnss.AmbiguityStateRegistry(base_reg3);
    got_reg3 = reg3.registerGroundBlock(nT_reg3, nRx_reg3, nSig_reg3, ...
        'floatPerTowerReceiverSignal');

    assert(isequal(got_reg3, sm_reg3.ambiguityIdx3d), ...
        ['T5 FAILED: 3-D registry order != EKF order (nesting mismatch)\n' ...
         '  registry: %s\n  ekf     : %s'], ...
        mat2str(got_reg3(:)'), mat2str(sm_reg3.ambiguityIdx3d(:)'));
    fprintf('    %dT x %dRx x %dSig, base=%d, %d indices identical: PASS\n', ...
        nT_reg3, nRx_reg3, nSig_reg3, base_reg3, numel(got_reg3));
else
    fprintf('    (3-D map not populated in this config; order asserted in T4): SKIP\n');
end

% ----------------------------------------------------------------
% T6: APPEND-ONLY -- ISL registration never moves a ground index
% ----------------------------------------------------------------
fprintf('  T6: ISL block appends without renumbering ground ...\n');

reg_mix = revgnss.AmbiguityStateRegistry(10);
gnd_before = reg_mix.registerGroundBlock(3, 1, 1, 'floatPerTowerSignal');
nGnd_mix   = reg_mix.count();

isl_idx = reg_mix.registerIslBlock([2 3 4], 1, 1);

gnd_after = zeros(size(gnd_before));
for ti_mix = 1:3
    gnd_after(ti_mix) = reg_mix.idxOf(revgnss.AmbiguityKey.ground(ti_mix, 1, 1));
end
assert(isequal(gnd_before, gnd_after), ...
    'T6 FAILED: ground indices moved: %s -> %s', ...
    mat2str(gnd_before(:)'), mat2str(gnd_after(:)'));
assert(all(isl_idx(:) > max(gnd_before(:))), ...
    'T6 FAILED: ISL indices %s not strictly above ground max %d', ...
    mat2str(isl_idx(:)'), max(gnd_before(:)));
assert(reg_mix.count() == nGnd_mix + 3, ...
    'T6 FAILED: count=%d, expected %d', reg_mix.count(), nGnd_mix + 3);
fprintf('    ground %s unchanged; ISL %s appended: PASS\n', ...
    mat2str(gnd_before(:)'), mat2str(isl_idx(:)'));

% ----------------------------------------------------------------
% T7: family separation without assuming contiguity
% ----------------------------------------------------------------
fprintf('  T7: indicesOfType separates families ...\n');

gIdx_mix = reg_mix.indicesOfType(revgnss.AmbiguityKey.GROUND);
iIdx_mix = reg_mix.indicesOfType(revgnss.AmbiguityKey.ISL);
assert(isequal(sort(gIdx_mix), sort(gnd_before(:)')), ...
    'T7 FAILED: ground family %s != %s', mat2str(gIdx_mix), mat2str(gnd_before(:)'));
assert(isequal(sort(iIdx_mix), sort(isl_idx(:)')), ...
    'T7 FAILED: ISL family %s != %s', mat2str(iIdx_mix), mat2str(isl_idx(:)'));
assert(isempty(intersect(gIdx_mix, iIdx_mix)), 'T7 FAILED: families overlap');
fprintf('    ground=%s isl=%s disjoint: PASS\n', mat2str(gIdx_mix), mat2str(iIdx_mix));

% ----------------------------------------------------------------
% T8: unregistered lookup returns 0 (never a silent wrong index)
% ----------------------------------------------------------------
fprintf('  T8: idxOf(unknown) == 0 ...\n');

assert(reg_mix.idxOf(revgnss.AmbiguityKey.ground(99, 1, 1)) == 0, ...
    'T8 FAILED: unknown ground key did not return 0');
assert(reg_mix.idxOf(revgnss.AmbiguityKey.islOneWay(9, 9, 9)) == 0, ...
    'T8 FAILED: unknown ISL key did not return 0');
assert(~reg_mix.has(revgnss.AmbiguityKey.ground(99, 1, 1)), 'T8 FAILED: has() true');
fprintf('    PASS\n');

fprintf('=== test_ambiguity_state_registry: ALL PASS ===\n');
