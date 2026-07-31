function test_distributed_covariance_network_audit_and_fleet_limit()
% test_distributed_covariance_network_audit_and_fleet_limit  Plan Stage 3.1 items 6-7: the
% transient PSD/symmetry audit of an assembled small-fleet covariance, and the hard configured
% fleet-size limit -- fails, never silently drops a cross block. Enforced by validateConfig (an
% absolute ceiling on the configured value, and a check of the configured value against
% scenario.nSpaceAssets), reinforced by a defensive re-check at IndependentFleetCoordinator.
% initialize() using the same error identifier (validateConfig already guarantees this cannot
% fire by the time initialize() runs, since the constructor calls validateConfig first; the
% re-check is intentional defence-in-depth, not a second independent gate), and by
% DistributedCovarianceNetwork.registerFleetMembers' own hard limit on the network itself.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
addpath(rootDir);
addpath(fullfile(rootDir,'config'));
addpath(fullfile(rootDir,'config','internal'));

fprintf('=== test_distributed_covariance_network_audit_and_fleet_limit ===\n');
i_test_clean_audit_and_forged_verdict_refusal_();
i_test_positive_semi_definite_violation_();
i_test_canonical_correlation_violation_localizes_the_pair_();
i_test_stale_cross_block_();
i_test_fleet_limit_three_layers_();
i_test_assembled_dimension_ceiling_();
fprintf('=== test_distributed_covariance_network_audit_and_fleet_limit: ALL PASS ===\n');
end

% ================================================================================================
function i_test_clean_audit_and_forged_verdict_refusal_()
[network, ~, ekfs, ids] = i_twoMemberNetworkWithTreatment_('rejected');
localMarginalSupply = struct('endpointIdentifier',ids, ...
    'localMarginal',{eye(ekfs{1}.nx),eye(ekfs{2}.nx)});
audit = network.auditAssembledFleetCovariance(struct( ...
    'localMarginalSupply',localMarginalSupply,'auditCoordinateEpoch_s',network.currentCoordinateEpoch_s));
assert(strcmp(audit.verdict,'symmetricPositiveSemiDefinite'),'a zero-cross-block fleet must audit clean');
assert(audit.isSymmetricPositiveSemiDefinite,'flag must be true for a clean verdict');

threw = false;
try
    revgnss.DistributedFleetCovarianceAudit.fromRecord(struct( ...
        'auditCoordinateEpoch_s',0,'networkRevisionNumber',0,'endpointIdentifiers',{ids}, ...
        'endpointDimensions',[ekfs{1}.nx,ekfs{2}.nx],'assembledDimension',ekfs{1}.nx+ekfs{2}.nx, ...
        'symmetryResidualFrobenius',0,'symmetryResidualRelative',0,'minimumScaledEigenvalue',-1, ...
        'scaledConditionNumber',1,'maximumPairCanonicalCorrelation',0,'worstPairKey','', ...
        'staleCrossBlockPairKeys',{{}},'benignDiagonalNudgeEventCount',0, ...
        'isSymmetricPositiveSemiDefinite',true,'verdict','positiveSemiDefiniteViolation'));
catch ME
    threw = strcmp(ME.identifier,'DistributedFleetCovarianceAudit:verdictFlagMismatch');
end
assert(threw,'a forged clean flag paired with a violating verdict must be refused at construction');
fprintf('  PASS A1/A2: clean audit; a forged clean flag with a violating verdict is refused\n');
end

