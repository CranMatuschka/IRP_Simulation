% SimulationConfig.m
% =========================================================================
% SHARED CONFIGURATION FOR CLOCK / REVERSE-GNSS SIMULATION SCENARIOS
% =========================================================================
% This script creates one plain struct named simConfig. Scenario scripts
% may still change values before running by defining simConfigOverrides
% in the caller workspace. Example:
%
%   simConfigOverrides.simulation.totalTime_h = 0.25;
%   simConfigOverrides.enableReportGeneration = false;
%   run('Codes/Simulation/Clock/GSandSCClockScenario.m')

simConfig = struct();

%% Global Switches
simConfig.randomSeed = 42;
simConfig.seeds.clockTruth = simConfig.randomSeed + 1001;
simConfig.seeds.measurementNoise = simConfig.randomSeed + 2001;
simConfig.seeds.orbitProcess = simConfig.randomSeed + 3001;
simConfig.seeds.towerClocks = simConfig.randomSeed + 4001;
simConfig.seeds.allanValidation = simConfig.randomSeed + 5001;
simConfig.enableInteractivePlots = false;
simConfig.enableReportGeneration = true;

%% Physical Constants
simConfig.constants.speedOfLight_mps = 299792458.0;
simConfig.constants.earthMu_m3ps2 = 398600.4418e9;
simConfig.constants.earthRadius_m = 6378137.0;

%% Simulation Timing
simConfig.simulation.dt_s = 1.0;
simConfig.simulation.totalTime_h = 24.0;
simConfig.simulation.startUtc = datetime(2025, 11, 7, 23, 0, 0, 'TimeZone', 'UTC');

%% Legacy Single Spacecraft Defaults
simConfig.spacecraft.name = 'GEO-1';
simConfig.spacecraft.geoAltitude_m = 35786000.0;
simConfig.spacecraft.startLatitude_deg = 0.0;
simConfig.spacecraft.startLongitude_deg = 32.0;
simConfig.spacecraft.enableJ2 = false;
simConfig.spacecraft.enableRelativityClock = false;

%% Oscillator Library
% h0, hm1, and hm2 are the active Allan power-law coefficients used by
% Clock.m. Disabled placeholders are retained for future phase-noise masks,
% carrier tracking, and hardware clock studies.
simConfig.clockLibrary = struct(...
    'TCXO',           makeOscillator(1e-21,    1e-20,    2e-20), ...
    'StandardQuartz', makeOscillator(2e-19,    7e-21,    2e-20), ...
    'OCXO1',          makeOscillator(8e-20,    2e-21,    4e-23), ...
    'Rubidium1',      makeOscillator(2e-20,    7e-24,    4e-29), ...
    'Cesium1',        makeOscillator(1e-19,    1e-25,    2e-32), ...
    'OCXO2',          makeOscillator(2.51e-26, 2.51e-23, 2.51e-22) ...
);

%% Legacy Spacecraft Receiver Clock
simConfig.spacecraft.clock.clockType = 'Cesium1';
simConfig.spacecraft.clock.initialBias_ps = 0.0;
simConfig.spacecraft.clock.initialDrift_ps_per_s = 0.0;
simConfig.spacecraft.clock.h0Factor = 1.0;
simConfig.spacecraft.clock.hm1Factor = 1.0;
simConfig.spacecraft.clock.hm2Factor = 1.0;
simConfig.spacecraft.clock.whitePhaseNoise = struct('enabled', false, 'level', 0.0);
simConfig.spacecraft.clock.flickerPhaseNoise = struct('enabled', false, 'level', 0.0);
simConfig.spacecraft.clock.whiteFrequencyNoise = struct('enabled', true, 'factor', 1.0);
simConfig.spacecraft.clock.flickerFrequencyNoise = struct('enabled', true, 'factor', 1.0);
simConfig.spacecraft.clock.randomWalkFrequencyNoise = struct('enabled', true, 'factor', 1.0);
simConfig.spacecraft.clock.gaussMarkov = struct('enabled', false, 'correlationTime_s', Inf, 'sigma_ps', 0.0);

%% Spacecraft RF Hardware Phase Centers
% Disabled. ReceiverComponent is now the active receiver geometry model.
simConfig.spacecraft.rfHardware = [];

