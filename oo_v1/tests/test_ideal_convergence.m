% test_ideal_convergence  Verify EKF converges under ideal (no-noise) conditions.
%
% Pass criterion: final position error < 500 m after 300 s.
% (Threshold is generous because attitude is included and initial uncertainty
%  is large; tighter thresholds should be set once tuning is done.)

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_ideal_convergence ===\n');

cfg = revgnss.ConfigFactory.idealConfig();
cfg.simulation.duration_s = 300;
cfg.simulation.dt_s       = 1.0;
cfg.plots.enable          = false;

sim = revgnss.ReverseGNSSSimulation(cfg);
sim.initialize();
sim.run();

posErr = sim.diag.getPositionErrors();
finalErr = posErr(end);

THRESHOLD_M = 500;
fprintf('  Final position error: %.2f m  (threshold: %d m)\n', finalErr, THRESHOLD_M);

assert(finalErr < THRESHOLD_M, ...
    'test_ideal_convergence FAILED: final pos error %.2f m > %d m threshold', ...
    finalErr, THRESHOLD_M);

fprintf('  PASS\n');
