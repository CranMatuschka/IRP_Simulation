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
        % Plan Section 2.5: how a ledger entry's ownerAssetIdentifier/remoteAssetIdentifier were
        % determined. 'canonicalReconciledOwner' -- a real revgnss.LinkObservationDelivery
        % existed and CanonicalEndpointIdentity.requireReconciled already proved the label.
        % 'recordDeclaredEndpointLabel' -- no delivery exists yet (rejected before propose()
        % succeeded); the label is read directly from the physical record via the SAME
        % LinkObservationDelivery.ownerRemoteEndpointFieldsFor mapping propose() itself uses,
        % but is NOT cross-reconciled against a canonical product identity. 'unattributed' --
        % the record class/ownerPolicy pairing has no defined mapping at all (fail-soft
        % sentinel, never a thrown error, on the rejection path).
        AllowedOwnerAttributionSources = { ...
            'canonicalReconciledOwner','recordDeclaredEndpointLabel','unattributed'};
        UnattributedAssetIdentifier = 'asset:unattributed';
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
                'correlationPolicy',delivery.correlationPolicy, ...
                'observableIdentifier',delivery.observableIdentifier, ...
                'processedObservableType',delivery.processedObservableType, ...
                'processedUnits',delivery.processedUnits, ...
                'wasDeliveredToOwner',true, ...
                'ownerAttributionSource','canonicalReconciledOwner', ...
                'remoteStateProvenance',delivery.remoteStateProvenance, ...
                'clockClaim',delivery.clockClaim, ...
                'pairAbsolutelyAnchored',delivery.pairAbsolutelyAnchored, ...
                'pairAnchorDatumIdentifier',delivery.pairAnchorDatumIdentifier, ...
                'calibrationStateIdentifiers',{delivery.calibrationStateIdentifiers}, ...
                'correlationNetworkRoute','','correlationNetworkRouteReasonCode','', ...
                'remoteEndpointCorrectionApplied',false,'remoteEndpointIdentifier','', ...
                'synchronizedMessageIdentifier','','synchronizedMessageSignature_hex','');
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

        function recordSynchronizedPairConsumption(obj, record)
            % recordSynchronizedPairConsumption  Section 3.2's counterpart to recordConsumed +
            % recordCorrelationNetworkRoute, called ONCE by
            % revgnss.SynchronizedPairLinkUpdateTransaction.commitAcknowledgedPairUpdate's step
            % C4, after BOTH endpoint corrections have already been committed (never before --
            % this is the fleet-wide ledger's own record of an already-applied synchronized
            % update, not a gate that could still refuse it). remoteAssetIdentifier is read from
            % correctionMessage.remoteEndpointCorrection rather than requiring a redundant
            % caller-supplied field that could disagree with the message it is meant to describe.
            required = {'observationIdentifier','ownerAssetIdentifier','updateEpoch_s', ...
                'correctionMessage','ownerAcknowledgement','remoteAcknowledgement', ...
                'correlationNetworkRoute','correlationNetworkRouteReasonCode'};
            missing = setdiff(required,fieldnames(record));
            if ~isempty(missing)
                error('DistributedDeliveryLedger:synchronizedPairConsumptionSchema', ...
                    'recordSynchronizedPairConsumption is missing %s.',missing{1});
            end
            if ~isa(record.correctionMessage,'revgnss.SynchronizedPairCorrectionMessage')
                error('DistributedDeliveryLedger:synchronizedPairConsumptionMessageType', ...
                    'correctionMessage must be a revgnss.SynchronizedPairCorrectionMessage.');
            end
            if ~(isa(record.ownerAcknowledgement,'revgnss.EndpointCorrectionAcknowledgement') && ...
                    record.ownerAcknowledgement.accepted && ...
                    isa(record.remoteAcknowledgement,'revgnss.EndpointCorrectionAcknowledgement') && ...
                    record.remoteAcknowledgement.accepted)
                error('DistributedDeliveryLedger:synchronizedPairConsumptionNotAcknowledged', ...
                    'recordSynchronizedPairConsumption requires both endpoint acknowledgements accepted.');
            end
            % Bind each acknowledgement to THIS correction message (not just "some accepted
            % acknowledgement object") before writing its endpoint/message identifiers into the
            % permanent audit row -- mirrors revgnss.LocalEndpointCorrectionReceiver.
            % commitAcknowledgedCorrection's own binding check.
            msg = record.correctionMessage;
            if ~(strcmp(record.ownerAcknowledgement.messageIdentifier,msg.messageIdentifier) && ...
                    strcmp(record.ownerAcknowledgement.messageSignature_hex,msg.messageSignature_hex) && ...
                    strcmp(record.ownerAcknowledgement.endpointIdentifier, ...
                    msg.ownerEndpointCorrection.endpointIdentifier))
                error('DistributedDeliveryLedger:synchronizedPairConsumptionOwnerAckNotBound', ...
                    'ownerAcknowledgement is not bound to correctionMessage''s owner endpoint.');
            end
            if ~(strcmp(record.remoteAcknowledgement.messageIdentifier,msg.messageIdentifier) && ...
                    strcmp(record.remoteAcknowledgement.messageSignature_hex,msg.messageSignature_hex) && ...
                    strcmp(record.remoteAcknowledgement.endpointIdentifier, ...
                    msg.remoteEndpointCorrection.endpointIdentifier))
                error('DistributedDeliveryLedger:synchronizedPairConsumptionRemoteAckNotBound', ...
                    'remoteAcknowledgement is not bound to correctionMessage''s remote endpoint.');
            end
            identifier = char(record.observationIdentifier);
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
            if ~strcmp(entry.ownerAssetIdentifier,char(record.ownerAssetIdentifier))
                error('DistributedDeliveryLedger:ownerMismatch', ...
                    'Observation %s may be consumed only by its recorded owner %s.', ...
                    identifier,entry.ownerAssetIdentifier);
            end
            if entry.deliveryEpoch_s ~= record.updateEpoch_s
                error('DistributedDeliveryLedger:epochMismatch', ...
                    'Observation %s must be consumed at its recorded delivery epoch.',identifier);
            end
            if ~any(strcmp(char(record.correlationNetworkRoute), ...
                    revgnss.DistributedCovarianceNetworkContract.AllowedLinkUpdateRoutes))
                error('DistributedDeliveryLedger:correlationNetworkRoute', ...
                    'correlationNetworkRoute must be one of the frozen AllowedLinkUpdateRoutes.');
            end
            if ~any(strcmp(char(record.correlationNetworkRouteReasonCode), ...
                    revgnss.DistributedCovarianceNetworkContract.AllowedRouteReasonCodes))
                error('DistributedDeliveryLedger:correlationNetworkRouteReasonCode', ...
                    'correlationNetworkRouteReasonCode must be one of the frozen AllowedRouteReasonCodes.');
            end
            entry.state = 'consumed';
            entry.consumptionEpoch_s = double(record.updateEpoch_s);
            entry.correlationNetworkRoute = char(record.correlationNetworkRoute);
            entry.correlationNetworkRouteReasonCode = char(record.correlationNetworkRouteReasonCode);
            entry.remoteEndpointCorrectionApplied = true;
            entry.remoteEndpointIdentifier = record.correctionMessage.remoteEndpointCorrection.endpointIdentifier;
            entry.synchronizedMessageIdentifier = record.correctionMessage.messageIdentifier;
            entry.synchronizedMessageSignature_hex = record.correctionMessage.messageSignature_hex;
            obj.entries_(identifier) = entry;
        end

        function recordCorrelationNetworkRoute(obj, observationIdentifier, route, reasonCode)
            % recordCorrelationNetworkRoute  Plan Stage 3.1: mutates an EXISTING eligible/
            % consumed entry with the routing decision (revgnss.DistributedCovarianceNetwork.
            % routeForDelivery), computed in phase 5 -- after recordEligible already created the
            % entry in phase 4 -- so this cannot be a recordEligible field.
            identifier = char(observationIdentifier);
            if ~isKey(obj.entries_,identifier)
                error('DistributedDeliveryLedger:unknownObservation', ...
                    'Observation %s has no fleet-wide delivery ledger entry.',identifier);
            end
            if ~any(strcmp(char(route),revgnss.DistributedCovarianceNetworkContract.AllowedLinkUpdateRoutes))
                error('DistributedDeliveryLedger:correlationNetworkRoute', ...
                    'route must be one of the frozen AllowedLinkUpdateRoutes.');
            end
            if ~any(strcmp(char(reasonCode), ...
                    revgnss.DistributedCovarianceNetworkContract.AllowedRouteReasonCodes))
                error('DistributedDeliveryLedger:correlationNetworkRouteReasonCode', ...
                    'reasonCode must be one of the frozen AllowedRouteReasonCodes.');
            end
            entry = obj.entries_(identifier);
            entry.correlationNetworkRoute = char(route);
            entry.correlationNetworkRouteReasonCode = char(reasonCode);
            obj.entries_(identifier) = entry;
        end

        function recordRejected(obj, rejectionRecord)
            required = {'observationIdentifier','ownerAssetIdentifier', ...
                'remoteProductIdentifier','sourceEpoch_s','deliveryEpoch_s','reasonCode', ...
                'reasonMessage','sourceErrorIdentifier','physicalRecordClass', ...
                'observableIdentifier','processedObservableType','processedUnits', ...
                'ownerAttributionSource','remoteAssetIdentifier'};
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
            if isempty(char(rejectionRecord.observableIdentifier))
                error('DistributedDeliveryLedger:reasonCode', ...
                    'recordRejected requires a non-empty observableIdentifier.');
            end
            attributionSource = char(rejectionRecord.ownerAttributionSource);
            if ~any(strcmp(attributionSource, ...
                    revgnss.DistributedDeliveryLedger.AllowedOwnerAttributionSources))
                error('DistributedDeliveryLedger:reasonCode', ...
                    'recordRejected ownerAttributionSource must be a frozen allowed source.');
            end
            entry = struct( ...
                'observationIdentifier',identifier, ...
                'deliveryIdentifier','', ...
                'sessionIdentifier','', ...
                'physicalRecordClass',char(rejectionRecord.physicalRecordClass), ...
                'ownerAssetIdentifier',char(rejectionRecord.ownerAssetIdentifier), ...
                'ownerCanonicalIndex',NaN, ...
                'remoteAssetIdentifier',char(rejectionRecord.remoteAssetIdentifier), ...
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
                'correlationPolicy','', ...
                'observableIdentifier',char(rejectionRecord.observableIdentifier), ...
                'processedObservableType',char(rejectionRecord.processedObservableType), ...
                'processedUnits',char(rejectionRecord.processedUnits), ...
                'wasDeliveredToOwner',false, ...
                'ownerAttributionSource',attributionSource, ...
                'remoteStateProvenance','', ...
                'clockClaim','', ...
                'pairAbsolutelyAnchored',false, ...
                'pairAnchorDatumIdentifier','', ...
                'calibrationStateIdentifiers',{{}}, ...
                'correlationNetworkRoute','','correlationNetworkRouteReasonCode','', ...
                'remoteEndpointCorrectionApplied',false,'remoteEndpointIdentifier','', ...
                'synchronizedMessageIdentifier','','synchronizedMessageSignature_hex','');
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

        function groups = summaryByObservableAndOwner(obj)
            % summaryByObservableAndOwner  Plan Section 2.5: "for each observable type and
            % asset" accounting. One element per distinct (observableIdentifier,
            % ownerAssetIdentifier) pair, in first-appearance order (deterministic report
            % ordering). Deliberately a SEPARATE method from summary() -- summary()/
            % emptySummary() stay byte-identical (tests/test_stage2_communication_interfaces.m
            % asserts isequal(emptySummary(),...) on the disabled path).
            rows = obj.export();
            keys = {};
            working = {}; % cell array of working structs (carries the internal sawDeliveredRow_
                           % accumulator field finalizeObservableOwnerGroup strips) -- kept OUT of the struct
                           % array itself until finalized, since a MATLAB struct array requires
                           % every element to share one field set, and the public
                           % emptyObservableOwnerSummary() shape must never carry that field.
            for index = 1:numel(rows)
                entry = rows(index);
                if entry.wasDeliveredToOwner ~= ~isempty(entry.deliveryIdentifier)
                    error('DistributedDeliveryLedger:deliveryFlagInconsistent', ...
                        'Observation %s has wasDeliveredToOwner inconsistent with deliveryIdentifier.', ...
                        entry.observationIdentifier);
                end
                key = [entry.observableIdentifier '::' entry.ownerAssetIdentifier];
                groupIndex = find(strcmp(keys,key),1);
                if isempty(groupIndex)
                    keys{end+1} = key; %#ok<AGROW>
                    groupIndex = numel(keys);
                    working{groupIndex} = revgnss.DistributedDeliveryLedger.emptyObservableOwnerGroup( ...
                        entry.observableIdentifier,entry.ownerAssetIdentifier); %#ok<AGROW>
                end
                working{groupIndex} = revgnss.DistributedDeliveryLedger.foldEntryIntoGroup_( ...
                    working{groupIndex},entry);
            end
            if isempty(working)
                groups = revgnss.DistributedDeliveryLedger.emptyObservableOwnerSummary();
                return
            end
            groups = revgnss.DistributedDeliveryLedger.emptyObservableOwnerSummary();
            for groupIndex = 1:numel(working)
                groups(groupIndex) = revgnss.DistributedDeliveryLedger.finalizeObservableOwnerGroup(working{groupIndex});
            end
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

        function groups = emptyObservableOwnerSummary()
            % emptyObservableOwnerSummary  The 1x0 shape summaryByObservableAndOwner returns
            % when the ledger has no entries; also the frozen field-name contract a caller can
            % compare fieldnames(...) against.
            groups = struct( ...
                'observableIdentifier',{},'ownerAssetIdentifier',{}, ...
                'ledgerRecords',{},'deliveredRecords',{},'ownerConsumedRecords',{}, ...
                'eligibleNotConsumedRecords',{},'rejectedRecords',{}, ...
                'rejectedBeforeDeliveryRecords',{},'rejectedAfterDeliveryRecords',{}, ...
                'rejectionReasonCodes',{},'rejectionReasonCounts',{}, ...
                'rejectionsByReasonCode',{}, ...
                'minimumRemoteProductAge_s',{},'maximumRemoteProductAge_s',{}, ...
                'processedObservableTypes',{},'processedUnits',{}, ...
                'physicalRecordClasses',{},'ownerAttributionSources',{}, ...
                'remoteAssetIdentifiers',{},'correlationPolicies',{}, ...
                'covarianceGroupIdentifiers',{},'calibrationProductIdentifiers',{}, ...
                'calibrationStateIdentifiers',{},'remoteStateProvenanceKinds',{}, ...
                'clockClaims',{},'pairAnchorDatumIdentifiers',{}, ...
                'allDeliveredPairsAbsolutelyAnchored',{});
        end

        function groups = summaryByObservableAndOwnerOrEmpty(ledgerOrEmpty)
            if isempty(ledgerOrEmpty)
                groups = revgnss.DistributedDeliveryLedger.emptyObservableOwnerSummary();
                return
            end
            if ~isa(ledgerOrEmpty,'revgnss.DistributedDeliveryLedger')
                error('DistributedDeliveryLedger:deliveryType', ...
                    'summaryByObservableAndOwnerOrEmpty requires a revgnss.DistributedDeliveryLedger or [].');
            end
            groups = ledgerOrEmpty.summaryByObservableAndOwner();
        end

        function group = emptyObservableOwnerGroup(observableIdentifier, ownerAssetIdentifier)
            % emptyObservableOwnerGroup  Public (plan Section 2.5): a zero-count group row for
            % one (observableIdentifier, ownerAssetIdentifier) key, with no ledger entries yet
            % folded in. Used internally by summaryByObservableAndOwner and externally by
            % revgnss.DistributedFleetReportingContract.buildLinkAccounting to represent a key
            % that was GENERATED but never reached the ledger at all (every proposal for it
            % failed before revgnss.LinkObservationDelivery.tryPropose even returned, an
            % occurrence this class's own recordRejected/recordEligible always intercepts in
            % practice, but the report layer must not assume that).
            group = struct( ...
                'observableIdentifier',char(observableIdentifier), ...
                'ownerAssetIdentifier',char(ownerAssetIdentifier), ...
                'ledgerRecords',0,'deliveredRecords',0,'ownerConsumedRecords',0, ...
                'eligibleNotConsumedRecords',0,'rejectedRecords',0, ...
                'rejectedBeforeDeliveryRecords',0,'rejectedAfterDeliveryRecords',0, ...
                'rejectionReasonCodes',{{}},'rejectionReasonCounts',[], ...
                'rejectionsByReasonCode',struct(), ...
                'minimumRemoteProductAge_s',NaN,'maximumRemoteProductAge_s',NaN, ...
                'processedObservableTypes',{{}},'processedUnits',{{}}, ...
                'physicalRecordClasses',{{}},'ownerAttributionSources',{{}}, ...
                'remoteAssetIdentifiers',{{}},'correlationPolicies',{{}}, ...
                'covarianceGroupIdentifiers',{{}},'calibrationProductIdentifiers',{{}}, ...
                'calibrationStateIdentifiers',{{}},'remoteStateProvenanceKinds',{{}}, ...
                'clockClaims',{{}},'pairAnchorDatumIdentifiers',{{}}, ...
                'allDeliveredPairsAbsolutelyAnchored',true);
            group.sawDeliveredRow_ = false; %#ok<STRNU> temporary accumulator field, stripped by finalizeObservableOwnerGroup
        end

        function group = finalizeObservableOwnerGroup(group)
            % finalizeObservableOwnerGroup  Public (plan Section 2.5) counterpart to
            % emptyObservableOwnerGroup: strips the internal sawDeliveredRow_ accumulator field
            % and computes the makeValidName-keyed rejectionsByReasonCode struct, matching
            % summary()'s own established idiom.
            if ~group.sawDeliveredRow_
                group.allDeliveredPairsAbsolutelyAnchored = false;
            end
            group = rmfield(group,'sawDeliveredRow_');
            reasonStruct = struct();
            for index = 1:numel(group.rejectionReasonCodes)
                reasonStruct.(matlab.lang.makeValidName(group.rejectionReasonCodes{index})) = ...
                    group.rejectionReasonCounts(index);
            end
            group.rejectionsByReasonCode = reasonStruct;
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
                'correlationPolicy','', ...
                'observableIdentifier','','processedObservableType','','processedUnits','', ...
                'wasDeliveredToOwner',false,'ownerAttributionSource','', ...
                'remoteStateProvenance','','clockClaim','','pairAbsolutelyAnchored',false, ...
                'pairAnchorDatumIdentifier','','calibrationStateIdentifiers',{{}}, ...
                'correlationNetworkRoute','','correlationNetworkRouteReasonCode','', ...
                'remoteEndpointCorrectionApplied',false,'remoteEndpointIdentifier','', ...
                'synchronizedMessageIdentifier','','synchronizedMessageSignature_hex','');
        end

        function group = foldEntryIntoGroup_(group, entry)
            addUnique_ = @(cellList,value) revgnss.DistributedDeliveryLedger.addUnique_(cellList,value);
            group.ledgerRecords = group.ledgerRecords+1;
            group.processedObservableTypes = addUnique_(group.processedObservableTypes,entry.processedObservableType);
            group.processedUnits = addUnique_(group.processedUnits,entry.processedUnits);
            group.physicalRecordClasses = addUnique_(group.physicalRecordClasses,entry.physicalRecordClass);
            group.ownerAttributionSources = addUnique_(group.ownerAttributionSources,entry.ownerAttributionSource);
            group.remoteAssetIdentifiers = addUnique_(group.remoteAssetIdentifiers,entry.remoteAssetIdentifier);

            if entry.wasDeliveredToOwner
                group.deliveredRecords = group.deliveredRecords+1;
                group.sawDeliveredRow_ = true;
                if ~isnan(entry.remoteProductAge_s)
                    if isnan(group.minimumRemoteProductAge_s) || entry.remoteProductAge_s < group.minimumRemoteProductAge_s
                        group.minimumRemoteProductAge_s = entry.remoteProductAge_s;
                    end
                    if isnan(group.maximumRemoteProductAge_s) || entry.remoteProductAge_s > group.maximumRemoteProductAge_s
                        group.maximumRemoteProductAge_s = entry.remoteProductAge_s;
                    end
                end
                group.correlationPolicies = addUnique_(group.correlationPolicies,entry.correlationPolicy);
                group.covarianceGroupIdentifiers = addUnique_( ...
                    group.covarianceGroupIdentifiers,entry.covarianceGroupIdentifier);
                for calibIndex = 1:numel(entry.calibrationProductIdentifiers)
                    group.calibrationProductIdentifiers = addUnique_( ...
                        group.calibrationProductIdentifiers,entry.calibrationProductIdentifiers{calibIndex});
                end
                for calibIndex = 1:numel(entry.calibrationStateIdentifiers)
                    group.calibrationStateIdentifiers = addUnique_( ...
                        group.calibrationStateIdentifiers,entry.calibrationStateIdentifiers{calibIndex});
                end
                group.remoteStateProvenanceKinds = addUnique_( ...
                    group.remoteStateProvenanceKinds,entry.remoteStateProvenance);
                group.clockClaims = addUnique_(group.clockClaims,entry.clockClaim);
                group.pairAnchorDatumIdentifiers = addUnique_( ...
                    group.pairAnchorDatumIdentifiers,entry.pairAnchorDatumIdentifier);
                group.allDeliveredPairsAbsolutelyAnchored = ...
                    group.allDeliveredPairsAbsolutelyAnchored && entry.pairAbsolutelyAnchored;
            end

            switch entry.state
                case 'consumed'
                    group.ownerConsumedRecords = group.ownerConsumedRecords+1;
                case 'eligible'
                    group.eligibleNotConsumedRecords = group.eligibleNotConsumedRecords+1;
                case 'rejected'
                    group.rejectedRecords = group.rejectedRecords+1;
                    if entry.wasDeliveredToOwner
                        group.rejectedAfterDeliveryRecords = group.rejectedAfterDeliveryRecords+1;
                    else
                        group.rejectedBeforeDeliveryRecords = group.rejectedBeforeDeliveryRecords+1;
                    end
                    codeIndex = find(strcmp(group.rejectionReasonCodes,entry.rejectionReasonCode),1);
                    if isempty(codeIndex)
                        group.rejectionReasonCodes{end+1} = entry.rejectionReasonCode;
                        group.rejectionReasonCounts(end+1) = 1;
                    else
                        group.rejectionReasonCounts(codeIndex) = group.rejectionReasonCounts(codeIndex)+1;
                    end
            end
        end

        function cellList = addUnique_(cellList, value)
            if isempty(value) || any(strcmp(cellList,value)); return; end
            cellList{end+1} = value;
        end
    end
end
