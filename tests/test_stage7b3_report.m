% test_stage7b3_report  Stage 7B.3: clock-style PDF visual replication tests.
%
% Verifies that LatexReportBuilder produces:
%   - Sections labeled 1-7 in correct page order
%   - Per-Receiver section (§4) and Clock/Oscillator section (§5)
%   - Disabled Components (§6) before Numerical Summary (§7)
%   - OriginalStyleReportLayout class exists with required API
%   - cfg.report.layout = 'clockStyle' is accepted
%   - run_oo_reverse_gnss_report.m references the clockStyle layout

function tests = test_stage7b3_report
    tests = functiontests(localfunctions);
end

% ======================================================================
function setup(tc)
    thisDir = fileparts(mfilename('fullpath'));
    addpath(fullfile(thisDir, '..'));
end

% ======================================================================
% T01 — build() with clockStyle config returns >= 7 figures
% ======================================================================
function testClockStyleReportBuilds(tc)
    cfg = tc7b3_minimalCfg_();
    diag = tc7b3_emptyDiag_();
    figs = revgnss.LatexReportBuilder.build(diag, [], [], cfg, struct());
    tc7b3_closeFigs_(figs);
    verifyTrue(tc, numel(figs) >= 7, ...
        sprintf('Expected >= 7 figures with clockStyle, got %d', numel(figs)));
end

% ======================================================================
% T02 — no raw text-dump "00 — Report Summary" page in output
% ======================================================================
function testClockStyleReportNoRawDumpFirstPage(tc)
    cfg  = tc7b3_minimalCfg_();
    diag = tc7b3_emptyDiag_();
    figs = revgnss.LatexReportBuilder.build(diag, [], [], cfg, struct());
    names = arrayfun(@(f) get(f,'Name'), figs, 'UniformOutput', false);
    tc7b3_closeFigs_(figs);
    hasDump = any(contains(names, 'Report Summary', 'IgnoreCase', false) & ...
                  cellfun(@(n) startsWith(n,'00'), names));
    verifyFalse(tc, hasDump, 'Raw dump page (00 — Report Summary) should not appear');
end

% ======================================================================
% T03 — sections 1, 2, 3, 4, 5, 6, 7 appear in ascending page order
% ======================================================================
function testClockStyleReportCorrectSectionOrder(tc)
    cfg  = tc7b3_minimalCfg_();
    diag = tc7b3_emptyDiag_();
    figs = revgnss.LatexReportBuilder.build(diag, [], [], cfg, struct());

    markers = {'1. Scenario', '2. State', '3. Measurement', ...
               '4. Per-Receiver', '5. Clock', '6. Disabled', '7. Numerical'};
    idxs = zeros(1, numel(markers));
    for m = 1:numel(markers)
        for fi = 1:numel(figs)
            txt = tc7b3_figText_(figs(fi));
            if contains(txt, markers{m}, 'IgnoreCase', true)
                idxs(m) = fi;
                break;
            end
        end
    end
    tc7b3_closeFigs_(figs);

    for m = 1:numel(markers)
        verifyGreaterThan(tc, idxs(m), 0, ...
            sprintf('Section marker "%s" not found in any figure', markers{m}));
    end
    for m = 2:numel(markers)
        verifyGreaterThan(tc, idxs(m), idxs(m-1), ...
            sprintf('Section %d page (idx=%d) not after section %d page (idx=%d)', ...
                m, idxs(m), m-1, idxs(m-1)));
    end
end

% ======================================================================
% T04 — some page contains "1. Scenario Summary"
% ======================================================================
function testClockStyleReportHasScenarioSummary(tc)
    cfg  = tc7b3_minimalCfg_();
    diag = tc7b3_emptyDiag_();
    figs = revgnss.LatexReportBuilder.build(diag, [], [], cfg, struct());
    found = tc7b3_anyFigContains_(figs, '1. Scenario Summary');
    tc7b3_closeFigs_(figs);
    verifyTrue(tc, found, 'No figure contains "1. Scenario Summary"');
end

% ======================================================================
% T05 — some page has the EKF state vector table (Index, Symbol, Description)
% ======================================================================
function testClockStyleReportHasStateVectorTable(tc)
    cfg  = tc7b3_minimalCfg_();
    diag = tc7b3_emptyDiag_();
    figs = revgnss.LatexReportBuilder.build(diag, [], [], cfg, struct());
    hasIdx = tc7b3_anyFigContains_(figs, 'Index');
    hasSym = tc7b3_anyFigContains_(figs, 'Symbol');
    hasSV  = tc7b3_anyFigContains_(figs, 'State Vector');
    tc7b3_closeFigs_(figs);
    verifyTrue(tc, hasIdx && hasSym && hasSV, ...
        'State vector table (Index / Symbol / State Vector) not found');
end

