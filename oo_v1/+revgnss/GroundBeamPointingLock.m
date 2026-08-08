classdef GroundBeamPointingLock
    % GroundBeamPointingLock  Recover formation ORIENTATION from where the beam actually lands.
    %
    % THE IDEA. Inter-satellite ranges are exactly blind to a rigid rotation of the formation, so
    % no crosslink can ever fix orientation (see SwarmRelativeSolver: solvedPos leaves rotation
    % bit-for-bit unchanged). But a rigid rotation costs a phased array almost NO gain. To first
    % order the path error it induces at satellite i is
    %
    %       e_i = u . (theta x r_i) = (u x theta) . r_i
    %
    % which is LINEAR in r_i, i.e. a pure wavefront tilt. The beam stays sharp and simply lands
    % somewhere else. Measured on the 6 h archives the tilt fraction is 0.89: 89 % of the whole
    % path error is nothing but mispointing, worth 9.45 km of spot displacement on the ground.
    %
    % So orientation does not have to be ESTIMATED from a precise ranging observable at all. It can
    % be READ OFF the mispointing, which is an ambiguity-free power measurement: aim at a known
    % tower, see where the spot really lands, and the offset gives two constraints on the rotation.
    % Three towers give six constraints on three unknowns, and they break the degeneracy a single
    % tower cannot -- a roll about the line of sight to tower 1 does not move spot 1 at all, but it
    % does move spots 2 and 3. That is the "horse on three leashes".
    %
    % WHY THIS BEATS THE DIFFERENCED-CARRIER ROUTE. The joint shape+rotation solve needs the
    % formation to TURN before rotation separates from deformation -- 99 deg of turn (6 h) to reach
    % a rotation SNR of 3, and even then the carrier variant is biased 1.79x because a 7582x
    % observation weight amplifies a residual 1.55x larger than its noise model. This observable
    % needs no arc and no turn: the tower geometry is fixed in ECEF, so the solve is instantaneous
    % and well-conditioned at EVERY epoch. It also cannot be corrupted by an ambiguity, because it
    % never uses phase -- only the position of a power peak.
    %
    % WHAT IT CANNOT DO. Pointing removes the tilt and nothing else. The residual after the
    % best-fit tilt is real deformation, and that is the coherence floor -- which is exactly the
    % term the ISL crosslink DOES fix. The two are complementary, not competing: ISL owns shape,
    % this owns orientation.
    %
    % OBSERVABLE PROVENANCE. The spot offset is generated from truth, because the true geometry is
    % what decides where the beam physically lands -- the same status as any synthetic range in
    % this simulator. The ESTIMATOR consumes only 2 noisy scalars per tower plus the known tower
    % positions and its own estimated geometry; it never sees a truth position. The Jacobian is
    % built entirely from the estimate, so nothing truth-derived enters the correction itself.
    %
    %   out = revgnss.GroundBeamPointingLock.solve(cfg, results, rel)
    %
    % Gated by cfg.multiAsset.beamPointingLock.enable (default false -> byte-identical when off).
    %
    % See also: revgnss.BeamformingPhasorDiagnostics (fitSpotOffset_ is the forward model this
    %           inverts), revgnss.SwarmRelativeSolver, revgnss.JointGeometrySolver

    properties (Constant, Access = private)
        EarthRadius_m = 6378137.0;
        JacobianStep_rad = 1e-7;    % the map is linear in theta, so one step is exact
    end

    methods (Static)

        function out = solve(cfg, results, rel)
            L = revgnss.GroundBeamPointingLock;
            out = L.empty_();
            if ~L.getBool_(cfg, {'multiAsset','beamPointingLock','enable'}, false)
                out.reason = 'gateOff'; return
            end
            if ~isstruct(rel) || ~isfield(rel,'solvedPos') || isempty(rel.solvedPos)
                out.reason = 'noSolvedPos:requires multiAsset.twoWayISL.enable'; return
            end
            P0 = rel.solvedPos;
            [~, N, nEp] = size(P0);
            if N < 3
                out.reason = 'needAtLeast3Assets'; return
            end

            % --- Truth geometry (generates the observable, never enters the correction) --------
            [T, okT] = L.truthPositions_(results, N, nEp);
            if ~okT
                out.reason = 'noTruthTrajectory'; return
            end

            % --- Tower selection ---------------------------------------------------------------
            [G, towerIds, why] = L.selectTowers_(cfg, T);
            if isempty(G)
                out.reason = why; return
            end
            nT = size(G,2);
            out.towerIds = towerIds;
            out.nTowers  = nT;

            spotSigma = max(1e-6, L.getNum_(cfg, {'multiAsset','beamPointingLock','spotSigma_m'}, 500));
            out.spotSigma_m = spotSigma;
            seed = round(L.getNum_(cfg, {'multiAsset','beamPointingLock','seed'}, 90210));
            rs = RandStream('threefry','Seed',seed);

            Pc = P0;
            theta = zeros(3, nEp);
            sigTheta = nan(3, nEp);
            spotPre = nan(nT, nEp);
            spotPost = nan(nT, nEp);
            condJ = nan(1, nEp);
            nUsed = 0;

            for k = 1:nEp
                Pk = P0(:,:,k); Tk = T(:,:,k);
                if any(~isfinite(Pk(:))) || any(~isfinite(Tk(:))); continue; end

                % 1) MEASURE: where does the beam land, per tower? (truth-generated + noise)
                dObs = zeros(2*nT,1); okAll = true;
                for j = 1:nT
                    [dE, dN, ~] = L.spotOffset_(Tk, G(:,j), L.pathError_(Pk, Tk, G(:,j)), G(:,j));
                    if ~isfinite(dE) || ~isfinite(dN); okAll = false; break; end
                    noise = spotSigma * randn(rs, 2, 1);
                    dObs(2*j-1) = dE + noise(1);
                    dObs(2*j)   = dN + noise(2);
                    spotPre(j,k) = hypot(dE, dN);
                end
                if ~okAll; continue; end

                % 2) JACOBIAN: estimate-only prediction of how the spots move with a rotation.
                J = zeros(2*nT, 3); okJ = true;
                for ax = 1:3
                    dth = zeros(3,1); dth(ax) = L.JacobianStep_rad;
                    Pp = L.rotateAbout_(Pk, dth);
                    col = zeros(2*nT,1);
                    for j = 1:nT
                        % Prediction uses the ESTIMATE as its own reference, so no truth leaks in.
                        [dE, dN, ~] = L.spotOffset_(Pk, G(:,j), L.pathError_(Pp, Pk, G(:,j)), G(:,j));
                        if ~isfinite(dE) || ~isfinite(dN); okJ = false; break; end
                        col(2*j-1) = dE; col(2*j) = dN;
                    end
                    if ~okJ; break; end
                    J(:,ax) = col / L.JacobianStep_rad;
                end
                if ~okJ; continue; end
                condJ(k) = cond(J);
                if ~isfinite(condJ(k)) || condJ(k) > 1e10; continue; end

                % 3) SOLVE for the rotation that nulls the measured mispointing, and APPLY it.
                phi = -(J \ dObs);
                Pk2 = L.rotateAbout_(Pk, phi);
                Pc(:,:,k) = Pk2;
                theta(:,k) = phi;
                C = spotSigma^2 * L.symInv_(J.'*J);
                sigTheta(:,k) = sqrt(abs(diag(C)));
                nUsed = nUsed + 1;

                % Residual mispointing after the correction -- the closed-loop error.
                for j = 1:nT
                    [dE, dN, ~] = L.spotOffset_(Tk, G(:,j), L.pathError_(Pk2, Tk, G(:,j)), G(:,j));
                    spotPost(j,k) = hypot(dE, dN);
                end
            end

            if nUsed == 0
                out.reason = 'noEpochSolved'; return
            end
            out.applicable        = true;
            out.reason            = 'ok';
            out.solvedPos         = Pc;
            out.theta_rad         = theta;
            out.thetaSigma_rad    = sigTheta;
            out.nEpochsUsed       = nUsed;
            out.condition         = median(condJ(isfinite(condJ)));
            out.spotErrorPre_m    = spotPre;
            out.spotErrorPost_m   = spotPost;
            out.tailSpotPre_m     = L.tailRms_(spotPre);
            out.tailSpotPost_m    = L.tailRms_(spotPost);
            out.tailThetaSigma_deg = L.tailRms_(vecnorm(sigTheta,2,1)) * 180/pi;
            out.appliedTheta_deg   = L.tailRms_(vecnorm(theta,2,1)) * 180/pi;
        end

        function print(out)
            % print  Console summary, in the two units that decide the result: how far the spot
            % was off, and how much rotation had to be applied to bring it back.
            if ~isstruct(out) || ~isfield(out,'applicable') || ~out.applicable
                r = 'unavailable';
                if isstruct(out) && isfield(out,'reason'); r = out.reason; end
                fprintf('  Beam pointing lock: %s\n', r);
                return
            end
            fprintf('  Beam pointing lock (%d towers, spot sigma %.0f m):\n', out.nTowers, out.spotSigma_m);
            fprintf('    towers %s | epochs %d | Jacobian cond %.2f\n', ...
                mat2str(out.towerIds), out.nEpochsUsed, out.condition);
            fprintf('    spot error  %.0f m -> %.0f m  | rotation applied %.5f deg (formal %.5f deg)\n', ...
                out.tailSpotPre_m, out.tailSpotPost_m, out.appliedTheta_deg, out.tailThetaSigma_deg);
        end
    end

    methods (Static, Access = private)

        function e = pathError_(P, Ref, g)
            % pathError_  Per-satellite path error toward g, mean-removed.
            %   |g - P_i| - |g - Ref_i|
            % With Ref = truth this is the physical error that displaces the beam; with Ref = the
            % estimate it is the predicted change from perturbing the estimate.
            e = vecnorm(g - P, 2, 1) - vecnorm(g - Ref, 2, 1);
            e = e - mean(e);
        end

        function [dEast, dNorth, resid] = spotOffset_(rRef, target_m, e, up_ref)
            % spotOffset_  Least-squares spot offset in the ground tangent plane at the target.
            %
            % Same construction as BeamformingPhasorDiagnostics.fitSpotOffset_ (that method is
            % private, so the maths is restated rather than reached into): solve min_d ||U d - e||
            % with U(i,:) = [u_i.eEast, u_i.eNorth], u_i from satellite i toward the target. The
            % along-boresight direction is deliberately excluded -- with every u_i near-parallel it
            % is near-degenerate, and fitting it would let defocus absorb error that does cost gain.
            dEast = NaN; dNorth = NaN; resid = e;
            up = up_ref/max(norm(up_ref),realmin);
            ref = [0;0;1];
            if abs(up.'*ref) > 0.99; ref = [1;0;0]; end
            eEast = cross(ref, up); n = norm(eEast);
            if ~(n > 0); return; end
            eEast = eEast/n;
            eNorth = cross(up, eEast);

            d = target_m - rRef;
            rng_m = vecnorm(d, 2, 1);
            U = d ./ max(rng_m, realmin);
            A = [(eEast.'*U).', (eNorth.'*U).'];
            A = A - mean(A,1);              % e is mean-removed, so A must be too
            if rank(A) < 2; return; end
            sol = A\e(:);
            dEast = sol(1); dNorth = sol(2);
            resid = (e(:) - A*sol).';
        end

        function Q = rotateAbout_(P, th)
            % rotateAbout_  Rotate the formation about its own centroid by rotation vector th.
            c = mean(P, 2);
            Q = revgnss.GroundBeamPointingLock.rot_(th) * (P - c) + c;
        end

        function R = rot_(th)
            % Rodrigues, exact for any angle.
            t = norm(th);
            if t < 1e-14; R = eye(3); return; end
            k = th/t; K = [0 -k(3) k(2); k(3) 0 -k(1); -k(2) k(1) 0];
            R = eye(3) + sin(t)*K + (1-cos(t))*(K*K);
        end

        function [T, ok] = truthPositions_(results, N, nEp)
            T = nan(3, N, nEp); ok = false;
            if ~isstruct(results) || ~isfield(results,'asset'); return; end
            for i = 1:N
                a = results.asset{i};
                if ~isfield(a,'truthTraj') || isempty(a.truthTraj); return; end
                Tt = a.truthTraj;
                if size(Tt,1) ~= 3; Tt = Tt.'; end
                if size(Tt,2) < nEp; return; end
                T(:,i,:) = reshape(Tt(:,1:nEp), 3, 1, nEp);
            end
            ok = all(isfinite(T(:)));
        end

        function [G, ids, why] = selectTowers_(cfg, T)
            % selectTowers_  Pick the towers the beam will lock onto.
            %
            % 'auto' takes the nTowers visible towers with the WIDEST angular spread as seen from
            % the formation, because the conditioning of the rotation solve is set by how much the
            % three lines of sight differ -- three towers clustered together constrain roll about
            % their common boresight no better than one does.
            L = revgnss.GroundBeamPointingLock;
            G = zeros(3,0); ids = []; why = '';
            if ~isfield(cfg,'towers'); why = 'noTowersInConfig'; return; end
            nAvail = numel(cfg.towers);
            if isfield(cfg,'scenario') && isfield(cfg.scenario,'nTowers')
                nAvail = min(nAvail, round(cfg.scenario.nTowers));
            end
            All = zeros(3, nAvail);
            for k = 1:nAvail
                All(:,k) = models.frames.GeometryUtils.geodetic2ecef( ...
                    cfg.towers(k).lat_rad, cfg.towers(k).lon_rad, cfg.towers(k).alt_m);
            end
            want = round(L.getNum_(cfg, {'multiAsset','beamPointingLock','nTowers'}, 3));
            minElev = L.getNum_(cfg, {'multiAsset','beamPointingLock','minElevation_deg'}, 10);

            % Visibility from the formation centroid, at the middle of the arc.
            kMid = max(1, round(size(T,3)/2));
            c = mean(T(:,:,kMid), 2);
            vis = false(1, nAvail);
            for k = 1:nAvail
                up = All(:,k)/norm(All(:,k));
                d  = c - All(:,k);
                vis(k) = asind(max(-1,min(1,(up.'*d)/norm(d)))) >= minElev;
            end
            idxVis = find(vis);
            if numel(idxVis) < 3
                why = sprintf('needAtLeast3VisibleTowers(have %d above %.0f deg)', numel(idxVis), minElev);
                return
            end

            forced = L.getVec_(cfg, {'multiAsset','beamPointingLock','towers'});
            if ~isempty(forced)
                ids = round(forced(:).');
                ids = ids(ismember(ids, idxVis));
                if numel(ids) < 3; why = 'forcedTowersNotVisible'; return; end
            else
                want = max(3, min(want, numel(idxVis)));
                ids = L.widestSpread_(All, c, idxVis, want);
            end
            G = All(:, ids);
        end

        function ids = widestSpread_(All, c, cand, want)
            % widestSpread_  Greedy max-min angular separation of the lines of sight.
            U = zeros(3, numel(cand));
            for m = 1:numel(cand)
                v = All(:,cand(m)) - c; U(:,m) = v/norm(v);
            end
            % Seed with the most separated pair.
            best = [1 2]; bestSep = -inf;
            for i = 1:numel(cand)
                for j = i+1:numel(cand)
                    s = 1 - U(:,i).'*U(:,j);
                    if s > bestSep; bestSep = s; best = [i j]; end
                end
            end
            pick = best;
            while numel(pick) < want
                bestAdd = 0; bestVal = -inf;
                for m = 1:numel(cand)
                    if any(pick == m); continue; end
                    v = min(1 - U(:,m).'*U(:,pick));   % max-min separation
                    if v > bestVal; bestVal = v; bestAdd = m; end
                end
                if bestAdd == 0; break; end
                pick(end+1) = bestAdd; %#ok<AGROW>
            end
            ids = sort(cand(pick));
        end

        function r = tailRms_(X, frac)
            if nargin < 2; frac = 0.2; end
            if isempty(X); r = NaN; return; end
            v = X(:).';
            if size(X,1) > 1
                n = size(X,2); i0 = max(1, floor(n*(1-frac))+1);
                v = reshape(X(:,i0:end), 1, []);
            else
                n = numel(v); i0 = max(1, floor(n*(1-frac))+1);
                v = v(i0:end);
            end
            v = v(isfinite(v));
            if isempty(v); r = NaN; else; r = sqrt(mean(v.^2)); end
        end

        function Ai = symInv_(A)
            A = (A+A.')/2;
            [U,S,V] = svd(A);
            s = diag(S); tol = max(size(A))*eps(max(s));
            si = zeros(size(s)); si(s > tol) = 1./s(s > tol);
            Ai = V*diag(si)*U.';
        end

        function out = empty_()
            out = struct('applicable', false, 'reason', 'notAttempted', 'solvedPos', [], ...
                'theta_rad', [], 'thetaSigma_rad', [], 'nEpochsUsed', 0, 'condition', NaN, ...
                'towerIds', [], 'nTowers', 0, 'spotSigma_m', NaN, ...
                'spotErrorPre_m', [], 'spotErrorPost_m', [], ...
                'tailSpotPre_m', NaN, 'tailSpotPost_m', NaN, ...
                'tailThetaSigma_deg', NaN, 'appliedTheta_deg', NaN);
        end

        function v = getNum_(cfg, path, dflt)
            v = cfg;
            for j = 1:numel(path)
                if isstruct(v) && isfield(v, path{j}); v = v.(path{j}); else; v = dflt; return; end
            end
            if ~(isnumeric(v) && isscalar(v)); v = dflt; end
        end

        function v = getBool_(cfg, path, dflt)
            v = dflt; x = cfg;
            for j = 1:numel(path)
                if isstruct(x) && isfield(x, path{j}); x = x.(path{j}); else; return; end
            end
            if islogical(x) || isnumeric(x); v = logical(x); end
        end

        function v = getVec_(cfg, path)
            v = []; x = cfg;
            for j = 1:numel(path)
                if isstruct(x) && isfield(x, path{j}); x = x.(path{j}); else; return; end
            end
            if isnumeric(x); v = x(:).'; end
        end
    end
end
