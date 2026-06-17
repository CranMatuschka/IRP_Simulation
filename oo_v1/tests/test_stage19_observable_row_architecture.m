% test_stage19_observable_row_architecture
%
% Stage 19: generic endpoint/link/observable row metadata around existing rows.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir, '..');
addpath(rootDir);

fprintf('=== test_stage19_observable_row_architecture ===\n');

outDir = fullfile(rootDir, 'output', 'stage19_observable_rows');
if ~exist(outDir, 'dir'); mkdir(outDir); end

% ----------------------------------------------------------------
% T1: descriptor factories are lightweight metadata structs
% ----------------------------------------------------------------
fprintf('  T1: descriptor factories ...\n');
ep = revgnss.EndpointDescriptor.tower(2);
lk = revgnss.LinkDescriptor.towerToReceiver(2, 3, 'GEO-1');
rw = revgnss.ObservableRowDescriptor.create(1, 'code', lk.id, 'L1', 2, 3, [1 2 13], 'unit-test', 'physicalEKF');
assert(strcmp(ep.id, 'tower:002'), 'T1 FAILED: endpoint id mismatch');
assert(strcmp(lk.transmitterEndpointId, 'tower:002'), 'T1 FAILED: link tx mismatch');
assert(strcmp(rw.observableType, 'code'), 'T1 FAILED: row type mismatch');
fprintf('    PASS\n');

% ----------------------------------------------------------------
% T2: short report run exposes actual endpoint/link/row stack
% ----------------------------------------------------------------
fprintf('  T2: short run observable stack ...\n');
cfg = mkCfg_(rootDir, outDir);
w = warning('off','all');
out = revgnss.ReportRunner.runSingle(cfg);
warning(w);
s = out.summary;
obs = s.observableStack;

assert(obs.nEndpoints == 8, 'T2 FAILED: endpoints=%d expected 8', obs.nEndpoints);
assert(obs.nLinks == 15, 'T2 FAILED: links=%d expected 15', obs.nLinks);
assert(ismember('tower', obs.endpointTypes), 'T2 FAILED: tower endpoint type missing');
assert(ismember('spacecraftReceiver', obs.endpointTypes), 'T2 FAILED: spacecraft receiver endpoint missing');
assert(s.totalCodeRows == 30, 'T2 FAILED: code rows=%d expected 30', s.totalCodeRows);
assert(s.totalDopplerRows == 30, 'T2 FAILED: doppler rows=%d expected actual 30', s.totalDopplerRows);
assert(s.totalCarrierRows == 15, 'T2 FAILED: carrier rows=%d expected 15', s.totalCarrierRows);
assert(s.totalDiffAttRows == 10, 'T2 FAILED: diff attitude rows=%d expected 10', s.totalDiffAttRows);
assert(out.diag.log(end).numMeasurementRows == 75, ...
    'T2 FAILED: physical H rows=%d expected 75', out.diag.log(end).numMeasurementRows);
fprintf('    PASS (endpoints=%d links=%d rows code/dop/car/diff=%d/%d/%d/%d)\n', ...
    obs.nEndpoints, obs.nLinks, s.totalCodeRows, s.totalDopplerRows, s.totalCarrierRows, s.totalDiffAttRows);

% ----------------------------------------------------------------
% T3: state columns touched by type are exposed
% ----------------------------------------------------------------
fprintf('  T3: state-column metadata ...\n');
cols = obs.stateColumnsByType;
assert(ismember(out.sim.ekf.stateMap.b_rx_idx, cols.code), ...
    'T3 FAILED: code rows missing receiver clock bias column');
assert(ismember(out.sim.ekf.stateMap.bdot_rx_idx, cols.doppler), ...
    'T3 FAILED: doppler rows missing receiver clock drift column');
assert(any(cols.carrier >= 15), 'T3 FAILED: carrier rows missing ambiguity columns');
assert(isequal(cols.diffCarrierAttitude, out.sim.ekf.stateMap.euler_idx(:)'), ...
    'T3 FAILED: differential attitude rows should touch Euler columns only');
fprintf('    PASS\n');

% ----------------------------------------------------------------
% T4: report source includes Observable Row Reality Check
% ----------------------------------------------------------------
fprintf('  T4: report section text ...\n');
tex = fileread(out.texPath);
assert(contains(tex, 'Observable Row Reality Check'), ...
    'T4 FAILED: report section missing');
assert(contains(tex, 'Code / Doppler / carrier rows & 30 / 30 / 15'), ...
    'T4 FAILED: observable row count row missing or stale');
assert(contains(tex, 'diffCarrierAttitude'), ...
    'T4 FAILED: differential attitude observable missing from table');
assert(~contains(tex, 'Carrier phase is computed but not fed into the EKF'), ...
    'T4 FAILED: stale carrier diagnostic-only contradiction present');
fprintf('    PASS\n');

fprintf('=== test_stage19_observable_row_architecture: ALL PASS ===\n');

function cfg = mkCfg_(rootDir, outDir)
    cfg = revgnss.ConfigFactory.defaultConfig();
    cfg.scenario.nReceivers = 3;
    cfg.simulation.duration_s = 20;
    cfg.simulation.dt_s = 1;
    cfg.signals.twoFrequency.enable = true;
    cfg.measurements.doppler.enable = true;
    cfg.measurements.doppler.useInEKF = true;
    cfg.physics.doppler.truth.enable = true;
    cfg.physics.doppler.model.enable = true;
    cfg.measurements.carrierPhase.enable = true;
    cfg.measurements.carrierMode = 'ekfFloat';
    cfg.measurements.carrier.sigma_m = 0.002;
    cfg.estimation.ambiguityMode = 'floatPerTowerReceiverSignal';
    cfg.estimation.ambiguity.initialSigma_m = 100;
    cfg.measurements.carrier.slipDetection.enable = true;
    cfg.measurements.carrier.slipDetection.threshold_m = 0.1;
    cfg.measurements.carrier.slipDetection.minEpochsBeforeDetect = 3;
    cfg.measurements.carrier.slipDetection.action = 'resetAndSkip';
    cfg.estimation.troposphereMode = 'none';
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
    cfg.report.version = 'stage19-test';
    cfg.report.baseOutputDir = outDir;
    cfg.report.overwrite = true;
    cfg.validation.unsupportedFeaturePolicy = 'disableWithWarning';
    addpath(rootDir);
end
