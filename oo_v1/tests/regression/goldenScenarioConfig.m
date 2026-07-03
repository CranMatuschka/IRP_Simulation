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

function cfg = goldenScenarioConfig(durationOverride_s)
%GOLDENSCENARIOCONFIG  Frozen snapshot of run_oo_reverse_gnss_report.m config.
%   Phase-0 regression contract. This is a VERBATIM copy of the canonical
%   Stage-85 singleAssetCarrierAttitude GEO scenario configuration block, wrapped
%   as a function that returns the resolved cfg with report writing disabled so
%   the regression gate can read out.summary quickly (no PDF/LaTeX build).
%
%   durationOverride_s (optional): short SMOKE duration; empty/absent = full 3600 s.
%
%   DO NOT hand-tune numeric values here. When a later refactor phase changes the
%   config API, update this fixture to build the SAME scenario through the new API
%   and prove the golden metrics are unchanged (the numbers are the contract).

    thisDir = fileparts(mfilename('fullpath'));
    addpath(fullfile(thisDir, '..', '..'));  % oo_v1 root, so +revgnss resolves

    % Environment overrides pinned OFF: the golden scenario is the default
    % (non-all-toggles) run, independent of ambient shell state (fixes C-6 for
    % the gate). stageAllToggles stays false below, so the all-toggle block is dead.
    oo_v1_envValidate_   = false;  %#ok<NASGU>
    oo_v1_envAllToggles_ = false;
    oo_v1_envStage_      = 0;       %#ok<NASGU>
    oo_v1_envCompile_    = '';

cfg = revgnss.ConfigFactory.defaultConfig();

% ============================================================
% USER CONFIGURATION TOGGLES
% ============================================================

% --- Simulation timing ------------------------------------------
cfg.simulation.duration_s = 3600;
cfg.simulation.dt_s       = 1;

% --- Diagnostics storage ---------------------------------------
% 'compact'     : never store full P/H/R/z/h (small MAT; all science preserved)
% 'sampledFull' : compact + full-matrix snapshots every snapshot.interval_s
% 'full'        : full matrices every epoch (large MAT; debug only)
cfg.diagnostics.storage.mode                   = 'compact';
cfg.diagnostics.storage.snapshot.enable        = true;
cfg.diagnostics.storage.snapshot.interval_s    = 300;
% To enable full matrices for a short debug run:
%   cfg.diagnostics.storage.mode = 'full';

% --- Report output ----------------------------------------------
cfg.report.writePdf       = true;   % false = skip PDF (fast testing)
cfg.report.writeMat       = true;   % false = skip MAT (fast testing)
cfg.plots.showFigures     = false;
cfg.report.version        = '2.01';
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
% Stage 77: ScenarioPresets.singleAssetCarrierAttitude is the single owner of nReceivers.
% It sets nReceivers=4 (non-collinear cross pattern). Do not set it here.
% (nReceivers=1 → attitude OFF; nReceivers>1 → attitude ON, auto lever arms)

% --- Single-asset one-way scenario (Stage 66/67) -------------------------
% One estimated spacecraft. Ground towers transmit reference signals upward
% one-way (tower-to-space only). No ISL, no TWSTFT, no two-way, no relay,
% no multi-asset estimation. ISL/TWSTFT remain at ConfigFactory defaults
% (all disabled) — do not enable them here.
cfg.scenario.nSpaceAssets = 1;        % one estimated spacecraft only
cfg.scenario.orbitClass   = 'GEO';    % 'GEO' | 'MEO' | 'LEO'
%                                      % Stage 82: j2Rk4 truth (j2Rk4 + twoBody EKF mismatch; see ScenarioPresets, Stage 82)

% --- Frequency --------------------------------------------------
% Stage 77 canonical: cfg.signals.enabledMask is the single frequency control.
% [true, true]  -> L1 + L2 (dual-frequency)
% [true, false] -> L1 only (single-frequency)
% finalizeConfig derives twoFrequency.enable, code/carrier.enabledByFrequency,
% and diffAtt.ambiguityResolution.enabledByFrequency from this mask.
cfg.signals.enabledMask = [true, true];

