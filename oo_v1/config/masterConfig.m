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
%   Limitations: signal-dependent hardware delays default to zero and configured
%   code DCB is global per signal (no calibrated per-link product); the Doppler
%   ionosphere-rate term is not modelled; the PR/Doppler shared tower-clock
%   cross-covariance is ignored (block-diagonal R).
    thisDir   = fileparts(mfilename('fullpath'));   % .../oo_v1/config
    oo_v1Root = fileparts(thisDir);                 % .../oo_v1
    addpath(oo_v1Root);                             % +revgnss builders
    addpath(thisDir);                               % master config folder
    addpath(fullfile(thisDir, 'internal'));          % internal config helpers

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
cfg.scenario.name         = 'singleAssetNominalNavigation';
cfg.scenario.nSpaceAssets = 1;        % helix ISL swarm (5 secondaries) -> ~3 cm / ~50 ps
cfg.scenario.nTowers      = 5;        % 5-tower default (frozen-golden network). baseConfig
                                      % defines 12 real sites; set nTowers=12 for the wide
                                      % network that breaks the single-GEO radial<->clock
                                      % degeneracy (towers 6-12 are the extra real sites).
cfg.scenario.orbitClass   = 'GEO';    % 'GEO' | 'MEO' | 'LEO'
% Receiver antennas. One antenna is sufficient for the nominal star-tracker/gyro
% attitude solution. Four antennas are required only by explicit GNSS lever-arm
% attitude experiments.
cfg.scenario.nReceivers   = 1;

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
% Light-time is iterative one-way; the relativistic clock term is guarded off.
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
% simpleMapped models with independent nominal truth and correction values.
cfg.errors.troposphere.enable              = true;
cfg.errors.troposphere.modelType           = 'simpleMapped';
cfg.errors.troposphere.truth.zenithDelay_m = 2.45;
cfg.errors.troposphere.model.zenithDelay_m = 2.30;
cfg.errors.troposphere.model.biasFraction  = 1;
cfg.errors.troposphere.stochastic.enable   = false;
% Declared model uncertainty. Must be consistent with the model error this config
% actually commits: truth 2.45 - model 2.30*biasFraction = 0.15 m at zenith. It read
% 0.10 while the stochastic sigma (switched off, but formerly still charged into R)
% quietly made up the difference. 0.10 -> 0.15 states the same total honestly.
cfg.errors.troposphere.sigma_m             = 0.15;
cfg.errors.ionosphere.enable               = true;
cfg.errors.ionosphere.modelType            = 'simpleMapped';
cfg.errors.ionosphere.truth.zenithDelay_m  = 5;
cfg.errors.ionosphere.model.zenithDelay_m  = 4;
cfg.errors.ionosphere.model.biasFraction   = 1;
cfg.errors.ionosphere.stochastic.enable    = false;
cfg.errors.ionosphere.scintillation.enable = false;
cfg.errors.ionosphere.higherOrder.enable   = false;
% Declared model uncertainty. Twin of the troposphere case: this config commits a
% truth 5 - model 4*biasFraction = 1.00 m zenith model error while declaring only
% 0.50 m of uncertainty, with the disabled stochastic sigma silently covering the
% rest inside R. 0.50 -> 1.00 makes the declaration match the committed error.
cfg.errors.ionosphere.sigma_m              = 1.00;

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
% sharedErrorCorrelation currently only ASSERTS that a tower's product noise is shared across
% consumers -- it gates no logic (models.clocks.TowerClockCorrectionProvider reads it into
% pc.sharedErrorCorrelation and nothing else consumes that field except a report row). The
% ACTUAL sharing is that models.clocks.TowerClockCorrectionProvider.productNoise_'s correction
% residual is a DETERMINISTIC function of (towerIndex,productEpoch) -- identical for every real
% consumer of that pair regardless of process or asset (the persistent cache is memoization of
% that deterministic value, not the source of the sharing; clearing it would reproduce the same
% number). This is unconditional whenever towerClockMode~='perfectCorrection', regardless of this
% flag's value; revgnss.IndependentFleetCoordinator.validateConfig's
% towerClockProductReachableButRejected guard is what currently prevents that reachable-but-
% untreated combination in a multi-asset independent fleet with an enabled correlation network
% (plan Section 3.3). This flag is reserved as the future enable bit for a real MEASUREMENT-SPACE
% tracked-covariance-group treatment (an R-term, the missing K_i*R_ij*K_j' cross term consumed by
% revgnss.CommonSourceCovarianceGroup -- NOT a Q-term on the network's own state-space cross
% blocks, which is a separate mechanism; see revgnss.DistributedLinkProtocolContract.
% CommonSourceNames's own comment), not yet built.
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
% Quaternion nominal plus local error-state EKF driven by star-tracker observations
% and inertial gyro measurements. Carrier attitude and integer search are disabled.
cfg.estimator.attitude.parameterization           = 'quaternionErrorState';
cfg.estimator.attitude.maxErrorStateInjection_rad = deg2rad(10);
cfg.diagnostics.attitudeCovarianceReset.enable    = true;
cfg.estimator.attitude.primaryMode                = 'starTrackerGyroscope';
cfg.estimator.attitudeCarrierMode                 = 'off';
cfg.estimator.starTracker.enable                  = true;
cfg.estimator.starTracker.useInEKF                = true;
cfg.estimator.starTracker.updatePeriod_s          = 1;
cfg.estimator.starTracker.updatePhase_s           = 0;
cfg.estimator.starTracker.whiteAngularSigma_rad   = deg2rad(10/3600);
cfg.estimator.starTracker.outages_s               = zeros(0,2);
cfg.estimator.starTracker.truth.seed              = 1201;
cfg.estimator.starTracker.truth.fixedAlignmentBias_rad = zeros(3,1);
cfg.estimator.starTracker.truth.alignmentDriftRate_radps = zeros(3,1);
cfg.estimator.starTracker.truth.alignmentDriftRandomWalk_rad_per_sqrt_s = 0;
cfg.estimator.starTracker.truth.drawAlignmentFromCalibrationCovariance = false;
cfg.estimator.starTracker.calibration.identifier  = 'star-tracker-body-alignment-v1';
cfg.estimator.starTracker.calibration.q_B_S_wxyz  = [1;0;0;0];
cfg.estimator.starTracker.calibration.covariance_rad2 = zeros(3);
cfg.estimator.starTracker.calibration.validFrom_s = 0;
cfg.estimator.starTracker.calibration.validUntil_s = 1e12;
cfg.estimator.starTracker.calibration.treatment   = 'fixedCalibration';
cfg.estimator.starTracker.calibration.driftProcessNoise_rad2ps = zeros(3);
cfg.estimator.imu.enable                          = true;
cfg.estimator.estimateGyroBias                    = true;
cfg.estimator.diffAtt.calibWin_s                  = 60;
cfg.estimator.diffAtt.referenceMode               = 'selfCalibrated';
cfg.estimator.diffAtt.referenceSigma_deg          = 0.1;
cfg.estimator.diffAtt.solutionInterpretation = ...
    'relativeAttitudeTrackingConditionedOnInitialPrior';
cfg.estimator.attitude.carrierSignal              = 'L1';   % documentary (report builder)
cfg.estimator.attitude.useRawCarrierForAttitude   = true;   % documentary (report builder)
cfg.estimator.attitudeInitMode                    = 'none';
cfg.estimator.attitudeInit.knownAttitudeCalibration.allow    = false;
cfg.estimator.attitudeInit.search.windowDeg               = [2; 2; 2];
cfg.estimator.attitudeInit.search.stepDeg                 = [0.5; 0.5; 0.5];
cfg.estimator.attitudeInit.search.maxCandidates           = 729;
cfg.estimator.attitudeInit.search.ratioThreshold          = 1.20;
cfg.estimator.attitudeInit.search.ambiguousRatioThreshold = 1.01;
cfg.estimator.attitudeInit.search.improvementRatioThreshold = 1.05;
cfg.estimator.attitudeInit.search.maxRmsCycles            = 0.30;
cfg.estimator.attitudeInit.search.sigmaScaleDeg            = 2.0;
cfg.estimator.attitudeInitShadow.enable                   = false;

%% Estimator: ambiguity resolution
% Guarded raw-carrier integer fixing for the receiver-baseline attitude system, with
% hardened gates. Carrier ionosphere-free integer fixing is explicitly unsupported.
cfg.estimator.integerAmbiguity.enable                      = false;
cfg.estimator.integerAmbiguity.mode                        = 'controlledRawCarrier';
cfg.estimator.integerAmbiguity.minArcLength_s              = 300;
cfg.estimator.integerAmbiguity.maxSigma_cycles             = 0.15;
cfg.estimator.integerAmbiguity.maxDistanceToInteger_cycles = 0.20;
cfg.estimator.integerAmbiguity.maxResidualRmsIncrease_m    = 0.01;
cfg.estimator.integerAmbiguity.fixVariance_cycles2         = 1e-4;
cfg.estimator.integerAmbiguity.resetOnSlip                 = true;
% --- LAMBDA / MLAMBDA integer ambiguity resolution (feature/ISL-LAMBDA). Default OFF. ---
% Wraps the TU Delft LAMBDA 4.0 toolbox (Massarweh/Verhagen/Teunissen 2024) for a proper
% ILS search, replacing per-ambiguity ROUNDING (the weakest integer estimator, which is
% what cfg.estimator.integerAmbiguity does today) and adding the false-fix protection it
% explicitly lacks: every fix is gated on a bootstrapped success rate.
%
% EXTERNAL DEPENDENCY -- the toolbox is NOT vendored. Its files carry a TU Delft copyright
% with NO licence grant, so shipping them in this public repo would be unlicensed. Point
% toolboxPath at your own copy (like the Orekit bridge); when absent the resolver returns
% the FLOAT solution and reports 'unavailable-toolbox' rather than erroring.
%
% VALIDITY PRECONDITION: LAMBDA assumes the float vector's TRUTH is an integer. The
% UNDIFFERENCED ambiguities here are not -- they absorb the per-arc clock/hardware bias --
% so only DIFFERENCED (between-antenna / between-satellite) or bias-calibrated vectors may
% be fixed. See docs/plans/ISL_LAMBDA/03_LAMBDA_INTEGER_RESOLUTION.md.
cfg.estimator.lambda.enable          = false;   % master gate for the LAMBDA engine
cfg.estimator.lambda.toolboxPath     = '';      % e.g. '/path/to/LAMBD4-master_2024_10_01'
cfg.estimator.lambda.method          = 3;       % 3=ILS search-and-shrink, 5=PAR, 1=rounding
cfg.estimator.lambda.nCands          = 2;       % >=2 so a ratio test is possible
cfg.estimator.lambda.minSuccessRate  = 0.999;   % bootstrapped SR floor (Ps_LAMBDA)
cfg.estimator.lambda.ratioThreshold  = 2.0;     % sqnorm(2)/sqnorm(1) discrimination test
% Per-domain gates, INDEPENDENT of each other (ISL vs ground-to-space must be separately
% togglable). Both require cfg.estimator.lambda.enable as the master switch.
cfg.estimator.lambda.ground.enable   = false;   % ground-to-space carrier AR
cfg.estimator.lambda.isl.enable      = false;   % inter-satellite carrier AR
% Route B FEEDBACK: when true the accepted DIFFERENCED integers are injected back into the
% filter as a linear constraint (the conditional mixed-integer update). False = assess and
% report only. The constraint is DETERMINISTIC, so it is applied ONCE PER ARC and held --
% re-applying every epoch would double-count the same information and collapse P.
cfg.estimator.lambda.isl.applyFix    = false;
cfg.estimator.lambda.isl.fixSigma_m  = 1e-3;    % tightness of the injected constraint [m]
cfg.estimator.diffAtt.ambiguityResolution.enable                       = false;
cfg.estimator.diffAtt.ambiguityResolution.method                       = 'constrainedBaselineIntegerSearch';
cfg.estimator.diffAtt.ambiguityResolution.signal                       = 'L1';
cfg.estimator.diffAtt.ambiguityResolution.searchHalfWidth_cycles       = 5;
cfg.estimator.diffAtt.ambiguityResolution.minArcEpochs                 = 60;
cfg.estimator.diffAtt.ambiguityResolution.rmsThreshold_cycles          = 0.10;
cfg.estimator.diffAtt.ambiguityResolution.ratioThreshold               = 3.0;
cfg.estimator.diffAtt.ambiguityResolution.useExternalReferenceAsSearchCenter = false;
cfg.estimator.diffAtt.ambiguityResolution.allowExternalReferenceFallback     = false;
cfg.estimator.diffAtt.ambiguityResolution.maxFloatDistance_cycles      = 0.25;
cfg.estimator.diffAtt.ambiguityResolution.requireAllForGnssOnlyClaim   = true;
cfg.estimator.diffAtt.ambiguityResolution.partialFixPolicy             = 'mixedFixedFloat';
cfg.estimator.diffAtt.ambiguityResolution.phaseBiasStatus              = 'notCalibratedExternalProduct';
cfg.estimator.diffAtt.ambiguityResolution.enforcePhaseBiasStatus       = false;
cfg.estimator.diffAtt.ambiguityResolution.requirePhaseBiasCalibrationForFix = true;
cfg.estimator.diffAtt.ambiguityResolution.falseFixClassification       = 'screenedNotFormal';
cfg.estimator.diffAtt.ambiguityResolution.maxWideLaneFloatDistance_cycles    = 0.5;
cfg.estimator.diffAtt.ambiguityResolution.differentialIonosphereInBaselineAr = 'neglectedShortBaselineV1';

%% Carrier slip detection
% Disabled while ionosphere-free carrier rows are formed before per-frequency tracking.
cfg.measurements.carrier.slipDetection.enable                = false;
cfg.measurements.carrier.slipDetection.minEpochsBeforeDetect = 3;
cfg.measurements.carrier.slipDetection.resetSigma_m          = 100;
cfg.measurements.carrier.slipDetection.action                = 'resetAndSkip';
cfg.carrierSlip.enable                          = false;
cfg.carrierSlip.method                          = 'modelStepCompensatedResidualJump';
cfg.carrierSlip.threshold_m                     = 0.10;
cfg.carrierSlip.minArcLength_s                  = 300;
cfg.carrierSlip.productStepCompensation         = true;
cfg.carrierSlip.atmosphereStepCompensation      = true;
cfg.carrierSlip.antennaStepCompensation         = true;
cfg.carrierSlip.hardwareStepCompensation        = true;
cfg.carrierSlip.diffAttitudeBaselineMode        = true;
cfg.carrierSlip.commonModeCompensation.enable   = false;
cfg.carrierSlip.commonModeCompensation.minRows  = 4;
cfg.carrierSlip.baselineDifferencedMode.enable  = false;
cfg.carrierSlip.baselineDifferencedMode.referenceAntenna = 1;
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
% Carrier rows carry the SAME product residual as the code rows (z has -b_twr_true,
% h has -b_twr_model), so the constant bias belongs in the carrier R too. Previously
% false AND unread: the block was skipped on the grounds that the float ambiguity
% absorbs a per-arc constant, but the generator redraws the bias every product
% interval (30 s), which the ambiguity cannot track (~0.055 mm of process noise per
% interval against a 10-100 mm step). Now a live control, default ON.
cfg.covariance.sharedErrors.applyTowerClockToCarrier = true;
cfg.covariance.sharedErrors.applyTowerClockToDoppler = false;
cfg.covariance.sharedErrors.carrierPolicy            = 'sharedProductBiasAndDriftBlocks';
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
% Unsupported features fail during configuration resolution.
cfg.validation.unsupportedFeaturePolicy   = 'error';
cfg.validation.fullSuiteRun               = false;
cfg.estimator.runKnownAmbiguityValidation = false;

% Predeclared scientific acceptance rules. These values define a campaign; they do
% not claim that the statistical campaign has already been executed.
cfg.validation.manifest.identifier = 'coherent-two-way-code-and-attitude-v1';
cfg.validation.manifest.status = 'declaredNotStatisticallyExecuted';
cfg.validation.manifest.shortEnsemble.seedList = 1001:1200;
cfg.validation.manifest.shortEnsemble.minimumIndependentRuns = 200;
cfg.validation.manifest.fullScenario.seedList = 5001:5050;
cfg.validation.manifest.fullScenario.minimumIndependentRuns = 50;
cfg.validation.manifest.fullScenario.duration_s = 3600;
cfg.validation.manifest.lightTime.maximumResidual_s = 1e-11;
cfg.validation.manifest.range.maximumZeroNoiseClosure_m = 1e-3;
cfg.validation.manifest.jacobian.maximumRelativeError = 1e-5;
cfg.validation.manifest.jacobian.maximumAbsoluteError = 1e-7;
cfg.validation.manifest.statistics.confidence = 0.95;
cfg.validation.manifest.statistics.burnInFraction = 0.5;
cfg.validation.manifest.statistics.evaluationRule = ...
    'fixedEpochsAcrossIndependentRuns';
cfg.validation.manifest.attitude.initialError_deg = [1;-1;0.5];
cfg.validation.manifest.attitude.maximumConvergenceTime_s = 60;
cfg.validation.manifest.attitude.maximumFinalError_deg = 0.05;
cfg.validation.manifest.attitude.maximumOutageRecoveryTime_s = 30;
cfg.validation.manifest.attitude.requireThreeSigmaCoverage = true;
cfg.validation.manifest.numerics.maximumCovarianceAsymmetry = 1e-10;
cfg.validation.manifest.numerics.minimumCovarianceEigenvalue = -1e-10;

cfg.validation.scientificCampaign.enable = false;
cfg.validation.scientificCampaign.profile = 'light';
cfg.validation.scientificCampaign.seedList = [85, 185, 285];
cfg.validation.scientificCampaign.duration_s = 900;
cfg.validation.scientificCampaign.runNominal = true;
cfg.validation.scientificCampaign.runL1Only = true;
cfg.validation.scientificCampaign.runDegradedClockProduct = true;
cfg.validation.scientificCampaign.runSlipInjection = true;
cfg.validation.scientificCampaign.runReducedTowerGeometry = false;
unassessedAccuracyCriteria = struct( ...
    'positionRmsPassLimit_m', NaN, ...
    'clockBiasRmsPassLimit_m', NaN, ...
    'positionRmsWarningLimit_m', NaN, ...
    'clockBiasRmsWarningLimit_m', NaN);
campaignCases = { ...
    'nominalDualFrequency', 'l1Only', 'degradedClockProduct', ...
    'slipInjection', 'reducedTowerGeometry'};
for campaignCaseIndex = 1:numel(campaignCases)
    cfg.validation.scientificCampaign.acceptanceCriteria. ...
        (campaignCases{campaignCaseIndex}) = unassessedAccuracyCriteria;
end

% ================================================================
% SCENARIO ASSEMBLY  (runs after the toggles; may override a few of them)
%   Nominal single-spacecraft navigation with absolute attitude sensors.
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
cfg.scenario.name         = 'singleAssetNominalNavigation';
cfg.scenario.nReceivers   = size(arms,2);
cfg.asset.receiverLeverArms_body_m = arms;
cfg.asset.receiverLeverArm_body_m  = arms(:,1);
cfg.assets(1).receiverLeverArms_body_m = arms;
cfg.assets(1).receiverLeverArm_body_m  = arms(:,1);

%% Attitude estimation setup
% Absolute attitude is supplied by the star tracker and inertial gyro.
cfg.estimator.estimateAttitude                   = true;
cfg.estimator.estimateAngularRate                = false;
cfg.estimator.estimateAttitudeFromPseudorange    = false;
cfg.estimator.estimateAngularRateFromPseudorange = false;
cfg.estimator.attitude.useCarrierPartials        = false;
cfg.estimator.attitude.useCodePartials           = false;
cfg.estimator.attitude.useDopplerPartials        = false;

%% Initial state and covariance
% Initial attitude error and the diagonal covariance/process-noise seeds for the run.
cfg.estimator.P0_euler_rad             = deg2rad(5);
cfg.estimator.P0_omega_radps           = 1e-12;
cfg.estimator.sigma_angAccel_radps2    = 1e-7;
cfg.estimator.initialError.euler_deg   = [1; -1; 0.5];
cfg.estimator.initialError.omega_radps = [0; 0; 0];

%% Carrier / ambiguity and arc handling (scenario)
% Re-assert the carrier float-ambiguity EKF and retain independent arc states.
% Cross-frequency arc consistency is unavailable in the runtime row ordering.
cfg.measurements.carrierPhase.enable = true;
cfg.measurements.carrierMode         = 'ekfFloat';
cfg.estimation.ambiguityMode         = 'floatPerTowerReceiverSignal';
cfg.measurements.carrier.slipDetection.enable = false;
if ~isfield(cfg.measurements.carrier.slipDetection,'threshold_m')
    cfg.measurements.carrier.slipDetection.threshold_m           = 0.1;
    cfg.measurements.carrier.slipDetection.minEpochsBeforeDetect = 3;
    cfg.measurements.carrier.slipDetection.resetSigma_m          = 100;
    cfg.measurements.carrier.slipDetection.action                = 'resetAndSkip';
end
cfg.estimator.arcSeparatedAmbiguities.enable            = false;
cfg.estimator.enforceCarrierArcConsistency.enable       = false;
cfg.diagnostics.arcSeparatedAmbiguities.enable          = false;
cfg.diagnostics.carrierArcConsistencyEnforcement.enable = false;
cfg.diagnostics.carrierArcEvidence.enable               = false;

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
    % Gated inter-satellite light-time correction (~1 cm/km at km baselines): the beacon
    % moves during the signal transit, a systematic the instantaneous |r1-r2| omits. Matters
    % for cm-class carrier-phase / precise-product ISL; negligible for the 0.3 m code row.
    % Cross-validated sub-mm against Orekit's rigorous inter-satellite light-time. Default OFF
    % keeps the swarm fingerprint byte-identical; applied to truth AND model when enabled.
    cfg.measurements.isl.lightTime.enable = false;
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
cfg.measurements.twoWayTimeTransfer.mode     = 'firstOrderReciprocal';
cfg.measurements.twoWayTimeTransfer.towers   = 'all';   % which ground towers are two-way capable
cfg.measurements.twoWayTimeTransfer.sigma_m  = 0.03;    % two-way time uncertainty 1-sigma [m] (~100 ps)

%% Reserved per-secondary ground-space time transfer. Default OFF.
% No observation builder consumes this block. Canonical validation rejects activation.
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
% applyAtmosphereProfile) so the golden opts out with the single flag below.
%
%   atmosphere.realistic
%     true  -> Saastamoinen/Niell troposphere (+per-tower ZWD EKF) and a
%              diurnal+stochastic ionosphere (Klobuchar + higher-order + gated
%              scintillation): non-cancelling, physically-sized truth-model residuals.
%     false -> simpleMapped nominal atmosphere with independent truth/model values.
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
cfg.atmosphere.realistic      = false;
cfg.atmosphere.ionosphereFree = false;   % L1/L2 ionosphere-free combination
cfg.atmosphere.estimateIono   = false;   % per-tower slant-ionosphere EKF state

