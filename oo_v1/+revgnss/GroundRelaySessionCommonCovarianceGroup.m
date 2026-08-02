classdef GroundRelaySessionCommonCovarianceGroup
    % GroundRelaySessionCommonCovarianceGroup  Plan Section 4.5 item 5: one immutable declaration
    % of one shared, seconds^2-domain uncertainty source for the classical relay TWSTFT session
    % processor (relay group delay, either station's terminal delay, or shared atmosphere).
    %
    % Sibling to revgnss.CommonSourceCovarianceGroup, NEVER isa-compatible with it and NEVER fed
    % into revgnss.ReciprocalTimeTransferCovarianceBuilder.sessionCommonModeBlock: that method is
    % isa-locked to revgnss.CommonSourceCovarianceGroup and reads
    % g.sharedCovarianceContribution_m2 BY NAME -- always METRES^2-domain
    % (revgnss.DirectReciprocalTimeTransferBuilder already explicitly refuses that class for
    % exactly this reason: this subsystem's own covarianceBlock is always seconds^2-domain,
    % feeding it through would silently label an m^2 quantity 's^2', the identical bug class
    % Section 4.2's own combined review caught as its blocking-1 finding). This class's own field
    % is named sharedCovarianceContribution_s2 -- the domain is stated in the name, matching
    % revgnss.ReciprocalLinkHardwareModel.calibrationCovariance_s2's own naming convention -- and
    % is fed instead to revgnss.ReciprocalTimeTransferCovarianceBuilder.relayBlock, a
    % domain-agnostic pass-through validated only for shape/symmetry/PSD (no unit-presupposing
    % field name at all), by revgnss.GroundRelayTimeTransferSessionBuilder.
    %
    % commonSourceName is its OWN closed vocabulary (AllowedCommonSourceNames below) --
    % deliberately NOT revgnss.DistributedLinkProtocolContract.CommonSourceNames: that vocabulary
    % belongs to the distributed-fleet link-update protocol (revgnss.IndependentFleetCoordinator/
    % revgnss.SplitCovarianceIntersectionBound), which this standalone, non-coordinator-routed
    % session processor is explicitly outside of (plan: "a separate session processor").
    %
    % temporalCovarianceModel reuses the EXISTING revgnss.DistributedLinkCalibrationState.
    % AllowedTemporalCovarianceModels vocabulary verbatim -- no new vocabulary word invented.
    % ForbiddenTemporalCovarianceModels={'whitePerRow'} is copied verbatim from
    % revgnss.CommonSourceCovarianceGroup (plan invariant 8: a declared common source may never
    % be modelled as independent white noise on repeated rows), constructor-enforced as a
    % mechanical proof, not merely a documented intent.

    properties (Constant)
        AllowedCommonSourceNames = { ...
            'relayGroupDelay','stationATerminalDelay','stationBTerminalDelay','sharedAtmosphere'};
        ForbiddenTemporalCovarianceModels = {'whitePerRow'};
    end

    properties (SetAccess = immutable)
        covarianceGroupIdentifier (1,:) char
        commonSourceName (1,:) char
        sharedCovarianceContribution_s2 (:,:) double
        memberRowCount (1,1) double
        temporalCovarianceModel (1,:) char
        correlationTime_s (1,1) double
        validFromEpoch_s (1,1) double
        validUntilEpoch_s (1,1) double
    end

    methods
        function obj = GroundRelaySessionCommonCovarianceGroup(record)
            required = {'covarianceGroupIdentifier','commonSourceName', ...
                'sharedCovarianceContribution_s2','memberRowCount','temporalCovarianceModel', ...
                'correlationTime_s','validFromEpoch_s','validUntilEpoch_s'};
            supplied = fieldnames(record);
            missing = setdiff(required,supplied);
            unknown = setdiff(supplied,required);
            if ~isempty(missing)
                error('GroundRelaySessionCommonCovarianceGroup:missingField', ...
                    'GroundRelaySessionCommonCovarianceGroup is missing %s.',missing{1});
            end
            if ~isempty(unknown)
                error('GroundRelaySessionCommonCovarianceGroup:unknownField', ...
                    'GroundRelaySessionCommonCovarianceGroup contains unsupported field %s.',unknown{1});
            end

            if isempty(strtrim(char(record.covarianceGroupIdentifier)))
                error('GroundRelaySessionCommonCovarianceGroup:covarianceGroupIdentifier', ...
                    'covarianceGroupIdentifier must be nonempty text.');
            end
            sourceName = char(record.commonSourceName);
            if ~any(strcmp(sourceName, ...
                    revgnss.GroundRelaySessionCommonCovarianceGroup.AllowedCommonSourceNames))
                error('GroundRelaySessionCommonCovarianceGroup:commonSourceName', ...
                    'commonSourceName must be one of the frozen AllowedCommonSourceNames.');
            end

            temporalModel = char(record.temporalCovarianceModel);
            if any(strcmp(temporalModel, ...
                    revgnss.GroundRelaySessionCommonCovarianceGroup.ForbiddenTemporalCovarianceModels))
                error('GroundRelaySessionCommonCovarianceGroup:whiteNoiseTreatmentForbidden', ...
                    ['A declared common source may not be modelled as independent white noise on ' ...
                    'repeated rows (plan invariant 8).']);
            end
            allowedModels = revgnss.DistributedLinkCalibrationState.AllowedTemporalCovarianceModels;
            if ~any(strcmp(temporalModel,allowedModels))
                error('GroundRelaySessionCommonCovarianceGroup:temporalCovarianceModel', ...
                    'temporalCovarianceModel must be one of the frozen allowed models.');
            end

            m = record.memberRowCount;
            if ~(isnumeric(m) && isscalar(m) && isfinite(m) && m == round(m) && m >= 1)
                error('GroundRelaySessionCommonCovarianceGroup:memberRowCount', ...
                    'memberRowCount must be a positive integer.');
            end
            W = record.sharedCovarianceContribution_s2;
            if ~isequal(size(W),[m m]) || any(~isfinite(W(:))) || ...
                    norm(W-W','fro') > 1e-15*max(1,norm(W,'fro')) || ...
                    min(eig((W+W')/2)) < -1e-15*max(1,norm(W,'fro'))
                error('GroundRelaySessionCommonCovarianceGroup:sharedContribution', ...
                    'sharedCovarianceContribution_s2 must be finite, symmetric, PSD, and memberRowCount-by-memberRowCount.');
            end

            if ~(isnumeric(record.validFromEpoch_s) && isscalar(record.validFromEpoch_s) && ...
                    isfinite(record.validFromEpoch_s) && isnumeric(record.validUntilEpoch_s) && ...
                    isscalar(record.validUntilEpoch_s) && isfinite(record.validUntilEpoch_s) && ...
                    record.validUntilEpoch_s >= record.validFromEpoch_s)
                error('GroundRelaySessionCommonCovarianceGroup:validityInterval', ...
                    'validFromEpoch_s and validUntilEpoch_s must both be finite, with validUntil at or after validFrom.');
            end
            if strcmp(temporalModel,'firstOrderGaussMarkov')
                if ~(isnumeric(record.correlationTime_s) && isscalar(record.correlationTime_s) && ...
                        isfinite(record.correlationTime_s) && record.correlationTime_s > 0)
                    error('GroundRelaySessionCommonCovarianceGroup:correlationTime', ...
                        'correlationTime_s must be finite and positive for firstOrderGaussMarkov.');
                end
            elseif ~(isnumeric(record.correlationTime_s) && isscalar(record.correlationTime_s))
                error('GroundRelaySessionCommonCovarianceGroup:correlationTime', ...
                    'correlationTime_s must be numeric even when not required by the temporal model.');
            end

            obj.covarianceGroupIdentifier = char(record.covarianceGroupIdentifier);
            obj.commonSourceName = sourceName;
            obj.sharedCovarianceContribution_s2 = (W+W')/2;
            obj.memberRowCount = double(m);
            obj.temporalCovarianceModel = temporalModel;
            obj.correlationTime_s = double(record.correlationTime_s);
            obj.validFromEpoch_s = double(record.validFromEpoch_s);
            obj.validUntilEpoch_s = double(record.validUntilEpoch_s);
        end
    end
end