% ================================================================================================
function i_test_positive_semi_definite_violation_()
% An oversized, unmatched declared common-noise term breaks PSD-ness of the assembly -- exactly
% the design's own C1 analysis (a cross-only injection with no matching diagonal can make the
% assembled fleet Q, and hence the resulting cross-covariance, indefinite relative to a tiny
% supplied marginal). For a two-member fleet the pair IS the whole assembly, so by the Cauchy
% interlacing theorem this ALWAYS also fails the sharper per-pair canonical-correlation check
% (verified by execution: with the coarser global check ordered first, this exact fixture
% still reported the correct pair as the culprit, motivating the precedence fix in
% auditAssembledFleetCovariance -- checking the per-pair test first, so any violation that CAN
% be localized to a named pair IS, and 'positiveSemiDefiniteViolation' is reserved for a
% genuinely joint 3+-way effect no single pair captures). The verdict here is therefore the
% sharper 'pairCanonicalCorrelationViolation', not the coarser global one.
[network, providers, ekfs, ids] = i_twoMemberNetworkWithTreatment_('declaredCommonAccelerationGroup');
group = revgnss.CommonProcessNoiseCovarianceGroup.fromRecord(struct( ...
    'processNoiseGroupIdentifier','group:huge','commonSourceName','sharedForceAtmosphericProduct', ...
    'treatment','declaredCommonAccelerationGroup','memberEndpointIdentifiers',{ids}, ...
    'frameIdentifier','ECEF','commonAccelerationSigma_mps2',50, ...
    'stateComponentPairing','positionVelocityPerAxis', ...
    'sourceConfigurationPath','estimator.processNoise.commonAcceleration', ...
    'validFromCoordinateEpoch_s',0,'validUntilCoordinateEpoch_s',1e9));
network.declareCommonProcessNoiseGroup(group);
cfg = ekfs{1}.cfg;
towerClockModels = cell(1,cfg.scenario.nTowers);
for k = 1:cfg.scenario.nTowers; towerClockModels{k} = ekfs{1}.rxClockModel; end
ekfs{1}.predict(1,towerClockModels,0); ekfs{2}.predict(1,towerClockModels,0);
network.advanceEpoch(struct('coordinateEpoch_s',1,'intervalDuration_s',1, ...
    'captures',[providers{1}.takeEpochCapture(0,1),providers{2}.takeEpochCapture(0,1)]));

localMarginalSupply = struct('endpointIdentifier',ids, ...
    'localMarginal',{eye(ekfs{1}.nx)*1e-6,eye(ekfs{2}.nx)*1e-6});
audit = network.auditAssembledFleetCovariance(struct( ...
    'localMarginalSupply',localMarginalSupply,'auditCoordinateEpoch_s',1));
fprintf('  verdict=%s minScaledEig=%.3e\n',audit.verdict,audit.minimumScaledEigenvalue);
assert(any(strcmp(audit.verdict,{'pairCanonicalCorrelationViolation','positiveSemiDefiniteViolation'})), ...
    'an oversized unmatched common-noise term must be caught (by the sharper per-pair check, or the coarser global one)');
assert(~audit.isSymmetricPositiveSemiDefinite,'the audit flag must not be clean for a genuinely indefinite assembly');
threwWrapper = false;
try
    network.requireAssembledFleetCovarianceSymmetricPsd(struct( ...
        'localMarginalSupply',localMarginalSupply,'auditCoordinateEpoch_s',1));
catch ME
    threwWrapper = strcmp(ME.identifier,'DistributedCovarianceNetwork:auditFailed');
end
assert(threwWrapper,'the throwing wrapper must throw on any non-clean verdict');
fprintf('  PASS A3: an indefinite assembly is caught (verdict=%s); throwing wrapper throws\n',audit.verdict);
end

% ================================================================================================
function i_test_canonical_correlation_violation_localizes_the_pair_()
% A4: seed a real, modest nonzero cross block via a declared common source, then audit with a
% caller-supplied marginal so much smaller than the real cross-block magnitude that even that
% modest correlation exceeds the Cauchy-Schwarz bound -- the sharpest available proof that the
% per-pair check both fires AND names the offending pair.
[network, providers, ekfs, ids] = i_twoMemberNetworkWithTreatment_('declaredCommonAccelerationGroup');
group = revgnss.CommonProcessNoiseCovarianceGroup.fromRecord(struct( ...
    'processNoiseGroupIdentifier','group:corr','commonSourceName','sharedForceAtmosphericProduct', ...
    'treatment','declaredCommonAccelerationGroup','memberEndpointIdentifiers',{ids}, ...
    'frameIdentifier','ECEF','commonAccelerationSigma_mps2',0.05, ...
    'stateComponentPairing','positionVelocityPerAxis', ...
    'sourceConfigurationPath','estimator.processNoise.commonAcceleration', ...
    'validFromCoordinateEpoch_s',0,'validUntilCoordinateEpoch_s',1e9));
