% test_config_defaults_and_presets
% ConfigFactory named presets return valid, finalizeable configs.
%
% Verifies:
%   - defaultConfig() has all required new v4 fields
%   - cleanConfig() finalizes without error
%   - matchedErrorBaselineConfig() finalizes without error
%   - dualFrequencyIFConfig() finalizes without error
%   - carrierFloatConfig() finalizes without error
%   - stochasticErrorsConfig() finalizes without error

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_config_defaults_and_presets ===\n');

% --- defaultConfig new fields
cfg = revgnss.ConfigFactory.defaultConfig();

assert(isfield(cfg.measurements,'carrierMode'),      'Missing measurements.carrierMode');
assert(isfield(cfg.measurements,'codeMode'),         'Missing measurements.codeMode');
assert(isfield(cfg.estimation,'ambiguityMode'),      'Missing estimation.ambiguityMode');
assert(isfield(cfg.estimation,'troposphereMode'),    'Missing estimation.troposphereMode');
assert(isfield(cfg.effects,'lightTime'),             'Missing effects.lightTime');
assert(isfield(cfg.effects.lightTime,'model'),       'Missing effects.lightTime.model');
assert(isfield(cfg.effects,'antenna'),               'Missing effects.antenna');
assert(isfield(cfg.effects.antenna,'pcvModel'),      'Missing effects.antenna.pcvModel');
assert(isfield(cfg.towerClock,'correctionMode'),     'Missing towerClock.correctionMode');
assert(isfield(cfg.diagnostics,'observability'),     'Missing diagnostics.observability');

fprintf('  defaultConfig: all new fields present\n');

% --- Named presets: must finalize without error
presets = {'cleanConfig','matchedErrorBaselineConfig', ...
           'dualFrequencyIFConfig','carrierFloatConfig','stochasticErrorsConfig'};

for k = 1:numel(presets)
    preset = presets{k};
    try
        cfgP = revgnss.ConfigFactory.(preset)();
        cfgP.plots.enable  = false;
        cfgP.report.enable = false;
        revgnss.ConfigFactory.finalizeConfig(cfgP);
        fprintf('  %s: OK\n', preset);
    catch e
        error('Preset %s threw: %s', preset, e.message);
    end
end

fprintf('  PASS\n');
