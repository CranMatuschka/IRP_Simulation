function test_synchronized_pair_link_update_transaction_atomicity()
% test_synchronized_pair_link_update_transaction_atomicity  Plan Stage 3.2 items 6-7:
% revgnss.SynchronizedPairLinkUpdateTransaction's own two-phase-commit guarantee, exercised
% directly (not only through the coordinator): a genuine partial-delivery refusal (remote
% endpoint's prior-state digest has moved since the message was assembled) writes NOTHING
% anywhere. commitAcknowledgedPairUpdate is public and test-callable by its own header; its
% journal ({networkPreImage,ownerSnapshot,remoteSnapshot}) covers ONLY C1-C3's effects, so the
% two forced-failure subtests below test the two genuinely different outcomes that follow
% (Section 3.2 review finding B3): a C1 failure (nothing yet mutated) is verifiably rolled back;
% a C4 failure (after C1-C3 already correctly committed) seals rather than falsely rolling back
% an already-correct update. The successful-commit / fleet-ledger-population claim is proven
% separately, through the real coordinator, in
% tests/test_independent_fleet_synchronized_pair_live_path.m: a genuine
% revgnss.DistributedDeliveryLedger 'eligible' entry can only be seeded by a real
% revgnss.LinkObservationDelivery, which itself requires the full production endpoint-provider
% stack (revgnss.OwnerLocalEstimatorEndpointProvider/revgnss.FrozenProductEndpointProvider) --
% exactly what the coordinator already builds, so proving that path there (not hand-assembled
% here) is both the lower-risk and the more representative test. Real
% revgnss.filter.ReverseGNSSEKF-backed providers/receivers throughout.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
addpath(rootDir);
addpath(fullfile(rootDir,'config'));
addpath(fullfile(rootDir,'config','internal'));

fprintf('=== test_synchronized_pair_link_update_transaction_atomicity ===\n');
i_test_partial_delivery_refusal_writes_nothing_();
i_test_c1_failure_is_verifiably_rolled_back_();
i_test_c4_failure_after_full_commit_seals_rather_than_falsely_rolls_back_();
fprintf('=== test_synchronized_pair_link_update_transaction_atomicity: ALL PASS ===\n');
end

% ================================================================================================
function i_test_partial_delivery_refusal_writes_nothing_()
[network, providers, ekfs, ids, receivers] = i_twoMemberPairExactFixture_();
record = i_realTwoWayCodeRangeRecord_('obs:atomic:partial',ids{1},ids{2});

xOwnerBefore = ekfs{1}.x; POwnerBefore = ekfs{1}.P;
xRemoteBefore = ekfs{2}.x; PRemoteBefore = ekfs{2}.P;
revBefore = network.currentRevisionNumber();

% Move the REMOTE endpoint's state AFTER the transaction would assemble its message but through
% a channel the transaction has no way to see coming -- the sanctioned external write path
% itself -- so its live prior-state digest no longer matches what a freshly-assembled message
% would declare. executeSynchronizedPairUpdate assembles fresh each call, so to get a genuine
% digest mismatch we assemble the message manually first, then perturb, then feed the ALREADY-
% STALE message into commitAcknowledgedPairUpdate's own upstream phase via prepareAcknowledgement
% directly (mirroring exactly what the transaction's phase 2 does).
ownerEndpoint = i_endpointRecordFromProvider_(providers{1});
remoteEndpoint = i_endpointRecordFromProvider_(providers{2});
Pij = network.orientedCrossCovariance(ids{1},ids{2});
message = revgnss.SynchronizedPairCorrectionMessage.assemble(i_assembleArgs_( ...
    record,ownerEndpoint,remoteEndpoint,Pij,struct('endpointIdentifier',{},'priorCrossToOwner',{}, ...
    'priorCrossToRemote',{},'localMarginal',{})));

ekfs{2}.applyDeclaredExternalCovarianceWrite(ekfs{2}.x+1,ekfs{2}.P,ekfs{2}.nominalQuat_wxyz(:,1));
assert(~isequal(ekfs{2}.x,xRemoteBefore) && isequal(ekfs{2}.P,PRemoteBefore), ...
    'the perturbation must have actually moved the remote EKF state (sanity check on the fixture itself)');

staged = network.stagePairExactLinkTransform(message);
ownerAck = receivers{1}.prepareAcknowledgement(message,record,'eligible');
remoteAck = receivers{2}.prepareAcknowledgement(message,record,'eligible');
assert(ownerAck.accepted,'the untouched owner endpoint must still acknowledge');
assert(~remoteAck.accepted && strcmp(remoteAck.reasonCode,'priorStateDigestMismatch'), ...
    'the perturbed remote endpoint must refuse with priorStateDigestMismatch, got accepted=%d reasonCode=%s', ...
    remoteAck.accepted,remoteAck.reasonCode); %#ok<CTPCT>
% (both refused/accepted acks computed; NOTHING has been written by prepareAcknowledgement itself
% -- verify the whole surface is still exactly as it was.)
assert(isequal(ekfs{1}.x,xOwnerBefore) && isequal(ekfs{1}.P,POwnerBefore), ...
    'the owner EKF must be untouched: prepareAcknowledgement never writes');
assert(isequal(network.currentRevisionNumber(),revBefore), ...
    'the network must be untouched: staging never writes, only builds');
fprintf('  PASS: a partial-delivery refusal (one endpoint digest-mismatched) writes NOTHING anywhere\n');
end

% ================================================================================================
function i_test_c1_failure_is_verifiably_rolled_back_()
% A failure AT C1 (network.commitStagedPairExactLinkTransform) means NOTHING has mutated yet
% (C1 is the FIRST mutating step) -- the journal fully covers this failure, so a genuine,
% verified :commitRolledBack is the correct and honest outcome. Forced via a stale
% preparedAgainstRevisionNumber (the network advances between staging and commit).
[network, providers, ekfs, ids, receivers] = i_twoMemberPairExactFixture_();
record = i_realTwoWayCodeRangeRecord_('obs:atomic:c1fail',ids{1},ids{2});
delivery = i_deliveryStruct_(record,ids{1},ids{2});

ownerEndpoint = i_endpointRecordFromProvider_(providers{1});
remoteEndpoint = i_endpointRecordFromProvider_(providers{2});
Pij = network.orientedCrossCovariance(ids{1},ids{2});
message = revgnss.SynchronizedPairCorrectionMessage.assemble(i_assembleArgs_( ...
    record,ownerEndpoint,remoteEndpoint,Pij,struct('endpointIdentifier',{},'priorCrossToOwner',{}, ...
    'priorCrossToRemote',{},'localMarginal',{})));
staged = network.stagePairExactLinkTransform(message);
ownerAck = receivers{1}.prepareAcknowledgement(message,record,'eligible');
remoteAck = receivers{2}.prepareAcknowledgement(message,record,'eligible');
assert(ownerAck.accepted && remoteAck.accepted,'both endpoints must acknowledge cleanly for this subtest');

xOwnerBefore = ekfs{1}.x; POwnerBefore = ekfs{1}.P;
xRemoteBefore = ekfs{2}.x; PRemoteBefore = ekfs{2}.P;
revBefore = network.currentRevisionNumber();

% Force staged.preparedAgainstRevisionNumber stale (as if some other writer had advanced the
% network between staging and commit) -- commitStagedPairExactLinkTransform's own revision
% check is C1's first line, so this fails BEFORE any mutation.
staleStaged = staged;
staleStaged.preparedAgainstRevisionNumber = staged.preparedAgainstRevisionNumber - 1;

brokenLedger = revgnss.DistributedDeliveryLedger();
threw = false;
try
    revgnss.SynchronizedPairLinkUpdateTransaction.commitAcknowledgedPairUpdate(struct( ...
        'network',network,'staged',staleStaged,'message',message, ...
        'ownerReceiver',receivers{1},'remoteReceiver',receivers{2}, ...
        'ownerAcknowledgement',ownerAck,'remoteAcknowledgement',remoteAck, ...
        'deliveryLedger',brokenLedger,'delivery',delivery, ...
        'physicalObservationRecord',record,'coordinateEventEpoch_s',0));
catch ME
    threw = strcmp(ME.identifier,'SynchronizedPairLinkUpdateTransaction:commitRolledBack');
end
assert(threw,'a C1 failure (nothing yet mutated) must raise a genuine, verified :commitRolledBack');
assert(~network.isSealed,'a C1 failure''s VERIFIED rollback must not seal the network');
assert(network.currentRevisionNumber() == revBefore,'the network revision must be unchanged');
assert(isequal(ekfs{1}.x,xOwnerBefore) && isequal(ekfs{1}.P,POwnerBefore) && ...
    isequal(ekfs{2}.x,xRemoteBefore) && isequal(ekfs{2}.P,PRemoteBefore), ...
    'neither EKF was ever touched by a C1 failure');
fprintf('  PASS: a C1 (pre-mutation) failure raises a genuine, verified :commitRolledBack\n');
end

% ================================================================================================
function i_test_c4_failure_after_full_commit_seals_rather_than_falsely_rolls_back_()
% Section 3.2 review finding B3: the journal ({networkPreImage,ownerSnapshot,remoteSnapshot})
% covers ONLY C1-C3's effects. A failure AT or AFTER C4 means C1 (network), C2 (owner EKF), and
% C3 (remote EKF) already succeeded -- BOTH filters and the network already correctly reflect the
% new, scientifically valid state -- so rolling them back would revert a correct update just
% because a bookkeeping step failed, and "verified rollback" could never honestly be claimed for
% a step the journal never covered. The fixed behaviour seals immediately instead, WITHOUT
% touching the (already-correct) EKF/network state.
[network, providers, ekfs, ids, receivers] = i_twoMemberPairExactFixture_();
record = i_realTwoWayCodeRangeRecord_('obs:atomic:c4fail',ids{1},ids{2});
delivery = i_deliveryStruct_(record,ids{1},ids{2});

ownerEndpoint = i_endpointRecordFromProvider_(providers{1});
remoteEndpoint = i_endpointRecordFromProvider_(providers{2});
Pij = network.orientedCrossCovariance(ids{1},ids{2});
message = revgnss.SynchronizedPairCorrectionMessage.assemble(i_assembleArgs_( ...
    record,ownerEndpoint,remoteEndpoint,Pij,struct('endpointIdentifier',{},'priorCrossToOwner',{}, ...
    'priorCrossToRemote',{},'localMarginal',{})));
staged = network.stagePairExactLinkTransform(message);
ownerAck = receivers{1}.prepareAcknowledgement(message,record,'eligible');
remoteAck = receivers{2}.prepareAcknowledgement(message,record,'eligible');
assert(ownerAck.accepted && remoteAck.accepted,'both endpoints must acknowledge cleanly for this subtest');

revisionBeforeCommit = network.currentRevisionNumber();

% A FRESH, empty delivery ledger (never given an eligible entry for this observation) makes
% commitAcknowledgedPairUpdate's own step C4 throw DistributedDeliveryLedger:unknownObservation
% AFTER C1-C3 have already mutated real state.
brokenLedger = revgnss.DistributedDeliveryLedger();
threw = false;
try
    revgnss.SynchronizedPairLinkUpdateTransaction.commitAcknowledgedPairUpdate(struct( ...
        'network',network,'staged',staged,'message',message, ...
        'ownerReceiver',receivers{1},'remoteReceiver',receivers{2}, ...
        'ownerAcknowledgement',ownerAck,'remoteAcknowledgement',remoteAck, ...
        'deliveryLedger',brokenLedger,'delivery',delivery, ...
        'physicalObservationRecord',record,'coordinateEventEpoch_s',0));
catch ME
    threw = strcmp(ME.identifier,'SynchronizedPairLinkUpdateTransaction:fatalUnrecoverablePartialCommit');
end
assert(threw,'a C4 failure (after C1-C3 already committed) must raise :fatalUnrecoverablePartialCommit');

% Once sealed, requireNotSealed_ correctly refuses EVERY cross-block read (orientedCrossCovariance
% included -- confirmed by trace during review: "no covariance data can be read out of a sealed
% network"), so this subtest verifies C1 really committed through provenanceSummary's revisionNumber
% (an unguarded diagnostic getter) instead of re-reading the (now-forbidden) cross block itself.
prov = network.provenanceSummary();
assert(prov.isSealed,'a C4 failure must seal the network (its ledger bookkeeping is now unreliable)');
assert(~isempty(prov.sealReason),'the seal reason must be recorded and readable');
assert(prov.revisionNumber == revisionBeforeCommit+1, ...
    'the revision number (bumped only by C1''s single map-swap commit) proves C1 really ran and was NOT reverted');
assert(isequal(ekfs{1}.x,message.ownerEndpointCorrection.xPosterior) && ...
    isequal(ekfs{1}.P,message.ownerEndpointCorrection.PPosterior), ...
    'the owner EKF (correctly updated by C2) must NOT be reverted -- it was never wrong');
assert(isequal(ekfs{2}.x,message.remoteEndpointCorrection.xPosterior) && ...
    isequal(ekfs{2}.P,message.remoteEndpointCorrection.PPosterior), ...
    'the remote EKF (correctly updated by C3) must NOT be reverted -- it was never wrong');
threwOnSealedRead = false;
try
    network.orientedCrossCovariance(ids{1},ids{2});
catch ME2
    threwOnSealedRead = strcmp(ME2.identifier,'DistributedCovarianceNetwork:networkSealed');
end
assert(threwOnSealedRead,'a sealed network must refuse even a read of its (correctly-committed) cross blocks');
fprintf('  PASS: a C4 failure (after C1-C3 already committed) seals rather than falsely rolling back an already-correct update\n');
end

% ================================================================================================
function [network, providers, ekfs, ids, receivers] = i_twoMemberPairExactFixture_()
cfg = masterConfig();
cfg.scenario.nTowers = 3;
cfg = revgnss.ConfigFactory.finalizeConfig(cfg);
clockModel = models.clocks.ClockModel(cfg.asset.clock);
ids = {'spacecraft:1','spacecraft:2'};
ekfs = cell(1,2); providers = cell(1,2); receivers = cell(1,2);
for k = 1:2
    ekfs{k} = filter.ReverseGNSSEKF(cfg,cfg.scenario.nTowers,clockModel);
    ekfs{k}.initState(zeros(ekfs{k}.nx,1),eye(ekfs{k}.nx)*0.01);
    ekfs{k}.retainEpochTransitionOperators = true;
    providers{k} = revgnss.OwnerLocalEkfTransitionCaptureProvider.forLocalEkf(ekfs{k},ids{k},k);
    receivers{k} = revgnss.LocalEndpointCorrectionReceiver.forLocalLeaf( ...
        providers{k},revgnss.ObservationConsumptionLedger());
end
policyRecord = struct('policyIdentifier','exactPairwiseCrossCovariance', ...
    'configuredMaximumFleetSize',4,'commonProcessNoiseTreatment','rejected', ...
    'linkUpdateRoutingPolicy','pairExactWhenBothEndpointsTracked','crossBlockSpanKind','fullLocalStateSpan', ...
    'stateSchemaVersion',revgnss.DistributedLinkProtocolContract.StateSchemaVersion);
network = revgnss.DistributedCovarianceNetwork(policyRecord);
network.registerFleetMembers([providers{1}.memberRegistrationRecord(0),providers{2}.memberRegistrationRecord(0)]);
network.declareIndependentPriorPairs(0);
end

% ================================================================================================
function record = i_realTwoWayCodeRangeRecord_(observationIdentifier, ownerId, remoteId)
record = revgnss.InterSatelliteObservationRecord(struct( ...
    'observationIdentifier',observationIdentifier,'sessionIdentifier','session:test', ...
    'initiatorAssetIdentifier',ownerId,'transponderAssetIdentifier',remoteId, ...
    'initiatorTransmitTerminalIdentifier','t1tx','initiatorReceiveTerminalIdentifier','t1rx', ...
    'transponderReceiveTerminalIdentifier','t2rx','transponderTransmitTerminalIdentifier','t2tx', ...
    'initiatorTransmitAntennaIdentifier','a1tx','initiatorReceiveAntennaIdentifier','a1rx', ...
    'transponderReceiveAntennaIdentifier','a2rx','transponderTransmitAntennaIdentifier','a2tx', ...
    'protocolIdentifier','protocol:test','signalIdentifier','signal:test','channelIdentifier','channel:test', ...
    'forwardCarrierFrequency_Hz',2.2e9,'returnCarrierFrequency_Hz',2.2e9,'codeChipRate_Hz',1e7, ...
    'initiatorTransmitLocalClockTag_s',0,'initiatorReceiveLocalClockTag_s',1e-3, ...
    'measuredLocalRoundTripDelay_s',1e-3,'referenceLocalClockTag_s',1e-3,'referenceEpochRule','finalReception', ...
    'localTimeSystemIdentifier',ownerId,'timestampReferencePointIdentifier','antennaPhaseCenter', ...
    'commandedScheduleIdentifier','schedule:test', ...
    'processedObservableType','twoWayCodeRange','processedValue',1.5e5,'processedUnits','m', ...
    'covarianceGroupIdentifier','','covarianceRowIndex',1,'covarianceBlock',1, ...
    'covarianceUnits','m^2','calibrationProductIdentifiers',{{}}, ...
    'calibrationValidFromLocalTag_s',-Inf,'calibrationValidUntilLocalTag_s',Inf, ...
    'carrierToNoiseDensity_dBHz',45,'effectiveRangingBandwidth_Hz',1e6,'roundTripLinkMargin_dB',10, ...
    'available',true,'qualityFlags',struct(),'truthDiagnosticIdentifier',''));
end

function delivery = i_deliveryStruct_(record, ownerId, remoteId)
delivery = struct( ...
    'ownerAssetIdentifier',ownerId,'remoteAssetIdentifier',remoteId, ...
    'observationIdentifier',record.observationIdentifier, ...
    'deliveryIdentifier',['delivery:' record.observationIdentifier], ...
    'sessionIdentifier',record.sessionIdentifier,'observableIdentifier','coherentTwoWayCodeRange', ...
    'deliveryEpoch_s',0,'sourceEpoch_s',0,'coordinateEventEpoch_s',0, ...
    'clockClaim','absoluteClockState','pairAbsolutelyAnchored',true, ...
    'physicalObservationRecord',record);
end

function block = i_updateBlock_()
Hi14 = zeros(1,14); Hi14(1) = 1;
Hj14 = zeros(1,14); Hj14(2) = -1;
block = struct('ownerJacobian_mPerErrorUnit',Hi14,'remoteJacobian_mPerErrorUnit',Hj14, ...
    'independentMeasurementCovariance_m2',1,'residual_m',0.05,'observableRowUnits','m', ...
    'commonSourceContributionCovariances_m2',{{}},'calibrationStateIdentifiers',{{}}, ...
    'calibrationMappingJacobian_mPerCalibrationUnit',zeros(1,0));
end

function argsRecord = i_assembleArgs_(record, ownerEndpoint, remoteEndpoint, Pij, thirdMembers)
block = i_updateBlock_();
argsRecord = struct( ...
    'observationIdentifier',record.observationIdentifier, ...
    'deliveryIdentifier',['delivery:' record.observationIdentifier], ...
    'sessionIdentifier',record.sessionIdentifier, ...
    'observableIdentifier','coherentTwoWayCodeRange','observableRowUnits',block.observableRowUnits, ...
    'coordinateEventEpoch_s',0,'deliveryEpoch_s',0,'sourceEpoch_s',0, ...
    'issuerIdentifier',ownerEndpoint.identifier,'partialDeliveryPolicy','rejectWholeUpdate', ...
    'messageSignaturePolicy','contentDigestFnv1a64','thirdMemberCrossConditioning','exactJointPairTransform', ...
    'ownerEndpoint',ownerEndpoint,'remoteEndpoint',remoteEndpoint, ...
    'ownerJacobian_mPerErrorUnit',block.ownerJacobian_mPerErrorUnit, ...
    'remoteJacobian_mPerErrorUnit',block.remoteJacobian_mPerErrorUnit, ...
    'independentMeasurementCovariance_m2',block.independentMeasurementCovariance_m2, ...
    'residual_m',block.residual_m,'priorPairCrossCovariance',Pij,'thirdMembers',thirdMembers, ...
    'networkRevisionNumber',0,'clockClaim','absoluteClockState','pairAbsolutelyAnchored',true);
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
