classdef PairwiseCrossCovarianceBlock
    % PairwiseCrossCovarianceBlock  One immutable, validated declaration of one fleet pair's
    % cross-covariance block P_ij (plan Stage 3.1 item 2). Stored at FULL local dimension
    % (n_i-by-n_j), not the 14-component core: the core is not closed under the local ground
    % update (a shared/pair update couples non-core columns of one member to core columns of
    % the other) or under F when gyro-bias/SRP states exist -- see
    % revgnss.DistributedCovarianceNetwork's header (U1).
    %
    % Stored once per unordered pair (revgnss.DistributedCovarianceNetworkContract.
    % canonicalPairKey, U22): P_ji is never stored, orientedTo(...) transposes on read, so
    % P_ji=P_ij' is structural and no code path can let two stored copies drift apart. This
    % block is NEVER symmetrized -- P_ij is not a symmetric matrix.
    %
    % This block is coordinator-local and non-transmissible: it never enters an
    % EndpointStateProduct and needs no transmissible schema version (making P_ij
    % transmissible is explicitly out of Stage 3.1 scope; see the plan's Stage-3 completion
    % record).

    properties (SetAccess = immutable)
        crossBlockIdentifier             (1,:) char
        firstEndpointIdentifier          (1,:) char
        secondEndpointIdentifier         (1,:) char
        crossCovariance                  (:,:) double
        crossBlockSpanKind               (1,:) char
        sourceCoordinateEpoch_s          (1,1) double
        stateSchemaVersion               (1,:) char
        firstLocalStateMapFingerprint    (1,:) char
        secondLocalStateMapFingerprint   (1,:) char
        firstSchemaStateIndices          (14,1) double
        secondSchemaStateIndices         (14,1) double
        provenanceKind                   (1,:) char
        provenanceDetail                 (1,:) char
        contributingObservationIdentifiers        (1,:) cell
        contributingCommonProcessGroupIdentifiers (1,:) cell
        transformCount                   (1,1) double
        networkRevisionNumber            (1,1) double
    end

    methods
        function obj = PairwiseCrossCovarianceBlock(record)
            required = {'firstEndpointIdentifier','secondEndpointIdentifier','crossCovariance', ...
                'crossBlockSpanKind','sourceCoordinateEpoch_s','stateSchemaVersion', ...
                'firstLocalStateMapFingerprint','secondLocalStateMapFingerprint', ...
                'firstSchemaStateIndices','secondSchemaStateIndices','provenanceKind', ...
                'provenanceDetail','contributingObservationIdentifiers', ...
                'contributingCommonProcessGroupIdentifiers','transformCount','networkRevisionNumber'};
            supplied = fieldnames(record);
            missing = setdiff(required,supplied);
            unknown = setdiff(supplied,required);
            if ~isempty(missing)
                error('PairwiseCrossCovarianceBlock:missingField', ...
                    'PairwiseCrossCovarianceBlock is missing %s.',missing{1});
            end
            if ~isempty(unknown)
                error('PairwiseCrossCovarianceBlock:unknownField', ...
                    'PairwiseCrossCovarianceBlock contains unsupported field %s.',unknown{1});
            end

            first = char(record.firstEndpointIdentifier);
            second = char(record.secondEndpointIdentifier);
            if strcmp(first,second)
                error('PairwiseCrossCovarianceBlock:selfPair', ...
                    'A cross-covariance block requires two distinct endpoint identifiers.');
            end
            ordered = sort({first,second});
            if ~strcmp(first,ordered{1})
                error('PairwiseCrossCovarianceBlock:orientation', ...
                    ['A PairwiseCrossCovarianceBlock must be constructed with ' ...
                    'firstEndpointIdentifier lexicographically before secondEndpointIdentifier; ' ...
                    'use DistributedCovarianceNetworkContract.canonicalPairKey to determine order.']);
            end

            if ~strcmp(char(record.crossBlockSpanKind), ...
                    revgnss.DistributedCovarianceNetworkContract.CrossBlockSpanKind)
                error('PairwiseCrossCovarianceBlock:spanKind', ...
                    'crossBlockSpanKind must be the frozen fullLocalStateSpan value.');
            end
            if ~strcmp(char(record.stateSchemaVersion), ...
                    revgnss.DistributedLinkProtocolContract.StateSchemaVersion)
                error('PairwiseCrossCovarianceBlock:stateSchemaVersion', ...
                    'stateSchemaVersion must equal the frozen Stage-2 v1 schema version.');
            end
            if ~any(strcmp(char(record.provenanceKind), ...
                    revgnss.DistributedCovarianceNetworkContract.AllowedCrossBlockProvenanceKinds))
                error('PairwiseCrossCovarianceBlock:provenanceKind', ...
                    'provenanceKind must be one of the frozen allowed provenance kinds.');
            end

            W = record.crossCovariance;
            if isempty(W) || any(~isfinite(W(:)))
                error('PairwiseCrossCovarianceBlock:crossCovariance', ...
                    'crossCovariance must be a finite, nonempty matrix.');
            end
            idxA = record.firstSchemaStateIndices(:);
            idxB = record.secondSchemaStateIndices(:);
            if numel(idxA) ~= 14 || numel(unique(idxA)) ~= 14 || ...
                    numel(idxB) ~= 14 || numel(unique(idxB)) ~= 14
                error('PairwiseCrossCovarianceBlock:schemaIndices', ...
                    'firstSchemaStateIndices/secondSchemaStateIndices must each be 14 distinct indices.');
            end
            if size(W,1) < max(idxA) || size(W,2) < max(idxB)
                error('PairwiseCrossCovarianceBlock:dimensionMismatch', ...
                    'crossCovariance is too small to contain the declared schema indices.');
            end

            if ~(isnumeric(record.sourceCoordinateEpoch_s) && isscalar(record.sourceCoordinateEpoch_s) && ...
                    isfinite(record.sourceCoordinateEpoch_s))
                error('PairwiseCrossCovarianceBlock:sourceEpoch', ...
                    'sourceCoordinateEpoch_s must be a finite scalar.');
            end
            if ~(isnumeric(record.transformCount) && isscalar(record.transformCount) && ...
                    record.transformCount >= 0 && record.transformCount == round(record.transformCount))
                error('PairwiseCrossCovarianceBlock:transformCount', ...
                    'transformCount must be a nonnegative integer.');
            end
            if ~(isnumeric(record.networkRevisionNumber) && isscalar(record.networkRevisionNumber) && ...
                    record.networkRevisionNumber >= 0)
                error('PairwiseCrossCovarianceBlock:revisionNumber', ...
                    'networkRevisionNumber must be a nonnegative scalar.');
            end
            if ~iscell(record.contributingObservationIdentifiers) || ...
                    ~iscell(record.contributingCommonProcessGroupIdentifiers)
                error('PairwiseCrossCovarianceBlock:contributingIdentifiers', ...
                    'contributingObservationIdentifiers/contributingCommonProcessGroupIdentifiers must be cell arrays.');
            end

            obj.crossBlockIdentifier = revgnss.DistributedCovarianceNetworkContract.canonicalPairKey(first,second);
            obj.firstEndpointIdentifier = first;
            obj.secondEndpointIdentifier = second;
            obj.crossCovariance = W;
            obj.crossBlockSpanKind = char(record.crossBlockSpanKind);
            obj.sourceCoordinateEpoch_s = double(record.sourceCoordinateEpoch_s);
            obj.stateSchemaVersion = char(record.stateSchemaVersion);
            obj.firstLocalStateMapFingerprint = char(record.firstLocalStateMapFingerprint);
            obj.secondLocalStateMapFingerprint = char(record.secondLocalStateMapFingerprint);
            obj.firstSchemaStateIndices = idxA;
            obj.secondSchemaStateIndices = idxB;
            obj.provenanceKind = char(record.provenanceKind);
            obj.provenanceDetail = char(record.provenanceDetail);
            obj.contributingObservationIdentifiers = record.contributingObservationIdentifiers;
            obj.contributingCommonProcessGroupIdentifiers = record.contributingCommonProcessGroupIdentifiers;
            obj.transformCount = double(record.transformCount);
            obj.networkRevisionNumber = double(record.networkRevisionNumber);
        end

        function M = orientedTo(obj, firstEndpointIdentifier, secondEndpointIdentifier)
            % orientedTo  The ONLY way to read this block in a requested orientation. Returns
            % the stored crossCovariance directly when the request matches storage order, or its
            % transpose when reversed. Throws for any other pair.
            a = char(firstEndpointIdentifier);
            b = char(secondEndpointIdentifier);
            if strcmp(a,obj.firstEndpointIdentifier) && strcmp(b,obj.secondEndpointIdentifier)
                M = obj.crossCovariance;
            elseif strcmp(a,obj.secondEndpointIdentifier) && strcmp(b,obj.firstEndpointIdentifier)
                M = obj.crossCovariance';
            else
                error('PairwiseCrossCovarianceBlock:orientationRequest', ...
                    'orientedTo was asked for a pair this block does not describe.');
            end
        end

        function s = toStruct(obj)
            names = properties(obj);
            s = struct();
            for index = 1:numel(names)
                s.(names{index}) = obj.(names{index});
            end
        end
    end

    methods (Static)
        function obj = fromRecord(record)
            obj = revgnss.PairwiseCrossCovarianceBlock(record);
        end

        function obj = independentPriorFor(firstMember, secondMember, coordinateEpoch_s)
            % independentPriorFor  The zero cross block a fresh pair is declared with
            % (priorIndependenceDeclaration, U23): P_ij(0)=0 is asserted per member, not a
            % silent default.
            first = firstMember.endpointIdentifier;
            second = secondMember.endpointIdentifier;
            ordered = sort({char(first),char(second)});
            if strcmp(ordered{1},char(first))
                a = firstMember; b = secondMember;
            else
                a = secondMember; b = firstMember;
            end
            record = struct( ...
                'firstEndpointIdentifier',a.endpointIdentifier, ...
                'secondEndpointIdentifier',b.endpointIdentifier, ...
                'crossCovariance',zeros(a.localStateDimension,b.localStateDimension), ...
                'crossBlockSpanKind',revgnss.DistributedCovarianceNetworkContract.CrossBlockSpanKind, ...
                'sourceCoordinateEpoch_s',coordinateEpoch_s, ...
                'stateSchemaVersion',revgnss.DistributedLinkProtocolContract.StateSchemaVersion, ...
                'firstLocalStateMapFingerprint',a.localStateMapFingerprint, ...
                'secondLocalStateMapFingerprint',b.localStateMapFingerprint, ...
                'firstSchemaStateIndices',a.schemaStateIndices, ...
                'secondSchemaStateIndices',b.schemaStateIndices, ...
                'provenanceKind','initialisedIndependentPrior', ...
                'provenanceDetail','independent local priors declared at fleet registration', ...
                'contributingObservationIdentifiers',{{}}, ...
                'contributingCommonProcessGroupIdentifiers',{{}}, ...
                'transformCount',0, ...
                'networkRevisionNumber',0);
            obj = revgnss.PairwiseCrossCovarianceBlock(record);
        end
    end
end
