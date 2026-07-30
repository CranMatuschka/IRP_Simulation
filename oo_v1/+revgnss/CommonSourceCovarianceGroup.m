classdef CommonSourceCovarianceGroup
    % CommonSourceCovarianceGroup  One immutable declaration of one shared-source instance
    % (plan Section 2.2 bullet 5). Gives the word 'covarianceGroup' (and the other
    % DistributedLinkProtocolContract.AllowedCommonSourceTreatments words) a backing data
    % structure a revgnss.SplitCovarianceIntersectionBound caller can look up; that frozen
    % vocabulary is reused UNCHANGED here, not redefined.
    %
    % 'estimatedOwnerState' is refused BY NAME (SchemaUnavailableTreatments), before the
    % generic vocabulary check, with the same reasoning DistributedLinkCalibrationState uses
    % for 'whitePerRow': the frozen v1 14-component state/covariance schema
    % (DistributedLinkProtocolContract.StateSchemaV1*) has no product/calibration slot, so a
    % shared source cannot become an owner-estimated state without widening that schema, which
    % is Section 2.3/Stage-3 scope. Silently dropping the declaration instead would violate
    % plan invariant 6 ("unsupported combinations must fail configuration validation... never
    % fall back silently to a simpler model") and the forbidden shortcut "do not set unknown
    % cross-covariances to zero after link measurements begin."
    %
    % 'transmittedStateProduct' + treatment='covarianceGroup' is refused BY NAME
    % (SourceTreatmentIncompatibilities). This source's error is the remote endpoint's OWN
    % prediction error against its own truth (e_j in SplitCovarianceIntersectionBound's
    % derivation) -- it is already carried, in full, by that module's remotePrior Young term.
    % It is not a measurement-noise contribution and was never inside a caller's
    % totalMeasurementCovariance_m2 to begin with, so a caller declaring it as a
    % 'covarianceGroup' common source and having it subtracted into Rind would either drive
    % Rind non-positive-definite (a safe but misleadingly-diagnosed refusal) or -- if a caller
    % padded totalMeasurementCovariance_m2 to make the subtraction succeed -- double-count
    % against the remote-prior term. A future Section 2.3 adapter that wants extra
    % conservatism against remote-state-transmission error should widen the remote prior
    % covariance Pj itself, not declare a covarianceGroup for this source.

    properties (Constant)
        ForbiddenTemporalCovarianceModels = {'whitePerRow'};
        SchemaUnavailableTreatments = {'estimatedOwnerState'};
        AllowedTemporalCovarianceModelsRequiringProcessNoise = {'randomWalk','firstOrderGaussMarkov'};
        % Per-common-source-name treatments that are refused BY NAME regardless of the generic
        % AllowedCommonSourceTreatments vocabulary check. Keyed by commonSourceName; each value
        % is a cell array of treatment words refused for that source.
        SourceTreatmentIncompatibilities = struct( ...
            'transmittedStateProduct',{{'covarianceGroup'}});
    end

    properties (SetAccess = immutable)
        covarianceGroupIdentifier (1,:) char
        commonSourceName (1,:) char
        treatment (1,:) char
        sourceProductIdentifier (1,:) char
        memberObservationIdentifiers (1,:) cell
        memberDeliveryIdentifiers (1,:) cell
        memberRowCount (1,1) double
        sharedCovarianceContribution_m2 (:,:) double
        temporalCovarianceModel (1,:) char
        correlationTime_s (1,1) double
        % processNoisePsd_m2PerS is always in m^2/s: unlike DistributedLinkCalibrationState
        % (whose stateKind can be a state-space delay in seconds), this class's
        % sharedCovarianceContribution_m2 is always measurement-space, so the units are fixed
        % and need no companion units field -- the name states them completely.
        processNoisePsd_m2PerS (1,1) double
        validFromEpoch_s (1,1) double
        validUntilEpoch_s (1,1) double
        externalProductIdentifier (1,:) char
    end

    methods
        function obj = CommonSourceCovarianceGroup(record)
            required = {'covarianceGroupIdentifier','commonSourceName','treatment', ...
                'sourceProductIdentifier','memberObservationIdentifiers', ...
                'memberDeliveryIdentifiers','memberRowCount','sharedCovarianceContribution_m2', ...
                'temporalCovarianceModel','correlationTime_s','processNoisePsd_m2PerS', ...
                'validFromEpoch_s','validUntilEpoch_s','externalProductIdentifier'};
            supplied = fieldnames(record);
            missing = setdiff(required,supplied);
            unknown = setdiff(supplied,required);
            if ~isempty(missing)
                error('CommonSourceCovarianceGroup:missingField', ...
                    'CommonSourceCovarianceGroup is missing %s.',missing{1});
            end
            if ~isempty(unknown)
                error('CommonSourceCovarianceGroup:unknownField', ...
                    'CommonSourceCovarianceGroup contains unsupported field %s.',unknown{1});
            end

            if ~((ischar(record.covarianceGroupIdentifier) || isstring(record.covarianceGroupIdentifier)) && ...
                    ~isempty(strtrim(char(record.covarianceGroupIdentifier))))
                error('CommonSourceCovarianceGroup:covarianceGroupIdentifier', ...
                    'covarianceGroupIdentifier must be nonempty text.');
            end

            names = revgnss.DistributedLinkProtocolContract.CommonSourceNames;
            if ~((ischar(record.commonSourceName) || isstring(record.commonSourceName)) && ...
                    any(strcmp(char(record.commonSourceName),names)))
                error('CommonSourceCovarianceGroup:commonSourceName', ...
                    'commonSourceName must be a frozen DistributedLinkProtocolContract common source.');
            end

            treatment = char(record.treatment);
            if any(strcmp(treatment,revgnss.CommonSourceCovarianceGroup.SchemaUnavailableTreatments))
                error('CommonSourceCovarianceGroup:ownerEstimatedTreatmentSchemaUnavailable', ...
                    ['treatment ''estimatedOwnerState'' is not expressible in the frozen v1 14-' ...
                    'component state/covariance schema (no product/calibration slot exists); ' ...
                    'widening the schema is Section 2.3/Stage-3 scope.']);
            end
            allowedTreatments = revgnss.DistributedLinkProtocolContract.AllowedCommonSourceTreatments;
            if ~any(strcmp(treatment,allowedTreatments))
                error('CommonSourceCovarianceGroup:treatment', ...
                    'treatment must be one of the frozen AllowedCommonSourceTreatments.');
            end
            incompatibilities = revgnss.CommonSourceCovarianceGroup.SourceTreatmentIncompatibilities;
            commonSourceName = char(record.commonSourceName);
            if isfield(incompatibilities,commonSourceName) && ...
                    any(strcmp(treatment,incompatibilities.(commonSourceName)))
                error('CommonSourceCovarianceGroup:sourceTreatmentIncompatible', ...
                    ['commonSourceName ''%s'' does not support treatment ''%s'' (see class header ' ...
                    'for why); declare a different treatment or widen the remote prior covariance ' ...
                    'instead.'],commonSourceName,treatment);
            end

            members = record.memberObservationIdentifiers;
            if ~iscell(members) || isempty(members) || ...
                    any(cellfun(@(v) ~(ischar(v)||isstring(v)) || isempty(strtrim(char(v))),members)) || ...
                    numel(unique(cellfun(@char,members,'UniformOutput',false))) ~= numel(members)
                error('CommonSourceCovarianceGroup:memberIdentifiers', ...
                    'memberObservationIdentifiers must be a nonempty cell of distinct nonempty identifiers.');
            end
            if ~iscell(record.memberDeliveryIdentifiers)
                error('CommonSourceCovarianceGroup:memberIdentifiers', ...
                    'memberDeliveryIdentifiers must be a cell array of text identifiers.');
            end
            if numel(members) >= 2 && strcmp(treatment,'rejected')
                error('CommonSourceCovarianceGroup:rejectedTreatmentForSharedGroup', ...
                    'A group with two or more members cannot use treatment=''rejected''.');
            end

            temporalModel = char(record.temporalCovarianceModel);
            if any(strcmp(temporalModel,revgnss.CommonSourceCovarianceGroup.ForbiddenTemporalCovarianceModels))
                error('CommonSourceCovarianceGroup:whiteNoiseTreatmentForbidden', ...
                    ['A declared common source may not be modelled as independent white noise on ' ...
                    'repeated rows (plan invariant 8).']);
            end
            allowedModels = revgnss.DistributedLinkCalibrationState.AllowedTemporalCovarianceModels;
            if ~any(strcmp(temporalModel,allowedModels))
                error('CommonSourceCovarianceGroup:temporalCovarianceModel', ...
                    'temporalCovarianceModel must be one of the frozen allowed models.');
            end

            if ~(isnumeric(record.validFromEpoch_s) && isscalar(record.validFromEpoch_s) && ...
                    isfinite(record.validFromEpoch_s) && isnumeric(record.validUntilEpoch_s) && ...
                    isscalar(record.validUntilEpoch_s) && isfinite(record.validUntilEpoch_s) && ...
                    record.validUntilEpoch_s >= record.validFromEpoch_s)
                error('CommonSourceCovarianceGroup:validityInterval', ...
                    ['validFromEpoch_s and validUntilEpoch_s must both be finite, with validUntil ' ...
                    'at or after validFrom. An unbounded interval is operationally equivalent to no ' ...
                    'validity interval at all.']);
            end

            m = record.memberRowCount;
            if ~(isnumeric(m) && isscalar(m) && isfinite(m) && m == round(m) && m >= 1)
                error('CommonSourceCovarianceGroup:sharedContribution', ...
                    'memberRowCount must be a positive integer.');
            end
            W = record.sharedCovarianceContribution_m2;
            if ~isequal(size(W),[m m]) || any(~isfinite(W(:))) || norm(W-W','fro') > 1e-10*max(1,norm(W,'fro')) || ...
                    min(eig((W+W')/2)) < -1e-10*max(1,norm(W,'fro'))
                error('CommonSourceCovarianceGroup:sharedContribution', ...
                    'sharedCovarianceContribution_m2 must be finite, symmetric, PSD, and memberRowCount-by-memberRowCount.');
            end

            externalEmpty = isempty(record.externalProductIdentifier);
            if strcmp(treatment,'externalCovarianceProduct')
                if externalEmpty
                    error('CommonSourceCovarianceGroup:externalProductExclusivity', ...
                        'treatment=''externalCovarianceProduct'' requires a non-empty externalProductIdentifier.');
                end
            elseif ~externalEmpty
                error('CommonSourceCovarianceGroup:externalProductExclusivity', ...
                    'externalProductIdentifier must be empty unless treatment=''externalCovarianceProduct''.');
            end

            processNoiseRequiredModel = any(strcmp(temporalModel,{'randomWalk','firstOrderGaussMarkov'}));
            if strcmp(temporalModel,'firstOrderGaussMarkov')
                if ~(isnumeric(record.correlationTime_s) && isscalar(record.correlationTime_s) && ...
                        isfinite(record.correlationTime_s) && record.correlationTime_s > 0)
                    error('CommonSourceCovarianceGroup:correlationTime', ...
                        'correlationTime_s must be finite and positive for firstOrderGaussMarkov.');
                end
            elseif ~processNoiseRequiredModel && ~(isnumeric(record.correlationTime_s) && isscalar(record.correlationTime_s))
                error('CommonSourceCovarianceGroup:correlationTime', ...
                    'correlationTime_s must be numeric even when not required.');
            end
            if processNoiseRequiredModel
                if ~(isnumeric(record.processNoisePsd_m2PerS) && isscalar(record.processNoisePsd_m2PerS) && ...
                        isfinite(record.processNoisePsd_m2PerS) && record.processNoisePsd_m2PerS >= 0)
                    error('CommonSourceCovarianceGroup:processNoise', ...
                        'processNoisePsd_m2PerS must be finite and nonnegative for the declared temporal model.');
                end
            elseif ~(isnumeric(record.processNoisePsd_m2PerS) && isscalar(record.processNoisePsd_m2PerS))
                error('CommonSourceCovarianceGroup:processNoise', ...
                    'processNoisePsd_m2PerS must be numeric even when not required.');
            end

            obj.covarianceGroupIdentifier = char(record.covarianceGroupIdentifier);
            obj.commonSourceName = char(record.commonSourceName);
            obj.treatment = treatment;
            obj.sourceProductIdentifier = char(record.sourceProductIdentifier);
            obj.memberObservationIdentifiers = cellfun(@char,members,'UniformOutput',false);
            obj.memberDeliveryIdentifiers = cellfun(@char,record.memberDeliveryIdentifiers,'UniformOutput',false);
            obj.memberRowCount = double(m);
            obj.sharedCovarianceContribution_m2 = (W+W')/2;
            obj.temporalCovarianceModel = temporalModel;
            obj.correlationTime_s = double(record.correlationTime_s);
            obj.processNoisePsd_m2PerS = double(record.processNoisePsd_m2PerS);
            obj.validFromEpoch_s = double(record.validFromEpoch_s);
            obj.validUntilEpoch_s = double(record.validUntilEpoch_s);
            obj.externalProductIdentifier = char(record.externalProductIdentifier);
        end
    end
end
