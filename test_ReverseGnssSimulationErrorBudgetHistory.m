function test_ReverseGnssSimulationErrorBudgetHistory()
%TEST_REVERSEGNSSSIMULATIONERRORBUDGETHISTORY 1-second history alias check.

ProjectPathManager.addProjectPaths();

runtimeOptions = struct();
runtimeOptions.entryPointName = mfilename;
runtimeOptions.simConfigOverride = makeOneSecondOverride();

sim = ReverseGnssSimulation(runtimeOptions);
sim.configure();
sim.run();

history = sim.history;
assert(isfield(history, 'errorBudget'));
assert(isfield(history.errorBudget, 'atmosphere'));
assert(isfield(history.errorBudget, 'nonAtmospheric'));

assert(isequaln( ...
    history.errorBudget.atmosphere.truthTotal_m, ...
    history.atmosphere.truth.total_m));
assert(isequaln( ...
    history.errorBudget.atmosphere.modelTotal_m, ...
    history.atmosphere.model.total_m));
assert(isequaln( ...
    history.errorBudget.atmosphere.residualTotal_m, ...
    history.atmosphere.residual.total_m));

assert(isequaln( ...
    history.errorBudget.nonAtmospheric.components.total.truth_m, ...
    history.non_atmospheric.truth.total_m));
assert(isequaln( ...
    history.errorBudget.nonAtmospheric.components.total.model_m, ...
    history.non_atmospheric.model.total_m));
assert(isequaln( ...
    history.errorBudget.nonAtmospheric.components.total.residual_m, ...
    history.non_atmospheric.residual.total_m));
assert(any(isfinite( ...
    history.errorBudget.nonAtmospheric.components.hardware.truth_m(:))));

reportData = ReportDataBuilder.fromSimulation(sim);
assert(isequaln( ...
    reportData.atmosphere_residual_by_receiver_tower_m, ...
    history.errorBudget.atmosphere.residualTotal_m));
assert(isequaln( ...
    reportData.atmosphere_troposphere_residual_by_receiver_tower_m, ...
    history.errorBudget.atmosphere.components.troposphere.residual_m));
assert(isequaln( ...
    reportData.atmosphere_ionosphere_residual_by_receiver_tower_m, ...
    history.errorBudget.atmosphere.components.ionosphere.residual_m));
assert(abs(reportData.model_atmosphere_residual_variance_m2 - ...
    mean(history.errorBudget.atmosphere.sameTowerVariance_m2(:), ...
    'omitnan')) < eps);

fprintf('PASS: ReverseGnssSimulation error-budget history check passed.\n');
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
