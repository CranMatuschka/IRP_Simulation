function test_distributed_clock_observability_audit()
% test_distributed_clock_observability_audit  Proves the load-bearing physical point behind
% plan Section 2.4: a finite prior clock-bias variance is NOT an anchor. The numerical
% pairClockInformationRank/ConditionNumber cross-check must track the DECLARATIVE anchor fact
% (revgnss.EndpointClockAnchorDeclaration), never the raw size of a prior variance.

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir,'..'));

fprintf('=== test_distributed_clock_observability_audit ===\n');
i_test_anchored_pair_is_full_rank_well_conditioned_();
i_test_unanchored_pair_with_tiny_prior_variance_stays_rank_deficient_();
i_test_forging_absolute_claim_permitted_is_refused_();
fprintf('=== test_distributed_clock_observability_audit: ALL PASS ===\n');
end

% ================================================================================================
function i_test_anchored_pair_is_full_rank_well_conditioned_()
[ownerState,remoteState] = i_realEndpointStatePair_();
[H_owner,H_remote,n] = i_relativeBiasJacobian_(ownerState); %#ok<ASGLU>
anchorSummary = revgnss.DistributedClockGaugeContract.requireDeclaredClockAnchorPair( ...
    ownerState,remoteState,'relativeBiasOnly');
assert(anchorSummary.pairAbsolutelyAnchored, ...
    ['Both real fleet endpoints are anchored by the masterConfig default (5 towers, ' ...
    'perfectCorrection): this fixture assumption must hold.']);
audit = revgnss.DistributedClockGaugeContract.clockObservabilityAudit( ...
    ownerState,remoteState,H_owner,H_remote,0.25,'firstOrderReciprocalClockTransfer',anchorSummary);
assert(audit.pairClockInformationRank == 2);
assert(audit.pairClockInformationConditionNumber < 1e6, ...
    'A genuinely anchored pair must be numerically well-conditioned, not merely rank==2.');
assert(audit.absoluteClaimPermitted);
fprintf('  PASS anchored pair -> pairClockInformationRank==2, well-conditioned, claim permitted\n');
end

% ================================================================================================
function i_test_unanchored_pair_with_tiny_prior_variance_stays_rank_deficient_()
% THE load-bearing point: forge both endpoints unanchored, but give the owner an artificially
% TINY clock-bias prior variance (which, numerically, looks like strong information). The
% pairClockInformationRank must STILL be 1 (rank-deficient), because the prior-information term
% is gated on the DECLARATIVE anchor, not on how small the variance happens to be.
[ownerState,remoteState] = i_realEndpointStatePair_();
[H_owner,H_remote,~] = i_relativeBiasJacobian_(ownerState);
biasIdx = find(strcmp(ownerState.covarianceComponentOrder,'clockBiasError_m'),1);

unanchoredOwnerDecl = i_unanchoredDeclaration_('spacecraft:1',1);
unanchoredRemoteDecl = i_unanchoredDeclaration_('spacecraft:2',2);
ownerUnanchored = i_withClockAnchorDeclaration_(ownerState,unanchoredOwnerDecl);
remoteUnanchored = i_withClockAnchorDeclaration_(remoteState,unanchoredRemoteDecl);

% Forge a deliberately tiny clock-bias prior variance on the (now unanchored) owner state. The
% clock-bias row/column is decoupled from the rest of the state (zeroed off-diagonal) so the
% forged matrix remains a valid PSD covariance -- shrinking only the diagonal entry while
% leaving real cross-correlations in place would generally break PSD-ness.
tinyP = ownerUnanchored.covarianceBlock;
tinyP(biasIdx,:) = 0; tinyP(:,biasIdx) = 0;
tinyP(biasIdx,biasIdx) = 1e-12;
ownerTinyPrior = i_withCovarianceBlock_(ownerUnanchored,tinyP);

anchorSummary = revgnss.DistributedClockGaugeContract.requireDeclaredClockAnchorPair( ...
    ownerTinyPrior,remoteUnanchored,'notAClockObservable');
assert(~anchorSummary.pairAbsolutelyAnchored, ...
    'Both endpoints are declared unanchored; the tiny prior variance must not flip this.');
audit = revgnss.DistributedClockGaugeContract.clockObservabilityAudit( ...
    ownerTinyPrior,remoteUnanchored,H_owner,H_remote,0.25,'coherentTwoWayCodeRange',anchorSummary);
assert(audit.pairClockInformationRank == 1, ...
    ['pairClockInformationRank must stay 1 (rank-deficient): a finite -- even artificially ' ...
    'tiny -- prior variance is NOT an anchor, and must not be folded into the pair information ' ...
    'matrix for an unanchored endpoint.']);
assert(~audit.absoluteClaimPermitted, ...
    'absoluteClaimPermitted must be false regardless of how small the forged prior variance is.');
fprintf('  PASS a tiny prior clock variance on an UNANCHORED endpoint does not manufacture rank/permission\n');
end

