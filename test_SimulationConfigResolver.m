function test_SimulationConfigResolver()
%TEST_SIMULATIONCONFIGRESOLVER Unit checks for canonical error config.

ProjectPathManager.addProjectPaths();

testModeNormalization();
testAwgnValidation();
testBackwardCompatibleDefaults();
testClockStatus();

fprintf('PASS: SimulationConfigResolver checks passed.\n');
end

function testModeNormalization()
simConfig = loadDefaultConfig();
scenario = simConfig.scenarios.reverseGnssClockNavigationScenario;

scenario.errors.ionosphere.enabled = true;
scenario.errors.ionosphere.truth = "standrard";
scenario.errors.ionosphere.model = "STD";
scenario.errors.ionosphere.stochastic = "off";

scenario.errors.troposphere.enabled = true;
scenario.errors.troposphere.truth = "Advanced";
scenario.errors.troposphere.model = "adv";

scenario.errors.multipath.enabled = true;
scenario.errors.multipath.truth = "standard+awgn";
scenario.errors.multipath.model = "standard";
scenario.errors.multipath.stochastic = "noise";

scenario.errors.hardwareDelay.enabled = false;
scenario.errors.hardwareDelay.truth = "standard";

simConfig.scenarios.reverseGnssClockNavigationScenario = scenario;
resolved = SimulationConfigResolver.resolve(simConfig);

assert(resolved.errors.ionosphere.truthMode == "standard");
assert(resolved.errors.ionosphere.modelMode == "standard");
assert(resolved.errors.ionosphere.stochasticMode == "off");
assert(resolved.errors.ionosphere.enabled);

assert(resolved.errors.troposphere.truthMode == "advanced");
assert(resolved.errors.troposphere.modelMode == "advanced");
assert(resolved.errors.troposphere.advanced);

assert(resolved.errors.multipath.truthMode == "standard+awgn");
assert(resolved.errors.multipath.stochasticMode == "awgn");

assert(~resolved.errors.hardwareDelay.enabled);
assert(resolved.errors.hardwareDelay.truthMode == "off");
end

function testAwgnValidation()
simConfig = loadDefaultConfig();
scenario = simConfig.scenarios.reverseGnssClockNavigationScenario;

scenario.errors.measurementNoise.enabled = true;
scenario.errors.measurementNoise.truth = "awgn";
scenario.errors.multipath.enabled = true;
scenario.errors.multipath.truth = "standard+awgn";
simConfig.scenarios.reverseGnssClockNavigationScenario = scenario;

resolved = SimulationConfigResolver.resolve(simConfig);
assert(resolved.errors.measurementNoise.truthMode == "awgn");
assert(resolved.errors.multipath.truthMode == "standard+awgn");

scenario.errors.hardwareDelay.enabled = true;
scenario.errors.hardwareDelay.truth = "awgn";
simConfig.scenarios.reverseGnssClockNavigationScenario = scenario;
assertThrows(@() SimulationConfigResolver.resolve(simConfig), ...
    'SimulationConfigResolver:InvalidAwgnMode');

scenario.errors.hardwareDelay.syntheticStressTest = true;
simConfig.scenarios.reverseGnssClockNavigationScenario = scenario;
resolved = SimulationConfigResolver.resolve(simConfig);
assert(resolved.errors.hardwareDelay.truthMode == "awgn");
assert(resolved.errors.hardwareDelay.syntheticStressTest);

scenario.errors = rmfield(scenario.errors, 'hardwareDelay');
scenario.errors.towerSurvey.enabled = true;
scenario.errors.towerSurvey.truth = "noise";
scenario.errors.towerSurvey.syntheticStressTest = false;
simConfig.scenarios.reverseGnssClockNavigationScenario = scenario;
assertThrows(@() SimulationConfigResolver.resolve(simConfig), ...
    'SimulationConfigResolver:InvalidAwgnMode');

scenario.errors.towerSurvey.syntheticStressTest = true;
simConfig.scenarios.reverseGnssClockNavigationScenario = scenario;
resolved = SimulationConfigResolver.resolve(simConfig);
assert(resolved.errors.towerSurvey.truthMode == "awgn");
end

function testBackwardCompatibleDefaults()
simConfig = loadDefaultConfig();
resolved = SimulationConfigResolver.resolve(simConfig);

assert(isfield(resolved, 'errors'));
expectedFields = ["measurementNoise", "ionosphere", "troposphere", ...
    "multipath", "hardwareDelay", "antennaDelay", "towerSurvey", ...
    "lightTime", "legacySagnac", "relativity", "clock"];

actualFields = string(fieldnames(resolved.errors));
assert(isequal(sort(actualFields), sort(expectedFields(:))));

assert(~resolved.errors.measurementNoise.enabled);
assert(~resolved.errors.ionosphere.enabled);
assert(~resolved.errors.troposphere.enabled);
assert(~resolved.errors.multipath.enabled);
assert(~resolved.errors.hardwareDelay.enabled);
assert(~resolved.errors.antennaDelay.enabled);
assert(~resolved.errors.towerSurvey.enabled);
assert(~resolved.errors.lightTime.enabled);
assert(~resolved.errors.legacySagnac.enabled);
assert(~resolved.errors.relativity.enabled);
assert(resolved.errors.clock.enabled);
assert(resolved.errors.clock.covariance.enabled);
end

function testClockStatus()
simConfig = loadDefaultConfig();
scenario = simConfig.scenarios.reverseGnssClockNavigationScenario;
scenario.process.clockModel = "coupledGaussMarkov";
simConfig.scenarios.reverseGnssClockNavigationScenario = scenario;

resolved = SimulationConfigResolver.resolve(simConfig);
assert(resolved.errors.clock.modelMode == "advanced");
assert(resolved.errors.clock.stochasticMode == "advanced");
assert(resolved.errors.clock.diagnostics.status == "experimental");
end

function simConfig = loadDefaultConfig()
run(char(ProjectPathManager.simulationConfigFile()));
end

function assertThrows(fn, expectedIdentifier)
didThrow = false;
try
    fn();
catch ME
    didThrow = true;
    assert(strcmp(ME.identifier, expectedIdentifier), ...
        'Expected %s, got %s: %s', ...
        expectedIdentifier, ME.identifier, ME.message);
end

assert(didThrow, 'Expected error %s, but no error was thrown.', ...
    expectedIdentifier);
end
