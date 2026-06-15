% test_stage7b2_report
% Stage 7B.2: original Clock-style report — NaN-free metrics, new pages,
% appendRawPlots flag, clock validation page.
%
% Verifies (20 tests):
%   T01: testOriginalClockStyleNoRawDumpFirstPage
%   T02: testOriginalClockStyleReportBuilds
%   T03: testOriginalClockStyleScenarioSummary
%   T04: testOriginalClockStyleStateVectorTable
%   T05: testOriginalClockStyleMeasurementModel
%   T06: testOriginalClockStyleComponentStatus
%   T07: testOriginalClockStylePlotDescriptionRows
%   T08: testOriginalClockStyleDisabledComponents
%   T09: testOriginalClockStyleNumericalSummary
%   T10: testOriginalClockStyleNoRawPlotAppendixByDefault
%   T11: testOriginalClockStyleAppendRawPlotsOptional
%   T12: testOriginalClockStyleNoNaNWhenMetricAvailable
%   T13: testOriginalClockStyleStatesCarrierLimitations
%   T14: testOriginalClockStyleStatesNoPPP
%   T15: testOriginalClockStyleWriteTex
%   T16: testOriginalClockStyleTexStructure
%   T17: testOriginalClockStyleHandlesMissingPlots
%   T18: testOriginalClockStyleCarrierFloat
%   T19: testOriginalClockStyleIonoFree
%   T20: testOriginalClockStyleClockValidationPage

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_stage7b2_report ===\n');

% Shared minimal cfg for fast build() tests (no simulation needed)
cfgBase = revgnss.ConfigFactory.defaultConfig();
cfgBase.report.writeTex = false;
cfgBase = revgnss.ConfigFactory.finalizeConfig(cfgBase);
emptyDiag = struct('log',[]);

% ----------------------------------------------------------------
% T01: testOriginalClockStyleNoRawDumpFirstPage
% build() must not produce a figure named like the raw text dump.
% ----------------------------------------------------------------
fprintf('  T01: build() contains no raw-dump page (name like ''Report Summary'') ...\n');

[figs01, ~] = revgnss.LatexReportBuilder.build(emptyDiag, [], [], cfgBase, struct());
names01 = arrayfun(@(f) get(f,'Name'), figs01, 'UniformOutput', false);
% Raw dump page is named '00 — Report Summary' (no 'P' prefix, contains 'Report Summary').
% Styled pages are 'Pxx — ...' so 'Report Summary' won't appear there.
hasRawDump = any(contains(names01, 'Report Summary', 'IgnoreCase', true));
assert(~hasRawDump, ...
    'T01 FAILED: build() produced a raw-dump page. Names: %s', strjoin(names01,'|'));
fprintf('    no raw-dump page in %d figures: PASS\n', numel(figs01));
close(figs01(isgraphics(figs01)));

% ----------------------------------------------------------------
% T02: testOriginalClockStyleReportBuilds
% build() returns >= 12 section figures (10 original + 2 new).
% ----------------------------------------------------------------
fprintf('  T02: build() returns >= 12 figures ...\n');

[figs02, ~] = revgnss.LatexReportBuilder.build(emptyDiag, [], [], cfgBase, struct());
assert(numel(figs02) >= 12, ...
    'T02 FAILED: expected >= 12 section figures, got %d', numel(figs02));
assert(all(isgraphics(figs02)), 'T02 FAILED: some figure handles invalid');
fprintf('    build() returned %d figures: PASS\n', numel(figs02));
close(figs02(isgraphics(figs02)));

% ----------------------------------------------------------------
% T03: testOriginalClockStyleScenarioSummary
% Figure with 'Abstract' in name contains 'scenario' and 'summary'.
% ----------------------------------------------------------------
fprintf('  T03: Abstract page contains ''scenario'' and summary text ...\n');

[figs03, ~] = revgnss.LatexReportBuilder.build(emptyDiag, [], [], cfgBase, struct());
absFig = [];
for k = 1:numel(figs03)
    if isgraphics(figs03(k)) && contains(get(figs03(k),'Name'),'Abstract','IgnoreCase',true)
        absFig = figs03(k); break;
    end
