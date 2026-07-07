function txCodeBias(fid, diag, cfg)
% txCodeBias  Report section for per-tower L1 transmitter code hardware delays.
%
% Only printed when cfg.hardware.txCodeBias.enable == true.
% Shows gauge type, gauge residual convergence, and number of states.
%
% Extracted verbatim from ClockExactReportBuilder.writeTxCodeBias_ as part
% of the C-9 report decomposition (Phase 7). Read-only: consumes only the
% (now-public) ClockExactReportBuilder formatting toolkit. The emitted LaTeX
% is byte-identical to the original method (verified by the normalized .tex
% diff harness, tests/report/reportTexFingerprint.m).

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
