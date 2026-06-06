% test_ReverseGnss_5Towers_NReceivers_SimConfigPDF
% Scenario runner script using SimulationConfig.m.
%TEST_REVERSEGNSS_5TOWERS_NRECEIVERS_SIMCONFIGPDF
% Minimal scenario test that uses SimulationConfig.m as the base config.
%
% It only overrides:
%   - receiver count and receiver lever-arm array
%   - runtime length
%   - report/PDF flags
%
% Usage:

%   sim = test_ReverseGnss_5Towers_NReceivers_SimConfigPDF();
%   sim = test_ReverseGnss_5Towers_NReceivers_SimConfigPDF(8);
REPORT_VERSION = sprintf('1.27');
N_RECEIVERS = 4;
assert(N_RECEIVERS >= 1 && floor(N_RECEIVERS) == N_RECEIVERS, ...
    'N_RECEIVERS must be a positive integer.');

thisDir = fileparts(mfilename('fullpath'));
if isempty(thisDir)
    thisDir = pwd;
end
addpath(thisDir);
ProjectPathManager.addProjectPaths();

% The ReverseGnssSimulation object will run SimulationConfig.m itself.
% This override is merged into the scenario by SimulationConfig.m.
 RUN_DATE_TAG = string(datetime("now", ...
    "TimeZone", "UTC", ...
    "Format", "yyyyMMdd"));   

scenarioName = sprintf("Clock_%s_v%s", RUN_DATE_TAG, REPORT_VERSION);

simConfigOverride = struct();
simConfigOverride.randomSeed = 42;
simConfigOverride.enableInteractivePlots = false;
simConfigOverride.enableReportGeneration = true;

% Keep the test fast. Increase this to 1.0 for a one-hour run.
simConfigOverride.simulation.dt_s = 1.0;
simConfigOverride.simulation.totalTime_h = 1.0;

scenario = struct();
scenario.name = scenarioName;
scenario.numReceivers = N_RECEIVERS;
scenario.receiverBaseline_m = 2.0;
scenario.receivers = makeReceiverConfigsForTest(N_RECEIVERS, scenario.receiverBaseline_m, 0.30);

% Report/PDF must be generated.
scenario.report.enable = true;
scenario.report.generatePdf = true;
scenario.report.compilePdf = true;
scenario.report.interactivePlots = false;
scenario.report.enableAllanDeviationValidation = true;

% Deterministic regression by default. Turn this on in SimulationConfig
% or here if you explicitly want noisy measurements.
scenario.measurement.enableLightTimeCorrection = false;
scenario.measurement.enableSagnacCorrection = false;
scenario.measurement.enableMeasurementNoise = false;
scenario.measurement.enableNoise = false;
scenario.measurement.enableElevationMask = true;
scenario.measurement.elevationMask_deg = 5.0;


% Enable deterministic elevation-dependent atmosphere in the normal retained
% PDF report. Truth and estimator model are matched so the report shows the
% propagation correction without intentionally biasing the EKF.
truthAtmosphereCfg = struct( ...
    'enableTroposphere', true, ...
    'enableIonosphere', true, ...
    'troposphereModel', "saastamoinen", ...
    'troposphereMappingFunction', "simple", ...
    'ionosphereModel', "thinshellvtec", ...
    'constantTroposphereDelay_m', 0.0, ...
    'constantIonosphereDelay_m', 0.0, ...
    'surfacePressure_hPa', 1013.25, ...
    'surfaceTemperature_K', 293.15, ...
    'relativeHumidity_fraction', 0.50, ...
    'minimumMappingElevation_deg', 3.0, ...
    'vtec_TECU', 10.0, ...
    'residualTroposphereSigma_m', 0.0, ...
    'residualIonosphereSigma_m', 0.0);

modelAtmosphereCfg = truthAtmosphereCfg;

scenario.atmosphere.truth = truthAtmosphereCfg;
scenario.atmosphere.model = modelAtmosphereCfg;
% Use external timing corrections, not tower-clock EKF states, for the
% simple 14-state spacecraft navigation/clock test.
scenario.enableGroundClockErrors = false;
scenario.enableGroundClockCorrection = true;
scenario.enableGroundClockCorrectionNoise = false;
scenario.enableTowerClockEKF = false;
scenario.towerClockGaugeMode = "externalTowerCorrections";

simConfigOverride.scenarios.reverseGnssClockNavigationScenario = scenario;

runtimeOptions = struct();
runtimeOptions.entryPointName = mfilename;
runtimeOptions.N_RECEIVERS = N_RECEIVERS;
runtimeOptions.simConfigOverride = simConfigOverride;

sim = ReverseGnssSimulation(runtimeOptions);
sim.configure();

RUN_DATE_TAG = string(datetime("now", ...
"TimeZone", "UTC", ...
"Format", "yyyyMMdd"));
RUN_NAME_FOLDER = sprintf("Reports_%s", RUN_DATE_TAG);

sim.outputDir = string(fullfile(thisDir, ...
    "reports", ...
    RUN_NAME_FOLDER, ...
    scenarioName));
if ~exist(char(sim.outputDir), "dir")
    mkdir(char(sim.outputDir));
end

fprintf('\n============================================================\n');
fprintf('Reverse-GNSS test from SimulationConfig.m\n');
fprintf('Scenario: 5 towers, 1 SpaceAsset, %d receivers\n', N_RECEIVERS);
fprintf('Report/PDF output: %s\n', char(sim.outputDir));
fprintf('============================================================\n');

sim.run();
sim.saveResults();
sim.generateReport();

texFile = fullfile(char(sim.outputDir), sprintf('%s_report.tex', char(sim.scenarioName)));
pdfFile = fullfile(char(sim.outputDir), sprintf('%s_report.pdf', char(sim.scenarioName)));

assert(exist(texFile, 'file') == 2, 'Report TEX was not created: %s', texFile);
assert(exist(pdfFile, 'file') == 2, ...
    ['Report PDF was not created: %s\n', ...
     'Check that pdflatex is installed and visible on the MATLAB system path.'], pdfFile);
reportText = fileread(texFile);

assert(contains(reportText, 'Ionosphere and Troposphere Delay Components'), ...
    'Atmosphere component section is missing from the normal TEX report.');

assert(contains(reportText, 'Atmosphere Propagation Summary'), ...
    'Atmosphere summary table is missing from the normal TEX report.');
assert(contains(reportText, 'Atmosphere Truth Minus Model Residual Components'), ...
    'Atmosphere residual component row is missing from the normal TEX report.');

validateRetainedReportAtmosphereDiagnostics(sim);
runTroposphereProviderInterfaceRegression();
runTroposphereHydrostaticWetComponentRegression();
runTroposphereMappingFunctionSelectionRegression();
runDeterministicTroposphereProfileProviderRegression();
runProfileTroposphereDelayRegression();
runTroposphereProfileReportDiagnosticsRegression();
runIonosphereProviderInterfaceRegression();

runGriddedIonosphereProviderInterpolationRegression();
runIonexParserProviderRegression();
runIonexParserEdgeCaseRegression();
runIonexConfigurationExampleRegression();
runIonexAtmosphereDelayRegression();
runIonexHistoryReportDiagnosticsRegression();
runIonexTruthModelMismatchRegression();
runAtmosphereInvalidGradientGuardRegression();


runIonospherePiercePointGeometryRegression();
runAtmosphereConstantDiagnosticRegression();

runAtmosphereResidualAndCovarianceRegression();
runAtmosphereComponentResidualDecompositionRegression();
runAtmosphereResidualCovarianceNisRegression();
runAtmosphereGradientFiniteDifferenceRegression();

fprintf('\nPASS: test finished and PDF was created:\n%s\n', pdfFile);

%% Helper function
function receivers = makeReceiverConfigsForTest(nReceivers, baseline_m, sigma_m)
    base = double(baseline_m);

    offsets = [ ...
         0,  base, -base,  0,     0,     0,     0,  base, -base,  base, -base,  base; ...
         0,  0,     0,     base, -base,  0,     0,  base,  base, -base, -base,  0; ...
         0,  0,     0,     0,     0,     base, -base, 0,   0,     0,     0,     base];

    if nReceivers > size(offsets, 2)
        extra = zeros(3, nReceivers - size(offsets, 2));
        for k = 1:size(extra, 2)
            a = 2*pi*(k-1)/size(extra, 2);
            extra(:, k) = base * [cos(a); sin(a); 0.5*(-1)^k];
        end
        offsets = [offsets, extra]; %#ok<AGROW>
    end

    template = struct( ...
        'id', 1, ...
        'name', '', ...
        'enabled', true, ...
        'mode', "RX", ...
        'offsetBody_m', zeros(3, 1), ...
        'leverArmBody_m', zeros(3, 1), ...
        'pco_m', zeros(3, 1), ...
        'pcvMap', [], ...
        'measurementSigma_m', double(sigma_m), ...
        'pseudorangeSigma_m', double(sigma_m));

    receivers = repmat(template, 1, nReceivers);
    for rx = 1:nReceivers
        receivers(rx).id = rx;
        receivers(rx).name = sprintf('GEO-1-RX%02d', rx);
        receivers(rx).enabled = true;
        receivers(rx).mode = "RX";
        receivers(rx).offsetBody_m = offsets(:, rx);
        receivers(rx).leverArmBody_m = offsets(:, rx);
        receivers(rx).pco_m = zeros(3, 1);
        receivers(rx).pcvMap = [];
        receivers(rx).measurementSigma_m = double(sigma_m);
        receivers(rx).pseudorangeSigma_m = double(sigma_m);
    end
end

function validateRetainedReportAtmosphereDiagnostics(sim)
    assert(isfield(sim.history, 'atmosphere_truth_delay_by_receiver_tower_m'));
    assert(isfield(sim.history, 'atmosphere_truth_troposphere_by_receiver_tower_m'));
    assert(isfield(sim.history, 'atmosphere_truth_ionosphere_by_receiver_tower_m'));
    assert(isfield(sim.history, 'atmosphere_truth_total_by_receiver_tower_m'));
    assert(isfield(sim.history, 'atmosphere_model_delay_by_receiver_tower_m'));
    assert(isfield(sim.history, 'atmosphere_model_troposphere_by_receiver_tower_m'));
    assert(isfield(sim.history, 'atmosphere_model_ionosphere_by_receiver_tower_m'));

    visible = sim.history.visibility_mask_by_receiver_tower;

    assert(any(visible(:)), ...
        'Retained regression produced no visible pseudorange measurements.');

    truthTotal = sim.history.atmosphere_truth_delay_by_receiver_tower_m;
    truthTropo = sim.history.atmosphere_truth_troposphere_by_receiver_tower_m;
    truthIono = sim.history.atmosphere_truth_ionosphere_by_receiver_tower_m;
    truthTotalWithResidual = sim.history.atmosphere_truth_total_by_receiver_tower_m;

    modelTotal = sim.history.atmosphere_model_delay_by_receiver_tower_m;
    modelTropo = sim.history.atmosphere_model_troposphere_by_receiver_tower_m;
    modelIono = sim.history.atmosphere_model_ionosphere_by_receiver_tower_m;

    truthResidualByTower = sim.history.atmosphere_truth_residual_by_tower_m;

    assert(all(isfinite(truthTropo(visible))), ...
        'Retained report truth troposphere contains non-finite values.');

    assert(all(isfinite(truthIono(visible))), ...
        'Retained report truth ionosphere contains non-finite values.');

    assert(all(truthTropo(visible) > 0.0), ...
        'Saastamoinen truth troposphere should be positive for visible links.');

    assert(all(truthIono(visible) > 0.0), ...
        'Thin-shell VTEC truth ionosphere should be positive for visible code links.');

    assert(all(abs(truthTotal(visible) - ...
        (truthTropo(visible) + truthIono(visible))) < 1e-10), ...
        'Truth atmosphere total must equal troposphere plus ionosphere.');

    assert(all(abs(truthTotalWithResidual(visible) - truthTotal(visible)) < 1e-10), ...
        'Retained report truth atmosphere residual should be zero.');

    assert(all(isfinite(modelTropo(visible))), ...
        'Retained report model troposphere contains non-finite values.');

    assert(all(isfinite(modelIono(visible))), ...
        'Retained report model ionosphere contains non-finite values.');

    assert(all(modelTropo(visible) > 0.0), ...
        'Saastamoinen model troposphere should be positive for visible links.');

    assert(all(modelIono(visible) > 0.0), ...
        'Thin-shell VTEC model ionosphere should be positive for visible code links.');

    assert(all(abs(modelTotal(visible) - ...
        (modelTropo(visible) + modelIono(visible))) < 1e-10), ...
        'Model atmosphere total must equal model troposphere plus ionosphere.');

    atmosphereResidual = truthTotalWithResidual - modelTotal;

    assert(all(isfinite(atmosphereResidual(visible))), ...
        'Truth-minus-model atmosphere residual contains non-finite values.');

    assert(all(abs(truthResidualByTower(:)) < 1e-12), ...
        'Retained report truth atmospheric residual should be zero.');

    results = ResultBuilder.fromSimulation(sim);
    reportData = ReportDataBuilder.fromSimulation(sim);
    reportToggles = ReportConfigBuilder.togglesFromSimulation(sim);

    assert(reportToggles.ionosphere, ...
        'Ionosphere report toggle should be enabled.');

    assert(reportToggles.troposphere, ...
        'Troposphere report toggle should be enabled.');
    assert(sim.truthAtmosphere.troposphereModel == "saastamoinen", ...
        'Retained report should use Saastamoinen truth troposphere.');

    assert(sim.truthAtmosphere.ionosphereModel == "thinshellvtec", ...
        'Retained report should use thin-shell VTEC truth ionosphere.');

    assert(sim.modelAtmosphere.troposphereModel == "saastamoinen", ...
        'Retained report should use Saastamoinen estimator troposphere.');

    assert(sim.modelAtmosphere.ionosphereModel == "thinshellvtec", ...
        'Retained report should use thin-shell VTEC estimator ionosphere.');
    assert(isfield(results, 'atmosphere_truth_troposphere_by_receiver_tower_m'));
    assert(isfield(results, 'atmosphere_truth_ionosphere_by_receiver_tower_m'));
    assert(isfield(results, 'atmosphere_model_troposphere_by_receiver_tower_m'));
    assert(isfield(results, 'atmosphere_model_ionosphere_by_receiver_tower_m'));

    assert(isfield(reportData, 'atmosphere_summary_table'));
    assert(isfield(reportData, ...
        'atmosphere_truth_ionosphere_vtec_TECU_by_receiver_tower'));

    assert(isfield(reportData, ...
        'atmosphere_truth_ionosphere_stec_TECU_by_receiver_tower'));

    assert(isfield(reportData, ...
        'atmosphere_truth_ionosphere_mapping_factor_by_receiver_tower'));

    assert(isfield(reportData, ...
        'atmosphere_model_ionosphere_vtec_TECU_by_receiver_tower'));

    assert(isfield(reportData, ...
        'atmosphere_model_ionosphere_stec_TECU_by_receiver_tower'));

    assert(isfield(reportData, ...
        'atmosphere_model_ionosphere_mapping_factor_by_receiver_tower'));

    truthVtec = ...
        reportData.atmosphere_truth_ionosphere_vtec_TECU_by_receiver_tower;

    truthStec = ...
        reportData.atmosphere_truth_ionosphere_stec_TECU_by_receiver_tower;

    truthMapping = ...
        reportData.atmosphere_truth_ionosphere_mapping_factor_by_receiver_tower;

    modelVtec = ...
        reportData.atmosphere_model_ionosphere_vtec_TECU_by_receiver_tower;

    modelStec = ...
        reportData.atmosphere_model_ionosphere_stec_TECU_by_receiver_tower;

    modelMapping = ...
        reportData.atmosphere_model_ionosphere_mapping_factor_by_receiver_tower;

    assert(all(abs(truthVtec(visible) - 10.0) < 1e-12), ...
        'Retained report scalar truth VTEC should be 10 TECU.');

    assert(all(abs(modelVtec(visible) - 10.0) < 1e-12), ...
        'Retained report scalar model VTEC should be 10 TECU.');

    assert(all(isfinite(truthStec(visible))), ...
        'Retained report scalar truth STEC should be finite.');

    assert(all(isfinite(modelStec(visible))), ...
        'Retained report scalar model STEC should be finite.');

    assert(all(abs(truthStec(visible) - ...
        truthVtec(visible) .* truthMapping(visible)) < 1e-10), ...
        'Retained report scalar truth STEC must equal VTEC times mapping factor.');

    assert(all(abs(modelStec(visible) - ...
        modelVtec(visible) .* modelMapping(visible)) < 1e-10), ...
        'Retained report scalar model STEC must equal VTEC times mapping factor.');

    assert(isfield(reportData, 'atmosphere_troposphere_residual_by_receiver_tower_m'));
    assert(isfield(reportData, 'atmosphere_ionosphere_residual_by_receiver_tower_m'));

    disp("PASS: retained PDF report includes ionosphere and troposphere diagnostics.");
