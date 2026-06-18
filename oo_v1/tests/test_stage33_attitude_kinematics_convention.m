% test_stage33_attitude_kinematics_convention  Smoke tests for Stage 33.
%
% T1: Zero Euler -> identity DCM, validateDcm ok.
% T2: 90-deg yaw -> [1;0;0] body rotates to approx [0;1;0] reference.
% T3: Near-singular pitch -> isNearGimbalLock true.
% T4: finiteDiffLeverArmJacobian returns 3x3 finite matrix.
% T5: ReportStatus stage == '33'.

fprintf('test_stage33_attitude_kinematics_convention\n');

% --- T1: zero Euler -> identity DCM ---
C1 = revgnss.AttitudeKinematics.eulerToDcm([0; 0; 0]);
[ok1, orthErr1, detErr1] = revgnss.AttitudeKinematics.validateDcm(C1);
assert(norm(C1 - eye(3), 'fro') < 1e-12, 'T1: eulerToDcm([0;0;0]) should be identity');
assert(ok1, sprintf('T1: validateDcm failed: orthErr=%.2e, detErr=%.2e', orthErr1, detErr1));
fprintf('T1 PASS: zero Euler -> identity DCM, validateDcm ok\n');

% --- T2: 90-deg yaw -> body [1;0;0] maps to reference [0;1;0] ---
rpy2 = [0; 0; pi/2];
v_ref = revgnss.AttitudeKinematics.rotateBodyToReference(rpy2, [1; 0; 0]);
assert(norm(v_ref - [0; 1; 0]) < 1e-10, ...
    sprintf('T2: expected [0;1;0], got [%.4f;%.4f;%.4f]', v_ref(1), v_ref(2), v_ref(3)));
[ok2] = revgnss.AttitudeKinematics.validateDcm(revgnss.AttitudeKinematics.eulerToDcm(rpy2));
assert(ok2, 'T2: DCM at 90-deg yaw should be valid orthogonal matrix');
fprintf('T2 PASS: 90-deg yaw rotates [1;0;0] body to [0;1;0] reference\n');

% --- T3: near-singular pitch -> isNearGimbalLock true ---
rpy3 = [0; pi/2 - 1e-5; 0];
gm3 = revgnss.AttitudeKinematics.gimbalMetric(rpy3);
flag3 = revgnss.AttitudeKinematics.isNearGimbalLock(rpy3, 1e-3);
assert(flag3, sprintf('T3: expected near gimbal lock, gimbalMetric=%.6f', gm3));
assert(gm3 < 1e-3, sprintf('T3: gimbalMetric=%.6f should be < 1e-3', gm3));
fprintf('T3 PASS: pitch near pi/2 -> isNearGimbalLock=true, gimbalMetric=%.2e\n', gm3);

% --- T4: finiteDiffLeverArmJacobian is 3x3 and finite ---
rpy4   = [0.1; 0.2; 0.3];
lever4 = [1.0; 0.5; -0.3];
J4 = revgnss.AttitudeKinematics.finiteDiffLeverArmJacobian(rpy4, lever4);
assert(isequal(size(J4), [3, 3]), 'T4: Jacobian should be 3x3');
assert(all(isfinite(J4(:))), 'T4: Jacobian should be all-finite');
fprintf('T4 PASS: finiteDiffLeverArmJacobian is 3x3 and finite (max|J|=%.4f)\n', max(abs(J4(:))));

% --- T5: ReportStatus stage == '33' ---
rs = revgnss.ReportStatus.current();
assert(str2double(char(rs.stage)) >= 33, ...
    sprintf('T5: stage should be >= 33, got ''%s''', char(rs.stage)));
fprintf('T5 PASS: ReportStatus.current().stage = ''%s'' (>= 33)\n', char(rs.stage));

fprintf('\ntest_stage33_attitude_kinematics_convention: all 5 tests passed.\n');
