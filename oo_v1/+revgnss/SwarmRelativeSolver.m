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
            % Relative-clock gate. The historical key multiAsset.twoWayTimeTransferISL.enable is
            % now HARD-BLOCKED by validateMasterConfig:legacySatelliteTimeTransfer in favour of
            % measurements.isl.twoWay.timeTransfer, which left this layer unreachable: the guard
            % refused the only key that could switch it on. Accept EITHER key so the sanctioned
            % path reaches the solver while every existing caller of the legacy key keeps working.
            % Only the .enable/.useInEKF keys are blocked -- the .sigma_m/.delayCal.* noise-model
            % parameters this solver reads in clockNoise_ are not, so they stay where they are.
            clockGateOn = revgnss.SwarmRelativeSolver.getBool_(cfg, {'multiAsset','twoWayTimeTransferISL','enable'}, false) || ...
                revgnss.SwarmRelativeSolver.getBool_(cfg, {'measurements','isl','twoWay','timeTransfer','enable'}, false);
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
            % Crosslink topology: how many neighbours each spacecraft can actually contact, and
            % which. Configurable rather than hard-coded, because it is a spacecraft design
            % parameter (number of terminals) not a property of the estimator.
            maxDeg = revgnss.SwarmRelativeSolver.getNum_(cfg, ...
                {'multiAsset','twoWayISL','maxNeighbours'}, revgnss.SwarmRelativeSolver.MAX_DEGREE);
            maxDeg = max(1, round(maxDeg));
            maxRange = revgnss.SwarmRelativeSolver.getNum_(cfg, ...
                {'multiAsset','twoWayISL','maxRange_m'}, inf);
            reqVis = revgnss.SwarmRelativeSolver.getBool_(cfg, ...
                {'multiAsset','twoWayISL','requireLineOfSight'}, true);
            layout = revgnss.SwarmRelativeSolver.getStr_(cfg, ...
                {'multiAsset','twoWayISL','terminalLayout'}, 'omni');
            switch lower(layout)
                case 'cones'
                    body = revgnss.SwarmRelativeSolver.bodyFrames_(Est, meanPos);
                    [pairs, topoDiag] = revgnss.SwarmRelativeSolver.coneGraph_( ...
                        cfg, meanPos, body, maxRange, reqVis);
                otherwise
                    [pairs, topoDiag] = revgnss.SwarmRelativeSolver.neighbourGraph_( ...
                        meanPos, maxDeg, maxRange, reqVis);
            end
            topoDiag.terminalLayout = lower(layout);
            out.topology = topoDiag;
            out.topology.nLinks = size(pairs,1);
            out.topology.nAssets = N;
            out.topology.shapeDof = max(0, 3*N - 6);
            % A range graph can only fix the shape if it spans 3N-6; state it rather than let a
            % marginal graph fail silently downstream.
            out.topology.rigidityMargin = size(pairs,1) - max(0, 3*N - 6);
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

            % --- REAL four-timestamp range, when the recorded truth supports it ----------------
            % Replaces the synthetic |r_i-r_k|+bias+noise above with the SUM combination of the
            % same t1..t4 exchange that produces the clock difference: a genuine two-way range
            % carrying retarded-time light travel each way, endpoint motion between the events,
            % terminal/turnaround delays and attitude-rotated phase centres. Validated inside
            % fourTimestampObservables_ against the truth geometry before it is accepted; on any
            % failure the synthetic observable is kept and the reason recorded.
            % Only the range is consumed here; the clock half is recomputed by the clock layer.
            [~, ftRange, ftReason] = revgnss.SwarmRelativeSolver.fourTimestampObservables_( ...
                cfg, results, pairs, tVec, nEp);
            out.shapeObservationSource = 'syntheticTwoWayISL';
            out.shapeFallbackReason = ftReason;
            if ~isempty(ftRange)
                out.shapeObservationSource = 'fourTimestampTwoWayRange';
                out.shapeFallbackReason = '';
            end

            % --- Gauge prior: which directions may the ISL move? --------------------------------
            % 'minNorm' (default) is the historical unweighted gauge, byte-identical. 'radialStiff'
            % declares that the radial axis is already pinned by the ground link and the crosslinks
            % may only reshape the formation ACROSS it. Read before the delay-bias pass so both
            % that pass and the final solve use the same gauge -- estimating biases under one gauge
            % and applying them under another would leave the bias absorbing the difference.
            gaugeMode = revgnss.SwarmRelativeSolver.getStr_(cfg, ...
                {'multiAsset','twoWayISL','gauge','mode'}, 'minNorm');
            solvePrior = struct();
            if strcmpi(gaugeMode, 'radialstiff')
                solvePrior = struct( ...
                    'sigmaRadial_m', revgnss.SwarmRelativeSolver.getNum_(cfg, ...
                        {'multiAsset','twoWayISL','gauge','sigmaRadialPrior_m'}, 0.16), ...
                    'sigmaTransverse_m', revgnss.SwarmRelativeSolver.getNum_(cfg, ...
                        {'multiAsset','twoWayISL','gauge','sigmaTransversePrior_m'}, inf));
            end
            out.gaugeMode = lower(gaugeMode);
            out.gaugePrior = solvePrior;

            % --- Per-link delay-bias ESTIMATION (network self-calibration) ---------------------
            % A two-way range is rho = 0.5c(dt - tau_terminal - tau_turnaround); an error in the
            % STORED tau enters as a per-link CONSTANT, which is why it does not average down and
            % why it, not thermal noise, sets the shape floor. But constant is exactly what makes
            % it separable: over the arc the formation GEOMETRY changes while the bias does not.
            % Estimate it as the per-link mean post-fit residual over a first pass, then re-solve
            % with it removed.
            %
            % WHAT IS AND IS NOT OBSERVABLE. Adding the SAME constant to every link inflates every
            % distance, i.e. it scales the formation -- indistinguishable from a real change of
            % scale, so the COMMON part of the bias is unobservable and is deliberately left in.
            % Only the per-link DIFFERENCES from the mean are removed, and those are precisely the
            % part that DISTORTS the shape. Removing the mean as well would be fitting a gauge.
            estimateBias = revgnss.SwarmRelativeSolver.getBool_(cfg, ...
                {'multiAsset','twoWayISL','delayCal','estimate','enable'}, false);
            biasHat = zeros(nP,1);
            out.delayBiasEstimated = false;
            out.delayBiasEstimate_m = zeros(1,nP);
            out.delayBiasResidualRms_m = NaN;
            if estimateBias
                nPass = max(1, round(revgnss.SwarmRelativeSolver.getNum_(cfg, ...
                    {'multiAsset','twoWayISL','delayCal','estimate','iterations'}, 2)));
                for pass = 1:nPass
                    acc = zeros(nP,1); cnt = 0;
                    for kk = 1:nEp
                        estK = zeros(3,N);
                        for i = 1:N; estK(:,i) = Est{i}(:,kk); end
                        zK = revgnss.SwarmRelativeSolver.rangeObservables_( ...
                            pairs, kk, ftRange, Truth, tVec, ltOn, pairBias, thermal, nP) - biasHat;
                        rH = revgnss.SwarmRelativeSolver.solveEpoch_( ...
                            estK, zK, pairs, 1./pairR(:), N, solvePrior);
                        for p = 1:nP
                            acc(p) = acc(p) + (zK(p) - norm(rH(:,pairs(p,1)) - rH(:,pairs(p,2))));
                        end
                        cnt = cnt + 1;
                    end
                    delta = acc/max(cnt,1);
                    delta = delta - mean(delta);      % keep the unobservable common part
                    biasHat = biasHat + delta;
                end
                out.delayBiasEstimated = true;
                out.delayBiasEstimate_m = biasHat(:).';
                % Honest scoring against the truth biases, differential part only (the common
                % part is not observable, so comparing it would flatter or punish arbitrarily).
                truthDiff = pairBias(:) - mean(pairBias(:));
                out.delayBiasResidualRms_m = sqrt(mean((biasHat - truthDiff).^2));
            end

            % --- Per-epoch free-network shape solve ---------------------------------------------
            blRaw = nan(1,nEp); blSol = nan(1,nEp);
            shRaw = nan(1,nEp); shSol = nan(1,nEp);
            fSig  = nan(1,nEp); weakEp = false(1,nEp);
            solvedPos = nan(3,N,nEp); % Native estimated frame; no truth-based alignment.
            Winv  = 1 ./ pairR(:);                    % per-pair weight = 1/R
            for kk = 1:nEp
                estK = zeros(3,N); truthK = zeros(3,N);
                for i = 1:N; estK(:,i) = Est{i}(:,kk); truthK(:,i) = Truth{i}(:,kk); end

                % Two-way-ISL range observables for this epoch. The four-timestamp value already
                % contains the full round-trip physics, so only the hardware delay-calibration
                % bias and receiver thermal noise are added -- exactly the terms clockNoise_/
                % rangeNoise_ define. The synthetic branch is the fallback.
                zK = revgnss.SwarmRelativeSolver.rangeObservables_( ...
                    pairs, kk, ftRange, Truth, tVec, ltOn, pairBias, thermal, nP) - biasHat;
                if ltOn && isempty(ftRange)
                    for p = 1:nP
                        lt = revgnss.SwarmRelativeSolver.twoWayLightTime_(Truth, ...
                            pairs(p,1), pairs(p,2), kk, tVec, ...
                            norm(truthK(:,pairs(p,1)) - truthK(:,pairs(p,2))));
                        out.lightTimeMax_m = max(out.lightTimeMax_m, abs(lt));
                    end
                end

                [rHat, Pshape, weak] = revgnss.SwarmRelativeSolver.solveEpoch_( ...
                    estK, zK, pairs, Winv, N, solvePrior);
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

            % Gated ground-differenced ROTATION solve.
            % Ranges fix the shape and are exactly blind to the formation's orientation (the
            % Jacobian along a rotation direction is machine zero), so the orientation above is
            % whatever the per-asset EKF priors supplied. Only an Earth-referenced observable can
            % set it; revgnss.GroundDifferencedRotationSolver supplies one from tower->satellite
            % code double differences. Default OFF -> solvedPos is untouched and byte-identical.
            % solvedPosPreRotation is retained unconditionally so the before/after pair is always
            % available to the metric layer, which is the only thing allowed to see truth.
            out.solvedPosPreRotation = out.solvedPos;
            rot = revgnss.GroundDifferencedRotationSolver.solve(cfg, results, out);
            out.rotationGateOn      = rot.applicable;
            out.rotationReason      = rot.reason;
            out.rotationTheta_rad   = rot.theta_rad;
            out.rotationSigma_rad   = rot.thetaSigma_rad;
            out.rotationNObs        = rot.nObs;
            out.rotationCondition   = rot.condition;
            if rot.applicable && ~isempty(rot.solvedPos)
                out.solvedPos = rot.solvedPos;
            end

            % Gated JOINT shape+rotation solve. Supersedes the 3-parameter stage above: that one
            % has no shape freedom, so arc-correlated deformation leaks into rotation at
            % 0.30 deg/m with a formal sigma that never notices. The joint solve carries an
            % arc-constant shape correction alongside the rotation, which removes the leakage by
            % construction. It runs LAST so it sees the ISL-solved geometry, and it overwrites
            % solvedPos only on success. Default OFF -> byte-identical.
            jnt = revgnss.JointGeometrySolver.solve(cfg, results, out);
            out.jointGateOn        = jnt.applicable;
            out.jointReason        = jnt.reason;
            out.jointTheta_rad     = jnt.theta_rad;
            out.jointThetaSigma_rad = jnt.thetaSigma_rad;
            out.jointShapeStep_m   = jnt.shapeStep_m;
            out.jointNObs          = jnt.nObs;
            if jnt.applicable && ~isempty(jnt.solvedPos)
                out.solvedPos = jnt.solvedPos;
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
                'shapeFallbackReason', '', ...
                'delayBiasEstimated', false, 'delayBiasEstimate_m', [], ...
                'delayBiasResidualRms_m', NaN, ...
                'relClockGateOn', false, 'relClockErrRaw_m', NaN, ...
                'relClockErrSolved_m', NaN, 'relClockFormalSigma_m', NaN, ...
                'relClockObservableSource', 'disabled', 'relClockFallbackReason', '', ...
                'topology', struct(), ...
                'solvedPos', [], 'solvedPosPreRotation', [], 'time_s', [], ...
                'rotationGateOn', false, 'rotationReason', 'notAttempted', ...
                'rotationTheta_rad', [0;0;0], 'rotationSigma_rad', [NaN;NaN;NaN], ...
                'rotationNObs', 0, 'rotationCondition', NaN, ...
                'jointGateOn', false, 'jointReason', 'notAttempted', ...
                'jointTheta_rad', [0;0;0], 'jointThetaSigma_rad', [NaN;NaN;NaN], ...
                'jointShapeStep_m', NaN, 'jointNObs', 0, ...
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

        function tf = lineOfSightClearsEarth_(rA_m, rB_m)
            % lineOfSightClearsEarth_  True when the straight segment A->B does not pass through
            % the Earth (plus the configured grazing margin).
            %
            % Closest approach of the SEGMENT to the origin, not of the infinite line: for two
            % satellites on the same side of the planet the perpendicular foot often lies outside
            % the segment, and using the line would wrongly declare them blocked.
            Re = revgnss.Constants.EARTH_RADIUS_M;
            d = rB_m - rA_m;
            L2 = d.'*d;
            if L2 <= 0; tf = true; return; end
            t = -(rA_m.'*d)/L2;                 % parameter of the closest point on the infinite line
            t = min(1, max(0, t));              % clamp INTO the segment
            closest = norm(rA_m + t*d);
            tf = closest > Re;
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

        function body = bodyFrames_(Est, meanPos)
            % bodyFrames_  Per-satellite body axes for a nadir-pointing bus, from the estimated
            % trajectory alone: z_body = radial (the beamforming face looks down it), x_body =
            % along-track, y_body = cross-track. Returns a [3 x 3 x N] stack of [x y z] columns.
            N = size(meanPos,2);
            body = zeros(3,3,N);
            for i = 1:N
                zb = meanPos(:,i);
                nz = norm(zb);
                if nz <= 0; zb = [0;0;1]; else; zb = zb/nz; end
                % Along-track from the satellite's own motion over the arc; a formation this tight
                % gives every member essentially the same track, but taking it per-satellite keeps
                % the frame well defined without needing a velocity field the solver is not passed.
                v = Est{i}(:,end) - Est{i}(:,1);
                v = v - (zb.'*v)*zb;                    % strip the radial part
                if norm(v) < eps(nz)
                    v = [1;0;0] - zb(1)*zb;             % degenerate arc: any perpendicular will do
                    if norm(v) < 1e-9; v = [0;1;0] - zb(2)*zb; end
                end
                xb = v/norm(v);
                yb = cross(zb, xb);
                body(:,:,i) = [xb, yb, zb];
            end
        end

        function B = terminalBoresights_(cfg)
            % terminalBoresights_  Antenna boresights in BODY axes [x=along, y=cross, z=radial]:
            % rimTerminalCount terminals spread evenly in the x-y plane (optionally tilted up by
            % rimTilt_deg) plus zenith (+z) and nadir (-z).
            nRim = revgnss.SwarmRelativeSolver.getNum_(cfg, ...
                {'multiAsset','twoWayISL','rimTerminalCount'}, 3);
            nRim = max(0, round(nRim));
            tilt = deg2rad(revgnss.SwarmRelativeSolver.getNum_(cfg, ...
                {'multiAsset','twoWayISL','rimTilt_deg'}, 0));
            useZen = revgnss.SwarmRelativeSolver.getBool_(cfg, ...
                {'multiAsset','twoWayISL','useZenithTerminal'}, true);
            useNad = revgnss.SwarmRelativeSolver.getBool_(cfg, ...
                {'multiAsset','twoWayISL','useNadirTerminal'}, true);
            B = zeros(3,0);
            for k = 1:nRim
                az = 2*pi*(k-1)/nRim;
                B(:,end+1) = [cos(tilt)*cos(az); cos(tilt)*sin(az); sin(tilt)]; %#ok<AGROW>
            end
            if useZen; B(:,end+1) = [0;0; 1]; end
            if useNad; B(:,end+1) = [0;0;-1]; end
        end

        function [pairs, diag] = coneGraph_(cfg, meanPos, body, maxRange_m, requireVisible)
            % coneGraph_  One link per ANTENNA CONE rather than the k closest overall.
            %
            % Why this is not the same rule: the k-closest set clusters in direction, so several
            % terminals end up pointing at nearly the same place and the range network learns the
            % same component of the geometry repeatedly. Range is cheap here -- a 4 km crosslink in
            % this formation costs almost nothing -- so the budget is better spent on ANGULAR
            % diversity, which one-link-per-cone enforces for free.
            %
            % The trap this method exists to avoid: cones OVERLAP, so "nearest inside each cone"
            % naively selects the SAME satellite for three cones at once and the graph collapses
            % (measured: 29 links at 90 deg, versus 59 once partners are forced distinct). Partners
            % are therefore assigned, not chosen independently: most-constrained terminal first,
            % each partner claimed once.
            %
            % linksPerTerminal > 1 gives each terminal several partners to serve in turn. That is
            % not extra hardware -- the crosslink schedule already time-shares one terminal across
            % a round -- it is the same antenna visiting more of its cone.
            half = cosd(revgnss.SwarmRelativeSolver.getNum_(cfg, ...
                {'multiAsset','twoWayISL','coneHalfAngle_deg'}, 70));
            perTerm = max(1, round(revgnss.SwarmRelativeSolver.getNum_(cfg, ...
                {'multiAsset','twoWayISL','linksPerTerminal'}, 2)));
            if nargin < 4 || isempty(maxRange_m); maxRange_m = inf; end
            if nargin < 5 || isempty(requireVisible); requireVisible = true; end
            Bbody = revgnss.SwarmRelativeSolver.terminalBoresights_(cfg);
            nT = size(Bbody,2);
            N = size(meanPos,2);

            visible = false(N);
            for i = 1:N
                for k = 1:N
                    if i == k; continue; end
                    visible(i,k) = ~requireVisible || ...
                        revgnss.SwarmRelativeSolver.lineOfSightClearsEarth_(meanPos(:,i), meanPos(:,k));
                end
            end

            adj = false(N);
            emptySlots = 0;
            for i = 1:N
                Bi = body(:,:,i) * Bbody;                  % boresights rotated into ECEF
                d = meanPos - meanPos(:,i);
                rng_m = vecnorm(d,2,1);
                eligible = visible(i,:) & rng_m <= maxRange_m;
                eligible(i) = false;
                U = d ./ max(rng_m, eps);
                cand = cell(1,nT);
                for b = 1:nT
                    inCone = (Bi(:,b).' * U) >= half & eligible;
                    idx = find(inCone);
                    [~, ord] = sort(rng_m(idx));
                    cand{b} = idx(ord);                    % in-cone partners, nearest first
                end
                claimed = false(1,N);
                for pass = 1:perTerm
                    remaining = zeros(1,nT);
                    for b = 1:nT; remaining(b) = sum(~claimed(cand{b})); end
                    [~, order] = sort(remaining);          % most-constrained terminal chooses first
                    for b = order
                        free = cand{b}(~claimed(cand{b}));
                        if isempty(free)
                            if pass == 1; emptySlots = emptySlots + 1; end
                            continue;
                        end
                        j = free(1);
                        claimed(j) = true;
                        adj(i,j) = true;
                    end
                end
            end
            adj = adj & (visible | visible.');
            diag = struct('maxDegree', nT*perTerm, 'maxRange_m', maxRange_m, ...
                'requireVisible', logical(requireVisible), ...
                'nVisiblePairs', sum(sum(triu(visible,1))), ...
                'nCandidatePairs', N*(N-1)/2, ...
                'nTerminals', nT, 'linksPerTerminal', perTerm, ...
                'coneHalfAngle_deg', acosd(half), 'nEmptyConeSlots', emptySlots);
            adj = adj | adj.';
            pairs = zeros(0,2);
            for i = 1:N
                for k = (i+1):N
                    if adj(i,k); pairs(end+1,:) = [i k]; end %#ok<AGROW>
                end
            end
        end

        function [pairs, diag] = neighbourGraph_(meanPos, maxDeg, maxRange_m, requireVisible)
            % neighbourGraph_  Each satellite contacts at most maxDeg neighbours: the CLOSEST ones
            % that are actually VISIBLE to it. Symmetrized by union, canonical i<k.
            %
            % A real terminal cannot talk to every other member of the constellation: it has a
            % finite number of steerable crosslink terminals, a finite link budget, and a line of
            % sight that the Earth can block. Three independent limits, applied in order:
            %   1. VISIBILITY  the segment between the two satellites must clear the Earth. A
            %      crosslink whose line of sight passes through the planet does not exist, however
            %      close the two spacecraft are in straight-line distance.
            %   2. maxRange_m  link-budget reach (inf disables it).
            %   3. maxDeg      how many terminals the spacecraft actually has.
            % Distance alone was the previous rule, which silently assumed every pair was
            % reachable; for a co-orbiting GEO formation that happens to be true, but it is an
            % assumption the topology should state rather than inherit.
            %
            % For N <= maxDeg+1 with no other limit biting this is the full mesh, matching the
            % historical links='all' behaviour exactly.
            if nargin < 3 || isempty(maxRange_m); maxRange_m = inf; end
            if nargin < 4 || isempty(requireVisible); requireVisible = true; end
            N = size(meanPos,2);
            D = inf(N);
            visible = false(N);
            for i = 1:N
                for k = 1:N
                    if i == k; continue; end
                    d = norm(meanPos(:,i) - meanPos(:,k));
                    vis = ~requireVisible || ...
                        revgnss.SwarmRelativeSolver.lineOfSightClearsEarth_(meanPos(:,i), meanPos(:,k));
                    visible(i,k) = vis;
                    if vis && d <= maxRange_m; D(i,k) = d; end
                end
            end
            adj = false(N);
            for i = 1:N
                cand = find(isfinite(D(i,:)));
                [~, ord] = sort(D(i,cand));                % nearest first, eligible only
                cand = cand(ord);
                deg = min(maxDeg, numel(cand));
                adj(i, cand(1:deg)) = true;                % directed nearest-maxDeg
            end
            adj = adj & (visible | visible.');             % a link needs a clear path both ways
            diag = struct('maxDegree', maxDeg, 'maxRange_m', maxRange_m, ...
                'requireVisible', logical(requireVisible), ...
                'nVisiblePairs', sum(sum(triu(visible,1))), ...
                'nCandidatePairs', N*(N-1)/2);
            adj = adj | adj.';                             % symmetric UNION (link if either picks it)
            pairs = zeros(0,2);
            for i = 1:N
                for k = (i+1):N
                    if adj(i,k); pairs(end+1,:) = [i k]; end %#ok<AGROW>
                end
            end
        end

        function S = directionalStiffness_(estK, N, prior)
            % directionalStiffness_  Block-diagonal 3Nx3N prior stiffness, anisotropic per
            % satellite: stiff along its own radial (Earth-pointing) direction, free across it.
            %
            % Returns [] when no prior is configured, which restores the exact historical
            % min-norm behaviour byte for byte.
            S = [];
            if ~isstruct(prior) || isempty(fieldnames(prior)); return; end
            sigR = revgnss.SwarmRelativeSolver.priorField_(prior, 'sigmaRadial_m', inf);
            sigT = revgnss.SwarmRelativeSolver.priorField_(prior, 'sigmaTransverse_m', inf);
            kR = 0; if isfinite(sigR) && sigR > 0; kR = 1/sigR^2; end
            kT = 0; if isfinite(sigT) && sigT > 0; kT = 1/sigT^2; end
            if kR <= 0 && kT <= 0; return; end
            S = zeros(3*N);
            for i = 1:N
                u = estK(:,i);
                n = norm(u);
                if ~(n > 0); continue; end
                u = u/n;                                   % radial: Earth centre -> satellite
                P = u*u.';                                 % projector onto radial
                blk = kR*P + kT*(eye(3) - P);              % stiff radially, kT across it
                idx = 3*(i-1) + (1:3);
                S(idx, idx) = blk;
            end
        end

        function v = priorField_(prior, name, dflt)
            v = dflt;
            if isfield(prior, name) && ~isempty(prior.(name)) && isnumeric(prior.(name))
                v = double(prior.(name)(1));
            end
        end

        function [rHat, Pshape, weak] = solveEpoch_(estK, zK, pairs, Winv, N, prior)
            % One epoch: Gauss-Newton min-norm (inner-gauge) WLS shape correction over delta in R^{3N}.
            % delta = pinv(H'WH) H'W res puts ZERO in the 6-D rigid null space -> the corrected
            % positions keep the estimated rigid frame and only the internal shape moves. Reported metrics
            % are gauge-invariant so this choice is inert.
            %
            % OPTIONAL DIRECTIONAL PRIOR (prior.sigmaRadial_m / prior.sigmaTransverse_m).
            % The plain min-norm gauge treats every direction as equally uncertain, which is false
            % here and expensively so. Ground two-way ranging measures the RADIAL direction
            % directly, and the per-asset EKF realises ~0.16 m there against ~3.4 m transverse --
            % a 21x anisotropy. The crosslinks, by contrast, are mostly TRANSVERSE chords (this
            % formation is 5607 m wide and 1985 m deep), so an unweighted fit happily spends
            % radial displacement to satisfy transverse range residuals. Measured consequence:
            % the solve degraded the beamforming path error from 0.165 m to 0.584 m while
            % improving shape -- it traded the one axis the beam reads for two it does not.
            %
            % Adding S = sum_i (1/sigmaRadial^2) * u_i u_i' with u_i the radial unit vector makes
            % radial corrections expensive and transverse ones free, so the ISL fixes the shape
            % without overwriting what the ground link already knew. Deliberately NOT the filter's
            % own covariance: this project measured that covariance to be ~25x optimistic, so a
            % P^-1 weight would refuse to move at all. Physics-justified stiffness first; the
            % covariance route becomes correct once the covariance is honest.
            if nargin < 6; prior = []; end
            nP = size(pairs,1);
            r  = estK;                                     % working estimate, updated per GN iter
            S  = revgnss.SwarmRelativeSolver.directionalStiffness_(estK, N, prior);
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
                if ~isempty(S)
                    % Penalise the DISPLACEMENT FROM THE PRIOR, so the term is (delta_total)'S(...)
                    % measured from the original estimate, not from this iteration's working point.
                    step = reshape(r - estK, [], 1);
                    Nmat = Nmat + S;
                    g    = g - S*step;
                end
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
            % removing a pair cannot perturb another pair's draw.
            %
            % R = thermal^2 + (const^2 + rw^2), i.e. the per-epoch error variance.
            %
            % This previously carried an extra nCorr = min(tau/dt, nCorrCap) = 60 factor on
            % the bias term, justified as stopping "the sequential white-R weight" from
            % averaging the bias below ~sqrt(nCorr). That justification does not apply to
            % this consumer: solveEpoch_ is a PER-EPOCH weighted least squares (see the
            % `for kk = 1:nEp` loop) which performs no temporal averaging at all. At any
            % single epoch the error on a pair is thermal(p,kk) + pairBias(p), whose
            % variance is exactly sP^2 + sConst^2 + sRW^2 -- the bias is fully present,
            % not averaged, so inflating it 60x simply overstates R by ~7.4x.
            %
            % Because pairR here varies per pair (link-budget thermal sigma), the inflation
            % was also estimate-affecting: it swamped the per-pair sP^2 and flattened the
            % relative weights towards uniform. Removing it restores link-budget-driven
            % weighting. tau_s / nCorrCap remain configured for any future sequential
            % consumer but no longer inflate this per-epoch R.
            g = @(p,d) revgnss.SwarmRelativeSolver.getNum_(cfg, p, d);
            sThermal = g({'multiAsset','twoWayISL','sigma_m'}, 0.01);
            sConst   = g({'multiAsset','twoWayISL','delayCal','sigma_const_m'}, 0.01);
            sRW      = g({'multiAsset','twoWayISL','delayCal','sigma_rw_m'}, 0.003);
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
                pairR(p) = sP^2 + sConst^2 + sRW^2;
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

            % REAL four-timestamp physics when the recorded truth supports it. The synthetic
            % observable below is (b_i - b_k) + bias + noise: an exact clock difference with no
            % round trip in it at all. The four-timestamp chain instead solves the actual t1..t4
            % event sequence (retarded-time light travel each way, endpoint motion between the
            % events, terminal/turnaround delays, phase-centre offsets rotated by the truth
            % attitude) and reduces THAT to a clock difference -- which is what a real terminal
            % computes. Falls back to the synthetic observable, with the reason recorded, when the
            % recorded truth lacks attitude or clock drift; it never silently substitutes.
            [fourTs, ~, ftReason] = revgnss.SwarmRelativeSolver.fourTimestampObservables_( ...
                cfg, results, pairs, tVec, nEp);
            out.relClockObservableSource = 'syntheticClockDifference';
            out.relClockFallbackReason = ftReason;
            if ~isempty(fourTs)
                out.relClockObservableSource = 'fourTimestampClockDifference';
                out.relClockFallbackReason = '';
            end

            relRaw = nan(1,nEp); relSol = nan(1,nEp); fSig = nan(1,nEp);
            % The per-satellite solved clock is kept, not just its RMS: a beamformer pays for the
            % clock error in the same metres of path as the geometry error, so the two have to be
            % summed per element before any coherence figure means anything.
            solvedClock_m = nan(N, nEp);
            for kk = 1:nEp
                eB = estB(:,kk); tB = truB(:,kk);
                H = zeros(nP, N); res = zeros(nP,1);
                for p = 1:nP
                    i = pairs(p,1); k = pairs(p,2);
                    if isempty(fourTs) || ~isfinite(fourTs(p,kk))
                        z = (tB(i) - tB(k)) + pairBias(p) + thermal(p,kk);   % synthetic fallback
                    else
                        % Four-timestamp value already carries the full round-trip physics; only
                        % the hardware delay-calibration bias and receiver thermal noise are added,
                        % exactly as clockNoise_ defines them for the synthetic path.
                        z = fourTs(p,kk) + pairBias(p) + thermal(p,kk);
                    end
                    res(p) = z - (eB(i) - eB(k));
                    H(p,i) = 1; H(p,k) = -1;                             % +1 on clk_i, -1 on clk_k
                end
                W = diag(Winv);
                % min-norm inner gauge: the 1-D null space is the common (mean) clock, which sat-sat
                % time transfer cannot observe -> left at the prior mean; every reported metric is a clock
                % DIFFERENCE so it is gauge-invariant.
                [C, delta] = revgnss.SwarmRelativeSolver.truncPinv_(H.'*W*H, H.'*W*res);
                bHat = eB + delta;
                solvedClock_m(:,kk) = bHat(:) - tB(:);   % signed error, per satellite, in metres
                relRaw(kk) = revgnss.SwarmRelativeSolver.relClockRms_(eB,   tB, pairs);
                relSol(kk) = revgnss.SwarmRelativeSolver.relClockRms_(bHat, tB, pairs);
                fSig(kk)   = sqrt(mean(diag(C)));
            end
            tsel = revgnss.SwarmRelativeSolver.tailIdx_(nEp);
            out.relClockGateOn        = true;
            out.relClockErrRaw_m      = sqrt(mean(relRaw(tsel).^2));
            out.relClockErrSolved_m   = sqrt(mean(relSol(tsel).^2));
            out.relClockFormalSigma_m = mean(fSig(tsel));
            out.solvedClockError_m    = solvedClock_m;   % [N x nEp], consumed by the phasor series
        end

        function zK = rangeObservables_(pairs, kk, ftRange, Truth, tVec, ltOn, pairBias, thermal, nP)
            % rangeObservables_  The nPairs x 1 two-way range observations for one epoch.
            % Single definition shared by the bias-estimation pass and the final solve, so the
            % two can never drift apart. Prefers the REAL four-timestamp range; falls back to the
            % synthetic geometric range (optionally light-time corrected) when it is unavailable.
            zK = zeros(nP,1);
            for p = 1:nP
                i = pairs(p,1); k = pairs(p,2);
                if ~isempty(ftRange) && isfinite(ftRange(p,kk))
                    rho = ftRange(p,kk);
                else
                    rho = norm(Truth{i}(:,kk) - Truth{k}(:,kk));
                    if ltOn
                        rho = rho + revgnss.SwarmRelativeSolver.twoWayLightTime_( ...
                            Truth, i, k, kk, tVec, rho);
                    end
                end
                zK(p) = rho + pairBias(p) + thermal(p,kk);
            end
        end

        function [values_m, range_m, reason] = fourTimestampObservables_(cfg, results, pairs, tVec, nEp)
            % fourTimestampObservables_  Replay the REAL four-timestamp chain for every pair and
            % epoch, returning BOTH observables the four tags support:
            %   values_m  nPairs x nEpoch clock difference [m]
            %   range_m   nPairs x nEpoch two-way RANGE     [m]
            %
            % The same t1..t4 exchange yields both -- they are the difference and the sum
            % combination of the identical four tags:
            %     clock = 0.5*((t2-t1) - (t4-t3))
            %     range = 0.5*c*((t4-t1) - (t3-t2))
            % revgnss.FourTimestampObservableBuilder reduces only the clock, but publishes the two
            % intervals the range needs (originRoundTripLocalDelay_s, anchorTurnaroundLocalDelay_s)
            % computed from the SAME delay-corrected tags, so the range is recovered here without
            % re-deriving any physics. Both therefore carry the full round trip: retarded-time
            % light travel each way, endpoint motion between events, terminal and turnaround
            % delays, phase centres rotated by truth attitude.
            %
            % Empty + a reason when the recorded truth cannot drive it -- the caller then keeps the
            % synthetic observable and reports which. No partial mixing: either every endpoint can
            % be replayed or none is.
            %
            % SIGN. revgnss.FourTimestampObservableBuilder.reduceClockDifference_ is
            % 0.5*((t2-t1)-(t4-t3)) with the ORIGIN as the subtracting reference, i.e. it returns
            % (b_remote - b_reference) = b_k - b_i for pair (i,k). This solver's clock rows are
            % built as (b_i - b_k), so the value is NEGATED here. Verified at run time below
            % against the recorded truth difference rather than trusted. The range needs no sign
            % convention but IS validated against the truth geometry for the same reason.
            values_m = []; range_m = []; reason = '';
            N = numel(results.asset);
            for i = 1:N
                if ~revgnss.TruthEndpointReplay.isUsable(results.asset{i}, nEp)
                    reason = sprintf('asset%d:%s', i, ...
                        revgnss.TruthEndpointReplay.unusableReason(results.asset{i}, nEp));
                    return
                end
            end
            try
                hardware = revgnss.FourTimestampPhysicalLinkConfig.hardwareModel(cfg,'isl','physicalTruth');
                info = struct('terminalDelayAllocation', revgnss.SwarmRelativeSolver.getStr_(cfg, ...
                    {'measurements','isl','twoWay','fourTimestampPhysical','terminalDelayAllocation'}, ...
                    'receiveEvent'));
                carrierHz = revgnss.SwarmRelativeSolver.getNum_(cfg, ...
                    {'measurements','isl','twoWay','fourTimestampPhysical','carrierFrequency_Hz'},26e9);
                geom = cell(1,N);
                replay = cell(1,N);
                for i = 1:N
                    geom{i} = revgnss.FourTimestampPhysicalLinkConfig.shortNameIslTerminalGeometry(cfg,i);
                    replay{i} = revgnss.TruthEndpointReplay(results.asset{i}, nEp, tVec);
                end
            catch setupErr
                reason = ['setup:' setupErr.message];
                return
            end

            nP = size(pairs,1);
            values_m = nan(nP,nEp);
            range_m = nan(nP,nEp);
            cLight = revgnss.Constants.SPEED_OF_LIGHT_MPS;
            for kk = 1:nEp
                t_s = tVec(kk);
                for i = 1:N; replay{i}.seek(kk); end
                for p = 1:nP
                    a = pairs(p,1); b = pairs(p,2);
                    try
                        record = revgnss.DirectReciprocalTimeTransferBuilder.buildFromIsl( ...
                            replay{a}, a, geom{a}, replay{b}, b, geom{b}, hardware, t_s, ...
                            exchangeIdentifier=sprintf('swarm-rel:%d-%d:e%09d',a,b,kk), ...
                            sessionIdentifier=sprintf('swarm-rel:%d-%d:s%09d',a,b,kk), ...
                            protocolIdentifier='directFourTimestampTwoWay', ...
                            signalIdentifier='ISL-4TS', channelIdentifier=sprintf('CH-%d-%d',a,b), ...
                            carrierFrequency_Hz=carrierHz, ...
                            counterTagSigma_s=zeros(1,4), ...
                            counterTagLabels={'t1','t2','t3','t4'}, ...
                            truthDiagnosticIdentifier=sprintf('swarm-rel:%d-%d:e%09d-truth',a,b,kk));
                        obs = revgnss.FourTimestampObservableBuilder.fromExchangeRecord( ...
                            record, hardware, info);
                        values_m(p,kk) = -obs.clockDifferenceValue_m;   % -> (b_i - b_k), see SIGN
                        % The SUM combination of the same four delay-corrected tags: the classical
                        % two-way range. (t4-t1) is the round trip on the origin's clock, (t3-t2)
                        % the turnaround on the destination's; their difference is forward plus
                        % return propagation, so half of it times c is the one-way range.
                        range_m(p,kk) = 0.5*cLight * ...
                            (obs.originRoundTripLocalDelay_s - obs.anchorTurnaroundLocalDelay_s);
                    catch obsErr
                        if isempty(reason); reason = ['observable:' obsErr.message]; end
                        values_m = []; range_m = [];
                        return
                    end
                end
            end

            % Runtime sign/scale check against the recorded truth clock difference. A sign error
            % would double the residual instead of cancelling it, and would otherwise be invisible
            % because the solver only ever reports a gauge-invariant RMS.
            i1 = pairs(1,1); k1 = pairs(1,2);
            b1 = results.asset{i1}.truthClkTraj_m(:).';
            b2 = results.asset{k1}.truthClkTraj_m(:).';
            m = min([nEp numel(b1) numel(b2)]);
            expected = b1(1:m) - b2(1:m);
            got = values_m(1,1:m);
            good = isfinite(expected) & isfinite(got);
            if any(good)
                errSame = sqrt(mean((got(good)-expected(good)).^2));
                errFlip = sqrt(mean((got(good)+expected(good)).^2));
                if errFlip < errSame
                    reason = sprintf(['signCheckFailed: matching the NEGATED truth difference ' ...
                        '(%.4g m) better than the asserted one (%.4g m)'], errFlip, errSame);
                    values_m = []; range_m = [];
                    return
                end
            end

            % Range validation against the TRUTH geometry. The recovered range must reproduce the
            % true inter-satellite distance to well inside the measurement error the caller is
            % about to add; a delay-bookkeeping mistake in the sum combination would otherwise
            % enter as a silent per-link bias. Checked on the first pair over the whole arc.
            rt1 = results.asset{i1}.truthTraj; rt2 = results.asset{k1}.truthTraj;
            mm = min([nEp size(rt1,2) size(rt2,2)]);
            truthRange = vecnorm(rt1(:,1:mm)-rt2(:,1:mm),2,1);
            gotRange = range_m(1,1:mm);
            ok = isfinite(truthRange) & isfinite(gotRange);
            if any(ok)
                resid = gotRange(ok) - truthRange(ok);
                residRms = sqrt(mean(resid.^2));
                % Tolerance: the physical chain legitimately differs from the instantaneous
                % geometric distance by the light-time/motion terms, which are sub-millimetre for
                % a co-moving formation. Anything at the metre level is a bookkeeping error.
                if ~(residRms < 0.10)
                    reason = sprintf(['rangeCheckFailed: four-timestamp range differs from the ' ...
                        'truth geometry by %.4g m RMS (bias %.4g m)'], residRms, mean(resid));
                    values_m = []; range_m = [];
                    return
                end
            end
        end

        function s = getStr_(cfg, path, dflt)
            s = cfg;
            for i = 1:numel(path)
                if isstruct(s) && isfield(s,path{i}); s = s.(path{i}); else; s = dflt; return; end
            end
            if ~(ischar(s) || isstring(s)); s = dflt; else; s = char(s); end
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
            % R = thermal^2 + (const^2 + rw^2), the per-epoch error variance.
            %
            % As in islNoise_, the former nCorr = min(tau/dt, nCorrCap) = 60 inflation on the
            % bias term does not apply here: the consumer is a per-epoch weighted least
            % squares with no temporal averaging, so the constant per-pair bias is fully
            % present at every epoch rather than being averaged down. pairR is UNIFORM on
            % this path, so the scale cancelled out of the estimate and the sole casualty
            % was the reported relClockFormalSigma_m, which ran sqrt(7.37) = 2.72x high.
            g = @(p,d) revgnss.SwarmRelativeSolver.getNum_(cfg, p, d);
            thermalSigma = g({'multiAsset','twoWayTimeTransferISL','sigma_m'}, 0.03);
            sConst = g({'multiAsset','twoWayTimeTransferISL','delayCal','sigma_const_m'}, 0.01);
            sRW    = g({'multiAsset','twoWayTimeTransferISL','delayCal','sigma_rw_m'}, 0.003);
            Rii    = thermalSigma^2 + sConst^2 + sRW^2;
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
