classdef ShapeFrameSeparationProbe
    % ShapeFrameSeparationProbe  Is the shape/rotation separation physics, or parameterisation?
    %
    % EXECUTION-PLAN ITEM A4, AND IT GATES THREE OTHER PHASES. revgnss.JointGeometrySolver
    % separates an arc-constant shape offset from an arc-constant rotation on one argument: the
    % rotation generator G_k is rebuilt from the formation geometry at every epoch, so it TURNS
    % through the orbit, while a shape offset expressed in ECEF does not. That argument is the
    % basis of the turn-angle law (14.5x penalty at 7.5 deg of turn, 1.0x at 360 deg), of the
    % whole case for long arcs, and of Phase H's 4N+3 hardware-bias separation, which rests on
    % exactly the same mechanism.
    %
    % THE OBJECTION. A physical deformation is constant in the BODY/LVLH frame. In ECEF it
    % therefore turns WITH the formation -- the opposite of what the solver assumes. If the true
    % error turns the same way the rotation generator does, "G turns, dp does not" is an artefact
    % of the parameterisation and not a property of the measurement.
    %
    % HOW THIS ANSWERS IT. Two experiments, both driving the REAL solver rather than a second
    % copy of its mathematics -- the observable, the Jacobians, the whitening and the acceptance
    % tests are all the shipping ones:
    %
    %   (1) INJECTION AND RECOVERY. Take the geometry the ISL layer produced, apply a KNOWN
    %       rotation and a KNOWN shape error to it, and hand the result to the solver as its
    %       starting estimate. The true geometry -- and therefore the observable -- is untouched,
    %       so the solver's job is to undo exactly what was injected. Run every combination of
    %       {shape error injected in ECEF, in the body frame} x {solver parameterised in ECEF, in
    %       the body frame}. The OFF-DIAGONAL cells are the interesting ones: they say what
    %       happens when the parameterisation does not match the physics.
    %
    %   (2) ARC SWEEP. Repeat over prefixes of the arc, so the separation penalty is measured as
    %       a function of how far the formation actually turned, in both parameterisations. If
    %       the turn-angle law survives in both, three phases rest on physics. If it appears in
    %       one and not the other, it was parameterisation, and the plan changes shape.
    %
    % REPORT EITHER OUTCOME. This class exists to be able to say the mechanism is an artefact.
    %
    %   out = revgnss.ShapeFrameSeparationProbe.sweep(cfg, results, rel)
    %   out = revgnss.ShapeFrameSeparationProbe.sweep(cfg, results, rel, opts)
    %       opts.arcFractions      prefixes of the arc to test (default [0.125 0.25 0.5 1])
    %       opts.rotation_deg      magnitude of the injected rotation (default 0.02)
    %       opts.shapeError_m      per-point RMS of the injected shape error (default 0.10)
    %       opts.frames            solver parameterisations (default {'ecef','formationBody'})
    %       opts.injectFrames      frames to inject the shape error in (default the same two)

    methods (Static)

        function out = sweep(cfg, results, rel, opts)
            P = revgnss.ShapeFrameSeparationProbe;
            if nargin < 4; opts = struct(); end
            opts = P.defaults_(opts);
            out = struct('applicable', false, 'reason', 'notAttempted', 'rows', struct([]), ...
                'opts', opts, 'observable', 'code', 'carrierObservable', []);

            if ~isstruct(rel) || ~isfield(rel,'solvedPos') || isempty(rel.solvedPos)
                out.reason = 'noSolvedPos'; return
            end
            nEp = size(rel.solvedPos,3);
            if nEp < 10; out.reason = 'arcTooShort'; return; end

            % The solver refuses when the gate is off, so turn it on for the probe only. The
            % acceptance tests are DISABLED here on purpose: this class is measuring what the
            % estimator recovers, and a refusal to write back would hide that behind a guard.
            base = cfg;
            base.multiAsset.jointGeometry.enable = true;
            base.multiAsset.jointGeometry.accept.minRotationSnr    = 0;
            base.multiAsset.jointGeometry.accept.maxShapeStepSigma = Inf;

            % THE OBSERVABLE HAS TO GIVE THE SHAPE ROOM TO MOVE, OR THE EXPERIMENT IS VACUOUS.
            % A4 asks whether the shape/rotation separation depends on which frame the shape is
            % parameterised in. That question is only answerable if the shape can actually move:
            % on the CODE double difference only 1 of 12 shape DOF is constrained, so every cell
            % of the table returns the same thing and the verdict reads "the frame does not
            % matter" for a reason that has nothing to do with the frame. On the fixed wide-lane
            % carrier, 9 of 12 are constrained. Default to carrier when the resolver can supply
            % it, and RECORD which was used, because the two answer different questions.
            ov = [];
            out.observable = 'code';
            if ~strcmpi(opts.observable, 'code')
                cr = revgnss.GroundCarrierAmbiguityResolver.resolve( ...
                    P.forceCarrier_(cfg), results, rel);
                ov = revgnss.SwarmRelativeSolver.carrierObservableFor(base, cr);
                if ~isempty(ov)
                    out.observable = ov.name;
                elseif strcmpi(opts.observable, 'carrier')
                    out.reason = ['carrierObservableUnavailable: ' cr.reason];
                    return
                end
            end
            out.carrierObservable = ov;

            rows = struct('arcFraction',{},'nEpochs',{},'duration_s',{},'turnAngle_deg',{}, ...
                'solverFrame',{},'injectFrame',{},'injectedRotation_deg',{}, ...
                'injectedShape_m',{},'recoveredRotation_deg',{},'rotationRecoveryRatio',{}, ...
                'rotationErrAfter_deg',{},'shapeStep_m',{},'observableShapeDof',{}, ...
                'shapeDofTotal',{},'separationPenalty',{},'separationPenaltyFree',{}, ...
                'rotationSigma_deg',{},'reason',{});

            for a = 1:numel(opts.arcFractions)
                n = max(10, round(opts.arcFractions(a)*nEp));
                n = min(n, nEp);
                relCut = P.truncate_(rel, n);
                for f = 1:numel(opts.frames)
                    cfgF = base;
                    cfgF.multiAsset.jointGeometry.shapeFrame = opts.frames{f};
                    for g = 1:numel(opts.injectFrames)
                        [relInj, thTrue, dpRms] = P.inject_(relCut, ...
                            opts.rotation_deg, opts.shapeError_m, opts.injectFrames{g}, opts.seed);
                        jnt = revgnss.JointGeometrySolver.solve(cfgF, results, relInj, ...
                            P.truncateObservable_(ov, n));

                        r = struct();
                        r.arcFraction  = opts.arcFractions(a);
                        r.nEpochs      = n;
                        r.duration_s   = relCut.time_s(end) - relCut.time_s(1);
                        r.turnAngle_deg = jnt.turnAngle_deg;
                        r.solverFrame  = opts.frames{f};
                        r.injectFrame  = opts.injectFrames{g};
                        r.injectedRotation_deg = norm(thTrue)*180/pi;
                        r.injectedShape_m      = dpRms;
                        % The solver returns the CORRECTION, so a perfect recovery is -thTrue.
                        r.recoveredRotation_deg = norm(jnt.theta_rad)*180/pi;
                        r.rotationRecoveryRatio = ...
                            P.safeDiv_(norm(jnt.theta_rad), norm(thTrue));
                        r.rotationErrAfter_deg  = norm(jnt.theta_rad(:) + thTrue(:))*180/pi;
                        r.shapeStep_m           = jnt.shapeStep_m;
                        r.observableShapeDof    = jnt.observableShapeDof;
                        r.shapeDofTotal         = jnt.shapeDofTotal;
                        r.separationPenalty     = jnt.separationPenalty;
                        r.separationPenaltyFree = jnt.separationPenaltyFree;
                        r.rotationSigma_deg     = norm(jnt.thetaSigma_rad)*180/pi;
                        r.reason                = jnt.reason;
                        rows(end+1) = r;                                       %#ok<AGROW>
                    end
                end
            end
            out.applicable = true; out.reason = 'ok'; out.rows = rows;
            out.verdict = revgnss.ShapeFrameSeparationProbe.verdict_(rows);
        end

        function print(out)
            % print  The table, in the form the finding has to be reported in.
            if ~isstruct(out) || ~isfield(out,'applicable') || ~out.applicable
                r = 'unavailable';
                if isstruct(out) && isfield(out,'reason'); r = out.reason; end
                fprintf('  Shape-frame separation probe: %s\n', r); return
            end
            fprintf('\n  === A4: shape-frame separation (injection + arc sweep) ===\n');
            fprintf('  observable: %s   (the shape must have room to move or the frame cannot matter)\n', ...
                out.observable);
            fprintf('  %8s %7s  %-14s %-14s  %9s %9s %7s %7s %9s\n', ...
                'arc[s]', 'turn', 'solverFrame', 'injectFrame', ...
                'errAfter', 'shapeStep', 'dof', 'penalty', 'free');
            for i = 1:numel(out.rows)
                r = out.rows(i);
                fprintf('  %8.0f %6.1f%s  %-14s %-14s  %9.5f %9.4f %3d/%-3d %7.2f %9.3g\n', ...
                    r.duration_s, r.turnAngle_deg, char(176), r.solverFrame, r.injectFrame, ...
                    r.rotationErrAfter_deg, r.shapeStep_m, ...
                    r.observableShapeDof, r.shapeDofTotal, ...
                    r.separationPenalty, r.separationPenaltyFree);
            end
            fprintf('  VERDICT: %s\n', out.verdict);
        end
    end

    methods (Static, Access = private)

        function o = defaults_(o)
            d = struct('arcFractions', [0.125 0.25 0.5 1.0], 'rotation_deg', 0.02, ...
                'shapeError_m', 0.10, 'seed', 20260805, 'observable', 'auto', ...
                'frames', {{'ecef','formationBody'}}, ...
                'injectFrames', {{'ecef','formationBody'}});
            f = fieldnames(d);
            for i = 1:numel(f)
                if ~isfield(o, f{i}) || isempty(o.(f{i})); o.(f{i}) = d.(f{i}); end
            end
        end

        function c = forceCarrier_(cfg)
            % forceCarrier_  Turn the resolver on for the probe's own use without disturbing the
            % caller's configuration, which may legitimately have it off.
            c = cfg;
            c.multiAsset.groundCarrier.enable = true;
        end

        function ov = truncateObservable_(ov, n)
            % truncateObservable_  Clip a per-link observable to the arc prefix under test. The
            % observable is [N x nTw x nEp]; the sweep shortens nEp, and handing the solver a
            % longer one would fail its shape check.
            if isempty(ov) || ~isstruct(ov) || ~isfield(ov,'rhoObs'); ov = []; return; end
            if size(ov.rhoObs,3) >= n
                ov.rhoObs = ov.rhoObs(:,:,1:n);
            else
                ov = [];
            end
        end

        function relCut = truncate_(rel, n)
            % truncate_  A prefix of the arc. Only solvedPos and time_s matter to the solver;
            % revgnss.TruthEndpointReplay interpolates the truth onto whatever grid it is given,
            % so a shorter tVec is all that is needed to shorten the arc.
            relCut = rel;
            relCut.solvedPos = rel.solvedPos(:,:,1:n);
            relCut.time_s    = rel.time_s(1:n);
        end

        function [relInj, thTrue, dpRms] = inject_(rel, rotDeg, shapeM, frame, seed)
            % inject_  Perturb the ESTIMATE, never the truth. The observable is rebuilt from the
            % recorded truth inside the solver, so displacing solvedPos by a known rotation and a
            % known shape error gives the solver an exactly-known error to undo. That is what
            % makes this a recovery test rather than a self-consistency test.
            S = revgnss.ShapeFrameSeparationProbe;
            P = rel.solvedPos; N = size(P,2); nEp = size(P,3);
            rs = RandStream('mt19937ar','Seed',seed);

            % Rotation about a fixed, reproducible axis.
            axis = [1;2;3]; axis = axis/norm(axis);
            thTrue = axis * (rotDeg*pi/180);
            Rth = S.rot_(thTrue);

            % Shape error: a random displacement projected onto the SHAPE subspace, so it carries
            % no translation and no rotation of its own -- otherwise the "shape" error would
            % contain a rotation and the experiment would be circular.
            k0 = find(squeeze(all(all(isfinite(P),1),2)), 1);
            if isempty(k0); k0 = 1; end
            B = S.shapeBasis_(P(:,:,k0), N);
            v = randn(rs, size(B,2), 1);
            dp = B*v;
            dp = dp / sqrt(mean(sum(reshape(dp,3,N).^2,1))) * shapeM;
            dpRms = sqrt(mean(sum(reshape(dp,3,N).^2,1)));

            bodyFrame = strcmpi(frame,'formationbody');
            Q0 = P(:,:,k0) - mean(P(:,:,k0),2);
            relInj = rel;
            for k = 1:nEp
                Pk = P(:,:,k);
                if any(~isfinite(Pk(:))); continue; end
                c = mean(Pk,2);
                if bodyFrame
                    Qk = Pk - c;
                    [U,~,V] = svd(Qk*Q0.');
                    D = eye(3); D(3,3) = sign(det(U*V.'));
                    Rk = U*D*V.';
                    dpk = S.blockRotate_(Rk, dp, N);
                else
                    dpk = dp;
                end
                relInj.solvedPos(:,:,k) = c + Rth*(Pk - c) + reshape(dpk,3,N);
            end
        end

        function v = verdict_(rows)
            % verdict_  Reduce the table to the one sentence the plan asks for. The comparison
            % that matters is MATCHED versus MISMATCHED parameterisation: if a solver in the
            % wrong frame recovers the rotation just as well, the frame was never the mechanism.
            v = 'inconclusive';
            if isempty(rows); return; end
            full = rows([rows.arcFraction] == max([rows.arcFraction]));
            if isempty(full); return; end
            matched = []; mismatched = [];
            for i = 1:numel(full)
                same = strcmpi(full(i).solverFrame, full(i).injectFrame);
                if same
                    matched(end+1) = full(i).rotationErrAfter_deg;              %#ok<AGROW>
                else
                    mismatched(end+1) = full(i).rotationErrAfter_deg;           %#ok<AGROW>
                end
            end
            if isempty(matched) || isempty(mismatched); return; end
            m = median(matched); x = median(mismatched);
            if x > 3*max(m, eps)
                v = sprintf(['THE FRAME MATTERS: a mismatched parameterisation leaves %.4g deg ' ...
                    'of rotation error against %.4g deg when matched (%.1fx). The separation ' ...
                    'mechanism is real but the shape frame must be modelled correctly.'], ...
                    x, m, x/max(m,eps));
            elseif m > 3*max(x, eps)
                v = sprintf(['UNEXPECTED: the mismatched parameterisation did BETTER (%.4g vs ' ...
                    '%.4g deg). Treat the whole table as suspect and check the injection.'], x, m);
            else
                v = sprintf(['THE FRAME DOES NOT MATTER at this arc length: matched %.4g deg vs ' ...
                    'mismatched %.4g deg. Either the arc separates so well that the ' ...
                    'parameterisation is irrelevant, or it separates so badly that neither ' ...
                    'recovers anything -- read the penalty column before concluding.'], m, x);
            end
        end

        function B = shapeBasis_(Pk, N)
            q = Pk - mean(Pk,2);
            G = zeros(3*N,3); T = repmat(eye(3), N, 1);
            for i = 1:N
                G(3*(i-1)+(1:3),:) = ...
                    -[0 -q(3,i) q(2,i); q(3,i) 0 -q(1,i); -q(2,i) q(1,i) 0];
            end
            B = null([G, T].');
        end

        function w = blockRotate_(Rk, v, N)
            w = zeros(size(v));
            for i = 1:N
                idx = 3*(i-1)+(1:3);
                w(idx) = Rk*v(idx);
            end
        end

        function R = rot_(th)
            t = norm(th);
            if t < 1e-14; R = eye(3); return; end
            k = th/t; K = [0 -k(3) k(2); k(3) 0 -k(1); -k(2) k(1) 0];
            R = eye(3) + sin(t)*K + (1-cos(t))*(K*K);
        end

        function v = safeDiv_(a, b)
            if b == 0; v = NaN; else; v = a/b; end
        end
    end
end
