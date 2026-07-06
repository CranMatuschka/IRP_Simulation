function cfg = masterConfig()
%MASTERCONFIG  The single canonical oo_v1 configuration (clarity refactor, Phase 1).
%   THE one place the scientific config lives. Reads top-to-bottom:
%     1. seed structure + low-level defaults from config/baseConfig.m
%     2. every human-facing value and toggle (this file)
%     3. the singleAssetCarrierAttitude scenario preset (inlined below)
%     4. contract checks via validateMasterConfig (returns cfg unchanged)
%   No dependency on the +revgnss config layer. Value derivations (e.g.
%   enabledByFrequency from enabledMask, the time vector, thresholds) remain in
%   ConfigFactory.finalizeConfig, run once by the simulation. The all-toggle and
%   validation-campaign env overrides remain in the runner (retired in Phase 6).
%
%   v1 known limitations (unchanged): signal-dependent hardware delays / DCB set to
%   zero (IF residual not modelled); Doppler ionosphere-rate term not modelled;
%   PR/Doppler shared tower-clock cross-covariance ignored (block-diagonal R).
    thisDir   = fileparts(mfilename('fullpath'));   % .../oo_v1/config
    oo_v1Root = fileparts(thisDir);                 % .../oo_v1
    addpath(oo_v1Root);                             % +revgnss builders
    addpath(thisDir);                               % baseConfig (same folder)

cfg = baseConfig();   % structural + default base (config/baseConfig.m); no +revgnss config-layer dep

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
cfg.report.version        = '2.01';   % report FORMAT/content version (shown in the PDF)
cfg.report.runVersion     = 1;        % per-RUN version tag -> output folder Report_v%03d_HHMM
cfg.report.baseOutputDir  = fullfile(oo_v1Root, 'output');
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
cfg.report.zoomLastSeconds       = 120;   % zoom plots show the LAST 120 s (fixed window, not a fraction)
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
cfg.scenario.nSpaceAssets = 3;        % 1 = single asset; >1 = helix ISL swarm aiding the primary
cfg.scenario.orbitClass   = 'GEO';    % 'GEO' | 'MEO' | 'LEO'
%                                      % Truth-estimation separation: j2Rk4 truth + j2 EKF (SAME model family, not a mismatch)

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

% --- Geometry / relativity (one master enable per effect; Phase 2.1) ------------
cfg.physics.sagnac.enable                = true;
cfg.physics.lightTime.enable             = true;
cfg.physics.lightTime.mode               = 'iterativeOneWay';
cfg.physics.lightTime.iterations         = 2;
cfg.physics.lightTime.tolerance_s        = 1e-12;
cfg.physics.relativity.shapiro.enable    = true;
cfg.physics.relativity.clock.enable      = true;  % disabled/warned in finalize: not validated v1

% --- Atmosphere (one master enable per effect; Phase 2.1) -----------------------
cfg.errors.troposphere.enable             = true;
cfg.errors.troposphere.modelType          = 'simpleMapped';
cfg.errors.troposphere.stochastic.enable  = true;
cfg.errors.ionosphere.enable              = true;
cfg.errors.ionosphere.modelType           = 'simpleMapped';
cfg.errors.ionosphere.stochastic.enable   = true;
cfg.errors.ionosphere.scintillation.enable = true;

% --- Measurement noise ------------------------------------------
cfg.measurements.codeNoise.model = 'constant';

% --- Hardware / multipath (one master enable per effect; Phase 2.1) -------------
cfg.errors.hardwareDelay.enable = false;
cfg.errors.multipath.enable     = false;

% --- Survey / antenna (one master enable per effect; Phase 2.1) -----------------
cfg.effects.towerSurvey.enable  = false;
% Stage 68: antenna PCO enabled by default (synthetic calibrated constants; no ANTEX).
cfg.effects.antennaPCO.enable   = true;
% PCV kept disabled by default (no ANTEX; set to true in all-toggle run only).
cfg.effects.antennaPCV.enable   = false;

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
cfg.physics.doppler.enable            = true;

