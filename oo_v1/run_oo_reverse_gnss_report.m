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

% --- Environment-variable overrides (Stage 25+ validation gate) ---
oo_v1_envValidate_   = strcmpi(getenv('OO_V1_VALIDATE_REPORT'), 'true');
oo_v1_envAllToggles_ = strcmpi(getenv('OO_V1_ALL_TOGGLES'), 'true');
if oo_v1_envValidate_; oo_v1_envAllToggles_ = true; end  % validate always uses all toggles
oo_v1_envStage_      = str2double(getenv('OO_V1_VALIDATION_STAGE'));
if isnan(oo_v1_envStage_); oo_v1_envStage_ = 0; end
if oo_v1_envValidate_ && oo_v1_envStage_ == 0; oo_v1_envStage_ = 69; end
oo_v1_envCompile_    = strtrim(getenv('OO_V1_REPORT_COMPILE_TEX'));

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
% Stage 65: compact final report flags
cfg.report.zoomLastFraction      = 0.10;  % zoom plots show last 10% of simulation time
cfg.report.compactFinalReport    = true;  % suppress stage-history chapters
cfg.report.suppressStageSections = true;  % no architecture-diary sections in PDF
cfg.report.deduplicateFigures    = true;  % no repeated figure paths in TEX

% --- Stage 61/62: scenario selector and attitude parameterization ---
% Quaternion nominal / error-state EKF runs on the Stage 59 scenario.
% ScenarioPresets.apply() is called after all toggles (see below).
cfg.scenario.name = 'singleAssetCarrierAttitude';
% Stage 61: select quaternion error-state EKF ('eulerZYX' | 'quaternionErrorState')
cfg.estimator.attitude.parameterization = 'quaternionErrorState';
% Stage 62: injection size guard (warn if |delta_theta| exceeds this; not a clamp)
cfg.estimator.attitude.maxErrorStateInjection_rad = deg2rad(10);
% Stage 62: attitude covariance reset diagnostics
cfg.diagnostics.attitudeCovarianceReset.enable = true;
% Stage 63: guarded raw-carrier integer ambiguity fixing
cfg.estimator.integerAmbiguity.enable                     = true;
cfg.estimator.integerAmbiguity.mode                       = 'controlledRawCarrier';
cfg.estimator.integerAmbiguity.minArcLength_s             = 300;
cfg.estimator.integerAmbiguity.maxSigma_cycles            = 0.15;
cfg.estimator.integerAmbiguity.maxDistanceToInteger_cycles = 0.20;
cfg.estimator.integerAmbiguity.maxResidualRmsIncrease_m   = 0.01;
cfg.estimator.integerAmbiguity.fixVariance_cycles2        = 1e-4;
cfg.estimator.integerAmbiguity.resetOnSlip                = true;

% --- Receivers / attitude ---------------------------------------
% nReceivers == 1  ->  attitude estimation OFF, zero lever arms
% nReceivers  > 1  ->  attitude estimation ON,  auto cross-pattern lever arms
cfg.scenario.nReceivers = 3;

% --- Single-asset one-way scenario (Stage 66/67) -------------------------
% One estimated spacecraft. Ground towers transmit reference signals upward
% one-way (tower-to-space only). No ISL, no TWSTFT, no two-way, no relay,
% no multi-asset estimation. ISL/TWSTFT remain at ConfigFactory defaults
% (all disabled) — do not enable them here.
cfg.scenario.nSpaceAssets = 1;        % one estimated spacecraft only
cfg.scenario.orbitClass   = 'GEO';    % 'GEO' | 'MEO' | 'LEO'
%                                      % Stage 67: twoBodyRk4 truth propagator (see ScenarioPresets)

% --- Frequency --------------------------------------------------
% false  ->  L1 only
% true   ->  L1 + L2
cfg.signals.twoFrequency.enable = true;

