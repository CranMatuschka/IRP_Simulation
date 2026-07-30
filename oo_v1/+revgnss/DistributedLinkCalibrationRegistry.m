classdef DistributedLinkCalibrationRegistry < handle
    % DistributedLinkCalibrationRegistry  Enforces "exactly one declared owner" for a
    % persistent link calibration/terminal-residual state (plan Section 2.1, Interface #4).
    %
    % Coordinator-owned: revgnss.IndependentFleetCoordinator holds one private instance,
    % constructed with cfg.multiAsset.distributedEstimator.linkUpdate.calibrationOwnership.policy
    % (default 'undeclared'). With the default policy every method below throws
    % :policyDisabled, so no calibration ownership can be claimed. No handle to this registry
    % is ever given to a local ReverseGNSSSimulation.

    properties (Constant)
        AllowedPolicies = {'undeclared','singleOwnerRegistry'};
    end

    properties (SetAccess = immutable)
        policyIdentifier (1,:) char
    end

    properties (Access = private)
        declarations_ containers.Map
    end

    methods
        function obj = DistributedLinkCalibrationRegistry(policyIdentifier)
            if nargin < 1; policyIdentifier = 'undeclared'; end
            if ~(ischar(policyIdentifier) || ...
                    (isstring(policyIdentifier) && isscalar(policyIdentifier))) || ...
                    ~any(strcmp(char(policyIdentifier), ...
                    revgnss.DistributedLinkCalibrationRegistry.AllowedPolicies))
                error('DistributedLinkCalibrationRegistry:policy', ...
                    'policyIdentifier must be a frozen calibration-ownership policy.');
            end
            obj.policyIdentifier = char(policyIdentifier);
            obj.declarations_ = containers.Map('KeyType','char','ValueType','any');
        end

        function declareOwner(obj, declaration)
            obj.requirePolicyEnabled_();
            if ~isa(declaration,'revgnss.DistributedLinkCalibrationState')
                error('DistributedLinkCalibrationRegistry:declarationType', ...
                    'declareOwner requires a revgnss.DistributedLinkCalibrationState.');
            end
            key = declaration.calibrationStateIdentifier;
            if isKey(obj.declarations_,key)
                existing = obj.declarations_(key);
                if isequaln(existing,declaration)
                    % NaN-tolerant: an unused field (e.g. correlationTime_s when the temporal
                    % model does not require it) legitimately carries NaN, and plain isequal
                    % treats NaN ~= NaN.
                    return
                end
                error('DistributedLinkCalibrationRegistry:duplicateOwner', ...
                    'Calibration state %s already has a different declared owner.',key);
            end
            obj.declarations_(key) = declaration;
        end

        function declaration = ownerFor(obj, calibrationStateIdentifier)
            obj.requirePolicyEnabled_();
            key = char(calibrationStateIdentifier);
            if ~isKey(obj.declarations_,key)
                error('DistributedLinkCalibrationRegistry:unknownCalibrationState', ...
                    'Calibration state %s has no declared owner.',key);
            end
            declaration = obj.declarations_(key);
        end

        function requireDeclaredOwnerFor(obj, calibrationStateIdentifiers, ownerAssetIdentifier)
            obj.requirePolicyEnabled_();
            if ~iscell(calibrationStateIdentifiers)
                error('DistributedLinkCalibrationRegistry:declarationType', ...
                    'calibrationStateIdentifiers must be a cell array of text identifiers.');
            end
            for index = 1:numel(calibrationStateIdentifiers)
                key = char(calibrationStateIdentifiers{index});
                if ~isKey(obj.declarations_,key)
                    error('DistributedLinkCalibrationRegistry:unknownCalibrationState', ...
                        'Calibration state %s has no declared owner.',key);
                end
                declaration = obj.declarations_(key);
                if strcmp(declaration.ownershipKind,'externalCalibrationProduct')
                    error('DistributedLinkCalibrationRegistry:externalProductOwnerMismatch', ...
                        'Calibration state %s is owned by an external product, not a local estimator.',key);
                end
                if ~strcmp(declaration.ownerAssetIdentifier,char(ownerAssetIdentifier))
                    error('DistributedLinkCalibrationRegistry:ownerConflict', ...
                        'Calibration state %s is declared owned by %s, not %s.',key, ...
                        declaration.ownerAssetIdentifier,char(ownerAssetIdentifier));
                end
            end
        end

        function tf = isDeclared(obj, calibrationStateIdentifier)
            obj.requirePolicyEnabled_();
            tf = isKey(obj.declarations_,char(calibrationStateIdentifier));
        end

        function count = numberDeclared(obj)
            obj.requirePolicyEnabled_();
            count = obj.declarations_.Count;
        end

        function rows = export(obj)
            obj.requirePolicyEnabled_();
            keysList = keys(obj.declarations_);
            rows = repmat(struct('calibrationStateIdentifier','','declaration',[]),1,numel(keysList));
            for index = 1:numel(keysList)
                rows(index).calibrationStateIdentifier = keysList{index};
                rows(index).declaration = obj.declarations_(keysList{index});
            end
        end
    end

    methods (Access = private)
        function requirePolicyEnabled_(obj)
            if strcmp(obj.policyIdentifier,'undeclared')
                error('DistributedLinkCalibrationRegistry:policyDisabled', ...
                    'No calibration-ownership policy is declared; every registry method is disabled.');
            end
        end
    end
end
