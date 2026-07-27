% test_per_asset_leaf_no_redispatch
% A federated swarm LEAF config must never re-enter the swarm.
%
% THE REGRESSION THIS PINS: cfg.multiAsset.keepIslInPerAssetEkf preserves nSpaceAssets in
% each per-asset config so the ISL builder has transmitters. But ReportRunner.runSingle
% dispatches to the federated path on nSpaceAssets>1, and buildUnifiedSwarmReport_ re-runs
% the chief through runSingle to get its rich SimData. The leaf therefore re-dispatched into
% a SECOND full 6-asset swarm: ~1016 s wasted, a swarm-shaped output where the chief's
% summary was expected, and -- because the chief re-run deliberately sets writePdf=false --
% NO PDF AT ALL. The user's writePdf=true toggle was correct and still produced nothing.
%
% Proves:
%   T1  singleAssetBase_ plants multiAsset.perAssetLeaf on every leaf, both toggle states
%   T2  the marker SURVIVES ConfigFactory.finalizeConfig -- the precondition the in-leaf
%       known-ambiguity-validation sub-run (a nested runSingle) depends on
%   T3  runSingle on a leaf does NOT re-dispatch: it returns a single-asset output, and the
%       federated banner is emitted ZERO times
%   T4  golden-safe: a plain single-asset config never carries the marker, and a genuine
%       swarm config still dispatches
%   T5  the KAV sub-run is collapsed to one asset (no nested constellation rebuild)

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir, '..');
addpath(rootDir); addpath(fullfile(rootDir, 'config')); addpath(fullfile(rootDir, 'config', 'internal'));

fprintf('=== test_per_asset_leaf_no_redispatch ===\n');

% ----------------------------------------------------------------
% T1: the marker is planted in both toggle states
% ----------------------------------------------------------------
fprintf('  T1: singleAssetBase_ plants perAssetLeaf ...\n');

for keep = [false true]
    b = revgnss.ReportRunner.federatedSetup_(i_cfg(keep)).base;
    assert(isfield(b,'multiAsset') && isfield(b.multiAsset,'perAssetLeaf') && b.multiAsset.perAssetLeaf, ...
        'T1 FAILED: leaf config has no perAssetLeaf marker (keepIsl=%d)', keep);
    expectN = 1; if keep; expectN = 4; end
    assert(b.scenario.nSpaceAssets == expectN, ...
        'T1 FAILED: keepIsl=%d gave nSpaceAssets=%d, expected %d', keep, b.scenario.nSpaceAssets, expectN);
end
fprintf('    marker present for keepIsl=false (nSA=1) and true (nSA=4): PASS\n');

% ----------------------------------------------------------------
% T2: the marker survives finalizeConfig
% ----------------------------------------------------------------
fprintf('  T2: marker survives ConfigFactory.finalizeConfig ...\n');

bOn  = revgnss.ReportRunner.federatedSetup_(i_cfg(true)).base;
fin  = revgnss.ConfigFactory.finalizeConfig(bOn);
assert(isfield(fin,'multiAsset') && isfield(fin.multiAsset,'perAssetLeaf') && fin.multiAsset.perAssetLeaf, ...
    ['T2 FAILED: finalizeConfig dropped perAssetLeaf. The in-leaf KAV sub-run calls runSingle ' ...
     'with the POST-finalize config, so losing the marker there re-opens the recursion -- and ' ...
     'with federated.parallel on, that is a nested multi-worker matlab -batch fan-out.']);
assert(fin.scenario.nSpaceAssets == 4, ...
    'T2 FAILED: finalizeConfig changed nSpaceAssets to %d', fin.scenario.nSpaceAssets);
fprintf('    perAssetLeaf survives finalize (nSA still 4): PASS\n');

% ----------------------------------------------------------------
% T3: runSingle on a leaf does NOT re-dispatch
% ----------------------------------------------------------------
fprintf('  T3: runSingle on a leaf runs single-asset (no swarm re-entry) ...\n');

