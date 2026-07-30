function test_independent_fleet_stage2_reporting()
% test_independent_fleet_stage2_reporting  Plan Section 2.5: real end-to-end proof of the
% distributed-fleet report's per-observable/per-asset accounting (generated/delivered/owner-
% consumed/rejected+reason, remote product age, provenance, correlation policy, calibration/
% covariance groups, and the distributed-result-status vocabulary), driven through the REAL
% revgnss.ReportRunner.runSingle -> IndependentFleetCoordinator -> IndependentFleetDiagnosticReport
% pipeline, not synthetic ledger construction alone.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
addpath(rootDir);
addpath(fullfile(rootDir,'config'));
addpath(fullfile(rootDir,'config','internal'));

fprintf('=== test_independent_fleet_stage2_reporting ===\n');
i_test_end_to_end_report_through_report_runner_();
i_test_forbidden_stage_two_vocabulary_absent_();
i_test_per_observable_and_asset_accounting_is_exact_();
i_test_rejected_records_carry_observable_owner_and_exact_reason_();
i_test_disabled_link_update_path_reports_honestly_();
i_test_ledger_aggregation_contract_();
i_test_stage_three_status_fields_unchanged_();
i_test_federated_swarm_path_untouched_();
fprintf('=== test_independent_fleet_stage2_reporting: ALL PASS ===\n');
end

% ================================================================================================
function i_test_end_to_end_report_through_report_runner_()
cfg = i_sanctionedFleetConfig_('oneWayCode');
cfg.report.writePdf = true;
cfg.report.compileTex = 'never';
out = revgnss.ReportRunner.runSingle(cfg);

assert(strcmp(out.summary.reportStatus,'diagnosticOnlyIndependentFleet'), ...
    'The existing reportStatus vocabulary must stay unchanged.');
assert(strcmp(out.summary.distributedResultStatus,'conservativeDistributedOwnerOnly'));
assert(out.diagnosticReport.success);
assert(out.diagnosticReport.stageTwoSectionEmitted);
assert(out.diagnosticReport.forbiddenTermCheckPassed);

linkAccounting = out.diagnosticReport.linkAccounting;
assert(~isempty(linkAccounting.perObservableAndAsset));
rowIdx = find(strcmp({linkAccounting.perObservableAndAsset.observableIdentifier},'oneWayCode'),1);
assert(~isempty(rowIdx),'A oneWayCode row must be present in the per-observable/per-asset accounting.');
row = linkAccounting.perObservableAndAsset(rowIdx);
assert(row.generatedRecords > 0 && row.ownerConsumedRecords > 0);
assert(row.accountingBalanced,'The generated/delivered/consumed/rejected identities must hold exactly.');

texText = fileread(out.texPath);
mustContain = {'oneWayCode','spacecraft:1','simulationCoordinateTime\_s','ECEF', ...
    'receiverClockBiasStateGauge','endpointStateProduct-v1','estimatorEligible-v1', ...
    'splitCovarianceIntersection'};
for index = 1:numel(mustContain)
    assert(contains(texText,mustContain{index}), ...
        'The rendered report must contain ''%s''.',mustContain{index});
end
fprintf('  PASS end_to_end_report_through_report_runner\n');
end

% ================================================================================================
function i_test_forbidden_stage_two_vocabulary_absent_()
cfg = i_sanctionedFleetConfig_('oneWayCode');
cfg.report.writePdf = true;
cfg.report.compileTex = 'never';
out = revgnss.ReportRunner.runSingle(cfg);
texText = fileread(out.texPath);
revgnss.DistributedFleetReportingContract.requireNoForbiddenStageTwoTerm(texText);

positiveControls = {'a joint solution','Joint EKF','solved formation', ...
    'centralized-equivalent','centralised equivalent'};
for index = 1:numel(positiveControls)
    i_expectError_(@() revgnss.DistributedFleetReportingContract.requireNoForbiddenStageTwoTerm( ...
        positiveControls{index}),'DistributedFleetReportingContract:forbiddenStageTwoTerm');
