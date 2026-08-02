function test_relay_twstft_common_delay_covariance()
% test_relay_twstft_common_delay_covariance  Plan Section 4.5. Verifies the seconds^2-domain
% session-common covariance (revgnss.GroundRelaySessionCommonCovarianceGroup, assembled by
% revgnss.GroundRelayTimeTransferSessionBuilder into revgnss.
% ReciprocalTimeTransferCovarianceBuilder.relayBlock -- its first real caller): domain safety,
% persistence (not white noise), and no double-count between per-pass and session-level covariance.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
addpath(rootDir);
addpath(fullfile(rootDir,'config'));
addpath(fullfile(rootDir,'config','internal'));

fprintf('=== test_relay_twstft_common_delay_covariance ===\n');
i_test_domain_never_crosses_to_metres_squared_();
i_test_whitePerRow_forbidden_();
i_test_relayBlock_bitidentical_passthrough_();
i_test_persistence_bitidentical_across_sessions_();
i_test_no_double_count_in_per_pass_records_();
i_test_atmosphere_routed_to_all_four_slots_when_enabled_();
i_test_temporal_model_survives_onto_observable_();
fprintf('=== test_relay_twstft_common_delay_covariance: ALL PASS ===\n');
end

% ================================================================================================
function i_test_temporal_model_survives_onto_observable_()
% Combined review m4: temporalCovarianceModel previously never reached the final observable at
% all -- a consumer of buildSession's return value alone had no way to see WHY the session-common
% covariance is temporally correlated rather than white. sessionCommonTemporalModels must carry
% each declared source's own model, one entry per sessionCommonComponentOrder label.
cfg = i_baseCfg_();
cfg.measurements.groundRelayTimeTransfer.sessionCommonCovariance.relayGroupDelaySigma_s = 1e-9;
cfg.measurements.groundRelayTimeTransfer.sessionCommonCovariance.atmosphereSigma_s = 2e-9;
[stationATruth,stationBTruth,relayAssetTruth] = i_truthEndpoints_();
observable = revgnss.GroundRelayTimeTransferSessionBuilder.buildSession( ...
    cfg,stationATruth,stationBTruth,relayAssetTruth,[]);
assert(numel(observable.sessionCommonTemporalModels)==numel(observable.sessionCommonComponentOrder), ...
    'FAIL: sessionCommonTemporalModels must have one entry per sessionCommonComponentOrder label.');
relayIdx = find(startsWith(observable.sessionCommonComponentOrder,'relayGroupDelay:'),1);
atmoIdx = find(startsWith(observable.sessionCommonComponentOrder,'sharedAtmosphere:'),1);
assert(~isempty(relayIdx) && ~isempty(atmoIdx));
assert(strcmp(observable.sessionCommonTemporalModels{relayIdx},'firstOrderGaussMarkov'));
assert(strcmp(observable.sessionCommonTemporalModels{atmoIdx},'firstOrderGaussMarkov'));
% Default (no session-common sources declared) case: both cells empty, no length mismatch.
cfgOff = i_baseCfg_();
observableOff = revgnss.GroundRelayTimeTransferSessionBuilder.buildSession( ...
    cfgOff,stationATruth,stationBTruth,relayAssetTruth,[]);
assert(isempty(observableOff.sessionCommonTemporalModels) && isempty(observableOff.sessionCommonComponentOrder));
fprintf('  PASS sessionCommonTemporalModels carries each declared source''s own temporal model onto the observable\n');
end

% ================================================================================================
function i_test_domain_never_crosses_to_metres_squared_()
% A revgnss.CommonSourceCovarianceGroup (metres^2-domain) must never be accepted by this
% seconds^2-domain subsystem's own group type -- distinct classes, never isa-compatible.
group = revgnss.GroundRelaySessionCommonCovarianceGroup(struct( ...
    'covarianceGroupIdentifier','g1','commonSourceName','relayGroupDelay', ...
    'sharedCovarianceContribution_s2',1e-18,'memberRowCount',1, ...
    'temporalCovarianceModel','firstOrderGaussMarkov','correlationTime_s',1e9, ...
    'validFromEpoch_s',-1e12,'validUntilEpoch_s',1e12));
assert(~isa(group,'revgnss.CommonSourceCovarianceGroup'), ...
    'FAIL: revgnss.GroundRelaySessionCommonCovarianceGroup must never be isa revgnss.CommonSourceCovarianceGroup.');
