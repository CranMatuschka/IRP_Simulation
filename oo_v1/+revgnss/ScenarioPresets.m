classdef ScenarioPresets
    % ScenarioPresets  Named scenario preset configurations.
    %
    % Supported scenario names:
    %   'default'                   — config unchanged.
    %   'singleAssetCarrierAttitude' — single-space-asset multi-antenna float-carrier attitude.
    %
    % Usage:
    %   cfg = revgnss.ConfigFactory.defaultConfig();
    %   cfg = revgnss.ScenarioPresets.apply(cfg, 'singleAssetCarrierAttitude');

    methods (Static)

        function cfg = apply(cfg, scenarioName)
            % apply  Apply named scenario preset to config.
            if nargin < 2 || isempty(scenarioName); scenarioName = 'default'; end
            switch scenarioName
                case 'default'
                    % No changes.
                case 'singleAssetCarrierAttitude'
                    cfg = revgnss.ScenarioPresets.singleAssetCarrierAttitude(cfg);
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
            % Stage 67+: uses twoBodyRk4 truth propagator with matched twoBody EKF dynamics.
            % Stage 76: raw dual-frequency (L1+L2) baseline attitude AR is supported
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

            % Attitude estimation. Use preferred Stage 56 controls exclusively so the
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
            cfg.estimator.sigma_angAccel_radps2     = 1e-10;
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

            % Stage 53/54: arc-separated ambiguities and arc consistency enforcement.
            cfg.estimator.arcSeparatedAmbiguities.enable             = true;
            cfg.estimator.enforceCarrierArcConsistency.enable        = true;
            cfg.diagnostics.arcSeparatedAmbiguities.enable           = true;
            cfg.diagnostics.carrierArcConsistencyEnforcement.enable  = true;
            cfg.diagnostics.carrierArcEvidence.enable                = true;

            % Observability and geometry diagnostics.
            cfg.diagnostics.attitudeObservability.enable = true;
            cfg.diagnostics.receiverGeometry.enable      = true;
            cfg.diagnostics.ekfInnovationAccounting.enable = true;
            if isfield(cfg,'diagnostics') && isfield(cfg.diagnostics,'attitudeEvidence')
                cfg.diagnostics.attitudeEvidence.enable = true;
            end

            % Stage 80: truth propagation is centrally owned by cfg.orbit.truth.mode.
            % Default active run remains matched twoBodyRk4/twoBody for validation
            % stability; j2Rk4 is available by config without changing downstream code.
            % Orbit is GEO (35786 km, equatorial). GEO in ECEF moves very slowly
            % (orbital period ≈ Earth rotation period) so twoBody is nearly equivalent
            % to static ECEF but physically correct.
            cfg.orbit.useOrbitPropagator = true;
            cfg.orbit.altitudeMean_m     = 35786000;
            cfg.orbit.inclination_rad    = 0;
            cfg.orbit.raan_rad           = 0;
            cfg.orbit.trueAnomaly0_rad   = 23 * pi/180;
            cfg.orbit.epochGMST_rad      = 0;
            if ~isfield(cfg.orbit,'truth') || ~isfield(cfg.orbit.truth,'mode') || ...
                    strcmp(cfg.orbit.truth.mode,'stationaryEcef')
                cfg.orbit.truth.mode = 'twoBodyRk4';
            end
            cfg.orbit.mode               = cfg.orbit.truth.mode;
            cfg.estimator.dynamics.mode  = 'twoBody';

            % Stage 67: stochastic tower clocks — non-perfect broadcast correction.
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
                lines{end+1} = 'EKF dynamics         : twoBody (matched twoBodyRk4 truth propagator; GEO equatorial)';
                lines{end+1} = 'Integer fixing        : false';
                lines{end+1} = 'LAMBDA/MLAMBDA        : false';
                lines{end+1} = 'False-fix-risk control: false';
                lines{end+1} = 'PPP-grade claim       : false';
            end
        end

    end
end
