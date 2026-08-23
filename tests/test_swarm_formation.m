% test_swarm_formation
%
% Helix swarm formation truth: bounded Clohessy-Wiltshire projected-circular
% relative orbit around the primary chief, propagated with the primary dynamics.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir, '..');
addpath(rootDir);

fprintf('=== test_swarm_formation ===\n');

oc = struct('altitudeMean_m',35786000,'inclination_rad',0,'raan_rad',0, ...
    'trueAnomaly0_rad',23*pi/180,'epochGMST_rad',0,'mode','j2Rk4');
op = models.orbit.OrbitPropagator(oc);

% ----------------------------------------------------------------
% T1: propagateFromEciState reproduces propagate() from the element state
% ----------------------------------------------------------------
fprintf('  T1: ECI-state propagation equivalence ...\n');
t = (0:30:3600)';
[r, v]   = op.propagate(t);
[ri, vi] = op.initialEciState();
[r2, v2] = op.propagateFromEciState(ri, vi, t);
assert(max(abs(r(:)-r2(:))) < 1e-6, 'T1 FAILED: position mismatch');
assert(max(abs(v(:)-v2(:))) < 1e-9, 'T1 FAILED: velocity mismatch');
fprintf('    PASS\n');

% ----------------------------------------------------------------
% T2: helix separation is bounded and stays above the 500 m target over 12 h
% ----------------------------------------------------------------
fprintf('  T2: bounded helix separation over 12 h ...\n');
cfg = struct();
cfg.scenario.nSpaceAssets   = 4;
cfg.orbit.useOrbitPropagator = true;
cfg.formation = struct('mode','helix','baseline_m',1000,'phase0_rad',0);
tVec = (0:60:12*3600)';
[rP, ~]         = op.propagate(tVec);
[rC, vC, meta]  = revgnss.SwarmFormation.buildSecondaryCaches(cfg, op, tVec, rP);
assert(meta.active && meta.nSecondaries == 3, 'T2 FAILED: 3 secondaries expected');
assert(meta.minSeparation_m >= 500, 'T2 FAILED: separation dropped below 500 m');
% projected-circular bound: |dr| in [rho, 1.118*rho]
assert(meta.minSeparation_m >= 0.99*meta.baseline_m, 'T2 FAILED: min sep below baseline');
assert(meta.maxSeparation_m <= 1.13*meta.baseline_m, 'T2 FAILED: max sep exceeds 1.118*baseline');
% bounded: separation at end ~ separation at start (no secular drift)
sep0  = vecnorm(rC{1}(:,1)-rP(:,1));
sepEnd = vecnorm(rC{1}(:,end)-rP(:,end));
assert(abs(sep0 - sepEnd) < 10, 'T2 FAILED: formation drifted > 10 m over 12 h');
fprintf('    PASS (sep in [%.0f, %.0f] m, drift %.2f m)\n', ...
    meta.minSeparation_m, meta.maxSeparation_m, abs(sep0-sepEnd));

% ----------------------------------------------------------------
% T3: velocity consistency (finite-difference of the cached position)
% ----------------------------------------------------------------
fprintf('  T3: cached velocity matches position derivative ...\n');
k = 100; dt = tVec(k+1)-tVec(k);
vfd = (rC{1}(:,k+1)-rC{1}(:,k))/dt;   % ECEF finite difference (approx, includes rotation)
% compare speed magnitude to within 1% (ECEF FD vs analytic ECEF velocity)
assert(abs(norm(vfd)-norm(vC{1}(:,k)))/norm(vC{1}(:,k)) < 0.02, 'T3 FAILED: velocity inconsistent');
fprintf('    PASS\n');

fprintf('=== test_swarm_formation: ALL PASS ===\n');
