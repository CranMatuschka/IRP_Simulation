function test_four_timestamp_short_long_terminal_geometry_translation()
% test_four_timestamp_short_long_terminal_geometry_translation  Plan Section 4.4, Stage-4 named
% test. revgnss.FourTimestampPhysicalLinkConfig.shortNameIslTerminalGeometry/
% shortNameGroundSpaceTerminalGeometry translate this project's LONG masterConfig field names
% (transmitPhaseCentreOffset_body_m/receivePhaseCentreOffset_body_m) into the SHORT names
% revgnss.ReciprocalEndpointTruthProvider.spacecraft/fixedStation hard-require
% (transmitOffset_body_m/receiveOffset_body_m) -- genuinely different, non-interchangeable field
% names (confirmed by direct read during Section 4.4 design), not a documentation inconsistency.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
addpath(rootDir);
addpath(fullfile(rootDir,'config'));
addpath(fullfile(rootDir,'config','internal'));

fprintf('=== test_four_timestamp_short_long_terminal_geometry_translation ===\n');
i_test_isl_translation_reuses_long_names_verbatim_();
i_test_isl_translation_rejects_malformed_offset_();
i_test_isl_translation_identifiers_vary_by_asset_index_();
i_test_groundSpace_tower_translation_reads_correct_leaf_();
i_test_groundSpace_spacecraft_translation_reads_correct_leaf_();
i_test_groundSpace_translation_rejects_bad_endpointKind_();
i_test_groundSpace_translation_rejects_malformed_offset_();
i_test_groundSpace_identifiers_vary_by_supplied_identifier_();
fprintf('=== test_four_timestamp_short_long_terminal_geometry_translation: ALL PASS ===\n');
end

% ================================================================================================
function i_test_isl_translation_reuses_long_names_verbatim_()
cfg = masterConfig();
expectedTx = cfg.measurements.isl.twoWay.terminalGeometry.transmitPhaseCentreOffset_body_m;
expectedRx = cfg.measurements.isl.twoWay.terminalGeometry.receivePhaseCentreOffset_body_m;
short = revgnss.FourTimestampPhysicalLinkConfig.shortNameIslTerminalGeometry(cfg,1);
assert(isfield(short,'transmitOffset_body_m') && isfield(short,'receiveOffset_body_m'));
assert(norm(short.transmitOffset_body_m(:)-expectedTx(:)) < 1e-12, ...
    'FAIL: shortNameIslTerminalGeometry must reuse isl.twoWay.terminalGeometry.transmitPhaseCentreOffset_body_m verbatim.');
assert(norm(short.receiveOffset_body_m(:)-expectedRx(:)) < 1e-12, ...
    'FAIL: shortNameIslTerminalGeometry must reuse isl.twoWay.terminalGeometry.receivePhaseCentreOffset_body_m verbatim.');
fprintf('  PASS ISL translation reuses isl.twoWay.terminalGeometry.* offsets verbatim (no new leaf)\n');
end

% ================================================================================================
function i_test_isl_translation_rejects_malformed_offset_()
cfg = masterConfig();
cfg.measurements.isl.twoWay.terminalGeometry.transmitPhaseCentreOffset_body_m = [1;2];
threw = false;
try
    revgnss.FourTimestampPhysicalLinkConfig.shortNameIslTerminalGeometry(cfg,1);
catch ME
    threw = strcmp(ME.identifier,'FourTimestampPhysicalLinkConfig:islTerminalGeometry');
end
assert(threw,'FAIL: a 2-element offset must be rejected.');
fprintf('  PASS ISL translation rejects a malformed (non-3-vector) offset\n');
end

% ================================================================================================
function i_test_isl_translation_identifiers_vary_by_asset_index_()
cfg = masterConfig();
short1 = revgnss.FourTimestampPhysicalLinkConfig.shortNameIslTerminalGeometry(cfg,1);
short2 = revgnss.FourTimestampPhysicalLinkConfig.shortNameIslTerminalGeometry(cfg,2);
assert(~strcmp(short1.transmitTerminalIdentifier,short2.transmitTerminalIdentifier), ...
    'FAIL: distinct assets must get distinct terminal identifiers.');
assert(~strcmp(short1.receiveTerminalIdentifier,short2.receiveTerminalIdentifier));
assert(contains(short1.transmitTerminalIdentifier,'asset-1'));
assert(contains(short2.transmitTerminalIdentifier,'asset-2'));
fprintf('  PASS ISL translation identifiers are asset-index-distinct: %s vs %s\n', ...
    short1.transmitTerminalIdentifier,short2.transmitTerminalIdentifier);
