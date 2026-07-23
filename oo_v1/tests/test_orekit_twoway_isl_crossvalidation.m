% test_orekit_twoway_isl_crossvalidation
%
% TIER 3 (delay layer, part 4 of 4) -- the two-way / inter-satellite observables,
% vs Orekit 13.1.7's rigorous light-time (AbstractMeasurement.signalTimeOfFlight*).
% These use the emitter/receiver ECI position+velocity directly, so no custom rotating
% frame is needed (as established in the Shapiro+Sagnac test).
%
%   PART A -- ISL: the sim's inter-satellite range is INSTANTANEOUS (|r1 - r2|, no
%     light-time -- ISLMeasurementBuilder.geometry_). Compared to Orekit's rigorous
%     one-way light-time between two moving spacecraft, the sim neglects a light-time
%     correction of ~1 cm per km of baseline (the emitter's displacement during transit).
%     For cm-class ISL ranging at km+ baselines this is a real, quantified approximation.
%
%   PART B -- two-way: two-way time transfer works because the up-leg and down-leg Sagnac
%     are equal-and-opposite and CANCEL in the round trip, so the geometry drops out and
%     the clock difference remains -- the premise of TwoWayTimeTransferBuilder. Orekit's
%     rigorous two legs (up = AdjustableEmitter tower->sat, down = AdjustableReceiver
%     sat->tower) give two-way = c*(tauUp + tauDn); this equals 2 * the instantaneous
%     one-way to sub-mm even though each one-way Sagnac is up to ~64 m -> reciprocity.
%
% RESULT (MATLAB R2025b + Orekit 13.1.7): ISL light-time correction 0.01 m (1 km) ->
% 2.05 m (200 km), ~linear; two-way round-trip cancels a up-to-64 m one-way Sagnac to
% <= 0.6 mm. Completes the delay-layer cross-validation (tropo/iono/Shapiro/Sagnac/
% two-way/ISL).
%
% REQUIREMENTS / SKIP: JVM-enabled MATLAB (`matlab -batch`, not the -nojvm MCP session)
% + the Orekit bridge at ~/orekit-bridge. Skips cleanly if absent.

fprintf('test_orekit_twoway_isl_crossvalidation\n');

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
rGeo = 42164137.0;   vCirc = sqrt(mu/rGeo);
frame = org.orekit.frames.FramesFactory.getGCRF();
epoch = org.orekit.time.AbsoluteDate.J2000_EPOCH;
V3 = @(v) org.hipparchus.geometry.euclidean.threed.Vector3D(v(1), v(2), v(3));

% ===========================================================================
% PART A -- ISL inter-satellite range: sim instantaneous vs Orekit light-time
% ===========================================================================
% The instantaneous |r1-r2| omits a light-time correction; the sim closes it with the
% gated cfg.measurements.isl.lightTime.enable, whose first-order term is
%   rho + (u . v_tx_inertial)*(rho/c),  u = (r_rx - r_tx)/rho.
% Here the emitter velocity v1 is already inertial (ECI), so that formula is checked
% directly against Orekit's rigorous light-time (foErr, asserted sub-mm below).
fprintf('\n== PART A: ISL range  sim instantaneous vs Orekit light-time (+ gated first-order) ==\n');
fprintf('  baseline[km]   inst[m]        ltRange[m]      lt corr[m]   |1st-order - Orekit|[m]\n');
bls = [1 5 10 50 100 200];   corr = zeros(size(bls));   foErr = zeros(size(bls));
for i = 1:numel(bls)
    del = (bls(i)*1000)/rGeo;
    r1 = rGeo*[1;0;0];               v1 = vCirc*[0;1;0];
    r2 = rGeo*[cos(del);sin(del);0];                      % receiver (second satellite)
    inst = norm(r2 - r1);
    tau  = org.orekit.estimation.measurements.AbstractMeasurement.signalTimeOfFlightAdjustableEmitter( ...
        i_pv(epoch, r1, v1, -mu/rGeo^3*r1, V3), V3(r2), epoch, frame);
    corr(i) = c*tau - inst;
    u  = (r2 - r1) / inst;
    firstOrder = inst + (u' * v1) * (inst / c);           % the sim's gated ISL light-time term
    foErr(i) = abs(firstOrder - c*tau);
    fprintf('  %10d   %12.4f   %13.4f   %10.3e   %10.3e\n', bls(i), inst, c*tau, corr(i), foErr(i));
end
fprintf('  ISL light-time correction ~%.3f cm/km (max %.3f m at %d km); sim gated 1st-order matches Orekit to %.2e m\n', ...
    100*corr(1)/bls(1), corr(end), bls(end), max(foErr));
assert(max(foErr) < 1e-3, 'ISL first-order light-time vs Orekit %.3e m > 1 mm', max(foErr));

% ===========================================================================
% PART B -- two-way round-trip: the one-way Sagnac cancels (reciprocity)
% ===========================================================================
fprintf('\n== PART B: two-way round-trip  one-way Sagnac cancellation (reciprocity) ==\n');
fprintf('  sep[deg]  1way_inst[m]    1way Sagnac[m]  2way-2*inst[m]\n');
seps = [10 30 60 80];   d2wMax = 0;   sagMax = 0;
for sep = seps
    rT = Re*[1;0;0];                     vT = cross([0;0;om], rT);       % rotating tower
    rS = rGeo*[cosd(sep);sind(sep);0];   vT_ac = cross([0;0;om], vT);    % geostationary sat
    inst = norm(rS - rT);
    sag1 = (om/c)*(rT(1)*rS(2) - rT(2)*rS(1));                           % one-way Sagnac (context)
    pvT  = i_pv(epoch, rT, vT, vT_ac, V3);
    tauUp = org.orekit.estimation.measurements.AbstractMeasurement.signalTimeOfFlightAdjustableEmitter(pvT, V3(rS), epoch, frame);
    tauDn = org.orekit.estimation.measurements.AbstractMeasurement.signalTimeOfFlightAdjustableReceiver(V3(rS), epoch, pvT, epoch, frame);
    twoWay = c*(tauUp + tauDn);
    d2wMax = max(d2wMax, abs(twoWay - 2*inst));
    sagMax = max(sagMax, abs(sag1));
    fprintf('  %6d  %14.4f  %12.3f  %14.3e\n', sep, inst, sag1, twoWay - 2*inst);
end
fprintf('  one-way Sagnac up to %.0f m cancels in the round trip -> |2way - 2*1way| <= %.3e m\n', sagMax, d2wMax);

% ---------------------------------------------------------------------------
% Optional ISL-correction plot (non-fatal)
% ---------------------------------------------------------------------------
try
    f = figure('Visible','off');
    plot(bls, corr, 'o-', 'LineWidth', 1.3); grid on;
    xlabel('ISL baseline [km]'); ylabel('light-time correction [m]');
    title('Tier 3: ISL light-time correction the sim omits (~1 cm/km)');
    outPng = fullfile(oo_v1Root, 'output', 'orekit_twoway_isl_crossvalidation.png');
    exportgraphics(f, outPng, 'Resolution', 130); close(f);
    fprintf('  plot written: %s\n', outPng);
catch plotErr
    fprintf('  (plot skipped: %s)\n', plotErr.message);
end

% ---------------------------------------------------------------------------
% Assertions.
%   A: characterises the sim's instantaneous-ISL approximation vs Orekit's rigorous
%      light-time -- the correction is positive, monotone, and ~linear at ~1 cm/km
%      (observed 1.03 cm/km; 2.05 m at 200 km). Guards the finding + gross API errors.
%   B: the one-way Sagnac must be a real >10 m effect, and the two-way round trip must
%      cancel it to sub-mm (observed 0.57 mm) -- the reciprocity TWSTFT depends on.
% ---------------------------------------------------------------------------
assert(all(corr > 0), 'A FAIL: ISL light-time range must exceed the instantaneous range');
assert(all(diff(corr) > 0), 'A FAIL: ISL correction must grow with baseline');
assert(corr(1) > 0.005 && corr(1) < 0.02, 'A FAIL: ISL corr at 1 km = %.4f m, expected ~0.01 (1 cm/km)', corr(1));
assert(abs(corr(end)/corr(1) - bls(end)/bls(1)) < 0.15*bls(end)/bls(1), 'A FAIL: ISL correction not ~linear in baseline');
assert(sagMax > 10,  'B FAIL: one-way Sagnac %.1f m < 10 m -- geometry not exercising it', sagMax);
assert(d2wMax < 1e-3, 'B FAIL: two-way reciprocity |2way-2*1way| %.3e m > 1 mm', d2wMax);

fprintf('\ntest_orekit_twoway_isl_crossvalidation: PASS -- ISL light-time ~1 cm/km quantified; two-way Sagnac cancels to sub-mm.\n');

% ===========================================================================
% Local functions
% ===========================================================================
function p = i_pv(epoch, r, v, a, V3)
    % Build a TimeStampedPVCoordinates (with acceleration when the ctor supports it).
    try
        p = org.orekit.utils.TimeStampedPVCoordinates(epoch, V3(r), V3(v), V3(a));
    catch
        p = org.orekit.utils.TimeStampedPVCoordinates(epoch, V3(r), V3(v));
    end
end
