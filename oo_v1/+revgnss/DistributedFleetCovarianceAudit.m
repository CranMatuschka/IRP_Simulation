classdef DistributedFleetCovarianceAudit
    % DistributedFleetCovarianceAudit  Immutable, constructor-verdict-forced certificate of one
    % PSD/symmetry audit of a transiently-assembled small-fleet covariance (plan Stage 3.1 item
    % 6). Mirrors the revgnss.OwnerPosteriorBoundResult idiom:
    % isSymmetricPositiveSemiDefinite == strcmp(verdict,'symmetricPositiveSemiDefinite') is
    % constructor-forced, so a caller cannot forge a clean flag with a violating verdict.
    %
    % This is a class rather than a plain struct precisely because it has an invariant that must
    % be constructor-forced. The assembled fleet covariance itself is NEVER stored here or on
    % revgnss.DistributedCovarianceNetwork: it is transient, rebuilt on demand from each
    % member's own live local marginal plus the network's owned cross blocks, so there is never
    % a second source of truth for data the leaves own.

    properties (SetAccess = immutable)
        auditCoordinateEpoch_s   (1,1) double
        networkRevisionNumber    (1,1) double
        endpointIdentifiers      (1,:) cell
        endpointDimensions       (1,:) double
        assembledDimension       (1,1) double
        symmetryResidualFrobenius (1,1) double
        symmetryResidualRelative  (1,1) double
        minimumScaledEigenvalue   (1,1) double
        scaledConditionNumber     (1,1) double
        maximumPairCanonicalCorrelation (1,1) double
        worstPairKey              (1,:) char
        staleCrossBlockPairKeys   (1,:) cell
        benignDiagonalNudgeEventCount (1,1) double
        isSymmetricPositiveSemiDefinite (1,1) logical
        verdict                   (1,:) char
    end

    methods
        function obj = DistributedFleetCovarianceAudit(record)
            required = {'auditCoordinateEpoch_s','networkRevisionNumber','endpointIdentifiers', ...
                'endpointDimensions','assembledDimension','symmetryResidualFrobenius', ...
                'symmetryResidualRelative','minimumScaledEigenvalue','scaledConditionNumber', ...
                'maximumPairCanonicalCorrelation','worstPairKey','staleCrossBlockPairKeys', ...
                'benignDiagonalNudgeEventCount','isSymmetricPositiveSemiDefinite','verdict'};
            supplied = fieldnames(record);
            missing = setdiff(required,supplied);
            unknown = setdiff(supplied,required);
            if ~isempty(missing)
                error('DistributedFleetCovarianceAudit:missingField', ...
                    'DistributedFleetCovarianceAudit is missing %s.',missing{1});
            end
            if ~isempty(unknown)
                error('DistributedFleetCovarianceAudit:unknownField', ...
                    'DistributedFleetCovarianceAudit contains unsupported field %s.',unknown{1});
            end

            verdict = char(record.verdict);
            if ~any(strcmp(verdict,revgnss.DistributedCovarianceNetworkContract.AllowedAuditVerdicts))
                error('DistributedFleetCovarianceAudit:verdict', ...
                    'verdict must be one of the frozen AllowedAuditVerdicts.');
            end
            expectedClean = strcmp(verdict,'symmetricPositiveSemiDefinite');
            if logical(record.isSymmetricPositiveSemiDefinite) ~= expectedClean
                error('DistributedFleetCovarianceAudit:verdictFlagMismatch', ...
                    ['isSymmetricPositiveSemiDefinite must equal ' ...
                    'strcmp(verdict,''symmetricPositiveSemiDefinite''); a caller cannot forge a ' ...
                    'clean flag with a violating verdict.']);
            end

            if numel(record.endpointIdentifiers) ~= numel(record.endpointDimensions)
                error('DistributedFleetCovarianceAudit:endpointSchema', ...
                    'endpointIdentifiers and endpointDimensions must have the same length.');
            end
            if sum(record.endpointDimensions) ~= record.assembledDimension
                error('DistributedFleetCovarianceAudit:assembledDimension', ...
                    'assembledDimension must equal the sum of endpointDimensions.');
            end
            if record.assembledDimension > ...
                    revgnss.DistributedCovarianceNetworkContract.MaximumAssembledFleetDimension
                error('DistributedFleetCovarianceAudit:assembledFleetDimensionLimitExceeded', ...
                    'assembledDimension exceeds MaximumAssembledFleetDimension.');
            end

            obj.auditCoordinateEpoch_s = double(record.auditCoordinateEpoch_s);
            obj.networkRevisionNumber = double(record.networkRevisionNumber);
            obj.endpointIdentifiers = cellfun(@char,record.endpointIdentifiers,'UniformOutput',false);
            obj.endpointDimensions = double(record.endpointDimensions);
            obj.assembledDimension = double(record.assembledDimension);
            obj.symmetryResidualFrobenius = double(record.symmetryResidualFrobenius);
            obj.symmetryResidualRelative = double(record.symmetryResidualRelative);
            obj.minimumScaledEigenvalue = double(record.minimumScaledEigenvalue);
            obj.scaledConditionNumber = double(record.scaledConditionNumber);
            obj.maximumPairCanonicalCorrelation = double(record.maximumPairCanonicalCorrelation);
            obj.worstPairKey = char(record.worstPairKey);
            obj.staleCrossBlockPairKeys = record.staleCrossBlockPairKeys;
            obj.benignDiagonalNudgeEventCount = double(record.benignDiagonalNudgeEventCount);
            obj.isSymmetricPositiveSemiDefinite = expectedClean;
            obj.verdict = verdict;
        end
    end

    methods (Static)
        function obj = fromRecord(record)
            obj = revgnss.DistributedFleetCovarianceAudit(record);
        end
    end
end