% --- Phase 2.1: one master enable per effect -> internal truth/model pair --------
% Every effect above sets a SINGLE .enable, so the config surface can no longer
% manufacture a truth!=model mismatch. expandEnableToggles slaves the internal
% .truth.enable/.model.enable pair (still read by ~150 pipeline sites) to that value;
% migrating those read-sites to read .enable directly is a later cleanup commit.
cfg = expandEnableToggles(cfg, { ...
    'physics.sagnac', 'physics.lightTime', 'physics.relativity.shapiro', ...
    'physics.relativity.clock', 'physics.doppler', ...
    'errors.troposphere', 'errors.ionosphere', 'errors.hardwareDelay', 'errors.multipath', ...
    'effects.towerSurvey', 'effects.antennaPCO', 'effects.antennaPCV' });

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

% ============================================================
% Scenario preset: singleAssetCarrierAttitude
%   Inlined from ScenarioPresets.apply (Phase 1.2). Applies AFTER the toggle
%   block above, exactly as the old apply() did. ReceiverGeometry.defaultLeverArms
%   is kept as a structural builder. The geoRealWorldTruthComparison preset stays
%   in +revgnss/ScenarioPresets.m for run_geo_realworld_truth_comparison.m.
% ============================================================

% Multi-asset swarm: nSpaceAssets>1 is supported as a represented-only helix swarm
% that aids the PRIMARY (asset 1) EKF via ISL. Only the primary is estimated
% (enforced in MultiAssetConfig.normalize); secondaries are represented-only truth.
if ~isfield(cfg,'assets') || isempty(cfg.assets)
    cfg.assets = cfg.asset;
end

nReq79_ = 4;
if isfield(cfg,'scenario') && isfield(cfg.scenario,'nReceivers') && cfg.scenario.nReceivers > 1
    nReq79_ = cfg.scenario.nReceivers;
end
arms = [];
if isfield(cfg,'asset') && isfield(cfg.asset,'receiverLeverArms_body_m')
    cand79_ = cfg.asset.receiverLeverArms_body_m;
    if isnumeric(cand79_) && size(cand79_,1) == 3 && size(cand79_,2) > 1
        arms = cand79_;
    end
end
if ~isempty(arms) && size(arms,2) ~= nReq79_
    error('ScenarioPresets:receiverGeometryMismatch', ...
        'cfg.scenario.nReceivers=%d but receiverLeverArms_body_m has %d columns.', ...
        nReq79_, size(arms,2));
end
if isempty(arms)
    arms = revgnss.ReceiverGeometry.defaultLeverArms(nReq79_);
end

cfg.scenario.name         = 'singleAssetCarrierAttitude';
% nSpaceAssets is preserved from the user toggle above (default 1). Setting it > 1
% activates the represented-only helix swarm; do NOT force it back to 1 here.
cfg.scenario.nReceivers   = size(arms,2);
cfg.asset.receiverLeverArms_body_m = arms;
cfg.asset.receiverLeverArm_body_m  = arms(:,1);
cfg.assets(1).receiverLeverArms_body_m = arms;
cfg.assets(1).receiverLeverArm_body_m  = arms(:,1);

% Attitude estimation. Use preferred Stage 56 controls exclusively so the
% legacy estimateAttitudeFromPseudorange flag does not cause H/metadata
% inconsistencies (code rows must not declare attitude sensitivity while
% H attitude columns are zero).
cfg.estimator.estimateAttitude                    = true;
cfg.estimator.estimateAngularRate                 = false;
cfg.estimator.estimateAttitudeFromPseudorange     = false; % code OFF via preferred
cfg.estimator.estimateAngularRateFromPseudorange  = false;
cfg.estimator.attitude.useCarrierPartials         = true;  % preferred: carrier ON
cfg.estimator.attitude.useCodePartials            = false; % preferred: code OFF
cfg.estimator.attitude.useDopplerPartials         = false; % preferred: Doppler OFF

