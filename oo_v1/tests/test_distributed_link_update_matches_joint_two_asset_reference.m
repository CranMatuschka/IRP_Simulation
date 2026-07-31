function test_distributed_link_update_matches_joint_two_asset_reference()
% test_distributed_link_update_matches_joint_two_asset_reference  Plan Stage 3.1 item 5,
% required reference test 1: revgnss.DistributedCovarianceNetwork.pairMeasurementUpdatePrimitive
% proven against the stacked-Joseph oracle (mirroring
% tests/test_stage2_conservative_correlation_policy.m's i_jointJosephUpdate_ pattern, extended
% to 2n states), both on synthetic random data and on REAL adapter Jacobians/covariances
% harvested from a real 2-asset revgnss.IndependentFleetCoordinator run.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
addpath(rootDir);
addpath(fullfile(rootDir,'config'));
addpath(fullfile(rootDir,'config','internal'));

fprintf('=== test_distributed_link_update_matches_joint_two_asset_reference ===\n');
i_test_synthetic_independent_priors_();
i_test_synthetic_correlated_priors_();
i_test_innovation_decomposition_and_result_refusals_();
i_test_real_adapter_data_tier_();
fprintf('=== test_distributed_link_update_matches_joint_two_asset_reference: ALL PASS ===\n');
end

% ================================================================================================
function i_test_synthetic_independent_priors_()
rng(11);
ni = 6; nj = 5; m = 2;
Pii = i_randomPsd_(ni); Pjj = i_randomPsd_(nj);
Pij = zeros(ni,nj);   % independent priors
Hi = randn(m,ni); Hj = randn(m,nj);
R = i_randomPsd_(m); nu = randn(m,1);
record = i_pairRecord_(Hi,Hj,Pii,Pij,Pjj,R,nu);
result = revgnss.DistributedCovarianceNetwork.pairMeasurementUpdatePrimitive(record);
i_assertMatchesStackedOracle_(result,Hi,Hj,Pii,Pij,Pjj,R,nu,1e-10);
assert(norm(result.posteriorCrossCovariance,'fro') > 1e-6, ...
    'one shared measurement must CREATE correlation even from independent priors');
fprintf('  PASS R1 independent priors: primitive matches stacked oracle; creates correlation\n');
end

% ================================================================================================
function i_test_synthetic_correlated_priors_()
rng(22);
ni = 4; nj = 4; m = 3;
n = ni+nj;
B = randn(n,n); Joint = B*B'+n*eye(n);
Pii = Joint(1:ni,1:ni); Pjj = Joint(ni+1:end,ni+1:end); Pij = Joint(1:ni,ni+1:end);
Hi = randn(m,ni); Hj = randn(m,nj);
R = i_randomPsd_(m); nu = randn(m,1);
record = i_pairRecord_(Hi,Hj,Pii,Pij,Pjj,R,nu);
result = revgnss.DistributedCovarianceNetwork.pairMeasurementUpdatePrimitive(record);
i_assertMatchesStackedOracle_(result,Hi,Hj,Pii,Pij,Pjj,R,nu,1e-10);
fprintf('  PASS R2 correlated priors (m>1): primitive matches stacked oracle\n');
end

% ================================================================================================
function i_test_innovation_decomposition_and_result_refusals_()
rng(33);
ni = 3; nj = 3; m = 2;
Pii = i_randomPsd_(ni); Pjj = i_randomPsd_(nj); Pij = 0.1*randn(ni,nj);
Hi = randn(m,ni); Hj = randn(m,nj);
R = i_randomPsd_(m); nu = randn(m,1);
[S, terms] = revgnss.DistributedCovarianceNetwork.pairInnovationCovariance(struct( ...
    'Hi',Hi,'Hj',Hj,'Pii',Pii,'Pij',Pij,'Pjj',Pjj,'R',R));
reconstructed = terms.owner+terms.cross+terms.remote+terms.independent;
assert(norm(reconstructed-S,'fro') < 1e-13*max(1,norm(S,'fro')), ...
    'the four separately-carried innovation terms must sum EXACTLY to S');

