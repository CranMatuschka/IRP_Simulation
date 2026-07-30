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
        function [absName, relName, kabschName] = renderFigures(results, rel, folder, absStem, relStem, kabschStem, doKabsch)
            % renderFigures  Render swarm diagnostic figures into `folder`.
            if nargin < 6 || isempty(kabschStem); kabschStem = [relStem '_kabsch']; end
            if nargin < 7 || isempty(doKabsch); doKabsch = false; end
            absName = ''; relName = ''; kabschName = '';
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
            try
                f2 = revgnss.FederatedSwarmReport.plotRelativeLayer_(t, rel);
                % Rescale into readable units so no axis carries a x10^-n multiplier.
                revgnss.ClockExactReportBuilder.normalizeAxisUnits_(f2); 
                exportgraphics(f2, fullfile(folder, [relStem '.png']), 'Resolution', 130); close(f2);
                relName = [relStem '.png'];
            catch; end
            if doKabsch
                try
                    f3 = revgnss.FederatedSwarmReport.plotKabschAlignment_(results);
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
                    f = revgnss.FederatedSwarmReport.plotKabschAlignment_(results);
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
                f2 = revgnss.FederatedSwarmReport.plotRelativeLayer_(t, rel);
                % Rescale into readable units so no axis carries a x10^-n multiplier.
                revgnss.ClockExactReportBuilder.normalizeAxisUnits_(f2); 
                exportgraphics(f2, png2, 'Resolution', 130); close(f2);
            catch; end
            if doKabsch
                try
                    f3 = revgnss.FederatedSwarmReport.plotKabschAlignment_(results);
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

        function fig = plotRelativeLayer_(t_h, rel)
            fig = figure('visible','off','Position',[0 0 900 420]);
            ax = axes(fig); hold(ax,'on');
            plotted = false;
            hasRaw = isstruct(rel) && isfield(rel,'perEpoch') && isfield(rel.perEpoch,'baselineErrRaw_m') && ...
                any(isfinite(rel.perEpoch.baselineErrRaw_m));
            hasSolved = isstruct(rel) && isfield(rel,'perEpoch') && ...
                ((isfield(rel.perEpoch,'baselineErrSolved_m') && any(isfinite(rel.perEpoch.baselineErrSolved_m))) || ...
                 (isfield(rel.perEpoch,'shapeErrSolved_m') && any(isfinite(rel.perEpoch.shapeErrSolved_m))));
            if hasSolved
                plot(ax, t_h, rel.perEpoch.baselineErrSolved_m*100, 'b-', 'LineWidth', 1.2, ...
                    'DisplayName','baseline err (solved)');
                plot(ax, t_h, rel.perEpoch.shapeErrSolved_m*100, 'r-', 'LineWidth', 1.2, ...
                    'DisplayName','shape err (solved)');
                plotted = true;
            end
            if hasRaw
                plot(ax, t_h, rel.perEpoch.baselineErrRaw_m*100, 'b:', 'LineWidth', 0.8, ...
                    'DisplayName','baseline err (raw, pre-ISL)');
                plotted = true;
            end
            grid(ax,'on'); xlabel(ax,'time [h]'); ylabel(ax,'formation error [cm]');
            if plotted
                if ~isempty(revgnss.FederatedSwarmReport.positiveFiniteRelValues_(rel))
                    set(ax,'YScale','log');
                end
                legend(ax,'Location','best');
            else
                text(ax, 0.5, 0.5, 'relative-layer diagnostics unavailable', ...
                    'Units','normalized', 'HorizontalAlignment','center');
            end
            if hasSolved
                title(ax,'Relative layer: two-way ISL solved formation shape');
            else
                title(ax,'Relative geometry diagnostic: two-way ISL shape layer off');
            end
            set(ax,'FontSize',11);
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

        function fig = plotKabschAlignment_(results)
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
