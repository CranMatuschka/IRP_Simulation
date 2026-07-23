function results = run_required_fixes_validation(varargin)
% run_required_fixes_validation  Noninteractive required-fix validation harness.
%
% Modes:
%   unit    - focused source-path checks and declared xfail rows for open fixes.
%   quick   - short scenario ladder scaffold, extended in the ladder commit.
%   release - corrected non-PDF battery evidence plus all fix gates.
%   runtimeOrder - reversed-order TW0/TW1 runtime evidence for one scenario.

p = inputParser;
p.addParameter('Mode','unit',@(x)ischar(x) || isstring(x));
p.addParameter('Focus','all',@(x)ischar(x) || isstring(x));
p.addParameter('WritePdf',false,@(x)islogical(x) || isnumeric(x));
p.addParameter('Scenario','',@(x)ischar(x) || isstring(x));
p.addParameter('Duration',NaN,@isnumeric);
p.parse(varargin{:});

mode = lower(char(p.Results.Mode));
focus = lower(char(p.Results.Focus));
writePdf = logical(p.Results.WritePdf);
scenario = char(p.Results.Scenario);
duration_s = double(p.Results.Duration);

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
        rows = releaseRows_(mode, focus, writePdf, duration_s, outDir);
    case 'runtimeorder'
        rows = runtimeOrderRows_(mode, focus, scenario, duration_s, writePdf, outDir);
end

metrics = struct2table(rows);
csvPath = fullfile(outDir, 'metrics.csv');
matPath = fullfile(outDir, 'metrics.mat');
summaryPath = fullfile(outDir, 'summary.md');
tag = validationFileTag_(mode, focus);
modeCsvPath = fullfile(outDir, sprintf('metrics_%s.csv', tag));
modeMatPath = fullfile(outDir, sprintf('metrics_%s.mat', tag));
modeSummaryPath = fullfile(outDir, sprintf('summary_%s.md', tag));
writetable(metrics, csvPath);
writetable(metrics, modeCsvPath);
results = struct('mode',mode,'focus',focus,'outputDir',outDir, ...
    'metrics',metrics,'rows',rows,'csvPath',csvPath, ...
    'matPath',matPath,'summaryPath',summaryPath, ...
    'modeCsvPath',modeCsvPath,'modeMatPath',modeMatPath, ...
    'modeSummaryPath',modeSummaryPath);
save(matPath, 'metrics', 'results');
save(modeMatPath, 'metrics', 'results');
writeSummary_(summaryPath, rows, mode, focus);
writeSummary_(modeSummaryPath, rows, mode, focus);

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
fprintf('[required-fixes] wrote %s\n', modeCsvPath);
fprintf('[required-fixes] wrote %s\n', modeMatPath);
fprintf('[required-fixes] wrote %s\n', modeSummaryPath);
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

rows(end+1) = executableTestRow_(mode, focus, 'islDocs', ...
    {'tests/test_isl_documentation_consistency.m'}, ...
    'Legacy ISL helper wording routes users to the active ISL builders and relative solver.');

rows = filterRows_(rows, focus);
end

function rows = releaseRows_(mode, focus, writePdf, duration_s, outDir)
numericDuration_s = defaultDuration_(duration_s, 120);
semanticDuration_s = defaultDuration_(duration_s, 7200);

rows = requiredFixValidationCase( ...
    'ScenarioId','release_contract', ...
    'Mode',mode, ...
    'Focus',focus, ...
    'Status','pass', ...
    'Duration_s',numericDuration_s, ...
    'ReleaseEvidenceLevel','unit+quick+short-numerical+full-semantic', ...
    'Message',['Release mode runs all fix gates, the quick ladder, short numerical ' ...
               'baseline/realism battery rows, and a full-topology semantic dry-run manifest.']);

rows = [rows, unitRows_(mode, focus)];
rows = [rows, requiredFixQuickScenarioRows(mode, focus, min(numericDuration_s, 60))];
rows = [rows, releaseSemanticManifestRows_(mode, focus, semanticDuration_s, outDir)];
rows = [rows, releaseNumericBatteryRows_(mode, focus, writePdf, numericDuration_s, outDir)];
rows = filterRows_(rows, focus);
end

