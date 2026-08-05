% test_orekit_composed_observable_crossvalidation
%
% LEVEL A -- the COMPOSED observable, vs Orekit 13.1.7.
%
% The six earlier Orekit tests each validate ONE model in isolation (orbit, Niell,
% Saastamoinen, Klobuchar, Shapiro, Sagnac, two-way/ISL). None of them exercises the
% ASSEMBLY: the order terms are stacked in, their signs, the per-signal dispersive
% scaling, and whether any term is double-counted on its way into z. That assembly is
% what this test drives -- through the real pipeline
% (revgnss.ScenarioFactory.build -> MeasurementModel.computeMeasurements), not a
% re-implementation of it.
%
% The sim composes a code row as (CodeMeasurementBuilder.build):
%
%     z = rho_true + b_rx - b_twr + truthTotal
%     rho_true = geometricRange(r_ant, tower_at_transmit) + sagnac + shapiro + pcv
%     truthTotal = trop + iono + ionoHO + hwDelay + dcb + mp + codeNoise + scint
%
% Starting from the "everything off" scenario (config/scenarios/ideal_G5S1R4_ts3600_flat.json)
% every term above is zero except the geometry and Shapiro, so each effect can be switched
% on ALONE and its contribution to z read off by differencing whole z vectors.
%
%   PART A1 -- geometry: sim z minus Shapiro (all else exactly zero) vs Orekit's rigorous
%     one-way uplink light-time (AbstractMeasurement.signalTimeOfFlightAdjustableEmitter,
%     emitter = tower with ECI pos + vel = omega x r, receiver = satellite antenna at the
%     receive epoch). NOTE the sim default is cfg.effects.lightTime.model = 'iterative',
%     i.e. it already solves light-time rather than applying a first-order Sagnac, so this
%     is a like-for-like rigorous-vs-rigorous comparison. Shapiro itself is checked against
%     the IERS closed form evaluated with Orekit's WGS-84 GM.
%
%   PART A2 -- troposphere: switch tropo on alone. The delta of the whole z vector must
%     equal the sim's own reported trop term exactly (composition), must be POSITIVE (a
%     delay lengthens a pseudorange), and must be frequency-INDEPENDENT (non-dispersive).
%     Under the realistic atmosphere (modelType 'localWeatherGM' + Niell mapping) the
%     delta is additionally compared against ZHD/ZWD mapped with Orekit's
%     NiellMappingFunctionModel, and against Orekit's ModifiedSaastamoinenModel fed the
%     sim's own surface pressure/temperature.
%
%   PART A3 -- ionosphere: switch iono on alone. Same composition and sign checks, plus
%     the dispersive scaling between the two code signals must be exactly (f_L1/f_L2)^2.
%     The obliquity that actually lands in z is compared against Orekit's IS-GPS-200
%     obliquity F = 1 + 16*(0.53 - E)^3.
%
%   PART A4 -- superposition: with tropo AND iono both on, the delta from the flat case
%     must equal the sum of the two individually measured deltas. This is the double-count
%     / cross-contamination check -- the one thing no single-model test can catch.
%
% REQUIREMENTS / SKIP: JVM-enabled MATLAB (`matlab -batch`, not the -nojvm MCP session)
% + the Orekit bridge at ~/orekit-bridge. Skips cleanly if absent.

fprintf('test_orekit_composed_observable_crossvalidation\n');

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

frame = org.orekit.frames.FramesFactory.getGCRF();   % abstract inertial container
epoch = org.orekit.time.AbsoluteDate.J2000_EPOCH;
utc   = org.orekit.time.TimeScalesFactory.getUTC();
V3    = @(v) org.hipparchus.geometry.euclidean.threed.Vector3D(v(1), v(2), v(3));

c   = revgnss.Constants.SPEED_OF_LIGHT_MPS;
mu  = revgnss.Constants.EARTH_GM_M3PS2;
om  = revgnss.Constants.EARTH_OMEGA_RADPS;
assert(abs(c  - org.orekit.utils.Constants.SPEED_OF_LIGHT) <= 1e-6, 'c mismatch sim vs Orekit');
assert(abs(mu - org.orekit.utils.Constants.WGS84_EARTH_MU) <= 1e3, 'GM mismatch sim vs Orekit');

FLAT = 'ideal_G5S1R4_ts3600_flat.json';

