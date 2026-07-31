function test_leaf_declared_common_process_noise_diagonal()
% test_leaf_declared_common_process_noise_diagonal  Plan Stage 3.3, the live-path diagonal gap
% Stage 3.1/3.2 explicitly deferred here: filter.ReverseGNSSEKF.buildQ_'s new declared-common-
% process-noise block. Golden-safety (empty group -> buildQ_ output bit-identical to the pre-
% Section-3.3 formula) and exact wiring (a declared group's diagonal contribution appears in Q
% via the SAME revgnss.CommonProcessNoiseCovarianceGroup.ownDiagonalContribution instance method
% revgnss.DistributedCovarianceNetwork.advanceEpoch's own cross-block math already calls -- see
% tests/test_distributed_common_product_cross_covariance.m's Q1-Q4 subtests for the independent,
% element-for-element proof that THAT method reproduces a real joint EKF's Q exactly; this file
% proves buildQ_ actually reaches it, not that the formula itself is correct). Real
% filter.ReverseGNSSEKF throughout, no mocks.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
addpath(rootDir);
addpath(fullfile(rootDir,'config'));
addpath(fullfile(rootDir,'config','internal'));

fprintf('=== test_leaf_declared_common_process_noise_diagonal ===\n');
i_test_golden_safety_when_empty_();
i_test_diagonal_matches_own_diagonal_contribution_exactly_();
fprintf('=== test_leaf_declared_common_process_noise_diagonal: ALL PASS ===\n');
end

% ================================================================================================
function i_test_golden_safety_when_empty_()
[ekf, towerClockModels, dt] = i_freshEkf_();
assert(isempty(ekf.declaredCommonProcessNoiseGroup_), ...
    'declaredCommonProcessNoiseGroup_ must default empty');
Qbaseline = ekf.buildQ_(dt,towerClockModels);

% Explicitly re-assigning the empty default (a caller that reads-then-writes the property back)
% must still be a no-op -- golden safety is structural (branch not taken), not "empty happens to
% behave like zero."
ekf.declaredCommonProcessNoiseGroup_ = revgnss.CommonProcessNoiseCovarianceGroup.empty;
Qagain = ekf.buildQ_(dt,towerClockModels);
assert(isequal(Qbaseline,Qagain),'buildQ_ must be bit-identical with an explicitly-empty group');
fprintf('  PASS: buildQ_ is golden-safe (bit-identical) when declaredCommonProcessNoiseGroup_ is empty\n');
end

% ================================================================================================
function i_test_diagonal_matches_own_diagonal_contribution_exactly_()
[ekf, towerClockModels, dt] = i_freshEkf_();
Qbaseline = ekf.buildQ_(dt,towerClockModels);

sigma = 0.017;
group = revgnss.CommonProcessNoiseCovarianceGroup.fromRecord(struct( ...
    'processNoiseGroupIdentifier','group:diagonal-test','commonSourceName','sharedForceAtmosphericProduct', ...
    'treatment','declaredCommonAccelerationGroup','memberEndpointIdentifiers',{{'spacecraft:1','spacecraft:2'}}, ...
    'frameIdentifier','ECEF','commonAccelerationSigma_mps2',sigma, ...
    'stateComponentPairing','positionVelocityPerAxis', ...
    'sourceConfigurationPath','multiAsset.distributedEstimator.correlationNetwork.commonProcessNoise', ...
    'validFromCoordinateEpoch_s',0,'validUntilCoordinateEpoch_s',1e9));
ekf.declaredCommonProcessNoiseGroup_ = group;
Qwith = ekf.buildQ_(dt,towerClockModels);

schemaIdx = revgnss.DistributedCovarianceNetworkContract.schemaStateIndicesFromStateMap(ekf.stateMap,1);
expectedDiagonal = group.ownDiagonalContribution(dt,schemaIdx,ekf.nx);

assert(isequal(Qwith,Qbaseline+expectedDiagonal), ...
    'buildQ_ with a declared group must equal the baseline Q plus EXACTLY ownDiagonalContribution''s output');
assert(any(expectedDiagonal(:) ~= 0),'sanity: the declared diagonal contribution must be genuinely nonzero');

% Removing the group (real-world: never happens mid-run, but proves the branch is reversible and
% not a one-way sticky mutation) restores the baseline exactly.
ekf.declaredCommonProcessNoiseGroup_ = revgnss.CommonProcessNoiseCovarianceGroup.empty;
Qremoved = ekf.buildQ_(dt,towerClockModels);
assert(isequal(Qremoved,Qbaseline),'clearing the group must restore the exact baseline Q');
fprintf('  PASS: buildQ_''s declared diagonal term equals ownDiagonalContribution exactly, and is reversible\n');
end

% ================================================================================================
function [ekf, towerClockModels, dt] = i_freshEkf_()
cfg = masterConfig();
cfg.scenario.nTowers = 3;
cfg = revgnss.ConfigFactory.finalizeConfig(cfg);
clockModel = models.clocks.ClockModel(cfg.asset.clock);
ekf = filter.ReverseGNSSEKF(cfg,cfg.scenario.nTowers,clockModel);
x0 = zeros(ekf.nx,1); x0(1:3) = [7000e3;0;0]; x0(4:6) = [0;7500;0];
ekf.initState(x0,eye(ekf.nx));
towerClockModels = cell(1,cfg.scenario.nTowers);
for k = 1:cfg.scenario.nTowers; towerClockModels{k} = clockModel; end
dt = 1.0;
end
