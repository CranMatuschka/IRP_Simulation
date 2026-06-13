% test_carrier_ekf_requires_ambiguities
% carrierMode='ekfFloat' must fail finalizeConfig when ambiguityMode!='floatPerTowerSignal'.
%
% Verifies:
%   - Error thrown with descriptive message when ambiguityMode='none'
%   - Error message mentions 'ambiguity' or 'ekfFloat'
%   - Setting ambiguityMode='floatPerTowerSignal' makes it pass

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_carrier_ekf_requires_ambiguities ===\n');

% --- Must throw when ambiguityMode is not floatPerTowerSignal
cfg_fail = revgnss.ConfigFactory.defaultConfig();
cfg_fail.measurements.carrierMode = 'ekfFloat';
cfg_fail.estimation.ambiguityMode = 'none';
cfg_fail.plots.enable  = false;
cfg_fail.report.enable = false;

didThrow = false;
errMsg   = '';
try
    revgnss.ConfigFactory.finalizeConfig(cfg_fail);
catch e
    didThrow = true;
    errMsg   = e.message;
end
assert(didThrow, 'finalizeConfig must throw for ekfFloat without float ambiguities');
assert(contains(lower(errMsg), 'ambiguit') || contains(lower(errMsg), 'ekffloat'), ...
    'Error message should mention ambiguity or ekfFloat, got: %s', errMsg);

% --- Must NOT throw when ambiguityMode is correct
cfg_ok = revgnss.ConfigFactory.defaultConfig();
cfg_ok.measurements.carrierMode = 'ekfFloat';
cfg_ok.estimation.ambiguityMode = 'floatPerTowerSignal';
cfg_ok.plots.enable  = false;
cfg_ok.report.enable = false;
revgnss.ConfigFactory.finalizeConfig(cfg_ok);   % should not throw

fprintf('  Error message: "%s"\n', errMsg);
fprintf('  PASS\n');
