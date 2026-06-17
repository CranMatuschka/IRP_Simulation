% run_oo_reverse_gnss_report  Main user-facing reverse-GNSS simulation script.
%
% Edit the USER CONFIGURATION section below to select scenario, toggles,
% and report options.  All physics and error-source switches live here.
%
% Output (when write flags are true):
%   output/Report-YYYYMMDD/report-vX.XX.pdf
%   output/Report-YYYYMMDD/report-vX.XX.mat
%
% CHANGED: v3→v4 — Issue 19
% -------  v1 Known Limitations  -------
%
% L1. Signal-dependent hardware delays / differential code biases (DCB)
%     are set to zero.  In the IF combination, HW_IF = a*HW_L1 - b*HW_L2
%     does not cancel and can be a significant bias for precise positioning.
%     Not modelled in v1.  See Schaer (1999), Montenbruck (2014).
%
% L2. Doppler ionosphere-rate term (d/dt of first-order iono delay) is
%     not modelled.  Doppler IF combination is not implemented.
%     Doppler is excluded from ionoFreeCode mode if iono-rate is active.
%
% L3. Pseudorange/Doppler cross-covariance from shared tower-clock
%     product errors is ignored.  R is block-diagonal (PR and Doppler
%     blocks uncorrelated).  Valid only when clock product errors are
%     small or when clock states are estimated in the EKF.

clear; close all; clc;

thisDir = fileparts(mfilename('fullpath'));
addpath(thisDir);

cfg = revgnss.ConfigFactory.defaultConfig();

% ============================================================
% USER CONFIGURATION TOGGLES
% ============================================================

% --- Simulation timing ------------------------------------------
cfg.simulation.duration_s = 3600;
cfg.simulation.dt_s       = 1;

% --- Report output ----------------------------------------------
cfg.report.writePdf       = true;   % false = skip PDF (fast testing)
cfg.report.writeMat       = true;   % false = skip MAT (fast testing)
cfg.plots.showFigures     = false;
cfg.report.version        = '1.01';
cfg.report.baseOutputDir  = fullfile(thisDir, 'output');
cfg.report.overwrite      = true;

% Report style and layout:
%   layout='clockExact'  — LaTeX pipeline (requires pdflatex/xelatex).
%                          Writes .tex + compiles to PDF matching Clock_* style.
%   layout='clockStyle'  — MATLAB figure report with Clock-style section pages.
%   layout='default'     — Simple text dump + raw diagnostic plots.
cfg.report.style     = 'latex';      % 'latex' | '' (simple)
cfg.report.layout    = 'clockExact'; % 'clockExact' | 'clockStyle' | 'default'
cfg.report.writeTex  = true;         % true  = write .tex source file beside PDF
cfg.report.compileTex = 'require';   % 'require' | 'auto' | 'never'

% --- Receivers / attitude ---------------------------------------
% nReceivers == 1  ->  attitude estimation OFF, zero lever arms
% nReceivers  > 1  ->  attitude estimation ON,  auto cross-pattern lever arms
cfg.scenario.nReceivers = 3;

% --- Multi-asset scenario metadata (Stage 20) --------------------
% Measurements and EKF states remain attached to the primary estimated asset.
% GEO-2 is represented as a non-estimated scenario/report/endpoints object
% only; no ISL/TWSTFT/relay rows are generated in this stage.
cfg.scenario.nSpaceAssets = 2;
cfg.assets(1) = cfg.asset;
cfg.assets(1).assetIndex = 1;
cfg.assets(1).estimated = true;
cfg.assets(1).stateOwner = 'primaryEKF';
cfg.assets(2) = cfg.assets(1);
cfg.assets(2).name = 'GEO-2';
cfg.assets(2).assetIndex = 2;
cfg.assets(2).estimated = false;
cfg.assets(2).stateOwner = 'representedOnly';
cfg.assets(2).r_ecef_m = revgnss.GeometryUtils.geodetic2ecef(0.0, 28.0*pi/180, 35786000.0);
cfg.assets(2).receiverLeverArm_body_m = [0; 0; 0];
cfg.assets(2).receiverLeverArms_body_m = [0; 0; 0];
cfg.assets(2).clock.name = 'RxClock_GEO_2';

% --- Frequency --------------------------------------------------
% false  ->  L1 only
% true   ->  L1 + L2
cfg.signals.twoFrequency.enable = true;

