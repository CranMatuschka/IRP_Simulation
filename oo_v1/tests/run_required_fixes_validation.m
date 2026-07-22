function results = run_required_fixes_validation(varargin)
% run_required_fixes_validation  Noninteractive required-fix validation harness.
%
% Modes:
%   unit    - focused source-path checks and declared xfail rows for open fixes.
%   quick   - short scenario ladder scaffold, extended in the ladder commit.
%   release - release scaffold, extended after fix-specific gates are closed.

p = inputParser;
p.addParameter('Mode','unit',@(x)ischar(x) || isstring(x));
p.addParameter('Focus','all',@(x)ischar(x) || isstring(x));
p.addParameter('WritePdf',false,@(x)islogical(x) || isnumeric(x));
p.addParameter('Scenario','',@(x)ischar(x) || isstring(x));
p.addParameter('Duration',NaN,@isnumeric);
p.parse(varargin{:});

mode = lower(char(p.Results.Mode));
focus = lower(char(p.Results.Focus));
writePdf = logical(p.Results.WritePdf); %#ok<NASGU>
scenario = char(p.Results.Scenario); %#ok<NASGU>
duration_s = double(p.Results.Duration); %#ok<NASGU>

validModes = {'unit','quick','release','runtimeorder'};
assertRequiredFixMetric(any(strcmp(mode, validModes)), 'mode', ...
    sprintf('Unsupported Mode "%s".', mode));

rootDir = fileparts(fileparts(mfilename('fullpath')));
outDir = fullfile(rootDir, 'output', 'RequiredFixValidation_20260722');
if ~exist(outDir, 'dir')
    mkdir(outDir);
end

switch mode
    case 'unit'
        rows = unitRows_(mode, focus);
    case 'quick'
        rows = scaffoldRows_(mode, focus, 'quick_ladder', ...
            'Scenario ladder is scheduled for Commit 8; fix-specific unit gates remain authoritative before then.');
    case 'release'
        rows = scaffoldRows_(mode, focus, 'release_ladder', ...
            'Release battery validation is scheduled for Commit 10 after all physics fixes pass.');
    case 'runtimeorder'
        rows = scaffoldRows_(mode, focus, 'runtime_order', ...
            'Runtime order diagnostic is scheduled for Commit 10 after corrected battery labels and gates exist.');
end

metrics = struct2table(rows);
csvPath = fullfile(outDir, 'metrics.csv');
matPath = fullfile(outDir, 'metrics.mat');
summaryPath = fullfile(outDir, 'summary.md');
writetable(metrics, csvPath);
results = struct('mode',mode,'focus',focus,'outputDir',outDir, ...
    'metrics',metrics,'rows',rows,'csvPath',csvPath, ...
    'matPath',matPath,'summaryPath',summaryPath);
save(matPath, 'metrics', 'results');
writeSummary_(summaryPath, rows, mode, focus);

hasFail = any(strcmp({rows.status}, 'fail'));
if hasFail
    error('run_required_fixes_validation:failed', ...
        'Required-fix validation failed. See %s', summaryPath);
end

fprintf('[required-fixes] mode=%s focus=%s rows=%d -> %s\n', ...
    mode, focus, numel(rows), outDir);
fprintf('[required-fixes] wrote %s\n', csvPath);
fprintf('[required-fixes] wrote %s\n', matPath);
fprintf('[required-fixes] wrote %s\n', summaryPath);
end

function rows = unitRows_(mode, focus)
rows = requiredFixValidationCase( ...
    'ScenarioId','harness_contract', ...
    'Mode',mode, ...
    'Focus',focus, ...
    'Status','pass', ...
    'Message','Validation harness writes metrics.csv, metrics.mat, and summary.md noninteractively.');

rows(end+1) = sourceCheckRow_(mode, focus, 'ionoHO', ...
    '+models/+measurements/CodeMeasurementBuilder.m', ...
    {'ionoHO','higher-order iono'}, ...
    'Commit 2 must prove higher-order ionosphere is carried through L1/L2/IF active code rows.');

rows(end+1) = sourceCheckRow_(mode, focus, 'swarm', ...
    '+revgnss/SwarmRelativeSolver.m', ...
    {'twoWayISL','shapeGateOn'}, ...
    'Commit 3 must gate solved relative shape on enabled two-way ISL observations.');

