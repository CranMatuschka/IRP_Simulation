% test_orekit_lunisolar_srp_crossvalidation
%
% TIER 2 external cross-validation: the sim's realism-grade TRUTH perturbations
% (Sun+Moon third-body + cannonball SRP, models.orbit.OrbitPerturbations, enabled
% by cfg.orbit.truth.perturbations.*) vs Orekit 13.1.7 with DE-440 ephemerides.
%
% Unlike Tier 1 (test_orekit_orbit_crossvalidation, a byte-level J2 check), this is
% a genuine PHYSICS / FIDELITY comparison: the sim places the Sun and Moon with the
% Montenbruck & Gill (2000) low-precision ANALYTIC series, whereas Orekit uses the
% JPL DE-440 numerical ephemeris. The trajectory difference is therefore expected to
% be non-zero and is dominated by that ephemeris-model gap -- which is exactly what we
% quantify. Frames align cleanly: the sim's "J2000 mean-equator ECI" == Orekit EME2000,
% epochJD_TT = 2451545.0 == AbsoluteDate.J2000_EPOCH, so no EOP enters.
%
% PART A -- ephemeris fidelity: sim M&G Sun/Moon vs Orekit DE-440 (EME2000), over 4 h.
%   Reports the angular + range error. This is the physical source of the Part-B gap.
% PART B -- trajectory, per-effect breakdown (same IC/epoch, sim RK4 vs Orekit DP853):
%   J2-only            : re-confirms the Tier-1 bridge (~95 nm; force + integrator).
%   J2 + luni-solar    : sim vs DE-440 = the M&G-vs-DE fidelity, tiny vs the effect.
%   J2 + luni-solar+SRP : + cannonball(sim) vs isotropic(Orekit) SRP, matched Cr/A-m/pRef.
%
% RESULT (MATLAB R2025b + Orekit 13.1.7, this arc): Sun 12", Moon 17"; J2 95 nm;
% luni-solar 0.61 m out of a 647 m effect (~0.09% -> force model correct, M&G adequate);
% +SRP leaves the gap at 0.61 m (SRP effect 13 m cancels -> cannonball==isotropic sub-mm,
% no eclipse at J2000). Confirms OrbitPerturbations.m's "M&G adequate for <=4 h" claim.
%
% Matched physical parameters (sim -> Orekit): GM_sun/GM_moon agree to ~1e-8 (DE-440);
% SRP pRef 4.56e-6 N/m2 @ 1 AU, Cr 1.3, A/m 0.02 m2/kg; Earth shadow = sphere (flattening
% 0) in EME2000 so occultation stays frame/EOP-independent like the sim's cylinder.
%
% REQUIREMENTS / SKIP: JVM-enabled MATLAB (run via `matlab -batch`, not the -nojvm MCP
% session) + the Orekit bridge at ~/orekit-bridge. Skips cleanly if absent.

fprintf('test_orekit_lunisolar_srp_crossvalidation\n');

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

jars = dir(fullfile(libDir, '*.jar'));
for k = 1:numel(jars); javaaddpath(fullfile(libDir, jars(k).name)); end
dpm = org.orekit.data.DataContext.getDefault().getDataProvidersManager();
dpm.addProvider(org.orekit.data.DirectoryCrawler(java.io.File(dataDir)));

% ---------------------------------------------------------------------------
% Constants + matched perturbation parameters
% ---------------------------------------------------------------------------
mu   = revgnss.Constants.EARTH_GM_M3PS2;
rEq  = revgnss.Constants.EARTH_RADIUS_M;
J2   = revgnss.Constants.EARTH_J2;
omgE = revgnss.Constants.EARTH_OMEGA_RADPS;
AU   = 1.495978707e11;   pRef = 4.56e-6;   Cr = 1.3;   AoM = 0.02;   % OrbitPerturbations defaults
epochJD = 2451545.0;                                                  % J2000.0 (TT) = the sim default

% ---------------------------------------------------------------------------
% Sim truth propagators: J2, J2+luni-solar, J2+luni-solar+SRP
% ---------------------------------------------------------------------------
ocBase = struct('altitudeMean_m', 35786000, 'inclination_rad', 0, 'raan_rad', 0, ...
                'trueAnomaly0_rad', 23*pi/180, 'epochGMST_rad', 0, 'mode', 'j2Rk4');
ocLS = ocBase;
ocLS.truth.perturbations = struct('epochJD_TT', epochJD, ...
    'luniSolar', struct('enable', true), 'srp', struct('enable', false));
ocFull = ocBase;
ocFull.truth.perturbations = struct('epochJD_TT', epochJD, ...
    'luniSolar', struct('enable', true), ...
    'srp', struct('enable', true, 'Cr', Cr, 'areaToMass_m2pkg', AoM, 'shadow', 'cylindrical'));

opBase = models.orbit.OrbitPropagator(ocBase);
opLS   = models.orbit.OrbitPropagator(ocLS);
opFull = models.orbit.OrbitPropagator(ocFull);
[r0, v0] = opBase.initialEciState();

