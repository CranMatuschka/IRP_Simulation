% test_stage26_orbit_two_body_energy  Energy conservation for two-body RK4 propagation.
%
% T1: Specific energy conserved over 1000 s of two-body RK4 at LEO (< 1 J/kg).
% T2: specificEnergy_Jkg matches analytic formula E = -mu/(2a).
% T3: J2 mode changes energy (J2 is non-conservative — no conservation expected).
% T4: OrbitPropagator 'twoBodyRk4' mode returns same ECEF radius as analytic at t=0.

fprintf('test_stage26_orbit_two_body_energy\n');

mu = revgnss.Constants.EARTH_GM_M3PS2;
Re = revgnss.Constants.EARTH_RADIUS_M;
a  = Re + 600e3;   % 600 km LEO semi-major axis

r0    = [a; 0; 0];
v0    = [0; sqrt(mu/a); 0];   % circular orbit in XY plane

E0    = models.orbit.OrbitDynamics.specificEnergy_Jkg(r0, v0);

% T2: analytic formula
E_analytic = -mu / (2*a);
assert(abs(E0 - E_analytic) < 1e-3, 'T2: specificEnergy_Jkg formula mismatch (> 1e-3 J/kg)');
fprintf('T2 PASS: specificEnergy error = %.4e J/kg\n', abs(E0 - E_analytic));

% T1: energy conservation over 1000 RK4 steps of 1 s
r = r0; v = v0;
dt = 1.0;
for k = 1:1000
    [r, v] = models.orbit.OrbitDynamics.rk4Step(r, v, dt, 'twoBody');
end
Ef = models.orbit.OrbitDynamics.specificEnergy_Jkg(r, v);
assert(abs(Ef - E0) < 1.0, ...
    sprintf('T1: Two-body energy error %.4e J/kg > 1 J/kg tolerance', abs(Ef - E0)));
fprintf('T1 PASS: two-body energy drift over 1000 s = %.4e J/kg\n', abs(Ef - E0));

% T3: J2 mode — just verify it runs and returns a different trajectory
r_j2 = r0; v_j2 = v0;
for k = 1:100
    [r_j2, v_j2] = models.orbit.OrbitDynamics.rk4Step(r_j2, v_j2, dt, 'j2');
end
r_tb = r0; v_tb = v0;
for k = 1:100
    [r_tb, v_tb] = models.orbit.OrbitDynamics.rk4Step(r_tb, v_tb, dt, 'twoBody');
end
assert(norm(r_j2 - r_tb) > 1e-3, 'T3: J2 and two-body should give different trajectories after 100 s');
fprintf('T3 PASS: J2/two-body position divergence after 100 s = %.4e m\n', norm(r_j2 - r_tb));

% T4: OrbitPropagator 'twoBodyRk4' radius at t=0 matches expected
cfg_op           = struct();
cfg_op.altitudeMean_m   = 600e3;
cfg_op.inclination_rad  = 0;
cfg_op.raan_rad         = 0;
cfg_op.trueAnomaly0_rad = 0;
cfg_op.epochGMST_rad    = 0;
cfg_op.orbit.mode       = 'twoBodyRk4';
op = revgnss.OrbitPropagator(cfg_op);
[r_t0, ~] = op.propagate(0);
assert(abs(norm(r_t0) - a) < 1.0, ...
    sprintf('T4: twoBodyRk4 radius at t=0 error %.4e m', abs(norm(r_t0) - a)));
fprintf('T4 PASS: twoBodyRk4 radius at t=0 = %.2f m (expected %.2f m)\n', norm(r_t0), a);

fprintf('\ntest_stage26_orbit_two_body_energy: all 4 tests passed.\n');
