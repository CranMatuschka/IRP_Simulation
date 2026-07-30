classdef ObservationConsumptionLedger < handle
    % ObservationConsumptionLedger  Tracks eligible and consumed observations.

    properties (Access = private)
        eligible
        consumed
    end

    methods
        function obj = ObservationConsumptionLedger()
            obj.eligible = containers.Map('KeyType','char','ValueType','double');
            obj.consumed = containers.Map('KeyType','char','ValueType','double');
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
    end

    methods (Static, Access = private)
        function [identifier,epoch_s] = validateInput_(observation,epoch_s)
            if ~isa(observation,'revgnss.InterSatelliteObservationRecord') && ...
                    ~isa(observation, ...
                    'revgnss.InterSatelliteTimeTransferObservationRecord')
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
