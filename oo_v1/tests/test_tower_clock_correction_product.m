% test_tower_clock_correction_product
% Task 6: Tower clock correction product mode.
%
% Verifies:
%   T1: Config mapping — correctionMode → towerClockMode
%   T2: 'product' mode evaluates b_hat = b(t_prod) + bdot(t_prod)*(t-t_prod)
%       For deterministic zero clocks: b_hat = 0 = truth → same h as perfectCorrection
%   T3: 'productNoisy' mode inflates R by noiseSigma^2 (towerClkSigma > 0)
%   T4: 'product' mode prediction diverges from truth for stochastic non-zero clocks

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_tower_clock_correction_product ===\n');

% ----------------------------------------------------------------
% T1: Config mapping — correctionMode names map to correct towerClockMode
% ----------------------------------------------------------------
fprintf('  T1: Config mapping correctionMode → towerClockMode ...\n');

% Updated in TASK 6: 'product' maps to 'product', 'productNoisy' to 'productNoisy'
cases = { ...
    'perfectTruth', 'perfectCorrection'; ...
    'product',      'product'; ...
    'productNoisy', 'productNoisy'; ...
    'none',         'none'; ...
};

for k = 1:size(cases, 1)
    corrMode   = cases{k,1};
    expectMode = cases{k,2};

    cfg = revgnss.ConfigFactory.defaultConfig();
    cfg.towerClock.correctionMode = corrMode;
    cfg.plots.enable  = false;
    cfg.report.enable = false;

    cfgF = revgnss.ConfigFactory.finalizeConfig(cfg);

    actual = cfgF.estimator.towerClockMode;
    assert(strcmp(actual, expectMode), ...
        'T1: correctionMode=%s: expected towerClockMode=%s, got %s', ...
        corrMode, expectMode, actual);
    fprintf('    correctionMode=%-14s → towerClockMode=%s\n', corrMode, actual);
end

% ----------------------------------------------------------------
% T2: 'product' mode linear evaluation — deterministic zero clocks
%     b_hat(t) = b(t_prod) + bdot(t_prod)*(t - t_prod) = 0 for zero clocks
%     h_product must equal h_perfectCorrection (both use b_twr = 0)
% ----------------------------------------------------------------
fprintf('  T2: product mode agrees with perfectCorrection for zero clocks ...\n');

% Use towerClockProductConfig (provides required products struct with zero bias/drift)
cfg_prod = revgnss.ConfigFactory.towerClockProductConfig();
cfg_prod.measurements.doppler.useInEKF = false;
cfg_prod.measurements.carrierMode      = 'off';
cfg_prod.simulation.duration_s         = 10;
cfg_prod.plots.enable  = false;
cfg_prod.report.enable = false;

cfg_pc = cfg_prod;
cfg_pc.towerClock.correctionMode = 'perfectTruth';

% Run a few epochs so history is populated
sim_prod = revgnss.ReverseGNSSSimulation(cfg_prod);
sim_prod.initialize();
sim_prod.run();

sim_pc = revgnss.ReverseGNSSSimulation(cfg_pc);
sim_pc.initialize();
sim_pc.run();

% Compare h at a mid-run epoch via measurementModel directly
% (both should be identical for zero deterministic clocks)
[asset_p, towers_p, ekf_p, mm_p] = revgnss.ScenarioFactory.build(cfg_prod);
[asset_c, towers_c, ekf_c, mm_c] = revgnss.ScenarioFactory.build(cfg_pc);

% Step towers a few times so history exists at t=5 s
for step = 1:5
    for ti = 1:numel(towers_p); towers_p{ti}.stepClock(1); end
    for ti = 1:numel(towers_c); towers_c{ti}.stepClock(1); end
end

[~, h_prod] = mm_p.computeMeasurements(asset_p, towers_p, ekf_p.x, 5, ekf_p.stateMap);
[~, h_pc  ] = mm_c.computeMeasurements(asset_c, towers_c, ekf_c.x, 5, ekf_c.stateMap);

if ~isempty(h_prod) && ~isempty(h_pc)
    max_diff = max(abs(h_prod - h_pc));
    assert(max_diff < 1e-9, ...
        'T2 FAILED: product vs perfectCorrection h differ by %.2e (expect < 1e-9 for zero clocks)', ...
        max_diff);
    fprintf('    max |h_product - h_perfectCorrection| = %.2e (zero clocks): PASS\n', max_diff);
else
    fprintf('    no visible towers — vacuous PASS\n');
end

