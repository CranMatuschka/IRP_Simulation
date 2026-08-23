% test_no_truth_leak_in_prediction  Phase 4b.2: EKF prediction reads no truth STATE.
%
% Realizes confusion fix C-10: truth enters the estimator ONLY through the
% measurement. The prediction (time propagation) must depend only on the EKF state,
% config, and tower-clock NOISE COEFFICIENTS (the Q model) — never on the truth
% realization (clock bias / fractional frequency). This test perturbs ONLY the truth
% realization and asserts the predicted x and P are bit-identical, proving there is no
% truth-state leakage into prediction.
thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));
addpath(fullfile(thisDir, '..', 'config'));
fprintf('=== test_no_truth_leak_in_prediction ===\n');

rng(42, 'twister');
cfg = revgnss.ConfigFactory.defaultConfig();
cfg.simulation.duration_s = 10;
cfg.simulation.dt_s       = 1;
cfg.plots.enable          = false;
cfg.report.enable         = false;
sim = revgnss.ReverseGNSSSimulation(cfg);
sim.initialize();

ekf = sim.ekf;
dt  = cfg.simulation.dt_s;
tcm = cellfun(@(t) t.clock, sim.towers, 'UniformOutput', false);

x0 = ekf.x;  P0 = ekf.P;

% Baseline prediction with the true clock realizations.
ekf.x = x0;  ekf.P = P0;  rng(7, 'twister');
ekf.predict(dt, tcm, 0);
x1 = ekf.x;  P1 = ekf.P;

% Perturb ONLY the tower-clock truth realization (bias_s, fracFreq); the Q noise
% coefficients (h0/h-1/h-2) are untouched. Predict again from the same state + RNG.
for i = 1:numel(tcm)
    tcm{i}.bias_s   = tcm{i}.bias_s   + 1234.5;
    tcm{i}.fracFreq = tcm{i}.fracFreq + 6.7e-9;
end
ekf.x = x0;  ekf.P = P0;  rng(7, 'twister');
ekf.predict(dt, tcm, 0);

assert(isequal(ekf.x, x1), ...
    'FAILED: predicted STATE changed under a tower-clock truth-realization perturbation — truth leaks into prediction.');
assert(isequal(ekf.P, P1), ...
    'FAILED: predicted COVARIANCE changed under a tower-clock truth-realization perturbation — truth leaks into prediction.');
fprintf('  prediction invariant to tower-clock truth realization: PASS\n');
fprintf('=== test_no_truth_leak_in_prediction: PASS ===\n');
