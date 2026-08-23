% test_tropo_zwd_jacobian
% ZWD states appear in the stateMap and simulation runs cleanly.
%
% Verifies:
%   - stateMap.zwdIdx(ti) is a valid column index (> 0, <= nx)
%   - The simulation converges (no NaN states) after running with ZWD enabled
%   - ZWD state values are bounded (< 10 m ZWD residual is physically reasonable)

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_tropo_zwd_jacobian ===\n');

cfg = revgnss.ConfigFactory.defaultConfig();
cfg.estimation.troposphereMode      = 'perTowerZwd';
cfg.estimation.tropoZwd.tau_s        = 3600;
cfg.estimation.tropoZwd.sigma_ss_m   = 0.05;
cfg.estimation.tropoZwd.initialSigma_m = 0.10;
cfg.simulation.duration_s = 120;
cfg.plots.enable  = false;
cfg.report.enable = false;

sim = revgnss.ReverseGNSSSimulation(cfg);
sim.initialize();

nTowers = cfg.scenario.nTowers;
nx      = sim.ekf.nx;
sm      = sim.ekf.stateMap;

% All ZWD indices valid
for ti = 1:nTowers
    idx = sm.zwdIdx(ti);
    assert(idx > 0 && idx <= nx, ...
        'zwdIdx(%d)=%d is out of range [1,%d]', ti, idx, nx);
end

sim.run();

% No NaN in final state
x_final = sim.ekf.x;
assert(all(isfinite(x_final)), 'EKF state has NaN/Inf after ZWD run');

% ZWD states should be bounded (< 1 m physically)
for ti = 1:nTowers
    zwd_est = x_final(sm.zwdIdx(ti));
    assert(abs(zwd_est) < 1.0, ...
        'ZWD state for tower %d = %.4f m; expected < 1 m', ti, zwd_est);
end

fprintf('  zwdIdx = [%s]  nx=%d\n', num2str(sm.zwdIdx'), nx);
fprintf('  ZWD estimates: [%s] m\n', num2str(x_final(sm.zwdIdx)'));
fprintf('  PASS\n');
