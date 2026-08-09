classdef ConfigFactory
    % ConfigFactory  Builds simulation configuration structs.
    %
    % Default scenario: GEO-1 at lat 0, lon 23 deg, alt 35 786 km with five
    % ground towers from the original SimulationConfig.m layout.
    %
    % -----------------------------------------------------------------------
    % CONFIGURATION HIERARCHY
    %
    %   Product runs resolve masterConfig plus a scenario JSON. defaultConfig()
    %   is the structural all-off fixture used by focused tests and named
    %   experimental presets. cleanConfig() is the explicit code-only control.
    %
    % -----------------------------------------------------------------------
    % SUPPORTED OBSERVABLES
    %   Code pseudorange (single-frequency or IF L1/L2 combination)
    %   Simplified Doppler
    %   Raw L1/L2 float carrier EKF; raw dual-frequency baseline attitude AR
    %     (L2 EKF attitude rows and joint L1+L2 integer-pair search are supported;
    %      carrier-IF integer fixing is explicitly unsupported; LAMBDA/MLAMBDA unsupported)
    %   ZWD per-tower EKF state
    %   Tower-clock product structs (explicit or truth-history)
    %   PCV: none / toy (elevation only) / table (elevation-only, no azimuth)
    %   Ionosphere mapping: simpleSecant (1/sin) or thinShell
    %   Thin-shell mapping: M(e)=1/sqrt(1-(Re*cos(e)/(Re+hI))^2); NOT Klobuchar
    %
    % NOT SUPPORTED
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
    %   defaultConfig()              Structural honest off=off fixture
    %   idealConfig()                Code noise = 0, all errors off
    %   cleanConfig()                All errors off, code-only
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
            % defaultConfig  Delegates to config/baseConfig.m for base configuration.
            %   Body moved to config/baseConfig.m to lift the config base out of this
            %   2512-line monolith; all existing callers keep working via this delegation.
            addpath(fullfile(fileparts(fileparts(mfilename('fullpath'))), 'config'));
            cfg = masterConfig('baseOnly');
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
            % Kept at 1e-15 deliberately. Attitude is NOT estimated here
            % (estimateAttitude=false, nReceivers=1), so this value is inert — the EKF
            % zeroes the attitude Q block (ReverseGNSSEKF.buildQ_ freeze). The
            % torque-budget default applies only to attitude-ESTIMATING presets.
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
            % Torque-budget-justified attitude process noise (~1e-7 rad/s^2),
            % replacing the over-optimistic 1e-10. alpha = tau / I (Wertz).
            cfg.estimator.sigma_angAccel_radps2     = revgnss.ConfigFactory.angAccelFromTorqueBudget_( ...
                cfg.asset.inertia_kgm2, cfg.asset.residualDisturbanceTorque_Nm);
            cfg.estimator.initialError.euler_deg    = [1; -1; 0.5];
            cfg.estimator.initialError.omega_radps  = [0; 0; 0];

            cfg.errors.codeNoise.sigma_m = 0.03;
        end

        function cfg = clockNoiseConfig()
            % clockNoiseConfig  Stochastic receiver + tower clocks with noisyCorrection.
            %
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
            % Set the KNOB, not the derived field: finalizeConfig maps
            % towerClock.correctionMode -> estimator.towerClockMode and would overwrite a
            % direct assignment here. ('noisyCorrection' has no dedicated correctionMode
            % name; it reaches the internal mode via the switch's passthrough branch.)
            cfg.towerClock.correctionMode = 'noisyCorrection';
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
            % Knob, not the derived field -- see clockNoiseConfig above.
            cfg.towerClock.correctionMode = 'none';
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

            % Keep perfect correction: assume clock products are broadcast.
            % Knob, not the derived field -- 'perfectTruth' maps to towerClockMode
            % 'perfectCorrection'. See clockNoiseConfig above.
            cfg.towerClock.correctionMode = 'perfectTruth';
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

        function cfg = geoRealWorldTruthComparisonConfig()
            % geoRealWorldTruthComparisonConfig  Canonical GEO scenario.
            %
            % Single source of truth for run_geo_realworld_truth_comparison.m.
            % The scenario uses the same J2 force family and seeded stochastic
            % residuals in clocks, atmosphere, hardware, multipath, and measurements.
            cfg = revgnss.ConfigFactory.defaultConfig();
            cfg = revgnss.ScenarioPresets.apply(cfg, 'geoRealWorldTruthComparison');
            cfg.validation.unsupportedFeaturePolicy = 'error';
            cfg.validation.synthetic = true;
            cfg.validation.allowTruthModelMismatch = false;
            cfg.scientificProfile.mode = 'geoRealisticTruthComparisonV1';
            cfg.scientificProfile.claimLevel = 'realisticSimulationTruthComparison';
            cfg.scientificProfile.allowRealWorldClaim = false;
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
            % Use truthHistoryProductNoisy (history-based + noise) consistently.
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

            % Select the h-coefficient source ('legacy' | 'jowTable2p1'), threaded
            % via cfg.clockScaling.templateSource (synced from cfg.clock.templateSource).
            tsrc = getf_(globalScaling, 'templateSource', 'legacy');
            tmpl = revgnss.ConfigFactory.getClockTemplate_(templateName, tsrc);

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

        function cfg = applyMultiAssetMode(cfg)
            % applyMultiAssetMode  Resolve the cfg.multiAsset.mode convenience switch
            %   ('fast' | 'joint') without activating measurement features.
            %
            %   'fast'  retains the independent-filter compatibility architecture.
            %   'joint' marks every represented spacecraft as owned by the centralized
            %           estimator. Sensor and protocol gates remain explicit.
            %
            %   Called from both masterConfig and finalizeConfig.
            mode = 'fast';
            if isfield(cfg,'multiAsset') && isfield(cfg.multiAsset,'mode') && ...
                    (ischar(cfg.multiAsset.mode) || isstring(cfg.multiAsset.mode))
                mode = char(cfg.multiAsset.mode);
            end
            switch lower(mode)
                case 'fast'
                    return
                case 'joint'
                    nAssets = 1;
                    if isfield(cfg,'scenario') && isfield(cfg.scenario,'nSpaceAssets')
                        nAssets = max(1, round(cfg.scenario.nSpaceAssets));
                    end
                    if nAssets < 2
                        error('ConfigFactory:jointModeAssetCount', ...
                            'cfg.multiAsset.mode=''joint'' requires scenario.nSpaceAssets >= 2.');
                    end
                    cfg.multiAsset.mode = 'joint';
                    cfg = revgnss.MultiAssetConfig.normalize(cfg);
                otherwise
                    error('ConfigFactory:multiAssetMode', ...
                        'cfg.multiAsset.mode must be ''fast'' or ''joint''; got ''%s''.', mode);
            end
        end

        function cfg = applyAtmosphereProfile(cfg)
            % applyAtmosphereProfile  Apply masterConfig's atmosphere toggles.
            %   Opt-in: returns cfg unchanged unless cfg.atmosphere.realistic is
            %   true. When true, overlays the physically-realistic troposphere/
            %   ionosphere/scintillation (realisticAtmosphereConfig) and resolves the
            %   two orthogonal ionosphere toggles into the measurement/estimation
            %   settings:
            %     cfg.atmosphere.ionosphereFree -> codeMode 'ionosphereFree' (IF combo)
            %     cfg.atmosphere.estimateIono   -> ionosphereMode 'perTowerSlant' state
            %     both false                    -> codeMode 'singleFrequency' (RAW dual-freq)
            %   Idempotent (re-running yields the same cfg), so it is safe under
            %   finalizeConfig being called more than once per run.
            if ~(isfield(cfg,'atmosphere') && isfield(cfg.atmosphere,'realistic') ...
                    && cfg.atmosphere.realistic)
                return;
            end
            if isempty(which('realisticAtmosphereConfig'))
                error('revgnss:ConfigFactory:missingAtmosphereProfile', ...
                    ['cfg.atmosphere.realistic is true but realisticAtmosphereConfig.m ' ...
                     'is not on the path (expected in oo_v1/config).']);
            end
            cfg  = realisticAtmosphereConfig(cfg);

            % Resolve the ionosphere toggles. Prefer the two booleans; accept the
            % legacy 'ionosphereHandling' string for back-compat and map it.
            ionoFree   = false;
            estimIono  = false;
            if isfield(cfg.atmosphere,'ionosphereFree'); ionoFree  = logical(cfg.atmosphere.ionosphereFree); end
            if isfield(cfg.atmosphere,'estimateIono');   estimIono = logical(cfg.atmosphere.estimateIono);   end
            if isfield(cfg.atmosphere,'ionosphereHandling')   % legacy alias
                switch cfg.atmosphere.ionosphereHandling
                    case 'ionosphereFree'; ionoFree = true;
                    case 'ekfState';       estimIono = true;
                    case 'single'          % raw dual-frequency -> both false
                    otherwise
                        error('revgnss:ConfigFactory:badIonosphereHandling', ...
                            'Unknown cfg.atmosphere.ionosphereHandling ''%s''.', cfg.atmosphere.ionosphereHandling);
                end
            end
            if ionoFree && estimIono
                error('revgnss:ConfigFactory:conflictingIonosphere', ...
                    'cfg.atmosphere.ionosphereFree and .estimateIono are mutually exclusive.');
            end

            if ionoFree
                cfg.measurements.codeMode = 'ionosphereFree';
            elseif estimIono
                cfg.measurements.codeMode              = 'singleFrequency';
                cfg.estimation.ionosphereMode          = 'perTowerSlant';
                cfg.errors.ionosphere.model.correction = 'none';
            else
                cfg.measurements.codeMode = 'singleFrequency';   % RAW uncombined dual-freq
            end
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

            % Apply the selected atmosphere profile before resolving parent enables.
            cfg = revgnss.ConfigFactory.applyAtmosphereProfile(cfg);

            cfg = resolveEnablePairsPostMerge(cfg, { ...
                'physics.sagnac', 'physics.lightTime', 'physics.relativity.shapiro', ...
                'physics.relativity.clock', 'physics.doppler', ...
                'errors.troposphere', 'errors.ionosphere', 'errors.hardwareDelay', 'errors.multipath', ...
                'effects.towerSurvey', 'effects.antennaPCO', 'effects.antennaPCV' });

            % ---- Multi-asset mode switch (ordering-safe re-resolution) -----
            % Resolve cfg.multiAsset.mode after scenario overrides. Joint mode changes
            % state ownership only; measurement and protocol gates remain explicit.
            cfg = revgnss.ConfigFactory.applyMultiAssetMode(cfg);
            revgnss.IndependentFleetCoordinator.validateConfig(cfg);

            % ---- PRE-merge writers, re-resolved post-merge (step 2) ---------------------
            % These four run at masterConfig.m:632/677/678/679, i.e. BEFORE run_oo_v1 merges
            % the scenario JSON, which makes their trigger keys inert from a scenario:
            % scenario.orbitClass -- the documented "SINGLE switch" -- perturbations.sunMoon.
            % enable, multiAsset.injectTruthSideDynamics and errors.hardwareDelay.perTowerBias
            % .enable. Re-running them here is what makes a scenario able to reach them.
            %
            % All four are idempotent (constants and copies; the two `max` clamps converge),
            % so the masterConfig call is left in place -- it still serves callers that use
            % masterConfig() without finalizeConfig, e.g. tests/regression/
            % goldenRealismScenarioConfig -- and this pass simply re-resolves.
            %
            % preserveScenarioOwned gives the scenario back every key it wrote, so a writer
            % supplies defaults but never overrides the JSON. No JSON => no provenance =>
            % strict pass-through => goldens byte-identical.
            %
            % ORDER IS LOAD-BEARING:
            %   orbitClassConfig FIRST  -- on the LEO path it replaces cfg.towers wholesale,
            %       and applyPerTowerHwBias draws one bias per tower from numel(cfg.towers).
            %   applyPerTowerHwBias LAST -- it deliberately forces hardwareDelay.model.enable
            %       = false (uncalibrated: the bias must survive z - h). resolveEnablePairs-
            %       PostMerge above would re-slave that member to the master, undoing it.
            %
            % NOT relocated here: realismGradeConfig. It is gated on nSpaceAssets >= 2 for its
            % ISL blocks and masterConfig has nSpaceAssets = 1 at call time, so moving it would
            % newly fire 21 ISL keys for the 34 swarm scenarios and apply 62 keys to the 46
            % scenarios that set realism.grade = true -- a campaign-wide result change that
            % needs its own measured step, not a silent ride-along.
            cfg = preserveScenarioOwned(cfg, @orbitClassConfig);
            cfg = preserveScenarioOwned(cfg, @applyLuniSolar);
            cfg = preserveScenarioOwned(cfg, @applyInjectTruthSideDynamics);
            cfg = preserveScenarioOwned(cfg, @applyPerTowerHwBias);

            % ---- realism.grade re-resolved post-merge (GATED, default OFF) --------------
            % The deferred half of step 2. Enabling this makes realism.grade work from a
            % scenario for the first time -- and 46 of the 69 committed scenarios set it, so
            % it is a campaign-wide result change, not a refactor. Default OFF so it can be
            % MEASURED (resolve each scenario both ways and diff) before it is decided.
            % Turning it on is a scientific decision with a re-run attached; see step 5.
            resolveRealism_ = false;
            try; resolveRealism_ = logical(cfg.realism.resolvePostMerge); catch; end
            gradeOn_ = false;
            try; gradeOn_ = logical(cfg.realism.grade); catch; end
            if resolveRealism_ && gradeOn_
                cfg = preserveScenarioOwned(cfg, @realismGradeConfig);
            end

            % ---- IMU / gyro attitude aiding (gated; no-op unless cfg.estimator.imu.enable) ----
            % Resolve the master switch into the EKF flag here. Physical IMUs are assigned
            % after MultiAssetConfig.normalize identifies the estimated spacecraft.
            imuOn = false;
            try; imuOn = logical(cfg.estimator.imu.enable); catch; end
            cfg.estimator.estimateGyroBias = imuOn;

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

            arcConsistencyRequested = false;
            try
                arcConsistencyRequested = logical( ...
                    cfg.estimator.enforceCarrierArcConsistency.enable);
            catch
            end
            if arcConsistencyRequested
                error('ConfigFactory:carrierArcConsistencyUnavailable', ...
                    ['estimator.enforceCarrierArcConsistency.enable is unavailable: ' ...
                     'arc identifiers are assigned after carrier ionosphere-free rows are built.']);
            end
            phaseBiasRequirementDeclared = isfield(cfg, 'estimator') && ...
                isfield(cfg.estimator, 'diffAtt') && ...
                isfield(cfg.estimator.diffAtt, 'ambiguityResolution') && ...
                isfield(cfg.estimator.diffAtt.ambiguityResolution, ...
                    'requirePhaseBiasCalibrationForFix');
            if phaseBiasRequirementDeclared && ~logical( ...
                    cfg.estimator.diffAtt.ambiguityResolution. ...
                    requirePhaseBiasCalibrationForFix)
                error('ConfigFactory:uncalibratedIntegerFixingUnavailable', ...
                    'Integer fixing cannot bypass phase-bias calibration.');
            end

            % ---- User convenience field mappings -------------------------
            % cfg.clock.receiver.deterministic → cfg.asset.clock.deterministic
            if isfield(cfg,'clock') && isfield(cfg.clock,'receiver') && ...
                    isfield(cfg.clock.receiver,'deterministic')
                cfg.asset.clock.deterministic = cfg.clock.receiver.deterministic;
            end
            % Canonical clock product mode → legacy alias sync
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
            % cfg.clocks.tower.product.mode → cfg.towerClock.correctionMode (legacy route)
            % The legacy chain used to write cfg.estimator.towerClockMode directly. Two
            % reasons it no longer does:
            %   - Guarding that write on ~isfield(cfg.towerClock,'correctionMode') makes it
            %     DEAD CODE: masterConfig always assigns cfg.towerClock.correctionMode, so
            %     the guard is always false. A scenario that set only the legacy knob had it
            %     silently ignored -- config/ladder/test/test001_idealFlat.json asks for
            %     'perfectTruth' and got the default 'truthHistoryProductNoisy', worth
            %     ~0.14 m of position error.
            %   - The legacy names are EXTERNAL ('perfectTruth'); estimator.towerClockMode
            %     takes INTERNAL ones ('perfectCorrection'). Writing the external name
            %     straight in only ever "worked" because TowerClockCorrectionProvider's
            %     switch falls through to `otherwise -> towerClockModel = 0`.
            % So route the legacy value into the NEW knob instead and let the normalisation
            % switch below translate it. OWNERSHIP decides, not field existence: honour the
            % legacy knob only when the scenario set it and did NOT set the new one.
            % cfg.provenance.explicit is the same list preserveScenarioOwned uses, and is
            % absent when finalizeConfig is handed a raw masterConfig -- so a direct call is
            % unaffected and the new knob still wins.
            towerClkOwned_ = {};
            if isfield(cfg,'provenance') && isfield(cfg.provenance,'explicit')
                towerClkOwned_ = cfg.provenance.explicit;
            end
            if any(strcmp(towerClkOwned_,'clocks.tower.product.mode')) && ...
                    isfield(cfg,'clocks') && isfield(cfg.clocks,'tower') && ...
                    isfield(cfg.clocks.tower,'product') && ...
                    isfield(cfg.clocks.tower.product,'mode')
                if any(strcmp(towerClkOwned_,'towerClock.correctionMode'))
                    if ~strcmp(cfg.towerClock.correctionMode, cfg.clocks.tower.product.mode)
                        cfg.validation.warnings{end+1} = ...
                            'cfg.clocks.tower.product.mode and cfg.towerClock.correctionMode are both scenario-set and disagree; cfg.towerClock.correctionMode wins.';
                    end
                else
                    if ~isfield(cfg,'towerClock'); cfg.towerClock = struct(); end
                    cfg.towerClock.correctionMode = cfg.clocks.tower.product.mode;
                end
            end
            % cfg.towerClock.correctionMode → cfg.estimator.towerClockMode (new mapping)
            % Truth-history modes and explicit-struct modes are now distinct.
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
                        % Assign unconditionally, like every other case. The old
                        % "only if not already set" guard could never fire -- masterConfig
                        % always sets cfg.estimator.towerClockMode -- so correctionMode
                        % 'perfectTruth' was the ONE mode that silently did not map, and you
                        % got the product mode ('truthHistoryProductNoisy') instead. That
                        % quietly denied the perfect-truth validation baseline to anyone who
                        % asked for it.
                        cfg.estimator.towerClockMode = 'perfectCorrection';
                    case 'truthHistoryProduct'
                        % History-based product. Internal mode 'truthProduct' does NOT
                        % require cfg.towerClock.products — it uses tower truth history.
                        cfg.estimator.towerClockMode = 'truthProduct';
                    case 'truthHistoryProductNoisy'
                        % History-based product with deterministic per-product
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

            % Canonical slip threshold sync
            % cfg.carrierSlip.threshold_m is canonical; derive slipDetection.threshold_m.
            % CarrierTrackManager reads cfg.measurements.carrier.slipDetection.threshold_m at runtime.
            if isfield(cfg,'carrierSlip') && isfield(cfg.carrierSlip,'threshold_m')
                if isfield(cfg,'measurements') && isfield(cfg.measurements,'carrier') && ...
                        isfield(cfg.measurements.carrier,'slipDetection')
                    % NaN on the canonical side means AUTO (resolved later, once lambda and
                    % the carrier sigma are known) -- not a disagreement. Guard the compare:
                    % x ~= NaN is ALWAYS true, so without this every auto-threshold run would
                    % emit a "canonical slip threshold wins" warning that means nothing.
                    if isfield(cfg.measurements.carrier.slipDetection,'threshold_m') && ...
                            isfinite(cfg.carrierSlip.threshold_m) && ...
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

            % ---- cfg.estimator.clockGauge alias -> canonical cfg.clock.gauge ----
            % Optional convenience surface exposing the plan's datum vocabulary
            % ('none' | 'masterClock' | 'zeroMeanEnsemble' + masterIndex). Present-only:
            % there is NO baseConfig default for cfg.estimator.clockGauge, so configs that
            % set cfg.clock.gauge.mode directly are never clobbered. This alias only maps
            % the datum mode onto the existing gauge engine;
            % it does not by itself enable tower-clock estimation (use cfg.clock.mode for
            % that). Datum rationale: for n clocks only n-1 clock states are separable,
            % leaving one unobservable common-mode datum (Kaplan & Hegarty, control segment).
            if isfield(cfg,'estimator') && isfield(cfg.estimator,'clockGauge')
                eg = cfg.estimator.clockGauge;
                if ~isfield(cfg,'clock');       cfg.clock = struct();       end
                if ~isfield(cfg.clock,'gauge'); cfg.clock.gauge = struct(); end
                if isfield(eg,'mode')
                    switch eg.mode
                        case 'none';             cfg.clock.gauge.mode = 'externalTowerCorrections';
                        case 'masterClock';      cfg.clock.gauge.mode = 'fixReferenceTower';
                        case 'zeroMeanEnsemble'; cfg.clock.gauge.mode = 'meanGroundClockGauge';
                        otherwise
                            error('ConfigFactory:invalidClockGaugeMode', ...
                                ['cfg.estimator.clockGauge.mode must be ''none'', ''masterClock'', ' ...
                                 'or ''zeroMeanEnsemble''; got ''%s''.'], eg.mode);
                    end
                end
                if isfield(eg,'masterIndex')
                    cfg.clock.gauge.referenceTowerIndex = eg.masterIndex;
                end
            end

            % ---- Clock mode / gauge validation ------------------
            % Map cfg.clock.mode to estimator.estimateTowerClocks and validate gauge.
            if isfield(cfg,'clock') && isfield(cfg.clock,'mode')
                clockMode = cfg.clock.mode;
                gaugeMode = 'externalTowerCorrections';
                if isfield(cfg.clock,'gauge') && isfield(cfg.clock.gauge,'mode')
                    gaugeMode = cfg.clock.gauge.mode;
                end

                % Accept the datum-vocabulary synonyms
                % 'masterClock' and 'zeroMeanEnsemble' as aliases for the EXISTING
                % gauge machinery, so plan/preset configs written in that vocabulary
                % drive the same pseudo-measurement update path (no parallel gauge).
                %   masterClock      == fixReferenceTower   (one clock held as datum)
                %   zeroMeanEnsemble == meanGroundClockGauge (zero-mean composite clock)
                % Rationale: for n clocks only n-1 clock states are separable, leaving
                % one unobservable common-mode datum (Kaplan & Hegarty, control-segment
                % discussion). The gauge pins that datum. masterIndex aliases
                % referenceTowerIndex.
                switch gaugeMode
                    case 'masterClock'
                        gaugeMode = 'fixReferenceTower';
                        cfg.clock.gauge.mode = gaugeMode;
                    case 'zeroMeanEnsemble'
                        gaugeMode = 'meanGroundClockGauge';
                        cfg.clock.gauge.mode = gaugeMode;
                end
                if isfield(cfg.clock,'gauge') && isfield(cfg.clock.gauge,'masterIndex')
                    cfg.clock.gauge.referenceTowerIndex = cfg.clock.gauge.masterIndex;
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

            % ---- Transmitter code bias identifiability guards ------
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

            % ---- Receiver hardware-bias identifiability guards ------
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
                    if ~any(strcmp(cfg.validation.warnings, warnMsg12))
                        cfg.validation.warnings{end+1} = warnMsg12;
                        warning('ConfigFactory:rxCarrierBiasAbsorbed', '%s', warnMsg12);
                    end
                end
            end

            % ---- Ionosphere-free + rxCodeBias incompatibility guard ------
            % IF combines L1 and L2 with different coefficients, so a single scalar
            % receiver code-bias calibration is not well-defined for both frequencies.
            % Per-signal receiver code-bias handling is not implemented.
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

            % ---- One-way light-time / Sagnac consistency -------
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

            % ---- Relativistic clock-rate offset --------------------
            % Implemented as a gated TRUTH-side constant relativistic fractional-frequency
            % offset on the receiver clock (applied at the receiver-clock recreate below via
            % revgnss.Relativity -> cfg.asset.clock.relativisticFracFreq). Previously force-
            % disabled as "not validated v1"; now supported and default OFF (masterConfig).
            % No separate model-side (broadcast) correction is applied: the constant offset
            % is observable and absorbed by the estimated receiver clock-drift state, so the
            % estimation residual for a circular orbit is zero (only an eccentric orbit's
            % periodic term would survive). See docs/scientific_correctness_review_v3.md.
            if isfield(cfg,'physics') && isfield(cfg.physics,'relativity') && ...
                    isfield(cfg.physics.relativity,'clock')
                rc   = cfg.physics.relativity.clock;
                rcOn = (isfield(rc,'truth') && isfield(rc.truth,'enable') && rc.truth.enable) || ...
                       (isfield(rc,'model') && isfield(rc.model,'enable') && rc.model.enable);
                if rcOn
                    mappedRelativity = ...
                        'relativity.clock: truth-side receiver clock-rate offset';
                    if ~any(strcmp(cfg.validation.mappedFeatures, mappedRelativity))
                        cfg.validation.mappedFeatures{end+1} = mappedRelativity;
                    end
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

            % ---- Central signal and frequency ownership --------
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
            % SignalDefinition is keyed by NAME, so a scenario that retunes a band while
            % keeping the name (the Ka ladder moves "L1" to 30 GHz) would have its frequency
            % silently stamped back to the canonical 1575.42 MHz here -- every ka_*.json ran
            % at L-band, which nullifies the 1/f^2 ionosphere argument the ladder exists to
            % test. Honour a frequency the scenario explicitly owns; derive lambda from it so
            % the pair can never disagree. cfg.provenance.explicit is the same list
            % preserveScenarioOwned uses, and is absent when finalizeConfig is handed a raw
            % masterConfig -- hence the guard.
            ownedSig79_ = {};
            if isfield(cfg,'provenance') && isfield(cfg.provenance,'explicit')
                ownedSig79_ = cfg.provenance.explicit;
            end
            for si79_ = 1:nSig79_
                sd79_ = revgnss.SignalDefinition.get(sigNames79_{si79_});
                freqHz79_(si79_) = sd79_.frequency_Hz;
                waveM79_(si79_)  = sd79_.wavelength_m;

                sn79o_ = sigNames79_{si79_};
                if any(strcmp(ownedSig79_, sprintf('signals.%s.frequency_Hz', sn79o_))) && ...
                        isfield(cfg.signals, sn79o_) && ...
                        isfield(cfg.signals.(sn79o_), 'frequency_Hz')
                    fOwn79_ = cfg.signals.(sn79o_).frequency_Hz;
                    if isnumeric(fOwn79_) && isscalar(fOwn79_) && isfinite(fOwn79_) && fOwn79_ > 0
                        freqHz79_(si79_) = fOwn79_;
                        waveM79_(si79_)  = 299792458 / fOwn79_;   % c [m/s], as SignalDefinition
                    end
                end
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

            % ---- carrierPhase frequency/wavelength DERIVED, not frozen -----------------
            % masterConfig seeds measurements.carrierPhase.frequency_Hz/.lambda_m from the
            % canonical SignalDefinition.get('L1') -- 1575.42 MHz / 190.29 mm -- and nothing
            % updated them when a scenario retuned the band. Measured across
            % config/ladder/freq/freq009..013 (915 MHz .. 61.25 GHz): signals.L1.frequency_Hz
            % followed the JSON in every file while carrierPhase.frequency_Hz read 1575.42 MHz
            % in ALL of them, up to a 39x wavelength error at the 61.25 GHz rung. Derive both
            % from the SAME resolved primary carrier the code path and the ionosphere scaling
            % already use (cfg.signals.<primary>), so the pair can never disagree with the band.
            %
            % The primary carrier is 'L1' when present (masterConfig always names L1 first);
            % a signal list without an L1 falls back to its first entry. lambda is derived from
            % the frequency rather than copied, so the two fields are consistent by construction.
            % A scenario that pins either field explicitly keeps its own value -- same
            % provenance.explicit ownership test the frequency block above uses.
            %
            % GOLDEN-SAFE: golden_baseline.json leaves L1 at the canonical 1575.42 MHz, so the
            % derived pair comes out bit-identical to masterConfig's seed there.
            if ~isfield(cfg.measurements,'carrierPhase')
                cfg.measurements.carrierPhase = struct();
            end
            primIdx79_ = find(strcmpi(sigNames79_, 'L1'), 1);
            if isempty(primIdx79_); primIdx79_ = 1; end
            if nSig79_ >= 1
                cpOwnsFreq79_ = any(strcmp(ownedSig79_, 'measurements.carrierPhase.frequency_Hz'));
                cpOwnsLam79_  = any(strcmp(ownedSig79_, 'measurements.carrierPhase.lambda_m'));
                if ~cpOwnsFreq79_
                    cfg.measurements.carrierPhase.frequency_Hz = freqHz79_(primIdx79_);
                end
                if ~cpOwnsLam79_
                    if cpOwnsFreq79_
                        % Scenario pinned the frequency but not the wavelength: derive from
                        % what it pinned, not from the signal table it chose to bypass.
                        cfg.measurements.carrierPhase.lambda_m = ...
                            299792458 / cfg.measurements.carrierPhase.frequency_Hz;   % c [m/s]
                    else
                        % Same array the cfg.signals.<name>.lambda_m aliases come from, so
                        % carrierPhase.lambda_m == cfg.signals.L1.lambda_m to the last bit.
                        cfg.measurements.carrierPhase.lambda_m = waveM79_(primIdx79_);
                    end
                end
            end

            % ---- Band-invariant carrier sigma and slip threshold ------------------------
            % Both quantities are physically specified in CYCLES (a fraction of a wavelength,
            % and an integer count of wavelengths) but are stored in metres, so they silently
            % rescale with the band. Resolve them HERE, after lambda is known, and keep the
            % metre field canonical so every downstream reader is untouched.
            %
            % MEASURED, freq009..013 at the fixed metre values: carrier R goes from 0.026
            % cycles at GPS L1 to 1.02 cycles at 61.25 GHz (R asserting a whole wavelength of
            % noise), and the slip threshold from 0.53 to 20.4 cycles (sub-cycle sensitive to
            % blind). The pre-fix ladder could not show this because the carrier wavelength
            % was stuck at L1 regardless of band; see the carrierPhase block above.
            %
            % PRECEDENCE, both fields: THE CYCLES FORM WINS WHENEVER IT IS SET to a finite
            % positive value, because setting it is an unambiguous opt-in; the metre field is
            % the fallback. The reverse rule (metre-wins-if-owned) was tried and is useless in
            % practice: golden_baseline.json explicitly declares
            % measurements.carrier.sigma_m = 0.01 with a documented 10 mm budget, and EVERY
            % ladder file inherits it through _extends, so a metre-wins rule would leave the
            % cycles knob inert on every scenario in the repository. When BOTH are explicitly
            % scenario-owned the cycles form still wins, and a validation warning records it
            % so the override is never silent.
            % GOLDEN-SAFE: masterConfig ships sigma_cycles = NaN and threshold_cycles = NaN,
            % so with no opt-in nothing is written and the frozen goldens are byte-identical.
            if nSig79_ >= 1
                lamPrim79_ = waveM79_(primIdx79_);

                % --- carrier sigma (the R applied to every carrier EKF row) ---
                if ~isfield(cfg.measurements,'carrier'); cfg.measurements.carrier = struct(); end
                sigCyc79_ = NaN;
                if isfield(cfg.measurements.carrier,'sigma_cycles')
                    sigCyc79_ = cfg.measurements.carrier.sigma_cycles;
                end
                if isnumeric(sigCyc79_) && isscalar(sigCyc79_) && isfinite(sigCyc79_) && sigCyc79_ > 0
                    % TWO-TERM BUDGET. A cycles-only sigma models the DISPERSIVE part of the
                    % carrier error -- PLL thermal noise, phase multipath (bounded by
                    % lambda/4), phase wind-up (exactly one cycle per revolution) -- all of
                    % which really are proportional to lambda. It does NOT model the
                    % NON-DISPERSIVE part: tropospheric wet-delay fluctuation, oscillator
                    % phase noise, antenna phase-centre mechanical stability, PCV residual.
                    % Those are constant in METRES, so expressed in cycles they grow linearly
                    % with frequency -- a fixed cycles figure is exactly backwards for them.
                    %
                    % Without a floor, 0.01 cycles at the 61.25 GHz rung is 0.049 mm, which is
                    % 204x below the 1 cm "real-world guard" realismGradeConfig declares
                    % (honestFloors.carrier_sigma_m) and that GeoRealWorldScenarioGuard
                    % enforces -- i.e. the derivation would silently undercut the repository's
                    % own realism policy. Add the floor in quadrature so it cannot.
                    %
                    % The floor is cfg.measurement.sigmaFloor_m (the EXISTING general floor,
                    % 1 mm by default, raised to 1 cm by the realism grade and to 1 m by
                    % honestCovarianceConfig) unless the scenario states a carrier-specific
                    % one. Reused rather than reinvented so the carrier and code floors cannot
                    % drift apart.
                    %
                    % APPLIED ONLY ON THE CYCLES PATH: a scenario that never sets sigma_cycles
                    % keeps its sigma_m untouched, so the frozen goldens cannot move.
                    sigDer79_ = sigCyc79_ * lamPrim79_;
                    floor79_ = NaN;
                    if isfield(cfg.measurements.carrier,'sigmaFloor_m')
                        floor79_ = cfg.measurements.carrier.sigmaFloor_m;
                    end
                    if ~(isnumeric(floor79_) && isscalar(floor79_) && isfinite(floor79_) && floor79_ >= 0)
                        floor79_ = NaN;
                        if isfield(cfg,'measurement') && isfield(cfg.measurement,'sigmaFloor_m')
                            floor79_ = cfg.measurement.sigmaFloor_m;
                        end
                    end
                    if isnumeric(floor79_) && isscalar(floor79_) && isfinite(floor79_) && floor79_ > 0
                        sigDer79_ = sqrt(sigDer79_^2 + floor79_^2);
                    end
                    % Warn only on a REAL override. finalizeConfig can run more than once per
                    % run (see the re-entry note above), and on the second pass the value it
                    % would report as "scenario-owned" is the one this block already derived
                    % -- a duplicate warning naming a number the user never wrote.
                    if any(strcmp(ownedSig79_, 'measurements.carrier.sigma_m')) && ...
                            cfg.measurements.carrier.sigma_m ~= sigDer79_
                        cfg.validation.warnings{end+1} = sprintf( ...
                            ['measurements.carrier.sigma_cycles (%g cyc) overrides the ' ...
                             'scenario-owned measurements.carrier.sigma_m (%g m); the ' ...
                             'band-referenced form wins -> %g m at lambda %g m.'], ...
                            sigCyc79_, cfg.measurements.carrier.sigma_m, ...
                            sigDer79_, lamPrim79_);
                    end
                    cfg.measurements.carrier.sigma_m = sigDer79_;
                end

                % --- slip threshold (canonical owner is cfg.carrierSlip.threshold_m) ---
                if isfield(cfg,'carrierSlip')
                    thrCyc79_ = NaN;
                    if isfield(cfg.carrierSlip,'threshold_cycles')
                        thrCyc79_ = cfg.carrierSlip.threshold_cycles;
                    end
                    thrM79_ = NaN;
                    if isfield(cfg.carrierSlip,'threshold_m'); thrM79_ = cfg.carrierSlip.threshold_m; end

                    if isnumeric(thrCyc79_) && isscalar(thrCyc79_) && ...
                            isfinite(thrCyc79_) && thrCyc79_ > 0
                        thrDer79_ = thrCyc79_ * lamPrim79_;
                        % Same re-entry guard as the sigma above.
                        if any(strcmp(ownedSig79_, 'carrierSlip.threshold_m')) && ...
                                thrM79_ ~= thrDer79_
                            cfg.validation.warnings{end+1} = sprintf( ...
                                ['carrierSlip.threshold_cycles (%g cyc) overrides the ' ...
                                 'scenario-owned carrierSlip.threshold_m (%g m); the ' ...
                                 'band-referenced form wins -> %g m.'], ...
                                thrCyc79_, thrM79_, thrDer79_);
                        end
                        cfg.carrierSlip.threshold_m = thrDer79_;
                    elseif isnumeric(thrM79_) && isscalar(thrM79_) && ~isfinite(thrM79_)
                        % NaN = AUTO, the ISL idiom: the detector tests the epoch-to-epoch
                        % change of the carrier prefit, whose noise is sqrt(2)*sigma, so
                        % 5*sqrt(2)*sigma can never desynchronise from the sigma in force.
                        sigNow79_ = 0.005;
                        if isfield(cfg.measurements.carrier,'sigma_m') && ...
                                isnumeric(cfg.measurements.carrier.sigma_m) && ...
                                isscalar(cfg.measurements.carrier.sigma_m) && ...
                                isfinite(cfg.measurements.carrier.sigma_m)
                            sigNow79_ = cfg.measurements.carrier.sigma_m;
                        end
                        cfg.carrierSlip.threshold_m = 5 * sqrt(2) * sigNow79_;
                    end

                    % Re-assert the canonical sync. The earlier sync (see "Canonical slip
                    % threshold sync") runs BEFORE lambda is resolved, so anything derived
                    % here has to be pushed to the runtime field CarrierTrackManager reads.
                    if isfield(cfg.measurements.carrier,'slipDetection') && ...
                            isfield(cfg.carrierSlip,'threshold_m')
                        cfg.measurements.carrier.slipDetection.threshold_m = ...
                            cfg.carrierSlip.threshold_m;
                    end
                end
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

            carrierIfActive = revgnss.CarrierIonoFreeRowBuilder.shouldCombine(cfg) && ...
                nnz(cfg.measurements.carrier.enabledByFrequency) > 1;
            arcSeparationRequested = false;
            try
                arcSeparationRequested = logical( ...
                    cfg.estimator.arcSeparatedAmbiguities.enable);
            catch
            end
            slipDetectionRequested = false;
            try
                slipDetectionRequested = logical(cfg.carrierSlip.enable);
            catch
            end
            if carrierIfActive && (arcSeparationRequested || slipDetectionRequested)
                error('ConfigFactory:carrierIfArcTrackingUnavailable', ...
                    ['Carrier ionosphere-free rows are formed before per-frequency ' ...
                     'arc tracking. Disable carrierSlip and arcSeparatedAmbiguities.']);
            end

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

                enforceBiasStatus = false;
                try
                    enforceBiasStatus = logical(cfg.estimator.diffAtt.ambiguityResolution.enforcePhaseBiasStatus);
                catch
                end
                phaseBiasStatusOwned = false;
                try
                    phaseBiasStatusOwned = any(strcmp( ...
                        cfg.provenance.explicit, ...
                        'estimator.diffAtt.ambiguityResolution.phaseBiasStatus'));
                catch
                end
                if enforceBiasStatus && ~phaseBiasStatusOwned
                    cfg.estimator.diffAtt.ambiguityResolution.phaseBiasStatus = ...
                        revgnss.InterAntennaPhaseBias.resolvedStatus(cfg);
                end
            end

            % ---- Multi-space-asset policy ------------------------------------
            % nSpaceAssets>1 is supported as a represented-only helix swarm that aids
            % the PRIMARY (asset 1) EKF via ISL. Joint estimation of secondary states
            % is NOT enabled; MultiAssetConfig.normalize enforces primary-only
            % estimation (only asset 1 gets EKF columns). No truncation of assets.

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
            % Runs after canonical masks are finalized.
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

            % ---- attitudeCarrierMode validation ----------------
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

            % ---- Attitude initialization mode validation --------
            if ~isfield(cfg.estimator,'attitudeInitMode')
                cfg.estimator.attitudeInitMode = 'none';
            end
            attInitMode16 = cfg.estimator.attitudeInitMode;
            if strcmp(attInitMode16, 'knownAttitudeCalibration')
                error('ConfigFactory:truthAttitudeInitializationUnavailable', ...
                    ['knownAttitudeCalibration uses simulated truth as an estimator ' ...
                     'input and is unavailable.']);
            end
            validInit16 = {'none','coarseBaselineIntegerSearch'};
            if ~any(strcmp(attInitMode16, validInit16))
                error('ConfigFactory:invalidAttitudeInitMode', ...
                    ['cfg.estimator.attitudeInitMode must be none or ' ...
                     'coarseBaselineIntegerSearch.']);
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
            % Canonical h-coefficient source is cfg.clock.templateSource; mirror it
            % into the clockScaling struct that makeClockConfig reads.
            gs.templateSource = getf_(getf_(cfg,'clock',struct()), 'templateSource', ...
                getf_(gs,'templateSource','legacy'));
            cfg.clockScaling.templateSource = gs.templateSource;
            % Optional per-draw clock-seed offset for the Monte-Carlo consistency
            % harness, so tower/receiver CLOCK truth realisations vary across seeds.
            % Default (field absent) resolves to 0 -> seeds unchanged, byte-identical.
            % Spacing (harness uses j*1000) >> #clocks keeps the distinctness assert below.
            mcOff_ = 0;
            try; mcOff_ = round(cfg.simulation.mcSeedOffset); catch; end
            for k = 1:nT_req
                if isfield(cfg.towers(k),'clockType') && ...
                        isfield(cfg.towers(k),'clockFactors')
                    % Sync roleNoiseFactor from clockScaling before recreating
                    cfg.towers(k).clockFactors.roleNoiseFactor = ...
                        gs.towerNoiseFactor;
                    prev = cfg.towers(k).clock;
                    clk  = revgnss.ConfigFactory.makeClockConfig( ...
                        cfg.towers(k).clockType, 200+k+mcOff_, ...
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
                receiverSeed = 100 + mcOff_;
                if isfield(prev,'seed') && isnumeric(prev.seed) && ...
                        isscalar(prev.seed) && isfinite(prev.seed) && prev.seed ~= 100
                    % Preserve an explicitly configured local receiver-clock stream.
                    receiverSeed = prev.seed;
                end
                clk  = revgnss.ConfigFactory.makeClockConfig( ...
                    cfg.asset.clockType, receiverSeed, cfg.asset.clockFactors, gs);
                clk.name          = prev.name;
                clk.deterministic = prev.deterministic;
                clk.bias_s        = prev.bias_s;
                clk.fracFreq      = prev.fracFreq;
                cfg.asset.clock   = clk;
            end

            % Gated relativistic clock-rate offset on the TRUTH receiver clock. When
            % physics.relativity.clock.truth is enabled, set the receiver clock's constant
            % relativistic fractional-frequency offset from the orbit (revgnss.Relativity);
            % it accumulates as a linear clock-bias ramp in the truth pseudorange. Default
            % OFF -> field stays 0 -> golden byte-identical.
            relClkTruth_ = false;
            try; relClkTruth_ = logical(cfg.physics.relativity.clock.truth.enable); catch; end
            if relClkTruth_ && isfield(cfg,'asset') && isfield(cfg.asset,'clock')
                alt_ = 35786000;
                try; alt_ = cfg.orbit.altitudeMean_m; catch; end
                cfg.asset.clock.relativisticFracFreq = revgnss.Relativity.geoClockFracFreq(alt_);
            end

            % ---- Receiver lever arms and auto-attitude ----------------------
            % Priority: custom 3×nR arms always win (any nR).
            %           Then auto-fill from 4-column cross pattern if nR<=4.
            %           Else require custom arms or error.
            % A single receiver has no lever-arm attitude information, but a
            % configured star tracker or inertial gyro still supports attitude states.
            nR_req      = cfg.scenario.nReceivers;
            defaultArms = [1 -1 0 0; 0 0 1 -1; 0.2 0.2 -0.2 -0.2];  % 3 × 4
            sensorAttitudeEnabled = false;
            try
                sensorAttitudeEnabled = logical(cfg.estimator.starTracker.enable) || ...
                    logical(cfg.estimator.imu.enable);
            catch
            end

            if nR_req < 1
                error('ConfigFactory:finalizeConfig', ...
                    'cfg.scenario.nReceivers must be >= 1 (got %d).', nR_req);
            end

            if nR_req == 1
                % Single receiver: zero lever arm, sensor attitude only.
                cfg.asset.receiverLeverArm_body_m              = [0; 0; 0];
                cfg.asset.receiverLeverArms_body_m             = [0; 0; 0];
                cfg.estimator.estimateAttitude                   = sensorAttitudeEnabled;
                cfg.estimator.estimateAngularRate                = false;
                cfg.estimator.estimateAttitudeFromPseudorange    = false;
                cfg.estimator.estimateAngularRateFromPseudorange = false;
            else
                % Multi-receiver: attitude is observable from pseudorange geometry.
                cfg.estimator.estimateAttitude                   = true;
                cfg.estimator.estimateAngularRate                = false;
                cfg.estimator.estimateAttitudeFromPseudorange    = true;
                cfg.estimator.estimateAngularRateFromPseudorange = false;
                try
                    if isfield(cfg.estimator,'attitude') && ...
                            isfield(cfg.estimator.attitude,'useCodePartials') && ...
                            ~cfg.estimator.attitude.useCodePartials
                        cfg.estimator.estimateAttitudeFromPseudorange = false;
                    end
                catch; end
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

            % ---- Tower survey errors --------------------------------
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
            jointGeometry = false;
            try; jointGeometry = strcmpi(cfg.multiAsset.mode,'joint'); catch; end
            if jointGeometry && isfield(cfg,'assets')
                for assetIdx_ = 1:numel(cfg.assets)
                    cfg.assets(assetIdx_).receiverLeverArms_body_m = ...
                        cfg.asset.receiverLeverArms_body_m;
                    cfg.assets(assetIdx_).receiverLeverArm_body_m = ...
                        cfg.asset.receiverLeverArm_body_m;
                end
            end
            cfg = revgnss.MultiAssetConfig.normalize(cfg);
            % One physical IMU belongs to each estimated spacecraft. The primary is
            % estimated in fast mode; joint mode marks every spacecraft as estimated.
            if isfield(cfg,'assets') && ~isempty(cfg.assets)
                for assetIdx_ = 1:numel(cfg.assets)
                    imuCfg_ = cfg.estimator.imu.truth;
                    imuCfg_.enable = imuOn && logical(cfg.assets(assetIdx_).estimated);
                    imuCfg_.seed = cfg.estimator.imu.truth.seed + 1009*(assetIdx_-1);
                    imuCfg_.sensorIdentifier = sprintf( ...
                        'spacecraft-%d:gyroscope',assetIdx_);
                    imuCfg_.biasStateIdentifier = sprintf( ...
                        'spacecraft-%d:gyroscope-bias',assetIdx_);
                    cfg.assets(assetIdx_).imu = imuCfg_;
                end
                cfg.asset = cfg.assets(1);
            end
            revgnss.ISLMeasurementBuilder.validateConfig(cfg);
            revgnss.TwoWayISLMeasurementBuilder.validateConfig(cfg);
            revgnss.InterSatelliteTimeTransferBuilder.validateConfig(cfg);
            revgnss.ISLTimingModel.validateConfig(cfg);
            revgnss.TWSTFTDiagnosticBuilder.validateConfig(cfg);
            revgnss.TwoWayTimeTransferBuilder.validateConfig(cfg);

            % --- Clock-seed independence contract (seed-independence refactor) ---
            % Every physical clock must own a distinct RNG seed so its noise
            % realization is independent of every other clock. Canonical seeds:
            % receiver=100, tower k=200+k, secondary asset ai=300+ai (assigned in
            % MultiAssetConfig.finalizeAsset_). assets(1) IS the receiver clock, so
            % it is counted once (via cfg.asset) and skipped in the assets loop.
            clkSeeds_ = [];
            if isfield(cfg,'asset') && isfield(cfg.asset,'clock') && isfield(cfg.asset.clock,'seed')
                clkSeeds_(end+1) = cfg.asset.clock.seed; %#ok<AGROW>
            end
            if isfield(cfg,'towers')
                for kSeed_ = 1:numel(cfg.towers)
                    if isfield(cfg.towers(kSeed_),'clock') && isfield(cfg.towers(kSeed_).clock,'seed')
                        clkSeeds_(end+1) = cfg.towers(kSeed_).clock.seed; %#ok<AGROW>
                    end
                end
            end
            if isfield(cfg,'assets')
                for aiSeed_ = 2:numel(cfg.assets)
                    if isfield(cfg.assets(aiSeed_),'clock') && isfield(cfg.assets(aiSeed_).clock,'seed')
                        clkSeeds_(end+1) = cfg.assets(aiSeed_).clock.seed; %#ok<AGROW>
                    end
                end
            end
            assert(numel(clkSeeds_) == numel(unique(clkSeeds_)), ...
                'ConfigFactory:duplicateClockSeed', ...
                ['Clock RNG seeds must be pairwise distinct so each clock is independent; ' ...
                 'got [%s]. Check receiver(100)/tower(200+k)/secondary-asset(300+ai) seeds.'], ...
                num2str(clkSeeds_));

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

            % --- Scientific profile, product contracts, and model coverage ---
            % All canonical config fields are owned here in finalizeConfig.

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
            % Reflect the actual higher-order iono model state honestly.
            if isfield(cfg,'errors') && isfield(cfg.errors,'ionosphere') && ...
                    isfield(cfg.errors.ionosphere,'higherOrder') && ...
                    isfield(cfg.errors.ionosphere.higherOrder,'enable') && ...
                    cfg.errors.ionosphere.higherOrder.enable
                cfg.effects.ionosphere.higherOrderStatus = 'boundedResidualTruthSide';
            end
            % Klobuchar IS shipped (models.atmosphere.Klobuchar, called from
            % EnvironmentModel.getIonoDelay on the tecGaussMarkov model side). Stamp the
            % status from the correction the config actually selects instead of the flat
            % 'notImplemented' this used to carry -- that literal contradicted both the
            % shipped kernel and the golden baseline's model.correction = 'klobuchar',
            % and it propagated into the toggle manifest and the report.
            if ~isfield(cfg.effects.ionosphere,'klobucharStatus')
                ionoCorrection_ = 'none';
                try; ionoCorrection_ = char(cfg.errors.ionosphere.model.correction); catch; end
                modelSideOn_ = false;
                try; modelSideOn_ = logical(cfg.errors.ionosphere.model.enable); catch; end
                if strcmpi(ionoCorrection_, 'klobuchar') && modelSideOn_
                    cfg.effects.ionosphere.klobucharStatus = 'appliedModelSideBroadcastClimatology';
                else
                    cfg.effects.ionosphere.klobucharStatus = 'notSelected';
                end
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


            % --- J2 unmodeled-dynamics process-noise tuning + consistency diagnostics ---
            % NOTE (clarity refactor 2.2): this is NOT an artificial "mismatch analysis"
            % subsystem. j2Rk4 truth + twoBody EKF is a legitimate MODELLING CHOICE (truth
            % includes J2; the EKF propagates two-body). The block below (a) tunes process
            % noise for the unmodeled J2 acceleration - LOAD-BEARING for the validated EKF,
            % must not be removed (see ReverseGNSSEKF process-noise) - and (b) records
            % consistency diagnostics that are redundant with residual/NIS. Config can no
            % longer manufacture a truth!=model mismatch (2.1 collapsed the dual toggles).

            % Compute representative J2 accel at initial GEO orbit state (equatorial, z=0).
            cfg82_j2Norm_ = 0;
            try
                if isfield(cfg.orbit, 'altitudeMean_m') && cfg.orbit.useOrbitPropagator
                    Re82_ = revgnss.Constants.EARTH_RADIUS_M;
                    r82_  = cfg.orbit.altitudeMean_m + Re82_;
                    a82_  = models.orbit.OrbitDynamics.j2Accel_mps2([r82_; 0; 0]);
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
                cfg.diagnostics.dynamicsMismatch.j2DefaultPolicy  = ...
                    'j2TruthJ2EstimatorSameForceFamily';
                cfg.diagnostics.dynamicsMismatch.j2ActiveByDefault = true;
                cfg.diagnostics.dynamicsMismatch.mismatchLabel    = ...
                    'same J2 force family';
            else
                cfg.diagnostics.dynamicsMismatch.j2DefaultPolicy  = 'twoBodyDefaultJ2Available';
                cfg.diagnostics.dynamicsMismatch.j2ActiveByDefault = false;
                cfg.diagnostics.dynamicsMismatch.mismatchLabel    = ...
                    'sameForceFamilyOrStationary';
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

            % Keep the honest canonical name a read-only MIRROR of the (possibly auto-scaled)
            % modelMismatch alias. Never write modelMismatch here: the EKF reads that field,
            % so mirroring one-way guarantees the resolved process noise Q is unchanged.
            cfg.estimator.processNoise.residualAccelerationUncertainty = ...
                cfg.estimator.processNoise.modelMismatch;

            % Hard-block a SILENT truth-vs-EKF dynamics FAMILY mismatch,
            % but ONLY when the run opts in via cfg.validation.enforceModelFamilyConsistency.
            % Keeping it opt-in stops it firing on legitimate reduced-dynamics or non-realistic
            % runners; the same-family default sets the flag true. assertModelFamilyConsistent
            % itself still allows an explicitly-labelled mismatch analysis. This is the single
            % chokepoint: runSingle -> ReverseGNSSSimulation.initialize -> finalizeConfig, so
            % every run path is covered transitively.
            enforceFam82_ = false;
            if isfield(cfg,'validation') && isfield(cfg.validation,'enforceModelFamilyConsistency')
                enforceFam82_ = logical(cfg.validation.enforceModelFamilyConsistency);
            end
            if enforceFam82_
                revgnss.GeoRealWorldScenarioGuard.assertModelFamilyConsistent(cfg);
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

            % --- Doppler dynamics and carrier product-covariance closure ---
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

            % --- Doppler/product-covariance correctness hardening ---
            % J2 ratio diagnostics: how much sigma_accel covers J2 rms and max.
            if cfg82_j2Norm_ > 0
                cfg.diagnostics.dynamicsMismatch.sigmaToRmsJ2Ratio = ...
                    cfg82_sigBase_ / max(cfg82_j2Norm_, 1e-20);
                cfg.diagnostics.dynamicsMismatch.sigmaToMaxJ2Ratio = ...
                    cfg82_sigBase_ / max(cfg82_j2Norm_, 1e-20);
                cfg.diagnostics.dynamicsMismatch.dynamicsProcessNoiseConsistencyNote = ...
                    sprintf('sigmaAccel/J2rms=%.2f; not fully absorbed — tolerated by configured process noise in synthetic validation', ...
                        cfg82_sigBase_ / max(cfg82_j2Norm_, 1e-20));
            else
                cfg.diagnostics.dynamicsMismatch.sigmaToRmsJ2Ratio = NaN;
                cfg.diagnostics.dynamicsMismatch.sigmaToMaxJ2Ratio = NaN;
                cfg.diagnostics.dynamicsMismatch.dynamicsProcessNoiseConsistencyNote = ...
                    'j2Norm=0; ratios not applicable';
            end

            % Carrier-Doppler cross-consistency: not implemented, explicitly guarded.
            if ~isfield(cfg.diagnostics,'carrierDoppler')
                cfg.diagnostics.carrierDoppler = struct();
            end
            if ~isfield(cfg.diagnostics.carrierDoppler,'consistencyStatus')
                cfg.diagnostics.carrierDoppler.consistencyStatus = 'notImplementedGuarded';
            end
            if ~isfield(cfg.diagnostics.carrierDoppler,'rmsDiff_mps')
                cfg.diagnostics.carrierDoppler.rmsDiff_mps = NaN;
            end

            % Doppler drift diagonal policy default (informational, used by DopplerMeasurementBuilder).
            if ~isfield(cfg.covariance.productClock,'dopplerDriftDiagonalPolicy')
                cfg.covariance.productClock.dopplerDriftDiagonalPolicy = 'trackingOnlyPlusBlock';
            end

            % Report freshness stage (overwritten below).
            cfg.diagnostics.reportStatusFreshnessStage = 84;

            % --- Descriptive synthetic validation campaign ---
            if ~isfield(cfg,'validation'); cfg.validation = struct(); end
            if ~isfield(cfg.validation,'scientificCampaign')
                cfg.validation.scientificCampaign = struct();
            end
            sc = cfg.validation.scientificCampaign;
            if ~isfield(sc,'enable');                   sc.enable   = false;            end
            if ~isfield(sc,'profile');                  sc.profile  = 'light';          end
            if ~isfield(sc,'seedList');                 sc.seedList = [85, 185, 285];   end
            if ~isfield(sc,'duration_s');               sc.duration_s = 900;            end
            if ~isfield(sc,'runNominal');               sc.runNominal              = true;  end
            if ~isfield(sc,'runL1Only');                sc.runL1Only               = true;  end
            if ~isfield(sc,'runDegradedClockProduct');  sc.runDegradedClockProduct = true;  end
            if ~isfield(sc,'runSlipInjection');         sc.runSlipInjection        = true;  end
            if ~isfield(sc,'runReducedTowerGeometry');  sc.runReducedTowerGeometry = false; end
            cfg.validation.scientificCampaign = sc;

            if ~isfield(cfg.validation,'statistics'); cfg.validation.statistics = struct(); end
            vs = cfg.validation.statistics;
            if ~isfield(vs,'nis'); vs.nis = struct(); end
            if ~isfield(vs.nis,'minSamplesPerGroup');  vs.nis.minSamplesPerGroup = 20; end
            if ~isfield(vs.nis,'confidenceLevel');     vs.nis.confidenceLevel    = 0.95; end
            if ~isfield(vs,'nees'); vs.nees = struct(); end
            if ~isfield(vs,'monteCarlo'); vs.monteCarlo = struct(); end
            if ~isfield(vs.monteCarlo,'enable'); vs.monteCarlo.enable = false; end
            cfg.validation.statistics = vs;

            if ~isfield(cfg.validation,'stress'); cfg.validation.stress = struct(); end
            vst = cfg.validation.stress;
            if ~isfield(vst,'slips'); vst.slips = struct(); end
            if ~isfield(vst.slips,'enable');       vst.slips.enable     = false; end
            if ~isfield(vst,'clockProduct'); vst.clockProduct = struct(); end
            if ~isfield(vst.clockProduct,'scaleBiasSigma');  vst.clockProduct.scaleBiasSigma  = 3; end
            if ~isfield(vst.clockProduct,'scaleDriftSigma'); vst.clockProduct.scaleDriftSigma = 3; end
            cfg.validation.stress = vst;

            cfg.diagnostics.reportStatusFreshnessStage = 85;

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

        function tmpl = getClockTemplate_(templateName, templateSource)
            % getClockTemplate_  Return base h-coefficient struct for a clock type.
            %
            % h-values are one-sided PSD of fractional frequency.
            % References: IEEE Std 1139-2008; Sesia et al.; GPS ICD.
            %
            % templateSource: 'legacy' (default here — the original numbers, kept
            % for exact reproducibility of past results) or 'jowTable2p1' (h-coefficients
            % re-anchored to the project primary-source JOW Table 2.1; less optimistic).
            % The canonical selector is cfg.clock.templateSource, threaded through
            % makeClockConfig -> cfg.clockScaling.templateSource.
            if nargin < 2 || isempty(templateSource); templateSource = 'legacy'; end
            switch lower(templateSource)
                case 'jowtable2p1'
                    tmpl = revgnss.ConfigFactory.getClockTemplateJow_(templateName);
                    return
                case 'legacy'
                    % fall through to the legacy table below
                otherwise
                    error('ConfigFactory:invalidTemplateSource', ...
                        'cfg.clock.templateSource must be ''legacy'' or ''jowTable2p1''; got ''%s''.', ...
                        templateSource);
            end

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

                case 'CESIUM1'
                    % Cesium beam / hydrogen maser class (excellent stability)
                    tmpl.h2      = 0;
                    tmpl.h1      = 0;
                    tmpl.h0      = 1e-26;
                    tmpl.hMinus1 = 1e-28;
                    tmpl.hMinus2 = 1e-30;

                case 'ZERO'
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

        function tmpl = getClockTemplateJow_(templateName)
            % getClockTemplateJow_  h-coefficients re-anchored to JOW Table 2.1.
            %
            % The legacy OCXO/CESIUM templates are optimistic versus the project's own
            % primary-source analogue (JOW Table 2.1): the OCXO random-walk-FM term
            % hMinus2 (which dominates the Allan deviation at long averaging times and
            % drives the Sg*dt^3/3 growth of clock-bias variance between updates) was
            % 2e-29, and CESIUM1 h0 was ~7 orders below a real caesium beam. Those make
            % the clock look more stable over a pass than the real hardware.
            %
            % h-values are one-sided PSD of fractional frequency (IEEE Std 1139-2008
            % power-law convention). Sources are cited per coefficient below.
            switch upper(templateName)
                case 'TCXO'
                    % Aligned to JOW Table 2.1 TCXO; already close to the legacy values.
                    tmpl.h2      = 0;
                    tmpl.h1      = 0;
                    tmpl.h0      = 9e-22;     % WFM  (JOW Table 2.1)
                    tmpl.hMinus1 = 2e-21;     % FFM
                    tmpl.hMinus2 = 1e-20;     % RWFM

                case 'OCXO'
                    % JOW Table 2.1 OCXO2 (conservative long-term choice). The RWFM term
                    % is the re-anchored coefficient: hMinus2 = 2.51e-22 (JOW OCXO2),
                    % NOT the optimistic legacy 2e-29 (JOW OCXO1 = 4e-23 is the less
                    % pessimistic alternative). h0/hMinus1 retained from the legacy OCXO
                    % (JOW does not flag them as optimistic and they set only the short-
                    % term/flicker floor, not the long-term random walk).
                    tmpl.h2      = 0;
                    tmpl.h1      = 0;
                    tmpl.h0      = 2e-25;     % WFM  (retained; short-term floor)
                    tmpl.hMinus1 = 7e-27;     % FFM  (retained)
                    tmpl.hMinus2 = 2.51e-22;  % RWFM (JOW Table 2.1 OCXO2 — re-anchored)

                case 'RUBIDIUM'
                    % Aligned to JOW Table 2.1 rubidium; already close to legacy.
                    tmpl.h2      = 0;
                    tmpl.h1      = 0;
                    tmpl.h0      = 1e-22;     % WFM
                    tmpl.hMinus1 = 4.5e-24;   % FFM
                    tmpl.hMinus2 = 3e-28;     % RWFM

                case 'CESIUM1'
                    % JOW Table 2.1 Cesium1 (caesium beam): white-FM dominated short term,
                    % very stable long term. h0 re-anchored ~7 orders up from the legacy
                    % 1e-26 (which behaved like an idealised maser, not a caesium beam).
                    tmpl.h2      = 0;
                    tmpl.h1      = 0;
                    tmpl.h0      = 1e-19;     % WFM  (JOW Table 2.1 Cesium1 — re-anchored)
                    tmpl.hMinus1 = 1e-25;     % FFM  (JOW Table 2.1 Cesium1)
                    tmpl.hMinus2 = 2e-32;     % RWFM (JOW Table 2.1 Cesium1)

                case 'ZERO'
                    tmpl.h2      = 0;
                    tmpl.h1      = 0;
                    tmpl.h0      = 0;
                    tmpl.hMinus1 = 0;
                    tmpl.hMinus2 = 0;

                otherwise
                    warning('ConfigFactory:unknownTemplate', ...
                        'Unknown clock template "%s"; defaulting to OCXO (jowTable2p1).', templateName);
                    tmpl = revgnss.ConfigFactory.getClockTemplateJow_('OCXO');
                    return
            end

            % Shared fields for all templates
            tmpl.bias_s   = 0.0;
            tmpl.fracFreq = 0.0;
            tmpl.driftRate_fracPerSec = 0.0;
        end

        function saa = angAccelFromTorqueBudget_(inertia_kgm2, torque_Nm)
            % angAccelFromTorqueBudget_  Angular-acceleration 1-sigma [rad/s^2] from a
            % residual disturbance-torque budget: alpha = tau / I  (Euler's equation,
            % single-axis). Used to set a physically defensible cfg.estimator.
            % sigma_angAccel_radps2 for attitude-estimating presets instead of an
            % over-optimistic literal. Source for the environmental-torque magnitudes:
            % Wertz, "Spacecraft Attitude Determination and Control", 1978 (gravity-
            % gradient, solar-radiation-pressure, residual-magnetic, aerodynamic torques
            % — at GEO SRP dominates). Choose the conservative (higher) torque / lower
            % inertia end so the attitude process noise is not under-modelled.
            %   inertia_kgm2  principal moment of inertia [kg m^2] (> 0)
            %   torque_Nm     residual (unmodelled) disturbance torque 1-sigma [N m]
            assert(isscalar(inertia_kgm2) && inertia_kgm2 > 0 && isfinite(inertia_kgm2), ...
                'ConfigFactory:angAccelInertia', 'inertia_kgm2 must be a positive finite scalar');
            saa = torque_Nm / inertia_kgm2;
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
