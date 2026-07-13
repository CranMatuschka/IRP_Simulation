function cfg = masterConfig()
%MASTERCONFIG  The single canonical oo_v1 configuration.
%   Reads top to bottom: base defaults (baseConfig), then user toggles grouped by
%   topic, then the scenario assembly that runs after the toggles (and may override
%   a few of them), then a contract check. Value derivations (frequency masks, the
%   time vector, thresholds) run later in ConfigFactory.finalizeConfig.
%
%   v1 limitations: signal-dependent hardware delays / DCB are zero (IF residual not
%   modelled); the Doppler ionosphere-rate term is not modelled; the PR/Doppler
%   shared tower-clock cross-covariance is ignored (block-diagonal R).
    thisDir   = fileparts(mfilename('fullpath'));   % .../oo_v1/config
    oo_v1Root = fileparts(thisDir);                 % .../oo_v1
    addpath(oo_v1Root);                             % +revgnss builders
    addpath(thisDir);                               % baseConfig (same folder)

cfg = baseConfig();   % structural + default base; no +revgnss config-layer dependency

% ================================================================
% USER TOGGLES  (grouped by topic; applied before the scenario assembly)
% ================================================================

%% Simulation run
% How long the run is and how densely diagnostics are stored. 'compact' keeps a
% small MAT while preserving all science; 'sampledFull'/'full' add matrix snapshots.
cfg.simulation.duration_s = 3600*4;
cfg.simulation.dt_s       = 1;
cfg.diagnostics.storage.mode                = 'compact';
cfg.diagnostics.storage.snapshot.enable     = true;
cfg.diagnostics.storage.snapshot.interval_s = 300;

%% Scenario
% One estimated GEO spacecraft; nSpaceAssets is the swarm switch (1 = ground-only,
% >1 = helix ISL swarm aiding the primary, primary clock scaling ~1/sqrt(N-1)).
cfg.scenario.name         = 'singleAssetCarrierAttitude';
cfg.scenario.nSpaceAssets = 1;        % helix ISL swarm (5 secondaries) -> ~3 cm / ~50 ps
cfg.scenario.nTowers      = 12;       % 12 real ground sites (baseConfig towerDefs); wide
                                      % lat/lon spread breaks the single-GEO radial<->clock
                                      % degeneracy. Set 5 for the frozen-golden network.
cfg.scenario.orbitClass   = 'GEO';    % 'GEO' | 'MEO' | 'LEO'
% nReceivers is owned by the scenario assembly below (4-antenna cross pattern);
% do not set it here. nReceivers=1 -> attitude off; >1 -> attitude on.

%% Report output
% What the run writes and in which style. 'clockExact' compiles a LaTeX PDF (needs
% pdflatex/xelatex); 'clockStyle' and 'default' are MATLAB-figure fallbacks.
cfg.report.writePdf              = true;   % false = skip PDF (fast testing)
cfg.report.writeMat              = true;   % false = skip MAT (fast testing)
cfg.plots.showFigures            = false;
cfg.report.version               = '2.02'; % report FORMAT/content version (shown in the PDF)
cfg.report.runVersion            = 1;      % per-RUN tag -> output folder Report_v%03d_HHMM
cfg.report.baseOutputDir         = fullfile(oo_v1Root, 'output');
cfg.report.overwrite             = true;
cfg.report.style                 = 'latex';      % 'latex' | '' (simple)
cfg.report.layout                = 'clockExact';  % 'clockExact' | 'clockStyle' | 'default'
cfg.report.writeTex              = true;
cfg.report.compileTex            = 'require';     % 'require' | 'auto' | 'never'
cfg.report.zoomLastSeconds       = 120;    % zoom plots show the last 120 s (fixed window)
cfg.report.compactFinalReport    = true;
cfg.report.suppressStageSections = true;
cfg.report.deduplicateFigures    = true;

%% Signals and frequency
% enabledMask is the single frequency control; finalizeConfig derives twoFrequency
% and the per-frequency code/carrier/AR masks from it. [true,true] = L1+L2.
cfg.signals.enabledMask = [true, true];

