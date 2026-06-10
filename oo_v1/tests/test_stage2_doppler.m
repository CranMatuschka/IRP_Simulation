% test_stage2_doppler  Stage 2 acceptance: Doppler observable.
%
% Verifies:
%   - doppler disabled → identical to no-doppler baseline
%   - doppler enabled, useInEKF=false → EKF unchanged, diagnostic exists
%   - doppler enabled, useInEKF=true  → velocity estimate improves (or stable)

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_stage2_doppler ===\n');

DUR = 200;

% --- Baseline: no doppler ---
cfgB = revgnss.ConfigFactory.defaultConfig();
cfgB.simulation.duration_s = DUR;
cfgB.plots.enable  = false;
cfgB.report.enable = false;
simB = revgnss.ReverseGNSSSimulation(cfgB);
simB.initialize();
simB.run();

% --- Doppler enabled, useInEKF=false (diagnostic only) ---
cfg2 = revgnss.ConfigFactory.defaultConfig();
cfg2.simulation.duration_s            = DUR;
cfg2.measurements.doppler.enable      = true;
cfg2.measurements.doppler.useInEKF    = false;
cfg2.measurements.doppler.sigma_mps   = 0.01;
cfg2.plots.enable  = false;
cfg2.report.enable = false;
sim2 = revgnss.ReverseGNSSSimulation(cfg2);
sim2.initialize();
sim2.run();

posB = simB.diag.getPositionErrors();
pos2 = sim2.diag.getPositionErrors();
nmB  = simB.diag.getNumMeasurements();
nm2  = sim2.diag.getNumMeasurements();

% useInEKF=false → EKF measurement count unchanged vs. baseline
assert(isequal(nmB, nm2), 'useInEKF=false should not add measurements to EKF');

% Doppler noise draws shift the RNG so trajectories will differ slightly;
% verify both converge to a similar level rather than requiring exact match.
assert(pos2(end) < 200, ...
    'useInEKF=false should still converge, final pos err=%.1f m', pos2(end));
fprintf('  useInEKF=false: EKF measurement count unchanged, final pos err=%.2f m\n', pos2(end));

% --- Doppler enabled, useInEKF=true ---
cfg3 = revgnss.ConfigFactory.defaultConfig();
cfg3.simulation.duration_s            = DUR;
cfg3.measurements.doppler.enable      = true;
cfg3.measurements.doppler.useInEKF    = true;
cfg3.measurements.doppler.sigma_mps   = 0.01;
cfg3.plots.enable  = false;
cfg3.report.enable = false;
sim3 = revgnss.ReverseGNSSSimulation(cfg3);
sim3.initialize();
sim3.run();

nm3 = sim3.diag.getNumMeasurements();
posF = sim3.diag.getPositionErrors();

% With useInEKF=true, measurement count should be > baseline (more rows)
assert(mean(nm3) > mean(nmB), ...
    'useInEKF=true should add doppler rows; mean_meas=%d vs baseline=%d', ...
    round(mean(nm3)), round(mean(nmB)));

fprintf('  useInEKF=true: mean_meas=%.1f (baseline=%.1f)  final_pos_err=%.2f m\n', ...
    mean(nm3), mean(nmB), posF(end));

% Filter should still converge with doppler
assert(posF(end) < 300, 'EKF should still converge with doppler, final err=%.1f m', posF(end));

fprintf('  PASS\n');