dur_s = 14400;  step_s = 60;  tVec = (0:step_s:dur_s)';  nT = numel(tVec);   % 4 h
simBase = i_unrot(opBase.propagate(tVec), tVec, omgE);
simLS   = i_unrot(opLS.propagate(tVec),   tVec, omgE);
simFull = i_unrot(opFull.propagate(tVec), tVec, omgE);

% ---------------------------------------------------------------------------
% Orekit setup (EME2000 inertial container; sphere occulter -> frame-independent shadow)
% ---------------------------------------------------------------------------
frame  = org.orekit.frames.FramesFactory.getEME2000();
epoch  = org.orekit.time.AbsoluteDate.J2000_EPOCH;
sun    = org.orekit.bodies.CelestialBodyFactory.getSun();
moon   = org.orekit.bodies.CelestialBodyFactory.getMoon();
earth  = org.orekit.bodies.OneAxisEllipsoid(rEq, 0.0, frame);
pv0    = org.orekit.utils.PVCoordinates( ...
             org.hipparchus.geometry.euclidean.threed.Vector3D(r0(1), r0(2), r0(3)), ...
             org.hipparchus.geometry.euclidean.threed.Vector3D(v0(1), v0(2), v0(3)));
orbit0 = org.orekit.orbits.CartesianOrbit(pv0, frame, epoch, mu);

% ===========================================================================
% PART A -- Sun/Moon ephemeris: sim M&G vs Orekit DE-440 (EME2000)
% ===========================================================================
sunAng = zeros(nT,1); sunDist = zeros(nT,1); moonAng = zeros(nT,1); moonDist = zeros(nT,1);
sNorm = 0; mNorm = 0;
for k = 1:nT
    jd   = epochJD + tVec(k)/86400;
    s_mg = models.orbit.OrbitPerturbations.sunPositionEci(jd);
    m_mg = models.orbit.OrbitPerturbations.moonPositionEci(jd);
    dk   = epoch.shiftedBy(tVec(k));
    ps = sun.getPosition(dk, frame);   s_de = [ps.getX(); ps.getY(); ps.getZ()];
    pm = moon.getPosition(dk, frame);  m_de = [pm.getX(); pm.getY(); pm.getZ()];
    sunAng(k)   = acosd(dot(s_mg, s_de)/(norm(s_mg)*norm(s_de)));
    moonAng(k)  = acosd(dot(m_mg, m_de)/(norm(m_mg)*norm(m_de)));
    sunDist(k)  = norm(s_mg) - norm(s_de);
    moonDist(k) = norm(m_mg) - norm(m_de);
    sNorm = norm(s_de); mNorm = norm(m_de);
end
fprintf('\n== PART A: Sun/Moon ephemeris  M&G vs Orekit DE-440 (EME2000, %d h) ==\n', dur_s/3600);
fprintf('  Sun : max ang %.4f deg (%.0f arcsec) | max |Drange| %.3e m (%.4f%%)\n', ...
    max(abs(sunAng)),  max(abs(sunAng))*3600,  max(abs(sunDist)),  100*max(abs(sunDist))/sNorm);
fprintf('  Moon: max ang %.4f deg (%.0f arcsec) | max |Drange| %.3e m (%.4f%%)\n', ...
    max(abs(moonAng)), max(abs(moonAng))*3600, max(abs(moonDist)), 100*max(abs(moonDist))/mNorm);

% ===========================================================================
% PART B -- trajectory: sim (M&G + cannonball SRP) vs Orekit (DE-440 + isotropic SRP)
% ===========================================================================
oreBase = i_propOre(struct('ls',false,'srp',false), mu,rEq,J2,sun,moon,earth,AU,pRef,Cr,AoM,frame,orbit0,epoch,tVec);
oreLS   = i_propOre(struct('ls',true, 'srp',false), mu,rEq,J2,sun,moon,earth,AU,pRef,Cr,AoM,frame,orbit0,epoch,tVec);
oreFull = i_propOre(struct('ls',true, 'srp',true ), mu,rEq,J2,sun,moon,earth,AU,pRef,Cr,AoM,frame,orbit0,epoch,tVec);

dBase = vecnorm(oreBase - simBase);   dLS = vecnorm(oreLS - simLS);   dFull = vecnorm(oreFull - simFull);
effLS  = vecnorm(simLS   - simBase);  % sim's own luni-solar effect over the arc
effSRP = vecnorm(simFull - simLS);    % sim's own SRP effect over the arc

fprintf('\n== PART B: trajectory sim vs Orekit (max |dr| over %d h) ==\n', dur_s/3600);
fprintf('  J2 only             : %.3e m      (re-confirms Tier-1 bridge)\n', max(dBase));
fprintf('  J2 + luni-solar     : %8.3f m  of a %.1f m effect  (%.3f%% -> force model OK, M&G source)\n', ...
    max(dLS), max(effLS), 100*max(dLS)/max(effLS));
fprintf('  J2 + luni-solar+SRP : %8.3f m  (sim SRP effect %.2f m; unchanged => SRP models agree sub-mm)\n', ...
    max(dFull), max(effSRP));

