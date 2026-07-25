classdef BaselineAmbiguityLambda
    % BaselineAmbiguityLambda  Formal LAMBDA assessment of the attitude-baseline fix.
    %
    % Route A of docs/plans/ISL_LAMBDA/03: between-antenna single differencing cancels BOTH
    % the receiver and the tower clock, so the differential ambiguity dN is a TRUE INTEGER.
    % It is the only integer-ready parametrisation in this codebase, which makes it the
    % right place to put the LAMBDA engine to work on live data.
    %
    % WHAT THIS DOES -- AND, IMPORTANTLY, WHAT IT CANNOT DO
    %   revgnss.BaselineCarrierAmbiguityResolver resolves each (tower, baseline) INDEPENDENTLY
    %   by a scalar search over a +/-searchHalfWidth window. That is a SEPARABLE problem: the
    %   float ambiguities it produces have a DIAGONAL variance-covariance matrix, because the
    %   per-baseline accumulators carry no cross-baseline covariance.
    %
    %   For a diagonal Qa, integer least squares provably degenerates to bootstrapping and to
    %   plain rounding -- the Z-transformation has nothing to decorrelate (Teunissen 1998b;
    %   Verhagen 2005). So LAMBDA CANNOT return a different integer here, and any claim that
    %   "adding LAMBDA improved the attitude fix" would be false. T2 of the test pins the
    %   agreement rather than hoping for it.
    %
    %   The genuine contribution is the part the existing resolver explicitly lacks: it
    %   reports falseFixClassification = 'screenedNotFormal', i.e. gates but NO formal
    %   false-fix probability. Ps_LAMBDA supplies a rigorous bootstrapped SUCCESS RATE (a
    %   lower bound for ILS) and the matching failure rate. That upgrades the acceptance
    %   decision from heuristic screening to a quantified risk.
    %
    %   Realising ILS's actual advantage needs a JOINT float solution with genuine
    %   cross-baseline covariance (all baselines estimated together, sharing the attitude
    %   states). That is a larger change to DiffAttitudeBuilder and is deliberately NOT
    %   attempted here.
    %
    % REPORTING-ONLY. This does not modify store.delta_B / store.N_int; it annotates the
    % store with a formal assessment. Making LAMBDA authoritative is a separate, gated step
    % once the joint covariance above exists.

    methods (Static)

        function s = assess(store, cfg)
            % assess  Formal LAMBDA/Ps_LAMBDA assessment of an existing baseline fix.
            s = revgnss.integer.BaselineAmbiguityLambda.blank_();
            if ~revgnss.integer.BaselineAmbiguityLambda.gateOn_(cfg)
                s.classification = 'disabled-by-config'; return
            end
            s.enabled = true;
            if isempty(store) || ~isstruct(store) || ~isfield(store,'accumN')
                s.classification = 'unavailable-noStore'; return
            end
            if ~isfield(store,'nBaselines') || store.nBaselines < 1
                s.classification = 'unavailable-noBaselines'; return
            end

            lam = revgnss.integer.BaselineAmbiguityLambda.lambda_(cfg);
            [aHat_cyc, var_cyc, nInt, ok] = ...
                revgnss.integer.BaselineAmbiguityLambda.gather_(store, lam);
            s.n = numel(aHat_cyc);
            if s.n < 1 || ~any(ok)
                s.classification = 'unavailable-noArcs'; return
            end
            aHat_cyc = aHat_cyc(ok);
            var_cyc  = var_cyc(ok);
            nInt     = nInt(ok);
            s.n      = numel(aHat_cyc);

            % DIAGONAL by construction -- the per-baseline accumulators carry no
            % cross-baseline covariance. Recorded explicitly so a reader is not misled
            % into thinking a joint ILS was performed.
            Qa_cyc = diag(var_cyc);
            s.covarianceStructure = 'diagonal-separablePerBaseline';
            s.meanSigma_cycles    = mean(sqrt(var_cyc));
            s.maxSigma_cycles     = max(sqrt(var_cyc));

            [aFix_cyc, info] = revgnss.integer.LambdaResolver.resolve(aHat_cyc, Qa_cyc, cfg);
            s.available      = info.available;
            s.decision       = info.decision;
            s.successRate    = info.successRate;
            s.failureRate    = info.failureRate;
            s.ratio          = info.ratio;
            s.nFixedByLambda = info.nFixed;
            s.accepted       = info.accepted;
            s.message        = info.message;

            if ~info.available
                s.classification = 'unavailable-toolbox'; return
            end

            s.lambdaIntegers   = round(aFix_cyc(:)');
            s.existingIntegers = round(nInt(:)');
            if info.accepted
                d = s.lambdaIntegers - s.existingIntegers;
                s.nDisagree = sum(d ~= 0);
                s.agrees    = s.nDisagree == 0;
                if s.agrees
                    s.classification = 'agrees-formalSuccessRate';
                else
                    % Theory says this cannot happen for a diagonal Qa; surface it loudly
                    % rather than quietly preferring one answer.
                    s.classification = 'DISAGREES-investigate';
                end
            else
                s.classification = ['notFixed-' info.decision];
            end
        end

        function lines = summaryLines(s)
            lines = {};
            lines{end+1} = sprintf('LAMBDA baseline AR   : %s', s.classification);
            if ~s.enabled; return; end
            lines{end+1} = sprintf('  nAmbiguities       : %d', s.n);
            lines{end+1} = sprintf('  covariance         : %s', s.covarianceStructure);
            if isfinite(s.successRate)
                lines{end+1} = sprintf('  successRate (IB)   : %.6f', s.successRate);
                lines{end+1} = sprintf('  failureRate        : %.6f', s.failureRate);
            end
            if isfinite(s.meanSigma_cycles)
                lines{end+1} = sprintf('  sigma mean/max cyc : %.4f / %.4f', ...
                    s.meanSigma_cycles, s.maxSigma_cycles);
            end
            lines{end+1} = sprintf('  ILSbeatsRounding   : false (diagonal Qa -> ILS == rounding)');
        end

    end

    methods (Static, Access = private)

        function tf = gateOn_(cfg)
            % Master LAMBDA gate AND the ground-domain gate. Independent of the ISL gate.
            tf = false;
            try
                tf = logical(cfg.estimator.lambda.enable) && ...
                     logical(cfg.estimator.lambda.ground.enable);
            catch; end
        end

        function lam = lambda_(cfg)
            lam = revgnss.SignalDefinition.get('L1').wavelength_m;
            try; lam = cfg.signals.wavelength_m(1); catch; end
        end

        function [aHat_cyc, var_cyc, nInt, ok] = gather_(store, lam)
            % Float ambiguity (cycles) and its variance per (tower, baseline).
            %
            %   N_float = S1 / (n*lambda)
            %   residual variance about the fit: s2 = (S2 - S1^2/n) / max(n-1,1)
            %   var(N_float) = s2 / (n * lambda^2)      [standard error of the mean]
            nT = store.nTowers; nB = store.nBaselines;
            m  = nT * nB;
            aHat_cyc = zeros(m,1); var_cyc = zeros(m,1); nInt = zeros(m,1);
            ok = false(m,1);
            k = 0;
            for ti = 1:nT
                for bi = 1:nB
                    k = k + 1;
                    n  = store.accumN(ti,bi);
                    S1 = store.accumSum(ti,bi);
                    S2 = store.accumSumSq(ti,bi);
                    if n < 2; continue; end
                    aHat_cyc(k) = S1 / (n * lam);
                    s2 = (S2 - (S1^2)/n) / max(n-1, 1);
                    s2 = max(s2, 0);
                    v  = s2 / (n * lam^2);
                    if ~isfinite(v) || v <= 0; v = eps; end
                    var_cyc(k) = v;
                    if isfield(store,'N_int'); nInt(k) = store.N_int(ti,bi); end
                    ok(k) = true;
                end
            end
        end

        function s = blank_()
            s = struct('enabled', false, 'available', false, 'accepted', false, ...
                'classification', 'notAttempted', 'decision', 'not-run', 'message', '', ...
                'n', 0, 'nFixedByLambda', 0, 'successRate', NaN, 'failureRate', NaN, ...
                'ratio', NaN, 'meanSigma_cycles', NaN, 'maxSigma_cycles', NaN, ...
                'covarianceStructure', 'unknown', 'lambdaIntegers', [], ...
                'existingIntegers', [], 'agrees', false, 'nDisagree', NaN);
        end

    end
end
