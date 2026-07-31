function test_session_timing_product_no_persistent_state()
% test_session_timing_product_no_persistent_state  Plan Stage 3.3, commonSourceTreatment.
% sessionTimingProduct: a characterization TRIPWIRE, not a feature test. Section 3.3's own
% design synthesis found no session-persistent state to close off -- unlike models.clocks.
% TowerClockCorrectionProvider.productNoise_, whose correction residual is a DETERMINISTIC
% function of (towerIndex,productEpoch) alone -- identical for every real consumer of that pair,
% not merely cached (the real gap behind revgnss.IndependentFleetCoordinator's
% towerClockProductReachableButRejected error) -- revgnss.InterSatelliteTimeTransferBuilder draws
% its noise through a fresh, per-call RandStream keyed by (referenceIndex,remoteIndex,epochIndex)
% with no `persistent` MATLAB state, and never reuses a sessionIdentifier across epochs.
% commonSourceTreatment.sessionTimingProduct='rejected' is therefore an honest "nothing to
% treat," not a placeholder. This test's only job is to fail loudly the day someone adds
% session-persistent state without updating this entry.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
addpath(rootDir);
addpath(fullfile(rootDir,'config'));
addpath(fullfile(rootDir,'config','internal'));

fprintf('=== test_session_timing_product_no_persistent_state ===\n');
i_test_no_persistent_noise_cache_across_epochs_();
fprintf('=== test_session_timing_product_no_persistent_state: ALL PASS ===\n');
end

% ================================================================================================
function i_test_no_persistent_noise_cache_across_epochs_()
cfg = resolveSimulationConfig('joint_G5S2R4_reciprocal_time_transfer.json');
cfg.simulation.duration_s = 1;
cfg.estimator.minMeasurementsForUpdate = 1;
simulation = revgnss.ReverseGNSSSimulation(cfg);
simulation.initialize();

% Same static truth (assets never advanced between calls) at two DIFFERENT epochs: any
% difference in the recorded value must come from the noise draw's epoch dependence, not from
% truth motion, isolating exactly the property a persistent asset-blind cache (like tower
% clock's) would violate.
[obsAt0,~,~] = revgnss.InterSatelliteTimeTransferBuilder.generateObservations( ...
    simulation.cfg,simulation.assets,0);
[obsAt10,~,~] = revgnss.InterSatelliteTimeTransferBuilder.generateObservations( ...
    simulation.cfg,simulation.assets,10);
assert(isscalar(obsAt0) && isscalar(obsAt10),'expected exactly one time-transfer record per call');
recAt0 = obsAt0{1};
recAt10 = obsAt10{1};

assert(~strcmp(recAt0.sessionIdentifier,recAt10.sessionIdentifier), ...
    'sessionIdentifier must not repeat across different epochs (no session-persistent state)');
assert(recAt0.processedValue ~= recAt10.processedValue, ...
    ['the recorded value must differ across epochs with static truth: a shared/cached noise ' ...
    'draw (the tower-clock-product failure mode) would make it identical']);

% Same epoch, called twice: reproducible (a pure function of its inputs, not accumulating
% MATLAB session state across calls -- the ABSENCE of a persistent cache, confirmed positively
% rather than merely inferred from the epoch-to-epoch difference above).
[obsAt0Again,~,~] = revgnss.InterSatelliteTimeTransferBuilder.generateObservations( ...
    simulation.cfg,simulation.assets,0);
recAt0Again = obsAt0Again{1};
assert(recAt0.processedValue == recAt0Again.processedValue, ...
    'the SAME epoch with unchanged truth must reproduce the identical value (deterministic, no call-order state)');
fprintf('  PASS: no session-persistent noise cache -- epoch-to-epoch differs, same-epoch is reproducible, sessionIdentifier never repeats\n');
end
