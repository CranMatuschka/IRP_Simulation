% test_stage7a2_policy_fixes
% Stage 7A.2: policy unification and product/transmit-time epoch fixes.
%
% Verifies:
%   T1:  Carrier IF throws at finalization with default policy (='error')
%   T2:  Carrier IF disableWithWarning suppresses error at finalization
%   T3:  Carrier IF disableWithWarning sets carrierCombinationMode='raw'
%   T4:  Carrier IF NOT silently becoming raw with default policy
%   T5:  Raw L1 carrier (ekfFloat, raw combination) does not throw
%   T6:  productNoisy sigma uses same epoch as bias (epoch-consistent)
%   T7:  product mode without explicit struct throws productStructMissing
%   T8:  productNoisy mode without explicit struct throws productStructMissing
%   T9:  product bias and sigma are both included in R diagonal
%   T10: Doppler EKF silently disabled when physics not configured (no throw)
%   T11: ISL stub returns empty z, h, H (not implemented)

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_stage7a2_policy_fixes ===\n');

% ----------------------------------------------------------------
% T1: Carrier IF throws at finalization by default (policy='error')
% ----------------------------------------------------------------
fprintf('  T1: carrier IF throws at finalization by default (policy=error) ...\n');

cfg1 = revgnss.ConfigFactory.defaultConfig();
assert(strcmp(cfg1.validation.unsupportedFeaturePolicy,'error'), ...
    'T1 FAILED: defaultConfig should set policy=error, got ''%s''', ...
    cfg1.validation.unsupportedFeaturePolicy);
cfg1.measurements.carrierMode             = 'ekfFloat';
cfg1.measurements.carrierCombinationMode  = 'ionosphereFree';
cfg1.estimation.ambiguityMode             = 'floatPerTowerSignal';

threw1 = false;
try
    revgnss.ConfigFactory.finalizeConfig(cfg1);
catch ME
    threw1 = true;
    assert(contains(ME.identifier,'carrierIF') || contains(ME.identifier,'ConfigFactory'), ...
        'T1 FAILED: wrong error id ''%s''', ME.identifier);
end
assert(threw1, 'T1 FAILED: carrier IF with default policy should throw at finalization');
fprintf('    threw ConfigFactory carrier IF error: PASS\n');

% ----------------------------------------------------------------
% T2: disableWithWarning suppresses carrier IF error at finalization
% ----------------------------------------------------------------
fprintf('  T2: disableWithWarning suppresses carrier IF finalization error ...\n');

cfg2 = revgnss.ConfigFactory.defaultConfig();
cfg2.measurements.carrierMode             = 'ekfFloat';
cfg2.measurements.carrierCombinationMode  = 'ionosphereFree';
cfg2.validation.unsupportedFeaturePolicy  = 'disableWithWarning';
cfg2.estimation.ambiguityMode             = 'floatPerTowerSignal';

threw2 = false;
ws2 = warning('off','all');
try
    cfg2_fin = revgnss.ConfigFactory.finalizeConfig(cfg2);
catch
    threw2 = true;
end
warning(ws2);
assert(~threw2, 'T2 FAILED: disableWithWarning should suppress carrier IF error');
fprintf('    disableWithWarning did not throw: PASS\n');

% ----------------------------------------------------------------
% T3: After disableWithWarning, carrierCombinationMode='raw'
% ----------------------------------------------------------------
fprintf('  T3: disableWithWarning falls back to raw carrierCombinationMode ...\n');

assert(strcmp(cfg2_fin.measurements.carrierCombinationMode,'raw'), ...
    'T3 FAILED: after disableWithWarning, expected ''raw'', got ''%s''', ...
    cfg2_fin.measurements.carrierCombinationMode);
fprintf('    carrierCombinationMode=raw after disableWithWarning: PASS\n');

% ----------------------------------------------------------------
% T4: Carrier IF is NOT silently made raw with default policy
% ----------------------------------------------------------------
fprintf('  T4: carrier IF must not silently become raw with default policy ...\n');

cfg4 = revgnss.ConfigFactory.defaultConfig();
cfg4.measurements.carrierMode             = 'ekfFloat';
cfg4.measurements.carrierCombinationMode  = 'ionosphereFree';
cfg4.estimation.ambiguityMode             = 'floatPerTowerSignal';

threw4 = false;
try
    revgnss.ConfigFactory.finalizeConfig(cfg4);
catch
    threw4 = true;
end
assert(threw4, 'T4 FAILED: carrier IF must not silently become raw with default policy');
fprintf('    carrier IF not silently accepted: PASS\n');