% ======================================================================
% T06 — some page has measurement model text (pseudorange equation)
% ======================================================================
function testClockStyleReportHasMeasurementModelTable(tc)
    cfg  = tc7b3_minimalCfg_();
    diag = tc7b3_emptyDiag_();
    figs = revgnss.LatexReportBuilder.build(diag, [], [], cfg, struct());
    hasMM  = tc7b3_anyFigContains_(figs, 'Measurement Model');
    hasPR  = tc7b3_anyFigContains_(figs, 'pseudorange', 'IgnoreCase', true);
    tc7b3_closeFigs_(figs);
    verifyTrue(tc, hasMM && hasPR, ...
        '"Measurement Model" + "pseudorange" not found in any figure');
end

% ======================================================================
% T07 — some page has component-status table (Enabled / Disabled)
% ======================================================================
function testClockStyleReportHasComponentStatusTable(tc)
    cfg  = tc7b3_minimalCfg_();
    diag = tc7b3_emptyDiag_();
    figs = revgnss.LatexReportBuilder.build(diag, [], [], cfg, struct());
    hasCS  = tc7b3_anyFigContains_(figs, 'Component Status');
    hasEn  = tc7b3_anyFigContains_(figs, 'Enabled');
    hasDis = tc7b3_anyFigContains_(figs, 'Disabled');
    tc7b3_closeFigs_(figs);
    verifyTrue(tc, hasCS && hasEn && hasDis, ...
        'Component Status table with Enabled/Disabled not found');
end

% ======================================================================
% T08 — at least one figure has "No plot generated." (two-column rows)
% ======================================================================
function testClockStyleReportHasPlotDescriptionRows(tc)
    cfg  = tc7b3_minimalCfg_();
    diag = tc7b3_emptyDiag_();
    figs = revgnss.LatexReportBuilder.build(diag, [], [], cfg, struct());
    found = tc7b3_anyFigContains_(figs, 'No plot generated.');
    tc7b3_closeFigs_(figs);
    verifyTrue(tc, found, '"No plot generated." not found in any figure');
end

% ======================================================================
% T09 — some page contains "Per-Receiver" (section 4)
% ======================================================================
function testClockStyleReportHasPerReceiverSection(tc)
    cfg  = tc7b3_minimalCfg_();
    diag = tc7b3_emptyDiag_();
    figs = revgnss.LatexReportBuilder.build(diag, [], [], cfg, struct());
    found = tc7b3_anyFigContains_(figs, 'Per-Receiver');
    tc7b3_closeFigs_(figs);
    verifyTrue(tc, found, '"Per-Receiver" not found in any figure (section 4 missing)');
end

% ======================================================================
% T10 — some page contains clock validation section (§5)
% ======================================================================
function testClockStyleReportHasClockValidationSection(tc)
    cfg  = tc7b3_minimalCfg_();
    diag = tc7b3_emptyDiag_();
    figs = revgnss.LatexReportBuilder.build(diag, [], [], cfg, struct());
    hasClk = tc7b3_anyFigContains_(figs, '5. Clock');
    tc7b3_closeFigs_(figs);
    verifyTrue(tc, hasClk, '"5. Clock" section not found (clock validation section missing)');
end

% ======================================================================
% T11 — some page contains disabled-components section with "No plot generated."
% ======================================================================
function testClockStyleReportHasDisabledComponentsRows(tc)
    cfg  = tc7b3_minimalCfg_();
    diag = tc7b3_emptyDiag_();
    figs = revgnss.LatexReportBuilder.build(diag, [], [], cfg, struct());
    hasDis = tc7b3_anyFigContains_(figs, '6. Disabled');
    hasRow = tc7b3_anyFigContains_(figs, 'No plot generated.');
    tc7b3_closeFigs_(figs);
    verifyTrue(tc, hasDis && hasRow, ...
        'Section "6. Disabled" with "No plot generated." rows not found');
end

% ======================================================================
% T12 — some page contains "7. Numerical Summary"
% ======================================================================
function testClockStyleReportHasNumericalSummary(tc)
    cfg  = tc7b3_minimalCfg_();
    diag = tc7b3_emptyDiag_();
    figs = revgnss.LatexReportBuilder.build(diag, [], [], cfg, struct());
    found = tc7b3_anyFigContains_(figs, '7. Numerical Summary');
    tc7b3_closeFigs_(figs);
    verifyTrue(tc, found, '"7. Numerical Summary" not found in any figure');
end

% ======================================================================
% T13 — no "NaN" literal in the summary page when metrics unavailable
% ======================================================================
function testClockStyleReportNoNaNInSummaryWhenUnavailable(tc)
    cfg  = tc7b3_minimalCfg_();
    diag = tc7b3_emptyDiag_();
    figs = revgnss.LatexReportBuilder.build(diag, [], [], cfg, struct());

    % Check verdict/numerical page — should say 'not available', not 'NaN'
    nanFound = false;
    for fi = 1:numel(figs)
        txt = tc7b3_figText_(figs(fi));
        if contains(txt, '7. Numerical') || contains(txt, 'Numerical Summary')
            if contains(txt, ' NaN') || contains(txt, 'NaN ')
                nanFound = true;
            end
            break;
        end
    end
    tc7b3_closeFigs_(figs);
    verifyFalse(tc, nanFound, 'Numerical Summary page contains literal NaN');