% --- Code ionosphere-free EKF rows (Stage 45) ------------------
% Guarded L1/L2 IF combination in EKF. Requires L1+L2 (cfg.signals.enabledMask=[true,true]).
% enable=false (default): keep separate L1+L2 rows in EKF.
% enable=true + useInEkf=true: replace L1+L2 with IF rows in EKF.
% Carrier IF rows, integer fixing, and calibrated DCB are NOT implemented.
cfg.measurements.code.ionosphereFreeRows.enable  = true;
cfg.measurements.code.ionosphereFreeRows.useInEkf = true;
cfg.diagnostics.codeIonoFreeRows.enable           = true;

% --- Code IF EKF consistency diagnostic (Stage 46) -------------
% Audits Stage 45 code IF path: row counts, H compatibility,
% R/noise amplification, residual/NIS, and bias-state risk.
% Carrier IF rows, integer fixing, and calibrated DCB are NOT implemented.
cfg.diagnostics.codeIonoFreeConsistency.enable = true;

% --- Carrier IF float EKF rows (Stage 47) ----------------------
% Guarded L1/L2 carrier IF combination (float ambiguity, non-integer).
% Requires L1+L2 (cfg.signals.enabledMask=[true,true]) and carrierMode='ekfFloat'.
% enable=false (default): keep separate L1+L2 carrier rows in EKF.
% enable=true + useInEkf=true: replace L1+L2 carrier with IF rows.
% B_IF = alpha*B_L1 + beta*B_L2 — NOT an integer; no fixing in v1.
cfg.measurements.carrier.ionosphereFreeRows.enable  = true;
cfg.measurements.carrier.ionosphereFreeRows.useInEkf = true;
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
cfg.physics.lightTime.enable             = true;
cfg.physics.lightTime.mode               = 'iterativeOneWay';
cfg.physics.lightTime.iterations         = 2;
cfg.physics.lightTime.tolerance_s        = 1e-12;
cfg.physics.lightTime.truth.enable       = true;
cfg.physics.lightTime.model.enable       = true;
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
% Stage 67: stochastic receiver and tower clocks.
% Stage 71: tower clock correction upgraded from truth-plus-noise to
%   synthetic product-prediction mode (truthHistoryProductNoisy).
%   Product epoch is delayed/quantised; correction contains per-product
%   bias/drift noise fixed at product broadcast time; prediction error
%   grows with product age and enters measurement covariance.
%   Receiver clock bias/drift remain estimated by the EKF.
%   Tower clocks are corrected by product, not estimated, to avoid
%   clock gauge ambiguity without a reference constraint.
% Stage 72: actual root cause of 27 m position error was false carrier
%   cycle-slip detection triggered by product epoch changes.  At each 30 s
%   product boundary the model correction steps by (b_noise_new - b_noise_old)
%   whose RMS is sqrt(2)*sigmaBias.  CycleSlipDetector compares consecutive
%   pre-fit residuals; when that jump exceeds slipDetection.threshold_m the
%   ambiguity is reset and the arc broken.  With sigmaBias=0.05 m the jump
%   RMS is 0.07 m, giving ~15 % false-slip rate per measurement per epoch
%   change, causing cascading resets that prevent carrier convergence.
%   Fix: reduce sigmaBias to 0.01 m so the jump sigma (0.014 m) is 7-sigma
%   below the 0.1 m threshold (false-slip probability ~10^-12 per measurement).
%   Also corrected: clockAtProductEpoch history fallback and GroundTower
%   history initialisation at t=0.  Summary fields moved before PDF build;
%   gauge text corrected; covariance handling labelled diagonal-only.
cfg.clock.receiver.deterministic       = false;
cfg.estimator.estimateTowerClocks      = false;
% Stage 77: cfg.clocks.tower.product.mode is canonical (set below).
% cfg.errors.towerClockCorrection.mode is derived from it in finalizeConfig.

% Stage 71: product model parameters.
% Stage 72: sigmaBias reduced 0.05 -> 0.01 m to prevent false carrier slips
%   at product epoch boundaries (see comment above).  0.01 m = 0.033 ns
%   corresponds to an IGS-class dense-network clock product.
cfg.clocks.tower.product.mode                  = 'truthHistoryProductNoisy';
cfg.clocks.tower.product.updateInterval_s      = 30;
cfg.clocks.tower.product.latency_s             = 5;
cfg.clocks.tower.product.sigmaBias_m           = 0.01;   % ~0.033 ns: IGS-class ground tracking network
cfg.clocks.tower.product.sigmaDrift_mps        = 0.0002; % ~0.0007 ppb/s
cfg.clocks.tower.product.covBiasDrift          = 0;
cfg.clocks.tower.product.validity_s            = 120;
cfg.clocks.tower.product.addToR                = true;
cfg.clocks.tower.product.sharedErrorCorrelation = true;

