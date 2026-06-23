% test_stage29_report_status_freshness  Smoke tests for Stage 29 ReportStatus.
%
% T1: ReportStatus.current() returns stage field >= '29' (currently '83').
% T2: missingStages_ list does NOT contain 'Stage 24 runs targeted smoke only'.
% T3: validationArtifactFresh field exists and is logical.
% T4: summaryLines() includes the string 'Stage 29'.

fprintf('test_stage29_report_status_freshness\n');

% T1: stage field >= some valid number; currently '83'
s = revgnss.ReportStatus.current();
assert(isfield(s, 'stage'), 'T1: ReportStatus.current() missing stage field');
assert(str2double(char(s.stage)) >= 29, ...
    sprintf('T1: stage should be numeric >= 29, got ''%s''', char(s.stage)));
fprintf('T1 PASS: ReportStatus.current() returns stage >= 29\n');

% T2: stale 'Stage 24 runs targeted smoke only' entry removed
lines = revgnss.ReportStatus.current();
missList = lines.missingScientificStages;
stale = 'Stage 24 runs targeted smoke only';
hasStale = any(cellfun(@(x) contains(x, stale), missList));
assert(~hasStale, 'T2: missingScientificStages still contains stale Stage-24 entry');
fprintf('T2 PASS: missingScientificStages does not contain stale Stage-24 entry\n');

% T3: validationArtifactFresh is a logical scalar
assert(isfield(s, 'validationArtifactFresh'), 'T3: missing field validationArtifactFresh');
assert(islogical(s.validationArtifactFresh) && isscalar(s.validationArtifactFresh), ...
    'T3: validationArtifactFresh must be a logical scalar');
fprintf('T3 PASS: validationArtifactFresh is a logical scalar (value = %s)\n', ...
    mat2str(s.validationArtifactFresh));

% T4: summaryLines() includes 'Stage 29'
sl = revgnss.ReportStatus.summaryLines();
assert(iscell(sl) && ~isempty(sl), 'T4: summaryLines() returned empty or non-cell');
combined = strjoin(sl, ' ');
assert(~isempty(strfind(combined, 'Stage ')), ... %#ok<STREMP>
    'T4: summaryLines() does not contain any stage string');
fprintf('T4 PASS: summaryLines() contains stage string\n');

fprintf('\ntest_stage29_report_status_freshness: all 4 tests passed.\n');