%% Physics, relativity and Doppler
% One master enable per effect (truth/model pair slaved in expandEnableToggles below).
% Light-time is iterative one-way; the relativistic clock term is guarded off in v1.
cfg.physics.sagnac.enable             = true;
cfg.physics.lightTime.enable          = true;
cfg.physics.lightTime.mode            = 'iterativeOneWay';
cfg.physics.lightTime.iterations      = 2;
cfg.physics.lightTime.tolerance_s     = 1e-12;
cfg.physics.relativity.shapiro.enable = true;
cfg.physics.relativity.clock.enable   = true;   % disabled/warned in finalize: not validated v1
cfg.physics.doppler.enable            = true;
cfg.measurements.doppler.enable       = true;
cfg.measurements.doppler.useInEKF     = true;

%% Atmosphere
% Troposphere and ionosphere truth+model with a shared master enable each. Both use
% the synthetic simpleMapped model; ionosphere adds a stochastic scintillation term.
cfg.errors.troposphere.enable              = false;
cfg.errors.troposphere.modelType           = 'simpleMapped';
cfg.errors.troposphere.stochastic.enable   = true;
cfg.errors.ionosphere.enable               = false;
cfg.errors.ionosphere.modelType            = 'simpleMapped';
cfg.errors.ionosphere.stochastic.enable    = true;
cfg.errors.ionosphere.scintillation.enable = true;

%% Error sources
% Hardware delay, multipath, tower survey, antenna PCV and correlated noise are off
% by default; antenna PCO is on (synthetic constants). Inter-frequency biases are zero.
cfg.measurements.codeNoise.model   = 'constant';
cfg.errors.hardwareDelay.enable    = false;
cfg.errors.multipath.enable        = false;
cfg.effects.towerSurvey.enable     = false;
cfg.effects.antennaPCO.enable      = true;   % synthetic calibrated constants (no ANTEX)
cfg.effects.antennaPCV.enable      = false;  % no ANTEX; enabled in all-toggle runs only
cfg.effects.correlatedNoise.enable = false;
cfg.biases.interFrequency.code.truth.L1_m    = 0;
cfg.biases.interFrequency.code.truth.L2_m    = 0;
cfg.biases.interFrequency.code.model.L1_m    = 0;
cfg.biases.interFrequency.code.model.L2_m    = 0;
cfg.biases.interFrequency.carrier.truth.L1_m = 0;
cfg.biases.interFrequency.carrier.truth.L2_m = 0;
cfg.biases.interFrequency.carrier.model.L1_m = 0;
cfg.biases.interFrequency.carrier.model.L2_m = 0;

%% Clocks
% The receiver clock is stochastic; the tower clocks are deterministic (set in the
% scenario assembly) and corrected by a delayed, noisy broadcast product whose
% age-grown uncertainty enters R.
cfg.clock.receiver.deterministic  = false;
cfg.estimator.estimateTowerClocks = false;
cfg.clocks.tower.product.mode                   = 'truthHistoryProductNoisy';
cfg.clocks.tower.product.updateInterval_s       = 30;
cfg.clocks.tower.product.latency_s              = 5;
cfg.clocks.tower.product.sigmaBias_m            = 0.01;   % ~0.033 ns: IGS-class ground network
cfg.clocks.tower.product.sigmaDrift_mps         = 0.0002; % ~0.0007 ppb/s
cfg.clocks.tower.product.covBiasDrift           = 0;
cfg.clocks.tower.product.validity_s             = 120;
cfg.clocks.tower.product.addToR                 = true;
cfg.clocks.tower.product.sharedErrorCorrelation = true;

% Slave each single .enable above to its internal truth/model pair (read by ~150
% pipeline sites), so the config surface cannot manufacture a truth != model mismatch.
cfg = expandEnableToggles(cfg, { ...
    'physics.sagnac', 'physics.lightTime', 'physics.relativity.shapiro', ...
    'physics.relativity.clock', 'physics.doppler', ...
    'errors.troposphere', 'errors.ionosphere', 'errors.hardwareDelay', 'errors.multipath', ...
    'effects.towerSurvey', 'effects.antennaPCO', 'effects.antennaPCV' });

