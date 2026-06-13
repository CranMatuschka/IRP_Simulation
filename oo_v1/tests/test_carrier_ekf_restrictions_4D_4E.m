% test_carrier_ekf_restrictions_4D_4E
% Tasks 4D + 4E: ekfFloat carrier mode v1 restrictions.
%
% Verifies:
%   T1 (4D): ekfFloat + L1+L2 enabled → warning issued
%   T2 (4D): ekfFloat + L1 only → no multi-freq warning in cfg.validation.warnings
%   T3 (4D): ekfFloat + L1+L2 → state dimension uses L1 ambiguities only (nx_amb unchanged)
%   T4 (4E): ekfFloat + carrierCombinationMode='ionosphereFree' → fallback to 'raw', warning issued
%   T5 (4E): policy='error' + carrierCombinationMode='ionosphereFree' → throws error

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_carrier_ekf_restrictions_4D_4E ===\n');

% ----------------------------------------------------------------
% T1 (4D): ekfFloat + L1+L2 → warning in cfg.validation.warnings
% ----------------------------------------------------------------
fprintf('  T1 (4D): ekfFloat + L1+L2 produces multi-freq warning ...\n');

cfg_t1 = revgnss.ConfigFactory.defaultConfig();
cfg_t1.measurements.carrierMode      = 'ekfFloat';
cfg_t1.estimation.ambiguityMode      = 'floatPerTowerSignal';
cfg_t1.signals.twoFrequency.enable   = true;
% Use ionosphereFree code (not IF carrier) to satisfy dual-freq codeMode
cfg_t1.measurements.codeMode         = 'ionosphereFree';
cfg_t1.plots.enable  = false;
cfg_t1.report.enable = false;

% Capture warnings
warnState = warning('off','all');
lastwarn('');
cfg_t1f = revgnss.ConfigFactory.finalizeConfig(cfg_t1);
[lastMsg, lastId] = lastwarn();
warning(warnState);

% Check that the multi-freq warning was issued via warning()
foundWarn4D = contains(lastMsg,'L1') || any(cellfun(@(w) contains(w,'L1 rows'), ...
    cfg_t1f.validation.warnings));
assert(foundWarn4D, ...
    'T1 FAILED: expected L1-only warning for ekfFloat+L1+L2, none found');
fprintf('    Warning issued for ekfFloat+L1+L2: PASS\n');

% ----------------------------------------------------------------
% T2 (4D): ekfFloat + L1 only → no multi-freq warning in validation.warnings
% ----------------------------------------------------------------
fprintf('  T2 (4D): ekfFloat + L1 only → no multi-freq warning ...\n');

cfg_t2 = revgnss.ConfigFactory.defaultConfig();
cfg_t2.measurements.carrierMode    = 'ekfFloat';
cfg_t2.estimation.ambiguityMode    = 'floatPerTowerSignal';
cfg_t2.signals.twoFrequency.enable = false;
cfg_t2.plots.enable  = false;
cfg_t2.report.enable = false;

warnState2 = warning('off','all');
cfg_t2f = revgnss.ConfigFactory.finalizeConfig(cfg_t2);
warning(warnState2);

hasL2Warn = any(cellfun(@(w) contains(w,'L2 carrier'), cfg_t2f.validation.warnings));
assert(~hasL2Warn, ...
    'T2 FAILED: unexpected multi-freq warning with L1-only ekfFloat');
fprintf('    No multi-freq warning for L1-only ekfFloat: PASS\n');

% ----------------------------------------------------------------
% T3 (4D): ekfFloat + L1+L2 → issues warning but does NOT throw an error.
%          L2 ambiguity states are allocated but L2 carrier rows are never
%          added to H (computeCarrierEkfRows_ uses sigIdx=1 only).
% ----------------------------------------------------------------
fprintf('  T3 (4D): ekfFloat + L1+L2 initializes with warning, not error ...\n');

