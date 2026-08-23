% test_stage14_7_attitude_observability
%
% Stage 14.7: attitude observability diagnostics and Jacobian validation.
%
% T1: zero lever arm → attitude columns of H_pr near zero (< 1e-9).
% T2: nonzero lever arm → attitude columns of H_pr nonzero (> 1e-9).
% T3: finalizeConfig with nReceivers=3 enables attitude estimation + valid P0.
% T4: attitudeObsClass is a valid convergence-based class after smoke run (Stage 14.8 update).
% T5: smoke run attitudeJacobianNorm > 0 throughout when lever arms nonzero.

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_stage14_7_attitude_observability ===\n');

VALID_CLASSES_147 = {'CONVERGED','BOUNDED_WEAK_GEOMETRY','NON_CONVERGENT', ...
                     'AMBIGUITY_ABSORBED','CALIBRATION_FAILED','WEAKLY_OBSERVABLE', ...
                     'UNOBSERVABLE','INVALID_CONFIG','UNKNOWN'};

nTowers = 5;

% ----------------------------------------------------------------
% T1: Zero lever arm → near-zero attitude columns in H_pr
% ----------------------------------------------------------------
fprintf('  T1: zero lever arm → H attitude columns near zero ...\n');

cfg_t1 = revgnss.ConfigFactory.defaultConfig();
cfg_t1.scenario.nReceivers = 1;  % forces zero lever arm
cfg_t1.plots.enable  = false;
cfg_t1.report.enable = false;

wS1 = warning('off','all');
cfg_t1f = revgnss.ConfigFactory.finalizeConfig(cfg_t1);
warning(wS1);

leverArms1 = cfg_t1f.asset.receiverLeverArms_body_m;
assert(all(abs(leverArms1(:)) < 1e-12), 'T1 SETUP: expected zero lever arm for nReceivers=1');
assert(~cfg_t1f.estimator.estimateAttitude, 'T1 SETUP: estimateAttitude should be false for nReceivers=1');

[~, towers1, ekf1, measModel1] = revgnss.ScenarioFactory.build(cfg_t1f);
sm1 = ekf1.stateMap;
x0_1 = ekf1.x;
leverArms1m = cfg_t1f.asset.receiverLeverArms_body_m;

% Build H using CodeJacobianBuilder directly
r_est1  = x0_1(sm1.r_idx);
eul_est1 = x0_1(sm1.euler_idx);
twr_list1 = (1:nTowers)';
ant_list1 = ones(nTowers,1);
H1 = models.measurements.CodeJacobianBuilder.build(cfg_t1f, 1e-6, towers1, twr_list1, ant_list1, ...
    r_est1, eul_est1, leverArms1m, x0_1, sm1, ekf1.nx);

H_att1 = H1(:, sm1.euler_idx);
maxAbsAtt1 = max(abs(H_att1(:)));
assert(maxAbsAtt1 < 1e-9, ...
    'T1 FAILED: max |H attitude| = %.3e, expected < 1e-9 for zero lever arm', maxAbsAtt1);
fprintf('    PASS (max |H_att| = %.2e)\n', maxAbsAtt1);

% ----------------------------------------------------------------
% T2: Nonzero lever arm → nonzero attitude columns in H_pr
% ----------------------------------------------------------------
fprintf('  T2: nonzero lever arm → H attitude columns nonzero ...\n');

cfg_t2 = revgnss.ConfigFactory.defaultConfig();
cfg_t2.scenario.nReceivers = 3;  % auto-enables lever arms and attitude
cfg_t2.measurements.carrierMode    = 'ekfFloat';
cfg_t2.estimation.ambiguityMode    = 'floatPerTowerReceiverSignal';
cfg_t2.plots.enable  = false;
cfg_t2.report.enable = false;

wS2 = warning('off','all');
cfg_t2f = revgnss.ConfigFactory.finalizeConfig(cfg_t2);
warning(wS2);

leverArms2m = cfg_t2f.asset.receiverLeverArms_body_m;
assert(size(leverArms2m,2) >= 1 && norm(leverArms2m(:,1)) > 1e-9, ...
    'T2 SETUP: expected nonzero lever arm for nReceivers=3');
assert(cfg_t2f.estimator.estimateAttitude, 'T2 SETUP: estimateAttitude should be true for nReceivers=3');

