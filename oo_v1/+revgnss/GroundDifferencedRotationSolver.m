classdef GroundDifferencedRotationSolver
    % GroundDifferencedRotationSolver  Recovers the ONE thing inter-satellite ranging can never see.
    %
    % THE PROBLEM. Two-way ISL ranging observes |r_i - r_k| only. A rigid ROTATION of the whole
    % formation leaves every one of those distances identically unchanged -- measured directly, the
    % range Jacobian along a rotation direction is 1.0e-16, i.e. machine zero. So the formation
    % SHAPE is observable and its ORIENTATION is not, at any epoch, to any precision, from any
    % number of crosslinks. revgnss.SwarmRelativeSolver therefore leaves the solved geometry in
    % whatever orientation the per-asset EKF priors happened to supply, and that orientation is set
    % by the GROUND link: sigma_theta ~ sigma_abs / (R*sqrt(N)). At R = 1083 m, N = 20 and the
    % ~2.4 m per-satellite absolute accuracy of a federated run that is ~0.028 deg, which puts
    % ~0.75 m of rim displacement into the beamforming phase with every baseline error at zero.
    %
    % THE OBSERVABLE. Orientation is only recoverable from something Earth-referenced. For one
    % ground tower m and two satellites i, j the between-satellite single difference
    %       SD_ij,m = rho_i,m - rho_j,m
    % is sensitive to orientation through  d(SD)/d(theta) = (b_ij x u_m),  b_ij the baseline and
    % u_m the line of sight. Differencing a SECOND time across towers,
    %       DD_ij,ml = SD_ij,m - SD_ij,l
    % is what this class actually forms, because the double difference removes, exactly and without
    % estimating anything:
    %   * the tower clock          (already gone in the single difference -- same tower, both sats)
    %   * the tower survey error   (same tower; drawn once in finalizeConfig, identical per asset)
    %   * the per-satellite DIFFERENTIAL CLOCK, which is otherwise one free parameter per satellite
    %     per epoch (19 x 3601 = 68 439 nuisance parameters at G5S20R4) -- this is the reason DD is
    %     preferred over SD here, not a marginal noise argument
    %   * the per-satellite constant receiver code/group delay
    % The price is sensitivity: |u_m - u_l| <= 0.23 because the 5 golden towers span only 13.1 deg
    % as seen from GEO. Measured trade (scratch CRLB, N=20): DD is ~15% worse than an SD that is
    % handed a perfect clock, and BETTER than an SD that must estimate the code bias. DD wins.
    %
    % WHY THE OBSERVABLE IS RE-SYNTHESISED. Nothing measurement-side survives a federated run --
    % +data/SimulationDataStore.m builds entry.measurements.{z,h,prefitInnovation,...} as a local
    % struct and storeEntry_ never reads it, and storeSnapshot has no production caller. There is no
    % stored pseudorange, residual, visible-tower list or elevation to difference. This class
    % therefore rebuilds the tower->satellite observable from the recorded TRUTH the same way
    % revgnss.TruthEndpointReplay lets the ISL layer drive the real four-timestamp chain: truth
    % centre of mass + truth attitude -> antenna phase centre -> geometry. Truth enters the
    % OBSERVABLE (which is what a real receiver measures); it never enters the ESTIMATOR, which
    % sees only the observable and the ISL-solved geometry.
    %
    % ATMOSPHERE -- READ THIS BEFORE BELIEVING ANY NUMBER THIS CLASS PRINTS.
    % Physically, two satellites 2 km apart at GEO viewing one tower look through the same air: the
    % ray paths diverge by 2000/36e6 rad = 11 arcsec, which is 0.5 m of separation at the top of the
    % troposphere and 18 m at a 350 km ionospheric pierce point -- far inside the decorrelation
    % scale of either. The deterministic part of the modelled atmosphere depends on the satellite
    % ONLY through the elevation angle, so at 11 arcsec it differences away to 0.006-1.6 mm, which
    % is 200-600x below the code noise. That is why no atmosphere term is evaluated below.
    % BUT the simulator does NOT model it that way. Every asset owns its own models.errors.
    % EnvironmentModel, seeded per asset (+revgnss/IndependentFleetScenarioFactory.m:44), and the
    % RngRegistry key has no asset field -- so with cfg.atmosphere.realistic = true each satellite
    % draws an INDEPENDENT tropo/iono/scintillation realisation and the difference carries
    % sqrt(2) x (0.05-0.10 m tropo GM + 0.34-0.62 m iono GM + 0.34-2.12 m scintillation), three
    % orders of magnitude above the geometric residual, with Gauss-Markov correlation times
    % (600 s iono, 10800 s tropo) that make it average almost not at all. That is a MODELLING
    % ARTEFACT of treating a 2 km formation as N uncorrelated single satellites, not physics.
    % differentialAtmosphereSigma_m exists to inject it deliberately so the cost can be measured;
    % it defaults to 0, i.e. the physically correct common-mode case.
    %
    %   out = revgnss.GroundDifferencedRotationSolver.solve(cfg, results, rel)
    %       out.applicable        false when the gate is off or a guard fails (reason recorded)
    %       out.reason            named blocker, never silent
    %       out.solvedPos         [3 x N x nEp] rel.solvedPos after the rotation correction
    %       out.theta_rad         [3 x 1] estimated rotation correction (estimated frame -> Earth)
    %       out.thetaSigma_rad    [3 x 1] formal 1-sigma from the least squares
    %       out.nObs              number of double differences actually used
    %       out.condition         condition number of the 3x3 normal matrix (geometry health)

    properties (Constant, Access = private)
        MIN_TOWERS = 2;      % a double difference needs at least two simultaneously visible towers
        GN_ITERS   = 2;      % the DD is near-linear in a sub-degree rotation; 2 passes is ample
    end

    methods (Static)

        function out = solve(cfg, results, rel)
            out = revgnss.GroundDifferencedRotationSolver.emptyOut_();
            G = revgnss.GroundDifferencedRotationSolver;

            if ~G.getBool_(cfg, {'multiAsset','groundDifferencedRotation','enable'}, false)
                out.reason = 'gateOff'; return
            end
            if ~isstruct(rel) || ~isfield(rel,'solvedPos') || isempty(rel.solvedPos)
                % solvedPos only exists when the ISL shape gate ran (SwarmRelativeSolver line 286).
                out.reason = 'noSolvedPos:requires multiAsset.twoWayISL.enable'; return
            end
            N = size(rel.solvedPos, 2); nEp = size(rel.solvedPos, 3);
            if N < 3
                out.reason = 'needAtLeast3Assets'; return
            end
            tVec = rel.time_s(:).';
            if numel(tVec) ~= nEp
                out.reason = 'timeGridMismatch'; return
            end

            % --- Observable + guards (shared with revgnss.JointGeometrySolver) ---------------
            obs = revgnss.GroundDifferencedRotationSolver.buildObservable(cfg, results, tVec, N);
            if ~obs.ok; out.reason = obs.reason; return; end
            out = revgnss.GroundDifferencedRotationSolver.solveRotationOnly_( ...
                cfg, rel, out, obs, N, nEp);
        end

        function obs = buildObservable(cfg, results, tVec, N)
            % buildObservable  Re-synthesise the tower->satellite code observable from recorded
            % truth, and return it with its visibility mask. Extracted so the 3-parameter
            % rotation solve above and revgnss.JointGeometrySolver consume ONE physics path
            % rather than two drifting copies of it.
            %
            % Truth enters the OBSERVABLE, which is what a real receiver measures. It never
            % enters an estimator: callers see only rhoObs and the tower positions.
            G = revgnss.GroundDifferencedRotationSolver;
            obs = struct('ok', false, 'reason', 'notAttempted', 'rhoObs', [], ...
                'rhoTruth', [], 'atmDiff', [], 'visTw', [], ...
                'towerPos', zeros(3,0), 'nTw', 0, 'codeSigma_m', NaN, ...
                'multipathSigma_m', NaN, 'differentialAtmosphereSigma_m', NaN, ...
                'leverPred_ecef', [], 'leverArmMode', 'none', ...
                'leverArm_body_m', [0;0;0], 'leverArmDdSystematic_m', NaN, ...
                'leverArmDdMax_m', NaN, 'leverArmDdUncorrected_m', NaN, ...
                'leverArmReason', '');
            nEp = numel(tVec);

            % Attitude is REQUIRED: truthTraj is the centre of mass, and the receive antenna sits
            % on a lever arm. At the sub-metre level this observable is trying to see, a metre-class
            % antenna offset per satellite would swamp the rotation signature entirely.
            if ~isstruct(results) || ~isfield(results,'asset') || numel(results.asset) < N
                obs.reason = 'noAssetPayload:requires results.asset{1..N}'; return
            end
            for i = 1:N
                if ~revgnss.TruthEndpointReplay.isUsable(results.asset{i}, nEp)
                    obs.reason = sprintf('asset%d:%s', i, ...
                        revgnss.TruthEndpointReplay.unusableReason(results.asset{i}, nEp));
                    return
                end
            end
            [towerPos, nTw] = G.towerPositions_(cfg);
            if nTw < G.MIN_TOWERS
                obs.reason = sprintf('needAtLeast%dTowers', G.MIN_TOWERS); return
            end

            replay = cell(1,N);
            for i = 1:N
                replay{i} = revgnss.TruthEndpointReplay(results.asset{i}, nEp, tVec);
            end
            lever = G.leverArm_(cfg);
            mask  = G.getNum_(cfg, {'estimator','elevationMask_rad'}, 5*pi/180);

            % --- LEVER-ARM SYMMETRY (execution plan B1) -------------------------------------
            % THE DEFECT THIS REPLACES. The observable below is built at the receive ANTENNA
            % PHASE CENTRE -- truth centre of mass rotated by the truth attitude onto the lever
            % arm -- which is right, because that is where a real receiver's signal arrives.
            % Every consumer then predicted the same range from rel.solvedPos, which is a CENTRE
            % OF MASS quantity, with no lever arm at all. The offset is common-mode only in the
            % sense that all satellites carry the SAME body-frame lever; it does NOT cancel in a
            % between-satellite difference, because the single difference retains L.(u_i - u_j).
            % Sized on the real layouts that is 0.048 mm at b = 1800 m and 0.180 mm at the
            % 6724 m run22 maximum -- above the 0.135 mm class-B bar with IDENTICAL attitudes on
            % every satellite. Worse, it is LINEAR IN THE BASELINE, exactly like the rotation
            % signature, so it ALIASES ONTO ROTATION instead of averaging away.
            %
            % THE FIX IS SYMMETRY, NOT A CORRECTION TERM. Two modes, and no third:
            %   'estimatedAttitude' -- observable uses TRUTH attitude, prediction uses the
            %       per-asset EKF's ESTIMATED attitude. The residual then carries only the
            %       attitude ERROR times the lever, which is a real, honestly-modelled error.
            %       This is what a real receiver could do: it knows its own attitude solution.
            %   'centreOfMass'      -- lever removed from BOTH sides. The residual carries no
            %       lever term at all. Used when the EKF does not estimate attitude, because the
            %       alternative would be to re-introduce the asymmetry under a different name.
            % Never mixed. leverArmMode is exported so no consumer has to guess.
            [leverMode, leverPred, leverReason] = G.predictionLeverArms_(cfg, results, lever, N, nEp);
            if strcmp(leverMode, 'centreOfMass')
                leverObs = [0;0;0];
            else
                leverObs = lever;
            end
            obs.leverArmMode    = leverMode;
            obs.leverArm_body_m = leverObs;
            if ~isempty(leverReason); obs.leverArmReason = leverReason; end

            % --- Truth antenna phase centres, per epoch -------------------------------------
            Atruth     = nan(3, N, nEp);
            leverTruth = zeros(3, N, nEp);
            for k = 1:nEp
                for i = 1:N
                    replay{i}.seek(k);
                    % Same helper the measurement path uses (ZYX, C_ref_body = Rz*Ry*Rx) rather
                    % than a local re-derivation -- an Euler convention mismatch here would show
                    % up as a per-satellite metre-class offset, i.e. exactly the signal we want.
                    Atruth(:,i,k) = revgnss.AttitudeKinematics.applyLeverArm( ...
                        replay{i}.r_ecef_m, replay{i}.attitude_euler_rad, leverObs);
                    leverTruth(:,i,k) = Atruth(:,i,k) - replay{i}.r_ecef_m;
                end
            end

            % --- Observable noise -----------------------------------------------------------
            % White thermal plus a Gauss-Markov multipath term. The multipath correlation time
            % matters more than its sigma: at tau = 60 s a 3600 s arc carries 60 independent
            % multipath samples against 3600 thermal ones, so a 0.30 m coloured term is worth
            % 0.30*sqrt(tau/dt) = 2.3 m of white noise for averaging purposes.
            dt      = G.medianStep_(tVec);
            sigTh   = G.getNum_(cfg, {'multiAsset','groundDifferencedRotation','codeSigma_m'}, ...
                      G.getNum_(cfg, {'multiAsset','towerSecondary','code','sigma_m'}, 1.0));
            sigMp   = G.getNum_(cfg, {'multiAsset','groundDifferencedRotation','multipathSigma_m'}, 0.0);
            tauMp   = max(dt, G.getNum_(cfg, {'errors','multipath','coloredGM','tau_s'}, 60));
            sigAtm  = G.getNum_(cfg, ...
                      {'multiAsset','groundDifferencedRotation','differentialAtmosphereSigma_m'}, 0.0);
            tauAtm  = max(dt, G.getNum_(cfg, ...
                      {'multiAsset','groundDifferencedRotation','differentialAtmosphereTau_s'}, 600));
            seed0   = G.getNum_(cfg, {'simulation','seed'}, 42);

            % --- Build the OBSERVABLE once, before any iteration ----------------------------
            % The observable is a measurement: it depends on truth and on the noise realisation,
            % never on the current rotation estimate. Drawing it inside the Gauss-Newton loop
            % would re-randomise the data between iterations and the solve would chase noise.
            rsW  = RandStream('mt19937ar','Seed', seed0 + 91000);
            rsMp = RandStream('mt19937ar','Seed', seed0 + 92000);
            rsAt = RandStream('mt19937ar','Seed', seed0 + 93000);
            aMp  = exp(-dt/tauMp);   qMp  = sigMp  * sqrt(max(0,1-aMp^2));
            aAtm = exp(-dt/tauAtm);  qAtm = sigAtm * sqrt(max(0,1-aAtm^2));
            mpS  = sigMp  * randn(rsMp, N, nTw);
            atS  = sigAtm * randn(rsAt, N, nTw);

            rhoObs   = nan(N, nTw, nEp);
            rhoTruth = nan(N, nTw, nEp);      % noise-free geometry, for the carrier probe
            atmDiff  = zeros(N, nTw, nEp);    % the differential-atmosphere realisation, so a
                                              % carrier observable can carry the SAME air column
            visTw    = false(nTw, nEp);
            for k = 1:nEp
                if k > 1
                    mpS = aMp*mpS + qMp*randn(rsMp, N, nTw);
                    atS = aAtm*atS + qAtm*randn(rsAt, N, nTw);
                end
                At = Atruth(:,:,k);
                for m = 1:nTw
                    seen = true;
                    for i = 1:N
                        if G.elevation_(towerPos(:,m), At(:,i)) < mask; seen = false; break; end
                    end
                    % A double difference needs the WHOLE satellite set on that tower; a tower
                    % visible to only part of the swarm cannot form a between-satellite pair.
                    if ~seen; continue; end
                    visTw(m,k) = true;
                    for i = 1:N
                        rhoTruth(i,m,k) = norm(At(:,i) - towerPos(:,m));
                        atmDiff(i,m,k)  = atS(i,m);
                        rhoObs(i,m,k)   = rhoTruth(i,m,k) + ...
                            sigTh*randn(rsW) + mpS(i,m) + atS(i,m);
                    end
                end
            end

            obs.ok = true; obs.reason = 'ok';
            obs.rhoObs = rhoObs; obs.rhoTruth = rhoTruth; obs.atmDiff = atmDiff; obs.visTw = visTw;
            obs.towerPos = towerPos; obs.nTw = nTw;
            obs.codeSigma_m = sigTh;
            obs.multipathSigma_m = sigMp;
            obs.differentialAtmosphereSigma_m = sigAtm;
            obs.leverPred_ecef = leverPred;

            % Size the residual lever-arm systematic that SURVIVES the fix, in the units of the
            % thing it corrupts: metres of double difference. This is the T3 acceptance number.
            % In 'centreOfMass' mode it is identically zero by construction; in
            % 'estimatedAttitude' mode it is the attitude ERROR projected on the lever and then
            % double-differenced, which is what an honest budget should contain.
            [obs.leverArmDdSystematic_m, obs.leverArmDdMax_m, obs.leverArmDdUncorrected_m] = ...
                G.leverArmDdResidual_(Atruth, leverTruth, leverPred, towerPos, visTw, N);
        end

        function A = predictedAntenna(obs, Pk, k)
            % predictedAntenna  Turn a predicted CENTRE-OF-MASS geometry into the predicted
            % ANTENNA PHASE CENTRES the observable is actually referenced to.
            %
            % Every consumer of buildObservable must call this instead of using Pk directly --
            % that asymmetry was execution-plan defect B1. The offset is a FIXED ECEF vector at
            % epoch k (it comes from the asset's own attitude solution, which is Earth-referenced
            % and therefore independent of the formation-rotation parameter being estimated), so
            % it does not enter the rotation Jacobian: the moment arm stays (P_i - centroid).
            A = Pk;
            if ~isstruct(obs) || ~isfield(obs,'leverPred_ecef') || isempty(obs.leverPred_ecef)
                return
            end
            L = obs.leverPred_ecef;
            if k < 1 || k > size(L,3); return; end
            A = Pk + L(:,:,k);
        end

        function out = solveRotationOnly_(cfg, rel, out, obs, N, nEp)
            % The historical 3-parameter solve. Kept because it is the thing that MEASURED the
            % shape-leakage coefficient; revgnss.JointGeometrySolver is the correct estimator.
            G = revgnss.GroundDifferencedRotationSolver;
            towerPos = obs.towerPos; rhoObs = obs.rhoObs; visTw = obs.visTw;
            nTw    = obs.nTw;
            sigTh  = obs.codeSigma_m;
            sigMp  = obs.multipathSigma_m;
            sigAtm = obs.differentialAtmosphereSigma_m;

            % --- Gauss-Newton on the 3-vector rotation --------------------------------------
            % Ntp (3 x 3N) is accumulated alongside the 3x3 normal matrix. It is the cross-
            % information between rotation and shape, and it is what turns the shape-leakage
            % coefficient from a hard-coded constant into a MEASURED property of this run
            % (execution-plan E3).
            theta = zeros(3,1); Nmat = zeros(3); Ntp = zeros(3,3*N); nObs = 0; sse = 0;
            Bshape = [];
            for iter = 1:G.GN_ITERS
                Nmat = zeros(3); gvec = zeros(3,1); Ntp = zeros(3,3*N);
                nObs = 0; sse = 0;
                Rth = G.rot_(theta);
                for k = 1:nEp
                    okTw = find(visTw(:,k)).';
                    if numel(okTw) < G.MIN_TOWERS; continue; end
                    Pk = rel.solvedPos(:,:,k);
                    if any(~isfinite(Pk(:))); continue; end
                    cP = mean(Pk,2);
                    Pe = cP + Rth*(Pk - cP);          % running rotation, about the EST centroid
                    % B1: predict at the ANTENNA, which is where the observable is formed. The
                    % offset comes from the asset's own (Earth-referenced) attitude estimate, so
                    % it does not turn with the formation-rotation parameter -- the moment arm in
                    % the Jacobian below stays (Pe_i - cP), the centre-of-mass offset.
                    Ae = revgnss.GroundDifferencedRotationSolver.predictedAntenna(obs, Pe, k);
                    if isempty(Bshape); Bshape = G.shapeBasis_(Pk, N); end

                    rhoP = zeros(N, nTw); uP = zeros(3, N, nTw);
                    for m = okTw
                        for i = 1:N
                            dP = Ae(:,i) - towerPos(:,m);
                            rhoP(i,m) = norm(dP);
                            uP(:,i,m) = dP / rhoP(i,m);
                        end
                    end
                    ref = okTw(1);
                    nDD = (numel(okTw)-1)*(N-1);
                    Jth = zeros(nDD,3); Jsh = zeros(nDD,3*N); rv = zeros(nDD,1); row = 0;
                    for m = okTw
                        if m == ref; continue; end
                        for i = 2:N
                            row = row + 1;
                            ddObs = (rhoObs(i,m,k)-rhoObs(1,m,k)) ...
                                  - (rhoObs(i,ref,k)-rhoObs(1,ref,k));
                            ddPrd = (rhoP(i,m)-rhoP(1,m)) - (rhoP(i,ref)-rhoP(1,ref));
                            % d(rho)/d(theta) = u'*(theta x p) = (p x u)'*theta, p about cP
                            Jth(row,:) = (cross(Pe(:,i)-cP, uP(:,i,m))   - cross(Pe(:,1)-cP, uP(:,1,m)) ...
                                        - cross(Pe(:,i)-cP, uP(:,i,ref)) + cross(Pe(:,1)-cP, uP(:,1,ref))).';
                            Jsh(row, 3*(i-1)+(1:3)) =  (uP(:,i,m) - uP(:,i,ref)).';
                            Jsh(row, 1:3)           = -(uP(:,1,m) - uP(:,1,ref)).';
                            rv(row) = ddObs - ddPrd;
                        end
                    end
                    if row < 1; continue; end
                    Jth = Jth(1:row,:); Jsh = Jsh(1:row,:); rv = rv(1:row);
                    Nmat = Nmat + (Jth.'*Jth); gvec = gvec + (Jth.'*rv);
                    Ntp  = Ntp  + (Jth.'*Jsh);
                    sse  = sse + (rv.'*rv); nObs = nObs + row;
                end
                if nObs < 3; out.reason = 'tooFewDoubleDifferences'; return; end
                if rcond(Nmat) < 1e-12; out.reason = 'rotationGeometrySingular'; return; end
                theta = theta + Nmat \ gvec;
            end

            % Formal sigma from the post-fit scatter, not from an assumed sigma: the DD carries
            % thermal + multipath + whatever differential atmosphere was injected, and only the
            % residuals know the total.
            dof   = max(1, nObs - 3);
            s2    = sse / dof;
            Cth   = s2 * inv(Nmat);                                          %#ok<MINV>

            % --- SHAPE LEAKAGE GUARD -- the reason this stage is not safe to leave on ---------
            % This solver has exactly 3 free parameters and no shape freedom, so any DEFORMATION
            % error in rel.solvedPos that is correlated over the arc (which every EKF error is)
            % projects straight onto the rotation. Measured on the stored G5S20R4 geometry by
            % injecting a known 0.02 deg rotation and a controlled arc-constant shape error:
            %     shape err   0.00 m -> recovered 0.0200 deg (exact)
            %                 0.01 m -> 0.0139
            %                 0.10 m -> 0.0338
            %                 1.00 m -> 0.2940
            %                 3.72 m -> 1.0966      (3.72 m is the real run16 deformation)
            % i.e. a stable ~0.3 deg of spurious rotation per metre of shape error, and the
            % geometry only carries ~0.02 deg of real rotation to begin with. CRITICALLY the
            % formal sigma below does NOT see this at all -- it sat at 0.004-0.008 deg per axis
            % in every one of those rows -- so an unguarded stage would report high confidence
            % while making the orientation an order of magnitude worse. Refuse to apply the
            % correction unless the predicted leakage is small against the rotation we can
            % actually measure; still report theta so the diagnostic is visible.
            % E3 -- the coefficient is MEASURED, not asserted. 0.30 deg/m was read off a
            % truth-injection experiment on one stored geometry and then hard-coded into a guard
            % that decides whether a correction is applied, on runs with different formations,
            % arc lengths and tower sets. The map from a shape perturbation to the spurious
            % rotation it produces is exactly inv(N_thth)*N_thp restricted to the shape subspace,
            % and both factors are already accumulated above. Quoted per metre of PER-POINT RMS
            % shape error, which is the unit shapeSigma is in: |dp| = s*sqrt(N) for an
            % orthonormal basis, so the operator norm carries a sqrt(N).
            leakDegPerMetre = 0.30; leakSource = 'legacyConstant';
            if ~isempty(Bshape) && rcond(Nmat) > 1e-12
                Lop = (Nmat \ Ntp) * Bshape;
                leakDegPerMetre = norm(Lop) * sqrt(N) * 180/pi;
                leakSource = 'marginalisedCovariance';
            end

            % E2 -- NO TRUTH. The previous fallback read rel.shapeErrSolved_m, which
            % revgnss.SwarmRelativeSolver computes against truthK. That is the worse of the two
            % truth leaks the execution plan names, because this value does not merely weight an
            % estimate -- it decides whether the estimate is used at all. And because
            % assumedShapeSigma_m was never declared in masterConfig while deepMergeConfig throws
            % on undeclared paths, the truth fallback was the ONLY executable path.
            shapeSigma = G.getNum_(cfg, ...
                {'multiAsset','groundDifferencedRotation','assumedShapeSigma_m'}, NaN);
            shapeSigmaSource = 'config';
            if ~isfinite(shapeSigma) || shapeSigma <= 0
                f = G.getNum_(rel, {'formalShapeSigma_m'}, NaN);
                if isfinite(f) && f > 0
                    shapeSigma = sqrt(3)*f;              % per-axis sigma -> per-point norm
                    shapeSigmaSource = 'islFormalCovariance';
                else
                    out.reason = ['noShapePrior: set multiAsset.groundDifferencedRotation.' ...
                        'assumedShapeSigma_m, or run the ISL shape layer so its formal ' ...
                        'covariance is published. There is deliberately no truth fallback, and ' ...
                        'no default -- an unset prior must fail loudly, because this value ' ...
                        'decides whether the correction is applied at all.'];
                    return
                end
            end
            out.shapeSigmaSource = shapeSigmaSource;
            out.leakDegPerMetre  = leakDegPerMetre;
            out.leakSource       = leakSource;
            sigTheta = norm(sqrt(abs(diag(s2 * inv(Nmat))))) * 180/pi;                %#ok<MINV>
            predLeak = leakDegPerMetre * shapeSigma;
            out.shapeSigmaUsed_m   = shapeSigma;
            out.predictedLeak_deg  = predLeak;
            out.rotationSigma_deg  = sigTheta;
            % A5: THREE outcomes, not two. This comparison decides whether a ~0.5 m geometry
            % correction is applied, and on the smoke fixture it sat at a 3 % margin -- close
            % enough that a 1e-14 arithmetic perturbation between a serial and a parallel run
            % flipped it and moved 33 of 148 reported fields, solvedPos by 0.55 m and the beam
            % spot by 3.8 km. A dead-band twelve orders of magnitude wider than that
            % perturbation makes the near-threshold case land deterministically on
            % 'indeterminate', which is the honest answer: the data cannot tell.
            deadBand = revgnss.GuardDecision.deadBandFor(cfg, ...
                {'multiAsset','jointGeometry','guardDeadBand'}, []);
            deadBand = revgnss.GuardDecision.deadBandFor(cfg, ...
                {'multiAsset','groundDifferencedRotation','guardDeadBand'}, deadBand);
            leakGuard = revgnss.GuardDecision.evaluate(predLeak, sigTheta, 'le', deadBand);
            out.leakGuard = leakGuard;
            out.leakMargin = leakGuard.margin;
            out.shapeLeakageDominates = ~leakGuard.pass;

            out.applicable     = true;
            out.reason         = 'ok';
            out.theta_rad      = theta;
            out.thetaSigma_rad = sqrt(abs(diag(Cth)));
            out.nObs           = nObs;
            out.condition      = cond(Nmat);
            out.codeSigma_m    = sigTh;
            out.multipathSigma_m = sigMp;
            out.differentialAtmosphereSigma_m = sigAtm;
            out.nTowers        = nTw;
            out.leverArmMode   = obs.leverArmMode;
            out.leverArmDdSystematic_m = obs.leverArmDdSystematic_m;
            out.leverArmDdMax_m        = obs.leverArmDdMax_m;
            out.leverArmDdUncorrected_m = obs.leverArmDdUncorrected_m;

            % Publish the corrected geometry so every downstream consumer of solvedPos
            % (RelativeErrorFigures, BeamformingPhasorDiagnostics, ...) sees the rotation fix --
            % but ONLY when the leakage guard above is satisfied. Leaving solvedPos untouched is
            % the correct failure mode: ranges already gave an orientation, and a shape-leakage-
            % dominated correction is measurably worse than doing nothing.
            if out.shapeLeakageDominates && ~G.getBool_(cfg, ...
                    {'multiAsset','groundDifferencedRotation','applyDespiteLeakage'}, false)
                out.reason    = sprintf(['shapeLeakage[%s]: predicted %.4f deg of spurious ' ...
                    'rotation from %.3f m shape error vs %.4f deg measurable -- %s -- ' ...
                    'correction NOT applied'], leakGuard.outcome, predLeak, shapeSigma, ...
                    sigTheta, leakGuard.text);
                out.solvedPos = rel.solvedPos;
                return
            end

            % SIGNIFICANCE GUARD. The leakage test above asks whether a SHAPE error could be
            % masquerading as rotation; it never asks whether the rotation is distinguishable
            % from ZERO. Measured on the 120 s smoke fixture: the stage estimated 0.159 deg
            % against a formal 0.125 deg -- SNR 1.2, i.e. consistent with noise -- passed the
            % leakage test, applied 2.5 m of rim displacement and made the relative geometry
            % 2.6x WORSE. Applying a statistically insignificant rotation is strictly harmful:
            % ranges already supplied an orientation, so the null action is not "no information",
            % it is "keep the better estimate". Same absolute-SNR discipline, and the same
            % config knob, as revgnss.JointGeometrySolver's acceptance test.
            snrRot = norm(theta) / max(norm(sqrt(abs(diag(Cth)))), realmin);
            out.rotationSnr = snrRot;
            minSnr = G.getNum_(cfg, {'multiAsset','jointGeometry','accept','minRotationSnr'}, 3);
            minSnr = G.getNum_(cfg, ...
                {'multiAsset','groundDifferencedRotation','accept','minRotationSnr'}, minSnr);
            snrGuard = revgnss.GuardDecision.evaluate(snrRot, minSnr, 'ge', deadBand);
            out.snrGuard = snrGuard;
            if ~snrGuard.pass
                out.reason = sprintf(['rotationSnr[%s]: %.4f deg estimated against a formal ' ...
                    '%.4f deg -- %s -- correction NOT applied'], snrGuard.outcome, ...
                    norm(theta)*180/pi, sigTheta, snrGuard.text);
                out.solvedPos = rel.solvedPos;
                return
            end
            corrected = rel.solvedPos;
            Rm = G.rot_(theta);
            for k = 1:nEp
                Pk = rel.solvedPos(:,:,k);
                if any(~isfinite(Pk(:))); continue; end
                c = mean(Pk,2);
                corrected(:,:,k) = c + Rm*(Pk - c);
            end
            out.solvedPos = corrected;
        end
    end

    methods (Static, Access = private)

        function o = emptyOut_()
            o = struct('applicable', false, 'reason', 'notAttempted', 'solvedPos', [], ...
                'theta_rad', [0;0;0], 'thetaSigma_rad', [NaN;NaN;NaN], 'nObs', 0, ...
                'condition', NaN, 'codeSigma_m', NaN, 'multipathSigma_m', NaN, ...
                'differentialAtmosphereSigma_m', NaN, 'nTowers', 0, ...
                'shapeSigmaUsed_m', NaN, 'predictedLeak_deg', NaN, ...
                'rotationSigma_deg', NaN, 'shapeLeakageDominates', false, ...
                'leverArmMode', 'none', 'leverArmDdSystematic_m', NaN, ...
                'leverArmDdMax_m', NaN, 'leverArmDdUncorrected_m', NaN, ...
                'leakDegPerMetre', NaN, ...
                'leakSource', 'notAttempted', 'shapeSigmaSource', 'notAttempted', ...
                'rotationSnr', NaN, 'leakMargin', NaN, ...
                'leakGuard', struct('outcome','notAttempted'), ...
                'snrGuard', struct('outcome','notAttempted'));
        end

        function B = shapeBasis_(Pk, N)
            % shapeBasis_  Orthonormal basis of the 3N-6 SHAPE subspace at one epoch: translation
            % and rotation removed. Used only to restrict the E3 leakage operator -- a rigid
            % rotation of the geometry is not a "shape error" and must not be charged as one.
            q = Pk - mean(Pk,2);
            G = zeros(3*N,3); T = repmat(eye(3), N, 1);
            for i = 1:N
                G(3*(i-1)+(1:3),:) = ...
                    -[0 -q(3,i) q(2,i); q(3,i) 0 -q(1,i); -q(2,i) q(1,i) 0];
            end
            B = null([G, T].');
        end

        function R = rot_(th)
            % Small-angle-exact rotation from a rotation vector (Rodrigues).
            t = norm(th);
            if t < 1e-14; R = eye(3); return; end
            k = th/t; K = [0 -k(3) k(2); k(3) 0 -k(1); -k(2) k(1) 0];
            R = eye(3) + sin(t)*K + (1-cos(t))*(K*K);
        end

        function [P, n] = towerPositions_(cfg)
            % Nominal ECEF tower positions. The survey error is deliberately NOT applied: it is
            % drawn once in finalizeConfig from its own seed and is therefore IDENTICAL for every
            % asset, so it cancels exactly in the between-satellite difference. (It is also absent
            % from the cfg saved in the swarm .mat, which is pre-finalizeConfig.)
            P = zeros(3,0); n = 0;
            if ~isfield(cfg,'towers'); return; end
            nT = numel(cfg.towers);
            if isfield(cfg,'scenario') && isfield(cfg.scenario,'nTowers')
                nT = min(nT, round(cfg.scenario.nTowers));
            end
            P = zeros(3,nT);
            for k = 1:nT
                P(:,k) = models.frames.GeometryUtils.geodetic2ecef( ...
                    cfg.towers(k).lat_rad, cfg.towers(k).lon_rad, cfg.towers(k).alt_m);
            end
            n = nT;
        end

        function e = elevation_(towerEcef, satEcef)
            up = towerEcef / norm(towerEcef);
            d  = satEcef - towerEcef;
            e  = asin(max(-1, min(1, (up.'*d) / norm(d))));
        end

        function [mode, leverPred, reason] = predictionLeverArms_(cfg, results, lever, N, nEp)
            % predictionLeverArms_  Per-(asset, epoch) ECEF lever-arm offset built from the
            % ESTIMATED attitude, i.e. from a quantity a real spacecraft actually has.
            %
            % Returns 'centreOfMass' with a zero offset whenever the estimated attitude is not
            % available for every asset over every epoch. That is deliberate and is the whole
            % point of B1: the failure mode is SYMMETRY LOSS, so the fallback must remove the
            % lever from both sides rather than leave the prediction short of it.
            G = revgnss.GroundDifferencedRotationSolver;
            leverPred = zeros(3, N, nEp); reason = '';
            want = G.getStr_(cfg, {'multiAsset','groundDifferencedRotation','leverArm','mode'}, 'auto');
            if strcmpi(want, 'centreOfMass')
                mode = 'centreOfMass'; reason = 'configForced'; return
            end
            if norm(lever) == 0
                mode = 'centreOfMass'; reason = 'zeroLeverArm'; return
            end
            euler = cell(1,N);
            for i = 1:N
                [e, why] = G.estimatedEuler_(results, i, nEp);
                if isempty(e)
                    if strcmpi(want, 'estimatedAttitude')
                        error('revgnss:GroundDifferencedRotation:noEstimatedAttitude', ...
                            ['leverArm.mode = ''estimatedAttitude'' was requested but asset %d ' ...
                             'has no usable attitude estimate (%s). Set leverArm.mode = ' ...
                             '''centreOfMass'' to remove the lever arm from BOTH the observable ' ...
                             'and the prediction instead.'], i, why);
                    end
                    mode = 'centreOfMass';
                    reason = sprintf('asset%d:%s', i, why);
                    return
                end
                euler{i} = e;
            end
            mode = 'estimatedAttitude';
            for k = 1:nEp
                for i = 1:N
                    C = revgnss.AttitudeKinematics.bodyToEcefRotation(euler{i}(:,k));
                    leverPred(:,i,k) = C * lever(:);
                end
            end
        end

        function [e, why] = estimatedEuler_(results, i, nEp)
            % estimatedEuler_  [3 x nEp] attitude estimate for asset i, or [] with a named reason.
            %
            % The attitude source is history.nominalQuat_wxyz, which logStep writes under
            % BOTH parameterizations (the nominal quaternion in quaternionErrorState mode,
            % eulerToQuatZYX(x) in eulerZYX mode). The euler rows of history.x are NOT a
            % usable attitude when that quaternion history exists: under quaternionErrorState
            % (the default) they hold the post-reset MEKF ERROR state — identically zero at
            % every epoch — which passes every finiteness guard and would place the lever
            % prediction at IDENTITY attitude while the observable carries the truth
            % attitude, re-creating the exact B1 asymmetry this mode exists to remove.
            e = []; why = '';
            if ~isfield(results,'asset') || numel(results.asset) < i
                why = 'noAssetPayload'; return
            end
            a = results.asset{i};
            if ~isstruct(a) || ~isfield(a,'history')
                why = 'noHistory'; return
            end
            if isfield(a.history,'nominalQuat_wxyz') && ~isempty(a.history.nominalQuat_wxyz)
                q = a.history.nominalQuat_wxyz;
                if ndims(q) ~= 3 || size(q,1) ~= 4
                    why = 'quatHistoryBadShape'; return
                end
                if size(q,3) < nEp
                    why = sprintf('attitudeHistoryShort:%d<%d', size(q,3), nEp); return
                end
                e = zeros(3, nEp);
                for k = 1:nEp
                    qk = q(:,1,k);
                    if ~all(isfinite(qk)) || norm(qk) < 0.5
                        e = []; why = 'attitudeQuatHistoryInvalid'; return
                    end
                    e(:,k) = revgnss.AttitudeErrorStateKinematics.quatToEulerZYX(qk);
                end
                return
            end
            % Legacy payloads only (predating the quaternion history): the euler rows of
            % history.x carried the attitude on the eulerZYX path.
            if ~isfield(a,'stateMap') || ~isfield(a.history,'x') || isempty(a.history.x)
                why = 'noHistory'; return
            end
            sm = a.stateMap;
            if ~isfield(sm,'euler_idx') || isempty(sm.euler_idx)
                why = 'attitudeNotEstimated'; return
            end
            idx = sm.euler_idx(:).';
            if numel(idx) ~= 3 || max(idx) > size(a.history.x,1)
                why = 'eulerIdxOutOfRange'; return
            end
            e = a.history.x(idx, :);
            if size(e,2) < nEp
                e = []; why = sprintf('attitudeHistoryShort:%d<%d', size(e,2), nEp); return
            end
            e = e(:, 1:nEp);
            if any(~isfinite(e(:)))
                e = []; why = 'attitudeHistoryNonFinite'; return
            end
            % An estimated attitude is never exactly zero at every epoch; an all-zero
            % block is the quaternionErrorState error-state signature on a payload that
            % lost its quaternion history. Refuse it so leverArm_ falls back to the
            % symmetric centreOfMass mode instead of an identity-attitude lever.
            if all(e(:) == 0)
                e = []; why = 'eulerHistoryAllZeroLikelyErrorState'; return
            end
        end

        function [rmsDd, maxDd, rmsRaw] = leverArmDdResidual_(Atruth, leverTruth, leverPred, ...
                towerPos, visTw, N)
            % leverArmDdResidual_  What the lever arm costs the double difference, before and
            % after B1.
            %
            % AFTER  dL_i = C(euler_truth_i)*L - C(euler_est_i)*L, the residual misplacement of
            %        satellite i's phase centre once the prediction also carries a lever.
            % BEFORE dL_i = C(euler_truth_i)*L, i.e. the prediction at the CENTRE OF MASS with
            %        no lever at all -- the defect as it stood. Reported alongside, because a
            %        fix whose "after" is machine zero is only convincing next to its "before".
            %
            % Both are the DD of the LOS projection, evaluated on the TRUTH lines of sight --
            % the same construction the B1 analysis used to size the defect (0.048 mm at
            % b = 1800 m, 0.180 mm at the 6724 m run22 maximum). In 'centreOfMass' mode both
            % levers are zero and both numbers are exactly 0, which is the point of that mode:
            % symmetry, not a correction term.
            rmsDd = 0; maxDd = 0; rmsRaw = 0;
            if isempty(leverPred) || isempty(leverTruth); return; end
            nEp = size(Atruth,3); nTw = size(towerPos,2);
            acc = 0; accRaw = 0; nAcc = 0;
            for k = 1:nEp
                okTw = find(visTw(:,k)).';
                if numel(okTw) < 2; continue; end
                u = zeros(3,N,nTw);
                for m = okTw
                    for i = 1:N
                        d = Atruth(:,i,k) - towerPos(:,m);
                        u(:,i,m) = d / norm(d);
                    end
                end
                dL  = leverTruth(:,:,k) - leverPred(:,:,k);
                dL0 = leverTruth(:,:,k);
                ref = okTw(1);
                for m = okTw
                    if m == ref; continue; end
                    du1 = u(:,1,m)-u(:,1,ref);
                    for i = 2:N
                        dui = u(:,i,m)-u(:,i,ref);
                        v  = dui.'*dL(:,i)  - du1.'*dL(:,1);
                        v0 = dui.'*dL0(:,i) - du1.'*dL0(:,1);
                        acc = acc + v^2; accRaw = accRaw + v0^2; nAcc = nAcc + 1;
                        maxDd = max(maxDd, abs(v));
                    end
                end
            end
            if nAcc > 0
                rmsDd = sqrt(acc/nAcc); rmsRaw = sqrt(accRaw/nAcc);
            end
        end

        function v = getStr_(cfg, path, dflt)
            v = dflt; c = cfg;
            for i = 1:numel(path)
                if ~isstruct(c) || ~isfield(c, path{i}); return; end
                c = c.(path{i});
            end
            if ~isempty(c) && (ischar(c) || isstring(c)); v = char(c); end
        end

        function L = leverArm_(cfg)
            % Receive antenna 1's body-frame lever arm, the same one MeasurementModel uses to
            % place the truth phase centre (cfg.asset.receiverLeverArms_body_m column 1, mirrored
            % into receiverLeverArm_body_m by masterConfig).
            L = [0;0;0];
            try
                L = cfg.asset.receiverLeverArms_body_m(:,1);
            catch
                try; L = cfg.asset.receiverLeverArm_body_m(:); catch; L = [0;0;0]; end
            end
            L = L(:);
            if numel(L) ~= 3 || ~all(isfinite(L)); L = [0;0;0]; end
        end

        function d = medianStep_(t)
            d = 1.0;
            if numel(t) >= 2; d = median(diff(t)); end
            if ~isfinite(d) || d <= 0; d = 1.0; end
        end

        function v = getBool_(cfg, path, dflt)
            v = revgnss.GroundDifferencedRotationSolver.getNum_(cfg, path, dflt);
            v = logical(v);
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
