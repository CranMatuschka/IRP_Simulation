classdef SwarmRelativeSolver
    % SwarmRelativeSolver  Diagnostic per-epoch free-network shape adjustment.
    %
    % Recovers the formation SHAPE from two-way inter-satellite ranging over a bounded-degree
    % (<=5 nearest-range, decision D2) neighbour graph, run PURELY as a read-only post-processor of
    % the federated per-asset marginals (revgnss.ReportRunner.runFederatedEstimation output). It is the second
    % layer of the federated architecture (docs/federated_swarm_architecture.md).
    %
    % HONESTY / SAFETY (the reason for the pivot away from the joint EKF):
    %   * D1 -- NO shared covariance, NO write path to any per-asset x/P. The solver reads
    %     results.asset{i}.{history,truthTraj,stateMap} and returns a NEW struct; it can therefore
    %     not re-open the per-asset filters nor create the shared-P coupling that diverged the joint
    %     filter 11 m -> 2 km. It builds its own information matrix over a fresh delta and discards it.
    %   * RIGID-MOTION-BLIND -- two-way ISL observes |r_i - r_k| only (rows +u'/-u'). The formation
    %     SHAPE is observable; the absolute translation + rotation of the whole formation are NOT.
    %     The solve uses a minimal-constraint (min-norm / inner) gauge, and EVERY reported metric is
    %     gauge-invariant (baseline lengths + best-fit-rigid shape residual), so the gauge is a
    %     numerical well-posedness device, not an absolute-state prior.
    %   * NO absolute claim -- absolute stays per-asset (wall-limited). This layer reports SHAPE only.
    %   * NO double-count -- ground pseudoranges and ISL use disjoint measurements; the ground
    %     covariance P_i is deliberately NOT injected as a shape prior.
    %
    % Satellite time-transfer relative clocks are a separate gated default-off diagnostic; this file
    % ships the SHAPE core (two-way ISL) only.
    %
    %   out = revgnss.SwarmRelativeSolver.solve(cfg, results)
    %       out.applicable          false when N<2 (nothing to relate) -> all metrics NaN
    %       out.nAssets, out.pairs  neighbour graph (canonical i<k pairs)
    %       out.baselineErrRaw_m    tail-avg baseline RMS of the raw per-asset estimates
    %       out.baselineErrSolved_m tail-avg per-pair baseline-length RMS AFTER the ISL shape solve
    %       out.shapeErrRaw_m       tail-avg best-fit-rigid shape RMS, raw per-asset estimates
    %       out.shapeErrSolved_m    tail-avg best-fit-rigid shape RMS after the solve
    %       out.formalShapeSigma_m  tail-avg formal 1-sigma of the solved shape (min-norm cov) -- G8
    %       out.weaklyObservable    true if the geometry leaves a shape DOF weakly observable (G10)
    %       out.perEpoch            per-epoch series (time, baseline/shape err raw+solved)

    properties (Constant, Access = private)
        MAX_DEGREE = 5;      % D2: each asset links to at most 5 nearest-range neighbours
        GN_ITERS   = 3;      % Gauss-Newton iterations (baseline norm is mildly nonlinear)
        TAIL_FRAC  = 0.20;   % report the last 20% of epochs (matches SwarmEstimateSummary)
        RANK_TOL   = 1e-6;   % relative singular-value tolerance for rank / weak-observability
    end

    methods (Static)
        function out = solve(cfg, results)
            out = revgnss.SwarmRelativeSolver.emptyOut_();
            shapeGateOn = revgnss.SwarmRelativeSolver.getBool_(cfg, {'multiAsset','twoWayISL','enable'}, false);
            clockGateOn = revgnss.SwarmRelativeSolver.getBool_(cfg, {'multiAsset','twoWayTimeTransferISL','enable'}, false);
            out.shapeGateOn = shapeGateOn;
            out.shapeObservationSource = 'disabled';
            N = 0;
            if isstruct(results) && isfield(results,'N'); N = results.N; end
            out.nAssets = N;
            if N < 2
                return;   % applicable=false, all metrics NaN: nothing to relate for a lone asset
            end

            % --- Gather per-asset per-epoch estimated + truth position trajectories -------------
            [Est, Truth, tVec, ok] = revgnss.SwarmRelativeSolver.gatherTrajectories_(results, N);
            if ~ok; return; end
            nEp = numel(tVec);
            out.applicable = true;

            % --- Neighbour graph: <=5 nearest-range from the MEAN estimated geometry (D2) -------
            meanPos = zeros(3, N);
            for i = 1:N; meanPos(:,i) = mean(Est{i}, 2); end
            pairs = revgnss.SwarmRelativeSolver.neighbourGraph_(meanPos, revgnss.SwarmRelativeSolver.MAX_DEGREE);
            out.pairs = pairs;
            nP = size(pairs,1);
            if nP < 1; return; end

            if ~shapeGateOn
                [blRaw, shRaw] = revgnss.SwarmRelativeSolver.rawGeometrySeries_(Est, Truth, pairs, nEp, N);
                tsel = revgnss.SwarmRelativeSolver.tailIdx_(nEp);
                out.baselineErrRaw_m = sqrt(mean(blRaw(tsel).^2));
                out.shapeErrRaw_m = sqrt(mean(shRaw(tsel).^2));
                out.perEpoch = struct('time_s', tVec(:).', ...
                    'baselineErrRaw_m', blRaw, 'baselineErrSolved_m', nan(1,nEp), ...
                    'shapeErrRaw_m', shRaw, 'shapeErrSolved_m', nan(1,nEp));
                out.time_s = tVec(:).';
                if clockGateOn
                    out = revgnss.SwarmRelativeSolver.solveRelativeClocks_(cfg, results, N, pairs, tVec, out);
                end
                return
            end
            out.shapeObservationSource = 'syntheticTwoWayISL';

            % --- Per-pair ISL noise: constant delay-cal bias (identity-keyed) + conservative R ---
            % meanPos supplies the per-pair BASELINE LENGTH so the thermal sigma can be
            % derived from a link budget (sigma ~ distance) instead of one typed constant.
            [pairBias, pairR, pairSigma] = revgnss.SwarmRelativeSolver.islNoise_(cfg, pairs, meanPos);
            out.linkBudget = revgnss.ISLLinkBudget.describe(cfg, {'multiAsset','twoWayISL'}, 0.01);
            out.pairSigma_m = pairSigma(:)';
            % Per-(pair,epoch) thermal, drawn once per pair from an identity-keyed stream.
            % Sigma is now PER PAIR (a 5 km link is noisier than a 1 km link); with the
            % link budget disabled every pairSigma equals the legacy scalar -> unchanged.
            thermal = zeros(nP, nEp);
            for p = 1:nP
                node = pairs(p,1)*64 + pairs(p,2);
                rs = RandStream('mt19937ar', 'Seed', revgnss.SwarmRelativeSolver.baseSeed_(cfg) + 7000 + node);
                thermal(p,:) = pairSigma(p) * randn(rs, 1, nEp);
            end
            % --- Light-time-aware two-way geometry (gated, default off) -----------------
            % The synthetic observable used |r_i - r_k| (instantaneous). The physical
            % two-way range differs by the motion during the round trip. Velocities are
            % finite-differenced from the truth trajectories (none are stored).
            ltOn = revgnss.SwarmRelativeSolver.getBool_(cfg, {'multiAsset','twoWayISL','lightTime','enable'}, false);
            out.lightTimeOn = ltOn;
            out.lightTimeMax_m = 0;

            % --- Per-epoch free-network shape solve ---------------------------------------------
            blRaw = nan(1,nEp); blSol = nan(1,nEp);
            shRaw = nan(1,nEp); shSol = nan(1,nEp);
            fSig  = nan(1,nEp); weakEp = false(1,nEp);
            solvedPos = nan(3,N,nEp); % Native estimated frame; no truth-based alignment.
            Winv  = 1 ./ pairR(:);                    % per-pair weight = 1/R
            for kk = 1:nEp
                estK = zeros(3,N); truthK = zeros(3,N);
                for i = 1:N; estK(:,i) = Est{i}(:,kk); truthK(:,i) = Truth{i}(:,kk); end

                % Synthesized two-way-ISL observables for this epoch (both endpoints truth).
                zK = zeros(nP,1);
                for p = 1:nP
                    i = pairs(p,1); k = pairs(p,2);
                    rho = norm(truthK(:,i) - truthK(:,k));
                    if ltOn
                        lt = revgnss.SwarmRelativeSolver.twoWayLightTime_( ...
                            Truth, i, k, kk, tVec, rho);
                        out.lightTimeMax_m = max(out.lightTimeMax_m, abs(lt));
                        rho = rho + lt;
                    end
                    zK(p) = rho + pairBias(p) + thermal(p,kk);
                end

                [rHat, Pshape, weak] = revgnss.SwarmRelativeSolver.solveEpoch_(estK, zK, pairs, Winv, N);
                weakEp(kk) = weak;

                blRaw(kk) = revgnss.SwarmRelativeSolver.baselineRms_(estK,  truthK, pairs);
                blSol(kk) = revgnss.SwarmRelativeSolver.baselineRms_(rHat,  truthK, pairs);
                shRaw(kk) = revgnss.SwarmRelativeSolver.shapeRms_(estK,  truthK);
                shSol(kk) = revgnss.SwarmRelativeSolver.shapeRms_(rHat,  truthK);
                fSig(kk)  = sqrt(mean(Pshape));       % formal 1-sigma of the solved positions
                % rHat retains the estimated rigid frame; no truth-based frame alignment is
                % applied. The synthetic range observations above are generated from
                % truth trajectories, so this remains a diagnostic post-processor.
                solvedPos(:,:,kk) = rHat;
            end

            % --- Tail-average reporting ---------------------------------------------------------
            tsel = revgnss.SwarmRelativeSolver.tailIdx_(nEp);
            out.baselineErrRaw_m    = sqrt(mean(blRaw(tsel).^2));
            out.baselineErrSolved_m = sqrt(mean(blSol(tsel).^2));
            out.shapeErrRaw_m       = sqrt(mean(shRaw(tsel).^2));
            out.shapeErrSolved_m    = sqrt(mean(shSol(tsel).^2));
            out.formalShapeSigma_m  = mean(fSig(tsel));
            % Tail-consistent with the reported metrics: flag weak only if the REPORTED (tail) window
            % has a weakly-observed DOF. An isolated early near-degeneracy (e.g. t=0, where sin(phase)=0
            % zeroes the cross-track of a helix member) does not degrade the tail-averaged solution.
            out.weaklyObservable    = any(weakEp(tsel));
            out.everWeaklyObservable = any(weakEp);   % diagnostic: geometry passed through a degeneracy
            out.perEpoch = struct('time_s', tVec(:).', ...
                'baselineErrRaw_m', blRaw, 'baselineErrSolved_m', blSol, ...
                'shapeErrRaw_m', shRaw, 'shapeErrSolved_m', shSol);
            out.solvedPos = solvedPos; % [3 x N x nEp], native estimated frame.
            out.time_s = tVec(:).';

            % Gated satellite time-transfer relative-clock solve.
            % The clock DUAL of the shape solve. Two-way sat<->sat time transfer observes the clock
            % DIFFERENCE b_i-b_k directly (rows +1/-1), so a free-network min-norm solve over the same
            % neighbour graph sharpens the swarm's RELATIVE clocks to the TWSTFT floor. Default OFF
            % (needs the sat<->sat transmit premise, beyond plain reverse-GNSS uplink); when OFF the
            % clock fields stay NaN and the shape output above is unchanged.
            if clockGateOn
                out = revgnss.SwarmRelativeSolver.solveRelativeClocks_(cfg, results, N, pairs, tVec, out);
            end
        end
    end

    methods (Static, Access = private)

        function out = emptyOut_()
            out = struct('applicable', false, 'nAssets', 0, 'pairs', zeros(0,2), ...
                'baselineErrRaw_m', NaN, 'baselineErrSolved_m', NaN, ...
                'shapeErrRaw_m', NaN, 'shapeErrSolved_m', NaN, ...
                'formalShapeSigma_m', NaN, 'weaklyObservable', false, ...
                'everWeaklyObservable', false, ...
                'shapeGateOn', false, 'shapeObservationSource', 'disabled', ...
                'relClockGateOn', false, 'relClockErrRaw_m', NaN, ...
                'relClockErrSolved_m', NaN, 'relClockFormalSigma_m', NaN, ...
                'solvedPos', [], 'time_s', [], ...
                'perEpoch', struct());
        end

        function [Est, Truth, tVec, ok] = gatherTrajectories_(results, N)
            % Per-asset [3 x nEp] estimated (from the EKF history) and flown-truth trajectories.
            Est = cell(1,N); Truth = cell(1,N); tVec = []; ok = false;
            nEp = [];
            for i = 1:N
                a = results.asset{i};
                if ~isfield(a,'history') || ~isfield(a.history,'x') || isempty(a.history.x); return; end
                if ~isfield(a,'truthTraj') || isempty(a.truthTraj); return; end
                sm = a.stateMap;
                Est{i}   = a.history.x(sm.r_idx, :);      % [3 x nEp] estimated ECEF position
                Truth{i} = a.truthTraj;                    % [3 x nEp] flown ECEF truth
                if size(Est{i},2) ~= size(Truth{i},2); return; end
                if isempty(nEp); nEp = size(Est{i},2); tVec = a.history.time_s(:).'; end
                if size(Est{i},2) ~= nEp; return; end      % all assets must share the epoch grid
            end
            ok = true;
        end

        function [blRaw, shRaw] = rawGeometrySeries_(Est, Truth, pairs, nEp, N)
            blRaw = nan(1,nEp);
            shRaw = nan(1,nEp);
            for kk = 1:nEp
                estK = zeros(3,N); truthK = zeros(3,N);
                for i = 1:N
                    estK(:,i) = Est{i}(:,kk);
                    truthK(:,i) = Truth{i}(:,kk);
                end
                blRaw(kk) = revgnss.SwarmRelativeSolver.baselineRms_(estK, truthK, pairs);
                shRaw(kk) = revgnss.SwarmRelativeSolver.shapeRms_(estK, truthK);
            end
        end

        function pairs = neighbourGraph_(meanPos, maxDeg)
            % <=maxDeg nearest-range neighbours per node, symmetrized by union, canonical i<k.
            % For N <= maxDeg+1 this is the full mesh (nchoosek), identical to links='all'.
            N = size(meanPos,2);
            D = zeros(N);
            for i = 1:N
                for k = 1:N
                    D(i,k) = norm(meanPos(:,i) - meanPos(:,k));
                end
            end
            adj = false(N);
            for i = 1:N
                [~, ord] = sort(D(i,:));                    % nearest first (self at distance 0)
                ord(ord == i) = [];                        % drop self
                deg = min(maxDeg, numel(ord));
                adj(i, ord(1:deg)) = true;                 % directed nearest-maxDeg
            end
            adj = adj | adj.';                             % symmetric UNION (link if either picks it)
            pairs = zeros(0,2);
            for i = 1:N
                for k = (i+1):N
                    if adj(i,k); pairs(end+1,:) = [i k]; end %#ok<AGROW>
                end
            end
        end

        function [rHat, Pshape, weak] = solveEpoch_(estK, zK, pairs, Winv, N)
            % One epoch: Gauss-Newton min-norm (inner-gauge) WLS shape correction over delta in R^{3N}.
            % delta = pinv(H'WH) H'W res puts ZERO in the 6-D rigid null space -> the corrected
            % positions keep the estimated rigid frame and only the internal shape moves. Reported metrics
            % are gauge-invariant so this choice is inert.
            nP = size(pairs,1);
            r  = estK;                                     % working estimate, updated per GN iter
            NmatLast = []; Clast = [];
            for it = 1:revgnss.SwarmRelativeSolver.GN_ITERS
                H   = zeros(nP, 3*N);
                res = zeros(nP, 1);
                for p = 1:nP
                    i = pairs(p,1); k = pairs(p,2);
                    d = r(:,i) - r(:,k); rho = norm(d); if rho < 1; rho = 1; end
                    u = d / rho;
                    ci = 3*(i-1) + (1:3); ck = 3*(k-1) + (1:3);
                    H(p, ci) =  u.';
                    H(p, ck) = -u.';
                    res(p)   = zK(p) - rho;
                end
                W    = diag(Winv);
                Nmat = H.' * W * H;
                g    = H.' * W * res;
                % TRUNCATED pseudo-inverse: zero every singular direction below RANK_TOL*max. This
                % keeps the min-norm inner gauge (rigid null space -> 0) AND, crucially, does NOT
                % amplify a WEAKLY observable shape DOF (e.g. the out-of-line bending of a near-
                % collinear formation). Untruncated pinv would divide the noise by a tiny singular
                % value and blow the correction up (32 m on the collinear N=3 helix). The unobserved
                % direction is left at the prior estimate rather than corrected with noise.
                [Cpinv, delta] = revgnss.SwarmRelativeSolver.truncPinv_(Nmat, g);
                r = r + reshape(delta, 3, N);
                NmatLast = Nmat; Clast = Cpinv;
            end
            rHat = r;

            % Formal covariance of the solved positions (truncated min-norm): diagonal position
            % variances are the conservative shape sigma the analysis layer reports (G8).
            Pshape = diag(Clast);
            Pshape = Pshape(:).';

            % Weak-observability (G10): the observable shape subspace has dimension 3N-6. If the
            % (3N-6)-th singular value is tiny relative to the largest, a shape DOF is weakly seen.
            weak = false;
            s = svd(NmatLast);
            nObs = max(0, 3*N - 6);
            if nObs >= 1 && nObs <= numel(s)
                if s(1) <= 0 || s(nObs) / s(1) < revgnss.SwarmRelativeSolver.RANK_TOL
                    weak = true;
                end
            end
        end

        function [C, x] = truncPinv_(A, b)
            % Truncated pseudo-inverse of a symmetric PSD normal matrix A: keep only singular
            % directions with s_i > RANK_TOL*s_max (drops the 6 rigid-null directions AND any
            % weakly-observable shape DOF). C = truncated pinv; x = C*b (min-norm least-squares).
            [U, S, V] = svd(A);
            s = diag(S);
            tol = revgnss.SwarmRelativeSolver.RANK_TOL * max(s);
            keep = s > tol;
            sinv = zeros(size(s));
            sinv(keep) = 1 ./ s(keep);
            C = V * diag(sinv) * U.';
            x = C * b;
        end

        function rms = baselineRms_(estK, truthK, pairs)
            % RMS over neighbour pairs of (estimated baseline length - truth baseline length).
            nP = size(pairs,1); e = zeros(nP,1);
            for p = 1:nP
                i = pairs(p,1); k = pairs(p,2);
                e(p) = norm(estK(:,i) - estK(:,k)) - norm(truthK(:,i) - truthK(:,k));
            end
            rms = sqrt(mean(e.^2));
        end

        function rms = shapeRms_(estK, truthK)
            % Best-fit-rigid (6-DOF, NO scale) shape residual RMS: Kabsch-align est -> truth, then
            % per-point position RMS. Gauge-invariant (removes translation + rotation).
            aligned = revgnss.SwarmRelativeSolver.alignToTruth_(estK, truthK);
            diffs = aligned - truthK;
            rms = sqrt(mean(sum(diffs.^2, 1)));
        end

        function aligned = alignToTruth_(estK, truthK)
            % Kabsch best-fit-rigid (6-DOF, no scale) transform of estK onto truthK. Shared by
            % shapeRms_ (byte-identical) and the per-satellite solved-relPos gauge in the summary.
            cE = mean(estK,2); cT = mean(truthK,2);
            E = estK - cE; T = truthK - cT;
            M = E * T.';
            [U,~,V] = svd(M);
            dsign = sign(det(V*U.')); if dsign == 0; dsign = 1; end
            R = V * diag([1,1,dsign]) * U.';               % rotates est -> truth
            aligned = R * (estK - cE) + cT;
        end

        function lt = twoWayLightTime_(Truth, i, k, kk, tVec, rho)
            % twoWayLightTime_  Residual two-way light-time term [m].
            %
            % In a TWO-WAY exchange the first-order Sagnac/transport terms CANCEL by
            % reciprocity (cross-validated sub-mm vs Orekit, tests/
            % test_orekit_twoway_isl_crossvalidation.m). What survives is the RELATIVE
            % motion of the two endpoints during the round trip 2*rho/c:
            %
            %   lt ~ (u . dv) * (rho/c)      u = unit baseline, dv = v_i - v_k
            %
            % Velocities are finite-differenced from the truth trajectories, since the
            % relative layer stores positions only. At a 1 km formation baseline this term
            % is MICROMETRES -- correct but inert; it only becomes relevant at the 100 km+
            % baselines a wider formation would use. Reported via out.lightTimeMax_m so the
            % magnitude is visible rather than assumed.
            lt = 0;
            n = numel(tVec);
            if n < 2; return; end
            a = max(1, kk-1); b = min(n, kk+1);
            dt = tVec(b) - tVec(a);
            if ~(dt > 0); return; end
            vi = (Truth{i}(:,b) - Truth{i}(:,a)) / dt;
            vk = (Truth{k}(:,b) - Truth{k}(:,a)) / dt;
            d  = Truth{i}(:,kk) - Truth{k}(:,kk);
            nd = norm(d); if nd < 1; return; end
            u  = d / nd;
            lt = (u.' * (vi - vk)) * (rho / revgnss.Constants.SPEED_OF_LIGHT_MPS);
        end

        function [pairBias, pairR, pairSigma] = islNoise_(cfg, pairs, meanPos)
            % Per-pair constant delay-cal bias (dominant, un-averageable floor) + conservative R.
            % The two-way-ISL delay-cal + thermal R/noise physics is self-contained here (the
            % equivalent joint-EKF two-way-ISL builder was retired). The delay-cal
            % bias is drawn once per pair from an IDENTITY-KEYED stream (node = i*64+k) so adding /
            % removing a pair cannot perturb another pair's draw. R = thermal^2 + nCorr*(const^2+rw^2)
            % with nCorr the correlated-bias inflation -> the sequential white-R weight cannot average
            % the bias below ~sqrt(nCorr) (conservative).
            g = @(p,d) revgnss.SwarmRelativeSolver.getNum_(cfg, p, d);
            sThermal = g({'multiAsset','twoWayISL','sigma_m'}, 0.01);
            sConst   = g({'multiAsset','twoWayISL','delayCal','sigma_const_m'}, 0.01);
            sRW      = g({'multiAsset','twoWayISL','delayCal','sigma_rw_m'}, 0.003);
            tau      = g({'multiAsset','twoWayISL','delayCal','tau_s'}, 3600);
            nCap     = g({'multiAsset','twoWayISL','delayCal','nCorrCap'}, 60);
            dt       = g({'simulation','dt_s'}, 1);
            nCorr    = min(max(tau/max(dt,eps),1), nCap);
            sBias    = sqrt(sConst^2 + sRW^2);
            nP = size(pairs,1);
            pairBias = zeros(nP,1); pairR = zeros(nP,1); pairSigma = zeros(nP,1);
            haveGeom = nargin >= 3 && ~isempty(meanPos);
            for p = 1:nP
                % PER-PAIR thermal sigma from the link budget (sigma ~ baseline length).
                % With linkBudget.model='fixed' (default) this returns the legacy scalar
                % for every pair, so the solver is byte-identical.
                sP = sThermal;
                if haveGeom
                    dPair = norm(meanPos(:,pairs(p,1)) - meanPos(:,pairs(p,2)));
                    sP = revgnss.ISLLinkBudget.sigma(cfg, dPair, {'multiAsset','twoWayISL'}, sThermal);
                end
                pairSigma(p) = sP;
                pairR(p) = sP^2 + nCorr*(sConst^2 + sRW^2);
                node = pairs(p,1)*64 + pairs(p,2);
                rs = RandStream('mt19937ar', 'Seed', revgnss.SwarmRelativeSolver.baseSeed_(cfg) + node);
                pairBias(p) = sBias * randn(rs);
            end
        end

        function out = solveRelativeClocks_(cfg, results, N, pairs, tVec, out)
            % Free-network minimum-norm relative-clock solve: the scalar clock dual of the shape
            % solve. Sharpens the swarm's relative clocks from sat-sat TWSTFT clock-difference
            % observations over the same neighbour graph. Read-only (no per-asset x/P write). Reports
            % the relative-clock error vs truth, raw vs solved, tail-averaged.
            nEp = numel(tVec); nP = size(pairs,1);
            if nP < 1; return; end

            % Per-asset estimated clock bias and truth clock trajectories, aligned to tVec.
            estB = zeros(N, nEp); truB = zeros(N, nEp);
            for i = 1:N
                a = results.asset{i}; sm = a.stateMap;
                if ~isfield(sm,'b_rx_idx') || isempty(sm.b_rx_idx); return; end
                estB(i,:) = a.history.x(sm.b_rx_idx, :);
                if ~isfield(a,'truthClkTraj_m') || isempty(a.truthClkTraj_m); return; end
                truB(i,:) = interp1(a.truthClkTime_s, a.truthClkTraj_m, tVec, 'linear', 'extrap');
            end

            % Per-pair TWSTFT noise (constant delay-cal bias + conservative R) + per-epoch thermal.
            [pairBias, pairR, thermalSigma] = revgnss.SwarmRelativeSolver.clockNoise_(cfg, pairs);
            thermal = zeros(nP, nEp);
            for p = 1:nP
                node = pairs(p,1)*64 + pairs(p,2);
                rs = RandStream('mt19937ar', 'Seed', revgnss.SwarmRelativeSolver.baseSeed_(cfg) + 9000 + node);
                thermal(p,:) = thermalSigma * randn(rs, 1, nEp);
            end
            Winv = 1 ./ pairR(:);

            relRaw = nan(1,nEp); relSol = nan(1,nEp); fSig = nan(1,nEp);
            for kk = 1:nEp
                eB = estB(:,kk); tB = truB(:,kk);
                H = zeros(nP, N); res = zeros(nP,1);
                for p = 1:nP
                    i = pairs(p,1); k = pairs(p,2);
                    z = (tB(i) - tB(k)) + pairBias(p) + thermal(p,kk);   % TWSTFT clock difference
                    res(p) = z - (eB(i) - eB(k));
                    H(p,i) = 1; H(p,k) = -1;                             % +1 on clk_i, -1 on clk_k
                end
                W = diag(Winv);
                % min-norm inner gauge: the 1-D null space is the common (mean) clock, which sat-sat
                % time transfer cannot observe -> left at the prior mean; every reported metric is a clock
                % DIFFERENCE so it is gauge-invariant.
                [C, delta] = revgnss.SwarmRelativeSolver.truncPinv_(H.'*W*H, H.'*W*res);
                bHat = eB + delta;
                relRaw(kk) = revgnss.SwarmRelativeSolver.relClockRms_(eB,   tB, pairs);
                relSol(kk) = revgnss.SwarmRelativeSolver.relClockRms_(bHat, tB, pairs);
                fSig(kk)   = sqrt(mean(diag(C)));
            end
            tsel = revgnss.SwarmRelativeSolver.tailIdx_(nEp);
            out.relClockGateOn        = true;
            out.relClockErrRaw_m      = sqrt(mean(relRaw(tsel).^2));
            out.relClockErrSolved_m   = sqrt(mean(relSol(tsel).^2));
            out.relClockFormalSigma_m = mean(fSig(tsel));
        end

        function rms = relClockRms_(b, truthB, pairs)
            % RMS over neighbour pairs of the relative-clock error (b_i-b_k) - (truth_i-truth_k).
            nP = size(pairs,1); e = zeros(nP,1);
            for p = 1:nP
                i = pairs(p,1); k = pairs(p,2);
                e(p) = (b(i) - b(k)) - (truthB(i) - truthB(k));
            end
            rms = sqrt(mean(e.^2));
        end

        function [pairBias, pairR, thermalSigma] = clockNoise_(cfg, pairs)
            % Per-pair sat-sat TWSTFT noise: constant delay-cal bias (identity-keyed) + conservative
            % R. The sat-sat two-way time-transfer thermal/delay-cal R physics is self-contained
            % here (the equivalent joint-EKF sat-sat two-way time-transfer builder was retired);
            % R = thermal^2 + nCorr*(const^2+rw^2), the correlated-bias inflation.
            g = @(p,d) revgnss.SwarmRelativeSolver.getNum_(cfg, p, d);
            thermalSigma = g({'multiAsset','twoWayTimeTransferISL','sigma_m'}, 0.03);
            sConst = g({'multiAsset','twoWayTimeTransferISL','delayCal','sigma_const_m'}, 0.01);
            sRW    = g({'multiAsset','twoWayTimeTransferISL','delayCal','sigma_rw_m'}, 0.003);
            tau    = g({'multiAsset','twoWayTimeTransferISL','delayCal','tau_s'}, 3600);
            nCap   = g({'multiAsset','twoWayTimeTransferISL','delayCal','nCorrCap'}, 60);
            dt     = g({'simulation','dt_s'}, 1);
            nCorr  = min(max(tau/max(dt,eps),1), nCap);
            Rii    = thermalSigma^2 + nCorr*(sConst^2 + sRW^2);
            sBias  = sqrt(sConst^2 + sRW^2);
            nP = size(pairs,1);
            pairBias = zeros(nP,1); pairR = Rii * ones(nP,1);
            for p = 1:nP
                node = pairs(p,1)*64 + pairs(p,2);
                rs = RandStream('mt19937ar', 'Seed', revgnss.SwarmRelativeSolver.baseSeed_(cfg) + 2000 + node);
                pairBias(p) = sBias * randn(rs);
            end
        end

        function s = baseSeed_(cfg)
            s = 424242;   % Relative-network noise seed, independent of simulation streams.
            if isfield(cfg,'simulation') && isfield(cfg.simulation,'seed') && isscalar(cfg.simulation.seed)
                s = s + cfg.simulation.seed;
            end
        end

        function idx = tailIdx_(nEp)
            n0 = max(1, floor(nEp * (1 - revgnss.SwarmRelativeSolver.TAIL_FRAC)) + 1);
            idx = n0:nEp;
        end

        function v = getNum_(cfg, path, dflt)
            v = cfg;
            for j = 1:numel(path)
                if isstruct(v) && isfield(v, path{j}); v = v.(path{j}); else; v = dflt; return; end
            end
            if ~(isnumeric(v) && isscalar(v) && isfinite(v)); v = dflt; end
        end

        function tf = getBool_(cfg, path, dflt)
            v = cfg;
            for j = 1:numel(path)
                if isstruct(v) && isfield(v, path{j}); v = v.(path{j}); else; tf = dflt; return; end
            end
            tf = islogical(v) && isscalar(v) && v;
        end
    end
end
