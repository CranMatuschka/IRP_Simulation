% test_stage16_attitude_initialization
%
% Stage 16: absolute multi-antenna attitude initialization.
%
% T1: default mode is safe ('none').
% T2: knownAttitudeCalibration requires an explicit known-attitude declaration.
% T3: knownAttitudeCalibration seeds the EKF as CALIBRATED_ABSOLUTE_REFERENCE.
% T4: coarseBaselineIntegerSearch runs through quality gates and reports an
%     honest Stage 16 classification.

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_stage16_attitude_initialization ===\n');

VALID_INIT = {'ABS_ATT_CONVERGED','CALIBRATED_ABSOLUTE_REFERENCE', ...
              'CALIBRATED_TRACKING','INIT_FAILED','WEAK_GEOMETRY','UNOBSERVABLE'};

% ----------------------------------------------------------------
% T1: default mode is safe
% ----------------------------------------------------------------
fprintf('  T1: default attitudeInitMode is none ...\n');
cfg1 = revgnss.ConfigFactory.defaultConfig();
assert(isfield(cfg1.estimator,'attitudeInitMode'), ...
    'T1 FAILED: attitudeInitMode missing from default config');
assert(strcmp(cfg1.estimator.attitudeInitMode,'none'), ...
    'T1 FAILED: default attitudeInitMode=%s, expected none', cfg1.estimator.attitudeInitMode);
fprintf('    PASS\n');

% ----------------------------------------------------------------
% T2: knownAttitudeCalibration requires explicit declaration
% ----------------------------------------------------------------
fprintf('  T2: knownAttitudeCalibration guard requires allow=true ...\n');
cfg2 = mkBaseCfg_(6);
cfg2.estimator.attitudeInitMode = 'knownAttitudeCalibration';
cfg2.estimator.attitudeInit.knownAttitudeCalibration.allow = false;
didThrow2 = false;
try
    revgnss.ConfigFactory.finalizeConfig(cfg2);
catch ME2
    didThrow2 = contains(ME2.identifier, 'knownAttitudeNotDeclared');
end
assert(didThrow2, 'T2 FAILED: missing known-attitude declaration did not throw expected guard');
fprintf('    PASS\n');

% ----------------------------------------------------------------
% T3: knownAttitudeCalibration seeds EKF and is reported explicitly
% ----------------------------------------------------------------
fprintf('  T3: knownAttitudeCalibration smoke run ...\n');
cfg3 = mkBaseCfg_(20);
cfg3.estimator.attitudeCarrierMode = 'calibratedDifferentialAmbiguity';
cfg3.estimator.diffAtt.calibWin_s = 4;
cfg3.estimator.attitudeInitMode = 'knownAttitudeCalibration';
cfg3.estimator.attitudeInit.knownAttitudeCalibration.allow = true;
cfg3.estimator.attitudeInit.knownAttitudeCalibration.sigmaDeg = 0.1;
w3 = warning('off','all');
out3 = revgnss.ReportRunner.runSingle(cfg3);
warning(w3);
assert(strcmp(out3.summary.attitudeInitClass, 'CALIBRATED_ABSOLUTE_REFERENCE'), ...
    'T3 FAILED: attitudeInitClass=%s', out3.summary.attitudeInitClass);
assert(out3.summary.finalAttitudeError_deg < 1.0, ...
    'T3 FAILED: final attitude error %.3f deg too large for known reference', ...
    out3.summary.finalAttitudeError_deg);
fprintf('    PASS (class=%s, final attitude error=%.4f deg)\n', ...
    out3.summary.attitudeInitClass, out3.summary.finalAttitudeError_deg);

% ----------------------------------------------------------------
% T4: coarse search reports a valid scientific classification
% ----------------------------------------------------------------
fprintf('  T4: coarseBaselineIntegerSearch smoke classification ...\n');
cfg4 = mkBaseCfg_(5);
cfg4.estimator.attitudeInitMode = 'coarseBaselineIntegerSearch';
cfg4.estimator.attitudeInit.search.windowDeg = [1; 1; 1];
cfg4.estimator.attitudeInit.search.stepDeg = [1; 1; 1];
cfg4.estimator.attitudeInit.search.maxCandidates = 27;
w4 = warning('off','all');
out4 = revgnss.ReportRunner.runSingle(cfg4);
warning(w4);
assert(ismember(out4.summary.attitudeInitClass, VALID_INIT), ...
    'T4 FAILED: attitudeInitClass=%s not recognised', out4.summary.attitudeInitClass);
assert(out4.summary.attitudeInitCandidates > 0, ...
    'T4 FAILED: coarse search candidate count missing');
fprintf('    PASS (class=%s, candidates=%d, ratio=%.3f)\n', ...
    out4.summary.attitudeInitClass, out4.summary.attitudeInitCandidates, ...
    out4.summary.attitudeInitRatio);

fprintf('=== test_stage16_attitude_initialization: ALL PASS ===\n');

function cfg = mkBaseCfg_(dur_s)
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
    cfg.plots.enable = false;
    cfg.report.enable = false;
    cfg.report.writePdf = false;
    cfg.report.writeMat = false;
    cfg.validation.unsupportedFeaturePolicy = 'disableWithWarning';
end
