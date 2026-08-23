function test_four_timestamp_ground_space_atmosphere_truth_model_separation()
% test_four_timestamp_ground_space_atmosphere_truth_model_separation  Plan Section 4.4, Stage-4
% named test (previously deferred until Section 4.4 in the plan doc).
%
% What "atmosphere" currently means for this observable, measured directly (not assumed):
% revgnss.DirectReciprocalTimeTransferBuilder.buildFromGroundToSpace's applyAtmosphere/
% atmosphereVariance_s2 options feed ONLY revgnss.ReciprocalTimeTransferCovarianceBuilder.
% atmosphereBlock, contributing to the TRUTH exchange record's OWN covarianceBlock -- they do NOT
% add any delay term to revgnss.ReciprocalTimestampEventModel.solveDirectRoundTrip's timestamp
% events (confirmed by direct read: no delay-model call exists in that path for atmosphere). And
% revgnss.FourTimestampGroundSpaceTimeTransferBuilder.build's own Ri is computed independently of
% that block entirely. Toggling applyAtmosphere therefore changes the TRUTH RECORD's declared
% covariance (a real, measurable effect at that layer, exercised directly below) but would change
% NOTHING in the z/h/H/R rows this builder hands to the EKF -- exactly the "declared but inert"
% pattern plan invariant 6 exists to forbid. Combined-review finding M5: rather than accept and
% silently no-op, revgnss.FourTimestampGroundSpaceTimeTransferBuilder.validateConfig now REFUSES
% applyAtmosphere=true outright (error identifier
% FourTimestampGroundSpaceTimeTransferBuilder:atmosphereNotWired) until a later stage wires a
% real delay/R contribution. This test documents both halves: the truth-record-only effect that
% DOES exist (still reachable via revgnss.DirectReciprocalTimeTransferBuilder directly), and the
% loud refusal at this builder's own config-validation boundary.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
addpath(rootDir);
addpath(fullfile(rootDir,'config'));
addpath(fullfile(rootDir,'config','internal'));

fprintf('=== test_four_timestamp_ground_space_atmosphere_truth_model_separation ===\n');
i_test_validateConfig_accepts_off_refuses_on_();
i_test_truth_record_covariance_grows_with_atmosphere_applied_();
i_test_truth_record_covariance_unaffected_when_atmosphere_not_applied_but_variance_supplied_is_refused_();
i_test_sim_initialize_refuses_applyAtmosphere_true_();
fprintf(['=== test_four_timestamp_ground_space_atmosphere_truth_model_separation: ' ...
    'ALL PASS ===\n']);
end

% ================================================================================================
function i_test_validateConfig_accepts_off_refuses_on_()
cfgOff = i_baseGroundSpaceConfig_();
cfgOff.measurements.twoWayTimeTransfer.fourTimestampPhysical.applyAtmosphere = false;
cfgOff.measurements.twoWayTimeTransfer.fourTimestampPhysical.atmosphereVariance_s2 = [];
revgnss.FourTimestampGroundSpaceTimeTransferBuilder.validateConfig(cfgOff);

cfgOn = i_baseGroundSpaceConfig_();
cfgOn.measurements.twoWayTimeTransfer.fourTimestampPhysical.applyAtmosphere = true;
cfgOn.measurements.twoWayTimeTransfer.fourTimestampPhysical.atmosphereVariance_s2 = 1e-20;
threw = false;
try
    revgnss.FourTimestampGroundSpaceTimeTransferBuilder.validateConfig(cfgOn);
catch ME
    threw = strcmp(ME.identifier,'FourTimestampGroundSpaceTimeTransferBuilder:atmosphereNotWired');
end
assert(threw,'FAIL: validateConfig must refuse applyAtmosphere=true regardless of atmosphereVariance_s2.');
fprintf('  PASS validateConfig accepts atmosphere off, refuses atmosphere on (M5)\n');
end

% ================================================================================================
function i_test_truth_record_covariance_grows_with_atmosphere_applied_()
[towerTruth_ecef_m,towerGeom,spaceAsset,spaceGeom,hardware] = i_truthFixture_();

recordOff = revgnss.DirectReciprocalTimeTransferBuilder.buildFromGroundToSpace( ...
    towerTruth_ecef_m,0,0,'tower:1',towerGeom,spaceAsset,1,spaceGeom,hardware,10, ...
    exchangeIdentifier='e:off',sessionIdentifier='s:off',protocolIdentifier='directFourTimestampTwoWay', ...
    signalIdentifier='TWSTFT-4TS',channelIdentifier='t001',carrierFrequency_Hz=2.2e9, ...
    counterTagSigma_s=zeros(1,4),counterTagLabels={'t1','t2','t3','t4'}, ...
    applyAtmosphere=false,atmosphereVariance_s2=[]);
recordOn = revgnss.DirectReciprocalTimeTransferBuilder.buildFromGroundToSpace( ...
    towerTruth_ecef_m,0,0,'tower:1',towerGeom,spaceAsset,1,spaceGeom,hardware,10, ...
    exchangeIdentifier='e:on',sessionIdentifier='s:on',protocolIdentifier='directFourTimestampTwoWay', ...
    signalIdentifier='TWSTFT-4TS',channelIdentifier='t001',carrierFrequency_Hz=2.2e9, ...
    counterTagSigma_s=zeros(1,4),counterTagLabels={'t1','t2','t3','t4'}, ...
    applyAtmosphere=true,atmosphereVariance_s2=1e-16);

assert(trace(recordOn.covarianceBlock) > trace(recordOff.covarianceBlock), ...
    'FAIL: applying atmosphere must grow the truth exchange record''s own declared covariance.');