function rows = releaseSemanticManifestRows_(mode, focus, duration_s, outDir)
topologies = {[1 1],[1 4],[3 4],[6 4]};
outRoot = fullfile(outDir, 'release_semantic_manifest');
cases = { ...
    struct('id','release_manifest_Battery_baseline','realism',false,'atmosphere','realistic','runClass','baseline','group','Battery_baseline'), ...
    struct('id','release_manifest_Battery_idealised','realism',false,'atmosphere','matched','runClass','idealised','group','Battery_idealised'), ...
    struct('id','release_manifest_Battery_realism','realism',true,'atmosphere','realistic','runClass','realism','group','Battery_realism')};

rows = repmat(requiredFixValidationCase('ScenarioId','release_manifest_seed', ...
    'Mode',mode,'Focus',focus,'Status','pass'), 1, 0);
for k = 1:numel(cases)
    c = cases{k};
    t0 = tic;
    try
        manifest = run_oo_v1_battery('Duration', duration_s, 'Towers', 5, ...
            'SR', topologies, 'TW', [0 1], 'Realism', c.realism, ...
            'Atmosphere', c.atmosphere, 'WritePdf', false, 'Analyze', false, ...
            'OutRoot', outRoot, 'DryRun', true);
        assert(numel(manifest) == 8, ...
            'Expected 8 dry-run rows for %s, got %d.', c.group, numel(manifest));
        assert(all([manifest.ok]), 'Dry-run manifest rows must all be ok for %s.', c.group);
        assert(all(strcmp({manifest.runClass}, c.runClass)), ...
            'runClass mismatch for %s.', c.group);
        assert(all(strcmp({manifest.groupName}, c.group)), ...
            'groupName mismatch for %s.', c.group);
        assert(all(strcmp({manifest.atmosphereMode}, c.atmosphere)), ...
            'atmosphereMode mismatch for %s.', c.group);
        msg = sprintf('%s full-topology semantic dry-run emitted %d rows; labels are corrected but no numerical simulation is claimed.', ...
            c.group, numel(manifest));
        status = 'pass';
    catch ex
        manifest = struct('G',NaN,'S',NaN,'R',NaN); %#ok<NASGU>
        msg = ex.message;
        status = 'fail';
    end
    rows(end+1) = requiredFixValidationCase( ... %#ok<AGROW>
        'ScenarioId',c.id, ...
        'Mode',mode, ...
        'Focus',focus, ...
        'Status',status, ...
        'Duration_s',duration_s, ...
        'NTowers',5, ...
        'NAssets',NaN, ...
        'ActiveMeasurementTypes','battery manifest semantics only', ...
        'Wall_s',toc(t0), ...
        'ReportWall_s',0, ...
        'RunOrder','full topology dry-run', ...
        'GroupName',c.group, ...
        'ReleaseEvidenceLevel','full-topology-dry-run-manifest', ...
        'Message',msg);
end
end

function rows = releaseNumericBatteryRows_(mode, focus, writePdf, duration_s, outDir)
outRoot = fullfile(outDir, 'release_numeric');
cases = { ...
    struct('idPrefix','release_numeric_Battery_baseline','realism',false,'atmosphere','realistic','evidence','short-numerical-baseline'), ...
    struct('idPrefix','release_numeric_Battery_realism','realism',true,'atmosphere','realistic','evidence','short-numerical-realism')};
rows = repmat(requiredFixValidationCase('ScenarioId','release_numeric_seed', ...
    'Mode',mode,'Focus',focus,'Status','pass'), 1, 0);
for k = 1:numel(cases)
    c = cases{k};
    try
        manifest = run_oo_v1_battery('Duration', duration_s, 'Towers', 5, ...
            'SR', {[1 1]}, 'TW', [0 1], 'Realism', c.realism, ...
            'Atmosphere', c.atmosphere, 'WritePdf', writePdf, ...
            'Analyze', false, 'OutRoot', outRoot);
        for mi = 1:numel(manifest)
            rows(end+1) = manifestMetricRow_(manifest(mi), mode, focus, ... %#ok<AGROW>
                sprintf('%s_%s', c.idPrefix, manifest(mi).tag), ...
                c.evidence, '', writePdf);
        end
    catch ex
        rows(end+1) = requiredFixValidationCase( ... %#ok<AGROW>
            'ScenarioId',c.idPrefix, ...
            'Mode',mode, ...
            'Focus',focus, ...
            'Status','fail', ...
            'Duration_s',duration_s, ...
            'ReleaseEvidenceLevel',c.evidence, ...
            'Message',ex.message);
    end