end

function runTroposphereProviderInterfaceRegression()
    ProjectPathManager.addProjectPaths();

    provider = TroposphereProfileProviderFactory.create( ...
        "none", ...
        fullfile("data", "atmosphere"), ...
        struct(), ...
        "model");

    assert(isa(provider, 'TroposphereProfileProvider'), ...
        'Provider must implement TroposphereProfileProvider.');

    assert(isa(provider, 'NullTroposphereProfileProvider'), ...
        'Default troposphere provider should be NullTroposphereProfileProvider.');

    assert(~provider.isAvailable(), ...
        'Null troposphere provider must report unavailable.');

    queryTime = datetime(2026, 5, 27, 23, 0, 0, ...
        'TimeZone', 'UTC');

    result = provider.profileAt(queryTime, 52.0, 13.0, 100.0);

    assert(isstruct(result), ...
        'Troposphere provider result must be a struct.');

    assert(isfield(result, 'valid'));
    assert(isfield(result, 'pressure_hPa'));
    assert(isfield(result, 'temperature_K'));
    assert(isfield(result, 'relativeHumidity_fraction'));
    assert(isfield(result, 'waterVaporPressure_hPa'));
    assert(isfield(result, 'zenithHydrostaticDelay_m'));
    assert(isfield(result, 'zenithWetDelay_m'));
    assert(isfield(result, 'providerType'));

    assert(~result.valid, ...
        'Null troposphere provider must return invalid profile data.');

    assert(isnan(result.pressure_hPa), ...
        'Null troposphere provider pressure must be NaN.');

    constants = struct( ...
        'speedOfLight_mps', 299792458.0, ...
        'earthRadius_m', 6378137.0);

    atmosphereCfg = struct();
    atmosphereCfg.dataRoot = fullfile("data", "atmosphere");
    atmosphereCfg.missingDataPolicy = "error";
    atmosphereCfg.ionosphereShellHeight_m = 350000.0;

    atmosphereCfg.model = struct( ...
        'enableTroposphere', false, ...
        'enableIonosphere', false, ...
        'troposphereProviderType', "none", ...
        'ionosphereProviderType', "none");

    atmosphere = Atmosphere(atmosphereCfg, constants, "model");

    assert(atmosphere.troposphereProviderType == "none", ...
        'Atmosphere should store troposphereProviderType.');

    assert(isa(atmosphere.troposphereProvider, ...
            'NullTroposphereProfileProvider'), ...
        'Atmosphere should own a null troposphere provider by default.');

    profileCfg = atmosphereCfg;
    profileCfg.model.troposphereProviderType = "profile";

    profileAtmosphere = Atmosphere(profileCfg, constants, "model");

    assert(profileAtmosphere.troposphereProviderType == "profile", ...
        'Atmosphere should accept the profile troposphere provider type.');

    assert(isa(profileAtmosphere.troposphereProvider, ...
            'NullTroposphereProfileProvider'), ...
        ['Profile troposphere provider should currently resolve to the null ', ...
         'provider until the deterministic profile provider is implemented.']);

    era5Cfg = atmosphereCfg;
    era5Cfg.model.troposphereProviderType = "era5";

    era5Atmosphere = Atmosphere(era5Cfg, constants, "model");

    assert(era5Atmosphere.troposphereProviderType == "era5", ...
        'Atmosphere should accept the era5 troposphere provider type.');

    assert(isa(era5Atmosphere.troposphereProvider, ...
            'NullTroposphereProfileProvider'), ...
        ['ERA5 troposphere provider should currently resolve to the null ', ...
         'provider until ERA5 provider parsing is implemented.']);

    assert(~era5Atmosphere.troposphereProvider.isAvailable(), ...
        'ERA5 placeholder troposphere provider should not be available yet.');

    disp("PASS: troposphere provider interface is available and baseline-safe.");
end

function runTroposphereHydrostaticWetComponentRegression()
    ProjectPathManager.addProjectPaths();

    datetimeUtc = datetime(2026, 5, 27, 23, 0, 0, ...
        'TimeZone', 'UTC');

    jd = Clock.julianDateFromDatetime(datetimeUtc);

    constants = struct( ...
        'speedOfLight_mps', 299792458.0, ...
        'earthRadius_m', 6378137.0);

    pressure_hPa = 1013.25;
    temperature_K = 293.15;
    relativeHumidity_fraction = 0.50;
    minimumMappingElevation_deg = 3.0;

    atmosphereCfg = struct();
    atmosphereCfg.dataRoot = fullfile("data", "atmosphere");
    atmosphereCfg.missingDataPolicy = "error";
    atmosphereCfg.ionosphereShellHeight_m = 350000.0;

    atmosphereCfg.model = struct( ...
        'enableTroposphere', true, ...
        'enableIonosphere', false, ...
        'troposphereModel', "saastamoinen", ...
        'troposphereProviderType', "none", ...
        'troposphereMappingFunction', "simple", ...
        'ionosphereModel', "disabled", ...
        'surfacePressure_hPa', pressure_hPa, ...
        'surfaceTemperature_K', temperature_K, ...
        'relativeHumidity_fraction', relativeHumidity_fraction, ...
        'minimumMappingElevation_deg', minimumMappingElevation_deg, ...
        'residualTroposphereSigma_m', 0.0, ...
        'residualIonosphereSigma_m', 0.0);

    atmosphere = Atmosphere(atmosphereCfg, constants, "model");

    towerCfg = struct( ...
        'name', 'SaastamoinenComponentTower', ...
        'lat_deg', 28.3, ...
        'lon_deg', -16.5, ...
        'alt_m', 0.0, ...
        'txSignalDelay_m', 0.0);

    tower = GroundNode(towerCfg);

    elevation_deg = 45.0;
    azimuth_deg = 120.0;
    slantRange_m = 4.0e7;

    uEnu = [ ...
        cosd(elevation_deg) * sind(azimuth_deg); ...
        cosd(elevation_deg) * cosd(azimuth_deg); ...
        sind(elevation_deg)];

    R_enu_ecef = FrameGeometry.ecefToEnuDcm( ...
        tower.lat_deg, tower.lon_deg);

    uEcef = R_enu_ecef.' * uEnu;

    receiverEcef_m = tower.pos_ECEF_m + slantRange_m * uEcef;
    receiverEci_m = FrameGeometry.ecefToEciDcm(jd) * receiverEcef_m;

    delay = atmosphere.codeDelayMeters( ...
        tower, receiverEci_m, jd, datetimeUtc, 1575.42e6);

    assert(delay.valid, ...
        'Saastamoinen component regression should produce a valid delay.');

    assert(isfield(delay.metadata, 'troposphere'), ...
        'Atmosphere delay metadata must contain troposphere diagnostics.');

    tropo = delay.metadata.troposphere;

    assert(tropo.valid, ...
        'Saastamoinen troposphere diagnostics should be valid.');

    assert(tropo.zenithHydrostaticDelay_m > 0.0, ...
        'Zenith hydrostatic delay should be positive.');

    assert(tropo.zenithWetDelay_m > 0.0, ...
        'Zenith wet delay should be positive.');

    assert(tropo.slantHydrostaticDelay_m > 0.0, ...
        'Slant hydrostatic delay should be positive.');

    assert(tropo.slantWetDelay_m > 0.0, ...
        'Slant wet delay should be positive.');

    assert(abs(tropo.total_m - ...
        (tropo.slantHydrostaticDelay_m + tropo.slantWetDelay_m)) < 1e-12, ...
        'Troposphere total must equal hydrostatic plus wet slant delays.');

    assert(abs(delay.troposphere_m - tropo.total_m) < 1e-12, ...
        'Delay troposphere component must equal troposphere metadata total.');

    temperature_C = temperature_K - 273.15;

    saturationVaporPressure_hPa = ...
        6.1121 * exp( ...
        (18.678 - temperature_C / 234.5) * ...
        (temperature_C / (257.14 + temperature_C)));

    expectedWaterVaporPressure_hPa = ...
        relativeHumidity_fraction * saturationVaporPressure_hPa;

    latitude_rad = deg2rad(double(tower.lat_deg));
    height_km = double(tower.alt_m) / 1000.0;

    heightCorrection = ...
        1.0 ...
        - 0.00266 * cos(2.0 * latitude_rad) ...
        - 0.00028 * height_km;

    expectedZhd_m = ...
        0.0022768 * pressure_hPa / heightCorrection;

    expectedZwd_m = ...
        0.002277 * ...
        (1255.0 / temperature_K + 0.05) * ...
        expectedWaterVaporPressure_hPa;

    expectedMapping = ...
        1.0 / sind(max(delay.elevation_deg, minimumMappingElevation_deg));

    expectedTotal_m = ...
        (expectedZhd_m + expectedZwd_m) * expectedMapping;

    assert(abs(tropo.waterVaporPressure_hPa - ...
        expectedWaterVaporPressure_hPa) < 1e-12, ...
        'Saastamoinen water vapour pressure is incorrect.');

    assert(abs(tropo.zenithHydrostaticDelay_m - expectedZhd_m) < 1e-12, ...
        'Saastamoinen zenith hydrostatic delay is incorrect.');

    assert(abs(tropo.zenithWetDelay_m - expectedZwd_m) < 1e-12, ...
        'Saastamoinen zenith wet delay is incorrect.');

    assert(abs(tropo.mappingHydrostatic - expectedMapping) < 1e-12, ...
        'Hydrostatic mapping factor is incorrect.');

    assert(abs(tropo.mappingWet - expectedMapping) < 1e-12, ...
        'Wet mapping factor is incorrect.');

    assert(abs(delay.troposphere_m - expectedTotal_m) < 1e-12, ...
        'Saastamoinen total delay changed during hydrostatic/wet refactor.');

    disp("PASS: Saastamoinen hydrostatic and wet components are consistent.");
end

function runTroposphereMappingFunctionSelectionRegression()
    ProjectPathManager.addProjectPaths();

    datetimeUtc = datetime(2026, 5, 27, 23, 0, 0, ...
        'TimeZone', 'UTC');

    jd = Clock.julianDateFromDatetime(datetimeUtc);

    constants = struct( ...
        'speedOfLight_mps', 299792458.0, ...
        'earthRadius_m', 6378137.0);

    atmosphereCfg = struct();
    atmosphereCfg.dataRoot = fullfile("data", "atmosphere");
    atmosphereCfg.missingDataPolicy = "error";
    atmosphereCfg.ionosphereShellHeight_m = 350000.0;

    atmosphereCfg.model = struct( ...
        'enableTroposphere', true, ...
        'enableIonosphere', false, ...
        'troposphereModel', "saastamoinen", ...
        'troposphereProviderType', "none", ...
        'troposphereMappingFunction', "simple", ...
        'ionosphereModel', "disabled", ...
        'surfacePressure_hPa', 1013.25, ...
        'surfaceTemperature_K', 293.15, ...
        'relativeHumidity_fraction', 0.50, ...
        'minimumMappingElevation_deg', 3.0, ...
        'residualTroposphereSigma_m', 0.0, ...
        'residualIonosphereSigma_m', 0.0);

    atmosphere = Atmosphere(atmosphereCfg, constants, "model");

    assert(atmosphere.troposphereMappingFunction == "simple", ...
        'Atmosphere should store troposphereMappingFunction="simple".');

    towerCfg = struct( ...
        'name', 'MappingFunctionTower', ...
        'lat_deg', 28.3, ...
        'lon_deg', -16.5, ...
        'alt_m', 0.0, ...
        'txSignalDelay_m', 0.0);

    tower = GroundNode(towerCfg);

    elevation_deg = 20.0;
    azimuth_deg = 90.0;
    slantRange_m = 4.0e7;

    uEnu = [ ...
        cosd(elevation_deg) * sind(azimuth_deg); ...
        cosd(elevation_deg) * cosd(azimuth_deg); ...
        sind(elevation_deg)];

    R_enu_ecef = FrameGeometry.ecefToEnuDcm( ...
        tower.lat_deg, tower.lon_deg);

    uEcef = R_enu_ecef.' * uEnu;

    receiverEcef_m = tower.pos_ECEF_m + slantRange_m * uEcef;
    receiverEci_m = FrameGeometry.ecefToEciDcm(jd) * receiverEcef_m;

    delay = atmosphere.codeDelayMeters( ...
        tower, receiverEci_m, jd, datetimeUtc, 1575.42e6);

    assert(delay.valid, ...
        'Simple troposphere mapping regression should produce a valid delay.');

    tropo = delay.metadata.troposphere;

    expectedMapping = ...
        1.0 / sind(max(delay.elevation_deg, 3.0));

    assert(tropo.mappingFunction == "simple", ...
        'Troposphere metadata should record the selected mapping function.');

    assert(abs(tropo.mappingHydrostatic - expectedMapping) < 1e-12, ...
        'Simple hydrostatic mapping factor is incorrect.');

    assert(abs(tropo.mappingWet - expectedMapping) < 1e-12, ...
        'Simple wet mapping factor is incorrect.');

    assert(abs(tropo.total_m - ...
        (tropo.zenithHydrostaticDelay_m * tropo.mappingHydrostatic + ...
         tropo.zenithWetDelay_m * tropo.mappingWet)) < 1e-12, ...
        'Troposphere total should use selected hydrostatic and wet mapping factors.');

    badCfg = atmosphereCfg;
    badCfg.model.troposphereMappingFunction = "niell";

    rejectedUnsupportedMapping = false;

    try
        Atmosphere(badCfg, constants, "model");
    catch ME
        rejectedUnsupportedMapping = ...
            strcmp(ME.identifier, ...
            'Atmosphere:InvalidConfigurationChoice');
    end

    assert(rejectedUnsupportedMapping, ...
        'Unsupported troposphere mapping functions must be rejected until implemented.');

    disp("PASS: troposphere mapping-function selection is explicit and safe.");
end

