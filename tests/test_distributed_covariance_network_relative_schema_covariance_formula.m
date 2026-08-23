function test_distributed_covariance_network_relative_schema_covariance_formula()
% test_distributed_covariance_network_relative_schema_covariance_formula  Plan Section 3.5 item 1:
% P_delta_r = P_i+P_j-P_ij-P_ji, computed off revgnss.DistributedCovarianceNetwork's own stored
% cross block. relativeSchemaCovariance itself was written in Stage 3.1 (a comment there already
% read "REPORTING it is Section 3.5 scope") but had ZERO callers anywhere in the repo until this
% stage's relativeSchemaCovarianceFromLocalMarginals gave it its first real caller. Real
% filter.ReverseGNSSEKF throughout, no mocks.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
addpath(rootDir);
addpath(fullfile(rootDir,'config'));
addpath(fullfile(rootDir,'config','internal'));

fprintf('=== test_distributed_covariance_network_relative_schema_covariance_formula ===\n');
i_test_formula_matches_manual_computation_();
i_test_missing_marginal_refused_();
fprintf('=== test_distributed_covariance_network_relative_schema_covariance_formula: ALL PASS ===\n');
end

% ================================================================================================
function i_test_formula_matches_manual_computation_()
% Deliberately DIFFERENT initial covariance scales for the two members (P_i != P_j by
% construction, not by coincidence) plus a real, non-trivial propagated P_ij, so a naive wrong
% shortcut that assumes P_i==P_j and/or P_ij==P_ij' (e.g. 2*(P_i-P_ij)) gives a visibly different
% answer from the correct P_i+P_j-P_ij-P_ji formula -- this is the sharpest available proof the
% formula is really being applied, not merely returning something plausible-looking.
cfg = masterConfig();
cfg.scenario.nTowers = 3;
cfg = revgnss.ConfigFactory.finalizeConfig(cfg);
clockModel = models.clocks.ClockModel(cfg.asset.clock);
ids = {'spacecraft:1','spacecraft:2'};
ekfs = cell(1,2); providers = cell(1,2);
scales = [3, 11];
for k = 1:2
    ekfs{k} = filter.ReverseGNSSEKF(cfg,cfg.scenario.nTowers,clockModel);
    ekfs{k}.initState(zeros(ekfs{k}.nx,1),eye(ekfs{k}.nx)*scales(k));
    ekfs{k}.retainEpochTransitionOperators = true;
    providers{k} = revgnss.OwnerLocalEkfTransitionCaptureProvider.forLocalEkf(ekfs{k},ids{k},k);
end
policyRecord = struct('policyIdentifier','exactPairwiseCrossCovariance', ...
    'configuredMaximumFleetSize',2,'commonProcessNoiseTreatment','rejected', ...
    'linkUpdateRoutingPolicy','conservativeBoundOnly','crossBlockSpanKind','fullLocalStateSpan', ...
    'stateSchemaVersion',revgnss.DistributedLinkProtocolContract.StateSchemaVersion);
network = revgnss.DistributedCovarianceNetwork(policyRecord);
network.registerFleetMembers([providers{1}.memberRegistrationRecord(0),providers{2}.memberRegistrationRecord(0)]);
network.declareIndependentPriorPairs(0);

towerClockModels = cell(1,cfg.scenario.nTowers);
for k = 1:cfg.scenario.nTowers; towerClockModels{k} = ekfs{1}.rxClockModel; end
ekfs{1}.predict(1,towerClockModels,0); ekfs{2}.predict(1,towerClockModels,0);
network.advanceEpoch(struct('coordinateEpoch_s',1,'intervalDuration_s',1, ...
    'captures',[providers{1}.takeEpochCapture(0,1),providers{2}.takeEpochCapture(0,1)]));

marginalSupply = struct('endpointIdentifier',ids,'localMarginal',{ekfs{1}.P,ekfs{2}.P});
Pdr = network.relativeSchemaCovarianceFromLocalMarginals('spacecraft:1','spacecraft:2',marginalSupply);
assert(isequal(size(Pdr),[14 14]),'Pdr must be the 14-schema block');
symResid = max(max(abs(Pdr-Pdr')));
assert(symResid < 1e-9,'Pdr must be symmetric (max asymmetry %.3e)',symResid);

schemaIdx1 = revgnss.DistributedCovarianceNetworkContract.schemaStateIndicesFromStateMap(ekfs{1}.stateMap,1);
schemaIdx2 = revgnss.DistributedCovarianceNetworkContract.schemaStateIndicesFromStateMap(ekfs{2}.stateMap,1);
Mij = network.orientedCrossCovariance('spacecraft:1','spacecraft:2');
PijSchema = Mij(schemaIdx1,schemaIdx2);
Pi = ekfs{1}.P(schemaIdx1,schemaIdx1);
Pj = ekfs{2}.P(schemaIdx2,schemaIdx2);
PdrManual = Pi+Pj-PijSchema-PijSchema';
assert(isequal(Pdr,PdrManual),'relativeSchemaCovarianceFromLocalMarginals must exactly equal the manual formula');
fprintf('  PASS exact match against the hand-derived P_i+P_j-P_ij-P_ji formula\n');

naiveWrong = 2*(Pi-PijSchema);
naiveDelta = max(max(abs(Pdr-naiveWrong)));
assert(naiveDelta > 1e-6, ...
    'sanity: with deliberately different P_i/P_j scales, the correct formula must visibly differ from the naive 2*(P_i-P_ij) shortcut (delta=%.3e)',naiveDelta);
fprintf('  PASS correct formula measurably differs from the naive symmetric-shortcut formula (delta=%.3e)\n',naiveDelta);
end

% ================================================================================================
function i_test_missing_marginal_refused_()
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
    'configuredMaximumFleetSize',2,'commonProcessNoiseTreatment','rejected', ...
    'linkUpdateRoutingPolicy','conservativeBoundOnly','crossBlockSpanKind','fullLocalStateSpan', ...
    'stateSchemaVersion',revgnss.DistributedLinkProtocolContract.StateSchemaVersion);
network = revgnss.DistributedCovarianceNetwork(policyRecord);
network.registerFleetMembers([providers{1}.memberRegistrationRecord(0),providers{2}.memberRegistrationRecord(0)]);
network.declareIndependentPriorPairs(0);

threw = false;
try
    network.relativeSchemaCovarianceFromLocalMarginals('spacecraft:1','spacecraft:2', ...
        struct('endpointIdentifier',{'spacecraft:1'},'localMarginal',{ekfs{1}.P}));
catch ME
    threw = strcmp(ME.identifier,'DistributedCovarianceNetwork:localMarginalMissing');
end
assert(threw,'a missing local marginal for one endpoint must be refused with the frozen identifier');
fprintf('  PASS missing-marginal guard fires with the frozen identifier\n');
end
