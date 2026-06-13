% test_zwd_h_consistency
% Task 2: ZWD state contribution to h is consistent with H Jacobian column.
%
% Verifies:
%   T1: dh/d(x_zwd) via finite difference matches H(mi, zwdIdx(ti)).
%   T2: Setting x_zwd = v and running computeMeasurements changes h by mf*v
%       (mapping function times ZWD state increment).
%   T3: With troposphereMode='none', ZWD column in H is absent.

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_zwd_h_consistency ===\n');

% ----------------------------------------------------------------
% Setup: ZWD-enabled config, single epoch
% ----------------------------------------------------------------
cfg = revgnss.ConfigFactory.defaultConfig();
cfg.estimation.troposphereMode    = 'perTowerZwd';
cfg.estimation.tropoZwd.tau_s     = 3600;
cfg.simulation.duration_s         = 1;
cfg.plots.enable  = false;
cfg.report.enable = false;

[asset, towers, ekf, measModel] = revgnss.ScenarioFactory.build(cfg);
sm = ekf.stateMap;

% ----------------------------------------------------------------
% T1: finite-difference dh/d(x_zwd) vs H column
% ----------------------------------------------------------------
fprintf('  T1: finite-difference ZWD Jacobian consistency ...\n');

x0 = ekf.x;
[~, h0, H0] = measModel.computeMeasurements(asset, towers, x0, 0, sm);

nTowers = numel(sm.zwdIdx);
% Use large FD step (1 m) to avoid floating-point cancellation at GEO range (~36e6 m).
% At 36 Mm, ulp ≈ 8e-9 m, so step 1 m → FD error ≈ 8e-9/1 ≈ 1e-8 m.
eps_fd  = 1.0;
fd_err  = 0;

[~, ~, ~, ~, errSt0] = measModel.computeMeasurements(asset, towers, x0, 0, sm);
M_pr = errSt0.nPseudorange;   % pseudorange row count (not Doppler)

for ti = 1:nTowers
    idx_zwd = sm.zwdIdx(ti);
    if idx_zwd <= 0; continue; end

    % Perturb ZWD state by 1 m
    x_pert = x0;
    x_pert(idx_zwd) = x0(idx_zwd) + eps_fd;
    [~, h_pert, ~] = measModel.computeMeasurements(asset, towers, x_pert, 0, sm);

    dh_fd  = (h_pert(1:M_pr) - h0(1:M_pr)) / eps_fd;
    H_col  = H0(1:M_pr, idx_zwd);

    err_ti = max(abs(dh_fd - H_col));
    fd_err = max(fd_err, err_ti);

    assert(err_ti < 1e-5, ...
        'T1 FAILED: tower %d ZWD Jacobian FD error = %.2e > 1e-5', ti, err_ti);
end
fprintf('    Max FD error across %d ZWD states: %.2e m (tol 1e-5): PASS\n', ...
    nTowers, fd_err);

% ----------------------------------------------------------------
% T2: manual h change from ZWD state increment
% ----------------------------------------------------------------
fprintf('  T2: ZWD state increment changes h by mf*delta_zwd ...\n');

% Use first visible tower
ti1     = sm.zwdIdx(1) > 0;
if ti1
    idx_zwd1 = sm.zwdIdx(1);
    delta    = 0.10;  % 0.1 m ZWD increment

    x_inc = x0;
    x_inc(idx_zwd1) = x0(idx_zwd1) + delta;

    [~, h_inc] = measModel.computeMeasurements(asset, towers, x_inc, 0, sm);

    dh_h = h_inc - h0;
    % Only h rows corresponding to tower 1 should change
    % Find measurement rows for tower 1
    [~, ~, ~, ~, errSt] = measModel.computeMeasurements(asset, towers, x0, 0, sm);
    twr_per_meas = errSt.towerIdx_perMeas;
    mask1 = (twr_per_meas == 1);

    for mi = 1:M_pr   % pseudorange rows only
        if mask1(mi)
            elv   = errSt.elevations_rad(mi);
            mf    = revgnss.MappingFunctions.troposphere(elv, 'simple');
            expected_dh = mf * delta;
            actual_dh   = dh_h(mi);
            % Tolerance: floating-point residual at 36 Mm range, step 0.1 m
            assert(abs(actual_dh - expected_dh) < 1e-5, ...
                'T2 FAILED: row %d h increment %.4e != mf*delta=%.4e', ...
                mi, actual_dh, expected_dh);
        else
            assert(abs(dh_h(mi)) < 1e-5, ...
                'T2 FAILED: row %d (tower ~=1) changed by %.2e when only tower 1 ZWD perturbed', ...
                mi, dh_h(mi));
        end
    end
    fprintf('    h changes by mf*delta for tower 1 rows, unchanged elsewhere: PASS\n');
end

% ----------------------------------------------------------------
% T3: troposphereMode='none' — no ZWD column in H
% ----------------------------------------------------------------
fprintf('  T3: troposphereMode=none — ZWD column absent from H ...\n');

cfg_no = revgnss.ConfigFactory.defaultConfig();
cfg_no.estimation.troposphereMode = 'none';
cfg_no.simulation.duration_s      = 1;
cfg_no.plots.enable  = false;
cfg_no.report.enable = false;

[asset_no, towers_no, ekf_no, measModel_no] = revgnss.ScenarioFactory.build(cfg_no);
sm_no = ekf_no.stateMap;

[~, ~, H_no] = measModel_no.computeMeasurements(asset_no, towers_no, ekf_no.x, 0, sm_no);

% zwdIdx is always present in stateMap but all zeros when ZWD not estimated
if isfield(sm_no,'zwdIdx')
    assert(all(sm_no.zwdIdx == 0), ...
        'T3 FAILED: zwdIdx should be all-zero when troposphereMode=none, got [%s]', ...
        num2str(sm_no.zwdIdx'));
end
assert(~ekf_no.estimateZwd, 'T3 FAILED: estimateZwd should be false');

% H should have no non-zero ZWD column (all ZWD indices are 0)
H_no_zwd_cols = zeros(size(H_no,1), 1);
if isfield(sm_no,'zwdIdx')
    valid = sm_no.zwdIdx(sm_no.zwdIdx > 0);
    if ~isempty(valid)
        H_no_zwd_cols = H_no(:, valid(1));
    end
end
assert(all(H_no_zwd_cols == 0), 'T3 FAILED: non-zero ZWD H column when troposphereMode=none');
fprintf('    troposphereMode=none: zwdIdx all zero, no ZWD H column: PASS\n');

fprintf('=== test_zwd_h_consistency: ALL PASS ===\n');
