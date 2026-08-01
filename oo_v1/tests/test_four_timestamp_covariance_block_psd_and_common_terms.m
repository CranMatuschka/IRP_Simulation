function test_four_timestamp_covariance_block_psd_and_common_terms()
% test_four_timestamp_covariance_block_psd_and_common_terms  Plan Section 4.2, Stage-4 test list
% item 9. revgnss.ReciprocalTimeTransferCovarianceBuilder must: assemble a genuinely
% block-diagonal, symmetric, positive-semidefinite covariance from named sub-blocks in the exact
% componentOrder of the blocks supplied; degrade absent/not-applicable blocks (relay,
% sessionCommonMode on a direct topology) to a true zero-row contribution rather than a
% fabricated zero-variance term; and reject an assembled result that is not PSD.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
addpath(rootDir);

fprintf('=== test_four_timestamp_covariance_block_psd_and_common_terms ===\n');
i_test_each_block_shape_and_labels_();
i_test_assemble_block_diagonal_order_and_psd_();
i_test_direct_topology_relay_and_session_blocks_degrade_to_zero_row_();
i_test_session_common_mode_block_carries_the_shared_term_();
i_test_assemble_rejects_non_psd_();
i_test_assemble_rejects_malformed_block_shape_();
i_test_session_common_mode_block_array_input_via_blkdiag_();
i_test_relay_block_non_empty_validated_();
i_test_product_calibration_block_rejects_range_units_();
i_test_terminal_modem_delay_block_empty_covariance_degrades_();
i_test_terminal_modem_delay_block_uses_named_component_order_();
fprintf('=== test_four_timestamp_covariance_block_psd_and_common_terms: ALL PASS ===\n');
end

% ================================================================================================
function i_test_each_block_shape_and_labels_()
B = revgnss.ReciprocalTimeTransferCovarianceBuilder;
blk = B.counterTagNoiseBlock([2e-9,3e-9],{'t1CounterNoise','t4CounterNoise'});
assert(isequal(diag(blk.covariance),[4e-18;9e-18]));
assert(isequal(blk.componentOrder,{'t1CounterNoise','t4CounterNoise'}));

blkAtm = B.atmosphereBlock([1e-19,2e-19,3e-19,4e-19]);
assert(isequal(diag(blkAtm.covariance),[1e-19;2e-19;3e-19;4e-19]));
assert(numel(blkAtm.componentOrder)==4);
fprintf('  PASS individual block shapes and componentOrder labels\n');
end

% ================================================================================================
function i_test_assemble_block_diagonal_order_and_psd_()
B = revgnss.ReciprocalTimeTransferCovarianceBuilder;
blk1 = B.counterTagNoiseBlock([1e-9,1e-9],{'a','b'});
blk2 = B.atmosphereBlock([2e-19,3e-19]);
[C,order,~] = B.assemble({blk1,blk2});
assert(isequal(size(C),[4 4]));
% Block-diagonal: cross terms between the two blocks must be exactly zero.
assert(isequal(C(1:2,3:4),zeros(2,2)) && isequal(C(3:4,1:2),zeros(2,2)), ...
    'FAIL: assembled covariance must be block-diagonal with zero cross-terms between sources');
assert(isequal(order,{'a','b','atmosphereDelay:1','atmosphereDelay:2'}), ...
    'FAIL: componentOrder must preserve the exact order blocks were supplied in');
