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
    %   * one ARC-CONSTANT shape correction dp, restricted to the shape subspace and carrying
    %     the ISL prior
    %   * one ARC-CONSTANT rotation dtheta, carrying no prior at all, because inter-satellite
    %     ranging supplies exactly zero information about it
    %
    % BOTH PARAMETERS ARE ARC-CONSTANT, AND THAT IS THE WHOLE POINT. The first version of this
    % class made the shape correction PER EPOCH. It still leaked -- 0.10 m of shape error produced
    % 0.049 deg of rotation, 3.72 m produced 0.479 deg -- because a per-epoch parameter tells the
    % estimator that the shape error is INDEPENDENT each epoch, so marginalising over 3601 epochs
    % appears to average it away. It does not: the shape error is the SAME every epoch. That
    % arc-correlation is precisely the property that makes it leak, and modelling it as
    % independent hands the correlated part straight to the rotation.
    %
    % WHAT SEPARATES THEM, AND THE OPEN QUESTION UNDER IT. An arc-constant shape offset and an
    % arc-constant rotation are told apart only because the two enter the design matrix with
    % DIFFERENT epoch dependence. The rotation generator G_k is built from the formation geometry
    % at epoch k, so it turns through the orbit; a shape offset expressed in ECEF does not. Over
    % 3600 s the formation turns 15 deg (weak); over 6 h, 90 deg (strong). Arc length is not a
    % tuning knob here, it is the mechanism.
    %
    % BUT WHICH FRAME IS THE SHAPE ERROR CONSTANT IN? A physical deformation is fixed in the
    % BODY/LVLH frame, so in ECEF it turns WITH the formation -- the exact opposite of the
    % assumption above, and if it turns the same way the rotation generator does, the separation
    % mechanism is a parameterisation artefact. shapeFrame makes that testable rather than
    % assumed:
    %   'ecef'          dp is one ECEF vector, applied identically at every epoch (legacy)
    %   'formationBody' dp is a BODY-frame vector; dp_ecef(k) = R_k * dp_body, with R_k the
    %                   rigid rotation the formation itself has undergone between the reference
    %                   epoch and epoch k, recovered by Kabsch from the SOLVED geometry (no truth,
    %                   no velocity, no orbit model)
    % revgnss.ShapeFrameSeparationProbe measures the separation penalty under both, which is
    % execution-plan item A4 -- the cheapest thing that can invalidate the turn-angle law, and
    % therefore the case for long arcs, and therefore Phase H.
    %
    % HOW THE NORMAL EQUATIONS ARE BUILT (execution-plan Phase D):
    %   * parameters are [alpha ; theta'] where dp = B*alpha over an ORTHONORMAL shape basis and
    %     theta' = Lrot*theta is the rotation expressed as METRES OF RIM DISPLACEMENT. Both blocks
    %     are then in the same unit, which is what makes one rank tolerance meaningful at all --
    %     mixing radians with metres is what made the old truncated pseudo-inverse hazardous.
    %   * the double-difference covariance is the real R_DD = D*R*D', not a diagonal 4*sigma^2:
    %     two DDs sharing a reference satellite or a reference tower are correlated, and the
    %     structure matrix D says by how much.
    %   * the prior enters as information on alpha, from the ISL layer's OWN formal covariance.
    %     Never from truth (execution-plan Phase E). An unset prior is a hard failure, not a
    %     silent fallback.
    %   * the solve is a Cholesky factorisation, and the rotation is judged by an ABSOLUTE SNR
    %     test on the SCHUR COMPLEMENT -- the only matrix that knows the separation penalty.
    %     rcond cannot do this job: it is scale-free and passes by ten orders either way, while
    %     the raw rotation block overstates information by 288x on the weakest axis.
    %   * NOTHING is written back until the solve has argued for itself (execution-plan C1).
    %
    %   out = revgnss.JointGeometrySolver.solve(cfg, results, rel)
    %       out.applicable      false when the gate is off or a guard fails (reason recorded)
    %       out.accepted        false when the solve ran but its step was refused (C1)
    %       out.solvedPos       [3 x N x nEp] geometry after the joint correction
    %       out.theta_rad       [3 x 1] global rotation correction
    %       out.thetaSigma_rad  [3 x 1] formal 1-sigma, from the Schur-reduced 3x3
    %       out.shapeStep_m     RMS size of the arc-constant shape correction actually applied
    %       out.observableShapeDof  how many of the 3N-6 shape DOF the ground DD really constrains

    properties (Constant, Access = private)
        GN_ITERS   = 3;
        MIN_TOWERS = 2;
    end

    methods (Static)

        function o = emptyOut()
            % emptyOut  The output contract, so callers can pre-declare it.
            o = revgnss.JointGeometrySolver.emptyOut_();
        end

        function [acceptShape, acceptRotation] = acceptance(rotationPassed, shapePassed, nDof)
            % acceptance  Which blocks may be written back, given the two guard verdicts.
            %
            % SEPARATE AND PUBLIC BECAUSE THE INVARIANT IS THE WHOLE POINT, and because it was
            % wrong once. The two guards are NOT independent switches: a rotation may only be
            % applied alongside an accepted shape.
            %
            % Measured at N = 4 over 300 s with the blocks treated independently: the solve
            % returned a 31 m shape step and an 8.66 deg rotation whose formal sigma was
            % 0.21 deg. The rotation guard passed by 1260 % on an SNR of 40.8 while the shape
            % guard failed by 1683 %, so the rotation was applied alone and moved the geometry by
            % 171 m. It was never a standalone estimate -- it was the partner of a shape step the
            % estimator itself rejects, and the two only fitted the data together. Applying half
            % of a jointly-estimated pair is not the conservative choice, it is an incoherent one.
            %
            % There is also no safe fallback for the rotation on its own: a rotation-only solve
            % IS revgnss.GroundDifferencedRotationSolver, which is measured to leak shape into
            % rotation at 0.30 deg per metre and is the estimator this class exists to replace.
            %
            %   shape rejected  -> nothing is applied
            %   shape accepted, rotation rejected -> shape only, from a rotation-CONSTRAINED
            %                                       re-solve (the caller does that part)
            %   both accepted   -> both
            acceptShape    = logical(shapePassed) && nDof >= 1;
            acceptRotation = logical(rotationPassed) && acceptShape;
        end

        function out = solve(cfg, results, rel, observableOverride)
            % solve  The joint shape+rotation estimate.
            %
            % observableOverride (optional) replaces the CODE double difference with another
            % per-link range of the same shape -- in practice the wide-lane or L1 carrier with
            % its integer removed, which is execution-plan F8 and the reason all of Phase F
            % exists. It must supply .rhoObs [N x nTw x nEp] and .rawSigma_m; everything else
            % (geometry, visibility, towers, lever arms, Jacobians, whitening, rank analysis,
            % acceptance) is unchanged, because the observable is the only thing that differs.
            % Carrier is ~500x more precise than the code that capped the gain at 1.53x, so
            % nothing else needs to change for the payoff to appear.
            J = revgnss.JointGeometrySolver;
            out = J.emptyOut_();
            if nargin < 4; observableOverride = []; end
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

            % --- ISL shape prior (execution-plan E1) -----------------------------------------
            % Resolved FIRST. A missing prior is a configuration fault, and reporting it before
            % spending an arc's worth of work on the observable is both faster and clearer.
            [sigPrior, priorSource, priorPerCoord] = J.shapePrior_(cfg, rel, N);
            if isempty(sigPrior)
                out.reason = ['noShapePrior: set multiAsset.jointGeometry.shapePriorSigma_m, ' ...
                    'or run the ISL shape layer so its formal covariance is published. ' ...
                    'There is deliberately no truth fallback.'];
                return
            end
            out.shapePriorSigma_m = sigPrior;
            out.shapePriorSource  = priorSource;

            % One physics path, shared with the 3-parameter solver.
            obs = revgnss.GroundDifferencedRotationSolver.buildObservable(cfg, results, tVec, N);
            if ~obs.ok; out.reason = obs.reason; return; end
            out.leverArmMode           = obs.leverArmMode;
            out.leverArmDdSystematic_m = obs.leverArmDdSystematic_m;

            % F8: swap the observable, keep everything else. The override carries its own raw
            % sigma, which is what makes the reported covariance correct rather than merely
            % smaller -- a carrier observable weighted at code sigma would look no better.
            out.observable = 'code';
            if isstruct(observableOverride) && isfield(observableOverride,'rhoObs') && ...
                    ~isempty(observableOverride.rhoObs)
                if ~isequal(size(observableOverride.rhoObs), size(obs.rhoObs))
                    out.reason = 'observableOverrideShapeMismatch'; return
                end
                obs.rhoObs = observableOverride.rhoObs;
                obs.codeSigma_m = observableOverride.rawSigma_m;
                obs.multipathSigma_m = 0;              % carrier multipath is mm-class
                obs.differentialAtmosphereSigma_m = 0; % removed by the lane combination
                out.observable = 'fixedCarrier';
                if isfield(observableOverride,'name'); out.observable = observableOverride.name; end
            end

            % --- Parameterisation ------------------------------------------------------------
            P = rel.solvedPos;
            [Pref, kRef] = J.firstFiniteEpoch_(P);
            if isempty(Pref); out.reason = 'noFiniteEpochForShapeProjector'; return; end
            out.shapeProjectorEpoch = kRef;

            shapeFrame = lower(J.getStr_(cfg, {'multiAsset','jointGeometry','shapeFrame'}, 'ecef'));
            if ~ismember(shapeFrame, {'ecef','formationbody'})
                out.reason = sprintf('unknownShapeFrame:%s', shapeFrame); return
            end
            out.shapeFrame = shapeFrame;

            B0 = J.shapeBasis_(Pref, N);
            if isempty(B0); out.reason = 'degenerateShapeSubspace'; return; end

            % Unit equilibration (D1): theta' = Lrot*theta is the rim displacement in METRES a
            % unit rotation produces, so the shape and rotation blocks share one unit.
            % Lrot = sqrt(2/3)*R_rms for an isotropic rotation axis.
            q0   = Pref - mean(Pref,2);
            Rrms = sqrt(mean(sum(q0.^2,1)));
            Lrot = sqrt(2/3)*Rrms;
            if ~isfinite(Lrot) || Lrot <= 0; out.reason = 'degenerateFormationRadius'; return; end
            out.rotationLever_m = Lrot;
            out.formationRrms_m = Rrms;

            % The formation's own turn. Governs separability, and supplies the 'formationBody'
            % frame for A4.
            [Rk, turnDeg] = J.formationRotations_(P, kRef);
            out.turnAngle_deg = turnDeg;
            out.separable = turnDeg >= J.getNum_(cfg, ...
                {'multiAsset','jointGeometry','minTurnAngle_deg'}, 30);

            % --- Measurement covariance ------------------------------------------------------
            dt    = max(1e-9, median(diff(tVec)));
            tauMp = max(dt, J.getNum_(cfg, {'errors','multipath','coloredGM','tau_s'}, 60));
            % Variance of ONE RAW tower->satellite range. Multipath is coloured, so its
            % contribution to an ARC average is sigma*sqrt(tau/dt), not sigma -- charge it there.
            varRaw = obs.codeSigma_m^2 ...
                   + obs.multipathSigma_m^2*(tauMp/dt) ...
                   + obs.differentialAtmosphereSigma_m^2;
            varRaw = max(varRaw, eps);
            out.ddSigma_m = 2*sqrt(varRaw);      % a DD combines four raw ranges

            ctx = struct('obs', obs, 'N', N, 'nEp', nEp, 'Lrot', Lrot, 'Rk', Rk, ...
                'shapeFrame', shapeFrame, 'varRaw', varRaw, 'minTowers', J.MIN_TOWERS, ...
                'cache', containers.Map('KeyType','char','ValueType','any'));

            % --- Pre-pass: measure the observable shape subspace, THEN choose the basis -------
            % C2/C3. run20 is a RANK problem, not a weight problem: it reduced its own fitted DD
            % residual by 1.74x while making the true shape 2.9x worse -- the signature of
            % unobservable directions, not of a badly-chosen prior. Regularising 12 DOF with one
            % scalar cannot fix that; measuring which of the 12 the data actually sees, and
            % refusing to move the rest, can.
            acc = J.accumulate_(ctx, P, B0, zeros(size(B0,2),1), 0);
            if acc.nUsed < 1; out.reason = 'noUsableEpochs'; return; end
            nS0 = size(B0,2);
            SpriorFull = J.priorInformation_(B0, sigPrior, priorPerCoord);
            minGain = J.getNum_(cfg, {'multiAsset','jointGeometry','shapeSubspace','minGain'}, 1.1);
            diagn = J.shapeObservability_(acc.Nm(1:nS0,1:nS0), acc.Nm(1:nS0,nS0+(1:3)), ...
                acc.Nm(nS0+(1:3),nS0+(1:3)), SpriorFull, minGain);
            out.observableShapeDof = diagn.nObservable;
            out.shapeDofTotal      = nS0;
            out.shapeGainMedian    = diagn.gainMedian;
            out.shapeGainMin       = diagn.gainMin;
            out.shapeGainMax       = diagn.gainMax;
            out.shapeGain          = diagn.gain(:).';

            % The separation penalties belong HERE, on the FULL 3N-6 shape block, not after C3
            % has restricted it. "What would the rotation cost if the shape were free" is a
            % question about the ARC and the GEOMETRY; asking it of a basis that has already had
            % its unobservable directions removed answers a different question and gives ~1.0
            % every time, which would read as "this arc separates perfectly" on an arc that
            % separates nothing.
            [out.separationPenalty, out.separationPenaltyFree] = J.separationPenalty_( ...
                acc.Nm(nS0+(1:3),nS0+(1:3)), acc.Nm(1:nS0,1:nS0), ...
                acc.Nm(1:nS0,nS0+(1:3)), SpriorFull);

            if J.getBool_(cfg, {'multiAsset','jointGeometry','shapeSubspace','enable'}, true)
                B = B0 * diagn.V(:, diagn.observable);   % V orthonormal -> B stays orthonormal
            else
                B = B0;
            end
            nS = size(B,2);
            Sprior = J.priorInformation_(B, sigPrior, priorPerCoord);

            % --- Gauss-Newton ----------------------------------------------------------------
            % The working copy the iteration produced is deliberately discarded: what gets
            % published is rebuilt from the ORIGINAL geometry with only the ACCEPTED blocks.
            [alphaTot, Rtot, acc, ~, gnOk] = J.gaussNewton_(ctx, rel.solvedPos, B, Sprior, Lrot, true);
            if ~gnOk; out.reason = 'normalMatrixNotPositiveDefinite'; return; end
            theta = J.rotVec_(Rtot);

            % --- Statistics -------------------------------------------------------------------
            dof = max(1, acc.nRow - (nS+3));
            s2  = acc.sse/dof;                          % dimensionless variance factor
            Naa = acc.Nm(1:nS,1:nS) + Sprior;
            Nat = acc.Nm(1:nS,nS+(1:3));
            Ntt = acc.Nm(nS+(1:3),nS+(1:3));

            % D3: the SCHUR COMPLEMENT is the only matrix that knows the separation penalty. Its
            % inverse is the rotation covariance AFTER the shape has been allowed to move, which
            % is what the turn-angle law is about.
            [Saa, okS] = J.cholSolve_(Naa, Nat);
            if ~okS; out.reason = 'shapeBlockNotPositiveDefinite'; return; end
            Schur = (Ntt - Nat.'*Saa);
            Schur = (Schur+Schur.')/2;
            Cth   = s2 * J.symInv_(Schur);              % theta' units: metres^2 of rim
            sigThetaPrime = sqrt(abs(diag(Cth)));
            dpTot = B*alphaTot;

            out.applicable         = true;
            out.reason             = 'ok';
            out.theta_rad          = theta;
            out.thetaSigma_rad     = sigThetaPrime/Lrot;
            out.nEpochsUsed        = acc.nUsed;
            out.nObs               = acc.nRow;
            out.shapeStep_m        = sqrt(mean(vecnorm(reshape(dpTot,3,N),2,1).^2));
            out.condition          = cond(Naa);
            out.varianceFactor     = s2;
            out.rotationSigmaRim_m = sigThetaPrime;
            % POSTERIOR shape sigma, per point, after this observable has been applied. The
            % cascade in revgnss.GroundCarrierAmbiguityResolver needs it: the L1 float ambiguity
            % is estimated against the CONDITIONED geometry, so charging it the ISL layer's prior
            % sigma would keep refusing L1 on a geometry the wide lane had already sharpened.
            % Directions C3 declined to move retain the prior exactly, which is what they are
            % worth, so they are added back at sigPrior rather than quietly dropped.
            trShape = s2*trace(J.symInv_(Naa)) + max(0, nS0-nS)*sigPrior^2;
            out.shapeSigmaPosterior_m = sqrt(max(trShape,0)/N);

            % --- C1 + D3 acceptance -----------------------------------------------------------
            % run20 applied a 0.368 m shape step against a 0.0736 m error and shipped it, because
            % the only test was 'the solver ran'. Two absolute tests replace that -- and they are
            % judged SEPARATELY, because they answer different questions.
            %
            % WHY THE TWO BLOCKS ARE ACCEPTED INDEPENDENTLY. The rotation test asks whether the
            % measured orientation correction is distinguishable from zero; on a short arc it
            % rightly says no. But the SHAPE correction is not conditional on that. Rejecting the
            % whole step because the rotation is insignificant would throw away a shape
            % improvement that has its own, separate justification -- and it would break the
            % Phase F cascade at its most important link, where a fixed wide lane sharpens the
            % geometry so L1 can be searched, on arcs far too short to see a rotation.
            thetaRim = Lrot*theta;
            out.rotationSnr    = abs(thetaRim) ./ max(sigThetaPrime, realmin);
            out.rotationSnrMin = norm(thetaRim)/max(norm(sigThetaPrime), realmin);
            minSnr   = J.getNum_(cfg, {'multiAsset','jointGeometry','accept','minRotationSnr'}, 3);
            maxStepK = J.getNum_(cfg, {'multiAsset','jointGeometry','accept','maxShapeStepSigma'}, 3);

            % A5: three-way, with a dead-band. Both of these decide whether a metre-class
            % correction reaches the geometry, and a hard comparison at a few per cent margin is
            % a coin flip that a 1e-14 arithmetic difference between a serial and a parallel run
            % can win -- measured on the sibling solver's leakage guard, where it moved 33 of 148
            % reported fields. A near-threshold result is reported as INDETERMINATE and takes the
            % conservative branch, deterministically.
            deadBand = revgnss.GuardDecision.deadBandFor(cfg, ...
                {'multiAsset','jointGeometry','guardDeadBand'}, []);
            rotGuard = revgnss.GuardDecision.evaluate(out.rotationSnrMin, minSnr, 'ge', deadBand);
            shpGuard = revgnss.GuardDecision.evaluate(out.shapeStep_m, maxStepK*sigPrior, 'le', deadBand);
            out.rotationGuard = rotGuard;
            out.shapeGuard    = shpGuard;

            % HALF OF A JOINTLY-ESTIMATED PAIR IS NOT A CONSERVATIVE ANSWER. Measured at N = 4
            % over 300 s: the solve returned a 31 m shape step and an 8.66 deg rotation whose
            % formal sigma was 0.21 deg -- SNR 40.8, so the rotation guard passed by 1260 % while
            % the shape guard failed by 1683 %. Applying the rotation alone moved the geometry by
            % 171 m. The rotation was never a standalone estimate: it was the partner of a shape
            % step the estimator itself rejects, and the pair only fitted the data together.
            %
            % So the two guards are NOT independent switches:
            %   * shape REJECTED -> reject everything. The only way to apply the rotation without
            %     a shape correction is to fall back to a rotation-only solve, and that is
            %     revgnss.GroundDifferencedRotationSolver -- the estimator this class exists to
            %     replace, measured to leak at 0.30 deg per metre.
            %   * shape ACCEPTED, rotation REJECTED -> re-solve with the rotation CONSTRAINED to
            %     zero and apply that. Not the marginal shape estimate: the blocks are
            %     correlated, so the shape that is right when theta = 0 is not the shape that was
            %     fitted alongside a free theta. This is the branch the Phase F cascade needs,
            %     where a fixed wide lane sharpens the geometry on arcs far too short to see a
            %     rotation.
            %   * both accepted -> apply the joint solution as computed.
            [out.acceptedShape, out.acceptedRotation] = ...
                J.acceptance(rotGuard.pass, shpGuard.pass, out.observableShapeDof);
            out.accepted = out.acceptedShape;

            coupling = '';
            if rotGuard.pass && ~out.acceptedShape
                coupling = [' || ROTATION DISCARDED WITH THE SHAPE: it was the partner of a ' ...
                    'rejected shape step, not a standalone estimate; applying it alone would ' ...
                    'reduce this to the 3-parameter solver the joint solve replaces'];
            end
            out.acceptReason = sprintf(['rotation %s (%s; |theta| = %.4g m of rim, formal ' ...
                '%.4g m, arc turned %.1f deg) | shape %s (%s; %.4g m step against a %.4g m ' ...
                'prior, %d/%d DOF observable)%s'], ...
                rotGuard.outcome, rotGuard.text, norm(thetaRim), norm(sigThetaPrime), turnDeg, ...
                shpGuard.outcome, shpGuard.text, out.shapeStep_m, sigPrior, ...
                out.observableShapeDof, out.shapeDofTotal, coupling);

            if ~out.acceptedShape
                out.solvedPos = rel.solvedPos;              % leave the geometry exactly as found
            elseif out.acceptedRotation
                out.solvedPos = J.applyTotal_(ctx, rel.solvedPos, B, alphaTot, Rtot);
            else
                % Re-solve with theta constrained to zero, then re-test the shape guard on the
                % CONSTRAINED step -- it is a different number from the marginal one, and it is
                % the one actually being applied.
                [aC, ~, ~, ~, okC] = J.gaussNewton_(ctx, rel.solvedPos, B, Sprior, Lrot, false);
                if ~okC
                    out.acceptedShape = false; out.accepted = false;
                    out.acceptReason = [out.acceptReason ' || constrained re-solve failed'];
                    out.solvedPos = rel.solvedPos; return
                end
                dpC = B*aC;
                stepC = sqrt(mean(vecnorm(reshape(dpC,3,N),2,1).^2));
                gC = revgnss.GuardDecision.evaluate(stepC, maxStepK*sigPrior, 'le', deadBand);
                out.shapeStepConstrained_m = stepC;
                out.shapeGuardConstrained  = gC;
                if ~gC.pass
                    out.acceptedShape = false; out.accepted = false;
                    out.acceptReason = sprintf('%s || constrained shape %s (%s)', ...
                        out.acceptReason, gC.outcome, gC.text);
                    out.solvedPos = rel.solvedPos;
                else
                    out.shapeStep_m = stepC;
                    out.solvedPos = J.applyTotal_(ctx, rel.solvedPos, B, aC, eye(3));
                    out.acceptReason = sprintf(['%s || shape APPLIED from a rotation-constrained ' ...
                        're-solve (%.4g m), not from the marginal joint estimate'], ...
                        out.acceptReason, stepC);
                end
            end
        end
    end

    methods (Static, Access = private)

        function o = emptyOut_()
            o = struct('applicable', false, 'reason', 'notAttempted', 'solvedPos', [], ...
                'theta_rad', [0;0;0], 'thetaSigma_rad', [NaN;NaN;NaN], ...
                'nEpochsUsed', 0, 'nObs', 0, 'shapeStep_m', NaN, 'condition', NaN, ...
                'shapePriorSigma_m', NaN, 'ddSigma_m', NaN, 'shapeProjectorEpoch', 0, ...
                'shapePriorSource', 'notAttempted', 'leverArmMode', 'none', ...
                'leverArmDdSystematic_m', NaN, 'shapeFrame', 'ecef', ...
                'observableShapeDof', NaN, 'shapeDofTotal', NaN, 'shapeGain', [], ...
                'shapeGainMedian', NaN, 'shapeGainMin', NaN, 'shapeGainMax', NaN, ...
                'rotationSnr', [NaN;NaN;NaN], 'rotationSnrMin', NaN, ...
                'rotationSigmaRim_m', [NaN;NaN;NaN], 'separationPenalty', NaN, ...
                'separationPenaltyFree', NaN, ...
                'rotationLever_m', NaN, 'formationRrms_m', NaN, 'varianceFactor', NaN, ...
                'accepted', false, 'acceptedRotation', false, 'acceptedShape', false, ...
                'rotationGuard', struct('outcome','notAttempted'), ...
                'shapeGuard', struct('outcome','notAttempted'), ...
                'shapeGuardConstrained', struct('outcome','notAttempted'), ...
                'shapeStepConstrained_m', NaN, ...
                'acceptReason', 'notAttempted', ...
                'turnAngle_deg', NaN, 'separable', false, 'observable', 'code', ...
                'shapeSigmaPosterior_m', NaN);
        end

        % ---- accumulation ----------------------------------------------------------------

        function [alphaTot, Rtot, acc, P, ok] = gaussNewton_(ctx, P0, B, Sprior, Lrot, useRotation)
            % gaussNewton_  The iteration, with the rotation block optionally CONSTRAINED TO ZERO.
            %
            % The constrained mode is not a convenience -- it is what makes a partial acceptance
            % coherent. See acceptance below: applying the marginal shape estimate while setting
            % the rotation to zero is not the same thing as solving with the rotation held at
            % zero, because the two blocks are correlated. Applying half of a jointly-estimated
            % pair injects the half that was only ever meaningful in combination with the other.
            J = revgnss.JointGeometrySolver;
            nS = size(B,2);
            np = nS + 3*double(useRotation);
            Rtot = eye(3); alphaTot = zeros(nS,1); P = P0; ok = true;
            acc = struct('Nm', zeros(nS+3), 'bv', zeros(nS+3,1), 'sse', 0, 'nRow', 0, 'nUsed', 0);
            for iter = 1:J.GN_ITERS
                acc = J.accumulate_(ctx, P, B, alphaTot, 1);
                if acc.nUsed < 1; ok = false; return; end
                Nfull = acc.Nm(1:np, 1:np);
                Nfull(1:nS,1:nS) = Nfull(1:nS,1:nS) + Sprior;
                bv = acc.bv(1:np);
                % D2: the prior restrains the ACCUMULATED correction, not this iteration's step.
                % Without this term the iteration converges toward the UNREGULARISED least
                % squares (x_n = (1-rho^n)*x_LS): the effective prior sigma is inflated, not
                % shrunk. At present settings that is a 0.03 % effect; fixed for correctness.
                bv(1:nS) = bv(1:nS) - Sprior*alphaTot;

                [dx, okChol] = J.cholSolve_(Nfull, bv);
                if ~okChol; ok = false; return; end
                dAlpha = dx(1:nS);
                if useRotation
                    dth = dx(nS+(1:3))/Lrot;           % back to radians
                else
                    dth = [0;0;0];
                end
                alphaTot = alphaTot + dAlpha;
                Rtot     = J.rot_(dth)*Rtot;
                P = J.applyStep_(ctx, P, B, dAlpha, dth);
            end
        end

        function acc = accumulate_(ctx, P, B, alphaTot, wantResidual) %#ok<INUSD>
            % accumulate_  One pass over the arc: build the whitened normal equations for
            % [alpha ; theta'] at the current geometry P. Shared by the C2 pre-pass and every
            % Gauss-Newton iteration so there is exactly one place the rows are formed.
            J   = revgnss.JointGeometrySolver;
            obs = ctx.obs; N = ctx.N; nS = size(B,2); np = nS + 3;
            acc = struct('Nm', zeros(np), 'bv', zeros(np,1), 'sse', 0, 'nRow', 0, 'nUsed', 0);
            bodyFrame = strcmp(ctx.shapeFrame,'formationbody');
            for k = 1:ctx.nEp
                okTw = find(obs.visTw(:,k)).';
                if numel(okTw) < ctx.minTowers; continue; end
                Pk = P(:,:,k);
                if any(~isfinite(Pk(:))); continue; end
                q = Pk - mean(Pk,2);

                % Rotation generator at THIS epoch: dp_i = dtheta x q_i = -skew(q_i)*dtheta,
                % divided by Lrot because the parameter is theta' = Lrot*theta.
                G = zeros(3*N,3);
                for i = 1:N
                    G(3*(i-1)+(1:3),:) = -J.skew_(q(:,i))/ctx.Lrot;
                end
                if bodyFrame
                    Bk = J.rotateBasis_(B, ctx.Rk(:,:,k), N);
                else
                    Bk = B;
                end

                Apos = revgnss.GroundDifferencedRotationSolver.predictedAntenna(obs, Pk, k);
                nT = numel(okTw);
                u = zeros(3,N,nT); rhoP = zeros(N,nT);
                for mm = 1:nT
                    for i = 1:N
                        d = Apos(:,i) - obs.towerPos(:,okTw(mm));
                        rhoP(i,mm) = norm(d); u(:,i,mm) = d/rhoP(i,mm);
                    end
                end

                [Jp, r, nDD] = J.buildEpochRows_(obs, u, rhoP, okTw, N, k);
                if nDD < 1; continue; end

                % D4: whiten with the REAL DD covariance R_DD = D*R*D'. Cached on the visible
                % tower set, which changes at most a handful of times over an arc.
                Lw = J.ddWhitener_(ctx.cache, okTw, N, ctx.varRaw);
                Aw = Lw \ [Jp*Bk, Jp*G];
                rw = Lw \ r;

                acc.Nm  = acc.Nm + (Aw.'*Aw);
                acc.bv  = acc.bv + (Aw.'*rw);
                % B2 -- UNITS. sse used to accumulate the UNWEIGHTED sum of squares while the
                % normal matrix carried the weight, and the two were combined as
                % C = (sse/dof)*inv(Nm), leaving C wrong by exactly varDD. At a 1 m code sigma
                % that was CONSERVATIVE so nobody noticed; below a 0.5 m DD sigma it FLIPS
                % OPTIMISTIC -- precisely the regime carrier phase moves this work into. The
                % variance factor must be the WEIGHTED residual sum, so s0^2 = r'Wr/dof is the
                % dimensionless ratio of actual to assumed variance.
                acc.sse = acc.sse + (rw.'*rw);
                acc.nRow = acc.nRow + nDD; acc.nUsed = acc.nUsed + 1;
            end
        end

        function P = applyTotal_(ctx, P0, B, alphaTot, Rtot)
            % applyTotal_  The ACCEPTED correction, applied once to the original geometry.
            % Separate from applyStep_ because the Gauss-Newton working copy always carries both
            % blocks, while the published geometry carries only the ones that passed.
            J = revgnss.JointGeometrySolver;
            N = ctx.N; P = P0;
            bodyFrame = strcmp(ctx.shapeFrame,'formationbody');
            dpEcef = B*alphaTot;
            for k = 1:ctx.nEp
                Pk = P0(:,:,k);
                if any(~isfinite(Pk(:))); continue; end
                if bodyFrame
                    dpk = J.rotateBasis_(B, ctx.Rk(:,:,k), N)*alphaTot;
                else
                    dpk = dpEcef;
                end
                c = mean(Pk,2);
                P(:,:,k) = c + Rtot*(Pk - c) + reshape(dpk,3,N);
            end
        end

        function v = rotVec_(R)
            % rotVec_  Rotation vector of a rotation matrix (inverse of rot_).
            t = acos(max(-1, min(1, (trace(R)-1)/2)));
            if t < 1e-14; v = [0;0;0]; return; end
            v = t/(2*sin(t)) * [R(3,2)-R(2,3); R(1,3)-R(3,1); R(2,1)-R(1,2)];
        end

        function P = applyStep_(ctx, P, B, dAlpha, dth)
            % applyStep_  Rotate about each epoch's estimated centroid and add the shape step,
            % carried into the epoch's frame when the shape is parameterised in the body frame.
            J = revgnss.JointGeometrySolver;
            N = ctx.N;
            bodyFrame = strcmp(ctx.shapeFrame,'formationbody');
            Rth = J.rot_(dth);
            dpEcef = B*dAlpha;
            for k = 1:ctx.nEp
                Pk = P(:,:,k);
                if any(~isfinite(Pk(:))); continue; end
                if bodyFrame
                    dpk = J.rotateBasis_(B, ctx.Rk(:,:,k), N)*dAlpha;
                else
                    dpk = dpEcef;
                end
                c = mean(Pk,2);
                P(:,:,k) = c + Rth*(Pk - c) + reshape(dpk,3,N);
            end
        end

        % ---- prior ------------------------------------------------------------------------

        function [sig, source, perCoord] = shapePrior_(cfg, rel, N)
            % shapePrior_  The ISL layer's belief about its own shape error. TRUTH IS NOT A
            % CANDIDATE (execution-plan E1): the previous fallback read rel.shapeErrSolved_m,
            % which revgnss.SwarmRelativeSolver computes against truthK, so truth was setting
            % the weight that decides how far the ground data may move the geometry.
            J = revgnss.JointGeometrySolver;
            sig = []; source = ''; perCoord = [];
            v = J.getNum_(cfg, {'multiAsset','jointGeometry','shapePriorSigma_m'}, NaN);
            if isfinite(v) && v > 0
                sig = v; source = 'config';
            else
                % sqrt(3) converts a PER-AXIS sigma into the norm of a 3-vector displacement --
                % the same conversion revgnss.FederatedSwarmReport already applies.
                f = J.getNum_(rel, {'formalShapeSigma_m'}, NaN);
                if isfinite(f) && f > 0
                    sig = sqrt(3)*f; source = 'islFormalCovariance';
                end
            end
            if isempty(sig); return; end
            % C4: prefer the ANISOTROPIC per-coordinate covariance when the ISL layer publishes
            % it. The isotropic scalar was a stated simplification, not a modelling choice.
            if isstruct(rel) && isfield(rel,'shapeSigmaPerCoord_m') && ...
                    numel(rel.shapeSigmaPerCoord_m) == 3*N
                pc = rel.shapeSigmaPerCoord_m(:);
                if all(isfinite(pc)) && all(pc > 0)
                    % Renormalise so the per-point norm matches the scalar prior actually in
                    % force: the anisotropy is the information being added, not the level.
                    scale = sig / sqrt(mean(sum(reshape(pc,3,N).^2,1)));
                    perCoord = pc*scale; source = [source '+perCoordAnisotropy'];
                end
            end
        end

        function S = priorInformation_(B, sig, perCoord)
            % priorInformation_  Prior information on alpha. B is orthonormal, so an isotropic
            % prior is exactly (1/sig^2)*I; an anisotropic one is B'*inv(diag(s.^2))*B.
            if isempty(perCoord)
                S = eye(size(B,2))/sig^2;
            else
                S = B.' * diag(1./(perCoord.^2)) * B;
                S = (S+S.')/2;
            end
        end

        % ---- parameterisation --------------------------------------------------------------

        function [Pk, kRef] = firstFiniteEpoch_(P)
            % firstFiniteEpoch_  The earliest epoch whose geometry is entirely finite, or [].
            % B3: this used epoch 1 unconditionally while every other loop skipped non-finite
            % geometry, so a single NaN at epoch 1 -- exactly where a cold filter puts one --
            % turned the projector, the solve and everything downstream of solvedPos into NaN
            % with no error raised anywhere.
            Pk = []; kRef = 0;
            for k = 1:size(P,3)
                Q = P(:,:,k);
                if all(isfinite(Q(:))); Pk = Q; kRef = k; return; end
            end
        end

        function B = shapeBasis_(Pk, N)
            % shapeBasis_  Orthonormal basis of the 3N-6 SHAPE subspace: translation (3) and
            % rotation (3) removed, so the shape parameter cannot absorb the rotation it is
            % meant to be separated from.
            q = Pk - mean(Pk,2);
            G = zeros(3*N,3); T = repmat(eye(3), N, 1);
            for i = 1:N
                G(3*(i-1)+(1:3),:) = -revgnss.JointGeometrySolver.skew_(q(:,i));
            end
            B = null([G, T].');
            if isempty(B) || size(B,2) < 1; B = []; end
        end

        function Bk = rotateBasis_(B, Rk, N)
            % rotateBasis_  Carry a body-frame shape basis into ECEF at an epoch the formation
            % has turned to: blkdiag(Rk,...,Rk)*B. This is the 'formationBody' half of A4.
            % Orthonormality survives, because a block-diagonal rotation is orthogonal.
            Bk = zeros(size(B));
            for i = 1:N
                idx = 3*(i-1)+(1:3);
                Bk(idx,:) = Rk*B(idx,:);
            end
        end

        function [Rk, turnDeg] = formationRotations_(P, kRef)
            % formationRotations_  The rigid rotation the formation itself has undergone from the
            % reference epoch to each epoch, by Kabsch on the SOLVED geometry. Truth-free, and it
            % needs neither velocity nor an orbit model -- the formation's own turn is visible in
            % its own coordinates. Also returns the total turn over the arc, the variable that
            % governs shape/rotation separability (14.5x penalty at 7.5 deg, 1.0x at 360 deg).
            nEp = size(P,3);
            Rk = repmat(eye(3), 1, 1, nEp);
            Q0 = P(:,:,kRef) - mean(P(:,:,kRef),2);
            turnDeg = 0; last = eye(3);
            for k = 1:nEp
                Qk = P(:,:,k);
                if any(~isfinite(Qk(:))); Rk(:,:,k) = last; continue; end
                Qk = Qk - mean(Qk,2);
                [U,~,V] = svd(Qk*Q0.');
                D = eye(3); D(3,3) = sign(det(U*V.'));
                R = U*D*V.';
                Rk(:,:,k) = R; last = R;
                turnDeg = max(turnDeg, real(acosd(max(-1,min(1,(trace(R)-1)/2)))));
            end
        end

        % ---- rows and weighting ------------------------------------------------------------

        function [Jp, r, nDD] = buildEpochRows_(obs, u, rhoP, okTw, N, k)
            % buildEpochRows_  Double-difference residuals and their Jacobian w.r.t. the 3N
            % centre-of-mass coordinates, at one epoch. Reference tower = okTw(1), reference
            % satellite = 1, matching revgnss.GroundDifferencedRotationSolver exactly. Column
            % indices mm are POSITIONS IN okTw; obs.rhoObs is indexed by absolute tower number.
            nT = numel(okTw);
            Jp = zeros((nT-1)*(N-1), 3*N); r = zeros((nT-1)*(N-1),1); row = 0;
            rhoObs = obs.rhoObs; mr = okTw(1);
            for mm = 2:nT
                m = okTw(mm);
                for i = 2:N
                    row = row + 1;
                    r(row) = ((rhoObs(i,m,k)-rhoObs(1,m,k)) - (rhoObs(i,mr,k)-rhoObs(1,mr,k))) ...
                           - ((rhoP(i,mm)-rhoP(1,mm)) - (rhoP(i,1)-rhoP(1,1)));
                    Jp(row, 3*(i-1)+(1:3)) =  (u(:,i,mm) - u(:,i,1)).';
                    Jp(row, 1:3)           = -(u(:,1,mm) - u(:,1,1)).';
                end
            end
            nDD = row;
            Jp = Jp(1:row,:); r = r(1:row);
        end

        function Lw = ddWhitener_(cache, okTw, N, varRaw)
            % ddWhitener_  Lower Cholesky factor of the REAL double-difference covariance
            % R_DD = D*R*D' (D4). The previous diagonal 4*sigma^2 ignores that two DDs sharing a
            % reference satellite or a reference tower are correlated. Worth ~0.5 % of rotation
            % information and conservative on two axes of three, so low impact -- but it is
            % trivially correct and it is what the reported sigma claims to be.
            key = sprintf('%d_', okTw);
            if isKey(cache, key)
                Lw = cache(key)*sqrt(varRaw); return
            end
            nT = numel(okTw);
            nDD = (nT-1)*(N-1);
            D = zeros(nDD, N*nT); row = 0;
            idx = @(ii,mm) (mm-1)*N + ii;          % raw range rho(i, okTw(mm))
            for mm = 2:nT
                for i = 2:N
                    row = row + 1;
                    D(row, idx(i,mm)) =  1; D(row, idx(1,mm)) = -1;
                    D(row, idx(i,1))  = -1; D(row, idx(1,1))  =  1;
                end
            end
            Rdd = D*D.';
            [Lu, p] = chol(Rdd, 'lower');
            if p ~= 0
                Lu = chol(Rdd + 1e-9*(trace(Rdd)/nDD)*eye(nDD), 'lower');
            end
            cache(key) = Lu;
            Lw = Lu*sqrt(varRaw);
        end

        % ---- diagnostics and solving ---------------------------------------------------------

        function d = shapeObservability_(Naa, Nat, Ntt, Sprior, minGain)
            % shapeObservability_  C2: how many of the shape DOF does the ground DD actually
            % constrain, and by how much?
            %
            % The information the DD supplies about shape AFTER the rotation is free is the
            % Schur complement Naa - Nat*inv(Ntt)*Nta: a shape direction the rotation can mimic
            % is not constrained by these data no matter how large Naa looks. Gain is quoted
            % against the PRIOR -- gain_j = sigma_prior / sigma_posterior along eigen-direction
            % j -- so gain = 1 means the measurement said nothing and only the prior is holding
            % that direction. THIS is the number that explains run20, and it was unknown.
            %
            % The eigenvectors are taken of the SYMMETRIC information matrix itself, so V is
            % orthonormal and B*V stays an orthonormal basis; that is what keeps the isotropic
            % prior equal to a plain identity in the rotated basis.
            nS = size(Naa,1);
            d = struct('nObservable', 0, 'gainMedian', NaN, 'gainMin', NaN, 'gainMax', NaN, ...
                'observable', false(nS,1), 'V', eye(nS), 'gain', nan(nS,1));
            if rcond(Ntt) < eps
                M = Naa;
            else
                M = Naa - Nat*(Ntt\Nat.');
            end
            M = (M+M.')/2;
            [V, E] = eig(M);
            e = max(0, real(diag(E)));
            [e, ord] = sort(e, 'descend'); V = real(V(:,ord));
            % Prior information along each direction (identity*1/sig^2 in the isotropic case).
            pj = max(realmin, diag(V.'*Sprior*V));
            gain = sqrt(1 + e./pj);
            d.gain = gain; d.V = V;
            d.observable = gain >= minGain;
            d.nObservable = sum(d.observable);
            d.gainMedian = median(gain); d.gainMin = min(gain); d.gainMax = max(gain);
            if d.nObservable == 0
                % Keep the single best direction so the system stays well-posed and the refusal
                % is made by the acceptance guard, with a reason, rather than by an empty
                % parameter vector.
                d.observable(1) = true; d.nObservable = 1;
            end
        end

        function [pPrior, pFree] = separationPenalty_(Ntt, Naa, Nat, Sprior)
            % separationPenalty_  sigma_theta(shape co-estimated) / sigma_theta(shape known
            % exactly). TWO of them, because they answer two different questions and conflating
            % them is how the turn-angle table gets misquoted:
            %
            %   pPrior  the penalty THIS RUN ACTUALLY PAYS, with the ISL prior in force. A tight
            %           prior stops the shape moving, so this can sit near 1.0 even on an arc
            %           that separates nothing -- it says the PRIOR is holding the answer, not
            %           the data.
            %   pFree   the penalty with the shape entirely free. This is the published
            %           turn-angle law (14.5x at 7.5 deg of turn ... 1.0x at 360 deg) and it is
            %           the number that says whether the ARC can separate them at all. On a
            %           short arc the free shape block is singular, which is the honest answer:
            %           Inf, i.e. the arc cannot do it.
            %
            % Reporting only pPrior would let a tight prior masquerade as a separating arc,
            % which is exactly the confusion that produced the 1.53x headline.
            J = revgnss.JointGeometrySolver;
            pPrior = NaN; pFree = NaN;
            if rcond(Ntt) < eps; return; end
            a = sqrt(abs(diag(J.symInv_(Ntt))));
            good = a > 0;
            if ~any(good); return; end

            Sp = Ntt - Nat.'*((Naa + Sprior)\Nat);
            Sp = (Sp+Sp.')/2;
            if rcond(Sp) > eps
                b = sqrt(abs(diag(J.symInv_(Sp))));
                pPrior = max(b(good)./a(good));
            end

            % Shape free: use a pseudo-inverse, because the un-primed shape block is singular
            % precisely when the arc cannot separate the two -- and that is a result, not an
            % error condition.
            Sf = Ntt - Nat.'*(pinv(Naa)*Nat);
            Sf = (Sf+Sf.')/2;
            if rcond(Sf) > eps
                c = sqrt(abs(diag(J.symInv_(Sf))));
                pFree = max(c(good)./a(good));
            else
                pFree = Inf;
            end
        end

        function [x, ok] = cholSolve_(A, b)
            % cholSolve_  D1: a Cholesky solve, replacing the truncated pseudo-inverse. The
            % pseudo-inverse was needed only because the old parameterisation kept the rigid null
            % space inside the parameter vector and mixed radians with metres. With an
            % orthonormal shape basis, unit equilibration and a proper prior the matrix is
            % positive definite, and the factorisation either succeeds or names its failure
            % instead of silently truncating a direction that mattered.
            A = (A+A.')/2;
            [L, p] = chol(A, 'lower');
            if p ~= 0; x = zeros(size(b,1), size(b,2)); ok = false; return; end
            x = L.' \ (L \ b); ok = true;
        end

        function Ci = symInv_(A)
            A = (A+A.')/2;
            [L, p] = chol(A, 'lower');
            if p ~= 0; Ci = pinv(A); return; end
            Li = L \ eye(size(A,1));
            Ci = Li.'*Li;
        end

        function S = skew_(v)
            S = [0 -v(3) v(2); v(3) 0 -v(1); -v(2) v(1) 0];
        end

        function R = rot_(th)
            t = norm(th);
            if t < 1e-14; R = eye(3); return; end
            k = th/t; K = revgnss.JointGeometrySolver.skew_(k);
            R = eye(3) + sin(t)*K + (1-cos(t))*(K*K);
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

        function v = getStr_(cfg, path, dflt)
            v = dflt; c = cfg;
            for i = 1:numel(path)
                if ~isstruct(c) || ~isfield(c, path{i}); return; end
                c = c.(path{i});
            end
            if ~isempty(c) && (ischar(c) || isstring(c)); v = char(c); end
        end
    end
end
