% test_orekit_shapiro_sagnac_crossvalidation
%
% TIER 3 (delay layer, part 3 of N) -- the deterministic range corrections in
% models.corrections.RangeCorrections: the relativistic Shapiro path delay and the
% Earth-rotation (Sagnac) correction, vs Orekit 13.1.7.
%
%   PART A -- Shapiro: sim shapiroDelayMeters = 2*GM/c^2 * ln((rr+rt+R)/(rr+rt-R))
%     (Moyer / IERS closed form) vs the same closed form evaluated with Orekit's
%     WGS-84 GM and speed of light. Shapiro is frame-free (three scalar distances only)
%     and has no model ambiguity, so this validates the sim's formula + constants.
%     (Orekit's ShapiroRangeModifier(GM) implements the identical closed form; extracting
%     its value needs the full estimation framework, so we check the closed form directly.)
%
%   PART B -- Sagnac: the sim's FIRST-ORDER uplink Sagnac (instantaneous range +
%     (omega/c)*(tx_x*rx_y - tx_y*rx_x)) vs Orekit's RIGOROUS one-way light-time
%     (AbstractMeasurement.signalTimeOfFlightAdjustableEmitter, emitter = tower with ECI
%     position+velocity = omega x r, receiver = satellite at the receive epoch). This
%     needs NO custom frame -- the tower's rotation enters through its ECI velocity. The
%     rigorous light-time is additionally cross-checked against an independent exact
%     iterative solver (tower fixed in ECEF, rotated by omega*tau).
%
% RESULT (MATLAB R2025b + Orekit 13.1.7): GM and c match Orekit's WGS-84 exactly; Shapiro
% ~17-23 mm at GEO, byte-identical to the IERS form (max |d| = 0). Sagnac 0-64 m; the sim's
% first-order approximation matches Orekit's rigorous light-time to <= 0.3 mm (adequate at
% GEO), and Orekit's light-time matches the exact iterative solver to ~nm (reference
% confirmed two independent ways).
%
% REQUIREMENTS / SKIP: JVM-enabled MATLAB (`matlab -batch`, not the -nojvm MCP session)
% + the Orekit bridge at ~/orekit-bridge. Skips cleanly if absent.

fprintf('test_orekit_shapiro_sagnac_crossvalidation\n');

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

mu = revgnss.Constants.EARTH_GM_M3PS2;   c  = revgnss.Constants.SPEED_OF_LIGHT_MPS;
Re = revgnss.Constants.EARTH_RADIUS_M;   om = revgnss.Constants.EARTH_OMEGA_RADPS;
rGeo = 42164137.0;
cfg.physics = struct('muEarth_m3ps2', mu, 'c_mps', c, 'omegaEarth_radps', om);
frame = org.orekit.frames.FramesFactory.getGCRF();
epoch = org.orekit.time.AbsoluteDate.J2000_EPOCH;
V3 = @(v) org.hipparchus.geometry.euclidean.threed.Vector3D(v(1), v(2), v(3));

% Constants must match Orekit (Shapiro + Sagnac both scale with GM/c and omega)
assert(abs(mu - org.orekit.utils.Constants.WGS84_EARTH_MU) <= 1e3, 'GM mismatch sim vs Orekit');
assert(abs(c  - org.orekit.utils.Constants.SPEED_OF_LIGHT)  <= 1e-6, 'c mismatch sim vs Orekit');
fprintf('Constants OK: GM=%.6e  c=%.4f  (== Orekit WGS-84)\n', mu, c);

seps = [0 10 20 40 60 80];

% ===========================================================================
% PART A -- Shapiro (frame-free): sim vs IERS closed form (Orekit GM/c)
% ===========================================================================
fprintf('\n== PART A: Shapiro delay  sim vs IERS 2GM/c^2 ln(...) ==\n');
fprintf('  sep[deg]  R[km]    shap(sim)[mm]  shap(ref)[mm]    d[mm]\n');
dShapMax = 0;
for sep = seps
    T = [Re; 0; 0];                                   % tower (equator, lon 0)
    S = rGeo*[cosd(sep); sind(sep); 0];               % GEO sat, sep deg away in-plane
    rr = norm(S); rt = norm(T); R = norm(S - T);
    shap_sim = models.corrections.RangeCorrections.shapiroDelayMeters(S, T, cfg);
    shap_ref = (2*mu/c^2) * log((rr+rt+R)/(rr+rt-R));
    dShapMax = max(dShapMax, abs(shap_sim - shap_ref));
    fprintf('  %6d  %7.0f   %10.4f   %10.4f   %8.1e\n', sep, R/1000, 1000*shap_sim, 1000*shap_ref, 1000*(shap_sim-shap_ref));
