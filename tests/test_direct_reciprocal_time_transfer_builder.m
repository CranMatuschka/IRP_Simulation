function test_direct_reciprocal_time_transfer_builder()
% test_direct_reciprocal_time_transfer_builder  Plan Section 4.2 interface #5.
% revgnss.DirectReciprocalTimeTransferBuilder.buildFromIsl and .buildFromGroundToSpace must both
% funnel through the SAME private assembleDirect_ (proved here by cross-checking the ISL path's
% output events against the ground-to-space path's events for an equivalent geometry, and by
% checking every topology-dependent field the two paths are supposed to differ on:
% legAppliesAtmosphere and the chain endpoint identifiers), and must correctly wire the ID
% provenance fields (calibrationProductIdentifiers) from the objects actually supplied, not from
% an arbitrary merged list. Also covers the Stage 4.2 combined-review fixes: commonSourceGroups is
% always refused (units mismatch, deferred to Section 4.5), atmosphere applicability and
% atmosphereVariance_s2 must agree in both directions, calibration validity is enforced at the
% final-reception tag, required options give this class's own errors, and carrierFrequency_Hz
% accepts either a scalar or a 1-by-4 vector.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
addpath(rootDir);

fprintf('=== test_direct_reciprocal_time_transfer_builder ===\n');
i_test_buildFromIsl_basic_and_atmosphere_off_();
i_test_buildFromGroundToSpace_atmosphere_on_();
i_test_isl_and_ground_to_space_share_the_same_private_assembly_(); %#ok<*NASGU>
i_test_calibration_ids_wired_from_supplied_objects_();
i_test_common_source_groups_always_rejected_();
i_test_unit_mixing_calibration_state_rejected_();
i_test_self_link_rejected_();
i_test_atmosphere_consistency_enforced_both_directions_();
i_test_calibration_validity_window_enforced_end_to_end_();
i_test_required_options_give_class_owned_errors_();
i_test_carrier_frequency_accepts_scalar_or_1x4_vector_();
fprintf('=== test_direct_reciprocal_time_transfer_builder: ALL PASS ===\n');
end

% ================================================================================================
function geom = i_geometry_()
geom = struct('transmitOffset_body_m',zeros(3,1),'receiveOffset_body_m',zeros(3,1), ...
    'transmitTerminalIdentifier','terminal:tx','receiveTerminalIdentifier','terminal:rx', ...
    'transmitAntennaIdentifier','antenna:tx','receiveAntennaIdentifier','antenna:rx');
end

function asset = i_asset_(r_ecef_m,v_ecef_mps,biasM,driftMps)
clock = struct('getBiasMeters',@() biasM,'getDriftMetersPerSecond',@() driftMps,'getOscillatorDriftMetersPerSecond',@() driftMps);
asset = struct('r_ecef_m',r_ecef_m,'v_ecef_mps',v_ecef_mps,'attitude_euler_rad',[0;0;0],'clock',clock);
end

function hw = i_hardware_()
hw = revgnss.ReciprocalLinkHardwareModel('parameterSource','physicalTruth', ...
    'physicalChainIdentifier','chain:AB','calibrationProductIdentifier','prod:AB', ...
    'turnaroundProperTime_s',1e-3,'calibrationCovariance_s2',[1e-19 0;0 1e-19]);
end

function baseArgs = i_baseNameValueArgs_()
baseArgs = {'exchangeIdentifier','exch:x','sessionIdentifier','sess:x', ...
    'protocolIdentifier','proto:x','signalIdentifier','sig:x','channelIdentifier','chan:x', ...
    'carrierFrequency_Hz',10e9};
end

