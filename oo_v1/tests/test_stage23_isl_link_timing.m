% test_stage23_isl_link_timing
%
% Stage 23: ISL transmit/receive event timing and clock-transfer diagnostics.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir, '..');
addpath(rootDir);

fprintf('=== test_stage23_isl_link_timing ===\n');

outDir = fullfile(rootDir, 'output', 'stage23_isl_timing');
if ~exist(outDir, 'dir'); mkdir(outDir); end

% ----------------------------------------------------------------
% T1: timing defaults are disabled/neutral
% ----------------------------------------------------------------
fprintf('  T1: timing defaults disabled ...\n');
cfg0 = revgnss.ConfigFactory.finalizeConfig(revgnss.ConfigFactory.defaultConfig());
assert(~cfg0.measurements.isl.timing.enable, 'T1 FAILED: ISL timing must default off');
assert(strcmp(cfg0.measurements.isl.timing.mode, 'sameEpoch'), 'T1 FAILED: default mode must be sameEpoch');
assert(~cfg0.measurements.isl.clockTransferDiagnostics.enable, 'T1 FAILED: clock diagnostics must default off');
fprintf('    PASS\n');

% ----------------------------------------------------------------
% T2: unsupported timing mode is guarded
% ----------------------------------------------------------------
fprintf('  T2: timing mode guard ...\n');
cfgBad = mkCfg_(rootDir, outDir);
cfgBad.measurements.isl.timing.mode = 'twstft';
didFail = false;
try
    revgnss.ConfigFactory.finalizeConfig(cfgBad);
catch ME
    didFail = contains(ME.identifier, 'ISLTimingModel:unsupportedMode');
end
assert(didFail, 'T2 FAILED: unsupported timing mode did not fail clearly');
fprintf('    PASS\n');

% ----------------------------------------------------------------
% T3: direct builders produce event metadata and report-only diagnostics
% ----------------------------------------------------------------
fprintf('  T3: direct event metadata ...\n');
cfg = revgnss.ConfigFactory.finalizeConfig(mkCfg_(rootDir, outDir));
[asset, ~, ekf] = revgnss.ScenarioFactory.build(cfg);
assets = revgnss.MultiAssetConfig.instantiateAssets(cfg, asset);
[z1, ~, ~, ~, islInfo] = revgnss.ISLMeasurementBuilder.build( ...
    cfg, asset, assets, ekf.x, ekf.stateMap, ekf.nx, 42);
[z2, ~, H2, ~, twoInfo] = revgnss.TwoWayISLMeasurementBuilder.build( ...
    cfg, asset, assets, ekf.x, ekf.stateMap, ekf.nx, 42);
assert(isempty(z1), 'T3 FAILED: one-way rows should be diagnostic-only in this config');
assert(numel(z2) == 1, 'T3 FAILED: two-way range should be the only ISL EKF row');
assert(numel(islInfo.linkEvents) == 3, 'T3 FAILED: expected one-way code/Doppler/carrier events');
assert(numel(twoInfo.linkEvents) == 2, 'T3 FAILED: expected two-way forward/return events');
assert(all([islInfo.linkEvents.lightTime_s] > 0), 'T3 FAILED: one-way light times must be positive');
assert(all([twoInfo.linkEvents.receiveTime_s] == 42), 'T3 FAILED: receive times not preserved');
assert(H2(1, ekf.stateMap.b_rx_idx) == 0, 'T3 FAILED: two-way timing diagnostics changed clock H');
clockDiag = revgnss.ISLTimingModel.summarize(cfg, islInfo, twoInfo);
assert(clockDiag.clockTransferDiagnosticAvailable, 'T3 FAILED: clock diagnostics should be available');
assert(strcmp(clockDiag.clockCancellationAssumption, 'sameEpochExactAssumption'), ...
    'T3 FAILED: sameEpoch cancellation classification wrong');
assert(clockDiag.eventCount == 5, 'T3 FAILED: expected five timing events');
fprintf('    PASS\n');

% ----------------------------------------------------------------
% T4: short report exposes Stage 23 timing section truthfully
% ----------------------------------------------------------------
fprintf('  T4: short report timing section ...\n');
w = warning('off','all');
out = revgnss.ReportRunner.runSingle(cfg);
warning(w);
tex = fileread(out.texPath);
assert(contains(tex, 'ISL Link Timing and Clock-Transfer Diagnostics'), ...
    'T4 FAILED: Stage 23 timing section missing');
assert(contains(tex, 'Is this TWSTFT? & NO'), 'T4 FAILED: TWSTFT status not explicit');
assert(contains(tex, 'Relay/transponder implemented? & NO'), 'T4 FAILED: relay status not explicit');
assert(contains(tex, 'ISL carrier EKF-used? & NO'), 'T4 FAILED: carrier EKF status not explicit');
assert(out.summary.islTiming.eventCount == 5, 'T4 FAILED: summary event count wrong');
assert(out.summary.totalIslTwoWayRangeRows == 1 && out.summary.islTwoWayRangeUsedInEkf, ...
    'T4 FAILED: Stage 22 two-way EKF row was not preserved');
fprintf('    PASS (events=%d meanLightTime=%.6g s)\n', ...
    out.summary.islTiming.eventCount, out.summary.islTiming.meanLightTime_s);

fprintf('=== test_stage23_isl_link_timing: ALL PASS ===\n');

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
    cfg.measurements.isl.timing.tolerance_s = 1e-12;
    cfg.measurements.isl.timing.processingDelay_s = 0.0;
    cfg.measurements.isl.clockTransferDiagnostics.enable = true;
    cfg.report.enable = true;
    cfg.report.writePdf = true;
    cfg.report.writeMat = false;
    cfg.report.writeTex = true;
    cfg.report.compileTex = 'never';
    cfg.report.style = 'latex';
    cfg.report.layout = 'clockExact';
    cfg.report.version = 'stage23-test';
    cfg.report.baseOutputDir = outDir;
    cfg.report.overwrite = true;
    cfg.validation.unsupportedFeaturePolicy = 'disableWithWarning';
    addpath(rootDir);
end
