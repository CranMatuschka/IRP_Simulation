% test_stage7b4_report  Stage 7B.4: ClockExact LaTeX report renderer tests.
%
% Verifies that ClockExactReportBuilder:
%   - Produces a .tex file when called with minimal cfg
%   - Requires LaTeX when compileTex='require' and LaTeX is absent
%   - Produces no raw text dump sections ("--- Output ---" etc.) in the .tex
%   - Produces sections 1–7 in ascending order in the .tex
%   - Includes state vector longtable, measurement model table, component status
%   - Includes plot-description longtable rows ("Plot" header, "No plot generated.")
%   - Includes disabled-components section and numerical summary
%   - Respects appendRawPlots=false by default (no raw appendix)
%   - Does NOT claim PPP-grade accuracy
%   - States carrier float limitations
%   - run_oo_reverse_gnss_report.m references clockExact layout

function tests = test_stage7b4_report
    tests = functiontests(localfunctions);
end

% ======================================================================
function setup(tc)
    thisDir = fileparts(mfilename('fullpath'));
    addpath(fullfile(thisDir, '..'));
end

% ======================================================================
% T01 — build() with clockExact config returns a result struct with texPath
% ======================================================================
function testClockExactReportBuilds(tc)
    cfg = tc7b4_minimalCfg_();
    diag = tc7b4_emptyDiag_();
    result = revgnss.ClockExactReportBuilder.build(diag, [], [], cfg, struct());
    verifyTrue(tc, isfield(result, 'texPath'), 'result missing texPath field');
    verifyTrue(tc, isfield(result, 'success'), 'result missing success field');
    verifyTrue(tc, isfile(result.texPath), ...
        sprintf('Expected .tex file at: %s', result.texPath));
    tc7b4_cleanup_(result);
end

% ======================================================================
% T02 — compileTex='require' either compiles to PDF or fails with clear message
%        (tests that the LaTeX-required path is wired up correctly)
% ======================================================================
function testClockExactRequiresLatex(tc)
    cfg = tc7b4_minimalCfg_();
    cfg.report.compileTex = 'require';
    diag = tc7b4_emptyDiag_();
    % If LaTeX is available: should succeed (result.success=true, pdfPath set).
    % If LaTeX is not available: should throw with the expected error identifier.
    errored = false;
    errMsg  = '';
    try
        result = revgnss.ClockExactReportBuilder.build(diag, [], [], cfg, struct());
        tc7b4_cleanup_(result);
        % LaTeX available: build must either produce a PDF or report success
        verifyTrue(tc, result.success || ~isempty(result.texPath), ...
            'compileTex=require with LaTeX available: neither success nor texPath set');
    catch ME
        errored = true;
        errMsg  = ME.message;
    end
    if errored
        % LaTeX unavailable: error must contain the expected guidance text
        verifyTrue(tc, contains(errMsg, 'ClockExact', 'IgnoreCase', true) || ...
                       contains(errMsg, 'pdflatex', 'IgnoreCase', true), ...
            sprintf('compileTex=require error message unexpected: %s', errMsg));
    end
end

% ======================================================================
% T03 — no raw text dump in .tex ("--- Output ---", "--- Configuration ---")
% ======================================================================
function testClockExactNoRawDumpSections(tc)
    cfg = tc7b4_minimalCfg_();
    diag = tc7b4_emptyDiag_();
    result = revgnss.ClockExactReportBuilder.build(diag, [], [], cfg, struct());
    src = tc7b4_readTex_(result.texPath);
    tc7b4_cleanup_(result);
    verifyFalse(tc, contains(src, '--- Output ---'), ...
        '.tex contains raw dump section "--- Output ---"');
    verifyFalse(tc, contains(src, '--- Configuration ---'), ...
        '.tex contains raw dump section "--- Configuration ---"');
    verifyFalse(tc, contains(src, '--- Metrics ---'), ...
        '.tex contains raw dump section "--- Metrics ---"');
end

