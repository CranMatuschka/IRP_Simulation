% test_stage37_pdf_status_relocation  Smoke tests for Stage 37.
%
% T1: ReportStatus.current() reports Stage >= 37.
% T2: README contains "Validation status and missing stages".
% T3: README contains at least one missing-stage item.
% T4: missingScientificStages non-empty and contains no "Validation Status" entry.

fprintf('test_stage37_pdf_status_relocation\n');

% --- T1: stage >= 37 ---
rs = revgnss.ReportStatus.current();
assert(str2double(char(rs.stage)) >= 37, ...
    sprintf('T1: stage should be >= 37, got ''%s''', char(rs.stage)));
fprintf('T1 PASS: ReportStatus.current().stage = ''%s'' (>= 37)\n', char(rs.stage));

% --- T2: README has "Validation status and missing stages" section ---
readmePath = fullfile(fileparts(fileparts(mfilename('fullpath'))), 'README_oo_v1.md');
assert(exist(readmePath,'file') == 2, 'T2: README_oo_v1.md not found');
readmeTxt = fileread(readmePath);
assert(contains(readmeTxt, 'Validation status and missing stages'), ...
    'T2: README should contain heading "Validation status and missing stages"');
fprintf('T2 PASS: README contains "Validation status and missing stages"\n');

% --- T3: README has at least one missing-stage item ---
hasMissing = ~isempty(regexp(readmeTxt, '- (Full|Quaternion|Calibrated|L2|Monte)', 'once'));
assert(hasMissing, 'T3: README should contain at least one missing-stage list item');
fprintf('T3 PASS: README contains missing-stage items\n');

% --- T4: missingScientificStages non-empty; no "Validation Status" in list ---
assert(~isempty(rs.missingScientificStages), ...
    'T4: missingScientificStages should not be empty');
hasValStat = any(cellfun(@(s) contains(lower(s), 'validation status'), ...
    rs.missingScientificStages));
assert(~hasValStat, ...
    'T4: missingScientificStages must not list "validation status" (it is not a scientific gap)');
fprintf('T4 PASS: missingScientificStages non-empty; no "validation status" item\n');

fprintf('\ntest_stage37_pdf_status_relocation: all 4 tests passed.\n');
