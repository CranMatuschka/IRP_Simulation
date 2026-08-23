classdef FourTimestampEstimatorEndpointBridge
    % FourTimestampEstimatorEndpointBridge  Plan Section 4.3: public state-container ->
    % revgnss.TwoWayCodeEndpointModel adapters, deliberately PUBLIC (unlike every precedent this
    % mirrors, which is Access=private to its own adapter class) so a future Section 4.4 adapter
    % for this observable does not need a fourth private copy of this exact conversion pipeline.
    %
    % Three factories, each producing an 'estimatorState'-sourced endpoint:
    %   fromCommunicationEndpointState  ISL/distributed path. Public generalization of
    %                                   revgnss.CoherentTwoWayRangeLinkUpdateAdapter.
    %                                   buildEndpointModel_/estimatorEndpointModelFromState
    %                                   (+revgnss/CoherentTwoWayRangeLinkUpdateAdapter.m:183-193 is
    %                                   estimatorEndpointModelFromState, which is actually PUBLIC on
    %                                   that class -- only buildEndpointModel_ at line 315 is
    %                                   Access=private; duplicated here anyway, deliberately, to
    %                                   avoid a Section-4.3-depends-on-Section-2.3.1 concrete-
    %                                   adapter coupling for a small, frozen-schema-only pipeline),
    %                                   same ecefStateToInertial + rotMatEcefToInertial*
    %                                   bodyToEcefRotation + first post-Newtonian properTimeRate_
    %                                   pipeline. Optional override arguments (default = the
    %                                   state's own values) let the FD stencil rebuild a perturbed
    %                                   endpoint without a second, parallel construction path.
    %   fromAssetStateBlock             Ground-space/local-EKF path, the spacecraft. Same
    %                                   conversion pipeline, sourced from a revgnss.AssetStateBlock
    %                                   resolution of a single local EKF's own x/stateMap. Accepts
    %                                   an optional trailing rotationOverride (12th argument): when
    %                                   supplied, it is used DIRECTLY as the body->ECEF rotation
    %                                   instead of being rebuilt from eulerOverride_rad -- required
    %                                   by revgnss.FourTimestampObservableLinearization.
    %                                   groundSpaceJacobian's quaternionErrorState attitude
    %                                   perturbation, which perturbs the nominal DCM in tangent
    %                                   space (revgnss.AttitudeErrorStateKinematics.
    %                                   smallAnglePerturbedDcm) rather than the Euler angles
    %                                   themselves.
    %   fromTowerBroadcastProduct       Ground-space, the fixed endpoint. 'estimatorState'-sourced
    %                                   mirror of revgnss.ReciprocalEndpointTruthProvider.
    %                                   fixedStation (which is hardcoded 'physicalTruth' at
    %                                   +revgnss/ReciprocalEndpointTruthProvider.m:67 and therefore
    %                                   unusable for prediction) -- identical conversion pipeline
    %                                   AND identical properTimeRate=1 default (a deliberate
    %                                   truth/estimate-side CONSISTENCY choice: fixedStation's own
    %                                   header already named this a "Section 4.3/4.4 ground-station
    %                                   relativity-fidelity choice, not a Section 4.2 concern" --
    %                                   4.3 declines to introduce a truth-vs-estimate asymmetry on
    %                                   that specific, still-open question rather than silently
    %                                   picking a different default on one side only).
    %
    % TERMINAL GEOMETRY FIELD NAMES. fromCommunicationEndpointState reads
    % endpointState.terminalGeometry's own established field names
    % (transmitPhaseCentreOffset_body_m/receivePhaseCentreOffset_body_m, confirmed
    % +revgnss/CommunicationEndpointState.m:224-227). fromAssetStateBlock/fromTowerBroadcastProduct
    % accept a CALLER-SUPPLIED terminalGeometry struct -- deliberately standardized on the SAME
    % long field names (not revgnss.ReciprocalEndpointTruthProvider's shorter
    % transmitOffset_body_m/receiveOffset_body_m convention), since buildEstimatorEndpoint_ is one
    % shared private helper serving all three factories and the distributed-fleet vocabulary
    % (Sections 2.x/3.x) already established the long names as the frozen convention.

    methods (Static)
        function endpoint = fromCommunicationEndpointState(endpointState, recordEndpointIdentifier, ...
                positionOverrideEcef_m, velocityOverrideEcef_mps, rotationOverride, ...
                clockBiasOverride_m, clockDriftOverride_mps)
            if ~isa(endpointState,'revgnss.CommunicationEndpointState')
                error('FourTimestampEstimatorEndpointBridge:endpointStateType', ...
                    'fromCommunicationEndpointState requires a revgnss.CommunicationEndpointState.');
            end
            if nargin < 3 || isempty(positionOverrideEcef_m)
                positionOverrideEcef_m = endpointState.positionEcef_m;
            end
            if nargin < 4 || isempty(velocityOverrideEcef_mps)
                velocityOverrideEcef_mps = endpointState.velocityEcef_mps;
            end
            if nargin < 5 || isempty(rotationOverride)
                rotationOverride = revgnss.AttitudeKinematics.bodyToEcefRotation( ...
                    endpointState.attitudeEulerZyx_rad);
            end
            if nargin < 6 || isempty(clockBiasOverride_m)
                clockBiasOverride_m = endpointState.clockBias_m;
            end
            if nargin < 7 || isempty(clockDriftOverride_mps)
                clockDriftOverride_mps = endpointState.clockDriftRate_mps;
            end
            endpoint = revgnss.FourTimestampEstimatorEndpointBridge.buildEstimatorEndpoint_( ...
                recordEndpointIdentifier, endpointState.coordinateEpoch_s, positionOverrideEcef_m, ...
                velocityOverrideEcef_mps, rotationOverride, clockBiasOverride_m, ...
                clockDriftOverride_mps, endpointState.terminalGeometry);
        end

        function endpoint = fromAssetStateBlock(x, stateMap, assetIdx, terminalGeometry, t_s, ...
                recordEndpointIdentifier, positionOverrideEcef_m, velocityOverrideEcef_mps, ...
                eulerOverride_rad, clockBiasOverride_m, clockDriftOverride_mps, rotationOverride)
            blk = revgnss.AssetStateBlock.forAsset(stateMap, assetIdx);
            if isempty(blk.r) || isempty(blk.v) || isempty(blk.euler) || isempty(blk.b) || isempty(blk.bdot)
                error('FourTimestampEstimatorEndpointBridge:stateBlock', ...
                    'The resolved AssetStateBlock is missing a required position/velocity/attitude/clock column.');
            end
            if nargin < 7 || isempty(positionOverrideEcef_m); positionOverrideEcef_m = x(blk.r); end
            if nargin < 8 || isempty(velocityOverrideEcef_mps); velocityOverrideEcef_mps = x(blk.v); end
            if nargin < 9 || isempty(eulerOverride_rad); eulerOverride_rad = x(blk.euler); end
            if nargin < 10 || isempty(clockBiasOverride_m); clockBiasOverride_m = x(blk.b); end
            if nargin < 11 || isempty(clockDriftOverride_mps); clockDriftOverride_mps = x(blk.bdot); end
            if nargin < 12 || isempty(rotationOverride)
                rotation = revgnss.AttitudeKinematics.bodyToEcefRotation(eulerOverride_rad);
            else
                rotation = rotationOverride;
            end
            endpoint = revgnss.FourTimestampEstimatorEndpointBridge.buildEstimatorEndpoint_( ...
                recordEndpointIdentifier, t_s, positionOverrideEcef_m, velocityOverrideEcef_mps, ...
                rotation, clockBiasOverride_m, clockDriftOverride_mps, terminalGeometry);
        end

        function endpoint = fromTowerBroadcastProduct(towerEcef_m, towerClockBiasMeters, ...
                towerClockDriftMetersPerSecond, towerIdentifier, terminalGeometry, t_s)
            if ~(isnumeric(towerEcef_m) && numel(towerEcef_m)==3 && all(isfinite(towerEcef_m)))
                error('FourTimestampEstimatorEndpointBridge:towerPosition', ...
                    'towerEcef_m must be a finite 3-element position vector.');
            end
            if ~(isnumeric(towerClockBiasMeters) && isscalar(towerClockBiasMeters) && ...
                    isfinite(towerClockBiasMeters))
                error('FourTimestampEstimatorEndpointBridge:towerClockBias', ...
                    'towerClockBiasMeters must be a finite scalar.');
            end
            if ~(isnumeric(towerClockDriftMetersPerSecond) && isscalar(towerClockDriftMetersPerSecond) && ...
                    isfinite(towerClockDriftMetersPerSecond))
                error('FourTimestampEstimatorEndpointBridge:towerClockDrift', ...
                    'towerClockDriftMetersPerSecond must be a finite scalar.');
            end
            if ~(ischar(towerIdentifier) || isstring(towerIdentifier)) || strlength(string(towerIdentifier))==0
                error('FourTimestampEstimatorEndpointBridge:towerIdentifier', ...
                    'towerIdentifier must be a nonempty identifier.');
            end
            if ~(isnumeric(t_s) && isscalar(t_s) && isfinite(t_s))
                error('FourTimestampEstimatorEndpointBridge:coordinateEpoch', ...
                    't_s must be a finite scalar.');
            end
            [rInertial,vInertial] = models.frames.FrameTimeUtils.ecefStateToInertial( ...
                towerEcef_m(:),zeros(3,1),t_s);
            bodyToInertial = models.frames.FrameTimeUtils.rotMatEcefToInertial(t_s);
            c = revgnss.Constants.SPEED_OF_LIGHT_MPS;
            bias_s = towerClockBiasMeters/c;
            localClockRate = 1 + towerClockDriftMetersPerSecond/c;
            endpoint = revgnss.TwoWayCodeEndpointModel.constantVelocity( ...
                'estimatorState',towerIdentifier,rInertial,vInertial,t_s, ...
                bodyToInertialRotation=bodyToInertial, ...
                transmitPhaseCentreOffset_body_m=terminalGeometry.transmitPhaseCentreOffset_body_m, ...
                receivePhaseCentreOffset_body_m=terminalGeometry.receivePhaseCentreOffset_body_m, ...
                transmitTerminalIdentifier=terminalGeometry.transmitTerminalIdentifier, ...
                receiveTerminalIdentifier=terminalGeometry.receiveTerminalIdentifier, ...
                transmitAntennaIdentifier=terminalGeometry.transmitAntennaIdentifier, ...
                receiveAntennaIdentifier=terminalGeometry.receiveAntennaIdentifier, ...
                clockLocalTimeAtReference_s=t_s+bias_s, ...
                localClockRate=localClockRate, ...
                properTimeRate=1);
        end
    end

    methods (Static, Access = private)
        function endpoint = buildEstimatorEndpoint_(assetIdentifier, t0, positionEcef_m, ...
                velocityEcef_mps, bodyToEcefRotation, clockBias_m, clockDriftRate_mps, terminalGeometry)
            [rI,vI] = models.frames.FrameTimeUtils.ecefStateToInertial(positionEcef_m,velocityEcef_mps,t0);
            bodyToInertial = models.frames.FrameTimeUtils.rotMatEcefToInertial(t0) * bodyToEcefRotation;
            c = revgnss.Constants.SPEED_OF_LIGHT_MPS;
            bias_s = clockBias_m / c;
            localClockRate = 1 + clockDriftRate_mps / c;
            properTimeRate = revgnss.FourTimestampEstimatorEndpointBridge.properTimeRate_(rI, vI);
            endpoint = revgnss.TwoWayCodeEndpointModel.constantVelocity( ...
                'estimatorState', assetIdentifier, rI, vI, t0, ...
                bodyToInertialRotation=bodyToInertial, ...
                transmitPhaseCentreOffset_body_m=terminalGeometry.transmitPhaseCentreOffset_body_m, ...
                receivePhaseCentreOffset_body_m=terminalGeometry.receivePhaseCentreOffset_body_m, ...
                transmitTerminalIdentifier=terminalGeometry.transmitTerminalIdentifier, ...
                receiveTerminalIdentifier=terminalGeometry.receiveTerminalIdentifier, ...
                transmitAntennaIdentifier=terminalGeometry.transmitAntennaIdentifier, ...
                receiveAntennaIdentifier=terminalGeometry.receiveAntennaIdentifier, ...
                clockLocalTimeAtReference_s=t0+bias_s, ...
                localClockRate=localClockRate, ...
                properTimeRate=properTimeRate);
        end

        function rate = properTimeRate_(rInertial_m, vInertial_mps)
            % Independently re-derived (not a call-through: every existing implementation of this
            % exact formula -- TwoWayISLMeasurementBuilder.properTimeRate_,
            % CoherentTwoWayRangeLinkUpdateAdapter.properTimeRate_,
            % ReciprocalEndpointTruthProvider.properTimeRate_ -- is Access=private to its own
            % class). Same first post-Newtonian spherical-Earth formula in all four.
            c = revgnss.Constants.SPEED_OF_LIGHT_MPS;
            radius_m = norm(rInertial_m);
            if ~(isfinite(radius_m) && radius_m > 0) || any(~isfinite(vInertial_mps))
                error('FourTimestampEstimatorEndpointBridge:properTimeState', ...
                    'Proper-time conversion requires a finite inertial state.');
            end
            rate = 1 - (revgnss.Constants.EARTH_GM_M3PS2/radius_m + ...
                0.5*dot(vInertial_mps,vInertial_mps))/c^2;
            if ~(isfinite(rate) && rate > 0)
                error('FourTimestampEstimatorEndpointBridge:properTimeRate', ...
                    'Computed proper-time rate must be finite and positive.');
            end
        end
    end
end
