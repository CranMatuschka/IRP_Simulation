function test_distributed_time_transfer_local_clock_sign_and_units()
% test_distributed_time_transfer_local_clock_sign_and_units  Plan-named Stage-2 test (was
% missing before Section 2.4). Cross-checks revgnss.DistributedClockGaugeContract's sign/
% common-mode-blindness/rank certificate against revgnss.ReciprocalTimeTransferModel's own
% independently-derived partials (referenceClockPartial=-1, remoteClockPartial=+1), NOT against
% the certificate's own internal logic -- an independent oracle, not a self-check.

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir,'..'));

fprintf('=== test_distributed_time_transfer_local_clock_sign_and_units ===\n');
i_test_reciprocal_model_sign_matches_documented_convention_();
i_test_clock_observability_audit_relative_bias_only_certified_();
i_test_negative_controls_();
fprintf('=== test_distributed_time_transfer_local_clock_sign_and_units: ALL PASS ===\n');
end

% ================================================================================================
function i_test_reciprocal_model_sign_matches_documented_convention_()
% Independent oracle: ReciprocalTimeTransferModel.evaluate itself, perturbed by finite
% difference on each endpoint's own clockBias_m, not read from its returned partials (which
% would be circular -- the perturbation IS the independent check).
reference = struct('position_m',[7e6;0;0],'velocity_mps',[0;3e3;0],'clockBias_m',5);
remote = struct('position_m',[7e6;2e5;1e5],'velocity_mps',[0;3e3;10],'clockBias_m',-3);

base = revgnss.ReciprocalTimeTransferModel.evaluate(reference,remote);
step = 1e-3;
referencePlus = reference; referencePlus.clockBias_m = reference.clockBias_m+step;
remotePlus = remote; remotePlus.clockBias_m = remote.clockBias_m+step;
valueReferencePlus = revgnss.ReciprocalTimeTransferModel.evaluate(referencePlus,remote).value_m;
valueRemotePlus = revgnss.ReciprocalTimeTransferModel.evaluate(reference,remotePlus).value_m;

dReference = (valueReferencePlus-base.value_m)/step;
dRemote = (valueRemotePlus-base.value_m)/step;
assert(abs(dReference-(-1)) < 1e-9,'d(value)/d(referenceClockBias) must be exactly -1.');
assert(abs(dRemote-(+1)) < 1e-9,'d(value)/d(remoteClockBias) must be exactly +1.');
assert(base.referenceClockPartial == -1 && base.remoteClockPartial == 1, ...
    'The model''s own reported partials must match the finite-difference oracle.');
fprintf('  PASS ReciprocalTimeTransferModel sign matches documented remoteMinusOwner convention\n');
end

% ================================================================================================
function i_test_clock_observability_audit_relative_bias_only_certified_()
[ownerState,remoteState] = i_realEndpointStatePair_();
n = numel(ownerState.covarianceComponentOrder);
biasIdx = find(strcmp(ownerState.covarianceComponentOrder,'clockBiasError_m'),1);

H_owner = zeros(1,n); H_owner(biasIdx) = -1;
H_remote = zeros(1,n); H_remote(biasIdx) = 1;
Rind_m2 = 0.25;

anchorSummary = revgnss.DistributedClockGaugeContract.requireDeclaredClockAnchorPair( ...
    ownerState,remoteState,'relativeBiasOnly');
audit = revgnss.DistributedClockGaugeContract.clockObservabilityAudit( ...
    ownerState,remoteState,H_owner,H_remote,Rind_m2,'firstOrderReciprocalClockTransfer',anchorSummary);

assert(strcmp(audit.auditVerdict,'relativeBiasOnlyCertified'));
assert(audit.ownerClockBiasColumn_mPerM == -1 && audit.remoteClockBiasColumn_mPerM == 1);
assert(audit.ownerClockDriftColumn_mPerMps == 0 && audit.remoteClockDriftColumn_mPerMps == 0);
assert(abs(audit.commonModeSensitivity_mPerM) < 1e-12,'A well-formed relative row must be common-mode blind.');
assert(abs(audit.differentialModeSensitivity_mPerM-2) < 1e-12);
assert(audit.rowClockInformationRank == 1);
expectedNull = [1;1]/sqrt(2);
assert(min(norm(audit.rowClockNullSpaceDirection-expectedNull), ...
    norm(audit.rowClockNullSpaceDirection+expectedNull)) < 1e-9, ...
    'The row null space must be the common-mode direction [1,1]/sqrt(2), up to sign.');
assert(audit.pairAbsolutelyAnchored && audit.absoluteClaimPermitted, ...
    'Both real fleet endpoints are anchored by masterConfig default; the pair claim must be permitted.');
assert(audit.pairClockInformationRank == 2, ...
    'With at least one anchored endpoint, the pair information matrix must be full rank.');
assert(isfinite(audit.pairClockInformationConditionNumber));
fprintf('  PASS clockObservabilityAudit certifies a well-formed relative-bias-only row\n');
end

