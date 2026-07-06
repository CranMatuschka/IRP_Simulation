function numericalSummary(fid, cfg, summary, diag)
%NUMERICALSUMMARY  "Numerical Summary" report section (Phase 7).
%   Extracted verbatim from ClockExactReportBuilder.writeNumericalSummary_ as part
%   of the C-9 report decomposition. Read-only: consumes only the precomputed plotPaths
%   + figure dir and the (now-public) ClockExactReportBuilder formatting toolkit. The
%   emitted LaTeX is byte-identical to the original method (verified by the normalized
%   .tex diff harness, tests/report/reportTexFingerprint.m).
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
    % Stage 73: slip detection diagnostics
    slipMeth73_ = CE.safeField_(summary, 'carrierSlipDetectorMethod', 'rawResidualJump');
    nProdBnd73_ = CE.safeField_(summary, 'nCarrierProductBoundaries', NaN);
    nProdCmp73_ = CE.safeField_(summary, 'nCarrierProductBoundariesCompensated', NaN);
    nSlips73_   = CE.safeField_(summary, 'nConfirmedCarrierSlips', NaN);
    nFalse73_   = CE.safeField_(summary, 'nFalseProductBoundaryResets', NaN);
    CE.writeQuantRow_(fid, 'Carrier slip detector (Stage~73)', ...
        CE.esc_(strrep(slipMeth73_,'_','\_')));
    CE.writeQuantRow_(fid, 'Product epoch boundary events (Stage~73)', ...
        sprintf('%s compensated / %s total', CE.fmtN_(nProdCmp73_), CE.fmtN_(nProdBnd73_)));
    if isfield(summary,'nConfirmedCarrierSlips') && summary.nConfirmedCarrierSlips == 0
        CE.writeQuantRow_(fid, 'Confirmed carrier slips (Stage~73)', ...
            'No confirmed slips in nominal run');
    else
        CE.writeQuantRow_(fid, 'Confirmed carrier slips (Stage~73)', CE.fmtN_(nSlips73_));
    end
    CE.writeQuantRow_(fid, 'False product-boundary resets (Stage~73)', CE.fmtN_(nFalse73_));
    % Stage 74: shared-error covariance rows
    covMode74_  = CE.safeField_(summary, 'covarianceMode', 'diagonalOnly');
    cbcAppl74_  = CE.safeField_(summary, 'codeTowerClockBlockCovarianceApplied', false);
    nBlk74_     = CE.safeField_(summary, 'nCodeClockCovarianceBlocks', 0);
    meanBlk74_  = CE.safeField_(summary, 'meanCodeClockBlockSize', NaN);
    maxBlk74_   = CE.safeField_(summary, 'maxCodeClockBlockSize', NaN);
    carrPol74_  = CE.safeField_(summary, 'carrierTowerClockCovariancePolicy', 'notApplied');
    doppPol74_  = CE.safeField_(summary, 'dopplerClockProductCovariancePolicy', 'simplifiedV1NotApplied');
    spdOk74_    = CE.safeField_(summary, 'sharedErrorCovarianceSPD', true);
    jit74_      = CE.safeField_(summary, 'covarianceJitterAdded', false);
    CE.writeQuantRow_(fid, 'Covariance mode (Stage~74)', CE.esc_(strrep(covMode74_,'_','\_')));
    if cbcAppl74_
        CE.writeQuantRow_(fid, 'Code block covariance (Stage~74)', ...
            sprintf('%d blocks, mean %.0f rows, max %.0f rows', ...
            nBlk74_, meanBlk74_, maxBlk74_));
    else
        CE.writeQuantRow_(fid, 'Code block covariance (Stage~74)', 'fallback: diagonal only');
    end
    CE.writeQuantRow_(fid, 'Carrier $R$ policy (Stage~74)', ...
        CE.esc_(strrep(carrPol74_,'_','\_')));
    CE.writeQuantRow_(fid, 'Doppler $R$ policy (Stage~74/83)', ...
        CE.esc_(strrep(doppPol74_,'_','\_')));
    jitStr74_ = ''; if jit74_; jitStr74_ = ' (jitter added)'; end
    CE.writeQuantRow_(fid, '$R$ symmetric PD (Stage~74)', ...
        sprintf('%s%s', mat2str(spdOk74_), jitStr74_));
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

    % Honest whole-run caveat: the "Final sample" / final-20-epoch numbers can read
    % as converged even when the estimate wanders for most of the run, because in this
    % single-asset ground-tower geometry the receiver clock and the nadir position are
    % near-degenerate (weak observability). Surface the whole-run median/max and the
    % position<->clock error coupling so the report cannot overstate convergence.
    posMedH   = CE.safeField_(summary, 'positionErrorMedian_m', NaN);
    posMaxH   = CE.safeField_(summary, 'positionErrorMax_m',    NaN);
    finalRmsH = CE.safeField_(summary, 'finalPositionRMS_m',    NaN);
    pcCorrH   = CE.safeField_(summary, 'positionClockErrorCorr', NaN);
    if isfinite(posMedH) && isfinite(finalRmsH)
        fprintf(fid, ['\\vspace{0.15cm}\n\\noindent \\textit{Whole-run vs final window: 3D position ' ...
            'error is %s median (max %s) over the whole run, versus %s RMS over the final 20 epochs. ' ...
            'The position$\\leftrightarrow$clock error correlation is %+.2f --- in this single-asset ' ...
            'ground-tower geometry the receiver clock and the nadir position are near-degenerate ' ...
            '(weak observability), so the final-window figure understates the whole-run error.}\n\n'], ...
            CE.fmtM_(posMedH), CE.fmtM_(posMaxH), CE.fmtM_(finalRmsH), pcCorrH);
    end

    % Version and test status note
    testLines = revgnss.ReportStatus.summaryLines();
    if ~isempty(testLines)
        fprintf(fid, '\\vspace{0.2cm}\n\\noindent \\textit{%s}\n\n', ...
            CE.esc_(testLines{1}));
    end
    fprintf(fid, ['\\noindent \\textit{Scientific limitations (v1): ' ...
        'tower clock correction is synthetic product-prediction (Stage 71); ' ...
        'code $R$ uses block covariance for same-tower rows (Stage 74): ' ...
        'shared product-clock error modelled as off-diagonal; ' ...
        'carrier $R$ not inflated (float ambiguity absorbs constant arc bias; ' ...
        'time-varying product error not fully modelled); ' ...
        'Doppler clock-drift $\\sigma$ simplified v1 (no shared product-drift covariance); ' ...
        'NIS is partially covariance-aware: carrier and Doppler product correlations remain simplified; ' ...
        'carrier slip detection is model-step-compensated (Stage 73): product epoch steps removed from slip statistic, ' ...
        'DiffAtt slip detection disabled per Stage 69 design (innovation gate only); ' ...
        'no synthetic cycle-slip guarantee; v1 robustness demonstration only; ' ...
        'baseline differential integer fixing implemented (Stage 70); ' ...
        'no LAMBDA/MLAMBDA, no WL/NL, no carrier-IF integer fixing; ' ...
        'Stage 75 ambiguity hardening: per-baseline classification, float-distance gate ($|\\hat{N}-N_{\\mathrm{best}}|<0.25$ cyc), ' ...
        'ratio test tightened to 3.0, arc gate 60 epochs; ' ...
        'GNSS-only attitude claim requires all baselines fixed with no external-reference calibration; ' ...
        'phase bias not independently calibrated (\\texttt{notCalibratedExternalProduct}); ' ...
        'false-fix risk classification is \\texttt{screenedNotFormal} (no LAMBDA/ILS); ' ...
        'no real CLK product ingestion, no PPP-grade accuracy, no ANTEX/IONEX/SP3/CLK parsers. ' ...
        'Full validation suite NOT RUN (targeted random smoke only).}\n\n']);
end
