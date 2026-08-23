classdef LocalEpochTransitionCapture
    % LocalEpochTransitionCapture  One immutable, validated snapshot of one local EKF's closed-
    % loop error-transition operators over one coordinator epoch (plan Stage 3.1 items 4-5).
    %
    % stateTransition (F_i) describes predict() alone. localUpdateContraction (A_i) is the
    % COMPOSITE contraction of every update() call in the interval,
    % A_i = G_L*(I-K_L*H_L) * ... * G_1*(I-K_1*H_1), A_i=I when no update() ran -- F alone is
    % insufficient because the local ground/onboard update is the larger part of the epoch's
    % error transformation (plan Stage-3 design, U3). G folds the quaternion-error-state
    % attitude reset Jacobian I-0.5*[deltaTheta]x on the euler rows (U4); it is identity in
    % eulerZYX mode.
    %
    % unmodelledCovarianceTransformCount>0 means a non-linear, non-diagonal covariance edit
    % occurred that this capture's operators do NOT describe (nearestSPD_ projection, or an
    % ambiguity-covariance reset) -- revgnss.DistributedCovarianceNetwork.advanceEpoch refuses
    % such a capture rather than silently propagating a wrong cross block (U5). The benign
    % tiny-negative-eigenvalue diagonal nudge is counted separately and does NOT set this
    % (U6): it is a positive diagonal addition to P_ii only and never touches a cross block.

    properties (SetAccess = immutable)
        endpointIdentifier                 (1,:) char
        localStateDimension                (1,1) double
        predictApplied                     (1,1) logical
        stateTransition                    (:,:) double
        processNoise                       (:,:) double
        localUpdateContraction             (:,:) double
        intervalStartCoordinateEpoch_s     (1,1) double
        intervalDuration_s                 (1,1) double
        intervalEndCoordinateEpoch_s       (1,1) double
        accountedUpdateCallCount           (1,1) double
        accountedMeasurementRowCount       (1,1) double
        benignDiagonalNudgeCount           (1,1) double
        unmodelledCovarianceTransformCount (1,1) double
        unmodelledCovarianceTransformKinds (1,:) cell
        schemaStateIndices                 (14,1) double
        covarianceComponentOrder           (1,:) cell
        attitudeErrorCoordinateConvention  (1,:) char
        localStateMapFingerprint           (1,:) char
        captureSequenceNumber              (1,1) double
    end

    methods
        function obj = LocalEpochTransitionCapture(record)
            required = {'endpointIdentifier','localStateDimension','predictApplied', ...
                'stateTransition','processNoise','localUpdateContraction', ...
                'intervalStartCoordinateEpoch_s','intervalDuration_s', ...
                'intervalEndCoordinateEpoch_s','accountedUpdateCallCount', ...
                'accountedMeasurementRowCount','benignDiagonalNudgeCount', ...
                'unmodelledCovarianceTransformCount','unmodelledCovarianceTransformKinds', ...
                'schemaStateIndices','covarianceComponentOrder', ...
                'attitudeErrorCoordinateConvention','localStateMapFingerprint', ...
                'captureSequenceNumber'};
            supplied = fieldnames(record);
            missing = setdiff(required,supplied);
            unknown = setdiff(supplied,required);
            if ~isempty(missing)
                error('LocalEpochTransitionCapture:missingField', ...
                    'LocalEpochTransitionCapture is missing %s.',missing{1});
            end
            if ~isempty(unknown)
                error('LocalEpochTransitionCapture:unknownField', ...
                    'LocalEpochTransitionCapture contains unsupported field %s.',unknown{1});
            end

            n = record.localStateDimension;
            if ~(isnumeric(n) && isscalar(n) && n == round(n) && n >= 14)
                error('LocalEpochTransitionCapture:localStateDimension', ...
                    'localStateDimension must be an integer at least 14.');
            end
            F = record.stateTransition;
            Q = record.processNoise;
            A = record.localUpdateContraction;
            if ~isequal(size(F),[n n]) || any(~isfinite(F(:)))
                error('LocalEpochTransitionCapture:stateTransition', ...
                    'stateTransition must be a finite n-by-n matrix.');
            end
            if ~isequal(size(Q),[n n]) || any(~isfinite(Q(:))) || norm(Q-Q','fro') > 1e-8*max(1,norm(Q,'fro'))
                error('LocalEpochTransitionCapture:processNoise', ...
                    'processNoise must be a finite, symmetric n-by-n matrix.');
            end
            if ~isequal(size(A),[n n]) || any(~isfinite(A(:)))
                error('LocalEpochTransitionCapture:localUpdateContraction', ...
                    'localUpdateContraction must be a finite n-by-n matrix.');
            end

            dt = record.intervalDuration_s;
            if ~(isnumeric(dt) && isscalar(dt) && isfinite(dt) && dt > 0)
                error('LocalEpochTransitionCapture:intervalDuration', ...
                    'intervalDuration_s must be a finite positive scalar.');
            end
            if abs((record.intervalStartCoordinateEpoch_s+dt) - record.intervalEndCoordinateEpoch_s) > 1e-9
                error('LocalEpochTransitionCapture:intervalArithmetic', ...
                    'intervalEndCoordinateEpoch_s must equal intervalStart+intervalDuration.');
            end

            if ~record.predictApplied
                if ~isequal(F,eye(n)) || any(Q(:) ~= 0)
                    error('LocalEpochTransitionCapture:predictNotApplied', ...
                        'predictApplied=false requires stateTransition=eye(n) and processNoise=zeros(n).');
                end
            end

            idx = record.schemaStateIndices(:);
            if numel(idx) ~= 14 || numel(unique(idx)) ~= 14 || any(idx < 1) || any(idx > n)
                error('LocalEpochTransitionCapture:schemaStateIndices', ...
                    'schemaStateIndices must be 14 distinct indices within 1:localStateDimension.');
            end

            matchesEuler = isequal(record.covarianceComponentOrder, ...
                revgnss.DistributedLinkProtocolContract.StateSchemaV1CovarianceComponentOrderEuler);
            matchesTangent = isequal(record.covarianceComponentOrder, ...
                revgnss.DistributedLinkProtocolContract.StateSchemaV1CovarianceComponentOrderTangent);
            if ~(matchesEuler || matchesTangent)
                error('LocalEpochTransitionCapture:covarianceComponentOrder', ...
                    'covarianceComponentOrder must be a recognised frozen v1 variant.');
            end
            variant = 'euler'; if matchesTangent; variant = 'tangent'; end
            conventionOk = ...
                (strcmp(variant,'euler') && strcmp(record.attitudeErrorCoordinateConvention,'eulerZYXError_rad')) || ...
                (strcmp(variant,'tangent') && strcmp(record.attitudeErrorCoordinateConvention, ...
                'rightMultiplicativeLocalTangent_rad'));
            if ~conventionOk
                error('LocalEpochTransitionCapture:attitudeConventionMismatch', ...
                    'attitudeErrorCoordinateConvention disagrees with the covariance component order.');
            end

            if ~(isnumeric(record.unmodelledCovarianceTransformCount) && ...
                    record.unmodelledCovarianceTransformCount >= 0)
                error('LocalEpochTransitionCapture:transformCount', ...
                    'unmodelledCovarianceTransformCount must be a nonnegative scalar.');
            end
            if numel(record.unmodelledCovarianceTransformKinds) ~= record.unmodelledCovarianceTransformCount
                error('LocalEpochTransitionCapture:transformKinds', ...
                    'unmodelledCovarianceTransformKinds must have one entry per counted transform.');
            end

            obj.endpointIdentifier = char(record.endpointIdentifier);
            obj.localStateDimension = double(n);
            obj.predictApplied = logical(record.predictApplied);
            obj.stateTransition = F;
            obj.processNoise = (Q+Q')/2;
            obj.localUpdateContraction = A;
            obj.intervalStartCoordinateEpoch_s = double(record.intervalStartCoordinateEpoch_s);
            obj.intervalDuration_s = double(dt);
            obj.intervalEndCoordinateEpoch_s = double(record.intervalEndCoordinateEpoch_s);
            obj.accountedUpdateCallCount = double(record.accountedUpdateCallCount);
            obj.accountedMeasurementRowCount = double(record.accountedMeasurementRowCount);
            obj.benignDiagonalNudgeCount = double(record.benignDiagonalNudgeCount);
            obj.unmodelledCovarianceTransformCount = double(record.unmodelledCovarianceTransformCount);
            obj.unmodelledCovarianceTransformKinds = record.unmodelledCovarianceTransformKinds;
            obj.schemaStateIndices = idx;
            obj.covarianceComponentOrder = record.covarianceComponentOrder;
            obj.attitudeErrorCoordinateConvention = char(record.attitudeErrorCoordinateConvention);
            obj.localStateMapFingerprint = char(record.localStateMapFingerprint);
            obj.captureSequenceNumber = double(record.captureSequenceNumber);
        end
    end

    methods (Static)
        function obj = fromLocalEpochRecord(record)
            obj = revgnss.LocalEpochTransitionCapture(record);
        end
    end
end
