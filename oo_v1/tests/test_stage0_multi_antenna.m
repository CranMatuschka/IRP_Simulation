% test_stage0_multi_antenna  Stage 0 acceptance: multiAntennaAttitudeConfig.
%
% Verifies:
%   - 5 towers, 4 receivers
%   - max 20 measurements/epoch
%   - attitude H columns nonzero
%   - omega H columns zero

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_stage0_multi_antenna ===\n');

cfg = revgnss.ConfigFactory.multiAntennaAttitudeConfig();
cfg.simulation.duration_s = 60;
cfg.plots.enable  = false;
cfg.report.enable = false;

assert(cfg.scenario.nTowers    == 5, 'nTowers should be 5');
assert(cfg.scenario.nReceivers == 4, 'nReceivers should be 4');
assert(cfg.estimator.estimateAttitudeFromPseudorange, 'estimateAttitudeFromPseudorange should be true');
assert(~cfg.estimator.estimateAngularRateFromPseudorange, 'estimateAngularRateFromPseudorange should be false');

sim = revgnss.ReverseGNSSSimulation(cfg);
sim.initialize();

nRx = size(sim.asset.receiverLeverArms_body_m, 2);
assert(nRx == 4, 'Should have 4 receivers after finalize, got %d', nRx);

sim.run();

nm = sim.diag.getNumMeasurements();
assert(max(nm) <= 20, 'Max measurements/epoch should be <= 20 (5 towers × 4 antennas), got %d', max(nm));
assert(mean(nm) >= 15, 'Mean meas/epoch should be >= 15 (most towers visible), got %.1f', mean(nm));

% Check attitude Jacobian was nonzero (attitude observable with lever arms)
attNorm = [sim.diag.log.attitudeJacobianNorm];
assert(max(attNorm) > 1e-6, 'Attitude Jacobian should be nonzero with lever arms');

% Check omega H columns are zero (no rate estimation from pseudorange)
sm = sim.ekf.stateMap;
lastH = sim.diag.log(end).H;
if ~isempty(lastH) && size(lastH,2) >= 12
    omgNorm = norm(lastH(:, sm.omega_idx), 'fro');
    assert(omgNorm < 1e-10, 'Omega H columns should be zero in pseudorange-only mode');
end

fprintf('  nTowers=%d  nReceivers=%d  max_meas=%d  mean_meas=%.1f\n', ...
    cfg.scenario.nTowers, nRx, max(nm), mean(nm));
fprintf('  Max attitude H norm: %.4e\n', max(attNorm));
fprintf('  PASS\n');
