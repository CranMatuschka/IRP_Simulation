function test_independent_fleet_relative_covariance_report_text()
% test_independent_fleet_relative_covariance_report_text  Plan Section 3.5 item 2/4's rendering
% requirement: revgnss.IndependentFleetDiagnosticReport.build must print the link-graph
% connectivity verdict BEFORE any numeric relative-baseline row (never the reverse), must render
% the original pre-Section-3.5 blanket-denial sentence byte-for-byte unchanged on the disabled
% default path, and the forbidden-vocabulary check (revgnss.DistributedFleetReportingContract.
% requireNoForbiddenStageTwoTerm) must still pass on the new section's own text. Real
% IndependentFleetCoordinator + real report build (compileTex='never'), no mocks.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
addpath(rootDir);
addpath(fullfile(rootDir,'config'));
addpath(fullfile(rootDir,'config','internal'));

fprintf('=== test_independent_fleet_relative_covariance_report_text ===\n');
i_test_disabled_path_original_sentence_unchanged_();
i_test_enabled_path_connectivity_precedes_numbers_();
fprintf('=== test_independent_fleet_relative_covariance_report_text: ALL PASS ===\n');
end

% ================================================================================================
function i_test_disabled_path_original_sentence_unchanged_()
outDir = tempname; mkdir(outDir);
cfg = i_baseFleetCfg_(2);
coord = revgnss.IndependentFleetCoordinator(cfg);
coord.run();
results = coord.getResults();
summary = coord.runtimeSummary();
report = revgnss.IndependentFleetDiagnosticReport.build(cfg,results,summary,outDir,'reltext_off');
assert(report.success && report.forbiddenTermCheckPassed,'the disabled-path report must build clean');
assert(report.relativeCovarianceSectionEmitted,'the new section must still be emitted (as "unavailable"), not skipped');
texText = fileread(report.texPath);
assert(~isempty(strfind(texText, ...
    'It does not provide a communication-link relative solution, distributed link fusion, or cross-spacecraft covariance.')), ...
    'the ORIGINAL pre-Section-3.5 blanket-denial sentence must render byte-for-byte unchanged when disabled');
assert(~isempty(strfind(texText,'No relative baseline covariance is reported for this run')), ...
    'the new section must state the honest reason on the disabled path');
fprintf('  PASS disabled path: original blanket-denial sentence byte-unchanged + honest new-section reason\n');
end

% ================================================================================================
function i_test_enabled_path_connectivity_precedes_numbers_()
outDir = tempname; mkdir(outDir);
cfg = i_baseFleetCfg_(2);
cfg.multiAsset.distributedEstimator.correlationNetwork.policy = 'exactPairwiseCrossCovariance';
cfg.multiAsset.distributedEstimator.correlationNetwork.maximumFleetSize = 2;
coord = revgnss.IndependentFleetCoordinator(cfg);
coord.run();
results = coord.getResults();
summary = coord.runtimeSummary();
report = revgnss.IndependentFleetDiagnosticReport.build(cfg,results,summary,outDir,'reltext_on');
assert(report.success && report.forbiddenTermCheckPassed && report.relativeCovarianceSectionEmitted, ...
    'the enabled-path report must build clean with the new section emitted');
texText = fileread(report.texPath);

idxConn = strfind(texText,'Link-graph connectivity');
idxTable = strfind(texText,'baseline err');
assert(~isempty(idxConn) && ~isempty(idxTable), 'both the connectivity verdict and the numeric table must be present');
assert(idxConn(1) < idxTable(1), ...
    'the connectivity verdict must precede the numeric table (plan Section 3.5 item 2 ordering requirement)');
fprintf('  PASS connectivity verdict precedes the numeric table\n');

assert(~isempty(strfind(texText,'Relative baseline covariance diagnostic')),'section header must be present');
assert(~isempty(strfind(texText,'Shape')) && ~isempty(strfind(texText,'NIS is not reported')), ...
    'shape/NIS disclaimers must be present');
assert(~isempty(strfind(texText, ...
    'It additionally reports, in the relative baseline covariance section above')), ...
    'the Interpretation section must be conditionally updated to describe the new coverage');
fprintf('  PASS shape/NIS disclaimers + updated Interpretation sentence present\n');
end

% ================================================================================================
function cfg = i_baseFleetCfg_(nAssets)
cfg = masterConfig();
cfg.clocks.tower.product.mode = 'perfectCorrection';
cfg.simulation.duration_s = 4;
cfg.simulation.dt_s = 1;
cfg.report.writePdf = false; cfg.report.writeMat = false; cfg.report.compileTex = 'never';
cfg.plots.enable = false; cfg.plots.showFigures = false;
cfg.scenario.nSpaceAssets = nAssets;
cfg.multiAsset.mode = 'fast';
cfg.multiAsset.estimateMode = 'off';
cfg.multiAsset.keepIslInPerAssetEkf = false;
cfg.multiAsset.towersObserveSecondaries = false;
cfg.multiAsset.distributedEstimator.enable = true;
cfg.multiAsset.distributedEstimator.stateExchange.enable = false;
cfg.multiAsset.distributedEstimator.deliveryLedger.enable = true;
cfg.multiAsset.distributedEstimator.linkUpdate.enable = true;
cfg.multiAsset.distributedEstimator.linkUpdate.ownerPolicy = 'initiator';
cfg.multiAsset.distributedEstimator.linkUpdate.correlationPolicy = 'splitCovarianceIntersection';
cfg.multiAsset.distributedEstimator.linkUpdate.updateAdapter.observable = 'coherentTwoWayCodeRange';
cfg.measurements.isl.enable = true;
cfg.measurements.isl.twoWay.enable = true;
cfg.measurements.isl.twoWay.range.enable = true;
cfg.measurements.isl.twoWay.range.useInEKF = false;
end