function runDeterministicTroposphereProfileProviderRegression()
    ProjectPathManager.addProjectPaths();

    epoch0 = datetime(2026, 5, 27, 23, 0, 0, ...
        'TimeZone', 'UTC');

    epochUtc = [epoch0; epoch0 + hours(1)];

    pressure_hPa = [990.0; 1010.0];
    temperature_K = [285.0; 295.0];
    relativeHumidity_fraction = [0.40; 0.60];

    profileCfg = struct( ...
        'datetimeUtc', epochUtc, ...
        'pressure_hPa', pressure_hPa, ...
        'temperature_K', temperature_K, ...
        'relativeHumidity_fraction', relativeHumidity_fraction, ...
        'source', "unit-test deterministic profile");

    providerCfg = struct();
    providerCfg.troposphereProfile = profileCfg;

    provider = TroposphereProfileProviderFactory.create( ...
        "profile", ...
        fullfile("data", "atmosphere"), ...
        providerCfg, ...
        "model");

    assert(isa(provider, 'DeterministicTroposphereProfileProvider'), ...
        'Profile source should construct DeterministicTroposphereProfileProvider.');

    assert(provider.isAvailable(), ...
        'Deterministic troposphere profile provider should be available.');

    queryTime = epoch0 + minutes(30);

    result = provider.profileAt(queryTime, 52.0, 13.0, 100.0);

    expectedPressure_hPa = 1000.0;
    expectedTemperature_K = 290.0;
    expectedRelativeHumidity_fraction = 0.50;

    temperature_C = expectedTemperature_K - 273.15;

    saturationVaporPressure_hPa = ...
        6.1121 * exp( ...
        (18.678 - temperature_C / 234.5) * ...
        (temperature_C / (257.14 + temperature_C)));

    expectedWaterVaporPressure_hPa = ...
        expectedRelativeHumidity_fraction * saturationVaporPressure_hPa;

    assert(result.valid, ...
        'Interpolated deterministic troposphere profile should be valid.');

    assert(abs(result.pressure_hPa - expectedPressure_hPa) < 1e-12, ...
        'Interpolated pressure is incorrect.');

    assert(abs(result.temperature_K - expectedTemperature_K) < 1e-12, ...
        'Interpolated temperature is incorrect.');

    assert(abs(result.relativeHumidity_fraction - ...
        expectedRelativeHumidity_fraction) < 1e-12, ...
        'Interpolated relative humidity is incorrect.');

    assert(abs(result.waterVaporPressure_hPa - ...
        expectedWaterVaporPressure_hPa) < 1e-12, ...
        'Computed water vapour pressure is incorrect.');

    assert(result.providerType == "profile", ...
        'Deterministic profile result should report providerType profile.');

    assert(result.metadata.timeIndex0 == 1);
    assert(result.metadata.timeIndex1 == 2);
    assert(abs(result.metadata.timeWeight - 0.5) < 1e-12);

    outsideResult = provider.profileAt( ...
        epoch0 - hours(1), 52.0, 13.0, 100.0);

    assert(~outsideResult.valid, ...
        'Deterministic profile provider should reject out-of-time queries.');

    constants = struct( ...
        'speedOfLight_mps', 299792458.0, ...
        'earthRadius_m', 6378137.0);

    atmosphereCfg = struct();
    atmosphereCfg.dataRoot = fullfile("data", "atmosphere");
    atmosphereCfg.missingDataPolicy = "error";
    atmosphereCfg.ionosphereShellHeight_m = 350000.0;

    atmosphereCfg.model = struct( ...
        'enableTroposphere', false, ...
        'enableIonosphere', false, ...
        'troposphereProviderType', "profile", ...
        'troposphereProfile', profileCfg, ...
        'ionosphereProviderType', "none");

    atmosphere = Atmosphere(atmosphereCfg, constants, "model");

    assert(atmosphere.troposphereProviderType == "profile", ...
        'Atmosphere should accept deterministic profile provider type.');

    assert(isa(atmosphere.troposphereProvider, ...
            'DeterministicTroposphereProfileProvider'), ...
        'Atmosphere should own a deterministic troposphere profile provider.');

    disp("PASS: deterministic troposphere profile provider interpolation is valid.");
end

function runProfileTroposphereDelayRegression()
    ProjectPathManager.addProjectPaths();

    epoch0 = datetime(2026, 5, 27, 23, 0, 0, ...
        'TimeZone', 'UTC');

    epochUtc = [epoch0; epoch0 + hours(1)];
    queryTime = epoch0 + minutes(30);

    pressure_hPa = [990.0; 1010.0];
    temperature_K = [285.0; 295.0];
    relativeHumidity_fraction = [0.40; 0.60];

    expectedPressure_hPa = 1000.0;
    expectedTemperature_K = 290.0;
    expectedRelativeHumidity_fraction = 0.50;

    profileCfg = struct( ...
        'datetimeUtc', epochUtc, ...
        'pressure_hPa', pressure_hPa, ...
        'temperature_K', temperature_K, ...
        'relativeHumidity_fraction', relativeHumidity_fraction, ...
        'source', "unit-test profile delay");

    constants = struct( ...
        'speedOfLight_mps', 299792458.0, ...
        'earthRadius_m', 6378137.0);

    atmosphereCfg = struct();
    atmosphereCfg.dataRoot = fullfile("data", "atmosphere");
    atmosphereCfg.missingDataPolicy = "error";
    atmosphereCfg.ionosphereShellHeight_m = 350000.0;

    atmosphereCfg.model = struct( ...
        'enableTroposphere', true, ...
        'enableIonosphere', false, ...
        'troposphereModel', "profile", ...
        'troposphereProviderType', "profile", ...
        'troposphereMappingFunction', "simple", ...
        'troposphereProfile', profileCfg, ...
        'ionosphereModel', "disabled", ...
        'minimumMappingElevation_deg', 3.0, ...
        'residualTroposphereSigma_m', 0.0, ...
        'residualIonosphereSigma_m', 0.0);

    atmosphere = Atmosphere(atmosphereCfg, constants, "model");

    assert(atmosphere.troposphereModel == "profile", ...
        'Atmosphere should accept troposphereModel="profile".');

    assert(isa(atmosphere.troposphereProvider, ...
            'DeterministicTroposphereProfileProvider'), ...
        'Profile troposphere model should own a deterministic profile provider.');

    towerCfg = struct( ...
        'name', 'ProfileDelayTower', ...
        'lat_deg', 28.3, ...
        'lon_deg', -16.5, ...
        'alt_m', 0.0, ...
        'txSignalDelay_m', 0.0);

    tower = GroundNode(towerCfg);

    elevation_deg = 35.0;
    azimuth_deg = 120.0;
    slantRange_m = 4.0e7;

    uEnu = [ ...
        cosd(elevation_deg) * sind(azimuth_deg); ...
        cosd(elevation_deg) * cosd(azimuth_deg); ...
        sind(elevation_deg)];

    R_enu_ecef = FrameGeometry.ecefToEnuDcm( ...
        tower.lat_deg, tower.lon_deg);

    uEcef = R_enu_ecef.' * uEnu;

    jd = Clock.julianDateFromDatetime(queryTime);

    receiverEcef_m = tower.pos_ECEF_m + slantRange_m * uEcef;
    receiverEci_m = FrameGeometry.ecefToEciDcm(jd) * receiverEcef_m;

    delay = atmosphere.codeDelayMeters( ...
        tower, receiverEci_m, jd, queryTime, 1575.42e6);

    assert(delay.valid, ...
        'Profile-provider troposphere delay should be valid.');

    assert(delay.ionosphere_m == 0.0, ...
        'Profile troposphere regression should have zero ionosphere delay.');

    tropo = delay.metadata.troposphere;

    assert(tropo.valid, ...
        'Profile troposphere diagnostics should be valid.');

    assert(tropo.providerType == "profile", ...
        'Profile troposphere diagnostics should report provider type profile.');

    assert(tropo.mappingFunction == "simple", ...
        'Profile troposphere diagnostics should record simple mapping.');

    temperature_C = expectedTemperature_K - 273.15;

    saturationVaporPressure_hPa = ...
        6.1121 * exp( ...
        (18.678 - temperature_C / 234.5) * ...
        (temperature_C / (257.14 + temperature_C)));

    expectedWaterVaporPressure_hPa = ...
        expectedRelativeHumidity_fraction * saturationVaporPressure_hPa;

    latitude_rad = deg2rad(double(tower.lat_deg));
    height_km = double(tower.alt_m) / 1000.0;

    heightCorrection = ...
        1.0 ...
        - 0.00266 * cos(2.0 * latitude_rad) ...
        - 0.00028 * height_km;

    expectedZhd_m = ...
        0.0022768 * expectedPressure_hPa / heightCorrection;

    expectedZwd_m = ...
        0.002277 * ...
        (1255.0 / expectedTemperature_K + 0.05) * ...
        expectedWaterVaporPressure_hPa;

    expectedMapping = ...
        1.0 / sind(max(delay.elevation_deg, 3.0));

    expectedSlantHydrostatic_m = expectedZhd_m * expectedMapping;
    expectedSlantWet_m = expectedZwd_m * expectedMapping;
    expectedTotal_m = expectedSlantHydrostatic_m + expectedSlantWet_m;

    assert(abs(tropo.pressure_hPa - expectedPressure_hPa) < 1e-12, ...
        'Profile troposphere pressure interpolation is incorrect.');

    assert(abs(tropo.temperature_K - expectedTemperature_K) < 1e-12, ...
        'Profile troposphere temperature interpolation is incorrect.');

    assert(abs(tropo.relativeHumidity_fraction - ...
        expectedRelativeHumidity_fraction) < 1e-12, ...
        'Profile troposphere relative humidity interpolation is incorrect.');

    assert(abs(tropo.waterVaporPressure_hPa - ...
        expectedWaterVaporPressure_hPa) < 1e-12, ...
        'Profile troposphere water vapour pressure is incorrect.');

    assert(abs(tropo.zenithHydrostaticDelay_m - expectedZhd_m) < 1e-12, ...
        'Profile zenith hydrostatic delay is incorrect.');

    assert(abs(tropo.zenithWetDelay_m - expectedZwd_m) < 1e-12, ...
        'Profile zenith wet delay is incorrect.');

    assert(abs(tropo.slantHydrostaticDelay_m - ...
        expectedSlantHydrostatic_m) < 1e-12, ...
        'Profile slant hydrostatic delay is incorrect.');

    assert(abs(tropo.slantWetDelay_m - expectedSlantWet_m) < 1e-12, ...
        'Profile slant wet delay is incorrect.');

    assert(abs(delay.troposphere_m - expectedTotal_m) < 1e-12, ...
        'Profile total troposphere delay is incorrect.');

    [delayWithGradient, gradientReceiverEci] = ...
        atmosphere.codeDelayAndGradientMeters( ...
        tower, receiverEci_m, jd, queryTime, 1575.42e6);

    assert(delayWithGradient.valid, ...
        'Profile troposphere delay with gradient should be valid.');

    assert(all(isfinite(gradientReceiverEci)), ...
        'Profile troposphere numerical gradient must be finite.');

    assert(norm(gradientReceiverEci) > 0.0, ...
        'Profile troposphere numerical gradient should be nonzero.');

    invalidCfg = atmosphereCfg;
    invalidCfg.missingDataPolicy = "invalid";

    invalidAtmosphere = Atmosphere(invalidCfg, constants, "model");

    outsideTime = epoch0 - hours(1);
    outsideJd = Clock.julianDateFromDatetime(outsideTime);
    outsideReceiverEci_m = FrameGeometry.ecefToEciDcm(outsideJd) * receiverEcef_m;

    invalidDelay = invalidAtmosphere.codeDelayMeters( ...
        tower, outsideReceiverEci_m, outsideJd, outsideTime, 1575.42e6);

    assert(~invalidDelay.valid, ...
        'Out-of-profile troposphere delay should be invalid with missingDataPolicy="invalid".');

    assert(isnan(invalidDelay.troposphere_m), ...
        'Out-of-profile troposphere delay should be NaN with missingDataPolicy="invalid".');

    disp("PASS: profile-provider troposphere delay model is valid.");
end