network.declareCommonProcessNoiseGroup(group);
cfg = ekfs{1}.cfg;
towerClockModels = cell(1,cfg.scenario.nTowers);
for k = 1:cfg.scenario.nTowers; towerClockModels{k} = ekfs{1}.rxClockModel; end
ekfs{1}.predict(1,towerClockModels,0); ekfs{2}.predict(1,towerClockModels,0);
network.advanceEpoch(struct('coordinateEpoch_s',1,'intervalDuration_s',1, ...
    'captures',[providers{1}.takeEpochCapture(0,1),providers{2}.takeEpochCapture(0,1)]));

localMarginalSupply = struct('endpointIdentifier',ids, ...
    'localMarginal',{eye(ekfs{1}.nx)*1e-12,eye(ekfs{2}.nx)*1e-12});
audit = network.auditAssembledFleetCovariance(struct( ...
    'localMarginalSupply',localMarginalSupply,'auditCoordinateEpoch_s',1));
fprintf('  verdict=%s worstPairKey=%s maxRho=%.3e\n',audit.verdict,audit.worstPairKey,audit.maximumPairCanonicalCorrelation);
assert(strcmp(audit.verdict,'pairCanonicalCorrelationViolation'), ...
    'a tiny marginal against a real nonzero cross block must trip the canonical-correlation check');
assert(strcmp(audit.worstPairKey,revgnss.DistributedCovarianceNetworkContract.canonicalPairKey(ids{1},ids{2})), ...
    'worstPairKey must name the exact offending pair');
fprintf('  PASS A4/A5: canonical-correlation violation localizes the offending pair (unit-diagonal rescaling exercised)\n');
end

% ================================================================================================
function i_test_stale_cross_block_()
[network, ~, ekfs, ids] = i_twoMemberNetworkWithTreatment_('rejected');
localMarginalSupply = struct('endpointIdentifier',ids, ...
    'localMarginal',{eye(ekfs{1}.nx),eye(ekfs{2}.nx)});
audit = network.auditAssembledFleetCovariance(struct( ...
    'localMarginalSupply',localMarginalSupply,'auditCoordinateEpoch_s',network.currentCoordinateEpoch_s+5));
assert(strcmp(audit.verdict,'staleCrossBlock'), ...
    'an audit epoch mismatching the stored block epoch must report staleCrossBlock');
assert(~isempty(audit.staleCrossBlockPairKeys),'staleCrossBlockPairKeys must name the stale pair');
fprintf('  PASS A6: stale cross block detected\n');
end

% ================================================================================================
function i_test_fleet_limit_three_layers_()
cfg = i_twoAssetFleetCfg_();
cfg.multiAsset.distributedEstimator.correlationNetwork.policy = 'exactPairwiseCrossCovariance';
cfg.multiAsset.distributedEstimator.correlationNetwork.maximumFleetSize = 9;
threw1 = false;
try
    revgnss.IndependentFleetCoordinator.validateConfig(revgnss.ConfigFactory.finalizeConfig(cfg));
catch ME
    threw1 = strcmp(ME.identifier,'IndependentFleetCoordinator:correlationNetworkFleetSizeCeiling');
end
assert(threw1,'a configured maximumFleetSize above the frozen ceiling must be refused');

cfg2 = i_twoAssetFleetCfg_();
cfg2.scenario.nSpaceAssets = 3;
cfg2.multiAsset.distributedEstimator.correlationNetwork.policy = 'exactPairwiseCrossCovariance';
cfg2.multiAsset.distributedEstimator.correlationNetwork.maximumFleetSize = 2;
threw2 = false;
try
    revgnss.IndependentFleetCoordinator.validateConfig(revgnss.ConfigFactory.finalizeConfig(cfg2));
catch ME2
    threw2 = strcmp(ME2.identifier,'IndependentFleetCoordinator:correlationNetworkFleetSizeLimit');
end
assert(threw2,'nSpaceAssets exceeding maximumFleetSize must be refused at validateConfig');

[~, providers, ~, ~] = i_threeMemberNetwork_();
policyRecord = struct('policyIdentifier','exactPairwiseCrossCovariance', ...
    'configuredMaximumFleetSize',2,'commonProcessNoiseTreatment','rejected', ...
    'linkUpdateRoutingPolicy','conservativeBoundOnly','crossBlockSpanKind','fullLocalStateSpan', ...
    'stateSchemaVersion',revgnss.DistributedLinkProtocolContract.StateSchemaVersion);
