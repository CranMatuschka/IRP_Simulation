function test_coherent_two_way_frequency_active_path()
% Configured carrier frequency must affect the active epoch observation.

[info8,cfg8] = i_buildAtFrequency(8e9);
[info16,~] = i_buildAtFrequency(16e9);

expectedLoss_dB = 20*log10(2);
assert(abs((info16.carrierToNoiseDensity_dBHz - ...
    info8.carrierToNoiseDensity_dBHz) + expectedLoss_dB) < 1e-8);
assert(abs(info16.thermalSigma_m/info8.thermalSigma_m - 2) < 1e-8);
assert(abs(info16.truthDiagnostic.forwardGeometricRange_m - ...
    info8.truthDiagnostic.forwardGeometricRange_m) < 1e-6);
assert(abs(info16.truthDiagnostic.returnGeometricRange_m - ...
    info8.truthDiagnostic.returnGeometricRange_m) < 1e-6);
assert(abs(info8.rfLinkTruth.forward.distance_m - ...
    info8.truthDiagnostic.forwardGeometricRange_m) < 1e-6);
assert(abs(info8.rfLinkTruth.return.distance_m - ...
    info8.truthDiagnostic.returnGeometricRange_m) < 1e-6);
assert(strcmp(info8.observationRecord.protocolIdentifier, ...
    'coherentTranspondedPnTwoWayCode'));
assert(info8.nEkfRows == 1);
ledger = revgnss.ObservationConsumptionLedger();
ledger.markEligible(info8.observationRecord,0);
ledger.consume(info8.observationRecord,0);
assert(ledger.numberEligible() == 1);
assert(ledger.numberConsumed() == 1);
duplicateRejected = false;
try
    ledger.consume(info8.observationRecord,0);
catch exception
    duplicateRejected = strcmp(exception.identifier, ...
        'ObservationConsumptionLedger:duplicateObservation');
end
assert(duplicateRejected);

cfgPlasma = cfg8;
cfgPlasma.measurements.isl.twoWay.range.plasma.enable = true;
cfgPlasma.measurements.isl.twoWay.range.plasma.truthForwardTEC_electrons_per_m2 = 1e17;
cfgPlasma.measurements.isl.twoWay.range.plasma.truthReturnTEC_electrons_per_m2 = 1e17;
cfgPlasma.measurements.isl.twoWay.range.plasma.estimatorForwardTEC_electrons_per_m2 = 0;
cfgPlasma.measurements.isl.twoWay.range.plasma.estimatorReturnTEC_electrons_per_m2 = 0;
cfgPlasma.measurements.isl.twoWay.range.plasma.residualSigma_m = 0.01;
simPlasma = revgnss.ReverseGNSSSimulation(cfgPlasma);
simPlasma.initialize();
[~,~,~,~,plasmaInfo] = revgnss.TwoWayISLMeasurementBuilder.build( ...
    simPlasma.cfg,simPlasma.asset,simPlasma.assets, ...
    simPlasma.ekf.getMeasurementState(),simPlasma.ekf.stateMap, ...
    simPlasma.ekf.nx,0);
assert(plasmaInfo.physicalPropagationGroupDelay_s > 0);
assert(plasmaInfo.modeledPropagationGroupDelay_s == 0);

cfgInvalid = cfgPlasma;
cfgInvalid.measurements.isl.twoWay.range.plasma.estimatorForwardTEC_electrons_per_m2 = 1e17;
cfgInvalid.measurements.isl.twoWay.range.plasma.estimatorReturnTEC_electrons_per_m2 = 1e17;
cfgInvalid.measurements.isl.twoWay.range.plasma.residualSigma_m = 0;
didReject = false;
try
    revgnss.TwoWayISLMeasurementBuilder.validateConfig(cfgInvalid);
catch exception
    didReject = strcmp(exception.identifier, ...
        'TwoWayISLMeasurementBuilder:plasmaTruthModelSeparation');
end
assert(didReject);

cfgSchedule = cfg8;
cfgSchedule.measurements.isl.twoWay.schedule.updatePeriod_s = 2;
cfgSchedule.measurements.isl.twoWay.schedule.updatePhase_s = 0;
simSchedule = revgnss.ReverseGNSSSimulation(cfgSchedule);
simSchedule.initialize();
[zOff,~,~,~,infoOff] = revgnss.TwoWayISLMeasurementBuilder.build( ...
    simSchedule.cfg,simSchedule.asset,simSchedule.assets, ...
    simSchedule.ekf.getMeasurementState(),simSchedule.ekf.stateMap, ...
    simSchedule.ekf.nx,1);
assert(isempty(zOff) && ~infoOff.scheduled && ...
    strcmp(infoOff.scheduleStatus,'notScheduled'));
[zOn,~,~,~,infoOn] = revgnss.TwoWayISLMeasurementBuilder.build( ...
    simSchedule.cfg,simSchedule.asset,simSchedule.assets, ...
    simSchedule.ekf.getMeasurementState(),simSchedule.ekf.stateMap, ...
    simSchedule.ekf.nx,2);
assert(isscalar(zOn) && infoOn.scheduled && ...
    strcmp(infoOn.scheduleStatus,'scheduled'));

