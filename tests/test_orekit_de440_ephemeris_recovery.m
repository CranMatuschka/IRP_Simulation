% test_orekit_de440_ephemeris_recovery
%
% Prototype validation for the gated DE-440 truth ephemeris
% (cfg.perturbations.sunMoon.ephemeris = 'de440', backend models.orbit.De440Ephemeris).
% Tier 2 (test_orekit_lunisolar_srp_crossvalidation) showed the sim's Montenbruck & Gill
% analytic Sun/Moon leaves a ~0.6 m / 4 h luni-solar truth-fidelity gap vs Orekit DE-440.
% This test measures how much of that gap switching the sim to DE-440 recovers.
%
%   PART A -- backend: models.orbit.De440Ephemeris.sunEci/moonEci vs Orekit DE-440 direct
%     (both are DE-440) -> byte-identical, confirming the helper is a faithful DE-440 read.
%   PART B -- trajectory: the sim's own J2+luni-solar truth, propagated with ephemeris 'mg'
%     vs 'de440', each compared to the SAME Orekit DE-440 reference over a 4 h GEO arc:
%       gap('mg')    reproduces the Tier-2 ~0.6 m ephemeris gap;
%       gap('de440') collapses it to ~tens of um (residual = the ~1e-8 GM difference and
%                    the RK4-vs-DP853 integrator, both established sub-mm in Tiers 1-2),
%     i.e. DE-440 recovers essentially all of the M&G ephemeris gap -> the sim's luni-solar
%     FORCE model is exact and M&G is the sole truth-fidelity loss.
%
% REQUIREMENTS / SKIP: JVM-enabled MATLAB (`matlab -batch`, not the -nojvm MCP session) +
% the Orekit bridge at ~/orekit-bridge (De440Ephemeris reads DE-440 through it). Skips cleanly.

fprintf('test_orekit_de440_ephemeris_recovery\n');

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

jars = dir(fullfile(libDir, '*.jar'));
for k = 1:numel(jars); javaaddpath(fullfile(libDir, jars(k).name)); end
dpm = org.orekit.data.DataContext.getDefault().getDataProvidersManager();
dpm.addProvider(org.orekit.data.DirectoryCrawler(java.io.File(dataDir)));

mu   = revgnss.Constants.EARTH_GM_M3PS2;   rEq = revgnss.Constants.EARTH_RADIUS_M;
J2   = revgnss.Constants.EARTH_J2;         omgE = revgnss.Constants.EARTH_OMEGA_RADPS;
epochJD = 2451545.0;                                       % J2000.0 (TT)
frame = org.orekit.frames.FramesFactory.getEME2000();
epoch = org.orekit.time.AbsoluteDate.J2000_EPOCH;
sun   = org.orekit.bodies.CelestialBodyFactory.getSun();
moon  = org.orekit.bodies.CelestialBodyFactory.getMoon();
V3    = @(v) org.hipparchus.geometry.euclidean.threed.Vector3D(v(1), v(2), v(3));