threw = false;
try
    revgnss.ReciprocalTimeTransferCovarianceBuilder.sessionCommonModeBlock(group);
catch
    threw = true;
end
assert(threw,'FAIL: sessionCommonModeBlock must refuse a revgnss.GroundRelaySessionCommonCovarianceGroup by type.');
fprintf('  PASS seconds^2-domain group is never isa-compatible with the metres^2-domain type; sessionCommonModeBlock refuses it by type\n');
end

% ================================================================================================
function i_test_whitePerRow_forbidden_()
threw = false;
try
    revgnss.GroundRelaySessionCommonCovarianceGroup(struct( ...
        'covarianceGroupIdentifier','g1','commonSourceName','relayGroupDelay', ...
        'sharedCovarianceContribution_s2',1e-18,'memberRowCount',1, ...
        'temporalCovarianceModel','whitePerRow','correlationTime_s',0, ...
        'validFromEpoch_s',-1e12,'validUntilEpoch_s',1e12));
catch ME
    threw = strcmp(ME.identifier,'GroundRelaySessionCommonCovarianceGroup:whiteNoiseTreatmentForbidden');
end
assert(threw,'FAIL: temporalCovarianceModel=whitePerRow must be constructor-refused (invariant 8).');
fprintf('  PASS whitePerRow is constructor-forbidden\n');
end

% ================================================================================================
function i_test_relayBlock_bitidentical_passthrough_()
cfg = i_baseCfg_();
cfg.measurements.groundRelayTimeTransfer.sessionCommonCovariance.relayGroupDelaySigma_s = 1e-9;
groups = revgnss.GroundRelayPhysicalLinkConfig.sessionCommonGroups(cfg);
assert(numel(groups)==1);
directBlock = struct('covariance',groups(1).sharedCovarianceContribution_s2, ...
    'componentOrder',{{groups(1).commonSourceName}},'sourceIdentifiers',{{groups(1).covarianceGroupIdentifier}});
resultDirect = revgnss.ReciprocalTimeTransferCovarianceBuilder.relayBlock(directBlock);
assert(isequal(resultDirect.covariance,directBlock.covariance));
assert(isequal(resultDirect.componentOrder,directBlock.componentOrder));
fprintf('  PASS relayBlock is a bit-identical pass-through for a well-formed session-common block\n');
end

% ================================================================================================
function i_test_persistence_bitidentical_across_sessions_()
% Combined review T4: an un-reviewed first cut left sessionCommonCovariance.* entirely at its
% zero default here, so both observables' sessionCommonCovariance_s2 were bit-identical only
% because both were the SAME vacuous zeros(0,0) -- the persistence claim was untested. A nonzero
% relayGroupDelaySigma_s makes the bit-identical assertion genuinely load-bearing.
cfg = i_baseCfg_();
cfg.measurements.groundRelayTimeTransfer.sessionCommonCovariance.relayGroupDelaySigma_s = 7e-9;
cfg.measurements.groundRelayTimeTransfer.hardware.stationATransmitDelay_s = 300e-9;
cfg.measurements.groundRelayTimeTransfer.truth.stationATransmitDelayError_s = 20e-9;
[stationATruth,stationBTruth,relayAssetTruth] = i_truthEndpoints_();

observable1 = revgnss.GroundRelayTimeTransferSessionBuilder.buildSession( ...
    cfg,stationATruth,stationBTruth,relayAssetTruth,[]);
cfg2 = cfg;
cfg2.measurements.groundRelayTimeTransfer.schedule.forwardReceptionEpoch_s = 30;
cfg2.measurements.groundRelayTimeTransfer.schedule.returnReceptionEpoch_s = 40;
observable2 = revgnss.GroundRelayTimeTransferSessionBuilder.buildSession( ...
    cfg2,stationATruth,stationBTruth,relayAssetTruth,[]);

assert(~isempty(observable1.sessionCommonCovariance_s2) && observable1.sessionCommonCovariance_s2(1,1) > 0, ...
    'FAIL: fixture must declare a genuinely nonzero sessionCommonCovariance_s2 for this test to be non-vacuous.');
assert(isequal(observable1.sessionCommonCovariance_s2,observable2.sessionCommonCovariance_s2), ...
    'FAIL: sessionCommonCovariance_s2 must be bit-identical across independent sessions at different epochs.');
