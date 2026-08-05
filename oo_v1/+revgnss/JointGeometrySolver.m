classdef JointGeometrySolver
    % JointGeometrySolver  Combined ISL + ground relative-geometry solve, over ALL 3N parameters.
    %
    % WHY THIS EXISTS. revgnss.GroundDifferencedRotationSolver estimates the formation's
    % orientation with exactly three free parameters and no shape freedom. Measured consequence:
    % any DEFORMATION error that is correlated over the arc -- which every EKF error is -- has
    % nowhere to go but into the rotation, at a stable 0.30 deg per metre. Injecting a known
    % 0.02 deg rotation and a controlled shape error recovered 0.0200 deg at zero shape error,
    % 0.0338 at 0.10 m, 0.2940 at 1.00 m and 1.0966 at 3.72 m -- and the formal sigma reported
    % 0.0115 deg in EVERY one of those rows, i.e. it is completely blind to its own dominant
    % error. That is a property of solving rotation SEPARATELY, not of the observable.
    %
    % THE FIX is to stop separating them. Shape and orientation are solved in one system:
    %   * per epoch k: a shape correction dp_k, constrained to the 3N-6 SHAPE subspace and
    %     carrying an ISL prior (sigma_shape)
    %   * globally:    one rotation dtheta shared by every epoch, carrying no prior at all,
    %     because inter-satellite ranging supplies exactly zero information about it
    % Shape error then has somewhere to go, and the leakage disappears by construction rather
    % than being detected and guarded against after the fact.
    %
    % BOTH PARAMETERS ARE GLOBAL, AND THAT IS THE WHOLE POINT. The first version of this class
    % made the shape correction PER EPOCH. It still leaked -- 0.10 m of shape error produced
    % 0.049 deg of rotation, 3.72 m produced 0.479 deg -- because a per-epoch parameter tells the
    % estimator that the shape error is INDEPENDENT each epoch, so marginalising over 3601 epochs
    % appears to average it away. It does not: the shape error is the SAME every epoch. That
    % arc-correlation is precisely the property that makes it leak, and modelling it as
    % independent hands the correlated part straight to the rotation.
    %
    % So the shape correction is a single arc-constant dp, exactly like the rotation. 3N + 3 = 63
    % parameters total, one dense solve, no Schur complement, no per-epoch inverse.
    %
    % WHAT SEPARATES THEM. An arc-constant shape offset and an arc-constant rotation are told
    % apart ONLY because the formation's internal geometry ROTATES through the orbit, so the
    % rotation generator G_k turns while a fixed shape offset does not. Over a 3600 s arc the
    % formation turns 15 deg, which is weak separation; over 6 h it turns 90 deg, which is
    % strong. Arc length is therefore not a tuning knob here, it is the mechanism.
    %
    % KNOWN SIMPLIFICATION, stated rather than hidden: the ISL contribution enters as an
    % ISOTROPIC prior of sigma_shape on the shape subspace, not as the true per-epoch ISL
    % covariance. revgnss.SwarmRelativeSolver computes that covariance but publishes only a
    % scalar tail average (formalShapeSigma_m), so the anisotropy is not currently reachable.
    % This is the same approximation the scratch CRLB used to predict the behaviour, so the two
    % are consistent; consuming the real per-epoch covariance is the obvious refinement.
    %
    %   out = revgnss.JointGeometrySolver.solve(cfg, results, rel)
    %       out.applicable      false when the gate is off or a guard fails (reason recorded)
    %       out.solvedPos       [3 x N x nEp] geometry after the joint correction
    %       out.theta_rad       [3 x 1] global rotation correction
    %       out.thetaSigma_rad  [3 x 1] formal 1-sigma, from the Schur-reduced 3x3
    %       out.shapeStep_m     RMS size of the per-epoch shape correction actually applied

    properties (Constant, Access = private)
        GN_ITERS   = 3;
        MIN_TOWERS = 2;
        RANK_TOL   = 1e-9;
    end

    methods (Static)

        function out = solve(cfg, results, rel)
            J = revgnss.JointGeometrySolver;
            out = J.emptyOut_();
            if ~J.getBool_(cfg, {'multiAsset','jointGeometry','enable'}, false)
                out.reason = 'gateOff'; return
            end
            if ~isstruct(rel) || ~isfield(rel,'solvedPos') || isempty(rel.solvedPos)
                out.reason = 'noSolvedPos:requires multiAsset.twoWayISL.enable'; return
            end
            N = size(rel.solvedPos,2); nEp = size(rel.solvedPos,3);
            if N < 4; out.reason = 'needAtLeast4Assets'; return; end
            tVec = rel.time_s(:).';
            if numel(tVec) ~= nEp; out.reason = 'timeGridMismatch'; return; end

            % One physics path, shared with the 3-parameter solver.
            obs = revgnss.GroundDifferencedRotationSolver.buildObservable(cfg, results, tVec, N);
            if ~obs.ok; out.reason = obs.reason; return; end
            towerPos = obs.towerPos; nTw = obs.nTw;
            rhoObs   = obs.rhoObs;  visTw = obs.visTw;

            % Measurement variance of one double difference: four raw ranges, plus whatever
            % differential atmosphere was injected. Multipath is coloured, so its contribution
            % to an ARC average is sigma*sqrt(tau/dt), not sigma -- charge it at that rate.
            dt    = max(1e-9, median(diff(tVec)));
            tauMp = max(dt, J.getNum_(cfg, {'errors','multipath','coloredGM','tau_s'}, 60));
            varDD = 4*obs.codeSigma_m^2 ...
                  + 4*obs.multipathSigma_m^2*(tauMp/dt) ...
                  + 4*obs.differentialAtmosphereSigma_m^2;
            w = 1/max(varDD, eps);

            % ISL shape prior. Prefer an explicit declaration; fall back to what the ISL layer
            % measured for itself. Never silently assume a good shape -- that was the failure
            % mode of the 3-parameter solver.
            sigShape = J.getNum_(cfg, {'multiAsset','jointGeometry','shapePriorSigma_m'}, NaN);
            if ~isfinite(sigShape)
                sigShape = J.getNum_(rel, {'shapeErrSolved_m'}, NaN);
            end
            if ~isfinite(sigShape) || sigShape <= 0
                out.reason = 'noShapePrior: set multiAsset.jointGeometry.shapePriorSigma_m'; return
            end
            out.shapePriorSigma_m = sigShape;

            % Parameter vector x = [dp (3N, arc-constant, shape subspace); dtheta (3)].
            np = 3*N + 3;
            theta = zeros(3,1); dpTot = zeros(3*N,1);
            P = rel.solvedPos;
            nUsed = 0; nRow = 0; sse = 0; Nm = zeros(np);

            for iter = 1:J.GN_ITERS
                Nm = zeros(np); bv = zeros(np,1);
                nUsed = 0; nRow = 0; sse = 0;
                for k = 1:nEp
                    okTw = find(visTw(:,k)).';
                    if numel(okTw) < J.MIN_TOWERS; continue; end
                    Pk = P(:,:,k);
                    if any(~isfinite(Pk(:))); continue; end
                    q = Pk - mean(Pk,2);

                    % Rotation generator at THIS epoch: dp_i = dtheta x q_i = -skew(q_i)*dtheta.
                    % G turns with the formation; a constant shape offset does not. That
                    % difference is the only thing separating the two parameter blocks.
                    G = zeros(3*N,3);
                    for i = 1:N
                        G(3*(i-1)+(1:3),:) = -J.skew_(q(:,i));
                    end

                    u = zeros(3,N,nTw); rhoP = zeros(N,nTw);
                    for m = okTw
                        for i = 1:N
                            d = Pk(:,i) - towerPos(:,m);
                            rhoP(i,m) = norm(d); u(:,i,m) = d/rhoP(i,m);
                        end
                    end

                    ref = okTw(1);
                    nDD = (numel(okTw)-1)*(N-1);
                    Jp = zeros(nDD, 3*N); r = zeros(nDD,1); row = 0;
                    for m = okTw
                        if m == ref; continue; end
                        for i = 2:N
                            row = row + 1;
                            r(row) = ((rhoObs(i,m,k)-rhoObs(1,m,k)) - (rhoObs(i,ref,k)-rhoObs(1,ref,k))) ...
                                   - ((rhoP(i,m)-rhoP(1,m)) - (rhoP(i,ref)-rhoP(1,ref)));
                            Jp(row, 3*(i-1)+(1:3)) =  (u(:,i,m) - u(:,i,ref)).';
                            Jp(row, 1:3)           = -(u(:,1,m) - u(:,1,ref)).';
                        end
                    end
                    if row < 1; continue; end
                    Jp = Jp(1:row,:); r = r(1:row);

                    Ak = [Jp, Jp*G];
                    Nm = Nm + w*(Ak.'*Ak);
                    bv = bv + w*(Ak.'*r);
                    sse = sse + r.'*r; nRow = nRow + row; nUsed = nUsed + 1;
                end
                if nUsed < 1; out.reason = 'noUsableEpochs'; return; end

                % ISL prior on the shape block only. Rotation gets NO prior -- inter-satellite
                % ranging supplies exactly zero information about it, and pretending otherwise
                % is what a naive combined filter would get wrong.
                Pr = J.shapeProjector_(P(:,:,1), N);
                Nm(1:3*N,1:3*N) = Nm(1:3*N,1:3*N) + Pr/(sigShape^2);

                % NO rcond guard here. Nm is rank-deficient BY CONSTRUCTION: the shape projector
                % removes translation and rotation from the dp block, so at least 6 eigenvalues
                % are exactly zero. That is intended, and the truncated pseudo-inverse is what
                % handles it. Observability of the thing we actually care about is checked on the
                % ROTATION block below, not on the full matrix.
                Ci  = J.pinvTrunc_(Nm);
                rotInfo = Nm(3*N+(1:3), 3*N+(1:3));
                if rcond(rotInfo) < 1e-12
                    out.reason = 'rotationGeometrySingular'; return
                end
                dx  = Ci*bv;
                dp  = Pr*dx(1:3*N);            % keep the shape step off the rigid subspace
                dth = dx(3*N+(1:3));
                theta = theta + dth; dpTot = dpTot + dp;

                for k = 1:nEp
                    Pk = P(:,:,k);
                    if any(~isfinite(Pk(:))); continue; end
                    c = mean(Pk,2);
                    P(:,:,k) = c + J.rot_(dth)*(Pk - c) + reshape(dp,3,N);
                end
            end

            dof = max(1, nRow - np);
            C   = (sse/dof)*J.pinvTrunc_(Nm);
            out.applicable      = true;
            out.reason          = 'ok';
            out.solvedPos       = P;
            out.theta_rad       = theta;
            out.thetaSigma_rad  = sqrt(abs(diag(C(3*N+(1:3), 3*N+(1:3)))));
            out.nEpochsUsed     = nUsed;
            out.nObs            = nRow;
            out.shapeStep_m     = sqrt(mean(vecnorm(reshape(dpTot,3,N),2,1).^2));
            out.condition       = cond(Nm);
            out.ddSigma_m       = sqrt(varDD);
        end
    end

    methods (Static, Access = private)

        function o = emptyOut_()
            o = struct('applicable', false, 'reason', 'notAttempted', 'solvedPos', [], ...
                'theta_rad', [0;0;0], 'thetaSigma_rad', [NaN;NaN;NaN], ...
                'nEpochsUsed', 0, 'nObs', 0, 'shapeStep_m', NaN, 'condition', NaN, ...
                'shapePriorSigma_m', NaN, 'ddSigma_m', NaN);
        end

        function S = skew_(v)
            S = [0 -v(3) v(2); v(3) 0 -v(1); -v(2) v(1) 0];
        end

        function Pr = shapeProjector_(Pk, N)
            % Projector onto the 3N-6 SHAPE subspace: translation and rotation are removed, so
            % the shape parameter cannot absorb the rotation it is meant to be separated from.
            q = Pk - mean(Pk,2);
            G = zeros(3*N,3); T = repmat(eye(3), N, 1);
            for i = 1:N
                G(3*(i-1)+(1:3),:) = -revgnss.JointGeometrySolver.skew_(q(:,i));
            end
            Q = orth([G, T]);
            Pr = eye(3*N) - Q*Q.';
        end

        function R = rot_(th)
            t = norm(th);
            if t < 1e-14; R = eye(3); return; end
            k = th/t; K = revgnss.JointGeometrySolver.skew_(k);
            R = eye(3) + sin(t)*K + (1-cos(t))*(K*K);
        end

        function C = pinvTrunc_(A)
            % Truncated pseudo-inverse: the projected normal matrix is singular by construction
            % on the rigid subspace, and that singularity is intended, not a failure.
            [U,Sv,V] = svd((A+A.')/2);
            s = diag(Sv); tol = revgnss.JointGeometrySolver.RANK_TOL * max(s);
            si = zeros(size(s)); keep = s > tol; si(keep) = 1./s(keep);
            C = V*diag(si)*U.';
        end

        function v = getBool_(cfg, path, dflt)
            v = logical(revgnss.JointGeometrySolver.getNum_(cfg, path, dflt));
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
