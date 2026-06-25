function run_stage27_validation()
% run_stage27_validation  Stage 27 validation gate.
%
% Stage 27: Validation Artifact Closure + Real PDF Text Verification.
%
% Procedure:
%   1. Select 4 tests (seed 27); force at least one test_stage27* or test_stage26*.
%   2. Run selected tests. If any fail: write partial summary and STOP.
%   3. Write PRELIMINARY latest_validation_summary.json (stage=27, invokedMainScript=true)
%      so the generated PDF already shows Stage 27 in its validation section.
%   4. Run run_oo_reverse_gnss_report literally via env vars (all toggles).
%   5. Verify PDF using pdftotext (real text extraction).
%      TEX fallback if pdftotext unavailable (pdfTextVerified stays false).
%   6. Write final latest_validation_summary.json + .txt.
%   7. Write notion_stage27_update.md.
%
% Usage:
%   cd oo_v1
%   run_stage27_validation

    rootDir = fileparts(mfilename('fullpath'));
    testDir = fullfile(rootDir, 'tests');
    outDir  = fullfile(rootDir, 'output');
    if ~exist(outDir, 'dir'); mkdir(outDir); end

    fprintf('=== Stage 27 Validation Gate ===\n\n');

    % ---- Phase 1: Test selection (seed 27, force stage27/stage26 test) ----
    fprintf('[1/5] Selecting smoke tests (seed 27, forcing stage27/26 test)...\n');
    files = s27_selectWithStage_(testDir, 27, 4);
    results = revgnss.ValidationRunner.runSelected(files, rootDir);
    revgnss.ValidationRunner.printSummary(results);

    [nPass, nTot] = revgnss.ValidationRunner.countResults(results);

    % Persist before any workspace clear
    assignin('base', 'oo_v1_s27_results_',    results);
    assignin('base', 'oo_v1_s27_script_ok_',  false);
    assignin('base', 'oo_v1_s27_script_err_', '');

    % ---- Stop on test failure ----
    if nPass < nTot
        fprintf('\n[STOP] %d / %d tests failed. Stopping before report run.\n', ...
            nTot - nPass, nTot);
        sha_    = s27_gitSHA_(rootDir);
        branch_ = s27_gitBranch_(rootDir);
        partial              = struct();
        partial.stage        = 27;
        partial.stageTitle   = 'Validation Artifact Closure + Real PDF Text Verification';
        partial.branch       = branch_;
        partial.gitSHA       = sha_;
        partial.timestamp    = datestr(now, 'yyyy-mm-ddTHH:MM:SS'); %#ok<TNOW1,DATST>
        partial.matlabVersion = version;
        partial.testSeed     = 27;
        partial.nSelectedTests        = nTot;
        partial.nPassingSelectedTests = nPass;
        partial.selectedTestNames     = {results.name};
        partial.currentStageSmokeTestIncluded = s27_hasStageTest_(files, {'27','26'});
        partial.fullSuiteRun          = false;
        partial.allToggleReportRun    = false;
        partial.reportRunPassed       = false;
        partial.invokedMainScript     = false;
        partial.pdfVerified           = false;
        partial.pdfTextVerified       = false;
        partial.texVerified           = false;
        partial.pdfPath               = '';
        partial.validationWarnings    = {};
        partial.notes = sprintf( ...
            'Stage 27 STOPPED: %d / %d tests failed. Report not run.', ...
            nTot - nPass, nTot);
        revgnss.ValidationSummary.write(outDir, partial);
        fprintf('Partial summary written to output/latest_validation_summary.json\n');
        return
    end

    % ---- Phase 2: Write PRELIMINARY summary (so PDF reads Stage 27) ----
    fprintf('[2/5] Writing preliminary summary (stage=27)...\n');
    sha_pre    = s27_gitSHA_(rootDir);
    branch_pre = s27_gitBranch_(rootDir);
    prelim              = struct();
    prelim.stage        = 27;
    prelim.stageTitle   = 'Validation Artifact Closure + Real PDF Text Verification';
    prelim.branch       = branch_pre;
    prelim.gitSHA       = sha_pre;
    prelim.timestamp    = datestr(now, 'yyyy-mm-ddTHH:MM:SS'); %#ok<TNOW1,DATST>
    prelim.matlabVersion = version;
    prelim.testSeed     = 27;
    prelim.nSelectedTests        = nTot;
    prelim.nPassingSelectedTests = nPass;
    prelim.selectedTestNames     = {results.name};
    prelim.currentStageSmokeTestIncluded = s27_hasStageTest_(files, {'27','26'});
    prelim.fullSuiteRun          = false;
    prelim.allToggleReportRun    = false;
    prelim.reportRunPassed       = false;
    prelim.invokedMainScript     = true;   % will be invoked next
    prelim.pdfVerified           = false;
    prelim.pdfTextVerified       = false;
    prelim.texVerified           = false;
    prelim.pdfPath               = '';
    prelim.validationWarnings    = {};
    prelim.notes                 = 'Preliminary summary — PDF not yet generated.';
    revgnss.ValidationSummary.write(outDir, prelim);

    % ---- Phase 3: Execute main script literally via env vars ----
    fprintf('[3/5] Running run_oo_reverse_gnss_report with all toggles...\n');
    setenv('OO_V1_ALL_TOGGLES',        'true');
    setenv('OO_V1_VALIDATION_STAGE',   '27');
    setenv('OO_V1_REPORT_COMPILE_TEX', 'auto');
    try
        run_oo_reverse_gnss_report;
        assignin('base', 'oo_v1_s27_script_ok_', true);
    catch scrErr_
        assignin('base', 'oo_v1_s27_script_err_', scrErr_.message);
    end
    setenv('OO_V1_ALL_TOGGLES',        '');
    setenv('OO_V1_VALIDATION_STAGE',   '');
    setenv('OO_V1_REPORT_COMPILE_TEX', '');

    % ---- Phase 4: Collect results (re-derive paths after clear) ----
    fprintf('[4/5] Collecting results...\n');
    rootDir2 = fileparts(mfilename('fullpath'));
    outDir2  = fullfile(rootDir2, 'output');

    results2         = evalin('base', 'oo_v1_s27_results_');
    [nPass2, nTot2]  = revgnss.ValidationRunner.countResults(results2);
    reportRunPassed  = evalin('base', 'oo_v1_s27_script_ok_');
    scriptErrMsg     = evalin('base', 'oo_v1_s27_script_err_');

    out2 = struct('pdfPath', '');
    if reportRunPassed
        try; out2 = evalin('base', 'oo_v1_last_report_out'); catch; end
    end

    % ---- Phase 5: Verify PDF text ----
    fprintf('[5/5] Verifying report artifacts...\n');
    sha_fin    = s27_gitSHA_(rootDir2);
    branch_fin = s27_gitBranch_(rootDir2);

    pdfOk = false; pdfTextOk = false; texOk = false;
    pdfPath = '';
    warnings_ = {};
    if isfield(out2, 'pdfPath') && ~isempty(out2.pdfPath)
        pdfPath = out2.pdfPath;
        [pdfOk, pdfTextOk, texOk, newWarnings] = s27_verifyReport_(pdfPath, sha_fin, nPass2, nTot2);
        warnings_ = [warnings_, newWarnings];
    end

    % ---- Write final validation summary ----
    data                              = struct();
    data.stage                        = 27;
    data.stageTitle                   = 'Validation Artifact Closure + Real PDF Text Verification';
    data.branch                       = branch_fin;
    data.gitSHA                       = sha_fin;
    data.timestamp                    = datestr(now, 'yyyy-mm-ddTHH:MM:SS'); %#ok<TNOW1,DATST>
    data.matlabVersion                = version;
    data.testSeed                     = 27;
    data.nSelectedTests               = nTot2;
    data.nPassingSelectedTests        = nPass2;
    data.selectedTestNames            = {results2.name};
    stageTestIncluded_ = false;
    try
        files2_ = evalin('base', 'oo_v1_s27_files_');
        stageTestIncluded_ = s27_hasStageTest_(files2_, {'27','26'});
    catch; end
    data.currentStageSmokeTestIncluded = stageTestIncluded_;
    data.fullSuiteRun                 = false;
    data.allToggleReportRun           = reportRunPassed;
    data.reportRunPassed              = reportRunPassed;
    data.invokedMainScript            = true;
    data.pdfVerified                  = pdfOk;
    data.pdfTextVerified              = pdfTextOk;
    data.texVerified                  = texOk;
    data.pdfPath                      = pdfPath;
    data.validationWarnings           = warnings_;
    data.notes = sprintf( ...
        'Stage 27 targeted smoke (%d/%d passed) + all-toggle main-script run. Full suite NOT RUN.', ...
        nPass2, nTot2);
    if ~isempty(scriptErrMsg)
        data.notes = [data.notes ' SCRIPT ERROR: ' scriptErrMsg(1:min(end,200))];
    end

    revgnss.ValidationSummary.write(outDir2, data);
    s27_writeNotionUpdate_(outDir2, data, results2, branch_fin, sha_fin);

    % ---- Final summary printout ----
    allOk = (nPass2 == nTot2) && reportRunPassed && pdfOk;
    fprintf('\n=== Stage 27 Validation Summary ===\n');
    fprintf('Branch          : %s\n', branch_fin);
    fprintf('SHA             : %s\n', sha_fin);
    fprintf('Smoke tests     : %d / %d selected passed\n', nPass2, nTot2);
    fprintf('Main script run : %s\n', s27_passStr_(reportRunPassed));
    fprintf('PDF verified    : %s\n', s27_passStr_(pdfOk));
    fprintf('PDF text check  : %s\n', s27_passStr_(pdfTextOk));
    fprintf('TEX fallback    : %s\n', s27_passStr_(texOk));
    if ~isempty(warnings_)
        fprintf('Warnings        : %d\n', numel(warnings_));
        for k = 1:numel(warnings_)
            fprintf('  - %s\n', warnings_{k});
        end
    end
    fprintf('Overall         : %s\n', s27_passStr_(allOk));
    fprintf('\nArtifacts written to:\n  %s\n', outDir2);
    fprintf('  latest_validation_summary.json\n');
    fprintf('  latest_validation_summary.txt\n');
    fprintf('  notion_stage27_update.md\n\n');