%% Multi-Asset Receiver Configuration
% ReceiverComponent is the active architecture.
% Each receiver is only a mounted phase-center offset plus a pseudorange sigma.
% All receivers on one SpaceAsset share that SpaceAsset clock.

simConfig.spaceAssets.numAssets = 1;
simConfig.spaceAssets.receiverCountPerAsset = [6];
simConfig.spaceAssets.defaultReceiverClockMode = "sharedSpaceAssetClock";
simConfig.spaceAssets.platformAttitudeTruth_deg = [0.5; -0.3; 1.0];
simConfig.spaceAssets.attitudeFrame = "LVLH";

simConfig.spaceAssets.assets = [ ...
    makeSpaceAssetConfig(1, 'GEO-1', true, ...
        simConfig.spacecraft.startLatitude_deg, ...
        simConfig.spacecraft.startLongitude_deg, ...
        simConfig.spacecraft.geoAltitude_m, ...
        simConfig.spacecraft.enableJ2, ...
        simConfig.spacecraft.enableRelativityClock, ...
        'Cesium1') ...
];

simConfig.spaceAssets.antennas = [ ...
    makeAntennaConfig(1, 1, 'GEO-1-RX-CENTER', true, ...
        [0; 0; 0], 0.30, "RX"), ...
    makeAntennaConfig(2, 1, 'GEO-1-RX-X-PLUS', false, ...
        [2.0; 0; 0], 0.30, "RX"), ...
    makeAntennaConfig(3, 1, 'GEO-1-RX-X-MINUS', false, ...
        [-2.0; 0; 0], 0.30, "RX"), ...
    makeAntennaConfig(4, 1, 'GEO-1-RX-Y-PLUS', false, ...
        [0; 2.0; 0], 0.30, "RX"), ...
    makeAntennaConfig(5, 1, 'GEO-1-RX-Y-MINUS', false, ...
        [0; -2.0; 0], 0.30, "RX"), ...
    makeAntennaConfig(6, 1, 'GEO-1-RX-Z-PLUS', false, ...
        [0; 0; 2.0], 0.30, "RX")];

simConfig.spaceAssets.assets(1).antennas = simConfig.spaceAssets.antennas;

%% Shared Measurement Covariance Terms
simConfig.measurementDefaults = makeMeasurementConfig(0.30, false);

%% Shared Orbit And Process Toggles
simConfig.process.q_acc_m2ps3 = 1e-6;
simConfig.process.orbitProcessVariance = 1e-6;
simConfig.orbit.enableJ2 = false;
simConfig.orbit.enableSolarRadiationPressure = false;
simConfig.orbit.enableStationkeeping = false;
simConfig.orbit.enableRelativisticClock = false;
simConfig.orbit.stmMethod = "variational";

%% Shared Aggregate Clock Process Options
simConfig.clockModel = "brownHwang";           % brownHwang | coupledGaussMarkov
simConfig.clockGaussMarkovCorrelationTime_s = 6 * 3600.0;

%% EKF Defaults
simConfig.ekf.initialPositionSigma_m = 1000.0;
simConfig.ekf.initialVelocitySigma_mps = 0.5;
simConfig.ekf.initialClockBiasSigma_s = 50e-9;
simConfig.ekf.initialClockDriftSigma_s_per_s = 5e-11;
simConfig.ekf.initialClockBiasSigma_m = 80.0;
simConfig.ekf.initialClockDriftSigma_mps = 0.05;
simConfig.ekf.clockPhaseCovarianceFloor_ps = 10.0;
simConfig.ekf.clockFrequencyCovarianceFloor_ps_per_s = 0.05;
simConfig.ekf.clockBiasCovarianceFloor_m = 1e-5;
simConfig.ekf.clockDriftCovarianceFloor_mps = 1e-8;
simConfig.ekf.enableClockCovarianceFloor = true;
simConfig.ekf.orbitProcessVariance = simConfig.process.orbitProcessVariance;

%% Allan Validation Defaults
simConfig.validation.tauSimulation_s = logspace(0, 5, 45);      % simulated points: 1 s ... 1e5 s
simConfig.validation.tauProfile_s    = logspace(-4, 8, 1000);   % theory curves: full scale
simConfig.validation.allanValidationSamples = 500000;

