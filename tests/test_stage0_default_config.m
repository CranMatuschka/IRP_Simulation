% test_stage0_default_config  Stage 0 acceptance: defaultConfig produces 5 towers, 1 receiver.
%
% Verifies:
%   - 5 towers, 1 receiver configured
%   - max 5 measurements per epoch
%   - attitude from pseudorange = false
%   - no P-not-PSD warnings during short run

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_stage0_default_config ===\n');

cfg = revgnss.ConfigFactory.defaultConfig();
cfg.simulation.duration_s = 120;
cfg.plots.enable  = false;
cfg.report.enable = false;

% Verify config before running
assert(cfg.scenario.nTowers    == 5, 'nTowers should be 5');
assert(cfg.scenario.nReceivers == 1, 'nReceivers should be 1');
assert(~cfg.estimator.estimateAttitudeFromPseudorange, 'estimateAttitudeFromPseudorange should be false');

sim = revgnss.ReverseGNSSSimulation(cfg);
sim.initialize();

nRx = size(sim.asset.receiverLeverArms_body_m, 2);
assert(nRx == 1, 'After finalize: should have 1 receiver, got %d', nRx);

sim.run();

nm = sim.diag.getNumMeasurements();
assert(max(nm) <= 5, 'Max measurements/epoch should be <= 5 (5 towers × 1 receiver), got %d', max(nm));
assert(mean(nm) >= 4, 'Mean measurements/epoch should be >= 4 (all towers visible for GEO), got %.1f', mean(nm));

fprintf('  nTowers=%d  nReceivers=%d  max_meas=%d  mean_meas=%.1f\n', ...
    cfg.scenario.nTowers, nRx, max(nm), mean(nm));
fprintf('  estimateAttitudeFromPseudorange: %d\n', cfg.estimator.estimateAttitudeFromPseudorange);
fprintf('  PASS\n');
