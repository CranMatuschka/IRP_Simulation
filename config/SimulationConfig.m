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
simConfig.seeds.atmosphereResidual = simConfig.randomSeed + 4001;
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

% Geometric range currently uses ECI transmitter and receiver positions
% evaluated at the receiver epoch. Inertial light-time propagation is not
% implemented yet. When it is enabled in the future, it must evaluate the
% ground transmitter in ECI at transmit time and must not be combined with a
% separate ECEF Sagnac correction unless explicitly proven not to double
% count Earth rotation.
% Keep disabled, but use the canonical field names consumed by
% MeasurementModel.
scenario.measurement.propagationFrame = "ECI_static_receive_epoch";
scenario.measurement.enableLightTimeCorrection = false;
scenario.measurement.lightTimeCorrectionMethod = "inertialIterative";
scenario.measurement.lightTimeCorrectionTolerance_s = 1e-12;
scenario.measurement.lightTimeCorrectionMaxIterations = 10;

scenario.measurement.sagnacCorrection_m = 0.0;
scenario.measurement.enableRelativisticPathDelay = false;
scenario.measurement.enableRelativisticClockCorrection = false;

%% Atmosphere Model
% "truth" controls the physical atmospheric delay and optional residual noise
% applied to generated pseudoranges.
%
% "model" controls the deterministic correction and receiver-position
% sensitivity used by the estimator prediction and EKF measurement Jacobian.
% Estimator atmosphere defaults to disabled.
scenario.atmosphere = struct();

% Project-relative folder for downloaded or cached atmospheric products.
scenario.atmosphere.dataRoot = fullfile("data", "atmosphere");

% Missing external data must never be silently replaced with zero.
% Supported values: "error", "invalid"
scenario.atmosphere.missingDataPolicy = "error";

% Thin-shell height used by future ionosphere models.
scenario.atmosphere.ionosphereShellHeight_m = 350000.0;

%
% IONEX first-order code ionosphere correction example:
%
%   scenario.atmosphere.truth.enableIonosphere = true;
%   scenario.atmosphere.truth.ionosphereModel = "ionex";
%   scenario.atmosphere.truth.ionosphereProviderType = "ionex";
%   scenario.atmosphere.truth.ionexFile = "example.ionex";
%
%   scenario.atmosphere.model.enableIonosphere = true;
%   scenario.atmosphere.model.ionosphereModel = "ionex";
%   scenario.atmosphere.model.ionosphereProviderType = "ionex";
%   scenario.atmosphere.model.ionexFile = "example.ionex";
%
% ionexFile may be an absolute path or a path relative to
% scenario.atmosphere.dataRoot. The implemented IONEX correction is the
% first-order single-frequency code delay:
%
%   delay_m = 40.3 * STEC / f^2
%
% where STEC is VTEC interpolated at the thin-shell pierce point multiplied
% by the shell mapping factor. missingDataPolicy="error" is recommended for
% production runs; "invalid" is useful for deterministic regression tests.

