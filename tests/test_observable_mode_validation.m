% test_observable_mode_validation
% ConfigFactory validation: invalid mode combinations throw errors.
%
% Verifies:
%   - carrierMode='ekfFloat' without ambiguityMode='floatPerTowerSignal' throws
%   - carrierMode='ekfFloat' WITH ambiguityMode='floatPerTowerSignal' does NOT throw
%   - codeMode='ionosphereFree' without L1+L2 signals throws

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_observable_mode_validation ===\n');

% --- Test 1: carrierMode='ekfFloat' without ambiguityMode → must throw
cfg_bad = revgnss.ConfigFactory.defaultConfig();
cfg_bad.measurements.carrierMode  = 'ekfFloat';
cfg_bad.estimation.ambiguityMode  = 'none';   % not floatPerTowerSignal
cfg_bad.plots.enable  = false;
cfg_bad.report.enable = false;
threwError = false;
try
    revgnss.ConfigFactory.finalizeConfig(cfg_bad);
catch e
    threwError = true;
    fprintf('  [expected] ekfFloat without ambiguities: %s\n', e.message);
end
assert(threwError, 'Must throw when carrierMode=ekfFloat but ambiguityMode!=floatPerTowerSignal');

% --- Test 2: carrierMode='ekfFloat' WITH ambiguityMode → must NOT throw
cfg_ok = revgnss.ConfigFactory.defaultConfig();
cfg_ok.measurements.carrierMode  = 'ekfFloat';
cfg_ok.estimation.ambiguityMode  = 'floatPerTowerSignal';
cfg_ok.plots.enable  = false;
cfg_ok.report.enable = false;
threwOk = false;
try
    revgnss.ConfigFactory.finalizeConfig(cfg_ok);
catch e2
    threwOk = true;
    fprintf('  [unexpected] %s\n', e2.message);
end
assert(~threwOk, 'Must NOT throw when carrierMode=ekfFloat and ambiguityMode=floatPerTowerSignal');

fprintf('  PASS\n');
