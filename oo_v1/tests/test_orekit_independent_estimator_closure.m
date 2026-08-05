% test_orekit_independent_estimator_closure
%
% LEVEL B -- closing the loop: an INDEPENDENT, externally developed estimator is given
% nothing but the simulator's own observables and must recover the simulator's own truth
% trajectory.
%
% Every other cross-validation in this repository compares a sim quantity against an
% Orekit quantity. This one is different in kind: Orekit is handed the sim's pseudoranges
% as raw numbers, told nothing about how they were produced, and asked to solve for the
% orbit with ITS OWN measurement model, ITS OWN force model, ITS OWN light-time solver and
% ITS OWN least-squares engine. If any term in the sim's observable chain carried a wrong
% sign, a double count, or a wrong scale, that error would be inconsistent with a real
% orbit and Orekit would either fail to converge or converge somewhere other than truth.
%
% THE GEOMETRY PROBLEM, AND WHY THIS WORKS WITHOUT CUSTOM JAVA: reverse GNSS is an UPLINK
% (ground transmits, spacecraft receives). Orekit's ground-station Range class is a
% downlink/two-way observable, and at GEO the convention difference is ~370 m, far too
% large to ignore. The sim's own two-way product is no help either -- it is a
% range-CANCELLED time-transfer observable and carries no orbit information at all. The
% resolution is org.orekit.estimation.measurements.gnss.OneWayGNSSRange, whose geometry is
% exactly remote-emitter -> local-receiver. The "remote emitter" only has to be a
% PVCoordinatesProvider, so each ground tower is supplied as an Orekit Ephemeris of its
% own inertial states (interpolation error ~2e-9 m, verified below).
%
%   PART B1 -- measurement-level closure: an Orekit OneWayGNSSRange, carrying Orekit's
%     ShapiroOneWayGNSSRangeModifier, is evaluated on the sim's truth state and compared
%     against the sim's z. Unlike the Level A test, OREKIT does the composing here.
%
%   PART B2 -- orbit-determination closure: a BatchLSEstimator (Levenberg-Marquardt over
%     a numerically propagated J2 orbit) is started from a deliberately WRONG initial
%     state and fed only the sim's pseudoranges. It must converge back onto the sim's
%     truth trajectory. Run twice, from a 500 m and from a 50 km initial error, to show
%     the answer is the estimator's own convergence rather than a retained initial guess.
%
% REQUIREMENTS / SKIP: JVM-enabled MATLAB (`matlab -batch`, not the -nojvm MCP session)
% + the Orekit bridge at ~/orekit-bridge. Skips cleanly if absent.

fprintf('test_orekit_independent_estimator_closure\n');

% ---------------------------------------------------------------------------
% Bridge locations + skip guards
% ---------------------------------------------------------------------------
libDir  = fullfile(getenv('HOME'), 'orekit-bridge', 'lib');
dataDir = fullfile(getenv('HOME'), 'orekit-bridge', 'data', 'orekit-data-main');
if ~usejava('jvm')
    fprintf('SKIP: no JVM. Run via `matlab -batch` rather than a -nojvm session.\n'); return
end
if ~isfolder(libDir) || isempty(dir(fullfile(libDir, '*.jar'))) || ~isfolder(dataDir)
    fprintf('SKIP: Orekit bridge not installed.\n      jars: %s\n      data: %s\n', libDir, dataDir); return
end

here      = fileparts(mfilename('fullpath'));
oo_v1Root = fileparts(here);
addpath(oo_v1Root);
addpath(fullfile(oo_v1Root, 'config'));
addpath(fullfile(oo_v1Root, 'config', 'internal'));

jars = dir(fullfile(libDir, '*.jar'));
for k = 1:numel(jars); javaaddpath(fullfile(libDir, jars(k).name)); end
dpm = org.orekit.data.DataContext.getDefault().getDataProvidersManager();
dpm.addProvider(org.orekit.data.DirectoryCrawler(java.io.File(dataDir)));

frame = org.orekit.frames.FramesFactory.getGCRF();
epoch = org.orekit.time.AbsoluteDate.J2000_EPOCH;
V3    = @(v) org.hipparchus.geometry.euclidean.threed.Vector3D(v(1), v(2), v(3));

c   = revgnss.Constants.SPEED_OF_LIGHT_MPS;
mu  = revgnss.Constants.EARTH_GM_M3PS2;
rEq = revgnss.Constants.EARTH_RADIUS_M;
J2  = revgnss.Constants.EARTH_J2;