function runTroposphereProfileReportDiagnosticsRegression()
    ProjectPathManager.addProjectPaths();

    epoch0 = datetime(2026, 5, 27, 23, 0, 0, ...
        'TimeZone', 'UTC');

    epochUtc = [epoch0; epoch0 + hours(1)];

    profileCfg = struct( ...
        'datetimeUtc', epochUtc, ...
        'pressure_hPa', [990.0; 1010.0], ...
        'temperature_K', [285.0; 295.0], ...
        'relativeHumidity_fraction', [0.40; 0.60], ...
        'source', "unit-test profile report");

    simConfigOverride = makeShortRegressionOverride();
    scenarioPath = 'reverseGnssClockNavigationScenario';

    profileAtmosphereCfg = struct( ...
        'enableTroposphere', true, ...
        'enableIonosphere', false, ...
        'troposphereModel', "profile", ...
        'troposphereProviderType', "profile", ...
        'troposphereMappingFunction', "simple", ...
        'troposphereProfile', profileCfg, ...
        'ionosphereModel', "disabled", ...
        'minimumMappingElevation_deg', 3.0, ...
        'residualTroposphereSigma_m', 0.0, ...
        'residualIonosphereSigma_m', 0.0);

    simConfigOverride.scenarios.(scenarioPath).atmosphere.truth = ...
        profileAtmosphereCfg;

    simConfigOverride.scenarios.(scenarioPath).atmosphere.model = ...
        profileAtmosphereCfg;

    simConfigOverride.scenarios.(scenarioPath).measurement.enableElevationMask = true;
    simConfigOverride.scenarios.(scenarioPath).measurement.elevationMask_deg = 5.0;

    runtimeOptions = struct();
    runtimeOptions.entryPointName = ...
        "TroposphereProfileReportDiagnosticsRegression";
    runtimeOptions.simConfigOverride = simConfigOverride;

    sim = ReverseGnssSimulation(runtimeOptions);
    sim.configure();
    sim.run();

    visible = sim.history.visibility_mask_by_receiver_tower(:, :, 1);

    assert(any(visible(:)), ...
        'Troposphere profile report diagnostic regression produced no visible measurements.');

    truthPressure = ...
        sim.history.atmosphere_truth_troposphere_pressure_hPa_by_receiver_tower(:, :, 1);

    truthTemperature = ...
        sim.history.atmosphere_truth_troposphere_temperature_K_by_receiver_tower(:, :, 1);

    truthRelativeHumidity = ...
        sim.history.atmosphere_truth_troposphere_relative_humidity_fraction_by_receiver_tower(:, :, 1);

    truthWaterVaporPressure = ...
        sim.history.atmosphere_truth_troposphere_water_vapor_pressure_hPa_by_receiver_tower(:, :, 1);

    truthZhd = ...
        sim.history.atmosphere_truth_troposphere_zhd_m_by_receiver_tower(:, :, 1);

    truthZwd = ...
        sim.history.atmosphere_truth_troposphere_zwd_m_by_receiver_tower(:, :, 1);

    truthSlantHydrostatic = ...
        sim.history.atmosphere_truth_troposphere_slant_hydrostatic_m_by_receiver_tower(:, :, 1);

    truthSlantWet = ...
        sim.history.atmosphere_truth_troposphere_slant_wet_m_by_receiver_tower(:, :, 1);

    truthMappingHydrostatic = ...
        sim.history.atmosphere_truth_troposphere_mapping_hydrostatic_by_receiver_tower(:, :, 1);

    truthMappingWet = ...
        sim.history.atmosphere_truth_troposphere_mapping_wet_by_receiver_tower(:, :, 1);

    modelZhd = ...
        sim.history.atmosphere_model_troposphere_zhd_m_by_receiver_tower(:, :, 1);

    modelZwd = ...
        sim.history.atmosphere_model_troposphere_zwd_m_by_receiver_tower(:, :, 1);

    modelSlantHydrostatic = ...
        sim.history.atmosphere_model_troposphere_slant_hydrostatic_m_by_receiver_tower(:, :, 1);

    modelSlantWet = ...
        sim.history.atmosphere_model_troposphere_slant_wet_m_by_receiver_tower(:, :, 1);

    assert(all(isfinite(truthPressure(visible))), ...
        'Recorded truth pressure should be finite.');

    assert(all(isfinite(truthTemperature(visible))), ...
        'Recorded truth temperature should be finite.');

    assert(all(isfinite(truthRelativeHumidity(visible))), ...
        'Recorded truth relative humidity should be finite.');

    assert(all(isfinite(truthWaterVaporPressure(visible))), ...
        'Recorded truth water vapour pressure should be finite.');

    assert(all(isfinite(truthZhd(visible))), ...
        'Recorded truth ZHD should be finite.');

    assert(all(isfinite(truthZwd(visible))), ...
        'Recorded truth ZWD should be finite.');

    assert(all(isfinite(truthSlantHydrostatic(visible))), ...
        'Recorded truth slant hydrostatic delay should be finite.');

    assert(all(isfinite(truthSlantWet(visible))), ...
        'Recorded truth slant wet delay should be finite.');

    assert(all(isfinite(modelZhd(visible))), ...
        'Recorded model ZHD should be finite.');

    assert(all(isfinite(modelZwd(visible))), ...
        'Recorded model ZWD should be finite.');

    assert(all(isfinite(modelSlantHydrostatic(visible))), ...
        'Recorded model slant hydrostatic delay should be finite.');

    assert(all(isfinite(modelSlantWet(visible))), ...
        'Recorded model slant wet delay should be finite.');

    assert(all(abs(truthSlantHydrostatic(visible) - ...
        truthZhd(visible) .* truthMappingHydrostatic(visible)) < 1e-10), ...
        'Truth slant hydrostatic delay must equal ZHD times hydrostatic mapping factor.');

    assert(all(abs(truthSlantWet(visible) - ...
        truthZwd(visible) .* truthMappingWet(visible)) < 1e-10), ...
        'Truth slant wet delay must equal ZWD times wet mapping factor.');

    results = ResultBuilder.fromSimulation(sim);
    reportData = ReportDataBuilder.fromSimulation(sim);

    assert(isfield(results, ...
        'atmosphere_truth_troposphere_zhd_m_by_receiver_tower'));

    assert(isfield(results, ...
        'atmosphere_truth_troposphere_zwd_m_by_receiver_tower'));

    assert(isfield(results, ...
        'atmosphere_truth_troposphere_slant_hydrostatic_m_by_receiver_tower'));

    assert(isfield(results, ...
        'atmosphere_truth_troposphere_slant_wet_m_by_receiver_tower'));

    assert(isfield(results, ...
        'atmosphere_model_troposphere_zhd_m_by_receiver_tower'));

    assert(isfield(results, ...
        'atmosphere_model_troposphere_zwd_m_by_receiver_tower'));

    assert(isfield(results, ...
        'atmosphere_model_troposphere_slant_hydrostatic_m_by_receiver_tower'));

    assert(isfield(results, ...
        'atmosphere_model_troposphere_slant_wet_m_by_receiver_tower'));

    assert(isfield(reportData, ...
        'atmosphere_truth_troposphere_zhd_m_by_receiver_tower'));

    assert(isfield(reportData, ...
        'atmosphere_model_troposphere_zhd_m_by_receiver_tower'));

    assert(isfield(reportData, ...
        'atmosphere_truth_troposphere_slant_hydrostatic_m_by_receiver_tower'));

    assert(isfield(reportData, ...
        'atmosphere_model_troposphere_slant_hydrostatic_m_by_receiver_tower'));

    assert(isfield(reportData, 'troposphere_profile_summary_table'), ...
        'Report data should contain troposphere profile summary table.');

    assert(any(contains( ...
        string(reportData.troposphere_profile_summary_table.Quantity), ...
        "Mean truth ZHD")), ...
        'Troposphere profile summary table should contain mean truth ZHD.');

    assert(any(contains( ...
        string(reportData.troposphere_profile_summary_table.Quantity), ...
        "Mean estimator ZHD")), ...
        'Troposphere profile summary table should contain mean estimator ZHD.');

    assert(any(isfinite( ...
        reportData.atmosphere_truth_troposphere_slant_hydrostatic_m_by_receiver_tower(:))), ...
        'Troposphere profile plot source should contain finite truth slant hydrostatic delay.');

    assert(any(isfinite( ...
        reportData.atmosphere_model_troposphere_slant_hydrostatic_m_by_receiver_tower(:))), ...
        'Troposphere profile plot source should contain finite model slant hydrostatic delay.');

    disp("PASS: troposphere profile history and report diagnostics are recorded.");
end

function runIonosphereProviderInterfaceRegression()
    ProjectPathManager.addProjectPaths();

    provider = IonosphereMapProviderFactory.create( ...
        "none", ...
        fullfile("data", "atmosphere"), ...
        struct(), ...
        "model");

    assert(isa(provider, 'IonosphereMapProvider'), ...
        'Provider must implement IonosphereMapProvider.');

    assert(isa(provider, 'NullIonosphereMapProvider'), ...
        'Default provider should be NullIonosphereMapProvider.');

    assert(~provider.isAvailable(), ...
        'Null provider must report unavailable.');

    queryTime = datetime(2026, 5, 27, 23, 0, 0, 'TimeZone', 'UTC');

    result = provider.verticalTecAt(queryTime, 52.0, 13.0);

    assert(isstruct(result), ...
        'Provider result must be a struct.');

    assert(isfield(result, 'valid'));
    assert(isfield(result, 'vtec_TECU'));
    assert(isfield(result, 'latitude_deg'));
    assert(isfield(result, 'longitude_deg'));
    assert(isfield(result, 'providerType'));

    assert(~result.valid, ...
        'Null provider must return invalid VTEC data.');

    assert(isnan(result.vtec_TECU), ...
        'Null provider VTEC must be NaN.');

    constants = struct( ...
        'speedOfLight_mps', 299792458.0, ...
        'earthRadius_m', 6378137.0);

    atmosphereCfg = struct();
    atmosphereCfg.dataRoot = fullfile("data", "atmosphere");
    atmosphereCfg.missingDataPolicy = "error";
    atmosphereCfg.ionosphereShellHeight_m = 350000.0;

    atmosphereCfg.model = struct( ...
        'enableTroposphere', false, ...
        'enableIonosphere', false, ...
        'ionosphereProviderType', "none");

    atmosphere = Atmosphere(atmosphereCfg, constants, "model");

    assert(atmosphere.ionosphereProviderType == "none", ...
        'Atmosphere should store ionosphereProviderType.');

    assert(isa(atmosphere.ionosphereProvider, 'NullIonosphereMapProvider'), ...
        'Atmosphere should own a null ionosphere provider by default.');

    ionexCfg = atmosphereCfg;
    ionexCfg.model.ionosphereProviderType = "ionex";

    ionexAtmosphere = Atmosphere(ionexCfg, constants, "model");

    assert(ionexAtmosphere.ionosphereProviderType == "ionex", ...
        'Atmosphere should accept the ionex provider type.');

    assert(isa(ionexAtmosphere.ionosphereProvider, ...
            'NullIonosphereMapProvider'), ...
        ['IONEX provider type should currently resolve to the null ', ...
         'provider until IonexProvider is implemented.']);

    assert(~ionexAtmosphere.ionosphereProvider.isAvailable(), ...
        'IONEX placeholder provider should not be available yet.');

    disp("PASS: ionosphere provider interface is available and baseline-safe.");
end

function runGriddedIonosphereProviderInterpolationRegression()
    ProjectPathManager.addProjectPaths();

    epoch0 = datetime(2026, 5, 27, 23, 0, 0, 'TimeZone', 'UTC');
    epochUtc = [epoch0; epoch0 + hours(1)];

    latitude_deg = [-10.0; 10.0];
    longitude_deg = [0.0; 20.0];

    vtec_TECU = zeros( ...
        numel(latitude_deg), ...
        numel(longitude_deg), ...
        numel(epochUtc));

    for it = 1:numel(epochUtc)
        for ilat = 1:numel(latitude_deg)
            for ilon = 1:numel(longitude_deg)
                vtec_TECU(ilat, ilon, it) = ...
                    100.0 ...
                    + latitude_deg(ilat) ...
                    + 2.0 * longitude_deg(ilon) ...
                    + 10.0 * (it - 1);
            end
        end
    end

    mapCfg = struct( ...
        'datetimeUtc', epochUtc, ...
        'latitude_deg', latitude_deg, ...
        'longitude_deg', longitude_deg, ...
        'vtec_TECU', vtec_TECU, ...
        'rms_TECU', ones(size(vtec_TECU)) * 0.5, ...
        'source', "unit-test grid");

    providerCfg = struct();
    providerCfg.ionosphereMap = mapCfg;

    provider = IonosphereMapProviderFactory.create( ...
        "grid", ...
        fullfile("data", "atmosphere"), ...
        providerCfg, ...
        "model");

    assert(isa(provider, 'GriddedIonosphereMapProvider'), ...
        'Grid provider type should construct GriddedIonosphereMapProvider.');

    assert(provider.isAvailable(), ...
        'Grid provider should be available.');

    queryTime = epoch0 + minutes(30);
    queryLat_deg = 0.0;
    queryLon_deg = 10.0;

    result = provider.verticalTecAt( ...
        queryTime, queryLat_deg, queryLon_deg);

    expectedVtec_TECU = ...
        100.0 ...
        + queryLat_deg ...
        + 2.0 * queryLon_deg ...
        + 10.0 * 0.5;

    assert(result.valid, ...
        'Grid provider interpolation result should be valid.');

    assert(abs(result.vtec_TECU - expectedVtec_TECU) < 1e-12, ...
        'Grid provider VTEC interpolation is incorrect.');

    assert(abs(result.rms_TECU - 0.5) < 1e-12, ...
        'Grid provider RMS interpolation is incorrect.');

    assert(result.metadata.latitudeIndex0 == 1);
    assert(result.metadata.latitudeIndex1 == 2);
    assert(result.metadata.longitudeIndex0 == 1);
    assert(result.metadata.longitudeIndex1 == 2);
    assert(result.metadata.timeIndex0 == 1);
    assert(result.metadata.timeIndex1 == 2);

    outsideResult = provider.verticalTecAt( ...
        queryTime, 80.0, queryLon_deg);

    assert(~outsideResult.valid, ...
        'Grid provider should reject queries outside latitude coverage.');

    constants = struct( ...
        'speedOfLight_mps', 299792458.0, ...
        'earthRadius_m', 6378137.0);

    atmosphereCfg = struct();
    atmosphereCfg.dataRoot = fullfile("data", "atmosphere");
    atmosphereCfg.missingDataPolicy = "error";
    atmosphereCfg.ionosphereShellHeight_m = 350000.0;

    atmosphereCfg.model = struct( ...
        'enableTroposphere', false, ...
        'enableIonosphere', false, ...
        'ionosphereProviderType', "grid", ...
        'ionosphereMap', mapCfg);

    atmosphere = Atmosphere(atmosphereCfg, constants, "model");

    assert(atmosphere.ionosphereProviderType == "grid", ...
        'Atmosphere should accept the grid ionosphere provider type.');

    assert(isa(atmosphere.ionosphereProvider, ...
            'GriddedIonosphereMapProvider'), ...
        'Atmosphere should own a gridded ionosphere provider.');

    disp("PASS: gridded ionosphere provider interpolation is valid.");
end

function runIonexParserProviderRegression()
    ProjectPathManager.addProjectPaths();

    ionexText = [
        "     0                                                      EXPONENT"
        "                                                            END OF HEADER"
        "     1                                                      START OF TEC MAP"
        "  2026     5    27    23     0     0                       EPOCH OF CURRENT MAP"
        "   -10.0     0.0    20.0    20.0   350.0                   LAT/LON1/LON2/DLON/H"
        "     90   130"
        "    10.0     0.0    20.0    20.0   350.0                   LAT/LON1/LON2/DLON/H"
        "    110   150"
        "                                                            END OF TEC MAP"
        "     2                                                      START OF TEC MAP"
        "  2026     5    28     0     0     0                       EPOCH OF CURRENT MAP"
        "   -10.0     0.0    20.0    20.0   350.0                   LAT/LON1/LON2/DLON/H"
        "    100   140"
        "    10.0     0.0    20.0    20.0   350.0                   LAT/LON1/LON2/DLON/H"
        "    120   160"
        "                                                            END OF TEC MAP"
        ];

    ionexFile = fullfile(tempdir, ...
        sprintf('reverse_gnss_test_%s.ionex', char(java.util.UUID.randomUUID)));

    fid = fopen(ionexFile, 'w');

    assert(fid > 0, ...
        'Could not create temporary IONEX file.');

    cleanup = onCleanup(@() deleteTemporaryFile(ionexFile));

    for k = 1:numel(ionexText)
        fprintf(fid, '%s\n', ionexText(k));
    end

    fclose(fid);

    mapCfg = IonexParser.parseFile(ionexFile);

    assert(isfield(mapCfg, 'datetimeUtc'));
    assert(isfield(mapCfg, 'latitude_deg'));
    assert(isfield(mapCfg, 'longitude_deg'));
    assert(isfield(mapCfg, 'vtec_TECU'));

    assert(numel(mapCfg.datetimeUtc) == 2);
    assert(isequal(mapCfg.latitude_deg(:), [-10.0; 10.0]));
    assert(isequal(mapCfg.longitude_deg(:), [0.0; 20.0]));

    providerCfg = struct();
    providerCfg.ionexFile = ionexFile;

    provider = IonosphereMapProviderFactory.create( ...
        "ionex", ...
        "", ...
        providerCfg, ...
        "model");

    assert(isa(provider, 'IonexIonosphereMapProvider'), ...
        'IONEX source should construct IonexIonosphereMapProvider.');

    assert(provider.isAvailable(), ...
        'IONEX provider should be available.');

    queryTime = datetime(2026, 5, 27, 23, 30, 0, 'TimeZone', 'UTC');

    result = provider.verticalTecAt(queryTime, 0.0, 10.0);

    expectedVtec_TECU = 125.0;

    assert(result.valid, ...
        'IONEX provider interpolation should be valid.');

    assert(abs(result.vtec_TECU - expectedVtec_TECU) < 1e-12, ...
        'IONEX provider VTEC interpolation is incorrect.');

    assert(result.providerType == "ionex", ...
        'IONEX provider result should identify providerType ionex.');

    assert(string(result.source) == string(ionexFile), ...
        'IONEX provider result should report the source file.');

    constants = struct( ...
        'speedOfLight_mps', 299792458.0, ...
        'earthRadius_m', 6378137.0);

    atmosphereCfg = struct();
    atmosphereCfg.dataRoot = "";
    atmosphereCfg.missingDataPolicy = "error";
    atmosphereCfg.ionosphereShellHeight_m = 350000.0;

    atmosphereCfg.model = struct( ...
        'enableTroposphere', false, ...
        'enableIonosphere', false, ...
        'ionosphereProviderType', "ionex", ...
        'ionexFile', ionexFile);

    atmosphere = Atmosphere(atmosphereCfg, constants, "model");

    assert(atmosphere.ionosphereProviderType == "ionex", ...
        'Atmosphere should accept ionex provider type.');

    assert(isa(atmosphere.ionosphereProvider, ...
            'IonexIonosphereMapProvider'), ...
        'Atmosphere should own an IONEX ionosphere provider when a source file is configured.');

    disp("PASS: IONEX parser and provider interpolation are valid.");
end