% ===========================================================================
% Baseline: everything off. z = geometry + Shapiro, nothing else.
% ===========================================================================
B = runVariant_(FLAT, @(cfg) cfg);
M = B.M;
fprintf('\nBaseline (all effects off): %d code rows, %d towers, %d signals\n', ...
    M, numel(B.towers), M/numel(B.towers));
assert(max(abs(B.es.truthTotal_m)) == 0, 'baseline truthTotal must be exactly 0 (got %.3e)', ...
    max(abs(B.es.truthTotal_m)));
assert(max(abs(B.es.towerClockTruth_m)) == 0, 'baseline tower clock must be exactly 0');
assert(B.b_rx == 0, 'baseline receiver clock must be exactly 0');
assert(max(abs(B.es.sagnacTruth_m)) == 0, ...
    'expected iterative light-time (sagnac term inactive); got sagnac up to %.3e m', ...
    max(abs(B.es.sagnacTruth_m)));

% ===========================================================================
% PART A1 -- geometry + Shapiro vs Orekit rigorous uplink light-time
% ===========================================================================
fprintf('\n== PART A1: composed geometry  sim vs Orekit rigorous light-time ==\n');
fprintf('  row twr  el[deg]  rho(sim)[m]      d(sim-ore)[m]  shapiro[mm]  d shap[m]\n');
dGeoMax = 0; dShapMax = 0; dTotMax = 0;
for mi = 1:M
    ti = B.es.towerIdx_perMeas(mi);
    rt = B.towerPos(:,ti);
    rs = B.satAnt(:, B.es.antennaIdx_perMeas(mi));

    % sim geometric part: strip the only other non-zero term (Shapiro)
    simGeom = B.z(mi) - B.es.shapiroTruth_m(mi);

    % Orekit rigorous light-time. The ECEF triad at this epoch is used directly as the
    % inertial container; the tower's rotation enters through its velocity omega x r, so
    % no custom rotating frame is needed (same construction as the Sagnac test).
    vT = cross([0;0;om], rt);
    aT = cross([0;0;om], vT);
    try
        pvT = org.orekit.utils.TimeStampedPVCoordinates(epoch, V3(rt), V3(vT), V3(aT));
    catch
        pvT = org.orekit.utils.TimeStampedPVCoordinates(epoch, V3(rt), V3(vT));
    end
    tau = org.orekit.estimation.measurements.AbstractMeasurement.signalTimeOfFlightAdjustableEmitter( ...
        pvT, V3(rs), epoch, frame);
    oreGeom = c*tau;

    % Shapiro against the IERS closed form with Orekit's GM. The sim evaluates it between
    % the ACTUAL event endpoints, i.e. the tower at TRANSMIT time, so the reference must
    % use the same tower position -- rotated back by omega*tau using OREKIT's light-time,
    % not the sim's. Using the receive-time tower position instead biases the reference by
    % ~5e-8 m (the tower moves ~60 m during the 0.13 s uplink).
    th   = -om*tau;
    Rz   = [cos(th) -sin(th) 0; sin(th) cos(th) 0; 0 0 1];
    rtTx = Rz*rt;
    rr = norm(rs); rtn = norm(rtTx); Rsep = norm(rs - rtTx);
    shapRef = (2*mu/c^2) * log((rr+rtn+Rsep)/(rr+rtn-Rsep));

    dGeoMax  = max(dGeoMax,  abs(simGeom - oreGeom));
    dShapMax = max(dShapMax, abs(B.es.shapiroTruth_m(mi) - shapRef));
    dTotMax  = max(dTotMax,  abs(B.z(mi) - (oreGeom + shapRef)));
    if mi <= numel(B.towers)
        fprintf('  %3d %3d  %7.2f  %15.4f  %13.2e  %10.4f  %9.2e\n', mi, ti, ...
            rad2deg(B.elev(mi)), simGeom, simGeom-oreGeom, 1000*B.es.shapiroTruth_m(mi), ...
            B.es.shapiroTruth_m(mi)-shapRef);
    end
end
fprintf('  max |d geometry| = %.3e m | max |d Shapiro| = %.3e m | max |d TOTAL z| = %.3e m\n', ...
    dGeoMax, dShapMax, dTotMax);

% ===========================================================================
% PART A2 -- troposphere: composition, sign, non-dispersiveness, Orekit anchor
% ===========================================================================
fprintf('\n== PART A2: troposphere into z ==\n');

