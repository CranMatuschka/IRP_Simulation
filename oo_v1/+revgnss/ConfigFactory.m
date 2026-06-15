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
    % SUPPORTED OBSERVABLES (Stage 7A)
    %   Code pseudorange (single-frequency or IF L1/L2 combination)
    %   Simplified Doppler
    %   Raw L1 float carrier EKF (no L2 carrier, no IF carrier, no integer fixing)
    %   ZWD per-tower EKF state
    %   Tower-clock product structs (explicit or truth-history)
    %   PCV: none / toy (elevation only) / table (elevation-only, no azimuth)
    %   Ionosphere mapping: simpleSecant (1/sin) or thinShell
    %   Thin-shell mapping: M(e)=1/sqrt(1-(Re*cos(e)/(Re+hI))^2); NOT Klobuchar
    %
    % NOT SUPPORTED (Stage 7A)
    %   L2 carrier EKF | carrier IF | integer ambiguity resolution
    %   Azimuth-dependent PCV | ANTEX parser | IONEX | SP3/CLK | RINEX
    %   VMF3 / GPT3 / ERA5 | Klobuchar ionosphere model
    %   PPP-grade or mm-level accuracy claims
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

            % --- No orbit propagator for GEO (stationary in ECEF) --------
            cfg.orbit.useOrbitPropagator = false;

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
            % perfectCorrection: EKF uses known tower clock values (zero here).
            cfg.estimator.towerClockMode          = 'perfectCorrection';
            cfg.estimator.towerClockCorrectionSigma_m = 0.5; % used if noisyCorrection
            cfg.estimator.elevationMask_rad       = 5 * pi/180;
            cfg.estimator.attitudeJacobianStep_rad = 1e-6;
            cfg.estimator.sigma_accel_mps2        = 0.01;
            % Near-zero angular-acceleration noise: attitude stays frozen at truth.
            cfg.estimator.sigma_angAccel_radps2   = 1e-15;
            cfg.estimator.minMeasurementsForUpdate = 4;

            % Initial covariance (1-sigma diagonal)
            cfg.estimator.P0_pos_m        = 1000.0;
            cfg.estimator.P0_vel_mps      = 1.0;
            % Near-zero attitude uncertainty: EKF treats attitude as known.
            cfg.estimator.P0_euler_rad    = 1e-12;
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
            cfg.signals.enabled = {'L1'};
            cfg.signals.twoFrequency.enable = false;
            cfg.signals.L1.name          = 'L1';
            cfg.signals.L1.frequency_Hz  = 1575.42e6;
            cfg.signals.L1.lambda_m      = 299792458 / 1575.42e6;
            cfg.signals.L1.codeSigma0_m  = 0.30;
            cfg.signals.L2.name          = 'L2';
            cfg.signals.L2.frequency_Hz  = 1227.60e6;
            cfg.signals.L2.lambda_m      = 299792458 / 1227.60e6;
            cfg.signals.L2.codeSigma0_m  = 0.45;

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

            % --- Physics constants and range-correction toggles ---------------
            % All physics corrections default to false. Enable in realisticPseudorangeConfig.
            cfg.physics.c_mps              = 299792458;
            cfg.physics.omegaEarth_radps   = 7.2921151467e-5;
            cfg.physics.muEarth_m3ps2      = 3.986004418e14;

            cfg.physics.sagnac.truth.enable    = true;
            cfg.physics.sagnac.model.enable    = true;

            cfg.physics.lightTime.truth.enable = false;
            cfg.physics.lightTime.model.enable = false;
            cfg.physics.lightTime.maxIter      = 2;

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
            cfg.measurements.carrierPhase.frequency_Hz     = 1575.42e6;
            cfg.measurements.carrierPhase.lambda_m         = 299792458 / 1575.42e6;
            cfg.measurements.carrierPhase.sigma_cycles     = 0.01;
            cfg.measurements.carrierPhase.initialAmbiguityMode = 'randomInteger';
            cfg.measurements.carrierPhase.seed             = 9001;
            cfg.measurements.carrierPhase.cycleSlip.enable = true;

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
            % 'toy' preserves existing toyAzEl behavior.
            % 'table' uses receiverPcvTable (elevation-only or el+az).
            cfg.effects.antenna.pcvModel                     = 'toy';
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

            % --- Observability diagnostics (Step 8) -------------------------
            cfg.diagnostics.observability.enabled       = false;
            cfg.diagnostics.observability.warn          = true;
            cfg.diagnostics.observability.rankTolerance = [];

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
            cfg.signals.twoFrequency.enable      = true;
            cfg.measurements.codeMode            = 'ionosphereFree';
            cfg.measurements.observableMode      = 'code+doppler';
            cfg.errors.ionosphere.truth.enable   = true;
            cfg.errors.ionosphere.model.enable   = true;
        end

        function cfg = carrierFloatConfig()
            % carrierFloatConfig  Carrier phase EKF with float ambiguity states.
            %
            % ambiguityMode='floatPerTowerSignal': one float ambiguity per tower/signal.
            % No integer fixing. Ambiguities converge over time absorbing phase offsets.
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
            %   sigmaDrift_mps — 1-sigma drift uncertainty [m/s]
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
            %   'truthProduct' | 'product' | 'productNoisy'
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
                        % History-based + Gaussian noise added to R.
                        cfg.estimator.towerClockMode = 'noisyCorrection';
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

            % ---- Unsupported: light-time ----------------------------------
            % Full light-time not implemented. Map to first-order Sagnac or error.
            if isfield(cfg,'physics') && isfield(cfg.physics,'lightTime')
                lt = cfg.physics.lightTime;
                ltTruth = isfield(lt,'truth') && isfield(lt.truth,'enable') && lt.truth.enable;
                ltModel = isfield(lt,'model') && isfield(lt.model,'enable') && lt.model.enable;
                if ltTruth || ltModel
                    if strcmp(policy,'error')
                        error('ConfigFactory:lightTimeNotSupported', ...
                            ['Full light-time correction is not implemented in v1. ' ...
                             'Set unsupportedFeaturePolicy=''disableWithWarning'' to map to Sagnac.']);
                    end
                    parts = {'Full light-time not implemented in v1.'};
                    if ltTruth
                        sOn = isfield(cfg.physics,'sagnac') && isfield(cfg.physics.sagnac,'truth') && ...
                              isfield(cfg.physics.sagnac.truth,'enable') && cfg.physics.sagnac.truth.enable;
                        if ~sOn
                            cfg.physics.sagnac.truth.enable    = true;
                            parts{end+1}                       = 'lightTime.truth mapped to sagnac.truth.';
                            cfg.validation.mappedFeatures{end+1} = 'lightTime.truth -> sagnac.truth';
                        else
                            parts{end+1} = 'lightTime.truth: sagnac.truth already enabled; lightTime disabled.';
                        end
                        cfg.physics.lightTime.truth.enable = false;
                    end
                    if ltModel
                        sOn = isfield(cfg.physics,'sagnac') && isfield(cfg.physics.sagnac,'model') && ...
                              isfield(cfg.physics.sagnac.model,'enable') && cfg.physics.sagnac.model.enable;
                        if ~sOn
                            cfg.physics.sagnac.model.enable    = true;
                            parts{end+1}                       = 'lightTime.model mapped to sagnac.model.';
                            cfg.validation.mappedFeatures{end+1} = 'lightTime.model -> sagnac.model';
                        else
                            parts{end+1} = 'lightTime.model: sagnac.model already enabled; lightTime disabled.';
                        end
                        cfg.physics.lightTime.model.enable = false;
                    end
                    warnMsg = strjoin(parts, ' ');
                    cfg.validation.warnings{end+1} = warnMsg;
                    warning('ConfigFactory:lightTimeMapped', '%s', warnMsg);
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
                        % Require ambiguityMode='floatPerTowerSignal'
                        ambMode = '';
                        if isfield(cfg,'estimation') && isfield(cfg.estimation,'ambiguityMode')
                            ambMode = cfg.estimation.ambiguityMode;
                        end
                        if ~strcmp(ambMode,'floatPerTowerSignal')
                            error('ConfigFactory:carrierEKFRequiresAmbiguities', ...
                                ['carrierMode=''ekfFloat'' requires ' ...
                                 'cfg.estimation.ambiguityMode=''floatPerTowerSignal''. ' ...
                                 'Set ambiguityMode appropriately.']);
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

            % ---- twoFrequency early apply (must run before codeMode validation) ----
            if isfield(cfg,'signals') && isfield(cfg.signals,'twoFrequency') && ...
                    isfield(cfg.signals.twoFrequency,'enable')
                if cfg.signals.twoFrequency.enable
                    cfg.signals.enabled = {'L1','L2'};
                else
                    cfg.signals.enabled = {'L1'};
                end
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
                                'codeMode=''ionosphereFree'' requires L1 and L2 signals. Enable cfg.signals.twoFrequency.enable=true.');
                        end
                    case {'singleFrequency','dualFrequencyStacked'}
                        % OK
                    otherwise
                        error('ConfigFactory:invalidCodeMode', ...
                            'cfg.measurements.codeMode must be ''singleFrequency'', ''dualFrequencyStacked'', or ''ionosphereFree''; got ''%s''.', codeMode);
                end
            end

            % ---- Task 4D/4E: carrier ekfFloat v1 restrictions -----------
            % Runs AFTER twoFrequency apply so cfg.signals.enabled is final.
            if isfield(cfg,'measurements') && isfield(cfg.measurements,'carrierMode') && ...
                    strcmp(cfg.measurements.carrierMode,'ekfFloat')

                % Task 4D: ekfFloat uses L1 only (sigIdx=1 in computeCarrierEkfRows_)
                sigEnabled = {};
                if isfield(cfg,'signals') && isfield(cfg.signals,'enabled')
                    sigEnabled = cfg.signals.enabled;
                end
                if numel(sigEnabled) > 1
                    warnMsg4D = ['ekfFloat carrier mode adds L1 rows only in v1 ' ...
                                 '(computeCarrierEkfRows_ uses sigIdx=1). ' ...
                                 'L2 carrier EKF rows are NOT added. ' ...
                                 'For dual-frequency iono removal use codeMode=''ionosphereFree''.'];
                    cfg.validation.warnings{end+1} = warnMsg4D;
                    warning('ConfigFactory:carrierEKFSingleFreqOnly', '%s', warnMsg4D);
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
            %                nReceivers >1 → estimateAttitude/FromPseudorange true.
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
                cfg.estimator.estimateAngularRate                = true;
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
