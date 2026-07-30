classdef ScientificCampaignMetrics
    % ScientificCampaignMetrics  Pure metrics for the synthetic validation campaign.

    methods (Static)

        function assessment = assessAccuracy(positionRms_m, clockBiasRms_m, criteria)
            assessment = struct( ...
                'status', 'notAssessed', ...
                'criteriaAvailable', false, ...
                'reason', '');
            if ~isfinite(positionRms_m) || ~isfinite(clockBiasRms_m)
                assessment.status = 'invalidRun';
                assessment.reason = 'Position or clock RMS is not finite.';
                return
            end

            required = {'positionRmsPassLimit_m', 'clockBiasRmsPassLimit_m'};
            if ~all(isfield(criteria, required)) || ...
                    ~all(isfinite([criteria.positionRmsPassLimit_m, ...
                                   criteria.clockBiasRmsPassLimit_m]))
                assessment.reason = 'Mission accuracy criteria are not defined.';
                return
            end
            assessment.criteriaAvailable = true;

            warningFields = {'positionRmsWarningLimit_m', ...
                'clockBiasRmsWarningLimit_m'};
            warningDefined = all(isfield(criteria, warningFields)) && ...
                all(isfinite([criteria.positionRmsWarningLimit_m, ...
                              criteria.clockBiasRmsWarningLimit_m]));
            assert(criteria.positionRmsPassLimit_m >= 0 && ...
                criteria.clockBiasRmsPassLimit_m >= 0, ...
                'ScientificCampaignMetrics:invalidAccuracyCriteria', ...
                'Accuracy limits must be nonnegative.');
            if warningDefined
                assert(criteria.positionRmsWarningLimit_m >= ...
                    criteria.positionRmsPassLimit_m && ...
                    criteria.clockBiasRmsWarningLimit_m >= ...
                    criteria.clockBiasRmsPassLimit_m, ...
                    'ScientificCampaignMetrics:invalidAccuracyCriteria', ...
                    'Warning limits must not be tighter than pass limits.');
            end

            if positionRms_m <= criteria.positionRmsPassLimit_m && ...
                    clockBiasRms_m <= criteria.clockBiasRmsPassLimit_m
                assessment.status = 'pass';
                return
            end

            if warningDefined && ...
                    positionRms_m <= criteria.positionRmsWarningLimit_m && ...
                    clockBiasRms_m <= criteria.clockBiasRmsWarningLimit_m
                assessment.status = 'warn';
                assessment.reason = 'At least one pass limit was exceeded.';
            else
                assessment.status = 'fail';
                assessment.reason = 'At least one accuracy limit was exceeded.';
            end
        end

        function summary = aggregateConsistency(rows, requiredCaseName)
            if nargin >= 2 && ~isempty(requiredCaseName)
                selected = cellfun(@(row) isfield(row, 'caseName') && ...
                    strcmp(row.caseName, requiredCaseName), rows);
                rows = rows(selected);
            end
            rows = rows(cellfun(@(row) ...
                revgnss.ScientificCampaignMetrics.isValidCampaignRow_(row), rows));
            summary = struct();
            nisFields = {'nisOverall', 'nisCode', 'nisCarrier', 'nisDoppler'};
            neesFields = {'neesPos', 'neesVel', 'neesClk', 'neesAtt'};

            for index = 1:numel(nisFields)
                summary.(nisFields{index}) = ...
                    revgnss.ScientificCampaignMetrics.aggregateGroup_( ...
                        rows, nisFields{index}, true);
            end
            for index = 1:numel(neesFields)
                summary.(neesFields{index}) = ...
                    revgnss.ScientificCampaignMetrics.aggregateGroup_( ...
                        rows, neesFields{index}, false);
            end

            summary.nisDiffAtt = struct('status', 'notAvailable');
            summary.neesCore = struct('status', ...
                revgnss.ScientificCampaignMetrics.worseConsistencyStatus_( ...
                    summary.neesPos.status, summary.neesVel.status));
            summary.independentRunCount = sum(cellfun(@(row) ...
                isfield(row, 'nisResult') && ...
                isfield(row.nisResult, 'available') && ...
                logical(row.nisResult.available), rows));
            summary.available = summary.independentRunCount > 0;
            summary.interpretation = ...
                'descriptiveAcrossIndependentRuns; notFormalChiSquare';
        end

        function summary = summarizeAmbiguityDecisions(store)
            attempted = false;
            try; attempted = logical(store.integerFixAttempted); catch; end
            nTowers = 0;
            nBaselines = 0;
            nAccepted = 0;
            try; nTowers = double(store.nTowers); catch; end
            try; nBaselines = double(store.nBaselines); catch; end
            try; nAccepted = double(store.nIntegerFixed); catch; end
            nConfiguredCandidates = max(0, nTowers * nBaselines);
            assert(nConfiguredCandidates == floor(nConfiguredCandidates) && ...
                nAccepted == floor(nAccepted) && nAccepted >= 0 && ...
                nAccepted <= nConfiguredCandidates, ...
                'ScientificCampaignMetrics:invalidAmbiguityCounts', ...
                ['Ambiguity acceptance counts must satisfy 0 <= accepted <= ' ...
                 'configured candidates.']);

            summary = struct( ...
                'status', 'notApplicableFixingDisabled', ...
                'attempted', attempted, ...
                'nConfiguredCandidates', nConfiguredCandidates, ...
                'nAccepted', 0, ...
                'acceptanceFraction', NaN, ...
                'correctnessStatus', 'notAssessedWithoutTruthComparison');
            if ~attempted
                return
            end
            if nConfiguredCandidates < 1
                summary.status = 'notAvailableNoConfiguredCandidates';
                return
            end

            summary.status = 'available';
            summary.nAccepted = nAccepted;
            summary.acceptanceFraction = ...
                summary.nAccepted / nConfiguredCandidates;
        end

        function summary = summarizeSlipDeclarations(arcEvidence, configuredEpochCount)
            declarations = 0;
            try; declarations = double(arcEvidence.nConfirmedSlips); catch; end
            configuredEpochCount = double(configuredEpochCount);
            assert(isfinite(configuredEpochCount) && configuredEpochCount >= 0 && ...
                configuredEpochCount == floor(configuredEpochCount) && ...
                isfinite(declarations) && declarations >= 0 && ...
                declarations == floor(declarations), ...
                'ScientificCampaignMetrics:invalidSlipCounts', ...
                'Slip declaration counts must be finite nonnegative integers.');
            summary = struct( ...
                'status', 'notAvailableWithoutEventAssociation', ...
                'configuredEpochCount', configuredEpochCount, ...
                'nDetectorDeclarations', declarations, ...
                'detectionProbability', NaN);
        end

        function status = summarizeStatuses(statuses)
            if isempty(statuses)
                status = 'notRun';
                return
            end
            if any(strcmp(statuses, 'invalidRun'))
                status = 'invalidRun';
            elseif any(strcmp(statuses, 'fail'))
                status = 'fail';
            elseif any(strcmp(statuses, 'warn'))
                status = 'warn';
            elseif any(strcmp(statuses, 'notAssessed'))
                status = 'notAssessed';
            elseif all(strcmp(statuses, 'pass'))
                status = 'pass';
            else
                error('ScientificCampaignMetrics:unknownStatus', ...
                    'Unknown campaign status in aggregation.');
            end
        end

    end

    methods (Static, Access = private)

        function group = aggregateGroup_(rows, field, isNis)
            reportedMeans = [];
            normalizedMeans = [];
            for index = 1:numel(rows)
                row = rows{index};
                if ~isfield(row, 'nisResult') || ...
                        ~isfield(row.nisResult, field)
                    continue
                end
                source = row.nisResult.(field);
                if ~isfield(source, 'mean') || ~isfinite(source.mean)
                    continue
                end
                if isNis
                    if ~isfield(source, 'nisPerDof') || ...
                            ~isfinite(source.nisPerDof)
                        continue
                    end
                    normalizedValue = source.nisPerDof;
                else
                    normalizedValue = source.mean;
                end
                reportedMeans(end + 1) = source.mean; %#ok<AGROW>
                normalizedMeans(end + 1) = normalizedValue; %#ok<AGROW>
            end

            group = struct( ...
                'status', 'notAvailable', ...
                'mean', NaN, ...
                'normalizedMean', NaN, ...
                'medianNormalizedMean', NaN, ...
                'nIndependentRuns', numel(normalizedMeans));
            if isempty(normalizedMeans)
                return
            end
            group.mean = mean(reportedMeans);
            group.normalizedMean = mean(normalizedMeans);
            group.medianNormalizedMean = median(normalizedMeans);
            if group.nIndependentRuns < 2
                group.status = 'insufficientIndependentRuns';
            elseif group.normalizedMean < 0.5
                group.status = 'warnLow';
            elseif group.normalizedMean > 2
                group.status = 'warnHigh';
            else
                group.status = 'pass';
            end
        end

        function valid = isValidCampaignRow_(row)
            valid = true;
            if isfield(row, 'status')
                valid = ~strcmp(row.status, 'invalidRun');
            end
        end

        function status = worseConsistencyStatus_(first, second)
            order = {'warnHigh', 'warnLow', 'insufficientIndependentRuns', ...
                'notAvailable', 'pass'};
            firstIndex = find(strcmp(order, first), 1);
            secondIndex = find(strcmp(order, second), 1);
            if isempty(firstIndex); firstIndex = 1; end
            if isempty(secondIndex); secondIndex = 1; end
            status = order{min(firstIndex, secondIndex)};
        end

    end
end