end
% Word-boundary proof: these must NOT throw.
revgnss.DistributedFleetReportingContract.requireNoForbiddenStageTwoTerm('a disjoint set');
revgnss.DistributedFleetReportingContract.requireNoForbiddenStageTwoTerm('the adjoint operator');
fprintf('  PASS forbidden_stage_two_vocabulary_absent\n');
end

% ================================================================================================
function i_test_per_observable_and_asset_accounting_is_exact_()
observables = {'coherentTwoWayCodeRange','firstOrderReciprocalClockTransfer', ...
    'oneWayCode','oneWayDoppler'};
for obsIdx = 1:numel(observables)
    observable = observables{obsIdx};
    cfg = i_sanctionedFleetConfig_(observable);
    coordinator = revgnss.IndependentFleetCoordinator(cfg);
    coordinator.run();
    results = coordinator.getResults();
    accounting = revgnss.DistributedFleetReportingContract.buildLinkAccounting(results);

    rows = accounting.perObservableAndAsset;
    observableIds = unique({rows.observableIdentifier});
    assert(isscalar(observableIds) && strcmp(observableIds{1},observable), ...
        '(%s) exactly one observableIdentifier must appear, and it must equal the configured one.',observable);

    counters = results.linkObservationCounters;
    assert(sum([rows.generatedRecords]) == counters.generated, ...
        '(%s) sum of per-key generatedRecords must equal the fleet-wide generated counter.',observable);
    assert(sum([rows.ownerConsumedRecords]) == counters.consumedByOwner, ...
        '(%s) sum of per-key ownerConsumedRecords must equal the fleet-wide consumedByOwner counter.',observable);
    assert(sum([rows.ledgerRecords]) == results.linkDelivery.distinctObservations, ...
        '(%s) sum of per-key ledgerRecords must equal the ledger''s own distinctObservations (invariant 9).',observable);
    assert(accounting.generationTallyReconciled, ...
        '(%s) the generation tally must reconcile against the ledger.',observable);
    % Non-vacuous: a canonicalization failure that rejected every record (asset:unattributed on
    % both sides) would still leave generationTallyReconciled=true, so pin the real positive
    % outcome directly -- at least one record actually consumed, filed under the CANONICAL
    % spacecraft:N owner label, not the sentinel or the record's own raw asset:N scheme.
    assert(counters.consumedByOwner > 0, ...
        '(%s) this clean fixture must actually consume at least one record.',observable);
    assert(strcmp(rows(1).ownerAssetIdentifier,'spacecraft:1'), ...
        '(%s) the owner must be canonicalized to spacecraft:1, not asset:1 or asset:unattributed.',observable);
    for rowIdx = 1:numel(rows)
        assert(rows(rowIdx).unitsMatchContract, ...
            '(%s) row %d: processedUnits must match RowUnitsByObservable.',observable,rowIdx);
        expectedUnits = revgnss.DistributedLinkUpdateAdapter.RowUnitsByObservable.(observable);
        assert(strcmp(rows(rowIdx).observableRowUnits,expectedUnits));
    end
end
% Headline proof the shared record class is split by OBSERVABLE, not by physicalRecordClass:
% oneWayCode and oneWayDoppler both back OneWayInterSatelliteObservationRecord, yet their rows
% above were each keyed correctly under their own distinct observableIdentifier with the right
% row units ('m' vs 'm/s').
fprintf('  PASS per_observable_and_asset_accounting_is_exact (4 observables)\n');
end

% ================================================================================================
function i_test_rejected_records_carry_observable_owner_and_exact_reason_()
cfg = i_sanctionedFleetConfig_('oneWayCode');
cfg.multiAsset.distributedEstimator.stateExchange.maximumAge_s = 1; % forces sameEpochScopeViolated
coordinator = revgnss.IndependentFleetCoordinator(cfg);
coordinator.run();
results = coordinator.getResults();
counters = results.linkObservationCounters;
assert(counters.generated > 0 && counters.consumedByOwner == 0);
assert(counters.generated == results.linkDelivery.rejected);

