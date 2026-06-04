% SimulationConfig.m
% =========================================================================
% SIMPLIFIED REVERSE-GNSS SATELLITE-RECEIVER SCENARIO CONFIGURATION
% =========================================================================
% The active scenario is:
%
%   simConfig.scenarios.reverseGnssClockNavigationScenario
%
% Ground towers transmit upward. The satellite is the receiver. The EKF uses
% ECI spacecraft center-of-mass position/velocity, Body-frame receiver lever
% arms rotated by q_BI, and one shared onboard receiver clock.

simConfig = struct();

%% Global Settings
simConfig.randomSeed = 42;
simConfig.seeds.clockTruth = simConfig.randomSeed + 1001;
simConfig.seeds.measurementNoise = simConfig.randomSeed + 2001;
simConfig.seeds.allanValidation = simConfig.randomSeed + 5001;
simConfig.enableInteractivePlots = false;
simConfig.enableReportGeneration = true;

%% Constants
simConfig.constants.speedOfLight_mps = 299792458.0;
simConfig.constants.earthMu_m3ps2 = 398600.4418e9;
simConfig.constants.earthRadius_m = 6378137.0;

%% Time
simConfig.simulation.dt_s = 1.0;
simConfig.simulation.totalTime_h = 1.0;
simConfig.simulation.startUtc = datetime(2026, 5, 27, 23, 0, 0, 'TimeZone', 'UTC');

%% Oscillator Library
simConfig.clockLibrary = struct( ...
    'TCXO',           makeOscillator(1e-21,    1e-20,    2e-20), ...
    'StandardQuartz', makeOscillator(2e-19,    7e-21,    2e-20), ...
    'OCXO1',          makeOscillator(8e-20,    2e-21,    4e-23), ...
    'Rubidium1',      makeOscillator(2e-20,    7e-24,    4e-29), ...
    'Cesium1',        makeOscillator(1e-19,    1e-25,    2e-32), ...
    'OCXO2',          makeOscillator(2.51e-26, 2.51e-23, 2.51e-22));

%% Scenario
scenario = struct();
scenario.name = "reverseGnssClockNavigationScenario";
scenario.description = "Reverse-GNSS pseudorange EKF: satellite RX, ground TX towers";

%   Frame convention:
%   Spacecraft navigation state: ECI
%   Ground tower storage: geodetic/ECEF, converted to ECI per measurement
%   Receiver lever arms: Body frame, rotated to ECI by q_BI
scenario.navigationFrameName = "ECI";
scenario.attitudeFrameName = "body-to-ECI quaternion q_BI";

scenario.spaceAsset = struct();
scenario.spaceAsset.name = "GEO-1";
scenario.spaceAsset.startLatitude_deg = 0.0;
scenario.spaceAsset.startLongitude_deg = 23.0;
scenario.spaceAsset.geoAltitude_m = 35786000.0;
scenario.spaceAsset.clock.clockType = 'Cesium1';
scenario.spaceAsset.clock.initialBias_ps = 0.0;
scenario.spaceAsset.clock.initialDrift_ps_per_s = 0.0;
scenario.spaceAsset.trueInitialAttitudeEuler321_deg = [0.0; 0.0; 0.0];
scenario.spaceAsset.trueAngularVelocity_degps = [0.0; 0.0; 0.0];

scenario.numReceivers = 4;
scenario.receiverBaseline_m = 2.0;
scenario.receivers = makeReceiverConfigs(scenario.numReceivers, scenario.receiverBaseline_m, 0.30);

scenario.towers = [ ...
    makeTower("Tenerife",        28.3,   -16.5,   0.0,  4.0), ...
    makeTower("Stockholm",       59.3,    18.1,   0.0, -2.5), ...
    makeTower("Hartebeesthoek", -25.9,    27.7,   0.0,  3.0), ...
    makeTower("Bengaluru",       13.0,    77.6,   0.0, -1.5), ...
    makeTower("Libreville",      0.0355,  -9.4496, 0.0,  0.0)];

%% Measurement Model
scenario.measurement = struct();
scenario.measurement.pseudorangeSigma_m = 0.30;
scenario.measurement.signalFrequency_Hz = 1575.42e6;
scenario.measurement.sigma_numerical_floor_m = 1e-3;
scenario.measurement.enableMeasurementNoise = false;
scenario.measurement.enableNoise = false;

