% test_stage14_6_multi_receiver_carrier_ambiguity
%
% Stage 14.6: floatPerTowerReceiverSignal ambiguity mode.
%
% T1: floatPerTowerSignal + nReceivers>1 still throws an error (guard preserved).
% T2: floatPerTowerReceiverSignal + nReceivers>1 passes finalizeConfig.
% T3: floatPerTowerReceiverSignal + nReceivers=1 also passes (single-receiver use).
% T4: nAmbiguities = nTowers * nReceivers for the new mode.
% T5: ambiguityIdx3d has correct shape [nTowers x nReceivers x 1].
% T6: ambiguityIdx (legacy 2D) is all-zeros for new mode.
% T7: resetAmbiguityCovariance with receiverIdx resets the correct P diagonal entry.
% T8: CarrierTrackManager.process sets receiverIdx in resetRequests.
% T9: Short smoke run (10 epochs) with 3 receivers does not throw.
% T10: nAmbiguities = nTowers*nReceivers states in EKF for smoke run.

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_stage14_6_multi_receiver_carrier_ambiguity ===\n');

nTowers    = 5;
nReceivers = 3;

% ----------------------------------------------------------------
% T1: floatPerTowerSignal + nReceivers>1 → error (guard preserved)
% ----------------------------------------------------------------
fprintf('  T1: floatPerTowerSignal + nReceivers>1 still errors ...\n');

cfg_t1 = revgnss.ConfigFactory.defaultConfig();
cfg_t1.measurements.carrierMode   = 'ekfFloat';
cfg_t1.estimation.ambiguityMode   = 'floatPerTowerSignal';
cfg_t1.scenario.nReceivers        = 3;
cfg_t1.validation.unsupportedFeaturePolicy = 'error';
cfg_t1.plots.enable  = false;
cfg_t1.report.enable = false;

threwErr1 = false;
wState1 = warning('off','all');
try
    revgnss.ConfigFactory.finalizeConfig(cfg_t1);
catch ME1
    threwErr1 = true;
    assert(contains(ME1.identifier,'ConfigFactory'), ...
        'T1 FAILED: wrong error identifier ''%s''', ME1.identifier);
end
warning(wState1);
assert(threwErr1, 'T1 FAILED: expected error for floatPerTowerSignal + nReceivers>1');
fprintf('    PASS (error thrown as expected)\n');

% ----------------------------------------------------------------
% T2: floatPerTowerReceiverSignal + nReceivers>1 passes
% ----------------------------------------------------------------
fprintf('  T2: floatPerTowerReceiverSignal + nReceivers>1 passes finalizeConfig ...\n');

cfg_t2 = revgnss.ConfigFactory.defaultConfig();
cfg_t2.measurements.carrierMode   = 'ekfFloat';
cfg_t2.estimation.ambiguityMode   = 'floatPerTowerReceiverSignal';
cfg_t2.scenario.nReceivers        = nReceivers;
cfg_t2.validation.unsupportedFeaturePolicy = 'disableWithWarning';
cfg_t2.plots.enable  = false;
cfg_t2.report.enable = false;

threwErr2 = false;
cfg_t2f   = [];
wState2 = warning('off','all');
try
    cfg_t2f = revgnss.ConfigFactory.finalizeConfig(cfg_t2);
catch ME2
    threwErr2 = true;
    fprintf('    ERROR: %s\n', ME2.message);
end
warning(wState2);
assert(~threwErr2, 'T2 FAILED: floatPerTowerReceiverSignal + nReceivers>1 should not throw');
fprintf('    PASS (no error)\n');

% ----------------------------------------------------------------
% T3: floatPerTowerReceiverSignal + nReceivers=1 passes
% ----------------------------------------------------------------
fprintf('  T3: floatPerTowerReceiverSignal + nReceivers=1 passes ...\n');

cfg_t3 = revgnss.ConfigFactory.defaultConfig();
cfg_t3.measurements.carrierMode   = 'ekfFloat';
cfg_t3.estimation.ambiguityMode   = 'floatPerTowerReceiverSignal';
cfg_t3.scenario.nReceivers        = 1;
cfg_t3.plots.enable  = false;
cfg_t3.report.enable = false;

threwErr3 = false;
wState3 = warning('off','all');
try
    revgnss.ConfigFactory.finalizeConfig(cfg_t3);
catch ME3
    threwErr3 = true;
    fprintf('    ERROR: %s\n', ME3.message);
