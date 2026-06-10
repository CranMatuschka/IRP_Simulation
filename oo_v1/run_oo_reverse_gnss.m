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
% Output (cfg.plots.showFigures = false by default):
%   Figures created hidden (not shown on screen).
%   Individual figures saved to: oo_v1/output/figures/<NN>_<name>.png/.fig
%   PDF saved to:                oo_v1/output/reverse_gnss_simple_report.pdf
%
% To show figures on screen, set cfg.plots.showFigures = true before running.
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
% Enable plots and report; figures are hidden by default (showFigures=false).
cfg.plots.enable                = true;
cfg.plots.showFigures           = false;   % hidden: saved to disk, not shown
cfg.plots.saveIndividualFigures = true;
cfg.plots.savePdf               = true;
cfg.plots.closeAfterSave        = false;
cfg.report.enable               = true;

%% --- Create and run simulation ----------------------------------------
sim = revgnss.ReverseGNSSSimulation(cfg);
sim.initialize();
sim.run();

%% --- Generate plots and PDF report ------------------------------------
% sim.plotAndReport() is equivalent to:
%   figHandles = sim.plot();
%   sim.writeReport(figHandles);
figHandles = sim.plot();
sim.writeReport(figHandles);

%% --- Export results (optional) ----------------------------------------
results = sim.getResults();
fprintf('\nDone. Access results via the ''results'' variable.\n');
fprintf('  results.diag         - per-epoch diagnostics\n');
fprintf('  results.assetHistory  - truth state log\n');
fprintf('  results.ekfHistory    - EKF state log\n');
fprintf('Figures saved to: %s\n', cfg.plots.outputDir);
