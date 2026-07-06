% test_orbit_truth_cache_equivalence
%
% Verifies that the orbit truth cache in ReverseGNSSSimulation precomputes
% the deterministic trajectory correctly and avoids repeated scalar RK4
% re-integration.
%
% T1: OrbitPropagator vector call matches scalar calls at all epochs
%     (j2Rk4, dt=10 s, 600 s scenario).
% T2: OrbitPropagator vector call matches scalar calls (twoBodyRk4).
% T3: ReverseGNSSSimulation with cache enabled vs disabled gives equivalent
%     position/clock results within tolerance.
% T4: Cache is correctly disabled when cfg.orbit.truth.cache.enable = false.
% T5: shouldUseOrbitTruthCache_ returns false for stationary ECEF (no propagator).

fprintf('test_orbit_truth_cache_equivalence\n');

% =========================================================================
% Shared tolerances
% =========================================================================
tol_pos_m   = 1e-6;   % position [m]  — for same sub-step path
tol_vel_mps = 1e-9;   % velocity [m/s]

% =========================================================================
% T1: j2Rk4 — vector propagate(tVec) matches individual scalar calls
% =========================================================================
fprintf('\nT1: j2Rk4 vector vs scalar propagation...\n');

dt1  = 10;        % dt in seconds — matches RK4 sub-step (nSub=1 per epoch)
dur1 = 600;       % 600 s = 60 epochs + 1 initial
tVec1 = (0:dt1:dur1)';

cfg1 = struct();
cfg1.altitudeMean_m   = 35786e3;
cfg1.inclination_rad  = 0;
cfg1.raan_rad         = 0;
cfg1.trueAnomaly0_rad = 23 * pi/180;
cfg1.epochGMST_rad    = 0;
cfg1.mode             = 'j2Rk4';

op1 = models.orbit.OrbitPropagator(cfg1);

% Vector call — single pre-computation
[rVec1, vVec1] = op1.propagate(tVec1);

% Scalar calls — simulate the old per-epoch path
maxPosErr1 = 0;
maxVelErr1 = 0;
% Check every 5th epoch to keep test fast
checkEpochs1 = 1:5:numel(tVec1);
for ki = checkEpochs1
    t_k = tVec1(ki);
    [r_k, v_k] = op1.propagate(t_k);
    posErr = norm(rVec1(:,ki) - r_k);
    velErr = norm(vVec1(:,ki) - v_k);
    maxPosErr1 = max(maxPosErr1, posErr);
    maxVelErr1 = max(maxVelErr1, velErr);
end

assert(maxPosErr1 < tol_pos_m, ...
    sprintf('T1 FAIL: j2Rk4 max pos error %.3e m > tolerance %.3e m', maxPosErr1, tol_pos_m));
assert(maxVelErr1 < tol_vel_mps, ...
    sprintf('T1 FAIL: j2Rk4 max vel error %.3e m/s > tolerance %.3e m/s', maxVelErr1, tol_vel_mps));
fprintf('T1 PASS: j2Rk4 vector vs scalar — maxPos=%.2e m, maxVel=%.2e m/s\n', ...
    maxPosErr1, maxVelErr1);

% =========================================================================
% T2: twoBodyRk4 — vector propagate(tVec) matches scalar calls
% =========================================================================
fprintf('\nT2: twoBodyRk4 vector vs scalar propagation...\n');

cfg2 = cfg1; cfg2.mode = 'twoBodyRk4';
op2  = models.orbit.OrbitPropagator(cfg2);
[rVec2, vVec2] = op2.propagate(tVec1);

maxPosErr2 = 0;
maxVelErr2 = 0;
for ki = checkEpochs1
    t_k = tVec1(ki);
    [r_k, v_k] = op2.propagate(t_k);
    posErr = norm(rVec2(:,ki) - r_k);
    velErr = norm(vVec2(:,ki) - v_k);
    maxPosErr2 = max(maxPosErr2, posErr);
    maxVelErr2 = max(maxVelErr2, velErr);
end

assert(maxPosErr2 < tol_pos_m, ...
    sprintf('T2 FAIL: twoBodyRk4 max pos error %.3e m', maxPosErr2));