% ---------------------------------------------------------------------------
% Generate the observation arc from the real pipeline, everything off.
% ---------------------------------------------------------------------------
cfg = resolveSimulationConfig('ideal_G5S1R4_ts3600_flat.json');
cfg.scenario.nTowers    = 5;
cfg.scenario.nReceivers = 1;
cfg.plots.enable  = false;
cfg.report.enable = false;
cfg = revgnss.ConfigFactory.finalizeConfig(cfg);

[asset, towers, ekf, mm, ~, orbitProp] = revgnss.ScenarioFactory.build(cfg);
nT = numel(towers);

tGrid = 0:60:1800;                      % 31 epochs over half an hour
obs   = struct('t', {}, 'tower', {}, 'z', {}, 'rSatEci', {}, 'vSatEci', {});
truthEci = zeros(6, numel(tGrid));
for kk = 1:numel(tGrid)
    t_s = tGrid(kk);
    [r_ecef, v_ecef] = orbitProp.propagate(t_s);
    asset.setTruthFromOrbit(r_ecef, v_ecef);
    [z, ~, ~, ~, es] = mm.computeMeasurements(asset, towers, ekf.x, t_s, ekf.stateMap);

    [r_i, v_i] = models.frames.FrameTimeUtils.ecefStateToInertial(r_ecef, v_ecef, t_s);
    truthEci(:, kk) = [r_i(:); v_i(:)];

    % Keep the FIRST code signal block only: one row per (tower, epoch).
    for mi = 1:nT
        obs(end+1) = struct('t', t_s, 'tower', es.towerIdx_perMeas(mi), ...
            'z', z(mi), 'rSatEci', r_i(:), 'vSatEci', v_i(:)); %#ok<SAGROW>
    end
end
fprintf('\nObservation arc: %d epochs x %d towers = %d pseudoranges over %g s\n', ...
    numel(tGrid), nT, numel(obs), tGrid(end));

% ---------------------------------------------------------------------------
% Each tower as an Orekit PVCoordinatesProvider (inertial Ephemeris of its own states).
% ---------------------------------------------------------------------------
tEph = (tGrid(1)-600) : 20 : (tGrid(end)+600);
towerEph = cell(nT,1); ephErrMax = 0;
for ti = 1:nT
    r_ecef_t = towers{ti}.getAntennaPositionECEF();
    lst = java.util.ArrayList();
    for t = tEph
        [rI, vI] = models.frames.FrameTimeUtils.ecefStateToInertial(r_ecef_t, zeros(3,1), t);
        aI = -(revgnss.Constants.EARTH_OMEGA_RADPS^2) * [rI(1); rI(2); 0];  % centripetal
        d  = epoch.shiftedBy(t);
        pv = org.orekit.utils.TimeStampedPVCoordinates(d, V3(rI), V3(vI), V3(aI));
        lst.add(org.orekit.propagation.SpacecraftState( ...
            org.orekit.utils.AbsolutePVCoordinates(frame, pv)));
    end
    towerEph{ti} = org.orekit.propagation.analytical.Ephemeris(lst, 6);
    % Verify the interpolant against the sim's own frame utility at off-node times.
    for t = tGrid(1)+[7.3 133.7 921.1]
        pvq = towerEph{ti}.getPVCoordinates(epoch.shiftedBy(t), frame);
        p = [pvq.getPosition().getX(); pvq.getPosition().getY(); pvq.getPosition().getZ()];
        rRef = models.frames.FrameTimeUtils.ecefToInertial(r_ecef_t, t);
        ephErrMax = max(ephErrMax, norm(p - rRef(:)));
    end
end
fprintf('Tower ephemeris interpolation error vs the sim frame utility: max %.3e m\n', ephErrMax);

% ===========================================================================
% PART B1 -- measurement-level closure (Orekit composes, we only compare)
% ===========================================================================
fprintf('\n== PART B1: Orekit OneWayGNSSRange (+ Shapiro modifier) vs the sim''s z ==\n');

obsSat  = org.orekit.estimation.measurements.ObservableSatellite(0);
shapiro = org.orekit.estimation.measurements.modifiers.ShapiroOneWayGNSSRangeModifier(mu);

