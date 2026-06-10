% run_oo_reverse_gnss  Default reverse-GNSS simulation (GEO-1 scenario).
%
% Runs the default GEO-1 convergence validation scenario and saves a PDF report.
%
% Default scenario:
%   Space asset : GEO-1 at lat 0 deg, lon 23 deg, alt 35786 km
%   Towers      : Tenerife, Stockholm, Hartebeesthoek, Bengaluru, Libreville
%   Duration    : 3600 s (1 hour)
%   Errors      : code noise 0.3 m, atmosphere off, hardware delays off
%   Tower clocks: deterministic zero bias, perfectCorrection mode
%   EKF start   : 1000 m position offset, 100 m clock bias offset
%
% Output:
%   Figures open on screen.
%   PDF saved to: oo_v1/output/reverse_gnss_simple_report.pdf
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

% Duration and step already set in defaultConfig (3600 s, dt=1 s).
% Enable plots and report.
cfg.plots.enable          = true;
cfg.plots.saveFigures     = false;
cfg.report.enable         = true;

%% --- Create and run simulation ----------------------------------------
sim = revgnss.ReverseGNSSSimulation(cfg);
sim.initialize();
sim.run();

%% --- Generate plots and PDF report ------------------------------------
sim.plot();
sim.writeReport();

%% --- Export results (optional) ----------------------------------------
results = sim.getResults();
fprintf('\nDone. Access results via the ''results'' variable.\n');
fprintf('  results.diag        - per-epoch diagnostics\n');
fprintf('  results.assetHistory - truth state log\n');
fprintf('  results.ekfHistory   - EKF state log\n');