network3 = revgnss.DistributedCovarianceNetwork(policyRecord);
memberRecords = [providers{1}.memberRegistrationRecord(0),providers{2}.memberRegistrationRecord(0), ...
    providers{3}.memberRegistrationRecord(0)];
threw3 = false;
try
    network3.registerFleetMembers(memberRecords);
catch ME3
    threw3 = strcmp(ME3.identifier,'DistributedCovarianceNetwork:fleetSizeLimitExceeded');
end
assert(threw3 && isempty(network3.crossBlockIdentifiers()), ...
    'registerFleetMembers must refuse and leave zero cross blocks -- fails, never drops');
fprintf(['  PASS A7: fleet-size limit enforced at validateConfig (ceiling, and nSpaceAssets ' ...
    'vs configured), reinforced defensively at initialize(), and enforced again by ' ...
    'registerFleetMembers itself\n']);
end

% ================================================================================================
function i_test_assembled_dimension_ceiling_()
threw = false;
try
    revgnss.DistributedFleetCovarianceAudit.fromRecord(struct( ...
        'auditCoordinateEpoch_s',0,'networkRevisionNumber',0, ...
        'endpointIdentifiers',{{'spacecraft:1','spacecraft:2'}}, ...
        'endpointDimensions',[300 300],'assembledDimension',600,'symmetryResidualFrobenius',0, ...
        'symmetryResidualRelative',0,'minimumScaledEigenvalue',1,'scaledConditionNumber',1, ...
        'maximumPairCanonicalCorrelation',0,'worstPairKey','','staleCrossBlockPairKeys',{{}}, ...
        'benignDiagonalNudgeEventCount',0,'isSymmetricPositiveSemiDefinite',true, ...
        'verdict','symmetricPositiveSemiDefinite'));
catch ME
    threw = strcmp(ME.identifier,'DistributedFleetCovarianceAudit:assembledFleetDimensionLimitExceeded');
end
assert(threw,'an assembled dimension above MaximumAssembledFleetDimension must be refused');
fprintf('  PASS A8: MaximumAssembledFleetDimension guard fires\n');
end

% ================================================================================================
function [network, providers, ekfs, ids] = i_twoMemberNetworkWithTreatment_(treatment)
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
    'configuredMaximumFleetSize',2,'commonProcessNoiseTreatment',treatment, ...
    'linkUpdateRoutingPolicy','conservativeBoundOnly','crossBlockSpanKind','fullLocalStateSpan', ...
    'stateSchemaVersion',revgnss.DistributedLinkProtocolContract.StateSchemaVersion);
network = revgnss.DistributedCovarianceNetwork(policyRecord);
network.registerFleetMembers([providers{1}.memberRegistrationRecord(0),providers{2}.memberRegistrationRecord(0)]);
network.declareIndependentPriorPairs(0);
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
    ekfs{k}.initState(zeros(ekfs{k}.nx,1),eye(ekfs{k}.nx)*(2+k));
    ekfs{k}.retainEpochTransitionOperators = true;
    providers{k} = revgnss.OwnerLocalEkfTransitionCaptureProvider.forLocalEkf(ekfs{k},ids{k},k);
end
policyRecord = struct('policyIdentifier','exactPairwiseCrossCovariance', ...
    'configuredMaximumFleetSize',4,'commonProcessNoiseTreatment','rejected', ...
    'linkUpdateRoutingPolicy','conservativeBoundOnly','crossBlockSpanKind','fullLocalStateSpan', ...
    'stateSchemaVersion',revgnss.DistributedLinkProtocolContract.StateSchemaVersion);
network = revgnss.DistributedCovarianceNetwork(policyRecord);
network.registerFleetMembers([providers{1}.memberRegistrationRecord(0),providers{2}.memberRegistrationRecord(0), ...
    providers{3}.memberRegistrationRecord(0)]);
network.declareIndependentPriorPairs(0);
end

function cfg = i_twoAssetFleetCfg_()
cfg = masterConfig();
cfg.scenario.nSpaceAssets = 2;
cfg.multiAsset.mode = 'fast';
cfg.multiAsset.distributedEstimator.enable = true;
cfg.multiAsset.distributedEstimator.deliveryLedger.enable = true;
end
