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
    %   defaultConfig()          GEO-1, deterministic clocks, all errors off
    %   idealConfig()            Same but code noise = 0
    %   noLeverArmConfig()       Zero lever arm (attitude unobservable)
    %   positionClockOnlyConfig()  Attitude/omega frozen, zero lever arm
    %   clockNoiseConfig()       Stochastic clocks + noisyCorrection mode
    %   atmosphereConfig()       Trop + iono enabled
    %   uncorrectedTowerClocksConfig()  Stochastic, no correction
    %   clockDiversityConfig()   Each tower uses a different clock type
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

            % --- GEO asset (stationary in ECEF) ---------------------------
            geoLat_rad = 0.0;
            geoLon_rad = 23.0 * pi / 180;
            geoAlt_m   = 35786000.0;
            r_geo      = revgnss.GeometryUtils.geodetic2ecef(geoLat_rad, geoLon_rad, geoAlt_m);

            cfg.asset.name                    = 'GEO-1';
            cfg.asset.mass_kg                 = 2000;
            cfg.asset.r_ecef_m                = r_geo;
            cfg.asset.v_ecef_mps              = [0; 0; 0];   % geostationary in ECEF
            cfg.asset.attitude_euler_rad      = [0; 0; 0];
            cfg.asset.angularRate_body_radps  = [0; 0; 0];
            cfg.asset.receiverLeverArm_body_m = [1.0; 0.5; 0.2];

            % Clock scaling factors (applied by makeClockConfig)
            cfg.clockScaling.globalBiasFactor    = 1.0;
            cfg.clockScaling.globalFreqFactor    = 1.0;
            cfg.clockScaling.globalNoiseFactor   = 1.0;
            cfg.clockScaling.receiverNoiseFactor = 1.0;
            cfg.clockScaling.towerNoiseFactor    = 1.0;

            % Asset receiver clock: OCXO, deterministic for convergence test
            cfg.asset.clock = revgnss.ConfigFactory.makeClockConfig( ...
                'OCXO', 100, struct(), cfg.clockScaling);
            cfg.asset.clock.name         = 'RxClock';
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

            cfg.towers = struct();
            for k = 1:5
                cfg.towers(k).id                  = k;
                cfg.towers(k).name                = towerDefs{k,1};
                cfg.towers(k).lat_rad             = towerDefs{k,2} * pi/180;
                cfg.towers(k).lon_rad             = towerDefs{k,3} * pi/180;
                cfg.towers(k).alt_m               = towerDefs{k,4};
                cfg.towers(k).antennaOffset_enu_m = [0; 0; 0];
                cfg.towers(k).hardwareDelay_m     = 0.0;

                % Per-tower clock template tag (informational)
                cfg.towers(k).clockTemplate = 'OCXO';
                cfg.towers(k).clockFactors  = struct();

                % Tower clock: OCXO, deterministic for convergence test
                cfg.towers(k).clock = revgnss.ConfigFactory.makeClockConfig( ...
                    'OCXO', 200 + k, struct(), cfg.clockScaling);
                cfg.towers(k).clock.name         = sprintf('%s_Clock', towerDefs{k,1});
                cfg.towers(k).clock.deterministic = true;
                cfg.towers(k).clock.bias_s        = 0.0;
                cfg.towers(k).clock.fracFreq      = 0.0;
            end

            % --- Estimator ------------------------------------------------
            cfg.estimator.estimateTowerClocks     = false;
            cfg.estimator.estimateAttitude        = true;
            cfg.estimator.estimateAngularRate     = true;
            % perfectCorrection: EKF uses known tower clock values (zero here).
            cfg.estimator.towerClockMode          = 'perfectCorrection';
            cfg.estimator.towerClockCorrectionSigma_m = 0.5; % used if noisyCorrection
            cfg.estimator.elevationMask_rad       = 5 * pi/180;
            cfg.estimator.attitudeJacobianStep_rad = 1e-6;
            cfg.estimator.sigma_accel_mps2        = 0.01;
            cfg.estimator.sigma_angAccel_radps2   = 1e-5;
            cfg.estimator.minMeasurementsForUpdate = 4;

            % Initial covariance (1-sigma diagonal)
            cfg.estimator.P0_pos_m        = 1000.0;
            cfg.estimator.P0_vel_mps      = 1.0;
            cfg.estimator.P0_euler_rad    = 0.01;
            cfg.estimator.P0_omega_radps  = 1e-4;
            cfg.estimator.P0_bRx_m        = 100.0;
            cfg.estimator.P0_bdotRx_mps   = 0.01;

            % Controlled initial errors (fixed offsets, not random)
            cfg.estimator.initialError.pos_m          = [1000; -500; 250];
            cfg.estimator.initialError.vel_mps        = [0.1; -0.1; 0.05];
            cfg.estimator.initialError.euler_deg      = [0.5; -0.3; 0.2];
            cfg.estimator.initialError.omega_radps    = [0; 0; 0];
            cfg.estimator.initialError.clockBias_m    = 100.0;
            cfg.estimator.initialError.clockDrift_mps = 0.01;

            % --- Measurement noise floor ----------------------------------
            cfg.measurement.sigmaFloor_m = 1e-3;

            % --- Error sources: all off by default -----------------------
            cfg.errors.codeNoise.sigma_m = 0.3;

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

            cfg.errors.hardwareDelay.truth.enable      = false;
            cfg.errors.hardwareDelay.truth.default_m   = 0.0;
            cfg.errors.hardwareDelay.model.enable      = false;
            cfg.errors.hardwareDelay.model.default_m   = 0.0;

            cfg.errors.multipath.truth.enable              = false;
            cfg.errors.multipath.truth.amplitude_m         = 0.3;
            cfg.errors.multipath.truth.frequency_radps     = 0.01;
            cfg.errors.multipath.truth.stochastic_sigma_m  = 0.1;
            cfg.errors.multipath.sigma_m                   = 0.0;

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
            cfg.report.outputPdf           = fullfile(fileparts(mfilename('fullpath')), ...
                '..', 'output', 'reverse_gnss_simple_report.pdf');
            cfg.report.includeTimestampedCopy = false;
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
            % noLeverArmConfig  Zero lever arm — attitude unobservable from pseudorange.
            cfg = revgnss.ConfigFactory.idealConfig();
            cfg.asset.receiverLeverArm_body_m = [0; 0; 0];
        end

        function cfg = positionClockOnlyConfig()
            % positionClockOnlyConfig  Attitude/omega effectively frozen.
            %
            % Use this for baseline debugging when attitude convergence is
            % not the focus.  Attitude and angular-rate states are given near-zero
            % initial uncertainty and process noise, and the lever arm is set to
            % zero so they do not affect measurements.
            %
            % Only position (3) and clock bias+drift (2) are actively estimated.

            cfg = revgnss.ConfigFactory.idealConfig();
            cfg.asset.receiverLeverArm_body_m = [0; 0; 0];

            % Near-zero uncertainty and process noise for attitude/omega
            cfg.estimator.P0_euler_rad      = 1e-12;
            cfg.estimator.P0_omega_radps    = 1e-12;
            cfg.estimator.sigma_angAccel_radps2 = 1e-15;

            % Disable estimation flags (EKF will use near-zero Q for these)
            cfg.estimator.estimateAttitude    = false;
            cfg.estimator.estimateAngularRate = false;
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
            % Tower assignments:
            %   Tenerife        OCXO     (standard ground station)
            %   Stockholm       TCXO     (lower-grade)
            %   Hartebeesthoek  Rubidium (medium-long term)
            %   Bengaluru       OCXO     (3× worse h0)
            %   Libreville      AtomicLike (best)
            %
            % Tower clocks are stochastic; mode = perfectCorrection.

            cfg = revgnss.ConfigFactory.defaultConfig();
            gs  = cfg.clockScaling;

            templateNames = {'OCXO','TCXO','Rubidium','OCXO','AtomicLike'};
            seedBase      = 200;
            factorSets    = { ...
                struct(), ...                          % Tenerife: OCXO standard
                struct(), ...                          % Stockholm: TCXO standard
                struct(), ...                          % Hartebeesthoek: Rubidium standard
                struct('h0Factor', 3.0), ...           % Bengaluru: OCXO worse h0
                struct() };                            % Libreville: AtomicLike

            for k = 1:5
                tpl = templateNames{k};
                fac = factorSets{k};
                cfgClk = revgnss.ConfigFactory.makeClockConfig(tpl, seedBase+k, fac, gs);
                cfgClk.name         = sprintf('%s_Clock', cfg.towers(k).name);
                cfgClk.deterministic = false;
                cfgClk.bias_s        = (k-1) * 5e-9;    % small initial bias offset
                cfgClk.fracFreq      = k * 1e-12;

                cfg.towers(k).clock        = cfgClk;
                cfg.towers(k).clockTemplate = tpl;
                cfg.towers(k).clockFactors  = fac;
            end

            % Receiver clock also stochastic (OCXO)
            rxClk = revgnss.ConfigFactory.makeClockConfig('OCXO', 100, struct(), gs);
            rxClk.name         = 'RxClock';
            rxClk.deterministic = false;
            rxClk.bias_s        = 0.0;
            rxClk.fracFreq      = 0.0;
            cfg.asset.clock = rxClk;

            % Keep perfectCorrection: assume clock products broadcast
            cfg.estimator.towerClockMode = 'perfectCorrection';
            cfg.errors.codeNoise.sigma_m  = 1.0;
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
            %                    biasFactor, freqFactor, noiseFactor,
            %                    h2Factor, h1Factor, h0Factor, hMinus1Factor, hMinus2Factor
            %   globalScaling  cfg.clockScaling struct (globalNoiseFactor, etc.)
            %
            % All h-coefficient factors scale as AMPLITUDE^2 (since h is a PSD level).
            % Example: h0Factor=3 triples h0, giving ~sqrt(3)× worse WFM ADEV.

            if nargin < 3 || isempty(factors);       factors       = struct(); end
            if nargin < 4 || isempty(globalScaling); globalScaling = struct(); end

            tmpl = revgnss.ConfigFactory.getClockTemplate_(templateName);

            % Extract global factors
            gNoise   = getf_(globalScaling, 'globalNoiseFactor',   1.0);
            gBias    = getf_(globalScaling, 'globalBiasFactor',    1.0);
            gFreq    = getf_(globalScaling, 'globalFreqFactor',    1.0);
            gTower   = getf_(globalScaling, 'towerNoiseFactor',    1.0);
            gRx      = getf_(globalScaling, 'receiverNoiseFactor', 1.0);
            % Note: caller decides whether this is a tower or receiver clock
            % and may pass gTower or gRx as additional multiplier externally.
            % Here we apply globalNoiseFactor only.

            % Per-coefficient amplitude-squared scale factors
            noiseAmp2 = gNoise^2;
            h2F   = getf_(factors,'h2Factor',   1.0)^2 * noiseAmp2;
            h1F   = getf_(factors,'h1Factor',   1.0)^2 * noiseAmp2;
            h0F   = getf_(factors,'h0Factor',   1.0)^2 * noiseAmp2;
            hm1F  = getf_(factors,'hMinus1Factor',1.0)^2 * noiseAmp2;
            hm2F  = getf_(factors,'hMinus2Factor',1.0)^2 * noiseAmp2;

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