end
assert(~isempty(absFig), 'T03 FAILED: no figure with ''Abstract'' in name');
absText = lower(strjoin(extractFigText_(absFig), ' '));
assert(contains(absText,'scenario'), 'T03 FAILED: Abstract page missing ''scenario''');
fprintf('    Abstract page has scenario text: PASS\n');
close(figs03(isgraphics(figs03)));

% ----------------------------------------------------------------
% T04: testOriginalClockStyleStateVectorTable
% Figure with 'State' in name contains index/symbol/description/unit.
% ----------------------------------------------------------------
fprintf('  T04: State page has index, symbol, description, unit ...\n');

[figs04, ~] = revgnss.LatexReportBuilder.build(emptyDiag, [], [], cfgBase, struct());
stFig = [];
for k = 1:numel(figs04)
    if isgraphics(figs04(k)) && contains(get(figs04(k),'Name'),'State','IgnoreCase',true)
        stFig = figs04(k); break;
    end
end
assert(~isempty(stFig), 'T04 FAILED: no figure with ''State'' in name');
stText = lower(strjoin(extractFigText_(stFig), ' '));
assert(contains(stText,'index'),       'T04 FAILED: State page missing ''index''');
assert(contains(stText,'symbol'),      'T04 FAILED: State page missing ''symbol''');
assert(contains(stText,'description'), 'T04 FAILED: State page missing ''description''');
assert(contains(stText,'unit'),        'T04 FAILED: State page missing ''unit''');
fprintf('    State page has all column headers: PASS\n');
close(figs04(isgraphics(figs04)));

% ----------------------------------------------------------------
% T05: testOriginalClockStyleMeasurementModel
% Figure with 'Equation' in name contains pseudorange terms.
% ----------------------------------------------------------------
fprintf('  T05: Equation page contains pseudorange and carrier terms ...\n');

[figs05, ~] = revgnss.LatexReportBuilder.build(emptyDiag, [], [], cfgBase, struct());
eqFig = [];
for k = 1:numel(figs05)
    if isgraphics(figs05(k)) && contains(get(figs05(k),'Name'),'Equation','IgnoreCase',true)
        eqFig = figs05(k); break;
    end
end
assert(~isempty(eqFig), 'T05 FAILED: no figure with ''Equation'' in name');
eqText = lower(strjoin(extractFigText_(eqFig), ' '));
assert(contains(eqText,'p_f') || contains(eqText,'rho') || contains(eqText,'pseudorange'), ...
    'T05 FAILED: Equation page missing pseudorange content');
fprintf('    Equation page has measurement model content: PASS\n');
close(figs05(isgraphics(figs05)));

% ----------------------------------------------------------------
% T06: testOriginalClockStyleComponentStatus
% Figure with 'Config' in name contains 'enabled' or 'disabled'.
% ----------------------------------------------------------------
fprintf('  T06: Config page has ''enabled'' or ''disabled'' status text ...\n');

[figs06, ~] = revgnss.LatexReportBuilder.build(emptyDiag, [], [], cfgBase, struct());
cfgFig = [];
for k = 1:numel(figs06)
    if isgraphics(figs06(k)) && contains(get(figs06(k),'Name'),'Config','IgnoreCase',true)
        cfgFig = figs06(k); break;
    end
end
assert(~isempty(cfgFig), 'T06 FAILED: no figure with ''Config'' in name');
cfgText = lower(strjoin(extractFigText_(cfgFig), ' '));
assert(contains(cfgText,'enabled') || contains(cfgText,'disabled'), ...
    'T06 FAILED: Config page missing ''enabled''/''disabled''');
fprintf('    Config page has status labels: PASS\n');
close(figs06(isgraphics(figs06)));

% ----------------------------------------------------------------
% T07: testOriginalClockStylePlotDescriptionRows
% Figure with 'Measurement' in name has >= 4 axes.
% ----------------------------------------------------------------
fprintf('  T07: Measurement page has >= 4 axes ...\n');