T = runVariant_(FLAT, @(cfg) setfield_(cfg, 'errors.troposphere.enable', true));
assertSameGeometry_(B, T, 'tropo');
dTrop = T.z(1:M) - B.z(1:M);
tropReported = T.es.bySource.truth_m.trop(:);

dCompose = max(abs(dTrop - tropReported));
fprintf('  default model (%s): delta z vs reported trop term: max |d| = %.3e m\n', ...
    T.cfg.errors.troposphere.modelType, dCompose);
fprintf('  sign: min delta = %+.4f m, max delta = %+.4f m\n', min(dTrop), max(dTrop));

% non-dispersive: the same tower must get the same trop on every signal
nT_    = numel(B.towers);
nSig   = M / nT_;
tropMat = reshape(dTrop, nT_, nSig);
dDisp  = max(max(abs(tropMat - tropMat(:,1))));
fprintf('  non-dispersive across %d signals: max spread = %.3e m\n', nSig, dDisp);

% Realistic atmosphere: ZHD/ZWD + Niell -> compare against Orekit's Niell and Saastamoinen
TR = runVariant_(FLAT, @(cfg) realisticTropo_(cfg));
assertSameGeometry_(B, TR, 'tropo-realistic');
dTropR = TR.z(1:M) - B.z(1:M);
fprintf('  realistic model (%s, truth mapping=%s, doy=%d):\n', TR.cfg.errors.troposphere.modelType, ...
    TR.cfg.errors.troposphere.truth.mappingType, TR.cfg.errors.troposphere.dayOfYear);

% Orekit's Niell takes day-of-year from the date, so the reference date must carry the
% same doy the sim was configured with (1 Jan) -- Niell m_h is seasonal.
niell = org.orekit.models.earth.troposphere.NiellMappingFunctionModel();
dateT = org.orekit.time.AbsoluteDate(2001, 1, 1, 12, 0, 0.0, utc);
fprintf('    twr  el[deg]   ZHD[m]  ZWD[m]   sim[m]   Niell-mapped[m]   d[mm]   Saas[m]  d[mm]\n');
dNiellMax = 0; dSaasMax = 0;
for ti = 1:nT_
    mi  = ti;                                   % first signal block, one row per tower
    ws  = TR.env.weatherState(ti);
    el  = TR.elev(mi);
    gp  = org.orekit.bodies.GeodeticPoint(ws.latRad, ws.lonRad, ws.heightKm*1000);
    tc  = org.orekit.utils.TrackingCoordinates(0.0, el, 0.0);
    mf  = niell.mappingFactors(tc, gp, dateT);
    oreMapped = ws.ZHD_m*mf(1) + ws.ZWD_m*mf(2);

    pth  = org.orekit.models.earth.weather.PressureTemperatureHumidity( ...
        ws.heightKm*1000, ws.pressure_hPa*100, ws.temperature_K, 0.0, 273.15, 3.0);
    prov = org.orekit.models.earth.weather.ConstantPressureTemperatureHumidityProvider(pth);
    saas = org.orekit.models.earth.troposphere.ModifiedSaastamoinenModel(prov);
    try
        td = saas.pathDelay(tc, gp, [], dateT);
    catch
        td = saas.pathDelay(tc, gp, zeros(1,0), dateT);
    end
    oreSaas = td.getDelay();

    dNiellMax = max(dNiellMax, abs(dTropR(mi) - oreMapped));
    dSaasMax  = max(dSaasMax,  abs(dTropR(mi) - oreSaas));
    fprintf('    %3d  %7.2f  %7.4f %7.4f  %8.4f  %14.4f  %7.1f  %8.4f %7.1f\n', ti, ...
        rad2deg(el), ws.ZHD_m, ws.ZWD_m, dTropR(mi), oreMapped, 1000*(dTropR(mi)-oreMapped), ...
        oreSaas, 1000*(dTropR(mi)-oreSaas));
end
fprintf('    max |sim - Orekit Niell-mapped| = %.3e m | max |sim - Orekit Saastamoinen| = %.3e m\n', ...
    dNiellMax, dSaasMax);

% ===========================================================================
% PART A3 -- ionosphere: composition, sign, dispersive scaling, obliquity
% ===========================================================================
fprintf('\n== PART A3: ionosphere into z ==\n');

