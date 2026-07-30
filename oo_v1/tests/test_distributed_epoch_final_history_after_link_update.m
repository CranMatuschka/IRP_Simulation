function test_distributed_epoch_final_history_after_link_update()
% test_distributed_epoch_final_history_after_link_update  Deferred local-history commit.
%
% Closes the Section 2.0/2.1 commit-ordering blocker: IndependentFleetCoordinator now
% commits each local estimator's history/report row AFTER the distributed epoch
% finalization phases (publish products -> deliver link records -> owner-only link
% update), so a future owner-only update would be described by the SAME epoch's row
% instead of mutating state behind an already-written one.
%
% Proves, in order:
%   1. split (runLocalEstimationEpochWithoutHistoryCommit + commitPendingEpochHistory)
%      is byte-identical to the unchanged inline runLocalEstimationEpoch;
%   2. the commit guards reject an absent, repeated, or abandoned staged epoch;
%   3. a state change applied between the split and the commit IS carried by that
%      epoch's committed row and history entry (the hazard actually being closed),
%      while the same change applied after an inline commit is NOT;
%   4. a full coordinator run in the new deferred order equals the same run driven in
%      the pre-fix inline order, since phases 4-5 remain no-ops.
%
% This enables nothing: linkUpdate.enable stays unconditionally rejected, no adapter
% exists, and no new configuration key is introduced.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
addpath(rootDir);
addpath(fullfile(rootDir,'config'));
addpath(fullfile(rootDir,'config','internal'));

fprintf('=== test_distributed_epoch_final_history_after_link_update ===\n');
i_splitCommitMatchesInlineCommit_();
i_commitGuardsRejectMisuse_();
i_deferredRowDescribesPostPhaseState_();
i_coordinatorDeferredOrderMatchesLegacyOrder_();
fprintf('=== test_distributed_epoch_final_history_after_link_update: ALL PASS ===\n');
end

% ================================================================================================
function i_splitCommitMatchesInlineCommit_()
cfg = i_baseConfig_();
inlineSim = revgnss.ReverseGNSSSimulation(cfg);
splitSim = revgnss.ReverseGNSSSimulation(cfg);
evalc('inlineSim.initialize(); splitSim.initialize();');
assert(~inlineSim.hasPendingEpochHistory() && ~splitSim.hasPendingEpochHistory(), ...
    'A freshly initialized simulation must have no staged epoch history.');

for epochIndex = 1:inlineSim.nEpochs
    evalc(['inlineSim.advanceTruthEpoch(epochIndex); ' ...
        'inlineSim.runLocalEstimationEpoch(epochIndex);']);
    assert(~inlineSim.hasPendingEpochHistory(), ...
        'The inline entry point must commit its epoch row before returning.');
    evalc(['splitSim.advanceTruthEpoch(epochIndex); ' ...
        'splitSim.runLocalEstimationEpochWithoutHistoryCommit(epochIndex);']);
    assert(splitSim.hasPendingEpochHistory(), ...
        'The deferred entry point must stage exactly one uncommitted epoch row.');
    assert(splitSim.lastEstimatedEpoch == epochIndex, ...
        ['lastEstimatedEpoch must NOT be deferred: product publication depends on it ' ...
         'being current at the phase-3 position.']);
    splitSim.commitPendingEpochHistory();
    assert(~splitSim.hasPendingEpochHistory(), ...
        'commitPendingEpochHistory must clear the staged epoch row.');
end
evalc('inlineSim.finishRun(false); splitSim.finishRun(false);');

assert(isequaln(inlineSim.ekf.x,splitSim.ekf.x) && ...
    isequaln(inlineSim.ekf.P,splitSim.ekf.P) && ...
    isequaln(inlineSim.ekf.history,splitSim.ekf.history), ...
    'Splitting the history commit changed the local EKF state, covariance, or history.');
