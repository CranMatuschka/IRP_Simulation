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
        rows = requiredFixQuickScenarioRows(mode, focus, duration_s);
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

rows(end+1) = executableTestRow_(mode, focus, 'ionoHO', ...
    {'tests/test_iono_higher_order.m','tests/test_code_iono_higher_order_multisignal.m'}, ...
    'Higher-order ionosphere is carried through L1/L2/IF active code rows.');

rows(end+1) = executableTestRow_(mode, focus, 'swarm', ...
    {'tests/test_swarm_two_way_isl_gating.m'}, ...
    'Swarm solved-shape metrics are gated by multiAsset.twoWayISL.enable.');

rows(end+1) = executableTestRow_(mode, focus, 'twtt', ...
    {'tests/test_wpA_two_way_time_transfer.m','tests/test_two_way_time_transfer_postfit.m'}, ...
    'Two-way time-transfer physical rows are included in postfit residuals and per-type NIS.');

rows(end+1) = executableTestRow_(mode, focus, 'datastore', ...
    {'tests/test_datastore_physical_tower_count.m'}, ...
    'Datastore preserves physical tower count separately from expanded tower-clock rows.');

rows(end+1) = executableTestRow_(mode, focus, 'dcb', ...
    {'tests/test_code_dcb_active_path.m'}, ...
    'Configured per-signal code DCB reaches active raw and IF code rows without stochastic R inflation.');

rows(end+1) = executableTestRow_(mode, focus, 'labels', ...
    {'tests/test_battery_label_semantics.m','tests/test_run_name_tw_semantics.m'}, ...
    'Battery labels and TW tags reflect active atmosphere, realism, and TWTT EKF physics.');

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

function row = executableTestRow_(mode, focus, fixId, relPaths, passMessage)
if ~(strcmp(focus, 'all') || strcmpi(focus, fixId))
    row = requiredFixValidationCase( ...
        'ScenarioId',fixId, ...
        'Mode',mode, ...
        'Focus',focus, ...
        'Status','xfail', ...
        'Message',sprintf('Commit for %s is not the active focus in this run.', fixId));
    return
end

rootDir = fileparts(fileparts(mfilename('fullpath')));
try
    for k = 1:numel(relPaths)
        run(fullfile(rootDir, relPaths{k}));
    end
    row = requiredFixValidationCase( ...
        'ScenarioId',fixId, ...
        'Mode',mode, ...
        'Focus',focus, ...
        'Status','pass', ...
        'DcbActiveFlag',strcmpi(fixId,'dcb'), ...
        'HigherOrderIonoActiveFlag',strcmpi(fixId,'ionoHO'), ...
        'Message',passMessage);
catch ex
    row = requiredFixValidationCase( ...
        'ScenarioId',fixId, ...
        'Mode',mode, ...
        'Focus',focus, ...
        'Status','fail', ...
        'DcbActiveFlag',false, ...
        'HigherOrderIonoActiveFlag',false, ...
        'Message',ex.message);
end
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
