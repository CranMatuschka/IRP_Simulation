classdef SynchronizedDeliveryContract
    % SynchronizedDeliveryContract  Frozen Section-3.2 vocabulary and shared statics for the
    % synchronized two-endpoint link-delivery protocol (plan Stage 3.2). Extends Stage 3.1's
    % revgnss.DistributedCovarianceNetworkContract with the vocabulary needed to deliver a
    % correction to BOTH endpoint filters from one shared innovation, rather than only
    % conditioning the network on a conservative owner-only update.

    properties (Constant)
        ProtocolSchemaVersion = 'synchronizedPairDelivery-v1'

        % Section 3.4 item 1: coherent two-way ISL range is the first observable enabled with
        % full endpoint distributed update. Widening this list is Section 3.4 scope.
        PairExactEligibleObservables = {'coherentTwoWayCodeRange'}

        AllowedPartialDeliveryPolicies      = {'rejectWholeUpdate'}
        AllowedMessageSignaturePolicies     = {'contentDigestFnv1a64'}
        AllowedThirdMemberCrossConditioning = {'exactJointPairTransform'}
        AllowedEndpointOverlapPolicies      = {'rejectSupersededLinearizationPoint'}
        AllowedProcessingOrders             = {'ascendingObservationIdentifier'}
        AllowedEndpointRoles                = {'owner','remote'}
        AllowedEndpointApplicationKinds     = {'ownerOnly','bothEndpointsSynchronized'}

        % The sub-phase order inside one synchronized delivery (documentary + a mechanical
        % tripwire target); NOT the coordinator's own frozen per-epoch phase order, which stays
        % revgnss.DistributedCovarianceNetworkContract.EpochPhaseOrderWithCorrelationNetwork,
        % untouched.
        SynchronizedDeliverySubPhaseOrder = { ...
            'assembleSignedCorrectionMessage', ...
            'acknowledgeOwnerEndpoint', ...
            'acknowledgeRemoteEndpoint', ...
            'requireBothAcknowledgements', ...
            'commitStagedCrossBlocks', ...
            'commitOwnerEndpoint', ...
            'commitRemoteEndpoint', ...
            'recordSynchronizedConsumption'}

        AllowedAcknowledgementReasonCodes = { ...
            'accepted','recipientNotAddressedByMessage','messageSignatureInvalid', ...
            'stateSchemaVersionMismatch','recipientStateMapFingerprintChanged', ...
            'recipientStateDimensionMismatch','recipientAttitudeConventionMismatch', ...
            'recipientOpenEpochTransitionCapture','priorStateDigestMismatch', ...
            'posteriorNotSymmetricPositiveSemiDefinite','nonFiniteCorrection', ...
            'recipientLedgerAlreadyHoldsObservation','fleetLedgerEntryNotEligible'}

        AllowedSynchronizedRefusalReasonCodes = { ...
            'synchronizedPreparationFailed','synchronizedPartialDeliveryRejected', ...
            'synchronizedCommitRolledBack','linearizationPointSupersededByPairExactUpdate', ...
            'pairExactObservableNotEligible','pairExactClockGaugeNotAnchored', ...
            'pairExactCommonSourceContributionUntreated', ...
            'crossBlockMissingForThirdMember','staleNetworkRevision','endpointStateDigestChanged'}

        ThirdMemberOmittedVarianceToleranceRelative = 1e-12
        PosteriorSymmetryToleranceRelative          = 1e-12
        PosteriorEigenvalueToleranceScaled          = 1e-10
        OrderInvarianceToleranceRelative            = 1e-12
    end

    methods (Static)
        function tf = isPairExactEligibleObservable(observableIdentifier)
            tf = any(strcmp(char(observableIdentifier), ...
                revgnss.SynchronizedDeliveryContract.PairExactEligibleObservables));
        end

        function requireAcknowledgementReasonCode(code)
            if ~any(strcmp(char(code), ...
                    revgnss.SynchronizedDeliveryContract.AllowedAcknowledgementReasonCodes))
                error('SynchronizedDeliveryContract:acknowledgementReasonCode', ...
                    'reasonCode must be one of the frozen AllowedAcknowledgementReasonCodes.');
            end
        end

        function requireRefusalReasonCode(code)
            if ~any(strcmp(char(code), ...
                    revgnss.SynchronizedDeliveryContract.AllowedSynchronizedRefusalReasonCodes))
                error('SynchronizedDeliveryContract:refusalReasonCode', ...
                    'refusalReasonCode must be one of the frozen AllowedSynchronizedRefusalReasonCodes.');
            end
        end

        function requireSubPhaseOrderUnchanged()
            expected = { ...
                'assembleSignedCorrectionMessage','acknowledgeOwnerEndpoint', ...
                'acknowledgeRemoteEndpoint','requireBothAcknowledgements', ...
                'commitStagedCrossBlocks','commitOwnerEndpoint','commitRemoteEndpoint', ...
                'recordSynchronizedConsumption'};
            if ~isequal(revgnss.SynchronizedDeliveryContract.SynchronizedDeliverySubPhaseOrder,expected)
                error('SynchronizedDeliveryContract:subPhaseOrderDrift', ...
                    'SynchronizedDeliverySubPhaseOrder must remain byte-identical to its frozen value.');
            end
        end

        function requirePhaseSixNameFrozen()
            % requirePhaseSixNameFrozen  Mechanical proof that Stage 3.2 did not rename phase 6
            % ('ownerOnlyLinkUpdate') or its coordinator method: source-regex over the real file.
            thisDir = fileparts(mfilename('fullpath'));
            srcPath = fullfile(thisDir,'IndependentFleetCoordinator.m');
            src = fileread(srcPath);
            if isempty(regexp(src,'function\s+applyOwnerOnlyLinkUpdate_\s*\(','once'))
                error('SynchronizedDeliveryContract:phaseSixRenamed', ...
                    'IndependentFleetCoordinator.applyOwnerOnlyLinkUpdate_ must not be renamed.');
            end
            % EpochPhaseOrderWithCorrelationNetwork is 1-indexed with 'ownerOnlyLinkUpdate' as its
            % SIXTH entry (advanceSharedTruthAndLocalPrediction, localGroundOnboardUpdate,
            % propagateAndConditionCrossCovariance, publishAndFreezeEstimatorProducts,
            % generateValidateDeliverLinkRecords, ownerOnlyLinkUpdate, ...) -- index 6, not 5.
            phaseOrder = revgnss.DistributedCovarianceNetworkContract.EpochPhaseOrderWithCorrelationNetwork;
            if ~strcmp(phaseOrder{6},'ownerOnlyLinkUpdate')
                error('SynchronizedDeliveryContract:phaseSixRenamed', ...
                    'EpochPhaseOrderWithCorrelationNetwork{6} must remain ''ownerOnlyLinkUpdate''.');
            end
        end
    end
end