function runIonexParserEdgeCaseRegression()
    ProjectPathManager.addProjectPaths();

    exponentIonexFile = string([tempname, '_exponent_reversed_lat.ionex']);
    missingIonexFile = string([tempname, '_missing_values.ionex']);
    narrowIonexFile = string([tempname, '_narrow_grid.ionex']);

    cleanupExponent = onCleanup(@() deleteTemporaryFile(exponentIonexFile));
    cleanupMissing = onCleanup(@() deleteTemporaryFile(missingIonexFile));
    cleanupNarrow = onCleanup(@() deleteTemporaryFile(narrowIonexFile));

    exponentIonexText = [
        "    -1                                                      EXPONENT"
        "                                                            END OF HEADER"
        "     1                                                      START OF TEC MAP"
        "  2026     5    27    23     0     0                       EPOCH OF CURRENT MAP"
        "    10.0     0.0    20.0    20.0   350.0                   LAT/LON1/LON2/DLON/H"
        "    110   130"
        "   -10.0     0.0    20.0    20.0   350.0                   LAT/LON1/LON2/DLON/H"
        "     90   110"
        "                                                            END OF TEC MAP"
        "     2                                                      START OF TEC MAP"
        "  2026     5    28     0     0     0                       EPOCH OF CURRENT MAP"
        "    10.0     0.0    20.0    20.0   350.0                   LAT/LON1/LON2/DLON/H"
        "    130   150"
        "   -10.0     0.0    20.0    20.0   350.0                   LAT/LON1/LON2/DLON/H"
        "    110   130"
        "                                                            END OF TEC MAP"
        ];

    writeIonexTextFile(exponentIonexFile, exponentIonexText);

    mapCfg = IonexParser.parseFile(exponentIonexFile);

    assert(isequal(mapCfg.latitude_deg(:), [-10.0; 10.0]), ...
        'IONEX parser should sort reversed latitude rows into ascending order.');

    assert(isequal(mapCfg.longitude_deg(:), [0.0; 20.0]), ...
        'IONEX parser longitude grid is incorrect.');

    assert(abs(mapCfg.vtec_TECU(1, 1, 1) - 9.0) < 1e-12, ...
        'IONEX exponent scaling failed for first latitude row.');

    assert(abs(mapCfg.vtec_TECU(2, 2, 1) - 13.0) < 1e-12, ...
        'IONEX exponent scaling failed for second latitude row.');

    providerCfg = struct();
    providerCfg.ionexFile = exponentIonexFile;

    provider = IonosphereMapProviderFactory.create( ...
        "ionex", ...
        "", ...
        providerCfg, ...
        "model");

    queryTime = datetime(2026, 5, 27, 23, 30, 0, ...
        'TimeZone', 'UTC');

    result = provider.verticalTecAt(queryTime, 0.0, 10.0);

    assert(result.valid, ...
        'IONEX provider should interpolate inside the grid.');

    assert(abs(result.vtec_TECU - 12.0) < 1e-12, ...
        'IONEX provider failed combined latitude/longitude/time interpolation.');

    outsideLatitude = provider.verticalTecAt(queryTime, 50.0, 10.0);

    assert(~outsideLatitude.valid, ...
        'IONEX provider should mark latitude queries outside the grid invalid.');

    outsideTime = provider.verticalTecAt( ...
        datetime(2026, 5, 28, 2, 0, 0, 'TimeZone', 'UTC'), ...
        0.0, ...
        10.0);

    assert(~outsideTime.valid, ...
        'IONEX provider should mark time queries outside the grid invalid.');

    missingIonexText = [
        "     0                                                      EXPONENT"
        "                                                            END OF HEADER"
        "     1                                                      START OF TEC MAP"
        "  2026     5    27    23     0     0                       EPOCH OF CURRENT MAP"
        "   -10.0     0.0    20.0    20.0   350.0                   LAT/LON1/LON2/DLON/H"
        "   9999    10"
        "                                                            END OF TEC MAP"
        ];

    writeIonexTextFile(missingIonexFile, missingIonexText);

    missingValueErrorDetected = false;

    try
        IonexParser.parseFile(missingIonexFile);
    catch ME
        missingValueErrorDetected = ...
            strcmp(ME.identifier, ...
            'IonexParser:MissingTecValuesUnsupported');
    end

    assert(missingValueErrorDetected, ...
        'IONEX parser should reject unsupported missing TEC values.');

    narrowIonexText = [
        "     0                                                      EXPONENT"
        "                                                            END OF HEADER"
        "     1                                                      START OF TEC MAP"
        "  2026     5    27    23     0     0                       EPOCH OF CURRENT MAP"
        "    80.0   100.0   120.0    20.0   350.0                   LAT/LON1/LON2/DLON/H"
        "     10    10"
        "    90.0   100.0   120.0    20.0   350.0                   LAT/LON1/LON2/DLON/H"
        "     10    10"
        "                                                            END OF TEC MAP"
        "     2                                                      START OF TEC MAP"
        "  2026     5    28     0     0     0                       EPOCH OF CURRENT MAP"
        "    80.0   100.0   120.0    20.0   350.0                   LAT/LON1/LON2/DLON/H"
        "     10    10"
        "    90.0   100.0   120.0    20.0   350.0                   LAT/LON1/LON2/DLON/H"
        "     10    10"
        "                                                            END OF TEC MAP"
        ];

    writeIonexTextFile(narrowIonexFile, narrowIonexText);

    datetimeUtc = datetime(2026, 5, 27, 23, 30, 0, ...
        'TimeZone', 'UTC');

    jd = Clock.julianDateFromDatetime(datetimeUtc);

    constants = struct( ...
        'speedOfLight_mps', 299792458.0, ...
        'earthRadius_m', 6378137.0);

    atmosphereCfg = struct();
    atmosphereCfg.dataRoot = "";
    atmosphereCfg.missingDataPolicy = "invalid";
    atmosphereCfg.ionosphereShellHeight_m = 350000.0;

    atmosphereCfg.model = struct( ...
        'enableTroposphere', false, ...
        'enableIonosphere', true, ...
        'troposphereModel', "disabled", ...
        'ionosphereModel', "ionex", ...
        'ionosphereProviderType', "ionex", ...
        'ionexFile', narrowIonexFile, ...
        'residualTroposphereSigma_m', 0.0, ...
        'residualIonosphereSigma_m', 0.0);

    atmosphere = Atmosphere(atmosphereCfg, constants, "model");

    towerCfg = struct( ...
        'name', 'IonexMissingPolicyTower', ...
        'lat_deg', 0.0, ...
        'lon_deg', 0.0, ...
        'alt_m', 0.0, ...
        'txSignalDelay_m', 0.0);

    tower = GroundNode(towerCfg);

    receiverEcef_m = [6378137.0 + 4.0e7; 0.0; 0.0];
    receiverEci_m = FrameGeometry.ecefToEciDcm(jd) * receiverEcef_m;

    delay = atmosphere.codeDelayMeters( ...
        tower, receiverEci_m, jd, datetimeUtc, 1575.42e6);

    assert(~delay.valid, ...
        'missingDataPolicy="invalid" should return an invalid delay instead of throwing.');

    assert(isnan(delay.ionosphere_m), ...
        'Out-of-grid IONEX with missingDataPolicy="invalid" should produce NaN ionosphere delay.');

    disp("PASS: IONEX parser edge cases are covered.");
end

function runIonexConfigurationExampleRegression()
    ProjectPathManager.addProjectPaths();

    ionexFile = string([tempname, '_config_example.ionex']);
    cleanupIonex = onCleanup(@() deleteTemporaryFile(ionexFile));

    writeUniformIonexTestFile(ionexFile, 12.0);

    constants = struct( ...
        'speedOfLight_mps', 299792458.0, ...
        'earthRadius_m', 6378137.0);

    atmosphereCfg = struct();
    atmosphereCfg.dataRoot = "";
    atmosphereCfg.missingDataPolicy = "error";
    atmosphereCfg.ionosphereShellHeight_m = 350000.0;

    ionexExampleCfg = struct( ...
        'enableTroposphere', false, ...
        'enableIonosphere', true, ...
        'troposphereModel', "disabled", ...
        'ionosphereModel', "ionex", ...
        'ionosphereProviderType', "ionex", ...
        'ionexFile', ionexFile, ...
        'residualTroposphereSigma_m', 0.0, ...
        'residualIonosphereSigma_m', 0.0);

    atmosphereCfg.truth = ionexExampleCfg;
    atmosphereCfg.model = ionexExampleCfg;

    truthAtmosphere = Atmosphere(atmosphereCfg, constants, "truth");
    modelAtmosphere = Atmosphere(atmosphereCfg, constants, "model");

    assert(truthAtmosphere.ionosphereModel == "ionex", ...
        'IONEX config example should select ionosphereModel="ionex" for truth.');

    assert(modelAtmosphere.ionosphereModel == "ionex", ...
        'IONEX config example should select ionosphereModel="ionex" for model.');

    assert(truthAtmosphere.ionosphereProviderType == "ionex", ...
        'IONEX config example should select ionosphereProviderType="ionex" for truth.');

    assert(modelAtmosphere.ionosphereProviderType == "ionex", ...
        'IONEX config example should select ionosphereProviderType="ionex" for model.');

    assert(isa(truthAtmosphere.ionosphereProvider, ...
            'IonexIonosphereMapProvider'), ...
        'Truth IONEX config example should construct IonexIonosphereMapProvider.');

    assert(isa(modelAtmosphere.ionosphereProvider, ...
            'IonexIonosphereMapProvider'), ...
        'Model IONEX config example should construct IonexIonosphereMapProvider.');

    assert(truthAtmosphere.ionosphereProvider.isAvailable(), ...
        'Truth IONEX provider from config example should be available.');

    assert(modelAtmosphere.ionosphereProvider.isAvailable(), ...
        'Model IONEX provider from config example should be available.');

    configPath = fullfile( ...
        fileparts(mfilename('fullpath')), ...
        'config', ...
        'SimulationConfig.m');

    configText = string(fileread(configPath));

    assert(contains(configText, ...
            'IONEX first-order code ionosphere correction example'), ...
        'SimulationConfig should document the IONEX usage example.');

    assert(contains(configText, ...
            'ionosphereProviderType = "ionex"'), ...
        'SimulationConfig should document ionosphereProviderType="ionex".');

    assert(contains(configText, ...
            'ionexFile = "example.ionex"'), ...
        'SimulationConfig should document ionexFile usage.');

    assert(contains(configText, ...
            'missingDataPolicy="error"'), ...
        'SimulationConfig should document recommended IONEX missing-data policy.');

    disp("PASS: IONEX configuration example is documented and constructible.");
end

function runIonexAtmosphereDelayRegression()
    ProjectPathManager.addProjectPaths();

    ionexText = [
        "     0                                                      EXPONENT"
        "                                                            END OF HEADER"
        "     1                                                      START OF TEC MAP"
        "  2026     5    27    23     0     0                       EPOCH OF CURRENT MAP"
        "   -90.0  -180.0   180.0   360.0   350.0                   LAT/LON1/LON2/DLON/H"
        "     10    10"
        "    90.0  -180.0   180.0   360.0   350.0                   LAT/LON1/LON2/DLON/H"
        "     10    10"
        "                                                            END OF TEC MAP"
        "     2                                                      START OF TEC MAP"
        "  2026     5    28     0     0     0                       EPOCH OF CURRENT MAP"
        "   -90.0  -180.0   180.0   360.0   350.0                   LAT/LON1/LON2/DLON/H"
        "     10    10"
        "    90.0  -180.0   180.0   360.0   350.0                   LAT/LON1/LON2/DLON/H"
        "     10    10"
        "                                                            END OF TEC MAP"
        ];

    ionexFile = fullfile(tempdir, ...
        sprintf('reverse_gnss_ionex_delay_%s.ionex', ...
        char(java.util.UUID.randomUUID)));

    fid = fopen(ionexFile, 'w');

    assert(fid > 0, ...
        'Could not create temporary IONEX delay test file.');

    cleanup = onCleanup(@() deleteTemporaryFile(ionexFile));

    for k = 1:numel(ionexText)
        fprintf(fid, '%s\n', ionexText(k));
    end

    fclose(fid);

    datetimeUtc = datetime(2026, 5, 27, 23, 30, 0, ...
        'TimeZone', 'UTC');

    jd = Clock.julianDateFromDatetime(datetimeUtc);

    constants = struct( ...
        'speedOfLight_mps', 299792458.0, ...
        'earthRadius_m', 6378137.0);

    atmosphereCfg = struct();
    atmosphereCfg.dataRoot = "";
    atmosphereCfg.missingDataPolicy = "error";
    atmosphereCfg.ionosphereShellHeight_m = 350000.0;

    atmosphereCfg.model = struct( ...
        'enableTroposphere', false, ...
        'enableIonosphere', true, ...
        'troposphereModel', "disabled", ...
        'ionosphereModel', "ionex", ...
        'ionosphereProviderType', "ionex", ...
        'ionexFile', ionexFile, ...
        'residualTroposphereSigma_m', 0.0, ...
        'residualIonosphereSigma_m', 0.0);

    atmosphere = Atmosphere(atmosphereCfg, constants, "model");

    towerCfg = struct( ...
        'name', 'IonexDelayTower', ...
        'lat_deg', 28.3, ...
        'lon_deg', -16.5, ...
        'alt_m', 0.0, ...
        'txSignalDelay_m', 0.0);

    tower = GroundNode(towerCfg);

    elevation_deg = 45.0;
    azimuth_deg = 120.0;
    slantRange_m = 4.0e7;

    uEnu = [ ...
        cosd(elevation_deg) * sind(azimuth_deg); ...
        cosd(elevation_deg) * cosd(azimuth_deg); ...
        sind(elevation_deg)];

    R_enu_ecef = FrameGeometry.ecefToEnuDcm( ...
        tower.lat_deg, tower.lon_deg);

    uEcef = R_enu_ecef.' * uEnu;

    receiverEcef_m = tower.pos_ECEF_m + slantRange_m * uEcef;
    receiverEci_m = FrameGeometry.ecefToEciDcm(jd) * receiverEcef_m;

    frequency_Hz = 1575.42e6;

    delay = atmosphere.codeDelayMeters( ...
        tower, receiverEci_m, jd, datetimeUtc, frequency_Hz);

    assert(delay.valid, ...
        'IONEX atmosphere delay should be valid.');

    assert(delay.troposphere_m == 0.0, ...
        'IONEX-only test should have zero troposphere delay.');

    assert(delay.ionosphere_m > 0.0, ...
        'IONEX code ionosphere delay should be positive.');

    assert(delay.metadata.ionospherePiercePoint.valid, ...
        'IONEX delay metadata must contain a valid pierce point.');

    assert(delay.metadata.ionosphereMap.valid, ...
        'IONEX delay metadata must contain a valid VTEC map query.');

    assert(delay.metadata.ionosphereMap.providerType == "ionex", ...
        'IONEX delay metadata should report provider type ionex.');

    assert(abs(delay.metadata.ionosphereMap.vtec_TECU - 10.0) < 1e-12, ...
        'IONEX test VTEC should interpolate to 10 TECU.');

    expectedDelay_m = ...
        40.3 * ...
        (10.0 * 1.0e16 * ...
        delay.metadata.ionospherePiercePoint.mappingFactor) / ...
        frequency_Hz^2;

    assert(abs(delay.ionosphere_m - expectedDelay_m) < 1e-10, ...
        'IONEX atmosphere delay does not match first-order code delay formula.');

    [delayWithGradient, gradientReceiverEci] = ...
        atmosphere.codeDelayAndGradientMeters( ...
        tower, receiverEci_m, jd, datetimeUtc, frequency_Hz);

    assert(delayWithGradient.valid, ...
        'IONEX atmosphere delay with gradient should be valid.');

    assert(all(isfinite(gradientReceiverEci)), ...
        'IONEX numerical atmosphere gradient must be finite.');

    assert(norm(gradientReceiverEci) > 0.0, ...
        'IONEX numerical gradient should be nonzero for oblique geometry.');

    disp("PASS: IONEX atmosphere code-delay model is valid.");
