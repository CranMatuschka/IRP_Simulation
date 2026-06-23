classdef ReportStatus
    % ReportStatus  Runtime validation status.
    %
    % Reads runtime values from output/latest_validation_summary.json (if present).
    % If the JSON is missing or has a stale SHA, validationArtifactFresh=false.
    % Report generation continues normally regardless.
    %
    % Usage:
    %   s     = revgnss.ReportStatus.current();      % full status struct
    %   lines = revgnss.ReportStatus.summaryLines();  % formatted cell array

    methods (Static)

        function s = current()
            s.stage      = '78';
            s.stageTitle = 'Central Configuration Completion and Source-Truth Cleanup';
            s.validationMode = 'targeted-random-smoke';
            s.fullSuiteRun   = false;

            s.gitSHA        = revgnss.ReportStatus.getGitSHA_();
            s.branch        = revgnss.ReportStatus.getGitBranch_();
            s.matlabVersion = version;
            s.timestamp     = datestr(now, 'yyyy-mm-dd'); %#ok<TNOW1,DATST>

            % Load validation summary; never fail report generation.
            summaryDir = fullfile(fileparts(mfilename('fullpath')), '..', 'output');
            vs = revgnss.ValidationSummary.read(summaryDir);

            if isfield(vs, 'nPassingSelectedTests') && isnumeric(vs.nPassingSelectedTests)
                s.nPassingSelectedTests = vs.nPassingSelectedTests;
                s.nSelectedTests        = vs.nSelectedTests;
            else
                s.nPassingSelectedTests = 0;
                s.nSelectedTests        = 0;
            end
            s.allPass = (s.nPassingSelectedTests == s.nSelectedTests) && ...
                        (s.nSelectedTests > 0);

            s.reportRunPassed    = revgnss.ReportStatus.safeBool_(vs, 'reportRunPassed',    false);
            s.pdfVerified        = revgnss.ReportStatus.safeBool_(vs, 'pdfVerified',        false);
            s.allToggleReportRun = revgnss.ReportStatus.safeBool_(vs, 'allToggleReportRun', false);
            s.invokedMainScript  = revgnss.ReportStatus.safeBool_(vs, 'invokedMainScript',  false);
            s.pdfTextVerified    = revgnss.ReportStatus.safeBool_(vs, 'pdfTextVerified',    false);
            s.texVerified        = revgnss.ReportStatus.safeBool_(vs, 'texVerified',        false);
            if isfield(vs, 'validationWarnings') && iscell(vs.validationWarnings)
                s.validationWarnings = vs.validationWarnings;
            else
                s.validationWarnings = {};
            end

            % Freshness: require matching stage AND matching runtime SHA.
            runtimeSHA = revgnss.ReportStatus.getGitSHA_();
            vsStageNum = 0;
            if isfield(vs, 'stage')
                vsStageNum = str2double(strtrim(num2str(vs.stage)));
                if isnan(vsStageNum); vsStageNum = 0; end
            end
            vsSHA = '';
            if isfield(vs, 'gitSHA'); vsSHA = strtrim(char(vs.gitSHA)); end
            s.validationArtifactFresh = (vsStageNum >= 76) && strcmp(vsSHA, runtimeSHA);
            if ~s.validationArtifactFresh
                s.validationWarnings{end+1} = ...
                    'No fresh local validation summary for this commit. Run: setenv(''OO_V1_VALIDATE_REPORT'',''true''); setenv(''OO_V1_VALIDATION_STAGE'',''76''); run_oo_reverse_gnss_report';
            end

            if isfield(vs, 'selectedTestNames')
                s.selectedTests = vs.selectedTestNames;
            else
                s.selectedTests = {};
            end
            if isfield(vs, 'notes') && ~isempty(vs.notes)
                s.validationNote = vs.notes;
            else
                s.validationNote = '';
            end

            s.missingScientificStages = revgnss.StageHistory.missingScientificItems(78);
            s.implementedStage24Items = revgnss.StageHistory.implementedItems();
        end

        function lines = summaryLines()
            % summaryLines  Formatted cell array for embedding in report pages.
            s = revgnss.ReportStatus.current();
            lines = {};
            lines{end+1} = sprintf('Stage        : %s -- %s', s.stage, s.stageTitle);
            lines{end+1} = sprintf('Branch       : %s', s.branch);
            lines{end+1} = sprintf('Commit SHA   : %s', s.gitSHA);
            lines{end+1} = sprintf('Validation   : %s  (full suite NOT RUN)', s.validationMode);
            lines{end+1} = sprintf('Tests passed : %d / %d selected', ...
                s.nPassingSelectedTests, s.nSelectedTests);
            lines{end+1} = sprintf('All-toggle   : %s', mat2str(s.allToggleReportRun));
            lines{end+1} = sprintf('PDF verified : %s', mat2str(s.pdfVerified));
            lines{end+1} = sprintf('MATLAB       : %s', s.matlabVersion);
            lines{end+1} = sprintf('Status date  : %s', s.timestamp);
        end

    end

    methods (Static, Access = private)

        function sha = getGitSHA_()
            sha = 'unknown';
            try
                repoRoot = fileparts(fileparts(mfilename('fullpath')));
                [s, out] = system(sprintf('git -C "%s" rev-parse --short HEAD 2>/dev/null', repoRoot));
                if s == 0; sha = strtrim(out); end
            catch; end
        end

        function br = getGitBranch_()
            br = 'unknown';
            try
                repoRoot = fileparts(fileparts(mfilename('fullpath')));
                [s, out] = system(sprintf('git -C "%s" rev-parse --abbrev-ref HEAD 2>/dev/null', repoRoot));
                if s == 0; br = strtrim(out); end
            catch; end
        end

        function v = safeBool_(s, f, def)
            if isfield(s, f); v = logical(s.(f)); else; v = def; end
        end

    end
end
