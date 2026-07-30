function test_joint_coherent_two_way_scenario()
root = fileparts(fileparts(mfilename('fullpath')));
addpath(root);
addpath(fullfile(root,'config'));
addpath(fullfile(root,'config','internal'));

scenarioFiles = { ...
    'joint_G5S6R4_coherent_two_way_code.json', ...
    'joint_G5S6R4_coherent_two_way_code_realism.json'};
for scenarioIndex = 1:numel(scenarioFiles)
    cfg = resolveSimulationConfig(scenarioFiles{scenarioIndex});
    assert(cfg.scenario.nSpaceAssets == 6 && cfg.scenario.nReceivers == 4);
    assert(strcmp(cfg.multiAsset.mode,'joint'));
    if scenarioIndex == 1
        assert(strcmp(cfg.report.layout,'jointSummary'));
    else
        assert(strcmp(cfg.report.layout,'clockExact'));
    end
    assert(cfg.measurements.isl.twoWay.range.useInEKF);
    assert(~cfg.measurements.isl.code.enable && ...
        ~cfg.measurements.isl.carrier.enable && ...
        ~cfg.measurements.isl.twoWay.doppler.enable);
    assert(~cfg.multiAsset.twoWayISL.enable && ...
        ~cfg.multiAsset.twoWayTimeTransferISL.enable);
    assert(~cfg.multiAsset.twoWayISL.lightTime.enable);
    assert(~cfg.measurements.isl.carrier.ambiguity.enable && ...
        ~cfg.measurements.isl.carrier.slipDetection.enable);
    links = revgnss.TwoWayISLMeasurementBuilder.linkDefinitions(cfg);
    assert(numel(links) == 6);
    endpoints = [[links.initiatorAssetIndex]' ...
        [links.transponderAssetIndex]'];
    assert(all(accumarray(endpoints(:),1,[6,1]) == 2));
    reachable = false(1,6);
    reachable(1) = true;
    for passIndex = 1:6
        for linkIndex = 1:size(endpoints,1)
            if any(reachable(endpoints(linkIndex,:)))
                reachable(endpoints(linkIndex,:)) = true;
            end
        end
    end
    assert(all(reachable));
    for assetIndex = 1:6
        assert(size(cfg.assets(assetIndex).receiverLeverArms_body_m,2) == 4);
    end
end

cfg = resolveSimulationConfig(scenarioFiles{1});
cfg.simulation.duration_s = 1;
cfg.report.enable = false;
cfg.report.writePdf = false;
cfg.report.writeMat = false;
cfg.plots.enable = false;
simulation = revgnss.ReverseGNSSSimulation(cfg);
simulation.initialize();
[recordedObservation,protectedDiagnostic,generationInfo] = ...
    revgnss.TwoWayISLMeasurementBuilder.generateObservation( ...
    simulation.cfg,simulation.asset,simulation.assets,0);
assert(isa(recordedObservation,'revgnss.InterSatelliteObservationRecord'));
assert(~isempty(protectedDiagnostic));
assert(strcmp(recordedObservation.localTimeSystemIdentifier, ...
    'initiatorOnboardClock'));
assert(strcmp(recordedObservation.timestampReferencePointIdentifier, ...
    'initiatorReceiveTerminal'));
assert(~isempty(recordedObservation.commandedScheduleIdentifier));
assert(recordedObservation.effectiveRangingBandwidth_Hz > 0);
assert(isfinite(recordedObservation.roundTripLinkMargin_dB));
assert(recordedObservation.referenceLocalClockTag_s >= ...
    recordedObservation.calibrationValidFromLocalTag_s);
assert(recordedObservation.referenceLocalClockTag_s <= ...
    recordedObservation.calibrationValidUntilLocalTag_s);

estimatorInfo = generationInfo;
estimatorInfo.truthDiagnostic = [];
[zRecorded,hRecorded,HRecorded,RRecorded,estimatorInfo] = ...
    revgnss.TwoWayISLMeasurementBuilder.linearizeRecordedObservation( ...
    simulation.cfg,recordedObservation, ...
    simulation.ekf.getMeasurementState(),simulation.ekf.stateMap, ...
    simulation.ekf.nx,0,estimatorInfo);
assert(isempty(estimatorInfo.truthDiagnostic));

[z,~,H,R,info] = revgnss.TwoWayISLMeasurementBuilder.build( ...
    simulation.cfg,simulation.asset,simulation.assets, ...
    simulation.ekf.getMeasurementState(),simulation.ekf.stateMap, ...
    simulation.ekf.nx,0);
assert(abs(z-zRecorded) < 1e-12);
assert(abs(info.hEkf-hRecorded) < 1e-12);
assert(norm(H-HRecorded,Inf) < 1e-12);
assert(abs(R-RRecorded) < 1e-12);
biasIndices = simulation.ekf.stateMap.twoWayCodeCalibrationBiasIdx;
assert(isscalar(z) && isscalar(R) && R > 0);
assert(isequal(size(H),[1,simulation.ekf.nx]));
assert(numel(biasIndices) == 6 && H(biasIndices(1)) == 1);
assert(all(H(biasIndices(2:end)) == 0));
assert(strcmp(info.calibrationUncertaintyTreatment, ...
    'estimatedPersistentResidualBias'));

initiatorBlock = simulation.ekf.stateMap.asset(1);
transponderBlock = simulation.ekf.stateMap.asset(2);
assert(norm(H(initiatorBlock.r)) > 0.9);
assert(norm(H(transponderBlock.r)) > 0.9);
assert(dot(H(initiatorBlock.r),H(transponderBlock.r)) < -0.8);
assert(norm(H(initiatorBlock.v)) > 0);
assert(norm(H(transponderBlock.v)) > 0);

simulation.ekf.P = eye(simulation.ekf.nx);
simulation.ekf.P(initiatorBlock.r,initiatorBlock.r) = 100*eye(3);
simulation.ekf.P(transponderBlock.r,transponderBlock.r) = 100*eye(3);
simulation.ekf.P(initiatorBlock.r,transponderBlock.r) = zeros(3);
simulation.ekf.P(transponderBlock.r,initiatorBlock.r) = zeros(3);
simulation.ekf.update(z,z,H,R);
assert(norm(simulation.ekf.P( ...
    initiatorBlock.r,transponderBlock.r),'fro') > 0, ...
    'The physical two-way observation did not create endpoint cross-covariance.');

blockedCfg = simulation.cfg;
blockedCfg.measurements.isl.twoWay.range.tracking.enforceThreshold = true;
blockedCfg.measurements.isl.twoWay.range.tracking. ...
    minimumCarrierToNoiseDensity_dBHz = 300;
[blockedObservation,~,blockedInfo] = ...
    revgnss.TwoWayISLMeasurementBuilder.generateObservation( ...
    blockedCfg,simulation.asset,simulation.assets,0);
assert(~blockedObservation.available && ...
    blockedObservation.roundTripLinkMargin_dB < 0);
blockedInfo.truthDiagnostic = [];
[zBlocked,~,HBlocked,~,~] = ...
    revgnss.TwoWayISLMeasurementBuilder.linearizeRecordedObservation( ...
    blockedCfg,blockedObservation,simulation.ekf.getMeasurementState(), ...
    simulation.ekf.stateMap,simulation.ekf.nx,0,blockedInfo);
assert(isempty(zBlocked) && size(HBlocked,1) == 0);

runCfg = resolveSimulationConfig(scenarioFiles{1});
runCfg.simulation.duration_s = 2;
runCfg.report.enable = false;
runCfg.report.writePdf = false;
runCfg.report.writeMat = false;
runCfg.plots.enable = false;
runSimulation = revgnss.ReverseGNSSSimulation(runCfg);
runSimulation.initialize();
runSimulation.run();
runResults = runSimulation.getResults();
assert(runResults.coherentTwoWayRange.generatedRecords > 0);
assert(runResults.coherentTwoWayRange.eligibleRows > 0);
assert(runResults.coherentTwoWayRange.consumedRows == ...
    runResults.coherentTwoWayRange.eligibleRows);
assert(size(runSimulation.ekf.history. ...
    relativePositionCovarianceToReference_m2,3) == 5);

fprintf('test_joint_coherent_two_way_scenario: PASS\n');
end
