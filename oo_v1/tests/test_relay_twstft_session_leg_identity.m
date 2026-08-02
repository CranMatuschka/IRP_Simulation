function test_relay_twstft_session_leg_identity()
% test_relay_twstft_session_leg_identity  Plan Section 4.5. Verifies revgnss.
% GroundRelayOneWayPassRecordBuilder/revgnss.GroundRelaySessionObservableBuilder produce two
% genuinely independent, correctly-shaped one-way relay passes -- "session leg identity" -- before
% any physics correctness is asserted (test_relay_twstft_clock_gauge.m). Also covers combined
% review B2 (buildSession must refuse when disabled) and T1 (negative-path coverage for
% requireSessionLegIdentity_'s guard branches and the observable constructor's own validation).

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
addpath(rootDir);
addpath(fullfile(rootDir,'config'));
addpath(fullfile(rootDir,'config','internal'));

fprintf('=== test_relay_twstft_session_leg_identity ===\n');
i_test_chain_shape_and_role_order_();
i_test_compare_endpoints_never_include_relay_();
i_test_exchange_identifiers_distinct_();
i_test_independent_solveRelayTransit_calls_cross_validated_();
i_test_self_link_guard_reachable_();
i_test_time_ordering_();
i_test_golden_safety_incomplete_config_();
i_test_buildSession_refuses_when_disabled_();
i_test_requireSessionLegIdentity_rejects_topologyKind_();
i_test_requireSessionLegIdentity_rejects_chainShape_mismatched_relay_();
i_test_requireSessionLegIdentity_rejects_chainShape_unswapped_direction_();
i_test_requireSessionLegIdentity_rejects_duplicate_exchangeIdentifier_();
i_test_observable_constructor_rejects_malformed_input_();
fprintf('=== test_relay_twstft_session_leg_identity: ALL PASS ===\n');
end

% ================================================================================================
function i_test_chain_shape_and_role_order_()
[~, stationA, stationB, relay, hwForward, hwReturn] = i_fixture_();
optsF = i_baseOptions_('fwd:1'); optsR = i_baseOptions_('ret:1');
recordForward = revgnss.GroundRelayOneWayPassRecordBuilder.buildOneWayPass( ...
    stationA, relay, stationB, hwForward, 10, [], optsF{:});
recordReturn = revgnss.GroundRelayOneWayPassRecordBuilder.buildOneWayPass( ...
    stationB, relay, stationA, hwReturn, 20, [], optsR{:});
assert(strcmp(recordForward.topologyKind,'relayTransit'));
assert(strcmp(recordReturn.topologyKind,'relayTransit'));
assert(isequal(recordForward.chainEndpointIdentifiers,{'station:A','asset:1','asset:1','station:B'}));
assert(isequal(recordReturn.chainEndpointIdentifiers,{'station:B','asset:1','asset:1','station:A'}));
fprintf('  PASS chain-endpoint shape/role order on both records\n');
end

% ================================================================================================
function i_test_compare_endpoints_never_include_relay_()
[~, stationA, stationB, relay, hwForward, hwReturn] = i_fixture_();
optsF = i_baseOptions_('fwd:1'); optsR = i_baseOptions_('ret:1');
recordForward = revgnss.GroundRelayOneWayPassRecordBuilder.buildOneWayPass( ...
    stationA, relay, stationB, hwForward, 10, [], optsF{:});
recordReturn = revgnss.GroundRelayOneWayPassRecordBuilder.buildOneWayPass( ...
    stationB, relay, stationA, hwReturn, 20, [], optsR{:});
assert(isempty(setdiff(recordForward.localClockCompareEndpointIdentifiers,{'station:A','station:B'})));
assert(isempty(setdiff(recordReturn.localClockCompareEndpointIdentifiers,{'station:A','station:B'})));
assert(~any(strcmp('asset:1',recordForward.localClockCompareEndpointIdentifiers)));
assert(~any(strcmp('asset:1',recordReturn.localClockCompareEndpointIdentifiers)));
fprintf('  PASS localClockCompareEndpointIdentifiers is exactly {stationA,stationB} on both, never the relay\n');
end