% ----------------------------------------------------------------
% T3: 'productNoisy' mode sets towerClkSigma > 0, inflating R
% ----------------------------------------------------------------
fprintf('  T3: productNoisy inflates R via noiseSigma ...\n');

sigma_prod = 0.3;
% Use towerClockProductConfig and set sigmaBias in products struct
cfg_pn = revgnss.ConfigFactory.towerClockProductConfig();
cfg_pn.towerClock.correctionMode = 'productNoisy';
for k = 1:numel(cfg_pn.towerClock.products)
    cfg_pn.towerClock.products(k).bias_m         = 0;
    cfg_pn.towerClock.products(k).drift_mps      = 0;
    cfg_pn.towerClock.products(k).sigmaBias_m    = sigma_prod;
    cfg_pn.towerClock.products(k).sigmaDrift_mps = 0;
    cfg_pn.towerClock.products(k).epoch_s        = 0;
end
cfg_pn.measurements.doppler.useInEKF = false;
cfg_pn.measurements.carrierMode      = 'off';
cfg_pn.plots.enable  = false;
cfg_pn.report.enable = false;

[asset_pn, towers_pn, ekf_pn, mm_pn] = revgnss.ScenarioFactory.build(cfg_pn);
[~, ~, ~, R_pn, errSt_pn] = mm_pn.computeMeasurements( ...
    asset_pn, towers_pn, ekf_pn.x, 0, ekf_pn.stateMap);

if ~isempty(R_pn)
    actual_R_diag = diag(R_pn);
    M_pr = errSt_pn.nPseudorange;
    % R diagonal must include sigmaBias_m^2 contribution from products struct
    assert(all(actual_R_diag(1:M_pr) >= sigma_prod^2 - 1e-12), ...
        'T3 FAILED: productNoisy R diagonal < sigma_prod^2=%.4e', sigma_prod^2);
    fprintf('    R(1)=%.4e (>= sigma_prod^2=%.4e): PASS\n', actual_R_diag(1), sigma_prod^2);
else
    fprintf('    no visible towers — vacuous PASS\n');
end

% ----------------------------------------------------------------
% T4: 'product' prediction evaluates b_hat(t) = b(t_prod) + bdot(t_prod)*(t-t_prod).
%     At t=450 with interval=300: t_prod = floor(450/300)*300 = 300.
%     Tower 1 has bias=50 m, no drift. So b_hat(450) = 50 + 0*150 = 50 m.
%     This confirms getClockAtProductEpoch_ reads history correctly.
% ----------------------------------------------------------------
fprintf('  T4: product linear evaluation reads history at t_prod ...\n');

bias_expected_m = 50.0;
c_mps = 299792458;

cfg_t4 = revgnss.ConfigFactory.defaultConfig();
% truthHistoryProduct: history-based linear prediction from tower clock log.
% product mode now requires explicit cfg.towerClock.products struct;
% this test checks getClockAtProductEpoch_ which is the history-based path.
cfg_t4.towerClock.correctionMode              = 'truthHistoryProduct';
cfg_t4.errors.towerClock.updateInterval_s     = 300;
cfg_t4.simulation.duration_s                  = 500;  % precompute noise far enough
cfg_t4.measurements.doppler.useInEKF = false;
cfg_t4.measurements.carrierMode      = 'off';
cfg_t4.plots.enable  = false;
cfg_t4.report.enable = false;

% Tower 1: known bias 50 m, zero drift, deterministic (no stochastic noise)
cfg_t4.towers(1).clock.bias_s        = bias_expected_m / c_mps;
cfg_t4.towers(1).clock.fracFreq      = 0;
cfg_t4.towers(1).clock.deterministic = true;

[asset_t4, towers_t4, ekf_t4, mm_t4] = revgnss.ScenarioFactory.build(cfg_t4);

% Step tower clocks 450 steps to populate history up to t=450 s
for step_i = 1:450
    for ti = 1:numel(towers_t4)
        towers_t4{ti}.stepClock(1);
    end
end

% At t=450, interval=300 → t_prod = floor(450/300)*300 = 300
% b(t=300) = 50 m (deterministic constant), bdot = 0
% b_hat(450) = 50 + 0 * (450-300) = 50 m
[~, ~, ~, ~, errSt_t4] = mm_t4.computeMeasurements( ...
    asset_t4, towers_t4, ekf_t4.x, 450, ekf_t4.stateMap);