%% Measurement observables
% DIAGNOSTIC ionosphere-free rows: these build L1/L2 IF code/carrier rows for the REPORT
% and consistency diagnostics ONLY -- NOT a second EKF path. Per CodeIonoFreeRowBuilder:
% "EKF integration uses the existing CodeMeasurementBuilder codeMode path." The EKF's
% actual ionosphere handling is the codeMode chosen by cfg.atmosphere.ionosphereFree /
% .estimateIono above; the '.useInEkf' field below is diagnostic metadata, not a toggle
% that puts a second (double-counting) IF row into the filter. Carrier phase runs as a
% float-ambiguity EKF (one ambiguity per tower x receiver x signal, no fixing).
cfg.measurements.code.ionosphereFreeRows.enable     = true;
cfg.measurements.code.ionosphereFreeRows.useInEkf    = true;
cfg.diagnostics.codeIonoFreeRows.enable              = true;
cfg.diagnostics.codeIonoFreeConsistency.enable       = true;
cfg.measurements.carrier.ionosphereFreeRows.enable   = true;
cfg.measurements.carrier.ionosphereFreeRows.useInEkf = true;
cfg.diagnostics.carrierIonoFreeRows.enable           = true;
cfg.measurements.carrierPhase.enable    = true;
cfg.measurements.carrierMode            = 'ekfFloat';
cfg.estimation.ambiguityMode            = 'floatPerTowerReceiverSignal';
cfg.estimation.ambiguity.initialSigma_m = 100;

%% Estimator: dynamics
% EKF translational prediction. Default constant-velocity here; the scenario assembly
% below switches it to J2 to match the truth propagator family.
cfg.estimator.dynamics.mode          = 'constantVelocity';
cfg.estimator.dynamics.fdPositionStep_m   = 1.0;
cfg.estimator.dynamics.fdVelocityStep_mps = 1e-3;

%% Estimator: attitude
% Quaternion nominal + error-state EKF driven by calibrated differential carrier from
% the antenna cross pattern. The coarse integer-search initialiser is disabled.
cfg.estimator.attitude.parameterization           = 'quaternionErrorState';
cfg.estimator.attitude.maxErrorStateInjection_rad = deg2rad(10);
cfg.diagnostics.attitudeCovarianceReset.enable    = true;
cfg.estimator.attitude.primaryMode                = 'carrierLeverArmQuaternionEkf';
cfg.estimator.attitudeCarrierMode                 = 'calibratedDifferentialAmbiguity';
cfg.estimator.diffAtt.calibWin_s                  = 60;
cfg.estimator.diffAtt.referenceMode               = 'externalInitialAttitude';
cfg.estimator.diffAtt.referenceSigma_deg          = 0.1;
cfg.estimator.attitude.carrierSignal              = 'L1';   % documentary (report builder)
cfg.estimator.attitude.useRawCarrierForAttitude   = true;   % documentary (report builder)
cfg.estimator.attitudeInitMode                    = 'none';
cfg.estimator.attitudeInit.search.windowDeg               = [2; 2; 2];
cfg.estimator.attitudeInit.search.stepDeg                 = [0.5; 0.5; 0.5];
cfg.estimator.attitudeInit.search.maxCandidates           = 729;
cfg.estimator.attitudeInit.search.ratioThreshold          = 1.20;
cfg.estimator.attitudeInit.search.ambiguousRatioThreshold = 1.01;
cfg.estimator.attitudeInit.search.improvementRatioThreshold = 1.05;
cfg.estimator.attitudeInit.search.maxRmsCycles            = 0.30;
cfg.estimator.attitudeInitShadow.enable                   = false;

