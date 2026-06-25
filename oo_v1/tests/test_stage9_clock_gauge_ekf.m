% test_stage9_clock_gauge_ekf  Stage 9 clock-gauge EKF constraint tests.
%
% T-P9a: spacecraft-receiver-clock-only still runs (no regression)
% T-P9b: includeTowerClocksInEKF + gauge='free' → error containing 'unobservable'
% T-P9c: includeTowerClocksInEKF + gauge='free' → error contains 'gauge'
% T-P9d: fixReferenceTower → gauge rows >= 1 added each epoch (EKF updates ran)
% T-P9e: fixReferenceTower → clock subspace rank is finite and positive
% T-P9f: meanGroundClockGauge → gauge rows >= 1 added
% T-P9g: meanGroundClockGauge → clock subspace rank is finite and positive
% T-P9h: gauge rows NOT counted in getNumMeasurements() (pseudorange count unchanged)
% T-P9i: getClockGaugeBiasResiduals() returns finite values for fixReferenceTower
% T-P9j: cfg defaults include sigmaBias_m, sigmaDrift_mps, referenceTowerIndex

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_stage9_clock_gauge_ekf ===\n');

% Shared parameters: 5 towers so EKF updates run (>= 4 measurements/epoch)
nT  = 5;
dur = 20;

% ----------------------------------------------------------------
% T-P9a: baseline spacecraft-clock-only still runs
% ----------------------------------------------------------------
fprintf('  T-P9a: baseline spacecraftReceiverClockOnly ...\n');
cfg_base = revgnss.ConfigFactory.defaultConfig();
cfg_base.scenario.nTowers      = nT;
cfg_base.scenario.nReceivers   = 1;
cfg_base.simulation.duration_s = dur;
cfg_base.simulation.dt_s       = 1;
cfg_base.plots.enable  = false;
cfg_base.report.enable = false;
cfg_base.errors.codeNoise.sigma_m = 0;
% Default: clock.mode='spacecraftReceiverClockOnly' — no tower clock states

sim_base = revgnss.ReverseGNSSSimulation(cfg_base);
sim_base.run();
posErr = sim_base.diag.getPositionErrors();
assert(~isempty(posErr) && all(isfinite(posErr)), ...
    'T-P9a FAILED: baseline run did not produce finite position errors');
fprintf('    PASS (baseline runs, final pos err = %.3f m)\n', posErr(end));

% ----------------------------------------------------------------
% T-P9b/c: includeTowerClocksInEKF + free → error containing 'unobservable' or 'gauge'
% ----------------------------------------------------------------
fprintf('  T-P9b/c: includeTowerClocksInEKF + gauge=free → error ...\n');
cfg_free = revgnss.ConfigFactory.defaultConfig();
cfg_free.clock.mode       = 'includeTowerClocksInEKF';
cfg_free.clock.gauge.mode = 'free';

threw_free = false;
errMsg_free = '';
try
    revgnss.ConfigFactory.finalizeConfig(cfg_free);
catch ME
    threw_free = true;
    errMsg_free = ME.message;
end
assert(threw_free, 'T-P9b FAILED: expected error for includeTowerClocksInEKF + free');
hasUnobs  = contains(lower(errMsg_free), 'unobservable');
hasGauge  = contains(lower(errMsg_free), 'gauge');
assert(hasUnobs || hasGauge, ...
    sprintf('T-P9c FAILED: error message missing ''unobservable''/''gauge'': %s', errMsg_free));
fprintf('    PASS (error thrown: %s)\n', errMsg_free(1:min(80,end)));

% ----------------------------------------------------------------
% T-P9d/e/i: fixReferenceTower → gauge rows >= 1, rank finite, residuals finite
% ----------------------------------------------------------------
fprintf('  T-P9d: fixReferenceTower → gauge rows added >= 1 ...\n');
cfg_fix = revgnss.ConfigFactory.defaultConfig();
cfg_fix.clock.mode                    = 'includeTowerClocksInEKF';
cfg_fix.clock.gauge.mode              = 'fixReferenceTower';
cfg_fix.clock.gauge.referenceTowerIndex = 1;
cfg_fix.clock.gauge.sigmaBias_m       = 1e-4;   % larger sigma for numerical stability
cfg_fix.clock.gauge.sigmaDrift_mps    = 1e-7;
cfg_fix.scenario.nTowers              = nT;
cfg_fix.scenario.nReceivers           = 1;
cfg_fix.simulation.duration_s         = dur;
cfg_fix.simulation.dt_s               = 1;
cfg_fix.plots.enable  = false;
cfg_fix.report.enable = false;
cfg_fix.errors.codeNoise.sigma_m      = 0;

sim_fix = revgnss.ReverseGNSSSimulation(cfg_fix);
sim_fix.run();

gaugeRows_fix = sim_fix.diag.getClockGaugeRowsAdded();
gaugePos      = gaugeRows_fix(gaugeRows_fix > 0);
assert(~isempty(gaugePos), ...
    'T-P9d FAILED: getClockGaugeRowsAdded() returned all zeros for fixReferenceTower');
fprintf('    PASS (gauge rows added: %d per update epoch)\n', gaugePos(1));

