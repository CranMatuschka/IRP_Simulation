% test_default_geo_visibility  Verify >= 4 towers visible for most epochs.
%
% GEO-1 at lon 23 deg is well placed to see all 5 towers (Africa/Europe).
% Pass criterion: >= 4 towers visible in at least 90% of epochs.

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_default_geo_visibility ===\n');

cfg = revgnss.ConfigFactory.defaultConfig();
cfg.simulation.duration_s = 300;   % short run for speed
cfg.plots.enable          = false;
cfg.report.enable         = false;

sim = revgnss.ReverseGNSSSimulation(cfg);
sim.initialize();
sim.run();

nVis    = sim.diag.getNumVisibleTowers();
nEpochs = numel(nVis);

fracAbove4 = mean(nVis >= 4);
fprintf('  Mean visible towers : %.2f\n', mean(nVis));
fprintf('  Fraction >= 4 towers: %.1f%%\n', fracAbove4 * 100);

assert(fracAbove4 >= 0.9, ...
    'test_default_geo_visibility FAILED: only %.1f%% epochs have >= 4 towers', ...
    fracAbove4 * 100);

fprintf('  PASS\n');