% --- Doppler ----------------------------------------------------
cfg.measurements.doppler.enable       = true;
cfg.measurements.doppler.useInEKF     = true;
cfg.physics.doppler.truth.enable      = true;
cfg.physics.doppler.model.enable      = true;

% --- Carrier phase EKF (multi-receiver mode, Stage 14.6) -------
% floatPerTowerReceiverSignal: one float ambiguity per tower x receiver x signal.
% Scientifically valid for nReceivers > 1.  Float ambiguities; no LAMBDA/MLAMBDA integer fixing.
cfg.measurements.carrierPhase.enable    = true;
cfg.measurements.carrierMode            = 'ekfFloat';
cfg.estimation.ambiguityMode            = 'floatPerTowerReceiverSignal';
cfg.estimation.ambiguity.initialSigma_m = 100;

% --- Carrier slip detection (Stage 73: model-step-compensated) -
% Stage 73 replaces the raw residual-jump test with a compensated test:
%   slipMetric = observed_jump - expected_model_jump
%   isSlip = |slipMetric| >= threshold
% Expected jump = towerClkModel_k - towerClkModel_{k-1}. Tower clock product
% epoch boundary steps are thereby removed from the slip statistic, making
% arc handling robust to product update intervals regardless of clock sigma.
% Real cycle slips (B_true discontinuity) still produce large slipMetric.
cfg.measurements.carrier.slipDetection.enable                = true;
% Stage 77: threshold_m derived from canonical cfg.carrierSlip.threshold_m in finalizeConfig.
cfg.measurements.carrier.slipDetection.minEpochsBeforeDetect = 3;
cfg.measurements.carrier.slipDetection.resetSigma_m          = 100;
cfg.measurements.carrier.slipDetection.action                = 'resetAndSkip';

% Stage 73: carrier arc robustness config
cfg.carrierSlip.enable                          = true;
cfg.carrierSlip.method                          = 'modelStepCompensatedResidualJump';
cfg.carrierSlip.threshold_m                     = 0.10;
cfg.carrierSlip.minArcLength_s                  = 300;
cfg.carrierSlip.productStepCompensation         = true;
cfg.carrierSlip.atmosphereStepCompensation      = true;  % documented intent (v1: atm model is smooth)
cfg.carrierSlip.antennaStepCompensation         = true;  % documented intent (v1: PCO is static)
cfg.carrierSlip.hardwareStepCompensation        = true;  % documented intent (v1: HW delay is static)
cfg.carrierSlip.diffAttitudeBaselineMode        = true;  % DiffAtt slip detector disabled per Stage 69
cfg.carrierSlip.resetAmbiguityOnConfirmedSlip   = true;
cfg.carrierSlip.ignoreKnownProductBoundaryJumps = false; % compensate then test; do not ignore
cfg.carrierSlip.logDiagnostics                  = true;
cfg.carrierSlip.syntheticSlipInjection.enable       = false;
cfg.carrierSlip.syntheticSlipInjection.time_s       = 1800;
cfg.carrierSlip.syntheticSlipInjection.towerIndex   = 1;
cfg.carrierSlip.syntheticSlipInjection.receiverIndex = 2;
cfg.carrierSlip.syntheticSlipInjection.signal       = 'L1';
cfg.carrierSlip.syntheticSlipInjection.jumpCycles   = 1;