I = runVariant_(FLAT, @(cfg) setfield_(cfg, 'errors.ionosphere.enable', true));
assertSameGeometry_(B, I, 'iono');
dIono = I.z(1:M) - B.z(1:M);
ionoReported = I.es.bySource.truth_m.iono(:) + I.es.bySource.truth_m.ionoHO(:);

dComposeI = max(abs(dIono - ionoReported));
fprintf('  delta z vs reported iono term: max |d| = %.3e m\n', dComposeI);
fprintf('  sign: min delta = %+.4f m, max delta = %+.4f m (code delay must be positive)\n', ...
    min(dIono), max(dIono));

% dispersive scaling: iono ~ 1/f^2, so row(sig2)/row(sig1) == (f1/f2)^2
fL1 = I.cfg.signals.L1.frequency_Hz;
fL2 = I.cfg.signals.L2.frequency_Hz;
ionoMat  = reshape(dIono, nT_, nSig);
if nSig >= 2
    ratio    = ionoMat(:,2) ./ ionoMat(:,1);
    expRatio = (fL1/fL2)^2;
    dRatio   = max(abs(ratio - expRatio));
    fprintf('  dispersive scaling: measured %.9f vs (f_L1/f_L2)^2 = %.9f -> max |d| = %.3e\n', ...
        mean(ratio), expRatio, dRatio);
else
    dRatio = 0;
    fprintf('  dispersive scaling: only one code signal, skipped\n');
end

% obliquity actually landing in z, vs Orekit's IS-GPS-200 F
AMP = 20e-9; PER = 86400; DC = 5e-9;
klob = org.orekit.models.earth.ionosphere.KlobucharIonoModel([AMP 0 0 0], [PER 0 0 0], utc);
date0 = org.orekit.time.AbsoluteDate(2001, 6, 29, 0, 0, 0.0, utc);
geoEq = org.orekit.bodies.GeodeticPoint(0.0, 0.0, 0.0);
fprintf('    twr  el[deg]   obliq(sim)  F(Orekit IS-GPS-200)   ratio\n');
obliqRatioMax = 0;
for ti = 1:nT_
    el   = I.elev(ti);
    vert = I.env.getIonoDelay(ti, pi/2, 'truth', fL1, fL1);
    slnt = I.env.getIonoDelay(ti, el,   'truth', fL1, fL1);
    obliqSim = slnt / vert;
    try,   osN = klob.pathDelay(date0.shiftedBy(2*3600), geoEq, el, 0.0, fL1, []);
    catch; osN = klob.pathDelay(date0.shiftedBy(2*3600), geoEq, el, 0.0, fL1, zeros(1,0)); end
    Fore = osN / (c*DC);
    obliqRatioMax = max(obliqRatioMax, abs(obliqSim/Fore - 1));
    fprintf('    %3d  %7.2f  %10.4f  %20.4f  %7.4f\n', ti, rad2deg(el), obliqSim, Fore, obliqSim/Fore);
end
fprintf('    max |obliq(sim)/F(Orekit) - 1| = %.1f%%  (documented model difference:\n', 100*obliqRatioMax);
fprintf('      the default sim obliquity is a plain thin-shell secant 1/sin(e), Orekit is IS-GPS-200 F)\n');

% ===========================================================================
% PART A4 -- superposition: no double counting, no cross-contamination
% ===========================================================================
fprintf('\n== PART A4: superposition (tropo + iono together vs separately) ==\n');
A = runVariant_(FLAT, @(cfg) setfield_(setfield_(cfg, 'errors.troposphere.enable', true), ...
                                       'errors.ionosphere.enable', true));
assertSameGeometry_(B, A, 'tropo+iono');
dBoth   = A.z(1:M) - B.z(1:M);
dSumSep = dTrop + dIono;
dSuper  = max(abs(dBoth - dSumSep));
fprintf('  max |delta(both) - (delta(trop) + delta(iono))| = %.3e m\n', dSuper);
fprintf('  (delta(both) spans %.4f .. %.4f m)\n', min(dBoth), max(dBoth));

