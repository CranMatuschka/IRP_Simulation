% run_oo_reverse_gnss_report  Main user-facing reverse-GNSS report script.
%
% Produces a single dated PDF+MAT report in:
%   oo_v1/output/Report-YYYYMMDD/report-vX.XX.pdf
%
% Edit cfg.scenario.nReceivers and cfg.signals.twoFrequency.enable to
% switch between single/multi-antenna and single/dual-frequency modes.
%
% Default: nReceivers=1, L1 only, 600 s, code noise 0.3 m.

%% --- Setup path -------------------------------------------------------
thisDir = fileparts(mfilename('fullpath'));
addpath(thisDir);

%% --- Build configuration ---------------------------------------------
cfg = revgnss.ConfigFactory.defaultConfig();

cfg.simulation.duration_s = 600;

% Topology: set nReceivers > 1 to enable attitude estimation automatically.
cfg.scenario.nReceivers = 1;

% Dual-frequency toggle: false → L1 only, true → L1 + L2.
cfg.signals.twoFrequency.enable = false;

% Report metadata
cfg.report.version       = '1.01';
cfg.report.baseOutputDir = fullfile(thisDir, 'output');

%% --- Run and generate report -----------------------------------------
out = revgnss.ReportRunner.runSingle(cfg);

fprintf('\nReport written to:\n  %s\n', out.pdfPath);
