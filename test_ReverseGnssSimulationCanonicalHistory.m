function test_ReverseGnssSimulationCanonicalHistory()
%TEST_REVERSEGNSSSIMULATIONCANONICALHISTORY One-second canonical history check.

ProjectPathManager.addProjectPaths();

runtimeOptions = struct();
runtimeOptions.entryPointName = mfilename;
runtimeOptions.simConfigOverride = makeOneSecondOverride();

sim = ReverseGnssSimulation(runtimeOptions);
sim.configure();
sim.run();

history = sim.history;
finalPositionError_m = norm( ...
    history.x(sim.idx.pos, end) - history.truth(sim.idx.pos, end));
innovationRmsMean_m = mean(history.innovation_rms_m, 'omitnan');
truthAtmosphereMean_m = mean(history.errors.atmosphere.truth_m(:), 'omitnan');
modelAtmosphereMean_m = mean(history.errors.atmosphere.model_m(:), 'omitnan');
covarianceMean_m2 = mean(history.errors.atmosphere.variance_m2(:), 'omitnan');

assert(abs(finalPositionError_m - 559.38528668540778) < 1e-3);
assert(abs(innovationRmsMean_m - 584.51380801007917) < 1e-3);
assert(abs(truthAtmosphereMean_m - 2.5) < 1e-12);
assert(abs(modelAtmosphereMean_m - 2.5) < 1e-12);
assert(abs(covarianceMean_m2 - 0.05) < 1e-12);

assert(isfield(history, 'errors'));
assert(isfield(history.errors, 'atmosphere'));
assert(isfield(history.errors, 'hardware'));
assert(~isfield(history, 'errorBudget'));
assert(~isfield(history, 'atmosphere'));
assert(~isfield(history, 'non_atmospheric'));
assert(~isfield(history, 'propagation'));
assert(any(isfinite(history.errors.hardware.truth_m(:))));

assert(isequaln(history.errors.atmosphere.residual_m, ...
    history.errors.troposphere.residual_m + history.errors.ionosphere.residual_m));
assert(abs(mean(history.errors.atmosphere.variance_m2(:), 'omitnan') - 0.05) < eps);

results = ResultBuilder.fromSimulation(sim);
assert(isfield(results, 'history'));
assert(isequaln(results.history, sim.history));
assert(~isfield(results, 'errors'));
assert(~isfield(results, 'diagnostics'));
assert(~isfield(results, 'x'));
assert(~isfield(results, 'truth'));
assert(~isfield(results, 'covariance_diag'));
assert(~isfield(results, 'atmosphere'));
assert(~isfield(results, 'non_atmospheric'));
assert(~isfield(results, 'propagation'));
assert(~isfield(results, 'legacy'));

status = sim.results.error_budget_status;
assert(any(status.guarded_not_implemented == ...
    "Shapiro relativistic path delay truth/model correction"));
assert(~any(status.implemented == ...
    "Shapiro relativistic path delay truth/model correction"));
assert(any(status.diagnostics_available == "history.errors"));

fprintf('PASS: ReverseGnssSimulation canonical history check passed.\n');
end

function simConfigOverride = makeOneSecondOverride()
simConfigOverride = struct();
simConfigOverride.randomSeed = 42;
simConfigOverride.enableInteractivePlots = false;
simConfigOverride.enableReportGeneration = false;
simConfigOverride.simulation.dt_s = 1.0;
simConfigOverride.simulation.totalTime_h = 1 / 3600;
simConfigOverride.validation.allanValidationSamples = 16;
simConfigOverride.validation.tauSimulation_s = [1, 2, 4];
simConfigOverride.validation.tauProfile_s = [1, 2, 4];

scenario = struct();
scenario.report.enable = false;
scenario.report.generatePdf = false;
scenario.report.compilePdf = false;
scenario.report.interactivePlots = false;
scenario.report.enableAllanDeviationValidation = false;

scenario.measurement.enableHardwareDelay = true;
scenario.measurement.txHardwareDelay_m = 0.5;
scenario.measurement.rxHardwareDelay_m = 0.25;
scenario.measurement.txHardwareDelayModel_m = 0.2;
scenario.measurement.rxHardwareDelayModel_m = 0.1;

atmosphere = struct( ...
    'enableTroposphere', true, ...
    'enableIonosphere', true, ...
    'troposphereModel', "constant", ...
    'ionosphereModel', "constant", ...
    'constantTroposphereDelay_m', 2.0, ...
    'constantIonosphereDelay_m', 0.5, ...
    'residualTroposphereSigma_m', 0.0, ...
    'residualIonosphereSigma_m', 0.0);

scenario.atmosphere.truth = atmosphere;
atmosphere.residualTroposphereSigma_m = 0.20;
atmosphere.residualIonosphereSigma_m = 0.10;
scenario.atmosphere.model = atmosphere;

simConfigOverride.scenarios.reverseGnssClockNavigationScenario = scenario;
end
