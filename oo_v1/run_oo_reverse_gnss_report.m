% run_oo_reverse_gnss_report  Main user-facing reverse-GNSS simulation script.
%
% Edit the USER CONFIGURATION section below to select scenario, toggles,
% and report options.  All physics and error-source switches live here.
%
% Output (when write flags are true):
%   output/Report-YYYYMMDD/report-vX.XX.pdf
%   output/Report-YYYYMMDD/report-vX.XX.mat

clear; close all; clc;

thisDir = fileparts(mfilename('fullpath'));
addpath(thisDir);

cfg = revgnss.ConfigFactory.defaultConfig();

% ============================================================
% USER CONFIGURATION TOGGLES
% ============================================================

% --- Simulation timing ------------------------------------------
cfg.simulation.duration_s = 600;
cfg.simulation.dt_s       = 1;

% --- Report output ----------------------------------------------
cfg.report.writePdf       = true;   % false = skip PDF (fast testing)
cfg.report.writeMat       = true;   % false = skip MAT (fast testing)
cfg.plots.showFigures     = false;
cfg.report.version        = '1.01';
cfg.report.baseOutputDir  = fullfile(thisDir, 'output');
cfg.report.overwrite      = true;

% --- Receivers / attitude ---------------------------------------
% nReceivers == 1  ->  attitude estimation OFF, zero lever arms
% nReceivers  > 1  ->  attitude estimation ON,  auto cross-pattern lever arms
cfg.scenario.nReceivers = 1;

% --- Frequency --------------------------------------------------
% false  ->  L1 only
% true   ->  L1 + L2
cfg.signals.twoFrequency.enable = false;

% --- Geometry / relativity --------------------------------------
cfg.physics.sagnac.truth.enable          = false;
cfg.physics.sagnac.model.enable          = false;
cfg.physics.lightTime.truth.enable       = false;   % mapped to Sagnac if enabled
cfg.physics.lightTime.model.enable       = false;   % mapped to Sagnac if enabled
cfg.physics.relativity.shapiro.truth.enable = false;
cfg.physics.relativity.shapiro.model.enable = false;
cfg.physics.relativity.clock.truth.enable   = false; % disabled/warned: not validated v1
cfg.physics.relativity.clock.model.enable   = false; % disabled/warned: not validated v1

% --- Atmosphere -------------------------------------------------
cfg.errors.troposphere.truth.enable       = false;
cfg.errors.troposphere.model.enable       = false;
cfg.errors.troposphere.modelType          = 'simpleMapped';
cfg.errors.troposphere.stochastic.enable  = false;
cfg.errors.ionosphere.truth.enable        = false;
cfg.errors.ionosphere.model.enable        = false;
cfg.errors.ionosphere.modelType           = 'simpleMapped';
cfg.errors.ionosphere.stochastic.enable   = false;
cfg.errors.ionosphere.scintillation.enable = false;

% --- Measurement noise ------------------------------------------
cfg.measurements.codeNoise.model = 'constant';

% --- Hardware / multipath ---------------------------------------
cfg.errors.hardwareDelay.truth.enable = false;
cfg.errors.hardwareDelay.model.enable = false;
cfg.errors.multipath.truth.enable     = false;
cfg.errors.multipath.model.enable     = false;

% --- Survey / antenna -------------------------------------------
cfg.effects.towerSurvey.truth.enable  = false;
cfg.effects.towerSurvey.model.enable  = false;
cfg.effects.antennaPCO.truth.enable   = false;
cfg.effects.antennaPCO.model.enable   = false;
cfg.effects.antennaPCV.truth.enable   = false;
cfg.effects.antennaPCV.model.enable   = false;

% --- Correlated noise -------------------------------------------
cfg.effects.correlatedNoise.enable = false;

% --- Clocks -----------------------------------------------------
cfg.clock.receiver.deterministic      = true;
cfg.errors.towerClockCorrection.mode  = 'perfectCorrection';

% --- Doppler ----------------------------------------------------
cfg.measurements.doppler.enable       = false;
cfg.measurements.doppler.useInEKF     = false;
cfg.physics.doppler.truth.enable      = false;
cfg.physics.doppler.model.enable      = false;

% --- Carrier phase ----------------------------------------------
cfg.measurements.carrierPhase.enable      = false;
cfg.measurements.carrierPhase.useInEKF    = false;   % disabled/warned: ambiguity states not implemented v1

% --- Validation policy ------------------------------------------
% 'disableWithWarning'  ->  unsupported features disabled with console warning
% 'error'              ->  any unsupported feature throws an error
cfg.validation.unsupportedFeaturePolicy = 'disableWithWarning';

% ============================================================
% RUN SIMULATION AND WRITE REPORT
% ============================================================

out = revgnss.ReportRunner.runSingle(cfg);

if cfg.report.writePdf
    fprintf('\nPDF:\n%s\n', out.pdfPath);
    try; open(out.pdfPath); catch; end
end
if cfg.report.writeMat
    fprintf('\nMAT:\n%s\n', out.matPath);
end