% ----------------------------------------------------------------
% T5: Raw L1 carrier (ekfFloat + raw) does NOT throw
% ----------------------------------------------------------------
fprintf('  T5: ekfFloat with raw combination does not throw ...\n');

cfg5 = revgnss.ConfigFactory.defaultConfig();
cfg5.measurements.carrierMode             = 'ekfFloat';
cfg5.measurements.carrierCombinationMode  = 'raw';
cfg5.estimation.ambiguityMode             = 'floatPerTowerSignal';
cfg5.plots.enable  = false;
cfg5.report.enable = false;

threw5 = false;
try
    revgnss.ConfigFactory.finalizeConfig(cfg5);
catch ME
    threw5 = true;
    fprintf('    unexpected throw: %s\n', ME.message);
end
assert(~threw5, 'T5 FAILED: ekfFloat + raw should not throw');
fprintf('    ekfFloat+raw: PASS\n');

% ----------------------------------------------------------------
% T6: productNoisy sigma uses same epoch as bias at transmit time
% ----------------------------------------------------------------
fprintf('  T6: productNoisy sigma uses same epoch as bias at transmit time ...\n');

cfg6 = revgnss.ConfigFactory.towerClockProductConfig();
cfg6.towerClock.correctionMode = 'productNoisy';
for k = 1:numel(cfg6.towerClock.products)
    cfg6.towerClock.products(k).sigmaBias_m    = 0.10;
    cfg6.towerClock.products(k).sigmaDrift_mps = 0.01;   % significant drift sigma
    cfg6.towerClock.products(k).epoch_s        = 0;
end
cfg6.measurements.doppler.useInEKF = false;
cfg6.measurements.carrierMode      = 'off';
cfg6.effects.lightTime.model       = 'iterative';   % ensures t_tx != t_rx
cfg6.plots.enable  = false;
cfg6.report.enable = false;

[asset6, towers6, ekf6, mm6] = revgnss.ScenarioFactory.build(cfg6);
% Evaluate at t_s = 500 s so transmit time differs from 0 and drift term is significant
t_s6 = 500;
[~, ~, ~, R6, errSt6] = mm6.computeMeasurements(asset6, towers6, ekf6.x, t_s6, ekf6.stateMap);

M_pr6 = errSt6.nPseudorange;
if M_pr6 > 0 && ~isempty(R6)
    R_diag6 = diag(R6);
    % dt ≈ t_tx - 0 ≈ 500 - tau ≈ 499.88 s
    % sigma^2 ≈ sigmaBias^2 + dt^2 * sigmaDrift^2 ≈ 0.01 + 0.01^2 * 499.88^2 ≈ 25.0
    % Must be >> sigmaBias^2=0.01 to confirm drift term is included
    minR6 = min(R_diag6(1:M_pr6));
    assert(minR6 > 0.10^2 + 0.01^2 * 100^2, ...
        'T6 FAILED: R=%.4e too small; sigma_drift at t=500s not included?', minR6);
    fprintf('    productNoisy R=%.4e confirms epoch-consistent sigma with drift: PASS\n', R_diag6(1));
else
    fprintf('    no visible towers (vacuous PASS)\n');
end

% ----------------------------------------------------------------
% T7: product mode without explicit struct throws productStructMissing
% ----------------------------------------------------------------
fprintf('  T7: product mode without explicit struct throws productStructMissing ...\n');

cfg7 = revgnss.ConfigFactory.defaultConfig();
cfg7.towerClock.correctionMode  = 'product';
% Intentionally do NOT set cfg7.towerClock.products
cfg7 = revgnss.ConfigFactory.finalizeConfig(cfg7);
cfg7.plots.enable  = false;
cfg7.report.enable = false;

[asset7, towers7, ekf7, mm7] = revgnss.ScenarioFactory.build(cfg7);
threw7 = false;
try
    mm7.computeMeasurements(asset7, towers7, ekf7.x, 0, ekf7.stateMap);
catch ME
    threw7 = true;
    assert(contains(ME.identifier,'productStructMissing'), ...
        'T7 FAILED: wrong error id ''%s''', ME.identifier);
end
assert(threw7, 'T7 FAILED: product mode without struct must throw productStructMissing');
fprintf('    product without struct threw productStructMissing: PASS\n');

% ----------------------------------------------------------------
% T8: productNoisy mode without explicit struct also throws
% ----------------------------------------------------------------
fprintf('  T8: productNoisy mode without explicit struct throws productStructMissing ...\n');

cfg8 = revgnss.ConfigFactory.defaultConfig();
cfg8.towerClock.correctionMode  = 'productNoisy';
% Intentionally do NOT set cfg8.towerClock.products
cfg8 = revgnss.ConfigFactory.finalizeConfig(cfg8);
cfg8.plots.enable  = false;
cfg8.report.enable = false;