% ================================================================================================
function i_test_buildFromIsl_basic_and_atmosphere_off_()
geom = i_geometry_();
assetA = i_asset_([7000e3;0;0],[0;0;0],3.0,1e-4);
assetB = i_asset_([7000e3;500e3;0],[0;0;0],-2.0,2e-4);
rec = revgnss.DirectReciprocalTimeTransferBuilder.buildFromIsl( ...
    assetA,1,geom, assetB,2,geom, i_hardware_(), 10, ...
    exchangeIdentifier='exch:1',sessionIdentifier='sess:1', ...
    protocolIdentifier='proto:isl',signalIdentifier='sig:isl',channelIdentifier='chan:1', ...
    carrierFrequency_Hz=26e9, ...
    counterTagSigma_s=[1e-9,1e-9],counterTagLabels={'t1CounterNoise','t4CounterNoise'});
assert(strcmp(rec.topologyKind,'directRoundTrip'));
assert(isequal(rec.chainEndpointIdentifiers,{'asset:1','asset:2','asset:2','asset:1'}));
assert(all(~rec.legAppliesAtmosphere),'FAIL: ISL must never apply atmosphere');
assert(all(rec.chainCarrierFrequency_Hz==26e9));
assert(all(rec.localClockTagAvailable));
assert(size(rec.covarianceBlock,1)==4,'FAIL: expected counterTag(2)+terminalModem(2)=4 rows');
assert(isequal(rec.calibrationProductIdentifiers,{'prod:AB'}), ...
    'FAIL: calibrationProductIdentifiers must carry the hardware''s own product id');
assert(isempty(rec.covarianceGroupIdentifiers), ...
    'FAIL: no session common-mode group is wired this stage, so covarianceGroupIdentifiers must be empty');
assert(strcmp(rec.covarianceUnits,'s^2'));
fprintf('  PASS buildFromIsl: basic construction, atmosphere off\n');
end

% ================================================================================================
function i_test_buildFromGroundToSpace_atmosphere_on_()
geom = i_geometry_();
assetB = i_asset_([7000e3;500e3;0],[0;0;0],-2.0,2e-4);
rec = revgnss.DirectReciprocalTimeTransferBuilder.buildFromGroundToSpace( ...
    [6378e3;0;0], 5.0, 0.0, 'tower:1', geom, assetB, 2, geom, i_hardware_(), 10, ...
    exchangeIdentifier='exch:2',sessionIdentifier='sess:2', ...
    protocolIdentifier='proto:g2s',signalIdentifier='sig:g2s',channelIdentifier='chan:2', ...
    carrierFrequency_Hz=14e9, ...
    counterTagSigma_s=[1e-9,1e-9],counterTagLabels={'t1CounterNoise','t4CounterNoise'}, ...
    atmosphereVariance_s2=[1e-20,1e-20,1e-20,1e-20]);
assert(isequal(rec.chainEndpointIdentifiers,{'tower:1','asset:2','asset:2','tower:1'}));
assert(all(rec.legAppliesAtmosphere),'FAIL: ground-to-space must apply atmosphere on every event by default');
assert(size(rec.covarianceBlock,1)==8,'FAIL: expected counterTag(2)+terminalModem(2)+atm(4)=8 rows');
fprintf('  PASS buildFromGroundToSpace: basic construction, atmosphere on (default applyAtmosphere=true)\n');
end

% ================================================================================================
function i_test_isl_and_ground_to_space_share_the_same_private_assembly_()
% Give the ground tower the SAME position/velocity/clock as an equivalent spacecraft asset in the
% ISL path (a physically odd but numerically valid probe): the two paths must then produce
% IDENTICAL coordinateTimeEvents_s and localClockTags_s, proving both call through one shared
% assembleDirect_ rather than two independently-drifted implementations. applyAtmosphere=false is
% passed explicitly on the ground-to-space side so this is an apples-to-apples comparison of the
% shared physics/tagging path, not a probe of the (deliberately topology-dependent) atmosphere
% wiring covered separately below.
geom = i_geometry_();
assetA = i_asset_([7000e3;0;0],[0;0;0],3.0,0);
assetB = i_asset_([7000e3;500e3;0],[0;0;0],-2.0,0);
hw = i_hardware_();

