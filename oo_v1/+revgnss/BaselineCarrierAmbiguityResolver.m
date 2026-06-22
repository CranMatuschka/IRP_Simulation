classdef BaselineCarrierAmbiguityResolver
    % BaselineCarrierAmbiguityResolver  Stage 70/75: raw-L1 baseline differential integer search.
    %
    % For each tower/baseline, resolves ΔN in:
    %   ΔΦ − Δρ(q_ref) = λ_L1 · ΔN + noise
    %
    % using accumulated sufficient statistics (S1=Σresid, S2=Σresid², n=count).
    % The reference attitude q_ref comes from DiffAttitudeBuilder.referenceAttitude_euler_rad
    % when referenceMode='externalInitialAttitude', providing a float ambiguity close to the
    % true integer.  No LAMBDA/MLAMBDA, no carrier-IF fixing.
    %
    % Stage 70 acceptance gates (all must pass):
    %   n >= minArcEpochs
    %   RMS_residual(N_best) < rmsThreshold_m
    %   ratio = RMS(N_second) / RMS(N_best) > ratioThreshold
    %
    % Stage 75 additional gate:
    %   |N_float - N_best| < maxFloatDistance_cycles  (float-distance guard)
    %
    % Stage 75 per-baseline ambiguityStatus values:
    %   'fixedInteger'              — passed all gates
    %   'rejectedInsufficientArc'   — n < minArcEpochs
    %   'rejectedRms'               — rms >= rmsThreshold_m (first failing gate after arc)
    %   'rejectedRatio'             — ratio <= ratioThreshold (rms passed)
    %   'rejectedFloatDistance'     — |N_float-N_best| >= maxFloatDistance_cycles
    %   'floatExternalReference'    — AR disabled or baseline not attempted
    %
    % Stage 75 global classification (stored in store.integerClassification):
    %   'notAttempted'              — AR disabled or nBaselines=0
    %   'fixedAll'                  — all baselines passed gates
    %   'mixedFixedFloat'           — partial fix; float baselines included in EKF
    %   'fixedPartialExcludedFloat' — partial fix; float baselines excluded from EKF
    %   'fallbackExternalRef'       — no baselines passed; Stage 69 float delta_B retained
    %
    % gnssOnlyAttitudeClaim: true only when all baselines fixed AND no extRef calibration
    %   used.  Controlled by requireAllForGnssOnlyClaim config flag.

    methods (Static)

        function store = resolve(store, cfg)
            % resolve  Attempt integer fix for all baselines; update store.delta_B.
            [arEn, c] = revgnss.BaselineCarrierAmbiguityResolver.parseCfg_(cfg);
            % Stage 70/75: initialise summary fields
            store.integerFixAttempted           = false;
            store.integerFixAccepted            = false;
            store.nIntegerFixed                 = 0;
            store.nIntegerRejected              = 0;
            store.integerClassification         = 'notAttempted';
            store.externalRefUsedAsSearchCenter = false;
            store.externalRefUsedForCalibration = true;
            % Stage 75: new global fields
            store.gnssOnlyAttitudeClaim         = false;
            store.falseFixClassification        = c.falseFixClassification;
            store.phaseBiasStatus               = c.phaseBiasStatus;
            store.partialFixPolicy              = c.partialFixPolicy;
            store.nBaselineArFloatExternal      = 0;
            store.nBaselineArRejectedArc        = 0;
            % Stage 75: per-baseline metadata (cell/matrix, nTowers x nBaselines)
            store.ambiguityStatus   = repmat({'floatExternalReference'}, store.nTowers, store.nBaselines);
            store.N_float_all       = zeros(store.nTowers, store.nBaselines);
            store.floatDistance_all = zeros(store.nTowers, store.nBaselines);
            store.rmsBest_all       = zeros(store.nTowers, store.nBaselines);
            store.rmsSecond_all     = zeros(store.nTowers, store.nBaselines);
            store.ratio_all         = zeros(store.nTowers, store.nBaselines);
            store.N_int = zeros(store.nTowers, store.nBaselines);
            if ~arEn || store.nBaselines < 1; return; end

            store.integerFixAttempted           = true;
            store.externalRefUsedAsSearchCenter = ...
                ~isempty(store.referenceAttitude_euler_rad) && c.useExtRefAsCenter;

            lambda = c.lambda_m;
            nFixed = 0; nRejArc = 0; nRejGates = 0;
            for ti = 1:store.nTowers
                for bi = 1:store.nBaselines
                    n  = store.accumN(ti,bi);
                    S1 = store.accumSum(ti,bi);    % Σ(ΔΦ − Δρ_ref)  [m]
                    S2 = store.accumSumSq(ti,bi);  % Σ(ΔΦ − Δρ_ref)² [m²]
                    % Gate 1: arc length
                    if n < c.minArcEpochs
                        store.ambiguityStatus{ti,bi} = 'rejectedInsufficientArc';
                        nRejArc = nRejArc + 1; continue
                    end
                    N_float = S1 / (n * lambda);
                    store.N_float_all(ti,bi) = N_float;
                    hw    = c.searchHalfWidth;
                    cands = (floor(N_float) - hw) : (ceil(N_float) + hw);
                    costs = zeros(1, numel(cands));
                    for kc = 1:numel(cands)
                        Nk = cands(kc);
                        % cost² = (S2 − 2λNk·S1 + n(λNk)²) / n
                        cs = (S2 - 2*lambda*Nk*S1 + n*(lambda*Nk)^2) / n;
                        costs(kc) = sqrt(max(0, cs));
                    end
                    [sc, si] = sort(costs);
                    rms1   = sc(1);
                    rms2   = Inf; if numel(sc) > 1; rms2 = sc(2); end
                    ratio  = rms2 / max(rms1, 1e-12);
                    N_best = cands(si(1));
                    floatDist = abs(N_float - N_best);
                    store.rmsBest_all(ti,bi)       = rms1;
                    store.rmsSecond_all(ti,bi)     = rms2;
                    store.ratio_all(ti,bi)         = ratio;
                    store.floatDistance_all(ti,bi) = floatDist;
                    % Gate evaluation (Stage 70 gates + Stage 75 float-distance gate)
                    rmsOk   = rms1 < c.rmsThreshold_m;
                    ratioOk = ratio > c.ratioThreshold;
                    fdOk    = floatDist < c.maxFloatDistance_cycles;
                    if rmsOk && ratioOk && fdOk
                        store.N_int(ti,bi)   = N_best;
                        store.delta_B(ti,bi) = lambda * N_best;
                        store.ambiguityStatus{ti,bi} = 'fixedInteger';
                        nFixed = nFixed + 1;
                    else
                        nRejGates = nRejGates + 1;
                        % Assign specific rejection reason at first failing gate
                        if ~rmsOk
                            store.ambiguityStatus{ti,bi} = 'rejectedRms';
                        elseif ~ratioOk
                            store.ambiguityStatus{ti,bi} = 'rejectedRatio';
                        else
                            store.ambiguityStatus{ti,bi} = 'rejectedFloatDistance';
                        end
                    end
                end
            end

            store.nIntegerFixed            = nFixed;
            store.nIntegerRejected         = nRejArc + nRejGates;
            store.nBaselineArFloatExternal = nRejGates;  % had epochs, failed integer gates → float calibration retained
            store.nBaselineArRejectedArc   = nRejArc;    % insufficient arc → not attempted
            total = store.nTowers * store.nBaselines;

            if nFixed == total && total > 0
                store.integerFixAccepted            = true;
                store.externalRefUsedForCalibration = false;
                store.integerClassification         = 'fixedAll';
                fprintf('  [DiffAttAR] %d/%d baselines integer-fixed (extRef used as search centre only)\n', ...
                    nFixed, total);
            elseif nFixed > 0
                store.integerFixAccepted = true;
                if strcmp(c.partialFixPolicy,'mixedFixedFloat')
                    store.integerClassification         = 'mixedFixedFloat';
                    store.externalRefUsedForCalibration = true;
                else  % 'useFixedOnlyOrExplicitMixed' or 'fixedOnly'
                    store.integerClassification         = 'fixedPartialExcludedFloat';
                    store.externalRefUsedForCalibration = false;
                end
                fprintf('  [DiffAttAR] %d/%d baselines integer-fixed (partial; policy=%s)\n', ...
                    nFixed, total, c.partialFixPolicy);
            else
                store.integerFixAccepted            = false;
                store.externalRefUsedForCalibration = true;
                store.integerClassification         = 'fallbackExternalRef';
                fprintf('  [DiffAttAR] Integer fix: all %d baselines failed gates; fallback to external-reference float calibration\n', total);
            end
            % Non-fixed baselines already retain the Stage 69 float delta_B value
            % computed by DiffAttitudeBuilder.finalize() before this call.

            % Stage 75: GNSS-only attitude claim.
            % True only when all baselines are integer-fixed and no extRef calibration is used.
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
            c.lambda_m          = 299792458 / 1575.42e6;   % GPS L1 wavelength [m] ≈ 0.1903 m
            c.searchHalfWidth   = 5;
            c.minArcEpochs      = 10;
            c.rmsThreshold_m    = 0.10 * c.lambda_m;       % 0.10 cycles in metres
            c.ratioThreshold    = 2.0;
            c.useExtRefAsCenter = true;
            % Stage 75 defaults (backward-compatible: float-distance gate disabled by default)
            c.maxFloatDistance_cycles    = Inf;
            c.phaseBiasStatus            = 'notCalibratedExternalProduct';
            c.requireAllForGnssOnlyClaim = true;
            c.partialFixPolicy           = 'mixedFixedFloat';  % original Stage 70 behavior
            c.falseFixClassification     = 'screenedNotFormal';
            % Stage 70 config reads
            try; c.searchHalfWidth = cfg.estimator.diffAtt.ambiguityResolution.searchHalfWidth_cycles; catch; end
            try; c.minArcEpochs    = cfg.estimator.diffAtt.ambiguityResolution.minArcEpochs;           catch; end
            try
                thCyc = cfg.estimator.diffAtt.ambiguityResolution.rmsThreshold_cycles;
                c.rmsThreshold_m = thCyc * c.lambda_m;
            catch; end
            try; c.ratioThreshold   = cfg.estimator.diffAtt.ambiguityResolution.ratioThreshold;                         catch; end
            try; c.useExtRefAsCenter = logical(cfg.estimator.diffAtt.ambiguityResolution.useExternalReferenceAsSearchCenter); catch; end
            % Stage 75 config reads
            try; c.maxFloatDistance_cycles    = cfg.estimator.diffAtt.ambiguityResolution.maxFloatDistance_cycles;       catch; end
            try; c.phaseBiasStatus            = cfg.estimator.diffAtt.ambiguityResolution.phaseBiasStatus;               catch; end
            try; c.requireAllForGnssOnlyClaim = logical(cfg.estimator.diffAtt.ambiguityResolution.requireAllForGnssOnlyClaim); catch; end
            try; c.partialFixPolicy           = cfg.estimator.diffAtt.ambiguityResolution.partialFixPolicy;               catch; end
            try; c.falseFixClassification     = cfg.estimator.diffAtt.ambiguityResolution.falseFixClassification;         catch; end
        end

    end  % private Static
end
