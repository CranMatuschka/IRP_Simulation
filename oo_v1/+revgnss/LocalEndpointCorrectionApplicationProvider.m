classdef LocalEndpointCorrectionApplicationProvider
    % LocalEndpointCorrectionApplicationProvider  Frozen provider allow-list contract for Stage
    % 3.2's dual-endpoint correction application, the structural twin of Stage 3.1's
    % revgnss.LocalEpochTransitionCaptureProvider. No classdef (Abstract) base: a provider is
    % sanctioned by appearing in AllowedProviderClasses, so adding a new one is a reviewable,
    % greppable edit to this contract rather than a silently-accepted subclass.

    properties (Constant)
        AllowedProviderClasses = {'revgnss.OwnerLocalEkfTransitionCaptureProvider'}
        RequiredProviderMethods = {'endpointIdentifier','localStateDimension','schemaStateIndices', ...
            'localStateMapFingerprint','localCovariance','localState','nominalQuaternion', ...
            'attitudeParameterization','localStateDigest','hasOpenEpochTransitionCapture', ...
            'takeApplicationRollbackSnapshot','applyDeclaredEndpointCorrection', ...
            'restoreApplicationRollbackSnapshot','noteDeclaredExternalCovarianceWrite'}
    end

    methods (Static)
        function requireProvider(provider)
            if ~any(strcmp(class(provider), ...
                    revgnss.LocalEndpointCorrectionApplicationProvider.AllowedProviderClasses))
                error('LocalEndpointCorrectionApplicationProvider:providerClassNotSanctioned', ...
                    'Class %s is not a sanctioned LocalEndpointCorrectionApplicationProvider.',class(provider));
            end
            methodsRequired = revgnss.LocalEndpointCorrectionApplicationProvider.RequiredProviderMethods;
            for index = 1:numel(methodsRequired)
                name = methodsRequired{index};
                if ~(ismethod(provider,name) || isprop(provider,name))
                    error('LocalEndpointCorrectionApplicationProvider:providerMissingMethod', ...
                        'Provider %s is missing required member %s.',class(provider),name);
                end
            end
        end

        function hex = requireStateDigest(provider)
            revgnss.LocalEndpointCorrectionApplicationProvider.requireProvider(provider);
            hex = provider.localStateDigest();
            if isempty(hex) || ~ischar(hex)
                error('LocalEndpointCorrectionApplicationProvider:stateDigest', ...
                    'A provider must return a nonempty char state digest.');
            end
        end

        function snap = requireRollbackSnapshot(provider)
            revgnss.LocalEndpointCorrectionApplicationProvider.requireProvider(provider);
            snap = provider.takeApplicationRollbackSnapshot();
            required = {'x','P','nominalQuat_wxyz','attitudeInjectionCount','maxAttitudeInjectionNorm_rad'};
            missing = setdiff(required,fieldnames(snap));
            if ~isempty(missing)
                error('LocalEndpointCorrectionApplicationProvider:rollbackSnapshotSchema', ...
                    'A rollback snapshot is missing %s.',missing{1});
            end
        end

        function requireCorrectionApplied(provider, xPosterior, PPosterior, nominalQuatPosterior, ...
                injectionNorm_rad)
            revgnss.LocalEndpointCorrectionApplicationProvider.requireProvider(provider);
            provider.applyDeclaredEndpointCorrection(xPosterior,PPosterior,nominalQuatPosterior, ...
                injectionNorm_rad);
            if ~isequal(provider.localState(),xPosterior) || ~isequal(provider.localCovariance(), ...
                    (PPosterior+PPosterior')/2)
                error('LocalEndpointCorrectionApplicationProvider:correctionNotApplied', ...
                    'The provider''s live state does not reflect the declared correction after applying it.');
            end
        end

        function requireRollbackRestored(provider, snapshot)
            revgnss.LocalEndpointCorrectionApplicationProvider.requireProvider(provider);
            provider.restoreApplicationRollbackSnapshot(snapshot);
            if ~isequaln(provider.localState(),snapshot.x) || ...
                    ~isequaln(provider.localCovariance(),(snapshot.P+snapshot.P')/2) || ...
                    ~isequaln(provider.nominalQuaternion(),snapshot.nominalQuat_wxyz)
                error('LocalEndpointCorrectionApplicationProvider:rollbackNotVerified', ...
                    'The provider''s live state does not match the rollback snapshot after restoring it.');
            end
        end
    end
end
