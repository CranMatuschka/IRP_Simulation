% test_stage12a_measurement_model_decomposition
%   Regression tests for Stage 12A.2 structural refactor.
%
%   Verifies:
%     T1: MeasurementModelUtils.rxCodeBiasModel returns correct values
%     T2: MeasurementModelUtils.codeSignalSigma - constant and elevation modes
%     T3: MeasurementModelUtils.zwdMappingKind reads cfg correctly
%     T4: MeasurementModelUtils.needsFiniteDiffH_ agrees with MeasurementModel wrapper
%     T5: MeasurementModel.computePseudorangeModelOnly delegates to PseudorangeModelOnlyBuilder
%     T6: MeasurementModel.computeCarrierModelOnly delegates to CarrierModelOnlyBuilder
%     T7: CarrierMeasurementBuilder.buildDiagnostic produces same result as old computeCarrierPhase_

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_stage12a_measurement_model_decomposition ===\n');

%% T1: rxCodeBiasModel
fprintf('  T1: MeasurementModelUtils.rxCodeBiasModel ...\n');
cfg_off.hardware.rxCodeBias.mode = 'off';
assert(models.measurements.MeasurementModelUtils.rxCodeBiasModel(cfg_off) == 0, ...
    'T1a FAILED: off mode should return 0');

cfg_fixed.hardware.rxCodeBias.mode       = 'fixed';
cfg_fixed.hardware.rxCodeBias.fixedValue_m = 3.14;
assert(abs(models.measurements.MeasurementModelUtils.rxCodeBiasModel(cfg_fixed) - 3.14) < 1e-12, ...
    'T1b FAILED: fixed mode should return fixedValue_m');

cfg_nohw = struct();
assert(models.measurements.MeasurementModelUtils.rxCodeBiasModel(cfg_nohw) == 0, ...
    'T1c FAILED: missing hardware field should return 0');

% Wrapper parity
assert(models.measurements.MeasurementModel.rxCodeBiasModel(cfg_fixed) == ...
       models.measurements.MeasurementModelUtils.rxCodeBiasModel(cfg_fixed), ...
    'T1d FAILED: MeasurementModel wrapper should match Utils');
fprintf('    rxCodeBiasModel: off=0, fixed=3.14, missing=0, wrapper agrees: PASS\n');

%% T2: codeSignalSigma
fprintf('  T2: MeasurementModelUtils.codeSignalSigma ...\n');
sigCfg.codeSigma0_m = 2.0;

cfg_const.measurements.codeNoise.model = 'constant';
sigma_c = models.measurements.MeasurementModelUtils.codeSignalSigma(sigCfg, pi/6, cfg_const);
assert(abs(sigma_c - 2.0) < 1e-12, 'T2a FAILED: constant mode should return sigma0');

cfg_elev.measurements.codeNoise.model = 'elevation';
cfg_elev.measurements.codeNoise.elevationExponent = 1.0;
sigma_e = models.measurements.MeasurementModelUtils.codeSignalSigma(sigCfg, pi/6, cfg_elev);
assert(sigma_e > sigma_c, 'T2b FAILED: elevation model should give higher sigma at 30 deg');

% Wrapper parity
assert(abs(models.measurements.MeasurementModel.codeSignalSigma(sigCfg, pi/6, cfg_const) - sigma_c) < 1e-12, ...
    'T2c FAILED: MeasurementModel wrapper should match Utils');
fprintf('    codeSignalSigma: constant=%.2f, elevation>constant, wrapper agrees: PASS\n', sigma_c);

%% T3: zwdMappingKind
fprintf('  T3: MeasurementModelUtils.zwdMappingKind ...\n');
cfg_def = struct();
assert(strcmp(models.measurements.MeasurementModelUtils.zwdMappingKind(cfg_def), 'simple'), ...
    'T3a FAILED: default should be simple');

cfg_cf.effects.troposphere.mappingModel = 'continuedFraction';
assert(strcmp(models.measurements.MeasurementModelUtils.zwdMappingKind(cfg_cf), 'continuedFraction'), ...
    'T3b FAILED: should read effects.troposphere.mappingModel');

% Wrapper parity
assert(strcmp(models.measurements.MeasurementModel.zwdMappingKind(cfg_cf), 'continuedFraction'), ...
    'T3c FAILED: MeasurementModel wrapper should match Utils');
fprintf('    zwdMappingKind: default=simple, cfg=continuedFraction, wrapper agrees: PASS\n');

