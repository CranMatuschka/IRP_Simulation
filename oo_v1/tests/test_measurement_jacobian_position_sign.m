% test_measurement_jacobian_position_sign  Finite-difference check of H(position).
%
% CHANGED: v3→v4 — Issue 12
% Naming: H_model = H as returned by MeasurementModel.computeH.
%         H_fd_ref = independently recomputed finite-difference Jacobian.
% We do NOT call H_model "analytic" because the internal implementation
% may use numerical differentiation (FD) when corrections are enabled.
%
% Tolerances: rel_tol = 1e-4 for geometry-only rows;
%             abs_tol = 1e-7 for rows where |H_fd_ref| is small.

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_measurement_jacobian_position_sign ===\n');

cfg = revgnss.ConfigFactory.idealConfig();
cfg.simulation.duration_s = 10;
cfg.plots.enable  = false;
cfg.report.enable = false;

[asset, towers, ekf, measModel, ~, ~] = revgnss.ScenarioFactory.build(cfg);

x_est    = ekf.x;
stateMap = ekf.stateMap;
lever    = asset.receiverLeverArm_body_m;
euler    = x_est(stateMap.euler_idx);
r_cm     = x_est(stateMap.r_idx);

% H_model: H as returned by MeasurementModel (may use FD internally)
[z, h, H_model, R, errStruct] = measModel.computeMeasurements(asset, towers, x_est, 0, stateMap);

if isempty(z)
    fprintf('  No visible towers at epoch 0 — cannot test Jacobian.\n');
    fprintf('  PASS (vacuous)\n');
    return
end

M = numel(z);
fprintf('  Measurements (tower-antenna pairs): %d\n', M);

% Tower/antenna index for each measurement (stored by computeMeasurements)
twr_list = errStruct.towerIdx_perMeas;   % [M x 1]
ant_list = errStruct.antennaIdx_perMeas; % [M x 1]
leverArms = asset.receiverLeverArms_body_m;  % 3 x N_ant

% H_fd_ref: independently recomputed FD Jacobian (step = 1e-5 * |r| or 1 m)
stepFD  = max(1e-5 * norm(r_cm), 1.0);
H_fd_ref = zeros(M, 3);

for ai = 1:3
    dx = zeros(3,1);  dx(ai) = stepFD;

    for mi = 1:M
        lv    = leverArms(:, ant_list(mi));
        r_ant_p = revgnss.AttitudeKinematics.applyLeverArm(r_cm + dx, euler, lv);
        r_ant_m = revgnss.AttitudeKinematics.applyLeverArm(r_cm - dx, euler, lv);
        r_twr = towers{twr_list(mi)}.getAntennaPositionECEF();
        rho_p = norm(r_ant_p - r_twr);
        rho_m = norm(r_ant_m - r_twr);
        H_fd_ref(mi, ai) = (rho_p - rho_m) / (2 * stepFD);
    end
end

% Extract position block from H_model
H_pos = H_model(:, stateMap.r_idx);   % M x 3

% CHANGED: v3→v4 — Issue 12 tolerances
rel_tol = 1e-4;   % for geometry-only rows
abs_tol = 1e-7;   % for rows where |H_fd_ref| is small
err     = abs(H_pos - H_fd_ref);
rel_err = err ./ max(abs(H_fd_ref), 1e-10);
passes  = rel_err(:) < rel_tol | err(:) < abs_tol;
maxRel  = max(rel_err(:));

fprintf('  Max relative Jacobian error (H_model vs H_fd_ref): %.2e\n', maxRel);
assert(all(passes), ...
    'test_measurement_jacobian_position_sign FAILED: H_model does not match H_fd_ref within tolerance (max rel=%.2e)', maxRel);

% Sign check: H_pos first row aligned with unit LOS vector (tower → receiver).
lv1   = leverArms(:, ant_list(1));
r_ant = revgnss.AttitudeKinematics.applyLeverArm(r_cm, euler, lv1);
r_twr1 = towers{twr_list(1)}.getAntennaPositionECEF();
u1 = (r_ant - r_twr1) / norm(r_ant - r_twr1);
dotProd = dot(H_pos(1,:)', u1);

fprintf('  LOS alignment (dot product, expected ~1): %.6f\n', dotProd);
assert(dotProd > 0.99, ...
    'test_measurement_jacobian_position_sign FAILED: H_pos row not aligned with LOS vector (dot=%.4f)', dotProd);

fprintf('  PASS\n');
