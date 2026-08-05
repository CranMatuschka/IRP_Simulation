classdef FederatedSwarmReport
    % FederatedSwarmReport  Unified PDF report for a federated swarm run.
    %
    % Renders ONE swarm report from the federated results (N independent single-asset EKFs) + the
    % relative layer + the symmetric per-satellite summary: a per-satellite absolute table, the
    % relative-layer (shape / relative-clock) table, a per-satellite absolute-error plot and the
    % ISL-sharpens-shape plot, plus the honest interpretation. Compiled with pdflatex.
    %
    %   ce = revgnss.FederatedSwarmReport.build(cfg, results, rel, summ, folder, stem)
    %       ce.success  ce.pdfPath  ce.texPath
    % Consumes ReportRunner.runFederatedEstimation-style results + SwarmRelativeSolver + FederatedSwarmSummary output.

    methods (Static)
        function [absName, relName, kabschName, relRefName, relSwarmName, relRefSwarmName] = ...
                renderFigures(results, rel, folder, absStem, relStem, kabschStem, doKabsch, refAsset)
            % renderFigures  Render swarm diagnostic figures into `folder`.
            %
            % MANDATORY SET for any multi-asset run: the relative layer and the
            % relative-to-reference view are each rendered TWICE -- once in the EARTH frame (the
            % turn included, what a ground beamformer experiences) and once in the SWARM frame
            % (the turn removed, the formation's own geometry, which is what the ISL governs).
            % Reporting only one of the two has repeatedly caused the same confusion: the swarm
            % frame alone claims sub-decimetre formation flying while the beam is incoherent, and
            % the Earth frame alone hides that the crosslink is doing its job perfectly.
            if nargin < 6 || isempty(kabschStem); kabschStem = [relStem '_kabsch']; end
            if nargin < 7 || isempty(doKabsch); doKabsch = false; end
            if nargin < 8 || isempty(refAsset); refAsset = 1; end
            absName = ''; relName = ''; kabschName = ''; relRefName = '';
            relSwarmName = ''; relRefSwarmName = '';
            if ~isfolder(folder); mkdir(folder); end
            N = 0; if isstruct(results) && isfield(results,'N'); N = results.N; end
            if N < 1; return; end
            t = results.asset{1}.history.time_s(:).' / 3600;   % hours
            try
                f1 = figure('visible','off','Position',[0 0 900 480]); hold on; cmap = lines(max(N,1));
                for i = 1:N
                    sm = results.asset{i}.stateMap;
                    e = vecnorm(results.asset{i}.history.x(sm.r_idx,:) - results.asset{i}.truthTraj, 2, 1);
                    plot(t, e, 'Color', cmap(i,:), 'LineWidth', 1.0, 'DisplayName', sprintf('asset %d', i));
                end
                grid on; xlabel('time [h]'); ylabel('absolute position error [m]');
                title('Per-satellite absolute position error (each independent EKF)');
                legend('Location','best'); set(gca,'FontSize',11);
                % Rescale into readable units so no axis carries a x10^-n multiplier.
                revgnss.ClockExactReportBuilder.normalizeAxisUnits_(f1); 
                exportgraphics(f1, fullfile(folder, [absStem '.png']), 'Resolution', 130); close(f1);
                absName = [absStem '.png'];
            catch; end
            % --- relative layer, EARTH frame then SWARM frame ---------------------------------
            try
                f2 = revgnss.FederatedSwarmReport.plotRelativeLayer_(t, rel, results, 'earth');
                % Rescale into readable units so no axis carries a x10^-n multiplier.
                revgnss.ClockExactReportBuilder.normalizeAxisUnits_(f2);
                exportgraphics(f2, fullfile(folder, [relStem '.png']), 'Resolution', 130); close(f2);
                relName = [relStem '.png'];
            catch; end
            try
                f2s = revgnss.FederatedSwarmReport.plotRelativeLayer_(t, rel, results, 'swarm');
                revgnss.ClockExactReportBuilder.normalizeAxisUnits_(f2s);
                exportgraphics(f2s, fullfile(folder, [relStem '_swarmframe.png']), 'Resolution', 130);
                close(f2s);
                relSwarmName = [relStem '_swarmframe.png'];
            catch; end
            % --- relative-to-reference, EARTH frame then SWARM frame -------------------------
            try
                f4 = revgnss.FederatedSwarmReport.plotRelativeToReference_(t, rel, results, refAsset, 'earth');
                if isgraphics(f4)
                    exportgraphics(f4, fullfile(folder, [relStem '_toref.png']), 'Resolution', 130);
                    close(f4);
                    relRefName = [relStem '_toref.png'];
                end
            catch; end
            try
                f4s = revgnss.FederatedSwarmReport.plotRelativeToReference_(t, rel, results, refAsset, 'swarm');
                if isgraphics(f4s)
                    exportgraphics(f4s, fullfile(folder, [relStem '_toref_swarmframe.png']), 'Resolution', 130);
                    close(f4s);
                    relRefSwarmName = [relStem '_toref_swarmframe.png'];
                end
            catch; end
            if doKabsch
                try
                    f3 = revgnss.FederatedSwarmReport.plotKabschAlignment_(results, rel);
                    if isgraphics(f3)
                        % Rescale into readable units so no axis carries a x10^-n multiplier.
                        revgnss.ClockExactReportBuilder.normalizeAxisUnits_(f3); 
                        exportgraphics(f3, fullfile(folder, [kabschStem '.png']), 'Resolution', 160);
                        close(f3);
                        kabschName = [kabschStem '.png'];
                    end
                catch; end
            end
        end

        function [absName, kabschName] = renderIndependentFleetDiagnostics(results, folder, absStem, kabschStem, doKabsch)
            % renderIndependentFleetDiagnostics  Absolute and geometric diagnostics only.
            if nargin < 5 || isempty(doKabsch); doKabsch = false; end
            absName = '';
            kabschName = '';
            if ~isfolder(folder); mkdir(folder); end
            N = 0;
            if isstruct(results) && isfield(results,'N'); N = results.N; end
            if N < 1; return; end
            t = results.asset{1}.history.time_s(:).' / 3600;
            f = [];
            try
                f = figure('visible','off','Position',[0 0 900 480]);
                hold on;
                cmap = lines(max(N,1));
                for i = 1:N
                    sm = results.asset{i}.stateMap;
                    e = vecnorm(results.asset{i}.history.x(sm.r_idx,:) - ...
                        results.asset{i}.truthTraj,2,1);
                    plot(t,e,'Color',cmap(i,:),'LineWidth',1.0, ...
                        'DisplayName',sprintf('asset %d',i));
                end
                grid on;
                xlabel('time [h]');
                ylabel('absolute position error [m]');
                title('Per-satellite absolute position error (independent local EKFs)');
                legend('Location','best');
                set(gca,'FontSize',11);
                revgnss.ClockExactReportBuilder.normalizeAxisUnits_(f);
                exportgraphics(f,fullfile(folder,[absStem '.png']),'Resolution',130);
                close(f);
                f = [];
                absName = [absStem '.png'];
            catch
                if ~isempty(f) && isgraphics(f); close(f); end
            end
            if doKabsch
                f = [];
                try
                    % No relative layer on the independent-fleet path (it has none), so the
                    % Kabsch figure falls back to the raw per-asset positions by design.
                    f = revgnss.FederatedSwarmReport.plotKabschAlignment_(results, []);
                    if isgraphics(f)
                        revgnss.ClockExactReportBuilder.normalizeAxisUnits_(f);
                        exportgraphics(f,fullfile(folder,[kabschStem '.png']),'Resolution',160);
                        close(f);
                        f = [];
                        kabschName = [kabschStem '.png'];
                    end
                catch
                    if ~isempty(f) && isgraphics(f); close(f); end
                end
            end
        end

        function ce = build(cfg, results, rel, summ, folder, stem)
            ce = struct('success', false, 'pdfPath', '', 'texPath', '');
            C = revgnss.Constants.SPEED_OF_LIGHT_MPS;
            if ~isfolder(folder); mkdir(folder); end
            N = results.N;
            G = revgnss.FederatedSwarmReport.num_(cfg, {'scenario','nTowers'}, 0);
            R = revgnss.FederatedSwarmReport.num_(cfg, {'scenario','nReceivers'}, 0);
            DUR = revgnss.FederatedSwarmReport.num_(cfg, {'simulation','duration_s'}, 0);
            dt  = revgnss.FederatedSwarmReport.num_(cfg, {'simulation','dt_s'}, 1);

            % ---- Figures -----------------------------------------------------
            t = results.asset{1}.history.time_s(:).' / 3600;   % hours
            png1 = fullfile(folder, [stem '_swarm_abs_err.png']);
            png2 = fullfile(folder, [stem '_swarm_rel_err.png']);
            png3 = fullfile(folder, [stem '_swarm_kabsch_alignment.png']);
            doKabsch = revgnss.FederatedSwarmReport.bool_(cfg, {'report','kabschAlignmentPlot','enable'}, false);
            try
                f1 = figure('visible','off','Position',[0 0 900 480]); hold on; cmap = lines(max(N,1));
                for i = 1:N
                    sm = results.asset{i}.stateMap;
                    e = vecnorm(results.asset{i}.history.x(sm.r_idx,:) - results.asset{i}.truthTraj, 2, 1);
                    plot(t, e, 'Color', cmap(i,:), 'LineWidth', 1.0, 'DisplayName', sprintf('asset %d', i));
                end
                grid on; xlabel('time [h]'); ylabel('absolute position error [m]');
                title('Per-satellite absolute position error (each independent EKF)');
                legend('Location','best'); set(gca,'FontSize',11);
                % Rescale into readable units so no axis carries a x10^-n multiplier.
                revgnss.ClockExactReportBuilder.normalizeAxisUnits_(f1); 
                exportgraphics(f1, png1, 'Resolution', 130); close(f1);
            catch; end
            try
                f2 = revgnss.FederatedSwarmReport.plotRelativeLayer_(t, rel, results);
                % Rescale into readable units so no axis carries a x10^-n multiplier.
                revgnss.ClockExactReportBuilder.normalizeAxisUnits_(f2); 
                exportgraphics(f2, png2, 'Resolution', 130); close(f2);
            catch; end
            if doKabsch
                try
                    f3 = revgnss.FederatedSwarmReport.plotKabschAlignment_(results, rel);
                    if isgraphics(f3)
                        % Rescale into readable units so no axis carries a x10^-n multiplier.
                        revgnss.ClockExactReportBuilder.normalizeAxisUnits_(f3); 
                        exportgraphics(f3, png3, 'Resolution', 160); close(f3);
                    end
                catch; end
            end

            % ---- LaTeX -------------------------------------------------------
            texPath = fullfile(folder, [stem '.tex']);
            fid = fopen(texPath, 'w');
            if fid < 0; ce.texPath = texPath; return; end
            fp = @(varargin) fprintf(fid, varargin{:});
            fp('\\documentclass[11pt]{article}\n\\usepackage{graphicx,booktabs,geometry,lmodern}\n\\geometry{margin=2.3cm}\n');
            fp('\\title{Federated Swarm Report --- G%dS%dR%d, %g\\,s}\n', G, N, R, DUR);
            fp('\\author{oo\\_v1 reverse-GNSS (federated N-EKF swarm)}\n\\date{\\today}\n\\begin{document}\\maketitle\n');
            fp('\\section*{Configuration}\n\\begin{itemize}\n');
            fp('\\item %d ground towers, %d space assets, %d receivers/asset; arc %g\\,s (%d epochs, dt=%g\\,s).\n', ...
                G, N, R, DUR, numel(t), dt);
            fp('\\item Estimator: %d \\emph{independent} single-asset EKFs (no chief, no shared covariance); reference = asset %d.\n', N, summ.refAsset);
            fp('\\item Relative layer: two-way ISL (formation shape) + sat--sat TWSTFT (relative clocks), read-only.\n\\end{itemize}\n');
            fp('\\section*{Per-satellite absolute estimate (each from its own EKF)}\n');
            fp('\\begin{center}\\begin{tabular}{crrrrr}\\toprule\n');
            fp('asset & absErr [m] & absSig [m] & err/$\\sigma$ & clkErr [ns] & relPos [m] \\\\ \\midrule\n');
            for i = 1:numel(summ.perAsset)
                p = summ.perAsset(i);
                fp('%d & %.3f & %.3f & %.2f & %.3f & %.3f \\\\\n', p.asset, p.absErr_m, p.absSigma_m, p.absRatio, p.clkErr_m/C*1e9, p.relPosErr_m);
            end
            fp('\\bottomrule\\end{tabular}\\end{center}\n');
            fp('\\section*{Relative layer (ISL / TWSTFT)}\n\\begin{center}\\begin{tabular}{lr}\\toprule\n');
            fp('formation baseline error (raw per-asset estimates) & %.3f m \\\\\n', rel.baselineErrRaw_m);
            shapeOn = isfield(rel,'shapeGateOn') && logical(rel.shapeGateOn);
            if shapeOn && isfinite(rel.baselineErrSolved_m)
                fp('formation baseline error (solved) & %.4f m (%.2f cm) \\\\\n', rel.baselineErrSolved_m, rel.baselineErrSolved_m*100);
            else
                fp('formation baseline error (solved) & -- (two-way ISL shape disabled) \\\\\n');
            end
            if shapeOn && isfinite(rel.shapeErrSolved_m)
                fp('best-fit-rigid shape error (solved) & %.4f m (%.2f cm) \\\\\n', rel.shapeErrSolved_m, rel.shapeErrSolved_m*100);
            else
                fp('best-fit-rigid shape error (solved) & -- (two-way ISL shape disabled) \\\\\n');
            end
            if isfield(rel,'relClockGateOn') && rel.relClockGateOn
                fp('relative clock error (TWSTFT) & %.5f m (%.4f ns) \\\\\n', rel.relClockErrSolved_m, rel.relClockErrSolved_m/C*1e9);
            else
                fp('relative clock (TWSTFT) & off \\\\\n');
            end
            fp('weakly observable & %d \\\\\n\\bottomrule\\end{tabular}\\end{center}\n', rel.weaklyObservable);
            if isfile(png1); fp('\\begin{figure}[h]\\centering\\includegraphics[width=\\linewidth]{%s}\\end{figure}\n', [stem '_swarm_abs_err.png']); end
            if isfile(png2); fp('\\begin{figure}[h]\\centering\\includegraphics[width=\\linewidth]{%s}\\end{figure}\n', [stem '_swarm_rel_err.png']); end
            if isfile(png3); fp('\\begin{figure}[h]\\centering\\includegraphics[width=0.85\\linewidth]{%s}\\end{figure}\n', [stem '_swarm_kabsch_alignment.png']); end
            fp('\\section*{Interpretation}\n');
            fp('Each satellite estimates its \\emph{own absolute} state from the ground towers only; that ');
            fp('absolute is wall-limited (radial--clock common mode, err/$\\sigma$ near 1--3). The ');
            fp('relative layer is fused with \\emph{no shared covariance} (design decision D1), so it cannot ');
            if shapeOn
                fp('re-open any per-asset filter, yet it sharpens the observable formation shape and relative clocks.\n\\end{document}\n');
            else
                fp('re-open any per-asset filter. The two-way ISL shape layer is disabled, so solved shape metrics are not reported.\n\\end{document}\n');
            end
            fclose(fid);
            ce.texPath = texPath;

            % ---- Compile -----------------------------------------------------
            compileTex = 'require';
            try; compileTex = cfg.report.compileTex; catch; end
            if strcmp(compileTex,'never'); ce.success = true; return; end
            cwd = pwd; cleaner = onCleanup(@() cd(cwd)); cd(folder);
            st = 1;
            for k = 1:2
                [st, ~] = system(sprintf('pdflatex -interaction=nonstopmode -halt-on-error %s.tex', stem));
            end
            clear cleaner;
            pdf = fullfile(folder, [stem '.pdf']);
            if isfile(pdf) && st == 0
                ce.pdfPath = pdf; ce.success = true;
            else
                ce.success = false;
            end
        end
    end

    methods (Static, Access = private)
        function v = num_(cfg, path, dflt)
            v = cfg;
            for j = 1:numel(path)
                if isstruct(v) && isfield(v, path{j}); v = v.(path{j}); else; v = dflt; return; end
            end
            if ~(isnumeric(v) && isscalar(v)); v = dflt; end
        end

        function v = bool_(cfg, path, dflt)
            v = dflt;
            x = cfg;
            for j = 1:numel(path)
                if isstruct(x) && isfield(x, path{j}); x = x.(path{j}); else; return; end
            end
            if islogical(x) || isnumeric(x); v = logical(x); end
        end

        function fig = plotRelativeLayer_(t_h, rel, results, frame)
            % plotRelativeLayer_  Relative-layer error with the PER-PAIR BAND, not just the
            % aggregate RMS curves.
            %
            % Two deliberate departures from the previous version:
            %   * the min/max envelope across every baseline is drawn, with an explicit MEDIAN
            %     line and its numeric value -- the aggregate RMS alone hides how wide the spread
            %     across pairs is, which is the quantity that decides beamforming coherence;
            %   * the y axis is LINEAR with a dense, explicitly-placed tick set. The log axis this
            %     replaced compressed a 20-60 cm settled band into an unreadable sliver between
            %     two decade gridlines.
            if nargin < 3; results = []; end
            if nargin < 4 || isempty(frame); frame = 'earth'; end
            fig = figure('visible','off','Position',[0 0 980 470]);
            ax = axes(fig); hold(ax,'on');
            plotted = false;

            hasRaw = isstruct(rel) && isfield(rel,'perEpoch') && isfield(rel.perEpoch,'baselineErrRaw_m') && ...
                any(isfinite(rel.perEpoch.baselineErrRaw_m));
            hasSolved = isstruct(rel) && isfield(rel,'perEpoch') && ...
                ((isfield(rel.perEpoch,'baselineErrSolved_m') && any(isfinite(rel.perEpoch.baselineErrSolved_m))) || ...
                 (isfield(rel.perEpoch,'shapeErrSolved_m') && any(isfinite(rel.perEpoch.shapeErrSolved_m))));

            % Per-pair band from the solved positions vs truth, in the requested FRAME.
            band = revgnss.FederatedSwarmReport.perPairBand_(rel, results, frame);
            medianValue_cm = NaN;
            if ~isempty(band)
                nEpB = size(band,2);
                tb = t_h(1:nEpB);
                sm = revgnss.FederatedSwarmReport.smoothRows_(band, nEpB);
                lo = min(sm,[],1)*100; hi = max(sm,[],1)*100; md = median(sm,1)*100;
                fill(ax,[tb fliplr(tb)],[lo fliplr(hi)],[0.20 0.45 0.80], ...
                    'FaceAlpha',0.18,'EdgeColor','none','DisplayName','band over all baselines');
                plot(ax,tb,hi,'-','Color',[0.20 0.45 0.80],'LineWidth',1.2,'DisplayName','max baseline');
                plot(ax,tb,lo,'-','Color',[0.20 0.45 0.80],'LineWidth',1.2,'DisplayName','min baseline');
                ts = max(1,floor(nEpB*0.8));
                medianValue_cm = median(reshape(band(:,ts:end),[],1))*100;   % RAW, not smoothed
                plot(ax,tb,md,'-','Color',[0.05 0.20 0.50],'LineWidth',2.6, ...
                    'DisplayName',sprintf('median baseline (settled %.2f cm)',medianValue_cm));
                plotted = true;
            end

            if hasSolved && ~strcmpi(frame,'swarm')
                % The rigid-shape RMS is already rotation-free, so it belongs on the Earth-frame
                % plot as the reference line; on the swarm-frame plot it would duplicate the band.
                sh = rel.perEpoch.shapeErrSolved_m;
                shS = revgnss.FederatedSwarmReport.smoothRows_(sh(:).', numel(sh));
                plot(ax, t_h(1:numel(shS)), shS*100, 'r-', 'LineWidth', 1.8, ...
                    'DisplayName','shape err (rotation-free RMS)');
                plotted = true;
            end
            if hasRaw
                rw = rel.perEpoch.baselineErrRaw_m;
                rwS = revgnss.FederatedSwarmReport.smoothRows_(rw(:).', numel(rw));
                plot(ax, t_h(1:numel(rwS)), rwS*100, ':', 'Color',[0.45 0.45 0.45], ...
                    'LineWidth', 1.4, 'DisplayName','baseline err (raw, pre-ISL)');
                plotted = true;
            end

            grid(ax,'on'); box(ax,'on');
            xlabel(ax,'time [h]'); ylabel(ax,'formation error [cm]');
            if plotted
                % LINEAR, scaled from the settled part so the start-up transient cannot flatten it.
                ref = [];
                if ~isempty(band)
                    ts = max(1,floor(size(band,2)*0.8));
                    ref = reshape(band(:,ts:end),[],1)*100;
                elseif hasSolved
                    v = rel.perEpoch.shapeErrSolved_m*100; v = v(isfinite(v));
                    ts = max(1,floor(numel(v)*0.8)); ref = v(ts:end);
                end
                revgnss.FederatedSwarmReport.applyLinearDenseTicks_(ax, ref);
                legend(ax,'Location','northeast','FontSize',9);
                if isfinite(medianValue_cm)
                    if strcmpi(frame,'swarm')
                        subtitle(ax, sprintf(['SWARM FRAME -- formation''s own geometry, rigid turn ' ...
                            'REMOVED.  settled median %.2f cm.  Curves are a running median.'], ...
                            medianValue_cm), 'FontSize',9.5);
                    else
                        subtitle(ax, sprintf(['EARTH (ECEF) FRAME -- includes the formation''s rigid ' ...
                            'turn.  settled median %.2f cm.  Curves are a running median.'], ...
                            medianValue_cm), 'FontSize',9.5);
                    end
                end
            else
                text(ax, 0.5, 0.5, 'relative-layer diagnostics unavailable', ...
                    'Units','normalized', 'HorizontalAlignment','center');
            end
            if ~hasSolved
                title(ax,'Relative geometry diagnostic: two-way ISL shape layer off');
            elseif strcmpi(frame,'swarm')
                title(ax,'Relative layer in the SWARM FRAME (turn removed) -- what the ISL governs');
            else
                title(ax,'Relative layer in the EARTH FRAME (turn included) -- what the beam sees');
            end
            set(ax,'FontSize',11);
        end

        function fig = plotRelativeToReference_(t_h, rel, results, refAsset, frame)
            % plotRelativeToReference_  One SMOOTHED curve per satellite: its baseline-vector
            % error against the reference satellite the report is written about.
            %
            % Deliberately the relative twin of the per-satellite ABSOLUTE plot, so the two read
            % the same way. Two choices that matter:
            %   * a running MEDIAN, not the raw series. The per-epoch trace is dominated by
            %     measurement noise that swamps the trend; the median is what a reader actually
            %     wants and what the settled value is quoted from.
            %   * LINEAR y on round ticks, so a level can be read straight off the axis.
            fig = [];
            if nargin < 4 || isempty(refAsset); refAsset = 1; end
            if nargin < 5 || isempty(frame); frame = 'earth'; end
            band = revgnss.FederatedSwarmReport.perPairBand_(rel, results, frame, refAsset);
            if isempty(band); return; end
            nEp = size(band,2);
            t = t_h(1:nEp);
            sm = revgnss.FederatedSwarmReport.smoothRows_(band, nEp);

            fig = figure('visible','off','Position',[0 0 980 470]);
            ax = axes(fig); hold(ax,'on'); grid(ax,'on'); box(ax,'on');
            ids = setdiff(1:rel.nAssets, refAsset);
            cmap = lines(max(numel(ids),1));
            for r = 1:numel(ids)
                plot(ax, t, sm(r,:), '-', 'Color', cmap(r,:), 'LineWidth', 2.0, ...
                    'DisplayName', sprintf('asset %d', ids(r)));
            end
            ts = max(1,floor(nEp*0.8));
            settled = median(reshape(band(:,ts:end),[],1));
            yline(ax, settled, '--', 'Color',[0.25 0.25 0.25], 'LineWidth', 1.6, ...
                'DisplayName', sprintf('settled median %.3f m', settled));
            xlabel(ax,'time [h]'); ylabel(ax,'relative position error [m]');
            if strcmpi(frame,'swarm')
                title(ax, sprintf(['Relative position error to asset %d -- SWARM FRAME ' ...
                    '(rigid turn removed)'], refAsset));
                subtitle(ax, sprintf(['the formation''s OWN geometry, the part the ISL governs;  ' ...
                    'running median;  settled median %.3f m'], settled), 'FontSize',9.5);
            else
                title(ax, sprintf(['Relative position error to asset %d -- EARTH FRAME ' ...
                    '(turn included)'], refAsset));
                subtitle(ax, sprintf(['what a ground beamformer experiences;  running median;  ' ...
                    'settled median %.3f m'], settled), 'FontSize',9.5);
            end
            legend(ax,'Location','northeast','FontSize',9);
            revgnss.FederatedSwarmReport.applyLinearDenseTicks_(ax, reshape(sm(:,ts:end),[],1));
            set(ax,'FontSize',11);
        end


        function [lo, hi, ticks] = niceTicks_(lo, hi, targetCount)
            % niceTicks_  Round tick step from the 1/2/2.5/5/10 family, so labels read as
            % 0, 50, 100, ... instead of linspace's 37.6444, 75.2888, ... A dense axis is only
            % readable if the numbers on it are ones a reader can hold in their head.
            span = hi - lo;
            if ~(span > 0) || ~isfinite(span); ticks = [lo hi]; return; end
            raw = span/max(targetCount,1);
            mag = 10^floor(log10(raw));
            step = 10*mag;
            for m = [1 2 2.5 5 10]
                if raw <= m*mag + eps(m*mag); step = m*mag; break; end
            end
            lo = floor(lo/step)*step;
            hi = ceil(hi/step)*step;
            ticks = lo:step:hi;
        end

        function [band, pairs] = perPairBand_(rel, results, frame, refAsset)
            % perPairBand_  Baseline VECTOR error per pair and epoch, in a CHOSEN FRAME.
            %
            %   frame='earth'  the estimate as it stands. Includes the formation's rigid
            %                  ORIENTATION error relative to the Earth-fixed frame. This is what a
            %                  ground observer -- and a beamformer -- actually experiences.
            %   frame='swarm'  the best-fit rigid rotation is removed first, so what remains is
            %                  the formation's OWN internal geometry error (deformation). This is
            %                  the part inter-satellite ranging governs; it is blind to the turn.
            %
            % The two differ by a factor of several in this system, which is exactly why they are
            % plotted separately and labelled rather than collapsed into one "relative error".
            %
            % refAsset > 0 returns only the baselines against that asset (N-1 rows); otherwise all
            % N*(N-1)/2 pairs.
            band = []; pairs = zeros(0,2);
            if nargin < 3 || isempty(frame); frame = 'earth'; end
            if nargin < 4 || isempty(refAsset); refAsset = 0; end
            if ~isstruct(rel) || ~isfield(rel,'solvedPos') || isempty(rel.solvedPos); return; end
            if ~isstruct(results) || ~isfield(results,'asset'); return; end
            P = rel.solvedPos; N = size(P,2); nEp = size(P,3);
            if N < 2 || nEp < 2 || numel(results.asset) < N; return; end
            T = zeros(3,N,nEp);
            for i = 1:N
                a = results.asset{i};
                if ~isfield(a,'truthTraj') || size(a.truthTraj,2) < nEp; return; end
                T(:,i,:) = reshape(a.truthTraj(:,1:nEp),3,1,nEp);
            end
            if refAsset >= 1 && refAsset <= N
                ids = setdiff(1:N,refAsset);
                pairs = [repmat(refAsset,numel(ids),1) ids(:)];
            else
                pairs = nchoosek(1:N,2);
            end
            useSwarm = strcmpi(frame,'swarm');
            band = zeros(size(pairs,1),nEp);
            for kk = 1:nEp
                Tk = T(:,:,kk); Pk = P(:,:,kk);
                Tc = Tk - mean(Tk,2); Pc = Pk - mean(Pk,2);
                if useSwarm
                    [U,~,V] = svd(Pc*Tc.');
                    R = U*diag([1 1 sign(det(U*V.'))])*V.';
                    Pc = R.'*Pc;                     % rotate the estimate back onto truth
                end
                for p = 1:size(pairs,1)
                    i = pairs(p,1); k = pairs(p,2);
                    band(p,kk) = norm((Pc(:,i)-Pc(:,k)) - (Tc(:,i)-Tc(:,k)));
                end
            end
        end

        function y = smoothRows_(x, nEp)
            % smoothRows_  Running median so the trend is readable. The per-epoch trace is
            % dominated by measurement noise that hides the very structure these plots exist to
            % show; the settled statistics are still computed from the RAW series, never from the
            % smoothed one, so smoothing changes the picture and not the numbers.
            w = max(31, 2*floor(nEp/80)+1);
            y = zeros(size(x));
            for r = 1:size(x,1); y(r,:) = movmedian(x(r,:), w); end
        end

        function applyLinearDenseTicks_(ax, referenceValues)
            % applyLinearDenseTicks_  Linear y axis, ~11 explicit ticks, plain numbers.
            % Placing the ticks explicitly is the point: MATLAB's automatic choice on a range like
            % 0-60 cm gives 3-4 gridlines, which is what made the previous plot unreadable.
            set(ax,'YScale','linear');
            v = referenceValues(:); v = v(isfinite(v));
            if isempty(v); return; end
            hi = max(v)*1.25; lo = min(0, min(v));
            if ~(hi > lo); return; end
            [lo, hi, ticks] = revgnss.FederatedSwarmReport.niceTicks_(lo, hi, 10);
            ylim(ax,[lo hi]);
            set(ax,'YTick',ticks);
            try; ax.YAxis.Exponent = 0; catch; end
            ax.YAxis.TickLabelFormat = '%.4g';
        end

        function vals = positiveFiniteRelValues_(rel)
            vals = [];
            fields = {'baselineErrRaw_m','baselineErrSolved_m','shapeErrSolved_m'};
            if ~isstruct(rel) || ~isfield(rel,'perEpoch'); return; end
            for i = 1:numel(fields)
                name = fields{i};
                if isfield(rel.perEpoch, name)
                    v = rel.perEpoch.(name) * 100;
                    vals = [vals; v(isfinite(v) & v > 0).']; %#ok<AGROW>
                end
            end
        end

        function fig = plotKabschAlignment_(results, rel)
            % plotKabschAlignment_  TWO panels, both with the error EXAGGERATED so its DIRECTION
            % is visible:
            %   left   estimate as it stands  -> shows the rigid TURN
            %   right  estimate Kabsch-aligned -> the turn removed, so only DEFORMATION remains
            % At true scale a sub-degree turn over a kilometre-class formation is invisible, which
            % is exactly why the previous single true-scale panel showed a formation that looked
            % perfect while the beam was incoherent. The exaggeration factor is stated on the axes
            % and the numeric RMS/max are the REAL values, never the exaggerated ones.
            fig = [];
            if nargin < 2; rel = []; end
            [est, truth, ok] = revgnss.FederatedSwarmReport.finalFormation_(results);
            if ~ok || size(est,2) < 3; return; end
            % Prefer the RELATIVE-LAYER solution when it exists. finalFormation_ returns the raw
            % per-asset EKF positions, in which rotation and deformation are comparable, so the
            % turn-vs-deformation split this figure exists to show would not appear at all.
            src = 'raw per-asset EKF positions';
            if isstruct(rel) && isfield(rel,'solvedPos') && ~isempty(rel.solvedPos) && ...
                    size(rel.solvedPos,2) == size(est,2)
                est = rel.solvedPos(:,:,end);
                src = 'ISL-solved relative positions';
            end
            [estAligned, truthCtr, ~, rms_m, max_m] = ...
                revgnss.FederatedSwarmReport.kabschNoScale_(est, truth);
            estCtr = est - mean(est,2);
            fig = revgnss.FederatedSwarmReport.kabschTwoPanel_( ...
                truthCtr, estCtr, estAligned, rms_m, max_m, src);
        end

        function fig = kabschTwoPanel_(truthCtr, estCtr, estAligned, rms_m, max_m, src)
            N = size(truthCtr,2);
            % Exaggeration chosen so the LARGER of the two residuals spans ~15% of the formation.
            span = max(max(truthCtr,[],2) - min(truthCtr,[],2));
            resTurn = max(vecnorm(estCtr    - truthCtr,2,1));
            resDef  = max(vecnorm(estAligned - truthCtr,2,1));
            AMP = 1;
            if resTurn > 0; AMP = max(1, round(0.15*span/resTurn)); end

            fig = figure('visible','off','Color','white','Position',[0 0 1440 640]);
            tl = tiledlayout(fig,1,2,'TileSpacing','compact','Padding','compact');
            revgnss.FederatedSwarmReport.kabschPanel_(nexttile(tl,1), truthCtr, ...
                truthCtr + AMP*(estCtr - truthCtr), N, AMP, ...
                'As estimated: the formation is TURNED', ...
                sprintf('rigid turn, %.4f m RMS per satellite', ...
                sqrt(mean(sum((estCtr-truthCtr).^2,1)))));
            revgnss.FederatedSwarmReport.kabschPanel_(nexttile(tl,2), truthCtr, ...
                truthCtr + AMP*(estAligned - truthCtr), N, AMP, ...
                'Kabsch aligned: the turn removed', ...
                sprintf('deformation only, RMS %.4f m, max %.4f m', rms_m, max_m));
            title(tl, {sprintf(['Final formation error, direction shown at %dx exaggeration' ...
                '   (numbers are the REAL values)'], AMP), ...
                sprintf('source: %s', src)}, 'FontWeight','bold','FontSize',12.5);
        end

        function kabschPanel_(ax, truthCtr, shown, N, AMP, ttl, sub) %#ok<INUSD>
            hold(ax,'on'); grid(ax,'on'); box(ax,'on');
            for a1 = 1:N-1
                for b1 = a1+1:N
                    plot3(ax,[truthCtr(1,a1) truthCtr(1,b1)],[truthCtr(2,a1) truthCtr(2,b1)], ...
                        [truthCtr(3,a1) truthCtr(3,b1)],'-','Color',[0.80 0.87 0.95],'LineWidth',0.9, ...
                        'HandleVisibility','off');
                end
            end
            plot3(ax,0,0,0,'kp','MarkerFaceColor',[1.0 0.85 0.10],'MarkerSize',11,'DisplayName','centroid');
            plot3(ax,truthCtr(1,:),truthCtr(2,:),truthCtr(3,:),'o','MarkerSize',9, ...
                'MarkerFaceColor',[0.20 0.45 0.80],'MarkerEdgeColor','k','DisplayName','truth');
            plot3(ax,shown(1,:),shown(2,:),shown(3,:),'o','MarkerSize',8, ...
                'MarkerFaceColor',[0.90 0.20 0.10],'MarkerEdgeColor','k','DisplayName','estimate');
            for i = 1:N
                plot3(ax,[truthCtr(1,i) shown(1,i)],[truthCtr(2,i) shown(2,i)], ...
                    [truthCtr(3,i) shown(3,i)],'-','Color',[0.85 0.20 0.10],'LineWidth',2.0, ...
                    'HandleVisibility','off');
                text(ax,truthCtr(1,i),truthCtr(2,i),truthCtr(3,i),sprintf('  %d',i), ...
                    'FontSize',10,'FontWeight','bold');
            end
            xlabel(ax,'centered ECEF X [m]'); ylabel(ax,'centered ECEF Y [m]');
            zlabel(ax,'centered ECEF Z [m]');
            title(ax,ttl,'FontSize',11.5,'FontWeight','bold');
            subtitle(ax,sub,'FontSize',9.5);
            legend(ax,'Location','northeast','FontSize',9);
            view(ax,-55,24); axis(ax,'vis3d'); axis(ax,'equal'); set(ax,'FontSize',10);
        end

        function fig = plotKabschAlignmentLegacy_(results)
            fig = [];
            [est, truth, ok] = revgnss.FederatedSwarmReport.finalFormation_(results);
            if ~ok || size(est,2) < 3; return; end
            [estAligned, truthCtr, ~, rms_m, max_m] = ...
                revgnss.FederatedSwarmReport.kabschNoScale_(est, truth);

            allPts = [truthCtr estAligned];
            span = max(max(allPts,[],2) - min(allPts,[],2));
            if ~isfinite(span) || span <= 0; span = 1; end
            pad = 0.18 * span;
            mid = 0.5 * (max(allPts,[],2) + min(allPts,[],2));
            lims = [mid - 0.5*span - pad, mid + 0.5*span + pad];
            labelOffset = max(1e-3,0.05*span);
            truthLabelOffset = [labelOffset; labelOffset; labelOffset];
            estimateLabelOffset = [labelOffset; -labelOffset; -labelOffset];

            fig = figure('visible','off','Color','white','Position',[0 0 780 640]);
            ax = axes(fig); hold(ax,'on'); grid(ax,'on'); axis(ax,'equal');
            plot3(ax, 0, 0, 0, 'kp', 'MarkerFaceColor',[1.0 0.85 0.10], ...
                'MarkerSize',10, 'DisplayName','centroid');
            plot3(ax, truthCtr(1,:), truthCtr(2,:), truthCtr(3,:), 'ko', ...
                'MarkerFaceColor','k', 'MarkerSize',7, 'DisplayName','truth');
            plot3(ax, estAligned(1,:), estAligned(2,:), estAligned(3,:), 'ro', ...
                'MarkerFaceColor',[0.90 0.10 0.10], 'MarkerSize',6, ...
                'DisplayName','estimated, Kabsch aligned');
            for i = 1:size(est,2)
                plot3(ax, [truthCtr(1,i) estAligned(1,i)], ...
                    [truthCtr(2,i) estAligned(2,i)], ...
                    [truthCtr(3,i) estAligned(3,i)], 'Color',[0.25 0.25 0.25], ...
                    'LineWidth',0.9, 'HandleVisibility','off');
                text(ax,truthCtr(1,i)+truthLabelOffset(1), ...
                    truthCtr(2,i)+truthLabelOffset(2), ...
                    truthCtr(3,i)+truthLabelOffset(3),sprintf('T%d',i), ...
                    'FontSize',8,'Color','k');
                text(ax,estAligned(1,i)+estimateLabelOffset(1), ...
                    estAligned(2,i)+estimateLabelOffset(2), ...
                    estAligned(3,i)+estimateLabelOffset(3),sprintf('E%d',i), ...
                    'FontSize',8,'Color',[0.70 0 0]);
            end
            xlim(ax, lims(1,:)); ylim(ax, lims(2,:)); zlim(ax, lims(3,:));
            xlabel(ax,'centered ECEF X [m]');
            ylabel(ax,'centered ECEF Y [m]');
            zlabel(ax,'centered ECEF Z [m]');
            title(ax, sprintf('Final formation after rigid Kabsch alignment: RMS %.3f m, max %.3f m', ...
                rms_m, max_m));
            legend(ax,'Location','best');
            view(ax, -55, 24);
            set(ax,'FontSize',10);
        end

        function [est, truth, ok] = finalFormation_(results)
            ok = false; est = []; truth = [];
            N = 0; if isstruct(results) && isfield(results,'N'); N = results.N; end
            if N < 1 || ~isfield(results,'asset') || numel(results.asset) < N; return; end
            est = nan(3,N); truth = nan(3,N);
            for i = 1:N
                a = results.asset{i};
                if ~isfield(a,'history') || ~isfield(a.history,'x') || isempty(a.history.x); return; end
                if ~isfield(a,'stateMap') || ~isfield(a.stateMap,'r_idx'); return; end
                if ~isfield(a,'truthTraj') || isempty(a.truthTraj); return; end
                est(:,i) = a.history.x(a.stateMap.r_idx, end);
                truth(:,i) = a.truthTraj(:, end);
            end
            ok = all(isfinite(est(:))) && all(isfinite(truth(:)));
        end

        function [aligned, truthCtr, residual, rms_m, max_m] = kabschNoScale_(est, truth)
            x = est - mean(est, 2);
            y = truth - mean(truth, 2);
            H = x * y.';
            [U,~,V] = svd(H);
            D = eye(3);
            if det(V * U.') < 0; D(3,3) = -1; end
            R = V * D * U.';
            aligned = R * x;
            truthCtr = y;
            residual = aligned - truthCtr;
            rn = vecnorm(residual, 2, 1);
            rms_m = sqrt(mean(rn.^2));
            max_m = max(rn);
        end
    end
end
