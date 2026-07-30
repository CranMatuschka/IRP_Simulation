% test_canonical_configuration_flow  One JSON overlays the canonical master configuration.

testDirectory = fileparts(mfilename('fullpath'));
repositoryRoot = fileparts(testDirectory);
addpath(repositoryRoot);
addpath(fullfile(repositoryRoot, 'config'));
addpath(fullfile(repositoryRoot, 'config', 'internal'));

[masterResolved, ~] = resolveSimulationConfig();
[defaultResolved, defaultMetadata] = resolveSimulationConfig('default.json');
assert(strcmp(defaultMetadata.explicitPaths{1}, 'scenario.name'));
assert(~isfield(defaultResolved, 'x_comment'));

defaultComparable = defaultResolved;
if isfield(defaultComparable, 'provenance')
    defaultComparable = rmfield(defaultComparable, 'provenance');
end
assert(isequaln(masterResolved, defaultComparable), ...
    'Minimal default.json does not resolve to the masterConfig nominal case.');
assert(~defaultResolved.atmosphere.realistic);
assert(strcmp(defaultResolved.errors.troposphere.modelType, 'simpleMapped'));
assert(strcmp(defaultResolved.errors.ionosphere.modelType, 'simpleMapped'));
assert(defaultResolved.errors.troposphere.truth.zenithDelay_m ~= ...
    defaultResolved.errors.troposphere.model.zenithDelay_m);
assert(defaultResolved.errors.ionosphere.truth.zenithDelay_m ~= ...
    defaultResolved.errors.ionosphere.model.zenithDelay_m);
assert(defaultResolved.scenario.nReceivers == 1);
assert(defaultResolved.estimator.starTracker.enable && ...
    defaultResolved.estimator.imu.enable);
assert(defaultResolved.estimator.estimateAttitude);
assert(strcmp(defaultResolved.estimator.attitude.primaryMode, ...
    'starTrackerGyroscope'));
assert(strcmp(defaultResolved.estimator.attitudeCarrierMode,'off'));
assert(~defaultResolved.estimator.integerAmbiguity.enable && ...
    ~defaultResolved.estimator.diffAtt.ambiguityResolution.enable);

[realismResolved, ~] = resolveSimulationConfig('realism.json');
assert(realismResolved.atmosphere.realistic);
assert(strcmp(realismResolved.errors.troposphere.modelType, 'localWeatherGM'));
assert(strcmp(realismResolved.errors.ionosphere.modelType, 'tecGaussMarkov'));
assert(realismResolved.orbit.truth.perturbations.luniSolar.enable && ...
    realismResolved.orbit.truth.perturbations.srp.enable);
assert(~realismResolved.estimator.dynamics.perturbations.luniSolar.enable && ...
    ~realismResolved.estimator.dynamics.perturbations.srp.enable);
assert(realismResolved.estimator.processNoise.modelMismatch.enable);
assert(realismResolved.estimator.starTracker.whiteAngularSigma_rad > ...
    defaultResolved.estimator.starTracker.whiteAngularSigma_rad);
assert(realismResolved.estimator.imu.truth.arw_rad_per_sqrt_s > ...
    defaultResolved.estimator.imu.truth.arw_rad_per_sqrt_s);

resolvedAgain = revgnss.ConfigFactory.finalizeConfig(defaultResolved);
assert(isequaln(defaultResolved, resolvedAgain), ...
    'Configuration resolution is not idempotent.');

assert(~masterResolved.estimator.enforceCarrierArcConsistency.enable);
assert(~masterResolved.estimator.arcSeparatedAmbiguities.enable);
assert(~masterResolved.carrierSlip.enable);
unsupportedArcConfig = masterResolved;
unsupportedArcConfig.estimator.enforceCarrierArcConsistency.enable = true;
unsupportedArcRejected = false;
try
    revgnss.ConfigFactory.finalizeConfig(unsupportedArcConfig);
catch exception
    unsupportedArcRejected = strcmp(exception.identifier, ...
        'ConfigFactory:carrierArcConsistencyUnavailable');
end
assert(unsupportedArcRejected, ...
    'Unavailable cross-frequency arc consistency was accepted.');

unsupportedIfTrackingConfig = masterResolved;
unsupportedIfTrackingConfig.carrierSlip.enable = true;
unsupportedIfTrackingRejected = false;
try
    revgnss.ConfigFactory.finalizeConfig(unsupportedIfTrackingConfig);
catch exception
    unsupportedIfTrackingRejected = strcmp(exception.identifier, ...
        'ConfigFactory:carrierIfArcTrackingUnavailable');
end
assert(unsupportedIfTrackingRejected, ...
    'Unavailable ionosphere-free carrier arc tracking was accepted.');

arrayOverlay = struct();
arrayOverlay.assets = repmat(masterResolved.assets(1), 1, 2);
[arrayOverlay.assets.unrecognizedScientificField] = deal(1, 2);
arrayUnknownRejected = false;
try
    deepMergeConfig(masterResolved, arrayOverlay);
catch exception
    arrayUnknownRejected = strcmp(exception.identifier, ...
        'deepMergeConfig:unknownConfigPath');
end
assert(arrayUnknownRejected, ...
    'An unknown field inside a configuration struct array was accepted.');

unknownOverlay = struct();
unknownOverlay.realism.directOverlay = true;
temporaryJson = [tempname '.json'];
fileIdentifier = fopen(temporaryJson, 'wt');
assert(fileIdentifier >= 0, 'Unable to create temporary configuration JSON.');
cleanupFile = onCleanup(@() deleteIfPresent_(temporaryJson));
cleanupHandle = onCleanup(@() fclose(fileIdentifier));
fprintf(fileIdentifier, '%s', jsonencode(unknownOverlay));
clear cleanupHandle

unknownRejected = false;
try
    resolveSimulationConfig(temporaryJson);
catch exception
    unknownRejected = strcmp(exception.identifier, ...
        'deepMergeConfig:unknownConfigPath');
end
assert(unknownRejected, 'An unknown or retired configuration key was accepted.');

atmosphereOffOverlay = struct();
atmosphereOffOverlay.atmosphere.realistic = true;
atmosphereOffOverlay.errors.troposphere.enable = false;
atmosphereOffOverlay.errors.ionosphere.enable = false;
atmosphereOffJson = [tempname '.json'];
fileIdentifier = fopen(atmosphereOffJson, 'wt');
assert(fileIdentifier >= 0, 'Unable to create temporary atmosphere JSON.');
cleanupAtmosphereFile = onCleanup(@() deleteIfPresent_(atmosphereOffJson));
cleanupHandle = onCleanup(@() fclose(fileIdentifier));
fprintf(fileIdentifier, '%s', jsonencode(atmosphereOffOverlay));
clear cleanupHandle
[atmosphereOffResolved, ~] = resolveSimulationConfig(atmosphereOffJson);
assert(~atmosphereOffResolved.errors.troposphere.truth.enable && ...
    ~atmosphereOffResolved.errors.troposphere.model.enable);
assert(~atmosphereOffResolved.errors.ionosphere.truth.enable && ...
    ~atmosphereOffResolved.errors.ionosphere.model.enable);

runnerSource = fileread(fullfile(repositoryRoot, 'run_oo_v1.m'));
assert(contains(runnerSource, 'resolveSimulationConfig(configPath)'));
assert(contains(runnerSource, 'configPath = ''default.json'''));

fprintf('test_canonical_configuration_flow: PASS\n');

function deleteIfPresent_(path)
    if isfile(path)
        delete(path);
    end
end
