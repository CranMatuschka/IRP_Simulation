function test_four_timestamp_naming_and_mode_dispatch()
% test_four_timestamp_naming_and_mode_dispatch  Plan Section 4.4, Stage-4 named test.
%
% Two DISTINCT mode strings exist in this codebase and must never be confused:
%   'fourTimestampClockDifference'  the Section 4.4 observable this stage implements (sanctioned,
%                                    dispatched from revgnss.TwoWayTimeTransferBuilder and
%                                    revgnss.IndependentFleetCoordinator's sanctionedObservables).
%   'fourTimestampPhysical'         revgnss.ReciprocalTimeTransferModel.PhysicalTimestampMode --
%                                    a DIFFERENT, still-reserved raw-tag scheme that stays
%                                    unimplemented and must keep throwing
%                                    ReciprocalTimeTransferModel:fourTimestampUnavailable
%                                    everywhere, unaffected by this stage's work.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
addpath(rootDir);
addpath(fullfile(rootDir,'config'));
addpath(fullfile(rootDir,'config','internal'));

fprintf('=== test_four_timestamp_naming_and_mode_dispatch ===\n');
i_test_groundSpace_mode_dispatches_to_new_builder_not_legacy_();
i_test_groundSpace_mode_bad_config_gives_four_timestamp_specific_error_();
i_test_reservedPhysicalMode_still_throws_unavailable_();
i_test_legacy_firstOrderMode_unaffected_();
i_test_coordinator_recognizes_fourTimestampClockDifference_as_sanctioned_();
i_test_coordinator_rejects_reservedPhysicalMode_as_observable_();
fprintf('=== test_four_timestamp_naming_and_mode_dispatch: ALL PASS ===\n');
end

% ================================================================================================
function i_test_groundSpace_mode_dispatches_to_new_builder_not_legacy_()
cfg = i_baseGroundSpaceConfig_();
cfg.measurements.twoWayTimeTransfer.mode = 'fourTimestampClockDifference';
% Must not throw: dispatched to revgnss.FourTimestampGroundSpaceTimeTransferBuilder.validateConfig,
% never reaching revgnss.ReciprocalTimeTransferModel.validateMode (which would reject this string
% outright -- neither 'firstOrderReciprocal' nor 'fourTimestampPhysical').
revgnss.TwoWayTimeTransferBuilder.validateConfig(cfg);
fprintf('  PASS mode=fourTimestampClockDifference dispatches to the new builder (no legacy validateMode call)\n');
end

% ================================================================================================
function i_test_groundSpace_mode_bad_config_gives_four_timestamp_specific_error_()
cfg = i_baseGroundSpaceConfig_();
cfg.measurements.twoWayTimeTransfer.mode = 'fourTimestampClockDifference';
% terminalDelayAllocation is a field that only revgnss.FourTimestampGroundSpaceTimeTransferBuilder's
% own validateConfig checks -- the legacy path has no such field at all. Getting THIS specific
% error identifier is direct proof of real dispatch, not just "no error was thrown".
cfg.measurements.twoWayTimeTransfer.fourTimestampPhysical.terminalDelayAllocation = 'bogus';
threw = false;
try
    revgnss.TwoWayTimeTransferBuilder.validateConfig(cfg);
catch ME
    threw = strcmp(ME.identifier,'FourTimestampGroundSpaceTimeTransferBuilder:terminalDelayAllocation');
end
assert(threw,'FAIL: a bad fourTimestampPhysical.terminalDelayAllocation must surface the new builder''s own error.');
fprintf('  PASS a four-timestamp-specific config error proves real dispatch to the new builder\n');
end

% ================================================================================================
function i_test_reservedPhysicalMode_still_throws_unavailable_()
cfg = i_baseGroundSpaceConfig_();
cfg.measurements.twoWayTimeTransfer.mode = 'fourTimestampPhysical';
threw = false;
try
    revgnss.TwoWayTimeTransferBuilder.validateConfig(cfg);
catch ME
    threw = strcmp(ME.identifier,'ReciprocalTimeTransferModel:fourTimestampUnavailable');
end
assert(threw,'FAIL: fourTimestampPhysical must still be rejected as reserved/unimplemented.');
% And directly, at the model level (the two names must never collapse into one code path):
threwDirect = false;
try
    revgnss.ReciprocalTimeTransferModel.validateMode('fourTimestampPhysical');
catch ME
    threwDirect = strcmp(ME.identifier,'ReciprocalTimeTransferModel:fourTimestampUnavailable');
end
assert(threwDirect);
threwOk = true;
try
    revgnss.ReciprocalTimeTransferModel.validateMode('fourTimestampClockDifference');
    threwOk = false;
catch
    % expected: validateMode's own vocabulary is firstOrderReciprocal/fourTimestampPhysical only.
end
assert(threwOk,'FAIL: ReciprocalTimeTransferModel.validateMode must not silently accept fourTimestampClockDifference either.');
fprintf('  PASS fourTimestampPhysical stays reserved/unimplemented both via TwoWayTimeTransferBuilder and directly\n');
end

% ================================================================================================
function i_test_legacy_firstOrderMode_unaffected_()
cfg = i_baseGroundSpaceConfig_();
cfg.measurements.twoWayTimeTransfer.mode = 'firstOrderReciprocal';
revgnss.TwoWayTimeTransferBuilder.validateConfig(cfg);
fprintf('  PASS legacy mode=firstOrderReciprocal is unaffected by the new dispatch branch\n');
end

% ================================================================================================
function i_test_coordinator_recognizes_fourTimestampClockDifference_as_sanctioned_()
cfg = i_sanctionedIslFleetConfig_();
revgnss.IndependentFleetCoordinator.validateConfig(cfg);
fprintf('  PASS IndependentFleetCoordinator.validateConfig accepts fourTimestampClockDifference as a sanctioned observable\n');
end

% ================================================================================================
function i_test_coordinator_rejects_reservedPhysicalMode_as_observable_()
cfg = i_sanctionedIslFleetConfig_();
cfg.multiAsset.distributedEstimator.linkUpdate.updateAdapter.observable = 'fourTimestampPhysical';
threw = false;
try
    revgnss.IndependentFleetCoordinator.validateConfig(cfg);
catch ME
    threw = strcmp(ME.identifier,'IndependentFleetCoordinator:linkUpdateUnavailable');
end
assert(threw,'FAIL: fourTimestampPhysical must not be accepted as a sanctioned observable string.');
fprintf('  PASS IndependentFleetCoordinator rejects fourTimestampPhysical as an observable identifier\n');
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
end

% ================================================================================================
function cfg = i_sanctionedIslFleetConfig_()
cfg = masterConfig();
cfg.simulation.duration_s = 5;
cfg.simulation.dt_s = 1;
cfg.report.writePdf = false;
cfg.report.writeMat = false;
cfg.report.compileTex = 'never';
cfg.plots.enable = false;
cfg.plots.showFigures = false;

cfg.scenario.nSpaceAssets = 2;
cfg.multiAsset.mode = 'fast';
cfg.multiAsset.estimateMode = 'off';
cfg.multiAsset.keepIslInPerAssetEkf = false;
cfg.multiAsset.towersObserveSecondaries = false;

cfg.multiAsset.distributedEstimator.enable = true;
cfg.multiAsset.distributedEstimator.stateExchange.enable = false;
cfg.multiAsset.distributedEstimator.deliveryLedger.enable = true;
cfg.multiAsset.distributedEstimator.linkUpdate.enable = true;
cfg.multiAsset.distributedEstimator.linkUpdate.ownerPolicy = 'initiator';
cfg.multiAsset.distributedEstimator.linkUpdate.correlationPolicy = 'splitCovarianceIntersection';
cfg.multiAsset.distributedEstimator.linkUpdate.updateAdapter.observable = 'fourTimestampClockDifference';

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
