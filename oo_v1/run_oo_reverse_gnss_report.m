% run_oo_reverse_gnss_report  Main user-facing reverse-GNSS simulation script.
%
% Runs one simulation and writes one report:
%   output/Report-YYYYMMDD/report-vX.XX.pdf
%   output/Report-YYYYMMDD/report-vX.XX.mat
%
% Edit the USER CONFIGURATION section below to change the scenario.

clear; close all; clc;

thisDir = fileparts(mfilename('fullpath'));
addpath(thisDir);

cfg = revgnss.ConfigFactory.defaultConfig();

% ============================================================
% USER CONFIGURATION
% ============================================================

cfg.simulation.duration_s = 600;

% Receivers:
% nReceivers == 1  →  attitude estimation automatically OFF
% nReceivers  > 1  →  attitude estimation automatically ON
cfg.scenario.nReceivers = 1;

% Frequency:
% false  →  L1 only
% true   →  L1 + L2
cfg.signals.twoFrequency.enable = false;

% Report
cfg.report.version       = '1.01';
cfg.report.baseOutputDir = fullfile(thisDir, 'output');
cfg.report.overwrite     = true;

% ============================================================
% RUN ONE SIMULATION AND WRITE ONE REPORT
% ============================================================

out = revgnss.ReportRunner.runSingle(cfg);

fprintf('\nPDF:\n%s\n', out.pdfPath);
fprintf('\nMAT:\n%s\n', out.matPath);

try
    open(out.pdfPath);
catch
end
