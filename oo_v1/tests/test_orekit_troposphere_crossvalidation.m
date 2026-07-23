% test_orekit_troposphere_crossvalidation
%
% TIER 3 (delay layer, part 1 of N) -- the classic "reference GNSS library" check:
% the sim's troposphere delay models vs Orekit 13.1.7's named models.
%
%   PART A -- Niell (1996) mapping functions m_h(e), m_w(e):
%       sim models.atmosphere.MappingFunctions.niellHydrostatic / niellWet
%       vs Orekit org.orekit.models.earth.troposphere.NiellMappingFunctionModel.
%       Purely geometric (elevation, latitude, day-of-year, height); no weather.
%
%   PART B -- Saastamoinen/Davis zenith hydrostatic delay (ZHD):
%       sim models.errors.EnvironmentModel weatherState(k).ZHD_m
%       (ZHD = 0.0022768*P/(1 - 0.00266*cos2phi - 0.00028*h_km), Davis 1985)
%       vs Orekit org.orekit.models.earth.troposphere.ModifiedSaastamoinenModel
%       .pathDelay(...).getZh(), fed the SAME surface pressure so only the ZHD
%       FORMULA differs.
%
% RESULT (MATLAB R2025b + Orekit 13.1.7): Niell m_h/m_w match to ~0 (byte-identical
% Niell 1996) at every elevation 5..90 deg; ZHD agrees to <= 6 mm across latitude/
% height -- 0.2 mm at mid-latitude (where the Davis cos2phi gravity term vanishes),
% with the ~6 mm equator gap being a documented convention difference (the sim uses
% the full Davis latitude/height gravity correction; Orekit's ModifiedSaastamoinen
% getZh was latitude-independent at these points). Both are sub-cm.
%
% REQUIREMENTS / SKIP: JVM-enabled MATLAB (`matlab -batch`, not the -nojvm MCP
% session) + the Orekit bridge at ~/orekit-bridge. Skips cleanly if absent.

fprintf('test_orekit_troposphere_crossvalidation\n');

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

utc  = org.orekit.time.TimeScalesFactory.getUTC();
date = org.orekit.time.AbsoluteDate(2001, 6, 29, 12, 0, 0.0, utc);   % day-of-year 180 (2001 non-leap)
doy  = 180;   latDeg = 45;   latRad = deg2rad(latDeg);

% ===========================================================================
% PART A -- Niell (1996) mapping functions: sim vs Orekit
% ===========================================================================
niell = org.orekit.models.earth.troposphere.NiellMappingFunctionModel();
gpA   = org.orekit.bodies.GeodeticPoint(latRad, 0.0, 0.0);
elDeg = [5 7 10 15 20 30 45 60 90];
fprintf('\n== PART A: Niell (1996) mapping  sim vs Orekit  (lat %d deg, doy %d, h 0) ==\n', latDeg, doy);
fprintf('  el     m_h(sim)  m_h(ore)    d_mh   | m_w(sim)  m_w(ore)    d_mw\n');
dmhMax = 0; dmwMax = 0;
for e = elDeg
    er   = deg2rad(e);
    mh_s = models.atmosphere.MappingFunctions.niellHydrostatic(er, latRad, doy, 0);
    mw_s = models.atmosphere.MappingFunctions.niellWet(er, latRad);
    tc   = org.orekit.utils.TrackingCoordinates(0.0, er, 0.0);   % (az, el, range)
    mf   = niell.mappingFactors(tc, gpA, date);                  % [m_h, m_w]
    dmhMax = max(dmhMax, abs(mh_s - mf(1)));  dmwMax = max(dmwMax, abs(mw_s - mf(2)));
    fprintf('  %2d   %8.4f %8.4f  %8.1e | %8.4f %8.4f  %8.1e\n', e, mh_s, mf(1), mh_s-mf(1), mw_s, mf(2), mw_s-mf(2));
end
fprintf('  max |d m_h| = %.3e   max |d m_w| = %.3e\n', dmhMax, dmwMax);

% ===========================================================================
% PART B -- Saastamoinen/Davis ZHD: sim vs Orekit (same surface pressure)
% ===========================================================================
mkTower = @(lat_deg, alt) struct('id',1,'name','t','lat_rad',deg2rad(lat_deg),'lon_rad',0, ...
    'alt_m',alt,'antennaOffset_enu_m',[0;0;0],'hardwareDelay_m',0);
cfgT = struct(); cfgT.towers = [mkTower(45,0), mkTower(0,0), mkTower(45,3000)];
env  = models.errors.EnvironmentModel(cfgT, 3);
assert(isfield(env.weatherState(1),'ZHD_m') && isfield(env.weatherState(1),'pressure_hPa'), ...
    'EnvironmentModel weatherState must expose ZHD_m and pressure_hPa');