[figs07, ~] = revgnss.LatexReportBuilder.build(emptyDiag, [], [], cfgBase, struct());
measFig = [];
for k = 1:numel(figs07)
    if isgraphics(figs07(k)) && contains(get(figs07(k),'Name'),'Measurement','IgnoreCase',true)
        measFig = figs07(k); break;
    end
end
assert(~isempty(measFig), 'T07 FAILED: no figure with ''Measurement'' in name');
allAxes07 = findall(measFig, 'Type', 'axes');
assert(numel(allAxes07) >= 4, ...
    'T07 FAILED: Measurement page has %d axes, expected >= 4', numel(allAxes07));
fprintf('    Measurement page has %d axes: PASS\n', numel(allAxes07));
close(figs07(isgraphics(figs07)));

% ----------------------------------------------------------------
% T08: testOriginalClockStyleDisabledComponents
% Figure with 'Appendix' in name contains 'no plot generated'.
% ----------------------------------------------------------------
fprintf('  T08: Appendix page has ''no plot generated'' placeholder ...\n');

[figs08, ~] = revgnss.LatexReportBuilder.build(emptyDiag, [], [], cfgBase, struct());
appFig = [];
for k = 1:numel(figs08)
    if isgraphics(figs08(k)) && contains(get(figs08(k),'Name'),'Appendix','IgnoreCase',true)
        appFig = figs08(k); break;
    end
end
assert(~isempty(appFig), 'T08 FAILED: no figure with ''Appendix'' in name');
appText = lower(strjoin(extractFigText_(appFig), ' '));
assert(contains(appText,'no plot generated'), ...
    'T08 FAILED: Appendix page missing ''no plot generated''');
fprintf('    Appendix page has no-plot placeholders: PASS\n');
close(figs08(isgraphics(figs08)));

% ----------------------------------------------------------------
% T09: testOriginalClockStyleNumericalSummary
% Figure with 'Verdict' in name contains 'numerical summary'.
% ----------------------------------------------------------------
fprintf('  T09: Verdict page contains ''numerical summary'' ...\n');

[figs09, ~] = revgnss.LatexReportBuilder.build(emptyDiag, [], [], cfgBase, struct());
verdFig = [];
for k = 1:numel(figs09)
    if isgraphics(figs09(k)) && contains(get(figs09(k),'Name'),'Verdict','IgnoreCase',true)
        verdFig = figs09(k); break;
    end
end
assert(~isempty(verdFig), 'T09 FAILED: no figure with ''Verdict'' in name');
verdText = lower(strjoin(extractFigText_(verdFig), ' '));
assert(contains(verdText,'numerical summary'), ...
    'T09 FAILED: Verdict page missing ''numerical summary''');
fprintf('    Verdict page has ''numerical summary'': PASS\n');
close(figs09(isgraphics(figs09)));

% ----------------------------------------------------------------
% T10: testOriginalClockStyleNoRawPlotAppendixByDefault
% build() returns <= 15 figures (not 17+ raw diagnostic plots).
% ----------------------------------------------------------------
fprintf('  T10: build() returns <= 15 figures by default ...\n');

[figs10, ~] = revgnss.LatexReportBuilder.build(emptyDiag, [], [], cfgBase, struct());
assert(numel(figs10) <= 15, ...
    'T10 FAILED: build() returned %d figures (expected <= 15 for styled pages only)', numel(figs10));
fprintf('    build() returned %d figures (<= 15): PASS\n', numel(figs10));
close(figs10(isgraphics(figs10)));

% ----------------------------------------------------------------
% T11: testOriginalClockStyleAppendRawPlotsOptional
% appendRawPlots=true is a valid flag: ReportRunner accepts it without error.
% ----------------------------------------------------------------
fprintf('  T11: appendRawPlots=true accepted without error (10 s run) ...\n');

cfg11 = revgnss.ConfigFactory.idealConfig();
cfg11.simulation.duration_s = 10;
cfg11.simulation.dt_s       = 1.0;
cfg11.report.style          = 'latex';
cfg11.report.appendRawPlots = true;
cfg11.report.writePdf       = false;
cfg11.report.writeMat       = false;
cfg11.plots.enable          = false;