recIsl = revgnss.DirectReciprocalTimeTransferBuilder.buildFromIsl( ...
    assetA,1,geom, assetB,2,geom, hw, 10, ...
    exchangeIdentifier='exch:3a',sessionIdentifier='sess:3', ...
    protocolIdentifier='proto:x',signalIdentifier='sig:x',channelIdentifier='chan:x', ...
    carrierFrequency_Hz=10e9,counterTagSigma_s=[1e-9,1e-9],counterTagLabels={'a','b'});
recG2S = revgnss.DirectReciprocalTimeTransferBuilder.buildFromGroundToSpace( ...
    assetA.r_ecef_m,3.0,0.0,'tower:equivA',geom, assetB,2,geom, hw, 10, ...
    exchangeIdentifier='exch:3b',sessionIdentifier='sess:3', ...
    protocolIdentifier='proto:x',signalIdentifier='sig:x',channelIdentifier='chan:x', ...
    carrierFrequency_Hz=10e9,counterTagSigma_s=[1e-9,1e-9],counterTagLabels={'a','b'}, ...
    applyAtmosphere=false);

assert(max(abs(recIsl.coordinateTimeEvents_s-recG2S.coordinateTimeEvents_s)) < 1e-9, ...
    'FAIL: buildFromIsl and buildFromGroundToSpace must solve identical events for equivalent endpoints');
assert(max(abs(recIsl.localClockTags_s-recG2S.localClockTags_s)) < 1e-9, ...
    'FAIL: buildFromIsl and buildFromGroundToSpace must tag identical local clock values for equivalent endpoints');
fprintf('  PASS buildFromIsl and buildFromGroundToSpace funnel through the same private assembly\n');
end

% ================================================================================================
function i_test_calibration_ids_wired_from_supplied_objects_()
geom = i_geometry_();
assetA = i_asset_([7000e3;0;0],[0;0;0],0,0);
assetB = i_asset_([7000e3;500e3;0],[0;0;0],0,0);
hw = i_hardware_();

calRec = struct('calibrationStateIdentifier','cal:term1','scopeIdentifier','link:AB', ...
    'stateKind','turnaroundGroupDelayResidual_s','ownershipKind','externalCalibrationProduct', ...
    'ownerAssetIdentifier','','ownerCanonicalIndex',0,'externalProductIdentifier','ext:1', ...
    'temporalCovarianceModel','externalProductCovariance','correlationTime_s',0, ...
    'processNoisePsd_perS',0,'processNoisePsdUnits','s^2/s','priorVariance',1e-20, ...
    'priorVarianceUnits','s^2','validFromLocalTag_s',0,'validUntilLocalTag_s',1e6, ...
    'estimationStatus','notEstimated');
cal = revgnss.DistributedLinkCalibrationState(calRec);

rec = revgnss.DirectReciprocalTimeTransferBuilder.buildFromIsl( ...
    assetA,1,geom, assetB,2,geom, hw, 10, ...
    exchangeIdentifier='exch:4',sessionIdentifier='sess:4', ...
    protocolIdentifier='proto:x',signalIdentifier='sig:x',channelIdentifier='chan:x', ...
    carrierFrequency_Hz=10e9, calibrationStates=cal);

assert(numel(rec.calibrationProductIdentifiers)==2 && ...
    any(strcmp(rec.calibrationProductIdentifiers,'prod:AB')) && ...
    any(strcmp(rec.calibrationProductIdentifiers,'cal:term1')), ...
    'FAIL: calibrationProductIdentifiers must contain both the hardware product id and the supplied calibration state id');
fprintf('  PASS calibrationProductIdentifiers wired from the objects actually supplied\n');
end

