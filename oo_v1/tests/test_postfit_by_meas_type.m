% test_postfit_by_meas_type
% Task 5: postfit residuals include code, Doppler, and carrier rows.
%
% Verifies:
%   T2: carrier ekfFloat — z length includes carrier rows
%   T3: measType_perRow correctly labels code/doppler/carrier rows
%
% NOTE: T1 (code-only postfit length via sim.diag.log) and T4 (per-epoch
% postfit length via sim.diag.log) were removed — the single-database
% refactor dropped the legacy per-epoch .log struct (raw z/postfit vectors
% are no longer retained; the array store keeps only per-epoch RMS
% scalars). T2/T3 exercise the same measurement-row-labeling behavior
% directly via the measurement model and remain valid.

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_postfit_by_meas_type ===\n');

% ----------------------------------------------------------------
% T2: carrier ekfFloat — z includes carrier rows
% ----------------------------------------------------------------
fprintf('  T2: carrier ekfFloat z includes carrier rows ...\n');

cfg2 = revgnss.ConfigFactory.carrierFloatConfig();
cfg2.simulation.duration_s = 3;
cfg2.plots.enable  = false;
cfg2.report.enable = false;

% Manually get measurement breakdown for one epoch via measModel
[asset2, towers2, ekf2, mm2] = revgnss.ScenarioFactory.build(cfg2);
[z2b, ~, ~, ~, errSt2b] = mm2.computeMeasurements(asset2, towers2, ekf2.x, 0, ekf2.stateMap);

M_pr2  = errSt2b.nPseudorange;
M_dop2 = 0;
if isfield(errSt2b,'doppler') && isfield(errSt2b.doppler,'z')
    M_dop2 = numel(errSt2b.doppler.z);
end
M_car2 = 0;
if isfield(errSt2b,'carrierPhase') && isfield(errSt2b.carrierPhase,'phi_m')
    M_car2 = numel(errSt2b.carrierPhase.phi_m);
end

assert(M_car2 > 0, 'T2 FAILED: no carrier rows in carrierFloatConfig measurement');
assert(numel(z2b) == M_pr2 + M_dop2 + M_car2, ...
    'T2 FAILED: z length %d != M_pr(%d)+M_dop(%d)+M_car(%d)=%d', ...
    numel(z2b), M_pr2, M_dop2, M_car2, M_pr2+M_dop2+M_car2);
fprintf('    z length %d = M_pr(%d)+M_dop(%d)+M_car(%d): PASS\n', ...
    numel(z2b), M_pr2, M_dop2, M_car2);

% ----------------------------------------------------------------
% T3: measType_perRow correctly labels all rows
% ----------------------------------------------------------------
fprintf('  T3: measType_perRow labeling ...\n');

types = errSt2b.measType_perRow;
assert(numel(types) == numel(z2b), ...
    'T3 FAILED: measType_perRow length %d != numel(z)=%d', numel(types), numel(z2b));

n_code    = sum(strcmp(types,'code'));
n_doppler = sum(strcmp(types,'doppler'));
n_carrier = sum(strcmp(types,'carrier'));

assert(n_code    == M_pr2,  'T3 FAILED: n_code=%d != M_pr=%d',    n_code,  M_pr2);
assert(n_doppler == M_dop2, 'T3 FAILED: n_doppler=%d != M_dop=%d', n_doppler, M_dop2);
assert(n_carrier == M_car2, 'T3 FAILED: n_carrier=%d != M_car=%d', n_carrier, M_car2);
fprintf('    code=%d, doppler=%d, carrier=%d (correct): PASS\n', ...
    n_code, n_doppler, n_carrier);

fprintf('=== test_postfit_by_meas_type: ALL PASS ===\n');