%% Tower Library
reverseGnss = struct();
reverseGnss.towerClock.clockType = 'Cesium1';
reverseGnss.towerClock.h0Factor = [0.93, 1.06, 1.12, 0.98, 1.03];
reverseGnss.towerClock.hm1Factor = [1.08, 0.95, 1.15, 1.02, 0.91];
reverseGnss.towerClock.hm2Factor = [1.18, 0.88, 1.05, 1.10, 0.96];
reverseGnss.towerClock.initialBias_ps = [18.0, -11.0, 24.0, -8.0, 6.0];
reverseGnss.towerClock.initialDrift_ps_per_s = [0.05, -0.03, 0.07, -0.04, 0.02];
simConfig.tower.clock.clockType = reverseGnss.towerClock.clockType;
simConfig.towerLibrary = [ ...
    makeTower('Tenerife',        28.3,   -16.5,   0.0, true, reverseGnss.towerClock.clockType, ...
        reverseGnss.towerClock.h0Factor(1), reverseGnss.towerClock.hm1Factor(1), reverseGnss.towerClock.hm2Factor(1), reverseGnss.towerClock.initialBias_ps(1), reverseGnss.towerClock.initialDrift_ps_per_s(1)), ...
        
    makeTower('Stockholm',       59.3,    18.1,   0.0, true, reverseGnss.towerClock.clockType, ...
        reverseGnss.towerClock.h0Factor(2), reverseGnss.towerClock.hm1Factor(2), reverseGnss.towerClock.hm2Factor(2), reverseGnss.towerClock.initialBias_ps(2), reverseGnss.towerClock.initialDrift_ps_per_s(2)), ...
        
    makeTower('Hartebeesthoek', -25.9,    27.7,   0.0, true, reverseGnss.towerClock.clockType, ...
        reverseGnss.towerClock.h0Factor(3), reverseGnss.towerClock.hm1Factor(3), reverseGnss.towerClock.hm2Factor(3), reverseGnss.towerClock.initialBias_ps(3), reverseGnss.towerClock.initialDrift_ps_per_s(3)), ...
        
    makeTower('Bengaluru',       13.0,    77.6,   0.0, true, reverseGnss.towerClock.clockType, ...
        reverseGnss.towerClock.h0Factor(4), reverseGnss.towerClock.hm1Factor(4), reverseGnss.towerClock.hm2Factor(4), reverseGnss.towerClock.initialBias_ps(4), reverseGnss.towerClock.initialDrift_ps_per_s(4)), ...
        
    makeTower('Libreville',      0.0355, -9.4496, 0.0, true, reverseGnss.towerClock.clockType, ...
        reverseGnss.towerClock.h0Factor(5), reverseGnss.towerClock.hm1Factor(5), reverseGnss.towerClock.hm2Factor(5), reverseGnss.towerClock.initialBias_ps(5), reverseGnss.towerClock.initialDrift_ps_per_s(5)) ...
];


%% Reverse-GNSS Ground-To-Space Joint Network Scenario

reverseGnss.description = 'GEO reverse-GNSS pseudorange EKF with explicit clock reference/gauge';
reverseGnss.clockGaugeMode = "externalTimeTransfer"; % none | knownTowerClockCorrections | externalTowerCorrections | fixReferenceTower | zeroMeanNetworkConstraint | externalTimeTransfer
reverseGnss.referenceTowerName = "Libreville";
reverseGnss.externalClockCorrectionSigma_ps = 50.0;
reverseGnss.externalTimeTransfer.enableNoise = true;
reverseGnss.externalTimeTransfer.estimateTowerClockBias = true;
reverseGnss.externalTimeTransfer.estimateTowerClockDrift = false;
reverseGnss.zeroMeanClockConstraintSigma_m = 1e-3;
reverseGnss.towers = simConfig.towerLibrary;
reverseGnss.measurement = makeMeasurementConfig(0.30, false);
reverseGnss.measurement.elevationMask_deg = 0.0;
reverseGnss.measurement.sigma_numerical_floor_m = 1e-4;
reverseGnss.process = simConfig.process;
reverseGnss.clockModel = simConfig.clockModel;
reverseGnss.clockGaussMarkovCorrelationTime_s = simConfig.clockGaussMarkovCorrelationTime_s;
reverseGnss.orbit = simConfig.orbit;
reverseGnss.ekf = simConfig.ekf;
reverseGnss.ekf.initialPositionSigma_m = 1.0;
reverseGnss.ekf.initialVelocitySigma_mps = 1e-4;
reverseGnss.ekf.initialClockBiasSigma_m = 80.0;
reverseGnss.ekf.initialClockDriftSigma_mps = 0.05;
reverseGnss.diagnostics.observabilityWindowEpochs = 300;
reverseGnss.report.enable = simConfig.enableReportGeneration;
reverseGnss.report.interactivePlots = simConfig.enableInteractivePlots;

