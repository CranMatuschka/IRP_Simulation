function test_distributed_covariance_network_pair_exact_staging_and_commit()
% test_distributed_covariance_network_pair_exact_staging_and_commit  Plan Stage 3.2 items 5-8:
% revgnss.DistributedCovarianceNetwork's own half of the synchronized pair-exact protocol --
% routeForDelivery's two new eligibility checks, the pure third-member cross-transform/omission-
% audit math (checked against an independently recomputed reference, not just "did not error"),
% stage/commit/rollback/seal, and the honest overlapping-pair supersession refusal the order-
% invariance proof requires. Real revgnss.filter.ReverseGNSSEKF-backed providers throughout
% (matching the Stage 3.1 fixture style in test_distributed_covariance_network_audit_and_
% fleet_limit.m), not synthetic structs.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
addpath(rootDir);
addpath(fullfile(rootDir,'config'));
addpath(fullfile(rootDir,'config','internal'));

fprintf('=== test_distributed_covariance_network_pair_exact_staging_and_commit ===\n');
i_test_route_for_delivery_eligibility_checks_();
i_test_pure_math_against_independent_reference_();
i_test_stage_commit_third_member_and_claims_();
i_test_overlapping_pair_supersession_refusal_();
i_test_verified_rollback_restores_exact_preimage_();
i_test_seal_on_failed_rollback_and_guard_();
i_test_tampered_message_is_detected_and_refused_();
fprintf('=== test_distributed_covariance_network_pair_exact_staging_and_commit: ALL PASS ===\n');
end

% ================================================================================================
function i_test_route_for_delivery_eligibility_checks_()
[network, ~, ~, ids] = i_twoMemberPairExactNetwork_();
base = struct('ownerAssetIdentifier',ids{1},'remoteAssetIdentifier',ids{2},'coordinateEventEpoch_s',0);

[route, reason] = network.routeForDelivery(base);
assert(strcmp(route,'pairExact') && strcmp(reason,'pairExactRouteAvailable'), ...
    'a fresh, fully-tracked pair with no observable/clockClaim fields must route pairExact');

req2 = base; req2.observableIdentifier = 'notEligibleObservable';
[route, reason] = network.routeForDelivery(req2);
assert(strcmp(route,'conservativeBound') && strcmp(reason,'pairExactRefusedObservableNotEligible'), ...
    'an ineligible observable must refuse to conservativeBound with the frozen reason code');

req3 = base; req3.observableIdentifier = 'coherentTwoWayCodeRange';
req3.clockClaim = 'relativeBiasOnly'; req3.pairAbsolutelyAnchored = false;
[route, reason] = network.routeForDelivery(req3);
assert(strcmp(route,'conservativeBound') && strcmp(reason,'pairExactRefusedClockGaugeNotAnchored'), ...
    'an unanchored relative clock claim must refuse to conservativeBound with the frozen reason code');

req4 = req3; req4.pairAbsolutelyAnchored = true;
[route, reason] = network.routeForDelivery(req4);
assert(strcmp(route,'pairExact') && strcmp(reason,'pairExactRouteAvailable'), ...
    'an anchored relative clock claim with an eligible observable must route pairExact');
fprintf('  PASS: routeForDelivery observable-eligibility and clock-gauge-anchoring checks\n');
end

% ================================================================================================
function i_test_pure_math_against_independent_reference_()
rng_ = RandStream('mt19937ar','Seed',42);
ni = 5; nj = 4; nk = 3; m = 2;
Hi = rng_.randn(m,ni); Hj = rng_.randn(m,nj);
A = rng_.randn(ni,ni); Ki = A*A'+eye(ni); Ki = Ki(:,1:m);
B = rng_.randn(nj,nj); Kj = B*B'+eye(nj); Kj = Kj(:,1:m);

[Mi, Ni, Nj, Mj] = revgnss.DistributedCovarianceNetwork.pairExactErrorTransforms(struct( ...
    'Hi',Hi,'Hj',Hj,'Ki',Ki,'Kj',Kj));