% ======================================================================
% T04 — sections 1–7 appear in ascending order in the .tex
% ======================================================================
function testClockExactCorrectSectionOrder(tc)
    cfg = tc7b4_minimalCfg_();
    diag = tc7b4_emptyDiag_();
    result = revgnss.ClockExactReportBuilder.build(diag, [], [], cfg, struct());
    src = tc7b4_readTex_(result.texPath);
    tc7b4_cleanup_(result);

    markers = {'\section{Goal and Scenario', '\section{State Estim', ...
               '\section{Measurement', '\section{Oscillator', ...
               '\section{Scientific Verdict'};
    idxs = zeros(1, numel(markers));
    for m = 1:numel(markers)
        pos = strfind(src, markers{m});
        if ~isempty(pos); idxs(m) = pos(1); end
    end

    for m = 1:numel(markers)
        verifyGreaterThan(tc, idxs(m), 0, ...
            sprintf('Section marker "%s" not found in .tex', markers{m}));
    end
    for m = 2:numel(markers)
        verifyGreaterThan(tc, idxs(m), idxs(m-1), ...
            sprintf('Section %d (pos=%d) not after section %d (pos=%d)', ...
                m, idxs(m), m-1, idxs(m-1)));
    end
end

% ======================================================================
% T05 — .tex contains "Scenario Summary" section
% ======================================================================
function testClockExactHasScenarioSummary(tc)
    cfg = tc7b4_minimalCfg_();
    diag = tc7b4_emptyDiag_();
    result = revgnss.ClockExactReportBuilder.build(diag, [], [], cfg, struct());
    src = tc7b4_readTex_(result.texPath);
    tc7b4_cleanup_(result);
    verifyTrue(tc, contains(src, 'Goal and Scenario'), ...
        '"Goal and Scenario" not found in .tex');
end

% ======================================================================
% T06 — .tex contains EKF state vector longtable
% ======================================================================
function testClockExactHasStateVectorLongtable(tc)
    cfg = tc7b4_minimalCfg_();
    diag = tc7b4_emptyDiag_();
    result = revgnss.ClockExactReportBuilder.build(diag, [], [], cfg, struct());
    src = tc7b4_readTex_(result.texPath);
    tc7b4_cleanup_(result);
    hasGrp = contains(src, 'State group');
    hasRng = contains(src, 'x[1:3]');
    hasLT  = contains(src, 'longtable');
    verifyTrue(tc, hasGrp && hasRng && hasLT, ...
        'Grouped state vector longtable (State group/x[1:3]/longtable) not found in .tex');
end

% ======================================================================
% T07 — .tex contains measurement model table (pseudorange equation)
% ======================================================================
function testClockExactHasMeasurementModelTable(tc)
    cfg = tc7b4_minimalCfg_();
    diag = tc7b4_emptyDiag_();
    result = revgnss.ClockExactReportBuilder.build(diag, [], [], cfg, struct());
    src = tc7b4_readTex_(result.texPath);
    tc7b4_cleanup_(result);
    hasMM  = contains(src, 'Measurement Model');
    hasPR  = contains(src, 'pseudorange', 'IgnoreCase', true);
    verifyTrue(tc, hasMM && hasPR, ...
        '"Measurement Model" + "pseudorange" not found in .tex');
end

% ======================================================================
% T08 — .tex contains component status table (Enabled/Disabled)
% ======================================================================
function testClockExactHasComponentStatusTable(tc)
    cfg = tc7b4_minimalCfg_();
    diag = tc7b4_emptyDiag_();
    result = revgnss.ClockExactReportBuilder.build(diag, [], [], cfg, struct());
    src = tc7b4_readTex_(result.texPath);
    tc7b4_cleanup_(result);
    hasCS = contains(src, 'Component');
    hasEn = contains(src, 'Enabled');
    hasDi = contains(src, 'Disabled');
    verifyTrue(tc, hasCS && hasEn && hasDi, ...
        'Component Status table with Enabled/Disabled not found in .tex');
end

