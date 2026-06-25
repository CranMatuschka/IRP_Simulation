% test_attitude_lever_arm_observability
%
% Verifies attitude Jacobian gating:
%   Case 1: nReceivers=1 → zero lever (finalizeConfig)       → H_att ≈ 0  (geometry kills it)
%   Case 2: nReceivers=2 → finalizeConfig auto-enables both attitude flags regardless of
%           requested flag value → H_att ≠ 0  (auto-attitude for multi-receiver)
%   Case 3: nReceivers=2 → nonzero lever, flag=true           → H_att ≠ 0  (observable)
%
% Note: finalizeConfig unconditionally sets estimateAttitude and
% estimateAttitudeFromPseudorange based on nReceivers:
%   nReceivers=1  → both false  (geometry: zero lever)
%   nReceivers>1  → both true   (auto-enable for multi-receiver)
%
% Lever arms set by finalizeConfig:
%   nReceivers=1  → [0;0;0]
%   nReceivers=2  → first two columns of ±1 m cross pattern

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_attitude_lever_arm_observability ===\n');

ZERO_THRESH    = 1e-6;
NONZERO_THRESH = 1e-3;

% Case 1: single receiver (zero lever arm) — flag=true but geometry kills it
H1 = getAttitudeJacCols(1, true);
m1 = max(abs(H1(:)));
fprintf('  Case 1 (nRx=1, zero lever, flag=true):      max|H_att| = %.2e  (expect ~ 0)\n', m1);
assert(m1 < ZERO_THRESH, 'Case1 FAILED: %.2e >= %.2e', m1, ZERO_THRESH);

% Case 2: nRx=2 with flag requested false — finalizeConfig overrides to true (auto-attitude).
% Verifies that multi-receiver configuration always enables attitude Jacobian.
H2 = getAttitudeJacCols(2, false);
m2 = max(abs(H2(:)));
fprintf('  Case 2 (nRx=2, flag=false→auto-true):      max|H_att| = %.2e  (expect >> 0)\n', m2);
assert(m2 > NONZERO_THRESH, 'Case2 FAILED: nRx=2 auto-enables attitude; max|H_att|=%.2e', m2);

% Case 3: two receivers (nonzero lever), flag=true → attitude observable
H3 = getAttitudeJacCols(2, true);
m3 = max(abs(H3(:)));
fprintf('  Case 3 (nRx=2, nonzero lever, flag=true):   max|H_att| = %.2e  (expect >> 0)\n', m3);
assert(m3 > NONZERO_THRESH, 'Case3 FAILED: %.2e <= %.2e', m3, NONZERO_THRESH);

fprintf('  PASS\n');

%% Local functions
function Hatt = getAttitudeJacCols(nReceivers, estimateFromPR)
    cfg = revgnss.ConfigFactory.idealConfig();
    cfg.simulation.dt_s       = 1.0;
    cfg.simulation.duration_s = 5;
    cfg.plots.enable          = false;

    % Set receiver count — finalizeConfig will set lever arms accordingly
    cfg.scenario.nReceivers = nReceivers;

    % Set attitude-from-pseudorange flag.
    % Note: finalizeConfig overrides both attitude flags based on nReceivers:
    %   nReceivers=1 → both false; nReceivers>1 → both true.
    cfg.estimator.estimateAttitudeFromPseudorange = estimateFromPR;
    if estimateFromPR
        cfg.estimator.estimateAttitude = true;
    end

    [asset, towers, ekf, measModel, ~, ~] = revgnss.ScenarioFactory.build(cfg);

    [~, ~, H, ~, ~] = measModel.computeMeasurements( ...
        asset, towers, ekf.x, 0, ekf.stateMap);

    if isempty(H)
        Hatt = zeros(0,3);
        return
    end
    Hatt = H(:, ekf.stateMap.euler_idx);
end