end

function runIonexHistoryReportDiagnosticsRegression()
    ProjectPathManager.addProjectPaths();

    ionexText = [
        "     0                                                      EXPONENT"
        "                                                            END OF HEADER"
        "     1                                                      START OF TEC MAP"
        "  2026     5    27    23     0     0                       EPOCH OF CURRENT MAP"
        "   -90.0  -180.0   180.0   360.0   350.0                   LAT/LON1/LON2/DLON/H"
        "     10    10"
        "    90.0  -180.0   180.0   360.0   350.0                   LAT/LON1/LON2/DLON/H"
        "     10    10"
        "                                                            END OF TEC MAP"
        "     2                                                      START OF TEC MAP"
        "  2026     5    28     0     0     0                       EPOCH OF CURRENT MAP"
        "   -90.0  -180.0   180.0   360.0   350.0                   LAT/LON1/LON2/DLON/H"
        "     10    10"
        "    90.0  -180.0   180.0   360.0   350.0                   LAT/LON1/LON2/DLON/H"
        "     10    10"
        "                                                            END OF TEC MAP"
        ];

    ionexFile = fullfile(tempdir, ...
        sprintf('reverse_gnss_ionex_history_%s.ionex', ...
        char(java.util.UUID.randomUUID)));

    fid = fopen(ionexFile, 'w');

    assert(fid > 0, ...
        'Could not create temporary IONEX history test file.');

    cleanup = onCleanup(@() deleteTemporaryFile(ionexFile));

    for k = 1:numel(ionexText)
        fprintf(fid, '%s\n', ionexText(k));
    end

    fclose(fid);

    simConfigOverride = makeShortRegressionOverride();
    scenarioPath = 'reverseGnssClockNavigationScenario';

    ionexAtmosphereCfg = struct( ...
        'enableTroposphere', false, ...
        'enableIonosphere', true, ...
        'troposphereModel', "disabled", ...
        'ionosphereModel', "ionex", ...
        'ionosphereProviderType', "ionex", ...
        'ionexFile', ionexFile, ...
        'residualTroposphereSigma_m', 0.0, ...
        'residualIonosphereSigma_m', 0.0);

    simConfigOverride.scenarios.(scenarioPath).atmosphere.truth = ...
        ionexAtmosphereCfg;

    simConfigOverride.scenarios.(scenarioPath).atmosphere.model = ...
        ionexAtmosphereCfg;

    simConfigOverride.scenarios.(scenarioPath).measurement.enableElevationMask = true;
    simConfigOverride.scenarios.(scenarioPath).measurement.elevationMask_deg = 5.0;

    runtimeOptions = struct();
    runtimeOptions.entryPointName = "IonexHistoryReportDiagnosticsRegression";
    runtimeOptions.simConfigOverride = simConfigOverride;

    sim = ReverseGnssSimulation(runtimeOptions);
    sim.configure();
    sim.run();

    visible = sim.history.visibility_mask_by_receiver_tower(:, :, 1);

    assert(any(visible(:)), ...
        'IONEX history diagnostic regression produced no visible measurements.');

    truthVtec = ...
        sim.history.atmosphere_truth_ionosphere_vtec_TECU_by_receiver_tower(:, :, 1);

    truthStec = ...
        sim.history.atmosphere_truth_ionosphere_stec_TECU_by_receiver_tower(:, :, 1);

    truthMapping = ...
        sim.history.atmosphere_truth_ionosphere_mapping_factor_by_receiver_tower(:, :, 1);

    truthLat = ...
        sim.history.atmosphere_truth_ionosphere_ipp_lat_deg_by_receiver_tower(:, :, 1);

    truthLon = ...
        sim.history.atmosphere_truth_ionosphere_ipp_lon_deg_by_receiver_tower(:, :, 1);

    assert(all(abs(truthVtec(visible) - 10.0) < 1e-12), ...
        'Recorded IONEX truth VTEC should equal 10 TECU.');

    assert(all(isfinite(truthStec(visible))), ...
        'Recorded IONEX truth STEC should be finite.');

    assert(all(isfinite(truthMapping(visible))), ...
        'Recorded IONEX truth mapping factor should be finite.');

    assert(all(isfinite(truthLat(visible))), ...
        'Recorded IONEX truth IPP latitude should be finite.');

    assert(all(isfinite(truthLon(visible))), ...
        'Recorded IONEX truth IPP longitude should be finite.');

    assert(all(abs(truthStec(visible) - ...
        truthVtec(visible) .* truthMapping(visible)) < 1e-10), ...
        'Recorded STEC must equal VTEC times mapping factor.');

    results = ResultBuilder.fromSimulation(sim);
    reportData = ReportDataBuilder.fromSimulation(sim);

    assert(isfield(results, ...
        'atmosphere_truth_ionosphere_vtec_TECU_by_receiver_tower'));

    assert(isfield(results, ...
        'atmosphere_truth_ionosphere_stec_TECU_by_receiver_tower'));

    assert(isfield(results, ...
        'atmosphere_truth_ionosphere_mapping_factor_by_receiver_tower'));

    assert(isfield(results, ...
        'atmosphere_model_ionosphere_vtec_TECU_by_receiver_tower'));

    assert(isfield(results, ...
        'atmosphere_model_ionosphere_stec_TECU_by_receiver_tower'));

    assert(isfield(results, ...
        'atmosphere_model_ionosphere_mapping_factor_by_receiver_tower'));

    assert(isfield(reportData, ...
        'atmosphere_truth_ionosphere_vtec_TECU_by_receiver_tower'));

    assert(isfield(reportData, ...
        'atmosphere_model_ionosphere_vtec_TECU_by_receiver_tower'));

    modelVtec = ...
        sim.history.atmosphere_model_ionosphere_vtec_TECU_by_receiver_tower(:, :, 1);

    modelStec = ...
        sim.history.atmosphere_model_ionosphere_stec_TECU_by_receiver_tower(:, :, 1);

    modelMapping = ...
        sim.history.atmosphere_model_ionosphere_mapping_factor_by_receiver_tower(:, :, 1);

    assert(all(abs(modelVtec(visible) - 10.0) < 1e-12), ...
        'Recorded IONEX model VTEC should equal 10 TECU.');

    assert(all(isfinite(modelStec(visible))), ...
        'Recorded IONEX model STEC should be finite.');

    assert(all(isfinite(modelMapping(visible))), ...
        'Recorded IONEX model mapping factor should be finite.');

    assert(all(abs(modelStec(visible) - ...
        modelVtec(visible) .* modelMapping(visible)) < 1e-10), ...
        'Recorded model STEC must equal model VTEC times model mapping factor.');

    assert(all(abs( ...
        results.atmosphere_model_ionosphere_vtec_TECU_by_receiver_tower(:, :, 1) - ...
        sim.history.atmosphere_model_ionosphere_vtec_TECU_by_receiver_tower(:, :, 1)) < 1e-12 | ...
        ~visible, 'all'), ...
        'ResultBuilder model VTEC export should match simulation history.');

    assert(isfield(reportData, 'ionosphere_map_summary_table'), ...
        'Report data should contain ionosphere map summary table.');

        assert(any(isfinite( ...
        reportData.atmosphere_truth_ionosphere_vtec_TECU_by_receiver_tower(:))), ...
        'IONEX report plot source should contain finite truth VTEC.');

    assert(any(isfinite( ...
        reportData.atmosphere_model_ionosphere_vtec_TECU_by_receiver_tower(:))), ...
        'IONEX report plot source should contain finite model VTEC.');

    assert(any(isfinite( ...
        reportData.atmosphere_truth_ionosphere_stec_TECU_by_receiver_tower(:))), ...
        'IONEX report plot source should contain finite truth STEC.');

    assert(any(isfinite( ...
        reportData.atmosphere_model_ionosphere_stec_TECU_by_receiver_tower(:))), ...
        'IONEX report plot source should contain finite model STEC.');

    assert(any(isfinite( ...
        reportData.atmosphere_truth_ionosphere_mapping_factor_by_receiver_tower(:))), ...
        'IONEX report plot source should contain finite truth mapping factor.');

    assert(any(isfinite( ...
        reportData.atmosphere_model_ionosphere_mapping_factor_by_receiver_tower(:))), ...
        'IONEX report plot source should contain finite model mapping factor.');
    
    assert(any(contains( ...
        string(reportData.ionosphere_map_summary_table.Quantity), ...
        "Mean truth VTEC")), ...
        'Ionosphere map summary table should contain mean truth VTEC.');

    disp("PASS: IONEX history and report diagnostics are recorded.");
end

function runIonexTruthModelMismatchRegression()
    ProjectPathManager.addProjectPaths();

    truthIonexFile = string([tempname, '_truth.ionex']);
    modelIonexFile = string([tempname, '_model.ionex']);

    cleanupTruth = onCleanup(@() deleteTemporaryFile(truthIonexFile));
    cleanupModel = onCleanup(@() deleteTemporaryFile(modelIonexFile));

    writeUniformIonexTestFile(truthIonexFile, 14.0);
    writeUniformIonexTestFile(modelIonexFile, 10.0);

    simConfigOverride = makeShortRegressionOverride();
    scenarioPath = 'reverseGnssClockNavigationScenario';

    truthCfg = struct( ...
        'enableTroposphere', false, ...
        'enableIonosphere', true, ...
        'troposphereModel', "disabled", ...
        'ionosphereModel', "ionex", ...
        'ionosphereProviderType', "ionex", ...
        'ionexFile', truthIonexFile, ...
        'residualTroposphereSigma_m', 0.0, ...
        'residualIonosphereSigma_m', 0.0);

    modelCfg = truthCfg;
    modelCfg.ionexFile = modelIonexFile;

    simConfigOverride.scenarios.(scenarioPath).atmosphere.truth = truthCfg;
    simConfigOverride.scenarios.(scenarioPath).atmosphere.model = modelCfg;

    simConfigOverride.scenarios.(scenarioPath).measurement.enableElevationMask = true;
    simConfigOverride.scenarios.(scenarioPath).measurement.elevationMask_deg = 5.0;

    runtimeOptions = struct();
    runtimeOptions.entryPointName = "IonexTruthModelMismatchRegression";
    runtimeOptions.simConfigOverride = simConfigOverride;

    sim = ReverseGnssSimulation(runtimeOptions);
    sim.configure();
    sim.run();

    visible = sim.history.visibility_mask_by_receiver_tower(:, :, 1);

    assert(any(visible(:)), ...
        'IONEX truth/model mismatch regression produced no visible measurements.');

    truthVtec = ...
        sim.history.atmosphere_truth_ionosphere_vtec_TECU_by_receiver_tower(:, :, 1);

    modelVtec = ...
        sim.history.atmosphere_model_ionosphere_vtec_TECU_by_receiver_tower(:, :, 1);

    truthStec = ...
        sim.history.atmosphere_truth_ionosphere_stec_TECU_by_receiver_tower(:, :, 1);

    modelStec = ...
        sim.history.atmosphere_model_ionosphere_stec_TECU_by_receiver_tower(:, :, 1);

    truthMapping = ...
        sim.history.atmosphere_truth_ionosphere_mapping_factor_by_receiver_tower(:, :, 1);

    modelMapping = ...
        sim.history.atmosphere_model_ionosphere_mapping_factor_by_receiver_tower(:, :, 1);

    truthIonosphere_m = ...
        sim.history.atmosphere_truth_ionosphere_by_receiver_tower_m(:, :, 1);

    modelIonosphere_m = ...
        sim.history.atmosphere_model_ionosphere_by_receiver_tower_m(:, :, 1);

    assert(all(abs(truthVtec(visible) - 14.0) < 1e-12), ...
        'Truth IONEX VTEC should equal 14 TECU.');

    assert(all(abs(modelVtec(visible) - 10.0) < 1e-12), ...
        'Estimator IONEX VTEC should equal 10 TECU.');

    assert(all(abs(truthStec(visible) - ...
        truthVtec(visible) .* truthMapping(visible)) < 1e-10), ...
        'Truth STEC must equal truth VTEC times truth mapping factor.');

    assert(all(abs(modelStec(visible) - ...
        modelVtec(visible) .* modelMapping(visible)) < 1e-10), ...
        'Estimator STEC must equal estimator VTEC times estimator mapping factor.');

    frequency_Hz = 1575.42e6;

    expectedTruthIonosphere_m = ...
        40.3 .* (truthStec .* 1.0e16) ./ frequency_Hz^2;

    expectedModelIonosphere_m = ...
        40.3 .* (modelStec .* 1.0e16) ./ frequency_Hz^2;

    assert(max(abs(truthIonosphere_m(visible) - ...
        expectedTruthIonosphere_m(visible))) < 1e-10, ...
        'Truth IONEX ionosphere delay does not match first-order code-delay formula.');

    assert(max(abs(modelIonosphere_m(visible) - ...
        expectedModelIonosphere_m(visible))) < 1e-10, ...
        'Estimator IONEX ionosphere delay does not match first-order code-delay formula.');

    reportData = ReportDataBuilder.fromSimulation(sim);

    ionosphereResidual_m = ...
        reportData.atmosphere_ionosphere_residual_by_receiver_tower_m(:, :, 1);

    expectedResidual_m = truthIonosphere_m - modelIonosphere_m;

    assert(max(abs(ionosphereResidual_m(visible) - ...
        expectedResidual_m(visible))) < 1e-10, ...
        'IONEX truth-minus-model residual should equal truth ionosphere minus model ionosphere.');

    assert(mean(ionosphereResidual_m(visible), 'omitnan') > 0.0, ...
        'Truth VTEC larger than model VTEC should produce positive mean ionosphere residual.');

    assert(mean(truthVtec(visible), 'omitnan') > ...
        mean(modelVtec(visible), 'omitnan'), ...
        'Truth VTEC mean should be larger than estimator VTEC mean.');

    assert(isfield(reportData, 'ionosphere_map_summary_table'), ...
        'IONEX mismatch report data should include the ionosphere map summary table.');

    disp("PASS: IONEX truth-model mismatch produces the expected residual.");
end