% ---------------------------------------------------------------------------
% Assertions
%
%   A1: the composed geometric row must match Orekit's rigorous light-time. Both solve
%       the same uplink problem (sim iteratively in ECEF, Orekit by shifting the emitter
%       PV in an inertial frame), so the residual is numerical, not modelling -> 1 mm.
%       Shapiro is a fixed closed form -> exact. The full z must match the Orekit-composed
%       reference to the same 1 mm.
%   A2/A3: differencing whole z vectors must reproduce the sim's OWN reported per-source
%       term to machine precision -- that is the composition claim (right sign, applied
%       once, nothing else moved). Tropo must be positive and frequency-independent; iono
%       must be positive on code and scale exactly as 1/f^2.
%   A2 realistic: what lands in z must be ZHD*m_h + ZWD*m_w with Orekit's own Niell
%       factors -> mm. The looser Saastamoinen bound absorbs the ZWD-model difference.
%   A4: superposition to machine precision -- the double-count check.
%
% TOLERANCE NOTE: "machine precision" here is a few ULP of a ~3.9e7 m pseudorange, and
% eps(3.9e7) = 7.45e-9 m. Differencing two such numbers cannot resolve better than that,
% so the composition/superposition bounds are set at 1e-7 m (~13 ULP), NOT at 1e-9 --
% a 1e-9 bound would be below the representable resolution of the quantity being tested.
% ---------------------------------------------------------------------------
ULP_M = 1e-7;   % ~13 ULP of a GEO-range pseudorange

assert(dGeoMax  < 1e-3,   'A1 FAIL: composed geometry vs Orekit light-time %.3e m > 1 mm', dGeoMax);
assert(dShapMax < ULP_M,  'A1 FAIL: Shapiro in z vs IERS closed form %.3e m > %.0e', dShapMax, ULP_M);
assert(dTotMax  < 1e-3,   'A1 FAIL: full composed z vs Orekit reference %.3e m > 1 mm', dTotMax);

assert(dCompose < ULP_M, 'A2 FAIL: trop contribution to z %.3e m != reported trop term', dCompose);
assert(all(dTrop > 0),   'A2 FAIL: troposphere must LENGTHEN a pseudorange (sign error)');
assert(dDisp    < ULP_M, 'A2 FAIL: troposphere is non-dispersive but varies %.3e m across signals', dDisp);
assert(all(dTropR > 0),  'A2 FAIL: realistic troposphere must LENGTHEN a pseudorange (sign error)');
assert(dNiellMax < 5e-3, 'A2 FAIL: realistic trop in z vs Orekit Niell-mapped ZHD/ZWD %.3e m > 5 mm', dNiellMax);
assert(dSaasMax  < 0.30, 'A2 FAIL: realistic trop in z vs Orekit Saastamoinen %.3e m > 30 cm', dSaasMax);

assert(dComposeI < ULP_M, 'A3 FAIL: iono contribution to z %.3e m != reported iono term', dComposeI);
assert(all(dIono > 0),    'A3 FAIL: ionosphere must DELAY code (sign error)');
assert(dRatio   < 1e-8,   'A3 FAIL: iono dispersive scaling off by %.3e from (f_L1/f_L2)^2', dRatio);
% The obliquity difference is a MODEL choice, not an error -- assert only that the sim's
% thin-shell secant stays in the same family as IS-GPS-200 F (both monotone single-layer
% mappings), so a genuine mapping blunder would still be caught.
assert(obliqRatioMax < 0.5, ...
    'A3 FAIL: iono obliquity differs from Orekit IS-GPS-200 F by %.0f%% -- beyond a model difference', ...
    100*obliqRatioMax);

assert(dSuper   < ULP_M, 'A4 FAIL: tropo and iono do not superpose (%.3e m) -- double count?', dSuper);
assert(max(abs(dBoth)) > 1, 'A4 FAIL: combined effect %.3e m too small to be a real test', max(abs(dBoth)));

fprintf(['\ntest_orekit_composed_observable_crossvalidation: PASS -- composed z matches Orekit ' ...
         'rigorous light-time + Shapiro to %.1e m; tropo/iono enter z exactly once, with the ' ...
         'right sign and dispersion, and superpose to %.1e m.\n'], dTotMax, dSuper);