% --- Geometry / relativity --------------------------------------
cfg.physics.sagnac.truth.enable          = true;
cfg.physics.sagnac.model.enable          = true;
cfg.physics.lightTime.truth.enable       = true;   % mapped to Sagnac if enabled
cfg.physics.lightTime.model.enable       = true;   % mapped to Sagnac if enabled
cfg.physics.relativity.shapiro.truth.enable = true;
cfg.physics.relativity.shapiro.model.enable = true;
cfg.physics.relativity.clock.truth.enable   = true; % disabled/warned: not validated v1
cfg.physics.relativity.clock.model.enable   = true; % disabled/warned: not validated v1

% --- Atmosphere -------------------------------------------------
cfg.errors.troposphere.truth.enable       = true;
cfg.errors.troposphere.model.enable       = true;
cfg.errors.troposphere.modelType          = 'simpleMapped';
cfg.errors.troposphere.stochastic.enable  = true;
cfg.errors.ionosphere.truth.enable        = true;
cfg.errors.ionosphere.model.enable        = true;
cfg.errors.ionosphere.modelType           = 'simpleMapped';
cfg.errors.ionosphere.stochastic.enable   = true;
cfg.errors.ionosphere.scintillation.enable = true;

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
cfg.measurements.doppler.enable       = true;
cfg.measurements.doppler.useInEKF     = true;
cfg.physics.doppler.truth.enable      = true;
cfg.physics.doppler.model.enable      = true;

% --- Carrier phase EKF (multi-receiver mode, Stage 14.6) -------
% floatPerTowerReceiverSignal: one float ambiguity per tower x receiver x signal.
% Scientifically valid for nReceivers > 1.  No integer fixing, L1 only.
cfg.measurements.carrierPhase.enable    = true;
cfg.measurements.carrierMode            = 'ekfFloat';
cfg.estimation.ambiguityMode            = 'floatPerTowerReceiverSignal';
cfg.estimation.ambiguity.initialSigma_m = 100;

% --- Carrier slip detection -------------------------------------
cfg.measurements.carrier.slipDetection.enable                = true;
cfg.measurements.carrier.slipDetection.threshold_m           = 0.1;
cfg.measurements.carrier.slipDetection.minEpochsBeforeDetect = 3;
cfg.measurements.carrier.slipDetection.resetSigma_m          = 100;
cfg.measurements.carrier.slipDetection.action                = 'resetAndSkip';

% --- Troposphere ZWD EKF state ----------------------------------
% Disabled in the default multi-receiver report.  Stage 15 ZWD states are
% diagnostic/validation tools here and can be weakly observable in this GEO
% geometry; keep the report configuration scientifically bounded.
cfg.estimation.troposphereMode         = 'none';
cfg.estimation.tropoZwd.initialSigma_m = 0.3;
cfg.estimation.tropoZwd.sigma_ss_m     = 0.05;
cfg.estimation.tropoZwd.tau_s          = 3600;

% --- Attitude/ambiguity separability validation (Stage 14.9) ----
% Runs a short 120 s known-ambiguity validation after the main run.
% ATTITUDE VALIDATION ONLY — not operational integer fixing.
% Shows whether attitude converges when truth ambiguities are known.
cfg.estimator.runKnownAmbiguityValidation = true;

% --- Calibrated differential carrier attitude (Stage 15) --------
% Operational: baseline-differenced carrier with calibrated ambiguity bias.
% Requires carrierMode=ekfFloat + nReceivers>=2.
% Calibration absorbs the attitude reference at t < calibWin_s.
cfg.estimator.attitudeCarrierMode    = 'calibratedDifferentialAmbiguity';
cfg.estimator.diffAtt.calibWin_s     = 60;

% --- Absolute attitude initialization (Stage 17) ----------------
% Independent coarse attitude/integer search.  If the residual/ratio gate is
% weak, the report classifies it honestly and Stage 15 remains relative
% calibrated tracking only.
cfg.estimator.attitudeInitMode = 'coarseBaselineIntegerSearch';
cfg.estimator.attitudeInit.search.windowDeg = [2; 2; 2];
cfg.estimator.attitudeInit.search.stepDeg = [0.5; 0.5; 0.5];
cfg.estimator.attitudeInit.search.maxCandidates = 729;
cfg.estimator.attitudeInit.search.ratioThreshold = 1.20;
cfg.estimator.attitudeInit.search.ambiguousRatioThreshold = 1.01;
cfg.estimator.attitudeInit.search.improvementRatioThreshold = 1.05;
cfg.estimator.attitudeInit.search.maxRmsCycles = 0.30;
cfg.estimator.attitudeInitShadow.enable = false;

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