% ================================================================================================
function i_test_negative_controls_()
[ownerState,remoteState] = i_realEndpointStatePair_();
n = numel(ownerState.covarianceComponentOrder);
biasIdx = find(strcmp(ownerState.covarianceComponentOrder,'clockBiasError_m'),1);
driftIdx = find(strcmp(ownerState.covarianceComponentOrder,'clockDriftError_mps'),1);
anchorSummary = revgnss.DistributedClockGaugeContract.requireDeclaredClockAnchorPair( ...
    ownerState,remoteState,'relativeBiasOnly');

% Swapped sign.
Hswap_owner = zeros(1,n); Hswap_owner(biasIdx) = 1;
Hswap_remote = zeros(1,n); Hswap_remote(biasIdx) = -1;
i_expectError_(@() revgnss.DistributedClockGaugeContract.clockObservabilityAudit( ...
    ownerState,remoteState,Hswap_owner,Hswap_remote,0.25,'firstOrderReciprocalClockTransfer', ...
    anchorSummary),'DistributedClockObservabilityAudit:verdictInconsistentWithAnchoring');

% Nonzero drift column.
Hdrift_owner = zeros(1,n); Hdrift_owner(biasIdx) = -1; Hdrift_owner(driftIdx) = 0.1;
Hdrift_remote = zeros(1,n); Hdrift_remote(biasIdx) = 1;
i_expectError_(@() revgnss.DistributedClockGaugeContract.clockObservabilityAudit( ...
    ownerState,remoteState,Hdrift_owner,Hdrift_remote,0.25,'firstOrderReciprocalClockTransfer', ...
    anchorSummary),'DistributedClockObservabilityAudit:verdictInconsistentWithAnchoring');

% Both columns +1: not common-mode blind.
Hblind_owner = zeros(1,n); Hblind_owner(biasIdx) = 1;
Hblind_remote = zeros(1,n); Hblind_remote(biasIdx) = 1;
i_expectError_(@() revgnss.DistributedClockGaugeContract.clockObservabilityAudit( ...
    ownerState,remoteState,Hblind_owner,Hblind_remote,0.25,'firstOrderReciprocalClockTransfer', ...
    anchorSummary),'DistributedClockObservabilityAudit:verdictInconsistentWithAnchoring');

fprintf('  PASS negative controls (swapped sign / nonzero drift / non-blind common mode) all refused\n');
end

% ================================================================================================
function [ownerState, remoteState] = i_realEndpointStatePair_()
cfg = masterConfig();
cfg.simulation.duration_s = 4; cfg.simulation.dt_s = 1;
cfg.report.writePdf = false; cfg.report.writeMat = false; cfg.report.compileTex = 'never';
cfg.plots.enable = false; cfg.plots.showFigures = false;
cfg.scenario.nSpaceAssets = 2;

setup = revgnss.IndependentFleetScenarioFactory.federatedSetup(cfg,false);
cfg1 = revgnss.IndependentFleetScenarioFactory.stageOneLeafConfigForIndex(setup,cfg,1);
cfg2 = revgnss.IndependentFleetScenarioFactory.stageOneLeafConfigForIndex(setup,cfg,2);
sim1 = revgnss.ReverseGNSSSimulation(cfg1);
sim1.initialize(); sim1.advanceTruthEpoch(1); sim1.runLocalEstimationEpoch(1);
sim2 = revgnss.ReverseGNSSSimulation(cfg2);
sim2.initialize(); sim2.advanceTruthEpoch(1); sim2.runLocalEstimationEpoch(1);
epoch_s = sim1.tVec(sim1.lastEstimatedEpoch);

ownerProvider = revgnss.OwnerLocalEstimatorEndpointProvider.fromLocalSimulation(sim1,1,epoch_s);
ownerState = ownerProvider.stateAtCoordinateEpoch(epoch_s);

diag2 = revgnss.EndpointStateProduct.fromLocalEstimator(sim2,2,epoch_s,0,'seq:sign-units-test');
commonTreat = struct('towerClockProduct','rejected','terminalCalibration','rejected', ...
    'transmittedStateProduct','rejected','sessionTimingProduct','rejected', ...
    'sharedForceAtmosphericProduct','rejected');
eligible2 = revgnss.EstimatorEligibleEndpointStateProduct.fromDiagnosticProduct(diag2,commonTreat);
remoteProvider = revgnss.FrozenProductEndpointProvider.fromEstimatorEligibleProduct(eligible2,epoch_s);
remoteState = remoteProvider.stateAtCoordinateEpoch(epoch_s);
end

function i_expectError_(action, identifier)
try
    action();
catch ME
    assert(strcmp(ME.identifier,identifier), ...
        'Expected %s, received %s (%s).',identifier,ME.identifier,ME.message);
    return
end
error('test_distributed_time_transfer_local_clock_sign_and_units:missingError', ...
    'Expected error %s was not raised.',identifier);
end
