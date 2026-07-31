function test_distributed_common_product_cross_covariance()
% test_distributed_common_product_cross_covariance  Plan Stage 3.1 item 3, required reference
% test 3: revgnss.CommonProcessNoiseCovarianceGroup generalizes
% filter.ReverseGNSSEKF.addJointAssetProcessNoise_'s qCommon placement, cross-checked against
% the REAL joint EKF path, then against a hand-built centralized reference over several epochs.
% Also proves the live-path refusal (declaredCommonAccelerationGroup is refused on the
% coordinator path today).

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
addpath(rootDir);
addpath(fullfile(rootDir,'config'));
addpath(fullfile(rootDir,'config','internal'));

fprintf('=== test_distributed_common_product_cross_covariance ===\n');
i_test_cross_process_noise_matches_joint_path_();
i_test_centralized_reference_over_multiple_epochs_();
i_test_group_membership_and_schema_refusals_();
i_test_live_path_refusal_();
fprintf('=== test_distributed_common_product_cross_covariance: ALL PASS ===\n');
end

% ================================================================================================
function i_test_cross_process_noise_matches_joint_path_()
% Q1+Q2: build a real 2-asset JOINT filter.ReverseGNSSEKF with commonAcceleration enabled, call
% predict(), and compare the group's crossProcessNoise element-for-element with the joint path's
% own Q(asset1_rv,asset2_rv) cross block.
cfg = masterConfig();
cfg.scenario.nSpaceAssets = 2;
cfg.multiAsset.mode = 'joint';
cfg.estimator.processNoise.commonAcceleration.enable = true;
cfg.estimator.processNoise.commonAcceleration.sigma_mps2 = 0.02;
cfg = revgnss.ConfigFactory.finalizeConfig(cfg);
clockModel = models.clocks.ClockModel(cfg.asset.clock);
jointEkf = filter.ReverseGNSSEKF(cfg,cfg.scenario.nTowers,clockModel);
jointEkf.initState(zeros(jointEkf.nx,1),eye(jointEkf.nx));
towerClockModels = cell(1,cfg.scenario.nTowers);
for k = 1:cfg.scenario.nTowers; towerClockModels{k} = clockModel; end
dt = 1.0;
jointEkf.predict(dt,towerClockModels,0);
Qjoint = jointEkf.buildQ_(dt,towerClockModels);
Qjoint = jointEkf.addJointAssetProcessNoise_(Qjoint,dt,{clockModel,clockModel});

primaryRv = [jointEkf.stateMap.r_idx(:);jointEkf.stateMap.v_idx(:)];
secondaryBlk = jointEkf.stateMap.asset(2);
secondaryRv = [secondaryBlk.r(:);secondaryBlk.v(:)];
QjointCross = Qjoint(primaryRv,secondaryRv);

group = revgnss.CommonProcessNoiseCovarianceGroup.fromRecord(struct( ...
    'processNoiseGroupIdentifier','group:1','commonSourceName','sharedForceAtmosphericProduct', ...
    'treatment','declaredCommonAccelerationGroup','memberEndpointIdentifiers',{{'spacecraft:1','spacecraft:2'}}, ...
    'frameIdentifier','ECEF','commonAccelerationSigma_mps2',0.02, ...
    'stateComponentPairing','positionVelocityPerAxis', ...
    'sourceConfigurationPath','estimator.processNoise.commonAcceleration', ...
    'validFromCoordinateEpoch_s',0,'validUntilCoordinateEpoch_s',1e9));
firstSchema = revgnss.DistributedCovarianceNetworkContract.schemaStateIndicesFromStateMap(jointEkf.stateMap,1);
secondSchema = revgnss.DistributedCovarianceNetworkContract.schemaStateIndicesFromStateMap(jointEkf.stateMap,2);
Qij = group.crossProcessNoise(dt,firstSchema,secondSchema,jointEkf.nx,jointEkf.nx);
QijAtRv = Qij(primaryRv,secondaryRv);