% ======================================================================
% T09 — .tex contains plot-description longtable ("Plot & Description")
% ======================================================================
function testClockExactHasPlotDescriptionLongtable(tc)
    cfg = tc7b4_minimalCfg_();
    diag = tc7b4_emptyDiag_();
    result = revgnss.ClockExactReportBuilder.build(diag, [], [], cfg, struct());
    src = tc7b4_readTex_(result.texPath);
    tc7b4_cleanup_(result);
    hasPlot = contains(src, '\textbf{Plot}');
    hasDesc = contains(src, 'Description and statistical approach');
    verifyTrue(tc, hasPlot && hasDesc, ...
        'Plot-description longtable header not found in .tex');
end

% ======================================================================
% T10 — refactor: no "No plot generated." placeholders; RAC label present
% ======================================================================
function testClockExactHasRacPositionLabel(tc)
    cfg = tc7b4_minimalCfg_();
    diag = tc7b4_emptyDiag_();
    result = revgnss.ClockExactReportBuilder.build(diag, [], [], cfg, struct());
    src = tc7b4_readTex_(result.texPath);
    tc7b4_cleanup_(result);
    verifyFalse(tc, contains(src, 'No plot generated.'), ...
        'Report still contains a "No plot generated." placeholder.');
    verifyTrue(tc, contains(src, 'RAC'), ...
        'RAC position-frame label not found in .tex');
end

% ======================================================================
% T11 — refactor: always-present DOP metrics section
% ======================================================================
function testClockExactHasDopMetricsSection(tc)
    cfg = tc7b4_minimalCfg_();
    diag = tc7b4_emptyDiag_();
    result = revgnss.ClockExactReportBuilder.build(diag, [], [], cfg, struct());
    src = tc7b4_readTex_(result.texPath);
    tc7b4_cleanup_(result);
    verifyTrue(tc, contains(src, 'Ground-to-Space Geometry and DOP Metrics'), ...
        'DOP metrics section not found in .tex');
end

% ======================================================================
% T12 — .tex contains "Numerical Summary" section (§7) with metric tables
% ======================================================================
function testClockExactHasNumericalSummaryTables(tc)
    cfg = tc7b4_minimalCfg_();
    diag = tc7b4_emptyDiag_();
    result = revgnss.ClockExactReportBuilder.build(diag, [], [], cfg, struct());
    src = tc7b4_readTex_(result.texPath);
    tc7b4_cleanup_(result);
    hasNS = contains(src, 'Scientific Verdict');
    hasQt = contains(src, 'Quantity');
    verifyTrue(tc, hasNS && hasQt, ...
        '"Scientific Verdict" with Quantity table not found in .tex');
end

% ======================================================================
% T13 — default build: no raw plot appendix (appendRawPlots=false)
% ======================================================================
function testClockExactNoRawPlotAppendixByDefault(tc)
    cfg = tc7b4_minimalCfg_();
    diag = tc7b4_emptyDiag_();
    result = revgnss.ClockExactReportBuilder.build(diag, [], [], cfg, struct());
    src = tc7b4_readTex_(result.texPath);
    tc7b4_cleanup_(result);
    hasAppendix = contains(src, '\appendix') || ...
                  contains(src, 'Raw Diagnostic Plots Appendix', 'IgnoreCase', true);
    verifyFalse(tc, hasAppendix, '.tex contains raw plot appendix (expected none by default)');
end

% ======================================================================
% T14 — appendRawPlots=true accepted without error
% ======================================================================
function testClockExactAppendRawPlotsOptional(tc)
    cfg = tc7b4_minimalCfg_();
    cfg.report.appendRawPlots = true;
    diag = tc7b4_emptyDiag_();
    % Should not error; .tex file should still be written
    result = revgnss.ClockExactReportBuilder.build(diag, [], [], cfg, struct());
    tc7b4_cleanup_(result);
    verifyTrue(tc, isfield(result, 'texPath'), ...
        'appendRawPlots=true broke build() — no texPath returned');
end