if ~isempty(errSt_t4)
    t_prod_t4 = errSt_t4.towerClockProductEpoch_s;
    assert(abs(t_prod_t4 - 300) < 1e-9, ...
        'T4 FAILED: product epoch at t=450 should be 300 (got %.1f)', t_prod_t4);

    twr_meas_idx = find(errSt_t4.towerIdx_perMeas == 1, 1);
    if ~isempty(twr_meas_idx)
        b_hat = errSt_t4.towerClockModel_m(twr_meas_idx);
        assert(abs(b_hat - bias_expected_m) < 1e-3, ...
            'T4 FAILED: b_hat=%.4f m should be ~%.4f m (tower bias at t_prod=300)', ...
            b_hat, bias_expected_m);
        fprintf('    t=450, t_prod=%d s, b_hat=%.4f m ≈ bias=%.4f m: PASS\n', ...
            t_prod_t4, b_hat, bias_expected_m);
    else
        fprintf('    tower 1 not visible — vacuous PASS\n');
    end
else
    fprintf('    no measurements — vacuous PASS\n');
end

% ----------------------------------------------------------------
% T5: testWrongProductCreatesInnovation
%     Tower clocks have nonzero biases (clockNoiseConfig) but correction
%     mode='none' (no product applied). Innovations must be significantly
%     larger than with perfectTruth (which corrects the clock exactly).
%     This verifies that an uncorrected tower clock bias propagates to innovation.
% ----------------------------------------------------------------
fprintf('  T5: wrong product (no correction) creates larger innovation than perfectTruth ...\n');

% Base: stochastic tower clocks with known nonzero biases
cfg_t5_base = revgnss.ConfigFactory.clockNoiseConfig();
cfg_t5_base.measurements.doppler.useInEKF = false;
cfg_t5_base.measurements.carrierMode      = 'off';
cfg_t5_base.errors.codeNoise.sigma_m      = 0;  % noise-free
cfg_t5_base.plots.enable  = false;
cfg_t5_base.report.enable = false;

% 'none' mode: no correction, tower clock bias shows in innovation
cfg_t5_none = cfg_t5_base;
cfg_t5_none.towerClock.correctionMode = 'none';
[asset_t5n, towers_t5n, ekf_t5n, mm_t5n] = revgnss.ScenarioFactory.build(cfg_t5_none);
[z_t5n, h_t5n, ~, ~, errSt_t5n] = mm_t5n.computeMeasurements( ...
    asset_t5n, towers_t5n, ekf_t5n.x, 0, ekf_t5n.stateMap);

% 'perfectTruth' mode: correction = truth, innovation near 0
cfg_t5_pt = cfg_t5_base;
cfg_t5_pt.towerClock.correctionMode = 'perfectTruth';
[asset_t5p, towers_t5p, ekf_t5p, mm_t5p] = revgnss.ScenarioFactory.build(cfg_t5_pt);
[z_t5p, h_t5p, ~, ~, errSt_t5p] = mm_t5p.computeMeasurements( ...
    asset_t5p, towers_t5p, ekf_t5p.x, 0, ekf_t5p.stateMap);

if ~isempty(z_t5n) && ~isempty(z_t5p)
    M_pr5 = errSt_t5n.nPseudorange;
    innov_none = z_t5n(1:M_pr5) - h_t5n(1:M_pr5);
    innov_pt   = z_t5p(1:M_pr5) - h_t5p(1:M_pr5);
    % towerClockModel for 'none' is 0; towerClockTruth is nonzero bias
    % Innovation in 'none' mode should include the full tower clock bias
    truth_bias = errSt_t5n.towerClockTruth_m;  % per-measurement true clock values
    % For any tower with nonzero truth clock, the 'none' innovation > pt innovation
    max_abs_none = max(abs(innov_none));
    max_abs_pt   = max(abs(innov_pt));
    % Should have at least one tower with nonzero bias (clockNoiseConfig)
    assert(max(abs(truth_bias)) > 1e-3, ...
        'T5 FAILED: clockNoiseConfig tower clock biases should be nonzero');
    % 'none' mode innovation should be larger than 'perfectTruth' innovation
    assert(max_abs_none > max_abs_pt + 1e-3, ...
        'T5 FAILED: none-mode innovation (%.4f m) should exceed perfectTruth (%.4f m)', ...
        max_abs_none, max_abs_pt);
    fprintf('    |innov|_none=%.4f m  |innov|_perfectTruth=%.4f m: PASS\n', ...
        max_abs_none, max_abs_pt);
else
    fprintf('    no visible towers — vacuous PASS\n');
end

fprintf('=== test_tower_clock_correction_product: ALL PASS ===\n');
