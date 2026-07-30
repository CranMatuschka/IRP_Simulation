classdef SplitCovarianceIntersectionBound
    % SplitCovarianceIntersectionBound  Pure math for plan Section 2.2's conservative
    % correlation policy. Static-only, no state, no handle, no config read, no truth access,
    % no I/O -- matching DistributedLinkProtocolContract's frozen contract-class idiom.
    %
    % WHY THIS IS A NEW CLASS, NOT CODE INSIDE DistributedLinkUpdateAdapter/Block: both of
    % those classes' own header comments assert "contains NO physics/residual/Jacobian/
    % covariance computation anywhere in this file"; that assertion is exercised by
    % tests/test_stage2_communication_interfaces.m. A covariance computation added to either
    % file would falsify its own documented, tested contract. This module is observable-
    % agnostic (it takes only matrices, never a physical record), so Section 2.3's eventual
    % adapter can call the SAME proven function rather than re-deriving it.
    %
    % THE MATHEMATICAL CLAIM (see docs/plans/INDEPENDENT_FLEET_EKF_AND_TIMESTAMP_TWSTFT_PLAN.md
    % Section 2.2 and the approved design "Section 2.2 Design (Revision 2)" for the full
    % derivation). Owner error recursion:
    %
    %   e_i^+ = (I-K*Hi)*e_i - K*Hj*e_j + K*sum_g(w_g) + K*sum_k(u_k) + K*v
    %
    % Partition into n = 2+G+P unknown-cross-correlated terms (owner prior, remote prior, one
    % per declared common source, one per declared calibration owner) plus the residual
    % independent-noise term K*v, which is EXACTLY orthogonal to every other term by
    % construction (v is defined as whatever remains after every declared common/calibration
    % contribution has been subtracted from the total measurement covariance). The n-term
    % Young/Jensen inequality in the Loewner order (proved by a one-line Cauchy-Schwarz/Jensen
    % argument, valid for ANY weights in the open simplex and ANY joint second moment of the n
    % terms) then gives the reported bound:
    %
    %   B(K,omega) = (1/omega_1)*(I-K*Hi)*Pi*(I-K*Hi)' + (1/omega_2)*K*(Hj*Pj*Hj')*K'
    %              + sum_g (1/omega_{2+g})*K*W_g*K' + sum_k (1/omega_{2+G+k})*K*U_k*K'
    %              + K*Rind*K'
    %
    % with Rind := Rtotal - sum_g(W_g) - sum_k(U_k) constructed ONLY by subtraction (never
    % supplied directly), and Rtotal, W_g, U_k declared separately -- the module forms
    % Hj*Pj*Hj' itself and never accepts a pre-summed remote/common-source block, which is what
    % makes the additive-folding shortcut plan Section 2.2.2 forbids structurally
    % inexpressible here (see requireLoewnerDominates and the B1 regression guard in
    % tests/test_stage2_conservative_correlation_policy.m for the numerical counterexample this
    % closes: folding H_j*P_j*H_j' plus a correlated common source additively into one term
    % under-reports the true second moment by a factor up to n).
    %
    % VALIDITY is unconditional in (K,omega): B(K,omega) Loewner-dominates the true owner
    % posterior second moment for EVERY gain K of the right shape and EVERY weight vector omega
    % in the open bounded simplex, over the FULL admissible set of jointly-PSD cross moments
    % among the owner prior error, the remote prior error, every declared common-source error,
    % and every declared calibration error (no assumption on any of those cross moments beyond
    % joint PSD-ness). Tightness/optimality (selectGainAndWeights) only affects how CONSERVATIVE
    % the reported bound is, never whether it is a bound at all.

    properties (Constant)
        ErrorSignConvention = 'estimateMinusTruth';
        AdmissibleCrossCovarianceSet = 'allJointlyPsdCrossMomentsAcrossAllDeclaredTerms';
        AllowedCorrelationPolicies = {'splitCovarianceIntersection'};
        TestOnlyCorrelationPolicies = {'assumeIndependent'};
        AllowedWeightSelectionRules = { ...
            'traceMinimisingBoundedSimplexCoordinateDescent','fixedDeclaredWeights'};
        WeightLowerBound = 1e-6;
        MaximumYoungTerms = 64;
        MaximumWeightIterations = 8;
        RelativeObjectiveTolerance = 1e-12;
        SymmetryToleranceFrobenius = 1e-10;
        EigenvalueToleranceRelative = 1e-10;
        ShortFormAgreementToleranceRelative = 1e-8;
        AllowedCalibrationStateUnits = {'m'};
        % Plan Section 2.2 bullet 4: an observable is listed here only after its own adapter has
        % a dedicated reference-test set proving the four premises the bound formula itself
        % requires (Jacobian correctness, noise independence, R_total==R_ind exactly, and a
        % well-posed rank structure for that H) -- the Young/Jensen bound formula itself is
        % proven once, generically, for ARBITRARY K/weights/H (see describeDerivation /
        % tests/test_conservative_full_state_link_update.m's admissible-cross-covariance sweep),
        % so admitting a new observable here is a claim about ITS OWN H/R meeting those four
        % premises, never a re-proof of the formula.
        % 'coherentTwoWayCodeRange' (plan Section 2.3.1, revgnss.CoherentTwoWayRangeLinkUpdateAdapter;
        % see tests/test_conservative_full_state_link_update.m and
        % tests/test_coherent_two_way_range_link_update_adapter.m) and
        % 'firstOrderReciprocalClockTransfer' (plan Section 2.3.2,
        % revgnss.FirstOrderReciprocalClockTransferLinkUpdateAdapter; see
        % tests/test_first_order_reciprocal_clock_transfer_link_update_adapter.m -- analytic
        % Jacobian correctness vs an independent perturbation oracle, remoteContributionCovariance
        % _m2 == H_remote*P_remote*H_remote' exactly, exact common-mode-blind rank-1 clock
        % observability audit, and zero position/velocity sensitivity) are the only two entries.
        ObservablesWithDemonstratedConservativeBound = { ...
            'coherentTwoWayCodeRange','firstOrderReciprocalClockTransfer'};
    end

    methods (Static)
        function result = ownerPosteriorBound(args)
            % ownerPosteriorBound  Main entry: the conservative splitCovarianceIntersection
            % bound. Refuses correlationPolicy='assumeIndependent' by name (a different METHOD
            % NAME carries that test-only path, not a value of this one's input).
            if isstruct(args) && isfield(args,'correlationPolicy') && ...
                    (ischar(args.correlationPolicy) || isstring(args.correlationPolicy)) && ...
                    strcmp(char(args.correlationPolicy),'assumeIndependent')
                error('SplitCovarianceIntersectionBound:testOnlyPolicyRequested', ...
                    ['ownerPosteriorBound refuses correlationPolicy=''assumeIndependent''. Call ' ...
                    'ownerPosteriorAssumingIndependence with an explicit independence ' ...
                    'attestation instead; that is a different, guarded method.']);
            end
            [terms,Rind,checked] = revgnss.SplitCovarianceIntersectionBound.assembleYoungTerms_( ...
                args,'splitCovarianceIntersection');
            sigmaCell = {terms(2:end).matrix};
            [K,weights,diagnostics] = revgnss.SplitCovarianceIntersectionBound.selectGainAndWeights( ...
                checked.Pi,checked.Hi,sigmaCell,Rind,checked.weightSelectionRule,checked.declaredWeights);
            B = revgnss.SplitCovarianceIntersectionBound.evaluateBound(terms,Rind,K,weights,checked.Hi);
            contributions = revgnss.SplitCovarianceIntersectionBound.termContributions_( ...
                terms,K,checked.Hi);

            record = revgnss.SplitCovarianceIntersectionBound.buildResultRecord_( ...
                'splitCovarianceIntersection','psdUpperBoundUnderUnknownCrossCovariance', ...
                checked,terms,Rind,K,weights,diagnostics,B,contributions,true,struct());
            result = revgnss.OwnerPosteriorBoundResult(record);
        end

        function result = ownerPosteriorAssumingIndependence(args, independenceAttestation)
            % ownerPosteriorAssumingIndependence  TEST-ONLY guarded exact posterior under an
            % attested independence assumption (plan Section 2.2 bullet 3). Requires G=P=0
            % (declared common/calibration contributions refuse the attestation) and a positive
            % attestation struct the caller must construct explicitly; see
            % requireIndependenceAttestation_ for the full precondition list.
            [terms,Rind,checked] = revgnss.SplitCovarianceIntersectionBound.assembleYoungTerms_( ...
                args,'assumeIndependent');
            if numel(terms) ~= 2
                error('SplitCovarianceIntersectionBound:independenceNotAttested', ...
                    ['ownerPosteriorAssumingIndependence requires zero declared common-source ' ...
                    'and calibration contributions (G=P=0); a shared source cannot be attested ' ...
                    'independent of itself.']);
            end
            revgnss.SplitCovarianceIntersectionBound.requireIndependenceAttestation_( ...
                independenceAttestation);

            Sremote = terms(2).matrix;
            Stot = checked.Hi*checked.Pi*checked.Hi' + Sremote + Rind;
            Kind = checked.Pi*checked.Hi' / Stot;
            weightsOnes = [1 1];
            B = revgnss.SplitCovarianceIntersectionBound.evaluateBound( ...
                terms,Rind,Kind,weightsOnes,checked.Hi);
            contributions = revgnss.SplitCovarianceIntersectionBound.termContributions_( ...
                terms,Kind,checked.Hi);

            record = revgnss.SplitCovarianceIntersectionBound.buildResultRecord_( ...
                'assumeIndependent','exactUnderAttestedIndependence', ...
                checked,terms,Rind,Kind,weightsOnes,struct( ...
                    'objectiveTraceHistory_errorUnit2',NaN,'weightsClamped',false, ...
                    'iterationCount',0,'weightSolverBranch','exactUnderAttestedIndependence'), ...
                B,contributions,false,independenceAttestation);
            result = revgnss.OwnerPosteriorBoundResult(record);
        end

        function [terms, Rind] = assembleYoungTerms(args)
            % assembleYoungTerms  Public entry point: builds the ordered Young-term list and
            % Rind from declared inputs only. This is the ONLY place the term count is decided
            % -- callers cannot supply a pre-summed remote/common-source block (see class
            % header). Requires correlationPolicy='splitCovarianceIntersection'.
            [terms,Rind] = revgnss.SplitCovarianceIntersectionBound.assembleYoungTerms_( ...
                args,'splitCovarianceIntersection');
        end

        function [K, weights, diagnostics] = selectGainAndWeights( ...
                Pi, Hi, sigmaCell, Rind, rule, declaredWeights)
            % selectGainAndWeights  Bounded, deterministic gain/weight selection (design
            % Section A.6). VALIDITY of the reported bound never depends on this method's
            % output being optimal or even converged -- evaluateBound is a valid Loewner
            % upper bound at ANY feasible (K,weights). This method only controls tightness.
            nTerms = 1 + numel(sigmaCell);
            lowerBound = revgnss.SplitCovarianceIntersectionBound.WeightLowerBound;

            if strcmp(rule,'fixedDeclaredWeights')
                w = declaredWeights(:)';
                if numel(w) ~= nTerms
                    error('SplitCovarianceIntersectionBound:weightVectorLength', ...
                        'declaredWeights must have exactly %d entries for %d Young terms.', ...
                        nTerms,nTerms);
                end
                if any(~isfinite(w)) || any(w < lowerBound - 1e-12) || abs(sum(w)-1) > 1e-6
                    error('SplitCovarianceIntersectionBound:weightOutsideOpenSimplex', ...
                        'declaredWeights must sum to 1 with every entry at or above the frozen lower bound.');
                end
                K = revgnss.SplitCovarianceIntersectionBound.gainAt_(Pi,Hi,sigmaCell,Rind,w);
                weights = w;
                diagnostics = struct('objectiveTraceHistory_errorUnit2',NaN, ...
                    'weightsClamped',any(w <= lowerBound + 1e-9),'iterationCount',0, ...
                    'weightSolverBranch','fixedDeclaredWeights');
                return
            end
            if ~strcmp(rule,'traceMinimisingBoundedSimplexCoordinateDescent')
                error('SplitCovarianceIntersectionBound:weightSelectionRuleUnsupported', ...
                    'weightSelectionRule must be a frozen allowed rule.');
            end

            Tmax = revgnss.SplitCovarianceIntersectionBound.MaximumWeightIterations;
            tauRel = revgnss.SplitCovarianceIntersectionBound.RelativeObjectiveTolerance;

            % Seed: the naive (unweighted, coefficient-1) fold. This is a legitimate GAIN to
            % seed the iteration from; reporting its posterior directly (rather than iterating
            % to a genuine simplex weight vector) is precisely the shortcut plan Section 2.2.2
            % forbids, so it is used here only as K0.
            m = size(Rind,1);
            SigmaSum = zeros(m);
            for idx = 1:numel(sigmaCell); SigmaSum = SigmaSum + sigmaCell{idx}; end
            K = Pi*Hi' / (Hi*Pi*Hi' + SigmaSum + Rind);

            wPrev = ones(1,nTerms)/nTerms;
            branch = 'unclampedClosedForm';
            clamped = false;
            history = zeros(1,0);
            iterCount = 0;
            JPrev = Inf;

            for t = 1:Tmax
                a = revgnss.SplitCovarianceIntersectionBound.termTraces_(Pi,Hi,sigmaCell,K);
                d = trace(K*Rind*K');
                [wCandidate,br] = revgnss.SplitCovarianceIntersectionBound.waterFillWeights( ...
                    a,lowerBound);
                Jcandidate = sum(a./wCandidate) + d;
                Jkeep = sum(a./wPrev) + d;
                if t == 1 || Jcandidate <= Jkeep*(1+tauRel)
                    w = wCandidate; branch = br;
                else
                    iterCount = t-1;
                    break
                end
                clamped = clamped || any(w <= lowerBound + 1e-9);
                Jnew = sum(a./w) + d;
                history(end+1) = Jnew; %#ok<AGROW>
                Knew = revgnss.SplitCovarianceIntersectionBound.gainAt_(Pi,Hi,sigmaCell,Rind,w);
                iterCount = t;
                if abs(JPrev-Jnew) <= tauRel*max(1,abs(Jnew))
                    K = Knew; wPrev = w;
                    break
                end
                K = Knew; wPrev = w; JPrev = Jnew;
            end

            weights = wPrev;
            diagnostics = struct('objectiveTraceHistory_errorUnit2',history, ...
                'weightsClamped',clamped,'iterationCount',iterCount,'weightSolverBranch',branch);
        end

        function [w, branch] = waterFillWeights(a, lowerBound)
            % waterFillWeights  Exact bounded-simplex KKT solution (design Section A.6.2):
            % minimise sum(a_l/w_l) s.t. sum(w)=1, w_l>=lowerBound. Closed-form water-filling
            % omega_l = max(lowerBound, sqrt(a_l/lambda)), lambda found by monotone bisection.
            a = a(:)';
            n = numel(a);
            a(a < 0) = 0;
            if n*lowerBound >= 1
                error('SplitCovarianceIntersectionBound:tooManyYoungTerms', ...
                    'n*WeightLowerBound must be below 1 for a feasible simplex to exist.');
            end
            if all(a == 0)
                w = ones(1,n)/n;
                branch = 'uniformDegenerate';
                return
            end
            g = @(logLambda) sum(max(lowerBound,sqrt(a/exp(logLambda)))) - 1;
            loLo = -60; hiHi = 60;
            while g(loLo) <= 0 && loLo > -600; loLo = loLo - 60; end
            while g(hiHi) >= 0 && hiHi < 600; hiHi = hiHi + 60; end
            logLambda = fzero(g,[loLo hiHi]);
            lambda = exp(logLambda);
            wUnclamped = sqrt(a/lambda);
            w = max(lowerBound,wUnclamped);
            w = w / sum(w);
            if any(wUnclamped < lowerBound - 1e-12)
                branch = 'waterFilledActiveSet';
            else
                branch = 'unclampedClosedForm';
            end
        end

        function B = evaluateBound(terms, Rind, K, weights, Hi)
            % evaluateBound  The boxed formula of design Section A.4, evaluated explicitly
            % (never via the internal-consistency-only short form). Valid at ANY feasible
            % (K,weights) -- see class header.
            n = numel(terms);
            if numel(weights) ~= n
                error('SplitCovarianceIntersectionBound:weightVectorLength', ...
                    'weights must have one entry per Young term.');
            end
            nOwner = size(K,1);
            IminusKHi = eye(nOwner) - K*Hi;
            B = K*Rind*K';
            for idx = 1:n
                term = terms(idx);
                if strcmp(term.kind,'ownerPrior')
                    contribution = IminusKHi*term.matrix*IminusKHi';
                else
                    contribution = K*term.matrix*K';
                end
                B = B + contribution/weights(idx);
            end
            B = (B+B')/2;
        end

        function requireLoewnerDominates(upper, lower, tolRel)
            % requireLoewnerDominates  min(eig(sym(upper-lower))) >= -tolRel*scale. The single
            % PSD-comparison helper every conservative-bound test uses.
            if nargin < 3 || isempty(tolRel); tolRel = 1e-8; end
            if ~isequal(size(upper),size(lower)) || size(upper,1) ~= size(upper,2)
                error('SplitCovarianceIntersectionBound:loewnerShape', ...
                    'requireLoewnerDominates requires two equally sized square matrices.');
            end
            diffMat = upper-lower;
            diffMat = (diffMat+diffMat')/2;
            scale = max(1,max(abs(eig((upper+upper')/2))));
            minEig = min(eig(diffMat));
            if minEig < -tolRel*scale
                error('SplitCovarianceIntersectionBound:loewnerViolation', ...
                    ['upper does not Loewner-dominate lower: min(eig(upper-lower))=%.6e is below ' ...
                    'the tolerance -%.3e.'],minEig,tolRel*scale);
            end
        end

        function requireObservableHasDemonstratedBound(observableIdentifier)
            % requireObservableHasDemonstratedBound  Throws for every observable NOT listed in
            % ObservablesWithDemonstratedConservativeBound (plan Section 2.2 bullet 4). An
            % observable is added to that list only after its own adapter has a dedicated
            % Loewner-domination/independence reference test set; it is never widened by
            % inference from another observable's proof.
            allowed = revgnss.SplitCovarianceIntersectionBound.ObservablesWithDemonstratedConservativeBound;
            if ~((ischar(observableIdentifier) || ...
                    (isstring(observableIdentifier) && isscalar(observableIdentifier))) && ...
                    any(strcmp(char(observableIdentifier),allowed)))
                error('SplitCovarianceIntersectionBound:observableBoundNotDemonstrated', ...
                    ['Observable ''%s'' has no demonstrated conservative ' ...
                    'split-covariance-intersection bound; it is not selectable until its own ' ...
                    'adapter proves one (ObservablesWithDemonstratedConservativeBound).'], ...
                    char(observableIdentifier));
            end
        end

        function text = describeDerivation()
            % describeDerivation  Machine-readable, greppable frozen statement of the
            % derivation this module implements (design Section A.4/A.8).
            text = struct( ...
                'errorPartition', ...
                    ['e_i^+ = (I-K*Hi)*e_i - K*Hj*e_j + K*sum_g(w_g) + K*sum_k(u_k) + K*v, ' ...
                    'v uncorrelated with every other term by construction (subtraction-only Rind).'], ...
                'admissibleSet',revgnss.SplitCovarianceIntersectionBound.AdmissibleCrossCovarianceSet, ...
                'nTermYoungLemma', ...
                    ['For weights w_l>0 summing to 1: E[(sum T_l)(sum T_l)^T] <= sum (1/w_l)*E[T_l*T_l^T], ' ...
                    'proved by Jensen''s inequality on t->t^2 with no assumption on any cross moment.'], ...
                'coefficientOnePremise', ...
                    ['K*Rind*K'' carries coefficient 1 (not 1/w) because v is EXACTLY uncorrelated ' ...
                    'with every other term (Rind built only by subtracting declared common/' ...
                    'calibration contributions from the declared total measurement covariance).'], ...
                'weightRule','traceMinimisingBoundedSimplexCoordinateDescent (design Section A.6)', ...
                'shortForm', ...
                    ['B(K*(w),w) = (1/w_1)*(I-K*(w)*Hi)*Pi, used only as an internal consistency ' ...
                    'assertion, never reported directly (reporting it would be the shortcut plan ' ...
                    'Section 2.2.2 forbids in numerical form).'], ...
                'josephMinimalityChain', ...
                    ['B(K,w) >= P_ind^+(K) >= P_ind^+(K_ind) = (I-K_ind*Hi)*Pi, the first step ' ...
                    'because every 1/w_l>=1, the second by Joseph-quadratic minimality in K at ' ...
                    'fixed S_tot (design Section A.8).'], ...
                'refusedRefinements', ...
                    {{'termMergeRequiresIndependenceAttestation', ...
                    'jointDominatingBlockCertificateUnavailable'}});
        end
    end

    methods (Static, Access = private)
        function [terms, Rind, checked] = assembleYoungTerms_(args, expectedPolicy)
            checked = revgnss.SplitCovarianceIntersectionBound.validateArgs_(args,expectedPolicy);
            Sremote = checked.Hj*checked.Pj*checked.Hj';
            Sremote = (Sremote+Sremote')/2;

            Rind = checked.Rtot;
            for idx = 1:numel(checked.commonTerms)
                Rind = Rind - checked.commonTerms{idx}.matrix;
            end
            for idx = 1:numel(checked.calibTerms)
                Rind = Rind - checked.calibTerms{idx}.matrix;
            end
            Rind = (Rind+Rind')/2;

            tol = revgnss.SplitCovarianceIntersectionBound.EigenvalueToleranceRelative * ...
                max(1,norm(checked.Rtot,'fro'));
            if min(eig(Rind)) <= tol
                error('SplitCovarianceIntersectionBound:independentNoiseNotPositiveDefiniteAfterCommonSourceRemoval', ...
                    ['totalMeasurementCovariance_m2 minus every declared common-source and ' ...
                    'calibration contribution is not positive definite; the declared accounting ' ...
                    'is inconsistent (plan Section 2.2 invariant: no source may remain ' ...
                    'unaccounted for inside the independent-noise term).']);
            end

            terms = struct('matrix',{},'provenance',{},'kind',{});
            terms(1) = struct('matrix',checked.Pi,'provenance','ownerPriorTerm','kind','ownerPrior');
            terms(2) = struct('matrix',Sremote,'provenance','remoteEndpointPriorTerm','kind','remotePrior');
            for idx = 1:numel(checked.commonTerms)
                terms(end+1) = checked.commonTerms{idx}; %#ok<AGROW>
            end
            for idx = 1:numel(checked.calibTerms)
                terms(end+1) = checked.calibTerms{idx}; %#ok<AGROW>
            end
        end

        function checked = validateArgs_(args, expectedPolicy)
            required = {'ownerPriorCovariance_errorUnit2','ownerJacobian_mPerErrorUnit', ...
                'remotePriorCovariance_errorUnit2','remoteJacobian_mPerErrorUnit', ...
                'totalMeasurementCovariance_m2','totalMeasurementCovarianceIncludesDeclaredCommonSources', ...
                'declaredCommonSourceContributions','declaredCalibrationContributions', ...
                'ownerCovarianceComponentOrder','ownerAttitudeErrorCoordinateConvention', ...
                'remoteCovarianceComponentOrder','remoteAttitudeErrorCoordinateConvention', ...
                'weightSelectionRule','declaredWeights','correlationPolicy'};
            if ~isstruct(args) || ~isscalar(args)
                error('SplitCovarianceIntersectionBound:inputSchema', ...
                    'ownerPosteriorBound/ownerPosteriorAssumingIndependence require a scalar struct.');
            end
            supplied = fieldnames(args);
            missing = setdiff(required,supplied);
            unknown = setdiff(supplied,required);
            if ~isempty(missing)
                error('SplitCovarianceIntersectionBound:inputSchema','Missing field %s.',missing{1});
            end
            if ~isempty(unknown)
                error('SplitCovarianceIntersectionBound:inputSchema','Unsupported field %s.',unknown{1});
            end

            tolSym = revgnss.SplitCovarianceIntersectionBound.SymmetryToleranceFrobenius;
            tolEig = revgnss.SplitCovarianceIntersectionBound.EigenvalueToleranceRelative;

            Pi = args.ownerPriorCovariance_errorUnit2;
            if ~i_isSquareFinite_(Pi) || norm(Pi-Pi','fro') > tolSym*max(1,norm(Pi,'fro')) || ...
                    min(eig((Pi+Pi')/2)) <= tolEig*max(1,norm(Pi,'fro'))
                error('SplitCovarianceIntersectionBound:ownerPriorCovarianceNotPositiveDefinite', ...
                    'ownerPriorCovariance_errorUnit2 must be finite, symmetric, and positive definite.');
            end
            nOwner = size(Pi,1);

            Pj = args.remotePriorCovariance_errorUnit2;
            if ~i_isSquareFinite_(Pj) || norm(Pj-Pj','fro') > tolSym*max(1,norm(Pj,'fro')) || ...
                    min(eig((Pj+Pj')/2)) < -tolEig*max(1,norm(Pj,'fro'))
                error('SplitCovarianceIntersectionBound:remotePriorCovariance', ...
                    'remotePriorCovariance_errorUnit2 must be finite, symmetric, and PSD.');
            end
            nRemote = size(Pj,1);

            Hi = args.ownerJacobian_mPerErrorUnit;
            Hj = args.remoteJacobian_mPerErrorUnit;
            if ~ismatrix(Hi) || ~ismatrix(Hj) || any(~isfinite(Hi(:))) || any(~isfinite(Hj(:))) || ...
                    size(Hi,2) ~= nOwner || size(Hj,2) ~= nRemote || size(Hi,1) ~= size(Hj,1)
                error('SplitCovarianceIntersectionBound:jacobianDimension', ...
                    ['ownerJacobian_mPerErrorUnit and remoteJacobian_mPerErrorUnit must share m ' ...
                    'rows and match their declared error dimensions.']);
            end
            m = size(Hi,1);

            Rtot = args.totalMeasurementCovariance_m2;
            if ~isequal(size(Rtot),[m m]) || any(~isfinite(Rtot(:))) || ...
                    norm(Rtot-Rtot','fro') > tolSym*max(1,norm(Rtot,'fro')) || ...
                    min(eig((Rtot+Rtot')/2)) <= tolEig*max(1,norm(Rtot,'fro'))
                error('SplitCovarianceIntersectionBound:totalMeasurementCovariance', ...
                    'totalMeasurementCovariance_m2 must be finite, symmetric, positive definite, and m-by-m.');
            end

            if ~(islogical(args.totalMeasurementCovarianceIncludesDeclaredCommonSources) && ...
                    isscalar(args.totalMeasurementCovarianceIncludesDeclaredCommonSources) && ...
                    args.totalMeasurementCovarianceIncludesDeclaredCommonSources)
                error('SplitCovarianceIntersectionBound:commonSourceAccountingUndeclared', ...
                    'totalMeasurementCovarianceIncludesDeclaredCommonSources must be literally true.');
            end

            commonSourceNames = revgnss.DistributedLinkProtocolContract.CommonSourceNames;
            commonRows = args.declaredCommonSourceContributions;
            G = numel(commonRows);
            commonTerms = cell(1,G);
            for idx = 1:G
                row = commonRows(idx);
                if ~(isfield(row,'covarianceGroupIdentifier') && isfield(row,'commonSourceName') && ...
                        isfield(row,'contribution_m2') && isfield(row,'sourceProductIdentifier'))
                    error('SplitCovarianceIntersectionBound:commonSourceContributionSchema', ...
                        'declaredCommonSourceContributions(%d) is missing a required field.',idx);
                end
                if ~((ischar(row.commonSourceName) || isstring(row.commonSourceName)) && ...
                        any(strcmp(char(row.commonSourceName),commonSourceNames)))
                    error('SplitCovarianceIntersectionBound:commonSourceContributionSchema', ...
                        'declaredCommonSourceContributions(%d).commonSourceName must be a frozen common-source name.',idx);
                end
                if ~((ischar(row.covarianceGroupIdentifier) || isstring(row.covarianceGroupIdentifier)) && ...
                        ~isempty(strtrim(char(row.covarianceGroupIdentifier))))
                    error('SplitCovarianceIntersectionBound:commonSourceContributionSchema', ...
                        'declaredCommonSourceContributions(%d).covarianceGroupIdentifier must be nonempty text.',idx);
                end
                if ~((ischar(row.sourceProductIdentifier) || isstring(row.sourceProductIdentifier)))
                    error('SplitCovarianceIntersectionBound:commonSourceContributionSchema', ...
                        'declaredCommonSourceContributions(%d).sourceProductIdentifier must be text.',idx);
                end
                W = row.contribution_m2;
                if ~isequal(size(W),[m m]) || any(~isfinite(W(:))) || ...
                        norm(W-W','fro') > tolSym*max(1,norm(W,'fro')) || ...
                        min(eig((W+W')/2)) < -tolEig*max(1,norm(W,'fro'))
                    error('SplitCovarianceIntersectionBound:commonSourceContributionSchema', ...
                        'declaredCommonSourceContributions(%d).contribution_m2 must be finite, symmetric, PSD, and m-by-m.',idx);
                end
                commonTerms{idx} = struct('matrix',(W+W')/2, ...
                    'provenance',sprintf('commonSource:%s',char(row.covarianceGroupIdentifier)), ...
                    'kind','commonSource');
            end

            calibRows = args.declaredCalibrationContributions;
            P = numel(calibRows);
            calibTerms = cell(1,P);
            for idx = 1:P
                row = calibRows(idx);
                if ~(isfield(row,'calibrationStateIdentifier') && ...
                        isfield(row,'mappingColumn_mPerCalibrationUnit') && isfield(row,'stateUnits') && ...
                        isfield(row,'priorVariance') && isfield(row,'priorVarianceUnits'))
                    error('SplitCovarianceIntersectionBound:calibrationContributionSchema', ...
                        'declaredCalibrationContributions(%d) is missing a required field.',idx);
                end
                g = row.mappingColumn_mPerCalibrationUnit;
                if ~isequal(size(g),[m 1]) || any(~isfinite(g))
                    error('SplitCovarianceIntersectionBound:calibrationContributionSchema', ...
                        'declaredCalibrationContributions(%d).mappingColumn_mPerCalibrationUnit must be a finite m-by-1 column.',idx);
                end
                if ~((ischar(row.stateUnits) || isstring(row.stateUnits)) && ...
                        strcmp(char(row.stateUnits),'m'))
                    error('SplitCovarianceIntersectionBound:calibrationUnitMappingUnavailable', ...
                        ['declaredCalibrationContributions(%d).stateUnits must be ''m''; the s-to-m ' ...
                        'mapping factor c (one-way) or 2c (round-trip) is a Section 2.3 adapter ' ...
                        'responsibility, not implemented here.'],idx);
                end
                if ~(isnumeric(row.priorVariance) && isscalar(row.priorVariance) && ...
                        isfinite(row.priorVariance) && row.priorVariance > 0) || ...
                        ~((ischar(row.priorVarianceUnits) || isstring(row.priorVarianceUnits)) && ...
                        strcmp(char(row.priorVarianceUnits),'m^2'))
                    error('SplitCovarianceIntersectionBound:calibrationContributionSchema', ...
                        'declaredCalibrationContributions(%d).priorVariance must be finite/positive with units m^2.',idx);
                end
                if ~(isfield(row,'calibrationStateIdentifier') && ...
                        (ischar(row.calibrationStateIdentifier) || isstring(row.calibrationStateIdentifier)) && ...
                        ~isempty(strtrim(char(row.calibrationStateIdentifier))))
                    error('SplitCovarianceIntersectionBound:calibrationContributionSchema', ...
                        'declaredCalibrationContributions(%d).calibrationStateIdentifier must be nonempty text.',idx);
                end
                U = g*row.priorVariance*g';
                calibTerms{idx} = struct('matrix',(U+U')/2, ...
                    'provenance',sprintf('calibration:%s',char(row.calibrationStateIdentifier)), ...
                    'kind','calibration');
            end

            nTerms = 2+G+P;
            if nTerms > revgnss.SplitCovarianceIntersectionBound.MaximumYoungTerms
                error('SplitCovarianceIntersectionBound:tooManyYoungTerms', ...
                    'The declared inputs require %d Young terms, exceeding MaximumYoungTerms.',nTerms);
            end

            revgnss.SplitCovarianceIntersectionBound.requireRecognisedComponentOrder_( ...
                args.ownerCovarianceComponentOrder,args.ownerAttitudeErrorCoordinateConvention);
            revgnss.SplitCovarianceIntersectionBound.requireRecognisedComponentOrder_( ...
                args.remoteCovarianceComponentOrder,args.remoteAttitudeErrorCoordinateConvention);
            if numel(args.ownerCovarianceComponentOrder) ~= nOwner
                error('SplitCovarianceIntersectionBound:componentOrderUnrecognised', ...
                    'ownerCovarianceComponentOrder length must match the owner prior dimension.');
            end
            if numel(args.remoteCovarianceComponentOrder) ~= nRemote
                error('SplitCovarianceIntersectionBound:componentOrderUnrecognised', ...
                    'remoteCovarianceComponentOrder length must match the remote prior dimension.');
            end

            rule = args.weightSelectionRule;
            if ~((ischar(rule) || isstring(rule)) && any(strcmp(char(rule), ...
                    revgnss.SplitCovarianceIntersectionBound.AllowedWeightSelectionRules)))
                error('SplitCovarianceIntersectionBound:weightSelectionRuleUnsupported', ...
                    'weightSelectionRule must be a frozen allowed rule.');
            end
            if ~(isnumeric(args.declaredWeights) && isvector(args.declaredWeights))
                error('SplitCovarianceIntersectionBound:weightVectorLength', ...
                    'declaredWeights must be a numeric row vector (NaN entries unless fixedDeclaredWeights).');
            end

            correlationPolicy = args.correlationPolicy;
            if ~(ischar(correlationPolicy) || isstring(correlationPolicy))
                error('SplitCovarianceIntersectionBound:inputSchema','correlationPolicy must be text.');
            end
            correlationPolicy = char(correlationPolicy);
            if strcmp(correlationPolicy,'assumeIndependent') && ~strcmp(expectedPolicy,'assumeIndependent')
                error('SplitCovarianceIntersectionBound:testOnlyPolicyRequested', ...
                    'This entry point refuses correlationPolicy=''assumeIndependent''.');
            end
            if ~strcmp(correlationPolicy,expectedPolicy)
                error('SplitCovarianceIntersectionBound:inputSchema', ...
                    'correlationPolicy must equal ''%s'' for this entry point.',expectedPolicy);
            end

            checked = struct('Pi',(Pi+Pi')/2,'Hi',Hi,'Pj',(Pj+Pj')/2,'Hj',Hj,'Rtot',(Rtot+Rtot')/2, ...
                'commonTerms',{commonTerms},'calibTerms',{calibTerms}, ...
                'ownerCovarianceComponentOrder',{args.ownerCovarianceComponentOrder}, ...
                'ownerAttitudeErrorCoordinateConvention',char(args.ownerAttitudeErrorCoordinateConvention), ...
                'remoteCovarianceComponentOrder',{args.remoteCovarianceComponentOrder}, ...
                'remoteAttitudeErrorCoordinateConvention',char(args.remoteAttitudeErrorCoordinateConvention), ...
                'weightSelectionRule',char(rule),'declaredWeights',args.declaredWeights, ...
                'correlationPolicy',correlationPolicy,'m',m,'nOwner',nOwner,'nRemote',nRemote);
        end

        function requireIndependenceAttestation_(attestation)
            requiredFlags = {'priorsIndependentlyGenerated','noSharedMeasurement', ...
                'noSharedTowerProduct','noSharedTerminalCalibration','noSharedProcessSource'};
            if ~isstruct(attestation) || ~isscalar(attestation)
                error('SplitCovarianceIntersectionBound:independenceAttestationSchema', ...
                    'independenceAttestation must be a scalar struct.');
            end
            for idx = 1:numel(requiredFlags)
                name = requiredFlags{idx};
                if ~isfield(attestation,name) || ~islogical(attestation.(name)) || ...
                        ~isscalar(attestation.(name)) || ~attestation.(name)
                    error('SplitCovarianceIntersectionBound:independenceNotAttested', ...
                        'independenceAttestation.%s must be declared true.',name);
                end
            end
            if ~isfield(attestation,'fixtureIdentifier') || ...
                    ~(ischar(attestation.fixtureIdentifier) || isstring(attestation.fixtureIdentifier)) || ...
                    isempty(strtrim(char(attestation.fixtureIdentifier)))
                error('SplitCovarianceIntersectionBound:independenceAttestationSchema', ...
                    'independenceAttestation.fixtureIdentifier must be nonempty text.');
            end
            if ~isfield(attestation,'commonSourceTreatment') || ...
                    ~revgnss.DistributedLinkProtocolContract.isFullyRejectedCommonSourceTreatment( ...
                    attestation.commonSourceTreatment)
                error('SplitCovarianceIntersectionBound:independenceNotAttested', ...
                    'independenceAttestation.commonSourceTreatment must have every source ''rejected''.');
            end
        end

        function requireRecognisedComponentOrder_(componentOrder, attitudeConvention)
            matchesEuler = isequal(componentOrder, ...
                revgnss.DistributedLinkProtocolContract.StateSchemaV1CovarianceComponentOrderEuler);
            matchesTangent = isequal(componentOrder, ...
                revgnss.DistributedLinkProtocolContract.StateSchemaV1CovarianceComponentOrderTangent);
            if ~(matchesEuler || matchesTangent)
                error('SplitCovarianceIntersectionBound:componentOrderUnrecognised', ...
                    'A covariance component order must be a recognised frozen v1 variant.');
            end
            variant = 'euler';
            if matchesTangent; variant = 'tangent'; end
            conventionMatchesVariant = ...
                (strcmp(variant,'euler') && strcmp(char(attitudeConvention),'eulerZYXError_rad')) || ...
                (strcmp(variant,'tangent') && strcmp(char(attitudeConvention), ...
                'rightMultiplicativeLocalTangent_rad'));
            if ~conventionMatchesVariant
                error('SplitCovarianceIntersectionBound:componentOrderUnrecognised', ...
                    'A declared attitude convention disagrees with its own covariance labels.');
            end
        end

        function a = termTraces_(Pi, Hi, sigmaCell, K)
            nOwner = size(Pi,1);
            IminusKHi = eye(nOwner) - K*Hi;
            a = zeros(1,1+numel(sigmaCell));
            a(1) = trace(IminusKHi*Pi*IminusKHi');
            for idx = 1:numel(sigmaCell)
                a(idx+1) = trace(K*sigmaCell{idx}*K');
            end
        end

        function K = gainAt_(Pi, Hi, sigmaCell, Rind, w)
            m = size(Rind,1);
            Xi = zeros(m);
            for idx = 1:numel(sigmaCell)
                Xi = Xi + sigmaCell{idx}/w(idx+1);
            end
            Xi = Xi + Rind;
            K = Pi*Hi' / (Hi*Pi*Hi' + w(1)*Xi);
        end

        function contributions = termContributions_(terms, K, Hi)
            nOwner = size(K,1);
            IminusKHi = eye(nOwner) - K*Hi;
            contributions = cell(1,numel(terms));
            for idx = 1:numel(terms)
                term = terms(idx);
                if strcmp(term.kind,'ownerPrior')
                    C = IminusKHi*term.matrix*IminusKHi';
                else
                    C = K*term.matrix*K';
                end
                contributions{idx} = (C+C')/2;
            end
        end

        function record = buildResultRecord_(correlationPolicy, boundKind, checked, terms, Rind, ...
                K, weights, diagnostics, B, contributions, isConservative, attestation)
            provenance = {terms.provenance};
            commonContrib = struct('covarianceGroupIdentifier',{},'contribution_m2',{});
            calibContrib = struct('calibrationStateIdentifier',{},'contribution_m2',{});
            for idx = 3:numel(terms)
                if strcmp(terms(idx).kind,'commonSource')
                    commonContrib(end+1) = struct( ...
                        'covarianceGroupIdentifier',terms(idx).provenance, ...
                        'contribution_m2',terms(idx).matrix); %#ok<AGROW>
                else
                    calibContrib(end+1) = struct( ...
                        'calibrationStateIdentifier',terms(idx).provenance, ...
                        'contribution_m2',terms(idx).matrix); %#ok<AGROW>
                end
            end
            commonContrib = reshape(commonContrib,1,numel(commonContrib));
            calibContrib = reshape(calibContrib,1,numel(calibContrib));
            record = struct( ...
                'correlationPolicy',correlationPolicy, ...
                'boundKind',boundKind, ...
                'admissibleCrossCovarianceSet',revgnss.SplitCovarianceIntersectionBound.AdmissibleCrossCovarianceSet, ...
                'errorSignConvention',revgnss.SplitCovarianceIntersectionBound.ErrorSignConvention, ...
                'weightSelectionRule',checked.weightSelectionRule, ...
                'weightSolverBranch',diagnostics.weightSolverBranch, ...
                'youngTermWeights',weights, ...
                'youngTermProvenance',{provenance}, ...
                'youngTerms_errorUnit2',{contributions}, ...
                'weightLowerBound',revgnss.SplitCovarianceIntersectionBound.WeightLowerBound, ...
                'weightsClamped',diagnostics.weightsClamped, ...
                'weightIterationCount',diagnostics.iterationCount, ...
                'objectiveTraceHistory_errorUnit2',diagnostics.objectiveTraceHistory_errorUnit2, ...
                'ownerCovarianceComponentOrder',{checked.ownerCovarianceComponentOrder}, ...
                'ownerAttitudeErrorCoordinateConvention',checked.ownerAttitudeErrorCoordinateConvention, ...
                'remoteCovarianceComponentOrder',{checked.remoteCovarianceComponentOrder}, ...
                'remoteAttitudeErrorCoordinateConvention',checked.remoteAttitudeErrorCoordinateConvention, ...
                'gain_errorUnitPerM',K, ...
                'ownerPriorCovariance_errorUnit2',checked.Pi, ...
                'remoteContributionCovariance_m2',terms(2).matrix, ...
                'commonSourceContributions_m2',{num2cell(commonContrib)}, ...
                'calibrationContributions_m2',{num2cell(calibContrib)}, ...
                'totalMeasurementCovariance_m2',checked.Rtot, ...
                'independentMeasurementCovariance_m2',Rind, ...
                'independentNoiseTerm_errorUnit2',K*Rind*K', ...
                'ownerPosteriorCovarianceReported_errorUnit2',B, ...
                'minimumEigenvalueReported_errorUnit2',min(eig((B+B')/2)), ...
                'commonSourceContributionsSubtractedFromDeclaredTotal',true, ...
                'isConservativeUpperBound',isConservative, ...
                'independenceAttestation',attestation);
        end
    end
end

function tf = i_isSquareFinite_(M)
tf = isnumeric(M) && ismatrix(M) && size(M,1) == size(M,2) && ~isempty(M) && all(isfinite(M(:)));
end
