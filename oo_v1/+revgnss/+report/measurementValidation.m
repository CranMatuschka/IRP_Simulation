function measurementValidation(fid, plotPaths, stem, figDir, diag, cfg, summary)
%MEASUREMENTVALIDATION  "Measurement and Geometry Validation" report section.
%   Extracted verbatim from ClockExactReportBuilder.writeMeasurementValidation_ as part
%   of the report decomposition. Read-only: consumes only the precomputed plotPaths
%   + figure dir and the (now-public) ClockExactReportBuilder formatting toolkit. The
%   emitted LaTeX is byte-identical to the original method (verified by the normalized
%   .tex diff harness, tests/report/reportTexFingerprint.m).
    CE = revgnss.ClockExactReportBuilder;
    if nargin < 6; cfg = struct(); end
    if nargin < 7; summary = struct(); end
    jointMode = isfield(summary,'estimatorMultiAssetMode') && ...
        strcmpi(summary.estimatorMultiAssetMode,'joint');
    fprintf(fid, '\\section{Measurement and Geometry Validation}\n');
    fprintf(fid, ['Pre-fit residuals test the predicted measurement model before correction. ' ...
        'Post-fit residuals show how much error remains after the EKF update. ' ...
        'RMS residuals are useful diagnostics, but they are not by themselves a proof ' ...
        'of statistical consistency. ' ...
        'In deterministic or partly deterministic validation runs, NIS should be interpreted ' ...
        'as a numerical conditioning and model-coupling diagnostic.\n\n']);
    if jointMode
        fprintf(fid, ['The plotted time histories are the reference-spacecraft diagnostics ' ...
            'stored by the canonical simulation data store. Joint EKF update counts and ' ...
            'state dimensions are reported in the scenario and numerical tables.\n\n']);
    end
    zoomSec = 120;
    try
        if isfield(cfg,'report') && isfield(cfg.report,'zoomLastSeconds') && ...
                isnumeric(cfg.report.zoomLastSeconds) && cfg.report.zoomLastSeconds > 0
            zoomSec = cfg.report.zoomLastSeconds;
        end
    catch; end
    fprintf(fid, CE.plotTableHeader_());

    CE.writeRow_(fid, CE.figRef_(plotPaths,'innovRMS',figDir,stem), ...
        'EKF Measurement Pre-Fit and Post-Fit Residual RMS', ...
        i_innovText(CE, diag, zoomSec));

    CE.writeRow_(fid, CE.figRef_(plotPaths,'perSrc',figDir,stem), ...
        'Error Source Contributions', ...
        ['Breakdown of the raw code error into physical contributions: ' ...
         'code (geometric and clock residual), troposphere truth-model mismatch, ' ...
         'ionosphere truth-model mismatch.']);

    CE.writeRow_(fid, CE.figRef_(plotPaths,'visTowers',figDir,stem), ...
        'Tower Rows Used by the EKF', ...
        ['The number of ground towers passing the elevation mask at each epoch. ' ...
         'Elevation mask applied per-tower before including in the EKF update.']);

    CE.writeRow_(fid, CE.figRef_(plotPaths,'dop',figDir,stem), ...
        'Geometry: unit-weight DOP (dimensionless)', ...
        ['How much the geometry multiplies ranging noise. GDOP covers position and clock, ' ...
         'PDOP position alone; VDOP is the radial axis and HDOP along plus cross track. ' ...
         'From GEO the ground network sits in a few degrees of sky, so the values run into ' ...
         'the hundreds: weak geometry, not unobservable. Flat, because the sight lines ' ...
         'barely move. PDOP draws underneath VDOP, which owns nearly all of it.']);

    CE.writeRow_(fid, CE.figRef_(plotPaths,'dopSigma',figDir,stem), ...
        'Weighting: the same DOPs times sigma [m]', ...
        ['The same four quantities formed with the measurement covariance instead of unit ' ...
         'weights, so these are single-epoch formal sigmas in metres. The sawtooth is the ' ...
         'tower-clock correction sigma inside R, which grows with the age of the last ' ...
         'clock product and resets each update interval. Movement here with the figure ' ...
         'above flat is a weighting change, not a geometry change. Inset: the tail at a ' ...
         'scale where one cycle is visible.']);

    fprintf(fid, CE.plotTableFooter_());

    % Ground-to-space geometry / DOP metrics table (always present).
    fprintf(fid, '\\subsection{Ground-to-Space Geometry and DOP Metrics}\n');
    fprintf(fid, ['Dilution-of-precision factors scale measurement noise into state uncertainty ' ...
        '(lower is better). Values are run medians computed from the pseudorange observation ' ...
        'geometry in the ECEF line-of-sight frame. This chapter is always shown, independent of ' ...
        'any pass/fail gate. A GEO spacecraft viewing a compact cluster of ground transmitters sees ' ...
        'nearly parallel lines of sight, so the DOP values are large (hundreds) and ' ...
        'nearly constant: the geometry is observable (full rank) but weak.\n\n' ...
        'Both flavours are listed because they are not interchangeable. Unit weight is the ' ...
        'classical $\\mathrm{inv}(G^{T}G)$ DOP, dimensionless and a function of the sight ' ...
        'lines alone. R-weighted is $\\mathrm{inv}(H^{T}R^{-1}H)$, whose square roots are ' ...
        'formal sigmas in metres, so it also moves when only the weighting moves. Quoting ' ...
        'the second as a DOP overstates the geometry by roughly the ranging sigma.\n\n']);
    % Every row is read from the store the same way -- median over the finite samples, or
    % the literal string 'not available' when the series is absent or all-NaN. The HDOP /
    % VDOP / condition-number row used to be HARD-CODED to 'not available' even though the
    % store computes all three, so the table under-reported what the run actually knew.
    med_ = @(fn) i_medianOf(diag, fn);
    vt = i_medianOf(diag, 'getNumVisibleTowers', '%.1f');
    gd = med_('getGDOPLike');   pd = med_('getPDOPLike');   td = med_('getTDOPLike');
    hd = med_('getHDOPLike');   vd = med_('getVDOPLike');
    cn = i_medianOf(diag, 'getPositionClockCondition', '%.3g');
    % PDOP^2 = VDOP^2 + HDOP^2 over an orthonormal RAC triad, so these two ratios say
    % which axis OWNS the position dilution. At GEO the radial axis owns essentially all
    % of it, and the consequence is visible in the DOP figure only as an absence: the
    % PDOP curve is drawn before VDOP and the two coincide, so PDOP is painted over and
    % the reader sees three curves where four were plotted. Quoting the ratios states
    % that in numbers instead of leaving it to be inferred from a hidden curve.
    vp = i_ratioOf(diag, 'getVDOPLike', 'getPDOPLike');
    hv = i_ratioOf(diag, 'getHDOPLike', 'getVDOPLike');
    gdG = med_('getGDOPGeometric');   pdG = med_('getPDOPGeometric');
    tdG = med_('getTDOPGeometric');   vdG = med_('getVDOPGeometric');
    hdG = med_('getHDOPGeometric');
    fprintf(fid, '\\begin{center}\\small\n');
    fprintf(fid, '\\begin{tabular}{p{0.52\\textwidth}p{0.38\\textwidth}}\n\\toprule\n');
    fprintf(fid, '\\textbf{Geometry metric} & \\textbf{Value (run median)}\\\\\n\\midrule\n');
    fprintf(fid, 'Visible ground transmitters & %s\\\\\n', vt);
    fprintf(fid, '\\multicolumn{2}{l}{\\emph{Unit-weight DOP (dimensionless, geometry only)}}\\\\\n');
    fprintf(fid, 'GDOP (position + clock) & %s\\\\\n', gdG);
    fprintf(fid, 'PDOP (position) & %s\\\\\n', pdG);
    fprintf(fid, 'TDOP (receiver clock) & %s\\\\\n', tdG);
    fprintf(fid, 'VDOP (radial) / HDOP (along+cross) & %s / %s\\\\\n', vdG, hdG);
    fprintf(fid, '\\multicolumn{2}{l}{\\emph{R-weighted, i.e. single-epoch formal sigma [m]}}\\\\\n');
    fprintf(fid, 'GDOP $\\times\\sigma$ (position + clock) [m] & %s\\\\\n', gd);
    fprintf(fid, 'PDOP $\\times\\sigma$ (position) [m] & %s\\\\\n', pd);
    fprintf(fid, 'TDOP $\\times\\sigma$ (receiver clock) [m] & %s\\\\\n', td);
    fprintf(fid, 'VDOP (radial) / HDOP (along+cross) [m] & %s / %s\\\\\n', vd, hd);
    fprintf(fid, '\\multicolumn{2}{l}{\\emph{Axis split (identical for both flavours)}}\\\\\n');
    fprintf(fid, 'VDOP / PDOP (radial share of the position dilution) & %s\\\\\n', vp);
    fprintf(fid, 'HDOP / VDOP (along+cross against radial) & %s\\\\\n', hv);
    fprintf(fid, 'Position--clock normal-matrix condition number & %s\\\\\n', cn);
    fprintf(fid, 'Geometry convention & ECEF line-of-sight; per-tower elevation mask applied\\\\\n');
    fprintf(fid, '\\bottomrule\n\\end{tabular}\n\\end{center}\n\n');
    fprintf(fid, '\\clearpage\n');