scenario.measurement.enableHardwareDelay = false;
scenario.measurement.enableMultipathDelay = false;
scenario.measurement.enableAntennaDelay = false;
scenario.measurement.enableSagnacCorrection = false;
scenario.measurement.enableElevationMask = true;
scenario.measurement.elevationMask_deg = 5.0;

scenario.measurement.txHardwareDelay_m = 0.0;
scenario.measurement.rxHardwareDelay_m = 0.0;
scenario.measurement.multipathDelay_m = 0.0;
scenario.measurement.antennaDelay_m = 0.0;
scenario.measurement.enableLightTime = true;
scenario.measurement.lightTimeCorrectionMethod = "inertialIterative";
scenario.measurement.lightTimeTolerance_s = 1e-12;
scenario.measurement.lightTimeMaxIterations = 10;
scenario.measurement.sagnacCorrection_m = 0.0;

%% Atmosphere Model
% The legacy measurement atmosphere fields above remain in place until the
% Atmosphere class is connected to MeasurementModel.
%
% "truth" controls the physical delay applied to generated pseudoranges.
% "model" controls the correction applied by the estimator prediction model.

scenario.atmosphere = struct();

% Project-relative folder for downloaded or cached atmospheric products.
scenario.atmosphere.dataRoot = fullfile("data", "atmosphere");

% Missing external data must never be silently replaced with zero.
% Supported values: "error", "invalid"
scenario.atmosphere.missingDataPolicy = "error";

% Thin-shell height used by future ionosphere models.
scenario.atmosphere.ionosphereShellHeight_m = 350000.0;

scenario.atmosphere.truth = struct( ...
    'enableTroposphere', false, ...
    'enableIonosphere', false, ...
    'troposphereModel', "constant", ...
    'ionosphereModel', "constant", ...
    'constantTroposphereDelay_m', 0.0, ...
    'constantIonosphereDelay_m', 0.0, ...
    'surfacePressure_hPa', 1013.25, ...
    'surfaceTemperature_K', 293.15, ...
    'relativeHumidity_fraction', 0.50, ...
    'minimumMappingElevation_deg', 3.0, ...
    'vtec_TECU', 10.0);

% Preserve the current simulation behavior: atmosphere is generated only in
% truth and is not yet corrected in the estimator prediction model.
scenario.atmosphere.model = struct( ...
    'enableTroposphere', false, ...
    'enableIonosphere', false, ...
    'troposphereModel', "disabled", ...
    'ionosphereModel', "disabled", ...
    'constantTroposphereDelay_m', 0.0, ...
    'constantIonosphereDelay_m', 0.0, ...
    'surfacePressure_hPa', 1013.25, ...
    'surfaceTemperature_K', 293.15, ...
    'relativeHumidity_fraction', 0.50, ...
    'minimumMappingElevation_deg', 3.0, ...
    'vtec_TECU', 10.0);

%% EKF and Process Noise
scenario.enableGroundClockErrors = true;
scenario.enableGroundClockCorrection = true;
scenario.enableGroundClockCorrectionNoise = true;
scenario.groundClockCorrectionSigma_ps = 50.0;

scenario.enableTowerClockEKF = false;
scenario.towerClockGaugeMode = "externalTowerCorrections";

scenario.process = struct();
scenario.process.eciAccelerationPsd_m2ps3 = 1e-6;
scenario.process.attitudeAngularAccelerationPsd_rad2ps3 = deg2rad(1e-4)^2;
scenario.process.clockModel = "brownHwang";
scenario.process.clockCorrelationTime_s = 3600.0;
scenario.process.towerClockModel = scenario.process.clockModel;
scenario.process.towerClockCorrelationTime_s = scenario.process.clockCorrelationTime_s;

scenario.ekf = struct();
scenario.ekf.initialClockBiasError_m = 100.0;
scenario.ekf.initialClockFrequencyError_mps = 0.0;
scenario.ekf.initialTowerClockBiasSigma_m = 100.0;
scenario.ekf.initialTowerClockDriftSigma_mps = 0.05;

scenario.ekf.initialPositionError_m = [1000.0; 1000.0; 1000.0];
scenario.ekf.initialVelocityError_mps = [0.5; 0.5; 0.5];
scenario.ekf.initialAttitudeError_deg = [3.0; -2.0; 5.0];
scenario.ekf.initialAngularVelocityError_degps = [0.0; 0.0; 0.0];