assert(isequaln(inlineSim.simData.getData(),splitSim.simData.getData()) && ...
    isequaln(inlineSim.simData.getMeta(),splitSim.simData.getMeta()) && ...
    isequaln(inlineSim.simData.getNumMeasurementRows(), ...
    splitSim.simData.getNumMeasurementRows()), ...
    'Splitting the history commit changed the canonical database contents.');
end

% ================================================================================================
function i_commitGuardsRejectMisuse_()
cfg = i_baseConfig_();

% (a) Nothing staged.
sim = revgnss.ReverseGNSSSimulation(cfg);
evalc('sim.initialize();');
i_expectError_(@() sim.commitPendingEpochHistory(), ...
    'ReverseGNSSSimulation:noPendingEpochCommit');

% (b) Committed twice without an intervening estimation epoch.
evalc(['sim.advanceTruthEpoch(1); ' ...
    'sim.runLocalEstimationEpochWithoutHistoryCommit(1);']);
sim.commitPendingEpochHistory();
i_expectError_(@() sim.commitPendingEpochHistory(), ...
    'ReverseGNSSSimulation:noPendingEpochCommit');

% (c) Next epoch estimated while the previous row is still staged.
abandoned = revgnss.ReverseGNSSSimulation(cfg);
evalc('abandoned.initialize();');
evalc(['abandoned.advanceTruthEpoch(1); ' ...
    'abandoned.runLocalEstimationEpochWithoutHistoryCommit(1);']);
evalc('abandoned.advanceTruthEpoch(2);');
i_expectError_(@() abandoned.runLocalEstimationEpochWithoutHistoryCommit(2), ...
    'ReverseGNSSSimulation:uncommittedEpochHistory');
i_expectError_(@() abandoned.runLocalEstimationEpoch(2), ...
    'ReverseGNSSSimulation:uncommittedEpochHistory');

% (d) Finalized while the last row is still staged: loud, never a silently dropped epoch.
tail = revgnss.ReverseGNSSSimulation(cfg);
evalc('tail.initialize();');
for epochIndex = 1:tail.nEpochs-1
    evalc(['tail.advanceTruthEpoch(epochIndex); ' ...
        'tail.runLocalEstimationEpoch(epochIndex);']);
end
evalc(['tail.advanceTruthEpoch(tail.nEpochs); ' ...
    'tail.runLocalEstimationEpochWithoutHistoryCommit(tail.nEpochs);']);
i_expectError_(@() tail.finishRun(false), ...
    'ReverseGNSSSimulation:uncommittedEpochHistory');
tail.commitPendingEpochHistory();
evalc('tail.finishRun(false);');
assert(tail.runComplete,'A committed final epoch must still finalize normally.');
end

% ================================================================================================
function i_deferredRowDescribesPostPhaseState_()
% Stand-in for a future owner-only link update: an explicit state change applied at the
% phase-5 position. No production code performs this; the test applies it directly to an
% in-memory EKF to demonstrate WHICH epoch row describes it.
cfg = i_baseConfig_();
positionChange_m = 137.0;

inlineSim = revgnss.ReverseGNSSSimulation(cfg);
deferredSim = revgnss.ReverseGNSSSimulation(cfg);
evalc('inlineSim.initialize(); deferredSim.initialize();');
positionIndex = inlineSim.ekf.stateMap.r_idx(1);

for epochIndex = 1:inlineSim.nEpochs
    % Pre-fix order: commit, then the phase-5 state change.
    evalc(['inlineSim.advanceTruthEpoch(epochIndex); ' ...
        'inlineSim.runLocalEstimationEpoch(epochIndex);']);
    inlineSim.ekf.x(positionIndex) = inlineSim.ekf.x(positionIndex) + positionChange_m;

    % New order: the same state change at the same point in the epoch, then commit.
    evalc(['deferredSim.advanceTruthEpoch(epochIndex); ' ...
        'deferredSim.runLocalEstimationEpochWithoutHistoryCommit(epochIndex);']);
    deferredSim.ekf.x(positionIndex) = deferredSim.ekf.x(positionIndex) + positionChange_m;
    deferredSim.commitPendingEpochHistory();
