function test_four_timestamp_ground_space_time_transfer_builder()
% test_four_timestamp_ground_space_time_transfer_builder  Plan Section 4.4, Stage-4 named test.
% revgnss.FourTimestampGroundSpaceTimeTransferBuilder -- the tower<->spacecraft direct
% four-timestamp physics, dispatched from revgnss.TwoWayTimeTransferBuilder when
% cfg.measurements.twoWayTimeTransfer.mode=='fourTimestampClockDifference'. Exercises the full
% live pipeline (revgnss.ReverseGNSSSimulation.initialize/runLocalEstimationEpoch) end to end, not
% just the builder called in isolation, since the dispatch itself (both call sites now passing
% obj.ekf.getMeasurementState() rather than raw obj.ekf.x -- see file header comments in
% +revgnss/ReverseGNSSSimulation.m) is part of what this section changed.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
addpath(rootDir);
addpath(fullfile(rootDir,'config'));
addpath(fullfile(rootDir,'config','internal'));

fprintf('=== test_four_timestamp_ground_space_time_transfer_builder ===\n');
i_test_end_to_end_epoch_and_dispatch_();
i_test_predictEkfRows_matches_build_row_count_();
i_test_validateConfig_rejects_bad_sigma_();
i_test_validateConfig_refuses_applyAtmosphere_true_();
i_test_validateConfig_rejects_estimateTowerClocks_true_();
i_test_validateConfig_rejects_nonzero_counterTagSigma_();
i_test_validateConfig_rejects_nonzero_calibrationSigma_();
i_test_validateConfig_rejects_includeReciprocityResidual_true_();
fprintf('=== test_four_timestamp_ground_space_time_transfer_builder: ALL PASS ===\n');
end

% ================================================================================================
function i_test_end_to_end_epoch_and_dispatch_()
[cfg, sim, t_s] = i_groundSpaceFixture_();

[zAdd, hAdd, HAdd, RAdd, info] = revgnss.TwoWayTimeTransferBuilder.build( ...
    cfg, sim.errorChain, sim.asset, sim.towers, sim.ekf.getMeasurementState(), sim.ekf.stateMap, ...
    sim.ekf.nx, t_s);
