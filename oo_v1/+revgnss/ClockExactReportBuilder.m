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
        function result = build(diag, dataMeta, asset, towers, cfg, summary)
            % build  Full ClockExact report pipeline.
            % diag: SimulationDataStore (or legacy Diagnostics for compat)
            % dataMeta: schema metadata from simData.getMeta()
            if nargin < 6; summary = struct(); end
            if nargin < 5 || isempty(cfg); cfg = struct(); end
            if nargin < 2; dataMeta = struct(); end

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
            ver = revgnss.ClockExactReportBuilder.getCfgStr_(cfg, {'report','version'}, '1.00');

            % cfg.report.reportFolder bypasses the date-stamped subfolder.
            reportDir = revgnss.ClockExactReportBuilder.getCfgStr_(cfg, {'report','reportFolder'}, '');
            if isempty(reportDir)
                baseDir = fullfile(fileparts(mfilename('fullpath')), '..', 'output');
                baseDir = revgnss.ClockExactReportBuilder.getCfgStr_(cfg, {'report','baseOutputDir'}, baseDir);
                prefix  = revgnss.ClockExactReportBuilder.getCfgStr_(cfg, {'report','dateFolderPrefix'}, 'Report-');
                reportDir = fullfile(baseDir, [prefix datestr(now,'yyyymmdd')]); %#ok<TNOW1,DATST>
            end
            if ~exist(reportDir,'dir'); mkdir(reportDir); end

            % cfg.report.stem overrides the default scenario-name-based stem.
            stem = revgnss.ClockExactReportBuilder.getCfgStr_(cfg, {'report','stem'}, '');
            if isempty(stem)
                scenarioName = revgnss.ClockExactReportBuilder.getCfgStr_(cfg, {'asset','name'}, 'GEO-1');
                stem = strrep(strrep(strrep(scenarioName, ' ', '_'), '-', '_'), '.', '_');
                stem = ['oo_v1_' stem];
            end

            figDir  = fullfile(reportDir, 'figures');
            if ~exist(figDir,'dir'); mkdir(figDir); end
            texPath = fullfile(reportDir, [stem '.tex']);
            pdfPath = fullfile(reportDir, [stem '.pdf']);

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
            keepArtifacts = false;
            try; keepArtifacts = logical(cfg.report.keepBuildArtifacts); catch; end
            if ~strcmp(compileMode,'never') && latexOk
                fprintf('  [ClockExact] Compiling with %s...\n', latexCmd);
                ok = revgnss.ClockExactReportBuilder.compileTex_(texPath, latexCmd);
                if ok
                    result.success = true;
                    result.message = sprintf('PDF compiled: %s', pdfPath);
                    fprintf('  [ClockExact] PDF written: %s\n', pdfPath);
                    if ~keepArtifacts
                        revgnss.ClockExactReportBuilder.cleanBuildArtifacts_(texPath, figDir);
                    end
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

    methods (Static)  % (Phase 7: report toolkit callable by extracted +revgnss/+report/ sections)

        function cleanBuildArtifacts_(texPath, figDir) %#ok<INUSD>
            % cleanBuildArtifacts_  Remove LaTeX intermediates after a successful
            % compile. The figures/ folder is preserved next to the report PDF and
            % MAT file so the individual figure PDFs remain available to the user.
            exts = {'.tex', '.aux', '.log', '.out', '.toc', '.synctex.gz'};
            base = texPath(1:end-4);  % strip .tex
            for k = 1:numel(exts)
                f = [base exts{k}];
                if exist(f,'file') == 2; try; delete(f); catch; end; end
            end
        end


        % ================================================================
        % COMPACT PLOT GENERATION
        % ================================================================

        function paths = generateCompactPlots_(diag, cfg, summary, figDir, stem) %#ok<INUSD>
            % generateCompactPlots_  Create compact plots for each report row.
            % cfg.report.plotExportMode controls PNG (rasterSafe) vs PDF (vectorPdf).
            paths = struct();
            isDiag = isobject(diag) && ismethod(diag, 'getTimeVector');

            t = [];
            if isDiag; try; t = diag.getTimeVector(); catch; end; end

            CE = revgnss.ClockExactReportBuilder;

            % Position error
            paths.posErr = CE.tryPlot_(figDir, [stem '_position_error.pdf'], @() ...
                CE.plotPositionError_(diag, t), cfg);

            % Clock bias error
            paths.clkErr = CE.tryPlot_(figDir, [stem '_clock_error.pdf'], @() ...
                CE.plotClockError_(diag, t), cfg);

            % Clock drift
            paths.clkDrift = CE.tryPlot_(figDir, [stem '_clock_drift.pdf'], @() ...
                CE.plotClockDrift_(diag, t), cfg);

            % Innovation RMS (prefit / postfit)
            paths.innovRMS = CE.tryPlot_(figDir, [stem '_innovation_rms.pdf'], @() ...
                CE.plotInnovationRMS_(diag, t), cfg);

            % NIS
            paths.nis = CE.tryPlot_(figDir, [stem '_nis.pdf'], @() ...
                CE.plotNIS_(diag, t), cfg);

            % Attitude diagnostics
            paths.attComp = CE.tryPlot_(figDir, [stem '_attitude_components.pdf'], @() ...
                revgnss.ReportRealityHelper.plotAttitudeComponents(diag, t), cfg);
            paths.attNorm = CE.tryPlot_(figDir, [stem '_attitude_norm.pdf'], @() ...
                revgnss.ReportRealityHelper.plotAttitudeNorm(diag, t), cfg);
            paths.attSigma = CE.tryPlot_(figDir, [stem '_attitude_sigma.pdf'], @() ...
                revgnss.ReportRealityHelper.plotAttitudeSigma(diag, t), cfg);

            % Visible towers
            paths.visTowers = CE.tryPlot_(figDir, [stem '_visible_towers.pdf'], @() ...
                CE.plotVisibleTowers_(diag, t), cfg);

            % DOP metrics
            paths.dop = CE.tryPlot_(figDir, [stem '_dop.pdf'], @() ...
                CE.plotDOP_(diag, t), cfg);

            % Tower clock biases (bar chart)
            paths.twrClocks = CE.tryPlot_(figDir, [stem '_tower_clocks.pdf'], @() ...
                CE.plotTowerClocks_(diag), cfg);

            % Per-source error breakdown
            paths.perSrc = CE.tryPlot_(figDir, [stem '_per_source_error.pdf'], @() ...
                CE.plotPerSourceError_(diag, t), cfg);

            % Zoom plots: last cfg.report.zoomLastSeconds seconds (fixed window, default 120 s).
            zoomSec = 120;
            try
                if isfield(cfg,'report') && isfield(cfg.report,'zoomLastSeconds') && ...
                        isnumeric(cfg.report.zoomLastSeconds) && cfg.report.zoomLastSeconds > 0
                    zoomSec = cfg.report.zoomLastSeconds;
                end
            catch; end
            paths.posErrZoom  = CE.tryPlot_(figDir, [stem '_position_error_zoomlast.pdf'], @() ...
                CE.plotSignalZoom_(diag, t, 'posErr',  zoomSec), cfg);
            paths.clkErrZoom  = CE.tryPlot_(figDir, [stem '_clock_error_zoomlast.pdf'], @() ...
                CE.plotSignalZoom_(diag, t, 'clkErr',  zoomSec), cfg);
            paths.clkDriftZoom = CE.tryPlot_(figDir, [stem '_clock_drift_zoomlast.pdf'], @() ...
                CE.plotSignalZoom_(diag, t, 'clkDrift', zoomSec), cfg);
            paths.attCompZoom = CE.tryPlot_(figDir, [stem '_attitude_components_zoomlast.pdf'], @() ...
                CE.plotAttZoom_(diag, t, zoomSec), cfg);

            % Allan deviation (Stage 67)
            paths.allanDev = CE.tryPlot_(figDir, [stem '_allan_deviation.pdf'], @() ...
                CE.plotAllanDeviation_(diag, t), cfg);
        end

        % ................................................................
        function fig = plotSignalZoom_(diag, t, signal, zoomSec)
            % Zoom to the LAST zoomSec seconds (fixed window), with +/-3 sigma covariance
            % borders overlaid (dotted). State indices per ReverseGNSSEKF.buildStateMap_:
            % position 1:3, clock bias 13, clock drift 14.
            fig = revgnss.ClockExactReportBuilder.makeCompactFig_('');
            ax  = gca(fig);
            CE  = revgnss.ClockExactReportBuilder;
            try
                c0 = revgnss.Constants.SPEED_OF_LIGHT_MPS;
                ppm = 1e6;
                if isempty(t)
                    CE.noDataAxes_(ax); return;
                end
                i0 = find(t >= t(end) - zoomSec, 1, 'first');
                if isempty(i0); i0 = 1; end
                tz = t(i0:end);
                ttl = sprintf('Last %g s (dotted = \\pm3\\sigma)', zoomSec);

                switch signal
                    case 'posErr'
                        ev = diag.getPositionErrorVecs();   % [3 x N] estimate - truth
                        nAll = numel(t);
                        rTr = []; vTr = [];
                        try; rTr = diag.getTruthPositionVecs(); vTr = diag.getTruthVelocityVecs(); catch; end
                        if ~isempty(ev) && size(ev,2) == nAll
                            nrm = sqrt(sum(ev.^2,1));
                            rac = [];
                            if ~isempty(rTr) && ~isempty(vTr) && size(rTr,2) >= nAll && size(vTr,2) >= nAll
                                rac = revgnss.OrbitFrame.ecefToRacGeo(ev, rTr(:,1:nAll), vTr(:,1:nAll));
                                if all(~isfinite(rac(:))); rac = []; end
                            end
                            seg = i0:nAll;
                            if ~isempty(rac)
                                [~, unit, sc] = revgnss.PlotUnitScaler.scaleMetric(reshape(rac(:,seg),[],1), 'm');
                                hold(ax,'on');
                                plot(ax, tz, rac(1,seg)*sc, 'r-', 'LineWidth',0.8, 'DisplayName','radial');
                                plot(ax, tz, rac(2,seg)*sc, 'g-', 'LineWidth',0.8, 'DisplayName','along-track');
                                plot(ax, tz, rac(3,seg)*sc, 'b-', 'LineWidth',0.8, 'DisplayName','cross-track');
                                legend(ax,'show','Location','northeast','FontSize',5);
                            else
                                [~, unit, sc] = revgnss.PlotUnitScaler.scaleMetric(nrm(seg), 'm');
                                plot(ax, tz, nrm(seg)*sc, 'b-', 'LineWidth',0.8);
                            end
                            xlabel(ax,'Time [s]','FontSize',7);
                            ylabel(ax, revgnss.PlotUnitScaler.axisLabel('Position error', unit),'FontSize',7);
                            title(ax, ttl,'FontSize',7); grid(ax,'on');
                            revgnss.PlotUnitScaler.disableExponent(ax); return;
                        end
                    case 'clkErr'
                        c = diag.getClockBiasErrors();   % metres
                        if ~isempty(c)
                            y = c ./ c0;   % seconds
                            [~, unit, sc] = revgnss.PlotUnitScaler.scaleMetric(y(i0:end), 's');
                            hold(ax,'on');
                            plot(ax, tz, y(i0:end)*sc, 'r-', 'LineWidth',0.8);
                            CE.overlaySigma_(ax, tz, CE.stateSigmaWin_(diag,13,sc/c0,i0), 3, 'k:');
                            xlabel(ax,'Time [s]','FontSize',7);
                            ylabel(ax, revgnss.PlotUnitScaler.axisLabel('Clock bias error', unit),'FontSize',7);
                            title(ax, ttl,'FontSize',7); grid(ax,'on');
                            revgnss.PlotUnitScaler.disableExponent(ax); return;
                        end
                    case 'clkDrift'
                        yf = diag.getClockDriftErrors() ./ c0;  % m/s -> fractional [s/s]
                        if ~isempty(yf)
                            [~, unit, sc] = revgnss.PlotUnitScaler.scaleMetric(yf(i0:end), 's/s');
                            hold(ax,'on');
                            plot(ax, tz, yf(i0:end)*sc, 'b-', 'LineWidth',0.8);
                            CE.overlaySigma_(ax, tz, CE.stateSigmaWin_(diag,14,sc/c0,i0), 3, 'k:');
                            xlabel(ax,'Time [s]','FontSize',7);
                            ylabel(ax, revgnss.PlotUnitScaler.axisLabel('Clock drift error', unit),'FontSize',7);
                            title(ax, ttl,'FontSize',7); grid(ax,'on');
                            revgnss.PlotUnitScaler.disableExponent(ax); return;
                        end
                end
            catch
            end
            CE.noDataAxes_(ax);
        end

        % ................................................................
        function fig = plotAttZoom_(diag, t, zoomSec)
            % plotAttZoom_  Attitude component errors, zoomed to the last zoomSec seconds.
            fig = revgnss.ClockExactReportBuilder.makeCompactFig_('');
            ax  = gca(fig);
            try
                % Reuse ReportRealityHelper if available; otherwise graceful no-data.
                tmpFig = revgnss.ReportRealityHelper.plotAttitudeComponents(diag, t);
                if isgraphics(tmpFig)
                    n  = numel(t);
                    i0 = find(t >= t(end) - zoomSec, 1, 'first'); if isempty(i0); i0 = 1; end
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
        function fig = plotAllanDeviation_(diag, t)
            % plotAllanDeviation_  Overlapping ADEV for asset Rx and tower clocks.
            fig = revgnss.ClockExactReportBuilder.makeCompactFig_('');
            ax = gca(fig);
            try
                c = 299792458;
                hold(ax, 'on');
                nLines = 0;

                % Asset Rx clock truth [s]
                x_rx = revgnss.AllanDeviation.getRxClockBiasTrue(diag);
                if sum(isfinite(x_rx)) > 8
                    adev = revgnss.AllanDeviation.compute(x_rx(isfinite(x_rx)), ...
                        t(isfinite(x_rx)));
                    if ~isempty(adev.tau)
                        loglog(ax, adev.tau, adev.sigma_y, 'k-', ...
                            'LineWidth', 1.4, 'DisplayName', 'Asset Rx');
                        nLines = nLines + 1;
                    end
                end

                % Tower clocks [m → s]
                twr_m = revgnss.AllanDeviation.getTowerClockBiasMatrix(diag);
                % The store carries one column per measurement row (tower repeated
                % across receivers/signals); collapse to distinct tower time series.
                if ~isempty(twr_m)
                    [~, ia] = unique(twr_m', 'rows', 'stable');
                    twr_m = twr_m(:, sort(ia));
                end
                nT = min(size(twr_m, 2), 8);   % cap curves on the compact plot
                if nT > 0
                    cols_ = lines(max(nT, 1));
                    for tk = 1:nT
                        x_col = twr_m(:, tk);
                        ok = isfinite(x_col);
                        if sum(ok) < 8; continue; end
                        x_s = x_col(ok) / c;
                        t_v = t(ok);
                        adev = revgnss.AllanDeviation.compute(x_s(:), t_v(:));
                        if ~isempty(adev.tau)
                            loglog(ax, adev.tau, adev.sigma_y, '-', ...
                                'Color', cols_(tk,:), 'LineWidth', 0.8, ...
                                'DisplayName', sprintf('Tower %d', tk));
                            nLines = nLines + 1;
                        end
                    end
                end

                if nLines > 0
                    hold(ax, 'off');
                    xlabel(ax, '\tau [s]', 'FontSize', 7);
                    ylabel(ax, '\sigma_y(\tau)', 'FontSize', 7);
                    grid(ax, 'on'); grid(ax, 'minor');
                    legend(ax, 'show', 'Location', 'best', 'FontSize', 6);
                    return
                end
            catch; end
            hold(ax, 'off');
            revgnss.ClockExactReportBuilder.noDataAxes_(ax);
        end

        % ................................................................
        function outPath = tryPlot_(figDir, fname, plotFcn, cfg)
            % tryPlot_  Run plotFcn, export vector PDF (default) or PNG, return path or ''.
            %
            % cfg.report.plotExportMode (default 'vectorPdf'):
            %   'vectorPdf'  — export PDF via exportgraphics ContentType=vector.
            %   'rasterSafe' — export PNG via print -dpng -r180.
            %
            % cfg.report.vectorFallbackToRaster (default true):
            %   On vector export failure, fall back to PNG for this figure only.
            if nargin < 4; cfg = struct(); end
            outPath = '';
            mode = revgnss.ClockExactReportBuilder.getCfgStr_( ...
                cfg, {'report','plotExportMode'}, 'vectorPdf');
            doFallback = revgnss.ClockExactReportBuilder.getLogical_( ...
                cfg, {'report','vectorFallbackToRaster'}, true);
            [~, stem_name, ~] = fileparts(fname);
            pdfPath = fullfile(figDir, [stem_name '.pdf']);
            pngPath = fullfile(figDir, [stem_name '.png']);
            fig = [];
            try
                fig = plotFcn();
                if ~isgraphics(fig)
                    return;
                end
                cleanupObj = onCleanup( ...
                    @() revgnss.ClockExactReportBuilder.safeCloseFig_(fig)); %#ok<NASGU>
                set(fig, 'Visible',        'off');
                set(fig, 'Color',          'white');
                set(fig, 'InvertHardcopy', 'off');
                set(fig, 'Renderer',       'painters');
                if strcmpi(mode, 'rasterSafe')
                    print(fig, pngPath, '-dpng', '-r180');
                    outPath = pngPath;
                else
                    try
                        exportgraphics(fig, pdfPath, 'ContentType','vector', ...
                            'BackgroundColor','white');
                        outPath = pdfPath;
                    catch vecME
                        if doFallback
                            warning('ClockExactReportBuilder:vectorFallback', ...
                                'Vector export failed for %s (%s); falling back to a raster PDF.', ...
                                fname, vecME.message);
                            try
                                exportgraphics(fig, pdfPath, 'ContentType','image', ...
                                    'Resolution',220, 'BackgroundColor','white');
                                outPath = pdfPath;
                            catch
                                outPath = '';
                            end
                        else
                            rethrow(vecME);
                        end
                    end
                end
            catch ME
                warning('ClockExactReportBuilder:plotExportFailed', ...
                    'Plot export failed for %s: %s', fname, ME.message);
                outPath = '';
            end
            try; drawnow limitrate; catch; end
        end

        % ................................................................
        function outPath = tryPlot3D_(figDir, fname, plotFcn, resolution)
            % tryPlot3D_  Render a lit 3-D scene and export it as a PDF holding a
            % rasterised image (ContentType='image'). Unlike tryPlot_ this keeps the
            % default (OpenGL) renderer so lighting and transparency survive; a true
            % vector export would flatten them. Optional resolution (DPI) defaults to 200.
            if nargin < 4 || isempty(resolution); resolution = 200; end
            outPath = '';
            [~, stem_name, ~] = fileparts(fname);
            pdfPath = fullfile(figDir, [stem_name '.pdf']);
            fig = [];
            try
                fig = plotFcn();
                if ~isgraphics(fig); return; end
                cleanupObj = onCleanup( ...
                    @() revgnss.ClockExactReportBuilder.safeCloseFig_(fig)); %#ok<NASGU>
                set(fig, 'Visible','off', 'Color','white', 'InvertHardcopy','off');
                exportgraphics(fig, pdfPath, 'ContentType','image', ...
                    'Resolution', resolution, 'BackgroundColor','white');
                outPath = pdfPath;
            catch ME
                warning('ClockExactReportBuilder:plot3DFailed', ...
                    '3-D plot export failed for %s: %s', fname, ME.message);
                outPath = '';
            end
            try; drawnow limitrate; catch; end
        end

        % ................................................................
        function safeCloseFig_(fig)
            % safeCloseFig_  Close a figure handle silently (for onCleanup use).
            try
                if ~isempty(fig) && isgraphics(fig)
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
            % Position error in the RAC (radial / along-track / cross-track)
            % orbital frame, estimate minus truth, with auto SI-prefix units.
            fig = revgnss.ClockExactReportBuilder.makeCompactFig_('');
            ax  = gca(fig);
            PU  = @revgnss.PlotUnitScaler.scaleMetric;
            try
                ev = diag.getPositionErrorVecs();  % [3 x n] estimate - truth ECEF
                e  = diag.getPositionErrors();     % [1 x n] 3D norm
                rTr = []; vTr = [];
                try; rTr = diag.getTruthPositionVecs(); vTr = diag.getTruthVelocityVecs(); catch; end
                n = numel(t);
                haveRac = ~isempty(t) && ~isempty(ev) && size(ev,2) == n && ...
                          ~isempty(rTr) && ~isempty(vTr) && size(rTr,2) >= n && size(vTr,2) >= n;
                rac = [];
                if haveRac
                    rac = revgnss.OrbitFrame.ecefToRacGeo(ev, rTr(:,1:n), vTr(:,1:n));
                    if all(~isfinite(rac(:))); haveRac = false; end
                end
                if haveRac
                    [~, unit, sc] = PU(rac(:), 'm');
                    hold(ax,'on');
                    plot(ax, t, rac(1,:)*sc, 'r-', 'LineWidth', 0.8, 'DisplayName', 'radial');
                    plot(ax, t, rac(2,:)*sc, 'g-', 'LineWidth', 0.8, 'DisplayName', 'along-track');
                    plot(ax, t, rac(3,:)*sc, 'b-', 'LineWidth', 0.8, 'DisplayName', 'cross-track');
                    legend(ax, 'show', 'Location', 'northeast', 'FontSize', 5);
                    xlabel(ax, 'Time [s]', 'FontSize', 7);
                    ylabel(ax, revgnss.PlotUnitScaler.axisLabel('Error', unit), 'FontSize', 7);
                    title(ax, 'Position error: RAC frame (estimate - truth)', 'FontSize', 7);
                    grid(ax, 'on');
                    revgnss.PlotUnitScaler.disableExponent(ax);
                    return;
                elseif ~isempty(t) && ~isempty(e)
                    % Fallback: clearly-labelled 3D norm (RAC basis unavailable).
                    [es, unit] = PU(e, 'm');
                    plot(ax, t, es, 'b-', 'LineWidth', 0.8);
                    xlabel(ax, 'Time [s]', 'FontSize', 7);
                    ylabel(ax, revgnss.PlotUnitScaler.axisLabel('Error (3D norm)', unit), 'FontSize', 7);
                    title(ax, 'Position error: 3D norm (RAC basis unavailable)', 'FontSize', 7);
                    grid(ax, 'on');
                    revgnss.PlotUnitScaler.disableExponent(ax);
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
                c = diag.getClockBiasErrors();     % stored range domain [m]
                if ~isempty(t) && ~isempty(c)
                    CE = revgnss.ClockExactReportBuilder;
                    c0 = revgnss.Constants.SPEED_OF_LIGHT_MPS;
                    [cs, unit, sc] = revgnss.PlotUnitScaler.scaleMetric(c / c0, 's');   % -> time domain
                    hold(ax,'on');
                    plot(ax, t, cs, 'r-', 'LineWidth', 0.8);
                    % Pdiag(13) is range-domain; divide by c to match the time-domain plot.
                    CE.overlaySigma_(ax, t, CE.stateSigmaWin_(diag,13,sc/c0,1), 3, 'k:');
                    xlabel(ax, 'Time [s]', 'FontSize',7);
                    ylabel(ax, revgnss.PlotUnitScaler.axisLabel('Clock error', unit), 'FontSize',7);
                    title(ax, 'Receiver clock bias error (dotted = \pm3\sigma)', 'FontSize',7);
                    grid(ax, 'on');
                    revgnss.PlotUnitScaler.disableExponent(ax);
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
                d = diag.getClockDriftErrors();    % stored range-rate domain [m/s]
                if ~isempty(t) && ~isempty(d)
                    CE = revgnss.ClockExactReportBuilder;
                    c0 = revgnss.Constants.SPEED_OF_LIGHT_MPS;
                    [ds, unit, sc] = revgnss.PlotUnitScaler.scaleMetric(d / c0, 's/s');  % -> fractional frequency
                    hold(ax,'on');
                    plot(ax, t, ds, 'b-', 'LineWidth', 0.8);
                    % Pdiag(14) is range-rate domain; divide by c to match the fractional plot.
                    CE.overlaySigma_(ax, t, CE.stateSigmaWin_(diag,14,sc/c0,1), 3, 'k:');
                    xlabel(ax, 'Time [s]', 'FontSize',7);
                    ylabel(ax, revgnss.PlotUnitScaler.axisLabel('Drift error', unit), 'FontSize',7);
                    title(ax, 'Receiver clock drift error (dotted = \pm3\sigma)', 'FontSize',7);
                    grid(ax, 'on');
                    revgnss.PlotUnitScaler.disableExponent(ax);
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
                v = [];
                if iscell(M) && ~isempty(M) && ~isempty(M{end})
                    v = M{end};
                elseif isnumeric(M) && ~isempty(M)
                    % Compact store: [nRows x nEpochs]; take the last epoch and
                    % collapse the per-row duplication to distinct tower biases.
                    lastCol = M(:, end);
                    v = unique(lastCol(isfinite(lastCol)), 'stable');
                end
                if isnumeric(v) && ~isempty(v)
                    c0 = revgnss.Constants.SPEED_OF_LIGHT_MPS;
                    [vs, unit] = revgnss.PlotUnitScaler.scaleMetric(v / c0, 's');   % -> time domain
                    bar(ax, 1:numel(vs), vs, 0.5);
                    xlabel(ax,'Tower index','FontSize',7);
                    ylabel(ax, revgnss.PlotUnitScaler.axisLabel('Bias', unit),'FontSize',7);
                    grid(ax,'on');
                    return;
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

        function s = stateSigmaWin_(diag, idx, scale, i0)
            % stateSigmaWin_  Windowed 1-sigma (sqrt of covariance diagonal) for EKF state
            %   row idx, scaled to the plot's units, from sample i0 to the end. Returns []
            %   if the covariance is unavailable or too small (graceful no-band).
            s = [];
            try
                d_ = diag.getData();
                if isfield(d_,'Pdiag') && ~isempty(d_.Pdiag) && size(d_.Pdiag,1) >= idx
                    row = sqrt(max(d_.Pdiag(idx,:), 0)) * scale;
                    if i0 < 1; i0 = 1; end
                    s = row(i0:end);
                end
            catch; end
        end

        function overlaySigma_(ax, tt, sig, k, style)
            % overlaySigma_  Draw +/- k*sigma dotted covariance borders on ax over time tt.
            %   Hidden from the legend; no-op if the sigma vector is unavailable/mismatched.
            if isempty(sig) || numel(sig) ~= numel(tt) || all(~isfinite(sig)); return; end
            hold(ax,'on');
            plot(ax, tt,  k*sig, style, 'LineWidth',0.6, 'HandleVisibility','off');
            plot(ax, tt, -k*sig, style, 'LineWidth',0.6, 'HandleVisibility','off');
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
            fprintf(fid, '\\begin{center}\n');
            fprintf(fid, '{\\Large \\textbf{Reverse-GNSS Spacecraft Multi-Observable EKF Report}}\\\\[4pt]\n');
            fprintf(fid, '{\\large Scenario: \\textbf{%s}}\\\\[4pt]\n', esc(scenarioName));
            fprintf(fid, '{\\small Reverse-GNSS EKF simulator \\textemdash{} validation version %s \\\\ Generated %s}\\\\[3pt]\n', ...
                esc(ver), esc(ts));
            fprintf(fid, ['{\\footnotesize Controlled synthetic reverse-GNSS scenario. Results are compared against the ' ...
                'known synthetic truth and are not a real-data or PPP-grade performance claim.}\n']);
            fprintf(fid, '\\end{center}\n');
            fprintf(fid, '\\vspace{0.3cm}\n');

            % ---- Sections -----------------------------------------------
            revgnss.report.scenarioSummary(fid, cfg, summary, diag, nTwr, nRx, dur, dt, esc, plotPaths, stem, figDir);
            revgnss.report.stateEstimation(fid, plotPaths, stem, cfg, diag, figDir);
            revgnss.report.measurementValidation(fid, plotPaths, stem, figDir, diag);
            revgnss.report.oscillatorValidation(fid, plotPaths, stem, figDir, cfg);
            revgnss.report.txCodeBias(fid, diag, cfg);
            revgnss.report.tropZwdArchitecture(fid, cfg);
            revgnss.report.numericalSummary(fid, cfg, summary, diag);
            revgnss.report.activePhysicsConfig(fid, cfg, summary, plotPaths, stem, figDir);

            fprintf(fid, '\\end{document}\n');
            fclose(fid);
        end

        % ================================================================
        % SECTION 1 — SCENARIO SUMMARY
        % ================================================================

        % writeScenarioSummary_ extracted to +revgnss/+report/scenarioSummary.m (Phase 7).


        % ================================================================
        % COMPONENT STATUS ROWS (1.6)
        % ================================================================

        function writeComponentRows_(fid, cfg, esc)
            CE = revgnss.ClockExactReportBuilder;

            % --- Clock / gauge ---
            clkMd2  = CE.getCfgStr_(cfg, {'clock','mode'}, 'spacecraftReceiverClockOnly');
            gaugMd2 = CE.getCfgStr_(cfg, {'clock','gauge','mode'}, 'externalTowerCorrections');

            % --- Signal mask: read cfg.signals.enabledMask (not twoFrequency.enable) ---
            sigMask2 = logical([true, false]);
            try
                nd = cfg.signals.enabledMask;
                if islogical(nd)||isnumeric(nd); sigMask2 = logical(nd); end
            catch; end
            isDual2 = numel(sigMask2) >= 2 && sigMask2(2);

            % --- Carrier ---
            carMode2 = CE.getCfgStr_(cfg, {'measurements','carrierMode'}, '');
            carEn2   = CE.getLogical_(cfg, {'measurements','carrierPhase','enable'}, false);
            carEKF2  = strcmp(carMode2, 'ekfFloat');
            carL2EKF2  = carEKF2 && isDual2;
            codeIF2    = CE.getLogical_(cfg, {'measurements','code','ionosphereFreeRows','useInEkf'}, false);
            carIF2     = CE.getLogical_(cfg, {'measurements','carrier','ionosphereFreeRows','useInEkf'}, false);
            carSlip2   = CE.getLogical_(cfg, {'carrierSlip','enable'}, false);
            arcSep2    = CE.getLogical_(cfg, {'estimator','arcSeparatedAmbiguities','enable'}, false);

            % --- Integer ambiguity ---
            intFixEn2  = CE.getLogical_(cfg, {'estimator','integerAmbiguity','enable'}, false);
            intFixMode2 = CE.getCfgStr_(cfg, {'estimator','integerAmbiguity','mode'}, '');
            baseArEn2  = CE.getLogical_(cfg, {'estimator','diffAtt','ambiguityResolution','enable'}, false);
            baseArMeth2 = CE.getCfgStr_(cfg, {'estimator','diffAtt','ambiguityResolution','method'}, '');

            % --- Tower product correction ---
            prodMode2  = CE.getCfgStr_(cfg, {'clocks','tower','product','mode'}, '');
            prodEn2    = strcmp(prodMode2, 'truthHistoryProductNoisy');
            prodCovEn2 = CE.getLogical_(cfg, {'covariance','productClock','enable'}, false);
            sharedEn2  = CE.getLogical_(cfg, {'covariance','sharedErrors','enable'}, false);

            % --- Light-time ---
            ltEn2   = CE.getLogical_(cfg, {'physics','lightTime','enable'}, false);
            ltMode2 = CE.getCfgStr_(cfg, {'physics','lightTime','mode'}, '');

            % --- Doppler ---
            dopEKF2 = CE.getLogical_(cfg, {'measurements','doppler','useInEKF'}, false);
            dopMdl2 = CE.getCfgStr_(cfg, {'measurements','doppler','modelLevel'}, '');

            % --- Attitude ---
            attEn2     = CE.getLogical_(cfg, {'estimator','estimateAttitude'}, false);
            attParam2  = CE.getCfgStr_(cfg, {'estimator','attitude','parameterization'}, '');
            diffAttEn2 = strcmp(CE.getCfgStr_(cfg, {'estimator','attitudeCarrierMode'}, ''), ...
                                'calibratedDifferentialAmbiguity');

            % --- ZWD EKF ---
            zwdMode2 = CE.getCfgStr_(cfg, {'estimation','troposphereMode'}, 'none');
            zwdEKF2  = ~strcmp(zwdMode2, 'none') && ~isempty(zwdMode2);

            % ---- Build row descriptions ----
            % Status values: true=Enabled, false=Disabled, 'guarded'=Guarded/config-only, 'nimpl'=Not implemented

            % Carrier L1 float note
            if carEKF2 && carEn2
                carL1Note = 'Float ambiguity EKF, raw L1.';
            elseif carEn2
                carL1Note = 'Carrier enabled but not in EKF.';
            else
                carL1Note = 'Carrier phase disabled.';
            end

            % Carrier L2 status/note
            if carL2EKF2
                carL2St = true;
                carL2Note = 'Float ambiguity EKF, raw L2 (L1+L2 active).';
            elseif carEKF2 && ~isDual2
                carL2St = false;
                carL2Note = 'L1 only; L2 float rows available when dual-freq enabled.';
            else
                carL2St = false;
                carL2Note = 'Carrier or dual-freq not active.';
            end

            % Code IF status/note
            if codeIF2
                codeIFSt = true;
                codeIFNote = 'Code IF rows reduce ionosphere in EKF.';
            elseif isDual2
                codeIFSt = false;
                codeIFNote = 'L1+L2 available; code IF rows not enabled.';
            else
                codeIFSt = false;
                codeIFNote = 'Requires L1+L2; L1 only active.';
            end

            % Carrier IF float status/note
            if carIF2
                carIFSt = true;
                carIFNote = 'IF carrier float rows in EKF; no integer fixing.';
            elseif carEKF2 && isDual2
                carIFSt = false;
                carIFNote = 'Carrier float+dual-freq active; IF float rows not enabled.';
            else
                carIFSt = false;
                carIFNote = 'Requires carrier float and L1+L2.';
            end

            % Raw integer fixing status/note
            if intFixEn2
                intFixSt = true;
                intFixNote = sprintf('Guarded %s; fixes attempted only when arc/sigma/distance/RMS gates pass.', revgnss.ReportLabel.humanize(intFixMode2));
            else
                intFixSt = false;
                intFixNote = 'Disabled; guarded raw-carrier fixing available, not active in this run.';
            end

            % Baseline attitude AR status/note
            if baseArEn2
                baseArSt = true;
                baseArNote = sprintf('method: %s; requires carrier float, 4 receivers, attitude EKF, and differential-attitude mode.', revgnss.ReportLabel.humanize(baseArMeth2));
            else
                baseArSt = false;
                baseArNote = 'Not active; requires carrier float + 4rx + attitude EKF + diffAtt mode.';
            end

            % Tower product correction status/note
            if prodEn2
                prodSt = true;
                prodNote = sprintf('External noisy product correction (%s).', revgnss.ReportLabel.humanize(prodMode2));
            else
                prodSt = false;
                prodNote = 'Perfect external tower correction assumed.';
            end

            % Light-time / Sagnac status and note
            sagEn2 = CE.getLogical_(cfg, {'physics','sagnac','truth','enable'}, false) || ...
                     CE.getLogical_(cfg, {'physics','sagnac','model','enable'}, false);
            if ltEn2
                ltSt   = true;
                ltNote = sprintf('%s; Sagnac subsumed when iterative light-time active.', revgnss.ReportLabel.humanize(ltMode2));
            elseif sagEn2
                ltSt   = true;
                ltNote = 'First-order Sagnac only (no iterative light-time).';
            else
                ltSt   = false;
                ltNote = '';
            end

            % Pre-compute conditional notes (avoids need for ternary helper)
            if isDual2; dualNote2 = 'L1+L2; IF combination available.'; else; dualNote2 = 'L1 only.'; end
            dopNote2    = ''; if dopEKF2; dopNote2 = sprintf('model: %s', revgnss.ReportLabel.humanize(dopMdl2)); end
            zwdSt2      = 'guarded'; if zwdEKF2; zwdSt2 = true; end
            zwdNote2    = 'Guarded/config-only; weak GEO observability at GEO.';
            if zwdEKF2; zwdNote2 = sprintf('mode: %s', revgnss.ReportLabel.humanize(zwdMode2)); end
            slipNote2   = '';
            if carSlip2 && arcSep2; slipNote2 = 'model-step-compensated residual jump; arc-separated float ambiguities.'; end
            prodCovSt2  = prodCovEn2 || sharedEn2;
            prodCovN2   = 'No product covariance applied to R.';
            if prodCovSt2; prodCovN2 = 'R-inflation from product age and drift uncertainty.'; end
            tClkNote2   = sprintf('mode: %s; gauge: %s.', revgnss.ReportLabel.humanize(clkMd2), revgnss.ReportLabel.humanize(gaugMd2));
            attNote2    = 'No attitude states.'; if attEn2; attNote2 = sprintf('parameterisation: %s', revgnss.ReportLabel.humanize(attParam2)); end
            diffAttN2   = ''; if diffAttEn2; diffAttN2 = 'calibrated differential ambiguity active.'; end

            % ---- Five compact group tables (avoids single-table page overflow) ----
            gTitles = { ...
                'Core geometry and signals', ...
                'Clock and covariance', ...
                'Atmosphere and propagation', ...
                'Carrier, ambiguity and attitude', ...
                'Antenna, hardware and unsupported', ...
            };

            gRows = cell(5, 1);

            gRows{1} = { ...
                'Ground segment geometry',       true,    'Included in this report.'; ...
                'L1+L2 dual-frequency signals',  isDual2, dualNote2; ...
                'Carrier phase enabled',         carEn2,  ''; ...
                'Doppler in EKF',                dopEKF2, dopNote2; ...
            };

            gRows{2} = { ...
                'Receiver clock (spacecraft)',    true,                                       'Included in this report.'; ...
                'Tower clock product correction', prodSt,                                    prodNote; ...
                'Tower clock product covariance', prodCovSt2,                                prodCovN2; ...
                'Joint tower clock EKF',          strcmp(clkMd2,'includeTowerClocksInEKF'),  tClkNote2; ...
                'ZWD / troposphere EKF state',    zwdSt2,                                    zwdNote2; ...
                'Per-tower hardware delay EKF',   'guarded', 'Config flag exists; no dedicated EKF state in v1.'; ...
            };

            gRows{3} = { ...
                'Troposphere (truth)',  CE.getLogical_(cfg,{'errors','troposphere','truth','enable'},false), ''; ...
                'Troposphere (model)', CE.getLogical_(cfg,{'errors','troposphere','model','enable'},false), ''; ...
                'Ionosphere (truth)',  CE.getLogical_(cfg,{'errors','ionosphere','truth','enable'},false),   ''; ...
                'Ionosphere (model)',  CE.getLogical_(cfg,{'errors','ionosphere','model','enable'},false),   ''; ...
                'Light-time / Sagnac correction',  ltSt,   ltNote; ...
                'Shapiro delay (truth)',  CE.getLogical_(cfg,{'physics','relativity','shapiro','truth','enable'},false), ''; ...
                'Relativity clock (truth)', CE.getLogical_(cfg,{'physics','relativity','clock','truth','enable'},false), ''; ...
            };

            gRows{4} = { ...
                'Carrier L1 float rows in EKF',   carEKF2 && carEn2,    carL1Note; ...
                'Carrier L2 float rows in EKF',   carL2St,              carL2Note; ...
                'Carrier slip guards + arc sep',   carSlip2 && arcSep2,  slipNote2; ...
                'Code IF rows in EKF',            codeIFSt,             codeIFNote; ...
                'Carrier IF float rows in EKF',   carIFSt,              carIFNote; ...
                'Raw carrier integer fixing',     intFixSt,             intFixNote; ...
                'Baseline attitude AR',           baseArSt,             baseArNote; ...
                'Attitude EKF (spacecraft)',       attEn2,               attNote2; ...
                'Diff. carrier att. calibration',  diffAttEn2,           diffAttN2; ...
            };

            gRows{5} = { ...
                'Antenna PCO (truth)',       CE.getLogical_(cfg,{'effects','antennaPCO','truth','enable'},false),   ''; ...
                'Antenna PCV (truth)',       CE.getLogical_(cfg,{'effects','antennaPCV','truth','enable'},false),   ''; ...
                'Hardware delay (truth)',    CE.getLogical_(cfg,{'errors','hardwareDelay','truth','enable'},false), ''; ...
                'Multipath (truth)',         CE.getLogical_(cfg,{'errors','multipath','truth','enable'},false),     ''; ...
                'Carrier IF integer fixing', 'nimpl', 'Explicitly unsupported in v1; IF ambiguity is not an integer.'; ...
                'LAMBDA / MLAMBDA',         'nimpl', 'No decorrelated ILS in v1; distance-to-integer gate only.'; ...
                'ANTEX / SP3 / CLK parsers', 'nimpl', 'Synthetic constants only; no file-based corrections.'; ...
                'PPP-grade processing',     'nimpl', 'Not implemented in v1.'; ...
            };

            for gi = 1:5
                fprintf(fid, '\\begingroup\n\\small\n');
                fprintf(fid, '\\setlength{\\tabcolsep}{3pt}\n');
                fprintf(fid, '\\renewcommand{\\arraystretch}{0.92}\n');
                fprintf(fid, '\\begin{center}\n');
                fprintf(fid, '{\\bfseries\\small %s}\\\\[2pt]\n', gTitles{gi});
                fprintf(fid, ['\\begin{tabular}{>{\\raggedright\\arraybackslash}p{0.34\\textwidth}' ...
                              ' >{\\raggedright\\arraybackslash}p{0.18\\textwidth}' ...
                              ' >{\\raggedright\\arraybackslash}p{0.40\\textwidth}}\n']);
                fprintf(fid, '\\toprule\n');
                fprintf(fid, '\\textbf{Component} & \\textbf{Status} & \\textbf{Note}\\\\\n');
                fprintf(fid, '\\midrule\n');
                rws = gRows{gi};
                for k = 1:size(rws, 1)
                    comp = esc(rws{k,1});
                    isEn = rws{k,2};
                    act  = rws{k,3};
                    if isequal(isEn, true)
                        stTex = '\textcolor{green!45!black}{Enabled}';
                        if isempty(act); act = 'Active in this run.'; end
                    elseif isequal(isEn, 'guarded')
                        stTex = '\textcolor{orange!70!black}{Guarded}';
                        if isempty(act); act = 'Not active in current run.'; end
                    elseif isequal(isEn, 'nimpl')
                        stTex = '\textcolor{gray!80}{Not\,impl.}';
                        if isempty(act); act = 'Not available in v1.'; end
                    else
                        stTex = '\textcolor{gray}{Disabled}';
                        if isempty(act); act = '---'; end
                    end
                    fprintf(fid, '%s & %s & %s\\\\\n', comp, stTex, esc(act));
                    fprintf(fid, '\\midrule\n');
                end
                fprintf(fid, '\\bottomrule\n\\end{tabular}\n\\end{center}\n');
                fprintf(fid, '\\endgroup\n\\vspace{4pt}\n');
            end
        end

        % ================================================================
        % SECTION 2 — STATE ESTIMATION VALIDATION
        % ================================================================

        % writeStateEstimation_ extracted to +revgnss/+report/stateEstimation.m (Phase 7).

        % ================================================================
        % SECTION 3 — MEASUREMENT AND GEOMETRY VALIDATION
        % ================================================================

        % writeMeasurementValidation_ extracted to +revgnss/+report/measurementValidation.m (Phase 7).

        % ================================================================
        % SECTION 4 — PER-RECEIVER MEASUREMENT DIAGNOSTICS
        % ================================================================

        % writePerReceiverDiagnostics_ extracted to +revgnss/+report/perReceiverDiagnostics.m (Phase 7).

        % ================================================================
        % SECTION 5 — OSCILLATOR STABILITY VALIDATION
        % ================================================================

        % writeOscillatorValidation_ extracted to +revgnss/+report/oscillatorValidation.m (Phase 7).

        % ================================================================
        % SECTION 6 — DISABLED COMPONENTS
        % ================================================================

        % ================================================================
        % SECTION 6B — CLOCK OBSERVABILITY AND GAUGE VALIDATION
        % ================================================================

        % writeClockObservability_ extracted to +revgnss/+report/clockObservability.m (Phase 7).

        % ================================================================
        % SECTION 7 — TRANSMITTER CODE HARDWARE-DELAY STATES (Stage 11)
        % ================================================================

        % writeTxCodeBias_ extracted to +revgnss/+report/txCodeBias.m (Phase 7).



        % ================================================================
        % SECTION 7 — NUMERICAL SUMMARY
        % ================================================================

        % writeNumericalSummary_ extracted to +revgnss/+report/numericalSummary.m (Phase 7).

        % ================================================================
        % STAGE 68: ACTIVE PHYSICS MODEL CONFIGURATION (non-stage-titled)
        % ================================================================
        % writeTropZwdArchitecture_ extracted to +revgnss/+report/tropZwdArchitecture.m (Phase 7).

        % writeActivePhysicsConfig_ extracted to +revgnss/+report/activePhysicsConfig.m (Phase 7).

        % Spacecraft + reference-frame schematic moved to the standalone, editable
        % output/utils/make_spacecraft_frames.m (scenario-independent; exported via
        % tryPlot3D_ to output/utils/spacecraft_frames.pdf, which the report references).

        % ================================================================
        % LONGTABLE HELPERS
        % ================================================================

        function s = plotTableHeader_()
            % 66/33 split: the plot column dominates; the description stays compact.
            s = ['\\begin{longtable}{@{}p{0.62\\textwidth}p{0.30\\textwidth}@{}}\n' ...
                 '\\toprule\n' ...
                 '\\textbf{Plot} & \\textbf{Description and statistical approach}\\\\\n' ...
                 '\\midrule\n'];
        end

        function s = plotTableFooter_()
            s = '\\bottomrule\n\\end{longtable}\n';
        end

        % ================================================================
        % FINAL SCIENTIFIC CLOSURE (Stage 66 compact section)
        % ================================================================
        function writeFinalScientificClosure_(fid, summary)
            % writeFinalScientificClosure_  Compact final model closure table.
            CE = revgnss.ClockExactReportBuilder;
            if ~isfield(summary,'physicsConfigSectionActive') || ~summary.physicsConfigSectionActive; return; end
            fprintf(fid, '\\clearpage\n');
            fprintf(fid, '\\section{Single-Asset One-Way Scientific Closure}\n');
            fprintf(fid, ['\\textit{v1 is a controlled, internally consistent MATLAB reverse-GNSS EKF simulation: ' ...
                'one estimated spacecraft, Earth towers transmit one-way reference signals upward, ' ...
                'spacecraft estimates position/velocity/clock/attitude using code, carrier, Doppler, ' ...
                'and configurable error models. ' ...
                'It is \\textbf{NOT} an operational navigator, \\textbf{NOT} PPP-grade, ' ...
                '\\textbf{NOT} mission-qualified, and \\textbf{NOT} a real-data GNSS processor.}\n\n']);
            % --- Compact closure table ---
            fprintf(fid, '\\begin{center}\\small\n');
            fprintf(fid, '\\begin{tabular}{p{0.38\\textwidth}p{0.52\\textwidth}}\n');
            fprintf(fid, '\\toprule\n\\textbf{Property} & \\textbf{Value / Status}\\\\\n\\midrule\n');
            % Stage 66: single-asset one-way topology rows
            nSA_ = 1;
            if isfield(summary,'stage66NSpaceAssets'); nSA_ = summary.stage66NSpaceAssets; end
            fprintf(fid, 'nSpaceAssets & %d (single estimated spacecraft)\\\\\n', nSA_);
            oc66_ = 'GEO';
            if isfield(summary,'stage66OrbitClass'); oc66_ = summary.stage66OrbitClass; end
            fprintf(fid, 'Orbit class & \\texttt{%s} (Stage~82+ default: j2Rk4 truth, twoBody EKF)\\\\\n', oc66_);
            nTwr_ = 0;
            if isfield(summary,'nTowers'); nTwr_ = summary.nTowers; end
            fprintf(fid, 'nTowers & %d (transmitters; tower-to-space one-way)\\\\\n', nTwr_);
            nRx_ = 0;
            if isfield(summary,'nReceivers'); nRx_ = summary.nReceivers; end
            fprintf(fid, 'nReceivers & %d (spacecraft antennas)\\\\\n', nRx_);
            islDis_ = true;
            if isfield(summary,'stage66IslDisabled'); islDis_ = summary.stage66IslDisabled; end
            fprintf(fid, 'ISL & %s\\\\\n', CE.yesNo_(islDis_, 'disabled', 'ACTIVE (unexpected)'));
            twDis_ = true;
            if isfield(summary,'stage66TwstftDisabled'); twDis_ = summary.stage66TwstftDisabled; end
            fprintf(fid, 'TWSTFT & %s\\\\\n', CE.yesNo_(twDis_, 'disabled', 'ACTIVE (unexpected)'));
            twoWayDis_ = true;
            if isfield(summary,'stage66TwoWayDisabled'); twoWayDis_ = summary.stage66TwoWayDisabled; end
            fprintf(fid, 'Two-way range & %s\\\\\n', CE.yesNo_(twoWayDis_, 'disabled', 'ACTIVE (unexpected)'));
            fprintf(fid, 'Relay/transponder & disabled\\\\\n');
            fprintf(fid, 'Multi-asset estimation & disabled (nSpaceAssets=1)\\\\\n');
            fprintf(fid, '\\midrule\n');
            % Scenario and dynamics
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
            fprintf(fid, 'Operational claim & false (NOT operational, NOT PPP-grade, NOT mission-qualified)\\\\\n');
            fprintf(fid, '\\midrule\n');
            % Metrics
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
                fprintf(fid, 'KAV result (truth-assisted diagnostic; not part of the realistic claim) & \\texttt{%s}\\\\\n', strrep(summary.knownAmbClass,'_','\_'));
            end
            fprintf(fid, '\\midrule\n');
            fprintf(fid, ['\\multicolumn{2}{p{0.94\\textwidth}}{\\textbf{Known v1 limitations:} ' ...
                'full-suite validation not run; no ISL/TWSTFT/two-way/relay physics; ' ...
                'no calibrated PCO/PCV/ANTEX; ' ...
                'simplified Doppler (no Sagnac-rate, no relativistic range-rate, no lever-arm velocity); ' ...
                'IF covariance assumes Cov(L1,L2)=0; ' ...
                'no LAMBDA/MLAMBDA/WL/NL integer fixing; ' ...
                'no formal false-fix-risk control; ' ...
                'no scientific troposphere/ionosphere/orbit models; ' ...
                'no IERS/EOP/SP3/CLK/ANTEX ingestion.}\\\\\n']);
            fprintf(fid, '\\bottomrule\n\\end{tabular}\n\\end{center}\n');
        end

        % ================================================================
        % STAGE 67 CLOSURE: ATTITUDE, CLOCK, AND DYNAMICS REALISM
        % ================================================================
        function writeStage67Closure_(fid, summary, plotPaths, stem, figDir)
            CE = revgnss.ClockExactReportBuilder;
            if ~isfield(summary,'oneWayClosureSectionActive') || ~summary.oneWayClosureSectionActive; return; end
            fprintf(fid, '\\clearpage\n');
            fprintf(fid, '\\section{Stage 67 Attitude, Clock, and Dynamics Realism Closure}\n');
            fprintf(fid, ['\\textit{Stage~67 makes three physical realism upgrades to the ' ...
                'Stage~66 single-asset one-way simulation: ' ...
                '(A) attitude estimator clearly identified as a carrier lever-arm quaternion EKF; ' ...
                '(B) stochastic tower and spacecraft clocks replace perfect corrections; ' ...
                '(C) matched twoBodyRk4 truth propagator + twoBody EKF dynamics replace static-ECEF truth.}\n\n']);

            fprintf(fid, '\\begin{center}\\small\n');

            % ---- A: Attitude table ---------------------------------------
            fprintf(fid, '\\textbf{A.~Attitude determination}\n\n');
            fprintf(fid, '\\begin{tabular}{p{0.42\\textwidth}p{0.48\\textwidth}}\n');
            fprintf(fid, '\\toprule\n\\textbf{Property} & \\textbf{Value / Status}\\\\\n\\midrule\n');
            attPrim_ = 'carrierLeverArmQuaternionEkf';
            if isfield(summary,'stage67PrimaryAttMode'); attPrim_ = summary.stage67PrimaryAttMode; end
            fprintf(fid, 'Primary estimator & \\texttt{%s}\\\\\n', strrep(attPrim_,'_','\_'));
            fprintf(fid, 'Quaternion EKF type & nominal + error-state $\\delta\\theta$ (Stages~61/62)\\\\\n');
            fprintf(fid, 'Covariance reset & Joseph form + attitude reset Jacobian\\\\\n');
            attInit_ = 'coarseBaselineIntegerSearch';
            if isfield(summary,'stage67AttInitMode'); attInit_ = summary.stage67AttInitMode; end
            fprintf(fid, 'Initializer & \\texttt{%s} (optional; not primary estimator)\\\\\n', ...
                strrep(attInit_,'_','\_'));
            attCar_ = 'calibratedDifferentialAmbiguity';
            if isfield(summary,'stage67AttCarrierMode'); attCar_ = summary.stage67AttCarrierMode; end
            fprintf(fid, 'Carrier tracking & \\texttt{%s} (relative only; not absolute reference)\\\\\n', ...
                strrep(attCar_,'_','\_'));
            fprintf(fid, '\\bottomrule\n\\end{tabular}\n\n\\vspace{6pt}\n');

            % ---- B: Clock table ------------------------------------------
            fprintf(fid, '\\textbf{B.~Clock model}\n\n');
            fprintf(fid, '\\begin{tabular}{p{0.42\\textwidth}p{0.48\\textwidth}}\n');
            fprintf(fid, '\\toprule\n\\textbf{Property} & \\textbf{Value / Status}\\\\\n\\midrule\n');
            rxDet_ = false;
            if isfield(summary,'stage67RxClockDet'); rxDet_ = summary.stage67RxClockDet; end
            fprintf(fid, 'Asset Rx clock & %s (Brown-Hwang two-state)\\\\\n', ...
                CE.yesNo_(rxDet_, 'deterministic (unexpected)', 'stochastic'));
            tClkMode_ = 'noisyCorrection';
            if isfield(summary,'stage67TowerClockMode'); tClkMode_ = summary.stage67TowerClockMode; end
            fprintf(fid, 'Tower clock correction & \\texttt{%s}\\\\\n', strrep(tClkMode_,'_','\_'));
            tClkSig_ = 0.5;
            if isfield(summary,'stage67TowerClockSigma_m'); tClkSig_ = summary.stage67TowerClockSigma_m; end
            fprintf(fid, 'Tower correction $\\sigma$ & %.2f m\\\\\n', tClkSig_);
            fprintf(fid, 'Perfect tower correction & false (stochastic biases + broadcast uncertainty)\\\\\n');
            fprintf(fid, '\\bottomrule\n\\end{tabular}\n\n\\vspace{6pt}\n');

            % ---- C: Dynamics table ---------------------------------------
            fprintf(fid, '\\textbf{C.~Orbital dynamics}\n\n');
            fprintf(fid, '\\begin{tabular}{p{0.42\\textwidth}p{0.48\\textwidth}}\n');
            fprintf(fid, '\\toprule\n\\textbf{Property} & \\textbf{Value / Status}\\\\\n\\midrule\n');
            propMode_ = 'twoBodyRk4';
            if isfield(summary,'stage67OrbitPropMode'); propMode_ = summary.stage67OrbitPropMode; end
            fprintf(fid, 'Truth propagator & \\texttt{%s} (GEO: alt~=~35786~km, inc~=~0, $\\nu_0$~=~23\\textdegree)\\\\\n', ...
                strrep(propMode_,'_','\_'));
            dynMode_ = 'twoBody';
            if isfield(summary,'stage67DynamicsMode'); dynMode_ = summary.stage67DynamicsMode; end
            fprintf(fid, 'EKF dynamics & \\texttt{%s} (matched to truth propagator)\\\\\n', ...
                strrep(dynMode_,'_','\_'));
            propEn_ = true;
            if isfield(summary,'stage67OrbitProp'); propEn_ = summary.stage67OrbitProp; end
            fprintf(fid, 'Orbit propagator active & %s\\\\\n', ...
                CE.yesNo_(propEn_, 'true', 'false (unexpected)'));
            fprintf(fid, 'Static ECEF truth & false (replaced by twoBodyRk4 propagator)\\\\\n');
            fprintf(fid, '\\bottomrule\n\\end{tabular}\n\n\\end{center}\n');

            % ---- Allan deviation plot reference ---------------------------
            allanPath = CE.figRef_(plotPaths, 'allanDev', figDir, stem);
            if ~isempty(allanPath) && isfile(allanPath)
                [~, nm, ext] = fileparts(allanPath);
                fprintf(fid, ['\\begin{center}\n' ...
                    '\\includegraphics[width=0.65\\textwidth]{figures/%s}\n' ...
                    '\\end{center}\n'], [nm ext]);
                fprintf(fid, ['\\textit{Figure: Overlapping Allan deviation $\\sigma_y(\\tau)$ for the asset ' ...
                    'receiver clock (black) and tower transmitter clocks (coloured). ' ...
                    'Stage~67 stochastic clock model; synthetic v1 oscillator parameters.}\n\n']);
            end
        end

        function s = yesNo_(flag, yes, no)
            if flag; s = yes; else; s = no; end
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

        function br = getGitBranch_()
            br = 'unknown';
            try
                repoRoot = fileparts(fileparts(mfilename('fullpath')));
                [st, out] = system(sprintf('git -C "%s" rev-parse --abbrev-ref HEAD 2>/dev/null', repoRoot));
                if st == 0 && ~isempty(strtrim(out)); br = strtrim(out); end
            catch; end
        end

        function s = measTypeStr_(summary)
            % measTypeStr_  Build a short measurement-type string from summary flags.
            parts = {};
            if isfield(summary,'pseudorangeEnabled')    && summary.pseudorangeEnabled;    parts{end+1} = 'code'; end
            if isfield(summary,'carrierPhaseEnabled')   && summary.carrierPhaseEnabled;   parts{end+1} = 'carrier'; end
            if isfield(summary,'dopplerEnabled')        && summary.dopplerEnabled;        parts{end+1} = 'Doppler'; end
            if isfield(summary,'integerAmbiguityFixingActive') && summary.integerAmbiguityFixingActive
                parts{end+1} = 'intFix';
            end
            parts = unique(parts,'stable');
            if isempty(parts); s = 'code (default)'; else; s = strjoin(parts,'+'); end
        end

    end  % private static

end
