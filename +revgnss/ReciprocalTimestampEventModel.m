classdef ReciprocalTimestampEventModel
    % ReciprocalTimestampEventModel  Plan Section 4.2 interface #2: solves transmit/receive
    % coordinate events for a light-time exchange and converts them to endpoint local time tags.
    %
    % Deliberately NEW CODE, not a call-through to revgnss.CoherentTwoWayCodeRangingModel, for two
    % verified reasons (Stage 4.2 combined review finding 17 corrected an earlier, inaccurate
    % three-reason version of this comment -- re-verified against the source directly):
    % (1) solvePhysicalEventGeometry requires an isa(...,'revgnss.CoherentTwoWayCodeHardwareModel')
    % hardware model whose constructor hard-asserts PN-code-ranging-specific fields (chip rate,
    % code length, code-phase calibration) with no meaning here; (2) solveEvents_ hardcodes a
    % SINGLE 'initiator' role for both the t1-transmit AND the t4-receive event, with no way to
    % supply two DIFFERENT bodies for those roles -- a 3-node relay pass needs exactly that (the
    % source transmits at t1, a DIFFERENT body, the destination, receives at t4). Note this is not
    % about the t2/t3 turnaround arithmetic itself: solveEventChain_ below reproduces that same
    % t2 = t3 - turnaroundCoordinate_s step, with the same node at both t2 and t3, verbatim from
    % solveEvents_ -- the actual generalization is splitting the old 'initiator' role into
    % separate finalReceiveEndpoint/initialTransmitEndpoint parameters. (A same-identifier check
    % alone would NOT have disqualified reuse: solvePhysicalEventGeometry only rejects IDENTICAL
    % initiator/transponder asset identifiers, so a distinctly-identified tower or relay endpoint
    % would pass that particular check; reasons (1) and (2) above are what actually disqualify it.)
    %
    % The numerical core (solveRetardedLeg_) mirrors CoherentTwoWayCodeRangingModel.
    % solveRetardedTransmitTime_'s exact fixed-point idiom (same shape: iterate delay to a
    % tolerance with a hard cap and explicit non-convergence error) as independently-written new
    % code with its own tolerance/cap defaults, never sharing state or defaults with the ISL
    % solver.
    %
    % A single private three-event-chain solver (solveEventChain_) serves BOTH public entries,
    % because the direct round-trip case (chain {origin,dest,dest,origin}) and the relay-transit
    % case (chain {source,relay,relay,dest}) are the SAME algorithm -- "solve the last leg
    % retarded against a fixed final receiver, derive the turnaround node's transmit time by
    % subtracting one anchored delay, solve the first leg retarded against that" -- differing
    % only in whether the first and last endpoint objects are identical (direct) or distinct
    % (relay).
    %
    % localClockTags is the concrete fix for the gap this session's grounding investigation named:
    % revgnss.CoherentTwoWayCodeRangingModel.solveEvents_ only ever tags t1/t4 with the
    % INITIATOR's own clock -- the transponder's own t2/t3 local tags are never produced anywhere
    % in that solver. Here every one of the four coordinate events is tagged with THAT role's own
    % endpoint clock, via revgnss.TwoWayCodeEndpointModel.localTimeAt.

    methods (Static)
        function events = solveDirectRoundTrip(originEndpoint, destinationEndpoint, hardware, t4_s, solverOptions)
            if nargin < 5; solverOptions = struct(); end
            if strcmp(originEndpoint.assetIdentifier, destinationEndpoint.assetIdentifier)
                error('ReciprocalTimestampEventModel:selfLink', ...
                    'Origin and destination must be different endpoints.');
            end
            events = revgnss.ReciprocalTimestampEventModel.solveEventChain_( ...
                originEndpoint, destinationEndpoint, originEndpoint, hardware, t4_s, ...
                solverOptions, 'directRoundTrip');
        end

        function events = solveRelayTransit(sourceEndpoint, relayEndpoint, destinationEndpoint, ...
                hardware, t4_s, solverOptions)
            if nargin < 6; solverOptions = struct(); end
            ids = {sourceEndpoint.assetIdentifier, relayEndpoint.assetIdentifier, ...
                destinationEndpoint.assetIdentifier};
            if numel(unique(ids)) ~= 3
                error('ReciprocalTimestampEventModel:selfLink', ...
                    'Source, relay, and destination must be three distinct endpoints.');
            end
            events = revgnss.ReciprocalTimestampEventModel.solveEventChain_( ...
                destinationEndpoint, relayEndpoint, sourceEndpoint, hardware, t4_s, ...
                solverOptions, 'relayTransit');
        end

        function localTags_s = localClockTags(events, chainEndpoints)
            % localTags_s(k) = chainEndpoints{k}.localTimeAt(events.t<k>_s) -- chainEndpoints
            % follows the SAME 1-by-4 role shape as
            % revgnss.ReciprocalTimestampExchangeRecord.chainEndpointIdentifiers
            % ({origin,dest,dest,origin} direct; {source,relay,relay,dest} relay).
            if ~iscell(chainEndpoints) || numel(chainEndpoints) ~= 4 || ...
                    ~all(cellfun(@(e) isa(e,'revgnss.TwoWayCodeEndpointModel'),chainEndpoints))
                error('ReciprocalTimestampEventModel:chainEndpoints', ...
                    'chainEndpoints must be a 1-by-4 cell of revgnss.TwoWayCodeEndpointModel.');
            end
            eventTimes_s = [events.t1_s, events.t2_s, events.t3_s, events.t4_s];
            localTags_s = zeros(1,4);
            for k = 1:4
                localTags_s(k) = chainEndpoints{k}.localTimeAt(eventTimes_s(k));
            end
        end
    end

    methods (Static, Access = private)
        function events = solveEventChain_(finalReceiveEndpoint, turnaroundEndpoint, ...
                initialTransmitEndpoint, hardware, t4_s, solverOptions, topologyKind)
            if ~isa(finalReceiveEndpoint,'revgnss.TwoWayCodeEndpointModel') || ...
                    ~isa(turnaroundEndpoint,'revgnss.TwoWayCodeEndpointModel') || ...
                    ~isa(initialTransmitEndpoint,'revgnss.TwoWayCodeEndpointModel') || ...
                    ~isa(hardware,'revgnss.ReciprocalLinkHardwareModel')
                error('ReciprocalTimestampEventModel:eventChainType', ...
                    'Event chain solving requires three revgnss.TwoWayCodeEndpointModel endpoints and one revgnss.ReciprocalLinkHardwareModel.');
            end
            finalReceiveEndpoint.assertStateSource('physicalTruth');
            turnaroundEndpoint.assertStateSource('physicalTruth');
            initialTransmitEndpoint.assertStateSource('physicalTruth');
            hardware.assertParameterSource('physicalTruth');
            if ~(isnumeric(t4_s) && isscalar(t4_s) && isfinite(t4_s))
                error('ReciprocalTimestampEventModel:finalReceptionTime', ...
                    'finalReceptionCoordinateTime_s must be a finite scalar.');
            end

            options = revgnss.ReciprocalTimestampEventModel.solverOptions_(solverOptions);
            c = revgnss.Constants.SPEED_OF_LIGHT_MPS;

            rFinal_rx_t4_m = finalReceiveEndpoint.receivePhaseCentreAt(t4_s);
            [t3_s, returnDelay_s, returnIterations] = ...
                revgnss.ReciprocalTimestampEventModel.solveRetardedLeg_( ...
                    rFinal_rx_t4_m, t4_s, ...
                    @(time_s) turnaroundEndpoint.transmitPhaseCentreAt(time_s), c, options);

            turnaroundCoordinate_s = ...
                turnaroundEndpoint.coordinateDurationForProperDuration(hardware.turnaroundProperTime_s);
            t2_s = t3_s - turnaroundCoordinate_s;
            rTurnaround_rx_t2_m = turnaroundEndpoint.receivePhaseCentreAt(t2_s);
            [t1_s, forwardDelay_s, forwardIterations] = ...
                revgnss.ReciprocalTimestampEventModel.solveRetardedLeg_( ...
                    rTurnaround_rx_t2_m, t2_s, ...
                    @(time_s) initialTransmitEndpoint.transmitPhaseCentreAt(time_s), c, options);

            rInitial_tx_t1_m = initialTransmitEndpoint.transmitPhaseCentreAt(t1_s);
            rTurnaround_tx_t3_m = turnaroundEndpoint.transmitPhaseCentreAt(t3_s);
            forwardRange_m = norm(rTurnaround_rx_t2_m - rInitial_tx_t1_m);
            returnRange_m = norm(rFinal_rx_t4_m - rTurnaround_tx_t3_m);
            forwardResidual_s = forwardDelay_s - forwardRange_m / c;
            returnResidual_s = returnDelay_s - returnRange_m / c;
            if max(abs([forwardResidual_s, returnResidual_s])) > 10 * options.lightTimeTolerance_s
                error('ReciprocalTimestampEventModel:lightTimeResidual', ...
                    'The event chain light-time equations did not close to the requested tolerance.');
            end
            if ~(t1_s <= t2_s && t2_s <= t3_s && t3_s <= t4_s)
                error('ReciprocalTimestampEventModel:eventOrder', ...
                    'The solved event sequence is not time ordered.');
            end

            events = struct( ...
                'topologyKind', topologyKind, ...
                't1_s', t1_s, 't2_s', t2_s, 't3_s', t3_s, 't4_s', t4_s, ...
                'r_tx_t1_m', rInitial_tx_t1_m, 'r_rx_t2_m', rTurnaround_rx_t2_m, ...
                'r_tx_t3_m', rTurnaround_tx_t3_m, 'r_rx_t4_m', rFinal_rx_t4_m, ...
                'forwardRange_m', forwardRange_m, 'returnRange_m', returnRange_m, ...
                'forwardPropagationDelay_s', forwardDelay_s, ...
                'returnPropagationDelay_s', returnDelay_s, ...
                'turnaroundCoordinate_s', turnaroundCoordinate_s, ...
                'forwardResidual_s', forwardResidual_s, ...
                'returnResidual_s', returnResidual_s, ...
                'forwardIterationCount', forwardIterations, ...
                'returnIterationCount', returnIterations);
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
                error('ReciprocalTimestampEventModel:lightTimeConvergence', ...
                    'Retarded-time iteration did not converge.');
            end
            transmitTime_s = receiveTime_s-delay_s;
        end

        function options = solverOptions_(supplied)
            if isempty(supplied)
                supplied = struct();
            end
            if ~isstruct(supplied) || ~isscalar(supplied)
                error('ReciprocalTimestampEventModel:solverOptions', ...
                    'solverOptions must be a scalar structure.');
            end
            allowed = {'lightTimeTolerance_s','maximumIterations'};
            unknown = setdiff(fieldnames(supplied), allowed);
            if ~isempty(unknown)
                error('ReciprocalTimestampEventModel:solverOptions', ...
                    'Unsupported solver option %s.', unknown{1});
            end
            options = struct('lightTimeTolerance_s', 1e-13, 'maximumIterations', 50);
            for k = 1:numel(allowed)
                if isfield(supplied, allowed{k})
                    options.(allowed{k}) = supplied.(allowed{k});
                end
            end
            if ~(isscalar(options.lightTimeTolerance_s) && ...
                    isfinite(options.lightTimeTolerance_s) && options.lightTimeTolerance_s > 0)
                error('ReciprocalTimestampEventModel:solverTolerance', ...
                    'lightTimeTolerance_s must be finite and positive.');
            end
            if ~(isscalar(options.maximumIterations) && ...
                    options.maximumIterations == round(options.maximumIterations) && ...
                    options.maximumIterations >= 3)
                % solveRetardedLeg_ only sets converged=true once iterations>=3 (it always takes
                % an initial estimate plus at least 2 refinements before checking closure) --
                % a cap below 3 can NEVER converge, so this is validated as a hard floor rather
                % than left to surface as a misleading "did not converge" on every call (Stage 4.2
                % combined review finding 5).
                error('ReciprocalTimestampEventModel:solverIterations', ...
                    'maximumIterations must be an integer >= 3 (fewer can never satisfy the convergence check).');
            end
        end
    end
end