% ===========================================================================
% PART A -- De440Ephemeris backend vs Orekit DE-440 direct (both DE-440 -> ~0)
% ===========================================================================
% Compare at the SAME instant the backend derives from jd, so this isolates the DE-440
% READ (the jd<->date round-trip has a ~40 us floor from representing the epoch as a large
% Julian Date -- a property of the jd interface shared with M&G, negligible for the
% trajectory as Part B's 15 um confirms).
fprintf('\n== PART A: De440Ephemeris backend vs Orekit DE-440 at the same jd (EME2000) ==\n');
dSunMax = 0; dMoonMax = 0;
for dOff = [0 30 180 3600]                                 % sample jd offsets over the arc
    jd = epochJD + dOff/86400;
    dk = epoch.shiftedBy((jd - epochJD)*86400);            % the instant sunEci/moonEci derive from jd
    s_h = models.orbit.De440Ephemeris.sunEci(jd);   ps = sun.getPosition(dk, frame);
    m_h = models.orbit.De440Ephemeris.moonEci(jd);  pm = moon.getPosition(dk, frame);
    dSunMax  = max(dSunMax,  norm(s_h - [ps.getX();ps.getY();ps.getZ()]));
    dMoonMax = max(dMoonMax, norm(m_h - [pm.getX();pm.getY();pm.getZ()]));
end
fprintf('  max |De440Ephemeris - Orekit| : Sun %.3e m   Moon %.3e m (faithful DE-440 read)\n', dSunMax, dMoonMax);

% ===========================================================================
% PART B -- luni-solar trajectory: sim ('mg' vs 'de440') vs Orekit DE-440
% ===========================================================================
ocBase = struct('altitudeMean_m', 35786000, 'inclination_rad', 0, 'raan_rad', 0, ...
                'trueAnomaly0_rad', 23*pi/180, 'epochGMST_rad', 0, 'mode', 'j2Rk4');
mkPert = @(eph) struct('epochJD_TT', epochJD, 'luniSolar', struct('enable', true), ...
                       'srp', struct('enable', false), 'ephemeris', eph);
ocMG = ocBase; ocMG.truth.perturbations = mkPert('mg');
ocDE = ocBase; ocDE.truth.perturbations = mkPert('de440');
opMG = models.orbit.OrbitPropagator(ocMG);
opDE = models.orbit.OrbitPropagator(ocDE);
[r0, v0] = opMG.initialEciState();

dur_s = 14400;  step_s = 60;  tVec = (0:step_s:dur_s)';   % 4 h
simMG = i_unrot(opMG.propagate(tVec), tVec, omgE);
simDE = i_unrot(opDE.propagate(tVec), tVec, omgE);

% Orekit reference: J2 + DE-440 Sun/Moon third-body, same IC/epoch/frame
pv0    = org.orekit.utils.PVCoordinates(V3(r0), V3(v0));
orbit0 = org.orekit.orbits.CartesianOrbit(pv0, frame, epoch, mu);
oreLS  = i_propOreLS(mu, rEq, J2, sun, moon, frame, orbit0, epoch, tVec);

gapMG = max(vecnorm(simMG - oreLS));
gapDE = max(vecnorm(simDE - oreLS));
effLS = max(vecnorm(simMG - i_unrot(models.orbit.OrbitPropagator(ocBase).propagate(tVec), tVec, omgE)));
recovery = 100 * (1 - gapDE/gapMG);
fprintf('\n== PART B: luni-solar sim vs Orekit DE-440 (max |dr| over 4 h; effect %.1f m) ==\n', effLS);
fprintf('  ephemeris ''mg''    : %8.4f m   (reproduces the Tier-2 M&G ephemeris gap)\n', gapMG);
fprintf('  ephemeris ''de440'' : %8.3e m   (%.3f%% of the M&G gap recovered)\n', gapDE, recovery);

% ---------------------------------------------------------------------------
% Assertions
%   A: the backend is a faithful DE-440 read (matches Orekit DE-440 to ~0).
%   B: 'mg' reproduces the ~0.6 m gap; 'de440' collapses it to << 1 cm (tens of um from
%      the ~1e-8 GM difference + RK4/DP853), i.e. >99% of the M&G gap recovered.
% ---------------------------------------------------------------------------
assert(dSunMax  < 1e-6 && dMoonMax < 1e-6, 'A FAIL: backend vs Orekit DE-440 Sun %.3e / Moon %.3e m (not a faithful read)', dSunMax, dMoonMax);
assert(gapMG > 0.3 && gapMG < 1.0, 'B FAIL: mg gap %.4f m outside the expected ~0.6 m band', gapMG);
assert(gapDE < 1e-2, 'B FAIL: de440 gap %.3e m > 1 cm -- DE-440 did not recover the ephemeris gap', gapDE);
assert(recovery > 99, 'B FAIL: recovery %.2f%% < 99%%', recovery);

fprintf('\ntest_orekit_de440_ephemeris_recovery: PASS -- DE-440 recovers %.2f%% of the M&G luni-solar gap (%.2f m -> %.1e m).\n', ...
    recovery, gapMG, gapDE);

% ===========================================================================
% Local functions
% ===========================================================================
function rEci = i_unrot(rEcef, tVec, omgE)
    nT = numel(tVec); rEci = zeros(3, nT);
    for k = 1:nT
        th = omgE*tVec(k);
        Rz = [cos(th), -sin(th), 0; sin(th), cos(th), 0; 0, 0, 1];
        rEci(:, k) = Rz * rEcef(:, k);
    end
end

function rEci = i_propOreLS(mu, rEq, J2, sun, moon, frame, orbit0, epoch, tVec)
    % J2 (+J2 convention) + DE-440 Sun/Moon third-body, DP853, sampled at tVec.
    integ = org.hipparchus.ode.nonstiff.DormandPrince853Integrator(1e-3, 300, 1e-7, 1e-11);
    np = org.orekit.propagation.numerical.NumericalPropagator(integ);
    np.setOrbitType(org.orekit.orbits.OrbitType.CARTESIAN);
    np.setInitialState(org.orekit.propagation.SpacecraftState(orbit0));
    np.addForceModel(org.orekit.forces.gravity.J2OnlyPerturbation(mu, rEq, J2, frame));
    np.addForceModel(org.orekit.forces.gravity.ThirdBodyAttraction(sun));
    np.addForceModel(org.orekit.forces.gravity.ThirdBodyAttraction(moon));
    nT = numel(tVec); rEci = zeros(3, nT);
    for k = 1:nT
        stk = np.propagate(epoch.shiftedBy(tVec(k)));
        p = stk.getPVCoordinates(frame).getPosition();
        rEci(:, k) = [p.getX(); p.getY(); p.getZ()];
    end
end