fprintf('  PASS truth exchange record covariance trace grows with atmosphere applied (%.3e -> %.3e)\n', ...
    trace(recordOff.covarianceBlock),trace(recordOn.covarianceBlock));
end

% ================================================================================================
function i_test_truth_record_covariance_unaffected_when_atmosphere_not_applied_but_variance_supplied_is_refused_()
[towerTruth_ecef_m,towerGeom,spaceAsset,spaceGeom,hardware] = i_truthFixture_();
threw = false;
try
    revgnss.DirectReciprocalTimeTransferBuilder.buildFromGroundToSpace( ...
        towerTruth_ecef_m,0,0,'tower:1',towerGeom,spaceAsset,1,spaceGeom,hardware,10, ...
        exchangeIdentifier='e:bad',sessionIdentifier='s:bad', ...
        protocolIdentifier='directFourTimestampTwoWay', ...
        signalIdentifier='TWSTFT-4TS',channelIdentifier='t001',carrierFrequency_Hz=2.2e9, ...
        counterTagSigma_s=zeros(1,4),counterTagLabels={'t1','t2','t3','t4'}, ...
        applyAtmosphere=false,atmosphereVariance_s2=1e-16);
catch ME
    threw = strcmp(ME.identifier,'DirectReciprocalTimeTransferBuilder:atmosphereVarianceNotApplicable');
end
assert(threw,'FAIL: supplying atmosphereVariance_s2 with applyAtmosphere=false must be refused.');
fprintf('  PASS supplying an unused atmosphereVariance_s2 is refused (Stage 4.2 consistency guard)\n');
end

% ================================================================================================
function i_test_sim_initialize_refuses_applyAtmosphere_true_()
% Combined-review M5: applyAtmosphere=true must be refused at config-validation time (this
% builder's validateConfig, reached via revgnss.ConfigFactory.finalizeConfig during
% revgnss.ReverseGNSSSimulation.initialize), not merely left "inert but reachable" the way an
% earlier cut of this test proved z/h/H/R stayed byte-identical on vs off. That earlier byte-
% identical behavior is no longer reachable at all -- construction itself now fails loudly.
cfgOff = i_baseGroundSpaceConfig_();
cfgOff.measurements.twoWayTimeTransfer.fourTimestampPhysical.applyAtmosphere = false;
[z,~,~,~] = i_runBuild_(cfgOff);
assert(numel(z) > 0,'FAIL: the atmosphere-off fixture must still produce real rows.');

cfgOn = i_baseGroundSpaceConfig_();
cfgOn.measurements.twoWayTimeTransfer.fourTimestampPhysical.applyAtmosphere = true;
cfgOn.measurements.twoWayTimeTransfer.fourTimestampPhysical.atmosphereVariance_s2 = 1e-16;
threw = false;
try
    revgnss.ReverseGNSSSimulation(cfgOn).initialize();
catch ME
    threw = strcmp(ME.identifier,'FourTimestampGroundSpaceTimeTransferBuilder:atmosphereNotWired');
end
assert(threw,'FAIL: ReverseGNSSSimulation.initialize() must refuse applyAtmosphere=true via validateConfig.');
fprintf('  PASS applyAtmosphere=false initializes and produces rows; applyAtmosphere=true is refused at initialize()\n');
end

% ================================================================================================
function [z,h,H,R] = i_runBuild_(cfg)
sim = revgnss.ReverseGNSSSimulation(cfg);
sim.initialize();
sim.advanceTruthEpoch(1);
sim.runLocalEstimationEpoch(1);
t_s = sim.tVec(sim.lastEstimatedEpoch);
[z,h,H,R,~] = revgnss.TwoWayTimeTransferBuilder.build( ...
    cfg, sim.errorChain, sim.asset, sim.towers, sim.ekf.getMeasurementState(), sim.ekf.stateMap, ...
    sim.ekf.nx, t_s);
end

% ================================================================================================
function cfg = i_baseGroundSpaceConfig_()
cfg = masterConfig();
cfg.simulation.duration_s = 4;
cfg.simulation.dt_s = 1;
cfg.report.writePdf = false;
cfg.report.writeMat = false;
cfg.report.compileTex = 'never';
cfg.plots.enable = false;
cfg.plots.showFigures = false;
cfg.measurements.twoWayTimeTransfer.enable = true;
cfg.measurements.twoWayTimeTransfer.useInEKF = true;
cfg.measurements.twoWayTimeTransfer.mode = 'fourTimestampClockDifference';
end

% ================================================================================================
function [towerTruth_ecef_m,towerGeom,spaceAsset,spaceGeom,hardware] = i_truthFixture_()
cfg = i_baseGroundSpaceConfig_();
sim = revgnss.ReverseGNSSSimulation(cfg);
sim.initialize();
sim.advanceTruthEpoch(1);
towerTruth_ecef_m = models.measurements.MeasurementModelUtils.towerPositionEcef( ...
    cfg,sim.towers{1},1,'truth',sim.tVec(1));
towerGeom = revgnss.FourTimestampPhysicalLinkConfig.shortNameGroundSpaceTerminalGeometry( ...
    cfg,'tower','four-timestamp:tower:1');
spaceGeom = revgnss.FourTimestampPhysicalLinkConfig.shortNameGroundSpaceTerminalGeometry( ...
    cfg,'spacecraft','four-timestamp:spacecraft');
spaceAsset = sim.asset;
hardware = revgnss.FourTimestampPhysicalLinkConfig.hardwareModel(cfg,'groundSpace','physicalTruth');
end