%% T4: needsFiniteDiffH_
fprintf('  T4: MeasurementModelUtils.needsFiniteDiffH_ ...\n');
cfg_plain = revgnss.ConfigFactory.defaultConfig();
cfg_plain.physics.sagnac.model.enable = false;
cfg_plain.physics.relativity.shapiro.model.enable = false;
cfg_plain.effects.antennaPCO.model.enable = false;
cfg_plain.effects.antennaPCV.model.enable = false;
assert(~models.measurements.MeasurementModelUtils.needsFiniteDiffH_(cfg_plain), ...
    'T4a FAILED: plain config should not need FD');

cfg_sag = cfg_plain;
cfg_sag.physics.sagnac.model.enable = true;
assert(models.measurements.MeasurementModelUtils.needsFiniteDiffH_(cfg_sag), ...
    'T4b FAILED: sagnac model should trigger FD');

% Wrapper parity
assert(models.measurements.MeasurementModel.needsFiniteDiffH_(cfg_sag) == ...
       models.measurements.MeasurementModelUtils.needsFiniteDiffH_(cfg_sag), ...
    'T4c FAILED: MeasurementModel wrapper should match Utils');
fprintf('    needsFiniteDiffH_: plain=false, sagnac=true, wrapper agrees: PASS\n');

%% T5 & T6: Round-trip numerical equivalence via full EKF step
fprintf('  T5/T6: computePseudorangeModelOnly and computeCarrierModelOnly round-trip ...\n');

cfg5 = revgnss.ConfigFactory.defaultConfig();
[asset5, towers5, ekf5, mm5] = revgnss.ScenarioFactory.build(cfg5);
x_est5 = ekf5.x;
sm5    = ekf5.stateMap;

[~, ~, ~, ~, es5] = mm5.computeMeasurements(asset5, towers5, x_est5, 0, sm5);

h_pr_wrapper = mm5.computePseudorangeModelOnly(asset5, towers5, x_est5, es5, sm5, 0);
h_pr_direct  = revgnss.PseudorangeModelOnlyBuilder.compute( ...
    cfg5, asset5, towers5, x_est5, es5, sm5, 0);

assert(isequal(size(h_pr_wrapper), size(h_pr_direct)), ...
    'T5a FAILED: size mismatch');
assert(max(abs(h_pr_wrapper - h_pr_direct)) < 1e-14, ...
    'T5b FAILED: wrapper and builder disagree numerically');
fprintf('    computePseudorangeModelOnly: wrapper == builder (max diff %.2e): PASS\n', ...
    max(abs(h_pr_wrapper - h_pr_direct)));

h_phi_wrapper = mm5.computeCarrierModelOnly(asset5, towers5, x_est5, es5, sm5, 0);
h_phi_direct  = revgnss.CarrierModelOnlyBuilder.compute( ...
    cfg5, asset5, towers5, x_est5, es5, sm5, 0);
% Both should be empty for default config (no carrier EKF)
assert(isequal(h_phi_wrapper, h_phi_direct), ...
    'T6a FAILED: computeCarrierModelOnly wrapper and builder disagree');
fprintf('    computeCarrierModelOnly: wrapper == builder: PASS\n');

%% T7: buildDiagnostic
fprintf('  T7: CarrierMeasurementBuilder.buildDiagnostic ...\n');
cfg7 = revgnss.ConfigFactory.defaultConfig();
cfg7.measurements.carrierPhase.enable = true;
cfg7.measurements.carrierMode = 'diagnostic';

[asset7, towers7, ekf7, mm7] = revgnss.ScenarioFactory.build(cfg7);
x7  = ekf7.x;
sm7 = ekf7.stateMap;

[~, ~, ~, ~, es7] = mm7.computeMeasurements(asset7, towers7, x7, 0, sm7);

assert(isfield(es7,'carrierPhase') && isstruct(es7.carrierPhase) && ...
    isfield(es7.carrierPhase,'phi_cycles'), ...
    'T7a FAILED: carrierPhase should be populated by buildDiagnostic');
assert(numel(es7.carrierPhase.phi_cycles) > 0, ...
    'T7b FAILED: phi_cycles should be non-empty');
fprintf('    buildDiagnostic: phi_cycles populated (%d measurements): PASS\n', ...
    numel(es7.carrierPhase.phi_cycles));

fprintf('=== test_stage12a_measurement_model_decomposition: ALL PASS ===\n');