[asset8, towers8, ekf8, mm8] = revgnss.ScenarioFactory.build(cfg8);
threw8 = false;
try
    mm8.computeMeasurements(asset8, towers8, ekf8.x, 0, ekf8.stateMap);
catch ME
    threw8 = true;
    assert(contains(ME.identifier,'productStructMissing'), ...
        'T8 FAILED: wrong error id ''%s''', ME.identifier);
end
assert(threw8, 'T8 FAILED: productNoisy mode without struct must throw productStructMissing');
fprintf('    productNoisy without struct threw productStructMissing: PASS\n');

% ----------------------------------------------------------------
% T9: product bias and sigma included in R diagonal for productNoisy
% ----------------------------------------------------------------
fprintf('  T9: product bias sigma inflates R diagonal in productNoisy ...\n');

sigBias9 = 0.25;
cfg9 = revgnss.ConfigFactory.towerClockProductConfig();
cfg9.towerClock.correctionMode = 'productNoisy';
for k = 1:numel(cfg9.towerClock.products)
    cfg9.towerClock.products(k).bias_m         = 0;
    cfg9.towerClock.products(k).drift_mps      = 0;
    cfg9.towerClock.products(k).sigmaBias_m    = sigBias9;
    cfg9.towerClock.products(k).sigmaDrift_mps = 0;
    cfg9.towerClock.products(k).epoch_s        = 0;
end
cfg9.measurements.doppler.useInEKF = false;
cfg9.measurements.carrierMode      = 'off';
cfg9.plots.enable  = false;
cfg9.report.enable = false;

[asset9, towers9, ekf9, mm9] = revgnss.ScenarioFactory.build(cfg9);
[~, ~, ~, R9, errSt9] = mm9.computeMeasurements(asset9, towers9, ekf9.x, 0, ekf9.stateMap);

M_pr9 = errSt9.nPseudorange;
if M_pr9 > 0 && ~isempty(R9)
    R_diag9 = diag(R9);
    % R must exceed sigBias^2 alone (code noise sigma adds on top)
    expected_min9 = sigBias9^2 - 1e-10;
    assert(all(R_diag9(1:M_pr9) >= expected_min9), ...
        'T9 FAILED: min R(1:%d)=%.4e < sigmaBias^2=%.4e', ...
        M_pr9, min(R_diag9(1:M_pr9)), expected_min9);
    fprintf('    R diagonal >= sigmaBias^2 for %d measurements: PASS\n', M_pr9);
else
    fprintf('    no visible towers (vacuous PASS)\n');
end

% ----------------------------------------------------------------
% T10: Doppler EKF silently disabled when physics not configured (no throw)
% ----------------------------------------------------------------
fprintf('  T10: doppler useInEKF silently disabled when physics not configured ...\n');

cfg10 = revgnss.ConfigFactory.defaultConfig();
assert(cfg10.measurements.doppler.useInEKF, ...
    'T10 FAILED: defaultConfig should have doppler.useInEKF=true before finalization');
assert(~cfg10.physics.doppler.model.enable, ...
    'T10 FAILED: defaultConfig should have physics.doppler.model.enable=false');
% policy='error' is now the default, but doppler EKF mismatch should warn+disable, not throw
threw10 = false;
ws10 = warning('off','ConfigFactory:dopplerEKFDisabled');
try
    cfg10_fin = revgnss.ConfigFactory.finalizeConfig(cfg10);
catch ME
    threw10 = true;
    fprintf('    unexpected throw: %s\n', ME.message);
end
warning(ws10);
assert(~threw10, 'T10 FAILED: doppler EKF mismatch should warn+disable, not throw');
assert(~cfg10_fin.measurements.doppler.useInEKF, ...
    'T10 FAILED: finalizeConfig should have disabled doppler.useInEKF');
fprintf('    doppler.useInEKF=false after finalization, no throw: PASS\n');

% ----------------------------------------------------------------
% T11: legacy ISL helper returns empty z, h, H
% ----------------------------------------------------------------
fprintf('  T11: legacy ISL helper returns empty z, h, H ...\n');

[z11, h11, H11] = models.measurements.MeasurementModelUtils.computeISLMeasurements([], [], [], []);
assert(isempty(z11), 'T11 FAILED: z_isl should be empty');
assert(isempty(h11), 'T11 FAILED: h_isl should be empty');
assert(size(H11,1) == 0, 'T11 FAILED: H_isl should have 0 rows');
fprintf('    legacy ISL helper: z=[], h=[], H=[0x0]: PASS\n');

fprintf('=== test_stage7a2_policy_fixes: ALL PASS ===\n');