err = norm(QijAtRv-QjointCross,'fro')/max(1,norm(QjointCross,'fro'));
fprintf('  relative error vs real joint-EKF Q cross block: %.3e\n',err);
assert(err < 1e-12,'CommonProcessNoiseCovarianceGroup.crossProcessNoise must match addJointAssetProcessNoise_ exactly');
fprintf('  PASS Q1/Q2: crossProcessNoise matches the real joint-EKF path element-for-element\n');
end

% ================================================================================================
function i_test_centralized_reference_over_multiple_epochs_()
% Q3: independent-fleet network with the group declared, propagated over 3 epochs, matches a
% hand-built 2n-state centralized reference whose Q carries qCommon on BOTH diagonal and
% off-diagonal blocks.
cfg = masterConfig();
cfg.scenario.nTowers = 3;
cfg = revgnss.ConfigFactory.finalizeConfig(cfg);
clockModel = models.clocks.ClockModel(cfg.asset.clock);
ekfA = filter.ReverseGNSSEKF(cfg,cfg.scenario.nTowers,clockModel);
ekfB = filter.ReverseGNSSEKF(cfg,cfg.scenario.nTowers,clockModel);
x0 = zeros(ekfA.nx,1); x0(1:3) = [7000e3;0;0]; x0(4:6) = [0;7500;0];
ekfA.initState(x0,eye(ekfA.nx)); ekfB.initState(x0,eye(ekfB.nx));
ekfA.retainEpochTransitionOperators = true; ekfB.retainEpochTransitionOperators = true;
provA = revgnss.OwnerLocalEkfTransitionCaptureProvider.forLocalEkf(ekfA,'spacecraft:1',1);
provB = revgnss.OwnerLocalEkfTransitionCaptureProvider.forLocalEkf(ekfB,'spacecraft:2',2);

sigma = 0.03;
policyRecord = struct('policyIdentifier','exactPairwiseCrossCovariance', ...
    'configuredMaximumFleetSize',2,'commonProcessNoiseTreatment','declaredCommonAccelerationGroup', ...
    'linkUpdateRoutingPolicy','conservativeBoundOnly','crossBlockSpanKind','fullLocalStateSpan', ...
    'stateSchemaVersion',revgnss.DistributedLinkProtocolContract.StateSchemaVersion);
network = revgnss.DistributedCovarianceNetwork(policyRecord);
network.registerFleetMembers([provA.memberRegistrationRecord(0),provB.memberRegistrationRecord(0)]);
network.declareIndependentPriorPairs(0);
group = revgnss.CommonProcessNoiseCovarianceGroup.fromRecord(struct( ...
    'processNoiseGroupIdentifier','group:1','commonSourceName','sharedForceAtmosphericProduct', ...
    'treatment','declaredCommonAccelerationGroup','memberEndpointIdentifiers',{{'spacecraft:1','spacecraft:2'}}, ...
    'frameIdentifier','ECEF','commonAccelerationSigma_mps2',sigma, ...
    'stateComponentPairing','positionVelocityPerAxis', ...
    'sourceConfigurationPath','estimator.processNoise.commonAcceleration', ...
    'validFromCoordinateEpoch_s',0,'validUntilCoordinateEpoch_s',1e9));
network.declareCommonProcessNoiseGroup(group);

