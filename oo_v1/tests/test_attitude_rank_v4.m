% test_attitude_rank_v4  Attitude observability must use SVD rank (Issue 8).
%
% T8a: attitudeRank == 3 for multi-antenna geometry (full observability).
% T8b: attitudeRank == 0 for single-antenna zero lever arm (unobservable).
%
% CHANGED: v3→v4 — Issue 8
% Using only max singular value cannot distinguish partial (1-2 axis)
% from full 3-axis sensitivity.  Use SVD rank with relative tolerance.

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_attitude_rank_v4 ===\n');

% ----------------------------------------------------------------
% T8a: Multi-antenna cross pattern → full 3-axis attitude sensitivity
% ----------------------------------------------------------------
fprintf('  T8a: multi-antenna attitude rank == 3 ...\n');

cfg_multi = revgnss.ConfigFactory.multiAntennaAttitudeConfig();
cfg_multi.simulation.duration_s = 60;
cfg_multi.plots.enable  = false;
cfg_multi.report.enable = false;
% Heavy per-epoch diagnostics (SVD attitude rank) default to a 300s cadence
% (config/baseConfig.m cfg.data.heavyDiagnosticsInterval_s); force every-epoch
% computation so this short 60s run has a populated attitudeRank at the final
% epoch (data.SimulationDataStore.parseHeavyDiagCfg_ / recordEpoch heavyDiag_ gate).
cfg_multi.data.computeHeavyDiagnosticsEveryEpoch = true;

sim_multi = revgnss.ReverseGNSSSimulation(cfg_multi);
sim_multi.initialize();
sim_multi.run();

attRanks = sim_multi.diag.getAttitudeRank();

% Check final epoch (after convergence)
N = numel(attRanks);
finalRank   = attRanks(N);

fprintf('    Final epoch attitudeRank = %d\n', finalRank);
assert(finalRank == 3, ...
    'T8a FAILED: multiAntennaAttitudeConfig should give attitudeRank=3 (got %d)', finalRank);
fprintf('    PASS\n');

% ----------------------------------------------------------------
% T8b: Single antenna, zero lever arm → attitude unobservable (rank 0)
% ----------------------------------------------------------------
fprintf('  T8b: single-antenna zero lever arm → attitudeRank == 0 ...\n');

cfg_single = revgnss.ConfigFactory.noLeverArmConfig();
cfg_single.simulation.duration_s = 60;
cfg_single.plots.enable  = false;
cfg_single.report.enable = false;
cfg_single.data.computeHeavyDiagnosticsEveryEpoch = true;

sim_single = revgnss.ReverseGNSSSimulation(cfg_single);
sim_single.initialize();
sim_single.run();

attRanks_s = sim_single.diag.getAttitudeRank();
finalRank_s = attRanks_s(end);

fprintf('    Final epoch attitudeRank = %d\n', finalRank_s);
assert(finalRank_s == 0, ...
    'T8b FAILED: zero lever arm should give attitudeRank=0 (got %d)', finalRank_s);
fprintf('    PASS\n');

fprintf('=== test_attitude_rank_v4: ALL PASS ===\n');