end
fprintf('  max |d Shapiro| = %.3e m\n', dShapMax);

% ===========================================================================
% PART B -- Sagnac: sim first-order vs Orekit rigorous light-time vs exact solver
% ===========================================================================
fprintf('\n== PART B: one-way uplink Sagnac  sim 1st-order vs Orekit light-time ==\n');
fprintf('  sep[deg]  sagnac[m]  d(sim-ore)[m]  d(ore-exact)[m]\n');
dSagMax = 0; dRefMax = 0; sagMax = 0;
for sep = seps
    T  = [Re; 0; 0];                                  % tower ECI at t=0 (GMST=0 -> ECI=ECEF)
    S  = rGeo*[cosd(sep); sind(sep); 0];              % sat ECI at the receive epoch
    vT = cross([0;0;om], T);                          % tower ECI velocity = omega x r
    aT = cross([0;0;om], vT);                         % centripetal acceleration
    % sim: instantaneous range + first-order Sagnac (rx = sat, tx = tower)
    rhoInst  = norm(S - T);
    sag      = (om/c)*(T(1)*S(2) - T(2)*S(1));
    simRange = rhoInst + sag;
    % Orekit rigorous light-time (emitter = tower adjusted, receiver = sat @ epoch)
    try
        pvT = org.orekit.utils.TimeStampedPVCoordinates(epoch, V3(T), V3(vT), V3(aT));
    catch
        pvT = org.orekit.utils.TimeStampedPVCoordinates(epoch, V3(T), V3(vT));
    end
    tau = org.orekit.estimation.measurements.AbstractMeasurement.signalTimeOfFlightAdjustableEmitter(pvT, V3(S), epoch, frame);
    oreRange = c*tau;
    % independent exact iterative light-time (tower fixed in ECEF, rotates at omega)
    tau2 = rhoInst/c;
    for it = 1:8
        th = -om*tau2; Rz = [cos(th) -sin(th) 0; sin(th) cos(th) 0; 0 0 1];
        tau2 = norm(S - Rz*T)/c;
    end
    exactRange = c*tau2;
    dSagMax = max(dSagMax, abs(simRange - oreRange));
    dRefMax = max(dRefMax, abs(oreRange - exactRange));
    sagMax  = max(sagMax, abs(sag));
    fprintf('  %6d  %8.3f  %12.2e  %14.2e\n', sep, sag, simRange-oreRange, oreRange-exactRange);
end
fprintf('  Sagnac magnitude up to %.1f m; first-order approx err (sim vs Orekit) = %.3e m; Orekit vs exact = %.3e m\n', ...
    sagMax, dSagMax, dRefMax);

% ---------------------------------------------------------------------------
% Assertions.
%   A: Shapiro is a fixed IERS formula -> sim reproduces it exactly (observed 0). 1e-6 m.
%   B: Sagnac magnitude must be real (>10 m, so the approximation is being exercised);
%      the sim's first-order approximation vs Orekit's rigorous light-time must be sub-mm
%      at GEO (observed 0.28 mm); and Orekit's light-time must match the independent exact
%      solver to ~nm (confirms the rigorous reference).
% ---------------------------------------------------------------------------
assert(dShapMax < 1e-6, 'A FAIL: Shapiro max |d| %.3e m > 1e-6 (formula/constants differ)', dShapMax);
assert(sagMax   > 10,   'B FAIL: Sagnac magnitude %.2f m < 10 m -- geometry not exercising it', sagMax);
assert(dSagMax  < 2e-3, 'B FAIL: first-order Sagnac vs Orekit %.3e m > 2 mm (approximation inadequate?)', dSagMax);
assert(dRefMax  < 1e-5, 'B FAIL: Orekit light-time vs exact solver %.3e m > 1e-5 (reference disagreement)', dRefMax);

fprintf('\ntest_orekit_shapiro_sagnac_crossvalidation: PASS -- Shapiro exact; first-order Sagnac sub-mm vs Orekit rigorous light-time.\n');
