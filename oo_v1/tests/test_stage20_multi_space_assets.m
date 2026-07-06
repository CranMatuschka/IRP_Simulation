% test_stage20_multi_space_assets
%
% Stage 20: multiple represented spacecraft assets without ISL/TWSTFT rows.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir, '..');
addpath(rootDir);

fprintf('=== test_stage20_multi_space_assets ===\n');

outDir = fullfile(rootDir, 'output', 'stage20_multi_assets');
if ~exist(outDir, 'dir'); mkdir(outDir); end

% ----------------------------------------------------------------
% T1: default config remains single-asset compatible
% ----------------------------------------------------------------
fprintf('  T1: default single-asset compatibility ...\n');
cfg1 = revgnss.ConfigFactory.defaultConfig();
cfg1 = revgnss.ConfigFactory.finalizeConfig(cfg1);
s1 = revgnss.MultiAssetConfig.summary(cfg1);
assert(cfg1.scenario.nSpaceAssets == 1, 'T1 FAILED: default nSpaceAssets must be 1');
assert(numel(cfg1.assets) == 1, 'T1 FAILED: default assets array must contain one asset');
assert(strcmp(cfg1.asset.name, cfg1.assets(1).name), 'T1 FAILED: cfg.asset must mirror assets(1)');
assert(s1.assetTable(1).estimated, 'T1 FAILED: primary asset must be estimated');
fprintf('    PASS\n');

% ----------------------------------------------------------------
% T2: secondary asset is represented but guarded out of EKF ownership
% ----------------------------------------------------------------
fprintf('  T2: multi-asset config normalization ...\n');
cfg2 = mkCfg_(rootDir, outDir);
cfg2 = revgnss.ConfigFactory.finalizeConfig(cfg2);
s2 = revgnss.MultiAssetConfig.summary(cfg2);
assert(cfg2.scenario.nSpaceAssets == 2, 'T2 FAILED: nSpaceAssets mismatch');
assert(numel(cfg2.assets) == 2, 'T2 FAILED: assets array size mismatch');
assert(s2.assetTable(1).estimated, 'T2 FAILED: primary asset should be estimated');
assert(~s2.assetTable(2).estimated, 'T2 FAILED: secondary asset should not be estimated');
assert(strcmp(s2.assetTable(2).stateOwner, 'representedOnly'), 'T2 FAILED: secondary state owner mismatch');
assert(s2.assetTable(2).activeLinkCount == 0, 'T2 FAILED: secondary asset must have no active rows');
assert(s2.islRows == 0 && s2.twstftRows == 0, 'T2 FAILED: Stage 20 must not create space-link rows');
fprintf('    PASS\n');

% ----------------------------------------------------------------
% T3: short run exposes primary rows plus secondary endpoint metadata
% ----------------------------------------------------------------
fprintf('  T3: short run endpoint/link metadata ...\n');
w = warning('off','all');
out = revgnss.ReportRunner.runSingle(cfg2);
warning(w);
obs = out.summary.observableStack;
assert(obs.nEndpoints == 9, 'T3 FAILED: endpoints=%d expected 9', obs.nEndpoints);
assert(obs.nLinks == 15, 'T3 FAILED: links=%d expected primary-only 15', obs.nLinks);
assert(ismember('GEO-1', obs.endpointAssetNames), 'T3 FAILED: primary endpoint asset missing');
assert(ismember('GEO-2', obs.endpointAssetNames), 'T3 FAILED: secondary endpoint asset missing');
assert(numel(obs.linksByAsset) == 1 && strcmp(obs.linksByAsset(1).assetName, 'GEO-1'), ...
    'T3 FAILED: active links should target only GEO-1');
assert(out.summary.totalCodeRows == 30, 'T3 FAILED: code rows changed');
assert(out.summary.totalDopplerRows == 30, 'T3 FAILED: Doppler rows changed');
assert(out.summary.totalCarrierRows == 15, 'T3 FAILED: carrier rows changed');
res = out.sim.getResults();
assert(numel(res.assetHistories) == 2, 'T3 FAILED: secondary truth history missing');
fprintf('    PASS (endpoints=%d links=%d rows code/dop/car=%d/%d/%d)\n', ...
    obs.nEndpoints, obs.nLinks, out.summary.totalCodeRows, ...
    out.summary.totalDopplerRows, out.summary.totalCarrierRows);

