classdef DistributedLinkProtocolContract
    % DistributedLinkProtocolContract  Frozen Stage-2 protocol contract (plan Section 2.0).
    %
    % This class freezes the decisions Section 2.0 requires before any observable adapter
    % (Section 2.3) is allowed to update a local EKF: the coordinate time scale, frame,
    % clock datum/gauge, state-schema version, attitude-error coordinate convention, the
    % common-information vocabulary, and the time-transfer clock claim. It implements no
    % estimator update and changes no runtime behaviour. distributedEstimator.linkUpdate.enable
    % was unconditionally rejected by revgnss.IndependentFleetCoordinator.validateConfig at the
    % time this class was first written; Stage 2.3.1 removed that blanket guard and linkUpdate is
    % now a real, exercised live path (see e.g. tests/test_independent_fleet_synchronized_pair_
    % live_path.m) -- this header is left describing the class's own scope (the frozen
    % Stage-2.0 protocol contract), not the coordinator's current gating.

    properties (Constant)
        % CoordinateTimeScale, FrameIdentifier, and ClockDatumIdentifier name the single
        % simulator-wide assumption each existing Stage-1 product already relies on, since no
        % product or record carries these as an explicit tag yet (EndpointStateProduct rejects
        % unknown fields, so it structurally cannot). Each is enforced today only implicitly:
        %   CoordinateTimeScale -- EndpointStateProduct.fromLocalEstimator requires
        %     sourceEpoch_s to equal the local simulation's own tVec(epoch) value
        %     (EndpointStateProduct.m, 'sourceEpoch' check); there is one time scale per run.
        %   FrameIdentifier -- baked into the state label suffixes themselves
        %     ('...EcefX_m' etc.); requireStateSchemaVersion below fails if that ever drifts.
        %   ClockDatumIdentifier -- the receiver clock bias/drift pair is the only clock state
        %     EndpointStateProduct exports (clockBias_m/clockDrift_mps); there is exactly one
        %     clock gauge in play, again enforced by requireStateSchemaVersion.
        % A future Section 2.1 estimator-eligible publication profile must carry these as
        % explicit fields rather than relying on this implicit, single-schema-revision binding;
        % see requireStateSchemaVersion's docstring for why the label check alone is not a
        % substitute for an explicit version tag.
        CoordinateTimeScale = 'simulationCoordinateTime_s';
        FrameIdentifier = 'ECEF';
        ClockDatumIdentifier = 'receiverClockBiasStateGauge';

        % StateSchemaVersion names the exact EndpointStateProduct label contract below. Any
        % change to revgnss.EndpointStateProduct.fromLocalEstimator's label lists requires a
        % new version identifier here so a stale consumer fails loudly instead of silently
        % misreading a reordered or renamed component.
        StateSchemaVersion = 'endpointStateProduct-v1';

        StateSchemaV1StateComponentOrder = { ...
            'positionEcefX_m','positionEcefY_m','positionEcefZ_m', ...
            'velocityEcefX_mps','velocityEcefY_mps','velocityEcefZ_mps', ...
            'attitudeRoll_rad','attitudePitch_rad','attitudeYaw_rad', ...
            'angularRateX_radps','angularRateY_radps','angularRateZ_radps', ...
            'clockBias_m','clockDrift_mps'};

        StateSchemaV1CovarianceComponentOrderEuler = { ...
            'positionErrorEcefX_m','positionErrorEcefY_m','positionErrorEcefZ_m', ...
            'velocityErrorEcefX_mps','velocityErrorEcefY_mps','velocityErrorEcefZ_mps', ...
            'attitudeRollError_rad','attitudePitchError_rad','attitudeYawError_rad', ...
            'angularRateErrorX_radps','angularRateErrorY_radps','angularRateErrorZ_radps', ...
            'clockBiasError_m','clockDriftError_mps'};

        StateSchemaV1CovarianceComponentOrderTangent = { ...
            'positionErrorEcefX_m','positionErrorEcefY_m','positionErrorEcefZ_m', ...
            'velocityErrorEcefX_mps','velocityErrorEcefY_mps','velocityErrorEcefZ_mps', ...
            'attitudeTangentErrorX_rad','attitudeTangentErrorY_rad','attitudeTangentErrorZ_rad', ...
            'angularRateErrorX_radps','angularRateErrorY_radps','angularRateErrorZ_radps', ...
            'clockBiasError_m','clockDriftError_mps'};

        AllowedAttitudeErrorCoordinateConventions = { ...
            'eulerZYXError_rad','rightMultiplicativeLocalTangent_rad'};

        % Known common-information sources a distributed link update must declare a treatment
        % for. No treatment is implemented at THIS key for any of the five, so
        % isFullyRejectedCommonSourceTreatment requires every one to be 'rejected' on the live
        % linkUpdate path. The intended treatment for each:
        %   - sharedForceAtmosphericProduct: 'rejected' here is correct and permanent -- the real
        %     treatment is a DIFFERENT, state-space channel (correlationNetwork.
        %     commonProcessNoiseTreatment='declaredCommonAccelerationGroup', a Q-term, not an
        %     R-term/covarianceGroup at this measurement-space key) -- see revgnss.
        %     CommonProcessNoiseCovarianceGroup and filter.ReverseGNSSEKF.
        %     declaredCommonProcessNoiseGroup_.
        %   - transmittedStateProduct: 'covarianceGroup' is structurally barred BY NAME for this
        %     source (revgnss.CommonSourceCovarianceGroup.SourceTreatmentIncompatibilities.
        %     transmittedStateProduct) because the remote's own prediction error is already fully
        %     carried by revgnss.SplitCovarianceIntersectionBound's remotePrior Young's-inequality
        %     term. 'rejected' here means "not additionally declared as a covariance group," not
        %     "untreated" -- the source IS conservatively treated, outside this enum.
        %   - towerClockProduct, terminalCalibration, sessionTimingProduct: genuinely untreated at
        %     this key -- no treatment exists yet for any of the three, so 'rejected' is left as
        %     the only legal value here rather than accepted as a silent mislabel. For
        %     towerClockProduct specifically, the gap is not merely undisclosed: revgnss.
        %     IndependentFleetCoordinator.validateConfig's towerClockProductReachableButRejected
        %     hard error refuses the one combination (an enabled correlation network, nAssets>1,
        %     towerClockMode~='perfectCorrection') where the false 'rejected' claim would
        %     otherwise be silently load-bearing.
        CommonSourceNames = { ...
            'towerClockProduct','terminalCalibration','transmittedStateProduct', ...
            'sessionTimingProduct','sharedForceAtmosphericProduct'};
        AllowedCommonSourceTreatments = { ...
            'covarianceGroup','estimatedOwnerState','externalCovarianceProduct','rejected'};

        % A reciprocal/two-way time-transfer row observes a relative clock bias only (Section
        % 2.0.6). No absolute or drift claim is physically supported by the existing
        % ReciprocalTimeTransferModel / InterSatelliteTimeTransferBuilder observable.
        AllowedClockClaims = {'relativeBiasOnly'};

        % The required additive per-epoch phase order for the distributed path (Section
        % 2.0.1). Phases 4-5 have no implementation while linkUpdate.enable is rejected;
        % IndependentFleetCoordinator's per-epoch loop calls no-op guards at their position.
        EpochFinalizationPhaseOrder = { ...
            'advanceSharedTruthAndLocalPrediction', ...
            'localGroundOnboardUpdate', ...
            'publishAndFreezeEstimatorProducts', ...
            'generateValidateDeliverLinkRecords', ...
            'ownerOnlyLinkUpdate', ...
            'commitLocalHistoryAndConsumption'};
    end

    methods (Static)
        function requireSameEpochScope(settings)
            % requireSameEpochScope  Section 2.0.2 same-epoch-only gate.
            %   Not wired into general stateExchange validation: Stage-1 diagnostic-only
            %   state exchange may use a nonzero maximumAge_s/deliveryDelay_s. This gate is
            %   for the future linkUpdate-enabled path only (Section 2.1+), which must call
            %   it before treating a remote product as estimator-eligible.
            if ~(isstruct(settings) && isfield(settings,'maximumAge_s') && ...
                    isfield(settings,'deliveryDelay_s'))
                error('DistributedLinkProtocolContract:stateExchangeSchema', ...
                    'requireSameEpochScope requires maximumAge_s and deliveryDelay_s fields.');
            end
            if ~(isnumeric(settings.maximumAge_s) && isscalar(settings.maximumAge_s) && ...
                    settings.maximumAge_s == 0)
                error('DistributedLinkProtocolContract:maximumAge', ...
                    'The first active Stage-2 scope requires stateExchange.maximumAge_s=0.');
            end
            if ~(isnumeric(settings.deliveryDelay_s) && isscalar(settings.deliveryDelay_s) && ...
                    settings.deliveryDelay_s == 0)
                error('DistributedLinkProtocolContract:deliveryDelay', ...
                    'The first active Stage-2 scope requires stateExchange.deliveryDelay_s=0.');
            end
        end

        function requireOutOfSequenceRejected(outOfSequencePolicy)
            if ~(ischar(outOfSequencePolicy) || ...
                    (isstring(outOfSequencePolicy) && isscalar(outOfSequencePolicy))) || ...
                    ~strcmp(char(outOfSequencePolicy),'reject')
                error('DistributedLinkProtocolContract:outOfSequencePolicy', ...
                    'The first active Stage-2 scope requires outOfSequencePolicy=''reject''.');
            end
        end

        function requireCommonSourceTreatmentDeclared(commonSourceTreatment)
            % requireCommonSourceTreatmentDeclared  Schema/vocabulary check only. Accepts any
            % of the four frozen treatment words; does not gate whether one is implemented.
            if ~isstruct(commonSourceTreatment)
                error('DistributedLinkProtocolContract:commonSourceTreatmentType', ...
                    'linkUpdate.commonSourceTreatment must be a struct.');
            end
            names = revgnss.DistributedLinkProtocolContract.CommonSourceNames;
            allowed = revgnss.DistributedLinkProtocolContract.AllowedCommonSourceTreatments;
            for index = 1:numel(names)
                name = names{index};
                if ~isfield(commonSourceTreatment,name)
                    error('DistributedLinkProtocolContract:commonSourceMissing', ...
                        'linkUpdate.commonSourceTreatment.%s must be declared.',name);
                end
                value = commonSourceTreatment.(name);
                if ~(ischar(value) || (isstring(value) && isscalar(value))) || ...
                        ~any(strcmp(char(value),allowed))
                    error('DistributedLinkProtocolContract:commonSourceValue', ...
                        ['linkUpdate.commonSourceTreatment.%s must be one of the frozen ' ...
                        'treatments (covarianceGroup, estimatedOwnerState, ' ...
                        'externalCovarianceProduct, rejected).'],name);
                end
            end
        end

        function tf = isFullyRejectedCommonSourceTreatment(commonSourceTreatment)
            % isFullyRejectedCommonSourceTreatment  True iff every known common source is
            % still 'rejected'. No treatment is implemented yet (Section 2.2 delivers one);
            % IndependentFleetCoordinator.validateConfig requires this to hold today.
            revgnss.DistributedLinkProtocolContract.requireCommonSourceTreatmentDeclared( ...
                commonSourceTreatment);
            names = revgnss.DistributedLinkProtocolContract.CommonSourceNames;
            tf = true;
            for index = 1:numel(names)
                if ~strcmp(char(commonSourceTreatment.(names{index})),'rejected')
                    tf = false;
                    return
                end
            end
        end

        function requireClockClaim(clockClaim)
            allowed = revgnss.DistributedLinkProtocolContract.AllowedClockClaims;
            if ~(ischar(clockClaim) || (isstring(clockClaim) && isscalar(clockClaim))) || ...
                    ~any(strcmp(char(clockClaim),allowed))
                error('DistributedLinkProtocolContract:clockClaim', ...
                    ['linkUpdate.timeTransferClockClaim must be ''relativeBiasOnly''. A ' ...
                    'reciprocal/two-way time-transfer row observes b_remote-b_owner; it is ' ...
                    'never an absolute clock datum or a direct drift measurement.']);
            end
        end

        function variant = requireStateSchemaVersion(product)
            % requireStateSchemaVersion  Validate an EndpointStateProduct against the frozen
            % v1 label contract and return which attitude-covariance variant it matched
            % ('euler' or 'tangent'). Detects silent drift if EndpointStateProduct's own
            % labels ever change without updating StateSchemaVersion here.
            %
            % This is a labels-only heuristic: it is sufficient to catch accidental drift
            % within the current single schema revision, but it is NOT a substitute for an
            % explicit stored version/frame/time-scale/clock-datum field, because a future
            % schema revision could reuse identical labels while changing their meaning (for
            % example a different clock gauge). The Section 2.1 estimator-eligible
            % publication profile must carry an explicit version tag rather than relying on
            % this check alone.
            if ~isa(product,'revgnss.EndpointStateProduct')
                error('DistributedLinkProtocolContract:productType', ...
                    'requireStateSchemaVersion requires an EndpointStateProduct.');
            end
            expectedState = revgnss.DistributedLinkProtocolContract.StateSchemaV1StateComponentOrder;
            if ~isequal(product.stateComponentOrder,expectedState)
                error('DistributedLinkProtocolContract:stateComponentOrder', ...
                    'The product state component order does not match %s.', ...
                    revgnss.DistributedLinkProtocolContract.StateSchemaVersion);
            end
            matchesEuler = isequal(product.covarianceComponentOrder, ...
                revgnss.DistributedLinkProtocolContract.StateSchemaV1CovarianceComponentOrderEuler);
            matchesTangent = isequal(product.covarianceComponentOrder, ...
                revgnss.DistributedLinkProtocolContract.StateSchemaV1CovarianceComponentOrderTangent);
            if ~(matchesEuler || matchesTangent)
                error('DistributedLinkProtocolContract:covarianceComponentOrder', ...
                    'The product covariance component order does not match %s.', ...
                    revgnss.DistributedLinkProtocolContract.StateSchemaVersion);
            end
            if matchesEuler
                variant = 'euler';
            else
                variant = 'tangent';
            end
        end

        function requireDiagnosticOnlyProduct(product)
            % requireDiagnosticOnlyProduct  Section 2.0.4: Stage-1 EndpointStateProduct stays
            % diagnostic-only until a separate estimator-eligible profile exists.
            if ~isa(product,'revgnss.EndpointStateProduct')
                error('DistributedLinkProtocolContract:productType', ...
                    'requireDiagnosticOnlyProduct requires an EndpointStateProduct.');
            end
            flags = product.qualityFlags;
            if ~(isstruct(flags) && isfield(flags,'diagnosticOnly') && ...
                    isfield(flags,'consumedByEstimator') && isfield(flags,'truthUsed') && ...
                    islogical(flags.diagnosticOnly) && islogical(flags.consumedByEstimator) && ...
                    islogical(flags.truthUsed))
                error('DistributedLinkProtocolContract:qualityFlagsSchema', ...
                    'An EndpointStateProduct must declare diagnosticOnly/consumedByEstimator/truthUsed.');
            end
            if ~flags.diagnosticOnly || flags.consumedByEstimator || flags.truthUsed
                error('DistributedLinkProtocolContract:notDiagnosticOnly', ...
                    ['This EndpointStateProduct is not diagnostic-only. Stage 2.0 keeps every ' ...
                    'Stage-1 state product diagnostic-only; an estimator-eligible profile is ' ...
                    'a distinct, not-yet-added publication path (Section 2.1).']);
            end
        end

        function requireDeliveryProvenance(product, currentEpoch_s)
            % requireDeliveryProvenance  Compose every Section 2.0.3 delivery requirement a
            % future adapter must check before treating a product as a candidate delivery
            % input: schema version, attitude-error coordinate convention (cross-checked
            % against the covariance labels actually carried, not just checked in isolation),
            % diagnostic-only status, a canonical identity that is internally self-consistent,
            % and same-epoch freshness at the specific currentEpoch_s a delivery would use it.
            variant = revgnss.DistributedLinkProtocolContract.requireStateSchemaVersion(product);
            revgnss.DistributedLinkProtocolContract.requireDiagnosticOnlyProduct(product);
            provenance = product.processModelProvenance;
            allowedConventions = ...
                revgnss.DistributedLinkProtocolContract.AllowedAttitudeErrorCoordinateConventions;
            if ~(isstruct(provenance) && isfield(provenance,'attitudeCovarianceCoordinates') && ...
                    any(strcmp(char(provenance.attitudeCovarianceCoordinates),allowedConventions)))
                error('DistributedLinkProtocolContract:attitudeConvention', ...
                    ['processModelProvenance.attitudeCovarianceCoordinates must be one of ' ...
                    'the frozen attitude-error coordinate conventions.']);
            end
            declaredConvention = char(provenance.attitudeCovarianceCoordinates);
            conventionMatchesVariant = ...
                (strcmp(variant,'euler') && strcmp(declaredConvention,'eulerZYXError_rad')) || ...
                (strcmp(variant,'tangent') && ...
                strcmp(declaredConvention,'rightMultiplicativeLocalTangent_rad'));
            if ~conventionMatchesVariant
                error('DistributedLinkProtocolContract:attitudeConventionMismatch', ...
                    ['processModelProvenance.attitudeCovarianceCoordinates (''%s'') does not ' ...
                    'match the covariance label set actually carried by this product ' ...
                    '(''%s''). A remote MEKF right-multiplicative tangent-error covariance ' ...
                    'must never be treated as an Euler-angle covariance, or vice versa.'], ...
                    declaredConvention,variant);
            end
            canonicalId = revgnss.CanonicalEndpointIdentity.fromProductIdentifier( ...
                product.sourceAssetIdentifier);
            if canonicalId.physicalAssetIndex ~= product.sourceAssetIndex
                error('DistributedLinkProtocolContract:identityMismatch', ...
                    ['sourceAssetIdentifier ''%s'' and sourceAssetIndex %d disagree on the ' ...
                    'physical spacecraft this product describes.'], ...
                    product.sourceAssetIdentifier,product.sourceAssetIndex);
            end
            if ~(isnumeric(currentEpoch_s) && isscalar(currentEpoch_s) && ...
                    isfinite(currentEpoch_s))
                error('DistributedLinkProtocolContract:currentEpochType', ...
                    'requireDeliveryProvenance requires a finite scalar currentEpoch_s.');
            end
            if currentEpoch_s < product.deliveryEpoch_s
                error('DistributedLinkProtocolContract:notYetDelivered', ...
                    'This product has not yet reached its declared delivery epoch.');
            end
            if currentEpoch_s ~= product.validAtEpoch_s
                error('DistributedLinkProtocolContract:staleProduct', ...
                    ['The first active Stage-2 scope is same-epoch-only (Section 2.0.2); a ' ...
                    'product valid at a different epoch than the current delivery epoch is ' ...
                    'stale and must be rejected, not propagated.']);
            end
        end

        function requireSingletonCovarianceGroup(record)
            % requireSingletonCovarianceGroup  Section 2.0.3 covariance-group-identifier
            % freeze for a physical link record (InterSatelliteObservationRecord or
            % InterSatelliteTimeTransferObservationRecord). Every existing builder
            % (CoherentTwoWayCodeRangingModel, TwoWayISLMeasurementBuilder,
            % InterSatelliteTimeTransferBuilder) sets covarianceGroupIdentifier equal to the
            % record's own observationIdentifier: no covariance is actually shared/grouped
            % across observations today. This freezes that fact so a future adapter cannot
            % assume an existing record already declares a real shared-covariance group;
            % Section 2.2 must add and prove one deliberately before any source is treated
            % as 'covarianceGroup' rather than 'rejected'.
            if ~(isprop(record,'observationIdentifier') && ...
                    isprop(record,'covarianceGroupIdentifier'))
                error('DistributedLinkProtocolContract:covarianceGroupSchema', ...
                    ['A physical link record must declare observationIdentifier and ' ...
                    'covarianceGroupIdentifier.']);
            end
            if isempty(record.covarianceGroupIdentifier)
                error('DistributedLinkProtocolContract:covarianceGroupMissing', ...
                    'A physical link record must declare a non-empty covarianceGroupIdentifier.');
            end
            if ~strcmp(char(record.covarianceGroupIdentifier),char(record.observationIdentifier))
                error('DistributedLinkProtocolContract:covarianceGroupNotSingleton', ...
                    ['This record declares a covarianceGroupIdentifier distinct from its own ' ...
                    'observationIdentifier. No builder implements real covariance sharing ' ...
                    'yet; Section 2.2 must add and prove a treatment before this is accepted.']);
            end
        end

        function requireCalibrationProvenance(record)
            % requireCalibrationProvenance  Section 2.0.3 calibration validity/provenance
            % freeze. InterSatelliteObservationRecord (two-way PN range) carries
            % calibrationProductIdentifiers plus an explicit validity interval;
            % InterSatelliteTimeTransferObservationRecord carries only
            % calibrationProductIdentifiers today, with no validity interval. This requires
            % at least one declared calibration product identifier always, and -- only when a
            % validity interval is actually present on the record -- requires it be sane and
            % contain the record's own reference tag. A first-order reciprocal time-transfer
            % delivery therefore cannot claim a temporally-scoped calibration provenance until
            % a validity interval is added to that record type (plan Sections 2.3.2 / 2.4).
            if ~isprop(record,'calibrationProductIdentifiers')
                error('DistributedLinkProtocolContract:calibrationSchema', ...
                    'A physical link record must declare calibrationProductIdentifiers.');
            end
            if isempty(record.calibrationProductIdentifiers)
                error('DistributedLinkProtocolContract:calibrationMissing', ...
                    'A physical link record must declare at least one calibrationProductIdentifier.');
            end
            hasValidityInterval = isprop(record,'calibrationValidFromLocalTag_s') && ...
                isprop(record,'calibrationValidUntilLocalTag_s') && ...
                isprop(record,'referenceLocalClockTag_s');
            if ~hasValidityInterval
                return
            end
            if record.calibrationValidUntilLocalTag_s < record.calibrationValidFromLocalTag_s
                error('DistributedLinkProtocolContract:calibrationValidityReversed', ...
                    'The calibration validity interval is reversed.');
            end
            if record.referenceLocalClockTag_s < record.calibrationValidFromLocalTag_s || ...
                    record.referenceLocalClockTag_s > record.calibrationValidUntilLocalTag_s
                error('DistributedLinkProtocolContract:calibrationValidityExpired', ...
                    'The observation reference tag is outside the calibration validity interval.');
            end
        end
    end
end
