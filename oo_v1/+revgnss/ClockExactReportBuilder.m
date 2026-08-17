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

    methods (Static)  % (Report toolkit callable by extracted +revgnss/+report/ sections)

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

            % Initial convergence transient (a priori vs posterior). Omitted for runs
            % whose data carries no prior series.
            zoomFirstSec = 120;
            try
                if isfield(cfg,'report') && isfield(cfg.report,'zoomFirstSeconds') && ...
                        isnumeric(cfg.report.zoomFirstSeconds) && cfg.report.zoomFirstSeconds > 0
                    zoomFirstSec = cfg.report.zoomFirstSeconds;
                end
            catch; end
            paths.initTransient = CE.tryPlot_(figDir, [stem '_initial_transient.pdf'], @() ...
                CE.plotInitialTransient_(diag, t, zoomFirstSec), cfg);

            % Clock bias error
            paths.clkErr = CE.tryPlot_(figDir, [stem '_clock_error.pdf'], @() ...
                CE.plotClockError_(diag, t), cfg);

            % Clock: true development vs EKF estimate (the "real clock" overlay)
            paths.clkTruth = CE.tryPlot_(figDir, [stem '_clock_truth_vs_estimate.pdf'], @() ...
                CE.plotClockTruthVsEstimate_(diag, t), cfg);

            % Clock drift
            paths.clkDrift = CE.tryPlot_(figDir, [stem '_clock_drift.pdf'], @() ...
                CE.plotClockDrift_(diag, t), cfg);

            % The settled-tail window, resolved here because the innovation plot draws it
            % as an inset rather than as a separate figure.
            zoomSec = 120;
            try
                if isfield(cfg,'report') && isfield(cfg.report,'zoomLastSeconds') && ...
                        isnumeric(cfg.report.zoomLastSeconds) && cfg.report.zoomLastSeconds > 0
                    zoomSec = cfg.report.zoomLastSeconds;
                end
            catch; end

            % Innovation RMS (prefit / postfit), with the settled tail inset in-figure
            paths.innovRMS = CE.tryPlot_(figDir, [stem '_innovation_rms.pdf'], @() ...
                CE.plotInnovationRMS_(diag, t, zoomSec), cfg);

            % NIS
            paths.nis = CE.tryPlot_(figDir, [stem '_nis.pdf'], @() ...
                CE.plotNIS_(diag, t), cfg);

            % Attitude diagnostics
            paths.attComp = CE.tryPlot_(figDir, [stem '_attitude_components.pdf'], @() ...
                revgnss.ReportRealityHelper.plotAttitudeComponents(diag, t), cfg);
            % 3D attitude error norm plot REMOVED (user request): it is the Euclidean norm of
            % the roll/pitch/yaw errors already shown in full by the attitude-components plot
            % and its final-120 s zoom, so it added no information. The generator
            % ReportRealityHelper.plotAttitudeNorm is kept for direct/interactive use.
            paths.attSigma = CE.tryPlot_(figDir, [stem '_attitude_sigma.pdf'], @() ...
                revgnss.ReportRealityHelper.plotAttitudeSigma(diag, t), cfg);

            % Visible towers
            paths.visTowers = CE.tryPlot_(figDir, [stem '_visible_towers.pdf'], @() ...
                CE.plotVisibleTowers_(diag, t), cfg);

            % DOP metrics. TWO figures, not one axes with two y-scales: on a 1 h arc the
            % R-weighted curves sawtooth ~120 times with the tower-clock product age, which
            % renders as a solid band that buries the flat geometry curves underneath it,
            % and eight legend entries then cover whatever is left. Split, the geometry
            % figure is legible on its own and the sigma figure gets an inset at a scale
            % where one sawtooth cycle is actually visible.
            paths.dop = CE.tryPlot_(figDir, [stem '_dop.pdf'], @() ...
                CE.plotDOP_(diag, t), cfg);
            paths.dopSigma = CE.tryPlot_(figDir, [stem '_dop_sigma.pdf'], @() ...
                CE.plotDOPSigma_(diag, t, zoomSec), cfg);

            % Tower clock biases (bar chart)
            paths.twrClocks = CE.tryPlot_(figDir, [stem '_tower_clocks.pdf'], @() ...
                CE.plotTowerClocks_(diag), cfg);

            % Per-source error breakdown
            paths.perSrc = CE.tryPlot_(figDir, [stem '_per_source_error.pdf'], @() ...
                CE.plotPerSourceError_(diag, t), cfg);

            % Zoom plots: last cfg.report.zoomLastSeconds seconds (fixed window, default 120 s).
            paths.posErrZoom  = CE.tryPlot_(figDir, [stem '_position_error_zoomlast.pdf'], @() ...
                CE.plotSignalZoom_(diag, t, 'posErr',  zoomSec), cfg);
            paths.clkErrZoom  = CE.tryPlot_(figDir, [stem '_clock_error_zoomlast.pdf'], @() ...
                CE.plotSignalZoom_(diag, t, 'clkErr',  zoomSec), cfg);
            paths.clkDriftZoom = CE.tryPlot_(figDir, [stem '_clock_drift_zoomlast.pdf'], @() ...
                CE.plotSignalZoom_(diag, t, 'clkDrift', zoomSec), cfg);
            paths.attCompZoom = CE.tryPlot_(figDir, [stem '_attitude_components_zoomlast.pdf'], @() ...
                CE.plotAttZoom_(diag, t, zoomSec), cfg);

            % Allan deviation
            paths.allanDev = CE.tryPlot_(figDir, [stem '_allan_deviation.pdf'], @() ...
                CE.plotAllanDeviation_(diag, t), cfg);

            isJointFormation = isstruct(summary) && ...
                isfield(summary, 'jointFormationDiagnostics') && ...
                isfield(summary.jointFormationDiagnostics, 'available') && ...
                summary.jointFormationDiagnostics.available;
            if isJointFormation
                formationDiagnostics = summary.jointFormationDiagnostics;
                paths.jointFormation = CE.tryPlot_(figDir, [stem '_joint_formation_error.pdf'], @() ...
                    revgnss.JointMultiAssetFormationDiagnostics.plotPositionErrors(formationDiagnostics), cfg);
                paths.jointRelativeLayer = CE.tryPlot_(figDir, [stem '_joint_relative_layer.pdf'], @() ...
                    revgnss.JointMultiAssetFormationDiagnostics.plotRelativeLayer(formationDiagnostics), cfg);
                paths.jointKabsch = CE.tryPlot3D_(figDir, [stem '_joint_kabsch_alignment.pdf'], @() ...
                    revgnss.JointMultiAssetFormationDiagnostics.plotKabschAlignment(formationDiagnostics), 220);
                % Beamforming phase budget. Each plot method returns [] when the payload
                % is absent or unavailable, and tryPlot_ turns that into an empty path,
                % so a single-asset or non-beamforming run adds no figures.
                if isfield(summary,'beamformingPhasor')
                    beamforming = summary.beamformingPhasor;
                    paths.beamPhasor = CE.tryPlot_(figDir, [stem '_beamforming_phasor.pdf'], @() ...
                        revgnss.BeamformingPhasorDiagnostics.plotPhasorChain(beamforming), cfg);
                    paths.beamLoss = CE.tryPlot_(figDir, [stem '_beamforming_loss.pdf'], @() ...
                        revgnss.BeamformingPhasorDiagnostics.plotLossVsFrequency(beamforming), cfg);
                    paths.beamPattern = CE.tryPlot_(figDir, [stem '_beamforming_pattern.pdf'], @() ...
                        revgnss.BeamformingPhasorDiagnostics.plotBeamPattern(beamforming), cfg);
                end
            else
                paths.swarmPos = CE.tryPlot_(figDir, [stem '_swarm_position_error.pdf'], @() ...
                    CE.plotSwarmPosError_(diag, t, []), cfg);
                paths.swarmPosZoom = CE.tryPlot_(figDir, [stem '_swarm_position_error_zoomlast.pdf'], @() ...
                    CE.plotSwarmPosError_(diag, t, zoomSec), cfg);
            end
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
                                % Filter +-3 sigma envelope per RAC axis (honours the title's
                                % "dotted = +-3 sigma"; colour-matched, hidden from the legend).
                                CE = revgnss.ClockExactReportBuilder;
                                racSig = CE.racPositionSigma_(diag, rTr(:,1:nAll), vTr(:,1:nAll), nAll);
                                if ~isempty(racSig)
                                    CE.overlaySigma_(ax, tz, racSig(1,seg)*sc, 3, 'r:');
                                    CE.overlaySigma_(ax, tz, racSig(2,seg)*sc, 3, 'g:');
                                    CE.overlaySigma_(ax, tz, racSig(3,seg)*sc, 3, 'b:');
                                end
                                legend(ax,'show','Location','best','FontSize',5);
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
                        legend(ax,'show','Location','best','FontSize',6);
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
        function normalizeAxisUnits_(fig)
            % normalizeAxisUnits_  Remove the "x10^-3" style axis multiplier from every axes by
            % rescaling the DATA into a sensible unit and saying so in the label -- e.g. metres
            % -> cm/mm, seconds -> ns/ps. Merely setting Exponent=0 would leave "0.000001".
            %
            % Deliberately conservative: each axes is attempted independently inside try/catch,
            % and it BAILS (leaving the axes exactly as it was) whenever rescaling could be
            % wrong -- a yyaxis pair, an unlabelled or unrecognised unit, mixed-magnitude
            % children, or anything non-finite. Worst case is today's behaviour for that one
            % axes; it can never corrupt a curve.
            axList = findall(fig, 'Type', 'axes');
            for ii = 1:numel(axList)
                ax = axList(ii);
                % Inset panels follow their host's scale, applied below. Rescaling one
                % on its own maximum would silently put it in a different unit from the
                % axis label it is drawn inside.
                if strcmp(get(ax,'Tag'), 'reportInset'); continue; end
                % LOG axes first. Their tick labels are inherently 10^n and are NOT the linear
                % "Exponent" multiplier handled below -- an earlier version of this function
                % missed them entirely and log plots kept their 10^0/10^1/10^2 ticks. Log scale
                % is correct where the data spans decades (the relative-layer plot covers five),
                % so the fix is plain-number tick labels, not a switch to linear which would
                % flatten the solved curves into the axis.
                try
                    if numel(ax.YAxis) == 1 && strcmpi(ax.YScale, 'log')
                        revgnss.ClockExactReportBuilder.plainLogTicks_(ax, 'Y');
                    end
                    if numel(ax.XAxis) == 1 && strcmpi(ax.XScale, 'log')
                        revgnss.ClockExactReportBuilder.plainLogTicks_(ax, 'X');
                    end
                catch
                end
                try
                    if numel(ax.YAxis) ~= 1; continue; end        % yyaxis: two units, skip
                    if strcmpi(ax.YScale, 'log'); continue; end   % handled above; do not rescale
                    lbl = '';
                    try; lbl = ax.YLabel.String; catch; end
                    if iscell(lbl); lbl = strjoin(lbl, ' '); end
                    if isempty(lbl); continue; end
                    tok = regexp(lbl, '\[([^\]]+)\]', 'tokens', 'once');
                    if isempty(tok); continue; end
                    unit = strtrim(tok{1});

                    kids = findall(ax, '-property', 'YData');
                    if isempty(kids); continue; end
                    mx = 0; any_ = false;
                    for k = 1:numel(kids)
                        y = kids(k).YData(:); y = y(isfinite(y));
                        if isempty(y); continue; end
                        mx = max(mx, max(abs(y))); any_ = true;
                    end
                    if ~any_ || mx <= 0 || ~isfinite(mx); continue; end

                    [f, newUnit] = revgnss.ClockExactReportBuilder.pickUnitScale_(mx, unit);
                    if f == 1 || ~isfinite(f)
                        ax.YAxis.Exponent = 0;   % already readable; just kill any multiplier
                        continue
                    end
                    for k = 1:numel(kids)
                        kids(k).YData = kids(k).YData * f;
                    end
                    revgnss.ClockExactReportBuilder.rescaleInsets_(fig, ax, f);
                    ax.YLabel.String = strrep(lbl, ['[' unit ']'], ['[' newUnit ']']);
                    ax.YLimMode = 'auto';
                    ax.YAxis.Exponent = 0;
                catch
                    % leave this axes untouched
                end
            end
        end

        function rescaleInsets_(fig, hostAx, f)
            % rescaleInsets_  Apply the host axes' unit rescale to its inset panels.
            insets = findall(fig, 'Type','axes', 'Tag','reportInset');
            for k = 1:numel(insets)
                try
                    if ~isequal(insets(k).UserData, hostAx); continue; end
                    kids = findall(insets(k), '-property', 'YData');
                    for q = 1:numel(kids)
                        kids(q).YData = kids(q).YData * f;
                    end
                    insets(k).YLimMode = 'auto';
                    insets(k).YAxis.Exponent = 0;
                catch
                end
            end
        end

        function plainLogTicks_(ax, which)
            % Replace a log axis's 10^n tick labels with plain numbers (0.1, 1, 10, 1000, ...).
            % Keeps the log SCALE -- which is correct when the data spans decades -- while
            % removing the exponent notation the reader does not want.
            if strcmpi(which,'Y'); ticks = ax.YTick; else; ticks = ax.XTick; end
            if isempty(ticks); return; end
            lbl = cell(1, numel(ticks));
            for k = 1:numel(ticks)
                v = ticks(k);
                if ~isfinite(v)
                    lbl{k} = '';
                elseif v == 0
                    lbl{k} = '0';
                elseif abs(v) >= 1e6 || abs(v) < 1e-4
                    % Beyond this a plain number is longer than the exponent it replaces, so
                    % keep it compact rather than printing 0.00001 or 10000000.
                    lbl{k} = sprintf('%g', v);
                else
                    lbl{k} = strtrim(sprintf('%.10g', v));
                end
            end
            if strcmpi(which,'Y')
                ax.YTickMode = 'manual'; ax.YTickLabelMode = 'manual'; ax.YTickLabel = lbl;
            else
                ax.XTickMode = 'manual'; ax.XTickLabelMode = 'manual'; ax.XTickLabel = lbl;
            end
        end

        function [f, newUnit] = pickUnitScale_(mx, unit)
            % Choose a multiplier so the largest plotted value lands in a readable range, and
            % return the matching unit string. f=1 means "leave the data alone".
            f = 1; newUnit = unit;
            u = lower(strtrim(unit));
            switch u
                case {'m','metres','meters'}
                    if     mx < 1e-5, f = 1e9;  newUnit = 'nm';
                    elseif mx < 1e-2, f = 1e3;  newUnit = 'mm';
                    elseif mx < 1,    f = 1e2;  newUnit = 'cm';
                    end
                case {'s','sec','seconds'}
                    if     mx < 1e-9, f = 1e12; newUnit = 'ps';
                    elseif mx < 1e-6, f = 1e9;  newUnit = 'ns';
                    elseif mx < 1e-3, f = 1e6;  newUnit = '\mus';
                    elseif mx < 1,    f = 1e3;  newUnit = 'ms';
                    end
                case {'m/s','mps'}
                    if     mx < 1e-3, f = 1e6;  newUnit = '\mum/s';
                    elseif mx < 1,    f = 1e3;  newUnit = 'mm/s';
                    end
                case {'deg','degrees'}
                    if mx < 1, f = 1e3; newUnit = 'mdeg'; end
                case {'rad'}
                    if     mx < 1e-3, f = 1e6;  newUnit = '\murad';
                    elseif mx < 1,    f = 1e3;  newUnit = 'mrad';
                    end
                otherwise
                    % Unknown unit: do NOT invent a prefix. Exponent suppression only.
            end
        end

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
                % Rescale into readable units BEFORE export so no figure carries a "x10^-n"
                % axis multiplier. Every plot in the report funnels through here.
                revgnss.ClockExactReportBuilder.normalizeAxisUnits_(fig);
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
            % Modern, report-scaled look (single insertion point for every report figure):
            % keep the compact 7 pt font, but soften to dark-grey ink, ticks out, a faint
            % grid and thin axes lines. Line colours stay per-plot (they are semantic).
            set(ax, 'FontSize',7, 'FontName','Helvetica', 'Box','off', ...
                'TickDir','out', 'TickLength',[0.02 0.02], 'LineWidth',0.6, ...
                'XColor',[0.20 0.20 0.22], 'YColor',[0.20 0.20 0.22], ...
                'GridColor',[0.45 0.45 0.48], 'GridAlpha',0.15, 'MinorGridAlpha',0.07);
            if nargin > 0 && ~isempty(titleStr)
                title(ax, titleStr, 'FontSize',7, 'FontWeight','normal', 'Color',[0.20 0.20 0.22]);
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
                    % Shade the +-3 sigma envelopes FIRST (colour-matched, transparent) so
                    % the three overlapping bands read as regions and the error traces
                    % draw on top of them.
                    CE_ = revgnss.ClockExactReportBuilder;
                    racSigFill = CE_.racPositionSigma_(diag, rTr(:,1:n), vTr(:,1:n), n);
                    racRgb = [0.85 0.20 0.20; 0.20 0.65 0.25; 0.20 0.35 0.85];
                    if ~isempty(racSigFill)
                        for aFill = 1:3
                            CE_.fillSigma_(ax, t, racSigFill(aFill,:)*sc, 3, racRgb(aFill,:), 0.13);
                        end
                    end
                    plot(ax, t, rac(1,:)*sc, 'r-', 'LineWidth', 0.8, 'DisplayName', 'radial');
                    plot(ax, t, rac(2,:)*sc, 'g-', 'LineWidth', 0.8, 'DisplayName', 'along-track');
                    plot(ax, t, rac(3,:)*sc, 'b-', 'LineWidth', 0.8, 'DisplayName', 'cross-track');
                    % Overlay the filter's +-3 sigma envelope per RAC axis (dotted,
                    % colour-matched, hidden from the legend). The radial band is wide
                    % under the GEO radial<->clock degeneracy; along/cross hug their traces.
                    CE = revgnss.ClockExactReportBuilder;
                    racSig = CE.racPositionSigma_(diag, rTr(:,1:n), vTr(:,1:n), n);
                    if ~isempty(racSig)
                        CE.overlaySigma_(ax, t, racSig(1,:)*sc, 3, 'r:');
                        CE.overlaySigma_(ax, t, racSig(2,:)*sc, 3, 'g:');
                        CE.overlaySigma_(ax, t, racSig(3,:)*sc, 3, 'b:');
                    end
                    legend(ax, 'show', 'Location', 'best', 'FontSize', 5);
                    xlabel(ax, 'Time [s]', 'FontSize', 7);
                    ylabel(ax, revgnss.PlotUnitScaler.axisLabel('Error', unit), 'FontSize', 7);
                    % Short title by design. The old one ran to 100 characters and, on a
                    % 7 cm canvas, wrapped into several lines that ate most of the figure
                    % height, so the plot itself came out tiny on the page. It also
                    % contained \x2014, which is not a TeX command: MATLAB's TeX
                    % interpreter gave up on the whole string and printed it raw, so the
                    % reader saw a literal "\pm3\sigma". The precision-not-uncertainty
                    % caveat now lives in the LaTeX description column beside the figure.
                    title(ax, 'RAC position error (shaded = formal \pm3\sigma)', 'FontSize', 7);
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
        function fig = plotInitialTransient_(diag, t, windowSec)
            % Initial convergence transient: A PRIORI (pre-update) vs POSTERIOR
            % (post-update) position error over the opening window, log-y.
            %
            % Why this figure exists: the per-epoch history row is committed AFTER the
            % epoch's measurement update, so the posterior series -- every other position
            % plot in this report -- begins at an already-corrected value. The configured
            % cfg.estimator.initialError offset is consumed by the first update and never
            % appears. The prior series is the only place the initial condition is visible,
            % and the gap between the two curves at epoch 1 IS the transient.
            %
            % Returns [] when no prior series is present (legacy struct-log runs and
            % .mat files captured before the prior series existed), so tryPlot_ yields ''
            % and the report row is silently omitted rather than printing an empty axes.
            fig = [];
            if nargin < 3 || isempty(windowSec); windowSec = 120; end
            prior = [];
            try; prior = diag.getPriorPositionErrors(); catch; return; end
            if isempty(prior) || ~any(isfinite(prior)); return; end

            post = [];
            try; post = diag.getPositionErrors(); catch; end
            sigPrior = [];
            try; sigPrior = diag.getPriorPositionSigmas(); catch; end

            prior = prior(:).'; post = post(:).'; t = t(:).';
            n = min([numel(t), numel(prior), numel(post)]);
            if n < 2; return; end
            t = t(1:n); prior = prior(1:n); post = post(1:n);

            % Opening window, but always at least a handful of epochs: on a coarse-dt run
            % windowSec could otherwise select a single point and hide the very step the
            % figure exists to show.
            iEnd = find(t <= t(1) + windowSec, 1, 'last');
            if isempty(iEnd); iEnd = n; end
            iEnd = max(iEnd, min(n, 10));

            % A log axis renders nothing for non-positive data, so an ideal-flat config
            % (errors identically zero) would otherwise emit a blank figure. Omit the row
            % instead.
            if ~any(prior(1:iEnd) > 0) && ~any(post(1:iEnd) > 0); return; end

            fig = revgnss.ClockExactReportBuilder.makeCompactFig_('');
            ax  = gca(fig);
            hold(ax, 'on');

            % 3-sigma RSS of the a priori formal uncertainty. At epoch 1 this is the P0 the
            % filter was initialised with, so the curve shows the covariance collapsing
            % alongside the error.
            if ~isempty(sigPrior) && size(sigPrior,2) >= iEnd
                s3 = 3 * sqrt(sum(sigPrior(:,1:iEnd).^2, 1));
                if any(isfinite(s3) & s3 > 0)
                    plot(ax, t(1:iEnd), s3, ':', 'Color',[0.45 0.45 0.48], ...
                        'LineWidth',0.7, 'DisplayName','prior 3\sigma (RSS)');
                    plot(ax, t(1), s3(1), 'o', 'MarkerSize',3.5, ...
                        'MarkerEdgeColor',[0.45 0.45 0.48], 'MarkerFaceColor','w', ...
                        'LineWidth',0.7, 'HandleVisibility','off');
                end
            end

            plot(ax, t(1:iEnd), prior(1:iEnd), '-', 'Color',[0.85 0.20 0.20], ...
                'LineWidth',0.9, 'DisplayName','a priori (pre-update)');
            plot(ax, t(1:iEnd), post(1:iEnd), '-', 'Color',[0.20 0.35 0.85], ...
                'LineWidth',0.9, 'DisplayName','posterior (post-update)');
            % Mark epoch 1 explicitly: it is the configured initial error, and on a log
            % axis over a 120 s window it is one pixel wide without a marker.
            plot(ax, t(1), prior(1), 'o', 'MarkerSize',3.5, ...
                'MarkerEdgeColor',[0.85 0.20 0.20], 'MarkerFaceColor','w', ...
                'LineWidth',0.7, 'HandleVisibility','off');

            set(ax, 'YScale', 'log');
            grid(ax, 'on');
            % Pad the left edge: epoch 1 is the whole point of this figure, and flush
            % against the axis its marker and the near-vertical first segment are clipped.
            span = t(iEnd) - t(1);
            if span > 0; xlim(ax, [t(1) - 0.03*span, t(iEnd)]); else; xlim(ax,'auto'); end
            legend(ax, 'show', 'Location','best', 'FontSize',5);
            xlabel(ax, 'Time [s]', 'FontSize', 7);
            ylabel(ax, 'Position error [m]', 'FontSize', 7);
            title(ax, sprintf('A priori vs posterior (first %g s, log)', ...
                t(iEnd) - t(1)), 'FontSize', 7);
        end

        % ................................................................
        function fig = plotSwarmPosError_(diag, t, zoomSec)
            % Honest multi-asset swarm: per-satellite ABSOLUTE position error (solid) with
            % the filter's +/-3-sigma envelope (dashed), over the RELATIVE baseline error to
            % the chief (the two-way-ISL-sharpened shape). Two stacked panels, all secondaries
            % on one axis for direct comparison. When zoomSec>0 the x-axis is the final window.
            %
            % Returns [] (NOT a graphics handle) when the run carries no secondary-orbit
            % estimate -- single-asset or non-'position' estimateMode. tryPlot_ then yields ''
            % and the report row is omitted, so single-asset .tex is byte-identical.
            fig = [];
            if nargin < 3; zoomSec = []; end
            try; d = diag.getData(); catch; return; end
            if ~isfield(d,'secondaryOrbit') || ~isfield(d.secondaryOrbit,'posError_m') || ...
                    isempty(d.secondaryOrbit.posError_m) || ~any(isfinite(d.secondaryOrbit.posError_m(:)))
                return;
            end
            so   = d.secondaryOrbit;
            E    = so.posError_m;
            SG   = []; if isfield(so,'posSigma_m'); SG = so.posSigma_m; end
            nSec = size(E,1);
            tt   = t(:).'; if numel(tt) ~= size(E,2); tt = 1:size(E,2); end
            xl   = [];
            if ~isempty(zoomSec) && zoomSec > 0 && numel(tt) > 1
                xl = [max(tt(end)-zoomSec, tt(1)), tt(end)];
            end
            col  = lines(max(nSec,1));
            zlab = ''; if ~isempty(xl); zlab = sprintf(', final %g s', zoomSec); end

            fig = figure('Visible','off','Color','white','Units','pixels','Position',[80 80 1080 760]);
            tl  = tiledlayout(fig,2,1,'TileSpacing','compact','Padding','compact');

            % Panel 1: ABSOLUTE per-satellite error (solid) vs filter +/-3 sigma (dashed).
            ax1 = nexttile(tl); hold(ax1,'on'); grid(ax1,'on');
            for i = 1:nSec
                plot(ax1, tt, E(i,:), '-', 'Color', col(i,:), 'LineWidth',1.3, ...
                    'DisplayName', sprintf('GEO-%d abs err', i+1));
                if ~isempty(SG) && size(SG,1) >= i
                    plot(ax1, tt, 3*SG(i,:), '--', 'Color', col(i,:), 'LineWidth',0.8, ...
                        'HandleVisibility','off');
                end
            end
            ylabel(ax1,'|position error| [m]', 'FontSize',9);
            title(ax1, ['ABSOLUTE error (solid) vs filter \pm3\sigma (dashed)' zlab], 'FontSize',10);
            if nSec > 0; legend(ax1,'Location','best','FontSize',8); end
            if ~isempty(xl); xlim(ax1,xl); end

            % Panel 2: RELATIVE per-satellite baseline error to the chief.
            ax2 = nexttile(tl); hold(ax2,'on'); grid(ax2,'on');
            if isfield(so,'baselineError_m') && ~isempty(so.baselineError_m) && any(isfinite(so.baselineError_m(:)))
                B = so.baselineError_m;
                for i = 1:nSec
                    plot(ax2, tt, B(i,:), '-', 'Color', col(i,:), 'LineWidth',1.3, ...
                        'DisplayName', sprintf('GEO-%d baseline err', i+1));
                end
                yline(ax2,0,'k:','HandleVisibility','off');
                ylabel(ax2,'baseline error (est - truth) [m]', 'FontSize',9);
                title(ax2, ['RELATIVE baseline error to chief (shape)' zlab], 'FontSize',10);
                if nSec > 0; legend(ax2,'Location','best','FontSize',8); end
                if ~isempty(xl); xlim(ax2,xl); end
            else
                revgnss.ClockExactReportBuilder.noDataAxes_(ax2);
            end
            xlabel(ax2,'time [s]', 'FontSize',9);
            title(tl, 'Per-satellite position error, honest multi-asset swarm', ...
                'FontWeight','bold', 'FontSize',11);
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
        function fig = plotClockTruthVsEstimate_(diag, t)
            % True receiver-clock development vs the EKF-estimated ("corrected") clock.
            % truth = getRxClockBiasTrue [s]; error = getClockBiasErrors [m] = est - truth;
            % so estimate [s] = truth + error/c. Shows what the clock really does vs the filter's
            % reconstruction (the residual is the separate clock-error plot). Under the one-way GEO
            % radial<->clock degeneracy the estimate absorbs the radial common mode and wanders far
            % more than the (quiet) truth.
            fig = revgnss.ClockExactReportBuilder.makeCompactFig_('');
            ax  = gca(fig);
            try
                bt = diag.getRxClockBiasTrue();     % [s] truth
                er = diag.getClockBiasErrors();     % [m] est - truth
                if ~isempty(t) && ~isempty(bt) && ~isempty(er)
                    c0 = revgnss.Constants.SPEED_OF_LIGHT_MPS;
                    n  = min([numel(t) numel(bt) numel(er)]);
                    t = t(1:n); bt = bt(1:n); er = er(1:n);
                    est = bt(:) + er(:) / c0;        % [s] estimate = truth + error
                    % Scale by the estimate range (the visibly-wandering series).
                    [ests, unit, sc] = revgnss.PlotUnitScaler.scaleMetric(est, 's');
                    bts = bt(:) * sc;
                    hold(ax,'on');
                    plot(ax, t, bts,  'k-',  'LineWidth', 1.1);
                    plot(ax, t, ests, 'r--', 'LineWidth', 0.8);
                    xlabel(ax, 'Time [s]', 'FontSize',7);
                    ylabel(ax, revgnss.PlotUnitScaler.axisLabel('RX clock bias', unit), 'FontSize',7);
                    title(ax, 'Receiver clock: truth vs EKF estimate', 'FontSize',7);
                    legend(ax, {'truth','estimate'}, 'FontSize',6, 'Location','best', 'Box','off');
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
        function fig = plotInnovationRMS_(diag, t, zoomSec)
            % plotInnovationRMS_  Pre-fit innovation and post-fit residual RMS, with the
            %   settled tail inset INSIDE the same axes. The full run is dominated by the
            %   opening transient, which compresses the converged part of both curves into
            %   the axis; the inset shows the last zoomSec seconds on its own scale so the
            %   settled level is readable without spending a second report row on it.
            if nargin < 3 || isempty(zoomSec); zoomSec = 120; end
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
                    end
                    xlabel(ax,'Time [s]','FontSize',7);
                    ylabel(ax,'RMS [m]','FontSize',7);
                    grid(ax,'on');
                    legend(ax,'show','Location','northoutside', ...
                        'Orientation','horizontal','FontSize',5,'Box','off');
                    revgnss.ClockExactReportBuilder.insetTail_(ax, t, ...
                        {pf, po}, {'b-','r--'}, zoomSec);
                    return;
                end
            catch; end
            revgnss.ClockExactReportBuilder.noDataAxes_(ax);
        end

        % ................................................................
        function insetTail_(ax, t, series, styles, zoomSec, titleStr)
            % insetTail_  Draw a small "last zoomSec s" panel inside the parent axes.
            %   Placed in the upper-right of the parent, which is where these decaying
            %   curves leave space. Silently does nothing when the window would hold
            %   fewer than two samples.
            %
            %   titleStr overrides the default 'last N s' caption. It exists so a caller
            %   whose MAIN axes already shows the tail can invert the pair -- pass the full
            %   span as zoomSec and 'full run' as the title -- without a second helper that
            %   would have to be kept in visual step with this one.
            if nargin < 6 || isempty(titleStr); titleStr = sprintf('last %g s', zoomSec); end
            t = t(:).';
            if numel(t) < 3 || ~isfinite(zoomSec) || zoomSec <= 0; return; end
            i0 = find(t >= t(end) - zoomSec, 1, 'first');
            if isempty(i0) || (numel(t) - i0) < 1; return; end
            pos = get(ax, 'Position');
            inPos = [pos(1) + 0.50*pos(3), pos(2) + 0.52*pos(4), ...
                     0.42*pos(3), 0.36*pos(4)];
            % Tagged and parented so normalizeAxisUnits_ rescales the inset by the SAME
            % factor as its host axes. Left to itself it would pick its own SI prefix
            % from its own (smaller) settled maximum, and the inset would then be a
            % different unit from the axis label it sits inside, with nothing saying so.
            axIn = axes(ancestor(ax,'figure'), 'Position', inPos, ...
                'Tag','reportInset', 'UserData',ax);
            hold(axIn,'on');
            drew = false;
            for k = 1:numel(series)
                y = series{k};
                if isempty(y) || numel(y) < numel(t); continue; end
                y = y(:).';
                plot(axIn, t(i0:end), y(i0:numel(t)), styles{k}, ...
                    'LineWidth',0.7, 'HandleVisibility','off');
                drew = true;
            end
            if ~drew; delete(axIn); return; end
            set(axIn, 'FontSize',5, 'FontName','Helvetica', 'Box','on', ...
                'TickDir','out', 'LineWidth',0.5, ...
                'XColor',[0.20 0.20 0.22], 'YColor',[0.20 0.20 0.22], ...
                'Color',[1 1 1], 'GridColor',[0.45 0.45 0.48], 'GridAlpha',0.15);
            grid(axIn,'on');
            xlim(axIn, [t(i0) t(end)]);
            title(axIn, titleStr, 'FontSize',5, ...
                'FontWeight','normal', 'Color',[0.20 0.20 0.22]);
        end

        % ................................................................
        function fig = plotNIS_(diag, t)
            fig = revgnss.ClockExactReportBuilder.makeCompactFig_('');
            ax  = gca(fig);
            try
                n = diag.getNIS();
                if ~isempty(t) && ~isempty(n)
                    % E[NIS_k] = M_k, the row count of epoch k -- NOT 1. Drawn bare, a
                    % curve sitting near 100 reads as a catastrophic failure when it is
                    % the nominal value, so the dof and its two-sided 95% chi-squared
                    % band go behind the series as the reference the eye needs.
                    [dof, lo, hi] = revgnss.ClockExactReportBuilder.nisDofBand_(diag, numel(n));
                    if numel(t) ~= numel(n); dof = []; end   % band must align with t
                    hold(ax,'on');
                    if ~isempty(dof)
                        tc = t(:);
                        % Edged, not EdgeColor 'none': the edge draws the band limits
                        % crisply AND gives the legend swatch a visible outline.
                        fill(ax, [tc; flipud(tc)], [lo(:); flipud(hi(:))], [0.80 0.80 0.80], ...
                            'EdgeColor',[0.62 0.62 0.62], 'LineWidth',0.4, ...
                            'FaceAlpha',0.55, 'DisplayName','95% \chi^2 (per epoch)');
                        plot(ax, tc, dof, 'r--', 'LineWidth',0.8, 'DisplayName','E[NIS] = dof');
                    end
                    plot(ax, t, n, 'k-', 'LineWidth',0.8, 'DisplayName','NIS');
                    xlabel(ax,'Time [s]','FontSize',7);
                    ylabel(ax,'NIS [-]','FontSize',7);
                    grid(ax,'on');
                    if ~isempty(dof)
                        % Outside the axes: NIS fills its band top to bottom, so every
                        % in-axes location lands on the data.
                        legend(ax,'Location','northoutside','Orientation','horizontal', ...
                            'FontSize',6,'Box','off');
                    end
                    hold(ax,'off');
                    return;
                end
            catch; end
            revgnss.ClockExactReportBuilder.noDataAxes_(ax);
        end

        function [dof, lo, hi] = nisDofBand_(diag, nEpochs)
            % nisDofBand_  Per-epoch NIS dof and its two-sided 95% chi-squared band.
            %   The dof is the EKF row count, which can change with tower visibility, so
            %   the band is evaluated per epoch -- but only once per DISTINCT dof, since
            %   the count is constant in most runs. Empty on any gap: a partial band
            %   would misplace the reference the plot is being given.
            dof = []; lo = []; hi = [];
            rows = double(diag.getNumMeasurementRows());
            rows = rows(:);
            if numel(rows) ~= nEpochs || isempty(rows) || any(~isfinite(rows)) || any(rows <= 0)
                return;
            end
            dof = rows;
            lo  = zeros(size(rows));
            hi  = zeros(size(rows));
            for d = unique(rows)'
                [l_, h_] = revgnss.ChiSquareConsistency.bounds(d, 0.95);
                m = (rows == d);
                lo(m) = l_;
                hi(m) = h_;
            end
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
                hdop = []; vdop = [];
                try; hdop = diag.getHDOPLike(); catch; end
                try; vdop = diag.getVDOPLike(); catch; end
                % A DOP series is NaN wherever the geometry was rank-deficient, so it can
                % be legitimately sparse. Say "no data" only when NOTHING is finite --
                % otherwise plotSparse_ still renders whatever samples exist.
                % Unit-weight (dimensionless) counterparts. Absent on stores written before
                % they existed, in which case this figure falls back to the weighted series
                % under an honest label rather than rendering nothing.
                gdopG = []; pdopG = []; vdopG = []; hdopG = [];
                try; gdopG = diag.getGDOPGeometric(); catch; end
                try; pdopG = diag.getPDOPGeometric(); catch; end
                try; vdopG = diag.getVDOPGeometric(); catch; end
                try; hdopG = diag.getHDOPGeometric(); catch; end
                hasG_ = any(isfinite(gdopG));
                if ~hasG_
                    gdopG = gdop; pdopG = pdop; vdopG = vdop; hdopG = hdop;
                end
                if ~isempty(t) && any(isfinite(gdopG))
                    hold(ax,'on');
                    CE_ = @revgnss.ClockExactReportBuilder.plotSparse_;
                    CE_(ax,t,gdopG,'b','-', 'GDOP');
                    CE_(ax,t,pdopG,'r','--','PDOP');
                    % HDOP/VDOP in the orbital RAC frame (a spacecraft has no local
                    % horizon). VDOP is the RADIAL axis -- the one degenerate with the
                    % receiver clock at GEO -- so it is expected to dominate, and PDOP
                    % therefore draws underneath it.
                    CE_(ax,t,vdopG,'m','-', 'VDOP (radial)');
                    CE_(ax,t,hdopG,'g','-.','HDOP (along+cross)');
                    if hasG_
                        ylabel(ax,'DOP [-]','FontSize',7);
                    else
                        % No unit-weight series in this store, so what is on screen is the
                        % R-weighted quantity. Say so in the label rather than let a metre
                        % value sit under a dimensionless one.
                        ylabel(ax,'Formal sigma [m] (R-weighted)','FontSize',7);
                    end
                    revgnss.ClockExactReportBuilder.legendOutside_(ax);
                    xlabel(ax,'Time [s]','FontSize',7);
                    grid(ax,'on');
                    return;
                end
            catch; end
            revgnss.ClockExactReportBuilder.noDataAxes_(ax);
        end

        % ................................................................
        function fig = plotDOPSigma_(diag, t, zoomSec)
            % plotDOPSigma_  The R-WEIGHTED DOPs, i.e. single-epoch formal sigmas [m].
            %
            % Companion to plotDOP_. Same four quantities, formed with the measurement
            % covariance instead of unit weights, so they move with R rather than with the
            % sight lines. On this stack that means a sawtooth: the tower-clock correction
            % sigma inside R grows with the age of the last clock product and resets every
            % cfg.clocks.tower.product.updateInterval_s.
            %
            % The MAIN axes shows the tail window, not the whole arc, and the inset carries
            % the full run. At 1 h against a 30 s product interval the arc holds ~120 cycles
            % at roughly one pixel each: as the main plot that is a solid band which says
            % nothing about the shape, and it buried the flat geometry curves when the two
            % flavours shared one axes. The tail window is where the ramp and the reset are
            % separately visible, and it loses nothing, because the modulation is a function
            % of the product AGE alone -- MEASURED on golden_baseline_attitude, GDOP at
            % t = 40 / 70 / 100 s (all age 10 s) is 183.2 / 180.6 / 181.3. The full-run inset
            % is what backs that claim up: it shows the envelope repeating rather than
            % drifting, which one window on its own could not establish.
            if nargin < 3 || isempty(zoomSec); zoomSec = 120; end
            fig = revgnss.ClockExactReportBuilder.makeCompactFig_('');
            ax  = gca(fig);
            try
                gdop = diag.getGDOPLike();
                pdop = diag.getPDOPLike();
                hdop = []; vdop = [];
                try; hdop = diag.getHDOPLike(); catch; end
                try; vdop = diag.getVDOPLike(); catch; end
                if ~isempty(t) && any(isfinite(gdop))
                    hold(ax,'on');
                    CE_ = @revgnss.ClockExactReportBuilder.plotSparse_;
                    CE_(ax,t,gdop,'b','-', 'GDOP x sigma');
                    CE_(ax,t,pdop,'r','--','PDOP x sigma');
                    CE_(ax,t,vdop,'m','-', 'VDOP x sigma (radial)');
                    CE_(ax,t,hdop,'g','-.','HDOP x sigma (along+cross)');
                    ylabel(ax,'Formal sigma [m]','FontSize',7);
                    grid(ax,'on');
                    revgnss.ClockExactReportBuilder.legendOutside_(ax);
                    % Crop the VIEW to the tail. plotSparse_ has already drawn the whole
                    % series, so nothing is discarded and the inset below still reaches it.
                    tSpan_ = t(end) - t(1);
                    if isfinite(zoomSec) && zoomSec > 0 && zoomSec < tSpan_
                        xlim(ax, [t(end)-zoomSec, t(end)]);
                        xlabel(ax, sprintf('Time [s] (last %g s)', zoomSec), 'FontSize',7);
                    else
                        xlabel(ax,'Time [s]','FontSize',7);
                    end
                    % Full run in the inset. Linespec strings, not RGB triplets: insetTail_
                    % forwards these straight to plot() as a format argument.
                    revgnss.ClockExactReportBuilder.insetTail_(ax, t, ...
                        {gdop, pdop, vdop, hdop}, {'b-','r--','m-','g-.'}, tSpan_, 'full run');
                    % Thin the inset's ticks. insetTail_ leaves them on auto, which at
                    % FontSize 5 in a panel this small prints four-digit epoch labels
                    % close enough to touch. Done here rather than in insetTail_ so the
                    % innovation figure that shares it keeps its current appearance.
                    for axIn_ = findall(fig, 'Type','axes', 'Tag','reportInset').'
                        if ~isequal(axIn_.UserData, ax); continue; end
                        xl_ = xlim(axIn_); yl_ = ylim(axIn_);
                        set(axIn_, 'XTick', linspace(xl_(1), xl_(2), 3), ...
                                   'YTick', linspace(yl_(1), yl_(2), 3));
                    end
                    return;
                end
            catch; end
            revgnss.ClockExactReportBuilder.noDataAxes_(ax);
        end

        % ................................................................
        function legendOutside_(ax)
            % legendOutside_  Legend above the axes, horizontal, off the data.
            %   'Location','best' searches for empty space INSIDE the axes. A series that
            %   fills its axes -- a sawtooth over a long arc, say -- has none, so 'best'
            %   parks the box on top of the curves and the figure becomes unreadable
            %   exactly when it carries the most data. Above the axes there is always room.
            try
                lg = legend(ax, 'show');
                set(lg, 'Location','northoutside', 'Orientation','horizontal', ...
                    'NumColumns',2, 'FontSize',5, 'Box','off');
            catch
                try; legend(ax,'show','Location','best','FontSize',5); catch; end
            end
        end

        % ................................................................
        function plotSparse_(ax, t, y, colour, style, name)
            % plotSparse_  Draw a series that may be mostly NaN.
            %   A line segment needs two ADJACENT finite samples. A series sampled at a
            %   coarse diagnostic interval, or punctuated by rank-deficient epochs, has
            %   none, so a plain line plot renders an empty axes even though the data is
            %   there. Fall back to markers in that case so the samples are visible.
            if isempty(y) || ~any(isfinite(y)); return; end
            n = min(numel(t), numel(y));
            t = t(1:n); y = y(1:n);
            fin = isfinite(y);
            hasSegment = any(fin(1:end-1) & fin(2:end));
            if hasSegment
                plot(ax, t, y, 'Color',colour, 'LineStyle',style, ...
                    'LineWidth',0.8, 'DisplayName',name);
            else
                plot(ax, t(fin), y(fin), 'Color',colour, 'LineStyle','none', ...
                    'Marker','o', 'MarkerSize',3, 'MarkerFaceColor',colour, ...
                    'DisplayName',name);
            end
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
                        legend(ax,'show','Location','best','FontSize',6);
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
            Pd = revgnss.ClockExactReportBuilder.pdiagOf_(diag);
            if isempty(Pd) || size(Pd,1) < idx; return; end
            row = sqrt(max(Pd(idx,:), 0)) * scale;
            if i0 < 1; i0 = 1; end
            if i0 > numel(row); return; end
            s = row(i0:end);
        end

        function Pd = pdiagOf_(diag)
            % pdiagOf_  [nx x N] covariance diagonal from either accessor layer.
            %   Reads the dedicated getPdiag() accessor FIRST. The previous route went
            %   through the heavy getData() struct, which throws on a store rebuilt from
            %   an older .mat -- and because every caller wrapped that in try/catch, the
            %   failure was silent: the clock plots kept their "dotted = +-3 sigma" title
            %   while drawing no band at all, and the RAC position plot lost its shading.
            Pd = [];
            try
                Pd = diag.getPdiag();
            catch
                Pd = [];
            end
            if ~isempty(Pd); return; end
            try
                d_ = diag.getData();
                if isfield(d_,'Pdiag'); Pd = d_.Pdiag; end
            catch
                Pd = [];
            end
        end

        function fillSigma_(ax, tt, sig, k, rgb, alpha)
            % fillSigma_  Shade the +/- k*sigma region as a transparent colour-matched
            %   band, so overlapping axes read like a seaborn/fill_between plot rather
            %   than six competing dotted lines. Drawn BEFORE the error traces so the
            %   traces sit on top; hidden from the legend; no-op on bad input.
            if isempty(sig) || numel(sig) ~= numel(tt) || all(~isfinite(sig)); return; end
            if nargin < 6 || isempty(alpha); alpha = 0.15; end
            tt = tt(:).'; sig = sig(:).';
            good = isfinite(sig) & isfinite(tt);
            if ~any(good); return; end
            tt = tt(good); sig = sig(good);
            hold(ax,'on');
            xPatch = [tt, fliplr(tt)];
            yPatch = [k*sig, fliplr(-k*sig)];
            patch(ax, 'XData',xPatch, 'YData',yPatch, ...
                'FaceColor',rgb, 'FaceAlpha',alpha, 'EdgeColor','none', ...
                'HandleVisibility','off');
        end

        function overlaySigma_(ax, tt, sig, k, style)
            % overlaySigma_  Draw +/- k*sigma dotted covariance borders on ax over time tt.
            %   Hidden from the legend; no-op if the sigma vector is unavailable/mismatched.
            if isempty(sig) || numel(sig) ~= numel(tt) || all(~isfinite(sig)); return; end
            hold(ax,'on');
            plot(ax, tt,  k*sig, style, 'LineWidth',0.6, 'HandleVisibility','off');
            plot(ax, tt, -k*sig, style, 'LineWidth',0.6, 'HandleVisibility','off');
        end

        function racSig = racPositionSigma_(diag, rEcef, vEcef, n)
            % racPositionSigma_  [3 x n] 1-sigma of the radial / along-track /
            %   cross-track POSITION error, from the FULL EKF position covariance
            %   (states 1:3, including cross-covariance) projected into the RAC frame
            %   with the SAME v_eff = v_ecef + omega x r convention as
            %   OrbitFrame.ecefToRacGeo: sigma_axis = sqrt(basis' * Ppos * basis).
            %   Falls back to the diagonal-only projection (sqrt(sum basis_i^2 * Pii))
            %   for report data written before PposOffDiag_m2 existed -- the diagonal
            %   projection under/over-states the band whenever the ellipse isn't
            %   ECEF-axis-aligned (see project_stochastic_audit_rac3sigma memory).
            %   Returns [] if Pdiag is unavailable (callers then draw no band).
            racSig = [];
            try
                Pd_ = revgnss.ClockExactReportBuilder.pdiagOf_(diag);
                if isempty(Pd_) || size(Pd_,1) < 3
                    return;
                end
                Pxyz = max(Pd_(1:3,:), 0);                    % [3 x N] x/y/z variance
                Xoff = revgnss.ClockExactReportBuilder.pposOffDiagOf_(diag);
                w = 7.2921150e-5;
                try; w = revgnss.Constants.EARTH_OMEGA_RADPS; catch; end
                omega = [0;0;w];
                np = min(n, size(Pxyz,2));
                racSig = nan(3, n);
                for kk = 1:np
                    rk = rEcef(:,kk); veff = vEcef(:,kk) + cross(omega, rk);
                    [rH,aH,hH,ok] = revgnss.OrbitFrame.racBasis(rk, veff);
                    if ~ok; continue; end
                    if ~isempty(Xoff) && kk <= size(Xoff,2) && all(isfinite(Xoff(:,kk)))
                        p = Pxyz(:,kk); xo = Xoff(:,kk);
                        Ppos = [p(1) xo(1) xo(2); xo(1) p(2) xo(3); xo(2) xo(3) p(3)];
                        racSig(:,kk) = sqrt(max([rH'*Ppos*rH; aH'*Ppos*aH; hH'*Ppos*hH], 0));
                    else
                        p = Pxyz(:,kk);
                        racSig(:,kk) = sqrt([ (rH.^2).'*p; (aH.^2).'*p; (hH.^2).'*p ]);
                    end
                end
            catch; racSig = []; end
        end

        function X = pposOffDiagOf_(diag)
            % pposOffDiagOf_  [3 x N] (Pxy;Pxz;Pyz), or [] when the store predates it.
            X = [];
            try
                X = diag.getPposOffDiag();
            catch
                X = [];
            end
            if isempty(X)
                try
                    d_ = diag.getData();
                    if isfield(d_,'PposOffDiag_m2'); X = d_.PposOffDiag_m2; end
                catch
                    X = [];
                end
            end
            if ~isempty(X) && size(X,1) ~= 3; X = []; end
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
            fprintf(fid, '{\\small Reverse-GNSS EKF simulator, validation version %s \\\\ Generated %s}\\\\[3pt]\n', ...
                esc(ver), esc(ts));
            fprintf(fid, '{\\footnotesize Controlled synthetic reverse-GNSS scenario.}\n');
            fprintf(fid, '\\end{center}\n');
            fprintf(fid, '\\vspace{0.3cm}\n');

            % ---- Sections -----------------------------------------------
            revgnss.report.scenarioSummary(fid, cfg, summary, diag, nTwr, nRx, dur, dt, esc, plotPaths, stem, figDir);
            % stateEstimation receives `summary` so a federated-swarm run can place the two
            % swarm plots directly after the RAC final-zoom row (see item-9 change).
            revgnss.report.stateEstimation(fid, plotPaths, stem, cfg, diag, figDir, summary);
            % Mandatory per-pair relative-position table for multi-asset runs. Emits
            % nothing when summary.pairwiseRelativePositionError is absent or
            % unavailable, so single-asset .tex stays byte-identical to the golden.
            revgnss.report.relativeFormationPairs(fid, cfg, summary, esc);
            % Coherent-beamforming phase budget of the same relative solution. Emits
            % nothing when summary.beamformingPhasor is absent or unavailable, so
            % single-asset .tex stays byte-identical to the golden.
            revgnss.report.beamformingPhasor(fid, cfg, summary, esc, plotPaths);
            revgnss.report.measurementValidation( ...
                fid, plotPaths, stem, figDir, diag, cfg, summary);
            % Oscillator Stability Validation removed on request (2026-08-07). It was an
            % Allan-deviation-only section; the ADEV plot is no longer wanted in the report.
            % +revgnss/+report/oscillatorValidation.m is retained but no longer called.
            revgnss.report.txCodeBias(fid, diag, cfg);
            % Troposphere and ZWD Architecture removed on request (2026-08-07). It was a
            % five-row static configuration table that restated the scenario JSON and carried
            % no measured quantity. +revgnss/+report/tropZwdArchitecture.m is retained but no
            % longer called, matching the oscillatorValidation precedent above.
            % LAST PLOT before the Numerical Summary: the actual complex sum behind the
            % scalar beamforming loss. Emits nothing on single-asset runs.
            revgnss.report.phasorDiagram(fid, cfg, summary, figDir, stem, esc);
            revgnss.report.numericalSummary(fid, cfg, summary, diag);
            % Federated-swarm appendix: emits nothing unless summary.federatedSwarm is set
            % (swarm runs only) -> single-asset .tex is byte-identical to the golden.
            revgnss.report.federatedSwarmAppendix(fid, cfg, summary, figDir, esc);

            fprintf(fid, '\\end{document}\n');
            fclose(fid);
        end

        % ================================================================
        % SECTION 1 — SCENARIO SUMMARY
        % ================================================================

        % writeScenarioSummary_ extracted to +revgnss/+report/scenarioSummary.m.


        % ================================================================
        % COMPONENT STATUS ROWS (1.6)
        % ================================================================

        function tf = carrierIfActive_(cfg)
            % The ONE authority on whether the EKF's carrier rows are the L1/L2 ionosphere-free
            % combination. Calls combineStatus, not shouldCombine (P12): shouldCombine only
            % reflects the two config leaves and says "combined" even with a single active
            % carrier signal, when the physics (CarrierMeasurementBuilder.m) silently falls
            % through to raw rows. combineStatus ANDs in the signal count so this can never
            % drift from what the EKF actually received.
            tf = false;
            try; tf = logical(revgnss.CarrierIonoFreeRowBuilder.combineStatus(cfg)); catch; end
        end

        function s = channelCell_(on)
            % One channel of the three-channel effect table. Deliberately binary: the whole
            % point of splitting truth/model/noise is that each channel IS on or off.
            if isequal(on, true)
                s = '\textcolor{green!45!black}{$\bullet$}';
            else
                s = '\textcolor{gray!45}{$\circ$}';
            end
        end

        function rows = atmosphereEffectRows_(cfg)
            % atmosphereEffectRows_  Three-channel status for each propagation error source.
            % Row schema: {name, truthOn, modelOn, noiseOn, note}. Every gate below is the key
            % the PHYSICS reads, verified against its consumer -- not a documentary mirror.
            CE = revgnss.ClockExactReportBuilder;
            g  = @(p,d) CE.getLogical_(cfg, p, d);
            gs = @(p,d) CE.getCfgStr_(cfg, p, d);

            % --- troposphere -----------------------------------------------------------
            tT = g({'errors','troposphere','truth','enable'}, false);
            tM = g({'errors','troposphere','model','enable'}, false);
            tBias = CE.getCfgNum_(cfg, {'errors','troposphere','model','biasFraction'}, 1);
            zwdOn = strcmpi(gs({'estimation','troposphereMode'},'none'), 'perTowerZwd');
            if ~tT
                tNote = 'Not injected. Sigma still charged to R (see Noise).';
            elseif zwdOn
                tNote = 'Injected; residual absorbed by the per-tower ZWD EKF state.';
            elseif tM && abs(tBias-1) < 1e-9
                tNote = 'Injected and corrected identically: residual is ZERO by construction, not a modelled effect.';
            elseif tM
                tNote = sprintf('Injected; model applies %.0f%% of the truth delay, so a residual survives.', 100*tBias);
            else
                tNote = 'Injected with NO correction: the full delay reaches the filter.';
            end

            % --- ionosphere ------------------------------------------------------------
            % The first-order term is removed by the L1/L2 ionosphere-free combination -- but
            % CODE and CARRIER are gated SEPARATELY and disagree in the default config:
            %   code    : cfg.measurements.codeMode == 'ionosphereFree'
            %   carrier : revgnss.CarrierIonoFreeRowBuilder.shouldCombine(cfg)
            % measurements.code.ionosphereFreeRows.{enable,useInEkf} are DEAD keys -- their only
            % non-test consumer is an unreachable fallback in CodeMeasurementBuilder, dead
            % because codeMode is never empty. An earlier version of this row read them and
            % therefore reported the opposite of what the run did.
            iT = g({'errors','ionosphere','truth','enable'}, false);
            iM = g({'errors','ionosphere','model','enable'}, false);
            iCorr = lower(gs({'errors','ionosphere','model','correction'},'none'));
            iMdl  = gs({'errors','ionosphere','modelType'},'');
            iHO   = g({'errors','ionosphere','higherOrder','enable'}, false);
            iCodeIF = strcmpi(gs({'measurements','codeMode'},''), 'ionosphereFree');
            iCarrIF = false;
            try; iCarrIF = logical(revgnss.CarrierIonoFreeRowBuilder.combineStatus(cfg)); catch; end
            iStateOn = strcmpi(gs({'estimation','ionosphereMode'},'none'), 'perTowerSlant');
            if ~iT
                iNote = 'Not injected. Sigma still charged to R (see Noise).';
            else
                ifTxt = sprintf('First order: %s on code rows, %s on carrier rows (L1/L2 IF combination).', ...
                    CE.yesNo_(iCodeIF,'cancelled','SURVIVES'), CE.yesNo_(iCarrIF,'cancelled','SURVIVES'));
                if iStateOn
                    iNote = [ifTxt ' Remainder absorbed by the per-tower slant EKF state.'];
                elseif iM && ~strcmpi(iCorr,'none')
                    iNote = sprintf('%s %s truth corrected by the %s broadcast model, which APPROXIMATES it, so a residual survives.%s', ...
                        ifTxt, revgnss.ReportLabel.humanize(iMdl), iCorr, ...
                        CE.yesNo_(iHO,' Higher-order terms survive the IF combination.',''));
                else
                    iNote = [ifTxt ' No model correction: the residual reaches the filter in full.'];
                end
            end

            % --- Shapiro: the archetypal former 'Matched' row --------------------------
            sT = g({'physics','relativity','shapiro','truth','enable'}, false);
            sM = g({'physics','relativity','shapiro','model','enable'}, false);
            if sT && sM
                sNote = 'Applied identically to truth and model: the residual is ZERO. Nothing about this effect reaches the filter.';
            elseif sT
                sNote = 'Injected with no correction: a real residual reaches the filter.';
            else
                sNote = 'Not injected.';
            end

            % --- light-time / Sagnac ---------------------------------------------------
            ltT = g({'physics','lightTime','enable'}, false);
            ltMode = gs({'physics','lightTime','mode'},'');
            sagT = g({'physics','sagnac','truth','enable'}, false);
            if ltT
                ltNote = sprintf('Iterative one-way light-time (%s); Sagnac subsumed by the geometric Earth rotation, so a separate Sagnac term would double-count.', ltMode);
            elseif sagT
                ltNote = 'First-order Sagnac only (no iterative light-time).';
            else
                ltNote = 'Neither light-time nor Sagnac applied.';
            end

            % --- relativistic clock ----------------------------------------------------
            rcT = g({'physics','relativity','clock','truth','enable'}, false);
            rcM = g({'physics','relativity','clock','model','enable'}, false);
            if rcT && ~rcM
                rcNote = 'Truth-side rate offset with no model; largely absorbed by the estimated clock drift.';
            elseif rcT && rcM
                rcNote = 'Applied to truth and model: residual is ZERO.';
            else
                rcNote = 'Not injected.';
            end

            % NOISE column. Troposphere and ionosphere sigmas are computed UNCONDITIONALLY in
            % ErrorChain and charged into R whatever the truth/model gates say -- that is the
            % channel a binary status hides. The others contribute no R term.
            rows = { ...
                'Troposphere',                        tT,   tM,   true,  tNote; ...
                'Ionosphere',                          iT,   iM,   true,  iNote; ...
                'Light-time / Sagnac',                 ltT || sagT, ltT || sagT, false, ltNote; ...
                'Shapiro delay (relativistic range)',  sT,   sM,   false, sNote; ...
                'Relativistic clock offset',           rcT,  rcM,  false, rcNote; ...
            };
        end

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

            % Empirical RTN accelerations (reduced-dynamic filtering). Three Gauss-Markov
            % acceleration states absorbing force-model error that no measurement-side
            % state can reach. Gate is enable && useInEKF, both default false.
            empAccOn2 = CE.getLogical_(cfg,{'estimator','empiricalAccel','enable'},false) && ...
                        CE.getLogical_(cfg,{'estimator','empiricalAccel','useInEKF'},false);
            empAccSt2   = empAccOn2;
            empAccNote2 = 'Disabled; force-model error is left unmodelled (biases the state, not P).';
            if empAccOn2
                tauEa = 1800; sigEa = 1e-7;
                try; tauEa = cfg.estimator.empiricalAccel.tau_s;         catch; end
                try; sigEa = cfg.estimator.empiricalAccel.sigma_ss_mps2; catch; end
                empAccNote2 = sprintf(['3 Gauss-Markov states in the RTN frame, ' ...
                    'tau = %g s, steady-state sigma = %.3g m/s^2.'], tauEa, sigEa);
            end
            slipNote2   = '';
            if carSlip2 && arcSep2; slipNote2 = 'model-step-compensated residual jump; arc-separated float ambiguities.'; end
            prodCovSt2  = prodCovEn2 || sharedEn2;
            prodCovN2   = 'No product covariance applied to R.';
            if prodCovSt2; prodCovN2 = 'R-inflation from product age and drift uncertainty.'; end
            tClkNote2   = sprintf('mode: %s; gauge: %s.', revgnss.ReportLabel.humanize(clkMd2), revgnss.ReportLabel.humanize(gaugMd2));
            attNote2    = 'No attitude states.'; if attEn2; attNote2 = sprintf('parameterisation: %s', revgnss.ReportLabel.humanize(attParam2)); end
            diffAttN2   = ''; if diffAttEn2; diffAttN2 = 'calibrated differential ambiguity active.'; end

            % --- Atmosphere honesty ------------------------------------------------
            % SUPERSEDED -- DO NOT EXTEND. tropSt/ionoSt/shapSt/ltSt below are no longer
            % consumed by any table: gRows{3} now comes from atmosphereEffectRows_, which
            % reports the three independent channels (truth into z / model into h / noise into
            % R) instead of one status. Kept only because several LOCAL variables computed in
            % this block (dualNote2, zwdEKF2, ltMode2, ...) are still used by tables 1, 2 and 4.
            % If you are changing how an atmospheric effect is REPORTED, edit
            % atmosphereEffectRows_ -- editing here changes nothing.
            % A cfg.errors.*.enable=true does NOT mean a real error is injected. If the
            % model applies the same delay as the truth (matched), the residual is ZERO;
            % and the ionosphere is master-gated by cfg.ionosphere.mode (mode='off' means
            % no ionosphere at all, regardless of errors.ionosphere.enable). Report the
            % NET effect, not the raw flag. Status 'matched' = applied on both sides -> 0.
            tropTruthEn  = CE.getLogical_(cfg,{'errors','troposphere','truth','enable'},false);
            tropModelEn  = CE.getLogical_(cfg,{'errors','troposphere','model','enable'},false);
            tropBiasFrac = CE.getCfgNum_(cfg,{'errors','troposphere','model','biasFraction'},1);
            if ~tropTruthEn
                tropSt = false;     tropNote = 'Not applied (truth troposphere off).';
            elseif zwdEKF2
                tropSt = true;      tropNote = 'Truth troposphere injected; residual absorbed by the per-tower ZWD EKF state.';
            elseif tropModelEn && abs(tropBiasFrac - 1) < 1e-9
                tropSt = 'matched'; tropNote = 'Zero residual: model matches truth (biasFraction = 1); no error reaches the filter.';
            else
                tropSt = true;      tropNote = sprintf('Residual injected: model applies %.0f%% of the truth delay.', 100*tropBiasFrac);
            end
            % Ionosphere: derive from the LIVE gates, exactly as the troposphere block above
            % does. This row used to read cfg.ionosphere.mode, which is a legacy key with ZERO
            % physics consumers -- nothing in ErrorChain reads it and realisticAtmosphereConfig
            % never updates it, so it sits at its 'off' default forever. A run with the full
            % realistic ionosphere (tecGaussMarkov truth + diurnal TEC + stochastic + topside +
            % higher-order + scintillation, Klobuchar-corrected) was therefore reported as
            % "Disabled -- not applied", i.e. the report UNDER-claimed an active error source
            % and a reader would conclude the ionosphere had not been modelled at all.
            ionoTruthEn = CE.getLogical_(cfg,{'errors','ionosphere','truth','enable'},false);
            ionoModelEn = CE.getLogical_(cfg,{'errors','ionosphere','model','enable'},false);
            ionoCorr    = lower(CE.getCfgStr_(cfg,{'errors','ionosphere','model','correction'},'none'));
            ionoTruthMd = CE.getCfgStr_(cfg,{'errors','ionosphere','modelType'},'');
            ionoStateOn = strcmpi(CE.getCfgStr_(cfg,{'estimation','ionosphereMode'},'none'),'perTowerSlant');
            % IF rows only cancel the ionosphere if the FILTER actually uses them; enable
            % alone can leave them diagnostic while the L1 rows (still iono-bearing) drive
            % the update.
            ionoIfOn    = CE.getLogical_(cfg,{'measurements','code','ionosphereFreeRows','enable'},false) && ...
                          CE.getLogical_(cfg,{'measurements','code','ionosphereFreeRows','useInEkf'},false);
            ionoHighOrd = CE.getLogical_(cfg,{'errors','ionosphere','higherOrder','enable'},false);
            ionoMode2   = lower(CE.getCfgStr_(cfg,{'ionosphere','mode'},'off'));
            if ~ionoTruthEn
                % Backward compatibility: a config that only ever set the legacy key still
                % reports through the old switch rather than silently reading "off".
                switch ionoMode2
                    case 'truthonly';     ionoSt = true;      ionoNote = 'Residual injected: truth-only ionosphere (model does not correct).';
                    case 'model';         ionoSt = 'matched'; ionoNote = 'Zero residual: model corrects the truth ionosphere.';
                    case 'ionospherefree';ionoSt = 'matched'; ionoNote = 'Removed by the L1/L2 ionosphere-free combination.';
                    otherwise;            ionoSt = false;     ionoNote = 'Not applied (no truth ionosphere).';
                end
            elseif ionoIfOn
                % The IF combination cancels the FIRST-ORDER term only. ErrorChain's
                % higherOrderIono_ injects the second/third-order residual that survives it,
                % so with higherOrder on a real (cm-level) error still reaches the filter and
                % 'matched' would overstate the cancellation.
                if ionoHighOrd
                    ionoSt = true;
                    ionoNote = ['First order removed by the L1/L2 ionosphere-free combination; ' ...
                        'the second/third-order residual survives it and reaches the filter.'];
                else
                    ionoSt = 'matched';
                    ionoNote = 'Removed by the L1/L2 ionosphere-free combination (first order; higher order not modelled).';
                end
            elseif ionoStateOn
                ionoSt = true;      ionoNote = 'Truth ionosphere injected; residual absorbed by the per-tower slant EKF state.';
            elseif ionoModelEn && ~strcmpi(ionoCorr,'none')
                ionoSt = true;
                ionoNote = sprintf(['Residual injected: %s truth, corrected by the %s broadcast model. ' ...
                    'The correction APPROXIMATES the truth, so a real residual survives.'], ...
                    revgnss.ReportLabel.humanize(ionoTruthMd), ionoCorr);
            elseif ionoModelEn
                ionoSt = 'matched'; ionoNote = 'Zero residual: model corrects the truth ionosphere.';
            else
                ionoSt = true;      ionoNote = 'Residual injected: truth-only ionosphere (model does not correct).';
            end
            shapTruthEn = CE.getLogical_(cfg,{'physics','relativity','shapiro','truth','enable'},false);
            shapModelEn = CE.getLogical_(cfg,{'physics','relativity','shapiro','model','enable'},false);
            if ~shapTruthEn
                shapSt = false;     shapNote = '';
            elseif shapModelEn
                shapSt = 'matched'; shapNote = 'Zero residual: applied on both truth and model.';
            else
                shapSt = true;      shapNote = 'Residual injected: truth-only relativistic range delay.';
            end

            % ---- Five compact group tables (avoids single-table page overflow) ----
            gTitles = { ...
                'Core geometry and signals', ...
                'Clock and covariance', ...
                'Atmosphere and propagation', ...
                'Carrier, ambiguity and attitude', ...
                'Antenna, hardware and unsupported', ...
            };

            gRows = cell(5, 1);

            % STALE ROWS RE-POINTED. Each of these previously read a key with no physics
            % consumer, or was a hardcoded literal that read no config at all:
            %   'Ground segment geometry'   hardcoded true -> now reports the real tower count
            %   'Carrier phase enabled'     read measurements.carrierPhase.enable, which is only
            %                               a FALLBACK; the authoritative gate is carrierMode
            %                               (MeasurementModel.m:268-281), and masterConfig always
            %                               defines it, so the old key could never change anything
            carModeStr2 = CE.getCfgStr_(cfg, {'measurements','carrierMode'}, 'none');
            carRealOn2  = strcmpi(carModeStr2, 'ekfFloat');
            nTwrRow2    = CE.getCfgNum_(cfg, {'scenario','nTowers'}, 0);
            nRxRow2     = CE.getCfgNum_(cfg, {'scenario','nReceivers'}, 1);
            gRows{1} = { ...
                'Ground segment geometry',       nTwrRow2 > 0, sprintf('%d transmitting towers, %d receive antennas.', round(nTwrRow2), round(nRxRow2)); ...
                'L1+L2 dual-frequency signals',  isDual2, dualNote2; ...
                'Carrier phase in EKF',          carRealOn2, sprintf('Gate is measurements.carrierMode = ''%s'' (carrierPhase.enable is a fallback only).', carModeStr2); ...
                'Doppler in EKF',                dopEKF2, dopNote2; ...
            };

            gRows{2} = { ...
                'Receiver clock (spacecraft)',    true,   sprintf(['%s oscillator; ' ...
                    'h-coefficients from Winkel (2003) Table 2.1.'], ...
                    CE.getCfgStr_(cfg,{'asset','clockType'},'unknown')); ...
                'Tower clock product correction', prodSt,                                    prodNote; ...
                'Tower clock product covariance', prodCovSt2,                                prodCovN2; ...
                'Joint tower clock EKF',          strcmp(clkMd2,'includeTowerClocksInEKF'),  tClkNote2; ...
                'ZWD / troposphere EKF state',    zwdSt2,                                    zwdNote2; ...
                'Empirical RTN accelerations',    empAccSt2,                                 empAccNote2; ...
                ... % was hardcoded 'guarded' with "no dedicated EKF state in v1" -- FALSE:
                ... % hardware.txCodeBias.useInEKF demonstrably appends one state per tower.
                'Per-tower TX code bias EKF', CE.getLogical_(cfg,{'hardware','txCodeBias','useInEKF'},false), ...
                    sprintf('%d estimated tower code-bias states.', ...
                        round(CE.getLogical_(cfg,{'hardware','txCodeBias','useInEKF'},false) * nTwrRow2)); ...
            };

            % ---- Table 3 uses the THREE-CHANNEL schema -------------------------------
            % An error source enters the filter through up to three INDEPENDENT channels, and
            % a single Enabled/Disabled cell cannot describe any of them honestly:
            %   TRUTH  the effect perturbs the measurement z
            %   MODEL  the filter subtracts a correction in h
            %   NOISE  the effect inflates the measurement covariance R
            % This replaces the old 'Matched' status. 'Matched' asserted "applied to both sides
            % so the residual is zero", which reads as though the effect is active when it is
            % arithmetically a no-op -- and for the ionosphere it was measured still producing
            % 1.3-3.0 m of residual, i.e. the label was simply false. Truth+Model both green with
            % an explicit note carries the same information without the false implication.
            % The NOISE column is what a binary status hides completely: ErrorChain charges the
            % troposphere and ionosphere sigmas into R UNCONDITIONALLY -- not gated on
            % truth.enable, model.enable or stochastic.enable -- so with the atmosphere fully
            % "Disabled" the ionosphere still supplies most of the measurement variance.
            gRows{3} = revgnss.ClockExactReportBuilder.atmosphereEffectRows_(cfg);

            gRows{4} = { ...
                'Carrier L1 float rows in EKF',   carEKF2 && carEn2,    carL1Note; ...
                'Carrier L2 float rows in EKF',   carL2St,              carL2Note; ...
                'Carrier slip guards + arc sep',   carSlip2 && arcSep2,  slipNote2; ...
                ... % Both IF rows previously read *.ionosphereFreeRows.useInEkf. For CODE that
                ... % key is DEAD (codeMode is the real gate); for CARRIER the real gate is
                ... % CarrierIonoFreeRowBuilder.combineStatus. They disagree in the default config.
                'Code IF rows in EKF',    strcmpi(CE.getCfgStr_(cfg,{'measurements','codeMode'},''),'ionosphereFree'), ...
                    sprintf('Gate is measurements.codeMode = ''%s''.', CE.getCfgStr_(cfg,{'measurements','codeMode'},'unset')); ...
                'Carrier IF rows in EKF', CE.carrierIfActive_(cfg), ...
                    'Gate is CarrierIonoFreeRowBuilder.combineStatus (enable AND useInEkf AND nCarrierSignals>1); the signal-count clause is now in the code, not just this note.'; ...
                'Raw carrier integer fixing',     intFixSt,             intFixNote; ...
                'Baseline attitude AR',           baseArSt,             baseArNote; ...
                'Attitude EKF (spacecraft)',       attEn2,               attNote2; ...
                'Diff. carrier att. calibration',  diffAttEn2,           diffAttN2; ...
            };

            % PCV: the row used to read effects.antennaPCV.truth.enable, but
            % RangeCorrections gates on effects.antenna.pcvModel and returns zero for 'none',
            % so the flag could read Enabled while the correction was identically zero.
            pcvModel2 = CE.getCfgStr_(cfg, {'effects','antenna','pcvModel'}, 'none');
            pcvOn2    = CE.getLogical_(cfg,{'effects','antennaPCV','truth','enable'},false) && ...
                        ~strcmpi(pcvModel2, 'none');
            % Multipath: the coloured Gauss-Markov path is gated on coloredGM.enable, not on
            % the truth flag alone.
            mpTruth2 = CE.getLogical_(cfg,{'errors','multipath','truth','enable'},false);
            mpGM2    = CE.getLogical_(cfg,{'errors','multipath','coloredGM','enable'},false);
            % LAMBDA: 'Not impl.' is stale on this branch -- the engine exists and is gated.
            lamOn2   = CE.getLogical_(cfg,{'estimator','lambda','enable'},false);
            lamPath2 = CE.getCfgStr_(cfg,{'estimator','lambda','toolboxPath'},'');
            if lamOn2 && ~isempty(lamPath2)
                lamSt2 = true;
                lamNote2 = 'External TU Delft LAMBDA engine active (reports a bootstrapped success rate; a fix below the gate is refused).';
            elseif lamOn2
                lamSt2 = 'guarded'; lamNote2 = 'Enabled but estimator.lambda.toolboxPath is unset, so the engine cannot run.';
            else
                lamSt2 = false; lamNote2 = 'Available on this branch but switched off.';
            end
            gRows{5} = { ...
                'Antenna PCO (truth)',       CE.getLogical_(cfg,{'effects','antennaPCO','truth','enable'},false),   ''; ...
                'Antenna PCV (truth)',       pcvOn2, sprintf('Gate is effects.antenna.pcvModel = ''%s''; ''none'' yields an identically zero correction whatever the truth flag says.', pcvModel2); ...
                'Hardware delay (truth)',    CE.getLogical_(cfg,{'errors','hardwareDelay','truth','enable'},false), ''; ...
                'Multipath (truth)',         mpTruth2 && mpGM2, CE.yesNo_(mpGM2, 'Time-correlated (coloured Gauss-Markov) code multipath.', 'Truth flag set but coloredGM.enable is off, so no multipath is generated.'); ...
                'LAMBDA / MLAMBDA',          lamSt2, lamNote2; ...
                'Carrier IF integer fixing', 'nimpl', 'Explicitly unsupported; the IF ambiguity is not an integer.'; ...
                'ANTEX / SP3 / CLK parsers', 'nimpl', 'Synthetic constants only; no file-based corrections.'; ...
                'PPP-grade processing',     'nimpl', 'Not implemented.'; ...
            };

            for gi = 1:5
                fprintf(fid, '\\begingroup\n\\small\n');
                fprintf(fid, '\\setlength{\\tabcolsep}{3pt}\n');
                fprintf(fid, '\\renewcommand{\\arraystretch}{0.92}\n');
                fprintf(fid, '\\begin{center}\n');
                fprintf(fid, '{\\bfseries\\small %s}\\\\[2pt]\n', gTitles{gi});
                rws = gRows{gi};
                isEffectTable = (size(rws, 2) == 5);   % {name, truth, model, noise, note}
                if isEffectTable
                    fprintf(fid, ['\\begin{tabular}{>{\\raggedright\\arraybackslash}p{0.24\\textwidth}' ...
                                  ' c c c' ...
                                  ' >{\\raggedright\\arraybackslash}p{0.44\\textwidth}}\n']);
                    fprintf(fid, '\\toprule\n');
                    fprintf(fid, ['\\textbf{Error source} & \\textbf{Truth} & \\textbf{Model} & ' ...
                                  '\\textbf{Noise} & \\textbf{What actually reaches the filter}\\\\\n']);
                    fprintf(fid, ['& {\\tiny in $z$} & {\\tiny in $h$} & {\\tiny in $R$} & \\\\\n']);
                else
                    fprintf(fid, ['\\begin{tabular}{>{\\raggedright\\arraybackslash}p{0.34\\textwidth}' ...
                                  ' >{\\raggedright\\arraybackslash}p{0.18\\textwidth}' ...
                                  ' >{\\raggedright\\arraybackslash}p{0.40\\textwidth}}\n']);
                    fprintf(fid, '\\toprule\n');
                    fprintf(fid, '\\textbf{Component} & \\textbf{Status} & \\textbf{Note}\\\\\n');
                end
                fprintf(fid, '\\midrule\n');
                for k = 1:size(rws, 1)
                    comp = esc(rws{k,1});
                    if isEffectTable
                        % Each channel is genuinely binary -- that is the point of splitting them.
                        tick = @(b) revgnss.ClockExactReportBuilder.channelCell_(b);
                        fprintf(fid, '%s & %s & %s & %s & %s\\\\\n', comp, ...
                            tick(rws{k,2}), tick(rws{k,3}), tick(rws{k,4}), esc(rws{k,5}));
                        fprintf(fid, '\\midrule\n');
                        continue
                    end
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
                        if isempty(act); act = 'n/a'; end
                    end
                    fprintf(fid, '%s & %s & %s\\\\\n', comp, stTex, esc(act));
                    fprintf(fid, '\\midrule\n');
                end
                fprintf(fid, '\\bottomrule\n\\end{tabular}\n\\end{center}\n');
                fprintf(fid, '\\endgroup\n\\vspace{4pt}\n');

                % Per-asset scope note under the atmosphere/propagation table (swarm runs).
                % The rows above describe the CHIEF's tower links; secondaries only see these
                % effects when the per-asset guards are enabled -- make that explicit.
                if gi == 3
                    nSA_ap = CE.getCfgNum_(cfg, {'scenario','nSpaceAssets'}, 1);
                    if nSA_ap > 1
                        jointMode_ = strcmpi(CE.getCfgStr_(cfg, ...
                            {'multiAsset','mode'},'fast'),'joint');
                        if jointMode_
                            fprintf(fid, ['{\\footnotesize\\itshape Multi-asset scope (%d spacecraft): ' ...
                                'each jointly estimated spacecraft uses its own ground-link ' ...
                                'measurement model and error-chain realization. The configured ' ...
                                'atmosphere therefore applies to every spacecraft--tower uplink. ' ...
                                'Inter-satellite links carry no neutral-atmosphere or ionosphere term.}\\\\[4pt]\n'], ...
                                round(nSA_ap));
                        else
                            guardA_ = CE.getLogical_(cfg, {'multiAsset','towerSecondary','atmosphere','enable'}, false);
                            dynB_   = CE.getLogical_(cfg, {'multiAsset','injectTruthSideDynamics'}, false);
                            fprintf(fid, ['{\\footnotesize\\itshape Multi-asset scope (%d spacecraft): the effects above are ' ...
                                'applied to the chief''s tower links. Each secondary satellite receives a divergent uplink ' ...
                                'atmosphere only when \\texttt{multiAsset.towerSecondary.atmosphere} is enabled (this run: %s), ' ...
                                'and truth-side per-satellite dynamics only when \\texttt{injectTruthSideDynamics} is enabled ' ...
                                '(this run: %s). Inter-satellite links carry no atmosphere.}\\\\[4pt]\n'], ...
                                round(nSA_ap), CE.yesNo_(guardA_,'enabled','off'), CE.yesNo_(dynB_,'enabled','off'));
                        end
                    end
                end
            end
        end

        % ================================================================
        % SECTION 2 — STATE ESTIMATION VALIDATION
        % ================================================================

        % writeStateEstimation_ extracted to +revgnss/+report/stateEstimation.m.

        % ================================================================
        % SECTION 3 — MEASUREMENT AND GEOMETRY VALIDATION
        % ================================================================

        % writeMeasurementValidation_ extracted to +revgnss/+report/measurementValidation.m.

        % ================================================================
        % SECTION 4 — PER-RECEIVER MEASUREMENT DIAGNOSTICS
        % ================================================================

        % Per-receiver measurement diagnostics are not generated in this report configuration.

        % ================================================================
        % SECTION 5 — OSCILLATOR STABILITY VALIDATION
        % ================================================================

        % writeOscillatorValidation_ extracted to +revgnss/+report/oscillatorValidation.m.

        % ================================================================
        % SECTION 6 — DISABLED COMPONENTS
        % ================================================================

        % ================================================================
        % SECTION 6B — CLOCK OBSERVABILITY AND GAUGE VALIDATION
        % ================================================================

        % writeClockObservability_ extracted to +revgnss/+report/clockObservability.m.

        % ================================================================
        % SECTION 7 — TRANSMITTER CODE HARDWARE-DELAY STATES
        % ================================================================

        % writeTxCodeBias_ extracted to +revgnss/+report/txCodeBias.m.



        % ================================================================
        % SECTION 7 — NUMERICAL SUMMARY
        % ================================================================

        % writeNumericalSummary_ extracted to +revgnss/+report/numericalSummary.m.

        % ================================================================
        % ACTIVE PHYSICS MODEL CONFIGURATION
        % ================================================================
        % writeTropZwdArchitecture_ extracted to +revgnss/+report/tropZwdArchitecture.m.

        % writeActivePhysicsConfig_ extracted to +revgnss/+report/activePhysicsConfig.m.

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
        % FINAL SCIENTIFIC CLOSURE
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
            % Single-asset one-way topology rows
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
        % ATTITUDE, CLOCK, AND DYNAMICS REALISM CLOSURE
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
                '(C) twoBodyRk4 truth propagation and twoBody EKF dynamics use the same force family and replace static-ECEF truth.}\n\n']);

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
            fprintf(fid, 'EKF dynamics & \\texttt{%s} (same force family as truth propagator)\\\\\n', ...
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

        % ================================================================
        % REPORT-TEXT STATISTICS
        %   Numbers quoted in a plot's description must come from the SAME series the
        %   plot draws, so these read the store directly rather than re-deriving from
        %   a summary struct that may have been built under different gating.
        % ================================================================

        function idx = tailIndex_(t, windowSec)
            % tailIndex_  First sample of the trailing windowSec-second window.
            idx = 1;
            if isempty(t) || ~isfinite(windowSec) || windowSec <= 0; return; end
            j = find(t >= t(end) - windowSec, 1, 'first');
            if ~isempty(j); idx = j; end
        end

        function s = fmtRms_(v, unit, fmt)
            % fmtRms_  RMS of the finite entries of v, or 'n/a'.
            if nargin < 3 || isempty(fmt); fmt = '%.3g'; end
            s = 'n/a';
            v = v(:); v = v(isfinite(v));
            if isempty(v); return; end
            s = sprintf([fmt ' %s'], sqrt(mean(v.^2)), unit);
        end

        function [txt, ok] = racTailRms_(diag, t, windowSec)
            % racTailRms_  "radial A, along-track B, cross-track C" RMS over the trailing
            %   window, in the RAC frame the zoom figure plots. ok=false when the RAC
            %   basis is unavailable, in which case txt is the 3-D norm instead.
            txt = ''; ok = false;
            try
                ev = diag.getPositionErrorVecs();
                n  = numel(t);
                if isempty(ev) || size(ev,2) ~= n; return; end
                i0 = revgnss.ClockExactReportBuilder.tailIndex_(t, windowSec);
                rTr = diag.getTruthPositionVecs(); vTr = diag.getTruthVelocityVecs();
                if ~isempty(rTr) && ~isempty(vTr) && size(rTr,2) >= n && size(vTr,2) >= n
                    rac = revgnss.OrbitFrame.ecefToRacGeo(ev, rTr(:,1:n), vTr(:,1:n));
                    if any(isfinite(rac(:)))
                        CE_ = revgnss.ClockExactReportBuilder;
                        txt = sprintf('radial %s, along-track %s, cross-track %s', ...
                            CE_.fmtRms_(rac(1,i0:n),'m'), ...
                            CE_.fmtRms_(rac(2,i0:n),'m'), ...
                            CE_.fmtRms_(rac(3,i0:n),'m'));
                        ok = true; return;
                    end
                end
                nrm = sqrt(sum(ev(:,i0:n).^2,1));
                txt = sprintf('3-D norm %s (RAC basis unavailable)', ...
                    revgnss.ClockExactReportBuilder.fmtRms_(nrm,'m'));
            catch
            end
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

        % ----------------------------------------------------------------
        % NIS dof / chi-squared band
        % ----------------------------------------------------------------

        function writeNisDofRows_(fid, summary, tableWidth)
            % writeNisDofRows_  Mean NIS with its dof, normalised ratio, and chi-squared band.
            %
            % NIS is the RAW statistic, whose expectation is M_k -- the number of
            % measurement rows folded into epoch k, 105 for the four-antenna baseline --
            % and NOT 1. A mean printed on its own invites the reader to compare it
            % against 1 and read a nominal filter as two orders of magnitude wrong, so
            % the dof it must be divided by is printed beside it, with the ratio and the
            % two-sided chi-squared acceptance band. Emits nothing when the run stored no
            % NIS dof (federated-swarm runs have no single-filter NIS at all), so those
            % reports stay byte-identical.
            %
            % tableWidth: text width of the enclosing two-column table, for the footnote
            %   \multicolumn spanning both columns.
            CE      = revgnss.ClockExactReportBuilder;
            dofAll  = CE.safeField_(summary, 'expectedNIS', NaN);
            dofPhys = CE.safeField_(summary, 'physicalDof', NaN);
            nisAll  = CE.safeField_(summary, 'meanNIS',     NaN);
            nisPhys = CE.safeField_(summary, 'physicalNIS', NaN);
            if ~CE.isPosFinite_(dofAll) && ~CE.isPosFinite_(dofPhys); return; end

            % NIS itself may legitimately be 0 (a fully deterministic run has zero
            % innovation), so the value and ratio rows accept any finite number; only
            % the dof, which divides, must be strictly positive.
            CE.writeQuantRow_(fid, 'Mean NIS (raw, all rows)', ...
                CE.nisPairStr_(nisAll, nisPhys, @(v) sprintf('%.2f', v)));
            CE.writeQuantRow_(fid, 'NIS dof (EKF rows / epoch)', ...
                CE.nisPairStr_(CE.posOrNan_(dofAll), CE.posOrNan_(dofPhys), ...
                               @(v) CE.dofStr_(v)));
            CE.writeQuantRow_(fid, 'Mean NIS / dof (expected 1.00)', ...
                CE.nisPairStr_(CE.ratio_(nisAll, dofAll), CE.ratio_(nisPhys, dofPhys), ...
                               @(v) sprintf('%.3f', v)));

            % Band on the physical dof when the accounting separated the gauge rows:
            % physicalNIS is the chi-squared diagnostic, meanNIS the augmented alias.
            dofBand = dofPhys;
            if ~CE.isPosFinite_(dofBand); dofBand = dofAll; end
            [rlo, rhi] = revgnss.ChiSquareConsistency.bounds(dofBand, 0.95);
            CE.writeQuantRow_(fid, ...
                sprintf('95\\%% $\\chi^2$ band, dof $=%s$', CE.dofStr_(dofBand)), ...
                sprintf('$[%.1f,\\;%.1f]$ raw', rlo, rhi));
            % writeQuantRow_ passes the label through %s, so it must already be literal
            % LaTeX -- a doubled backslash here would emit a row break, not \hspace.
            CE.writeQuantRow_(fid, '\hspace{1em}same band per dof', ...
                sprintf('$[%.3f,\\;%.3f]$', rlo/dofBand, rhi/dofBand));
            fprintf(fid, ['\\multicolumn{2}{p{%.2f\\textwidth}}{\\footnotesize ' ...
                'The $\\chi^2$ band is the two-sided 95\\%% interval for a ' ...
                '\\textbf{single} epoch. The means above are averaged over epochs whose ' ...
                'NIS is autocorrelated in this simulation, so the band bounds the ' ...
                'per-epoch scatter and is not a hypothesis test on the mean.}\\\\\n'], ...
                tableWidth);
        end

        function s = nisPairStr_(allVal, physVal, fmt)
            % nisPairStr_  "<all> (all rows), <phys> (physical)", collapsed when equal.
            %   Gauge rows are absent in most runs, which makes the two statistics
            %   identical; printing one number then reads clearer than printing it twice.
            hasAll  = isnumeric(allVal)  && isscalar(allVal)  && isfinite(allVal);
            hasPhys = isnumeric(physVal) && isscalar(physVal) && isfinite(physVal);
            if hasAll && hasPhys
                if abs(allVal - physVal) <= 1e-9 * max(1, abs(allVal))
                    s = fmt(allVal);
                else
                    s = sprintf('%s (all rows), %s (physical)', fmt(allVal), fmt(physVal));
                end
            elseif hasAll
                s = sprintf('%s (all rows)', fmt(allVal));
            elseif hasPhys
                s = sprintf('%s (physical)', fmt(physVal));
            else
                s = 'not available';
            end
        end

        function s = dofStr_(v)
            % dofStr_  dof as an integer when the row count is constant, else a mean.
            if abs(v - round(v)) < 1e-9
                s = sprintf('%d', round(v));
            else
                s = sprintf('%.1f (mean)', v);
            end
        end

        function r = ratio_(num, den)
            r = NaN;
            if revgnss.ClockExactReportBuilder.isPosFinite_(den) && isfinite(num)
                r = num / den;
            end
        end

        function v = posOrNan_(v)
            % posOrNan_  Pass a strictly positive finite scalar through, else NaN.
            if ~revgnss.ClockExactReportBuilder.isPosFinite_(v); v = NaN; end
        end

        function tf = isPosFinite_(v)
            tf = isnumeric(v) && isscalar(v) && isfinite(v) && v > 0;
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
            cmdFmt ='"%s" -interaction=nonstopmode -output-directory "%s" "%s" > /dev/null 2>&1';
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
                s = '[n/a, n/a, n/a]';
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