accounting = revgnss.DistributedFleetReportingContract.buildLinkAccounting(results);
rowIdx = find(strcmp({accounting.perObservableAndAsset.observableIdentifier},'oneWayCode'),1);
row = accounting.perObservableAndAsset(rowIdx);
assert(strcmp(row.ownerAssetIdentifier,'spacecraft:1'));
assert(row.rejectedRecords == counters.generated);
assert(row.rejectedBeforeDeliveryRecords == counters.generated);
assert(row.deliveredRecords == 0);
assert(isscalar(row.rejectionReasonCodes) && strcmp(row.rejectionReasonCodes{1},'sameEpochScopeViolated'));
assert(isscalar(row.ownerAttributionSources) && ...
    strcmp(row.ownerAttributionSources{1},'recordDeclaredEndpointLabel'));
assert(strcmp(accounting.distributedResultStatus,'linkUpdateEnabledButNoRecordConsumed'));

ledgerRows = coordinator.deliveryLedger.export();
assert(all(~[ledgerRows.wasDeliveredToOwner]));
assert(all(strcmp({ledgerRows.observableIdentifier},'oneWayCode')));
fprintf('  PASS rejected_records_carry_observable_owner_and_exact_reason\n');
end

% ================================================================================================
function i_test_disabled_link_update_path_reports_honestly_()
cfg = i_stage1FleetConfig_();
cfg.report.writePdf = true;
cfg.report.compileTex = 'never';
out = revgnss.ReportRunner.runSingle(cfg);

assert(strcmp(out.summary.distributedResultStatus,'diagnosticOnlyNoLinkUpdate'));
accounting = out.diagnosticReport.linkAccounting;
assert(~accounting.deliveryLedgerEnabled);
assert(isempty(accounting.perObservableAndAsset));
assert(isequal(out.fleetResults.linkDelivery,revgnss.DistributedDeliveryLedger.emptySummary()));
assert(isequaln(out.fleetResults.linkObservationCounters, ...
    struct('generated',0,'delivered',0,'consumedByOwner',0)));

texText = fileread(out.texPath);
assert(contains(texText,'ledger is disabled') || contains(texText,'unavailable'));
fprintf('  PASS disabled_link_update_path_reports_honestly\n');
end

% ================================================================================================
function i_test_ledger_aggregation_contract_()
ledger = revgnss.DistributedDeliveryLedger();
empty = ledger.summaryByObservableAndOwner();
assert(isequal(fieldnames(empty),fieldnames(revgnss.DistributedDeliveryLedger.emptyObservableOwnerSummary())));
assert(isequal(fieldnames(ledger.summary()),fieldnames(revgnss.DistributedDeliveryLedger.emptySummary())), ...
    'summary()/emptySummary() must stay byte-identical to their pre-Section-2.5 field set.');

rec = i_syntheticRejectionRecord_();
rec2 = rec; rec2.observationIdentifier = 'obs:second'; rec2.reasonCode = 'anotherReason';
ledger.recordRejected(rec);
ledger.recordRejected(rec2);
rows = ledger.export();
assert(all([rows.wasDeliveredToOwner] == false));
groups = ledger.summaryByObservableAndOwner();
assert(isscalar(groups));
assert(numel(groups.rejectionReasonCodes) == 2, ...
    'Distinct raw reason codes must not be collapsed into one bucket.');

badMissing = rmfield(rec,'observableIdentifier');
i_expectError_(@() ledger.recordRejected(badMissing),'DistributedDeliveryLedger:reasonCode');
badAttribution = rec; badAttribution.observationIdentifier = 'obs:third';
badAttribution.ownerAttributionSource = 'notARealSource';
i_expectError_(@() ledger.recordRejected(badAttribution),'DistributedDeliveryLedger:reasonCode');
fprintf('  PASS ledger_aggregation_contract\n');
end

% ================================================================================================
function i_test_stage_three_status_fields_unchanged_()
cfg = i_sanctionedFleetConfig_('oneWayCode');
coordinator = revgnss.IndependentFleetCoordinator(cfg);
coordinator.run();
summary = coordinator.runtimeSummary();
assert(strcmp(summary.relativeEstimatorStatus,'notImplementedInStage1'));
assert(strcmp(summary.linkFusionStatus,'notImplementedInStage1'));
fprintf('  PASS stage_three_status_fields_unchanged\n');
end

