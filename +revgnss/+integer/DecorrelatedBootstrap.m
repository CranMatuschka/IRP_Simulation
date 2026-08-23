classdef DecorrelatedBootstrap
    % DecorrelatedBootstrap  Integer ambiguity resolution with a success rate you can defend.
    %
    % WHY THIS EXISTS ALONGSIDE revgnss.integer.LambdaResolver. That class is the right answer
    % and wraps the canonical TU Delft LAMBDA 4.0 -- but the toolbox carries no licence grant, so
    % it is not vendored, and cfg.estimator.lambda.toolboxPath is empty on a fresh checkout.
    % Execution-plan Phase F cannot depend on a component that is absent by default, so this
    % class supplies the same three things natively:
    %
    %   1. DECORRELATION. Integer Gauss transformations and adjacent permutations that make the
    %      conditional variances as small and as uniform as possible. Without it, bootstrapping
    %      on a strongly correlated double-difference covariance succeeds essentially never.
    %   2. INTEGER BOOTSTRAPPING. Sequential conditional rounding. It is NOT the best integer
    %      estimator -- integer least squares is -- but its success rate is EXACT and is a
    %      rigorous LOWER BOUND for ILS, which is the property that matters when the number
    %      being reported is "how often does this fix correctly".
    %   3. A BOUNDED ILS SEARCH, for the ratio test. Depth-first search-and-shrink with a node
    %      budget. When the budget is exhausted the class SAYS SO and falls back to the
    %      bootstrapped answer rather than reporting a search it did not finish.
    %
    % THE NUMBER THIS CLASS EXISTS TO PRODUCE IS P(FALSE FIX), NOT A FIX RATE. A fix rate
    % measured against an integer the experiment drew itself is a self-check; a real receiver has
    % no such integer. successRate here is computed from the COVARIANCE alone -- no truth of any
    % kind enters -- which is why it can be quoted for a fix that has no ground truth behind it.
    %
    % CONVENTION, stated because getting it wrong is silent. Q = L*D*L' with L unit LOWER
    % triangular and D = diag(d). The quadratic form is then
    %       (aHat-a)' inv(Q) (aHat-a) = sum_i w_i^2/d_i,   w_i = e_i - sum_{j<i} L(i,j) w_j
    % so components are conditioned in increasing index order and d_i is the variance of
    % component i conditioned on 1..i-1. The transformation is z = Z'*a with Z unimodular, so
    % Qz = Z'*Q*Z and a = inv(Z)'*z. verifyTransform() asserts exactly that invariant, and
    % tests/test_decorrelated_bootstrap.m checks it against brute force on small problems.
    %
    %   [aFix, info] = revgnss.integer.DecorrelatedBootstrap.resolve(aHat_cyc, Qa_cyc, opts)

    properties (Constant, Access = private)
        MAX_SWEEPS = 40;
        NODE_BUDGET_DEFAULT = 200000;
    end

    methods (Static)

        function [aFix, info] = resolve(aHat, Qa, opts)
            % resolve  Fix, or refuse and say why. aFix is the FLOAT input when not accepted, so
            % a caller that ignores info still behaves safely.
            D = revgnss.integer.DecorrelatedBootstrap;
            if nargin < 3; opts = struct(); end
            opts = D.defaults_(opts);
            aHat = aHat(:);
            info = D.blankInfo_(numel(aHat));
            aFix = aHat;
            if isempty(aHat); info.decision = 'no-ambiguities'; return; end

            Qa = (Qa + Qa.')/2;
            if ~all(isfinite(Qa(:))) || ~all(isfinite(aHat))
                info.decision = 'reject-nonfinite'; return
            end

            % --- decorrelate ---------------------------------------------------------------
            [Z, L, d, okRed] = D.reduce_(Qa);
            if ~okRed
                info.decision = 'reject-notPositiveDefinite'; return
            end
            info.conditionBefore = D.adop_(Qa);
            info.conditionAfter  = exp(mean(log(max(d, realmin))))^0.5;
            zHat = Z.' * aHat;

            % --- bootstrapped success rate, from the covariance alone ----------------------
            % P_s = prod( 2*Phi(1/(2*sigma_i|I)) - 1 ). Exact for bootstrapping, and a
            % rigorous lower bound for ILS.
            sig = sqrt(max(d, realmin));
            info.successRate = prod(2*D.normcdf_(1./(2*sig)) - 1);
            info.failureRate = 1 - info.successRate;
            info.adop_cyc    = info.conditionAfter;
            if ~isfinite(info.successRate) || info.successRate < opts.minSuccessRate
                info.decision = 'reject-lowSuccessRate';
                info.message = sprintf('P_s = %.6f < required %.6f', ...
                    info.successRate, opts.minSuccessRate);
                return
            end

            % --- bootstrap ------------------------------------------------------------------
            zBoot = D.bootstrap_(zHat, L);
            info.nFixed = numel(zBoot);

            % --- bounded ILS, for the discrimination test -----------------------------------
            [zBest, sqn, nodes, exhausted] = D.ils_(zHat, L, d, zBoot, ...
                opts.nodeBudget, opts.ratioThreshold);
            info.searchNodes = nodes;
            info.searchExhausted = exhausted;
            info.sqnorm = sqn;
            if exhausted
                info.estimator = 'bootstrap';
                info.message = sprintf(['ILS node budget (%d) exhausted; reporting the ' ...
                    'BOOTSTRAPPED fix, whose success rate is exact and is a lower bound for ' ...
                    'ILS. No ratio test was possible.'], opts.nodeBudget);
                zFix = zBoot;
            else
                info.estimator = 'ils';
                zFix = zBest;
                if sqn(1) > 0
                    % An unfound runner-up sat outside an ellipsoid of (threshold+1)*best, so
                    % Inf here means "further away than the test needs", not "unknown".
                    info.ratio = sqn(2)/sqn(1);
                else
                    info.ratio = Inf;
                end
                if info.ratio < opts.ratioThreshold
                    info.decision = 'reject-ratioTest';
                    info.message = sprintf('ratio = %.3f < %.3f', ...
                        info.ratio, opts.ratioThreshold);
                    return
                end
            end
            info.bootstrapMatchesIls = isequal(zFix, zBoot);

            % --- back to the original parameterisation --------------------------------------
            aFix = round(D.invZt_(Z, zFix));
            info.accepted = true;
            info.decision = 'accepted';
        end

        function [Z, L, d, ok] = reduce_(Q)
            % reduce_  Decorrelating unimodular transformation, exposed so tests can assert the
            % invariant Z'*Q*Z = L*D*L' directly.
            D = revgnss.integer.DecorrelatedBootstrap;
            n = size(Q,1);
            Z = eye(n); ok = true;
            [L, d, ok0] = D.ldl_(Q);
            if ~ok0; L = []; d = []; ok = false; return; end

            for sweep = 1:D.MAX_SWEEPS
                changed = false;
                % Integer Gauss: drive every |L(i,j)| below 1/2, largest j first so the
                % reductions do not undo one another.
                for j = n-1:-1:1
                    for i = n:-1:j+1
                        mu = round(L(i,j));
                        if mu ~= 0
                            L(i,:) = L(i,:) - mu*L(j,:);
                            Z(:,i) = Z(:,i) - mu*Z(:,j);
                            changed = true;
                        end
                    end
                end
                % Adjacent permutation when it shrinks a conditional variance. Re-factorising
                % after the swap rather than applying the closed-form 2x2 update is O(n^3) but
                % it is GUARANTEED consistent; n here is the double-difference count, tens at
                % most, and the alternative is a convention error that would silently overstate
                % the success rate.
                swapped = false;
                for k = 1:n-1
                    dbar = d(k)*L(k+1,k)^2 + d(k+1);
                    if dbar < d(k) - 1e-12*max(1,d(k))
                        p = 1:n; p([k k+1]) = [k+1 k];
                        Z = Z(:,p);
                        Qz = Z.'*Q*Z; Qz = (Qz+Qz.')/2;
                        [L, d, okS] = D.ldl_(Qz);
                        if ~okS; ok = false; return; end
                        swapped = true; changed = true;
                        break                       % restart the scan; d has changed throughout
                    end
                end
                if ~changed && ~swapped; break; end
            end
        end

        function ok = verifyTransform(Q, Z, L, d, tol)
            % verifyTransform  The invariant, as a callable assertion: Z is unimodular and
            % Z'*Q*Z = L*diag(d)*L'. A decorrelation that violates either would produce a
            % success rate that is not a property of the problem.
            if nargin < 5; tol = 1e-6; end
            detZ = round(det(Z));
            ok = abs(abs(detZ) - 1) < 1e-6 ...
                && all(all(abs(Z - round(Z)) < 1e-9)) ...
                && norm(Z.'*Q*Z - L*diag(d)*L.', 'fro') <= tol*max(1, norm(Q,'fro'));
        end
    end

    methods (Static, Access = private)

        function o = defaults_(o)
            d = struct('minSuccessRate', 0.999, 'ratioThreshold', 2.0, ...
                'nodeBudget', revgnss.integer.DecorrelatedBootstrap.NODE_BUDGET_DEFAULT);
            f = fieldnames(d);
            for i = 1:numel(f)
                if ~isfield(o,f{i}) || isempty(o.(f{i})); o.(f{i}) = d.(f{i}); end
            end
        end

        function [L, d, ok] = ldl_(Q)
            % ldl_  Q = L*diag(d)*L', L unit lower triangular. Plain Cholesky-style recursion
            % rather than MATLAB's ldl(), which may pivot and would silently permute the
            % conditioning order this whole class is defined by.
            n = size(Q,1); L = eye(n); d = zeros(n,1); ok = true;
            A = Q;
            for k = 1:n
                d(k) = A(k,k);
                if ~(d(k) > 0) || ~isfinite(d(k)); ok = false; return; end
                if k < n
                    L(k+1:n,k) = A(k+1:n,k)/d(k);
                    A(k+1:n,k+1:n) = A(k+1:n,k+1:n) - L(k+1:n,k)*d(k)*L(k+1:n,k).';
                end
            end
        end

        function z = bootstrap_(zHat, L)
            % bootstrap_  Sequential conditional rounding in the conditioning order.
            n = numel(zHat); z = zeros(n,1); w = zeros(n,1);
            for i = 1:n
                cond = zHat(i);
                for j = 1:i-1
                    cond = cond - L(i,j)*w(j);
                end
                z(i) = round(cond);
                w(i) = cond - z(i);
            end
        end

        function [zBest, sqn, nodes, exhausted] = ils_(zHat, L, d, zInit, budget, ratioThreshold)
            % ils_  Depth-first search-and-shrink for the two best integer vectors, bounded.
            %
            % Minimises sum_i w_i^2/d_i with w_i = (zHat_i - z_i) - sum_{j<i} L(i,j) w_j, which
            % is exactly (zHat-z)' inv(Q) (zHat-z) under the LDL' convention documented above.
            %
            % THE INITIAL ELLIPSOID IS CHOSEN SO A MISSED RUNNER-UP CANNOT PRODUCE A FALSE
            % ACCEPT. The search starts inside chi2 = (ratioThreshold+1)*cost(bootstrap). Since
            % the bootstrap cost bounds the ILS optimum from above, anything not found inside
            % that ellipsoid has cost > (ratioThreshold+1)*best, i.e. a ratio comfortably past
            % the discrimination threshold -- so failing to find it can only make the test
            % HARDER to pass, never easier. Within the ellipsoid the bound shrinks to the
            % second-best cost as soon as two candidates exist, which is the usual search-and-
            % shrink behaviour.
            %
            % Offsets at each level are enumerated round(cond), then outward in the direction of
            % the residual first: cond rounds to z, and the sequence z, z+s, z-s, z+2s, ...
            % with s = sign(cond-z) makes |w| non-decreasing, so a pruned level can be abandoned
            % immediately rather than scanned to a fixed width.
            D = revgnss.integer.DecorrelatedBootstrap;
            n = numel(zHat);
            nodes = 0; exhausted = false;
            bootCost = D.cost_(zHat, L, d, zInit);
            zBest = zInit; bestCost = Inf; secondCost = Inf;
            chi2 = max((ratioThreshold+1)*bootCost, 1e-9*n);

            z = zeros(n,1); w = zeros(n,1); stp = zeros(n,1);
            cost = zeros(n+1,1); cond = zeros(n,1);
            i = 1; cost(1) = 0; cond(1) = zHat(1);
            z(1) = round(cond(1)); stp(1) = D.firstStep_(cond(1), z(1));

            while true
                nodes = nodes + 1;
                if nodes > budget; exhausted = true; sqn = [bestCost secondCost]; return; end
                wi = cond(i) - z(i);
                c  = cost(i) + wi^2/d(i);
                if c < chi2
                    if i < n
                        w(i) = wi; cost(i+1) = c;
                        cnd = zHat(i+1);
                        for j = 1:i; cnd = cnd - L(i+1,j)*w(j); end
                        cond(i+1) = cnd;
                        i = i + 1;
                        z(i) = round(cond(i)); stp(i) = D.firstStep_(cond(i), z(i));
                    else
                        if c < bestCost
                            secondCost = bestCost;
                            bestCost = c; zBest = z;
                        elseif c < secondCost
                            secondCost = c;
                        end
                        if isfinite(secondCost); chi2 = secondCost; end
                        z(i) = z(i) + stp(i); stp(i) = -stp(i) - sign(stp(i));
                    end
                else
                    if i == 1; break; end
                    i = i - 1;
                    z(i) = z(i) + stp(i); stp(i) = -stp(i) - sign(stp(i));
                end
            end
            if ~isfinite(bestCost); zBest = zInit; bestCost = bootCost; end
            sqn = [bestCost secondCost];
        end

        function s = firstStep_(cond, z)
            s = sign(cond - z);
            if s == 0; s = 1; end
        end

        function c = cost_(zHat, L, d, z)
            n = numel(zHat); w = zeros(n,1); c = 0;
            for i = 1:n
                cond = zHat(i);
                for j = 1:i-1
                    cond = cond - L(i,j)*w(j);
                end
                w(i) = cond - z(i);
                c = c + w(i)^2/d(i);
            end
        end

        function a = invZt_(Z, z)
            % invZt_  a = inv(Z)'*z, the inverse of z = Z'*a. Z is unimodular so the inverse is
            % integer; the round() at the call site removes float dust, not a real fraction.
            a = (Z.') \ z;
        end

        function v = adop_(Q)
            % adop_  Ambiguity dilution of precision: det(Q)^(1/(2n)) in cycles. The scalar that
            % says whether fixing is plausible at all, independent of dimension.
            n = size(Q,1);
            v = exp(sum(log(max(eig((Q+Q.')/2), realmin)))/(2*n));
        end

        function p = normcdf_(x)
            p = 0.5*erfc(-x/sqrt(2));
        end

        function info = blankInfo_(n)
            info = struct('accepted', false, 'decision', 'not-run', 'message', '', ...
                'n', n, 'nFixed', 0, 'successRate', NaN, 'failureRate', NaN, ...
                'ratio', NaN, 'sqnorm', [], 'adop_cyc', NaN, 'estimator', 'none', ...
                'conditionBefore', NaN, 'conditionAfter', NaN, ...
                'searchNodes', 0, 'searchExhausted', false, 'bootstrapMatchesIls', false);
        end
    end
end
