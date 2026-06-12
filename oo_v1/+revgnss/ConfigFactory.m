classdef ConfigFactory
    % ConfigFactory  Builds simulation configuration structs.
    %
    % Default scenario: GEO-1 at lat 0, lon 23 deg, alt 35 786 km with five
    % ground towers from the original SimulationConfig.m layout.  All error
    % sources are disabled by default for clean EKF convergence validation.
    %
    % Clock templates available (see clockTemplates sub-struct):
    %   TCXO        Temperature-compensated crystal oscillator (moderate)
    %   OCXO        Oven-controlled crystal oscillator (good)
    %   Rubidium    Rubidium frequency standard (medium-long term)
    %   AtomicLike  Cesium / H-maser class (excellent)
    %   Custom      User-filled coefficients
    %
    % Factory configs:
    %   defaultConfig()              GEO-1, deterministic clocks, all errors off
    %   idealConfig()                Same but code noise = 0
    %   noLeverArmConfig()           Zero lever arm (attitude unobservable)
    %   positionClockOnlyConfig()    Attitude/omega frozen, zero lever arm
    %   multiAntennaAttitudeConfig() 4-antenna cross; attitude observable
    %   clockNoiseConfig()           Stochastic clocks + noisyCorrection mode
    %   atmosphereConfig()           Trop + iono enabled
    %   uncorrectedTowerClocksConfig()  Stochastic, no correction
    %   clockDiversityConfig()       Each tower uses a different clock type
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
            % defaultConfig  GEO-1 convergence test, deterministic clocks, all errors off.

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
            cfg.estimator.estimateAttitudeFromPseudorange     = true;
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

            % --- Observable toggles: pseudorange always on, others off ------
            % Doppler and carrier phase are off by default; explicit cases enable them.
            % doppler.useInEKF=true requires physics.doppler.model.enable=true.
            % carrierPhase.useInEKF=true requires estimateCarrierAmbiguities=true.
            cfg.measurements.pseudorange.enable   = true;
            cfg.measurements.doppler.enable       = true;
            cfg.measurements.doppler.sigma_mps    = 0.01;
            cfg.measurements.doppler.useInEKF     = true;

            cfg.measurements.carrierPhase.enable           = true;
            cfg.measurements.carrierPhase.useInEKF         = true;
            cfg.measurements.carrierPhase.frequency_Hz     = 1575.42e6;
            cfg.measurements.carrierPhase.lambda_m         = 299792458 / 1575.42e6;
            cfg.measurements.carrierPhase.sigma_cycles     = 0.01;
            cfg.measurements.carrierPhase.initialAmbiguityMode = 'randomInteger';
            cfg.measurements.carrierPhase.seed             = 9001;
            cfg.measurements.carrierPhase.cycleSlip.enable = true;

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

            % --- Validation policy ----------------------------------------
            cfg.validation.unsupportedFeaturePolicy = 'disableWithWarning';
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
            %
            % With both truth and model enabled, corrections mostly cancel in the
            % innovation. To see the deterministic bias, set model.enable=false.
            %
            % Light-time iteration is NOT implemented in v1. Sagnac is applied as
            % the first-order Earth-rotation correction. Do not enable lightTime
            % until an ECI/transmit-time model exists.
            cfg = revgnss.ConfigFactory.defaultConfig();
            cfg.physics.sagnac.truth.enable           = true;
            cfg.physics.sagnac.model.enable           = true;
            cfg.physics.lightTime.truth.enable        = false;   % not implemented in v1
            cfg.physics.lightTime.model.enable        = false;   % not implemented in v1
            cfg.physics.relativity.shapiro.truth.enable = true;
            cfg.physics.relativity.shapiro.model.enable = true;
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
                cfg.validation.unsupportedFeaturePolicy = 'disableWithWarning';
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
            % cfg.errors.towerClockCorrection.mode → cfg.estimator.towerClockMode
            if isfield(cfg,'errors') && isfield(cfg.errors,'towerClockCorrection') && ...
                    isfield(cfg.errors.towerClockCorrection,'mode')
                cfg.estimator.towerClockMode = cfg.errors.towerClockCorrection.mode;
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

            % ---- Unsupported: carrier phase useInEKF ----------------------
            if isfield(cfg,'measurements') && isfield(cfg.measurements,'carrierPhase') && ...
                    isfield(cfg.measurements.carrierPhase,'useInEKF') && ...
                    cfg.measurements.carrierPhase.useInEKF
                warnMsg = 'Carrier phase EKF use requires ambiguity states not implemented in v1. carrierPhase.useInEKF disabled (diagnostic mode kept if enable=true).';
                if strcmp(policy,'error')
                    error('ConfigFactory:carrierEKFNotSupported', '%s', warnMsg);
                end
                cfg.measurements.carrierPhase.useInEKF = false;
                cfg.validation.warnings{end+1}         = warnMsg;
                cfg.validation.disabledFeatures{end+1} = 'carrierPhase.useInEKF';
                warning('ConfigFactory:carrierEKFDisabled', '%s', warnMsg);
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
                    if strcmp(policy,'error')
                        error('ConfigFactory:dopplerEKFInvalid', '%s', warnMsg);
                    end
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

            % ---- twoFrequency toggle: always overrides signals.enabled ----
            % false → {'L1'} only;  true → {'L1','L2'}.
            % All callers that want L1+L2 must set twoFrequency.enable=true.
            if isfield(cfg,'signals') && isfield(cfg.signals,'twoFrequency') && ...
                    isfield(cfg.signals.twoFrequency,'enable')
                if cfg.signals.twoFrequency.enable
                    cfg.signals.enabled = {'L1','L2'};
                else
                    cfg.signals.enabled = {'L1'};
                end
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