end
warning(wState3);
assert(~threwErr3, 'T3 FAILED: floatPerTowerReceiverSignal + nReceivers=1 should not throw');
fprintf('    PASS (single-receiver new mode OK)\n');

% ----------------------------------------------------------------
% T4: nAmbiguities = nTowers * nReceivers
% ----------------------------------------------------------------
fprintf('  T4: nAmbiguities = nTowers * nReceivers for new mode ...\n');

wState4 = warning('off','all');
[~, ~, ekf_t4] = revgnss.ScenarioFactory.build(cfg_t2f);
warning(wState4);

expectedNAmb = nTowers * nReceivers;  % L1 only
assert(ekf_t4.nAmbiguities == expectedNAmb, ...
    'T4 FAILED: nAmbiguities=%d, expected %d (%d towers x %d receivers)', ...
    ekf_t4.nAmbiguities, expectedNAmb, nTowers, nReceivers);
fprintf('    PASS (nAmbiguities=%d = %d*%d)\n', ekf_t4.nAmbiguities, nTowers, nReceivers);

% ----------------------------------------------------------------
% T5: ambiguityIdx3d shape = [nTowers x nReceivers x 1]
% ----------------------------------------------------------------
fprintf('  T5: ambiguityIdx3d has shape [nTowers x nReceivers x 1] ...\n');

sm4 = ekf_t4.stateMap;
assert(isfield(sm4,'ambiguityIdx3d'), 'T5 FAILED: ambiguityIdx3d field missing from stateMap');
d1 = size(sm4.ambiguityIdx3d, 1);
d2 = size(sm4.ambiguityIdx3d, 2);
d3 = size(sm4.ambiguityIdx3d, 3);  % always valid; trailing 1 is safe
assert(d1 == nTowers,    'T5 FAILED: dim1=%d, expected %d', d1, nTowers);
assert(d2 == nReceivers, 'T5 FAILED: dim2=%d, expected %d', d2, nReceivers);
assert(d3 == 1,          'T5 FAILED: dim3=%d, expected 1 (L1 only)', d3);
fprintf('    PASS (shape=[%d %d %d])\n', d1, d2, d3);

% ----------------------------------------------------------------
% T6: legacy ambiguityIdx (2D) is all-zeros for new mode
% ----------------------------------------------------------------
fprintf('  T6: legacy ambiguityIdx is all-zeros for new mode ...\n');

assert(isfield(sm4,'ambiguityIdx'), 'T6 FAILED: ambiguityIdx field missing');
assert(all(sm4.ambiguityIdx(:) == 0), ...
    'T6 FAILED: legacy ambiguityIdx should be zeros for floatPerTowerReceiverSignal');
fprintf('    PASS (legacy slot is zero-filled)\n');

% ----------------------------------------------------------------
% T7: resetAmbiguityCovariance resets correct P entry
% ----------------------------------------------------------------
fprintf('  T7: resetAmbiguityCovariance with receiverIdx resets correct P entry ...\n');

ti7 = 2; ri7 = 2; si7 = 1;
sigma7 = 55.0;
targetIdx7 = sm4.ambiguityIdx3d(ti7, ri7, si7);
assert(targetIdx7 > 0, 'T7 FAILED: target state index is 0');

% Set P diagonal to known value, then reset
ekf_t4.P(targetIdx7, targetIdx7) = 1234.5;
ekf_t4.resetAmbiguityCovariance(ti7, si7, sigma7, ri7);
assert(abs(ekf_t4.P(targetIdx7, targetIdx7) - sigma7^2) < 1e-9, ...
    'T7 FAILED: P(%d,%d)=%.2f, expected %.2f', ...
    targetIdx7, targetIdx7, ekf_t4.P(targetIdx7,targetIdx7), sigma7^2);
% Off-diagonal should be zero
assert(all(ekf_t4.P(targetIdx7, [1:targetIdx7-1, targetIdx7+1:end]) == 0), ...
    'T7 FAILED: off-diagonal not zeroed after reset');
fprintf('    PASS (P[%d,%d]=%.0f^2 after reset)\n', targetIdx7, targetIdx7, sigma7);

% ----------------------------------------------------------------
% T8: CarrierTrackManager sets receiverIdx in resetRequests
% ----------------------------------------------------------------
fprintf('  T8: CarrierTrackManager.process includes receiverIdx in resetRequests ...\n');