assert(abs(observable1.sessionCommonCovariance_s2(1,1) - 7e-9^2) < 1e-30, ...
    'FAIL: sessionCommonCovariance_s2 must not shrink (e.g. be divided by session count) -- it must equal sigma^2 exactly.');
% Positive point-estimate test (finding 4's non-cancelling mechanism): the induced bias from an
% asymmetric TX!=RX station delay error is identical (not shrunk/re-derived) across both sessions.
assert(abs(observable1.clockDifferenceValue_s - observable2.clockDifferenceValue_s) < 1e-9, ...
    'FAIL: the asymmetric-delay-induced bias must repeat identically, not be averaged away as white noise.');
assert(abs(observable1.clockDifferenceValue_s) > 1e-9, ...
    'FAIL: the asymmetric delay error must produce a genuinely nonzero bias in this fixture.');
fprintf('  PASS session-common covariance (genuinely nonzero) and its induced bias are bit-identical/repeatable across independent sessions (not white noise, not shrinking)\n');
end

% ================================================================================================
function i_test_no_double_count_in_per_pass_records_()
cfg = i_baseCfg_();
cfg.measurements.groundRelayTimeTransfer.sessionCommonCovariance.relayGroupDelaySigma_s = 1e-9;
cfg.measurements.groundRelayTimeTransfer.hardware.stationATransmitDelay_s = 100e-9;
[stationATruth,stationBTruth,relayAssetTruth] = i_truthEndpoints_();
observable = revgnss.GroundRelayTimeTransferSessionBuilder.buildSession( ...
    cfg,stationATruth,stationBTruth,relayAssetTruth,[]);
labels = observable.sessionCommonComponentOrder;
% Session-level labels come from commonSourceName:memberRow (e.g. 'relayGroupDelay:1') -- never a
% 'terminalModemDelay:*' label, which would only appear if a per-pass record had wrongly been
% given a nonempty terminalModemDelayBlock/relayBlock input (the double-count this design forbids).
assert(~any(cellfun(@(l) startsWith(l,'terminalModemDelay:'),labels)));
assert(any(startsWith(labels,'relayGroupDelay:')));
fprintf('  PASS session-level covariance never carries a terminalModemDelay:* label (no double-count)\n');
end

% ================================================================================================
function i_test_atmosphere_routed_to_all_four_slots_when_enabled_()
% Combined review T5: an un-reviewed first cut asserted only isa(observable,...) here, never the
% method's own name ("routed to all four slots") -- legAppliesAtmosphere and the two
% atmosphereDelay:* covariance rows on a raw buildOneWayPass record (bypassing buildSession, whose
% observable does not expose per-pass records) are asserted directly instead.
geom = struct('transmitOffset_body_m',zeros(3,1),'receiveOffset_body_m',zeros(3,1), ...
    'transmitTerminalIdentifier','tx','receiveTerminalIdentifier','rx', ...
    'transmitAntennaIdentifier','txa','receiveAntennaIdentifier','rxa');
stationA = revgnss.ReciprocalEndpointTruthProvider.fixedStation([6378137;0;0],0,0,'station:A',geom,10);
stationB = revgnss.ReciprocalEndpointTruthProvider.fixedStation([0;6378137;0],0,0,'station:B',geom,10);
relayAsset = struct('r_ecef_m',[42164000;0;0],'v_ecef_mps',[0;3074;0],'attitude_euler_rad',[0;0;0], ...
    'clock',struct('getBiasMeters',@() 0,'getDriftMetersPerSecond',@() 0));
relay = revgnss.ReciprocalEndpointTruthProvider.spacecraft(relayAsset,1,geom,10);
hardware = revgnss.GroundRelaySessionHardwareModel( ...
    parameterSource='physicalTruth',physicalChainIdentifier='chain-1', ...
    calibrationProductIdentifier='cal-1',relayGroupDelayNominal_s=1e-3);
hwForward = hardware.asEventSolverHardware('forward');
recordAtmo = revgnss.GroundRelayOneWayPassRecordBuilder.buildOneWayPass( ...
    stationA, relay, stationB, hwForward, 10, [1e-20, 1e-20], ...
    exchangeIdentifier='fwd:atmo',sessionIdentifier='sess:1',protocolIdentifier='p', ...
    signalIdentifier='s',channelIdentifier='c',carrierFrequency_Hz=14e9, ...
    counterTagSigma_s=zeros(1,4),counterTagLabels={'t1','t2','t3','t4'},applyAtmosphere=true);
assert(isequal(recordAtmo.legAppliesAtmosphere,true(1,4)), ...
    'FAIL: applyAtmosphere=true must set legAppliesAtmosphere==true(1,4) (all four slots).');
assert(any(strcmp(recordAtmo.covarianceComponentOrder,'atmosphereDelay:1')) && ...
    any(strcmp(recordAtmo.covarianceComponentOrder,'atmosphereDelay:2')), ...
    'FAIL: a nonempty atmosphereLegVariance_s2 must produce both atmosphereDelay:1/atmosphereDelay:2 covariance rows.');

recordNoAtmo = revgnss.GroundRelayOneWayPassRecordBuilder.buildOneWayPass( ...
    stationA, relay, stationB, hwForward, 10, [], ...
    exchangeIdentifier='fwd:noatmo',sessionIdentifier='sess:1',protocolIdentifier='p', ...
    signalIdentifier='s',channelIdentifier='c',carrierFrequency_Hz=14e9, ...
    counterTagSigma_s=zeros(1,4),counterTagLabels={'t1','t2','t3','t4'},applyAtmosphere=false);
assert(isequal(recordNoAtmo.legAppliesAtmosphere,false(1,4)));
assert(~any(startsWith(recordNoAtmo.covarianceComponentOrder,'atmosphereDelay:')));
fprintf('  PASS applyAtmosphere=true routes to legAppliesAtmosphere==true(1,4) and both atmosphereDelay:* rows; false routes to neither\n');

cfg = i_baseCfg_();
cfg.measurements.groundRelayTimeTransfer.atmosphere.applyTropo = true;
cfg.measurements.groundRelayTimeTransfer.atmosphere.perLegResidualVariance_s2 = [1e-20, 1e-20];
[stationATruth,stationBTruth,relayAssetTruth] = i_truthEndpoints_();
envModel = models.errors.EnvironmentModel(masterConfig(),2);
observable = revgnss.GroundRelayTimeTransferSessionBuilder.buildSession( ...
    cfg,stationATruth,stationBTruth,relayAssetTruth,envModel);
assert(isa(observable,'revgnss.GroundRelaySessionClockDifferenceObservable'));
fprintf('  PASS atmosphere-enabled session builds successfully end to end (applyTropo=true)\n');

cfgOff = i_baseCfg_();
observableOff = revgnss.GroundRelayTimeTransferSessionBuilder.buildSession( ...
    cfgOff,stationATruth,stationBTruth,relayAssetTruth,[]);
assert(observableOff.atmosphereDelayForward_s==0 && observableOff.atmosphereDelayReturn_s==0, ...
    'FAIL: with all delays/sigmas at zero default, the atmosphere subsystem must be fully inert.');
fprintf('  PASS default (atmosphere disabled) subsystem is fully inert\n');
end

% ================================================================================================
function cfg = i_baseCfg_()
cfg = masterConfig();
cfg.measurements.groundRelayTimeTransfer.enable = true;
cfg.measurements.groundRelayTimeTransfer.session.stationATowerIndex = 1;
cfg.measurements.groundRelayTimeTransfer.session.stationBTowerIndex = 2;
cfg.measurements.groundRelayTimeTransfer.session.relaySpaceAssetIndex = 1;
cfg.measurements.groundRelayTimeTransfer.schedule.forwardReceptionEpoch_s = 10;
cfg.measurements.groundRelayTimeTransfer.schedule.returnReceptionEpoch_s = 20;
end

% ================================================================================================
function [stationATruth,stationBTruth,relayAssetTruth] = i_truthEndpoints_()
stationATruth = struct('r_ecef_m',[6378137;0;0],'clockBiasMeters',0,'clockDriftMetersPerSecond',0, ...
    'identifier','station:A');
stationBTruth = struct('r_ecef_m',[0;6378137;0],'clockBiasMeters',0,'clockDriftMetersPerSecond',0, ...
    'identifier','station:B');
relayAssetTruth = struct('r_ecef_m',[42164000;0;0],'v_ecef_mps',[0;3074;0], ...
    'attitude_euler_rad',[0;0;0],'clock',struct('getBiasMeters',@() 0,'getDriftMetersPerSecond',@() 0));
end