end

function s = i_innovText(CE, diag, zoomSec)
%I_INNOVTEXT  Pre-fit / post-fit description carrying both RMS levels.
%   The figure now holds its own settled-tail inset, so the text has to quote BOTH
%   the whole-run RMS (which the opening transient dominates) and the tail RMS the
%   inset shows, or the reader cannot tell which number the inset belongs to.
    s = ['The pre-fit innovation (before the EKF correction) and the post-fit residual ' ...
         '(after the update) for the active measurement stack. This is a geometry, ' ...
         'clock-state coupling, and convergence diagnostic.'];
    try
        t  = diag.getTimeVector();
        pf = diag.getPrefitInnovationRMS();
        po = diag.getPostfitResidualRMS();
        i0 = CE.tailIndex_(t, zoomSec);
        n  = min([numel(t), numel(pf)]);
        if n < 2; return; end
        nPo = min(numel(po), n);
        s = sprintf(['%s The inset repeats the last %g s on its own scale, because the ' ...
            'opening transient otherwise compresses the settled level into the axis. ' ...
            'Whole run: pre-fit %s, post-fit %s. Last %g s: pre-fit %s, post-fit %s. ' ...
            'Post-fit below pre-fit is the update doing work; the two converging on each ' ...
            'other means the remaining error is not something the current state vector ' ...
            'can absorb.'], ...
            s, zoomSec, ...
            CE.fmtRms_(pf(1:n),'m'),          CE.fmtRms_(po(1:nPo),'m'), ...
            zoomSec, ...
            CE.fmtRms_(pf(i0:n),'m'),         CE.fmtRms_(po(min(i0,nPo):nPo),'m'));
    catch
    end