%% Legacy Clock-Only Scenario
clockOnly = struct();
clockOnly.description = '10-state orbit plus 4-state spacecraft clock with perfect ground clocks';
clockOnly.towers = simConfig.towerLibrary(1:4);
clockOnly.groundClocks.perfectTransmitterClocks = true;
clockOnly.groundClocks.groundClockErrorEnabled = false;
clockOnly.groundClocks.estimateTowerClocks = false;
clockOnly.measurement = makeMeasurementConfig(0.01, false);
clockOnly.measurement.elevationMask_deg = -90.0;
clockOnly.ekf = simConfig.ekf;
clockOnly.orbit = simConfig.orbit;
clockOnly.orbit.stmMethod = "debugFirstOrder";
clockOnly.process = simConfig.process;

% Antenna Values
% Values for LEICA AR25 [L1, L2]
antenna = struct();
antenna.leicaAR25.pco_up_m = [0.88, 0.12] * 1e-3;       
antenna.leicaAR25.pco_east_m = [0.87, 0.02] * 1e-3;     
antenna.leicaAR25.pco_north_m = [159.36, 153.58] * 1e-3;  
% 2. Phase Center Variation (PCV) Mapping
antenna.leicaAR25.pcv_zenith_angles_deg = 0:5:90;
antenna.leicaAR25.pcv_values_mm = [0.00,  0.26,  0.63,  1.05,  1.48,  1.86,  2.16, ...
                             2.34,  2.37,  2.22,  1.90,  1.42,  0.81,  0.11, ...
                            -0.64, -1.39, -2.09, -2.68, -3.11];
%% VSNSC Multi-Receiver Scenario
vsnscToReceivers = reverseGnss;
vsnscToReceivers.description = 'Configuration-driven reverse-GNSS scenario with SpaceAsset receiver payloads';
vsnscToReceivers.spaceAssets = simConfig.spaceAssets;
vsnscToReceivers.receiverClockMode = simConfig.spaceAssets.defaultReceiverClockMode;
vsnscToReceivers.report.enable = simConfig.enableReportGeneration;
vsnscToReceivers.report.interactivePlots = simConfig.enableInteractivePlots;
% Report generation controls used by GSNSCClockScenarioTwoReceivers.m.
% generatePdf uses Reports/generateReport.m for the same LaTeX/PDF style as
% the legacy validation scenarios. generateMarkdown keeps the lightweight
% engineering note for quick inspection, and generateFigures stores PNG
% diagnostics for that Markdown report.
vsnscToReceivers.report.outputFolderName = "Default";
vsnscToReceivers.report.generatePdf = true;
vsnscToReceivers.report.generateMarkdown = true;
vsnscToReceivers.report.generateFigures = true;
vsnscToReceivers.report.includeFirstPageAssumptions = true;
% Receiver-comparison diagnostics run shadow EKFs using the same truth stream:
% RX1 only, RX2 only, and RX1+RX2 fused. These diagnostics are for report
% comparison only; they do not change the primary fused scenario.
vsnscToReceivers.report.enableReceiverSubsetComparison = true;

simConfig.scenarios.clockOnly = clockOnly;
simConfig.scenarios.reverseGnss = reverseGnss;
simConfig.scenarios.vsnscToReceivers = vsnscToReceivers;

%% Backward-Compatible Aliases
simConfig.towers = simConfig.scenarios.clockOnly.towers;
simConfig.noise.enableMeasurementNoise = simConfig.scenarios.clockOnly.measurement.enableNoise;
simConfig.noise.pseudorangeSigma_m = simConfig.scenarios.clockOnly.measurement.pseudorangeSigma_m;
simConfig.groundClocks = simConfig.scenarios.clockOnly.groundClocks;

%% Caller Overrides
if exist("simConfigOverride", "var") && isstruct(simConfigOverride)
    simConfig = mergeStructRecursive(simConfig, simConfigOverride);
end
if exist("simConfigOverrides", "var") && isstruct(simConfigOverrides)
    simConfig = mergeStructRecursive(simConfig, simConfigOverrides);
