% run_oo_reverse_gnss  Default reverse-GNSS simulation (GEO-1 scenario).
%
% Wrapper around ReportRunner.runSingle — kept for backward compatibility.
% For the full user-facing report workflow see run_oo_reverse_gnss_report.m.
%
% Default scenario:
%   Space asset : GEO-1, lat 0 deg, lon 23 deg, alt 35786 km
%   Towers      : 5 ground stations (Tenerife, Stockholm, Hartebeesthoek, Bengaluru, Libreville)
%   Receivers   : 1 (single antenna, attitude frozen)
%   Duration    : 3600 s, dt = 1 s
%   Errors      : code noise 0.3 m, atmosphere off
%   Tower clocks: deterministic zero bias, perfectCorrection mode
%   Physics     : all range corrections disabled by default

%% --- Setup path -------------------------------------------------------
thisDir = fileparts(mfilename('fullpath'));
addpath(thisDir);
fprintf('Working directory: %s\n', thisDir);

%% --- Build configuration ---------------------------------------------
cfg = revgnss.ConfigFactory.defaultConfig();

% Alternative presets (uncomment to use instead):
% cfg = revgnss.ConfigFactory.multiAntennaAttitudeConfig();   % 4 antennas, attitude estimation
% cfg = revgnss.ConfigFactory.clockDiversityConfig();         % diverse tower clocks
% cfg = revgnss.ConfigFactory.realisticPseudorangeConfig();   % Sagnac + Shapiro corrections

%% --- Run via ReportRunner --------------------------------------------
out = revgnss.ReportRunner.runSingle(cfg);

results = out.sim.getResults();
fprintf('\nDone. Access results via the ''results'' variable.\n');
fprintf('  results.diag         - per-epoch diagnostics\n');
fprintf('  results.assetHistory  - truth state log\n');
fprintf('  results.ekfHistory    - EKF state log\n');
fprintf('Report saved to: %s\n', out.pdfPath);
