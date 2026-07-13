% test_niell_mapping_function
% Niell (1996) NMF hydrostatic/wet mapping and thin-shell ionospheric obliquity,
% verified against published reference values (Niell 1996; Klobuchar 1987 geometry).
%
% Reference values (lat 45 deg, annual-average hydrostatic, h_ion = 350 km):
%   elev   1/sin(e)   m_h        m_w        M_thinShell
%    5      11.474    10.13      10.75       3.04
%   15       3.864     3.800      3.833      2.49
%   30       2.000     1.993      1.997      1.75
%   90       1.000     1.000      1.000      1.00
%
% (The 3 deg row is not tested because ELEVATION_FLOOR_RAD = 5 deg clamps below it.)

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_niell_mapping_function ===\n');

MF     = @models.atmosphere.MappingFunctions;
lat45  = deg2rad(45);
doyAvg = 28 + 365.25/4;   % nulls the seasonal cosine -> annual-average coefficients
tolLow = 0.02;            % ~0.2%% absolute at low elevation vs published table
tolTight = 1e-9;

% --- Normalisation: m(90 deg) = 1 exactly (catches continued-fraction nesting errors)
mh90 = models.atmosphere.MappingFunctions.niellHydrostatic(pi/2, lat45, doyAvg, 0);
mw90 = models.atmosphere.MappingFunctions.niellWet(pi/2, lat45);
assert(abs(mh90 - 1) < tolTight, 'Niell hydrostatic must be 1.0 at zenith, got %.10f', mh90);
assert(abs(mw90 - 1) < tolTight, 'Niell wet must be 1.0 at zenith, got %.10f', mw90);

% --- Reference values at 5 / 15 / 30 deg
ref = struct( ...
    'el_deg', {5, 15, 30}, ...
    'mh',     {10.13, 3.800, 1.993}, ...
    'mw',     {10.75, 3.833, 1.997}, ...
    'M',      {3.04, 2.49, 1.75});

for k = 1:numel(ref)
    er = deg2rad(ref(k).el_deg);
    mh = models.atmosphere.MappingFunctions.niellHydrostatic(er, lat45, doyAvg, 0);
    mw = models.atmosphere.MappingFunctions.niellWet(er, lat45);
    Mi = models.atmosphere.MappingFunctions.ionosphere(er, 'thinShell', 350e3);
    assert(abs(mh - ref(k).mh) < tolLow, ...
        'm_h(%d deg)=%.4f expected ~%.3f', ref(k).el_deg, mh, ref(k).mh);
    assert(abs(mw - ref(k).mw) < tolLow, ...
        'm_w(%d deg)=%.4f expected ~%.3f', ref(k).el_deg, mw, ref(k).mw);
    assert(abs(Mi - ref(k).M)  < tolLow, ...
        'M_thinShell(%d deg)=%.4f expected ~%.3f', ref(k).el_deg, Mi, ref(k).M);
end

% --- Thin-shell obliquity is far smaller than 1/sin at low elevation (not a secant)
M5   = models.atmosphere.MappingFunctions.ionosphere(deg2rad(5), 'thinShell', 350e3);
sec5 = 1/sin(deg2rad(5));
assert(M5 < 0.5*sec5, 'thin-shell M(5 deg)=%.3f should be << 1/sin(5 deg)=%.3f', M5, sec5);

% --- Wet and hydrostatic mappings differ, and both differ from the secant, most at low elevation
mh5 = models.atmosphere.MappingFunctions.niellHydrostatic(deg2rad(5), lat45, doyAvg, 0);
mw5 = models.atmosphere.MappingFunctions.niellWet(deg2rad(5), lat45);
assert(mw5 > mh5, 'wet mapping should exceed hydrostatic at 5 deg (%.3f vs %.3f)', mw5, mh5);
assert(mw5 < sec5 && mh5 < sec5, 'Niell mappings should be below 1/sin at 5 deg');

% --- Height correction: positive height raises the hydrostatic mapping at low elevation,
%     and has no effect at zenith (height term vanishes as sin e -> 1)
mh5_h0 = models.atmosphere.MappingFunctions.niellHydrostatic(deg2rad(5), lat45, doyAvg, 0);
mh5_h1 = models.atmosphere.MappingFunctions.niellHydrostatic(deg2rad(5), lat45, doyAvg, 1);
assert(mh5_h1 > mh5_h0, 'height correction should increase m_h at low elevation');
assert(abs(mh5_h1 - mh5_h0 - 0.022) < 0.01, ...
    'height correction ~0.022/km at 5 deg, got %.4f', mh5_h1 - mh5_h0);
mh90_h1 = models.atmosphere.MappingFunctions.niellHydrostatic(pi/2, lat45, doyAvg, 1);
assert(abs(mh90_h1 - 1) < 1e-6, 'height correction must vanish at zenith, got %.8f', mh90_h1);

% --- 'niell' dispatch through troposphere(elevRad, kind, opts) matches the direct methods
optsH = struct('component','h','latitude_rad',lat45,'doy',doyAvg,'height_km',0);
optsW = struct('component','w','latitude_rad',lat45);
mhD = models.atmosphere.MappingFunctions.troposphere(deg2rad(15), 'niell', optsH);
mwD = models.atmosphere.MappingFunctions.troposphere(deg2rad(15), 'niell', optsW);
assert(abs(mhD - models.atmosphere.MappingFunctions.niellHydrostatic(deg2rad(15), lat45, doyAvg, 0)) < tolTight, ...
    'niell dispatch (h) must match niellHydrostatic');
assert(abs(mwD - models.atmosphere.MappingFunctions.niellWet(deg2rad(15), lat45)) < tolTight, ...
    'niell dispatch (w) must match niellWet');

fprintf('  m_h(5)=%.4f m_w(5)=%.4f M(5)=%.4f | m_h(30)=%.4f m_w(30)=%.4f M(30)=%.4f\n', ...
    mh5, mw5, M5, ...
    models.atmosphere.MappingFunctions.niellHydrostatic(deg2rad(30), lat45, doyAvg, 0), ...
    models.atmosphere.MappingFunctions.niellWet(deg2rad(30), lat45), ...
    models.atmosphere.MappingFunctions.ionosphere(deg2rad(30), 'thinShell', 350e3));
fprintf('  PASS\n');