end

%% Local Helper Functions
function osc = makeOscillator(h0, hm1, hm2)
    osc = struct();
    osc.h0 = h0;
    osc.hm1 = hm1;
    osc.hm2 = hm2;
    osc.whitePhaseNoise = struct('enabled', false, 'level', 0.0);
    osc.flickerPhaseNoise = struct('enabled', false, 'level', 0.0);
    osc.whiteFrequencyNoise = struct('enabled', true, 'coefficient', h0);
    osc.flickerFrequencyNoise = struct('enabled', true, 'coefficient', hm1);
    osc.randomWalkFrequencyNoise = struct('enabled', true, 'coefficient', hm2);
    osc.gaussMarkov = struct('enabled', false, 'correlationTime_s', Inf, 'sigma_ps', 0.0);
end

function asset = makeSpaceAssetConfig(id, name, enabled, lat_deg, lon_deg, altitude_m, enableJ2, enableRelativityClock, sharedClockType)
    asset = struct();
    asset.id = id;
    asset.name = name;
    asset.enabled = enabled;
    asset.startLatitude_deg = lat_deg;
    asset.startLongitude_deg = lon_deg;
    asset.geoAltitude_m = altitude_m;
    asset.enableJ2 = enableJ2;
    asset.enableRelativityClock = enableRelativityClock;
    asset.sharedClock.clockType = sharedClockType;
    asset.sharedClock.initialBias_ps = 0.0;
    asset.sharedClock.initialDrift_ps_per_s = 0.0;
end

function antenna = makeAntennaConfig(id, parentAssetIndex, name, enabled, leverArmBody_m, measurementSigma_m, mode)
    if nargin < 7 || isempty(mode)
        mode = "RX";
    end

    antenna = struct();
    antenna.id = id;
    antenna.parentAssetIndex = parentAssetIndex;
    antenna.name = name;
    antenna.enabled = enabled;
    antenna.mode = mode;
    antenna.leverArmBody_m = leverArmBody_m(:);

    % Default zero RF phase-centre state preserves old ReceiverComponent
    % zero-bias validation behaviour exactly.
    antenna.pco_m = zeros(3,1);
    antenna.pcvMap = [];

    antenna.measurementSigma_m = measurementSigma_m;
    antenna.pseudorangeSigma_m = measurementSigma_m;
    antenna.metadata = struct();
end

function receiver = makeReceiverPayloadConfig(id, parentSpaceAssetId, parentAssetIndex, name, enabled, ...
        antennaOffsetBody_m, clockMode, estimateClock, initialBiasEstimate_m, ...
        initialDriftEstimate_mps, initialBiasSigma_m, initialDriftSigma_mps, measurementSigma_m)
    receiver = struct();
    receiver.id = id;
    receiver.parentSpaceAssetId = parentSpaceAssetId;
    receiver.parentAssetIndex = parentAssetIndex;
    receiver.name = name;
    receiver.enabled = enabled;
    receiver.antennaOffsetBody_m = antennaOffsetBody_m(:);
    receiver.offsetBody_m = antennaOffsetBody_m(:);
    receiver.clockMode = clockMode;
    receiver.clock = [];
    receiver.sharedClockReference = "";
    receiver.trueClockBias_m = 0.0;
    receiver.trueClockDrift_mps = 0.0;
    receiver.initialClockBiasEstimate_m = initialBiasEstimate_m;
    receiver.initialClockDriftEstimate_mps = initialDriftEstimate_mps;
    receiver.initialClockBiasSigma_m = initialBiasSigma_m;
    receiver.initialClockDriftSigma_mps = initialDriftSigma_mps;
    receiver.processNoiseClock_m2 = 0.0;
    receiver.processNoiseDrift_m2ps2 = 0.0;
    receiver.measurementSigma_m = measurementSigma_m;
    receiver.pseudorangeSigma_m = measurementSigma_m;
    receiver.estimateClock = estimateClock;
    receiver.metadata = struct();
end

