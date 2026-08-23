% test_stage7a_tower_clock
% Task 4: Tower-clock product mode semantics.
%
% Verifies:
%   T1: product without products struct throws MeasurementModel:productStructMissing
%   T2: productNoisy without products struct throws
%   T3: truthHistoryProduct works without products struct
%   T4: product with explicit struct does NOT throw
%   T5: product correct struct creates near-zero innovation (matched truth)
%   T6: product wrong struct creates deterministic innovation

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_stage7a_tower_clock ===\n');

% ----------------------------------------------------------------
% T1: product without products struct throws
% ----------------------------------------------------------------
fprintf('  T1: product without struct throws ...\n');

cfg1 = revgnss.ConfigFactory.defaultConfig();
cfg1.towerClock.correctionMode = 'product';
% Intentionally do NOT set cfg1.towerClock.products
cfg1 = revgnss.ConfigFactory.finalizeConfig(cfg1);
cfg1.plots.enable  = false;
cfg1.report.enable = false;

[asset1, towers1, ekf1, mm1] = revgnss.ScenarioFactory.build(cfg1);
threw1 = false;
try
    mm1.computeMeasurements(asset1, towers1, ekf1.x, 0, ekf1.stateMap);
catch ME
    threw1 = true;
    assert(contains(ME.identifier, 'productStructMissing') || ...
           contains(ME.identifier, 'MeasurementModel'), ...
        'T1 FAILED: wrong error id: %s', ME.identifier);
    fprintf('    caught expected error: %s\n', ME.identifier);
end
assert(threw1, 'T1 FAILED: product without struct should throw');
fprintf('    product without struct throws: PASS\n');

% ----------------------------------------------------------------
% T2: productNoisy without struct throws
% ----------------------------------------------------------------
fprintf('  T2: productNoisy without struct throws ...\n');

cfg2 = revgnss.ConfigFactory.defaultConfig();
cfg2.towerClock.correctionMode = 'productNoisy';
cfg2 = revgnss.ConfigFactory.finalizeConfig(cfg2);
cfg2.plots.enable  = false;
cfg2.report.enable = false;

[asset2, towers2, ekf2, mm2] = revgnss.ScenarioFactory.build(cfg2);
threw2 = false;
try
    mm2.computeMeasurements(asset2, towers2, ekf2.x, 0, ekf2.stateMap);
catch ME
    threw2 = true;
    assert(contains(ME.identifier,'productStructMissing') || ...
           contains(ME.identifier,'MeasurementModel'), ...
        'T2 FAILED: wrong error id: %s', ME.identifier);
    fprintf('    caught: %s\n', ME.identifier);
end
assert(threw2, 'T2 FAILED: productNoisy without struct should throw');
fprintf('    productNoisy without struct throws: PASS\n');

% ----------------------------------------------------------------
% T3: truthHistoryProduct works without products struct
% ----------------------------------------------------------------
fprintf('  T3: truthHistoryProduct works without struct ...\n');

cfg3 = revgnss.ConfigFactory.defaultConfig();
cfg3.towerClock.correctionMode = 'truthHistoryProduct';
cfg3 = revgnss.ConfigFactory.finalizeConfig(cfg3);
cfg3.plots.enable  = false;
cfg3.report.enable = false;

[asset3, towers3, ekf3, mm3] = revgnss.ScenarioFactory.build(cfg3);
threwT3 = false;
try
    [z3, h3, ~, ~, ~] = mm3.computeMeasurements(asset3, towers3, ekf3.x, 0, ekf3.stateMap);
    threwT3 = false;
catch ME
    threwT3 = true;
    fprintf('  T3 unexpected error: %s\n', ME.message);
end
assert(~threwT3, 'T3 FAILED: truthHistoryProduct should not throw without products struct');
assert(~isempty(z3), 'T3 FAILED: no measurements returned');
fprintf('    truthHistoryProduct works, %d measurements: PASS\n', numel(z3));

% ----------------------------------------------------------------
% T4: product with explicit struct does NOT throw
% ----------------------------------------------------------------
fprintf('  T4: product with complete explicit struct ...\n');

cfg4 = revgnss.ConfigFactory.towerClockProductConfig();
cfg4 = revgnss.ConfigFactory.finalizeConfig(cfg4);
cfg4.plots.enable  = false;
cfg4.report.enable = false;

[asset4, towers4, ekf4, mm4] = revgnss.ScenarioFactory.build(cfg4);
threwT4 = false;
try
    [z4, h4, ~, ~, ~] = mm4.computeMeasurements(asset4, towers4, ekf4.x, 0, ekf4.stateMap);
catch ME
    threwT4 = true;
    fprintf('  T4 unexpected error: %s\n', ME.message);
end
assert(~threwT4, 'T4 FAILED: product with complete struct should not throw');
assert(~isempty(z4), 'T4 FAILED: no measurements returned');
fprintf('    product with complete struct: %d measurements, no error: PASS\n', numel(z4));

% ----------------------------------------------------------------
% T5: product wrong bias creates deterministic innovation
% ----------------------------------------------------------------
fprintf('  T5: wrong product bias creates innovation ...\n');

cfg5 = revgnss.ConfigFactory.towerClockProductConfig();
cfg5.scenario.nTowers = 1;
cfg5 = revgnss.ConfigFactory.finalizeConfig(cfg5);
cfg5.plots.enable  = false;
cfg5.report.enable = false;

% Set wrong bias on tower 1 product
biasErr_m = 50.0;
cfg5.towerClock.products(1).bias_m = biasErr_m;

[asset5, towers5, ekf5, mm5] = revgnss.ScenarioFactory.build(cfg5);
[z5, h5, ~, ~, ~] = mm5.computeMeasurements(asset5, towers5, ekf5.x, 0, ekf5.stateMap);

innov5 = z5 - h5;
% The wrong product bias should create innovation |innov| ≈ biasErr_m
% (with sign depending on convention: product enters h as -b_twr)
maxInnov5 = max(abs(innov5));
assert(maxInnov5 > biasErr_m * 0.5, ...
    'T5 FAILED: wrong product bias %g m should create innovation > %g m, got %.2f', ...
    biasErr_m, biasErr_m*0.5, maxInnov5);
fprintf('    wrong bias %g m created innovation %.2f m: PASS\n', biasErr_m, maxInnov5);

fprintf('=== test_stage7a_tower_clock: ALL PASS ===\n');
