classdef DistributedLinkCalibrationState
    % DistributedLinkCalibrationState  Interface #4 (plan Section 2.1): one ownership
    % declaration for one persistent link-calibration / terminal-residual quantity.
    %
    % 'whitePerRow' is deliberately absent from AllowedTemporalCovarianceModels -- it is a
    % named failure mode, not a supported option (plan invariant 8: "No persistent calibration,
    % terminal delay, or common product error may be copied as independent white diagonal R on
    % repeated rows"). The constructor checks ForbiddenTemporalCovarianceModels BEFORE the
    % allow-list so that shortcut is refused by its own diagnosable identifier
    % (:whiteNoiseTreatmentForbidden), not folded into the generic :temporalCovarianceModel
    % vocabulary error.

    properties (Constant)
        AllowedOwnershipKinds = {'ownerEstimatedState','externalCalibrationProduct'};
        AllowedStateKinds = { ...
            'turnaroundGroupDelayResidual_s','initiatorTerminalGroupDelayResidual_s', ...
            'transponderTerminalGroupDelayResidual_s','linkRangeBiasResidual_m'};
        AllowedTemporalCovarianceModels = { ...
            'notDeclared','randomWalk','firstOrderGaussMarkov','externalProductCovariance'};
        ForbiddenTemporalCovarianceModels = {'whitePerRow'};
    end

    properties (SetAccess = immutable)
        calibrationStateIdentifier (1,:) char
        scopeIdentifier (1,:) char
        stateKind (1,:) char
        ownershipKind (1,:) char
        ownerAssetIdentifier (1,:) char
        ownerCanonicalIndex (1,1) double
        externalProductIdentifier (1,:) char
        temporalCovarianceModel (1,:) char
        correlationTime_s (1,1) double
        processNoisePsd_perS (1,1) double
        processNoisePsdUnits (1,:) char
        priorVariance (1,1) double
        priorVarianceUnits (1,:) char
        validFromLocalTag_s (1,1) double
        validUntilLocalTag_s (1,1) double
        estimationStatus (1,:) char
    end

    methods
        function obj = DistributedLinkCalibrationState(record)
            required = {'calibrationStateIdentifier','scopeIdentifier','stateKind', ...
                'ownershipKind','ownerAssetIdentifier','ownerCanonicalIndex', ...
                'externalProductIdentifier','temporalCovarianceModel','correlationTime_s', ...
                'processNoisePsd_perS','processNoisePsdUnits','priorVariance', ...
                'priorVarianceUnits','validFromLocalTag_s','validUntilLocalTag_s', ...
                'estimationStatus'};
            supplied = fieldnames(record);
            missing = setdiff(required,supplied);
            unknown = setdiff(supplied,required);
            if ~isempty(missing)
                error('DistributedLinkCalibrationState:missingField', ...
                    'DistributedLinkCalibrationState is missing %s.',missing{1});
            end
            if ~isempty(unknown)
                error('DistributedLinkCalibrationState:unknownField', ...
                    'DistributedLinkCalibrationState contains unsupported field %s.',unknown{1});
            end

            ownershipKind = char(record.ownershipKind);
            if ~any(strcmp(ownershipKind, ...
                    revgnss.DistributedLinkCalibrationState.AllowedOwnershipKinds))
                error('DistributedLinkCalibrationState:ownershipKind', ...
                    'ownershipKind must be a frozen ownership kind.');
            end

            ownerEmpty = isempty(record.ownerAssetIdentifier);
            externalEmpty = isempty(record.externalProductIdentifier);
            if ownerEmpty == externalEmpty
                error('DistributedLinkCalibrationState:ownerExclusivity', ...
                    'Exactly one of ownerAssetIdentifier / externalProductIdentifier must be set.');
            end
            if strcmp(ownershipKind,'ownerEstimatedState')
                if ownerEmpty
                    error('DistributedLinkCalibrationState:ownerExclusivity', ...
                        'ownerEstimatedState requires a non-empty ownerAssetIdentifier.');
                end
                canonicalId = revgnss.CanonicalEndpointIdentity.fromProductIdentifier( ...
                    record.ownerAssetIdentifier);
                if canonicalId.physicalAssetIndex ~= record.ownerCanonicalIndex
                    error('DistributedLinkCalibrationState:ownerIdentifier', ...
                        'ownerAssetIdentifier and ownerCanonicalIndex disagree on the owning spacecraft.');
                end
            elseif ~ownerEmpty
                error('DistributedLinkCalibrationState:ownerExclusivity', ...
                    'externalCalibrationProduct requires an empty ownerAssetIdentifier.');
            end

            if ~any(strcmp(char(record.stateKind), ...
                    revgnss.DistributedLinkCalibrationState.AllowedStateKinds))
                error('DistributedLinkCalibrationState:stateKind', ...
                    'stateKind must be a frozen calibration state kind.');
            end

            temporalModel = char(record.temporalCovarianceModel);
            if any(strcmp(temporalModel, ...
                    revgnss.DistributedLinkCalibrationState.ForbiddenTemporalCovarianceModels))
                error('DistributedLinkCalibrationState:whiteNoiseTreatmentForbidden', ...
                    ['A persistent link calibration may not be modelled as independent white ' ...
                    'noise on repeated rows (plan invariant 8). Declare a persistent state ' ...
                    'with randomWalk or firstOrderGaussMarkov, or an externalProductCovariance.']);
            end
            if ~any(strcmp(temporalModel, ...
                    revgnss.DistributedLinkCalibrationState.AllowedTemporalCovarianceModels))
                error('DistributedLinkCalibrationState:temporalCovarianceModel', ...
                    'temporalCovarianceModel must be a frozen allowed model.');
            end

            if ~(isnumeric(record.validFromLocalTag_s) && isscalar(record.validFromLocalTag_s) && ...
                    isfinite(record.validFromLocalTag_s) && ...
                    isnumeric(record.validUntilLocalTag_s) && ...
                    isscalar(record.validUntilLocalTag_s) && ...
                    isfinite(record.validUntilLocalTag_s) && ...
                    record.validUntilLocalTag_s >= record.validFromLocalTag_s)
                error('DistributedLinkCalibrationState:validityInterval', ...
                    ['validFromLocalTag_s and validUntilLocalTag_s must both be finite, with ' ...
                    'validUntilLocalTag_s at or after validFromLocalTag_s. An unbounded ' ...
                    'interval is operationally equivalent to no validity interval at all ' ...
                    '(plan Section 2.4.4).']);
            end

            processNoiseRequired = any(strcmp(temporalModel,{'randomWalk','firstOrderGaussMarkov'}));
            if processNoiseRequired
                if ~(isnumeric(record.processNoisePsd_perS) && ...
                        isscalar(record.processNoisePsd_perS) && ...
                        isfinite(record.processNoisePsd_perS) && record.processNoisePsd_perS >= 0)
                    error('DistributedLinkCalibrationState:processNoise', ...
                        'processNoisePsd_perS must be finite and nonnegative for the declared model.');
                end
            elseif ~(isnumeric(record.processNoisePsd_perS) && isscalar(record.processNoisePsd_perS))
                error('DistributedLinkCalibrationState:processNoise', ...
                    'processNoisePsd_perS must be numeric even when not required.');
            end
            if strcmp(temporalModel,'firstOrderGaussMarkov')
                if ~(isnumeric(record.correlationTime_s) && isscalar(record.correlationTime_s) && ...
                        isfinite(record.correlationTime_s) && record.correlationTime_s > 0)
                    error('DistributedLinkCalibrationState:processNoise', ...
                        'correlationTime_s must be finite and positive for firstOrderGaussMarkov.');
                end
            end

            expectedUnits = 'm^2';
            if ~isempty(regexp(char(record.stateKind),'_s$','once'))
                expectedUnits = 's^2';
            end
            if ~(isnumeric(record.priorVariance) && isscalar(record.priorVariance) && ...
                    isfinite(record.priorVariance) && record.priorVariance > 0) || ...
                    ~strcmp(char(record.priorVarianceUnits),expectedUnits)
                error('DistributedLinkCalibrationState:priorVariance', ...
                    'priorVariance must be finite/positive with units matching the state kind suffix.');
            end
            % processNoisePsd_perS's name states only the "per second" half; the squared-
            % quantity half depends on stateKind (s^2/s for the *_s delay residuals, m^2/s for
            % linkRangeBiasResidual_m). Require the companion units field the same way
            % priorVarianceUnits is already required, so the two cannot be numerically
            % incomparable under one undifferentiated property name (plan invariant 10).
            expectedPsdUnits = [expectedUnits '/s'];
            if ~strcmp(char(record.processNoisePsdUnits),expectedPsdUnits)
                error('DistributedLinkCalibrationState:processNoisePsdUnits', ...
                    'processNoisePsdUnits must be %s, matching the state kind suffix.',expectedPsdUnits);
            end

            if ~strcmp(char(record.estimationStatus),'notEstimated')
                error('DistributedLinkCalibrationState:estimationStatusUnsupported', ...
                    'No distributed calibration state is estimated until Section 2.2/2.3; estimationStatus must be ''notEstimated''.');
            end

            obj.calibrationStateIdentifier = char(record.calibrationStateIdentifier);
            obj.scopeIdentifier = char(record.scopeIdentifier);
            obj.stateKind = char(record.stateKind);
            obj.ownershipKind = ownershipKind;
            obj.ownerAssetIdentifier = char(record.ownerAssetIdentifier);
            obj.ownerCanonicalIndex = double(record.ownerCanonicalIndex);
            obj.externalProductIdentifier = char(record.externalProductIdentifier);
            obj.temporalCovarianceModel = temporalModel;
            obj.correlationTime_s = double(record.correlationTime_s);
            obj.processNoisePsd_perS = double(record.processNoisePsd_perS);
            obj.processNoisePsdUnits = char(record.processNoisePsdUnits);
            obj.priorVariance = double(record.priorVariance);
            obj.priorVarianceUnits = char(record.priorVarianceUnits);
            obj.validFromLocalTag_s = double(record.validFromLocalTag_s);
            obj.validUntilLocalTag_s = double(record.validUntilLocalTag_s);
            obj.estimationStatus = char(record.estimationStatus);
        end

        function tf = coversLocalTag(obj, localTag_s)
            tf = isnumeric(localTag_s) && isscalar(localTag_s) && isfinite(localTag_s) && ...
                localTag_s >= obj.validFromLocalTag_s && localTag_s <= obj.validUntilLocalTag_s;
        end
    end
end