end

function s = i_medianOf(diag, accessor, fmt)
%I_MEDIANOF  Median over the finite samples of a store series, or 'not available'.
%   One accessor per row, so a row can never claim a value the store does not hold --
%   and, equally, can never say 'not available' about a series that is there. The two
%   accessor layers differ (data.SimulationDataStore vs revgnss.Diagnostics), hence the
%   try/catch: a missing method degrades to 'not available' rather than erroring.
    if nargin < 3; fmt = '%.2f'; end
    s = 'not available';
    try
        v = diag.(accessor)();
        v = v(isfinite(v));
        if ~isempty(v); s = sprintf(fmt, median(v)); end
    catch
    end
end

function s = i_ratioOf(diag, numAccessor, denAccessor)
%I_RATIOOF  Median of a PER-EPOCH ratio of two store series, with its range.
%   Formed epoch by epoch and then reduced, NOT as median(num)/median(den). The DOP
%   series are not stationary -- they sawtooth together with the tower-clock product
%   age (see TowerClockCorrectionProvider), because these are R-weighted DOPs and the
%   correction sigma rides in R. A ratio of two separately-taken medians would mix
%   different epochs of that sawtooth; the per-epoch ratio divides the common factor
%   out and isolates the geometry split, which is what this row is claiming to report.
%
%   The range is quoted alongside the median because the whole point of the row is
%   whether the two axes are separable at all. MEASURED on golden_baseline_attitude:
%   VDOP/PDOP 0.9984 (min 0.9967), i.e. the radial axis holds the position dilution
%   for the WHOLE arc, not merely on average. A bare median could not say that.
    s = 'not available';
    try
        a = diag.(numAccessor)();
        b = diag.(denAccessor)();
        n = min(numel(a), numel(b));
        if n < 1; return; end
        a = a(1:n); b = b(1:n);
        ok = isfinite(a) & isfinite(b) & (b > 0);
        if ~any(ok); return; end
        r = a(ok) ./ b(ok);
        s = sprintf('%.4f (min %.4f, max %.4f)', median(r), min(r), max(r));
    catch
    end
end