% ================================================================================================
function i_test_forging_absolute_claim_permitted_is_refused_()
[ownerState,remoteState] = i_realEndpointStatePair_();
[H_owner,H_remote,n] = i_relativeBiasJacobian_(ownerState); %#ok<ASGLU>
unanchoredOwnerDecl = i_unanchoredDeclaration_('spacecraft:1',1);
unanchoredRemoteDecl = i_unanchoredDeclaration_('spacecraft:2',2);
ownerUnanchored = i_withClockAnchorDeclaration_(ownerState,unanchoredOwnerDecl);
remoteUnanchored = i_withClockAnchorDeclaration_(remoteState,unanchoredRemoteDecl);
anchorSummary = revgnss.DistributedClockGaugeContract.requireDeclaredClockAnchorPair( ...
    ownerUnanchored,remoteUnanchored,'notAClockObservable');
audit = revgnss.DistributedClockGaugeContract.clockObservabilityAudit( ...
    ownerUnanchored,remoteUnanchored,H_owner,H_remote,0.25,'coherentTwoWayCodeRange',anchorSummary);
record = struct( ...
    'observableIdentifier',audit.observableIdentifier,'clockClaim',audit.clockClaim, ...
    'ownerClockBiasColumn_mPerM',audit.ownerClockBiasColumn_mPerM, ...
    'remoteClockBiasColumn_mPerM',audit.remoteClockBiasColumn_mPerM, ...
    'ownerClockDriftColumn_mPerMps',audit.ownerClockDriftColumn_mPerMps, ...
    'remoteClockDriftColumn_mPerMps',audit.remoteClockDriftColumn_mPerMps, ...
    'commonModeSensitivity_mPerM',audit.commonModeSensitivity_mPerM, ...
    'differentialModeSensitivity_mPerM',audit.differentialModeSensitivity_mPerM, ...
    'rowClockInformationRank',audit.rowClockInformationRank, ...
    'rowClockNullSpaceDirection',audit.rowClockNullSpaceDirection, ...
    'ownerAnchorKind',audit.ownerAnchorKind,'remoteAnchorKind',audit.remoteAnchorKind, ...
    'pairAnchorDatumIdentifier',audit.pairAnchorDatumIdentifier, ...
    'pairAbsolutelyAnchored',audit.pairAbsolutelyAnchored, ...
    'ownerClockBiasPriorVariance_m2',audit.ownerClockBiasPriorVariance_m2, ...
    'remoteClockBiasPriorVariance_m2',audit.remoteClockBiasPriorVariance_m2, ...
    'independentMeasurementCovariance_m2',audit.independentMeasurementCovariance_m2, ...
    'pairClockInformationRank',audit.pairClockInformationRank, ...
    'pairClockInformationConditionNumber',audit.pairClockInformationConditionNumber, ...
    'absoluteClaimPermitted',true, ... % FORGED: pairAbsolutelyAnchored is false above
    'auditVerdict',audit.auditVerdict,'rowUnits',audit.rowUnits);
i_expectError_(@() revgnss.DistributedClockObservabilityAudit.fromValidatedRecord(record), ...
    'DistributedClockObservabilityAudit:absoluteClaimNotPermitted');
fprintf('  PASS forging absoluteClaimPermitted=true on an unanchored pair is refused at construction\n');
end

% ================================================================================================
function [H_owner, H_remote, n] = i_relativeBiasJacobian_(state)
n = numel(state.covarianceComponentOrder);
biasIdx = find(strcmp(state.covarianceComponentOrder,'clockBiasError_m'),1);
H_owner = zeros(1,n); H_owner(biasIdx) = -1;
H_remote = zeros(1,n); H_remote(biasIdx) = 1;
end

function state = i_withClockAnchorDeclaration_(state, declaration)
rec = state.toStruct();
rec.clockAnchorDeclaration = declaration;
state = revgnss.CommunicationEndpointState(rec);
end

function state = i_withCovarianceBlock_(state, P)
rec = state.toStruct();
rec.clockAnchorDeclaration = state.clockAnchorDeclaration;
rec.covarianceBlock = P;
state = revgnss.CommunicationEndpointState(rec);
end

function declaration = i_unanchoredDeclaration_(endpointIdentifier, canonicalIdx)
cfg = struct('scenario',struct('nTowers',0), ...
    'estimator',struct('towerClockMode','none'), ...
    'clock',struct('mode','spacecraftReceiverClockOnly', ...
        'gauge',struct('mode','externalTowerCorrections','referenceTowerIndex',1)));
declaration = revgnss.EndpointClockAnchorDeclaration.fromLocalEstimatorConfig( ...
    cfg,endpointIdentifier,canonicalIdx);
end

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

diag2 = revgnss.EndpointStateProduct.fromLocalEstimator(sim2,2,epoch_s,0,'seq:audit-test');
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
error('test_distributed_clock_observability_audit:missingError', ...
    'Expected error %s was not raised.',identifier);
end
