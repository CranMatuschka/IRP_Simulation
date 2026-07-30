classdef DistributedLinkUpdateBlock
    % DistributedLinkUpdateBlock  Validated container a revgnss.DistributedLinkUpdateAdapter
    % must produce (plan Section 2.1, Interface #3). Contains NO physics: no equation computes
    % a residual, Jacobian, or covariance anywhere in this file. It is a shape/validation gate.
    %
    % Why independentMeasurementCovariance_m2 and remoteContributionCovariance_m2 are separate
    % immutable fields, and no pre-summed residual-covariance field exists: plan Section 2.2.2
    % states that "merely adding H_j*P_j*H_j^T to measurement R while retaining the uninflated
    % local prior is not a proof of conservativeness." A block that could carry a pre-summed
    % residual covariance would make that shortcut expressible; here it is not expressible.
    % residualCovarianceAssembly's Section 2.1 value asserted that no assembly happened at all;
    % Section 2.2 adds exactly one new legal value,
    % 'notAssembledInputsEligibleForSplitCovarianceIntersection', whose name asserts that no
    % assembly STILL happens inside this block -- the assembly is performed OUTSIDE it, by
    % revgnss.SplitCovarianceIntersectionBound, which returns a revgnss.OwnerPosteriorBoundResult
    % this block neither carries nor could carry (there is no field it could occupy). No summed
    % covariance field name (e.g. combinedRemoteAndCommonCovariance_m2) may ever be added here:
    % additively folding a declared common source or calibration term into
    % remoteContributionCovariance_m2 is provably NOT an upper bound (a factor-of-2
    % counterexample is in SplitCovarianceIntersectionBound's class header and the B1 regression
    % test in tests/test_stage2_conservative_correlation_policy.m).
    %
    % Section 2.2's new fields draw from TWO DELIBERATELY DIFFERENT FROZEN VOCABULARIES, spelled
    % inversely of each other -- stated here so a future reader does not conflate them:
    %   persistentCalibrationTreatment draws from DistributedLinkCalibrationState.
    %     AllowedOwnershipKinds ('ownerEstimatedState','externalCalibrationProduct'), NOT from
    %     DistributedLinkProtocolContract.AllowedCommonSourceTreatments
    %     ('estimatedOwnerState',...). 'ownerEstimatedState' (the calibration-state spelling) is
    %     refused BY NAME below with the frozen v1-schema reason (matching
    %     CommonSourceCovarianceGroup's identical refusal); 'estimatedOwnerState' (the protocol-
    %     contract spelling) is simply not a member of AllowedPersistentCalibrationTreatments and
    %     keeps failing the generic :persistentCalibrationTreatment check -- that is correct, it
    %     is the wrong word for this field, not a schema-unavailability case.

    properties (SetAccess = immutable)
        observationIdentifier (1,:) char
        deliveryIdentifier (1,:) char
        ownerAssetIdentifier (1,:) char
        remoteAssetIdentifier (1,:) char
        remoteProductIdentifier (1,:) char
        coordinateEventEpoch_s (1,1) double
        observableIdentifier (1,:) char
        residual_m (:,1) double
        ownerCovarianceComponentOrder (1,:) cell
        remoteCovarianceComponentOrder (1,:) cell
        ownerAttitudeErrorCoordinateConvention (1,:) char
        remoteAttitudeErrorCoordinateConvention (1,:) char
        ownerJacobian_mPerErrorUnit (:,:) double
        remoteJacobian_mPerErrorUnit (:,:) double
        independentMeasurementCovariance_m2 (:,:) double
        remoteContributionCovariance_m2 (:,:) double
        residualCovarianceAssembly (1,:) char
        persistentCalibrationTreatment (1,:) char
        calibrationStateIdentifiers (1,:) cell
        covarianceGroupIdentifiers (1,:) cell
        correlationPolicy (1,:) char
        % --- Section 2.2 additions (all inert-sentinel-required when correlationPolicy='disabled') ---
        weightSelectionRule (1,:) char
        commonSourceContributionCovariances_m2 (1,:) cell
        calibrationMappingJacobian_mPerCalibrationUnit (:,:) double
        calibrationStateUnits (1,:) cell
        persistentCalibrationReferenceLocalTag_s (1,1) double
    end

    methods
        function obj = DistributedLinkUpdateBlock(record)
            required = {'observationIdentifier','deliveryIdentifier','ownerAssetIdentifier', ...
                'remoteAssetIdentifier','remoteProductIdentifier','coordinateEventEpoch_s', ...
                'observableIdentifier','residual_m','ownerCovarianceComponentOrder', ...
                'remoteCovarianceComponentOrder','ownerAttitudeErrorCoordinateConvention', ...
                'remoteAttitudeErrorCoordinateConvention','ownerJacobian_mPerErrorUnit', ...
                'remoteJacobian_mPerErrorUnit','independentMeasurementCovariance_m2', ...
                'remoteContributionCovariance_m2','residualCovarianceAssembly', ...
                'persistentCalibrationTreatment','calibrationStateIdentifiers', ...
                'covarianceGroupIdentifiers','correlationPolicy','weightSelectionRule', ...
                'commonSourceContributionCovariances_m2', ...
                'calibrationMappingJacobian_mPerCalibrationUnit','calibrationStateUnits', ...
                'persistentCalibrationReferenceLocalTag_s'};
            supplied = fieldnames(record);
            missing = setdiff(required,supplied);
            unknown = setdiff(supplied,required);
            if ~isempty(missing)
                error('DistributedLinkUpdateBlock:missingField', ...
                    'DistributedLinkUpdateBlock is missing %s.',missing{1});
            end
            if ~isempty(unknown)
                error('DistributedLinkUpdateBlock:unknownField', ...
                    'DistributedLinkUpdateBlock contains unsupported field %s.',unknown{1});
            end

            residual = record.residual_m(:);
            if isempty(residual) || any(~isfinite(residual))
                error('DistributedLinkUpdateBlock:residualValue', ...
                    'residual_m must be a nonempty finite column.');
            end
            m = numel(residual);
            nOwner = numel(record.ownerCovarianceComponentOrder);
            nRemote = numel(record.remoteCovarianceComponentOrder);
            Ho = record.ownerJacobian_mPerErrorUnit;
            Hr = record.remoteJacobian_mPerErrorUnit;
            if ~isequal(size(Ho),[m,nOwner]) || ~isequal(size(Hr),[m,nRemote]) || ...
                    any(~isfinite(Ho),'all') || any(~isfinite(Hr),'all')
                error('DistributedLinkUpdateBlock:jacobianDimension', ...
                    'Jacobian row/column dimensions must match the residual and component orders.');
            end

            R = record.independentMeasurementCovariance_m2;
            if ~isequal(size(R),[m,m]) || any(~isfinite(R),'all') || ...
                    norm(R-R','fro') > 1e-10 || min(eig((R+R')/2)) <= 0
                error('DistributedLinkUpdateBlock:measurementCovariance', ...
                    'independentMeasurementCovariance_m2 must be finite, symmetric, and positive definite.');
            end
            S = record.remoteContributionCovariance_m2;
            if ~isequal(size(S),[m,m]) || any(~isfinite(S),'all') || ...
                    norm(S-S','fro') > 1e-10 || min(eig((S+S')/2)) < -1e-10
                error('DistributedLinkUpdateBlock:remoteContributionCovariance', ...
                    'remoteContributionCovariance_m2 must be finite, symmetric, and PSD.');
            end

            revgnss.DistributedLinkUpdateBlock.requireRecognisedComponentOrder_( ...
                record.ownerCovarianceComponentOrder,record.ownerAttitudeErrorCoordinateConvention);
            revgnss.DistributedLinkUpdateBlock.requireRecognisedComponentOrder_( ...
                record.remoteCovarianceComponentOrder,record.remoteAttitudeErrorCoordinateConvention);

            allowedAssembly = revgnss.DistributedLinkUpdateAdapter.AllowedResidualCovarianceAssemblies;
            assembly = char(record.residualCovarianceAssembly);
            if ~any(strcmp(assembly,allowedAssembly))
                error('DistributedLinkUpdateBlock:residualCovarianceAssembly', ...
                    'residualCovarianceAssembly must be one of the frozen allowed assemblies.');
            end

            calibrationTreatment = char(record.persistentCalibrationTreatment);
            if strcmp(calibrationTreatment,'ownerEstimatedState')
                error('DistributedLinkUpdateBlock:ownerEstimatedCalibrationSchemaUnavailable', ...
                    ['persistentCalibrationTreatment ''ownerEstimatedState'' is not expressible in ' ...
                    'the frozen v1 14-component state/covariance schema (no calibration-state slot ' ...
                    'exists); widening the schema is Section 2.3/Stage-3 scope.']);
            end
            allowedCalibration = ...
                revgnss.DistributedLinkUpdateAdapter.AllowedPersistentCalibrationTreatments;
            if ~any(strcmp(calibrationTreatment,allowedCalibration))
                error('DistributedLinkUpdateBlock:persistentCalibrationTreatment', ...
                    'persistentCalibrationTreatment must be one of the frozen allowed treatments.');
            end

            correlationPolicy = char(record.correlationPolicy);
            allowedBlockPolicies = revgnss.DistributedLinkUpdateAdapter.AllowedBlockCorrelationPolicies;
            if ~any(strcmp(correlationPolicy,allowedBlockPolicies))
                error('DistributedLinkUpdateBlock:correlationPolicyUnsupported', ...
                    'correlationPolicy must be one of the frozen allowed block correlation policies.');
            end

            % Assembly<->policy coupling: the two can never disagree.
            assemblyPolicyPairOk = ...
                (strcmp(assembly,'notAssembledInSection21') && strcmp(correlationPolicy,'disabled')) || ...
                (strcmp(assembly,'notAssembledInputsEligibleForSplitCovarianceIntersection') && ...
                strcmp(correlationPolicy,'splitCovarianceIntersection'));
            if ~assemblyPolicyPairOk
                error('DistributedLinkUpdateBlock:assemblyPolicyMismatch', ...
                    'residualCovarianceAssembly and correlationPolicy must be the frozen matched pair.');
            end

            if ~(isnumeric(record.coordinateEventEpoch_s) && ...
                    isscalar(record.coordinateEventEpoch_s) && ...
                    isfinite(record.coordinateEventEpoch_s))
                error('DistributedLinkUpdateBlock:coordinateEventEpoch', ...
                    'coordinateEventEpoch_s must be a finite scalar.');
            end

            weightSelectionRule = char(record.weightSelectionRule);
            commonSourceCovariances = record.commonSourceContributionCovariances_m2;
            calibrationJacobian = record.calibrationMappingJacobian_mPerCalibrationUnit;
            calibrationUnits = record.calibrationStateUnits;
            referenceLocalTag = record.persistentCalibrationReferenceLocalTag_s;
            covarianceGroupIds = record.covarianceGroupIdentifiers;
            calibrationStateIds = record.calibrationStateIdentifiers;

            if strcmp(correlationPolicy,'disabled')
                % Inert sentinel enforcement: a 'disabled' block cannot smuggle live Section
                % 2.2 values through fields that a Section 2.1 consumer never inspects.
                inertOk = strcmp(weightSelectionRule,'notApplicable') && ...
                    isempty(commonSourceCovariances) && isempty(calibrationUnits) && ...
                    isequal(size(calibrationJacobian),[m,0]) && isnan(referenceLocalTag) && ...
                    isempty(covarianceGroupIds) && isempty(calibrationStateIds);
                if ~inertOk
                    error('DistributedLinkUpdateBlock:inertFieldsNotSentinel', ...
                        ['With correlationPolicy=''disabled'', weightSelectionRule must be ' ...
                        '''notApplicable'', commonSourceContributionCovariances_m2/' ...
                        'calibrationStateUnits/covarianceGroupIdentifiers/' ...
                        'calibrationStateIdentifiers must be empty, ' ...
                        'calibrationMappingJacobian_mPerCalibrationUnit must be m-by-0, and ' ...
                        'persistentCalibrationReferenceLocalTag_s must be NaN.']);
                end
            else
                allowedWeightRules = revgnss.SplitCovarianceIntersectionBound.AllowedWeightSelectionRules;
                if ~any(strcmp(weightSelectionRule,allowedWeightRules))
                    error('DistributedLinkUpdateBlock:weightSelectionRule', ...
                        'weightSelectionRule must be a frozen SplitCovarianceIntersectionBound rule.');
                end
                if ~iscell(commonSourceCovariances) || ...
                        numel(commonSourceCovariances) ~= numel(covarianceGroupIds)
                    error('DistributedLinkUpdateBlock:commonSourceContributionShape', ...
                        ['commonSourceContributionCovariances_m2 must have exactly one entry per ' ...
                        'covarianceGroupIdentifiers entry; no summed field exists.']);
                end
                for idx = 1:numel(commonSourceCovariances)
                    W = commonSourceCovariances{idx};
                    if ~isequal(size(W),[m,m]) || any(~isfinite(W),'all') || ...
                            norm(W-W','fro') > 1e-10*max(1,norm(W,'fro')) || ...
                            min(eig((W+W')/2)) < -1e-10*max(1,norm(W,'fro'))
                        error('DistributedLinkUpdateBlock:commonSourceContributionShape', ...
                            'commonSourceContributionCovariances_m2{%d} must be finite, symmetric, PSD, and m-by-m.',idx);
                    end
                end
                p = numel(calibrationStateIds);
                if ~isequal(size(calibrationJacobian),[m,p]) || any(~isfinite(calibrationJacobian),'all')
                    error('DistributedLinkUpdateBlock:calibrationMappingShape', ...
                        'calibrationMappingJacobian_mPerCalibrationUnit must be finite and m-by-p.');
                end
                if ~iscell(calibrationUnits) || numel(calibrationUnits) ~= p
                    error('DistributedLinkUpdateBlock:calibrationMappingShape', ...
                        'calibrationStateUnits must have exactly one entry per calibrationStateIdentifiers entry.');
                end
                allowedUnits = revgnss.SplitCovarianceIntersectionBound.AllowedCalibrationStateUnits;
                for idx = 1:p
                    if ~any(strcmp(char(calibrationUnits{idx}),allowedUnits))
                        error('DistributedLinkUpdateBlock:calibrationUnitMappingUnavailable', ...
                            ['calibrationStateUnits{%d} must be ''m''; the seconds-to-metres mapping ' ...
                            'factor c/2c is a Section 2.3 adapter responsibility.'],idx);
                    end
                end
                if strcmp(calibrationTreatment,'externalCalibrationProduct')
                    if p < 1
                        error('DistributedLinkUpdateBlock:calibrationMappingShape', ...
                            'externalCalibrationProduct requires at least one calibrationStateIdentifiers entry.');
                    end
                    if ~(isnumeric(referenceLocalTag) && isscalar(referenceLocalTag) && ...
                            isfinite(referenceLocalTag))
                        error('DistributedLinkUpdateBlock:persistentCalibrationReferenceLocalTag', ...
                            'persistentCalibrationReferenceLocalTag_s must be finite when a calibration state is declared.');
                    end
                elseif p ~= 0
                    error('DistributedLinkUpdateBlock:persistentCalibrationTreatment', ...
                        'calibrationStateIdentifiers must be empty unless persistentCalibrationTreatment=''externalCalibrationProduct''.');
                end
            end

            obj.observationIdentifier = char(record.observationIdentifier);
            obj.deliveryIdentifier = char(record.deliveryIdentifier);
            obj.ownerAssetIdentifier = char(record.ownerAssetIdentifier);
            obj.remoteAssetIdentifier = char(record.remoteAssetIdentifier);
            obj.remoteProductIdentifier = char(record.remoteProductIdentifier);
            obj.coordinateEventEpoch_s = double(record.coordinateEventEpoch_s);
            obj.observableIdentifier = char(record.observableIdentifier);
            obj.residual_m = residual;
            obj.ownerCovarianceComponentOrder = ...
                cellfun(@char,record.ownerCovarianceComponentOrder,'UniformOutput',false);
            obj.remoteCovarianceComponentOrder = ...
                cellfun(@char,record.remoteCovarianceComponentOrder,'UniformOutput',false);
            obj.ownerAttitudeErrorCoordinateConvention = ...
                char(record.ownerAttitudeErrorCoordinateConvention);
            obj.remoteAttitudeErrorCoordinateConvention = ...
                char(record.remoteAttitudeErrorCoordinateConvention);
            obj.ownerJacobian_mPerErrorUnit = Ho;
            obj.remoteJacobian_mPerErrorUnit = Hr;
            obj.independentMeasurementCovariance_m2 = (R+R')/2;
            obj.remoteContributionCovariance_m2 = (S+S')/2;
            obj.residualCovarianceAssembly = assembly;
            obj.persistentCalibrationTreatment = calibrationTreatment;
            obj.calibrationStateIdentifiers = calibrationStateIds;
            obj.covarianceGroupIdentifiers = covarianceGroupIds;
            obj.correlationPolicy = correlationPolicy;
            obj.weightSelectionRule = weightSelectionRule;
            obj.commonSourceContributionCovariances_m2 = ...
                cellfun(@(W) (W+W')/2,commonSourceCovariances,'UniformOutput',false);
            obj.calibrationMappingJacobian_mPerCalibrationUnit = calibrationJacobian;
            obj.calibrationStateUnits = cellfun(@char,calibrationUnits,'UniformOutput',false);
            obj.persistentCalibrationReferenceLocalTag_s = double(referenceLocalTag);
        end
    end

    methods (Static, Access = private)
        function requireRecognisedComponentOrder_(componentOrder, attitudeConvention)
            matchesEuler = isequal(componentOrder, ...
                revgnss.DistributedLinkProtocolContract.StateSchemaV1CovarianceComponentOrderEuler);
            matchesTangent = isequal(componentOrder, ...
                revgnss.DistributedLinkProtocolContract.StateSchemaV1CovarianceComponentOrderTangent);
            if ~(matchesEuler || matchesTangent)
                error('DistributedLinkUpdateBlock:attitudeConvention', ...
                    'A covariance component order must be a recognised frozen v1 variant.');
            end
            variant = 'euler';
            if matchesTangent; variant = 'tangent'; end
            conventionMatchesVariant = ...
                (strcmp(variant,'euler') && strcmp(char(attitudeConvention),'eulerZYXError_rad')) || ...
                (strcmp(variant,'tangent') && strcmp(char(attitudeConvention), ...
                'rightMultiplicativeLocalTangent_rad'));
            if ~conventionMatchesVariant
                error('DistributedLinkUpdateBlock:attitudeConvention', ...
                    'A declared attitude convention disagrees with its own covariance labels.');
            end
        end
    end
end