ctm8 = revgnss.CarrierTrackManager();
cfg8 = revgnss.ConfigFactory.defaultConfig();
cfg8.measurements.carrier.slipDetection.enable                = true;
cfg8.measurements.carrier.slipDetection.threshold_m           = 0.05;
cfg8.measurements.carrier.slipDetection.minEpochsBeforeDetect = 1;
cfg8.measurements.carrier.slipDetection.action                = 'resetAndSkip';

cpInfo8.towerIdx   = [1; 2];
cpInfo8.antennaIdx = [1; 3];   % antenna 3 is receiver 3
cpInfo8.signalIdx  = [1; 1];
cpInfo8.prefit_m   = [0.01; 0.01];

% Epoch 1: seed history
ctm8.process(cpInfo8, cfg8);

% Epoch 2: large jump on row 2
cpInfo8b = cpInfo8;
cpInfo8b.prefit_m = [0.01; 5.0];  % tower 2, antenna 3: large jump
[~, ~, rr8] = ctm8.process(cpInfo8b, cfg8);

assert(numel(rr8) >= 1, 'T8 FAILED: expected at least one reset request');
% Find the reset for tower 2
found8 = false;
for ri8 = 1:numel(rr8)
    if rr8(ri8).towerIdx == 2
        assert(isfield(rr8(ri8),'receiverIdx'), 'T8 FAILED: receiverIdx field missing from resetRequests');
        assert(rr8(ri8).receiverIdx == 3, ...
            'T8 FAILED: receiverIdx=%d, expected 3', rr8(ri8).receiverIdx);
        found8 = true;
        break;
    end
end
assert(found8, 'T8 FAILED: no reset request for tower 2 found');
fprintf('    PASS (receiverIdx=3 in resetRequests)\n');

% ----------------------------------------------------------------
% T9: Short smoke run with 3 receivers + new mode does not throw
% ----------------------------------------------------------------
fprintf('  T9: Short 10-epoch smoke run with floatPerTowerReceiverSignal ...\n');

cfg_t9 = revgnss.ConfigFactory.defaultConfig();
cfg_t9.scenario.nReceivers                  = 3;
cfg_t9.simulation.duration_s                = 9;
cfg_t9.simulation.dt_s                      = 1;
cfg_t9.measurements.carrierMode             = 'ekfFloat';
cfg_t9.estimation.ambiguityMode             = 'floatPerTowerReceiverSignal';
cfg_t9.estimation.ambiguity.initialSigma_m  = 100;
cfg_t9.measurements.doppler.enable          = true;
cfg_t9.measurements.doppler.useInEKF        = true;
cfg_t9.physics.doppler.truth.enable         = true;
cfg_t9.physics.doppler.model.enable         = true;
cfg_t9.measurements.carrier.slipDetection.enable = true;
cfg_t9.measurements.carrier.slipDetection.threshold_m = 0.1;
cfg_t9.measurements.carrier.slipDetection.minEpochsBeforeDetect = 3;
cfg_t9.measurements.carrier.slipDetection.action = 'resetAndSkip';
cfg_t9.errors.codeNoise.sigma_m             = 0.3;
cfg_t9.report.writePdf                      = false;
cfg_t9.report.writeMat                      = false;
cfg_t9.plots.enable                         = false;
cfg_t9.validation.unsupportedFeaturePolicy  = 'disableWithWarning';

threwErr9 = false;
wState9 = warning('off','all');
try
    sim9 = revgnss.ReverseGNSSSimulation(cfg_t9);
    sim9.initialize();
    sim9.run();
catch ME9
    threwErr9 = true;
    fprintf('    ERROR: %s\n', ME9.message);
end
warning(wState9);
assert(~threwErr9, 'T9 FAILED: smoke run threw an error');
fprintf('    PASS (10-epoch smoke run completed)\n');

% ----------------------------------------------------------------
% T10: EKF nx increased by nTowers*nReceivers ambiguity states
% ----------------------------------------------------------------
fprintf('  T10: EKF nx = 14 + nTowers*nReceivers ambiguity states ...\n');

nxExpected = 14 + nTowers * nReceivers;  % base + ambiguities
assert(sim9.ekf.nx == nxExpected, ...
    'T10 FAILED: ekf.nx=%d, expected %d (14 + %d*%d)', ...
    sim9.ekf.nx, nxExpected, nTowers, nReceivers);
fprintf('    PASS (ekf.nx=%d = 14 + %d)\n', sim9.ekf.nx, nTowers*nReceivers);

fprintf('=== test_stage14_6_multi_receiver_carrier_ambiguity: ALL PASS ===\n');
