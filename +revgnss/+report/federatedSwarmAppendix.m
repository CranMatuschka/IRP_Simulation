function federatedSwarmAppendix(fid, cfg, summary, figDir, esc) %#ok<INUSD>
%FEDERATEDSWARMAPPENDIX  "Federated Swarm" section for the ClockExact report.
%   Emits the federated-swarm tables and references the swarm figures already
%   placed in the state-estimation section. Single-asset reports are unchanged.
%
%   summary.federatedSwarm fields (set only by ReportRunner.runFederatedSwarm_):
%     .perAsset(i)  asset, absErr_m, absSigma_m, absRatio, clkErr_m, relPosErr_m, relPosSolvedErr_m
%     .refAsset     reference asset index (the "chief" whose full report this appendix rides on)
%     .rel          baselineErrRaw_m, baselineErrSolved_m, shapeErrSolved_m,
%                   shapeGateOn, relClockGateOn, relClockErrSolved_m,
%                   weaklyObservable, formalShapeSigma_m
%     .absFig/.relFig/.kabschFig  figure basenames already rendered into figDir
%     .nAssets .nTowers .nReceivers .duration_s

    if ~isfield(summary,'federatedSwarm') || isempty(summary.federatedSwarm)
        return;   % single-asset run: byte-identical to the golden .tex
    end
    fs  = summary.federatedSwarm;
    c   = revgnss.Constants.SPEED_OF_LIGHT_MPS;

    N = 0; if isfield(fs,'nAssets'); N = fs.nAssets; end
    ref = 1; if isfield(fs,'refAsset'); ref = fs.refAsset; end
    rel = struct(); if isfield(fs,'rel'); rel = fs.rel; end
    shapeOn = isfield(rel,'shapeGateOn') && logical(rel.shapeGateOn);

    fprintf(fid, '\\clearpage\n\\section{Federated Swarm (N independent single-asset EKFs + ISL/TWSTFT relative layer)}\n');
    if shapeOn
        layerText = ['the synthetic two-way ISL / sat--sat TWSTFT relative layer is a ' ...
            'read-only diagnostic post-processor'];
    else
        layerText = ['the sat--sat TWSTFT layer may sharpen relative clocks, while the two-way ISL ' ...
            'shape layer is disabled and only raw shape diagnostics are reported'];
    end
    fprintf(fid, ['This scenario is a \\emph{federated} swarm of %d satellites. Each satellite estimates its own ' ...
        'absolute state from the ground towers with its \\emph{own} single-asset EKF (no chief, no shared ' ...
        'covariance, design decision D1), so no filter can drag another into divergence. \\textbf{The detailed ' ...
        'report above is the reference satellite''s (asset~%d, the ``chief'''') \\emph{own single-asset run}}; ' ...
        'this swarm comprises %d such satellites, reported symmetrically in the tables below. In this configuration, ' ...
        '%s and is never fused back into any per-asset absolute solution.\n\n'], round(N), round(ref), round(N), layerText);

    % ---- Table 1: per-satellite absolute estimate --------------------------------------------
    fprintf(fid, '\\subsection*{Per-satellite absolute estimate (each from its own EKF)}\n');
    fprintf(fid, '\\begin{center}\\begin{tabular}{crrrrrr}\\toprule\n');
    fprintf(fid, ['asset & absErr [m] & absSig [m] & err/$\\sigma$ & clkErr [ns] & ' ...
        'relPos raw [m] & relPos solved [m] \\\\ \\midrule\n']);
    for i = 1:numel(fs.perAsset)
        p = fs.perAsset(i);
        solvedStr = '\multicolumn{1}{c}{--}';
        if isfield(p,'relPosSolvedErr_m') && ~isnan(p.relPosSolvedErr_m)
            solvedStr = sprintf('%.4f', p.relPosSolvedErr_m);
        end
        tag = ''; if p.asset == round(ref); tag = '$^{\ast}$'; end
        fprintf(fid, '%d%s & %.3f & %.3f & %.2f & %.3f & %.3f & %s \\\\\n', ...
            p.asset, tag, p.absErr_m, p.absSigma_m, p.absRatio, p.clkErr_m/c*1e9, p.relPosErr_m, solvedStr);
    end
    fprintf(fid, '\\bottomrule\\end{tabular}\\end{center}\n');
    if shapeOn
        fprintf(fid, ['{\\footnotesize $^{\\ast}$reference asset. \\textbf{relPos raw} = each satellite''s ' ...
            'relative-position error vs the reference from differencing the two \\emph{independent} EKF absolutes ' ...
            '(pre-ISL). \\textbf{relPos solved} = the same quantity \\emph{after} the ISL free-network shape solve. ' ...
            'Both retain the native estimate-frame gauge (ref-differenced, with no truth-based frame alignment). ' ...
            'The solved result nevertheless consumes truth-synthesized synthetic observations. Tail-averaged ' ...
            '(last 20\\,\\%%).}\n\n']);
    else
        fprintf(fid, ['{\\footnotesize $^{\\ast}$reference asset. \\textbf{relPos raw} = each satellite''s ' ...
            'relative-position error vs the reference from differencing the two \\emph{independent} EKF absolutes. ' ...
            '\\textbf{relPos solved} is not reported because the two-way ISL shape layer is disabled. Tail-averaged ' ...
            '(last 20\\,\\%%).}\n\n']);
    end

    % ---- Table 2: relative layer -------------------------------------------------------------
    % Plan Section 3.5 companion patch (a disjoint pipeline from the correlation-network path
    % Section 3.5 itself targets -- see revgnss.DistributedFleetReportingContract's own header --
    % but this appendix had the identical reporting defects Section 3.5 items 2/4 name: the
    % weak-observability verdict was printed LAST, after every numeric row, and the two formal
    % sigmas SwarmRelativeSolver already computes (formalShapeSigma_m/relClockFormalSigma_m) were
    % never printed at all despite being available on `rel`).
    g = @(n) getRel_(rel, n);
    fprintf(fid, '\\subsection*{Relative layer (ISL shape / sat--sat TWSTFT clocks)}\n');
    weak = logical(g('weaklyObservable'));
    if weak
        fprintf(fid, ['\\textbf{Weakly observable: yes.} The rows below marked $^{\\dagger}$ come from an ' ...
            'ill-conditioned ISL shape-solve normal matrix (small singular-value ratio); treat them as ' ...
            'unreliable rather than as a tight bound.\n\n']);
    else
        fprintf(fid, 'Weakly observable: no (the ISL shape-solve normal matrix is well-conditioned).\n\n');
    end
    dag = ''; if weak; dag = '$^{\dagger}$'; end
    fprintf(fid, '\\begin{center}\\begin{tabular}{lrrr}\\toprule\n');
    fprintf(fid, 'quantity & error & formal $\\sigma$ & err/$\\sigma$ \\\\ \\midrule\n');
    fprintf(fid, 'formation baseline error (raw, pre-ISL) & %.3f m & \\multicolumn{1}{c}{--} & \\multicolumn{1}{c}{--} \\\\\n', g('baselineErrRaw_m'));
    if shapeOn && isfinite(g('baselineErrSolved_m'))
        fprintf(fid, 'formation baseline error (solved)%s & %.4f m (%.2f cm) & \\multicolumn{1}{c}{--} & \\multicolumn{1}{c}{--} \\\\\n', ...
            dag, g('baselineErrSolved_m'), g('baselineErrSolved_m')*100);
    else
        fprintf(fid, 'formation baseline error (solved) & -- (two-way ISL shape disabled) & \\multicolumn{1}{c}{--} & \\multicolumn{1}{c}{--} \\\\\n');
    end
    if shapeOn && isfinite(g('shapeErrSolved_m'))
        % shapeErrSolved_m is an RMS over points of the 3-D residual NORM (SwarmRelativeSolver.
        % shapeRms_: sqrt(mean(sum(diffs.^2,1)))); formalShapeSigma_m is a PER-AXIS 1-sigma
        % (sqrt(mean(diag(C))) over 3N coordinates). Pairing them directly as printed would bias
        % err/sigma high by exactly sqrt(3) for a perfectly consistent solve -- scale the sigma to
        % the same per-point-norm quantity the error itself measures before printing either cell.
        shapeSigma = sqrt(3)*g('formalShapeSigma_m');
        fprintf(fid, 'best-fit-rigid shape error (solved)%s & %.4f m (%.2f cm) & %s & %s \\\\\n', ...
            dag, g('shapeErrSolved_m'), g('shapeErrSolved_m')*100, ...
            sigmaCell_(shapeSigma), ratioCell_(g('shapeErrSolved_m'),shapeSigma));
    else
        fprintf(fid, 'best-fit-rigid shape error (solved) & -- (two-way ISL shape disabled) & \\multicolumn{1}{c}{--} & \\multicolumn{1}{c}{--} \\\\\n');
    end
    if isfield(rel,'relClockGateOn') && rel.relClockGateOn
        % No dagger here: weaklyObservable is set exclusively from the SHAPE normal matrix's SVD
        % (SwarmRelativeSolver.solveEpoch_), never from solveRelativeClocks_'s own, independent
        % normal matrix -- marking this row would be a false conditioning claim. Also,
        % relClockFormalSigma_m is a PER-NODE 1-sigma while relClockErrSolved_m (relClockRms_) is
        % an RMS over PAIR-DIFFERENCE errors; for the min-norm gauge these differ by a
        % topology-dependent factor (sqrt(2N/(N-1)) on a complete graph) SwarmRelativeSolver does
        % not currently expose, so the sigma is labeled by what it actually is and the ratio cell
        % is left honestly blank rather than printing a mismatched, misleadingly-precise number.
        clockSigma = g('relClockFormalSigma_m');
        fprintf(fid, 'relative clock error (sat--sat TWSTFT) & %.5f m (%.4f ns) & %s (per-node) & \\multicolumn{1}{c}{--} \\\\\n', ...
            g('relClockErrSolved_m'), g('relClockErrSolved_m')/c*1e9, sigmaCell_(clockSigma));
    else
        fprintf(fid, 'relative clock (sat--sat TWSTFT) & off & \\multicolumn{1}{c}{--} & \\multicolumn{1}{c}{--} \\\\\n');
    end
    fprintf(fid, 'NIS & \\multicolumn{3}{l}{not applicable: the shape/clock layer is a per-epoch least-squares solve, not a filter} \\\\\n');
    fprintf(fid, '\\bottomrule\\end{tabular}\\end{center}\n');

    % ---- Figures -----------------------------------------------------------------------------
    % The two swarm plots (per-satellite absolute error; ISL-sharpened relative shape) are placed
    % with the state-estimation figures earlier in the report, directly after the RAC final-zoom
    % row, so they read in the same plot-row style as the rest of the report.
    if (isfield(fs,'absFig') && ~isempty(fs.absFig)) || (isfield(fs,'relFig') && ~isempty(fs.relFig)) || ...
            (isfield(fs,'kabschFig') && ~isempty(fs.kabschFig))
        fprintf(fid, ['\\emph{The per-satellite absolute-error, relative-layer, and Kabsch alignment plots appear with ' ...
            'the state-estimation figures above, immediately after the RAC final-zoom plot.}\n\n']);
    end
    if isfield(fs,'kabschFig') && ~isempty(fs.kabschFig)
        fprintf(fid, ['\\emph{Kabsch alignment uses truth as the reference frame and is a shape-only diagnostic; it ' ...
            'is not fed back into any estimate.}\n\n']);
    end

    if shapeOn
        fprintf(fid, ['\\medskip Each satellite''s absolute is wall-limited (radial--clock common mode, err/$\\sigma$ near ' ...
            '1--3), because reverse-GNSS towers only weakly separate radial position from the receiver clock. The ISL/TWSTFT ' ...
            'relative layer cannot re-open that wall (no shared covariance), yet it recovers the observable formation shape ' ...
            'and relative clocks.\n\n']);
    else
        fprintf(fid, ['\\medskip Each satellite''s absolute is wall-limited (radial--clock common mode, err/$\\sigma$ near ' ...
            '1--3), because reverse-GNSS towers only weakly separate radial position from the receiver clock. Sat--sat ' ...
            'TWSTFT may solve relative clocks, but the two-way ISL shape layer is disabled in this configuration, so solved ' ...
            'shape metrics are intentionally not reported.\n\n']);
    end
end

function v = getRel_(rel, name)
    v = NaN;
    if isstruct(rel) && isfield(rel, name) && ~isempty(rel.(name)); v = rel.(name); end
end

function cellText = sigmaCell_(sigmaValue)
% sigmaCell_  Plan Section 3.5 companion patch: renders SwarmRelativeSolver's own
% formalShapeSigma_m/relClockFormalSigma_m (already computed, previously never printed) as a
% table cell, honest '--' when unavailable rather than a fabricated 0.
if isfinite(sigmaValue) && sigmaValue >= 0
    cellText = sprintf('%.4f m',sigmaValue);
else
    cellText = '\multicolumn{1}{c}{--}';
end
end

function cellText = ratioCell_(errorValue, sigmaValue)
% ratioCell_  Same NaN-when-sigma<=0 safety idiom used throughout this plan's other report
% builders (e.g. IndependentFleetDiagnosticReport.positionMetrics_/safeRatio_).
if isfinite(errorValue) && isfinite(sigmaValue) && sigmaValue > 0
    cellText = sprintf('%.2f',errorValue/sigmaValue);
else
    cellText = '\multicolumn{1}{c}{--}';
end
end