% --- Stage 74: shared-error covariance consistency ---------------
% Code rows sharing the same tower and product epoch share a common tower
% clock product error.  Treating them as fully independent (diagonal-only R)
% makes the EKF too confident and NIS misleading.
%
% Stage 74 implements block covariance for code rows:
%   R_ij += sigma_twr^2   for all (i,j) from the same tower, i != j
% This is equivalent to R = diag(sigma_tracking^2) + sum_t(sigma_t^2*J_t)
% where J_t is the all-ones block for tower t.  R remains symmetric PD.
%
% Carrier R: Stage 83 adds time-varying product drift residual (age-weighted outer product).
%   Float ambiguity absorbs constant arc bias; drift covariance from arc-start is included.
% Doppler R: Stage 83 frameConsistentV2 — tower rotation + product-drift covariance blocks.
cfg.covariance.sharedErrors.enable                     = true;
cfg.covariance.sharedErrors.mode                       = 'blockTowerClockProduct';
cfg.covariance.sharedErrors.applyTowerClockToCode      = true;
cfg.covariance.sharedErrors.applyTowerClockToCarrier   = false;
cfg.covariance.sharedErrors.applyTowerClockToDoppler   = false;
cfg.covariance.sharedErrors.carrierPolicy              = 'arcBiasAbsorbsConstantProductBias';
cfg.covariance.sharedErrors.dopplerPolicy              = 'frameConsistentV2';
cfg.covariance.sharedErrors.ensureSPD                  = true;
cfg.covariance.sharedErrors.jitter_m2                  = 1e-12;
cfg.covariance.sharedErrors.reportDiagnostics          = true;

% --- Stage 83: Doppler and carrier product-covariance closure ---
cfg.measurements.doppler.modelLevel                     = 'frameConsistentV2';
cfg.measurements.doppler.includeTowerRotationalVelocity = true;
cfg.measurements.doppler.includeSagnacRate              = false;
cfg.measurements.doppler.includeLightTimeRate           = false;
cfg.measurements.doppler.includeTowerClockProductDrift  = true;
cfg.measurements.doppler.jacobianMode                   = 'analyticRangeRateV1';
cfg.covariance.productClock.enable                      = true;
cfg.covariance.productClock.applyToCode                 = true;
cfg.covariance.productClock.applyToDoppler              = true;
cfg.covariance.productClock.applyToCarrier              = true;
cfg.covariance.productClock.crossCodeDoppler            = false;
cfg.covariance.productClock.carrierPolicy               = 'timeVaryingProductResidualOnly';
cfg.covariance.productClock.dopplerPolicy               = 'sharedClockDriftProductBlock';
cfg.covariance.productClock.ensureSPD                   = true;
cfg.covariance.productClock.jitter_m2                   = 1e-12;

% --- Stage 84: Doppler/product-covariance correctness hardening ---
% Doppler R diagonal policy: trackingOnlyPlusBlock (no pre-add, helper owns all drift cov).
% Carrier: arc-reference status metadata.
% J2 ratio diagnostics: sigma/RMS and sigma/max for process-noise adequacy.
cfg.diagnostics.dynamicsMismatch.computeJ2Ratios       = true;
cfg.diagnostics.carrierDopplerConsistency.status       = 'notImplementedGuarded';

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

% --- Stage 70/75: baseline carrier attitude ambiguity resolution ---------------
% Controlled raw-L1 receiver-baseline integer ambiguity resolver for the
% lever-arm attitude system.  External initial attitude used ONLY as search
% centre; it is NOT the primary calibration source when integer fix succeeds.
% Stage 75: hardened gates (minArcEpochs=60, ratioThreshold=3.0), float-distance
% guard (maxFloatDistance_cycles=0.25), per-baseline classification, and honest
% GNSS-only claim gate (requireAllForGnssOnlyClaim=true).
cfg.estimator.diffAtt.ambiguityResolution.enable                       = true;
cfg.estimator.diffAtt.ambiguityResolution.method                       = 'constrainedBaselineIntegerSearch';
cfg.estimator.diffAtt.ambiguityResolution.signal                       = 'L1';
cfg.estimator.diffAtt.ambiguityResolution.searchHalfWidth_cycles       = 5;
cfg.estimator.diffAtt.ambiguityResolution.minArcEpochs                 = 60;
cfg.estimator.diffAtt.ambiguityResolution.rmsThreshold_cycles          = 0.10;
cfg.estimator.diffAtt.ambiguityResolution.ratioThreshold               = 3.0;
cfg.estimator.diffAtt.ambiguityResolution.useExternalReferenceAsSearchCenter = true;
cfg.estimator.diffAtt.ambiguityResolution.allowExternalReferenceFallback     = true;
% Stage 75 hardening fields
cfg.estimator.diffAtt.ambiguityResolution.maxFloatDistance_cycles      = 0.25;
cfg.estimator.diffAtt.ambiguityResolution.requireAllForGnssOnlyClaim   = true;
cfg.estimator.diffAtt.ambiguityResolution.partialFixPolicy             = 'useFixedOnlyOrExplicitMixed';
cfg.estimator.diffAtt.ambiguityResolution.phaseBiasStatus              = 'syntheticKnownZero';  % Stage 76: synthetic zero biases
cfg.estimator.diffAtt.ambiguityResolution.falseFixClassification       = 'screenedNotFormal';

