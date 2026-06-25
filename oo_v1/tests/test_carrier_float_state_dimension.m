% test_carrier_float_state_dimension
% ambiguityMode='floatPerTowerSignal' adds nTowers ambiguity states to the EKF.
%
% Verifies:
%   - nx_amb = nx_base + nTowers * nSignals (nSignals=1 for single-frequency)
%   - stateMap.ambiguityIdx has size [nTowers x 1], all > 0
%   - Simulation runs without error

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_carrier_float_state_dimension ===\n');

% Baseline
cfg_base = revgnss.ConfigFactory.defaultConfig();
cfg_base.simulation.duration_s = 60;
cfg_base.plots.enable  = false;
cfg_base.report.enable = false;
sim_base = revgnss.ReverseGNSSSimulation(cfg_base);
sim_base.initialize();
nx_base = sim_base.ekf.nx;

% With float ambiguities
cfg_amb = revgnss.ConfigFactory.defaultConfig();
cfg_amb.measurements.carrierMode = 'ekfFloat';
cfg_amb.estimation.ambiguityMode = 'floatPerTowerSignal';
cfg_amb.simulation.duration_s    = 60;
cfg_amb.plots.enable  = false;
cfg_amb.report.enable = false;

sim_amb = revgnss.ReverseGNSSSimulation(cfg_amb);
sim_amb.initialize();
nx_amb  = sim_amb.ekf.nx;
nTowers = cfg_amb.scenario.nTowers;
sm      = sim_amb.ekf.stateMap;

% Default config has single-frequency signals → nSignals = 1
nSig = max(1, sim_amb.ekf.ambiguityNSignals);

assert(nx_amb == nx_base + nTowers * nSig, ...
    'nx with ambiguities should be nx_base(%d) + nTowers(%d)*nSig(%d) = %d, got %d', ...
    nx_base, nTowers, nSig, nx_base + nTowers * nSig, nx_amb);

assert(isfield(sm,'ambiguityIdx'), 'stateMap must have ambiguityIdx field');
assert(size(sm.ambiguityIdx, 1) == nTowers, ...
    'ambiguityIdx should have %d tower rows, got %d', nTowers, size(sm.ambiguityIdx,1));
assert(all(sm.ambiguityIdx(:) > 0), 'All ambiguityIdx entries should be > 0');

% Run to verify no crash
sim_amb.run();

fprintf('  nx_base=%d  nx_amb=%d  nTowers=%d  nSig=%d\n', nx_base, nx_amb, nTowers, nSig);
fprintf('  ambiguityIdx(:,1) = [%s]\n', num2str(sm.ambiguityIdx(:,1)'));
fprintf('  PASS\n');