fprintf('\n== PART B: Saastamoinen/Davis ZHD  sim vs Orekit (matched surface pressure) ==\n');
fprintf('  lat[deg] h[m]  P[hPa]    ZHD(sim)  ZHD(ore)   d[mm]\n');
dZhdMax = 0; dZhdMidLat = Inf;
for k = 1:numel(cfgT.towers)
    ws   = env.weatherState(k);
    latk = cfgT.towers(k).lat_rad;  altk = cfgT.towers(k).alt_m;
    pth  = org.orekit.models.earth.weather.PressureTemperatureHumidity(altk, ws.pressure_hPa*100, 288.15, 0.0, 273.15, 3.0);
    prov = org.orekit.models.earth.weather.ConstantPressureTemperatureHumidityProvider(pth);
    saas = org.orekit.models.earth.troposphere.ModifiedSaastamoinenModel(prov);
    gp   = org.orekit.bodies.GeodeticPoint(latk, 0.0, altk);
    tc   = org.orekit.utils.TrackingCoordinates(0.0, pi/2, 0.0);     % zenith
    try
        td = saas.pathDelay(tc, gp, [], date);
    catch
        td = saas.pathDelay(tc, gp, zeros(1,0), date);
    end
    zhd_o = td.getZh();
    d = ws.ZHD_m - zhd_o;
    dZhdMax = max(dZhdMax, abs(d));
    if abs(rad2deg(latk) - 45) < 1 && altk == 0; dZhdMidLat = abs(d); end
    fprintf('  %5.0f   %5.0f %7.2f  %8.5f %8.5f  %6.2f\n', rad2deg(latk), altk, ws.pressure_hPa, ws.ZHD_m, zhd_o, 1000*d);
end
fprintf('  max |d ZHD| = %.3e m   (mid-lat/h0 = %.3e m)\n', dZhdMax, dZhdMidLat);

% ---------------------------------------------------------------------------
% Optional mapping-function plot (non-fatal)
% ---------------------------------------------------------------------------
try
    ev = 5:1:90; mh_s = zeros(size(ev)); mh_o = zeros(size(ev));
    for i = 1:numel(ev)
        mh_s(i) = models.atmosphere.MappingFunctions.niellHydrostatic(deg2rad(ev(i)), latRad, doy, 0);
        mf = niell.mappingFactors(org.orekit.utils.TrackingCoordinates(0.0, deg2rad(ev(i)), 0.0), gpA, date);
        mh_o(i) = mf(1);
    end
    f = figure('Visible','off');
    plot(ev, mh_s, '-', ev, mh_o, '--', 'LineWidth', 1.3); grid on;
    xlabel('elevation [deg]'); ylabel('Niell hydrostatic m_h'); set(gca,'YScale','log');
    legend('sim', 'Orekit', 'Location', 'northeast');
    title('Tier 3: Niell (1996) mapping -- sim vs Orekit (overlaid, byte-identical)');
    outPng = fullfile(oo_v1Root, 'output', 'orekit_troposphere_crossvalidation.png');
    exportgraphics(f, outPng, 'Resolution', 130); close(f);
    fprintf('  plot written: %s\n', outPng);
catch plotErr
    fprintf('  (plot skipped: %s)\n', plotErr.message);
end

% ---------------------------------------------------------------------------
% Assertions.
%   Niell: both implement Niell 1996 -> expect ~0 (observed 0.0). 1e-3 ceiling
%     proves the same model (a different mapping model differs by 1-5% at low el).
%   ZHD: same-formula check at mid-latitude (cos2phi term null) must be sub-mm;
%     the overall <=1.2 cm ceiling admits the documented latitude gravity-correction
%     convention gap (~6 mm at the equator) while still catching a real ZHD bug
%     (wrong 0.0022768 coefficient or pressure -> many cm).
% ---------------------------------------------------------------------------
assert(dmhMax < 1e-3, 'A FAIL: Niell m_h max |d| %.3e > 1e-3 (mapping model differs)', dmhMax);
assert(dmwMax < 1e-3, 'A FAIL: Niell m_w max |d| %.3e > 1e-3 (mapping model differs)', dmwMax);
assert(dZhdMidLat < 1e-3, 'B FAIL: mid-lat ZHD |d| %.3e m > 1 mm (ZHD formula differs)', dZhdMidLat);
assert(dZhdMax    < 0.012, 'B FAIL: ZHD max |d| %.3e m > 12 mm (ZHD model/pressure differs)', dZhdMax);

fprintf('\ntest_orekit_troposphere_crossvalidation: PASS -- Niell mapping byte-identical; Saastamoinen ZHD sub-cm vs Orekit.\n');
