function test_reciprocal_endpoint_truth_provider()
% test_reciprocal_endpoint_truth_provider  Plan Section 4.2 interface #3.
% revgnss.ReciprocalEndpointTruthProvider.spacecraft generalizes
% revgnss.TwoWayISLMeasurementBuilder.truthEndpoint_'s proven ECEF-truth-to-endpoint pipeline;
% truthEndpoint_ is Access=private, so this test independently re-derives the SAME pipeline by
% hand from the shared PUBLIC primitives (models.frames.FrameTimeUtils,
% revgnss.AttitudeKinematics, revgnss.Constants) rather than calling through to the private
% method -- proving the generalization did not silently diverge from the proven ISL conversion,
% without violating the "cannot call a private static method from outside its class" constraint.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
addpath(rootDir);

fprintf('=== test_reciprocal_endpoint_truth_provider ===\n');
i_test_spacecraft_matches_independently_rederived_pipeline_();
i_test_fixedStation_has_zero_ecef_velocity_and_unit_proper_time_rate_();
i_test_relay_always_throws_();
fprintf('=== test_reciprocal_endpoint_truth_provider: ALL PASS ===\n');
end

% ================================================================================================
function i_test_spacecraft_matches_independently_rederived_pipeline_()
c = revgnss.Constants.SPEED_OF_LIGHT_MPS;
% getOscillatorDriftMetersPerSecond is what the PROPER-TIME endpoint path reads: this
% endpoint supplies properTimeRate separately, so localClockRate must carry the
% oscillator rate only (see models.clocks.ClockModel). The stub has no relativistic
% offset, so both accessors return the same value and the assertion below is unchanged.
clock = struct('getBiasMeters',@() 12.5,'getDriftMetersPerSecond',@() 3e-4, ...
               'getOscillatorDriftMetersPerSecond',@() 3e-4);
asset = struct('r_ecef_m',[7000e3;1200e3;300e3],'v_ecef_mps',[10;7400;20], ...
    'attitude_euler_rad',[0.02;-0.01;0.05],'clock',clock);
geom = struct('transmitOffset_body_m',[0.1;-0.2;0.05],'receiveOffset_body_m',[-0.1;0.2;-0.05], ...
    'transmitTerminalIdentifier','S:tx','receiveTerminalIdentifier','S:rx', ...
    'transmitAntennaIdentifier','S:tx-pc','receiveAntennaIdentifier','S:rx-pc');
t_s = 137.5;
assetIdx = 4;

endpoint = revgnss.ReciprocalEndpointTruthProvider.spacecraft(asset,assetIdx,geom,t_s);

% Independently re-derived expectation using ONLY the shared public primitives -- deliberately
% NOT calling revgnss.TwoWayISLMeasurementBuilder.truthEndpoint_ (private).
[rInertial_m,vInertial_mps] = models.frames.FrameTimeUtils.ecefStateToInertial( ...
    asset.r_ecef_m,asset.v_ecef_mps,t_s);
bodyToInertial = models.frames.FrameTimeUtils.rotMatEcefToInertial(t_s) * ...
    revgnss.AttitudeKinematics.bodyToEcefRotation(asset.attitude_euler_rad);
bias_s = asset.clock.getBiasMeters()/c;
localClockRate = 1+asset.clock.getOscillatorDriftMetersPerSecond()/c;

assert(strcmp(endpoint.assetIdentifier,sprintf('asset:%d',assetIdx)));
assert(max(abs(endpoint.centrePositionAt(t_s)-rInertial_m)) < 1e-6, ...
    'FAIL: spacecraft() centre position must match the independently re-derived ECEF->inertial conversion');
assert(max(abs(endpoint.bodyToInertialAt(t_s)-bodyToInertial),[],'all') < 1e-12, ...
    'FAIL: spacecraft() attitude rotation must match the independently re-derived rotation');
assert(abs(endpoint.clockLocalTimeAtReference_s-(t_s+bias_s)) < 1e-12, ...
    'FAIL: spacecraft() clock bias conversion must match bias_s = biasMeters/c exactly');
assert(abs(endpoint.localClockRate-localClockRate) < 1e-15, ...
    'FAIL: spacecraft() clock rate conversion must match 1+driftMetersPerSecond/c exactly');
% Stage 4.2 combined review finding 16: properTimeRate is the one piece of genuinely duplicated
% physics this stage introduces (independently re-implementing the same first post-Newtonian
% formula revgnss.TwoWayISLMeasurementBuilder.properTimeRate_ uses, since that method is private)
% -- it was previously never asserted anywhere, so a future divergence between the two
% independent implementations would go undetected. Re-derived here a THIRD time, independently
% of both the production code and revgnss.ReciprocalEndpointTruthProvider.properTimeRate_'s own
% body, from the same public physical constants only.
expectedProperTimeRate = 1 - (revgnss.Constants.EARTH_GM_M3PS2/norm(rInertial_m) + ...
    0.5*dot(vInertial_mps,vInertial_mps))/c^2;
