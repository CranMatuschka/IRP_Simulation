function test_four_timestamp_clock_difference_link_update_adapter()
% test_four_timestamp_clock_difference_link_update_adapter  Plan Section 4.4, Stage-4 named test.
% revgnss.FourTimestampClockDifferenceLinkUpdateAdapter -- the 5th revgnss.DistributedLinkUpdateAdapter,
% for the direct four-timestamp ISL clock-difference observable. This is the test
% revgnss.SplitCovarianceIntersectionBound.ObservablesWithDemonstratedConservativeBound's own
% comment cites as demonstrating this observable's bound.
%
% CLASSIFICATION FINDING (measured, not assumed): a live 14-column
% revgnss.FourTimestampObservableLinearization.islTwoEndpointJacobian evaluation on the shipped
% masterConfig geometry (commonAperture, identical tx/rx phase-centre offsets) gives structurally
% nonzero but SMALL position/velocity/attitude/clockDrift sensitivity (position/attitude ~1e-6-
% 1e-5, velocity/drift ~2e-4-5e-4) -- the columns do not cancel to exactly zero the way
% relativeBiasOnly requires, and under any user-declared geometry with a genuine lever arm
% (distinct tx/rx offsets) the attitude columns grow to O(0.1-0.6) (see
% tests/test_four_timestamp_ground_space_finite_difference_jacobian.m's own fixture). Unlike
% revgnss.FirstOrderReciprocalClockTransferLinkUpdateAdapter, whose relativeBiasOnly status comes
% from a deliberate modeling choice (the reciprocity term, the only source of any such dependence
% in that model, is always refused), this observable's light-time-based physics couples to every
% column structurally, not merely under a particular config. It is therefore classified
% 'notAClockObservable' by revgnss.DistributedClockGaugeContract, matching
% revgnss.CoherentTwoWayRangeLinkUpdateAdapter's own "rich, multi-component" shape, even though
% its dominant term is still the same +-1 common-mode-blind clock-bias signature.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
addpath(rootDir);
addpath(fullfile(rootDir,'config'));
addpath(fullfile(rootDir,'config','internal'));

fprintf('=== test_four_timestamp_clock_difference_link_update_adapter ===\n');
fixture = i_fixture_();
i_test_delivery_accepted_and_notAClockObservable_(fixture);
i_test_residual_closure_within_declared_uncertainty_(fixture);
i_test_jacobian_matches_islTwoEndpointJacobian_directly_(fixture);
i_test_dominant_clock_bias_columns_are_plus_minus_one_(fixture);
i_test_remote_contribution_covariance_exact_(fixture);
i_test_requires_raw_timestamp_tags_(fixture);
i_test_rejects_reciprocity_term_(fixture);
i_test_persistent_calibration_treatment_enforced_(fixture);
fprintf('=== test_four_timestamp_clock_difference_link_update_adapter: ALL PASS ===\n');
end

% ================================================================================================
function i_test_delivery_accepted_and_notAClockObservable_(fixture)
assert(~fixture.rejection.rejected,'FAIL: fixture delivery must be accepted (%s / %s).', ...
    fixture.rejection.reasonCode,fixture.rejection.reasonMessage);
assert(strcmp(fixture.delivery.clockClaim,'notAClockObservable'), ...
    'FAIL: fourTimestampClockDifference must be notAClockObservable.');
audit = revgnss.DistributedClockGaugeContract.requireClockObservability( ...
    fixture.block,fixture.delivery,fixture.ownerState,fixture.remoteState, ...
    fixture.delivery.clockClaim,fixture.block.observableRowUnits);
assert(strcmp(audit.auditVerdict,'notAClockObservable'));
fprintf('  PASS delivery accepted, clockClaim=notAClockObservable, audit agrees\n');
end

% ================================================================================================
function i_test_residual_closure_within_declared_uncertainty_(fixture)
% Combined-review T1 (most important coverage gap): nothing previously bounded block.residual_m
% against the declared uncertainty -- a sign flip or an origin/anchor endpoint-order swap in
% buildUpdateBlock would still leave every other assertion in this file passing (they check
% shape/finiteness/exact-formula-reproduction, not physical plausibility), since the residual
% would simply have blown up. Rtotal = own-row measurement covariance + the remote endpoint's
% contribution through H_remote (both real, declared quantities on the block itself).
Rtotal_m2 = fixture.block.independentMeasurementCovariance_m2 + ...
    trace(fixture.block.remoteContributionCovariance_m2);
assert(isfinite(Rtotal_m2) && Rtotal_m2 > 0);
assert(abs(fixture.block.residual_m) < 10*sqrt(Rtotal_m2), ...
    'FAIL: |residual_m|=%.4f m must be within 10 sigma of sqrt(Rtotal)=%.4f m.', ...
    abs(fixture.block.residual_m),sqrt(Rtotal_m2));
fprintf('  PASS residual_m=%.4f m is within 10 sigma of sqrt(Rtotal)=%.4f m\n', ...
    fixture.block.residual_m,sqrt(Rtotal_m2));
end

% ================================================================================================
function i_test_jacobian_matches_islTwoEndpointJacobian_directly_(fixture)
assert(numel(fixture.block.ownerJacobian_mPerErrorUnit)==14);
assert(numel(fixture.block.remoteJacobian_mPerErrorUnit)==14);
assert(isfinite(fixture.diagnostics.predictedValue_m));

options = struct('linearizationSteps',fixture.steps,'solverOptions',struct());
[H_owner, H_remote, ~, ~, ~] = revgnss.FourTimestampObservableLinearization.islTwoEndpointJacobian( ...
    fixture.ownerState, fixture.remoteState, 'origin', fixture.calibrationProduct, ...
    fixture.delivery.coordinateEventEpoch_s, options);
assert(isequal(fixture.block.ownerJacobian_mPerErrorUnit,H_owner));
assert(isequal(fixture.block.remoteJacobian_mPerErrorUnit,H_remote));
fprintf('  PASS H_owner/H_remote reproduce a fresh islTwoEndpointJacobian call exactly\n');
end

% ================================================================================================
function i_test_dominant_clock_bias_columns_are_plus_minus_one_(fixture)
biasIdx = find(strcmp(fixture.ownerState.covarianceComponentOrder,'clockBiasError_m'),1);
assert(~isempty(biasIdx),'FAIL: fixture endpoint state has no clockBiasError_m component.');
assert(abs(fixture.block.ownerJacobian_mPerErrorUnit(biasIdx)-(-1)) < 1e-9);
assert(abs(fixture.block.remoteJacobian_mPerErrorUnit(biasIdx)-1) < 1e-9);
fprintf('  PASS dominant clockBias columns are exactly -1 (owner) / +1 (remote)\n');
end

% ================================================================================================
function i_test_remote_contribution_covariance_exact_(fixture)
Hj = fixture.block.remoteJacobian_mPerErrorUnit;
expected = Hj*fixture.remoteState.covarianceBlock*Hj';
expected = (expected+expected')/2;
assert(norm(fixture.block.remoteContributionCovariance_m2-expected,'fro') < ...
    1e-9*max(1,norm(expected,'fro')));
fprintf('  PASS remoteContributionCovariance_m2 == H_remote*P_remote*H_remote'' exactly\n');
end

% ================================================================================================
function i_test_requires_raw_timestamp_tags_(fixture)
badFields = fixture.obs.toStruct();
badFields.rawTimestampTagsAvailable = false;
threw = false;
try
    revgnss.InterSatelliteFourTimestampObservationRecord(badFields);
catch ME
    threw = strcmp(ME.identifier,'InterSatelliteFourTimestampObservationRecord:rawTimestampTagsAvailable');
end
assert(threw,'FAIL: the record itself must reject rawTimestampTagsAvailable=false.');
fprintf('  PASS record construction rejects rawTimestampTagsAvailable=false\n');
end

% ================================================================================================
function i_test_rejects_reciprocity_term_(fixture)
badFields = fixture.obs.toStruct();
badFields.reciprocityTermIncluded = true;
threw = false;
try
    revgnss.InterSatelliteFourTimestampObservationRecord(badFields);
catch ME
    threw = strcmp(ME.identifier,'InterSatelliteFourTimestampObservationRecord:reciprocityTermIncluded');
end
assert(threw,'FAIL: the record itself must reject reciprocityTermIncluded=true.');
fprintf('  PASS record construction rejects reciprocityTermIncluded=true\n');
end

% ================================================================================================
function i_test_persistent_calibration_treatment_enforced_(fixture)
badArgs = fixture.buildArgs;
badArgs.persistentCalibrationTreatment = 'externalCalibrationProduct';
threw = false;
try
    revgnss.FourTimestampClockDifferenceLinkUpdateAdapter.buildUpdateBlock(badArgs);
catch ME
    threw = strcmp(ME.identifier, ...
        'FourTimestampClockDifferenceLinkUpdateAdapter:persistentCalibrationTreatment');
end
assert(threw,'FAIL: only persistentCalibrationTreatment=''rejected'' must be accepted.');
fprintf('  PASS non-rejected persistentCalibrationTreatment refused\n');
end

% ================================================================================================
function fixture = i_fixture_()
cfg = masterConfig();
cfg.simulation.duration_s = 4;
cfg.simulation.dt_s = 1;
cfg.report.writePdf = false;
cfg.report.writeMat = false;
cfg.report.compileTex = 'never';
cfg.plots.enable = false;
cfg.plots.showFigures = false;

fleetCfg = cfg;
fleetCfg.scenario.nSpaceAssets = 2;
fleetCfg.measurements.isl.enable = true;
fleetCfg.measurements.isl.twoWay.enable = true;
fleetCfg.measurements.isl.twoWay.links = struct( ...
    'enable',true,'linkIdentifier','isl-link-1-2','initiatorAssetIndex',1,'transponderAssetIndex',2, ...
    'signalIdentifier','ISL-PN','channelIdentifier','PN-1', ...
    'schedule',struct('updatePhase_s',0,'commandIdentifier','scenario-open-loop'), ...
    'turnaroundCalibrationError_s',0,'terminalCalibrationError_s',0, ...
    'physicalChainIdentifier','isl-two-way-code-chain', ...
    'calibrationProductIdentifier','isl-two-way-code-calibration');
fleetCfg.measurements.isl.twoWay.schedule.updatePeriod_s = 1;
fleetCfg.measurements.isl.twoWay.schedule.start_s = 0;
fleetCfg.measurements.isl.twoWay.schedule.stop_s = 1e6;

setup = revgnss.IndependentFleetScenarioFactory.federatedSetup(fleetCfg, false);
cfg1 = revgnss.IndependentFleetScenarioFactory.stageOneLeafConfigForIndex(setup, fleetCfg, 1);
cfg2 = revgnss.IndependentFleetScenarioFactory.stageOneLeafConfigForIndex(setup, fleetCfg, 2);
sim1 = revgnss.ReverseGNSSSimulation(cfg1);
sim1.initialize(); sim1.advanceTruthEpoch(1); sim1.runLocalEstimationEpoch(1);
sim2 = revgnss.ReverseGNSSSimulation(cfg2);
sim2.initialize(); sim2.advanceTruthEpoch(1); sim2.runLocalEstimationEpoch(1);

epoch_s = sim1.tVec(sim1.lastEstimatedEpoch);
assets = {sim1.asset, sim2.asset};

revgnss.InterSatelliteFourTimestampTimeTransferBuilder.validateConfig(fleetCfg);
[observations, ~, ~] = revgnss.InterSatelliteFourTimestampTimeTransferBuilder. ...
    generateObservations(fleetCfg, assets, epoch_s);
assert(numel(observations)==1,'FAIL: expected exactly 1 scheduled four-timestamp ISL observation.');
obs = observations{1};
assert(isa(obs,'revgnss.InterSatelliteFourTimestampObservationRecord'));

commonSourceTreatment = struct('towerClockProduct','rejected','terminalCalibration','rejected', ...
    'transmittedStateProduct','rejected','sessionTimingProduct','rejected', ...
    'sharedForceAtmosphericProduct','rejected');
ownerGeom = revgnss.FourTimestampPhysicalLinkConfig.shortNameIslTerminalGeometry(fleetCfg,1);
ownerTerminal = struct('declared',true, ...
    'transmitTerminalIdentifier',ownerGeom.transmitTerminalIdentifier, ...
    'receiveTerminalIdentifier',ownerGeom.receiveTerminalIdentifier, ...
    'transmitAntennaIdentifier',ownerGeom.transmitAntennaIdentifier, ...
    'receiveAntennaIdentifier',ownerGeom.receiveAntennaIdentifier, ...
    'transmitPhaseCentreOffset_body_m',ownerGeom.transmitOffset_body_m, ...
    'receivePhaseCentreOffset_body_m',ownerGeom.receiveOffset_body_m);
remoteGeom = revgnss.FourTimestampPhysicalLinkConfig.shortNameIslTerminalGeometry(fleetCfg,2);
remoteTerminal = struct('declared',true, ...
    'transmitTerminalIdentifier',remoteGeom.transmitTerminalIdentifier, ...
    'receiveTerminalIdentifier',remoteGeom.receiveTerminalIdentifier, ...
    'transmitAntennaIdentifier',remoteGeom.transmitAntennaIdentifier, ...
    'receiveAntennaIdentifier',remoteGeom.receiveAntennaIdentifier, ...
    'transmitPhaseCentreOffset_body_m',remoteGeom.transmitOffset_body_m, ...
    'receivePhaseCentreOffset_body_m',remoteGeom.receiveOffset_body_m);

ownerProvider = revgnss.OwnerLocalEstimatorEndpointProvider.fromLocalSimulation(sim1,1,epoch_s,ownerTerminal);
diagnosticProduct2 = revgnss.EndpointStateProduct.fromLocalEstimator( ...
    sim2,2,epoch_s,0,'spacecraft:2:epoch:four-timestamp-adapter-test');
eligibleProduct2 = revgnss.EstimatorEligibleEndpointStateProduct.fromDiagnosticProduct( ...
    diagnosticProduct2,commonSourceTreatment);
remoteProvider = revgnss.FrozenProductEndpointProvider.fromEstimatorEligibleProduct( ...
    eligibleProduct2,epoch_s,remoteTerminal);

proposeArgs = struct( ...
    'physicalObservationRecord',obs,'ownerProvider',ownerProvider,'remoteProvider',remoteProvider, ...
    'ownerPolicy','initiator','roleReversalPolicy','disabled', ...
    'remoteProductPropagationPolicy','frozenSameEpochOnly', ...
    'stateExchangeSettings',struct('maximumAge_s',0,'deliveryDelay_s',0), ...
    'outOfSequencePolicy','reject','commonSourceTreatment',commonSourceTreatment, ...
    'correlationPolicy','splitCovarianceIntersection','calibrationRegistry',[], ...
    'deliveryEpoch_s',epoch_s,'coordinateEventEpoch_s',epoch_s, ...
    'observableIdentifier','fourTimestampClockDifference','persistentCalibrationTreatment','rejected', ...
    'configurationSnapshot',fleetCfg);
[delivery, rejection] = revgnss.LinkObservationDelivery.tryPropose(proposeArgs);

ownerState = delivery.ownerProvider.stateAtCoordinateEpoch(delivery.coordinateEventEpoch_s);
remoteState = delivery.remoteProvider.stateAtCoordinateEpoch(delivery.coordinateEventEpoch_s);
calibrationProduct = revgnss.FourTimestampPhysicalLinkConfig.hardwareModel(fleetCfg,'isl','calibrationProduct');
steps = revgnss.FourTimestampObservableLinearization.DefaultLinearizationSteps;
buildArgs = struct('delivery',delivery,'ownerState',ownerState,'remoteState',remoteState, ...
    'calibrationProduct',calibrationProduct,'linearizationSteps',steps,'solverOptions',struct(), ...
    'weightSelectionRule','fixedDeclaredWeights','persistentCalibrationTreatment','rejected');
[block, diagnostics] = revgnss.FourTimestampClockDifferenceLinkUpdateAdapter.buildUpdateBlock(buildArgs);
revgnss.DistributedLinkUpdateAdapter.requireUpdateBlock(block,delivery,ownerState,remoteState);

fixture = struct('cfg',cfg,'fleetCfg',fleetCfg,'sim1',sim1,'sim2',sim2,'obs',obs, ...
    'ownerState',ownerState,'remoteState',remoteState,'calibrationProduct',calibrationProduct, ...
    'steps',steps,'delivery',delivery,'rejection',rejection,'buildArgs',buildArgs, ...
    'block',block,'diagnostics',diagnostics);
end