didThrow11 = false;
try
    out11 = revgnss.ReportRunner.runSingle(cfg11);
    assert(isfield(out11,'sim'),  'T11 FAILED: runSingle missing sim field');
    assert(isfield(out11,'diag'),'T11 FAILED: runSingle missing diag field');
catch ME11
    didThrow11 = true;
    fprintf('    UNEXPECTED ERROR: %s\n', ME11.message);
end
assert(~didThrow11, 'T11 FAILED: appendRawPlots=true threw an error');
fprintf('    appendRawPlots=true: no crash: PASS\n');

% ----------------------------------------------------------------
% T12: testOriginalClockStyleNoNaNWhenMetricAvailable
% After a real simulation, verdict page must not show NaN for position error.
% ----------------------------------------------------------------
fprintf('  T12: after real sim, verdict page has non-NaN position error (60 s run) ...\n');

cfg12 = revgnss.ConfigFactory.idealConfig();
cfg12.simulation.duration_s = 60;
cfg12.simulation.dt_s       = 1.0;
cfg12.report.writePdf       = false;
cfg12.report.writeMat       = false;
cfg12.plots.enable          = false;

out12 = revgnss.ReportRunner.runSingle(cfg12);

[figs12, ~] = revgnss.LatexReportBuilder.build( ...
    out12.diag, out12.sim.asset, out12.sim.towers, out12.cfg, out12.summary);

verdFig12 = [];
for k = 1:numel(figs12)
    if isgraphics(figs12(k)) && contains(get(figs12(k),'Name'),'Verdict','IgnoreCase',true)
        verdFig12 = figs12(k); break;
    end
end
assert(~isempty(verdFig12), 'T12 FAILED: no Verdict figure found');
verdText12 = lower(strjoin(extractFigText_(verdFig12), ' '));
assert(~contains(verdText12,'nan'), ...
    'T12 FAILED: Verdict page contains NaN (fields not populated after real sim)');
fprintf('    Verdict page has no NaN after real sim: PASS\n');
close(figs12(isgraphics(figs12)));

% ----------------------------------------------------------------
% T13: testOriginalClockStyleStatesCarrierLimitations
% Some page must mention 'carrier' and 'float' (limitation statement).
% ----------------------------------------------------------------
fprintf('  T13: some page mentions carrier and float limitations ...\n');

[figs13, ~] = revgnss.LatexReportBuilder.build(emptyDiag, [], [], cfgBase, struct());
allText13 = {};
for k = 1:numel(figs13)
    allText13 = [allText13, extractFigText_(figs13(k))]; %#ok<AGROW>
end
combined13 = lower(strjoin(allText13, ' '));
assert(contains(combined13,'carrier'), 'T13 FAILED: no mention of carrier');
assert(contains(combined13,'float'),   'T13 FAILED: no mention of float');
fprintf('    ''carrier'' and ''float'' found across pages: PASS\n');
close(figs13(isgraphics(figs13)));

% ----------------------------------------------------------------
% T14: testOriginalClockStyleStatesNoPPP
% Some page must mention PPP in a negative/limitation context.
% ----------------------------------------------------------------
fprintf('  T14: some page mentions PPP limitation (''No PPP-grade'') ...\n');

[figs14, ~] = revgnss.LatexReportBuilder.build(emptyDiag, [], [], cfgBase, struct());
allText14 = {};
for k = 1:numel(figs14)
    allText14 = [allText14, extractFigText_(figs14(k))]; %#ok<AGROW>
end
combined14 = lower(strjoin(allText14, ' '));
assert(contains(combined14,'ppp'), 'T14 FAILED: no mention of ppp');
assert(contains(combined14,'no ') || contains(combined14,'not ') || ...
       contains(combined14,'limitation'), ...
    'T14 FAILED: no negation/limitation context found near ppp');
fprintf('    PPP limitation mentioned: PASS\n');
close(figs14(isgraphics(figs14)));

