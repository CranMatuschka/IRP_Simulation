% test_keep_isl_in_per_asset_ekf
% cfg.multiAsset.keepIslInPerAssetEkf: do the ISL rows survive into each per-asset EKF?
%
% In the federated swarm each member runs its own single-asset EKF on the GROUND rows (W1)
% while a separate read-only layer consumes the ISL/TWSTFT observables (W2). ReportRunner
% strips ISL out of W1 so the same photon is never counted twice. That strip is now gated.
%
% THE POINT OF THIS TEST is that the gate is not cosmetic. singleAssetBase_ also forces
% nSpaceAssets=1, and with one asset the ISL builder has ZERO transmitters -- so merely
% un-stripping measurements.isl.enable would leave a knob that flips a boolean and changes
% no measurement whatsoever. T3 asserts real ISL rows appear, which is the only thing that
% makes the toggle mean anything.
%
% Proves:
%   T1  default false -> per-asset cfg is byte-identical to the frozen behaviour
%       (isl.enable=false AND nSpaceAssets=1)
%   T2  true -> the constellation survives (isl.enable=true AND nSpaceAssets=N)
%   T3  NOT A FAKE KNOB: a real run produces >0 ISL measurement rows with the toggle on
%       and exactly 0 with it off
%   T4  the toggle is read in exactly ONE place (no default collision, the failure mode
%       that cost 876 m on crossTrackSpread)

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir, '..');
addpath(rootDir); addpath(fullfile(rootDir, 'config'));

fprintf('=== test_keep_isl_in_per_asset_ekf ===\n');

N_ASSETS = 4;

% ----------------------------------------------------------------
% T1 + T2: what reaches the per-asset EKF config
% ----------------------------------------------------------------
fprintf('  T1: default (false) strips ISL and collapses to one asset ...\n');

cfgOff = i_cfg(false);
baseOff = i_perAssetBase(cfgOff);
assert(~baseOff.measurements.isl.enable, ...
    'T1 FAILED: isl.enable=true with the toggle off; the frozen W1/W2 disjointness is broken');
assert(baseOff.scenario.nSpaceAssets == 1, ...
    'T1 FAILED: nSpaceAssets=%d, expected 1', baseOff.scenario.nSpaceAssets);
fprintf('    isl.enable=false, nSpaceAssets=1: PASS\n');

fprintf('  T2: true keeps ISL AND the constellation ...\n');

cfgOn = i_cfg(true);
baseOn = i_perAssetBase(cfgOn);
assert(baseOn.measurements.isl.enable, ...
    'T2 FAILED: isl.enable was still stripped with the toggle on');
assert(baseOn.scenario.nSpaceAssets == N_ASSETS, ...
    ['T2 FAILED: nSpaceAssets=%d, expected %d. Collapsing to 1 leaves the ISL builder ' ...
     'with no transmitters, which is exactly the fake-knob failure this test exists for.'], ...
    baseOn.scenario.nSpaceAssets, N_ASSETS);
fprintf('    isl.enable=true, nSpaceAssets=%d: PASS\n', baseOn.scenario.nSpaceAssets);

% ----------------------------------------------------------------
% T3: THE ANTI-FAKE-KNOB ASSERTION -- real rows, in a real run
% ----------------------------------------------------------------
fprintf('  T3: real run produces real ISL rows (not just a flipped boolean) ...\n');

[totOff, mxOff] = i_rowStats(baseOff);
[totOn,  mxOn ] = i_rowStats(baseOn);
assert(totOn > totOff, ...
    ['T3 FAILED: total EKF rows %g with the toggle ON vs %g OFF. The gate flips a flag but ' ...
     'no measurement changes -- the toggle is cosmetic and must not ship.'], totOn, totOff);
% 3 secondaries -> 3 one-way ISL code rows per epoch once past warmup.
nLinks = N_ASSETS - 1;
assert(mxOn - mxOff == nLinks, ...
    ['T3 FAILED: peak rows/epoch rose by %d, expected exactly %d (one code row per ' ...
     'secondary). A different count means the ISL rows are not the ones being added.'], ...
    mxOn - mxOff, nLinks);
fprintf('    rows/epoch peak %g -> %g (+%d links); total %g -> %g: PASS\n', ...
    mxOff, mxOn, nLinks, totOff, totOn);

% ----------------------------------------------------------------
% T4: one key, one reader
% ----------------------------------------------------------------
fprintf('  T4: single reader, no default collision ...\n');

cfgD = masterConfig();
assert(isfield(cfgD.multiAsset,'keepIslInPerAssetEkf'), ...
    'T4 FAILED: keepIslInPerAssetEkf must be declared in masterConfig');
assert(cfgD.multiAsset.keepIslInPerAssetEkf == false, ...
    'T4 FAILED: default must be false so the frozen swarm results are unchanged');

% Count CODE reads only: the field is also named in the explanatory comments, and those
% are documentation, not a second source of truth.
rrLines = strsplit(fileread(fullfile(rootDir,'+revgnss','ReportRunner.m')), newline);
nReads = 0;
for li = 1:numel(rrLines)
    ln = strtrim(rrLines{li});
    if startsWith(ln, '%'); continue; end
    nReads = nReads + numel(regexp(ln, 'multiAsset\.keepIslInPerAssetEkf', 'start'));
end
assert(nReads == 1, ...
    ['T4 FAILED: the config field is read %d times in ReportRunner. It must be read ONCE ' ...
     '(in keepIslInPerAssetEkf_) -- two readers with different fallbacks is the default ' ...
     'collision that silently moved the formation by 876 m.'], nReads);
fprintf('    declared once (false), read once via keepIslInPerAssetEkf_: PASS\n');

fprintf('=== test_keep_isl_in_per_asset_ekf: ALL PASS ===\n');

% ----------------------------------------------------------------
function base = i_perAssetBase(cfg)
    % The exact config each federated member's EKF is built from.
    setup = revgnss.ReportRunner.federatedSetup_(cfg);
    base  = setup.base;
end

function [total, peak] = i_rowStats(base1)
    % EKF measurement rows actually processed: total over the run, and the per-epoch peak.
    % numMeasurementRows = numel(z), i.e. the rows the update genuinely consumed -- not a
    % config echo, so it cannot agree with a toggle that does nothing.
    sim = revgnss.ReverseGNSSSimulation(revgnss.ConfigFactory.finalizeConfig(base1));
    evalc('sim.initialize(); sim.run();');
    nr = sim.simData.getNumMeasurementRows();
    total = sum(nr); peak = max(nr);
end

function cfg = i_cfg(keepIsl)
    cfg = masterConfig();
    cfg.simulation.seed = 42; cfg.simulation.duration_s = 300;
    cfg.scenario.nSpaceAssets = 4; cfg.scenario.nReceivers = 1;
    cfg.multiAsset.keepIslInPerAssetEkf = keepIsl;
    cfg.measurements.isl.enable = true; cfg.measurements.isl.transmitters = 'all';
    cfg.measurements.isl.receiverAssetIndex = 1;
    cfg.measurements.isl.code.enable = true; cfg.measurements.isl.code.useInEKF = true;
    cfg.measurements.isl.warmup_s = 60;
    cfg.report.writePdf = false; cfg.report.writeMat = false; cfg.report.compileTex = 'never';
    cfg.plots.enable = false; cfg.plots.showFigures = false;
end
