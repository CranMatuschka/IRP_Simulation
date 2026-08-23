function test_gyro_process_covariance()
%TEST_GYRO_PROCESS_COVARIANCE  Exact discrete gyro/bias covariance per asset.

root = fileparts(fileparts(mfilename('fullpath')));
addpath(root);
addpath(fullfile(root,'config'));
addpath(fullfile(root,'config','internal'));

cfg = revgnss.ConfigFactory.defaultConfig();
assert(~isfield(cfg.estimator.imu.filter,'useVanLoanCrossTerm'), ...
    'The exact gyro covariance must not depend on an optional partial cross term.');
cfg.scenario.nSpaceAssets = 3;
cfg.multiAsset.mode = 'joint';
cfg.estimator.attitude.parameterization = 'quaternionErrorState';
cfg.estimator.estimateAttitude = true;
cfg.estimator.estimateAngularRate = false;
cfg.estimator.estimateGyroBias = true;
cfg.estimator.imu.enable = true;
cfg.estimator.imu.filter.arw_rad_per_sqrt_s = 2e-4;
cfg.estimator.imu.filter.rrw_rad_per_s_sqrt_s = 3e-5;
cfg.estimator.imu.filter.P0_bias_radps = 1e-5;

ekf = filter.ReverseGNSSEKF(cfg,0,[]);
ekf.initState(zeros(ekf.nx,1),zeros(ekf.nx));
dt_s = 2.5;
ekf.predict(dt_s,{},0,zeros(3,3),{},zeros(3,3));

arwVariance = cfg.estimator.imu.filter.arw_rad_per_sqrt_s^2;
biasWalkPsd = cfg.estimator.imu.filter.rrw_rad_per_s_sqrt_s^2;
expected = [ ...
    (arwVariance*dt_s+biasWalkPsd*dt_s^3/3)*eye(3), ...
    -biasWalkPsd*dt_s^2/2*eye(3); ...
    -biasWalkPsd*dt_s^2/2*eye(3), ...
    biasWalkPsd*dt_s*eye(3)];
tolerance = 1e-12*norm(expected,'fro');

for assetIdx = 1:3
    block = ekf.stateMap.asset(assetIdx);
    indices = [block.euler;block.gyroBias];
    actual = ekf.P(indices,indices);
    assert(norm(actual-expected,'fro') < tolerance, ...
        'Spacecraft %d has an incomplete or inconsistent gyro process covariance.', ...
        assetIdx);
end
assert(norm(ekf.P-ekf.P','fro') < tolerance && min(eig(ekf.P)) >= -tolerance, ...
    'The propagated covariance is not symmetric positive semidefinite.');

fprintf('test_gyro_process_covariance: PASS\n');
end