fprintf('  T-P9e: fixReferenceTower → clock subspace rank finite ...\n');
clkRank_fix = sim_fix.diag.getClockSubspaceRank();
validRank   = clkRank_fix(isfinite(clkRank_fix) & clkRank_fix > 0);
assert(~isempty(validRank), ...
    'T-P9e FAILED: clock subspace rank is all NaN/0 for fixReferenceTower');
fprintf('    Median clock subspace rank: %d\n', median(validRank));
fprintf('    PASS\n');

fprintf('  T-P9i: fixReferenceTower → gauge bias residuals finite ...\n');
biasRes = sim_fix.diag.getClockGaugeBiasResiduals();
finiteRes = biasRes(isfinite(biasRes));
assert(~isempty(finiteRes), ...
    'T-P9i FAILED: clock gauge bias residuals all NaN for fixReferenceTower');
fprintf('    Median bias residual: %.2e m\n', median(abs(finiteRes)));
fprintf('    PASS\n');

% ----------------------------------------------------------------
% T-P9f/g: meanGroundClockGauge → gauge rows >= 1, rank finite
% ----------------------------------------------------------------
fprintf('  T-P9f: meanGroundClockGauge → gauge rows added >= 1 ...\n');
cfg_mean = revgnss.ConfigFactory.defaultConfig();
cfg_mean.clock.mode               = 'includeTowerClocksInEKF';
cfg_mean.clock.gauge.mode         = 'meanGroundClockGauge';
cfg_mean.clock.gauge.sigmaBias_m  = 1e-4;
cfg_mean.clock.gauge.sigmaDrift_mps = 1e-7;
cfg_mean.scenario.nTowers         = nT;
cfg_mean.scenario.nReceivers      = 1;
cfg_mean.simulation.duration_s    = dur;
cfg_mean.simulation.dt_s          = 1;
cfg_mean.plots.enable  = false;
cfg_mean.report.enable = false;
cfg_mean.errors.codeNoise.sigma_m = 0;

sim_mean = revgnss.ReverseGNSSSimulation(cfg_mean);
sim_mean.run();

gaugeRows_mean = sim_mean.diag.getClockGaugeRowsAdded();
gaugePosM      = gaugeRows_mean(gaugeRows_mean > 0);
assert(~isempty(gaugePosM), ...
    'T-P9f FAILED: getClockGaugeRowsAdded() returned all zeros for meanGroundClockGauge');
fprintf('    PASS (gauge rows added: %d per update epoch)\n', gaugePosM(1));

fprintf('  T-P9g: meanGroundClockGauge → clock subspace rank finite ...\n');
clkRank_mean = sim_mean.diag.getClockSubspaceRank();
validRankM   = clkRank_mean(isfinite(clkRank_mean) & clkRank_mean > 0);
assert(~isempty(validRankM), ...
    'T-P9g FAILED: clock subspace rank is all NaN/0 for meanGroundClockGauge');
fprintf('    Median clock subspace rank: %d\n', median(validRankM));
fprintf('    PASS\n');

% ----------------------------------------------------------------
% T-P9h: gauge rows NOT counted in getNumMeasurements() (physical pseudorange count)
% ----------------------------------------------------------------
fprintf('  T-P9h: gauge rows not counted in pseudorange count ...\n');
% Compare pseudorange count (code-only) for fixReferenceTower vs baseline.
% Both should have the same number of pseudorange measurements per epoch.
nMeas_base = sim_base.diag.getNumMeasurements();
nMeas_fix  = sim_fix.diag.getNumMeasurements();
% At same nTowers and same epoch count, pseudorange counts should match
assert(max(nMeas_fix) == max(nMeas_base), ...
    sprintf('T-P9h FAILED: pseudorange counts differ: base=%d, fix=%d', ...
        max(nMeas_base), max(nMeas_fix)));
fprintf('    PASS (max pseudorange count: base=%d, fix=%d — identical)\n', ...
    max(nMeas_base), max(nMeas_fix));

% ----------------------------------------------------------------
% T-P9j: defaultConfig has gauge sigma and referenceTowerIndex fields
% ----------------------------------------------------------------
fprintf('  T-P9j: defaultConfig has gauge sigma fields ...\n');
cfg_def = revgnss.ConfigFactory.defaultConfig();
assert(isfield(cfg_def.clock.gauge,'sigmaBias_m'), ...
    'T-P9j FAILED: missing cfg.clock.gauge.sigmaBias_m in defaultConfig');
assert(isfield(cfg_def.clock.gauge,'sigmaDrift_mps'), ...
    'T-P9j FAILED: missing cfg.clock.gauge.sigmaDrift_mps in defaultConfig');
assert(isfield(cfg_def.clock.gauge,'referenceTowerIndex'), ...
    'T-P9j FAILED: missing cfg.clock.gauge.referenceTowerIndex in defaultConfig');
assert(cfg_def.clock.gauge.referenceTowerIndex == 1, ...
    'T-P9j FAILED: default referenceTowerIndex should be 1');
fprintf('    sigmaBias_m = %g m, sigmaDrift_mps = %g m/s, referenceTowerIndex = %d\n', ...
    cfg_def.clock.gauge.sigmaBias_m, cfg_def.clock.gauge.sigmaDrift_mps, ...
    cfg_def.clock.gauge.referenceTowerIndex);
fprintf('    PASS\n');

fprintf('=== test_stage9_clock_gauge_ekf: ALL PASS ===\n');