assert(norm(C-C','fro') < 1e-30,'FAIL: assembled covariance must be exactly symmetric');
assert(min(eig(C)) >= -1e-25,'FAIL: assembled covariance must be positive semidefinite');
fprintf('  PASS assemble is block-diagonal, order-preserving, symmetric, PSD\n');
end

% ================================================================================================
function i_test_direct_topology_relay_and_session_blocks_degrade_to_zero_row_()
B = revgnss.ReciprocalTimeTransferCovarianceBuilder;
blk1 = B.counterTagNoiseBlock([1e-9],{'a'});
relayBlk = B.relayBlock([]);
sessionBlk = B.sessionCommonModeBlock([]);
assert(isequal(size(relayBlk.covariance),[0 0]));
assert(isequal(size(sessionBlk.covariance),[0 0]));
[C,order,ids] = B.assemble({blk1,relayBlk,sessionBlk});
assert(isequal(size(C),[1 1]), ...
    'FAIL: an absent relay/session block on a direct topology must contribute zero rows');
assert(numel(order)==1);
assert(isempty(ids));
fprintf('  PASS relay/session blocks degrade to a true zero-row contribution on a direct topology\n');
end

% ================================================================================================
function i_test_session_common_mode_block_carries_the_shared_term_()
csg = revgnss.CommonSourceCovarianceGroup(struct( ...
    'covarianceGroupIdentifier','grp:shared','commonSourceName','sessionTimingProduct', ...
    'treatment','covarianceGroup','sourceProductIdentifier','prod:osc', ...
    'memberObservationIdentifiers',{{'obs:1','obs:2'}}, ...
    'memberDeliveryIdentifiers',{{'del:1','del:2'}}, ...
    'memberRowCount',2,'sharedCovarianceContribution_m2',[2 0.5;0.5 2], ...
    'temporalCovarianceModel','randomWalk','correlationTime_s',0, ...
    'processNoisePsd_m2PerS',1e-6,'validFromEpoch_s',0,'validUntilEpoch_s',1e6, ...
    'externalProductIdentifier',''));
B = revgnss.ReciprocalTimeTransferCovarianceBuilder;
block = B.sessionCommonModeBlock(csg);
assert(isequal(block.covariance,[2 0.5;0.5 2]), ...
    'FAIL: sessionCommonModeBlock must carry the shared covariance contribution unchanged');
assert(isequal(block.sourceIdentifiers,{'grp:shared'}));
% Off-diagonal (shared/common) term must survive assembly unchanged -- this is the actual
% "common term" the two rows of a shared session source are correlated through.
[C,~,~] = B.assemble({block});
assert(abs(C(1,2)-0.5) < 1e-15 && abs(C(2,1)-0.5) < 1e-15, ...
    'FAIL: the off-diagonal common-mode term must be preserved through assembly');
fprintf('  PASS sessionCommonModeBlock carries the shared off-diagonal common term through assembly\n');
end

% ================================================================================================
function i_test_assemble_rejects_non_psd_()
% Per-block validation (Stage 4.2 combined review finding 11) now catches a non-PSD input block
% at assemble() entry, before block-diagonal placement -- earlier and with a clearer per-block
% identifier than the final assembled-matrix PSD check this test used to exercise.
B = revgnss.ReciprocalTimeTransferCovarianceBuilder;
badBlock = struct('covariance',[1 5;5 1],'componentOrder',{{'a','b'}},'sourceIdentifiers',{{}});
threw = false;
try
    B.assemble({badBlock});
catch ME
    threw = strcmp(ME.identifier,'ReciprocalTimeTransferCovarianceBuilder:blockShape');
end
assert(threw,'FAIL: a non-PSD input block must be rejected at assemble() entry');
fprintf('  PASS assemble rejects a non-positive-semidefinite input block\n');
end

% ================================================================================================
function i_test_assemble_rejects_malformed_block_shape_()
B = revgnss.ReciprocalTimeTransferCovarianceBuilder;
badBlock = struct('covariance',eye(3),'componentOrder',{{'a','b'}},'sourceIdentifiers',{{}});
threw = false;
try
    B.assemble({badBlock});
catch ME
    threw = strcmp(ME.identifier,'ReciprocalTimeTransferCovarianceBuilder:blockShape');
end
assert(threw,'FAIL: a componentOrder length mismatched with covariance rows must be rejected');
fprintf('  PASS assemble rejects a block whose componentOrder length mismatches its covariance\n');
end

% ================================================================================================
function i_test_session_common_mode_block_array_input_via_blkdiag_()
B = revgnss.ReciprocalTimeTransferCovarianceBuilder;
csg1 = revgnss.CommonSourceCovarianceGroup(struct( ...
    'covarianceGroupIdentifier','grp:1','commonSourceName','sessionTimingProduct', ...
    'treatment','covarianceGroup','sourceProductIdentifier','prod:1', ...
    'memberObservationIdentifiers',{{'obs:1'}},'memberDeliveryIdentifiers',{{'del:1'}}, ...
    'memberRowCount',1,'sharedCovarianceContribution_m2',2, ...
    'temporalCovarianceModel','randomWalk','correlationTime_s',0, ...
    'processNoisePsd_m2PerS',1e-6,'validFromEpoch_s',0,'validUntilEpoch_s',1e6, ...
    'externalProductIdentifier',''));
csg2 = revgnss.CommonSourceCovarianceGroup(struct( ...
    'covarianceGroupIdentifier','grp:2','commonSourceName','sessionTimingProduct', ...
    'treatment','covarianceGroup','sourceProductIdentifier','prod:2', ...
    'memberObservationIdentifiers',{{'obs:2'}},'memberDeliveryIdentifiers',{{'del:2'}}, ...
    'memberRowCount',1,'sharedCovarianceContribution_m2',3, ...
    'temporalCovarianceModel','randomWalk','correlationTime_s',0, ...
    'processNoisePsd_m2PerS',1e-6,'validFromEpoch_s',0,'validUntilEpoch_s',1e6, ...
    'externalProductIdentifier',''));
groups = [csg1,csg2];
block = B.sessionCommonModeBlock(groups); % previously crashed: struct() field/value NonPairedArgs
assert(isequal(block.covariance,blkdiag(2,3)), ...
    'FAIL: two groups must assemble as independent block-diagonal sub-blocks, no crash');
assert(isequal(block.sourceIdentifiers,{'grp:1','grp:2'}));
assert(numel(block.componentOrder)==2);
fprintf('  PASS sessionCommonModeBlock accepts an array of groups via blkdiag, no crash\n');
end

% ================================================================================================
function i_test_relay_block_non_empty_validated_()
B = revgnss.ReciprocalTimeTransferCovarianceBuilder;
goodBlock = struct('covariance',eye(2)*1e-18,'componentOrder',{{'r1','r2'}},'sourceIdentifiers',{{}});
block = B.relayBlock(goodBlock);
assert(isequal(block.covariance,eye(2)*1e-18),'FAIL: a valid non-empty relay block must pass through');
threw = false;
try
    B.relayBlock(struct('covariance',eye(2),'componentOrder',{{'r1'}},'sourceIdentifiers',{{}}));
catch ME
    threw = strcmp(ME.identifier,'ReciprocalTimeTransferCovarianceBuilder:blockShape');
end
assert(threw,'FAIL: relayBlock must validate a malformed non-empty block, not pass it through blindly');
fprintf('  PASS relayBlock validates its non-empty pass-through branch\n');
end

% ================================================================================================
function i_test_product_calibration_block_rejects_range_units_()
B = revgnss.ReciprocalTimeTransferCovarianceBuilder;
badRec = struct('calibrationStateIdentifier','cal:bad','scopeIdentifier','link:AB', ...
    'stateKind','linkRangeBiasResidual_m','ownershipKind','externalCalibrationProduct', ...
    'ownerAssetIdentifier','','ownerCanonicalIndex',0,'externalProductIdentifier','ext:1', ...
    'temporalCovarianceModel','externalProductCovariance','correlationTime_s',0, ...
    'processNoisePsd_perS',0,'processNoisePsdUnits','m^2/s','priorVariance',1e-4, ...
    'priorVarianceUnits','m^2','validFromLocalTag_s',0,'validUntilLocalTag_s',1e6, ...
    'estimationStatus','notEstimated');
badCal = revgnss.DistributedLinkCalibrationState(badRec);
threw = false;
try
    B.productCalibrationBlock(badCal);
catch ME
    threw = strcmp(ME.identifier,'ReciprocalTimeTransferCovarianceBuilder:productCalibrationUnits');
end
assert(threw,'FAIL: productCalibrationBlock must itself reject an m^2-domain calibration state');
fprintf('  PASS productCalibrationBlock enforces the s^2 unit guard directly (not just via a caller)\n');
end

% ================================================================================================
function i_test_terminal_modem_delay_block_empty_covariance_degrades_()
B = revgnss.ReciprocalTimeTransferCovarianceBuilder;
hw = revgnss.ReciprocalLinkHardwareModel('parameterSource','physicalTruth', ...
    'physicalChainIdentifier','chain:1','calibrationProductIdentifier','', ...
    'turnaroundProperTime_s',1e-3); % default calibrationCovariance_s2 is now zeros(0,0)
block = B.terminalModemDelayBlock(hw);
assert(isequal(size(block.covariance),[0 0]), ...
    'FAIL: an undeclared calibration covariance must degrade to a true zero-row block, not a fabricated 1x1 zero');
fprintf('  PASS terminalModemDelayBlock degrades an empty hardware covariance to a true zero-row block\n');
end

% ================================================================================================
function i_test_terminal_modem_delay_block_uses_named_component_order_()
B = revgnss.ReciprocalTimeTransferCovarianceBuilder;
hw = revgnss.ReciprocalLinkHardwareModel('parameterSource','physicalTruth', ...
    'physicalChainIdentifier','chain:1','calibrationProductIdentifier','prod:xyz', ...
    'turnaroundProperTime_s',1e-3,'calibrationCovariance_s2',diag([1e-19,2e-19]), ...
    'calibrationCovarianceComponentOrder',{'originGroupDelay','anchorGroupDelay'});
block = B.terminalModemDelayBlock(hw);
assert(isequal(block.componentOrder,{'originGroupDelay','anchorGroupDelay'}), ...
    'FAIL: terminalModemDelayBlock must use the hardware''s own named component order when declared');
fprintf('  PASS terminalModemDelayBlock uses the hardware''s own calibrationCovarianceComponentOrder\n');
end
