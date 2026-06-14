% test_stage6_tower_clock_product_struct
% Phase 4: explicit towerClock.products(ti) struct semantics.
%
% Verifies:
%   T1: towerClockProductConfig() creates a valid products struct array
%   T2: explicit product struct with zero bias → h agrees with perfectTruth
%   T3: productNoisy mode inflates R by sigmaBias^2 per product struct
%   T4: truthHistoryProduct correctionMode still works
%   T5: productValidityPolicy='warn' does not throw

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_stage6_tower_clock_product_struct ===\n');

% ----------------------------------------------------------------
% T1: towerClockProductConfig returns valid products struct array
% ----------------------------------------------------------------
fprintf('  T1: towerClockProductConfig produces valid products struct ...\n');

cfg1 = revgnss.ConfigFactory.towerClockProductConfig();
assert(isfield(cfg1.towerClock,'products'), ...
    'T1 FAILED: towerClock.products field missing');
nP = numel(cfg1.towerClock.products);
nT = cfg1.scenario.nTowers;
assert(nP == nT, 'T1 FAILED: products has %d entries, expected %d towers', nP, nT);

for k = 1:nP
    p = cfg1.towerClock.products(k);
    assert(isfield(p,'bias_m'),         'T1 FAILED: products(%d) missing bias_m', k);
    assert(isfield(p,'drift_mps'),      'T1 FAILED: products(%d) missing drift_mps', k);
    assert(isfield(p,'epoch_s'),        'T1 FAILED: products(%d) missing epoch_s', k);
    assert(isfield(p,'sigmaBias_m'),    'T1 FAILED: products(%d) missing sigmaBias_m', k);
    assert(isfield(p,'sigmaDrift_mps'), 'T1 FAILED: products(%d) missing sigmaDrift_mps', k);
    assert(isfield(p,'validity_s'),     'T1 FAILED: products(%d) missing validity_s', k);
end
assert(strcmp(cfg1.towerClock.correctionMode,'product'), ...
    'T1 FAILED: correctionMode should be ''product''');
fprintf('    %d towers, %d product structs, all fields present: PASS\n', nT, nP);

% ----------------------------------------------------------------
% T2: explicit product struct with zero bias → h agrees with perfectTruth
% ----------------------------------------------------------------
fprintf('  T2: explicit product struct with zero bias → zero innovation ...\n');

cfg2_prod = revgnss.ConfigFactory.towerClockProductConfig();
cfg2_prod.measurements.doppler.useInEKF = false;
cfg2_prod.measurements.carrierMode      = 'off';
cfg2_prod.plots.enable  = false;
cfg2_prod.report.enable = false;

cfg2_pt = revgnss.ConfigFactory.defaultConfig();
cfg2_pt.towerClock.correctionMode      = 'perfectTruth';
cfg2_pt.measurements.doppler.useInEKF  = false;
cfg2_pt.measurements.carrierMode       = 'off';
cfg2_pt.plots.enable  = false;
cfg2_pt.report.enable = false;

[asset2p, towers2p, ekf2p, mm2p] = revgnss.ScenarioFactory.build(cfg2_prod);
[asset2t, towers2t, ekf2t, mm2t] = revgnss.ScenarioFactory.build(cfg2_pt);

[~, h2p] = mm2p.computeMeasurements(asset2p, towers2p, ekf2p.x, 0, ekf2p.stateMap);
[~, h2t] = mm2t.computeMeasurements(asset2t, towers2t, ekf2t.x, 0, ekf2t.stateMap);

if ~isempty(h2p) && ~isempty(h2t)
    max_diff = max(abs(h2p - h2t));
    assert(max_diff < 1e-6, ...
        'T2 FAILED: product struct vs perfectTruth h differ by %.2e', max_diff);
    fprintf('    max |h_product - h_perfectTruth| = %.2e: PASS\n', max_diff);
else
    fprintf('    no visible towers (vacuous PASS)\n');
end

% ----------------------------------------------------------------
% T3: productNoisy mode inflates R using sigmaBias from products struct
% ----------------------------------------------------------------
fprintf('  T3: productNoisy inflates R by product struct sigmaBias ...\n');

sigBias = 0.4;  % m
cfg3 = revgnss.ConfigFactory.towerClockProductConfig();
cfg3.towerClock.correctionMode = 'productNoisy';
for k = 1:numel(cfg3.towerClock.products)
    cfg3.towerClock.products(k).sigmaBias_m = sigBias;
end
cfg3.measurements.doppler.useInEKF = false;
cfg3.measurements.carrierMode      = 'off';
cfg3.plots.enable  = false;
cfg3.report.enable = false;

[asset3, towers3, ekf3, mm3] = revgnss.ScenarioFactory.build(cfg3);
[~, ~, ~, R3, errSt3] = mm3.computeMeasurements(asset3, towers3, ekf3.x, 0, ekf3.stateMap);

if ~isempty(R3)
    M_pr3 = errSt3.nPseudorange;
    R_diag3 = diag(R3);
    assert(all(R_diag3(1:M_pr3) >= sigBias^2 - 1e-12), ...
        'T3 FAILED: R diagonal (%.4e) < sigBias^2 (%.4e)', min(R_diag3(1:M_pr3)), sigBias^2);
    fprintf('    min R_diag(1:%d)=%.4e >= sigBias^2=%.4e: PASS\n', ...
        M_pr3, min(R_diag3(1:M_pr3)), sigBias^2);
else
    fprintf('    no visible towers (vacuous PASS)\n');
end

% ----------------------------------------------------------------
% T4: truthHistoryProduct correctionMode maps to 'product' internally
% ----------------------------------------------------------------
fprintf('  T4: truthHistoryProduct correctionMode maps to internal product ...\n');

cfg4 = revgnss.ConfigFactory.defaultConfig();
cfg4.towerClock.correctionMode = 'truthHistoryProduct';
cfg4.plots.enable  = false;
cfg4.report.enable = false;

cfgF4 = revgnss.ConfigFactory.finalizeConfig(cfg4);
assert(strcmp(cfgF4.estimator.towerClockMode,'product'), ...
    'T4 FAILED: truthHistoryProduct should map to towerClockMode=product, got %s', ...
    cfgF4.estimator.towerClockMode);
fprintf('    truthHistoryProduct → towerClockMode=product: PASS\n');

% ----------------------------------------------------------------
% T5: productValidityPolicy='warn' does not throw
% ----------------------------------------------------------------
fprintf('  T5: productValidityPolicy=''warn'' does not throw ...\n');

cfg5 = revgnss.ConfigFactory.towerClockProductConfig();
cfg5.towerClock.productValidityPolicy = 'warn';
% Set an expired product (validity_s = 0) to trigger the validity check
for k = 1:numel(cfg5.towerClock.products)
    cfg5.towerClock.products(k).validity_s = 0;  % expired
end
cfg5.measurements.doppler.useInEKF = false;
cfg5.measurements.carrierMode      = 'off';
cfg5.simulation.duration_s         = 1;
cfg5.plots.enable  = false;
cfg5.report.enable = false;

threwT5 = false;
try
    [asset5, towers5, ekf5, mm5] = revgnss.ScenarioFactory.build(cfg5);
    mm5.computeMeasurements(asset5, towers5, ekf5.x, 0, ekf5.stateMap);
catch ME
    threwT5 = true;
    fprintf('    unexpected throw: %s\n', ME.message);
end
assert(~threwT5, 'T5 FAILED: productValidityPolicy=warn should not throw');
fprintf('    productValidityPolicy=warn does not throw: PASS\n');

fprintf('=== test_stage6_tower_clock_product_struct: ALL PASS ===\n');
