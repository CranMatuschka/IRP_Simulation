function test_ground_relay_truth_atmosphere_separation()
% test_ground_relay_truth_atmosphere_separation  Plan Section 4.5. revgnss.
% GroundRelayTimeTransferSessionBuilder.groundSpaceAtmosphere_ is the FIRST place in the whole
% plan atmosphere reaches an actual local-clock-tag value. Verifies: (1) every endpoint/hardware
% object carries 'physicalTruth' throughout, with the unmodified Section 4.2
% assertParameterSource('physicalTruth') guards genuinely reachable; (2) the atmosphere-reciprocity
% cancellation under a static/symmetric session, and (3) a genuine, nonzero, moving-relay
% atmosphere residual under motion -- a positive/negative pair, not a smoke test.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
addpath(rootDir);
addpath(fullfile(rootDir,'config'));
addpath(fullfile(rootDir,'config','internal'));

fprintf('=== test_ground_relay_truth_atmosphere_separation ===\n');
i_test_parameterSource_physicalTruth_throughout_();
i_test_calibrationProduct_source_rejected_by_solver_guard_();
i_test_atmosphere_reciprocity_cancellation_static_relay_();
i_test_atmosphere_residual_under_relay_motion_();
i_test_atmosphere_inert_when_disabled_();
fprintf('=== test_ground_relay_truth_atmosphere_separation: ALL PASS ===\n');
end

% ================================================================================================
function i_test_parameterSource_physicalTruth_throughout_()
cfg = i_baseCfg_();
hardware = revgnss.GroundRelayPhysicalLinkConfig.hardwareModel(cfg,'physicalTruth');
assert(strcmp(hardware.parameterSource,'physicalTruth'));
hwForward = hardware.asEventSolverHardware('forward');
assert(strcmp(hwForward.parameterSource,'physicalTruth'));
[stationATruth,stationBTruth,relayAssetTruth] = i_truthEndpoints_();
observable = revgnss.GroundRelayTimeTransferSessionBuilder.buildSession( ...
    cfg,stationATruth,stationBTruth,relayAssetTruth,[]);
assert(isa(observable,'revgnss.GroundRelaySessionClockDifferenceObservable'));
fprintf('  PASS hardware and endpoints carry parameterSource=physicalTruth throughout buildSession\n');
end

% ================================================================================================
function i_test_calibrationProduct_source_rejected_by_solver_guard_()
% The unmodified Section 4.2 assertParameterSource('physicalTruth') guard inside solveEventChain_
% must be genuinely reachable through the new builder, not silently bypassed: a hardware object
% built with parameterSource='calibrationProduct' must trip it.
cfg = i_baseCfg_();
hardwareWrongSource = revgnss.GroundRelayPhysicalLinkConfig.hardwareModel(cfg,'calibrationProduct');
[stationATruth,stationBTruth,~] = i_truthEndpoints_();
geom = revgnss.GroundRelayPhysicalLinkConfig.terminalGeometry(cfg,'stationA');
geomB = revgnss.GroundRelayPhysicalLinkConfig.terminalGeometry(cfg,'stationB');
relayGeom = revgnss.GroundRelayPhysicalLinkConfig.terminalGeometry(cfg,'relay');
stationA = revgnss.ReciprocalEndpointTruthProvider.fixedStation( ...
    stationATruth.r_ecef_m,0,0,'station:A',geom,10);
stationB = revgnss.ReciprocalEndpointTruthProvider.fixedStation( ...
    stationBTruth.r_ecef_m,0,0,'station:B',geomB,10);
relayAsset = struct('r_ecef_m',[42164000;0;0],'v_ecef_mps',[0;3074;0], ...
    'attitude_euler_rad',[0;0;0],'clock',struct('getBiasMeters',@() 0,'getDriftMetersPerSecond',@() 0));
relay = revgnss.ReciprocalEndpointTruthProvider.spacecraft(relayAsset,1,relayGeom,10);
hwForward = hardwareWrongSource.asEventSolverHardware('forward');
threw = false;
try
    revgnss.ReciprocalTimestampEventModel.solveRelayTransit(stationA,relay,stationB,hwForward,10,struct());
catch ME
    threw = strcmp(ME.identifier,'ReciprocalLinkHardwareModel:sourceSeparation') || ...
        ~isempty(strfind(lower(ME.message),'source')); %#ok<STREMP>
end
assert(threw, ...
    'FAIL: a calibrationProduct-sourced hardware object combined with physicalTruth endpoints should be rejected by the truth/estimate separation guard.');
fprintf('  PASS mismatched parameterSource is rejected by the unmodified Section 4.2 solver guard\n');
end