%
% Troposphere profile-provider example:
%
%   scenario.atmosphere.truth.enableTroposphere = true;
%   scenario.atmosphere.truth.troposphereModel = "profile";
%   scenario.atmosphere.truth.troposphereProviderType = "profile";
%   scenario.atmosphere.truth.troposphereMappingFunction = "simple";
%   scenario.atmosphere.truth.troposphereProfile = struct( ...
%       'datetimeUtc', datetime(2026,5,27,23,0,0,'TimeZone','UTC'), ...
%       'pressure_hPa', 1013.25, ...
%       'temperature_K', 293.15, ...
%       'relativeHumidity_fraction', 0.50);
%
%   scenario.atmosphere.model = scenario.atmosphere.truth;
%
% The profile provider is deterministic and in-memory. It is intended for
% regression tests, controlled truth/model mismatch studies, and as the
% internal representation that external weather providers can feed.
%
% ERA5 surface-meteorology troposphere example:
%
%   scenario.atmosphere.truth.enableTroposphere = true;
%   scenario.atmosphere.truth.troposphereModel = "profile";
%   scenario.atmosphere.truth.troposphereProviderType = "era5";
%   scenario.atmosphere.truth.troposphereMappingFunction = "simple";
%   scenario.atmosphere.truth.era5File = "era5_surface.nc";
%
%   scenario.atmosphere.model = scenario.atmosphere.truth;
%
% era5File may be an absolute path or a path relative to
% scenario.atmosphere.dataRoot. The implemented ERA5 path currently reads
% surface meteorology from NetCDF, not full vertical ray tracing. Supported
% variables are latitude/longitude/time, surface pressure sp [Pa],
% temperature t2m [K], and one humidity source such as d2m dewpoint [K],
% relative humidity, or water vapour pressure. Atmosphere then computes
% Saastamoinen-style ZHD/ZWD and applies the configured mapping function.
%
% Simple ZTD troposphere example:
%
%   scenario.atmosphere.truth.enableTroposphere = true;
%   scenario.atmosphere.truth.troposphereModel = "simpleZtd";
%   scenario.atmosphere.truth.zhd_m = 2.3;
%   scenario.atmosphere.truth.zwd_m = 0.2;
%   scenario.atmosphere.truth.minimumMappingElevation_deg = 10.0;
%
% simpleZtd computes:
%
%   slant_tropo_m = (zhd_m + zwd_m) ...
%                 / sin(max(elevation, minimumMappingElevation))
%
% This is a first-stage flat-earth obliquity model for regression tests and
% coarse simulations. It is not a precise low-elevation troposphere model,
% so minimumMappingElevation_deg must be at least 10 deg.

%
% Atmospheric residual covariance settings:
%
%   residualTroposphereSigma_m
%   residualIonosphereSigma_m
%
% These fields represent unmodelled atmospheric code-delay uncertainty in
% metres. They do not change the deterministic atmosphere correction itself.
% The deterministic correction is still controlled only by troposphereModel,
% ionosphereModel, and their provider data.
%
% For the estimator/model atmosphere, enabled residual sigmas are added to
% the pseudorange measurement covariance as:
%
%   R_atmosphere = residualTroposphereSigma_m^2 ...
%                + residualIonosphereSigma_m^2
%
% The covariance is applied as a same-tower common-mode contribution because
% all receivers observing the same transmitting tower share the same
% atmospheric model-error source for that tower/link epoch. When
% enableTroposphere=false or enableIonosphere=false, the corresponding
% residual sigma is ignored.
%
% For the truth atmosphere, residual sigmas can be used for stochastic truth
% perturbations. For deterministic regression and PDF-report scenarios they
% should normally stay at zero. Increasing model residual sigmas should
% reduce EKF overconfidence by increasing innovation covariance S and
% reducing NIS per degree of freedom for the same deterministic residual.