assert(info.enabled,'FAIL: fourTimestampClockDifference ground-space mode must report enabled=true.');
assert(~isempty(zAdd),'FAIL: expected at least one visible-tower row.');
assert(all(isfinite(zAdd)) && all(isfinite(hAdd)) && all(isfinite(RAdd(:))));
assert(size(HAdd,2)==sim.ekf.nx);
n = size(HAdd,1);
Rsym = RAdd - RAdd';
assert(norm(Rsym,'fro') < 1e-9*max(1,norm(RAdd,'fro')),'FAIL: R must be symmetric.');
assert(min(eig((RAdd+RAdd')/2)) > -1e-12,'FAIL: R must be PSD.');
% Combined-review T1: residual closure between the truth generator (zAdd) and the estimator
% predictor (hAdd) -- a genuine sign flip or origin/anchor endpoint-order swap in either side
% would blow the prefit residual up by orders of magnitude relative to the declared sigma, which
% every prior assertion here (finiteness, PSD-ness) is blind to.
prefitResidual_m = zAdd - hAdd;
sigmaPerRow_m = sqrt(diag(RAdd));
assert(all(abs(prefitResidual_m) < 10*sigmaPerRow_m), ...
    'FAIL: prefit residual must be within 10 sigma of the declared measurement noise -- got max|z-h|=%.4f m vs 10*sigma=%s m.', ...
    max(abs(prefitResidual_m)),mat2str(10*sigmaPerRow_m,4));
fprintf('  PASS build(): %d rows, nx=%d, prefit RMS=%.6f m, R symmetric PSD, residual closure within 10 sigma\n', ...
    n, sim.ekf.nx, info.prefitRms_m);
end

% ================================================================================================
function i_test_predictEkfRows_matches_build_row_count_()
[cfg, sim, t_s] = i_groundSpaceFixture_();
[~, hAdd, ~, ~, info] = revgnss.TwoWayTimeTransferBuilder.build( ...
    cfg, sim.errorChain, sim.asset, sim.towers, sim.ekf.getMeasurementState(), sim.ekf.stateMap, ...
    sim.ekf.nx, t_s);
hPred = revgnss.TwoWayTimeTransferBuilder.predictEkfRows( ...
    cfg, sim.asset, sim.towers, sim.ekf.getMeasurementState(), sim.ekf.stateMap, info, t_s);
assert(numel(hPred)==numel(hAdd));
assert(norm(hPred(:)-hAdd(:)) < 1e-9*max(1,norm(hAdd(:))), ...
    'FAIL: predictEkfRows must reproduce build''s own predicted rows at the same state/epoch.');
fprintf('  PASS predictEkfRows reproduces build''s %d predicted rows exactly\n', numel(hAdd));
end

% ================================================================================================
function i_test_validateConfig_rejects_bad_sigma_()
cfg = i_baseGroundSpaceConfig_();
cfg.measurements.twoWayTimeTransfer.fourTimestampPhysical.sigma_m = -1;
threw = false;
try
    revgnss.FourTimestampGroundSpaceTimeTransferBuilder.validateConfig(cfg);
catch
    threw = true;
end
assert(threw,'FAIL: validateConfig must reject a negative sigma_m.');
fprintf('  PASS validateConfig rejects negative sigma_m\n');
end

% ================================================================================================
function i_test_validateConfig_refuses_applyAtmosphere_true_()
% Combined-review M5: applyAtmosphere only ever affects the TRUTH exchange record's own
% declared covariance (never this builder's z/h/H/R -- see
% test_four_timestamp_ground_space_atmosphere_truth_model_separation.m), so validateConfig must
% refuse applyAtmosphere=true outright (invariant 6: a declared-but-inert toggle must fail
% validation, not silently no-op) rather than merely requiring a variance to go with it.
cfg = i_baseGroundSpaceConfig_();
cfg.measurements.twoWayTimeTransfer.fourTimestampPhysical.applyAtmosphere = true;
cfg.measurements.twoWayTimeTransfer.fourTimestampPhysical.atmosphereVariance_s2 = 1e-16;
threw = false;
try
    revgnss.FourTimestampGroundSpaceTimeTransferBuilder.validateConfig(cfg);
catch ME
    threw = strcmp(ME.identifier,'FourTimestampGroundSpaceTimeTransferBuilder:atmosphereNotWired');
end
assert(threw,'FAIL: validateConfig must refuse applyAtmosphere=true (not yet wired into z/h/H/R).');
fprintf('  PASS validateConfig refuses applyAtmosphere=true\n');
end

% ================================================================================================
function i_test_validateConfig_rejects_estimateTowerClocks_true_()
% Combined-review B2: this builder always reads the tower clock as a frozen broadcast product
% (revgnss.FourTimestampEstimatorEndpointBridge.fromTowerBroadcastProduct has no EKF-state
% counterpart), so a config that declares the tower clock IS an EKF state must be refused rather
% than silently read as if it were not.
cfg = i_baseGroundSpaceConfig_();
cfg.estimator.estimateTowerClocks = true;
threw = false;
try
    revgnss.FourTimestampGroundSpaceTimeTransferBuilder.validateConfig(cfg);
catch ME
    threw = strcmp(ME.identifier,'FourTimestampGroundSpaceTimeTransferBuilder:towerClockStateUnsupported');
end
assert(threw,'FAIL: validateConfig must reject estimator.estimateTowerClocks=true.');
fprintf('  PASS validateConfig rejects estimator.estimateTowerClocks=true\n');
end

% ================================================================================================
function i_test_validateConfig_rejects_nonzero_counterTagSigma_()
% Combined-review M4: counterTag.sigma_s only ever feeds the truth exchange record's own
% covarianceBlock, never this builder's Ri -- a nonzero declared value must be refused rather
% than silently discarded.
cfg = i_baseGroundSpaceConfig_();
cfg.measurements.twoWayTimeTransfer.fourTimestampPhysical.counterTag.sigma_s = [1e-9 0 0 0];
threw = false;
try
    revgnss.FourTimestampGroundSpaceTimeTransferBuilder.validateConfig(cfg);
catch ME
    threw = strcmp(ME.identifier,'FourTimestampGroundSpaceTimeTransferBuilder:counterTagNoiseNotWired');
end
assert(threw,'FAIL: validateConfig must reject a nonzero counterTag.sigma_s.');
fprintf('  PASS validateConfig rejects nonzero counterTag.sigma_s\n');
end

% ================================================================================================
function i_test_validateConfig_rejects_nonzero_calibrationSigma_()
% Combined-review M3: calibration.originTerminalSigma_s/anchorTerminalSigma_s (renamed from
% turnaround/terminal -- M2) are not wired into this builder's Ri at all -- a nonzero declared
% value must be refused rather than silently discarded (its truth-side partner,
% truth.*TerminalCalibrationError_s, IS live, so a user relying on the covariance to reflect
% that error would otherwise be silently under-covered).
cfg = i_baseGroundSpaceConfig_();
cfg.measurements.twoWayTimeTransfer.fourTimestampPhysical.calibration.anchorTerminalSigma_s = 1e-9;
threw = false;
try
    revgnss.FourTimestampGroundSpaceTimeTransferBuilder.validateConfig(cfg);
catch ME
    threw = strcmp(ME.identifier, ...
        'FourTimestampGroundSpaceTimeTransferBuilder:persistentCalibrationSigmaUnsupported');
end
assert(threw,'FAIL: validateConfig must reject a nonzero calibration.anchorTerminalSigma_s.');
fprintf('  PASS validateConfig rejects nonzero calibration.anchorTerminalSigma_s\n');
end

% ================================================================================================
function i_test_validateConfig_rejects_includeReciprocityResidual_true_()
% Combined-review m5: includeReciprocityResidual is a legacy-mode-only concept
% (revgnss.ReciprocalTimeTransferModel.evaluate's reciprocity term) that
% revgnss.FourTimestampGroundSpaceTimeTransferBuilder never reads -- the guard lives in the
% DISPATCHER (revgnss.TwoWayTimeTransferBuilder.validateConfig), not the ground-space builder's
% own validateConfig, so this test calls the dispatcher directly.
cfg = i_baseGroundSpaceConfig_();
cfg.measurements.twoWayTimeTransfer.includeReciprocityResidual = true;
threw = false;
try
    revgnss.TwoWayTimeTransferBuilder.validateConfig(cfg);
catch ME
    threw = strcmp(ME.identifier, ...
        'TwoWayTimeTransferBuilder:reciprocityTermUnavailableForFourTimestampMode');
end
assert(threw,'FAIL: validateConfig must reject includeReciprocityResidual=true under mode=fourTimestampClockDifference.');
fprintf('  PASS validateConfig rejects includeReciprocityResidual=true under mode=fourTimestampClockDifference\n');
end

% ================================================================================================
function cfg = i_baseGroundSpaceConfig_()
cfg = masterConfig();
cfg.simulation.duration_s = 4;
cfg.simulation.dt_s = 1;
cfg.report.writePdf = false;
cfg.report.writeMat = false;
cfg.report.compileTex = 'never';
cfg.plots.enable = false;
cfg.plots.showFigures = false;
cfg.measurements.twoWayTimeTransfer.enable = true;
cfg.measurements.twoWayTimeTransfer.useInEKF = true;
cfg.measurements.twoWayTimeTransfer.mode = 'fourTimestampClockDifference';
end

% ================================================================================================
function [cfg, sim, t_s] = i_groundSpaceFixture_()
cfg = i_baseGroundSpaceConfig_();
sim = revgnss.ReverseGNSSSimulation(cfg);
sim.initialize();
sim.advanceTruthEpoch(1);
sim.runLocalEstimationEpoch(1);
t_s = sim.tVec(sim.lastEstimatedEpoch);
end