% --- Formation scope of the STOCHASTIC atmosphere -------------------------------
%   atmosphere.sharedAcrossFormation.enable  (default false -> legacy, byte-identical)
%
%   false (default): every asset builds its own EnvironmentModel rooted at its own
%     cfg.simulation.seed (offset per asset by the federated fan-out in ReportRunner),
%     so swarm members draw STATISTICALLY INDEPENDENT troposphere, ionosphere and
%     scintillation. Fine for a single asset; wrong for a formation.
%
%   true: the four stochastic atmosphere states (tropo wet GM, iono TEC GM,
%     scintillation amplitude GM, phase-scintillation GM) and the per-measurement
%     scintillation truth draw are rooted at a FORMATION-WIDE seed and keyed by
%     (source, tower, epoch). Every asset then sees the SAME per-tower atmosphere.
%
%   Why true is the physical answer for a cluster: two satellites 2 km apart at GEO
%   viewing one tower have ray paths diverging by 2000/36e6 rad = 11 arcsec -- ~0.5 m
%   of separation at the top of the troposphere, ~18 m at a 350 km ionospheric pierce
%   point. Both are far inside the decorrelation scale (km for tropo, tens of km for
%   iono) and inside the L-band Fresnel scale sqrt(lambda*z) ~ 260 m that sets
%   scintillation coherence. They look through ONE air column, so the delay is
%   common-mode and a between-satellite single difference should retain only the
%   ~0.006-1.6 mm the 11 arcsec geometry justifies. With independent draws it instead
%   carries sqrt(2) x (0.047-0.104 m tropo + 0.34-0.62 m iono + 0.34-2.12 m
%   scintillation) -- 2-3 orders of magnitude too large, and with 600 s / 10800 s
%   Gauss-Markov correlation times it barely averages down. Any between-satellite
%   differenced ground observable (differenced carrier, ground-code DD for rotation)
%   is evaluated against that artefact unless this is on.
%
%   Scope: assets only. Distinct TOWERS keep independent atmospheres (they are
%   hundreds of km apart), and separate receive antennas on one asset keep their
%   independent scintillation draw, as before. Receiver thermal noise, clocks,
%   multipath and hardware delays stay rooted at the per-asset seed either way.
%
%   NOT the same as cfg.rng.independentStreams.enable=false: that also gives every
%   asset a byte-identical atmosphere (via the shared envRng seeded from
%   cfg.environment.weather.seed) but collapses EVERY other noise stream too, so it
%   is not a usable scientific control. This flag touches only the atmosphere.
cfg.atmosphere.sharedAcrossFormation.enable = false;
cfg.atmosphere.sharedAcrossFormation.seed   = 7201;   % formation-wide root (not per asset)

% Complex atmosphere profile selected by realism.json.
cfg.atmosphere.realisticProfile.errors.troposphere.enable = true;
cfg.atmosphere.realisticProfile.errors.troposphere.truth.enable = true;
cfg.atmosphere.realisticProfile.errors.troposphere.model.enable = true;
cfg.atmosphere.realisticProfile.errors.troposphere.modelType = 'localWeatherGM';
cfg.atmosphere.realisticProfile.errors.troposphere.dayOfYear = 180;
cfg.atmosphere.realisticProfile.errors.troposphere.truth.mappingType = 'niell';
cfg.atmosphere.realisticProfile.errors.troposphere.model.mappingType = 'niell';
cfg.atmosphere.realisticProfile.errors.troposphere.stochastic.enable = true;
cfg.atmosphere.realisticProfile.errors.troposphere.stochastic.process = 'gaussMarkov';
cfg.atmosphere.realisticProfile.errors.troposphere.stochastic.tau_s = 10800;
cfg.atmosphere.realisticProfile.errors.troposphere.stochastic.sigmaWet_ss_m = 0.04;
cfg.atmosphere.realisticProfile.errors.troposphere.stochastic.modelResidual.enable = false;
cfg.atmosphere.realisticProfile.estimation.troposphereMode = 'perTowerZwd';
cfg.atmosphere.realisticProfile.environment.weather.hydrostaticModelAssumption = ...
    'perfectSurfaceMeteorology';

cfg.atmosphere.realisticProfile.errors.ionosphere.enable = true;
cfg.atmosphere.realisticProfile.errors.ionosphere.truth.enable = true;
cfg.atmosphere.realisticProfile.errors.ionosphere.model.enable = true;
cfg.atmosphere.realisticProfile.errors.ionosphere.modelType = 'tecGaussMarkov';
cfg.atmosphere.realisticProfile.errors.ionosphere.truth.diurnal.enable = true;
cfg.atmosphere.realisticProfile.errors.ionosphere.truth.diurnal.vtecDay_TECU = 30;
cfg.atmosphere.realisticProfile.errors.ionosphere.truth.diurnal.vtecNight_TECU = 6;
cfg.atmosphere.realisticProfile.errors.ionosphere.truth.diurnal.peakLocalTime_h = 14;
cfg.atmosphere.realisticProfile.errors.ionosphere.topsideFraction = 1;
cfg.atmosphere.realisticProfile.errors.ionosphere.stochastic.enable = true;
cfg.atmosphere.realisticProfile.errors.ionosphere.stochastic.process = 'gaussMarkov';
cfg.atmosphere.realisticProfile.errors.ionosphere.stochastic.tau_s = 600;
cfg.atmosphere.realisticProfile.errors.ionosphere.stochastic.sigmaVDelayL1_ss_m = 0.3;
cfg.atmosphere.realisticProfile.errors.ionosphere.model.correction = 'klobuchar';
cfg.atmosphere.realisticProfile.errors.ionosphere.higherOrder.enable = true;
cfg.atmosphere.realisticProfile.effects.ionosphere.mappingModel = 'thinShell';
cfg.atmosphere.realisticProfile.effects.ionosphere.shellHeight_m = 350e3;
cfg.atmosphere.realisticProfile.errors.ionosphere.scintillation.enable = true;
cfg.atmosphere.realisticProfile.errors.ionosphere.scintillation.model = 'conker';
cfg.atmosphere.realisticProfile.errors.ionosphere.scintillation.S4zen = 0.3;
cfg.atmosphere.realisticProfile.errors.ionosphere.scintillation.tau_s = 30;
cfg.atmosphere.realisticProfile.errors.ionosphere.scintillation.phaseScint.enable = true;
cfg.atmosphere.realisticProfile.errors.ionosphere.scintillation.phaseScint.sigmaPhi_rad = 0.2;
cfg.atmosphere.realisticProfile.errors.ionosphere.scintillation.phaseScint.tau_s = 1.5;

%% Orbit class  (GEO | MEO | LEO — SINGLE switch)
% Change cfg.scenario.orbitClass (set under %% Scenario above) to move the whole
% run between orbit classes. config/internal/orbitClassConfig overrides altitude,
% inclination, RAAN, initial true anomaly and the SNC process noise for MEO/LEO;
% 'GEO' (default) is a strict no-op so the frozen goldens stay byte-identical.
cfg = orbitClassConfig(cfg);

