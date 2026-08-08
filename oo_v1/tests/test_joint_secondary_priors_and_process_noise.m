function test_joint_secondary_priors_and_process_noise()
% Secondary configuration fields must define their stated prior and SNC.

repoRoot = fileparts(fileparts(mfilename('fullpath')));
% genpath MUST NOT sweep .claude/worktrees -- see tests/run_all_tests.m. addpath prepends, so
% an unfiltered sweep makes every LATER test in the run resolve to the stale worktree copy.
claudePath_ = strsplit(genpath(repoRoot), pathsep);
claudePath_ = claudePath_(~cellfun(@isempty, claudePath_));
addpath(strjoin(claudePath_(~contains(claudePath_, [filesep '.claude' filesep])), pathsep));

cfg = i_baseConfig();
cfg.multiAsset.secondaryOrbit.initSigmaPos_m = 17;
cfg.multiAsset.secondaryOrbit.initSigmaVel_mps = 0.23;
cfg.multiAsset.secondaryClock.initSigma_m = 31;
cfg.multiAsset.secondaryClock.initSigmaDrift_mps = 0.47;
sim = revgnss.ReverseGNSSSimulation(cfg);
sim.initialize();
blk = sim.ekf.stateMap.asset(2);
P0 = sim.ekf.P;
assert(all(abs(diag(P0(blk.r,blk.r))-17^2) < 1e-12));
assert(all(abs(diag(P0(blk.v,blk.v))-0.23^2) < 1e-12));
assert(abs(P0(blk.b,blk.b)-31^2) < 1e-12);
assert(abs(P0(blk.bdot,blk.bdot)-0.47^2) < 1e-12);

% An empty secondary SNC inherits the effective primary SNC, including the
% declared reduced-dynamics mismatch term in quadrature.
cfg = i_baseConfig();
cfg.multiAsset.secondaryOrbit.sigma_accel_mps2 = [];
i_assertSecondarySNC_(cfg,hypot(3,4));

% A supplied secondary SNC is already the full secondary value; it must not
% receive the primary mismatch term a second time.
cfg = i_baseConfig();
cfg.multiAsset.secondaryOrbit.sigma_accel_mps2 = 7;
i_assertSecondarySNC_(cfg,7);

fprintf('test_joint_secondary_priors_and_process_noise: PASS\n');
end

function cfg = i_baseConfig()
cfg = revgnss.ConfigFactory.defaultConfig();
cfg.simulation.duration_s = 1;
cfg.scenario.nSpaceAssets = 2;
cfg.multiAsset.mode = 'joint';
cfg.estimator.starTracker.enable = false;
cfg.estimator.imu.enable = false;
cfg.estimator.sigma_accel_mps2 = 3;
cfg.estimator.processNoise.modelMismatch.enable = true;
cfg.estimator.processNoise.modelMismatch.sigma_mps2 = 4;
cfg.estimator.processNoise.commonAcceleration.enable = false;
end

function i_assertSecondarySNC_(cfg,expectedSigma_mps2)
sim = revgnss.ReverseGNSSSimulation(cfg);
sim.initialize();
ekf = sim.ekf;
blk = ekf.stateMap.asset(2);
dt_s = 2;
ekf.P = zeros(ekf.nx);
ekf.predict(dt_s,{},0);

qPosition = expectedSigma_mps2^2*dt_s^3/3;
qVelocity = expectedSigma_mps2^2*dt_s;
qPositionVelocity = expectedSigma_mps2^2*dt_s^2/2;
assert(abs(ekf.P(blk.r(1),blk.r(1))-qPosition) < 1e-12);
assert(abs(ekf.P(blk.v(1),blk.v(1))-qVelocity) < 1e-12);
assert(abs(ekf.P(blk.r(1),blk.v(1))-qPositionVelocity) < 1e-12);
assert(abs(ekf.P(blk.v(1),blk.r(1))-qPositionVelocity) < 1e-12);
end