% ================================================================================================
function i_test_exchange_identifiers_distinct_()
[~, stationA, stationB, relay, hwForward, hwReturn] = i_fixture_();
optsF = i_baseOptions_('fwd:1'); optsR = i_baseOptions_('ret:1');
recordForward = revgnss.GroundRelayOneWayPassRecordBuilder.buildOneWayPass( ...
    stationA, relay, stationB, hwForward, 10, [], optsF{:});
recordReturn = revgnss.GroundRelayOneWayPassRecordBuilder.buildOneWayPass( ...
    stationB, relay, stationA, hwReturn, 20, [], optsR{:});
assert(~strcmp(recordForward.exchangeIdentifier,recordReturn.exchangeIdentifier));
observable = revgnss.GroundRelaySessionObservableBuilder.combine( ...
    recordForward, recordReturn, i_hardware_(), i_hardwareCalibration_(), 0, 0, zeros(0,0), {}, ...
    sessionIdentifier='sess:1');
assert(isa(observable,'revgnss.GroundRelaySessionClockDifferenceObservable'));
fprintf('  PASS two genuinely distinct exchangeIdentifiers; combine() accepts them\n');
end

% ================================================================================================
function i_test_independent_solveRelayTransit_calls_cross_validated_()
% Independent-oracle discipline (Sections 4.2/4.3): re-derive the forward pass's own solved
% events via a direct, test-local call to solveRelayTransit -- not reusing the builder's own
% internal call -- and require exact agreement.
[~, stationA, stationB, relay, hwForward, hwReturn] = i_fixture_();
optsF = i_baseOptions_('fwd:1'); optsR = i_baseOptions_('ret:1');
recordForward = revgnss.GroundRelayOneWayPassRecordBuilder.buildOneWayPass( ...
    stationA, relay, stationB, hwForward, 10, [], optsF{:});
events = revgnss.ReciprocalTimestampEventModel.solveRelayTransit( ...
    stationA, relay, stationB, hwForward, 10, struct());
oracle = [events.t1_s, events.t2_s, events.t3_s, events.t4_s];
assert(norm(oracle - recordForward.coordinateTimeEvents_s) < 1e-12, ...
    'FAIL: buildOneWayPass must reproduce an independent direct solveRelayTransit call exactly.');