% --- Code ionosphere-free EKF rows (Stage 45) ------------------
% Guarded L1/L2 IF combination in EKF. Requires twoFrequency.enable=true.
% enable=false (default): keep separate L1+L2 rows in EKF.
% enable=true + useInEkf=true: replace L1+L2 with IF rows in EKF.
% Carrier IF rows, integer fixing, and calibrated DCB are NOT implemented.
cfg.measurements.code.ionosphereFreeRows.enable  = false;
cfg.measurements.code.ionosphereFreeRows.useInEkf = false;
cfg.diagnostics.codeIonoFreeRows.enable           = true;

% --- Code IF EKF consistency diagnostic (Stage 46) -------------
% Audits Stage 45 code IF path: row counts, H compatibility,
% R/noise amplification, residual/NIS, and bias-state risk.
% Carrier IF rows, integer fixing, and calibrated DCB are NOT implemented.
cfg.diagnostics.codeIonoFreeConsistency.enable = true;

% --- Carrier IF float EKF rows (Stage 47) ----------------------
% Guarded L1/L2 carrier IF combination (float ambiguity, non-integer).
% Requires twoFrequency.enable=true and carrierMode='ekfFloat'.
% enable=false (default): keep separate L1+L2 carrier rows in EKF.
% enable=true + useInEkf=true: replace L1+L2 carrier with IF rows.
% B_IF = alpha*B_L1 + beta*B_L2 — NOT an integer; no fixing in v1.
cfg.measurements.carrier.ionosphereFreeRows.enable  = false;
cfg.measurements.carrier.ionosphereFreeRows.useInEkf = false;
cfg.diagnostics.carrierIonoFreeRows.enable           = true;

% --- Carrier IF ambiguity traceability (Stage 48) ---------------
% Diagnostic only. Traces L1/L2 state pairs behind IF rows,
% propagates Var(B_IF) = [alpha beta] * P_pair * [alpha; beta]'
% from Stage 41 Pamb export. B_IF is non-integer (float). No integer fixing.
cfg.diagnostics.carrierIonoFreeAmbiguityTraceability.enable = false;

% --- Wide-lane / narrow-lane float diagnostics (Stage 49) -------
% Diagnostic only. Computes WL/NL cycle-domain sigma and WL/NL
% correlation from Stage 41 Pamb. No integer fixing, no LAMBDA/MLAMBDA,
% no phase-bias products, no false-fix-risk control.
cfg.diagnostics.wideLaneNarrowLane.enable = false;

% --- Ambiguity fixing readiness gate (Stage 50) -----------------
% Readiness gate only. Combines Stages 41/48/49, arc quality, and
% residual/NIS. Does not fix, round, or resolve ambiguities.
% No LAMBDA/MLAMBDA, no phase-bias products, no false-fix-risk control.
cfg.diagnostics.ambiguityFixingReadiness.enable = false;

% --- Ambiguity readiness evidence hardening (Stage 51) ----------
% Evidence hardening for the Stage 50 gate. Collects all evidence
% without early return, exposes arc-quality and residual/NIS availability.
% Still does not fix, round, or resolve ambiguities.
cfg.diagnostics.ambiguityReadinessEvidence.enable = false;

% --- Carrier arc and cycle-slip evidence (Stage 52) -------------
% Exports compact arc evidence from CarrierTrackManager: arc counts,
% arc durations, slip/reset events per track. No integer fixing,
% no LAMBDA/MLAMBDA. Requires carrierMode='ekfFloat' and slip detection.
cfg.diagnostics.carrierArcEvidence.enable = false;

% --- Arc-separated float ambiguities (Stage 53) -----------------
% Makes float carrier ambiguity treatment cycle-slip-aware. Per-track arc IDs
% are incremented on each cycle slip; arc consistency is checked for carrier IF
% and WL/NL pairs. No integer fixing, no LAMBDA/MLAMBDA, no false-fix-risk.
cfg.estimator.arcSeparatedAmbiguities.enable  = false;
cfg.diagnostics.arcSeparatedAmbiguities.enable = false;