%
% Stochastic truth atmosphere residual injection:
%
% The truth atmosphere can inject stochastic code-delay residuals into the
% generated pseudoranges by setting:
%
%   scenario.atmosphere.truth.residualTroposphereSigma_m
%   scenario.atmosphere.truth.residualIonosphereSigma_m
%
% The truth residuals are generated once per tower and epoch. The same
% residual sample is then applied to every receiver observing that tower at
% that epoch, so the injected term is tower-common across onboard receiver
% phase centres.
%
% The injected truth residual is separated into:
%
%   atmosphere_truth_troposphere_residual_by_tower_m
%   atmosphere_truth_ionosphere_residual_by_tower_m
%   atmosphere_truth_residual_by_tower_m
%
% with:
%
%   atmosphere_truth_residual_by_tower_m = ...
%       atmosphere_truth_troposphere_residual_by_tower_m + ...
%       atmosphere_truth_ionosphere_residual_by_tower_m
%
% The deterministic truth atmosphere delay remains separate from this
% stochastic residual. Therefore:
%
%   deterministic truth delay = modelled troposphere + modelled ionosphere
%   total truth delay         = deterministic truth delay + stochastic residual
%
% The atmosphere residual seed is:
%
%   simConfig.seeds.atmosphereResidual
%
% Reusing the same seed must reproduce identical truth residual samples.
% Changing the seed must produce a different residual sequence. For large
% sample counts, the residual statistics should converge approximately to:
%
%   std(troposphere residual) ~= residualTroposphereSigma_m
%   std(ionosphere residual)  ~= residualIonosphereSigma_m
%   std(total residual)       ~= hypot(residualTroposphereSigma_m, ...
%                                      residualIonosphereSigma_m)
%
% Keep truth residual sigmas at zero for deterministic geometry/report
% validation. Enable them only when testing stochastic truth generation,
% estimator consistency, or atmosphere-model robustness.
%
% Truth/model/residual diagnostic workflow:
%
%   sim.history.atmosphere.truth.total_m
%       physical atmosphere delay used in generated pseudoranges y
%
%   sim.history.atmosphere.model.total_m
%       deterministic correction available to the estimator prediction yp
%
%   sim.history.atmosphere.residual.total_m
%       truth.total_m - model.total_m, including stochastic truth residuals
%
%   sim.history.atmosphere.residual.deterministic_total_m
%       deterministic truth/model mismatch with stochastic samples removed
%
%   sim.history.atmosphere.covariance
%       model residual sigmas and the sameTower variance contribution added
%       to R for receivers observing the same transmitting tower
%
% The saved results struct mirrors these fields as results.atmosphere. The
% report data and atmosphere summary table expose the configured truth/model
% modes, constant parameters, deterministic mismatch, residual sigmas, and
% R covariance structure. The example script
% examples/runAtmosphereMismatchStudy.m configures a no-external-data
% constant mismatch with truth total 4.6 m, model total 3.7 m, and
% deterministic residual 0.9 m.
%
% Do not validate atmosphere realism from final position error alone. Common
% atmospheric range errors can be absorbed by receiver or tower clock states.
% Inspect prefit and postfit innovations, clock-bias errors, NIS, R, and the
% atmosphere truth/model/residual diagnostics.
%
% Propagation correction status:
%
%   scenario.measurement.propagationFrame = "ECI_static_receive_epoch"
%
% means geometric range uses ECI transmitter and receiver positions at the
% receive epoch. Inertial iterative light-time and relativistic path/clock
% terms are scaffolded diagnostics and remain disabled by default. Enabling
% unimplemented relativistic flags raises a clear error. Enabling both
% inertial light-time and separate Sagnac correction is guarded to prevent
% accidental double counting.

scenario.atmosphere.truth = struct( ...
    'enableTroposphere', false, ...
    'enableIonosphere', false, ...
    'troposphereModel', "constant", ...
    'troposphereProviderType', "none", ...
    'era5File', "", ...
    'troposphereMappingFunction', "simple", ...
    'ionosphereModel', "constant", ...
    'ionosphereProviderType', "none", ...
    'ionexFile', "", ...
    'constantTroposphereDelay_m', 0.0, ...
    'constantIonosphereDelay_m', 0.0, ...
    'surfacePressure_hPa', 1013.25, ...
    'surfaceTemperature_K', 293.15, ...
    'relativeHumidity_fraction', 0.50, ...
    'minimumMappingElevation_deg', 3.0, ...
    'zhd_m', 0.0, ...
    'zwd_m', 0.0, ...
    'vtec_TECU', 10.0, ...
    'residualTroposphereSigma_m', 0.0, ...
    'residualIonosphereSigma_m', 0.0);

% Estimator atmosphere defaults to disabled.
% When enabled, its correction, receiver-position sensitivity, and residual
% uncertainty are included in the EKF measurement model.
scenario.atmosphere.model = struct( ...
    'enableTroposphere', false, ...
    'enableIonosphere', false, ...
    'troposphereModel', "disabled", ...
    'troposphereProviderType', "none", ...
    'era5File', "", ...
    'troposphereMappingFunction', "simple", ...
    'ionosphereModel', "disabled", ...
    'ionosphereProviderType', "none", ...
    'ionexFile', "", ...
    'constantTroposphereDelay_m', 0.0, ...
    'constantIonosphereDelay_m', 0.0, ...
    'surfacePressure_hPa', 1013.25, ...
    'surfaceTemperature_K', 293.15, ...
    'relativeHumidity_fraction', 0.50, ...
    'minimumMappingElevation_deg', 3.0, ...
    'zhd_m', 0.0, ...
    'zwd_m', 0.0, ...
    'vtec_TECU', 10.0, ...
    'residualTroposphereSigma_m', 0.0, ...
    'residualIonosphereSigma_m', 0.0);

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
