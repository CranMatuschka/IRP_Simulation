% test_saastamoinen_zhd
% EnvironmentModel zenith hydrostatic delay uses the Saastamoinen/Davis (1985) form
%   ZHD = 0.0022768*P / (1 - 0.00266*cos(2*phi) - 0.00028*h_km)   [m, P in hPa]
% driven by tower latitude and the ICAO standard-atmosphere surface pressure.
%
% Verified reference: ZHD ~ 2.307 m at P=1013.25 hPa, phi=45 deg, h=0
% (Davis, Herring, Shapiro, Rogers & Elgered 1985, Radio Science 20(6):1593).

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_saastamoinen_zhd ===\n');

mkTower = @(lat_deg, alt) struct( ...
    'id', 1, 'name', 't', 'lat_rad', deg2rad(lat_deg), 'lon_rad', 0, 'alt_m', alt, ...
    'antennaOffset_enu_m', [0;0;0], 'hardwareDelay_m', 0);

cfg = struct();
cfg.towers = [mkTower(45, 0), mkTower(0, 0), mkTower(45, 3000)];

env = models.errors.EnvironmentModel(cfg, 3);
zA = env.weatherState(1).ZHD_m;   % lat 45, sea level
zB = env.weatherState(2).ZHD_m;   % equator, sea level
zC = env.weatherState(3).ZHD_m;   % lat 45, 3 km

% Independent recomputation of the Davis formula for tower A
P0    = 1013.25;
zA_ref = 0.0022768 * P0 / (1 - 0.00266*cos(2*deg2rad(45)) - 0.00028*0);
assert(abs(zA - 2.307) < 3e-3, 'ZHD(lat45,h0) should be ~2.307 m, got %.5f', zA);
assert(abs(zA - zA_ref) < 1e-9, 'ZHD(lat45,h0) must match the Davis formula exactly (%.6f vs %.6f)', zA, zA_ref);

% Equatorial column is slightly larger than mid-latitude (gravity is weaker at the equator)
assert(zB > zA, 'equatorial ZHD (%.5f) should exceed mid-latitude ZHD (%.5f)', zB, zA);
assert(abs(zB - zA) < 0.02, 'latitude effect on ZHD should be at the cm level, got %.4f m', zB - zA);

% Altitude lowers surface pressure, so a 3 km tower has a markedly smaller ZHD
assert(zC < zA, '3 km ZHD (%.5f) should be below sea-level ZHD (%.5f)', zC, zA);
assert(zC > 1.5 && zC < 2.2, '3 km ZHD out of physical band: %.5f m', zC);

% All physical and finite
assert(all(isfinite([zA zB zC])) && all([zA zB zC] > 1.4), 'ZHD values must be finite and physical');

fprintf('  ZHD(lat45,h0)=%.5f m  ZHD(eq,h0)=%.5f m  ZHD(lat45,3km)=%.5f m\n', zA, zB, zC);
fprintf('  PASS\n');
