function test_scientific_validation_manifest()
root = fileparts(fileparts(mfilename('fullpath')));
addpath(root);
addpath(fullfile(root,'config'));
addpath(fullfile(root,'config','internal'));

cfg = masterConfig();
manifest = cfg.validation.manifest;
assert(strcmp(manifest.status,'declaredNotStatisticallyExecuted'));
assert(manifest.shortEnsemble.minimumIndependentRuns >= 200);
assert(numel(unique(manifest.shortEnsemble.seedList)) >= ...
    manifest.shortEnsemble.minimumIndependentRuns);
assert(manifest.fullScenario.minimumIndependentRuns >= 50);
assert(numel(unique(manifest.fullScenario.seedList)) >= ...
    manifest.fullScenario.minimumIndependentRuns);
assert(manifest.fullScenario.duration_s == 3600);
assert(manifest.lightTime.maximumResidual_s <= 1e-11);
assert(manifest.range.maximumZeroNoiseClosure_m <= 1e-3);
assert(manifest.jacobian.maximumRelativeError <= 1e-5);
assert(manifest.statistics.confidence == 0.95);
assert(strcmp(manifest.statistics.evaluationRule, ...
    'fixedEpochsAcrossIndependentRuns'));

comparison = compareDefaultAndRealismConfigurations();
paths = string(comparison.changed.Path);
assert(any(paths == "realism.grade"));
assert(any(paths == "clock.templateSource"));
assert(any(paths == "estimator.starTracker.whiteAngularSigma_rad"));
assert(isempty(comparison.addedBeforeDerivation), ...
    'The realism overlay introduced a field not declared by masterConfig.');
addedPaths = string(comparison.addedByRealism.Path);
assert(all(contains(addedPaths,'relativisticFracFreq')), ...
    'Realism resolution added an unexpected derived field.');

fprintf('test_scientific_validation_manifest: PASS\n');
end
