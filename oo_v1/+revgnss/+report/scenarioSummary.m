function scenarioSummary(fid, cfg, summary, diag, nTwr, nRx, dur, dt, esc)
%SCENARIOSUMMARY  "Scenario Summary" report section (Phase 7).
%   Extracted verbatim from ClockExactReportBuilder.writeScenarioSummary_ as part
%   of the C-9 report decomposition. Read-only: consumes only the precomputed plotPaths
%   + figure dir and the (now-public) ClockExactReportBuilder formatting toolkit. The
%   emitted LaTeX is byte-identical to the original method (verified by the normalized
%   .tex diff harness, tests/report/reportTexFingerprint.m).
%   NOTE: writeComponentRows_ is intentionally NOT extracted (left as a public
%   method on ClockExactReportBuilder) and is invoked below via CE.writeComponentRows_.
    CE = revgnss.ClockExactReportBuilder;

    scenarioName = CE.getCfgStr_(cfg, {'asset','name'}, 'GEO-1');
    codeMode = CE.getCfgStr_(cfg, {'measurements','codeMode'},   'singleFrequency');
    carrMode = CE.getCfgStr_(cfg, {'measurements','carrierMode'}, 'diagnostic');
    clkMode  = CE.getCfgStr_(cfg, {'estimator','towerClockMode'}, 'perfectTruth');
    L = @revgnss.ReportLabel.humanize;

    fprintf(fid, '\\section{Goal and Scenario}\n');
    fprintf(fid, ['The goal of this simulation is to evaluate whether a single GEO-class space asset can ' ...
        'estimate its orbit, receiver clock, and selected auxiliary states from synthetic reverse-GNSS ' ...
        'measurements transmitted by a small ground network. The report compares the estimator against the ' ...
        'known synthetic truth and summarises the measurement geometry, stochastic assumptions, and residual ' ...
        'consistency. Results are valid for this controlled synthetic scenario only and are not a PPP-grade ' ...
        'or real-data performance claim. ' ...
        'The run length is %.2f hours (%.0f s) with %.1f s sampling.\n\n'], dur/3600, dur, dt);

    % Scenario table (values from cfg/summary; internal modes humanised)
    orbitClass = CE.getCfgStr_(cfg, {'scenario','orbitClass'}, 'GEO');
    nSA        = CE.getCfgNum_(cfg, {'scenario','nSpaceAssets'}, 1);
    seedV      = CE.getCfgNum_(cfg, {'simulation','seed'}, 42);
    verS       = CE.getCfgStr_(cfg, {'report','version'}, '1.00');
    dopEnabled = CE.getLogical_(cfg, {'measurements','doppler','enable'}, false);
    families   = {L(codeMode)};
    if ~isempty(carrMode) && ~strcmp(carrMode,'off'); families{end+1} = L(carrMode); end
    if dopEnabled; families{end+1} = 'Doppler'; end
    famStr = strjoin(families, ', ');
    fprintf(fid, '\\begin{center}\\small\n');
    fprintf(fid, '\\begin{tabular}{p{0.40\\textwidth}p{0.50\\textwidth}}\n\\toprule\n');
    fprintf(fid, '\\textbf{Metric} & \\textbf{Value}\\\\\n\\midrule\n');
    fprintf(fid, 'Baseline requirement & Single GEO asset reverse-GNSS estimation scenario\\\\\n');
    fprintf(fid, 'Orbit class & %s\\\\\n', esc(revgnss.ReportLabel.orbitClassLabel(orbitClass)));
    fprintf(fid, 'Space assets & %d\\\\\n', nSA);
    fprintf(fid, 'Ground transmitters & %d\\\\\n', nTwr);
    fprintf(fid, 'On-board receivers & %d\\\\\n', nRx);
    fprintf(fid, 'Enabled measurement families & %s\\\\\n', esc(famStr));
    fprintf(fid, 'Synthetic random seed & %d\\\\\n', seedV);
    fprintf(fid, 'Simulation duration & %.0f s (%.2f h)\\\\\n', dur, dur/3600);
    fprintf(fid, 'Validation version & %s\\\\\n', esc(verS));
    fprintf(fid, '\\bottomrule\n\\end{tabular}\n\\end{center}\n\n');

    % Coordinate frames and units
    fprintf(fid, '\\subsection{Coordinate Frames and Units}\n');
    fprintf(fid, '\\begin{center}\\small\n');
    fprintf(fid, '\\begin{tabular}{p{0.16\\textwidth}p{0.74\\textwidth}}\n\\toprule\n');
    fprintf(fid, '\\textbf{Frame} & \\textbf{Use}\\\\\n\\midrule\n');
    fprintf(fid, 'ECI & Orbit propagation and the radial/along-track/cross-track post-processing reference.\\\\\n');
    fprintf(fid, 'ECEF & Ground transmitter coordinates, receiver phase centres, line-of-sight geometry, and measurement rows.\\\\\n');
    fprintf(fid, 'RAC & Radial, along-track, and cross-track decomposition of the estimate-minus-truth position error.\\\\\n');
    fprintf(fid, 'Body & Attitude error-state and antenna lever-arm interpretation.\\\\\n');
    fprintf(fid, 'Clock units & Clock bias in metres and seconds; clock drift in m/s and s/s.\\\\\n');
    fprintf(fid, '\\bottomrule\n\\end{tabular}\n\\end{center}\n\n');

    % 1.1 Receiver Clock Architecture
    fprintf(fid, '\\subsection{Receiver Clock Architecture Interpretation}\n');
    fprintf(fid, ['Receiver clock bias $b_{rx}$ has a \\textbf{positive} sign ' ...
        '(adds to pseudorange). ' ...
        'Tower transmitter clock bias $b_{twr}$ has a \\textbf{negative} sign ' ...
        '(subtracts from pseudorange). ' ...
        'Troposphere delay $T$ is \\textbf{positive} for both code and carrier. ' ...
        'Ionosphere delay $I_f$ is \\textbf{positive} for code (group delay) and ' ...
        '\\textbf{negative} for carrier (phase advance). ' ...
        'Carrier ambiguity $B_\\phi$ is a float value in metres (raw L1, no integer fixing).\n\n']);
    % Clock mode / gauge summary (Stage 9: per-mode scientific narrative)
    clockMd1  = CE.getCfgStr_(cfg, {'clock','mode'}, 'spacecraftReceiverClockOnly');
    gaugeMd1  = CE.getCfgStr_(cfg, {'clock','gauge','mode'}, 'externalTowerCorrections');
    refTwr1   = CE.getCfgNum_(cfg, {'clock','gauge','referenceTowerIndex'}, 1);
    sigBias1  = CE.getCfgNum_(cfg, {'clock','gauge','sigmaBias_m'},    1e-6);
    sigDrift1 = CE.getCfgNum_(cfg, {'clock','gauge','sigmaDrift_mps'}, 1e-9);
    fprintf(fid, ['\\textbf{Clock architecture:} %s. ' ...
        '\\textbf{Clock gauge:} %s.\n\n'], esc(L(clockMd1)), esc(L(gaugeMd1)));
    if strcmp(clockMd1,'spacecraftReceiverClockOnly')
        fprintf(fid, ['Tower clock states are not included in the EKF. ' ...
            'The EKF estimates the spacecraft receiver clock only. ' ...
            'One-way pseudorange is gauge-ambiguous: $b_{rx}$ and $b_{twr}$ cannot be ' ...
            'separated without an external datum or gauge constraint; here the gauge ' ...
            'is resolved by external tower clock corrections.\n\n']);
    elseif strcmp(gaugeMd1,'fixReferenceTower')
        fprintf(fid, ['\\textbf{Gauge -- fixReferenceTower (tower %d):} ' ...
            'The selected reference tower defines the ground clock gauge. ' ...
            'Its tower clock bias and drift are constrained to zero by EKF ' ...
            'pseudo-measurement rows ($\\sigma_{bias}=%g$\\,m, ' ...
            '$\\sigma_{drift}=%g$\\,m/s). ' ...
            'All receiver and tower clock estimates are therefore relative to ' ...
            'this tower timescale. ' ...
            'Pseudo-measurement: $z=0$, $h=\\hat{b}_{twr,ref}$, ' ...
            '$H_{gauge}(b_{twr,ref})=1$, $R_{gauge}=\\sigma_{bias}^2$.\n\n'], ...
            refTwr1, sigBias1, sigDrift1);
    elseif strcmp(gaugeMd1,'meanGroundClockGauge')
        fprintf(fid, ['\\textbf{Gauge -- meanGroundClockGauge:} ' ...
            'The mean of all estimated tower clocks defines the ground clock gauge. ' ...
            'The EKF inserts zero-mean pseudo-measurement rows for tower clock bias ' ...
            '($\\sigma_{bias}=%g$\\,m) and drift ($\\sigma_{drift}=%g$\\,m/s). ' ...
            'The spacecraft receiver clock is therefore estimated relative to the ' ...
            'mean ground-clock timescale. ' ...
            'Pseudo-measurement: $z=0$, $h=\\frac{1}{N}\\sum_i \\hat{b}_{twr,i}$, ' ...
            '$H_{gauge}(b_{twr,i})=\\frac{1}{N}$, $R_{gauge}=\\sigma_{bias}^2$.\n\n'], ...
            sigBias1, sigDrift1);
    else
        fprintf(fid, ['One-way pseudorange is gauge-ambiguous: $b_{rx}$ and $b_{twr}$ ' ...
            'cannot be separated without an external datum or gauge constraint. ' ...
            'The gauge mode specifies how this datum ambiguity is resolved.\n\n']);
    end

    % 1.2 Scenario Geometry
    fprintf(fid, '\\subsection{Scenario Geometry and Receiver Architecture}\n');
    fprintf(fid, ['Truth pseudorange: ' ...
        '$P = \\|\\mathbf{r}_{sc} + \\mathbf{C}_{BI}\\mathbf{l}_{a,B} - \\mathbf{r}_{twr}\\|' ...
        '+ b_{rx}^{true} - b_{twr}^{true} + d_{truth} + \\nu$. ' ...
        'Estimator prediction: $\\hat{P} = \\|\\hat{\\mathbf{r}}_{sc} + \\hat{\\mathbf{C}}_{BI}' ...
        '\\mathbf{l}_{a,B} - \\mathbf{r}_{twr}\\| + \\hat{b}_{rx} + d_{model}$. ' ...
        'Range geometry uses ECEF positions at the receiver epoch. ' ...
        'Optional light-time and Sagnac corrections are applied when enabled.\n\n']);

    % 1.3 State Vector — compact grouped table (ranges from active EKF config)
    fprintf(fid, '\\subsection{State Vector}\n');
    fprintf(fid, ['The filter is an error-state EKF. The 14 base states are grouped below; optional ' ...
        'blocks are appended when active. Index ranges are computed from the active filter ' ...
        'configuration, not hard-coded.\n\n']);
    doTwrClk = isfield(cfg,'estimator') && isfield(cfg.estimator,'estimateTowerClocks') ...
        && cfg.estimator.estimateTowerClocks;
    doAmb = isfield(cfg,'measurements') && isfield(cfg.measurements,'carrierMode') ...
        && strcmp(cfg.measurements.carrierMode,'ekfFloat');
    ambMode = CE.getCfgStr_(cfg, {'estimation','ambiguityMode'}, 'none');
    doZwd = isfield(cfg,'estimation') && isfield(cfg.estimation,'troposphereMode') ...
        && strcmp(cfg.estimation.troposphereMode,'perTowerZwd');
    fprintf(fid, '\\begin{center}\\small\n');
    fprintf(fid, ['\\begin{longtable}{@{}>{\\raggedright\\arraybackslash}p{0.21\\textwidth}' ...
        '>{\\raggedright\\arraybackslash}p{0.12\\textwidth}' ...
        '>{\\raggedright\\arraybackslash}p{0.05\\textwidth}' ...
        '>{\\raggedright\\arraybackslash}p{0.10\\textwidth}' ...
        '>{\\raggedright\\arraybackslash}p{0.36\\textwidth}@{}}\n']);
    fprintf(fid, '\\toprule\n');
    fprintf(fid, '\\textbf{State group} & \\textbf{Indices} & \\textbf{Dim} & \\textbf{Unit} & \\textbf{Description}\\\\\n\\midrule\n');
    fprintf(fid, 'position & x[1:3] & 3 & m & spacecraft position error (RAC/ECEF as configured)\\\\\n');
    fprintf(fid, 'velocity & x[4:6] & 3 & m/s & spacecraft velocity error\\\\\n');
    fprintf(fid, 'attitude & x[7:9] & 3 & rad & small-angle body attitude error\\\\\n');
    fprintf(fid, 'angular rate & x[10:12] & 3 & rad/s & body angular-rate error\\\\\n');
    fprintf(fid, 'receiver clock bias & x[13] & 1 & m & receiver clock bias (positive sign)\\\\\n');
    fprintf(fid, 'receiver clock drift & x[14] & 1 & m/s & receiver clock drift\\\\\n');
    idxEnd = 14;
    if doTwrClk
        nB = 2*nTwr; a = idxEnd+1; b = idxEnd+nB; idxEnd = b;
        fprintf(fid, 'tower clocks & x[%d:%d] & %d & m, m/s & per-tower clock bias and drift (negative sign in measurement)\\\\\n', a, b, nB);
    end
    if doAmb
        if strcmp(ambMode,'floatPerTowerReceiverSignal'); nB = nTwr*nRx; else; nB = nTwr; end
        a = idxEnd+1; b = idxEnd+nB; idxEnd = b;
        fprintf(fid, 'float ambiguities & x[%d:%d] & %d & m & one float carrier ambiguity per active tower/receiver/signal arc\\\\\n', a, b, nB);
    end
    if doZwd
        nB = nTwr; a = idxEnd+1; b = idxEnd+nB; idxEnd = b;
        fprintf(fid, 'zenith wet delay & x[%d:%d] & %d & m & per-tower zenith wet delay residual\\\\\n', a, b, nB);
    end
    fprintf(fid, '\\midrule\n');
    fprintf(fid, '\\textbf{total} & x[1:%d] & %d & --- & active EKF state dimension\\\\\n', idxEnd, idxEnd);
    fprintf(fid, '\\bottomrule\n\\end{longtable}\n\\end{center}\n');

    % 1.5 Measurement Model Equations
    fprintf(fid, '\\subsection{Measurement Model Equations}\n');
    % Signal frequencies for the ionosphere-free combination (no hardcoded constants).
    sd78_L1_ = revgnss.SignalDefinition.get('L1');
    sd78_L2_ = revgnss.SignalDefinition.get('L2');
    f1 = sd78_L1_.frequency_Hz;
    f2 = sd78_L2_.frequency_Hz;
    alpha =  f1^2 / (f1^2 - f2^2);
    beta  = -f2^2 / (f1^2 - f2^2);
    fprintf(fid, ['\\begin{align*}\n' ...
        '\\rho_{\\mathrm{code}} &= \\rho_{\\mathrm{geom}} + b_{\\mathrm{rx}} - b_{\\mathrm{tx}} + T + I_{\\mathrm{code}} ' ...
        '+ \\Delta_{\\mathrm{sagnac}} + \\Delta_{\\mathrm{rel}} + \\Delta_{\\mathrm{ant}} + B_{\\mathrm{code}} + M + \\epsilon_\\rho \\\\\n' ...
        '\\Phi &= \\rho_{\\mathrm{geom}} + b_{\\mathrm{rx}} - b_{\\mathrm{tx}} + T + I_{\\mathrm{carrier}} ' ...
        '+ \\Delta_{\\mathrm{sagnac}} + \\Delta_{\\mathrm{rel}} + \\Delta_{\\mathrm{ant}} + N_{a,r,s} + B_\\phi + M + \\epsilon_\\phi \\\\\n' ...
        'D &= \\dot{\\rho} + \\dot{b}_{\\mathrm{rx}} - \\dot{b}_{\\mathrm{tx}} + \\dot{\\Delta}_{\\mathrm{corr}} + \\epsilon_D \\\\\n' ...
        '\\nu &= z - h(\\hat{x}^{-})\n' ...
        '\\end{align*}\n']);
    % Inter-satellite link rows (active only in the multi-asset / swarm scenario).
    fprintf(fid, ['\\begin{align*}\n' ...
        '\\rho_{\\mathrm{ISL}} &= \\lVert \\mathbf{r}_{\\mathrm{sc}} - \\mathbf{r}_{j} \\rVert + b_{\\mathrm{rx}} - b_{j} + \\epsilon_{\\mathrm{ISL}} \\\\\n' ...
        'D_{\\mathrm{ISL}} &= \\mathbf{u}_{\\mathrm{sc},j}^{\\top}(\\mathbf{v}_{\\mathrm{sc}} - \\mathbf{v}_{j}) + \\dot{b}_{\\mathrm{rx}} - \\dot{b}_{j} + \\epsilon_{D,\\mathrm{ISL}}\n' ...
        '\\end{align*}\n']);
    fprintf(fid, ['{\\footnotesize The inter-satellite link (ISL) rows apply only when the multi-asset ' ...
        'swarm scenario is enabled: $j$ is a neighbouring space asset and $\\mathbf{u}_{\\mathrm{sc},j}$ is the ' ...
        'inter-asset line of sight. The ionosphere-free code combination is ' ...
        '$P_{\\mathrm{IF}} = \\alpha P_{L1} + \\beta P_{L2}$ with $\\alpha=%.4f$, $\\beta=%.4f$.}\n\n'], alpha, beta);
    % Observability rank (position + clock geometry) measured from the run.
    grStr = 'not available';
    try
        gr = diag.getGeometryRank(); gr = gr(isfinite(gr));
        if ~isempty(gr); grStr = sprintf('%.1f of 4 (median over the run)', median(gr)); end
    catch; end
    fprintf(fid, ['\\noindent \\textbf{Observable rank:} the position and clock geometry rank is %s --- ' ...
        'i.e.\\ how many of the four position/clock directions the pseudorange geometry constrains at each epoch. ' ...
        'A full rank of~4 can coexist with a very large DOP when the line-of-sight directions are nearly parallel.\n\n'], grStr);

    fprintf(fid, '\\begin{center}\n\\scriptsize\n');
    fprintf(fid, ['\\begin{longtable}{@{}>{\\raggedright\\arraybackslash}p{0.273\\textwidth}' ...
        '>{\\raggedright\\arraybackslash}p{0.273\\textwidth}' ...
        '>{\\raggedright\\arraybackslash}p{0.273\\textwidth}@{}}\n']);
    fprintf(fid, '\\toprule\n');
    fprintf(fid, '\\textbf{Term} & \\textbf{Expression} & \\textbf{Meaning}\\\\\n');
    fprintf(fid, '\\midrule\n');
    termRows = { ...
        'geometric range', '$\rho = \|\mathbf{r}_{sc} + \mathbf{C}_{BI}\mathbf{l}_{a,B} - \mathbf{r}_{twr}\|$', 'Phase-centre to tower range'; ...
        'receiver clock', '$+b_{rx}$ [m] (POSITIVE sign)', 'Shared spacecraft RX clock bias'; ...
        'tower clock', '$-b_{twr}$ [m] (NEGATIVE sign)', 'Ground transmitter clock bias'; ...
        'troposphere', '$+T$ (code and carrier, POSITIVE)', 'Slant wet+dry delay, same sign'; ...
        'iono code', '$+I_f$ (POSITIVE for code)', 'First-order group delay'; ...
        'iono carrier', '$-I_f$ (NEGATIVE for carrier)', 'First-order phase advance'; ...
        'float ambiguity', '$+B_\phi$ [m] (L1 only)', 'L1 carrier cycle ambiguity, float'; ...
        'measurement noise', '$\nu \sim N(0, R)$', 'Code / carrier / Doppler noise'; ...
    };
    for k = 1:size(termRows,1)
        fprintf(fid, '%s & %s & %s\\\\\n', termRows{k,:});
    end
    fprintf(fid, '\\bottomrule\n\\end{longtable}\n\\normalsize\n\\end{center}\n');

    % 1.4b Measurement configuration and error budget (values from cfg)
    fprintf(fid, '\\subsection{Measurement Noise and Error Budget}\n');
    codeEn   = true;   % code is the baseline observable
    carrEn   = ~isempty(carrMode) && ~strcmp(carrMode,'off') && ~strcmp(carrMode,'none');
    dopEn    = CE.getLogical_(cfg, {'measurements','doppler','enable'}, false);
    codeSig  = CE.getCfgNum_(cfg, {'signals','L1','codeSigma0_m'}, NaN);
    carrSig  = CE.getCfgNum_(cfg, {'measurements','carrier','sigma_m'}, NaN);
    dopSig   = CE.getCfgNum_(cfg, {'measurements','doppler','sigma_mps'}, NaN);
    covFloor = CE.getCfgNum_(cfg, {'measurement','sigmaFloor_m'}, NaN);
    prodCov  = CE.getLogical_(cfg, {'covariance','productClock','enable'}, false);
    shrdCov  = CE.getLogical_(cfg, {'covariance','sharedErrors','enable'}, false);
    E = @revgnss.ReportLabel.enabledLabel;
    fprintf(fid, '\\begin{center}\\small\n');
    fprintf(fid, '\\begin{tabular}{p{0.52\\textwidth}p{0.38\\textwidth}}\n\\toprule\n');
    fprintf(fid, '\\textbf{Measurement model} & \\textbf{Value}\\\\\n\\midrule\n');
    fprintf(fid, 'Code pseudorange & %s\\\\\n', E(codeEn));
    fprintf(fid, 'Carrier phase & %s\\\\\n', E(carrEn));
    fprintf(fid, 'Doppler & %s\\\\\n', E(dopEn));
    fprintf(fid, 'Code noise $\\sigma$ & %s\\\\\n', fmtVal_(codeSig,'m'));
    fprintf(fid, 'Carrier phase $\\sigma$ & %s\\\\\n', fmtVal_(carrSig,'m'));
    fprintf(fid, 'Doppler $\\sigma$ & %s\\\\\n', fmtVal_(dopSig,'m/s'));
    fprintf(fid, 'Measurement covariance floor & %s\\\\\n', fmtVal_(covFloor,'m'));
    fprintf(fid, 'Shared-product covariance & %s\\\\\n', E(prodCov));
    fprintf(fid, 'Shared transmitter-clock covariance & %s\\\\\n', E(shrdCov));
    fprintf(fid, '\\bottomrule\n\\end{tabular}\n\\end{center}\n\n');

    % Error budget (disabled models reported honestly)
    mpEn     = CE.getLogical_(cfg, {'errors','multipath','truth','enable'}, false);
    tropEn   = CE.getLogical_(cfg, {'errors','troposphere','truth','enable'}, false);
    ionoEn   = CE.getLogical_(cfg, {'errors','ionosphere','truth','enable'}, false);
    twrBias  = CE.getCfgNum_(cfg, {'clocks','tower','product','sigmaBias_m'}, NaN);
    twrDrift = CE.getCfgNum_(cfg, {'clocks','tower','product','sigmaDrift_mps'}, NaN);
    mpAmp    = CE.getCfgNum_(cfg, {'errors','multipath','truth','amplitude_m'}, NaN);
    mpSig    = CE.getCfgNum_(cfg, {'errors','multipath','truth','stochastic_sigma_m'}, NaN);
    tropZ    = CE.getCfgNum_(cfg, {'errors','troposphere','truth','zenithWetDelay_m'}, NaN);
    ionoV    = CE.getCfgNum_(cfg, {'errors','ionosphere','truth','verticalDelayL1_m'}, NaN);
    if mpEn;   mpAmpS = fmtVal_(mpAmp,'m'); mpSigS = fmtVal_(mpSig,'m'); else; mpAmpS = 'disabled'; mpSigS = 'disabled'; end
    if tropEn; tropZS = fmtVal_(tropZ,'m'); else; tropZS = 'disabled'; end
    if ionoEn; ionoVS = fmtVal_(ionoV,'m'); else; ionoVS = 'disabled'; end
    fprintf(fid, '\\begin{center}\\small\n');
    fprintf(fid, '\\begin{tabular}{p{0.52\\textwidth}p{0.38\\textwidth}}\n\\toprule\n');
    fprintf(fid, '\\textbf{Error budget} & \\textbf{Value}\\\\\n\\midrule\n');
    fprintf(fid, 'Code thermal $\\sigma$ & %s\\\\\n', fmtVal_(codeSig,'m'));
    fprintf(fid, 'Carrier phase $\\sigma$ & %s\\\\\n', fmtVal_(carrSig,'m'));
    fprintf(fid, 'Doppler $\\sigma$ & %s\\\\\n', fmtVal_(dopSig,'m/s'));
    fprintf(fid, 'Tower clock product $\\sigma$ (bias) & %s\\\\\n', fmtVal_(twrBias,'m'));
    fprintf(fid, 'Tower clock product $\\sigma$ (drift) & %s\\\\\n', fmtVal_(twrDrift,'m/s'));
    fprintf(fid, 'Multipath amplitude & %s\\\\\n', mpAmpS);
    fprintf(fid, 'Multipath stochastic $\\sigma$ & %s\\\\\n', mpSigS);
    fprintf(fid, 'Troposphere zenith wet delay & %s\\\\\n', tropZS);
    fprintf(fid, 'Ionosphere vertical L1 delay & %s\\\\\n', ionoVS);
    fprintf(fid, 'Receiver / transmitter clock process-noise drives & defined in the clock model (Appendix)\\\\\n');
    fprintf(fid, '\\bottomrule\n\\end{tabular}\n\\end{center}\n\n');

    % 1.5 Starting positions
    fprintf(fid, '\\subsection{Starting Positions}\n');
    fprintf(fid, '\\begin{center}\n\\scriptsize\n');
    fprintf(fid, ['\\begin{longtable}{@{}>{\\raggedright\\arraybackslash}p{0.12\\textwidth}' ...
        '>{\\raggedright\\arraybackslash}p{0.14\\textwidth}' ...
        '>{\\raggedright\\arraybackslash}p{0.17\\textwidth}' ...
        '>{\\raggedright\\arraybackslash}p{0.15\\textwidth}' ...
        '>{\\raggedright\\arraybackslash}p{0.15\\textwidth}' ...
        '>{\\raggedright\\arraybackslash}p{0.12\\textwidth}@{}}\n']);
    fprintf(fid, '\\toprule\n');
    fprintf(fid, '\\textbf{Type} & \\textbf{Name} & \\textbf{Frame} & \\textbf{Coord 1} & \\textbf{Coord 2} & \\textbf{Coord 3}\\\\\n');
    fprintf(fid, '\\midrule\n');
    % Asset
    rGeo = zeros(3,1);
    try; rGeo = cfg.asset.r_ecef_m; catch; end
    fprintf(fid, 'Spacecraft & %s & ECEF centre of mass & X %.5g m & Y %.5g m & Z %.5g m\\\\\n', ...
        esc(scenarioName), rGeo(1), rGeo(2), rGeo(3));
    % Towers
    if isfield(cfg,'towers')
        nT = min(nTwr, numel(cfg.towers));
        for k = 1:nT
            tname = ''; lat_d = 0; lon_d = 0; alt_m = 0;
            try; tname = cfg.towers(k).name; catch; end
            try; lat_d = cfg.towers(k).lat_rad * 180/pi; catch; end
            try; lon_d = cfg.towers(k).lon_rad * 180/pi; catch; end
            try; alt_m = cfg.towers(k).alt_m; catch; end
            fprintf(fid, 'Ground tower & %s & Fixed geodetic & Lat %.2f deg & Lon %.2f deg & Alt %.1f m\\\\\n', ...
                esc(tname), lat_d, lon_d, alt_m);
        end
    end
    fprintf(fid, '\\bottomrule\n\\end{longtable}\n\\normalsize\n\\end{center}\n');

    % 1.6 Component Status — compact grouped multi-tables (5 categories)
    CE.writeComponentRows_(fid, cfg, esc);
    fprintf(fid, '\\clearpage\n');
end

function s = fmtVal_(x, unit)
% fmtVal_  Format a configured numeric value, or 'not configured' when absent.
    if ~isfinite(x)
        s = 'not configured';
    else
        s = sprintf('%.4g %s', x, unit);
    end
end
