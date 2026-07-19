function cfg = masterConfig(mode)
%MASTERCONFIG  THE single oo_v1 configuration file (edit only this one).
%   Reads top to bottom: the structural defaults (the i_baseDefaults subfunction at the
%   BOTTOM of this file -- formerly config/baseConfig.m, now inlined so there is ONE config
%   file), then the user toggles grouped by topic, then the scenario assembly that runs
%   after the toggles (and may override a few of them), then a contract check. Value
%   derivations (frequency masks, the time vector, thresholds) run later in
%   ConfigFactory.finalizeConfig.
%
%   masterConfig('baseOnly') returns JUST the structural defaults (skips the toggles and
%   scenario). revgnss.ConfigFactory.defaultConfig calls that, so the derived/test/frozen-
%   golden configs are all built on the same defaults, from this one file.
%
%   v1 limitations: signal-dependent hardware delays / DCB are zero (IF residual not
%   modelled); the Doppler ionosphere-rate term is not modelled; the PR/Doppler
%   shared tower-clock cross-covariance is ignored (block-diagonal R).
    thisDir   = fileparts(mfilename('fullpath'));   % .../oo_v1/config
    oo_v1Root = fileparts(thisDir);                 % .../oo_v1
    addpath(oo_v1Root);                             % +revgnss builders
    addpath(thisDir);                               % baseConfig (same folder)

cfg = i_baseDefaults();   % structural + default base (inlined as the local subfunction below)
if nargin >= 1 && strcmp(mode,'baseOnly'); return; end   % ConfigFactory.defaultConfig / goldens stop here

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
cfg.scenario.nTowers      = 5;        % 5-tower default (frozen-golden network). baseConfig
                                      % defines 12 real sites; set nTowers=12 for the wide
                                      % network that breaks the single-GEO radial<->clock
                                      % degeneracy (towers 6-12 are the extra real sites).
cfg.scenario.orbitClass   = 'GEO';    % 'GEO' | 'MEO' | 'LEO'
% Receiver antennas. The scenario assembly + finalizeConfig rebuild the lever-arm
% cross from this and turn attitude estimation ON (>1) or OFF (==1). 4 = headline
% 4-antenna cross pattern (attitude ON, the stated objective); set to 1 for the
% ground-only single-antenna knob (G5S1R1, attitude OFF).
cfg.scenario.nReceivers   = 4;

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
% Monte-Carlo filter-consistency evidence written to the run .out log. A single run
% gives one NEES/NIS sample; chi-squared consistency needs an ensemble. Default OFF
% (goldens byte-identical; N extra full runs). Set enable=true to append an averaged
% NIS/NEES-vs-chi-square-band verdict; the shipped filter is conservative-by-design and is
% expected to read BELOW the band (under-confident, honest). Tune nSeeds/duration_s below.
cfg.report.monteCarlo.enable     = false;   % <- true to append MC consistency evidence
cfg.report.monteCarlo.nSeeds     = 12;
cfg.report.monteCarlo.duration_s = 900;

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
cfg.physics.relativity.clock.enable   = false;  % Gated relativistic clock-rate offset on the
                                                % TRUTH receiver clock (~+46.6 us/day / ~2.3 km over a
                                                % 4 h GEO run). Default OFF: the constant offset is fully
                                                % absorbed by the estimated clock-drift state (observable),
                                                % so for the circular GEO it does not bias the solution;
                                                % set true to make the truth physically complete.
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
% Receiver oscillator + clock realism (both single strings, changed right here).
% clockType picks the oscillator class ('CESIUM1' | 'OCXO' | 'RUBIDIUM' | 'TCXO');
% templateSource picks the h-coefficient realism: 'legacy' = idealised/optimistic (the
% frozen-golden and headline default) | 'jowTable2p1' = realistic, literature-anchored
% (JOW Table 2.1 real caesium / OCXO2 -> the sub-100 ps timing result degrades honestly).
% Change either ONE string; ConfigFactory.finalizeConfig rebuilds every clock from them.
cfg.asset.clockType               = 'CESIUM1';
cfg.clock.templateSource          = 'legacy';
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

%% Estimator: SRP scale-coefficient state (primary only). Gated, DEFAULT OFF.
% When enable && useInEKF, the EKF appends ONE state s -- a dimensionless multiplier on a
% reference SRP acceleration (Cr = s*refCr) -- and estimates it from the along-track
% trajectory bending. This is the PROPER fix for an un-modelled SRP force-gap: it lets the
% filter recover the missing acceleration (NEES->~1 with a smooth estimate) instead of
% bluntly inflating the orbit process noise. Requires dynamics.mode ~= 'constantVelocity'
% (else s is unobservable). Off -> no state appended -> golden byte-identical.
cfg.estimator.srpCoefficient.enable              = false;
cfg.estimator.srpCoefficient.useInEKF            = false;
cfg.estimator.srpCoefficient.initScale           = 1.0;    % s0 prior mean (nominal Cr multiplier)
cfg.estimator.srpCoefficient.initSigma           = 0.1;    % 1-sigma prior on s
cfg.estimator.srpCoefficient.procNoise           = 1e-9;   % random-walk 1-sigma [1/sqrt(s)]
cfg.estimator.srpCoefficient.refCr               = 1.3;    % reference Cr (matches truth default)
cfg.estimator.srpCoefficient.refAreaToMass_m2pkg = 0.02;   % reference A/m [m^2/kg]
cfg.estimator.srpCoefficient.fdScaleStep         = 10.0;   % FD step for d/ds (linearity -> exact)

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
% Attitude process noise (angular-acceleration 1-sigma). EMPIRICALLY RETUNED to 3e-4.
% A Q-tuning sweep on the attitude-estimating config (nadir GEO, S1R4, 3600 s) has a clear
% minimum here: attitude tail RMS is 0.1344 deg at the old torque-budget value (~1e-7),
% 0.0707 deg at 3e-4, and rises again to 0.1391 deg at 1e-3 -- a classic Q bowl. The
% physical torque-budget value tau/I ~ 1e-7 (revgnss.ConfigFactory.angAccelFromTorqueBudget_)
% is ~3000x too TIGHT for the ESTIMATOR at the weakly-observed radial<->clock attitude wall:
% it over-trusts the constant-rate attitude prediction and lags the carrier measurements.
% Looser Q here both LOWERS the attitude error and makes P more conservative. The torque-
% budget helper is retained (it still sizes the ConfigFactory attitude presets and documents
% the physical floor). Single-antenna / positionClockOnly runs leave this inert (the EKF
% freezes the attitude Q block when attitude is not estimated), so the single-antenna golden
% is unaffected; the 4-antenna headline and realism goldens move with this value.
cfg.estimator.sigma_angAccel_radps2    = 3e-4;   % empirical Q optimum (see sweep note above)
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

%% Two-way time transfer (TWSTFT into the EKF)
% Tower<->spacecraft two-way time transfer: a REAL EKF observable that measures the
% clock difference (b_rx - b_tower) with the geometric range cancelled by reciprocity,
% so it constrains the RECEIVER CLOCK directly and breaks the GEO radial<->clock
% degeneracy that limits the one-way uplink. This is the literature-standard route to
% the sub-100 ps regime (Merlo & Nanzer 2023; EM-WaTT/TWSTFT; T2L2 — all two-way).
%   enable/useInEKF -> flip BOTH true to add the two-way rows to the filter.
% Default OFF so the frozen goldens stay byte-identical; set true to enable this.
% sigma_m is the two-way time uncertainty (~0.03 m = 100 ps); the achievable receiver-
% clock accuracy is floored by max(sigma_m, tower-clock-product sigma) — a better
% ground reference clock is needed to push below ~100 ps (honest reference-clock limit).
cfg.measurements.twoWayTimeTransfer.enable   = false;   % <- set true (with useInEKF) to enable
cfg.measurements.twoWayTimeTransfer.useInEKF = false;
cfg.measurements.twoWayTimeTransfer.towers   = 'all';   % which ground towers are two-way capable
cfg.measurements.twoWayTimeTransfer.sigma_m  = 0.03;    % two-way time uncertainty 1-sigma [m] (~100 ps)

%% Per-SECONDARY two-way time transfer (P3'). Default OFF.
% The per-satellite twin of the primary two-way link above: a ground-tower<->SECONDARY
% two-way exchange pins each secondary's clock b_tx DIRECTLY (H +1 on the secondary clock
% state, no position column), decoupled from the secondary radial -- the only lever that
% improves the per-satellite ABSOLUTE clock (and radial, via the WP5 range row). REQUIRES
% the secondary to TRANSMIT, which the plain reverse-GNSS uplink does NOT assume -> this is
% an explicit "with per-satellite two-way time transfer" enhancement, not the baseline
% geometry; label results accordingly. Needs estimated secondary clocks (estimateMode
% 'clocks'/'position'). Fuses with the WP5 one-way ground row (independent draws). sigma_m
% ~0.03 m = 100 ps lab-grade; operational two-way is ~0.3-1 ns (0.1-0.3 m).
cfg.measurements.secondaryTwoWayTimeTransfer.enable                     = false;
cfg.measurements.secondaryTwoWayTimeTransfer.useInEKF                   = false;
cfg.measurements.secondaryTwoWayTimeTransfer.towers                     = 'all';   % 'all' or vector of tower indices
cfg.measurements.secondaryTwoWayTimeTransfer.sigma_m                    = 0.03;    % 1-sigma [m] (~100 ps lab-grade)
cfg.measurements.secondaryTwoWayTimeTransfer.warmup_s                   = 0;
cfg.measurements.secondaryTwoWayTimeTransfer.includeReciprocityResidual = false;  % model motion non-reciprocity (both sides)
cfg.measurements.secondaryTwoWayTimeTransfer.reciprocitySigma_m         = 0.005;  % residual non-reciprocity 1-sigma [m]
cfg.measurements.secondaryTwoWayTimeTransfer.conservativeProductCorrelation = true;% inflate tower-product var by epochs/interval

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

%% Orbit class  (GEO | MEO | LEO — SINGLE switch)
% Change cfg.scenario.orbitClass (set under %% Scenario above) to move the whole
% run between orbit classes. config/orbitClassConfig overrides altitude,
% inclination, RAAN, initial true anomaly and the SNC process noise for MEO/LEO;
% 'GEO' (default) is a strict no-op so the frozen goldens stay byte-identical.
cfg = orbitClassConfig(cfg);

%% Realism grade  (v4 realism fixes — SINGLE opt-in switch)
% false (default) -> the current headline config; the frozen goldens are unaffected.
% true  -> overlay config/realismGradeConfig: realistic JOW caesium clock, IGS-RTS tower
%          product sigma, C/N0 code weighting, multipath/hardware/PCV/survey/DCB truth
%          systematics, relativistic clock, honest measurement floors, luni-solar process
%          noise, and realistic ISL product sigma. Makes the run physically representative
%          rather than an idealised twin. See docs/scientific_correctness_review_v4.md.
%          NEW-PHYSICS WPs (truth luni-solar propagator, unknown inter-antenna carrier
%          biases, EOP/solid-Earth tide) are applied by their own dedicated builders.
cfg.realism.grade = false;
% Per-effect sub-toggles (consulted ONLY when realism.grade = true). Each defaults true,
% i.e. the full realism overlay; set any to false to keep realism grade but drop that ONE
% effect. realismGradeConfig gates each block on these and handles the truth/model re-
% expansion and the coupled luni-solar/process-noise unit internally, so they are safe to
% flip individually. With grade = false these are inert (goldens byte-identical).
cfg.realism.include.clock                   = true;   % R-1  realistic caesium clock template
cfg.realism.include.towerProductSigma       = true;   % R-4  IGS-RTS tower product sigma
cfg.realism.include.cn0                      = true;   % M7   C/N0 code-noise weighting
cfg.realism.include.multipath               = true;   % R-5  colored-GM code multipath (truth)
cfg.realism.include.hardwareDelay           = true;   % R-5  per-tower hardware group delay (truth)
cfg.realism.include.antennaPCV              = true;   % R-5  uncalibrated antenna PCV (truth)
cfg.realism.include.towerSurvey             = true;   % R-5  static ENU survey error (truth)
cfg.realism.include.dcb                      = true;   % R-5  inter-frequency code bias (truth)
cfg.realism.include.honestFloors            = true;   % R-10 honest measurement sigma floors
cfg.realism.include.luniSolar               = true;   % R-3  matched luni-solar+SRP + retuned SNC (coupled)
cfg.realism.include.relativity              = true;   % WP-D relativistic receiver-clock offset
cfg.realism.include.islProductSigma         = true;   % ISL  realistic secondary product sigma
cfg.realism.include.eop                      = true;   % R-8  uncorrected EOP frame residual (truth)
cfg.realism.include.solidEarthTide          = true;   % R-8  solid-Earth tide (truth)
cfg.realism.include.interAntennaCarrierBias = true;   % R-6  unknown inter-antenna carrier bias (truth)
if isfield(cfg,'realism') && isfield(cfg.realism,'grade') && cfg.realism.grade
    cfg = realismGradeConfig(cfg);
