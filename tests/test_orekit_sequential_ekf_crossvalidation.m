% test_orekit_sequential_ekf_crossvalidation
%
% LEVEL B (part 2) -- the SEQUENTIAL filter, vs Orekit 13.1.7's KalmanEstimator.
%
% test_orekit_independent_estimator_closure validated the OBSERVABLES: a batch estimator
% given only the sim's pseudoranges lands on truth. A batch fit, however, says nothing
% about how the sim's EKF gets there -- it never exercises the time update, the Joseph
% covariance form, or the epoch-by-epoch covariance contraction. Those are precisely where
% two filters silently disagree while both still converge, and where a filter can end up
% "confidently wrong": right state, wrong P.
%
% THE ARGUMENT: a Kalman filter is a deterministic function of (x0, P0, Q, R, dynamics,
% measurement model, measurement sequence). Fix all seven and the answer is unique. So
% both filters are given
%     * the same initial state and the same P0 (rotated into each one's frame),
%     * the same process noise (exactly zero on the orbital block in this scenario),
%     * the same R, read out of the sim rather than assumed -- the sim's code sigma is
%       elevation-weighted, so R is NOT sigma0^2 * I,
%     * the same measurements, including the same noise realisation,
% and must then produce the same state AND the same covariance at every epoch. Any
% difference is a defect in one of the two, not a modelling choice.
%
% SCOPE, STATED HONESTLY: the comparison is over the 6-state orbital block. The sim's code
% row is H = [u_hat' | ... | +1 on b_rx], so the receiver clock genuinely participates;
% Orekit's OneWayGNSSRange has a single clock-offset driver in seconds and no drift state,
% which cannot be matched to the sim's (bias, drift) pair. The clock states are therefore
% PINNED (P0 -> 1e-18, Q = 0) so that both filters solve the same 6-parameter problem.
% This tests the filter mechanics, not the radial-clock observability, and the pinning is
% asserted rather than assumed. Attitude, ambiguity and gyro-bias states have identically
% zero columns in H here, so they are inert and need no such treatment.
%
% TWO FURTHER INPUTS ARE PINNED, for the same reason and in the same style -- Orekit's
% measurement API cannot be given them, so leaving them free makes the two filters solve
% different problems rather than the same one:
%
%   R MUST BE DIAGONAL. OneWayGNSSRange carries ONE scalar sigma per measurement, so the
%     reference can only ever be handed sqrt(diag(R)). Since 2026-08-06 (commit 3ed031f)
%     the sim adds an L1<->L2 common-mode block to R wherever a shared atmosphere sigma is
%     charged -- correctly, because one physical atmosphere must not be averaged down as
%     two independent samples. Under this fixture that block reaches rho = 0.68..0.91 even
%     though the atmosphere is switched off on the truth side, and it silently turned this
%     comparison into 10.1 m of state disagreement and 20 % of covariance disagreement from
%     the FIRST update. It is a deliberate sim feature and out of scope here, so
%     covariance.sharedErrors is switched OFF below and diagonality is then ASSERTED.
%
%   NO TOWER-CLOCK CORRECTION. Orekit has no tower clock term, so any correction the sim
%     folds into h is an unmodelled bias on the reference side. Worth 0.14 m here. The
%     canonical knob is set below in addition to the fixture's legacy alias, so the test
%     states its own precondition instead of depending on which alias finalizeConfig
%     honours, and the resulting correction is ASSERTED to be identically zero.
%
% Both are asserted per epoch rather than assumed: a cross-validation that silently stops
% comparing like with like is worse than no cross-validation at all, and both of these
% arrived from elsewhere in the codebase long after this test was written.
%
%   PART A -- state trajectory: position and velocity at every epoch.
%   PART B -- covariance: the 6x6 position/velocity block at every epoch, plus a check
%     that it actually contracts by orders of magnitude (otherwise agreement is vacuous).
%   PART C -- discriminating power: Orekit is re-run with R inflated by 10%, and the
%     covariances MUST then disagree. Without this, a test that compares two numbers which
%     happen to be insensitive to the thing under test would pass for the wrong reason.
%
% REQUIREMENTS / SKIP: JVM-enabled MATLAB (`matlab -batch`, not the -nojvm MCP session)
% + the Orekit bridge at ~/orekit-bridge. Skips cleanly if absent.

fprintf('test_orekit_sequential_ekf_crossvalidation\n');

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

mu  = revgnss.Constants.EARTH_GM_M3PS2;
rEq = revgnss.Constants.EARTH_RADIUS_M;
J2  = revgnss.Constants.EARTH_J2;

% ---------------------------------------------------------------------------
% Scenario: flat, but with a real (elevation-weighted) code sigma so the filter has
% something to weigh. The same knob drives R and the noise realisation, so the
% measurements are genuinely noisy -- which is fine, and better: both filters receive the
% identical realisation, so they must still agree exactly.
% ---------------------------------------------------------------------------
cfg = resolveSimulationConfig('test001_idealFlat.json', ...
    struct('simulation', struct('duration_s', 3600)));
cfg.scenario.nTowers    = 5;
cfg.scenario.nReceivers = 1;
cfg.signals.L1.codeSigma0_m = 1.0;
cfg.signals.L2.codeSigma0_m = 1.0;
cfg.estimator.dynamics.mode = 'j2';
cfg.plots.enable  = false;
cfg.report.enable = false;
% The two inputs Orekit's measurement API cannot be given -- see the SCOPE note above.
% Both are asserted below, so a future default that re-enables either one fails loudly
% here instead of quietly degrading the comparison.
cfg.covariance.sharedErrors.enable = false;   % -> R diagonal, the only R Orekit can take
cfg.towerClock.correctionMode      = 'perfectTruth';  % -> no tower clock term in h
cfg = revgnss.ConfigFactory.finalizeConfig(cfg);

[asset, towers, ekf, mm, ~, orbitProp] = revgnss.ScenarioFactory.build(cfg);
sm = ekf.stateMap;
nT = numel(towers);

% ---- Pin the clock states, and PROVE the pinning worked ------------------------------
P0 = ekf.P;
clkIdx = [sm.b_rx_idx, sm.bdot_rx_idx];
P0(clkIdx, :) = 0; P0(:, clkIdx) = 0;
P0(sm.b_rx_idx,    sm.b_rx_idx)    = 1e-18;
P0(sm.bdot_rx_idx, sm.bdot_rx_idx) = 1e-18;
x0 = ekf.x;
x0(clkIdx) = 0;
ekf.initState(x0, P0);

dt = 60;
Qchk = ekf.buildQ_(dt, {});
orbIdx = [sm.r_idx(:); sm.v_idx(:)];
assert(max(max(abs(Qchk(orbIdx, orbIdx)))) == 0, ...
    'orbital process noise must be exactly zero for this comparison (got %.3e)', ...
    max(max(abs(Qchk(orbIdx, orbIdx)))));
assert(max(abs(Qchk(clkIdx, clkIdx)), [], 'all') == 0, ...
    'receiver clock process noise must be exactly zero for this comparison (got %.3e)', ...
    max(abs(Qchk(clkIdx, clkIdx)), [], 'all'));
fprintf('\nQ(dt=%g): orbital block and clock block both exactly zero (verified)\n', dt);
fprintf('P0 sigma: pos %.1f m, vel %.3f m/s, clock pinned to %.0e m\n', ...
    sqrt(P0(1,1)), sqrt(P0(4,4)), sqrt(P0(sm.b_rx_idx, sm.b_rx_idx)));

% ---- Tower ephemerides for Orekit (same construction as the batch closure test) -------
tGrid = 0:dt:1200;
tEph  = (tGrid(1)-600) : 20 : (tGrid(end)+600);
towerEph = cell(nT,1);
for ti = 1:nT
    r_ecef_t = towers{ti}.getAntennaPositionECEF();
    lst = java.util.ArrayList();
    for t = tEph
        [rI, vI] = models.frames.FrameTimeUtils.ecefStateToInertial(r_ecef_t, zeros(3,1), t);
        aI = -(revgnss.Constants.EARTH_OMEGA_RADPS^2) * [rI(1); rI(2); 0];
        pv = org.orekit.utils.TimeStampedPVCoordinates(epoch.shiftedBy(t), V3(rI), V3(vI), V3(aI));
        lst.add(org.orekit.propagation.SpacecraftState( ...
            org.orekit.utils.AbsolutePVCoordinates(frame, pv)));
    end
    towerEph{ti} = org.orekit.propagation.analytical.Ephemeris(lst, 6);
end

% ===========================================================================
% Run the SIM's own EKF, recording the measurements it consumed
% ===========================================================================
fprintf('\n== Running the sim EKF over %d epochs (code rows only) ==\n', numel(tGrid));

nEp = numel(tGrid);
simX = zeros(6, nEp); simP = cell(nEp,1);
recorded = cell(nEp,1);
clkMax = 0; twrMax = 0; offDiagMax = 0;
for kk = 1:nEp
    t_s = tGrid(kk);
    if kk > 1
        ekf.predict(dt, {}, tGrid(kk-1), []);
    end
    [r_ecef, v_ecef] = orbitProp.propagate(t_s);
    asset.setTruthFromOrbit(r_ecef, v_ecef);
    [z, h, H, R, es] = mm.computeMeasurements(asset, towers, ekf.x, t_s, ekf.stateMap);

    M = es.nPseudorange;
    rows = 1:M;                                  % code rows only

    % The two preconditions Orekit cannot be given. Measured, not assumed: the reference
    % is handed sqrt(diag(R)) and a bias-free h, so a correlated R or a non-zero tower
    % clock correction means the two filters stop solving the same problem.
    Rc_ = R(rows,rows);
    offDiagMax = max(offDiagMax, max(max(abs(Rc_ - diag(diag(Rc_))))));
    if isfield(es,'towerClockModel_m') && numel(es.towerClockModel_m) >= M
        twrMax = max(twrMax, max(abs(es.towerClockModel_m(rows))));
    end

    ekf.update(z(rows), h(rows), H(rows,:), R(rows,rows));

    simX(:,kk) = ekf.x(orbIdx);
    simP{kk}   = ekf.P(orbIdx, orbIdx);
    recorded{kk} = struct('t', t_s, 'tower', es.towerIdx_perMeas(rows), ...
                          'z', z(rows), 'sigma', sqrt(diag(R(rows,rows))));
    clkMax = max(clkMax, max(abs(ekf.x(clkIdx))));
end
fprintf('  %d measurements/epoch, R is elevation-weighted (sigma %.2f .. %.2f m)\n', ...
    numel(recorded{1}.z), min(recorded{1}.sigma), max(recorded{1}.sigma));

% ---- The two pinned inputs, verified over the whole arc ------------------------------
assert(offDiagMax == 0, ...
    ['R is not diagonal (max |off-diagonal| = %.3e m^2 over the arc). Orekit''s ' ...
     'OneWayGNSSRange takes one scalar sigma per measurement, so the reference below is ' ...
     'given sqrt(diag(R)) and a correlated R means the two filters are NOT solving the ' ...
     'same problem -- the comparison would be meaningless rather than merely loose. ' ...
     'cfg.covariance.sharedErrors is switched off above; something has re-enabled a ' ...
     'correlated R term.'], offDiagMax);
assert(twrMax == 0, ...
    ['the sim folded a tower-clock correction of up to %.3e m into h. Orekit has no ' ...
     'tower clock term, so that is an unmodelled bias on the reference side and lands ' ...
     'directly in the state comparison. cfg.towerClock.correctionMode is set to ' ...
     '''perfectTruth'' above; check that finalizeConfig still honours it.'], twrMax);
fprintf('  R diagonal over the arc (max |off-diag| = 0) and no tower-clock term in h (verified)\n');

% The pinned clock is not perfectly immobile -- the Joseph update reintroduces a tiny
% gain on it -- so the residual excursion is measured rather than assumed. It enters the
% comparison as a direct additive shift on h, so it only has to stay well below the state
% tolerance asserted at the end (1 mm) for the 6-state comparison to be legitimate.
fprintf('  pinned clock states moved at most %.3e m over the arc (must stay << 1 mm)\n', clkMax);
assert(clkMax < 1e-4, ...
    ['clock pinning failed: states moved %.3e m, which is not negligible against the 1 mm ' ...
     'state tolerance -- the 6-state comparison would no longer be like-for-like'], clkMax);

% ===========================================================================
% Run Orekit's KalmanEstimator on the identical data
% ===========================================================================
fprintf('\n== Running Orekit KalmanEstimator on the identical data ==\n');

T0 = frameTransform6_(0);                                % inertial -> ECEF
P0orb_ecef = P0(orbIdx, orbIdx);
P0orb_eci  = T0 \ P0orb_ecef / T0';                      % rotate P0 into Orekit's frame
x0orb_eci  = T0 \ simX0_(x0, orbIdx);

[oreX, oreP] = runOrekitKalman_(x0orb_eci, P0orb_eci, recorded, towerEph, ...
    mu, rEq, J2, frame, epoch, V3, 1.0);

% ===========================================================================
% PART A / B -- compare state and covariance, epoch by epoch
% ===========================================================================
fprintf('\n== PART A/B: state and covariance agreement ==\n');
fprintf('  epoch   t[s]    |dr|[m]     |dv|[m/s]    max|dP_rr|      rel dP    sigma_r(sim)[m]\n');
% Measure the contraction from the PRIOR P0, not from the first posterior: most of the
% work happens in the very first update (1732 m -> ~14 m), so starting the count after it
% would understate the filter's job by more than an order of magnitude.
dXmax = 0; dVmax = 0; dPrel = 0; sigLast = NaN;
sigFirst = sqrt(trace(P0orb_ecef(1:3,1:3)));
for kk = 1:nEp
    % sim is in ECEF, Orekit in inertial: bring Orekit across for comparison
    Tk = frameTransform6_(tGrid(kk));
    xOreEcef = Tk * oreX(:,kk);
    POreEcef = Tk * oreP{kk} * Tk';

    dR = norm(simX(1:3,kk) - xOreEcef(1:3));
    dV = norm(simX(4:6,kk) - xOreEcef(4:6));
    dP = max(max(abs(simP{kk} - POreEcef)));
    scaleP = max(max(abs(simP{kk})));
    rel = dP / max(scaleP, eps);

    dXmax = max(dXmax, dR); dVmax = max(dVmax, dV); dPrel = max(dPrel, rel);
    sr = sqrt(trace(simP{kk}(1:3,1:3)));
    if kk == nEp; sigLast = sr; end
    if kk <= 3 || kk == nEp
        fprintf('  %5d %6g  %10.3e  %11.3e  %13.3e  %10.3e  %14.4f\n', ...
            kk, tGrid(kk), dR, dV, dP, rel, sr);
    end
end
fprintf('  max |dr| = %.3e m | max |dv| = %.3e m/s | max relative dP = %.3e\n', ...
    dXmax, dVmax, dPrel);
fprintf('  position sigma contracted %.1f m (prior P0) -> %.4f m (factor %.0f) over the arc\n', ...
    sigFirst, sigLast, sigFirst/sigLast);

% ===========================================================================
% PART C -- discriminating power: a 10%% R error must break the agreement
% ===========================================================================
fprintf('\n== PART C: does the comparison actually detect a wrong R? ==\n');
[~, orePbad] = runOrekitKalman_(x0orb_eci, P0orb_eci, recorded, towerEph, ...
    mu, rEq, J2, frame, epoch, V3, 1.10);
TkEnd = frameTransform6_(tGrid(end));
PbadEcef = TkEnd * orePbad{end} * TkEnd';
relBad = max(max(abs(simP{end} - PbadEcef))) / max(max(abs(simP{end})));
fprintf('  with R inflated 10%%: relative dP at the final epoch = %.3e (matched run: %.3e)\n', ...
    relBad, dPrel);

% ---------------------------------------------------------------------------
% Assertions
%
%   A/B: with (x0, P0, Q, R, dynamics, measurement model, data) all matched, the two
%      filters are computing the same deterministic function. Measured 2026-08-08:
%      7.5e-07 m in state, 1.7e-08 m/s in velocity and 4.3e-08 relative in covariance,
%      the last hovering at 1e-08..3e-08 across the arc rather than trending -- the sim
%      propagates P with a fixed-step RK4 finite-difference STM while Orekit integrates
%      variational equations adaptively, so what is left is truncation noise, not a
%      systematic split. Bounds are set three orders above that, which is still seven
%      orders below the sensitivity demonstrated in PART C -- a wrong Q, a missing Joseph
%      term or a transposed H are percent-level effects, not parts per hundred million.
%   B also asserts the covariance actually contracts, so the agreement cannot be satisfied
%      by two filters that both simply carry P0 forward.
%   C asserts the comparison is SENSITIVE: a 10% error in R must show up far above the
%      matched-run residual. Without this the test could pass by comparing two quantities
%      that are insensitive to the filter internals.
% ---------------------------------------------------------------------------
assert(dXmax < 1e-3, 'A FAIL: EKF position trajectories differ by %.3e m > 1 mm', dXmax);
assert(dVmax < 1e-6, 'A FAIL: EKF velocity trajectories differ by %.3e m/s > 1e-6', dVmax);
assert(dPrel < 1e-4, 'B FAIL: EKF covariance differs by %.3e relative > 1e-4', dPrel);
assert(sigFirst/sigLast > 100, ...
    ['B FAIL: position sigma only contracted by a factor %.1f -- the filters are not doing ' ...
     'enough work for the comparison to mean anything'], sigFirst/sigLast);
assert(relBad > 100*dPrel && relBad > 1e-3, ...
    ['C FAIL: a 10%% error in R changed the covariance by only %.3e (matched %.3e) -- the ' ...
     'comparison is not sensitive to the filter internals it claims to test'], relBad, dPrel);

fprintf(['\ntest_orekit_sequential_ekf_crossvalidation: PASS -- the sim EKF and Orekit''s ' ...
         'KalmanEstimator agree to %.1e m in state and %.1e relative in covariance over ' ...
         '%d epochs, while the position sigma contracts by a factor of %.0f; a 10%% R error ' ...
         'is detected at %.1e.\n'], dXmax, dPrel, nEp, sigFirst/sigLast, relBad);

% ===========================================================================
% Local helpers
% ===========================================================================
function x = simX0_(x0, orbIdx)
    x = x0(orbIdx);
end

function [X, Pc] = runOrekitKalman_(x0eci, P0eci, recorded, towerEph, ...
        mu, rEq, J2, frame, epoch, V3, sigmaScale)
    % A textbook Orekit sequential filter: numerically propagated J2 orbit, six Cartesian
    % orbital parameters, zero process noise, initial covariance supplied explicitly.
    % Measurements at one epoch are bundled into a MultiplexedMeasurement so that Orekit
    % performs ONE combined update per epoch, matching the sim's batch update -- processing
    % them singly would relinearise between rows and is a different filter.
    pv0    = org.orekit.utils.PVCoordinates(V3(x0eci(1:3)), V3(x0eci(4:6)));
    orbit0 = org.orekit.orbits.CartesianOrbit(pv0, frame, epoch, mu);

    integBuilder = org.orekit.propagation.conversion.DormandPrince853IntegratorBuilder(1e-3, 300.0, 1e-3);
    builder = org.orekit.propagation.conversion.NumericalPropagatorBuilder( ...
        orbit0, integBuilder, org.orekit.orbits.PositionAngleType.TRUE, 1.0);
    builder.addForceModel(org.orekit.forces.gravity.J2OnlyPerturbation(mu, rEq, J2, frame));
    drivers = builder.getOrbitalParametersDrivers();
    for i = 0:(drivers.getNbParams()-1)
        drivers.getDrivers().get(i).setSelected(true);
    end

    initCov = org.hipparchus.linear.MatrixUtils.createRealMatrix(P0eci);
    procQ   = org.hipparchus.linear.MatrixUtils.createRealMatrix(zeros(6,6));
    covProv = org.orekit.estimation.sequential.ConstantProcessNoise(initCov, procQ);

    kb = org.orekit.estimation.sequential.KalmanEstimatorBuilder();
    kb = kb.addPropagationConfiguration(builder, covProv);
    kalman = kb.build();

    obsSat  = org.orekit.estimation.measurements.ObservableSatellite(0);
    shapiro = org.orekit.estimation.measurements.modifiers.ShapiroOneWayGNSSRangeModifier(mu);

    nEp = numel(recorded);
    X  = zeros(6, nEp);
    Pc = cell(nEp,1);
    for kk = 1:nEp
        o = recorded{kk};
        lst = java.util.ArrayList();
        for j = 1:numel(o.z)
            m = org.orekit.estimation.measurements.gnss.OneWayGNSSRange( ...
                towerEph{o.tower(j)}, 0.0, epoch.shiftedBy(o.t), o.z(j), ...
                sigmaScale * o.sigma(j), 1.0, obsSat);
            m.addModifier(shapiro);
            lst.add(m);
        end
        mux = org.orekit.estimation.measurements.MultiplexedMeasurement(lst);
        props = kalman.estimationStep(mux);

        st = props(1).propagate(epoch.shiftedBy(o.t));
        p  = st.getPosition(frame);
        vv = st.getPVCoordinates(frame).getVelocity();
        X(:,kk) = [p.getX(); p.getY(); p.getZ(); vv.getX(); vv.getY(); vv.getZ()];
        Pc{kk}  = double(kalman.getPhysicalEstimatedCovarianceMatrix().getData());
    end
end

function T = frameTransform6_(t_s)
    % Exact 6x6 inertial -> ECEF transform for a state [r; v], built by pushing the six
    % basis vectors through the sim's OWN frame utility, with linearity verified.
    T = zeros(6,6);
    for k = 1:6
        e = zeros(6,1); e(k) = 1;
        [re, ve] = models.frames.FrameTimeUtils.inertialStateToEcef(e(1:3), e(4:6), t_s);
        T(:,k) = [re(:); ve(:)];
    end
    x = [1e7; -2e7; 3e6; 100; -200; 50];
    [rc, vc] = models.frames.FrameTimeUtils.inertialStateToEcef(x(1:3), x(4:6), t_s);
    assert(max(abs(T*x - [rc(:); vc(:)])) < 1e-6, ...
        'frame transform is not linear in the state -- the covariance rotation is invalid');
end