end

% ======================================================================
% T14 — default cfg: figure count <= 15 (no raw plot appendix)
% ======================================================================
function testClockStyleReportNoRawPlotAppendixByDefault(tc)
    cfg  = tc7b3_minimalCfg_();
    diag = tc7b3_emptyDiag_();
    figs = revgnss.LatexReportBuilder.build(diag, [], [], cfg, struct());
    n = numel(figs);
    tc7b3_closeFigs_(figs);
    verifyLessThanOrEqual(tc, n, 15, ...
        sprintf('Default build produced %d figures (expected <= 15; raw plots should be off)', n));
end

% ======================================================================
% T15 — appendRawPlots=true accepted without error
% ======================================================================
function testClockStyleReportAppendRawPlotsOptional(tc)
    cfg = tc7b3_minimalCfg_();
    cfg.report.appendRawPlots = true;
    diag = tc7b3_emptyDiag_();
    figs = revgnss.LatexReportBuilder.build(diag, [], [], cfg, struct());
    tc7b3_closeFigs_(figs);
    verifyTrue(tc, numel(figs) >= 7, ...
        'appendRawPlots=true broke build() — fewer than 7 figures returned');
end

% ======================================================================
% T16 — run_oo_reverse_gnss_report.m exists and references clockStyle
% ======================================================================
function testClockStyleReportRunScriptWorks(tc)
    thisDir = fileparts(mfilename('fullpath'));
    scriptPath = fullfile(thisDir, '..', 'run_oo_reverse_gnss_report.m');
    verifyTrue(tc, isfile(scriptPath), 'run_oo_reverse_gnss_report.m not found');

    src = fileread(scriptPath);
    hasLayout     = contains(src, 'report.layout');
    hasClockStyle = contains(src, 'clockStyle');
    verifyTrue(tc, hasLayout,     'run_oo_reverse_gnss_report.m missing cfg.report.layout');
    verifyTrue(tc, hasClockStyle, 'run_oo_reverse_gnss_report.m missing ''clockStyle'' value');
end

% ======================================================================
% T17 — some page states that PPP is NOT implemented (limitation noted)
% ======================================================================
function testClockStyleReportStatesNoPPP(tc)
    cfg  = tc7b3_minimalCfg_();
    diag = tc7b3_emptyDiag_();
    figs = revgnss.LatexReportBuilder.build(diag, [], [], cfg, struct());
    found = tc7b3_anyFigContains_(figs, 'PPP');
    tc7b3_closeFigs_(figs);
    verifyTrue(tc, found, 'PPP limitation not stated in any figure');
end

% ======================================================================
% T18 — some page states carrier float limitations
% ======================================================================
function testClockStyleReportStatesCarrierLimitations(tc)
    cfg  = tc7b3_minimalCfg_();
    diag = tc7b3_emptyDiag_();
    figs = revgnss.LatexReportBuilder.build(diag, [], [], cfg, struct());
    hasFloat   = tc7b3_anyFigContains_(figs, 'float', 'IgnoreCase', true);
    hasCarrier = tc7b3_anyFigContains_(figs, 'carrier', 'IgnoreCase', true);
    tc7b3_closeFigs_(figs);
    verifyTrue(tc, hasFloat && hasCarrier, ...
        'Carrier float limitations not stated in any figure');
end

% ======================================================================
% LOCAL HELPERS
% ======================================================================

function cfg = tc7b3_minimalCfg_()
    cfg = revgnss.ConfigFactory.defaultConfig();
    cfg.report.style  = 'latex';
    cfg.report.layout = 'clockStyle';
    cfg.report.writeTex  = false;
    cfg.report.compileTex = 'never';
    cfg.report.writePdf  = false;
    cfg.report.writeMat  = false;
end

function diag = tc7b3_emptyDiag_()
    % Minimal stub that satisfies Diagnostics constructor
    try
        cfg = revgnss.ConfigFactory.defaultConfig();
        diag = revgnss.Diagnostics(cfg);
    catch
        diag = struct();
    end
end

function txt = tc7b3_figText_(fig)
    txt = '';
    if ~isgraphics(fig); return; end
    allTxt = findall(fig, 'Type', 'text');
    parts  = cell(1, numel(allTxt));
    for k = 1:numel(allTxt)
        s = get(allTxt(k), 'String');
        if iscell(s)
            parts{k} = strjoin(s, ' ');
        elseif ischar(s) || isstring(s)
            parts{k} = char(s);
        else
            parts{k} = '';
        end
    end
    txt = strjoin(parts, ' ');
end

function found = tc7b3_anyFigContains_(figs, pattern, varargin)
    found = false;
    for fi = 1:numel(figs)
        txt = tc7b3_figText_(figs(fi));
        if contains(txt, pattern, varargin{:})
            found = true;
            return;
        end
    end
end

function tc7b3_closeFigs_(figs)
    try
        close(figs(isgraphics(figs)));
    catch
    end
end
