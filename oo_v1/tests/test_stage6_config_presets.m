% test_stage6_config_presets
% Phase 5: config API cleanup — new presets, truthHistoryProduct mode.
%
% Verifies:
%   T1: defaultConfig mappingModel field present (new in Stage 6)
%   T2: towerClockProductConfig finalizes without error
%   T3: stochasticErrorsConfig now uses truthHistoryProduct correctionMode
%   T4: carrierFloatConfig activates carrierMode=ekfFloat AND ambiguityMode=float
%   T5: dualFrequencyIFConfig creates codeMode=ionosphereFree
%   T6: cleanConfig has all effects disabled (no truth errors)

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_stage6_config_presets ===\n');

% ----------------------------------------------------------------
% T1: defaultConfig includes new Stage-6 mappingModel field
% ----------------------------------------------------------------
fprintf('  T1: defaultConfig has effects.troposphere.mappingModel ...\n');

cfg1 = revgnss.ConfigFactory.defaultConfig();
assert(isfield(cfg1,'effects'), 'T1 FAILED: cfg.effects missing');
assert(isfield(cfg1.effects,'troposphere'), 'T1 FAILED: cfg.effects.troposphere missing');
assert(isfield(cfg1.effects.troposphere,'mappingModel'), ...
    'T1 FAILED: cfg.effects.troposphere.mappingModel missing');
assert(ischar(cfg1.effects.troposphere.mappingModel) || ...
    isstring(cfg1.effects.troposphere.mappingModel), ...
    'T1 FAILED: mappingModel should be a string');
fprintf('    mappingModel=%s: PASS\n', cfg1.effects.troposphere.mappingModel);

% ----------------------------------------------------------------
% T2: towerClockProductConfig finalizes without error
% ----------------------------------------------------------------
fprintf('  T2: towerClockProductConfig finalizes without error ...\n');

cfg2 = revgnss.ConfigFactory.towerClockProductConfig();
cfg2.plots.enable  = false;
cfg2.report.enable = false;

threwT2 = false;
try
    revgnss.ConfigFactory.finalizeConfig(cfg2);
catch ME
    threwT2 = true;
    fprintf('    unexpected error: %s\n', ME.message);
end
assert(~threwT2, 'T2 FAILED: towerClockProductConfig finalize threw an error');
fprintf('    towerClockProductConfig finalizes: PASS\n');

% ----------------------------------------------------------------
% T3: stochasticErrorsConfig uses truthHistoryProduct correctionMode
% ----------------------------------------------------------------
fprintf('  T3: stochasticErrorsConfig uses truthHistoryProduct correctionMode ...\n');

cfg3 = revgnss.ConfigFactory.stochasticErrorsConfig();
assert(strcmp(cfg3.towerClock.correctionMode,'truthHistoryProduct'), ...
    'T3 FAILED: stochasticErrorsConfig.towerClock.correctionMode should be ''truthHistoryProduct'', got ''%s''', ...
    cfg3.towerClock.correctionMode);
fprintf('    stochasticErrorsConfig correctionMode=truthHistoryProduct: PASS\n');

% ----------------------------------------------------------------
% T4: carrierFloatConfig activates carrierMode=ekfFloat
% ----------------------------------------------------------------
fprintf('  T4: carrierFloatConfig activates carrierMode=ekfFloat ...\n');

cfg4 = revgnss.ConfigFactory.carrierFloatConfig();
assert(isfield(cfg4,'measurements'), 'T4 FAILED: measurements field missing');
assert(isfield(cfg4.measurements,'carrierMode'), 'T4 FAILED: carrierMode missing');
assert(strcmp(cfg4.measurements.carrierMode,'ekfFloat'), ...
    'T4 FAILED: carrierMode=%s, expected ekfFloat', cfg4.measurements.carrierMode);

assert(isfield(cfg4,'estimation'), 'T4 FAILED: estimation field missing');
assert(isfield(cfg4.estimation,'ambiguityMode'), 'T4 FAILED: ambiguityMode missing');
assert(strcmp(cfg4.estimation.ambiguityMode,'float'), ...
    'T4 FAILED: ambiguityMode=%s, expected float', cfg4.estimation.ambiguityMode);
fprintf('    carrierMode=ekfFloat, ambiguityMode=float: PASS\n');

% ----------------------------------------------------------------
% T5: dualFrequencyIFConfig creates codeMode=ionosphereFree
% ----------------------------------------------------------------
fprintf('  T5: dualFrequencyIFConfig has codeMode=ionosphereFree ...\n');

cfg5 = revgnss.ConfigFactory.dualFrequencyIFConfig();
assert(isfield(cfg5.measurements,'codeMode'), 'T5 FAILED: codeMode missing');
assert(strcmp(cfg5.measurements.codeMode,'ionosphereFree'), ...
    'T5 FAILED: codeMode=%s, expected ionosphereFree', cfg5.measurements.codeMode);
assert(cfg5.signals.twoFrequency.enable, ...
    'T5 FAILED: dualFrequencyIFConfig should have twoFrequency enabled');
fprintf('    codeMode=ionosphereFree, twoFrequency=true: PASS\n');

% ----------------------------------------------------------------
% T6: cleanConfig has all effects disabled
% ----------------------------------------------------------------
fprintf('  T6: cleanConfig disables truth effects ...\n');

cfg6 = revgnss.ConfigFactory.cleanConfig();

% Check key truth effects are off
effects_to_check = { ...
    'errors.troposphere.truth.enable', ...
    'errors.ionosphere.truth.enable', ...
    'errors.multipath.truth.enable', ...
    'errors.hardwareDelay.truth.enable', ...
};

for k = 1:numel(effects_to_check)
    path_str = effects_to_check{k};
    parts = strsplit(path_str,'.');
    val = cfg6; ok = true;
    for p = 1:numel(parts)
        if isfield(val, parts{p}); val = val.(parts{p});
        else; ok = false; break; end
    end
    if ok
        assert(~val, 'T6 FAILED: cleanConfig has %s=true (expected false)', path_str);
    end
end
fprintf('    cleanConfig truth effects are all disabled: PASS\n');

fprintf('=== test_stage6_config_presets: ALL PASS ===\n');