% ================================================================================================
function i_test_common_source_groups_always_rejected_()
% Stage 4.2 combined review finding 1: revgnss.CommonSourceCovarianceGroup.
% sharedCovarianceContribution_m2 is always metres^2-domain; this builder's covarianceBlock is
% always seconds^2-domain. A nonempty commonSourceGroups must be refused loudly, not silently
% mislabeled (a real seconds-domain shared-source type is Section 4.5 scope).
geom = i_geometry_();
assetA = i_asset_([7000e3;0;0],[0;0;0],0,0);
assetB = i_asset_([7000e3;500e3;0],[0;0;0],0,0);
csgRec = struct('covarianceGroupIdentifier','grp:shared','commonSourceName','sessionTimingProduct', ...
    'treatment','covarianceGroup','sourceProductIdentifier','prod:osc', ...
    'memberObservationIdentifiers',{{'obs:1','obs:2'}}, ...
    'memberDeliveryIdentifiers',{{'del:1','del:2'}}, ...
    'memberRowCount',2,'sharedCovarianceContribution_m2',[1 0;0 1], ...
    'temporalCovarianceModel','randomWalk','correlationTime_s',0, ...
    'processNoisePsd_m2PerS',1e-6,'validFromEpoch_s',0,'validUntilEpoch_s',1e6, ...
    'externalProductIdentifier','');
csg = revgnss.CommonSourceCovarianceGroup(csgRec);
baseArgs = i_baseNameValueArgs_();
threw = false;
try
    revgnss.DirectReciprocalTimeTransferBuilder.buildFromIsl( ...
        assetA,1,geom, assetB,2,geom, i_hardware_(), 10, baseArgs{:}, ...
        commonSourceGroups=csg);
catch ME
    threw = strcmp(ME.identifier,'DirectReciprocalTimeTransferBuilder:commonSourceGroupUnits');
end
assert(threw,'FAIL: a nonempty commonSourceGroups must always be rejected this stage (m^2-vs-s^2 mismatch)');
fprintf('  PASS commonSourceGroups is always rejected (deferred to Section 4.5)\n');
end

% ================================================================================================
function i_test_unit_mixing_calibration_state_rejected_()
% The s^2 unit guard now lives centrally in
% revgnss.ReciprocalTimeTransferCovarianceBuilder.productCalibrationBlock (Stage 4.2 combined
% review finding 9), so the identifier surfaced here comes from that class, not this one.
geom = i_geometry_();
assetA = i_asset_([7000e3;0;0],[0;0;0],0,0);
assetB = i_asset_([7000e3;500e3;0],[0;0;0],0,0);
badRec = struct('calibrationStateIdentifier','cal:bad','scopeIdentifier','link:AB', ...
    'stateKind','linkRangeBiasResidual_m','ownershipKind','externalCalibrationProduct', ...
    'ownerAssetIdentifier','','ownerCanonicalIndex',0,'externalProductIdentifier','ext:1', ...
    'temporalCovarianceModel','externalProductCovariance','correlationTime_s',0, ...
    'processNoisePsd_perS',0,'processNoisePsdUnits','m^2/s','priorVariance',1e-4, ...
    'priorVarianceUnits','m^2','validFromLocalTag_s',0,'validUntilLocalTag_s',1e6, ...
    'estimationStatus','notEstimated');
badCal = revgnss.DistributedLinkCalibrationState(badRec);
baseArgs = i_baseNameValueArgs_();
threw = false;
try
    revgnss.DirectReciprocalTimeTransferBuilder.buildFromIsl( ...
        assetA,1,geom, assetB,2,geom, i_hardware_(), 10, baseArgs{:}, ...
        calibrationStates=badCal);
catch ME
    threw = strcmp(ME.identifier,'ReciprocalTimeTransferCovarianceBuilder:productCalibrationUnits');
end
assert(threw,'FAIL: a linkRangeBiasResidual_m (m^2) calibration state must be rejected in a s^2 time-transfer block');
fprintf('  PASS unit-mixing calibration state rejected (centralized guard)\n');
end

% ================================================================================================
function i_test_self_link_rejected_()
geom = i_geometry_();
assetA = i_asset_([7000e3;0;0],[0;0;0],0,0);
baseArgs = i_baseNameValueArgs_();
threw = false;
try
    revgnss.DirectReciprocalTimeTransferBuilder.buildFromIsl( ...
        assetA,1,geom, assetA,1,geom, i_hardware_(), 10, baseArgs{:});
