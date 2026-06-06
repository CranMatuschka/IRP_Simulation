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
REPORT_VERSION = sprintf('1.10');
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


validateRetainedReportAtmosphereDiagnostics(sim);
runIonosphereProviderInterfaceRegression();
runIonospherePiercePointGeometryRegression();
runAtmosphereConstantDiagnosticRegression();
runAtmosphereResidualAndCovarianceRegression();
runAtmosphereComponentResidualDecompositionRegression();
runAtmosphereResidualCovarianceNisRegression();
runAtmosphereGradientFiniteDifferenceRegression();

fprintf('\nPASS: test finished and PDF was created:\n%s\n', pdfFile);


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
    assert(isfield(reportData, 'atmosphere_troposphere_residual_by_receiver_tower_m'));
    assert(isfield(reportData, 'atmosphere_ionosphere_residual_by_receiver_tower_m'));

    disp("PASS: retained PDF report includes ionosphere and troposphere diagnostics.");
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