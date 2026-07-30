% test_stage16_attitude_initialization
%
% Stage 16: absolute multi-antenna attitude initialization.
%
% T1: default mode is safe ('none').
% T2: truth-derived attitude initialization is rejected.
% T3: the rejection is independent of the legacy allow flag.
% T4: coarseBaselineIntegerSearch runs through quality gates and reports an
%     honest Stage 16 classification.

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_stage16_attitude_initialization ===\n');

VALID_INIT = {'ABS_ATT_CONVERGED','CALIBRATED_ABSOLUTE_REFERENCE', ...
              'CALIBRATED_TRACKING','ABS_ATT_INIT_FAILED','ABS_ATT_WEAK', ...
              'INIT_FAILED','WEAK_GEOMETRY','UNOBSERVABLE'};

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
% T2: truth-derived initialization is unavailable
% ----------------------------------------------------------------
fprintf('  T2: knownAttitudeCalibration is unavailable ...\n');
cfg2 = mkBaseCfg_(6);
cfg2.estimator.attitudeInitMode = 'knownAttitudeCalibration';
cfg2.estimator.attitudeInit.knownAttitudeCalibration.allow = false;
didThrow2 = false;
try
    revgnss.ConfigFactory.finalizeConfig(cfg2);
catch ME2
    didThrow2 = contains(ME2.identifier, ...
        'truthAttitudeInitializationUnavailable');
end
assert(didThrow2, ...
    'T2 FAILED: truth-derived attitude initialization was accepted');
fprintf('    PASS\n');

% ----------------------------------------------------------------
% T3: legacy allow flag cannot bypass the truth-input guard
% ----------------------------------------------------------------
fprintf('  T3: legacy allow flag cannot bypass the guard ...\n');
cfg3 = mkBaseCfg_(6);
cfg3.estimator.attitudeInitMode = 'knownAttitudeCalibration';
cfg3.estimator.attitudeInit.knownAttitudeCalibration.allow = true;
didThrow3 = false;
try
    revgnss.ConfigFactory.finalizeConfig(cfg3);
catch ME3
    didThrow3 = contains(ME3.identifier, ...
        'truthAttitudeInitializationUnavailable');
end
assert(didThrow3, ...
    'T3 FAILED: legacy allow flag bypassed the truth-input guard');
fprintf('    PASS\n');

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
assert(ismember(out4.sim.attInitInfo.classification, VALID_INIT), ...
    'T4 FAILED: attitudeInitClass=%s not recognised', out4.sim.attInitInfo.classification);
assert(out4.sim.attInitInfo.nCandidates > 0, ...
    'T4 FAILED: coarse search candidate count missing');
fprintf('    PASS (class=%s, candidates=%d, ratio=%.3f)\n', ...
    out4.sim.attInitInfo.classification, out4.sim.attInitInfo.nCandidates, ...
    out4.sim.attInitInfo.ratio);

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