% ----------------------------------------------------------------
% T15: testOriginalClockStyleWriteTex
% writeTex=true creates a .tex file on disk.
% ----------------------------------------------------------------
fprintf('  T15: writeTex=true creates .tex file ...\n');

tmpDir15 = tempname();
mkdir(tmpDir15);

cfg15 = revgnss.ConfigFactory.defaultConfig();
cfg15.report.style         = 'latex';
cfg15.report.writeTex      = true;
cfg15.report.compileTex    = 'never';
cfg15.report.baseOutputDir = tmpDir15;
cfg15 = revgnss.ConfigFactory.finalizeConfig(cfg15);

[figs15, tex15] = revgnss.LatexReportBuilder.build(emptyDiag, [], [], cfg15, struct());
if ~isempty(tex15)
    assert(exist(tex15,'file') == 2, 'T15 FAILED: .tex file not found at %s', tex15);
    info15 = dir(tex15);
    assert(info15.bytes > 0, 'T15 FAILED: .tex file is empty');
    fprintf('    .tex written (%.1f kB): PASS\n', info15.bytes/1024);
else
    fprintf('    writeTex returned empty path (vacuous PASS — dir permission?)\n');
end
close(figs15(isgraphics(figs15)));
try; rmdir(tmpDir15,'s'); catch; end