end

% ---- Local helper functions ----

function files = s27_selectWithStage_(testDir, seed, count)
    % Select tests, forcing at least one test_stage27* or test_stage26* file.
    tmp = dir(fullfile(testDir, 'test_*.m'));
    if isempty(tmp)
        files = {};
        return
    end
    allFiles = sort({tmp.name});

    % Find stage-matching candidates (prefer test_stage27*, then test_stage26*)
    forced = '';
    for pat = {'test_stage27', 'test_stage26'}
        for k = 1:numel(allFiles)
            if strncmpi(allFiles{k}, pat{1}, numel(pat{1}))
                forced = allFiles{k};
                break
            end
        end
        if ~isempty(forced); break; end
    end

    % Fill the rest randomly
    s = RandStream('mt19937ar', 'Seed', seed);
    perm = randperm(s, numel(allFiles));
    n    = min(count, numel(allFiles));
    selected = allFiles(sort(perm(1:n)));

    if ~isempty(forced) && ~any(strcmp(selected, forced))
        selected{end} = forced;
        selected = sort(selected);
    end
    files = selected;

    % Save files to base workspace for later reference
    assignin('base', 'oo_v1_s27_files_', files);
end

function tf = s27_hasStageTest_(files, stageTags)
    tf = false;
    for k = 1:numel(files)
        for j = 1:numel(stageTags)
            if contains(files{k}, ['test_stage' stageTags{j}])
                tf = true; return
            end
        end
    end
