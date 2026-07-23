% test_orekit_orbit_crossvalidation
%
% FIRST EXTERNAL cross-validation of the oo_v1 truth orbit propagator.
% Compares the sim's default J2 GEO truth (models.orbit.OrbitPropagator, mode
% 'j2Rk4') against Orekit 13.1.7 -- an independent, operationally-validated Java
% astrodynamics library (CNES/ESA) -- fed the IDENTICAL initial ECI state,
% gravity constants (GM, Re, J2 from revgnss.Constants) and force model
% (two-body + J2 zonal).
%
% Why this is a clean, exact comparison:
%   The default truth is J2-ZONAL only, integrated in ECI, mapped to ECEF by a
%   pure rotZ(-omega*t) with epochGMST=0. A zonal (C20-only) field is symmetric
%   about the Z axis, so the Earth-rotation phase does NOT enter the dynamics --
%   the whole IERS/EOP frame realization drops out and only pole (Z) alignment
%   matters. We therefore give Orekit the same Cartesian state in an inertial
%   frame (GCRF as the abstract ECI container) and reference J2 to that same
%   frame, reproducing the sim's idealized world with no EOP dependence.
%
% Two comparisons over a 1 h GEO arc, in ECI position (|dr| is rotation-invariant
% so it is identical in ECI and ECEF):
%   A  matched fixed-step RK4 (Orekit ClassicalRungeKutta @ the sim's step)
%      -> the two truncation errors cancel; residual = rounding only, proving the
%         FORCE-MODEL IMPLEMENTATION is identical.
%   B  independent adaptive DP853 (tight) -> residual = the sim's RK4 truncation
%      error, proving the step choice is adequate.
%
% Constant map (asserted): sim revgnss.Constants == Orekit Constants.WGS84_*
%   GM  3.986004418e14, Req 6378137.0; J2 1.08262668e-3 -> Orekit +J2 (see note).
%
% REQUIREMENTS / SKIP: needs a JVM-enabled MATLAB (run via `matlab -batch`, NOT
% the -nojvm MCP session) and the Orekit bridge at ~/orekit-bridge (jars in
% lib/, orekit-data in data/orekit-data-main). If either is absent the test
% SKIPS (prints why and returns) so it never fails a bridge-less CI checkout.

fprintf('test_orekit_orbit_crossvalidation\n');

% ---------------------------------------------------------------------------
% Bridge locations + skip guards
% ---------------------------------------------------------------------------
libDir  = fullfile(getenv('HOME'), 'orekit-bridge', 'lib');
dataDir = fullfile(getenv('HOME'), 'orekit-bridge', 'data', 'orekit-data-main');

if ~usejava('jvm')
    fprintf(['SKIP: no JVM in this MATLAB session. Run via `matlab -batch` ' ...
             '(JVM on) rather than a -nojvm session.\n']);
    return
end
if ~isfolder(libDir) || isempty(dir(fullfile(libDir, '*.jar'))) || ~isfolder(dataDir)
    fprintf(['SKIP: Orekit bridge not installed.\n' ...
             '      Expected jars in %s\n      and orekit-data in %s\n'], libDir, dataDir);
    return
end

% ---------------------------------------------------------------------------
% Put the sim (+models, +revgnss packages) on the path
% ---------------------------------------------------------------------------
here      = fileparts(mfilename('fullpath'));
oo_v1Root = fileparts(here);
addpath(oo_v1Root);

% ---------------------------------------------------------------------------
% Load Orekit jars + orekit-data
% ---------------------------------------------------------------------------
jars = dir(fullfile(libDir, '*.jar'));
for k = 1:numel(jars); javaaddpath(fullfile(libDir, jars(k).name)); end
dpm = org.orekit.data.DataContext.getDefault().getDataProvidersManager();
dpm.addProvider(org.orekit.data.DirectoryCrawler(java.io.File(dataDir)));

% ---------------------------------------------------------------------------
% Constants: the sim is the reference; assert Orekit WGS-84 matches it
% ---------------------------------------------------------------------------
mu  = revgnss.Constants.EARTH_GM_M3PS2;
rEq = revgnss.Constants.EARTH_RADIUS_M;
J2  = revgnss.Constants.EARTH_J2;
mu_ore  = org.orekit.utils.Constants.WGS84_EARTH_MU;
rEq_ore = org.orekit.utils.Constants.WGS84_EARTH_EQUATORIAL_RADIUS;
assert(abs(mu  - mu_ore)  <= 1e3,  'GM sim vs Orekit WGS84 mismatch: %.9e vs %.9e', mu, mu_ore);
assert(abs(rEq - rEq_ore) <= 1e-3, 'Req sim vs Orekit WGS84 mismatch: %.4f vs %.4f', rEq, rEq_ore);
fprintf('Constants OK (sim == Orekit WGS-84): GM=%.9e  Req=%.1f  J2=%.8e\n', mu, rEq, J2);

% ---------------------------------------------------------------------------
% Sim default J2 truth propagator (elements = masterConfig GEO default)
% ---------------------------------------------------------------------------
oc = struct('altitudeMean_m', 35786000, 'inclination_rad', 0, 'raan_rad', 0, ...
            'trueAnomaly0_rad', 23*pi/180, 'epochGMST_rad', 0, 'mode', 'j2Rk4');
op = models.orbit.OrbitPropagator(oc);
[r0, v0] = op.initialEciState();          % t=0 ECI Cartesian IC -> Orekit gets the SAME state
omgE = revgnss.Constants.EARTH_OMEGA_RADPS;

% ---------------------------------------------------------------------------
% Arc + sampling
% ---------------------------------------------------------------------------
dur_s  = 3600;                            % 1 h GEO arc
step_s = 10;                              % 10 s grid -> sim RK4 sub-step = 10 s (nSub = 1)
tVec   = (0:step_s:dur_s)';
nT     = numel(tVec);

% Sim trajectory (ECEF) -> un-rotate to ECI. rotZ preserves |dr|, so the position
% difference magnitude is identical in ECI and ECEF; ECI is compared for clarity.
[rEcef_sim, ~] = op.propagate(tVec);
rEci_sim = zeros(3, nT);
for k = 1:nT
    th = oc.epochGMST_rad + omgE * tVec(k);
    Rz = [cos(th), -sin(th), 0; sin(th), cos(th), 0; 0, 0, 1];   % rotZ(+theta) = (ECI<-ECEF)
    rEci_sim(:, k) = Rz * rEcef_sim(:, k);
end

% ---------------------------------------------------------------------------
% Orekit initial orbit: same ECI Cartesian IC, same GM
% ---------------------------------------------------------------------------
frame = org.orekit.frames.FramesFactory.getGCRF();          % abstract inertial ECI container
utc   = org.orekit.time.TimeScalesFactory.getUTC();
epoch = org.orekit.time.AbsoluteDate(2026, 7, 23, 0, 0, 0.0, utc);  % arbitrary: J2-zonal is time-independent
pv0   = org.orekit.utils.PVCoordinates( ...
            org.hipparchus.geometry.euclidean.threed.Vector3D(r0(1), r0(2), r0(3)), ...
            org.hipparchus.geometry.euclidean.threed.Vector3D(v0(1), v0(2), v0(3)));
orbit0 = org.orekit.orbits.CartesianOrbit(pv0, frame, epoch, mu);
% Orekit J2OnlyPerturbation(mu, rEq, j2, frame): the 3rd argument is the POSITIVE
% J2 coefficient (empirically verified against the sim -- +J2 reproduces the truth
% to sub-mm, whereas passing the negative unnormalized C20 = -J2 flips the sign and
% doubles the J2 effect to 2 x 54.5 m over this 1 h arc).
j2coef = J2;

% ---------------------------------------------------------------------------
% Comparison A -- matched fixed-step RK4 (implementation equivalence)
% ---------------------------------------------------------------------------
integA = org.hipparchus.ode.nonstiff.ClassicalRungeKuttaIntegrator(step_s);
rEci_A = i_propagateOrekit(integA, mu, rEq, j2coef, frame, orbit0, epoch, tVec);
dA     = vecnorm(rEci_A - rEci_sim);                        % 1 x N  [m]

% ---------------------------------------------------------------------------
% Comparison B -- independent adaptive DP853, tight (truncation bound)
% ---------------------------------------------------------------------------
integB = org.hipparchus.ode.nonstiff.DormandPrince853Integrator(1e-3, 300, 1e-8, 1e-12);
rEci_B = i_propagateOrekit(integB, mu, rEq, j2coef, frame, orbit0, epoch, tVec);
dB     = vecnorm(rEci_B - rEci_sim);                        % 1 x N  [m]

rmsA = sqrt(mean(dA.^2));   rmsB = sqrt(mean(dB.^2));       % avoid Signal Toolbox rms()

% ---------------------------------------------------------------------------
% Report
% ---------------------------------------------------------------------------
fprintf('\nGEO J2 truth vs Orekit 13.1.7  (%d s arc, %d s grid, %d pts)\n', dur_s, step_s, nT);
fprintf('  A  matched RK4@%ds : max|dr|=%.3e m   rms=%.3e m   final=%.3e m\n', step_s, max(dA), rmsA, dA(end));
fprintf('  B  DP853 tight     : max|dr|=%.3e m   rms=%.3e m   final=%.3e m\n', max(dB), rmsB, dB(end));

% ---------------------------------------------------------------------------
% Optional diff plot (non-fatal)
% ---------------------------------------------------------------------------
try
    f = figure('Visible', 'off');
    plot(tVec/60, dA, '-', tVec/60, dB, '--', 'LineWidth', 1.3);
    grid on; xlabel('time [min]'); ylabel('|\Deltar|  ECI position [m]');
    legend('A: matched RK4 (impl. equivalence)', 'B: DP853 tight (independent)', 'Location', 'northwest');
    title('oo\_v1 J2 GEO truth vs Orekit 13.1.7');
    outPng = fullfile(oo_v1Root, 'output', 'orekit_orbit_crossvalidation.png');
    exportgraphics(f, outPng, 'Resolution', 130); close(f);
    fprintf('  diff plot written: %s\n', outPng);
catch plotErr
    fprintf('  (plot skipped: %s)\n', plotErr.message);
end

% ---------------------------------------------------------------------------
% Assertions -- ceilings ~3 orders above the observed agreement: robust across
% platforms yet still catch any real regression (a sign/frame/constant error is
% metres..km -- e.g. the +/-J2 sign flip is 2 x 54.5 m, 6 orders over tolA).
%   Observed (MATLAB R2025b + Orekit 13.1.7, this arc):
%     A matched RK4  ~1.5e-8 m (15 nm)     -> force-model implementation identical
%     B DP853 tight  ~1.6e-7 m (0.16 um)   -> sim RK4@10s truncation over 1 h
% ---------------------------------------------------------------------------
tolA = 1e-5;   % [m] matched-RK4 rounding ceiling (implementation equivalence)
tolB = 1e-4;   % [m] independent-integrator dynamics ceiling
assert(max(dA) < tolA, ...
    'A FAIL: matched-RK4 max|dr|=%.3e m > %.1e m -- force-model implementation differs.', max(dA), tolA);
assert(max(dB) < tolB, ...
    'B FAIL: DP853 max|dr|=%.3e m > %.1e m -- dynamics disagree with the independent tool.', max(dB), tolB);

fprintf('\ntest_orekit_orbit_crossvalidation: PASS -- sim J2 GEO truth matches Orekit 13.1.7.\n');

% ===========================================================================
% Local functions
% ===========================================================================
function rEci = i_propagateOrekit(integ, mu, rEq, j2coef, frame, orbit0, epoch, tVec)
    % Build a numerical propagator (central Newtonian auto-added) + J2-only, and
    % return the ECI position at each tVec epoch as a 3 x N matrix [m].
    j2f = org.orekit.forces.gravity.J2OnlyPerturbation(mu, rEq, j2coef, frame);
    np  = org.orekit.propagation.numerical.NumericalPropagator(integ);
    np.setOrbitType(org.orekit.orbits.OrbitType.CARTESIAN);
    np.setInitialState(org.orekit.propagation.SpacecraftState(orbit0));
    np.addForceModel(j2f);
    nT   = numel(tVec);
    rEci = zeros(3, nT);
    for k = 1:nT
        stk = np.propagate(epoch.shiftedBy(tVec(k)));
        p   = stk.getPVCoordinates(frame).getPosition();
        rEci(:, k) = [p.getX(); p.getY(); p.getZ()];
    end
end
