classdef BaselineCarrierAmbiguityResolver
    % BaselineCarrierAmbiguityResolver  Stage 70: raw-L1 baseline differential integer search.
    %
    % For each tower/baseline, resolves ΔN in:
    %   ΔΦ − Δρ(q_ref) = λ_L1 · ΔN + noise
    %
    % using accumulated sufficient statistics (S1=Σresid, S2=Σresid², n=count).
    % The reference attitude q_ref comes from DiffAttitudeBuilder.referenceAttitude_euler_rad
    % when referenceMode='externalInitialAttitude', providing a float ambiguity close to the
    % true integer.  No LAMBDA/MLAMBDA, no carrier-IF fixing, no false-fix-risk control.
    %
    % Acceptance gates (all must pass):
    %   n >= minArcEpochs
    %   RMS_residual(N_best) < rmsThreshold_m
    %   ratio = RMS(N_second) / RMS(N_best) > ratioThreshold
    %
    % Classification (stored in store.integerClassification):
    %   'notAttempted'       — AR disabled or nBaselines=0
    %   'fixedAll'           — all baselines passed gates
    %   'fixedPartial'       — some baselines passed; others retain float delta_B
    %   'fallbackExternalRef'— no baselines passed; Stage 69 float delta_B retained

    methods (Static)

        function store = resolve(store, cfg)
            % resolve  Attempt integer fix for all baselines; update store.delta_B.
            [arEn, c] = revgnss.BaselineCarrierAmbiguityResolver.parseCfg_(cfg);
            % Initialise Stage 70 summary fields
            store.integerFixAttempted           = false;
            store.integerFixAccepted            = false;
            store.nIntegerFixed                 = 0;
            store.nIntegerRejected              = 0;
            store.integerClassification         = 'notAttempted';
            store.externalRefUsedAsSearchCenter = false;
            store.externalRefUsedForCalibration = true;
            store.N_int = zeros(store.nTowers, store.nBaselines);
            if ~arEn || store.nBaselines < 1; return; end

            store.integerFixAttempted           = true;
            store.externalRefUsedAsSearchCenter = ...
                ~isempty(store.referenceAttitude_euler_rad) && c.useExtRefAsCenter;

            lambda  = c.lambda_m;
            nFixed  = 0;
            nRej    = 0;
            for ti = 1:store.nTowers
                for bi = 1:store.nBaselines
                    n  = store.accumN(ti,bi);
                    S1 = store.accumSum(ti,bi);    % Σ(ΔΦ − Δρ_ref)  [m]
                    S2 = store.accumSumSq(ti,bi);  % Σ(ΔΦ − Δρ_ref)² [m²]
                    if n < c.minArcEpochs
                        nRej = nRej + 1; continue
                    end
                    N_float = S1 / (n * lambda);
                    hw      = c.searchHalfWidth;
                    cands   = (floor(N_float) - hw) : (ceil(N_float) + hw);
                    costs   = zeros(1, numel(cands));
                    for kc = 1:numel(cands)
                        Nk = cands(kc);
                        % cost² = (S2 − 2λNk·S1 + n(λNk)²) / n
                        cs = (S2 - 2*lambda*Nk*S1 + n*(lambda*Nk)^2) / n;
                        costs(kc) = sqrt(max(0, cs));
                    end
                    [sc, si] = sort(costs);
                    rms1 = sc(1);
                    if numel(sc) > 1
                        rms2 = sc(2);
                    else
                        rms2 = Inf;
                    end
                    ratio = rms2 / max(rms1, 1e-12);
                    if rms1 < c.rmsThreshold_m && ratio > c.ratioThreshold
                        store.N_int(ti,bi)   = cands(si(1));
                        store.delta_B(ti,bi) = lambda * store.N_int(ti,bi);
                        nFixed = nFixed + 1;
                    else
                        nRej = nRej + 1;
                    end
                end
            end

            store.nIntegerFixed   = nFixed;
            store.nIntegerRejected = nRej;
            total = store.nTowers * store.nBaselines;

            if nFixed == total && total > 0
                store.integerFixAccepted            = true;
                store.externalRefUsedForCalibration = false;
                store.integerClassification         = 'fixedAll';
                fprintf('  [DiffAttAR] %d/%d baselines integer-fixed (extRef used as search centre only)\n', ...
                    nFixed, total);
            elseif nFixed > 0
                store.integerFixAccepted            = true;
                store.externalRefUsedForCalibration = false;
                store.integerClassification         = 'fixedPartial';
                fprintf('  [DiffAttAR] %d/%d baselines integer-fixed (partial; rest retain float delta_B)\n', ...
                    nFixed, total);
            else
                store.integerFixAccepted            = false;
                store.externalRefUsedForCalibration = true;
                store.integerClassification         = 'fallbackExternalRef';
                fprintf('  [DiffAttAR] Integer fix: all %d baselines failed gates; fallback to external-reference float calibration\n', ...
                    total);
            end
            % Non-fixed baselines already retain the Stage 69 float delta_B value
            % computed by DiffAttitudeBuilder.finalize() before this call.
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
            try; c.searchHalfWidth = cfg.estimator.diffAtt.ambiguityResolution.searchHalfWidth_cycles; catch; end
            try; c.minArcEpochs    = cfg.estimator.diffAtt.ambiguityResolution.minArcEpochs;           catch; end
            try
                thCyc = cfg.estimator.diffAtt.ambiguityResolution.rmsThreshold_cycles;
                c.rmsThreshold_m = thCyc * c.lambda_m;
            catch; end
            try; c.ratioThreshold  = cfg.estimator.diffAtt.ambiguityResolution.ratioThreshold;               catch; end
            try; c.useExtRefAsCenter = logical(cfg.estimator.diffAtt.ambiguityResolution.useExternalReferenceAsSearchCenter); catch; end
        end

    end  % private Static
end