% Initial attitude covariance and error.
cfg.estimator.P0_euler_rad              = deg2rad(5);
cfg.estimator.P0_omega_radps            = 1e-12;
cfg.estimator.sigma_angAccel_radps2     = 1e-10;
cfg.estimator.initialError.euler_deg    = [1; -1; 0.5];
cfg.estimator.initialError.omega_radps  = [0; 0; 0];

% Carrier measurements and ambiguity mode.
cfg.measurements.carrierPhase.enable = true;
cfg.measurements.carrierMode         = 'ekfFloat';
cfg.estimation.ambiguityMode         = 'floatPerTowerReceiverSignal';

% Carrier slip detection (keep defaults if already set).
cfg.measurements.carrier.slipDetection.enable = true;
if ~isfield(cfg.measurements.carrier.slipDetection,'threshold_m')
    cfg.measurements.carrier.slipDetection.threshold_m           = 0.1;
    cfg.measurements.carrier.slipDetection.minEpochsBeforeDetect = 3;
    cfg.measurements.carrier.slipDetection.resetSigma_m          = 100;
    cfg.measurements.carrier.slipDetection.action                = 'resetAndSkip';
end

% Stage 53/54: arc-separated ambiguities and arc consistency enforcement.
cfg.estimator.arcSeparatedAmbiguities.enable             = true;
cfg.estimator.enforceCarrierArcConsistency.enable        = true;
cfg.diagnostics.arcSeparatedAmbiguities.enable           = true;
cfg.diagnostics.carrierArcConsistencyEnforcement.enable  = true;
cfg.diagnostics.carrierArcEvidence.enable                = true;

% Observability and geometry diagnostics.
cfg.diagnostics.attitudeObservability.enable = true;
cfg.diagnostics.receiverGeometry.enable      = true;
cfg.diagnostics.ekfInnovationAccounting.enable = true;
if isfield(cfg,'diagnostics') && isfield(cfg.diagnostics,'attitudeEvidence')
    cfg.diagnostics.attitudeEvidence.enable = true;
end

% Truth-estimation separation (SAME model family): J2 truth propagator + J2 EKF dynamics.
% Truth and estimator share the J2 family; the estimator does NOT use a deliberately
% degraded (two-body) propagator. Its imperfection comes from realistic sources only:
% the perturbed initial state + covariance, noisy code/carrier/Doppler measurements,
% the stochastic receiver clock + delayed/noisy tower-clock products, atmosphere
% residuals, antenna calibration uncertainty, float carrier ambiguities, and
% residual-acceleration process noise (sigma_accel_mps2 — covers SRP / third body /
% higher-order gravity, none of which are in this J2-only truth). At GEO equatorial the
% J2 accel is ~8.3e-6 m/s2 (radial only). cfg.orbit.truth.mode is centrally owned.
% An explicit reduced-dynamics/mismatch experiment is a NON-default analysis mode
% (set validation.analysisType='explicitMismatchAnalysis' + allowTruthModelMismatch=true).
cfg.orbit.useOrbitPropagator = true;
cfg.orbit.altitudeMean_m     = 35786000;
cfg.orbit.inclination_rad    = 0;
cfg.orbit.raan_rad           = 0;
cfg.orbit.trueAnomaly0_rad   = 23 * pi/180;
cfg.orbit.epochGMST_rad      = 0;
if ~isfield(cfg.orbit,'truth') || ~isfield(cfg.orbit.truth,'mode') || ...
        strcmp(cfg.orbit.truth.mode,'stationaryEcef')
    cfg.orbit.truth.mode = 'j2Rk4';