%% Estimator: ambiguity resolution
% Guarded raw-carrier integer fixing for the receiver-baseline attitude system, with
% hardened gates. Carrier ionosphere-free integer fixing is explicitly unsupported.
cfg.estimator.integerAmbiguity.enable                      = true;
cfg.estimator.integerAmbiguity.mode                        = 'controlledRawCarrier';
cfg.estimator.integerAmbiguity.minArcLength_s              = 300;
cfg.estimator.integerAmbiguity.maxSigma_cycles             = 0.15;
cfg.estimator.integerAmbiguity.maxDistanceToInteger_cycles = 0.20;
cfg.estimator.integerAmbiguity.maxResidualRmsIncrease_m    = 0.01;
cfg.estimator.integerAmbiguity.fixVariance_cycles2         = 1e-4;
cfg.estimator.integerAmbiguity.resetOnSlip                 = true;
cfg.estimator.diffAtt.ambiguityResolution.enable                       = true;
cfg.estimator.diffAtt.ambiguityResolution.method                       = 'constrainedBaselineIntegerSearch';
cfg.estimator.diffAtt.ambiguityResolution.signal                       = 'L1';
cfg.estimator.diffAtt.ambiguityResolution.searchHalfWidth_cycles       = 5;
cfg.estimator.diffAtt.ambiguityResolution.minArcEpochs                 = 60;
cfg.estimator.diffAtt.ambiguityResolution.rmsThreshold_cycles          = 0.10;
cfg.estimator.diffAtt.ambiguityResolution.ratioThreshold               = 3.0;
cfg.estimator.diffAtt.ambiguityResolution.useExternalReferenceAsSearchCenter = true;
cfg.estimator.diffAtt.ambiguityResolution.allowExternalReferenceFallback     = true;
cfg.estimator.diffAtt.ambiguityResolution.maxFloatDistance_cycles      = 0.25;
cfg.estimator.diffAtt.ambiguityResolution.requireAllForGnssOnlyClaim   = true;
cfg.estimator.diffAtt.ambiguityResolution.partialFixPolicy             = 'useFixedOnlyOrExplicitMixed';
cfg.estimator.diffAtt.ambiguityResolution.phaseBiasStatus              = 'syntheticKnownZero';
cfg.estimator.diffAtt.ambiguityResolution.falseFixClassification       = 'screenedNotFormal';
cfg.estimator.diffAtt.ambiguityResolution.maxWideLaneFloatDistance_cycles    = 0.5;
cfg.estimator.diffAtt.ambiguityResolution.differentialIonosphereInBaselineAr = 'neglectedShortBaselineV1';

%% Carrier slip detection
% Model-step-compensated jump test: expected tower-clock-product steps are removed
% before comparing to threshold, so arcs stay robust across product update intervals.
cfg.measurements.carrier.slipDetection.enable                = true;
cfg.measurements.carrier.slipDetection.minEpochsBeforeDetect = 3;
cfg.measurements.carrier.slipDetection.resetSigma_m          = 100;
cfg.measurements.carrier.slipDetection.action                = 'resetAndSkip';
cfg.carrierSlip.enable                          = true;
cfg.carrierSlip.method                          = 'modelStepCompensatedResidualJump';
cfg.carrierSlip.threshold_m                     = 0.10;
cfg.carrierSlip.minArcLength_s                  = 300;
cfg.carrierSlip.productStepCompensation         = true;
cfg.carrierSlip.atmosphereStepCompensation      = true;
cfg.carrierSlip.antennaStepCompensation         = true;
cfg.carrierSlip.hardwareStepCompensation        = true;
cfg.carrierSlip.diffAttitudeBaselineMode        = true;
cfg.carrierSlip.resetAmbiguityOnConfirmedSlip   = true;
cfg.carrierSlip.ignoreKnownProductBoundaryJumps = false;
cfg.carrierSlip.logDiagnostics                  = true;
cfg.carrierSlip.syntheticSlipInjection.enable        = false;
cfg.carrierSlip.syntheticSlipInjection.time_s        = 1800;
cfg.carrierSlip.syntheticSlipInjection.towerIndex    = 1;
cfg.carrierSlip.syntheticSlipInjection.receiverIndex = 2;
cfg.carrierSlip.syntheticSlipInjection.signal        = 'L1';
cfg.carrierSlip.syntheticSlipInjection.jumpCycles    = 1;

%% Covariance
% Code rows from the same tower/product epoch share the product clock error, so R
% carries a block term; the product-clock closure adds age-weighted drift covariance.
cfg.covariance.sharedErrors.enable                   = true;
cfg.covariance.sharedErrors.mode                     = 'blockTowerClockProduct';
cfg.covariance.sharedErrors.applyTowerClockToCode    = true;
cfg.covariance.sharedErrors.applyTowerClockToCarrier = false;
cfg.covariance.sharedErrors.applyTowerClockToDoppler = false;
cfg.covariance.sharedErrors.carrierPolicy            = 'arcBiasAbsorbsConstantProductBias';
cfg.covariance.sharedErrors.dopplerPolicy            = 'frameConsistentV2';
cfg.covariance.sharedErrors.ensureSPD                = true;
cfg.covariance.sharedErrors.jitter_m2                = 1e-12;
cfg.covariance.sharedErrors.reportDiagnostics        = true;
cfg.measurements.doppler.modelLevel                     = 'frameConsistentV2';
cfg.measurements.doppler.includeTowerRotationalVelocity = true;
cfg.measurements.doppler.includeSagnacRate              = false;
cfg.measurements.doppler.includeLightTimeRate           = false;
cfg.measurements.doppler.includeTowerClockProductDrift  = true;
cfg.measurements.doppler.jacobianMode                   = 'analyticRangeRateV1';
cfg.covariance.productClock.enable           = true;
cfg.covariance.productClock.applyToCode      = true;
cfg.covariance.productClock.applyToDoppler   = true;
cfg.covariance.productClock.applyToCarrier   = true;
cfg.covariance.productClock.crossCodeDoppler = false;
cfg.covariance.productClock.carrierPolicy    = 'timeVaryingProductResidualOnly';
cfg.covariance.productClock.dopplerPolicy    = 'sharedClockDriftProductBlock';
cfg.covariance.productClock.ensureSPD        = true;
cfg.covariance.productClock.jitter_m2        = 1e-12;