end

function [pdfOk, pdfTextOk, texOk, warnings] = s27_verifyReport_(pdfPath, sha, nPass, nTot)
    pdfOk = false; pdfTextOk = false; texOk = false; warnings = {};

    if ~exist(pdfPath, 'file')
        warnings{end+1} = 'PDF file not found.';
        return
    end
    info = dir(pdfPath);
    pdfOk = info.bytes > 50000;
    if ~pdfOk
        warnings{end+1} = sprintf('PDF too small: %d bytes', info.bytes);
    end

    % Try real PDF text extraction via pdftotext
    [status, pdfText] = system(sprintf('pdftotext "%s" - 2>/dev/null', pdfPath));
    if status == 0 && ~isempty(strtrim(pdfText))
        pdfTextOk = s27_checkPdfText_(pdfText, '27', sha, nPass, nTot);
        if ~pdfTextOk
            warnings{end+1} = sprintf( ...
                'PDF text check failed: missing expected tokens (Stage 27, SHA %s, %d/%d).', ...
                sha, nPass, nTot);
        end
        return
    end

    % pdftotext unavailable — TEX fallback
    warnings{end+1} = 'pdftotext unavailable; using TEX fallback (pdfTextVerified=false).';
    texPath = strrep(pdfPath, '.pdf', '.tex');
    if exist(texPath, 'file')
        try
            txt = fileread(texPath);
            texOk = ~isempty(strfind(txt, 'NOT RUN')) && ... %#ok<STREMP>
                    ~isempty(strfind(txt, 'Stage 27')); %#ok<STREMP>
            if ~texOk
                warnings{end+1} = 'TEX check: missing "NOT RUN" or "Stage 27" in .tex source.';
            end
        catch; end
    end
