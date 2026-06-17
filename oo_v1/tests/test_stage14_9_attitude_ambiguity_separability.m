% test_stage14_9_attitude_ambiguity_separability
%
% Stage 14.9: attitude-ambiguity separability and known-ambiguity validation.
%
% T1: float EKF (nRx=3) → attitudeSeparable=false in all diag epochs.
%     Proves H_amb spans R^M ⟹ H_att not separable from free float ambiguities.
% T2: known-ambiguity validation (nRx=3, 120 s) → attitudeImprovementRatio > 1.
%     Proves Jacobian/frame correct; float absorption is the sole blocker.
% T3: nRx=1 (zero lever arm) → attitudeSeparable=false, class=UNOBSERVABLE.
% T4: summary.knownAmbClass present when runKnownAmbiguityValidation=true.
% T5: float EKF class = AMBIGUITY_ABSORBED (upgraded from NON_CONVERGENT).

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_stage14_9_attitude_ambiguity_separability ===\n');

VALID_KAV = {'CONVERGED_VAL','IMPROVED_VAL','NON_CONVERGENT_VAL','SKIPPED'};

% ----------------------------------------------------------------
% T1: float EKF (nRx=3) → attitudeSeparable = false in all epochs
% ----------------------------------------------------------------
fprintf('  T1: float EKF nRx=3 → attitudeSeparable=false in all epochs ...\n');

wS1 = warning('off','all');
cfg_t1 = mkCfg_(3, 9);
threwErr1 = false;
try
    out1 = revgnss.ReportRunner.runSingle(cfg_t1);
catch ME1
    threwErr1 = true; fprintf('    ERROR: %s\n', ME1.message);
end
warning(wS1);
assert(~threwErr1, 'T1 FAILED: smoke run threw an error');

sepVec1  = logical([out1.diag.log.attitudeSeparable]);
corrVec1 = double([out1.diag.log.attitudeAmbCorrMaxAbs]);
assert(~any(sepVec1), ...
    'T1 FAILED: attitudeSeparable=true in %d epoch(s); expected false for free float EKF', ...
    sum(sepVec1));
fprintf('    PASS (attitudeSeparable=false in all %d epochs, max|cos|=%.4f)\n', ...
    numel(sepVec1), max(corrVec1(isfinite(corrVec1))));

% ----------------------------------------------------------------
% T2: known-ambiguity validation (120 s) → improvement ratio > 1
% ----------------------------------------------------------------
fprintf('  T2: known-ambiguity validation (120 s) → attitudeImprovementRatio > 1 ...\n');

wS2 = warning('off','all');
cfg_t2 = mkCfg_(3, 120);
cfg_t2.estimator.knownAmbiguityAttitudeValidation = true;
threwErr2 = false;
try
    out2 = revgnss.ReportRunner.runSingle(cfg_t2);
catch ME2
    threwErr2 = true; fprintf('    ERROR: %s\n', ME2.message);
end
warning(wS2);
assert(~threwErr2, 'T2 FAILED: KAV run threw an error');

impR2 = out2.summary.attitudeImprovementRatio;
assert(~isnan(impR2), 'T2 FAILED: attitudeImprovementRatio = NaN after 120 s KAV run');
assert(impR2 > 1.0, ...
    'T2 FAILED: attitudeImprovementRatio=%.3f (expected >1 — attitude should improve with known ambiguities)', ...
    impR2);
fprintf('    PASS (ratio=%.3f, init=%.2f deg, final=%.2f deg)\n', ...
    impR2, out2.summary.initialAttitudeError_deg, out2.summary.finalAttitudeError_deg);

% ----------------------------------------------------------------
% T3: nRx=1 (zero lever arm) → attitudeSeparable=false, class=UNOBSERVABLE
% ----------------------------------------------------------------
fprintf('  T3: nRx=1 (zero lever arm) → attitudeSeparable=false, UNOBSERVABLE ...\n');

wS3 = warning('off','all');
cfg_t3 = mkCfg_(1, 4);
threwErr3 = false;
try
    out3 = revgnss.ReportRunner.runSingle(cfg_t3);
catch ME3
    threwErr3 = true; fprintf('    ERROR: %s\n', ME3.message);