scenario.ekf.initialClockBiasSigma_m = 100.0;
scenario.ekf.initialClockFrequencySigma_mps = 0.05;
scenario.ekf.initialTowerClockBiasError_m = 0.0;
scenario.ekf.initialTowerClockDriftError_mps = 0.0;
scenario.ekf.towerClockGaugeBiasSigma_m = 1e-4;
scenario.ekf.towerClockGaugeDriftSigma_mps = 1e-6;

scenario.ekf.initialPositionSigma_m = 1000.0;
scenario.ekf.initialVelocitySigma_mps = 0.5;
scenario.ekf.initialAttitudeSigma_deg = 10.0;
scenario.ekf.initialAngularVelocitySigma_degps = 0.05;
scenario.ekf.covarianceFloor = 1e-14;

%% Report and Allan Validation
scenario.report = struct();
scenario.report.enable = simConfig.enableReportGeneration;
scenario.report.generatePdf = true;
scenario.report.compilePdf = true;
scenario.report.interactivePlots = simConfig.enableInteractivePlots;
scenario.report.enableAllanDeviationValidation = true;

simConfig.validation.tauSimulation_s = logspace(0, 4, 25);
simConfig.validation.tauProfile_s = logspace(-1, 6, 300);
simConfig.validation.allanValidationSamples = 20000;

simConfig.scenarios.reverseGnssClockNavigationScenario = scenario;

%% Convenience Aliases
simConfig.towers = scenario.towers;
simConfig.noise.enableMeasurementNoise = scenario.measurement.enableMeasurementNoise;
simConfig.noise.pseudorangeSigma_m = scenario.measurement.pseudorangeSigma_m;

%% Caller Overrides
if exist("simConfigOverride", "var") && isstruct(simConfigOverride)
    simConfig = mergeStructRecursive(simConfig, simConfigOverride);
end
if exist("simConfigOverrides", "var") && isstruct(simConfigOverrides)
    simConfig = mergeStructRecursive(simConfig, simConfigOverrides);
end

% Temporary compatibility bridge:
% MeasurementModel still consumes constant atmosphere fields from
% scenario.measurement. Derive those internal fields from the canonical
% scenario.atmosphere configuration after caller overrides are merged.
simConfig = applyAtmosphereCompatibilityBridge(simConfig);

%% Helpers
function osc = makeOscillator(h0, hm1, hm2)
    osc = struct();
    osc.h0 = h0;
    osc.hm1 = hm1;
    osc.hm2 = hm2;
end

function tower = makeTower(name, lat_deg, lon_deg, alt_m, txDelay_m)
    tower = struct();
    tower.name = char(name);
    tower.lat_deg = lat_deg;
    tower.lon_deg = lon_deg;
    tower.alt_m = alt_m;
    tower.enabled = true;
    tower.txSignalDelay_m = txDelay_m;
end

function receivers = makeReceiverConfigs(nReceivers, baseline_m, sigma_m)
    offsets = canonicalReceiverOffsets(nReceivers, baseline_m);
    template = struct( ...
        'id', 1, ...
        'name', '', ...
        'enabled', true, ...
        'mode', "RX", ...
        'offsetBody_m', zeros(3, 1), ...
        'leverArmBody_m', zeros(3, 1), ...
        'pco_m', zeros(3, 1), ...
        'pcvMap', [], ...
        'measurementSigma_m', sigma_m, ...
        'pseudorangeSigma_m', sigma_m);
    receivers = repmat(template, 1, nReceivers);
    for k = 1:nReceivers
        receivers(k).id = k;
        receivers(k).name = sprintf('GEO-1-RX%02d', k);
        receivers(k).offsetBody_m = offsets(:, k);
        receivers(k).leverArmBody_m = offsets(:, k);
    end
end

