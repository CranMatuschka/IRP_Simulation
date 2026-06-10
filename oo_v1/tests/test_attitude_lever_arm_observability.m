% test_attitude_lever_arm_observability
%
% Verifies:
%   Case 1: Zero lever arm -> attitude Jacobian columns are all near zero.
%   Case 2: Nonzero lever arm -> at least some attitude Jacobian columns are nonzero.
%
% Note: pseudorange alone observes attitude ONLY through the receiver
% antenna lever arm.  If the lever arm is zero, rotation of the spacecraft
% produces no change in antenna position, and the Jacobian is zero.

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_attitude_lever_arm_observability ===\n');

% Case 1: zero lever arm
H_zero = getAttitudeJacCols([0;0;0]);
maxAbsZero = max(abs(H_zero(:)));
fprintf('  Zero lever arm:    max |H_attitude| = %.2e  (expected ~ 0)\n', maxAbsZero);

% Case 2: nonzero lever arm
H_nonzero = getAttitudeJacCols([1.0;0.5;0.2]);
maxAbsNonzero = max(abs(H_nonzero(:)));
fprintf('  Nonzero lever arm: max |H_attitude| = %.2e  (expected >> 0)\n', maxAbsNonzero);

% Assertions
ZERO_THRESH    = 1e-6;
NONZERO_THRESH = 1e-3;

assert(maxAbsZero < ZERO_THRESH, ...
    'test_attitude_lever_arm_observability FAILED: zero lever arm Jacobian = %.2e (should be < %.2e)', ...
    maxAbsZero, ZERO_THRESH);

assert(maxAbsNonzero > NONZERO_THRESH, ...
    'test_attitude_lever_arm_observability FAILED: nonzero lever arm Jacobian = %.2e (should be > %.2e)', ...
    maxAbsNonzero, NONZERO_THRESH);

fprintf('  PASS\n');

%% Local functions
function Hatt = getAttitudeJacCols(leverArm)
    cfg = revgnss.ConfigFactory.idealConfig();
    cfg.simulation.dt_s          = 1.0;
    cfg.simulation.duration_s    = 5;
    cfg.plots.enable             = false;
    cfg.asset.receiverLeverArm_body_m = leverArm;

    [asset, towers, ekf, measModel, ~, ~] = revgnss.ScenarioFactory.build(cfg);

    t0 = 0;
    [~, ~, H, ~, ~] = measModel.computeMeasurements( ...
        asset, towers, ekf.x, t0, ekf.stateMap);

    if isempty(H)
        Hatt = zeros(0,3);
        return
    end
    Hatt = H(:, ekf.stateMap.euler_idx);
end
