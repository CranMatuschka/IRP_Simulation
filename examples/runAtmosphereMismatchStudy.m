function [sim, results, resultFile] = runAtmosphereMismatchStudy()
%RUNATMOSPHEREMISMATCHSTUDY Constant truth/model atmosphere mismatch example.
%
% This example requires no external IONEX, ERA5, or profile data. It uses
% constant first-stage atmosphere delays to demonstrate the measurement
% truth/model/residual split:
%
%   truth atmosphere deterministic total = 2.6 m + 2.0 m = 4.6 m
%   model atmosphere deterministic total = 2.3 m + 1.4 m = 3.7 m
%   deterministic truth minus model     = 0.9 m
%
% Truth residual sigmas below generate seeded stochastic residual samples in
% y only. Model residual sigmas below contribute covariance to R only.

thisDir = fileparts(mfilename('fullpath'));
projectRoot = fileparts(thisDir);
addpath(projectRoot);
ProjectPathManager.addProjectPaths();

truthAtmosphereCfg = struct( ...
    'enableTroposphere', true, ...
    'troposphereModel', "constant", ...
    'constantTroposphereDelay_m', 2.6, ...
    'enableIonosphere', true, ...
    'ionosphereModel', "constant", ...
    'constantIonosphereDelay_m', 2.0, ...
    'residualTroposphereSigma_m', 0.1, ...
    'residualIonosphereSigma_m', 0.3);

modelAtmosphereCfg = struct( ...
    'enableTroposphere', true, ...
    'troposphereModel', "constant", ...
    'constantTroposphereDelay_m', 2.3, ...
    'enableIonosphere', true, ...
    'ionosphereModel', "constant", ...
    'constantIonosphereDelay_m', 1.4, ...
    'residualTroposphereSigma_m', 0.2, ...
    'residualIonosphereSigma_m', 0.5);

simConfigOverride = struct();
simConfigOverride.randomSeed = 42;
simConfigOverride.seeds.atmosphereResidual = 40042;
simConfigOverride.enableInteractivePlots = false;
simConfigOverride.enableReportGeneration = false;
simConfigOverride.simulation.dt_s = 1.0;
simConfigOverride.simulation.totalTime_h = 0.001;

scenario = struct();
scenario.name = "AtmosphereMismatchStudy";
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

scenario.atmosphere.truth = truthAtmosphereCfg;
scenario.atmosphere.model = modelAtmosphereCfg;

scenario.enableGroundClockErrors = false;
scenario.enableGroundClockCorrection = true;
scenario.enableGroundClockCorrectionNoise = false;
scenario.enableTowerClockEKF = false;
scenario.towerClockGaugeMode = "externalTowerCorrections";

simConfigOverride.scenarios.reverseGnssClockNavigationScenario = scenario;

runtimeOptions = struct();
runtimeOptions.entryPointName = mfilename;
runtimeOptions.simConfigOverride = simConfigOverride;

sim = ReverseGnssSimulation(runtimeOptions);
sim.configure();
sim.outputDir = string(fullfile(projectRoot, "reports", "examples", ...
    "AtmosphereMismatchStudy"));
sim.run();
sim.saveResults();

results = sim.results;
resultFile = fullfile(char(sim.outputDir), ...
    sprintf('%s_results.mat', char(sim.scenarioName)));

expectedTruth_m = 4.6;
expectedModel_m = 3.7;
expectedDeterministicResidual_m = 0.9;
expectedModelVariance_m2 = 0.2^2 + 0.5^2;

visible = logical(sim.history.visibility_mask_by_receiver_tower);
truthDeterministic_m = sim.history.errors.atmosphere.deterministicTruth_m;
truthTotal_m = sim.history.errors.atmosphere.truth_m;
truthStochastic_m = sim.history.errors.atmosphere.stochasticResidual_m;
modelTotal_m = sim.history.errors.atmosphere.model_m;
deterministicResidual_m = ...
    sim.history.errors.atmosphere.deterministicResidual_m;

valid = visible & isfinite(truthDeterministic_m) & isfinite(modelTotal_m);
assert(any(valid(:)), ...
    'Atmosphere mismatch example produced no visible links.');

assertClose(max(abs(truthDeterministic_m(valid) - expectedTruth_m)), ...
    0.0, 1e-9, 'truth deterministic atmosphere total');
assertClose(max(abs(modelTotal_m(valid) - expectedModel_m)), ...
    0.0, 1e-9, 'model atmosphere total');
assertClose(max(abs( ...
    deterministicResidual_m(valid) - expectedDeterministicResidual_m)), ...
    0.0, 1e-9, 'deterministic atmosphere residual');
assertClose(max(abs( ...
    truthTotal_m(valid) - truthDeterministic_m(valid) - ...
    truthStochastic_m(valid))), ...
    0.0, 1e-9, 'truth total atmosphere composition');
assertClose(mean(deterministicResidual_m(valid), 'omitnan'), ...
    expectedDeterministicResidual_m, 1e-9, ...
    'deterministic atmosphere residual summary');
assertClose(mean(sim.history.errors.atmosphere.variance_m2(:), 'omitnan'), ...
    expectedModelVariance_m2, 1e-12, ...
    'model atmosphere covariance variance');

assert(isfield(results, 'history') && ...
    isfield(results.history.errors, 'atmosphere'), ...
    'Saved results structure must expose the canonical history snapshot.');
assert(exist(resultFile, 'file') == 2, ...
    'Expected saved results file was not created: %s', resultFile);

fprintf('\nAtmosphere mismatch study complete.\n');
fprintf('Deterministic truth total: %.3f m\n', expectedTruth_m);
fprintf('Deterministic model total: %.3f m\n', expectedModel_m);
fprintf('Deterministic residual: %.3f m\n', ...
    expectedDeterministicResidual_m);
fprintf('Model covariance variance in R: %.3f m^2 (%s)\n', ...
    expectedModelVariance_m2, ...
    char(sim.history.errors.atmosphere.correlationModel));
fprintf('Saved results: %s\n\n', resultFile);
end

function assertClose(actual, expected, tol, label)
    assert(abs(double(actual) - double(expected)) <= double(tol), ...
        '%s expected %.12g, got %.12g', ...
        char(string(label)), double(expected), double(actual));
end
