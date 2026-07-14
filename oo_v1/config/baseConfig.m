function cfg = baseConfig()
%BASECONFIG  Structural + default base config (relocated from ConfigFactory.defaultConfig).
%   Phase 1.3: moves the config base out of the 2512-line +revgnss/ConfigFactory
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
% Attitude process-noise budget (WP3). The angular-acceleration 1-sigma driving the
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
% WP4: clock h-coefficient source. 'legacy' = original (optimistic) numbers, kept for
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
% Stage 15: differential carrier attitude mode.
% 'off' (safe default) | 'calibratedDifferentialAmbiguity' | 'validationKnownAmbiguity'
cfg.estimator.attitudeCarrierMode     = 'off';
cfg.estimator.diffAtt.calibWin_s      = 60;   % calibration window length (s)
% Stage 16: absolute multi-antenna attitude initialization.
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
% Stage 76: central signal list (names, Hz, boolean masks).
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
% WP6: second/third-order ionosphere (Branch A bounded residual). The dual-frequency
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
% WP-F: hardware-delay real-residual channels, default inert. residualStochastic adds a
% truth-only white residual (needs enable + sigma_m>0 + truth.enable) that survives z-h;
% declaring the fields removes the runtime try/catch reliance. NB: enabling hardwareDelay
% with matched truth==model default_m AND these off contributes EXACTLY 0 -> validateMasterConfig
% warns (validateMasterConfig:hwDelayNoResidual). A differing truth/model default_m also leaves
% a constant residual (already supported).
cfg.errors.hardwareDelay.sigma_m                   = 0.0;
cfg.errors.hardwareDelay.residualStochastic.enable = false;

cfg.errors.multipath.truth.enable              = false;
cfg.errors.multipath.truth.amplitude_m         = 0.3;
cfg.errors.multipath.truth.frequency_radps     = 0.01;
cfg.errors.multipath.truth.stochastic_sigma_m  = 0.1;
cfg.errors.multipath.sigma_m                   = 0.0;
% WP5: multipath as a coloured (first-order Gauss-Markov) process. Multipath is the
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
% cfg.effects groups new deterministic effects added in Stages 2–4.
% Each effect has truth/model toggle so mismatches appear as innovation bias.
% If truth=true and model=true with same params, the effect mostly cancels.
% R contains stochastic uncertainty only — deterministic bias belongs here.

cfg.effects.towerSurvey.truth.enable = false;
cfg.effects.towerSurvey.model.enable = false;
cfg.effects.towerSurvey.sigmaENU_m   = [0.01; 0.01; 0.03];
cfg.effects.towerSurvey.seed         = 3100;

cfg.effects.antennaPCO.truth.enable          = false;
cfg.effects.antennaPCO.model.enable          = false;
cfg.effects.antennaPCO.receiverOffset_body_m = [0; 0; 0];
cfg.effects.antennaPCO.towerOffset_enu_m     = [0; 0; 0];
% WP-E: optional gated truth-only PCO calibration residual -- a receiver antenna phase-centre
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

cfg.measurements.carrierPhase.enable           = true;
cfg.measurements.carrierPhase.useInEKF         = false;   % governed by carrierMode in v4+
cfg.measurements.carrierPhase.frequency_Hz     = sigL1Default_.frequency_Hz;
cfg.measurements.carrierPhase.lambda_m         = sigL1Default_.wavelength_m;
cfg.measurements.carrierPhase.sigma_cycles     = 0.01;
cfg.measurements.carrierPhase.initialAmbiguityMode = 'randomInteger';
cfg.measurements.carrierPhase.seed             = 9001;
cfg.measurements.carrierPhase.cycleSlip.enable = true;

% --- One-way inter-spacecraft link scaffold (Stage 21) --------
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

% --- TWSTFT code time-transfer diagnostic scaffold (Stage 24) ---
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

% --- Tower<->spacecraft two-way time transfer (WP-A) -------------
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

% Slip detection (Stage 14)
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

% --- Ionosphere mapping model (Stage 7A) ------------------------
% Governs the mapping function used to project vertical ionosphere
% delays to slant delays in EnvironmentModel.getIonoDelay().
% 'simpleSecant' — 1/sin(el) (backward-compatible, Stage 6 and earlier)
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

% --- Clock architecture mode (Stage 8) ---------------------------
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
% WP4: h-coefficient source for clock templates (canonical selector). 'legacy' keeps
% every current number bit-identical; 'jowTable2p1' re-anchors OCXO/CESIUM to the
% project primary source (JOW Table 2.1) — less optimistic, more conservative.
cfg.clock.templateSource                 = 'legacy';
cfg.clock.gauge.mode                     = 'externalTowerCorrections';
cfg.clock.gauge.referenceTowerIndex      = 1;      % used by fixReferenceTower
cfg.clock.gauge.sigmaBias_m              = 1e-6;   % pseudo-meas sigma for bias gauge [m]
cfg.clock.gauge.sigmaDrift_mps           = 1e-9;   % pseudo-meas sigma for drift gauge [m/s]
cfg.clock.hardwareDelay.estimatePerTower = false;

% --- Transmitter code hardware-delay states (Stage 11) ----------
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

% --- Receiver code / carrier hardware-bias architecture (Stage 12) ---
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

% --- Clock observability Gramian (Stage 10) ---------------------
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
% WP-B: Monte-Carlo NEES/NIS filter-consistency evidence appended to the run (.out log).
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