% --- Enforced arc-consistent carrier combinations (Stage 54) ----
% When enabled, carrier ionosphere-free rows skip L1/L2 pairs whose arc IDs
% differ (incompatible arcs after a cycle slip). Requires arcSeparatedAmbiguities
% (Stage 53) for arc metadata; falls back to disableWithWarning if metadata
% absent. No integer fixing, no LAMBDA/MLAMBDA, no false-fix-risk control.
cfg.estimator.enforceCarrierArcConsistency.enable        = false;
cfg.diagnostics.carrierArcConsistencyEnforcement.enable  = false;

% --- Diagnostic plugin registry (Stage 55) ----------------------
% Architecture-only toggle: enables DiagnosticPluginRegistry metadata
% collection in ReportRunner. Defaults to true — adds metadata only, no
% scientific content, no EKF math, no integer fixing, no LAMBDA/MLAMBDA.
cfg.diagnostics.pluginRegistry.enable = true;

% --- Stage 56: preferred attitude partial controls ---------------
% LinkGeometry.shouldUseAttitudePartials prefers cfg.estimator.attitude.use*Partials
% when present, and falls back to the legacy estimateAttitudeFromPseudorange flag
% when absent. The preferred fields are set explicitly below only when the user
% wants to override. For default runs the legacy fallback handles everything.
%
% To enable attitude partials explicitly:
%   cfg.estimator.attitude.useCodePartials    = true;
%   cfg.estimator.attitude.useCarrierPartials = true;
%   cfg.estimator.attitude.useDopplerPartials = false;

% --- Stage 57: EKF innovation accounting and gauge/NIS cleanup --
% Separate physical/gauge/augmented NIS in summary. Default enabled.
cfg.diagnostics.ekfInnovationAccounting.enable = true;

% --- Stage 58: EKF translational dynamics prediction mode -------
% Default: constant-velocity (backward compatible).
% Set mode to 'twoBody' or 'j2' to enable inertial orbit prediction.
% Frame model: constant Earth rotation only (no EOP/IERS).
cfg.estimator.dynamics.mode          = 'constantVelocity';
cfg.estimator.dynamics.fdPositionStep_m   = 1.0;
cfg.estimator.dynamics.fdVelocityStep_mps = 1e-3;
cfg.diagnostics.ekfDynamics.enable  = true;

% --- Inter-frequency bias budget (Stage 44) --------------------
% Diagnostic only. Default all to 0 (no calibrated products in v1).
% Units: metres. Set to non-zero to exercise bias-budget propagation.
cfg.biases.interFrequency.code.truth.L1_m    = 0;
cfg.biases.interFrequency.code.truth.L2_m    = 0;
cfg.biases.interFrequency.code.model.L1_m    = 0;
cfg.biases.interFrequency.code.model.L2_m    = 0;
cfg.biases.interFrequency.carrier.truth.L1_m = 0;
cfg.biases.interFrequency.carrier.truth.L2_m = 0;
cfg.biases.interFrequency.carrier.model.L1_m = 0;
cfg.biases.interFrequency.carrier.model.L2_m = 0;

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
% Stage 68: antenna PCO enabled by default (synthetic calibrated constants; no ANTEX).
cfg.effects.antennaPCO.truth.enable   = true;
cfg.effects.antennaPCO.model.enable   = true;
% PCV kept disabled by default (no ANTEX; set to true in all-toggle run only).
cfg.effects.antennaPCV.truth.enable   = false;
cfg.effects.antennaPCV.model.enable   = false;

% --- Correlated noise -------------------------------------------
cfg.effects.correlatedNoise.enable = false;

% --- Clocks -----------------------------------------------------
% Stage 67: stochastic receiver and tower clocks (non-perfect correction).
% Tower clock stochastic mode is applied per-tower in ScenarioPresets.
cfg.clock.receiver.deterministic      = false;
cfg.errors.towerClockCorrection.mode  = 'noisyCorrection';

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

