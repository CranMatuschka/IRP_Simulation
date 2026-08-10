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
% The clock is deliberately NOT asserted here any more. Until 2026-08-10 the realism
% overlay differed from the default on clock.templateSource, flipping a whole second
% h-coefficient table. With ONE table (Winkel 2003 Table 2.1) both resolve to the same
% CESIUM1 with the same coefficients, so the clock is no longer a default-vs-realism
% difference at all -- and asserting one would pin an artefact of the retired table.
assert(~any(paths == "clock.templateSource"), ...
    'clock.templateSource was removed 2026-08-10 and must not reappear in the manifest.');
assert(any(paths == "estimator.starTracker.whiteAngularSigma_rad"));
assert(isempty(comparison.addedBeforeDerivation), ...
    'The realism overlay introduced a field not declared by masterConfig.');
addedPaths = string(comparison.addedByRealism.Path);
assert(all(contains(addedPaths,'relativisticFracFreq')), ...
    'Realism resolution added an unexpected derived field.');

fprintf('test_scientific_validation_manifest: PASS\n');
end
