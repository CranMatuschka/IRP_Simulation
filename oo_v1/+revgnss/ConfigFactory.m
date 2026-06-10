classdef ConfigFactory
    % ConfigFactory  Builds default simulation configuration structs.
    %
    % All experiments start from defaultConfig() and override specific fields.
    %
    % Usage:
    %   cfg = revgnss.ConfigFactory.defaultConfig();
    %   cfg.errors.codeNoise.sigma_m = 5.0;
    %   sim = revgnss.ReverseGNSSSimulation(cfg);

    methods (Static)

        function cfg = defaultConfig()
            % defaultConfig  Full default configuration for reverse-GNSS simulation.

            % --- Simulation timing --------------------------------------
            cfg.simulation.dt_s       = 1.0;     % epoch interval [s]
            cfg.simulation.duration_s = 300.0;   % total simulation time [s]
            cfg.simulation.seed       = 42;

            % --- Asset (space vehicle) ----------------------------------
            % Initial position: LEO at ~500 km, 0 deg lat, 0 deg lon (ECEF approx)
            Re  = revgnss.Constants.EARTH_RADIUS_M;
            alt = 500e3;
            a   = Re + alt;
            v_circ = sqrt(revgnss.Constants.EARTH_GM_M3PS2 / a);

            cfg.asset.name                    = 'LEO_Asset';
            cfg.asset.mass_kg                 = 150;
            cfg.asset.r_ecef_m                = [a; 0; 0];
            cfg.asset.v_ecef_mps              = [0; v_circ * cos(0); v_circ * sin(51.6*pi/180)];
            cfg.asset.attitude_euler_rad      = [0; 0; 0];
            cfg.asset.angularRate_body_radps  = [0; 0; 1e-3];
            cfg.asset.receiverLeverArm_body_m = [1.0; 0.5; 0.2];

            % Asset receiver clock: OCXO-like
            cfg.asset.clock.name      = 'RxOCXO';
            cfg.asset.clock.clockType = 'OCXO';
            cfg.asset.clock.noiseCoeffs.h2       = 0;
            cfg.asset.clock.noiseCoeffs.h1       = 0;
            cfg.asset.clock.noiseCoeffs.h0       = 2e-25;
            cfg.asset.clock.noiseCoeffs.hMinus1  = 7e-27;
            cfg.asset.clock.noiseCoeffs.hMinus2  = 2e-29;
            cfg.asset.clock.deterministic = false;
            cfg.asset.clock.seed          = 100;
            cfg.asset.clock.bias_s        = 1e-6;
            cfg.asset.clock.fracFreq      = 1e-11;

            % --- Orbit propagator --------------------------------------
            cfg.orbit.altitudeMean_m   = alt;
            cfg.orbit.inclination_rad  = 51.6 * pi/180;
            cfg.orbit.raan_rad         = 0;
            cfg.orbit.trueAnomaly0_rad = 0;
            cfg.orbit.epochGMST_rad    = 0;
            cfg.orbit.useOrbitPropagator = true;

            % --- Ground towers (8 towers) -------------------------------
            % Placed at roughly evenly distributed latitudes/longitudes
            towerLats = [51.5, 48.8, 40.7, 35.7, -33.9, 28.6, 55.8, 1.3] * pi/180;
            towerLons = [-0.1, 2.3, -74.0, 139.7, 151.2, 77.2, 37.6, 103.8] * pi/180;
            towerAlts = [50, 120, 10, 40, 30, 220, 190, 15];  % [m]

            cfg.towers = struct();
            for k = 1:8
                cfg.towers(k).id                 = k;
                cfg.towers(k).name               = sprintf('Tower_%d', k);
                cfg.towers(k).lat_rad            = towerLats(k);
                cfg.towers(k).lon_rad            = towerLons(k);
                cfg.towers(k).alt_m              = towerAlts(k);
                cfg.towers(k).antennaOffset_enu_m= [0;0;5];  % 5 m above ground ref
                cfg.towers(k).hardwareDelay_m    = 0.05 * k; % [m] nominal

                % Tower clock: all OCXO for default
                cfg.towers(k).clock.name         = sprintf('Tower%d_OCXO', k);
                cfg.towers(k).clock.clockType    = 'OCXO';
                cfg.towers(k).clock.noiseCoeffs.h2      = 0;
                cfg.towers(k).clock.noiseCoeffs.h1      = 0;
                cfg.towers(k).clock.noiseCoeffs.h0      = 1e-24;
                cfg.towers(k).clock.noiseCoeffs.hMinus1 = 1e-26;
                cfg.towers(k).clock.noiseCoeffs.hMinus2 = 1e-28;
                cfg.towers(k).clock.deterministic= false;
                cfg.towers(k).clock.seed         = 200 + k;
                cfg.towers(k).clock.bias_s       = (k-1)*1e-8;
                cfg.towers(k).clock.fracFreq     = k * 1e-12;
            end

            % --- Estimator ---------------------------------------------
            cfg.estimator.estimateTowerClocks    = false;
            cfg.estimator.elevationMask_rad      = 5 * pi/180;
            cfg.estimator.attitudeJacobianStep_rad = 1e-6;
            cfg.estimator.sigma_accel_mps2       = 0.5;
            cfg.estimator.sigma_angAccel_radps2  = 1e-3;
            cfg.estimator.towerClockMode         = 'none';  % none|perfectCorrection|noisyCorrection|estimatedState

            % Initial covariance (1-sigma)
            cfg.estimator.P0_pos_m          = 1000;   % [m]
            cfg.estimator.P0_vel_mps        = 10;     % [m/s]
            cfg.estimator.P0_euler_rad      = 0.1;    % [rad] ~ 6 deg
            cfg.estimator.P0_omega_radps    = 0.01;
            cfg.estimator.P0_bRx_m          = 3e5;    % ~ 1 ms clock bias in meters
            cfg.estimator.P0_bdotRx_mps     = 3e1;    % ~ 0.1 us/s in m/s

            % --- Error sources -----------------------------------------
            % Code noise
            cfg.errors.codeNoise.sigma_m = 1.0;  % [m]

            % Troposphere
            cfg.errors.troposphere.truth.enable       = true;
            cfg.errors.troposphere.truth.zenithDelay_m= 2.3;
            cfg.errors.troposphere.model.enable       = true;
            cfg.errors.troposphere.model.zenithDelay_m= 2.3;
            cfg.errors.troposphere.model.biasFraction = 1.0;
            cfg.errors.troposphere.sigma_m            = 0.1;

            % Ionosphere
            cfg.errors.ionosphere.truth.enable        = true;
            cfg.errors.ionosphere.truth.zenithDelay_m = 5.0;
            cfg.errors.ionosphere.model.enable        = true;
            cfg.errors.ionosphere.model.zenithDelay_m = 5.0;
            cfg.errors.ionosphere.model.biasFraction  = 1.0;
            cfg.errors.ionosphere.sigma_m             = 0.5;

            % Hardware delay
            cfg.errors.hardwareDelay.truth.enable     = true;
            cfg.errors.hardwareDelay.truth.default_m  = 0.05;
            cfg.errors.hardwareDelay.model.enable     = true;
            cfg.errors.hardwareDelay.model.default_m  = 0.05;

            % Multipath
            cfg.errors.multipath.truth.enable           = false;
            cfg.errors.multipath.truth.amplitude_m      = 0.3;
            cfg.errors.multipath.truth.frequency_radps  = 0.01;
            cfg.errors.multipath.truth.stochastic_sigma_m = 0.1;
            cfg.errors.multipath.sigma_m                = 0.0;

            % --- Plots -------------------------------------------------
            cfg.plots.enable      = true;
            cfg.plots.saveFigures = false;
            cfg.plots.outputDir   = fullfile(fileparts(mfilename('fullpath')), ...
                '..', '..', 'output', 'figures');
        end

        % ----------------------------------------------------------------
        function cfg = idealConfig()
            % idealConfig  Experiment A: no noise, no errors, nonzero lever arm.
            cfg = revgnss.ConfigFactory.defaultConfig();

            cfg.errors.codeNoise.sigma_m              = 0;
            cfg.errors.troposphere.truth.enable       = false;
            cfg.errors.troposphere.model.enable       = false;
            cfg.errors.ionosphere.truth.enable        = false;
            cfg.errors.ionosphere.model.enable        = false;
            cfg.errors.hardwareDelay.truth.enable     = false;
            cfg.errors.hardwareDelay.model.enable     = false;
            cfg.errors.multipath.truth.enable         = false;

            % Deterministic clocks (no noise)
            cfg.asset.clock.deterministic  = true;
            cfg.asset.clock.bias_s         = 0;
            cfg.asset.clock.fracFreq       = 0;
            for k = 1:numel(cfg.towers)
                cfg.towers(k).clock.deterministic = true;
                cfg.towers(k).clock.bias_s        = 0;
                cfg.towers(k).clock.fracFreq      = 0;
            end

            cfg.estimator.towerClockMode = 'perfectCorrection';
        end

        % ----------------------------------------------------------------
        function cfg = noLeverArmConfig()
            % noLeverArmConfig  Zero receiver lever arm for observability test.
            cfg = revgnss.ConfigFactory.idealConfig();
            cfg.asset.receiverLeverArm_body_m = [0;0;0];
        end
    end
end
