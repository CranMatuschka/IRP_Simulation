classdef ConfigFactory
    % ConfigFactory  Builds simulation configuration structs.
    %
    % The default scenario is a GEO-1 satellite at lat 0, lon 23 deg, alt 35786 km,
    % with five ground towers matching the original SimulationConfig.m layout.
    % All error sources are disabled by default for clean EKF convergence validation.
    %
    % Usage:
    %   cfg = revgnss.ConfigFactory.defaultConfig();
    %   sim = revgnss.ReverseGNSSSimulation(cfg);

    methods (Static)

        function cfg = defaultConfig()
            % defaultConfig  GEO-1 reverse-GNSS convergence test (all errors off).
            %
            % Space asset: GEO-1 at lat 0 deg, lon 23 deg, alt 35786000 m.
            % Towers: Tenerife, Stockholm, Hartebeesthoek, Bengaluru, Libreville.
            % Clock: deterministic, zero truth bias. EKF starts 100 m off.
            % Atmosphere: disabled. Hardware delay: disabled. Multipath: disabled.

            % --- Simulation timing ----------------------------------------
            cfg.simulation.dt_s       = 1.0;
            cfg.simulation.duration_s = 3600.0;
            cfg.simulation.seed       = 42;

            % --- GEO asset (stationary in ECEF) ---------------------------
            geoLat_rad = 0.0;
            geoLon_rad = 23.0 * pi / 180;
            geoAlt_m   = 35786000.0;
            r_geo = revgnss.GeometryUtils.geodetic2ecef(geoLat_rad, geoLon_rad, geoAlt_m);

            cfg.asset.name                    = 'GEO-1';
            cfg.asset.mass_kg                 = 2000;
            cfg.asset.r_ecef_m                = r_geo;
            cfg.asset.v_ecef_mps              = [0; 0; 0];   % geostationary in ECEF
            cfg.asset.attitude_euler_rad      = [0; 0; 0];
            cfg.asset.angularRate_body_radps  = [0; 0; 0];
            cfg.asset.receiverLeverArm_body_m = [1.0; 0.5; 0.2];

            % Asset receiver clock: deterministic, zero initial bias
            cfg.asset.clock.name      = 'RxClock';
            cfg.asset.clock.clockType = 'OCXO';
            cfg.asset.clock.noiseCoeffs.h2       = 0;
            cfg.asset.clock.noiseCoeffs.h1       = 0;
            cfg.asset.clock.noiseCoeffs.h0       = 2e-25;
            cfg.asset.clock.noiseCoeffs.hMinus1  = 7e-27;
            cfg.asset.clock.noiseCoeffs.hMinus2  = 2e-29;
            cfg.asset.clock.deterministic = true;
            cfg.asset.clock.seed          = 100;
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

            cfg.towers = struct();
            for k = 1:5
                cfg.towers(k).id                  = k;
                cfg.towers(k).name                = towerDefs{k,1};
                cfg.towers(k).lat_rad             = towerDefs{k,2} * pi/180;
                cfg.towers(k).lon_rad             = towerDefs{k,3} * pi/180;
                cfg.towers(k).alt_m               = towerDefs{k,4};
                cfg.towers(k).antennaOffset_enu_m = [0; 0; 0];
                cfg.towers(k).hardwareDelay_m     = 0.0;

                % Tower clock: deterministic, zero bias for convergence test
                cfg.towers(k).clock.name         = sprintf('%s_Clock', towerDefs{k,1});
                cfg.towers(k).clock.clockType    = 'OCXO';
                cfg.towers(k).clock.noiseCoeffs.h2      = 0;
                cfg.towers(k).clock.noiseCoeffs.h1      = 0;
                cfg.towers(k).clock.noiseCoeffs.h0      = 1e-24;
                cfg.towers(k).clock.noiseCoeffs.hMinus1 = 1e-26;
                cfg.towers(k).clock.noiseCoeffs.hMinus2 = 1e-28;
                cfg.towers(k).clock.deterministic = true;
                cfg.towers(k).clock.seed          = 200 + k;
                cfg.towers(k).clock.bias_s        = 0.0;
                cfg.towers(k).clock.fracFreq      = 0.0;
            end

            % --- Estimator ------------------------------------------------
            cfg.estimator.estimateTowerClocks      = false;
            % perfectCorrection: EKF uses known tower clock values (zero here).
            cfg.estimator.towerClockMode           = 'perfectCorrection';
            cfg.estimator.elevationMask_rad        = 5 * pi/180;
            cfg.estimator.attitudeJacobianStep_rad = 1e-6;
            cfg.estimator.sigma_accel_mps2         = 0.01;   % low for GEO (slow dynamics)
            cfg.estimator.sigma_angAccel_radps2    = 1e-5;
            cfg.estimator.minMeasurementsForUpdate = 4;

            % Initial covariance (1-sigma diagonal)
            cfg.estimator.P0_pos_m       = 1000.0;   % [m]
            cfg.estimator.P0_vel_mps     = 1.0;      % [m/s]
            cfg.estimator.P0_euler_rad   = 0.01;     % [rad] ~ 0.6 deg
            cfg.estimator.P0_omega_radps = 1e-4;
            cfg.estimator.P0_bRx_m       = 100.0;    % [m] — NOT 300 km
            cfg.estimator.P0_bdotRx_mps  = 0.01;

            % Controlled initial errors (fixed offsets, not random draws).
            % These replace the previous random P0-scaled perturbations.
            cfg.estimator.initialError.pos_m          = [1000; -500; 250];
            cfg.estimator.initialError.vel_mps        = [0.1; -0.1; 0.05];
            cfg.estimator.initialError.euler_deg      = [0.5; -0.3; 0.2];
            cfg.estimator.initialError.omega_radps    = [0; 0; 0];
            cfg.estimator.initialError.clockBias_m    = 100.0;
            cfg.estimator.initialError.clockDrift_mps = 0.01;

            % --- Measurement noise floor ----------------------------------
            cfg.measurement.sigmaFloor_m = 1e-3;   % prevents R = 0 in ideal mode

            % --- Error sources: disabled by default for convergence test --
            cfg.errors.codeNoise.sigma_m = 0.3;    % [m] small but nonzero

            % Troposphere off by default
            cfg.errors.troposphere.truth.enable        = false;
            cfg.errors.troposphere.truth.zenithDelay_m = 2.3;
            cfg.errors.troposphere.model.enable        = false;
            cfg.errors.troposphere.model.zenithDelay_m = 2.3;
            cfg.errors.troposphere.model.biasFraction  = 1.0;
            cfg.errors.troposphere.sigma_m             = 0.0;

            % Ionosphere off by default
            cfg.errors.ionosphere.truth.enable         = false;
            cfg.errors.ionosphere.truth.zenithDelay_m  = 5.0;
            cfg.errors.ionosphere.model.enable         = false;
            cfg.errors.ionosphere.model.zenithDelay_m  = 5.0;
            cfg.errors.ionosphere.model.biasFraction   = 1.0;
            cfg.errors.ionosphere.sigma_m              = 0.0;

            % Hardware delay off by default
            cfg.errors.hardwareDelay.truth.enable      = false;
            cfg.errors.hardwareDelay.truth.default_m   = 0.0;
            cfg.errors.hardwareDelay.model.enable      = false;
            cfg.errors.hardwareDelay.model.default_m   = 0.0;

            % Multipath off by default
            cfg.errors.multipath.truth.enable              = false;
            cfg.errors.multipath.truth.amplitude_m         = 0.3;
            cfg.errors.multipath.truth.frequency_radps     = 0.01;
            cfg.errors.multipath.truth.stochastic_sigma_m  = 0.1;
            cfg.errors.multipath.sigma_m                   = 0.0;

            % --- Plots ----------------------------------------------------
            cfg.plots.enable      = true;
            cfg.plots.saveFigures = false;
            cfg.plots.outputDir   = fullfile(fileparts(mfilename('fullpath')), ...
                '..', 'output', 'figures');

            % --- Report ---------------------------------------------------
            cfg.report.enable              = true;
            cfg.report.outputPdf           = fullfile(fileparts(mfilename('fullpath')), ...
                '..', 'output', 'reverse_gnss_simple_report.pdf');
            cfg.report.includeTimestampedCopy = false;
        end

        % ------------------------------------------------------------------
        function cfg = idealConfig()
            % idealConfig  Zero code noise, all errors off, deterministic clocks.
            cfg = revgnss.ConfigFactory.defaultConfig();
            cfg.errors.codeNoise.sigma_m = 0;
        end

        % ------------------------------------------------------------------
        function cfg = noLeverArmConfig()
            % noLeverArmConfig  Zero lever arm — attitude unobservable from pseudorange.
            cfg = revgnss.ConfigFactory.idealConfig();
            cfg.asset.receiverLeverArm_body_m = [0; 0; 0];
        end

        % ------------------------------------------------------------------
        function cfg = clockNoiseConfig()
            % clockNoiseConfig  Enable receiver and tower clock noise.
            cfg = revgnss.ConfigFactory.defaultConfig();

            cfg.asset.clock.deterministic = false;
            cfg.asset.clock.bias_s        = 1e-6;
            cfg.asset.clock.fracFreq      = 1e-11;

            for k = 1:numel(cfg.towers)
                cfg.towers(k).clock.deterministic = false;
                cfg.towers(k).clock.bias_s        = (k - 1) * 1e-8;
                cfg.towers(k).clock.fracFreq      = k * 1e-12;
            end
            % noisyCorrection: apply known bias + small random noise
            cfg.estimator.towerClockMode = 'noisyCorrection';
        end

        % ------------------------------------------------------------------
        function cfg = atmosphereConfig()
            % atmosphereConfig  Enable troposphere and ionosphere delays.
            cfg = revgnss.ConfigFactory.defaultConfig();

            cfg.errors.troposphere.truth.enable  = true;
            cfg.errors.troposphere.model.enable  = true;
            cfg.errors.troposphere.sigma_m       = 0.1;

            cfg.errors.ionosphere.truth.enable   = true;
            cfg.errors.ionosphere.model.enable   = true;
            cfg.errors.ionosphere.sigma_m        = 0.3;
        end

        % ------------------------------------------------------------------
        function cfg = uncorrectedTowerClocksConfig()
            % uncorrectedTowerClocksConfig  Tower clocks not corrected (mode = 'none').
            cfg = revgnss.ConfigFactory.clockNoiseConfig();
            cfg.estimator.towerClockMode = 'none';
        end
    end
end