end

% --- Resolve the multi-asset mode preset BEFORE the estimateMode-dependent overlays and
% the contract check, so applyInjectTruthSideDynamics and validateMasterConfig see the
% granular toggles the switch expands to. No-op for 'fast' (the default). finalizeConfig
% re-resolves it for ordering-safety when nSpaceAssets/mode are set after masterConfig().
cfg = revgnss.ConfigFactory.applyMultiAssetMode(cfg);

% --- Optional matched-force / per-tower-hardware overlays (gated; no-op unless enabled) ------
% Standalone config/ functions (like realismGradeConfig): masterConfig applies them for the
% default path; a run script can also call them after masterConfig() once it sets the toggle.
cfg = applyLuniSolar(cfg);        % cfg.perturbations.sunMoon.enable
cfg = applyInjectTruthSideDynamics(cfg);   % Guard B: one-sided truth-side gap (no-op unless swarm 'position')
cfg = applyPerTowerHwBias(cfg);   % cfg.errors.hardwareDelay.perTowerBias.enable

% ================================================================
% Contract check (asserts only; returns cfg unchanged)
% ================================================================
cfg = validateMasterConfig(cfg);
end

% ======================================================================
% i_baseDefaults  The structural default library (formerly config/baseConfig.m).
%   Every field's default lives here; masterConfig overrides only what a run
%   changes. ConfigFactory.defaultConfig calls masterConfig('baseOnly') to get
%   just these defaults (used by the derived/test/golden configs).
% ======================================================================
function cfg = i_baseDefaults()
%BASECONFIG  Structural + default base config (relocated from ConfigFactory.defaultConfig).
%   Moves the config base out of the 2512-line +revgnss/ConfigFactory
%   monolith into the config/ folder. revgnss.ConfigFactory.defaultConfig now
%   delegates here, so the 20+ derived configs and tests keep working, while the
%   canonical masterConfig depends on config/, not the monolith. Structural builders
%   (makeClockConfig, SignalDefinition, Constants, GeometryUtils) are kept as calls;
%   masterConfig seeds from this base and owns every human-facing value/toggle on top.
    addpath(fileparts(fileparts(mfilename('fullpath'))));  % oo_v1 root, for +revgnss builders

% defaultConfig  GEO-1 honest off=off baseline (clarity refactor C-5).
%
% The base default injects NO error effects: troposphere, ionosphere, hardware delay,
% multipath, tower survey and antenna PCV/PCO are all OFF, and the EKF uses RAW
% measurement rows (ionosphere-free rows are opt-in and require L1+L2). Turning an
% effect on adds a REAL error the estimator does not perfectly cancel (it uses the
% estimated state, clock products and estimated atmosphere). Named presets set what
% they need on top: masterConfig (the canonical run), atmosphereConfig,
% matchedErrorBaselineConfig (tropo+iono matched), cleanConfig (explicit all-off).
% (Matched vs off atmosphere cancels in the innovation, so this change does not affect
% the pre-existing zero-noise idealConfig NIS test, which is inconsistent on main too.)
% Tower clocks: perfectTruth (validation mode).
% Code noise: 0.3 m sigma.
% Doppler: enabled with useInEKF=true; requires physics.doppler.model.enable=true
%   for EKF use (finalizeConfig disables useInEKF if physics not set).
% Carrier phase: diagnostic (not in EKF) by default; set carrierMode='ekfFloat'
%   and estimation.ambiguityMode='floatPerTowerSignal' to use in EKF.
% Ionosphere mapping: 'simpleSecant' (1/sin, backward-compatible).
% Validation policy: 'error' (unsupported features throw by default).

% --- Simulation timing ----------------------------------------
cfg.simulation.dt_s       = 1.0;
cfg.simulation.duration_s = 3600.0;
cfg.simulation.seed       = 42;

% --- RNG stream independence ----------------------------------
% When enable=true (default) every physically-independent noise source draws
% from its own identity-keyed substream (models.noise.RngRegistry) rooted at
% cfg.simulation.seed, instead of sharing one draw order. This gives true
% per-tower / per-asset / per-source independence and ORDER-independence:
% toggling one effect or changing tower visibility cannot perturb any other
% source's realization (enabling one-factor-at-a-time and common-random-number
% studies). Set enable=false to reproduce the legacy shared-stream behaviour
% bit-for-bit. engine is the counter-based generator used for the substreams.
cfg.rng.independentStreams.enable = true;
cfg.rng.independentStreams.engine = 'threefry';

% --- Scenario topology (simple count fields) ------------------
cfg.scenario.nTowers    = 5;
cfg.scenario.nReceivers = 1;
cfg.scenario.nSpaceAssets = 1;

% --- GEO asset (stationary in ECEF) ---------------------------
geoLat_rad = 0.0;
geoLon_rad = 23.0 * pi / 180;
geoAlt_m   = 35786000.0;
r_geo      = models.frames.GeometryUtils.geodetic2ecef(geoLat_rad, geoLon_rad, geoAlt_m);

cfg.asset.name                    = 'GEO-1';
cfg.asset.mass_kg                 = 70;
% Attitude process-noise budget. The angular-acceleration 1-sigma driving the
% EKF attitude Q is derived from a residual disturbance-torque budget alpha = tau / I.
% Representative small-satellite values (Wertz, "Spacecraft Attitude Determination and
% Control", 1978, environmental-torque chapters: gravity-gradient, solar-radiation
% pressure, residual-magnetic; at GEO SRP dominates). Conservative choices: a modest
% principal inertia and a residual (post-modelling) disturbance torque, giving
% alpha ~ 1e-7 rad/s^2 — the higher (more conservative) end of the plausible range,
% so the attitude covariance is not artificially over-confident.
cfg.asset.inertia_kgm2               = 10;      % principal moment of inertia [kg m^2]
cfg.asset.residualDisturbanceTorque_Nm = 1e-6;  % residual disturbance torque 1-sigma [N m]
cfg.asset.r_ecef_m                = r_geo;
cfg.asset.v_ecef_mps              = [0; 0; 0];   % geostationary in ECEF
cfg.asset.attitude_euler_rad      = [0; 0; 0];
cfg.asset.angularRate_body_radps  = [0; 0; 0];
% Lever arms: zero by default (single antenna, attitude unobservable).
% finalizeConfig() sets cross-pattern arms when nReceivers > 1.
cfg.asset.receiverLeverArm_body_m  = [0; 0; 0];
cfg.asset.receiverLeverArms_body_m = [0; 0; 0];

% Clock scaling factors (applied by makeClockConfig)
cfg.clockScaling.globalBiasFactor    = 1.0;
cfg.clockScaling.globalFreqFactor    = 1.0;
cfg.clockScaling.globalNoiseFactor   = 1.0;
cfg.clockScaling.receiverNoiseFactor = 1.0;
cfg.clockScaling.towerNoiseFactor    = 1.0;
% Clock h-coefficient source. 'legacy' = original (optimistic) numbers, kept for
% exact reproducibility; 'jowTable2p1' = re-anchored to JOW Table 2.1 (less optimistic
% OCXO/CESIUM). Canonical selector is cfg.clock.templateSource (below); this mirror is
% read by the config-build-time makeClockConfig calls before cfg.clock exists.
cfg.clockScaling.templateSource      = 'legacy';

% Asset receiver clock fields (simple config fields)
% CESIUM1 (Cesium beam / H-maser class) is the physically-correct on-board clock for
% a precision GEO nav/comms spacecraft. OCXO is a ground / control-segment oscillator
% and was unrealistic here. Note this does NOT materially change the radial error (the
% clock process noise is not the radial driver -- radial=clock is a geometry/observability
% degeneracy, not a clock-Q limit); it is a realism correction only.
cfg.asset.clockName    = 'SpaceReceiverClock';
cfg.asset.clockType    = 'CESIUM1';
cfg.asset.clockFactors = struct( ...
    'biasFactor',1,'freqFactor',1,'noiseFactor',1, ...
    'roleNoiseFactor', cfg.clockScaling.receiverNoiseFactor, ...
    'h2Factor',1,'h1Factor',1,'h0Factor',1,'hMinus1Factor',1,'hMinus2Factor',1);
cfg.asset.clock = revgnss.ConfigFactory.makeClockConfig( ...
    cfg.asset.clockType, 100, cfg.asset.clockFactors, cfg.clockScaling);
cfg.asset.clock.name          = 'RxClock';
cfg.asset.clock.deterministic = true;
cfg.asset.clock.bias_s        = 0.0;
cfg.asset.clock.fracFreq      = 0.0;
cfg.asset.assetIndex = 1;
cfg.asset.estimated = true;
cfg.asset.stateOwner = 'primaryEKF';
cfg.assets = cfg.asset;

% --- Orbit propagation owner fields --------------------------
% defaultConfig may remain stationary; active report presets set truth/estimator modes.
cfg.orbit.useOrbitPropagator = false;
cfg.orbit.mode = 'stationaryEcef';
cfg.orbit.truth.mode = 'stationaryEcef';
cfg.orbit.truth.availableModes = {'twoBodyRk4','j2Rk4'};
% Performance switch: precompute full trajectory once (vectorized) instead
% of re-integrating from t=0 at every epoch (O(N^2)). Science unchanged.
cfg.orbit.truth.cache.enable = true;
cfg.orbit.truth.cache.mode   = 'precomputeVector';
% Truth-only luni-solar third-body + SRP perturbations (R-3). Default OFF -> the truth
% propagator is byte-identical J2. When enabled the TRUTH orbit gains sun+moon third-body
% (~7e-6 m/s^2 at GEO, comparable to J2) and cannonball SRP (~1e-7) while the EKF stays J2,
% creating a genuine force-model gap (its process-noise sigma is sized in realismGradeConfig).
% See +models/+orbit/OrbitPerturbations. Enters the TRUTH propagator only (not the EKF).
cfg.orbit.truth.perturbations.luniSolar.enable     = false;
cfg.orbit.truth.perturbations.srp.enable           = false;
cfg.orbit.truth.perturbations.epochJD_TT           = 2451545.0;   % J2000 TT (sun/moon ephemeris epoch)
cfg.orbit.truth.perturbations.srp.Cr               = 1.3;         % radiation-pressure coefficient
cfg.orbit.truth.perturbations.srp.areaToMass_m2pkg = 0.02;        % area-to-mass ratio [m^2/kg]
cfg.orbit.truth.perturbations.srp.shadow           = 'cylindrical';

% Single convenience switch for the MATCHED Sun+Moon third-body + SRP force model (truth AND
% EKF), default OFF. When true, i_applyLuniSolar() (end of file) enables both the truth-side and
% the EKF-side perturbations with matched epoch/Cr/area-to-mass and retunes the residual-
% acceleration SNC to 1e-6 -- the same coupled unit realism's include.luniSolar applies, but
% available standalone without the rest of the realism overlay. Default false -> frozen goldens
% stay byte-identical. (The individual truth/EKF enables above remain for a deliberate one-sided
% force gap; this switch is the matched, no-gap version.)
cfg.perturbations.sunMoon.enable = false;