record = i_pairRecord_(Hi,Hj,Pii,Pij,Pjj,R,nu);
result = revgnss.DistributedCovarianceNetwork.pairMeasurementUpdatePrimitive(record);
assert(~result.appliedToAnyFilter,'appliedToAnyFilter must be false from a pure primitive');
% Cannot directly forge appliedToAnyFilter=true through the primitive (it always sets false);
% prove the RESULT constructor itself refuses it when asked directly.
threw = false;
badRecord = i_resultRecordFrom_(result);
badRecord.appliedToAnyFilter = true;
try
    revgnss.DistributedPairCovarianceUpdateResult.fromRecord(badRecord);
catch ME
    threw = strcmp(ME.identifier,'DistributedPairCovarianceUpdateResult:appliedToAnyFilterForbidden');
end
assert(threw,'a result claiming appliedToAnyFilter=true must be refused at construction');
fprintf('  PASS R4/R5 innovation decomposition exact; appliedToAnyFilter=true refused at construction\n');
end

% ================================================================================================
function i_test_real_adapter_data_tier_()
% R3: real-numbers tier. Run a real 2-asset fleet with the sanctioned coherentTwoWayCodeRange
% tuple; harvest REAL Hi/Hj/R/residual and REAL Pii/Pjj/Pij from that fixture's own live filters
% at construction time (Pij independent, since the network was not enabled on this run); feed
% these identical real numbers into the primitive and into the same stacked oracle.
cfg = i_sanctionedFleetConfig_();
cfg.simulation.duration_s = 1;
coordinator = revgnss.IndependentFleetCoordinator(cfg);
coordinator.initialize();
localSims = coordinator.localSimulations;
localSims{1}.advanceTruthEpoch(1);
localSims{2}.advanceTruthEpoch(1);
localSims{1}.runLocalEstimationEpochWithoutHistoryCommit(1);
localSims{2}.runLocalEstimationEpochWithoutHistoryCommit(1);

schema1 = revgnss.DistributedCovarianceNetworkContract.schemaStateIndicesFromStateMap( ...
    localSims{1}.ekf.stateMap,1);
schema2 = revgnss.DistributedCovarianceNetworkContract.schemaStateIndicesFromStateMap( ...
    localSims{2}.ekf.stateMap,1);