end

function ok = s27_checkPdfText_(txt, stage, sha, nPass, nTot)
    ok = true;
    countStr = sprintf('%d / %d', nPass, nTot);
    tokens = {['Stage ' stage], sha, countStr, 'NOT RUN', 'Main script'};
    for k = 1:numel(tokens)
        if isempty(strfind(txt, tokens{k})) %#ok<STREMP>
            ok = false; return
        end
    end
end

function sha = s27_gitSHA_(rootDir)
    sha = 'unknown';
    try
        [s, o] = system(sprintf('git -C "%s" rev-parse --short HEAD 2>/dev/null', rootDir));
        if s == 0; sha = strtrim(o); end
    catch; end
end

function br = s27_gitBranch_(rootDir)
    br = 'unknown';
    try
        [s, o] = system(sprintf('git -C "%s" rev-parse --abbrev-ref HEAD 2>/dev/null', rootDir));
        if s == 0; br = strtrim(o); end
    catch; end
end

function str = s27_passStr_(ok)
    if ok; str = 'PASS'; else; str = 'FAIL'; end
end

function s27_writeNotionUpdate_(outDir, data, results, branch, sha)
    fPath = fullfile(outDir, 'notion_stage27_update.md');
    fid   = fopen(fPath, 'w', 'n', 'UTF-8');
    if fid < 0; return; end
    fprintf(fid, '## Stage 27 Validation Update\n\n');
    fprintf(fid, '| Item | Value |\n');
    fprintf(fid, '|------|-------|\n');
    fprintf(fid, '| Stage | 27 --- %s |\n', data.stageTitle);
    fprintf(fid, '| Branch | `%s` |\n', branch);
    fprintf(fid, '| Commit SHA | `%s` |\n', sha);
    fprintf(fid, '| Timestamp | %s |\n', data.timestamp);
    fprintf(fid, '| Tests selected | %d / %d passed |\n', ...
        data.nPassingSelectedTests, data.nSelectedTests);
    fprintf(fid, '| Stage smoke test included | %s |\n', mat2str(data.currentStageSmokeTestIncluded));
    fprintf(fid, '| Full suite | **NOT RUN** |\n');
    fprintf(fid, '| Main script invoked literally | yes |\n');
    fprintf(fid, '| All toggles | %s |\n', mat2str(data.allToggleReportRun));
    fprintf(fid, '| PDF verified | %s |\n', mat2str(data.pdfVerified));
    fprintf(fid, '| PDF text verified | %s |\n', mat2str(data.pdfTextVerified));
    fprintf(fid, '| TEX verified (fallback) | %s |\n', mat2str(data.texVerified));
    if ~isempty(data.validationWarnings)
        fprintf(fid, '\n### Warnings\n\n');
        for k = 1:numel(data.validationWarnings)
            fprintf(fid, '- %s\n', data.validationWarnings{k});
        end
    end
    fprintf(fid, '\n### Selected tests\n\n');
    for k = 1:numel(results)
        if results(k).passed
            fprintf(fid, '- [x] `%s`\n', results(k).name);
        else
            fprintf(fid, '- [ ] `%s` --- %s\n', results(k).name, results(k).message);
        end
    end
    fprintf(fid, '\n*Generated by `run_stage27_validation` on %s*\n', data.timestamp);
    fclose(fid);
end