% ================================================================================================
function i_test_atmosphere_reciprocity_cancellation_static_relay_()
% A near-static relay (zero velocity) gives the forward and return passes the SAME relay ECEF
% snapshot -> atmosphereDelayForward_s == atmosphereDelayReturn_s exactly (Section 0 finding 6's
% reciprocity property), so the atmosphere correction cancels out of clockDifferenceValue_s
% entirely (it appears with the SAME sign convention on both passes' own destination-station slot,
% and the combiner's 0.5*((DeltaF-tauF)-(DeltaR-tauR)) difference removes any pass-independent
% additive constant common to both... more precisely here: equal delayForward/delayReturn is
% asserted directly, and the resulting bias contribution is verified to match the zero-atmosphere
% baseline).
cfg = i_baseCfg_();
cfg.measurements.groundRelayTimeTransfer.atmosphere.applyTropo = true;
cfg.measurements.groundRelayTimeTransfer.atmosphere.applyIono = true;
[stationATruth,stationBTruth,~] = i_truthEndpoints_();
relayAssetStatic = struct('r_ecef_m',[42164000;0;0],'v_ecef_mps',[0;0;0], ...
    'attitude_euler_rad',[0;0;0],'clock',struct('getBiasMeters',@() 0,'getDriftMetersPerSecond',@() 0));
envModel = models.errors.EnvironmentModel(masterConfig(),2);
observableAtmo = revgnss.GroundRelayTimeTransferSessionBuilder.buildSession( ...
    cfg,stationATruth,stationBTruth,relayAssetStatic,envModel);
assert(abs(observableAtmo.atmosphereDelayForward_s - observableAtmo.atmosphereDelayReturn_s) < 1e-15, ...
    'FAIL: a static relay must give forward/return passes an identical atmosphere delay (reciprocity).');

cfgOff = i_baseCfg_();
observableNoAtmo = revgnss.GroundRelayTimeTransferSessionBuilder.buildSession( ...
    cfgOff,stationATruth,stationBTruth,relayAssetStatic,[]);
assert(abs(observableAtmo.clockDifferenceValue_s - observableNoAtmo.clockDifferenceValue_s) < 1e-9, ...
    'FAIL: an identical (reciprocal) atmosphere delay on both passes must cancel out of clockDifferenceValue_s.');
fprintf('  PASS static-relay atmosphere is exactly reciprocal and cancels out of clockDifferenceValue_s\n');
end