% ===========================================================================
% Local helpers
% ===========================================================================
function out = runVariant_(scenarioJson, mutator)
    % Resolve the flat scenario, apply the caller's mutation, build the real pipeline,
    % and evaluate one epoch at t = 0. Returns everything the comparisons need.
    cfg = resolveSimulationConfig(scenarioJson);
    cfg.scenario.nTowers   = 5;
    cfg.scenario.nReceivers = 1;      % one antenna -> one row per (tower, signal)
    cfg.plots.enable  = false;
    cfg.report.enable = false;
    cfg = mutator(cfg);
    cfg = revgnss.ConfigFactory.finalizeConfig(cfg);

    [asset, towers, ekf, mm, ec, orbitProp] = revgnss.ScenarioFactory.build(cfg);
    [r_ecef, v_ecef] = orbitProp.propagate(0);
    asset.setTruthFromOrbit(r_ecef, v_ecef);
    [z, ~, ~, ~, es] = mm.computeMeasurements(asset, towers, ekf.x, 0, ekf.stateMap);

    lever  = asset.receiverLeverArms_body_m;
    satAnt = asset.getAntennaPositionsECEF(asset.r_ecef_m, asset.attitude_euler_rad, lever);
    towerPos = zeros(3, numel(towers));
    for ti = 1:numel(towers); towerPos(:,ti) = towers{ti}.getAntennaPositionECEF(); end

    M = es.nPseudorange;
    elev = zeros(M,1);
    for mi = 1:M
        elev(mi) = models.frames.GeometryUtils.elevationAngle( ...
            towerPos(:, es.towerIdx_perMeas(mi)), satAnt(:, es.antennaIdx_perMeas(mi)));
    end

    out = struct('cfg', cfg, 'z', z, 'es', es, 'asset', asset, 'towers', {towers}, ...
        'env', ec.envModel, 'satAnt', satAnt, 'towerPos', towerPos, 'M', M, ...
        'elev', elev, 'b_rx', asset.clock.getBiasMeters());
end

function assertSameGeometry_(a, b, label)
    % Differencing z vectors is only meaningful if the two runs share row order and
    % geometry. Anything else means the mutation moved something it should not have.
    assert(a.M == b.M, '%s: row count changed %d -> %d', label, a.M, b.M);
    assert(isequal(a.es.towerIdx_perMeas, b.es.towerIdx_perMeas), '%s: tower row order changed', label);
    assert(isequal(a.es.antennaIdx_perMeas, b.es.antennaIdx_perMeas), '%s: antenna row order changed', label);
    assert(max(abs(a.satAnt(:) - b.satAnt(:))) < 1e-9, '%s: truth satellite geometry moved', label);
    assert(max(abs(a.towerPos(:) - b.towerPos(:))) < 1e-9, '%s: tower geometry moved', label);
    assert(max(abs(a.es.shapiroTruth_m - b.es.shapiroTruth_m)) < 1e-12, '%s: Shapiro changed', label);
    assert(b.b_rx == 0 && max(abs(b.es.towerClockTruth_m)) == 0, '%s: clocks must stay zero', label);
end

function cfg = realisticTropo_(cfg)
    % The default troposphere is a constant zenith delay mapped by 1/sin(e). Switch to
    % the ZHD/ZWD local-weather model with Niell mapping -- the configuration that has an
    % apples-to-apples Orekit counterpart -- with the stochastic wet residual disabled so
    % the delta is the deterministic delay only. dayOfYear is pinned to the sim default
    % so the Orekit Niell call can be made at the matching date.
    cfg = setfield_(cfg, 'errors.troposphere.enable', true);
    cfg = setfield_(cfg, 'errors.troposphere.modelType', 'localWeatherGM');
    cfg = setfield_(cfg, 'errors.troposphere.truth.mappingType', 'niell');
    cfg = setfield_(cfg, 'errors.troposphere.model.mappingType', 'niell');
    cfg = setfield_(cfg, 'errors.troposphere.dayOfYear', TROPO_DOY_());
    cfg = setfield_(cfg, 'errors.troposphere.stochastic.sigmaWet_ss_m', 0);
end

function d = TROPO_DOY_()
    % Day of year used for both the sim's Niell call and the Orekit reference date.
    d = 1;
end

function s = setfield_(s, dotted, value)
    % setfield with a dotted path, creating intermediate structs as needed.
    parts = strsplit(dotted, '.');
    s = setrec_(s, parts, value);
end

function s = setrec_(s, parts, value)
    if numel(parts) == 1
        s.(parts{1}) = value;
    else
        if ~isfield(s, parts{1}) || ~isstruct(s.(parts{1}))
            s.(parts{1}) = struct();
        end
        s.(parts{1}) = setrec_(s.(parts{1}), parts(2:end), value);
    end
end
