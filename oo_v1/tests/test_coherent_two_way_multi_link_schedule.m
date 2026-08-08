function test_coherent_two_way_multi_link_schedule()
% Validate scheduled fleet topology, row ownership, and observation use.

root = fileparts(fileparts(mfilename('fullpath')));
addpath(root);
addpath(fullfile(root,'config'));
addpath(fullfile(root,'config','internal'));

cfg = resolveSimulationConfig( ...
    'test003_jointCoherentTwoWayCode.json');
links = revgnss.TwoWayISLMeasurementBuilder.linkDefinitions(cfg);
assert(numel(links) == 6);

endpoints = [[links.initiatorAssetIndex]' ...
    [links.transponderAssetIndex]'];
assert(all(accumarray(endpoints(:),1,[6,1]) == 2));
reachable = false(1,6);
reachable(1) = true;
for passIndex = 1:6
    for linkIndex = 1:numel(links)
        if any(reachable(endpoints(linkIndex,:)))
            reachable(endpoints(linkIndex,:)) = true;
        end
    end
end
assert(all(reachable),'The scheduled physical-link graph is not connected.');

phases_s = arrayfun(@(link) link.schedule.updatePhase_s,links);
for phase_s = unique(phases_s(:)).'
    activeEndpoints = endpoints(phases_s == phase_s,:);
    assert(numel(unique(activeEndpoints(:))) == numel(activeEndpoints), ...
        'A spacecraft terminal is assigned to two links in one epoch.');
end
assert(~cfg.measurements.isl.carrier.enable);
assert(~cfg.multiAsset.twoWayTimeTransferISL.enable);
assert(numel(unique([links.turnaroundCalibrationError_s])) > 1);
assert(numel(unique([links.terminalCalibrationError_s])) > 1);

sharedCalibrationCfg = cfg;
sharedCalibrationCfg.measurements.isl.twoWay.calibration. ...
    errorCorrelationModel = 'sharedTerminalComponents';
assertThrows_( ...
    @() revgnss.TwoWayISLMeasurementBuilder.validateConfig(sharedCalibrationCfg), ...
    'TwoWayISLMeasurementBuilder:sharedCalibrationUnavailable');

conflictingCfg = cfg;
conflictingCfg.measurements.isl.twoWay.links(4).schedule.updatePhase_s = 0;
assertThrows_( ...
    @() revgnss.TwoWayISLMeasurementBuilder.validateConfig(conflictingCfg), ...
    'TwoWayISLMeasurementBuilder:terminalScheduleConflict');

cfg.simulation.duration_s = 5;
cfg.report.enable = false;
cfg.report.writePdf = false;
cfg.report.writeMat = false;
cfg.plots.enable = false;
simulation = revgnss.ReverseGNSSSimulation(cfg);
simulation.initialize();

biasIndices = simulation.ekf.stateMap.twoWayCodeCalibrationBiasIdx;
biasIdentifiers = simulation.ekf.stateMap. ...
    twoWayCodeCalibrationBiasLinkIdentifiers;
assert(numel(biasIndices) == numel(links));
assert(isequal(biasIdentifiers(:),{links.linkIdentifier}.'));
assert(norm(simulation.ekf.P(biasIndices,biasIndices) - ...
    diag(diag(simulation.ekf.P(biasIndices,biasIndices))),'fro') == 0);

[observations0,diagnostics0,generationInfo0] = ...
    revgnss.TwoWayISLMeasurementBuilder.generateObservations( ...
    simulation.cfg,simulation.asset,simulation.assets,0);
assert(numel(observations0) == 3 && numel(diagnostics0) == 3);
assert(numel(unique(cellfun(@(record) record.observationIdentifier, ...
    observations0,'UniformOutput',false))) == 3);
assert(simulation.cfg.measurements.isl.twoWay.calibration. ...
    validFromLocalTag_s < 0);
for observationIndex = 1:numel(observations0)
    linkInfo = generationInfo0.linkInfos{observationIndex};
    linkIndex = find(strcmp({links.linkIdentifier}, ...
        linkInfo.linkIdentifier),1);
    assert(~isempty(linkIndex));
    assert(strcmp(linkInfo.physicalChainIdentifier, ...
        links(linkIndex).physicalChainIdentifier));
    assert(strcmp(linkInfo.calibrationProductIdentifier, ...
        links(linkIndex).calibrationProductIdentifier));
    assert(startsWith(observations0{observationIndex}. ...
        observationIdentifier,[linkInfo.linkIdentifier ':code:']));
    assert(strcmp(observations0{observationIndex}. ...
        calibrationProductIdentifiers{1}, ...
        links(linkIndex).calibrationProductIdentifier));
    assert(numel(observations0{observationIndex}. ...
        calibrationProductIdentifiers) == 3);
    assert(contains(observations0{observationIndex}. ...
        initiatorTransmitTerminalIdentifier, ...
        links(linkIndex).physicalChainIdentifier));
    assert(strcmp(observations0{observationIndex}. ...
        initiatorTransmitAntennaIdentifier, ...
        observations0{observationIndex}. ...
        initiatorReceiveAntennaIdentifier));
    assert(observations0{observationIndex}.referenceLocalClockTag_s >= ...
        observations0{observationIndex}.calibrationValidFromLocalTag_s);
end

for observationIndex = 1:numel(generationInfo0.linkInfos)
    generationInfo0.linkInfos{observationIndex}.truthDiagnostic = [];
end
generationInfo0.truthDiagnostic = [];
[z0,h0,H0,R0,linearizationInfo0] = ...
    revgnss.TwoWayISLMeasurementBuilder.linearizeRecordedObservations( ...
    simulation.cfg,observations0,simulation.ekf.getMeasurementState(), ...
    simulation.ekf.stateMap,simulation.ekf.nx,0,generationInfo0);
assert(isequal(size(H0),[3,simulation.ekf.nx]));
assert(isequal(size(R0),[3,3]) && ...
    norm(R0-diag(diag(R0)),'fro') == 0);
assert(numel(linearizationInfo0.eligibleObservationRecords) == 3);
[zRecorded,hRecorded,HRecorded,RRecorded] = ...
    revgnss.TwoWayISLMeasurementBuilder.linearizeRecordedObservations( ...
    simulation.cfg,observations0,simulation.ekf.getMeasurementState(), ...
    simulation.ekf.stateMap,simulation.ekf.nx,0);
assert(norm(zRecorded-z0,Inf) == 0);
assert(norm(hRecorded-h0,Inf) == 0);
assert(norm(HRecorded-H0,Inf) == 0);
assert(norm(RRecorded-R0,Inf) == 0);

for rowIndex = 1:size(H0,1)
    linkInfo = linearizationInfo0.linkInfos{rowIndex};
    linkIndex = find(strcmp(biasIdentifiers,linkInfo.linkIdentifier),1);
    assert(H0(rowIndex,biasIndices(linkIndex)) == 1);
    otherBiasIndices = biasIndices;
    otherBiasIndices(linkIndex) = [];
    assert(all(H0(rowIndex,otherBiasIndices) == 0));
    endpointIndices = [linkInfo.receiverAssetIndex, ...
        linkInfo.transmitterAssetIndex];
    for assetIndex = 1:6
        positionColumns = simulation.ekf.stateMap.asset(assetIndex).r;
        if ismember(assetIndex,endpointIndices)
            assert(norm(H0(rowIndex,positionColumns)) > 0.9);
        else
            assert(all(H0(rowIndex,positionColumns) == 0));
        end
    end
end

simulation.ekf.P = eye(simulation.ekf.nx);
for assetIndex = 1:6
    positionColumns = simulation.ekf.stateMap.asset(assetIndex).r;
    simulation.ekf.P(positionColumns,positionColumns) = 100*eye(3);
end
simulation.ekf.update(h0,h0,H0,R0);
for rowIndex = 1:size(H0,1)
    linkInfo = linearizationInfo0.linkInfos{rowIndex};
    firstPosition = simulation.ekf.stateMap. ...
        asset(linkInfo.receiverAssetIndex).r;
    secondPosition = simulation.ekf.stateMap. ...
        asset(linkInfo.transmitterAssetIndex).r;
    assert(norm(simulation.ekf.P( ...
        firstPosition,secondPosition),'fro') > 0);
end

ledger = revgnss.ObservationConsumptionLedger();
ledger.markEligible(observations0{1},0);
assertThrows_(@() ledger.markEligible(observations0{1},0), ...
    'ObservationConsumptionLedger:duplicateObservation');
ledger.consume(observations0{1},0);
assertThrows_(@() ledger.consume(observations0{1},0), ...
    'ObservationConsumptionLedger:duplicateObservation');

simulation.cfg.estimator.minMeasurementsForUpdate = 1e6;
simulation.step(1);
assert(numel(simulation.interSatelliteObservations) == 3);
assert(simulation.observationLedger.numberEligible() == 3);
assert(simulation.observationLedger.numberConsumed() == 0);
for epochIndex = 2:5
    simulation.step(epochIndex);
end
simulation.cfg.estimator.minMeasurementsForUpdate = 1;
simulation.step(6);
assert(numel(simulation.interSatelliteObservations) == 6);
assert(simulation.observationLedger.numberEligible() == 6);
assert(simulation.observationLedger.numberConsumed() == 3);

observationIdentifiers = cellfun( ...
    @(record) record.observationIdentifier, ...
    simulation.interSatelliteObservations,'UniformOutput',false);
assert(numel(unique(observationIdentifiers)) == 6);

fprintf('test_coherent_two_way_multi_link_schedule: PASS\n');
end

function assertThrows_(callable,identifier)
didThrow = false;
try
    callable();
catch exception
    didThrow = strcmp(exception.identifier,identifier);
end
assert(didThrow,'Expected exception %s.',identifier);
end
