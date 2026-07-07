% test_stage21_one_way_isl_observables
%
% Stage 21: one-way ISL code/Doppler EKF rows plus diagnostic carrier metadata.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir, '..');
addpath(rootDir);

fprintf('=== test_stage21_one_way_isl_observables ===\n');

outDir = fullfile(rootDir, 'output', 'stage21_one_way_isl');
if ~exist(outDir, 'dir'); mkdir(outDir); end

% ----------------------------------------------------------------
% T1: defaults keep ISL disabled
% ----------------------------------------------------------------
fprintf('  T1: ISL defaults disabled ...\n');
cfg0 = revgnss.ConfigFactory.finalizeConfig(revgnss.ConfigFactory.defaultConfig());
assert(isfield(cfg0.measurements,'isl') && ~cfg0.measurements.isl.enable, ...
    'T1 FAILED: cfg.measurements.isl.enable must default false');
assert(~cfg0.measurements.isl.code.useInEKF && ~cfg0.measurements.isl.doppler.useInEKF, ...
    'T1 FAILED: ISL code/Doppler EKF use must default false');
fprintf('    PASS\n');

% ----------------------------------------------------------------
% T2: config guards reject invalid ISL setups
% ----------------------------------------------------------------
fprintf('  T2: config guards ...\n');
cfgBad = cfg0;
cfgBad.measurements.isl.enable = true;
cfgBad.measurements.isl.code.enable = true;
cfgBad.measurements.isl.code.useInEKF = true;
didFail = false;
try
    revgnss.ConfigFactory.finalizeConfig(cfgBad);
catch ME
    didFail = contains(ME.identifier, 'ISLMeasurementBuilder:assetCount');
end
assert(didFail, 'T2 FAILED: ISL with one asset should fail clearly');
cfgBad = mkCfg_(rootDir, outDir);
cfgBad.measurements.isl.carrier.useInEKF = true;
didFail = false;
try
    revgnss.ConfigFactory.finalizeConfig(cfgBad);
catch ME
    didFail = contains(ME.identifier, 'ISLMeasurementBuilder:carrierEkfUnsupported');
end
assert(didFail, 'T2 FAILED: ISL carrier EKF should be guarded');
fprintf('    PASS\n');

% ----------------------------------------------------------------
% T3: code/Doppler Jacobian signs match finite differences
% ----------------------------------------------------------------
fprintf('  T3: ISL Jacobian finite differences ...\n');
cfg = revgnss.ConfigFactory.finalizeConfig(mkCfg_(rootDir, outDir));
[asset, ~, ekf] = revgnss.ScenarioFactory.build(cfg);
assets = revgnss.MultiAssetConfig.instantiateAssets(cfg, asset);
[~, h0, H, ~, info] = revgnss.ISLMeasurementBuilder.build( ...
    cfg, asset, assets, ekf.x, ekf.stateMap, ekf.nx);
assert(numel(info.ekfRowTypes) == 2, 'T3 FAILED: expected ISL code and Doppler EKF rows');
sm = ekf.stateMap;
epsVal = 0.25;
for k = 1:3
    x2 = ekf.x; x2(sm.r_idx(k)) = x2(sm.r_idx(k)) + epsVal;
    h2 = revgnss.ISLMeasurementBuilder.predictEkfRows(cfg, asset, assets, x2, sm, info);
    fd = (h2(1) - h0(1)) / epsVal;
    assert(abs(fd - H(1, sm.r_idx(k))) < 1e-5, 'T3 FAILED: ISL code position sign mismatch');
    x2 = ekf.x; x2(sm.v_idx(k)) = x2(sm.v_idx(k)) + epsVal;
    h2 = revgnss.ISLMeasurementBuilder.predictEkfRows(cfg, asset, assets, x2, sm, info);
    fd = (h2(2) - h0(2)) / epsVal;
    assert(abs(fd - H(2, sm.v_idx(k))) < 1e-12, 'T3 FAILED: ISL Doppler velocity sign mismatch');
