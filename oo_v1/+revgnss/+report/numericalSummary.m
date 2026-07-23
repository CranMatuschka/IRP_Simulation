function numericalSummary(fid, cfg, summary, diag)
%NUMERICALSUMMARY  "Numerical Summary" report section.
%   Extracted verbatim from ClockExactReportBuilder.writeNumericalSummary_ as part
%   of the report decomposition. Read-only: consumes only the precomputed plotPaths
%   + figure dir and the (now-public) ClockExactReportBuilder formatting toolkit. The
%   emitted LaTeX is byte-identical to the original method (verified by the normalized
%   .tex diff harness, tests/report/reportTexFingerprint.m).
    CE = revgnss.ClockExactReportBuilder;
    fprintf(fid, '\\section{Scientific Verdict}\n');
    fprintf(fid, ['This section summarises estimator performance against the known synthetic truth. ' ...
        'The final-sample values are endpoint diagnostics; do not use them alone to rank ' ...
        'performance. Run-level statistics below cover the full record and the final window. ' ...
        'All results are for the controlled synthetic scenario only and are not a real-data or ' ...
        'PPP-grade performance claim.\n\n']);

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
    % Slip detection diagnostics
    slipMeth73_ = CE.safeField_(summary, 'carrierSlipDetectorMethod', 'rawResidualJump');
    nProdBnd73_ = CE.safeField_(summary, 'nCarrierProductBoundaries', NaN);
    nProdCmp73_ = CE.safeField_(summary, 'nCarrierProductBoundariesCompensated', NaN);
    nSlips73_   = CE.safeField_(summary, 'nConfirmedCarrierSlips', NaN);
    nFalse73_   = CE.safeField_(summary, 'nFalseProductBoundaryResets', NaN);
    CE.writeQuantRow_(fid, 'Carrier slip detector', ...
        CE.esc_(revgnss.ReportLabel.humanize(slipMeth73_)));
    CE.writeQuantRow_(fid, 'Product epoch boundary events', ...
        sprintf('%s compensated / %s total', CE.fmtN_(nProdCmp73_), CE.fmtN_(nProdBnd73_)));
    if isfield(summary,'nConfirmedCarrierSlips') && summary.nConfirmedCarrierSlips == 0
        CE.writeQuantRow_(fid, 'Confirmed carrier slips', ...
            'No confirmed slips in nominal run');
    else
        CE.writeQuantRow_(fid, 'Confirmed carrier slips', CE.fmtN_(nSlips73_));
    end
    CE.writeQuantRow_(fid, 'False product-boundary resets', CE.fmtN_(nFalse73_));
    % Shared-error covariance rows
    covMode74_  = CE.safeField_(summary, 'covarianceMode', 'diagonalOnly');
    cbcAppl74_  = CE.safeField_(summary, 'codeTowerClockBlockCovarianceApplied', false);
    nBlk74_     = CE.safeField_(summary, 'nCodeClockCovarianceBlocks', 0);
    meanBlk74_  = CE.safeField_(summary, 'meanCodeClockBlockSize', NaN);
    maxBlk74_   = CE.safeField_(summary, 'maxCodeClockBlockSize', NaN);
    carrPol74_  = CE.safeField_(summary, 'carrierTowerClockCovariancePolicy', 'notApplied');
    doppPol74_  = CE.safeField_(summary, 'dopplerClockProductCovariancePolicy', 'simplifiedV1NotApplied');
    spdOk74_    = CE.safeField_(summary, 'sharedErrorCovarianceSPD', true);
    jit74_      = CE.safeField_(summary, 'covarianceJitterAdded', false);
    CE.writeQuantRow_(fid, 'Covariance mode', CE.esc_(revgnss.ReportLabel.humanize(covMode74_)));
    if cbcAppl74_
        CE.writeQuantRow_(fid, 'Code block covariance', ...
            sprintf('%d blocks, mean %.0f rows, max %.0f rows', ...
            nBlk74_, meanBlk74_, maxBlk74_));
    else
        CE.writeQuantRow_(fid, 'Code block covariance', 'fallback: diagonal only');
    end
    CE.writeQuantRow_(fid, 'Carrier $R$ policy', ...
        CE.esc_(revgnss.ReportLabel.humanize(carrPol74_)));
    CE.writeQuantRow_(fid, 'Doppler $R$ policy', ...
        CE.esc_(revgnss.ReportLabel.humanize(doppPol74_)));
    jitStr74_ = ''; if jit74_; jitStr74_ = ' (jitter added)'; end
    CE.writeQuantRow_(fid, '$R$ symmetric positive-definite', ...
        sprintf('%s%s', CE.yesNo_(logical(spdOk74_),'yes','no'), jitStr74_));
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
end
