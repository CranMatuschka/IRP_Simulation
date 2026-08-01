classdef FourTimestampObservableBuilder
    % FourTimestampObservableBuilder  Plan Section 4.3: the physics core. Two entry points, one
    % shared internally by both:
    %
    %   predictFromEndpointModels  Solves the 4-event chain (dispatching once, centrally, on
    %                              stateSource) and reduces it to a processed clock-difference
    %                              value + diagnostics. Used by the estimate-side Jacobian.
    %   fromExchangeRecord         Builds a revgnss.FourTimestampClockDifferenceObservable (item
    %                              5) from a FINISHED, already-solved revgnss.
    %                              ReciprocalTimestampExchangeRecord's own four raw tags -- no
    %                              re-solve, no re-derivation of truth. Used truth-side/
    %                              diagnostic-side.
    %
    % Both share applyTerminalDelayAllocation_ (item 2: TX/RX terminal delays, previously
    % declared on revgnss.ReciprocalLinkHardwareModel but never applied to anything) and
    % reduceClockDifference_ (item 5: the one processed observable).
    %
    % TRUTH VS ESTIMATE. revgnss.ReciprocalTimestampEventModel.solveEventChain_ unconditionally
    % hard-gates stateSource=='physicalTruth' (+revgnss/ReciprocalTimestampEventModel.m:96-99) --
    % it cannot be called for an estimator-state (perturbed) evaluation, which item 6's Jacobian
    % requires. solveDirectRoundTripEstimatorState_ below is therefore a narrowly-scoped THIRD
    % copy of the same fixed-point retarded-time idiom (the first two:
    % revgnss.CoherentTwoWayCodeRangingModel.solveEvents_ and
    % revgnss.ReciprocalTimestampEventModel.solveEventChain_ itself), differing from the latter
    % ONLY by omitting its four physicalTruth/calibrationProduct-source assertions and requiring
    % estimatorState/calibrationProduct instead. This is the SAME golden-safety tradeoff Section
    % 4.2's own completion record already named and accepted for its own duplication of
    % revgnss.CoherentTwoWayCodeRangingModel's private solver -- not a new pattern, an inherited
    % one. revgnss.ReciprocalTimestampEventModel.localClockTags itself carries NO state-source
    % gate at all (only an isa check), so tagging, delay-folding, and the clock-difference
    % reduction are single, unduplicated code shared by both branches -- only the geometric solve
    % itself forks.

    properties (Constant)
        SpeedOfLight_mps = 299792458
        AllowedTerminalDelayAllocations = {'receiveEvent','transmitEvent','splitEvenly'};
        DefaultTerminalDelayAllocation = 'receiveEvent';
    end

    methods (Static)
        function [value_m, prediction] = predictFromEndpointModels(originEndpoint, ...
                destinationEndpoint, hardware, t4_s, options)
            if ~isa(originEndpoint,'revgnss.TwoWayCodeEndpointModel') || ...
                    ~isa(destinationEndpoint,'revgnss.TwoWayCodeEndpointModel') || ...
                    ~isa(hardware,'revgnss.ReciprocalLinkHardwareModel')
                error('FourTimestampObservableBuilder:endpointType', ...
                    ['predictFromEndpointModels requires two revgnss.TwoWayCodeEndpointModel ' ...
                    'endpoints and one revgnss.ReciprocalLinkHardwareModel.']);
            end
            if nargin < 5 || isempty(options); options = struct(); end
            options = revgnss.FourTimestampObservableBuilder.normalizePredictionOptions_(options);

            originEndpoint.assertStateSource(destinationEndpoint.stateSource);
            if strcmp(originEndpoint.assetIdentifier, destinationEndpoint.assetIdentifier)
                error('FourTimestampObservableBuilder:selfLink', ...
                    'originEndpoint and destinationEndpoint must not share the same assetIdentifier.');
            end
            switch originEndpoint.stateSource
                case 'physicalTruth'
                    hardware.assertParameterSource('physicalTruth');
                    events = revgnss.ReciprocalTimestampEventModel.solveDirectRoundTrip( ...
                        originEndpoint, destinationEndpoint, hardware, t4_s, options.solverOptions);
                case 'estimatorState'
                    hardware.assertParameterSource('calibrationProduct');
                    events = revgnss.FourTimestampObservableBuilder.solveDirectRoundTripEstimatorState_( ...
                        originEndpoint, destinationEndpoint, hardware, t4_s, options.solverOptions);
                otherwise
                    error('FourTimestampObservableBuilder:stateSource', ...
                        'Unsupported endpoint stateSource %s.',originEndpoint.stateSource);
            end

            rawTags_s = revgnss.ReciprocalTimestampEventModel.localClockTags( ...
                events, {originEndpoint, destinationEndpoint, destinationEndpoint, originEndpoint});
            hardware.assertValidAt(rawTags_s(4));
            correctedTags_s = revgnss.FourTimestampObservableBuilder.applyTerminalDelayAllocation_( ...
                rawTags_s, hardware.originTerminalGroupDelay_s, hardware.anchorTerminalGroupDelay_s, ...
                options.terminalDelayAllocation);
            revgnss.FourTimestampObservableBuilder.requireFiniteOrderedTags_(correctedTags_s);

            [value_s, diagnostics_s] = revgnss.FourTimestampObservableBuilder.reduceClockDifference_( ...
                correctedTags_s);
            value_m = revgnss.FourTimestampObservableBuilder.SpeedOfLight_mps * value_s;
            prediction = struct('events',events,'rawTags_s',rawTags_s,'correctedTags_s',correctedTags_s, ...
                'value_s',value_s,'originRoundTripLocalDelay_s',diagnostics_s.originRoundTrip_s, ...
                'anchorTurnaroundLocalDelay_s',diagnostics_s.anchorTurnaround_s, ...
                'terminalDelayAllocation',options.terminalDelayAllocation);
        end

        function observable = fromExchangeRecord(record, hardware, options)
            if ~isa(record,'revgnss.ReciprocalTimestampExchangeRecord')
                error('FourTimestampObservableBuilder:recordType', ...
                    'fromExchangeRecord requires a revgnss.ReciprocalTimestampExchangeRecord.');
            end
            if ~isa(hardware,'revgnss.ReciprocalLinkHardwareModel')
                error('FourTimestampObservableBuilder:hardwareType', ...
                    'fromExchangeRecord requires a revgnss.ReciprocalLinkHardwareModel.');
            end
            if nargin < 3 || isempty(options); options = struct(); end
            if ~isstruct(options) || ~isscalar(options)
                error('FourTimestampObservableBuilder:options', 'options must be a scalar structure.');
            end
            allowed = {'terminalDelayAllocation','calibrationStates'};
            unknown = setdiff(fieldnames(options),allowed);
            if ~isempty(unknown)
                error('FourTimestampObservableBuilder:options', 'Unsupported option %s.',unknown{1});
            end
            allocation = revgnss.FourTimestampObservableBuilder.DefaultTerminalDelayAllocation;
            if isfield(options,'terminalDelayAllocation'); allocation = options.terminalDelayAllocation; end
            if ~any(strcmp(allocation, ...
                    revgnss.FourTimestampObservableBuilder.AllowedTerminalDelayAllocations))
                error('FourTimestampObservableBuilder:terminalDelayAllocation', ...
                    'terminalDelayAllocation must be a frozen allocation.');
            end
            calibrationStates = [];
            if isfield(options,'calibrationStates'); calibrationStates = options.calibrationStates; end

            % Item 7 re-enforcement: a finished record can be well-formed on its own terms and
            % still fail these checks (availability=false; a partially-tagged record whose
            % per-slot NaN-when-unavailable discipline is individually legal but insufficient for
            % this reduction; an unsupported topology/epoch rule; a validity window that has
            % since narrowed since the record was built) -- never treated as same-epoch/available
            % by silent substitution.
            if ~record.availability
                error('FourTimestampObservableBuilder:recordUnavailable', ...
                    'The exchange record is not available.');
            end
            if ~all(record.localClockTagAvailable)
                error('FourTimestampObservableBuilder:incompleteLocalTags', ...
                    ['All four local clock tags must be available to build a processed ' ...
                    'clock-difference observable.']);
            end
            if ~strcmp(record.topologyKind,'directRoundTrip')
                error('FourTimestampObservableBuilder:relayTopologyUnsupported', ...
                    'Only directRoundTrip records are supported this stage (relayTransit: Section 4.5).');
            end
            if ~strcmp(record.referenceEpochRule,'finalReception')
                error('FourTimestampObservableBuilder:referenceEpochRule', ...
                    'Only referenceEpochRule=''finalReception'' is verified for this reduction.');
            end
            hardware.assertValidAt(record.localClockTags_s(4));
            if ~isempty(calibrationStates)
                if ~all(arrayfun(@(s) s.coversLocalTag(record.localClockTags_s(4)),calibrationStates))
                    error('FourTimestampObservableBuilder:calibrationStateValidity', ...
                        ['A supplied DistributedLinkCalibrationState is not valid at the ' ...
                        'final-reception local tag.']);
                end
            end

            correctedTags_s = revgnss.FourTimestampObservableBuilder.applyTerminalDelayAllocation_( ...
                record.localClockTags_s, hardware.originTerminalGroupDelay_s, ...
                hardware.anchorTerminalGroupDelay_s, allocation);
            revgnss.FourTimestampObservableBuilder.requireFiniteOrderedTags_(correctedTags_s);
            [value_s, diagnostics_s] = revgnss.FourTimestampObservableBuilder.reduceClockDifference_( ...
                correctedTags_s);

            observable = revgnss.FourTimestampClockDifferenceObservable(struct( ...
                'sourceExchangeIdentifier',record.exchangeIdentifier, ...
                'sourceSessionIdentifier',record.sessionIdentifier, ...
                'topologyKind',record.topologyKind, ...
                'referenceEndpointIdentifier',record.localClockCompareEndpointIdentifiers{1}, ...
                'remoteEndpointIdentifier',record.localClockCompareEndpointIdentifiers{2}, ...
                'referenceEpochRule',record.referenceEpochRule, ...
                'referenceCoordinateEpoch_s',record.referenceCoordinateEpoch_s, ...
                'terminalDelayAllocation',allocation, ...
                'originTerminalGroupDelayApplied_s',hardware.originTerminalGroupDelay_s, ...
                'anchorTerminalGroupDelayApplied_s',hardware.anchorTerminalGroupDelay_s, ...
                'clockDifferenceValue_s',value_s, ...
                'clockDifferenceValue_m',revgnss.FourTimestampObservableBuilder.SpeedOfLight_mps*value_s, ...
                'clockDifferenceVarianceDeclared',false, ...
                'clockDifferenceVariance_m2',NaN, ...
                'originRoundTripLocalDelay_s',diagnostics_s.originRoundTrip_s, ...
                'anchorTurnaroundLocalDelay_s',diagnostics_s.anchorTurnaround_s, ...
                'rawCovarianceBlock',record.covarianceBlock, ...
                'rawCovarianceComponentOrder',{record.covarianceComponentOrder}, ...
                'rawCovarianceUnits',record.covarianceUnits, ...
                'calibrationProductIdentifiers',{record.calibrationProductIdentifiers}, ...
                'availability',record.availability, ...
                'truthDiagnosticIdentifier',record.truthDiagnosticIdentifier));
        end
    end

    methods (Static, Access = private)
        function correctedTags_s = applyTerminalDelayAllocation_(tags_s, originDelay_s, ...
                anchorDelay_s, allocation)
            % tags_s is 1x4 in chain-role order {origin,dest,dest,origin} (t1..t4), exactly
            % revgnss.ReciprocalTimestampExchangeRecord.localClockTags_s's own shape. Applied as a
            % post-hoc correction to already-solved local tags ONLY -- never by mutating a
            % coordinate event or turnaroundProperTime_s, which would (and, in an earlier design
            % iteration, provably did) entangle the two delay terms' effects incorrectly.
            switch allocation
                case 'receiveEvent'
                    correctedTags_s = tags_s + [0, anchorDelay_s, 0, originDelay_s];
                case 'transmitEvent'
                    correctedTags_s = tags_s - [originDelay_s, 0, anchorDelay_s, 0];
                case 'splitEvenly'
                    correctedTags_s = tags_s + ...
                        0.5*[-originDelay_s, anchorDelay_s, -anchorDelay_s, originDelay_s];
                otherwise
                    error('FourTimestampObservableBuilder:terminalDelayAllocation', ...
                        'Unrecognised terminal delay allocation %s.',allocation);
            end
        end

        function requireFiniteOrderedTags_(tags_s)
            if ~(all(isfinite(tags_s)) && tags_s(1) <= tags_s(2) && tags_s(2) <= tags_s(3) && ...
                    tags_s(3) <= tags_s(4))
                error('FourTimestampObservableBuilder:tagOrder', ...
                    'The four local clock tags must be finite and time-ordered after delay correction.');
            end
        end

        function [value_s, diagnostics_s] = reduceClockDifference_(tags_s)
            % The classical two-way clock-difference combination, measurement-domain only (a pure
            % function of the four tag numbers -- never calls TwoWayCodeEndpointModel.localTimeAt
            % or any other truth-side clock model directly). Sign convention matches
            % revgnss.ReciprocalTimeTransferModel.evaluate's own referenceClockPartial=-1/
            % remoteClockPartial=+1: tags_s(1)/(4) (origin, the reference) subtract,
            % tags_s(2)/(3) (destination, the remote) add.
            value_s = 0.5*((tags_s(2)-tags_s(1)) - (tags_s(4)-tags_s(3)));
            diagnostics_s = struct('originRoundTrip_s',tags_s(4)-tags_s(1), ...
                'anchorTurnaround_s',tags_s(3)-tags_s(2));
        end

        function options = normalizePredictionOptions_(supplied)
            if ~isstruct(supplied) || ~isscalar(supplied)
                error('FourTimestampObservableBuilder:options', 'options must be a scalar structure.');
            end
            allowed = {'terminalDelayAllocation','solverOptions'};
            unknown = setdiff(fieldnames(supplied),allowed);
            if ~isempty(unknown)
                error('FourTimestampObservableBuilder:options', 'Unsupported option %s.',unknown{1});
            end
            options = struct('terminalDelayAllocation', ...
                revgnss.FourTimestampObservableBuilder.DefaultTerminalDelayAllocation, ...
                'solverOptions',struct());
            for k = 1:numel(allowed)
                if isfield(supplied,allowed{k})
                    options.(allowed{k}) = supplied.(allowed{k});
                end
            end
            if ~any(strcmp(options.terminalDelayAllocation, ...
                    revgnss.FourTimestampObservableBuilder.AllowedTerminalDelayAllocations))
                error('FourTimestampObservableBuilder:terminalDelayAllocation', ...
                    'terminalDelayAllocation must be a frozen allocation.');
            end
        end

        function events = solveDirectRoundTripEstimatorState_(originEndpoint, destinationEndpoint, ...
                hardware, t4_s, solverOptions)
            % Mirrors revgnss.ReciprocalTimestampEventModel.solveEventChain_'s body for the
            % directRoundTrip shape (+revgnss/ReciprocalTimestampEventModel.m:105-151) exactly,
            % substituting estimatorState/calibrationProduct source assertions for that method's
            % hard-coded physicalTruth ones. See class header for why this duplication is
            % unavoidable rather than a call-through.
            originEndpoint.assertStateSource('estimatorState');
            destinationEndpoint.assertStateSource('estimatorState');
            hardware.assertParameterSource('calibrationProduct');
            if ~(isnumeric(t4_s) && isscalar(t4_s) && isfinite(t4_s))
                error('FourTimestampObservableBuilder:finalReceptionTime', ...
                    'finalReceptionCoordinateTime_s must be a finite scalar.');
            end

            options = revgnss.FourTimestampObservableBuilder.solverOptions_(solverOptions);
            c = revgnss.Constants.SPEED_OF_LIGHT_MPS;

            rFinal_rx_t4_m = originEndpoint.receivePhaseCentreAt(t4_s);
            [t3_s, returnDelay_s, returnIterations] = ...
                revgnss.FourTimestampObservableBuilder.solveRetardedLeg_( ...
                    rFinal_rx_t4_m, t4_s, ...
                    @(time_s) destinationEndpoint.transmitPhaseCentreAt(time_s), c, options);

            turnaroundCoordinate_s = ...
                destinationEndpoint.coordinateDurationForProperDuration(hardware.turnaroundProperTime_s);
            t2_s = t3_s - turnaroundCoordinate_s;
            rTurnaround_rx_t2_m = destinationEndpoint.receivePhaseCentreAt(t2_s);
            [t1_s, forwardDelay_s, forwardIterations] = ...
                revgnss.FourTimestampObservableBuilder.solveRetardedLeg_( ...
                    rTurnaround_rx_t2_m, t2_s, ...
                    @(time_s) originEndpoint.transmitPhaseCentreAt(time_s), c, options);

            rInitial_tx_t1_m = originEndpoint.transmitPhaseCentreAt(t1_s);
            rTurnaround_tx_t3_m = destinationEndpoint.transmitPhaseCentreAt(t3_s);
            forwardRange_m = norm(rTurnaround_rx_t2_m - rInitial_tx_t1_m);
            returnRange_m = norm(rFinal_rx_t4_m - rTurnaround_tx_t3_m);
            forwardResidual_s = forwardDelay_s - forwardRange_m / c;
            returnResidual_s = returnDelay_s - returnRange_m / c;
            if max(abs([forwardResidual_s, returnResidual_s])) > 10 * options.lightTimeTolerance_s
                error('FourTimestampObservableBuilder:lightTimeResidual', ...
                    'The event chain light-time equations did not close to the requested tolerance.');
            end
            if ~(t1_s <= t2_s && t2_s <= t3_s && t3_s <= t4_s)
                error('FourTimestampObservableBuilder:eventOrder', ...
                    'The solved event sequence is not time ordered.');
            end

            events = struct( ...
                'topologyKind','directRoundTrip', ...
                't1_s',t1_s, 't2_s',t2_s, 't3_s',t3_s, 't4_s',t4_s, ...
                'r_tx_t1_m',rInitial_tx_t1_m, 'r_rx_t2_m',rTurnaround_rx_t2_m, ...
                'r_tx_t3_m',rTurnaround_tx_t3_m, 'r_rx_t4_m',rFinal_rx_t4_m, ...
                'forwardRange_m',forwardRange_m, 'returnRange_m',returnRange_m, ...
                'forwardPropagationDelay_s',forwardDelay_s, ...
                'returnPropagationDelay_s',returnDelay_s, ...
                'turnaroundCoordinate_s',turnaroundCoordinate_s, ...
                'forwardResidual_s',forwardResidual_s, ...
                'returnResidual_s',returnResidual_s, ...
                'forwardIterationCount',forwardIterations, ...
                'returnIterationCount',returnIterations);
        end

        function [transmitTime_s, delay_s, iterations] = solveRetardedLeg_( ...
                receivePosition_m, receiveTime_s, transmitPositionFunction, c, options)
            delay_s = norm(receivePosition_m - transmitPositionFunction(receiveTime_s)) / c;
            converged = false;
            for iterations = 1:options.maximumIterations
                updatedDelay_s = norm(receivePosition_m - ...
                    transmitPositionFunction(receiveTime_s-delay_s)) / c;
                if iterations >= 3 && ...
                        abs(updatedDelay_s - delay_s) <= options.lightTimeTolerance_s
                    delay_s = updatedDelay_s;
                    converged = true;
                    break
                end
                delay_s = updatedDelay_s;
            end
            if ~converged
                error('FourTimestampObservableBuilder:lightTimeConvergence', ...
                    'Retarded-time iteration did not converge.');
            end
            transmitTime_s = receiveTime_s-delay_s;
        end

        function options = solverOptions_(supplied)
            if isempty(supplied)
                supplied = struct();
            end
            if ~isstruct(supplied) || ~isscalar(supplied)
                error('FourTimestampObservableBuilder:solverOptions', ...
                    'solverOptions must be a scalar structure.');
            end
            allowed = {'lightTimeTolerance_s','maximumIterations'};
            unknown = setdiff(fieldnames(supplied),allowed);
            if ~isempty(unknown)
                error('FourTimestampObservableBuilder:solverOptions', ...
                    'Unsupported solver option %s.',unknown{1});
            end
            options = struct('lightTimeTolerance_s',1e-13,'maximumIterations',50);
            for k = 1:numel(allowed)
                if isfield(supplied,allowed{k})
                    options.(allowed{k}) = supplied.(allowed{k});
                end
            end
            if ~(isscalar(options.lightTimeTolerance_s) && ...
                    isfinite(options.lightTimeTolerance_s) && options.lightTimeTolerance_s > 0)
                error('FourTimestampObservableBuilder:solverTolerance', ...
                    'lightTimeTolerance_s must be finite and positive.');
            end
            if ~(isscalar(options.maximumIterations) && ...
                    options.maximumIterations == round(options.maximumIterations) && ...
                    options.maximumIterations >= 3)
                error('FourTimestampObservableBuilder:solverIterations', ...
                    'maximumIterations must be an integer >= 3 (fewer can never satisfy the convergence check).');
            end
        end
    end
end
