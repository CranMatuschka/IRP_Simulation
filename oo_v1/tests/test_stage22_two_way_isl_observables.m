% test_stage22_two_way_isl_observables
%
% Stage 22: two-way ISL range EKF row and double-counting guards.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir, '..');
addpath(rootDir);

fprintf('=== test_stage22_two_way_isl_observables ===\n');

outDir = fullfile(rootDir, 'output', 'stage22_two_way_isl');
if ~exist(outDir, 'dir'); mkdir(outDir); end

% ----------------------------------------------------------------
% T1: two-way defaults disabled
% ----------------------------------------------------------------
fprintf('  T1: two-way defaults disabled ...\n');
cfg0 = revgnss.ConfigFactory.finalizeConfig(revgnss.ConfigFactory.defaultConfig());
assert(~cfg0.measurements.isl.twoWay.enable, 'T1 FAILED: two-way ISL must default off');
assert(~cfg0.measurements.isl.twoWay.range.useInEKF, 'T1 FAILED: two-way range EKF must default off');
fprintf('    PASS\n');

% ----------------------------------------------------------------
% T2: one-way code EKF + two-way range EKF double-counting is guarded
% ----------------------------------------------------------------
fprintf('  T2: double-counting guard ...\n');
cfgBad = mkCfg_(rootDir, outDir);
cfgBad.measurements.isl.code.useInEKF = true;
didFail = false;
try
    revgnss.ConfigFactory.finalizeConfig(cfgBad);
catch ME
    didFail = contains(ME.identifier, 'TwoWayISLMeasurementBuilder:doubleCounting');
end
assert(didFail, 'T2 FAILED: double-counting guard did not fire');
fprintf('    PASS\n');

% ----------------------------------------------------------------
% T3: two-way range Jacobian sign and zero clock column
% ----------------------------------------------------------------
fprintf('  T3: two-way range finite differences ...\n');
cfg = revgnss.ConfigFactory.finalizeConfig(mkCfg_(rootDir, outDir));
[asset, ~, ekf] = revgnss.ScenarioFactory.build(cfg);
assets = revgnss.MultiAssetConfig.instantiateAssets(cfg, asset);
[~, h0, H, ~, info] = revgnss.TwoWayISLMeasurementBuilder.build( ...
    cfg, asset, assets, ekf.x, ekf.stateMap, ekf.nx);
assert(numel(info.ekfRowTypes) == 1 && strcmp(info.ekfRowTypes{1}, 'islTwoWayRange'), ...
    'T3 FAILED: expected one two-way range EKF row');
sm = ekf.stateMap;
assert(H(1, sm.b_rx_idx) == 0 && H(1, sm.bdot_rx_idx) == 0, ...
    'T3 FAILED: two-way range must not touch receiver clock columns');
epsVal = 0.25;
for k = 1:3
    x2 = ekf.x; x2(sm.r_idx(k)) = x2(sm.r_idx(k)) + epsVal;
    h2 = revgnss.TwoWayISLMeasurementBuilder.predictEkfRows(cfg, asset, assets, x2, sm, info);
    fd = (h2(1) - h0(1)) / epsVal;
    assert(abs(fd - H(1, sm.r_idx(k))) < 1e-5, ...
        'T3 FAILED: two-way range position sign mismatch');
end
fprintf('    PASS\n');

% ----------------------------------------------------------------
% T4: short report run exposes correct one-way/two-way row roles
% ----------------------------------------------------------------
fprintf('  T4: short report run with two-way ISL metadata ...\n');
w = warning('off','all');
out = revgnss.ReportRunner.runSingle(cfg);
warning(w);
obs = out.summary.observableStack;
assert(obs.rowsByType.islCode == 1 && obs.rowsByType.islDoppler == 1, ...
    'T4 FAILED: one-way diagnostic rows missing');
assert(obs.rowsByType.islCarrierDiagnostic == 1, 'T4 FAILED: ISL carrier diagnostic row missing');
assert(obs.rowsByType.islTwoWayRange == 1, 'T4 FAILED: two-way range row missing');
assert(obs.rowsByType.islTwoWayDopplerDiagnostic == 1, 'T4 FAILED: two-way Doppler diagnostic row missing');
assert(obs.nLinks == 7, 'T4 FAILED: links=%d expected 7', obs.nLinks);
tex = fileread(out.texPath);
assert(contains(tex, 'Two-Way ISL Observable Architecture'), 'T4 FAILED: two-way section missing');
assert(contains(tex, 'One-way code / Doppler EKF-used & false / false'), ...
    'T4 FAILED: raw one-way rows should be diagnostic-only');
assert(contains(tex, 'Two-way range rows / EKF-used & 1 / true'), ...
    'T4 FAILED: two-way range EKF status missing');
assert(contains(tex, 'Double-counting guard & OK'), 'T4 FAILED: double-counting guard status missing');
assert(~contains(tex, 'TWSTFT rows enabled') && ~contains(tex, 'relay/transponder enabled'), ...
    'T4 FAILED: false unsupported-link claim present');
fprintf('    PASS (links=%d ISL one/two-way rows=%d/%d/%d/%d/%d)\n', ...
    obs.nLinks, obs.rowsByType.islCode, obs.rowsByType.islDoppler, ...
    obs.rowsByType.islCarrierDiagnostic, obs.rowsByType.islTwoWayRange, ...
    obs.rowsByType.islTwoWayDopplerDiagnostic);

fprintf('=== test_stage22_two_way_isl_observables: ALL PASS ===\n');

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
    cfg.assets(2).r_ecef_m = revgnss.GeometryUtils.geodetic2ecef(0.0, 28.0*pi/180, 35786000.0);
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
    cfg.measurements.isl.code.useInEKF = false;
    cfg.measurements.isl.doppler.enable = true;
    cfg.measurements.isl.doppler.useInEKF = false;
    cfg.measurements.isl.carrier.enable = true;
    cfg.measurements.isl.carrier.useInEKF = false;
    cfg.measurements.isl.twoWay.enable = true;
    cfg.measurements.isl.twoWay.range.enable = true;
    cfg.measurements.isl.twoWay.range.useInEKF = true;
    cfg.measurements.isl.twoWay.range.sigma_m = 0.25;
    cfg.measurements.isl.twoWay.doppler.enable = true;
    cfg.measurements.isl.twoWay.doppler.useInEKF = false;
    cfg.report.enable = true;
    cfg.report.writePdf = true;
    cfg.report.writeMat = false;
    cfg.report.writeTex = true;
    cfg.report.compileTex = 'never';
    cfg.report.style = 'latex';
    cfg.report.layout = 'clockExact';
    cfg.report.version = 'stage22-test';
    cfg.report.baseOutputDir = outDir;
    cfg.report.overwrite = true;
    cfg.validation.unsupportedFeaturePolicy = 'disableWithWarning';
    addpath(rootDir);
end