end
warning(wS3);
assert(~threwErr3, 'T3 FAILED: smoke run threw an error');

sepVec3 = logical([out3.diag.log.attitudeSeparable]);
assert(~any(sepVec3), 'T3 FAILED: attitudeSeparable=true for nRx=1 (zero lever arm)');
cls3 = out3.summary.attitudeObsClass;
assert(strcmp(cls3,'UNOBSERVABLE'), ...
    'T3 FAILED: class=''%s'', expected ''UNOBSERVABLE''', cls3);
fprintf('    PASS (attitudeSeparable=false, class=%s)\n', cls3);

% ----------------------------------------------------------------
% T4: summary.knownAmbClass present when runKnownAmbiguityValidation=true
% ----------------------------------------------------------------
fprintf('  T4: runKnownAmbiguityValidation=true → knownAmbClass in summary ...\n');

wS4 = warning('off','all');
cfg_t4 = mkCfg_(3, 9);
cfg_t4.estimator.runKnownAmbiguityValidation = true;
threwErr4 = false;
try
    out4 = revgnss.ReportRunner.runSingle(cfg_t4);
catch ME4
    threwErr4 = true; fprintf('    ERROR: %s\n', ME4.message);
end
warning(wS4);
assert(~threwErr4, 'T4 FAILED: smoke run threw an error');

assert(isfield(out4.summary,'knownAmbClass'), 'T4 FAILED: knownAmbClass field missing');
assert(ismember(out4.summary.knownAmbClass, VALID_KAV), ...
    'T4 FAILED: knownAmbClass=''%s'' not recognised', out4.summary.knownAmbClass);
fprintf('    PASS (knownAmbClass=%s, ratio=%.3f)\n', ...
    out4.summary.knownAmbClass, out4.summary.knownAmbImprovementRatio);

% ----------------------------------------------------------------
% T5: float EKF class = AMBIGUITY_ABSORBED (upgraded from NON_CONVERGENT)
% ----------------------------------------------------------------
fprintf('  T5: float EKF class = AMBIGUITY_ABSORBED ...\n');

cls1 = out1.summary.attitudeObsClass;
assert(~strcmp(cls1,'OBSERVABLE'), 'T5 FAILED: old class ''OBSERVABLE'' must not appear');
assert(~strcmp(cls1,'NON_CONVERGENT'), ...
    'T5 FAILED: NON_CONVERGENT should be upgraded to AMBIGUITY_ABSORBED when !separable');
assert(strcmp(cls1,'AMBIGUITY_ABSORBED'), ...
    'T5 FAILED: class=''%s'', expected ''AMBIGUITY_ABSORBED''', cls1);
fprintf('    PASS (attitudeObsClass=%s)\n', cls1);

fprintf('=== test_stage14_9_attitude_ambiguity_separability: ALL PASS ===\n');

% ----------------------------------------------------------------
% Local helper: build base carrier EKF config
% ----------------------------------------------------------------
function cfg = mkCfg_(nRx, dur)
    cfg = revgnss.ConfigFactory.defaultConfig();
    cfg.scenario.nReceivers                             = nRx;
    cfg.simulation.duration_s                           = dur;
    cfg.simulation.dt_s                                 = 1;
    cfg.measurements.carrierMode                        = 'ekfFloat';
    cfg.estimation.ambiguityMode                        = 'floatPerTowerReceiverSignal';
    cfg.estimation.ambiguity.initialSigma_m             = 100;
    cfg.measurements.doppler.enable                     = true;
    cfg.measurements.doppler.useInEKF                   = true;
    cfg.physics.doppler.truth.enable                    = true;
    cfg.physics.doppler.model.enable                    = true;
    cfg.measurements.carrier.slipDetection.enable       = true;
    cfg.measurements.carrier.slipDetection.threshold_m  = 0.1;
    cfg.measurements.carrier.slipDetection.minEpochsBeforeDetect = 3;
    cfg.measurements.carrier.slipDetection.action       = 'resetAndSkip';
    cfg.plots.enable                                    = false;
    cfg.report.enable                                   = false;
    cfg.report.writePdf                                 = false;
    cfg.report.writeMat                                 = false;
    cfg.validation.unsupportedFeaturePolicy             = 'disableWithWarning';
end