rows(end+1) = sourceCheckRow_(mode, focus, 'twtt', ...
    '+revgnss/ReverseGNSSSimulation.m', ...
    {'twoWayTimeTransfer','postfit'}, ...
    'Commit 4 must include physical TWTT rows in postfit residual diagnostics.');

rows(end+1) = sourceCheckRow_(mode, focus, 'datastore', ...
    '+data/SimulationDataStore.m', ...
    {'nTowers_','nTowerClockRowsStored'}, ...
    'Commit 5 must preserve physical tower count separately from expanded row storage.');

rows(end+1) = sourceCheckRow_(mode, focus, 'dcb', ...
    '+models/+measurements/CodeMeasurementBuilder.m', ...
    {'dcb','interFrequency'}, ...
    'Commit 6 must inject configured per-signal code DCB into active raw and IF code rows.');

rows(end+1) = sourceCheckRow_(mode, focus, 'labels', ...
    'run_oo_v1.m', ...
    {'twoWayTimeTransfer','TW'}, ...
    'Commit 7 must make run labels reflect active physics rather than diagnostic toggles.');

rows(end+1) = sourceCheckRow_(mode, focus, 'islDocs', ...
    '+models/+measurements/MeasurementModelUtils.m', ...
    {'ISL','not implemented'}, ...
    'Commit 9 must replace stale ISL wording with active-layer routing.');

rows = filterRows_(rows, focus);
end

function row = sourceCheckRow_(mode, focus, fixId, relPath, tokens, openMessage)
rootDir = fileparts(fileparts(mfilename('fullpath')));
path = fullfile(rootDir, relPath);
status = 'xfail';
message = openMessage;
if exist(path, 'file')
    src = fileread(path);
    present = true;
    for k = 1:numel(tokens)
        present = present && contains(src, tokens{k});
    end
    if present && strcmp(fixId, 'labels')
        status = 'pass';
        message = sprintf('Source contains current semantic hooks for %s; dedicated label tests are still required.', fixId);
    elseif present
        message = sprintf('Source contains tokens for %s, but dedicated acceptance remains in its planned commit.', fixId);
    end
else
    status = 'fail';
    message = sprintf('Required source file missing: %s', relPath);
end

row = requiredFixValidationCase( ...
    'ScenarioId',fixId, ...
    'Mode',mode, ...
    'Focus',focus, ...
    'Status',status, ...
    'Message',message);
end

function rows = scaffoldRows_(mode, focus, scenarioId, message)
rows = requiredFixValidationCase( ...
    'ScenarioId',scenarioId, ...
    'Mode',mode, ...
    'Focus',focus, ...
    'Status','xfail', ...
    'Message',message);
rows = filterRows_(rows, focus);
end

function rows = filterRows_(rows, focus)
if strcmp(focus, 'all') || isempty(focus)
    return;
end
keep = strcmpi({rows.scenario_id}, focus) | strcmp({rows.scenario_id}, 'harness_contract');
if ~any(keep)
    rows = requiredFixValidationCase( ...
        'ScenarioId',focus, ...
        'Mode',rows(1).mode, ...
        'Focus',focus, ...
        'Status','xfail', ...
        'Message','No focused validation row exists yet for this planned fix.');
else
    rows = rows(keep);
end
end

function writeSummary_(summaryPath, rows, mode, focus)
fid = fopen(summaryPath, 'w');
if fid < 0
    error('run_required_fixes_validation:summaryOpen', ...
        'Could not open summary for writing: %s', summaryPath);
end
cleanup = onCleanup(@() fclose(fid));
fprintf(fid, '# Required Fix Validation Summary\n\n');
fprintf(fid, '- mode: `%s`\n', mode);
fprintf(fid, '- focus: `%s`\n', focus);
fprintf(fid, '- generated: `%s`\n\n', datestr(now, 31));
statuses = {rows.status};
fprintf(fid, '- pass: %d\n', sum(strcmp(statuses, 'pass')));
fprintf(fid, '- xfail: %d\n', sum(strcmp(statuses, 'xfail')));
fprintf(fid, '- fail: %d\n\n', sum(strcmp(statuses, 'fail')));
fprintf(fid, '| scenario_id | status | message |\n');
fprintf(fid, '| --- | --- | --- |\n');
for k = 1:numel(rows)
    fprintf(fid, '| %s | %s | %s |\n', rows(k).scenario_id, rows(k).status, rows(k).message);
end
end
