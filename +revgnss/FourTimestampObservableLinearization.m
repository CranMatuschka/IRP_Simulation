classdef FourTimestampObservableLinearization
    % FourTimestampObservableLinearization  Plan Section 4.3 item 6: the FD-stencil Jacobian
    % engine, item-6-required to be verified against finite differences (which every column here
    % literally IS -- production and verification share no closed form to drift apart from).
    %
    % Three entries: islTwoEndpointJacobian (distributed-ISL path, both endpoints dynamic,
    % 14 columns each), groundSpaceJacobian (ground-space/local-EKF path, only the spacecraft is
    % dynamic, 11 columns, tower fixed truth/broadcast-product), calibrationMappingJacobian (item
    % 6's "owned calibration states" -- the 4 closed-form-checkable sensitivities to
    % revgnss.ReciprocalLinkHardwareModel's declared terminal delays).
    %
    % FD-STENCIL, NOT ANALYTIC. revgnss.CoherentTwoWayRangeLinkUpdateAdapter's own header states
    % outright "Both H_owner and H_remote are five-point central finite differences", and no
    % analytic attitude/lever-arm Jacobian exists anywhere in this repo -- so every column here
    % (including clock bias/drift, which DO have clean closed forms, derived and cross-checked
    % only as an independent TEST assertion, never a second production code path) uses the same
    % 5-point central stencil (-f(2h)+8f(h)-8f(-h)+f(-2h))/(12h) against
    % revgnss.FourTimestampObservableBuilder.predictFromEndpointModels.
    %
    % ISL VS GROUND-SPACE ATTITUDE PERTURBATION -- SAME CONVENTION, DIFFERENT SOURCE OF TRUTH. The
    % ISL path perturbs a revgnss.CommunicationEndpointState's own declared
    % attitudeErrorCoordinateConvention (tangent via
    % revgnss.AttitudeErrorStateKinematics.smallAnglePerturbedDcm -- the SAME right-multiplicative
    % operator the MEKF itself uses -- or plain additive Euler), mirroring
    % revgnss.CoherentTwoWayRangeLinkUpdateAdapter.columnPerturbationKinds/stepAndPerturbFn_
    % exactly (duplicated here rather than called through: that method is public, but calling
    % into a Section 2.3.1 concrete adapter class from a Section 4.3 physics class was judged an
    % unwanted cross-section coupling for a ~15-line, genuinely reusable, frozen-schema-only
    % utility). The ground-space path's revgnss.AssetStateBlock has no convention tag of its own
    % (it is a raw local-EKF state vector, not a revgnss.CommunicationEndpointState) -- so
    % groundSpaceJacobian instead dispatches on the CALLER-SUPPLIED
    % options.attitudeParameterization ('quaternionErrorState' [default, matches
    % config/masterConfig.m:239's repo default] or 'eulerZYX'), exactly mirroring the established,
    % LIVE production precedent +revgnss/LinkGeometry.m:92-138
    % (finiteDiffAttitudeJacobian): quaternionErrorState perturbs the NOMINAL body->ECEF DCM in
    % tangent space via smallAnglePerturbedDcm (the x(blk.euler) column of a local EKF's OWN state
    % vector is a zeroed tangent ERROR state under this parameterization, not literal Euler
    % angles -- revgnss.AssetStateBlock's x itself supplies the NOMINAL Euler angles this
    % dispatch perturbs around only when the caller has already substituted
    % filter.ReverseGNSSEKF.getMeasurementState()'s nominal-attitude view, exactly as every other
    % measurement Jacobian in this repo requires); eulerZYX perturbs the Euler angles additively
    % (legacy, matching this class's ISL 'attitudeEuler' kind and the pre-fix behavior for a
    % caller that explicitly opts out of the tangent convention). Defaulting to
    % quaternionErrorState (rather than defaulting to legacy Euler and requiring an explicit
    % opt-in) is deliberate: a Section 4.4 caller that does not think to pass this option gets the
    % REPO'S OWN DEFAULT convention, not a silently-wrong one.

    properties (Constant)
        DefaultLinearizationSteps = struct('positionStep_m',0.25,'velocityStep_mps',0.025, ...
            'attitudeStep_rad',5e-3,'clockBiasStep_m',5,'clockDriftStep_mps',0.005);
            % position/velocity/clockBias/clockDrift match test_coherent_two_way_code_physical_
            % jacobian.m:38-40. attitudeStep_rad is WIDER than that file's 5e-4: measured
            % empirically (Stage 4.3 combined review + independent re-confirmation during the
            % review's fix pass) that this specific four-timestamp observable's attitude columns
            % are noise-dominated (~1.8e-5 relative FD wobble) at 5e-4 -- a genuine step-size-vs-
            % floating-point-cancellation tradeoff, not truncation error, since 5e-3/1e-2 both
            % agree with an independent oracle comfortably inside the strict global tolerance
            % while 5e-4 does not. No terminalDelayStep_s here: calibrationMappingJacobian below
            % returns a closed form directly and takes no finite-difference step at all.
        AttitudePitchGuard_rad = 1.3962634; % 80 deg ZYX gimbal-adjacent guard, matches
                                             % CoherentTwoWayRangeLinkUpdateAdapter's own constant
                                             % (that constant is public there too; duplicated here,
                                             % like the perturbation-kind helpers below, to avoid a
                                             % Section-4.3-depends-on-Section-2.3.1 coupling for a
                                             % single scalar).
    end

    methods (Static)
        function [H_owner, H_remote, ownerKinds, remoteKinds, nominalValue_m] = islTwoEndpointJacobian( ...
                ownerEndpointState, remoteEndpointState, ownerRole, hardware, t4_s, options)
            if ~isa(ownerEndpointState,'revgnss.CommunicationEndpointState') || ...
                    ~isa(remoteEndpointState,'revgnss.CommunicationEndpointState')
                error('FourTimestampObservableLinearization:endpointStateType', ...
                    'islTwoEndpointJacobian requires two revgnss.CommunicationEndpointState endpoints.');
            end
            if ~any(strcmp(ownerRole,{'origin','destination'}))
                error('FourTimestampObservableLinearization:ownerRole', ...
                    'ownerRole must be ''origin'' or ''destination''.');
            end
            if nargin < 6 || isempty(options); options = struct(); end
            options = revgnss.FourTimestampObservableLinearization.normalizeOptions_(options);
            predictOptions = struct('terminalDelayAllocation',options.terminalDelayAllocation, ...
                'solverOptions',options.solverOptions);

            revgnss.FourTimestampObservableLinearization.requireLinearizableAttitude_( ...
                ownerEndpointState,'owner');
            revgnss.FourTimestampObservableLinearization.requireLinearizableAttitude_( ...
                remoteEndpointState,'remote');

            ownerIsOrigin = strcmp(ownerRole,'origin');
            [nominalValue_m,~] = revgnss.FourTimestampObservableLinearization.evaluateRolePair_( ...
                ownerEndpointState, remoteEndpointState, ownerIsOrigin, hardware, t4_s, predictOptions);

            [H_owner, ownerKinds] = revgnss.FourTimestampObservableLinearization.rolePerturbationJacobian_( ...
                ownerEndpointState, remoteEndpointState, ownerIsOrigin, true, hardware, t4_s, ...
                predictOptions, options.linearizationSteps);
            [H_remote, remoteKinds] = revgnss.FourTimestampObservableLinearization.rolePerturbationJacobian_( ...
                ownerEndpointState, remoteEndpointState, ownerIsOrigin, false, hardware, t4_s, ...
                predictOptions, options.linearizationSteps);
        end

        function [H_spacecraft, spacecraftKinds, nominalValue_m] = groundSpaceJacobian( ...
                x, stateMap, assetIdx, spacecraftTerminalGeometry, towerEndpoint, hardware, t4_s, options)
            % x must already reflect the NOMINAL attitude the caller wants linearized about --
            % under quaternionErrorState (options.attitudeParameterization's default), that means
            % x(blk.euler) is filter.ReverseGNSSEKF.getMeasurementState()'s nominal-Euler
            % substitution, NOT a live error-state x whose euler slot is a zeroed tangent error
            % (confirmed: filter.ReverseGNSSEKF.getMeasurementState/getReportEulerRad). This
            % method has no way to detect that substitution was skipped -- exactly the same
            % caller contract every other measurement-Jacobian builder in this repo already
            % relies on (e.g. models.measurements.CodeJacobianBuilder), not a new obligation.
            if ~isa(towerEndpoint,'revgnss.TwoWayCodeEndpointModel')
                error('FourTimestampObservableLinearization:towerEndpointType', ...
                    'groundSpaceJacobian requires a revgnss.TwoWayCodeEndpointModel tower endpoint.');
            end
            if nargin < 8 || isempty(options); options = struct(); end
            options = revgnss.FourTimestampObservableLinearization.normalizeOptions_(options);
            predictOptions = struct('terminalDelayAllocation',options.terminalDelayAllocation, ...
                'solverOptions',options.solverOptions);

            blk = revgnss.AssetStateBlock.forAsset(stateMap, assetIdx);
            if isempty(blk.r) || isempty(blk.v) || isempty(blk.euler) || isempty(blk.b) || isempty(blk.bdot)
                error('FourTimestampObservableLinearization:stateBlock', ...
                    ['The resolved AssetStateBlock is missing a required position/velocity/' ...
                    'attitude/clock column.']);
            end

            positionNominal_m = x(blk.r);
            velocityNominal_mps = x(blk.v);
            eulerNominal_rad = x(blk.euler);
            clockBiasNominal_m = x(blk.b);
            clockDriftNominal_mps = x(blk.bdot);

            revgnss.FourTimestampObservableLinearization.requireLinearizablePitch_( ...
                eulerNominal_rad(2), 'spacecraft');

            useTangentAttitude = strcmp(options.attitudeParameterization,'quaternionErrorState');
            if useTangentAttitude
                attitudeKind = 'attitudeTangent';
            else
                attitudeKind = 'attitudeEuler';
            end
            spacecraftKinds = [repmat({'position'},1,3), repmat({'velocity'},1,3), ...
                repmat({attitudeKind},1,3), {'clockBias'}, {'clockDrift'}];
            steps = options.linearizationSteps;
            columnSteps = [repmat(steps.positionStep_m,1,3), repmat(steps.velocityStep_mps,1,3), ...
                repmat(steps.attitudeStep_rad,1,3), steps.clockBiasStep_m, steps.clockDriftStep_mps];

            nominalRotation = revgnss.AttitudeKinematics.bodyToEcefRotation(eulerNominal_rad);

            nominalSpacecraft = revgnss.FourTimestampEstimatorEndpointBridge.fromAssetStateBlock( ...
                x, stateMap, assetIdx, spacecraftTerminalGeometry, t4_s, 'spacecraft');
            [nominalValue_m,~] = revgnss.FourTimestampObservableBuilder.predictFromEndpointModels( ...
                towerEndpoint, nominalSpacecraft, hardware, t4_s, predictOptions);

            H_spacecraft = zeros(1,11);
            for k = 1:11
                stepSize = columnSteps(k);
                evalFn = @(delta) revgnss.FourTimestampObservableLinearization.predictGroundSpaceAt_( ...
                    x, stateMap, assetIdx, spacecraftTerminalGeometry, towerEndpoint, hardware, t4_s, ...
                    predictOptions, positionNominal_m, velocityNominal_mps, eulerNominal_rad, ...
                    clockBiasNominal_m, clockDriftNominal_mps, nominalRotation, useTangentAttitude, k, delta);
                H_spacecraft(k) = revgnss.FourTimestampObservableLinearization.fivePointCentralDifference_( ...
                    evalFn, stepSize);
            end
        end

        function [dValue_dOrigin, dValue_dAnchor, dOriginDiag_dOrigin, dAnchorDiag_dAnchor] = ...
                calibrationMappingJacobian(originEndpoint, destinationEndpoint, hardware, t4_s, options)
            % Item 6's "owned calibration states" columns. DIMENSIONLESS (metres of processed
            % clock-difference value per metre of calibration-state delay), matching
            % revgnss.DistributedLinkUpdateBlock.calibrationStateUnits' only allowed value 'm' and
            % that class's own documented contract that "the seconds-to-metres mapping factor
            % c/2c is a Section 2.3 adapter responsibility" -- an EARLIER revision of this method
            % returned d(value_m)/d(delay_s) (an m/s-scaled value, ~0.5*c), which is off from the
            % correct d(value_m)/d(delay_m) by exactly a factor of c (Stage 4.3 combined review
            % blocking finding 2 -- the same bug CLASS as Section 4.2's own review's blocking-1
            % finding, there m^2 mislabeled s^2).
            %
            % CLOSED FORM, NOT FINITE DIFFERENCE. revgnss.FourTimestampObservableBuilder.
            % applyTerminalDelayAllocation_ is exactly AFFINE in originDelay_s/anchorDelay_s (each
            % delay enters through one fixed additive coefficient per allocation, confirmed by the
            % direct algebraic expansion below), and reduceClockDifference_ is a fixed linear
            % combination of the four corrected tags -- so the full chain
            % originDelay_s/anchorDelay_s -> value_s is affine in closed form, with NO dependence
            % on the raw tag values, t4_s, or endpoint geometry at all. An earlier revision used a
            % forward difference against predictFromEndpointModels instead; the Stage 4.3 combined
            % review found that approach epoch-fragile (double-precision cancellation in
            % reduceClockDifference_ scales with the magnitude of t4_s, growing from negligible at
            % t4_s=0 to a measurable error at realistic epoch magnitudes -- major finding 4).
            % Returning the closed form directly is exact at any t4_s (zero truncation AND zero
            % cancellation error) and is cross-checked independently against
            % predictFromEndpointModels' own finite difference by this method's own test, not
            % trusted blindly here.
            %
            %   receiveEvent : dValue_dOrigin=-0.5  dValue_dAnchor=+0.5
            %   transmitEvent: dValue_dOrigin=+0.5  dValue_dAnchor=-0.5
            %   splitEvenly  : dValue_dOrigin=0     dValue_dAnchor=0    (the allocation shifts all
            %                  four tags symmetrically, so it cancels exactly out of the classical
            %                  (t2-t1)-(t4-t3) combination -- verified algebraically, not assumed)
            %   dOriginDiag_dOrigin=+1 and dAnchorDiag_dAnchor=-1 for EVERY allocation:
            %   originRoundTrip_s=t4-t1 and anchorTurnaround_s=t3-t2 each depend on exactly one
            %   delay term, with a coefficient no allocation changes.
            %
            % originEndpoint/destinationEndpoint/hardware/t4_s are validated but otherwise unused
            % by the computation itself (the closed form depends only on the declared
            % terminalDelayAllocation) -- kept in the signature for calling-convention consistency
            % with islTwoEndpointJacobian/groundSpaceJacobian, and so a caller passing the wrong
            % type still fails fast rather than silently.
            if ~isa(originEndpoint,'revgnss.TwoWayCodeEndpointModel') || ...
                    ~isa(destinationEndpoint,'revgnss.TwoWayCodeEndpointModel')
                error('FourTimestampObservableLinearization:endpointType', ...
                    'calibrationMappingJacobian requires two revgnss.TwoWayCodeEndpointModel endpoints.');
            end
            if ~isa(hardware,'revgnss.ReciprocalLinkHardwareModel')
                error('FourTimestampObservableLinearization:hardwareType', ...
                    'calibrationMappingJacobian requires a revgnss.ReciprocalLinkHardwareModel.');
            end
            if ~(isnumeric(t4_s) && isscalar(t4_s) && isfinite(t4_s))
                error('FourTimestampObservableLinearization:finalReceptionTime', ...
                    't4_s must be a finite scalar.');
            end
            if nargin < 5 || isempty(options); options = struct(); end
            options = revgnss.FourTimestampObservableLinearization.normalizeOptions_(options);

            switch options.terminalDelayAllocation
                case 'receiveEvent'
                    dValue_dOrigin = -0.5; dValue_dAnchor = 0.5;
                case 'transmitEvent'
                    dValue_dOrigin = 0.5; dValue_dAnchor = -0.5;
                case 'splitEvenly'
                    dValue_dOrigin = 0; dValue_dAnchor = 0;
                otherwise
                    error('FourTimestampObservableLinearization:terminalDelayAllocation', ...
                        'Unrecognised terminal delay allocation %s.',options.terminalDelayAllocation);
            end
            dOriginDiag_dOrigin = 1;
            dAnchorDiag_dAnchor = -1;
        end
    end

    methods (Static, Access = private)
        function options = normalizeOptions_(supplied)
            if ~isstruct(supplied) || ~isscalar(supplied)
                error('FourTimestampObservableLinearization:options', 'options must be a scalar structure.');
            end
            allowed = {'linearizationSteps','terminalDelayAllocation','solverOptions', ...
                'attitudeParameterization'};
            unknown = setdiff(fieldnames(supplied),allowed);
            if ~isempty(unknown)
                error('FourTimestampObservableLinearization:options', 'Unsupported option %s.',unknown{1});
            end
            options = struct( ...
                'linearizationSteps',revgnss.FourTimestampObservableLinearization.DefaultLinearizationSteps, ...
                'terminalDelayAllocation',revgnss.FourTimestampObservableBuilder.DefaultTerminalDelayAllocation, ...
                'solverOptions',struct(), ...
                'attitudeParameterization','quaternionErrorState');
            for k = 1:numel(allowed)
                if isfield(supplied,allowed{k})
                    options.(allowed{k}) = supplied.(allowed{k});
                end
            end
            if ~any(strcmp(options.attitudeParameterization,{'quaternionErrorState','eulerZYX'}))
                error('FourTimestampObservableLinearization:attitudeParameterization', ...
                    'attitudeParameterization must be ''quaternionErrorState'' or ''eulerZYX''.');
            end
            requiredStepFields = {'positionStep_m','velocityStep_mps','attitudeStep_rad', ...
                'clockBiasStep_m','clockDriftStep_mps'};
            missingSteps = setdiff(requiredStepFields,fieldnames(options.linearizationSteps));
            if ~isempty(missingSteps)
                error('FourTimestampObservableLinearization:linearizationSteps', ...
                    'linearizationSteps is missing %s.',missingSteps{1});
            end
            for k = 1:numel(requiredStepFields)
                value = options.linearizationSteps.(requiredStepFields{k});
                if ~(isnumeric(value) && isscalar(value) && isfinite(value) && value > 0)
                    error('FourTimestampObservableLinearization:linearizationSteps', ...
                        '%s must be a finite positive scalar.',requiredStepFields{k});
                end
            end
        end

        function requireLinearizableAttitude_(endpointState, role)
            revgnss.FourTimestampObservableLinearization.requireLinearizablePitch_( ...
                endpointState.attitudeEulerZyx_rad(2), role);
        end

        function requireLinearizablePitch_(pitch_rad, role)
            guard = revgnss.FourTimestampObservableLinearization.AttitudePitchGuard_rad;
            if ~(isfinite(pitch_rad) && abs(pitch_rad) <= guard)
                error('FourTimestampObservableLinearization:attitudeNotLinearizable', ...
                    ['The %s endpoint''s pitch is too close to the ZYX gimbal singularity to ' ...
                    'linearize safely.'],role);
            end
        end

        function [value_m, prediction] = evaluateRolePair_(ownerEndpointState, remoteEndpointState, ...
                ownerIsOrigin, hardware, t4_s, predictOptions)
            ownerModel = revgnss.FourTimestampEstimatorEndpointBridge.fromCommunicationEndpointState( ...
                ownerEndpointState, 'owner');
            remoteModel = revgnss.FourTimestampEstimatorEndpointBridge.fromCommunicationEndpointState( ...
                remoteEndpointState, 'remote');
            if ownerIsOrigin
                originModel = ownerModel; destinationModel = remoteModel;
            else
                originModel = remoteModel; destinationModel = ownerModel;
            end
            [value_m, prediction] = revgnss.FourTimestampObservableBuilder.predictFromEndpointModels( ...
                originModel, destinationModel, hardware, t4_s, predictOptions);
        end

        function [H, kinds] = rolePerturbationJacobian_(ownerEndpointState, remoteEndpointState, ...
                ownerIsOrigin, perturbOwner, hardware, t4_s, predictOptions, steps)
            if perturbOwner
                perturbState = ownerEndpointState; perturbIsOrigin = ownerIsOrigin;
                fixedState = remoteEndpointState;
            else
                perturbState = remoteEndpointState; perturbIsOrigin = ~ownerIsOrigin;
                fixedState = ownerEndpointState;
            end
            kinds = revgnss.FourTimestampObservableLinearization.columnPerturbationKinds_( ...
                perturbState.covarianceComponentOrder, perturbState.attitudeErrorCoordinateConvention);
            nominalRotation = revgnss.AttitudeKinematics.bodyToEcefRotation( ...
                perturbState.attitudeEulerZyx_rad);
            fixedModel = revgnss.FourTimestampEstimatorEndpointBridge.fromCommunicationEndpointState( ...
                fixedState, 'fixed');

            H = zeros(1,numel(kinds));
            for k = 1:numel(kinds)
                kind = kinds{k};
                if strcmp(kind,'angularRate')
                    H(k) = 0; % declared and structurally zero: constant-attitude endpoint model
                    continue
                end
                [stepSize, perturbFn] = revgnss.FourTimestampObservableLinearization.stepAndPerturbFn_( ...
                    kind, k, steps, nominalRotation);
                evalFn = @(delta) revgnss.FourTimestampObservableLinearization.predictWithPerturbedRole_( ...
                    perturbState, perturbIsOrigin, fixedModel, hardware, t4_s, predictOptions, ...
                    perturbFn(delta));
                H(k) = revgnss.FourTimestampObservableLinearization.fivePointCentralDifference_( ...
                    evalFn, stepSize);
            end
        end

        function value_m = predictWithPerturbedRole_(perturbState, perturbIsOrigin, fixedModel, ...
                hardware, t4_s, predictOptions, perturbation)
            if isfield(perturbation,'eulerDelta_rad')
                rotation = revgnss.AttitudeKinematics.bodyToEcefRotation( ...
                    perturbState.attitudeEulerZyx_rad + perturbation.eulerDelta_rad);
            else
                rotation = perturbation.rotation;
            end
            perturbedModel = revgnss.FourTimestampEstimatorEndpointBridge.fromCommunicationEndpointState( ...
                perturbState, 'perturbed', ...
                perturbState.positionEcef_m + perturbation.positionDelta_m, ...
                perturbState.velocityEcef_mps + perturbation.velocityDelta_mps, ...
                rotation, ...
                perturbState.clockBias_m + perturbation.clockBiasDelta_m, ...
                perturbState.clockDriftRate_mps + perturbation.clockDriftDelta_mps);
            if perturbIsOrigin
                originModel = perturbedModel; destinationModel = fixedModel;
            else
                originModel = fixedModel; destinationModel = perturbedModel;
            end
            [value_m,~] = revgnss.FourTimestampObservableBuilder.predictFromEndpointModels( ...
                originModel, destinationModel, hardware, t4_s, predictOptions);
        end

        function value_m = predictGroundSpaceAt_(x, stateMap, assetIdx, terminalGeometry, ...
                towerEndpoint, hardware, t4_s, predictOptions, positionNominal_m, velocityNominal_mps, ...
                eulerNominal_rad, clockBiasNominal_m, clockDriftNominal_mps, nominalRotation, ...
                useTangentAttitude, columnIdx, delta)
            % Non-attitude columns perturb position/velocity/clock exactly as before, regardless of
            % useTangentAttitude. Attitude columns (7-9) dispatch: useTangentAttitude perturbs the
            % NOMINAL rotation in tangent space (rotationOverride, passed straight through to
            % revgnss.FourTimestampEstimatorEndpointBridge.fromAssetStateBlock -- never
            % reconstructed from a perturbed Euler triple, which is a DIFFERENT, non-equivalent
            % local coordinate patch); otherwise (legacy eulerZYX) the Euler angle itself is bumped
            % additively, exactly matching the pre-fix behavior for a caller that explicitly opts
            % out of the tangent convention.
            positionPerturbed_m = positionNominal_m;
            velocityPerturbed_mps = velocityNominal_mps;
            eulerPerturbed_rad = eulerNominal_rad;
            rotationOverride = [];
            clockBiasPerturbed_m = clockBiasNominal_m;
            clockDriftPerturbed_mps = clockDriftNominal_mps;
            if columnIdx <= 3
                positionPerturbed_m(columnIdx) = positionPerturbed_m(columnIdx) + delta;
                if useTangentAttitude; rotationOverride = nominalRotation; end
            elseif columnIdx <= 6
                velocityPerturbed_mps(columnIdx-3) = velocityPerturbed_mps(columnIdx-3) + delta;
                if useTangentAttitude; rotationOverride = nominalRotation; end
            elseif columnIdx <= 9
                axisIdx = columnIdx-6;
                if useTangentAttitude
                    deltaTheta_rad = zeros(3,1); deltaTheta_rad(axisIdx) = delta;
                    rotationOverride = revgnss.AttitudeErrorStateKinematics.smallAnglePerturbedDcm( ...
                        nominalRotation, deltaTheta_rad);
                else
                    eulerPerturbed_rad(axisIdx) = eulerPerturbed_rad(axisIdx) + delta;
                end
            elseif columnIdx == 10
                clockBiasPerturbed_m = clockBiasPerturbed_m + delta;
                if useTangentAttitude; rotationOverride = nominalRotation; end
            else
                clockDriftPerturbed_mps = clockDriftPerturbed_mps + delta;
                if useTangentAttitude; rotationOverride = nominalRotation; end
            end
            perturbedSpacecraft = revgnss.FourTimestampEstimatorEndpointBridge.fromAssetStateBlock( ...
                x, stateMap, assetIdx, terminalGeometry, t4_s, 'spacecraft', positionPerturbed_m, ...
                velocityPerturbed_mps, eulerPerturbed_rad, clockBiasPerturbed_m, clockDriftPerturbed_mps, ...
                rotationOverride);
            [value_m,~] = revgnss.FourTimestampObservableBuilder.predictFromEndpointModels( ...
                towerEndpoint, perturbedSpacecraft, hardware, t4_s, predictOptions);
        end

        function derivative = fivePointCentralDifference_(evalFn, stepSize)
            hp2 = evalFn(2*stepSize); hp1 = evalFn(stepSize);
            hm1 = evalFn(-stepSize); hm2 = evalFn(-2*stepSize);
            derivative = (-hp2+8*hp1-8*hm1+hm2)/(12*stepSize);
        end

        function kinds = columnPerturbationKinds_(covarianceComponentOrder, attitudeErrorCoordinateConvention)
            if numel(covarianceComponentOrder) ~= 14
                error('FourTimestampObservableLinearization:componentOrder', ...
                    'covarianceComponentOrder must have exactly 14 entries (frozen v1 schema).');
            end
            if strcmp(char(attitudeErrorCoordinateConvention),'rightMultiplicativeLocalTangent_rad')
                attitudeKind = 'attitudeTangent';
            elseif strcmp(char(attitudeErrorCoordinateConvention),'eulerZYXError_rad')
                attitudeKind = 'attitudeEuler';
            else
                error('FourTimestampObservableLinearization:attitudeConvention', ...
                    'attitudeErrorCoordinateConvention must be a frozen v1 variant.');
            end
            kinds = [repmat({'position'},1,3), repmat({'velocity'},1,3), ...
                repmat({attitudeKind},1,3), repmat({'angularRate'},1,3), ...
                {'clockBias'}, {'clockDrift'}];
        end

        function [stepSize, perturbFn] = stepAndPerturbFn_(kind, columnIndex, steps, nominalRotation)
            switch kind
                case 'position'
                    axisIdx = columnIndex;
                    stepSize = steps.positionStep_m;
                    perturbFn = @(delta) struct( ...
                        'positionDelta_m',revgnss.FourTimestampObservableLinearization.unitVector_(axisIdx,3)*delta, ...
                        'velocityDelta_mps',zeros(3,1),'rotation',nominalRotation, ...
                        'clockBiasDelta_m',0,'clockDriftDelta_mps',0);
                case 'velocity'
                    axisIdx = columnIndex-3;
                    stepSize = steps.velocityStep_mps;
                    perturbFn = @(delta) struct('positionDelta_m',zeros(3,1), ...
                        'velocityDelta_mps',revgnss.FourTimestampObservableLinearization.unitVector_(axisIdx,3)*delta, ...
                        'rotation',nominalRotation,'clockBiasDelta_m',0,'clockDriftDelta_mps',0);
                case 'attitudeTangent'
                    axisIdx = columnIndex-6;
                    stepSize = steps.attitudeStep_rad;
                    perturbFn = @(delta) struct('positionDelta_m',zeros(3,1),'velocityDelta_mps',zeros(3,1), ...
                        'rotation',revgnss.AttitudeErrorStateKinematics.smallAnglePerturbedDcm( ...
                            nominalRotation,revgnss.FourTimestampObservableLinearization.unitVector_(axisIdx,3)*delta), ...
                        'clockBiasDelta_m',0,'clockDriftDelta_mps',0);
                case 'attitudeEuler'
                    axisIdx = columnIndex-6;
                    stepSize = steps.attitudeStep_rad;
                    perturbFn = @(delta) struct('positionDelta_m',zeros(3,1),'velocityDelta_mps',zeros(3,1), ...
                        'rotation',[], ...
                        'eulerDelta_rad',revgnss.FourTimestampObservableLinearization.unitVector_(axisIdx,3)*delta, ...
                        'clockBiasDelta_m',0,'clockDriftDelta_mps',0);
                case 'clockBias'
                    stepSize = steps.clockBiasStep_m;
                    perturbFn = @(delta) struct('positionDelta_m',zeros(3,1),'velocityDelta_mps',zeros(3,1), ...
                        'rotation',nominalRotation,'clockBiasDelta_m',delta,'clockDriftDelta_mps',0);
                case 'clockDrift'
                    stepSize = steps.clockDriftStep_mps;
                    perturbFn = @(delta) struct('positionDelta_m',zeros(3,1),'velocityDelta_mps',zeros(3,1), ...
                        'rotation',nominalRotation,'clockBiasDelta_m',0,'clockDriftDelta_mps',delta);
                otherwise
                    error('FourTimestampObservableLinearization:columnKind', ...
                        'Unrecognised column perturbation kind %s.',kind);
            end
        end

        function e = unitVector_(axisIdx, n)
            e = zeros(n,1); e(axisIdx) = 1;
        end
    end
end
