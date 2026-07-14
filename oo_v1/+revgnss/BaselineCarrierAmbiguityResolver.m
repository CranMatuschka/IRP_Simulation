classdef BaselineCarrierAmbiguityResolver
    % BaselineCarrierAmbiguityResolver  raw-L1 or raw-L1+L2 baseline AR.
    %
    % For each tower/baseline, resolves ΔN in (single-frequency):
    %   ΔΦ − Δρ(q_ref) = λ_L1 · ΔN + noise
    %
    % Dual-frequency: joint integer-pair (N1,N2) search when L2 enabled:
    %   ΔΦ_f − Δρ(q_ref) = λ_f · ΔN_f + noise_f,  f ∈ {L1, L2}
    %
    % No LAMBDA/MLAMBDA, no carrier-IF fixing, no formal false-fix probability.
    % Wide-lane consistency used as a screening gate only (not full WL/NL fixing).
    %
    % Acceptance gates (each must pass):
    %   n >= minArcEpochs
    %   RMS_residual(N_best) < rmsThreshold_m
    %   ratio = RMS(N_second) / RMS(N_best) > ratioThreshold
    %   |N_float - N_best| < maxFloatDistance_cycles
    %
    % Adds (dual-frequency path):
    %   both L1 and L2 arc epochs >= minArcEpochs
    %   per-frequency RMS below threshold
    %   combined J ratio > ratioThreshold
    %   per-frequency float-distance gate
    %   wide-lane consistency: |N_WL_float - (N1_best-N2_best)| < maxWideLaneFloatDistance_cycles
    %   phaseBiasStatus permits integer interpretation
    %
    % Per-baseline ambiguityStatus values:
    %   'fixedDualFrequencyRaw'     — joint L1+L2 fixed, all gates passed
    %   'fixedL1Only'               — L1 fixed; L2 failed gates (dual-freq attempted)
    %   'fixedInteger'              — L1 fixed; single-frequency mode
    %   'rejectedInsufficientArc'   — n < minArcEpochs
    %   'rejectedRms'               — rms >= rmsThreshold
    %   'rejectedRatio'             — ratio <= ratioThreshold (rms passed)
    %   'rejectedFloatDistance'     — |N_float-N_best| >= maxFloatDistance_cycles
    %   'rejectedWideLane'          — wide-lane consistency gate failed (dual-freq)
    %   'floatExternalReference'    — AR disabled or baseline not attempted
    %
    % Global integerClassification values:
    %   'fixedDualFrequencyRawAll'  — all baselines fixedDualFrequencyRaw
    %   'fixedL1OnlyAll'            — all baselines fixedL1Only (dual-freq attempted but L2 failed)
    %   'fixedMixedFrequency'       — mix of dual-freq and L1-only fixed
    %   'fixedAll'                  — all fixed (single-freq L1 mode)
    %   'mixedFixedFloat'           — partial fix; float baselines included
    %   'fixedPartialExcludedFloat' — partial fix; float baselines excluded
    %   'fallbackExternalRef'       — none fixed; float calibration retained
    %   'notAttempted'              — AR disabled or nBaselines=0

    methods (Static)

        function store = resolve(store, cfg)
            % resolve  Attempt integer fix for all baselines; update store.delta_B.
            [arEn, c] = revgnss.BaselineCarrierAmbiguityResolver.parseCfg_(cfg);
            if ~isfield(c,'falseFixClassification'); c.falseFixClassification = 'screenedNotFormal'; end
            if ~isfield(c,'phaseBiasStatus'); c.phaseBiasStatus = 'notCalibratedExternalProduct'; end
            if ~isfield(c,'partialFixPolicy'); c.partialFixPolicy = 'mixedFixedFloat'; end
            if ~isfield(c,'differentialIonosphereMode'); c.differentialIonosphereMode = 'neglectedShortBaselineV1'; end
            % Initialise summary fields
            store.integerFixAttempted           = false;
            store.integerFixAccepted            = false;
            store.nIntegerFixed                 = 0;
            store.nIntegerRejected              = 0;
            store.integerClassification         = 'notAttempted';
            store.externalRefUsedAsSearchCenter = false;
            store.externalRefUsedForCalibration = true;
            % Global fields
            store.gnssOnlyAttitudeClaim         = false;
            store.falseFixClassification        = c.falseFixClassification;
            store.phaseBiasStatus               = c.phaseBiasStatus;
            store.partialFixPolicy              = c.partialFixPolicy;
            store.nBaselineArFloatExternal      = 0;
            store.nBaselineArRejectedArc        = 0;
            % Per-baseline metadata (nTowers x nBaselines)
            store.ambiguityStatus   = repmat({'floatExternalReference'}, store.nTowers, store.nBaselines);
            store.N_float_all       = zeros(store.nTowers, store.nBaselines);
            store.floatDistance_all = zeros(store.nTowers, store.nBaselines);
            store.rmsBest_all       = zeros(store.nTowers, store.nBaselines);
            store.rmsSecond_all     = zeros(store.nTowers, store.nBaselines);
            store.ratio_all         = zeros(store.nTowers, store.nBaselines);
            store.N_int             = zeros(store.nTowers, store.nBaselines);
            % Dual-frequency fields
            store.nBaselineArFixedDualFrequency = 0;
            store.nBaselineArFixedL1Only        = 0;
            store.N_float_L2_all    = zeros(store.nTowers, store.nBaselines);
            store.floatDist_L2_all  = zeros(store.nTowers, store.nBaselines);
            store.rmsBest_L2_all    = zeros(store.nTowers, store.nBaselines);
            store.wideLaneN_float   = zeros(store.nTowers, store.nBaselines);
            store.wideLaneStatus    = repmat({'notAttempted'}, store.nTowers, store.nBaselines);
            store.dualFreqStatus    = repmat({'notAttempted'}, store.nTowers, store.nBaselines);
            store.delta_B_L2        = zeros(store.nTowers, store.nBaselines);
            store.N_int_L2          = zeros(store.nTowers, store.nBaselines);
            store.attitudeArMode    = 'rawL1Only';
            store.differentialIonosphereInBaselineAr = c.differentialIonosphereMode;

            if ~arEn || store.nBaselines < 1; return; end

            store.integerFixAttempted           = true;
            store.externalRefUsedAsSearchCenter = ...
                ~isempty(store.referenceAttitude_euler_rad) && c.useExtRefAsCenter;

            % Determine if dual-frequency AR is active
            dualEn = c.enabledByFrequency(1) && numel(c.enabledByFrequency) >= 2 && ...
                c.enabledByFrequency(2) && isfield(store,'accumN_L2');
            % Phase-bias guard: only allow integer fixing when bias is known zero or compatible
            phaseBiasOk = strcmp(c.phaseBiasStatus,'syntheticKnownZero') || ...
                strcmp(c.phaseBiasStatus,'calibratedExternalProduct') || ...
                strcmp(c.phaseBiasStatus,'notCalibratedExternalProduct');  % allow float, gate later

            if dualEn
                store.attitudeArMode = 'rawDualFrequencyPair';
            else
                store.attitudeArMode = 'rawL1Only';
            end

            lambda1 = c.lambda_m;
            lambda2 = c.lambda_m_L2;
            nFixed = 0; nRejArc = 0; nRejGates = 0;
            nFixedDual = 0; nFixedL1Only = 0;

            for ti = 1:store.nTowers
                for bi = 1:store.nBaselines
                    n1 = store.accumN(ti,bi);
                    S1_1 = store.accumSum(ti,bi);
                    S2_1 = store.accumSumSq(ti,bi);

                    % ---- Arc gate (L1) ----
                    if n1 < c.minArcEpochs
                        store.ambiguityStatus{ti,bi} = 'rejectedInsufficientArc';
                        nRejArc = nRejArc + 1; continue
                    end

                    % ---- L1 float + candidate search ----
                    N_float_1 = S1_1 / (n1 * lambda1);
                    store.N_float_all(ti,bi) = N_float_1;
                    hw = c.searchHalfWidth;
                    cands1 = (floor(N_float_1) - hw) : (ceil(N_float_1) + hw);
                    costs1 = zeros(1,numel(cands1));
                    for kc = 1:numel(cands1)
                        Nk = cands1(kc);
                        cs = (S2_1 - 2*lambda1*Nk*S1_1 + n1*(lambda1*Nk)^2) / n1;
                        costs1(kc) = sqrt(max(0,cs));
                    end
                    [sc1, si1] = sort(costs1);
                    rms1_best = sc1(1);
                    rms1_2nd  = Inf; if numel(sc1) > 1; rms1_2nd = sc1(2); end
                    N1_best   = cands1(si1(1));
                    fd1       = abs(N_float_1 - N1_best);
                    ratio1    = rms1_2nd / max(rms1_best, 1e-12);
                    store.rmsBest_all(ti,bi)       = rms1_best;
                    store.rmsSecond_all(ti,bi)     = rms1_2nd;
                    store.ratio_all(ti,bi)         = ratio1;
                    store.floatDistance_all(ti,bi) = fd1;

                    % ---- Single-frequency gates ----
                    rms1Ok = rms1_best < c.rmsThreshold_m;
                    fd1Ok  = fd1 < c.maxFloatDistance_cycles;
                    % Combined ratio for single-freq is ratio1
                    ratioOk1 = ratio1 > c.ratioThreshold;

                    if dualEn && phaseBiasOk
                        % ---- Dual-frequency path ----
                        n2   = store.accumN_L2(ti,bi);
                        S1_2 = store.accumSum_L2(ti,bi);
                        S2_2 = store.accumSumSq_L2(ti,bi);
                        n2ArcOk = (n2 >= c.minArcEpochs);

                        if n2ArcOk
                            % L2 candidate search
                            N_float_2 = S1_2 / (n2 * lambda2);
                            store.N_float_L2_all(ti,bi) = N_float_2;
                            cands2 = (floor(N_float_2) - hw) : (ceil(N_float_2) + hw);
                            costs2 = zeros(1,numel(cands2));
                            for kc = 1:numel(cands2)
                                Nk2 = cands2(kc);
                                cs2 = (S2_2 - 2*lambda2*Nk2*S1_2 + n2*(lambda2*Nk2)^2) / n2;
                                costs2(kc) = sqrt(max(0,cs2));
                            end
                            [sc2, si2] = sort(costs2);
                            rms2_best = sc2(1);
                            rms2_2nd  = Inf; if numel(sc2) > 1; rms2_2nd = sc2(2); end
                            N2_best   = cands2(si2(1));
                            fd2       = abs(N_float_2 - N2_best);
                            store.rmsBest_L2_all(ti,bi) = rms2_best;
                            store.floatDist_L2_all(ti,bi) = fd2;

                            % Combined joint cost ratio (separable cost)
                            J1_best = n1 * rms1_best^2;
                            J1_2nd  = n1 * rms1_2nd^2;
                            J2_best = n2 * rms2_best^2;
                            J2_2nd  = n2 * rms2_2nd^2;
                            J_best  = J1_best + J2_best;
                            J_2nd   = min(J1_2nd + J2_best, J1_best + J2_2nd);
                            ratioComb = J_2nd / max(J_best, 1e-24);

                            % Wide-lane consistency gate
                            N_WL_float = N_float_1 - N_float_2;
                            N_WL_int   = N1_best - N2_best;
                            wlDisc     = abs(N_WL_float - N_WL_int);
                            wlOk       = wlDisc < c.maxWideLaneFloatDistance_cycles;
                            store.wideLaneN_float(ti,bi) = N_WL_float;
                            if wlOk
                                store.wideLaneStatus{ti,bi} = 'passed';
                            else
                                store.wideLaneStatus{ti,bi} = 'failed';
                            end

                            rms2Ok = rms2_best < (c.rmsThreshold_m * lambda2 / lambda1);
                            fd2Ok  = fd2 < c.maxFloatDistance_cycles;
                            ratioCombOk = ratioComb > c.ratioThreshold;

                            if rms1Ok && rms2Ok && fd1Ok && fd2Ok && ratioCombOk && wlOk
                                store.N_int(ti,bi)    = N1_best;
                                store.N_int_L2(ti,bi) = N2_best;
                                store.delta_B(ti,bi)    = lambda1 * N1_best;
                                store.delta_B_L2(ti,bi) = lambda2 * N2_best;
                                store.ambiguityStatus{ti,bi} = 'fixedDualFrequencyRaw';
                                store.dualFreqStatus{ti,bi}  = 'fixedDualFrequencyRaw';
                                nFixed = nFixed + 1;
                                nFixedDual = nFixedDual + 1;
                            else
                                % Dual-freq failed — try L1-only fallback
                                if rms1Ok && ratioOk1 && fd1Ok
                                    store.N_int(ti,bi)   = N1_best;
                                    store.delta_B(ti,bi) = lambda1 * N1_best;
                                    store.ambiguityStatus{ti,bi} = 'fixedL1Only';
                                    store.dualFreqStatus{ti,bi}  = 'l2GatesFailed';
                                    nFixed = nFixed + 1;
                                    nFixedL1Only = nFixedL1Only + 1;
                                else
                                    % Determine first failing gate for rejection reason
                                    if ~rms1Ok
                                        store.ambiguityStatus{ti,bi} = 'rejectedRms';
                                    elseif ~ratioOk1
                                        store.ambiguityStatus{ti,bi} = 'rejectedRatio';
                                    elseif ~fd1Ok
                                        store.ambiguityStatus{ti,bi} = 'rejectedFloatDistance';
                                    elseif ~wlOk
                                        store.ambiguityStatus{ti,bi} = 'rejectedWideLane';
                                    else
                                        store.ambiguityStatus{ti,bi} = 'rejectedRms';
                                    end
                                    store.dualFreqStatus{ti,bi} = 'failed';
                                    nRejGates = nRejGates + 1;
                                end
                            end
                        else
                            % L2 arc insufficient — try L1-only
                            store.wideLaneStatus{ti,bi} = 'l2ArcInsufficient';
                            if rms1Ok && ratioOk1 && fd1Ok
                                store.N_int(ti,bi)   = N1_best;
                                store.delta_B(ti,bi) = lambda1 * N1_best;
                                store.ambiguityStatus{ti,bi} = 'fixedL1Only';
                                store.dualFreqStatus{ti,bi}  = 'l2ArcInsufficient';
                                nFixed = nFixed + 1;
                                nFixedL1Only = nFixedL1Only + 1;
                            else
                                if ~rms1Ok
                                    store.ambiguityStatus{ti,bi} = 'rejectedRms';
                                elseif ~ratioOk1
                                    store.ambiguityStatus{ti,bi} = 'rejectedRatio';
                                else
                                    store.ambiguityStatus{ti,bi} = 'rejectedFloatDistance';
                                end
                                nRejGates = nRejGates + 1;
                            end
                        end

                    else
                        % ---- Single-frequency path (behavior) ----
                        if rms1Ok && ratioOk1 && fd1Ok
                            store.N_int(ti,bi)   = N1_best;
                            store.delta_B(ti,bi) = lambda1 * N1_best;
                            store.ambiguityStatus{ti,bi} = 'fixedInteger';
                            nFixed = nFixed + 1;
                        else
                            nRejGates = nRejGates + 1;
                            if ~rms1Ok
                                store.ambiguityStatus{ti,bi} = 'rejectedRms';
                            elseif ~ratioOk1
                                store.ambiguityStatus{ti,bi} = 'rejectedRatio';
                            else
                                store.ambiguityStatus{ti,bi} = 'rejectedFloatDistance';
                            end
                        end
                    end

                end  % bi
            end  % ti

            store.nIntegerFixed              = nFixed;
            store.nIntegerRejected           = nRejArc + nRejGates;
            store.nBaselineArFloatExternal   = nRejGates;
            store.nBaselineArRejectedArc     = nRejArc;
            store.nBaselineArFixedDualFrequency = nFixedDual;
            store.nBaselineArFixedL1Only        = nFixedL1Only;
            total = store.nTowers * store.nBaselines;

            % Global classification
            if dualEn
                if nFixedDual == total && total > 0
                    store.integerFixAccepted            = true;
                    store.externalRefUsedForCalibration = false;
                    store.integerClassification         = 'fixedDualFrequencyRawAll';
                    fprintf('  [DiffAttAR] %d/%d baselines fixedDualFrequencyRaw\n', nFixedDual, total);
                elseif nFixed == total && total > 0 && nFixedL1Only > 0
                    store.integerFixAccepted            = true;
                    store.externalRefUsedForCalibration = false;
                    if nFixedL1Only == total
                        store.integerClassification = 'fixedL1OnlyAll';
                    else
                        store.integerClassification = 'fixedMixedFrequency';
                    end
                    fprintf('  [DiffAttAR] %d/%d fixed (dual=%d, L1Only=%d)\n', ...
                        nFixed, total, nFixedDual, nFixedL1Only);
                elseif nFixed > 0
                    store.integerFixAccepted = true;
                    if strcmp(c.partialFixPolicy,'mixedFixedFloat')
                        store.integerClassification         = 'mixedFixedFloat';
                        store.externalRefUsedForCalibration = true;
                    else
                        store.integerClassification         = 'fixedPartialExcludedFloat';
                        store.externalRefUsedForCalibration = false;
                    end
                    fprintf('  [DiffAttAR] %d/%d baselines fixed (partial; policy=%s)\n', ...
                        nFixed, total, c.partialFixPolicy);
                else
                    store.integerFixAccepted            = false;
                    store.externalRefUsedForCalibration = true;
                    store.integerClassification         = 'fallbackExternalRef';
                    fprintf('  [DiffAttAR] All %d baselines failed gates; fallback to external-reference float\n', total);
                end
            else
                % Single-frequency classification (behavior preserved)
                if nFixed == total && total > 0
                    store.integerFixAccepted            = true;
                    store.externalRefUsedForCalibration = false;
                    store.integerClassification         = 'fixedAll';
                    fprintf('  [DiffAttAR] %d/%d baselines integer-fixed (L1 only; extRef search centre only)\n', nFixed, total);
                elseif nFixed > 0
                    store.integerFixAccepted = true;
                    if strcmp(c.partialFixPolicy,'mixedFixedFloat')
                        store.integerClassification         = 'mixedFixedFloat';
                        store.externalRefUsedForCalibration = true;
                    else
                        store.integerClassification         = 'fixedPartialExcludedFloat';
                        store.externalRefUsedForCalibration = false;
                    end
                    fprintf('  [DiffAttAR] %d/%d baselines integer-fixed (partial; policy=%s)\n', ...
                        nFixed, total, c.partialFixPolicy);
                else
                    store.integerFixAccepted            = false;
                    store.externalRefUsedForCalibration = true;
                    store.integerClassification         = 'fallbackExternalRef';
                    fprintf('  [DiffAttAR] Integer fix: all %d baselines failed gates; fallback\n', total);
                end
            end

            % GNSS-only attitude claim: true only when all baselines are integer-fixed
            % (dual or L1-only) and no external-reference calibration is used in EKF rows.
            if c.requireAllForGnssOnlyClaim
                store.gnssOnlyAttitudeClaim = (nFixed == total && total > 0 && ...
                    ~store.externalRefUsedForCalibration);
            else
                store.gnssOnlyAttitudeClaim = (nFixed > 0 && ~store.externalRefUsedForCalibration);
            end
        end

    end  % Static

    methods (Static, Access = private)

        function [en, c] = parseCfg_(cfg)
            en = false; c = struct();
            try; en = logical(cfg.estimator.diffAtt.ambiguityResolution.enable); catch; return; end
            % Derive wavelengths from canonical cfg.signals (set by finalizeConfig)
            % or SignalDefinition; no local hardcoded frequency constants.
            try
                c.lambda_m = cfg.signals.wavelength_m(1);
            catch
                c.lambda_m = revgnss.SignalDefinition.get('L1').wavelength_m;
            end
            try
                c.lambda_m_L2 = cfg.signals.wavelength_m(2);
            catch
                c.lambda_m_L2 = revgnss.SignalDefinition.get('L2').wavelength_m;
            end
            c.searchHalfWidth   = 5;
            c.minArcEpochs      = 10;
            c.rmsThreshold_m    = 0.10 * c.lambda_m;    % 0.10 cycles (L1 metres)
            c.ratioThreshold    = 2.0;
            c.useExtRefAsCenter = true;
            % Defaults
            c.maxFloatDistance_cycles    = Inf;
            c.phaseBiasStatus            = 'notCalibratedExternalProduct';
            c.requireAllForGnssOnlyClaim = true;
            c.partialFixPolicy           = 'mixedFixedFloat';
            c.falseFixClassification     = 'screenedNotFormal';
            % Defaults
            c.enabledByFrequency              = [true, false];  % L1 only by default
            c.maxWideLaneFloatDistance_cycles = 0.5;
            c.differentialIonosphereMode      = 'neglectedShortBaselineV1';
            % Config reads
            try; c.searchHalfWidth = cfg.estimator.diffAtt.ambiguityResolution.searchHalfWidth_cycles; catch; end
            try; c.minArcEpochs    = cfg.estimator.diffAtt.ambiguityResolution.minArcEpochs;           catch; end
            try
                thCyc = cfg.estimator.diffAtt.ambiguityResolution.rmsThreshold_cycles;
                c.rmsThreshold_m = thCyc * c.lambda_m;
            catch; end
            try; c.ratioThreshold    = cfg.estimator.diffAtt.ambiguityResolution.ratioThreshold;                             catch; end
            try; c.useExtRefAsCenter = logical(cfg.estimator.diffAtt.ambiguityResolution.useExternalReferenceAsSearchCenter); catch; end
            % Config reads
            try; c.maxFloatDistance_cycles    = cfg.estimator.diffAtt.ambiguityResolution.maxFloatDistance_cycles;            catch; end
            try; c.phaseBiasStatus            = cfg.estimator.diffAtt.ambiguityResolution.phaseBiasStatus;                    catch; end
            try; c.requireAllForGnssOnlyClaim = logical(cfg.estimator.diffAtt.ambiguityResolution.requireAllForGnssOnlyClaim); catch; end
            try; c.partialFixPolicy           = cfg.estimator.diffAtt.ambiguityResolution.partialFixPolicy;                    catch; end
            try; c.falseFixClassification     = cfg.estimator.diffAtt.ambiguityResolution.falseFixClassification;              catch; end
            % Config reads
            try; c.enabledByFrequency = logical(cfg.estimator.diffAtt.ambiguityResolution.enabledByFrequency); catch; end
            try; c.maxWideLaneFloatDistance_cycles = cfg.estimator.diffAtt.ambiguityResolution.maxWideLaneFloatDistance_cycles; catch; end
            try; c.differentialIonosphereMode = cfg.estimator.diffAtt.ambiguityResolution.differentialIonosphereInBaselineAr; catch; end
        end

    end  % private Static
end
