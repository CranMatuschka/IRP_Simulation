% test_two_way_time_transfer_postfit
% Commit 4: physical TWTT EKF rows must remain visible in postfit residual
% diagnostics and per-type innovation accounting.

fprintf('=== test_two_way_time_transfer_postfit ===\n');
thisDir = fileparts(mfilename('fullpath'));
oo = fileparts(thisDir);
addpath(oo);
addpath(fullfile(oo, 'config'));

cfg = masterConfig();
cfg.simulation.duration_s = 5;
cfg.measurements.doppler.enable = false;
cfg.measurements.doppler.useInEKF = false;
cfg.measurements.carrierMode = 'off';
cfg.measurements.carrierPhase.enable = false;
cfg.measurements.twoWayTimeTransfer.enable = true;
cfg.measurements.twoWayTimeTransfer.useInEKF = true;
cfg.measurements.twoWayTimeTransfer.sigma_m = 0.03;
cfg.measurements.twoWayTimeTransfer.warmup_s = 0;
cfg.measurements.twoWayTimeTransfer.includeReciprocityResidual = false;
cfg.estimator.minMeasurementsForUpdate = 1;
cfg.report.enable = false;
cfg.report.writePdf = false;
cfg.report.writeMat = false;
cfg.plots.enable = false;
cfg.plots.showFigures = false;

sim = revgnss.ReverseGNSSSimulation(cfg);
sim.run();
d = sim.simData.getData();

twRows = d.meas.nTwoWayTimeTransferRows(:);
active = twRows > 0;
assert(any(active), 'T1 FAILED: TWTT enabled but no physical TWTT rows were recorded.');
assert(all(isfinite(d.residual.postfitTwoWayTimeTransferRMS_m(active))), ...
    'T1 FAILED: active TWTT rows must have finite postfit TWTT RMS.');
assert(all(isfinite(d.consistency.NIS_twoWayTimeTransfer(active))), ...
    'T1 FAILED: active TWTT rows must have separate finite TWTT NIS.');
assert(all(d.stage57.twoWayTimeTransferDof(active) == twRows(active)), ...
    'T1 FAILED: Stage 57 TWTT dof must equal physical TWTT row count.');
assert(all(isfinite(d.stage57.twoWayTimeTransferRms(active))), ...
    'T1 FAILED: Stage 57 TWTT residual RMS must be finite.');

expectedRows = d.meas.nCodeRows(:) + d.meas.nDopplerRows(:) + ...
    d.meas.nCarrierRows(:) + d.meas.nTwoWayTimeTransferRows(:);
assert(all(d.meas.nRows(:) == expectedRows), ...
    'T1 FAILED: physical row total must equal code+doppler+carrier+TWTT rows when ISL is off.');
fprintf('  T1 compact postfit/accounting includes TWTT rows: PASS (%d active epochs)\n', sum(active));

[zTw, ~, HTw, ~, infoTw] = revgnss.TwoWayTimeTransferBuilder.build( ...
    sim.cfg, sim.errorChain, sim.asset, sim.towers, sim.ekf.x, ...
    sim.ekf.stateMap, sim.ekf.nx, sim.tVec(end));
[hPostTw, HPostTw] = revgnss.TwoWayTimeTransferBuilder.predictEkfRows( ...
    sim.cfg, sim.asset, sim.towers, sim.ekf.x, sim.ekf.stateMap, ...
    infoTw, sim.tVec(end));
assert(numel(hPostTw) == numel(zTw), ...
    'T2 FAILED: predictEkfRows must return one h per TWTT EKF row.');
assert(max(abs(HTw(:, sim.ekf.stateMap.r_idx)), [], 'all') == 0, ...
    'T2 FAILED: TWTT update H must have zero position partials.');
assert(max(abs(HPostTw(:, sim.ekf.stateMap.r_idx)), [], 'all') == 0, ...
    'T2 FAILED: TWTT postfit H must have zero position partials.');
assert(all(abs(HPostTw(:, sim.ekf.stateMap.b_rx_idx) - 1) < 1e-12), ...
    'T2 FAILED: TWTT postfit H must be +1 on receiver clock.');
fprintf('  T2 product-clock TWTT postfit prediction/Jacobian: PASS (%d rows)\n', numel(zTw));

cfgState = masterConfig();
cfgState.simulation.duration_s = 1;
cfgState.clock.mode = 'includeTowerClocksInEKF';
cfgState.clock.gauge.mode = 'fixReferenceTower';
cfgState.measurements.carrierMode = 'off';
cfgState.measurements.carrierPhase.enable = false;
cfgState.measurements.twoWayTimeTransfer.enable = true;
cfgState.measurements.twoWayTimeTransfer.useInEKF = true;
cfgState.estimator.minMeasurementsForUpdate = 1;
cfgState.report.enable = false;
cfgState.plots.enable = false;
cfgState = revgnss.ConfigFactory.finalizeConfig(cfgState);
[assetS, towersS, ekfS, ~, errChainS] = revgnss.ScenarioFactory.build(cfgState);
[zS, ~, HS, ~, infoS] = revgnss.TwoWayTimeTransferBuilder.build( ...
    cfgState, errChainS, assetS, towersS, ekfS.x, ekfS.stateMap, ekfS.nx, 0);
assert(~isempty(zS), 'T3 FAILED: estimated-tower-clock TWTT build produced no rows.');
assert(max(abs(HS(:, ekfS.stateMap.r_idx)), [], 'all') == 0, ...
    'T3 FAILED: estimated-tower-clock TWTT H must have zero position partials.');
for ri = 1:numel(infoS.rows)
    ti = infoS.rows(ri).towerIdx;
    tc = ekfS.stateMap.towerClockIdx(ti, 1);
    if tc > 0
        assert(abs(HS(ri, tc) + 1) < 1e-12, ...
            'T3 FAILED: TWTT row %d for tower %d must be -1 on tower-clock state.', ri, ti);
    end
end
fprintf('  T3 estimated-tower-clock sign convention: PASS (%d rows)\n', numel(zS));

fprintf('=== test_two_way_time_transfer_postfit: ALL PASS ===\n');
