% test_stage10_clock_observability_gramian  Stage 10 windowed clock observability tests.
%
% T-P10a: spacecraftReceiverClockOnly → physical rank >=1 once window fills
% T-P10b: includeTowerClocksInEKF + fixReferenceTower → physical rank < gauged rank
%         (physical nullspace confirmed, gauge removes it)
% T-P10c: gauged rank equals n_clk (full) after window fills
% T-P10d: gauged weak states = 0 (all clock states observable under gauge)
% T-P10e: physical weak states >= 1 (common bias nullspace exists without gauge)
% T-P10f: condition number improves from physical to gauged (condGauged < condPhysical)
% T-P10g: defaultConfig has required clockObservability fields
% T-P10h: Gramian returns NaN before minWindowEpochs epochs (short run check)

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_stage10_clock_observability_gramian ===\n');

nT  = 5;   % 5 towers so EKF updates run (>= 4 meas/epoch)
dur = 30;
dt  = 1;

% ----------------------------------------------------------------
% T-P10g: defaultConfig has required clockObservability fields
% ----------------------------------------------------------------
fprintf('  T-P10g: defaultConfig has clockObservability fields ...\n');
cfg_def = revgnss.ConfigFactory.defaultConfig();
assert(isfield(cfg_def,'diagnostics'), 'T-P10g FAILED: missing cfg.diagnostics');
assert(isfield(cfg_def.diagnostics,'clockObservability'), ...
    'T-P10g FAILED: missing cfg.diagnostics.clockObservability');
co = cfg_def.diagnostics.clockObservability;
assert(isfield(co,'enable'),             'T-P10g FAILED: missing .enable');
assert(isfield(co,'windowLengthEpochs'),'T-P10g FAILED: missing .windowLengthEpochs');
assert(isfield(co,'minWindowEpochs'),   'T-P10g FAILED: missing .minWindowEpochs');
assert(isfield(co,'rankTolerance'),     'T-P10g FAILED: missing .rankTolerance');
assert(co.enable == true,               'T-P10g FAILED: enable should default to true');
assert(co.windowLengthEpochs == 60,     'T-P10g FAILED: windowLengthEpochs should be 60');
assert(co.minWindowEpochs == 5,         'T-P10g FAILED: minWindowEpochs should be 5');
fprintf('    PASS (enable=%d, window=%d, minWin=%d)\n', ...
    co.enable, co.windowLengthEpochs, co.minWindowEpochs);

% ----------------------------------------------------------------
% T-P10h: NaN before minWindowEpochs filled (use minWindowEpochs=20, run only 3 epochs)
% ----------------------------------------------------------------
fprintf('  T-P10h: Gramian returns NaN before minWindowEpochs filled ...\n');
cfg_short = revgnss.ConfigFactory.defaultConfig();
cfg_short.scenario.nTowers              = nT;
cfg_short.scenario.nReceivers           = 1;
cfg_short.simulation.duration_s         = 3;   % 3 epochs only
cfg_short.simulation.dt_s               = 1;
cfg_short.plots.enable  = false;
cfg_short.report.enable = false;
cfg_short.errors.codeNoise.sigma_m      = 0;
cfg_short.diagnostics.clockObservability.minWindowEpochs = 20;  % require 20

