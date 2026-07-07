function clockObservability(fid, diag, cfg)
%CLOCKOBSERVABILITY  "Clock Observability and Gauge Validation" report section (Phase 7).
%   Extracted verbatim from ClockExactReportBuilder.writeClockObservability_ as part
%   of the C-9 report decomposition. Read-only: consumes only the precomputed plotPaths
%   + figure dir and the (now-public) ClockExactReportBuilder formatting toolkit. The
%   emitted LaTeX is byte-identical to the original method (verified by the normalized
%   .tex diff harness, tests/report/reportTexFingerprint.m).
    CE = revgnss.ClockExactReportBuilder;

    fprintf(fid, '\\section{Clock Observability and Gauge Validation}\n');
    fprintf(fid, CE.plotTableHeader_());

    gaugeMd = CE.getCfgStr_(cfg, {'clock','gauge','mode'}, 'externalTowerCorrections');
    clkMd   = CE.getCfgStr_(cfg, {'clock','mode'}, 'spacecraftReceiverClockOnly');

    % --- Background ---------------------------------------------------
    fprintf(fid, ['\\multicolumn{2}{|p{\\linewidth}|}{\\textbf{Background.} ' ...
        'One-way pseudorange is insensitive to \\emph{two} persistent common-mode perturbations: ' ...
        '(a) a common bias shift added simultaneously to all clock biases, and ' ...
        '(b) a common drift shift added simultaneously to all clock drifts. ' ...
        'Both null vectors persist for all observation epochs regardless of tower count. ' ...
        'The physical observability Gramian therefore has rank at most $n_{\\text{clk}}-2$. ' ...
        'A gauge constraint (\\texttt{fixReferenceTower} or \\texttt{meanGroundClockGauge}) ' ...
        'pins both the bias and drift of the datum tower, removing both null modes and ' ...
        'lifting the gauged Gramian $W_{\\text{gauged}}$ to full rank $n_{\\text{clk}}$.} \\\\ \\hline\n']);

    % --- Gauge mode ---------------------------------------------------
    switch gaugeMd
        case 'fixReferenceTower'
            refTwr = CE.getCfgNum_(cfg, {'clock','gauge','referenceTowerIndex'}, 1);
            sigB   = CE.getCfgNum_(cfg, {'clock','gauge','sigmaBias_m'}, 1e-6);
            sigD   = CE.getCfgNum_(cfg, {'clock','gauge','sigmaDrift_mps'}, 1e-9);
            gaugeStr = sprintf(['\\texttt{fixReferenceTower} (tower~%d). ' ...
                'EKF pseudo-measurements pin tower~%d clock bias and drift to zero ' ...
                'with $\\sigma_{\\rm bias}=%g$\\,m and $\\sigma_{\\rm drift}=%g$\\,m/s. ' ...
                'The reference tower absorbs the common-bias datum.'], ...
                refTwr, refTwr, sigB, sigD);
        case 'meanGroundClockGauge'
            sigB   = CE.getCfgNum_(cfg, {'clock','gauge','sigmaBias_m'}, 1e-6);
            sigD   = CE.getCfgNum_(cfg, {'clock','gauge','sigmaDrift_mps'}, 1e-9);
            gaugeStr = sprintf(['\\texttt{meanGroundClockGauge}. ' ...
                'EKF pseudo-measurements constrain the mean of all tower clock biases ' ...
                'and drifts to zero ($\\sigma_{\\rm bias}=%g$\\,m, ' ...
                '$\\sigma_{\\rm drift}=%g$\\,m/s). ' ...
                'This spreads the datum symmetrically across all towers.'], sigB, sigD);
        case 'externalTowerCorrections'
            % Stage 72: distinguish product-corrected from perfect/noisy.
            % Read mode from cfg (summary not in scope in this helper).
            tClkMdG_ = models.clocks.TowerClockCorrectionProvider.towerClockMode(cfg);
            if strcmp(tClkMdG_, 'truthHistoryProductNoisy')
                diagInfl_ = true;  % Stage 72: diagonal per-row code-R only
                gaugeStr = ['\texttt{externalTowerCorrections} (product-corrected). ' ...
                    'Tower clocks corrected by synthetic product predictions (Stage~72): ' ...
                    'delayed/quantised product epoch, per-product deterministic noise, ' ...
                    'linear prediction to measurement time. ' ...
                    'Receiver clock bias/drift estimated in EKF; ' ...
                    'tower clock states NOT estimated to avoid gauge ambiguity. ' ...
                    'Code $R$ inflated by product $\sigma$' ...
                    CE.yesNo_(diagInfl_, ' (diagonal per-row)', '') ...
                    '; carrier $R$ unchanged (float ambiguity absorbs constant-per-arc bias).'];
            else
                gaugeStr = ['\texttt{externalTowerCorrections}. ' ...
                    'Tower clock biases provided externally (truth-plus-noise); ' ...
                    'no gauge pseudo-measurements added to the EKF. ' ...
                    'The clock nullspace is resolved by assumption, not by constraint.'];
            end
        otherwise
            gaugeStr = sprintf('Gauge mode: \\texttt{%s} (spacecraft receiver clock only; no tower clocks in EKF).', ...
                CE.esc_(gaugeMd));
    end
    CE.writeRow_(fid, '', 'Clock Gauge Mode', gaugeStr);

    % --- Windowed Gramian results ----------------------------------
    rankPhy  = diag.getClockObsRankPhysical();
    rankGau  = diag.getClockObsRankGauged();
    condPhy  = diag.getClockObsCondPhysical();
    condGau  = diag.getClockObsCondGauged();
    weakPhy  = diag.getClockObsWeakStatesPhysical();
    weakGau  = diag.getClockObsWeakStatesGauged();

    finPhy = rankPhy(isfinite(rankPhy));
    finGau = rankGau(isfinite(rankGau));

    if isempty(finPhy)
        CE.writeRow_(fid, '', 'Clock Observability Gramian', ...
            ['Windowed Gramian not computed (fewer epochs than \\texttt{minWindowEpochs} ' ...
             'or clock states not in EKF).']);
    else
        mRkPhy = median(finPhy);
        mRkGau = median(finGau(isfinite(finGau)));
        mCdPhy = median(condPhy(isfinite(condPhy) & condPhy > 0));
        mCdGau = median(condGau(isfinite(condGau) & condGau > 0));
        mWkPhy = median(weakPhy(isfinite(weakPhy)));
        mWkGau = median(weakGau(isfinite(weakGau)));

        gramStr = sprintf(['Median physical rank~$%g$, median gauged rank~$%g$. ' ...
            'Median condition: physical~$%.1e$, gauged~$%.1e$. ' ...
            'Weak states (physical/gauged): $%g$ / $%g$.'], ...
            mRkPhy, mRkGau, mCdPhy, mCdGau, mWkPhy, mWkGau);

        % Scientific interpretation
        if mWkGau == 0 && mWkPhy > 0
            gramStr = [gramStr, ' The gauge successfully eliminates all weak clock states: ' ...
                'the gauged Gramian achieves full rank.'];
        elseif mWkGau > 0
            gramStr = [gramStr, sprintf(' \\textbf{Warning:} %g weak state(s) remain after gauging. ', mWkGau), ...
                'The gauge may not fully constrain the clock nullspace over this window.'];
        elseif mWkPhy == 0 && ~strcmp(clkMd,'includeTowerClocksInEKF')
            gramStr = [gramStr, ' No tower clock states in EKF: spacecraft receiver ' ...
                'clock is fully observable via multi-tower geometry.'];
        end
        CE.writeRow_(fid, '', 'Clock Observability Gramian', gramStr);
    end

    % --- NIS confirmation ----------------------------------------
    gaugeRows = diag.getClockGaugeRowsAdded();
    biasRes   = diag.getClockGaugeBiasResiduals();
    finBR     = biasRes(isfinite(biasRes));
    if ~isempty(finBR) && max(gaugeRows) > 0
        mBR = median(abs(finBR));
        CE.writeRow_(fid, '', 'Gauge Residuals', ...
            sprintf(['Median gauge bias residual~$%.2e$\\,m. ' ...
            'Values near zero confirm the gauge constraint is numerically effective.'], mBR));
    end

    fprintf(fid, CE.plotTableFooter_());
    fprintf(fid, '\\clearpage\n');
end
