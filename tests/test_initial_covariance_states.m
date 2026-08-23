% test_initial_covariance_states
% Task 1: Initial covariance for float ambiguity and ZWD states.
%
% Verifies that ScenarioFactory.build sets P0(ambIdx, ambIdx) = initialSigma_m^2
% and P0(zwdIdx, zwdIdx) = initialSigma_m^2.
% Before fix: these states had P0 = 0 (zeros(nx) default), making the EKF
% start with artificially low uncertainty.

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_initial_covariance_states ===\n');

% ----------------------------------------------------------------
% T1: Float ambiguity initial covariance = initialSigma_m^2
% ----------------------------------------------------------------
fprintf('  T1: P0 for ambiguity states ...\n');

sigma_amb = 150.0;   % non-default, to confirm actual value is used

cfg_amb = revgnss.ConfigFactory.defaultConfig();
cfg_amb.measurements.carrierMode             = 'ekfFloat';
cfg_amb.estimation.ambiguityMode             = 'floatPerTowerSignal';
cfg_amb.estimation.ambiguity.initialSigma_m  = sigma_amb;
cfg_amb.plots.enable  = false;
cfg_amb.report.enable = false;

[~, ~, ekf_amb] = revgnss.ScenarioFactory.build(cfg_amb);

sm_amb   = ekf_amb.stateMap;
P0_amb   = ekf_amb.P;
nTowers  = ekf_amb.nTowers;

for ti = 1:nTowers
    idx = sm_amb.ambiguityIdx(ti, 1);
    assert(idx > 0 && idx <= ekf_amb.nx, ...
        'ambiguityIdx(%d,1)=%d out of range', ti, idx);
    P0_ii = P0_amb(idx, idx);
    assert(abs(P0_ii - sigma_amb^2) < 1e-9, ...
        'T1 FAILED: P0(ambiguityIdx(%d)) = %.4f, expected %.4f (sigma_m=%g)', ...
        ti, P0_ii, sigma_amb^2, sigma_amb);
end
fprintf('    P0 ambiguity = %.4f m^2 = (%.1f m)^2 for all %d towers: PASS\n', ...
    sigma_amb^2, sigma_amb, nTowers);

% ----------------------------------------------------------------
% T2: ZWD initial covariance = initialSigma_m^2
% ----------------------------------------------------------------
fprintf('  T2: P0 for ZWD states ...\n');

sigma_zwd = 0.25;   % non-default (default is 0.10)

cfg_zwd = revgnss.ConfigFactory.defaultConfig();
cfg_zwd.estimation.troposphereMode             = 'perTowerZwd';
cfg_zwd.estimation.tropoZwd.initialSigma_m     = sigma_zwd;
cfg_zwd.plots.enable  = false;
cfg_zwd.report.enable = false;

[~, ~, ekf_zwd] = revgnss.ScenarioFactory.build(cfg_zwd);

sm_zwd  = ekf_zwd.stateMap;
P0_zwd  = ekf_zwd.P;
nTwr    = ekf_zwd.nTowers;

for ti = 1:nTwr
    idx = sm_zwd.zwdIdx(ti);
    assert(idx > 0 && idx <= ekf_zwd.nx, ...
        'zwdIdx(%d)=%d out of range', ti, idx);
    P0_ii = P0_zwd(idx, idx);
    assert(abs(P0_ii - sigma_zwd^2) < 1e-9, ...
        'T2 FAILED: P0(zwdIdx(%d)) = %.6f, expected %.6f (sigma_m=%g)', ...
        ti, P0_ii, sigma_zwd^2, sigma_zwd);
end
fprintf('    P0 ZWD = %.6f m^2 = (%.2f m)^2 for all %d towers: PASS\n', ...
    sigma_zwd^2, sigma_zwd, nTwr);

% ----------------------------------------------------------------
% T3: Base states unaffected (regression)
% ----------------------------------------------------------------
fprintf('  T3: Base state P0 unaffected ...\n');

cfg_base = revgnss.ConfigFactory.defaultConfig();
cfg_base.estimation.troposphereMode = 'perTowerZwd';
cfg_base.estimation.ambiguityMode   = 'none';
cfg_base.plots.enable  = false;
cfg_base.report.enable = false;
[~, ~, ekf_base] = revgnss.ScenarioFactory.build(cfg_base);

sm_b = ekf_base.stateMap;
P0_b = ekf_base.P;
assert(abs(P0_b(sm_b.b_rx_idx, sm_b.b_rx_idx) - cfg_base.estimator.P0_bRx_m^2) < 1e-9, ...
    'T3 FAILED: b_rx P0 changed');
fprintf('    b_rx P0 = %.1f m^2 (unchanged): PASS\n', P0_b(sm_b.b_rx_idx, sm_b.b_rx_idx));

fprintf('=== test_initial_covariance_states: ALL PASS ===\n');