assert(abs(endpoint.properTimeRate-expectedProperTimeRate) < 1e-15, ...
    'FAIL: spacecraft() properTimeRate must match the independently re-derived 1PN formula exactly');
assert(isequal(endpoint.transmitPhaseCentreOffset_body_m,geom.transmitOffset_body_m));
assert(isequal(endpoint.receivePhaseCentreOffset_body_m,geom.receiveOffset_body_m));
assert(strcmp(endpoint.transmitTerminalIdentifier,geom.transmitTerminalIdentifier));

% Independent velocity cross-check: transmitPhaseCentreAt at two nearby times must give a finite
% difference velocity consistent with vInertial_mps to first order (proves the endpoint's motion
% model, not just its instantaneous state, matches the re-derived inertial velocity).
dt = 1e-3;
finiteDiffVelocity_mps = (endpoint.centrePositionAt(t_s+dt)-endpoint.centrePositionAt(t_s-dt))/(2*dt);
assert(max(abs(finiteDiffVelocity_mps-vInertial_mps)) < 1e-6, ...
    'FAIL: spacecraft() motion model must match the independently re-derived inertial velocity');
fprintf('  PASS spacecraft() matches the independently re-derived ECEF-truth-to-endpoint pipeline\n');
end

% ================================================================================================
function i_test_fixedStation_has_zero_ecef_velocity_and_unit_proper_time_rate_()
geom = struct('transmitOffset_body_m',zeros(3,1),'receiveOffset_body_m',zeros(3,1), ...
    'transmitTerminalIdentifier','T:tx','receiveTerminalIdentifier','T:rx', ...
    'transmitAntennaIdentifier','T:tx-pc','receiveAntennaIdentifier','T:rx-pc');
towerEcef_m = [6378e3;0;0];
t_s = 42;
endpoint = revgnss.ReciprocalEndpointTruthProvider.fixedStation( ...
    towerEcef_m,7.0,0.5,'tower:9',geom,t_s);
assert(strcmp(endpoint.assetIdentifier,'tower:9'));
assert(abs(endpoint.properTimeRate-1) < 1e-15, ...
    'FAIL: fixedStation() must default properTimeRate to 1 (Section 4.2 does not model gravitational potential)');
% Stage 4.2 combined review finding 16: fixedStation's clock bias/rate conversion was previously
% never asserted (only position/velocity were) -- the SAME bias_s=biasMeters/c,
% localClockRate=1+driftMetersPerSecond/c conversion spacecraft() uses, independently re-checked
% here for the tower path too.
c = revgnss.Constants.SPEED_OF_LIGHT_MPS;
assert(abs(endpoint.clockLocalTimeAtReference_s-(t_s+7.0/c)) < 1e-12, ...
    'FAIL: fixedStation() clock bias conversion must match bias_s = biasMeters/c exactly');
assert(abs(endpoint.localClockRate-(1+0.5/c)) < 1e-15, ...
    'FAIL: fixedStation() clock rate conversion must match 1+driftMetersPerSecond/c exactly');
[rInertialExpected_m,vInertialExpected_mps] = models.frames.FrameTimeUtils.ecefStateToInertial( ...
    towerEcef_m,zeros(3,1),t_s);
assert(max(abs(endpoint.centrePositionAt(t_s)-rInertialExpected_m)) < 1e-6);
% The tower's ONLY inertial motion must be the Earth-rotation term -- a finite-difference
% velocity check confirms this, not just a single-epoch position match.
dt = 1e-3;
finiteDiffVelocity_mps = (endpoint.centrePositionAt(t_s+dt)-endpoint.centrePositionAt(t_s-dt))/(2*dt);
assert(max(abs(finiteDiffVelocity_mps-vInertialExpected_mps)) < 1e-6, ...
    'FAIL: fixedStation() motion must be pure Earth-rotation, matching ecefStateToInertial with zero ECEF velocity');
fprintf('  PASS fixedStation() has zero ECEF-frame velocity and unit proper-time rate\n');
end

% ================================================================================================
function i_test_relay_always_throws_()
threw = false;
try
    revgnss.ReciprocalEndpointTruthProvider.relay();
catch ME
    threw = strcmp(ME.identifier,'ReciprocalEndpointTruthProvider:relayNotImplemented');
end
assert(threw,'FAIL: relay() must always throw a loud, explicit not-implemented error');
fprintf('  PASS relay() throws loudly (no relay physical state exists yet)\n');
end
