function test_joint_summary_pdf()
% The compact joint summary remains available when explicitly selected.

reportFolder = tempname(tempdir);
mkdir(reportFolder);
cleanup = onCleanup(@() cleanup_(reportFolder)); %#ok<NASGU>

cfg = resolveSimulationConfig( ...
    'joint_G5S6R4_coherent_two_way_code.json');
cfg.simulation.duration_s = 1;
cfg.simulation.dt_s = 1;
cfg.report.reportFolder = reportFolder;
cfg.report.stem = 'joint-summary-smoke';
cfg.report.layout = 'jointSummary';
cfg.report.writePdf = true;
cfg.report.writeMat = false;
cfg.report.overwrite = true;
cfg.plots.enable = false;

out = revgnss.ReportRunner.runSingle(cfg);
assert(strcmp(out.cfg.report.layout,'jointSummary'));
assert(strcmp(out.summary.reportLayoutResolved,'jointSummary'));
schedule = out.summary.coherentTwoWayCodeSchedule;
links = revgnss.TwoWayISLMeasurementBuilder.linkDefinitions(out.cfg);
expectedEndpoints = [[links.initiatorAssetIndex].' ...
    [links.transponderAssetIndex].'];
assert(schedule.linkCount == 6);
assert(isequal(schedule.endpoints,expectedEndpoints));
assert(strcmp(schedule.topology,'connectedRing'));
assert(isequal(schedule.phases_s,[0,5]));
assert(isequal(schedule.activeLinkCountByPhase,[3,3]));
assert(all(schedule.terminalDisjointByPhase));
assert(schedule.uniformActiveLinkCount);
assert(exist(out.pdfPath,'file') == 2);
assert(dir(out.pdfPath).bytes > 0);
assert(isempty(out.texPath));

summaryFigure = findobj(0,'Type','figure', ...
    'Name','00 — Joint Estimator Summary');
comparisonFigure = findobj(0,'Type','figure', ...
    'Name','01 — Joint State Truth Comparison');
assert(isscalar(summaryFigure) && isscalar(comparisonFigure));
assert(numel(findall(comparisonFigure,'Type','line')) >= ...
    3*out.summary.nEstimatedAssets, ...
    'The joint report did not plot all assets in each state panel.');
summaryText = figureText_(summaryFigure);
assert(contains(summaryText,'configured coherent links: 6'));
assert(contains(summaryText,'connected ring over 6 spacecraft'));
assert(contains(summaryText, ...
    'each scheduled epoch activates 3 terminal-disjoint links'));
assert(contains(summaryText,'phase 0 s:'));
assert(contains(summaryText,'phase 5 s:'));
assert(~contains(summaryText,'one configured crosslink'));

fprintf('test_joint_summary_pdf: PASS\n');
end

function combinedText = figureText_(figureHandle)
textHandles = findall(figureHandle,'Type','text');
parts = cell(1,numel(textHandles));
for textIndex = 1:numel(textHandles)
    value = get(textHandles(textIndex),'String');
    if iscell(value)
        value = strjoin(value,newline);
    end
    parts{textIndex} = char(string(value));
end
combinedText = strjoin(parts,newline);
end

function cleanup_(reportFolder)
figures = findobj(0,'Type','figure');
if ~isempty(figures)
    close(figures);
end
if exist(reportFolder,'dir') == 7
    rmdir(reportFolder,'s');
end
end