%% Troposphere ZWD EKF state
% Off in the default report: the per-tower zenith wet delay state is weakly observable
% in this GEO geometry, so it is kept as a diagnostic tool only.
cfg.estimation.troposphereMode         = 'none';
cfg.estimation.tropoZwd.initialSigma_m = 0.3;
cfg.estimation.tropoZwd.sigma_ss_m     = 0.05;
cfg.estimation.tropoZwd.tau_s          = 3600;

%% Diagnostics
% Ambiguity-readiness, arc-evidence and covariance/dynamics audits. These add metadata
% only (no EKF math); arc-separated flags here are re-enabled by the scenario assembly.
cfg.diagnostics.carrierIonoFreeAmbiguityTraceability.enable = false;
cfg.diagnostics.wideLaneNarrowLane.enable                   = false;
cfg.diagnostics.ambiguityFixingReadiness.enable             = false;
cfg.diagnostics.ambiguityReadinessEvidence.enable           = false;
cfg.diagnostics.carrierArcEvidence.enable                   = false;
cfg.estimator.arcSeparatedAmbiguities.enable                = false;
cfg.diagnostics.arcSeparatedAmbiguities.enable              = false;
cfg.estimator.enforceCarrierArcConsistency.enable           = false;
cfg.diagnostics.carrierArcConsistencyEnforcement.enable     = false;
cfg.diagnostics.pluginRegistry.enable                       = true;
cfg.diagnostics.ekfInnovationAccounting.enable              = true;
cfg.diagnostics.ekfDynamics.enable                          = true;
cfg.diagnostics.dynamicsMismatch.computeJ2Ratios            = true;
cfg.diagnostics.carrierDopplerConsistency.status            = 'notImplementedGuarded';

%% Validation and post-run checks
% How unsupported features are handled, and the short known-ambiguity attitude
% validation run appended after the main run (validation only, not integer fixing).
cfg.validation.unsupportedFeaturePolicy   = 'disableWithWarning';
cfg.validation.fullSuiteRun               = false;
cfg.estimator.runKnownAmbiguityValidation = true;

% ================================================================
% SCENARIO ASSEMBLY  (runs after the toggles; may override a few of them)
%   Inlined from ScenarioPresets.singleAssetCarrierAttitude. The
%   geoRealWorldTruthComparison preset stays in +revgnss/ScenarioPresets.m.
% ================================================================

%% Receiver geometry and lever arms
% Build the multi-antenna cross pattern (represented-only assets mirror the primary)
% and set nReceivers from it.
if ~isfield(cfg,'assets') || isempty(cfg.assets)
    cfg.assets = cfg.asset;
end
nRecvReq_ = 1;
if isfield(cfg,'scenario') && isfield(cfg.scenario,'nReceivers') && cfg.scenario.nReceivers > 1
    nRecvReq_ = cfg.scenario.nReceivers;
end
arms = [];
if isfield(cfg,'asset') && isfield(cfg.asset,'receiverLeverArms_body_m')
    candArms_ = cfg.asset.receiverLeverArms_body_m;
    if isnumeric(candArms_) && size(candArms_,1) == 3 && size(candArms_,2) > 1
        arms = candArms_;
    end
end
if ~isempty(arms) && size(arms,2) ~= nRecvReq_
    error('ScenarioPresets:receiverGeometryMismatch', ...
        'cfg.scenario.nReceivers=%d but receiverLeverArms_body_m has %d columns.', ...
        nRecvReq_, size(arms,2));