% --- Attitude primary estimator (Stage 67) ----------------------
% Primary attitude estimator: carrier lever-arm quaternion error-state EKF.
% Baselined differential carrier phases from the 4-antenna cross pattern
% drive the quaternion nominal/error-state EKF (Stages 61/62).
% This label is documentary — the EKF runs regardless of this field.
cfg.estimator.attitude.primaryMode   = 'carrierLeverArmQuaternionEkf';

% --- Calibrated differential carrier attitude (Stage 15, Stage 69) ------
% Operational: baseline-differenced carrier with calibrated ambiguity bias.
% Requires carrierMode=ekfFloat + nReceivers>=2.
% Stage 69: referenceMode='externalInitialAttitude' prevents delta_B from
% absorbing the initial EKF attitude error.  DiffAttitudeBuilder.setReference()
% injects truth attitude + referenceSigma_deg noise during simulation init.
% Stage 69: DiffAtt always uses raw L1 rows (primary signalIdx); floatRows
% unwrapped from IF-combined cpInfo in ReverseGNSSSimulation when IF is active.
cfg.estimator.attitudeCarrierMode            = 'calibratedDifferentialAmbiguity';
cfg.estimator.diffAtt.calibWin_s             = 60;
cfg.estimator.diffAtt.referenceMode          = 'externalInitialAttitude';  % Stage 69
cfg.estimator.diffAtt.referenceSigma_deg     = 0.1;                         % Stage 69
% Documentary flags (read by report builder, not controlling EKF code paths):
cfg.estimator.attitude.carrierSignal         = 'L1';
cfg.estimator.attitude.useRawCarrierForAttitude = true;

% --- Coarse attitude initializer (Stage 17) — DISABLED in Stage 69 ------
% Disabled: 'coarseBaselineIntegerSearch' was injecting a potentially wrong
% initial attitude into the quaternion EKF.  The differential calibration with
% externalInitialAttitude reference is now the sole absolute attitude source.
cfg.estimator.attitudeInitMode = 'none';
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
cfg.validation.fullSuiteRun             = false;   % full suite never run here