end
evalc('inlineSim.finishRun(false); deferredSim.finishRun(false);');

assert(isequaln(inlineSim.ekf.x,deferredSim.ekf.x) && ...
    isequaln(inlineSim.ekf.P,deferredSim.ekf.P), ...
    ['Both orders must apply the identical state change at the identical point; only the ' ...
     'commit instant may differ.']);

inlineData = inlineSim.simData.getData();
deferredData = deferredSim.simData.getData();
recordedInline = inlineData.estimate.r_cm_ecef_m;
recordedDeferred = deferredData.estimate.r_cm_ecef_m;
inlinePositions = inlineSim.ekf.history.x(inlineSim.ekf.stateMap.r_idx,:);
deferredPositions = deferredSim.ekf.history.x(deferredSim.ekf.stateMap.r_idx,:);
positionRow = find(inlineSim.ekf.stateMap.r_idx == positionIndex,1);
assert(isequaln(recordedDeferred,deferredPositions), ...
    'The deferred committed row must be the post-phase state the EKF actually holds.');
assert(isequaln(recordedInline,inlinePositions), ...
    'The inline committed row must remain the state held at its own commit instant.');
assert(all(abs((recordedDeferred(positionRow,:)-recordedInline(positionRow,:)) - ...
    positionChange_m) < 1e-6), ...
    ['A phase-5 state change must appear in THIS epoch''s committed row under the new ' ...
     'order and be absent from it under the pre-fix order.']);

