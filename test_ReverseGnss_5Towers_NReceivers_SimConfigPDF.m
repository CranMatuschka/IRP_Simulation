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
REPORT_VERSION = sprintf('1.2');
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
