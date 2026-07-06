function activePhysicsConfig(fid, cfg, summary, plotPaths, stem, figDir)
%ACTIVEPHYSICSCONFIG  "Simulation Physics and Configuration" report section (Phase 7).
%   Extracted verbatim from ClockExactReportBuilder.writeActivePhysicsConfig_ as part
%   of the C-9 report decomposition. Read-only: consumes only the precomputed plotPaths
%   + figure dir and the (now-public) ClockExactReportBuilder formatting toolkit. The
%   emitted LaTeX is byte-identical to the original method (verified by the normalized
%   .tex diff harness, tests/report/reportTexFingerprint.m).
    CE = revgnss.ClockExactReportBuilder;
    if ~isfield(summary,'physicsConfigSectionActive') || ~summary.physicsConfigSectionActive; return; end
    fprintf(fid, '\\clearpage\n');
    fprintf(fid, '\\section{Simulation Physics and Configuration}\n');
    fprintf(fid, ['\\textit{Controlled, internally consistent MATLAB reverse-GNSS EKF simulation: ' ...
        'one spacecraft estimated from one-way ground-tower uplinks. ' ...
        'NOT operational, NOT PPP-grade, NOT mission-qualified, NOT real-data GNSS processor.}\n\n']);
    fprintf(fid, '\\begin{center}\\small\n');

    % ---- 1. Scenario topology ---
    fprintf(fid, '\\textbf{Scenario topology}\n\n');
    fprintf(fid, '\\begin{tabular}{p{0.38\\textwidth}p{0.52\\textwidth}}\n');
    fprintf(fid, '\\toprule\n\\textbf{Property} & \\textbf{Value}\\\\\n\\midrule\n');
    nSA_ = 1; if isfield(summary,'stage66NSpaceAssets'); nSA_ = summary.stage66NSpaceAssets; end
    fprintf(fid, 'nSpaceAssets & %d (single estimated spacecraft)\\\\\n', nSA_);
    oc_ = 'GEO'; if isfield(summary,'stage66OrbitClass'); oc_ = summary.stage66OrbitClass; end
    fprintf(fid, 'Orbit class & \\texttt{%s} (GEO equatorial, 35786~km)\\\\\n', oc_);
    nTwr_ = 0; if isfield(summary,'nTowers'); nTwr_ = summary.nTowers; end
    fprintf(fid, 'nTowers & %d (Earth transmitters; one-way tower-to-spacecraft)\\\\\n', nTwr_);
    nRx_ = 4; if isfield(summary,'nReceivers'); nRx_ = summary.nReceivers; end
    fprintf(fid, 'nReceivers & %d (spacecraft phase-centre antennas)\\\\\n', nRx_);
    fprintf(fid, 'Link direction & one-way uplink only (no two-way, no relay, no transponder)\\\\\n');
    islDis_ = true; if isfield(summary,'stage66IslDisabled'); islDis_ = summary.stage66IslDisabled; end
    fprintf(fid, 'ISL & %s\\\\\n', CE.yesNo_(islDis_,'disabled','ACTIVE (unexpected)'));
    twDis_ = true; if isfield(summary,'stage66TwstftDisabled'); twDis_ = summary.stage66TwstftDisabled; end
    fprintf(fid, 'TWSTFT & %s\\\\\n', CE.yesNo_(twDis_,'disabled','ACTIVE (unexpected)'));
    twoWDis_ = true; if isfield(summary,'stage66TwoWayDisabled'); twoWDis_ = summary.stage66TwoWayDisabled; end
    fprintf(fid, 'Two-way / multi-asset & %s\\\\\n', CE.yesNo_(twoWDis_,'disabled','ACTIVE (unexpected)'));
    fprintf(fid, '\\bottomrule\n\\end{tabular}\n\n\\vspace{6pt}\n');

    % ---- 2. Measurement model ---
    fprintf(fid, '\\textbf{Measurement model (one-way; clock sign: receiver $-$ transmitter)}\n\n');
    fprintf(fid, '\\begin{tabular}{p{0.38\\textwidth}p{0.52\\textwidth}}\n');
    fprintf(fid, '\\toprule\n\\textbf{Observable} & \\textbf{Model}\\\\\n\\midrule\n');
    fprintf(fid, 'Code & $z_P = \\rho + c(\\delta t_{\\rm rx}-\\delta t_{\\rm tx}) + T + I_{\\rm code} + d + \\varepsilon$\\\\\n');
    fprintf(fid, 'Carrier & $z_L = \\rho + c(\\delta t_{\\rm rx}-\\delta t_{\\rm tx}) + T - I_{\\rm carr} + \\lambda N + d_{\\phi} + \\varepsilon$\\\\\n');
    fprintf(fid, 'Doppler (v1) & $z_D = \\dot{\\rho} + c(\\dot{\\delta t}_{\\rm rx}-\\dot{\\delta t}_{\\rm tx}) + \\varepsilon$ (simplified LOS rate)\\\\\n');
    fprintf(fid, 'Iono sign & code: $+I_{\\rm L1}(f_p/f)^2$ (group delay); carrier: $-I_{\\rm L1}(f_p/f)^2$ (phase advance)\\\\\n');
    fprintf(fid, 'IF covariance & $\\mathrm{Var}(z_{\\rm IF})=\\alpha^2 V_{L1}+\\beta^2 V_{L2}$; $\\mathrm{Cov}(L_1,L_2)=0$ assumed\\\\\n');
    fprintf(fid, 'Ambiguity & float metres; no integer fixing; no LAMBDA/MLAMBDA/WL/NL\\\\\n');
    fprintf(fid, '\\bottomrule\n\\end{tabular}\n\n\\vspace{6pt}\n');

    % ---- 3. Atmosphere, antenna, and bias ---
    fprintf(fid, '\\textbf{Atmosphere, antenna, and bias corrections}\n\n');
    fprintf(fid, '\\begin{tabular}{p{0.38\\textwidth}p{0.52\\textwidth}}\n');
    fprintf(fid, '\\toprule\n\\textbf{Effect} & \\textbf{Status}\\\\\n\\midrule\n');
    tropTr_ = false; if isfield(summary,'stage68TropTruthEn'); tropTr_ = summary.stage68TropTruthEn; end
    tropMd_ = false; if isfield(summary,'stage68TropModelEn'); tropMd_ = summary.stage68TropModelEn; end
    tropTyp_ = 'simpleMapped'; if isfield(summary,'stage68TropModelType'); tropTyp_ = summary.stage68TropModelType; end
    fprintf(fid, 'Troposphere & truth~%s, model~%s (\\texttt{%s}; Saastamoinen-style mapping; synthetic, no GPT3/VMF3)\\\\\n', ...
        CE.yesNo_(tropTr_,'on','off'), CE.yesNo_(tropMd_,'on','off'), strrep(tropTyp_,'_','\_'));
    ionoTr_ = false; if isfield(summary,'stage68IonoTruthEn'); ionoTr_ = summary.stage68IonoTruthEn; end
    ionoMd_ = false; if isfield(summary,'stage68IonoModelEn'); ionoMd_ = summary.stage68IonoModelEn; end
    ionoTyp_ = 'simpleMapped'; if isfield(summary,'stage68IonoModelType'); ionoTyp_ = summary.stage68IonoModelType; end
    fprintf(fid, 'Ionosphere & truth~%s, model~%s (\\texttt{%s}; $1/f^2$ dispersion; synthetic, no Klobuchar/IONEX)\\\\\n', ...
        CE.yesNo_(ionoTr_,'on','off'), CE.yesNo_(ionoMd_,'on','off'), strrep(ionoTyp_,'_','\_'));
    sagEn_ = false; if isfield(summary,'stage68SagnacEn'); sagEn_ = summary.stage68SagnacEn; end
    fprintf(fid, 'Sagnac / light-time & %s (first-order; no relativistic rate)\\\\\n', CE.yesNo_(sagEn_,'enabled','disabled'));
    pcoEn_ = false; if isfield(summary,'stage68PcoEn'); pcoEn_ = summary.stage68PcoEn; end
    fprintf(fid, 'Antenna PCO & %s (synthetic calibrated constants; no ANTEX)\\\\\n', CE.yesNo_(pcoEn_,'enabled','disabled (unexpected)'));
    pcvEn_ = false; if isfield(summary,'stage68PcvEn'); pcvEn_ = summary.stage68PcvEn; end
    fprintf(fid, 'Antenna PCV & %s (none by default; no ANTEX)\\\\\n', CE.yesNo_(pcvEn_,'enabled','disabled'));
    hwEn_ = false; if isfield(summary,'stage68HwDelayEn'); hwEn_ = summary.stage68HwDelayEn; end
    fprintf(fid, 'Hardware bias & %s (synthetic; no calibrated DCB/phase-bias products)\\\\\n', CE.yesNo_(hwEn_,'enabled','disabled'));
    mpEn_ = false; if isfield(summary,'stage68MultipathEn'); mpEn_ = summary.stage68MultipathEn; end
    fprintf(fid, 'Multipath & %s\\\\\n', CE.yesNo_(mpEn_,'enabled (synthetic)','disabled'));
    fprintf(fid, '\\bottomrule\n\\end{tabular}\n\n\\vspace{6pt}\n');

    % ---- 4. Attitude ---
    fprintf(fid, '\\textbf{Attitude determination}\n\n');
    fprintf(fid, '\\begin{tabular}{p{0.38\\textwidth}p{0.52\\textwidth}}\n');
    fprintf(fid, '\\toprule\n\\textbf{Property} & \\textbf{Value}\\\\\n\\midrule\n');
    attPrim_ = 'carrierLeverArmQuaternionEkf';
    if isfield(summary,'stage67PrimaryAttMode'); attPrim_ = summary.stage67PrimaryAttMode; end
    fprintf(fid, 'Primary estimator & \\texttt{%s}\\\\\n', strrep(attPrim_,'_','\_'));
    fprintf(fid, 'EKF type & nominal $q$ + error-state $\\delta\\theta$; Joseph posterior reset\\\\\n');
    attInit_ = 'coarseBaselineIntegerSearch';
    if isfield(summary,'stage67AttInitMode'); attInit_ = summary.stage67AttInitMode; end
    fprintf(fid, 'Initializer & \\texttt{%s} (optional; not primary estimator)\\\\\n', strrep(attInit_,'_','\_'));
    attCar_ = 'calibratedDifferentialAmbiguity';
    if isfield(summary,'stage67AttCarrierMode'); attCar_ = summary.stage67AttCarrierMode; end
    fprintf(fid, 'Carrier tracking & \\texttt{%s}\\\\\n', strrep(attCar_,'_','\_'));
    % Stage 70/75: baseline integer fix status + GNSS-only claim
    arAttempted_ = false; arAccepted_ = false; arClass_ = 'notAttempted';
    arExtSrc_ = true; arExtSrch_ = false;
    if isfield(summary,'baselineIntegerFixAttempted'); arAttempted_ = summary.baselineIntegerFixAttempted; end
    if isfield(summary,'baselineIntegerFixAccepted');  arAccepted_  = summary.baselineIntegerFixAccepted;  end
    % Stage 75 classification takes precedence over Stage 70 if available
    arClass_ = CE.safeField_(summary,'baselineArClassification', ...
               CE.safeField_(summary,'baselineIntegerFixClassification','notAttempted'));
    if isfield(summary,'externalReferenceUsedForCalibration'); arExtSrc_ = summary.externalReferenceUsedForCalibration; end
    if isfield(summary,'externalReferenceUsedAsSearchCenter'); arExtSrch_ = summary.externalReferenceUsedAsSearchCenter; end
    nFix_ = CE.safeField_(summary,'nBaselineArFixed', ...
            CE.safeField_(summary,'nBaselineIntegerFixed',0));
    nRej_ = CE.safeField_(summary,'nBaselineIntegerRejected',0);
    nUsed75_ = CE.safeField_(summary,'nBaselineArUsedInEkf', nFix_);
    nRejArc75_ = CE.safeField_(summary,'nBaselineArRejectedArc', 0);
    nFloat75_  = CE.safeField_(summary,'nBaselineArFloatExternal', 0);
    gnssOnly75_ = CE.safeField_(summary,'baselineArGnssOnlyClaim', false);
    falseFix75_ = CE.safeField_(summary,'baselineArFalseFixClassification','screenedNotFormal');
    phaseBias75_ = CE.safeField_(summary,'baselineArPhaseBiasStatus','notCalibratedExternalProduct');
    policy75_    = CE.safeField_(summary,'baselineArPartialPolicy','mixedFixedFloat');
    % Stage 76: signal and dimension fields
    sigNames76_  = CE.safeField_(summary,'signalNames',{'L1'});
    % Stage 78: use SignalDefinition for default; no hardcoded constant.
    sigFreqs76_  = CE.safeField_(summary,'signalFrequenciesHz', ...
        [revgnss.SignalDefinition.get('L1').frequency_Hz]);
    sigMask76_   = CE.safeField_(summary,'signalEnabledMask',[true]);
    sigMode76_   = CE.safeField_(summary,'signalMode','L1');
    arFreqEn76_  = CE.safeField_(summary,'attitudeArEnabledByFrequency',[true false]);
    arMode76_    = CE.safeField_(summary,'attitudeArMode','rawL1Only');
    wlEn76_      = CE.safeField_(summary,'wideLaneScreeningEnabled',false);
    nDual76_     = CE.safeField_(summary,'nBaselineArFixedDualFrequency',0);
    nL1Only76_   = CE.safeField_(summary,'nBaselineArFixedL1Only',0);
    nTow76_      = CE.safeField_(summary,'nTowers',5);
    nRx76_       = CE.safeField_(summary,'nReceivers',4);
    nActBsl76_   = CE.safeField_(summary,'nActiveDiffAttBaselines',nTow76_*(nRx76_-1));
    carrIfFix76_ = false;  % never true in v1
    dIono76_     = CE.safeField_(summary,'differentialIonosphereInBaselineAr','neglectedShortBaselineV1');
    multiAS76_   = CE.safeField_(summary,'multiAssetSupported',false);
    % Signal summary row
    sigFreqStr_ = strjoin(arrayfun(@(f) sprintf('%.2f MHz', f/1e6), sigFreqs76_, 'UniformOutput', false), ', ');
    sigMaskStr_ = mat2str(sigMask76_);
    fprintf(fid, 'Signal names & \\texttt{%s} (%s); enabled mask: %s\\\\\n', ...
        strjoin(sigNames76_,'+'), sigFreqStr_, sigMaskStr_);
    fprintf(fid, 'Signal mode & \\texttt{%s}; AR by-freq: %s; WL screening: %s\\\\\n', ...
        sigMode76_, mat2str(arFreqEn76_), CE.yesNo_(wlEn76_,'enabled','disabled'));
    fprintf(fid, 'Topology (Stage~76) & %d towers $\\times$ %d receivers = %d active DiffAtt baselines\\\\\n', ...
        nTow76_, nRx76_, nActBsl76_);
    fprintf(fid, 'Multi-asset & supported: %s; requested: %s\\\\\n', ...
        CE.yesNo_(multiAS76_,'true','false'), ...
        CE.yesNo_(CE.safeField_(summary,'multiAssetRequested',false),'true','false'));
    if arAttempted_ && arAccepted_
        fprintf(fid, 'Baseline $\\Delta N$ integer fix & \\texttt{%s} (%d fixed: %d dual, %d L1-only; float: %d; arc-rej: %d; EKF: %d)\\\\\n', ...
            strrep(arClass_,'_','\_'), nFix_, nDual76_, nL1Only76_, nFloat75_, nRejArc75_, nUsed75_);
        fprintf(fid, 'AR mode (Stage~76) & \\texttt{%s}\\\\\n', strrep(arMode76_,'_','\_'));
        fprintf(fid, 'Partial-fix policy (Stage~75) & \\texttt{%s}\\\\\n', strrep(policy75_,'_','\_'));
        gnssClaimStr_ = CE.yesNo_(gnssOnly75_, ...
            'true (all baselines fixed; no extRef calibration)', ...
            'false (partial fix or extRef calibration used)');
        fprintf(fid, 'GNSS-only attitude claim (Stage~75) & %s\\\\\n', gnssClaimStr_);
        fprintf(fid, 'False-fix classification (Stage~75) & \\texttt{%s}\\\\\n', strrep(falseFix75_,'_','\_'));
    elseif arAttempted_
        fprintf(fid, 'Baseline $\\Delta N$ integer fix & \\texttt{%s} (0 fixed; fallback to float calibration)\\\\\n', ...
            strrep(arClass_,'_','\_'));
        fprintf(fid, 'GNSS-only attitude claim (Stage~75) & false (integer fix failed; differential tracking only)\\\\\n');
    else
        fprintf(fid, 'Baseline $\\Delta N$ integer fix & not attempted (AR disabled)\\\\\n');
        fprintf(fid, 'GNSS-only attitude claim (Stage~75) & false (differential carrier = relative only)\\\\\n');
    end
    fprintf(fid, 'Phase-bias status & \\texttt{%s}\\\\\n', strrep(phaseBias75_,'_','\_'));
    fprintf(fid, 'Carrier-IF integer fixing & %s (explicitly unsupported in v1)\\\\\n', CE.yesNo_(carrIfFix76_,'true','false'));
    fprintf(fid, 'Differential iono in baseline AR & \\texttt{%s}\\\\\n', strrep(dIono76_,'_','\_'));
    % Stage 79: final central configuration lock rows
    sigMaskCfg79_ = CE.safeField_(summary,'canonicalSignalEnabledMask',[true]);
    slipThr79_    = CE.safeField_(summary,'canonicalSlipThreshold_m',0.1);
    audit79_      = CE.safeField_(summary,'centralConfigAuditStatus','unknown');
    fprintf(fid, 'Config lock (Stage~79) & status: %s; signal mask: %s; slip thr: %.2f\\,m\\\\\n', ...
        audit79_, mat2str(logical(sigMaskCfg79_)), slipThr79_);
    freqAudit79_ = CE.safeField_(summary,'frequencyHardcodeAuditStatus','unknown');
    sigOwn79_    = CE.safeField_(summary,'signalConfigOwner','cfg.signals.names+cfg.signals.enabledMask');
    nWarn79_     = CE.safeField_(summary,'centralConfigWarnings',0);
    nErr79_      = CE.safeField_(summary,'centralConfigErrors',0);
    fprintf(fid, 'Config owners (Stage~79) & signal owner: %s; freq audit: %s; warnings/errors: %d/%d\\\\\n', ...
        sigOwn79_, freqAudit79_, nWarn79_, nErr79_);
    fprintf(fid, '\\bottomrule\n\\end{tabular}\n\n\\vspace{6pt}\n');

    % ---- 5. Clocks ---
    fprintf(fid, '\\textbf{Clock model}\n\n');
    fprintf(fid, '\\begin{tabular}{p{0.38\\textwidth}p{0.52\\textwidth}}\n');
    fprintf(fid, '\\toprule\n\\textbf{Property} & \\textbf{Value}\\\\\n\\midrule\n');
    rxDet_ = false; if isfield(summary,'stage67RxClockDet'); rxDet_ = summary.stage67RxClockDet; end
    rxEst_ = true; if isfield(summary,'receiverClockEstimated'); rxEst_ = summary.receiverClockEstimated; end
    fprintf(fid, 'Asset Rx clock & %s; EKF estimated=%s (Brown-Hwang two-state)\\\\\n', ...
        CE.yesNo_(rxDet_,'deterministic','stochastic'), CE.yesNo_(rxEst_,'true','false'));
    twrEst_ = false; if isfield(summary,'towerClockStatesEstimated'); twrEst_ = summary.towerClockStatesEstimated; end
    fprintf(fid, 'Tower clocks in EKF & %s (product-corrected; gauge avoided)\\\\\n', CE.yesNo_(twrEst_,'yes (experimental)','no'));
    % Stage 71: product mode
    tClkMode_ = 'noisyCorrection';
    if isfield(summary,'towerClockProductMode'); tClkMode_ = summary.towerClockProductMode;
    elseif isfield(summary,'stage67TowerClockMode'); tClkMode_ = summary.stage67TowerClockMode; end
    isProductMode71_ = strcmp(tClkMode_,'truthHistoryProductNoisy');
    fprintf(fid, 'Tower correction mode & \\texttt{%s}\\\\\n', strrep(tClkMode_,'_','\_'));
    if isProductMode71_
        dT71_ = NaN; if isfield(summary,'towerClockProductUpdateInterval_s'); dT71_ = summary.towerClockProductUpdateInterval_s; end
        lat71_ = NaN; if isfield(summary,'towerClockProductLatency_s'); lat71_ = summary.towerClockProductLatency_s; end
        mAge71_ = NaN; if isfield(summary,'towerClockProductMeanAge_s'); mAge71_ = summary.towerClockProductMeanAge_s; end
        xAge71_ = NaN; if isfield(summary,'towerClockProductMaxAge_s'); xAge71_ = summary.towerClockProductMaxAge_s; end
        mSig71_ = NaN; if isfield(summary,'towerClockProductMeanSigma_m'); mSig71_ = summary.towerClockProductMeanSigma_m; end
        xSig71_ = NaN; if isfield(summary,'towerClockProductMaxSigma_m'); xSig71_ = summary.towerClockProductMaxSigma_m; end
        shrd71_  = false; if isfield(summary,'towerClockSharedCovarianceApplied'); shrd71_  = summary.towerClockSharedCovarianceApplied; end
        diagInf_ = false; if isfield(summary,'towerClockProductDiagonalInflation'); diagInf_ = summary.towerClockProductDiagonalInflation; end
        fprintf(fid, 'Product update interval & %.0f s; latency %.0f s; max age %.0f s; mean age %.0f s\\\\\n', dT71_, lat71_, xAge71_, mAge71_);
        fprintf(fid, 'Product $\\sigma$ & mean %.3f m; max %.3f m (added to code $R$ per row; carrier $R$ unchanged)\\\\\n', mSig71_, xSig71_);
        fprintf(fid, 'Covariance handling & %s; Doppler clock-$\\dot{b}$ $\\sigma$: simplified v1 (not added to $R$)\\\\\n', ...
            CE.yesNo_(shrd71_, 'off-diagonal shared $R$ applied', ...
            CE.yesNo_(diagInf_, 'diagonal per-row $R$ inflation only (Stage~72)', 'not applied')));
        fprintf(fid, 'Perfect tower correction & false (product-predicted; not truth-plus-noise)\\\\\n');
    else
        tClkSig_ = 0.5;
        if isfield(summary,'stage67TowerClockSigma_m'); tClkSig_ = summary.stage67TowerClockSigma_m; end
        fprintf(fid, 'Correction $\\sigma$ & %.2f m\\\\\n', tClkSig_);
        pfCorr_ = false; if isfield(summary,'towerClockPerfectCorrection'); pfCorr_ = summary.towerClockPerfectCorrection; end
        fprintf(fid, 'Perfect tower correction & %s\\\\\n', CE.yesNo_(pfCorr_,'true (validation only)','false'));
    end
    allanPath_ = CE.figRef_(plotPaths, 'allanDev', figDir, stem);
    allanAvail_ = ~isempty(allanPath_) && isfile(allanPath_);
    fprintf(fid, 'Allan deviation & %s\\\\\n', CE.yesNo_(allanAvail_,'plot available (Oscillator Stability section)','not generated'));
    fprintf(fid, '\\bottomrule\n\\end{tabular}\n\n\\vspace{6pt}\n');

    % ---- 6. Orbital dynamics ---
    fprintf(fid, '\\textbf{Orbital dynamics}\n\n');
    fprintf(fid, '\\begin{tabular}{p{0.38\\textwidth}p{0.52\\textwidth}}\n');
    fprintf(fid, '\\toprule\n\\textbf{Property} & \\textbf{Value}\\\\\n\\midrule\n');
    propMode_ = 'twoBodyRk4';
    if isfield(summary,'truthPropagatorMode'); propMode_ = summary.truthPropagatorMode;
    elseif isfield(summary,'stage67OrbitPropMode'); propMode_ = summary.stage67OrbitPropMode; end
    fprintf(fid, 'Truth propagator & \\texttt{%s} (GEO 35786~km, $i\\!=\\!0$, $\\nu_0\\!=\\!23^\\circ$)\\\\\n', strrep(propMode_,'_','\_'));
    dynMode_ = 'twoBody';
    if isfield(summary,'estimatorDynamicsMode'); dynMode_ = summary.estimatorDynamicsMode;
    elseif isfield(summary,'stage67DynamicsMode'); dynMode_ = summary.stage67DynamicsMode; end
    mismatch80_ = CE.safeField_(summary,'dynamicsMismatchStatus','not evaluated');
    fprintf(fid, 'EKF predictor & \\texttt{%s}; mismatch status: %s\\\\\n', strrep(dynMode_,'_','\_'), strrep(mismatch80_,'_','\_'));
    fprintf(fid, 'Frames & truth: \\texttt{%s}; measurements: \\texttt{%s}; Earth rotation: \\texttt{%s}\\\\\n', ...
        CE.safeField_(summary,'propagationFrame','ECI'), ...
        CE.safeField_(summary,'measurementFrame','ECEF'), ...
        CE.safeField_(summary,'earthRotationModel','constantOmegaV1'));
    fprintf(fid, 'One-way light time & enabled=%s; mode=\\texttt{%s}; iter=%d; mean/max %.6f/%.6f~s\\\\\n', ...
        CE.yesNo_(CE.safeField_(summary,'lightTimeEnabled',false),'true','false'), ...
        CE.safeField_(summary,'lightTimeMode','sagnacFirstOrder'), ...
        CE.safeField_(summary,'lightTimeIterations',0), ...
        CE.safeField_(summary,'meanLightTime_s',0), ...
        CE.safeField_(summary,'maxLightTime_s',0));
    fprintf(fid, 'Sagnac handling & \\texttt{%s}; double-count guard: \\texttt{%s}; Doppler light-time derivative: \\texttt{%s}; Doppler model: \\texttt{%s}\\\\\n', ...
        CE.safeField_(summary,'sagnacHandling','firstOrderCorrection'), ...
        CE.safeField_(summary,'sagnacDoubleCountGuard','notEvaluated'), ...
        CE.safeField_(summary,'dopplerLightTimeDerivative','simplifiedV1'), ...
        CE.safeField_(summary,'dopplerModelLevel','frameConsistentV2'));
    fprintf(fid, 'J2 / drag / SRP / 3rd-body & J2 truth mode available; drag/SRP/3rd-body false in active scenario\\\\\n');
    fprintf(fid, 'J2 mismatch policy & \\texttt{%s}; J2 accel @ GEO: %.2e~m/s$^2$; process-noise consistency: \\texttt{%s}; $\\sigma$/J2\\,ratio=%.2f (tolerated by proc.~noise)\\\\n', ...
        strrep(CE.safeField_(summary,'j2DefaultPolicy','twoBodyDefaultJ2Available'),'_','\_'), ...
        CE.safeField_(summary,'representativeJ2Accel_mps2',0), ...
        CE.safeField_(summary,'dynamicsProcessNoiseConsistency','unknown'), ...
        CE.safeField_(summary,'sigmaToRmsJ2Ratio',NaN));
    fprintf(fid, 'Source truth & \\texttt{%s}; EOP: \\texttt{%s}; freshness stage: %d\\\\\n', ...
        strrep(CE.safeField_(summary,'sourceTruthStatus','unknown'),'_','\_'), ...
        strrep(CE.safeField_(summary,'eopStatus','notImplementedNoIERS'),'_','\_'), ...
        CE.safeField_(summary,'reportStatusFreshnessStage',0));
    fprintf(fid, 'IERS/EOP frame & not implemented; simplified constant-$\\Omega_E$ Earth rotation\\\\\n');
    fprintf(fid, 'DiffAtt schema & \\texttt{%s}\\\\\n', CE.safeField_(summary,'diffAttSchemaStatus','notEvaluated'));
    fprintf(fid, '\\bottomrule\n\\end{tabular}\n\n\\vspace{6pt}\n');

    % Stage 81/82: Scientific closure sub-table (no new chapter)
    fprintf(fid, '\\textbf{Scientific closure (Stage~81/82)}\n\n');
    fprintf(fid, '\\begin{tabular}{lp{0.74\\textwidth}}\n\\toprule\n');
    fprintf(fid, '\\textbf{Category} & \\textbf{Status}\\\\\\\\\n\\midrule\n');
    fprintf(fid, 'Scientific profile & \\texttt{%s}; claim: \\texttt{%s}\\\\\\\\\n', ...
        CE.safeField_(summary,'scientificProfileMode','singleAssetOneWaySyntheticClosedV1'), ...
        CE.safeField_(summary,'claimLevel','controlledSynthetic'));
    fprintf(fid, 'Model coverage & \\texttt{%s}; impl=%d guard=%d disabled=%d missing=%d\\\\\\\\\n', ...
        CE.safeField_(summary,'modelCoverageStatus','notRun'), ...
        CE.safeField_(summary,'nModelCategoriesImplementedSynthetic',0), ...
        CE.safeField_(summary,'nModelCategoriesGuardedNotImplemented',0), ...
        CE.safeField_(summary,'nModelCategoriesDisabledByConfig',0), ...
        CE.safeField_(summary,'nModelCategoriesMissingUnsafe',-1));
    fprintf(fid, 'Real-world claim gate & \\texttt{%s}\\\\\\\\\n', ...
        CE.safeField_(summary,'realWorldClaimGateStatus','blockedWithReasons'));
    fprintf(fid, 'External products & \\texttt{%s} (SP3/CLK/RINEX/ANTEX/IONEX not ingested)\\\\\\\\\n', ...
        CE.safeField_(summary,'externalProductsStatus','notImplemented'));
    fprintf(fid, 'Troposphere & \\texttt{%s}; gradient=disabled; VMD=notImpl.\\\\\\\\\n', ...
        CE.safeField_(summary,'troposphereClaimStatus','syntheticSimpleMappedV1'));
    fprintf(fid, 'Ionosphere & \\texttt{%s}; higher-order=disabled; IONEX=notImpl.\\\\\\\\\n', ...
        CE.safeField_(summary,'ionosphereClaimStatus','syntheticSimpleMappedV1'));
    fprintf(fid, 'Phase bias / DCB & \\texttt{%s} (no real product; real-world AR blocked)\\\\\\\\\n', ...
        CE.safeField_(summary,'biasPhaseMode','syntheticKnownZero'));
    fprintf(fid, 'Carrier-IF fixing & \\texttt{%s} (unsupported; IF ambiguity not integer)\\\\\\\\\n', ...
        mat2str(CE.safeField_(summary,'carrierIfIntegerFixing',false)));
    fprintf(fid, 'NIS / MC / NEES & NIS=\\texttt{%s}; MC=\\texttt{%s}; NEES=\\texttt{%s}\\\\\\\\\n', ...
        CE.safeField_(summary,'validationStatisticsNisMode','partialCovarianceAware'), ...
        mat2str(CE.safeField_(summary,'validationStatisticsMcEnable',false)), ...
        mat2str(CE.safeField_(summary,'validationStatisticsNeesEnable',false)));
    % Stage 85: synthetic campaign status rows
    campSt = CE.safeField_(summary,'scientificCampaignStatus','notRun');
    if ~strcmp(campSt,'notRun')
        fprintf(fid, 'Campaign overall & \\texttt{%s} (\\texttt{%s} profile; %s)\\\\\\\\\n', ...
            CE.safeField_(summary,'campaignOverallStatus','notRun'), ...
            CE.safeField_(summary,'scientificCampaignProfile','off'), ...
            CE.safeField_(summary,'validationStatisticsInterpretation','notRun'));
        fprintf(fid, 'Campaign nominal/L1/clk/slip & \\texttt{%s} / \\texttt{%s} / \\texttt{%s} / \\texttt{%s}\\\\\\\\\n', ...
            CE.safeField_(summary,'campaignNominalStatus','notRun'), ...
            CE.safeField_(summary,'campaignL1OnlyStatus','notRun'), ...
            CE.safeField_(summary,'campaignClockStressStatus','notRun'), ...
            CE.safeField_(summary,'campaignSlipStressStatus','notRun'));
        fprintf(fid, 'NIS code/dopp/carrier & \\texttt{%s} / \\texttt{%s} / \\texttt{%s} (partialCovarianceAwareSynthetic)\\\\\\\\\n', ...
            CE.safeField_(summary,'nisCodeStatus','notAvailable'), ...
            CE.safeField_(summary,'nisDopplerStatus','notAvailable'), ...
            CE.safeField_(summary,'nisCarrierStatus','notAvailable'));
        fprintf(fid, 'NEES pos/vel/clk/att & \\texttt{%s} / \\texttt{%s} / \\texttt{%s} / \\texttt{%s}\\\\\\\\\n', ...
            CE.safeField_(summary,'neesPositionStatus','notAvailable'), ...
            CE.safeField_(summary,'neesVelocityStatus','notAvailable'), ...
            CE.safeField_(summary,'neesClockStatus','notAvailable'), ...
            CE.safeField_(summary,'neesAttitudeStatus','notAvailable'));
    end
    fprintf(fid, '\\bottomrule\n\\end{tabular}\n\n\\vspace{6pt}\n');


    % ---- 7. Known limitations ---
    fprintf(fid, '\\textbf{Known v1 limitations}\n\n');
    fprintf(fid, '\\begin{tabular}{p{0.92\\textwidth}}\n\\toprule\n');
    fprintf(fid, 'No external RINEX/SP3/CLK/ANTEX/IONEX products ingested; tower clock product is synthetic (Stage 71/72).\\\\\n');
    fprintf(fid, 'No PPP-grade or operational navigation claim.\\\\\n');
    fprintf(fid, 'No LAMBDA/MLAMBDA; Stage 70/75/76 baseline AR: raw L1 (Stage 70/75) and raw L1+L2 integer-pair with wide-lane consistency screening (Stage 76); carrier-IF integer fixing is explicitly unsupported; false-fix risk is \\texttt{screenedNotFormal}; multi-asset estimation unsupported and guarded; differential ionosphere in baseline AR neglected (short receiver baselines).\\\\\n');
    fprintf(fid, 'No mission-qualified attitude determination (synthetic controlled scenario only).\\\\\n');
    fprintf(fid, 'No calibrated hardware bias/DCB/phase-bias products.\\\\\n');
    fprintf(fid, 'Doppler Stage~84 frameConsistentV2 (hardened): ECI-consistent range-rate (tower rotational velocity / Sagnac-rate capturedByTowerVelocityTerm); Doppler R diagonal double-count fixed (trackingOnlyPlusBlock); product-drift anchored at product-epoch truth; lever-arm velocity and relativistic range-rate not implemented.\\\\\n');
    fprintf(fid, 'IF covariance: uncorrelated noise assumption ($\\mathrm{Cov}(L_1,L_2)=0$).\\\\\n');
    fprintf(fid, 'Scientific atmosphere: no GPT3/VMF3/ERA5 troposphere; no Klobuchar/IONEX ionosphere.\\\\\n');
    fprintf(fid, 'No IERS/EOP-grade GCRS/ITRF reference-frame processing.\\\\\n');
    fprintf(fid, 'Full validation suite NOT RUN (targeted random smoke only).\\\\\n');
    fprintf(fid, '\\bottomrule\n\\end{tabular}\n');
    fprintf(fid, '\\end{center}\n');
end
