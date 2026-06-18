function run_stage25_26_validation()
% run_stage25_26_validation  Stage 25-26 script-exact validation gate.
%
% Stage 25: executes run_oo_reverse_gnss_report LITERALLY via environment
%   variables — not via ReportRunner.runSingle. This proves the user-facing
%   script works end-to-end with all toggles enabled.
%
% Stage 26: orbit dynamics tests included in the random-selected test pool.
%
% Procedure:
%   1. Randomly select 4 tests (seed 25) from tests/test_*.m.
%   2. Run them. Save results to base workspace before main script clears locals.
%   3. Set OO_V1_ALL_TOGGLES=true, OO_V1_VALIDATION_STAGE=25,
%      OO_V1_REPORT_COMPILE_TEX=auto; call run_oo_reverse_gnss_report.
%      Note: that script starts with 'clear', wiping local workspace.
%   4. Read output from base workspace (assignin'd by main script).
%   5. Verify PDF/TEX; write latest_validation_summary.json + .txt.
%   6. Write notion_stage25_26_update.md.
%
% Usage:
%   cd oo_v1
%   run_stage25_26_validation

    rootDir = fileparts(mfilename('fullpath'));
    testDir = fullfile(rootDir, 'tests');

    fprintf('=== Stage 25-26 Validation Gate ===\n\n');

    % ---- Phase 1: Targeted random smoke tests (seed 25) ----
    fprintf('[1/4] Selecting smoke tests (seed 25)...\n');
    files   = revgnss.ValidationRunner.selectTests(testDir, 25, 4);
    results = revgnss.ValidationRunner.runSelected(files, rootDir);
    revgnss.ValidationRunner.printSummary(results);

    % Persist to base workspace — main script's 'clear' will wipe local workspace.
    assignin('base', 'oo_v1_s2526_results_',    results);
    assignin('base', 'oo_v1_s2526_script_ok_',  false);
    assignin('base', 'oo_v1_s2526_script_err_', '');

    % ---- Phase 2: Execute main script literally via env vars ----
    fprintf('[2/4] Running run_oo_reverse_gnss_report with all toggles...\n');
    setenv('OO_V1_ALL_TOGGLES',        'true');
    setenv('OO_V1_VALIDATION_STAGE',   '25');
    setenv('OO_V1_REPORT_COMPILE_TEX', 'auto');
    try
        run_oo_reverse_gnss_report;
        % The script starts with 'clear' — local workspace is now cleared.
        % Variables set by the script after its 'clear' (out, cfg, etc.) ARE
        % in our local workspace; pre-script vars (results, rootDir) are NOT.
        assignin('base', 'oo_v1_s2526_script_ok_', true);
    catch scrErr_
        assignin('base', 'oo_v1_s2526_script_err_', scrErr_.message);
    end
    setenv('OO_V1_ALL_TOGGLES',        '');
    setenv('OO_V1_VALIDATION_STAGE',   '');
    setenv('OO_V1_REPORT_COMPILE_TEX', '');

    % ---- Phase 3: Collect results ----
    % Local workspace was cleared by main script's 'clear'. Re-derive paths.
    fprintf('[3/4] Collecting results...\n');
    rootDir2 = fileparts(mfilename('fullpath'));
    outDir2  = fullfile(rootDir2, 'output');

    results2        = evalin('base', 'oo_v1_s2526_results_');
    [nPass2, nTot2] = revgnss.ValidationRunner.countResults(results2);
    reportRunPassed = evalin('base', 'oo_v1_s2526_script_ok_');
    scriptErrMsg    = evalin('base', 'oo_v1_s2526_script_err_');

    out2 = struct('pdfPath', '');
    if reportRunPassed
        try; out2 = evalin('base', 'oo_v1_last_report_out'); catch; end
    end

    % ---- Phase 4: Verify PDF / TEX ----
    fprintf('[4/4] Verifying report artifacts...\n');
    pdfOk = false; pdfTextOk = false; pdfPath = '';
    if isfield(out2, 'pdfPath') && ~isempty(out2.pdfPath)
        pdfPath = out2.pdfPath;
        [pdfOk, pdfTextOk] = s2526_verifyReport_(pdfPath);
    end

    % ---- Write validation summary ----
    sha    = s2526_gitSHA_(rootDir2);
    branch = s2526_gitBranch_(rootDir2);

    data                       = struct();
    data.stage                 = 25;
    data.stageTitle            = 'Script-Exact Validation Gate + Orbit Dynamics Foundation';
    data.branch                = branch;
    data.gitSHA                = sha;
    data.timestamp             = datestr(now, 'yyyy-mm-ddTHH:MM:SS'); %#ok<TNOW1,DATST>
    data.matlabVersion         = version;
    data.testSeed              = 25;
    data.nSelectedTests        = nTot2;
    data.nPassingSelectedTests = nPass2;
    data.selectedTestNames     = {results2.name};
    data.fullSuiteRun          = false;
    data.allToggleReportRun    = reportRunPassed;
    data.reportRunPassed       = reportRunPassed;
    data.invokedMainScript     = true;
    data.pdfVerified           = pdfOk;
    data.pdfTextVerified       = pdfTextOk;
    data.pdfPath               = pdfPath;
    data.validationWarnings    = {};
    data.notes                 = sprintf( ...
        'Stage 25-26 targeted smoke (%d/%d passed) + all-toggle main-script run. Full suite NOT RUN.', ...
        nPass2, nTot2);
    if ~isempty(scriptErrMsg)
        data.notes = [data.notes ' SCRIPT ERROR: ' scriptErrMsg(1:min(end,200))];
    end

    revgnss.ValidationSummary.write(outDir2, data);

    s2526_writeNotionUpdate_(outDir2, data, results2, branch, sha);

    % ---- Final summary printout ----
    allOk = (nPass2 == nTot2) && reportRunPassed && pdfOk;
    fprintf('\n=== Stage 25-26 Validation Summary ===\n');
    fprintf('Branch          : %s\n', branch);
    fprintf('SHA             : %s\n', sha);
    fprintf('Smoke tests     : %d / %d selected passed\n', nPass2, nTot2);
    fprintf('Main script run : %s\n', s2526_passStr_(reportRunPassed));
    fprintf('PDF verified    : %s\n', s2526_passStr_(pdfOk));
    fprintf('PDF text check  : %s\n', s2526_passStr_(pdfTextOk));
    fprintf('Overall         : %s\n', s2526_passStr_(allOk));
    fprintf('\nArtifacts written to:\n  %s\n', outDir2);
    fprintf('  latest_validation_summary.json\n');
    fprintf('  latest_validation_summary.txt\n');
    fprintf('  notion_stage25_26_update.md\n\n');
end

% ---- Local helper functions ----

function [pdfOk, texOk] = s2526_verifyReport_(pdfPath)
    pdfOk = false; texOk = false;
    if exist(pdfPath, 'file')
        info = dir(pdfPath);
        pdfOk = info.bytes > 50000;
    end
    texPath = strrep(pdfPath, '.pdf', '.tex');
    if exist(texPath, 'file')
        try
            txt = fileread(texPath);
            texOk = ~isempty(strfind(txt, 'NOT RUN')); %#ok<STREMP>
        catch; end
    end
end

function sha = s2526_gitSHA_(rootDir)
    sha = 'unknown';
    try
        [s, o] = system(sprintf('git -C "%s" rev-parse --short HEAD 2>/dev/null', rootDir));
        if s == 0; sha = strtrim(o); end
    catch; end
end

function br = s2526_gitBranch_(rootDir)
    br = 'unknown';
    try
        [s, o] = system(sprintf('git -C "%s" rev-parse --abbrev-ref HEAD 2>/dev/null', rootDir));
        if s == 0; br = strtrim(o); end
    catch; end
end

function str = s2526_passStr_(ok)
    if ok; str = 'PASS'; else; str = 'FAIL'; end
end

function s2526_writeNotionUpdate_(outDir, data, results, branch, sha)
    fPath = fullfile(outDir, 'notion_stage25_26_update.md');
    fid   = fopen(fPath, 'w', 'n', 'UTF-8');
    if fid < 0; return; end
    fprintf(fid, '## Stage 25-26 Validation Update\n\n');
    fprintf(fid, '| Item | Value |\n');
    fprintf(fid, '|------|-------|\n');
    fprintf(fid, '| Stage | 25-26 — %s |\n', data.stageTitle);
    fprintf(fid, '| Branch | `%s` |\n', branch);
    fprintf(fid, '| Commit SHA | `%s` |\n', sha);
    fprintf(fid, '| Timestamp | %s |\n', data.timestamp);
    fprintf(fid, '| Tests selected | %d / %d passed |\n', ...
        data.nPassingSelectedTests, data.nSelectedTests);
    fprintf(fid, '| Full suite | **NOT RUN** |\n');
    fprintf(fid, '| Main script invoked literally | yes |\n');
    fprintf(fid, '| All toggles | %s |\n', mat2str(data.allToggleReportRun));
    fprintf(fid, '| PDF verified | %s |\n', mat2str(data.pdfVerified));
    fprintf(fid, '| PDF text verified | %s |\n', mat2str(data.pdfTextVerified));
    fprintf(fid, '\n### Selected tests\n\n');
    for k = 1:numel(results)
        if results(k).passed
            fprintf(fid, '- [x] `%s`\n', results(k).name);
        else
            fprintf(fid, '- [ ] `%s` — %s\n', results(k).name, results(k).message);
        end
    end
    fprintf(fid, '\n*Generated by `run_stage25_26_validation` on %s*\n', data.timestamp);
    fclose(fid);
end