% ----------------------------------------------------------------
% T4: report source states the multi-asset architecture truthfully
% ----------------------------------------------------------------
fprintf('  T4: report section text ...\n');
tex = fileread(out.texPath);
assert(contains(tex, 'Multi-Asset Scenario Architecture'), ...
    'T4 FAILED: multi-asset section missing');
assert(contains(tex, 'GEO-2'), 'T4 FAILED: secondary asset missing from report');
assert(contains(tex, 'ISL / TWSTFT rows & 0 / 0'), ...
    'T4 FAILED: report must state no ISL/TWSTFT rows');
assert(contains(tex, 'Active links by receiver asset & GEO-1:15'), ...
    'T4 FAILED: active-link-by-asset row missing');
assert(~contains(tex, 'ISL rows enabled'), 'T4 FAILED: false ISL claim present');
fprintf('    PASS\n');

fprintf('=== test_stage20_multi_space_assets: ALL PASS ===\n');

function cfg = mkCfg_(rootDir, outDir)
    cfg = revgnss.ConfigFactory.defaultConfig();
    cfg.scenario.nReceivers = 3;
    cfg.scenario.nSpaceAssets = 2;
    cfg.assets(1) = cfg.asset;
    cfg.assets(1).assetIndex = 1;
    cfg.assets(1).estimated = true;
    cfg.assets(1).stateOwner = 'primaryEKF';
    cfg.assets(2) = cfg.assets(1);
    cfg.assets(2).name = 'GEO-2';
    cfg.assets(2).assetIndex = 2;
    cfg.assets(2).estimated = false;
    cfg.assets(2).stateOwner = 'representedOnly';
    cfg.assets(2).r_ecef_m = models.frames.GeometryUtils.geodetic2ecef(0.0, 28.0*pi/180, 35786000.0);
    cfg.assets(2).receiverLeverArm_body_m = [0; 0; 0];
    cfg.assets(2).receiverLeverArms_body_m = [0; 0; 0];
    cfg.assets(2).clock.name = 'RxClock_GEO_2';
    cfg.simulation.duration_s = 20;
    cfg.simulation.dt_s = 1;
    cfg.signals.twoFrequency.enable = true;
    cfg.measurements.doppler.enable = true;
    cfg.measurements.doppler.useInEKF = true;
    cfg.physics.doppler.truth.enable = true;
    cfg.physics.doppler.model.enable = true;
    cfg.measurements.carrierPhase.enable = true;
    cfg.measurements.carrierMode = 'ekfFloat';
    cfg.estimation.ambiguityMode = 'floatPerTowerReceiverSignal';
    cfg.estimation.ambiguity.initialSigma_m = 100;
    cfg.measurements.carrier.slipDetection.enable = true;
    cfg.measurements.carrier.slipDetection.action = 'resetAndSkip';
    cfg.estimation.troposphereMode = 'none';
    cfg.estimator.runKnownAmbiguityValidation = false;
    cfg.estimator.attitudeCarrierMode = 'calibratedDifferentialAmbiguity';
    cfg.estimator.diffAtt.calibWin_s = 5;
    cfg.estimator.attitudeInitMode = 'coarseBaselineIntegerSearch';
    cfg.estimator.attitudeInit.search.windowDeg = [1; 1; 1];
    cfg.estimator.attitudeInit.search.stepDeg = [1; 1; 1];
    cfg.estimator.attitudeInit.search.maxCandidates = 27;
    cfg.estimator.attitudeInit.search.ratioThreshold = 1.20;
    cfg.estimator.attitudeInitShadow.enable = false;
    cfg.plots.enable = false;
    cfg.report.enable = true;
    cfg.report.writePdf = true;
    cfg.report.writeMat = false;
    cfg.report.writeTex = true;
    cfg.report.compileTex = 'never';
    cfg.report.style = 'latex';
    cfg.report.layout = 'clockExact';
    cfg.report.version = 'stage20-test';
    cfg.report.baseOutputDir = outDir;
    cfg.report.overwrite = true;
    cfg.validation.unsupportedFeaturePolicy = 'disableWithWarning';
    addpath(rootDir);
end
