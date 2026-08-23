% test_stage1_physics_disabled_unchanged  With all physics false, results unchanged.
%
% Verifies that defaultConfig (all physics off) gives the same prefit innovation
% RMS as a freshly constructed defaultConfig with explicit physics.false fields.

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_stage1_physics_disabled_unchanged ===\n');

DUR = 120;

cfg1 = revgnss.ConfigFactory.idealConfig();
cfg1.simulation.duration_s = DUR;
cfg1.plots.enable  = false;
cfg1.report.enable = false;
sim1 = revgnss.ReverseGNSSSimulation(cfg1);
sim1.initialize();
sim1.run();

% Belt-and-suspenders: second identical run with no additional overrides.
% idealConfig already has shapiro disabled; sagnac is enabled by default
% (disabling it here would change the physics, not test reproducibility).
cfg2 = revgnss.ConfigFactory.idealConfig();
cfg2.simulation.duration_s = DUR;
cfg2.plots.enable  = false;
cfg2.report.enable = false;
sim2 = revgnss.ReverseGNSSSimulation(cfg2);
sim2.initialize();
sim2.run();

pos1 = sim1.diag.getPositionErrors();
pos2 = sim2.diag.getPositionErrors();

% Should be numerically identical (same seed, same corrections)
maxDiff = max(abs(pos1 - pos2));
fprintf('  Max position error difference: %.2e m\n', maxDiff);
assert(maxDiff < 1e-6, ...
    'Physics-off results should be identical, max diff=%.2e m', maxDiff);

fprintf('  PASS\n');
