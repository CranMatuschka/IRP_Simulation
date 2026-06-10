classdef ReportWriter
    % ReportWriter  Saves an array of figure handles to a multi-page PDF.
    %
    % Usage:
    %   revgnss.ReportWriter.write(pdfPath, figHandles, cfg);
    %
    % figHandles is the array returned by sim.plot() / Plotter.plotAll().
    % If figHandles is empty, falls back to all currently open figures.
    %
    % cfg.plots.savePdf                = true   — write the PDF
    % cfg.plots.saveIndividualFigures  = true   — each fig as .png + .fig
    % cfg.plots.outputDir              = '...'  — individual-figure output dir
    % cfg.plots.closeAfterSave         = false  — keep figures open after saving
    %
    % PDF notes:
    %   MATLAB R2020b+ : exportgraphics with Append (clean vector PDF)
    %   Older releases : print -dpdf per figure, merged via Ghostscript if available

    methods (Static)

        function write(pdfPath, figHandles, cfg)
            % write  Save figures to PDF (and optionally individual PNG/FIG).
            %
            % Parameters:
            %   pdfPath    — full path to output PDF file
            %   figHandles — array of figure handles (from Plotter.plotAll)
            %   cfg        — simulation config struct

            if nargin < 3; cfg = struct(); end

            % ----- Decide whether to write a PDF --------------------------
            doPdf = true;
            if isfield(cfg,'plots') && isfield(cfg.plots,'savePdf')
                doPdf = cfg.plots.savePdf;
            end

            % ----- Resolve figure handles ---------------------------------
            if isempty(figHandles) || ~any(isgraphics(figHandles))
                % Fall back to all open figures (hidden ones included)
                figHandles = sort(findobj(0,'Type','figure'));
                if isempty(figHandles)
                    warning('ReportWriter:noFigures', ...
                        'No figures available. Call sim.plot() first.');
                    return
                end
                fprintf('  ReportWriter: using %d open figures (fallback)\n', numel(figHandles));
            end

            % Keep only valid figure handles
            figHandles = figHandles(isgraphics(figHandles) & ...
                strcmp(get(figHandles,'Type'),'figure'));

            if isempty(figHandles)
                warning('ReportWriter:noValidFigures', 'No valid figure handles to save.');
                return
            end

            % ----- Ensure output directory --------------------------------
            outDir = fileparts(pdfPath);
            if ~isempty(outDir) && ~exist(outDir,'dir')
                mkdir(outDir);
                fprintf('  Created output directory: %s\n', outDir);
            end

            % ----- Individual figure files --------------------------------
            revgnss.ReportWriter.saveIndividualFigures_(figHandles, cfg);

            % ----- PDF export --------------------------------------------
            if doPdf
                fprintf('  Saving %d figures to PDF: %s\n', numel(figHandles), pdfPath);

                if revgnss.ReportWriter.hasExportGraphicsAppend_()
                    revgnss.ReportWriter.exportViaExportGraphics_(figHandles, pdfPath);
                else
                    revgnss.ReportWriter.exportViaPrint_(figHandles, pdfPath);
                end

                if exist(pdfPath,'file')
                    info = dir(pdfPath);
                    fprintf('  PDF report saved: %s  (%.1f kB)\n', pdfPath, info.bytes/1024);
                else
                    warning('ReportWriter:writeFailed', ...
                        'PDF file not found after write: %s', pdfPath);
                end
            end

            % ----- Close after save? -------------------------------------
            if isfield(cfg,'plots') && isfield(cfg.plots,'closeAfterSave') && ...
                    cfg.plots.closeAfterSave
                for k = 1:numel(figHandles)
                    if isvalid(figHandles(k)); close(figHandles(k)); end
                end
                fprintf('  Closed %d figures.\n', numel(figHandles));
            end
        end

        % ------------------------------------------------------------------
        function writePdfFromOpenFigures(pdfPath)
            % writePdfFromOpenFigures  Convenience wrapper (no cfg needed).
            revgnss.ReportWriter.write(pdfPath, [], struct());
        end
    end

    methods (Static, Access = private)

        % ------------------------------------------------------------------
        function saveIndividualFigures_(figHandles, cfg)
            % saveIndividualFigures_  Save each figure as PNG + FIG.
            %
            % Saves to cfg.plots.outputDir.  Uses the figure Name property as
            % the filename stem (stripped of leading "NN — " for readability).
            % Skips if saveIndividualFigures is false.

            doSave = false;
            if isfield(cfg,'plots')
                if isfield(cfg.plots,'saveIndividualFigures') && cfg.plots.saveIndividualFigures
                    doSave = true;
                elseif isfield(cfg.plots,'saveFigures') && cfg.plots.saveFigures
                    doSave = true;
                end
            end
            if ~doSave; return; end

            outDir = '';
            if isfield(cfg,'plots') && isfield(cfg.plots,'outputDir')
                outDir = cfg.plots.outputDir;
            end
            if isempty(outDir)
                warning('ReportWriter:noOutputDir', ...
                    'cfg.plots.outputDir not set — skipping individual figure save.');
                return
            end
            if ~exist(outDir,'dir'); mkdir(outDir); end

            for k = 1:numel(figHandles)
                fig = figHandles(k);
                if ~isvalid(fig); continue; end

                % Build safe filename from figure Name
                fname = revgnss.ReportWriter.figNameToFilename_(fig.Name);
                if isempty(fname)
                    fname = sprintf('figure_%02d', k);
                end

                pngPath = fullfile(outDir, [fname '.png']);
                figPath = fullfile(outDir, [fname '.fig']);

                try
                    saveas(fig, pngPath);
                catch ME
                    warning('ReportWriter:savePng', 'PNG save failed (%s): %s', fname, ME.message);
                end
                try
                    saveas(fig, figPath);
                catch ME
                    warning('ReportWriter:saveFig', 'FIG save failed (%s): %s', fname, ME.message);
                end
                fprintf('  Saved: %s (.png + .fig)\n', fname);
            end
        end

        % ------------------------------------------------------------------
        function fname = figNameToFilename_(figName)
            % figNameToFilename_  Convert figure title to safe filename.
            %
            % "05 — Receiver Clock Bias"  ->  "05_rx_clock_bias"
            % If the title already starts with 'NN_', use it as-is.
            % Otherwise sanitise by replacing non-word characters.

            fname = strtrim(figName);

            % If it has the "NN — Title" style, extract the number + words
            tok = regexp(fname, '^(\d+)\s*[—\-]+\s*(.+)$', 'tokens','once');
            if numel(tok) == 2
                num  = strtrim(tok{1});
                rest = lower(strtrim(tok{2}));
                rest = regexprep(rest, '\s+', '_');
                rest = regexprep(rest, '[^\w]', '');
                fname = [num '_' rest];
                return
            end

            % Generic sanitisation
            fname = lower(fname);
            fname = regexprep(fname, '\s+', '_');
            fname = regexprep(fname, '[^\w]', '');
        end

        % ------------------------------------------------------------------
        function ok = hasExportGraphicsAppend_()
            % hasExportGraphicsAppend_  True on MATLAB R2020b+.
            try
                v   = ver('MATLAB');
                yr  = str2double(v.Version(1:4));
                rel = v.Release(3);   % 'a' or 'b'
                ok  = (yr > 2020) || (yr == 2020 && rel >= 'b');
            catch
                ok = false;
            end
        end

        % ------------------------------------------------------------------
        function exportViaExportGraphics_(figHandles, pdfPath)
            % exportViaExportGraphics_  Use exportgraphics (R2020b+) Append.
            if exist(pdfPath,'file'); delete(pdfPath); end

            for k = 1:numel(figHandles)
                fig = figHandles(k);
                if ~isvalid(fig); continue; end
                try
                    if k == 1
                        exportgraphics(fig, pdfPath, 'ContentType','vector');
                    else
                        exportgraphics(fig, pdfPath, 'ContentType','vector', 'Append',true);
                    end
                catch ME
                    warning('ReportWriter:exportFailed', ...
                        'exportgraphics failed for figure %d: %s', k, ME.message);
                end
            end
        end

        % ------------------------------------------------------------------
        function exportViaPrint_(figHandles, pdfPath)
            % exportViaPrint_  Fallback: print each figure + Ghostscript merge.
            tmpDir  = tempdir();
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
                        'print() failed for figure %d: %s', k, ME.message);
                end
            end

            if isempty(tmpFiles); return; end

            if numel(tmpFiles) == 1
                copyfile(tmpFiles{1}, pdfPath);
            else
                gsOk = revgnss.ReportWriter.tryGhostscriptMerge_(tmpFiles, pdfPath);
                if ~gsOk
                    copyfile(tmpFiles{1}, pdfPath);
                    warning('ReportWriter:partialPdf', ...
                        'Could not merge PDFs (Ghostscript unavailable). First figure only.');
                end
            end

            for k = 1:numel(tmpFiles)
                if exist(tmpFiles{k},'file'); delete(tmpFiles{k}); end
            end
        end

        % ------------------------------------------------------------------
        function ok = tryGhostscriptMerge_(tmpFiles, outPath)
            % tryGhostscriptMerge_  Merge PDFs via Ghostscript if available.
            ok    = false;
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