% --- Swarm formation (helix) truth ---------------------------
% One master control: cfg.scenario.nSpaceAssets. When it is > 1 (and an orbit
% propagator is active) the secondary assets are placed on a bounded
% Clohessy-Wiltshire projected-circular (helix) relative orbit around the
% primary chief and propagated with the SAME dynamics as the primary, so the
% swarm truth is physically real (not dead-reckoned). Only the primary
% (asset 1) is EKF-estimated; secondaries are represented-only truth that can
% provide ISL aiding. cfg.measurements.isl.* is the separate feature toggle for
% feeding those links into the EKF.
cfg.formation.mode        = 'helix';   % only supported formation mode
cfg.formation.baseline_m  = 1000.0;    % inter-satellite separation [m] (>500 m); changeable
cfg.formation.phase0_rad  = 0.0;       % phase of the first secondary on the projected-circular ring

% --- WP1: per-asset truth persistence (swarm runs only) -------
% When nSpaceAssets > 1, ReportRunner persists every asset's truth trajectory
% (position/velocity/attitude/clock) into the report .mat as `multiAssetTruth`,
% so per-satellite truth-vs-truth geometry -- inter-asset baselines (relative)
% and each asset's absolute position vs Earth -- can be compared offline. This
% is the represented-only secondary truth that already exists in memory but was
% previously dropped at the save boundary; only asset 1 is EKF-estimated, so no
% secondary ESTIMATE is produced here (that is the multiAssetEstimation upgrade).
% Inert for single-asset runs (nothing is written) -> golden-safe.
cfg.multiAsset.recordTruth   = true;   % persist per-asset truth for swarm (nSpaceAssets>1) runs
cfg.multiAsset.truthStride_s = 60.0;   % decimation stride [s] to keep long-run .mat small; <=0 = every truth epoch

