% test_attitude_lever_arm_observability
%
% Verifies the two-level attitude Jacobian gating:
%   Case 1: zero lever arm                        → H_att ≈ 0  (geometry)
%   Case 2: nonzero lever arm, flag=false (default) → H_att ≈ 0  (flag gate)
%   Case 3: nonzero lever arm, flag=true           → H_att ≠ 0  (observable)
%
% Attitude H columns are nonzero ONLY when
%   estimateAttitudeFromPseudorange == true  AND  norm(leverArm) > 0.

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_attitude_lever_arm_observability ===\n');

ZERO_THRESH    = 1e-6;
NONZERO_THRESH = 1e-3;

% Case 1: zero lever arm (flag=true but geometry kills it)
H1 = getAttitudeJacCols([0;0;0], true);
m1 = max(abs(H1(:)));
fprintf('  Case 1 (zero lever, flag=true):      max|H_att| = %.2e  (expect ~ 0)\n', m1);
assert(m1 < ZERO_THRESH, 'Case1 FAILED: %.2e >= %.2e', m1, ZERO_THRESH);

% Case 2: nonzero lever arm but flag=false (default config)
H2 = getAttitudeJacCols([1.0;0.5;0.2], false);
m2 = max(abs(H2(:)));
fprintf('  Case 2 (nonzero lever, flag=false):  max|H_att| = %.2e  (expect ~ 0)\n', m2);
assert(m2 < ZERO_THRESH, 'Case2 FAILED: %.2e >= %.2e', m2, ZERO_THRESH);

% Case 3: nonzero lever arm AND flag=true → attitude observable
H3 = getAttitudeJacCols([1.0;0.5;0.2], true);
m3 = max(abs(H3(:)));
fprintf('  Case 3 (nonzero lever, flag=true):   max|H_att| = %.2e  (expect >> 0)\n', m3);
assert(m3 > NONZERO_THRESH, 'Case3 FAILED: %.2e <= %.2e', m3, NONZERO_THRESH);

fprintf('  PASS\n');

%% Local functions
function Hatt = getAttitudeJacCols(leverArm, estimateFromPR)
    cfg = revgnss.ConfigFactory.idealConfig();
    cfg.simulation.dt_s       = 1.0;
    cfg.simulation.duration_s = 5;
    cfg.plots.enable          = false;

    % Set lever arm via new plural field (backward-compat: also set singular)
    cfg.asset.receiverLeverArm_body_m  = leverArm(:);
    cfg.asset.receiverLeverArms_body_m = leverArm(:);

    % Set attitude-from-pseudorange flag
    cfg.estimator.estimateAttitudeFromPseudorange = estimateFromPR;

    [asset, towers, ekf, measModel, ~, ~] = revgnss.ScenarioFactory.build(cfg);

    [~, ~, H, ~, ~] = measModel.computeMeasurements( ...
        asset, towers, ekf.x, 0, ekf.stateMap);

    if isempty(H)
        Hatt = zeros(0,3);
        return
    end
    Hatt = H(:, ekf.stateMap.euler_idx);
end