end

% ================================================================================================
function i_test_groundSpace_tower_translation_reads_correct_leaf_()
cfg = masterConfig();
expectedTx = cfg.measurements.twoWayTimeTransfer.fourTimestampPhysical.towerTerminalGeometry. ...
    transmitPhaseCentreOffset_body_m;
short = revgnss.FourTimestampPhysicalLinkConfig.shortNameGroundSpaceTerminalGeometry(cfg,'tower','tower:1');
assert(norm(short.transmitOffset_body_m(:)-expectedTx(:)) < 1e-12, ...
    'FAIL: ''tower'' must read towerTerminalGeometry, not spacecraftTerminalGeometry.');
assert(contains(short.transmitTerminalIdentifier,'tower:1'));
fprintf('  PASS ground-space ''tower'' reads towerTerminalGeometry.* (default zeros(3,1))\n');
end

% ================================================================================================
function i_test_groundSpace_spacecraft_translation_reads_correct_leaf_()
cfg = masterConfig();
expectedTx = cfg.measurements.twoWayTimeTransfer.fourTimestampPhysical.spacecraftTerminalGeometry. ...
    transmitPhaseCentreOffset_body_m;
short = revgnss.FourTimestampPhysicalLinkConfig.shortNameGroundSpaceTerminalGeometry(cfg,'spacecraft','sat:1');
assert(norm(short.transmitOffset_body_m(:)-expectedTx(:)) < 1e-12, ...
    'FAIL: ''spacecraft'' must read spacecraftTerminalGeometry, not towerTerminalGeometry.');
assert(norm(short.transmitOffset_body_m(:)-[0.8;0.2;0.3]) < 1e-12);
assert(contains(short.transmitTerminalIdentifier,'sat:1'));
% Distinct from the tower leaf's default (zeros), proving the two leaves are genuinely separate.
towerShort = revgnss.FourTimestampPhysicalLinkConfig.shortNameGroundSpaceTerminalGeometry(cfg,'tower','tower:1');
assert(norm(short.transmitOffset_body_m-towerShort.transmitOffset_body_m) > 1e-6, ...
    'FAIL: tower and spacecraft default offsets must be distinct (masterConfig default proof).');
fprintf('  PASS ground-space ''spacecraft'' reads spacecraftTerminalGeometry.* (default [0.8;0.2;0.3]), distinct from tower leaf\n');
end

% ================================================================================================
function i_test_groundSpace_translation_rejects_bad_endpointKind_()
cfg = masterConfig();
threw = false;
try
    revgnss.FourTimestampPhysicalLinkConfig.shortNameGroundSpaceTerminalGeometry(cfg,'satellite','x');
catch ME
    threw = strcmp(ME.identifier,'FourTimestampPhysicalLinkConfig:endpointKind');
end
assert(threw,'FAIL: an endpointKind other than tower/spacecraft must be rejected.');
fprintf('  PASS ground-space translation rejects an invalid endpointKind\n');
end

% ================================================================================================
function i_test_groundSpace_translation_rejects_malformed_offset_()
cfg = masterConfig();
cfg.measurements.twoWayTimeTransfer.fourTimestampPhysical.spacecraftTerminalGeometry. ...
    receivePhaseCentreOffset_body_m = [NaN;0;0];
threw = false;
try
    revgnss.FourTimestampPhysicalLinkConfig.shortNameGroundSpaceTerminalGeometry(cfg,'spacecraft','sat:1');
catch ME
    threw = strcmp(ME.identifier,'FourTimestampPhysicalLinkConfig:groundSpaceTerminalGeometry');
end
assert(threw,'FAIL: a non-finite offset must be rejected.');
fprintf('  PASS ground-space translation rejects a non-finite offset\n');
end

% ================================================================================================
function i_test_groundSpace_identifiers_vary_by_supplied_identifier_()
cfg = masterConfig();
shortA = revgnss.FourTimestampPhysicalLinkConfig.shortNameGroundSpaceTerminalGeometry(cfg,'tower','tower:1');
shortB = revgnss.FourTimestampPhysicalLinkConfig.shortNameGroundSpaceTerminalGeometry(cfg,'tower','tower:2');
assert(~strcmp(shortA.transmitTerminalIdentifier,shortB.transmitTerminalIdentifier));
assert(~strcmp(shortA.receiveAntennaIdentifier,shortB.receiveAntennaIdentifier));
fprintf('  PASS ground-space identifiers vary by the supplied identifier: %s vs %s\n', ...
    shortA.transmitTerminalIdentifier,shortB.transmitTerminalIdentifier);
end
