% test_stage18_attitude_candidate_confidence
%
% Stage 18: independent attitude candidate extraction and confidence mapping.

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_stage18_attitude_candidate_confidence ===\n');

VALID_CONF = {'ACCEPTED_ABS_ATTITUDE','WEAK_ATTITUDE_DETECTED', ...
              'AMBIGUOUS_ATTITUDE','NO_ATTITUDE_INFORMATION', ...
              'INVALID_GEOMETRY','VALIDATION_ONLY'};

% ----------------------------------------------------------------
% T1: coarse search reports candidate and confidence fields
% ----------------------------------------------------------------
fprintf('  T1: candidate confidence telemetry ...\n');
cfg1 = mkCfg_(20);
cfg1.estimator.attitudeInitMode = 'coarseBaselineIntegerSearch';
cfg1.estimator.attitudeInit.search.windowDeg = [2; 2; 2];
cfg1.estimator.attitudeInit.search.stepDeg = [0.5; 0.5; 0.5];
cfg1.estimator.attitudeInit.search.maxCandidates = 729;
cfg1.estimator.attitudeInit.search.ambiguousRatioThreshold = 1.01;
cfg1.estimator.attitudeInit.search.improvementRatioThreshold = 1.05;

w1 = warning('off','all');
out1 = revgnss.ReportRunner.runSingle(cfg1);
warning(w1);
s1 = out1.sim.attInitInfo;

assert(ismember(s1.confidenceClass, VALID_CONF), ...
    'T1 FAILED: unknown confidence class %s', s1.confidenceClass);
assert(all(isfinite(s1.bestCandidateEuler_deg)), ...
    'T1 FAILED: best candidate Euler missing');
assert(all(isfinite(s1.secondCandidateEuler_deg)), ...
    'T1 FAILED: second candidate Euler missing');
assert(isfinite(s1.candidateAttitudeError_deg), ...
    'T1 FAILED: candidate truth error missing');
assert(isfinite(s1.candidateImprovementRatio), ...
    'T1 FAILED: improvement ratio missing');
assert(numel(s1.topResidualCycles) >= 2, ...
    'T1 FAILED: residual surface top candidates missing');
assert(size(s1.topCandidateEuler_deg, 1) == 3, ...
    'T1 FAILED: top Euler candidate matrix has wrong shape');
fprintf('    PASS (confidence=%s, ratio=%.3f, candErr=%.3f deg, imp=%.3f)\n', ...
    s1.confidenceClass, s1.ratio, ...
    s1.candidateAttitudeError_deg, s1.candidateImprovementRatio);

% ----------------------------------------------------------------
% T2: weak/rejected candidate is not injected into main EKF
% ----------------------------------------------------------------
fprintf('  T2: rejected candidates are diagnostic-only ...\n');
if ~strcmp(s1.confidenceClass, 'ACCEPTED_ABS_ATTITUDE')
    assert(~s1.acceptedByEkf, ...
        'T2 FAILED: rejected/weak candidate must not be accepted by EKF');
else
    assert(s1.acceptedByEkf, ...
        'T2 FAILED: accepted confidence class should inject EKF initialization');
end
fprintf('    PASS (acceptedByEkf=%d)\n', s1.acceptedByEkf);

% ----------------------------------------------------------------
% T3: weak improvement maps to WEAK_ATTITUDE_DETECTED when ratio gate fails
% ----------------------------------------------------------------
fprintf('  T3: confidence decision is consistent with gates ...\n');
if s1.candidateImprovementRatio >= 1.05 && s1.ratio < 1.20
    assert(ismember(s1.confidenceClass, ...
        {'WEAK_ATTITUDE_DETECTED','AMBIGUOUS_ATTITUDE'}), ...
        'T3 FAILED: improved but rejected candidate should be weak or ambiguous');
end
assert(~isempty(s1.decisionReason), ...
    'T3 FAILED: decision reason missing');
fprintf('    PASS (%s)\n', s1.decisionReason);

% ----------------------------------------------------------------
% T4: shadow mode remains disabled by default
% ----------------------------------------------------------------
fprintf('  T4: shadow mode default is disabled ...\n');
assert(strcmp(s1.shadowMode, 'DISABLED'), ...
    'T4 FAILED: default shadow mode should be DISABLED');
fprintf('    PASS\n');

fprintf('=== test_stage18_attitude_candidate_confidence: ALL PASS ===\n');

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