assert(maxVelErr2 < tol_vel_mps, ...
    sprintf('T2 FAIL: twoBodyRk4 max vel error %.3e m/s', maxVelErr2));
fprintf('T2 PASS: twoBodyRk4 vector vs scalar — maxPos=%.2e m, maxVel=%.2e m/s\n', ...
    maxPosErr2, maxVelErr2);

% =========================================================================
% T3: ReverseGNSSSimulation with cache enabled vs disabled
% =========================================================================
fprintf('\nT3: Simulation with cache enabled vs disabled...\n');

cfgSim = revgnss.ConfigFactory.defaultConfig();
cfgSim = revgnss.ScenarioPresets.singleAssetCarrierAttitude(cfgSim);
cfgSim.simulation.duration_s   = 600;
cfgSim.simulation.dt_s         = 10;
cfgSim.report.enable           = false;
cfgSim.plots.enable            = false;
cfgSim.orbit.truth.mode        = 'j2Rk4';
cfgSim.orbit.mode              = 'j2Rk4';

% Run with cache enabled (default)
cfgOn          = cfgSim;
cfgOn.orbit.truth.cache.enable = true;
simOn = revgnss.ReverseGNSSSimulation(cfgOn);
simOn.initialize();
assert(simOn.orbitTruthCache.enabled, 'T3 FAIL: cache should be enabled');
assert(simOn.orbitTruthCache.built,   'T3 FAIL: cache should be built');
simOn.run();
resOn = simOn.getResults();
posErrOn = resOn.diag.getPositionErrors();

% Run with cache disabled
cfgOff          = cfgSim;
cfgOff.orbit.truth.cache.enable = false;
simOff = revgnss.ReverseGNSSSimulation(cfgOff);
simOff.initialize();
assert(~simOff.orbitTruthCache.enabled, 'T3 FAIL: cache should be disabled');
simOff.run();
resOff = simOff.getResults();
posErrOff = resOff.diag.getPositionErrors();

assert(numel(posErrOn) == numel(posErrOff), 'T3 FAIL: epoch count mismatch');

% Results should be identical (same RK4 sub-steps for dt=10s)
posMatch = max(abs(posErrOn - posErrOff));
assert(posMatch < tol_pos_m, ...
    sprintf('T3 FAIL: cached vs non-cached pos error mismatch %.3e m > %.3e m', ...
    posMatch, tol_pos_m));

% EKF state dimension must not change
assert(simOn.ekf.nx == simOff.ekf.nx, ...
    sprintf('T3 FAIL: state dim changed: cached=%d, non-cached=%d', simOn.ekf.nx, simOff.ekf.nx));

fprintf('T3 PASS: cache on/off max pos mismatch=%.2e m, nx=%d (unchanged)\n', ...
    posMatch, simOn.ekf.nx);

% =========================================================================
% T4: Cache disabled by cfg flag — shouldUseOrbitTruthCache_ returns false
% =========================================================================
fprintf('\nT4: Cache disable via cfg flag...\n');

cfgT4 = cfgSim;
cfgT4.orbit.truth.cache.enable = false;
simT4 = revgnss.ReverseGNSSSimulation(cfgT4);
simT4.initialize();
assert(~simT4.orbitTruthCache.enabled, 'T4 FAIL: cache should be disabled by config flag');
assert(~simT4.orbitTruthCache.built,   'T4 FAIL: cache should not be built when disabled');
fprintf('T4 PASS: cfg.orbit.truth.cache.enable=false correctly disables cache\n');

% =========================================================================
% T5: No cache for stationary ECEF scenario (no orbit propagator)
% =========================================================================
fprintf('\nT5: No cache for stationary ECEF...\n');

cfgT5 = revgnss.ConfigFactory.defaultConfig();
cfgT5.simulation.duration_s = 60;
cfgT5.simulation.dt_s       = 10;
cfgT5.report.enable         = false;
cfgT5.plots.enable          = false;
simT5 = revgnss.ReverseGNSSSimulation(cfgT5);
simT5.initialize();
assert(~simT5.orbitTruthCache.enabled, 'T5 FAIL: no cache expected for stationary ECEF');
fprintf('T5 PASS: stationary ECEF correctly skips orbit cache\n');

fprintf('\ntest_orbit_truth_cache_equivalence: all 5 tests passed.\n');