% ================================================================================================
function i_test_federated_swarm_path_untouched_()
cfg = masterConfig();
cfg.simulation.duration_s = 3; cfg.simulation.dt_s = 1;
cfg.report.writePdf = false; cfg.report.writeMat = false; cfg.report.compileTex = 'never';
cfg.plots.enable = false; cfg.plots.showFigures = false;
cfg.scenario.nSpaceAssets = 2;
cfg.multiAsset.mode = 'fast';
cfg.multiAsset.distributedEstimator.enable = false;
out = revgnss.ReportRunner.runSingle(cfg);
assert(isfield(out,'rel'),'A federated-swarm run must still route through runFederatedSwarm_.');
fprintf('  PASS federated_swarm_path_untouched\n');
end

% ================================================================================================
function out = i_expectError_(fn, expectedIdentifier)
out = [];
try
    fn();
    error('test_independent_fleet_stage2_reporting:missingError', ...
        'Expected %s was not raised.',expectedIdentifier);
catch ME
    if ~isempty(expectedIdentifier)
        assert(strcmp(ME.identifier,expectedIdentifier), ...
            'Expected %s, received %s (%s).',expectedIdentifier,ME.identifier,ME.message);
    end
end
end

function rec = i_syntheticRejectionRecord_()
rec = struct( ...
    'observationIdentifier','obs:first','ownerAssetIdentifier','spacecraft:1', ...
    'remoteAssetIdentifier','spacecraft:2','remoteProductIdentifier','', ...
    'sourceEpoch_s',1,'deliveryEpoch_s',1,'reasonCode','someReason', ...
    'reasonMessage','synthetic','sourceErrorIdentifier','test:synthetic', ...
    'physicalRecordClass','revgnss.OneWayInterSatelliteObservationRecord', ...
    'observableIdentifier','oneWayCode','processedObservableType','oneWayCodeRange', ...
    'processedUnits','m','ownerAttributionSource','recordDeclaredEndpointLabel');
end

% ================================================================================================
function cfg = i_sanctionedFleetConfig_(observable)
cfg = masterConfig();
cfg.simulation.duration_s = 5;
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
cfg.multiAsset.distributedEstimator.linkUpdate.updateAdapter.observable = observable;

switch observable
    case 'coherentTwoWayCodeRange'
        cfg.measurements.isl.enable = true;
        cfg.measurements.isl.twoWay.enable = true;
        cfg.measurements.isl.twoWay.range.enable = true;
    case 'firstOrderReciprocalClockTransfer'
        cfg.measurements.isl.enable = true;
        cfg.measurements.isl.twoWay.enable = true;
        cfg.measurements.isl.twoWay.timeTransfer.enable = true;
    case 'oneWayCode'
        cfg.measurements.isl.enable = true;
        cfg.measurements.isl.oneWay.enable = true;
        cfg.measurements.isl.oneWay.code.enable = true;
    case 'oneWayDoppler'
        cfg.measurements.isl.enable = true;
        cfg.measurements.isl.oneWay.enable = true;
        cfg.measurements.isl.oneWay.doppler.enable = true;
end
end

function cfg = i_stage1FleetConfig_()
cfg = masterConfig();
cfg.simulation.duration_s = 3;
cfg.simulation.dt_s = 1;
cfg.report.writePdf = false;
cfg.report.writeMat = false;
cfg.report.compileTex = 'never';
cfg.plots.enable = false;
cfg.plots.showFigures = false;
cfg.scenario.nSpaceAssets = 2;
cfg.multiAsset.distributedEstimator.enable = true;
cfg.multiAsset.distributedEstimator.stateExchange.enable = false;
cfg.multiAsset.distributedEstimator.deliveryLedger.enable = false;
cfg.multiAsset.distributedEstimator.linkUpdate.enable = false;
cfg.multiAsset.distributedEstimator.linkUpdate.ownerPolicy = 'disabled';
cfg.multiAsset.distributedEstimator.linkUpdate.correlationPolicy = 'disabled';
cfg.multiAsset.distributedEstimator.linkUpdate.updateAdapter.observable = 'none';
end