sim_short = revgnss.ReverseGNSSSimulation(cfg_short);
sim_short.run();
rk_short = sim_short.diag.getClockObsRankPhysical();
assert(all(isnan(rk_short)), ...
    sprintf('T-P10h FAILED: expected all NaN before minWindowEpochs filled, got %s', ...
        mat2str(rk_short(:)')));
fprintf('    PASS (all NaN when run < minWindowEpochs: %s)\n', mat2str(isnan(rk_short)'));

% ----------------------------------------------------------------
% Shared config for T-P10a / T-P10b-f: build base and tower-clock configs
% ----------------------------------------------------------------

% T-P10a: spacecraft-clock-only
cfg_a = revgnss.ConfigFactory.defaultConfig();
cfg_a.scenario.nTowers              = nT;
cfg_a.scenario.nReceivers           = 1;
cfg_a.simulation.duration_s         = dur;
cfg_a.simulation.dt_s               = dt;
cfg_a.plots.enable  = false;
cfg_a.report.enable = false;
cfg_a.errors.codeNoise.sigma_m      = 0;
cfg_a.diagnostics.clockObservability.minWindowEpochs = 3;

% T-P10b-f: includeTowerClocksInEKF + fixReferenceTower
cfg_b = revgnss.ConfigFactory.defaultConfig();
cfg_b.clock.mode                          = 'includeTowerClocksInEKF';
cfg_b.clock.gauge.mode                    = 'fixReferenceTower';
cfg_b.clock.gauge.referenceTowerIndex     = 1;
cfg_b.clock.gauge.sigmaBias_m             = 1e-2;
cfg_b.clock.gauge.sigmaDrift_mps          = 1e-4;
cfg_b.scenario.nTowers                    = nT;
cfg_b.scenario.nReceivers                 = 1;
cfg_b.simulation.duration_s               = dur;
cfg_b.simulation.dt_s                     = dt;
cfg_b.plots.enable  = false;
cfg_b.report.enable = false;
cfg_b.errors.codeNoise.sigma_m            = 0;
cfg_b.diagnostics.clockObservability.minWindowEpochs = 3;

% Run both simulations
sim_a = revgnss.ReverseGNSSSimulation(cfg_a);
sim_a.run();

sim_b = revgnss.ReverseGNSSSimulation(cfg_b);
sim_b.run();

% ----------------------------------------------------------------
% T-P10a: spacecraft-clock-only → physical rank >= 1 once window fills
% ----------------------------------------------------------------
fprintf('  T-P10a: spacecraftReceiverClockOnly → physical rank >= 1 ...\n');
rkPhy_a = sim_a.diag.getClockObsRankPhysical();
fin_a   = rkPhy_a(isfinite(rkPhy_a));
assert(~isempty(fin_a), 'T-P10a FAILED: all NaN for spacecraftReceiverClockOnly');
assert(median(fin_a) >= 1, ...
    sprintf('T-P10a FAILED: physical rank %.1f < 1', median(fin_a)));
fprintf('    PASS (median physical rank = %.0f)\n', median(fin_a));

% ----------------------------------------------------------------
% T-P10b: physical rank < gauged rank (nullspace exists, gauge removes it)
% ----------------------------------------------------------------
fprintf('  T-P10b: physical rank < gauged rank for fixReferenceTower ...\n');
rkPhy_b  = sim_b.diag.getClockObsRankPhysical();
rkGau_b  = sim_b.diag.getClockObsRankGauged();
fin_phy  = rkPhy_b(isfinite(rkPhy_b));
fin_gau  = rkGau_b(isfinite(rkGau_b));
assert(~isempty(fin_phy) && ~isempty(fin_gau), ...
    'T-P10b FAILED: Gramian not computed for fixReferenceTower');
mRkPhy = median(fin_phy);
mRkGau = median(fin_gau);
assert(mRkPhy < mRkGau, ...
    sprintf('T-P10b FAILED: physical rank %g NOT less than gauged rank %g', mRkPhy, mRkGau));
fprintf('    PASS (median physical=%g, gauged=%g)\n', mRkPhy, mRkGau);

% ----------------------------------------------------------------
% T-P10c: gauged rank equals n_clk = 2 + 2*nT (rx_bias, rx_drift, nT*[bias,drift])
%         and physical rank equals n_clk - 2 (two persistent null modes)
% ----------------------------------------------------------------
fprintf('  T-P10c: gauged rank = n_clk, physical rank = n_clk - 2 ...\n');
n_clk_expected = 2 + 2 * nT;   % 2 rx + 2 per tower
assert(round(mRkGau) == n_clk_expected, ...
    sprintf('T-P10c FAILED: gauged rank %g, expected n_clk=%d', mRkGau, n_clk_expected));
assert(round(mRkPhy) == n_clk_expected - 2, ...
    sprintf('T-P10c FAILED: physical rank %g, expected n_clk-2=%d', mRkPhy, n_clk_expected-2));
fprintf('    PASS (gauged rank = n_clk = %d, physical rank = n_clk-2 = %d)\n', ...
    n_clk_expected, n_clk_expected-2);

% ----------------------------------------------------------------
% T-P10d: gauged weak states = 0
% ----------------------------------------------------------------
fprintf('  T-P10d: gauged weak states = 0 ...\n');
wkGau_b = sim_b.diag.getClockObsWeakStatesGauged();
fin_wg  = wkGau_b(isfinite(wkGau_b));
assert(~isempty(fin_wg), 'T-P10d FAILED: all NaN weak gauged states');
assert(median(fin_wg) == 0, ...
    sprintf('T-P10d FAILED: median gauged weak states = %g (expected 0)', median(fin_wg)));
fprintf('    PASS (median gauged weak states = 0)\n');

% ----------------------------------------------------------------
% T-P10e: physical weak states >= 2 (two common nullspace modes)
%
% One-way pseudorange with receiver + tower clocks is insensitive to
% (a) a common bias shift: adding the same constant to all clock biases
% (b) a common drift shift: adding the same constant to all clock drifts
% Both modes persist for all epochs.  Physical rank = n_clk - 2 = 10.
% ----------------------------------------------------------------
fprintf('  T-P10e: physical weak states >= 2 (bias + drift null modes) ...\n');
wkPhy_b = sim_b.diag.getClockObsWeakStatesPhysical();
fin_wp  = wkPhy_b(isfinite(wkPhy_b));
assert(~isempty(fin_wp), 'T-P10e FAILED: all NaN weak physical states');
assert(median(fin_wp) >= 2, ...
    sprintf('T-P10e FAILED: median physical weak states = %g (expected >= 2)', median(fin_wp)));
fprintf('    PASS (median physical weak states = %.0f)\n', median(fin_wp));

% ----------------------------------------------------------------
% T-P10f: gauge removes exactly 2 null modes (bias AND drift common modes)
%
% fixReferenceTower pins both b_twr_ref (bias) and bdot_twr_ref (drift)
% to zero.  This removes both the common-bias null vector [1,0,1,0,...] and
% the common-drift null vector [0,1,0,1,...], so rank delta must be 2.
% ----------------------------------------------------------------
fprintf('  T-P10f: gauge rank delta = 2 (bias + drift null modes removed) ...\n');
rankDelta_b = rkGau_b - rkPhy_b;
fin_rd      = rankDelta_b(isfinite(rankDelta_b) & isfinite(rkPhy_b));
assert(~isempty(fin_rd), 'T-P10f FAILED: no finite rank delta values');
assert(median(fin_rd) == 2, ...
    sprintf('T-P10f FAILED: median rank delta = %g, expected exactly 2 (bias + drift null modes)', ...
        median(fin_rd)));
fprintf('    PASS (median rank delta = 2 — common-bias and common-drift null modes removed)\n');

fprintf('=== test_stage10_clock_observability_gramian: ALL PASS ===\n');
