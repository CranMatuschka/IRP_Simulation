classdef ScenarioPresets
    % ScenarioPresets  Named scenario preset configurations.
    %
    % Supported scenario names:
    %   'default'                   — config unchanged.
    %   'singleAssetCarrierAttitude' — single-space-asset multi-antenna float-carrier attitude.
    %   'geoRealWorldTruthComparison' — GEO closed-loop truth comparison.
    %
    % Usage:
    %   cfg = revgnss.ConfigFactory.defaultConfig();
    %   cfg = revgnss.ScenarioPresets.apply(cfg, 'singleAssetCarrierAttitude');
    %   cfg = revgnss.ScenarioPresets.apply(cfg, 'geoRealWorldTruthComparison');

    methods (Static)

        function cfg = apply(cfg, scenarioName)
            % apply  Apply named scenario preset to config.
            if nargin < 2 || isempty(scenarioName); scenarioName = 'default'; end
            switch scenarioName
                case 'default'
                    % No changes.
                case 'singleAssetCarrierAttitude'
                    cfg = revgnss.ScenarioPresets.singleAssetCarrierAttitude(cfg);
                case 'geoRealWorldTruthComparison'
                    cfg = revgnss.ScenarioPresets.geoRealWorldTruthComparison(cfg);
                otherwise
                    warning('ScenarioPresets:unknownScenario', ...
                        'Unknown scenario ''%s''; config unchanged.', scenarioName);
            end
        end

        function cfg = singleAssetCarrierAttitude(cfg)
            % singleAssetCarrierAttitude  Single-asset multi-antenna float-carrier attitude.
            %
            % Configures one estimated space asset with a 4-receiver non-collinear
            % cross-pattern geometry, carrier attitude partials, EKF float ambiguities,
            % arc-separated ambiguities, and enforced carrier arc consistency.
            % Truth-estimation separation: j2Rk4 truth propagator (J2-perturbed RK4) + j2 EKF
            %   dynamics — SAME model family (not a mismatch). Estimator error comes from
            %   realistic sources (init state/covariance, measurement/clock/atmosphere noise,
            %   float ambiguities, residual-acceleration process noise), never a degraded model.
            % Raw dual-frequency (L1+L2) baseline attitude ambiguity resolution is supported
            %   in controlled synthetic form. Carrier-IF integer fixing is explicitly
            %   unsupported. LAMBDA/MLAMBDA, calibrated phase-bias products, and
            %   PPP-grade claims are not implemented. Multi-space-asset is guarded.

            msg79_ = ['Multi-space-asset estimation is unsupported in oo_v1 active scenario. ' ...
                'This stage intentionally does not truncate assets.'];
            if isfield(cfg,'scenario') && isfield(cfg.scenario,'nSpaceAssets') && cfg.scenario.nSpaceAssets > 1
                error('ScenarioPresets:multiAssetUnsupported', '%s', msg79_);
            end
            if isfield(cfg,'assets') && numel(cfg.assets) > 1
                error('ScenarioPresets:multiAssetUnsupported', '%s', msg79_);
            elseif ~isfield(cfg,'assets')
                cfg.assets = cfg.asset;
            end

            nReq79_ = 4;
            if isfield(cfg,'scenario') && isfield(cfg.scenario,'nReceivers') && cfg.scenario.nReceivers > 1
                nReq79_ = cfg.scenario.nReceivers;
            end
            arms = [];
            if isfield(cfg,'asset') && isfield(cfg.asset,'receiverLeverArms_body_m')
                cand79_ = cfg.asset.receiverLeverArms_body_m;
                if isnumeric(cand79_) && size(cand79_,1) == 3 && size(cand79_,2) > 1
                    arms = cand79_;
                end
            end
            if ~isempty(arms) && size(arms,2) ~= nReq79_
                error('ScenarioPresets:receiverGeometryMismatch', ...
                    'cfg.scenario.nReceivers=%d but receiverLeverArms_body_m has %d columns.', ...
                    nReq79_, size(arms,2));
            end
            if isempty(arms)
                arms = revgnss.ReceiverGeometry.defaultLeverArms(nReq79_);
            end

            cfg.scenario.name         = 'singleAssetCarrierAttitude';
            cfg.scenario.nSpaceAssets = 1;
            cfg.scenario.nReceivers   = size(arms,2);
            cfg.asset.receiverLeverArms_body_m = arms;
            cfg.asset.receiverLeverArm_body_m  = arms(:,1);
            cfg.assets(1).receiverLeverArms_body_m = arms;
            cfg.assets(1).receiverLeverArm_body_m  = arms(:,1);

            % Attitude estimation. Use preferred controls exclusively so the
            % legacy estimateAttitudeFromPseudorange flag does not cause H/metadata
            % inconsistencies (code rows must not declare attitude sensitivity while
            % H attitude columns are zero).
            cfg.estimator.estimateAttitude                    = true;
            cfg.estimator.estimateAngularRate                 = false;
            cfg.estimator.estimateAttitudeFromPseudorange     = false; % code OFF via preferred
            cfg.estimator.estimateAngularRateFromPseudorange  = false;
            cfg.estimator.attitude.useCarrierPartials         = true;  % preferred: carrier ON
            cfg.estimator.attitude.useCodePartials            = false; % preferred: code OFF
            cfg.estimator.attitude.useDopplerPartials         = false; % preferred: Doppler OFF

            % Initial attitude covariance and error.
            cfg.estimator.P0_euler_rad              = deg2rad(5);
            cfg.estimator.P0_omega_radps            = 1e-12;
            % Torque-budget-justified attitude process noise (~1e-7 rad/s^2),
            % replacing the over-optimistic 1e-10. alpha = tau / I (Wertz).
            cfg.estimator.sigma_angAccel_radps2     = revgnss.ConfigFactory.angAccelFromTorqueBudget_( ...
                cfg.asset.inertia_kgm2, cfg.asset.residualDisturbanceTorque_Nm);
            cfg.estimator.initialError.euler_deg    = [1; -1; 0.5];
            cfg.estimator.initialError.omega_radps  = [0; 0; 0];

            % Carrier measurements and ambiguity mode.
            cfg.measurements.carrierPhase.enable = true;
            cfg.measurements.carrierMode         = 'ekfFloat';
            cfg.estimation.ambiguityMode         = 'floatPerTowerReceiverSignal';

            % Carrier slip detection (keep defaults if already set).
            cfg.measurements.carrier.slipDetection.enable = true;
            if ~isfield(cfg.measurements.carrier.slipDetection,'threshold_m')
                cfg.measurements.carrier.slipDetection.threshold_m           = 0.1;
                cfg.measurements.carrier.slipDetection.minEpochsBeforeDetect = 3;
                cfg.measurements.carrier.slipDetection.resetSigma_m          = 100;
                cfg.measurements.carrier.slipDetection.action                = 'resetAndSkip';
            end

            % Arc-separated ambiguities; cross-frequency enforcement is unavailable.
            cfg.estimator.arcSeparatedAmbiguities.enable             = true;
            cfg.estimator.enforceCarrierArcConsistency.enable        = false;
            cfg.diagnostics.arcSeparatedAmbiguities.enable           = true;
            cfg.diagnostics.carrierArcConsistencyEnforcement.enable  = false;
            cfg.diagnostics.carrierArcEvidence.enable                = true;

            % Observability and geometry diagnostics.
            cfg.diagnostics.attitudeObservability.enable = true;
            cfg.diagnostics.receiverGeometry.enable      = true;
            cfg.diagnostics.ekfInnovationAccounting.enable = true;
            if isfield(cfg,'diagnostics') && isfield(cfg.diagnostics,'attitudeEvidence')
                cfg.diagnostics.attitudeEvidence.enable = true;
            end

            % Truth-estimation separation (SAME model family): j2Rk4 truth + j2 EKF dynamics.
            % Truth and estimator share the J2 family; the estimator is imperfect for realistic
            % reasons only (initial state/covariance, measurement/clock/atmosphere noise, float
            % ambiguities, residual-acceleration process noise), not a degraded propagator.
            % At GEO equatorial the J2 accel is ~8.3e-6 m/s2 (radial only). cfg.orbit.truth.mode
            % is centrally owned. Orbit is GEO (35786 km, equatorial).
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
            cfg.estimator.dynamics.mode  = 'j2';   % SAME family as truth (truth-estimation separation)
            cfg.validation.enforceModelFamilyConsistency = true;   % both J2: enforce parity

            % Stochastic tower clocks with non-perfect broadcast correction.
            % Each tower clock is driven by the Brown-Hwang two-state process.
            % The EKF uses noisyCorrection: broadcast product with uncertainty sigma.
            for k = 1:numel(cfg.towers)
                cfg.towers(k).clock.deterministic = false;
            end

            % Disable ISL/TWSTFT: single-asset scenario has no inter-spacecraft links.
            if isfield(cfg,'measurements') && isfield(cfg.measurements,'isl')
                cfg.measurements.isl.enable = false;
                % TwoWayISLMeasurementBuilder.validateConfig requires isl.enable=true
                % when twoWay.enable=true, so we must also disable twoWay.
                if isfield(cfg.measurements.isl,'twoWay')
                    cfg.measurements.isl.twoWay.enable = false;
                    if isfield(cfg.measurements.isl.twoWay,'range')
                        cfg.measurements.isl.twoWay.range.enable = false;
                        cfg.measurements.isl.twoWay.range.useInEKF = false;
                    end
                    if isfield(cfg.measurements.isl.twoWay,'doppler')
                        cfg.measurements.isl.twoWay.doppler.enable = false;
                        cfg.measurements.isl.twoWay.doppler.useInEKF = false;
                    end
                end
                if isfield(cfg.measurements.isl,'timing')
                    cfg.measurements.isl.timing.enable = false;
                end
            end
            if isfield(cfg,'measurements') && isfield(cfg.measurements,'twstft')
                cfg.measurements.twstft.enable = false;
            end
        end

        function cfg = geoRealWorldTruthComparison(cfg)
            % geoRealWorldTruthComparison  GEO closed-loop truth comparison.
            %
            % Truth and EKF use the same J2 mean dynamics. Innovations are driven by
            % seeded stochastic residuals and by estimation error, not by a deliberate
            % truth/model force mismatch or truth-derived calibration.

            cfg.scenario.name         = 'geoRealWorldTruthComparison';
            cfg.scenario.orbitClass   = 'GEO';
            cfg.scenario.nSpaceAssets = 1;
            cfg.scenario.nReceivers   = 4;
            cfg.scenario.nTowers      = max(5, cfg.scenario.nTowers);

            arms = [ ...
                 1.20  -1.05   0.15  -0.35; ...
                -0.15   0.35   1.10  -1.25; ...
                 0.35  -0.25   0.70  -0.55 ];
            cfg.asset.receiverLeverArms_body_m = arms;
            cfg.asset.receiverLeverArm_body_m  = arms(:,1);
            cfg.assets = cfg.asset;

            cfg.estimator.estimateAttitude                   = true;
            cfg.estimator.estimateAngularRate                = false;
            cfg.estimator.estimateAttitudeFromPseudorange    = false;
            cfg.estimator.estimateAngularRateFromPseudorange = false;
            cfg.estimator.attitude.useCarrierPartials        = true;
            cfg.estimator.attitude.useCodePartials           = false;
            cfg.estimator.attitude.useDopplerPartials        = false;
            cfg.estimator.attitude.parameterization          = 'quaternionErrorState';
            cfg.estimator.attitudeCarrierMode                = 'off';
            cfg.estimator.attitudeInitMode                   = 'none';
            cfg.estimator.knownAmbiguityAttitudeValidation   = false;

            cfg.orbit.useOrbitPropagator = true;
            cfg.orbit.altitudeMean_m     = 35786000;
            cfg.orbit.inclination_rad    = 0;
            cfg.orbit.raan_rad           = 0;
            cfg.orbit.trueAnomaly0_rad   = 23 * pi/180;
            cfg.orbit.epochGMST_rad      = 0;
            cfg.orbit.truth.mode         = 'j2Rk4';
            cfg.orbit.mode               = 'j2Rk4';
            cfg.estimator.dynamics.mode  = 'j2';

            cfg.estimator.sigma_accel_mps2 = 1e-6;
            cfg.estimator.processNoise.modelMismatch.enable = false;
            cfg.estimator.processNoise.modelMismatch.sigma_mps2 = 0;
            % Torque-budget-justified attitude process noise (~1e-7 rad/s^2),
            % replacing the over-optimistic 1e-9. alpha = tau / I (Wertz).
            cfg.estimator.sigma_angAccel_radps2 = revgnss.ConfigFactory.angAccelFromTorqueBudget_( ...
                cfg.asset.inertia_kgm2, cfg.asset.residualDisturbanceTorque_Nm);

            cfg.estimator.P0_pos_m       = 3000;
            cfg.estimator.P0_vel_mps     = 1.0;
            cfg.estimator.P0_euler_rad   = deg2rad(10);
            cfg.estimator.P0_omega_radps = 1e-5;
            cfg.estimator.P0_bRx_m       = 300;
            cfg.estimator.P0_bdotRx_mps  = 0.05;
            cfg.estimator.initialError.pos_m          = [900; -650; 350];
            cfg.estimator.initialError.vel_mps        = [0.12; -0.08; 0.04];
            cfg.estimator.initialError.euler_deg      = [4; -3; 2];
            cfg.estimator.initialError.omega_radps    = [0; 0; 0];
            cfg.estimator.initialError.clockBias_m    = 120;
            cfg.estimator.initialError.clockDrift_mps = 0.02;

            cfg.asset.clock.deterministic = false;
            cfg.clock.receiver.deterministic = false;
            cfg.asset.clockType = 'OCXO';
            cfg.asset.clockFactors.hMinus2Factor = max(10, cfg.asset.clockFactors.hMinus2Factor);
            for k = 1:numel(cfg.towers)
                cfg.towers(k).clock.deterministic = false;
                cfg.towers(k).clock.bias_s   = (k-1) * 2e-8;
                cfg.towers(k).clock.fracFreq = k * 1e-12;
            end
            cfg.clocks.tower.deterministic = false;
            cfg.towerClock.correctionMode = 'truthHistoryProductNoisy';
            cfg.clocks.tower.product.mode = 'truthHistoryProductNoisy';
            cfg.clocks.tower.product.updateInterval_s = 30;
            cfg.clocks.tower.product.latency_s = 5;
            cfg.clocks.tower.product.sigmaBias_m = 0.10;
            cfg.clocks.tower.product.sigmaDrift_mps = 1e-3;
            cfg.clocks.tower.product.covBiasDrift = 0;
            cfg.clocks.tower.product.validity_s = 120;
            cfg.clocks.tower.product.addToR = true;
            cfg.clocks.tower.product.sharedErrorCorrelation = true;
            cfg.estimator.towerClockMode = 'truthHistoryProductNoisy';

            cfg.measurement.sigmaFloor_m = 0.01;
            cfg.errors.codeNoise.sigma_m = 0.60;
            cfg.signals.L1.codeSigma0_m = 0.60;
            cfg.signals.L2.codeSigma0_m = 0.90;
            cfg.measurements.codeNoise.model = 'constant';
            cfg.measurements.codeNoise.cn0.sigmaAt45dBHz_m = 0.60;
            cfg.measurements.doppler.enable = true;
            cfg.measurements.doppler.useInEKF = true;
            cfg.measurements.doppler.sigma_mps = 0.03;
            cfg.physics.doppler.truth.enable = true;
            cfg.physics.doppler.model.enable = true;
            cfg.measurements.carrierPhase.enable = true;
            cfg.measurements.carrierMode = 'ekfFloat';
            cfg.measurements.carrierCombinationMode = 'raw';
            cfg.measurements.carrier.sigma_m = 0.010;
            cfg.measurements.carrierPhase.sigma_cycles = ...
                cfg.measurements.carrier.sigma_m / cfg.measurements.carrierPhase.lambda_m;
            cfg.estimation.ambiguityMode = 'floatPerTowerReceiverSignal';

            cfg.carrierSlip.enable = true;
            cfg.carrierSlip.method = 'modelStepCompensatedResidualJump';
            cfg.carrierSlip.threshold_m = 0.15;
            cfg.carrierSlip.syntheticSlipInjection.enable = false;
            cfg.measurements.carrier.slipDetection.enable = true;
            cfg.measurements.carrier.slipDetection.threshold_m = 0.15;
            cfg.measurements.carrier.syntheticSlipProbability = 0;
            cfg.validation.stress.slips.enable = false;

            cfg.errors.troposphere.truth.enable = true;
            cfg.errors.troposphere.model.enable = true;
            cfg.errors.troposphere.modelType = 'simpleMapped';
            cfg.errors.troposphere.stochastic.enable = true;
            cfg.errors.troposphere.stochastic.sigmaWet_ss_m = 0.08;
            cfg.errors.troposphere.stochastic.sigmaModelResidual_m = 0.05;
            cfg.errors.troposphere.stochastic.modelResidual.enable = true;
            cfg.errors.troposphere.stochastic.modelResidual.mode = 'seededTruthResidual';

            cfg.errors.ionosphere.truth.enable = true;
            cfg.errors.ionosphere.model.enable = true;
            cfg.errors.ionosphere.modelType = 'simpleMapped';
            cfg.errors.ionosphere.stochastic.enable = true;
            cfg.errors.ionosphere.stochastic.sigmaVDelayL1_ss_m = 2.0;
            cfg.errors.ionosphere.stochastic.sigmaModelResidualL1_m = 1.0;
            cfg.errors.ionosphere.stochastic.modelResidual.enable = true;
            cfg.errors.ionosphere.stochastic.modelResidual.mode = 'seededTruthResidual';
            cfg.errors.ionosphere.scintillation.enable = true;
            cfg.errors.ionosphere.scintillation.sigmaCodeL1_m = 0.50;

            cfg.errors.hardwareDelay.truth.enable = true;
            cfg.errors.hardwareDelay.truth.default_m = 0.0;
            cfg.errors.hardwareDelay.model.enable = true;
            cfg.errors.hardwareDelay.model.default_m = 0.0;
            cfg.errors.hardwareDelay.sigma_m = 0.20;
            cfg.errors.hardwareDelay.residualStochastic.enable = true;

            cfg.errors.multipath.truth.enable = true;
            cfg.errors.multipath.truth.amplitude_m = 0.05;
            cfg.errors.multipath.truth.stochastic_sigma_m = 0.20;
            cfg.errors.multipath.sigma_m = 0.20;

            cfg.effects.antennaPCO.truth.enable = true;
            cfg.effects.antennaPCO.model.enable = true;
            cfg.effects.antennaPCO.receiverOffset_body_m = [0.02; -0.01; 0.03];
            cfg.effects.antennaPCO.towerOffset_enu_m = [0.01; 0.00; 0.02];
            cfg.effects.antennaPCV.truth.enable = false;
            cfg.effects.antennaPCV.model.enable = false;
            cfg.effects.towerSurvey.truth.enable = true;
            cfg.effects.towerSurvey.model.enable = true;
            cfg.effects.towerSurvey.sigmaENU_m = [0.02; 0.02; 0.05];

            cfg.covariance.sharedErrors.enable = true;
            % 'sharedTowerClockProductFullStack' was never a value ConfigFactory or any
            % physics reader recognised -- it described intent, not a dispatched shape.
            % ConfigFactory.finalizeConfig now VALIDATES this key (only
            % 'blockTowerClockProduct' or 'none'); migrate to the accepted name for the
            % one shape that has ever existed, or finalizeConfig throws.
            cfg.covariance.sharedErrors.mode = 'blockTowerClockProduct';
            cfg.covariance.sharedErrors.applyTowerClockToCode = true;
            cfg.covariance.sharedErrors.applyTowerClockToCarrier = true;
            cfg.covariance.sharedErrors.applyTowerClockToDoppler = true;
            cfg.covariance.sharedErrors.jitter_m2 = 1e-12;
            cfg.covariance.productClock.enable = true;
            cfg.covariance.productClock.applyToCode = true;
            cfg.covariance.productClock.applyToDoppler = true;
            cfg.covariance.productClock.applyToCarrier = true;
            cfg.covariance.productClock.crossCodeDoppler = true;
            cfg.covariance.productClock.ensureSPD = true;
            cfg.covariance.productClock.jitter_m2 = 1e-12;

            cfg.measurements.isl.enable = false;
            cfg.measurements.isl.twoWay.enable = false;
            cfg.measurements.twstft.enable = false;
            cfg.estimator.integerAmbiguityFixing.enable = false;
            cfg.estimator.arcSeparatedAmbiguities.enable = true;
            cfg.estimator.enforceCarrierArcConsistency.enable = false;
            cfg.diagnostics.carrierArcConsistencyEnforcement.enable = false;

            cfg.validation.unsupportedFeaturePolicy = 'error';
            cfg.validation.synthetic = true;
            cfg.validation.allowTruthModelMismatch = false;
            cfg.scientificProfile.mode = 'geoRealisticTruthComparisonV1';
            cfg.scientificProfile.claimLevel = 'realisticSimulationTruthComparison';
            cfg.scientificProfile.allowRealWorldClaim = false;
            cfg.diagnostics.stage86.forceModelLimitation = ...
                ['Force model is J2-only; lunisolar third-body and solar radiation ' ...
                 'pressure are not modelled. Process noise represents residual ' ...
                 'acceleration uncertainty, not those forces. Not a POD product.'];
        end

        function lines = summaryLines(cfg)
            % summaryLines  Report-ready lines for the active scenario preset.
            lines = {};
            name_ = '';
            if isfield(cfg,'scenario') && isfield(cfg.scenario,'name')
                name_ = cfg.scenario.name;
            end
            lines{end+1} = sprintf('Scenario preset      : %s', name_);
            if strcmp(name_, 'singleAssetCarrierAttitude')
                nRx_ = 4;
                if isfield(cfg,'scenario') && isfield(cfg.scenario,'nReceivers')
                    nRx_ = cfg.scenario.nReceivers;
                end
                lines{end+1} = sprintf('Receivers            : %d multi-antenna', nRx_);
                lines{end+1} = 'Carrier partials     : enabled';
                lines{end+1} = 'Code partials        : disabled';
                lines{end+1} = 'Doppler partials     : disabled';
                lines{end+1} = 'ISL / TWSTFT         : disabled';
                lines{end+1} = 'EKF dynamics         : j2 (j2Rk4 truth / j2 EKF, SAME family; residual-acceleration process noise sigma_accel=0.01 m/s2; GEO equatorial)';
                lines{end+1} = 'Integer fixing        : false';
                lines{end+1} = 'LAMBDA/MLAMBDA        : false';
                lines{end+1} = 'False-fix-risk control: false';
                lines{end+1} = 'PPP-grade claim       : false';
            elseif strcmp(name_, 'geoRealWorldTruthComparison')
                lines{end+1} = 'EKF dynamics         : same J2 force family in truth and estimator; no intentional force-family stressor.';
                lines{end+1} = 'Clock products       : simulated noisy product; no perfect tower-clock correction.';
                lines{end+1} = 'Ambiguities          : float carrier ambiguities only.';
                lines{end+1} = 'Force limitation     : J2-only; no SRP, third bodies, EOP, SP3/CLK, ANTEX, IONEX, VMF3, or GPT3.';
            end
        end

    end
end
