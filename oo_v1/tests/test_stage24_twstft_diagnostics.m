% test_stage24_twstft_diagnostics
%
% Stage 24: TWSTFT code time-transfer diagnostic scaffold.
% Verifies config defaults, guards, build path, observable row descriptor,
% and report section content.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir, '..');
addpath(rootDir);

fprintf('=== test_stage24_twstft_diagnostics ===\n');

outDir = fullfile(rootDir, 'output', 'stage24_twstft_diag');
if ~exist(outDir, 'dir'); mkdir(outDir); end

% ----------------------------------------------------------------
% T1: TWSTFT config defaults are all off
% ----------------------------------------------------------------
fprintf('  T1: TWSTFT config defaults ...\n');
cfg0 = revgnss.ConfigFactory.finalizeConfig(revgnss.ConfigFactory.defaultConfig());
assert(~cfg0.measurements.twstft.enable,          'T1 FAILED: twstft.enable must default false');
assert(~cfg0.measurements.twstft.code.enable,     'T1 FAILED: twstft.code.enable must default false');
assert(~cfg0.measurements.twstft.code.useInEKF,   'T1 FAILED: twstft.code.useInEKF must default false');
assert(cfg0.measurements.twstft.requireIslTiming, 'T1 FAILED: requireIslTiming must default true');
assert(cfg0.measurements.twstft.referenceAssetIndex == 1, 'T1 FAILED: referenceAssetIndex must default 1');
assert(cfg0.measurements.twstft.remoteAssetIndex   == 2, 'T1 FAILED: remoteAssetIndex must default 2');
fprintf('    PASS\n');

% ----------------------------------------------------------------
% T2: Guards fire correctly on invalid config
% ----------------------------------------------------------------
fprintf('  T2: TWSTFT config guards ...\n');

% Guard: useInEKF=true must be rejected
cfgBad = mkCfg_(rootDir, outDir);
cfgBad.measurements.twstft.code.useInEKF = true;
didFail = false;
try
    revgnss.ConfigFactory.finalizeConfig(cfgBad);
catch ME
    didFail = contains(ME.identifier, 'useInEkfBlocked');
end
assert(didFail, 'T2a FAILED: useInEKF=true did not fail');

% Guard: fewer than 2 assets must be rejected
cfgBad2 = revgnss.ConfigFactory.defaultConfig();
cfgBad2.measurements.twstft.enable = true;
cfgBad2.measurements.twstft.code.enable = true;
cfgBad2.measurements.twstft.requireIslTiming = false;
cfgBad2.scenario.nSpaceAssets = 1;
cfgBad2.validation.unsupportedFeaturePolicy = 'disableWithWarning';
didFail2 = false;
try
    revgnss.ConfigFactory.finalizeConfig(cfgBad2);
catch ME2
    didFail2 = contains(ME2.identifier, 'insufficientAssets');
end
assert(didFail2, 'T2b FAILED: nSpaceAssets<2 did not fail');

% Guard: identical reference and remote indices must be rejected
cfgBad3 = mkCfg_(rootDir, outDir);
cfgBad3.measurements.twstft.referenceAssetIndex = 1;
cfgBad3.measurements.twstft.remoteAssetIndex = 1;
didFail3 = false;
try
    revgnss.ConfigFactory.finalizeConfig(cfgBad3);
catch ME3
    didFail3 = contains(ME3.identifier, 'identicalAssets');
end
assert(didFail3, 'T2c FAILED: identical asset indices did not fail');

% Guard: requireIslTiming with ISL timing disabled must be rejected
cfgBad4 = mkCfg_(rootDir, outDir);
cfgBad4.measurements.isl.timing.enable = false;
cfgBad4.measurements.twstft.requireIslTiming = true;
didFail4 = false;
try
    revgnss.ConfigFactory.finalizeConfig(cfgBad4);
catch ME4
    didFail4 = contains(ME4.identifier, 'islTimingRequired');
end
assert(didFail4, 'T2d FAILED: requireIslTiming without timing did not fail');

fprintf('    PASS (4 guards verified)\n');

% ----------------------------------------------------------------
% T3: Build with valid config produces a diagnostic struct
% ----------------------------------------------------------------
fprintf('  T3: TWSTFT diagnostic build ...\n');
cfg = revgnss.ConfigFactory.finalizeConfig(mkCfg_(rootDir, outDir));
[asset, ~, ekf] = revgnss.ScenarioFactory.build(cfg);
assets = revgnss.MultiAssetConfig.instantiateAssets(cfg, asset);
[~, ~, ~, ~, islInfo] = revgnss.ISLMeasurementBuilder.build( ...
    cfg, asset, assets, ekf.x, ekf.stateMap, ekf.nx, 42);
[~, ~, ~, ~, twoInfo] = revgnss.TwoWayISLMeasurementBuilder.build( ...
    cfg, asset, assets, ekf.x, ekf.stateMap, ekf.nx, 42);

td = revgnss.TWSTFTDiagnosticBuilder.build(cfg, islInfo, twoInfo);

