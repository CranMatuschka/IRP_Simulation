function activePhysicsConfig(fid, cfg, summary, plotPaths, stem, figDir) %#ok<INUSD>
%ACTIVEPHYSICSCONFIG  "Appendix: Simulation Physics and Configuration".
%   Compact provenance appendix placed at the end of the report. Summarises the
%   enabled physical effects, the truth/estimator dynamics families, and the
%   controlled-synthetic scope. Internal mode identifiers are routed through
%   revgnss.ReportLabel so no raw CamelCase config string reaches the reader.
    CE = revgnss.ClockExactReportBuilder;
    if ~isfield(summary,'physicsConfigSectionActive') || ~summary.physicsConfigSectionActive; return; end
    H  = @(s) CE.esc_(revgnss.ReportLabel.humanize(s));   % escaped human label
    F  = @(f,d) CE.safeField_(summary, f, d);
    Y  = @(b,t,f) CE.yesNo_(logical(b), t, f);

    fprintf(fid, '\\clearpage\n');
    fprintf(fid, '\\section{Appendix: Simulation Physics and Configuration}\n');
    fprintf(fid, ['\\textit{Controlled, internally consistent reverse-GNSS EKF simulation: ' ...
        'one spacecraft estimated from one-way ground-tower uplinks. This is not an operational, ' ...
        'PPP-grade, mission-qualified, or real-data GNSS processor.}\n\n']);
    fprintf(fid, '\\begin{center}\\small\n');

    % ---- A. Scenario topology ------------------------------------------------
    fprintf(fid, '\\textbf{Scenario topology}\n\n');
    fprintf(fid, '\\begin{tabular}{p{0.38\\textwidth}p{0.52\\textwidth}}\n');
    fprintf(fid, '\\toprule\n\\textbf{Property} & \\textbf{Value}\\\\\n\\midrule\n');
    fprintf(fid, 'Space assets & %d (single estimated spacecraft)\\\\\n', F('stage66NSpaceAssets',1));
    fprintf(fid, 'Orbit class & %s (equatorial, 35786~km)\\\\\n', H(F('stage66OrbitClass','GEO')));
    fprintf(fid, 'Ground transmitters & %d (one-way tower-to-spacecraft)\\\\\n', F('nTowers',0));
    fprintf(fid, 'On-board receivers & %d (spacecraft phase-centre antennas)\\\\\n', F('nReceivers',4));
    fprintf(fid, 'Link direction & one-way uplink only (no two-way, relay, or transponder)\\\\\n');
    fprintf(fid, 'Inter-satellite / two-way links & %s\\\\\n', ...
        Y(F('stage66IslDisabled',true) && F('stage66TwoWayDisabled',true), 'disabled', 'active (unexpected)'));
    fprintf(fid, '\\bottomrule\n\\end{tabular}\n\n\\vspace{6pt}\n');

    % ---- B. Enabled physical effects ----------------------------------------
    fprintf(fid, '\\textbf{Physical effects}\n\n');
    fprintf(fid, '\\begin{tabular}{p{0.38\\textwidth}p{0.52\\textwidth}}\n');
    fprintf(fid, '\\toprule\n\\textbf{Effect} & \\textbf{Status}\\\\\n\\midrule\n');
    fprintf(fid, 'Troposphere & truth %s, model %s (%s; Saastamoinen-style; synthetic)\\\\\n', ...
        Y(F('stage68TropTruthEn',false),'on','off'), Y(F('stage68TropModelEn',false),'on','off'), H(F('stage68TropModelType','simpleMapped')));
    fprintf(fid, 'Ionosphere & truth %s, model %s (%s; $1/f^2$ dispersion; synthetic)\\\\\n', ...
        Y(F('stage68IonoTruthEn',false),'on','off'), Y(F('stage68IonoModelEn',false),'on','off'), H(F('stage68IonoModelType','simpleMapped')));
    fprintf(fid, 'Sagnac / light-time & %s (first-order; no relativistic rate)\\\\\n', Y(F('stage68SagnacEn',false),'enabled','disabled'));
    fprintf(fid, 'Antenna phase-centre offset & %s (synthetic constants; no ANTEX)\\\\\n', Y(F('stage68PcoEn',false),'enabled','disabled'));
    fprintf(fid, 'Antenna phase-centre variation & %s (no ANTEX)\\\\\n', Y(F('stage68PcvEn',false),'enabled','disabled'));
    fprintf(fid, 'Hardware bias & %s (synthetic; no calibrated DCB/phase-bias)\\\\\n', Y(F('stage68HwDelayEn',false),'enabled','disabled'));
    fprintf(fid, 'Multipath & %s\\\\\n', Y(F('stage68MultipathEn',false),'enabled (synthetic)','disabled'));
    fprintf(fid, '\\bottomrule\n\\end{tabular}\n\n\\vspace{6pt}\n');

    % ---- C. Dynamics and observation models ---------------------------------
    fprintf(fid, '\\textbf{Dynamics and observation models}\n\n');
    fprintf(fid, '\\begin{tabular}{p{0.38\\textwidth}p{0.52\\textwidth}}\n');
    fprintf(fid, '\\toprule\n\\textbf{Property} & \\textbf{Value}\\\\\n\\midrule\n');
    propMode_ = F('truthPropagatorMode', F('stage67OrbitPropMode','twoBodyRk4'));
    dynMode_  = F('estimatorDynamicsMode', F('stage67DynamicsMode','twoBody'));
    fprintf(fid, 'Truth propagator & %s (GEO 35786~km, $i\\!=\\!0$, $\\nu_0\\!=\\!23^\\circ$)\\\\\n', H(propMode_));
    % NOTE: the phrase "truth/EKF dynamics family" is a required audit marker.
    fprintf(fid, 'EKF predictor & %s; truth/EKF dynamics family: %s\\\\\n', ...
        H(dynMode_), H(F('dynamicsMismatchStatus','not evaluated')));
    % NOTE: the label "J2 dynamics policy" is a required audit marker.
    fprintf(fid, 'J2 dynamics policy & %s; J2 accel @ GEO %.2e~m/s$^2$; process-noise consistency: %s\\\\\n', ...
        H(F('j2DefaultPolicy','twoBodyDefaultJ2Available')), F('representativeJ2Accel_mps2',0), H(F('dynamicsProcessNoiseConsistency','unknown')));
    fprintf(fid, 'One-way light time & %s; mode %s; mean/max %.6f/%.6f~s\\\\\n', ...
        Y(F('lightTimeEnabled',false),'enabled','disabled'), H(F('lightTimeMode','sagnacFirstOrder')), F('meanLightTime_s',0), F('maxLightTime_s',0));
    fprintf(fid, 'Doppler model & %s; Sagnac handling %s\\\\\n', ...
        H(F('dopplerModelLevel','frameConsistentV2')), H(F('sagnacHandling','firstOrderCorrection')));
    fprintf(fid, 'Reference frames & propagation %s; measurements %s; Earth rotation %s\\\\\n', ...
        H(F('propagationFrame','ECI')), H(F('measurementFrame','ECEF')), H(F('earthRotationModel','constantOmegaV1')));
    fprintf(fid, 'IERS / EOP & not implemented; simplified constant Earth-rotation rate\\\\\n');
    fprintf(fid, '\\bottomrule\n\\end{tabular}\n\n\\vspace{6pt}\n');

    % ---- D. Attitude and carrier ambiguity ----------------------------------
    fprintf(fid, '\\textbf{Attitude and carrier ambiguity}\n\n');
    fprintf(fid, '\\begin{tabular}{p{0.38\\textwidth}p{0.52\\textwidth}}\n');
    fprintf(fid, '\\toprule\n\\textbf{Property} & \\textbf{Value}\\\\\n\\midrule\n');
    fprintf(fid, 'Primary attitude estimator & %s\\\\\n', H(F('stage67PrimaryAttMode','carrierLeverArmQuaternionEkf')));
    fprintf(fid, 'Carrier tracking & %s\\\\\n', H(F('stage67AttCarrierMode','calibratedDifferentialAmbiguity')));
    fprintf(fid, 'Baseline ambiguity resolution & %s\\\\\n', H(F('attitudeArMode','rawL1Only')));
    fprintf(fid, 'False-fix classification & %s\\\\\n', H(F('baselineArFalseFixClassification','screenedNotFormal')));
    fprintf(fid, 'Phase-bias status & %s\\\\\n', H(F('baselineArPhaseBiasStatus','notCalibratedExternalProduct')));
    fprintf(fid, 'Carrier ionosphere-free integer fixing & unsupported (float ambiguity only)\\\\\n');
    fprintf(fid, '\\bottomrule\n\\end{tabular}\n\n\\vspace{6pt}\n');

    % ---- Truth-estimation separation audit (required audit markers) ---------
    if isfield(summary,'truthEstimationSeparationRows') && iscell(summary.truthEstimationSeparationRows)
        rows_ = summary.truthEstimationSeparationRows;
        esc_  = @(s) strrep(strrep(strrep(strrep(strrep(char(s),'&','\&'),'%','\%'),'_','\_'),'#','\#'),'$','\$');
        yn_   = @(b) Y(b,'true','false');
        fprintf(fid, '\\textbf{Truth-estimation separation audit}\n\n');
        % WP-E/F: only claim "calibration residuals" as an imperfection source when antenna
        % PCO or hardware delay actually leaves a truth~=model residual. In the shipped config
        % they are matched (zero residual), so the clause is dropped for honesty.
        calibClause_ = '';
        if revgnss.ImperfectionAudit.pcoLeavesResidual(cfg) || revgnss.ImperfectionAudit.hwDelayLeavesResidual(cfg)
            calibClause_ = 'calibration residuals, ';
        end
        fprintf(fid, ['\\textit{Realistic synthetic truth-estimation comparison: truth and estimator use the ' ...
            'same physical model families; the estimator is imperfect only from initial-state uncertainty, ' ...
            'noisy measurements, stochastic clocks/products, atmosphere residuals, ' calibClause_ ...
            'and process noise. Not real-data validation, not POD, not PPP, not a model-mismatch analysis.}\n\n']);
        fprintf(fid, '\\begin{tabular}{p{0.16\\textwidth}p{0.14\\textwidth}p{0.16\\textwidth}p{0.05\\textwidth}p{0.34\\textwidth}}\n');
        fprintf(fid, ['\\toprule\n\\textbf{Model} & \\textbf{Truth family} & \\textbf{Estimator family} & ' ...
            '\\textbf{Same?} & \\textbf{Estimator imperfection source}\\\\\n\\midrule\n']);
        for ri_ = 1:size(rows_,1)
            fprintf(fid, '%s & %s & %s & %s & %s\\\\\n', ...
                esc_(rows_{ri_,1}), esc_(rows_{ri_,2}), esc_(rows_{ri_,3}), esc_(rows_{ri_,4}), esc_(rows_{ri_,5}));
        end
        fprintf(fid, '\\bottomrule\n\\end{tabular}\n\n\\vspace{4pt}\n');
        fprintf(fid, '\\begin{tabular}{lp{0.30\\textwidth}}\n\\toprule\n\\textbf{Separation flag} & \\textbf{Value}\\\\\n\\midrule\n');
        fprintf(fid, 'Same model families & %s\\\\\n', yn_(F('teSepSameModelFamilies',false)));
        fprintf(fid, 'Reduced-dynamics (process noise) & %s\\\\\n', yn_(F('teSepReducedDynamics',false)));
        fprintf(fid, 'Model-mismatch analysis & %s\\\\\n', yn_(F('teSepMismatchAnalysis',false)));
        fprintf(fid, 'Truth leakage in main filter & %s\\\\\n', yn_(F('teSepTruthLeakageInMainFilter',false)));
        fprintf(fid, 'Real-world validation claim & %s\\\\\n', yn_(F('teSepRealWorldClaim',false)));
        % NOTE: the label "Realistic synthetic TE comparison" is a required audit marker.
        fprintf(fid, 'Realistic synthetic TE comparison & %s\\\\\n', yn_(F('realisticSyntheticTruthEstimationComparison',false)));
        fprintf(fid, '\\bottomrule\n\\end{tabular}\n\n\\vspace{6pt}\n');
    end

    % ---- Scientific closure (compact) ---------------------------------------
    fprintf(fid, '\\textbf{Scientific closure}\n\n');
    fprintf(fid, '\\begin{tabular}{p{0.38\\textwidth}p{0.52\\textwidth}}\n\\toprule\n');
    fprintf(fid, '\\textbf{Category} & \\textbf{Status}\\\\\n\\midrule\n');
    fprintf(fid, 'Scientific profile & %s\\\\\n', H(F('scientificProfileMode','singleAssetOneWaySyntheticClosedV1')));
    fprintf(fid, 'Claim level & %s\\\\\n', H(F('claimLevel','controlledSynthetic')));
    fprintf(fid, 'Real-world claim gate & %s\\\\\n', H(F('realWorldClaimGateStatus','blockedWithReasons')));
    fprintf(fid, 'External products (SP3/CLK/RINEX/ANTEX/IONEX) & %s\\\\\n', H(F('externalProductsStatus','notImplemented')));
    fprintf(fid, '\\bottomrule\n\\end{tabular}\n\n\\vspace{6pt}\n');

    % ---- Known limitations (compact, de-staged) -----------------------------
    fprintf(fid, '\\textbf{Known limitations}\n\n');
    fprintf(fid, '\\begin{tabular}{p{0.92\\textwidth}}\n\\toprule\n');
    fprintf(fid, 'No external RINEX/SP3/CLK/ANTEX/IONEX products ingested; tower-clock product is synthetic.\\\\\n');
    fprintf(fid, 'No PPP-grade or operational navigation claim; no mission-qualified attitude determination.\\\\\n');
    fprintf(fid, 'No LAMBDA/MLAMBDA and no wide-lane/narrow-lane; carrier ionosphere-free integer fixing is unsupported.\\\\\n');
    fprintf(fid, 'No calibrated hardware bias/DCB/phase-bias products; no IERS/EOP-grade reference-frame processing.\\\\\n');
    fprintf(fid, 'Ionosphere-free covariance assumes uncorrelated L1/L2 noise.\\\\\n');
    % WP-7: relativistic clock-rate claim boundary. Applied identically to truth and
    % estimator (both disabled), so it creates no filter inconsistency; it is a
    % modelling/claim-scope omission a picosecond-class GEO result must declare.
    fprintf(fid, ['Relativistic clock-rate offset (gravitational + special-relativistic, ' ...
        '$\\sim\\!5.4\\times10^{-10}$ fractional, $\\sim\\!47~\\mu$s/day for a GEO clock versus ground) is ' ...
        'not modelled; it is applied identically to truth and estimator (both disabled), so it introduces no ' ...
        'filter inconsistency, but picosecond-class timing statements are scoped to the estimated/differential ' ...
        'clock states, which absorb a constant frequency offset.\\\\\n']);
    % WP-6: receiver clock-drift +-3sigma coverage is observability-limited (documented).
    fprintf(fid, ['Receiver clock-drift $\\pm3\\sigma$ coverage is observability-limited for a ' ...
        'caesium-class clock: the drift wander is far below the Doppler resolution, so the drift ' ...
        'confidence bound reflects process noise, not measurement information -- a fundamental limit, ' ...
        'not a filter defect (the report drift-error panel shows the empirical coverage).\\\\\n']);
    % WP-4: idealised headline-clock caveat (realistic clock is one string away).
    fprintf(fid, ['Headline receiver clock is the idealised legacy h-coefficient set ' ...
        '($\\sigma_y(1$~s$)\\approx 7\\times10^{-14}$, about two orders quieter than a real ' ...
        'caesium beam); a realistic literature-anchored set (clock.templateSource = jowTable2p1) ' ...
        'is one-string selectable and degrades the timing result accordingly.\\\\\n']);
    fprintf(fid, '\\bottomrule\n\\end{tabular}\n');

    % ---- Provenance (dynamic branch + commit) -------------------------------
    fprintf(fid, '\\vspace{6pt}\n');
    fprintf(fid, '\\end{center}\n');
    branch_ = 'unknown'; sha_ = '';
    try; branch_ = CE.getGitBranch_(); catch; end
    try; sha_ = CE.getGitSHA_(); catch; end
    fprintf(fid, '\\noindent {\\footnotesize Provenance: branch \\texttt{%s}, commit \\texttt{%s}.}\n\n', ...
        CE.esc_(branch_), CE.esc_(sha_));
end