dB1Max = 0; dB1NoShapMax = 0;
for k = 1:numel(obs)
    o = obs(k);
    m = org.orekit.estimation.measurements.gnss.OneWayGNSSRange( ...
        towerEph{o.tower}, 0.0, epoch.shiftedBy(o.t), o.z, 1.0, 1.0, obsSat);
    st = spacecraftState_(o.rSatEci, o.vSatEci, o.t, mu, frame, epoch, V3);
    arr = javaArray('org.orekit.propagation.SpacecraftState',1); arr(1) = st;

    evNo = m.estimateWithoutDerivatives(arr);
    vNo  = evNo.getEstimatedValue();
    dB1NoShapMax = max(dB1NoShapMax, abs(o.z - vNo(1)));

    m.addModifier(shapiro);
    ev = m.estimateWithoutDerivatives(arr);
    v  = ev.getEstimatedValue();
    dB1Max = max(dB1Max, abs(o.z - v(1)));
end
fprintf('  geometry only            : max |z_sim - Orekit| = %.3e m\n', dB1NoShapMax);
fprintf('  geometry + Orekit Shapiro: max |z_sim - Orekit| = %.3e m\n', dB1Max);
fprintf('  (the difference between those two lines IS the Shapiro term Orekit added)\n');

% ===========================================================================
% PART B2 -- orbit-determination closure
% ===========================================================================
fprintf('\n== PART B2: BatchLSEstimator recovers the truth trajectory ==\n');

r0True = truthEci(1:3, 1);
v0True = truthEci(4:6, 1);
fprintf('   init err   iters   final RMS[m]   |dr| vs truth [m]   |dv| vs truth [m/s]\n');

results = zeros(0,3);
for pert = [500, 50000]
    dr = pert     * [1; -1; 0.5] / norm([1; -1; 0.5]);
    dv = pert/1e4 * [0.3; 1; -0.5] / norm([0.3; 1; -0.5]);
    [drN, dvN, nIter, rmsFinal] = runBatchLS_( ...
        r0True + dr, v0True + dv, r0True, v0True, obs, towerEph, obsSat, shapiro, ...
        mu, rEq, J2, frame, epoch);
    fprintf('  %9.0f   %5d   %11.3e   %17.3e   %19.3e\n', pert, nIter, rmsFinal, drN, dvN);
    results(end+1,:) = [drN, dvN, rmsFinal]; %#ok<SAGROW>
end

% ---------------------------------------------------------------------------
% Assertions
%
%   B1: with every effect off, the sim's z is geometry + Shapiro. Orekit's own measurement
%       class, carrying Orekit's own Shapiro modifier, must reproduce it to round-off. The
%       "geometry only" line is asserted to be WORSE by about the Shapiro magnitude
%       (~19 mm at GEO), which proves the modifier is actually doing something rather than
%       both lines agreeing trivially.
%   B2: an estimator that shares no code with this repository, started 500 m and then
%       50 km away, must land on the sim's truth trajectory. Measured recovery is ~1e-11 m
%       with a post-fit RMS of ~1.5e-08 m, i.e. Orekit's DP853 J2 propagation reproduces
%       the sim's RK4 truth over the 1800 s arc to a few nanometres -- consistent with
%       Tier-1's 15 nm integrator comparison. The bounds below sit at 1 mm / 1e-6 m/s:
%       still eight orders above the observed value, so they tolerate integrator-tolerance
%       or platform differences, while a real sign error, double count or scale error
%       anywhere in the observable chain would show up as metres and fail. Both starts
%       must also agree with EACH OTHER far more tightly than either differs from truth,
%       which is what makes this a convergence rather than a retained initial guess.
% ---------------------------------------------------------------------------
assert(dB1Max < 1e-6, ...
    'B1 FAIL: Orekit OneWayGNSSRange + Shapiro vs sim z = %.3e m > 1e-6', dB1Max);
assert(dB1NoShapMax > 1e-3, ...
    ['B1 FAIL: dropping the Shapiro modifier changed nothing (%.3e m) -- the modifier is ' ...
     'inert, so the agreement above does not actually test relativistic composition'], ...
    dB1NoShapMax);

assert(size(results,1) == 2, 'B2 FAIL: expected 2 estimator runs');
assert(all(results(:,1) < 1e-3), ...
    'B2 FAIL: BatchLS position recovery %.3e m exceeds 1 mm', max(results(:,1)));
assert(all(results(:,2) < 1e-6), ...
    'B2 FAIL: BatchLS velocity recovery %.3e m/s exceeds 1e-6', max(results(:,2)));