% ================================================================================================
function i_test_atmosphere_residual_under_relay_motion_()
% A genuinely moving relay gives forward/return passes DIFFERENT relay ECEF snapshots -> the
% atmosphere delays measurably differ, and the residual survives into clockDifferenceValue_s --
% the negative half of the reciprocity/motion pair (proving the cancellation above is a real
% physical property of a static relay, not an accidental always-zero stub).
cfg = i_baseCfg_();
% A wide schedule gap (990s, not the shared fixture's 10s) gives the relay's own 3074 m/s ECEF
% velocity enough time to shift its snapshot position meaningfully between the forward and return
% pass -- at only 10s the resulting delay difference is ~1e-15 (pure floating-point noise, not a
% real physical effect); at 990s it is ~1e-11, ~11 orders of magnitude above the noise floor.
cfg.measurements.groundRelayTimeTransfer.schedule.returnReceptionEpoch_s = 1000;
cfg.measurements.groundRelayTimeTransfer.atmosphere.applyTropo = true;
cfg.measurements.groundRelayTimeTransfer.atmosphere.applyIono = true;
[stationATruth,stationBTruth,relayAssetMoving] = i_truthEndpoints_(); % nonzero v_ecef_mps
envModel = models.errors.EnvironmentModel(masterConfig(),2);
observableAtmo = revgnss.GroundRelayTimeTransferSessionBuilder.buildSession( ...
    cfg,stationATruth,stationBTruth,relayAssetMoving,envModel);
assert(abs(observableAtmo.atmosphereDelayForward_s - observableAtmo.atmosphereDelayReturn_s) > 1e-13, ...
    'FAIL: a moving relay must give forward/return passes a genuinely (not floating-point-noise) different atmosphere delay.');

% Combined review T6: the un-reviewed first cut asserted only the delay difference, never that the
% residual actually SURVIVES into clockDifferenceValue_s as its own comment claimed. Compare
% against a no-atmosphere observable at the SAME (widened, 990s) schedule, and against a STATIC-
% relay negative control at the same schedule (which must show ~zero residual, proving the
% moving-relay shift above is a real physical effect of relay motion, not of the wider schedule
% gap alone).
cfgNoAtmo = cfg;
cfgNoAtmo.measurements.groundRelayTimeTransfer.atmosphere.applyTropo = false;
cfgNoAtmo.measurements.groundRelayTimeTransfer.atmosphere.applyIono = false;
observableNoAtmo = revgnss.GroundRelayTimeTransferSessionBuilder.buildSession( ...
    cfgNoAtmo,stationATruth,stationBTruth,relayAssetMoving,[]);
gotShift_s = observableAtmo.clockDifferenceValue_s - observableNoAtmo.clockDifferenceValue_s;
assert(abs(gotShift_s) > 1e-13, ...
    'FAIL: the moving-relay atmosphere delay difference must survive into a nonzero clockDifferenceValue_s shift.');
% Tolerance set above the light-time solver's own lightTimeTolerance_s=1e-13s convergence floor
% (which chains through elevation/trig evaluations into ~1e-14s of accumulated rounding noise on
% these ~1e-10s-scale quantities), far below the ~2.5e-10s effect size itself -- non-vacuous.
assert(abs(gotShift_s - 0.5*(observableAtmo.atmosphereDelayForward_s-observableAtmo.atmosphereDelayReturn_s)) < 1e-12, ...
    'FAIL: the clockDifferenceValue_s shift must equal (to solver tolerance) half the forward/return atmosphere delay difference (the combiner''s own +-0.5 weighting).');

cfgStatic = cfg;
relayAssetStatic = relayAssetMoving; relayAssetStatic.v_ecef_mps = [0;0;0];
cfgStaticNoAtmo = cfgStatic;
cfgStaticNoAtmo.measurements.groundRelayTimeTransfer.atmosphere.applyTropo = false;
cfgStaticNoAtmo.measurements.groundRelayTimeTransfer.atmosphere.applyIono = false;
observableAtmoStatic = revgnss.GroundRelayTimeTransferSessionBuilder.buildSession( ...
    cfgStatic,stationATruth,stationBTruth,relayAssetStatic,envModel);
observableNoAtmoStatic = revgnss.GroundRelayTimeTransferSessionBuilder.buildSession( ...
    cfgStaticNoAtmo,stationATruth,stationBTruth,relayAssetStatic,[]);
staticShift_s = observableAtmoStatic.clockDifferenceValue_s - observableNoAtmoStatic.clockDifferenceValue_s;
% Threshold set comfortably above solver/floating-point noise at this widened (990s) schedule gap
% (measured ~4.3e-13s) yet ~200x below the genuine moving-relay effect (~2.5e-10s) -- the negative
% control remains meaningful without chasing an unrealistic bit-exact-zero claim.
assert(abs(staticShift_s) < 1e-12, ...
    'FAIL: a static relay at the same widened schedule must show ~zero clockDifferenceValue_s shift (negative control).');
assert(abs(staticShift_s) < abs(gotShift_s)/50, ...
    'FAIL: the static-relay shift must be a small fraction of the genuine moving-relay shift.');

fprintf('  PASS moving-relay atmosphere delay differs forward vs return (%.3e s vs %.3e s) and survives into clockDifferenceValue_s (shift=%.3e s); static-relay negative control ~0 (%.3e s)\n', ...
    observableAtmo.atmosphereDelayForward_s,observableAtmo.atmosphereDelayReturn_s,gotShift_s,staticShift_s);
end

% ================================================================================================
function i_test_atmosphere_inert_when_disabled_()
cfg = i_baseCfg_(); % applyTropo/applyIono both default false
[stationATruth,stationBTruth,relayAssetTruth] = i_truthEndpoints_();
observable = revgnss.GroundRelayTimeTransferSessionBuilder.buildSession( ...
    cfg,stationATruth,stationBTruth,relayAssetTruth,[]); % environmentModel=[] never touched
assert(observable.atmosphereDelayForward_s==0 && observable.atmosphereDelayReturn_s==0);
fprintf('  PASS atmosphere disabled by default: zero delay, environmentModel never dereferenced\n');
end

% ================================================================================================
function cfg = i_baseCfg_()
cfg = masterConfig();
cfg.measurements.groundRelayTimeTransfer.enable = true;
cfg.measurements.groundRelayTimeTransfer.session.stationATowerIndex = 1;
cfg.measurements.groundRelayTimeTransfer.session.stationBTowerIndex = 2;
cfg.measurements.groundRelayTimeTransfer.session.relaySpaceAssetIndex = 1;
cfg.measurements.groundRelayTimeTransfer.schedule.forwardReceptionEpoch_s = 10;
cfg.measurements.groundRelayTimeTransfer.schedule.returnReceptionEpoch_s = 20;
end

% ================================================================================================
function [stationATruth,stationBTruth,relayAssetTruth] = i_truthEndpoints_()
% Combined review m5: stationB at [0;6378137;0] (90 degrees of longitude from stationA, both on
% the equatorial plane with the relay on the x-axis) sees the relay at a NEGATIVE elevation
% (measured -8.6/-4.5 degrees forward/return) -- EnvironmentModel.getTropDelay then clamps at its
% own elevation floor and returns a saturated, physically meaningless delay for a leg with no real
% line of sight, so the atmosphere tests' entire physical content rested on station A alone. 30
% degrees of longitude gives stationB a genuine, non-clamped ~55 degree elevation to the relay
% (measured via models.frames.GeometryUtils.elevationAngle) while remaining a distinct station.
stationATruth = struct('r_ecef_m',[6378137;0;0],'clockBiasMeters',0,'clockDriftMetersPerSecond',0, ...
    'identifier','station:A');
stationBTruth = struct('r_ecef_m',6378137*[cosd(30);sind(30);0],'clockBiasMeters',0, ...
    'clockDriftMetersPerSecond',0,'identifier','station:B');
relayAssetTruth = struct('r_ecef_m',[42164000;0;0],'v_ecef_mps',[0;3074;0], ...
    'attitude_euler_rad',[0;0;0],'clock',struct('getBiasMeters',@() 0,'getDriftMetersPerSecond',@() 0));
end