% --- WP3: secondary-asset CLOCK estimation (bias+drift as EKF states) ---------
% 'off'      (WP<=2) secondaries are represented-only truth; their clock cancels
%            in the one-way ISL innovation (today's behaviour). Golden-safe.
% 'clocks'   (WP3)   estimate each secondary's [b_tx, bdot_tx] as 2 EKF states,
%            appended LAST. Requires nSpaceAssets>=2 AND isl.enable +
%            isl.code.useInEKF (validated). Secondary POSITIONS stay product (WP4).
% 'position' (P1'/WP4) estimate each secondary's full [r,v,b,bdot]; requires
%            towersObserveSecondaries (the near-radial position observable) on top of the
%            'clocks' preconditions. Superset of 'clocks'.
% NOTE: secondary truth clocks only wander when cfg.asset.clock.deterministic=false;
% with the default deterministic clock the estimation target is identically 0.
cfg.multiAsset.estimateMode = 'off';
% --- Convenience preset over the granular estimation toggles (resolved by
% revgnss.ConfigFactory.applyMultiAssetMode, in BOTH masterConfig and finalizeConfig):
%   'fast'   (default) the classic product-beacon one-way-ISL swarm. PASSTHROUGH -- does
%            not touch estimateMode/towersObserveSecondaries/twoWayISL, so it is byte-
%            identical to setting them by hand and the goldens are unaffected.
%   'honest' bundles the joint per-satellite estimation (estimateMode='position' +
%            towersObserveSecondaries + twoWayISL + ISL observability). Swarm-only
%            (nSpaceAssets>=2). Flip this ONE field to switch fast<->honest.
cfg.multiAsset.mode = 'fast';
% Loose a-priori on the secondary clock states (init draw AND stated P0 share these,
% so initial NEES is O(1)). Deliberately << tower's 1000 m / 10 m/s: a GEO atomic
% clock's broadcast a-priori is far better than an unknown ground beacon, yet loose
% enough to stay conservative/under-confident.
cfg.multiAsset.secondaryClock.initSigma_m        = 100.0;
cfg.multiAsset.secondaryClock.initSigmaDrift_mps = 1.0;
% P1'/WP4: prior on each secondary's estimated [r,v] (init draw AND stated P0 share
% these, so initial NEES is O(1)). estimateMode='position' promotes each secondary to
% a full [r,v,b,bdot] asset; requires towersObserveSecondaries (the position observable).
cfg.multiAsset.secondaryOrbit.initSigmaPos_m     = 100.0;   % [m] per axis
cfg.multiAsset.secondaryOrbit.initSigmaVel_mps   = 0.1;     % [m/s] per axis

% --- WP5: ground-tower -> secondary observation rows (absolute clock anchor) ---
% When true (and estimateMode='clocks'), each visible ground tower adds a
% pseudorange row observing a secondary's clock bias b_tx at a near-radial LOS
% against the KNOWN (product-corrected) tower clock. This anchors b_tx to the
% ground ABSOLUTELY -- independent of the primary radial -- curing the WP3
% degeneracy (b_tx near-degenerate with the primary radial through the ~horizontal
% ISL LOS). No primary-state columns, so golden-safe when off / nSpaceAssets=1.
cfg.multiAsset.towersObserveSecondaries          = false;
cfg.multiAsset.towerSecondary.code.sigma_m       = 1.0;   % tower->secondary thermal 1-sigma [m]
% Conservative product-correlation factor: the secondary ephemeris product error is
% piecewise-CONSTANT over its broadcast interval, so consecutive rows share it; the
% white-R filter would average it down ~sqrt(N). Inflate the product+tower-clock
% variance by nCorr so the filter cannot fake that averaging (honest-covariance,
% mirrors TwoWayTimeTransfer.conservativeProductCorrelation).
cfg.multiAsset.towerSecondary.productNCorr       = 30;    % effective correlated-sample count
cfg.multiAsset.towerSecondary.towerClkSigma_m    = 0.03;  % tower clock product residual 1-sigma [m] (~100 ps)
% --- Guard A (P1' realism): divergent uplink atmosphere on ground->secondary rows ---
% TRUTH-side per-(tower,interval) tropo+iono residual, SHARED across the secondaries a
% tower sees (per-LOS divergence is elevation-mapping only), interval-correlated (not
% white). Injected into z, not h -> cannot cancel; kept OUT of R by default so Guard C's
% per-sat/centroid NEES flags the near-radial common mode it pours into. Default off.
cfg.multiAsset.towerSecondary.atmosphere.enable            = false;
cfg.multiAsset.towerSecondary.atmosphere.sigmaTropZen_m    = 0.05;  % wet-tropo zenith residual [m]
cfg.multiAsset.towerSecondary.atmosphere.sigmaIonoZen_m    = 0.20;  % post-correction iono zenith residual [m]
cfg.multiAsset.towerSecondary.atmosphere.tauTrop_s         = 1800;  % wet correlation time [s]
cfg.multiAsset.towerSecondary.atmosphere.tauIono_s         = 600;   % TEC correlation time [s]
cfg.multiAsset.towerSecondary.atmosphere.ionoShellHeight_m = 350e3;
cfg.multiAsset.towerSecondary.atmosphere.chargeR           = false; % false: honest gate (bias unmodelled); true: nCorr R inflation
cfg.multiAsset.towerSecondary.atmosphere.nCorrCap          = 60;
% --- Per-secondary CARRIER phase + float-ambiguity states (Phase 1: single-frequency L1) ---
% Promotes each secondary from code-only toward a full single-asset model: tower->secondary
% carrier rows (cm thermal) with a per-(secondary,tower) float-ambiguity state, mirroring the
% chief's carrier machinery. Needs estimateMode='position' + towersObserveSecondaries (the row
% uses the secondary's r/v geometric column). Default off -> golden byte-identical.
cfg.multiAsset.towerSecondary.carrier.enable        = false;
cfg.multiAsset.towerSecondary.carrier.sigma_m       = 0.005;  % carrier thermal 1-sigma [m] (~5 mm)
cfg.multiAsset.towerSecondary.carrier.initialSigma_m = 100;   % float-ambiguity prior 1-sigma [m]
cfg.multiAsset.towerSecondary.carrier.ambProcNoise_m = 1e-4;  % ambiguity random-walk sigma [m/sqrt(s)]
% --- Per-secondary TROPOSPHERE (ZWD) states (Phase 2: each secondary estimates its own wet
% delay per tower, like the chief). Gauss-Markov, mirroring the chief per-tower ZWD. Allocated
% only when Guard A injects a divergent truth-side tropo residual; needs estimateMode='position'
% + towersObserveSecondaries. Default off -> golden byte-identical.
% HONEST OBSERVABILITY CAVEAT: at GEO the elevation to each satellite is ~constant, so the wet
% mapping m_w=1/sin(elev) is ~constant and the ZWD is DEGENERATE with the secondary clock -- it
% soaks radial<->clock wall error (100 m+, unphysical for a cm-dm tropo) and DEGRADES the
% absolute rather than improving it. This is the same weak observability the chief's ZWD has;
% it only becomes beneficial once the wall is broken (two-way ranging). Provided for single-asset
% structural symmetry; keep OFF unless the wall is broken. (Ionosphere states are dispersive ->
% require per-secondary dual-frequency: deferred to Phase 2b.)
cfg.multiAsset.towerSecondary.estimateAtmosphere    = false;
cfg.multiAsset.towerSecondary.zwd.tau_s             = 1800;    % wet-delay Gauss-Markov correlation time [s]
cfg.multiAsset.towerSecondary.zwd.sigma_ss_m        = 0.05;    % steady-state zenith wet 1-sigma [m]
cfg.multiAsset.towerSecondary.zwd.initialSigma_m    = 0.10;    % ZWD prior 1-sigma [m]
% --- Guard B (P1' realism): one-sided truth-side SRP + luni-solar dynamics gap ---
% Truth==EKF (both J2) today => each secondary's DYNAMIC error is identically 0 and NEES
% measures nothing dynamic. When injectTruthSideDynamics=true (and estimateMode='position'
% + nSpaceAssets>=2), applyInjectTruthSideDynamics turns on the existing truth-side
% luni-solar (~7e-6 m/s^2 at GEO) + cannonball SRP while the EKF stays J2 -> a real
% force-model gap for the WHOLE swarm. Default false -> golden byte-identical.
cfg.multiAsset.injectTruthSideDynamics           = false;
cfg.multiAsset.truthSideDynamics.sncSigma_mps2   = 1e-5;  % white-SNC lower bound for the gap [m/s^2]
                                                          % (sun+moon aligned PEAK ~1.1e-5; a crude white proxy
                                                          % for a coherent ramp -- Guard C NEES is the arbiter,
                                                          % do NOT raise it to force NEES->1)
cfg.multiAsset.secondaryOrbit.sigma_accel_mps2   = [];    % [] = inherit primary SNC (byte-identical to P1')
% --- Swarm all-pairs two-way ISL (clock-free baseline lengths), P2'. Default OFF. -------
% FUSION with P1' one-way ISL + WP5 ground anchor: independent draws (RngSource 22/23) ->
% adds Fisher information, NOT double-counting (one-way = range+clock-diff, two-way =
% clock-free baseline, independent noise). Requires estimateMode='position' (both endpoints
% are estimated states) AND towersObserveSecondaries (two-way is clock-free and rigid-motion
% blind -> ground rows supply the clock/absolute anchor). nSpaceAssets=1 -> 0 pairs -> 0 rows
% -> byte-identical golden. Sharpens the RELATIVE/shape solution only.
cfg.multiAsset.twoWayISL.enable                 = false;  % master gate (P2')
cfg.multiAsset.twoWayISL.links                  = 'all';  % 'all' pairs among estimated assets, or an M-by-2 [i k] list
cfg.multiAsset.twoWayISL.sigma_m                = 0.01;   % white two-way ranging thermal 1-sigma [m] (cm-class wideband crosslink)
cfg.multiAsset.twoWayISL.delayCal.sigma_const_m = 0.01;   % per-link turn-around+antenna-PCO cal bias, constant part [m] (33 ps = 1 cm)
cfg.multiAsset.twoWayISL.delayCal.sigma_rw_m    = 0.003;  % per-link cal-bias slow random-walk part [m]
cfg.multiAsset.twoWayISL.delayCal.tau_s         = 3600;   % cal-bias correlation time [s]
cfg.multiAsset.twoWayISL.delayCal.nCorrCap      = 60;     % cap on tau/dt R-inflation (honest gate)

% --- Satellite<->satellite TWO-WAY TIME TRANSFER ISL (the DUAL of P2'). Default OFF. -----
% P2' above uses the two-way SUM (range, clock-free baseline = SHAPE). This uses the two-way
% DIFFERENCE (range cancels) to observe the inter-satellite CLOCK difference directly and pin
% the swarm's RELATIVE clocks to each other -- a mesh time-sync independent of the ground:
%   z=(b_i-b_k)+delayCal+thermal ; h=x(clk_i)-x(clk_k) ; H=+1 on clk_i, -1 on clk_k (no position).
% REQUIRES the satellites to TRANSMIT+RECEIVE (full crosslink transceiver) -- NOT the plain
% reverse-GNSS uplink -> explicit "with inter-satellite two-way time transfer" enhancement.
% Needs estimated secondary clocks (estimateMode 'clocks'/'position'). Fuses with the one-way
% ISL (independent draws). sigma_m ~0.03 m = 100 ps lab-grade; operational two-way ~0.3-1 ns.
cfg.multiAsset.twoWayTimeTransferISL.enable                 = false;
cfg.multiAsset.twoWayTimeTransferISL.useInEKF               = false;
cfg.multiAsset.twoWayTimeTransferISL.links                  = 'all';  % 'all' clock-node pairs, or M-by-2 [i k]
cfg.multiAsset.twoWayTimeTransferISL.warmup_s               = 0;
cfg.multiAsset.twoWayTimeTransferISL.sigma_m                = 0.03;   % white two-way time 1-sigma [m] (~100 ps)
cfg.multiAsset.twoWayTimeTransferISL.delayCal.sigma_const_m = 0.01;   % per-link turn-around cal bias, constant part [m]
cfg.multiAsset.twoWayTimeTransferISL.delayCal.sigma_rw_m    = 0.003;  % per-link cal-bias slow random-walk part [m]
cfg.multiAsset.twoWayTimeTransferISL.delayCal.tau_s         = 3600;   % cal-bias correlation time [s]
cfg.multiAsset.twoWayTimeTransferISL.delayCal.nCorrCap      = 60;     % cap on tau/dt R-inflation (honest gate)

% --- Ground towers: real ground-station sites in the 23 deg-E GEO footprint ---
% Name, lat[deg], lon[deg], alt[m]. The first 5 are the frozen-golden network (do
% NOT reorder or edit them: the Stage-85 golden trims to nTowers=5 = these five).
% Towers 6-12 are additional real space-tracking / geodetic sites (ESA/ASI/IGS/NASA)
% spread across the visible hemisphere to break the radial<->clock degeneracy of a
% single ground-only GEO (wide lat -26..+68 deg, lon -25..+78 deg angular spread).
towerDefs = { ...
    'Tenerife',        28.3,      -16.5,    0.0; ...   % 1  ESA/INTA (frozen golden)
    'Stockholm',       59.3,       18.1,    0.0; ...   % 2  (frozen golden)
    'Hartebeesthoek', -25.9,       27.7,    0.0; ...   % 3  SANSA/HartRAO (frozen golden)
    'Bengaluru',       13.0,       77.6,    0.0; ...   % 4  ISRO ISTRAC (frozen golden)
    'Libreville',       0.0355,    -9.4496,  0.0; ...  % 5  (frozen golden)
    'Kiruna',          67.88,      21.10,    0.0; ...  % 6  ESA Esrange (far north lever)
    'Cebreros',        40.45,      -4.37,    0.0; ...  % 7  ESA DSA-2 deep-space
    'Matera',          40.65,      16.70,    0.0; ...  % 8  ASI Space Geodesy Centre
    'SantaMaria',      36.97,     -25.17,    0.0; ...  % 9  Azores (west Atlantic lever)
    'Malindi',         -2.996,     40.19,    0.0; ...  % 10 ASI Luigi Broglio (east equ.)
    'Ascension',       -7.95,     -14.41,    0.0; ...  % 11 NASA/IGS (south Atlantic)
    'AbuDhabi',        24.43,      54.62,    0.0 };    % 12 Yahsat (Middle East / east)

% Build ALL defined towers; finalizeConfig() trims to cfg.scenario.nTowers.
cfg.towers = struct();
for k = 1:size(towerDefs,1)
    cfg.towers(k).id                  = k;
    cfg.towers(k).name                = towerDefs{k,1};
    cfg.towers(k).lat_rad             = towerDefs{k,2} * pi/180;
    cfg.towers(k).lon_rad             = towerDefs{k,3} * pi/180;
    cfg.towers(k).alt_m               = towerDefs{k,4};
    cfg.towers(k).antennaOffset_enu_m = [0; 0; 0];
    cfg.towers(k).hardwareDelay_m     = 0.0;

    % Per-tower clock fields (simple config fields)
    cfg.towers(k).clockName    = 'GroundClock';
    cfg.towers(k).clockType    = 'OCXO';
    cfg.towers(k).clockFactors = struct( ...
        'biasFactor',1,'freqFactor',1,'noiseFactor',1, ...
        'roleNoiseFactor', cfg.clockScaling.towerNoiseFactor, ...
        'h2Factor',1,'h1Factor',1,'h0Factor',1,'hMinus1Factor',1,'hMinus2Factor',1);

    % Tower clock: OCXO, deterministic for convergence test
    cfg.towers(k).clock = revgnss.ConfigFactory.makeClockConfig( ...
        cfg.towers(k).clockType, 200+k, cfg.towers(k).clockFactors, cfg.clockScaling);
    cfg.towers(k).clock.name          = sprintf('%s_%s', cfg.towers(k).clockName, towerDefs{k,1});
    cfg.towers(k).clock.deterministic = true;
    cfg.towers(k).clock.bias_s        = 0.0;
    cfg.towers(k).clock.fracFreq      = 0.0;
end

% --- Estimator ------------------------------------------------
cfg.estimator.estimateTowerClocks     = false;
% Attitude/omega states remain in the 14-state vector but are frozen.
% (zero Q, zero H columns). Set true only in multiAntennaAttitudeConfig.
cfg.estimator.estimateAttitude        = true;
cfg.estimator.estimateAngularRate     = false;
cfg.estimator.estimateAttitudeFromPseudorange     = false;
cfg.estimator.estimateAngularRateFromPseudorange  = false;
cfg.estimator.estimateCarrierAmbiguities          = false;
% --- IMU attitude aiding (MASTER SWITCH, default OFF -> golden-safe) --------------------------
% The truth IMU (+models/+sensors/IMUModel) is a full strapdown unit: 3-axis GYRO + 3-axis
% ACCELEROMETER, each with its own bias random walk, white noise and RNG stream.
%
% GYRO -> consumed by the EKF. omega_gyro = omega_true + b_g + ARW; the EKF propagates the nominal
% attitude with omega = omega_gyro - b_g and estimates a 3-state gyro bias b_g APPENDED to the
% state ONLY when enabled (so nStates 24/54/59 are unchanged when off). The multi-antenna
% receivers still supply the absolute attitude update.
%
% ACCELEROMETER -> modelled and logged, NOT consumed by the EKF (no config knob: there is nothing
% to switch on). An accelerometer senses SPECIFIC FORCE, i.e. non-gravitational acceleration only
% -- it is blind to gravity. This asset is in free fall, so the true specific force is ~0 (at GEO
% only SRP ~1e-7 m/s^2, below any real accel noise floor): the measurement is pure bias + noise
% and carries zero orbit information. Feeding it to the EKF could only inject noise, which is why
% orbit determination uses DYNAMICS models (two-body + J2 + luni-solar/SRP) instead. It becomes
% informative only under thrust/manoeuvres, via SpaceAsset.specificForce_body_mps2.
%
% finalizeConfig mirrors imu.truth into cfg.asset.imu and sets estimateGyroBias = imu.enable.
cfg.estimator.imu.enable                        = false;   % master switch (gyro + accel)
cfg.estimator.imu.filter.arw_rad_per_sqrt_s     = 1e-4;    % EKF angle random walk (attitude Q)
cfg.estimator.imu.filter.rrw_rad_per_s_sqrt_s   = 1e-6;    % EKF bias rate random walk (b_g Q)
cfg.estimator.imu.filter.P0_bias_radps          = 1e-5;    % initial 1-sigma on b_g
cfg.estimator.imu.filter.useVanLoanCrossTerm    = false;   % optional theta<->b_g Q cross term
cfg.estimator.imu.truth.arw_rad_per_sqrt_s      = 1e-4;    % TRUTH gyro ARW (honest; own RNG stream)
cfg.estimator.imu.truth.rrw_rad_per_s_sqrt_s    = 1e-6;    % TRUTH gyro bias RRW
cfg.estimator.imu.truth.bias0Sigma_radps        = 1e-5;    % TRUTH gyro initial bias draw 1-sigma
cfg.estimator.imu.truth.accelVrw_mps_per_sqrt_s = 1e-3;    % TRUTH accel velocity random walk
cfg.estimator.imu.truth.accelBrw_mps2_sqrt_s    = 1e-6;    % TRUTH accel bias random walk
cfg.estimator.imu.truth.accelBias0Sigma_mps2    = 1e-4;    % TRUTH accel initial bias draw 1-sigma
cfg.estimator.imu.truth.seed                    = 909;     % IMU RNG seed (gyro); accel uses seed+1
cfg.estimator.estimateGyroBias                  = false;   % resolved from imu.enable in finalizeConfig
% Differential carrier attitude mode.
% 'off' (safe default) | 'calibratedDifferentialAmbiguity' | 'validationKnownAmbiguity'
cfg.estimator.attitudeCarrierMode     = 'off';
cfg.estimator.diffAtt.calibWin_s      = 60;   % calibration window length (s)
% Absolute multi-antenna attitude initialization.
% Safe default is 'none'.  'knownAttitudeCalibration' requires an
% explicit declaration that the calibration attitude is known.
cfg.estimator.attitudeInitMode = 'none';
cfg.estimator.attitudeInit.knownAttitudeCalibration.allow = false;
cfg.estimator.attitudeInit.search.windowDeg = [3; 3; 3];
cfg.estimator.attitudeInit.search.stepDeg = [1; 1; 1];
cfg.estimator.attitudeInit.search.maxCandidates = 343;
cfg.estimator.attitudeInit.search.ratioThreshold = 1.20;
cfg.estimator.attitudeInit.search.ambiguousRatioThreshold = 1.01;
cfg.estimator.attitudeInit.search.improvementRatioThreshold = 1.05;
cfg.estimator.attitudeInit.search.maxRmsCycles = 0.30;
cfg.estimator.attitudeInit.search.sigmaScaleDeg = 2.0;
cfg.estimator.attitudeInitShadow.enable = false;
% perfectCorrection: EKF uses known tower clock values (zero here).
cfg.estimator.towerClockMode          = 'perfectCorrection';
cfg.estimator.towerClockCorrectionSigma_m = 0.5; % used if noisyCorrection
cfg.estimator.elevationMask_rad       = 5 * pi/180;
cfg.estimator.attitudeJacobianStep_rad = 1e-6;
cfg.estimator.sigma_accel_mps2        = 1e-6;   % baseline residual-acceleration process noise (SNC) for a MATCHED-J2 GEO EKF: covers SRP (~1e-7), luni-solar third-body (~1e-6) and higher-order geopotential residuals. The old 0.01 was ~1e4x too large and let the weakly-observable radial<->receiver-clock mode random-walk (radial 10 m -> 1.9 m when corrected). For an explicit reduced-dynamics/mismatch run, size the EXTRA noise via processNoise.modelMismatch below, not this baseline.
cfg.estimator.dynamics.mode           = 'constantVelocity';
% EKF propagator luni-solar/SRP perturbations. Default OFF -> the EKF propagates pure J2
% (or two-body). Enable to make the FILTER dynamics include sun+moon third-body (and SRP),
% matching a truth that carries them (cfg.orbit.truth.perturbations) so the along-track
% force-model gap closes. Same constant-Omega ECI + ephemeris as the truth propagator; the
% FD STM picks it up automatically. See +models/+orbit/OrbitPerturbations, EkfDynamicsPredictor.
cfg.estimator.dynamics.perturbations.luniSolar.enable = false;
cfg.estimator.dynamics.perturbations.srp.enable       = false;
cfg.estimator.dynamics.perturbations.epochJD_TT       = 2451545.0;   % match cfg.orbit.truth.perturbations
% Dynamic-model residual-acceleration process noise. processNoise.modelMismatch is the
% back-compat field the EKF (ReverseGNSSEKF.buildQ_) reads; it carries the EXTRA process
% noise sized to a truth-vs-EKF propagator gap. It is ZERO/off in a same-family (matched)
% run and only active in an explicit reduced-dynamics / mismatch run.
cfg.estimator.processNoise.modelMismatch.enable = false;
cfg.estimator.processNoise.modelMismatch.sigma_mps2 = 1e-6;
% Canonical (honest) name for the SAME quantity. finalizeConfig keeps this a read-only
% mirror of processNoise.modelMismatch (after any auto-scale), so reports can name it by
% its physical meaning instead of the loaded word "mismatch". Do NOT read this in the EKF.
cfg.estimator.processNoise.residualAccelerationUncertainty.enable     = false;
cfg.estimator.processNoise.residualAccelerationUncertainty.sigma_mps2 = 1e-6;
% Near-zero angular-acceleration noise: attitude stays frozen at truth.
cfg.estimator.sigma_angAccel_radps2   = 1e-15;
cfg.estimator.minMeasurementsForUpdate = 4;

% Initial covariance (1-sigma diagonal)
cfg.estimator.P0_pos_m        = 1000.0;
cfg.estimator.P0_vel_mps      = 1.0;
% 5° initial 1-sigma — consistent with 0.5° initial error; finalizeConfig may increase.
cfg.estimator.P0_euler_rad    = deg2rad(5);
cfg.estimator.P0_omega_radps  = 1e-12;
cfg.estimator.P0_bRx_m        = 100.0;
cfg.estimator.P0_bdotRx_mps   = 0.01;

% Controlled initial errors (fixed offsets, not random)
cfg.estimator.initialError.pos_m          = [1000; -500; 250];
cfg.estimator.initialError.vel_mps        = [0.1; -0.1; 0.05];
% Zero attitude error: no initial offset, no runaway risk.
cfg.estimator.initialError.euler_deg      = [0.5; 0.5; 0.5];
cfg.estimator.initialError.omega_radps    = [0; 0; 0];
cfg.estimator.initialError.clockBias_m    = 100.0;
cfg.estimator.initialError.clockDrift_mps = 0.01;
cfg.estimator.forceFiniteDifferenceH      = false;

% --- Measurement noise floor ----------------------------------
cfg.measurement.sigmaFloor_m = 1e-3;

% --- Error sources: all off by default -----------------------
cfg.errors.codeNoise.sigma_m = 0.3;

% --- Signal / frequency config ----------------------------------------
sigL1Default_ = revgnss.SignalDefinition.get('L1');
sigL2Default_ = revgnss.SignalDefinition.get('L2');
cfg.signals.enabled = {'L1'};
cfg.signals.twoFrequency.enable = false;
cfg.signals.L1.name          = 'L1';
cfg.signals.L1.frequency_Hz  = sigL1Default_.frequency_Hz;
cfg.signals.L1.lambda_m      = sigL1Default_.wavelength_m;
cfg.signals.L1.codeSigma0_m  = 0.30;
cfg.signals.L2.name          = 'L2';
cfg.signals.L2.frequency_Hz  = sigL2Default_.frequency_Hz;
cfg.signals.L2.lambda_m      = sigL2Default_.wavelength_m;
cfg.signals.L2.codeSigma0_m  = 0.45;
cfg.signals.primary          = 'L1';   % primary signal for iono scaling
cfg.signals.secondary        = 'L2';   % secondary for IF combination
cfg.ionosphere.mode          = 'off';  % 'off'|'truthOnly'|'model'|'ionosphereFree'
% Central signal list (names, Hz, boolean masks).
% Populated by finalizeConfig from canonical names/enabledMask resolution.
cfg.signals.names            = {'L1'};
cfg.signals.frequencyHz      = sigL1Default_.frequency_Hz;
cfg.signals.enabledMask      = [true];
cfg.measurements.code.enabledByFrequency    = [true];
cfg.measurements.carrier.enabledByFrequency = [true];

% --- Code noise model --------------------------------------------------
cfg.measurements.codeNoise.model             = 'constant';
cfg.measurements.codeNoise.seed              = 6101;
cfg.measurements.codeNoise.minElevation_rad  = deg2rad(5);
cfg.measurements.codeNoise.elevationExponent = 1.0;
cfg.measurements.codeNoise.cn0.enable           = false;
cfg.measurements.codeNoise.cn0.base_dBHz        = 45;
cfg.measurements.codeNoise.cn0.elevationGain_dB = 6;
cfg.measurements.codeNoise.cn0.weatherLossScale_dB = 2;
cfg.measurements.codeNoise.cn0.sigmaAt45dBHz_m  = 0.30;

% --- Environment / weather -------------------------------------------
cfg.environment.weather.enable                 = false;
cfg.environment.weather.seed                   = 7201;
cfg.environment.weather.defaultPressure_hPa    = 1013.25;
cfg.environment.weather.defaultTemperature_K   = 293.15;
cfg.environment.weather.defaultRelativeHumidity = 0.50;
cfg.environment.weather.heightScale_m          = 8400;
cfg.environment.weather.lapseRate_K_per_m      = 0.0065;
cfg.environment.weather.minTemperature_K        = 220.0;
cfg.environment.weather.maxTemperature_K        = 320.0;

% --- Extended atmosphere model config --------------------------------
% Troposphere: new dry/wet split (backward compat: also keep zenithDelay_m)
cfg.errors.troposphere.modelType                  = 'simpleMapped';
cfg.errors.troposphere.truth.zenithDryDelay_m     = 2.3;
cfg.errors.troposphere.truth.zenithWetDelay_m     = 0.15;
cfg.errors.troposphere.model.zenithDryDelay_m     = 2.3;
cfg.errors.troposphere.model.zenithWetDelay_m     = 0.15;
cfg.errors.troposphere.stochastic.enable          = true;
cfg.errors.troposphere.stochastic.process         = 'gaussMarkov';
cfg.errors.troposphere.stochastic.tau_s           = 3600;
cfg.errors.troposphere.stochastic.sigmaWet_ss_m   = 0.05;
cfg.errors.troposphere.stochastic.sigmaModelResidual_m = 0.02;

% Ionosphere: new verticalDelayL1 (backward compat: keep zenithDelay_m)
cfg.errors.ionosphere.modelType                       = 'simpleMapped';
cfg.errors.ionosphere.truth.verticalDelayL1_m          = 5.0;
cfg.errors.ionosphere.model.verticalDelayL1_m          = 5.0;
cfg.errors.ionosphere.stochastic.enable               = false;
cfg.errors.ionosphere.stochastic.process              = 'gaussMarkov';
cfg.errors.ionosphere.stochastic.tau_s                = 1800;
cfg.errors.ionosphere.stochastic.sigmaVDelayL1_ss_m   = 1.0;
cfg.errors.ionosphere.stochastic.sigmaModelResidualL1_m = 0.5;
% Second/third-order ionosphere (Branch A bounded residual). The dual-frequency
% IF combination cancels the first-order 40.3*TEC/f^2 term, but the second-order
% (~f^-3) and third-order (~f^-4) residuals SURVIVE it and are of order cm at L1 under
% high solar activity. Modelled as a truth-side bounded residual tied to the first-order
% slant delay; enters R; NOT estimated. Default OFF => bit-identical. Conservative
% (high-activity) magnitudes. Sources: Bassiri & Hajj 1993; Hoque & Jakowski 2007; K&H.
cfg.errors.ionosphere.higherOrder.enable                = false;
cfg.errors.ionosphere.higherOrder.secondOrderFractionL1 = 0.003;  % 2nd-order as fraction of |I_L1| (~TEC)
cfg.errors.ionosphere.higherOrder.secondOrderCap_m      = 0.05;   % cap 2nd-order at L1 [m] (~1-2 cm typical)
cfg.errors.ionosphere.higherOrder.thirdOrderCoeff_perm  = 5e-5;   % 3rd-order coeff [1/m]: d3_L1 = coeff*I_L1^2 (~TEC^2)
cfg.errors.ionosphere.higherOrder.thirdOrderCap_m       = 0.005;  % cap 3rd-order at L1 [m] (~few mm)
cfg.errors.ionosphere.scintillation.enable            = true;
cfg.errors.ionosphere.scintillation.process           = 'gaussMarkov';
cfg.errors.ionosphere.scintillation.tau_s             = 30;
cfg.errors.ionosphere.scintillation.sigmaCodeL1_m     = 0.3;
cfg.errors.ionosphere.scintillation.frequencyExponent = 1.0;
cfg.errors.ionosphere.scintillation.affectsCodeNoise  = true;
cfg.errors.ionosphere.scintillation.affectsPseudorangeBias = false;

cfg.errors.troposphere.stochastic.modelResidual.enable = false;
cfg.errors.troposphere.stochastic.modelResidual.mode   = 'zero';
cfg.errors.ionosphere.stochastic.modelResidual.enable  = false;
cfg.errors.ionosphere.stochastic.modelResidual.mode    = 'zero';

% Honest off=off default (clarity refactor C-5): the base injects NO atmosphere.
% masterConfig / atmosphereConfig / matchedErrorBaselineConfig enable these
% explicitly. Delay parameters are retained (inert while the enables are false).
cfg.errors.troposphere.truth.enable        = false;
cfg.errors.troposphere.truth.zenithDelay_m = 2.3;
cfg.errors.troposphere.model.enable        = false;
cfg.errors.troposphere.model.zenithDelay_m = 2.3;
cfg.errors.troposphere.model.biasFraction  = 1.0;
cfg.errors.troposphere.sigma_m             = 0.0;

cfg.errors.ionosphere.truth.enable         = false;
cfg.errors.ionosphere.truth.zenithDelay_m  = 5.0;
cfg.errors.ionosphere.model.enable         = false;
cfg.errors.ionosphere.model.zenithDelay_m  = 5.0;
cfg.errors.ionosphere.model.biasFraction   = 1.0;
cfg.errors.ionosphere.sigma_m              = 0.0;
% CHANGED: v3→v4 — Issue 2/16
% d/dt of first-order iono delay: dot{I}_L1 = -(40.3/f_L1^2)*dot{TEC}.
% When true, Doppler is excluded from ionoFreeCode mode (no IF Doppler model).
cfg.errors.ionosphere.includeRateTerm      = false;

% Tower clock product parameters (for product epoch caching — Issue 6/16)
cfg.errors.towerClock.updateInterval_s     = 300;   % product update interval [s]
cfg.errors.towerClock.latency_s            = 0;     % product delivery latency [s]
% CHANGED: v3→v4 — Issue 10/16
% Shared clock-drift product uncertainty per tower.  Set > 0 if drift
% corrections are active and their error should appear in R.
cfg.errors.towerClock.driftCorrSigma_m_per_s = 0;  % [m/s], default: unmodelled

cfg.errors.hardwareDelay.truth.enable      = false;
cfg.errors.hardwareDelay.truth.default_m   = 0.0;
cfg.errors.hardwareDelay.model.enable      = false;  % honest off=off (was true; default_m=0 made it a no-op)
cfg.errors.hardwareDelay.model.default_m   = 0.0;
% Hardware-delay real-residual channels, default inert. residualStochastic adds a
% truth-only white residual (needs enable + sigma_m>0 + truth.enable) that survives z-h;
% declaring the fields removes the runtime try/catch reliance. NB: enabling hardwareDelay
% with matched truth==model default_m AND these off contributes EXACTLY 0 -> validateMasterConfig
% warns (validateMasterConfig:hwDelayNoResidual). A differing truth/model default_m also leaves
% a constant residual (already supported).
cfg.errors.hardwareDelay.sigma_m                   = 0.0;
cfg.errors.hardwareDelay.residualStochastic.enable = false;
% Per-tower CONSTANT uplink hardware group-delay bias (gated, default OFF -> golden-safe). When
% enabled, i_applyPerTowerHwBias() (end of file) draws ONE constant delay per tower from
% [min_ns,max_ns] using perTowerBias.seed on its OWN RandStream (does not disturb the shared
% draw order), writes it truth-only (model=0 -> survives z-h as a real UNcalibrated systematic),
% and adds a jitter_ns white residual matched into R. 10-30 ns is a realistic UNcalibrated ground
% RF-chain delay (cables/filters/LNA/ADC); a well-calibrated site is <1 ns, so this is the
% conservative "uncorrected" case. Each tower differs (seeded), never hardcoded.
cfg.errors.hardwareDelay.perTowerBias.enable    = false;
cfg.errors.hardwareDelay.perTowerBias.min_ns    = 10;
cfg.errors.hardwareDelay.perTowerBias.max_ns    = 30;
cfg.errors.hardwareDelay.perTowerBias.jitter_ns = 3;
cfg.errors.hardwareDelay.perTowerBias.seed      = 4300;

% Unknown inter-antenna carrier phase biases (truth-only) — R-6. Enabling injects an
% unknown per-antenna, per-signal carrier phase bias (~0.1-0.5 cycle) on the TRUTH carrier
% (reference antenna ai=1 == 0); the estimator does NOT model it, so the 4-antenna attitude
% no longer starts from a zero-bias truth. A constant bias is absorbed by the float
% ambiguity; a drifting one leaves a real residual. Default OFF -> byte-identical no-op.
cfg.errors.interAntennaCarrierBias.enable                   = false;
cfg.errors.interAntennaCarrierBias.sigma_cycles             = 0.25;
cfg.errors.interAntennaCarrierBias.perSignal                = true;
cfg.errors.interAntennaCarrierBias.drift.enable             = false;
cfg.errors.interAntennaCarrierBias.drift.rate_cyclesPerHour = 0.05;

cfg.errors.multipath.truth.enable              = false;
cfg.errors.multipath.truth.amplitude_m         = 0.3;
cfg.errors.multipath.truth.frequency_radps     = 0.01;
cfg.errors.multipath.truth.stochastic_sigma_m  = 0.1;
cfg.errors.multipath.sigma_m                   = 0.0;
% Multipath as a coloured (first-order Gauss-Markov) process. Multipath is the
% dominant code error in nominal conditions and is strongly time-correlated (tens of
% seconds to minutes, tied to geometry) — modelling it as white under-represents its
% low-frequency, per-link-correlated impact (Kaplan & Hegarty §7.2.6). One GM state per
% link (tower x antenna) is stepped each epoch; the realised value is added to the TRUTH
% pseudorange and its steady-state variance enters R (the estimator does not know the
% instantaneous value). It is NOT an EKF state — this is a truth-side conservative error.
% Default OFF (coloredGM.enable=false) => legacy white-sinusoid path, bit-identical.
cfg.errors.multipath.coloredGM.enable              = false;
cfg.errors.multipath.coloredGM.tau_s               = 60;     % correlation time [s] (tens of seconds)
cfg.errors.multipath.coloredGM.sigmaCodeL1_ss_m    = 0.30;   % steady-state code multipath 1-sigma at L1 [m]
cfg.errors.multipath.coloredGM.elevationExponent   = 1;      % envelope ~ 1/sin(el)^exp (1 or 2); low elev = more MP
cfg.errors.multipath.coloredGM.carrierScale        = 0.01;   % phase multipath ~ 1/100 of code (reserved)
cfg.errors.multipath.coloredGM.seed                = 6301;   % dedicated per-link RNG seed

% --- Effect toggles: deterministic geometric/structural effects ------
% cfg.effects groups deterministic geometric/structural effects.
% Each effect has truth/model toggle so mismatches appear as innovation bias.
% If truth=true and model=true with same params, the effect mostly cancels.
% R contains stochastic uncertainty only — deterministic bias belongs here.

cfg.effects.towerSurvey.truth.enable = false;
cfg.effects.towerSurvey.model.enable = false;
cfg.effects.towerSurvey.sigmaENU_m   = [0.01; 0.01; 0.03];
cfg.effects.towerSurvey.seed         = 3100;

% Truth-only solid-Earth tide (degree-2, IERS-2010 in-phase) — R-8. Displaces the TRUTH
% tower positions by the ~cm-dm tidal breathing the static model ignores (common part
% absorbed by the receiver clock; differential part is a real per-tower residual). Default
% OFF -> byte-identical no-op. See +models/+frames/SolidEarthTide.
cfg.effects.solidEarthTide.truth.enable = false;
cfg.effects.solidEarthTide.model.enable = false;   % model keeps static towers (pair symmetry)
cfg.effects.solidEarthTide.loveH2       = 0.6078;
cfg.effects.solidEarthTide.loveL2       = 0.0847;
cfg.effects.solidEarthTide.epochJD_TT   = 2451545.0;

cfg.effects.antennaPCO.truth.enable          = false;
cfg.effects.antennaPCO.model.enable          = false;
cfg.effects.antennaPCO.receiverOffset_body_m = [0; 0; 0];
cfg.effects.antennaPCO.towerOffset_enu_m     = [0; 0; 0];
% Optional gated truth-only PCO calibration residual -- a receiver antenna phase-centre
% mis-calibration the estimator does NOT know (applied to the truth side only), so it survives
% z-h as a REAL imperfection instead of cancelling. Default OFF -> zero -> golden byte-identical.
cfg.effects.antennaPCO.calibrationResidual.enable               = false;
cfg.effects.antennaPCO.calibrationResidual.receiverOffset_body_m = [0; 0; 0];

% antennaPCV: toy elevation model only.  NOT calibrated ANTEX.
cfg.effects.antennaPCV.truth.enable  = false;
cfg.effects.antennaPCV.model.enable  = false;
cfg.effects.antennaPCV.modelType     = 'toyAzEl';
cfg.effects.antennaPCV.amplitude_m   = 0.005;

cfg.effects.correlatedNoise.enable            = false;
cfg.effects.correlatedNoise.commonModeSigma_m = 0.0;
cfg.effects.correlatedNoise.sameTowerSigma_m  = 0.0;
cfg.effects.correlatedNoise.independentSigma_m = 0.0;
cfg.effects.correlatedNoise.seed              = 4100;

% --- Constants, frames, and range-correction toggles --------------
cfg.constants.c_mps            = revgnss.Constants.SPEED_OF_LIGHT_MPS;
cfg.constants.muEarth_m3s2     = revgnss.Constants.EARTH_GM_M3PS2;
cfg.constants.omegaEarth_radps = revgnss.Constants.EARTH_OMEGA_RADPS;
cfg.constants.radiusEarth_m    = revgnss.Constants.EARTH_RADIUS_M;
cfg.constants.J2               = revgnss.Constants.EARTH_J2;
cfg.frames.truthFrame          = 'ECI';
cfg.frames.measurementFrame    = 'ECEF';
cfg.frames.earthRotationModel  = 'constantOmegaV1';
% Truth-only Earth-orientation (EOP) error — R-8. The model uses constant-Omega with NO
% polar motion / UT1 correction; enabling this displaces the TRUTH tower positions by the
% uncorrected pole offset (~9 m at the surface for xp~0.3") so the frame mismatch survives
% z-h. Truth-only, default OFF -> byte-identical no-op. See +models/+frames/TruthEarthOrientation.
cfg.frames.truthEop.enable                 = false;
cfg.frames.truthEop.polarMotion_xp_arcsec  = 0.2;
cfg.frames.truthEop.polarMotion_yp_arcsec  = 0.3;
cfg.frames.truthEop.ut1Rate_error_msPerDay = 1.0;
cfg.physics.c_mps              = cfg.constants.c_mps;
cfg.physics.omegaEarth_radps   = cfg.constants.omegaEarth_radps;
cfg.physics.muEarth_m3ps2      = cfg.constants.muEarth_m3s2;

cfg.physics.sagnac.truth.enable    = true;
cfg.physics.sagnac.model.enable    = true;
cfg.physics.sagnac.mode            = 'firstOrderCorrection';

cfg.physics.lightTime.truth.enable = false;
cfg.physics.lightTime.model.enable = false;
cfg.physics.lightTime.maxIter      = 2;
cfg.physics.lightTime.enable       = false;
cfg.physics.lightTime.mode         = 'sagnacFirstOrder';
cfg.physics.lightTime.iterations   = 2;
cfg.physics.lightTime.tolerance_s  = 1e-12;
cfg.physics.lightTime.dopplerDerivative = 'simplifiedV1';

cfg.physics.relativity.shapiro.truth.enable = false;
cfg.physics.relativity.shapiro.model.enable = false;

cfg.physics.relativity.clock.truth.enable = false;
cfg.physics.relativity.clock.model.enable = false;

cfg.physics.doppler.truth.enable = false;
cfg.physics.doppler.model.enable = false;

% --- Observable toggles -----------------------------------------
% doppler.enable=true, doppler.useInEKF=true by default.
%   useInEKF is auto-disabled by finalizeConfig if physics.doppler.model.enable=false.
% carrierPhase.useInEKF is deprecated; use carrierMode='ekfFloat' instead.
cfg.measurements.pseudorange.enable   = true;
cfg.measurements.doppler.enable       = true;
cfg.measurements.doppler.sigma_mps    = 0.01;
cfg.measurements.doppler.useInEKF     = true;
% Include the range-rate position partial d(rhoDot)/dr in the Doppler Jacobian.
% Default false -> H has only d/dv and d/d(bdot_rx) (documented approximation; golden
% byte-identical). true -> the LOS-rotation + tower-rotation partial is added (small for a
% GEO). See revgnss.OneWayRangeRateModel.positionPartial.
cfg.measurements.doppler.includePositionPartial = false;

cfg.measurements.carrierPhase.enable           = true;
cfg.measurements.carrierPhase.useInEKF         = false;   % governed by carrierMode in v4+
cfg.measurements.carrierPhase.frequency_Hz     = sigL1Default_.frequency_Hz;
cfg.measurements.carrierPhase.lambda_m         = sigL1Default_.wavelength_m;
cfg.measurements.carrierPhase.sigma_cycles     = 0.01;
cfg.measurements.carrierPhase.initialAmbiguityMode = 'randomInteger';
cfg.measurements.carrierPhase.seed             = 9001;
cfg.measurements.carrierPhase.cycleSlip.enable = true;

% --- One-way inter-spacecraft link scaffold --------
cfg.measurements.isl.enable = false;
cfg.measurements.isl.transmitterAssetIndex = 2;   % legacy single-link default
cfg.measurements.isl.transmitters = 'all';        % 'all' secondaries (2..N) or a specific index
cfg.measurements.isl.receiverAssetIndex = 1;
cfg.measurements.isl.code.enable = false;
cfg.measurements.isl.code.useInEKF = false;
cfg.measurements.isl.code.sigma_m = 0.5;          % one-way ISL code thermal 1-sigma [m]
cfg.measurements.isl.doppler.enable = false;
cfg.measurements.isl.doppler.useInEKF = false;
cfg.measurements.isl.doppler.sigma_mps = 0.02;
cfg.measurements.isl.carrier.enable = false;
cfg.measurements.isl.carrier.useInEKF = false;
cfg.measurements.isl.carrier.sigma_m = 0.002;
% ISL acquisition warm-up [s]: ISL rows are diagnostic-only until the ground-only
% fix has converged (initial covariance shrunk), then they enter the EKF. Prevents
% the tight-ISL-on-huge-initial-covariance transient overshoot.
cfg.measurements.isl.warmup_s = 300;
% Represented-secondary product uncertainty (productAidedExternal): the secondary
% ephemeris/clock is a broadcast PRODUCT with a fixed-per-run error that both biases
% the ISL model h and inflates R. This floors the achievable primary accuracy by the
% reference-product quality (honest aiding, not perfect-truth knowledge).
cfg.measurements.isl.product.enable              = false;
cfg.measurements.isl.product.sigmaPos_m          = 0.05;   % secondary ephemeris product 1-sigma/axis [m]
cfg.measurements.isl.product.sigmaClock_m        = 0.03;   % secondary clock product 1-sigma [m] (~100 ps)
cfg.measurements.isl.product.sigmaVel_mps        = 1e-4;   % secondary velocity product 1-sigma [m/s]
cfg.measurements.isl.product.sigmaClockDrift_mps = 1e-4;   % secondary clock-drift product 1-sigma [m/s]
cfg.measurements.isl.product.updateInterval_s    = 300;    % product re-broadcast cadence [s]: the
                                                           % error is piecewise-constant per interval,
                                                           % so it averages down and R stays consistent
cfg.measurements.isl.twoWay.enable = false;
cfg.measurements.isl.twoWay.range.enable = false;
cfg.measurements.isl.twoWay.range.useInEKF = false;
cfg.measurements.isl.twoWay.range.sigma_m = 0.25;
cfg.measurements.isl.twoWay.doppler.enable = false;
cfg.measurements.isl.twoWay.doppler.useInEKF = false;
cfg.measurements.isl.timing.enable = false;
cfg.measurements.isl.timing.mode = 'sameEpoch';
cfg.measurements.isl.timing.maxIter = 3;
cfg.measurements.isl.timing.tolerance_s = 1e-12;
cfg.measurements.isl.timing.processingDelay_s = 0.0;
cfg.measurements.isl.clockTransferDiagnostics.enable = false;

% --- TWSTFT code time-transfer diagnostic scaffold ---
% All defaults off. Enabling these toggles does NOT add EKF rows.
% No relay/transponder, no ISL carrier EKF, no TWSTFT ambiguity states.
cfg.measurements.twstft.enable = false;
cfg.measurements.twstft.code.enable = false;
cfg.measurements.twstft.code.useInEKF = false;
cfg.measurements.twstft.code.sigma_s = 1e-9;
cfg.measurements.twstft.referenceAssetIndex = 1;
cfg.measurements.twstft.remoteAssetIndex = 2;
cfg.measurements.twstft.processingDelay_s = 0.0;
cfg.measurements.twstft.calibratedDelay_s = 0.0;
cfg.measurements.twstft.requireIslTiming = true;

% --- Tower<->spacecraft two-way time transfer ---
% A REAL EKF observable (unlike the spacecraft<->spacecraft TWSTFT scaffold above):
% each two-way-capable ground tower exchanges signals with the spacecraft, yielding
% a range-cancelled measurement of the clock difference (b_rx - b_tower). Because the
% geometric range cancels by reciprocity, the row observes the RECEIVER CLOCK directly
% (H has +1 on b_rx and NO position column), breaking the GEO radial<->clock degeneracy
% that limits the one-way uplink. Default OFF -> goldens byte-identical.
cfg.measurements.twoWayTimeTransfer.enable                     = false;
cfg.measurements.twoWayTimeTransfer.useInEKF                   = false;
cfg.measurements.twoWayTimeTransfer.towers                     = 'all';   % 'all' or vector of tower indices
cfg.measurements.twoWayTimeTransfer.sigma_m                    = 0.03;    % two-way time uncertainty 1-sigma [m] (~100 ps)
cfg.measurements.twoWayTimeTransfer.includeReciprocityResidual = false;  % model motion non-reciprocity (both sides)
cfg.measurements.twoWayTimeTransfer.reciprocitySigma_m         = 0.005;  % residual non-reciprocity 1-sigma [m]
cfg.measurements.twoWayTimeTransfer.warmup_s                   = 0;       % start two-way after this time [s]
% CONSERVATIVE (default true): the reference-clock broadcast-product error is constant
% per update interval, so the two-way rows within an interval share it. Inflating the
% product variance by N=interval/dt stops the sequential EKF over-averaging it below the
% reference-clock floor -> honest, never-optimistic clock. Set false for the idealised
% (independent-product) treatment.
cfg.measurements.twoWayTimeTransfer.conservativeProductCorrelation = true;

% --- Observable mode (Step 1) -----------------------------------
% observableMode: DESCRIPTIVE LABEL (not authoritative — does not gate
% measurements).  Used for report generation and diagnostics only.
% Actual measurement behavior is controlled by codeMode, carrierMode,
% cfg.measurements.doppler.enable, and cfg.measurements.doppler.useInEKF.
%
%   'code'                   pseudorange only
%   'code+doppler'           pseudorange + Doppler
%   'code+carrier'           pseudorange + carrier (requires carrierMode != 'off')
%   'code+doppler+carrier'   all three
%
% codeMode (authoritative):
%   'singleFrequency'        L1 (or L2) only
%   'dualFrequencyStacked'   L1 + L2 as separate rows
%   'ionosphereFree'         L1+L2 IF combination; requires L1 and L2
%
% carrierMode (authoritative):
%   'off'        do not compute carrier phase
%   'diagnostic' compute carrier z but do not update EKF
%   'ekfFloat'   carrier as EKF observable with float L1 ambiguity states
%                NOTE: L2 carrier EKF is NOT supported in v1.
%
% carrierCombinationMode (authoritative):
%   'raw'             individual L1 phase (L2 not supported in EKF)
%   'ionosphereFree'  NOT supported — no IF carrier EKF in v1
cfg.measurements.observableMode          = 'code+doppler+carrier';
cfg.measurements.codeMode                = 'singleFrequency';
cfg.measurements.carrierMode             = 'diagnostic';
cfg.measurements.carrierCombinationMode  = 'raw';

% Carrier phase in metres (new-style sigma)
cfg.measurements.carrier.sigma_m                   = 0.005;
cfg.measurements.carrier.minElevationDeg           = 5;
cfg.measurements.carrier.cycleSlipMode             = 'none';
cfg.measurements.carrier.syntheticSlipProbability  = 0;

% Slip detection
cfg.measurements.carrier.slipDetection.enable                 = false;
cfg.measurements.carrier.slipDetection.threshold_m            = 0.1;
cfg.measurements.carrier.slipDetection.minEpochsBeforeDetect  = 3;
cfg.measurements.carrier.slipDetection.resetSigma_m           = 100;
cfg.measurements.carrier.slipDetection.action                 = 'resetAndSkip';

% --- ZWD mapping model (Step 6) ---------------------------------
% Governs the mapping function used for ZWD state contributions in h,
% H Jacobian, and postfit recomputation.
% 'simple'           — 1/sin(el) (default)
% 'continuedFraction'— simple continued-fraction form (illustrative)
% NOTE: VMF3, GPT3, and Niell are NOT implemented.
cfg.effects.troposphere.mappingModel = 'simple';

% --- Ionosphere mapping model ------------------------
% Governs the mapping function used to project vertical ionosphere
% delays to slant delays in EnvironmentModel.getIonoDelay().
% 'simpleSecant' — 1/sin(el) (backward-compatible default)
% 'thinShell'    — single thin-shell: M(e)=1/sqrt(1-(Re*cos(e)/(Re+hI))^2)
%                  hI set via cfg.effects.ionosphere.shellHeight_m
% NOTE: This is NOT a Klobuchar model. Klobuchar is not implemented.
cfg.effects.ionosphere.mappingModel  = 'simpleSecant';
cfg.effects.ionosphere.shellHeight_m = 350e3;

% --- Estimation modes (Steps 3 + 7) ----------------------------
% ambiguityMode: 'none' | 'floatPerTowerSignal'
% troposphereMode: 'none' | 'perTowerZwd'
cfg.estimation.ambiguityMode = 'none';
cfg.estimation.ambiguity.initialSigma_m                   = 100;
cfg.estimation.ambiguity.processNoiseSigma_m_per_sqrt_s   = 1e-5;

cfg.estimation.troposphereMode = 'none';
cfg.estimation.tropoZwd.tau_s          = 3600;
cfg.estimation.tropoZwd.sigma_ss_m     = 0.05;
cfg.estimation.tropoZwd.initialSigma_m = 0.10;

% ionosphereMode: 'none' | 'perTowerSlant' (prototype). 'perTowerSlant' adds one EKF
% state per tower = the L1 slant ionospheric delay [m], observable from the L1/L2
% dispersion. It removes the ionosphere while keeping all dual-frequency rows (no
% ionosphere-free noise/row penalty). Pair with errors.ionosphere.model.correction='none'
% so the state supplies the model iono (not double-counted). Default 'none' => no states.
cfg.estimation.ionosphereMode = 'none';
cfg.estimation.slantIono.tau_s          = 900;    % slant-iono GM correlation time [s]
cfg.estimation.slantIono.sigma_ss_m     = 1.0;    % steady-state slant-iono sigma [m]
cfg.estimation.slantIono.initialSigma_m = 5.0;    % initial 1-sigma [m]

% --- Antenna PCV model (Step 4) ---------------------------------
% pcvModel: 'none' | 'toy' | 'table'
% Default is 'none' (no PCV applied). 'toy' is synthetic-only (label explicitly).
% 'table' uses receiverPcvTable (elevation-only or el+az).
cfg.effects.antenna.pcvModel                     = 'none';
cfg.effects.antenna.receiverPcvTable.elDeg       = 0:10:90;
cfg.effects.antenna.receiverPcvTable.pcv_m       = zeros(1, 10);

% --- Light-time model (Step 5) ----------------------------------
% 'none' | 'sagnacFirstOrder' | 'iterative'
% Default 'sagnacFirstOrder' maps from existing cfg.physics.sagnac behavior.
cfg.effects.lightTime.model   = 'sagnacFirstOrder';
cfg.effects.lightTime.maxIter = 5;
cfg.effects.lightTime.tol_s   = 1e-12;

% --- Tower clock correction product (Step 6) -------------------
% correctionMode: 'none' | 'perfectTruth' | 'truthHistoryProduct' |
%                 'product' | 'productNoisy'
%
% 'none'               — no tower clock correction
% 'perfectTruth'       — use exact truth clock (validation only)
% 'truthHistoryProduct'— simulate product from tower truth history
%                        (old 'product'/'productNoisy' behavior)
% 'product'            — use cfg.towerClock.products(ti) explicit struct
% 'productNoisy'       — same but add product uncertainty to R
%
% Product uncertainty R inflation (productNoisy):
%   sigma_corr^2 = sigmaBias^2 + dt^2*sigmaDrift^2 + 2*dt*covBiasDrift
% where dt = t_eval - epoch_s of the product.
%
% Validity: if abs(dt) > validity_s, action per productValidityPolicy.
cfg.towerClock.correctionMode         = 'perfectTruth';
cfg.towerClock.sigmaBias_m            = 0.0;
cfg.towerClock.sigmaDrift_mps         = 0.0;
cfg.towerClock.productValidityPolicy  = 'warn';  % 'warn' | 'error'
% cfg.towerClock.products is not set in defaultConfig (optional field).
% Set it in towerClockProductConfig() or manually per tower.

% --- Clock architecture mode ---------------------------
% clock.mode: which clocks are in the EKF state vector.
%   'spacecraftReceiverClockOnly' — only rx clock (default; 14-state base)
%   'includeTowerClocksInEKF'     — add tower clock states (+2/tower)
%     Requires clock.gauge.mode != 'free' (one-way PR is rank-deficient otherwise).
%
% clock.gauge.mode: how the clock datum ambiguity is resolved.
%   'externalTowerCorrections' — tower clocks corrected from external product (default)
%   'fixReferenceTower'        — pin tower-1 clock to zero (differential estimation)
%   'free'                     — no gauge; legal only with spacecraftReceiverClockOnly
%
% clock.hardwareDelay.estimatePerTower — hardware delay EKF state placeholder (v1: not implemented)
cfg.clock.mode                           = 'spacecraftReceiverClockOnly';
% h-coefficient source for clock templates (canonical selector). 'legacy' keeps
% every current number bit-identical; 'jowTable2p1' re-anchors OCXO/CESIUM to the
% project primary source (JOW Table 2.1) — less optimistic, more conservative.
cfg.clock.templateSource                 = 'legacy';
cfg.clock.gauge.mode                     = 'externalTowerCorrections';
cfg.clock.gauge.referenceTowerIndex      = 1;      % used by fixReferenceTower
cfg.clock.gauge.sigmaBias_m              = 1e-6;   % pseudo-meas sigma for bias gauge [m]
cfg.clock.gauge.sigmaDrift_mps           = 1e-9;   % pseudo-meas sigma for drift gauge [m/s]
cfg.clock.hardwareDelay.estimatePerTower = false;

% --- Transmitter code hardware-delay states ----------
% A transmitter code hardware delay is algebraically similar to a
% tower clock bias in one-way pseudorange.  Free simultaneous
% estimation of tower clock bias and tx code delay is forbidden
% (collinear in one-way code PR).  A delay gauge is mandatory when
% useInEKF=true.  All defaults are OFF so prior tests are unchanged.
cfg.hardware.txCodeBias.enable                    = false;
cfg.hardware.txCodeBias.useInEKF                  = false;
cfg.hardware.txCodeBias.mode                      = 'off';           % 'off' | 'perTowerL1'
cfg.hardware.txCodeBias.gaugeMode                 = 'fixReferenceTower'; % 'fixReferenceTower' | 'meanGroundDelayGauge'
cfg.hardware.txCodeBias.referenceTowerIndex       = 1;
cfg.hardware.txCodeBias.initialSigma_m            = 10.0;
cfg.hardware.txCodeBias.processSigma_m_per_sqrt_s = 1e-5;
cfg.hardware.txCodeBias.gaugeSigma_m              = 1e-6;

% --- Receiver code / carrier hardware-bias architecture ---
% Receiver code hardware delay has the same first-order sensitivity as
% receiver clock bias in single-frequency one-way pseudorange:
%   dP/d(b_rx) = +1,  dP/d(d_rx_code) = +1
% Free EKF estimation of both is not identifiable.  Allowed modes:
%   'off'                  — no correction applied (collinear term ignored)
%   'absorbedInReceiverClock'  — formally absorbed; default safe mode
%   'fixed'                — apply cfg.hardware.rxCodeBias.fixedValue_m to h
%   'externalCalibration'  — same as 'fixed' (value from external source)
%   'estimate'             — blocked; finalizeConfig throws an error
cfg.hardware.rxCodeBias.enable       = false;
cfg.hardware.rxCodeBias.mode         = 'absorbedInReceiverClock';
cfg.hardware.rxCodeBias.fixedValue_m = 0.0;
cfg.hardware.rxCodeBias.sigma_m      = 0.0;

% Receiver carrier phase hardware bias.  In float-ambiguity mode,
% constant phase hardware biases are absorbed into the float ambiguity
% states and are not separately estimable.  Allowed modes:
%   'notImplemented'     — default; no separate state or correction
%   'absorbedInAmbiguity'— explicitly declares absorption (carrier float only)
%   'fixed'              — apply cfg.hardware.rxCarrierBias.fixedValue_m
%   'externalCalibration'— same as 'fixed'
%   'estimate'           — blocked; finalizeConfig throws an error
cfg.hardware.rxCarrierBias.enable       = false;
cfg.hardware.rxCarrierBias.mode         = 'notImplemented';
cfg.hardware.rxCarrierBias.fixedValue_m = 0.0;
cfg.hardware.rxCarrierBias.sigma_m      = 0.0;

% --- Observability diagnostics (Step 8) -------------------------
cfg.diagnostics.observability.enabled       = false;
cfg.diagnostics.observability.warn          = true;
cfg.diagnostics.observability.rankTolerance = [];

% --- Clock observability Gramian ---------------------
% Windowed clock-subspace observability Gramian computed each epoch.
% Physical-only rank reveals the persistent one-way pseudorange nullspace.
% Gauged rank should equal n_clk after fixReferenceTower or meanGroundClockGauge.
cfg.diagnostics.clockObservability.enable             = true;
cfg.diagnostics.clockObservability.windowLengthEpochs = 60;
cfg.diagnostics.clockObservability.minWindowEpochs    = 5;
cfg.diagnostics.clockObservability.rankTolerance      = [];

% --- Diagnostics storage policy ---------------------------------
% mode: 'compact'     — never store full P/H/R/z/h (default; large runs safe)
%        'full'        — store full matrices every epoch (old behaviour; debug only)
%        'sampledFull' — compact every epoch + full snapshots every snapshot.interval_s
% Individual storeFullX flags: override per-field within compact/sampledFull.
% longRunAutoCompact: if a 'full'-mode run exceeds the duration/epoch thresholds,
%   automatically switch to 'compact' to protect memory.
cfg.diagnostics.storage.mode             = 'compact';
cfg.diagnostics.storage.storeFullP       = false;
cfg.diagnostics.storage.storeFullH       = false;
cfg.diagnostics.storage.storeFullR       = false;
cfg.diagnostics.storage.storeFullZ       = false;
cfg.diagnostics.storage.storeFullHpred   = false;

cfg.diagnostics.storage.storeStateVector          = true;
cfg.diagnostics.storage.storePdiag                = true;
cfg.diagnostics.storage.storeTruthEstimateErrors  = true;
cfg.diagnostics.storage.storeResidualSummaries    = true;
cfg.diagnostics.storage.storeConsistencyScalars   = true;
cfg.diagnostics.storage.storeMeasurementCounts    = true;
cfg.diagnostics.storage.storeClockSummaries       = true;
cfg.diagnostics.storage.storeAmbiguitySummaries   = true;
cfg.diagnostics.storage.storeSlipSummaries        = true;
cfg.diagnostics.storage.storeOrbitDiagnostics     = true;

cfg.diagnostics.storage.snapshot.enable          = true;
cfg.diagnostics.storage.snapshot.interval_s      = 600;
cfg.diagnostics.storage.snapshot.storeFullP      = true;
cfg.diagnostics.storage.snapshot.storeFullH      = true;
cfg.diagnostics.storage.snapshot.storeFullR      = true;
cfg.diagnostics.storage.snapshot.storeFullZ      = true;
cfg.diagnostics.storage.snapshot.storeFullHpred  = true;
cfg.diagnostics.storage.snapshot.maxSnapshots    = 200;
cfg.diagnostics.storage.snapshot.storeFirstLast  = true;

cfg.diagnostics.storage.longRunAutoCompact.enable             = true;
cfg.diagnostics.storage.longRunAutoCompact.durationThreshold_s = 7200;
cfg.diagnostics.storage.longRunAutoCompact.epochThreshold     = 10000;

% --- Array backend (SimulationDataStore) ------------------------
% 'legacyStruct': kept for backward compat but deprecated (SimulationDataStore is always active)
cfg.diagnostics.storage.backend = 'array';

% --- Data backend (v3 canonical) --------------------------------
cfg.data.backend                              = 'SimulationDataStore';
cfg.data.schemaVersion                        = 3;
cfg.data.storeFullMatricesEveryEpoch          = false;
cfg.data.snapshots.enable                     = false;
cfg.data.snapshots.interval_s                 = 600;
cfg.data.snapshots.maxSnapshots               = 200;
cfg.data.snapshots.storeFirstLast             = true;
cfg.data.heavyDiagnosticsInterval_s           = 300;
cfg.data.computeHeavyDiagnosticsEveryEpoch    = false;
cfg.data.legacyDiagnosticsEnable              = false;

% Full-matrix snapshot settings for array backend
cfg.diagnostics.storage.fullSnapshot.enable         = true;
cfg.diagnostics.storage.fullSnapshot.interval_s     = 600;
cfg.diagnostics.storage.fullSnapshot.maxSnapshots   = 200;
cfg.diagnostics.storage.fullSnapshot.storeFirstLast = true;
cfg.diagnostics.storage.fullSnapshot.storeP         = true;
cfg.diagnostics.storage.fullSnapshot.storeH         = true;
cfg.diagnostics.storage.fullSnapshot.storeR         = true;
cfg.diagnostics.storage.fullSnapshot.storeZ         = true;
cfg.diagnostics.storage.fullSnapshot.storeHpred     = true;

% --- Diagnostic sampling ----------------------------------------
% heavyDiagnosticsInterval_s: sample rank/cond/SVD at this interval
% (0 = every epoch). For 24h at 1s: 60s → 1440 heavy epochs vs 86400.
cfg.diagnostics.sampling.heavyDiagnosticsInterval_s    = 0;  % 0 = every epoch
cfg.diagnostics.sampling.computeRankEveryEpoch          = true;
cfg.diagnostics.sampling.computeConditionEveryEpoch     = true;
cfg.diagnostics.sampling.computeAttitudeSvdEveryEpoch   = true;
cfg.diagnostics.sampling.computeClockObservabilityEveryEpoch = true;

% --- Plots -------------------------------------------------------
% showFigures = false: figures created with Visible='off', saved to file.
% saveIndividualFigures: save each figure as .png and .fig.
% savePdf: save multi-page PDF report.
% closeAfterSave: close each figure after saving (keeps memory low).
cfg.plots.enable                = true;
cfg.plots.showFigures           = false;
cfg.plots.saveIndividualFigures = true;
cfg.plots.saveFigures           = true;   % legacy alias
cfg.plots.savePdf               = true;
cfg.plots.closeAfterSave        = false;
cfg.plots.outputDir             = fullfile(fileparts(mfilename('fullpath')), ...
    '..', 'output', 'figures');

% --- Report ---------------------------------------------------
cfg.report.enable              = true;
cfg.report.version             = '1.00';
% Monte-Carlo NEES/NIS filter-consistency evidence appended to the run (.out log).
% A single run gives one NEES/NIS sample; chi-squared consistency is only meaningful over
% an ensemble. Default OFF (golden byte-identical; expensive = N extra full runs). When on,
% ReportRunner runs N seeded draws (initial error from P0, varied measurement/atmosphere +
% clock-truth seeds) and band-checks the pooled NIS/NEES. baseConfig 'self' characterises
% the SHIPPED filter (conservative-by-design -> expected below band); 'matchedBaseline'
% gives a two-sided verdict.
cfg.report.monteCarlo.enable      = false;
cfg.report.monteCarlo.nSeeds      = 12;
cfg.report.monteCarlo.duration_s  = 900;      % short override; the shipped run is much longer
cfg.report.monteCarlo.confidence  = 0.99;
cfg.report.monteCarlo.baseConfig  = 'self';   % 'self' | 'matchedBaseline'
cfg.report.baseOutputDir       = fullfile(fileparts(mfilename('fullpath')), '..', 'output');
cfg.report.dateFolderPrefix    = 'Report-';
cfg.report.overwrite           = true;
cfg.report.writePdf            = true;
cfg.report.writeMat            = true;
cfg.report.appendRawPlots         = false;
cfg.report.layout                 = 'default'; % 'default' | 'clockStyle' | 'clockExact'
cfg.report.includeRawDiagnostics  = false;
cfg.report.zoomLastSeconds        = 120;       % EKF zoom plots show the last N seconds (fixed window)

% --- Validation policy ----------------------------------------
% 'error'             — unsupported features throw (default; safe)
% 'disableWithWarning'— unsupported features disabled with a warning
cfg.validation.unsupportedFeaturePolicy = 'error';
cfg.validation.warnings         = {};
cfg.validation.disabledFeatures = {};
cfg.validation.mappedFeatures   = {};
end
