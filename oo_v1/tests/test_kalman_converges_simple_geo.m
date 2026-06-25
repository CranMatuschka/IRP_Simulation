% test_kalman_converges_simple_geo  Verify EKF position error decreases.
%
% Default GEO-1 scenario: deterministic clocks, no atmosphere, code noise 0.3 m.
% Pass criteria:
%   1. Final position error < initial position error.
%   2. RMS over last 20% of run < initial position error.
%
% This is a minimal convergence test, not a precise accuracy benchmark.
% Attitude is weakly observable from pseudorange; focus is position + clock.

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_kalman_converges_simple_geo ===\n');

cfg = revgnss.ConfigFactory.defaultConfig();
cfg.simulation.duration_s = 1800;   % 30 min is enough to show convergence
cfg.simulation.dt_s       = 1.0;
cfg.plots.enable          = false;
cfg.report.enable         = false;

sim = revgnss.ReverseGNSSSimulation(cfg);
sim.initialize();
sim.run();

posErr = sim.diag.getPositionErrors();
initErr = posErr(1);
finalErr = posErr(end);

% RMS over last 20%
idx20  = max(1, round(0.8 * numel(posErr)));
rmsLast20 = rms(posErr(idx20:end));

fprintf('  Initial position error : %.2f m\n',  initErr);
fprintf('  Final position error   : %.2f m\n',  finalErr);
fprintf('  RMS (last 20%%)        : %.2f m\n',  rmsLast20);

assert(finalErr < initErr, ...
    'test_kalman_converges_simple_geo FAILED: final error %.2f m >= initial %.2f m', ...
    finalErr, initErr);

% Expect last-20% RMS is at most half the initial error
MAX_RMS_LAST20 = initErr * 0.5;
assert(rmsLast20 < MAX_RMS_LAST20, ...
    'test_kalman_converges_simple_geo FAILED: last-20%% RMS %.2f m >= threshold %.2f m', ...
    rmsLast20, MAX_RMS_LAST20);

fprintf('  PASS\n');
