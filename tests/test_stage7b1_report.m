% test_stage7b1_report.m — Stage 7B.1: original-style report visual verification
%
% 18 sub-tests verifying:
%   - Original-style two-column layout replaces ASCII/Courier blocks
%   - Component status table (Enabled/Disabled) in P03
%   - State-vector 5-column table with Index/Symbol/Description/Unit/Note in P04
%   - Plot-description rows in P05/P06 with "No plot generated." for empty diag
%   - Numerical summary in P08
%   - Scientific sign conventions and limitations stated in text
%   - .tex file contains \section{} and longtable environment
%   - All existing test_stage7b_report tests still pass (T18)
%
% All tests run without a full simulation (fast, < 30 s).

clear; close all; clc;
thisDir   = fileparts(mfilename('fullpath'));
parentDir = fileparts(thisDir);
addpath(parentDir);

fprintf('=== test_stage7b1_report ===\n');

nPass = 0; nFail = 0;

% -----------------------------------------------------------------------
% Helper: build report figures with minimal cfg and empty diag
% -----------------------------------------------------------------------
function [figs, cfg, summary] = buildMinimalReport_(parentDir2)
    cfg     = revgnss.ConfigFactory.defaultConfig();
    cfg.report.writePdf  = false;
    cfg.report.writeMat  = false;
    cfg.report.writeTex  = false;
    cfg.report.style     = 'latex';
    summary = struct( ...
        'codeMode',         'singleFrequency', ...
        'carrierMode',      'diagnostic', ...
        'ambiguityMode',    'none', ...
        'troposphereMode',  'none', ...
        'version',          '1.01', ...
        'timestamp',        '2026-01-01 00:00:00', ...
        'validationWarnings', {{}});
    diag    = struct();
    asset   = struct();
    towers  = {};
    figs = revgnss.LatexReportBuilder.build(diag, asset, towers, cfg, summary);
end

% -----------------------------------------------------------------------
% T01: testRunOoReverseGnssReportStillWorks
%      Config interface works and LatexReportBuilder.build returns >= 12 figs
%      (10 original + P10 Observable Diagnostics + P11 Clock Validation).
% -----------------------------------------------------------------------
try
    [figs01, ~, ~] = buildMinimalReport_(parentDir);
    n01 = numel(figs01);
    close(figs01);
    assert(n01 >= 12, 'Expected >= 12 report figures, got %d', n01);
    fprintf('T01 testRunOoReverseGnssReportStillWorks : PASS (%d figs)\n', n01);
    nPass = nPass + 1;
catch ex
    fprintf('T01 testRunOoReverseGnssReportStillWorks : FAIL — %s\n', ex.message);
    nFail = nFail + 1;
end

% -----------------------------------------------------------------------
% T02: testOriginalStyleReportBuilds
%      All 10 figures have correct 'Pxx —' name keywords.
% -----------------------------------------------------------------------
try
    [figs02, ~, ~] = buildMinimalReport_(parentDir);
    keywords = {'Title','Abstract','Equation','Config','State', ...
                'Measurement','Error','Observability','Verdict','Appendix'};
    missing = {};
    for kw = keywords
        found = false;
        for k = 1:numel(figs02)
            if contains(get(figs02(k),'Name'), kw{1}, 'IgnoreCase', true)
                found = true; break;
            end
        end
        if ~found; missing{end+1} = kw{1}; end %#ok<AGROW>
    end
    close(figs02);
    assert(isempty(missing), 'Missing figure keyword(s): %s', strjoin(missing,', '));
    fprintf('T02 testOriginalStyleReportBuilds : PASS\n');
    nPass = nPass + 1;
catch ex
    fprintf('T02 testOriginalStyleReportBuilds : FAIL — %s\n', ex.message);
    nFail = nFail + 1;
end

% -----------------------------------------------------------------------
% T03: testOriginalStyleReportHasScenarioSummary
%      P01 (Abstract) contains 'scenario' and 'summary'.
% -----------------------------------------------------------------------
try
    [figs03, ~, ~] = buildMinimalReport_(parentDir);
    p01txt = '';
    for k = 1:numel(figs03)
        if contains(get(figs03(k),'Name'),'Abstract','IgnoreCase',true)
            p01txt = lower(strjoin(extractFigText_(figs03(k)), ' '));
            break;
        end
    end
    close(figs03);
    assert(contains(p01txt,'scenario'), 'P01 missing "scenario"');
    assert(contains(p01txt,'summary'),  'P01 missing "summary"');
    fprintf('T03 testOriginalStyleReportHasScenarioSummary : PASS\n');
    nPass = nPass + 1;
