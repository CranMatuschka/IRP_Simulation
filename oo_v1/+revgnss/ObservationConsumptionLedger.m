classdef ObservationConsumptionLedger < handle
    % ObservationConsumptionLedger  Tracks eligible and consumed observations.

    properties (Access = private)
        eligible
        consumed
        appliedAsNonOwner_   % Stage 3.2: additive, NON-COUNTING trace for a remote endpoint's
                             % own synchronized correction. Deliberately invisible to
                             % numberEligible/numberConsumed/eligibleIdentifiers/
                             % consumedIdentifiers/reconcileWithLocalLedgers: the OWNER leaf is
                             % the one and only consumer of record for a physical observation
                             % (invariant 9); a second consume would double
                             % IndependentFleetCoordinator.linkObservationCounters_.
                             % consumedByOwner (it sums numberConsumed() over every leaf).
    end

    methods
        function obj = ObservationConsumptionLedger()
            obj.eligible = containers.Map('KeyType','char','ValueType','double');
            obj.consumed = containers.Map('KeyType','char','ValueType','double');
            obj.appliedAsNonOwner_ = containers.Map('KeyType','char','ValueType','double');
        end

        function markEligible(obj,observation,epoch_s)
            [identifier,epoch_s] = obj.validateInput_(observation,epoch_s);
            if isKey(obj.eligible,identifier) || isKey(obj.consumed,identifier)
                error('ObservationConsumptionLedger:duplicateObservation', ...
                    'Observation %s has already been appended or consumed.', ...
                    identifier);
            end
            obj.eligible(identifier) = epoch_s;
        end

        function consume(obj,observation,epoch_s)
            [identifier,epoch_s] = obj.validateInput_(observation,epoch_s);
            if isKey(obj.consumed,identifier)
                error('ObservationConsumptionLedger:duplicateObservation', ...
                    'Observation %s has already been used in an estimator update.', ...
                    identifier);
            end
            if ~isKey(obj.eligible,identifier)
                error('ObservationConsumptionLedger:notEligible', ...
                    'Observation %s was not appended to an eligible estimator row.', ...
                    identifier);
            end
            if obj.eligible(identifier) ~= epoch_s
                error('ObservationConsumptionLedger:epochMismatch', ...
                    'Observation %s must be consumed at its appended epoch.', ...
                    identifier);
            end
            obj.consumed(identifier) = epoch_s;
        end

        function count = numberEligible(obj)
            count = obj.eligible.Count;
        end

        function count = numberConsumed(obj)
            count = obj.consumed.Count;
        end

        function identifiers = eligibleIdentifiers(obj)
            % eligibleIdentifiers  Read-only accessor: every observationIdentifier currently
            % marked eligible (Section 2.1 rule 2 fleet-wide reconciliation needs identifier-
            % level, not merely count-level, access). No new state, no behaviour change.
            identifiers = keys(obj.eligible);
        end

        function identifiers = consumedIdentifiers(obj)
            % consumedIdentifiers  Read-only accessor, see eligibleIdentifiers.
            identifiers = keys(obj.consumed);
        end

        function markAppliedAsNonOwnerEndpoint(obj, observation, epoch_s)
            % markAppliedAsNonOwnerEndpoint  Stage 3.2: records that THIS leaf received a real
            % synchronized correction as the non-owner (remote) endpoint of a pair-exact link
            % update. Additive and non-counting (see the appliedAsNonOwner_ property header);
            % refuses a duplicate and refuses if this leaf already holds the identifier as
            % eligible or consumed (an endpoint is never simultaneously the owner and the
            % remote of its own physical observation).
            [identifier,epoch_s] = revgnss.ObservationConsumptionLedger.validateInput_(observation,epoch_s);
            if isKey(obj.appliedAsNonOwner_,identifier)
                error('ObservationConsumptionLedger:duplicateObservation', ...
                    'Observation %s has already been applied as a non-owner endpoint.',identifier);
            end
            if isKey(obj.eligible,identifier) || isKey(obj.consumed,identifier)
                error('ObservationConsumptionLedger:ownerRemoteConflict', ...
                    'Observation %s is already tracked as an owner-side record on this leaf.',identifier);
            end
            obj.appliedAsNonOwner_(identifier) = epoch_s;
        end

        function count = numberAppliedAsNonOwner(obj)
            count = obj.appliedAsNonOwner_.Count;
        end

        function identifiers = appliedAsNonOwnerIdentifiers(obj)
            identifiers = keys(obj.appliedAsNonOwner_);
        end

        function tf = holdsObservation(obj, observation)
            % holdsObservation  True if this leaf holds the physical observation's identifier in
            % ANY of the three maps (eligible, consumed, or applied-as-non-owner). Used by
            % revgnss.LocalEndpointCorrectionReceiver.prepareAcknowledgement (check 10) to
            % refuse a synchronized delivery this leaf has already seen in any role.
            identifier = observation.observationIdentifier;
            tf = isKey(obj.eligible,identifier) || isKey(obj.consumed,identifier) || ...
                isKey(obj.appliedAsNonOwner_,identifier);
        end
    end

    methods (Static, Access = private)
        function [identifier,epoch_s] = validateInput_(observation,epoch_s)
            if ~isa(observation,'revgnss.InterSatelliteObservationRecord') && ...
                    ~isa(observation,'revgnss.InterSatelliteTimeTransferObservationRecord') && ...
                    ~isa(observation,'revgnss.OneWayInterSatelliteObservationRecord')
                error('ObservationConsumptionLedger:observationType', ...
                    'Only immutable inter-satellite observation records can be tracked.');
            end
            if ~(isnumeric(epoch_s) && isscalar(epoch_s) && isfinite(epoch_s))
                error('ObservationConsumptionLedger:epoch', ...
                    'The observation epoch must be a finite scalar.');
            end
            identifier = observation.observationIdentifier;
            epoch_s = double(epoch_s);
        end
    end
end
