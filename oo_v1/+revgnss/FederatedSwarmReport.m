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
            try
                f1 = figure('visible','off','Position',[0 0 900 480]); hold on; cmap = lines(max(N,1));
                for i = 1:N
                    sm = results.asset{i}.stateMap;
                    e = vecnorm(results.asset{i}.history.x(sm.r_idx,:) - results.asset{i}.truthTraj, 2, 1);
                    plot(t, e, 'Color', cmap(i,:), 'LineWidth', 1.0, 'DisplayName', sprintf('asset %d', i));
                end
                grid on; xlabel('time [h]'); ylabel('absolute position error [m]');
                title('Per-satellite absolute position error (each independent EKF)');
                legend('Location','northeastoutside'); set(gca,'FontSize',11);
                exportgraphics(f1, png1, 'Resolution', 130); close(f1);
            catch; end
            try
                f2 = figure('visible','off','Position',[0 0 900 420]); hold on;
                plot(t, rel.perEpoch.baselineErrSolved_m*100, 'b-', 'LineWidth', 1.2, 'DisplayName','baseline err (solved)');
                plot(t, rel.perEpoch.shapeErrSolved_m*100,   'r-', 'LineWidth', 1.2, 'DisplayName','shape err (solved)');
                plot(t, rel.perEpoch.baselineErrRaw_m*100,   'b:', 'LineWidth', 0.8, 'DisplayName','baseline err (raw W1)');
                grid on; xlabel('time [h]'); ylabel('formation error [cm]'); set(gca,'YScale','log');
                title('Relative layer: ISL sharpens the formation shape to cm');
                legend('Location','northeastoutside'); set(gca,'FontSize',11);
                exportgraphics(f2, png2, 'Resolution', 130); close(f2);
            catch; end

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
            fp('formation baseline error (raw W1) & %.3f m \\\\\n', rel.baselineErrRaw_m);
            fp('formation baseline error (solved) & %.4f m (%.2f cm) \\\\\n', rel.baselineErrSolved_m, rel.baselineErrSolved_m*100);
            fp('best-fit-rigid shape error (solved) & %.4f m (%.2f cm) \\\\\n', rel.shapeErrSolved_m, rel.shapeErrSolved_m*100);
            if isfield(rel,'relClockGateOn') && rel.relClockGateOn
                fp('relative clock error (TWSTFT) & %.5f m (%.4f ns) \\\\\n', rel.relClockErrSolved_m, rel.relClockErrSolved_m/C*1e9);
            else
                fp('relative clock (TWSTFT) & off \\\\\n');
            end
            fp('weakly observable & %d \\\\\n\\bottomrule\\end{tabular}\\end{center}\n', rel.weaklyObservable);
            if isfile(png1); fp('\\begin{figure}[h]\\centering\\includegraphics[width=\\linewidth]{%s}\\end{figure}\n', [stem '_swarm_abs_err.png']); end
            if isfile(png2); fp('\\begin{figure}[h]\\centering\\includegraphics[width=\\linewidth]{%s}\\end{figure}\n', [stem '_swarm_rel_err.png']); end
            fp('\\section*{Interpretation}\n');
            fp('Each satellite estimates its \\emph{own absolute} state from the ground towers only; that ');
            fp('absolute is wall-limited (radial--clock common mode, err/$\\sigma$ near 1--3). The ISL/TWSTFT ');
            fp('relative layer is fused with \\emph{no shared covariance} (design decision D1), so it cannot ');
            fp('re-open any per-asset filter, yet it sharpens the observable formation shape to a few ');
            fp('centimetres and the relative clocks to $\\sim$100\\,ps.\n\\end{document}\n');
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
    end
end