% Under nonzero relay velocity (this fixture's relay moves at 3074 m/s), the two directions'
% propagation delays genuinely differ -- proving solveRelayTransit was invoked with swapped roles,
% not the same cached result reused twice.
recordReturn = revgnss.GroundRelayOneWayPassRecordBuilder.buildOneWayPass( ...
    stationB, relay, stationA, hwReturn, 20, [], optsR{:});
tauF_s = recordForward.coordinateTimeEvents_s(4) - recordForward.coordinateTimeEvents_s(1);
tauR_s = recordReturn.coordinateTimeEvents_s(4) - recordReturn.coordinateTimeEvents_s(1);
assert(abs(tauF_s - tauR_s) > 1e-9, ...
    'FAIL: forward/return total transit time must differ measurably under nonzero relay velocity.');
fprintf('  PASS independent solveRelayTransit cross-validation exact; |tauF-tauR|=%.3e s under relay motion\n', ...
    abs(tauF_s-tauR_s));
end

% ================================================================================================
function i_test_self_link_guard_reachable_()
[~, stationA, ~, ~, hwForward, ~] = i_fixture_();
relaySameId = stationA; % identical identifier to stationA -- must trip the 3-way distinctness guard
optsF = i_baseOptions_('fwd:1');
threw = false;
try
    revgnss.GroundRelayOneWayPassRecordBuilder.buildOneWayPass( ...
        stationA, relaySameId, stationA, hwForward, 10, [], optsF{:});
catch ME
    threw = strcmp(ME.identifier,'ReciprocalTimestampEventModel:selfLink');
end
assert(threw,'FAIL: a relay sharing an identifier with a station must trip the unmodified Section 4.2 self-link guard.');
fprintf('  PASS Section 4.2 self-link guard reachable, unmodified, through the new builder\n');
end

% ================================================================================================
function i_test_time_ordering_()
[~, stationA, stationB, relay, hwForward, hwReturn] = i_fixture_();
optsF = i_baseOptions_('fwd:1'); optsR = i_baseOptions_('ret:1');
recordForward = revgnss.GroundRelayOneWayPassRecordBuilder.buildOneWayPass( ...
    stationA, relay, stationB, hwForward, 10, [], optsF{:});
recordReturn = revgnss.GroundRelayOneWayPassRecordBuilder.buildOneWayPass( ...
    stationB, relay, stationA, hwReturn, 20, [], optsR{:});
assert(all(diff(recordForward.coordinateTimeEvents_s) >= 0));
assert(all(diff(recordReturn.coordinateTimeEvents_s) >= 0));
fprintf('  PASS coordinateTimeEvents_s is time-ordered t1<=t2<=t3<=t4 on both records\n');
end

% ================================================================================================
function i_test_golden_safety_incomplete_config_()
cfg = masterConfig();
assert(~cfg.measurements.groundRelayTimeTransfer.enable, ...
    'FAIL: groundRelayTimeTransfer.enable must default to false.');
revgnss.GroundRelayPhysicalLinkConfig.requireCompleteSessionConfig(cfg); % no-op while disabled
cfg.measurements.groundRelayTimeTransfer.enable = true; % now incomplete (no session indices)
threw = false;
try
    revgnss.GroundRelayPhysicalLinkConfig.requireCompleteSessionConfig(cfg);
catch
    threw = true;
end
assert(threw,'FAIL: enable=true with an incomplete session configuration must be hard-refused.');
fprintf('  PASS enable=false is a no-op; enable=true with an incomplete config is hard-refused\n');
end

% ================================================================================================
function i_test_buildSession_refuses_when_disabled_()
% Combined review B2: an un-reviewed first cut relied only on requireCompleteSessionConfig (a
% documented no-op while disabled), so buildSession itself never checked isEnabled -- a disabled
% config with the rest of the subtree fully populated silently built a real observable AND
% silently skipped every hard refusal (useInEKF=true, relayFrequencyTranslationRatio~=1) that
% would otherwise fire. buildSession must refuse before doing anything else.
cfg = i_baseCfg_();
cfg.measurements.groundRelayTimeTransfer.enable = false; % otherwise fully complete/valid
[stationATruth,stationBTruth,relayAssetTruth] = i_truthEndpoints_();
threw = false;
try
    revgnss.GroundRelayTimeTransferSessionBuilder.buildSession( ...
        cfg,stationATruth,stationBTruth,relayAssetTruth,[]);
catch ME
    threw = strcmp(ME.identifier,'GroundRelayTimeTransferSessionBuilder:disabled');
end
assert(threw,'FAIL: buildSession must refuse outright when groundRelayTimeTransfer.enable=false.');

% Also: disabled + useInEKF=true + relayFrequencyTranslationRatio~=1 (both otherwise-hard-refused)
% must STILL be refused for exactly the disabled reason, not silently pass through.
cfg2 = cfg;
cfg2.measurements.groundRelayTimeTransfer.useInEKF = true;
cfg2.measurements.groundRelayTimeTransfer.hardware.relayFrequencyTranslationRatio = 1.5;
threw2 = false;
try
    revgnss.GroundRelayTimeTransferSessionBuilder.buildSession( ...
        cfg2,stationATruth,stationBTruth,relayAssetTruth,[]);
catch ME2
    threw2 = strcmp(ME2.identifier,'GroundRelayTimeTransferSessionBuilder:disabled');
end
assert(threw2,'FAIL: buildSession must refuse for the disabled reason even with other refusal triggers set.');
fprintf('  PASS buildSession refuses immediately when disabled, regardless of the rest of the config\n');
end

% ================================================================================================
function i_test_requireSessionLegIdentity_rejects_topologyKind_()
% A genuine revgnss.ReciprocalTimestampExchangeRecord with topologyKind=='directRoundTrip'
% (built via the unmodified Section 4.2 revgnss.DirectReciprocalTimeTransferBuilder, a completely
% independent code path) must be refused by combine()'s own session-leg-identity guard.
[~, stationA, stationB, relay, hwForward, hwReturn] = i_fixture_();
optsF = i_baseOptions_('fwd:1');
recordForward = revgnss.GroundRelayOneWayPassRecordBuilder.buildOneWayPass( ...
    stationA, relay, stationB, hwForward, 10, [], optsF{:});
directHardware = revgnss.ReciprocalLinkHardwareModel( ...
    'parameterSource','physicalTruth','physicalChainIdentifier','direct-chain-1', ...
    'calibrationProductIdentifier','direct-cal-1','turnaroundProperTime_s',1e-3, ...
    'originTerminalGroupDelay_s',0,'anchorTerminalGroupDelay_s',0);
geom = i_geom_();
directRecord = revgnss.DirectReciprocalTimeTransferBuilder.buildFromGroundToSpace( ...
    [6378137;0;0],0,0,'station:A',geom, ...
    struct('r_ecef_m',[42164000;0;0],'v_ecef_mps',[0;3074;0],'attitude_euler_rad',[0;0;0], ...
        'clock',struct('getBiasMeters',@() 0,'getDriftMetersPerSecond',@() 0)), ...
    1,geom,directHardware,10, ...
    exchangeIdentifier='direct:1',sessionIdentifier='sess:1',protocolIdentifier='p', ...
    signalIdentifier='s',channelIdentifier='c',carrierFrequency_Hz=14e9, ...
    counterTagSigma_s=zeros(1,4),counterTagLabels={'t1','t2','t3','t4'},applyAtmosphere=false);
threw = false;
try
    revgnss.GroundRelaySessionObservableBuilder.combine( ...
        directRecord, recordForward, i_hardware_(), i_hardwareCalibration_(), 0, 0, zeros(0,0), {}, ...
        sessionIdentifier='sess:1');
catch ME
    threw = strcmp(ME.identifier,'GroundRelaySessionObservableBuilder:topologyKind');
end
assert(threw,'FAIL: a directRoundTrip record must be refused by combine().');
fprintf('  PASS combine() refuses a genuine directRoundTrip record (topologyKind guard)\n');
end

% ================================================================================================
function i_test_requireSessionLegIdentity_rejects_chainShape_mismatched_relay_()
% recordForward's relay ('asset:1') and recordReturn's relay ('asset:2') must be the SAME relay.
[~, stationA, stationB, relay, hwForward, hwReturn] = i_fixture_();
optsF = i_baseOptions_('fwd:1'); optsR = i_baseOptions_('ret:1');
recordForward = revgnss.GroundRelayOneWayPassRecordBuilder.buildOneWayPass( ...
    stationA, relay, stationB, hwForward, 10, [], optsF{:});
relayAsset2 = struct('r_ecef_m',[42164000;0;0],'v_ecef_mps',[0;3074;0], ...
    'attitude_euler_rad',[0;0;0],'clock',struct('getBiasMeters',@() 0,'getDriftMetersPerSecond',@() 0));
relay2 = revgnss.ReciprocalEndpointTruthProvider.spacecraft(relayAsset2,2,i_geom_(),20); % 'asset:2'
recordReturn = revgnss.GroundRelayOneWayPassRecordBuilder.buildOneWayPass( ...
    stationB, relay2, stationA, hwReturn, 20, [], optsR{:});
threw = false;
try
    revgnss.GroundRelaySessionObservableBuilder.combine( ...
        recordForward, recordReturn, i_hardware_(), i_hardwareCalibration_(), 0, 0, zeros(0,0), {}, ...
        sessionIdentifier='sess:1');
catch ME
    threw = strcmp(ME.identifier,'GroundRelaySessionObservableBuilder:chainShape');
end
assert(threw,'FAIL: mismatched relay identifiers between forward/return must be refused.');
fprintf('  PASS combine() refuses a forward/return pair using two different relays\n');
end

% ================================================================================================
function i_test_requireSessionLegIdentity_rejects_chainShape_unswapped_direction_()
% recordReturn must be the SWAPPED-ROLE pass (B->S->A); passing another A->S->B pass instead
% (chainR{1}==stationA, not stationB) must be refused.
[~, stationA, stationB, relay, hwForward, ~] = i_fixture_();
optsF = i_baseOptions_('fwd:1'); optsF2 = i_baseOptions_('fwd:2');
recordForward = revgnss.GroundRelayOneWayPassRecordBuilder.buildOneWayPass( ...
    stationA, relay, stationB, hwForward, 10, [], optsF{:});
recordNotSwapped = revgnss.GroundRelayOneWayPassRecordBuilder.buildOneWayPass( ...
    stationA, relay, stationB, hwForward, 20, [], optsF2{:}); % A->S->B again, not B->S->A
threw = false;
try
    revgnss.GroundRelaySessionObservableBuilder.combine( ...
        recordForward, recordNotSwapped, i_hardware_(), i_hardwareCalibration_(), 0, 0, zeros(0,0), {}, ...
        sessionIdentifier='sess:1');
catch ME
    threw = strcmp(ME.identifier,'GroundRelaySessionObservableBuilder:chainShape');
end
assert(threw,'FAIL: an un-swapped second A->S->B pass must be refused as recordReturn.');
fprintf('  PASS combine() refuses an un-swapped-direction pair (chainF{4}~=chainR{1})\n');
end

% ================================================================================================
function i_test_requireSessionLegIdentity_rejects_duplicate_exchangeIdentifier_()
[~, stationA, stationB, relay, hwForward, hwReturn] = i_fixture_();
sameId = i_baseOptions_('shared:1');
recordForward = revgnss.GroundRelayOneWayPassRecordBuilder.buildOneWayPass( ...
    stationA, relay, stationB, hwForward, 10, [], sameId{:});
recordReturn = revgnss.GroundRelayOneWayPassRecordBuilder.buildOneWayPass( ...
    stationB, relay, stationA, hwReturn, 20, [], sameId{:});
threw = false;
try
    revgnss.GroundRelaySessionObservableBuilder.combine( ...
        recordForward, recordReturn, i_hardware_(), i_hardwareCalibration_(), 0, 0, zeros(0,0), {}, ...
        sessionIdentifier='sess:1');
catch ME
    threw = strcmp(ME.identifier,'GroundRelaySessionObservableBuilder:distinctExchanges');
end
assert(threw,'FAIL: identical forward/return exchangeIdentifiers must be refused.');
fprintf('  PASS combine() refuses forward/return records sharing one exchangeIdentifier\n');
end

% ================================================================================================
function i_test_observable_constructor_rejects_malformed_input_()
% revgnss.GroundRelaySessionClockDifferenceObservable's own constructor has ~12 independent
% validation branches. Vary ONE field at a time from a known-good baseline (obtained via a real
% combine() call's own toStruct()) and require each mutation to be refused with the documented
% error identifier -- direct-constructor coverage complementary to combine()'s own guards above.
%
% requireSessionLegIdentity_'s remaining branches (availability=false, incomplete
% localClockTagAvailable, stationPairDistinct, compareEndpoints-includes-relay, out-of-order
% coordinateTimeEvents_s) are NOT independently tested here: revgnss.
% GroundRelayOneWayPassRecordBuilder.buildOneWayPass always produces availability=true,
% localClockTagAvailable=true(1,4), a correct localClockCompareEndpointIdentifiers set, and
% solveRelayTransit's own light-time solve always produces causally-ordered events, so these
% branches are structurally unreachable through the one shipped production call path -- genuine
% defense-in-depth (matching this project's own established discipline for unreachable guards),
% not dead code masking a real gap. stationPairDistinct is additionally already prevented one
% layer up by the unmodified Section 4.2 self-link guard (i_test_self_link_guard_reachable_
% above) whenever stationA==stationB.
[~, stationA, stationB, relay, hwForward, hwReturn] = i_fixture_();
optsF = i_baseOptions_('fwd:1'); optsR = i_baseOptions_('ret:1');
recordForward = revgnss.GroundRelayOneWayPassRecordBuilder.buildOneWayPass( ...
    stationA, relay, stationB, hwForward, 10, [], optsF{:});
recordReturn = revgnss.GroundRelayOneWayPassRecordBuilder.buildOneWayPass( ...
    stationB, relay, stationA, hwReturn, 20, [], optsR{:});
observable = revgnss.GroundRelaySessionObservableBuilder.combine( ...
    recordForward, recordReturn, i_hardware_(), i_hardwareCalibration_(), 0, 0, zeros(0,0), {}, ...
    sessionIdentifier='sess:1');
baseline = observable.toStruct();

cases = { ...
    'missing field',        @() rmfield(baseline,'clockDifferenceValue_s'), 'GroundRelaySessionClockDifferenceObservable:missingField'; ...
    'unknown field',        @() i_setField_(baseline,'bogusField',1), 'GroundRelaySessionClockDifferenceObservable:unknownField'; ...
    'non-distinct endpoints', @() i_setField_(baseline,'relayIdentifier',baseline.stationAIdentifier), 'GroundRelaySessionClockDifferenceObservable:distinctEndpoints'; ...
    'non-distinct exchanges', @() i_setField_(baseline,'sourceReturnExchangeIdentifier',baseline.sourceForwardExchangeIdentifier), 'GroundRelaySessionClockDifferenceObservable:distinctExchanges'; ...
    'non-finite numeric field', @() i_setField_(baseline,'clockDifferenceValue_s',NaN), 'GroundRelaySessionClockDifferenceObservable:numericField'; ...
    'negative independentVariance', @() i_setField_(baseline,'independentVariance_s2',-1), 'GroundRelaySessionClockDifferenceObservable:independentVariance'; ...
    'non-distinct epochs',   @() i_setField_(baseline,'returnReceptionEpoch_s',baseline.forwardReceptionEpoch_s), 'GroundRelaySessionClockDifferenceObservable:distinctEpochs'; ...
    'clockDifference units mismatch', @() i_setField_(baseline,'clockDifferenceValue_m',baseline.clockDifferenceValue_m+1000), 'GroundRelaySessionClockDifferenceObservable:unitsMismatch'; ...
    'classicalReciprocity units mismatch', @() i_setField_(baseline,'classicalReciprocityValue_m',baseline.classicalReciprocityValue_m+1000), 'GroundRelaySessionClockDifferenceObservable:unitsMismatch'; ...
    'non-square covariance', @() i_setField_(baseline,'sessionCommonCovariance_s2',zeros(2,3)), 'GroundRelaySessionClockDifferenceObservable:sessionCommonCovariance'; ...
    'componentOrder length mismatch', @() i_setFields_(baseline,{'sessionCommonCovariance_s2','sessionCommonComponentOrder'},{5,{'a','b'}}), 'GroundRelaySessionClockDifferenceObservable:sessionCommonComponentOrder'; ...
    'non-logical availability', @() i_setField_(baseline,'availability',1), 'GroundRelaySessionClockDifferenceObservable:availability'; ...
    };
for k = 1:size(cases,1)
    bad = cases{k,2}();
    expectedId = cases{k,3};
    threw = false;
    try
        revgnss.GroundRelaySessionClockDifferenceObservable(bad);
    catch ME
        threw = strcmp(ME.identifier,expectedId);
    end
    assert(threw,'FAIL: constructor case "%s" must be refused with identifier %s.',cases{k,1},expectedId);
end
fprintf('  PASS observable constructor rejects all %d malformed-input cases with the documented identifier\n', ...
    size(cases,1));
end

% ================================================================================================
function s = i_setField_(s, name, value)
s.(name) = value;
end

% ================================================================================================
function s = i_setFields_(s, names, values)
for k = 1:numel(names)
    s.(names{k}) = values{k};
end
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

% ================================================================================================
function hardware = i_hardware_()
hardware = revgnss.GroundRelaySessionHardwareModel( ...
    parameterSource='physicalTruth', physicalChainIdentifier='chain-1', ...
    calibrationProductIdentifier='cal-1', relayGroupDelayNominal_s=1e-3);
end

% ================================================================================================
function hardware = i_hardwareCalibration_()
% i_hardwareCalibration_  All-zero-station-delay calibrationProduct-sourced hardware, the
% "nothing known/calibrated" baseline combine() requires as its second argument (combined review
% M4). Paired with i_hardware_() (physicalTruth) this reproduces the exact pre-M4-fix numeric
% behaviour (net delay == hardwareTruth's full nominal value) for tests that are not specifically
% about calibration-vs-truth separation.
hardware = revgnss.GroundRelaySessionHardwareModel( ...
    parameterSource='calibrationProduct', physicalChainIdentifier='chain-1', ...
    calibrationProductIdentifier='cal-1', relayGroupDelayNominal_s=1e-3);
end

% ================================================================================================
function geom = i_geom_()
geom = struct('transmitOffset_body_m',zeros(3,1),'receiveOffset_body_m',zeros(3,1), ...
    'transmitTerminalIdentifier','tx','receiveTerminalIdentifier','rx', ...
    'transmitAntennaIdentifier','txa','receiveAntennaIdentifier','rxa');
end

% ================================================================================================
function [cfg, stationA, stationB, relay, hwForward, hwReturn] = i_fixture_()
cfg = i_baseCfg_();
geom = i_geom_();
stationA = revgnss.ReciprocalEndpointTruthProvider.fixedStation([6378137;0;0],0,0,'station:A',geom,10);
stationB = revgnss.ReciprocalEndpointTruthProvider.fixedStation([0;6378137;0],0,0,'station:B',geom,10);
relayAsset = struct('r_ecef_m',[42164000;0;0],'v_ecef_mps',[0;3074;0], ...
    'attitude_euler_rad',[0;0;0],'clock',struct('getBiasMeters',@() 0,'getDriftMetersPerSecond',@() 0));
relay = revgnss.ReciprocalEndpointTruthProvider.spacecraft(relayAsset,1,geom,10);
hardware = i_hardware_();
hwForward = hardware.asEventSolverHardware('forward');
hwReturn = hardware.asEventSolverHardware('return');
end

% ================================================================================================
function opts = i_baseOptions_(exchangeId)
opts = {'exchangeIdentifier',exchangeId,'sessionIdentifier','sess:1', ...
    'protocolIdentifier','classicalRelayTwstft','signalIdentifier','TWSTFT-RELAY', ...
    'channelIdentifier','relay-1','carrierFrequency_Hz',14e9, ...
    'counterTagSigma_s',zeros(1,4),'counterTagLabels',{'t1','t2','t3','t4'}, ...
    'applyAtmosphere',false};
end
