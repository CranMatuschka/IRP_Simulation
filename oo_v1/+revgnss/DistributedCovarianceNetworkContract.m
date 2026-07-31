classdef DistributedCovarianceNetworkContract
    % DistributedCovarianceNetworkContract  Frozen Stage-3.1 vocabulary and shared statics
    % for revgnss.DistributedCovarianceNetwork (plan Section 3.1).
    %
    % Section 3.1 shipped the network's OWN prediction/storage/audit/fleet-limit machinery and
    % the low-level pair-update PRIMITIVE (item 5). Section 3.2 adds the synchronized two-
    % endpoint delivery protocol on top: 'pairExactWhenBothEndpointsTracked' is now a legal
    % AllowedLinkUpdateRoutingPolicies value, so routeForDelivery can return 'pairExact' when
    % that routing policy is configured -- see revgnss.SynchronizedPairLinkUpdateTransaction for
    % the actual dual-endpoint apply-or-reject-both mechanism (this contract only names the
    % vocabulary; it applies nothing). Sections 3.3 (explicit common-information modeling), 3.4
    % (guarded observable re-enablement beyond coherentTwoWayCodeRange, including ISL carrier),
    % and 3.5 (honest reporting) remain not implemented.
    %
    % EpochPhaseOrderWithCorrelationNetwork extends (does not modify)
    % revgnss.DistributedLinkProtocolContract.EpochFinalizationPhaseOrder with exactly one
    % named insertion at index 3, 'propagateAndConditionCrossCovariance'; the frozen 6-entry
    % Stage-2 constant is left untouched (it is pinned by existing exact-equality tests).

    properties (Constant)
        NetworkSchemaVersion = 'distributedCovarianceNetwork-v1'
        CrossBlockSpanKind   = 'fullLocalStateSpan'

        AllowedNetworkPolicies               = {'disabled','exactPairwiseCrossCovariance'}
        AllowedCommonProcessNoiseTreatments  = {'rejected','declaredCommonAccelerationGroup'}
        AllowedCommonProcessNoiseFrames      = {'ECEF'}
        AllowedPriorIndependenceDeclarations = {'independentLocalPriors'}

        % Section 3.2: 'pairExactWhenBothEndpointsTracked' selects the synchronized two-endpoint
        % delivery protocol (revgnss.SynchronizedPairLinkUpdateTransaction).
        AllowedLinkUpdateRoutingPolicies = {'conservativeBoundOnly','pairExactWhenBothEndpointsTracked'}
        AllowedLinkUpdateRoutes          = {'conservativeBound','pairExact'}

        AllowedCrossBlockProvenanceKinds = { ...
            'initialisedIndependentPrior', ...
            'propagatedAndConditionedOnLocalUpdate', ...
            'conditionedOnConservativeOwnerOnlyLinkUpdate', ...
            'conditionedOnPairExactLinkUpdate'}

        AllowedRouteReasonCodes = { ...
            'pairExactRouteAvailable', ...
            'pairExactRouteRequiresSynchronizedDeliveryStage', ...
            'correlationNetworkDisabled','endpointNotFleetMember', ...
            'crossBlockAbsentForPair','crossBlockEpochStale', ...
            'crossBlockStateMapFingerprintChanged','crossBlockProvenanceUnusable', ...
            'pairExactRefusedObservableNotEligible','pairExactRefusedClockGaugeNotAnchored'}

        AllowedAuditVerdicts = { ...
            'symmetricPositiveSemiDefinite','symmetryViolation', ...
            'positiveSemiDefiniteViolation','pairCanonicalCorrelationViolation', ...
            'staleCrossBlock','notAudited'}

        AllowedCentralReferenceEquivalenceClaims = { ...
            'notEvaluated', ...
            'exactLinearPropagationOfDeclaredLocalCovariances', ...
            'conditionedOnConservativeOwnerOnlyUpdatesNoFleetBoundClaimed', ...
            'notEquivalentUnappliedCorrelatedLocalUpdates', ...
            'notEquivalentUnappliedThirdMemberCorrections', ...
            'exactPairConditionedNonPairLinksRemainConservative', ...
            'exactPairSynchronizedUpdatesCentralReferenceEquivalent'}

        % Orthogonal to the equivalence-claim ladder above: WHICH routing rule(s) actually fired
        % this run, independent of whether local ground updates went uncorrelated. Two separate
        % facts get two separate words rather than being folded into one, because overloading
        % one word is how honest reporting drifts into prose (plan Section 3.5's own concern).
        AllowedLinkUpdateConditioningClaims = { ...
            'notEvaluated','conservativeOwnerOnlyOnly','exactPairSynchronizedOnly', ...
            'mixedExactAndConservative'}

        MaximumSupportedFleetSize      = 4
        MaximumAssembledFleetDimension = 512

        SymmetryToleranceRelative                = 1e-12
        PositiveSemiDefiniteToleranceScaled       = 1e-10
        CanonicalCorrelationToleranceAbsolute     = 1e-9
        InnovationDecompositionToleranceRelative  = 1e-14

        % Every site in +filter/ReverseGNSSEKF.m that mutates obj.P and IS accounted for by the
        % retained local epoch-transition contraction. A new writer outside this list must
        % either be added here (and to the retention mechanism) or it silently breaks the
        % network's exactness claim; tests/test_local_epoch_transition_capture_from_real_ekf.m
        % pins this list against a regex sweep of the file's own obj.P assignment sites.
        AccountedLocalCovarianceMutationMethods = {'predict','update'}

        EpochPhaseOrderWithCorrelationNetwork = { ...
            'advanceSharedTruthAndLocalPrediction', ...
            'localGroundOnboardUpdate', ...
            'propagateAndConditionCrossCovariance', ...
            'publishAndFreezeEstimatorProducts', ...
            'generateValidateDeliverLinkRecords', ...
            'ownerOnlyLinkUpdate', ...
            'commitLocalHistoryAndConsumption'}
    end

    methods (Static)
        function requireEpochPhaseOrderExtendsStageTwo()
            % requireEpochPhaseOrderExtendsStageTwo  Mechanical proof that the 7-entry list
            % above is the frozen Stage-2 6-entry EpochFinalizationPhaseOrder with exactly one
            % named insertion at index 3, every other entry byte-identical and in order.
            stageTwo = revgnss.DistributedLinkProtocolContract.EpochFinalizationPhaseOrder;
            withNetwork = revgnss.DistributedCovarianceNetworkContract.EpochPhaseOrderWithCorrelationNetwork;
            if numel(withNetwork) ~= numel(stageTwo)+1
                error('DistributedCovarianceNetworkContract:phaseOrderLength', ...
                    'EpochPhaseOrderWithCorrelationNetwork must have exactly one more entry than Stage 2''s.');
            end
            if ~strcmp(withNetwork{3},'propagateAndConditionCrossCovariance')
                error('DistributedCovarianceNetworkContract:phaseOrderInsertion', ...
                    'The new phase must be named ''propagateAndConditionCrossCovariance'' at index 3.');
            end
            reduced = withNetwork([1 2 4 5 6 7]);
            if ~isequal(reduced,stageTwo)
                error('DistributedCovarianceNetworkContract:phaseOrderDrift', ...
                    ['EpochPhaseOrderWithCorrelationNetwork, with the new phase removed, must be ' ...
                    'byte-identical to DistributedLinkProtocolContract.EpochFinalizationPhaseOrder.']);
            end
        end

        function idx = schemaStateIndicesFromStateMap(stateMap, assetIndex)
            % schemaStateIndicesFromStateMap  The ONE 14-index concatenation
            % [r; v; euler; omega; b; bdot], factored out of
            % +revgnss/IndependentFleetCoordinator.m and +revgnss/OwnerLocalEstimatorEndpointProvider.m
            % so every caller shares one implementation (AssetStateBlock.forAsset itself omits
            % omega -- see its header -- so this static, not a widened AssetStateBlock, is the
            % dedupe point; U21).
            if nargin < 2 || isempty(assetIndex); assetIndex = 1; end
            blk = revgnss.AssetStateBlock.forAsset(stateMap,assetIndex);
            if assetIndex == 1
                omegaIdx = stateMap.omega_idx;
            else
                omegaIdx = stateMap.asset(assetIndex).omega;
            end
            idx = [blk.r(:);blk.v(:);blk.euler(:);omegaIdx(:);blk.b;blk.bdot];
            if numel(idx) ~= 14 || numel(unique(idx)) ~= 14
                error('DistributedCovarianceNetworkContract:schemaIndices', ...
                    'schemaStateIndicesFromStateMap must resolve 14 distinct state indices.');
            end
        end

        function key = canonicalPairKey(firstEndpointIdentifier, secondEndpointIdentifier)
            % canonicalPairKey  Lexicographically-ordered pair key: a cross block is stored
            % once per unordered pair (U22). Throws if the two identifiers are equal.
            a = char(firstEndpointIdentifier);
            b = char(secondEndpointIdentifier);
            if strcmp(a,b)
                error('DistributedCovarianceNetworkContract:pairKeySelf', ...
                    'A cross-covariance pair requires two distinct endpoint identifiers.');
            end
            ordered = sort({a,b});
            key = [ordered{1} '::' ordered{2}];
        end

        function fp = localStateMapFingerprint(stateMap, nx, attitudeParameterization)
            % localStateMapFingerprint  Opaque, deterministic fingerprint over nx, the 14-core
            % index vector, the attitude parameterization, and the sorted set of optional state
            % blocks present -- changes if any optional state block is added/removed.
            coreIdx = revgnss.DistributedCovarianceNetworkContract.schemaStateIndicesFromStateMap(stateMap,1);
            names = sort(fieldnames(stateMap));
            sizes = cellfun(@(n) numel(stateMap.(n)), names);
            parts = cell(1,numel(names));
            for index = 1:numel(names)
                parts{index} = sprintf('%s=%d',names{index},sizes(index));
            end
            fp = sprintf('nx=%d|core=%s|att=%s|blocks=%s', nx, ...
                mat2str(coreIdx(:)'), char(attitudeParameterization), strjoin(parts,','));
        end

        function requireMemberRecord(record)
            required = {'endpointIdentifier','canonicalPhysicalAssetIndex','localStateDimension', ...
                'schemaStateIndices','covarianceComponentOrder','attitudeErrorCoordinateConvention', ...
                'localStateMapFingerprint','stateSchemaVersion','priorIndependenceDeclaration', ...
                'registrationCoordinateEpoch_s'};
            missing = setdiff(required,fieldnames(record));
            if ~isempty(missing)
                error('DistributedCovarianceNetworkContract:memberRecordSchema', ...
                    'A fleet member record is missing %s.',missing{1});
            end
            declarations = revgnss.DistributedCovarianceNetworkContract.AllowedPriorIndependenceDeclarations;
            if ~any(strcmp(char(record.priorIndependenceDeclaration),declarations))
                error('DistributedCovarianceNetworkContract:priorIndependenceUndeclared', ...
                    'priorIndependenceDeclaration must be one of the frozen allowed declarations.');
            end
            if ~strcmp(char(record.stateSchemaVersion), ...
                    revgnss.DistributedLinkProtocolContract.StateSchemaVersion)
                error('DistributedCovarianceNetworkContract:stateSchemaVersionMismatch', ...
                    'A fleet member must declare the frozen Stage-2 state schema version.');
            end
        end

        function requirePolicyRecord(record)
            required = {'policyIdentifier','configuredMaximumFleetSize','commonProcessNoiseTreatment', ...
                'linkUpdateRoutingPolicy','crossBlockSpanKind','stateSchemaVersion'};
            supplied = fieldnames(record);
            missing = setdiff(required,supplied);
            unknown = setdiff(supplied,required);
            if ~isempty(missing)
                error('DistributedCovarianceNetworkContract:policyRecordSchema', ...
                    'A network policy record is missing %s.',missing{1});
            end
            if ~isempty(unknown)
                error('DistributedCovarianceNetworkContract:policyRecordSchema', ...
                    'A network policy record contains unsupported field %s.',unknown{1});
            end
        end
    end
end