end
end

function rows = runtimeOrderRows_(mode, focus, scenario, duration_s, writePdf, outDir)
if isempty(scenario)
    scenario = 'G5S3R4';
end
assertRequiredFixMetric(strcmpi(scenario, 'G5S3R4'), 'runtimeOrderScenario', ...
    'runtimeOrder currently supports Scenario=''G5S3R4'', matching the required-fix plan.');
duration_s = defaultDuration_(duration_s, 300);

rows = requiredFixValidationCase( ...
    'ScenarioId','runtime_order_contract', ...
    'Mode',mode, ...
    'Focus',focus, ...
    'Status','pass', ...
    'Duration_s',duration_s, ...
    'NTowers',5, ...
    'NAssets',3, ...
    'RunOrder','TW0 -> TW1 and TW1 -> TW0', ...
    'ReleaseEvidenceLevel','reversed-order-runtime', ...
    'Message',['Runs G5S3R4 twice in each TW order. With WritePdf=false, ' ...
               'wall_s is simulation plus MAT overhead and report_wall_s is zero by construction.']);

orders = { ...
    struct('id','A_TW0_TW1','tw',[0 1],'label','TW0 -> TW1'), ...
    struct('id','B_TW1_TW0','tw',[1 0],'label','TW1 -> TW0')};
for k = 1:numel(orders)
    ord = orders{k};
    outRoot = fullfile(outDir, 'runtime_order', ord.id);
    try
        manifest = run_oo_v1_battery('Duration', duration_s, 'Towers', 5, ...
            'SR', {[3 4]}, 'TW', ord.tw, 'Realism', false, ...
            'Atmosphere', 'realistic', 'WritePdf', writePdf, ...
            'Analyze', false, 'OutRoot', outRoot);
        for mi = 1:numel(manifest)
            rows(end+1) = manifestMetricRow_(manifest(mi), mode, focus, ... %#ok<AGROW>
                sprintf('runtime_%s_%s', ord.id, manifest(mi).tag), ...
                'reversed-order-runtime', ord.label, writePdf);
        end
    catch ex
        rows(end+1) = requiredFixValidationCase( ... %#ok<AGROW>
            'ScenarioId',sprintf('runtime_%s_failed', ord.id), ...
            'Mode',mode, ...
            'Focus',focus, ...
            'Status','fail', ...
            'Duration_s',duration_s, ...
            'NTowers',5, ...
            'NAssets',3, ...
            'RunOrder',ord.label, ...
            'ReleaseEvidenceLevel','reversed-order-runtime', ...
            'Message',ex.message);
    end
end
rows(end+1) = runtimeComparisonRow_(rows, mode, focus, duration_s);
rows = filterRows_(rows, focus);
end

function row = manifestMetricRow_(m, mode, focus, scenarioId, evidenceLevel, runOrder, writePdf)
status = 'pass';
if ~isfield(m, 'ok') || ~m.ok
    status = 'fail';
end
matPath = '';
if isfield(m, 'matPath'); matPath = m.matPath; end
if isempty(matPath) || ~isfile(matPath)
    status = 'fail';
end

ev = inspectMatEvidence_(matPath, m, writePdf);
msg = sprintf('%s %s: wall %.2f s, rows %s, epochs %s.', ...
    evidenceLevel, safeChar_(m, 'tag', scenarioId), scalarOrNan_(m.wall_s), ...
    ev.measurementRows, num2str(ev.epochCount));
if isfield(m, 'msg') && ~isempty(m.msg)
    msg = sprintf('%s message=%s', msg, m.msg);
end
if strcmp(status, 'fail') && isempty(matPath)
    msg = sprintf('%s MAT path missing.', evidenceLevel);
end

reportWall_s = 0;
pdfPath = ev.pdfPath;
if writePdf
    reportWall_s = NaN;
    if isempty(pdfPath) && ~isempty(matPath)
        pdfPath = regexprep(matPath, '\.mat$', '.pdf');
    end
