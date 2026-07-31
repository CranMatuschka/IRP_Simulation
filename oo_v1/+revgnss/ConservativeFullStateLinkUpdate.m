classdef ConservativeFullStateLinkUpdate
    % ConservativeFullStateLinkUpdate  Extends a revgnss.SplitCovarianceIntersectionBound
    % 14-component owner-block bound (plan Section 2.2) to a full owner state vector of
    % arbitrary dimension nx >= 14, for use by a Section 2.3 distributed-ISL adapter. Pure
    % static math: no handle, no cfg read, no truth access, no I/O. Contains no per-observable
    % physics -- it consumes only matrices and a validated revgnss.OwnerPosteriorBoundResult.
    %
    % WHY A SEPARATE CLASS: revgnss.SplitCovarianceIntersectionBound is frozen at the 14-state
    % schema block (its validateArgs_ requires the owner prior to be exactly 14-by-14 in the
    % frozen v1 component order). A real per-satellite EKF's state is wider (ambiguities, gyro
    % bias, tower clocks, ...). This class assembles the FULL nx-by-nx posterior covariance from
    % the module's certified 14-block bound, without altering or re-deriving that module.
    %
    % THE FULL-STATE ASSEMBLY (re-derived from Young's/Jensen's inequality on the full owner
    % error, not merely on its 14-component schema sub-block). Partition the owner's full state
    % error e = [e_S; e_O] (schema block S, everything else O). For a link update that only
    % couples S to the observable (H_full = [H_S, 0]) with gain K_full = [K_S; 0]:
    %
    %   e_full^+ = (I - K_full*H_full)*e_full - K_full*Hj*e_j + K_full*v
    %            = T1 + T2 + T3
    %
    % T3 = K_full*v is exactly uncorrelated with T1 and T2 (v is the residual measurement noise
    % after every declared common/calibration source has been subtracted; for this adapter's
    % observable it is drawn from an isolated per-(link,epoch) random stream, so it is
    % structurally independent of every state error). For any w1+w2=1, 0<w1<1, Jensen's
    % inequality on t->t^2 gives, with NO assumption on any cross moment between e_full and e_j:
    %
    %   E[(T1+T2)(T1+T2)'] <= (1/w1)*E[T1*T1'] + (1/w2)*E[T2*T2']
    %
    % so
    %
    %   P+ = (1/w1)*(I-K_full*H_full)*P*(I-K_full*H_full)' + (1/w2)*K_full*(Hj*Pj*Hj')*K_full' ...
    %        + K_full*Rind*K_full'
    %
    % Loewner-dominates E[e_full^+ * e_full^+'] unconditionally. Because K_full and H_full are
    % zero outside S, (I-K_full*H_full) = blkdiag(I-K_S*H_S, I) exactly, so in block form:
    %
    %   P+(S,S) = (1/w1)*(I-K_S*H_S)*P(S,S)*(I-K_S*H_S)' + (1/w2)*K_S*(Hj*Pj*Hj')*K_S' + K_S*Rind*K_S'
    %           = EXACTLY revgnss.SplitCovarianceIntersectionBound's certified 14-block bound B,
    %             evaluated at (K_S, [w1 w2]) -- so the module's own PSD/domination proof
    %             transfers to this block without alteration.
    %   P+(S,O) = (1/w1)*(I-K_S*H_S)*P(S,O)
    %   P+(O,O) = (1/w1)*P(O,O)
    %
    % The (O,O) inflation by 1/w1 is NOT optional: a reported P+ with P+(O,O)=P(O,O) exactly
    % (no inflation) would need P+(S,O) = (I-K_S*H_S)*P(S,O) - K_S*Hj*E[e_j*e_O'] to be exact,
    % which is impossible for an unknown, possibly-nonzero E[e_j*e_O']. A PSD upper bound with a
    % ZERO (O,O) surplus therefore cannot carry any (S,O) surplus either (a PSD matrix with a
    % zero diagonal block must have a zero corresponding off-diagonal block) -- so leaving O
    % uninflated while still reporting P(S,O) uncorrected is not a valid bound. This is exactly
    % the defect this class's own regression test (see tests/) proves against.
    %
    % THE DIMENSIONAL RESCALING (congruence). revgnss.SplitCovarianceIntersectionBound's
    % positive-definiteness gate on the owner prior is an ABSOLUTE eigenvalue floor
    % (EigenvalueToleranceRelative * max(1,norm(Pi,'fro'))). A real 14-component owner block
    % mixes m^2, m^2/s^2, rad^2 and rad^2/s^2 magnitudes that can differ by 30 orders (e.g. an
    % undriven angular-rate state at ~1e-24 rad^2/s^2 next to a position variance at ~1e6 m^2),
    % so the module's own PD gate can reject every real owner prior even though it is
    % genuinely positive definite. rescaleBoundArgsToUnitDiagonal applies an EXACT congruence
    % D = diag(sqrt(diag(Pi))) (and D_j for the remote prior) before calling the module, and
    % unscaleBoundResult maps the reported gain/covariance back: this changes nothing about
    % what is certified (an exact congruence transform of a valid bound is a valid bound in the
    % original coordinates), only the conditioning the module's own PD/eigenvalue checks see.

    properties (Constant)
        RequiredCorrelationPolicy = 'splitCovarianceIntersection';
        RequiredBoundKind = 'psdUpperBoundUnderUnknownCrossCovariance';
        RequiredYoungTermCount = 2;
        UnitDiagonalTolerance = 1e-9;
    end

    methods (Static)
        function [scaledArgs, ownerScale, remoteScale] = rescaleBoundArgsToUnitDiagonal(boundArgs)
            % rescaleBoundArgsToUnitDiagonal  Exact congruence D=diag(sqrt(diag(Pi))),
            % Dj=diag(sqrt(diag(Pj))): Pi~ = D^-1*Pi*D^-1, Hi~ = Hi*D (likewise remote). Every
            % other field of boundArgs (measurement-space quantities) is untouched. ownerScale
            % and remoteScale are the diagonal vectors, required later by unscaleBoundResult.
            if ~isstruct(boundArgs) || ~isscalar(boundArgs) || ...
                    ~isfield(boundArgs,'ownerPriorCovariance_errorUnit2') || ...
                    ~isfield(boundArgs,'ownerJacobian_mPerErrorUnit') || ...
                    ~isfield(boundArgs,'remotePriorCovariance_errorUnit2') || ...
                    ~isfield(boundArgs,'remoteJacobian_mPerErrorUnit')
                error('ConservativeFullStateLinkUpdate:rescaleArgsSchema', ...
                    ['rescaleBoundArgsToUnitDiagonal requires a scalar struct with at least the ' ...
                    'owner/remote prior covariance and Jacobian fields.']);
            end

            Pi = boundArgs.ownerPriorCovariance_errorUnit2;
            ownerScale = sqrt(diag(Pi));
            if any(~isfinite(ownerScale)) || any(ownerScale <= 0)
                error('ConservativeFullStateLinkUpdate:ownerPriorDiagonalNotPositive', ...
                    'Every diagonal entry of the owner prior covariance must be finite and positive.');
            end
            Pj = boundArgs.remotePriorCovariance_errorUnit2;
            remoteScale = sqrt(diag(Pj));
            if any(~isfinite(remoteScale)) || any(remoteScale <= 0)
                error('ConservativeFullStateLinkUpdate:remotePriorDiagonalNotPositive', ...
                    'Every diagonal entry of the remote prior covariance must be finite and positive.');
            end

            Do = diag(ownerScale);
            DoInv = diag(1./ownerScale);
            Dj = diag(remoteScale);
            DjInv = diag(1./remoteScale);

            scaledArgs = boundArgs;
            scaledArgs.ownerPriorCovariance_errorUnit2 = (DoInv*Pi*DoInv + (DoInv*Pi*DoInv)')/2;
            scaledArgs.ownerJacobian_mPerErrorUnit = boundArgs.ownerJacobian_mPerErrorUnit*Do;
            scaledArgs.remotePriorCovariance_errorUnit2 = (DjInv*Pj*DjInv + (DjInv*Pj*DjInv)')/2;
            scaledArgs.remoteJacobian_mPerErrorUnit = boundArgs.remoteJacobian_mPerErrorUnit*Dj;
        end

        function [B, K] = unscaleBoundResult(boundResult, ownerScale)
            % unscaleBoundResult  Exact inverse congruence: B = D*B~*D, K = D*K~, where D is
            % built from ownerScale (the SAME vector rescaleBoundArgsToUnitDiagonal returned).
            if ~isa(boundResult,'revgnss.OwnerPosteriorBoundResult')
                error('ConservativeFullStateLinkUpdate:boundResultType', ...
                    'unscaleBoundResult requires a revgnss.OwnerPosteriorBoundResult.');
            end
            Do = diag(ownerScale(:));
            K = Do*boundResult.gain_errorUnitPerM;
            Btilde = boundResult.ownerPosteriorCovarianceReported_errorUnit2;
            B = Do*Btilde*Do;
            B = (B+B')/2;
        end

        function requireConservativeBoundResult(boundResult)
            % requireConservativeBoundResult  The type-level guard that forecloses feeding an
            % ownerPosteriorAssumingIndependence result (weights=[1 1], boundKind=
            % 'exactUnderAttestedIndependence') into assembleFullStateYoungBound: doing so would
            % silently reproduce a rule with NO (O,O)/(S,O) inflation, i.e. exactly the invalid
            % rule this class's own header proves is not a bound. Every check has its own
            % identifier so a caller can discriminate the exact reason.
            if ~isa(boundResult,'revgnss.OwnerPosteriorBoundResult')
                error('ConservativeFullStateLinkUpdate:boundResultType', ...
                    'requireConservativeBoundResult requires a revgnss.OwnerPosteriorBoundResult.');
            end
            if ~strcmp(boundResult.correlationPolicy, ...
                    revgnss.ConservativeFullStateLinkUpdate.RequiredCorrelationPolicy)
                error('ConservativeFullStateLinkUpdate:boundPolicyNotConservative', ...
                    'boundResult.correlationPolicy must be ''splitCovarianceIntersection''.');
            end
            if ~strcmp(boundResult.boundKind,revgnss.ConservativeFullStateLinkUpdate.RequiredBoundKind)
                error('ConservativeFullStateLinkUpdate:boundKindNotConservative', ...
                    'boundResult.boundKind must be ''psdUpperBoundUnderUnknownCrossCovariance''.');
            end
            if ~boundResult.isConservativeUpperBound
                error('ConservativeFullStateLinkUpdate:boundNotDeclaredConservative', ...
                    'boundResult.isConservativeUpperBound must be true.');
            end
            nTerms = revgnss.ConservativeFullStateLinkUpdate.RequiredYoungTermCount;
            if numel(boundResult.youngTermProvenance) ~= nTerms || ...
                    numel(boundResult.youngTermWeights) ~= nTerms
                error('ConservativeFullStateLinkUpdate:youngTermCountUnsupported', ...
                    'This class assembles only the two-term (owner-prior, remote-prior) case.');
            end
            w = boundResult.youngTermWeights;
            if abs(sum(w)-1) > 1e-9
                error('ConservativeFullStateLinkUpdate:weightsNotOnSimplex', ...
                    'youngTermWeights must sum to 1.');
            end
            if ~all(w > 0 & w < 1)
                error('ConservativeFullStateLinkUpdate:weightsNotStrictlyInterior', ...
                    'youngTermWeights must lie strictly inside the open simplex.');
            end
            if any(w < revgnss.SplitCovarianceIntersectionBound.WeightLowerBound - 1e-12)
                error('ConservativeFullStateLinkUpdate:weightBelowFrozenLowerBound', ...
                    'youngTermWeights must be at or above the frozen weight lower bound.');
            end
        end

        function P = assembleFullStateYoungBound(Pprior, schemaStateIndices, boundResult, H_owner, ownerScale)
            % assembleFullStateYoungBound  Produces the full nx-by-nx owner posterior covariance
            % described in this class's header. boundResult must be the OwnerPosteriorBoundResult
            % returned by calling revgnss.SplitCovarianceIntersectionBound.ownerPosteriorBound on
            % the RESCALED (unit-diagonal) 14-block -- checked structurally below, not merely
            % assumed, so a boundResult produced without rescaling (or rescaled twice) is refused
            % rather than silently mis-assembled.
            revgnss.ConservativeFullStateLinkUpdate.requireConservativeBoundResult(boundResult);

            PiFromResult = boundResult.ownerPriorCovariance_errorUnit2;
            if max(abs(diag(PiFromResult)-1)) > revgnss.ConservativeFullStateLinkUpdate.UnitDiagonalTolerance
                error('ConservativeFullStateLinkUpdate:boundResultNotUnitDiagonal', ...
                    ['assembleFullStateYoungBound requires a boundResult produced from a unit-' ...
                    'diagonal (rescaled) owner prior; the supplied result''s own prior diagonal is ' ...
                    'not unit, indicating it was not produced via rescaleBoundArgsToUnitDiagonal.']);
            end

            nx = size(Pprior,1);
            if ~isequal(size(Pprior),[nx nx]) || any(~isfinite(Pprior(:))) || ...
                    norm(Pprior-Pprior','fro') > 1e-8*max(1,norm(Pprior,'fro'))
                error('ConservativeFullStateLinkUpdate:priorNotSymmetricFinite', ...
                    'Pprior must be a finite, symmetric, square matrix.');
            end
            idxS = schemaStateIndices(:)';
            nSchema = numel(idxS);
            if nSchema ~= size(H_owner,2) || numel(unique(idxS)) ~= nSchema || ...
                    any(idxS < 1) || any(idxS > nx)
                error('ConservativeFullStateLinkUpdate:schemaIndicesInvalid', ...
                    'schemaStateIndices must be nSchema distinct indices into 1:nx matching H_owner''s width.');
            end
            idxO = setdiff(1:nx, idxS);

            [B, K] = revgnss.ConservativeFullStateLinkUpdate.unscaleBoundResult(boundResult, ownerScale);
            w1 = boundResult.youngTermWeights(1);

            IminusKH_S = eye(nSchema) - K*H_owner;

            P = Pprior;
            P(idxS, idxS) = B;
            if ~isempty(idxO)
                P(idxS, idxO) = (1/w1) * (IminusKH_S * Pprior(idxS, idxO));
                P(idxO, idxS) = P(idxS, idxO)';
                P(idxO, idxO) = (1/w1) * Pprior(idxO, idxO);
            end
            P = (P+P')/2;

            revgnss.ConservativeFullStateLinkUpdate.requireSchemaBlockMatchesCertifiedBound( ...
                P, idxS, B, 1e-9);
        end

        function requireSchemaBlockMatchesCertifiedBound(Passembled, schemaStateIndices, certifiedB, tolRel)
            idxS = schemaStateIndices(:)';
            block = Passembled(idxS, idxS);
            scale = max(1, norm(certifiedB,'fro'));
            if norm(block-certifiedB,'fro') > tolRel*scale
                error('ConservativeFullStateLinkUpdate:schemaBlockMismatch', ...
                    'The assembled schema block does not match the certified 14-block bound.');
            end
        end

        function requireSymmetricPsd(M, toleranceRelative, contextName)
            if nargin < 2 || isempty(toleranceRelative); toleranceRelative = 1e-8; end
            if nargin < 3 || isempty(contextName); contextName = 'matrix'; end
            if norm(M-M','fro') > 1e-8*max(1,norm(M,'fro'))
                error('ConservativeFullStateLinkUpdate:notSymmetric', ...
                    '%s must be symmetric.', contextName);
            end
            Msym = (M+M')/2;
            scale = max(1, max(abs(eig(Msym))));
            if min(eig(Msym)) < -toleranceRelative*scale
                error('ConservativeFullStateLinkUpdate:notPsd', ...
                    '%s must be positive semi-definite.', contextName);
            end
        end

        function w = declaredWeightsFromFullStateTraces(Pprior, schemaStateIndices, H_owner, K0, ...
                remoteContribution_m2)
            % declaredWeightsFromFullStateTraces  Water-fills the two Young-term weights against
            % the FULL-state trace a1 = trace((I-K0*H_owner)*P(S,S)*(I-K0*H_owner)') +
            % trace(P(O,O)) (not merely the 14-block trace), so the non-schema block's own size
            % is what the weight solver sees -- the module's own trace-minimising rule ignores
            % trace(P(O,O)) entirely, since it never sees O. K0 is any admissible seed gain (the
            % naive unweighted fold gain is the natural choice; see the class caller). The
            % independent-noise term Rind carries coefficient 1 always (never 1/w), exactly as
            % in SplitCovarianceIntersectionBound.termTraces_/gainAt_, so it plays no role in the
            % weight objective and is deliberately not a parameter here.
            idxS = schemaStateIndices(:)';
            nx = size(Pprior,1);
            idxO = setdiff(1:nx, idxS);
            IminusK0H = eye(numel(idxS)) - K0*H_owner;
            a1 = trace(IminusK0H*Pprior(idxS,idxS)*IminusK0H');
            if ~isempty(idxO)
                a1 = a1 + trace(Pprior(idxO,idxO));
            end
            a2 = trace(K0*remoteContribution_m2*K0');
            w = revgnss.SplitCovarianceIntersectionBound.waterFillWeights( ...
                [a1 a2], revgnss.SplitCovarianceIntersectionBound.WeightLowerBound);
        end

        function result = applyOwnerOnlyUpdate(args)
            % applyOwnerOnlyUpdate  Pure: returns values, mutates nothing (no ekf/sim handle is
            % ever touched here -- the caller is responsible for assigning the returned
            % xPosterior/PPosterior/nominalQuatPosterior onto its own owner filter). Applies the
            % state correction at the certified conservative gain K (from boundResult, mapped
            % back through ownerScale) and the full-state assembled posterior covariance, then
            % delegates the quaternion-mode attitude injection/covariance-reset step to
            % revgnss.LocalStateCorrectionInjection.applyWithAttitudeReset (plan Stage 3.2,
            % U29): the exact same math this method always computed (same injectRight call,
            % same skew-symmetric reset Jacobian I-0.5*[deltaTheta]_x, applied to the POSTERIOR
            % not the prior, in the same order), now shared with the Stage 3.2 exact pair-update
            % path so the two never drift apart. This method itself cannot be reused BY that
            % path: it requires a revgnss.OwnerPosteriorBoundResult, which the exact path
            % deliberately never produces.
            required = {'xPrior','PPrior','schemaStateIndices','boundResult','H_owner', ...
                'ownerScale','residual_m','attitudeParameterization','nominalQuatPrior'};
            missing = setdiff(required,fieldnames(args));
            if ~isempty(missing)
                error('ConservativeFullStateLinkUpdate:applyArgsSchema', ...
                    'applyOwnerOnlyUpdate is missing argument %s.',missing{1});
            end

            idxS = args.schemaStateIndices(:)';
            [~, K] = revgnss.ConservativeFullStateLinkUpdate.unscaleBoundResult( ...
                args.boundResult, args.ownerScale);

            PPriorForBound = revgnss.ConservativeFullStateLinkUpdate.assembleFullStateYoungBound( ...
                args.PPrior, idxS, args.boundResult, args.H_owner, args.ownerScale);

            stateCorrectionFull = zeros(size(args.xPrior));
            stateCorrectionFull(idxS) = K*args.residual_m;

            injected = revgnss.LocalStateCorrectionInjection.applyWithAttitudeReset(struct( ...
                'xPrior',args.xPrior,'PPosterior',PPriorForBound,'schemaStateIndices',idxS, ...
                'stateCorrection_full',stateCorrectionFull, ...
                'attitudeParameterization',args.attitudeParameterization, ...
                'nominalQuatPrior',args.nominalQuatPrior));

            result = struct( ...
                'xPosterior',injected.xPosterior, ...
                'PPosterior',injected.PPosterior, ...
                'nominalQuatPosterior',injected.nominalQuatPosterior, ...
                'gain_errorUnitPerM',K, ...
                'attitudeInjectionNorm_rad',injected.attitudeInjectionNorm_rad, ...
                'attitudeResetJacobian',injected.attitudeResetJacobian);
        end
    end
end