[~, towers2, ekf2, ~] = revgnss.ScenarioFactory.build(cfg_t2f);
sm2 = ekf2.stateMap;
x0_2 = ekf2.x;
r_est2   = x0_2(sm2.r_idx);
eul_est2 = x0_2(sm2.euler_idx);
twr_list2 = repmat((1:nTowers)', 3, 1);
ant_list2 = [ones(nTowers,1); 2*ones(nTowers,1); 3*ones(nTowers,1)];

H2 = models.measurements.CodeJacobianBuilder.build(cfg_t2f, 1e-6, towers2, twr_list2, ant_list2, ...
    r_est2, eul_est2, leverArms2m, x0_2, sm2, ekf2.nx);

H_att2 = H2(:, sm2.euler_idx);
maxAbsAtt2 = max(abs(H_att2(:)));
assert(maxAbsAtt2 > 1e-9, ...
    'T2 FAILED: max |H attitude| = %.3e, expected > 1e-9 for nonzero lever arm', maxAbsAtt2);
fprintf('    PASS (max |H_att| = %.2e)\n', maxAbsAtt2);

% ----------------------------------------------------------------
% T3: finalizeConfig with nReceivers=3 → estimateAttitude=true, P0_euler_rad >= 5°
% ----------------------------------------------------------------
fprintf('  T3: finalizeConfig nReceivers=3 → attitude enabled, P0_euler_rad >= 5 deg ...\n');

cfg_t3 = revgnss.ConfigFactory.defaultConfig();
cfg_t3.scenario.nReceivers = 3;
cfg_t3.plots.enable  = false;
cfg_t3.report.enable = false;

wS3 = warning('off','all');
cfg_t3f = revgnss.ConfigFactory.finalizeConfig(cfg_t3);
warning(wS3);

assert(cfg_t3f.estimator.estimateAttitude, 'T3 FAILED: estimateAttitude should be true');
assert(cfg_t3f.estimator.estimateAttitudeFromPseudorange, ...
    'T3 FAILED: estimateAttitudeFromPseudorange should be true');
assert(cfg_t3f.estimator.P0_euler_rad >= deg2rad(5) - 1e-12, ...
    'T3 FAILED: P0_euler_rad = %.4f deg, expected >= 5 deg', ...
    cfg_t3f.estimator.P0_euler_rad * 180/pi);
fprintf('    PASS (estimateAttitude=true, P0_euler=%.1f deg)\n', ...
    cfg_t3f.estimator.P0_euler_rad * 180/pi);

% ----------------------------------------------------------------
% T4: smoke run → attitudeObsClass is a valid convergence-based class
% ----------------------------------------------------------------
fprintf('  T4: smoke run (30 epochs) → attitudeObsClass is a valid class ...\n');

cfg_t4 = revgnss.ConfigFactory.defaultConfig();
cfg_t4.scenario.nReceivers               = 3;
cfg_t4.simulation.duration_s             = 29;
cfg_t4.simulation.dt_s                   = 1;
cfg_t4.measurements.carrierMode          = 'ekfFloat';
cfg_t4.estimation.ambiguityMode          = 'floatPerTowerReceiverSignal';
cfg_t4.estimation.ambiguity.initialSigma_m = 100;
cfg_t4.measurements.doppler.enable       = true;
cfg_t4.measurements.doppler.useInEKF     = true;
cfg_t4.physics.doppler.truth.enable      = true;
cfg_t4.physics.doppler.model.enable      = true;
cfg_t4.measurements.carrier.slipDetection.enable = true;
cfg_t4.measurements.carrier.slipDetection.threshold_m = 0.1;
cfg_t4.measurements.carrier.slipDetection.minEpochsBeforeDetect = 3;
cfg_t4.measurements.carrier.slipDetection.action = 'resetAndSkip';
cfg_t4.report.writePdf = false;
cfg_t4.report.writeMat = false;
cfg_t4.plots.enable  = false;
cfg_t4.validation.unsupportedFeaturePolicy = 'disableWithWarning';

wS4 = warning('off','all');
threwErr4 = false;
try
    out4 = revgnss.ReportRunner.runSingle(cfg_t4);
catch ME4
    threwErr4 = true;
    fprintf('    ERROR: %s\n', ME4.message);
end
warning(wS4);

assert(~threwErr4, 'T4 FAILED: smoke run threw an error');
assert(isfield(out4.summary,'attitudeObsClass'), ...
    'T4 FAILED: summary.attitudeObsClass field missing');
cls4 = out4.summary.attitudeObsClass;
assert(~strcmp(cls4,'OBSERVABLE'), ...
    'T4 FAILED: old class ''OBSERVABLE'' must not appear (Stage 14.8 uses convergence-based classes)');
assert(ismember(cls4, VALID_CLASSES_147), ...
    'T4 FAILED: attitudeObsClass = ''%s'' not in recognised set', cls4);
fprintf('    PASS (attitudeObsClass = %s)\n', cls4);

% ----------------------------------------------------------------
% T5: smoke run attitudeJacobianNorm > 0 throughout
% ----------------------------------------------------------------
fprintf('  T5: attitudeJacobianNorm > 0 throughout smoke run ...\n');

jacNorms5 = out4.simData.getAttitudeJacobianNorm();
assert(all(jacNorms5 > 1e-9), ...
    'T5 FAILED: %d epochs with attitudeJacobianNorm <= 0', sum(jacNorms5 <= 1e-9));
fprintf('    PASS (min jac norm = %.4e, mean = %.4e)\n', min(jacNorms5), mean(jacNorms5));

fprintf('=== test_stage14_7_attitude_observability: ALL PASS ===\n');
