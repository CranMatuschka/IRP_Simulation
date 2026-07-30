% test_ionosphere_model_independence  Estimator climatology never derives from truth VTEC.

testDirectory = fileparts(mfilename('fullpath'));
repositoryRoot = fileparts(testDirectory);
addpath(repositoryRoot);
addpath(fullfile(repositoryRoot, 'config'));
addpath(fullfile(repositoryRoot, 'config', 'internal'));

baseConfig = masterConfig();
nominalModel = baseConfig.errors.ionosphere.model.klobuchar;
assert(isequaln(nominalModel, struct( ...
    'amplitude_ns', 20, 'period_h', 24, 'dc_ns', 5)), ...
    'masterConfig must own the reduced vertical Klobuchar parameters.');

profileConfig = realisticAtmosphereConfig(baseConfig);
assert(isequaln(profileConfig.errors.ionosphere.model.klobuchar, nominalModel), ...
    'The atmosphere profile changed estimator parameters.');

truthOverlay = struct();
truthOverlay.atmosphere.realistic = true;
truthOverlay.errors.ionosphere.truth.diurnal = struct( ...
    'enable', true, ...
    'vtecDay_TECU', 75, ...
    'vtecNight_TECU', 18, ...
    'peakLocalTime_h', 16);
truthOverlay.errors.ionosphere.model.klobuchar = struct( ...
    'amplitude_ns', 17, 'period_h', 22, 'dc_ns', 4);

temporaryJson = [tempname '.json'];
fileIdentifier = fopen(temporaryJson, 'wt');
assert(fileIdentifier >= 0, 'Unable to create temporary configuration JSON.');
cleanupFile = onCleanup(@() deleteIfPresent_(temporaryJson));
cleanupHandle = onCleanup(@() fclose(fileIdentifier));
fprintf(fileIdentifier, '%s', jsonencode(truthOverlay));
clear cleanupHandle

[resolvedOverride, metadata] = resolveSimulationConfig(temporaryJson);
assert(isequaln(resolvedOverride.errors.ionosphere.model.klobuchar, ...
    truthOverlay.errors.ionosphere.model.klobuchar), ...
    'A scenario-owned estimator product did not survive resolution.');
assert(all(ismember({ ...
    'errors.ionosphere.truth.diurnal.vtecDay_TECU', ...
    'errors.ionosphere.model.klobuchar.amplitude_ns'}, metadata.explicitPaths)), ...
    'Truth and estimator provenance was not recorded.');

lowTruth = profileConfig;
highTruth = profileConfig;
lowTruth.errors.ionosphere.truth.diurnal.vtecDay_TECU = 25;
lowTruth.errors.ionosphere.truth.diurnal.vtecNight_TECU = 5;
highTruth.errors.ionosphere.truth.diurnal.vtecDay_TECU = 70;
highTruth.errors.ionosphere.truth.diurnal.vtecNight_TECU = 20;

lowEnvironment = models.errors.EnvironmentModel(lowTruth, 42);
highEnvironment = models.errors.EnvironmentModel(highTruth, 42);
longitude = lowTruth.towers(1).lon_rad;
evaluationTime = mod(14 * 3600 - longitude * 43200 / pi, 86400);
lowEnvironment.tNow_s = evaluationTime;
highEnvironment.tNow_s = evaluationTime;
frequencyL1 = revgnss.SignalDefinition.get('L1').frequency_Hz;

lowModelDelay = lowEnvironment.getIonoDelay( ...
    1, pi / 2, 'model', frequencyL1, frequencyL1);
highModelDelay = highEnvironment.getIonoDelay( ...
    1, pi / 2, 'model', frequencyL1, frequencyL1);
lowTruthDelay = lowEnvironment.getIonoDelay( ...
    1, pi / 2, 'truth', frequencyL1, frequencyL1);
highTruthDelay = highEnvironment.getIonoDelay( ...
    1, pi / 2, 'truth', frequencyL1, frequencyL1);

assert(abs(lowModelDelay - highModelDelay) < 1e-12, ...
    'Changing truth VTEC changed the estimator correction.');
assert(abs(lowTruthDelay - highTruthDelay) > 1, ...
    'The truth-only VTEC change did not affect the simulated delay.');

fprintf('test_ionosphere_model_independence: PASS\n');

function deleteIfPresent_(path)
    if isfile(path)
        delete(path);
    end
end