leaf = revgnss.ReportRunner.assetConfigForIndex_(revgnss.ReportRunner.federatedSetup_(i_cfg(true)), 1);
leaf.report.writePdf = false; leaf.report.writeMat = false; leaf.report.compileTex = 'never';
leaf.report.enable = false; leaf.plots.enable = false; leaf.plots.showFigures = false;
txt = evalc('outLeaf = revgnss.ReportRunner.runSingle(leaf);');

nBanner = numel(regexp(txt, 'ReportRunner: federated swarm', 'start'));
assert(nBanner == 0, ...
    ['T3 FAILED: the federated banner appeared %d time(s) -- the leaf re-entered the swarm. ' ...
     'That is the regression: a second full N-asset run and no PDF.'], nBanner);
assert(isfield(outLeaf,'summary') && ~isempty(outLeaf.summary), ...
    'T3 FAILED: leaf run returned no summary (swarm-shaped output?)');
assert(~isfield(outLeaf,'rel'), ...
    'T3 FAILED: leaf output carries a relative-layer struct, i.e. it took the swarm path');
fprintf('    federated banner emitted 0 times, single-asset summary returned: PASS\n');

% ----------------------------------------------------------------
% T4: golden-safety -- plain configs are untouched
% ----------------------------------------------------------------
fprintf('  T4: a plain single-asset config never carries the marker ...\n');

plain = masterConfig();
assert(~(isfield(plain,'multiAsset') && isfield(plain.multiAsset,'perAssetLeaf')), ...
    'T4 FAILED: masterConfig declares perAssetLeaf; it is internal plumbing, not a user knob');
assert(~revgnss.ReportRunner.perAssetLeaf_(plain), ...
    'T4 FAILED: perAssetLeaf_ returned true for a plain config (absent must mean false)');
% and a genuine swarm config must STILL dispatch
swarmCfg = i_cfg(true);
assert(~revgnss.ReportRunner.perAssetLeaf_(swarmCfg) && swarmCfg.scenario.nSpaceAssets > 1, ...
    'T4 FAILED: a real swarm config looks like a leaf; it would never run the swarm at all');
fprintf('    absent => false; a real swarm config still dispatches: PASS\n');

% ----------------------------------------------------------------
% T5: KAV is collapsed to one asset
% ----------------------------------------------------------------
fprintf('  T5: the KAV sub-run is collapsed to a single asset ...\n');

src = fileread(fullfile(rootDir,'+revgnss','ReportRunner.m'));
assert(~isempty(regexp(src, 'cfg_kav\.scenario\.nSpaceAssets\s*=\s*1', 'once')), ...
    ['T5 FAILED: the KAV sub-run does not force nSpaceAssets=1. On a leaf it would rebuild the ' ...
     'whole constellation for a 120 s run whose ISL ambiguity states never receive a row ' ...
     '(warmup 300 s > 120 s) -- pure cost and a 100%% artefact.']);
assert(~isempty(regexp(src, 'cfg_kav\.measurements\.isl\.enable\s*=\s*false', 'once')), ...
    'T5 FAILED: the KAV sub-run does not disable ISL; KAV validates ground attitude ambiguities');
fprintf('    KAV forces nSpaceAssets=1 and isl.enable=false: PASS\n');

fprintf('=== test_per_asset_leaf_no_redispatch: ALL PASS ===\n');

% ----------------------------------------------------------------
function cfg = i_cfg(keepIsl)
    cfg = masterConfig();
    cfg.simulation.seed = 42; cfg.simulation.duration_s = 120;
    cfg.scenario.nSpaceAssets = 4; cfg.scenario.nReceivers = 1;
    cfg.multiAsset.keepIslInPerAssetEkf = keepIsl;
    cfg.measurements.isl.enable = true; cfg.measurements.isl.transmitters = 'all';
    cfg.measurements.isl.receiverAssetIndex = 1;
    cfg.measurements.isl.code.enable = true; cfg.measurements.isl.code.useInEKF = true;
    cfg.measurements.isl.warmup_s = 30;
    cfg.estimator.runKnownAmbiguityValidation = false;   % keep the test fast
    cfg.report.writePdf = false; cfg.report.writeMat = false; cfg.report.compileTex = 'never';
    cfg.plots.enable = false; cfg.plots.showFigures = false;
end