end
cfg.orbit.mode               = cfg.orbit.truth.mode;
cfg.estimator.dynamics.mode  = 'j2';   % SAME family as truth (truth-estimation separation, not mismatch)
% MD Stage 88/89/96: enforce truth/EKF dynamics family parity for this default run.
% Safe now that both are J2; assertModelFamilyConsistent runs in finalizeConfig.
cfg.validation.enforceModelFamilyConsistency = true;

% Stage 67: stochastic tower clocks — non-perfect broadcast correction.
% Each tower clock is driven by the Brown-Hwang two-state process.
% The EKF uses noisyCorrection: broadcast product with uncertainty sigma.
for k = 1:numel(cfg.towers)
    cfg.towers(k).clock.deterministic = false;
end

% --- Inter-spacecraft links (ISL) -------------------------------------------
% Single feature control: cfg.scenario.nSpaceAssets. With one asset there are no
% links (ISL off, golden single-asset path). With a helix swarm (nSpaceAssets>1)
% the primary (asset 1) EKF is aided by one-way ISL code+Doppler from every
% secondary "beacon in space": an extra pseudorange with a non-vertical line of
% sight that breaks the ground-only radial/clock degeneracy. Secondaries are
% represented-only precise-orbit references (productAidedExternal); their product
% uncertainty enters R so the aiding is honest, not perfect-truth. Two-way range
% and TWSTFT stay diagnostic (no EKF rows).
if cfg.scenario.nSpaceAssets <= 1
    cfg.measurements.isl.enable = false;
    cfg.measurements.isl.timing.enable = false;
    cfg.measurements.isl.twoWay.enable = false;
    cfg.measurements.isl.twoWay.range.enable   = false;
    cfg.measurements.isl.twoWay.range.useInEKF  = false;
    cfg.measurements.isl.twoWay.doppler.enable  = false;
    cfg.measurements.isl.twoWay.doppler.useInEKF = false;
else
    cfg.measurements.isl.enable        = true;
    cfg.measurements.isl.transmitters  = 'all';   % aid from every secondary
    cfg.measurements.isl.receiverAssetIndex = 1;  % into the primary only
    cfg.measurements.isl.warmup_s      = 300;     % acquire ISL after the ground fix converges
    cfg.measurements.isl.timing.enable = true;
    cfg.measurements.isl.timing.mode   = 'oneWayLightTime';
    cfg.measurements.isl.code.enable    = true;
    cfg.measurements.isl.code.useInEKF  = true;
    cfg.measurements.isl.code.sigma_m   = 1.0;    % one-way ISL code thermal 1-sigma [m]
    cfg.measurements.isl.doppler.enable   = true;
    cfg.measurements.isl.doppler.useInEKF = true;
    cfg.measurements.isl.doppler.sigma_mps = 0.05;
    cfg.measurements.isl.carrier.enable   = true; % diagnostic-only until ambiguity states exist
    cfg.measurements.isl.carrier.useInEKF = false;
    % Represented-secondary precise-orbit/clock product uncertainty (honest aiding).
    cfg.measurements.isl.product.enable        = true;
    cfg.measurements.isl.product.sigmaPos_m    = 0.05;
    cfg.measurements.isl.product.sigmaClock_m  = 0.03;   % ~100 ps reference clock product
    % Two-way ISL range is ill-conditioned into this near-degenerate filter; keep it
    % diagnostic (double-counting guard also forbids it alongside one-way code).
    cfg.measurements.isl.twoWay.enable          = false;
    cfg.measurements.isl.twoWay.range.enable    = false;
    cfg.measurements.isl.twoWay.range.useInEKF  = false;
    cfg.measurements.isl.twoWay.doppler.enable  = false;
    cfg.measurements.isl.twoWay.doppler.useInEKF = false;
end
if isfield(cfg,'measurements') && isfield(cfg.measurements,'twstft')
    cfg.measurements.twstft.enable = false;
end

% --- Phase 1.4: contract-check the assembled config (asserts only; returns cfg unchanged) ---
cfg = validateMasterConfig(cfg);