end

twTag = sprintf('TW%d', safeScalar_(m, 'TW', NaN));
row = requiredFixValidationCase( ...
    'ScenarioId',scenarioId, ...
    'Mode',mode, ...
    'Focus',focus, ...
    'Status',status, ...
    'Duration_s',ev.duration_s, ...
    'NTowers',safeScalar_(m, 'G', ev.nTowers), ...
    'NAssets',safeScalar_(m, 'S', ev.nAssets), ...
    'PhysicalTowerCountDatastore',ev.physicalTowerCount, ...
    'ActiveMeasurementTypes',ev.activeTypes, ...
    'CodeRowCountBySignal',ev.codeRowsBySignal, ...
    'TwttRowCount',ev.twttRows, ...
    'PostfitResidualCountByType',ev.postfitCounts, ...
    'MeanNisByType',ev.meanNisByType, ...
    'NEES',ev.nees, ...
    'PositionRMS_m',ev.positionRms_m, ...
    'ClockRMS_m',ev.clockRms_m, ...
    'RelativeShapeRawRMS_m',ev.relShapeRaw_m, ...
    'RelativeShapeSolvedRMS_m',ev.relShapeSolved_m, ...
    'SwarmGateFlags',ev.swarmGateFlags, ...
    'RunOrder',runOrder, ...
    'TwTag',twTag, ...
    'Wall_s',safeScalar_(m, 'wall_s', NaN), ...
    'ReportWall_s',reportWall_s, ...
    'EpochCount',ev.epochCount, ...
    'MeasurementRowCountByType',ev.measurementRows, ...
    'EkfUpdateDimensionByEpoch',ev.ekfDimension, ...
    'AcceptedUpdateCount',ev.acceptedUpdates, ...
    'RejectedUpdateCount',ev.rejectedUpdates, ...
    'WarningCount',ev.warningCount, ...
    'MatlabOrderNote',orderNote_(runOrder, twTag, writePdf), ...
    'GroupName',safeChar_(m, 'groupName', ''), ...
    'MatPath',matPath, ...
    'PdfPath',pdfPath, ...
    'ReleaseEvidenceLevel',evidenceLevel, ...
    'Message',msg);
end

function ev = inspectMatEvidence_(matPath, manifestRow, writePdf)
ev = emptyEvidence_();
ev.nTowers = safeScalar_(manifestRow, 'G', NaN);
ev.nAssets = safeScalar_(manifestRow, 'S', NaN);
ev.duration_s = NaN;
ev.physicalTowerCount = ev.nTowers;
if isempty(matPath) || ~isfile(matPath)
    return;
end

try
    available = who('-file', matPath);
    wanted = {'cfg', 'summary', 'diagnostics', 'results', 'rel', 'pdfPath'};
    present = intersect(wanted, available, 'stable');
    S = load(matPath, present{:});
catch ex
    ev.measurementRows = sprintf('MAT load failed: %s', ex.message);
    return;
end

if isfield(S, 'cfg')
    ev.duration_s = safeCfgScalar_(S.cfg, {'simulation','duration_s'}, ev.duration_s);
    ev.nTowers = safeCfgScalar_(S.cfg, {'scenario','nTowers'}, ev.nTowers);
    ev.nAssets = safeCfgScalar_(S.cfg, {'scenario','nSpaceAssets'}, ev.nAssets);
    ev.physicalTowerCount = ev.nTowers;
    counts = configRowCounts_(S.cfg);
    ev.measurementRows = counts.summary;
    ev.activeTypes = counts.activeTypes;
    ev.codeRowsBySignal = counts.codeRowsBySignal;
    ev.twttRows = counts.twttRows;
    ev.ekfDimension = counts.ekfDimension;
end
if isfield(S, 'pdfPath') && ischar(S.pdfPath)
    ev.pdfPath = S.pdfPath;
elseif writePdf && ~isempty(matPath)
    ev.pdfPath = regexprep(matPath, '\.mat$', '.pdf');
end

if isfield(S, 'diagnostics')
    ev = inspectSingleAssetDiagnostics_(ev, S);