%% Realism grade  (realism fixes — SINGLE opt-in switch)
% false (default) -> the current headline config; the frozen goldens are unaffected.
% true  -> overlay config/internal/realismGradeConfig: realistic JOW caesium clock, IGS-RTS tower
%          product sigma, C/N0 code weighting, multipath/hardware/PCV/survey/DCB truth
%          systematics, relativistic clock, honest measurement floors, luni-solar process
%          noise, and realistic ISL product sigma. Makes the run physically representative
%          rather than an idealised twin. See docs/scientific_correctness_review_v4.md.
%          New-physics effects (truth luni-solar propagator, unknown inter-antenna carrier
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
cfg.realism.include.luniSolar               = true;   % R-3  truth perturbations with reduced-dynamics EKF
cfg.realism.include.relativity              = true;   % Relativistic receiver-clock offset
cfg.realism.include.islProductSigma         = true;   % ISL  realistic secondary product sigma
cfg.realism.include.eop                      = true;   % R-8  uncorrected EOP frame residual (truth)
cfg.realism.include.solidEarthTide          = true;   % R-8  solid-Earth tide (truth)
cfg.realism.include.interAntennaCarrierBias = true;   % R-6  unknown inter-antenna carrier bias (truth)
% The four below were previously UNDECLARED here: realismGradeConfig's i_resolveIncludes
% invented them with default true, so they were invisible to anyone reading this file.
% Declared now at their existing values -> zero behaviour change, they are just no longer
% hidden. Note the block description above promises only "realistic ISL PRODUCT sigma", so
% islCarrier/islLinkBudget go beyond what realism.grade documents itself as doing; whether
% they belong here at all is the open question (measure the battery/ladder swarm slices first).
cfg.realism.include.islCarrier          = true;   % ISL carrier/noise parameters; does not enable rows
cfg.realism.include.islLinkBudget       = true;   % synthetic diagnostic parameters; does not enable it
% These two replace the former 'point34' (named after docs/attitude_improvement_review/
% point_3_*.md and point_4a_*.md -- a doc citation, not an effect, bundling two concerns).
% Both differ in KIND from every entry above: those add physical error sources to the TRUTH,
% these change ESTIMATOR behaviour and REPORT honesty.
cfg.realism.include.carrierArcSurvival  = true;   % common-mode + baseline-differenced slip guard
cfg.realism.include.phaseBiasHonesty    = true;   % report the RESOLVED phase-bias status, not the ideal one
cfg.realism.include.attitudeSensorNoise = true;   % conservative star-tracker and gyro noise
% Compatibility field for older callers. Canonical resolution applies the realism profile
% before explicit JSON overrides, so post-merge profile application is forbidden.
cfg.realism.resolvePostMerge = false;
if isfield(cfg,'realism') && isfield(cfg.realism,'grade') && cfg.realism.grade
    cfg = realismGradeConfig(cfg);
end

% --- Resolve the multi-asset mode preset BEFORE the estimateMode-dependent overlays and
% the contract check, so applyInjectTruthSideDynamics and validateMasterConfig see the
% granular toggles the switch expands to. No-op for 'fast' (the default). finalizeConfig
% re-resolves it for ordering-safety when nSpaceAssets/mode are set after masterConfig().
cfg = revgnss.ConfigFactory.applyMultiAssetMode(cfg);

% --- Optional force-stressor / per-tower-hardware overlays (gated; no-op unless enabled) ------
% Standalone config/internal functions (like realismGradeConfig): masterConfig applies them for the
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

% defaultConfig  GEO-1 honest off=off baseline.
%
% The base default injects NO error effects: troposphere, ionosphere, hardware delay,
% multipath, tower survey and antenna PCV/PCO are all OFF, and the EKF uses RAW
% measurement rows (ionosphere-free rows are opt-in and require L1+L2). Turning an
% effect on adds a REAL error the estimator does not perfectly cancel (it uses the
% estimated state, clock products and estimated atmosphere). Named presets set what
% they need on top: masterConfig (the canonical run), atmosphereConfig, and
% cleanConfig (explicit all-off).
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

% Enable Sun/Moon third-body and SRP in both propagators as one force-family option.
% Individual truth and estimator controls remain available for stress testing.
cfg.perturbations.sunMoon.enable = false;
% Sun/Moon ephemeris for the luni-solar perturbation (consulted by applyLuniSolar ->
% OrbitPerturbations). 'mg' = Montenbruck & Gill low-precision analytic (default; ~0.6 m /
% 4 h luni-solar truth-fidelity gap vs DE-440, adequate for short arcs and self-contained).
% 'de440' = JPL DE-440 via models.orbit.De440Ephemeris / the Orekit bridge (needs a JVM +
% ~/orekit-bridge; recovers that gap, for long-arc / high-absolute-fidelity truth). Default
% 'mg' keeps the frozen goldens byte-identical and needs no external dependency.
cfg.perturbations.sunMoon.ephemeris = 'mg';

% --- Swarm formation (helix) truth ---------------------------
% One master control: cfg.scenario.nSpaceAssets. When it is > 1 (and an orbit
% propagator is active) the secondary assets are placed on a bounded
% Clohessy-Wiltshire projected-circular (helix) relative orbit around the
% primary chief and propagated with the SAME dynamics as the primary, so the
% swarm truth is physically real (not dead-reckoned). Only the primary
% (asset 1) is EKF-estimated; secondaries are represented-only truth that can
% provide ISL aiding. cfg.measurements.isl.* is the separate feature toggle for
% feeding those links into the EKF.
cfg.formation.mode        = 'helix';   % 'helix' (one ring, legacy default) |
%   'multiRingHelix' (rings of radius k*spacing_m carrying round(2*pi*k) members each, so
%   the neighbour spacing stays ~spacing_m however many satellites are added)
cfg.formation.baseline_m  = 1000.0;    % RING RADIUS [m] (>500 m). NOT the inter-satellite
%   separation: with mode='helix' every member sits on ONE ring of this radius, so the chord
%   between neighbours is 2*rho*sin(pi/nSec) and SHRINKS as members are added -- 1176 m at
%   5 secondaries, 329 m at 19. Use mode='multiRingHelix' to hold the SEPARATION fixed.
cfg.formation.spacing_m   = 1000.0;    % target inter-satellite separation [m], multiRingHelix only
cfg.formation.phase0_rad  = 0.0;       % phase of the first secondary on the projected-circular ring
% --- Cross-track spread: 0 = PLANAR helix (rank-deficient), 1 = fully 3-D. ------------
% The classic projected-circular helix sets z = 2x for EVERY member, so all secondaries
% lie in one plane. MEASURED consequence at spread 0: the matrix of ISL line-of-sight unit
% vectors is RANK-2 (singular values [1.2566 1.1920 0.0000], sv3/sv1 = 2e-08) -- there is a
% direction, radial-dominant [0.73 R, 0.33 A, 0.60 C], in which the ISL rows carry NO
% information while the filter still shrinks the covariance there. That is why along-track
% is covariance-honest (err/sigma 0.89) but radial and cross-track are not (8.35, 7.28).
% s > 0 fans each member's cross-track amplitude over [1-s, 1+s] so the formation spans
% 3-D; every member still flies a valid bounded CW relative orbit.
%
% DEFAULT 1.0 -- and this line MUST exist. It previously did not, and
% ReportRunner.buildFederatedSetup_ carried a local "if missing, use 1.0" fallback while
% SwarmFormation.crossAmp_ read a missing field as 0.0. Absence therefore meant 3-D in the
% federated path and PLANAR in the single-EKF path, and simply WRITING the documented
% default into the config flipped the federated formation and moved its results by 876 m.
% The local override is deleted; this is now the single source of truth. See
% tests/test_formation_rank_deficiency.m.
cfg.formation.crossTrackSpread = 1.0;  % 0 = planar (rank-deficient); 1 = fully 3-D

% --- Per-asset truth persistence (swarm runs only) -------
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

% --- Secondary-asset CLOCK estimation (bias+drift as EKF states) ---------
% 'off'      secondaries are represented-only truth; their clock cancels
%            in the one-way ISL innovation (today's behaviour). Golden-safe.
% 'clocks'   estimate each secondary's [b_tx, bdot_tx] as 2 EKF states,
%            appended LAST. Requires nSpaceAssets>=2 AND isl.enable +
%            isl.code.useInEKF (validated). Secondary POSITIONS stay product.
% 'position' estimate each secondary's full [r,v,b,bdot]; requires
%            towersObserveSecondaries (the near-radial position observable) on top of the
%            'clocks' preconditions. Superset of 'clocks'.
% NOTE: secondary truth clocks only wander when cfg.asset.clock.deterministic=false;
% with the default deterministic clock the estimation target is identically 0.
cfg.multiAsset.estimateMode = 'off';
% --- Convenience preset over the granular estimation toggles (resolved by
% revgnss.ConfigFactory.applyMultiAssetMode, in BOTH masterConfig and finalizeConfig):
%   'fast'  (default) retains the independent-filter compatibility architecture.
%   'joint' is reserved for the centralized fleet estimator with full cross-spacecraft
%           covariance. It remains opt-in until its validation gates pass.
cfg.multiAsset.mode = 'fast';
cfg.multiAsset.federated.refAsset = 1;
cfg.multiAsset.federated.savePerAssetMat = false;
cfg.multiAsset.federated.parallel = false;
cfg.multiAsset.federated.maxWorkers = 0;
% Independent local-EKF fleet execution. This is intentionally separate from
% multiAsset.mode: 'joint' remains the centralized reference and 'fast' remains
% the existing compatibility path unless this explicit runtime is selected.
cfg.multiAsset.distributedEstimator.enable = false;
cfg.multiAsset.distributedEstimator.executionMode = 'epochSynchronous';
cfg.multiAsset.distributedEstimator.stateExchange.enable = false;
cfg.multiAsset.distributedEstimator.stateExchange.maximumAge_s = 0;
cfg.multiAsset.distributedEstimator.stateExchange.deliveryDelay_s = 0;
cfg.multiAsset.distributedEstimator.linkUpdate.enable = false;
cfg.multiAsset.distributedEstimator.linkUpdate.ownerPolicy = 'disabled';
cfg.multiAsset.distributedEstimator.linkUpdate.correlationPolicy = 'disabled';
% Stage 2.0 frozen correlation-contract vocabulary (plan Section 2.0.5): every known
% common-information source must declare exactly one treatment. No treatment is
% implemented yet, so 'rejected' is the only value validateConfig currently accepts;
% the other three words are reserved for Section 2.2 once a proven treatment exists.
cfg.multiAsset.distributedEstimator.linkUpdate.commonSourceTreatment.towerClockProduct = 'rejected';
cfg.multiAsset.distributedEstimator.linkUpdate.commonSourceTreatment.terminalCalibration = 'rejected';
cfg.multiAsset.distributedEstimator.linkUpdate.commonSourceTreatment.transmittedStateProduct = 'rejected';
cfg.multiAsset.distributedEstimator.linkUpdate.commonSourceTreatment.sessionTimingProduct = 'rejected';
cfg.multiAsset.distributedEstimator.linkUpdate.commonSourceTreatment.sharedForceAtmosphericProduct = 'rejected';
% Stage 2.0 frozen clock claim (plan Section 2.0.6): a reciprocal/two-way time-transfer
% row observes a relative clock bias (b_remote-b_owner), never an absolute clock datum
% or a direct drift measurement. 'relativeBiasOnly' is the only physically supported value.
cfg.multiAsset.distributedEstimator.linkUpdate.timeTransferClockClaim = 'relativeBiasOnly';
cfg.multiAsset.distributedEstimator.outOfSequencePolicy = 'reject';
% --- Section 2.1 generic communication interfaces (all inert by default) -------------------
% stateExchange.estimatorEligibleProfile.enable: publishes the ADDITIONAL Section 2.0.4
% estimator-eligible product profile alongside -- never instead of -- the Stage-1 diagnostic
% product/journal. deliveryLedger.enable: constructs the coordinator-owned fleet-wide
% revgnss.DistributedDeliveryLedger (Section 2.1 rule 2). Both default false and are forced
% false on every per-asset leaf by revgnss.IndependentFleetScenarioFactory, exactly like the
% three distributedEstimator keys already forced off there.
cfg.multiAsset.distributedEstimator.stateExchange.estimatorEligibleProfile.enable = false;
cfg.multiAsset.distributedEstimator.deliveryLedger.enable = false;
% The remaining four are single-legal-value word toggles: Section 2.1 ships no implementation
% for any other value, so changing them fails configuration validation
% (IndependentFleetCoordinator:section21ControlsUnavailable) rather than silently degrading.
cfg.multiAsset.distributedEstimator.linkUpdate.remoteProductPropagationPolicy = 'frozenSameEpochOnly';
cfg.multiAsset.distributedEstimator.linkUpdate.roleReversalPolicy = 'disabled';
cfg.multiAsset.distributedEstimator.linkUpdate.calibrationOwnership.policy = 'undeclared';
cfg.multiAsset.distributedEstimator.linkUpdate.updateAdapter.observable = 'none';
% --- Stage 3.1/3.2 correlation network (all inert by default) -----------------------------
% The network tracks pairwise cross-covariance P_ij only; each P_ii stays in its own local EKF
% and is never duplicated here. With the default linkUpdateRouting='conservativeBoundOnly',
% enabling the network moves nothing: it is asserted by test to leave every estimate byte-
% identical. Setting linkUpdateRouting='pairExactWhenBothEndpointsTracked' (Section 3.2) is the
% ONE toggle that changes this -- it applies a synchronized exact update to BOTH endpoint
% filters (not just the owner) for coherentTwoWayCodeRange deliveries where both endpoints are
% tracked with a fresh cross block; every other delivery still routes conservativeBound. The
% fleet-size limit is checked at initialize()/registerFleetMembers, never per delivery, so
% exceeding it fails rather than dropping cross blocks. commonProcessNoiseTreatment stays
% 'rejected' on the live path because the matching diagonal term lives in each leaf's own
% buildQ_ (Section 3.3 scope), not here.
cfg.multiAsset.distributedEstimator.correlationNetwork.policy = 'disabled';
cfg.multiAsset.distributedEstimator.correlationNetwork.maximumFleetSize = 0;
cfg.multiAsset.distributedEstimator.correlationNetwork.crossBlockSpan = 'fullLocalStateSpan';
cfg.multiAsset.distributedEstimator.correlationNetwork.commonProcessNoiseTreatment = 'rejected';
cfg.multiAsset.distributedEstimator.correlationNetwork.commonProcessNoise.sigma_mps2 = 0;
cfg.multiAsset.distributedEstimator.correlationNetwork.commonProcessNoise.frame = 'ECEF';
cfg.multiAsset.distributedEstimator.correlationNetwork.linkUpdateRouting = 'conservativeBoundOnly';
cfg.multiAsset.distributedEstimator.correlationNetwork.audit.enable = false;
cfg.multiAsset.distributedEstimator.correlationNetwork.audit.everyNEpochs = 0;
% --- ISL inside the independent per-asset EKFs -----------------------------
% The compatibility architecture runs independent asset filters and a separate read-only
% relative diagnostic. Keeping ISL out of the asset filters prevents the same observation
% from being reused in both paths.
%
% false (default) keeps the paths disjoint.
% true retains ISL rows in each asset filter; this is diagnostic because the relative
%      layer then reuses those observations and its covariance is not independently valid.
cfg.multiAsset.keepIslInPerAssetEkf = false;
% Kabsch formation-alignment plot in the swarm report. Previously UNDECLARED: ReportRunner
% read cfg.report.kabschAlignmentPlot.enable inside a try/catch that defaulted to false, so the
% figure was silently absent from every swarm report and no config file mentioned it. It is a
% standard formation diagnostic (best-fit rigid rotation between the estimated and true
% constellation), so it is declared here and ON by default.
cfg.report.kabschAlignmentPlot.enable = true;
% Loose a-priori on the secondary clock states (init draw AND stated P0 share these,
% so initial NEES is O(1)). Deliberately << tower's 1000 m / 10 m/s: a GEO atomic
% clock's broadcast a-priori is far better than an unknown ground beacon, yet loose
% enough to stay conservative/under-confident.
cfg.multiAsset.secondaryClock.initSigma_m        = 100.0;
cfg.multiAsset.secondaryClock.initSigmaDrift_mps = 1.0;
% Prior on each secondary's estimated [r,v] (init draw AND stated P0 share
% these, so initial NEES is O(1)). estimateMode='position' promotes each secondary to
% a full [r,v,b,bdot] asset; requires towersObserveSecondaries (the position observable).
cfg.multiAsset.secondaryOrbit.initSigmaPos_m     = 100.0;   % [m] per axis
cfg.multiAsset.secondaryOrbit.initSigmaVel_mps   = 0.1;     % [m/s] per axis

% --- Ground-tower -> secondary observation rows (absolute clock anchor) ---
% When true (and estimateMode='clocks'), each visible ground tower adds a
% pseudorange row observing a secondary's clock bias b_tx at a near-radial LOS
% against the KNOWN (product-corrected) tower clock. This anchors b_tx to the
% ground ABSOLUTELY -- independent of the primary radial -- curing the
% degeneracy (b_tx near-degenerate with the primary radial through the ~horizontal
% ISL LOS). No primary-state columns, so golden-safe when off / nSpaceAssets=1.
% DEFAULT true. In JOINT mode, false means the ground stack feeds ONLY the chief: measured at
% 600 s, all five secondaries froze at an IDENTICAL 1231.08 m error with 4 of 6 baselines exactly
% 0.00 m, so their mutual geometry was the initial condition rather than an estimate -- and every
% relative-navigation number read off that run was self-fulfilling. There is no reason to make
% "the towers see the whole formation" opt-in.
% INERT in the federated path: IndependentFleetScenarioFactory.stripSwarmEstimation gives each
% satellite its OWN single-asset leaf, where it is its own chief and already carries the full
% ground stack. The flag describes tower->SECONDARY rows inside one centralized filter, and a
% federated leaf has no secondaries.
cfg.multiAsset.towersObserveSecondaries          = true;
cfg.multiAsset.towerSecondary.code.sigma_m       = 1.0;   % tower->secondary thermal 1-sigma [m] (flat value AND the 'chiefFloored' floor)
% Secondary code-noise sigma model. 'chiefFloored' = the chief's elevation/C-N0
% code model (models.measurements.MeasurementModelUtils.codeSignalSigma) floored at code.sigma_m, so
% the secondary uplink is elevation-shaped like the chief but R NEVER drops below today's 1.0 m
% (max(x,floor) >= floor => R_new >= R_old, conservative). Byte-identical to 'flat' under the default
% 'constant' code model (codeSignalSigma=codeSigma0_m=0.30 -> floored to 1.0); the elevation shaping
% only activates under a realism-grade code model ('elevation'/'cn0'), inflating low-elevation R.
cfg.multiAsset.towerSecondary.code.sigmaModel    = 'chiefFloored';  % 'flat' | 'chiefFloored'
% Conservative product-correlation factor: the secondary ephemeris product error is
% piecewise-CONSTANT over its broadcast interval, so consecutive rows share it; the
% white-R filter would average it down ~sqrt(N). Inflate the product+tower-clock
% variance by nCorr so the filter cannot fake that averaging (honest-covariance,
% mirrors TwoWayTimeTransfer.conservativeProductCorrelation).
cfg.multiAsset.towerSecondary.productNCorr       = 30;    % effective correlated-sample count
cfg.multiAsset.towerSecondary.towerClkSigma_m    = 0.03;  % tower clock product residual 1-sigma [m] (~100 ps)
cfg.multiAsset.towerSecondary.towerClkDriftSigma_mps = 1e-3;  % tower clock-drift product uncertainty [m/s]
% --- Guard A: divergent uplink atmosphere on ground->secondary rows ---
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
% --- Per-secondary CARRIER phase + float-ambiguity states (single-frequency L1) ---
% Promotes each secondary from code-only toward a full single-asset model: tower->secondary
% carrier rows (cm thermal) with a per-(secondary,tower) float-ambiguity state, mirroring the
% chief's carrier machinery. Needs estimateMode='position' + towersObserveSecondaries (the row
% uses the secondary's r/v geometric column). Default off -> golden byte-identical.
cfg.multiAsset.towerSecondary.carrier.enable        = false;
cfg.multiAsset.towerSecondary.carrier.sigma_m       = 0.005;  % carrier thermal 1-sigma [m] (~5 mm)
cfg.multiAsset.towerSecondary.carrier.initialSigma_m = 100;   % float-ambiguity prior 1-sigma [m]
cfg.multiAsset.towerSecondary.carrier.ambProcNoise_m = 1e-4;  % ambiguity random-walk sigma [m/sqrt(s)]
% --- Per-secondary DOPPLER: tower->secondary range-rate row, symmetric to the
% chief Doppler. H: u_los' on velocity, +1 on secondary clock-drift, and d(rhoDot)/dr on the
% secondary position (the chief omits the position partial as negligible, but the secondary position
% is wall-limited so its range-rate error is position-DRIVEN -- the column is required or the filter
% mis-attributes it to velocity/drift). Emitted only in estimateMode='position'; block-diagonal R
% append (never shrinks an existing entry).
% DEFAULT OFF -- honest GEO finding: at GEO the satellite is ~stationary in ECEF, so the
% range-rate is dominated by the position-driven Sagnac geometry, not velocity. With the secondary
% position radial<->clock-wall-limited, Doppler does NOT make the clock-drift observable (drift error
% ~0.4-0.7 m/s with or without it) and empirically DEGRADES drift/velocity while marginally improving
% position. It is preserved (opt-in) for high-velocity orbits (LEO/MEO) where the range-rate IS
% velocity-dominated and Doppler genuinely helps. See docs/asset_symmetry_generalization.md §16.
cfg.multiAsset.towerSecondary.doppler.enable        = false;  % emit tower->secondary Doppler rows (opt-in; not beneficial at GEO)
cfg.multiAsset.towerSecondary.doppler.sigma_mps     = 0.05;   % Doppler thermal 1-sigma [m/s] (conservative uplink-degraded; >= chief 0.01)
% --- Per-secondary MULTI-ANTENNA + ATTITUDE: give a secondary the chief's
% attitude-estimation stack. multiAntenna carries the chief's antenna array + lever arms on the
% secondary (the inter-antenna carrier baseline is the ONLY thing that makes attitude observable);
% attitude adds per-secondary [euler(3), omega(3)] states. Both DEFAULT OFF -> the state blocks are
% empty (append-only, byte-identical golden + swarm). Attitude is refused unless multiAntenna is on
% (no baseline -> unobservable), mirroring the allocation-gate discipline of secondaryOrbitCount.
% Absolute accuracy is untouched (radial<->clock wall); the deliverable is per-satellite attitude,
% a rotational DOF orthogonal to the wall. See docs/asset_symmetry_generalization.md §17.
cfg.multiAsset.towerSecondary.multiAntenna.enable    = false;  % carry the chief antenna array on secondaries
cfg.multiAsset.towerSecondary.multiAntenna.nAntennas = 4;      % antennas per secondary when enabled (matches the headline 4-antenna cross)
cfg.multiAsset.towerSecondary.attitude.enable        = false;  % estimate per-secondary attitude (needs multiAntenna)
cfg.multiAsset.towerSecondary.attitude.initSigma_euler_rad   = 0.05;   % secondary attitude prior 1-sigma [rad]
cfg.multiAsset.towerSecondary.attitude.initSigma_omega_radps = 1e-4;   % secondary angular-rate prior 1-sigma [rad/s]
% --- Per-secondary TROPOSPHERE (ZWD) states (each secondary estimates its own wet
% delay per tower, like the chief). Gauss-Markov, mirroring the chief per-tower ZWD. Allocated
% only when Guard A injects a divergent truth-side tropo residual; needs estimateMode='position'
% + towersObserveSecondaries. Default off -> golden byte-identical.
% HONEST OBSERVABILITY CAVEAT: at GEO the elevation to each satellite is ~constant, so the wet
% mapping m_w=1/sin(elev) is ~constant and the ZWD is DEGENERATE with the secondary clock -- it
% soaks radial<->clock wall error (100 m+, unphysical for a cm-dm tropo) and DEGRADES the
% absolute rather than improving it. This is the same weak observability the chief's ZWD has;
% it only becomes beneficial once the wall is broken (two-way ranging). Provided for single-asset
% structural symmetry; keep OFF unless the wall is broken. (Ionosphere states are dispersive ->
% require per-secondary dual-frequency.)
cfg.multiAsset.towerSecondary.estimateAtmosphere    = false;
cfg.multiAsset.towerSecondary.zwd.tau_s             = 1800;    % wet-delay Gauss-Markov correlation time [s]
cfg.multiAsset.towerSecondary.zwd.sigma_ss_m        = 0.05;    % steady-state zenith wet 1-sigma [m]
cfg.multiAsset.towerSecondary.zwd.initialSigma_m    = 0.10;    % ZWD prior 1-sigma [m]
% --- Guard B: one-sided truth-side SRP + luni-solar dynamics gap ---
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
cfg.multiAsset.secondaryOrbit.sigma_accel_mps2   = [];    % [] = inherit primary SNC
% --- Synthetic all-pairs range-network diagnostic. Default OFF. -----------
% This postprocessed truth-derived adjustment does not feed the spacecraft estimator and is
% not a sequential radio exchange. It remains available only for explicit diagnostic studies.
cfg.multiAsset.twoWayISL.enable                 = false;
cfg.multiAsset.twoWayISL.links                  = 'all';  % 'all' pairs among estimated assets, or an M-by-2 [i k] list
% --- Crosslink TOPOLOGY: who can actually talk to whom -------------------------------
% A spacecraft has a finite number of steerable crosslink terminals and a line of sight the
% Earth can block, so it contacts its CLOSEST VISIBLE neighbours, not every other member.
% Applied in order: line-of-sight, then range, then terminal count.
cfg.multiAsset.twoWayISL.maxNeighbours      = 5;      % crosslink terminals per spacecraft
cfg.multiAsset.twoWayISL.maxRange_m         = Inf;    % link-budget reach [m]; Inf = no limit
cfg.multiAsset.twoWayISL.requireLineOfSight = true;   % reject pairs whose path crosses Earth
% terminalLayout: 'omni'  keep the historical rule -- the maxNeighbours CLOSEST visible sats.
%                 'cones' model the actual antenna farm: each terminal serves the nearest
%                         satellite inside ITS OWN cone. At these separations range is nearly
%                         free, so the link budget should buy ANGULAR diversity, and one link
%                         per cone spends it that way by construction. Measured on the N=20
%                         multi-ring geometry, 70 deg cones: 'omni' leaves 9 of 54 shape DOF
%                         unobservable with worst-satellite DOP 114; 'cones' with two links per
%                         terminal spans all 54 at DOP 10.8.
cfg.multiAsset.twoWayISL.terminalLayout     = 'omni';
cfg.multiAsset.twoWayISL.coneHalfAngle_deg  = 70;     % antenna half-power reach off boresight
cfg.multiAsset.twoWayISL.linksPerTerminal   = 2;      % distinct partners per terminal, time-shared
% Boresights of the hexagonal bus: 3 rim terminals 120 deg apart in the local horizontal plane
% plus zenith and nadir. rimTilt_deg lifts the rim boresights out of that plane towards zenith.
% --- Which directions may the crosslinks move? ---------------------------------------
% The relative solve corrects the EKF geometry to fit the ISL ranges. 'minNorm' (default,
% historical) treats every direction as equally uncertain -- but it is NOT: ground two-way
% ranging measures the RADIAL axis directly and the per-asset EKF realises ~0.16 m there
% against ~3.4 m transverse, while the crosslinks are mostly transverse chords. Measured
% consequence of ignoring that: the solve improved shape but degraded the BEAMFORMING path
% error from 0.165 m to 0.584 m, because it spent radial displacement to satisfy transverse
% residuals -- trading the one axis a ground beam reads for two it does not.
% 'radialStiff' prices radial corrections at sigmaRadialPrior_m and leaves transverse free.
cfg.multiAsset.twoWayISL.gauge.mode                  = 'minNorm';
cfg.multiAsset.twoWayISL.gauge.sigmaRadialPrior_m    = 0.16;  % ground-link radial accuracy [m]
cfg.multiAsset.twoWayISL.gauge.sigmaTransversePrior_m = Inf;  % Inf = crosslinks own this axis
cfg.multiAsset.twoWayISL.rimTerminalCount   = 3;
cfg.multiAsset.twoWayISL.rimTilt_deg        = 0;
cfg.multiAsset.twoWayISL.useZenithTerminal  = true;
cfg.multiAsset.twoWayISL.useNadirTerminal   = true;
cfg.multiAsset.twoWayISL.sigma_m                = 0.01;   % white two-way ranging thermal 1-sigma [m] (cm-class wideband crosslink)
cfg.multiAsset.twoWayISL.delayCal.sigma_const_m = 0.01;   % per-link turn-around+antenna-PCO cal bias, constant part [m] (33 ps = 1 cm)
cfg.multiAsset.twoWayISL.delayCal.sigma_rw_m    = 0.003;  % per-link cal-bias slow random-walk part [m]
cfg.multiAsset.twoWayISL.delayCal.tau_s         = 3600;   % cal-bias correlation time [s]
cfg.multiAsset.twoWayISL.delayCal.nCorrCap      = 60;     % cap on tau/dt R-inflation (honest gate)
% Per-link delay-bias NETWORK SELF-CALIBRATION (SwarmRelativeSolver stage 8). These two keys
% were read by the solver but never declared here, which made the stage UNREACHABLE from any
% scenario file -- config/internal/deepMergeConfig.m rejects unknown paths, so a JSON that set
% them aborted the run rather than enabling anything. Declaring them is what makes the measured
% 0.480 m -> 0.070 m shape improvement actually selectable.
cfg.multiAsset.twoWayISL.delayCal.estimate.enable     = false;
cfg.multiAsset.twoWayISL.delayCal.estimate.iterations = 2;
% --- Two-way ISL LINK BUDGET: derive sigma_m from the link instead of typing it. ------
% 'fixed' (default) keeps sigma_m exactly as written above -> byte-identical.
% 'linkBudget' makes the PER-PAIR sigma scale with baseline length via free-space path
% loss, anchored so that sigma(refDistance_m) == sigma_m. It converts the headline
% relative-accuracy number from "IF you had a 1 cm device" into "with THIS link at THIS
% range", which is the difference between an assumption and a result.
% antennaModel is the physics that must be stated, not defaulted silently:
%   'fixedAperture' (default) a dish of fixed diameter has G ~ f^2, exactly cancelling
%                   the f^2 path loss -> sigma is FREQUENCY-INDEPENDENT (sigma ~ d only).
%   'fixedGain'     constant dBi (patch/omni) -> the f^2 loss is uncompensated, so sigma
%                   grows with frequency as well as distance.
% Claiming Ka is automatically noisier than L-band is only true for 'fixedGain'.
cfg.multiAsset.twoWayISL.linkBudget.model           = 'fixed';   % 'fixed' | 'linkBudget'
cfg.multiAsset.twoWayISL.linkBudget.antennaModel    = 'fixedAperture';
cfg.multiAsset.twoWayISL.linkBudget.refDistance_m   = 1000;      % sigma_m is defined HERE
cfg.multiAsset.twoWayISL.linkBudget.refFrequency_Hz = 26e9;      % Ka crosslink reference
cfg.multiAsset.twoWayISL.linkBudget.EIRP_dBW        = 15;
cfg.multiAsset.twoWayISL.linkBudget.GT_dBK          = 5;
% Two-way light-time: the first-order Sagnac CANCELS by reciprocity in a round trip
% (Orekit-validated sub-mm); what survives is endpoint relative motion during the trip.
% MICROMETRES at a 1 km formation baseline -- correct but inert here, relevant at 100 km+.
% Reported as rel.lightTimeMax_m so the size is visible rather than assumed.
cfg.multiAsset.twoWayISL.lightTime.enable           = false;

% --- Ground-differenced formation ROTATION solve (read-only post-processor) ------
% The one degree of freedom crosslinks can never supply. Two-way ISL observes |r_i-r_k|
% only, so a rigid rotation of the whole formation leaves every range identically
% unchanged -- the measured range Jacobian along a rotation direction is 1e-16, machine
% zero. SwarmRelativeSolver's min-norm gauge therefore inherits whatever orientation the
% per-asset EKF priors carried, which the GROUND link sets at sigma_theta ~
% sigma_abs/(R*sqrt(N)) ~ 0.028 deg for a federated G5S20R4 run.
% This stage estimates that rotation from tower->satellite code DOUBLE differences
% (between satellites, then between towers). See revgnss.GroundDifferencedRotationSolver
% for why the second difference is not optional: it removes the per-satellite differential
% clock, which is otherwise one free parameter per satellite per epoch.
% Requires multiAsset.twoWayISL.enable (it corrects rel.solvedPos, which only exists then).
cfg.multiAsset.groundDifferencedRotation.enable = false;
% Per-epoch white code sigma [m]. Empty/absent falls back to towerSecondary.code.sigma_m.
cfg.multiAsset.groundDifferencedRotation.codeSigma_m = 1.0;
% Coloured (Gauss-Markov) multipath on the same observable. The correlation time matters
% more than the sigma: at tau = 60 s a 3600 s arc holds 60 independent multipath samples
% against 3600 thermal ones, so 0.30 m of coloured noise is worth 0.30*sqrt(tau/dt) =
% 2.3 m of white noise for averaging purposes. 0 = thermal only.
cfg.multiAsset.groundDifferencedRotation.multipathSigma_m = 0.0;
% DIFFERENTIAL atmosphere between two satellites viewing the SAME tower, per epoch [m].
% Physically this is ~0: the ray paths diverge by 11 arcsec, i.e. 0.5 m at the top of the
% troposphere and 18 m at a 350 km pierce point, both far inside the decorrelation scale,
% so the deterministic model differences away to 0.006-1.6 mm. The simulator does NOT model
% it that way -- each asset owns its own EnvironmentModel seeded per asset, so with
% cfg.atmosphere.realistic = true every satellite draws an INDEPENDENT tropo/iono/
% scintillation realisation worth sqrt(2)*(0.05-0.10 + 0.34-0.62 + 0.34-2.12) m. That is an
% artefact of treating a 2 km formation as N uncorrelated single satellites. This knob
% injects it deliberately so its cost can be measured; 0 = the physically correct case.
cfg.multiAsset.groundDifferencedRotation.differentialAtmosphereSigma_m = 0.0;
cfg.multiAsset.groundDifferencedRotation.differentialAtmosphereTau_s   = 600;

% --- JOINT shape + rotation solve (supersedes the 3-parameter stage above) -------
% The 3-parameter rotation solve has no shape freedom, so arc-correlated deformation
% projects straight onto rotation at a measured 0.30 deg per metre -- and its formal
% sigma is blind to it. revgnss.JointGeometrySolver carries an arc-CONSTANT shape
% correction alongside the rotation, so the shape error has somewhere to go.
% Both parameters are arc-constant on purpose: a PER-EPOCH shape parameter was tried
% first and still leaked (0.10 m shape -> 0.049 deg rotation), because it tells the
% estimator the shape error is independent each epoch and can be averaged away. It
% cannot -- it is the same error every epoch, and that correlation is exactly what
% leaks.
% WHAT SEPARATES SHAPE FROM ROTATION IS THE FORMATION TURNING, not integration time.
% Measured CRLB penalty (rotation sigma with shape co-estimated, vs shape held fixed):
%   1800 s (  7 deg turn) 14.5x     7200 s ( 30 deg)  5.6x    21600 s ( 90 deg) 2.1x
%   3600 s ( 15 deg turn)  9.9x    14400 s ( 60 deg)  2.9x    86400 s (360 deg) 1.0x
% i.e. a 3600 s arc cannot separate them; a quarter orbit gets within 2x; a full orbit
% is clean. Arc length is the mechanism here, not a tuning knob.
cfg.multiAsset.jointGeometry.enable = false;
% ISL shape prior [m], on the shape subspace only (rotation deliberately gets NO prior,
% because inter-satellite ranging supplies exactly zero information about it). Empty ->
% falls back to rel.shapeErrSolved_m. Declare it explicitly rather than inheriting a
% number the ISL layer computed about itself.
cfg.multiAsset.jointGeometry.shapePriorSigma_m = [];

% --- Coherent-beamforming phase budget (report-only diagnostic) -----------------
% Reads the final-epoch relative geometry and clock solution and reports the phasor
% sum of the per-spacecraft signals: what the RELATIVE error would cost a coherent
% transmit beam. Pure post-processing -- it never touches the truth model, the
% measurement model or the filter, so enabling it cannot move a single estimate.
% Emits nothing for single-asset runs, so golden .tex output is unaffected.
cfg.beamforming.enable = true;
% Target the beam is focused on. 'centroidNadir' places it at the sub-satellite point
% of the formation centroid; 'ecef' uses beamforming.target.ecef_m verbatim.
cfg.beamforming.target.mode   = 'centroidNadir';
cfg.beamforming.target.ecef_m = [];
% Carrier frequencies to tabulate [Hz]. Empty means derive a coherent / partial /
% dead triple from the solution itself plus the run's own L1 carrier, which is what
% makes the phasor chain visibly curl across the three figure panels.
cfg.beamforming.frequencies_Hz = [];
% Coherence criterion: sigma_e = lambda / thisValue. lambda/20 is the conventional
% "essentially lossless" line (about 0.1 dB); lambda/10 costs roughly 0.4 dB.
cfg.beamforming.coherenceCriterionLambdaFraction = 20;

% --- Legacy read-only satellite clock-network diagnostic. Default OFF. ---
% Retained for noncanonical federated post-processing compatibility. Canonical execution
% rejects activation; use measurements.isl.twoWay.timeTransfer for epoch observations.
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
% NOT reorder or edit them: these five are the core network (nTowers=5 default).
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
% GYRO -> measures omega_B/I in body axes. Before propagation the EKF uses its nominal
% body-to-ECEF attitude and Earth rate to obtain omega_B/E; truth attitude is never used.
% A three-state gyro bias is appended only when enabled. Gyro propagation alone cannot
% determine initial absolute attitude; enable a valid absolute observation separately.
%
% ACCELEROMETER -> modelled and logged, NOT consumed by the EKF (no config knob: there is nothing
% to switch on). An accelerometer senses SPECIFIC FORCE, i.e. non-gravitational acceleration only
% -- it is blind to gravity. This asset is in free fall, so the true specific force is ~0 (at GEO
% only SRP ~1e-7 m/s^2, below any real accel noise floor): the measurement is pure bias + noise
% and carries zero orbit information. Feeding it to the EKF could only inject noise, which is why
% orbit determination uses DYNAMICS models (two-body + J2 + luni-solar/SRP) instead. It becomes
% informative only under thrust/manoeuvres, via SpaceAsset.specificForce_body_mps2.
%
% finalizeConfig assigns one uniquely seeded IMU to each estimated spacecraft and sets
% estimateGyroBias = imu.enable.
cfg.estimator.imu.enable                        = false;   % master switch (gyro + accel)
cfg.estimator.imu.filter.arw_rad_per_sqrt_s     = 1e-4;    % EKF angle random walk (attitude Q)
cfg.estimator.imu.filter.rrw_rad_per_s_sqrt_s   = 1e-6;    % EKF bias rate random walk (b_g Q)
cfg.estimator.imu.filter.P0_bias_radps          = 1e-5;    % initial 1-sigma on b_g
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
cfg.estimator.diffAtt.ambiguityResolution.enable = false;
cfg.estimator.diffAtt.ambiguityResolution.method = 'constrainedBaselineIntegerSearch';
cfg.estimator.diffAtt.ambiguityResolution.signal = 'L1';
cfg.estimator.diffAtt.ambiguityResolution.searchHalfWidth_cycles = 5;
cfg.estimator.diffAtt.ambiguityResolution.minArcEpochs = 60;
cfg.estimator.diffAtt.ambiguityResolution.rmsThreshold_cycles = 0.10;
cfg.estimator.diffAtt.ambiguityResolution.ratioThreshold = 3.0;
cfg.estimator.diffAtt.ambiguityResolution.useExternalReferenceAsSearchCenter = false;
cfg.estimator.diffAtt.ambiguityResolution.allowExternalReferenceFallback = false;
cfg.estimator.diffAtt.ambiguityResolution.maxFloatDistance_cycles = 0.25;
cfg.estimator.diffAtt.ambiguityResolution.requireAllForGnssOnlyClaim = true;
cfg.estimator.diffAtt.ambiguityResolution.partialFixPolicy = 'mixedFixedFloat';
cfg.estimator.diffAtt.ambiguityResolution.phaseBiasStatus = 'notCalibratedExternalProduct';
cfg.estimator.diffAtt.ambiguityResolution.enforcePhaseBiasStatus = false;
cfg.estimator.diffAtt.ambiguityResolution.requirePhaseBiasCalibrationForFix = true;
cfg.estimator.diffAtt.ambiguityResolution.falseFixClassification = 'screenedNotFormal';
cfg.estimator.diffAtt.ambiguityResolution.maxWideLaneFloatDistance_cycles = 0.5;
cfg.estimator.diffAtt.ambiguityResolution.differentialIonosphereInBaselineAr = ...
    'neglectedShortBaselineV1';
cfg.estimator.starTracker.enable                  = false;
cfg.estimator.starTracker.useInEKF                = true;
cfg.estimator.starTracker.updatePeriod_s          = 1;
cfg.estimator.starTracker.updatePhase_s           = 0;
cfg.estimator.starTracker.whiteAngularSigma_rad   = deg2rad(10/3600);
cfg.estimator.starTracker.outages_s               = zeros(0,2);
cfg.estimator.starTracker.truth.seed              = 1201;
cfg.estimator.starTracker.truth.fixedAlignmentBias_rad = zeros(3,1);
cfg.estimator.starTracker.truth.alignmentDriftRate_radps = zeros(3,1);
cfg.estimator.starTracker.truth.alignmentDriftRandomWalk_rad_per_sqrt_s = 0;
cfg.estimator.starTracker.truth.drawAlignmentFromCalibrationCovariance = false;
cfg.estimator.starTracker.calibration.identifier  = 'star-tracker-body-alignment-v1';
cfg.estimator.starTracker.calibration.q_B_S_wxyz  = [1;0;0;0];
cfg.estimator.starTracker.calibration.covariance_rad2 = zeros(3);
cfg.estimator.starTracker.calibration.validFrom_s = 0;
cfg.estimator.starTracker.calibration.validUntil_s = 1e12;
cfg.estimator.starTracker.calibration.treatment   = 'fixedCalibration';
cfg.estimator.starTracker.calibration.driftProcessNoise_rad2ps = zeros(3);
cfg.carrierSlip.commonModeCompensation.enable = false;
cfg.carrierSlip.commonModeCompensation.minRows = 4;
cfg.carrierSlip.baselineDifferencedMode.enable = false;
cfg.carrierSlip.baselineDifferencedMode.referenceAntenna = 1;
% Absolute multi-antenna attitude initialization.
% Simulated truth is not an allowed estimator input.
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
cfg.estimator.sigma_accel_mps2        = 1e-6;   % baseline residual-acceleration process noise
cfg.estimator.dynamics.mode           = 'constantVelocity';
% EKF propagator luni-solar/SRP perturbations. Default OFF -> the EKF propagates pure J2
% (or two-body). Enable to make the FILTER dynamics include sun+moon third-body (and SRP),
% matching a truth that carries them (cfg.orbit.truth.perturbations) so the along-track
% force-model gap closes. Same constant-Omega ECI + ephemeris as the truth propagator; the
% FD STM picks it up automatically. See +models/+orbit/OrbitPerturbations, EkfDynamicsPredictor.
cfg.estimator.dynamics.perturbations.luniSolar.enable = false;
cfg.estimator.dynamics.perturbations.srp.enable       = false;
cfg.estimator.dynamics.perturbations.srp.Cr           = 1.3;
cfg.estimator.dynamics.perturbations.srp.areaToMass_m2pkg = 0.02;
cfg.estimator.dynamics.perturbations.epochJD_TT       = 2451545.0;   % match cfg.orbit.truth.perturbations
% Dynamic-model residual-acceleration process noise. processNoise.modelMismatch is the
% back-compat field the EKF (ReverseGNSSEKF.buildQ_) reads; it carries the EXTRA process
% noise sized to a truth-vs-EKF propagator gap. It is off when both use the
% same force family and active only for an explicit reduced-dynamics case.
cfg.estimator.processNoise.modelMismatch.enable = false;
cfg.estimator.processNoise.modelMismatch.sigma_mps2 = 1e-6;
% Canonical (honest) name for the SAME quantity. finalizeConfig keeps this a read-only
% mirror of processNoise.modelMismatch (after any auto-scale), so reports can name it by
% its physical meaning instead of the loaded word "mismatch". Do NOT read this in the EKF.
cfg.estimator.processNoise.residualAccelerationUncertainty.enable     = false;
cfg.estimator.processNoise.residualAccelerationUncertainty.sigma_mps2 = 1e-6;
% Optional fleet-common stochastic acceleration in ECEF. Its covariance is
% applied to every spacecraft pair, so the joint EKF retains the induced
% cross-spacecraft process covariance.
cfg.estimator.processNoise.commonAcceleration.enable = false;
cfg.estimator.processNoise.commonAcceleration.sigma_mps2 = 0;
cfg.estimator.processNoise.commonAcceleration.frame = 'ecef';
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
cfg.biases.interFrequency.code.truth.L1_m    = 0;
cfg.biases.interFrequency.code.truth.L2_m    = 0;
cfg.biases.interFrequency.code.model.L1_m    = 0;
cfg.biases.interFrequency.code.model.L2_m    = 0;
cfg.biases.interFrequency.carrier.truth.L1_m = 0;
cfg.biases.interFrequency.carrier.truth.L2_m = 0;
cfg.biases.interFrequency.carrier.model.L1_m = 0;
cfg.biases.interFrequency.carrier.model.L2_m = 0;

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
% DEPRECATED / DOCUMENTARY ONLY. 'off'|'truthOnly'|'model'|'ionosphereFree'. NOTHING in the
% physics reads this: the live gates are cfg.errors.ionosphere.{enable,truth.enable,
% model.enable,model.correction,modelType} (see +models/+errors/ErrorChain) and
% cfg.atmosphere.realistic -> config/internal/realisticAtmosphereConfig. Setting this key
% does NOT switch the ionosphere on or off. It is kept only so old configs that reference it
% still parse; the report derives its ionosphere row from the errors.* gates.
cfg.ionosphere.mode          = 'off';
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
cfg.environment.weather.hydrostaticModelAssumption = 'fixedNominalMapping';

% --- Extended atmosphere model config --------------------------------
% Troposphere: new dry/wet split (backward compat: also keep zenithDelay_m)
cfg.errors.troposphere.modelType                  = 'simpleMapped';
cfg.errors.troposphere.dayOfYear                  = 180;
cfg.errors.troposphere.truth.zenithDryDelay_m     = 2.3;
cfg.errors.troposphere.truth.zenithWetDelay_m     = 0.15;
cfg.errors.troposphere.truth.mappingType           = 'simple';
cfg.errors.troposphere.model.zenithDryDelay_m     = 2.3;
cfg.errors.troposphere.model.zenithWetDelay_m     = 0.15;
cfg.errors.troposphere.model.mappingType           = 'simple';
cfg.errors.troposphere.stochastic.enable          = true;
cfg.errors.troposphere.stochastic.process         = 'gaussMarkov';
cfg.errors.troposphere.stochastic.tau_s           = 3600;
cfg.errors.troposphere.stochastic.sigmaWet_ss_m   = 0.05;
cfg.errors.troposphere.stochastic.sigmaModelResidual_m = 0.02;

% Ionosphere: new verticalDelayL1 (backward compat: keep zenithDelay_m)
cfg.errors.ionosphere.modelType                       = 'simpleMapped';
cfg.errors.ionosphere.topsideFraction                  = 1;
cfg.errors.ionosphere.truth.verticalDelayL1_m          = 5.0;
cfg.errors.ionosphere.truth.diurnal.enable             = false;
cfg.errors.ionosphere.truth.diurnal.vtecDay_TECU       = 30;
cfg.errors.ionosphere.truth.diurnal.vtecNight_TECU     = 6;
cfg.errors.ionosphere.truth.diurnal.peakLocalTime_h    = 14;
cfg.errors.ionosphere.model.verticalDelayL1_m          = 5.0;
cfg.errors.ionosphere.model.correction                 = 'biasFraction';
cfg.errors.ionosphere.model.klobuchar.amplitude_ns     = 20;
cfg.errors.ionosphere.model.klobuchar.period_h         = 24;
cfg.errors.ionosphere.model.klobuchar.dc_ns            = 5;
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
cfg.errors.ionosphere.scintillation.model             = 'conker';
cfg.errors.ionosphere.scintillation.S4zen              = 0;
cfg.errors.ionosphere.scintillation.process           = 'gaussMarkov';
cfg.errors.ionosphere.scintillation.tau_s             = 30;
cfg.errors.ionosphere.scintillation.sigmaCodeL1_m     = 0.3;
cfg.errors.ionosphere.scintillation.frequencyExponent = 1.0;
cfg.errors.ionosphere.scintillation.affectsCodeNoise  = true;
cfg.errors.ionosphere.scintillation.affectsPseudorangeBias = false;
cfg.errors.ionosphere.scintillation.phaseScint.enable       = false;
cfg.errors.ionosphere.scintillation.phaseScint.sigmaPhi_rad = 0.2;
cfg.errors.ionosphere.scintillation.phaseScint.tau_s        = 1.5;

cfg.errors.troposphere.stochastic.modelResidual.enable = false;
cfg.errors.troposphere.stochastic.modelResidual.mode   = 'zero';
cfg.errors.ionosphere.stochastic.modelResidual.enable  = false;
cfg.errors.ionosphere.stochastic.modelResidual.mode    = 'zero';

% Honest off=off structural default.
cfg.errors.troposphere.truth.enable        = false;
cfg.errors.troposphere.truth.zenithDelay_m = 2.3;
cfg.errors.troposphere.model.enable        = false;
cfg.errors.troposphere.model.zenithDelay_m = 2.3;
cfg.errors.troposphere.model.biasFraction  = 1.0;
cfg.errors.troposphere.sigma_m              = 0.0;

cfg.errors.ionosphere.truth.enable         = false;
cfg.errors.ionosphere.truth.zenithDelay_m  = 5.0;
cfg.errors.ionosphere.model.enable         = false;
cfg.errors.ionosphere.model.zenithDelay_m  = 5.0;
cfg.errors.ionosphere.model.biasFraction   = 1.0;
cfg.errors.ionosphere.sigma_m              = 0.0;
% Tower clock product bias sigma
% d/dt of first-order iono delay: dot{I}_L1 = -(40.3/f_L1^2)*dot{TEC}.
% When true, Doppler is excluded from ionoFreeCode mode (no IF Doppler model).
cfg.errors.ionosphere.includeRateTerm      = false;

% Tower clock product parameters (for product epoch caching)
cfg.errors.towerClock.updateInterval_s     = 300;   % product update interval [s]
cfg.errors.towerClock.latency_s            = 0;     % product delivery latency [s]
% Tower clock product validity period
% Shared clock-drift product uncertainty per tower.  Set > 0 if drift
% corrections are active and their error should appear in R.
cfg.errors.towerClock.driftCorrSigma_m_per_s = 0;  % [m/s], default: unmodelled
cfg.clocks.tower.product.mode                   = 'truthHistoryProductNoisy';
cfg.clocks.tower.product.updateInterval_s       = 30;
cfg.clocks.tower.product.latency_s              = 5;
cfg.clocks.tower.product.sigmaBias_m            = 0.01;
cfg.clocks.tower.product.sigmaDrift_mps         = 0.0002;
cfg.clocks.tower.product.covBiasDrift           = 0;
cfg.clocks.tower.product.validity_s             = 120;
cfg.clocks.tower.product.addToR                 = true;
cfg.clocks.tower.product.sharedErrorCorrelation = true; % currently inert -- see the main block's comment

cfg.errors.hardwareDelay.enable            = false;
cfg.errors.hardwareDelay.truth.enable      = false;
cfg.errors.hardwareDelay.truth.default_m   = 0.0;
cfg.errors.hardwareDelay.model.enable      = false;  % honest off=off (was true; default_m=0 made it a no-op)
cfg.errors.hardwareDelay.model.default_m   = 0.0;
% Hardware-delay real-residual channels, default inert. residualStochastic adds a
% truth-only white residual (needs enable + sigma_m>0 + truth.enable) that survives z-h;
% declaring the fields removes the runtime try/catch reliance. NB: enabling hardwareDelay
% with identical truth/model constants and these off contributes exactly zero; validation
% warns (validateMasterConfig:hwDelayNoResidual). A differing truth/model default_m also leaves
% a constant residual (already supported).
cfg.errors.hardwareDelay.sigma_m                   = 0.0;
cfg.errors.hardwareDelay.residualStochastic.enable = false;
% Per-tower CONSTANT uplink hardware group-delay bias (gated, default OFF -> golden-safe). When
% enabled, i_applyPerTowerHwBias() (end of file) draws ONE constant delay per tower from
% [min_ns,max_ns] using perTowerBias.seed on its OWN RandStream (does not disturb the shared
% draw order), writes it truth-only (model=0 -> survives z-h as a real UNcalibrated systematic),
% and adds jitter_ns white uncertainty to R. 10-30 ns represents an uncalibrated ground
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

cfg.estimator.interAntennaCarrierBias.enable            = false;
cfg.estimator.interAntennaCarrierBias.mode              = 'none';
cfg.estimator.interAntennaCarrierBias.referenceReceiver = 1;
cfg.estimator.interAntennaCarrierBias.bias_cycles       = [];
cfg.estimator.interAntennaCarrierBias.bias_m            = [];

cfg.errors.multipath.enable                    = false;
cfg.errors.multipath.truth.enable              = false;
cfg.errors.multipath.model.enable              = false;
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

cfg.effects.towerSurvey.enable       = false;
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
cfg.effects.antennaPCV.enable        = false;
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

cfg.physics.relativity.clock.enable       = false;
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
cfg.measurements.carrierPhase.useInEKF         = false;   % governed by carrierMode
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
% ISL carrier 1-sigma [m]. This is the TOTAL error budget for the row, NOT the thermal
% noise alone -- and that distinction is the difference between a working filter and a
% diverging one.
%
% MEASURED (3600 s, 4 assets, 4 seeds, paired; see docs/plans/ISL_LAMBDA/03 appendix):
%     sigma      posRMS      clkRMS      B_err/sigma
%     (off)      0.581 m     0.01382 m      0.71
%     0.002      13.57 m     0.12593 m      2.14    <- 23x WORSE position, ambiguity inconsistent
%     0.05        1.337 m    0.00311 m      0.63
%     0.20        0.644 m    0.00519 m      0.67    <- clock 2.7x better at ~1.1x position cost
%     1.00        0.587 m    0.01153 m      0.74    <- carrier effectively inert
%
% WHY 2 mm IS WRONG: 2 mm is the THERMAL figure. The ISL carrier row's real error budget
% must also cover the systematics it cannot separate. The row is
% h = rho + b_rx - b_tx + B, so (b_rx + d, B_i - d) is an EXACT null direction of the
% carrier rows (verified: ||H_carrier*v||=0); the ONLY thing anchoring it is the 0.3 m
% code rows. Weighting the carrier at 2 mm therefore lets it dominate a direction it
% cannot actually observe, and the error accumulates with arc length (2x at 900 s, 26x at
% 3600 s). Phase wind-up and antenna PCV are also declared not-implemented, and they live
% in this same budget.
%
% 0.20 m is chosen as the smallest value that keeps the ambiguity covariance HONEST
% (B_err/sigma < 1) and position within ~1.1x of carrier-off while still delivering the
% clock gain. Lower it only with evidence that the systematics above are modelled.
cfg.measurements.isl.carrier.sigma_m = 0.20;
% --- ISL carrier AMBIGUITY STATES (feature/ISL-LAMBDA). Default OFF. ---------------
% One float ambiguity state per (ISL link x signal), appended strictly LAST in the
% state vector so enabling this shifts NO existing index (golden-safe).
%
% DELIBERATELY INDEPENDENT of the ground-to-space ambiguity switches
% (cfg.estimation.ambiguityMode / cfg.estimation.ambiguity.*). ISL and ground must be
% togglable separately, and the sigmas must NOT be shared: the ground
% cfg.estimation.ambiguity.initialSigma_m also drives the TRUTH ambiguity draw
% (CarrierMeasurementBuilder) and the cycle-slip covariance reset, so reusing it for
% ISL would couple three unrelated sinks and let an ISL-only change move the ground
% solution. Enabling requires isl.enable AND isl.carrier.enable as well.
%
% NOTE: the ambiguity here is stored in METRES (B = lambda*N + absorbed bias), matching
% the ground convention, so the carrier Jacobian column is +1 rather than lambda. The
% undifferenced B is NOT an integer (it absorbs the clock bias per arc) -- integer
% resolution needs a differenced parametrisation; see docs/plans/ISL_LAMBDA/03.
% ISL carrier frequency [Hz]. NaN -> fall back to L1 (1575.42 MHz) so the conventional
% behaviour is unchanged. Set explicitly for a real crosslink band (e.g. 26e9 for Ka).
% Only affects the carrier WAVELENGTH (hence the truth ambiguity lambda*N); the geometric
% range is frequency-independent, as vacuum propagation requires.
cfg.measurements.isl.carrier.frequency_Hz           = NaN;
cfg.measurements.isl.carrier.ambiguity.enable       = false;  % master gate for ISL ambiguity STATES
cfg.measurements.isl.carrier.ambiguity.nSignals     = 1;      % ISL carrier signals per link
cfg.measurements.isl.carrier.ambiguity.initialSigma_m = 100;  % P0 / slip-reset inflation [m]
cfg.measurements.isl.carrier.ambiguity.processNoiseSigma_m_per_sqrt_s = 0;  % 0 = constant within an arc
% ISL carrier cycle-slip detection. INDEPENDENT of the ground carrier slip settings
% (cfg.measurements.carrier.slipDetection.*): a crosslink arc and a ground tower arc have
% unrelated slip statistics. A slip starts a NEW arc, so the ambiguity covariance is
% re-inflated to initialSigma_m -- without that reset the filter keeps a tight sigma on a
% stale value (confidently wrong). Only 'resetAndUse' is implemented; the row is kept and
% the inflated covariance absorbs the jump.
cfg.measurements.isl.carrier.slipDetection.enable                = false;
% NaN = AUTO: 5*sqrt(2)*carrier sigma. The detector tests the epoch-to-epoch change of
% the carrier prefit, whose noise is sqrt(2)*sigma, so a FIXED threshold silently desyncs
% whenever sigma changes (measured: 0.10 m at sigma=0.20 m gave 423 false slips in a clean
% 500 s run). Set a number only to override deliberately.
% NOTE the honest consequence at sigma=0.20 m (~1.05 L1 cycles): the auto threshold is
% ~1.41 m ~ 7 cycles, so SINGLE-cycle slips are undetectable -- a slip the size of the
% noise cannot be seen. That is a real limit of the corrected error budget, not a bug.
cfg.measurements.isl.carrier.slipDetection.threshold_m            = NaN;
% Settle epochs after a row becomes EKF-ACTIVE (i.e. after the acquisition warm-up),
% NOT after it is first built. MEASURED: 3 (the ground default) is too short -- the
% ambiguity's ~lambda*N acquisition jump is still in progress, so detection fires on it,
% the reset re-inflates P, and the ambiguity jumps again (a self-sustaining false-slip
% loop). 3 gave 3 false slips per link in a clean 500 s run; 30 and 60 gave zero.
cfg.measurements.isl.carrier.slipDetection.minEpochsBeforeDetect  = 30;
cfg.measurements.isl.carrier.slipDetection.action                 = 'resetAndUse';
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
cfg.measurements.isl.twoWay.protocol = 'coherentTranspondedPnTwoWayCode';
cfg.measurements.isl.twoWay.linkIdentifier = 'isl-two-way-code-link-A1-A2';
cfg.measurements.isl.twoWay.signalIdentifier = 'ISL-PN';
cfg.measurements.isl.twoWay.physicalChainIdentifier = ...
    'isl-two-way-code-chain-A1-A2';
cfg.measurements.isl.twoWay.channelIdentifier = 'PN-1';
cfg.measurements.isl.twoWay.localTimeSystemIdentifier = ...
    'initiatorOnboardClock';
cfg.measurements.isl.twoWay.timestampReferencePointIdentifier = ...
    'initiatorReceiveTerminal';
cfg.measurements.isl.twoWay.forwardCarrierFrequency_Hz = 26e9;
cfg.measurements.isl.twoWay.returnCarrierFrequency_Hz = 26e9;
cfg.measurements.isl.twoWay.carrierFrequencyTurnaroundRatio = 1;
cfg.measurements.isl.twoWay.codeRateTurnaroundRatio = 1;
cfg.measurements.isl.twoWay.codeChipRate_Hz = 10.23e6;
cfg.measurements.isl.twoWay.codeLength_chips = 1023;
cfg.measurements.isl.twoWay.turnaroundProperTime_s = 1e-3;
cfg.measurements.isl.twoWay.initiatorTerminalGroupDelay_s = 0;
cfg.measurements.isl.twoWay.terminalGeometry.mode = 'commonAperture';
cfg.measurements.isl.twoWay.terminalGeometry. ...
    transmitPhaseCentreOffset_body_m = [0.8;0.2;0.3];
cfg.measurements.isl.twoWay.terminalGeometry. ...
    receivePhaseCentreOffset_body_m = [0.8;0.2;0.3];
cfg.measurements.isl.twoWay.terminalGeometry. ...
    calibrationProductIdentifier = 'isl-phase-centre-calibration-v1';
cfg.measurements.isl.twoWay.truth.turnaroundCalibrationError_s = 0;
cfg.measurements.isl.twoWay.truth.terminalCalibrationError_s = 0;
cfg.measurements.isl.twoWay.calibration.turnaroundSigma_s = 0;
cfg.measurements.isl.twoWay.calibration.terminalSigma_s = 0;
cfg.measurements.isl.twoWay.calibration.errorCorrelationModel = ...
    'independentPhysicalChains';
cfg.measurements.isl.twoWay.calibration.productIdentifier = ...
    'isl-two-way-code-calibration-A1-A2';
cfg.measurements.isl.twoWay.calibration.validFromLocalTag_s = -1e12;
cfg.measurements.isl.twoWay.calibration.validUntilLocalTag_s = 1e12;
cfg.measurements.isl.twoWay.calibration.residualBiasState.enable = false;
cfg.measurements.isl.twoWay.calibration.residualBiasState. ...
    processNoiseSigma_m_per_sqrt_s = 0;
cfg.measurements.isl.twoWay.carrierToNoiseDensity_dBHz = NaN;
cfg.measurements.isl.twoWay.schedule.updatePeriod_s = 1;
cfg.measurements.isl.twoWay.schedule.updatePhase_s = 0;
cfg.measurements.isl.twoWay.schedule.start_s = 0;
cfg.measurements.isl.twoWay.schedule.stop_s = 1e12;
cfg.measurements.isl.twoWay.schedule.outages_s = zeros(0,2);
cfg.measurements.isl.twoWay.schedule.commandIdentifier = ...
    'open-loop-scenario-schedule-A1-A2';
cfg.measurements.isl.twoWay.schedule.commandSource = 'scenarioOpenLoop';
% Fleet scenarios declare an open-loop link schedule here. Common RF, code,
% calibration-noise, and update-period settings remain in twoWay; each enabled
% link supplies only its physical identity, endpoints, and schedule phase.
cfg.measurements.isl.twoWay.links = struct( ...
    'enable',false, ...
    'linkIdentifier','isl-two-way-code-link-A1-A2', ...
    'initiatorAssetIndex',1, ...
    'transponderAssetIndex',2, ...
    'physicalChainIdentifier','isl-two-way-code-chain-A1-A2', ...
    'calibrationProductIdentifier','isl-two-way-code-calibration-A1-A2', ...
    'turnaroundCalibrationError_s',0, ...
    'terminalCalibrationError_s',0, ...
    'signalIdentifier','ISL-PN', ...
    'channelIdentifier','PN-1', ...
    'schedule',struct( ...
        'updatePhase_s',0, ...
        'commandIdentifier','open-loop-scenario-schedule-A1-A2'));
cfg.measurements.isl.twoWay.range.enable = false;
cfg.measurements.isl.twoWay.range.useInEKF = false;
cfg.measurements.isl.twoWay.range.sigma_m = 0.25;
% Non-thermal (systematic) two-way ranging 1-sigma [m], added to R in quadrature.
% Read ONLY when linkBudget.model='physicalRF' (gated like plasma.residualSigma_m),
% because that model returns THERMAL jitter alone and so has no error floor: at
% 1 km / 26 GHz it yields 1.9e-05 m with a 99.9 dB link margin, four orders below any
% real two-way ranging budget. On the 'fixed'/'linkBudget' branches sigma_m is already
% the TOTAL budget, so this term is deliberately not applied there.
% NOTE this widens R only. It does NOT add multipath or group-delay drift to the
% simulated observable -- the truth-side tracking error is still drawn from the
% thermal sigma alone. It buys honest (conservative) weighting, not extra physics.
% Default 0 preserves existing runs; a floorless sigma raises
% TwoWayISLMeasurementBuilder:floorlessRangeSigma.
cfg.measurements.isl.twoWay.range.nonThermalSigma_m = 0;
cfg.measurements.isl.twoWay.range.linearization.stencil = 'fivePoint';
cfg.measurements.isl.twoWay.range.linearization.positionStep_m = 0.5;
cfg.measurements.isl.twoWay.range.linearization.velocityStep_mps = 0.05;
cfg.measurements.isl.twoWay.range.linearization.attitudeStep_rad = 5e-4;
cfg.measurements.isl.twoWay.range.linearization.clockBiasStep_m = 10;
cfg.measurements.isl.twoWay.range.linearization.clockDriftStep_mps = 0.01;
cfg.measurements.isl.twoWay.range.linkBudget.model = 'fixed';
cfg.measurements.isl.twoWay.range.linkBudget.antennaModel = 'fixedAperture';
cfg.measurements.isl.twoWay.range.linkBudget.refDistance_m = 1e5;
cfg.measurements.isl.twoWay.range.linkBudget.refFrequency_Hz = 26e9;
cfg.measurements.isl.twoWay.range.linkBudget.EIRP_dBW = 15;
cfg.measurements.isl.twoWay.range.linkBudget.GT_dBK = 5;
cfg.measurements.isl.twoWay.range.linkBudget.validationDistance_m = 1e5;
cfg.measurements.isl.twoWay.range.linkBudget. ...
    forwardReturnTrackingErrorCorrelation = 0;
cfg.measurements.isl.twoWay.range.tracking.minimumCarrierToNoiseDensity_dBHz = 25;
cfg.measurements.isl.twoWay.range.tracking.enforceThreshold = false;

% Physical RF/code-tracking model. It is active only when model='physicalRF'.
cfg.measurements.isl.twoWay.range.linkBudget.forward.powerDefinition = 'eirp';
cfg.measurements.isl.twoWay.range.linkBudget.forward.eirp_dBW = 15;
cfg.measurements.isl.twoWay.range.linkBudget.forward.transmitPower_dBW = 0;
cfg.measurements.isl.twoWay.range.linkBudget.forward.losses_dB = 3;
cfg.measurements.isl.twoWay.range.linkBudget.forward.receiverNoiseDefinition = 'GT';
cfg.measurements.isl.twoWay.range.linkBudget.forward.receiverGT_dB_per_K = 5;
cfg.measurements.isl.twoWay.range.linkBudget.forward.systemNoiseTemperature_K = 500;
cfg.measurements.isl.twoWay.range.linkBudget.forward.bandwidthDefinition = 'chipRate';
cfg.measurements.isl.twoWay.range.linkBudget.forward.effectiveRangingBandwidth_Hz = 10.23e6;
cfg.measurements.isl.twoWay.range.linkBudget.forward.integrationTime_s = 0.1;
cfg.measurements.isl.twoWay.range.linkBudget.forward.modulationTrackingCoefficient = 1;
cfg.measurements.isl.twoWay.range.linkBudget.forward.transmitAntenna.model = 'fixedAperture';
cfg.measurements.isl.twoWay.range.linkBudget.forward.transmitAntenna.gain_dBi = 12;
cfg.measurements.isl.twoWay.range.linkBudget.forward.transmitAntenna.diameter_m = 0.25;
cfg.measurements.isl.twoWay.range.linkBudget.forward.transmitAntenna.efficiency = 0.62;
cfg.measurements.isl.twoWay.range.linkBudget.forward.receiveAntenna.model = 'fixedAperture';
cfg.measurements.isl.twoWay.range.linkBudget.forward.receiveAntenna.gain_dBi = 12;
cfg.measurements.isl.twoWay.range.linkBudget.forward.receiveAntenna.diameter_m = 0.25;
cfg.measurements.isl.twoWay.range.linkBudget.forward.receiveAntenna.efficiency = 0.62;

cfg.measurements.isl.twoWay.range.linkBudget.return = ...
    cfg.measurements.isl.twoWay.range.linkBudget.forward;

% Integrated electron content is declared separately for truth and estimator.
cfg.measurements.isl.twoWay.range.plasma.enable = false;
cfg.measurements.isl.twoWay.range.plasma.truthForwardTEC_electrons_per_m2 = 0;
cfg.measurements.isl.twoWay.range.plasma.truthReturnTEC_electrons_per_m2 = 0;
cfg.measurements.isl.twoWay.range.plasma.estimatorForwardTEC_electrons_per_m2 = 0;
cfg.measurements.isl.twoWay.range.plasma.estimatorReturnTEC_electrons_per_m2 = 0;
cfg.measurements.isl.twoWay.range.plasma.residualSigma_m = 0;
% Processed two-way clock difference. The first-order mode is shared with
% ground-to-space time transfer. This subtree's own .mode vocabulary stays
% firstOrderReciprocal-only forever -- the direct four-timestamp ISL observable below
% (isl.twoWay.fourTimestampPhysical.*) is a separate sibling leaf, selected via
% multiAsset.distributedEstimator.linkUpdate.updateAdapter.observable, not via .timeTransfer.mode.
cfg.measurements.isl.twoWay.timeTransfer.enable = false;
cfg.measurements.isl.twoWay.timeTransfer.useInEKF = false;
cfg.measurements.isl.twoWay.timeTransfer.mode = 'firstOrderReciprocal';
cfg.measurements.isl.twoWay.timeTransfer.sigma_m = 0.03;
cfg.measurements.isl.twoWay.timeTransfer.includeReciprocityResidual = false;
cfg.measurements.isl.twoWay.timeTransfer.reciprocitySigma_m = 0.005;
cfg.measurements.isl.twoWay.timeTransfer.warmup_s = 0;
cfg.measurements.isl.twoWay.timeTransfer.calibration.productIdentifier = ...
    'isl-time-transfer-calibration';
% Persistent time-transfer calibration error sources (Section 2.3.2's distributed adapter
% requires both exactly zero via DistributedClockGaugeContract.requireTimeTransferCalibration
% Provenance; a real persistent value is not modelled as a distributed-adapter state today).
cfg.measurements.isl.twoWay.timeTransfer.calibration.terminalDelayError_s = 0;
cfg.measurements.isl.twoWay.timeTransfer.calibration.terminalSigma_s = 0;

% Section 4.4: direct four-timestamp ISL physical mode. Selected via the distributed-fleet
% sanctioned-observable selector cfg.multiAsset.distributedEstimator.linkUpdate.updateAdapter.
% observable = 'fourTimestampClockDifference' (NOT via isl.twoWay.timeTransfer.mode, which
% stays scoped to revgnss.InterSatelliteTimeTransferBuilder's first-order-only physics -- see
% this file's own comment above). Reuses isl.twoWay.links/.schedule/.terminalGeometry verbatim
% (item 4) -- no new link/schedule/signal/channel/geometry keys are declared here.
cfg.measurements.isl.twoWay.fourTimestampPhysical.sigma_m                 = 0.03;
cfg.measurements.isl.twoWay.fourTimestampPhysical.terminalDelayAllocation = 'receiveEvent';
cfg.measurements.isl.twoWay.fourTimestampPhysical.carrierFrequency_Hz     = 26e9;
cfg.measurements.isl.twoWay.fourTimestampPhysical.counterTag.sigma_s      = zeros(1,4);
cfg.measurements.isl.twoWay.fourTimestampPhysical.counterTag.labels       = {'t1','t2','t3','t4'};

cfg.measurements.isl.twoWay.fourTimestampPhysical.hardware.turnaroundProperTime_s     = 1e-3;
cfg.measurements.isl.twoWay.fourTimestampPhysical.hardware.originTerminalGroupDelay_s = 0;
cfg.measurements.isl.twoWay.fourTimestampPhysical.hardware.anchorTerminalGroupDelay_s = 0;
cfg.measurements.isl.twoWay.fourTimestampPhysical.hardware.physicalChainIdentifier    = 'isl-four-timestamp-chain';
cfg.measurements.isl.twoWay.fourTimestampPhysical.hardware.calibrationProductIdentifier = 'isl-four-timestamp-calibration';
cfg.measurements.isl.twoWay.fourTimestampPhysical.hardware.validFromLocalTag_s        = -1e12;
cfg.measurements.isl.twoWay.fourTimestampPhysical.hardware.validUntilLocalTag_s       = 1e12;

% Combined-review M2: named for which HARDWARE TERMINAL DELAY they perturb (origin vs anchor --
% both are terminal delays, revgnss.FourTimestampPhysicalLinkConfig.hardwareModel's
% originTerminalGroupDelay_s/anchorTerminalGroupDelay_s), NOT "turnaround" -- a genuine
% turnaroundProperTime_s error is inert for this observable (t3/t4 shift together and cancel),
% so the earlier turnaroundCalibrationError_s name described something this leaf does not do.
cfg.measurements.isl.twoWay.fourTimestampPhysical.truth.originTerminalCalibrationError_s = 0;
cfg.measurements.isl.twoWay.fourTimestampPhysical.truth.anchorTerminalCalibrationError_s = 0;
cfg.measurements.isl.twoWay.fourTimestampPhysical.calibration.originTerminalSigma_s      = 0;
cfg.measurements.isl.twoWay.fourTimestampPhysical.calibration.anchorTerminalSigma_s      = 0;

cfg.measurements.isl.twoWay.fourTimestampPhysical.linearizationSteps.positionStep_m    = 0.25;
cfg.measurements.isl.twoWay.fourTimestampPhysical.linearizationSteps.velocityStep_mps   = 0.025;
cfg.measurements.isl.twoWay.fourTimestampPhysical.linearizationSteps.attitudeStep_rad   = 5e-3;
cfg.measurements.isl.twoWay.fourTimestampPhysical.linearizationSteps.clockBiasStep_m     = 5;
cfg.measurements.isl.twoWay.fourTimestampPhysical.linearizationSteps.clockDriftStep_mps  = 0.005;

cfg.measurements.isl.twoWay.doppler.enable = false;
cfg.measurements.isl.twoWay.doppler.useInEKF = false;

% --- One-way distributed ISL code/range-rate (plan Section 2.3 item 3) ---
% Distinct subtree from the legacy measurements.isl.code/doppler.* keys above, which belong
% to the forbidden joint/primary-aided ISLMeasurementBuilder routing (never reachable together
% with these -- IndependentFleetCoordinator refuses both at once). All defaults off/zero: the
% disabled path is byte-identical.
cfg.measurements.isl.oneWay.enable = false;
cfg.measurements.isl.oneWay.signalIdentifier = 'ISL-PN';
cfg.measurements.isl.oneWay.channelIdentifier = 'PN-1';
cfg.measurements.isl.oneWay.carrierFrequency_Hz = 26e9;
cfg.measurements.isl.oneWay.codeChipRate_Hz = 10.23e6;
cfg.measurements.isl.oneWay.warmup_s = 0;
cfg.measurements.isl.oneWay.terminalGeometry.transmitPhaseCentreOffset_body_m = [0.8;0.2;0.3];
cfg.measurements.isl.oneWay.terminalGeometry.receivePhaseCentreOffset_body_m = [0.8;0.2;0.3];
cfg.measurements.isl.oneWay.schedule.updatePeriod_s = 1;
cfg.measurements.isl.oneWay.schedule.updatePhase_s = 0;
cfg.measurements.isl.oneWay.schedule.start_s = 0;
cfg.measurements.isl.oneWay.schedule.stop_s = 1e12;
cfg.measurements.isl.oneWay.code.enable = false;
cfg.measurements.isl.oneWay.code.useInEKF = false;
cfg.measurements.isl.oneWay.code.sigma_m = 0.30;
cfg.measurements.isl.oneWay.code.linkBudget.model = 'fixed';   % 'fixed' | 'physicalRF'
cfg.measurements.isl.oneWay.doppler.enable = false;
cfg.measurements.isl.oneWay.doppler.useInEKF = false;
cfg.measurements.isl.oneWay.doppler.sigma_mps = 0.02;
cfg.measurements.isl.oneWay.doppler.sigmaSource = 'declaredConstant';
cfg.measurements.isl.oneWay.calibration.productIdentifier = 'isl-one-way-calibration';
cfg.measurements.isl.oneWay.calibration.validFromLocalTag_s = -1e12;
cfg.measurements.isl.oneWay.calibration.validUntilLocalTag_s = 1e12;
% Persistent one-way terminal-delay error sources, gated to exactly zero under the sanctioned
% distributed tuple (mirrors Section 2.3.2's timeTransfer.calibration.* precedent): a real
% persistent value is not modelled as a distributed-adapter state today.
cfg.measurements.isl.oneWay.calibration.transmitTerminalDelayError_s = 0;
cfg.measurements.isl.oneWay.calibration.receiveTerminalDelayError_s = 0;
cfg.measurements.isl.oneWay.calibration.terminalSigma_s = 0;

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
% An EKF observable distinct from the legacy diagnostic scaffold above:
% each two-way-capable ground tower exchanges signals with the spacecraft, yielding
% a range-cancelled measurement of the clock difference (b_rx - b_tower). Because the
% geometric range cancels by reciprocity, the row observes the RECEIVER CLOCK directly
% (H has +1 on b_rx and NO position column), breaking the GEO radial<->clock degeneracy
% that limits the one-way uplink. Default OFF -> goldens byte-identical.
cfg.measurements.twoWayTimeTransfer.enable                     = false;
cfg.measurements.twoWayTimeTransfer.useInEKF                   = false;
cfg.measurements.twoWayTimeTransfer.mode                       = 'firstOrderReciprocal';
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

% Section 4.4: direct four-timestamp ground-space physical mode. Selected by setting
% cfg.measurements.twoWayTimeTransfer.mode = 'fourTimestampClockDifference' above; every
% field below is this mode's own parameter set and is inert while mode stays at its
% unchanged default 'firstOrderReciprocal'.
cfg.measurements.twoWayTimeTransfer.fourTimestampPhysical.sigma_m                    = 0.03;
cfg.measurements.twoWayTimeTransfer.fourTimestampPhysical.terminalDelayAllocation    = 'receiveEvent';
cfg.measurements.twoWayTimeTransfer.fourTimestampPhysical.carrierFrequency_Hz        = 2.2e9;
cfg.measurements.twoWayTimeTransfer.fourTimestampPhysical.counterTag.sigma_s         = zeros(1,4);
cfg.measurements.twoWayTimeTransfer.fourTimestampPhysical.counterTag.labels          = {'t1','t2','t3','t4'};

cfg.measurements.twoWayTimeTransfer.fourTimestampPhysical.hardware.turnaroundProperTime_s     = 1e-3;
cfg.measurements.twoWayTimeTransfer.fourTimestampPhysical.hardware.originTerminalGroupDelay_s = 0;   % tower side
cfg.measurements.twoWayTimeTransfer.fourTimestampPhysical.hardware.anchorTerminalGroupDelay_s = 0;   % spacecraft side
cfg.measurements.twoWayTimeTransfer.fourTimestampPhysical.hardware.physicalChainIdentifier    = 'ground-space-four-timestamp-chain';
cfg.measurements.twoWayTimeTransfer.fourTimestampPhysical.hardware.calibrationProductIdentifier = 'ground-space-four-timestamp-calibration';
cfg.measurements.twoWayTimeTransfer.fourTimestampPhysical.hardware.validFromLocalTag_s        = -1e12;
cfg.measurements.twoWayTimeTransfer.fourTimestampPhysical.hardware.validUntilLocalTag_s       = 1e12;

% Truth-only additive error + declared (unowned) calibration uncertainty -- mirrors the
% EXISTING isl.twoWay.truth.*/calibration.* pattern below so item 5's guard can reuse that
% exact, already-reviewed requireZero_ idiom. Named for which HARDWARE TERMINAL DELAY they
% perturb (origin=tower side, anchor=spacecraft side -- combined-review M2), NOT "turnaround":
% a genuine turnaroundProperTime_s error is inert for this observable (t3/t4 shift together).
cfg.measurements.twoWayTimeTransfer.fourTimestampPhysical.truth.originTerminalCalibrationError_s = 0;
cfg.measurements.twoWayTimeTransfer.fourTimestampPhysical.truth.anchorTerminalCalibrationError_s = 0;
cfg.measurements.twoWayTimeTransfer.fourTimestampPhysical.calibration.originTerminalSigma_s      = 0;
cfg.measurements.twoWayTimeTransfer.fourTimestampPhysical.calibration.anchorTerminalSigma_s      = 0;

% Terminal geometry: LONG names (matches revgnss.CommunicationEndpointState/
% revgnss.FourTimestampEstimatorEndpointBridge's already-established convention --
% revgnss.FourTimestampPhysicalLinkConfig translates to the SHORT names the truth-side
% revgnss.ReciprocalEndpointTruthProvider factories require).
cfg.measurements.twoWayTimeTransfer.fourTimestampPhysical.towerTerminalGeometry.transmitPhaseCentreOffset_body_m = zeros(3,1);
cfg.measurements.twoWayTimeTransfer.fourTimestampPhysical.towerTerminalGeometry.receivePhaseCentreOffset_body_m  = zeros(3,1);
cfg.measurements.twoWayTimeTransfer.fourTimestampPhysical.spacecraftTerminalGeometry.transmitPhaseCentreOffset_body_m = [0.8;0.2;0.3];
cfg.measurements.twoWayTimeTransfer.fourTimestampPhysical.spacecraftTerminalGeometry.receivePhaseCentreOffset_body_m  = [0.8;0.2;0.3];

% Atmosphere -- item 3's structural separation: this leaf exists ONLY on the ground-space
% subtree (no ISL counterpart at all, matching plan item 4's vacuum/plasma-only ISL physics).
cfg.measurements.twoWayTimeTransfer.fourTimestampPhysical.applyAtmosphere       = false;
cfg.measurements.twoWayTimeTransfer.fourTimestampPhysical.atmosphereVariance_s2 = [];

% Linearization steps -- default MIRRORS revgnss.FourTimestampObservableLinearization.
% DefaultLinearizationSteps exactly (attitudeStep_rad=5e-3, the empirically re-tuned Section
% 4.3 review value); exposed for override but never silently diverges from the class's own
% tuned default.
cfg.measurements.twoWayTimeTransfer.fourTimestampPhysical.linearizationSteps.positionStep_m    = 0.25;
cfg.measurements.twoWayTimeTransfer.fourTimestampPhysical.linearizationSteps.velocityStep_mps   = 0.025;
cfg.measurements.twoWayTimeTransfer.fourTimestampPhysical.linearizationSteps.attitudeStep_rad   = 5e-3;
cfg.measurements.twoWayTimeTransfer.fourTimestampPhysical.linearizationSteps.clockBiasStep_m     = 5;
cfg.measurements.twoWayTimeTransfer.fourTimestampPhysical.linearizationSteps.clockDriftStep_mps  = 0.005;

%% --- Classical relay TWSTFT session processor (plan Section 4.5) ---
% A -> relay S -> B and B -> relay S -> A, combined by revgnss.GroundRelayTimeTransferSessionBuilder
% into ONE station-pair clock-difference report. Distinct from cfg.measurements.twstft.* (2-space-
% asset diagnostic-only ISL scaffold above -- never a physical relay model) and from
% cfg.measurements.twoWayTimeTransfer.* (ground<->ONE spacecraft, direct round trip, no relay).
% Report-only this stage: NOT routed through IndependentFleetCoordinator/DistributedLinkUpdateAdapter
% (no ground-station-pair dimension exists there, and the plan does not authorize widening that
% frozen vocabulary here). Fully inert unless enable=true AND a complete configuration is present;
% revgnss.GroundRelayPhysicalLinkConfig.requireCompleteSessionConfig hard-refuses an incomplete
% enable=true configuration.
%
% Deliberate, documented deviations from the plan's own item list (combined review M5, recorded
% here per the Section 4.4 completion-record precedent for an unimplemented plan item -- not a
% silent omission): plan item 5's "clock product" common-mode term has no config leaf or covariance
% group this stage (revgnss.GroundRelaySessionCommonCovarianceGroup.AllowedCommonSourceNames covers
% relay/station-terminal/atmosphere only); plan item 6's "frequency difference" observable is not
% reported (revgnss.GroundRelaySessionClockDifferenceObservable reports only clock-difference
% values) -- a frequency difference needs at least two independent sessions to estimate a rate,
% which this single-session builder does not accumulate. Both are left for a future stage.
cfg.measurements.groundRelayTimeTransfer.enable    = false;
cfg.measurements.groundRelayTimeTransfer.useInEKF  = false;   % hard-refused if true this stage

cfg.measurements.groundRelayTimeTransfer.session.stationATowerIndex    = [];   % required int
cfg.measurements.groundRelayTimeTransfer.session.stationBTowerIndex    = [];   % required int, != stationA
cfg.measurements.groundRelayTimeTransfer.session.relaySpaceAssetIndex  = [];   % required int
cfg.measurements.groundRelayTimeTransfer.session.sessionIdentifier     = 'ground-relay-session';
cfg.measurements.groundRelayTimeTransfer.session.protocolIdentifier    = 'classicalRelayTwstft';
cfg.measurements.groundRelayTimeTransfer.session.signalIdentifier      = 'TWSTFT-RELAY';
cfg.measurements.groundRelayTimeTransfer.session.channelIdentifier     = 'relay-1';
cfg.measurements.groundRelayTimeTransfer.session.carrierFrequency_Hz   = 14.0e9;   % Ku-band, representative

% Both epochs are the FINAL-RECEPTION coordinate time of their own pass (the same t4_s convention
% revgnss.ReciprocalTimestampEventModel.solveRelayTransit/solveDirectRoundTrip already use
% everywhere else in this plan) -- required, distinct, finite. A moving relay produces genuinely
% different forward/return geometry between these two epochs; that asymmetry is exactly what the
% exact closed-form combiner in revgnss.GroundRelaySessionObservableBuilder is designed to close.
cfg.measurements.groundRelayTimeTransfer.schedule.forwardReceptionEpoch_s = [];   % required
cfg.measurements.groundRelayTimeTransfer.schedule.returnReceptionEpoch_s  = [];   % required, != forward

cfg.measurements.groundRelayTimeTransfer.terminalGeometry.stationA.transmitPhaseCentreOffset_body_m = zeros(3,1);
cfg.measurements.groundRelayTimeTransfer.terminalGeometry.stationA.receivePhaseCentreOffset_body_m  = zeros(3,1);
cfg.measurements.groundRelayTimeTransfer.terminalGeometry.stationB.transmitPhaseCentreOffset_body_m = zeros(3,1);
cfg.measurements.groundRelayTimeTransfer.terminalGeometry.stationB.receivePhaseCentreOffset_body_m  = zeros(3,1);
cfg.measurements.groundRelayTimeTransfer.terminalGeometry.relay.transmitPhaseCentreOffset_body_m    = zeros(3,1);
cfg.measurements.groundRelayTimeTransfer.terminalGeometry.relay.receivePhaseCentreOffset_body_m     = zeros(3,1);

% Hardware / delay chain. Named for exactly what each perturbs -- a genuine TX-vs-RX split per
% station (a single combined per-station delay is PROVABLY INERT to the reported clock difference:
% only each station's own TX-minus-RX asymmetry survives the two-pass combination).
% relayGroupDelayNominal_s reuses the existing, already-tested
% revgnss.ReciprocalLinkHardwareModel.turnaroundProperTime_s mechanism verbatim (applied to
% whichever endpoint occupies the "turnaround" role -- for relayTransit, that is literally the
% relay); relayGroupDelayAsymmetry_s is an optional forward/return split for testing relay-hardware
% non-reciprocity (default 0 = perfectly reciprocal relay). relayGroupDelayAsymmetry_s moves only
% revgnss.GroundRelaySessionClockDifferenceObservable.classicalReciprocityValue_s (the realizable
% classical relay-TWSTFT combination) -- it is structurally, provably INERT on
% clockDifferenceValue_s (the truth-geometry-assisted reference value), by design: see
% revgnss.GroundRelaySessionObservableBuilder.combine's own header for the exact distinction
% between the two reported values (combined review B1).
cfg.measurements.groundRelayTimeTransfer.hardware.stationATransmitDelay_s        = 0;
cfg.measurements.groundRelayTimeTransfer.hardware.stationAReceiveDelay_s         = 0;
cfg.measurements.groundRelayTimeTransfer.hardware.stationBTransmitDelay_s        = 0;
cfg.measurements.groundRelayTimeTransfer.hardware.stationBReceiveDelay_s         = 0;
cfg.measurements.groundRelayTimeTransfer.hardware.relayGroupDelayNominal_s       = 1e-3;
cfg.measurements.groundRelayTimeTransfer.hardware.relayGroupDelayAsymmetry_s     = 0;
% Frequency translation / relay oscillator state: NOT numerically modelled this stage
% (solveRelayTransit is coordinate-time-only, frequency-agnostic). Must equal 1.0 --
% requireCompleteSessionConfig hard-refuses any other value (mirrors Section 4.4's
% applyAtmosphere hard-refuse precedent) rather than silently accepting a configured translation
% the physics never applies.
cfg.measurements.groundRelayTimeTransfer.hardware.relayFrequencyTranslationRatio = 1.0;
cfg.measurements.groundRelayTimeTransfer.hardware.relayOscillatorStateIdentifier = 'ground-relay-oscillator';
cfg.measurements.groundRelayTimeTransfer.hardware.physicalChainIdentifier        = 'ground-relay-twstft-chain';
cfg.measurements.groundRelayTimeTransfer.hardware.calibrationProductIdentifier   = 'ground-relay-twstft-calibration';
cfg.measurements.groundRelayTimeTransfer.hardware.validFromLocalTag_s            = -1e12;
cfg.measurements.groundRelayTimeTransfer.hardware.validUntilLocalTag_s           = 1e12;

% Truth-only additive error, folded into the nominal hardware values above when parameterSource=
% 'physicalTruth' (matches revgnss.FourTimestampPhysicalLinkConfig.hardwareModel's established
% truth/calibration split exactly). A nonzero stationATransmitDelayError_s WITHOUT an equal and
% opposite stationAReceiveDelayError_s produces a real, nonzero, testable bias in the reported
% clock difference; equal TX/RX errors are a documented, tested NO-OP by design.
cfg.measurements.groundRelayTimeTransfer.truth.stationATransmitDelayError_s = 0;
cfg.measurements.groundRelayTimeTransfer.truth.stationAReceiveDelayError_s  = 0;
cfg.measurements.groundRelayTimeTransfer.truth.stationBTransmitDelayError_s = 0;
cfg.measurements.groundRelayTimeTransfer.truth.stationBReceiveDelayError_s  = 0;
cfg.measurements.groundRelayTimeTransfer.truth.relayGroupDelayError_s       = 0;

% Session-common covariance: seconds^2-domain ONLY (revgnss.GroundRelaySessionCommonCovarianceGroup
% -- NOT revgnss.CommonSourceCovarianceGroup, which is metres^2-domain always).  temporalModel is
% restricted to the EXISTING revgnss.DistributedLinkCalibrationState.AllowedTemporalCovarianceModels
% vocabulary (no new word invented); 'whitePerRow' is constructor-forbidden. A large-but-finite
% correlationTime_s (not Inf) models "persistent for any session timescale this subsystem covers".
cfg.measurements.groundRelayTimeTransfer.sessionCommonCovariance.relayGroupDelaySigma_s          = 0;
cfg.measurements.groundRelayTimeTransfer.sessionCommonCovariance.relayGroupDelayTemporalModel     = 'firstOrderGaussMarkov';
cfg.measurements.groundRelayTimeTransfer.sessionCommonCovariance.relayGroupDelayCorrelationTime_s = 1e9;
cfg.measurements.groundRelayTimeTransfer.sessionCommonCovariance.stationATerminalSigma_s          = 0;
cfg.measurements.groundRelayTimeTransfer.sessionCommonCovariance.stationATerminalCorrelationTime_s = 1e9;
cfg.measurements.groundRelayTimeTransfer.sessionCommonCovariance.stationBTerminalSigma_s          = 0;
cfg.measurements.groundRelayTimeTransfer.sessionCommonCovariance.stationBTerminalCorrelationTime_s = 1e9;
cfg.measurements.groundRelayTimeTransfer.sessionCommonCovariance.atmosphereSigma_s                = 0;
cfg.measurements.groundRelayTimeTransfer.sessionCommonCovariance.atmosphereTemporalModel          = 'firstOrderGaussMarkov';
cfg.measurements.groundRelayTimeTransfer.sessionCommonCovariance.atmosphereCorrelationTime_s      = 1800;

% Counter/tag noise (mirrors twoWayTimeTransfer.fourTimestampPhysical.counterTag.* exactly).
cfg.measurements.groundRelayTimeTransfer.counterTag.sigma_s = zeros(1,4);
cfg.measurements.groundRelayTimeTransfer.counterTag.labels  = {'t1','t2','t3','t4'};

% Atmosphere: applies ONLY to the two ground-space legs of each one-way pass (station<->relay),
% NEVER to the relay's own turnaround -- enforced STRUCTURALLY, not by a runtime check: the
% relayTransit exchange-record schema has exactly two propagation legs and no leg object for the
% turnaround gap at all. perLegResidualVariance_s2 is an INDEPENDENT per-leg noise contribution to
% each pass's own record covariance (mapping-function/turbulence-scale residual); it is separate
% from, and additive to, sessionCommonCovariance.atmosphereSigma_s above (a SHARED/correlated
% systematic sampled once and reused for both appearances of each station-relay path).
cfg.measurements.groundRelayTimeTransfer.atmosphere.applyTropo               = false;
cfg.measurements.groundRelayTimeTransfer.atmosphere.applyIono                = false;
cfg.measurements.groundRelayTimeTransfer.atmosphere.f_L1ReferenceHz          = 1.57542e9;
cfg.measurements.groundRelayTimeTransfer.atmosphere.perLegResidualVariance_s2 = [0, 0];  % [stationA-relay, relay-stationB]

cfg.measurements.groundRelayTimeTransfer.solverOptions.lightTimeTolerance_s = 1e-13;
cfg.measurements.groundRelayTimeTransfer.solverOptions.maximumIterations    = 50;

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
%                NOTE: L2 carrier EKF is NOT supported.
%
% carrierCombinationMode (authoritative):
%   'raw'             individual L1 phase (L2 not supported in EKF)
%   'ionosphereFree'  NOT supported — no IF carrier EKF
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
% clock.hardwareDelay.estimatePerTower — hardware delay EKF state placeholder (not implemented)
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

% --- Data backend (canonical) --------------------------------
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
% clock-truth seeds) and band-checks the pooled NIS/NEES for the resolved scenario.
cfg.report.monteCarlo.enable      = false;
cfg.report.monteCarlo.nSeeds      = 12;
cfg.report.monteCarlo.duration_s  = 900;      % short override; the shipped run is much longer
cfg.report.monteCarlo.confidence  = 0.99;
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
