classdef ReportStatus
    % ReportStatus  Stage 24 runtime validation status.
    %
    % Reads runtime values from output/latest_validation_summary.json (if present).
    % If the JSON is missing, returns safe defaults with a warning note — report
    % generation continues normally.
    %
    % Usage:
    %   s     = revgnss.ReportStatus.current();      % full status struct
    %   lines = revgnss.ReportStatus.summaryLines();  % formatted cell array

    methods (Static)

        function s = current()
            % current  Return Stage 24 runtime validation status struct.

            s.stage      = '24';
            s.stageTitle = 'Validation Status Gate + Frame/Time/Light-Time Foundation';
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

            s.reportRunPassed   = revgnss.ReportStatus.safeBool_(vs, 'reportRunPassed', false);
            s.pdfVerified       = revgnss.ReportStatus.safeBool_(vs, 'pdfVerified',     false);
            s.allToggleReportRun= revgnss.ReportStatus.safeBool_(vs, 'allToggleReportRun', false);

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

            s.missingScientificStages = revgnss.ReportStatus.missingStages_();
            s.implementedStage24Items = revgnss.ReportStatus.implementedItems_();
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
                [s, out] = system('git rev-parse --short HEAD 2>/dev/null');
                if s == 0; sha = strtrim(out); end
            catch; end
        end

        function br = getGitBranch_()
            br = 'unknown';
            try
                [s, out] = system('git rev-parse --abbrev-ref HEAD 2>/dev/null');
                if s == 0; br = strtrim(out); end
            catch; end
        end

        function v = safeBool_(s, f, def)
            if isfield(s, f); v = logical(s.(f)); else; v = def; end
        end

        function list = missingStages_()
            list = {
                'Full CI / full test-suite validation (Stage 24 runs targeted smoke only)'
                'Full IERS/EOP GCRS/ITRF reference-frame and Earth-orientation products'
                'Full relativistic GNSS clock modelling (Schwarzschild, gravitational redshift)'
                'Dynamic orbit/force model (J2, drag, SRP; current: constant-velocity/simple orbit)'
                'Scientific troposphere: Niell/GMF/VMF3/GPT3/ERA5 mapping functions'
                'Scientific ionosphere: Klobuchar/IONEX/higher-order ionosphere models'
                'Carrier ionosphere-free (L4) combination in EKF'
                'Integer ambiguity resolution (LAMBDA/MLAMBDA)'
                'ANTEX PCO/PCV and calibrated hardware-bias products'
                'Real TWSTFT / relay / transponder physics'
                'External GNSS product ingestion: SP3, CLK, RINEX, IONEX, ANTEX'
            };
        end

        function list = implementedItems_()
            list = {
                'ReportStatus: runtime git SHA, branch, validation mode, missing-stages list'
                'ValidationSummary: JSON + TXT summary writer and reader'
                'ValidationRunner: deterministic random test selection (seed 24, 2-5 tests)'
                'FrameTimeUtils: simple ECEF/inertial Earth-rotation and Sagnac foundation'
                'run_stage24_validation.m: targeted smoke validation + all-toggle report run'
                'Report Stage 24 validation status section in PDF/TEX'
                'All-toggle report mode: all independent boolean features enabled for run'
                'README updated to Stage 24 with runtime-SHA policy'
                'TWSTFT code time-transfer diagnostic scaffold (Stage 24a, diagnostic-only)'
            };
        end

    end
end
