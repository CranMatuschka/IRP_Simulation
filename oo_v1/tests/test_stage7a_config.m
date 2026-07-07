% test_stage7a_config
% Task 7: Config and documentation cleanup.
%
% Verifies:
%   T1: defaultConfig produces errors.troposphere.truth.enable = true (matched, not off)
%   T2: cleanConfig produces errors.troposphere.truth.enable = false
%   T3: matchedErrorBaselineConfig equals defaultConfig behavior
%   T4: observableMode field exists and is a string
%   T5: defaultConfig has ionosphere.mappingModel = 'simpleSecant' (backward compat)
%   T6: towerClock.correctionMode = 'product' + no struct → throws after finalize

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_stage7a_config ===\n');

% ----------------------------------------------------------------
% T1: defaultConfig is an honest off=off baseline (clarity refactor C-5)
% ----------------------------------------------------------------
fprintf('  T1: defaultConfig is honest off=off baseline ...\n');

cfg1 = revgnss.ConfigFactory.defaultConfig();
assert(isfield(cfg1.errors.troposphere.truth,'enable') && ...
       cfg1.errors.troposphere.truth.enable == false, ...
    'T1 FAILED: defaultConfig should have troposphere.truth.enable=false (honest off=off default)');
assert(cfg1.errors.troposphere.model.enable == false, ...
    'T1 FAILED: defaultConfig should have troposphere.model.enable=false (honest off=off default)');
fprintf('    troposphere truth=false, model=false (honest off=off): PASS\n');

% ----------------------------------------------------------------
% T2: cleanConfig has all errors off
% ----------------------------------------------------------------
fprintf('  T2: cleanConfig — all errors off ...\n');

cfg2 = revgnss.ConfigFactory.cleanConfig();
assert(~cfg2.errors.troposphere.truth.enable, 'T2 FAILED: cleanConfig trop truth should be off');
assert(~cfg2.errors.troposphere.model.enable, 'T2 FAILED: cleanConfig trop model should be off');
assert(~cfg2.errors.ionosphere.truth.enable,  'T2 FAILED: cleanConfig iono truth should be off');
assert(~cfg2.errors.ionosphere.model.enable,  'T2 FAILED: cleanConfig iono model should be off');
assert(~cfg2.effects.antennaPCV.truth.enable,  'T2 FAILED: cleanConfig PCV truth should be off');
assert(~cfg2.effects.antennaPCO.truth.enable,  'T2 FAILED: cleanConfig PCO truth should be off');
fprintf('    cleanConfig: all major errors off: PASS\n');

% ----------------------------------------------------------------
% T3: matchedErrorBaselineConfig is the explicit matched-error baseline (tropo/iono ON)
% ----------------------------------------------------------------
fprintf('  T3: matchedErrorBaselineConfig has tropo/iono matched ON ...\n');

cfg3 = revgnss.ConfigFactory.matchedErrorBaselineConfig();
assert(cfg3.errors.troposphere.truth.enable == true && ...
       cfg3.errors.troposphere.model.enable == true, ...
    'T3 FAILED: matchedErrorBaselineConfig should have troposphere truth=model=true');
assert(cfg3.errors.ionosphere.truth.enable == true && ...
       cfg3.errors.ionosphere.model.enable == true, ...
    'T3 FAILED: matchedErrorBaselineConfig should have ionosphere truth=model=true');
fprintf('    matchedErrorBaselineConfig: tropo/iono matched ON: PASS\n');

% ----------------------------------------------------------------
% T4: observableMode is a string field in defaultConfig
% ----------------------------------------------------------------
fprintf('  T4: observableMode field exists as string ...\n');

assert(isfield(cfg1,'measurements') && isfield(cfg1.measurements,'observableMode'), ...
    'T4 FAILED: observableMode field missing from defaultConfig');
assert(ischar(cfg1.measurements.observableMode) || isstring(cfg1.measurements.observableMode), ...
    'T4 FAILED: observableMode should be a string, got %s', class(cfg1.measurements.observableMode));
fprintf('    observableMode = ''%s'': PASS\n', cfg1.measurements.observableMode);

% ----------------------------------------------------------------
% T5: defaultConfig ionosphere.mappingModel = 'simpleSecant'
% ----------------------------------------------------------------
fprintf('  T5: defaultConfig ionosphere.mappingModel = simpleSecant ...\n');

assert(isfield(cfg1,'effects') && isfield(cfg1.effects,'ionosphere') && ...
       isfield(cfg1.effects.ionosphere,'mappingModel'), ...
    'T5 FAILED: cfg.effects.ionosphere.mappingModel missing from defaultConfig');
assert(strcmp(cfg1.effects.ionosphere.mappingModel,'simpleSecant'), ...
    'T5 FAILED: defaultConfig ionosphere.mappingModel should be ''simpleSecant'' (backward compat), got ''%s''', ...
    cfg1.effects.ionosphere.mappingModel);
fprintf('    ionosphere.mappingModel = ''simpleSecant'': PASS\n');

% ----------------------------------------------------------------
% T6: correctionMode='product' without struct throws after finalize
% ----------------------------------------------------------------
fprintf('  T6: correctionMode=product without struct throws after build ...\n');

cfg6 = revgnss.ConfigFactory.defaultConfig();
cfg6.towerClock.correctionMode = 'product';
% Do NOT set cfg6.towerClock.products
cfg6 = revgnss.ConfigFactory.finalizeConfig(cfg6);
cfg6.plots.enable  = false;
cfg6.report.enable = false;

[asset6, towers6, ekf6, mm6] = revgnss.ScenarioFactory.build(cfg6);
threw6 = false;
try
    mm6.computeMeasurements(asset6, towers6, ekf6.x, 0, ekf6.stateMap);
catch ME
    threw6 = true;
end
assert(threw6, 'T6 FAILED: product mode without struct should throw at measurement time');
fprintf('    product without struct throws at build/measurement time: PASS\n');

fprintf('=== test_stage7a_config: ALL PASS ===\n');
