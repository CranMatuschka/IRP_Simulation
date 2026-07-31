classdef LocalEpochTransitionCaptureProvider
    % LocalEpochTransitionCaptureProvider  Frozen provider contract (plan Stage 3.1), the
    % structural twin of revgnss.CommunicationEndpointStateProvider. No classdef (Abstract)
    % base: a provider is sanctioned by appearing in AllowedProviderClasses, so adding a new
    % provider is a reviewable, greppable edit to this contract rather than a silently-accepted
    % subclass.

    properties (Constant)
        AllowedProviderClasses = {'revgnss.OwnerLocalEkfTransitionCaptureProvider'}
        RequiredProviderMethods = {'endpointIdentifier','localStateDimension', ...
            'schemaStateIndices','localStateMapFingerprint','localCovariance', ...
            'takeEpochCapture','declaredCaptureMode'}
        AllowedCaptureModes = {'ownerLocalPredictAndUpdateRetained'}
    end

    methods (Static)
        function requireProvider(provider)
            if ~any(strcmp(class(provider), ...
                    revgnss.LocalEpochTransitionCaptureProvider.AllowedProviderClasses))
                error('LocalEpochTransitionCaptureProvider:providerClassNotSanctioned', ...
                    'Class %s is not a sanctioned LocalEpochTransitionCaptureProvider.',class(provider));
            end
            methodsRequired = revgnss.LocalEpochTransitionCaptureProvider.RequiredProviderMethods;
            for index = 1:numel(methodsRequired)
                name = methodsRequired{index};
                if ~(ismethod(provider,name) || isprop(provider,name))
                    error('LocalEpochTransitionCaptureProvider:providerMissingMethod', ...
                        'Provider %s is missing required member %s.',class(provider),name);
                end
            end
            mode = provider.declaredCaptureMode();
            if ~any(strcmp(char(mode), ...
                    revgnss.LocalEpochTransitionCaptureProvider.AllowedCaptureModes))
                error('LocalEpochTransitionCaptureProvider:captureModeUnsupported', ...
                    'Provider capture mode %s is not supported.',char(mode));
            end
        end

        function capture = requireCaptureAt(provider, intervalStartCoordinateEpoch_s, intervalDuration_s)
            % requireCaptureAt  The epoch-alignment gate lives HERE, not inside the network:
            % verifies the returned object is a revgnss.LocalEpochTransitionCapture AND that its
            % interval matches the requested one exactly.
            revgnss.LocalEpochTransitionCaptureProvider.requireProvider(provider);
            capture = provider.takeEpochCapture(intervalStartCoordinateEpoch_s,intervalDuration_s);
            if ~isa(capture,'revgnss.LocalEpochTransitionCapture')
                error('LocalEpochTransitionCaptureProvider:captureType', ...
                    'A provider must return a revgnss.LocalEpochTransitionCapture.');
            end
            if abs(capture.intervalStartCoordinateEpoch_s - intervalStartCoordinateEpoch_s) > 1e-9 || ...
                    abs(capture.intervalDuration_s - intervalDuration_s) > 1e-9
                error('LocalEpochTransitionCaptureProvider:captureEpochMismatch', ...
                    'The returned capture interval does not match the requested interval.');
            end
        end

        function P = requireLocalMarginal(provider)
            revgnss.LocalEpochTransitionCaptureProvider.requireProvider(provider);
            P = provider.localCovariance();
            if isempty(P) || any(~isfinite(P(:))) || size(P,1) ~= size(P,2) || ...
                    norm(P-P','fro') > 1e-8*max(1,norm(P,'fro'))
                error('LocalEpochTransitionCaptureProvider:localMarginal', ...
                    'A provider''s local marginal must be finite, square, and symmetric.');
            end
            n = provider.localStateDimension();
            if size(P,1) ~= n
                error('LocalEpochTransitionCaptureProvider:localMarginalDimension', ...
                    'A provider''s local marginal dimension must equal its declared localStateDimension.');
            end
        end
    end
end
