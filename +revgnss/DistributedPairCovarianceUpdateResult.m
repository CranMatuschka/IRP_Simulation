classdef DistributedPairCovarianceUpdateResult
    % DistributedPairCovarianceUpdateResult  Immutable, validated report of one call to
    % revgnss.DistributedCovarianceNetwork.pairMeasurementUpdatePrimitive (plan Stage 3.1 item
    % 5). Pure result record: the primitive that produces it computes and applies nothing.
    % appliedToAnyFilter is constructor-FORCED false -- a result that claims to have been
    % applied is refused at construction, because applying a correction to a non-owner endpoint
    % IS delivery, the defining act of Section 3.2, which this stage does not implement.
    %
    % Discipline inherited from revgnss.DistributedLinkUpdateBlock: the four constituents of S
    % (owner/cross/remote/independent) are carried SEPARATELY, and the constructor requires
    % their sum to reconstruct innovationCovariance_rowUnit2 to tight tolerance. There is no
    % field that could carry a pre-summed/folded covariance and none may ever be added. This is
    % NOT the same discipline as revgnss.SplitCovarianceIntersectionBound's folding refusal
    % (Section 2.2): there, folding was forbidden because a term was UNKNOWN and the fold was
    % provably not a bound; here every term is DECLARED and stored separately, S is the exact
    % assembled innovation covariance (not a bound), and the constructor makes the sum auditable
    % instead of implicit.

    properties (SetAccess = immutable)
        observationIdentifier    (1,:) char
        deliveryIdentifier       (1,:) char
        observableIdentifier     (1,:) char
        observableRowUnits       (1,:) char
        ownerEndpointIdentifier  (1,:) char
        remoteEndpointIdentifier (1,:) char
        coordinateEventEpoch_s   (1,1) double

        residual_rowUnit                          (:,1) double
        innovationCovariance_rowUnit2              (:,:) double
        innovationOwnerTerm_rowUnit2               (:,:) double
        innovationCrossTerm_rowUnit2               (:,:) double
        innovationRemoteTerm_rowUnit2              (:,:) double
        independentMeasurementCovariance_rowUnit2  (:,:) double

        ownerGain_errorUnitPerRowUnit    (:,:) double
        remoteGain_errorUnitPerRowUnit   (:,:) double
        ownerStateCorrection_errorUnit   (:,1) double
        remoteStateCorrection_errorUnit  (:,1) double
        ownerPosteriorLocalCovariance    (:,:) double
        remotePosteriorLocalCovariance   (:,:) double
        posteriorCrossCovariance         (:,:) double

        normalizedInnovationSquared        (1,1) double
        jointPriorMinimumScaledEigenvalue  (1,1) double
        appliedToAnyFilter                 (1,1) logical
    end

    methods
        function obj = DistributedPairCovarianceUpdateResult(record)
            required = {'observationIdentifier','deliveryIdentifier','observableIdentifier', ...
                'observableRowUnits','ownerEndpointIdentifier','remoteEndpointIdentifier', ...
                'coordinateEventEpoch_s','residual_rowUnit','innovationCovariance_rowUnit2', ...
                'innovationOwnerTerm_rowUnit2','innovationCrossTerm_rowUnit2', ...
                'innovationRemoteTerm_rowUnit2','independentMeasurementCovariance_rowUnit2', ...
                'ownerGain_errorUnitPerRowUnit','remoteGain_errorUnitPerRowUnit', ...
                'ownerStateCorrection_errorUnit','remoteStateCorrection_errorUnit', ...
                'ownerPosteriorLocalCovariance','remotePosteriorLocalCovariance', ...
                'posteriorCrossCovariance','normalizedInnovationSquared', ...
                'jointPriorMinimumScaledEigenvalue','appliedToAnyFilter'};
            supplied = fieldnames(record);
            missing = setdiff(required,supplied);
            unknown = setdiff(supplied,required);
            if ~isempty(missing)
                error('DistributedPairCovarianceUpdateResult:missingField', ...
                    'DistributedPairCovarianceUpdateResult is missing %s.',missing{1});
            end
            if ~isempty(unknown)
                error('DistributedPairCovarianceUpdateResult:unknownField', ...
                    'DistributedPairCovarianceUpdateResult contains unsupported field %s.',unknown{1});
            end

            if record.appliedToAnyFilter
                error('DistributedPairCovarianceUpdateResult:appliedToAnyFilterForbidden', ...
                    ['appliedToAnyFilter must be false: this Stage-3.1 primitive computes and ' ...
                    'applies nothing. Applying a correction to a non-owner endpoint is delivery, ' ...
                    'Section 3.2''s defining act.']);
            end

            S = record.innovationCovariance_rowUnit2;
            owner = record.innovationOwnerTerm_rowUnit2;
            cross = record.innovationCrossTerm_rowUnit2;
            remote = record.innovationRemoteTerm_rowUnit2;
            R = record.independentMeasurementCovariance_rowUnit2;
            m = size(S,1);
            if isempty(S) || ~isequal(size(S),[m m]) || any(~isfinite(S(:)))
                error('DistributedPairCovarianceUpdateResult:innovationCovariance', ...
                    'innovationCovariance_rowUnit2 must be a finite square matrix.');
            end
            if norm(S-S','fro') > 1e-8*max(1,norm(S,'fro'))
                error('DistributedPairCovarianceUpdateResult:innovationCovarianceSymmetry', ...
                    'innovationCovariance_rowUnit2 must be symmetric.');
            end
            if min(eig((S+S')/2)) <= 0
                error('DistributedPairCovarianceUpdateResult:innovationCovarianceNotPd', ...
                    'innovationCovariance_rowUnit2 must be positive definite.');
            end
            if ~isequal(size(owner),[m m]) || ~isequal(size(cross),[m m]) || ...
                    ~isequal(size(remote),[m m]) || ~isequal(size(R),[m m])
                error('DistributedPairCovarianceUpdateResult:innovationTermDimension', ...
                    'Every innovation-covariance term must match the dimension of S.');
            end
            tol = revgnss.DistributedCovarianceNetworkContract.InnovationDecompositionToleranceRelative;
            reconstructed = owner+cross+remote+R;
            if norm(reconstructed-S,'fro') > tol*max(1,norm(S,'fro'))
                error('DistributedPairCovarianceUpdateResult:innovationDecompositionMismatch', ...
                    ['innovationOwnerTerm_rowUnit2 + innovationCrossTerm_rowUnit2 + ' ...
                    'innovationRemoteTerm_rowUnit2 + independentMeasurementCovariance_rowUnit2 ' ...
                    'must reconstruct innovationCovariance_rowUnit2.']);
            end

            Pi = record.ownerPosteriorLocalCovariance;
            Pj = record.remotePosteriorLocalCovariance;
            if isempty(Pi) || size(Pi,1) ~= size(Pi,2) || any(~isfinite(Pi(:))) || ...
                    norm(Pi-Pi','fro') > 1e-8*max(1,norm(Pi,'fro')) || min(eig((Pi+Pi')/2)) < ...
                    -1e-8*max(1,norm(Pi,'fro'))
                error('DistributedPairCovarianceUpdateResult:ownerPosterior', ...
                    'ownerPosteriorLocalCovariance must be finite, symmetric, and PSD.');
            end
            if isempty(Pj) || size(Pj,1) ~= size(Pj,2) || any(~isfinite(Pj(:))) || ...
                    norm(Pj-Pj','fro') > 1e-8*max(1,norm(Pj,'fro')) || min(eig((Pj+Pj')/2)) < ...
                    -1e-8*max(1,norm(Pj,'fro'))
                error('DistributedPairCovarianceUpdateResult:remotePosterior', ...
                    'remotePosteriorLocalCovariance must be finite, symmetric, and PSD.');
            end
            Pij = record.posteriorCrossCovariance;
            if isempty(Pij) || any(~isfinite(Pij(:))) || ...
                    ~isequal(size(Pij),[size(Pi,1),size(Pj,1)])
                error('DistributedPairCovarianceUpdateResult:posteriorCross', ...
                    'posteriorCrossCovariance must be finite and dimensioned owner-by-remote.');
            end

            floor_ = -revgnss.DistributedCovarianceNetworkContract.PositiveSemiDefiniteToleranceScaled;
            if record.jointPriorMinimumScaledEigenvalue < floor_
                error('DistributedPairCovarianceUpdateResult:jointPriorNotPsd', ...
                    ['jointPriorMinimumScaledEigenvalue is below the frozen PSD tolerance: the ' ...
                    'joint [[Pii,Pij];[Pij'',Pjj]] prior supplied to the primitive was not PSD.']);
            end

            obj.observationIdentifier = char(record.observationIdentifier);
            obj.deliveryIdentifier = char(record.deliveryIdentifier);
            obj.observableIdentifier = char(record.observableIdentifier);
            obj.observableRowUnits = char(record.observableRowUnits);
            obj.ownerEndpointIdentifier = char(record.ownerEndpointIdentifier);
            obj.remoteEndpointIdentifier = char(record.remoteEndpointIdentifier);
            obj.coordinateEventEpoch_s = double(record.coordinateEventEpoch_s);
            obj.residual_rowUnit = record.residual_rowUnit(:);
            obj.innovationCovariance_rowUnit2 = S;
            obj.innovationOwnerTerm_rowUnit2 = owner;
            obj.innovationCrossTerm_rowUnit2 = cross;
            obj.innovationRemoteTerm_rowUnit2 = remote;
            obj.independentMeasurementCovariance_rowUnit2 = R;
            obj.ownerGain_errorUnitPerRowUnit = record.ownerGain_errorUnitPerRowUnit;
            obj.remoteGain_errorUnitPerRowUnit = record.remoteGain_errorUnitPerRowUnit;
            obj.ownerStateCorrection_errorUnit = record.ownerStateCorrection_errorUnit(:);
            obj.remoteStateCorrection_errorUnit = record.remoteStateCorrection_errorUnit(:);
            obj.ownerPosteriorLocalCovariance = Pi;
            obj.remotePosteriorLocalCovariance = Pj;
            obj.posteriorCrossCovariance = Pij;
            obj.normalizedInnovationSquared = double(record.normalizedInnovationSquared);
            obj.jointPriorMinimumScaledEigenvalue = double(record.jointPriorMinimumScaledEigenvalue);
            obj.appliedToAnyFilter = false;
        end
    end

    methods (Static)
        function obj = fromRecord(record)
            obj = revgnss.DistributedPairCovarianceUpdateResult(record);
        end
    end
end
