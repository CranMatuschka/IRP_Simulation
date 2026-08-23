classdef DistributedFleetReportingContract
    % DistributedFleetReportingContract  Plan Section 2.5 pure-compute reporting contract:
    % static-only, no state, no I/O, no truth access -- matching DistributedLinkProtocolContract/
    % SplitCovarianceIntersectionBound's own frozen contract-class idiom. Assembles the
    % per-observable/per-asset accounting the report renders, and makes the plan's own Stage-2
    % vocabulary ban ("joint," "solved formation," "centralized-equivalent") executable rather
    % than aspirational.
    %
    % This class targets ONLY revgnss.IndependentFleetDiagnosticReport / the
    % IndependentFleetCoordinator distributed-link-update path. It does not touch, extend, or
    % reference +revgnss/+report/federatedSwarmAppendix.m or ReportRunner.runFederatedSwarm_,
    % which serve a different (nSpaceAssets>1, distributedEstimator.enable=false) architecture
    % and legitimately use chief/shape-solve language for it.

    properties (Constant)
        % 'diagnosticOnlyNoLinkUpdate' -- distributedEstimator.linkUpdate.enable=false; no link
        %   update was ever attempted, matching the existing Stage-1 diagnostic-only report.
        % 'conservativeDistributedOwnerOnly' -- the sanctioned tuple is active AND at least one
        %   record was actually consumed by its owner: the report may state a conservative
        %   distributed-update claim.
        % 'linkUpdateEnabledButNoRecordConsumed' -- linkUpdate.enable=true but zero records were
        %   ever consumed (e.g. every delivery was rejected). This is NOT collapsed into either
        %   of the other two values: Section 2.3.2's own review found exactly this state by
        %   execution (generated=6, delivered=0) and it was invisible in the report at the
        %   time -- collapsing it into 'diagnosticOnlyNoLinkUpdate' would hide that link updates
        %   were attempted, and into 'conservativeDistributedOwnerOnly' would overclaim.
        AllowedDistributedResultStatuses = {'diagnosticOnlyNoLinkUpdate', ...
            'conservativeDistributedOwnerOnly','linkUpdateEnabledButNoRecordConsumed'};
        % Word-boundary patterns, matched CASE-INSENSITIVELY via regexpi (so 'JOINT'/'Joint'/
        % 'joint' all match): '(?<![A-Za-z])joint(?![A-Za-z])' matches 'joint' but not
        % 'disjoint'/'adjoint'/'jointly' as a SUBSTRING of a longer identifier -- 'jointly'
        % still matches at its own word boundary (a genuine Stage-2-forbidden usage), only a
        % same-token embedding like 'disjoint' is exempted.
        ForbiddenStageTwoTermPatterns = { ...
            '(?<![A-Za-z])joint(?![A-Za-z])', ...
            'solved\s+formation', ...
            'central(?:iz|is)ed[-\s]equivalent'};
        ForbiddenStageTwoTermNames = {'joint','solved formation','centralized-equivalent'};
    end

    methods (Static)
        function status = resultStatus(linkUpdateEnabled, correlationPolicy, ownerConsumedRecords)
            if ~linkUpdateEnabled
                status = 'diagnosticOnlyNoLinkUpdate';
                return
            end
            if ownerConsumedRecords > 0 && strcmp(correlationPolicy,'splitCovarianceIntersection')
                status = 'conservativeDistributedOwnerOnly';
                return
            end
            if ownerConsumedRecords == 0
                status = 'linkUpdateEnabledButNoRecordConsumed';
                return
            end
            error('DistributedFleetReportingContract:unclassifiableResultStatus', ...
                ['linkUpdate.enable=true, ownerConsumedRecords>0, but correlationPolicy=''%s'' ' ...
                'is not the sanctioned ''splitCovarianceIntersection'' -- this combination is ' ...
                'not reachable through IndependentFleetCoordinator.validateConfig and is refused ' ...
                'here rather than defaulted.'],char(correlationPolicy));
        end

        function provenance = fleetWideProvenance()
            % fleetWideProvenance  Plan Section 2.5 "product publication profile and
            % coordinate-time/frame/clock-datum provenance." These are FLEET-WIDE frozen
            % constants, not per-delivery facts: revgnss.CommunicationEndpointState's own
            % constructor refuses construction unless coordinateTimeScale/frameIdentifier/
            % clockDatumIdentifier/stateSchemaVersion equal these exact values, and
            % revgnss.EstimatorEligibleEndpointStateProduct's constructor refuses any
            % publicationProfile other than the frozen literal 'estimatorEligible-v1' (kept as
            % an inline literal there, not a Constant property, because that class's own
            % toStruct() enumerates properties(obj) as its export list -- a Constant property
            % would leak into every exported struct and be rejected by the constructor's own
            % fixed required-field list on any round trip) -- so every endpoint state on every
            % delivery in this architecture carries exactly these values or never existed.
            % Reporting them per-delivery would add columns that can never actually vary and
            % would falsely imply they could.
            provenance = struct( ...
                'coordinateTimeScale',revgnss.DistributedLinkProtocolContract.CoordinateTimeScale, ...
                'frameIdentifier',revgnss.DistributedLinkProtocolContract.FrameIdentifier, ...
                'clockDatumIdentifier',revgnss.DistributedLinkProtocolContract.ClockDatumIdentifier, ...
                'stateSchemaVersion',revgnss.DistributedLinkProtocolContract.StateSchemaVersion, ...
                'productPublicationProfile','estimatorEligible-v1', ...
                'remoteProductPropagationPolicy','frozenSameEpochOnly', ...
                'productAgeScope','frozenZeroSameEpochOnly', ...
                'frozenByConstruction',true);
        end

        function accounting = buildLinkAccounting(results)
            % buildLinkAccounting  Full outer join of results.linkGenerationTally (generated
            % counts, tracked in the coordinator since the ledger never sees a purely-generated
            % record) and results.linkDeliveryByObservableAndOwner (everything from first
            % ledger contact onward), keyed on (observableIdentifier, ownerAssetIdentifier).
            if ~(isstruct(results) && isfield(results,'linkGenerationTally') && ...
                    isfield(results,'linkDeliveryByObservableAndOwner') && ...
                    isfield(results,'distributedResultStatus') && ...
                    isfield(results,'distributedLinkPolicy'))
                error('DistributedFleetReportingContract:resultsSchema', ...
                    ['buildLinkAccounting requires a revgnss.IndependentFleetCoordinator.getResults() ' ...
                    'struct with linkGenerationTally/linkDeliveryByObservableAndOwner/' ...
                    'distributedResultStatus/distributedLinkPolicy.']);
            end
            tally = results.linkGenerationTally;
            groups = results.linkDeliveryByObservableAndOwner;
            rowUnitsByObservable = revgnss.DistributedLinkUpdateAdapter.RowUnitsByObservable;

            keys = {};
            rows = struct('observableIdentifier',{},'ownerAssetIdentifier',{});
            for index = 1:numel(tally)
                keys{end+1} = [tally(index).observableIdentifier '::' tally(index).ownerAssetIdentifier]; %#ok<AGROW>
            end
            for index = 1:numel(groups)
                key = [groups(index).observableIdentifier '::' groups(index).ownerAssetIdentifier];
                if ~any(strcmp(keys,key))
                    keys{end+1} = key; %#ok<AGROW>
                end
            end

            perObservableAndAsset = struct([]);
            generationTallyDelta = 0;
            for keyIndex = 1:numel(keys)
                parts = strsplit(keys{keyIndex},'::');
                observableIdentifier = parts{1};
                ownerAssetIdentifier = parts{2};

                generatedRecords = 0;
                tallyMatch = find(strcmp({tally.observableIdentifier},observableIdentifier) & ...
                    strcmp({tally.ownerAssetIdentifier},ownerAssetIdentifier),1);
                if ~isempty(tallyMatch); generatedRecords = tally(tallyMatch).generatedRecords; end

                groupMatch = find(strcmp({groups.observableIdentifier},observableIdentifier) & ...
                    strcmp({groups.ownerAssetIdentifier},ownerAssetIdentifier),1);
                if isempty(groupMatch)
                    group = revgnss.DistributedDeliveryLedger.finalizeObservableOwnerGroup( ...
                        revgnss.DistributedDeliveryLedger.emptyObservableOwnerGroup( ...
                        observableIdentifier,ownerAssetIdentifier));
                else
                    group = groups(groupMatch);
                end

                row = group;
                row.generatedRecords = generatedRecords;
                row.observableRowUnits = '';
                if isfield(rowUnitsByObservable,observableIdentifier)
                    row.observableRowUnits = rowUnitsByObservable.(observableIdentifier);
                end
                row.unitsMatchContract = isempty(group.processedUnits) || ...
                    (numel(group.processedUnits) == 1 && ...
                    strcmp(group.processedUnits{1},row.observableRowUnits));
                row.accountingBalanced = ...
                    generatedRecords == (row.deliveredRecords+row.rejectedBeforeDeliveryRecords) && ...
                    row.deliveredRecords == (row.ownerConsumedRecords+row.rejectedAfterDeliveryRecords+ ...
                    row.eligibleNotConsumedRecords);
                generationTallyDelta = generationTallyDelta + ...
                    abs(generatedRecords-(row.deliveredRecords+row.rejectedBeforeDeliveryRecords));

                if isempty(perObservableAndAsset)
                    perObservableAndAsset = row;
                else
                    perObservableAndAsset(end+1) = row; %#ok<AGROW>
                end
            end

            accounting = struct( ...
                'architectureLabel',results.architectureLabel, ...
                'nAssets',results.N, ...
                'distributedResultStatus',results.distributedResultStatus, ...
                'deliveryLedgerEnabled',results.distributedLinkPolicy.deliveryLedgerEnabled, ...
                'perObservableAndAsset',perObservableAndAsset, ...
                'perObservable',revgnss.DistributedFleetReportingContract.rollUpByObservable( ...
                    perObservableAndAsset), ...
                'fleetWideProvenance',revgnss.DistributedFleetReportingContract.fleetWideProvenance(), ...
                'linkPolicy',results.distributedLinkPolicy, ...
                'generationTallyReconciled',generationTallyDelta == 0, ...
                'generationTallyDelta',generationTallyDelta);
        end

        function rows = rollUpByObservable(perObservableAndAsset)
            % rollUpByObservable  Sums the per-asset rows to one row per observable, for a
            % compact top-of-section summary above the full per-asset table.
            rows = struct('observableIdentifier',{},'generatedRecords',{},'deliveredRecords',{}, ...
                'ownerConsumedRecords',{},'rejectedRecords',{});
            if isempty(perObservableAndAsset); return; end
            observableIds = unique({perObservableAndAsset.observableIdentifier},'stable');
            for index = 1:numel(observableIds)
                mask = strcmp({perObservableAndAsset.observableIdentifier},observableIds{index});
                subset = perObservableAndAsset(mask);
                rows(index) = struct( ...
                    'observableIdentifier',observableIds{index}, ...
                    'generatedRecords',sum([subset.generatedRecords]), ...
                    'deliveredRecords',sum([subset.deliveredRecords]), ...
                    'ownerConsumedRecords',sum([subset.ownerConsumedRecords]), ...
                    'rejectedRecords',sum([subset.rejectedRecords]));
            end
        end

        function requireNoForbiddenStageTwoTerm(text)
            % requireNoForbiddenStageTwoTerm  Checked case-insensitively (regexpi), so an
            % all-caps heading cannot slip past. Lines containing \includegraphics are excluded
            % before matching: a report filename/stem is a config-derived value (e.g. built from
            % multiAsset.mode, which legitimately takes the value 'joint' elsewhere in this
            % codebase for the UNRELATED joint/centralized architecture) and is not this class's
            % own authored prose -- checking it would make an incidental filename collision
            % throw and silently drop the entire report (ReportRunner's own catch), which is a
            % worse failure than the one this check exists to prevent.
            text = char(text);
            lines = strsplit(text,newline);
            lines = lines(~contains(lines,'\includegraphics'));
            text = strjoin(lines,newline);
            patterns = revgnss.DistributedFleetReportingContract.ForbiddenStageTwoTermPatterns;
            names = revgnss.DistributedFleetReportingContract.ForbiddenStageTwoTermNames;
            for index = 1:numel(patterns)
                if ~isempty(regexpi(text,patterns{index},'once'))
                    error('DistributedFleetReportingContract:forbiddenStageTwoTerm', ...
                        ['Stage-2 report text contains the forbidden term ''%s''; the plan ' ...
                        'explicitly bans "joint," "solved formation," and "centralized-' ...
                        'equivalent" for Stage 2.'],names{index});
                end
            end
        end
    end
end