elseif isfield(S, 'results')
    ev = inspectFederatedResults_(ev, S);
end

if isfield(S, 'summary') && isstruct(S.summary)
    ev = mergeSummaryEvidence_(ev, S.summary);
end
end

function ev = inspectSingleAssetDiagnostics_(ev, S)
try
    d = S.diagnostics.getData();
    if isfield(d, 'time_s')
        ev.epochCount = numel(d.time_s);
    elseif isfield(d, 't_s')
        ev.epochCount = numel(d.t_s);
    end
    if isfield(d, 'towerClock') && isfield(d.towerClock, 'nPhysicalTowers')
        ev.physicalTowerCount = d.towerClock.nPhysicalTowers;
    end
    if isfield(d, 'meas')
        ev.measurementRows = sprintf('code=%g,doppler=%g,carrier=%g,twtt=%g,total=%g; source=datastore-max', ...
            maxOrNan_(d.meas.nCodeRows), maxOrNan_(d.meas.nDopplerRows), ...
            maxOrNan_(d.meas.nCarrierRows), maxOrNan_(d.meas.nTwoWayTimeTransferRows), ...
            maxOrNan_(d.meas.nRows));
        ev.codeRowsBySignal = sprintf('active code rows max=%g; signal split from summary/config', ...
            maxOrNan_(d.meas.nCodeRows));
        ev.twttRows = maxOrNan_(d.meas.nTwoWayTimeTransferRows);
        ev.ekfDimension = sprintf('max=%g,median=%.3g; source=datastore nRows', ...
            maxOrNan_(d.meas.nRows), median(double(d.meas.nRows(:)), 'omitnan'));
    end
    if isfield(d, 'consistency')
        nis = d.consistency.NIS(:);
        ev.acceptedUpdates = sum(isfinite(nis));
        ev.rejectedUpdates = sum(~isfinite(nis));
        ev.meanNisByType = sprintf('code=%.3g,doppler=%.3g,carrier=%.3g,twtt=%.3g', ...
            meanField_(d.consistency, 'NIS_code'), meanField_(d.consistency, 'NIS_doppler'), ...
            meanField_(d.consistency, 'NIS_carrier'), meanField_(d.consistency, 'NIS_twoWayTimeTransfer'));
        ev.nees = meanField_(d.consistency, 'NEES_pos');
    end
    if isfield(d, 'error')
        ev.positionRms_m = rmsFinite_(d.error.positionNorm_m);
        ev.clockRms_m = rmsFinite_(d.error.clockBias_m);
    end
    if isfield(d, 'residual')
        ev.postfitCounts = sprintf('postfitRMS code=%.3g,doppler=%.3g,carrier=%.3g,twtt=%.3g', ...
            meanField_(d.residual, 'postfitCodeRMS_m'), meanField_(d.residual, 'postfitDopplerRMS_mps'), ...
            meanField_(d.residual, 'postfitCarrierRMS_m'), meanField_(d.residual, 'postfitTwoWayTimeTransferRMS_m'));
    end
catch ex
    ev.postfitCounts = sprintf('single-asset datastore unavailable: %s', ex.message);
end
end

function ev = inspectFederatedResults_(ev, S)
try
    nEp = 0;
    nAccepted = 0;
    nRejected = 0;
    posVals = [];
    for ai = 1:numel(S.results.asset)
        a = S.results.asset{ai};
        if isfield(a, 'history') && isfield(a.history, 'time_s')
            nEp = max(nEp, numel(a.history.time_s));
        end
        if isfield(a, 'history') && isfield(a.history, 'NIS')
            nis = a.history.NIS(:);
            nAccepted = nAccepted + sum(isfinite(nis));
            nRejected = nRejected + sum(~isfinite(nis));
        end
        if isfield(a, 'history') && isfield(a.history, 'posErrNorm_m')
            posVals = [posVals; a.history.posErrNorm_m(:)]; %#ok<AGROW>
        end
    end
    ev.epochCount = nEp;
    ev.acceptedUpdates = nAccepted;
    ev.rejectedUpdates = nRejected;
    ev.positionRms_m = rmsFinite_(posVals);
    ev.postfitCounts = 'federated MAT saves per-asset EKF histories, not full postfit residual vectors';