function runAtmosphereInvalidGradientGuardRegression()
    ProjectPathManager.addProjectPaths();

    datetimeUtc = datetime(2026, 5, 27, 23, 0, 0, ...
        'TimeZone', 'UTC');

    jd = Clock.julianDateFromDatetime(datetimeUtc);

    earthRadius_m = 6378137.0;

    constants = struct( ...
        'speedOfLight_mps', 299792458.0, ...
        'earthRadius_m', earthRadius_m);

    atmosphereCfg = struct();
    atmosphereCfg.dataRoot = fullfile("data", "atmosphere");
    atmosphereCfg.missingDataPolicy = "error";
    atmosphereCfg.ionosphereShellHeight_m = 350000.0;

    atmosphereCfg.model = struct( ...
        'enableTroposphere', true, ...
        'enableIonosphere', true, ...
        'troposphereModel', "saastamoinen", ...
        'ionosphereModel', "thinshellvtec", ...
        'surfacePressure_hPa', 1013.25, ...
        'surfaceTemperature_K', 293.15, ...
        'relativeHumidity_fraction', 0.50, ...
        'minimumMappingElevation_deg', 3.0, ...
        'vtec_TECU', 10.0, ...
        'residualTroposphereSigma_m', 0.0, ...
        'residualIonosphereSigma_m', 0.0);

    atmosphere = Atmosphere(atmosphereCfg, constants, "model");

    towerCfg = struct( ...
        'name', 'InvalidGradientTower', ...
        'lat_deg', 0.0, ...
        'lon_deg', 0.0, ...
        'alt_m', 0.0, ...
        'txSignalDelay_m', 0.0);

    tower = GroundNode(towerCfg);

    % Receiver below the local horizon for an equatorial x-axis tower.
    receiverEcef_m = [0.0; earthRadius_m + 4.0e7; 0.0];
    receiverEci_m = FrameGeometry.ecefToEciDcm(jd) * receiverEcef_m;

    [delay, gradientReceiverEci] = atmosphere.codeDelayAndGradientMeters( ...
        tower, receiverEci_m, jd, datetimeUtc, 1575.42e6);

    assert(~delay.valid, ...
        'Below-horizon atmosphere delay should be invalid.');

    assert(all(isnan(gradientReceiverEci)), ...
        'Invalid atmosphere delay must return a NaN gradient.');

    disabledCfg = atmosphereCfg;
    disabledCfg.model.enableTroposphere = false;
    disabledCfg.model.enableIonosphere = false;
    disabledCfg.model.troposphereModel = "disabled";
    disabledCfg.model.ionosphereModel = "disabled";

    disabledAtmosphere = Atmosphere(disabledCfg, constants, "model");

    [disabledDelay, disabledGradient] = ...
        disabledAtmosphere.codeDelayAndGradientMeters( ...
        tower, receiverEci_m, jd, datetimeUtc, 1575.42e6);

    assert(~disabledDelay.valid, ...
        'Below-horizon disabled atmosphere delay should still be invalid.');

    assert(all(isnan(disabledGradient)), ...
        'Below-horizon disabled atmosphere should also return NaN gradient.');

    disp("PASS: invalid atmosphere delays return NaN gradients.");
end

function runIonospherePiercePointGeometryRegression()
    ProjectPathManager.addProjectPaths();

    earthRadius_m = 6378137.0;
    shellHeight_m = 350000.0;
    shellRadius_m = earthRadius_m + shellHeight_m;

    groundEcef_m = [earthRadius_m; 0.0; 0.0];
    receiverEcef_m = [earthRadius_m + 4.0e7; 0.0; 0.0];

    zenithPiercePoint = IonospherePiercePointGeometry.fromEcefLineOfSight( ...
        groundEcef_m, ...
        receiverEcef_m, ...
        earthRadius_m, ...
        shellHeight_m, ...
        90.0);

    assert(zenithPiercePoint.valid, ...
        'Zenith pierce point should be valid.');

    assert(abs(zenithPiercePoint.latitude_deg) < 1e-12, ...
        'Zenith pierce-point latitude should be zero at the equator.');

    assert(abs(zenithPiercePoint.longitude_deg) < 1e-12, ...
        'Zenith pierce-point longitude should be zero at the x-axis.');

    assert(abs(zenithPiercePoint.radius_m - shellRadius_m) < 1e-6, ...
        'Pierce point radius should equal the shell radius.');

    assert(abs(zenithPiercePoint.height_m - shellHeight_m) < 1e-6, ...
        'Pierce point shell height should equal configured shell height.');

    assert(abs(zenithPiercePoint.slantRangeToPiercePoint_m - shellHeight_m) < 1e-6, ...
        'Zenith slant range to shell should equal shell height.');

    assert(abs(zenithPiercePoint.mappingFactor - 1.0) < 1e-12, ...
        'Zenith thin-shell mapping factor should be one.');

    towerCfg = struct( ...
        'name', 'PiercePointTower', ...
        'lat_deg', 28.3, ...
        'lon_deg', -16.5, ...
        'alt_m', 0.0, ...
        'txSignalDelay_m', 0.0);

    tower = GroundNode(towerCfg);

    elevation_deg = 30.0;
    azimuth_deg = 120.0;
    slantRange_m = 4.0e7;

    uEnu = [ ...
        cosd(elevation_deg) * sind(azimuth_deg); ...
        cosd(elevation_deg) * cosd(azimuth_deg); ...
        sind(elevation_deg)];

    R_enu_ecef = FrameGeometry.ecefToEnuDcm( ...
        tower.lat_deg, tower.lon_deg);

    uEcef = R_enu_ecef.' * uEnu;

    receiverEcef_m = tower.pos_ECEF_m + slantRange_m * uEcef;

    obliquePiercePoint = ...
        IonospherePiercePointGeometry.fromEcefLineOfSight( ...
        tower.pos_ECEF_m, ...
        receiverEcef_m, ...
        earthRadius_m, ...
        shellHeight_m, ...
        elevation_deg);

    assert(obliquePiercePoint.valid, ...
        'Oblique pierce point should be valid.');

    assert(obliquePiercePoint.slantRangeToPiercePoint_m > 0.0, ...
        'Pierce-point slant range must be positive.');

    assert(obliquePiercePoint.slantRangeToPiercePoint_m < slantRange_m, ...
        'Pierce point must lie between the tower and receiver.');

    assert(abs(obliquePiercePoint.radius_m - shellRadius_m) < 1e-5, ...
        'Oblique pierce point must lie on the configured shell.');

    expectedMappingFactor = ...
        IonospherePiercePointGeometry.mappingFactorFromElevation( ...
        elevation_deg, earthRadius_m, shellHeight_m);

    assert(abs(obliquePiercePoint.mappingFactor - expectedMappingFactor) < 1e-12, ...
        'Pierce-point mapping factor must match the thin-shell formula.');

    assert(isfinite(obliquePiercePoint.latitude_deg));
    assert(isfinite(obliquePiercePoint.longitude_deg));
    assert(obliquePiercePoint.latitude_deg >= -90.0);
    assert(obliquePiercePoint.latitude_deg <= 90.0);
    assert(obliquePiercePoint.longitude_deg >= -180.0);
    assert(obliquePiercePoint.longitude_deg <= 180.0);

    datetimeUtc = datetime(2026, 5, 27, 23, 0, 0, 'TimeZone', 'UTC');
    jd = Clock.julianDateFromDatetime(datetimeUtc);

    constants = struct( ...
        'speedOfLight_mps', 299792458.0, ...
        'earthRadius_m', earthRadius_m);

    atmosphereCfg = struct();
    atmosphereCfg.dataRoot = fullfile("data", "atmosphere");
    atmosphereCfg.missingDataPolicy = "error";
    atmosphereCfg.ionosphereShellHeight_m = shellHeight_m;

    atmosphereCfg.model = struct( ...
        'enableTroposphere', false, ...
        'enableIonosphere', true, ...
        'troposphereModel', "disabled", ...
        'ionosphereModel', "thinshellvtec", ...
        'vtec_TECU', 10.0, ...
        'ionosphereProviderType', "none");

    atmosphere = Atmosphere(atmosphereCfg, constants, "model");

    receiverEci_m = FrameGeometry.ecefToEciDcm(jd) * receiverEcef_m;

    delay = atmosphere.codeDelayMeters( ...
        tower, receiverEci_m, jd, datetimeUtc, 1575.42e6);

    assert(delay.valid, ...
        'Thin-shell atmosphere delay should be valid for visible geometry.');

    assert(isfield(delay.metadata, 'ionospherePiercePoint'), ...
        'Atmosphere delay metadata must include ionosphere pierce point.');

    assert(delay.metadata.ionospherePiercePoint.valid, ...
        'Atmosphere metadata pierce point should be valid.');

    assert(abs(delay.metadata.ionospherePiercePoint.mappingFactor - ...
        atmosphere.ionosphereMappingFactorForTest(elevation_deg)) < 1e-12, ...
        'Atmosphere metadata mapping factor should match the model mapping factor.');

    disp("PASS: thin-shell ionosphere pierce-point geometry is valid.");
end

function runAtmosphereConstantDiagnosticRegression()
    simConfigOverride = makeShortRegressionOverride();

    truthCfg = struct( ...
        'enableTroposphere', true, ...
        'enableIonosphere', true, ...
        'troposphereModel', "constant", ...
        'ionosphereModel', "constant", ...
        'constantTroposphereDelay_m', 2.0, ...
        'constantIonosphereDelay_m', 3.0, ...
        'residualTroposphereSigma_m', 0.0, ...
        'residualIonosphereSigma_m', 0.0);

    modelCfg = truthCfg;

    simConfigOverride.scenarios.reverseGnssClockNavigationScenario.atmosphere.truth = truthCfg;
    simConfigOverride.scenarios.reverseGnssClockNavigationScenario.atmosphere.model = modelCfg;

    runtimeOptions = struct();
    runtimeOptions.entryPointName = "AtmosphereConstantDiagnosticRegression";
    runtimeOptions.simConfigOverride = simConfigOverride;

    sim = ReverseGnssSimulation(runtimeOptions);
    sim.configure();
    sim.run();

    visible = sim.history.visibility_mask_by_receiver_tower(:, :, 1);

    truthDelay = sim.history.atmosphere_truth_delay_by_receiver_tower_m(:, :, 1);
    truthTotal = sim.history.atmosphere_truth_total_by_receiver_tower_m(:, :, 1);
    modelDelay = sim.history.atmosphere_model_delay_by_receiver_tower_m(:, :, 1);

    assert(any(visible(:)), ...
        'Constant atmosphere regression produced no visible measurements.');

    assert(all(abs(truthDelay(visible) - 5.0) < 1e-12), ...
        'Truth atmosphere diagnostic should equal 5 m.');

    assert(all(abs(truthTotal(visible) - 5.0) < 1e-12), ...
        'Truth atmosphere total should equal 5 m with zero residual.');

    assert(all(abs(modelDelay(visible) - 5.0) < 1e-12), ...
        'Estimator atmosphere diagnostic should equal 5 m.');

    assert(all(isfinite(sim.history.innovation_rms_m)));
    assert(all(isfinite(sim.history.postfit_innovation_rms_m)));

    disp("PASS: constant truth/model atmosphere diagnostics equal 5 m.");
end