% ---------------------------------------------------------------------------
% Optional diff plot (non-fatal)
% ---------------------------------------------------------------------------
try
    f = figure('Visible', 'off');
    plot(tVec/3600, dLS, '-', tVec/3600, dFull, '--', 'LineWidth', 1.3); grid on;
    xlabel('time [h]'); ylabel('|\Deltar|  sim vs Orekit  [m]');
    legend('J2 + luni-solar', 'J2 + luni-solar + SRP', 'Location', 'northwest');
    title(sprintf('Tier 2: luni-solar+SRP truth vs Orekit DE-440 (effect %.0f m -> gap %.2f m)', max(effLS), max(dFull)));
    outPng = fullfile(oo_v1Root, 'output', 'orekit_lunisolar_srp_crossvalidation.png');
    exportgraphics(f, outPng, 'Resolution', 130); close(f);
    fprintf('  diff plot written: %s\n', outPng);
catch plotErr
    fprintf('  (plot skipped: %s)\n', plotErr.message);
end

% ---------------------------------------------------------------------------
% Assertions. This is a fidelity comparison, not byte-level: the sim-vs-DE gap is
% the M&G ephemeris error and must stay tiny relative to the (hundreds-of-metre)
% effect. A force-model bug (sign/missing term) would be tens-to-hundreds of metres.
%   Observed: Sun 0.0034 deg, Moon 0.0048 deg; J2 9.5e-8 m; luni-solar 0.606 m of
%   647 m; +SRP 0.606 m (SRP effect 13.3 m).
% ---------------------------------------------------------------------------
assert(max(abs(sunAng))  < 0.02, 'A FAIL: Sun M&G vs DE ang %.4f deg > 0.02 (frame/ephemeris error)', max(abs(sunAng)));
assert(max(abs(moonAng)) < 0.02, 'A FAIL: Moon M&G vs DE ang %.4f deg > 0.02 (frame/ephemeris error)', max(abs(moonAng)));
assert(max(dBase) < 1e-4, 'B FAIL: J2 bridge %.3e m > 1e-4 m', max(dBase));
assert(max(effLS)  > 100, 'B FAIL: luni-solar effect %.1f m < 100 m -- perturbation not active?', max(effLS));
assert(max(effSRP) > 1,   'B FAIL: SRP effect %.2f m < 1 m -- SRP not active?', max(effSRP));
assert(max(dLS)   < 3.0, 'B FAIL: luni-solar sim vs DE %.3f m > 3 m -- force model differs from Orekit', max(dLS));
assert(max(dFull) < 3.0, 'B FAIL: luni-solar+SRP sim vs DE %.3f m > 3 m -- SRP or third-body differs', max(dFull));

fprintf('\ntest_orekit_lunisolar_srp_crossvalidation: PASS -- sim luni-solar+SRP truth matches Orekit DE-440 to sub-metre (M&G-limited).\n');

% ===========================================================================
% Local functions
% ===========================================================================
function rEci = i_unrot(rEcef, tVec, omgE)
    % Un-rotate the sim's ECEF output to ECI (rotZ preserves |dr|).
    nT = numel(tVec); rEci = zeros(3, nT);
    for k = 1:nT
        th = omgE*tVec(k);
        Rz = [cos(th), -sin(th), 0; sin(th), cos(th), 0; 0, 0, 1];
        rEci(:, k) = Rz * rEcef(:, k);
    end
end

function rEci = i_propOre(flags, mu, rEq, J2, sun, moon, earth, AU, pRef, Cr, AoM, frame, orbit0, epoch, tVec)
    % Numerical propagator: J2 (+ optional Sun/Moon third-body, + optional cannonball SRP).
    integ = org.hipparchus.ode.nonstiff.DormandPrince853Integrator(1e-3, 300, 1e-7, 1e-11);
    np = org.orekit.propagation.numerical.NumericalPropagator(integ);
    np.setOrbitType(org.orekit.orbits.OrbitType.CARTESIAN);
    st0 = org.orekit.propagation.SpacecraftState(orbit0);
    np.setInitialState(st0);
    np.addForceModel(org.orekit.forces.gravity.J2OnlyPerturbation(mu, rEq, J2, frame));   % +J2 (Tier-1 convention)
    if flags.ls
        np.addForceModel(org.orekit.forces.gravity.ThirdBodyAttraction(sun));    % DE-440 Sun
        np.addForceModel(org.orekit.forces.gravity.ThirdBodyAttraction(moon));   % DE-440 Moon
    end
    if flags.srp
        m    = st0.getMass();                                                    % area/mass = A/m regardless of m
        radm = org.orekit.forces.radiation.IsotropicRadiationSingleCoefficient(AoM*m, Cr);
        np.addForceModel(org.orekit.forces.radiation.SolarRadiationPressure(AU, pRef, sun, earth, radm));
    end
    nT = numel(tVec); rEci = zeros(3, nT);
    for k = 1:nT
        stk = np.propagate(epoch.shiftedBy(tVec(k)));
        p   = stk.getPVCoordinates(frame).getPosition();
        rEci(:, k) = [p.getX(); p.getY(); p.getZ()];
    end
end
