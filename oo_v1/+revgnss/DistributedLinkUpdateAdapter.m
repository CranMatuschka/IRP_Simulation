classdef DistributedLinkUpdateAdapter
    % DistributedLinkUpdateAdapter  Interface #3 (plan Section 2.1): generic contract/shape.
    %
    % RegisteredAdapterClasses carries exactly ONE concrete per-observable adapter (plan Section
    % 2.3.1): revgnss.CoherentTwoWayRangeLinkUpdateAdapter, for the coherent transponded PN
    % two-way code range observable. AllowedObservables therefore admits 'none' and
    % 'coherentTwoWayCodeRange' only; every other real observable identifier -- including every
    % entry still in ReservedFutureObservables -- remains refused.
    %
    % This file itself still contains NO residual/Jacobian/covariance physics for any observable:
    % it is a shape/validation gate, and requireUpdateBlock additionally requires a
    % revgnss.SplitCovarianceIntersectionBound-demonstrated conservative bound before a non-
    % 'disabled' correlationPolicy is reachable for a given observable (see
    % requireRecordClassSupportedForObservable and the correlationPolicy check below).

    properties (Constant)
        RegisteredAdapterClasses = {'revgnss.CoherentTwoWayRangeLinkUpdateAdapter'};
        AllowedObservables = {'none','coherentTwoWayCodeRange'};
        % Documentary only: reserved, not implemented, not accepted anywhere today.
        ReservedFutureObservables = { ...
            'firstOrderReciprocalClockTransfer','oneWayCode','oneWayDoppler'};
        RequiredAdapterMethods = {'buildUpdateBlock'};
        % Section 2.2 adds ONE new legal assembly value, whose name asserts that no assembly
        % happened INSIDE the block (the assembly itself is performed outside it, by
        % revgnss.SplitCovarianceIntersectionBound, which returns a
        % revgnss.OwnerPosteriorBoundResult the block neither carries nor could carry). The
        % Section 2.1 value keeps its original meaning unchanged.
        AllowedResidualCovarianceAssemblies = { ...
            'notAssembledInSection21','notAssembledInputsEligibleForSplitCovarianceIntersection'};
        % Section 2.2 wires DistributedLinkCalibrationState's existing single-owner machinery
        % into this field: 'externalCalibrationProduct' is one of
        % DistributedLinkCalibrationState.AllowedOwnershipKinds (that class's OTHER kind,
        % 'ownerEstimatedState', is refused by name below -- see
        % ReservedPersistentCalibrationTreatments -- because it is not expressible in the
        % frozen v1 14-component schema). 'rejected' keeps its Section 2.1 meaning.
        AllowedPersistentCalibrationTreatments = {'rejected','externalCalibrationProduct'};
        % Documentary only: refused BY NAME (see DistributedLinkUpdateBlock's constructor)
        % before the generic vocabulary check, with the frozen v1-schema reason. This is the
        % calibration-state spelling (DistributedLinkCalibrationState.AllowedOwnershipKinds);
        % the DIFFERENT, protocol-contract spelling 'estimatedOwnerState'
        % (DistributedLinkProtocolContract.AllowedCommonSourceTreatments) is a different word
        % for a different field and keeps failing the generic :persistentCalibrationTreatment
        % check, not this by-name refusal.
        ReservedPersistentCalibrationTreatments = {'ownerEstimatedState'};
        % AllowedBlockCorrelationPolicies: what a DistributedLinkUpdateBlock may CARRY.
        % ReachableCorrelationPolicies: what requireUpdateBlock accepts today. Section 2.3 (and
        % only Section 2.3) widens ReachableCorrelationPolicies; Section 2.2 makes
        % 'splitCovarianceIntersection' EXPRESSIBLE on a block without making it REACHABLE
        % through requireUpdateBlock, LinkObservationDelivery, or IndependentFleetCoordinator.
        AllowedBlockCorrelationPolicies = {'disabled','splitCovarianceIntersection'};
        % Section 2.3.1 widens this to include 'splitCovarianceIntersection', but ONLY for an
        % observable with a demonstrated bound (requireUpdateBlock below re-checks this on every
        % call via SplitCovarianceIntersectionBound.requireObservableHasDemonstratedBound) -- the
        % gate is strictly stronger than the old blanket string refusal, not merely different.
        ReachableCorrelationPolicies = {'disabled','splitCovarianceIntersection'};
    end

    methods (Static)
        function requireObservableSelectable(observableIdentifier)
            allowed = revgnss.DistributedLinkUpdateAdapter.AllowedObservables;
            if ~(ischar(observableIdentifier) || ...
                    (isstring(observableIdentifier) && isscalar(observableIdentifier))) || ...
                    ~any(strcmp(char(observableIdentifier),allowed))
                error('DistributedLinkUpdateAdapter:observableNotSelectable', ...
                    ['Observable ''%s'' is not selectable. Only ''none'' and ' ...
                    '''coherentTwoWayCodeRange'' validate today.'], ...
                    char(observableIdentifier));
            end
        end

        function requireRegisteredAdapter(adapterClassName)
            if ~any(strcmp(char(adapterClassName), ...
                    revgnss.DistributedLinkUpdateAdapter.RegisteredAdapterClasses))
                error('DistributedLinkUpdateAdapter:adapterNotRegistered', ...
                    ['Adapter class ''%s'' is not registered today (RegisteredAdapterClasses ' ...
                    'carries only revgnss.CoherentTwoWayRangeLinkUpdateAdapter).'], ...
                    char(adapterClassName));
            end
        end

        function requireRecordClassSupportedForObservable(observableIdentifier, recordClassName)
            % requireRecordClassSupportedForObservable  Couples the SELECTED observable to the
            % physical record's own class, so a record of the wrong observable type (e.g. a
            % time-transfer record proposed under 'coherentTwoWayCodeRange') is refused at
            % delivery-proposal time rather than later, inside the adapter.
            revgnss.DistributedLinkUpdateAdapter.requireObservableSelectable(observableIdentifier);
            if strcmp(char(observableIdentifier),'none')
                return
            end
            registered = revgnss.DistributedLinkUpdateAdapter.RegisteredAdapterClasses;
            for index = 1:numel(registered)
                adapterClassName = registered{index};
                adapterObservableId = revgnss.DistributedLinkUpdateAdapter.constantValue_( ...
                    adapterClassName,'ObservableIdentifier');
                if strcmp(adapterObservableId,char(observableIdentifier))
                    supported = revgnss.DistributedLinkUpdateAdapter.constantValue_( ...
                        adapterClassName,'SupportedPhysicalRecordClasses');
                    if ~any(strcmp(char(recordClassName),supported))
                        error('DistributedLinkUpdateAdapter:recordClassNotSupportedForObservable', ...
                            ['Record class ''%s'' is not supported by the registered adapter for ' ...
                            'observable ''%s''.'],char(recordClassName),char(observableIdentifier));
                    end
                    return
                end
            end
            error('DistributedLinkUpdateAdapter:adapterNotRegistered', ...
                'No registered adapter declares ObservableIdentifier=''%s''.',char(observableIdentifier));
        end

        function requireUpdateBlock(block, delivery, ownerState, remoteState)
            if ~isa(block,'revgnss.DistributedLinkUpdateBlock')
                error('DistributedLinkUpdateAdapter:blockType', ...
                    'requireUpdateBlock requires a revgnss.DistributedLinkUpdateBlock.');
            end
            if ~isa(delivery,'revgnss.LinkObservationDelivery')
                error('DistributedLinkUpdateAdapter:blockType', ...
                    'requireUpdateBlock requires a revgnss.LinkObservationDelivery.');
            end
            if ~strcmp(block.observationIdentifier,delivery.observationIdentifier) || ...
                    ~strcmp(block.deliveryIdentifier,delivery.deliveryIdentifier) || ...
                    ~strcmp(block.ownerAssetIdentifier,delivery.ownerAssetIdentifier) || ...
                    ~strcmp(block.remoteAssetIdentifier,delivery.remoteAssetIdentifier) || ...
                    ~strcmp(block.remoteProductIdentifier,delivery.remoteProductIdentifier)
                error('DistributedLinkUpdateAdapter:identifierMismatch', ...
                    'The update block identifiers do not match its delivery.');
            end
            if block.coordinateEventEpoch_s ~= delivery.coordinateEventEpoch_s
                error('DistributedLinkUpdateAdapter:coordinateEventEpochMismatch', ...
                    'The update block coordinate event epoch does not match its delivery.');
            end
            if ~isa(ownerState,'revgnss.CommunicationEndpointState') || ...
                    ~isa(remoteState,'revgnss.CommunicationEndpointState')
                error('DistributedLinkUpdateAdapter:blockType', ...
                    'requireUpdateBlock requires two revgnss.CommunicationEndpointState objects.');
            end
            if ~isequal(block.ownerCovarianceComponentOrder,ownerState.covarianceComponentOrder)
                error('DistributedLinkUpdateAdapter:ownerComponentOrderMismatch', ...
                    'The update block owner covariance component order does not match the owner state.');
            end
            if ~isequal(block.remoteCovarianceComponentOrder,remoteState.covarianceComponentOrder)
                error('DistributedLinkUpdateAdapter:remoteComponentOrderMismatch', ...
                    'The update block remote covariance component order does not match the remote state.');
            end
            if ~strcmp(block.ownerAttitudeErrorCoordinateConvention, ...
                    ownerState.attitudeErrorCoordinateConvention) || ...
                    ~strcmp(block.remoteAttitudeErrorCoordinateConvention, ...
                    remoteState.attitudeErrorCoordinateConvention)
                error('DistributedLinkUpdateAdapter:attitudeConventionMismatch', ...
                    'The update block attitude conventions do not match the endpoint states.');
            end
            revgnss.CommunicationEndpointStateProvider.requireTerminalGeometryDeclared(ownerState);
            revgnss.CommunicationEndpointStateProvider.requireTerminalGeometryDeclared(remoteState);
            if ~any(strcmp(block.residualCovarianceAssembly, ...
                    revgnss.DistributedLinkUpdateAdapter.AllowedResidualCovarianceAssemblies))
                error('DistributedLinkUpdateAdapter:covarianceAssemblyForbidden', ...
                    'The update block residual covariance assembly is not permitted.');
            end
            if ~any(strcmp(block.persistentCalibrationTreatment, ...
                    revgnss.DistributedLinkUpdateAdapter.AllowedPersistentCalibrationTreatments))
                error('DistributedLinkUpdateAdapter:persistentCalibrationTreatment', ...
                    'The update block persistent calibration treatment is not permitted.');
            end
            % Section 2.2: re-expressed against ReachableCorrelationPolicies (today identical
            % in effect to the Section 2.1 literal 'disabled' check -- Section 2.3 is the only
            % section allowed to widen this constant), plus two ADDED checks that only
            % strengthen this gate: the block's policy must match its delivery's, and the
            % remote contribution it carries must be provably H_j*P_j*H_j^T alone.
            if ~any(strcmp(block.correlationPolicy, ...
                    revgnss.DistributedLinkUpdateAdapter.ReachableCorrelationPolicies))
                error('DistributedLinkUpdateAdapter:correlationPolicyUnsupported', ...
                    'The update block correlation policy is not reachable today.');
            end
            if ~strcmp(block.correlationPolicy,'disabled')
                % A non-'disabled' policy is reachable only for an observable with a DEMONSTRATED
                % conservative bound (Section 2.2 bullet 4) -- this is what makes the
                % ReachableCorrelationPolicies widening strictly stronger than a blanket string
                % refusal, not merely different (see the class header and Section 2.3.1).
                revgnss.SplitCovarianceIntersectionBound.requireObservableHasDemonstratedBound( ...
                    block.observableIdentifier);
            end
            if ~strcmp(block.correlationPolicy,delivery.correlationPolicy)
                error('DistributedLinkUpdateAdapter:correlationPolicyMismatch', ...
                    'The update block correlation policy does not match its delivery.');
            end
            revgnss.DistributedLinkUpdateAdapter.requireRemoteContributionIsRemotePriorOnly( ...
                block,remoteState);
        end

        function requireRemoteContributionIsRemotePriorOnly(block, remoteState)
            % requireRemoteContributionIsRemotePriorOnly  Transport-layer closure of plan
            % Section 2.2.2's forbidden shortcut: block.remoteContributionCovariance_m2 must
            % equal H_j*P_j*H_j^T EXACTLY, formed only from the remote endpoint's own state and
            % the block's own remote Jacobian. A block whose remote contribution silently folds
            % in a declared common source or calibration term is refused here, before it ever
            % reaches revgnss.SplitCovarianceIntersectionBound.
            if ~isa(block,'revgnss.DistributedLinkUpdateBlock')
                error('DistributedLinkUpdateAdapter:blockType', ...
                    'requireRemoteContributionIsRemotePriorOnly requires a revgnss.DistributedLinkUpdateBlock.');
            end
            if ~isa(remoteState,'revgnss.CommunicationEndpointState')
                error('DistributedLinkUpdateAdapter:blockType', ...
                    'requireRemoteContributionIsRemotePriorOnly requires a revgnss.CommunicationEndpointState.');
            end
            Hj = block.remoteJacobian_mPerErrorUnit;
            expected = Hj*remoteState.covarianceBlock*Hj';
            expected = (expected+expected')/2;
            actual = block.remoteContributionCovariance_m2;
            scale = max(1,norm(expected,'fro'));
            if ~isequal(size(actual),size(expected)) || norm(actual-expected,'fro') > 1e-9*scale
                error('DistributedLinkUpdateAdapter:remoteContributionNotRemotePriorOnly', ...
                    ['remoteContributionCovariance_m2 must equal H_j*P_j*H_j^T exactly, formed ' ...
                    'only from the remote endpoint state and the block''s own remote Jacobian; it ' ...
                    'must never have a declared common source or calibration term folded in ' ...
                    '(plan Section 2.2.2).']);
            end
        end

        function requirePersistentCalibrationOwnership(block, calibrationRegistry)
            % requirePersistentCalibrationOwnership  Plan Section 2.2 bullet 6, wired onto
            % Section 2.1's existing single-owner calibration machinery
            % (revgnss.DistributedLinkCalibrationState/Registry) rather than new state. The
            % validity interval has exactly one owner (the registry declaration); the variance
            % has exactly one owner (declaration.priorVariance); the block carries only the
            % mapping column and a reference tag, never a second copy of either.
            if ~isa(block,'revgnss.DistributedLinkUpdateBlock')
                error('DistributedLinkUpdateAdapter:blockType', ...
                    'requirePersistentCalibrationOwnership requires a revgnss.DistributedLinkUpdateBlock.');
            end
            treatment = block.persistentCalibrationTreatment;
            if strcmp(treatment,'rejected')
                if ~isempty(block.calibrationStateIdentifiers)
                    error('DistributedLinkUpdateAdapter:inertFieldsNotSentinel', ...
                        'persistentCalibrationTreatment=''rejected'' requires empty calibrationStateIdentifiers.');
                end
                return
            end
            if ~strcmp(treatment,'externalCalibrationProduct')
                error('DistributedLinkUpdateAdapter:persistentCalibrationTreatment', ...
                    'Unsupported persistentCalibrationTreatment for ownership resolution.');
            end
            if isempty(block.calibrationStateIdentifiers)
                error('DistributedLinkUpdateAdapter:persistentCalibrationOwnershipMismatch', ...
                    'externalCalibrationProduct requires at least one calibrationStateIdentifier.');
            end
            if ~isa(calibrationRegistry,'revgnss.DistributedLinkCalibrationRegistry')
                error('DistributedLinkUpdateAdapter:persistentCalibrationOwnershipMismatch', ...
                    'requirePersistentCalibrationOwnership requires a revgnss.DistributedLinkCalibrationRegistry.');
            end
            ids = block.calibrationStateIdentifiers;
            for index = 1:numel(ids)
                declaration = calibrationRegistry.ownerFor(ids{index});
                if ~strcmp(declaration.ownershipKind,'externalCalibrationProduct')
                    error('DistributedLinkUpdateAdapter:persistentCalibrationOwnershipMismatch', ...
                        'Calibration state %s is not owned as an externalCalibrationProduct.',ids{index});
                end
                if ~strcmp(declaration.temporalCovarianceModel,'externalProductCovariance')
                    error('DistributedLinkUpdateAdapter:calibrationTemporalPropagationUnavailable', ...
                        ['Propagating a randomWalk/firstOrderGaussMarkov calibration variance across ' ...
                        'time is a Section 2.3 adapter responsibility; only externalProductCovariance ' ...
                        'is usable as a persistent link update input today.']);
                end
                if ~strcmp(declaration.stateKind,'linkRangeBiasResidual_m') || ...
                        ~strcmp(declaration.priorVarianceUnits,'m^2')
                    error('DistributedLinkUpdateAdapter:calibrationUnitMappingUnavailable', ...
                        ['The seconds-to-metres calibration unit mapping (factor c one-way or 2c ' ...
                        'round-trip) is a Section 2.3 adapter responsibility; only ' ...
                        'linkRangeBiasResidual_m/m^2 is usable today.']);
                end
                if ~declaration.coversLocalTag(block.persistentCalibrationReferenceLocalTag_s)
                    error('DistributedLinkUpdateAdapter:persistentCalibrationValidityExpired', ...
                        'Calibration state %s does not cover the block''s reference local tag.',ids{index});
                end
            end
        end

        function contract = describeContract()
            contract = struct( ...
                'requiredBlockFields',{properties('revgnss.DistributedLinkUpdateBlock')}, ...
                'residualUnits','m', ...
                'jacobianUnits','m per declared error-coordinate unit (m, m/s, or rad)', ...
                'covarianceUnits','m^2', ...
                'coordinateTimeScale',revgnss.DistributedLinkProtocolContract.CoordinateTimeScale, ...
                'frameIdentifier',revgnss.DistributedLinkProtocolContract.FrameIdentifier, ...
                'allowedObservables',{revgnss.DistributedLinkUpdateAdapter.AllowedObservables}, ...
                'registeredAdapterClasses', ...
                    {revgnss.DistributedLinkUpdateAdapter.RegisteredAdapterClasses}, ...
                'residualCovarianceAssemblies', ...
                    {revgnss.DistributedLinkUpdateAdapter.AllowedResidualCovarianceAssemblies}, ...
                'reachableCorrelationPolicies', ...
                    {revgnss.DistributedLinkUpdateAdapter.ReachableCorrelationPolicies}, ...
                'conservativeBoundModule','revgnss.SplitCovarianceIntersectionBound');
        end
    end

    methods (Static, Access = private)
        function value = constantValue_(className, propertyName)
            % constantValue_  Reads a Constant property's literal value given only the class
            % name as text, via metaclass reflection (feval cannot call a property access
            % expressed as a dotted string). Used only to look up a registered adapter's own
            % declared ObservableIdentifier/SupportedPhysicalRecordClasses.
            mc = meta.class.fromName(className);
            if isempty(mc)
                error('DistributedLinkUpdateAdapter:adapterNotRegistered', ...
                    'Class ''%s'' does not exist.',className);
            end
            names = {mc.PropertyList.Name};
            propIndex = find(strcmp(names,propertyName),1);
            if isempty(propIndex) || ~mc.PropertyList(propIndex).Constant
                error('DistributedLinkUpdateAdapter:adapterNotRegistered', ...
                    'Class ''%s'' has no Constant property ''%s''.',className,propertyName);
            end
            value = mc.PropertyList(propIndex).DefaultValue;
        end
    end
end