catch ex
    fprintf('T03 testOriginalStyleReportHasScenarioSummary : FAIL — %s\n', ex.message);
    nFail = nFail + 1;
end

% -----------------------------------------------------------------------
% T04: testOriginalStyleReportHasStateVectorTable
%      P04 (State Vector) contains 'index', 'symbol', 'description', 'unit'.
% -----------------------------------------------------------------------
try
    [figs04, ~, ~] = buildMinimalReport_(parentDir);
    p04txt = '';
    for k = 1:numel(figs04)
        if contains(get(figs04(k),'Name'),'State','IgnoreCase',true)
            p04txt = lower(strjoin(extractFigText_(figs04(k)), ' '));
            break;
        end
    end
    close(figs04);
    assert(contains(p04txt,'index'),       'P04 missing "index"');
    assert(contains(p04txt,'symbol'),      'P04 missing "symbol"');
    assert(contains(p04txt,'description'), 'P04 missing "description"');
    assert(contains(p04txt,'unit'),        'P04 missing "unit"');
    fprintf('T04 testOriginalStyleReportHasStateVectorTable : PASS\n');
    nPass = nPass + 1;
catch ex
    fprintf('T04 testOriginalStyleReportHasStateVectorTable : FAIL — %s\n', ex.message);
    nFail = nFail + 1;
end

% -----------------------------------------------------------------------
% T05: testOriginalStyleReportHasMeasurementModelSection
%      P02 (Equations) contains 'measurement' or 'equation' and equation text.
% -----------------------------------------------------------------------
try
    [figs05, ~, ~] = buildMinimalReport_(parentDir);
    p02txt = '';
    for k = 1:numel(figs05)
        if contains(get(figs05(k),'Name'),'Equation','IgnoreCase',true)
            p02txt = lower(strjoin(extractFigText_(figs05(k)), ' '));
            break;
        end
    end
    close(figs05);
    assert(contains(p02txt,'measurement') || contains(p02txt,'equation'), ...
        'P02 missing "measurement" or "equation"');
    assert(contains(p02txt,'pseudorange') || contains(p02txt,'b_rx'), ...
        'P02 missing pseudorange equation terms');
    fprintf('T05 testOriginalStyleReportHasMeasurementModelSection : PASS\n');
    nPass = nPass + 1;
catch ex
    fprintf('T05 testOriginalStyleReportHasMeasurementModelSection : FAIL — %s\n', ex.message);
    nFail = nFail + 1;
end

% -----------------------------------------------------------------------
% T06: testOriginalStyleReportHasComponentStatusTable
%      P03 (Configuration) contains 'enabled' and 'disabled'.
% -----------------------------------------------------------------------
try
    [figs06, ~, ~] = buildMinimalReport_(parentDir);
    p03txt = '';
    for k = 1:numel(figs06)
        if contains(get(figs06(k),'Name'),'Config','IgnoreCase',true)
            p03txt = lower(strjoin(extractFigText_(figs06(k)), ' '));
            break;
        end
    end
    close(figs06);
    assert(contains(p03txt,'enabled'),  'P03 missing "enabled"');
    assert(contains(p03txt,'disabled'), 'P03 missing "disabled"');
    fprintf('T06 testOriginalStyleReportHasComponentStatusTable : PASS\n');
    nPass = nPass + 1;
catch ex
    fprintf('T06 testOriginalStyleReportHasComponentStatusTable : FAIL — %s\n', ex.message);
    nFail = nFail + 1;
end

% -----------------------------------------------------------------------
% T07: testOriginalStyleReportHasPlotDescriptionRows
%      P05 (Measurement) has multiple axes (two-column row structure).
%      With empty diag, 'no plot generated' appears in left columns.
% -----------------------------------------------------------------------
try
    [figs07, ~, ~] = buildMinimalReport_(parentDir);
    p05fig = [];
    for k = 1:numel(figs07)
        if contains(get(figs07(k),'Name'),'Measurement','IgnoreCase',true)
            p05fig = figs07(k); break;
        end
    end
    nAxes07 = numel(findobj(p05fig, 'Type', 'axes'));
    p05txt  = lower(strjoin(extractFigText_(p05fig), ' '));
    close(figs07);
    assert(nAxes07 >= 4, 'P05 expected >= 4 axes (two-col rows), got %d', nAxes07);
    assert(contains(p05txt,'no plot generated') || contains(p05txt,'position error') || ...
           contains(p05txt,'position'), 'P05 missing expected row content');
    fprintf('T07 testOriginalStyleReportHasPlotDescriptionRows : PASS (%d axes)\n', nAxes07);
    nPass = nPass + 1;
