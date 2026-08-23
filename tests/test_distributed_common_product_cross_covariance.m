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
% Q6 (Section 3.3 update): declaredCommonAccelerationGroup is NO LONGER refused on the live
% coordinator path -- Section 3.3 closed the diagonal-buildQ_ gap this refusal used to name (see
% filter.ReverseGNSSEKF.declaredCommonProcessNoiseGroup_ and this coordinator's own initialize()
% wiring). This subtest now proves the OPPOSITE of what it originally proved: a positive-sigma
% declaration validates cleanly end-to-end through the real coordinator; a non-positive-sigma
% declaration is refused as a pointless declaration (the NEW guard replacing the old blanket
% refusal); and the sibling commonAcceleration.enable=true guard is untouched.
cfg = i_twoAssetFleetCfg_();
cfg.multiAsset.distributedEstimator.correlationNetwork.policy = 'exactPairwiseCrossCovariance';
cfg.multiAsset.distributedEstimator.correlationNetwork.maximumFleetSize = 2;
cfg.multiAsset.distributedEstimator.correlationNetwork.commonProcessNoiseTreatment = ...
    'declaredCommonAccelerationGroup';
cfg.multiAsset.distributedEstimator.correlationNetwork.commonProcessNoise.sigma_mps2 = 1e-3;
% validateConfig itself must no longer throw for this now-legal combination.
revgnss.IndependentFleetCoordinator.validateConfig(revgnss.ConfigFactory.finalizeConfig(cfg));
fprintf('  PASS Q6a: declaredCommonAccelerationGroup with sigma_mps2>0 validates cleanly (no longer refused)\n');

% The real coordinator must run end-to-end and every leaf must receive the identical declared
% group value, matching the network's own declared group by construction (no parallel formula).
% revgnss.CommonProcessNoiseCovarianceGroup is a MATLAB value class (immutable properties, no
% mutators), so isequal is the meaningful check here -- there is no handle-style "same instance."
cfg.simulation.duration_s = 4; cfg.simulation.dt_s = 1;
cfg.report.writePdf = false; cfg.report.writeMat = false; cfg.report.compileTex = 'never';
cfg.plots.enable = false; cfg.plots.showFigures = false;
coordinator = revgnss.IndependentFleetCoordinator(cfg);
coordinator.run();
ekf1 = coordinator.localSimulations{1}.ekf;
ekf2 = coordinator.localSimulations{2}.ekf;
assert(~isempty(ekf1.declaredCommonProcessNoiseGroup_) && ~isempty(ekf2.declaredCommonProcessNoiseGroup_), ...
    'every leaf must receive the declared common-process-noise group');
assert(isequal(ekf1.declaredCommonProcessNoiseGroup_,ekf2.declaredCommonProcessNoiseGroup_), ...
    'every leaf must receive the identical group value, not independently-constructed copies');
fprintf('  PASS Q6b: the real coordinator runs end-to-end and wires the identical group value to every leaf\n');

% A declared group with sigma_mps2<=0 is a pointless declaration, refused by the NEW guard.
cfgZero = i_twoAssetFleetCfg_();
cfgZero.multiAsset.distributedEstimator.correlationNetwork.policy = 'exactPairwiseCrossCovariance';
cfgZero.multiAsset.distributedEstimator.correlationNetwork.maximumFleetSize = 2;
cfgZero.multiAsset.distributedEstimator.correlationNetwork.commonProcessNoiseTreatment = ...
    'declaredCommonAccelerationGroup';
cfgZero.multiAsset.distributedEstimator.correlationNetwork.commonProcessNoise.sigma_mps2 = 0;
threwZero = false;
try
    revgnss.IndependentFleetCoordinator.validateConfig(revgnss.ConfigFactory.finalizeConfig(cfgZero));
catch MEZero
    threwZero = strcmp(MEZero.identifier,'IndependentFleetCoordinator:commonProcessNoiseGroupMagnitudeRequired');
end
assert(threwZero,'declaredCommonAccelerationGroup with sigma_mps2<=0 must be refused as a pointless declaration');
fprintf('  PASS Q6c: sigma_mps2<=0 is refused as a pointless declaration\n');

% The sibling guard (a leaf''s own cfg carrying the joint-mode flag alongside an enabled
% network) is untouched by this change.
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
assert(threw2,'commonAcceleration.enable=true with an enabled network must still be refused');
fprintf('  PASS Q6d: the sibling commonAcceleration.enable guard is untouched\n');
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
% Section 3.3's towerClockProductReachableButRejected guard refuses nSpaceAssets>1 with an
% enabled correlation network unless towerClockMode='perfectCorrection'; every subtest in this
% file is exercising the commonProcessNoiseTreatment guard, not the tower-clock-product gap.
% Use the LEGACY knob, not clocks.tower.product.mode: the latter is arbitrated by
% cfg.provenance.explicit, which only resolveSimulationConfig produces, so setting it
% on a masterConfig() struct is INERT and this opt-in silently did not take.
cfg.towerClock.correctionMode = 'perfectTruth';
cfg.scenario.nSpaceAssets = 2;
cfg.multiAsset.mode = 'fast';
% Diagnosis B #2 (2026-08): SECOND inherited-default trap in this same helper, on top
% of the towerClockMode one documented above -- masterConfig.m:1364 defaults
% towersObserveSecondaries=true (since d05e73d, 2026-08-05, after this test was
% written), which trips IndependentFleetCoordinator.m's centralSecondaryState guard
% and aborts i_test_live_path_refusal_ at its very first unguarded validateConfig
% call (line ~193) before Q6a can print. Declare both explicitly rather than inherit.
cfg.multiAsset.estimateMode = 'off';
cfg.multiAsset.towersObserveSecondaries = false;
cfg.multiAsset.distributedEstimator.enable = true;
cfg.multiAsset.distributedEstimator.deliveryLedger.enable = true;
end
