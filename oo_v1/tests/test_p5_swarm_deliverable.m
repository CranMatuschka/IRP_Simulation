% test_p5_swarm_deliverable
%
% P5' per-satellite deliverable: (1) revgnss.SwarmEstimateSummary turns the persisted
% per-secondary estimate diagnostics into the per-satellite table (abs error, sigma,
% +/-3-sigma coverage, relative baseline error, NEES); (2) the store records the relative
% baseline error; (3) plot_mat_report grows a "Swarm estimate" tab for swarm runs.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir, '..');
addpath(rootDir); addpath(fullfile(rootDir, 'config'));

fprintf('=== test_p5_swarm_deliverable ===\n');

% ---------------------------------------------------------------------
% T1: SwarmEstimateSummary.compute on a synthetic diagnostics struct
% ---------------------------------------------------------------------
fprintf('  T1: SwarmEstimateSummary.compute (synthetic) ...\n');
nSec = 2; nEp = 10;
d = struct();
d.secondaryOrbit.posError_m      = [5*ones(1,nEp); 10*ones(1,nEp)];   % [nSec x nEp]
d.secondaryOrbit.posSigma_m      = [2*ones(1,nEp);  2*ones(1,nEp)];   % 3sigma = 6 m
d.secondaryOrbit.baselineError_m = [1*ones(1,nEp); -2*ones(1,nEp)];
d.secondaryOrbit.neesPos         = [4*ones(1,nEp);  9*ones(1,nEp)];
d.consistency.centroidNEES       = 100*ones(1,nEp);
s = revgnss.SwarmEstimateSummary.compute(d, 0.5);
assert(s.available && s.nSecondaries == 2, 'T1 FAILED: not available/2 secondaries');
assert(s.perSat(1).index == 2 && s.perSat(2).index == 3, 'T1 FAILED: asset indices');
assert(abs(s.perSat(1).absErrRms_m - 5) < 1e-9 && abs(s.perSat(2).absErrRms_m - 10) < 1e-9, 'T1 FAILED: abs RMS');
assert(abs(s.perSat(1).coverage3sigma - 1) < 1e-9, 'T1 FAILED: sat1 should be 100%% covered (5<=6)');
assert(abs(s.perSat(2).coverage3sigma - 0) < 1e-9, 'T1 FAILED: sat2 should be 0%% covered (10>6)');
assert(abs(s.perSat(1).baselineErrRms_m - 1) < 1e-9 && abs(s.perSat(2).baselineErrRms_m - 2) < 1e-9, 'T1 FAILED: baseline RMS');
assert(abs(s.perSat(1).neesPosMean - 4) < 1e-9, 'T1 FAILED: NEES mean');
assert(abs(s.centroidNeesMean - 100) < 1e-9, 'T1 FAILED: centroid NEES mean');
lines = revgnss.SwarmEstimateSummary.format(s);
assert(iscell(lines) && numel(lines) >= 4, 'T1 FAILED: format did not produce a table');
% empty / single-asset diagnostics -> not available
assert(~revgnss.SwarmEstimateSummary.compute(struct()).available, 'T1 FAILED: empty d marked available');
fprintf('    PASS\n');

% ---------------------------------------------------------------------
% T2: real honest swarm run -> store records baselineError_m; summary computes
% ---------------------------------------------------------------------
fprintf('  T2: store records relative baseline error; summary on real data ...\n');
cfg = i_honestSwarm(3, 300);
sim = revgnss.ReverseGNSSSimulation(revgnss.ConfigFactory.finalizeConfig(cfg));
sim.initialize(); sim.run();
dr = sim.simData.getData();
assert(isfield(dr,'secondaryOrbit') && isfield(dr.secondaryOrbit,'baselineError_m'), 'T2 FAILED: no baselineError_m');
assert(any(isfinite(dr.secondaryOrbit.baselineError_m(:))), 'T2 FAILED: baselineError_m all NaN');
sr = revgnss.SwarmEstimateSummary.compute(dr);
assert(sr.available && sr.nSecondaries == 2, 'T2 FAILED: summary not available/2');
assert(all(isfinite([sr.perSat.absErrRms_m])), 'T2 FAILED: abs err not finite');
assert(all(isfinite([sr.perSat.baselineErrRms_m])), 'T2 FAILED: baseline err not finite');
fprintf('    per-sat abs RMS = [%.2f %.2f] m, baseline RMS = [%.2f %.2f] m\n', ...
    sr.perSat(1).absErrRms_m, sr.perSat(2).absErrRms_m, sr.perSat(1).baselineErrRms_m, sr.perSat(2).baselineErrRms_m);
fprintf('    PASS\n');

% ---------------------------------------------------------------------
% T3: plot_mat_report grows a "Swarm estimate" tab for a saved swarm .mat
% ---------------------------------------------------------------------
fprintf('  T3: viewer "Swarm estimate" tab ...\n');
tmp = fullfile(tempdir, 'p5_swarm_matcheck'); if ~isfolder(tmp); mkdir(tmp); end
cfgV = i_honestSwarm(3, 120);
cfgV.report.reportFolder = tmp; cfgV.report.writeMat = true; cfgV.report.writePdf = false; cfgV.report.compileTex = 'never';
outV = revgnss.ReportRunner.runSingle(cfgV);
assert(isfile(outV.matPath), 'T3 FAILED: swarm .mat not written');
fig = plot_mat_report(outV.matPath);
titles = get(findobj(fig, 'type', 'uitab'), 'Title');
if ischar(titles); titles = {titles}; end
assert(any(strcmp(titles, 'Swarm estimate')), 'T3 FAILED: no "Swarm estimate" tab built');
close(fig);
fprintf('    PASS (tabs: %s)\n', strjoin(titles, ', '));

fprintf('=== test_p5_swarm_deliverable: ALL PASS ===\n');

% =====================================================================
function cfg = i_honestSwarm(nA, dur)
    cfg = masterConfig();
    cfg.scenario.nSpaceAssets = nA; cfg.scenario.nReceivers = 1; cfg.scenario.nTowers = 5;
    cfg.multiAsset.mode = 'honest';
    cfg = revgnss.ConfigFactory.applyMultiAssetMode(cfg);   % estimateMode='position', product off
    cfg.asset.clock.deterministic = false;
    cfg.simulation.duration_s = dur;
    cfg.report.writePdf = false; cfg.report.writeMat = false; cfg.report.compileTex = 'never';
    cfg.plots.showFigures = false; cfg.plots.enable = false;
end