function offsets = canonicalReceiverOffsets(nReceivers, baseline_m)
    base = baseline_m;
    canonical = [ ...
        0,  base, -base,  0,     0,     0,     0,  base, -base,  base, -base,  base; ...
        0,  0,     0,     base, -base,  0,     0,  base,  base, -base, -base,  0; ...
        0,  0,     0,     0,     0,     base, -base, 0,   0,     0,     0,     base];
    offsets = zeros(3, nReceivers);
    nCopy = min(nReceivers, size(canonical, 2));
    offsets(:, 1:nCopy) = canonical(:, 1:nCopy);
    for k = (nCopy + 1):nReceivers
        angle = 2.0 * pi * (k - nCopy - 1) / max(1, nReceivers - nCopy);
        offsets(:, k) = base * [cos(angle); sin(angle); 0.5 * (-1)^k];
    end
end

function base = mergeStructRecursive(base, override)
    names = fieldnames(override);
    for k = 1:numel(names)
        name = names{k};
        if isfield(base, name) && isstruct(base.(name)) && isstruct(override.(name)) && ...
                isscalar(base.(name)) && isscalar(override.(name))
            base.(name) = mergeStructRecursive(base.(name), override.(name));
        else
            base.(name) = override.(name);
        end
    end
end

function simConfig = applyAtmosphereCompatibilityBridge(simConfig)
    scenarioField = 'reverseGnssClockNavigationScenario';
    scenario = simConfig.scenarios.(scenarioField);

    if ~isfield(scenario, 'atmosphere') || ...
            ~isfield(scenario.atmosphere, 'truth') || ...
            ~isfield(scenario.atmosphere, 'model')
        error('SimulationConfig:MissingAtmosphereConfiguration', ...
            ['scenario.atmosphere.truth and scenario.atmosphere.model ', ...
             'must be defined.']);
    end

    truthCfg = scenario.atmosphere.truth;
    modelCfg = scenario.atmosphere.model;

    % The estimator atmosphere is not connected to predicted pseudoranges yet.
    % Reject enabled estimator corrections instead of silently ignoring them.
    if logical(modelCfg.enableTroposphere) || logical(modelCfg.enableIonosphere)
        error('SimulationConfig:EstimatorAtmosphereNotYetConnected', ...
            ['scenario.atmosphere.model must remain disabled until Atmosphere ', ...
             'is connected to predicted pseudoranges.']);
    end

    [useTroposphere, troposphereDelay_m] = ...
        constantAtmosphereCompatibility( ...
            truthCfg.enableTroposphere, ...
            truthCfg.troposphereModel, ...
            truthCfg.constantTroposphereDelay_m, ...
            "troposphere");

    [useIonosphere, ionosphereDelay_m] = ...
        constantAtmosphereCompatibility( ...
            truthCfg.enableIonosphere, ...
            truthCfg.ionosphereModel, ...
            truthCfg.constantIonosphereDelay_m, ...
            "ionosphere");

    % These are internal compatibility fields, not user-facing configuration.
    scenario.measurement.enableTroposphereDelay = useTroposphere;
    scenario.measurement.enableIonosphereDelay = useIonosphere;
    scenario.measurement.troposphereDelay_m = troposphereDelay_m;
    scenario.measurement.ionosphereDelay_m = ionosphereDelay_m;

    simConfig.scenarios.(scenarioField) = scenario;
end

function [enabled, delay_m] = constantAtmosphereCompatibility( ...
        enabledRaw, modelRaw, configuredDelay_m, componentName)

    enabled = logical(enabledRaw);

    if ~isscalar(enabled)
        error('SimulationConfig:InvalidAtmosphereEnableFlag', ...
            '%s enable flag must be scalar.', char(componentName));
    end

    modelName = lower(strtrim(string(modelRaw)));

    if ~isscalar(modelName)
        error('SimulationConfig:InvalidAtmosphereModel', ...
            '%s model name must be a string scalar.', char(componentName));
    end

    if ~enabled
        delay_m = 0.0;
        return;
    end

    % Until Atmosphere is injected into MeasurementModel, only the existing
    % constant-delay behavior can be represented truthfully.
    if modelName ~= "constant"
        error('SimulationConfig:AtmosphereModelNotYetConnected', ...
            ['The %s truth model "%s" is configured, but Atmosphere is not ', ...
             'connected to MeasurementModel yet. Use "constant" until the ', ...
             'integration commit.'], ...
            char(componentName), char(modelName));
    end

    validateattributes(configuredDelay_m, {'numeric'}, ...
        {'real', 'finite', 'scalar', 'nonnegative'}, ...
        mfilename, char(componentName));

    delay_m = double(configuredDelay_m);
end