end
assert(H(1, sm.b_rx_idx) == 1 && H(2, sm.bdot_rx_idx) == 1, ...
    'T3 FAILED: ISL receiver clock signs must be +1');
fprintf('    PASS\n');

% ----------------------------------------------------------------
% T4: short report run exposes ISL endpoints, rows, and limitations
% ----------------------------------------------------------------
fprintf('  T4: short report run with ISL metadata ...\n');
w = warning('off','all');
out = revgnss.ReportRunner.runSingle(cfg);
warning(w);
obs = out.summary.observableStack;
assert(obs.rowsByType.islCode == 1, 'T4 FAILED: missing ISL code row');
assert(obs.rowsByType.islDoppler == 1, 'T4 FAILED: missing ISL Doppler row');
assert(obs.rowsByType.islCarrierDiagnostic == 1, 'T4 FAILED: missing diagnostic ISL carrier row');
assert(ismember('spacecraftTransmitter', obs.endpointTypes), 'T4 FAILED: ISL transmitter endpoint missing');
assert(obs.nLinks == 6, 'T4 FAILED: links=%d expected 6', obs.nLinks);
tex = fileread(out.texPath);
assert(contains(tex, 'One-Way ISL Observable Architecture'), 'T4 FAILED: ISL report section missing');
assert(contains(tex, 'ISL code rows / EKF-used & 1 / true'), 'T4 FAILED: ISL code status missing');
assert(contains(tex, 'ISL carrier diagnostic rows / EKF-used & 1 / false'), ...
    'T4 FAILED: ISL carrier diagnostic status missing');
assert(~contains(tex, 'TWSTFT rows enabled') && ~contains(tex, 'two-way ISL enabled'), ...
    'T4 FAILED: false two-way/TWSTFT claim present');
fprintf('    PASS (endpoints=%d links=%d ISL rows=%d/%d/%d)\n', ...
    obs.nEndpoints, obs.nLinks, obs.rowsByType.islCode, ...
    obs.rowsByType.islDoppler, obs.rowsByType.islCarrierDiagnostic);

fprintf('=== test_stage21_one_way_isl_observables: ALL PASS ===\n');

function cfg = mkCfg_(rootDir, outDir)
    cfg = revgnss.ConfigFactory.defaultConfig();
    cfg.scenario.nReceivers = 1;
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
    cfg.assets(2).clock.name = 'RxClock_GEO_2';
    cfg.simulation.duration_s = 8;
    cfg.simulation.dt_s = 1;
    cfg.physics.doppler.truth.enable = true;
    cfg.physics.doppler.model.enable = true;
    cfg.measurements.doppler.enable = true;
    cfg.measurements.doppler.useInEKF = true;
    cfg.measurements.carrierPhase.enable = false;
    cfg.measurements.carrierMode = 'off';
    cfg.estimator.runKnownAmbiguityValidation = false;
    cfg.estimator.attitudeInitMode = 'none';
    cfg.estimator.attitudeCarrierMode = 'off';
    cfg.measurements.isl.enable = true;
    cfg.measurements.isl.transmitterAssetIndex = 2;
    cfg.measurements.isl.receiverAssetIndex = 1;
    cfg.measurements.isl.code.enable = true;
    cfg.measurements.isl.code.useInEKF = true;
    cfg.measurements.isl.doppler.enable = true;
    cfg.measurements.isl.doppler.useInEKF = true;
    cfg.measurements.isl.carrier.enable = true;
    cfg.measurements.isl.carrier.useInEKF = false;
    cfg.report.enable = true;
    cfg.report.writePdf = true;
    cfg.report.writeMat = false;
    cfg.report.writeTex = true;
    cfg.report.compileTex = 'never';
    cfg.report.style = 'latex';
    cfg.report.layout = 'clockExact';
    cfg.report.version = 'stage21-test';
    cfg.report.baseOutputDir = outDir;
    cfg.report.overwrite = true;
    cfg.validation.unsupportedFeaturePolicy = 'disableWithWarning';
    addpath(rootDir);
end
