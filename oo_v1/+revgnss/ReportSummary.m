classdef ReportSummary
    % ReportSummary  Format performance metric lines from a summary struct.
    %
    % Used by LatexReportBuilder to build the measurement-summary and
    % verdict pages from a summary struct returned by ReportRunner.
    methods (Static)

        function lines = metricsLines(summary)
            % metricsLines  Position/clock/NIS metrics from summary struct.
            lines = {};
            function v = fmtField(fname, unit)
                if isfield(summary, fname) && ~isnan(summary.(fname))
                    v = sprintf('  %-30s : %.4f %s', fname, summary.(fname), unit);
                else
                    v = sprintf('  %-30s : —', fname);
                end
            end
            lines{end+1} = fmtField('finalPositionError_m',  'm');
            lines{end+1} = fmtField('finalPositionRMS_m',    'm');
            lines{end+1} = fmtField('finalClockBiasRMS_m',   'm');
            if isfield(summary,'meanNIS') && ~isnan(summary.meanNIS)
                expNIS = NaN;
                if isfield(summary,'expectedNIS'); expNIS = summary.expectedNIS; end
                lines{end+1} = sprintf('  %-30s : %.2f  (expected %.1f)', ...
                    'meanNIS', summary.meanNIS, expNIS);
            end
            if isfield(summary,'deterministicMismatchRMS_last20_m') && ...
                    ~isnan(summary.deterministicMismatchRMS_last20_m)
                lines{end+1} = fmtField('deterministicMismatchRMS_last20_m', 'm');
            end
            if isfield(summary,'stochasticNoiseRMS_last20_m') && ...
                    ~isnan(summary.stochasticNoiseRMS_last20_m)
                lines{end+1} = fmtField('stochasticNoiseRMS_last20_m', 'm');
            end
        end

        function lines = modeLines(summary)
            % modeLines  Observable/estimation mode summary lines.
            function v = sf(name, def)
                if isfield(summary, name); v = summary.(name); else; v = def; end
            end
            lines = {};
            lines{end+1} = sprintf('  %-24s : %s', 'codeMode',        sf('codeMode',        '—'));
            lines{end+1} = sprintf('  %-24s : %s', 'carrierMode',     sf('carrierMode',     '—'));
            lines{end+1} = sprintf('  %-24s : %s', 'ambiguityMode',   sf('ambiguityMode',   '—'));
            lines{end+1} = sprintf('  %-24s : %s', 'troposphereMode', sf('troposphereMode', '—'));
            lines{end+1} = sprintf('  %-24s : %s', 'towerClockMode',  sf('towerClockMode',  '—'));
        end

    end
end
