classdef MainScriptValidationGate
    % MainScriptValidationGate  Validation gate for run_oo_reverse_gnss_report.
    %
    % Encapsulates test selection, stop-on-failure, preliminary summary, and
    % post-run PDF verification so run_oo_reverse_gnss_report stays clean.
    %
    % Usage:
    %   if revgnss.MainScriptValidationGate.isEnabled()
    %       [cfg, state, ok] = revgnss.MainScriptValidationGate.preRun(cfg, thisDir);
    %       if ~ok; return; end
    %   end
    %   out = revgnss.ReportRunner.runSingle(cfg);
    %   if revgnss.MainScriptValidationGate.isEnabled()
    %       revgnss.MainScriptValidationGate.postRun(state, out);
    %   end

    methods (Static)

        function ok = isEnabled()
            % isEnabled  True when OO_V1_VALIDATE_REPORT == 'true'.
            ok = strcmpi(getenv('OO_V1_VALIDATE_REPORT'), 'true');
        end

        function [cfg, state, shouldContinue] = preRun(cfg, thisDir)
            % preRun  Select 2-5 tests, run them, write preliminary summary.
            %   Returns shouldContinue=false if selected tests fail.

            shouldContinue = false;
            state = struct();

            % Resolve stage, seed, count from env vars.
            stg = 66;
            v = str2double(getenv('OO_V1_VALIDATION_STAGE'));
            if ~isnan(v) && v > 0; stg = round(v); end

            seed = 66;
            v = str2double(getenv('OO_V1_RANDOM_TEST_SEED'));
            if ~isnan(v) && isfinite(v); seed = round(v); end

            cnt = 4;
            v = str2double(getenv('OO_V1_RANDOM_TEST_COUNT'));
            if ~isnan(v) && isfinite(v); cnt = max(2, min(5, round(v))); end

            stgTitle = revgnss.MainScriptValidationGate.stageTitle_(stg);

            fprintf('\n[ValidationGate] Stage %d  seed %d  count %d\n', stg, seed, cnt);

            % Select and run tests.
            testDir = fullfile(thisDir, 'tests');
            files   = revgnss.MainScriptValidationGate.pickTests_(testDir, seed, cnt, stg);
            results = revgnss.ValidationRunner.runSelected(files, thisDir);
            revgnss.ValidationRunner.printSummary(results);
            [nPass, nTot] = revgnss.ValidationRunner.countResults(results);

            % Build state struct.
            outDir         = fullfile(thisDir, 'output');
            state.stage    = stg;
            state.stageTitle = stgTitle;
            state.seed     = seed;
            state.sha      = revgnss.MainScriptValidationGate.gitSHA_(thisDir);
            state.branch   = revgnss.MainScriptValidationGate.gitBranch_(thisDir);
            state.results  = results;
            state.nPass    = nPass;
            state.nTot     = nTot;
            state.outDir   = outDir;

            % Stop before report on any test failure.
            if nPass < nTot
                fprintf('[ValidationGate] %d test(s) failed — stopping before report.\n', nTot - nPass);
                revgnss.MainScriptValidationGate.writeSummary_(state, false, '', false, false, ...
                    {sprintf('%d selected test(s) failed; report not run.', nTot - nPass)});
                return
            end

            % Write preliminary summary so PDF shows correct stage/SHA.
            revgnss.MainScriptValidationGate.writeSummary_(state, false, '', false, false, ...
                {'Preliminary summary; PDF not yet generated.'});

            % Update cfg for validation mode.
            cfg.report.compileTex          = 'auto';
            cfg.validation.stage           = num2str(stg);
            cfg.validation.stageTitle      = stgTitle;
            cfg.validation.fullSuiteRun    = false;
            cfg.validation.invokedMainScript = true;
            cfg.validation.stageAllToggles = true;

            shouldContinue = true;
        end

        function postRun(state, out)
            % postRun  Verify PDF and write final summary.

            pdfPath = '';
            if isfield(out, 'pdfPath') && ~isempty(out.pdfPath)
                pdfPath = out.pdfPath;
            end

            [pdfOk, ptOk, texOk, warns] = revgnss.MainScriptValidationGate.vfyPdf_( ...
                pdfPath, state.sha, state.nPass, state.nTot, state.stage);

            revgnss.MainScriptValidationGate.writeSummary_(state, pdfOk, pdfPath, ptOk, texOk, warns);

            fprintf('[ValidationGate] Stage %d done.  PDF: %s  TextOK: %s  TEX: %s\n', ...
                state.stage, mat2str(pdfOk), mat2str(ptOk), mat2str(texOk));
        end

    end

    methods (Static, Access = private)

        function files = pickTests_(testDir, seed, count, stageNum)
            % pickTests_  Select 2-5 random tests, force test_stage<N>* if present.
            files = revgnss.ValidationRunner.selectTests(testDir, seed, count);
            tag = sprintf('test_stage%d', stageNum);
            tmp = dir(fullfile(testDir, [tag '*.m']));
            if ~isempty(tmp) && ~any(strcmp(files, tmp(1).name))
                files{end} = tmp(1).name;
                files = sort(files);
            end
        end

        function writeSummary_(state, pdfOk, pdfPath, ptOk, texOk, warns)
            % writeSummary_  Write JSON + TXT via ValidationSummary.
            if ~exist(state.outDir, 'dir'); mkdir(state.outDir); end
            [nPass, nTot] = revgnss.ValidationRunner.countResults(state.results);

            d.stage                         = num2str(state.stage);
            d.stageTitle                    = state.stageTitle;
            d.branch                        = state.branch;
            d.gitSHA                        = state.sha;
            d.timestamp                     = datestr(now, 'yyyy-mm-ddTHH:MM:SS'); %#ok<TNOW1,DATST>
            d.matlabVersion                 = version;
            d.testSeed                      = state.seed;
            d.nSelectedTests                = nTot;
            d.nPassingSelectedTests         = nPass;
            d.selectedTestNames             = {state.results.name};
            d.fullSuiteRun                  = false;
            d.allToggleReportRun            = ~isempty(pdfPath);
            d.invokedMainScript             = true;
            d.reportRunPassed               = ~isempty(pdfPath);
            d.pdfVerified                   = pdfOk;
            d.pdfTextVerified               = ptOk;
            d.texVerified                   = texOk;
            d.pdfPath                       = pdfPath;
            d.validationWarnings            = warns;
            d.currentStageSmokeTestIncluded = any(cellfun( ...
                @(n) contains(n, sprintf('stage%d', state.stage)), {state.results.name}));
            d.validationArtifactFresh       = true;   % fresh when written; staleness detected on read
            d.notes = sprintf('Stage %d smoke (%d/%d). Full suite NOT RUN.', state.stage, nPass, nTot);

            revgnss.ValidationSummary.write(state.outDir, d);
        end

        function [pdfOk, ptOk, texOk, warns] = vfyPdf_(pdfPath, sha, nP, nT, stg)
            % vfyPdf_  Verify PDF existence, size, and scientific content.
            % Stage 37+: PDF must have scientific sections and must NOT have a
            % "Stage N Validation Status" chapter heading.
            % SHA, test count, and NOT RUN are checked in JSON summary, not PDF.
            pdfOk = false; ptOk = false; texOk = false; warns = {};
            if isempty(pdfPath) || ~exist(pdfPath, 'file')
                warns{end+1} = 'PDF not found.'; return
            end
            info = dir(pdfPath);
            pdfOk = info.bytes > 50000;
            if ~pdfOk
                warns{end+1} = sprintf('PDF too small: %d bytes.', info.bytes); return
            end
            [st, txt] = system(sprintf('pdftotext "%s" - 2>/dev/null', pdfPath));
            if st == 0 && ~isempty(strtrim(txt))
                stgTag   = ['Stage ' num2str(stg)];
                badTok   = [stgTag ' Validation Status'];
                hasStage = ~isempty(strfind(txt, stgTag)); %#ok<STREMP>
                hasSci   = ~isempty(strfind(txt, 'Scenario Summary')); %#ok<STREMP>
                noValSt  =  isempty(strfind(txt, badTok)); %#ok<STREMP>
                ptOk = hasStage && hasSci && noValSt;
                if ~hasStage
                    warns{end+1} = sprintf('PDF text: ''Stage %d'' not found in title block.', stg);
                end
                if ~hasSci
                    warns{end+1} = 'PDF text: ''Scenario Summary'' section not found.';
                end
                if ~noValSt
                    warns{end+1} = sprintf('PDF text: ''%s'' heading still present.', badTok);
                end
                return
            end
            warns{end+1} = 'pdftotext unavailable; TEX fallback used (pdfTextVerified=false).';
            texPath = strrep(pdfPath, '.pdf', '.tex');
            if exist(texPath, 'file')
                try
                    t = fileread(texPath);
                    noValSt  = isempty(regexp(t, '\\\\section\{[^}]*Validation Status', 'once'));
                    hasScene = ~isempty(strfind(t, 'Scenario Summary')); %#ok<STREMP>
                    texOk = noValSt && hasScene;
                catch; end
            end
        end

        function t = stageTitle_(stg)
            switch stg
                case 30; t = 'Main-Script Validation Gate Restoration';
                case 31; t = 'Single-Asset Attitude Observability Audit';
                case 32; t = 'Single-Asset Receiver Geometry Model v1';
                case 33; t = 'Attitude Parameterization Convention Hardening';
                case 34; t = 'Attitude Jacobian Consistency Audit v1';
                case 35; t = 'Single-Asset Attitude Evidence Report v1';
                case 36; t = 'Single-Asset Attitude Scenario Readiness Gate v1';
                case 37; t = 'Move Validation Status Out of PDF Into README';
                case 38; t = 'Carrier-Phase Attitude Preparation v1';
                case 39; t = 'Carrier Row Metadata Inventory v1';
                case 40; t = 'Ambiguity Readiness Diagnostics v1';
                case 41; t = 'Ambiguity State Metadata and Covariance Export v1';
                case 42; t = 'L2 Carrier EKF Row Architecture v1';
                case 43; t = 'Ionosphere-Free Combination Diagnostics v1';
                case 44; t = 'Dual-Frequency IF Consistency and Bias Budget v1';
                case 45; t = 'Guarded Ionosphere-Free Code EKF Rows v1';
                case 46; t = 'Code IF EKF Consistency and Traceability v1';
                case 47; t = 'Guarded Carrier Ionosphere-Free Float EKF Rows v1';
                case 48; t = 'Carrier Ionosphere-Free Ambiguity Traceability v1';
                case 49; t = 'Wide-Lane / Narrow-Lane Float Diagnostics v1';
                case 50; t = 'Ambiguity Fixing Readiness Gate v1';
                case 51; t = 'Ambiguity Readiness Evidence Hardening v1';
                case 52; t = 'Carrier Arc and Cycle-Slip Evidence Export v1';
                case 53; t = 'Cycle-Slip-Aware Arc-Separated Float Ambiguities v1';
                case 54; t = 'Enforced Arc-Consistent Carrier Combinations v1';
                case 55; t = 'Source Truth and Report Architecture Cleanup v1';
                case 56; t = 'Measurement Geometry Core Consolidation v1';
                case 57; t = 'EKF Innovation Accounting and Gauge/NIS Cleanup v1';
                case 58; t = 'EKF Two-Body/J2 Dynamics Prediction v1';
                case 59; t = 'Single-Space-Asset Multi-Antenna Carrier Attitude Scenario v1';
                case 60; t = 'Carrier-Attitude Measurement Model Closure v1';
                case 61; t = 'Quaternion Nominal / Error-State Attitude EKF v1';
                case 62; t = 'Quaternion Error-State Covariance Consistency Closure v1';
                case 63; t = 'Controlled Single-Asset Integer Ambiguity Fixing v1';
                case 64; t = 'Scientific Closure and v1 Freeze';
                case 65; t = 'Lean Scientific Report and Code Cleanup';
                case 66; t = 'Single-Asset One-Way Realistic Reverse-GNSS v1 Closure';
                otherwise
                    try; t = revgnss.ReportStatus.current().stageTitle; catch; t = sprintf('Stage %d', stg); end
            end
        end

        function sha = gitSHA_(rootDir)
            sha = 'unknown';
            try
                [s, o] = system(sprintf('git -C "%s" rev-parse --short HEAD 2>/dev/null', rootDir));
                if s == 0; sha = strtrim(o); end
            catch; end
        end

        function br = gitBranch_(rootDir)
            br = 'unknown';
            try
                [s, o] = system(sprintf('git -C "%s" rev-parse --abbrev-ref HEAD 2>/dev/null', rootDir));
                if s == 0; br = strtrim(o); end
            catch; end
        end

    end
end
