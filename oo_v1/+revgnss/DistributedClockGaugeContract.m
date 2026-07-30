classdef DistributedClockGaugeContract
    % DistributedClockGaugeContract  Frozen Stage-2 clock/gauge/time-alignment guard layer (plan
    % Section 2.4), adapter-agnostic like revgnss.DistributedLinkProtocolContract.
    %
    % This section enables NOTHING new: revgnss.DistributedLinkUpdateAdapter.AllowedObservables
    % and RegisteredAdapterClasses are untouched, so a time-transfer record still cannot be
    % delivered end-to-end (a dedicated test proves this). What it adds is live TODAY on the
    % existing 'coherentTwoWayCodeRange' path (every real delivery now carries a certified clock
    % audit) and complete for a future 'firstOrderReciprocalClockTransfer' adapter to call into,
    % mirroring how Sections 2.0-2.2 built machinery before Section 2.3.1's adapter existed.
    %
    % The audit performed here is a structural/declarative anchor audit plus a rank certificate
    % on the 2-dimensional [b_owner, b_remote] clock subspace. It is deliberately NOT a fleet-
    % wide clock observability Gramian -- that requires the Stage-3 cross-covariance network.
    %
    % One physical point drives the whole design: a finite prior clock variance is NOT an
    % anchor. Every leaf's clock-bias prior variance is finite because P0 is finite; that says
    % nothing about whether the clock is tied to a stated datum. The anchor is a DECLARED,
    % config-derived property (revgnss.EndpointClockAnchorDeclaration); the numerical rank
    % certificate below is only a cross-check of it, never a substitute.

    properties (Constant)
        % A new observable MUST be added here or every guard below refuses it (invariant 6).
        % 'none' mirrors DistributedLinkUpdateAdapter.requireRecordClassSupportedForObservable's
        % own precedent of treating 'none' as a generic, adapter-free placeholder (used by
        % pre-Section-2.3.1 tests to exercise delivery mechanics unrelated to any specific
        % observable's physics) -- it is vacuously not a clock observable, never reaching a
        % relativeBiasOnly-specific check.
        ClockClaimByObservable = struct( ...
            'none','notAClockObservable', ...
            'coherentTwoWayCodeRange','notAClockObservable', ...
            'firstOrderReciprocalClockTransfer','relativeBiasOnly');
        AllowedClockClaims = {'notAClockObservable','relativeBiasOnly'};
        RelativeBiasSignConvention = 'remoteMinusOwner';
        CommonModeBlindnessTolerance = 1e-9;
        MinimumEndpointSeparation_m = 1;
        RemoteStateProvenanceKinds = { ...
            'frozenSameEpochPeerEstimate','supportedDelayedProduct','externalProduct'};
        ReachableRemoteStateProvenanceKinds = {'frozenSameEpochPeerEstimate'};
        SupportedTimeTransferModes = {'firstOrderReciprocal'};
    end

    methods (Static)
        function clockClaim = requireObservableClockClaimDeclared(observableIdentifier)
            observableIdentifier = char(observableIdentifier);
            byObservable = revgnss.DistributedClockGaugeContract.ClockClaimByObservable;
            if ~isfield(byObservable,observableIdentifier)
                error('DistributedClockGaugeContract:observableClockClaimUndeclared', ...
                    'Observable ''%s'' has no declared clock claim.',observableIdentifier);
            end
            clockClaim = byObservable.(observableIdentifier);
            if ~any(strcmp(clockClaim,revgnss.DistributedClockGaugeContract.AllowedClockClaims))
                error('DistributedClockGaugeContract:observableClockClaimUndeclared', ...
                    'Observable ''%s'' declares an unrecognised clock claim.',observableIdentifier);
            end
        end

        function requireEndpointPairTimeFrameDatumCompatible(ownerState, remoteState)
            if ~isa(ownerState,'revgnss.CommunicationEndpointState') || ...
                    ~isa(remoteState,'revgnss.CommunicationEndpointState')
                error('DistributedClockGaugeContract:endpointStateType', ...
                    'requireEndpointPairTimeFrameDatumCompatible requires two CommunicationEndpointStates.');
            end
            if ~strcmp(ownerState.coordinateTimeScale,remoteState.coordinateTimeScale)
                error('DistributedClockGaugeContract:coordinateTimeScaleMismatch', ...
                    'Owner and remote endpoint coordinate time scales do not match.');
            end
            if ~strcmp(ownerState.frameIdentifier,remoteState.frameIdentifier)
                error('DistributedClockGaugeContract:frameIdentifierMismatch', ...
                    'Owner and remote endpoint frame identifiers do not match.');
            end
            if ~strcmp(ownerState.clockDatumIdentifier,remoteState.clockDatumIdentifier)
                error('DistributedClockGaugeContract:clockDatumMismatch', ...
                    'Owner and remote endpoint clock datum identifiers do not match.');
            end
            if ~strcmp(ownerState.stateSchemaVersion,remoteState.stateSchemaVersion)
                error('DistributedClockGaugeContract:stateSchemaVersionMismatch', ...
                    'Owner and remote endpoint state schema versions do not match.');
            end
        end

        function summary = requireDeclaredClockAnchorPair(ownerState, remoteState, clockClaim)
            if ~isa(ownerState,'revgnss.CommunicationEndpointState') || ...
                    ~isa(remoteState,'revgnss.CommunicationEndpointState')
                error('DistributedClockGaugeContract:endpointStateType', ...
                    'requireDeclaredClockAnchorPair requires two CommunicationEndpointStates.');
            end
            ownerDecl = ownerState.clockAnchorDeclaration;
            remoteDecl = remoteState.clockAnchorDeclaration;
            if ~isa(ownerDecl,'revgnss.EndpointClockAnchorDeclaration') || ...
                    ~isa(remoteDecl,'revgnss.EndpointClockAnchorDeclaration')
                error('DistributedClockGaugeContract:clockAnchorUndeclared', ...
                    'Both endpoints must carry a revgnss.EndpointClockAnchorDeclaration.');
            end
            ownerAnchored = ownerDecl.isAbsolutelyAnchored();
            remoteAnchored = remoteDecl.isAbsolutelyAnchored();
            pairAbsolutelyAnchored = ownerAnchored || remoteAnchored;

            if strcmp(char(clockClaim),'relativeBiasOnly')
                if ~pairAbsolutelyAnchored
                    error('DistributedClockGaugeContract:unanchoredClockPair', ...
                        ['A relativeBiasOnly row between two unanchored endpoints has no ' ...
                        'stated datum on either side; radial/clock degeneracy makes injecting ' ...
                        'it into an absolute clock state unsafe. At least one endpoint must be ' ...
                        'absolutely anchored.']);
                end
                if ownerAnchored && remoteAnchored && ...
                        ~strcmp(ownerDecl.anchorDatumIdentifier,remoteDecl.anchorDatumIdentifier)
                    error('DistributedClockGaugeContract:clockAnchorDatumMismatch', ...
                        ['Owner and remote endpoints are anchored to different datums ' ...
                        '(''%s'' vs ''%s''); a relativeBiasOnly row cannot bridge two distinct ' ...
                        'stated clock datums.'],ownerDecl.anchorDatumIdentifier, ...
                        remoteDecl.anchorDatumIdentifier);
                end
            end
            % Anchor-datum equality is NOT enforced for a non-clock observable: a two-way range
            % between endpoints on different clock datums is physically fine (the biases cancel
            % in the round-trip formula). Recorded for reporting, never rejected, here.

            pairAnchorDatumIdentifier = revgnss.EndpointClockAnchorDeclaration.UndeclaredDatumIdentifier;
            if ownerAnchored
                pairAnchorDatumIdentifier = ownerDecl.anchorDatumIdentifier;
            elseif remoteAnchored
                pairAnchorDatumIdentifier = remoteDecl.anchorDatumIdentifier;
            end
            summary = struct( ...
                'ownerAnchorKind',ownerDecl.anchorKind, ...
                'remoteAnchorKind',remoteDecl.anchorKind, ...
                'pairAnchorDatumIdentifier',pairAnchorDatumIdentifier, ...
                'pairAbsolutelyAnchored',pairAbsolutelyAnchored, ...
                'ownerAnchored',ownerAnchored, ...
                'remoteAnchored',remoteAnchored);
        end

        function delay_s = requireEndpointPropagationDelayValid(ownerState, remoteState, record)
            if ~isa(ownerState,'revgnss.CommunicationEndpointState') || ...
                    ~isa(remoteState,'revgnss.CommunicationEndpointState')
                error('DistributedClockGaugeContract:endpointStateType', ...
                    'requireEndpointPropagationDelayValid requires two CommunicationEndpointStates.');
            end
            separation_m = norm(remoteState.positionEcef_m-ownerState.positionEcef_m);
            minSeparation_m = revgnss.DistributedClockGaugeContract.MinimumEndpointSeparation_m;
            if ~isfinite(separation_m) || separation_m < minSeparation_m
                error('DistributedClockGaugeContract:propagationDelayInvalid', ...
                    'Endpoint separation must be finite and at least %g m.',minSeparation_m);
            end
            delay_s = NaN;
            if isprop(record,'measuredLocalRoundTripDelay_s')
                delay_s = record.measuredLocalRoundTripDelay_s;
                if ~(isfinite(delay_s) && delay_s > 0)
                    error('DistributedClockGaugeContract:propagationDelayInvalid', ...
                        'measuredLocalRoundTripDelay_s must be finite and positive.');
                end
            end
        end

        function requireTimeTransferRecordTimeAlignment(record, deliveryEpoch_s, coordinateEventEpoch_s)
            if ~isprop(record,'referenceEpoch_s')
                error('DistributedClockGaugeContract:timestampMismatch', ...
                    'A time-transfer record must declare referenceEpoch_s.');
            end
            if record.referenceEpoch_s ~= deliveryEpoch_s || ...
                    record.referenceEpoch_s ~= coordinateEventEpoch_s
                error('DistributedClockGaugeContract:timestampMismatch', ...
                    ['The record reference epoch must equal both the delivery epoch and the ' ...
                    'coordinate event epoch.']);
            end
            if isprop(record,'rawTimestampTagsAvailable') && record.rawTimestampTagsAvailable
                error('DistributedClockGaugeContract:rawTimestampTagsClaimUnsupported', ...
                    'A raw four-timestamp claim is not supported; only firstOrderReciprocal is.');
            end
            if isprop(record,'modeIdentifier')
                allowed = revgnss.DistributedClockGaugeContract.SupportedTimeTransferModes;
                if ~any(strcmp(char(record.modeIdentifier),allowed))
                    error('DistributedClockGaugeContract:timeTransferModeUnsupported', ...
                        'Time-transfer mode ''%s'' is not supported.',char(record.modeIdentifier));
                end
            end
        end

        function requireTimeTransferCalibrationProvenance(record, persistentCalibrationTreatment, ...
                calibrationRegistry, cfg)
            hasValidityInterval = isprop(record,'calibrationValidFromLocalTag_s') && ...
                isprop(record,'calibrationValidUntilLocalTag_s');
            if ~hasValidityInterval
                error('DistributedClockGaugeContract:calibrationValidityMissing', ...
                    ['A time-transfer delivery requires a declared calibration validity ' ...
                    'interval; this record type does not carry one.']);
            end
            treatment = char(persistentCalibrationTreatment);
            if strcmp(treatment,'rejected')
                paths = revgnss.DistributedClockGaugeContract.TimeTransferPersistentDelayConfigPaths_();
                for index = 1:numel(paths)
                    value = revgnss.DistributedClockGaugeContract.field_(cfg,paths{index},0);
                    if (islogical(value) && value) || (isnumeric(value) && value ~= 0)
                        error('DistributedClockGaugeContract:persistentTimeTransferDelayUnowned', ...
                            ['persistentCalibrationTreatment=''rejected'' requires %s to be ' ...
                            'absent or exactly zero.'],strjoin(paths{index},'.'));
                    end
                end
                return
            end
            if ~strcmp(treatment,'externalCalibrationProduct')
                error('DistributedClockGaugeContract:calibrationTemporalProvenanceMissing', ...
                    'Unsupported persistentCalibrationTreatment for a time-transfer delivery.');
            end
            if isempty(calibrationRegistry) || ...
                    ~isa(calibrationRegistry,'revgnss.DistributedLinkCalibrationRegistry')
                error('DistributedClockGaugeContract:calibrationTemporalProvenanceMissing', ...
                    'externalCalibrationProduct requires a revgnss.DistributedLinkCalibrationRegistry.');
            end
            ids = record.calibrationProductIdentifiers;
            allowedModels = {'randomWalk','firstOrderGaussMarkov','externalProductCovariance'};
            for index = 1:numel(ids)
                declaration = calibrationRegistry.ownerFor(ids{index});
                if ~any(strcmp(declaration.temporalCovarianceModel,allowedModels))
                    error('DistributedClockGaugeContract:calibrationTemporalProvenanceMissing', ...
                        ['Calibration state %s must declare a temporal covariance model ' ...
                        '(randomWalk, firstOrderGaussMarkov, or externalProductCovariance).'], ...
                        ids{index});
                end
                if ~declaration.coversLocalTag(record.referenceLocalClockTag_s)
                    error('DistributedClockGaugeContract:calibrationTemporalProvenanceMissing', ...
                        'Calibration state %s does not cover this record''s reference local tag.', ...
                        ids{index});
                end
            end
        end

        function kind = requireRemoteStateProvenance(remoteState)
            if ~isa(remoteState,'revgnss.CommunicationEndpointState')
                error('DistributedClockGaugeContract:endpointStateType', ...
                    'requireRemoteStateProvenance requires a CommunicationEndpointState.');
            end
            sourceKind = '';
            if isstruct(remoteState.productProvenance) && ...
                    isfield(remoteState.productProvenance,'sourceKind')
                sourceKind = char(remoteState.productProvenance.sourceKind);
            end
            switch sourceKind
                case 'estimatorEligibleProduct'
                    kind = 'frozenSameEpochPeerEstimate';
                case 'ownerLocalEstimator'
                    % An owner state is never itself the "remote" side of a delivery in
                    % production (propose() always binds a FrozenProductEndpointProvider as
                    % remote), but the check is defined for any CommunicationEndpointState so a
                    % test can exercise it directly.
                    kind = 'frozenSameEpochPeerEstimate';
                otherwise
                    error('DistributedClockGaugeContract:remoteStateProvenanceUndeclared', ...
                        'productProvenance.sourceKind ''%s'' is not a recognised remote-state source.', ...
                        sourceKind);
            end
            if ~any(strcmp(kind, ...
                    revgnss.DistributedClockGaugeContract.ReachableRemoteStateProvenanceKinds))
                error('DistributedClockGaugeContract:remoteStateProvenanceUnsupported', ...
                    'Remote state provenance ''%s'' is not reachable today.',kind);
            end
        end

        function audit = clockObservabilityAudit(ownerState, remoteState, H_owner, H_remote, ...
                Rind_m2, observableIdentifier, anchorSummary)
            % clockObservabilityAudit  Pure compute: builds and returns a validated
            % revgnss.DistributedClockObservabilityAudit. H_owner/H_remote are full-state
            % Jacobian ROW vectors in the endpoints' own covarianceComponentOrder; Rind_m2 is the
            % scalar independent measurement variance.
            clockClaim = revgnss.DistributedClockGaugeContract.requireObservableClockClaimDeclared( ...
                observableIdentifier);
            if size(H_owner,1) ~= 1 || size(H_remote,1) ~= 1 || ~isscalar(Rind_m2)
                error('DistributedClockGaugeContract:jacobianShape', ...
                    ['clockObservabilityAudit requires single-row owner/remote Jacobians and a ' ...
                    'scalar independent measurement variance; every registered adapter today is ' ...
                    'scalar single-row, and a multi-row observable needs its own per-row audit, ' ...
                    'not a silent column misread.']);
            end

            ownerBiasCol = revgnss.DistributedClockGaugeContract.columnFor_( ...
                H_owner,ownerState.covarianceComponentOrder,'clockBiasError_m');
            remoteBiasCol = revgnss.DistributedClockGaugeContract.columnFor_( ...
                H_remote,remoteState.covarianceComponentOrder,'clockBiasError_m');
            ownerDriftCol = revgnss.DistributedClockGaugeContract.columnFor_( ...
                H_owner,ownerState.covarianceComponentOrder,'clockDriftError_mps');
            remoteDriftCol = revgnss.DistributedClockGaugeContract.columnFor_( ...
                H_remote,remoteState.covarianceComponentOrder,'clockDriftError_mps');

            commonMode = ownerBiasCol+remoteBiasCol;
            differentialMode = remoteBiasCol-ownerBiasCol;
            g = [ownerBiasCol,remoteBiasCol];
            rowInfo = (g'*g)/Rind_m2;
            % A genuinely RELATIVE tolerance (no absolute 1e-9 m^-2 floor): rowInfo's own scale
            % swings by orders of magnitude with Rind_m2 (thermal-noise variance for a real
            % observable, not a dimensionless quantity), so clamping the scale against a bare "1"
            % would inject an absolute floor with the wrong units and could flip the rank verdict
            % on measurement-noise magnitude alone rather than on the row's actual structure.
            rowRank = rank(rowInfo,1e-9*norm(rowInfo,'fro'));
            if all(abs(g) < 1e-12)
                nullDirection = [1;1]/sqrt(2);
            else
                nullDirection = [-g(2);g(1)];
                nullDirection = nullDirection/norm(nullDirection);
            end

            ownerBiasVar_m2 = ownerState.covarianceBlock( ...
                revgnss.DistributedClockGaugeContract.indexFor_( ...
                ownerState.covarianceComponentOrder,'clockBiasError_m'), ...
                revgnss.DistributedClockGaugeContract.indexFor_( ...
                ownerState.covarianceComponentOrder,'clockBiasError_m'));
            remoteBiasVar_m2 = remoteState.covarianceBlock( ...
                revgnss.DistributedClockGaugeContract.indexFor_( ...
                remoteState.covarianceComponentOrder,'clockBiasError_m'), ...
                revgnss.DistributedClockGaugeContract.indexFor_( ...
                remoteState.covarianceComponentOrder,'clockBiasError_m'));

            pairInfo = rowInfo;
            if anchorSummary.ownerAnchored
                if ~(isfinite(ownerBiasVar_m2) && ownerBiasVar_m2 > 0)
                    error('DistributedClockGaugeContract:priorVarianceInvalid', ...
                        'ownerClockBiasPriorVariance_m2 must be finite and strictly positive.');
                end
                pairInfo(1,1) = pairInfo(1,1)+1/ownerBiasVar_m2;
            end
            if anchorSummary.remoteAnchored
                if ~(isfinite(remoteBiasVar_m2) && remoteBiasVar_m2 > 0)
                    error('DistributedClockGaugeContract:priorVarianceInvalid', ...
                        'remoteClockBiasPriorVariance_m2 must be finite and strictly positive.');
                end
                pairInfo(2,2) = pairInfo(2,2)+1/remoteBiasVar_m2;
            end
            pairRank = rank(pairInfo,1e-9*norm(pairInfo,'fro'));
            singularValues = svd(pairInfo);
            if singularValues(end) > 0
                pairCond = singularValues(1)/singularValues(end);
            else
                pairCond = Inf;
            end

            verdict = 'notAClockObservable';
            if strcmp(clockClaim,'relativeBiasOnly')
                verdict = 'relativeBiasOnlyCertified';
            end

            record = struct( ...
                'observableIdentifier',char(observableIdentifier), ...
                'clockClaim',clockClaim, ...
                'ownerClockBiasColumn_mPerM',ownerBiasCol, ...
                'remoteClockBiasColumn_mPerM',remoteBiasCol, ...
                'ownerClockDriftColumn_mPerMps',ownerDriftCol, ...
                'remoteClockDriftColumn_mPerMps',remoteDriftCol, ...
                'commonModeSensitivity_mPerM',commonMode, ...
                'differentialModeSensitivity_mPerM',differentialMode, ...
                'rowClockInformationRank',rowRank, ...
                'rowClockNullSpaceDirection',nullDirection, ...
                'ownerAnchorKind',anchorSummary.ownerAnchorKind, ...
                'remoteAnchorKind',anchorSummary.remoteAnchorKind, ...
                'pairAnchorDatumIdentifier',anchorSummary.pairAnchorDatumIdentifier, ...
                'pairAbsolutelyAnchored',anchorSummary.pairAbsolutelyAnchored, ...
                'ownerClockBiasPriorVariance_m2',ownerBiasVar_m2, ...
                'remoteClockBiasPriorVariance_m2',remoteBiasVar_m2, ...
                'independentMeasurementCovariance_m2',Rind_m2, ...
                'pairClockInformationRank',pairRank, ...
                'pairClockInformationConditionNumber',pairCond, ...
                'absoluteClaimPermitted',anchorSummary.pairAbsolutelyAnchored, ...
                'auditVerdict',verdict);
            audit = revgnss.DistributedClockObservabilityAudit.fromValidatedRecord(record);
        end

        function audit = requireClockObservability(block, delivery, ownerState, remoteState, clockClaim)
            if ~isa(block,'revgnss.DistributedLinkUpdateBlock')
                error('DistributedClockGaugeContract:blockType', ...
                    'requireClockObservability requires a revgnss.DistributedLinkUpdateBlock.');
            end
            anchorSummary = revgnss.DistributedClockGaugeContract.requireDeclaredClockAnchorPair( ...
                ownerState,remoteState,clockClaim);
            audit = revgnss.DistributedClockGaugeContract.clockObservabilityAudit( ...
                ownerState,remoteState,block.ownerJacobian_mPerErrorUnit, ...
                block.remoteJacobian_mPerErrorUnit,block.independentMeasurementCovariance_m2, ...
                delivery.observableIdentifier,anchorSummary);
        end
    end

    methods (Static, Access = private)
        function paths = TimeTransferPersistentDelayConfigPaths_()
            paths = { ...
                {'measurements','isl','twoWay','timeTransfer','calibration','terminalDelayError_s'}, ...
                {'measurements','isl','twoWay','timeTransfer','calibration','terminalSigma_s'}, ...
                {'measurements','isl','twoWay','truth','terminalCalibrationError_s'}, ...
                {'measurements','isl','twoWay','calibration','terminalSigma_s'}};
        end

        function index = indexFor_(covarianceComponentOrder, label)
            index = find(strcmp(covarianceComponentOrder,label),1);
            if isempty(index)
                error('DistributedClockGaugeContract:covarianceComponentLabelMissing', ...
                    'covarianceComponentOrder does not declare ''%s''.',label);
            end
        end

        function value = columnFor_(H, covarianceComponentOrder, label)
            index = revgnss.DistributedClockGaugeContract.indexFor_(covarianceComponentOrder,label);
            value = H(1,index);
        end

        function value = field_(s,path,defaultValue)
            value = s;
            for index = 1:numel(path)
                if ~isstruct(value) || ~isfield(value,path{index})
                    value = defaultValue;
                    return
                end
                value = value.(path{index});
            end
            if isstring(value); value = char(value); end
        end
    end
end
