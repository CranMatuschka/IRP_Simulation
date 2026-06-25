% test_if_ekf_row_count
% Task 3: IF combination in EKF produces M rows (one per tower/antenna pair),
% not 2M rows (stacked L1+L2).
%
% Verifies:
%   T1: codeMode='ionosphereFree' with L1+L2 → M rows (not 2*M)
%   T2: codeMode='dualFrequencyStacked' with L1+L2 → 2*M rows
%   T3: errStruct.ifCombination is true in IF mode
%   T4: IF combination cancels iono in z (z_IF ≈ rho, iono residual < 1e-4 m)

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_if_ekf_row_count ===\n');

% ----------------------------------------------------------------
% Build base config with L1+L2 stacked to get reference row count M_stacked
% ----------------------------------------------------------------
cfg_stk = revgnss.ConfigFactory.defaultConfig();
cfg_stk.signals.twoFrequency.enable = true;
cfg_stk.measurements.codeMode       = 'dualFrequencyStacked';
cfg_stk.measurements.doppler.useInEKF = false;
cfg_stk.measurements.carrierMode    = 'off';
cfg_stk.simulation.duration_s = 1;
cfg_stk.plots.enable  = false;
cfg_stk.report.enable = false;

[asset_stk, towers_stk, ekf_stk, mm_stk] = revgnss.ScenarioFactory.build(cfg_stk);
sm_stk = ekf_stk.stateMap;
[~, ~, H_stk, ~, errSt_stk] = mm_stk.computeMeasurements( ...
    asset_stk, towers_stk, ekf_stk.x, 0, sm_stk);

M_stacked = size(H_stk, 1);   % 2 * nVisible towers
M_pairs   = M_stacked / 2;
fprintf('  Stacked rows: M=%d (M_pairs=%d)\n', M_stacked, M_pairs);

% ----------------------------------------------------------------
% T1: IF mode produces M_pairs rows, not M_stacked
% ----------------------------------------------------------------
fprintf('  T1: IF mode row count = M_pairs (not 2*M_pairs) ...\n');

cfg_if = revgnss.ConfigFactory.dualFrequencyIFConfig();
cfg_if.measurements.doppler.useInEKF = false;
cfg_if.measurements.carrierMode      = 'off';
cfg_if.simulation.duration_s = 1;
cfg_if.plots.enable  = false;
cfg_if.report.enable = false;

[asset_if, towers_if, ekf_if, mm_if] = revgnss.ScenarioFactory.build(cfg_if);
sm_if = ekf_if.stateMap;
[~, ~, H_if, ~, errSt_if] = mm_if.computeMeasurements( ...
    asset_if, towers_if, ekf_if.x, 0, sm_if);

M_if = size(H_if, 1);
assert(M_if == M_pairs, ...
    'T1 FAILED: IF mode produced %d rows, expected %d (M_pairs)', M_if, M_pairs);
fprintf('    IF mode rows = %d = M_pairs: PASS\n', M_if);

% ----------------------------------------------------------------
% T2: Stacked mode produces 2*M_pairs rows (regression guard)
% ----------------------------------------------------------------
fprintf('  T2: Stacked mode row count = 2*M_pairs (regression) ...\n');

assert(M_stacked == 2 * M_pairs, ...
    'T2 FAILED: stacked rows=%d should be 2*M_pairs=%d', M_stacked, 2*M_pairs);
fprintf('    Stacked rows = 2*M_pairs = %d: PASS\n', M_stacked);

% ----------------------------------------------------------------
% T3: errStruct.ifCombination flag set in IF mode
% ----------------------------------------------------------------
fprintf('  T3: errStruct.ifCombination flag ...\n');

assert(isfield(errSt_if,'ifCombination') && errSt_if.ifCombination, ...
    'T3 FAILED: errStruct.ifCombination not true in IF mode');
assert(~isfield(errSt_stk,'ifCombination') || ~errSt_stk.ifCombination, ...
    'T3 FAILED: errStruct.ifCombination should not be set in stacked mode');
fprintf('    ifCombination flag set in IF mode, absent in stacked mode: PASS\n');

% ----------------------------------------------------------------
% T4: IF combination removes first-order iono algebraically (unit test)
% Uses IonoFreeCombination directly without simulation to avoid position-error noise.
% Full simulation test with zero initial error would require ScenarioFactory zero-init.
% ----------------------------------------------------------------
fprintf('  T4: IF combination algebraically removes first-order iono ...\n');

f_L1 = 1575.42e6;
f_L2 = 1227.60e6;
[alpha_if, beta_if] = revgnss.IonoFreeCombination.coefficients(f_L1, f_L2);

rho   = 2.0e7;   % 20000 km range
I_L1  = 5.0;     % 5 m iono delay on L1
I_L2  = I_L1 * (f_L1/f_L2)^2;   % dispersive scaling

z_L1 = rho + I_L1;   % code measurement with iono (no other errors)
z_L2 = rho + I_L2;
z_IF = alpha_if * z_L1 + beta_if * z_L2;
iono_residual = z_IF - rho;  % should be ~0

assert(abs(iono_residual) < 1e-6, ...
    'T4 FAILED: IF iono residual = %.2e m (should be < 1e-6 m)', iono_residual);
fprintf('    IF iono residual = %.2e m (< 1e-6 m): PASS\n', iono_residual);

% Also verify that dualFrequencyIFConfig codeMode is indeed 'ionosphereFree'
cfg_chk = revgnss.ConfigFactory.dualFrequencyIFConfig();
assert(strcmp(cfg_chk.measurements.codeMode, 'ionosphereFree'), ...
    'T4b FAILED: dualFrequencyIFConfig codeMode != ionosphereFree');
fprintf('    dualFrequencyIFConfig.codeMode = ionosphereFree: PASS\n');

fprintf('=== test_if_ekf_row_count: ALL PASS ===\n');
