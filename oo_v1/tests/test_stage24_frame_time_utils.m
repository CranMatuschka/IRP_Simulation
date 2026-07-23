% test_stage24_frame_time_utils
%
% Stage 24: FrameTimeUtils unit validation.
% Verifies Earth-rotation, round-trip ECEF/inertial, Sagnac sign/scale.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir, '..');
addpath(rootDir);

fprintf('=== test_stage24_frame_time_utils ===\n');

% WP-12a: expected constants sourced from revgnss.Constants, the single source
% FrameTimeUtils now routes through (value unchanged; keeps the test in sync).
OMEGA = revgnss.Constants.EARTH_OMEGA_RADPS;   % expected WGS-84 rotation rate
C     = revgnss.Constants.SPEED_OF_LIGHT_MPS;
assert(models.frames.FrameTimeUtils.earthRotationRate_radps() == OMEGA, ...
    'FrameTimeUtils.earthRotationRate_radps must equal revgnss.Constants.EARTH_OMEGA_RADPS (WP-12a).');

% ----------------------------------------------------------------
% T1: earthRotationAngle at t=0 is zero; increases with time
% ----------------------------------------------------------------
fprintf('  T1: earthRotationAngle ...\n');
assert(models.frames.FrameTimeUtils.earthRotationAngle(0) == 0, ...
    'T1 FAILED: angle at t=0 must be 0');
theta10 = models.frames.FrameTimeUtils.earthRotationAngle(10);
assert(abs(theta10 - OMEGA * 10) < 1e-15, ...
    'T1 FAILED: angle at t=10 s must equal OMEGA*10');
fprintf('    PASS (theta_10 = %.6e rad)\n', theta10);

% ----------------------------------------------------------------
% T2: ecefToInertial + inertialToEcef round-trip
% ----------------------------------------------------------------
fprintf('  T2: ecefToInertial / inertialToEcef round-trip ...\n');
r_ecef = [6378000; 0; 0];
t_s    = 3600;
r_i    = models.frames.FrameTimeUtils.ecefToInertial(r_ecef, t_s);
r_back = models.frames.FrameTimeUtils.inertialToEcef(r_i, t_s);
assert(norm(r_back - r_ecef) < 1e-8, ...
    'T2 FAILED: round-trip error exceeds 1e-8 m');
% Rotation should change the x-y components, not z
assert(abs(r_i(3) - r_ecef(3)) < 1e-10, ...
    'T2 FAILED: z component should be unchanged');
fprintf('    PASS (round-trip error = %.2e m)\n', norm(r_back - r_ecef));

% ----------------------------------------------------------------
% T3: rotateEcefDuringLightTime is identity at tau=0
% ----------------------------------------------------------------
fprintf('  T3: rotateEcefDuringLightTime ...\n');
r_test = [1e7; 2e7; 3e7];
r_rot0 = models.frames.FrameTimeUtils.rotateEcefDuringLightTime(r_test, 0);
assert(norm(r_rot0 - r_test) < 1e-8, ...
    'T3 FAILED: tau=0 must return identity');
% GEO light time ~0.12 s; rotation should be small but non-zero
tau_geo = 0.12;
r_rot_geo = models.frames.FrameTimeUtils.rotateEcefDuringLightTime(r_test, tau_geo);
delta_rot = norm(r_rot_geo - r_test);
assert(delta_rot > 0 && delta_rot < 1e4, ...
    'T3 FAILED: light-time rotation should be small but non-zero');
fprintf('    PASS (rot at tau=0.12s: delta=%.3f m)\n', delta_rot);

% ----------------------------------------------------------------
% T4: sagnacCorrection_m sign and scale
% ----------------------------------------------------------------
fprintf('  T4: sagnacCorrection_m ...\n');
% GEO satellite above equator vs ground tower
rx_gnd  = [6378000; 0; 0];        % receiver on ground, along +x
tx_geo  = [0; 42164000; 0];       % transmitter at GEO, along +y

dRho_A = models.frames.FrameTimeUtils.sagnacCorrection_m(rx_gnd, tx_geo);
dRho_B = models.frames.FrameTimeUtils.sagnacCorrection_m(tx_geo, rx_gnd);

% Sagnac must be antisymmetric when rx and tx are swapped
assert(abs(dRho_A + dRho_B) < 1e-6, ...
    'T4 FAILED: Sagnac must be antisymmetric');
% Value should be in the 10-50 m range for GEO geometry
assert(abs(dRho_A) > 1 && abs(dRho_A) < 500, ...
    sprintf('T4 FAILED: Sagnac out of expected range: %.2f m', dRho_A));
% Check formula: (Omega × r_tx) · (r_rx - r_tx) / C
omega_cross_tx = OMEGA * [-tx_geo(2); tx_geo(1); 0];
expected = dot(omega_cross_tx, rx_gnd - tx_geo) / C;
assert(abs(dRho_A - expected) < 1e-10, ...
    'T4 FAILED: formula mismatch');
fprintf('    PASS (sagnac A->B = %.4f m)\n', dRho_A);

% ----------------------------------------------------------------
% T5: rotMatEcefToInertial is orthogonal (det=1, R'*R=I)
% ----------------------------------------------------------------
fprintf('  T5: rotMatEcefToInertial orthogonality ...\n');
R = models.frames.FrameTimeUtils.rotMatEcefToInertial(7200);
assert(abs(det(R) - 1) < 1e-14, 'T5 FAILED: det(R) must be 1');
assert(norm(R' * R - eye(3)) < 1e-13, 'T5 FAILED: R must be orthogonal');
fprintf('    PASS\n');

fprintf('=== test_stage24_frame_time_utils: ALL PASS ===\n');
