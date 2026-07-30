% test_joint_multi_asset_formation_diagnostics
% Verify joint-state absolute, relative, and rigid-formation diagnostics.

repoRoot = fileparts(fileparts(mfilename('fullpath')));
addpath(genpath(repoRoot));

time_s = [0; 60; 120];
truthPositions_m = cat(3, ...
    [0 1000 0; 0 0 1000; 0 0 0], ...
    [10 1010 10; 0 0 1000; 0 0 0], ...
    [20 1020 20; 0 0 1000; 0 0 0]);
estimatedPositions_m = truthPositions_m;
estimatedPositions_m(:, 2, :) = estimatedPositions_m(:, 2, :) + repmat([2; -1; 0.5], 1, 1, 3);
estimatedPositions_m(:, 3, :) = estimatedPositions_m(:, 3, :) + repmat([-1; 1; 0], 1, 1, 3);

jointEstimate = struct('time_s', time_s, 'asset', struct([]));
multiAssetTruth = struct('time_s', time_s, 'asset', struct([]));
for assetIndex = 1:3
    jointEstimate.asset(assetIndex).name = sprintf('GEO-%d', assetIndex);
    jointEstimate.asset(assetIndex).r_ecef_m = squeeze(estimatedPositions_m(:, assetIndex, :));
    multiAssetTruth.asset(assetIndex).r_ecef_m = squeeze(truthPositions_m(:, assetIndex, :));
end
jointEstimate.relativePositionCovarianceToReference_m2 = ...
    repmat(4 * eye(3),1,1,2,numel(time_s));

diagnostics = revgnss.JointMultiAssetFormationDiagnostics.compute( ...
    jointEstimate, multiAssetTruth,struct('physicalRangeRowsConsumed',6, ...
    'physicalRangeLinkCount',1));
assert(diagnostics.available);
assert(isequal(size(diagnostics.absolutePositionError_m), [3, 3]));
assert(isequal(size(diagnostics.relativeBaselineError_m), [2, 3]));
assert(isequal(size(diagnostics.relativeBaselineSigma3d_m), [2, 3]));
assert(abs(diagnostics.absolutePositionError_m(2, end) - sqrt(5.25)) < 1e-12);
assert(abs(diagnostics.relativeBaselineError_m(1, end) - sqrt(5.25)) < 1e-12);
assert(abs(diagnostics.relativeBaselineSigma3d_m(1,end) - sqrt(12)) < 1e-12);
assert(diagnostics.relativeCovarianceAvailable);
assert(diagnostics.hasPhysicalRangeConstraints);
assert(diagnostics.physicalRangeLinkCount == 1);
assert(diagnostics.relativePositionDof == 6);
assert(strcmp(diagnostics.rangeOnlyObservabilityStatus, ...
    'insufficientScalarConstraints'));

diagnosticsWithoutRange = revgnss.JointMultiAssetFormationDiagnostics.compute( ...
    jointEstimate, multiAssetTruth);
assert(~diagnosticsWithoutRange.hasPhysicalRangeConstraints);
assert(strcmp(diagnosticsWithoutRange.rangeOnlyObservabilityStatus, ...
    'noPhysicalRangeRows'));

positionFigure = revgnss.JointMultiAssetFormationDiagnostics.plotPositionErrors(diagnostics);
assert(isgraphics(positionFigure));
close(positionFigure);
relativeLayerFigure = revgnss.JointMultiAssetFormationDiagnostics.plotRelativeLayer(diagnostics);
assert(isgraphics(relativeLayerFigure));
close(relativeLayerFigure);
kabschFigure = revgnss.JointMultiAssetFormationDiagnostics.plotKabschAlignment(diagnostics);
assert(isgraphics(kabschFigure));
close(kabschFigure);

fprintf('test_joint_multi_asset_formation_diagnostics: PASS\n');
