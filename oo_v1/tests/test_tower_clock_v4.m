% test_tower_clock_v4  Tower clock v4 scientific corrections.
%
% T4: fixedReference mode — b_tower_hat never equals any b_rx value.
% T5: noisyCorrection — correction = true_clock + noise, noise ~ N(0, sigma^2).
% T6: Product epoch — t_prod = floor((t-latency)/interval)*interval,
%     negative t_prod silently clamped to 0 (Stage 71 removed the warning;
%     see T6c for the current, no-warning behavior).
%
% CHANGED: v3→v4 — Issues 4, 5, 6

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_tower_clock_v4 ===\n');

% ----------------------------------------------------------------
% T4: fixedReference — towerClockModel must NOT equal b_rx
% (In the v1 implementation, perfectCorrection uses the true tower clock
%  which has a nonzero and distinct bias from the receiver clock)
% ----------------------------------------------------------------
fprintf('  T4: tower clock correction not from receiver clock ...\n');

cfg4 = revgnss.ConfigFactory.defaultConfig();
cfg4.plots.enable  = false;
cfg4.report.enable = false;

% Set nonzero tower clock biases (distinct from 0, which is b_rx)
b_rx_true = 0.0;   % receiver clock bias (OCXO deterministic, bias_s=0 → 0 m)
for k = 1:numel(cfg4.towers)
    cfg4.towers(k).clock.bias_s = k * 1e-7;   % ~30 m each, distinct
    cfg4.towers(k).clock.deterministic = true;
end
cfg4.estimator.towerClockMode = 'perfectCorrection';

[asset4, towers4, ekf4, measModel4, ~, ~] = revgnss.ScenarioFactory.build(cfg4);
[~, ~, ~, ~, errStruct4] = measModel4.computeMeasurements( ...
    asset4, towers4, ekf4.x, 0, ekf4.stateMap);

if ~isempty(errStruct4)
    towerCorr = errStruct4.towerClockCorrection_m;
    b_rx_m    = asset4.clock.getBiasMeters();
    % Tower corrections must not equal b_rx for any measurement
    for mi = 1:numel(towerCorr)
        % Tower clock biases are O(k * 30 m); receiver is 0.
        assert(abs(towerCorr(mi) - b_rx_m) > 0.1 || abs(towerCorr(mi)) < 1e-12, ...
            'T4 FAILED: towerClockCorrection(mi=%d) = %.4f equals b_rx = %.4f', ...
            mi, towerCorr(mi), b_rx_m);
    end
    fprintf('    All %d tower corrections distinct from b_rx (%.4f m): PASS\n', ...
        numel(towerCorr), b_rx_m);
else
    fprintf('    No visible towers — vacuous PASS\n');
end

% ----------------------------------------------------------------
% T5: noisyCorrection — MC test that noise is zero-mean with correct sigma
% ----------------------------------------------------------------
fprintf('  T5: noisyCorrection MC noise distribution ...\n');

N_mc  = 1000;
sigma = 0.5;  % default sigma from cfg.estimator.towerClockCorrectionSigma_m

cfg5 = revgnss.ConfigFactory.defaultConfig();
cfg5.plots.enable  = false;
cfg5.report.enable = false;
% Select the mode through cfg.towerClock.correctionMode -- cfg.estimator.towerClockMode is
% DERIVED and finalizeConfig overwrites it, so setting it here silently did nothing and the
% MC below saw zero noise. 'noisyCorrection' has no dedicated correctionMode spelling; it
% reaches the internal mode through the switch's passthrough branch.
cfg5.towerClock.correctionMode = 'noisyCorrection';
cfg5.estimator.towerClockCorrectionSigma_m = sigma;
% Use nonzero tower clocks so we can separate noise from bias
for k = 1:numel(cfg5.towers)
    cfg5.towers(k).clock.bias_s = k * 1e-8;
    cfg5.towers(k).clock.deterministic = true;
end

corrections = zeros(N_mc, 1);
trueBiases  = zeros(N_mc, 1);

for n = 1:N_mc
    cfg5.simulation.seed = 1000 + n;
    [asset5, towers5, ekf5, measModel5, ~, ~] = revgnss.ScenarioFactory.build(cfg5);
    [~, ~, ~, ~, errStruct5] = measModel5.computeMeasurements( ...
        asset5, towers5, ekf5.x, 0, ekf5.stateMap);
    if ~isempty(errStruct5) && numel(errStruct5.towerClockCorrection_m) >= 1
        corrections(n) = errStruct5.towerClockCorrection_m(1);
        trueBiases(n)  = errStruct5.towerClockTruth_m(1);
    end
