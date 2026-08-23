classdef CommonSourceCovarianceRegistry < handle
    % CommonSourceCovarianceRegistry  Lookup for revgnss.CommonSourceCovarianceGroup
    % declarations (plan Section 2.2 bullet 5), structurally a twin of
    % revgnss.DistributedLinkCalibrationRegistry including its default-disabled guard: the
    % default policy 'undeclared' makes every method throw :policyDisabled, so the registry is
    % inert by construction and needs no masterConfig key. Constructed only in tests today
    % (plan Section 2.2 scope: no coordinator ownership, no reachability from a live run).
    %
    % contributionsFor deliberately has no summing accessor: revision 1 of this design folded
    % multiple declared blocks additively into one remote-contribution term, which
    % SplitCovarianceIntersectionBound's worked counterexample (class header, and the B1
    % regression test in tests/test_stage2_conservative_correlation_policy.m) shows under-
    % reports the true second moment by a factor up to n. A method named
    % ':summedContributionUnavailable' will never exist here.

    properties (Constant)
        AllowedPolicies = {'undeclared','declaredGroupRegistry'};
    end

    properties (SetAccess = immutable)
        policyIdentifier (1,:) char
    end

    properties (Access = private)
        groups_ containers.Map
        byObservation_ containers.Map
    end

    methods
        function obj = CommonSourceCovarianceRegistry(policyIdentifier)
            if nargin < 1; policyIdentifier = 'undeclared'; end
            if ~(ischar(policyIdentifier) || (isstring(policyIdentifier) && isscalar(policyIdentifier))) || ...
                    ~any(strcmp(char(policyIdentifier),revgnss.CommonSourceCovarianceRegistry.AllowedPolicies))
                error('CommonSourceCovarianceRegistry:policy', ...
                    'policyIdentifier must be a frozen common-source-covariance-registry policy.');
            end
            obj.policyIdentifier = char(policyIdentifier);
            obj.groups_ = containers.Map('KeyType','char','ValueType','any');
            obj.byObservation_ = containers.Map('KeyType','char','ValueType','any');
        end

        function declareGroup(obj, group)
            obj.requirePolicyEnabled_();
            if ~isa(group,'revgnss.CommonSourceCovarianceGroup')
                error('CommonSourceCovarianceRegistry:groupType', ...
                    'declareGroup requires a revgnss.CommonSourceCovarianceGroup.');
            end
            key = group.covarianceGroupIdentifier;
            if isKey(obj.groups_,key)
                existing = obj.groups_(key);
                if isequaln(existing,group)
                    return
                end
                error('CommonSourceCovarianceRegistry:duplicateGroup', ...
                    'Covariance group %s already has a different declaration.',key);
            end
            obj.groups_(key) = group;
            for index = 1:numel(group.memberObservationIdentifiers)
                obsId = char(group.memberObservationIdentifiers{index});
                if isKey(obj.byObservation_,obsId)
                    list = obj.byObservation_(obsId);
                else
                    list = {};
                end
                if ~any(strcmp(list,key))
                    list{end+1} = key; %#ok<AGROW>
                end
                obj.byObservation_(obsId) = list;
            end
        end

        function groups = groupsForObservation(obj, observationIdentifier)
            obj.requirePolicyEnabled_();
            key = char(observationIdentifier);
            groups = revgnss.CommonSourceCovarianceGroup.empty(1,0);
            if ~isKey(obj.byObservation_,key)
                return
            end
            ids = obj.byObservation_(key);
            for index = 1:numel(ids)
                groups(end+1) = obj.groups_(ids{index}); %#ok<AGROW>
            end
        end

        function contributions = contributionsFor(obj, observationIdentifier)
            obj.requirePolicyEnabled_();
            groups = obj.groupsForObservation(observationIdentifier);
            contributions = struct('covarianceGroupIdentifier',{},'commonSourceName',{}, ...
                'contribution_m2',{},'sourceProductIdentifier',{});
            for index = 1:numel(groups)
                g = groups(index);
                contributions(end+1) = struct( ...
                    'covarianceGroupIdentifier',g.covarianceGroupIdentifier, ...
                    'commonSourceName',g.commonSourceName, ...
                    'contribution_m2',g.sharedCovarianceContribution_m2, ...
                    'sourceProductIdentifier',g.sourceProductIdentifier); %#ok<AGROW>
            end
            contributions = reshape(contributions,1,numel(contributions));
        end

        function requireEveryDeclaredSourceTreated(obj, commonSourceTreatment)
            obj.requirePolicyEnabled_();
            keysList = keys(obj.groups_);
            for index = 1:numel(keysList)
                g = obj.groups_(keysList{index});
                if numel(g.memberObservationIdentifiers) < 2
                    continue
                end
                if ~isfield(commonSourceTreatment,g.commonSourceName)
                    error('CommonSourceCovarianceRegistry:untreatedCommonSource', ...
                        'commonSourceTreatment has no entry for declared source %s.',g.commonSourceName);
                end
                value = char(commonSourceTreatment.(g.commonSourceName));
                if strcmp(value,'estimatedOwnerState')
                    error('CommonSourceCovarianceRegistry:ownerEstimatedTreatmentSchemaUnavailable', ...
                        ['treatment ''estimatedOwnerState'' is not expressible in the frozen v1 ' ...
                        'state/covariance schema.']);
                end
                if strcmp(value,'rejected')
                    error('CommonSourceCovarianceRegistry:untreatedCommonSource', ...
                        'Declared shared source %s (>=2 members) cannot be treated as ''rejected''.', ...
                        g.commonSourceName);
                end
            end
        end

        function requireConsistentRowCount(obj, observationIdentifier)
            obj.requirePolicyEnabled_();
            groups = obj.groupsForObservation(observationIdentifier);
            if isempty(groups); return; end
            counts = arrayfun(@(g) g.memberRowCount,groups);
            if numel(unique(counts)) > 1
                error('CommonSourceCovarianceRegistry:memberDimensionMismatch', ...
                    'Declared groups for %s disagree on memberRowCount.',char(observationIdentifier));
            end
        end

        function tf = isDeclared(obj, covarianceGroupIdentifier)
            obj.requirePolicyEnabled_();
            tf = isKey(obj.groups_,char(covarianceGroupIdentifier));
        end

        function count = numberDeclared(obj)
            obj.requirePolicyEnabled_();
            count = obj.groups_.Count;
        end

        function rows = export(obj)
            obj.requirePolicyEnabled_();
            keysList = keys(obj.groups_);
            rows = repmat(struct('covarianceGroupIdentifier','','group',[]),1,numel(keysList));
            for index = 1:numel(keysList)
                rows(index).covarianceGroupIdentifier = keysList{index};
                rows(index).group = obj.groups_(keysList{index});
            end
        end
    end

    methods (Access = private)
        function requirePolicyEnabled_(obj)
            if strcmp(obj.policyIdentifier,'undeclared')
                error('CommonSourceCovarianceRegistry:policyDisabled', ...
                    'No common-source-covariance-registry policy is declared; every method is disabled.');
            end
        end
    end
end
