classdef CommunicationEndpointStateProvider
    % CommunicationEndpointStateProvider  Frozen provider contract (plan Section 2.1, Interface #1).
    %
    % There is no classdef (Abstract) base. A provider is sanctioned by appearing in the
    % frozen AllowedProviderClasses list below, so adding a new provider is a reviewable,
    % greppable edit to this contract class rather than a silently-accepted subclass. This is
    % the direct structural answer to the plan's forbidden shortcut: "must not reuse a
    % joint-state-map linearizer as a local update shortcut" -- a hypothetical
    % JointStateMapEndpointProvider would have to be added here to be usable at all.

    properties (Constant)
        AllowedProviderClasses = { ...
            'revgnss.OwnerLocalEstimatorEndpointProvider', ...
            'revgnss.FrozenProductEndpointProvider'};
        RequiredProviderMethods = {'stateAtCoordinateEpoch','endpointIdentifier', ...
            'declaredEvaluationPolicy'};
        AllowedStateSources = {'estimatorState'};
        AllowedStateOrigins = {'ownerLocalEstimator','frozenRemoteProduct'};
        AllowedStateEvaluationPolicies = {'frozenSameEpochOnly'};
        % Documentary only: not implemented, not accepted anywhere today.
        ReservedFutureEvaluationPolicies = {'shortArcKinematicWithDeclaredProcessNoise'};
    end

    methods (Static)
        function requireProvider(provider)
            if ~any(strcmp(class(provider), ...
                    revgnss.CommunicationEndpointStateProvider.AllowedProviderClasses))
                error('CommunicationEndpointStateProvider:providerClassNotSanctioned', ...
                    'Class %s is not a sanctioned CommunicationEndpointStateProvider.', ...
                    class(provider));
            end
            methodsRequired = revgnss.CommunicationEndpointStateProvider.RequiredProviderMethods;
            for index = 1:numel(methodsRequired)
                name = methodsRequired{index};
                if ~(ismethod(provider,name) || isprop(provider,name))
                    error('CommunicationEndpointStateProvider:providerMissingMethod', ...
                        'Provider %s is missing required member %s.',class(provider),name);
                end
            end
            policy = provider.declaredEvaluationPolicy;
            allowed = revgnss.CommunicationEndpointStateProvider.AllowedStateEvaluationPolicies;
            if ~any(strcmp(char(policy),allowed))
                error('CommunicationEndpointStateProvider:propagationPolicyUnsupported', ...
                    'Provider evaluation policy %s is not supported.',char(policy));
            end
        end

        function state = requireStateAt(provider, coordinateEpoch_s)
            revgnss.CommunicationEndpointStateProvider.requireProvider(provider);
            state = provider.stateAtCoordinateEpoch(coordinateEpoch_s);
            if ~isa(state,'revgnss.CommunicationEndpointState')
                error('CommunicationEndpointStateProvider:stateType', ...
                    'A provider must return a revgnss.CommunicationEndpointState.');
            end
            if state.coordinateEpoch_s ~= coordinateEpoch_s
                error('CommunicationEndpointStateProvider:stateEpochMismatch', ...
                    'The returned state epoch does not equal the requested coordinate epoch.');
            end
            if ~any(strcmp(state.stateSource, ...
                    revgnss.CommunicationEndpointStateProvider.AllowedStateSources))
                error('CommunicationEndpointStateProvider:providerNotEstimatorSourced', ...
                    'A CommunicationEndpointState must be estimator-sourced.');
            end
            if state.qualityFlags.truthUsed
                error('CommunicationEndpointStateProvider:truthSourcedState', ...
                    'A CommunicationEndpointState must never be truth-sourced.');
            end
        end

        function requireSameEpochPair(ownerState, remoteState, coordinateEpoch_s)
            if ~isa(ownerState,'revgnss.CommunicationEndpointState') || ...
                    ~isa(remoteState,'revgnss.CommunicationEndpointState')
                error('CommunicationEndpointStateProvider:stateType', ...
                    'requireSameEpochPair requires two CommunicationEndpointState objects.');
            end
            if ownerState.coordinateEpoch_s ~= coordinateEpoch_s || ...
                    remoteState.coordinateEpoch_s ~= coordinateEpoch_s
                error('CommunicationEndpointStateProvider:epochOutsideFrozenScope', ...
                    'Both endpoint states must be frozen at the requested coordinate epoch.');
            end
            if ownerState.productProvenance.productAge_s ~= 0 || ...
                    remoteState.productProvenance.productAge_s ~= 0
                error('CommunicationEndpointStateProvider:epochOutsideFrozenScope', ...
                    'The initial Stage-2 scope requires zero product age on both endpoints.');
            end
            if ownerState.canonicalPhysicalAssetIndex == remoteState.canonicalPhysicalAssetIndex
                error('CommunicationEndpointStateProvider:endpointsNotDistinct', ...
                    'The owner and remote endpoint must name distinct physical spacecraft.');
            end
        end

        function requireTerminalGeometryDeclared(state)
            if ~isa(state,'revgnss.CommunicationEndpointState')
                error('CommunicationEndpointStateProvider:stateType', ...
                    'requireTerminalGeometryDeclared requires a CommunicationEndpointState.');
            end
            if ~state.terminalGeometry.declared
                error('CommunicationEndpointStateProvider:terminalGeometryNotDeclared', ...
                    'This endpoint state does not declare terminal geometry.');
            end
        end

        function requireCompatibleCovarianceCoordinates(ownerState, remoteState)
            % requireCompatibleCovarianceCoordinates  Each endpoint's covariance component
            % order must be a recognised frozen variant matching its own declared attitude
            % convention. This does NOT require the two endpoints to share a variant -- a
            % remote MEKF tangent covariance paired with an owner Euler covariance is legal
            % (plan Section 2.3.1); an adapter must handle both in their declared coordinates.
            states = {ownerState,remoteState};
            for index = 1:numel(states)
                state = states{index};
                if ~isa(state,'revgnss.CommunicationEndpointState')
                    error('CommunicationEndpointStateProvider:stateType', ...
                        'requireCompatibleCovarianceCoordinates requires CommunicationEndpointState objects.');
                end
                matchesEuler = isequal(state.covarianceComponentOrder, ...
                    revgnss.DistributedLinkProtocolContract.StateSchemaV1CovarianceComponentOrderEuler);
                matchesTangent = isequal(state.covarianceComponentOrder, ...
                    revgnss.DistributedLinkProtocolContract.StateSchemaV1CovarianceComponentOrderTangent);
                if ~(matchesEuler || matchesTangent)
                    error('CommunicationEndpointStateProvider:attitudeConventionMismatch', ...
                        'An endpoint covariance component order is not a recognised frozen variant.');
                end
                variant = 'euler';
                if matchesTangent; variant = 'tangent'; end
                conventionMatchesVariant = ...
                    (strcmp(variant,'euler') && ...
                    strcmp(state.attitudeErrorCoordinateConvention,'eulerZYXError_rad')) || ...
                    (strcmp(variant,'tangent') && strcmp(state.attitudeErrorCoordinateConvention, ...
                    'rightMultiplicativeLocalTangent_rad'));
                if ~conventionMatchesVariant
                    error('CommunicationEndpointStateProvider:attitudeConventionMismatch', ...
                        'An endpoint declared attitude convention disagrees with its own covariance labels.');
                end
            end
        end
    end
end
