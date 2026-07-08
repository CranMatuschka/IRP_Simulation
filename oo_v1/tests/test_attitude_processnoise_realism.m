% test_attitude_processnoise_realism  WP3 acceptance test: attitude process noise
% (sigma_angAccel) is set from a physically defensible torque budget for
% attitude-ESTIMATING presets, and is left inert for the frozen-attitude preset.
%
% Physical basis: real spacecraft see gravity-gradient / solar-radiation-pressure /
% residual-magnetic torques implying angular accelerations ~1e-9..1e-6 rad/s^2
% (Wertz, "Spacecraft Attitude Determination and Control", 1978). The previous
% 1e-10..1e-9 literals made the EKF attitude covariance over-confident. WP3 derives
% sigma_angAccel = tau / I from cfg.asset, giving ~1e-7 rad/s^2 (conservative end).
%
% Parts:
%   A. angAccelFromTorqueBudget_ computes tau/I; every estimateAttitude=true preset now
%      yields sigma_angAccel_radps2 >= 1e-8; positionClockOnlyConfig stays 1e-15 (off).
%   B. Mechanism: the EKF attitude process-noise block scales as sigma_angAccel^2, so the
%      realistic value gives a LARGER attitude Q than the old 1e-15 (documents the old
%      value's over-confidence), and the EKF actually uses the config value.
%   C. Observability tie-in: when attitude is estimated but geometry makes it weak/
%      unobservable, the audit warns that the reported attitude covariance is
%      process-noise-limited (not measurement-constrained).

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));
addpath(fullfile(thisDir, '..', 'config'));

fprintf('=== test_attitude_processnoise_realism ===\n');

FLOOR = 1e-8;   % justified minimum for attitude-estimating presets

% ================================================================
% Part A: helper + per-preset defaults
% ================================================================
fprintf('  A. torque-budget helper + per-preset sigma_angAccel ...\n');
assert(abs(revgnss.ConfigFactory.angAccelFromTorqueBudget_(10, 1e-6) - 1e-7) < 1e-18, ...
    'Part A FAILED: helper tau/I incorrect');
assert(abs(revgnss.ConfigFactory.angAccelFromTorqueBudget_(4, 2e-6) - 5e-7) < 1e-18, ...
    'Part A FAILED: helper tau/I incorrect (2)');

% Attitude-estimating presets must all be >= FLOOR.
presets = struct('name', {}, 'cfg', {});
presets(end+1) = struct('name','masterConfig',                'cfg', masterConfig());
presets(end+1) = struct('name','singleAssetCarrierAttitude',  'cfg', ...
    revgnss.ScenarioPresets.apply(revgnss.ConfigFactory.defaultConfig(),'singleAssetCarrierAttitude'));
presets(end+1) = struct('name','multiAntennaAttitudeConfig',  'cfg', revgnss.ConfigFactory.multiAntennaAttitudeConfig());
presets(end+1) = struct('name','geoRealWorldTruthComparison', 'cfg', ...
    revgnss.ConfigFactory.geoRealWorldTruthComparisonConfig());
for i = 1:numel(presets)
    saa = presets(i).cfg.estimator.sigma_angAccel_radps2;
    assert(saa >= FLOOR, 'Part A FAILED: %s sigma_angAccel=%.2e < floor %.0e', ...
        presets(i).name, saa, FLOOR);
    fprintf('    %-28s sigma_angAccel = %.2e (>= %.0e)\n', presets(i).name, saa, FLOOR);
end

% positionClockOnlyConfig: attitude off, value left inert at 1e-15.
pco = revgnss.ConfigFactory.positionClockOnlyConfig();
assert(~pco.estimator.estimateAttitude, 'Part A FAILED: positionClockOnly should have attitude off');
assert(abs(pco.estimator.sigma_angAccel_radps2 - 1e-15) < 1e-30, ...
    'Part A FAILED: positionClockOnly sigma_angAccel should remain 1e-15 (inert)');
fprintf('    positionClockOnlyConfig      sigma_angAccel = 1e-15 (inert, attitude off)\n');
fprintf('    PASS\n');

% ================================================================
% Part B: EKF attitude Q scales as sigma^2 (realistic > old 1e-15)
% ================================================================
fprintf('  B. attitude process-noise block scales as sigma_angAccel^2 ...\n');
cfgB = revgnss.ConfigFactory.multiAntennaAttitudeConfig();   % estimateAttitude = true
[~, ~, ekf] = revgnss.ScenarioFactory.build(cfgB);
assert(ekf.estimateAttitude, 'Part B FAILED: expected an attitude-estimating EKF');
sm = ekf.stateMap;
dt = 1.0;

ekf.sigma_angAccel_radps2 = 1e-15;
Q_old = ekf.buildQ_(dt, {});
qOld  = trace(Q_old(sm.euler_idx, sm.euler_idx));

ekf.sigma_angAccel_radps2 = 1e-7;
Q_new = ekf.buildQ_(dt, {});
qNew  = trace(Q_new(sm.euler_idx, sm.euler_idx));

fprintf('    trace(Q_euler): old(1e-15)=%.3e  new(1e-7)=%.3e  ratio=%.3e\n', qOld, qNew, qNew/qOld);
assert(qNew > qOld, 'Part B FAILED: realistic Q not larger than 1e-15 Q');
expectedRatio = (1e-7 / 1e-15)^2;
assert(abs(qNew/qOld - expectedRatio) / expectedRatio < 1e-6, ...
    'Part B FAILED: attitude Q does not scale as sigma^2 (ratio %.3e vs %.3e)', ...
    qNew/qOld, expectedRatio);
fprintf('    PASS (Q_euler ~ sigma_angAccel^2; old 1e-15 was over-confident)\n');

% ================================================================
% Part C: observability tie-in warning
% ================================================================
fprintf('  C. process-noise-limited warning when attitude weak/unobservable ...\n');
cfgC = revgnss.ConfigFactory.finalizeConfig(revgnss.ConfigFactory.multiAntennaAttitudeConfig());
assert(cfgC.estimator.estimateAttitude, 'Part C FAILED: expected estimateAttitude=true');
% H with ZERO attitude columns -> unobservable attitude while it is being estimated.
Hbad = randn(8, ekf.nx);
Hbad(:, sm.euler_idx) = 0;
audit = revgnss.AttitudeObservability.audit(Hbad, sm, cfgC, {});
assert(~audit.isObservable, 'Part C FAILED: zeroed attitude columns should be unobservable');
hasWarn = any(cellfun(@(w) contains(w, 'process-noise-limited'), audit.warnings));
assert(hasWarn, 'Part C FAILED: missing process-noise-limited warning (classification=%s)', audit.classification);
fprintf('    classification=%s -> warned process-noise-limited\n', audit.classification);
fprintf('    PASS\n');

fprintf('=== test_attitude_processnoise_realism: ALL PASS ===\n');
