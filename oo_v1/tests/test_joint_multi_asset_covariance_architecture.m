function test_joint_multi_asset_covariance_architecture()
% Joint range updates must create and retain cross-spacecraft covariance.

sim = i_jointSimulation(2);
ekf = sim.ekf;
stateMap = ekf.stateMap;
primaryPosition = stateMap.asset(1).r;
secondaryPosition = stateMap.asset(2).r;

ekf.P = eye(ekf.nx);
ekf.P(primaryPosition,primaryPosition) = 100*eye(3);
ekf.P(secondaryPosition,secondaryPosition) = 100*eye(3);
ekf.P(primaryPosition,secondaryPosition) = zeros(3);
ekf.P(secondaryPosition,primaryPosition) = zeros(3);

direction = ekf.x(primaryPosition)-ekf.x(secondaryPosition);
direction = direction/norm(direction);
H = zeros(1,ekf.nx);
H(primaryPosition) = direction';
H(secondaryPosition) = -direction';
ekf.update(1,0,H,0.25);

crossCovariance = ekf.P(primaryPosition,secondaryPosition);
assert(norm(crossCovariance,'fro') > 0);
assert(norm(ekf.P-ekf.P','fro') < 1e-10);
assert(min(eig((ekf.P+ekf.P')/2)) >= -1e-10);

relativeCovariance = ekf.P(primaryPosition,primaryPosition) + ...
    ekf.P(secondaryPosition,secondaryPosition) - ...
    ekf.P(primaryPosition,secondaryPosition) - ...
    ekf.P(secondaryPosition,primaryPosition);
differenceMap = zeros(3,ekf.nx);
differenceMap(:,primaryPosition) = eye(3);
differenceMap(:,secondaryPosition) = -eye(3);
assert(norm(relativeCovariance-differenceMap*ekf.P*differenceMap','fro') < 1e-10);
ekf.logStep(0,NaN,NaN);
loggedRelativeCovariance = ...
    ekf.history.relativePositionCovarianceToReference_m2(:,:,1,end);
assert(norm(loggedRelativeCovariance-relativeCovariance,'fro') < 1e-10);

% A correlated measurement block and its whitened form are equivalent.
priorCovariance = diag(linspace(1,2,ekf.nx));
Hblock = zeros(2,ekf.nx);
Hblock(1,primaryPosition(1)) = 1;
Hblock(1,secondaryPosition(1)) = -1;
Hblock(2,primaryPosition(2)) = 1;
Hblock(2,secondaryPosition(2)) = -1;
measurementCovariance = [4,1.2;1.2,9];
posteriorFull = i_joseph(priorCovariance,Hblock,measurementCovariance);
lowerFactor = chol(measurementCovariance,'lower');
posteriorWhitened = i_joseph(priorCovariance, ...
    lowerFactor\Hblock,eye(2));
assert(norm(posteriorFull-posteriorWhitened,'fro') < 1e-10);

simSix = i_jointSimulation(6,4);
assert(numel(simSix.ekf.stateMap.asset) == 6);
allIndices = [];
for assetIdx = 1:6
    block = simSix.ekf.stateMap.asset(assetIdx);
    indices = [block.r;block.v;block.euler;block.omega;block.b;block.bdot];
    assert(numel(indices) == 14);
    assert(size(simSix.cfg.assets(assetIdx).receiverLeverArms_body_m,2) == 4);
    allIndices = [allIndices;indices]; %#ok<AGROW>
end
assert(numel(unique(allIndices)) == numel(allIndices));

commonSimulation = i_jointSimulationWithCommonAcceleration(2,2e-5);
commonFilter = commonSimulation.ekf;
commonFilter.P = zeros(commonFilter.nx);
commonFilter.predict(1,{},0);
firstPosition = commonFilter.stateMap.asset(1).r;
secondPosition = commonFilter.stateMap.asset(2).r;
firstVelocity = commonFilter.stateMap.asset(1).v;
secondVelocity = commonFilter.stateMap.asset(2).v;
expectedCommonVariance = (2e-5)^2;
assert(abs(commonFilter.P(firstPosition(1),secondPosition(1)) - ...
    expectedCommonVariance/3) < 1e-20);
assert(abs(commonFilter.P(firstPosition(1),secondVelocity(1)) - ...
    expectedCommonVariance/2) < 1e-20);
assert(abs(commonFilter.P(firstVelocity(1),secondVelocity(1)) - ...
    expectedCommonVariance) < 1e-20);
assert(min(eig((commonFilter.P+commonFilter.P')/2)) >= -1e-18);

fprintf('test_joint_multi_asset_covariance_architecture: PASS\n');
end

function sim = i_jointSimulation(nAssets,nReceivers)
if nargin < 2; nReceivers = 1; end
cfg = revgnss.ConfigFactory.defaultConfig();
cfg.simulation.duration_s = 1;
cfg.scenario.nSpaceAssets = nAssets;
cfg.scenario.nReceivers = nReceivers;
cfg.multiAsset.mode = 'joint';
cfg.estimator.starTracker.enable = false;
cfg.estimator.imu.enable = false;
sim = revgnss.ReverseGNSSSimulation(cfg);
sim.initialize();
end

function sim = i_jointSimulationWithCommonAcceleration(nAssets,sigma_mps2)
cfg = revgnss.ConfigFactory.defaultConfig();
cfg.simulation.duration_s = 1;
cfg.scenario.nSpaceAssets = nAssets;
cfg.multiAsset.mode = 'joint';
cfg.estimator.starTracker.enable = false;
cfg.estimator.imu.enable = false;
cfg.estimator.processNoise.commonAcceleration.enable = true;
cfg.estimator.processNoise.commonAcceleration.sigma_mps2 = sigma_mps2;
cfg.estimator.processNoise.commonAcceleration.frame = 'ecef';
sim = revgnss.ReverseGNSSSimulation(cfg);
sim.initialize();
end

function posterior = i_joseph(prior,H,R)
innovationCovariance = H*prior*H' + R;
gain = prior*H'/innovationCovariance;
identityMinusGainH = eye(size(prior))-gain*H;
posterior = identityMinusGainH*prior*identityMinusGainH' + gain*R*gain';
posterior = (posterior+posterior')/2;
end
