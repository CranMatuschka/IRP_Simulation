% test_point34_carrier_slip_phase_bias
% Carrier slip common-mode guards and inter-antenna phase-bias controls.

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));
addpath(fullfile(thisDir, '..', 'config'));

fprintf('=== test_point34_carrier_slip_phase_bias ===\n');

% -------------------------------------------------------------------------
fprintf('  T1: legacy per-track jumps still reset when common-mode guard is off ...\n');
cfg1 = localSlipCfg_(false, false);
tm1 = revgnss.CarrierTrackManager();
tm1.process(localCp_((1:4)', ones(4,1), zeros(4,1)), cfg1);
[s1, keep1, r1] = tm1.process(localCp_((1:4)', ones(4,1), 0.20*ones(4,1)), cfg1);
assert(s1.nSlips == 4, 'T1 FAILED: legacy path should flag all common jumps.');
assert(~any(keep1), 'T1 FAILED: resetAndSkip should drop all slipped rows.');
assert(numel(r1) == 4, 'T1 FAILED: expected four reset requests.');
fprintf('    PASS\n');

% -------------------------------------------------------------------------
fprintf('  T2: common-mode guard suppresses receiver-clock-like jumps ...\n');
cfg2 = localSlipCfg_(true, false);
tm2 = revgnss.CarrierTrackManager();
tm2.process(localCp_((1:4)', ones(4,1), zeros(4,1)), cfg2);
[s2, keep2, r2] = tm2.process(localCp_((1:4)', ones(4,1), 0.20*ones(4,1)), cfg2);
assert(s2.nSlips == 0, 'T2 FAILED: common jump should not be a slip.');
assert(all(keep2), 'T2 FAILED: common-mode rows should be kept.');
assert(isempty(r2), 'T2 FAILED: common-mode event should not reset ambiguities.');
assert(s2.nCommonModeEvents == 1, 'T2 FAILED: common-mode event not reported.');
assert(s2.nSuppressedCommonModeResets == 4, 'T2 FAILED: suppressed reset count wrong.');
fprintf('    PASS\n');

% -------------------------------------------------------------------------
fprintf('  T3: common-mode guard preserves localized slip sensitivity ...\n');
tm3 = revgnss.CarrierTrackManager();
tm3.process(localCp_((1:4)', ones(4,1), zeros(4,1)), cfg2);
[s3, keep3, r3] = tm3.process(localCp_((1:4)', ones(4,1), [0.20; 0.20; 0.45; 0.20]), cfg2);
assert(s3.nSlips == 1, 'T3 FAILED: localized slip should remain detectable.');
assert(~keep3(3) && all(keep3([1 2 4])), 'T3 FAILED: only localized row should be dropped.');
assert(numel(r3) == 1 && r3(1).towerIdx == 3, 'T3 FAILED: wrong reset request.');
fprintf('    PASS\n');

% -------------------------------------------------------------------------
fprintf('  T4: baseline-differenced mode cancels common antenna-pair jumps ...\n');
cfg4 = localSlipCfg_(false, true);
tw = [1; 1; 2; 2];
ant = [1; 2; 1; 2];
tm4 = revgnss.CarrierTrackManager();
tm4.process(localCp_(tw, ant, zeros(4,1)), cfg4);
[s4, keep4, r4] = tm4.process(localCp_(tw, ant, [0.20; 0.20; 0.20; 0.45]), cfg4);
assert(s4.nSlips == 1, 'T4 FAILED: only baseline-local jump should slip.');
assert(~keep4(4) && all(keep4(1:3)), 'T4 FAILED: baseline differencing dropped wrong rows.');
assert(numel(r4) == 1 && r4(1).towerIdx == 2 && r4(1).receiverIdx == 2, ...
    'T4 FAILED: wrong baseline reset request.');
assert(s4.nBaselineDifferencedRows == 2, 'T4 FAILED: baseline row count wrong.');
fprintf('    PASS\n');

% -------------------------------------------------------------------------
fprintf('  T5: calibrated inter-antenna phase-bias helper is zero when disabled ...\n');
cfg5 = masterConfig();
lambda1 = revgnss.SignalDefinition.get('L1').wavelength_m;
lambda2 = revgnss.SignalDefinition.get('L2').wavelength_m;
assert(revgnss.InterAntennaPhaseBias.modelBiasMeters(cfg5, 2, 1) == 0, ...
    'T5 FAILED: disabled model must be zero.');
cfg5.estimator.interAntennaCarrierBias.enable = true;
cfg5.estimator.interAntennaCarrierBias.mode = 'fixedKnown';
cfg5.estimator.interAntennaCarrierBias.bias_cycles = [0 0; 0.25 -0.50];
[alphaIF, betaIF] = revgnss.IonoFreeCombination.coefficients( ...
    revgnss.SignalDefinition.get('L1').frequency_Hz, ...
    revgnss.SignalDefinition.get('L2').frequency_Hz);
assert(abs(revgnss.InterAntennaPhaseBias.modelBiasMeters(cfg5, 2, 1) - 0.25*lambda1) < 1e-12, ...
    'T5 FAILED: L1 phase-bias conversion wrong.');
assert(abs(revgnss.InterAntennaPhaseBias.modelBiasMeters(cfg5, 2, 2) + 0.50*lambda2) < 1e-12, ...
    'T5 FAILED: L2 phase-bias conversion wrong.');
assert(abs(revgnss.InterAntennaPhaseBias.modelBiasMeters(cfg5, 2, 0) - ...
    (alphaIF*0.25*lambda1 + betaIF*(-0.50)*lambda2)) < 1e-12, ...
    'T5 FAILED: ionosphere-free phase-bias conversion wrong.');
assert(revgnss.InterAntennaPhaseBias.modelBiasMeters(cfg5, 1, 1) == 0, ...
    'T5 FAILED: reference receiver must stay zero.');
fprintf('    PASS\n');

% -------------------------------------------------------------------------
fprintf('  T6: phase-bias status finalizer is opt-in and model-aware ...\n');
cfg6 = masterConfig();
cfg6.errors.interAntennaCarrierBias.enable = true;
cfg6.estimator.diffAtt.ambiguityResolution.enforcePhaseBiasStatus = true;
cfg6.estimator.interAntennaCarrierBias.enable = false;
cfg6 = revgnss.ConfigFactory.finalizeConfig(cfg6);
assert(strcmp(cfg6.estimator.diffAtt.ambiguityResolution.phaseBiasStatus, 'notCalibratedExternalProduct'), ...
    'T6 FAILED: unmodelled truth bias should be notCalibratedExternalProduct.');

cfg6b = masterConfig();
cfg6b.errors.interAntennaCarrierBias.enable = true;
cfg6b.estimator.diffAtt.ambiguityResolution.enforcePhaseBiasStatus = true;
cfg6b.estimator.interAntennaCarrierBias.enable = true;
cfg6b.estimator.interAntennaCarrierBias.mode = 'fixedKnown';
cfg6b.estimator.interAntennaCarrierBias.bias_cycles = zeros(4,2);
cfg6b = revgnss.ConfigFactory.finalizeConfig(cfg6b);
assert(strcmp(cfg6b.estimator.diffAtt.ambiguityResolution.phaseBiasStatus, 'calibratedExternalProduct'), ...
    'T6 FAILED: fixed model should be calibratedExternalProduct.');
fprintf('    PASS\n');

% -------------------------------------------------------------------------
fprintf('  T7: ambiguity resolver can block uncalibrated phase-bias fixing ...\n');
cfg7 = masterConfig();
cfg7.estimator.diffAtt.ambiguityResolution.requirePhaseBiasCalibrationForFix = true;
cfg7.estimator.diffAtt.ambiguityResolution.phaseBiasStatus = 'notCalibratedExternalProduct';
store7 = localOneBaselineStore_(3, lambda1);
out7 = revgnss.BaselineCarrierAmbiguityResolver.resolve(store7, cfg7);
assert(out7.nIntegerFixed == 0, 'T7 FAILED: uncalibrated phase bias should block fixes.');
assert(strcmp(out7.ambiguityStatus{1,1}, 'rejectedPhaseBias'), ...
    'T7 FAILED: rejection reason should be rejectedPhaseBias.');

cfg7.estimator.diffAtt.ambiguityResolution.phaseBiasStatus = 'syntheticKnownZero';
out7b = revgnss.BaselineCarrierAmbiguityResolver.resolve(store7, cfg7);
assert(out7b.nIntegerFixed == 1, 'T7 FAILED: known-zero phase bias should allow fixing.');
assert(strcmp(out7b.ambiguityStatus{1,1}, 'fixedInteger'), ...
    'T7 FAILED: expected fixedInteger after known-zero status.');
fprintf('    PASS\n');

fprintf('=== test_point34_carrier_slip_phase_bias: ALL PASS ===\n');

function cfg = localSlipCfg_(commonMode, baselineMode)
    cfg = revgnss.ConfigFactory.defaultConfig();
    cfg.measurements.carrier.slipDetection.enable = true;
    cfg.measurements.carrier.slipDetection.threshold_m = 0.10;
    cfg.measurements.carrier.slipDetection.minEpochsBeforeDetect = 2;
    cfg.measurements.carrier.slipDetection.action = 'resetAndSkip';
    cfg.carrierSlip.productStepCompensation = false;
    cfg.carrierSlip.commonModeCompensation.enable = commonMode;
    cfg.carrierSlip.commonModeCompensation.minRows = 4;
    cfg.carrierSlip.baselineDifferencedMode.enable = baselineMode;
    cfg.carrierSlip.baselineDifferencedMode.referenceAntenna = 1;
end

function cp = localCp_(towerIdx, antennaIdx, prefit)
    cp.towerIdx = towerIdx(:);
    cp.antennaIdx = antennaIdx(:);
    cp.signalIdx = ones(numel(prefit), 1);
    cp.prefit_m = prefit(:);
end

function store = localOneBaselineStore_(N, lambda)
    store.nTowers = 1;
    store.nBaselines = 1;
    store.accumN = 60;
    store.accumSum = 60 * lambda * N;
    store.accumSumSq = 60 * (lambda * N)^2;
    store.delta_B = 0;
    store.referenceAttitude_euler_rad = [];
end
