% test_stage14_8_carrier_attitude_convergence
%
% Stage 14.8: convergence-based attitude classification and carrier Jacobian.
%
% T1: nRx=1 (zero lever arm) → attitudeJacobianNorm = 0 in all EKF updates.
% T2: nRx=3, carrier EKF → attitudeJacobianNorm > 0 (carrier columns populated).
% T3: summary.attitudeImprovementRatio field present after smoke run.
% T4: summary.carrierAttJacActive = true when carrier EKF + nonzero lever arms.
% T5: attitudeObsClass is one of the convergence-based classes (not old 'OBSERVABLE').

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_stage14_8_carrier_attitude_convergence ===\n');

VALID_CLASSES = {'CONVERGED','BOUNDED_WEAK_GEOMETRY','NON_CONVERGENT', ...
                 'AMBIGUITY_ABSORBED','CALIBRATION_FAILED','WEAKLY_OBSERVABLE', ...
                 'UNOBSERVABLE','INVALID_CONFIG','UNKNOWN'};

CARRIER_BASE.measurements.carrierMode          = 'ekfFloat';
CARRIER_BASE.estimation.ambiguityMode          = 'floatPerTowerReceiverSignal';
CARRIER_BASE.estimation.ambiguity.initialSigma_m = 100;
CARRIER_BASE.measurements.doppler.enable       = true;
CARRIER_BASE.measurements.doppler.useInEKF     = true;
CARRIER_BASE.physics.doppler.truth.enable      = true;
CARRIER_BASE.physics.doppler.model.enable      = true;
CARRIER_BASE.measurements.carrier.slipDetection.enable            = true;
CARRIER_BASE.measurements.carrier.slipDetection.threshold_m       = 0.1;
CARRIER_BASE.measurements.carrier.slipDetection.minEpochsBeforeDetect = 3;
CARRIER_BASE.measurements.carrier.slipDetection.action            = 'resetAndSkip';

% ----------------------------------------------------------------
% T1: nRx=1 (zero lever arm, carrier EKF) → attitudeJacobianNorm = 0
% ----------------------------------------------------------------
fprintf('  T1: nRx=1 (zero lever arm, carrier EKF) → attitudeJacobianNorm = 0 ...\n');

cfg_t1 = revgnss.ConfigFactory.defaultConfig();
cfg_t1 = applyStruct_(cfg_t1, CARRIER_BASE);
cfg_t1.scenario.nReceivers           = 1;
cfg_t1.simulation.duration_s         = 4;
cfg_t1.simulation.dt_s               = 1;
cfg_t1.plots.enable                  = false;
cfg_t1.report.enable                 = false;
cfg_t1.validation.unsupportedFeaturePolicy = 'disableWithWarning';

wS1 = warning('off','all');
threwErr1 = false;
try
    out1 = revgnss.ReportRunner.runSingle(cfg_t1);
catch ME1
    threwErr1 = true;
    fprintf('    ERROR: %s\n', ME1.message);
end
warning(wS1);

assert(~threwErr1, 'T1 FAILED: smoke run threw an error');
jacNorms1 = [out1.diag.log.attitudeJacobianNorm];
assert(all(jacNorms1 < 1e-10), ...
    'T1 FAILED: %d of %d epochs have attitudeJacobianNorm > 0 (expected 0 for zero lever arm)', ...
    sum(jacNorms1 >= 1e-10), numel(jacNorms1));
fprintf('    PASS (max norm = %.2e over %d epochs)\n', max(jacNorms1), numel(jacNorms1));

% ----------------------------------------------------------------
% T2: nRx=3, carrier EKF → attitudeJacobianNorm > 0 (attitude Jac populated)
% ----------------------------------------------------------------
fprintf('  T2: nRx=3, carrier EKF → attitudeJacobianNorm > 0 ...\n');

cfg_t2 = revgnss.ConfigFactory.defaultConfig();
cfg_t2 = applyStruct_(cfg_t2, CARRIER_BASE);
cfg_t2.scenario.nReceivers   = 3;
cfg_t2.simulation.duration_s = 4;
cfg_t2.simulation.dt_s       = 1;
cfg_t2.plots.enable          = false;
cfg_t2.report.enable         = false;
cfg_t2.validation.unsupportedFeaturePolicy = 'disableWithWarning';

wS2 = warning('off','all');
threwErr2 = false;
try
    out2 = revgnss.ReportRunner.runSingle(cfg_t2);
catch ME2
    threwErr2 = true;
    fprintf('    ERROR: %s\n', ME2.message);
end
warning(wS2);

assert(~threwErr2, 'T2 FAILED: smoke run threw an error');
jacNorms2 = [out2.diag.log.attitudeJacobianNorm];
assert(any(jacNorms2 > 1e-9), ...
    'T2 FAILED: all attitudeJacobianNorm <= 1e-9 (expected > 0 for nRx=3 + carrier EKF)');
fprintf('    PASS (max norm = %.4e over %d epochs)\n', max(jacNorms2), numel(jacNorms2));

% ----------------------------------------------------------------
% T3: attitudeImprovementRatio field present in summary
% ----------------------------------------------------------------
fprintf('  T3: summary.attitudeImprovementRatio present after smoke run ...\n');

assert(isfield(out2.summary,'attitudeImprovementRatio'), ...
    'T3 FAILED: summary.attitudeImprovementRatio field missing');
impR3 = out2.summary.attitudeImprovementRatio;
if isnan(impR3)
    fprintf('    PASS (field present, value = NaN — too short for convergence assessment)\n');
else
    fprintf('    PASS (attitudeImprovementRatio = %.3f)\n', impR3);
end

% ----------------------------------------------------------------
% T4: carrierAttJacActive = true for carrier EKF + nonzero lever arms (nRx=3)
% ----------------------------------------------------------------
fprintf('  T4: carrierAttJacActive = true for carrier EKF + nonzero lever arms ...\n');

assert(isfield(out2.summary,'carrierAttJacActive'), ...
    'T4 FAILED: summary.carrierAttJacActive field missing');
assert(out2.summary.carrierAttJacActive, ...
    'T4 FAILED: carrierAttJacActive = false, expected true (carrier EKF + nonzero lever arms)');
fprintf('    PASS (carrierAttJacActive = true)\n');

% ----------------------------------------------------------------
% T5: attitudeObsClass is a valid convergence-based class (not 'OBSERVABLE')
% ----------------------------------------------------------------
fprintf('  T5: attitudeObsClass is a valid convergence-based class ...\n');

assert(isfield(out2.summary,'attitudeObsClass'), ...
    'T5 FAILED: summary.attitudeObsClass field missing');
cls5 = out2.summary.attitudeObsClass;
assert(~strcmp(cls5,'OBSERVABLE'), ...
    'T5 FAILED: old class ''OBSERVABLE'' must not be used; use convergence-based classes');
assert(ismember(cls5, VALID_CLASSES), ...
    'T5 FAILED: attitudeObsClass = ''%s'' not in recognised set', cls5);
fprintf('    PASS (attitudeObsClass = %s)\n', cls5);

fprintf('=== test_stage14_8_carrier_attitude_convergence: ALL PASS ===\n');

% ----------------------------------------------------------------
% Local helper: merge struct s2 fields into s1 (nested, single level)
% ----------------------------------------------------------------
function s = applyStruct_(s, s2)
    fns = fieldnames(s2);
    for i = 1:numel(fns)
        f = fns{i};
        if isstruct(s2.(f)) && isfield(s, f) && isstruct(s.(f))
            s.(f) = applyStruct_(s.(f), s2.(f));
        else
            s.(f) = s2.(f);
        end
    end
end
