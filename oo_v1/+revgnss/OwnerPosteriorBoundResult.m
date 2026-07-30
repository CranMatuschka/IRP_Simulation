classdef OwnerPosteriorBoundResult
    % OwnerPosteriorBoundResult  Immutable, validated report of a
    % revgnss.SplitCovarianceIntersectionBound computation (plan Section 2.2).
    %
    % Every field here is the REPORTED covariance and its full derivation provenance -- never
    % anything tighter, and never a pre-summed remote/common-source block (there is no field
    % that could hold one; see revgnss.SplitCovarianceIntersectionBound's header for why that
    % shortcut is unrepresentable). isConservativeUpperBound is TRUE only for boundKind=
    % 'psdUpperBoundUnderUnknownCrossCovariance' with
    % commonSourceContributionsSubtractedFromDeclaredTotal=true; it is FALSE on every
    % ownerPosteriorAssumingIndependence result, which is exact-under-attestation, not an upper
    % bound over the admissible cross-covariance set.
    %
    % commonSourceContributionsSubtractedFromDeclaredTotal names exactly what the module can
    % mechanically confirm: every declared common-source/calibration contribution was
    % subtracted from totalMeasurementCovariance_m2 before Rind was formed. It is NOT a
    % statistical verification that the declared contributions are actually disjoint from the
    % residual noise -- that is an assumption the CALLER attests by declaring
    % totalMeasurementCovarianceIncludesDeclaredCommonSources=true at the module boundary
    % (revgnss.SplitCovarianceIntersectionBound cannot check a caller's honesty about what its
    % own totalMeasurementCovariance_m2 physically represents). The field is named for the
    % mechanical fact it reports, not a claim of independent verification -- matching this
    % repo's established convention of never folding an unchecked condition into a `true`
    % verdict (see +revgnss/DistributedDeliveryLedger.m's ownerDisagreementsChecked).
    %
    % Units: *_errorUnit2 components are the squares of ownerCovarianceComponentOrder's
    % suffixes (m^2, m^2/s^2, rad^2, rad^2/s^2) -- the component order IS the units declaration
    % (plan invariant 10). *_m2 components are measurement-space (m^2).

    properties (Constant)
        AllowedBoundKinds = {'psdUpperBoundUnderUnknownCrossCovariance','exactUnderAttestedIndependence'};
    end

    properties (SetAccess = immutable)
        correlationPolicy (1,:) char
        boundKind (1,:) char
        admissibleCrossCovarianceSet (1,:) char
        errorSignConvention (1,:) char
        weightSelectionRule (1,:) char
        weightSolverBranch (1,:) char
        youngTermWeights (1,:) double
        youngTermProvenance (1,:) cell
        youngTerms_errorUnit2 (1,:) cell
        weightLowerBound (1,1) double
        weightsClamped (1,1) logical
        weightIterationCount (1,1) double
        objectiveTraceHistory_errorUnit2 (1,:) double
        ownerCovarianceComponentOrder (1,:) cell
        ownerAttitudeErrorCoordinateConvention (1,:) char
        remoteCovarianceComponentOrder (1,:) cell
        remoteAttitudeErrorCoordinateConvention (1,:) char
        gain_errorUnitPerM (:,:) double
        ownerPriorCovariance_errorUnit2 (:,:) double
        remoteContributionCovariance_m2 (:,:) double
        commonSourceContributions_m2 (1,:) cell
        calibrationContributions_m2 (1,:) cell
        totalMeasurementCovariance_m2 (:,:) double
        independentMeasurementCovariance_m2 (:,:) double
        independentNoiseTerm_errorUnit2 (:,:) double
        ownerPosteriorCovarianceReported_errorUnit2 (:,:) double
        minimumEigenvalueReported_errorUnit2 (1,1) double
        commonSourceContributionsSubtractedFromDeclaredTotal (1,1) logical
        isConservativeUpperBound (1,1) logical
        independenceAttestation (1,1) struct
    end

    methods
        function obj = OwnerPosteriorBoundResult(record)
            required = { ...
                'correlationPolicy','boundKind','admissibleCrossCovarianceSet', ...
                'errorSignConvention','weightSelectionRule','weightSolverBranch', ...
                'youngTermWeights','youngTermProvenance','youngTerms_errorUnit2', ...
                'weightLowerBound','weightsClamped','weightIterationCount', ...
                'objectiveTraceHistory_errorUnit2','ownerCovarianceComponentOrder', ...
                'ownerAttitudeErrorCoordinateConvention','remoteCovarianceComponentOrder', ...
                'remoteAttitudeErrorCoordinateConvention','gain_errorUnitPerM', ...
                'ownerPriorCovariance_errorUnit2','remoteContributionCovariance_m2', ...
                'commonSourceContributions_m2','calibrationContributions_m2', ...
                'totalMeasurementCovariance_m2','independentMeasurementCovariance_m2', ...
                'independentNoiseTerm_errorUnit2','ownerPosteriorCovarianceReported_errorUnit2', ...
                'minimumEigenvalueReported_errorUnit2', ...
                'commonSourceContributionsSubtractedFromDeclaredTotal', ...
                'isConservativeUpperBound','independenceAttestation'};
            supplied = fieldnames(record);
            missing = setdiff(required,supplied);
            unknown = setdiff(supplied,required);
            if ~isempty(missing)
                error('OwnerPosteriorBoundResult:missingField', ...
                    'OwnerPosteriorBoundResult is missing %s.',missing{1});
            end
            if ~isempty(unknown)
                error('OwnerPosteriorBoundResult:unknownField', ...
                    'OwnerPosteriorBoundResult contains unsupported field %s.',unknown{1});
            end

            boundKind = char(record.boundKind);
            if ~any(strcmp(boundKind,revgnss.OwnerPosteriorBoundResult.AllowedBoundKinds))
                error('OwnerPosteriorBoundResult:boundKind', ...
                    'boundKind must be a frozen allowed bound kind.');
            end
            correlationPolicy = char(record.correlationPolicy);
            policyKindOk = ...
                (strcmp(correlationPolicy,'splitCovarianceIntersection') && ...
                strcmp(boundKind,'psdUpperBoundUnderUnknownCrossCovariance')) || ...
                (strcmp(correlationPolicy,'assumeIndependent') && ...
                strcmp(boundKind,'exactUnderAttestedIndependence'));
            if ~policyKindOk
                error('OwnerPosteriorBoundResult:policyKindMismatch', ...
                    'correlationPolicy and boundKind must be the frozen matched pair.');
            end

            nTerms = numel(record.youngTermProvenance);
            if numel(record.youngTermWeights) ~= nTerms || numel(record.youngTerms_errorUnit2) ~= nTerms
                error('OwnerPosteriorBoundResult:weightVector', ...
                    'youngTermWeights and youngTerms_errorUnit2 must each have one entry per provenance label.');
            end
            if strcmp(boundKind,'psdUpperBoundUnderUnknownCrossCovariance')
                if abs(sum(record.youngTermWeights)-1) > 1e-6 || ...
                        any(record.youngTermWeights < record.weightLowerBound - 1e-9)
                    error('OwnerPosteriorBoundResult:weightVector', ...
                        'youngTermWeights must sum to 1 with every entry at or above weightLowerBound.');
                end
            end
            if nTerms < 2 || ~strcmp(record.youngTermProvenance{1},'ownerPriorTerm') || ...
                    ~strcmp(record.youngTermProvenance{2},'remoteEndpointPriorTerm')
                error('OwnerPosteriorBoundResult:termProvenance', ...
                    'youngTermProvenance{1}/{2} must be ''ownerPriorTerm''/''remoteEndpointPriorTerm''.');
            end
            if numel(unique(record.youngTermProvenance)) ~= nTerms
                error('OwnerPosteriorBoundResult:termProvenance', ...
                    'youngTermProvenance entries must be distinct: a folded block cannot masquerade as one term.');
            end
            for idx = 1:nTerms
                Tl = record.youngTerms_errorUnit2{idx};
                scale = max(1,norm(Tl,'fro'));
                if isempty(Tl) || any(~isfinite(Tl(:))) || size(Tl,1) ~= size(Tl,2) || ...
                        norm(Tl-Tl','fro') > 1e-8*scale || min(eig((Tl+Tl')/2)) < -1e-8*scale
                    error('OwnerPosteriorBoundResult:termNotPsd', ...
                        'youngTerms_errorUnit2{%d} must be finite, symmetric, square, and PSD.',idx);
                end
            end

            B = record.ownerPosteriorCovarianceReported_errorUnit2;
            if isempty(B) || any(~isfinite(B(:))) || size(B,1) ~= size(B,2) || ...
                    norm(B-B','fro') > 1e-8*max(1,norm(B,'fro'))
                error('OwnerPosteriorBoundResult:reportedCovariance', ...
                    'ownerPosteriorCovarianceReported_errorUnit2 must be finite, square, and symmetric.');
            end
            if min(eig((B+B')/2)) <= 0
                error('OwnerPosteriorBoundResult:reportedCovariance', ...
                    'ownerPosteriorCovarianceReported_errorUnit2 must be positive definite.');
            end

            reconstructed = record.independentNoiseTerm_errorUnit2;
            for idx = 1:nTerms
                reconstructed = reconstructed + record.youngTerms_errorUnit2{idx}/record.youngTermWeights(idx);
            end
            scaleB = max(1,norm(B,'fro'));
            if norm(reconstructed-B,'fro') > 1e-8*scaleB
                error('OwnerPosteriorBoundResult:termDecompositionMismatch', ...
                    ['The weighted Young terms plus the independent-noise term do not reconstruct ' ...
                    'ownerPosteriorCovarianceReported_errorUnit2.']);
            end

            history = record.objectiveTraceHistory_errorUnit2;
            if numel(history) > 1
                diffs = diff(history);
                tolHist = 1e-9*max(1,max(abs(history)));
                if any(diffs > tolHist)
                    error('OwnerPosteriorBoundResult:objectiveNotMonotone', ...
                        'objectiveTraceHistory_errorUnit2 must be non-increasing within the guarded tolerance.');
                end
            end

            if record.isConservativeUpperBound && ~(strcmp(boundKind,'psdUpperBoundUnderUnknownCrossCovariance') ...
                    && record.commonSourceContributionsSubtractedFromDeclaredTotal)
                error('OwnerPosteriorBoundResult:conservativeClaimUnsupported', ...
                    ['isConservativeUpperBound=true requires boundKind=''psdUpperBoundUnderUnknown' ...
                    'CrossCovariance'' and commonSourceContributionsSubtractedFromDeclaredTotal=true.']);
            end

            revgnss.OwnerPosteriorBoundResult.requireRecognisedComponentOrder_( ...
                record.ownerCovarianceComponentOrder,record.ownerAttitudeErrorCoordinateConvention);
            revgnss.OwnerPosteriorBoundResult.requireRecognisedComponentOrder_( ...
                record.remoteCovarianceComponentOrder,record.remoteAttitudeErrorCoordinateConvention);

            for index = 1:numel(required)
                obj.(required{index}) = record.(required{index});
            end
        end
    end

    methods (Static, Access = private)
        function requireRecognisedComponentOrder_(componentOrder, attitudeConvention)
            matchesEuler = isequal(componentOrder, ...
                revgnss.DistributedLinkProtocolContract.StateSchemaV1CovarianceComponentOrderEuler);
            matchesTangent = isequal(componentOrder, ...
                revgnss.DistributedLinkProtocolContract.StateSchemaV1CovarianceComponentOrderTangent);
            if ~(matchesEuler || matchesTangent)
                error('OwnerPosteriorBoundResult:componentOrderUnrecognised', ...
                    'A covariance component order must be a recognised frozen v1 variant.');
            end
            variant = 'euler';
            if matchesTangent; variant = 'tangent'; end
            conventionMatchesVariant = ...
                (strcmp(variant,'euler') && strcmp(char(attitudeConvention),'eulerZYXError_rad')) || ...
                (strcmp(variant,'tangent') && strcmp(char(attitudeConvention), ...
                'rightMultiplicativeLocalTangent_rad'));
            if ~conventionMatchesVariant
                error('OwnerPosteriorBoundResult:componentOrderUnrecognised', ...
                    'A declared attitude convention disagrees with its own covariance labels.');
            end
        end
    end
end
