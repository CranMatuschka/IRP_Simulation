classdef DistributedCovarianceNetwork < handle
    % DistributedCovarianceNetwork  Coordinator-owned correlation-tracked cross-covariance
    % network (plan Stage 3.1). Local marginals P_ii stay in each member's own local EKF and
    % are NEVER duplicated here (item 1): this class owns only named pairwise cross blocks
    % P_ij, each with source epoch/state-map-version/provenance (item 2), declared common
    % process-noise groups (item 3), the propagation rule
    % P_ij <- A_i*(F_i*P_ij*F_j'+Q_ij)*A_j' (item 4), the pair measurement-update PRIMITIVE
    % (item 5, pure -- computes and applies nothing; see revgnss.DistributedPairCovarianceUpdate
    % Result), a PSD/symmetry audit of a transiently-assembled small-fleet covariance (item 6),
    % and a hard configured fleet-size limit enforced at registerFleetMembers (item 7: fails,
    % never silently drops a cross block).
    %
    % Does NOT change revgnss.filter.ReverseGNSSEKF's joint state vector and does not reuse it
    % internally: every quantity here comes from a revgnss.LocalEpochTransitionCaptureProvider
    % (structurally unable to read truth) or from a caller-supplied live local marginal.
    %
    % SCOPE (as of Stage 3.1; Stage 3.2 has since implemented the synchronized two-endpoint
    % delivery protocol this paragraph originally described as missing -- signed correction
    % messages, non-owner delivery, acknowledgement, partial-delivery rejection all now exist,
    % see revgnss.SynchronizedDeliveryContract and revgnss.SynchronizedPairLinkUpdateTransaction).
    % routeForDelivery CAN now return 'pairExact' when correlationNetwork.linkUpdateRouting==
    % 'pairExactWhenBothEndpointsTracked' and the routed observable is pair-exact-eligible -- see
    % routeForDelivery's own header for the current, authoritative routing rule.
    %
    % HONESTY (no fleet-level conservativeness bound claimed for the mixed assembly). Once
    % applyConservativeOwnerOnlyLinkTransform has conditioned any pair, the cross blocks are
    % conditioned on a BOUNDED remote marginal (the Stage-2 conservative route), so the
    % assembled-minus-true difference is not block-diagonal and PSD-ness of that difference is
    % not proven. centralReferenceEquivalenceClaim() reports this automatically from counters,
    % never from a caller-set flag, and downgrades the moment either condition applies.

    properties (SetAccess = immutable)
        policyIdentifier             (1,:) char
        configuredMaximumFleetSize   (1,1) double
        commonProcessNoiseTreatment  (1,:) char
        linkUpdateRoutingPolicy      (1,:) char
        crossBlockSpanKind           (1,:) char
        stateSchemaVersion           (1,:) char
    end

    properties (SetAccess = private)
        memberIdentifiers           (1,:) cell   = {}
        memberStateDimensions       (1,:) double = []
        memberSchemaStateIndices    (1,:) cell   = {}
        memberStateMapFingerprints  (1,:) cell   = {}
        currentCoordinateEpoch_s    (1,1) double = NaN
        epochsAdvanced              (1,1) double = 0
        revisionNumber              (1,1) double = 0
        conservativeOwnerOnlyConditioningCount (1,1) double = 0
        unappliedCorrelatedLocalUpdateCount    (1,1) double = 0
        lastAuditCertificate = []

        % Section 3.2: synchronized two-endpoint delivery counters/state, mirroring the Section
        % 3.1 counters above -- see stagePairExactLinkTransform/commitStagedPairExactLinkTransform
        % and centralReferenceEquivalenceClaim/linkUpdateConditioningClaim, which compute their
        % reported words from these counters and never from a caller-set flag.
        pairExactSynchronizedUpdateCount       (1,1) double  = 0
        pairExactThirdMemberConditioningCount  (1,1) double  = 0
        unappliedThirdMemberCorrectionCount    (1,1) double  = 0
        maximumOmittedThirdMemberVarianceRatio (1,1) double  = 0
        supersededDeliveryRejectionCount       (1,1) double  = 0
        isSealed                               (1,1) logical = false
        sealReason                             (1,:) char    = ''
    end

    properties (Access = private)
        crossBlocks_ containers.Map
        memberRecords_ containers.Map
        commonProcessNoiseGroups_ cell = {}
    end

    methods
        function obj = DistributedCovarianceNetwork(policyRecord)
            revgnss.DistributedCovarianceNetworkContract.requirePolicyRecord(policyRecord);
            policyId = char(policyRecord.policyIdentifier);
            if ~any(strcmp(policyId,revgnss.DistributedCovarianceNetworkContract.AllowedNetworkPolicies))
                error('DistributedCovarianceNetwork:policyIdentifier', ...
                    'policyIdentifier must be one of the frozen AllowedNetworkPolicies.');
            end
            if ~strcmp(policyId,'exactPairwiseCrossCovariance')
                error('DistributedCovarianceNetwork:policyNotConstructible', ...
                    ['A revgnss.DistributedCovarianceNetwork is only ever constructed for ' ...
                    'policyIdentifier=''exactPairwiseCrossCovariance''; ''disabled'' means no ' ...
                    'network object is constructed at all.']);
            end
            ceilingN = revgnss.DistributedCovarianceNetworkContract.MaximumSupportedFleetSize;
            n = policyRecord.configuredMaximumFleetSize;
            if ~(isnumeric(n) && isscalar(n) && n == round(n) && n >= 2 && n <= ceilingN)
                error('DistributedCovarianceNetwork:configuredMaximumFleetSize', ...
                    'configuredMaximumFleetSize must be an integer in [2, %d].',ceilingN);
            end
            treatment = char(policyRecord.commonProcessNoiseTreatment);
            if ~any(strcmp(treatment, ...
                    revgnss.DistributedCovarianceNetworkContract.AllowedCommonProcessNoiseTreatments))
                error('DistributedCovarianceNetwork:commonProcessNoiseTreatment', ...
                    'commonProcessNoiseTreatment must be one of the frozen allowed treatments.');
            end
            routing = char(policyRecord.linkUpdateRoutingPolicy);
            if ~any(strcmp(routing, ...
                    revgnss.DistributedCovarianceNetworkContract.AllowedLinkUpdateRoutingPolicies))
                error('DistributedCovarianceNetwork:linkUpdateRoutingPolicy', ...
                    'linkUpdateRoutingPolicy must be one of the frozen AllowedLinkUpdateRoutingPolicies.');
            end
            if ~strcmp(char(policyRecord.crossBlockSpanKind), ...
                    revgnss.DistributedCovarianceNetworkContract.CrossBlockSpanKind)
                error('DistributedCovarianceNetwork:crossBlockSpanKind', ...
                    'crossBlockSpanKind must be the frozen fullLocalStateSpan value.');
            end
            if ~strcmp(char(policyRecord.stateSchemaVersion), ...
                    revgnss.DistributedLinkProtocolContract.StateSchemaVersion)
                error('DistributedCovarianceNetwork:stateSchemaVersion', ...
                    'stateSchemaVersion must equal the frozen Stage-2 v1 schema version.');
            end

            obj.policyIdentifier = policyId;
            obj.configuredMaximumFleetSize = double(n);
            obj.commonProcessNoiseTreatment = treatment;
            obj.linkUpdateRoutingPolicy = routing;
            obj.crossBlockSpanKind = char(policyRecord.crossBlockSpanKind);
            obj.stateSchemaVersion = char(policyRecord.stateSchemaVersion);
            obj.crossBlocks_ = containers.Map('KeyType','char','ValueType','any');
            obj.memberRecords_ = containers.Map('KeyType','char','ValueType','any');
        end

        function registerFleetMembers(obj, memberRecords)
            % registerFleetMembers  One-shot registration (item 7: hard fleet-size limit,
            % checked BEFORE a single cross block is created -- fails, never drops).
            obj.requireNotSealed_();
            if ~isempty(obj.memberIdentifiers)
                error('DistributedCovarianceNetwork:alreadyRegistered', ...
                    'registerFleetMembers may be called only once per network instance.');
            end
            n = numel(memberRecords);
            ceilingN = revgnss.DistributedCovarianceNetworkContract.MaximumSupportedFleetSize;
            if n > obj.configuredMaximumFleetSize || n > ceilingN
                error('DistributedCovarianceNetwork:fleetSizeLimitExceeded', ...
                    'Fleet size %d exceeds the configured/frozen maximum (%d/%d).', ...
                    n,obj.configuredMaximumFleetSize,ceilingN);
            end
            if n < 2
                error('DistributedCovarianceNetwork:fleetTooSmall', ...
                    'A correlation network requires at least two members.');
            end
            ids = cell(1,n);
            dims = zeros(1,n);
            schemaIdx = cell(1,n);
            fingerprints = cell(1,n);
            for index = 1:n
                record = memberRecords(index);
                revgnss.DistributedCovarianceNetworkContract.requireMemberRecord(record);
                id = char(record.endpointIdentifier);
                if isKey(obj.memberRecords_,id)
                    error('DistributedCovarianceNetwork:duplicateMemberIdentifier', ...
                        'Endpoint %s is registered more than once.',id);
                end
                obj.memberRecords_(id) = record;
                ids{index} = id;
                dims(index) = record.localStateDimension;
                schemaIdx{index} = record.schemaStateIndices(:);
                fingerprints{index} = char(record.localStateMapFingerprint);
            end
            obj.memberIdentifiers = ids;
            obj.memberStateDimensions = dims;
            obj.memberSchemaStateIndices = schemaIdx;
            obj.memberStateMapFingerprints = fingerprints;
        end

        function declareIndependentPriorPairs(obj, coordinateEpoch_s)
            % declareIndependentPriorPairs  P_ij(0)=0 is a per-member DECLARATION
            % (priorIndependenceDeclaration, already asserted by requireMemberRecord), not a
            % silent default.
            obj.requireNotSealed_();
            if isempty(obj.memberIdentifiers)
                error('DistributedCovarianceNetwork:notRegistered', ...
                    'registerFleetMembers must be called before declareIndependentPriorPairs.');
            end
            n = numel(obj.memberIdentifiers);
            for i = 1:n
                for j = i+1:n
                    firstMember = obj.memberRecords_(obj.memberIdentifiers{i});
                    secondMember = obj.memberRecords_(obj.memberIdentifiers{j});
                    block = revgnss.PairwiseCrossCovarianceBlock.independentPriorFor( ...
                        firstMember,secondMember,coordinateEpoch_s);
                    obj.crossBlocks_(block.crossBlockIdentifier) = block;
                end
            end
            obj.currentCoordinateEpoch_s = coordinateEpoch_s;
        end

        function declareCommonProcessNoiseGroup(obj, group)
            obj.requireNotSealed_();
            if ~isa(group,'revgnss.CommonProcessNoiseCovarianceGroup')
                error('DistributedCovarianceNetwork:commonProcessNoiseGroupType', ...
                    'declareCommonProcessNoiseGroup requires a revgnss.CommonProcessNoiseCovarianceGroup.');
            end
            for index = 1:numel(group.memberEndpointIdentifiers)
                if ~obj.isRegisteredMember(group.memberEndpointIdentifiers{index})
                    error('DistributedCovarianceNetwork:commonProcessNoiseGroupUnknownMember', ...
                        'Common process-noise group member %s is not a registered fleet member.', ...
                        group.memberEndpointIdentifiers{index});
                end
            end
            obj.commonProcessNoiseGroups_{end+1} = group;
        end

        function tf = isRegisteredMember(obj, endpointIdentifier)
            tf = isKey(obj.memberRecords_,char(endpointIdentifier));
        end

        function n = fleetSize(obj)
            n = numel(obj.memberIdentifiers);
        end

        function advanceEpoch(obj, epochRecord)
            % advanceEpoch  Items 3+4: P_ij <- A_i*(F_i*P_ij*F_j'+Q_ij)*A_j' for every stored
            % pair. epochRecord.captures must contain exactly one revgnss.
            % LocalEpochTransitionCapture per registered member, matched by identifier.
            obj.requireNotSealed_();
            required = {'coordinateEpoch_s','intervalDuration_s','captures'};
            missing = setdiff(required,fieldnames(epochRecord));
            if ~isempty(missing)
                error('DistributedCovarianceNetwork:epochRecordSchema', ...
                    'advanceEpoch epochRecord is missing %s.',missing{1});
            end
            captures = epochRecord.captures;
            if ~isa(captures,'revgnss.LocalEpochTransitionCapture')
                error('DistributedCovarianceNetwork:captureType', ...
                    'epochRecord.captures must be a revgnss.LocalEpochTransitionCapture array.');
            end
            capIds = arrayfun(@(c) c.endpointIdentifier,captures,'UniformOutput',false);
            if numel(captures) ~= numel(obj.memberIdentifiers) || ...
                    ~isequal(sort(capIds),sort(obj.memberIdentifiers))
                error('DistributedCovarianceNetwork:captureMemberMismatch', ...
                    'The supplied capture set does not match the registered member set exactly.');
            end
            intervalStart = epochRecord.coordinateEpoch_s - epochRecord.intervalDuration_s;
            captureById = containers.Map('KeyType','char','ValueType','any');
            for index = 1:numel(captures)
                cap = captures(index);
                if abs(cap.intervalStartCoordinateEpoch_s-intervalStart) > 1e-9 || ...
                        abs(cap.intervalDuration_s-epochRecord.intervalDuration_s) > 1e-9
                    error('DistributedCovarianceNetwork:captureEpochMismatch', ...
                        'Capture for %s does not match the requested epoch interval.', ...
                        cap.endpointIdentifier);
                end
                memberIdx = find(strcmp(obj.memberIdentifiers,cap.endpointIdentifier),1);
                if cap.localStateDimension ~= obj.memberStateDimensions(memberIdx)
                    error('DistributedCovarianceNetwork:captureDimensionMismatch', ...
                        'Capture for %s has a dimension mismatch against the registered member.', ...
                        cap.endpointIdentifier);
                end
                if ~strcmp(cap.localStateMapFingerprint,obj.memberStateMapFingerprints{memberIdx})
                    error('DistributedCovarianceNetwork:localStateMapFingerprintChanged', ...
                        'Member %s''s local state-map fingerprint has changed since registration.', ...
                        cap.endpointIdentifier);
                end
                if cap.unmodelledCovarianceTransformCount > 0
                    error('DistributedCovarianceNetwork:unmodelledCovarianceTransform', ...
                        ['Member %s''s epoch-transition capture recorded an unmodelled covariance ' ...
                        'transform (%s); the retained operators do not describe its P.'], ...
                        cap.endpointIdentifier,strjoin(cap.unmodelledCovarianceTransformKinds,','));
                end
                captureById(cap.endpointIdentifier) = cap;
            end

            keysNow = obj.crossBlocks_.keys;
            for index = 1:numel(keysNow)
                block = obj.crossBlocks_(keysNow{index});
                capI = captureById(block.firstEndpointIdentifier);
                capJ = captureById(block.secondEndpointIdentifier);
                Fi = capI.stateTransition; Ai = capI.localUpdateContraction;
                Fj = capJ.stateTransition; Aj = capJ.localUpdateContraction;
                Pij = block.crossCovariance;
                Qij = zeros(size(Pij));
                contributingGroupIds = {};
                if ~strcmp(obj.commonProcessNoiseTreatment,'rejected')
                    for g = 1:numel(obj.commonProcessNoiseGroups_)
                        group = obj.commonProcessNoiseGroups_{g};
                        if any(strcmp(group.memberEndpointIdentifiers,block.firstEndpointIdentifier)) && ...
                                any(strcmp(group.memberEndpointIdentifiers,block.secondEndpointIdentifier))
                            Qij = Qij + group.crossProcessNoise(epochRecord.intervalDuration_s, ...
                                capI.schemaStateIndices,capJ.schemaStateIndices,size(Pij,1),size(Pij,2));
                            contributingGroupIds{end+1} = group.processNoiseGroupIdentifier; %#ok<AGROW>
                        end
                    end
                end
                newPij = Ai*(Fi*Pij*Fj' + Qij)*Aj';
                if any(~isfinite(newPij(:)))
                    error('DistributedCovarianceNetwork:nonFiniteCrossBlock', ...
                        'Propagated cross block %s is not finite.',keysNow{index});
                end
                newRecord = struct( ...
                    'firstEndpointIdentifier',block.firstEndpointIdentifier, ...
                    'secondEndpointIdentifier',block.secondEndpointIdentifier, ...
                    'crossCovariance',newPij, ...
                    'crossBlockSpanKind',block.crossBlockSpanKind, ...
                    'sourceCoordinateEpoch_s',epochRecord.coordinateEpoch_s, ...
                    'stateSchemaVersion',block.stateSchemaVersion, ...
                    'firstLocalStateMapFingerprint',capI.localStateMapFingerprint, ...
                    'secondLocalStateMapFingerprint',capJ.localStateMapFingerprint, ...
                    'firstSchemaStateIndices',capI.schemaStateIndices, ...
                    'secondSchemaStateIndices',capJ.schemaStateIndices, ...
                    'provenanceKind','propagatedAndConditionedOnLocalUpdate', ...
                    'provenanceDetail',sprintf( ...
                        'predict+local-update propagation at coordinate epoch %.6f',epochRecord.coordinateEpoch_s), ...
                    'contributingObservationIdentifiers',{{}}, ...
                    'contributingCommonProcessGroupIdentifiers',{contributingGroupIds}, ...
                    'transformCount',block.transformCount+1, ...
                    'networkRevisionNumber',obj.revisionNumber+1);
                obj.crossBlocks_(keysNow{index}) = revgnss.PairwiseCrossCovarianceBlock.fromRecord(newRecord);
            end
            obj.currentCoordinateEpoch_s = epochRecord.coordinateEpoch_s;
            obj.epochsAdvanced = obj.epochsAdvanced+1;
            obj.revisionNumber = obj.revisionNumber+1;
        end

        function applyConservativeOwnerOnlyLinkTransform(obj, transformRecord)
            % applyConservativeOwnerOnlyLinkTransform  Section 2.4 conditioning: the live
            % coordinator path applies the Stage-2 conservative owner-only update, never the
            % pair-exact primitive, so the network must stay conditioned on THAT update or its
            % cross blocks go stale from the first delivery onward.
            %
            %   P_ij+ = A*P_ij + B*P_jj(S_j,:)              (the link partner j)
            %   P_ik+ = A*P_ik + B*P_jk(S_j,:)   k not in {i,j}  (every third member)
            %
            % P_jj/P_jk are read live via transformRecord.remoteLocalMarginalSupply, NEVER from
            % a frozen published product: consuming a stale snapshot instead of the live
            % marginal would silently substitute a stale prior.
            obj.requireNotSealed_();
            required = {'ownerEndpointIdentifier','remoteEndpointIdentifier','coordinateEpoch_s', ...
                'ownerErrorTransition_A','remoteSchemaErrorCoupling_B','remoteLocalMarginalSupply'};
            missing = setdiff(required,fieldnames(transformRecord));
            if ~isempty(missing)
                error('DistributedCovarianceNetwork:transformRecordSchema', ...
                    'applyConservativeOwnerOnlyLinkTransform transformRecord is missing %s.',missing{1});
            end
            ownerId = char(transformRecord.ownerEndpointIdentifier);
            remoteId = char(transformRecord.remoteEndpointIdentifier);
            if ~obj.isRegisteredMember(ownerId)
                return   % owner not tracked by this network: nothing to condition
            end
            A = transformRecord.ownerErrorTransition_A;
            B = transformRecord.remoteSchemaErrorCoupling_B;
            marginals = transformRecord.remoteLocalMarginalSupply;
            marginalIds = {marginals.endpointIdentifier};

            keysNow = obj.crossBlocks_.keys;
            touchedAny = false;
            for index = 1:numel(keysNow)
                block = obj.crossBlocks_(keysNow{index});
                if strcmp(block.firstEndpointIdentifier,ownerId)
                    otherId = block.secondEndpointIdentifier;
                    Pij = block.crossCovariance;
                elseif strcmp(block.secondEndpointIdentifier,ownerId)
                    otherId = block.firstEndpointIdentifier;
                    Pij = block.crossCovariance';
                else
                    continue
                end
                touchedAny = true;
                entryIdx = find(strcmp(marginalIds,otherId),1);
                if isempty(entryIdx)
                    error('DistributedCovarianceNetwork:remoteMarginalMissingForPair', ...
                        'No live local marginal was supplied for tracked pair member %s.',otherId);
                end
                remoteSchemaIdx = obj.memberSchemaStateIndices{strcmp(obj.memberIdentifiers,remoteId)};
                if strcmp(otherId,remoteId)
                    Pother = marginals(entryIdx).localMarginal;
                    coupling = B*Pother(remoteSchemaIdx,:);
                else
                    remoteOtherKey = revgnss.DistributedCovarianceNetworkContract.canonicalPairKey( ...
                        remoteId,otherId);
                    if ~isKey(obj.crossBlocks_,remoteOtherKey)
                        error('DistributedCovarianceNetwork:crossBlockAbsentForPair', ...
                            'No cross block exists for pair (%s,%s).',remoteId,otherId);
                    end
                    remoteOtherBlock = obj.crossBlocks_(remoteOtherKey);
                    Pjk = remoteOtherBlock.orientedTo(remoteId,otherId);
                    coupling = B*Pjk(remoteSchemaIdx,:);
                end
                newPijOwnerFirst = A*Pij + coupling;
                if strcmp(block.firstEndpointIdentifier,ownerId)
                    firstId = ownerId; secondId = otherId; newCross = newPijOwnerFirst;
                    firstFp = block.firstLocalStateMapFingerprint;
                    secondFp = block.secondLocalStateMapFingerprint;
                    firstIdx = block.firstSchemaStateIndices;
                    secondIdx = block.secondSchemaStateIndices;
                else
                    firstId = otherId; secondId = ownerId; newCross = newPijOwnerFirst';
                    firstFp = block.secondLocalStateMapFingerprint;
                    secondFp = block.firstLocalStateMapFingerprint;
                    firstIdx = block.secondSchemaStateIndices;
                    secondIdx = block.firstSchemaStateIndices;
                end
                if any(~isfinite(newCross(:)))
                    error('DistributedCovarianceNetwork:nonFiniteCrossBlock', ...
                        'Conservative-conditioned cross block %s is not finite.',keysNow{index});
                end
                newRecord = struct( ...
                    'firstEndpointIdentifier',firstId,'secondEndpointIdentifier',secondId, ...
                    'crossCovariance',newCross,'crossBlockSpanKind',block.crossBlockSpanKind, ...
                    'sourceCoordinateEpoch_s',transformRecord.coordinateEpoch_s, ...
                    'stateSchemaVersion',block.stateSchemaVersion, ...
                    'firstLocalStateMapFingerprint',firstFp,'secondLocalStateMapFingerprint',secondFp, ...
                    'firstSchemaStateIndices',firstIdx,'secondSchemaStateIndices',secondIdx, ...
                    'provenanceKind','conditionedOnConservativeOwnerOnlyLinkUpdate', ...
                    'provenanceDetail',sprintf( ...
                        'conditioned on a conservative owner-only link update at owner %s',ownerId), ...
                    'contributingObservationIdentifiers',{{}}, ...
                    'contributingCommonProcessGroupIdentifiers',{{}}, ...
                    'transformCount',block.transformCount+1, ...
                    'networkRevisionNumber',obj.revisionNumber+1);
                obj.crossBlocks_(keysNow{index}) = revgnss.PairwiseCrossCovarianceBlock.fromRecord(newRecord);
            end
            if touchedAny
                obj.conservativeOwnerOnlyConditioningCount = obj.conservativeOwnerOnlyConditioningCount+1;
                obj.revisionNumber = obj.revisionNumber+1;
            end
        end

        function noteUnappliedCorrelatedLocalUpdate(obj, endpointIdentifier, coordinateEpoch_s) %#ok<INUSD>
            % noteUnappliedCorrelatedLocalUpdate  Once P_ij~=0, a member's own local ground/
            % onboard update at that epoch is correlated information a centralized filter would
            % have used to correct its correlated partner too; this architecture does not (at
            % 3.1 or 3.2). The covariance stays exact for the estimators that actually ran; the
            % estimates are sub-optimal versus the centralized reference. Counted so
            % centralReferenceEquivalenceClaim reports this automatically.
            obj.requireNotSealed_();
            obj.unappliedCorrelatedLocalUpdateCount = obj.unappliedCorrelatedLocalUpdateCount+1;
        end

        function block = crossBlockFor(obj, firstEndpointIdentifier, secondEndpointIdentifier)
            obj.requireNotSealed_();
            key = revgnss.DistributedCovarianceNetworkContract.canonicalPairKey( ...
                firstEndpointIdentifier,secondEndpointIdentifier);
            if ~isKey(obj.crossBlocks_,key)
                error('DistributedCovarianceNetwork:crossBlockAbsentForPair', ...
                    'No cross block exists for pair (%s,%s).', ...
                    char(firstEndpointIdentifier),char(secondEndpointIdentifier));
            end
            block = obj.crossBlocks_(key);
        end

        function M = orientedCrossCovariance(obj, firstEndpointIdentifier, secondEndpointIdentifier)
            block = obj.crossBlockFor(firstEndpointIdentifier,secondEndpointIdentifier);
            M = block.orientedTo(firstEndpointIdentifier,secondEndpointIdentifier);
        end

        function keysOut = crossBlockIdentifiers(obj)
            keysOut = obj.crossBlocks_.keys;
        end

        function rev = currentRevisionNumber(obj)
            rev = obj.revisionNumber;
        end

        function P = assembleDeclaredFleetCovariance(obj, localMarginalSupply)
            % assembleDeclaredFleetCovariance  Test/diagnostic only: transiently assembles
            % [P_ii on the diagonal; P_ij/P_ij' off-diagonal] from a caller-supplied live
            % marginal set plus the owned cross blocks. NEVER stored: there is never a second
            % source of truth for data the leaves own.
            n = numel(obj.memberIdentifiers);
            dims = obj.memberStateDimensions;
            offsets = [0,cumsum(dims)];
            total = offsets(end);
            if total > revgnss.DistributedCovarianceNetworkContract.MaximumAssembledFleetDimension
                error('DistributedCovarianceNetwork:assembledFleetDimensionLimitExceeded', ...
                    'The assembled fleet dimension exceeds MaximumAssembledFleetDimension.');
            end
            marginalIds = {localMarginalSupply.endpointIdentifier};
            P = zeros(total,total);
            for i = 1:n
                idxI = offsets(i)+1:offsets(i+1);
                entryIdx = find(strcmp(marginalIds,obj.memberIdentifiers{i}),1);
                if isempty(entryIdx)
                    error('DistributedCovarianceNetwork:localMarginalMissing', ...
                        'No live local marginal was supplied for member %s.',obj.memberIdentifiers{i});
                end
                Pii = localMarginalSupply(entryIdx).localMarginal;
                if ~isequal(size(Pii),[dims(i) dims(i)])
                    error('DistributedCovarianceNetwork:localMarginalDimension', ...
                        'The supplied local marginal for %s has the wrong dimension.', ...
                        obj.memberIdentifiers{i});
                end
                P(idxI,idxI) = (Pii+Pii')/2;
                for j = i+1:n
                    idxJ = offsets(j)+1:offsets(j+1);
                    Mij = obj.orientedCrossCovariance(obj.memberIdentifiers{i},obj.memberIdentifiers{j});
                    P(idxI,idxJ) = Mij;
                    P(idxJ,idxI) = Mij';
                end
            end
        end

        function audit = auditAssembledFleetCovariance(obj, auditRequest)
            required = {'localMarginalSupply','auditCoordinateEpoch_s'};
            missing = setdiff(required,fieldnames(auditRequest));
            if ~isempty(missing)
                error('DistributedCovarianceNetwork:auditRequestSchema', ...
                    'auditAssembledFleetCovariance auditRequest is missing %s.',missing{1});
            end
            P = obj.assembleDeclaredFleetCovariance(auditRequest.localMarginalSupply);
            n = numel(obj.memberIdentifiers);
            dims = obj.memberStateDimensions;
            offsets = [0,cumsum(dims)];

            symFro = norm(P-P','fro');
            symRel = symFro/max(1,norm(P,'fro'));
            % max(...,0) before sqrt: a non-finite/negative diagonal entry (a corrupted or
            % genuinely non-PD supplied local marginal) must never produce a COMPLEX D --
            % sqrt of a negative real returns 0+bi in MATLAB, and the subsequent D(D<=0)=1
            % compares only the real part, silently leaving imaginary residue in D and in
            % every eigenvalue/condition-number computed from it.
            D = sqrt(max(diag(P),0));
            D(D==0) = 1;
            Dinv = diag(1./D);
            scaled = Dinv*P*Dinv;
            scaled = (scaled+scaled')/2;
            eigsScaled = eig(scaled);
            minEig = min(eigsScaled);
            posEigs = eigsScaled(eigsScaled > 1e-14);
            if isempty(posEigs)
                condNum = Inf;
            else
                condNum = max(eigsScaled)/min(posEigs);
            end

            maxRho = 0;
            worstKey = '';
            staleKeys = {};
            for i = 1:n
                for j = i+1:n
                    key = revgnss.DistributedCovarianceNetworkContract.canonicalPairKey( ...
                        obj.memberIdentifiers{i},obj.memberIdentifiers{j});
                    block = obj.crossBlocks_(key);
                    if abs(block.sourceCoordinateEpoch_s-auditRequest.auditCoordinateEpoch_s) > 1e-9
                        staleKeys{end+1} = key; %#ok<AGROW>
                    end
                    idxI = offsets(i)+1:offsets(i+1);
                    idxJ = offsets(j)+1:offsets(j+1);
                    % Read from the already unit-diagonal-rescaled `scaled` matrix, not raw P:
                    % an exact diagonal congruence of Pii/Pjj/Pij preserves the canonical
                    % correlation exactly (it is scale-invariant) while giving chol() a far
                    % better-conditioned input, so a merely ill-scaled (not actually singular)
                    % local marginal no longer risks a spurious chol failure here.
                    Pii = scaled(idxI,idxI); Pjj = scaled(idxJ,idxJ); Pij = scaled(idxI,idxJ);
                    try
                        Li = chol(Pii,'lower');
                        Lj = chol(Pjj,'lower');
                        canon = Li\Pij/Lj';
                        rho = max(svd(canon));
                    catch
                        rho = Inf;
                    end
                    if rho > maxRho
                        maxRho = rho;
                        worstKey = key;
                    end
                end
            end

            % Precedence: the per-pair canonical-correlation check is checked BEFORE the coarser
            % global scaled-eigenvalue floor. By the Cauchy interlacing theorem, a genuine
            % Cauchy-Schwarz violation in any pair's own 2-block principal submatrix always
            % forces the FULL assembled matrix to be non-PSD too (a negative eigenvalue in a
            % principal submatrix propagates to the full matrix) -- so whenever a violation CAN
            % be localized to one named pair, checking correlation first reports the more
            % actionable, sharper verdict; the global check then remains for genuinely N-way
            % joint violations that are not localizable to any single pair (verified by
            % execution: ordering it after the global check made every practical PSD violation
            % report the less-informative verdict, since violations essentially always
            % localize to at least one pair).
            if ~isempty(staleKeys)
                verdict = 'staleCrossBlock';
            elseif symRel > revgnss.DistributedCovarianceNetworkContract.SymmetryToleranceRelative
                verdict = 'symmetryViolation';
            elseif maxRho > 1+revgnss.DistributedCovarianceNetworkContract.CanonicalCorrelationToleranceAbsolute
                verdict = 'pairCanonicalCorrelationViolation';
            elseif minEig < -revgnss.DistributedCovarianceNetworkContract.PositiveSemiDefiniteToleranceScaled
                verdict = 'positiveSemiDefiniteViolation';
            else
                verdict = 'symmetricPositiveSemiDefinite';
            end

            record = struct( ...
                'auditCoordinateEpoch_s',auditRequest.auditCoordinateEpoch_s, ...
                'networkRevisionNumber',obj.revisionNumber, ...
                'endpointIdentifiers',{obj.memberIdentifiers}, ...
                'endpointDimensions',dims, ...
                'assembledDimension',sum(dims), ...
                'symmetryResidualFrobenius',symFro, ...
                'symmetryResidualRelative',symRel, ...
                'minimumScaledEigenvalue',minEig, ...
                'scaledConditionNumber',condNum, ...
                'maximumPairCanonicalCorrelation',maxRho, ...
                'worstPairKey',worstKey, ...
                'staleCrossBlockPairKeys',{staleKeys}, ...
                'benignDiagonalNudgeEventCount',0, ...
                'isSymmetricPositiveSemiDefinite',strcmp(verdict,'symmetricPositiveSemiDefinite'), ...
                'verdict',verdict);
            audit = revgnss.DistributedFleetCovarianceAudit.fromRecord(record);
            obj.lastAuditCertificate = audit;
        end

        function requireAssembledFleetCovarianceSymmetricPsd(obj, auditRequest)
            audit = obj.auditAssembledFleetCovariance(auditRequest);
            if ~audit.isSymmetricPositiveSemiDefinite
                error('DistributedCovarianceNetwork:auditFailed', ...
                    'Assembled fleet covariance audit failed: %s.',audit.verdict);
            end
        end

        function Pdr = relativeSchemaCovariance(obj, firstId, secondId, firstSchemaMarginal, secondSchemaMarginal)
            % relativeSchemaCovariance  P_i+P_j-P_ij-P_ji restricted to the 14-schema block
            % (plan Section 3.5 formula). Computed here as one line off the stored data;
            % REPORTING it is Section 3.5 scope.
            block = obj.crossBlockFor(firstId,secondId);
            firstIdx = obj.memberSchemaStateIndices{strcmp(obj.memberIdentifiers,char(firstId))};
            secondIdx = obj.memberSchemaStateIndices{strcmp(obj.memberIdentifiers,char(secondId))};
            Mij = block.orientedTo(firstId,secondId);
            PijSchema = Mij(firstIdx,secondIdx);
            Pdr = firstSchemaMarginal+secondSchemaMarginal-PijSchema-PijSchema';
        end

        function [route, reasonCode] = routeForDelivery(obj, routeRequest)
            % routeForDelivery  Item 5's routing decision. Returns 'pairExact' iff ALL of: both
            % endpoints are registered members; a cross block exists for the pair; it is fresh
            % at this exact coordinate epoch (no interpolation, matching the existing
            % remoteProductPropagationPolicy='frozenSameEpochOnly' discipline); both stored
            % fingerprints match the endpoints' CURRENT ones; its provenance is usable; the
            % observable is pair-exact eligible; the clock claim is gauge-anchored; AND
            % linkUpdateRoutingPolicy=='pairExactWhenBothEndpointsTracked'. The two observable/
            % clock-gauge checks (Section 3.2) only run when the caller supplies the optional
            % routeRequest.observableIdentifier/clockClaim/pairAbsolutelyAnchored fields --
            % omitting them exercises checks 1-5 and the routing-policy word in isolation, which
            % revgnss.SynchronizedPairLinkUpdateTransaction's real caller never does.
            obj.requireNotSealed_();
            required = {'ownerAssetIdentifier','remoteAssetIdentifier','coordinateEventEpoch_s'};
            missing = setdiff(required,fieldnames(routeRequest));
            if ~isempty(missing)
                error('DistributedCovarianceNetwork:routeRequestSchema', ...
                    'routeForDelivery routeRequest is missing %s.',missing{1});
            end
            route = 'conservativeBound';
            ownerId = char(routeRequest.ownerAssetIdentifier);
            remoteId = char(routeRequest.remoteAssetIdentifier);
            if ~(obj.isRegisteredMember(ownerId) && obj.isRegisteredMember(remoteId))
                reasonCode = 'endpointNotFleetMember';
                return
            end
            key = revgnss.DistributedCovarianceNetworkContract.canonicalPairKey(ownerId,remoteId);
            if ~isKey(obj.crossBlocks_,key)
                reasonCode = 'crossBlockAbsentForPair';
                return
            end
            block = obj.crossBlocks_(key);
            if abs(block.sourceCoordinateEpoch_s-routeRequest.coordinateEventEpoch_s) > 1e-9
                reasonCode = 'crossBlockEpochStale';
                return
            end
            ownerIdx = find(strcmp(obj.memberIdentifiers,ownerId),1);
            remoteIdx = find(strcmp(obj.memberIdentifiers,remoteId),1);
            if strcmp(block.firstEndpointIdentifier,ownerId)
                storedOwnerFp = block.firstLocalStateMapFingerprint;
                storedRemoteFp = block.secondLocalStateMapFingerprint;
            else
                storedOwnerFp = block.secondLocalStateMapFingerprint;
                storedRemoteFp = block.firstLocalStateMapFingerprint;
            end
            if ~strcmp(storedOwnerFp,obj.memberStateMapFingerprints{ownerIdx}) || ...
                    ~strcmp(storedRemoteFp,obj.memberStateMapFingerprints{remoteIdx})
                reasonCode = 'crossBlockStateMapFingerprintChanged';
                return
            end
            if ~any(strcmp(block.provenanceKind, ...
                    revgnss.DistributedCovarianceNetworkContract.AllowedCrossBlockProvenanceKinds))
                reasonCode = 'crossBlockProvenanceUnusable';
                return
            end
            if isfield(routeRequest,'observableIdentifier') && ~isempty(routeRequest.observableIdentifier) && ...
                    ~revgnss.SynchronizedDeliveryContract.isPairExactEligibleObservable( ...
                    routeRequest.observableIdentifier)
                reasonCode = 'pairExactRefusedObservableNotEligible';
                return
            end
            if isfield(routeRequest,'clockClaim') && strcmp(char(routeRequest.clockClaim),'relativeBiasOnly') && ...
                    ~(isfield(routeRequest,'pairAbsolutelyAnchored') && logical(routeRequest.pairAbsolutelyAnchored))
                reasonCode = 'pairExactRefusedClockGaugeNotAnchored';
                return
            end
            if ~strcmp(obj.linkUpdateRoutingPolicy,'pairExactWhenBothEndpointsTracked')
                reasonCode = 'pairExactRouteRequiresSynchronizedDeliveryStage';
                return
            end
            route = 'pairExact';
            reasonCode = 'pairExactRouteAvailable';
        end

        function claim = centralReferenceEquivalenceClaim(obj)
            % centralReferenceEquivalenceClaim  Computed from counters, never set: worst-first
            % precedence so a machine-computed word cannot drift from reality the way prose can.
            %
            % Section 3.2 inserts two new tiers between the Section 3.1 pair (unapplied-
            % correlated-local-update / conservative-owner-only) and the Section 3.1 best case
            % (exact linear propagation only). A single conservative-owner-only conditioning
            % ANYWHERE in the fleet still outranks every pair-exact tier: once one pair's cross
            % blocks are conditioned on a bounded remote marginal, the assembled-minus-true
            % difference is not block-diagonal fleet-wide (this class's own header), so no
            % fleet-level equivalence claim is sound even where a DIFFERENT pair was updated
            % exactly. Within the pair-exact-only regime (no conservative conditioning has ever
            % run), a 2-member fleet has exactly one possible pair, so a pair-exact update on it
            % is genuinely complete coverage; a >2-member fleet always has at least one OTHER
            % pair this particular delivery did not touch (its own cross block, and its own
            % owner-only route), so full central-reference equivalence cannot be claimed there
            % even though every block this delivery DID touch is exact.
            if obj.unappliedCorrelatedLocalUpdateCount > 0
                claim = 'notEquivalentUnappliedCorrelatedLocalUpdates';
            elseif obj.unappliedThirdMemberCorrectionCount > 0
                claim = 'notEquivalentUnappliedThirdMemberCorrections';
            elseif obj.conservativeOwnerOnlyConditioningCount > 0
                claim = 'conditionedOnConservativeOwnerOnlyUpdatesNoFleetBoundClaimed';
            elseif obj.pairExactSynchronizedUpdateCount > 0
                if obj.fleetSize() <= 2
                    claim = 'exactPairSynchronizedUpdatesCentralReferenceEquivalent';
                else
                    claim = 'exactPairConditionedNonPairLinksRemainConservative';
                end
            elseif obj.epochsAdvanced > 0
                claim = 'exactLinearPropagationOfDeclaredLocalCovariances';
            else
                claim = 'notEvaluated';
            end
        end

        function claim = linkUpdateConditioningClaim(obj)
            % linkUpdateConditioningClaim  Orthogonal to centralReferenceEquivalenceClaim above:
            % WHICH routing rule(s) actually fired this run, independent of whether local ground
            % updates went uncorrelated. See DistributedCovarianceNetworkContract.
            % AllowedLinkUpdateConditioningClaims's own header for why this is a separate word.
            hasConservative = obj.conservativeOwnerOnlyConditioningCount > 0;
            hasExact = obj.pairExactSynchronizedUpdateCount > 0;
            if hasConservative && hasExact
                claim = 'mixedExactAndConservative';
            elseif hasExact
                claim = 'exactPairSynchronizedOnly';
            elseif hasConservative
                claim = 'conservativeOwnerOnlyOnly';
            else
                claim = 'notEvaluated';
            end
        end

        function s = policySummary(obj)
            s = struct( ...
                'policyIdentifier',obj.policyIdentifier, ...
                'configuredMaximumFleetSize',obj.configuredMaximumFleetSize, ...
                'commonProcessNoiseTreatment',obj.commonProcessNoiseTreatment, ...
                'linkUpdateRoutingPolicy',obj.linkUpdateRoutingPolicy, ...
                'crossBlockSpanKind',obj.crossBlockSpanKind, ...
                'stateSchemaVersion',obj.stateSchemaVersion, ...
                'fleetSize',obj.fleetSize());
        end

        function s = provenanceSummary(obj)
            s = struct( ...
                'epochsAdvanced',obj.epochsAdvanced, ...
                'revisionNumber',obj.revisionNumber, ...
                'conservativeOwnerOnlyConditioningCount',obj.conservativeOwnerOnlyConditioningCount, ...
                'unappliedCorrelatedLocalUpdateCount',obj.unappliedCorrelatedLocalUpdateCount, ...
                'pairExactSynchronizedUpdateCount',obj.pairExactSynchronizedUpdateCount, ...
                'pairExactThirdMemberConditioningCount',obj.pairExactThirdMemberConditioningCount, ...
                'unappliedThirdMemberCorrectionCount',obj.unappliedThirdMemberCorrectionCount, ...
                'maximumOmittedThirdMemberVarianceRatio',obj.maximumOmittedThirdMemberVarianceRatio, ...
                'supersededDeliveryRejectionCount',obj.supersededDeliveryRejectionCount, ...
                'isSealed',obj.isSealed, ...
                'sealReason',obj.sealReason, ...
                'linkUpdateConditioningClaim',obj.linkUpdateConditioningClaim(), ...
                'centralReferenceEquivalenceClaim',obj.centralReferenceEquivalenceClaim(), ...
                'currentCoordinateEpoch_s',obj.currentCoordinateEpoch_s);
        end

        function s = toStruct(obj)
            s = obj.policySummary();
            prov = obj.provenanceSummary();
            names = fieldnames(prov);
            for index = 1:numel(names)
                s.(names{index}) = prov.(names{index});
            end
        end

        function staged = stagePairExactLinkTransform(obj, message)
            % stagePairExactLinkTransform  Section 3.2 item 6/7 phase 1b: validates and BUILDS
            % every replacement cross block a signed revgnss.SynchronizedPairCorrectionMessage
            % implies, but mutates NOTHING -- obj.crossBlocks_ is read only. Refuses (throws,
            % never partially stages) on: an unregistered or unknown-pair endpoint
            % (:crossBlockMissingForThirdMember), a same-epoch pair already conditioned by an
            % earlier pair-exact commit this epoch (:linearizationPointSupersededByPairExactUpdate
            % -- the honest refusal the order-invariance proof requires for overlapping pairs,
            % see revgnss.SynchronizedDeliveryContract's header), a dimension mismatch against
            % the stored block, or a duplicate staged pair.
            obj.requireNotSealed_();
            if ~isa(message,'revgnss.SynchronizedPairCorrectionMessage')
                error('DistributedCovarianceNetwork:messageType', ...
                    'stagePairExactLinkTransform requires a revgnss.SynchronizedPairCorrectionMessage.');
            end
            revgnss.SynchronizedPairCorrectionMessage.requireIntact(message);
            revgnss.SynchronizedPairCorrectionMessage.requireApplicableNow(message,obj.revisionNumber);

            corrections = message.crossBlockCorrections;
            nCorr = numel(corrections);
            replacementKeys = cell(1,nCorr);
            replacementBlocks = cell(1,nCorr);
            for index = 1:nCorr
                corr = corrections(index);
                firstId = char(corr.firstEndpointIdentifier);
                secondId = char(corr.secondEndpointIdentifier);
                if ~(obj.isRegisteredMember(firstId) && obj.isRegisteredMember(secondId))
                    error('DistributedCovarianceNetwork:crossBlockMissingForThirdMember', ...
                        'Staged correction addresses pair (%s,%s) with an unregistered member.', ...
                        firstId,secondId);
                end
                key = revgnss.DistributedCovarianceNetworkContract.canonicalPairKey(firstId,secondId);
                if ~isKey(obj.crossBlocks_,key)
                    error('DistributedCovarianceNetwork:crossBlockMissingForThirdMember', ...
                        'No cross block exists for staged pair (%s,%s).',firstId,secondId);
                end
                existing = obj.crossBlocks_(key);
                if abs(existing.sourceCoordinateEpoch_s-message.coordinateEventEpoch_s) < 1e-9 && ...
                        strcmp(existing.provenanceKind,'conditionedOnPairExactLinkUpdate')
                    error('DistributedCovarianceNetwork:linearizationPointSupersededByPairExactUpdate', ...
                        ['Cross block %s was already conditioned by a pair-exact update at this ' ...
                        'exact coordinate epoch; a second synchronized delivery touching the same ' ...
                        'block this epoch cannot be exact-order-invariant and is refused rather ' ...
                        'than silently applied.'],key);
                end
                firstOriented = strcmp(existing.firstEndpointIdentifier,firstId);
                if firstOriented
                    newCrossStored = corr.posteriorCrossCovariance;
                else
                    newCrossStored = corr.posteriorCrossCovariance';
                end
                if ~isequal(size(newCrossStored),size(existing.crossCovariance))
                    error('DistributedCovarianceNetwork:crossBlockDimensionMismatch', ...
                        'Staged correction for pair (%s,%s) does not match the stored block''s dimension.', ...
                        firstId,secondId);
                end
                firstIdx = find(strcmp(obj.memberIdentifiers,existing.firstEndpointIdentifier),1);
                secondIdx = find(strcmp(obj.memberIdentifiers,existing.secondEndpointIdentifier),1);
                newRecord = struct( ...
                    'firstEndpointIdentifier',existing.firstEndpointIdentifier, ...
                    'secondEndpointIdentifier',existing.secondEndpointIdentifier, ...
                    'crossCovariance',newCrossStored, ...
                    'crossBlockSpanKind',existing.crossBlockSpanKind, ...
                    'sourceCoordinateEpoch_s',message.coordinateEventEpoch_s, ...
                    'stateSchemaVersion',existing.stateSchemaVersion, ...
                    'firstLocalStateMapFingerprint',obj.memberStateMapFingerprints{firstIdx}, ...
                    'secondLocalStateMapFingerprint',obj.memberStateMapFingerprints{secondIdx}, ...
                    'firstSchemaStateIndices',obj.memberSchemaStateIndices{firstIdx}, ...
                    'secondSchemaStateIndices',obj.memberSchemaStateIndices{secondIdx}, ...
                    'provenanceKind','conditionedOnPairExactLinkUpdate', ...
                    'provenanceDetail',sprintf('conditioned on synchronized pair-exact delivery %s', ...
                        message.messageIdentifier), ...
                    'contributingObservationIdentifiers',{{message.observationIdentifier}}, ...
                    'contributingCommonProcessGroupIdentifiers',{{}}, ...
                    'transformCount',existing.transformCount+1, ...
                    'networkRevisionNumber',obj.revisionNumber+1);
                replacementKeys{index} = key;
                replacementBlocks{index} = revgnss.PairwiseCrossCovarianceBlock.fromRecord(newRecord);
            end
            if numel(unique(replacementKeys)) ~= numel(replacementKeys)
                error('DistributedCovarianceNetwork:duplicateStagedCrossBlock', ...
                    'A synchronized correction message must not stage the same cross block twice.');
            end
            untouchedKeys = setdiff(obj.crossBlocks_.keys,replacementKeys);
            staged = struct( ...
                'messageIdentifier',message.messageIdentifier, ...
                'coordinateEventEpoch_s',message.coordinateEventEpoch_s, ...
                'replacementKeys',{replacementKeys}, ...
                'replacementBlocks',{replacementBlocks}, ...
                'untouchedKeys',{untouchedKeys}, ...
                'preparedAgainstRevisionNumber',obj.revisionNumber, ...
                'thirdMemberOmissionAudit',message.thirdMemberOmissionAudit, ...
                'hasThirdMemberCorrections',nCorr>1);
        end

        function preImage = stagedPreImage(obj, staged)
            % stagedPreImage  Journals the live pre-commit VALUE of every block a staged
            % transform is about to replace, plus every counter commitStagedPairExactLinkTransform
            % is about to bump -- read-only, called before the one mutating commit step.
            obj.requireNotSealed_();
            n = numel(staged.replacementKeys);
            preBlocks = cell(1,n);
            for index = 1:n
                preBlocks{index} = obj.crossBlocks_(staged.replacementKeys{index});
            end
            preImage = struct( ...
                'replacementKeys',{staged.replacementKeys}, ...
                'preReplacementBlocks',{preBlocks}, ...
                'untouchedKeys',{staged.untouchedKeys}, ...
                'preRevisionNumber',obj.revisionNumber, ...
                'preConservativeOwnerOnlyConditioningCount',obj.conservativeOwnerOnlyConditioningCount, ...
                'prePairExactSynchronizedUpdateCount',obj.pairExactSynchronizedUpdateCount, ...
                'prePairExactThirdMemberConditioningCount',obj.pairExactThirdMemberConditioningCount, ...
                'preUnappliedThirdMemberCorrectionCount',obj.unappliedThirdMemberCorrectionCount, ...
                'preMaximumOmittedThirdMemberVarianceRatio',obj.maximumOmittedThirdMemberVarianceRatio);
        end

        function commitStagedPairExactLinkTransform(obj, staged)
            % commitStagedPairExactLinkTransform  The ONE mutating step of the network's own
            % half of a synchronized pair update: copies crossBlocks_, writes the staged
            % replacements into the copy, then performs a SINGLE map-swap assignment -- so if
            % anything above this line throws, obj.crossBlocks_ still points at the untouched
            % original map. Throws :pairExactCommitRevisionMismatch if the network has advanced
            % since staging (another writer raced this transaction).
            obj.requireNotSealed_();
            requiredStagedFields = {'messageIdentifier','coordinateEventEpoch_s','replacementKeys', ...
                'replacementBlocks','untouchedKeys','preparedAgainstRevisionNumber', ...
                'thirdMemberOmissionAudit','hasThirdMemberCorrections'};
            missingStagedFields = setdiff(requiredStagedFields,fieldnames(staged));
            if ~isempty(missingStagedFields)
                error('DistributedCovarianceNetwork:stagedSchema', ...
                    'commitStagedPairExactLinkTransform''s staged argument is missing %s.', ...
                    missingStagedFields{1});
            end
            if staged.preparedAgainstRevisionNumber ~= obj.revisionNumber
                error('DistributedCovarianceNetwork:pairExactCommitRevisionMismatch', ...
                    'The network has advanced since this pair-exact transform was staged.');
            end
            preMap = obj.crossBlocks_;
            allKeysAtCommit = preMap.keys;
            partition = union(staged.replacementKeys,staged.untouchedKeys);
            if numel(partition) ~= numel(allKeysAtCommit) || ...
                    ~isempty(setxor(partition,allKeysAtCommit)) || ...
                    ~isempty(intersect(staged.replacementKeys,staged.untouchedKeys))
                error('DistributedCovarianceNetwork:stagedPartitionCorrupt', ...
                    ['The staged replacement/untouched key partition does not exactly match the ' ...
                    'live cross-block set.']);
            end
            newMap = containers.Map('KeyType','char','ValueType','any');
            for index = 1:numel(allKeysAtCommit)
                newMap(allKeysAtCommit{index}) = preMap(allKeysAtCommit{index});
            end
            for index = 1:numel(staged.replacementKeys)
                newMap(staged.replacementKeys{index}) = staged.replacementBlocks{index};
            end
            obj.crossBlocks_ = newMap;
            obj.revisionNumber = obj.revisionNumber+1;
            obj.pairExactSynchronizedUpdateCount = obj.pairExactSynchronizedUpdateCount+1;
            if staged.hasThirdMemberCorrections
                obj.pairExactThirdMemberConditioningCount = obj.pairExactThirdMemberConditioningCount+1;
            end
            audit = staged.thirdMemberOmissionAudit;
            if ~audit.isNegligible
                obj.unappliedThirdMemberCorrectionCount = obj.unappliedThirdMemberCorrectionCount+1;
            end
            if ~isempty(audit.ratios)
                obj.maximumOmittedThirdMemberVarianceRatio = max( ...
                    obj.maximumOmittedThirdMemberVarianceRatio,max(audit.ratios));
            end
        end

        function restoreStagedPreImage(obj, preImage)
            % restoreStagedPreImage  Verified rollback for commitStagedPairExactLinkTransform:
            % rebuilds crossBlocks_ from the journaled pre-image values (never from any object
            % reference that might itself have been touched), restores every counter, then
            % re-reads each restored block and throws :rollbackNotVerified if it does not match
            % the journal exactly. Deliberately carries NO isSealed guard -- this is itself part
            % of the recovery path invoked BEFORE a seal decision is made; guarding it would
            % make recovery unreachable.
            restoredMap = containers.Map('KeyType','char','ValueType','any');
            for index = 1:numel(preImage.replacementKeys)
                restoredMap(preImage.replacementKeys{index}) = preImage.preReplacementBlocks{index};
            end
            for index = 1:numel(preImage.untouchedKeys)
                key = preImage.untouchedKeys{index};
                if isKey(obj.crossBlocks_,key)
                    restoredMap(key) = obj.crossBlocks_(key);
                end
            end
            obj.crossBlocks_ = restoredMap;
            obj.revisionNumber = preImage.preRevisionNumber;
            obj.conservativeOwnerOnlyConditioningCount = preImage.preConservativeOwnerOnlyConditioningCount;
            obj.pairExactSynchronizedUpdateCount = preImage.prePairExactSynchronizedUpdateCount;
            obj.pairExactThirdMemberConditioningCount = preImage.prePairExactThirdMemberConditioningCount;
            obj.unappliedThirdMemberCorrectionCount = preImage.preUnappliedThirdMemberCorrectionCount;
            obj.maximumOmittedThirdMemberVarianceRatio = preImage.preMaximumOmittedThirdMemberVarianceRatio;
            for index = 1:numel(preImage.replacementKeys)
                key = preImage.replacementKeys{index};
                if ~isequaln(obj.crossBlocks_(key),preImage.preReplacementBlocks{index})
                    error('DistributedCovarianceNetwork:rollbackNotVerified', ...
                        'Cross block %s does not match its pre-image after restoration.',key);
                end
            end
        end

        function sealOnFailedRollback(obj, reason)
            % sealOnFailedRollback  Last resort: called only when restoreStagedPreImage itself
            % threw. Idempotent (first reason wins) since a sealed network's own reason should
            % never be silently overwritten by a later, unrelated failure.
            if obj.isSealed
                return
            end
            obj.isSealed = true;
            obj.sealReason = char(reason);
        end

        function noteSupersededDeliveryRejection(obj)
            % noteSupersededDeliveryRejection  Counts a delivery refused because its target
            % cross block was already superseded by an earlier pair-exact commit this same
            % epoch (see stagePairExactLinkTransform's :linearizationPointSupersededByPairExact
            % Update). No isSealed guard: incrementing a diagnostic counter on the refusal path
            % is harmless even against an otherwise-sealed network.
            obj.supersededDeliveryRejectionCount = obj.supersededDeliveryRejectionCount+1;
        end
    end

    methods (Access = private)
        function requireNotSealed_(obj)
            if obj.isSealed
                error('DistributedCovarianceNetwork:networkSealed', ...
                    ['This DistributedCovarianceNetwork is sealed (%s) after an unverifiable ' ...
                    'partial commit; no further reads or writes are permitted.'],obj.sealReason);
            end
        end
    end

    methods (Static)
        function [S, terms] = pairInnovationCovariance(record)
            required = {'Hi','Hj','Pii','Pij','Pjj','R'};
            missing = setdiff(required,fieldnames(record));
            if ~isempty(missing)
                error('DistributedCovarianceNetwork:pairInnovationSchema', ...
                    'pairInnovationCovariance record is missing %s.',missing{1});
            end
            owner = record.Hi*record.Pii*record.Hi';
            cross = record.Hi*record.Pij*record.Hj' + record.Hj*record.Pij'*record.Hi';
            remote = record.Hj*record.Pjj*record.Hj';
            S = owner+cross+remote+record.R;
            S = (S+S')/2;
            terms = struct('owner',owner,'cross',cross,'remote',remote,'independent',record.R);
        end

        function result = pairMeasurementUpdatePrimitive(record)
            % pairMeasurementUpdatePrimitive  Item 5. Pure, static, dimension-agnostic: computes
            % and applies nothing (revgnss.DistributedPairCovarianceUpdateResult's constructor
            % forces appliedToAnyFilter=false). Implemented blockwise -- no joint/stacked matrix
            % is ever materialized here; the stacked-Joseph oracle exists only in tests, making
            % the reference-equivalence test a genuine independent check.
            required = {'observationIdentifier','deliveryIdentifier','observableIdentifier', ...
                'observableRowUnits','ownerEndpointIdentifier','remoteEndpointIdentifier', ...
                'coordinateEventEpoch_s','Hi','Hj','Pii','Pij','Pjj','R','residual'};
            missing = setdiff(required,fieldnames(record));
            if ~isempty(missing)
                error('DistributedCovarianceNetwork:pairUpdateSchema', ...
                    'pairMeasurementUpdatePrimitive record is missing %s.',missing{1});
            end
            Hi = record.Hi; Hj = record.Hj;
            Pii = record.Pii; Pij = record.Pij; Pjj = record.Pjj; R = record.R;
            [S, terms] = revgnss.DistributedCovarianceNetwork.pairInnovationCovariance(record);

            Ci = Pii*Hi' + Pij*Hj';
            Cj = Pij'*Hi' + Pjj*Hj';
            Ki = Ci/S;
            Kj = Cj/S;
            ni = size(Pii,1); nj = size(Pjj,1);
            Mi = eye(ni)-Ki*Hi; Ni = -Ki*Hj;
            Mj = eye(nj)-Kj*Hj; Nj = -Kj*Hi;

            Piiplus = Mi*Pii*Mi' + Mi*Pij*Ni' + Ni*Pij'*Mi' + Ni*Pjj*Ni' + Ki*R*Ki';
            Pjjplus = Nj*Pii*Nj' + Nj*Pij*Mj' + Mj*Pij'*Nj' + Mj*Pjj*Mj' + Kj*R*Kj';
            Pijplus = Mi*Pii*Nj' + Mi*Pij*Mj' + Ni*Pij'*Nj' + Ni*Pjj*Mj' + Ki*R*Kj';
            Piiplus = (Piiplus+Piiplus')/2;
            Pjjplus = (Pjjplus+Pjjplus')/2;

            nu = record.residual(:);
            dxi = Ki*nu;
            dxj = Kj*nu;
            nis = nu'*(S\nu);

            Dvec = sqrt([diag(Pii);diag(Pjj)]);
            Dvec(Dvec<=0) = 1;
            Dinv = diag(1./Dvec);
            jointPrior = [Pii,Pij;Pij',Pjj];
            scaled = Dinv*jointPrior*Dinv;
            minEig = min(eig((scaled+scaled')/2));

            resultRecord = struct( ...
                'observationIdentifier',record.observationIdentifier, ...
                'deliveryIdentifier',record.deliveryIdentifier, ...
                'observableIdentifier',record.observableIdentifier, ...
                'observableRowUnits',record.observableRowUnits, ...
                'ownerEndpointIdentifier',record.ownerEndpointIdentifier, ...
                'remoteEndpointIdentifier',record.remoteEndpointIdentifier, ...
                'coordinateEventEpoch_s',record.coordinateEventEpoch_s, ...
                'residual_rowUnit',nu, ...
                'innovationCovariance_rowUnit2',S, ...
                'innovationOwnerTerm_rowUnit2',terms.owner, ...
                'innovationCrossTerm_rowUnit2',terms.cross, ...
                'innovationRemoteTerm_rowUnit2',terms.remote, ...
                'independentMeasurementCovariance_rowUnit2',R, ...
                'ownerGain_errorUnitPerRowUnit',Ki, ...
                'remoteGain_errorUnitPerRowUnit',Kj, ...
                'ownerStateCorrection_errorUnit',dxi, ...
                'remoteStateCorrection_errorUnit',dxj, ...
                'ownerPosteriorLocalCovariance',Piiplus, ...
                'remotePosteriorLocalCovariance',Pjjplus, ...
                'posteriorCrossCovariance',Pijplus, ...
                'normalizedInnovationSquared',nis, ...
                'jointPriorMinimumScaledEigenvalue',minEig, ...
                'appliedToAnyFilter',false);
            result = revgnss.DistributedPairCovarianceUpdateResult.fromRecord(resultRecord);
        end

        function [A, B] = conservativeOwnerOnlyErrorTransforms(record)
            % conservativeOwnerOnlyErrorTransforms  Builds (A_i,B_i) for Section 2.4's
            % conditioning rule from data revgnss.IndependentFleetCoordinator already holds:
            % the certified conservative gain (embedded on the owner's schema columns), the
            % owner/remote Jacobians, and the attitude-reset Jacobian
            % (revgnss.ConservativeFullStateLinkUpdate.applyOwnerOnlyUpdate's one additive
            % returned field).
            required = {'gainFull','ownerJacobianFull','remoteJacobian','attitudeResetJacobian', ...
                'schemaStateIndices'};
            missing = setdiff(required,fieldnames(record));
            if ~isempty(missing)
                error('DistributedCovarianceNetwork:errorTransformSchema', ...
                    'conservativeOwnerOnlyErrorTransforms record is missing %s.',missing{1});
            end
            ni = size(record.gainFull,1);
            Gi = eye(ni);
            attitudeIdx = record.schemaStateIndices(7:9);
            Gi(attitudeIdx,attitudeIdx) = record.attitudeResetJacobian;
            A = Gi*(eye(ni) - record.gainFull*record.ownerJacobianFull);
            B = Gi*(-record.gainFull*record.remoteJacobian);
        end

        function [Mi, Ni, Nj, Mj] = pairExactErrorTransforms(record)
            % pairExactErrorTransforms  The four error-transition blocks of the pair-exact
            % update, factored out of pairMeasurementUpdatePrimitive's own inline computation
            % (kept byte-identical there) so a caller/test can obtain them independently, e.g.
            % to build a custom third-member conditioning without re-deriving Ki/Kj's algebra.
            required = {'Hi','Hj','Ki','Kj'};
            missing = setdiff(required,fieldnames(record));
            if ~isempty(missing)
                error('DistributedCovarianceNetwork:pairErrorTransformSchema', ...
                    'pairExactErrorTransforms record is missing %s.',missing{1});
            end
            ni = size(record.Ki,1);
            nj = size(record.Kj,1);
            Mi = eye(ni) - record.Ki*record.Hi;
            Ni = -record.Ki*record.Hj;
            Nj = -record.Kj*record.Hi;
            Mj = eye(nj) - record.Kj*record.Hj;
        end

        function PijPlus = applyAttitudeResetCongruenceToPairCross(Pij, ownerAttitudeResetJacobian, ...
                remoteAttitudeResetJacobian, ownerSchemaStateIndices, remoteSchemaStateIndices)
            % applyAttitudeResetCongruenceToPairCross  Section 3.2 item 4/5: the pair-exact
            % counterpart of the owner-only quaternion-reset congruence already applied to a
            % single marginal by revgnss.LocalStateCorrectionInjection -- here BOTH sides of the
            % cross block get their own 3x3 reset Jacobian, embedded onto each endpoint's own
            % attitude schema columns/rows (owner columns for Gi, remote columns for Gj; the
            % 3rd-member axis, if any, is untouched by definition -- see
            % pairExactThirdMemberCrossTransforms for that one-sided case).
            ni = size(Pij,1);
            nj = size(Pij,2);
            ownerAttIdx = ownerSchemaStateIndices(7:9);
            remoteAttIdx = remoteSchemaStateIndices(7:9);
            Gi = eye(ni); Gi(ownerAttIdx,ownerAttIdx) = ownerAttitudeResetJacobian;
            Gj = eye(nj); Gj(remoteAttIdx,remoteAttIdx) = remoteAttitudeResetJacobian;
            PijPlus = Gi*Pij*Gj';
        end

        function [PikPlus, PjkPlus] = pairExactThirdMemberCrossTransforms(record)
            % pairExactThirdMemberCrossTransforms  Section 3.2 item 5: conditions EVERY third
            % member's cross block to owner (Pik) and to remote (Pjk) simultaneously, one-sided
            % (only the owner/remote side's attitude reset is applied -- the third member's own
            % state was not touched by this observation, so its own axis gets no congruence):
            %   W_k    = Hi*Pik{k} + Hj*Pjk{k}
            %   PikPlus{k} = Gi*(Pik{k} - Ki*W_k)
            %   PjkPlus{k} = Gj*(Pjk{k} - Kj*W_k)
            % Pik{k}/Pjk{k} are owner-first/remote-first oriented (ni-by-nk / nj-by-nk), matching
            % revgnss.DistributedCovarianceNetwork.orientedCrossCovariance(ownerId,thirdId)'s own
            % convention -- see revgnss.SynchronizedPairLinkUpdateTransaction, the only caller
            % that builds this record from live data.
            required = {'Hi','Hj','Ki','Kj','Gi','Gj','ownerSchemaStateIndices', ...
                'remoteSchemaStateIndices','Pik','Pjk'};
            missing = setdiff(required,fieldnames(record));
            if ~isempty(missing)
                error('DistributedCovarianceNetwork:thirdMemberCrossTransformSchema', ...
                    'pairExactThirdMemberCrossTransforms record is missing %s.',missing{1});
            end
            nThird = numel(record.Pik);
            if numel(record.Pjk) ~= nThird
                error('DistributedCovarianceNetwork:thirdMemberCrossTransformSchema', ...
                    'Pik and Pjk must have the same number of third-member entries.');
            end
            ni = size(record.Ki,1);
            nj = size(record.Kj,1);
            ownerAttIdx = record.ownerSchemaStateIndices(7:9);
            remoteAttIdx = record.remoteSchemaStateIndices(7:9);
            GiFull = eye(ni); GiFull(ownerAttIdx,ownerAttIdx) = record.Gi;
            GjFull = eye(nj); GjFull(remoteAttIdx,remoteAttIdx) = record.Gj;
            PikPlus = cell(1,nThird);
            PjkPlus = cell(1,nThird);
            for k = 1:nThird
                Wk = record.Hi*record.Pik{k} + record.Hj*record.Pjk{k};
                PikPlus{k} = GiFull*(record.Pik{k} - record.Ki*Wk);
                PjkPlus{k} = GjFull*(record.Pjk{k} - record.Kj*Wk);
                if any(~isfinite(PikPlus{k}(:))) || any(~isfinite(PjkPlus{k}(:)))
                    error('DistributedCovarianceNetwork:nonFiniteThirdMemberCrossTransform', ...
                        'Third-member cross-block transform %d produced a non-finite result.',k);
                end
            end
        end

        function audit = thirdMemberOmittedCorrectionAudit(record)
            % thirdMemberOmittedCorrectionAudit  Section 3.2 item 8: quantifies, per third
            % member k, the variance this exact pair update WOULD have removed from k's own
            % local marginal Pkk had k also been jointly updated (it was not -- only its cross
            % blocks are conditioned, never its own diagonal):
            %   C_k      = Pki{k}'*Hi' + Pkj{k}'*Hj'     (Pki/Pkj are owner-first/remote-first,
            %                                              transposed here to the k-first
            %                                              orientation this formula is stated in)
            %   omitted  = C_k*(S\C_k')
            %   ratio_k  = max(diag(omitted)) / max(diag(Pkk))
            % isNegligible is true iff every ratio_k is within
            % SynchronizedDeliveryContract.ThirdMemberOmittedVarianceToleranceRelative -- this
            % audit reports the omission, it never corrects it (Section 3.2 scope is exactly the
            % owner/remote pair plus third-member CROSS blocks; a third member's own marginal
            % update is out of scope, see the plan's own Section 3 item list).
            required = {'S','Hi','Hj','Pki','Pkj','Pkk','endpointIdentifiers'};
            missing = setdiff(required,fieldnames(record));
            if ~isempty(missing)
                error('DistributedCovarianceNetwork:thirdMemberOmissionAuditSchema', ...
                    'thirdMemberOmittedCorrectionAudit record is missing %s.',missing{1});
            end
            nThird = numel(record.Pki);
            if numel(record.Pkj) ~= nThird || numel(record.Pkk) ~= nThird || ...
                    numel(record.endpointIdentifiers) ~= nThird
                error('DistributedCovarianceNetwork:thirdMemberOmissionAuditSchema', ...
                    'Pki, Pkj, Pkk, and endpointIdentifiers must all have the same number of entries.');
            end
            ratios = zeros(1,nThird);
            tol = revgnss.SynchronizedDeliveryContract.ThirdMemberOmittedVarianceToleranceRelative;
            for k = 1:nThird
                Ck = record.Pki{k}'*record.Hi' + record.Pkj{k}'*record.Hj';
                omitted = Ck*(record.S\Ck');
                omitted = (omitted+omitted')/2;
                Pkk = record.Pkk{k};
                denom = max(diag(Pkk));
                if denom <= 0
                    denom = 1;
                end
                ratios(k) = max(diag(omitted))/denom;
            end
            audit = struct( ...
                'endpointIdentifiers',{record.endpointIdentifiers}, ...
                'ratios',ratios, ...
                'isNegligible',all(ratios <= tol));
        end
    end
end