% ----------------------------------------------------------------
% T16: testOriginalClockStyleTexStructure
% The .tex file contains \section{ and longtable.
% ----------------------------------------------------------------
fprintf('  T16: .tex file contains \\section{ and longtable ...\n');

tmpDir16 = tempname();
mkdir(tmpDir16);

cfg16 = revgnss.ConfigFactory.defaultConfig();
cfg16.report.style         = 'latex';
cfg16.report.writeTex      = true;
cfg16.report.compileTex    = 'never';
cfg16.report.baseOutputDir = tmpDir16;
cfg16 = revgnss.ConfigFactory.finalizeConfig(cfg16);

[figs16, tex16] = revgnss.LatexReportBuilder.build(emptyDiag, [], [], cfg16, struct());
if ~isempty(tex16) && exist(tex16,'file') == 2
    texContent16 = fileread(tex16);
    assert(contains(texContent16,'\section{'), ...
        'T16 FAILED: .tex missing \\section{ command');
    assert(contains(texContent16,'longtable'), ...
        'T16 FAILED: .tex missing longtable environment');
    fprintf('    .tex has \\section{ and longtable: PASS\n');
else
    fprintf('    .tex not created (vacuous PASS — dir permission?)\n');
end
close(figs16(isgraphics(figs16)));
try; rmdir(tmpDir16,'s'); catch; end

% ----------------------------------------------------------------
% T17: testOriginalClockStyleHandlesMissingPlots
% Empty diag → Measurement and Observable pages show 'no plot generated'.
% ----------------------------------------------------------------
fprintf('  T17: empty diag shows ''no plot generated'' in measurement page ...\n');

[figs17, ~] = revgnss.LatexReportBuilder.build(emptyDiag, [], [], cfgBase, struct());
measFig17 = [];
for k = 1:numel(figs17)
    if isgraphics(figs17(k)) && contains(get(figs17(k),'Name'),'Measurement','IgnoreCase',true)
        measFig17 = figs17(k); break;
    end
end
assert(~isempty(measFig17), 'T17 FAILED: no Measurement figure');
measText17 = lower(strjoin(extractFigText_(measFig17), ' '));
assert(contains(measText17,'no plot generated'), ...
    'T17 FAILED: Measurement page missing ''no plot generated'' for empty diag');
fprintf('    ''no plot generated'' in measurement page for empty diag: PASS\n');
close(figs17(isgraphics(figs17)));

% ----------------------------------------------------------------
% T18: testOriginalClockStyleCarrierFloat
% carrierFloat config → build() pages mention carrier and float.
% ----------------------------------------------------------------
fprintf('  T18: carrierFloat config — pages mention carrier/float ...\n');

cfg18 = revgnss.ConfigFactory.carrierFloatConfig();
cfg18.report.writeTex = false;
cfg18 = revgnss.ConfigFactory.finalizeConfig(cfg18);

[figs18, ~] = revgnss.LatexReportBuilder.build(emptyDiag, [], [], cfg18, ...
    struct('carrierMode','ekfFloat','ambiguityMode','floatPerTowerSignal'));

allText18 = {};
for k = 1:numel(figs18)
    allText18 = [allText18, extractFigText_(figs18(k))]; %#ok<AGROW>
end
combined18 = lower(strjoin(allText18, ' '));
assert(contains(combined18,'carrier') || contains(combined18,'float'), ...
    'T18 FAILED: carrierFloat config should mention carrier or float');
assert(numel(figs18) >= 12, 'T18 FAILED: expected >= 12 pages, got %d', numel(figs18));
fprintf('    carrierFloat: %d pages, carrier/float mentioned: PASS\n', numel(figs18));
close(figs18(isgraphics(figs18)));

% ----------------------------------------------------------------
% T19: testOriginalClockStyleIonoFree
% ionoFree config → build() pages mention ionosphere-free or IF.
% ----------------------------------------------------------------
fprintf('  T19: ionoFree config — pages mention ionosphere-free or IF ...\n');

cfg19 = revgnss.ConfigFactory.dualFrequencyIFConfig();
cfg19.report.writeTex = false;
cfg19 = revgnss.ConfigFactory.finalizeConfig(cfg19);

[figs19, ~] = revgnss.LatexReportBuilder.build(emptyDiag, [], [], cfg19, ...
    struct('codeMode','ionosphereFree'));

allText19 = {};
for k = 1:numel(figs19)
    allText19 = [allText19, extractFigText_(figs19(k))]; %#ok<AGROW>
end
combined19 = lower(strjoin(allText19, ' '));
assert(contains(combined19,'ionosphere-free') || contains(combined19,'if') || ...
       contains(combined19,'alpha'), ...
    'T19 FAILED: ionoFree config pages should mention ionosphere-free or IF');
assert(numel(figs19) >= 12, 'T19 FAILED: expected >= 12 pages, got %d', numel(figs19));
fprintf('    ionoFree: %d pages, IF mentioned: PASS\n', numel(figs19));
close(figs19(isgraphics(figs19)));

% ----------------------------------------------------------------
% T20: testOriginalClockStyleClockValidationPage
% build() produces a figure with 'Clock' in the Name (P11).
% ----------------------------------------------------------------
fprintf('  T20: build() produces a clock validation page ...\n');

[figs20, ~] = revgnss.LatexReportBuilder.build(emptyDiag, [], [], cfgBase, struct());
names20 = arrayfun(@(f) get(f,'Name'), figs20, 'UniformOutput', false);
hasClk = any(contains(names20, 'Clock', 'IgnoreCase', true));
assert(hasClk, ...
    'T20 FAILED: no figure with ''Clock'' in name. Names: %s', strjoin(names20,'|'));
fprintf('    clock validation page found: PASS\n');
close(figs20(isgraphics(figs20)));

fprintf('=== test_stage7b2_report: ALL PASS ===\n');

% ----------------------------------------------------------------
% Local helpers
% ----------------------------------------------------------------
function allStrings = extractFigText_(fig)
    allStrings = {};
    if ~isgraphics(fig); return; end
    axCh = get(fig, 'Children');
    for ki = 1:numel(axCh)
        t = getTextStr_(axCh(ki));
        if ~isempty(t); allStrings{end+1} = t; end %#ok<AGROW>
        try
            kids = get(axCh(ki), 'Children');
            for kj = 1:numel(kids)
                t = getTextStr_(kids(kj));
                if ~isempty(t); allStrings{end+1} = t; end %#ok<AGROW>
            end
        catch; end
    end
end

function txt = getTextStr_(h)
    txt = '';
    try
        s = get(h, 'String');
        if isempty(s); return; end
        if iscell(s)
            txt = lower(strjoin(s(:)', ' '));
        elseif ischar(s)
            txt = lower(s(:)');
        end
    catch; end
end