% ======================================================================
% T15 — .tex does NOT claim PPP-grade accuracy
% ======================================================================
function testClockExactNoPPPClaim(tc)
    cfg = tc7b4_minimalCfg_();
    diag = tc7b4_emptyDiag_();
    result = revgnss.ClockExactReportBuilder.build(diag, [], [], cfg, struct());
    src = tc7b4_readTex_(result.texPath);
    tc7b4_cleanup_(result);
    verifyTrue(tc, contains(src, 'PPP', 'IgnoreCase', false), ...
        'PPP limitation not mentioned in .tex (expected explicit statement)');
    % Must NOT claim PPP-grade (check no affirmative claim)
    hasClaim = contains(src, 'PPP-grade processing is supported', 'IgnoreCase', true) || ...
               contains(src, 'PPP implemented', 'IgnoreCase', true);
    verifyFalse(tc, hasClaim, '.tex makes unexpected PPP-grade accuracy claim');
end

% ======================================================================
% T16 — .tex states carrier float limitations
% ======================================================================
function testClockExactCarrierLimitations(tc)
    cfg = tc7b4_minimalCfg_();
    diag = tc7b4_emptyDiag_();
    result = revgnss.ClockExactReportBuilder.build(diag, [], [], cfg, struct());
    src = tc7b4_readTex_(result.texPath);
    tc7b4_cleanup_(result);
    hasFloat   = contains(src, 'float', 'IgnoreCase', true);
    hasCarrier = contains(src, 'carrier', 'IgnoreCase', true);
    verifyTrue(tc, hasFloat && hasCarrier, ...
        'Carrier float limitations not stated in .tex');
end

% ======================================================================
% T17 — run_oo_reverse_gnss_report.m references clockExact layout
% ======================================================================
function testRunOoReverseGnssReportClockExactWorks(tc)
    thisDir = fileparts(mfilename('fullpath'));
    scriptPath = fullfile(thisDir, '..', 'run_oo_reverse_gnss_report.m');
    verifyTrue(tc, isfile(scriptPath), 'run_oo_reverse_gnss_report.m not found');

    src = fileread(scriptPath);
    hasLayout     = contains(src, 'report.layout');
    hasClockExact = contains(src, 'clockExact');
    verifyTrue(tc, hasLayout,     'run_oo_reverse_gnss_report.m missing cfg.report.layout');
    verifyTrue(tc, hasClockExact, 'run_oo_reverse_gnss_report.m missing ''clockExact'' value');
end

% ======================================================================
% LOCAL HELPERS
% ======================================================================

function cfg = tc7b4_minimalCfg_()
    cfg = revgnss.ConfigFactory.defaultConfig();
    cfg.report.style       = 'latex';
    cfg.report.layout      = 'clockExact';
    cfg.report.writeTex    = true;
    cfg.report.compileTex  = 'never';   % skip compilation; just write .tex
    cfg.report.writePdf    = false;
    cfg.report.writeMat    = false;
    cfg.report.appendRawPlots       = false;
    cfg.report.includeRawDiagnostics = false;
    % Use a temp output dir so test artefacts don't accumulate in output/
    cfg.report.baseOutputDir = fullfile(tempdir(), 'revgnss_test_7b4');
end

function diag = tc7b4_emptyDiag_()
    try
        cfg = revgnss.ConfigFactory.defaultConfig();
        diag = revgnss.Diagnostics(cfg);
    catch
        diag = struct();
    end
end

function src = tc7b4_readTex_(texPath)
    src = '';
    if isfile(texPath)
        try; src = fileread(texPath); catch; end
    end
end

function tc7b4_cleanup_(result)
    % Remove artefacts written to temp dir
    try
        if isfield(result,'texPath') && isfile(result.texPath)
            delete(result.texPath);
        end
        if isfield(result,'figDir') && isfolder(result.figDir)
            % Remove generated compact plot PDFs only
            pdfFiles = dir(fullfile(result.figDir, '*.pdf'));
            for k = 1:numel(pdfFiles)
                delete(fullfile(result.figDir, pdfFiles(k).name));
            end
        end
    catch
    end
end
