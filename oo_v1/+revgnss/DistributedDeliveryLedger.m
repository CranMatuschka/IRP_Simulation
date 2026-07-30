classdef DistributedDeliveryLedger < handle
    % DistributedDeliveryLedger  Coordinator-owned fleet-wide delivery ledger (plan Section
    % 2.1 rule 2).
    %
    % Generalizes revgnss.ObservationConsumptionLedger additively: that per-local-simulation
    % ledger tracks eligible/consumed for one local EKF's own instance only, so nothing today
    % reconciles across local sims or proves a physical observation identifier was consumed by
    % at most one owner fleet-wide. This class is the fleet-wide proof: entries are keyed
    % ONLY by the physical observationIdentifier (revgnss.LinkObservationDelivery), so at most
    % one entry can ever exist per physical datum, at most one owner is ever recorded for it,
    % and at most one eligible->consumed transition can ever happen.
    %
    % There is exactly one coordinator per fleet run, hence exactly one ledger per fleet
    % (revgnss.IndependentFleetCoordinator.deliveryLedger). No handle to this ledger is ever
    % passed to a local revgnss.ReverseGNSSSimulation; information flows one way only, from the
    % coordinator READING leaf ledgers for reconciliation.

    properties (Constant)
        AllowedStates = {'eligible','consumed','rejected'};
    end

    properties (Access = private)
        entries_ containers.Map
        order_ (1,:) cell = {}
    end

    methods
        function obj = DistributedDeliveryLedger()
            obj.entries_ = containers.Map('KeyType','char','ValueType','any');
        end

        function recordEligible(obj, delivery)
            if ~isa(delivery,'revgnss.LinkObservationDelivery')
                error('DistributedDeliveryLedger:deliveryType', ...
                    'recordEligible requires a revgnss.LinkObservationDelivery.');
            end
            identifier = delivery.observationIdentifier;
            if isKey(obj.entries_,identifier)
                error('DistributedDeliveryLedger:duplicateObservation', ...
                    'Observation %s already has a fleet-wide delivery ledger entry.',identifier);
            end
            entry = struct( ...
                'observationIdentifier',identifier, ...
                'deliveryIdentifier',delivery.deliveryIdentifier, ...
                'sessionIdentifier',delivery.sessionIdentifier, ...
                'physicalRecordClass',delivery.physicalRecordClass, ...
                'ownerAssetIdentifier',delivery.ownerAssetIdentifier, ...
                'ownerCanonicalIndex',delivery.ownerCanonicalIndex, ...
                'remoteAssetIdentifier',delivery.remoteAssetIdentifier, ...
                'remoteProductIdentifier',delivery.remoteProductIdentifier, ...
                'sourceEpoch_s',delivery.sourceEpoch_s, ...
                'deliveryEpoch_s',delivery.deliveryEpoch_s, ...
                'consumptionEpoch_s',NaN, ...
                'state','eligible', ...
                'rejectionReasonCode','', ...
                'rejectionReasonMessage','', ...
                'rejectionSourceErrorIdentifier','', ...
                'covarianceGroupIdentifier',delivery.covarianceGroupIdentifier, ...
                'calibrationProductIdentifiers',{delivery.calibrationProductIdentifiers}, ...
                'remoteProductAge_s',delivery.remoteProductAge_s, ...
                'correlationPolicy',delivery.correlationPolicy);
            obj.entries_(identifier) = entry;
            obj.order_{end+1} = identifier;
        end

        function recordConsumed(obj, observationIdentifier, ownerAssetIdentifier, updateEpoch_s)
            identifier = char(observationIdentifier);
            if ~isKey(obj.entries_,identifier)
                error('DistributedDeliveryLedger:unknownObservation', ...
                    'Observation %s has no fleet-wide delivery ledger entry.',identifier);
            end
            entry = obj.entries_(identifier);
            if strcmp(entry.state,'consumed')
                error('DistributedDeliveryLedger:alreadyConsumed', ...
                    'Observation %s has already been consumed.',identifier);
            end
            if strcmp(entry.state,'rejected')
                error('DistributedDeliveryLedger:alreadyRejected', ...
                    'Observation %s was rejected and cannot be consumed.',identifier);
            end
            if ~strcmp(entry.ownerAssetIdentifier,char(ownerAssetIdentifier))
                error('DistributedDeliveryLedger:ownerMismatch', ...
                    'Observation %s may be consumed only by its recorded owner %s.', ...
                    identifier,entry.ownerAssetIdentifier);
            end
            if entry.deliveryEpoch_s ~= updateEpoch_s
                error('DistributedDeliveryLedger:epochMismatch', ...
                    'Observation %s must be consumed at its recorded delivery epoch.',identifier);
            end
            entry.state = 'consumed';
            entry.consumptionEpoch_s = double(updateEpoch_s);
            obj.entries_(identifier) = entry;
        end

        function recordRejected(obj, rejectionRecord)
            required = {'observationIdentifier','ownerAssetIdentifier', ...
                'remoteProductIdentifier','sourceEpoch_s','deliveryEpoch_s','reasonCode', ...
                'reasonMessage','sourceErrorIdentifier','physicalRecordClass'};
            missing = setdiff(required,fieldnames(rejectionRecord));
            if ~isempty(missing)
                error('DistributedDeliveryLedger:reasonCode', ...
                    'recordRejected rejection record is missing %s.',missing{1});
            end
            identifier = char(rejectionRecord.observationIdentifier);
            if isKey(obj.entries_,identifier)
                error('DistributedDeliveryLedger:duplicateObservation', ...
                    'Observation %s already has a fleet-wide delivery ledger entry.',identifier);
            end
            entry = struct( ...
                'observationIdentifier',identifier, ...
                'deliveryIdentifier','', ...
                'sessionIdentifier','', ...
                'physicalRecordClass',char(rejectionRecord.physicalRecordClass), ...
                'ownerAssetIdentifier',char(rejectionRecord.ownerAssetIdentifier), ...
                'ownerCanonicalIndex',NaN, ...
                'remoteAssetIdentifier','', ...
                'remoteProductIdentifier',char(rejectionRecord.remoteProductIdentifier), ...
                'sourceEpoch_s',rejectionRecord.sourceEpoch_s, ...
                'deliveryEpoch_s',rejectionRecord.deliveryEpoch_s, ...
                'consumptionEpoch_s',NaN, ...
                'state','rejected', ...
                'rejectionReasonCode',char(rejectionRecord.reasonCode), ...
                'rejectionReasonMessage',char(rejectionRecord.reasonMessage), ...
                'rejectionSourceErrorIdentifier',char(rejectionRecord.sourceErrorIdentifier), ...
                'covarianceGroupIdentifier','', ...
                'calibrationProductIdentifiers',{{}}, ...
                'remoteProductAge_s',NaN, ...
                'correlationPolicy','');
            obj.entries_(identifier) = entry;
            obj.order_{end+1} = identifier;
        end

        function recordRejectedFromEligible(obj, observationIdentifier, reasonCode, ...
                reasonMessage, sourceErrorIdentifier)
            % recordRejectedFromEligible  ADDITIVE (plan Section 2.3.1): transitions an EXISTING
            % 'eligible' entry to 'rejected' -- the transition recordRejected cannot perform,
            % since recordRejected refuses any identifier already keyed. Needed because phase 4
            % (generateValidateDeliverLinkRecords_) always records a proposed delivery eligible
            % before phase 5 (applyOwnerOnlyLinkUpdate_) attempts to consume it; a physics/bound
            % failure in phase 5 must become a ledger rejection, not an uncaught error, without
            % ever creating a second entry for the same physical observation identifier.
            identifier = char(observationIdentifier);
            if ~isKey(obj.entries_,identifier)
                error('DistributedDeliveryLedger:unknownObservation', ...
                    'Observation %s has no fleet-wide delivery ledger entry.',identifier);
            end
            entry = obj.entries_(identifier);
            if ~strcmp(entry.state,'eligible')
                error('DistributedDeliveryLedger:notEligible', ...
                    'Observation %s is not in the eligible state (state=%s).',identifier,entry.state);
            end
            entry.state = 'rejected';
            entry.rejectionReasonCode = char(reasonCode);
            entry.rejectionReasonMessage = char(reasonMessage);
            entry.rejectionSourceErrorIdentifier = char(sourceErrorIdentifier);
            obj.entries_(identifier) = entry;
        end

        function count = numberEligible(obj)
            count = obj.countState_('eligible');
        end

        function count = numberConsumed(obj)
            count = obj.countState_('consumed');
        end

        function count = numberRejected(obj)
            count = obj.countState_('rejected');
        end

        function tf = isConsumed(obj, observationIdentifier)
            identifier = char(observationIdentifier);
            tf = isKey(obj.entries_,identifier) && ...
                strcmp(obj.entries_(identifier).state,'consumed');
        end

        function owner = ownerFor(obj, observationIdentifier)
            identifier = char(observationIdentifier);
            if ~isKey(obj.entries_,identifier)
                error('DistributedDeliveryLedger:unknownObservation', ...
                    'Observation %s has no fleet-wide delivery ledger entry.',identifier);
            end
            owner = obj.entries_(identifier).ownerAssetIdentifier;
        end

        function entry = entryFor(obj, observationIdentifier)
            identifier = char(observationIdentifier);
            if ~isKey(obj.entries_,identifier)
                error('DistributedDeliveryLedger:unknownObservation', ...
                    'Observation %s has no fleet-wide delivery ledger entry.',identifier);
            end
            entry = obj.entries_(identifier);
        end

        function rows = export(obj)
            rows = repmat(revgnss.DistributedDeliveryLedger.emptyEntry_(),1,numel(obj.order_));
            for index = 1:numel(obj.order_)
                rows(index) = obj.entries_(obj.order_{index});
            end
        end

        function out = summary(obj)
            rows = obj.export();
            states = {rows.state};
            reasonCodes = {};
            reasonCounts = [];
            for index = 1:numel(rows)
                if ~strcmp(rows(index).state,'rejected'); continue; end
                code = rows(index).rejectionReasonCode;
                match = find(strcmp(reasonCodes,code),1);
                if isempty(match)
                    reasonCodes{end+1} = code; %#ok<AGROW>
                    reasonCounts(end+1) = 1; %#ok<AGROW>
                else
                    reasonCounts(match) = reasonCounts(match)+1;
                end
            end
            reasonStruct = struct();
            for index = 1:numel(reasonCodes)
                reasonStruct.(matlab.lang.makeValidName(reasonCodes{index})) = reasonCounts(index);
            end
            ages = [rows.remoteProductAge_s];
            ages = ages(~isnan(ages));
            maxAge = 0;
            if ~isempty(ages); maxAge = max(ages); end
            ownerIds = {rows.ownerAssetIdentifier};
            ownerIds = ownerIds(~cellfun(@isempty,ownerIds));
            out = struct( ...
                'eligible',sum(strcmp(states,'eligible')), ...
                'consumed',sum(strcmp(states,'consumed')), ...
                'rejected',sum(strcmp(states,'rejected')), ...
                'distinctOwners',numel(unique(ownerIds)), ...
                'distinctObservations',numel(obj.order_), ...
                'rejectionsByReasonCode',reasonStruct, ...
                'maximumRemoteProductAge_s',maxAge);
        end

        function report = reconcileWithLocalLedgers(obj, localLedgers)
            if ~iscell(localLedgers) || ...
                    any(~cellfun(@(v) isa(v,'revgnss.ObservationConsumptionLedger'),localLedgers))
                error('DistributedDeliveryLedger:localLedgerType', ...
                    'localLedgers must be a cell array of revgnss.ObservationConsumptionLedger.');
            end
            localConsumedIdentifiers = {};
            localConsumedTotal = 0;
            for index = 1:numel(localLedgers)
                ids = localLedgers{index}.consumedIdentifiers();
                localConsumedIdentifiers = [localConsumedIdentifiers,ids]; %#ok<AGROW>
                localConsumedTotal = localConsumedTotal + numel(ids);
            end
            localConsumedIdentifiers = unique(localConsumedIdentifiers);

            fleetConsumedIdentifiers = {};
            rows = obj.export();
            for index = 1:numel(rows)
                if strcmp(rows(index).state,'consumed')
                    fleetConsumedIdentifiers{end+1} = rows(index).observationIdentifier; %#ok<AGROW>
                end
            end

            consumedLocallyWithoutFleetRecord = setdiff(localConsumedIdentifiers, ...
                fleetConsumedIdentifiers);
            consumedByFleetWithoutLocalRecord = setdiff(fleetConsumedIdentifiers, ...
                localConsumedIdentifiers);
            % RESERVED, NOT YET CHECKED: revgnss.ObservationConsumptionLedger records only
            % identifier->epoch, never an owner, so a local sim consuming an observation owned
            % (per this fleet-wide ledger) by a DIFFERENT asset is structurally undetectable
            % today. ownerDisagreements is always empty; it is not folded into isReconciled
            % below so a reader cannot mistake "always empty" for "checked and clean." Closing
            % this requires the local ledger to record an owner, which is deliberately deferred
            % rather than bolted on here.
            ownerDisagreements = {};
            ownerDisagreementsChecked = false;

            report = struct( ...
                'fleetConsumed',numel(fleetConsumedIdentifiers), ...
                'localConsumedTotal',localConsumedTotal, ...
                'consumedLocallyWithoutFleetRecord',{consumedLocallyWithoutFleetRecord}, ...
                'consumedByFleetWithoutLocalRecord',{consumedByFleetWithoutLocalRecord}, ...
                'ownerDisagreements',{ownerDisagreements}, ...
                'ownerDisagreementsChecked',ownerDisagreementsChecked, ...
                'isReconciled',isempty(consumedLocallyWithoutFleetRecord) && ...
                    isempty(consumedByFleetWithoutLocalRecord));
        end
    end

    methods (Static)
        function requireReconciled(report)
            if ~(isstruct(report) && isfield(report,'isReconciled'))
                error('DistributedDeliveryLedger:reconciliationMismatch', ...
                    'requireReconciled requires a reconcileWithLocalLedgers report struct.');
            end
            if ~report.isReconciled
                error('DistributedDeliveryLedger:reconciliationMismatch', ...
                    'Fleet-wide and local consumption ledgers disagree.');
            end
        end

        function out = emptySummary()
            out = struct('eligible',0,'consumed',0,'rejected',0,'distinctOwners',0, ...
                'distinctObservations',0,'rejectionsByReasonCode',struct(), ...
                'maximumRemoteProductAge_s',0);
        end

        function out = summaryOrEmpty(ledgerOrEmpty)
            if isempty(ledgerOrEmpty)
                out = revgnss.DistributedDeliveryLedger.emptySummary();
                return
            end
            if ~isa(ledgerOrEmpty,'revgnss.DistributedDeliveryLedger')
                error('DistributedDeliveryLedger:deliveryType', ...
                    'summaryOrEmpty requires a revgnss.DistributedDeliveryLedger or [].');
            end
            out = ledgerOrEmpty.summary();
        end
    end

    methods (Access = private)
        function count = countState_(obj, stateName)
            count = 0;
            for index = 1:numel(obj.order_)
                if strcmp(obj.entries_(obj.order_{index}).state,stateName)
                    count = count+1;
                end
            end
        end
    end

    methods (Static, Access = private)
        function entry = emptyEntry_()
            entry = struct( ...
                'observationIdentifier','','deliveryIdentifier','','sessionIdentifier','', ...
                'physicalRecordClass','','ownerAssetIdentifier','','ownerCanonicalIndex',NaN, ...
                'remoteAssetIdentifier','','remoteProductIdentifier','','sourceEpoch_s',NaN, ...
                'deliveryEpoch_s',NaN,'consumptionEpoch_s',NaN,'state','', ...
                'rejectionReasonCode','','rejectionReasonMessage','', ...
                'rejectionSourceErrorIdentifier','','covarianceGroupIdentifier','', ...
                'calibrationProductIdentifiers',{{}},'remoteProductAge_s',NaN, ...
                'correlationPolicy','');
        end
    end
end