n = ekfA.nx;
Pref = blkdiag(eye(n),eye(n));
towerClockModels = cell(1,cfg.scenario.nTowers);
for k = 1:cfg.scenario.nTowers; towerClockModels{k} = clockModel; end
dt = 1.0; t = 0.0;
qCommon = sigma^2*[dt^3/3,dt^2/2;dt^2/2,dt];
worstErr = 0;
for epochNum = 1:3
    ekfA.predict(dt,towerClockModels,t); ekfB.predict(dt,towerClockModels,t);
    Ha = zeros(1,n); Ha(1) = 1; ekfA.update(ekfA.x(1)+0.1,ekfA.x(1),Ha,25);
    Hb = zeros(1,n); Hb(1) = 1; ekfB.update(ekfB.x(1)+0.1,ekfB.x(1),Hb,25);
    capA = provA.takeEpochCapture(t,dt); capB = provB.takeEpochCapture(t,dt);
    t = t+dt;
    network.advanceEpoch(struct('coordinateEpoch_s',t,'intervalDuration_s',dt,'captures',[capA,capB]));

    Fa = capA.stateTransition; Aa = capA.localUpdateContraction;
    Fb = capB.stateTransition; Ab = capB.localUpdateContraction;
    Fjoint = blkdiag(Fa,Fb);
    Ajoint = blkdiag(Aa,Ab);
    Qjoint = zeros(2*n,2*n);
    for axisIdx = 1:3
        piA = [axisIdx,3+axisIdx]; piB = n+[axisIdx,3+axisIdx];
        Qjoint(piA,piA) = Qjoint(piA,piA)+qCommon;
        Qjoint(piB,piB) = Qjoint(piB,piB)+qCommon;
        Qjoint(piA,piB) = Qjoint(piA,piB)+qCommon;
        Qjoint(piB,piA) = Qjoint(piB,piA)+qCommon;
    end
    Pref = Ajoint*(Fjoint*Pref*Fjoint'+Qjoint)*Ajoint';

    got = network.orientedCrossCovariance('spacecraft:1','spacecraft:2');
    ref = Pref(1:n,n+1:end);
    err = norm(got-ref,'fro')/max(1,norm(ref,'fro'));
    worstErr = max(worstErr,err);
end
fprintf('  worst relative error vs 3-epoch centralized reference: %.3e\n',worstErr);
assert(worstErr < 1e-9,'network cross block does not match the hand-built centralized reference');
fprintf('  PASS Q3/Q4: matches a 3-epoch centralized reference with qCommon on both blocks\n');
end

% ================================================================================================
function i_test_group_membership_and_schema_refusals_()
% Q5: a group naming a non-member contributes nothing; SchemaUnavailableTreatments refused by name.
[network, providers, ~, ids] = i_twoMemberNetwork_(); %#ok<ASGLU>
group = revgnss.CommonProcessNoiseCovarianceGroup.fromRecord(struct( ...
    'processNoiseGroupIdentifier','group:x','commonSourceName','sharedForceAtmosphericProduct', ...
    'treatment','declaredCommonAccelerationGroup','memberEndpointIdentifiers',{{'spacecraft:1','spacecraft:99'}}, ...
    'frameIdentifier','ECEF','commonAccelerationSigma_mps2',0.1, ...
    'stateComponentPairing','positionVelocityPerAxis', ...
    'sourceConfigurationPath','estimator.processNoise.commonAcceleration', ...
    'validFromCoordinateEpoch_s',0,'validUntilCoordinateEpoch_s',1e9));
threw = false;
try
    network.declareCommonProcessNoiseGroup(group);
catch ME
    threw = strcmp(ME.identifier,'DistributedCovarianceNetwork:commonProcessNoiseGroupUnknownMember');
end
assert(threw,'a group naming a non-registered member must be refused');

for treatment = {'estimatedOwnerState','externalCovarianceProduct'}
    threwSchema = false;
    try
        revgnss.CommonProcessNoiseCovarianceGroup.fromRecord(struct( ...
            'processNoiseGroupIdentifier','group:y','commonSourceName','sharedForceAtmosphericProduct', ...
            'treatment',treatment{1},'memberEndpointIdentifiers',{{'spacecraft:1','spacecraft:2'}}, ...
            'frameIdentifier','ECEF','commonAccelerationSigma_mps2',0.1, ...
            'stateComponentPairing','positionVelocityPerAxis', ...
            'sourceConfigurationPath','estimator.processNoise.commonAcceleration', ...
            'validFromCoordinateEpoch_s',0,'validUntilCoordinateEpoch_s',1e9));
    catch ME2
        threwSchema = strcmp(ME2.identifier,'CommonProcessNoiseCovarianceGroup:schemaUnavailableTreatment');
    end
    assert(threwSchema,'treatment ''%s'' must be refused by name',treatment{1});
end
fprintf('  PASS Q5: non-member group refused; estimatedOwnerState/externalCovarianceProduct refused by name\n');
end

% ================================================================================================
function i_test_live_path_refusal_()
% Q6: live coordinator path refuses declaredCommonAccelerationGroup, and refuses
% cfg.estimator.processNoise.commonAcceleration.enable=true together with an enabled network.
cfg = i_twoAssetFleetCfg_();
cfg.multiAsset.distributedEstimator.correlationNetwork.policy = 'exactPairwiseCrossCovariance';
cfg.multiAsset.distributedEstimator.correlationNetwork.maximumFleetSize = 2;
cfg.multiAsset.distributedEstimator.correlationNetwork.commonProcessNoiseTreatment = ...
    'declaredCommonAccelerationGroup';
threw = false;
try
    revgnss.IndependentFleetCoordinator.validateConfig(revgnss.ConfigFactory.finalizeConfig(cfg));
catch ME
    threw = strcmp(ME.identifier,'IndependentFleetCoordinator:commonProcessNoiseTreatmentUnavailableOnLivePath');
end
assert(threw,'declaredCommonAccelerationGroup must be refused on the live coordinator path');

cfg2 = i_twoAssetFleetCfg_();
cfg2.multiAsset.distributedEstimator.correlationNetwork.policy = 'exactPairwiseCrossCovariance';
cfg2.multiAsset.distributedEstimator.correlationNetwork.maximumFleetSize = 2;
cfg2.estimator.processNoise.commonAcceleration.enable = true;
threw2 = false;
try
    revgnss.IndependentFleetCoordinator.validateConfig(revgnss.ConfigFactory.finalizeConfig(cfg2));
catch ME2
    threw2 = strcmp(ME2.identifier,'IndependentFleetCoordinator:commonProcessNoiseUndeclared');
end
assert(threw2,'commonAcceleration.enable=true with an enabled network must be refused');
fprintf('  PASS Q6: live-path refusals fire as designed\n');
end

% ================================================================================================
function [network, providers, ekfs, ids] = i_twoMemberNetwork_()
cfg = masterConfig();
cfg.scenario.nTowers = 3;
cfg = revgnss.ConfigFactory.finalizeConfig(cfg);
clockModel = models.clocks.ClockModel(cfg.asset.clock);
ids = {'spacecraft:1','spacecraft:2'};
ekfs = cell(1,2); providers = cell(1,2);
for k = 1:2
    ekfs{k} = filter.ReverseGNSSEKF(cfg,cfg.scenario.nTowers,clockModel);
    ekfs{k}.initState(zeros(ekfs{k}.nx,1),eye(ekfs{k}.nx));
    ekfs{k}.retainEpochTransitionOperators = true;
    providers{k} = revgnss.OwnerLocalEkfTransitionCaptureProvider.forLocalEkf(ekfs{k},ids{k},k);
end
policyRecord = struct('policyIdentifier','exactPairwiseCrossCovariance', ...
    'configuredMaximumFleetSize',2,'commonProcessNoiseTreatment','declaredCommonAccelerationGroup', ...
    'linkUpdateRoutingPolicy','conservativeBoundOnly','crossBlockSpanKind','fullLocalStateSpan', ...
    'stateSchemaVersion',revgnss.DistributedLinkProtocolContract.StateSchemaVersion);
network = revgnss.DistributedCovarianceNetwork(policyRecord);
network.registerFleetMembers([providers{1}.memberRegistrationRecord(0),providers{2}.memberRegistrationRecord(0)]);
network.declareIndependentPriorPairs(0);
end

function cfg = i_twoAssetFleetCfg_()
cfg = masterConfig();
cfg.scenario.nSpaceAssets = 2;
cfg.multiAsset.mode = 'fast';
cfg.multiAsset.distributedEstimator.enable = true;
cfg.multiAsset.distributedEstimator.deliveryLedger.enable = true;
end
