% test_tropo_zwd_state_dimension
% troposphereMode='perTowerZwd' adds exactly nTowers ZWD states to the EKF.
%
% Verifies:
%   - nx_zwd = nx_base + nTowers
%   - stateMap.zwdIdx has nTowers entries, all > 0
%   - Simulation runs without error

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_tropo_zwd_state_dimension ===\n');

% Baseline (no ZWD)
cfg_base = revgnss.ConfigFactory.defaultConfig();
cfg_base.simulation.duration_s = 60;
cfg_base.plots.enable  = false;
cfg_base.report.enable = false;

sim_base = revgnss.ReverseGNSSSimulation(cfg_base);
sim_base.initialize();
nx_base = sim_base.ekf.nx;

% With ZWD states
cfg_zwd = revgnss.ConfigFactory.defaultConfig();
cfg_zwd.estimation.troposphereMode = 'perTowerZwd';
cfg_zwd.simulation.duration_s = 60;
cfg_zwd.plots.enable  = false;
cfg_zwd.report.enable = false;

sim_zwd = revgnss.ReverseGNSSSimulation(cfg_zwd);
sim_zwd.initialize();
nx_zwd   = sim_zwd.ekf.nx;
nTowers  = cfg_zwd.scenario.nTowers;
sm       = sim_zwd.ekf.stateMap;

assert(nx_zwd == nx_base + nTowers, ...
    'nx with ZWD should be nx_base(%d) + nTowers(%d) = %d, got %d', ...
    nx_base, nTowers, nx_base + nTowers, nx_zwd);

assert(isfield(sm,'zwdIdx') && numel(sm.zwdIdx) == nTowers, ...
    'stateMap.zwdIdx should have %d entries, got %d', nTowers, numel(sm.zwdIdx));
assert(all(sm.zwdIdx > 0), 'All zwdIdx entries should be > 0');

% Run to verify no crash
sim_zwd.run();

fprintf('  nx_base=%d  nx_zwd=%d  nTowers=%d  zwdIdx=[%s]\n', ...
    nx_base, nx_zwd, nTowers, num2str(sm.zwdIdx'));
fprintf('  PASS\n');
