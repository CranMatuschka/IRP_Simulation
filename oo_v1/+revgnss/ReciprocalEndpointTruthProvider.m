classdef ReciprocalEndpointTruthProvider
    % ReciprocalEndpointTruthProvider  Plan Section 4.2 interface #3 ("CommunicationEndpointState
    % Provider adapters"). NOT an extension of revgnss.CommunicationEndpointStateProvider --
    % confirmed unsuitable by direct read: that contract is estimator-state-only
    % (AllowedStateSources={'estimatorState'}), frozen-single-epoch
    % (AllowedStateEvaluationPolicies={'frozenSameEpochOnly'}), and requires two DISTINCT
    % spacecraft (requireSameEpochPair checks canonicalPhysicalAssetIndex inequality) -- none of
    % which fits truth-side event generation, a fixed ground tower, or a relay. Instead this is
    % three thin static factories generalizing revgnss.TwoWayISLMeasurementBuilder.truthEndpoint_
    % (the existing, proven ECEF-truth-to-TwoWayCodeEndpointModel pipeline) away from ISL-only
    % config lookups, producing the SAME already-neutral revgnss.TwoWayCodeEndpointModel value
    % type every consumer (ISL, ground-space, relay) already knows how to use.
    %
    % Estimate-side endpoint construction (needed by plan Section 4.3's linearization) is
    % deliberately NOT provided here: for the owning asset's own local EKF state it is a trivial
    % mirror of revgnss.TwoWayISLMeasurementBuilder.estimateEndpoint_ that Section 4.3 builds when
    % it needs it; for a REMOTE spacecraft's frozen estimator product, Section 4.3 may reuse the
    % existing, UNTOUCHED revgnss.CommunicationEndpointStateProvider/
    % OwnerLocalEstimatorEndpointProvider/FrozenProductEndpointProvider machinery read-only, as-is
    % -- that is precisely the problem it was built for, and this class does not duplicate it.

    methods (Static)
        function endpoint = spacecraft(asset, assetIdx, terminalGeometry, t_s)
            % spacecraft  Generalizes TwoWayISLMeasurementBuilder.truthEndpoint_: identical
            % ecefStateToInertial + bodyToEcefRotation + clock-bias/drift pipeline, but
            % terminalGeometry is a plain argument instead of an ISL-specific config lookup --
            % that lookup stays owned by whichever Section 4.4 adapter calls this (ISL's own
            % measurements.isl.twoWay.terminalGeometry.* config stays in
            % TwoWayISLMeasurementBuilder.terminalGeometry_, untouched).
            [rInertial,vInertial] = models.frames.FrameTimeUtils.ecefStateToInertial( ...
                asset.r_ecef_m,asset.v_ecef_mps,t_s);
            bodyToInertial = models.frames.FrameTimeUtils.rotMatEcefToInertial(t_s) * ...
                revgnss.AttitudeKinematics.bodyToEcefRotation(asset.attitude_euler_rad);
            c = revgnss.Constants.SPEED_OF_LIGHT_MPS;
            bias_s = asset.clock.getBiasMeters()/c;
            localClockRate = 1 + asset.clock.getDriftMetersPerSecond()/c;
            properTimeRate = revgnss.ReciprocalEndpointTruthProvider.properTimeRate_(rInertial,vInertial);
            endpoint = revgnss.TwoWayCodeEndpointModel.constantVelocity( ...
                'physicalTruth',sprintf('asset:%d',assetIdx),rInertial,vInertial,t_s, ...
                bodyToInertialRotation=bodyToInertial, ...
                transmitPhaseCentreOffset_body_m=terminalGeometry.transmitOffset_body_m, ...
                receivePhaseCentreOffset_body_m=terminalGeometry.receiveOffset_body_m, ...
                transmitTerminalIdentifier=terminalGeometry.transmitTerminalIdentifier, ...
                receiveTerminalIdentifier=terminalGeometry.receiveTerminalIdentifier, ...
                transmitAntennaIdentifier=terminalGeometry.transmitAntennaIdentifier, ...
                receiveAntennaIdentifier=terminalGeometry.receiveAntennaIdentifier, ...
                clockLocalTimeAtReference_s=t_s+bias_s, ...
                localClockRate=localClockRate, ...
                properTimeRate=properTimeRate);
        end

        function endpoint = fixedStation(towerTruth_ecef_m, towerClockBiasMeters, ...
                towerClockDriftMetersPerSecond, towerIdentifier, terminalGeometry, t_s)
            % fixedStation  A ground tower is fixed IN ECEF (zero ECEF-frame velocity); its real
            % inertial velocity is entirely the Earth-rotation term ecefStateToInertial already
            % applies to any ECEF state, truth or not -- so this is the same conversion pipeline
            % as spacecraft() with v_ecef_mps forced to zero, not a different physics path.
            % properTimeRate defaults to 1 (a Section 4.3/4.4 ground-station relativity-fidelity
            % choice, not a Section 4.2 concern -- a fixed station's own gravitational potential
            % well is a fixed offset a future stage may choose to model, not iterate here).
            [rInertial,vInertial] = models.frames.FrameTimeUtils.ecefStateToInertial( ...
                towerTruth_ecef_m(:),zeros(3,1),t_s);
            bodyToInertial = models.frames.FrameTimeUtils.rotMatEcefToInertial(t_s);
            c = revgnss.Constants.SPEED_OF_LIGHT_MPS;
            bias_s = towerClockBiasMeters/c;
            localClockRate = 1 + towerClockDriftMetersPerSecond/c;
            endpoint = revgnss.TwoWayCodeEndpointModel.constantVelocity( ...
                'physicalTruth',towerIdentifier,rInertial,vInertial,t_s, ...
                bodyToInertialRotation=bodyToInertial, ...
                transmitPhaseCentreOffset_body_m=terminalGeometry.transmitOffset_body_m, ...
                receivePhaseCentreOffset_body_m=terminalGeometry.receiveOffset_body_m, ...
                transmitTerminalIdentifier=terminalGeometry.transmitTerminalIdentifier, ...
                receiveTerminalIdentifier=terminalGeometry.receiveTerminalIdentifier, ...
                transmitAntennaIdentifier=terminalGeometry.transmitAntennaIdentifier, ...
                receiveAntennaIdentifier=terminalGeometry.receiveAntennaIdentifier, ...
                clockLocalTimeAtReference_s=t_s+bias_s, ...
                localClockRate=localClockRate, ...
                properTimeRate=1);
        end

        function endpoint = relay(varargin) %#ok<STOUT>
            % relay  No relay physical state exists anywhere in this codebase yet (plan Section
            % 4.5). Matches the established relayTransponderImplemented=false /
            % ReportRealityHelper discipline (loud, explicit, unimplemented) rather than a silent
            % placeholder that could accidentally be wired into a live path unflagged.
            error('ReciprocalEndpointTruthProvider:relayNotImplemented', ...
                'No relay physical state exists in this codebase yet (plan Section 4.5).');
        end
    end

    methods (Static, Access = private)
        function rate = properTimeRate_(rInertial_m, vInertial_mps)
            c = revgnss.Constants.SPEED_OF_LIGHT_MPS;
            radius_m = norm(rInertial_m);
            if ~(isfinite(radius_m) && radius_m > 0) || any(~isfinite(vInertial_mps))
                error('ReciprocalEndpointTruthProvider:properTimeState', ...
                    'Proper-time conversion requires a finite inertial state.');
            end
            % First post-Newtonian spherical-Earth rate d(tau)/dt -- same formula as
            % TwoWayISLMeasurementBuilder.properTimeRate_, independently re-implemented here
            % (Section 4.2 deliberately does not call through to ISL-specific private methods).
            rate = 1 - (revgnss.Constants.EARTH_GM_M3PS2/radius_m + ...
                0.5*dot(vInertial_mps,vInertial_mps))/c^2;
            if ~(isfinite(rate) && rate > 0)
                error('ReciprocalEndpointTruthProvider:properTimeRate', ...
                    'Computed proper-time rate must be finite and positive.');
            end
        end
    end
end
