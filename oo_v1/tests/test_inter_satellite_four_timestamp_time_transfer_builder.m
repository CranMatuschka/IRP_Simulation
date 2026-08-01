function test_inter_satellite_four_timestamp_time_transfer_builder()
% test_inter_satellite_four_timestamp_time_transfer_builder  Plan Section 4.4, Stage-4 named test.
% revgnss.InterSatelliteFourTimestampTimeTransferBuilder -- the ISL truth-side generator for the
% direct four-timestamp clock-difference observable. Reuses
% revgnss.TwoWayISLMeasurementBuilder.linkDefinitions(cfg) VERBATIM (item 4) and
% revgnss.DirectReciprocalTimeTransferBuilder.buildFromIsl + revgnss.FourTimestampObservableBuilder.
% fromExchangeRecord for the physics.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
addpath(rootDir);
addpath(fullfile(rootDir,'config'));
addpath(fullfile(rootDir,'config','internal'));

fprintf('=== test_inter_satellite_four_timestamp_time_transfer_builder ===\n');
i_test_validateConfig_accepts_default_fleet_config_();
i_test_validateConfig_rejects_bad_sigma_();
i_test_validateConfig_rejects_bad_terminalDelayAllocation_();
i_test_validateConfig_rejects_bad_carrierFrequency_();
i_test_validateConfig_rejects_same_asset_link_();
i_test_validateConfig_rejects_nonzero_counterTagSigma_();
i_test_generateObservations_produces_valid_record_with_real_calibration_identifier_();
i_test_generateObservations_deterministic_given_same_seed_();
fprintf('=== test_inter_satellite_four_timestamp_time_transfer_builder: ALL PASS ===\n');
end

% ================================================================================================
function i_test_validateConfig_accepts_default_fleet_config_()
cfg = i_islFleetConfig_();
revgnss.InterSatelliteFourTimestampTimeTransferBuilder.validateConfig(cfg);
fprintf('  PASS validateConfig accepts a well-formed two-asset ISL fleet config\n');
end

% ================================================================================================
function i_test_validateConfig_rejects_bad_sigma_()
cfg = i_islFleetConfig_();
cfg.measurements.isl.twoWay.fourTimestampPhysical.sigma_m = 0;
i_expectValidateConfigError_(cfg,'InterSatelliteFourTimestampTimeTransferBuilder:sigma');
end

% ================================================================================================
function i_test_validateConfig_rejects_bad_terminalDelayAllocation_()
cfg = i_islFleetConfig_();
cfg.measurements.isl.twoWay.fourTimestampPhysical.terminalDelayAllocation = 'notAFrozenAllocation';
i_expectValidateConfigError_(cfg,'InterSatelliteFourTimestampTimeTransferBuilder:terminalDelayAllocation');
end

% ================================================================================================
function i_test_validateConfig_rejects_bad_carrierFrequency_()
cfg = i_islFleetConfig_();
cfg.measurements.isl.twoWay.fourTimestampPhysical.carrierFrequency_Hz = -1;
i_expectValidateConfigError_(cfg,'InterSatelliteFourTimestampTimeTransferBuilder:carrierFrequency');
end

% ================================================================================================
function i_test_validateConfig_rejects_nonzero_counterTagSigma_()
% Combined-review M4: counterTag.sigma_s only ever feeds the TRUTH exchange record's own
% covarianceBlock, which generateObservations discards -- the OBSERVATION record's
% covarianceBlock is always info.sigma_m^2. A nonzero declared value must be refused.
cfg = i_islFleetConfig_();
cfg.measurements.isl.twoWay.fourTimestampPhysical.counterTag.sigma_s = [0 0 1e-9 0];
i_expectValidateConfigError_(cfg,'InterSatelliteFourTimestampTimeTransferBuilder:counterTagNoiseNotWired');
end

% ================================================================================================
function i_test_validateConfig_rejects_same_asset_link_()
cfg = i_islFleetConfig_();
cfg.measurements.isl.twoWay.links.transponderAssetIndex = cfg.measurements.isl.twoWay.links.initiatorAssetIndex;
i_expectValidateConfigError_(cfg,'InterSatelliteFourTimestampTimeTransferBuilder:endpoints');
end

% ================================================================================================
function i_expectValidateConfigError_(cfg, expectedIdentifier)
threw = false;
try
    revgnss.InterSatelliteFourTimestampTimeTransferBuilder.validateConfig(cfg);
catch ME
    threw = strcmp(ME.identifier,expectedIdentifier);
    assert(threw,'FAIL: expected %s, got %s (%s).',expectedIdentifier,ME.identifier,ME.message);
end
assert(threw,'FAIL: validateConfig must reject this config (expected %s).',expectedIdentifier);
fprintf('  PASS validateConfig rejects with %s\n',expectedIdentifier);
end