assert(isequal(Mi,eye(ni)-Ki*Hi),'Mi must equal I-Ki*Hi exactly');
assert(isequal(Ni,-Ki*Hj),'Ni must equal -Ki*Hj exactly');
assert(isequal(Nj,-Kj*Hi),'Nj must equal -Kj*Hi exactly');
assert(isequal(Mj,eye(nj)-Kj*Hj),'Mj must equal I-Kj*Hj exactly');

% Attitude-reset congruence: a random Pij and two random 3x3 "reset" blocks embedded at
% arbitrary schema attitude columns/rows must equal the direct hand congruence Gi*Pij*Gj'.
Pij = rng_.randn(ni,nj);
Gi3 = eye(3) - 0.5*[0 -0.03 0.01; 0.03 0 -0.02; -0.01 0.02 0];
Gj3 = eye(3) - 0.5*[0 -0.01 0.02; 0.01 0 -0.01; -0.02 0.01 0];
% Only indices 7:9 (the frozen attitude-block slot) are ever read by
% applyAttitudeResetCongruenceToPairCross/pairExactThirdMemberCrossTransforms; the other 11
% entries are irrelevant filler here, kept in-bounds for ni/nj purely so the vectors are valid.
ownerSchemaIdx = ones(14,1); ownerSchemaIdx(7:9) = [2;3;4];    % must lie within 1:ni (ni=5)
remoteSchemaIdx = ones(14,1); remoteSchemaIdx(7:9) = [1;2;3];  % must lie within 1:nj (nj=4)
PijPlus = revgnss.DistributedCovarianceNetwork.applyAttitudeResetCongruenceToPairCross( ...
    Pij,Gi3,Gj3,ownerSchemaIdx,remoteSchemaIdx);
