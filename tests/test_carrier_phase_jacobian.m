% test_carrier_phase_jacobian
% Carrier EKF rows: ambiguity states connected, stateMap valid, simulation clean.
%
% Verifies:
%   - stateMap.ambiguityIdx(ti, 1) > 0 for each tower
%   - Each ambiguity state index is within [1, nx]
%   - EKF state is finite after short run with carrier phase enabled

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_carrier_phase_jacobian ===\n');

cfg = revgnss.ConfigFactory.defaultConfig();
cfg.measurements.carrierMode = 'ekfFloat';
cfg.estimation.ambiguityMode = 'floatPerTowerSignal';
cfg.simulation.duration_s    = 60;
cfg.plots.enable  = false;
cfg.report.enable = false;

sim = revgnss.ReverseGNSSSimulation(cfg);
sim.initialize();

nTowers = cfg.scenario.nTowers;
nx      = sim.ekf.nx;
sm      = sim.ekf.stateMap;

% Every tower must have a valid ambiguity state index
for ti = 1:nTowers
    idx = sm.ambiguityIdx(ti, 1);
    assert(idx > 0 && idx <= nx, ...
        'ambiguityIdx(%d,1)=%d out of range [1,%d]', ti, idx, nx);
end

% Ambiguity indices must be distinct
ambIdxVec = sm.ambiguityIdx(:,1)';
assert(numel(unique(ambIdxVec)) == nTowers, ...
    'Ambiguity state indices are not unique: [%s]', num2str(ambIdxVec));

% Ambiguity indices must not overlap with base state indices
baseIdx = [sm.r_idx(:); sm.v_idx(:); sm.euler_idx(:); sm.omega_idx(:); ...
           sm.b_rx_idx; sm.bdot_rx_idx]';
overlap = intersect(ambIdxVec, baseIdx);
assert(isempty(overlap), 'Ambiguity indices overlap base state: [%s]', num2str(overlap));

% Run and check no NaN
sim.run();
assert(all(isfinite(sim.ekf.x)), 'EKF state has NaN/Inf with carrier EKF enabled');

fprintf('  nx=%d  ambiguityIdx=[%s]\n', nx, num2str(ambIdxVec));
fprintf('  PASS\n');