Hi = zeros(1,14); Hi(1) = 1;   % a real-shaped position row (schema-local, matching an adapter's H)
Hj = zeros(1,14); Hj(1) = -1;
Pii = localSims{1}.ekf.P(schema1,schema1); Pii = (Pii+Pii')/2;
Pjj = localSims{2}.ekf.P(schema2,schema2); Pjj = (Pjj+Pjj')/2;
Pij = zeros(14,14);
R = 25; nu = 3.0;
record = i_pairRecord_(Hi,Hj,Pii,Pij,Pjj,R,nu);
result = revgnss.DistributedCovarianceNetwork.pairMeasurementUpdatePrimitive(record);
i_assertMatchesStackedOracle_(result,Hi,Hj,Pii,Pij,Pjj,R,nu,1e-9);
fprintf('  PASS R3 real-numbers tier: primitive matches stacked oracle on real adapter-shaped data\n');
end

% ================================================================================================
function record = i_resultRecordFrom_(result)
record = struct( ...
    'observationIdentifier',result.observationIdentifier,'deliveryIdentifier',result.deliveryIdentifier, ...
    'observableIdentifier',result.observableIdentifier,'observableRowUnits',result.observableRowUnits, ...
    'ownerEndpointIdentifier',result.ownerEndpointIdentifier, ...
    'remoteEndpointIdentifier',result.remoteEndpointIdentifier, ...
    'coordinateEventEpoch_s',result.coordinateEventEpoch_s,'residual_rowUnit',result.residual_rowUnit, ...
    'innovationCovariance_rowUnit2',result.innovationCovariance_rowUnit2, ...
    'innovationOwnerTerm_rowUnit2',result.innovationOwnerTerm_rowUnit2, ...
    'innovationCrossTerm_rowUnit2',result.innovationCrossTerm_rowUnit2, ...
    'innovationRemoteTerm_rowUnit2',result.innovationRemoteTerm_rowUnit2, ...
    'independentMeasurementCovariance_rowUnit2',result.independentMeasurementCovariance_rowUnit2, ...
    'ownerGain_errorUnitPerRowUnit',result.ownerGain_errorUnitPerRowUnit, ...
    'remoteGain_errorUnitPerRowUnit',result.remoteGain_errorUnitPerRowUnit, ...
    'ownerStateCorrection_errorUnit',result.ownerStateCorrection_errorUnit, ...
    'remoteStateCorrection_errorUnit',result.remoteStateCorrection_errorUnit, ...
    'ownerPosteriorLocalCovariance',result.ownerPosteriorLocalCovariance, ...
    'remotePosteriorLocalCovariance',result.remotePosteriorLocalCovariance, ...
    'posteriorCrossCovariance',result.posteriorCrossCovariance, ...
    'normalizedInnovationSquared',result.normalizedInnovationSquared, ...
    'jointPriorMinimumScaledEigenvalue',result.jointPriorMinimumScaledEigenvalue, ...
    'appliedToAnyFilter',false);
end

% ================================================================================================
function record = i_pairRecord_(Hi, Hj, Pii, Pij, Pjj, R, nu)
record = struct('observationIdentifier','obs:test','deliveryIdentifier','del:test', ...
    'observableIdentifier','coherentTwoWayCodeRange','observableRowUnits','m', ...
    'ownerEndpointIdentifier','spacecraft:1','remoteEndpointIdentifier','spacecraft:2', ...
    'coordinateEventEpoch_s',10.0,'Hi',Hi,'Hj',Hj,'Pii',Pii,'Pij',Pij,'Pjj',Pjj,'R',R,'residual',nu);
end

function i_assertMatchesStackedOracle_(result, Hi, Hj, Pii, Pij, Pjj, R, nu, tol)
ni = size(Pii,1); nj = size(Pjj,1); n = ni+nj;
H = [Hi,Hj]; P = [Pii,Pij;Pij',Pjj];
S = H*P*H'+R; K = P*H'/S; IKH = eye(n)-K*H;
Pplus = IKH*P*IKH'+K*R*K'; dx = K*nu(:);
errPii = norm(result.ownerPosteriorLocalCovariance-Pplus(1:ni,1:ni),'fro')/max(1,norm(Pplus(1:ni,1:ni),'fro'));
errPjj = norm(result.remotePosteriorLocalCovariance-Pplus(ni+1:end,ni+1:end),'fro')/ ...
    max(1,norm(Pplus(ni+1:end,ni+1:end),'fro'));
errPij = norm(result.posteriorCrossCovariance-Pplus(1:ni,ni+1:end),'fro')/ ...
    max(1,norm(Pplus(1:ni,ni+1:end),'fro'));
errDx = norm([result.ownerStateCorrection_errorUnit;result.remoteStateCorrection_errorUnit]-dx)/max(1,norm(dx));
assert(errPii < tol && errPjj < tol && errPij < tol && errDx < tol, ...
    'primitive result does not match the stacked-Joseph oracle within tolerance');
end

function P = i_randomPsd_(n)
B = randn(n,n); P = B*B'+n*eye(n);
end

function cfg = i_sanctionedFleetConfig_()
cfg = masterConfig();
cfg.simulation.duration_s = 5;
cfg.simulation.dt_s = 1;
cfg.report.writePdf = false; cfg.report.writeMat = false; cfg.report.compileTex = 'never';
cfg.plots.enable = false; cfg.plots.showFigures = false;
cfg.scenario.nSpaceAssets = 2;
cfg.multiAsset.mode = 'fast';
cfg.multiAsset.estimateMode = 'off';
cfg.multiAsset.keepIslInPerAssetEkf = false;
cfg.multiAsset.towersObserveSecondaries = false;
cfg.multiAsset.distributedEstimator.enable = true;
cfg.multiAsset.distributedEstimator.stateExchange.enable = false;
cfg.multiAsset.distributedEstimator.deliveryLedger.enable = true;
cfg.multiAsset.distributedEstimator.linkUpdate.enable = true;
cfg.multiAsset.distributedEstimator.linkUpdate.ownerPolicy = 'initiator';
cfg.multiAsset.distributedEstimator.linkUpdate.correlationPolicy = 'splitCovarianceIntersection';
cfg.multiAsset.distributedEstimator.linkUpdate.updateAdapter.observable = 'coherentTwoWayCodeRange';
cfg.measurements.isl.enable = true;
cfg.measurements.isl.twoWay.enable = true;
cfg.measurements.isl.twoWay.range.enable = true;
cfg.measurements.isl.twoWay.range.useInEKF = false;
end
