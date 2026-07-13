% test_mc_consistency_harness
% WP-5: ensemble NEES/NIS filter-consistency harness. Verifies the harness runs an
% ensemble (initial error drawn from P0; measurement + clock-truth seeds varied per
% draw), is deterministic, computes valid two-sided chi-squared bounds, correctly flags
% the conservative-by-design default as BELOW band (not over-confident), and has
% discriminating power (pooled NIS/dof rises strongly when the prior is made
% over-confident). The default single-run path is untouched (byte-identical golden).

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));
addpath(fullfile(thisDir, '..', 'config'));

fprintf('=== test_mc_consistency_harness ===\n');

base = revgnss.ConfigFactory.matchedErrorBaselineConfig();
base.simulation.duration_s = 150; base.simulation.dt_s = 1;
opts = struct('nSeeds',8,'confidence',0.99,'burnInFraction',0.5,'baseSeed',3000,'initErrorScale',1);

% 1) Well-formed ensemble; the conservative-by-design default is flagged BELOW band ----
mc = revgnss.MonteCarloConsistency.run(base, opts);
assert(mc.nUsed == opts.nSeeds, 'all seeds must run (nUsed=%d)', mc.nUsed);
assert(isfinite(mc.nisPerDof) && mc.nisPerDof > 0, 'nisPerDof must be finite positive');
assert(numel(mc.nisBand)==2 && mc.nisBand(1) < mc.nisBand(2), 'band must be a valid interval');
assert(isfinite(mc.neesPerDof), 'neesPerDof must be finite');
assert(mc.nisBelowBand && ~mc.nisAboveBand, ...
    'conservative default must be flagged BELOW band (NIS/dof=%.3f)', mc.nisPerDof);
fprintf('  baseline: NIS/dof=%.3f (below band [%.0f,%.0f]); NEES/dof=%.3f\n', ...
    mc.nisPerDof, mc.nisBand(1), mc.nisBand(2), mc.neesPerDof);

% 2) Determinism: identical opts -> identical pooled sum -----------------------------
mc2 = revgnss.MonteCarloConsistency.run(base, opts);
assert(abs(mc2.nisSum - mc.nisSum) <= 1e-9*max(1,abs(mc.nisSum)), ...
    'harness must be deterministic (dSum=%.3e)', abs(mc2.nisSum - mc.nisSum));

% 3) Discriminating power: an over-confident prior (init error >> P0, no burn-in) raises
%    the pooled NIS/dof strongly -> the harness detects the injected inconsistency. -----
optBad = opts; optBad.initErrorScale = 8; optBad.burnInFraction = 0;
mcBad = revgnss.MonteCarloConsistency.run(base, optBad);
assert(mcBad.nisPerDof > 5 * mc.nisPerDof, ...
    'over-confident prior must raise NIS/dof >5x (%.3f vs %.3f)', mcBad.nisPerDof, mc.nisPerDof);
fprintf('  power: over-confident-prior NIS/dof=%.3f (%.1fx baseline)\n', ...
    mcBad.nisPerDof, mcBad.nisPerDof / mc.nisPerDof);

% 4) Default single-run path untouched (harness never runs on the shipped default) ----
cfg = masterConfig();
cfg.report.writePdf = false; cfg.report.writeMat = false;
cfg.report.compileTex = 'never'; cfg.plots.showFigures = false;
cfgR = revgnss.ConfigFactory.finalizeConfig(cfg);
assert(~cfgR.validation.statistics.monteCarlo.enable, ...
    'monteCarlo.enable must remain false by default.');
assert(~isfield(cfg.simulation, 'mcSeedOffset'), ...
    'masterConfig must not set mcSeedOffset (default clock seeds unchanged).');
fprintf('  determinism exact; default path monteCarlo.enable=false, mcSeedOffset unset\n');

fprintf('  PASS\n');
