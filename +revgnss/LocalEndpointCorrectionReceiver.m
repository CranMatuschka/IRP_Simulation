classdef LocalEndpointCorrectionReceiver < handle
    % LocalEndpointCorrectionReceiver  One per fleet leaf (plan Stage 3.2 items 4/6/7). Holds
    % the leaf's revgnss.OwnerLocalEkfTransitionCaptureProvider and its own
    % revgnss.ObservationConsumptionLedger only -- no ReverseGNSSSimulation, no SpaceAsset, no
    % clock, no raw EKF handle -- so it is structurally unable to read truth (invariant 7) and
    % unable to bypass the sanctioned write gate.
    %
    % A receiver carries NO fixed endpoint role: the SAME leaf is the owner for some deliveries
    % and the remote for others across an epoch-synchronous run, so the role is determined per
    % call from which endpoint of the message this receiver's own identifier matches
    % (revgnss.SynchronizedPairCorrectionMessage.correctionForEndpoint), never baked into the
    % object.
    %
    % prepareAcknowledgement is PURE -- it never writes -- and refuses (returns a refusal
    % object, never throws) in a fixed order, first failure wins. commitAcknowledgedCorrection
    % performs no ledger write; the ledger writes are the transaction's own last step.

    properties (SetAccess = immutable)
        endpointIdentifier (1,:) char
    end

    properties (Access = private)
        captureProvider_
        observationLedger_
    end

    methods (Access = private)
        function obj = LocalEndpointCorrectionReceiver(captureProvider, observationLedger)
            revgnss.LocalEndpointCorrectionApplicationProvider.requireProvider(captureProvider);
            if ~isa(observationLedger,'revgnss.ObservationConsumptionLedger')
                error('LocalEndpointCorrectionReceiver:observationLedgerType', ...
                    'observationLedger must be a revgnss.ObservationConsumptionLedger.');
            end
            obj.captureProvider_ = captureProvider;
            obj.observationLedger_ = observationLedger;
            obj.endpointIdentifier = captureProvider.endpointIdentifier();
        end
    end

    methods
        function ack = prepareAcknowledgement(obj, message, physicalObservationRecord, fleetLedgerEntryState)
            if ~isa(message,'revgnss.SynchronizedPairCorrectionMessage')
                error('LocalEndpointCorrectionReceiver:messageType', ...
                    'prepareAcknowledgement requires a revgnss.SynchronizedPairCorrectionMessage.');
            end

            % Role is determined structurally (a harmless field read, requiring no trust in the
            % signature) BEFORE the integrity check, purely so every refusal record -- including
            % an integrity failure -- can carry a valid AllowedEndpointRoles value. Best-effort
            % 'owner' is used for the not-addressed-at-all case, where no real role exists yet.
            isOwner = strcmp(obj.endpointIdentifier,message.ownerEndpointCorrection.endpointIdentifier);
            isRemote = strcmp(obj.endpointIdentifier,message.remoteEndpointCorrection.endpointIdentifier);
            role = 'owner';
            if isRemote && ~isOwner; role = 'remote'; end

            % 1. message integrity
            try
                revgnss.SynchronizedPairCorrectionMessage.requireIntact(message);
            catch
                ack = obj.refuseWith_(message,role,'messageSignatureInvalid', ...
                    'The message content digest does not match its declared signature.');
                return
            end

            % 2. addressed by this message?
            if ~(isOwner || isRemote)
                ack = obj.refuseWith_(message,role,'recipientNotAddressedByMessage', ...
                    'This message does not address this endpoint.');
                return
            end
            corr = message.correctionForEndpoint(obj.endpointIdentifier);

            % 3. state schema version
            if ~strcmp(message.stateSchemaVersion,revgnss.DistributedLinkProtocolContract.StateSchemaVersion)
                ack = obj.refuseWith_(message,role,'stateSchemaVersionMismatch', ...
                    'stateSchemaVersion does not match the frozen Stage-2 v1 schema version.');
                return
            end

            % 4. live state-map fingerprint
            liveFingerprint = obj.captureProvider_.localStateMapFingerprint();
            if ~strcmp(liveFingerprint,corr.localStateMapFingerprint)
                ack = obj.refuseWith_(message,role,'recipientStateMapFingerprintChanged', ...
                    'The live local state-map fingerprint has changed since the message was assembled.');
                return
            end

            % 5. state dimension
            if obj.captureProvider_.localStateDimension() ~= corr.localStateDimension
                ack = obj.refuseWith_(message,role,'recipientStateDimensionMismatch', ...
                    'The live local state dimension does not match the message payload.');
                return
            end

            % 6. attitude convention / parameterization
            if ~strcmp(obj.captureProvider_.attitudeParameterization(),corr.attitudeParameterization)
                ack = obj.refuseWith_(message,role,'recipientAttitudeConventionMismatch', ...
                    'The live attitude parameterization does not match the message payload.');
                return
            end

            % 7. no open capture window
            if obj.captureProvider_.hasOpenEpochTransitionCapture()
                ack = obj.refuseWith_(message,role,'recipientOpenEpochTransitionCapture', ...
                    'An epoch-transition capture is still open on this endpoint.');
                return
            end

            % 8. prior-state digest (the sharpest out-of-sequence guard: catches "computed
            % before another same-epoch write, applied after")
            liveDigest = obj.captureProvider_.localStateDigest();
            if ~strcmp(liveDigest,corr.priorStateDigest_hex)
                ack = obj.refuseWith_(message,role,'priorStateDigestMismatch', ...
                    ['The live prior-state digest does not match the message payload: this ' ...
                    'endpoint''s state has moved since the message was assembled.']);
                return
            end

            % 9. posterior finite + symmetric (PSD already forced by the message constructor)
            P = corr.PPosterior;
            if any(~isfinite(P(:))) || any(~isfinite(corr.xPosterior(:)))
                ack = obj.refuseWith_(message,role,'nonFiniteCorrection', ...
                    'The proposed posterior contains a non-finite value.');
                return
            end
            if norm(P-P','fro') > revgnss.SynchronizedDeliveryContract.PosteriorSymmetryToleranceRelative* ...
                    max(1,norm(P,'fro'))
                ack = obj.refuseWith_(message,role,'posteriorNotSymmetricPositiveSemiDefinite', ...
                    'The proposed posterior is not symmetric.');
                return
            end

            % 10. this leaf's own ledger does not already hold the observation (makes the
            % transaction's later ledger writes total, per U19)
            if obj.observationLedger_.holdsObservation(physicalObservationRecord)
                ack = obj.refuseWith_(message,role,'recipientLedgerAlreadyHoldsObservation', ...
                    'This leaf''s own consumption ledger already holds this observation.');
                return
            end

            % 11. fleet ledger entry state
            if ~strcmp(char(fleetLedgerEntryState),'eligible')
                ack = obj.refuseWith_(message,role,'fleetLedgerEntryNotEligible', ...
                    'The fleet-wide delivery ledger entry for this observation is not eligible.');
                return
            end

            ack = revgnss.EndpointCorrectionAcknowledgement.accept(struct( ...
                'messageIdentifier',message.messageIdentifier, ...
                'messageSignature_hex',message.messageSignature_hex, ...
                'endpointIdentifier',obj.endpointIdentifier, ...
                'endpointRole',role, ...
                'reasonMessage','accepted', ...
                'validatedPriorStateDigest_hex',liveDigest, ...
                'validatedStateMapFingerprint',liveFingerprint, ...
                'acknowledgementEpoch_s',message.coordinateEventEpoch_s, ...
                'acknowledgementPhase','prepared'));
        end

        function snapshot = takeRollbackSnapshot(obj)
            snapshot = revgnss.LocalEndpointCorrectionApplicationProvider.requireRollbackSnapshot( ...
                obj.captureProvider_);
        end

        function commitAcknowledgedCorrection(obj, message, preparedAcknowledgement)
            if ~(isa(preparedAcknowledgement,'revgnss.EndpointCorrectionAcknowledgement') && ...
                    preparedAcknowledgement.accepted && ...
                    strcmp(preparedAcknowledgement.acknowledgementPhase,'prepared') && ...
                    strcmp(preparedAcknowledgement.messageIdentifier,message.messageIdentifier) && ...
                    strcmp(preparedAcknowledgement.messageSignature_hex,message.messageSignature_hex) && ...
                    strcmp(preparedAcknowledgement.endpointIdentifier,obj.endpointIdentifier))
                error('LocalEndpointCorrectionReceiver:acknowledgementNotBound', ...
                    ['commitAcknowledgedCorrection requires an accepted, prepared acknowledgement ' ...
                    'bound to this exact message identifier, signature, and endpoint.']);
            end
            liveDigest = obj.captureProvider_.localStateDigest();
            if ~strcmp(liveDigest,preparedAcknowledgement.validatedPriorStateDigest_hex)
                error('LocalEndpointCorrectionReceiver:priorStateDigestChangedSinceAcknowledge', ...
                    'This endpoint''s state changed between acknowledge and commit.');
            end
            corr = message.correctionForEndpoint(obj.endpointIdentifier);
            revgnss.LocalEndpointCorrectionApplicationProvider.requireCorrectionApplied( ...
                obj.captureProvider_,corr.xPosterior,corr.PPosterior,corr.nominalQuatPosterior, ...
                corr.attitudeInjectionNorm_rad);
        end

        function rollback(obj, snapshot)
            revgnss.LocalEndpointCorrectionApplicationProvider.requireRollbackRestored( ...
                obj.captureProvider_,snapshot);
        end

        function recordOwnerConsumption(obj, physicalObservationRecord, epoch_s)
            obj.observationLedger_.markEligible(physicalObservationRecord,epoch_s);
            obj.observationLedger_.consume(physicalObservationRecord,epoch_s);
        end

        function recordNonOwnerEndpointApplication(obj, physicalObservationRecord, epoch_s)
            obj.observationLedger_.markAppliedAsNonOwnerEndpoint(physicalObservationRecord,epoch_s);
        end

        function hex = stateDigest(obj)
            hex = obj.captureProvider_.localStateDigest();
        end
    end

    methods (Access = private)
        function ack = refuseWith_(obj, message, role, reasonCode, reasonMessage)
            ack = revgnss.EndpointCorrectionAcknowledgement.refuse(struct( ...
                'messageIdentifier',message.messageIdentifier, ...
                'messageSignature_hex',message.messageSignature_hex, ...
                'endpointIdentifier',obj.endpointIdentifier, ...
                'endpointRole',role, ...
                'reasonCode',reasonCode, ...
                'reasonMessage',reasonMessage, ...
                'validatedPriorStateDigest_hex','', ...
                'validatedStateMapFingerprint','', ...
                'acknowledgementEpoch_s',message.coordinateEventEpoch_s, ...
                'acknowledgementPhase','prepared'));
        end
    end

    methods (Static)
        function obj = forLocalLeaf(captureProvider, observationLedger)
            obj = revgnss.LocalEndpointCorrectionReceiver(captureProvider,observationLedger);
        end
    end
end
