% test_stage28_orbit_diagnostics_smoke  Smoke tests for OrbitDiagnostics.
%
% T1: summarizeModes returns struct with expected mode fields.
% T2: j2PerturbationRatio at GEO is below 1e-4 (small perturbation).
% T3: compareCircularVsTwoBody returns arrays with correct sizes.
% T4: energyDriftTwoBody returns sorted non-negative drift vector.

fprintf('test_stage28_orbit_diagnostics_smoke\n');

Re = revgnss.Constants.EARTH_RADIUS_M;

% T1: summarizeModes struct fields
info = revgnss.OrbitDiagnostics.summarizeModes();
assert(isfield(info, 'circularAnalytic'), 'T1: missing field circularAnalytic');
assert(isfield(info, 'twoBodyRk4'),      'T1: missing field twoBodyRk4');
assert(isfield(info, 'j2Rk4'),           'T1: missing field j2Rk4');
assert(ischar(info.circularAnalytic) && ~isempty(info.circularAnalytic), ...
    'T1: circularAnalytic description empty');
fprintf('T1 PASS: summarizeModes returns struct with 3 mode descriptions\n');

% T2: j2PerturbationRatio at GEO
r_geo = [Re + 35786e3; 0; 0];
ratio = revgnss.OrbitDiagnostics.j2PerturbationRatio(r_geo);
assert(isnumeric(ratio) && isscalar(ratio), 'T2: j2PerturbationRatio not scalar');
assert(ratio < 1e-4, ...
    sprintf('T2: J2/two-body ratio at GEO = %.2e (should be < 1e-4)', ratio));
fprintf('T2 PASS: J2/two-body ratio at GEO = %.4e (< 1e-4)\n', ratio);

% T3: compareCircularVsTwoBody array sizes
cfg = struct('altitudeMean_m', 600e3, 'inclination_rad', 0, ...
             'raan_rad', 0, 'trueAnomaly0_rad', 0, 'epochGMST_rad', 0);
tGrid = [0; 10; 20; 30];
[rc, rk, diff] = revgnss.OrbitDiagnostics.compareCircularVsTwoBody(cfg, tGrid);
assert(isequal(size(rc), [3, 4]), 'T3: r_circ_ecef wrong size');
assert(isequal(size(rk), [3, 4]), 'T3: r_rk4_ecef wrong size');
assert(numel(diff) == 4, 'T3: diffNorm_m wrong length');
assert(all(diff >= 0), 'T3: diffNorm_m should be non-negative');
fprintf('T3 PASS: compareCircularVsTwoBody returns [3x4] position arrays\n');

% T4: energyDriftTwoBody returns sorted non-negative drift
cfgE = struct('altitudeMean_m', 600e3);
[t_s, dE] = revgnss.OrbitDiagnostics.energyDriftTwoBody(cfgE, 100, 1);
assert(isnumeric(t_s) && isnumeric(dE), 'T4: outputs not numeric');
assert(numel(t_s) == numel(dE), 'T4: t_s and dE length mismatch');
assert(all(dE >= 0), 'T4: energy drift must be non-negative (absolute value)');
assert(t_s(1) == 0, 'T4: time vector should start at 0');
fprintf('T4 PASS: energyDriftTwoBody returns %d points, final drift = %.4e J/kg\n', ...
    numel(t_s), dE(end));

fprintf('\ntest_stage28_orbit_diagnostics_smoke: all 4 tests passed.\n');
