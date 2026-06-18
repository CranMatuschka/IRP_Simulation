% test_stage32_receiver_geometry_model  Smoke tests for Stage 32.
%
% T1: Plural lever-arm field -> nReceiversGeometry=3, 3 baselines, nonzero max norm.
% T2: Singular lever-arm field only -> one receiver, nonzero lever arm.
% T3: Declared count mismatches geometry -> warnings nonempty.
% T4: ReportStatus.current() returns stage '32'.
% T5: missingScientificStages has no stale antenna-geometry wording.

fprintf('test_stage32_receiver_geometry_model\n');

% --- T1: plural lever-arm field ---
c1.scenario.nReceivers = 3;
c1.asset.name          = 'GEO-1';
c1.asset.assetIndex    = 1;
c1.asset.receiverLeverArms_body_m = [1 -1 0; 0 0 1; 0 0 0];   % 3 x 3
g1 = revgnss.ReceiverGeometry.fromConfig(c1);
assert(g1.nReceiversGeometry == 3, ...
    sprintf('T1: expected nReceiversGeometry=3, got %d', g1.nReceiversGeometry));
assert(numel(g1.baselineLengths_m) == 3, ...
    sprintf('T1: expected 3 baselines, got %d', numel(g1.baselineLengths_m)));
assert(g1.leverArmMaxNorm_m > 0, 'T1: leverArmMaxNorm_m should be > 0');
assert(g1.hasNonzeroLeverArm, 'T1: hasNonzeroLeverArm should be true');
fprintf('T1 PASS: plural lever arm -> nReceivers=%d, baselines=%d, maxNorm=%.3f m\n', ...
    g1.nReceiversGeometry, numel(g1.baselineLengths_m), g1.leverArmMaxNorm_m);

% --- T2: singular lever-arm field only ---
c2.scenario.nReceivers = 1;
c2.asset.receiverLeverArm_body_m = [1; 0; 0];
% no plural field
g2 = revgnss.ReceiverGeometry.fromConfig(c2);
assert(g2.nReceiversGeometry == 1, ...
    sprintf('T2: expected nReceiversGeometry=1, got %d', g2.nReceiversGeometry));
assert(g2.leverArmMaxNorm_m > 0, 'T2: leverArmMaxNorm_m should be > 0 for [1;0;0]');
assert(g2.hasNonzeroLeverArm, 'T2: hasNonzeroLeverArm should be true');
assert(isempty(g2.baselineLengths_m), 'T2: single receiver should have no baselines');
fprintf('T2 PASS: singular lever arm -> nReceivers=%d, maxNorm=%.3f m\n', ...
    g2.nReceiversGeometry, g2.leverArmMaxNorm_m);

% --- T3: declared count mismatches geometry ---
c3.scenario.nReceivers = 3;
c3.asset.receiverLeverArm_body_m = [0.5; 0; 0];   % only 1 column
g3 = revgnss.ReceiverGeometry.fromConfig(c3);
assert(~isempty(g3.warnings), 'T3: warnings should be nonempty when nReceivers=3 but geometry=1');
fprintf('T3 PASS: mismatch warning present: "%s"\n', g3.warnings{1});

% --- T4: ReportStatus stage == '32' ---
rs = revgnss.ReportStatus.current();
assert(strcmp(char(rs.stage), '32'), ...
    sprintf('T4: expected stage ''32'', got ''%s''', char(rs.stage)));
fprintf('T4 PASS: ReportStatus.current().stage = ''32''\n');

% --- T5: no stale antenna-geometry wording in missingScientificStages ---
stale = 'Space-asset antenna geometry and lever-arm model';
hasStale = any(cellfun(@(x) contains(x, stale), rs.missingScientificStages));
assert(~hasStale, 'T5: missingScientificStages still contains stale Stage-32 entry');
fprintf('T5 PASS: no stale antenna-geometry entry in missingScientificStages\n');

fprintf('\ntest_stage32_receiver_geometry_model: all 5 tests passed.\n');