end
if isempty(arms)
    arms = revgnss.ReceiverGeometry.defaultLeverArms(nRecvReq_);
end
cfg.scenario.name         = 'singleAssetCarrierAttitude';
cfg.scenario.nReceivers   = size(arms,2);
cfg.asset.receiverLeverArms_body_m = arms;
cfg.asset.receiverLeverArm_body_m  = arms(:,1);
cfg.assets(1).receiverLeverArms_body_m = arms;
cfg.assets(1).receiverLeverArm_body_m  = arms(:,1);

%% Attitude estimation setup
% Drive attitude from carrier partials only (code/Doppler attitude sensitivity off) so
% the observation matrix and row metadata stay consistent.
cfg.estimator.estimateAttitude                   = true;
cfg.estimator.estimateAngularRate                = false;
cfg.estimator.estimateAttitudeFromPseudorange    = false;
cfg.estimator.estimateAngularRateFromPseudorange = false;
cfg.estimator.attitude.useCarrierPartials        = true;
cfg.estimator.attitude.useCodePartials           = false;
cfg.estimator.attitude.useDopplerPartials        = false;

%% Initial state and covariance
% Initial attitude error and the diagonal covariance/process-noise seeds for the run.
cfg.estimator.P0_euler_rad             = deg2rad(5);
cfg.estimator.P0_omega_radps           = 1e-12;
% WP3: torque-budget-justified attitude process noise (~1e-7 rad/s^2), replacing the
% over-optimistic 1e-10. alpha = tau / I from cfg.asset (Wertz environmental torques).
cfg.estimator.sigma_angAccel_radps2    = revgnss.ConfigFactory.angAccelFromTorqueBudget_( ...
    cfg.asset.inertia_kgm2, cfg.asset.residualDisturbanceTorque_Nm);
cfg.estimator.initialError.euler_deg   = [1; -1; 0.5];
cfg.estimator.initialError.omega_radps = [0; 0; 0];

%% Carrier / ambiguity and arc handling (scenario)
% Re-assert the carrier float-ambiguity EKF, ensure a slip threshold exists, and turn
% on arc-separated ambiguities with arc-consistency enforcement.
cfg.measurements.carrierPhase.enable = true;
cfg.measurements.carrierMode         = 'ekfFloat';
cfg.estimation.ambiguityMode         = 'floatPerTowerReceiverSignal';
cfg.measurements.carrier.slipDetection.enable = true;
if ~isfield(cfg.measurements.carrier.slipDetection,'threshold_m')
    cfg.measurements.carrier.slipDetection.threshold_m           = 0.1;
    cfg.measurements.carrier.slipDetection.minEpochsBeforeDetect = 3;
    cfg.measurements.carrier.slipDetection.resetSigma_m          = 100;
    cfg.measurements.carrier.slipDetection.action                = 'resetAndSkip';
end
cfg.estimator.arcSeparatedAmbiguities.enable            = true;
cfg.estimator.enforceCarrierArcConsistency.enable       = true;
cfg.diagnostics.arcSeparatedAmbiguities.enable          = true;
cfg.diagnostics.carrierArcConsistencyEnforcement.enable = true;
cfg.diagnostics.carrierArcEvidence.enable               = true;

%% Observability diagnostics (scenario)
% Enable attitude-observability, receiver-geometry, and innovation-accounting reporting.
cfg.diagnostics.attitudeObservability.enable   = true;
cfg.diagnostics.receiverGeometry.enable        = true;
cfg.diagnostics.ekfInnovationAccounting.enable = true;
if isfield(cfg,'diagnostics') && isfield(cfg.diagnostics,'attitudeEvidence')
    cfg.diagnostics.attitudeEvidence.enable = true;
end

%% Orbit and truth-estimation dynamics
% Truth and EKF share the J2 family (not a mismatch); the estimator is imperfect only
% from realistic sources (initial state, noise, clocks, atmosphere, process noise).
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
cfg.estimator.dynamics.mode  = 'j2';   % same family as truth
cfg.validation.enforceModelFamilyConsistency = true;

%% Tower clocks
% Ground tower clocks are deterministic here (no per-tower stochastic realisation).
for k = 1:numel(cfg.towers)
    cfg.towers(k).clock.deterministic = true;
end

