classdef OwnerLocalEkfTransitionCaptureProvider
    % OwnerLocalEkfTransitionCaptureProvider  Owner-side revgnss.LocalEpochTransitionCaptureProvider
    % (plan Stage 3.1). Holds a handle to the leaf's OWN filter.ReverseGNSSEKF only -- never a
    % ReverseGNSSSimulation, SpaceAsset, or clock object -- so it is structurally unable to read
    % truth, mirroring revgnss.OwnerLocalEstimatorEndpointProvider's stated discipline
    % (invariant 7).
    %
    % takeEpochCapture delegates to ekf.takeEpochTransitionCapture() (a plain struct), enriches
    % it with the 14-index schema, the component order, the attitude convention, and the
    % fingerprint, and wraps it in the immutable revgnss.LocalEpochTransitionCapture record.
    % This is the one place that performs the 14-index concatenation, via
    % revgnss.DistributedCovarianceNetworkContract.schemaStateIndicesFromStateMap.
    %
    % The (intervalStartCoordinateEpoch_s, intervalDuration_s) argument pair matches
    % revgnss.LocalEpochTransitionCaptureProvider.requireCaptureAt's own calling convention
    % exactly (the epoch-alignment gate lives in that contract method, not duplicated here).

    properties (SetAccess = immutable)
        endpointIdentifier          (1,:) char
        canonicalPhysicalAssetIndex (1,1) double
    end

    properties (Access = private)
        ekf_
    end

    methods (Access = private)
        function obj = OwnerLocalEkfTransitionCaptureProvider(ekfHandle, endpointIdentifier, ...
                canonicalPhysicalAssetIndex)
            if ~isa(ekfHandle,'filter.ReverseGNSSEKF')
                error('OwnerLocalEkfTransitionCaptureProvider:ekfType', ...
                    'ekfHandle must be a filter.ReverseGNSSEKF.');
            end
            if ~ekfHandle.retainEpochTransitionOperators
                error('OwnerLocalEkfTransitionCaptureProvider:retentionNotEnabled', ...
                    ['ekfHandle.retainEpochTransitionOperators must be true before a capture ' ...
                    'provider is constructed.']);
            end
            isJointStateMap = (ekfHandle.nSecondaryAssets > 0) || ...
                (isfield(ekfHandle.stateMap,'asset') && numel(ekfHandle.stateMap.asset) > 1);
            if isJointStateMap
                error('OwnerLocalEkfTransitionCaptureProvider:jointStateMapRejected', ...
                    ['This local estimator carries a joint (multi-asset) state map. A capture ' ...
                    'provider must read exactly one independent local filter; it must never ' ...
                    'index a joint-mode secondary-asset block.']);
            end
            obj.ekf_ = ekfHandle;
            obj.endpointIdentifier = char(endpointIdentifier);
            obj.canonicalPhysicalAssetIndex = double(canonicalPhysicalAssetIndex);
        end
    end

    methods
        function n = localStateDimension(obj)
            n = obj.ekf_.nx;
        end

        function idx = schemaStateIndices(obj)
            idx = revgnss.DistributedCovarianceNetworkContract.schemaStateIndicesFromStateMap( ...
                obj.ekf_.stateMap,1);
        end

        function fp = localStateMapFingerprint(obj)
            fp = revgnss.DistributedCovarianceNetworkContract.localStateMapFingerprint( ...
                obj.ekf_.stateMap,obj.ekf_.nx,obj.ekf_.attitudeParameterization);
        end

        function P = localCovariance(obj)
            % localCovariance  Live symmetrised copy of ekf.P. NEVER stored on this object: a
            % fresh read every call.
            Praw = obj.ekf_.P;
            P = (Praw+Praw')/2;
        end

        function mode = declaredCaptureMode(~)
            mode = 'ownerLocalPredictAndUpdateRetained';
        end

        function capture = takeEpochCapture(obj, intervalStartCoordinateEpoch_s, intervalDuration_s)
            raw = obj.ekf_.takeEpochTransitionCapture();
            [covarianceLabels, attitudeConvention] = ...
                revgnss.OwnerLocalEkfTransitionCaptureProvider.covarianceContractFor_(obj.ekf_);
            record = raw;
            record.endpointIdentifier = obj.endpointIdentifier;
            record.schemaStateIndices = obj.schemaStateIndices();
            record.covarianceComponentOrder = covarianceLabels;
            record.attitudeErrorCoordinateConvention = attitudeConvention;
            record.localStateMapFingerprint = obj.localStateMapFingerprint();
            capture = revgnss.LocalEpochTransitionCapture.fromLocalEpochRecord(record);
            if abs(capture.intervalStartCoordinateEpoch_s - intervalStartCoordinateEpoch_s) > 1e-9 || ...
                    abs(capture.intervalDuration_s - intervalDuration_s) > 1e-9
                error('OwnerLocalEkfTransitionCaptureProvider:captureEpochMismatch', ...
                    'The taken capture interval does not match the requested interval.');
            end
        end

        function registration = memberRegistrationRecord(obj, coordinateEpoch_s)
            [covarianceLabels, attitudeConvention] = ...
                revgnss.OwnerLocalEkfTransitionCaptureProvider.covarianceContractFor_(obj.ekf_);
            registration = struct( ...
                'endpointIdentifier',obj.endpointIdentifier, ...
                'canonicalPhysicalAssetIndex',obj.canonicalPhysicalAssetIndex, ...
                'localStateDimension',obj.localStateDimension(), ...
                'schemaStateIndices',obj.schemaStateIndices(), ...
                'covarianceComponentOrder',{covarianceLabels}, ...
                'attitudeErrorCoordinateConvention',attitudeConvention, ...
                'localStateMapFingerprint',obj.localStateMapFingerprint(), ...
                'stateSchemaVersion',revgnss.DistributedLinkProtocolContract.StateSchemaVersion, ...
                'priorIndependenceDeclaration','independentLocalPriors', ...
                'registrationCoordinateEpoch_s',coordinateEpoch_s);
        end

        function noteDeclaredExternalCovarianceWrite(obj)
            % noteDeclaredExternalCovarianceWrite  Asserts no capture window is left open across
            % a sanctioned coordinator write (ekf.applyDeclaredExternalCovarianceWrite itself
            % re-seeds the EKF's own watermark; this is the provider-level sanity check that no
            % caller left a window open before that write).
            if obj.ekf_.retainEpochTransitionOperators && obj.ekf_.hasOpenEpochTransitionCapture()
                error('OwnerLocalEkfTransitionCaptureProvider:captureStillOpen', ...
                    'An epoch-transition capture is still open; take it before an external write.');
            end
        end
    end

    methods (Static)
        function obj = forLocalEkf(ekfHandle, endpointIdentifier, canonicalPhysicalAssetIndex)
            obj = revgnss.OwnerLocalEkfTransitionCaptureProvider(ekfHandle,endpointIdentifier, ...
                canonicalPhysicalAssetIndex);
        end
    end

    methods (Static, Access = private)
        function [labels, convention] = covarianceContractFor_(ekfHandle)
            if strcmp(ekfHandle.attitudeParameterization,'quaternionErrorState')
                labels = revgnss.DistributedLinkProtocolContract.StateSchemaV1CovarianceComponentOrderTangent;
                convention = 'rightMultiplicativeLocalTangent_rad';
            else
                labels = revgnss.DistributedLinkProtocolContract.StateSchemaV1CovarianceComponentOrderEuler;
                convention = 'eulerZYXError_rad';
            end
        end
    end
end