function runAtmosphereComponentResidualDecompositionRegression()
    simConfigOverride = makeShortRegressionOverride();

    truthCfg = struct( ...
        'enableTroposphere', true, ...
        'enableIonosphere', true, ...
        'troposphereModel', "constant", ...
        'ionosphereModel', "constant", ...
        'constantTroposphereDelay_m', 0.0, ...
        'constantIonosphereDelay_m', 0.0, ...
        'residualTroposphereSigma_m', 0.8, ...
        'residualIonosphereSigma_m', 0.6);

    modelCfg = truthCfg;

    simConfigOverride.scenarios.reverseGnssClockNavigationScenario.atmosphere.truth = truthCfg;
    simConfigOverride.scenarios.reverseGnssClockNavigationScenario.atmosphere.model = modelCfg;

    runtimeOptions = struct();
    runtimeOptions.entryPointName = "AtmosphereComponentResidualDecompositionRegression";
    runtimeOptions.simConfigOverride = simConfigOverride;

    sim = ReverseGnssSimulation(runtimeOptions);
    sim.configure();
    sim.run();

    visible = sim.history.visibility_mask_by_receiver_tower(:, :, 1);

    assert(any(visible(:)), ...
        'Component residual regression produced no visible measurements.');

    assert(isfield(sim.history, 'atmosphere_truth_troposphere_residual_by_tower_m'));
    assert(isfield(sim.history, 'atmosphere_truth_ionosphere_residual_by_tower_m'));
    assert(isfield(sim.history, 'atmosphere_truth_troposphere_total_by_receiver_tower_m'));
    assert(isfield(sim.history, 'atmosphere_truth_ionosphere_total_by_receiver_tower_m'));

    totalResidualByTower_m = ...
        sim.history.atmosphere_truth_residual_by_tower_m(:, 1);

    troposphereResidualByTower_m = ...
        sim.history.atmosphere_truth_troposphere_residual_by_tower_m(:, 1);

    ionosphereResidualByTower_m = ...
        sim.history.atmosphere_truth_ionosphere_residual_by_tower_m(:, 1);

    assert(max(abs(totalResidualByTower_m - ...
        troposphereResidualByTower_m - ...
        ionosphereResidualByTower_m)) < 1e-12, ...
        'Total atmosphere residual must equal troposphere plus ionosphere residuals.');

    truthTroposphereDeterministic_m = ...
        sim.history.atmosphere_truth_troposphere_by_receiver_tower_m(:, :, 1);

    truthIonosphereDeterministic_m = ...
        sim.history.atmosphere_truth_ionosphere_by_receiver_tower_m(:, :, 1);

    truthTotalDeterministic_m = ...
        sim.history.atmosphere_truth_delay_by_receiver_tower_m(:, :, 1);

    truthTroposphereTotal_m = ...
        sim.history.atmosphere_truth_troposphere_total_by_receiver_tower_m(:, :, 1);

    truthIonosphereTotal_m = ...
        sim.history.atmosphere_truth_ionosphere_total_by_receiver_tower_m(:, :, 1);

    truthTotal_m = ...
        sim.history.atmosphere_truth_total_by_receiver_tower_m(:, :, 1);

    expectedTroposphereTotal_m = ...
        truthTroposphereDeterministic_m + ...
        repmat(troposphereResidualByTower_m(:).', sim.numReceivers, 1);

    expectedIonosphereTotal_m = ...
        truthIonosphereDeterministic_m + ...
        repmat(ionosphereResidualByTower_m(:).', sim.numReceivers, 1);

    assert(max(abs(truthTroposphereTotal_m(visible) - ...
        expectedTroposphereTotal_m(visible))) < 1e-12, ...
        'Truth troposphere total must equal deterministic troposphere plus troposphere residual.');

    assert(max(abs(truthIonosphereTotal_m(visible) - ...
        expectedIonosphereTotal_m(visible))) < 1e-12, ...
        'Truth ionosphere total must equal deterministic ionosphere plus ionosphere residual.');

    assert(max(abs(truthTotal_m(visible) - ...
        truthTroposphereTotal_m(visible) - ...
        truthIonosphereTotal_m(visible))) < 1e-12, ...
        'Truth total atmosphere must equal troposphere total plus ionosphere total.');

    assert(max(abs(truthTotalDeterministic_m(visible) - ...
        truthTroposphereDeterministic_m(visible) - ...
        truthIonosphereDeterministic_m(visible))) < 1e-12, ...
        'Deterministic truth atmosphere must equal deterministic troposphere plus ionosphere.');

    results = ResultBuilder.fromSimulation(sim);
    reportData = ReportDataBuilder.fromSimulation(sim);

    assert(isfield(results, 'atmosphere_truth_troposphere_residual_by_tower_m'));
    assert(isfield(results, 'atmosphere_truth_ionosphere_residual_by_tower_m'));
    assert(isfield(results, 'atmosphere_truth_troposphere_total_by_receiver_tower_m'));
    assert(isfield(results, 'atmosphere_truth_ionosphere_total_by_receiver_tower_m'));

    assert(isfield(reportData, 'atmosphere_truth_troposphere_residual_by_tower_m'));
    assert(isfield(reportData, 'atmosphere_truth_ionosphere_residual_by_tower_m'));
    assert(isfield(reportData, 'atmosphere_truth_troposphere_total_by_receiver_tower_m'));
    assert(isfield(reportData, 'atmosphere_truth_ionosphere_total_by_receiver_tower_m'));

    componentResidualSum_m = ...
        reportData.atmosphere_troposphere_residual_by_receiver_tower_m + ...
        reportData.atmosphere_ionosphere_residual_by_receiver_tower_m;

    totalAtmosphereResidual_m = ...
        reportData.atmosphere_residual_by_receiver_tower_m;

    assert(max(abs(componentResidualSum_m(visible) - ...
        totalAtmosphereResidual_m(visible))) < 1e-12, ...
        'Report atmosphere residual components must sum to total atmosphere residual.');

    measurementTowerIndex = [1; 2; 1; 2];

    R = sim.measurementModel.measurementCovariance( ...
        measurementTowerIndex, ...
        true, ...
        0.0);

    expectedAtmosphereVariance_m2 = 0.8^2 + 0.6^2;

    assert(abs(R(1, 3) - expectedAtmosphereVariance_m2) < 1e-12);
    assert(abs(R(2, 4) - expectedAtmosphereVariance_m2) < 1e-12);
    assert(abs(R(1, 2)) < 1e-12);
    assert(abs(R(1, 4)) < 1e-12);

    disp("PASS: atmosphere residual decomposition is internally consistent.");
end

function runAtmosphereResidualCovarianceNisRegression()
    baseOverride = makeShortRegressionOverride();

    truthCfg = struct( ...
        'enableTroposphere', true, ...
        'enableIonosphere', true, ...
        'troposphereModel', "constant", ...
        'ionosphereModel', "constant", ...
        'constantTroposphereDelay_m', 0.0, ...
        'constantIonosphereDelay_m', 0.0, ...
        'residualTroposphereSigma_m', 0.8, ...
        'residualIonosphereSigma_m', 0.6);

    matchedModelCfg = truthCfg;

    underModeledModelCfg = truthCfg;
    underModeledModelCfg.residualTroposphereSigma_m = 0.0;
    underModeledModelCfg.residualIonosphereSigma_m = 0.0;

    scenarioPath = 'reverseGnssClockNavigationScenario';

    matchedOverride = baseOverride;
    matchedOverride.scenarios.(scenarioPath).atmosphere.truth = truthCfg;
    matchedOverride.scenarios.(scenarioPath).atmosphere.model = matchedModelCfg;

    underModeledOverride = baseOverride;
    underModeledOverride.scenarios.(scenarioPath).atmosphere.truth = truthCfg;
    underModeledOverride.scenarios.(scenarioPath).atmosphere.model = underModeledModelCfg;

    matchedOptions = struct();
    matchedOptions.entryPointName = "AtmosphereMatchedCovarianceNisRegression";
    matchedOptions.simConfigOverride = matchedOverride;

    simMatched = ReverseGnssSimulation(matchedOptions);
    simMatched.configure();
    simMatched.run();

    underModeledOptions = struct();
    underModeledOptions.entryPointName = "AtmosphereUnderModeledCovarianceNisRegression";
    underModeledOptions.simConfigOverride = underModeledOverride;

    simUnderModeled = ReverseGnssSimulation(underModeledOptions);
    simUnderModeled.configure();
    simUnderModeled.run();

    nisMatched = simMatched.history.nis_history(1);
    nisUnderModeled = simUnderModeled.history.nis_history(1);

    assert(isfinite(nisMatched), ...
        'Matched atmosphere covariance NIS must be finite.');

    assert(isfinite(nisUnderModeled), ...
        'Under-modeled atmosphere covariance NIS must be finite.');

    assert(nisMatched <= nisUnderModeled + 1e-10, ...
        ['Adding the matched atmospheric residual covariance to R should ', ...
         'not increase the first-epoch NIS for the same innovation.']);

    matchedAtmosphereVariance_m2 = ...
        simMatched.measurementModel.atmosphereResidualVariance_m2();

    underModeledAtmosphereVariance_m2 = ...
        simUnderModeled.measurementModel.atmosphereResidualVariance_m2();

    assert(abs(matchedAtmosphereVariance_m2 - 1.0) < 1e-12, ...
        'Matched atmosphere residual variance should be 0.8^2 + 0.6^2 = 1 m^2.');

    assert(underModeledAtmosphereVariance_m2 == 0.0, ...
        'Under-modeled estimator atmosphere residual variance should be zero.');

    measurementTowerIndex = [1; 2; 1; 2];

    Rmatched = simMatched.measurementModel.measurementCovariance( ...
        measurementTowerIndex, ...
        true, ...
        0.0);

    RunderModeled = simUnderModeled.measurementModel.measurementCovariance( ...
        measurementTowerIndex, ...
        true, ...
        0.0);

    Rdiff = 0.5 * ((Rmatched - RunderModeled) + ...
                   (Rmatched - RunderModeled).');

    assert(min(eig(Rdiff)) > -1e-12, ...
        'Matched atmosphere covariance should add a positive semidefinite term to R.');

    assert(abs(Rdiff(1, 3) - 1.0) < 1e-12, ...
        'Same-tower atmosphere covariance should equal 1 m^2.');

    assert(abs(Rdiff(2, 4) - 1.0) < 1e-12, ...
        'Same-tower atmosphere covariance should equal 1 m^2.');

    assert(abs(Rdiff(1, 2)) < 1e-12, ...
        'Different towers should not share atmosphere residual covariance.');

    reportData = ReportDataBuilder.fromSimulation(simMatched);

    assert(isfield(reportData, 'R_atmosphere_m2'));
    assert(all(abs(reportData.R_atmosphere_m2(:) - 1.0) < 1e-12), ...
        'Report atmosphere covariance contribution should equal 1 m^2.');

    disp("PASS: matched atmospheric residual covariance reduces or preserves NIS.");
end

function runAtmosphereResidualAndCovarianceRegression()
    simConfigOverride = makeShortRegressionOverride();

    truthCfg = struct( ...
        'enableTroposphere', true, ...
        'enableIonosphere', false, ...
        'troposphereModel', "constant", ...
        'ionosphereModel', "disabled", ...
        'constantTroposphereDelay_m', 0.0, ...
        'constantIonosphereDelay_m', 0.0, ...
        'residualTroposphereSigma_m', 1.0, ...
        'residualIonosphereSigma_m', 0.0);

    modelCfg = struct( ...
        'enableTroposphere', true, ...
        'enableIonosphere', true, ...
        'troposphereModel', "constant", ...
        'ionosphereModel', "constant", ...
        'constantTroposphereDelay_m', 0.0, ...
        'constantIonosphereDelay_m', 0.0, ...
        'residualTroposphereSigma_m', 0.20, ...
        'residualIonosphereSigma_m', 0.30);

    simConfigOverride.scenarios.reverseGnssClockNavigationScenario.atmosphere.truth = truthCfg;
    simConfigOverride.scenarios.reverseGnssClockNavigationScenario.atmosphere.model = modelCfg;

    runtimeOptions = struct();
    runtimeOptions.entryPointName = "AtmosphereResidualAndCovarianceRegression";
    runtimeOptions.simConfigOverride = simConfigOverride;

    sim = ReverseGnssSimulation(runtimeOptions);
    sim.configure();
    sim.run();

    visible = sim.history.visibility_mask_by_receiver_tower(:, :, 1);
    truthDelay = sim.history.atmosphere_truth_delay_by_receiver_tower_m(:, :, 1);
    truthTotal = sim.history.atmosphere_truth_total_by_receiver_tower_m(:, :, 1);
    residualByTower = sim.history.atmosphere_truth_residual_by_tower_m(:, 1);

    commonTowerFound = false;

    for twr = 1:sim.numTowers
        receiverMask = visible(:, twr);

        if nnz(receiverMask) >= 2
            receiverResiduals = truthTotal(receiverMask, twr) - truthDelay(receiverMask, twr);

            assert(max(receiverResiduals) - min(receiverResiduals) < 1e-10, ...
                'Truth atmospheric residual must be common across receivers for one tower.');

            assert(abs(receiverResiduals(1) - residualByTower(twr)) < 1e-10, ...
                'Recorded tower atmospheric residual does not match receiver/tower total.');

            commonTowerFound = true;
        end
    end

    assert(commonTowerFound, ...
        'No tower had at least two visible receiver measurements.');

    assert(abs(sim.truthAtmosphere.residualCodeSigma_m() - 1.0) < 1e-12);
    assert(abs(sim.modelAtmosphere.residualCodeVariance_m2() - 0.13) < 1e-12);

    measurementTowerIndex = [1; 2; 1; 2];

    R = sim.measurementModel.measurementCovariance( ...
        measurementTowerIndex, ...
        true, ...
        0.0);

    atmosphereVariance_m2 = 0.20^2 + 0.30^2;

    assert(abs(R(1, 3) - atmosphereVariance_m2) < 1e-12);
    assert(abs(R(2, 4) - atmosphereVariance_m2) < 1e-12);
    assert(abs(R(1, 2)) < 1e-12);
    assert(abs(R(1, 4)) < 1e-12);
    assert(norm(R - R.', inf) < 1e-12);
    assert(min(eig(0.5 * (R + R.'))) > 0.0);

    disp("PASS: atmospheric residuals are tower-common and covariance is consistent.");
end

function runAtmosphereGradientFiniteDifferenceRegression()
    datetimeUtc = datetime(2026, 5, 27, 23, 0, 0, 'TimeZone', 'UTC');
    jd = Clock.julianDateFromDatetime(datetimeUtc);

    constants = struct( ...
        'speedOfLight_mps', 299792458.0, ...
        'earthRadius_m', 6378137.0);

    atmosphereCfg = struct();
    atmosphereCfg.dataRoot = fullfile("data", "atmosphere");
    atmosphereCfg.missingDataPolicy = "error";
    atmosphereCfg.ionosphereShellHeight_m = 350000.0;

    atmosphereCfg.model = struct( ...
        'enableTroposphere', true, ...
        'enableIonosphere', true, ...
        'troposphereModel', "saastamoinen", ...
        'ionosphereModel', "thinshellvtec", ...
        'constantTroposphereDelay_m', 0.0, ...
        'constantIonosphereDelay_m', 0.0, ...
        'surfacePressure_hPa', 1013.25, ...
        'surfaceTemperature_K', 293.15, ...
        'relativeHumidity_fraction', 0.50, ...
        'minimumMappingElevation_deg', 3.0, ...
        'vtec_TECU', 10.0, ...
        'residualTroposphereSigma_m', 0.0, ...
        'residualIonosphereSigma_m', 0.0);

    atmosphere = Atmosphere(atmosphereCfg, constants, "model");

    towerCfg = struct( ...
        'name', 'GradientTower', ...
        'lat_deg', 28.3, ...
        'lon_deg', -16.5, ...
        'alt_m', 0.0, ...
        'txSignalDelay_m', 0.0);

    tower = GroundNode(towerCfg);

    elevation_deg = 30.0;
    azimuth_deg = 120.0;
    slantRange_m = 4.0e7;

    uEnu = [ ...
        cosd(elevation_deg) * sind(azimuth_deg); ...
        cosd(elevation_deg) * cosd(azimuth_deg); ...
        sind(elevation_deg)];

    R_enu_ecef = FrameGeometry.ecefToEnuDcm( ...
        tower.lat_deg, tower.lon_deg);

    uEcef = R_enu_ecef.' * uEnu;

    receiverEcef_m = tower.pos_ECEF_m + slantRange_m * uEcef;
    receiverEci_m = FrameGeometry.ecefToEciDcm(jd) * receiverEcef_m;

    [delay, analyticGradient] = atmosphere.codeDelayAndGradientMeters( ...
        tower, receiverEci_m, jd, datetimeUtc, 1575.42e6);

    assert(delay.valid);

    step_m = 100.0;
    finiteDifferenceGradient = zeros(3, 1);

    for axisIndex = 1:3
        delta = zeros(3, 1);
        delta(axisIndex) = step_m;

        delayPlus = atmosphere.codeDelayMeters( ...
            tower, receiverEci_m + delta, jd, datetimeUtc, 1575.42e6);

        delayMinus = atmosphere.codeDelayMeters( ...
            tower, receiverEci_m - delta, jd, datetimeUtc, 1575.42e6);

        assert(delayPlus.valid && delayMinus.valid);

        finiteDifferenceGradient(axisIndex) = ...
            (delayPlus.total_m - delayMinus.total_m) / (2.0 * step_m);
    end

    gradientError = norm(analyticGradient - finiteDifferenceGradient, inf);
    gradientScale = max(norm(finiteDifferenceGradient, inf), 1e-12);

    assert(gradientError < 1e-4 * gradientScale, ...
        'Atmosphere analytic gradient does not match finite differences.');

    disp("PASS: atmosphere analytic gradient matches finite differences.");
end

function deleteTemporaryFile(filePath)
    if exist(filePath, 'file') == 2
        delete(filePath);
    end
end

function writeIonexTextFile(filePath, ionexText)
    fid = fopen(char(string(filePath)), 'w');

    assert(fid > 0, ...
        'Could not create temporary IONEX test file: %s', ...
        char(string(filePath)));

    fileCleanup = onCleanup(@() fclose(fid));

    for k = 1:numel(ionexText)
        fprintf(fid, '%s\n', ionexText(k));
    end
end

function writeUniformIonexTestFile(filePath, vtec_TECU)
    vtecRow = sprintf(' %6.0f %5.0f', double(vtec_TECU), double(vtec_TECU));

    ionexText = [
        "     0                                                      EXPONENT"
        "                                                            END OF HEADER"
        "     1                                                      START OF TEC MAP"
        "  2026     5    27    23     0     0                       EPOCH OF CURRENT MAP"
        "   -90.0  -180.0   180.0   360.0   350.0                   LAT/LON1/LON2/DLON/H"
        string(vtecRow)
        "    90.0  -180.0   180.0   360.0   350.0                   LAT/LON1/LON2/DLON/H"
        string(vtecRow)
        "                                                            END OF TEC MAP"
        "     2                                                      START OF TEC MAP"
        "  2026     5    28     0     0     0                       EPOCH OF CURRENT MAP"
        "   -90.0  -180.0   180.0   360.0   350.0                   LAT/LON1/LON2/DLON/H"
        string(vtecRow)
        "    90.0  -180.0   180.0   360.0   350.0                   LAT/LON1/LON2/DLON/H"
        string(vtecRow)
        "                                                            END OF TEC MAP"
        ];

    fid = fopen(char(string(filePath)), 'w');

    assert(fid > 0, ...
        'Could not create temporary uniform IONEX test file: %s', ...
        char(string(filePath)));

    fileCleanup = onCleanup(@() fclose(fid));

    for k = 1:numel(ionexText)
        fprintf(fid, '%s\n', ionexText(k));
    end
end

function simConfigOverride = makeShortRegressionOverride()
    simConfigOverride = struct();
    simConfigOverride.randomSeed = 42;
    simConfigOverride.enableInteractivePlots = false;
    simConfigOverride.enableReportGeneration = false;

    simConfigOverride.simulation.dt_s = 1.0;
    simConfigOverride.simulation.totalTime_h = 0.001;

    scenario = struct();
    scenario.name = "AtmosphereRegression";
    scenario.numReceivers = 4;
    scenario.receiverBaseline_m = 2.0;
    scenario.receivers = makeReceiverConfigsForTest(4, scenario.receiverBaseline_m, 0.30);

    scenario.report.generatePdf = false;
    scenario.report.compilePdf = false;
    scenario.report.interactivePlots = false;
    scenario.report.enableAllanDeviationValidation = false;

    scenario.measurement.enableMeasurementNoise = false;
    scenario.measurement.enableNoise = false;
    scenario.measurement.enableElevationMask = true;
    scenario.measurement.elevationMask_deg = 5.0;
    scenario.measurement.enableLightTimeCorrection = false;
    scenario.measurement.enableSagnacCorrection = false;

    scenario.enableGroundClockErrors = false;
    scenario.enableGroundClockCorrection = true;
    scenario.enableGroundClockCorrectionNoise = false;
    scenario.enableTowerClockEKF = false;
    scenario.towerClockGaugeMode = "externalTowerCorrections";

    simConfigOverride.scenarios.reverseGnssClockNavigationScenario = scenario;
end