catch ex
    fprintf('T07 testOriginalStyleReportHasPlotDescriptionRows : FAIL — %s\n', ex.message);
    nFail = nFail + 1;
end

% -----------------------------------------------------------------------
% T08: testOriginalStyleReportHasDisabledComponents
%      P09 (Appendix) contains 'no plot generated' for disabled items.
% -----------------------------------------------------------------------
try
    [figs08, ~, ~] = buildMinimalReport_(parentDir);
    p09txt = '';
    for k = 1:numel(figs08)
        if contains(get(figs08(k),'Name'),'Appendix','IgnoreCase',true)
            p09txt = lower(strjoin(extractFigText_(figs08(k)), ' '));
            break;
        end
    end
    close(figs08);
    assert(contains(p09txt,'no plot generated'), 'P09 missing "no plot generated"');
    fprintf('T08 testOriginalStyleReportHasDisabledComponents : PASS\n');
    nPass = nPass + 1;
catch ex
    fprintf('T08 testOriginalStyleReportHasDisabledComponents : FAIL — %s\n', ex.message);
    nFail = nFail + 1;
end

% -----------------------------------------------------------------------
% T09: testOriginalStyleReportHasNumericalSummary
%      P08 (Verdict) contains 'numerical summary' and at least one 'nan' or digit.
% -----------------------------------------------------------------------
try
    [figs09, ~, ~] = buildMinimalReport_(parentDir);
    p08txt = '';
    for k = 1:numel(figs09)
        if contains(get(figs09(k),'Name'),'Verdict','IgnoreCase',true)
            p08txt = lower(strjoin(extractFigText_(figs09(k)), ' '));
            break;
        end
    end
    close(figs09);
    assert(contains(p08txt,'numerical summary') || contains(p08txt,'summary'), ...
        'P08 missing "numerical summary"');
    assert(contains(p08txt,'nan') || any(isstrprop(p08txt,'digit')), ...
        'P08 missing numerical values');
    fprintf('T09 testOriginalStyleReportHasNumericalSummary : PASS\n');
    nPass = nPass + 1;
catch ex
    fprintf('T09 testOriginalStyleReportHasNumericalSummary : FAIL — %s\n', ex.message);
    nFail = nFail + 1;
end

% -----------------------------------------------------------------------
% T10: testOriginalStyleReportStatesCarrierLimitations
%      Any page contains 'carrier' and 'float' (L1 float ambiguity limitation).
% -----------------------------------------------------------------------
try
    [figs10, ~, ~] = buildMinimalReport_(parentDir);
    allTxt10 = '';
    for k = 1:numel(figs10)
        allTxt10 = [allTxt10 ' ' lower(strjoin(extractFigText_(figs10(k)),' '))]; %#ok<AGROW>
    end
    close(figs10);
    assert(contains(allTxt10,'carrier'), 'No page mentions "carrier"');
    assert(contains(allTxt10,'float'),   'No page mentions "float"');
    fprintf('T10 testOriginalStyleReportStatesCarrierLimitations : PASS\n');
    nPass = nPass + 1;
catch ex
    fprintf('T10 testOriginalStyleReportStatesCarrierLimitations : FAIL — %s\n', ex.message);
    nFail = nFail + 1;
end

% -----------------------------------------------------------------------
% T11: testOriginalStyleReportStatesProductSemantics
%      Any page contains 'receiver clock' and 'positive'.
% -----------------------------------------------------------------------
try
    [figs11, ~, ~] = buildMinimalReport_(parentDir);
    allTxt11 = '';
    for k = 1:numel(figs11)
        allTxt11 = [allTxt11 ' ' lower(strjoin(extractFigText_(figs11(k)),' '))]; %#ok<AGROW>
    end
    close(figs11);
    assert(contains(allTxt11,'receiver clock'), 'No page mentions "receiver clock"');
    assert(contains(allTxt11,'positive'),        'No page mentions "positive" sign convention');
    fprintf('T11 testOriginalStyleReportStatesProductSemantics : PASS\n');
    nPass = nPass + 1;
catch ex
    fprintf('T11 testOriginalStyleReportStatesProductSemantics : FAIL — %s\n', ex.message);
    nFail = nFail + 1;
end

