% test_stage30_main_validation_gate_smoke  Smoke tests for Stage 30 validation gate.
%
% T1: MainScriptValidationGate.isEnabled() responds to the env var.
% T2: ReportStatus.current() returns stage >= 30.
% T3: missingScientificStages contains no stale Stage-24 wording.

fprintf('test_stage30_main_validation_gate_smoke\n');

% T1: isEnabled() controlled by OO_V1_VALIDATE_REPORT
orig = getenv('OO_V1_VALIDATE_REPORT');
setenv('OO_V1_VALIDATE_REPORT', '');
assert(~revgnss.MainScriptValidationGate.isEnabled(), ...
    'T1a: isEnabled() should be false when env var is empty');
setenv('OO_V1_VALIDATE_REPORT', 'true');
assert(revgnss.MainScriptValidationGate.isEnabled(), ...
    'T1b: isEnabled() should be true when env var is ''true''');
setenv('OO_V1_VALIDATE_REPORT', orig);
fprintf('T1 PASS: isEnabled() responds correctly to OO_V1_VALIDATE_REPORT\n');

% T2: ReportStatus stage is a number >= 30
s = revgnss.ReportStatus.current();
assert(isfield(s, 'stage'), 'T2: ReportStatus.current() missing field stage');
assert(str2double(char(s.stage)) >= 30, ...
    sprintf('T2: stage should be numeric >= 30, got ''%s''', char(s.stage)));
fprintf('T2 PASS: ReportStatus.current().stage is numeric >= 30\n');

% T3: missingScientificStages has no stale Stage-24 wording
stale = 'Stage 24 runs targeted smoke only';
hasStale = any(cellfun(@(x) contains(x, stale), s.missingScientificStages));
assert(~hasStale, 'T3: missingScientificStages still contains stale Stage-24 entry');
fprintf('T3 PASS: no stale Stage-24 entry in missingScientificStages\n');

fprintf('\ntest_stage30_main_validation_gate_smoke: all 3 tests passed.\n');
