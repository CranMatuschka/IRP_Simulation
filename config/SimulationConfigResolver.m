classdef SimulationConfigResolver
    %SIMULATIONCONFIGRESOLVER Normalizes legacy and string error settings.
    %
    % This resolver is intentionally passive: it converts SimulationConfig
    % fields into one canonical internal struct without changing existing
    % simulation behaviour. Later refactors can consume resolved.errors while
    % keeping the legacy fields available for backward compatibility.

    methods (Static)
        function resolved = resolve(simConfig)
            if nargin < 1 || ~isstruct(simConfig)
                error('SimulationConfigResolver:InvalidConfig', ...
                    'simConfig must be a struct.');
            end

            scenario = SimulationConfigResolver.activeScenario(simConfig);

            resolved = struct();
            resolved.scenarioName = string( ...
                SimulationConfigResolver.getFieldOrDefault( ...
                scenario, 'name', "reverseGnssClockNavigationScenario"));
            resolved.errors = struct();

            resolved.errors.measurementNoise = ...
                SimulationConfigResolver.resolveMeasurementNoise(scenario);
            resolved.errors.ionosphere = ...
                SimulationConfigResolver.resolveAtmosphereComponent( ...
                scenario, "ionosphere");
            resolved.errors.troposphere = ...
                SimulationConfigResolver.resolveAtmosphereComponent( ...
                scenario, "troposphere");
            resolved.errors.multipath = ...
                SimulationConfigResolver.resolveMultipath(scenario);
            resolved.errors.hardwareDelay = ...
                SimulationConfigResolver.resolveScalarDelay( ...
                scenario, "hardwareDelay", 'enableHardwareDelay', ...
                ["txHardwareDelay_m", "rxHardwareDelay_m"], ...
                ["txHardwareDelayModel_m", "rxHardwareDelayModel_m"]);
            resolved.errors.antennaDelay = ...
                SimulationConfigResolver.resolveScalarDelay( ...
                scenario, "antennaDelay", 'enableAntennaDelay', ...
                "antennaDelay_m", "antennaDelayModel_m");
            resolved.errors.towerSurvey = ...
                SimulationConfigResolver.resolveToggleOnly( ...
                scenario, "towerSurvey", 'enableTowerSurveyError', ...
                "deterministic");
            resolved.errors.lightTime = ...
                SimulationConfigResolver.resolveTruthModelToggle( ...
                scenario, "lightTime", ...
                'enableLightTimeCorrection', ...
                'enableLightTimeCorrectionTruth', ...
                'enableLightTimeCorrectionModel', ...
                "deterministic");
            resolved.errors.legacySagnac = ...
                SimulationConfigResolver.resolveScalarDelay( ...
                scenario, "legacySagnac", 'enableSagnacCorrection', ...
                "sagnacCorrection_m", "sagnacCorrectionModel_m");
            resolved.errors.relativity = ...
                SimulationConfigResolver.resolveRelativity(scenario);
            resolved.errors.clock = ...
                SimulationConfigResolver.resolveClock(scenario);

            resolved.errors = SimulationConfigResolver.applySimpleErrorConfig( ...
                resolved.errors, ...
                SimulationConfigResolver.getFieldOrDefault( ...
                scenario, 'errors', struct()));

            SimulationConfigResolver.validateResolvedErrors(resolved.errors);
        end
    end

    methods (Static, Access = private)
        function scenario = activeScenario(simConfig)
            if isfield(simConfig, 'scenarios') && ...
                    isfield(simConfig.scenarios, 'reverseGnssClockNavigationScenario')
                scenario = simConfig.scenarios.reverseGnssClockNavigationScenario;
            else
                scenario = simConfig;
            end
        end

        function component = baseComponent()
            component = struct();
            component.enabled = false;
            component.truthMode = "off";
            component.modelMode = "off";
            component.stochasticMode = "off";
            component.standard = false;
            component.advanced = false;
            component.covariance = struct( ...
                'enabled', false, ...
                'sigma_m', 0.0, ...
                'variance_m2', 0.0);
            component.correlationModel = "independent";
            component.syntheticStressTest = false;
            component.diagnostics = struct();
        end

        function component = finalizeComponent(component)
            modes = [ ...
                component.truthMode, ...
                component.modelMode, ...
                component.stochasticMode];
            component.enabled = any(modes ~= "off");
            component.standard = any(modes == "standard" | ...
                modes == "standard+awgn");
            component.advanced = any(modes == "advanced");
        end

        function component = resolveMeasurementNoise(scenario)
            component = SimulationConfigResolver.baseComponent();
            mcfg = SimulationConfigResolver.measurementCfg(scenario);

            enabled = logical(SimulationConfigResolver.getFieldOrDefault( ...
                mcfg, 'enableMeasurementNoise', false)) || ...
                logical(SimulationConfigResolver.getFieldOrDefault( ...
                mcfg, 'enableNoise', false));

            if enabled
                component.truthMode = "awgn";
                component.stochasticMode = "awgn";
            end

            sigma_m = SimulationConfigResolver.getScalarField( ...
                mcfg, 'pseudorangeSigma_m', 0.30);
            component.covariance.enabled = enabled;
            component.covariance.sigma_m = sigma_m;
            component.covariance.variance_m2 = sigma_m^2;
            component.correlationModel = "independent";
            component.diagnostics.legacyFields = ...
                ["enableMeasurementNoise", "enableNoise", "pseudorangeSigma_m"];
            component = SimulationConfigResolver.finalizeComponent(component);
        end

        function component = resolveAtmosphereComponent(scenario, name)
            component = SimulationConfigResolver.baseComponent();
            atmosphereCfg = SimulationConfigResolver.getFieldOrDefault( ...
                scenario, 'atmosphere', struct());
            truthCfg = SimulationConfigResolver.getFieldOrDefault( ...
                atmosphereCfg, 'truth', struct());
            modelCfg = SimulationConfigResolver.getFieldOrDefault( ...
                atmosphereCfg, 'model', struct());

            if name == "ionosphere"
                enableField = 'enableIonosphere';
                modelField = 'ionosphereModel';
                sigmaField = 'residualIonosphereSigma_m';
            else
                enableField = 'enableTroposphere';
                modelField = 'troposphereModel';
                sigmaField = 'residualTroposphereSigma_m';
            end

            truthEnabled = logical(SimulationConfigResolver.getFieldOrDefault( ...
                truthCfg, enableField, false));
            modelEnabled = logical(SimulationConfigResolver.getFieldOrDefault( ...
                modelCfg, enableField, false));
            truthSigma_m = SimulationConfigResolver.getScalarField( ...
                truthCfg, sigmaField, 0.0);
            modelSigma_m = SimulationConfigResolver.getScalarField( ...
                modelCfg, sigmaField, 0.0);

            component.truthMode = ...
                SimulationConfigResolver.legacyAtmosphereMode( ...
                truthEnabled, ...
                SimulationConfigResolver.getFieldOrDefault( ...
                truthCfg, modelField, "disabled"));
            component.modelMode = ...
                SimulationConfigResolver.legacyAtmosphereMode( ...
                modelEnabled, ...
                SimulationConfigResolver.getFieldOrDefault( ...
                modelCfg, modelField, "disabled"));

            if truthSigma_m > 0.0 || modelSigma_m > 0.0
                component.stochasticMode = "awgn";
            end

            component.covariance.enabled = modelSigma_m > 0.0;
            component.covariance.sigma_m = modelSigma_m;
            component.covariance.variance_m2 = modelSigma_m^2;
            component.correlationModel = "sameTower";
            component.diagnostics.truthResidualSigma_m = truthSigma_m;
            component.diagnostics.modelResidualSigma_m = modelSigma_m;
            component.diagnostics.legacyEnableField = string(enableField);
            component.diagnostics.legacyModelField = string(modelField);
            component = SimulationConfigResolver.finalizeComponent(component);
        end

        function mode = legacyAtmosphereMode(enabled, modelName)
            if ~enabled
                mode = "off";
                return;
            end

            key = lower(strtrim(string(modelName)));
            if any(key == ["ionex", "profile", "era5profile", "era5"])
                mode = "advanced";
            else
                mode = "standard";
            end
        end

        function component = resolveMultipath(scenario)
            component = SimulationConfigResolver.baseComponent();
            mcfg = SimulationConfigResolver.measurementCfg(scenario);

            deterministicEnabled = logical( ...
                SimulationConfigResolver.getFieldOrDefault( ...
                mcfg, 'enableMultipathDelay', false));
            stochasticEnabled = deterministicEnabled && logical( ...
                SimulationConfigResolver.getFieldOrDefault( ...
                mcfg, 'enableStochasticMultipath', false));

            if deterministicEnabled && stochasticEnabled
                component.truthMode = "standard+awgn";
                component.stochasticMode = "awgn";
            elseif deterministicEnabled
                component.truthMode = "standard";
            end

            if deterministicEnabled && SimulationConfigResolver.anyNonZeroField( ...
                    mcfg, "multipathDelayModel_m")
                component.modelMode = "standard";
            end

            sigma_m = SimulationConfigResolver.getScalarField( ...
                mcfg, 'multipathStochasticSigma0_m', 0.0);
            component.covariance.enabled = stochasticEnabled && sigma_m > 0.0;
            component.covariance.sigma_m = sigma_m;
            component.covariance.variance_m2 = sigma_m^2;
            component.correlationModel = "independent";
            component = SimulationConfigResolver.finalizeComponent(component);
        end

        function component = resolveScalarDelay( ...
                scenario, componentName, enableField, truthFields, modelFields)
            component = SimulationConfigResolver.baseComponent();
            mcfg = SimulationConfigResolver.measurementCfg(scenario);

            enabled = logical(SimulationConfigResolver.getFieldOrDefault( ...
                mcfg, enableField, false));

            if enabled
                component.truthMode = "standard";
            end

            if enabled && SimulationConfigResolver.anyNonZeroField(mcfg, modelFields)
                component.modelMode = "standard";
            end

            component.diagnostics.legacyEnableField = string(enableField);
            component.diagnostics.legacyTruthFields = string(truthFields);
            component.diagnostics.legacyModelFields = string(modelFields);
            component.diagnostics.component = string(componentName);
            component = SimulationConfigResolver.finalizeComponent(component);
        end

        function component = resolveToggleOnly( ...
                scenario, componentName, enableField, correlationModel)
            component = SimulationConfigResolver.baseComponent();
            mcfg = SimulationConfigResolver.measurementCfg(scenario);

            if logical(SimulationConfigResolver.getFieldOrDefault( ...
                    mcfg, enableField, false))
                component.truthMode = "standard";
                component.modelMode = "standard";
            end

            component.correlationModel = string(correlationModel);
            component.diagnostics.legacyEnableField = string(enableField);
            component.diagnostics.component = string(componentName);
            component = SimulationConfigResolver.finalizeComponent(component);
        end

        function component = resolveTruthModelToggle( ...
                scenario, componentName, commonField, truthField, modelField, ...
                correlationModel)
            component = SimulationConfigResolver.baseComponent();
            mcfg = SimulationConfigResolver.measurementCfg(scenario);

            commonEnabled = logical(SimulationConfigResolver.getFieldOrDefault( ...
                mcfg, commonField, false));
            truthEnabled = logical(SimulationConfigResolver.getFieldOrDefault( ...
                mcfg, truthField, commonEnabled));
            modelEnabled = logical(SimulationConfigResolver.getFieldOrDefault( ...
                mcfg, modelField, commonEnabled));

            if truthEnabled
                component.truthMode = "standard";
            end

            if modelEnabled
                component.modelMode = "standard";
            end

            component.correlationModel = string(correlationModel);
            component.diagnostics.legacyCommonField = string(commonField);
            component.diagnostics.legacyTruthField = string(truthField);
            component.diagnostics.legacyModelField = string(modelField);
            component.diagnostics.component = string(componentName);
            component = SimulationConfigResolver.finalizeComponent(component);
        end

        function component = resolveRelativity(scenario)
            component = SimulationConfigResolver.baseComponent();
            mcfg = SimulationConfigResolver.measurementCfg(scenario);

            pathCommon = logical(SimulationConfigResolver.getFieldOrDefault( ...
                mcfg, 'enableRelativisticPathDelay', false));
            clockCommon = logical(SimulationConfigResolver.getFieldOrDefault( ...
                mcfg, 'enableRelativisticClockCorrection', false));
            truthEnabled = logical(SimulationConfigResolver.getFieldOrDefault( ...
                mcfg, 'enableRelativisticPathDelayTruth', pathCommon)) || ...
                logical(SimulationConfigResolver.getFieldOrDefault( ...
                mcfg, 'enableRelativisticClockCorrectionTruth', clockCommon));
            modelEnabled = logical(SimulationConfigResolver.getFieldOrDefault( ...
                mcfg, 'enableRelativisticPathDelayModel', pathCommon)) || ...
                logical(SimulationConfigResolver.getFieldOrDefault( ...
                mcfg, 'enableRelativisticClockCorrectionModel', clockCommon));

            if truthEnabled
                component.truthMode = "standard";
            end

            if modelEnabled
                component.modelMode = "standard";
            end

            component.correlationModel = "deterministic";
            component.diagnostics.note = ...
                "Relativistic path and clock flags are normalized together; implementation guards remain in MeasurementModel.";
            component = SimulationConfigResolver.finalizeComponent(component);
        end

        function component = resolveClock(scenario)
            component = SimulationConfigResolver.baseComponent();
            processCfg = SimulationConfigResolver.getFieldOrDefault( ...
                scenario, 'process', struct());
            clockModel = string(SimulationConfigResolver.getFieldOrDefault( ...
                processCfg, 'clockModel', "brownHwang"));
            clockModelKey = lower(regexprep(strtrim(clockModel), '[-_]', ''));

            component.enabled = true;
            component.truthMode = "standard";
            if clockModelKey == "coupledgaussmarkov"
                component.modelMode = "advanced";
                component.stochasticMode = "advanced";
                component.diagnostics.status = "experimental";
            else
                component.modelMode = "standard";
                component.stochasticMode = "standard";
                component.diagnostics.status = "standard";
            end
            component.covariance.enabled = true;
            component.correlationModel = "process";
            component.diagnostics.clockModel = clockModel;
            component = SimulationConfigResolver.finalizeComponent(component);
        end

        function errors = applySimpleErrorConfig(errors, simpleErrors)
            if ~isstruct(simpleErrors)
                return;
            end

            names = fieldnames(errors);
            for idx = 1:numel(names)
                name = names{idx};
                if ~isfield(simpleErrors, name)
                    continue;
                end

                errors.(name) = SimulationConfigResolver.applyComponentOverride( ...
                    name, errors.(name), simpleErrors.(name));
            end
        end

        function component = applyComponentOverride(name, component, override)
            componentName = string(name);
            if ~isstruct(override)
                component.truthMode = ...
                    SimulationConfigResolver.normalizeMode(override);
                component.modelMode = "off";
                component.stochasticMode = "off";
                component = SimulationConfigResolver.finalizeComponent(component);
                return;
            end

            if isfield(override, 'syntheticStressTest')
                component.syntheticStressTest = logical( ...
                    override.syntheticStressTest);
            end

            explicitMode = false;
            explicitStochastic = false;
            if isfield(override, 'mode')
                mode = SimulationConfigResolver.normalizeMode(override.mode);
                component.truthMode = mode;
                component.modelMode = mode;
                explicitMode = true;
            end

            if isfield(override, 'truth')
                component.truthMode = ...
                    SimulationConfigResolver.normalizeMode(override.truth);
                explicitMode = true;
            elseif isfield(override, 'truthMode')
                component.truthMode = ...
                    SimulationConfigResolver.normalizeMode(override.truthMode);
                explicitMode = true;
            end

            if isfield(override, 'model')
                component.modelMode = ...
                    SimulationConfigResolver.normalizeMode(override.model);
                explicitMode = true;
            elseif isfield(override, 'modelMode')
                component.modelMode = ...
                    SimulationConfigResolver.normalizeMode(override.modelMode);
                explicitMode = true;
            end

            if isfield(override, 'stochastic')
                component.stochasticMode = ...
                    SimulationConfigResolver.normalizeMode(override.stochastic);
                explicitMode = true;
                explicitStochastic = true;
            elseif isfield(override, 'stochasticMode')
                component.stochasticMode = ...
                    SimulationConfigResolver.normalizeMode(override.stochasticMode);
                explicitMode = true;
                explicitStochastic = true;
            end

            if isfield(override, 'correlationModel')
                component.correlationModel = string(override.correlationModel);
            end

            if isfield(override, 'enabled')
                enabledOverride = logical(override.enabled);
                if ~enabledOverride
                    component.truthMode = "off";
                    component.modelMode = "off";
                    component.stochasticMode = "off";
                elseif ~explicitMode && ~component.enabled
                    component.truthMode = ...
                        SimulationConfigResolver.defaultEnabledMode(componentName);
                    if componentName == "measurementNoise"
                        component.stochasticMode = "awgn";
                    end
                end
            end

            if ~explicitStochastic && SimulationConfigResolver.componentUsesAwgn(component)
                component.stochasticMode = "awgn";
            end

            component = SimulationConfigResolver.finalizeComponent(component);
        end

        function mode = defaultEnabledMode(componentName)
            if string(componentName) == "measurementNoise"
                mode = "awgn";
            else
                mode = "standard";
            end
        end

        function mode = normalizeMode(rawMode)
            mode = lower(strtrim(string(rawMode)));
            mode = regexprep(mode, '[\s_]+', '');

            if any(mode == ["off", "disabled", "disable", "false", "none"])
                mode = "off";
            elseif any(mode == ["std", "standard", "standrard", "stardard"])
                mode = "standard";
            elseif any(mode == ["standard+awgn", "standardawgn", ...
                    "std+awgn", "stdawgn", "standard+noise", ...
                    "standardnoise"])
                mode = "standard+awgn";
            elseif any(mode == ["awgn", "noise", "whitenoise", "white"])
                mode = "awgn";
            elseif any(mode == ["advanced", "adv"])
                mode = "advanced";
            else
                error('SimulationConfigResolver:InvalidMode', ...
                    ['Error-source mode "%s" is not supported. Use off, ', ...
                     'standard, standard+awgn, awgn, or advanced.'], ...
                    char(string(rawMode)));
            end
        end

        function validateResolvedErrors(errors)
            names = fieldnames(errors);
            for idx = 1:numel(names)
                name = string(names{idx});
                component = errors.(names{idx});

                if SimulationConfigResolver.componentUsesAwgn(component)
                    SimulationConfigResolver.validateAwgnAllowed(name, component);
                end
            end
        end

        function tf = componentUsesAwgn(component)
            modes = [component.truthMode, component.modelMode, component.stochasticMode];
            tf = any(modes == "awgn" | modes == "standard+awgn");
        end

        function validateAwgnAllowed(name, component)
            if any(name == ["measurementNoise", "multipath", ...
                    "ionosphere", "troposphere", "clock"])
                return;
            end

            if any(name == ["hardwareDelay", "antennaDelay", "towerSurvey"])
                if component.syntheticStressTest
                    return;
                end

                error('SimulationConfigResolver:InvalidAwgnMode', ...
                    ['%s is deterministic in the physical model. AWGN is ', ...
                     'only allowed when %s.syntheticStressTest = true.'], ...
                    char(name), char(name));
            end

            if any(name == ["lightTime", "legacySagnac", "relativity"])
                error('SimulationConfigResolver:InvalidAwgnMode', ...
                    ['%s is deterministic propagation physics. AWGN is ', ...
                     'not a valid mode for this component.'], char(name));
            end
        end

        function mcfg = measurementCfg(scenario)
            mcfg = SimulationConfigResolver.getFieldOrDefault( ...
                scenario, 'measurement', struct());
        end

        function tf = anyNonZeroField(s, fields)
            tf = false;
            for fieldName = string(fields(:)).'
                if isstruct(s) && isfield(s, char(fieldName)) && ...
                        ~isempty(s.(char(fieldName)))
                    values = double(s.(char(fieldName)));
                    if any(values(:) ~= 0.0)
                        tf = true;
                        return;
                    end
                end
            end
        end

        function value = getFieldOrDefault(s, fieldName, defaultValue)
            if isstruct(s) && isfield(s, fieldName) && ~isempty(s.(fieldName))
                value = s.(fieldName);
            else
                value = defaultValue;
            end
        end

        function value = getScalarField(s, fieldName, defaultValue)
            if isstruct(s) && isfield(s, fieldName) && ~isempty(s.(fieldName))
                value = double(s.(fieldName));
            else
                value = double(defaultValue);
            end
        end
    end
end
