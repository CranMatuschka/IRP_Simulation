% test_orekit_jacobian_stm_crossvalidation
%
% LEVEL C (part 2) -- the EKF's two derivative blocks, vs Orekit 13.1.7.
%
% Every earlier Orekit test checks a VALUE. The filter, however, is driven by
% DERIVATIVES: the measurement Jacobian H decides how an innovation is distributed
% across the state, and the state transition matrix Phi decides how the covariance is
% propagated. A correct value with a wrong derivative gives a filter that is confidently
% wrong -- exactly the failure mode that internal consistency checks (NEES/NIS) report as
% "an observability wall" rather than as a bug. Both are cross-checked here against
% independently derived Orekit quantities.
%
%   PART A -- measurement Jacobian d(rho)/d(r_sat): the position columns of the H rows
%     that MeasurementModel.computeMeasurements actually returns, vs a central-difference
%     gradient of OREKIT's rigorous uplink light-time solution
%     (AbstractMeasurement.signalTimeOfFlightAdjustableEmitter). Orekit's solver is used
%     as the range function, so the reference knows nothing about how the sim derives its
%     partials. This catches a sign error, a mis-mapped state column, a missing
%     light-time/Sagnac coupling term, or a units slip -- none of which change z.
%
%   PART B -- state transition matrix: filter.EkfDynamicsPredictor.finiteDiffStm6 (6x6,
%     ECEF, central differences about the EKF's own RK4 dynamics) vs Orekit's
%     MatricesHarvester, which integrates the VARIATIONAL EQUATIONS rather than
%     differencing trajectories -- a structurally different route to the same matrix.
%     Compared in ECEF via the exact 6x6 frame transform, for both EKF dynamics modes
%     ('twoBody' and 'j2') and two step sizes.
%
% NOTE ON PRECISION: the sim's Phi is a finite difference of a ~4.2e7 m trajectory with a
% 1 m position step, so its own noise floor is eps(4.2e7)/1 m ~ 7.5e-9. Tolerances below
% are set at that floor, not tighter -- a tighter bound would be testing round-off.
%
% REQUIREMENTS / SKIP: JVM-enabled MATLAB (`matlab -batch`, not the -nojvm MCP session)
% + the Orekit bridge at ~/orekit-bridge. Skips cleanly if absent.

fprintf('test_orekit_jacobian_stm_crossvalidation\n');

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
om  = revgnss.Constants.EARTH_OMEGA_RADPS;

% ===========================================================================
% PART A -- measurement Jacobian d(rho)/d(r_sat)
% ===========================================================================
fprintf('\n== PART A: measurement Jacobian  sim H vs Orekit light-time gradient ==\n');

cfg = resolveSimulationConfig('ideal_G5S1R4_ts3600_flat.json');
cfg.scenario.nTowers    = 5;
cfg.scenario.nReceivers = 1;
cfg.plots.enable  = false;
cfg.report.enable = false;
cfg = revgnss.ConfigFactory.finalizeConfig(cfg);

[asset, towers, ekf, mm, ~, orbitProp] = revgnss.ScenarioFactory.build(cfg);
[r_ecef0, v_ecef0] = orbitProp.propagate(0);
asset.setTruthFromOrbit(r_ecef0, v_ecef0);
[~, ~, H, ~, es] = mm.computeMeasurements(asset, towers, ekf.x, 0, ekf.stateMap);

blk  = revgnss.AssetStateBlock.forAsset(ekf.stateMap, 1);
rIdx = blk.r;
M    = es.nPseudorange;
fdH  = models.measurements.MeasurementModel.needsFiniteDiffH_(cfg);
fprintf('  H position columns = %s | sim H path: %s\n', mat2str(rIdx(:)'), ...
    ternary_(fdH, 'finite-difference', 'analytic'));

lever  = asset.receiverLeverArms_body_m;
satAnt = asset.getAntennaPositionsECEF(asset.r_ecef_m, asset.attitude_euler_rad, lever);
towerPos = zeros(3, numel(towers));
for ti = 1:numel(towers); towerPos(:,ti) = towers{ti}.getAntennaPositionECEF(); end

step_m = 1.0;   % central-difference step on the satellite position
fprintf('  row twr  el[deg]   |H_sim|    |H_ore|   max|d component|   angle[urad]\n');
dJacMax = 0; dNormMax = 0; angMax = 0; ltDepart = 0;
for mi = 1:M
    ti = es.towerIdx_perMeas(mi);
    rt = towerPos(:,ti);
    rs = satAnt(:, es.antennaIdx_perMeas(mi));

    Hsim = H(mi, rIdx).';

    % Orekit-based gradient of the rigorous uplink light-time range w.r.t. the satellite
    % position. The tower is the emitter (ECI pos + vel = omega x r); only the receiver
    % position is perturbed, exactly the partial the filter needs.
    Hore = zeros(3,1);
    for k = 1:3
        dp = zeros(3,1); dp(k) = step_m;
        rp = orekitRange_(rs + dp, rt, om, c, epoch, frame, V3);
        rm = orekitRange_(rs - dp, rt, om, c, epoch, frame, V3);
        Hore(k) = (rp - rm) / (2*step_m);
    end

    dJac  = max(abs(Hsim - Hore));
    dNorm = abs(norm(Hsim) - norm(Hore));            % sim vs Orekit, NOT vs 1 -- see below
    ang   = real(acos(max(-1, min(1, dot(Hsim,Hore)/(norm(Hsim)*norm(Hore))))));
    dJacMax  = max(dJacMax, dJac);
    dNormMax = max(dNormMax, dNorm);
    angMax   = max(angMax, ang);
    ltDepart = max(ltDepart, abs(norm(Hsim) - 1));   % how far H is from a bare unit LOS
    if mi <= numel(towers)
        el = models.frames.GeometryUtils.elevationAngle(rt, rs);
        fprintf('  %3d %3d  %7.2f  %9.6f  %9.6f   %15.3e   %10.3f\n', mi, ti, rad2deg(el), ...
            norm(Hsim), norm(Hore), dJac, 1e6*ang);
    end
end
fprintf('  max |d H component| = %.3e | max | |H_sim|-|H_ore| | = %.3e | max angle = %.3e rad\n', ...
    dJacMax, dNormMax, angMax);

% The true partial is NOT a bare unit line-of-sight vector: differentiating the light-time
% solution adds the emitter-motion (Sagnac) coupling, of relative order v_tower/c. Both
% implementations show the same departure from unity, which is itself the evidence that
% neither dropped the coupling -- a naive d(rho)/dr = unit-LOS Jacobian would give exactly 1.
vTowerMax = om * rEq;
fprintf('  |H| departs from a bare unit LOS by %.3e; expected coupling scale v_tower/c = %.3e\n', ...
    ltDepart, vTowerMax/c);

% ===========================================================================
% PART B -- state transition matrix vs Orekit variational equations
% ===========================================================================
fprintf('\n== PART B: 6x6 STM  sim finite-difference vs Orekit variational equations ==\n');

% A GEO state, taken from the sim's own truth propagator so the comparison is about the
% dynamics rather than about the initial conditions.
t0 = 0;
r0 = r_ecef0(:); v0 = v_ecef0(:);
[r_i0, v_i0] = models.frames.FrameTimeUtils.ecefStateToInertial(r0, v0, t0);

% The sim differences a ~4.2e7 m trajectory, so each STM column inherits a round-off floor
% of eps(|r|) / (2 * perturbation step). Position columns use a 1 m step, velocity columns
% 1e-3 m/s, so the r-v block's floor is a thousand times coarser than the r-r block's. These
% floors are DERIVED here rather than fitted to the observed numbers, so the test stays a
% real bound if the step sizes or the orbit radius change.
drStep = 1.0; dvStep = 1e-3;
try; drStep = cfg.estimator.dynamics.fdPositionStep_m;   catch; end
try; dvStep = cfg.estimator.dynamics.fdVelocityStep_mps; catch; end
% The velocity rows must be scaled by the INERTIAL speed, not the ECEF one: at GEO the
% satellite is very nearly stationary in ECEF, so eps(|v_ecef|) is an artefact of the
% frame, not the precision actually available. propagateEcef converts to inertial, steps
% there, and converts back, so every returned ECEF velocity inherits the round-off of a
% ~3.1 km/s inertial quantity (equivalently of the omega x r transport term).
vScale   = max(norm(v0), norm(v_i0));
floorPos = eps(norm(r0)) / (2*drStep);      % r-rows differentiated w.r.t. position
floorVel = eps(norm(r0)) / (2*dvStep);      % r-rows differentiated w.r.t. velocity
floorVR  = eps(vScale)   / (2*drStep);      % v-rows w.r.t. position
floorVV  = eps(vScale)   / (2*dvStep);      % v-rows w.r.t. velocity
GUARD    = 10;                              % allow a few ULP of accumulation through RK4
fprintf('  finite-difference noise floors (x%d guard): rr %.1e  rv %.1e  vr %.1e  vv %.1e\n', ...
    GUARD, GUARD*floorPos, GUARD*floorVel, GUARD*floorVR, GUARD*floorVV);

fprintf('   mode        dt[s]   max|d Phi_rr|  max|d Phi_rv|  max|d Phi_vr|  max|d Phi_vv|   rel(rv)\n');
nCase = 0; okRR = true; okRV = true; okVR = true; okVV = true;
dRRmax = 0; dRVmax = 0; dVRmax = 0; dVVmax = 0; relRVmax = 0;
for modeName = {'twoBody', 'j2'}
    for dt = [1 60]
        cfgD = cfg;
        cfgD.estimator.dynamics.mode = modeName{1};

        % --- sim: finite-difference STM about its own RK4 step, in ECEF ---
        PhiSim = filter.EkfDynamicsPredictor.finiteDiffStm6(r0, v0, dt, t0, cfgD, []);

        % --- Orekit: variational equations, inertial, then rotated into ECEF ---
        PhiOreEci = orekitStm_(r_i0, v_i0, dt, mu, rEq, J2, modeName{1}, frame, epoch);
        T0 = frameTransform6_(t0);
        T1 = frameTransform6_(t0 + dt);
        PhiOre = T1 * PhiOreEci / T0;

        D = abs(PhiSim - PhiOre);
        dRR = max(max(D(1:3,1:3)));  dRV = max(max(D(1:3,4:6)));
        dVR = max(max(D(4:6,1:3)));  dVV = max(max(D(4:6,4:6)));
        % The r-v block is dominated by dt*I, so a relative measure is the meaningful one.
        relRV = dRV / max(1, max(max(abs(PhiOre(1:3,4:6)))));

        okRR = okRR && (dRR <= GUARD*floorPos);
        okRV = okRV && (dRV <= GUARD*floorVel);
        okVR = okVR && (dVR <= GUARD*floorVR);
        okVV = okVV && (dVV <= GUARD*floorVV);
        dRRmax = max(dRRmax,dRR); dRVmax = max(dRVmax,dRV);
        dVRmax = max(dVRmax,dVR); dVVmax = max(dVVmax,dVV);
        relRVmax = max(relRVmax, relRV);
        nCase = nCase + 1;
        fprintf('  %-10s  %5d   %13.3e  %13.3e  %13.3e  %13.3e  %9.2e\n', ...
            modeName{1}, dt, dRR, dRV, dVR, dVV, relRV);
    end
end
dPhiMax = max([dRRmax dRVmax dVRmax dVVmax]);
fprintf('  max |d Phi| over all cases = %.3e (r-v block relative: %.3e)\n', dPhiMax, relRVmax);

% Sanity: the STM must actually be non-trivial, otherwise agreement is vacuous.
PhiRef = filter.EkfDynamicsPredictor.finiteDiffStm6(r0, v0, 60, t0, ...
    setfield(cfg, 'estimator', setfield(cfg.estimator, 'dynamics', ...
        setfield(cfg.estimator.dynamics, 'mode', 'j2'))), []); %#ok<SFLD>
offIdentity = max(max(abs(PhiRef - eye(6))));
fprintf('  Phi(dt=60,j2) departs from identity by %.4f (non-trivial dynamics confirmed)\n', ...
    offIdentity);

% ---------------------------------------------------------------------------
% Assertions
%
%   A: the sim's H must agree with the Orekit-derived gradient componentwise and in
%      direction. It is deliberately NOT asserted to be a unit vector: the true partial
%      carries the emitter-motion coupling from differentiating the light-time solution,
%      so |H| differs from 1 at the v_tower/c level. That departure is asserted to be
%      PRESENT (lower bound) and of the right size (upper bound) -- a Jacobian built as a
%      bare unit line-of-sight would give exactly 1 and fail the lower bound.
%   B: the sim differences trajectories, Orekit integrates variational equations. They
%      must agree to the sim's finite-difference round-off floor, computed per block from
%      eps(|r|)/(2*step) rather than hand-tuned.
% ---------------------------------------------------------------------------
assert(dNormMax < 1e-8, 'A FAIL: |H_sim| and |H_ore| differ by %.3e', dNormMax);
assert(dJacMax  < 1e-6, 'A FAIL: H position row vs Orekit light-time gradient %.3e > 1e-6', dJacMax);
assert(angMax   < 1e-6, 'A FAIL: H direction differs from Orekit by %.3e rad', angMax);
assert(ltDepart > 0.1*vTowerMax/c, ...
    ['A FAIL: |H| = 1 to %.3e -- the light-time/emitter-motion coupling is MISSING from ' ...
     'the Jacobian (expected a departure of order v_tower/c = %.3e)'], ltDepart, vTowerMax/c);
assert(ltDepart < 10*vTowerMax/c, ...
    'A FAIL: |H| departs from unit LOS by %.3e, far beyond the v_tower/c = %.3e coupling scale', ...
    ltDepart, vTowerMax/c);

assert(nCase == 4, 'B FAIL: expected 4 STM cases, ran %d', nCase);
assert(okRR, 'B FAIL: STM r-r block vs Orekit %.3e exceeds its round-off floor %.3e', ...
    dRRmax, GUARD*floorPos);
assert(okRV, 'B FAIL: STM r-v block vs Orekit %.3e exceeds its round-off floor %.3e', ...
    dRVmax, GUARD*floorVel);
assert(okVR, 'B FAIL: STM v-r block vs Orekit %.3e exceeds its round-off floor %.3e', ...
    dVRmax, GUARD*floorVR);
assert(okVV, 'B FAIL: STM v-v block vs Orekit %.3e exceeds its round-off floor %.3e', ...
    dVVmax, GUARD*floorVV);
% (relRV is reported, not asserted: at dt = 1 s the r-v block is itself ~dt*I ~ 1, so the
% relative measure collapses onto the same round-off floor already bounded above. It is
% informative at dt = 60 s, where it drops to ~1e-8.)
assert(offIdentity > 1e-3, ...
    'B FAIL: STM is within %.3e of the identity -- the comparison is vacuous', offIdentity);

fprintf(['\ntest_orekit_jacobian_stm_crossvalidation: PASS -- measurement Jacobian matches ' ...
         'Orekit''s light-time gradient to %.1e (and carries the v_tower/c coupling, %.1e); ' ...
         'the 6x6 STM matches Orekit''s variational equations to each block''s round-off ' ...
         'floor across both dynamics modes.\n'], dJacMax, ltDepart);

% ===========================================================================
% Local helpers
% ===========================================================================
function rho = orekitRange_(rs, rt, om, c, epoch, frame, V3)
    % Rigorous one-way uplink range via Orekit's light-time solver. The ECEF triad is used
    % directly as the inertial container; the tower's rotation enters via its velocity.
    vT = cross([0;0;om], rt);
    aT = cross([0;0;om], vT);
    try
        pvT = org.orekit.utils.TimeStampedPVCoordinates(epoch, V3(rt), V3(vT), V3(aT));
    catch
        pvT = org.orekit.utils.TimeStampedPVCoordinates(epoch, V3(rt), V3(vT));
    end
    tau = org.orekit.estimation.measurements.AbstractMeasurement.signalTimeOfFlightAdjustableEmitter( ...
        pvT, V3(rs), epoch, frame);
    rho = c*tau;
end

function Phi = orekitStm_(r_i0, v_i0, dt, mu, rEq, J2, modeName, frame, epoch)
    % Orekit STM from the VARIATIONAL EQUATIONS (not from differencing trajectories).
    % J2OnlyPerturbation's third argument is the POSITIVE J2 coefficient; the central
    % Newtonian term is added automatically from the orbit mu, so it must NOT be added.
    V3 = @(v) org.hipparchus.geometry.euclidean.threed.Vector3D(v(1), v(2), v(3));
    pv0 = org.orekit.utils.PVCoordinates(V3(r_i0), V3(v_i0));
    orbit0 = org.orekit.orbits.CartesianOrbit(pv0, frame, epoch, mu);
    integ = org.hipparchus.ode.nonstiff.DormandPrince853Integrator(1e-4, 60, 1e-9, 1e-12);
    np = org.orekit.propagation.numerical.NumericalPropagator(integ);
    np.setOrbitType(org.orekit.orbits.OrbitType.CARTESIAN);
    np.setInitialState(org.orekit.propagation.SpacecraftState(orbit0));
    if strcmp(modeName, 'j2')
        np.addForceModel(org.orekit.forces.gravity.J2OnlyPerturbation(mu, rEq, J2, frame));
    end
    harvester = np.setupMatricesComputation('stm', [], []);
    state1 = np.propagate(epoch.shiftedBy(dt));
    Phi = double(harvester.getStateTransitionMatrix(state1).getData());
end

function T = frameTransform6_(t_s)
    % Exact 6x6 inertial -> ECEF transform for a state [r; v], built by pushing the six
    % basis vectors through the sim's OWN frame utility. Linearity is verified rather
    % than assumed, so a change of frame convention cannot silently invalidate the STM
    % comparison.
    T = zeros(6,6);
    for k = 1:6
        e = zeros(6,1); e(k) = 1;
        [re, ve] = models.frames.FrameTimeUtils.inertialStateToEcef(e(1:3), e(4:6), t_s);
        T(:,k) = [re(:); ve(:)];
    end
    x = [1e7; -2e7; 3e6; 100; -200; 50];
    [rc, vc] = models.frames.FrameTimeUtils.inertialStateToEcef(x(1:3), x(4:6), t_s);
    assert(max(abs(T*x - [rc(:); vc(:)])) < 1e-6, ...
        'frame transform is not linear in the state -- the STM similarity transform is invalid');
end

function out = ternary_(cond, a, b)
    if cond; out = a; else; out = b; end
end
