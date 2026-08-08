classdef GroundCarrierAmbiguityResolver
    % GroundCarrierAmbiguityResolver  Fix the ground double-difference integers WITHOUT truth.
    %
    % EXECUTION-PLAN F2, F4, F5 AND F6 -- the contribution. revgnss.GroundCarrierAmbiguityProbe
    % measures whether the integers COULD be fixed, by comparing against an integer it drew
    % itself. A real receiver has no such integer. This class decides, and then reports how often
    % it would be WRONG, from the covariance alone.
    %
    % WHY THE WIDE LANE COMES FIRST, AND WHY IT IS NOT THE ARGUMENT THE SUMMARY MADE. The stated
    % reason was wavelength: the DD prediction error is 0.148 m against a half-wavelength of
    % 0.431 m, so wide-lane clears by 2.9x and L1 does not. True, but it is the weaker argument,
    % because it makes the fix depend on the geometry error -- the very thing this programme is
    % trying to improve, so the reasoning is circular. The strong argument is that the wide-lane
    % ambiguity can be estimated from the MELBOURNE-WUBBENA combination
    %
    %       MW = (f1*L1 - f2*L2)/(f1 - f2)  -  (f1*P1 + f2*P2)/(f1 + f2)  =  lam_WL*N_WL + eps
    %
    % which is GEOMETRY-FREE and IONOSPHERE-FREE. The range, the orbit error, the shape error,
    % the rotation error and the ionosphere all cancel identically. The 0.148 m DD geometry error
    % that caps the code route does not enter at all, and the only thing standing between the
    % estimator and the integer is code noise divided by the square root of the arc length.
    % THAT is why the ladder starts at wide-lane, and it is why the bootstrap closes.
    %
    % THE CASCADE (F6):
    %   1. MW double difference, averaged over each ambiguity ARC -> float N_WL, with a
    %      covariance that accounts for the between-DD correlation the shared reference
    %      satellite and reference tower create.
    %   2. Integer-fix N_WL (revgnss.integer.DecorrelatedBootstrap, or LAMBDA when the toolbox
    %      is installed). Report P(false fix) from the covariance -- no truth.
    %   3. With N_WL fixed, form the wide-lane carrier range: an UNAMBIGUOUS observable at
    %      carrier precision, ~500x better than code, which is what conditions the geometry.
    %   4. With the geometry conditioned, estimate the L1 float ambiguity. N2 is then determined
    %      by N1 - N_WL, so the search is one-dimensional per link instead of two. Fix N1.
    %   5. Report everything, including the fixes that were REFUSED and why.
    %
    % F5 -- WHAT IS REPORTED IS P(FALSE FIX), NOT A FIX RATE. The success rate here is computed
    % from the ambiguity covariance by integer bootstrapping, which is exact and is a rigorous
    % lower bound for integer least squares. It is quotable for a fix that has no ground truth
    % behind it, which a counted fix rate is not. Where truth IS available (this being a
    % simulation) the realised correctness is ALSO reported, as a check on the predicted rate --
    % clearly separated, and never used to make a decision.
    %
    %   out = revgnss.GroundCarrierAmbiguityResolver.resolve(cfg, results, rel)

    properties (Constant, Access = private)
        MIN_TOWERS = 2;
    end

    methods (Static)

        function out = resolve(cfg, results, rel)
            R = revgnss.GroundCarrierAmbiguityResolver;
            out = R.emptyOut_();
            if ~R.getBool_(cfg, {'multiAsset','groundCarrier','enable'}, false)
                out.reason = 'gateOff'; return
            end
            if ~isstruct(rel) || ~isfield(rel,'solvedPos') || isempty(rel.solvedPos)
                out.reason = 'noSolvedPos'; return
            end
            N = size(rel.solvedPos,2); nEp = size(rel.solvedPos,3);
            tVec = rel.time_s(:).';
            if numel(tVec) ~= nEp; out.reason = 'timeGridMismatch'; return; end

            obs = revgnss.GroundDifferencedRotationSolver.buildObservable(cfg, results, tVec, N);
            if ~obs.ok; out.reason = obs.reason; return; end
            car = revgnss.GroundCarrierObservationSet.build(cfg, obs, tVec);
            if ~car.ok; out.reason = car.reason; return; end
            out.nSlips = car.nSlips;
            out.slipRatePerLinkPerHour = car.slipRatePerLinkPerHour;
            out.codeDdSigma_m = 2*obs.codeSigma_m;

            % --- the double-difference index set ---------------------------------------------
            % One ambiguity per (satellite i>=2, tower m /= ref, ARC). The arc dimension is what
            % makes a held fix distinguishable from a re-acquired one (F7).
            [idx, refTw] = R.ddIndex_(car, N, nEp);
            if isempty(idx.rows); out.reason = 'noDoubleDifferences'; return; end
            out.nAmbiguities = idx.n;
            out.nEpochsUsed  = idx.nEpochsUsed;

            % --- step 1+2: wide lane from Melbourne-Wubbena ------------------------------------
            [wlHat, Qwl, mwSigma] = R.wideLaneFloat_(car, idx, refTw, N);
            out.wideLaneFloatSigma_cyc = sqrt(mean(diag(Qwl)));
            out.mwSigmaPerEpoch_m = mwSigma;
            opts = R.resolverOpts_(cfg);
            [wlFix, wlInfo] = R.fixIntegers_(cfg, wlHat, Qwl, opts);
            out.wideLane = R.packInfo_(wlInfo);
            out.wideLane.floatSigma_cyc = out.wideLaneFloatSigma_cyc;

            % Realised correctness, for the predicted-vs-measured register ONLY. It plays no
            % part in any decision above and is computed after the fact.
            wlTrue = R.trueLaneIntegers_(car, idx, refTw, 'wide');
            out.wideLane.realisedCorrect = R.scoreFix_(wlFix, wlTrue, wlInfo.accepted);
            out.wideLane.nCorrectComponents = sum(round(wlFix(:)) == wlTrue(:));

            if ~wlInfo.accepted
                out.applicable = true; out.reason = 'wideLaneNotFixed';
                out.stage = 'wideLane';
                return
            end

            % --- step 3: the unambiguous wide-lane range ---------------------------------------
            % lam_WL*N_WL removed, the wide-lane carrier DD is a range with carrier-class noise.
            % Published as a PER-LINK pseudo-range whose double difference is exactly the fixed
            % one, so revgnss.JointGeometrySolver can consume it with no change to its row
            % construction: the per-link integer assignment is arbitrary (zero on the reference
            % satellite and the reference tower) precisely because only differences are used.
            [rhoWl, ddWlSigma] = R.laneRange_(car, idx, refTw, wlFix, N, nEp, 'wide');
            out.wideLaneRangeSigma_m = ddWlSigma;
            out.wideLaneObservable = struct('rhoObs', rhoWl, ...
                'rawSigma_m', ddWlSigma/2, 'name', 'fixedCarrier:wideLane');
            out.stage = 'wideLaneFixed';

            % --- step 3b: condition the geometry on the fixed wide lane (F6) --------------------
            % THIS IS THE STEP THAT CONVERTS A FIX INTO PRECISION. Until now the wide lane has
            % only told us an integer; feeding the de-ambiguated range back through the joint
            % shape+rotation solve is what turns it into geometry, and the sharpened geometry is
            % what makes the L1 search below feasible at all. The solve keeps its own acceptance
            % test, so a wide lane that cannot improve the geometry declines to.
            relCond = rel;
            cfgJ = cfg; cfgJ.multiAsset.jointGeometry.enable = true;
            jntWl = revgnss.JointGeometrySolver.solve(cfgJ, results, rel, out.wideLaneObservable);
            out.wideLaneGeometry = R.packJoint_(jntWl);
            if jntWl.applicable && jntWl.acceptedShape && ~isempty(jntWl.solvedPos)
                relCond.solvedPos = jntWl.solvedPos;
                relCond.shapeSigmaPosterior_m = jntWl.shapeSigmaPosterior_m;
                out.geometryConditioned = true;
                out.shapeSigmaPosterior_m = jntWl.shapeSigmaPosterior_m;
            end
            out.conditionedGeometry = relCond.solvedPos;

            % --- step 4: L1, with N2 determined by N1 - N_WL -------------------------------------
            if R.getBool_(cfg, {'multiAsset','groundCarrier','cascadeToL1'}, true)
                [l1Hat, Ql1] = R.l1Float_(car, idx, refTw, relCond, obs, N);
                out.l1FloatSigma_cyc = sqrt(mean(diag(Ql1)));
                [l1Fix, l1Info] = R.fixIntegers_(cfg, l1Hat, Ql1, opts);
                out.l1 = R.packInfo_(l1Info);
                out.l1.floatSigma_cyc = out.l1FloatSigma_cyc;
                l1True = R.trueLaneIntegers_(car, idx, refTw, 'L1');
                out.l1.realisedCorrect = R.scoreFix_(l1Fix, l1True, l1Info.accepted);
                out.l1.nCorrectComponents = sum(round(l1Fix(:)) == l1True(:));
                if l1Info.accepted
                    out.stage = 'l1Fixed';
                    out.n1Fix = l1Fix; out.n2Fix = l1Fix - wlFix;
                    [rhoL1, ddL1Sigma] = R.laneRange_(car, idx, refTw, l1Fix, N, nEp, 'L1');
                    out.l1RangeSigma_m = ddL1Sigma;
                    out.l1Observable = struct('rhoObs', rhoL1, ...
                        'rawSigma_m', ddL1Sigma/2, 'name', 'fixedCarrier:L1');
                end
            end

            out.applicable = true; out.reason = 'ok';
            out.wlFix = wlFix; out.ddIndex = idx; out.refTower = refTw;
        end

        function print(out)
            if ~isstruct(out) || ~isfield(out,'applicable') || ~out.applicable
                r = 'unavailable';
                if isstruct(out) && isfield(out,'reason'); r = out.reason; end
                if ~strcmp(r,'gateOff')
                    fprintf('  Ground carrier ambiguity resolver: %s\n', r);
                end
                return
            end
            fprintf('  ---- ground carrier ambiguity resolution (no truth in any decision) ----\n');
            fprintf('  %d DD ambiguities over %d epochs, %d cycle slips at %.3g /link/h\n', ...
                out.nAmbiguities, out.nEpochsUsed, out.nSlips, out.slipRatePerLinkPerHour);
            revgnss.GroundCarrierAmbiguityResolver.printStage_('wide-lane (Melbourne-Wubbena)', out.wideLane);
            if isfield(out,'wideLaneRangeSigma_m') && isfinite(out.wideLaneRangeSigma_m)
                fprintf('    -> unambiguous wide-lane range, DD sigma %.4f m (the code DD it replaces: %.3f m, %.0fx)\n', ...
                    out.wideLaneRangeSigma_m, out.codeDdSigma_m, ...
                    out.codeDdSigma_m/max(out.wideLaneRangeSigma_m, realmin));
            end
            if isfinite(out.shapeSigmaPosterior_m)
                fprintf('    -> geometry conditioned on the fixed wide lane: shape sigma %.4f m (%s)\n', ...
                    out.shapeSigmaPosterior_m, out.wideLaneGeometry.acceptReason);
            end
            if isfield(out,'l1') && ~isempty(out.l1) && isstruct(out.l1)
                revgnss.GroundCarrierAmbiguityResolver.printStage_('L1 (N2 = N1 - N_WL)', out.l1);
            end
            fprintf('    final stage reached: %s\n', out.stage);
        end
    end

    methods (Static, Access = private)

        function printStage_(label, s)
            if ~isstruct(s) || ~isfield(s,'decision'); return; end
            fprintf('    %-28s %s\n', label, s.decision);
            fprintf('      float sigma %.4f cyc | P(success) %.6f | P(false fix) %.3e | ratio %.2f\n', ...
                s.floatSigma_cyc, s.successRate, s.failureRate, s.ratio);
            if isfinite(s.realisedCorrect)
                fprintf('      REGISTER (not a decision input): realised %s, %d/%d components correct\n', ...
                    ternary_(s.realisedCorrect == 1, 'CORRECT', 'WRONG'), ...
                    s.nCorrectComponents, s.n);
            end
            if ~isempty(s.message); fprintf('      %s\n', s.message); end
        end

        function [idx, refTw] = ddIndex_(car, N, nEp)
            % ddIndex_  Which double differences exist, and which ambiguity each belongs to.
            %
            % The ambiguity KEY is (satellite, tower, arc of the satellite link, arc of the
            % reference-satellite link on the same tower, arc on the reference tower ...). A DD
            % combines four links, so a slip on ANY of them starts a new DD ambiguity. Rather
            % than track that combinatorially, the key is the tuple of the four arc indices --
            % which is exact, and which collapses to one ambiguity per (sat, tower) when no slip
            % occurs.
            refTw = 0;
            for m = 1:size(car.visTw,1)
                if any(car.visTw(m,:)); refTw = m; break; end
            end
            idx = struct('rows', [], 'n', 0, 'nEpochsUsed', 0, 'key', {{}}, ...
                'sat', [], 'tower', [], 'epoch', [], 'amb', []);
            if refTw == 0; return; end
            keys = containers.Map('KeyType','char','ValueType','double');
            nTw = size(car.visTw,1);
            cap = nEp*max(1,(nTw-1))*max(1,(N-1));
            sat = zeros(1,cap); tow = zeros(1,cap); ep = zeros(1,cap); amb = zeros(1,cap);
            nRow = 0; nUsed = 0;
            for k = 1:nEp
                okTw = find(car.visTw(:,k)).';
                if numel(okTw) < 2 || ~ismember(refTw, okTw); continue; end
                nUsed = nUsed + 1;
                for m = okTw
                    if m == refTw; continue; end
                    for i = 2:N
                        key = sprintf('%d_%d_%d_%d_%d_%d', i, m, ...
                            car.arcId(i,m,k), car.arcId(1,m,k), ...
                            car.arcId(i,refTw,k), car.arcId(1,refTw,k));
                        if isKey(keys, key); a = keys(key);
                        else; a = keys.Count + 1; keys(key) = a; end
                        nRow = nRow + 1;
                        sat(nRow) = i; tow(nRow) = m; ep(nRow) = k; amb(nRow) = a;
                    end
                end
            end
            idx.sat = sat(1:nRow); idx.tower = tow(1:nRow);
            idx.epoch = ep(1:nRow); idx.amb = amb(1:nRow);
            idx.rows = 1:nRow;
            idx.n = keys.Count;
            idx.nEpochsUsed = nUsed;
        end

        function [wlHat, Q, mwSigma] = wideLaneFloat_(car, idx, refTw, N)
            % wideLaneFloat_  Arc-averaged Melbourne-Wubbena double difference, in wide-lane
            % cycles, with the covariance that the shared reference satellite and tower imply.
            %
            % MW is GEOMETRY-FREE and IONOSPHERE-FREE, so nothing about the orbit, the shape or
            % the rotation enters. Its noise is code-dominated -- roughly
            % sqrt((f1*s1)^2+(f2*s2)^2)/(f1+f2) per link per epoch -- and it averages down as
            % 1/sqrt(nEpochs) because the code noise here is white.
            f1 = car.f1_Hz; f2 = car.f2_Hz;
            lamWL = car.lambdaWL_m;
            L = car.phase_m; P = car.code_m;
            mw = @(i,m,k) (f1*L(1,i,m,k) - f2*L(2,i,m,k))/(f1-f2) ...
                        - (f1*P(1,i,m,k) + f2*P(2,i,m,k))/(f1+f2);

            n = idx.n;
            acc = zeros(n,1); cnt = zeros(n,1);
            for r = idx.rows
                i = idx.sat(r); m = idx.tower(r); k = idx.epoch(r); a = idx.amb(r);
                v = (mw(i,m,k) - mw(1,m,k)) - (mw(i,refTw,k) - mw(1,refTw,k));
                acc(a) = acc(a) + v/lamWL; cnt(a) = cnt(a) + 1;
            end
            wlHat = acc ./ max(cnt,1);

            % Per-epoch MW sigma, in metres, propagated from the code and phase sigmas. A DD
            % combines four links; each MW combines two phases and two codes.
            s1 = car.codeSigma_m(1); s2 = car.codeSigma_m(2); sp = car.phaseSigma_m;
            varMwLink = (f1^2*sp^2 + f2^2*sp^2)/(f1-f2)^2 + (f1^2*s1^2 + f2^2*s2^2)/(f1+f2)^2;
            mwSigma = sqrt(4*varMwLink);                 % one DD, one epoch, metres

            % Covariance of the arc means, in cycles. The DDs at one epoch share the reference
            % satellite (link 1,m and 1,ref) and the reference tower, so they are correlated:
            % var = 4*v, cov = v or 2*v depending on how many links two DDs share. Built from
            % the structure rather than assumed diagonal -- a diagonal assumption here would
            % understate the ambiguity covariance and overstate the success rate, which is the
            % failure direction that matters.
            Q = revgnss.GroundCarrierAmbiguityResolver.ddCovariance_( ...
                idx, varMwLink/lamWL^2, cnt, N, size(car.visTw,1), refTw);
        end

        function Q = ddCovariance_(idx, varLinkCyc, cnt, N, nTw, refTw)
            % ddCovariance_  Covariance of the per-ambiguity ARC MEANS.
            %
            % DD(i,m,k) = x(i,m,k) - x(1,m,k) - x(i,ref,k) + x(1,ref,k) over links x that are
            % independent ACROSS links and ACROSS epochs. Two DDs formed at the same epoch share
            % up to three of their four links -- every one of them contains +x(1,ref,k) -- so the
            % ambiguity covariance is emphatically NOT diagonal. Assuming it were would
            % understate it and therefore OVERSTATE the success rate, which is the one direction
            % of error that matters here.
            %
            % Built as a signed incidence matrix over (link, epoch) and squared, rather than by
            % counting shared links pairwise: same answer, and it stays linear in the number of
            % rows instead of quadratic, which matters on a 21601-epoch arc.
            n = idx.n; nRow = numel(idx.rows);
            nLink = N*nTw;
            lin = @(i,m,k) (k-1)*nLink + (m-1)*N + i;
            r = repmat(idx.amb(:), 4, 1);
            c = [ lin(idx.sat(:), idx.tower(:), idx.epoch(:)) ; ...
                  lin(ones(nRow,1), idx.tower(:), idx.epoch(:)) ; ...
                  lin(idx.sat(:), refTw*ones(nRow,1), idx.epoch(:)) ; ...
                  lin(ones(nRow,1), refTw*ones(nRow,1), idx.epoch(:)) ];
            v = [ ones(nRow,1) ; -ones(nRow,1) ; -ones(nRow,1) ; ones(nRow,1) ];
            S = sparse(r, c, v, n, nLink*max(idx.epoch));    % per-ambiguity SUM over its epochs
            Q = full(S*S.') * varLinkCyc;

            % Arc means: divide by n_p * n_q.
            cc = max(cnt(:),1);
            Q = Q ./ (cc*cc.');
            Q = (Q+Q.')/2;
            % A tiny ridge keeps the factorisation well posed when an arc has a single epoch.
            Q = Q + 1e-12*mean(diag(Q))*eye(n);
        end

        function [rho, ddSigma] = laneRange_(car, idx, refTw, nFix, N, nEp, band) %#ok<INUSD>
            % laneRange_  The lane carrier as a PER-LINK pseudo-range with its integer removed.
            %
            % The integers are only known as DOUBLE DIFFERENCES, so no per-link integer exists.
            % None is needed: assign zero on the reference satellite and on the reference tower
            % and put the whole fixed DD on the (i, m) link. The double difference of the result
            % is then EXACTLY the de-ambiguated one, and every consumer that forms double
            % differences -- which is all of them -- sees the right thing. Anything that read a
            % single link would be reading a gauge choice, which is why nothing does.
            f1 = car.f1_Hz; f2 = car.f2_Hz;
            L = car.phase_m;
            if strcmpi(band,'wide')
                lam = car.lambdaWL_m;
                lane = (f1*squeeze(L(1,:,:,:)) - f2*squeeze(L(2,:,:,:)))/(f1-f2);
                amp = sqrt(f1^2+f2^2)/(f1-f2);
            else
                lam = car.lambda1_m;
                lane = squeeze(L(1,:,:,:));
                amp = 1.0;
            end
            nTw = size(car.visTw,1);
            rho = nan(N, nTw, nEp);
            rho(:,:,:) = lane;
            for r = idx.rows
                i = idx.sat(r); m = idx.tower(r); k = idx.epoch(r); a = idx.amb(r);
                rho(i,m,k) = lane(i,m,k) - lam*nFix(a);
            end
            sp = car.phaseSigma_m;
            ddSigma = 2 * amp * sp;         % a DD combines four links
        end

        function s = packJoint_(j)
            s = struct('applicable', false, 'accepted', false, 'acceptedShape', false, ...
                'acceptedRotation', false, 'reason', 'notAttempted', ...
                'acceptReason', '', 'theta_deg', NaN, 'sigma_deg', NaN, ...
                'shapeStep_m', NaN, 'observableShapeDof', NaN, 'shapeDofTotal', NaN, ...
                'separationPenaltyFree', NaN, 'turnAngle_deg', NaN, 'observable', '');
            if ~isstruct(j); return; end
            s.applicable = j.applicable; s.accepted = j.accepted;
            s.acceptedShape = j.acceptedShape; s.acceptedRotation = j.acceptedRotation;
            s.reason = j.reason; s.acceptReason = j.acceptReason;
            s.theta_deg = norm(j.theta_rad)*180/pi;
            s.sigma_deg = norm(j.thetaSigma_rad)*180/pi;
            s.shapeStep_m = j.shapeStep_m;
            s.observableShapeDof = j.observableShapeDof;
            s.shapeDofTotal = j.shapeDofTotal;
            s.separationPenaltyFree = j.separationPenaltyFree;
            s.turnAngle_deg = j.turnAngle_deg;
            s.observable = j.observable;
        end

        function [l1Hat, Q] = l1Float_(car, idx, refTw, rel, obs, N)
            % l1Float_  L1 double-difference float ambiguity against the CONDITIONED geometry.
            %
            % The geometry used here is the one the caller supplies -- after the wide-lane range
            % has been allowed to sharpen it (F6). The wide-lane fix additionally pins
            % N1 - N2 = N_WL, so N2 is determined and only N1 is searched: the dimension halves
            % and the search is one per link rather than two.
            f1 = car.f1_Hz; lam1 = car.lambda1_m;                              %#ok<NASGU>
            L = car.phase_m;
            n = idx.n;
            acc = zeros(n,1); cnt = zeros(n,1);
            for r = idx.rows
                i = idx.sat(r); m = idx.tower(r); k = idx.epoch(r); a = idx.amb(r);
                Pk = rel.solvedPos(:,:,k);
                if any(~isfinite(Pk(:))); continue; end
                A = revgnss.GroundDifferencedRotationSolver.predictedAntenna(obs, Pk, k);
                rp = @(ii,mm) norm(A(:,ii) - obs.towerPos(:,mm));
                ddPred = (rp(i,m)-rp(1,m)) - (rp(i,refTw)-rp(1,refTw));
                ddObs  = (L(1,i,m,k)-L(1,1,m,k)) - (L(1,i,refTw,k)-L(1,1,refTw,k));
                acc(a) = acc(a) + (ddObs - ddPred)/car.lambda1_m;
                cnt(a) = cnt(a) + 1;
            end
            l1Hat = acc ./ max(cnt,1);

            % The float sigma here is dominated NOT by phase noise but by the residual GEOMETRY
            % error, which is arc-correlated and therefore does not average away. Charging it as
            % white noise would understate the covariance and overstate the success rate, so it
            % is charged at its full per-epoch size with an effective sample count of one.
            geomSigma = revgnss.GroundCarrierAmbiguityResolver.geometryDdSigma_(rel);
            varCyc = (geomSigma/car.lambda1_m)^2;
            varPhaseCyc = 4*(car.phaseSigma_m/car.lambda1_m)^2;
            Q = revgnss.GroundCarrierAmbiguityResolver.ddCovariance_( ...
                idx, varPhaseCyc/4, max(cnt,1), N, size(car.visTw,1), refTw);
            Q = Q + varCyc*ones(n);          % fully correlated geometry term
            Q = Q + 1e-9*mean(diag(Q))*eye(n);
            Q = (Q+Q.')/2;
        end

        function s = geometryDdSigma_(rel)
            % geometryDdSigma_  How large a DD error the current geometry implies, WITHOUT truth,
            % de-magnified by the tower geometry (|u_m - u_l| <= 0.23 from GEO, which costs
            % signal but shrinks the geometry error by the same factor -- the property that makes
            % fixing possible at all).
            %
            % Prefers the POSTERIOR sigma the wide-lane-conditioned solve published over the ISL
            % layer's prior one. Using the prior here would charge L1 for a geometry error the
            % wide lane has already removed, so the cascade could never demonstrate its own
            % benefit -- conservative, but conservative in a way that hides the result.
            s = 0.15; f = NaN;
            if isstruct(rel) && isfield(rel,'shapeSigmaPosterior_m') && ...
                    isfinite(rel.shapeSigmaPosterior_m) && rel.shapeSigmaPosterior_m > 0
                f = rel.shapeSigmaPosterior_m / sqrt(3);   % per-point norm -> per axis
            elseif isstruct(rel) && isfield(rel,'formalShapeSigma_m')
                f = rel.formalShapeSigma_m;
            end
            if isfinite(f) && f > 0
                s = 0.23 * sqrt(3) * f * 2;    % per-axis -> norm, and a DD spans two baselines
            end
        end

        function [aFix, info] = fixIntegers_(cfg, aHat, Q, opts)
            % fixIntegers_  LAMBDA when the toolbox is installed, the native decorrelated
            % bootstrap otherwise. Both refuse below the success-rate floor and both report the
            % reason; the choice is recorded so a result can never be read as ILS when it was
            % bootstrapping.
            if revgnss.integer.LambdaResolver.isAvailable(cfg)
                [aFix, li] = revgnss.integer.LambdaResolver.resolve(aHat, Q, cfg);
                info = li; info.engine = 'LAMBDA';
                if ~isfield(info,'estimator'); info.estimator = 'ils'; end
                return
            end
            [aFix, info] = revgnss.integer.DecorrelatedBootstrap.resolve(aHat, Q, opts);
            info.engine = 'DecorrelatedBootstrap';
        end

        function o = resolverOpts_(cfg)
            R = revgnss.GroundCarrierAmbiguityResolver;
            o = struct( ...
                'minSuccessRate', R.getNum_(cfg, ...
                    {'multiAsset','groundCarrier','minSuccessRate'}, 0.999), ...
                'ratioThreshold', R.getNum_(cfg, ...
                    {'multiAsset','groundCarrier','ratioThreshold'}, 2.0), ...
                'nodeBudget', R.getNum_(cfg, ...
                    {'multiAsset','groundCarrier','nodeBudget'}, 200000));
        end

        function t = trueLaneIntegers_(car, idx, refTw, band)
            % trueLaneIntegers_  SCORING ONLY. Called after every decision has been made, so
            % that the predicted success rate can be checked against a realised outcome. It must
            % never appear upstream of a fix.
            t = zeros(idx.n,1);
            for r = idx.rows
                i = idx.sat(r); m = idx.tower(r); k = idx.epoch(r); a = idx.amb(r);
                if t(a) ~= 0; continue; end
                g = @(ii,mm,bb) car.Ntrue(bb, ii, mm, car.arcId(ii,mm,k));
                switch lower(band)
                    case 'wide'
                        f = @(ii,mm) g(ii,mm,1) - g(ii,mm,2);
                    otherwise
                        f = @(ii,mm) g(ii,mm,1);
                end
                t(a) = (f(i,m) - f(1,m)) - (f(i,refTw) - f(1,refTw));
            end
        end

        function v = scoreFix_(aFix, aTrue, accepted)
            v = NaN;
            if ~accepted; return; end
            v = double(isequal(round(aFix(:)), aTrue(:)));
        end

        function s = packInfo_(info)
            s = struct('decision', info.decision, 'accepted', info.accepted, ...
                'message', info.message, 'n', info.n, 'nFixed', info.nFixed, ...
                'successRate', info.successRate, 'failureRate', info.failureRate, ...
                'ratio', info.ratio, 'engine', '', 'estimator', '', ...
                'floatSigma_cyc', NaN, 'realisedCorrect', NaN, 'nCorrectComponents', NaN);
            if isfield(info,'engine');    s.engine    = info.engine; end
            if isfield(info,'estimator'); s.estimator = info.estimator; end
        end

        function o = emptyOut_()
            o = struct('applicable', false, 'reason', 'notAttempted', 'stage', 'none', ...
                'nAmbiguities', 0, 'nEpochsUsed', 0, 'nSlips', 0, ...
                'slipRatePerLinkPerHour', NaN, 'wideLane', struct(), 'l1', struct(), ...
                'wideLaneFloatSigma_cyc', NaN, 'l1FloatSigma_cyc', NaN, ...
                'mwSigmaPerEpoch_m', NaN, 'wideLaneRangeSigma_m', NaN, ...
                'l1RangeSigma_m', NaN, 'wideLaneObservable', struct(), ...
                'l1Observable', struct(), 'wideLaneGeometry', struct(), ...
                'geometryConditioned', false, 'conditionedGeometry', [], ...
                'shapeSigmaPosterior_m', NaN, 'codeDdSigma_m', NaN, ...
                'wlFix', [], 'n1Fix', [], 'n2Fix', [], ...
                'ddIndex', struct(), 'refTower', 0);
        end

        function v = getBool_(cfg, path, dflt)
            v = logical(revgnss.GroundCarrierAmbiguityResolver.getNum_(cfg, path, dflt));
        end

        function v = getNum_(cfg, path, dflt)
            v = dflt; c = cfg;
            for i = 1:numel(path)
                if ~isstruct(c) || ~isfield(c, path{i}); return; end
                c = c.(path{i});
            end
            if ~isempty(c) && (isnumeric(c) || islogical(c)); v = c; end
        end
    end
end

function v = ternary_(c, a, b)
if c; v = a; else; v = b; end
end
