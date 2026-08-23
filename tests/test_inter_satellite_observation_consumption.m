function test_inter_satellite_observation_consumption()
% Eligible two-way rows are consumed only by a successful EKF update.

cfgSkipped = i_config();
cfgSkipped.estimator.minMeasurementsForUpdate = 1e6;
simulationSkipped = revgnss.ReverseGNSSSimulation(cfgSkipped);
simulationSkipped.initialize();
simulationSkipped.run();

assert(simulationSkipped.observationLedger.numberEligible() == ...
    simulationSkipped.nEpochs);
assert(simulationSkipped.observationLedger.numberConsumed() == 0, ...
    'Rows rejected by the minimum-measurement guard were marked as consumed.');

cfgUsed = i_config();
cfgUsed.estimator.minMeasurementsForUpdate = 1;
simulationUsed = revgnss.ReverseGNSSSimulation(cfgUsed);
simulationUsed.initialize();
simulationUsed.run();

assert(simulationUsed.observationLedger.numberEligible() == ...
    simulationUsed.nEpochs);
assert(simulationUsed.observationLedger.numberConsumed() == ...
    simulationUsed.nEpochs, ...
    'A successful EKF update did not consume each eligible observation once.');

fprintf('test_inter_satellite_observation_consumption: PASS\n');
end

function cfg = i_config()
cfg = revgnss.ConfigFactory.defaultConfig();
cfg.simulation.duration_s = 1;
cfg.simulation.dt_s = 1;
cfg.scenario.nSpaceAssets = 2;
cfg.multiAsset.mode = 'joint';
cfg.estimator.starTracker.enable = false;
cfg.estimator.starTracker.useInEKF = false;
cfg.estimator.imu.enable = false;
cfg.measurements.doppler.enable = false;
cfg.measurements.doppler.useInEKF = false;
cfg.measurements.isl.enable = true;
cfg.measurements.isl.receiverAssetIndex = 1;
cfg.measurements.isl.transmitterAssetIndex = 2;
cfg.measurements.isl.code.enable = false;
cfg.measurements.isl.code.useInEKF = false;
cfg.measurements.isl.doppler.enable = false;
cfg.measurements.isl.doppler.useInEKF = false;
cfg.measurements.isl.carrier.enable = false;
cfg.measurements.isl.carrier.useInEKF = false;
cfg.measurements.isl.twoWay.enable = true;
cfg.measurements.isl.twoWay.range.enable = true;
cfg.measurements.isl.twoWay.range.useInEKF = true;
cfg.measurements.isl.twoWay.doppler.enable = false;
cfg.measurements.isl.twoWay.doppler.useInEKF = false;
cfg.report.enable = false;
cfg.report.writePdf = false;
cfg.report.writeMat = false;
cfg.plots.enable = false;
end
