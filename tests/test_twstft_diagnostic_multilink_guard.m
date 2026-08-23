function test_twstft_diagnostic_multilink_guard()
% test_twstft_diagnostic_multilink_guard  Plan Section 4.1 item 3: revgnss.TWSTFTDiagnosticBuilder
% must never report a "clock offset" number built from more than one ISL link's own events --
% twoWayInfo.linkEvents can legitimately carry events from several concurrently-active ISL links
% concatenated together (revgnss.TwoWayISLMeasurementBuilder.aggregateInfo_ concatenates every
% active link's events into one flat array with no re-partitioning), and this diagnostic models
% exactly one conceptual reference/remote pair. Two real, reachable failure modes: (1) a future
% producer that ever emitted an unpaired leg could let the old linear scan pick a forwardLeg from
% one link and a returnLeg from another; (2) even with today's producer, which always emits
% matched [forwardLeg,returnLeg] pairs per link, the old scan silently kept only the LAST link's
% own pair while still labelling it with cfg's referenceAssetIndex/remoteAssetIndex -- a real
% mislabeling bug this guard also closes. Uses real revgnss.ISLLinkEventDescriptor.create records
% (the actual production event schema, carrying real linkId/transmitterAssetIndex/
% receiverAssetIndex fields), not the plain synthetic structs
% tests/test_stage24_twstft_diagnostics.m's own fixture uses.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
addpath(rootDir);
addpath(fullfile(rootDir,'config'));
addpath(fullfile(rootDir,'config','internal'));

fprintf('=== test_twstft_diagnostic_multilink_guard ===\n');
i_test_two_different_links_refused_();
i_test_same_link_still_produces_a_diagnostic_();
i_test_missing_linkid_field_backward_compatible_();
i_test_single_link_wrong_asset_pair_refused_();
fprintf('=== test_twstft_diagnostic_multilink_guard: ALL PASS ===\n');
end

% ================================================================================================
function i_test_two_different_links_refused_()
cfg = i_baseTwstftCfg_();
twoWayInfo.linkEvents = [ ...
    i_realEvent_('isl:1<->2','forwardLeg',1.20,0.25), ...
    i_realEvent_('isl:1<->3','returnLeg',0.90,0.15)]; % DIFFERENT linkId -- must be refused
diag = revgnss.TWSTFTDiagnosticBuilder.build(cfg,struct(),twoWayInfo);
assert(diag.enabled,'the diagnostic must still be "enabled" (config-enabled), just refuse to combine');
assert(strcmp(diag.diagnosticClassification,'unavailableAmbiguousMultiLink'), ...
    'two events from different link identifiers must be refused with the frozen classification, got %s', ...
    diag.diagnosticClassification);
assert(isnan(diag.clockOffsetDiagnostic_s), ...
    'a refused (ambiguous multi-link) diagnostic must never report a clock-offset number');
assert(~isempty(diag.diagnosticNote) && ~isempty(strfind(diag.diagnosticNote,'isl:1<->2')) && ...
    ~isempty(strfind(diag.diagnosticNote,'isl:1<->3')), ...
    'the diagnostic note must name both offending link identifiers');
fprintf('  PASS two different link identifiers refused, no clock-offset number fabricated\n');
end

% ================================================================================================
function i_test_same_link_still_produces_a_diagnostic_()
% Negative control: the SAME linkId on both legs must still produce a real diagnostic -- proves
% the guard discriminates on link identity, not on carrying a linkId field at all.
cfg = i_baseTwstftCfg_();
twoWayInfo.linkEvents = [ ...
    i_realEvent_('isl:1<->2','forwardLeg',1.20,0.25), ...
    i_realEvent_('isl:1<->2','returnLeg',0.90,0.15)];
diag = revgnss.TWSTFTDiagnosticBuilder.build(cfg,struct(),twoWayInfo);
assert(strcmp(diag.diagnosticClassification,'diagnosticOnlyApproximation'), ...
    'matching link identifiers on both legs must still produce a real diagnostic, got %s', ...
    diag.diagnosticClassification);
assert(isfinite(diag.clockOffsetDiagnostic_s),'a same-link diagnostic must report a real finite clock offset');
fprintf('  PASS matching link identifiers on both legs still produce a real diagnostic\n');
end

% ================================================================================================
function i_test_missing_linkid_field_backward_compatible_()
% tests/test_stage24_twstft_diagnostics.m's own fixture builds plain structs with NO linkId
% field at all (eventRole/receiverClockBiasAtReceive_m/transmitterClockBiasAtTransmit_m only).
% The guard must not break that existing, still-valid usage.
cfg = i_baseTwstftCfg_();
twoWayInfo.linkEvents = [ ...
    struct('eventRole','forwardLeg','receiverClockBiasAtReceive_m',1.20,'transmitterClockBiasAtTransmit_m',0.25), ...
    struct('eventRole','returnLeg','receiverClockBiasAtReceive_m',0.90,'transmitterClockBiasAtTransmit_m',0.15)];
diag = revgnss.TWSTFTDiagnosticBuilder.build(cfg,struct(),twoWayInfo);
assert(strcmp(diag.diagnosticClassification,'diagnosticOnlyApproximation'), ...
    'events with no linkId field at all must be unaffected by the guard (backward compatible), got %s', ...
    diag.diagnosticClassification);
fprintf('  PASS events with no linkId field are unaffected by the guard (backward compatible)\n');
end

% ================================================================================================
function i_test_single_link_wrong_asset_pair_refused_()
% Review finding N3: a single, unambiguous link identifier is not enough -- if that ONE surviving
% link's own asset indices don't match cfg's configured referenceAssetIndex/remoteAssetIndex pair
% (e.g. exactly one ISL link 3<->4 active while cfg declares ref=1/rem=2), the old code would
% still report a real-looking number mislabeled under the wrong asset pair.
cfg = i_baseTwstftCfg_(); % ref=1, rem=2
twoWayInfo.linkEvents = [ ...
    i_realEventWithAssets_('isl:3<->4','forwardLeg',1.20,0.25,3,4), ...
    i_realEventWithAssets_('isl:3<->4','returnLeg',0.90,0.15,4,3)];
diag = revgnss.TWSTFTDiagnosticBuilder.build(cfg,struct(),twoWayInfo);
assert(strcmp(diag.diagnosticClassification,'unavailableLinkIdentityMismatch'), ...
    'a single link whose own asset indices do not match the configured ref/rem pair must be refused, got %s', ...
    diag.diagnosticClassification);
assert(isnan(diag.clockOffsetDiagnostic_s), ...
    'a refused (link-identity-mismatch) diagnostic must never report a clock-offset number');
assert(~isempty(strfind(diag.diagnosticNote,'referenceAssetIndex=1')) && ...
    ~isempty(strfind(diag.diagnosticNote,'remoteAssetIndex=2')), ...
    'the diagnostic note must name the configured (mismatched) reference/remote pair');
fprintf('  PASS single link with the wrong asset pair refused, no mislabeled clock-offset number\n');
end

% ================================================================================================
function ev = i_realEvent_(linkId, role, rxClock_m, txClock_m)
ev = i_realEventWithAssets_(linkId,role,rxClock_m,txClock_m,1,2);
end

function ev = i_realEventWithAssets_(linkId, role, rxClock_m, txClock_m, txIndex, rxIndex)
ev = revgnss.ISLLinkEventDescriptor.create('linkId',linkId,'linkType','twoWayISL', ...
    'eventRole',role,'txIndex',txIndex,'txName','A','rxIndex',rxIndex,'rxName','B', ...
    'receiveTime_s',1,'transmitTime_s',0,'lightTime_s',1,'range_m',3e8, ...
    'rxClockBias_m',rxClock_m,'txClockBias_m',txClock_m);
end

function cfg = i_baseTwstftCfg_()
cfg = masterConfig();
cfg.scenario.nSpaceAssets = 2;
cfg.scenario.nReceivers = 1;
cfg.signals.names = {'L1','L2'};
cfg.signals.enabledMask = [true,true];
cfg.measurements.carrierMode = 'off';
cfg.measurements.carrierPhase.enable = false;
cfg.measurements.carrier.enabledByFrequency = [false,false];
cfg.estimator.estimateAttitude = false;
cfg.measurements.isl.timing.enable = true;
cfg.measurements.twstft.enable = true;
cfg.measurements.twstft.code.enable = true;
cfg.measurements.twstft.code.useInEKF = false;
cfg.measurements.twstft.requireIslTiming = true;
cfg.measurements.twstft.referenceAssetIndex = 1;
cfg.measurements.twstft.remoteAssetIndex = 2;
revgnss.TWSTFTDiagnosticBuilder.validateConfig(cfg);
end