assert(td.enabled, 'T3 FAILED: diagnostic must be enabled');
assert(~td.useInEKF, 'T3 FAILED: useInEKF must be false');
assert(td.twstftEkfRows == 0, 'T3 FAILED: no EKF rows allowed');
assert(~td.relayTransponderImplemented, 'T3 FAILED: relay must not be claimed');
assert(~td.islCarrierEkfUsed, 'T3 FAILED: ISL carrier EKF must not be claimed');
assert(strcmp(td.diagnosticClassification, 'diagnosticOnlyApproximation'), ...
    'T3 FAILED: expected diagnosticOnlyApproximation');
assert(isfinite(td.clockOffsetDiagnostic_s), 'T3 FAILED: clock offset must be finite');
assert(isfinite(td.clockOffsetDiagnostic_m), 'T3 FAILED: clock offset [m] must be finite');
assert(abs(td.clockOffsetDiagnostic_m - td.clockOffsetDiagnostic_s * 299792458) < 1e-6, ...
    'T3 FAILED: m/s consistency');

% Check observable row descriptor
assert(numel(td.rows) == 1, 'T3 FAILED: expected one descriptor row');
assert(strcmp(td.rows(1).observableType, 'twstftCodeDiagnostic'), ...
    'T3 FAILED: row type must be twstftCodeDiagnostic');
assert(strcmp(td.rows(1).role, 'diagnosticOnly'), ...
    'T3 FAILED: row role must be diagnosticOnly');
assert(isempty(td.rows(1).stateColumns), 'T3 FAILED: no EKF state columns expected');
fprintf('    PASS (clockOffset=%.4g s = %.4g m)\n', ...
    td.clockOffsetDiagnostic_s, td.clockOffsetDiagnostic_m);

% ----------------------------------------------------------------
% T4: Report contains TWSTFT section and is compliant
% ----------------------------------------------------------------
fprintf('  T4: Report TWSTFT section ...\n');
w = warning('off','all');
out = revgnss.ReportRunner.runSingle(cfg);
warning(w);
tex = fileread(out.texPath);

assert(contains(tex, 'TWSTFT Code Time-Transfer Diagnostics'), ...
    'T4 FAILED: TWSTFT section missing from report');
assert(contains(tex, 'useInEKF'), ...
    'T4 FAILED: useInEKF line missing');
assert(contains(tex, 'NO'), 'T4 FAILED: relay/carrier guard rows missing');
assert(contains(tex, 'ISL Link Timing and Clock-Transfer Diagnostics'), ...
    'T4 FAILED: Stage 23 section must still be present');

% Verify TWSTFT is not counted as physical EKF rows
assert(out.summary.twstftDiag.enabled, 'T4 FAILED: twstftDiag.enabled should be true');
assert(~out.summary.twstftDiag.useInEKF, 'T4 FAILED: useInEKF must remain false');
assert(out.summary.twstftDiag.twstftEkfRows == 0, 'T4 FAILED: twstftEkfRows must be 0');

% Verify observable stack has twstftCodeDiagnostic counted separately
c = out.summary.observableStack.rowsByType;
nTwstft = 0;
if isfield(c,'twstftCodeDiagnostic'); nTwstft = c.twstftCodeDiagnostic; end
assert(nTwstft == 1, 'T4 FAILED: expected 1 twstftCodeDiagnostic row in stack');
% Physical EKF rows must not include TWSTFT
nPhys = out.summary.totalCodeRows + out.summary.totalDopplerRows + out.summary.totalCarrierRows;
nFromStack = c.code + c.doppler;
carr = 0; if isfield(c,'carrier'); carr = c.carrier; end
nFromStack = nFromStack + carr;
assert(nPhys == nFromStack, 'T4 FAILED: TWSTFT rows leaked into physical EKF count');
fprintf('    PASS (TWSTFT enabled, twstftRows=%d, physEkfRows=%d)\n', nTwstft, nPhys);

fprintf('=== test_stage24_twstft_diagnostics: ALL PASS ===\n');

% ================================================================
% Helper: build a valid two-asset ISL+TWSTFT config
% ================================================================
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
    cfg.measurements.isl.timing.enable = true;
    cfg.measurements.isl.timing.mode = 'sameEpoch';
    cfg.measurements.isl.timing.maxIter = 3;
    cfg.measurements.isl.timing.processingDelay_s = 0.0;
    cfg.measurements.isl.clockTransferDiagnostics.enable = true;
    cfg.measurements.twstft.enable = true;
    cfg.measurements.twstft.code.enable = true;
    cfg.measurements.twstft.code.useInEKF = false;
    cfg.measurements.twstft.referenceAssetIndex = 1;
    cfg.measurements.twstft.remoteAssetIndex = 2;
    cfg.measurements.twstft.requireIslTiming = true;
    cfg.report.enable = true;
    cfg.report.writePdf = true;
    cfg.report.writeMat = false;
    cfg.report.writeTex = true;
    cfg.report.compileTex = 'never';
    cfg.report.style = 'latex';
    cfg.report.layout = 'clockExact';
    cfg.report.version = 'stage24-test';
    cfg.report.baseOutputDir = outDir;
    cfg.report.overwrite = true;
    cfg.validation.unsupportedFeaturePolicy = 'disableWithWarning';
    addpath(rootDir);
end
