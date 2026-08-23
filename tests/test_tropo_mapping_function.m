% test_tropo_mapping_function
% MappingFunctions.troposphere: values, floor guard, models.
%
% Verifies:
%   - zenith (90 deg): mf = 1.0
%   - 30 deg elevation: mf = 1/sin(30 deg) = 2.0
%   - elevation floor applied (no division by zero at el=0)
%   - 'continuedFraction' mode returns finite positive value

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_tropo_mapping_function ===\n');

% Zenith (90 deg): mf = 1/sin(90) = 1
mf_zenith = models.atmosphere.MappingFunctions.troposphere(pi/2, 'simple');
assert(abs(mf_zenith - 1.0) < 1e-10, ...
    'Zenith mapping function should be 1.0, got %.6f', mf_zenith);

% 30 deg elevation: mf = 1/sin(30 deg) = 2.0
mf_30 = models.atmosphere.MappingFunctions.troposphere(30*pi/180, 'simple');
assert(abs(mf_30 - 2.0) < 1e-6, ...
    '30-deg mapping function should be 2.0, got %.6f', mf_30);

% Very low elevation (near zero): should not blow up (floor guard)
mf_low = models.atmosphere.MappingFunctions.troposphere(0.001, 'simple');
assert(isfinite(mf_low) && mf_low > 0, ...
    'Very low elevation mapping function should be finite positive, got %g', mf_low);

% continuedFraction mode: finite positive at 30 deg
mf_cf = models.atmosphere.MappingFunctions.troposphere(30*pi/180, 'continuedFraction');
assert(isfinite(mf_cf) && mf_cf > 0, ...
    'continuedFraction mapping function should be finite positive, got %g', mf_cf);

fprintf('  mf(90 deg)=%.4f  mf(30 deg)=%.4f  mf(CF 30 deg)=%.4f\n', ...
    mf_zenith, mf_30, mf_cf);
fprintf('  PASS\n');