catch ME
    threw = strcmp(ME.identifier,'ReciprocalTimestampEventModel:selfLink');
end
assert(threw,'FAIL: identical origin/destination asset identifiers must be rejected as a self-link');
fprintf('  PASS self-link rejected end-to-end through buildFromIsl\n');
end

% ================================================================================================
function i_test_atmosphere_consistency_enforced_both_directions_()
% Stage 4.2 combined review finding 3, both directions: (a) buildFromIsl (appliesAtmosphere=false
% always) must refuse a supplied atmosphereVariance_s2; (b) buildFromGroundToSpace with
% applyAtmosphere=true (the default) must REQUIRE one.
geom = i_geometry_();
assetA = i_asset_([7000e3;0;0],[0;0;0],0,0);
assetB = i_asset_([7000e3;500e3;0],[0;0;0],0,0);
baseArgs = i_baseNameValueArgs_();

threw = false;
try
    revgnss.DirectReciprocalTimeTransferBuilder.buildFromIsl( ...
        assetA,1,geom, assetB,2,geom, i_hardware_(), 10, baseArgs{:}, ...
        atmosphereVariance_s2=[1e-20,1e-20,1e-20,1e-20]);
catch ME
    threw = strcmp(ME.identifier,'DirectReciprocalTimeTransferBuilder:atmosphereVarianceNotApplicable');
end
assert(threw,'FAIL: buildFromIsl must refuse an atmosphereVariance_s2 (ISL never applies atmosphere)');

threw = false;
try
    revgnss.DirectReciprocalTimeTransferBuilder.buildFromGroundToSpace( ...
        [6378e3;0;0], 5.0, 0.0, 'tower:1', geom, assetB, 2, geom, i_hardware_(), 10, ...
        baseArgs{:}); % applyAtmosphere defaults true, no atmosphereVariance_s2 supplied
catch ME
    threw = strcmp(ME.identifier,'DirectReciprocalTimeTransferBuilder:atmosphereVarianceRequired');
end
assert(threw,'FAIL: buildFromGroundToSpace with applyAtmosphere=true must require atmosphereVariance_s2');

% Negative control: applyAtmosphere=false + no atmosphereVariance_s2 must succeed cleanly.
recOff = revgnss.DirectReciprocalTimeTransferBuilder.buildFromGroundToSpace( ...
    [6378e3;0;0], 5.0, 0.0, 'tower:1', geom, assetB, 2, geom, i_hardware_(), 10, ...
    baseArgs{:}, applyAtmosphere=false);
assert(all(~recOff.legAppliesAtmosphere));
fprintf('  PASS atmosphere applicability and atmosphereVariance_s2 are enforced consistently both ways\n');
end

% ================================================================================================
function i_test_calibration_validity_window_enforced_end_to_end_()
% Stage 4.2 combined review finding 2: a stale/expired calibration product must not silently
% construct a "valid" exchange record -- neither for the hardware's own validity window nor for a
% supplied DistributedLinkCalibrationState's.
geom = i_geometry_();
assetA = i_asset_([7000e3;0;0],[0;0;0],0,0);
assetB = i_asset_([7000e3;500e3;0],[0;0;0],0,0);
baseArgs = i_baseNameValueArgs_();

staleHw = revgnss.ReciprocalLinkHardwareModel('parameterSource','physicalTruth', ...
    'physicalChainIdentifier','chain:AB','calibrationProductIdentifier','prod:AB', ...
    'turnaroundProperTime_s',1e-3,'validFromLocalTag_s',1e6,'validUntilLocalTag_s',2e6);
threw = false;
try
    revgnss.DirectReciprocalTimeTransferBuilder.buildFromIsl( ...
        assetA,1,geom, assetB,2,geom, staleHw, 10, baseArgs{:});
catch ME
    threw = strcmp(ME.identifier,'ReciprocalLinkHardwareModel:outsideValidity');
end
assert(threw,'FAIL: a hardware product outside its own validity window must be rejected end to end');

