% test_stage17_absolute_attitude_initialization
%
% Stage 17: independent coarse attitude initialization and differential
% carrier arc bookkeeping.

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_stage17_absolute_attitude_initialization ===\n');

VALID_ABS = {'ABS_ATT_CONVERGED','ABS_ATT_WEAK','ABS_ATT_INIT_FAILED','UNOBSERVABLE'};

% ----------------------------------------------------------------
% T1: coarse search exposes required telemetry and honest classification
% ----------------------------------------------------------------
fprintf('  T1: coarseBaselineIntegerSearch telemetry ...\n');
cfg1 = mkCfg_(20);
cfg1.estimator.attitudeInitMode = 'coarseBaselineIntegerSearch';
cfg1.estimator.attitudeInit.search.windowDeg = [2; 2; 2];
cfg1.estimator.attitudeInit.search.stepDeg = [0.5; 0.5; 0.5];
cfg1.estimator.attitudeInit.search.maxCandidates = 729;
w1 = warning('off','all');
out1 = revgnss.ReportRunner.runSingle(cfg1);
warning(w1);

assert(ismember(out1.summary.attitudeInitClass, VALID_ABS), ...
    'T1 FAILED: unexpected attitudeInitClass=%s', out1.summary.attitudeInitClass);
assert(out1.summary.attitudeInitCandidates == 729, ...
    'T1 FAILED: candidate count %.0f, expected 729', out1.summary.attitudeInitCandidates);
assert(out1.summary.attitudeInitDiffRows >= 6, ...
    'T1 FAILED: too few differential rows: %.0f', out1.summary.attitudeInitDiffRows);
assert(isfinite(out1.summary.attitudeInitBestResidual), ...
    'T1 FAILED: best residual missing');
assert(isfinite(out1.summary.attitudeInitRatio), ...
    'T1 FAILED: ratio missing');
fprintf('    PASS (class=%s, rows=%.0f, best=%.4f cyc, ratio=%.3f)\n', ...
    out1.summary.attitudeInitClass, out1.summary.attitudeInitDiffRows, ...
    out1.summary.attitudeInitBestResidual, out1.summary.attitudeInitRatio);

% ----------------------------------------------------------------
% T2: slip on one antenna invalidates only the touched baseline
% ----------------------------------------------------------------
fprintf('  T2: differential baseline invalidation for antenna slip ...\n');
cfg2 = mkCfg_(5);
store2 = revgnss.DiffAttitudeBuilder.init(cfg2, 2);
store2.calibrated = true;
store2.activeMask(:) = true;
sl2.slippedKeys = {'T001_A002_S01'};
store2 = revgnss.DiffAttitudeBuilder.handleSlips(store2, sl2);
assert(~store2.activeMask(1,1), 'T2 FAILED: tower 1 baseline 1 should be invalidated');
assert(store2.activeMask(1,2), 'T2 FAILED: tower 1 baseline 2 should remain active');
assert(store2.lostCount == 1, 'T2 FAILED: lostCount=%d expected 1', store2.lostCount);
fprintf('    PASS\n');

% ----------------------------------------------------------------
% T3: slip on reference antenna invalidates all tower baselines
% ----------------------------------------------------------------
fprintf('  T3: reference antenna slip invalidates all tower baselines ...\n');
store3 = revgnss.DiffAttitudeBuilder.init(cfg2, 2);
store3.calibrated = true;
store3.activeMask(:) = true;
sl3.slippedKeys = {'T002_A001_S01'};
store3 = revgnss.DiffAttitudeBuilder.handleSlips(store3, sl3);
assert(~any(store3.activeMask(2,:)), 'T3 FAILED: all tower 2 baselines should be invalid');
assert(store3.lostCount == 2, 'T3 FAILED: lostCount=%d expected 2', store3.lostCount);
fprintf('    PASS\n');

% ----------------------------------------------------------------
% T4: Report summary exposes arc counters during diff-attitude tracking
% ----------------------------------------------------------------
fprintf('  T4: summary exposes arc counters ...\n');
assert(isfield(out1.summary,'diffAttActiveBaselines'), 'T4 FAILED: active baseline field missing');
assert(isfield(out1.summary,'diffAttLostBaselines'), 'T4 FAILED: lost baseline field missing');
assert(isfield(out1.summary,'diffAttRecalibratedBaselines'), 'T4 FAILED: recal baseline field missing');
assert(out1.summary.diffAttActiveBaselines >= 0, 'T4 FAILED: active baseline count invalid');
fprintf('    PASS (active=%.0f lost=%.0f recal=%.0f)\n', ...
    out1.summary.diffAttActiveBaselines, out1.summary.diffAttLostBaselines, ...
    out1.summary.diffAttRecalibratedBaselines);

fprintf('=== test_stage17_absolute_attitude_initialization: ALL PASS ===\n');

function cfg = mkCfg_(dur_s)
    cfg = revgnss.ConfigFactory.defaultConfig();
    cfg.scenario.nReceivers = 3;
    cfg.simulation.duration_s = dur_s;
    cfg.simulation.dt_s = 1;
    cfg.signals.twoFrequency.enable = false;
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
    cfg.estimator.attitudeCarrierMode = 'calibratedDifferentialAmbiguity';
    cfg.estimator.diffAtt.calibWin_s = 5;
    cfg.plots.enable = false;
    cfg.report.enable = false;
    cfg.report.writePdf = false;
    cfg.report.writeMat = false;
    cfg.validation.unsupportedFeaturePolicy = 'disableWithWarning';
end
