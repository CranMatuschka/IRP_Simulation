classdef CommonProcessNoiseCovarianceGroup
    % CommonProcessNoiseCovarianceGroup  One immutable declaration of one shared common-
    % process-noise source between fleet members (plan Stage 3.1 item 3). Sibling of, NOT a
    % reuse of, revgnss.CommonSourceCovarianceGroup: that class is measurement-space
    % (sharedCovarianceContribution_m2); this one is state-space (a position/velocity process-
    % noise cross term) and has no measurement-space contribution at all. Merging them would
    % force one of the two into the wrong units.
    %
    % crossProcessNoise(dt_s,...) generalizes filter.ReverseGNSSEKF.addJointAssetProcessNoise_'s
    % qCommon placement element-for-element (JointReferenceMethod), reading the SAME
    % cfg.estimator.processNoise.commonAcceleration.{enable,sigma_mps2,frame} values so a
    % centralized comparison is meaningful rather than circular.
    %
    % LIVE-PATH REFUSAL: addJointAssetProcessNoise_ adds qCommon to the DIAGONAL blocks too, and
    % only when jointMultiAssetEnabled. An independent-fleet leaf's own buildQ_ never receives
    % that matching diagonal term, so a cross-only injection into the network would NOT
    % reproduce the centralized reference and could make the assembled fleet Q indefinite. This
    % class is fully implemented and fully proven at the network level (see
    % tests/test_distributed_common_product_cross_covariance.m); the live coordinator path
    % refuses treatment='declaredCommonAccelerationGroup'
    % (IndependentFleetCoordinator:commonProcessNoiseTreatmentUnavailableOnLivePath).

    properties (Constant)
        AllowedTreatments = {'declaredCommonAccelerationGroup'}
        SchemaUnavailableTreatments = {'estimatedOwnerState','externalCovarianceProduct'}
        JointReferenceMethod = 'filter.ReverseGNSSEKF.addJointAssetProcessNoise_'
    end

    properties (SetAccess = immutable)
        processNoiseGroupIdentifier  (1,:) char
        commonSourceName             (1,:) char
        treatment                    (1,:) char
        memberEndpointIdentifiers    (1,:) cell
        frameIdentifier              (1,:) char
        commonAccelerationSigma_mps2 (1,1) double
        stateComponentPairing        (1,:) char
        sourceConfigurationPath      (1,:) char
        validFromCoordinateEpoch_s   (1,1) double
        validUntilCoordinateEpoch_s  (1,1) double
    end

    methods
        function obj = CommonProcessNoiseCovarianceGroup(record)
            required = {'processNoiseGroupIdentifier','commonSourceName','treatment', ...
                'memberEndpointIdentifiers','frameIdentifier','commonAccelerationSigma_mps2', ...
                'stateComponentPairing','sourceConfigurationPath','validFromCoordinateEpoch_s', ...
                'validUntilCoordinateEpoch_s'};
            supplied = fieldnames(record);
            missing = setdiff(required,supplied);
            unknown = setdiff(supplied,required);
            if ~isempty(missing)
                error('CommonProcessNoiseCovarianceGroup:missingField', ...
                    'CommonProcessNoiseCovarianceGroup is missing %s.',missing{1});
            end
            if ~isempty(unknown)
                error('CommonProcessNoiseCovarianceGroup:unknownField', ...
                    'CommonProcessNoiseCovarianceGroup contains unsupported field %s.',unknown{1});
            end

            treatment = char(record.treatment);
            if any(strcmp(treatment,revgnss.CommonProcessNoiseCovarianceGroup.SchemaUnavailableTreatments))
                error('CommonProcessNoiseCovarianceGroup:schemaUnavailableTreatment', ...
                    ['treatment ''%s'' is not available for a process-noise group: this class ' ...
                    'carries no measurement-space or product/calibration slot.'],treatment);
            end
            if ~any(strcmp(treatment,revgnss.CommonProcessNoiseCovarianceGroup.AllowedTreatments))
                error('CommonProcessNoiseCovarianceGroup:treatment', ...
                    'treatment must be one of the frozen AllowedTreatments.');
            end

            if ~strcmp(char(record.commonSourceName),'sharedForceAtmosphericProduct')
                error('CommonProcessNoiseCovarianceGroup:commonSourceName', ...
                    'commonSourceName must be ''sharedForceAtmosphericProduct''.');
            end

            members = record.memberEndpointIdentifiers;
            if ~iscell(members) || numel(members) < 2 || ...
                    any(cellfun(@(v) ~(ischar(v)||isstring(v)) || isempty(strtrim(char(v))),members)) || ...
                    numel(unique(cellfun(@char,members,'UniformOutput',false))) ~= numel(members)
                error('CommonProcessNoiseCovarianceGroup:memberIdentifiers', ...
                    'memberEndpointIdentifiers must list at least two distinct nonempty identifiers.');
            end

            if ~strcmp(char(record.frameIdentifier),'ECEF')
                error('CommonProcessNoiseCovarianceGroup:frame', ...
                    ['frameIdentifier must be ''ECEF'': the joint reference adds qCommon directly ' ...
                    'onto ECEF position/velocity indices with no rotation.']);
            end
            sigma = record.commonAccelerationSigma_mps2;
            if ~(isnumeric(sigma) && isscalar(sigma) && isfinite(sigma) && sigma >= 0)
                error('CommonProcessNoiseCovarianceGroup:sigma', ...
                    'commonAccelerationSigma_mps2 must be a finite nonnegative scalar.');
            end
            if ~strcmp(char(record.stateComponentPairing),'positionVelocityPerAxis')
                error('CommonProcessNoiseCovarianceGroup:pairing', ...
                    'stateComponentPairing must be ''positionVelocityPerAxis''.');
            end
            if isempty(char(record.sourceConfigurationPath))
                error('CommonProcessNoiseCovarianceGroup:sourcePath', ...
                    'sourceConfigurationPath must be nonempty text.');
            end
            if ~(isnumeric(record.validFromCoordinateEpoch_s) && isscalar(record.validFromCoordinateEpoch_s) && ...
                    isnumeric(record.validUntilCoordinateEpoch_s) && isscalar(record.validUntilCoordinateEpoch_s) && ...
                    record.validUntilCoordinateEpoch_s >= record.validFromCoordinateEpoch_s)
                error('CommonProcessNoiseCovarianceGroup:validityInterval', ...
                    'validFromCoordinateEpoch_s/validUntilCoordinateEpoch_s must form a valid interval.');
            end
            if isempty(char(record.processNoiseGroupIdentifier))
                error('CommonProcessNoiseCovarianceGroup:groupIdentifier', ...
                    'processNoiseGroupIdentifier must be nonempty text.');
            end

            obj.processNoiseGroupIdentifier = char(record.processNoiseGroupIdentifier);
            obj.commonSourceName = char(record.commonSourceName);
            obj.treatment = treatment;
            obj.memberEndpointIdentifiers = cellfun(@char,members,'UniformOutput',false);
            obj.frameIdentifier = char(record.frameIdentifier);
            obj.commonAccelerationSigma_mps2 = double(sigma);
            obj.stateComponentPairing = char(record.stateComponentPairing);
            obj.sourceConfigurationPath = char(record.sourceConfigurationPath);
            obj.validFromCoordinateEpoch_s = double(record.validFromCoordinateEpoch_s);
            obj.validUntilCoordinateEpoch_s = double(record.validUntilCoordinateEpoch_s);
        end

        function Qij = crossProcessNoise(obj, dt_s, firstSchemaIndices, secondSchemaIndices, nFirst, nSecond)
            % crossProcessNoise  Generalizes addJointAssetProcessNoise_'s qCommon placement: for
            % axis a in {1,2,3}, pi=[r_a,v_a] (first member), pj=[r_a,v_a] (second member),
            % Qij(pi,pj) += sigma^2*[dt^3/3,dt^2/2;dt^2/2,dt].
            Qij = zeros(nFirst,nSecond);
            qCommon = obj.commonAccelerationSigma_mps2^2 * [dt_s^3/3,dt_s^2/2;dt_s^2/2,dt_s];
            for axisIdx = 1:3
                pi_ = [firstSchemaIndices(axisIdx),firstSchemaIndices(3+axisIdx)];
                pj_ = [secondSchemaIndices(axisIdx),secondSchemaIndices(3+axisIdx)];
                Qij(pi_,pj_) = Qij(pi_,pj_) + qCommon;
            end
        end

        function Qii = ownDiagonalContribution(obj, dt_s, schemaIndices, n)
            % ownDiagonalContribution  Audit/test-reference use only, NEVER applied on the live
            % path: the diagonal term addJointAssetProcessNoise_ would add to a member's OWN Q,
            % needed only to build the centralized reference Q in tests.
            Qii = obj.crossProcessNoise(dt_s,schemaIndices,schemaIndices,n,n);
        end
    end

    methods (Static)
        function obj = fromRecord(record)
            obj = revgnss.CommonProcessNoiseCovarianceGroup(record);
        end
    end
end