%% Inter-spacecraft links (ISL)
% Single asset -> no links (ground-only golden path). Helix swarm -> one-way ISL
% code+Doppler from each represented secondary aids the primary EKF (product-aided, honest).
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
    cfg.measurements.isl.timing.enable = false;
    cfg.measurements.isl.code.enable    = true;
    cfg.measurements.isl.code.useInEKF  = true;
    cfg.measurements.isl.code.sigma_m   = 0.3;    % one-way ISL code thermal 1-sigma [m]
    cfg.measurements.isl.doppler.enable   = true;
    cfg.measurements.isl.doppler.useInEKF = true;
    cfg.measurements.isl.doppler.sigma_mps = 0.05;
    cfg.measurements.isl.carrier.enable   = true; % diagnostic-only until ambiguity states exist
    cfg.measurements.isl.carrier.useInEKF = false;
    cfg.measurements.isl.product.enable        = true;
    cfg.measurements.isl.product.sigmaPos_m    = 0.03;   % ~3 cm SLR-class precise reference orbit
    cfg.measurements.isl.product.sigmaClock_m  = 0.02;   % ~67 ps reference clock product
    cfg.measurements.isl.twoWay.enable          = false;
    cfg.measurements.isl.twoWay.range.enable    = false;
    cfg.measurements.isl.twoWay.range.useInEKF  = false;
    cfg.measurements.isl.twoWay.doppler.enable  = false;
    cfg.measurements.isl.twoWay.doppler.useInEKF = false;
end
if isfield(cfg,'measurements') && isfield(cfg.measurements,'twstft')
    cfg.measurements.twstft.enable = false;
end

%% Atmosphere realism + ionosphere handling  (SINGLE SOURCE OF TRUTH)
% The physically-realistic troposphere/ionosphere/scintillation overlay and the
% ionosphere-handling choice live HERE, not in run_oo_v1. These are DATA toggles;
% the overlay itself is applied in ConfigFactory.finalizeConfig (via
% applyAtmosphereProfile) so the Stage-85 golden opts out with the single flag below.
%
%   atmosphere.realistic
%     true  -> Saastamoinen/Niell troposphere (+per-tower ZWD EKF) and a
%              diurnal+stochastic ionosphere (Klobuchar + higher-order + gated
%              scintillation): non-cancelling, physically-sized truth-model residuals.
%     false -> matched synthetic atmosphere (truth==model; the frozen-golden physics).
%
%   Ionosphere handling -- TWO orthogonal boolean TOGGLES (only meaningful when
%   realistic==true). Both false = the default RAW dual-frequency processing.
%
%   atmosphere.ionosphereFree  (default false)
%     false -> RAW dual-frequency: L1 and L2 are kept as SEPARATE uncombined code rows,
%              each carrying its own ionosphere (Klobuchar-corrected residual left in,
%              largely absorbed by the receiver clock). NB this is the old 'single' name
%              -- it is NOT one frequency; both L1 and L2 are used, just uncombined.
%              BEST for the default 5-tower geometry (fewest unknowns; converges).
%     true  -> L1/L2 IONOSPHERE-FREE combination: removes the 1st-order iono per link,
%              but halves the code rows and amplifies noise x2.98 -> only pays off when
%              the geometry is measurement-rich (~10+ well-spread towers).
%
%   atmosphere.estimateIono  (default false)
%     true  -> add a per-tower slant-ionosphere EKF STATE (removes iono, keeps all rows,
%              but adds nTowers unknowns -> over-parameterises a thin geometry). Best only
%              with a rich tower network. Mutually exclusive with ionosphereFree.
%
% NOTE: ionosphere ELIMINATION is per dual-frequency link (tower-count independent);
% POSITION accuracy is geometry-limited. At 5 towers RAW wins; IF / iono-state recover
% and then surpass it once enough well-distributed towers make the geometry rich.
% (These map to cfg.measurements.codeMode / cfg.estimation.ionosphereMode inside
% ConfigFactory.applyAtmosphereProfile. codeMode='singleFrequency' is the internal name
% for RAW uncombined dual-frequency -- again, not one frequency.)
cfg.atmosphere.realistic      = true;
cfg.atmosphere.ionosphereFree = false;   % L1/L2 ionosphere-free combination
cfg.atmosphere.estimateIono   = false;   % per-tower slant-ionosphere EKF state

% ================================================================
% Contract check (asserts only; returns cfg unchanged)
% ================================================================
cfg = validateMasterConfig(cfg);