GiFull = eye(ni); GiFull([2 3 4],[2 3 4]) = Gi3;
GjFull = eye(nj); GjFull([1 2 3],[1 2 3]) = Gj3;
assert(norm(PijPlus-GiFull*Pij*GjFull','fro') < 1e-12, ...
    'applyAttitudeResetCongruenceToPairCross must equal the direct hand congruence');

% Third-member cross-transform + omission audit, hand-recomputed independently.
Pik = rng_.randn(ni,nk); Pjk = rng_.randn(nj,nk);
[PikPlus, PjkPlus] = revgnss.DistributedCovarianceNetwork.pairExactThirdMemberCrossTransforms(struct( ...
    'Hi',Hi,'Hj',Hj,'Ki',Ki,'Kj',Kj,'Gi',Gi3,'Gj',Gj3, ...
    'ownerSchemaStateIndices',ownerSchemaIdx,'remoteSchemaStateIndices',remoteSchemaIdx, ...
    'Pik',{{Pik}},'Pjk',{{Pjk}}));
Wk = Hi*Pik + Hj*Pjk;
expectedPikPlus = GiFull*(Pik-Ki*Wk);
expectedPjkPlus = GjFull*(Pjk-Kj*Wk);
assert(norm(PikPlus{1}-expectedPikPlus,'fro') < 1e-12,'PikPlus must match the hand-derived formula');
assert(norm(PjkPlus{1}-expectedPjkPlus,'fro') < 1e-12,'PjkPlus must match the hand-derived formula');

S = Hi*(A*A'+eye(ni))*Hi' + Hj*(B*B'+eye(nj))*Hj' + eye(m);
S = (S+S')/2;
Pkk = eye(nk)*3;
audit = revgnss.DistributedCovarianceNetwork.thirdMemberOmittedCorrectionAudit(struct( ...
    'S',S,'Hi',Hi,'Hj',Hj,'Pki',{{Pik}},'Pkj',{{Pjk}},'Pkk',{{Pkk}}, ...
    'endpointIdentifiers',{{'spacecraft:3'}}));
Ck = Pik'*Hi' + Pjk'*Hj';
omitted = Ck*(S\Ck');
expectedRatio = max(diag((omitted+omitted')/2))/max(diag(Pkk));
assert(abs(audit.ratios(1)-expectedRatio) < 1e-9,'omission ratio must match the hand-derived formula');
tol = revgnss.SynchronizedDeliveryContract.ThirdMemberOmittedVarianceToleranceRelative;
assert(audit.isNegligible == (expectedRatio <= tol),'isNegligible must match the ratio-vs-tolerance comparison');
fprintf('  PASS: pairExactErrorTransforms/attitude-congruence/third-member math match independent references\n');
end

% ================================================================================================
function i_test_stage_commit_third_member_and_claims_()
[network, providers, ~, ids] = i_threeMemberPairExactNetwork_();
i_seedNonzeroCrossBlocksViaCommonProcessNoise_(network,providers,ids);

message = i_assembleRealMessage_(network,providers,ids{1},ids{2},ids(3),0.05,10);
assert(numel(message.crossBlockCorrections) == 3, ...
    'a message with one third member must carry 3 cross-block corrections (direct + 2 third-member)');

staged = network.stagePairExactLinkTransform(message);
assert(numel(staged.replacementKeys) == 3 && numel(staged.replacementBlocks) == 3, ...
    'staged.replacementKeys/replacementBlocks must carry all 3 corrections (direct + 2 third-member)');

revBefore = network.currentRevisionNumber();
network.commitStagedPairExactLinkTransform(staged);
assert(network.currentRevisionNumber() == revBefore+1,'commit must bump the revision number by exactly one');

PAB = network.orientedCrossCovariance(ids{1},ids{2});
assert(isequal(PAB,message.crossBlockCorrections(1).posteriorCrossCovariance), ...
    'committed A-B cross block must equal the message''s declared direct-pair correction');
blockAB = network.crossBlockFor(ids{1},ids{2});
assert(strcmp(blockAB.provenanceKind,'conditionedOnPairExactLinkUpdate'), ...
    'committed cross block must carry the pair-exact provenance kind');

prov = network.provenanceSummary();
assert(prov.pairExactSynchronizedUpdateCount == 1,'pairExactSynchronizedUpdateCount must be 1 after one commit');
assert(prov.pairExactThirdMemberConditioningCount == 1, ...
    'pairExactThirdMemberConditioningCount must be 1 (this delivery had a third member)');
assert(strcmp(prov.linkUpdateConditioningClaim,'exactPairSynchronizedOnly'), ...
    'no conservative conditioning ever ran, so the conditioning claim must be exact-only');
assert(any(strcmp(prov.centralReferenceEquivalenceClaim, ...
    {'notEquivalentUnappliedThirdMemberCorrections','exactPairConditionedNonPairLinksRemainConservative'})), ...
    'a 3-member fleet after one pair-exact commit must report one of the two non-full-equivalence claims');
fprintf('  PASS: staging exposes replacements to the external contract, commit is single-revision, third-member conditioning and claims are correct\n');
end

% ================================================================================================
function i_test_overlapping_pair_supersession_refusal_()
[network, providers, ~, ids] = i_threeMemberPairExactNetwork_();
i_seedNonzeroCrossBlocksViaCommonProcessNoise_(network,providers,ids);

messageAB = i_assembleRealMessage_(network,providers,ids{1},ids{2},ids(3),0.05,10);
staged = network.stagePairExactLinkTransform(messageAB);
network.commitStagedPairExactLinkTransform(staged);

% A fresh message for the OVERLAPPING pair (B,C), assembled against the CURRENT (post-commit)
% revision, must still be refused at staging: B::C was already conditioned as a third-member
% cross block by the A-B delivery at this exact coordinate epoch.
messageBC = i_assembleRealMessage_(network,providers,ids{2},ids{3},{},0.03,10);
assert(messageBC.networkRevisionNumberAtAssembly == network.currentRevisionNumber(), ...
    'the second message must be assembled fresh against the post-commit revision');
threw = false;
try
    network.stagePairExactLinkTransform(messageBC);
catch ME
    threw = strcmp(ME.identifier,'DistributedCovarianceNetwork:linearizationPointSupersededByPairExactUpdate');
end
assert(threw,'an overlapping-pair delivery touching an already-conditioned block this epoch must be refused');
assert(network.provenanceSummary().pairExactSynchronizedUpdateCount == 1, ...
    'the refused overlapping delivery must not have committed anything');
fprintf('  PASS: overlapping-pair delivery is refused (order invariance''s honest negative case)\n');
end

% ================================================================================================
function i_test_verified_rollback_restores_exact_preimage_()
[network, providers, ~, ids] = i_threeMemberPairExactNetwork_();
i_seedNonzeroCrossBlocksViaCommonProcessNoise_(network,providers,ids);

PAB_before = network.orientedCrossCovariance(ids{1},ids{2});
revBefore = network.currentRevisionNumber();
provBefore = network.provenanceSummary();

message = i_assembleRealMessage_(network,providers,ids{1},ids{2},ids(3),0.05,10);
staged = network.stagePairExactLinkTransform(message);
preImage = network.stagedPreImage(staged);
network.commitStagedPairExactLinkTransform(staged);
assert(network.currentRevisionNumber() ~= revBefore,'commit must have changed the revision number');

network.restoreStagedPreImage(preImage);
assert(network.currentRevisionNumber() == revBefore,'rollback must restore the exact pre-commit revision number');
assert(isequal(network.orientedCrossCovariance(ids{1},ids{2}),PAB_before), ...
    'rollback must restore the exact pre-commit A-B cross block');
provAfter = network.provenanceSummary();
assert(isequal(provAfter.pairExactSynchronizedUpdateCount,provBefore.pairExactSynchronizedUpdateCount) && ...
    isequal(provAfter.pairExactThirdMemberConditioningCount,provBefore.pairExactThirdMemberConditioningCount) && ...
    isequal(provAfter.unappliedThirdMemberCorrectionCount,provBefore.unappliedThirdMemberCorrectionCount) && ...
    isequal(provAfter.maximumOmittedThirdMemberVarianceRatio,provBefore.maximumOmittedThirdMemberVarianceRatio), ...
    'rollback must restore every counter commitStagedPairExactLinkTransform bumped');
fprintf('  PASS: restoreStagedPreImage verifiably reverts revision, cross blocks, and every counter\n');
end

% ================================================================================================
function i_test_seal_on_failed_rollback_and_guard_()
[network, ~, ~, ids] = i_twoMemberPairExactNetwork_();
assert(~network.isSealed,'a fresh network must not be sealed');
network.sealOnFailedRollback('unit-test forced seal');
assert(network.isSealed,'sealOnFailedRollback must set isSealed');
assert(strcmp(network.provenanceSummary().sealReason,'unit-test forced seal'), ...
    'the seal reason must be readable via provenanceSummary even while sealed');

threw = false;
try
    network.routeForDelivery(struct('ownerAssetIdentifier',ids{1},'remoteAssetIdentifier',ids{2}, ...
        'coordinateEventEpoch_s',0));
catch ME
    threw = strcmp(ME.identifier,'DistributedCovarianceNetwork:networkSealed');
end
assert(threw,'a sealed network must refuse routeForDelivery');

network.sealOnFailedRollback('a different later reason');
assert(strcmp(network.provenanceSummary().sealReason,'unit-test forced seal'), ...
    'sealOnFailedRollback must be idempotent: the FIRST reason wins');
fprintf('  PASS: seal sets isSealed, guards a mutating/read method, is idempotent, and stays readable\n');
end

% ================================================================================================
function i_test_tampered_message_is_detected_and_refused_()
% Section 3.2 review finding B4: fromRecordWithDeclaredSignature previously called requireIntact
% on its own output, which made it structurally impossible to ever produce a message that FAILS
% requireIntact -- the "signed message" claim was untestable. Fixed by dropping that call; this
% is the test that closes the gap: mutate a real, validly-signed message's payload, reattach the
% OLD (now-mismatched) signature via fromRecordWithDeclaredSignature, and prove BOTH requireIntact
% and a real receiver's prepareAcknowledgement detect and refuse it.
[network, providers, ~, ids] = i_twoMemberPairExactNetwork_();
message = i_assembleRealMessage_(network,providers,ids{1},ids{2},{},0.05,0);

props = properties(message);
record = struct();
for index = 1:numel(props)
    record.(props{index}) = message.(props{index});
end
record.residual_rowUnit = record.residual_rowUnit + 1;  % mutate the payload
tampered = revgnss.SynchronizedPairCorrectionMessage.fromRecordWithDeclaredSignature( ...
    record,message.messageSignature_hex);   % OLD signature, now mismatched
assert(strcmp(tampered.messageSignature_hex,message.messageSignature_hex), ...
    'fromRecordWithDeclaredSignature must carry the DECLARED (now-mismatched) signature verbatim');

threw = false;
try
    revgnss.SynchronizedPairCorrectionMessage.requireIntact(tampered);
catch ME
    threw = strcmp(ME.identifier,'SynchronizedPairCorrectionMessage:messageSignatureInvalid');
end
assert(threw,'requireIntact must detect and reject a tampered payload with a stale signature');

% The message-integrity check (1) runs BEFORE physicalObservationRecord is ever dereferenced
% (checks 2-11), so a placeholder is sufficient here -- this subtest is about the signature gate,
% not the record-holding checks, which the atomicity/live-path tests already cover with real
% revgnss.InterSatelliteObservationRecord instances.
receiver = revgnss.LocalEndpointCorrectionReceiver.forLocalLeaf( ...
    providers{1},revgnss.ObservationConsumptionLedger());
ack = receiver.prepareAcknowledgement(tampered,[],'eligible');
assert(~ack.accepted && strcmp(ack.reasonCode,'messageSignatureInvalid'), ...
    'a real receiver must refuse a tampered message with reasonCode=messageSignatureInvalid, got accepted=%d reasonCode=%s', ...
    ack.accepted,ack.reasonCode); %#ok<CTPCT>
fprintf('  PASS: a tampered message (mutated payload + stale signature) is detected and refused end-to-end\n');
end

% ================================================================================================
function [network, providers, ekfs, ids] = i_twoMemberPairExactNetwork_()
[network, providers, ekfs, ids] = i_nMemberPairExactNetwork_(2);
end

function [network, providers, ekfs, ids] = i_threeMemberPairExactNetwork_()
[network, providers, ekfs, ids] = i_nMemberPairExactNetwork_(3);
end

function [network, providers, ekfs, ids] = i_nMemberPairExactNetwork_(n)
cfg = masterConfig();
cfg.scenario.nTowers = 3;
cfg = revgnss.ConfigFactory.finalizeConfig(cfg);
clockModel = models.clocks.ClockModel(cfg.asset.clock);
ids = arrayfun(@(k) sprintf('spacecraft:%d',k),1:n,'UniformOutput',false);
ekfs = cell(1,n); providers = cell(1,n);
for k = 1:n
    ekfs{k} = filter.ReverseGNSSEKF(cfg,cfg.scenario.nTowers,clockModel);
    ekfs{k}.initState(zeros(ekfs{k}.nx,1),eye(ekfs{k}.nx)*0.01);
    ekfs{k}.retainEpochTransitionOperators = true;
    providers{k} = revgnss.OwnerLocalEkfTransitionCaptureProvider.forLocalEkf(ekfs{k},ids{k},k);
end
policyRecord = struct('policyIdentifier','exactPairwiseCrossCovariance', ...
    'configuredMaximumFleetSize',4,'commonProcessNoiseTreatment','declaredCommonAccelerationGroup', ...
    'linkUpdateRoutingPolicy','pairExactWhenBothEndpointsTracked','crossBlockSpanKind','fullLocalStateSpan', ...
    'stateSchemaVersion',revgnss.DistributedLinkProtocolContract.StateSchemaVersion);
network = revgnss.DistributedCovarianceNetwork(policyRecord);
records = providers{1}.memberRegistrationRecord(0);
for k = 2:n
    records = [records, providers{k}.memberRegistrationRecord(0)]; %#ok<AGROW>
end
network.registerFleetMembers(records);
network.declareIndependentPriorPairs(0);
end

% ================================================================================================
function i_seedNonzeroCrossBlocksViaCommonProcessNoise_(network, providers, ids)
% i_seedNonzeroCrossBlocksViaCommonProcessNoise_  Every declared pair starts at P_ij=0
% (priorIndependenceDeclaration); a real message-assembly/staging test needs a genuinely
% nonzero, non-degenerate prior cross block to be meaningful. Uses Stage 3.1's own already-
% proven advanceEpoch + declared common process-noise group machinery (F=I,A=I trivial
% captures) purely as a fixture-setup step, exactly as test_distributed_covariance_network_
% prediction_cross_block.m does for its own advanceEpoch tests.
n = numel(ids);
group = revgnss.CommonProcessNoiseCovarianceGroup.fromRecord(struct( ...
    'processNoiseGroupIdentifier','fixture:group','commonSourceName','sharedForceAtmosphericProduct', ...
    'treatment','declaredCommonAccelerationGroup','memberEndpointIdentifiers',{ids}, ...
    'frameIdentifier','ECEF','commonAccelerationSigma_mps2',5e-3, ...
    'stateComponentPairing','positionVelocityPerAxis','sourceConfigurationPath','test.fixture', ...
    'validFromCoordinateEpoch_s',0,'validUntilCoordinateEpoch_s',1e9));
network.declareCommonProcessNoiseGroup(group);

captures = revgnss.LocalEpochTransitionCapture.empty;
for k = 1:n
    nx = providers{k}.localStateDimension();
    record = struct('endpointIdentifier',ids{k},'localStateDimension',nx,'predictApplied',true, ...
        'stateTransition',eye(nx),'processNoise',zeros(nx),'localUpdateContraction',eye(nx), ...
        'intervalStartCoordinateEpoch_s',0,'intervalDuration_s',10,'intervalEndCoordinateEpoch_s',10, ...
        'accountedUpdateCallCount',0,'accountedMeasurementRowCount',0,'benignDiagonalNudgeCount',0, ...
        'unmodelledCovarianceTransformCount',0,'unmodelledCovarianceTransformKinds',{{}}, ...
        'schemaStateIndices',providers{k}.schemaStateIndices(),'covarianceComponentOrder',{{}}, ...
        'attitudeErrorCoordinateConvention',providers{k}.attitudeParameterization(), ...
        'localStateMapFingerprint',providers{k}.localStateMapFingerprint(),'captureSequenceNumber',1);
    captures(k) = i_fixCaptureConventionFields_(record,providers{k}); %#ok<AGROW>
end
network.advanceEpoch(struct('coordinateEpoch_s',10,'intervalDuration_s',10,'captures',captures));
end

function cap = i_fixCaptureConventionFields_(record, provider)
% i_fixCaptureConventionFields_  covarianceComponentOrder/attitudeErrorCoordinateConvention must
% be the ONE matched frozen pair LocalEpochTransitionCapture accepts; derive both from the real
% provider's own attitude parameterization rather than hand-guessing.
if strcmp(provider.attitudeParameterization(),'quaternionErrorState')
    record.covarianceComponentOrder = ...
        revgnss.DistributedLinkProtocolContract.StateSchemaV1CovarianceComponentOrderTangent;
    record.attitudeErrorCoordinateConvention = 'rightMultiplicativeLocalTangent_rad';
else
    record.covarianceComponentOrder = ...
        revgnss.DistributedLinkProtocolContract.StateSchemaV1CovarianceComponentOrderEuler;
    record.attitudeErrorCoordinateConvention = 'eulerZYXError_rad';
end
cap = revgnss.LocalEpochTransitionCapture.fromLocalEpochRecord(record);
end

% ================================================================================================
function message = i_assembleRealMessage_(network, providers, ownerId, remoteId, thirdIds, ...
        residual_m, coordinateEpoch_s)
% i_assembleRealMessage_  Builds a real revgnss.SynchronizedPairCorrectionMessage from live
% provider state and the network's own currently-stored cross blocks -- the SAME data
% revgnss.SynchronizedPairLinkUpdateTransaction reads, just assembled directly here for a
% network-focused unit test rather than through the full transaction/coordinator.
ownerIdx = find(strcmp(cellfun(@(p) p.endpointIdentifier(),providers,'UniformOutput',false),ownerId),1);
remoteIdx = find(strcmp(cellfun(@(p) p.endpointIdentifier(),providers,'UniformOutput',false),remoteId),1);
ownerProvider = providers{ownerIdx};
remoteProvider = providers{remoteIdx};

owner = i_endpointRecordFromProvider_(ownerProvider);
remote = i_endpointRecordFromProvider_(remoteProvider);
Pij = network.orientedCrossCovariance(ownerId,remoteId);

thirdMembers = struct('endpointIdentifier',{},'priorCrossToOwner',{}, ...
    'priorCrossToRemote',{},'localMarginal',{});
for k = 1:numel(thirdIds)
    thirdIdx = find(strcmp(cellfun(@(p) p.endpointIdentifier(),providers,'UniformOutput',false), ...
        thirdIds{k}),1);
    thirdMembers(end+1) = struct( ...  %#ok<AGROW>
        'endpointIdentifier',thirdIds{k}, ...
        'priorCrossToOwner',network.orientedCrossCovariance(ownerId,thirdIds{k}), ...
        'priorCrossToRemote',network.orientedCrossCovariance(remoteId,thirdIds{k}), ...
        'localMarginal',providers{thirdIdx}.localCovariance());
end

Hi14 = zeros(1,14); Hi14(1) = 1;
Hj14 = zeros(1,14); Hj14(2) = -1;
message = revgnss.SynchronizedPairCorrectionMessage.assemble(struct( ...
    'observationIdentifier',sprintf('obs:%s:%s:%d',ownerId,remoteId,coordinateEpoch_s), ...
    'deliveryIdentifier',sprintf('delivery:%s:%s:%d',ownerId,remoteId,coordinateEpoch_s), ...
    'sessionIdentifier','session:test', ...
    'observableIdentifier','coherentTwoWayCodeRange','observableRowUnits','m', ...
    'coordinateEventEpoch_s',coordinateEpoch_s,'deliveryEpoch_s',coordinateEpoch_s, ...
    'sourceEpoch_s',coordinateEpoch_s, ...
    'issuerIdentifier','testHarness','partialDeliveryPolicy','rejectWholeUpdate', ...
    'messageSignaturePolicy','contentDigestFnv1a64','thirdMemberCrossConditioning','exactJointPairTransform', ...
    'ownerEndpoint',owner,'remoteEndpoint',remote, ...
    'ownerJacobian_mPerErrorUnit',Hi14,'remoteJacobian_mPerErrorUnit',Hj14, ...
    'independentMeasurementCovariance_m2',1,'residual_m',residual_m, ...
    'priorPairCrossCovariance',Pij,'thirdMembers',thirdMembers, ...
    'networkRevisionNumber',network.currentRevisionNumber(), ...
    'clockClaim','absoluteClockState','pairAbsolutelyAnchored',true));
end

function endpoint = i_endpointRecordFromProvider_(provider)
endpoint = struct( ...
    'identifier',provider.endpointIdentifier(),'canonicalPhysicalAssetIndex',provider.canonicalPhysicalAssetIndex, ...
    'localStateDimension',provider.localStateDimension(),'schemaStateIndices',provider.schemaStateIndices(), ...
    'localStateMapFingerprint',provider.localStateMapFingerprint(), ...
    'attitudeParameterization',provider.attitudeParameterization(), ...
    'attitudeErrorCoordinateConvention',i_attitudeConventionFor_(provider.attitudeParameterization()), ...
    'xPrior',provider.localState(),'PPrior',provider.localCovariance(), ...
    'nominalQuatPrior',provider.nominalQuaternion(), ...
    'priorStateDigest_hex',provider.localStateDigest(), ...
    'stateSchemaVersion',revgnss.DistributedLinkProtocolContract.StateSchemaVersion);
end

function convention = i_attitudeConventionFor_(attitudeParameterization)
if strcmp(attitudeParameterization,'quaternionErrorState')
    convention = 'rightMultiplicativeLocalTangent_rad';
else
    convention = 'eulerZYXError_rad';
end
end