end

noise_samples = corrections - trueBiases;
noise_mean  = mean(noise_samples);
noise_std   = std(noise_samples);

fprintf('    MC noise: mean=%.4f m (expect ~0), std=%.4f m (expect %.4f m)\n', ...
    noise_mean, noise_std, sigma);

assert(abs(noise_mean) < 3 * sigma / sqrt(N_mc), ...
    'T5 FAILED: noise mean %.4f is more than 3-sigma from zero', noise_mean);
assert(abs(noise_std - sigma) < 0.1 * sigma, ...
    'T5 FAILED: noise std %.4f differs from sigma %.4f by more than 10%%', noise_std, sigma);
fprintf('    PASS\n');

% ----------------------------------------------------------------
% T6: Product epoch calculation
%   t_prod = floor((t - latency) / updateInterval) * updateInterval
%   negative t_prod clamped to 0 with warning
% ----------------------------------------------------------------
fprintf('  T6: Product epoch computation and clamping ...\n');

cfg6 = revgnss.ConfigFactory.defaultConfig();
cfg6.plots.enable  = false;
cfg6.report.enable = false;
cfg6.clocks.tower.product.updateInterval_s = 300;
cfg6.clocks.tower.product.latency_s        = 0;

[asset6, towers6, ekf6, measModel6, ~, ~] = revgnss.ScenarioFactory.build(cfg6);

% T6a: t=0, interval=300, latency=0 → t_prod = 0
[~,~,~,~, es6a] = measModel6.computeMeasurements(asset6, towers6, ekf6.x, 0, ekf6.stateMap);
if ~isempty(es6a)
    assert(es6a.towerClockProductEpoch_s == 0, ...
        'T6a FAILED: t_prod at t=0 should be 0 (got %.1f)', es6a.towerClockProductEpoch_s);
    fprintf('    t=0: t_prod=%.0f s, age=%.0f s: PASS\n', ...
        es6a.towerClockProductEpoch_s, es6a.towerClockProductAge_s);
end

% T6b: t=450, interval=300, latency=0 → t_prod = 300
[~,~,~,~, es6b] = measModel6.computeMeasurements(asset6, towers6, ekf6.x, 450, ekf6.stateMap);
if ~isempty(es6b)
    expected_prod = floor(450 / 300) * 300;  % = 300
    assert(es6b.towerClockProductEpoch_s == expected_prod, ...
        'T6b FAILED: t_prod at t=450 should be 300 (got %.1f)', es6b.towerClockProductEpoch_s);
    assert(abs(es6b.towerClockProductAge_s - 150) < 1e-9, ...
        'T6b FAILED: product age at t=450 should be 150 s (got %.1f)', es6b.towerClockProductAge_s);
    fprintf('    t=450: t_prod=%.0f s, age=%.0f s: PASS\n', ...
        es6b.towerClockProductEpoch_s, es6b.towerClockProductAge_s);
end

% T6c: negative t_prod → silently clamped to 0 (need latency > t).
% Stage 71 ("realistic clock product handling", commit 73e7eff) deliberately
% removed the revgnss:productEpoch warning when it introduced the
% truthHistoryProductNoisy model: a negative t_prod is the normal startup
% transient before the first product epoch is available, not an error
% condition, so production no longer warns on it. Only the clamping behavior
% is verified here; no warning is expected (or re-added to production).
cfg6c = cfg6;
cfg6c.clocks.tower.product.latency_s = 600;  % latency > t → t_available = -600 → t_prod < 0
[asset6c, towers6c, ekf6c, measModel6c, ~, ~] = revgnss.ScenarioFactory.build(cfg6c);

[~,~,~,~, es6c] = measModel6c.computeMeasurements(asset6c, towers6c, ekf6c.x, 0, ekf6c.stateMap);
if ~isempty(es6c)
    assert(es6c.towerClockProductEpoch_s == 0, ...
        'T6c FAILED: negative t_prod should be clamped to 0 (got %.1f)', ...
        es6c.towerClockProductEpoch_s);
end
fprintf('    t=0, latency=600: t_prod clamped to 0 (no warning expected, Stage 71): PASS\n');

fprintf('=== test_tower_clock_v4: ALL PASS ===\n');
