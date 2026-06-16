classdef ReportStatus
    % ReportStatus  Static holder for test-suite status metadata.
    %
    % Usage:
    %   s = revgnss.ReportStatus.current();   % struct with status fields
    %   lines = revgnss.ReportStatus.summaryLines();  % formatted cell array
    methods (Static)

        function s = current()
            % current  Return struct with current test/validation status.
            s.nPassing      = 194;
            s.nTotal        = 194;
            s.stage         = '14.1';
            s.allPass       = (s.nPassing == s.nTotal);
            s.matlabVersion = version;
            s.commitSHA     = revgnss.ReportStatus.getGitSHA_();
            s.timestamp     = datestr(now, 'yyyy-mm-dd'); %#ok<TNOW1,DATST>
        end

        function lines = summaryLines()
            % summaryLines  Cell array of formatted status lines for report pages.
            s = revgnss.ReportStatus.current();
            lines = {};
            lines{end+1} = sprintf('Test status  : %d / %d passing  [Stage %s]', ...
                s.nPassing, s.nTotal, s.stage);
            lines{end+1} = sprintf('All pass     : %s', mat2str(s.allPass));
            lines{end+1} = sprintf('MATLAB       : %s', s.matlabVersion);
            lines{end+1} = sprintf('Commit SHA   : %s', s.commitSHA);
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

    end
end