function tower = makeTower(name, lat_deg, lon_deg, alt_m, clockEnabled, clockType, hm1Factor, hm2Factor, hm3Factor, initialBias_ps, initialDrift_ps_per_s)
    % makeTower creates a ground transmitter configuration.
    %
    % clockEnabled is intentionally a tower-level boolean. When true, a
    % scenario script may instantiate a physical transmitter oscillator. When
    % false, the tower remains an ideal time reference unless another scenario
    % explicitly overrides it.
    %
    % User-facing noise factors are named hm1Factor, hm2Factor, hm3Factor
    % because the scenario has three active clock-noise knobs per tower.
    % Internally, Clock.m uses the oscillator coefficients h0, hm1, hm2:
    %   hm1Factor -> h0  coefficient scale
    %   hm2Factor -> hm1 coefficient scale
    %   hm3Factor -> hm2 coefficient scale
    if nargin < 5 || isempty(clockEnabled), clockEnabled = false; end
    if nargin < 6 || isempty(clockType), clockType = 'Cesium1'; end
    if nargin < 7 || isempty(hm1Factor), hm1Factor = 1.0; end
    if nargin < 8 || isempty(hm2Factor), hm2Factor = 1.0; end
    if nargin < 9 || isempty(hm3Factor), hm3Factor = 1.0; end
    if nargin < 10 || isempty(initialBias_ps), initialBias_ps = 0.0; end
    if nargin < 11 || isempty(initialDrift_ps_per_s), initialDrift_ps_per_s = 0.0; end

    tower = struct();
    tower.name = name;
    tower.lat_deg = lat_deg;
    tower.lon_deg = lon_deg;
    tower.alt_m = alt_m;
    tower.enabled = true;

    tower.clockEnabled = logical(clockEnabled);
    tower.clock.clockType = char(string(clockType));

    % Internal coefficient-factor names consumed by the scenario script.
    tower.clock.h0Factor = hm1Factor;
    tower.clock.hm1Factor = hm2Factor;
    tower.clock.hm2Factor = hm3Factor;

    % User-facing aliases retained in the configuration for readability.
    tower.clock.hm1UserFactor = hm1Factor;
    tower.clock.hm2UserFactor = hm2Factor;
    tower.clock.hm3UserFactor = hm3Factor;

    tower.clock.initialBias_ps = initialBias_ps;
    tower.clock.initialDrift_ps_per_s = initialDrift_ps_per_s;
end

function hardware = makeRFHardware(name, id, enabled, leverArmBody_m, trueDelayOffset_m, ...
        initialDelayEstimate_m, initialDelaySigma_m, processNoiseDelay_m2, ...
        estimateDelay, isReferenceHardware, measurementSigma_m)
    hardware = struct();
    hardware.name = name;
    hardware.id = id;
    hardware.enabled = enabled;
    hardware.leverArmBody_m = leverArmBody_m(:);
    hardware.trueDelayOffset_m = trueDelayOffset_m;
    hardware.initialDelayEstimate_m = initialDelayEstimate_m;
    hardware.initialDelaySigma_m = initialDelaySigma_m;
    hardware.processNoiseDelay_m2 = processNoiseDelay_m2;
    hardware.estimateDelay = estimateDelay;
    hardware.isReferenceHardware = isReferenceHardware;
    hardware.measurementSigma_m = measurementSigma_m;
    hardware.metadata = struct();
end

function measurement = makeMeasurementConfig(pseudorange_sigma_m, enable_noise)
    measurement = struct();
    measurement.enableNoise = enable_noise;
    measurement.enableMeasurementNoise = enable_noise;
    measurement.elevationMask_deg = 0.0;
    measurement.pseudorangeSigma_m = pseudorange_sigma_m;
    measurement.sigma_receiver_thermal_m = 0.0;
    measurement.sigma_tracking_m = 0.0;
    measurement.sigma_tower_clock_correction_m = 0.0;
    measurement.sigma_troposphere_m = 0.0;
    measurement.sigma_ionosphere_m = 0.0;
    measurement.sigma_multipath_m = 0.0;
    measurement.sigma_hardware_delay_m = 0.0;
    measurement.sigma_numerical_floor_m = 1e-6;
end

function base = mergeStructRecursive(base, override)
    override_fields = fieldnames(override);
    for idx_field = 1:numel(override_fields)
        field_name = override_fields{idx_field};
        if isfield(base, field_name) && isstruct(base.(field_name)) && isstruct(override.(field_name)) ...
                && isscalar(base.(field_name)) && isscalar(override.(field_name))
            base.(field_name) = mergeStructRecursive(base.(field_name), override.(field_name));
        else
            base.(field_name) = override.(field_name);
        end
    end
end