catch ex
    ev.postfitCounts = sprintf('federated history unavailable: %s', ex.message);
end

if isfield(S, 'rel') && isstruct(S.rel)
    ev.relShapeRaw_m = safeStructScalar_(S.rel, 'shapeErrRaw_m', NaN);
    ev.relShapeSolved_m = safeStructScalar_(S.rel, 'shapeErrSolved_m', NaN);
    ev.swarmGateFlags = sprintf('shapeGate=%d,relClockGate=%d,source=%s', ...
        double(safeStructLogical_(S.rel, 'shapeGateOn', false)), ...
        double(safeStructLogical_(S.rel, 'relClockGateOn', false)), ...
        safeStructChar_(S.rel, 'shapeObservationSource', 'unknown'));
end
end

function ev = mergeSummaryEvidence_(ev, summary)
if isfield(summary, 'validationWarnings') && iscell(summary.validationWarnings)
    ev.warningCount = numel(summary.validationWarnings);
end
if isfield(summary, 'finalPositionRMS_m') && isfinite(summary.finalPositionRMS_m)
    ev.positionRms_m = summary.finalPositionRMS_m;
end
if isfield(summary, 'finalClockBiasRMS_m') && isfinite(summary.finalClockBiasRMS_m)
    ev.clockRms_m = summary.finalClockBiasRMS_m;
end
if isfield(summary, 'meanNIS') && isempty(ev.meanNisByType)
    ev.meanNisByType = sprintf('all=%.3g,expected=%.3g', ...
        safeStructScalar_(summary, 'meanNIS', NaN), safeStructScalar_(summary, 'expectedNIS', NaN));
end
if isfield(summary, 'formation') && isstruct(summary.formation)
    ev.relShapeSolved_m = safeStructScalar_(summary.formation, 'shapeErr_m', ev.relShapeSolved_m);
    ev.swarmGateFlags = sprintf('%s; relClockGate=%d', ev.swarmGateFlags, ...
        double(safeStructLogical_(summary.formation, 'relClockGateOn', false)));
end
end

function row = runtimeComparisonRow_(rows, mode, focus, duration_s)
rtRows = rows(startsWith({rows.scenario_id}, 'runtime_') & strcmp({rows.status}, 'pass') & ...
    ~strcmp({rows.scenario_id}, 'runtime_order_contract'));
tw0 = rtRows(strcmp({rtRows.tw_tag}, 'TW0'));
tw1 = rtRows(strcmp({rtRows.tw_tag}, 'TW1'));
status = 'pass';
if numel(tw0) < 2 || numel(tw1) < 2
    status = 'fail';
    msg = 'Runtime-order comparison requires two TW0 and two TW1 rows.';
else
    meanTw0 = mean([tw0.wall_s], 'omitnan');
    meanTw1 = mean([tw1.wall_s], 'omitnan');
    deltaPct = 100 * (meanTw1 - meanTw0) / max(meanTw0, eps);
    msg = sprintf(['mean TW0 %.2f s, mean TW1 %.2f s, delta %.1f%%. ' ...
        'Do not infer TW1 is physically cheaper from a single order; compare both orders with row counts and PDF disabled.'], ...
        meanTw0, meanTw1, deltaPct);
end
row = requiredFixValidationCase( ...
    'ScenarioId','runtime_order_interpretation', ...
    'Mode',mode, ...
    'Focus',focus, ...
    'Status',status, ...
    'Duration_s',duration_s, ...
    'NTowers',5, ...
    'NAssets',3, ...
    'RunOrder','TW0 -> TW1 and TW1 -> TW0', ...
    'ReleaseEvidenceLevel','runtime-order-interpretation', ...
    'Message',msg);
end

function ev = emptyEvidence_()
ev = struct( ...
    'duration_s',NaN, ...
    'nTowers',NaN, ...
    'nAssets',NaN, ...
    'physicalTowerCount',NaN, ...
    'activeTypes','', ...
    'codeRowsBySignal','', ...
    'twttRows',NaN, ...
    'postfitCounts','', ...
    'meanNisByType','', ...
    'nees',NaN, ...
    'positionRms_m',NaN, ...
    'clockRms_m',NaN, ...
    'relShapeRaw_m',NaN, ...
    'relShapeSolved_m',NaN, ...
    'swarmGateFlags','', ...
    'wall_s',NaN, ...
    'epochCount',NaN, ...
    'measurementRows','', ...
    'ekfDimension','', ...
    'acceptedUpdates',NaN, ...
    'rejectedUpdates',NaN, ...
    'warningCount',0, ...
    'pdfPath','');