cfgOutage = cfgSchedule;
cfgOutage.measurements.isl.twoWay.schedule.outages_s = [2,2];
simOutage = revgnss.ReverseGNSSSimulation(cfgOutage);
simOutage.initialize();
[zOutage,~,~,~,infoOutage] = revgnss.TwoWayISLMeasurementBuilder.build( ...
    simOutage.cfg,simOutage.asset,simOutage.assets, ...
    simOutage.ekf.getMeasurementState(),simOutage.ekf.stateMap, ...
    simOutage.ekf.nx,2);
assert(isempty(zOutage) && ~infoOutage.scheduled && ...
    strcmp(infoOutage.scheduleStatus,'scheduledOutage'));

cfgCalibration = cfg8;
cfgCalibration.measurements.isl.twoWay.truth. ...
    turnaroundCalibrationError_s = 0.5e-9;
cfgCalibration.measurements.isl.twoWay.truth. ...
    terminalCalibrationError_s = 0.5e-9;
cfgCalibration.measurements.isl.twoWay.calibration.turnaroundSigma_s = 2e-9;
cfgCalibration.measurements.isl.twoWay.calibration.terminalSigma_s = 3e-9;
cfgCalibration.measurements.isl.twoWay.calibration. ...
    residualBiasState.enable = true;
cfgCalibration.measurements.isl.twoWay.calibration. ...
    residualBiasState.processNoiseSigma_m_per_sqrt_s = 1e-5;
simCalibration = revgnss.ReverseGNSSSimulation(cfgCalibration);
simCalibration.initialize();
[~,~,HCalibration,RCalibration,infoCalibration] = ...
    revgnss.TwoWayISLMeasurementBuilder.build( ...
    simCalibration.cfg,simCalibration.asset,simCalibration.assets, ...
    simCalibration.ekf.getMeasurementState(),simCalibration.ekf.stateMap, ...
    simCalibration.ekf.nx,0);
calibrationBiasIndex = ...
    simCalibration.ekf.stateMap.twoWayCodeCalibrationBiasIdx;
assert(~isempty(calibrationBiasIndex) && HCalibration(calibrationBiasIndex) == 1);
assert(abs(RCalibration-infoCalibration.thermalSigma_m^2) < 1e-14);
assert(strcmp(infoCalibration.calibrationUncertaintyTreatment, ...
    'estimatedPersistentResidualBias'));
assert(abs(simCalibration.ekf.P(calibrationBiasIndex,calibrationBiasIndex) - ...
    infoCalibration.calibrationSigma_m^2) < 1e-14);

cfgInvalidCalibration = cfgCalibration;
cfgInvalidCalibration.measurements.isl.twoWay.calibration. ...
    residualBiasState.enable = false;
didRejectCalibration = false;
try
    revgnss.TwoWayISLMeasurementBuilder.validateConfig( ...
        cfgInvalidCalibration);
catch exception
    didRejectCalibration = strcmp(exception.identifier, ...
        'TwoWayISLMeasurementBuilder:persistentCalibrationRequiresState');
end
assert(didRejectCalibration);

fprintf('test_coherent_two_way_frequency_active_path: PASS\n');
end

function [info,cfg] = i_buildAtFrequency(frequency_Hz)
cfg = revgnss.ConfigFactory.defaultConfig();
cfg.simulation.duration_s = 1;
cfg.simulation.dt_s = 1;
cfg.scenario.nSpaceAssets = 2;
cfg.multiAsset.mode = 'joint';
cfg.measurements.isl.enable = true;
cfg.measurements.isl.twoWay.enable = true;
cfg.measurements.isl.twoWay.range.enable = true;
cfg.measurements.isl.twoWay.range.useInEKF = true;
cfg.measurements.isl.twoWay.forwardCarrierFrequency_Hz = frequency_Hz;
cfg.measurements.isl.twoWay.returnCarrierFrequency_Hz = frequency_Hz;
cfg.measurements.isl.twoWay.carrierFrequencyTurnaroundRatio = 1;
cfg.measurements.isl.twoWay.range.linkBudget.model = 'physicalRF';
cfg.measurements.isl.twoWay.range.linkBudget.forward.transmitAntenna.model = 'fixedGain';
cfg.measurements.isl.twoWay.range.linkBudget.forward.receiveAntenna.model = 'fixedGain';
cfg.measurements.isl.twoWay.range.linkBudget.return.transmitAntenna.model = 'fixedGain';
cfg.measurements.isl.twoWay.range.linkBudget.return.receiveAntenna.model = 'fixedGain';

sim = revgnss.ReverseGNSSSimulation(cfg);
sim.initialize();
[z,h,H,R,info] = revgnss.TwoWayISLMeasurementBuilder.build( ...
    sim.cfg,sim.asset,sim.assets,sim.ekf.getMeasurementState(), ...
    sim.ekf.stateMap,sim.ekf.nx,0);
assert(isscalar(z) && isscalar(h) && isequal(size(H),[1,sim.ekf.nx]));
assert(isscalar(R) && R > 0);
estimatorInfo = info;
estimatorInfo.truthDiagnostic = [];
postfitPrediction = revgnss.TwoWayISLMeasurementBuilder.predictEkfRows( ...
    sim.cfg,sim.asset,sim.assets,sim.ekf.getMeasurementState(), ...
    sim.ekf.stateMap,estimatorInfo,0);
assert(isscalar(postfitPrediction) && isfinite(postfitPrediction), ...
    'Estimator prediction incorrectly depends on protected truth diagnostics.');
cfg = sim.cfg;
end