assert(all(results(:,3) < 1e-4), ...
    'B2 FAIL: post-fit RMS %.3e m exceeds 1e-4 -- the sim''s observables are not consistent with a single J2 orbit', ...
    max(results(:,3)));
assert(abs(results(1,1) - results(2,1)) < 1e-4, ...
    ['B2 FAIL: the 500 m and 50 km starts converged to different answers (%.3e vs %.3e m) ' ...
     '-- the solution is not independent of the initial guess'], results(1,1), results(2,1));

fprintf(['\ntest_orekit_independent_estimator_closure: PASS -- Orekit''s own uplink range ' ...
         'measurement reproduces the sim''s z to %.1e m, and an independent batch ' ...
         'least-squares estimator given only those pseudoranges recovers the truth ' ...
         'trajectory to %.2e m position / %.2e m/s velocity from a 50 km initial error ' ...
         '(post-fit RMS %.1e m).\n'], ...
         dB1Max, max(results(:,1)), max(results(:,2)), max(results(:,3)));

% ===========================================================================
% Local helpers
% ===========================================================================
function st = spacecraftState_(rI, vI, t, mu, frame, epoch, V3)
    pv  = org.orekit.utils.PVCoordinates(V3(rI), V3(vI));
    orb = org.orekit.orbits.CartesianOrbit(pv, frame, epoch.shiftedBy(t), mu);
    st  = org.orekit.propagation.SpacecraftState(orb);
end

function [drN, dvN, nIter, rmsFinal] = runBatchLS_(r0, v0, r0True, v0True, obs, ...
        towerEph, obsSat, shapiro, mu, rEq, J2, frame, epoch)
    % A textbook Orekit batch least squares: numerically propagated J2 orbit, all six
    % Cartesian orbital parameters solved for, Levenberg-Marquardt. Nothing here knows
    % anything about how the pseudoranges were generated.
    V3 = @(v) org.hipparchus.geometry.euclidean.threed.Vector3D(v(1), v(2), v(3));
    pv0    = org.orekit.utils.PVCoordinates(V3(r0), V3(v0));
    orbit0 = org.orekit.orbits.CartesianOrbit(pv0, frame, epoch, mu);

    integBuilder = org.orekit.propagation.conversion.DormandPrince853IntegratorBuilder(1e-3, 300.0, 1e-3);
    builder = org.orekit.propagation.conversion.NumericalPropagatorBuilder( ...
        orbit0, integBuilder, org.orekit.orbits.PositionAngleType.TRUE, 1.0);
    builder.addForceModel(org.orekit.forces.gravity.J2OnlyPerturbation(mu, rEq, J2, frame));

    optimizer = org.hipparchus.optim.nonlinear.vector.leastsquares.LevenbergMarquardtOptimizer();
    % BatchLSEstimator takes PropagatorBuilder... (varargs); MATLAB will not wrap a single
    % object into a Java array on its own, so build the array explicitly.
    bArr = javaArray('org.orekit.propagation.conversion.PropagatorBuilder', 1);
    bArr(1) = builder;
    estimator = org.orekit.estimation.leastsquares.BatchLSEstimator(optimizer, bArr);
    estimator.setParametersConvergenceThreshold(1e-4);
    estimator.setMaxIterations(30);
    estimator.setMaxEvaluations(60);

    % Solve for all six orbital parameters, nothing else.
    drivers = builder.getOrbitalParametersDrivers();
    for i = 0:(drivers.getNbParams()-1)
        drivers.getDrivers().get(i).setSelected(true);
    end

    for k = 1:numel(obs)
        o = obs(k);
        m = org.orekit.estimation.measurements.gnss.OneWayGNSSRange( ...
            towerEph{o.tower}, 0.0, epoch.shiftedBy(o.t), o.z, 1.0, 1.0, obsSat);
        m.addModifier(shapiro);
        estimator.addMeasurement(m);
    end

    props = estimator.estimate();
    nIter = estimator.getIterationsCount();
    rmsFinal = estimator.getOptimum().getRMS();

    st = props(1).propagate(epoch);
    p  = st.getPosition(frame);
    vv = st.getPVCoordinates(frame).getVelocity();
    rEst = [p.getX(); p.getY(); p.getZ()];
    vEst = [vv.getX(); vv.getY(); vv.getZ()];
    drN = norm(rEst - r0True);
    dvN = norm(vEst - v0True);
end
