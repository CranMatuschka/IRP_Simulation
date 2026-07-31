function test_distributed_covariance_network_prediction_cross_block()
% test_distributed_covariance_network_prediction_cross_block  Plan Stage 3.1 items 1-2-4-7:
% revgnss.DistributedCovarianceNetwork's registration, independent-prior declaration, and the
% F/A-based cross-block propagation rule P_ij <- A_i*(F_i*P_ij*F_j'+Q_ij)*A_j', proven against
% real filter.ReverseGNSSEKF captures (not a synthetic F/A).

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
addpath(rootDir);
addpath(fullfile(rootDir,'config'));
addpath(fullfile(rootDir,'config','internal'));

fprintf('=== test_distributed_covariance_network_prediction_cross_block ===\n');
i_test_contract_self_consistency_();
i_test_zero_init_and_multi_epoch_propagation_();
i_test_non_core_coupling_after_a_correlated_local_update_();
i_test_conservative_owner_only_conditioning_and_third_member_signature_();
i_test_capture_guards_();
i_test_fleet_limit_at_network_layer_();
fprintf('=== test_distributed_covariance_network_prediction_cross_block: ALL PASS ===\n');
end

% ================================================================================================
function i_test_conservative_owner_only_conditioning_and_third_member_signature_()
% Section 2.4's applyConservativeOwnerOnlyLinkTransform, and the pure static
% conservativeOwnerOnlyErrorTransforms it is built from, have no other test coverage anywhere
% in the suite (revgnss.IndependentFleetCoordinator.applyOneLinkUpdate_ is the only production
% caller, and its sanctioned-tuple fixtures never exercise a genuine 3-member fleet). This is
% the direct, real-EKF proof: three real filter.ReverseGNSSEKF instances, a declared common-
% noise source seeding a real nonzero (2,3) cross block, a synthetic owner-only conservative
% transform for the (1,2) pair, and an exact check of the resulting P_13 against the design's
% own formula P_ik+ = A_i*P_ik + B_i*P_jk(S_j,:) -- the signature that a correlation network
% touches an UNINVOLVED third member.
cfg = masterConfig();
cfg.scenario.nTowers = 3;
cfg = revgnss.ConfigFactory.finalizeConfig(cfg);
clockModel = models.clocks.ClockModel(cfg.asset.clock);
ids = {'spacecraft:1','spacecraft:2','spacecraft:3'};
ekfs = cell(1,3); providers = cell(1,3);
for k = 1:3
    ekfs{k} = filter.ReverseGNSSEKF(cfg,cfg.scenario.nTowers,clockModel);
    x0 = zeros(ekfs{k}.nx,1); x0(1:3) = [7000e3+100*k;100;200]; x0(4:6) = [10;7500;20];
    ekfs{k}.initState(x0,eye(ekfs{k}.nx)*(5+k));
    ekfs{k}.retainEpochTransitionOperators = true;
    providers{k} = revgnss.OwnerLocalEkfTransitionCaptureProvider.forLocalEkf(ekfs{k},ids{k},k);
end

policyRecord = struct('policyIdentifier','exactPairwiseCrossCovariance', ...
    'configuredMaximumFleetSize',4,'commonProcessNoiseTreatment','declaredCommonAccelerationGroup', ...
    'linkUpdateRoutingPolicy','conservativeBoundOnly','crossBlockSpanKind','fullLocalStateSpan', ...
    'stateSchemaVersion',revgnss.DistributedLinkProtocolContract.StateSchemaVersion);
network = revgnss.DistributedCovarianceNetwork(policyRecord);
network.registerFleetMembers([providers{1}.memberRegistrationRecord(0),providers{2}.memberRegistrationRecord(0), ...
    providers{3}.memberRegistrationRecord(0)]);
network.declareIndependentPriorPairs(0);
commonGroup = revgnss.CommonProcessNoiseCovarianceGroup.fromRecord(struct( ...
    'processNoiseGroupIdentifier','group:23','commonSourceName','sharedForceAtmosphericProduct', ...
    'treatment','declaredCommonAccelerationGroup','memberEndpointIdentifiers',{{ids{2},ids{3}}}, ...
    'frameIdentifier','ECEF','commonAccelerationSigma_mps2',1e-4, ...
    'stateComponentPairing','positionVelocityPerAxis', ...
    'sourceConfigurationPath','estimator.processNoise.commonAcceleration', ...
    'validFromCoordinateEpoch_s',0,'validUntilCoordinateEpoch_s',1e9));
network.declareCommonProcessNoiseGroup(commonGroup);

towerClockModels = cell(1,cfg.scenario.nTowers);
for k = 1:cfg.scenario.nTowers; towerClockModels{k} = clockModel; end
dt = 1.0;
captures = revgnss.LocalEpochTransitionCapture.empty;
for k = 1:3
    ekfs{k}.predict(dt,towerClockModels,0);
    H = zeros(1,ekfs{k}.nx); H(1) = 1;
    ekfs{k}.update(ekfs{k}.x(1)+0.3,ekfs{k}.x(1),H,25);
    captures(k) = providers{k}.takeEpochCapture(0,dt); %#ok<AGROW>
end
network.advanceEpoch(struct('coordinateEpoch_s',dt,'intervalDuration_s',dt,'captures',captures));
% (2,3) must now carry a genuine nonzero cross block from the declared common source; (1,2) and
% (1,3) remain exactly zero (no source declared for either).
P23 = network.orientedCrossCovariance(ids{2},ids{3});
assert(nnz(P23) > 0,'the declared common-noise source between 2 and 3 must seed a nonzero (2,3) cross block');
P13Before = network.orientedCrossCovariance(ids{1},ids{3});
assert(nnz(P13Before) == 0,'(1,3) must still be exactly zero before any owner-only conditioning touches it');

% Synthetic owner-only conservative transform: owner=1, remote=2, third member=3. Build a real
% (A,B) pair via conservativeOwnerOnlyErrorTransforms from a plausible certified conservative
% gain touching only the owner's schema position row (mirrors what
% ConservativeFullStateLinkUpdate.applyOwnerOnlyUpdate actually returns in production).
schema1 = providers{1}.schemaStateIndices();
schema2 = providers{2}.schemaStateIndices();
n1 = ekfs{1}.nx;
HiFull = zeros(1,n1); HiFull(schema1(1)) = 1;
Hj = zeros(1,14); Hj(1) = 1;
P11 = (ekfs{1}.P+ekfs{1}.P')/2;
R_link = 100;
S_link = HiFull*P11*HiFull'+R_link;
Kfull = P11*HiFull'/S_link;   % n1 x 1, nonzero only where P11's own column 1 is nonzero
attitudeResetJacobian = eye(3);   % eulerZYX mode: no reset
[A, B] = revgnss.DistributedCovarianceNetwork.conservativeOwnerOnlyErrorTransforms(struct( ...
    'gainFull',Kfull,'ownerJacobianFull',HiFull,'remoteJacobian',Hj, ...
    'attitudeResetJacobian',attitudeResetJacobian,'schemaStateIndices',schema1));

P22 = (ekfs{2}.P+ekfs{2}.P')/2;
P33Live = (ekfs{3}.P+ekfs{3}.P')/2;
network.applyConservativeOwnerOnlyLinkTransform(struct( ...
    'ownerEndpointIdentifier',ids{1},'remoteEndpointIdentifier',ids{2}, ...
    'coordinateEpoch_s',dt,'ownerErrorTransition_A',A,'remoteSchemaErrorCoupling_B',B, ...
    'remoteLocalMarginalSupply',struct('endpointIdentifier',{ids{2},ids{3}},'localMarginal',{P22,P33Live})));

P13After = network.orientedCrossCovariance(ids{1},ids{3});
changeNorm = norm(P13After-P13Before,'fro');
fprintf('  ||P13_after-P13_before||_fro = %.3e (third-member signature)\n',changeNorm);
assert(changeNorm > 1e-14, ...
    'expected P13 (the uninvolved third member) to change after an owner-only conditioning for the (1,2) pair');

P13Ref = A*P13Before+B*P23(schema2,:);
errP13 = norm(P13After-P13Ref,'fro')/max(1,norm(P13Ref,'fro'));
fprintf('  P13 conditioning relative error vs design formula P_ik+ = A*P_ik + B*P_jk(S_j,:): %.3e\n',errP13);
assert(errP13 < 1e-9,'P13 after conditioning does not match the design formula P_ik+ = A*P_ik + B*P_jk(S_j,:)');

P23AfterCall = network.orientedCrossCovariance(ids{2},ids{3});
assert(isequal(P23,P23AfterCall), ...
    'the (2,3) pair (uninvolved in the owner-only transform) must be left completely unchanged');

claim = network.centralReferenceEquivalenceClaim();
assert(strcmp(claim,'conditionedOnConservativeOwnerOnlyUpdatesNoFleetBoundClaimed'), ...
    'expected the downgraded equivalence claim after a conservative owner-only conditioning');
fprintf('  PASS Section 2.4 conditioning + third-member signature: exact match to A*P_ik+B*P_jk(S_j,:)\n');
end

% ================================================================================================
function i_test_contract_self_consistency_()
revgnss.DistributedCovarianceNetworkContract.requireEpochPhaseOrderExtendsStageTwo();
stageTwo = revgnss.DistributedLinkProtocolContract.EpochFinalizationPhaseOrder;
assert(isequal(stageTwo, { ...
    'advanceSharedTruthAndLocalPrediction','localGroundOnboardUpdate', ...
    'publishAndFreezeEstimatorProducts','generateValidateDeliverLinkRecords', ...
    'ownerOnlyLinkUpdate','commitLocalHistoryAndConsumption'}), ...
    'the frozen Stage-2 phase order must be byte-identical to its pre-Stage-3.1 value');

cfg = masterConfig();
cfg.scenario.nTowers = 3;
cfg = revgnss.ConfigFactory.finalizeConfig(cfg);
clockModel = models.clocks.ClockModel(cfg.asset.clock);
ekf = filter.ReverseGNSSEKF(cfg,cfg.scenario.nTowers,clockModel);
idx = revgnss.DistributedCovarianceNetworkContract.schemaStateIndicesFromStateMap(ekf.stateMap,1);
expected = [ekf.stateMap.r_idx(:);ekf.stateMap.v_idx(:);ekf.stateMap.euler_idx(:); ...
    ekf.stateMap.omega_idx(:);ekf.stateMap.b_rx_idx;ekf.stateMap.bdot_rx_idx];
assert(isequal(idx,expected),'schemaStateIndicesFromStateMap must match the literal 14-index concatenation');
fprintf('  PASS contract self-consistency\n');
end

% ================================================================================================
function i_test_zero_init_and_multi_epoch_propagation_()
[network, providers, ekfs, ids] = i_threeMemberNetwork_();
for i = 1:3
    for j = i+1:3
        M = network.orientedCrossCovariance(ids{i},ids{j});
        assert(nnz(M) == 0,'every cross block must be exactly zero at registration');
    end
end

cfg = ekfs{1}.cfg;
towerClockModels = cell(1,cfg.scenario.nTowers);
clockModel = ekfs{1}.rxClockModel;
for k = 1:cfg.scenario.nTowers; towerClockModels{k} = clockModel; end
dt = 1.0;
tEpoch = 0.0;
worstErr = 0;
priorPij = struct();
for epochNum = 1:3
    captures = revgnss.LocalEpochTransitionCapture.empty;
    for k = 1:3
        ekfs{k}.predict(dt,towerClockModels,tEpoch);
        H = zeros(1,ekfs{k}.nx); H(1) = 1;
        z = ekfs{k}.x(1)+0.2; h = ekfs{k}.x(1); R = 25;
        ekfs{k}.update(z,h,H,R);
        captures(k) = providers{k}.takeEpochCapture(tEpoch,dt); %#ok<AGROW>
    end
    tEpoch = tEpoch+dt;
    epochRecord = struct('coordinateEpoch_s',tEpoch,'intervalDuration_s',dt,'captures',captures);
    network.advanceEpoch(epochRecord);

    for i = 1:3
        for j = i+1:3
            key = sprintf('p%d%d',i,j);
            if epochNum == 1
                priorPij.(key) = zeros(ekfs{i}.nx,ekfs{j}.nx);
            end
            Fi = captures(i).stateTransition; Ai = captures(i).localUpdateContraction;
            Fj = captures(j).stateTransition; Aj = captures(j).localUpdateContraction;
            ref = Ai*(Fi*priorPij.(key)*Fj')*Aj';
            got = network.orientedCrossCovariance(ids{i},ids{j});
            err = norm(got-ref,'fro')/max(1,norm(ref,'fro'));
            worstErr = max(worstErr,err);
            priorPij.(key) = got;
        end
    end
end
fprintf('  worst multi-epoch propagation relative error: %.3e\n',worstErr);
assert(worstErr < 1e-9,'advanceEpoch propagation does not match the F/A reference over 3 epochs');
assert(network.epochsAdvanced == 3,'expected epochsAdvanced==3');
fprintf('  PASS zero-init and multi-epoch propagation matches the F/A reference\n');
end

% ================================================================================================
function i_test_non_core_coupling_after_a_correlated_local_update_()
% With tower-clock (non-core) states genuinely correlated to position (core) in a leaf's OWN
% prior, a real local ground update's Kalman gain touches both blocks -- so the RETAINED A_i is
% not block-diagonal, and the propagated cross block develops nonzero (nonCore_i, core_j)
% entries. This is a property of the REAL local filter's own update, not of the Stage-2
% conservative owner-only conditioning (whose gain is embedded on the 14 schema rows only).
cfg = masterConfig();
cfg.scenario.nTowers = 2;
cfg.clock.mode = 'includeTowerClocksInEKF';
cfg = revgnss.ConfigFactory.finalizeConfig(cfg);
clockModel = models.clocks.ClockModel(cfg.asset.clock);

ekfA = filter.ReverseGNSSEKF(cfg,cfg.scenario.nTowers,clockModel);
ekfB = filter.ReverseGNSSEKF(cfg,cfg.scenario.nTowers,clockModel);
x0 = zeros(ekfA.nx,1); x0(1:3) = [7000e3;0;0]; x0(4:6) = [0;7500;0];
P0 = eye(ekfA.nx);
towerClockIdx = ekfA.stateMap.towerClockIdx(1,1);
P0(1,1) = 100; P0(towerClockIdx,towerClockIdx) = 100;
P0(1,towerClockIdx) = 20; P0(towerClockIdx,1) = 20;   % genuine, PSD, core<->nonCore correlation
ekfA.initState(x0,P0); ekfB.initState(x0,eye(ekfB.nx));
ekfA.retainEpochTransitionOperators = true; ekfB.retainEpochTransitionOperators = true;
provA = revgnss.OwnerLocalEkfTransitionCaptureProvider.forLocalEkf(ekfA,'spacecraft:1',1);
provB = revgnss.OwnerLocalEkfTransitionCaptureProvider.forLocalEkf(ekfB,'spacecraft:2',2);

policyRecord = struct('policyIdentifier','exactPairwiseCrossCovariance', ...
    'configuredMaximumFleetSize',2,'commonProcessNoiseTreatment','declaredCommonAccelerationGroup', ...
    'linkUpdateRoutingPolicy','conservativeBoundOnly','crossBlockSpanKind','fullLocalStateSpan', ...
    'stateSchemaVersion',revgnss.DistributedLinkProtocolContract.StateSchemaVersion);
network = revgnss.DistributedCovarianceNetwork(policyRecord);
network.registerFleetMembers([provA.memberRegistrationRecord(0),provB.memberRegistrationRecord(0)]);
network.declareIndependentPriorPairs(0);
commonGroup = revgnss.CommonProcessNoiseCovarianceGroup.fromRecord(struct( ...
    'processNoiseGroupIdentifier','group:AB','commonSourceName','sharedForceAtmosphericProduct', ...
    'treatment','declaredCommonAccelerationGroup','memberEndpointIdentifiers',{{'spacecraft:1','spacecraft:2'}}, ...
    'frameIdentifier','ECEF','commonAccelerationSigma_mps2',0.5, ...
    'stateComponentPairing','positionVelocityPerAxis', ...
    'sourceConfigurationPath','estimator.processNoise.commonAcceleration', ...
    'validFromCoordinateEpoch_s',0,'validUntilCoordinateEpoch_s',1e9));
network.declareCommonProcessNoiseGroup(commonGroup);

towerClockModels = {clockModel,clockModel};
dt = 1.0;

% Epoch 1: plain predict+trivial position-only updates, with a declared common-acceleration
% source between A and B -- seeds a nonzero CORE-core cross block via Q_AB (no coupling to the
% non-core tower-clock row yet, since neither update touches it).
ekfA.predict(dt,towerClockModels,0);
ekfB.predict(dt,towerClockModels,0);
Ha = zeros(1,ekfA.nx); Ha(1) = 1;
ekfA.update(ekfA.x(1)+0.1,ekfA.x(1),Ha,25);
Hb = zeros(1,ekfB.nx); Hb(1) = 1;
ekfB.update(ekfB.x(1)+0.1,ekfB.x(1),Hb,25);
network.advanceEpoch(struct('coordinateEpoch_s',dt,'intervalDuration_s',dt, ...
    'captures',[provA.takeEpochCapture(0,dt),provB.takeEpochCapture(0,dt)]));
M1 = network.orientedCrossCovariance('spacecraft:1','spacecraft:2');
assert(M1(1,1) ~= 0,'epoch 1 must seed a nonzero core-core cross entry via the declared common source');

% Epoch 2: A real ground row on member A that measures BOTH position and the correlated tower-
% clock state together -- this is what mixes core and non-core rows through A_A's own Kalman
% gain (not through the Stage-2 conservative owner-only path, which never touches this).
ekfA.predict(dt,towerClockModels,dt);
ekfB.predict(dt,towerClockModels,dt);
H = zeros(1,ekfA.nx); H(1) = 1; H(towerClockIdx) = 1;
z = ekfA.x(1)+ekfA.x(towerClockIdx)+0.1; h = ekfA.x(1)+ekfA.x(towerClockIdx); R = 25;
ekfA.update(z,h,H,R);
ekfB.update(ekfB.x(1)+0.1,ekfB.x(1),Hb,25);
network.advanceEpoch(struct('coordinateEpoch_s',2*dt,'intervalDuration_s',dt, ...
    'captures',[provA.takeEpochCapture(dt,dt),provB.takeEpochCapture(dt,dt)]));

M2 = network.orientedCrossCovariance('spacecraft:1','spacecraft:2');
nonCoreRow = towerClockIdx;
fprintf('  non-core row max abs entry: %.3e\n',max(abs(M2(nonCoreRow,:))));
assert(any(M2(nonCoreRow,:) ~= 0), ...
    'expected the owner''s non-core (tower-clock) row of the cross block to be nonzero');
fprintf('  PASS non-core coupling proof (a 14-core-only network cannot pass this)\n');
end

% ================================================================================================
function i_test_capture_guards_()
[network, providers, ekfs, ids] = i_threeMemberNetwork_(); %#ok<ASGLU>
cfg = ekfs{1}.cfg;
towerClockModels = cell(1,cfg.scenario.nTowers);
for k = 1:cfg.scenario.nTowers; towerClockModels{k} = ekfs{1}.rxClockModel; end

% Capture-member-set mismatch: supply only 2 of 3.
ekfs{1}.predict(1,towerClockModels,0); ekfs{2}.predict(1,towerClockModels,0);
c1 = providers{1}.takeEpochCapture(0,1);
c2 = providers{2}.takeEpochCapture(0,1);
threw = false;
try
    network.advanceEpoch(struct('coordinateEpoch_s',1,'intervalDuration_s',1,'captures',[c1,c2]));
catch ME
    threw = strcmp(ME.identifier,'DistributedCovarianceNetwork:captureMemberMismatch');
end
assert(threw,'expected captureMemberMismatch for an incomplete capture set');

% Double-take.
ekfs{3}.predict(1,towerClockModels,0);
providers{3}.takeEpochCapture(0,1);
threw2 = false;
try
    providers{3}.takeEpochCapture(0,1);
catch ME2
    threw2 = strcmp(ME2.identifier,'ReverseGNSSEKF:epochTransitionCaptureNotOpen');
end
assert(threw2,'expected epochTransitionCaptureNotOpen on a second take with no intervening predict()');

% Unaccounted external write.
ekfs{3}.predict(1,towerClockModels,1);
ekfs{3}.P(1,1) = ekfs{3}.P(1,1)+1;
threw3 = false;
try
    providers{3}.takeEpochCapture(1,1);
catch ME3
    threw3 = strcmp(ME3.identifier,'ReverseGNSSEKF:unaccountedCovarianceMutation');
end
assert(threw3,'expected unaccountedCovarianceMutation on an unwatermarked external P write');
fprintf('  PASS capture guards (member mismatch, double-take, unaccounted write)\n');
end

% ================================================================================================
function i_test_fleet_limit_at_network_layer_()
[~, providers, ~, ~] = i_threeMemberNetwork_(); % configuredMaximumFleetSize=4; the network built below with a limit of 2 is what makes registration fail
policyRecord = struct('policyIdentifier','exactPairwiseCrossCovariance', ...
    'configuredMaximumFleetSize',2,'commonProcessNoiseTreatment','rejected', ...
    'linkUpdateRoutingPolicy','conservativeBoundOnly','crossBlockSpanKind','fullLocalStateSpan', ...
    'stateSchemaVersion',revgnss.DistributedLinkProtocolContract.StateSchemaVersion);
network = revgnss.DistributedCovarianceNetwork(policyRecord);
memberRecords = [providers{1}.memberRegistrationRecord(0),providers{2}.memberRegistrationRecord(0), ...
    providers{3}.memberRegistrationRecord(0)];
threw = false;
try
    network.registerFleetMembers(memberRecords);
catch ME
    threw = strcmp(ME.identifier,'DistributedCovarianceNetwork:fleetSizeLimitExceeded');
end
assert(threw,'expected fleetSizeLimitExceeded when registering 3 members under a limit of 2');
assert(isempty(network.crossBlockIdentifiers()),'no partial cross block may exist after a refused registration');
fprintf('  PASS fleet-size limit fails rather than silently drops a cross block\n');
end

% ================================================================================================
function [network, providers, ekfs, ids] = i_threeMemberNetwork_()
cfg = masterConfig();
cfg.scenario.nTowers = 3;
cfg = revgnss.ConfigFactory.finalizeConfig(cfg);
clockModel = models.clocks.ClockModel(cfg.asset.clock);
ids = {'spacecraft:1','spacecraft:2','spacecraft:3'};
ekfs = cell(1,3); providers = cell(1,3);
for k = 1:3
    ekfs{k} = filter.ReverseGNSSEKF(cfg,cfg.scenario.nTowers,clockModel);
    x0 = zeros(ekfs{k}.nx,1); x0(1:3) = [7000e3+100*k;100;200]; x0(4:6) = [10;7500;20];
    ekfs{k}.initState(x0,eye(ekfs{k}.nx)*(5+k));
    ekfs{k}.retainEpochTransitionOperators = true;
    providers{k} = revgnss.OwnerLocalEkfTransitionCaptureProvider.forLocalEkf(ekfs{k},ids{k},k);
end
policyRecord = struct('policyIdentifier','exactPairwiseCrossCovariance', ...
    'configuredMaximumFleetSize',4,'commonProcessNoiseTreatment','rejected', ...
    'linkUpdateRoutingPolicy','conservativeBoundOnly','crossBlockSpanKind','fullLocalStateSpan', ...
    'stateSchemaVersion',revgnss.DistributedLinkProtocolContract.StateSchemaVersion);
network = revgnss.DistributedCovarianceNetwork(policyRecord);
memberRecords = [providers{1}.memberRegistrationRecord(0),providers{2}.memberRegistrationRecord(0), ...
    providers{3}.memberRegistrationRecord(0)];
network.registerFleetMembers(memberRecords);
network.declareIndependentPriorPairs(0);
end
