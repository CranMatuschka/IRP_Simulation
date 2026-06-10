% test_measurement_jacobian_position_sign  Finite-difference check of H(position).
%
% For pseudorange rho = ||r_ant - r_tower||, the Jacobian w.r.t. ECEF CM position
% should be:   H_pos(i,:) = (r_ant_est - r_tower_i)' / rho_i
%
% This test verifies analytically computed H matches numerical finite difference
% to better than 1e-4 relative error.

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

% Analytical measurements
[z, h, H, R, ~] = measModel.computeMeasurements(asset, towers, x_est, 0, stateMap);

if isempty(z)
    fprintf('  No visible towers at epoch 0 — cannot test Jacobian.\n');
    fprintf('  PASS (vacuous)\n');
    return
end

M = numel(z);
fprintf('  Visible towers: %d\n', M);

% Determine which towers are visible (same as inside computeMeasurements)
[visible, ~] = measModel.computeVisibility(towers, asset.getAntennaPositionECEF());
visIds = find(visible);

% Numerical finite-difference of H w.r.t. r_cm (3 position states)
stepFD = 0.5;   % 0.5 m perturbation
H_fd   = zeros(M, 3);

for ai = 1:3
    dx = zeros(3,1);  dx(ai) = stepFD;

    % Perturbed antenna positions
    r_ant_p = revgnss.AttitudeKinematics.applyLeverArm(r_cm + dx, euler, lever);
    r_ant_m = revgnss.AttitudeKinematics.applyLeverArm(r_cm - dx, euler, lever);

    for mi = 1:M
        ti    = visIds(mi);
        r_twr = towers{ti}.getAntennaPositionECEF();
        rho_p = norm(r_ant_p - r_twr);
        rho_m = norm(r_ant_m - r_twr);
        H_fd(mi, ai) = (rho_p - rho_m) / (2 * stepFD);
    end
end

% Extract analytical position block from H
H_pos = H(:, stateMap.r_idx);   % M x 3

% Compare: relative error per entry
denom   = max(abs(H_fd), 1e-10);
relErr  = abs(H_pos - H_fd) ./ denom;
maxRel  = max(relErr(:));

fprintf('  Max relative Jacobian error (position): %.2e\n', maxRel);
assert(maxRel < 1e-4, ...
    'test_measurement_jacobian_position_sign FAILED: relative error %.2e > 1e-4', maxRel);

% Sign check: H_pos row should be aligned with unit LOS vector (tower → receiver).
r_ant = revgnss.AttitudeKinematics.applyLeverArm(r_cm, euler, lever);
r_twr1 = towers{visIds(1)}.getAntennaPositionECEF();
u1 = (r_ant - r_twr1) / norm(r_ant - r_twr1);
dotProd = dot(H_pos(1,:)', u1);

fprintf('  LOS alignment (dot product, expected ~1): %.6f\n', dotProd);
assert(dotProd > 0.99, ...
    'test_measurement_jacobian_position_sign FAILED: H_pos row not aligned with LOS vector (dot=%.4f)', dotProd);

fprintf('  PASS\n');