end

function counts = configRowCounts_(cfg)
nT = safeCfgScalar_(cfg, {'scenario','nTowers'}, NaN);
nR = safeCfgScalar_(cfg, {'scenario','nReceivers'}, NaN);
nS = safeCfgScalar_(cfg, {'scenario','nSpaceAssets'}, 1);
nSig = numEnabledSignals_(cfg);
codeMode = safeCfgChar_(cfg, {'measurements','codeMode'}, 'singleFrequency');
if strcmpi(codeMode, 'ionosphereFree')
    nCode = nT * nR;
    codeBySignal = sprintf('IF=%g from L1/L2', nCode);
else
    nCode = nT * nR * nSig;
    codeBySignal = sprintf('%d signals x G%d x R%d = %g', nSig, round(nT), round(nR), nCode);
end

nDoppler = nT * nR * double(safeCfgBool_(cfg, {'measurements','doppler','useInEKF'}, false));
try
    nCarrierSignals = revgnss.SignalCatalog.nCarrierSignals(cfg);
catch
    nCarrierSignals = nSig;
end
nCarrier = nT * nR * nCarrierSignals * double(strcmpi(safeCfgChar_(cfg, {'measurements','carrierMode'}, 'off'), 'ekfFloat'));
nTwtt = twoWayTimeTransferRows_(cfg, nT);

nSec = max(0, nS - 1);
islOn = safeCfgBool_(cfg, {'measurements','isl','enable'}, false);
nIslCode = nSec * double(islOn && safeCfgBool_(cfg, {'measurements','isl','code','useInEKF'}, false));
nIslDoppler = nSec * double(islOn && safeCfgBool_(cfg, {'measurements','isl','doppler','useInEKF'}, false));
nIslTwoWay = double(islOn && safeCfgBool_(cfg, {'measurements','isl','twoWay','range','useInEKF'}, false));
nTotal = nCode + nDoppler + nCarrier + nTwtt + nIslCode + nIslDoppler + nIslTwoWay;

parts = {};
if nCode > 0; parts{end+1} = 'code'; end
if nDoppler > 0; parts{end+1} = 'doppler'; end
if nCarrier > 0; parts{end+1} = 'carrier'; end
if nTwtt > 0; parts{end+1} = 'twoWayTimeTransfer'; end
if nIslCode > 0; parts{end+1} = 'islCode'; end
if nIslDoppler > 0; parts{end+1} = 'islDoppler'; end
if nIslTwoWay > 0; parts{end+1} = 'islTwoWayRange'; end
if isempty(parts); parts = {'none'}; end

counts = struct();
counts.twttRows = nTwtt;
counts.codeRowsBySignal = codeBySignal;
counts.activeTypes = strjoin(parts, '+');
counts.summary = sprintf('code=%g,doppler=%g,carrier=%g,twtt=%g,islCode=%g,islDoppler=%g,islTwoWay=%g,total=%g; source=config-derived', ...
    nCode, nDoppler, nCarrier, nTwtt, nIslCode, nIslDoppler, nIslTwoWay, nTotal);
counts.ekfDimension = sprintf('nominal per-asset rows=%g; source=config-derived', nTotal);
end

function n = twoWayTimeTransferRows_(cfg, nT)
enabled = safeCfgBool_(cfg, {'measurements','twoWayTimeTransfer','enable'}, false) && ...
    safeCfgBool_(cfg, {'measurements','twoWayTimeTransfer','useInEKF'}, false);
if ~enabled
    n = 0;
    return;
end
towers = 'all';
try
    towers = cfg.measurements.twoWayTimeTransfer.towers;
catch
end
if ischar(towers) || isstring(towers)
    if strcmpi(char(towers), 'all')
        n = nT;
    else
        n = 0;
    end
else
    n = numel(towers);
end
end

