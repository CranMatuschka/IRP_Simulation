% run_oo_reverse_gnss  Entry point for the oo_v1 reverse-GNSS simulation.
%
% Runs a single default scenario and generates diagnostic plots.
%
% Usage (from oo_v1/ directory or any directory with oo_v1/ on path):
%   cd oo_v1
%   run_oo_reverse_gnss

%% --- Setup path --------------------------------------------------------
thisDir = fileparts(mfilename('fullpath'));
addpath(thisDir);
fprintf('Working directory: %s\n', thisDir);

%% --- Build configuration ----------------------------------------------
cfg = revgnss.ConfigFactory.defaultConfig();

% Optionally tune for a quick demo
cfg.simulation.duration_s = 300;
cfg.simulation.dt_s       = 1.0;
cfg.plots.enable          = true;
cfg.plots.saveFigures     = false;

%% --- Create and run simulation ----------------------------------------
sim = revgnss.ReverseGNSSSimulation(cfg);
sim.initialize();
sim.run();

%% --- Generate plots ---------------------------------------------------
sim.plot();

%% --- Export results (optional) ----------------------------------------
results = sim.getResults();
fprintf('\nDone. Access results via the ''results'' variable.\n');
fprintf('  results.diag        - per-epoch diagnostics\n');
fprintf('  results.assetHistory - truth state log\n');
fprintf('  results.ekfHistory   - EKF state log\n');
