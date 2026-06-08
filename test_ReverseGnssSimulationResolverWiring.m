function test_ReverseGnssSimulationResolverWiring()
%TEST_REVERSEGNSSSIMULATIONRESOLVERWIRING Passive resolver wiring check.

ProjectPathManager.addProjectPaths();

simConfigOverride = struct();
simConfigOverride.randomSeed = 42;
simConfigOverride.enableInteractivePlots = false;
simConfigOverride.enableReportGeneration = false;
simConfigOverride.simulation.dt_s = 1.0;
simConfigOverride.simulation.totalTime_h = 1 / 3600;

scenario = struct();
scenario.report.enable = false;
scenario.report.generatePdf = false;
scenario.report.compilePdf = false;
scenario.report.interactivePlots = false;
scenario.report.enableAllanDeviationValidation = false;

scenario.errors.measurementNoise.enabled = true;
scenario.errors.measurementNoise.truth = "noise";
scenario.errors.troposphere.enabled = true;
scenario.errors.troposphere.truth = "standrard";
scenario.errors.troposphere.model = "STD";
scenario.errors.troposphere.stochastic = "off";

simConfigOverride.scenarios.reverseGnssClockNavigationScenario = scenario;

runtimeOptions = struct();
runtimeOptions.entryPointName = mfilename;
runtimeOptions.simConfigOverride = simConfigOverride;

sim = ReverseGnssSimulation(runtimeOptions);
sim.configure();

assert(~isempty(sim.resolvedConfig));
assert(isfield(sim.resolvedConfig, 'errors'));
assert(isfield(sim.resolvedErrors, 'measurementNoise'));
assert(isfield(sim.resolvedErrors, 'troposphere'));
assert(sim.resolvedErrors.measurementNoise.truthMode == "awgn");
assert(sim.resolvedErrors.measurementNoise.stochasticMode == "awgn");
assert(sim.resolvedErrors.troposphere.truthMode == "standard");
assert(sim.resolvedErrors.troposphere.modelMode == "standard");
assert(sim.resolvedErrors.troposphere.stochasticMode == "off");
assert(sim.numSteps == 2);

fprintf('PASS: ReverseGnssSimulation resolver wiring check passed.\n');
end