% ================================================================================================
function i_test_generateObservations_produces_valid_record_with_real_calibration_identifier_()
[cfg, sim1, sim2, epoch_s] = i_islSimFixture_();
assets = {sim1.asset, sim2.asset};

[observations, truthDiagnostics, info] = revgnss.InterSatelliteFourTimestampTimeTransferBuilder. ...
    generateObservations(cfg, assets, epoch_s);
assert(numel(observations)==1,'FAIL: expected exactly 1 scheduled observation.');
obs = observations{1};
assert(isa(obs,'revgnss.InterSatelliteFourTimestampObservationRecord'));
assert(obs.rawTimestampTagsAvailable);
assert(~obs.reciprocityTermIncluded);
assert(isfinite(obs.processedValue));
% Real bug fixed during implementation: calibrationProductIdentifiers must be a real declared
% identifier, not an empty cell (which the delivery layer's calibrationProvenanceMissing guard
% would reject).
assert(numel(obs.calibrationProductIdentifiers)==1 && ~isempty(obs.calibrationProductIdentifiers{1}));
assert(numel(truthDiagnostics)==1 && isfinite(truthDiagnostics{1}.clockDifferenceTruth_m));
assert(numel(info.linkInfos)==1 && info.linkInfos{1}.linkDefinitionIndex==1);
fprintf('  PASS generateObservations: 1 observation, processedValue=%.6f m, calibrationProductIdentifiers={%s}\n', ...
    obs.processedValue, obs.calibrationProductIdentifiers{1});
end

% ================================================================================================
function i_test_generateObservations_deterministic_given_same_seed_()
[cfg, sim1, sim2, epoch_s] = i_islSimFixture_();
assets = {sim1.asset, sim2.asset};
[obsA, ~, ~] = revgnss.InterSatelliteFourTimestampTimeTransferBuilder.generateObservations( ...
    cfg, assets, epoch_s);
[obsB, ~, ~] = revgnss.InterSatelliteFourTimestampTimeTransferBuilder.generateObservations( ...
    cfg, assets, epoch_s);
assert(isequal(obsA{1}.processedValue,obsB{1}.processedValue), ...
    'FAIL: generateObservations must be deterministic (identity-keyed noise) for identical inputs.');
fprintf('  PASS generateObservations is deterministic given the same cfg/assets/epoch\n');
end

% ================================================================================================
function cfg = i_islFleetConfig_()
cfg = masterConfig();
cfg.simulation.duration_s = 4;
cfg.simulation.dt_s = 1;
cfg.report.writePdf = false;
cfg.report.writeMat = false;
cfg.report.compileTex = 'never';
cfg.plots.enable = false;
cfg.plots.showFigures = false;
cfg.scenario.nSpaceAssets = 2;
cfg.measurements.isl.enable = true;
cfg.measurements.isl.twoWay.enable = true;
cfg.measurements.isl.twoWay.links = struct( ...
    'enable',true,'linkIdentifier','isl-link-1-2','initiatorAssetIndex',1,'transponderAssetIndex',2, ...
    'signalIdentifier','ISL-PN','channelIdentifier','PN-1', ...
    'schedule',struct('updatePhase_s',0,'commandIdentifier','scenario-open-loop'), ...
    'turnaroundCalibrationError_s',0,'terminalCalibrationError_s',0, ...
    'physicalChainIdentifier','isl-two-way-code-chain', ...
    'calibrationProductIdentifier','isl-two-way-code-calibration');
cfg.measurements.isl.twoWay.schedule.updatePeriod_s = 1;
cfg.measurements.isl.twoWay.schedule.start_s = 0;
cfg.measurements.isl.twoWay.schedule.stop_s = 1e6;
end

% ================================================================================================
function [cfg, sim1, sim2, epoch_s] = i_islSimFixture_()
cfg = i_islFleetConfig_();
setup = revgnss.IndependentFleetScenarioFactory.federatedSetup(cfg, false);
cfg1 = revgnss.IndependentFleetScenarioFactory.stageOneLeafConfigForIndex(setup, cfg, 1);
cfg2 = revgnss.IndependentFleetScenarioFactory.stageOneLeafConfigForIndex(setup, cfg, 2);
sim1 = revgnss.ReverseGNSSSimulation(cfg1);
sim1.initialize(); sim1.advanceTruthEpoch(1); sim1.runLocalEstimationEpoch(1);
sim2 = revgnss.ReverseGNSSSimulation(cfg2);
sim2.initialize(); sim2.advanceTruthEpoch(1); sim2.runLocalEstimationEpoch(1);
epoch_s = sim1.tVec(sim1.lastEstimatedEpoch);
end
