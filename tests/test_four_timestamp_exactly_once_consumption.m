function test_four_timestamp_exactly_once_consumption()
% test_four_timestamp_exactly_once_consumption  Plan Section 4.4, Stage-4 named test (previously
% deferred until Section 4.4 in the plan doc).
%
% REAL BUG FOUND AND FIXED DURING THIS STAGE: revgnss.ObservationConsumptionLedger.validateInput_
% had a hardcoded 3-class allow-list (InterSatelliteObservationRecord,
% InterSatelliteTimeTransferObservationRecord, OneWayInterSatelliteObservationRecord) that did NOT
% include the new revgnss.InterSatelliteFourTimestampObservationRecord -- a 4th, previously-
% unidentified allow-list gap (matching this project's known recurring bug pattern: every new
% observation-record class requires updating several independent allow-lists, and at least one is
% always missed by the design). This defect meant every fourTimestampClockDifference update
% THREW inside revgnss.IndependentFleetCoordinator.applyOwnerOnlyLinkUpdate_'s try block (after
% revgnss.DistributedDeliveryLedger.recordConsumed had already succeeded), and the resulting
% catch-handler call to recordRejectedFromEligible then ITSELF threw ("not in the eligible state
% (state=consumed)"), masking the real error. Caught only by running the full coordinator
% end-to-end with real MATLAB execution, not by reading the design or any single-class unit test.
% Fixed by adding the new record class to the ledger's allow-list.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
addpath(rootDir);
addpath(fullfile(rootDir,'config'));
addpath(fullfile(rootDir,'config','internal'));

fprintf('=== test_four_timestamp_exactly_once_consumption ===\n');
i_test_ledger_accepts_four_timestamp_record_type_();
i_test_ledger_refuses_duplicate_markEligible_();
i_test_ledger_refuses_duplicate_consume_();
i_test_ledger_refuses_consume_without_eligible_();
i_test_ledger_refuses_consume_at_wrong_epoch_();
i_test_coordinator_multi_epoch_run_consumes_each_observation_exactly_once_();
fprintf('=== test_four_timestamp_exactly_once_consumption: ALL PASS ===\n');
end

% ================================================================================================
function i_test_ledger_accepts_four_timestamp_record_type_()
ledger = revgnss.ObservationConsumptionLedger();
obs = i_minimalFourTimestampRecord_('obs:exactly-once:1');
ledger.markEligible(obs,10);
assert(ledger.numberEligible()==1);
ledger.consume(obs,10);
assert(ledger.numberConsumed()==1);
fprintf('  PASS ledger accepts InterSatelliteFourTimestampObservationRecord (the fixed allow-list gap)\n');
end

% ================================================================================================
function i_test_ledger_refuses_duplicate_markEligible_()
ledger = revgnss.ObservationConsumptionLedger();
obs = i_minimalFourTimestampRecord_('obs:exactly-once:2');
ledger.markEligible(obs,10);
threw = false;
try
    ledger.markEligible(obs,10);
catch ME
    threw = strcmp(ME.identifier,'ObservationConsumptionLedger:duplicateObservation');
end
assert(threw,'FAIL: a second markEligible for the same observation must be refused.');
fprintf('  PASS duplicate markEligible refused\n');
end

% ================================================================================================
function i_test_ledger_refuses_duplicate_consume_()
ledger = revgnss.ObservationConsumptionLedger();
obs = i_minimalFourTimestampRecord_('obs:exactly-once:3');
ledger.markEligible(obs,10);
ledger.consume(obs,10);
threw = false;
try
    ledger.consume(obs,10);
catch ME
    threw = strcmp(ME.identifier,'ObservationConsumptionLedger:duplicateObservation');
end
assert(threw,'FAIL: a second consume for the same observation must be refused -- this IS the exactly-once guarantee.');
fprintf('  PASS duplicate consume refused (the exactly-once guarantee itself)\n');
end

% ================================================================================================
function i_test_ledger_refuses_consume_without_eligible_()
ledger = revgnss.ObservationConsumptionLedger();
obs = i_minimalFourTimestampRecord_('obs:exactly-once:4');
threw = false;
try
    ledger.consume(obs,10);
catch ME
    threw = strcmp(ME.identifier,'ObservationConsumptionLedger:notEligible');
end
assert(threw,'FAIL: consuming a never-eligible observation must be refused.');
fprintf('  PASS consume without a prior markEligible refused\n');
end

% ================================================================================================
function i_test_ledger_refuses_consume_at_wrong_epoch_()
ledger = revgnss.ObservationConsumptionLedger();
obs = i_minimalFourTimestampRecord_('obs:exactly-once:5');
ledger.markEligible(obs,10);
threw = false;
try
    ledger.consume(obs,11);
catch ME
    threw = strcmp(ME.identifier,'ObservationConsumptionLedger:epochMismatch');
end
assert(threw,'FAIL: consuming at a different epoch than markEligible must be refused.');
fprintf('  PASS consume at a mismatched epoch refused\n');
end

% ================================================================================================
function i_test_coordinator_multi_epoch_run_consumes_each_observation_exactly_once_()
% Integration-level proof: over several epochs, the real coordinator path (which is what
% surfaced the original bug) must generate/deliver/consume the SAME count each epoch, with no
% double-count and no dropped epoch.
cfg = i_sanctionedFleetConfig_(8);
coordinator = revgnss.IndependentFleetCoordinator(cfg);
coordinator.run();
nEpochs = numel(coordinator.tVec);
results = coordinator.getResults();
assert(results.complete);
counters = results.linkObservationCounters;
assert(counters.generated==nEpochs, ...
    'FAIL: expected exactly %d generated observations (1 link x %d epochs), got %d.', ...
    nEpochs,nEpochs,counters.generated);
assert(counters.delivered==nEpochs && counters.consumedByOwner==nEpochs, ...
    'FAIL: every one of the %d generated observations must be delivered and consumed exactly once.',nEpochs);
ledgerSummary = results.linkDelivery;
assert(ledgerSummary.consumed==nEpochs && ledgerSummary.rejected==0, ...
    'FAIL: the fleet-wide ledger must show exactly %d consumed and 0 rejected.',nEpochs);
ownerLedger = coordinator.localSimulations{1}.observationLedger;
assert(ownerLedger.numberConsumed()==nEpochs, ...
    'FAIL: the owner leaf''s own local ObservationConsumptionLedger must independently agree: %d consumed.',nEpochs);
fprintf('  PASS %d-epoch coordinator run: generated=delivered=consumedByOwner=%d, no double-count, no drop\n', ...
    nEpochs,nEpochs);
end

% ================================================================================================
function obs = i_minimalFourTimestampRecord_(observationIdentifier)
fields = struct( ...
    'observationIdentifier',observationIdentifier,'sessionIdentifier','sess:1','linkIdentifier','link:1', ...
    'referenceAssetIdentifier','asset:1','remoteAssetIdentifier','asset:2', ...
    'referenceTransmitTerminalIdentifier','a','referenceReceiveTerminalIdentifier','b', ...
    'referenceTransmitAntennaIdentifier','c','referenceReceiveAntennaIdentifier','d', ...
    'remoteTransmitTerminalIdentifier','e','remoteReceiveTerminalIdentifier','f', ...
    'remoteTransmitAntennaIdentifier','g','remoteReceiveAntennaIdentifier','h', ...
    'protocolIdentifier','directFourTimestampTwoWay','modeIdentifier','fourTimestampClockDifference', ...
    'signalIdentifier','sig','channelIdentifier','chan','referenceEpoch_s',10, ...
    'referenceEpochRule','finalReception','rawTimestampTagsAvailable',true, ...
    'timestampTags_s',[1 2 3 10],'processedObservableType','fourTimestampClockDifference', ...
    'processedValue',5.0,'processedUnits','m','covarianceGroupIdentifier','cg:1', ...
    'covarianceRowIndex',1,'covarianceBlock',0.01,'covarianceUnits','m^2', ...
    'calibrationProductIdentifiers',{{}},'available',true,'qualityFlags',struct(), ...
    'truthDiagnosticIdentifier','','referenceLocalClockTag_s',10, ...
    'calibrationValidFromLocalTag_s',10,'calibrationValidUntilLocalTag_s',10, ...
    'reciprocityTermIncluded',false);
obs = revgnss.InterSatelliteFourTimestampObservationRecord(fields);
end

% ================================================================================================
function cfg = i_sanctionedFleetConfig_(duration_s)
cfg = masterConfig();
cfg.simulation.duration_s = duration_s;
cfg.simulation.dt_s = 1;
cfg.report.writePdf = false;
cfg.report.writeMat = false;
cfg.report.compileTex = 'never';
cfg.plots.enable = false;
cfg.plots.showFigures = false;

cfg.scenario.nSpaceAssets = 2;
cfg.multiAsset.mode = 'fast';
cfg.multiAsset.estimateMode = 'off';
cfg.multiAsset.keepIslInPerAssetEkf = false;
cfg.multiAsset.towersObserveSecondaries = false;

cfg.multiAsset.distributedEstimator.enable = true;
cfg.multiAsset.distributedEstimator.stateExchange.enable = false;
cfg.multiAsset.distributedEstimator.deliveryLedger.enable = true;
cfg.multiAsset.distributedEstimator.linkUpdate.enable = true;
cfg.multiAsset.distributedEstimator.linkUpdate.ownerPolicy = 'initiator';
cfg.multiAsset.distributedEstimator.linkUpdate.correlationPolicy = 'splitCovarianceIntersection';
cfg.multiAsset.distributedEstimator.linkUpdate.updateAdapter.observable = 'fourTimestampClockDifference';

cfg.measurements.isl.enable = true;
cfg.measurements.isl.twoWay.enable = true;
cfg.measurements.isl.twoWay.links = struct( ...
    'enable',true,'linkIdentifier','isl-link-1-2','initiatorAssetIndex',1,'transponderAssetIndex',2, ...
    'signalIdentifier','ISL-PN','channelIdentifier','PN-1', ...
    'schedule',struct('updatePhase_s',0,'commandIdentifier','scenario-open-loop'), ...
    'turnaroundCalibrationError_s',0,'terminalCalibrationError_s',0, ...
    'physicalChainIdentifier','isl-two-way-code-chain', ...
    'calibrationProductIdentifier','isl-two-way-code-calibration');
cfg.measurements.isl.twoWay.schedule.updatePeriod_s = 1;
cfg.measurements.isl.twoWay.schedule.start_s = 0;
cfg.measurements.isl.twoWay.schedule.stop_s = 1e6;
end
