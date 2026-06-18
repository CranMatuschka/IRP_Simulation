classdef ValidationSummary
    % ValidationSummary  Write and read Stage 24 validation summary artifacts.
    %
    % Writes two artifacts to outDir:
    %   latest_validation_summary.json  — machine-readable full summary
    %   latest_validation_summary.txt   — human-readable one-pager
    %
    % Usage:
    %   revgnss.ValidationSummary.write(outDir, data);
    %   s = revgnss.ValidationSummary.read(outDir);   % safe defaults if missing

    methods (Static)

        function write(outDir, data)
            % write  Write JSON + TXT summary to outDir.
            if ~exist(outDir, 'dir'); mkdir(outDir); end

            % JSON
            jPath = fullfile(outDir, 'latest_validation_summary.json');
            fid = fopen(jPath, 'w', 'n', 'UTF-8');
            if fid < 0
                warning('ValidationSummary:writeError', 'Cannot open %s for writing', jPath);
                return
            end
            try
                txt = jsonencode(data, 'PrettyPrint', true);
            catch
                txt = jsonencode(data);   % older MATLAB without PrettyPrint
            end
            fprintf(fid, '%s\n', txt);
            fclose(fid);

            % TXT
            tPath = fullfile(outDir, 'latest_validation_summary.txt');
            fid = fopen(tPath, 'w', 'n', 'UTF-8');
            if fid < 0; return; end
            VS = revgnss.ValidationSummary;
            fprintf(fid, 'Stage 24 Validation Summary\n');
            fprintf(fid, '============================\n');
            fprintf(fid, 'Stage          : %s\n', VS.safe_(data, 'stage',      '?'));
            fprintf(fid, 'Stage title    : %s\n', VS.safe_(data, 'stageTitle', '?'));
            fprintf(fid, 'Branch         : %s\n', VS.safe_(data, 'branch',     'unknown'));
            fprintf(fid, 'Commit SHA     : %s\n', VS.safe_(data, 'gitSHA',     'unknown'));
            fprintf(fid, 'Timestamp      : %s\n', VS.safe_(data, 'timestamp',  '?'));
            fprintf(fid, 'MATLAB version : %s\n', VS.safe_(data, 'matlabVersion', '?'));
            fprintf(fid, 'Test seed      : %d\n', VS.safeNum_(data, 'testSeed', -1));
            fprintf(fid, 'Tests selected : %d\n', VS.safeNum_(data, 'nSelectedTests', 0));
            fprintf(fid, 'Tests passed   : %d / %d\n', ...
                VS.safeNum_(data, 'nPassingSelectedTests', 0), ...
                VS.safeNum_(data, 'nSelectedTests', 0));
            fprintf(fid, 'Full suite run : %s\n', mat2str(VS.safeBool_(data, 'fullSuiteRun', false)));
            fprintf(fid, 'All-toggle run : %s\n', mat2str(VS.safeBool_(data, 'allToggleReportRun', false)));
            fprintf(fid, 'Main script    : %s\n', mat2str(VS.safeBool_(data, 'invokedMainScript', false)));
            fprintf(fid, 'Report run OK  : %s\n', mat2str(VS.safeBool_(data, 'reportRunPassed', false)));
            fprintf(fid, 'PDF verified   : %s\n', mat2str(VS.safeBool_(data, 'pdfVerified', false)));
            fprintf(fid, 'TEX verified   : %s\n', mat2str(VS.safeBool_(data, 'texVerified', false)));
            fprintf(fid, 'Stage smoke    : %s\n', mat2str(VS.safeBool_(data, 'currentStageSmokeTestIncluded', false)));
            if isfield(data, 'pdfPath') && ~isempty(data.pdfPath)
                fprintf(fid, 'PDF path       : %s\n', data.pdfPath);
            end
            if isfield(data, 'notes') && ~isempty(data.notes)
                fprintf(fid, 'Notes          : %s\n', data.notes);
            end
            fclose(fid);
        end

        function s = read(outDir)
            % read  Read JSON summary; return safe defaults if missing or unreadable.
            jPath = fullfile(outDir, 'latest_validation_summary.json');
            if ~exist(jPath, 'file')
                s = revgnss.ValidationSummary.default_();
                s.notes = 'No latest validation summary found.';
                return
            end
            try
                rawTxt = fileread(jPath);
                s = jsondecode(rawTxt);
            catch ex
                s = revgnss.ValidationSummary.default_();
                s.notes = sprintf('Failed to parse summary JSON: %s', ex.message);
            end
        end

    end

    methods (Static, Access = private)

        function s = default_()
            s.stage                        = '24';
            s.stageTitle                   = 'Validation Status Gate + Frame/Time/Light-Time Foundation';
            s.branch                       = 'unknown';
            s.gitSHA                       = 'unknown';
            s.timestamp                    = 'unknown';
            s.matlabVersion                = version;
            s.testSeed                     = -1;
            s.nSelectedTests               = 0;
            s.nPassingSelectedTests        = 0;
            s.selectedTestNames            = {};
            s.fullSuiteRun                 = false;
            s.allToggleReportRun           = false;
            s.reportRunPassed              = false;
            s.invokedMainScript            = false;
            s.pdfVerified                  = false;
            s.pdfTextVerified              = false;
            s.texVerified                  = false;
            s.currentStageSmokeTestIncluded = false;
            s.pdfPath                      = '';
            s.validationWarnings           = {};
            s.notes                        = '';
        end

        function v = safe_(s, f, def)
            if isfield(s, f) && ~isempty(s.(f)); v = s.(f); else; v = def; end
        end

        function v = safeNum_(s, f, def)
            if isfield(s, f) && isnumeric(s.(f)); v = s.(f); else; v = def; end
        end

        function v = safeBool_(s, f, def)
            if isfield(s, f); v = logical(s.(f)); else; v = def; end
        end

    end
end