% The EKF's own history entry (position error, and therefore the NEES row) follows the
% same commit instant as the database row.
expectedDeferred = vecnorm(deferredPositions - deferredData.truth.r_cm_ecef_m);
expectedInline = vecnorm(inlinePositions - inlineData.truth.r_cm_ecef_m);
assert(max(abs(deferredSim.ekf.history.posErrNorm_m(:).' - expectedDeferred)) < 1e-9 && ...
    max(abs(inlineSim.ekf.history.posErrNorm_m(:).' - expectedInline)) < 1e-9, ...
    'Each history position-error entry must match the state committed at that instant.');
assert(~isequaln(deferredSim.ekf.history.posErrNorm_m, ...
    inlineSim.ekf.history.posErrNorm_m), ...
    'The two commit instants must be distinguishable in the recorded history.');
end

% ================================================================================================
function i_coordinatorDeferredOrderMatchesLegacyOrder_()
cfg = i_fleetConfig_(3);
cfg.multiAsset.distributedEstimator.stateExchange.enable = true;
cfg.multiAsset.distributedEstimator.stateExchange.maximumAge_s = 0;
cfg.multiAsset.distributedEstimator.stateExchange.deliveryDelay_s = 1;

deferred = revgnss.IndependentFleetCoordinator(cfg);
evalc('deferred.initialize(); deferred.run();');

% The same fleet driven with the pre-fix call sequence: local history committed inline,
% before the product-publication phase. Phases 4-5 are unreachable no-ops in both orders
% (validateConfig rejects linkUpdate.enable), so the two must agree exactly.
legacy = revgnss.IndependentFleetCoordinator(cfg);
evalc('legacy.initialize();');
settings = revgnss.IndependentFleetCoordinator.settingsFromConfig(legacy.cfg);
for epochIndex = 1:numel(legacy.tVec)
    for assetIndex = 1:legacy.nAssets
        evalc('legacy.localSimulations{assetIndex}.advanceTruthEpoch(epochIndex);');
    end
    for assetIndex = 1:legacy.nAssets
        evalc('legacy.localSimulations{assetIndex}.runLocalEstimationEpoch(epochIndex);');
    end
    sourceEpoch_s = legacy.tVec(epochIndex);
    for assetIndex = 1:legacy.nAssets
        sequenceIdentifier = sprintf('spacecraft:%d:epoch:%09d',assetIndex,epochIndex);
        product = revgnss.EndpointStateProduct.fromLocalEstimator( ...
            legacy.localSimulations{assetIndex},assetIndex,sourceEpoch_s, ...
            settings.stateExchange.deliveryDelay_s,sequenceIdentifier);
        legacy.exchangeJournal.record(product,sourceEpoch_s);
    end
    legacy.exchangeJournal.advanceToEpoch(legacy.tVec(epochIndex), ...
        settings.stateExchange.maximumAge_s);
end
for assetIndex = 1:legacy.nAssets
    evalc('legacy.localSimulations{assetIndex}.finishRun(false);');
end
legacy.isComplete = true;

assert(isequaln(legacy.getResults(),deferred.getResults()), ...
    'Deferring the local history commit past phases 3-5 changed the fleet results.');
assert(isequaln(legacy.runtimeSummary(),deferred.runtimeSummary()) && ...
    isequaln(legacy.exchangeJournal.export(),deferred.exchangeJournal.export()) && ...
    isequaln(legacy.exchangeJournal.summary(),deferred.exchangeJournal.summary()), ...
    'Deferring the local history commit changed the state-exchange journal.');
for assetIndex = 1:legacy.nAssets
    legacySim = legacy.localSimulations{assetIndex};
    deferredSim = deferred.localSimulations{assetIndex};
    assert(isequaln(legacySim.ekf.x,deferredSim.ekf.x) && ...
        isequaln(legacySim.ekf.P,deferredSim.ekf.P) && ...
        isequaln(legacySim.ekf.history,deferredSim.ekf.history) && ...
        isequaln(legacySim.simData.getData(),deferredSim.simData.getData()), ...
        'Deferring the local history commit changed a local estimator record.');
    assert(~deferredSim.hasPendingEpochHistory(), ...
        'A completed fleet run must leave no staged epoch row behind.');
end
end

% ================================================================================================
% Fixtures and helpers
% ================================================================================================

function cfg = i_baseConfig_()
cfg = masterConfig();
cfg.simulation.duration_s = 4;
cfg.simulation.dt_s = 1;
cfg.report.writePdf = false;
cfg.report.writeMat = false;
cfg.report.compileTex = 'never';
cfg.plots.enable = false;
cfg.plots.showFigures = false;
end

function cfg = i_fleetConfig_(nAssets)
cfg = i_baseConfig_();
cfg.scenario.nSpaceAssets = nAssets;
cfg.multiAsset.mode = 'fast';
cfg.multiAsset.estimateMode = 'off';
cfg.multiAsset.keepIslInPerAssetEkf = false;
cfg.multiAsset.towersObserveSecondaries = false;
cfg.multiAsset.distributedEstimator.enable = true;
cfg.multiAsset.distributedEstimator.stateExchange.enable = false;
cfg.multiAsset.distributedEstimator.linkUpdate.enable = false;
cfg.measurements.isl.enable = false;
cfg.measurements.isl.code.enable = false;
cfg.measurements.isl.code.useInEKF = false;
cfg.measurements.isl.doppler.enable = false;
cfg.measurements.isl.doppler.useInEKF = false;
cfg.measurements.isl.carrier.enable = false;
cfg.measurements.isl.carrier.useInEKF = false;
cfg.measurements.isl.timing.enable = false;
cfg.measurements.isl.twoWay.enable = false;
cfg.measurements.isl.twoWay.range.enable = false;
cfg.measurements.isl.twoWay.range.useInEKF = false;
cfg.measurements.isl.twoWay.doppler.enable = false;
cfg.measurements.isl.twoWay.doppler.useInEKF = false;
cfg.measurements.isl.twoWay.timeTransfer.enable = false;
cfg.measurements.isl.twoWay.timeTransfer.useInEKF = false;
end

function i_expectError_(action,identifier)
try
    action();
catch ME
    assert(strcmp(ME.identifier,identifier), ...
        'Expected %s, received %s.',identifier,ME.identifier);
    return
end
error('test_distributed_epoch_final_history_after_link_update:missingError', ...
    'Expected error %s was not raised.',identifier);
end
