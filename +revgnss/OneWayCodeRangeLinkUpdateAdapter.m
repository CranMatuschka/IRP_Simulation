classdef OneWayCodeRangeLinkUpdateAdapter
    % OneWayCodeRangeLinkUpdateAdapter  Plan Section 2.3 item 3 concrete adapter: the one-way
    % ISL code-range observable (owner = receiver, remote = transmitter). Reuses
    % revgnss.OneWayInterSatelliteRangingModel for all physics; this file contains no range
    % equation of its own.
    %
    % ANALYTIC PARTIALS, NOT A STENCIL. revgnss.OneWayInterSatelliteRangingModel.geometryPartials
    % returns a closed form for every column; H_owner/H_remote are built by direct evaluation of
    % that closed form, never by finite difference on the observable itself (only the
    % attitude-lever-arm Jacobian J_e = d(C_e*l_e)/d(attitude error) uses a central difference on
    % the DCM ALONE, for the eulerZYXError_rad convention, matching
    % revgnss.AttitudeKinematics.finiteDiffLeverArmJacobian's existing role in this codebase --
    % never a difference on the observable itself).
    %
    % NO ECEF -> ECI BRIDGE. The kernel is exactly frame-invariant (see
    % OneWayInterSatelliteRangingModel's header): range and range-rate are unchanged under any
    % rotation about a common origin, so revgnss.CommunicationEndpointState's own ECEF
    % positionEcef_m/velocityEcef_mps are used directly, with no frame conversion.

    properties (Constant)
        ObservableIdentifier = 'oneWayCode';
        SupportedPhysicalRecordClasses = {'revgnss.OneWayInterSatelliteObservationRecord'};
        SupportedProtocolIdentifier = 'oneWayBroadcastPnRanging';
        SupportedProcessedObservableType = 'oneWayCodeRange';
        SupportedProcessedUnits = 'm';
        ObservableRowUnits = 'm';
        ReferenceEpochRule = 'commonCoordinateEpoch';
        RequiredPersistentCalibrationTreatment = 'rejected';
        AttitudePitchGuard_rad = 1.3962634; % 80 deg: ZYX gimbal-adjacent guard, matches 2.3.1
    end

    methods (Static)
        function [block, diagnostics] = buildUpdateBlock(args)
            required = {'delivery','ownerState','remoteState','weightSelectionRule', ...
                'persistentCalibrationTreatment'};
            if ~isstruct(args) || ~isscalar(args)
                error('OneWayCodeRangeLinkUpdateAdapter:argsSchema', ...
                    'buildUpdateBlock requires a scalar struct.');
            end
            missing = setdiff(required,fieldnames(args));
            unknown = setdiff(fieldnames(args),required);
            if ~isempty(missing)
                error('OneWayCodeRangeLinkUpdateAdapter:argsSchema', ...
                    'buildUpdateBlock is missing argument %s.',missing{1});
            end
            if ~isempty(unknown)
                error('OneWayCodeRangeLinkUpdateAdapter:argsSchema', ...
                    'buildUpdateBlock received unsupported argument %s.',unknown{1});
            end

            delivery = args.delivery;
            ownerState = args.ownerState;
            remoteState = args.remoteState;
            if ~isa(delivery,'revgnss.LinkObservationDelivery')
                error('OneWayCodeRangeLinkUpdateAdapter:deliveryType', ...
                    'delivery must be a revgnss.LinkObservationDelivery.');
            end
            record = delivery.physicalObservationRecord;
            revgnss.OneWayCodeRangeLinkUpdateAdapter.requireSupportedRecord(record);

            revgnss.CommunicationEndpointStateProvider.requireSameEpochPair( ...
                ownerState, remoteState, delivery.coordinateEventEpoch_s);
            revgnss.CommunicationEndpointStateProvider.requireCompatibleCovarianceCoordinates( ...
                ownerState, remoteState);
            revgnss.CommunicationEndpointStateProvider.requireTerminalGeometryDeclared(ownerState);
            revgnss.CommunicationEndpointStateProvider.requireTerminalGeometryDeclared(remoteState);
            revgnss.OneWayCodeRangeLinkUpdateAdapter.requireTerminalIdentityMatchesRecord( ...
                ownerState, record, 'owner');
            revgnss.OneWayCodeRangeLinkUpdateAdapter.requireTerminalIdentityMatchesRecord( ...
                remoteState, record, 'remote');
            revgnss.OneWayCodeRangeLinkUpdateAdapter.requireLinearizableAttitude(ownerState,'owner');
            revgnss.OneWayCodeRangeLinkUpdateAdapter.requireLinearizableAttitude(remoteState,'remote');

            treatment = char(args.persistentCalibrationTreatment);
            if ~strcmp(treatment, ...
                    revgnss.OneWayCodeRangeLinkUpdateAdapter.RequiredPersistentCalibrationTreatment)
                error('OneWayCodeRangeLinkUpdateAdapter:persistentCalibrationTreatment', ...
                    'This adapter release supports only persistentCalibrationTreatment=''rejected''.');
            end
            if ~strcmp(treatment, delivery.persistentCalibrationTreatment)
                error('OneWayCodeRangeLinkUpdateAdapter:persistentCalibrationTreatmentMismatch', ...
                    'persistentCalibrationTreatment must equal the delivery''s own declared treatment.');
            end

            if ownerState.canonicalPhysicalAssetIndex ~= delivery.ownerCanonicalIndex || ...
                    remoteState.canonicalPhysicalAssetIndex ~= delivery.remoteCanonicalIndex
                error('OneWayCodeRangeLinkUpdateAdapter:canonicalIndexMismatch', ...
                    'An endpoint state''s canonical physical asset index does not match its delivery.');
            end

            revgnss.DistributedClockGaugeContract.requireEndpointPropagationDelayValid( ...
                ownerState, remoteState, record);

            receiverEndpoint = revgnss.OneWayInterSatelliteRangingModel.endpointFromCommunicationState( ...
                ownerState,'receiver');
            transmitterEndpoint = revgnss.OneWayInterSatelliteRangingModel.endpointFromCommunicationState( ...
                remoteState,'transmitter');
            [predictedValue, geometry] = revgnss.OneWayInterSatelliteRangingModel.predictProcessedValue( ...
                'oneWayCodeRange',receiverEndpoint,transmitterEndpoint);
            residual_m = record.processedValue-predictedValue;

            H_owner = revgnss.OneWayCodeRangeLinkUpdateAdapter.jacobianRow_( ...
                ownerState,'owner',geometry.lineOfSightUnit');
            H_owner(revgnss.OneWayCodeRangeLinkUpdateAdapter.indexFor_( ...
                ownerState.covarianceComponentOrder,'clockBiasError_m')) = 1;
            H_remote = revgnss.OneWayCodeRangeLinkUpdateAdapter.jacobianRow_( ...
                remoteState,'remote',-geometry.lineOfSightUnit');
            H_remote(revgnss.OneWayCodeRangeLinkUpdateAdapter.indexFor_( ...
                remoteState.covarianceComponentOrder,'clockBiasError_m')) = -1;

            Rind = record.covarianceBlock(record.covarianceRowIndex, record.covarianceRowIndex);
            if ~(isfinite(Rind) && Rind > 0)
                error('OneWayCodeRangeLinkUpdateAdapter:measurementCovariance', ...
                    'The record''s own-row measurement covariance must be finite and positive.');
            end
            remoteContribution_m2 = H_remote*remoteState.covarianceBlock*H_remote';
            remoteContribution_m2 = (remoteContribution_m2+remoteContribution_m2')/2;

            record_ = struct( ...
                'observationIdentifier',delivery.observationIdentifier, ...
                'deliveryIdentifier',delivery.deliveryIdentifier, ...
                'ownerAssetIdentifier',delivery.ownerAssetIdentifier, ...
                'remoteAssetIdentifier',delivery.remoteAssetIdentifier, ...
                'remoteProductIdentifier',delivery.remoteProductIdentifier, ...
                'coordinateEventEpoch_s',delivery.coordinateEventEpoch_s, ...
                'observableIdentifier',revgnss.OneWayCodeRangeLinkUpdateAdapter.ObservableIdentifier, ...
                'residual_m',residual_m, ...
                'ownerCovarianceComponentOrder',{ownerState.covarianceComponentOrder}, ...
                'remoteCovarianceComponentOrder',{remoteState.covarianceComponentOrder}, ...
                'ownerAttitudeErrorCoordinateConvention',ownerState.attitudeErrorCoordinateConvention, ...
                'remoteAttitudeErrorCoordinateConvention',remoteState.attitudeErrorCoordinateConvention, ...
                'ownerJacobian_mPerErrorUnit',H_owner, ...
                'remoteJacobian_mPerErrorUnit',H_remote, ...
                'independentMeasurementCovariance_m2',Rind, ...
                'remoteContributionCovariance_m2',remoteContribution_m2, ...
                'residualCovarianceAssembly','notAssembledInputsEligibleForSplitCovarianceIntersection', ...
                'persistentCalibrationTreatment',treatment, ...
                'calibrationStateIdentifiers',{{}}, ...
                'covarianceGroupIdentifiers',{{}}, ...
                'correlationPolicy','splitCovarianceIntersection', ...
                'weightSelectionRule',char(args.weightSelectionRule), ...
                'commonSourceContributionCovariances_m2',{{}}, ...
                'calibrationMappingJacobian_mPerCalibrationUnit',zeros(1,0), ...
                'calibrationStateUnits',{{}}, ...
                'persistentCalibrationReferenceLocalTag_s',NaN, ...
                'observableRowUnits',revgnss.OneWayCodeRangeLinkUpdateAdapter.ObservableRowUnits);
            block = revgnss.DistributedLinkUpdateBlock(record_);

            diagnostics = struct('predictedValue',predictedValue,'predictedValueUnits','m', ...
                'geometry',geometry);
        end

        function text = describeObservable()
            text = struct( ...
                'observableIdentifier',revgnss.OneWayCodeRangeLinkUpdateAdapter.ObservableIdentifier, ...
                'protocolIdentifier',revgnss.OneWayCodeRangeLinkUpdateAdapter.SupportedProtocolIdentifier, ...
                'residualSignConvention','observedMinusPredicted', ...
                'jacobianQuantity','dPredictedObservablePerErrorCoordinate', ...
                'referenceEpochRule',revgnss.OneWayCodeRangeLinkUpdateAdapter.ReferenceEpochRule, ...
                'stencilIdentifier','analyticLineOfSightWithLeverArmJacobian');
        end

        function requireSupportedRecord(record)
            if ~isa(record,'revgnss.OneWayInterSatelliteObservationRecord')
                error('OneWayCodeRangeLinkUpdateAdapter:recordType', ...
                    'This adapter requires a revgnss.OneWayInterSatelliteObservationRecord.');
            end
            if ~strcmp(record.protocolIdentifier, ...
                    revgnss.OneWayCodeRangeLinkUpdateAdapter.SupportedProtocolIdentifier)
                error('OneWayCodeRangeLinkUpdateAdapter:protocol', ...
                    'Record protocolIdentifier does not match this adapter''s supported protocol.');
            end
            if ~strcmp(record.processedObservableType, ...
                    revgnss.OneWayCodeRangeLinkUpdateAdapter.SupportedProcessedObservableType) || ...
                    ~strcmp(record.processedUnits, ...
                    revgnss.OneWayCodeRangeLinkUpdateAdapter.SupportedProcessedUnits)
                error('OneWayCodeRangeLinkUpdateAdapter:processedObservableType', ...
                    'Record processedObservableType/processedUnits do not match this adapter.');
            end
            if ~strcmp(record.referenceEpochRule,revgnss.OneWayCodeRangeLinkUpdateAdapter.ReferenceEpochRule)
                error('OneWayCodeRangeLinkUpdateAdapter:referenceEpochRule', ...
                    'Record referenceEpochRule does not match this adapter''s supported rule.');
            end
            if ~record.available
                error('OneWayCodeRangeLinkUpdateAdapter:recordUnavailable', ...
                    'The physical record is not available.');
            end
            idx = record.covarianceRowIndex;
            n = size(record.covarianceBlock,1);
            if ~(isnumeric(idx) && isscalar(idx) && idx == round(idx) && idx >= 1 && idx <= n)
                error('OneWayCodeRangeLinkUpdateAdapter:covarianceRowIndex', ...
                    'Record covarianceRowIndex is out of range for its own covarianceBlock.');
            end
        end

        function requireTerminalIdentityMatchesRecord(endpointState, record, role)
            if ~(ischar(role) && any(strcmp(role,{'owner','remote'})))
                error('OneWayCodeRangeLinkUpdateAdapter:role', ...
                    'role must be ''owner'' or ''remote''.');
            end
            terminal = endpointState.terminalGeometry;
            if strcmp(role,'owner')
                if ~strcmp(terminal.receiveTerminalIdentifier,record.receiveTerminalIdentifier) || ...
                        ~strcmp(terminal.receiveAntennaIdentifier,record.receiveAntennaIdentifier)
                    error('OneWayCodeRangeLinkUpdateAdapter:terminalGeometryMismatch', ...
                        'The owner (receiver) endpoint''s declared receive terminal geometry does not match the record.');
                end
            else
                if ~strcmp(terminal.transmitTerminalIdentifier,record.transmitTerminalIdentifier) || ...
                        ~strcmp(terminal.transmitAntennaIdentifier,record.transmitAntennaIdentifier)
                    error('OneWayCodeRangeLinkUpdateAdapter:terminalGeometryMismatch', ...
                        'The remote (transmitter) endpoint''s declared transmit terminal geometry does not match the record.');
                end
            end
        end

        function requireLinearizableAttitude(endpointState, role)
            pitch_rad = endpointState.attitudeEulerZyx_rad(2);
            guard = revgnss.OneWayCodeRangeLinkUpdateAdapter.AttitudePitchGuard_rad;
            if ~(isfinite(pitch_rad) && abs(pitch_rad) <= guard)
                error('OneWayCodeRangeLinkUpdateAdapter:attitudeNotLinearizable', ...
                    'The %s endpoint''s pitch is too close to the ZYX gimbal singularity to linearize safely.',role);
            end
        end
    end

    methods (Static, Access = private)
        function H = jacobianRow_(endpointState, role, positionRow_1x3)
            % jacobianRow_  Direct analytic label-lookup assignment: position/attitude columns
            % from the closed-form kernel partial and the endpoint's own lever-arm Jacobian
            % (owner=receiver uses receivePhaseCentreOffset_body_m, remote=transmitter uses
            % transmitPhaseCentreOffset_body_m, matching OneWayInterSatelliteRangingModel.
            % endpointFromCommunicationState's own role dispatch); velocity/angular-rate/
            % clock-drift columns are declared and structurally zero for oneWayCodeRange (the
            % kernel has no dependence on them); the clock-bias column is set by the caller.
            order = endpointState.covarianceComponentOrder;
            n = numel(order);
            H = zeros(1,n);
            H(1:3) = positionRow_1x3;
            terminal = endpointState.terminalGeometry;
            if strcmp(role,'owner')
                lever = terminal.receivePhaseCentreOffset_body_m;
            else
                lever = terminal.transmitPhaseCentreOffset_body_m;
            end
            rotation = revgnss.AttitudeKinematics.bodyToEcefRotation(endpointState.attitudeEulerZyx_rad);
            if strcmp(endpointState.attitudeErrorCoordinateConvention,'rightMultiplicativeLocalTangent_rad')
                skewLever = [0,-lever(3),lever(2); lever(3),0,-lever(1); -lever(2),lever(1),0];
                J = -rotation*skewLever;
            else
                J = revgnss.AttitudeKinematics.finiteDiffLeverArmJacobian( ...
                    endpointState.attitudeEulerZyx_rad,lever,1e-6);
            end
            attitudeCols = revgnss.OneWayCodeRangeLinkUpdateAdapter.indexRangeFor_(order,7,9);
            H(attitudeCols) = positionRow_1x3*J;
        end

        function index = indexFor_(covarianceComponentOrder, label)
            index = find(strcmp(covarianceComponentOrder,label),1);
            if isempty(index)
                error('OneWayCodeRangeLinkUpdateAdapter:componentOrder', ...
                    'covarianceComponentOrder does not declare ''%s''.',label);
            end
        end

        function idx = indexRangeFor_(covarianceComponentOrder, startLabelIdx, endLabelIdx)
            if numel(covarianceComponentOrder) ~= 14
                error('OneWayCodeRangeLinkUpdateAdapter:componentOrder', ...
                    'covarianceComponentOrder must have exactly 14 entries (frozen v1 schema).');
            end
            idx = startLabelIdx:endLabelIdx;
        end
    end
end
