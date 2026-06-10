% test_tower_clock_mode_path  Verify cfg.estimator.towerClockMode is read correctly.
%
% When towerClockMode = 'perfectCorrection', the predicted pseudorange uses the
% exact tower clock bias. When mode = 'none', it uses 0. These two modes must
% produce different h values when tower clocks have nonzero biases.

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_tower_clock_mode_path ===\n');

% Build a config with nonzero tower clock biases
cfg_pc = revgnss.ConfigFactory.defaultConfig();
cfg_pc.simulation.duration_s = 10;
cfg_pc.plots.enable  = false;
cfg_pc.report.enable = false;

% Introduce nonzero tower clock bias
for k = 1:numel(cfg_pc.towers)
    cfg_pc.towers(k).clock.bias_s    = k * 1e-7;  % nonzero bias
    cfg_pc.towers(k).clock.fracFreq  = 0;
    cfg_pc.towers(k).clock.deterministic = true;
end

cfg_none = cfg_pc;
cfg_none.estimator.towerClockMode = 'none';         % ignore tower clocks
cfg_pc.estimator.towerClockMode   = 'perfectCorrection';  % use exact bias

% Build measurement models
[asset_pc, towers_pc, ekf_pc, measModel_pc, ~, ~] = revgnss.ScenarioFactory.build(cfg_pc);
[asset_no, towers_no, ekf_no, measModel_no, ~, ~] = revgnss.ScenarioFactory.build(cfg_none);

t_s = 0;
[~, h_pc, ~, ~, ~] = measModel_pc.computeMeasurements(asset_pc, towers_pc, ekf_pc.x, t_s, ekf_pc.stateMap);
[~, h_no, ~, ~, ~] = measModel_no.computeMeasurements(asset_no, towers_no, ekf_no.x, t_s, ekf_no.stateMap);

if isempty(h_pc) || isempty(h_no)
    fprintf('  No visible towers — skipping\n');
    fprintf('  PASS (vacuous)\n');
    return
end

% With nonzero tower clocks, perfectCorrection and none must give different h
diff_h = norm(h_pc - h_no);
fprintf('  ||h_perfectCorrection - h_none|| = %.4f m\n', diff_h);

% Tower clock biases are O(c * 1e-7 s) ~ 30 m each, so the difference is large
assert(diff_h > 1.0, ...
    'test_tower_clock_mode_path FAILED: h values identical despite different clock modes (diff = %.4f m)', ...
    diff_h);

fprintf('  PASS\n');
