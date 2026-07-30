classdef DistributedClockObservabilityAudit
    % DistributedClockObservabilityAudit  Immutable validated result of a Section 2.4 clock
    % observability audit for one candidate link update (the revgnss.OwnerPosteriorBoundResult
    % idiom: the certificate is validated once, at construction, so it cannot be self-
    % contradictory downstream). Built only by revgnss.DistributedClockGaugeContract.

    properties (Constant)
        AllowedAuditVerdicts = {'relativeBiasOnlyCertified','notAClockObservable'};
    end

    properties (SetAccess = immutable)
        observableIdentifier (1,:) char
        clockClaim (1,:) char
        ownerClockBiasColumn_mPerM (1,1) double
        remoteClockBiasColumn_mPerM (1,1) double
        ownerClockDriftColumn_mPerMps (1,1) double
        remoteClockDriftColumn_mPerMps (1,1) double
        commonModeSensitivity_mPerM (1,1) double
        differentialModeSensitivity_mPerM (1,1) double
        rowClockInformationRank (1,1) double
        rowClockNullSpaceDirection (2,1) double
        ownerAnchorKind (1,:) char
        remoteAnchorKind (1,:) char
        pairAnchorDatumIdentifier (1,:) char
        pairAbsolutelyAnchored (1,1) logical
        ownerClockBiasPriorVariance_m2 (1,1) double
        remoteClockBiasPriorVariance_m2 (1,1) double
        independentMeasurementCovariance_m2 (1,1) double
        pairClockInformationRank (1,1) double
        pairClockInformationConditionNumber (1,1) double
        absoluteClaimPermitted (1,1) logical
        auditVerdict (1,:) char
        rowUnits (1,:) char
    end

    methods (Access = private)
        function obj = DistributedClockObservabilityAudit(record)
            required = {'observableIdentifier','clockClaim','ownerClockBiasColumn_mPerM', ...
                'remoteClockBiasColumn_mPerM','ownerClockDriftColumn_mPerMps', ...
                'remoteClockDriftColumn_mPerMps','commonModeSensitivity_mPerM', ...
                'differentialModeSensitivity_mPerM','rowClockInformationRank', ...
                'rowClockNullSpaceDirection','ownerAnchorKind','remoteAnchorKind', ...
                'pairAnchorDatumIdentifier','pairAbsolutelyAnchored', ...
                'ownerClockBiasPriorVariance_m2','remoteClockBiasPriorVariance_m2', ...
                'independentMeasurementCovariance_m2','pairClockInformationRank', ...
                'pairClockInformationConditionNumber','absoluteClaimPermitted','auditVerdict', ...
                'rowUnits'};
            supplied = fieldnames(record);
            missing = setdiff(required,supplied);
            unknown = setdiff(supplied,required);
            if ~isempty(missing)
                error('DistributedClockObservabilityAudit:missingField', ...
                    'DistributedClockObservabilityAudit is missing %s.',missing{1});
            end
            if ~isempty(unknown)
                error('DistributedClockObservabilityAudit:unknownField', ...
                    'DistributedClockObservabilityAudit contains unsupported field %s.',unknown{1});
            end
            if ~any(strcmp(char(record.auditVerdict), ...
                    revgnss.DistributedClockObservabilityAudit.AllowedAuditVerdicts))
                error('DistributedClockObservabilityAudit:auditVerdict', ...
                    'auditVerdict must be a frozen allowed verdict.');
            end
            if ~any(strcmp(char(record.rowUnits),revgnss.DistributedLinkUpdateAdapter.AllowedRowUnits))
                error('DistributedClockObservabilityAudit:rowUnits', ...
                    'rowUnits must be one of the frozen allowed row units.');
            end

            % absoluteClaimPermitted can NEVER be looser than the declarative anchor fact: a
            % caller cannot report an absolute clock result just because the numbers happen to
            % look observable (plan Section 2.4 requirement 2 -- never convert relative into
            % absolute without a stated datum).
            if record.absoluteClaimPermitted ~= record.pairAbsolutelyAnchored
                error('DistributedClockObservabilityAudit:absoluteClaimNotPermitted', ...
                    ['absoluteClaimPermitted must equal pairAbsolutelyAnchored exactly; an ' ...
                    'absolute clock claim may never be permitted for an unanchored pair, ' ...
                    'however well-conditioned the numerical information happens to be.']);
            end

            if strcmp(char(record.auditVerdict),'relativeBiasOnlyCertified')
                if ~strcmp(char(record.clockClaim),'relativeBiasOnly')
                    error('DistributedClockObservabilityAudit:verdictInconsistentWithAnchoring', ...
                        'relativeBiasOnlyCertified requires clockClaim=''relativeBiasOnly''.');
                end
                if record.ownerClockDriftColumn_mPerMps ~= 0 || ...
                        record.remoteClockDriftColumn_mPerMps ~= 0
                    error('DistributedClockObservabilityAudit:verdictInconsistentWithAnchoring', ...
                        'relativeBiasOnlyCertified requires both drift-column sensitivities to be exactly 0.');
                end
                scale = max(1,abs(record.differentialModeSensitivity_mPerM));
                tolerance = revgnss.DistributedClockGaugeContract.CommonModeBlindnessTolerance;
                if abs(record.commonModeSensitivity_mPerM) > tolerance*scale
                    error('DistributedClockObservabilityAudit:verdictInconsistentWithAnchoring', ...
                        'relativeBiasOnlyCertified requires the row to be common-mode blind.');
                end
                if record.rowClockInformationRank ~= 1
                    error('DistributedClockObservabilityAudit:verdictInconsistentWithAnchoring', ...
                        'relativeBiasOnlyCertified requires rowClockInformationRank==1.');
                end
                % The owner-negative/remote-positive check below IS the remoteMinusOwner
                % convention; the assertion makes that binding explicit, so a future change to
                % the frozen contract constant cannot silently drift out of sync with this check.
                if ~strcmp(revgnss.DistributedClockGaugeContract.RelativeBiasSignConvention, ...
                        'remoteMinusOwner')
                    error('DistributedClockObservabilityAudit:signConventionUnrecognised', ...
                        'DistributedClockGaugeContract.RelativeBiasSignConvention has no known check.');
                end
                if ~(record.ownerClockBiasColumn_mPerM < 0 && record.remoteClockBiasColumn_mPerM > 0)
                    error('DistributedClockObservabilityAudit:verdictInconsistentWithAnchoring', ...
                        ['relativeBiasOnlyCertified requires the documented remoteMinusOwner sign ' ...
                        'convention (owner column negative, remote column positive).']);
                end
            elseif strcmp(char(record.clockClaim),'relativeBiasOnly')
                error('DistributedClockObservabilityAudit:verdictInconsistentWithAnchoring', ...
                    'clockClaim=''relativeBiasOnly'' requires auditVerdict=''relativeBiasOnlyCertified''.');
            end

            obj.observableIdentifier = char(record.observableIdentifier);
            obj.clockClaim = char(record.clockClaim);
            obj.ownerClockBiasColumn_mPerM = double(record.ownerClockBiasColumn_mPerM);
            obj.remoteClockBiasColumn_mPerM = double(record.remoteClockBiasColumn_mPerM);
            obj.ownerClockDriftColumn_mPerMps = double(record.ownerClockDriftColumn_mPerMps);
            obj.remoteClockDriftColumn_mPerMps = double(record.remoteClockDriftColumn_mPerMps);
            obj.commonModeSensitivity_mPerM = double(record.commonModeSensitivity_mPerM);
            obj.differentialModeSensitivity_mPerM = double(record.differentialModeSensitivity_mPerM);
            obj.rowClockInformationRank = double(record.rowClockInformationRank);
            obj.rowClockNullSpaceDirection = record.rowClockNullSpaceDirection(:);
            obj.ownerAnchorKind = char(record.ownerAnchorKind);
            obj.remoteAnchorKind = char(record.remoteAnchorKind);
            obj.pairAnchorDatumIdentifier = char(record.pairAnchorDatumIdentifier);
            obj.pairAbsolutelyAnchored = logical(record.pairAbsolutelyAnchored);
            obj.ownerClockBiasPriorVariance_m2 = double(record.ownerClockBiasPriorVariance_m2);
            obj.remoteClockBiasPriorVariance_m2 = double(record.remoteClockBiasPriorVariance_m2);
            obj.independentMeasurementCovariance_m2 = double(record.independentMeasurementCovariance_m2);
            obj.pairClockInformationRank = double(record.pairClockInformationRank);
            obj.pairClockInformationConditionNumber = double(record.pairClockInformationConditionNumber);
            obj.absoluteClaimPermitted = logical(record.absoluteClaimPermitted);
            obj.auditVerdict = char(record.auditVerdict);
            obj.rowUnits = char(record.rowUnits);
        end
    end

    methods (Static)
        function obj = fromValidatedRecord(record)
            % fromValidatedRecord  The one non-private construction entry point, used only by
            % revgnss.DistributedClockGaugeContract (which performs the actual numeric work in
            % clockObservabilityAudit and is the sole intended caller). Kept as a distinct named
            % static method, rather than widening constructor access, so the private-construction
            % discipline documented above is never accidentally relaxed by an unrelated caller.
            obj = revgnss.DistributedClockObservabilityAudit(record);
        end
    end
end
