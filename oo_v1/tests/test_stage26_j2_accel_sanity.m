% test_stage26_j2_accel_sanity  Sanity checks for OrbitDynamics J2 acceleration.
%
% T1: J2 z-component is zero at equator (z=0 makes the z-term vanish exactly).
% T2: J2 acceleration is purely radial at the pole (x=y=0).
% T3: J2/two-body ratio at GEO altitude is below 1e-4 (small perturbation).
% T4: J2 acceleration at equator is in the same (inward) direction as two-body.

fprintf('test_stage26_j2_accel_sanity\n');

Re  = revgnss.Constants.EARTH_RADIUS_M;
alt = 600e3;
r_eq = Re + alt;   % equatorial radius

% T1: z-component zero at equator
r_equator = [r_eq; 0; 0];
a_j2 = revgnss.OrbitDynamics.j2Accel_mps2(r_equator);
assert(abs(a_j2(3)) < 1e-30, ...
    sprintf('T1: J2 z-accel at equator should be 0, got %.2e', a_j2(3)));
fprintf('T1 PASS: J2 z-accel at equator = %.2e m/s^2 (should be 0)\n', a_j2(3));

% T2: at pole, J2 has no x or y component
r_pole = [0; 0; r_eq];
a_j2_pole = revgnss.OrbitDynamics.j2Accel_mps2(r_pole);
assert(abs(a_j2_pole(1)) < 1e-30, ...
    sprintf('T2: J2 x-accel at pole should be 0, got %.2e', a_j2_pole(1)));
assert(abs(a_j2_pole(2)) < 1e-30, ...
    sprintf('T2: J2 y-accel at pole should be 0, got %.2e', a_j2_pole(2)));
fprintf('T2 PASS: J2 accel at pole = [%.2e  %.2e  %.4e] m/s^2 (x,y should be 0)\n', ...
    a_j2_pole(1), a_j2_pole(2), a_j2_pole(3));

% T3: J2 << two-body at GEO
r_geo = [Re + 35786e3; 0; 0];
a_tb  = revgnss.OrbitDynamics.twoBodyAccel_mps2(r_geo);
a_j2_geo = revgnss.OrbitDynamics.j2Accel_mps2(r_geo);
ratio = norm(a_j2_geo) / norm(a_tb);
assert(ratio < 1e-4, ...
    sprintf('T3: J2/two-body ratio at GEO = %.2e (should be < 1e-4)', ratio));
fprintf('T3 PASS: J2/two-body ratio at GEO = %.4e\n', ratio);

% T4: J2 inward pull at equator aligns with two-body (same sign)
a_tb_eq = revgnss.OrbitDynamics.twoBodyAccel_mps2(r_equator);
assert(sign(a_j2(1)) == sign(a_tb_eq(1)), ...
    'T4: J2 and two-body should both pull inward at equator');
fprintf('T4 PASS: J2 inward (%.4e) and two-body (%.4e) same sign at equator\n', ...
    a_j2(1), a_tb_eq(1));

fprintf('\ntest_stage26_j2_accel_sanity: all 4 tests passed.\n');
