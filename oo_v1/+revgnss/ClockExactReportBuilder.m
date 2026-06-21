classdef ClockExactReportBuilder
    % ClockExactReportBuilder  Produce a Clock_*-style LaTeX/PDF report.
    %
    % Pipeline (matches Clock_20260610_v1.43 structure exactly):
    %   1. Validate LaTeX availability (fail clearly if missing).
    %   2. Generate compact PDF plot files in <reportDir>/figures/.
    %   3. Write a .tex source file using the Clock_* longtable layout.
    %   4. Compile with pdflatex (two passes for cross-references).
    %   5. Return result struct with paths and status.
    %
    % Usage (called from ReportRunner when cfg.report.layout='clockExact'):
    %   result = revgnss.ClockExactReportBuilder.build(diag, asset, towers, cfg, summary);
    %
    % result fields:
    %   result.texPath       — .tex source path
    %   result.pdfPath       — compiled PDF path ('' if compilation skipped)
    %   result.figDir        — figures/ subfolder path
    %   result.latexAvailable — logical
    %   result.success       — logical
    %   result.message       — human-readable status or error message
    %
    % Required: pdflatex or xelatex in PATH (or /Library/TeX/texbin/pdflatex).
    % If LaTeX is not available and compileTex ~= 'never', build() errors with
    % a clear message:
    %   "ClockExact report requires pdflatex or xelatex to reproduce the
    %    Clock_* PDF style."
    %
    % cfg.report.layout         = 'clockExact'  (required to use this builder)
    % cfg.report.compileTex     = 'require'|'auto'|'never'
    % cfg.report.appendRawPlots = false (default; raw plot appendix off)

    methods (Static)

        % ================================================================
        function result = build(diag, asset, towers, cfg, summary)
            % build  Full ClockExact report pipeline.
            if nargin < 5; summary = struct(); end
            if nargin < 4 || isempty(cfg); cfg = struct(); end

            result.texPath        = '';
            result.pdfPath        = '';
            result.figDir         = '';
            result.latexAvailable = false;
            result.success        = false;
            result.message        = '';

            % ---- 1. LaTeX check ----------------------------------------
            compileMode = revgnss.ClockExactReportBuilder.getCfgStr_( ...
                cfg, {'report','compileTex'}, 'auto');
            [latexOk, latexCmd] = revgnss.ClockExactReportBuilder.detectLatex_();
            result.latexAvailable = latexOk;

            if ~latexOk && ~strcmp(compileMode,'never')
                msg = ['ClockExact report requires pdflatex or xelatex to reproduce ' ...
                    'the Clock_* PDF style. ' ...
                    'Install TeX Live or MiKTeX, or set cfg.report.compileTex=''never'' ' ...
                    'to write the .tex file without compiling.'];
                if strcmp(compileMode,'require')
                    error('ClockExactReportBuilder:noLatex', '%s', msg);
                else
                    warning('ClockExactReportBuilder:noLatex', '%s', msg);
                    compileMode = 'never';
                end
            end

            % ---- 2. Resolve output paths --------------------------------
            baseDir = fullfile(fileparts(mfilename('fullpath')), '..', 'output');
            baseDir = revgnss.ClockExactReportBuilder.getCfgStr_(cfg, {'report','baseOutputDir'}, baseDir);
            prefix  = revgnss.ClockExactReportBuilder.getCfgStr_(cfg, {'report','dateFolderPrefix'}, 'Report-');
            ver     = revgnss.ClockExactReportBuilder.getCfgStr_(cfg, {'report','version'}, '1.00');

            reportDir = fullfile(baseDir, [prefix datestr(now,'yyyymmdd')]); %#ok<TNOW1,DATST>
            if ~exist(reportDir,'dir'); mkdir(reportDir); end

            scenarioName = revgnss.ClockExactReportBuilder.getCfgStr_(cfg, {'asset','name'}, 'GEO-1');
            stem = strrep(strrep(strrep(scenarioName, ' ', '_'), '-', '_'), '.', '_');
            stem = ['oo_v1_' stem];

            figDir  = fullfile(reportDir, 'figures');
            if ~exist(figDir,'dir'); mkdir(figDir); end
            texPath = fullfile(reportDir, sprintf('report-v%s.tex', ver));
            pdfPath = fullfile(reportDir, sprintf('report-v%s.pdf', ver));

            result.figDir  = figDir;
            result.texPath = texPath;
            result.pdfPath = pdfPath;

            % ---- 3. Generate compact plot PDFs --------------------------
            fprintf('  [ClockExact] Generating compact plot images...\n');
            plotPaths = revgnss.ClockExactReportBuilder.generateCompactPlots_( ...
                diag, cfg, summary, figDir, stem);
            revgnss.ReportRealityHelper.validateConsistency( ...
                cfg, summary, diag, plotPaths);

            % ---- 4. Write .tex ------------------------------------------
            fprintf('  [ClockExact] Writing LaTeX source: %s\n', texPath);
            revgnss.ClockExactReportBuilder.writeTexFile_( ...
                texPath, cfg, summary, diag, figDir, plotPaths, stem);

            % ---- 5. Compile .tex ----------------------------------------
            if ~strcmp(compileMode,'never') && latexOk
                fprintf('  [ClockExact] Compiling with %s...\n', latexCmd);
                ok = revgnss.ClockExactReportBuilder.compileTex_(texPath, latexCmd);
                if ok
                    result.success = true;
                    result.message = sprintf('PDF compiled: %s', pdfPath);
                    fprintf('  [ClockExact] PDF written: %s\n', pdfPath);
                else
                    result.success = false;
                    result.message = sprintf('pdflatex failed for: %s', texPath);
                    warning('ClockExactReportBuilder:compileFailed', '%s', result.message);
                end
            else
                result.success = true;
                result.pdfPath = '';
                result.message = sprintf('LaTeX written (compile skipped): %s', texPath);
            end
        end

    end  % public static

    methods (Static, Access = private)

        % ================================================================
        % COMPACT PLOT GENERATION
        % ================================================================

        function paths = generateCompactPlots_(diag, cfg, summary, figDir, stem)
            % generateCompactPlots_  Create compact PDF plots for each report row.
            paths = struct();
            isDiag = isobject(diag) && ismethod(diag, 'getTimeVector');

            t = [];
            if isDiag; try; t = diag.getTimeVector(); catch; end; end

            CE = revgnss.ClockExactReportBuilder;

            % Position error
            paths.posErr = CE.tryPlot_(figDir, [stem '_position_error.pdf'], @() ...
                CE.plotPositionError_(diag, t));

            % Clock bias error
            paths.clkErr = CE.tryPlot_(figDir, [stem '_clock_error.pdf'], @() ...
                CE.plotClockError_(diag, t));

            % Clock drift
            paths.clkDrift = CE.tryPlot_(figDir, [stem '_clock_drift.pdf'], @() ...
                CE.plotClockDrift_(diag, t));

            % Innovation RMS (prefit / postfit)
            paths.innovRMS = CE.tryPlot_(figDir, [stem '_innovation_rms.pdf'], @() ...
                CE.plotInnovationRMS_(diag, t));

            % NIS
            paths.nis = CE.tryPlot_(figDir, [stem '_nis.pdf'], @() ...
                CE.plotNIS_(diag, t));

            % Attitude diagnostics
            paths.attComp = CE.tryPlot_(figDir, [stem '_attitude_components.pdf'], @() ...
                revgnss.ReportRealityHelper.plotAttitudeComponents(diag, t));
            paths.attNorm = CE.tryPlot_(figDir, [stem '_attitude_norm.pdf'], @() ...
                revgnss.ReportRealityHelper.plotAttitudeNorm(diag, t));
            paths.attSigma = CE.tryPlot_(figDir, [stem '_attitude_sigma.pdf'], @() ...
                revgnss.ReportRealityHelper.plotAttitudeSigma(diag, t));

            % Visible towers
            paths.visTowers = CE.tryPlot_(figDir, [stem '_visible_towers.pdf'], @() ...
                CE.plotVisibleTowers_(diag, t));

            % DOP metrics
            paths.dop = CE.tryPlot_(figDir, [stem '_dop.pdf'], @() ...
                CE.plotDOP_(diag, t));

            % Tower clock biases (bar chart)
            paths.twrClocks = CE.tryPlot_(figDir, [stem '_tower_clocks.pdf'], @() ...
                CE.plotTowerClocks_(diag));

            % Per-source error breakdown
            paths.perSrc = CE.tryPlot_(figDir, [stem '_per_source_error.pdf'], @() ...
                CE.plotPerSourceError_(diag, t));

            % Zoom plots: last 10% of time
            zoomFrac = 0.10;
            paths.posErrZoom  = CE.tryPlot_(figDir, [stem '_position_error_zoom10.pdf'], @() ...
                CE.plotSignalZoom_(diag, t, 'posErr',  zoomFrac));
            paths.clkErrZoom  = CE.tryPlot_(figDir, [stem '_clock_error_zoom10.pdf'], @() ...
                CE.plotSignalZoom_(diag, t, 'clkErr',  zoomFrac));
            paths.clkDriftZoom = CE.tryPlot_(figDir, [stem '_clock_drift_zoom10.pdf'], @() ...
                CE.plotSignalZoom_(diag, t, 'clkDrift', zoomFrac));
            paths.attCompZoom = CE.tryPlot_(figDir, [stem '_attitude_components_zoom10.pdf'], @() ...
                CE.plotAttZoom_(diag, t, zoomFrac));
        end

        % ................................................................
        function fig = plotSignalZoom_(diag, t, signal, zoomFrac)
            % plotSignalZoom_  Plot last zoomFrac of a time series (position, clock, drift).
            fig = revgnss.ClockExactReportBuilder.makeCompactFig_('');
            ax  = gca(fig);
            try
                switch signal
                    case 'posErr';   data = diag.getPositionErrors();     yLbl = 'Error [m]';
                    case 'clkErr';   data = diag.getClockBiasErrors()*1e3; yLbl = 'Clk err [mm]';
                    case 'clkDrift'; data = diag.getClockDriftErrors();   yLbl = 'Drift [m/s]';
                    otherwise;       data = [];                            yLbl = '';
                end
                if ~isempty(t) && ~isempty(data)
                    n  = numel(t);
                    i0 = max(1, round(n * (1-zoomFrac)));
                    plot(ax, t(i0:end), data(i0:end), 'b-', 'LineWidth', 0.8);
                    xlabel(ax, 'Time [s]', 'FontSize', 7);
                    ylabel(ax, yLbl, 'FontSize', 7);
                    grid(ax, 'on');
                    return;
                end
            catch; end
            revgnss.ClockExactReportBuilder.noDataAxes_(ax);
        end

        % ................................................................
        function fig = plotAttZoom_(diag, t, zoomFrac)
            % plotAttZoom_  Attitude component errors, zoomed to last zoomFrac.
            fig = revgnss.ClockExactReportBuilder.makeCompactFig_('');
            ax  = gca(fig);
            try
                % Reuse ReportRealityHelper if available; otherwise graceful no-data.
                tmpFig = revgnss.ReportRealityHelper.plotAttitudeComponents(diag, t);
                if isgraphics(tmpFig)
                    n  = numel(t);
                    i0 = max(1, round(n * (1-zoomFrac)));
                    ax2 = get(tmpFig,'CurrentAxes');
                    lines_ = findobj(ax2,'Type','line');
                    cmap = {'b','r','g'};
                    lbls = {'Roll','Pitch','Yaw'};
                    for ki = 1:numel(lines_)
                        yd = get(lines_(ki),'YData');
                        if numel(yd) >= n
                            ci = mod(ki-1,3)+1;
                            plot(ax, t(i0:end), yd(i0:end), ...
                                'Color', cmap{ci}, 'LineWidth',0.8, 'DisplayName', lbls{ci});
                            hold(ax,'on');
                        end
                    end
                    close(tmpFig);
                    if ~isempty(get(ax,'Children'))
                        legend(ax,'show','Location','northeast','FontSize',6);
                        xlabel(ax,'Time [s]','FontSize',7);
                        ylabel(ax,'Error [deg]','FontSize',7);
                        grid(ax,'on');
                        return;
                    end
                end
            catch; end
            revgnss.ClockExactReportBuilder.noDataAxes_(ax);
        end

        % ................................................................
        function outPath = tryPlot_(figDir, fname, plotFcn)
            % tryPlot_  Run plotFcn returning a figure; export; return path or ''.
            outPath = '';
            try
                fig = plotFcn();
                if isgraphics(fig)
                    outPath = fullfile(figDir, fname);
                    exportgraphics(fig, outPath, 'ContentType','vector', ...
                        'BackgroundColor','white');
                    close(fig);
                end
            catch
            end
        end

        % ................................................................
        function fig = makeCompactFig_(titleStr)
            % makeCompactFig_  7 cm × 4.5 cm compact figure for longtable rows.
            fig = figure('Visible','off', 'Color','white');
            set(fig, 'Units','centimeters', 'Position',[0 0 7 4.5], ...
                'PaperUnits','centimeters', 'PaperSize',[7 4.5], ...
                'PaperPositionMode','auto');
            ax = axes(fig);
            set(ax, 'FontSize',7, 'FontName','Helvetica', 'Box','off');
            if nargin > 0 && ~isempty(titleStr)
                title(ax, titleStr, 'FontSize',7, 'FontWeight','normal');
            end
        end

        % ................................................................
        function fig = plotPositionError_(diag, t)
            fig = revgnss.ClockExactReportBuilder.makeCompactFig_('');
            ax  = gca(fig);
            try
                e = diag.getPositionErrors();
                if ~isempty(t) && ~isempty(e)
                    plot(ax, t, e, 'b-', 'LineWidth', 0.8);
                    xlabel(ax, 'Time [s]', 'FontSize',7);
                    ylabel(ax, 'Error [m]', 'FontSize',7);
                    grid(ax, 'on');
                    return;
                end
            catch; end
            revgnss.ClockExactReportBuilder.noDataAxes_(ax);
        end

        % ................................................................
        function fig = plotClockError_(diag, t)
            fig = revgnss.ClockExactReportBuilder.makeCompactFig_('');
            ax  = gca(fig);
            try
                c = diag.getClockBiasErrors();
                if ~isempty(t) && ~isempty(c)
                    plot(ax, t, c * 1e3, 'r-', 'LineWidth', 0.8);
                    xlabel(ax, 'Time [s]', 'FontSize',7);
                    ylabel(ax, 'Clock error [mm]', 'FontSize',7);
                    grid(ax, 'on');
                    return;
                end
            catch; end
            revgnss.ClockExactReportBuilder.noDataAxes_(ax);
        end

        % ................................................................
        function fig = plotClockDrift_(diag, t)
            fig = revgnss.ClockExactReportBuilder.makeCompactFig_('');
            ax  = gca(fig);
            try
                d = diag.getClockDriftErrors();
                if ~isempty(t) && ~isempty(d)
                    plot(ax, t, d, 'b-', 'LineWidth', 0.8);
                    xlabel(ax, 'Time [s]', 'FontSize',7);
                    ylabel(ax, 'Drift err [m/s]', 'FontSize',7);
                    grid(ax, 'on');
                    return;
                end
            catch; end
            revgnss.ClockExactReportBuilder.noDataAxes_(ax);
        end

        % ................................................................
        function fig = plotInnovationRMS_(diag, t)
            fig = revgnss.ClockExactReportBuilder.makeCompactFig_('');
            ax  = gca(fig);
            try
                pf = diag.getPrefitInnovationRMS();
                po = diag.getPostfitResidualRMS();
                if ~isempty(t) && ~isempty(pf)
                    plot(ax, t, pf, 'b-', 'LineWidth',0.8, 'DisplayName','Pre-fit');
                    hold(ax,'on');
                    if ~isempty(po)
                        plot(ax, t, po, 'r--', 'LineWidth',0.8, 'DisplayName','Post-fit');
                        legend(ax,'show','Location','northeast','FontSize',6);
                    end
                    xlabel(ax,'Time [s]','FontSize',7);
                    ylabel(ax,'RMS [m]','FontSize',7);
                    grid(ax,'on');
                    return;
                end
            catch; end
            revgnss.ClockExactReportBuilder.noDataAxes_(ax);
        end

        % ................................................................
        function fig = plotNIS_(diag, t)
            fig = revgnss.ClockExactReportBuilder.makeCompactFig_('');
            ax  = gca(fig);
            try
                n = diag.getNIS();
                if ~isempty(t) && ~isempty(n)
                    plot(ax, t, n, 'k-', 'LineWidth',0.8);
                    xlabel(ax,'Time [s]','FontSize',7);
                    ylabel(ax,'NIS [-]','FontSize',7);
                    grid(ax,'on');
                    return;
                end
            catch; end
            revgnss.ClockExactReportBuilder.noDataAxes_(ax);
        end

        % ................................................................
        function fig = plotVisibleTowers_(diag, t)
            fig = revgnss.ClockExactReportBuilder.makeCompactFig_('');
            ax  = gca(fig);
            try
                nv = diag.getNumVisibleTowers();
                if ~isempty(t) && ~isempty(nv)
                    stairs(ax, t, nv, 'k-', 'LineWidth',0.8);
                    xlabel(ax,'Time [s]','FontSize',7);
                    ylabel(ax,'Count','FontSize',7);
                    ylim(ax, [0 max(nv)+1]);
                    grid(ax,'on');
                    return;
                end
            catch; end
            revgnss.ClockExactReportBuilder.noDataAxes_(ax);
        end

        % ................................................................
        function fig = plotDOP_(diag, t)
            fig = revgnss.ClockExactReportBuilder.makeCompactFig_('');
            ax  = gca(fig);
            try
                gdop = diag.getGDOPLike();
                pdop = diag.getPDOPLike();
                if ~isempty(t) && ~isempty(gdop)
                    hold(ax,'on');
                    plot(ax,t,gdop,'b-','LineWidth',0.8,'DisplayName','GDOP');
                    if ~isempty(pdop)
                        plot(ax,t,pdop,'r--','LineWidth',0.8,'DisplayName','PDOP');
                    end
                    legend(ax,'show','Location','northeast','FontSize',6);
                    xlabel(ax,'Time [s]','FontSize',7);
                    ylabel(ax,'DOP [-]','FontSize',7);
                    grid(ax,'on');
                    return;
                end
            catch; end
            revgnss.ClockExactReportBuilder.noDataAxes_(ax);
        end

        % ................................................................
        function fig = plotTowerClocks_(diag)
            fig = revgnss.ClockExactReportBuilder.makeCompactFig_('');
            ax  = gca(fig);
            try
                M = diag.getTowerClockBiasMatrix();
                if iscell(M) && ~isempty(M) && ~isempty(M{end})
                    v = M{end};
                    if isnumeric(v) && ~isempty(v)
                        bar(ax, 1:numel(v), v*1e3, 0.5);
                        xlabel(ax,'Tower index','FontSize',7);
                        ylabel(ax,'Bias [mm]','FontSize',7);
                        grid(ax,'on');
                        return;
                    end
                end
            catch; end
            revgnss.ClockExactReportBuilder.noDataAxes_(ax);
        end

        % ................................................................
        function fig = plotPerSourceError_(diag, t)
            fig = revgnss.ClockExactReportBuilder.makeCompactFig_('');
            ax  = gca(fig);
            try
                psr = diag.getPerSourceErrorRMS();
                if isstruct(psr)
                    flds = fieldnames(psr);
                    cmap = lines(min(numel(flds),4));
                    hold(ax,'on');
                    ok = false;
                    for ki = 1:min(numel(flds),4)
                        v = psr.(flds{ki});
                        if isnumeric(v) && ~isempty(v) && ~isempty(t)
                            plot(ax,t(1:numel(v)),v,'-','Color',cmap(ki,:), ...
                                'LineWidth',0.8,'DisplayName',flds{ki});
                            ok = true;
                        end
                    end
                    if ok
                        legend(ax,'show','Location','northeast','FontSize',6);
                        xlabel(ax,'Time [s]','FontSize',7);
                        ylabel(ax,'RMS [m]','FontSize',7);
                        grid(ax,'on');
                        return;
                    end
                end
            catch; end
            revgnss.ClockExactReportBuilder.noDataAxes_(ax);
        end

        % ................................................................
        function noDataAxes_(ax)
            cla(ax); axis(ax,'off');
            text(ax, 0.5, 0.5, 'No data available.', 'Units','normalized', ...
                'HorizontalAlignment','center', 'VerticalAlignment','middle', ...
                'FontSize',7, 'FontAngle','italic', 'Color',[0.5 0.5 0.5], ...
                'Interpreter','none');
        end

        % ================================================================
        % TEX FILE WRITER
        % ================================================================

        function writeTexFile_(texPath, cfg, summary, diag, figDir, plotPaths, stem)
            fid = fopen(texPath, 'w', 'n', 'UTF-8');
            if fid < 0
                error('ClockExactReportBuilder:texWriteFailed', ...
                    'Cannot write .tex: %s', texPath);
            end
            CE  = revgnss.ClockExactReportBuilder;
            esc = @CE.esc_;

            scenarioName = CE.getCfgStr_(cfg, {'asset','name'}, 'GEO-1');
            ver  = CE.getCfgStr_(cfg, {'report','version'}, '1.00');
            ts   = datestr(now, 'yyyy-mm-dd HH:MM:SS'); %#ok<TNOW1,DATST>
            if isfield(summary,'timestamp'); ts = summary.timestamp; end
            sha  = CE.getGitSHA_();
            nTwr = 5;  try; nTwr = cfg.scenario.nTowers;    catch; end
            nRx  = 1;  try; nRx  = cfg.scenario.nReceivers; catch; end
            dur  = 3600; try; dur = cfg.simulation.duration_s; catch; end
            dt   = 1;    try; dt  = cfg.simulation.dt_s;       catch; end

            % ---- Preamble -----------------------------------------------
            fprintf(fid, '\\documentclass[11pt,a4paper]{article}\n');
            fprintf(fid, '\\usepackage[margin=1.7cm]{geometry}\n');
            fprintf(fid, '\\usepackage{amsmath}\n');
            fprintf(fid, '\\usepackage{amssymb}\n');
            fprintf(fid, '\\usepackage{graphicx}\n');
            fprintf(fid, '\\usepackage{longtable}\n');
            fprintf(fid, '\\usepackage{array}\n');
            fprintf(fid, '\\usepackage{booktabs}\n');
            fprintf(fid, '\\usepackage{xcolor}\n');
            fprintf(fid, '\\usepackage{hyperref}\n');
            fprintf(fid, '\\setlength{\\parindent}{0pt}\n');
            fprintf(fid, '\\setlength{\\tabcolsep}{3pt}\n');
            fprintf(fid, '\\renewcommand{\\arraystretch}{1.18}\n');
            fprintf(fid, '\\hypersetup{colorlinks=true,linkcolor=black,urlcolor=blue}\n');
            fprintf(fid, '\\begin{document}\n');

            % ---- Title block -------------------------------------------
            try; stgNum = char(revgnss.ReportStatus.current().stage); catch; stgNum = '37'; end
            fprintf(fid, '\\begin{center}\n');
            fprintf(fid, '{\\Large \\textbf{Reverse-GNSS Spacecraft Multi-Observable EKF Report}}\\\\[4pt]\n');
            fprintf(fid, '{\\large Scenario: \\textbf{%s}}\\\\[4pt]\n', esc(scenarioName));
            fprintf(fid, '{\\small Generated by \\texttt{oo\\_v1} v%s on %s \\\\ Stage %s \\\\ Commit: %s}\n', ...
                esc(ver), esc(ts), esc(stgNum), sha);
            fprintf(fid, '\\end{center}\n');
            fprintf(fid, '\\vspace{0.3cm}\n');

            % ---- Sections -----------------------------------------------
            CE.writeScenarioSummary_(fid, cfg, summary, diag, nTwr, nRx, dur, dt, esc);
            CE.writeStateEstimation_(fid, plotPaths, stem, cfg, diag, figDir);
            CE.writeMeasurementValidation_(fid, plotPaths, stem, figDir);
            CE.writePerReceiverDiagnostics_(fid, plotPaths, stem, figDir, nRx);
            CE.writeOscillatorValidation_(fid, plotPaths, stem, figDir, cfg);
            CE.writeClockObservability_(fid, diag, cfg);
            CE.writeTxCodeBias_(fid, diag, cfg);
            CE.writeNumericalSummary_(fid, cfg, summary, diag);
            CE.writeFinalScientificClosure_(fid, summary);

            fprintf(fid, '\\end{document}\n');
            fclose(fid);
        end

        % ================================================================
        % SECTION 1 — SCENARIO SUMMARY
        % ================================================================

        function writeScenarioSummary_(fid, cfg, summary, diag, nTwr, nRx, dur, dt, esc)
            CE = revgnss.ClockExactReportBuilder;

            scenarioName = CE.getCfgStr_(cfg, {'asset','name'}, 'GEO-1');
            codeMode = CE.getCfgStr_(cfg, {'measurements','codeMode'},   'singleFrequency');
            carrMode = CE.getCfgStr_(cfg, {'measurements','carrierMode'}, 'diagnostic');
            clkMode  = CE.getCfgStr_(cfg, {'estimator','towerClockMode'}, 'perfectTruth');
            testLine = revgnss.ReportStatus.summaryLines();
            if isempty(testLine); testLine = {'Test status: see tests/ folder.'}; end
            testStr  = testLine{1};

            fprintf(fid, '\\section{Scenario Summary}\n');
            fprintf(fid, ['This report documents a reverse-GNSS simulation run using the oo\\_v1 ' ...
                'MATLAB simulator. ' ...
                'The ground segment transmits reverse-GNSS code, Doppler, and carrier observables to a GEO space receiver when enabled. ' ...
                'The EKF estimates spacecraft position, velocity, attitude, and receiver clock states ' ...
                'from the available observables. ' ...
                'The run length is %.2f hours (%.0f s) with %.1f s sampling and %d ground towers, ' ...
                '%d receiver phase centre(s). ' ...
                'Code mode: \\texttt{%s}. Carrier mode: \\texttt{%s}. ' ...
                'Tower clock mode: \\texttt{%s}. ' ...
                '%s\n\n'], ...
                dur/3600, dur, dt, nTwr, nRx, esc(codeMode), esc(carrMode), esc(clkMode), ...
                esc(testStr));

            % 1.1 Receiver Clock Architecture
            fprintf(fid, '\\subsection{Receiver Clock Architecture Interpretation}\n');
            fprintf(fid, ['Receiver clock bias $b_{rx}$ has a \\textbf{positive} sign ' ...
                '(adds to pseudorange). ' ...
                'Tower transmitter clock bias $b_{twr}$ has a \\textbf{negative} sign ' ...
                '(subtracts from pseudorange). ' ...
                'Troposphere delay $T$ is \\textbf{positive} for both code and carrier. ' ...
                'Ionosphere delay $I_f$ is \\textbf{positive} for code (group delay) and ' ...
                '\\textbf{negative} for carrier (phase advance). ' ...
                'Carrier ambiguity $B_\\phi$ is a float value in metres (raw L1, no integer fixing).\n\n']);
            % Clock mode / gauge summary (Stage 9: per-mode scientific narrative)
            clockMd1  = CE.getCfgStr_(cfg, {'clock','mode'}, 'spacecraftReceiverClockOnly');
            gaugeMd1  = CE.getCfgStr_(cfg, {'clock','gauge','mode'}, 'externalTowerCorrections');
            refTwr1   = CE.getCfgNum_(cfg, {'clock','gauge','referenceTowerIndex'}, 1);
            sigBias1  = CE.getCfgNum_(cfg, {'clock','gauge','sigmaBias_m'},    1e-6);
            sigDrift1 = CE.getCfgNum_(cfg, {'clock','gauge','sigmaDrift_mps'}, 1e-9);
            fprintf(fid, ['\\textbf{Clock architecture:} \\texttt{%s}. ' ...
                '\\textbf{Clock gauge:} \\texttt{%s}.\n\n'], esc(clockMd1), esc(gaugeMd1));
            if strcmp(clockMd1,'spacecraftReceiverClockOnly')
                fprintf(fid, ['Tower clock states are not included in the EKF. ' ...
                    'The EKF estimates the spacecraft receiver clock only. ' ...
                    'One-way pseudorange is gauge-ambiguous: $b_{rx}$ and $b_{twr}$ cannot be ' ...
                    'separated without an external datum or gauge constraint; here the gauge ' ...
                    'is resolved by external tower clock corrections.\n\n']);
            elseif strcmp(gaugeMd1,'fixReferenceTower')
                fprintf(fid, ['\\textbf{Gauge -- fixReferenceTower (tower %d):} ' ...
                    'The selected reference tower defines the ground clock gauge. ' ...
                    'Its tower clock bias and drift are constrained to zero by EKF ' ...
                    'pseudo-measurement rows ($\\sigma_{bias}=%g$\\,m, ' ...
                    '$\\sigma_{drift}=%g$\\,m/s). ' ...
                    'All receiver and tower clock estimates are therefore relative to ' ...
                    'this tower timescale. ' ...
                    'Pseudo-measurement: $z=0$, $h=\\hat{b}_{twr,ref}$, ' ...
                    '$H_{gauge}(b_{twr,ref})=1$, $R_{gauge}=\\sigma_{bias}^2$.\n\n'], ...
                    refTwr1, sigBias1, sigDrift1);
            elseif strcmp(gaugeMd1,'meanGroundClockGauge')
                fprintf(fid, ['\\textbf{Gauge -- meanGroundClockGauge:} ' ...
                    'The mean of all estimated tower clocks defines the ground clock gauge. ' ...
                    'The EKF inserts zero-mean pseudo-measurement rows for tower clock bias ' ...
                    '($\\sigma_{bias}=%g$\\,m) and drift ($\\sigma_{drift}=%g$\\,m/s). ' ...
                    'The spacecraft receiver clock is therefore estimated relative to the ' ...
                    'mean ground-clock timescale. ' ...
                    'Pseudo-measurement: $z=0$, $h=\\frac{1}{N}\\sum_i \\hat{b}_{twr,i}$, ' ...
                    '$H_{gauge}(b_{twr,i})=\\frac{1}{N}$, $R_{gauge}=\\sigma_{bias}^2$.\n\n'], ...
                    sigBias1, sigDrift1);
            else
                fprintf(fid, ['One-way pseudorange is gauge-ambiguous: $b_{rx}$ and $b_{twr}$ ' ...
                    'cannot be separated without an external datum or gauge constraint. ' ...
                    'The gauge mode specifies how this datum ambiguity is resolved.\n\n']);
            end

            % 1.2 Scenario Geometry
            fprintf(fid, '\\subsection{Scenario Geometry and Receiver Architecture}\n');
            fprintf(fid, ['Truth pseudorange: ' ...
                '$P = \\|\\mathbf{r}_{sc} + \\mathbf{C}_{BI}\\mathbf{l}_{a,B} - \\mathbf{r}_{twr}\\|' ...
                '+ b_{rx}^{true} - b_{twr}^{true} + d_{truth} + \\nu$. ' ...
                'Estimator prediction: $\\hat{P} = \\|\\hat{\\mathbf{r}}_{sc} + \\hat{\\mathbf{C}}_{BI}' ...
                '\\mathbf{l}_{a,B} - \\mathbf{r}_{twr}\\| + \\hat{b}_{rx} + d_{model}$. ' ...
                'Range geometry uses ECEF positions at the receiver epoch. ' ...
                'Optional light-time and Sagnac corrections are applied when enabled.\n\n']);

            % 1.3 EKF State Vector
            fprintf(fid, '\\subsection{EKF State Vector}\n');
            fprintf(fid, ['The filter is an error-state EKF. The 14 base states are: ' ...
                'position (3), velocity (3), attitude error (3), angular rate (3), ' ...
                'receiver clock bias (1), receiver clock drift (1).\n\n']);
            fprintf(fid, '\\begin{center}\n\\scriptsize\n');
            fprintf(fid, ['\\begin{longtable}{@{}>{\\raggedright\\arraybackslash}p{0.055\\textwidth}' ...
                '>{\\raggedright\\arraybackslash}p{0.175\\textwidth}' ...
                '>{\\raggedright\\arraybackslash}p{0.295\\textwidth}' ...
                '>{\\raggedright\\arraybackslash}p{0.070\\textwidth}' ...
                '>{\\raggedright\\arraybackslash}p{0.270\\textwidth}@{}}\n']);
            fprintf(fid, '\\toprule\n');
            fprintf(fid, '\\textbf{Index} & \\textbf{Symbol} & \\textbf{Description} & \\textbf{Unit} & \\textbf{DynamicCouplingNote}\\\\\n');
            fprintf(fid, '\\midrule\n');
            stRows = { ...
                '1','$\delta r_{E,x}$','ECEF X position','m','Coupled to velocity'; ...
                '2','$\delta r_{E,y}$','ECEF Y position','m','Coupled to velocity'; ...
                '3','$\delta r_{E,z}$','ECEF Z position','m','Coupled to velocity'; ...
                '4','$\delta v_{E,x}$','ECEF X velocity','m/s','Affects future position'; ...
                '5','$\delta v_{E,y}$','ECEF Y velocity','m/s','Affects future position'; ...
                '6','$\delta v_{E,z}$','ECEF Z velocity','m/s','Affects future position'; ...
                '7','$\delta\theta_{B,x}$','Body attitude error x','rad','Observable via lever arms'; ...
                '8','$\delta\theta_{B,y}$','Body attitude error y','rad','Observable via lever arms'; ...
                '9','$\delta\theta_{B,z}$','Body attitude error z','rad','Observable via lever arms'; ...
                '10','$\delta\omega_{B,x}$','Body angular rate x','rad/s','Affects future attitude'; ...
                '11','$\delta\omega_{B,y}$','Body angular rate y','rad/s','Affects future attitude'; ...
                '12','$\delta\omega_{B,z}$','Body angular rate z','rad/s','Affects future attitude'; ...
                '13','$\delta b_{rx}$','RX clock bias (POSITIVE sign)','m','Directly estimated'; ...
                '14','$\delta\dot{b}_{rx}$','RX clock drift','m/s','Propagates to clock bias'; ...
            };
            for k = 1:size(stRows,1)
                fprintf(fid, '%s & %s & %s & %s & %s\\\\\n', stRows{k,:});
            end
            % Extended states
            doTwrClk = isfield(cfg,'estimator') && isfield(cfg.estimator,'estimateTowerClocks') ...
                && cfg.estimator.estimateTowerClocks;
            doAmb = isfield(cfg,'measurements') && isfield(cfg.measurements,'carrierMode') ...
                && strcmp(cfg.measurements.carrierMode,'ekfFloat');
            ambMode = CE.getCfgStr_(cfg, {'estimation','ambiguityMode'}, 'none');
            doZwd = isfield(cfg,'estimation') && isfield(cfg.estimation,'troposphereMode') ...
                && strcmp(cfg.estimation.troposphereMode,'perTowerZwd');
            idx = 15;
            if doTwrClk
                for k = 1:nTwr
                    fprintf(fid, '%d & $\\delta b_{\\mathrm{twr},%d}$ & Tower %d clock bias (NEGATIVE sign in meas.) & m & Estimated tower bias\\\\\n', idx, k, k);
                    idx = idx+1;
                    fprintf(fid, '%d & $\\delta\\dot{b}_{\\mathrm{twr},%d}$ & Tower %d clock drift & m/s & Estimated tower drift\\\\\n', idx, k, k);
                    idx = idx+1;
                end
            end
            if doAmb
                if strcmp(ambMode,'floatPerTowerReceiverSignal')
                    for k = 1:nTwr
                        for ri = 1:nRx
                            fprintf(fid, '%d & $B_{\\phi,L1,t%d,r%d}$ & L1 carrier float ambiguity, tower %d receiver %d & m & Receiver-indexed float state; no integer fixing\\\\\n', ...
                                idx, k, ri, k, ri);
                            idx = idx+1;
                        end
                    end
                else
                    for k = 1:nTwr
                        fprintf(fid, '%d & $B_{\\phi,L1,t%d}$ & L1 carrier float ambiguity, tower %d & m & Tower/signal float state; no integer fixing\\\\\n', idx, k, k);
                        idx = idx+1;
                    end
                end
            end
            if doZwd
                for k = 1:nTwr
                    fprintf(fid, '%d & $\\mathrm{ZWD}_{\\mathrm{twr}%d}$ & Zenith wet delay, tower %d & m & Gauss-Markov; mapped by $m_w(\\mathrm{el})$\\\\\n', idx, k, k);
                    idx = idx+1; %#ok<NASGU>
                end
            end
            fprintf(fid, '\\bottomrule\n\\end{longtable}\n\\normalsize\n\\end{center}\n');

            % 1.4 Measurement Model
            fprintf(fid, '\\subsection{Pseudorange Measurement Model and Observation Matrix}\n');
            f1 = 1575.42e6; f2 = 1227.60e6;
            alpha =  f1^2 / (f1^2 - f2^2);
            beta  = -f2^2 / (f1^2 - f2^2);
            fprintf(fid, ['\\[\nP_f = \\rho + b_{rx} - b_{twr} + T + I_f + d_{\\rm code} + \\nu_P,' ...
                '\\quad I_f \\geq 0 \\;(\\text{positive for code})\n\\]\n']);
            fprintf(fid, ['\\[\n\\Phi_f = \\rho + b_{rx} - b_{twr} + T - I_f + B_\\phi + d_{\\rm phase} + \\nu_\\Phi,' ...
                '\\quad -I_f \\;(\\text{negative for carrier})\n\\]\n']);
            fprintf(fid, '\\[\\quad B_\\phi \\text{ is float ambiguity in metres (L1 only, no integer fixing)}\\]\n');
            fprintf(fid, ['\\[\nP_{\\rm IF} = \\alpha P_{L1} + \\beta P_{L2},' ...
                '\\quad \\alpha = %.6f,\\quad \\beta = %.6f\n\\]\n'], alpha, beta);

            fprintf(fid, '\\begin{center}\n\\scriptsize\n');
            fprintf(fid, ['\\begin{longtable}{@{}>{\\raggedright\\arraybackslash}p{0.273\\textwidth}' ...
                '>{\\raggedright\\arraybackslash}p{0.273\\textwidth}' ...
                '>{\\raggedright\\arraybackslash}p{0.273\\textwidth}@{}}\n']);
            fprintf(fid, '\\toprule\n');
            fprintf(fid, '\\textbf{Term} & \\textbf{Expression} & \\textbf{Meaning}\\\\\n');
            fprintf(fid, '\\midrule\n');
            termRows = { ...
                'geometric range', '$\rho = \|\mathbf{r}_{sc} + \mathbf{C}_{BI}\mathbf{l}_{a,B} - \mathbf{r}_{twr}\|$', 'Phase-centre to tower range'; ...
                'receiver clock', '$+b_{rx}$ [m] (POSITIVE sign)', 'Shared spacecraft RX clock bias'; ...
                'tower clock', '$-b_{twr}$ [m] (NEGATIVE sign)', 'Ground transmitter clock bias'; ...
                'troposphere', '$+T$ (code and carrier, POSITIVE)', 'Slant wet+dry delay, same sign'; ...
                'iono code', '$+I_f$ (POSITIVE for code)', 'First-order group delay'; ...
                'iono carrier', '$-I_f$ (NEGATIVE for carrier)', 'First-order phase advance'; ...
                'float ambiguity', '$+B_\phi$ [m] (L1 only)', 'L1 carrier cycle ambiguity, float'; ...
                'measurement noise', '$\nu \sim N(0, R)$', 'Code / carrier / Doppler noise'; ...
            };
            for k = 1:size(termRows,1)
                fprintf(fid, '%s & %s & %s\\\\\n', termRows{k,:});
            end
            fprintf(fid, '\\bottomrule\n\\end{longtable}\n\\normalsize\n\\end{center}\n');

            % 1.5 Starting positions
            fprintf(fid, '\\subsection{Starting Positions}\n');
            fprintf(fid, '\\begin{center}\n\\scriptsize\n');
            fprintf(fid, ['\\begin{longtable}{@{}>{\\raggedright\\arraybackslash}p{0.12\\textwidth}' ...
                '>{\\raggedright\\arraybackslash}p{0.14\\textwidth}' ...
                '>{\\raggedright\\arraybackslash}p{0.17\\textwidth}' ...
                '>{\\raggedright\\arraybackslash}p{0.15\\textwidth}' ...
                '>{\\raggedright\\arraybackslash}p{0.15\\textwidth}' ...
                '>{\\raggedright\\arraybackslash}p{0.12\\textwidth}@{}}\n']);
            fprintf(fid, '\\toprule\n');
            fprintf(fid, '\\textbf{Type} & \\textbf{Name} & \\textbf{Frame} & \\textbf{Coord 1} & \\textbf{Coord 2} & \\textbf{Coord 3}\\\\\n');
            fprintf(fid, '\\midrule\n');
            % Asset
            rGeo = zeros(3,1);
            try; rGeo = cfg.asset.r_ecef_m; catch; end
            fprintf(fid, 'SpaceAsset & %s & ECEF center of mass & X %.5g m & Y %.5g m & Z %.5g m\\\\\n', ...
                esc(scenarioName), rGeo(1), rGeo(2), rGeo(3));
            % Towers
            if isfield(cfg,'towers')
                nT = min(nTwr, numel(cfg.towers));
                for k = 1:nT
                    tname = ''; lat_d = 0; lon_d = 0; alt_m = 0;
                    try; tname = cfg.towers(k).name; catch; end
                    try; lat_d = cfg.towers(k).lat_rad * 180/pi; catch; end
                    try; lon_d = cfg.towers(k).lon_rad * 180/pi; catch; end
                    try; alt_m = cfg.towers(k).alt_m; catch; end
                    fprintf(fid, 'Tower & %s & Fixed geodetic & Lat %.2f deg & Lon %.2f deg & Alt %.1f m\\\\\n', ...
                        esc(tname), lat_d, lon_d, alt_m);
                end
            end
            fprintf(fid, '\\bottomrule\n\\end{longtable}\n\\normalsize\n\\end{center}\n');

            % 1.6 Component Status
            fprintf(fid, '\\begin{center}\n');
            fprintf(fid, '\\begin{tabular}{p{0.39\\textwidth}p{0.18\\textwidth}p{0.34\\textwidth}}\n');
            fprintf(fid, '\\toprule\n');
            fprintf(fid, '\\textbf{Component or scenario} & \\textbf{Status} & \\textbf{Report action}\\\\\n');
            fprintf(fid, '\\midrule\n');
            CE.writeComponentRows_(fid, cfg, esc);
            fprintf(fid, '\\bottomrule\n\\end{tabular}\n\\end{center}\n');
            fprintf(fid, '\\clearpage\n');
        end


        % ================================================================
        % COMPONENT STATUS ROWS (1.6)
        % ================================================================

        function writeComponentRows_(fid, cfg, esc)
            CE = revgnss.ClockExactReportBuilder;
            % Clock mode / gauge for status rows
            clkMd2  = CE.getCfgStr_(cfg, {'clock','mode'}, 'spacecraftReceiverClockOnly');
            gaugMd2 = CE.getCfgStr_(cfg, {'clock','gauge','mode'}, 'externalTowerCorrections');
            hwDel2  = CE.getLogical_(cfg, {'clock','hardwareDelay','estimatePerTower'}, false);
            carrEKF2 = strcmp(CE.getCfgStr_(cfg, {'measurements','carrierMode'}, 'diagnostic'), 'ekfFloat') || ...
                CE.getLogical_(cfg, {'measurements','carrierPhase','useInEKF'}, false);
            rows = { ...
                'Ground segment geometry',           true,   'Included in this report.'; ...
                'Receiver clock (spacecraft)',        true,   'Included in this report.'; ...
                'Tower transmitter clock',           CE.getLogical_(cfg,{'errors','towerClock','enable'},false), ''; ...
                'Sagnac correction (truth)',          CE.getLogical_(cfg,{'physics','sagnac','truth','enable'},false), ''; ...
                'Sagnac correction (model)',          CE.getLogical_(cfg,{'physics','sagnac','model','enable'},false), ''; ...
                'Shapiro delay (truth)',              CE.getLogical_(cfg,{'physics','relativity','shapiro','truth','enable'},false), ''; ...
                'Troposphere (truth)',                CE.getLogical_(cfg,{'errors','troposphere','truth','enable'},false), ''; ...
                'Troposphere (model)',                CE.getLogical_(cfg,{'errors','troposphere','model','enable'},false), ''; ...
                'Ionosphere (truth)',                 CE.getLogical_(cfg,{'errors','ionosphere','truth','enable'},false), ''; ...
                'Ionosphere (model)',                 CE.getLogical_(cfg,{'errors','ionosphere','model','enable'},false), ''; ...
                'Two-frequency L1+L2',               CE.getLogical_(cfg,{'signals','twoFrequency','enable'},false), ''; ...
                'Doppler in EKF',                    CE.getLogical_(cfg,{'measurements','doppler','useInEKF'},false), ''; ...
                'Carrier phase (enabled)',            CE.getLogical_(cfg,{'measurements','carrierPhase','enable'},false), ''; ...
                'Carrier phase in EKF',              carrEKF2, 'Float ambiguity EKF (L1 raw, no integer fixing).'; ...
                'Hardware delay (truth)',             CE.getLogical_(cfg,{'errors','hardwareDelay','truth','enable'},false), ''; ...
                'Multipath (truth)',                  CE.getLogical_(cfg,{'errors','multipath','truth','enable'},false), ''; ...
                'Antenna PCO (truth)',                CE.getLogical_(cfg,{'effects','antennaPCO','truth','enable'},false), ''; ...
                'Antenna PCV (truth)',                CE.getLogical_(cfg,{'effects','antennaPCV','truth','enable'},false), ''; ...
                'Joint tower clock EKF',             strcmp(clkMd2,'includeTowerClocksInEKF'), sprintf('Clock mode: %s. Gauge: %s.', clkMd2, gaugMd2); ...
                'Per-tower hardware delay EKF',      hwDel2, 'Not implemented (v1 -- config flag only).'; ...
                'Integer ambiguity fixing',           false, 'Not implemented (v1).'; ...
                'L2 carrier EKF',                    false, 'Not implemented (v1).'; ...
                'ANTEX / SP3 / CLK parsers',         false, 'Not implemented (v1).'; ...
                'PPP-grade processing',              false, 'Not implemented (v1).'; ...
            };
            for k = 1:size(rows,1)
                comp = esc(rows{k,1});
                isEn = rows{k,2};
                act  = rows{k,3};
                if isEn
                    stTex = '\textcolor{green!45!black}{Enabled}';
                    if isempty(act); act = 'Included in this report.'; end
                else
                    stTex = '\textcolor{gray}{Disabled}';
                    if isempty(act); act = 'Not part of current run.'; end
                end
                fprintf(fid, '%s & %s & %s\\\\\n', comp, stTex, esc(act));
                fprintf(fid, '\\midrule\n');
            end
        end

        % ================================================================
        % SECTION 2 — STATE ESTIMATION VALIDATION
        % ================================================================

        function writeStateEstimation_(fid, plotPaths, stem, cfg, diag, figDir)
            CE = revgnss.ClockExactReportBuilder;
            fprintf(fid, '\\section{State Estimation Validation}\n');
            fprintf(fid, ['The plots compare EKF state estimates with truth using deterministic truth ' ...
                'differencing. No measurement noise is injected unless the noise toggle is enabled. ' ...
                'Position error is the 3-D Euclidean norm of the estimated-minus-true ECEF position.\n\n']);
            fprintf(fid, CE.plotTableHeader_());

            CE.writeRow_(fid, CE.figRef_(plotPaths,'posErr',figDir,stem), ...
                'Combined EKF Local Position Error', ...
                ['The plot compares the EKF 3D position estimate with truth. ' ...
                 'The diagnostic is deterministic truth differencing; no stochastic noise is ' ...
                 'injected unless the noise toggle is enabled.']);

            CE.writeRow_(fid, CE.figRef_(plotPaths,'posErrZoom',figDir,stem), ...
                'Position Error — Final 10\% Zoom', ...
                'Position error over the final 10\% of simulation time. Confirms convergence.');

            CE.writeRow_(fid, CE.figRef_(plotPaths,'clkErr',figDir,stem), ...
                'Clock Synchronisation Error', ...
                ['The EKF clock-bias estimation error against the covariance envelope. ' ...
                 'The clock process follows the selected oscillator power-law noise model ' ...
                 '(Brown-Hwang two-state). Receiver clock sign is POSITIVE.']);

            CE.writeRow_(fid, CE.figRef_(plotPaths,'clkErrZoom',figDir,stem), ...
                'Clock Bias Error — Final 10\% Zoom', ...
                'Clock bias estimation error over the final 10\% of simulation time.');

            CE.writeRow_(fid, CE.figRef_(plotPaths,'clkDrift',figDir,stem), ...
                'Clock Drift / Fractional Frequency', ...
                ['The clock drift state (m/s equivalent). ' ...
                 'Fractional frequency deviation = drift / c. ' ...
                 'Brown-Hwang two-state process noise model.']);

            CE.writeRow_(fid, CE.figRef_(plotPaths,'clkDriftZoom',figDir,stem), ...
                'Clock Drift Error — Final 10\% Zoom', ...
                'Clock drift estimation error over the final 10\% of simulation time.');

            CE.writeRow_(fid, CE.figRef_(plotPaths,'nis',figDir,stem), ...
                'Normalised Innovation Squared', ...
                ['NIS is a chi-square consistency diagnostic only when measurement noise is ' ...
                 'stochastic, zero-mean, and correctly represented in R. ' ...
                 'In deterministic validation runs NIS is a numerical conditioning diagnostic only.']);

            % Attitude rows — conditional
            doAtt = isfield(cfg,'estimator') && isfield(cfg.estimator,'estimateAttitude') ...
                && cfg.estimator.estimateAttitude;
            if doAtt
                CE.writeRow_(fid, CE.figRef_(plotPaths,'attComp',figDir,stem), ...
                    'Attitude Error Components: Roll, Pitch, Yaw', ...
                    ['Roll, pitch, and yaw estimation errors from diagnostic truth history. ' ...
                     'If absent, attitude history or plot export was unavailable.']);
                CE.writeRow_(fid, CE.figRef_(plotPaths,'attNorm',figDir,stem), ...
                    '3D Attitude Error Norm', ...
                    'Euclidean norm of roll/pitch/yaw error in degrees.');
                CE.writeRow_(fid, CE.figRef_(plotPaths,'attCompZoom',figDir,stem), ...
                    'Attitude Components — Final 10\% Zoom', ...
                    'Roll/pitch/yaw errors over the final 10\% of simulation time.');
                CE.writeRow_(fid, CE.figRef_(plotPaths,'attSigma',figDir,stem), ...
                    'Attitude Covariance Sigma', ...
                    'Square-root sum of EKF Euler-angle covariance diagonal in degrees.');
            else
                CE.writeRow_(fid, '', ...
                    'EKF Attitude States', ...
                    ['Attitude estimation is not active in this run; no attitude plot is produced.']);
            end

            fprintf(fid, CE.plotTableFooter_());
            fprintf(fid, '\\clearpage\n');
        end

        % ================================================================
        % SECTION 3 — MEASUREMENT AND GEOMETRY VALIDATION
        % ================================================================

        function writeMeasurementValidation_(fid, plotPaths, stem, figDir)
            CE = revgnss.ClockExactReportBuilder;
            fprintf(fid, '\\section{Measurement and Geometry Validation}\n');
            fprintf(fid, ['Pre-fit residuals test the predicted measurement model before correction. ' ...
                'Post-fit residuals show how much error remains after the EKF update. ' ...
                'RMS residuals are useful diagnostics, but they are not by themselves a proof ' ...
                'of statistical consistency. ' ...
                'In deterministic or partly deterministic validation runs, NIS should be interpreted ' ...
                'as a numerical conditioning and model-coupling diagnostic.\n\n']);
            fprintf(fid, CE.plotTableHeader_());

            CE.writeRow_(fid, CE.figRef_(plotPaths,'innovRMS',figDir,stem), ...
                'Pseudorange Pre-Fit and Post-Fit Residual RMS', ...
                ['The pre-fit innovation (before EKF correction) and post-fit residual (after update) ' ...
                 'are plotted separately. With noise disabled this is a deterministic geometry, ' ...
                 'clock-state coupling, and estimator convergence diagnostic.']);

            CE.writeRow_(fid, CE.figRef_(plotPaths,'perSrc',figDir,stem), ...
                'Error Source Contributions', ...
                ['Breakdown of the raw code error into physical contributions: ' ...
                 'code (geometric and clock residual), troposphere truth-model mismatch, ' ...
                 'ionosphere truth-model mismatch.']);

            CE.writeRow_(fid, CE.figRef_(plotPaths,'visTowers',figDir,stem), ...
                'Tower Rows Used by the EKF', ...
                ['The number of ground towers passing the elevation mask at each epoch. ' ...
                 'Elevation mask applied per-tower before including in the EKF update.']);

            CE.writeRow_(fid, '', ...
                'Measurement Covariance Contribution', ...
                ['Per-row root-variance contributions represented in the measurement covariance. ' ...
                 'Receiver tracking noise, atmospheric residual, and tower-clock contributions ' ...
                 'are kept separate. No plot generated in this oo\_v1 run.']);

            CE.writeRow_(fid, CE.figRef_(plotPaths,'dop',figDir,stem), ...
                'Ground-to-Space Geometry (DOP Metrics)', ...
                ['GDOP, PDOP, TDOP are geometry-derived scaling factors computed from the ' ...
                 'pseudorange observation matrix. Lower DOP values indicate better geometric diversity. ' ...
                 'Tower network DOP near 1--2 is typical for GEO coverage.']);

            fprintf(fid, CE.plotTableFooter_());
            fprintf(fid, '\\clearpage\n');
        end

        % ================================================================
        % SECTION 4 — PER-RECEIVER MEASUREMENT DIAGNOSTICS
        % ================================================================

        function writePerReceiverDiagnostics_(fid, plotPaths, stem, figDir, nRx)
            CE = revgnss.ClockExactReportBuilder;
            fprintf(fid, '\\section{Per-Receiver Measurement Diagnostics}\n');
            fprintf(fid, ['Receiver rows are generated from the enabled RX phase centres ' ...
                'mounted on the SpaceAsset. This run has %d receiver phase centre(s). ' ...
                'Receiver clock, hardware delays, and attitude-derived antenna offsets ' ...
                'are included in the pseudorange model.\n\n'], nRx);
            fprintf(fid, CE.plotTableHeader_());

            CE.writeRow_(fid, '', ...
                'Per-Receiver Pre-Fit Pseudorange Residual RMS', ...
                ['Each curve is the tower-wise RMS pre-fit pseudorange residual for one receiver ' ...
                 'element. No separate per-receiver diagnostic plot available in this oo\_v1 run.']);

            CE.writeRow_(fid, '', ...
                'Per-Receiver Post-Fit Pseudorange Residual RMS', ...
                ['Each curve is the tower-wise RMS post-fit pseudorange residual after the EKF update. ' ...
                 'No separate per-receiver diagnostic plot available in this oo\_v1 run.']);

            CE.writeRow_(fid, '', ...
                'Per-Receiver Per-Tower Residual Heatmaps', ...
                ['Residuals by receiver and tower. ' ...
                 'Blank samples are non-visible or unused tower/receiver links. ' ...
                 'Not available in this oo\_v1 run.']);

            CE.writeRow_(fid, '', ...
                'Per-Receiver Pseudorange-Minus-Geometric Range', ...
                ['Pseudorange excess over geometric range per receiver. Contains clock terms. ' ...
                 'Not available as a standalone diagnostic in this oo\_v1 run.']);

            fprintf(fid, CE.plotTableFooter_());
            fprintf(fid, '\\clearpage\n');
        end

        % ================================================================
        % SECTION 5 — OSCILLATOR STABILITY VALIDATION
        % ================================================================

        function writeOscillatorValidation_(fid, plotPaths, stem, figDir, cfg)
            CE = revgnss.ClockExactReportBuilder;
            clkMode = CE.getCfgStr_(cfg, {'estimator','towerClockMode'}, 'perfectTruth');
            fprintf(fid, '\\section{Oscillator Stability Validation}\n');
            fprintf(fid, CE.plotTableHeader_());

            CE.writeRow_(fid, '', ...
                'Oscillator Stability Check (Allan Deviation)', ...
                ['Theoretical Allan deviation profiles for the spacecraft oscillator and tower oscillators. ' ...
                 'No Allan deviation plot generated in this oo\_v1 run (no overlapping-ADEV estimator).']);

            CE.writeRow_(fid, CE.figRef_(plotPaths,'clkErr',figDir,stem), ...
                'Receiver Clock Bias Tracking', ...
                ['Spacecraft receiver clock bias estimation error. ' ...
                 'Receiver clock sign is POSITIVE (adds to pseudorange). ' ...
                 'The clock bias converges as pseudorange innovations correct the clock state.']);

            CE.writeRow_(fid, CE.figRef_(plotPaths,'clkDrift',figDir,stem), ...
                'Clock Drift / Fractional Frequency', ...
                ['Clock drift state (m/s equivalent). Brown-Hwang two-state model. ' ...
                 'Fractional frequency deviation = drift / c.']);

            CE.writeRow_(fid, CE.figRef_(plotPaths,'twrClocks',figDir,stem), ...
                'Tower Clock Product Validation', ...
                ['Bar chart of per-tower clock truth bias at the final epoch. ' ...
                 sprintf('Tower clock mode: \\texttt{%s}. ', CE.esc_(clkMode)) ...
                 'Tower clock sign is NEGATIVE in the pseudorange model. ' ...
                 'Zero bar means truth and model clock agree.']);

            fprintf(fid, CE.plotTableFooter_());
            fprintf(fid, '\\clearpage\n');
        end

        % ================================================================
        % SECTION 6 — DISABLED COMPONENTS
        % ================================================================

        % ================================================================
        % SECTION 6B — CLOCK OBSERVABILITY AND GAUGE VALIDATION
        % ================================================================

        function writeClockObservability_(fid, diag, cfg)
            CE = revgnss.ClockExactReportBuilder;

            fprintf(fid, '\\section{Clock Observability and Gauge Validation}\n');
            fprintf(fid, CE.plotTableHeader_());

            gaugeMd = CE.getCfgStr_(cfg, {'clock','gauge','mode'}, 'externalTowerCorrections');
            clkMd   = CE.getCfgStr_(cfg, {'clock','mode'}, 'spacecraftReceiverClockOnly');

            % --- Background ---------------------------------------------------
            fprintf(fid, ['\\multicolumn{2}{|p{\\linewidth}|}{\\textbf{Background.} ' ...
                'One-way pseudorange is insensitive to \\emph{two} persistent common-mode perturbations: ' ...
                '(a) a common bias shift added simultaneously to all clock biases, and ' ...
                '(b) a common drift shift added simultaneously to all clock drifts. ' ...
                'Both null vectors persist for all observation epochs regardless of tower count. ' ...
                'The physical observability Gramian therefore has rank at most $n_{\\text{clk}}-2$. ' ...
                'A gauge constraint (\\texttt{fixReferenceTower} or \\texttt{meanGroundClockGauge}) ' ...
                'pins both the bias and drift of the datum tower, removing both null modes and ' ...
                'lifting the gauged Gramian $W_{\\text{gauged}}$ to full rank $n_{\\text{clk}}$.} \\\\ \\hline\n']);

            % --- Gauge mode ---------------------------------------------------
            switch gaugeMd
                case 'fixReferenceTower'
                    refTwr = CE.getCfgNum_(cfg, {'clock','gauge','referenceTowerIndex'}, 1);
                    sigB   = CE.getCfgNum_(cfg, {'clock','gauge','sigmaBias_m'}, 1e-6);
                    sigD   = CE.getCfgNum_(cfg, {'clock','gauge','sigmaDrift_mps'}, 1e-9);
                    gaugeStr = sprintf(['\\texttt{fixReferenceTower} (tower~%d). ' ...
                        'EKF pseudo-measurements pin tower~%d clock bias and drift to zero ' ...
                        'with $\\sigma_{\\rm bias}=%g$\\,m and $\\sigma_{\\rm drift}=%g$\\,m/s. ' ...
                        'The reference tower absorbs the common-bias datum.'], ...
                        refTwr, refTwr, sigB, sigD);
                case 'meanGroundClockGauge'
                    sigB   = CE.getCfgNum_(cfg, {'clock','gauge','sigmaBias_m'}, 1e-6);
                    sigD   = CE.getCfgNum_(cfg, {'clock','gauge','sigmaDrift_mps'}, 1e-9);
                    gaugeStr = sprintf(['\\texttt{meanGroundClockGauge}. ' ...
                        'EKF pseudo-measurements constrain the mean of all tower clock biases ' ...
                        'and drifts to zero ($\\sigma_{\\rm bias}=%g$\\,m, ' ...
                        '$\\sigma_{\\rm drift}=%g$\\,m/s). ' ...
                        'This spreads the datum symmetrically across all towers.'], sigB, sigD);
                case 'externalTowerCorrections'
                    gaugeStr = ['\texttt{externalTowerCorrections}. ' ...
                        'Tower clock biases are provided externally (perfect truth subtracted); ' ...
                        'no gauge pseudo-measurements are added to the EKF. ' ...
                        'The clock nullspace is resolved by assumption, not by constraint.'];
                otherwise
                    gaugeStr = sprintf('Gauge mode: \\texttt{%s} (spacecraft receiver clock only; no tower clocks in EKF).', ...
                        CE.esc_(gaugeMd));
            end
            CE.writeRow_(fid, '', 'Clock Gauge Mode', gaugeStr);

            % --- Windowed Gramian results ----------------------------------
            rankPhy  = diag.getClockObsRankPhysical();
            rankGau  = diag.getClockObsRankGauged();
            condPhy  = diag.getClockObsCondPhysical();
            condGau  = diag.getClockObsCondGauged();
            weakPhy  = diag.getClockObsWeakStatesPhysical();
            weakGau  = diag.getClockObsWeakStatesGauged();

            finPhy = rankPhy(isfinite(rankPhy));
            finGau = rankGau(isfinite(rankGau));

            if isempty(finPhy)
                CE.writeRow_(fid, '', 'Clock Observability Gramian', ...
                    ['Windowed Gramian not computed (fewer epochs than \\texttt{minWindowEpochs} ' ...
                     'or clock states not in EKF).']);
            else
                mRkPhy = median(finPhy);
                mRkGau = median(finGau(isfinite(finGau)));
                mCdPhy = median(condPhy(isfinite(condPhy) & condPhy > 0));
                mCdGau = median(condGau(isfinite(condGau) & condGau > 0));
                mWkPhy = median(weakPhy(isfinite(weakPhy)));
                mWkGau = median(weakGau(isfinite(weakGau)));

                gramStr = sprintf(['Median physical rank~$%g$, median gauged rank~$%g$. ' ...
                    'Median condition: physical~$%.1e$, gauged~$%.1e$. ' ...
                    'Weak states (physical/gauged): $%g$ / $%g$.'], ...
                    mRkPhy, mRkGau, mCdPhy, mCdGau, mWkPhy, mWkGau);

                % Scientific interpretation
                if mWkGau == 0 && mWkPhy > 0
                    gramStr = [gramStr, ' The gauge successfully eliminates all weak clock states: ' ...
                        'the gauged Gramian achieves full rank.'];
                elseif mWkGau > 0
                    gramStr = [gramStr, sprintf(' \\textbf{Warning:} %g weak state(s) remain after gauging. ', mWkGau), ...
                        'The gauge may not fully constrain the clock nullspace over this window.'];
                elseif mWkPhy == 0 && ~strcmp(clkMd,'includeTowerClocksInEKF')
                    gramStr = [gramStr, ' No tower clock states in EKF: spacecraft receiver ' ...
                        'clock is fully observable via multi-tower geometry.'];
                end
                CE.writeRow_(fid, '', 'Clock Observability Gramian', gramStr);
            end

            % --- NIS confirmation ----------------------------------------
            gaugeRows = diag.getClockGaugeRowsAdded();
            biasRes   = diag.getClockGaugeBiasResiduals();
            finBR     = biasRes(isfinite(biasRes));
            if ~isempty(finBR) && max(gaugeRows) > 0
                mBR = median(abs(finBR));
                CE.writeRow_(fid, '', 'Gauge Residuals', ...
                    sprintf(['Median gauge bias residual~$%.2e$\\,m. ' ...
                    'Values near zero confirm the gauge constraint is numerically effective.'], mBR));
            end

            fprintf(fid, CE.plotTableFooter_());
            fprintf(fid, '\\clearpage\n');
        end

        % ================================================================
        % SECTION 7 — TRANSMITTER CODE HARDWARE-DELAY STATES (Stage 11)
        % ================================================================

        function writeTxCodeBias_(fid, diag, cfg)
            % writeTxCodeBias_  Report section for per-tower L1 transmitter code hardware delays.
            %
            % Only printed when cfg.hardware.txCodeBias.enable == true.
            % Shows gauge type, gauge residual convergence, and number of states.

            CE = revgnss.ClockExactReportBuilder;

            txEnable = false;
            if isfield(cfg,'hardware') && isfield(cfg.hardware,'txCodeBias')
                txEnable = CE.getLogical_(cfg,{'hardware','txCodeBias','enable'},false);
            end
            if ~txEnable; return; end

            gaugeMode = CE.getCfgStr_(cfg,{'hardware','txCodeBias','gaugeMode'},'fixReferenceTower');
            refIdx    = CE.getCfgNum_(cfg,{'hardware','txCodeBias','referenceTowerIndex'},1);
            sigTx     = CE.getCfgNum_(cfg,{'hardware','txCodeBias','processSigma_m_per_sqrt_s'},1e-5);
            sig0Tx    = CE.getCfgNum_(cfg,{'hardware','txCodeBias','initialSigma_m'},10.0);
            sigGauge  = CE.getCfgNum_(cfg,{'hardware','txCodeBias','gaugeSigma_m'},1e-6);

            fprintf(fid, '\\section{Transmitter Code Hardware-Delay States}\n');
            fprintf(fid, CE.plotTableHeader_());

            % --- Gauge type ---
            switch gaugeMode
                case 'fixReferenceTower'
                    gaugeDesc = sprintf('fixReferenceTower (tower %d pinned to zero, $\\sigma_{\\rm gauge}=%.0e$\\,m)', ...
                        refIdx, sigGauge);
                case 'meanGroundDelayGauge'
                    gaugeDesc = sprintf('meanGroundDelayGauge (mean of all tower delays = 0, $\\sigma_{\\rm gauge}=%.0e$\\,m)', ...
                        sigGauge);
                otherwise
                    gaugeDesc = sprintf('%s (gauge sigma $%.0e$\\,m)', gaugeMode, sigGauge);
            end
            CE.writeRow_(fid, '', 'Delay gauge mode', gaugeDesc);

            % --- Process model ---
            CE.writeQuantRow_(fid, 'Initial sigma (all towers)', ...
                sprintf('$\\sigma_0 = %.1f$\\,m', sig0Tx));
            CE.writeQuantRow_(fid, 'Process noise', ...
                sprintf('$\\sigma_w = %.1e$\\,m/$\\sqrt{\\rm s}$ (random walk)', sigTx));

            % --- Active states ---
            nStates = 0;
            if ~isempty(diag) && ismethod(diag,'getNTxCodeBiasStates')
                ns = diag.getNTxCodeBiasStates();
                ns = ns(isfinite(ns) & ns > 0);
                if ~isempty(ns); nStates = median(ns); end
            end
            CE.writeQuantRow_(fid, 'Active tx-code-bias states', ...
                sprintf('%d (one per tower)', nStates));

            % --- Gauge residuals ---
            if ~isempty(diag) && ismethod(diag,'getTxCodeBiasGaugeResiduals')
                res = diag.getTxCodeBiasGaugeResiduals();
                res = res(isfinite(res));
                if ~isempty(res)
                    mRes = mean(abs(res));
                    CE.writeQuantRow_(fid, 'Gauge residual |mean| (absolute)', ...
                        sprintf('%.4f\\,m (should be $\\approx 0$ when gauge is effective)', mRes));
                    rowsAdded = diag.getTxCodeBiasGaugeRowsAdded();
                    mRows = mean(rowsAdded(isfinite(rowsAdded)));
                    CE.writeQuantRow_(fid, 'Gauge rows added per epoch', ...
                        sprintf('%.1f', mRows));
                end
            end

            % --- Identifiability note ---
            CE.writeRow_(fid, '', 'Identifiability constraint', ...
                ['Transmitter code hardware delay and tower clock bias are collinear in ' ...
                 'one-way code pseudorange ($\\partial P/\\partial d_{\\rm tx} = ' ...
                 '\\partial P/\\partial b_{\\rm twr} = 1$). ' ...
                 'The ConfigFactory identifiability guard prevents free estimation of both ' ...
                 'simultaneously; a delay-datum gauge is required.']);

            fprintf(fid, CE.plotTableFooter_());
            fprintf(fid, '\\clearpage\n');
        end



        % ================================================================
        % SECTION 7 — NUMERICAL SUMMARY
        % ================================================================

        function writeNumericalSummary_(fid, cfg, summary, diag)
            CE = revgnss.ClockExactReportBuilder;
            fprintf(fid, '\\section{Numerical Summary}\n');
            fprintf(fid, ['The final-sample values are endpoint diagnostics; do not use them alone ' ...
                'to rank performance. Run-level statistics below cover the full record ' ...
                'and the final window.\n\n']);

            % Collect metrics
            pos3D = CE.safeDiagScalar_(@() diag.getPositionErrors(), 'last');
            clkM  = CE.safeDiagScalar_(@() diag.getClockBiasErrors(), 'last');
            c_mps = 299792458.0;
            clkPs = CE.safeCalc_(@() clkM / c_mps * 1e12);
            pfRMS = CE.safeDiagScalar_(@() diag.getPrefitInnovationRMS(), 'last');
            poRMS = CE.safeDiagScalar_(@() diag.getPostfitResidualRMS(), 'last');

            posRMSFull = CE.safeDiagRMS_(@() diag.getPositionErrors());
            clkRMSFull = CE.safeDiagRMS_(@() diag.getClockBiasErrors());

            mxEKF = CE.safeField_(summary, 'maxEKFRows', NaN);
            nCd   = CE.safeField_(summary, 'totalCodeRows', NaN);
            nDp   = CE.safeField_(summary, 'totalDopplerRows', NaN);
            nCr   = CE.safeField_(summary, 'totalCarrierRows', NaN);

            % Table 1: Quantity / Value
            fprintf(fid, '\\begin{center}\n');
            fprintf(fid, '\\begin{tabular}{p{0.52\\textwidth}p{0.30\\textwidth}}\n');
            fprintf(fid, '\\toprule\n');
            fprintf(fid, '\\textbf{Quantity} & \\textbf{Value}\\\\\n');
            fprintf(fid, '\\midrule\n');
            CE.writeQuantRow_(fid, 'Final 3D position estimation error',        CE.fmtM_(pos3D));
            CE.writeQuantRow_(fid, 'Final receiver clock estimation error',     CE.fmtM_(clkM));
            CE.writeQuantRow_(fid, 'Final clock range-equivalent error (ps)',   CE.fmtPs_(clkPs));
            CE.writeQuantRow_(fid, 'Final pre-fit pseudorange innovation RMS',  CE.fmtM_(pfRMS));
            CE.writeQuantRow_(fid, 'Final post-fit pseudorange residual RMS',   CE.fmtM_(poRMS));
            CE.writeQuantRow_(fid, 'Max EKF measurement rows / epoch',          CE.fmtN_(mxEKF));
            CE.writeQuantRow_(fid, 'Total code pseudorange rows',               CE.fmtN_(nCd));
            CE.writeQuantRow_(fid, 'Total Doppler rows',                        CE.fmtN_(nDp));
            CE.writeQuantRow_(fid, 'Total carrier phase rows',                  CE.fmtN_(nCr));
            fprintf(fid, '\\bottomrule\n\\end{tabular}\n\\end{center}\n');

            % Table 2: Metric / Full RMS / Final window
            fprintf(fid, '\\vspace{0.25cm}\n\\begin{center}\n\\scriptsize\n');
            fprintf(fid, '\\begin{tabular}{p{0.28\\textwidth}p{0.14\\textwidth}p{0.14\\textwidth}}\n');
            fprintf(fid, '\\toprule\n');
            fprintf(fid, '\\textbf{Metric} & \\textbf{Full RMS} & \\textbf{Final sample}\\\\\n');
            fprintf(fid, '\\midrule\n');
            fprintf(fid, '3D position error [m] & %s & %s\\\\\n', CE.fmtM_(posRMSFull), CE.fmtM_(pos3D));
            fprintf(fid, 'Clock error [m] & %s & %s\\\\\n', CE.fmtM_(clkRMSFull), CE.fmtM_(clkM));
            fprintf(fid, 'Pre-fit innovation RMS [m] & --- & %s\\\\\n', CE.fmtM_(pfRMS));
            fprintf(fid, 'Post-fit residual RMS [m] & --- & %s\\\\\n', CE.fmtM_(poRMS));
            fprintf(fid, '\\bottomrule\n\\end{tabular}\n\\end{center}\n\\normalsize\n');

            % Version and test status note
            testLines = revgnss.ReportStatus.summaryLines();
            if ~isempty(testLines)
                fprintf(fid, '\\vspace{0.2cm}\n\\noindent \\textit{%s}\n\n', ...
                    CE.esc_(testLines{1}));
            end
            fprintf(fid, ['\\noindent \\textit{Scientific limitations (v1): float carrier only, ' ...
                'no integer fixing, no L2 carrier EKF, no carrier IF, no PPP-grade accuracy, ' ...
                'no ANTEX/IONEX/SP3/CLK parsers.}\n\n']);
        end

        % ================================================================
        % LONGTABLE HELPERS
        % ================================================================

        function s = plotTableHeader_()
            s = ['\\begin{longtable}{@{}p{0.46\\textwidth}p{0.48\\textwidth}@{}}\n' ...
                 '\\toprule\n' ...
                 '\\textbf{Plot} & \\textbf{Description and statistical approach}\\\\\n' ...
                 '\\midrule\n'];
        end

        function s = plotTableFooter_()
            s = '\\bottomrule\n\\end{longtable}\n';
        end

        % ================================================================
        % FINAL SCIENTIFIC CLOSURE (Stage 65 compact section)
        % ================================================================
        function writeFinalScientificClosure_(fid, summary)
            % writeFinalScientificClosure_  Compact final model closure table.
            CE = revgnss.ClockExactReportBuilder;
            if ~isfield(summary,'stage64Active') || ~summary.stage64Active; return; end
            fprintf(fid, '\\clearpage\n');
            fprintf(fid, '\\section{Final Scientific Model Closure}\n');
            fprintf(fid, ['\\textit{v1 is frozen as a controlled, internally consistent MATLAB EKF simulation ' ...
                'demonstrating measurement, covariance, ambiguity-state, attitude, dynamics, and reporting ' ...
                'architecture. ' ...
                'It is \\textbf{NOT} an operational navigator, \\textbf{NOT} PPP-grade, ' ...
                '\\textbf{NOT} mission-qualified attitude, and \\textbf{NOT} a real-data GNSS processor.}\n\n']);
            % --- Compact closure table ---
            fprintf(fid, '\\begin{center}\\small\n');
            fprintf(fid, '\\begin{tabular}{p{0.38\\textwidth}p{0.52\\textwidth}}\n');
            fprintf(fid, '\\toprule\n\\textbf{Property} & \\textbf{Value / Status}\\\\\n\\midrule\n');
            scen64_ = '';
            if isfield(summary,'stage64ScenarioName'); scen64_ = strrep(summary.stage64ScenarioName,'_','\_'); end
            fprintf(fid, 'Active scenario & \\texttt{%s}\\\\\n', scen64_);
            dyn64_ = '';
            if isfield(summary,'stage64DynamicsMode'); dyn64_ = strrep(summary.stage64DynamicsMode,'_','\_'); end
            fprintf(fid, 'Dynamics mode & \\texttt{%s}\\\\\n', dyn64_);
            measStr_ = revgnss.ClockExactReportBuilder.measTypeStr_(summary);
            fprintf(fid, 'Measurement types & %s\\\\\n', measStr_);
            if isfield(summary,'stage64PcvMode')
                fprintf(fid, 'PCV mode & \\texttt{%s}\\\\\n', strrep(summary.stage64PcvMode,'_','\_'));
            end
            fprintf(fid, 'IF cov assumption & \\texttt{Var(IF)=alpha2*Var(L1)+beta2*Var(L2), Cov(L1,L2)=0}\\\\\n');
            if isfield(summary,'stage64DopplerStatus')
                fprintf(fid, 'Doppler model & \\textit{%s}\\\\\n', CE.esc_(summary.stage64DopplerStatus));
            end
            if isfield(summary,'stage64AttParamterization')
                fprintf(fid, 'Attitude param. & \\texttt{%s}\\\\\n', strrep(summary.stage64AttParamterization,'_','\_'));
            end
            intFix_ = 'disabled';
            if isfield(summary,'stage64IntFixStatus'); intFix_ = strrep(summary.stage64IntFixStatus,'_','\_'); end
            fprintf(fid, 'Int.fix status & \\texttt{%s} (LAMBDA:false, WL/NL:false, falseFixRisk:false)\\\\\n', intFix_);
            if isfield(summary,'finalPositionError_m') && isfinite(summary.finalPositionError_m)
                fprintf(fid, 'Final pos error & %.3f m\\\\\n', summary.finalPositionError_m);
            end
            if isfield(summary,'meanNIS') && isfinite(summary.meanNIS)
                fprintf(fid, 'Mean NIS (all rows) & %.2f\\\\\n', summary.meanNIS);
            end
            if isfield(summary,'physicalNIS') && isfinite(summary.physicalNIS)
                fprintf(fid, 'Physical NIS & %.2f\\\\\n', summary.physicalNIS);
            end
            if isfield(summary,'knownAmbClass') && ~strcmp(summary.knownAmbClass,'SKIPPED')
                fprintf(fid, 'KAV result & \\texttt{%s}\\\\\n', strrep(summary.knownAmbClass,'_','\_'));
            end
            fprintf(fid, '\\midrule\n');
            fprintf(fid, ['\\multicolumn{2}{p{0.94\\textwidth}}{\\textbf{Known v1 limitations:} ' ...
                'full-suite validation not run; no calibrated PCO/PCV/ANTEX; ' ...
                'simplified Doppler (no Sagnac-rate, no relativistic range-rate, no lever-arm velocity from body rates); ' ...
                'IF covariance assumes Cov(L1,L2)=0; ' ...
                'no LAMBDA/MLAMBDA/WL/NL integer fixing; ' ...
                'no formal false-fix-risk control; ' ...
                'no scientific troposphere/ionosphere/orbit models; ' ...
                'no IERS/EOP/SP3/CLK/ANTEX ingestion.}\\\\\n']);
            fprintf(fid, '\\bottomrule\n\\end{tabular}\n\\end{center}\n');
        end

        function writeRow_(fid, imgPath, boldTitle, description)
            % writeRow_  Write one plot-description longtable row.
            % imgPath: full path to image file, or '' for no-plot
            if ~isempty(imgPath) && isfile(imgPath)
                [~, nm, ext] = fileparts(imgPath);
                imgRel = [nm ext];
                leftCell = sprintf(['\\begin{minipage}[t]{\\linewidth}\\vspace{0pt}' ...
                    '\\includegraphics[width=\\linewidth]{figures/%s}\\end{minipage}'], ...
                    imgRel);
            else
                leftCell = '\begin{minipage}[t]{\linewidth}\vspace{0pt}\textit{No plot generated.}\end{minipage}';
            end
            rightCell = sprintf(['\\begin{minipage}[t]{\\linewidth}\\vspace{0pt}' ...
                '\\textbf{%s}\\par\\vspace{3pt}%s\\end{minipage}'], ...
                boldTitle, description);
            fprintf(fid, '%s & %s\\\\\n\\midrule\n', leftCell, rightCell);
        end

        function s = figRef_(plotPaths, field, figDir, stem)
            % figRef_  Return the full path if the figure was generated, else ''.
            s = '';
            if isfield(plotPaths, field) && ~isempty(plotPaths.(field))
                s = plotPaths.(field);
            end
        end

        function writeQuantRow_(fid, label, valStr)
            fprintf(fid, '%s & %s\\\\\n', label, valStr);
        end

        % ================================================================
        % NUMERIC FORMATTERS
        % ================================================================

        function s = fmtM_(v)
            if isnan(v) || isinf(v)
                s = 'not available';
            else
                s = sprintf('%.6f m', v);
            end
        end

        function s = fmtPs_(v)
            if isnan(v) || isinf(v)
                s = 'not available';
            else
                s = sprintf('%.1f ps', v);
            end
        end

        function s = fmtN_(v)
            if isnan(v) || isinf(v)
                s = 'not available';
            else
                s = sprintf('%.0f', v);
            end
        end

        function v = safeDiagScalar_(fn, mode)
            v = NaN;
            try
                arr = fn();
                if ~isempty(arr)
                    if strcmp(mode,'last'); v = arr(end);
                    else; v = arr(1); end
                end
            catch; end
        end

        function v = safeDiagRMS_(fn)
            v = NaN;
            try
                arr = fn();
                if ~isempty(arr); v = rms(arr,'omitnan'); end
            catch; end
        end

        function v = safeCalc_(fn)
            v = NaN;
            try; v = fn(); catch; end
        end

        function v = safeField_(s, f, def)
            v = def;
            if isstruct(s) && isfield(s, f)
                v0 = s.(f);
                if ~(isnumeric(v0) && isscalar(v0) && isnan(v0))
                    v = v0;
                end
            end
        end

        function s = formatCols_(cols)
            if isempty(cols)
                s = 'none';
                return
            end
            cols = unique(cols(:))';
            parts = arrayfun(@(c) sprintf('%d', c), cols, 'UniformOutput', false);
            s = strjoin(parts, ', ');
        end

        % ================================================================
        % COMPILATION
        % ================================================================

        function ok = compileTex_(texPath, latexCmd)
            texDir = fileparts(texPath);
            [~,stem] = fileparts(texPath);
            cmdFmt = '"%s" -interaction=nonstopmode -output-directory "%s" "%s" > /dev/null 2>&1';
            % Run twice for proper table cross-references
            cmd1 = sprintf(cmdFmt, latexCmd, texDir, texPath);
            s1 = system(cmd1);
            s2 = system(cmd1);
            ok = (s1 == 0 || s2 == 0);
        end

        function [ok, cmd] = detectLatex_()
            % Check standard PATH and TeX Live location
            for c = {'/Library/TeX/texbin/pdflatex', 'pdflatex', 'xelatex', '/Library/TeX/texbin/xelatex'}
                [s,~] = system(['"' c{1} '" --version > /dev/null 2>&1']);
                if s == 0; ok = true; cmd = c{1}; return; end
            end
            ok = false; cmd = '';
        end

        % ================================================================
        % LATEX ESCAPING
        % ================================================================

        function s = esc_(s)
            % esc_  LaTeX-escape a string for use as %s data in fprintf.
            % Replacements use SINGLE backslash so the output written to
            % the .tex file is correct (e.g. \_  not  \\_ which would be
            % a LaTeX line-break followed by a bare subscript character).
            if ~ischar(s) && ~isstring(s); s = ''; return; end
            s = char(s);
            % Backslash must be replaced first to avoid double-escaping.
            s = strrep(s, '\', '\textbackslash{}');
            s = strrep(s, '_', '\_');
            s = strrep(s, '&', '\&');
            s = strrep(s, '%', '\%');
            s = strrep(s, '#', '\#');
            s = strrep(s, '{', '\{');
            s = strrep(s, '}', '\}');
            s = strrep(s, '^', '\^{}');
            s = strrep(s, '~', '\textasciitilde{}');
        end

        function s = vec3_(v)
            v = v(:);
            if numel(v) < 3 || any(~isfinite(v(1:3)))
                s = '[---, ---, ---]';
            else
                s = sprintf('[%.3f, %.3f, %.3f]', v(1), v(2), v(3));
            end
        end

        % ================================================================
        % MISC HELPERS
        % ================================================================

        function en = getLogical_(cfg, path, def)
            en = def;
            node = cfg;
            for pi = 1:numel(path)
                if ~isstruct(node) || ~isfield(node, path{pi}); return; end
                node = node.(path{pi});
            end
            if islogical(node) || isnumeric(node); en = logical(node); end
        end

        function s = getCfgStr_(cfg, path, def)
            s = def;
            node = cfg;
            for k = 1:numel(path)
                if ~isstruct(node) || ~isfield(node, path{k}); return; end
                node = node.(path{k});
            end
            if ischar(node) || isstring(node); s = char(node); end
        end

        function v = getCfgNum_(cfg, path, def)
            v = def;
            node = cfg;
            for k = 1:numel(path)
                if ~isstruct(node) || ~isfield(node, path{k}); return; end
                node = node.(path{k});
            end
            if isnumeric(node) && isscalar(node); v = double(node); end
        end

        function sha = getGitSHA_()
            sha = 'unknown';
            try
                repoRoot = fileparts(fileparts(mfilename('fullpath')));
                [st, out] = system(sprintf('git -C "%s" rev-parse --short HEAD 2>/dev/null', repoRoot));
                if st == 0; sha = strtrim(out); end
            catch; end
        end

        function s = measTypeStr_(summary)
            % measTypeStr_  Build a short measurement-type string from summary flags.
            parts = {};
            if isfield(summary,'pseudorangeEnabled')    && summary.pseudorangeEnabled;    parts{end+1} = 'code'; end
            if isfield(summary,'carrierPhaseEnabled')   && summary.carrierPhaseEnabled;   parts{end+1} = 'carrier'; end
            if isfield(summary,'dopplerEnabled')        && summary.dopplerEnabled;        parts{end+1} = 'Doppler'; end
            if isfield(summary,'stage63IntegerFixingImplemented') && summary.stage63IntegerFixingImplemented
                parts{end+1} = 'intFix';
            end
            parts = unique(parts,'stable');
            if isempty(parts); s = 'code (default)'; else; s = strjoin(parts,'+'); end
        end

    end  % private static

end