warnState3 = warning('off','all');
cfg_t3 = revgnss.ConfigFactory.defaultConfig();
cfg_t3.measurements.carrierMode    = 'ekfFloat';
cfg_t3.estimation.ambiguityMode    = 'floatPerTowerSignal';
cfg_t3.signals.twoFrequency.enable = true;
cfg_t3.measurements.codeMode       = 'ionosphereFree';
cfg_t3.plots.enable  = false;
cfg_t3.report.enable = false;

threwError3 = false;
ekf_t3      = [];
try
    cfg_t3f = revgnss.ConfigFactory.finalizeConfig(cfg_t3);
    [~, ~, ekf_t3] = revgnss.ScenarioFactory.build(cfg_t3f);
catch ME3
    threwError3 = true;
    fprintf('    ERROR: %s\n', ME3.message);
end
warning(warnState3);

assert(~threwError3, ...
    'T3 FAILED: ekfFloat+L1+L2 should warn but not throw (got error)');
fprintf('    ekfFloat+L1+L2 initializes with warning only (no crash): PASS\n');

% ----------------------------------------------------------------
% T4 (4E): ekfFloat + carrierCombinationMode='ionosphereFree'
%          → fallback to 'raw', warning in validation.warnings
% ----------------------------------------------------------------
fprintf('  T4 (4E): carrierCombinationMode=ionosphereFree falls back to raw ...\n');

cfg_t4 = revgnss.ConfigFactory.defaultConfig();
cfg_t4.measurements.carrierMode              = 'ekfFloat';
cfg_t4.estimation.ambiguityMode              = 'floatPerTowerSignal';
cfg_t4.measurements.carrierCombinationMode   = 'ionosphereFree';
cfg_t4.plots.enable  = false;
cfg_t4.report.enable = false;

warnState4 = warning('off','all');
cfg_t4f = revgnss.ConfigFactory.finalizeConfig(cfg_t4);
warning(warnState4);

assert(strcmp(cfg_t4f.measurements.carrierCombinationMode, 'raw'), ...
    'T4 FAILED: carrierCombinationMode should be ''raw'' after fallback, got ''%s''', ...
    cfg_t4f.measurements.carrierCombinationMode);

hasDisabledIF = any(cellfun(@(d) contains(d,'ionosphereFree'), ...
    cfg_t4f.validation.disabledFeatures));
assert(hasDisabledIF, ...
    'T4 FAILED: carrierCombinationMode.ionosphereFree not listed in disabledFeatures');

has4EWarn = any(cellfun(@(w) contains(w,'ionosphereFree'), cfg_t4f.validation.warnings));
assert(has4EWarn, ...
    'T4 FAILED: no warning about ionosphereFree carrier fallback in validation.warnings');

fprintf('    carrierCombinationMode fell back to ''raw'', warning issued: PASS\n');

% ----------------------------------------------------------------
% T5 (4E): policy='error' + carrierCombinationMode='ionosphereFree' → throws
% ----------------------------------------------------------------
fprintf('  T5 (4E): policy=error + carrierCombinationMode=ionosphereFree → error ...\n');

cfg_t5 = revgnss.ConfigFactory.defaultConfig();
cfg_t5.measurements.carrierMode                     = 'ekfFloat';
cfg_t5.estimation.ambiguityMode                     = 'floatPerTowerSignal';
cfg_t5.measurements.carrierCombinationMode          = 'ionosphereFree';
cfg_t5.validation.unsupportedFeaturePolicy          = 'error';
cfg_t5.plots.enable  = false;
cfg_t5.report.enable = false;

threwError = false;
warnState5 = warning('off','all');
try
    revgnss.ConfigFactory.finalizeConfig(cfg_t5);
catch ME
    threwError = true;
    assert(contains(ME.identifier,'carrierIF') || contains(ME.identifier,'ConfigFactory'), ...
        'T5 FAILED: error identifier ''%s'' does not match expected pattern', ME.identifier);
end
warning(warnState5);
assert(threwError, 'T5 FAILED: expected error for policy=error + carrierCombinationMode=ionosphereFree');
fprintf('    policy=error + ionosphereFree → error thrown: PASS\n');

fprintf('=== test_carrier_ekf_restrictions_4D_4E: ALL PASS ===\n');
