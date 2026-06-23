classdef ConfigFactory
    % ConfigFactory  Builds simulation configuration structs.
    %
    % Default scenario: GEO-1 at lat 0, lon 23 deg, alt 35 786 km with five
    % ground towers from the original SimulationConfig.m layout.
    %
    % -----------------------------------------------------------------------
    % CONFIGURATION HIERARCHY (Stage 7A)
    %
    %   defaultConfig()          MATCHED-ERROR BASELINE (not "all errors off").
    %                            Troposphere and ionosphere are BOTH enabled with
    %                            equal truth and model values so they cancel.
    %                            Innovations remain small. Use as the standard
    %                            starting point for any scenario.
    %
    %   cleanConfig()            Genuinely error-free code-only baseline.
    %                            All atmosphere, multipath, and antenna errors
    %                            disabled. Use for convergence validation.
    %
    %   matchedErrorBaselineConfig()  Alias for defaultConfig(). Explicit name
    %                            for the matched-error intent.
    %
    % -----------------------------------------------------------------------
    % SUPPORTED OBSERVABLES (Stage 7A, updated Stage 79)
    %   Code pseudorange (single-frequency or IF L1/L2 combination)
    %   Simplified Doppler
    %   Raw L1/L2 float carrier EKF; raw dual-frequency baseline attitude AR
    %     (Stage 76 adds L2 EKF attitude rows and joint L1+L2 integer-pair search;
    %      carrier-IF integer fixing is explicitly unsupported; LAMBDA/MLAMBDA unsupported)
    %   ZWD per-tower EKF state
    %   Tower-clock product structs (explicit or truth-history)
    %   PCV: none / toy (elevation only) / table (elevation-only, no azimuth)
    %   Ionosphere mapping: simpleSecant (1/sin) or thinShell
    %   Thin-shell mapping: M(e)=1/sqrt(1-(Re*cos(e)/(Re+hI))^2); NOT Klobuchar
    %
    % NOT SUPPORTED (updated Stage 79)
    %   Carrier-IF integer fixing | LAMBDA/MLAMBDA | formal ILS false-fix-risk control
    %   Azimuth-dependent PCV | ANTEX parser | IONEX | SP3/CLK | RINEX
    %   VMF3 / GPT3 / ERA5 | Klobuchar ionosphere model
    %   PPP-grade or mm-level accuracy claims
    %   Multi-space-asset estimation (guarded; nSpaceAssets > 1 errors)
    % -----------------------------------------------------------------------
    %
    % Clock templates available (see clockTemplates sub-struct):
    %   TCXO        Temperature-compensated crystal oscillator (moderate)
    %   OCXO        Oven-controlled crystal oscillator (good)
    %   Rubidium    Rubidium frequency standard (medium-long term)
    %   AtomicLike  Cesium / H-maser class (excellent)
    %   Custom      User-filled coefficients
    %
    % Factory configs:
    %   defaultConfig()              GEO-1, matched-error baseline (trop+iono both on)
    %   idealConfig()                Code noise = 0, all errors off
    %   cleanConfig()                All errors off, code-only
    %   matchedErrorBaselineConfig() Alias for defaultConfig()
    %   noLeverArmConfig()           Zero lever arm (attitude unobservable)
    %   positionClockOnlyConfig()    Attitude/omega frozen, zero lever arm
    %   multiAntennaAttitudeConfig() 4-antenna cross; attitude observable
    %   clockNoiseConfig()           Stochastic clocks + truthHistoryProductNoisy mode
    %   atmosphereConfig()           Trop + iono enabled
    %   uncorrectedTowerClocksConfig()  Stochastic, no correction
    %   clockDiversityConfig()       Each tower uses a different clock type
    %   towerClockProductConfig()    Explicit per-tower product struct mode
    %   carrierFloatConfig()         Raw L1 float carrier EKF
    %   dualFrequencyIFConfig()      L1+L2 IF code combination
    %
    % Finalizer (called automatically by ScenarioFactory.build):
    %   cfg = revgnss.ConfigFactory.finalizeConfig(cfg)
    %     Trims towers to cfg.scenario.nTowers, sets lever arms from nReceivers,
    %     recreates per-tower and receiver clocks from clockType/clockFactors.
    %
    % Clock factory:
    %   cfgClock = revgnss.ConfigFactory.makeClockConfig(templateName, seed, factors, globalScaling)

    methods (Static)

        % ==================================================================
        %  MAIN DEFAULT CONFIGURATION
        % ==================================================================
        function cfg = defaultConfig()
            % defaultConfig  GEO-1 matched-error baseline.
            %
            % Troposphere and ionosphere are BOTH enabled (truth=model), so they cancel
            % in innovations.  This is NOT "all errors off" — it is a matched-error
            % baseline.  Use cleanConfig() for a genuinely error-free code-only run.
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

            % --- Scenario topology (simple count fields) ------------------
            cfg.scenario.nTowers    = 5;
            cfg.scenario.nReceivers = 1;
            cfg.scenario.nSpaceAssets = 1;

            % --- GEO asset (stationary in ECEF) ---------------------------
            geoLat_rad = 0.0;
            geoLon_rad = 23.0 * pi / 180;
            geoAlt_m   = 35786000.0;
            r_geo      = revgnss.GeometryUtils.geodetic2ecef(geoLat_rad, geoLon_rad, geoAlt_m);

            cfg.asset.name                    = 'GEO-1';
            cfg.asset.mass_kg                 = 70;
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

            % Asset receiver clock fields (simple config fields)
            cfg.asset.clockName    = 'SpaceReceiverClock';
            cfg.asset.clockType    = 'OCXO';
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

            % --- Five ground towers (from SimulationConfig.m) -------------
            towerDefs = { ...
                'Tenerife',        28.3,      -16.5,    0.0; ...
                'Stockholm',       59.3,       18.1,    0.0; ...
                'Hartebeesthoek', -25.9,       27.7,    0.0; ...
                'Bengaluru',       13.0,       77.6,    0.0; ...
                'Libreville',       0.0355,    -9.4496,  0.0 };

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
            cfg.estimator.sigma_accel_mps2        = 0.01;
            cfg.estimator.dynamics.mode           = 'constantVelocity';
            cfg.estimator.processNoise.modelMismatch.enable = false;
            cfg.estimator.processNoise.modelMismatch.sigma_mps2 = 1e-6;
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

            cfg.errors.troposphere.truth.enable        = true;
            cfg.errors.troposphere.truth.zenithDelay_m = 2.3;
            cfg.errors.troposphere.model.enable        = true;
            cfg.errors.troposphere.model.zenithDelay_m = 2.3;
            cfg.errors.troposphere.model.biasFraction  = 1.0;
            cfg.errors.troposphere.sigma_m             = 0.0;

            cfg.errors.ionosphere.truth.enable         = true;
            cfg.errors.ionosphere.truth.zenithDelay_m  = 5.0;
            cfg.errors.ionosphere.model.enable         = true;
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
            cfg.errors.hardwareDelay.model.enable      = true;
            cfg.errors.hardwareDelay.model.default_m   = 0.0;

            cfg.errors.multipath.truth.enable              = false;
            cfg.errors.multipath.truth.amplitude_m         = 0.3;
            cfg.errors.multipath.truth.frequency_radps     = 0.01;
            cfg.errors.multipath.truth.stochastic_sigma_m  = 0.1;
            cfg.errors.multipath.sigma_m                   = 0.0;

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
            cfg.measurements.isl.transmitterAssetIndex = 2;
            cfg.measurements.isl.receiverAssetIndex = 1;
            cfg.measurements.isl.code.enable = false;
            cfg.measurements.isl.code.useInEKF = false;
            cfg.measurements.isl.code.sigma_m = 0.5;
            cfg.measurements.isl.doppler.enable = false;
            cfg.measurements.isl.doppler.useInEKF = false;
            cfg.measurements.isl.doppler.sigma_mps = 0.02;
            cfg.measurements.isl.carrier.enable = false;
            cfg.measurements.isl.carrier.useInEKF = false;
            cfg.measurements.isl.carrier.sigma_m = 0.002;
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
            cfg.report.baseOutputDir       = fullfile(fileparts(mfilename('fullpath')), '..', 'output');
            cfg.report.dateFolderPrefix    = 'Report-';
            cfg.report.overwrite           = true;
            cfg.report.writePdf            = true;
            cfg.report.writeMat            = true;
            cfg.report.appendRawPlots         = false;
            cfg.report.layout                 = 'default'; % 'default' | 'clockStyle' | 'clockExact'
            cfg.report.includeRawDiagnostics  = false;

            % --- Validation policy ----------------------------------------
            % 'error'             — unsupported features throw (default; safe)
            % 'disableWithWarning'— unsupported features disabled with a warning
            cfg.validation.unsupportedFeaturePolicy = 'error';
            cfg.validation.warnings         = {};
            cfg.validation.disabledFeatures = {};
            cfg.validation.mappedFeatures   = {};
        end

        % ==================================================================
        %  DERIVED CONFIGURATIONS
        % ==================================================================

        function cfg = idealConfig()
            % idealConfig  Zero code noise, all errors off, deterministic clocks.
            cfg = revgnss.ConfigFactory.defaultConfig();
            cfg.errors.codeNoise.sigma_m = 0;
        end

        function cfg = noLeverArmConfig()
            % noLeverArmConfig  Zero lever arm, single receiver — attitude unobservable.
            cfg = revgnss.ConfigFactory.idealConfig();
            cfg.scenario.nReceivers                          = 1;
            cfg.asset.receiverLeverArm_body_m                = [0; 0; 0];
            cfg.asset.receiverLeverArms_body_m               = [0; 0; 0];
            cfg.estimator.estimateAttitude                   = false;
            cfg.estimator.estimateAngularRate                = false;
            cfg.estimator.estimateAttitudeFromPseudorange    = false;
            cfg.estimator.estimateAngularRateFromPseudorange = false;
        end

        function cfg = positionClockOnlyConfig()
            % positionClockOnlyConfig  Position + clock only; attitude frozen.
            cfg = revgnss.ConfigFactory.idealConfig();
            cfg.scenario.nReceivers                          = 1;
            cfg.asset.receiverLeverArm_body_m                = [0; 0; 0];
            cfg.asset.receiverLeverArms_body_m               = [0; 0; 0];
            cfg.estimator.estimateAttitude                   = false;
            cfg.estimator.estimateAngularRate                = false;
            cfg.estimator.estimateAttitudeFromPseudorange    = false;
            cfg.estimator.estimateAngularRateFromPseudorange = false;
            cfg.estimator.P0_euler_rad                       = 1e-12;
            cfg.estimator.P0_omega_radps                     = 1e-12;
            cfg.estimator.sigma_angAccel_radps2              = 1e-15;
        end

        function cfg = multiAntennaAttitudeConfig()
            % multiAntennaAttitudeConfig  Four-antenna cross pattern for attitude estimation.
            %
            % Only preset that enables estimateAttitudeFromPseudorange.
            % 5 towers × 4 antennas = 20 measurements/epoch.
            % P0_euler_rad is 1-sigma; ScenarioFactory squares it.

            cfg = revgnss.ConfigFactory.defaultConfig();

            cfg.scenario.nReceivers = 4;

            % Explicit ±1 m cross pattern; finalizeConfig will NOT overwrite
            % because N == nReceivers.
            cfg.asset.receiverLeverArms_body_m = [ ...
                 1.0  -1.0   0.0   0.0; ...
                 0.0   0.0   1.0  -1.0; ...
                 0.2   0.2  -0.2  -0.2 ];
            cfg.asset.receiverLeverArm_body_m = cfg.asset.receiverLeverArms_body_m(:,1);

            cfg.estimator.estimateAttitude                   = true;
            cfg.estimator.estimateAngularRate                = false;
            cfg.estimator.estimateAttitudeFromPseudorange    = true;
            cfg.estimator.estimateAngularRateFromPseudorange = false;

            cfg.estimator.P0_euler_rad              = deg2rad(5);
            cfg.estimator.P0_omega_radps            = 1e-12;
            cfg.estimator.sigma_angAccel_radps2     = 1e-10;
            cfg.estimator.initialError.euler_deg    = [1; -1; 0.5];
            cfg.estimator.initialError.omega_radps  = [0; 0; 0];

            cfg.errors.codeNoise.sigma_m = 0.03;
        end

        function cfg = clockNoiseConfig()
            % clockNoiseConfig  Stochastic receiver + tower clocks with noisyCorrection.
            %
            % CHANGED: v3→v4 — Issue 5
            % SIMULATION NOTE: noisyCorrection is a truth-based simulated external
            % correction product.  It is NOT a model of what a real receiver
            % produces; it adds zero-mean Gaussian noise to the true tower clock.
            % Use for Monte Carlo bias/sigma studies only.
            % predictedProduct is the more realistic product model.
            cfg = revgnss.ConfigFactory.defaultConfig();

            % Enable stochastic noise for receiver clock
            cfg.asset.clock.deterministic = false;
            cfg.asset.clock.bias_s        = 1e-6;
            cfg.asset.clock.fracFreq      = 1e-11;

            % Enable stochastic noise for tower clocks
            for k = 1:numel(cfg.towers)
                cfg.towers(k).clock.deterministic = false;
                cfg.towers(k).clock.bias_s        = (k - 1) * 1e-8;
                cfg.towers(k).clock.fracFreq      = k * 1e-12;
            end
            cfg.estimator.towerClockMode = 'noisyCorrection';
        end

        function cfg = atmosphereConfig()
            % atmosphereConfig  Troposphere + ionosphere errors enabled.
            cfg = revgnss.ConfigFactory.defaultConfig();
            cfg.errors.troposphere.truth.enable  = true;
            cfg.errors.troposphere.model.enable  = true;
            cfg.errors.troposphere.sigma_m       = 0.1;
            cfg.errors.ionosphere.truth.enable   = true;
            cfg.errors.ionosphere.model.enable   = true;
            cfg.errors.ionosphere.sigma_m        = 0.3;
        end

        function cfg = uncorrectedTowerClocksConfig()
            % uncorrectedTowerClocksConfig  Stochastic tower clocks, no correction.
            cfg = revgnss.ConfigFactory.clockNoiseConfig();
            cfg.estimator.towerClockMode = 'none';
        end

        function cfg = clockDiversityConfig()
            % clockDiversityConfig  Each tower uses a different clock type.
            %
            % Overrides only clockType/clockFactors per tower, then recreates clock.
            %   1 Tenerife        OCXO       noiseFactor=1.0
            %   2 Stockholm       TCXO       noiseFactor=1.2
            %   3 Hartebeesthoek  Rubidium   noiseFactor=0.8
            %   4 Bengaluru       OCXO       h0Factor=3.0
            %   5 Libreville      AtomicLike noiseFactor=1.0
            %
            % Tower clocks are stochastic; mode = perfectCorrection.
            % Default (defaultConfig) run remains fully deterministic.

            cfg = revgnss.ConfigFactory.defaultConfig();
            gs  = cfg.clockScaling;

            % Per-tower overrides: only clockType and select clockFactors fields.
            % roleNoiseFactor is inherited from defaultConfig (= clockScaling.towerNoiseFactor).
            % {clockType, noiseFactor, h0Factor}
            towerOverrides = { ...
                'OCXO',       1.0, 1.0; ...    % 1 Tenerife
                'TCXO',       1.2, 1.0; ...    % 2 Stockholm
                'Rubidium',   0.8, 1.0; ...    % 3 Hartebeesthoek
                'OCXO',       1.0, 3.0; ...    % 4 Bengaluru  (h0Factor=3)
                'AtomicLike', 1.0, 1.0 };      % 5 Libreville

            nT = numel(cfg.towers);
            for k = 1:min(nT, size(towerOverrides,1))
                tType = towerOverrides{k,1};
                nF    = towerOverrides{k,2};
                h0F   = towerOverrides{k,3};

                % Override clockType and select clockFactors fields
                cfg.towers(k).clockType                = tType;
                cfg.towers(k).clockFactors.noiseFactor = nF;
                cfg.towers(k).clockFactors.h0Factor    = h0F;

                % Recreate clock with updated settings; roleNoiseFactor preserved
                cfgClk = revgnss.ConfigFactory.makeClockConfig( ...
                    tType, 200+k, cfg.towers(k).clockFactors, gs);
                cfgClk.name          = sprintf('%s_%s', cfg.towers(k).clockName, cfg.towers(k).name);
                cfgClk.deterministic = false;
                cfgClk.bias_s        = (k-1) * 5e-9;
                cfgClk.fracFreq      = k * 1e-12;

                cfg.towers(k).clock = cfgClk;
            end

            % Receiver clock also stochastic (reuse clock built in defaultConfig)
            cfg.asset.clock.deterministic = false;
            cfg.asset.clock.bias_s        = 0.0;
            cfg.asset.clock.fracFreq      = 0.0;

            % Keep perfectCorrection: assume clock products are broadcast
            cfg.estimator.towerClockMode = 'perfectCorrection';
            cfg.errors.codeNoise.sigma_m  = 1.0;
        end

        function cfg = realisticPseudorangeConfig()
            % realisticPseudorangeConfig  Sagnac + Shapiro corrections truth+model enabled.
            cfg = revgnss.ConfigFactory.defaultConfig();
            cfg.physics.sagnac.truth.enable             = true;
            cfg.physics.sagnac.model.enable             = true;
            cfg.physics.relativity.shapiro.truth.enable = true;
            cfg.physics.relativity.shapiro.model.enable = true;
        end

        function cfg = cleanConfig()
            % cleanConfig  All errors off: code-only baseline for convergence validation.
            %
            % Named scenario preset: no atmosphere, no antenna errors, no multipath,
            % no tower clock mismatch, simple code-only measurements.
            cfg = revgnss.ConfigFactory.defaultConfig();
            cfg.errors.troposphere.truth.enable    = false;
            cfg.errors.troposphere.model.enable    = false;
            cfg.errors.ionosphere.truth.enable     = false;
            cfg.errors.ionosphere.model.enable     = false;
            cfg.errors.hardwareDelay.truth.enable  = false;
            cfg.errors.hardwareDelay.model.enable  = false;
            cfg.errors.multipath.truth.enable      = false;
            cfg.effects.antennaPCV.truth.enable    = false;
            cfg.effects.antennaPCV.model.enable    = false;
            cfg.effects.antennaPCO.truth.enable    = false;
            cfg.effects.antennaPCO.model.enable    = false;
            cfg.errors.codeNoise.sigma_m           = 0.3;
            cfg.measurements.observableMode        = 'code';
            cfg.measurements.doppler.enable        = false;
            cfg.measurements.doppler.useInEKF      = false;
            cfg.measurements.carrierPhase.enable   = false;
            cfg.measurements.carrierMode           = 'off';
        end

        function cfg = matchedErrorBaselineConfig()
            % matchedErrorBaselineConfig  Truth+model include same deterministic corrections.
            %
            % Innovations remain small because model matches truth. This is the
            % matched-error baseline (NOT "all errors off" — same corrections both sides).
            cfg = revgnss.ConfigFactory.defaultConfig();
        end

        function cfg = dualFrequencyIFConfig()
            % dualFrequencyIFConfig  L1+L2 ionosphere-free code combination.
            %
            % Enables IF pseudorange combination.  First-order ionosphere cancels.
            % Requires both L1 and L2 active.
            cfg = revgnss.ConfigFactory.defaultConfig();
            cfg.signals.names                    = {'L1','L2'};
            cfg.signals.enabledMask              = [true,true];
            cfg.measurements.codeMode            = 'ionosphereFree';
            cfg.measurements.observableMode      = 'code+doppler';
            cfg.errors.ionosphere.truth.enable   = true;
            cfg.errors.ionosphere.model.enable   = true;
        end

        function cfg = carrierFloatConfig()
            % carrierFloatConfig  Carrier phase EKF with float ambiguity states (single receiver).
            %
            % ambiguityMode='floatPerTowerSignal': one float ambiguity per tower/signal.
            % Use carrierFloatMultiReceiverConfig() for multiple receivers.
            cfg = revgnss.ConfigFactory.defaultConfig();
            cfg.measurements.carrierMode             = 'ekfFloat';
            cfg.measurements.carrierCombinationMode  = 'raw';
            cfg.measurements.observableMode          = 'code+doppler+carrier';
            cfg.estimation.ambiguityMode             = 'floatPerTowerSignal';
            cfg.estimation.ambiguity.initialSigma_m  = 100;
            cfg.measurements.doppler.enable          = true;
            cfg.measurements.doppler.useInEKF        = true;
            cfg.physics.doppler.truth.enable         = true;
            cfg.physics.doppler.model.enable         = true;
        end

        function cfg = carrierFloatMultiReceiverConfig()
            % carrierFloatMultiReceiverConfig  Carrier EKF with tower/receiver/signal ambiguities.
            %
            % ambiguityMode='floatPerTowerReceiverSignal': one float ambiguity per
            % tower × receiver phase centre × signal.  Valid for nReceivers > 1.
            cfg = revgnss.ConfigFactory.defaultConfig();
            cfg.scenario.nReceivers                  = 3;
            cfg.measurements.carrierMode             = 'ekfFloat';
            cfg.measurements.carrierCombinationMode  = 'raw';
            cfg.measurements.observableMode          = 'code+doppler+carrier';
            cfg.estimation.ambiguityMode             = 'floatPerTowerReceiverSignal';
            cfg.estimation.ambiguity.initialSigma_m  = 100;
            cfg.measurements.doppler.enable          = true;
            cfg.measurements.doppler.useInEKF        = true;
            cfg.physics.doppler.truth.enable         = true;
            cfg.physics.doppler.model.enable         = true;
        end

        function cfg = stochasticErrorsConfig()
            % stochasticErrorsConfig  Stochastic clocks + atmosphere errors enabled.
            cfg = revgnss.ConfigFactory.defaultConfig();
            cfg.asset.clock.deterministic          = false;
            cfg.asset.clock.bias_s                 = 1e-6;
            cfg.asset.clock.fracFreq               = 1e-11;
            for k = 1:numel(cfg.towers)
                cfg.towers(k).clock.deterministic  = false;
                cfg.towers(k).clock.bias_s         = (k-1) * 1e-8;
                cfg.towers(k).clock.fracFreq       = k * 1e-12;
            end
            cfg.errors.troposphere.truth.enable    = true;
            cfg.errors.troposphere.model.enable    = true;
            cfg.errors.ionosphere.truth.enable     = true;
            cfg.errors.ionosphere.model.enable     = true;
            % Stage 7A: use truthHistoryProductNoisy (history-based + noise) consistently.
            % Do NOT set estimator.towerClockMode directly; let finalizeConfig map it.
            cfg.towerClock.correctionMode = 'truthHistoryProductNoisy';
        end

        function cfg = towerClockProductConfig()
            % towerClockProductConfig  Explicit per-tower product struct mode.
            %
            % Uses cfg.towerClock.products(ti) structs with bias/drift/epoch/sigma.
            % All towers initialised with zero bias/drift at epoch 0.
            % Add uncertainty to R via correctionMode='productNoisy'.
            %
            % Fields per tower product struct:
            %   bias_m       — clock bias at epoch_s [m]
            %   drift_mps    — clock drift at epoch_s [m/s]
            %   epoch_s      — reference epoch for linear prediction [s]
            %   sigmaBias_m  — 1-sigma bias uncertainty [m]
            %   sigmaDrift_mps — 1-sigma range-rate clock prediction uncertainty [m/s];
            %                    fractional-frequency equivalent is sigmaDrift_mps / c
            %   covBiasDrift — bias-drift covariance [m^2/s]
            %   validity_s   — max |dt| before policy triggers [s]
            cfg = revgnss.ConfigFactory.defaultConfig();
            cfg.towerClock.correctionMode        = 'product';
            cfg.towerClock.productValidityPolicy = 'warn';
            for k = 1:numel(cfg.towers)
                cfg.towerClock.products(k).bias_m        = 0.0;
                cfg.towerClock.products(k).drift_mps     = 0.0;
                cfg.towerClock.products(k).epoch_s       = 0.0;
                cfg.towerClock.products(k).sigmaBias_m   = 0.1;
                cfg.towerClock.products(k).sigmaDrift_mps = 1e-4;
                cfg.towerClock.products(k).covBiasDrift  = 0.0;
                cfg.towerClock.products(k).validity_s    = 600;
            end
        end

        % ==================================================================
        %  CLOCK FACTORY METHODS
        % ==================================================================

        function cfgClock = makeClockConfig(templateName, baseSeed, factors, globalScaling)
            % makeClockConfig  Build a clock config from a template + scaling factors.
            %
            % Inputs:
            %   templateName   'TCXO'|'OCXO'|'Rubidium'|'AtomicLike'|'Custom'
            %   baseSeed       integer seed for reproducibility
            %   factors        struct with optional per-coefficient scale factors:
            %                    biasFactor, freqFactor, noiseFactor, roleNoiseFactor,
            %                    h2Factor, h1Factor, h0Factor, hMinus1Factor, hMinus2Factor
            %   globalScaling  cfg.clockScaling struct (globalNoiseFactor, etc.)
            %
            % h-coefficients are PSD levels (one-sided, fractional frequency).
            % Scale factors are DIRECT multipliers on h (not on amplitude):
            %   noiseScale = globalNoiseFactor * noiseFactor * roleNoiseFactor
            %   h0_out = template.h0 * h0Factor * noiseScale
            % Example: h0Factor=3 → h0 is 3×, Allan deviation is sqrt(3)×.

            if nargin < 3 || isempty(factors);       factors       = struct(); end
            if nargin < 4 || isempty(globalScaling); globalScaling = struct(); end

            tmpl = revgnss.ConfigFactory.getClockTemplate_(templateName);

            % Extract global scale factors
            gNoise = getf_(globalScaling, 'globalNoiseFactor', 1.0);
            gBias  = getf_(globalScaling, 'globalBiasFactor',  1.0);
            gFreq  = getf_(globalScaling, 'globalFreqFactor',  1.0);

            % Combined noise scale (direct PSD multiplier, not amplitude-squared)
            noiseF     = getf_(factors, 'noiseFactor',     1.0);
            roleF      = getf_(factors, 'roleNoiseFactor', 1.0);
            noiseScale = gNoise * noiseF * roleF;

            % Per-coefficient direct PSD factors
            h2F   = getf_(factors,'h2Factor',      1.0) * noiseScale;
            h1F   = getf_(factors,'h1Factor',      1.0) * noiseScale;
            h0F   = getf_(factors,'h0Factor',      1.0) * noiseScale;
            hm1F  = getf_(factors,'hMinus1Factor', 1.0) * noiseScale;
            hm2F  = getf_(factors,'hMinus2Factor', 1.0) * noiseScale;

            biasF = getf_(factors,'biasFactor', 1.0) * gBias;
            freqF = getf_(factors,'freqFactor', 1.0) * gFreq;

            cfgClock.name         = templateName;
            cfgClock.clockType    = templateName;
            cfgClock.seed         = baseSeed;
            cfgClock.deterministic = false;
            cfgClock.bias_s        = tmpl.bias_s   * biasF;
            cfgClock.fracFreq      = tmpl.fracFreq * freqF;
            cfgClock.driftRate_fracPerSec = getf_(tmpl,'driftRate_fracPerSec',0);

            cfgClock.noiseCoeffs.h2       = tmpl.h2       * h2F;
            cfgClock.noiseCoeffs.h1       = tmpl.h1       * h1F;
            cfgClock.noiseCoeffs.h0       = tmpl.h0       * h0F;
            cfgClock.noiseCoeffs.hMinus1  = tmpl.hMinus1  * hm1F;
            cfgClock.noiseCoeffs.hMinus2  = tmpl.hMinus2  * hm2F;
        end

        function cfg = finalizeConfig(cfg)
            % finalizeConfig  Resolve nTowers/nReceivers, lever arms, recreate clocks.
            %
            % Called automatically by ScenarioFactory.build and
            % ReverseGNSSSimulation.initialize.  Also call manually after
            % overriding cfg.scenario.*, cfg.towers(k).clockType/Factors, or
            % cfg.asset.clockType/Factors.
            %
            % Rules enforced:
            %   nTowers > numel(cfg.towers)  → error  (no implicit tower creation)
            %   nTowers < numel(cfg.towers)  → trim cfg.towers to first nTowers
            %   nReceivers == 1              → lever arms = [0;0;0]  (single antenna)
            %   nReceivers  > 1              → lever arms from ±1 m cross pattern
            %   nReceivers  > 4              → error  (only 4 columns defined)
            %   nReceivers <= 1              → force estimateAttitudeFromPseudorange=false
            %
            % Clock recreation is idempotent: noiseCoeffs are re-derived from
            % clockType + clockFactors; name/deterministic/bias_s/fracFreq preserved.

            % ---- Initialize validation tracking ---------------------------
            if ~isfield(cfg,'validation')
                cfg.validation = struct();
            end
            if ~isfield(cfg.validation,'unsupportedFeaturePolicy')
                cfg.validation.unsupportedFeaturePolicy = 'error';
            end
            if ~isfield(cfg.validation,'warnings');         cfg.validation.warnings         = {}; end
            if ~isfield(cfg.validation,'disabledFeatures'); cfg.validation.disabledFeatures = {}; end
            if ~isfield(cfg.validation,'mappedFeatures');   cfg.validation.mappedFeatures   = {}; end
            policy = cfg.validation.unsupportedFeaturePolicy;

            % ---- User convenience field mappings -------------------------
            % cfg.clock.receiver.deterministic → cfg.asset.clock.deterministic
            if isfield(cfg,'clock') && isfield(cfg.clock,'receiver') && ...
                    isfield(cfg.clock.receiver,'deterministic')
                cfg.asset.clock.deterministic = cfg.clock.receiver.deterministic;
            end
            % Stage 77: canonical clock product mode → legacy alias sync
            % cfg.clocks.tower.product.mode is canonical; derive errors.towerClockCorrection.mode
            % before the legacy mapping below picks it up.
            if isfield(cfg,'clocks') && isfield(cfg.clocks,'tower') && ...
                    isfield(cfg.clocks.tower,'product') && isfield(cfg.clocks.tower.product,'mode')
                if ~isfield(cfg,'errors'); cfg.errors = struct(); end
                if ~isfield(cfg.errors,'towerClockCorrection')
                    cfg.errors.towerClockCorrection = struct();
                end
                if isfield(cfg.errors.towerClockCorrection,'mode') && ...
                        ~strcmp(cfg.errors.towerClockCorrection.mode, cfg.clocks.tower.product.mode)
                    cfg.validation.warnings{end+1} = ...
                        'cfg.errors.towerClockCorrection.mode is derived from cfg.clocks.tower.product.mode; canonical product mode wins.';
                end
                cfg.errors.towerClockCorrection.mode = cfg.clocks.tower.product.mode;
            end
            % cfg.errors.towerClockCorrection.mode → cfg.estimator.towerClockMode (legacy)
            if isfield(cfg,'errors') && isfield(cfg.errors,'towerClockCorrection') && ...
                    isfield(cfg.errors.towerClockCorrection,'mode')
                cfg.estimator.towerClockMode = cfg.errors.towerClockCorrection.mode;
            end
            % cfg.towerClock.correctionMode → cfg.estimator.towerClockMode (new mapping)
            % Stage 7A: truth-history modes and explicit-struct modes are now distinct.
            %
            % Supported correctionMode values:
            %   'none'                  — no tower clock correction
            %   'perfectTruth'          — use exact truth clock (validation only)
            %   'truthHistoryProduct'   — history-based linear prediction (no explicit struct)
            %   'truthHistoryProductNoisy' — history-based + noise added to R
            %   'product'               — explicit cfg.towerClock.products struct REQUIRED
            %   'productNoisy'          — explicit struct REQUIRED + uncertainty added to R
            %
            % Internal estimator.towerClockMode values:
            %   'none' | 'perfectCorrection' | 'noisyCorrection' |
            %   'truthProduct' | 'truthHistoryProductNoisy' |
            %   'product' | 'productNoisy'
            if isfield(cfg,'towerClock') && isfield(cfg.towerClock,'correctionMode')
                newMode = cfg.towerClock.correctionMode;
                switch newMode
                    case 'perfectTruth'
                        % Default value: only set if not already overridden by user.
                        if ~isfield(cfg,'estimator') || ~isfield(cfg.estimator,'towerClockMode')
                            cfg.estimator.towerClockMode = 'perfectCorrection';
                        end
                    case 'truthHistoryProduct'
                        % History-based product. Internal mode 'truthProduct' does NOT
                        % require cfg.towerClock.products — it uses tower truth history.
                        cfg.estimator.towerClockMode = 'truthProduct';
                    case 'truthHistoryProductNoisy'
                        % Stage 71: history-based product with deterministic per-product
                        % noise and prediction-uncertainty sigma added to R.
                        cfg.estimator.towerClockMode = 'truthHistoryProductNoisy';
                    case 'product'
                        % Explicit per-tower product struct required. NO fallback.
                        cfg.estimator.towerClockMode = 'product';
                    case 'productNoisy'
                        % Explicit product struct required + R inflation. NO fallback.
                        cfg.estimator.towerClockMode = 'productNoisy';
                    case 'none'
                        cfg.estimator.towerClockMode = 'none';
                    otherwise
                        cfg.estimator.towerClockMode = newMode;
                end
            end

            % Stage 77: canonical slip threshold sync
            % cfg.carrierSlip.threshold_m is canonical; derive slipDetection.threshold_m.
            % CarrierTrackManager reads cfg.measurements.carrier.slipDetection.threshold_m at runtime.
            if isfield(cfg,'carrierSlip') && isfield(cfg.carrierSlip,'threshold_m')
                if isfield(cfg,'measurements') && isfield(cfg.measurements,'carrier') && ...
                        isfield(cfg.measurements.carrier,'slipDetection')
                    if isfield(cfg.measurements.carrier.slipDetection,'threshold_m') && ...
                            cfg.measurements.carrier.slipDetection.threshold_m ~= cfg.carrierSlip.threshold_m
                        cfg.validation.warnings{end+1} = ...
                            'cfg.measurements.carrier.slipDetection.threshold_m is derived from cfg.carrierSlip.threshold_m; canonical slip threshold wins.';
                    end
                    if isfield(cfg.carrierSlip,'enable') && isfield(cfg.measurements.carrier.slipDetection,'enable') && ...
                            logical(cfg.measurements.carrier.slipDetection.enable) ~= logical(cfg.carrierSlip.enable)
                        cfg.validation.warnings{end+1} = ...
                            'cfg.measurements.carrier.slipDetection.enable is derived from cfg.carrierSlip.enable; canonical carrierSlip enable wins.';
                    end
                    if isfield(cfg.carrierSlip,'enable')
                        cfg.measurements.carrier.slipDetection.enable = logical(cfg.carrierSlip.enable);
                    end
                    cfg.measurements.carrier.slipDetection.threshold_m = ...
                        cfg.carrierSlip.threshold_m;
                end
            end

            % ---- Clock mode / gauge validation (Stage 8) ------------------
            % Map cfg.clock.mode to estimator.estimateTowerClocks and validate gauge.
            if isfield(cfg,'clock') && isfield(cfg.clock,'mode')
                clockMode = cfg.clock.mode;
                gaugeMode = 'externalTowerCorrections';
                if isfield(cfg.clock,'gauge') && isfield(cfg.clock.gauge,'mode')
                    gaugeMode = cfg.clock.gauge.mode;
                end
                switch clockMode
                    case 'spacecraftReceiverClockOnly'
                        cfg.estimator.estimateTowerClocks = false;
                    case 'includeTowerClocksInEKF'
                        cfg.estimator.estimateTowerClocks = true;
                        switch gaugeMode
                            case {'externalTowerCorrections', ...
                                  'fixReferenceTower', ...
                                  'meanGroundClockGauge'}
                                % valid: datum ambiguity is constrained
                            case 'free'
                                error('ConfigFactory:clockGaugeRequired', ...
                                    ['Joint spacecraft/tower clock estimation is unobservable ' ...
                                     'with clock.gauge.mode=''free''. ' ...
                                     'Use fixReferenceTower, meanGroundClockGauge, ' ...
                                     'or externalTowerCorrections.']);
                            otherwise
                                error('ConfigFactory:invalidGaugeMode', ...
                                    ['cfg.clock.gauge.mode must be ''fixReferenceTower'', ' ...
                                     '''meanGroundClockGauge'', or ''externalTowerCorrections''; ' ...
                                     'got ''%s''.'], gaugeMode);
                        end
                    otherwise
                        error('ConfigFactory:invalidClockMode', ...
                            ['cfg.clock.mode must be ''spacecraftReceiverClockOnly'' or ' ...
                             '''includeTowerClocksInEKF''; got ''%s''.'], clockMode);
                end
            end

            % ---- Stage 11: transmitter code bias identifiability guards ------
            if isfield(cfg,'hardware') && isfield(cfg.hardware,'txCodeBias')
                txc = cfg.hardware.txCodeBias;
                useInEKF11 = isfield(txc,'useInEKF') && txc.useInEKF;
                if useInEKF11
                    txMode11 = 'off';
                    if isfield(txc,'mode'); txMode11 = txc.mode; end

                    % Guard 1: useInEKF=true requires a valid mode
                    if strcmp(txMode11,'off')
                        error('ConfigFactory:txCodeBiasModeOff', ...
                            ['cfg.hardware.txCodeBias.useInEKF=true but mode=''off''. ' ...
                             'Set cfg.hardware.txCodeBias.mode=''perTowerL1'' to enable states.']);
                    end

                    % Guard 2: collinear with tower clock bias
                    estimTwrClk11 = isfield(cfg.estimator,'estimateTowerClocks') && ...
                                    cfg.estimator.estimateTowerClocks;
                    if estimTwrClk11
                        error('ConfigFactory:txCodeBiasCollinear', ...
                            ['Cannot freely estimate tower clock bias and transmitter code hardware delay together. ' ...
                             'They are collinear in one-way code pseudorange. ' ...
                             'Use external tower clock corrections or disable one of the two state groups.']);
                    end

                    % Guard 3: delay gauge required
                    gm11 = 'fixReferenceTower';
                    if isfield(txc,'gaugeMode'); gm11 = txc.gaugeMode; end
                    if ~any(strcmp(gm11, {'fixReferenceTower','meanGroundDelayGauge'}))
                        error('ConfigFactory:txCodeBiasGaugeRequired', ...
                            ['cfg.hardware.txCodeBias.useInEKF=true requires a valid delay gauge. ' ...
                             'Set cfg.hardware.txCodeBias.gaugeMode to ' ...
                             '''fixReferenceTower'' or ''meanGroundDelayGauge''. Got ''%s''.'], gm11);
                    end

                    % Guard 4: two-frequency / ionosphere-free not supported
                    codeMode11 = '';
                    if isfield(cfg,'measurements') && isfield(cfg.measurements,'codeMode')
                        codeMode11 = cfg.measurements.codeMode;
                    end
                    if any(strcmp(codeMode11, {'ionoFreeCode','twoFrequency','ionosphereFree'}))
                        error('ConfigFactory:txCodeBiasIF', ...
                            ['Stage 11 supports L1 per-tower code delay only. ' ...
                             'Per-signal L1/L2 group-delay states are not implemented yet. ' ...
                             'Disable txCodeBias or use singleFrequency code mode.']);
                    end

                    cfg.hardware.txCodeBias.enable = true;
                end
            end

            % ---- Stage 12: receiver hardware-bias identifiability guards ------
            if isfield(cfg,'hardware') && isfield(cfg.hardware,'rxCodeBias')
                rxcb = cfg.hardware.rxCodeBias;
                rxMode12 = 'absorbedInReceiverClock';
                if isfield(rxcb,'mode'); rxMode12 = rxcb.mode; end

                % Guard 1: free estimation is forbidden (collinear with receiver clock)
                if strcmp(rxMode12, 'estimate')
                    error('ConfigFactory:rxCodeBiasCollinear', ...
                        ['Receiver code hardware delay is collinear with receiver clock bias ' ...
                         'in single-frequency one-way pseudorange. ' ...
                         'Free EKF estimation is not identifiable without an external ' ...
                         'calibration, multi-frequency constraint, or clock prior. ' ...
                         'Use mode ''absorbedInReceiverClock'', ''fixed'', or ''externalCalibration''.']);
                end

                % Guard 2: fixed/external modes require a valid (non-NaN) value
                if any(strcmp(rxMode12, {'fixed','externalCalibration'}))
                    val12 = NaN;
                    if isfield(rxcb,'fixedValue_m'); val12 = rxcb.fixedValue_m; end
                    if isnan(val12)
                        error('ConfigFactory:rxCodeBiasNoValue', ...
                            ['cfg.hardware.rxCodeBias.mode=''%s'' requires a valid numeric ' ...
                             'fixedValue_m (got NaN). Set fixedValue_m to the calibrated ' ...
                             'receiver code hardware delay in metres.'], rxMode12);
                    end
                    cfg.hardware.rxCodeBias.enable = true;
                end
            end

            if isfield(cfg,'hardware') && isfield(cfg.hardware,'rxCarrierBias')
                rxcb2 = cfg.hardware.rxCarrierBias;
                rxCMode12 = 'notImplemented';
                if isfield(rxcb2,'mode'); rxCMode12 = rxcb2.mode; end

                % Guard 3: free carrier phase bias estimation is blocked
                if strcmp(rxCMode12, 'estimate')
                    error('ConfigFactory:rxCarrierBiasEstimate', ...
                        ['Receiver carrier phase hardware bias estimation is not supported. ' ...
                         'In float-ambiguity mode, constant phase hardware biases are absorbed ' ...
                         'into the float ambiguity states. Use mode ''absorbedInAmbiguity'' or ' ...
                         '''notImplemented'' to declare this explicitly.']);
                end

                % Warning (not error): carrier float in EKF + notImplemented → absorbed
                carrierModeInEKF12 = false;
                if isfield(cfg,'measurements') && isfield(cfg.measurements,'carrierMode')
                    carrierModeInEKF12 = strcmp(cfg.measurements.carrierMode,'ekfFloat');
                end
                if carrierModeInEKF12 && strcmp(rxCMode12,'notImplemented')
                    warnMsg12 = ['Receiver carrier hardware phase bias is absorbed into ' ...
                                 'float ambiguity states in this configuration ' ...
                                 '(rxCarrierBias.mode=''notImplemented'' + carrierMode=''ekfFloat''). ' ...
                                 'Absolute carrier phase calibration is not available.'];
                    cfg.validation.warnings{end+1} = warnMsg12;
                    warning('ConfigFactory:rxCarrierBiasAbsorbed', '%s', warnMsg12);
                end
            end

            % ---- Stage 13: ionosphere-free + rxCodeBias incompatibility guard ------
            % IF combines L1 and L2 with different coefficients, so a single scalar
            % receiver code-bias calibration is not well-defined for both frequencies.
            % Per-signal receiver code-bias handling is not implemented in Stage 13.
            codeModeIF13 = '';
            if isfield(cfg,'measurements') && isfield(cfg.measurements,'codeMode')
                codeModeIF13 = cfg.measurements.codeMode;
            end
            if strcmp(codeModeIF13,'ionosphereFree') && ...
                    isfield(cfg,'hardware') && isfield(cfg.hardware,'rxCodeBias')
                rxMode13 = 'absorbedInReceiverClock';
                if isfield(cfg.hardware.rxCodeBias,'mode')
                    rxMode13 = cfg.hardware.rxCodeBias.mode;
                end
                if any(strcmp(rxMode13, {'fixed','externalCalibration'}))
                    error('ConfigFactory:rxCodeBiasIFIncompatible', ...
                        ['cfg.hardware.rxCodeBias.mode=''%s'' is incompatible with ' ...
                         'codeMode=''ionosphereFree''. Ionosphere-free code requires per-signal ' ...
                         'hardware delay handling, which is not yet implemented. ' ...
                         'Use rxCodeBias.mode=''absorbedInReceiverClock'' or codeMode=''singleFrequency''.'], ...
                        rxMode13);
                end
            end

            % ---- Stage 80: one-way light-time / Sagnac consistency -------
            if isfield(cfg,'physics') && isfield(cfg.physics,'lightTime')
                lt = cfg.physics.lightTime;
                ltTruth = isfield(lt,'truth') && isfield(lt.truth,'enable') && lt.truth.enable;
                ltModel = isfield(lt,'model') && isfield(lt.model,'enable') && lt.model.enable;
                ltEnable = (isfield(lt,'enable') && lt.enable) || ltTruth || ltModel;
                if ~isfield(lt,'mode') || isempty(lt.mode)
                    cfg.physics.lightTime.mode = 'sagnacFirstOrder';
                end
                if ~isfield(lt,'iterations') && isfield(lt,'maxIter')
                    cfg.physics.lightTime.iterations = lt.maxIter;
                end
                if ~isfield(lt,'tolerance_s')
                    cfg.physics.lightTime.tolerance_s = getf_(lt,'tol_s',1e-12);
                end
                if ltEnable
                    mode80_ = cfg.physics.lightTime.mode;
                    switch mode80_
                        case {'sameEpoch','sagnacFirstOrder','firstOrderCorrection'}
                            cfg.effects.lightTime.model = 'sagnacFirstOrder';
                            cfg.physics.sagnac.mode = 'firstOrderCorrection';
                            cfg.physics.sagnac.truth.enable = ltTruth || cfg.physics.sagnac.truth.enable;
                            cfg.physics.sagnac.model.enable = ltModel || cfg.physics.sagnac.model.enable;
                            cfg.physics.lightTime.enable = true;
                            cfg.physics.lightTime.sagnacHandling = 'firstOrderCorrection';
                            cfg.physics.lightTime.doubleCountGuard = 'pass';
                        case {'iterativeOneWay','iterative'}
                            cfg.effects.lightTime.model = 'iterative';
                            cfg.effects.lightTime.maxIter = cfg.physics.lightTime.iterations;
                            cfg.effects.lightTime.tol_s = cfg.physics.lightTime.tolerance_s;
                            if (cfg.physics.sagnac.truth.enable || cfg.physics.sagnac.model.enable)
                                cfg.validation.warnings{end+1} = ...
                                    'Stage 80: iterativeOneWay light-time uses geometric Earth rotation; separate Sagnac truth/model disabled to prevent double counting.';
                            end
                            cfg.physics.sagnac.truth.enable = false;
                            cfg.physics.sagnac.model.enable = false;
                            cfg.physics.lightTime.enable = true;
                            cfg.physics.lightTime.sagnacHandling = 'geometricLightTime';
                            cfg.physics.lightTime.doubleCountGuard = 'pass';
                        otherwise
                            error('ConfigFactory:invalidLightTimeMode', ...
                                'Unsupported cfg.physics.lightTime.mode=''%s''.', mode80_);
                    end
                else
                    cfg.physics.lightTime.sagnacHandling = 'firstOrderCorrection';
                    cfg.physics.lightTime.doubleCountGuard = 'notNeeded';
                end
            end

            % ---- Unsupported: relativistic clock-rate correction ----------
            if isfield(cfg,'physics') && isfield(cfg.physics,'relativity') && ...
                    isfield(cfg.physics.relativity,'clock')
                rc    = cfg.physics.relativity.clock;
                rcOn  = (isfield(rc,'truth') && isfield(rc.truth,'enable') && rc.truth.enable) || ...
                        (isfield(rc,'model') && isfield(rc.model,'enable') && rc.model.enable);
                if rcOn
                    warnMsg = 'Relativistic clock-rate correction is not implemented as a validated v1 model and was disabled.';
                    if strcmp(policy,'error')
                        error('ConfigFactory:relClockNotSupported', '%s', warnMsg);
                    end
                    if isfield(rc,'truth') && isfield(rc.truth,'enable')
                        cfg.physics.relativity.clock.truth.enable = false;
                    end
                    if isfield(rc,'model') && isfield(rc.model,'enable')
                        cfg.physics.relativity.clock.model.enable = false;
                    end
                    cfg.validation.warnings{end+1}         = warnMsg;
                    cfg.validation.disabledFeatures{end+1} = 'relativity.clock';
                    warning('ConfigFactory:relClockDisabled', '%s', warnMsg);
                end
            end

            % ---- Carrier mode validation ----------------------------------
            % New API: cfg.measurements.carrierMode takes precedence.
            % Legacy: cfg.measurements.carrierPhase.useInEKF=true without new API
            %   → disabled with warning for backward compatibility.
            hasNewCarrierMode = isfield(cfg,'measurements') && ...
                isfield(cfg.measurements,'carrierMode');
            if hasNewCarrierMode
                carrierMode = cfg.measurements.carrierMode;
                switch carrierMode
                    case 'ekfFloat'
                        % Require a supported ambiguityMode
                        ambMode = '';
                        if isfield(cfg,'estimation') && isfield(cfg.estimation,'ambiguityMode')
                            ambMode = cfg.estimation.ambiguityMode;
                        end
                        validAmbModes = {'floatPerTowerSignal','floatPerTowerReceiverSignal'};
                        if ~any(strcmp(ambMode, validAmbModes))
                            error('ConfigFactory:carrierEKFRequiresAmbiguities', ...
                                ['carrierMode=''ekfFloat'' requires ' ...
                                 'cfg.estimation.ambiguityMode to be ''floatPerTowerSignal'' ' ...
                                 '(single receiver) or ''floatPerTowerReceiverSignal'' ' ...
                                 '(multi-receiver). Got ''%s''.'], ambMode);
                        end
                        % Require carrier signals configured
                        if ~isfield(cfg,'measurements') || ~isfield(cfg.measurements,'codeMode')
                            cfg.measurements.codeMode = 'singleFrequency';
                        end
                    case {'off','diagnostic'}
                        % Ensure legacy useInEKF=true is silenced when carrierMode governs behavior
                        if isfield(cfg,'measurements') && isfield(cfg.measurements,'carrierPhase') && ...
                                isfield(cfg.measurements.carrierPhase,'useInEKF') && ...
                                cfg.measurements.carrierPhase.useInEKF
                            cfg.measurements.carrierPhase.useInEKF = false;
                        end
                    otherwise
                        error('ConfigFactory:invalidCarrierMode', ...
                            'cfg.measurements.carrierMode must be ''off'', ''diagnostic'', or ''ekfFloat''; got ''%s''.', carrierMode);
                end
            else
                % Legacy path: check old carrierPhase.useInEKF
                if isfield(cfg,'measurements') && isfield(cfg.measurements,'carrierPhase') && ...
                        isfield(cfg.measurements.carrierPhase,'useInEKF') && ...
                        cfg.measurements.carrierPhase.useInEKF
                    warnMsg = ['Carrier phase EKF use via carrierPhase.useInEKF is deprecated. ' ...
                               'Set cfg.measurements.carrierMode=''ekfFloat'' and ' ...
                               'cfg.estimation.ambiguityMode=''floatPerTowerSignal'' instead. ' ...
                               'carrierPhase.useInEKF disabled (diagnostic mode kept if enable=true).'];
                    if strcmp(policy,'error')
                        error('ConfigFactory:carrierEKFUseLegacy', '%s', warnMsg);
                    end
                    cfg.measurements.carrierPhase.useInEKF = false;
                    cfg.validation.warnings{end+1}         = warnMsg;
                    cfg.validation.disabledFeatures{end+1} = 'carrierPhase.useInEKF';
                    warning('ConfigFactory:carrierEKFLegacy', '%s', warnMsg);
                end
            end

            % ---- Stage 79: central signal and frequency ownership --------
            if ~isfield(cfg,'signals'); cfg.signals = struct(); end
            if ~isfield(cfg,'measurements'); cfg.measurements = struct(); end
            if ~isfield(cfg.measurements,'code'); cfg.measurements.code = struct(); end
            if ~isfield(cfg.measurements,'carrier'); cfg.measurements.carrier = struct(); end
            if ~isfield(cfg.measurements,'doppler'); cfg.measurements.doppler = struct(); end

            sigNames79_ = {};
            if isfield(cfg.signals,'names'); sigNames79_ = cfg.signals.names; end
            if ischar(sigNames79_); sigNames79_ = {sigNames79_}; end
            if isfield(cfg.signals,'enabledMask')
                sigMask79_ = logical(cfg.signals.enabledMask(:)).';
                if isempty(sigNames79_) || numel(sigMask79_) > numel(sigNames79_)
                    defaultNames79_ = {'L1','L2','L5'};
                    if numel(sigMask79_) > numel(defaultNames79_)
                        error('ConfigFactory:signalMaskUnsupported', ...
                            'cfg.signals.enabledMask has %d entries but only L1/L2/L5 are defined in v1.', ...
                            numel(sigMask79_));
                    end
                    sigNames79_ = defaultNames79_(1:numel(sigMask79_));
                end
            else
                if isempty(sigNames79_)
                    if isfield(cfg.signals,'enabled')
                        sigNames79_ = cfg.signals.enabled;
                        if ischar(sigNames79_); sigNames79_ = {sigNames79_}; end
                    else
                        sigNames79_ = {'L1'};
                    end
                end
                sigMask79_ = true(1,numel(sigNames79_));
            end
            if numel(sigMask79_) ~= numel(sigNames79_)
                error('ConfigFactory:signalMaskSize', ...
                    'cfg.signals.enabledMask length (%d) must match cfg.signals.names length (%d).', ...
                    numel(sigMask79_), numel(sigNames79_));
            end

            legacyTwo79_ = isfield(cfg.signals,'twoFrequency') && ...
                isfield(cfg.signals.twoFrequency,'enable') && cfg.signals.twoFrequency.enable;
            if legacyTwo79_ && nnz(sigMask79_) <= 1
                cfg.validation.warnings{end+1} = ...
                    'cfg.signals.twoFrequency.enable is legacy and disagrees with cfg.signals.enabledMask; enabledMask wins.';
            end

            nSig79_ = numel(sigNames79_);
            freqHz79_ = zeros(1,nSig79_);
            waveM79_  = zeros(1,nSig79_);
            for si79_ = 1:nSig79_
                sd79_ = revgnss.SignalDefinition.get(sigNames79_{si79_});
                freqHz79_(si79_) = sd79_.frequency_Hz;
                waveM79_(si79_)  = sd79_.wavelength_m;
            end
            cfg.signals.names        = sigNames79_;
            cfg.signals.frequencyHz  = freqHz79_;
            cfg.signals.wavelength_m = waveM79_;
            cfg.signals.enabledMask  = sigMask79_;
            cfg.signals.enabled      = sigNames79_(sigMask79_);
            if ~isfield(cfg.signals,'twoFrequency'); cfg.signals.twoFrequency = struct(); end
            cfg.signals.twoFrequency.enable = nnz(sigMask79_) > 1;

            for si79_ = 1:nSig79_
                sn79_ = sigNames79_{si79_};
                cfg.signals.(sn79_).frequency_Hz = freqHz79_(si79_);
                cfg.signals.(sn79_).lambda_m     = waveM79_(si79_);
            end

            codeMask79_ = sigMask79_;
            if isfield(cfg.measurements.code,'enabledByFrequency')
                codeMask79_ = logical(cfg.measurements.code.enabledByFrequency(:)).';
                if numel(codeMask79_) ~= nSig79_
                    codeMask79_ = sigMask79_;
                end
            end
            carrierMask79_ = sigMask79_;
            if isfield(cfg.measurements.carrier,'enabledByFrequency')
                carrierMask79_ = logical(cfg.measurements.carrier.enabledByFrequency(:)).';
                if numel(carrierMask79_) ~= nSig79_
                    carrierMask79_ = sigMask79_;
                end
            end
            dopplerMask79_ = sigMask79_;
            if isfield(cfg.measurements.doppler,'enabledByFrequency')
                dopplerMask79_ = logical(cfg.measurements.doppler.enabledByFrequency(:)).';
                if numel(dopplerMask79_) ~= nSig79_
                    dopplerMask79_ = sigMask79_;
                end
            end
            if numel(codeMask79_) ~= nSig79_ || numel(carrierMask79_) ~= nSig79_ || numel(dopplerMask79_) ~= nSig79_
                error('ConfigFactory:frequencyMaskSize', ...
                    'Per-observable enabledByFrequency masks must match cfg.signals.names length (%d).', nSig79_);
            end
            if any(codeMask79_ & ~sigMask79_) || any(carrierMask79_ & ~sigMask79_) || any(dopplerMask79_ & ~sigMask79_)
                error('ConfigFactory:observableMaskExceedsSignalMask', ...
                    'Observable frequency masks may not enable a signal disabled by cfg.signals.enabledMask.');
            end
            cfg.measurements.code.enabledByFrequency    = codeMask79_ & sigMask79_;
            cfg.measurements.carrier.enabledByFrequency = carrierMask79_ & sigMask79_;
            cfg.measurements.doppler.enabledByFrequency = dopplerMask79_ & sigMask79_;

            if ~isfield(cfg.measurements.carrier,'l2EkfRows')
                cfg.measurements.carrier.l2EkfRows = struct();
            end
            l2Idx79_ = find(strcmpi(sigNames79_,'L2'), 1);
            if ~isfield(cfg.measurements.code,'l2Rows')
                cfg.measurements.code.l2Rows = struct();
            end
            l2Code79_ = ~isempty(l2Idx79_) && cfg.measurements.code.enabledByFrequency(l2Idx79_);
            if isfield(cfg.measurements.code.l2Rows,'enable') && ...
                    logical(cfg.measurements.code.l2Rows.enable) ~= l2Code79_
                cfg.validation.warnings{end+1} = ...
                    'cfg.measurements.code.l2Rows.enable is derived from code.enabledByFrequency; canonical code mask wins.';
            end
            cfg.measurements.code.l2Rows.enable = l2Code79_;

            l2Carrier79_ = ~isempty(l2Idx79_) && cfg.measurements.carrier.enabledByFrequency(l2Idx79_);
            if isfield(cfg.measurements.carrier.l2EkfRows,'enable') && ...
                    logical(cfg.measurements.carrier.l2EkfRows.enable) ~= l2Carrier79_
                cfg.validation.warnings{end+1} = ...
                    'cfg.measurements.carrier.l2EkfRows.enable is derived from carrier.enabledByFrequency; canonical carrier mask wins.';
            end
            cfg.measurements.carrier.l2EkfRows.enable = l2Carrier79_;

            if isfield(cfg,'estimator') && isfield(cfg.estimator,'diffAtt') && ...
                    isfield(cfg.estimator.diffAtt,'ambiguityResolution')
                arMask79_ = cfg.measurements.carrier.enabledByFrequency;
                arCfg79_ = cfg.estimator.diffAtt.ambiguityResolution;
                if isfield(arCfg79_,'enabledByFrequency')
                    arMask79_ = logical(arCfg79_.enabledByFrequency(:)).';
                    if numel(arMask79_) ~= nSig79_
                        error('ConfigFactory:arFrequencyMaskSize', ...
                            'cfg.estimator.diffAtt.ambiguityResolution.enabledByFrequency must match cfg.signals.names length (%d).', nSig79_);
                    end
                    if any(arMask79_ & ~cfg.measurements.carrier.enabledByFrequency)
                        error('ConfigFactory:arMaskExceedsCarrierMask', ...
                            'Attitude ambiguity-resolution frequencies must be a subset of carrier.enabledByFrequency.');
                    end
                end
                cfg.estimator.diffAtt.ambiguityResolution.enabledByFrequency = arMask79_;
            end

            % ---- Stage 79: multi-space-asset guard ---------------------------
            msg79Multi_ = ['Multi-space-asset estimation is unsupported in oo_v1 active scenario. ' ...
                'This stage intentionally does not truncate assets.'];
            if isfield(cfg,'scenario') && isfield(cfg.scenario,'nSpaceAssets') && cfg.scenario.nSpaceAssets > 1
                error('ConfigFactory:multiAssetUnsupported', '%s', msg79Multi_);
            end
            if isfield(cfg,'assets') && numel(cfg.assets) > 1
                error('ConfigFactory:multiAssetUnsupported', '%s', msg79Multi_);
            end

            % ---- codeMode validation -------------------------------------
            if isfield(cfg,'measurements') && isfield(cfg.measurements,'codeMode')
                codeMode = cfg.measurements.codeMode;
                switch codeMode
                    case 'ionosphereFree'
                        % Requires L1+L2
                        sigNames = {};
                        if isfield(cfg,'signals') && isfield(cfg.signals,'enabled')
                            sigNames = cfg.signals.enabled;
                        end
                        hasL1 = any(strcmpi(sigNames,'L1'));
                        hasL2 = any(strcmpi(sigNames,'L2'));
                        if ~hasL1 || ~hasL2
                            error('ConfigFactory:ionoFreeRequiresDualFreq', ...
                                'codeMode=''ionosphereFree'' requires L1 and L2 signals. Enable cfg.signals.enabledMask=[true true].');
                        end
                    case {'singleFrequency','dualFrequencyStacked'}
                        % OK
                    otherwise
                        error('ConfigFactory:invalidCodeMode', ...
                            'cfg.measurements.codeMode must be ''singleFrequency'', ''dualFrequencyStacked'', or ''ionosphereFree''; got ''%s''.', codeMode);
                end
            end

            % ---- Carrier ekfFloat v1 restrictions -----------------------
            % Runs AFTER Stage 79 canonical masks are finalized.
            if isfield(cfg,'measurements') && isfield(cfg.measurements,'carrierMode') && ...
                    strcmp(cfg.measurements.carrierMode,'ekfFloat')

                % L2 carrier EKF rows are selected by carrier.enabledByFrequency.
                sigEnabled = {};
                if isfield(cfg,'signals') && isfield(cfg.signals,'enabled')
                    sigEnabled = cfg.signals.enabled;
                end
                l2EkfGuardOn = isfield(cfg,'measurements') && ...
                    isfield(cfg.measurements,'carrier') && ...
                    isfield(cfg.measurements.carrier,'l2EkfRows') && ...
                    isfield(cfg.measurements.carrier.l2EkfRows,'enable') && ...
                    cfg.measurements.carrier.l2EkfRows.enable;
                if numel(sigEnabled) > 1 && ~l2EkfGuardOn
                    warnMsg4D = ['ekfFloat carrier mode: multiple signals enabled but ' ...
                                 'L2 carrier EKF rows are OFF by cfg.measurements.carrier.enabledByFrequency. ' ...
                                 'Only enabled carrier-mask rows will be added.'];
                    cfg.validation.warnings{end+1} = warnMsg4D;
                    warning('ConfigFactory:carrierL2EkfGuardOff', '%s', warnMsg4D);
                end

                % Task 4E: carrierCombinationMode='ionosphereFree' not implemented
                cCombMode = '';
                if isfield(cfg.measurements,'carrierCombinationMode')
                    cCombMode = cfg.measurements.carrierCombinationMode;
                end
                if strcmp(cCombMode,'ionosphereFree')
                    warnMsg4E = ['carrierCombinationMode=''ionosphereFree'' is not implemented ' ...
                                 'in v1 ekfFloat. Raw L1 carrier only. ' ...
                                 'To suppress this error and fall back to raw L1, set: ' ...
                                 'cfg.validation.unsupportedFeaturePolicy = ''disableWithWarning''.'];
                    if ~strcmp(policy,'disableWithWarning')
                        error('ConfigFactory:carrierIFNotSupported', '%s', warnMsg4E);
                    end
                    cfg.measurements.carrierCombinationMode = 'raw';
                    cfg.validation.warnings{end+1}         = warnMsg4E;
                    cfg.validation.disabledFeatures{end+1} = 'carrierCombinationMode.ionosphereFree';
                    warning('ConfigFactory:carrierIFDisabled', '%s', warnMsg4E);
                end

                nRx4F = 1;
                if isfield(cfg,'scenario') && isfield(cfg.scenario,'nReceivers')
                    nRx4F = cfg.scenario.nReceivers;
                end
                ambMode4F = '';
                if isfield(cfg,'estimation') && isfield(cfg.estimation,'ambiguityMode')
                    ambMode4F = cfg.estimation.ambiguityMode;
                end
                % Task 4F: floatPerTowerSignal with multiple receivers is invalid
                % (states indexed per tower/signal, rows per tower/receiver → dimension mismatch).
                % floatPerTowerReceiverSignal is the correct multi-receiver mode.
                if nRx4F > 1 && strcmp(ambMode4F,'floatPerTowerSignal')
                    error('ConfigFactory:carrierAmbiguityReceiverIndexRequired', ...
                        ['carrierMode=''ekfFloat'' with nReceivers=%d requires ' ...
                         'cfg.estimation.ambiguityMode=''floatPerTowerReceiverSignal''. ' ...
                         '''floatPerTowerSignal'' is valid for single receiver only — ' ...
                         'it indexes ambiguities per tower/signal, not tower/receiver/signal.'], nRx4F);
                end
            end

            % ---- Stage 15: attitudeCarrierMode validation ----------------
            if isfield(cfg,'estimator') && isfield(cfg.estimator,'attitudeCarrierMode') && ...
                    strcmp(cfg.estimator.attitudeCarrierMode,'calibratedDifferentialAmbiguity')
                carrierOk = isfield(cfg,'measurements') && isfield(cfg.measurements,'carrierMode') && ...
                    strcmp(cfg.measurements.carrierMode,'ekfFloat');
                nRx15 = 1;
                if isfield(cfg,'scenario') && isfield(cfg.scenario,'nReceivers')
                    nRx15 = cfg.scenario.nReceivers;
                end
                if ~carrierOk
                    cfg.estimator.attitudeCarrierMode = 'off';
                    cfg.validation.warnings{end+1} = ...
                        'attitudeCarrierMode=calibratedDifferentialAmbiguity requires carrierMode=ekfFloat. Disabled.';
                elseif nRx15 < 2
                    cfg.estimator.attitudeCarrierMode = 'off';
                    cfg.validation.warnings{end+1} = ...
                        'attitudeCarrierMode=calibratedDifferentialAmbiguity requires nReceivers>=2. Disabled.';
                end
            end

            % ---- Stage 16: attitude initialization mode validation --------
            if ~isfield(cfg.estimator,'attitudeInitMode')
                cfg.estimator.attitudeInitMode = 'none';
            end
            attInitMode16 = cfg.estimator.attitudeInitMode;
            validInit16 = {'none','knownAttitudeCalibration','coarseBaselineIntegerSearch'};
            if ~any(strcmp(attInitMode16, validInit16))
                error('ConfigFactory:invalidAttitudeInitMode', ...
                    'cfg.estimator.attitudeInitMode must be none, knownAttitudeCalibration, or coarseBaselineIntegerSearch.');
            end
            if ~strcmp(attInitMode16,'none')
                nRx16 = 1;
                if isfield(cfg,'scenario') && isfield(cfg.scenario,'nReceivers')
                    nRx16 = cfg.scenario.nReceivers;
                end
                carrierOk16 = isfield(cfg,'measurements') && isfield(cfg.measurements,'carrierMode') && ...
                    strcmp(cfg.measurements.carrierMode,'ekfFloat');
                ambMode16 = '';
                if isfield(cfg,'estimation') && isfield(cfg.estimation,'ambiguityMode')
                    ambMode16 = cfg.estimation.ambiguityMode;
                end
                if nRx16 < 3
                    error('ConfigFactory:attitudeInitReceivers', ...
                        'attitudeInitMode=%s requires at least 3 receiver phase centres.', attInitMode16);
                end
                if ~carrierOk16 || ~strcmp(ambMode16,'floatPerTowerReceiverSignal')
                    error('ConfigFactory:attitudeInitCarrierMode', ...
                        ['attitudeInitMode=%s requires carrierMode=ekfFloat and ' ...
                         'ambiguityMode=floatPerTowerReceiverSignal.'], attInitMode16);
                end
                if strcmp(attInitMode16,'knownAttitudeCalibration')
                    allow16 = isfield(cfg.estimator,'attitudeInit') && ...
                        isfield(cfg.estimator.attitudeInit,'knownAttitudeCalibration') && ...
                        isfield(cfg.estimator.attitudeInit.knownAttitudeCalibration,'allow') && ...
                        cfg.estimator.attitudeInit.knownAttitudeCalibration.allow;
                    if ~allow16
                        error('ConfigFactory:knownAttitudeNotDeclared', ...
                            ['knownAttitudeCalibration requires ' ...
                             'cfg.estimator.attitudeInit.knownAttitudeCalibration.allow=true.']);
                    end
                end
            end

            % ---- Unsupported: Doppler EKF dependency ---------------------
            if isfield(cfg,'measurements') && isfield(cfg.measurements,'doppler') && ...
                    isfield(cfg.measurements.doppler,'useInEKF') && ...
                    cfg.measurements.doppler.useInEKF
                dEnable  = isfield(cfg.measurements.doppler,'enable') && cfg.measurements.doppler.enable;
                dModelOk = isfield(cfg,'physics') && isfield(cfg.physics,'doppler') && ...
                           isfield(cfg.physics.doppler,'model') && ...
                           isfield(cfg.physics.doppler.model,'enable') && ...
                           cfg.physics.doppler.model.enable;
                if ~dEnable || ~dModelOk
                    missing = {};
                    if ~dEnable;  missing{end+1} = 'doppler.enable=true'; end
                    if ~dModelOk; missing{end+1} = 'physics.doppler.model.enable=true'; end
                    warnMsg = sprintf('doppler.useInEKF requires %s. useInEKF disabled.', strjoin(missing,' and '));
                    cfg.measurements.doppler.useInEKF      = false;
                    cfg.validation.warnings{end+1}         = warnMsg;
                    cfg.validation.disabledFeatures{end+1} = 'doppler.useInEKF';
                    warning('ConfigFactory:dopplerEKFDisabled', '%s', warnMsg);
                end
            end

            % ---- Tower count -----------------------------------------------
            nT_req   = cfg.scenario.nTowers;
            nT_avail = numel(cfg.towers);
            if nT_req > nT_avail
                error('ConfigFactory:finalizeConfig', ...
                    ['cfg.scenario.nTowers=%d but only %d towers are defined ' ...
                     'in cfg.towers.  Add tower definitions or reduce nTowers.'], ...
                    nT_req, nT_avail);
            end
            cfg.towers = cfg.towers(1:nT_req);

            % ---- Recreate tower clocks from type + factors (idempotent) ----
            gs = cfg.clockScaling;
            for k = 1:nT_req
                if isfield(cfg.towers(k),'clockType') && ...
                        isfield(cfg.towers(k),'clockFactors')
                    % Sync roleNoiseFactor from clockScaling before recreating
                    cfg.towers(k).clockFactors.roleNoiseFactor = ...
                        gs.towerNoiseFactor;
                    prev = cfg.towers(k).clock;
                    clk  = revgnss.ConfigFactory.makeClockConfig( ...
                        cfg.towers(k).clockType, 200+k, ...
                        cfg.towers(k).clockFactors, gs);
                    clk.name          = prev.name;
                    clk.deterministic = prev.deterministic;
                    clk.bias_s        = prev.bias_s;
                    clk.fracFreq      = prev.fracFreq;
                    cfg.towers(k).clock = clk;
                end
            end

            % ---- Recreate receiver clock (idempotent) ----------------------
            if isfield(cfg.asset,'clockType') && isfield(cfg.asset,'clockFactors')
                cfg.asset.clockFactors.roleNoiseFactor = gs.receiverNoiseFactor;
                prev = cfg.asset.clock;
                clk  = revgnss.ConfigFactory.makeClockConfig( ...
                    cfg.asset.clockType, 100, cfg.asset.clockFactors, gs);
                clk.name          = prev.name;
                clk.deterministic = prev.deterministic;
                clk.bias_s        = prev.bias_s;
                clk.fracFreq      = prev.fracFreq;
                cfg.asset.clock   = clk;
            end

            % ---- Receiver lever arms and auto-attitude ----------------------
            % Priority: custom 3×nR arms always win (any nR).
            %           Then auto-fill from 4-column cross pattern if nR<=4.
            %           Else require custom arms or error.
            % Auto-attitude: nReceivers==1 → all attitude flags false.
            %                nReceivers >1 → attitude estimated from lever arms.
            % Angular-rate estimation stays disabled unless a rotational velocity
            % measurement model is implemented.
            nR_req      = cfg.scenario.nReceivers;
            defaultArms = [1 -1 0 0; 0 0 1 -1; 0.2 0.2 -0.2 -0.2];  % 3 × 4

            if nR_req < 1
                error('ConfigFactory:finalizeConfig', ...
                    'cfg.scenario.nReceivers must be >= 1 (got %d).', nR_req);
            end

            if nR_req == 1
                % Single receiver: force zero lever arm; attitude is unobservable.
                cfg.asset.receiverLeverArm_body_m              = [0; 0; 0];
                cfg.asset.receiverLeverArms_body_m             = [0; 0; 0];
                cfg.estimator.estimateAttitude                   = false;
                cfg.estimator.estimateAngularRate                = false;
                cfg.estimator.estimateAttitudeFromPseudorange    = false;
                cfg.estimator.estimateAngularRateFromPseudorange = false;
            else
                % Multi-receiver: attitude is observable from pseudorange geometry.
                cfg.estimator.estimateAttitude                   = true;
                cfg.estimator.estimateAngularRate                = false;
                cfg.estimator.estimateAttitudeFromPseudorange    = true;
                cfg.estimator.estimateAngularRateFromPseudorange = false;
                existingArms = cfg.asset.receiverLeverArms_body_m;
                isCustom = (size(existingArms,1) == 3) && (size(existingArms,2) == nR_req);
                if isCustom
                    % Custom 3×nR arms already present — keep as-is.
                elseif nR_req <= size(defaultArms, 2)
                    cfg.asset.receiverLeverArms_body_m = defaultArms(:, 1:nR_req);
                else
                    error('ConfigFactory:finalizeConfig', ...
                        ['nReceivers=%d > 4 requires custom 3x%d receiverLeverArms_body_m. ' ...
                         'Set cfg.asset.receiverLeverArms_body_m to a 3x%d matrix ' ...
                         'before calling finalizeConfig.'], nR_req, nR_req, nR_req);
                end
                cfg.asset.receiverLeverArm_body_m = cfg.asset.receiverLeverArms_body_m(:, 1);

                initEuler_deg = [0; 0; 0];
                if isfield(cfg.estimator,'initialError') && ...
                        isfield(cfg.estimator.initialError,'euler_deg')
                    initEuler_deg = cfg.estimator.initialError.euler_deg(:);
                end
                initEulerMax_rad = max(abs(initEuler_deg)) * pi/180;
                if initEulerMax_rad > 0 && cfg.estimator.P0_euler_rad < initEulerMax_rad
                    cfg.estimator.P0_euler_rad = max(deg2rad(5), 2 * initEulerMax_rad);
                    cfg.validation.warnings{end+1} = ...
                        'P0_euler_rad increased to be consistent with nonzero initial attitude error.';
                end
                if ~strcmp(cfg.estimator.attitudeInitMode,'none')
                    arms16 = cfg.asset.receiverLeverArms_body_m;
                    leverNorm16 = sqrt(sum(arms16.^2, 1));
                    centered16 = arms16 - mean(arms16, 2);
                    if sum(leverNorm16 > 0.05) < 3 || rank(centered16, 1e-6) < 2
                        error('ConfigFactory:attitudeInitLeverGeometry', ...
                            'attitude initialization requires three non-collinear receiver lever arms.');
                    end
                    if strcmp(cfg.estimator.attitudeInitMode,'coarseBaselineIntegerSearch')
                        s16 = cfg.estimator.attitudeInit.search;
                        win16 = s16.windowDeg(:); if numel(win16) == 1; win16 = repmat(win16,3,1); end
                        step16 = s16.stepDeg(:); if numel(step16) == 1; step16 = repmat(step16,3,1); end
                        nCand16 = prod(floor(2*win16 ./ step16) + 1);
                        if any(step16 <= 0) || any(win16 < 0) || nCand16 > s16.maxCandidates
                            error('ConfigFactory:attitudeInitSearchWindow', ...
                                'coarseBaselineIntegerSearch candidate count (%d) exceeds maxCandidates (%d).', ...
                                nCand16, s16.maxCandidates);
                        end
                    end
                end
            end

            % ---- Tower survey errors (Stage 2) --------------------------------
            % One deterministic ENU error per tower drawn from a seeded RNG.
            % Same realization stored for truth and model use:
            %   truth=on / model=off  → innovation shows deterministic bias.
            %   truth=on / model=on   → mostly cancels (same error applied to both).
            if isfield(cfg,'effects') && isfield(cfg.effects,'towerSurvey')
                ts  = cfg.effects.towerSurvey;
                rngS = RandStream('mt19937ar','Seed', ts.seed);
                for k = 1:nT_req
                    cfg.towers(k).surveyError_ENU_m = ts.sigmaENU_m(:) .* randn(rngS, 3, 1);
                end
            else
                for k = 1:nT_req
                    cfg.towers(k).surveyError_ENU_m = zeros(3,1);
                end
            end
            cfg = revgnss.MultiAssetConfig.normalize(cfg);
            revgnss.ISLMeasurementBuilder.validateConfig(cfg);
            revgnss.TwoWayISLMeasurementBuilder.validateConfig(cfg);
            revgnss.ISLTimingModel.validateConfig(cfg);
            revgnss.TWSTFTDiagnosticBuilder.validateConfig(cfg);

            nWarn79_ = 0;
            if isfield(cfg,'validation') && isfield(cfg.validation,'warnings')
                nWarn79_ = numel(cfg.validation.warnings);
            end
            cfg.validation.centralConfigAudit = struct( ...
                'stage', '79', ...
                'status', 'pass', ...
                'signalConfigOwner', 'cfg.signals.names+cfg.signals.enabledMask', ...
                'frequencyHardcodeAuditStatus', 'canonicalSignalDefinition', ...
                'legacySignalAliasStatus', 'derivedFromCanonicalSignals', ...
                'receiverGeometryOwner', 'revgnss.ReceiverGeometry.defaultLeverArms+ScenarioPresets', ...
                'multiAssetTruncationGuard', 'hardErrorNoTruncation', ...
                'clockConfigOwner', 'cfg.clocks.tower.product', ...
                'slipConfigOwner', 'cfg.carrierSlip', ...
                'ambiguityConfigOwner', 'cfg.estimator.diffAtt.ambiguityResolution', ...
                'orbitConfigOwner', 'ScenarioPresets.twoBodyRk4+twoBody', ...
                'nWarnings', nWarn79_, ...
                'nErrors', 0, ...
                'centralConfigWarnings', nWarn79_, ...
                'centralConfigErrors', 0);

            % --- Stage 81: Scientific profile, product contracts, and model coverage ---
            % All canonical Stage 81 config fields are owned here in finalizeConfig.

            % Scientific profile
            if ~isfield(cfg, 'scientificProfile') || ~isfield(cfg.scientificProfile, 'mode')
                cfg.scientificProfile.mode = 'singleAssetOneWaySyntheticClosedV1';
            end
            if ~isfield(cfg.scientificProfile, 'claimLevel')
                cfg.scientificProfile.claimLevel = 'controlledSynthetic';
            end
            if ~isfield(cfg.scientificProfile, 'allowRealWorldClaim')
                cfg.scientificProfile.allowRealWorldClaim = false;
            end
            if cfg.scientificProfile.allowRealWorldClaim
                error('ConfigFactory:realWorldClaimBlocked', ...
                    ['cfg.scientificProfile.allowRealWorldClaim=true is blocked in v1. ' ...
                     'Real external product parsers (SP3/CLK/RINEX/ANTEX/IONEX) are not implemented. ' ...
                     'Set allowRealWorldClaim=false (default).']);
            end

            % External product interface contracts
            prodNames = {'sp3','clk','rinex','antex','ionex','eop','bias'};
            defMode   = {'notImplemented','syntheticTruthHistory','notImplemented', ...
                         'notImplemented','notImplemented','constantEarthRotationV1', ...
                         'syntheticKnownZero'};
            for pi_ = 1:numel(prodNames)
                pn_ = prodNames{pi_};
                if ~isfield(cfg,'products') || ~isfield(cfg.products,pn_) || ...
                        ~isfield(cfg.products.(pn_),'mode')
                    cfg.products.(pn_).mode = defMode{pi_};
                end
                if strcmp(cfg.products.(pn_).mode, 'externalFile')
                    error('ConfigFactory:externalFileNotImplemented', ...
                        ['cfg.products.%s.mode=''externalFile'' is not implemented. ' ...
                         'Only notImplemented / syntheticTruthHistory modes are valid in v1.'], pn_);
                end
            end

            % Bias mode canonical fields
            if ~isfield(cfg,'biases') || ~isfield(cfg.biases,'code') || ~isfield(cfg.biases.code,'mode')
                cfg.biases.code.mode = 'syntheticConfiguredZero';
            end
            if ~isfield(cfg.biases,'phase') || ~isfield(cfg.biases.phase,'mode')
                cfg.biases.phase.mode = 'syntheticKnownZero';
            end
            if ~isfield(cfg.biases,'interFrequency') || ~isfield(cfg.biases.interFrequency,'mode')
                cfg.biases.interFrequency.mode = 'syntheticConfiguredZero';
            end

            % Troposphere closure fields
            if ~isfield(cfg,'effects') || ~isfield(cfg.effects,'troposphere')
                cfg.effects.troposphere.claimStatus = 'syntheticSimpleMappedV1';
            end
            if ~isfield(cfg.effects.troposphere,'claimStatus')
                cfg.effects.troposphere.claimStatus = 'syntheticSimpleMappedV1';
            end
            if ~isfield(cfg.effects.troposphere,'gradientStatus')
                cfg.effects.troposphere.gradientStatus = 'disabled';
            end
            if ~isfield(cfg.effects.troposphere,'vmdStatus')
                cfg.effects.troposphere.vmdStatus = 'notImplemented';
            end

            % Ionosphere closure fields
            if ~isfield(cfg.effects,'ionosphere')
                cfg.effects.ionosphere.claimStatus = 'syntheticSimpleMappedV1';
            end
            if ~isfield(cfg.effects.ionosphere,'claimStatus')
                cfg.effects.ionosphere.claimStatus = 'syntheticSimpleMappedV1';
            end
            if ~isfield(cfg.effects.ionosphere,'higherOrderStatus')
                cfg.effects.ionosphere.higherOrderStatus = 'disabled';
            end
            if ~isfield(cfg.effects.ionosphere,'klobucharStatus')
                cfg.effects.ionosphere.klobucharStatus = 'notImplemented';
            end
            if ~isfield(cfg.effects.ionosphere,'ionexStatus')
                cfg.effects.ionosphere.ionexStatus = 'notImplemented';
            end
            if ~isfield(cfg.effects.ionosphere,'carrierIfIntegerFixing')
                cfg.effects.ionosphere.carrierIfIntegerFixing = false;
            end

            % Validation statistics canonical fields
            if ~isfield(cfg,'validation') || ~isfield(cfg.validation,'statistics')
                cfg.validation.statistics.monteCarlo.enable = false;
                cfg.validation.statistics.nees.enable       = false;
                cfg.validation.statistics.nis.mode          = 'partialCovarianceAware';
            end
            if ~isfield(cfg.validation.statistics,'monteCarlo')
                cfg.validation.statistics.monteCarlo.enable = false;
            end
            if ~isfield(cfg.validation.statistics,'nees')
                cfg.validation.statistics.nees.enable = false;
            end
            if ~isfield(cfg.validation.statistics,'nis')
                cfg.validation.statistics.nis.mode = 'partialCovarianceAware';
            end


            % --- Stage 82: J2 dynamics mismatch validation fields ---
            % All canonical Stage 82 diagnostics are owned here in finalizeConfig.

            % Compute representative J2 accel at initial GEO orbit state (equatorial, z=0).
            cfg82_j2Norm_ = 0;
            try
                if isfield(cfg.orbit, 'altitudeMean_m') && cfg.orbit.useOrbitPropagator
                    Re82_ = revgnss.Constants.EARTH_RADIUS_M;
                    r82_  = cfg.orbit.altitudeMean_m + Re82_;
                    a82_  = revgnss.OrbitDynamics.j2Accel_mps2([r82_; 0; 0]);
                    cfg82_j2Norm_ = norm(a82_);
                end
            catch; end
            cfg.diagnostics.dynamicsMismatch.representativeJ2Accel_mps2 = cfg82_j2Norm_;

            % Classify dynamics mismatch and set j2 default policy.
            truthMode82_ = 'unknown';
            try; truthMode82_ = cfg.orbit.truth.mode; catch; end
            ekfMode82_   = 'unknown';
            try; ekfMode82_   = cfg.estimator.dynamics.mode; catch; end
            isJ2Truth82_      = any(strcmpi({'j2Rk4','j2'}, truthMode82_));
            isTwoBodyEkf82_   = any(strcmpi({'twoBody','two_body','twobody'}, ekfMode82_));
            isJ2EkfMode82_    = any(strcmpi({'j2','twobodyj2'}, ekfMode82_));

            if isJ2Truth82_ && isTwoBodyEkf82_
                cfg.diagnostics.dynamicsMismatch.j2DefaultPolicy  = 'j2TruthTwoBodyEkfMismatch';
                cfg.diagnostics.dynamicsMismatch.j2ActiveByDefault = true;
                cfg.diagnostics.dynamicsMismatch.mismatchLabel    = ...
                    sprintf('%s truth / %s EKF', truthMode82_, ekfMode82_);
                if ~cfg.estimator.processNoise.modelMismatch.enable
                    cfg.estimator.processNoise.modelMismatch.enable = true;
                end
                autoSigma82_ = max(1e-8, 0.25 * cfg82_j2Norm_);
                if cfg.estimator.processNoise.modelMismatch.sigma_mps2 <= 1e-6
                    cfg.estimator.processNoise.modelMismatch.sigma_mps2 = autoSigma82_;
                end
            elseif isJ2Truth82_ && isJ2EkfMode82_
                cfg.diagnostics.dynamicsMismatch.j2DefaultPolicy  = 'j2TruthJ2EkfMatched';
                cfg.diagnostics.dynamicsMismatch.j2ActiveByDefault = true;
                cfg.diagnostics.dynamicsMismatch.mismatchLabel    = 'j2 matched';
            else
                cfg.diagnostics.dynamicsMismatch.j2DefaultPolicy  = 'twoBodyDefaultJ2Available';
                cfg.diagnostics.dynamicsMismatch.j2ActiveByDefault = false;
                cfg.diagnostics.dynamicsMismatch.mismatchLabel    = 'matchedOrStationary';
            end

            % Process-noise consistency audit: sigma_accel must be >= 0.1 * J2 accel.
            cfg82_sigBase_ = 0.01;
            try; cfg82_sigBase_ = cfg.estimator.sigma_accel_mps2; catch; end
            if cfg82_sigBase_ <= 0; cfg82_sigBase_ = 0.01; end
            cfg.diagnostics.dynamicsMismatch.sigmaAccelBase_mps2    = cfg82_sigBase_;
            cfg.diagnostics.dynamicsMismatch.sigmaAccelMismatch_mps2 = ...
                cfg.estimator.processNoise.modelMismatch.sigma_mps2;
            if cfg82_j2Norm_ > 0 && cfg82_sigBase_ < 0.1 * cfg82_j2Norm_
                warning('ConfigFactory:processNoiseTooSmall', ...
                    'sigma_accel_mps2 (%.2e) < 0.1*J2 accel (%.2e); increase sigma_accel_mps2.', ...
                    cfg82_sigBase_, cfg82_j2Norm_);
                cfg.diagnostics.dynamicsMismatch.dynamicsProcessNoiseConsistency = 'marginalBelowThreshold';
            else
                cfg.diagnostics.dynamicsMismatch.dynamicsProcessNoiseConsistency = 'consistent';
            end

            % Source truth, report freshness, EOP status.
            if isJ2Truth82_
                cfg.diagnostics.sourceTruthStatus = 'j2Rk4DefaultOrConfigured';
            else
                cfg.diagnostics.sourceTruthStatus = 'twoBodyRk4DefaultOrConfigured';
            end
            cfg.diagnostics.reportStatusFreshnessStage = 82;
            cfg.diagnostics.eopStatus = 'notImplementedNoIERS';
            try
                if strcmpi(cfg.products.eop.mode, 'externalFile')
                    cfg.diagnostics.eopStatus = 'externalFile';
                end
            catch; end

            % Earth-rotation model guard.
            try
                erm82_ = cfg.frames.earthRotationModel;
                if ~strcmp(erm82_, 'constantOmegaV1')
                    warning('ConfigFactory:earthRotationModelNonCanonical', ...
                        'cfg.frames.earthRotationModel = ''%s'' is non-canonical; expected ''constantOmegaV1''.', erm82_);
                end
            catch; end

            % --- Stage 83: Doppler dynamics and carrier product-covariance closure ---
            if ~isfield(cfg,'measurements'); cfg.measurements = struct(); end
            if ~isfield(cfg.measurements,'doppler'); cfg.measurements.doppler = struct(); end
            if ~isfield(cfg.measurements.doppler,'modelLevel')
                cfg.measurements.doppler.modelLevel = 'frameConsistentV2';
            end
            if ~isfield(cfg.measurements.doppler,'includeTowerRotationalVelocity')
                cfg.measurements.doppler.includeTowerRotationalVelocity = true;
            end
            if ~isfield(cfg.measurements.doppler,'includeSagnacRate')
                cfg.measurements.doppler.includeSagnacRate = false;
            end
            if ~isfield(cfg.measurements.doppler,'includeLightTimeRate')
                cfg.measurements.doppler.includeLightTimeRate = false;
            end
            if ~isfield(cfg.measurements.doppler,'includeTowerClockProductDrift')
                cfg.measurements.doppler.includeTowerClockProductDrift = true;
            end
            if ~isfield(cfg.measurements.doppler,'jacobianMode')
                cfg.measurements.doppler.jacobianMode = 'analyticRangeRateV1';
            end
            if ~isfield(cfg,'covariance'); cfg.covariance = struct(); end
            if ~isfield(cfg.covariance,'productClock'); cfg.covariance.productClock = struct(); end
            if ~isfield(cfg.covariance.productClock,'enable')
                cfg.covariance.productClock.enable = true;
            end
            if ~isfield(cfg.covariance.productClock,'applyToCode')
                cfg.covariance.productClock.applyToCode = true;
            end
            if ~isfield(cfg.covariance.productClock,'applyToDoppler')
                cfg.covariance.productClock.applyToDoppler = true;
            end
            if ~isfield(cfg.covariance.productClock,'applyToCarrier')
                cfg.covariance.productClock.applyToCarrier = true;
            end
            if ~isfield(cfg.covariance.productClock,'crossCodeDoppler')
                cfg.covariance.productClock.crossCodeDoppler = false;
            end
            if ~isfield(cfg.covariance.productClock,'carrierPolicy')
                cfg.covariance.productClock.carrierPolicy = 'timeVaryingProductResidualOnly';
            end
            if ~isfield(cfg.covariance.productClock,'dopplerPolicy')
                cfg.covariance.productClock.dopplerPolicy = 'sharedClockDriftProductBlock';
            end
            if ~isfield(cfg.covariance.productClock,'temporalModel')
                cfg.covariance.productClock.temporalModel = 'perProductEpochBiasDriftV1';
            end
            if ~isfield(cfg.covariance.productClock,'ensureSPD')
                cfg.covariance.productClock.ensureSPD = true;
            end
            if ~isfield(cfg.covariance.productClock,'jitter_m2')
                cfg.covariance.productClock.jitter_m2 = 1e-12;
            end
            if ~isfield(cfg,'diagnostics'); cfg.diagnostics = struct(); end
            if ~isfield(cfg.diagnostics,'doppler'); cfg.diagnostics.doppler = struct(); end
            if ~isfield(cfg.diagnostics.doppler,'modelLevel')
                cfg.diagnostics.doppler.modelLevel = 'frameConsistentV2';
            end
            if ~isfield(cfg.diagnostics.doppler,'sagnacRateHandling')
                cfg.diagnostics.doppler.sagnacRateHandling = 'capturedByTowerVelocityTerm';
            end
            if ~isfield(cfg.diagnostics.doppler,'lightTimeRateHandling')
                cfg.diagnostics.doppler.lightTimeRateHandling = 'metadataOnlyV1';
            end
            if ~isfield(cfg.diagnostics.doppler,'dopplerLightTimeDerivative')
                cfg.diagnostics.doppler.dopplerLightTimeDerivative = 'simplifiedV1';
            end

            % Run model coverage audit and guard on missingUnsafe
            cfg.validation.modelCoverageAudit = revgnss.ModelCoverageAudit.run(cfg);
            if cfg.validation.modelCoverageAudit.nModelCategoriesMissingUnsafe > 0
                error('ConfigFactory:modelCoverageMissingUnsafe', ...
                    ['Model coverage audit: %d category/ies are missingUnsafe. ' ...
                     'Every category must be implementedSynthetic, disabledByConfig, or guardedNotImplemented. ' ...
                     'Missing: %s'], ...
                    cfg.validation.modelCoverageAudit.nModelCategoriesMissingUnsafe, ...
                    strjoin(cfg.validation.modelCoverageAudit.modelCoverageBlockingItems, ', '));
            end
        end

        function tmpl = getClockTemplate_(templateName)
            % getClockTemplate_  Return base h-coefficient struct for a clock type.
            %
            % h-values are one-sided PSD of fractional frequency.
            % References: IEEE Std 1139-2008; Sesia et al.; GPS ICD.

            switch upper(templateName)
                case 'TCXO'
                    % Temperature-compensated crystal oscillator (moderate stability)
                    % Typical for low-grade embedded receivers
                    tmpl.h2      = 0;
                    tmpl.h1      = 0;
                    tmpl.h0      = 9e-22;     % WFM  — tau^(-1/2) ADEV ~ 1e-10 at tau=1s
                    tmpl.hMinus1 = 2e-21;     % FFM  — floor ~ sqrt(2*ln2*hm1) ~ 2e-11
                    tmpl.hMinus2 = 1e-20;     % RWFM — rises at tau^(+1/2)

                case 'OCXO'
                    % Oven-controlled crystal oscillator (good stability)
                    % Typical for GPS control segment / reference stations
                    tmpl.h2      = 0;
                    tmpl.h1      = 0;
                    tmpl.h0      = 2e-25;     % WFM
                    tmpl.hMinus1 = 7e-27;     % FFM
                    tmpl.hMinus2 = 2e-29;     % RWFM

                case 'RUBIDIUM'
                    % Rubidium frequency standard (good medium-to-long term)
                    tmpl.h2      = 0;
                    tmpl.h1      = 0;
                    tmpl.h0      = 1e-22;     % WFM (worse than OCXO short-term)
                    tmpl.hMinus1 = 4.5e-24;   % FFM
                    tmpl.hMinus2 = 3e-28;     % RWFM (better long-term than OCXO)

                case 'ATOMICLIKE'
                    % Cesium beam / hydrogen maser class (excellent stability)
                    tmpl.h2      = 0;
                    tmpl.h1      = 0;
                    tmpl.h0      = 1e-26;
                    tmpl.hMinus1 = 1e-28;
                    tmpl.hMinus2 = 1e-30;

                case 'CUSTOM'
                    % All zeros; caller fills in values
                    tmpl.h2      = 0;
                    tmpl.h1      = 0;
                    tmpl.h0      = 0;
                    tmpl.hMinus1 = 0;
                    tmpl.hMinus2 = 0;

                otherwise
                    warning('ConfigFactory:unknownTemplate', ...
                        'Unknown clock template "%s"; defaulting to OCXO.', templateName);
                    tmpl = revgnss.ConfigFactory.getClockTemplate_('OCXO');
            end

            % Shared fields for all templates
            tmpl.bias_s   = 0.0;
            tmpl.fracFreq = 0.0;
            tmpl.driftRate_fracPerSec = 0.0;
        end

    end  % methods (Static)
end  % classdef

% ======================================================================
% File-scope helper to safely get a struct field with a default value
% ======================================================================
function v = getf_(s, fname, default)
    if isfield(s, fname)
        v = s.(fname);
    else
        v = default;
    end
end