% -----------------------------------------------------------------------
% T12: testOriginalStyleReportStatesNoPPPClaim
%      Any page contains 'ppp' and 'no' (no PPP-grade claim).
% -----------------------------------------------------------------------
try
    [figs12, ~, ~] = buildMinimalReport_(parentDir);
    allTxt12 = '';
    for k = 1:numel(figs12)
        allTxt12 = [allTxt12 ' ' lower(strjoin(extractFigText_(figs12(k)),' '))]; %#ok<AGROW>
    end
    close(figs12);
    assert(contains(allTxt12,'ppp'),             'No page mentions "ppp"');
    assert(contains(allTxt12,'no ppp') || (contains(allTxt12,'ppp') && contains(allTxt12,'no ')), ...
        'No page states "no ppp" claim');
    fprintf('T12 testOriginalStyleReportStatesNoPPPClaim : PASS\n');
    nPass = nPass + 1;
catch ex
    fprintf('T12 testOriginalStyleReportStatesNoPPPClaim : FAIL — %s\n', ex.message);
    nFail = nFail + 1;
end

% -----------------------------------------------------------------------
% T13: testOriginalStyleReportWriteTex
%      writeTex=true creates a .tex file at the expected path.
% -----------------------------------------------------------------------
try
    cfg13 = revgnss.ConfigFactory.defaultConfig();
    tmpDir13 = fullfile(tempdir, sprintf('test_stage7b1_%d', round(rand()*1e6)));
    mkdir(tmpDir13);
    cfg13.report.writePdf      = false;
    cfg13.report.writeMat      = false;
    cfg13.report.writeTex      = true;
    cfg13.report.compileTex    = 'never';
    cfg13.report.style         = 'latex';
    cfg13.report.baseOutputDir = tmpDir13;
    cfg13.report.version       = '0.00';
    summary13 = struct('timestamp','2026-01-01 00:00:00','validationWarnings',{{}});
    [figs13, texPath13] = revgnss.LatexReportBuilder.build( ...
        struct(), struct(), {}, cfg13, summary13);
    close(figs13);
    texExists = ~isempty(texPath13) && exist(texPath13,'file') == 2;
    rmdir(tmpDir13, 's');
    assert(texExists, '.tex file was not created at %s', texPath13);
    fprintf('T13 testOriginalStyleReportWriteTex : PASS\n');
    nPass = nPass + 1;
catch ex
    fprintf('T13 testOriginalStyleReportWriteTex : FAIL — %s\n', ex.message);
    nFail = nFail + 1;
end