staleCalRec = struct('calibrationStateIdentifier','cal:stale','scopeIdentifier','link:AB', ...
    'stateKind','turnaroundGroupDelayResidual_s','ownershipKind','externalCalibrationProduct', ...
    'ownerAssetIdentifier','','ownerCanonicalIndex',0,'externalProductIdentifier','ext:1', ...
    'temporalCovarianceModel','externalProductCovariance','correlationTime_s',0, ...
    'processNoisePsd_perS',0,'processNoisePsdUnits','s^2/s','priorVariance',1e-20, ...
    'priorVarianceUnits','s^2','validFromLocalTag_s',1e6,'validUntilLocalTag_s',2e6, ...
    'estimationStatus','notEstimated');
staleCal = revgnss.DistributedLinkCalibrationState(staleCalRec);
threw = false;
try
    revgnss.DirectReciprocalTimeTransferBuilder.buildFromIsl( ...
        assetA,1,geom, assetB,2,geom, i_hardware_(), 10, baseArgs{:}, ...
        calibrationStates=staleCal);
catch ME
    threw = strcmp(ME.identifier,'DirectReciprocalTimeTransferBuilder:calibrationStateValidity');
end
assert(threw,'FAIL: a supplied calibration state outside its own validity window must be rejected end to end');
fprintf('  PASS calibration validity window enforced end to end (hardware and calibration states)\n');
end

% ================================================================================================
function i_test_required_options_give_class_owned_errors_()
geom = i_geometry_();
assetA = i_asset_([7000e3;0;0],[0;0;0],0,0);
assetB = i_asset_([7000e3;500e3;0],[0;0;0],0,0);
threw = false;
try
    revgnss.DirectReciprocalTimeTransferBuilder.buildFromIsl( ...
        assetA,1,geom, assetB,2,geom, i_hardware_(), 10, ...
        exchangeIdentifier='exch:x'); % sessionIdentifier, protocol/signal/channel, freq all omitted
catch ME
    threw = strcmp(ME.identifier,'DirectReciprocalTimeTransferBuilder:missingRequiredOption');
end
assert(threw,'FAIL: an omitted required option must give this class''s own error, not a MATLAB one');
fprintf('  PASS omitted required options give this class''s own ClassName:reason error\n');
end

% ================================================================================================
function i_test_carrier_frequency_accepts_scalar_or_1x4_vector_()
% Stage 4.2 combined review finding 13: the record's chainCarrierFrequency_Hz schema is per-event
% (1-by-4) specifically to support a future frequency-translating relay/transponder; this builder
% must not collapse that capability to an always-scalar broadcast.
geom = i_geometry_();
assetA = i_asset_([7000e3;0;0],[0;0;0],0,0);
assetB = i_asset_([7000e3;500e3;0],[0;0;0],0,0);
baseArgs = i_baseNameValueArgs_();
recScalar = revgnss.DirectReciprocalTimeTransferBuilder.buildFromIsl( ...
    assetA,1,geom, assetB,2,geom, i_hardware_(), 10, baseArgs{:});
assert(isequal(recScalar.chainCarrierFrequency_Hz,repmat(10e9,1,4)));

recVector = revgnss.DirectReciprocalTimeTransferBuilder.buildFromIsl( ...
    assetA,1,geom, assetB,2,geom, i_hardware_(), 10, ...
    exchangeIdentifier='exch:x',sessionIdentifier='sess:x',protocolIdentifier='proto:x', ...
    signalIdentifier='sig:x',channelIdentifier='chan:x', ...
    carrierFrequency_Hz=[10e9,10e9,20e9,20e9]);
assert(isequal(recVector.chainCarrierFrequency_Hz,[10e9,10e9,20e9,20e9]), ...
    'FAIL: a 1-by-4 carrierFrequency_Hz must pass through unchanged (frequency-translation capability)');
fprintf('  PASS carrierFrequency_Hz accepts both a scalar (broadcast) and a 1x4 vector\n');
end
