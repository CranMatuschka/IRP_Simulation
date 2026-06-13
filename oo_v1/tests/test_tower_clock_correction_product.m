% test_tower_clock_correction_product
% ConfigFactory.finalizeConfig maps new towerClock.correctionMode names.
%
% Verifies:
%   - 'perfectTruth' → estimator.towerClockMode = 'perfectCorrection'
%   - 'product'      → estimator.towerClockMode = 'perfectCorrection'
%   - 'productNoisy' → estimator.towerClockMode = 'noisyCorrection'
%   - 'none'         → estimator.towerClockMode = 'none'

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_tower_clock_correction_product ===\n');

cases = { ...
    'perfectTruth', 'perfectCorrection'; ...
    'product',      'perfectCorrection'; ...
    'productNoisy', 'noisyCorrection'; ...
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
        'correctionMode=%s: expected towerClockMode=%s, got %s', ...
        corrMode, expectMode, actual);
    fprintf('  correctionMode=%-14s → towerClockMode=%s\n', corrMode, actual);
end

fprintf('  PASS\n');
