classdef ReportWriter
    % ReportWriter  Saves all open MATLAB figures to a single PDF file.
    %
    % Usage:
    %   revgnss.ReportWriter.write(pdfPath, cfg, diag);
    %
    % The output PDF is written to oo_v1/output/reverse_gnss_simple_report.pdf
    % by default (configured via cfg.report.outputPdf).
    %
    % Implementation notes:
    %   MATLAB R2020a+ supports exportgraphics(..., 'Append', true).
    %   For older versions a print-based fallback is used.

    methods (Static)

        function write(pdfPath, cfg, diag)
            % write  Collect all open figures and save to pdfPath.

            % Ensure output directory exists
            outDir = fileparts(pdfPath);
            if ~isempty(outDir) && ~exist(outDir, 'dir')
                mkdir(outDir);
                fprintf('  Created output directory: %s\n', outDir);
            end

            % Collect all open figure handles, sorted by number
            figHandles = sort(findobj('Type', 'figure'));

            if isempty(figHandles)
                warning('ReportWriter:noFigures', ...
                    'No open figures to save. Call sim.plot() before sim.writeReport().');
                return
            end

            fprintf('  Saving %d figures to PDF...\n', numel(figHandles));

            % Try exportgraphics (R2020a+) with append support
            if revgnss.ReportWriter.hasExportGraphicsAppend_()
                revgnss.ReportWriter.exportViaExportGraphics_(figHandles, pdfPath);
            else
                revgnss.ReportWriter.exportViaPrint_(figHandles, pdfPath);
            end

            if exist(pdfPath, 'file')
                info = dir(pdfPath);
                fprintf('  PDF report saved to: %s  (%.1f kB)\n', pdfPath, info.bytes / 1024);
            else
                warning('ReportWriter:writeFailed', 'PDF file not found after write: %s', pdfPath);
            end
        end

        % ----------------------------------------------------------------
        function writePdfFromOpenFigures(pdfPath)
            % writePdfFromOpenFigures  Convenience wrapper (no cfg/diag needed).
            revgnss.ReportWriter.write(pdfPath, struct(), []);
        end
    end

    methods (Static, Access = private)

        function ok = hasExportGraphicsAppend_()
            % Check if exportgraphics supports 'Append' (requires R2020a+).
            try
                % exportgraphics exists since R2020a; Append since R2020b
                v = ver('MATLAB');
                yr  = str2double(v.Version(1:4));
                rel = v.Release(3);  % 'a' or 'b'
                ok = (yr > 2020) || (yr == 2020 && rel == 'b');
            catch
                ok = false;
            end
        end

        function exportViaExportGraphics_(figHandles, pdfPath)
            % Use exportgraphics with Append for clean multi-page PDF.
            if exist(pdfPath, 'file')
                delete(pdfPath);
            end
            for k = 1:numel(figHandles)
                fig = figHandles(k);
                if ~isvalid(fig); continue; end
                try
                    if k == 1
                        exportgraphics(fig, pdfPath, 'ContentType', 'vector');
                    else
                        exportgraphics(fig, pdfPath, 'ContentType', 'vector', 'Append', true);
                    end
                catch ME
                    warning('ReportWriter:exportFailed', ...
                        'Could not export figure %d: %s', fig.Number, ME.message);
                end
            end
        end

        function exportViaPrint_(figHandles, pdfPath)
            % Fallback: print each figure to a temporary PDF and concatenate.
            % Uses MATLAB's built-in print driver; works in older releases.
            tmpDir = tempdir();
            tmpFiles = {};
            for k = 1:numel(figHandles)
                fig = figHandles(k);
                if ~isvalid(fig); continue; end
                tmpPath = fullfile(tmpDir, sprintf('revgnss_fig_%04d.pdf', k));
                try
                    print(fig, tmpPath, '-dpdf', '-bestfit');
                    tmpFiles{end+1} = tmpPath; %#ok<AGROW>
                catch ME
                    warning('ReportWriter:printFailed', ...
                        'Could not print figure %d: %s', fig.Number, ME.message);
                end
            end

            if isempty(tmpFiles)
                return
            end

            if numel(tmpFiles) == 1
                % Single page: just copy
                copyfile(tmpFiles{1}, pdfPath);
            else
                % Multiple pages: use Ghostscript if available
                gsOk = revgnss.ReportWriter.tryGhostscriptMerge_(tmpFiles, pdfPath);
                if ~gsOk
                    % Last resort: copy the first file and warn
                    copyfile(tmpFiles{1}, pdfPath);
                    warning('ReportWriter:partialPdf', ...
                        'Could not merge PDFs (Ghostscript unavailable). Saved first figure only.');
                end
            end

            % Clean up temporary files
            for k = 1:numel(tmpFiles)
                if exist(tmpFiles{k}, 'file'); delete(tmpFiles{k}); end
            end
        end

        function ok = tryGhostscriptMerge_(tmpFiles, outPath)
            % Attempt to merge PDFs using Ghostscript (gs or gswin64c).
            ok = false;
            gsCmd = 'gs';
            if ispc(); gsCmd = 'gswin64c'; end

            inputStr = sprintf('"%s" ', tmpFiles{:});
            cmd = sprintf('%s -dBATCH -dNOPAUSE -q -sDEVICE=pdfwrite -sOutputFile="%s" %s', ...
                gsCmd, outPath, inputStr);
            status = system(cmd);
            ok = (status == 0);
        end
    end
end