% --- All-toggle validation mode --------------------------------
% Set stageAllToggles = true to enable every independent boolean toggle.
% OO_V1_ALL_TOGGLES=true achieves the same via env var (Stage 25+ gate).
% Mutually exclusive string modes (carrierMode, etc.) are NOT changed.
% Requires unsupportedFeaturePolicy = 'disableWithWarning' (set above).
stageAllToggles = false;
if stageAllToggles || oo_v1_envAllToggles_
    cfg.errors.hardwareDelay.truth.enable = true;
    cfg.errors.hardwareDelay.model.enable = true;
    cfg.errors.multipath.truth.enable     = true;
    cfg.errors.multipath.model.enable     = true;
    cfg.effects.towerSurvey.truth.enable  = true;
    cfg.effects.towerSurvey.model.enable  = true;
    cfg.effects.antennaPCO.truth.enable   = true;
    cfg.effects.antennaPCO.model.enable   = true;
    cfg.effects.antennaPCV.truth.enable   = true;
    cfg.effects.antennaPCV.model.enable   = true;
    cfg.effects.correlatedNoise.enable    = true;
    cfg.diagnostics.attitudeObservability.enable  = true;
    cfg.diagnostics.receiverGeometry.enable       = true;
    cfg.diagnostics.attitudeKinematics.enable     = true;
    cfg.diagnostics.attitudeJacobianAudit.enable        = true;
    cfg.diagnostics.attitudeEvidence.enable             = true;
    cfg.diagnostics.attitudeScenarioReadiness.enable    = true;
    cfg.diagnostics.carrierAttitudePreparation.enable   = true;
    cfg.diagnostics.carrierRowMetadataInventory.enable  = true;
    cfg.diagnostics.ambiguityReadiness.enable           = true;
    cfg.diagnostics.ambiguityStateMetadata.enable       = true;
    cfg.measurements.carrier.l2EkfRows.enable                = true;
    cfg.diagnostics.l2CarrierArchitecture.enable             = true;
    cfg.diagnostics.ionosphereFreeCombination.enable         = true;
    cfg.diagnostics.ifBiasBudget.enable                      = true;
    cfg.measurements.code.ionosphereFreeRows.enable          = true;
    cfg.measurements.code.ionosphereFreeRows.useInEkf        = true;
    cfg.diagnostics.codeIonoFreeRows.enable                  = true;
    cfg.diagnostics.codeIonoFreeConsistency.enable           = true;
    cfg.measurements.carrier.ionosphereFreeRows.enable       = true;
    cfg.measurements.carrier.ionosphereFreeRows.useInEkf     = true;
    cfg.diagnostics.carrierIonoFreeRows.enable               = true;
    cfg.diagnostics.carrierIonoFreeAmbiguityTraceability.enable = true;
    cfg.diagnostics.wideLaneNarrowLane.enable                    = true;
    cfg.diagnostics.ambiguityFixingReadiness.enable              = true;
    cfg.diagnostics.ambiguityReadinessEvidence.enable            = true;
    cfg.diagnostics.carrierArcEvidence.enable                    = true;
    cfg.estimator.arcSeparatedAmbiguities.enable                 = true;
    cfg.diagnostics.arcSeparatedAmbiguities.enable               = true;
    cfg.estimator.enforceCarrierArcConsistency.enable            = true;
    cfg.diagnostics.carrierArcConsistencyEnforcement.enable      = true;
    cfg.diagnostics.pluginRegistry.enable                        = true;
    % Stage 58: enable J2 dynamics in all-toggle mode to exercise inertial prediction
    cfg.estimator.dynamics.mode          = 'j2';
    cfg.diagnostics.ekfDynamics.enable  = true;
    cfg.validation.stageAllToggles         = true;
    if oo_v1_envAllToggles_
        cfg.validation.invokedMainScript = true;
        if oo_v1_envStage_ > 0
            cfg.validation.validationStage = oo_v1_envStage_;
        end
    end
    % Stage 67: ScenarioPresets.apply() (called below) overrides dynamics
    % to 'twoBody' with matched twoBodyRk4 truth propagator. No override needed here.
end
if ~isempty(oo_v1_envCompile_) && ismember(oo_v1_envCompile_, {'require','auto','never'})
    cfg.report.compileTex = oo_v1_envCompile_;
end

% Apply scenario preset after all toggles (preset overrides what it needs to).
if isfield(cfg,'scenario') && isfield(cfg.scenario,'name') && ...
        strcmp(cfg.scenario.name,'singleAssetCarrierAttitude')
    cfg = revgnss.ScenarioPresets.apply(cfg, 'singleAssetCarrierAttitude');
end

% ============================================================
% RUN SIMULATION AND WRITE REPORT
% ============================================================

% --- main-script validation gate (pre-run) ---
oo_v1_doValidate_ = revgnss.MainScriptValidationGate.isEnabled();
if oo_v1_doValidate_
    [cfg, oo_v1_gateState_, oo_v1_ok_] = ...
        revgnss.MainScriptValidationGate.preRun(cfg, thisDir);
    if ~oo_v1_ok_; return; end
end

out = revgnss.ReportRunner.runSingle(cfg);

if cfg.report.writePdf
    fprintf('\nPDF:\n%s\n', out.pdfPath);
    try; open(out.pdfPath); catch; end
end
if cfg.report.writeMat
    fprintf('\nMAT:\n%s\n', out.matPath);
end

% --- main-script validation gate (post-run) ---
if oo_v1_doValidate_
    revgnss.MainScriptValidationGate.postRun(oo_v1_gateState_, out);
end

assignin('base', 'oo_v1_last_report_out', out);
assignin('base', 'oo_v1_last_report_cfg', cfg);