% --- Stage 76: dual-frequency baseline attitude AR and dimension contract ------
% When enabledMask=[true,true] (L1+L2), dual-frequency raw integer-pair AR is
% attempted. Carrier-IF integer fixing remains explicitly unsupported and false.
% Wide-lane used as consistency screening gate only (not full WL/NL fixing).
% Stage 77: enabledByFrequency derived from cfg.signals.enabledMask in finalizeConfig.
cfg.estimator.diffAtt.ambiguityResolution.maxWideLaneFloatDistance_cycles   = 0.5;
cfg.estimator.diffAtt.ambiguityResolution.differentialIonosphereInBaselineAr = 'neglectedShortBaselineV1';
% Dimension contract: nSpaceAssets > 1 is unsupported and guarded in ConfigFactory.
% nTowers and nReceivers are dimension-supported; active count reported in summary.
% Signal list is centralized; cfg.signals.names, frequencyHz, enabledMask set by finalizeConfig.

% --- Coarse attitude initializer (Stage 17) — DISABLED in Stage 69+ -----
% Disabled: 'coarseBaselineIntegerSearch' was injecting a potentially wrong
% initial attitude into the quaternion EKF.  The differential calibration with
% externalInitialAttitude reference + Stage 70 integer fix is now the attitude source.
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

% --- Stage 81: Scientific profile (informational; central config owned by finalizeConfig) ---
% All fields are defaults only; finalizeConfig() overwrites if not set by user.
% cfg.scientificProfile.mode = 'singleAssetOneWaySyntheticClosedV1';
% cfg.scientificProfile.claimLevel = 'controlledSynthetic';
% cfg.scientificProfile.allowRealWorldClaim = false;  % MUST stay false until real parsers added


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
    % Stage 82: active scenario dynamics are owned by ScenarioPresets
    % (j2Rk4 truth + twoBody EKF mismatch; Stage 82 default); no temporary J2 override.
    cfg.diagnostics.ekfDynamics.enable  = true;
    cfg.validation.stageAllToggles         = true;
    if oo_v1_envAllToggles_
        cfg.validation.invokedMainScript = true;
        if oo_v1_envStage_ > 0
            cfg.validation.validationStage = oo_v1_envStage_;
        end
    end
end
if ~isempty(oo_v1_envCompile_) && ismember(oo_v1_envCompile_, {'require','auto','never'})
    cfg.report.compileTex = oo_v1_envCompile_;
end

% --- Stage 85: Formal synthetic validation campaign ---
% Enabled automatically when OO_V1_ALL_TOGGLES=true; off by default.
% ConfigFactory Stage 85 block owns all cfg.validation.scientificCampaign.* defaults.
if stageAllToggles || oo_v1_envAllToggles_
    cfg.validation.scientificCampaign.enable     = true;
    cfg.validation.scientificCampaign.profile    = 'light';
    cfg.validation.scientificCampaign.seedList   = [85, 185, 285];
    cfg.validation.scientificCampaign.duration_s = 900;
end

% Apply scenario preset after all toggles (preset overrides what it needs to).
if isfield(cfg,'scenario') && isfield(cfg.scenario,'name') && ...
        strcmp(cfg.scenario.name,'singleAssetCarrierAttitude')
    cfg = revgnss.ScenarioPresets.apply(cfg, 'singleAssetCarrierAttitude');
end

% ============================================================
% REGRESSION-FIXTURE OVERRIDES (no run here; returns the resolved cfg)
% ============================================================
% The gate runs the simulation itself and reads out.summary + sim.simData, so
% skip the report/PDF/MAT build entirely for speed and determinism.
cfg.report.writePdf   = false;
cfg.report.writeMat   = false;
cfg.report.compileTex = 'never';
cfg.plots.showFigures = false;

if nargin >= 1 && ~isempty(durationOverride_s)
    cfg.simulation.duration_s = durationOverride_s;   % SMOKE duration; else full 3600 s
end
end