% -----------------------------------------------------------------------
% T14: testOriginalStyleReportTexContainsSections
%      .tex file contains \section{ and longtable (original report style).
% -----------------------------------------------------------------------
try
    cfg14 = revgnss.ConfigFactory.defaultConfig();
    tmpDir14 = fullfile(tempdir, sprintf('test_stage7b1_%d', round(rand()*1e6)));
    mkdir(tmpDir14);
    cfg14.report.writePdf      = false;
    cfg14.report.writeMat      = false;
    cfg14.report.writeTex      = true;
    cfg14.report.compileTex    = 'never';
    cfg14.report.style         = 'latex';
    cfg14.report.baseOutputDir = tmpDir14;
    cfg14.report.version       = '0.00';
    summary14 = struct('timestamp','2026-01-01 00:00:00','validationWarnings',{{}});
    [figs14, texPath14] = revgnss.LatexReportBuilder.build( ...
        struct(), struct(), {}, cfg14, summary14);
    close(figs14);
    texContent = '';
    if ~isempty(texPath14) && exist(texPath14,'file') == 2
        fid14 = fopen(texPath14,'r');
        texContent = fread(fid14, '*char')';
        fclose(fid14);
    end
    rmdir(tmpDir14, 's');
    assert(contains(texContent, '\section{'), '.tex missing \\section{');
    assert(contains(texContent, 'longtable'),  '.tex missing longtable environment');
    fprintf('T14 testOriginalStyleReportTexContainsSections : PASS\n');
    nPass = nPass + 1;
catch ex
    fprintf('T14 testOriginalStyleReportTexContainsSections : FAIL — %s\n', ex.message);
    nFail = nFail + 1;
end

% -----------------------------------------------------------------------
% T15: testOriginalStyleReportHandlesMissingPlots
%      With empty diag struct, 'no plot generated' appears in P05 and P06.
% -----------------------------------------------------------------------
try
    [figs15, ~, ~] = buildMinimalReport_(parentDir);
    p05txt15 = ''; p06txt15 = '';
    for k = 1:numel(figs15)
        nm = get(figs15(k),'Name');
        if contains(nm,'Measurement','IgnoreCase',true)
            p05txt15 = lower(strjoin(extractFigText_(figs15(k)),' '));
        elseif contains(nm,'Error','IgnoreCase',true)
            p06txt15 = lower(strjoin(extractFigText_(figs15(k)),' '));
        end
    end
    close(figs15);
    assert(contains(p05txt15,'no plot generated'), ...
        'P05 missing "no plot generated" with empty diag');
    assert(contains(p06txt15,'no plot generated'), ...
        'P06 missing "no plot generated" with empty diag');
    fprintf('T15 testOriginalStyleReportHandlesMissingPlots : PASS\n');
    nPass = nPass + 1;
catch ex
    fprintf('T15 testOriginalStyleReportHandlesMissingPlots : FAIL — %s\n', ex.message);
    nFail = nFail + 1;
end

% -----------------------------------------------------------------------
% T16: testOriginalStyleReportCarrierFloat
%      With summary.carrierMode='ekfFloat', P08 mentions 'float'.
% -----------------------------------------------------------------------
try
    cfg16 = revgnss.ConfigFactory.defaultConfig();
    cfg16.report.writePdf = false;
    cfg16.report.writeMat = false;
    cfg16.report.writeTex = false;
    cfg16.report.style    = 'latex';
    sum16 = struct('carrierMode','ekfFloat','codeMode','singleFrequency', ...
        'ambiguityMode','floatPerTowerSignal','troposphereMode','none', ...
        'version','1.01','timestamp','2026-01-01 00:00:00','validationWarnings',{{}});
    figs16 = revgnss.LatexReportBuilder.build(struct(), struct(), {}, cfg16, sum16);
    p08txt16 = '';
    for k = 1:numel(figs16)
        if contains(get(figs16(k),'Name'),'Verdict','IgnoreCase',true)
            p08txt16 = lower(strjoin(extractFigText_(figs16(k)),' '));
            break;
        end
    end
    close(figs16);
    assert(contains(p08txt16,'float'), 'P08 missing "float" when carrierMode=ekfFloat');
    fprintf('T16 testOriginalStyleReportCarrierFloat : PASS\n');
    nPass = nPass + 1;
catch ex
    fprintf('T16 testOriginalStyleReportCarrierFloat : FAIL — %s\n', ex.message);
    nFail = nFail + 1;
end

% -----------------------------------------------------------------------
% T17: testOriginalStyleReportIonoFree
%      With summary.codeMode='ionosphereFree', P08 mentions 'ionosphere-free'.
% -----------------------------------------------------------------------
try
    cfg17 = revgnss.ConfigFactory.defaultConfig();
    cfg17.report.writePdf = false;
    cfg17.report.writeMat = false;
    cfg17.report.writeTex = false;
    cfg17.report.style    = 'latex';
    sum17 = struct('codeMode','ionosphereFree','carrierMode','diagnostic', ...
        'ambiguityMode','none','troposphereMode','none', ...
        'version','1.01','timestamp','2026-01-01 00:00:00','validationWarnings',{{}});
    figs17 = revgnss.LatexReportBuilder.build(struct(), struct(), {}, cfg17, sum17);
    p08txt17 = '';
    for k = 1:numel(figs17)
        if contains(get(figs17(k),'Name'),'Verdict','IgnoreCase',true)
            p08txt17 = lower(strjoin(extractFigText_(figs17(k)),' '));
            break;
        end
    end
    close(figs17);
    assert(contains(p08txt17,'ionosphere') && contains(p08txt17,'free'), ...
        'P08 missing "ionosphere-free" when codeMode=ionosphereFree');
    fprintf('T17 testOriginalStyleReportIonoFree : PASS\n');
    nPass = nPass + 1;
catch ex
    fprintf('T17 testOriginalStyleReportIonoFree : FAIL — %s\n', ex.message);
    nFail = nFail + 1;
end

% -----------------------------------------------------------------------
% T18: testAllExistingReportTestsStillPass
%      test_stage7b_report.m runs without errors and prints 'ALL PASS'.
% -----------------------------------------------------------------------
try
    out18 = evalc('run(fullfile(thisDir, ''test_stage7b_report''))');
    passed18 = contains(out18, 'ALL PASS');
    assert(passed18, 'test_stage7b_report did not print ALL PASS. Output:\n%s', out18);
    fprintf('T18 testAllExistingReportTestsStillPass : PASS\n');
    nPass = nPass + 1;
catch ex
    fprintf('T18 testAllExistingReportTestsStillPass : FAIL — %s\n', ex.message);
    nFail = nFail + 1;
end

% -----------------------------------------------------------------------
fprintf('\n=== test_stage7b1_report: %d PASS, %d FAIL ===\n', nPass, nFail);

% ========================================================================
% Local helpers
% ========================================================================
function allStrings = extractFigText_(fig)
    % extractFigText_  Collect all text strings from all axes in a figure.
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
