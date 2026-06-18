% test_stage31_attitude_observability_audit  Smoke tests for Stage 31 audit.
%
% T1: Zero lever arm + zero H attitude columns -> unobservable classification.
% T2: Nonzero H attitude + nonzero lever arms -> rank > 0, sensitiveRowCount > 0.
% T3: Code-only rows -> classification does not claim 'observable-float-carrier-or-mixed'.
% T4: ReportStatus.current() returns stage '31'.
% T5: missingScientificStages contains no stale attitude-observability-audit wording.

fprintf('test_stage31_attitude_observability_audit\n');

% Minimal stateMap mimicking ReverseGNSSEKF defaults
sm.r_idx     = (1:3)';
sm.v_idx     = (4:6)';
sm.euler_idx = (7:9)';
sm.omega_idx = (10:12)';
sm.b_rx_idx  = 13;
sm.bdot_rx_idx = 14;
sm.towerClockIdx = [];
sm.ambiguityIdx  = [];
sm.zwdIdx        = [];

nx = 14;
M  = 8;   % measurement rows

% Minimal cfg with zero lever arm
cfgZero.scenario.nReceivers = 1;
cfgZero.asset.receiverLeverArms_body_m = [0; 0; 0];
cfgZero.diagnostics.attitudeObservability.enable = true;

% --- T1: zero lever arm ---
H_zero = zeros(M, nx);
s1 = revgnss.AttitudeObservability.audit(H_zero, sm, cfgZero, {});
assert(strcmp(s1.classification, 'unobservable-zero-lever-arm'), ...
    sprintf('T1: expected unobservable-zero-lever-arm, got %s', s1.classification));
assert(~s1.isObservable, 'T1: isObservable should be false for zero lever arm');
fprintf('T1 PASS: zero lever arm -> unobservable-zero-lever-arm\n');

% --- T2: nonzero H attitude + nonzero lever arm ---
cfgNZ.scenario.nReceivers = 3;
cfgNZ.asset.receiverLeverArms_body_m = [1 -1 0; 0 0 1; 0 0 0];  % 3x3
cfgNZ.diagnostics.attitudeObservability.enable = true;

H_nz = zeros(M, nx);
H_nz(:, sm.euler_idx) = randn(M, 3);   % nonzero attitude columns
mTypes = [repmat({'carrier'},4,1); repmat({'code'},4,1)];
s2 = revgnss.AttitudeObservability.audit(H_nz, sm, cfgNZ, mTypes);
assert(s2.attitudeRank > 0, 'T2: attitudeRank should be > 0 for nonzero H_att');
assert(s2.attitudeSensitiveRowCount > 0, 'T2: attitudeSensitiveRowCount should be > 0');
assert(s2.hasNonzeroLeverArm, 'T2: hasNonzeroLeverArm should be true');
fprintf('T2 PASS: nonzero H_att + nonzero lever arm -> rank %d, sensitiveRows %d\n', ...
    s2.attitudeRank, s2.attitudeSensitiveRowCount);

% --- T3: code-only rows, nonzero lever arm ---
mTypesCode = repmat({'code'}, M, 1);
s3 = revgnss.AttitudeObservability.audit(H_nz, sm, cfgNZ, mTypesCode);
assert(~strcmp(s3.classification, 'observable-float-carrier-or-mixed') || ...
    s3.attitudeRank >= 3, ...
    'T3: code-only cannot be classified as observable-float-carrier-or-mixed unless rank >= 3');
assert(s3.nCarrierRows == 0, 'T3: nCarrierRows should be 0 for code-only input');
fprintf('T3 PASS: code-only -> classification ''%s'', nCarrierRows = 0\n', s3.classification);

% --- T4: ReportStatus stage == '31' ---
rs = revgnss.ReportStatus.current();
assert(strcmp(char(rs.stage), '31'), ...
    sprintf('T4: stage should be ''31'', got ''%s''', char(rs.stage)));
fprintf('T4 PASS: ReportStatus.current().stage = ''31''\n');

% --- T5: no stale attitude audit wording in missingScientificStages ---
stale = 'Attitude observability audit for single space asset';
hasStale = any(cellfun(@(x) contains(x, stale), rs.missingScientificStages));
assert(~hasStale, 'T5: missingScientificStages still contains stale Stage-31 entry');
fprintf('T5 PASS: no stale attitude-observability-audit entry in missingScientificStages\n');

fprintf('\ntest_stage31_attitude_observability_audit: all 5 tests passed.\n');