function n = numEnabledSignals_(cfg)
n = 1;
try
    if isfield(cfg, 'signals') && isfield(cfg.signals, 'enabledMask')
        mask = logical(cfg.signals.enabledMask(:));
        n = nnz(mask);
        if n > 0
            return;
        end
    end
    sig = cfg.signals.enabled;
    if iscell(sig)
        n = numel(sig);
    elseif isstring(sig)
        n = numel(sig);
    elseif ischar(sig)
        names = regexp(sig, 'L[0-9]+', 'match');
        n = max(1, numel(names));
    end
catch
end
end

function d = defaultDuration_(duration_s, default_s)
if ~isfinite(duration_s) || duration_s <= 0
    d = default_s;
else
    d = duration_s;
end
end

function note = orderNote_(runOrder, twTag, writePdf)
if isempty(runOrder)
    note = '';
    return;
end
if writePdf
    pdfNote = 'PDF requested, total wall includes report generation because ReportRunner has no split timer.';
else
    pdfNote = 'PDF disabled, report_wall_s=0; wall_s is simulation plus MAT output in this MATLAB process.';
end
note = sprintf('%s, %s. %s', runOrder, twTag, pdfNote);
end

function v = safeCfgScalar_(cfg, path, defaultValue)
v = defaultValue;
try
    x = cfg;
    for k = 1:numel(path)
        x = x.(path{k});
    end
    if isnumeric(x) && isscalar(x)
        v = double(x);
    end
catch
end
end

function v = safeCfgBool_(cfg, path, defaultValue)
v = defaultValue;
try
    x = cfg;
    for k = 1:numel(path)
        x = x.(path{k});
    end
    v = logical(x);
catch
end
end

function v = safeCfgChar_(cfg, path, defaultValue)
v = defaultValue;
try
    x = cfg;
    for k = 1:numel(path)
        x = x.(path{k});
    end
    if ischar(x) || isstring(x)
        v = char(x);
    end
catch
end
end

function v = safeScalar_(s, fieldName, defaultValue)
v = defaultValue;
try
    if isfield(s, fieldName) && isnumeric(s.(fieldName)) && isscalar(s.(fieldName))
        v = double(s.(fieldName));
    end
catch
end
end

function v = safeChar_(s, fieldName, defaultValue)
v = defaultValue;
try
    if isfield(s, fieldName) && (ischar(s.(fieldName)) || isstring(s.(fieldName)))
        v = char(s.(fieldName));
    end
catch
end
end

function v = safeStructScalar_(s, fieldName, defaultValue)
v = defaultValue;
try
    if isfield(s, fieldName) && isnumeric(s.(fieldName)) && isscalar(s.(fieldName))
        v = double(s.(fieldName));
    end
catch
end
end

function v = safeStructLogical_(s, fieldName, defaultValue)
v = defaultValue;
try
    if isfield(s, fieldName)
        v = logical(s.(fieldName));
    end
catch
end
end

function v = safeStructChar_(s, fieldName, defaultValue)
v = defaultValue;
try
    if isfield(s, fieldName) && (ischar(s.(fieldName)) || isstring(s.(fieldName)))
        v = char(s.(fieldName));
    end
catch
end
end

function v = maxOrNan_(x)
if isempty(x)
    v = NaN;
else
    v = max(double(x(:)), [], 'omitnan');
end
end

function v = meanField_(s, fieldName)
v = NaN;
try
    x = s.(fieldName);
    x = double(x(:));
    v = mean(x(isfinite(x)), 'omitnan');
catch
end
end

function v = rmsFinite_(x)
v = NaN;
try
    x = double(x(:));
    x = x(isfinite(x));
    if ~isempty(x)
        v = sqrt(mean(x.^2));
    end
catch
end
end

function v = scalarOrNan_(x)
if isempty(x)
    v = NaN;
else
    v = double(x(1));
end
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

function tag = validationFileTag_(mode, focus)
tag = lower(sprintf('%s_%s', char(mode), char(focus)));
tag = regexprep(tag, '[^a-z0-9_-]+', '_');
tag = regexprep(tag, '_+', '_');
tag = regexprep(tag, '^_|_$', '');
if isempty(tag)
    tag = 'validation';
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
