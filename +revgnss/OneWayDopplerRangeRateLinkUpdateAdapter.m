classdef OneWayDopplerRangeRateLinkUpdateAdapter
    % OneWayDopplerRangeRateLinkUpdateAdapter  Plan Section 2.3 item 3 concrete adapter: the
    % one-way ISL range-rate (Doppler) observable (owner = receiver, remote = transmitter).
    % Reuses revgnss.OneWayInterSatelliteRangingModel for all physics.
    %
    % THE POSITION/LINE-OF-SIGHT DERIVATIVE IS INCLUDED, NOT APPROXIMATED. For
    % rangeRate = u'*deltaVelocity with u = delta/||delta||, differentiating with respect to the
    % receiver's own position gives d(rangeRate)/d(r_owner) = deltaVelocity' * (I - u*u')/||delta||
    % -- the component of relative velocity PERPENDICULAR to the line of sight, divided by
    % range (revgnss.OneWayInterSatelliteRangingModel.geometryPartials.dRangeRate_dReceiverPosition,
    % verified in this adapter's own test against an independent five-point oracle to 1e-9
    % relative and shown exactly orthogonal to the line of sight). Omitting this term (as the
    % legacy revgnss.ISLMeasurementBuilder's velocity-only Doppler partial does) makes the row
    % structurally blind to position while its residual still contains the position error, so
    % the Kalman gain would be systematically wrong, not merely suboptimal.
    %
    % NO ECEF -> ECI BRIDGE, for the same exact-frame-invariance reason as the code-range
    % adapter -- see revgnss.OneWayInterSatelliteRangingModel's header.

    properties (Constant)
        ObservableIdentifier = 'oneWayDoppler';
        SupportedPhysicalRecordClasses = {'revgnss.OneWayInterSatelliteObservationRecord'};
        SupportedProtocolIdentifier = 'oneWayBroadcastPnRanging';
        SupportedProcessedObservableType = 'oneWayRangeRate';
        SupportedProcessedUnits = 'm/s';
        ObservableRowUnits = 'm/s';
        ReferenceEpochRule = 'commonCoordinateEpoch';
        RequiredPersistentCalibrationTreatment = 'rejected';
        AttitudePitchGuard_rad = 1.3962634;
    end

    methods (Static)
        function [block, diagnostics] = buildUpdateBlock(args)
            required = {'delivery','ownerState','remoteState','weightSelectionRule', ...
                'persistentCalibrationTreatment'};
            if ~isstruct(args) || ~isscalar(args)
                error('OneWayDopplerRangeRateLinkUpdateAdapter:argsSchema', ...
                    'buildUpdateBlock requires a scalar struct.');
            end
            missing = setdiff(required,fieldnames(args));
            unknown = setdiff(fieldnames(args),required);
            if ~isempty(missing)
                error('OneWayDopplerRangeRateLinkUpdateAdapter:argsSchema', ...
                    'buildUpdateBlock is missing argument %s.',missing{1});
            end
            if ~isempty(unknown)
                error('OneWayDopplerRangeRateLinkUpdateAdapter:argsSchema', ...
                    'buildUpdateBlock received unsupported argument %s.',unknown{1});
            end

            delivery = args.delivery;
            ownerState = args.ownerState;
            remoteState = args.remoteState;
            if ~isa(delivery,'revgnss.LinkObservationDelivery')
                error('OneWayDopplerRangeRateLinkUpdateAdapter:deliveryType', ...
                    'delivery must be a revgnss.LinkObservationDelivery.');
            end
            record = delivery.physicalObservationRecord;
            revgnss.OneWayDopplerRangeRateLinkUpdateAdapter.requireSupportedRecord(record);

            revgnss.CommunicationEndpointStateProvider.requireSameEpochPair( ...
                ownerState, remoteState, delivery.coordinateEventEpoch_s);
            revgnss.CommunicationEndpointStateProvider.requireCompatibleCovarianceCoordinates( ...
                ownerState, remoteState);
            revgnss.CommunicationEndpointStateProvider.requireTerminalGeometryDeclared(ownerState);
            revgnss.CommunicationEndpointStateProvider.requireTerminalGeometryDeclared(remoteState);
            revgnss.OneWayDopplerRangeRateLinkUpdateAdapter.requireTerminalIdentityMatchesRecord( ...
                ownerState, record, 'owner');
            revgnss.OneWayDopplerRangeRateLinkUpdateAdapter.requireTerminalIdentityMatchesRecord( ...
                remoteState, record, 'remote');
            revgnss.OneWayDopplerRangeRateLinkUpdateAdapter.requireLinearizableAttitude(ownerState,'owner');
            revgnss.OneWayDopplerRangeRateLinkUpdateAdapter.requireLinearizableAttitude(remoteState,'remote');

            treatment = char(args.persistentCalibrationTreatment);
            if ~strcmp(treatment, ...
                    revgnss.OneWayDopplerRangeRateLinkUpdateAdapter.RequiredPersistentCalibrationTreatment)
                error('OneWayDopplerRangeRateLinkUpdateAdapter:persistentCalibrationTreatment', ...
                    'This adapter release supports only persistentCalibrationTreatment=''rejected''.');
            end
            if ~strcmp(treatment, delivery.persistentCalibrationTreatment)
                error('OneWayDopplerRangeRateLinkUpdateAdapter:persistentCalibrationTreatmentMismatch', ...
                    'persistentCalibrationTreatment must equal the delivery''s own declared treatment.');
            end

            if ownerState.canonicalPhysicalAssetIndex ~= delivery.ownerCanonicalIndex || ...
                    remoteState.canonicalPhysicalAssetIndex ~= delivery.remoteCanonicalIndex
                error('OneWayDopplerRangeRateLinkUpdateAdapter:canonicalIndexMismatch', ...
                    'An endpoint state''s canonical physical asset index does not match its delivery.');
            end

            revgnss.DistributedClockGaugeContract.requireEndpointPropagationDelayValid( ...
                ownerState, remoteState, record);

            receiverEndpoint = revgnss.OneWayInterSatelliteRangingModel.endpointFromCommunicationState( ...
                ownerState,'receiver');
            transmitterEndpoint = revgnss.OneWayInterSatelliteRangingModel.endpointFromCommunicationState( ...
                remoteState,'transmitter');
            [predictedValue, geometry] = revgnss.OneWayInterSatelliteRangingModel.predictProcessedValue( ...
                'oneWayRangeRate',receiverEndpoint,transmitterEndpoint);
            partials = revgnss.OneWayInterSatelliteRangingModel.geometryPartials(geometry);
            residual_mps = record.processedValue-predictedValue;

            H_owner = revgnss.OneWayDopplerRangeRateLinkUpdateAdapter.jacobianRow_( ...
                ownerState,'owner',partials.dRangeRate_dReceiverPosition,partials.lineOfSightUnit');
            H_owner(revgnss.OneWayDopplerRangeRateLinkUpdateAdapter.indexFor_( ...
                ownerState.covarianceComponentOrder,'clockDriftError_mps')) = 1;
            H_remote = revgnss.OneWayDopplerRangeRateLinkUpdateAdapter.jacobianRow_( ...
                remoteState,'remote',-partials.dRangeRate_dReceiverPosition,-partials.lineOfSightUnit');
            H_remote(revgnss.OneWayDopplerRangeRateLinkUpdateAdapter.indexFor_( ...
                remoteState.covarianceComponentOrder,'clockDriftError_mps')) = -1;

            Rind = record.covarianceBlock(record.covarianceRowIndex, record.covarianceRowIndex);
            if ~(isfinite(Rind) && Rind > 0)
                error('OneWayDopplerRangeRateLinkUpdateAdapter:measurementCovariance', ...
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
                'observableIdentifier', ...
                    revgnss.OneWayDopplerRangeRateLinkUpdateAdapter.ObservableIdentifier, ...
                'residual_m',residual_mps, ...
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
                'observableRowUnits', ...
                    revgnss.OneWayDopplerRangeRateLinkUpdateAdapter.ObservableRowUnits);
            block = revgnss.DistributedLinkUpdateBlock(record_);

            diagnostics = struct('predictedValue',predictedValue,'predictedValueUnits','m/s', ...
                'geometry',geometry,'partials',partials);
        end

        function text = describeObservable()
            text = struct( ...
                'observableIdentifier', ...
                    revgnss.OneWayDopplerRangeRateLinkUpdateAdapter.ObservableIdentifier, ...
                'protocolIdentifier', ...
                    revgnss.OneWayDopplerRangeRateLinkUpdateAdapter.SupportedProtocolIdentifier, ...
                'residualSignConvention','observedMinusPredicted', ...
                'jacobianQuantity','dPredictedObservablePerErrorCoordinate', ...
                'referenceEpochRule',revgnss.OneWayDopplerRangeRateLinkUpdateAdapter.ReferenceEpochRule, ...
                'stencilIdentifier','analyticLineOfSightWithLeverArmJacobian');
        end

        function requireSupportedRecord(record)
            if ~isa(record,'revgnss.OneWayInterSatelliteObservationRecord')
                error('OneWayDopplerRangeRateLinkUpdateAdapter:recordType', ...
                    'This adapter requires a revgnss.OneWayInterSatelliteObservationRecord.');
            end
            if ~strcmp(record.protocolIdentifier, ...
                    revgnss.OneWayDopplerRangeRateLinkUpdateAdapter.SupportedProtocolIdentifier)
                error('OneWayDopplerRangeRateLinkUpdateAdapter:protocol', ...
                    'Record protocolIdentifier does not match this adapter''s supported protocol.');
            end
            if ~strcmp(record.processedObservableType, ...
                    revgnss.OneWayDopplerRangeRateLinkUpdateAdapter.SupportedProcessedObservableType) || ...
                    ~strcmp(record.processedUnits, ...
                    revgnss.OneWayDopplerRangeRateLinkUpdateAdapter.SupportedProcessedUnits)
                error('OneWayDopplerRangeRateLinkUpdateAdapter:processedObservableType', ...
                    'Record processedObservableType/processedUnits do not match this adapter.');
            end
            if ~strcmp(record.referenceEpochRule, ...
                    revgnss.OneWayDopplerRangeRateLinkUpdateAdapter.ReferenceEpochRule)
                error('OneWayDopplerRangeRateLinkUpdateAdapter:referenceEpochRule', ...
                    'Record referenceEpochRule does not match this adapter''s supported rule.');
            end
            if ~record.available
                error('OneWayDopplerRangeRateLinkUpdateAdapter:recordUnavailable', ...
                    'The physical record is not available.');
            end
            idx = record.covarianceRowIndex;
            n = size(record.covarianceBlock,1);
            if ~(isnumeric(idx) && isscalar(idx) && idx == round(idx) && idx >= 1 && idx <= n)
                error('OneWayDopplerRangeRateLinkUpdateAdapter:covarianceRowIndex', ...
                    'Record covarianceRowIndex is out of range for its own covarianceBlock.');
            end
        end

        function requireTerminalIdentityMatchesRecord(endpointState, record, role)
            if ~(ischar(role) && any(strcmp(role,{'owner','remote'})))
                error('OneWayDopplerRangeRateLinkUpdateAdapter:role', ...
                    'role must be ''owner'' or ''remote''.');
            end
            terminal = endpointState.terminalGeometry;
            if strcmp(role,'owner')
                if ~strcmp(terminal.receiveTerminalIdentifier,record.receiveTerminalIdentifier) || ...
                        ~strcmp(terminal.receiveAntennaIdentifier,record.receiveAntennaIdentifier)
                    error('OneWayDopplerRangeRateLinkUpdateAdapter:terminalGeometryMismatch', ...
                        'The owner (receiver) endpoint''s declared receive terminal geometry does not match the record.');
                end
            else
                if ~strcmp(terminal.transmitTerminalIdentifier,record.transmitTerminalIdentifier) || ...
                        ~strcmp(terminal.transmitAntennaIdentifier,record.transmitAntennaIdentifier)
                    error('OneWayDopplerRangeRateLinkUpdateAdapter:terminalGeometryMismatch', ...
                        'The remote (transmitter) endpoint''s declared transmit terminal geometry does not match the record.');
                end
            end
        end

        function requireLinearizableAttitude(endpointState, role)
            pitch_rad = endpointState.attitudeEulerZyx_rad(2);
            guard = revgnss.OneWayDopplerRangeRateLinkUpdateAdapter.AttitudePitchGuard_rad;
            if ~(isfinite(pitch_rad) && abs(pitch_rad) <= guard)
                error('OneWayDopplerRangeRateLinkUpdateAdapter:attitudeNotLinearizable', ...
                    'The %s endpoint''s pitch is too close to the ZYX gimbal singularity to linearize safely.',role);
            end
        end
    end

    methods (Static, Access = private)
        function H = jacobianRow_(endpointState, role, positionRow_1x3, velocityRow_1x3)
            % jacobianRow_  Position column from the closed-form dRangeRate/dPosition partial
            % (transformed through the SAME lever-arm attitude Jacobian the code-range adapter
            % uses, since the lever arm enters the receiver/transmitter phase-centre position
            % identically for both observables); velocity column is the line-of-sight unit
            % vector (dRangeRate/dVelocity = u'); angular-rate/clock-bias columns are declared
            % and structurally zero (the lever-arm RATE term is not modelled -- see
            % OneWayInterSatelliteRangingModel's header); the clock-drift column is set by the
            % caller.
            order = endpointState.covarianceComponentOrder;
            n = numel(order);
            H = zeros(1,n);
            H(1:3) = positionRow_1x3;
            H(4:6) = velocityRow_1x3;
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
            attitudeCols = revgnss.OneWayDopplerRangeRateLinkUpdateAdapter.indexRangeFor_(order,7,9);
            H(attitudeCols) = positionRow_1x3*J;
        end

        function index = indexFor_(covarianceComponentOrder, label)
            index = find(strcmp(covarianceComponentOrder,label),1);
            if isempty(index)
                error('OneWayDopplerRangeRateLinkUpdateAdapter:componentOrder', ...
                    'covarianceComponentOrder does not declare ''%s''.',label);
            end
        end

        function idx = indexRangeFor_(covarianceComponentOrder, startLabelIdx, endLabelIdx)
            if numel(covarianceComponentOrder) ~= 14
                error('OneWayDopplerRangeRateLinkUpdateAdapter:componentOrder', ...
                    'covarianceComponentOrder must have exactly 14 entries (frozen v1 schema).');
            end
            idx = startLabelIdx:endLabelIdx;
        end
    end
end
