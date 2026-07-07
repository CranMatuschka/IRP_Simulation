% test_stage7a_validation
% Task 9: Numeric validation tests — short scenarios checking EKF behavior.
%
% Verifies:
%   T1: cleanConfig single epoch — finite z, h, H; no NaN
%   T2: IF code combination — IF residual smaller than L1-only with active iono
%   T3: thinShell mapping — delay differs from simpleSecant at 10 deg
%   T4: ZWD state — perTowerZwd mode produces ZWD states in H
%   T5: product exact bias match — innovation near zero
%   T6: product wrong bias — deterministic innovation
%   T7: light-time iterative — tau_s > 0 from correctedPseudorange

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_stage7a_validation ===\n');

% ----------------------------------------------------------------
% T1: cleanConfig single epoch — finite measurements
% ----------------------------------------------------------------
fprintf('  T1: cleanConfig single epoch — finite z,h,H ...\n');

cfg1 = revgnss.ConfigFactory.cleanConfig();
cfg1 = revgnss.ConfigFactory.finalizeConfig(cfg1);
cfg1.plots.enable  = false;
cfg1.report.enable = false;

[asset1, towers1, ekf1, mm1] = revgnss.ScenarioFactory.build(cfg1);
[z1, h1, H1, R1, ~] = mm1.computeMeasurements(asset1, towers1, ekf1.x, 0, ekf1.stateMap);

assert(~isempty(z1), 'T1 FAILED: no measurements');
assert(all(isfinite(z1)), 'T1 FAILED: z contains non-finite values');
assert(all(isfinite(h1)), 'T1 FAILED: h contains non-finite values');
assert(all(isfinite(H1(:))), 'T1 FAILED: H contains non-finite values');
innov1 = z1 - h1;
fprintf('    %d measurements, max|innov|=%.4f m: PASS\n', numel(z1), max(abs(innov1)));

% ----------------------------------------------------------------
% T2: IF code — residual smaller with iono active
% ----------------------------------------------------------------
fprintf('  T2: IF code cancels first-order iono ...\n');

% L1-only with iono mismatch (model ≠ truth)
cfgL1 = revgnss.ConfigFactory.defaultConfig();
cfgL1.measurements.codeMode             = 'singleFrequency';
cfgL1.errors.ionosphere.truth.verticalDelayL1_m = 5.0;
cfgL1.errors.ionosphere.model.verticalDelayL1_m = 0.0;  % mismatch
cfgL1.errors.ionosphere.truth.enable   = true;
cfgL1.errors.ionosphere.model.enable   = false;
cfgL1.errors.troposphere.truth.enable  = false;
cfgL1.errors.troposphere.model.enable  = false;
cfgL1.measurements.doppler.enable      = false;
cfgL1.measurements.doppler.useInEKF    = false;
cfgL1.measurements.carrierMode         = 'off';
% Start EKF at truth so innovations reflect iono mismatch, not position/clock transient
cfgL1.estimator.initialError.pos_m          = [0; 0; 0];
cfgL1.estimator.initialError.vel_mps        = [0; 0; 0];
cfgL1.estimator.initialError.euler_deg      = [0; 0; 0];
cfgL1.estimator.initialError.omega_radps    = [0; 0; 0];
cfgL1.estimator.initialError.clockBias_m    = 0;
cfgL1.estimator.initialError.clockDrift_mps = 0;
cfgL1 = revgnss.ConfigFactory.finalizeConfig(cfgL1);
cfgL1.plots.enable  = false;
cfgL1.report.enable = false;

% IF config: rebuild from scratch (avoids double-finalization and inherited state issues)
cfgIF = revgnss.ConfigFactory.defaultConfig();
cfgIF.signals.twoFrequency.enable               = true;
cfgIF.measurements.codeMode                     = 'ionosphereFree';
cfgIF.errors.ionosphere.truth.verticalDelayL1_m = 5.0;
cfgIF.errors.ionosphere.model.verticalDelayL1_m = 0.0;
cfgIF.errors.ionosphere.truth.enable   = true;
cfgIF.errors.ionosphere.model.enable   = false;
cfgIF.errors.troposphere.truth.enable  = false;
cfgIF.errors.troposphere.model.enable  = false;
cfgIF.measurements.doppler.enable      = false;
cfgIF.measurements.doppler.useInEKF    = false;
cfgIF.measurements.carrierMode         = 'off';
% Start EKF at truth so innovations reflect iono cancellation, not position/clock transient
cfgIF.estimator.initialError.pos_m          = [0; 0; 0];
cfgIF.estimator.initialError.vel_mps        = [0; 0; 0];
cfgIF.estimator.initialError.euler_deg      = [0; 0; 0];
cfgIF.estimator.initialError.omega_radps    = [0; 0; 0];
cfgIF.estimator.initialError.clockBias_m    = 0;
cfgIF.estimator.initialError.clockDrift_mps = 0;
cfgIF = revgnss.ConfigFactory.finalizeConfig(cfgIF);
cfgIF.plots.enable  = false;
cfgIF.report.enable = false;

[assetL1, towersL1, ekfL1, mmL1] = revgnss.ScenarioFactory.build(cfgL1);
[zL1, hL1, ~, ~, ~] = mmL1.computeMeasurements(assetL1, towersL1, ekfL1.x, 0, ekfL1.stateMap);
rmsL1 = sqrt(mean((zL1-hL1).^2));

[assetIF, towersIF, ekfIF, mmIF] = revgnss.ScenarioFactory.build(cfgIF);
[zIF, hIF, ~, ~, ~] = mmIF.computeMeasurements(assetIF, towersIF, ekfIF.x, 0, ekfIF.stateMap);
rmsIF = sqrt(mean((zIF-hIF).^2));

assert(rmsIF < rmsL1 * 0.5, ...
    'T2 FAILED: IF residual RMS=%.4f should be < 50%% of L1 RMS=%.4f with iono mismatch', ...
    rmsIF, rmsL1);
fprintf('    L1 RMS=%.4f m, IF RMS=%.4f m (IF cancels iono): PASS\n', rmsL1, rmsIF);

% ----------------------------------------------------------------
% T3: thinShell mapping delay differs from simpleSecant at 10 deg
% ----------------------------------------------------------------
fprintf('  T3: thinShell vs simpleSecant delay differs at low elevation ...\n');

el_10 = 10 * pi/180;
f_L1  = 1575.42e6;

% Build minimal EnvironmentModel for simpleSecant
cfgSec = revgnss.ConfigFactory.defaultConfig();
cfgSec.errors.ionosphere.truth.enable = true;
cfgSec.errors.ionosphere.truth.verticalDelayL1_m = 5.0;
cfgSec.effects.ionosphere.mappingModel = 'simpleSecant';
envSec = models.errors.EnvironmentModel(cfgSec, 1);
dSec = envSec.getIonoDelay(1, el_10, 'truth', f_L1, f_L1);

% thinShell config
cfgTS = cfgSec;
cfgTS.effects.ionosphere.mappingModel  = 'thinShell';
cfgTS.effects.ionosphere.shellHeight_m = 350e3;
envTS = models.errors.EnvironmentModel(cfgTS, 1);
dTS = envTS.getIonoDelay(1, el_10, 'truth', f_L1, f_L1);

relDiff = abs(dSec - dTS) / abs(dSec);
assert(relDiff > 0.05, ...
    'T3 FAILED: simpleSecant=%.4f vs thinShell=%.4f m, relDiff=%.2f%% (expected > 5%%)', ...
    dSec, dTS, relDiff*100);
fprintf('    simpleSecant=%.4f thinShell=%.4f m, diff=%.1f%%: PASS\n', dSec, dTS, relDiff*100);

% ----------------------------------------------------------------
% T4: ZWD state — perTowerZwd produces non-zero ZWD H columns
% ----------------------------------------------------------------
fprintf('  T4: perTowerZwd — non-zero ZWD H columns ...\n');

cfg4 = revgnss.ConfigFactory.defaultConfig();
cfg4.estimation.troposphereMode = 'perTowerZwd';
cfg4.measurements.doppler.enable   = false;
cfg4.measurements.doppler.useInEKF = false;
cfg4.measurements.carrierMode      = 'off';
cfg4 = revgnss.ConfigFactory.finalizeConfig(cfg4);
cfg4.plots.enable  = false;
cfg4.report.enable = false;

[asset4, towers4, ekf4, mm4] = revgnss.ScenarioFactory.build(cfg4);
[~, ~, H4, ~, ~] = mm4.computeMeasurements(asset4, towers4, ekf4.x, 0, ekf4.stateMap);

sm4 = ekf4.stateMap;
assert(isfield(sm4,'zwdIdx') && ~isempty(sm4.zwdIdx), 'T4 FAILED: no ZWD states in stateMap');
zwdCols = sm4.zwdIdx(sm4.zwdIdx > 0 & sm4.zwdIdx <= size(H4,2));
assert(~isempty(zwdCols), 'T4 FAILED: no valid ZWD column indices');
hasNonzero = any(any(abs(H4(:,zwdCols)) > 1e-6));
assert(hasNonzero, 'T4 FAILED: all ZWD H columns are zero');
fprintf('    ZWD H columns non-zero (nZwd=%d): PASS\n', numel(zwdCols));

% ----------------------------------------------------------------
% T5: product exact match — small innovation
% ----------------------------------------------------------------
fprintf('  T5: product exact bias match — small innovation ...\n');

cfg5 = revgnss.ConfigFactory.towerClockProductConfig();
cfg5.scenario.nTowers = 1;
% Start EKF at truth so innovations reflect product clock accuracy only
cfg5.estimator.initialError.pos_m          = [0; 0; 0];
cfg5.estimator.initialError.vel_mps        = [0; 0; 0];
cfg5.estimator.initialError.euler_deg      = [0; 0; 0];
cfg5.estimator.initialError.omega_radps    = [0; 0; 0];
cfg5.estimator.initialError.clockBias_m    = 0;
cfg5.estimator.initialError.clockDrift_mps = 0;
cfg5 = revgnss.ConfigFactory.finalizeConfig(cfg5);
cfg5.plots.enable  = false;
cfg5.report.enable = false;

[asset5, towers5, ekf5, mm5] = revgnss.ScenarioFactory.build(cfg5);
% Set product bias to match true tower clock (which is 0 for deterministic config)
cfg5.towerClock.products(1).bias_m    = 0.0;
cfg5.towerClock.products(1).drift_mps = 0.0;
cfg5.towerClock.products(1).epoch_s   = 0.0;

% Rebuild with corrected config
[~, ~, ~, mm5b] = revgnss.ScenarioFactory.build(cfg5);
[z5, h5, ~, ~, ~] = mm5b.computeMeasurements(asset5, towers5, ekf5.x, 0, ekf5.stateMap);
innov5 = z5 - h5;
% With matched product and default config (matched trop/iono), innovations should be small
% (dominated by code noise sigma ~0.3 m)
assert(max(abs(innov5)) < 10.0, ...
    'T5 FAILED: exact product match should give |innov| < 10 m, got %.2f m', max(abs(innov5)));
fprintf('    exact product match max|innov|=%.4f m (< 10 m): PASS\n', max(abs(innov5)));

% ----------------------------------------------------------------
% T6: product wrong bias — deterministic innovation
% ----------------------------------------------------------------
fprintf('  T6: product wrong bias — deterministic innovation ...\n');

cfg6 = revgnss.ConfigFactory.towerClockProductConfig();
cfg6.scenario.nTowers = 1;
cfg6.errors.codeNoise.sigma_m = 0;  % zero noise to isolate bias effect
cfg6 = revgnss.ConfigFactory.finalizeConfig(cfg6);
cfg6.plots.enable  = false;
cfg6.report.enable = false;

biasErr = 100.0;  % 100 m wrong bias
cfg6.towerClock.products(1).bias_m    = biasErr;
cfg6.towerClock.products(1).drift_mps = 0.0;
cfg6.towerClock.products(1).epoch_s   = 0.0;

[asset6, towers6, ekf6, mm6] = revgnss.ScenarioFactory.build(cfg6);
[z6, h6, ~, ~, ~] = mm6.computeMeasurements(asset6, towers6, ekf6.x, 0, ekf6.stateMap);
innov6 = z6 - h6;
assert(max(abs(innov6)) > biasErr * 0.5, ...
    'T6 FAILED: wrong product bias %g m should create innovation > %g m, got %.2f', ...
    biasErr, biasErr*0.5, max(abs(innov6)));
fprintf('    wrong bias %g m created max|innov|=%.2f m: PASS\n', biasErr, max(abs(innov6)));

% ----------------------------------------------------------------
% T7: light-time iterative — tau_s > 0 from correctedPseudorange
% ----------------------------------------------------------------
fprintf('  T7: light-time iterative — tau_s > 0 ...\n');

r_rx7  = [42164e3; 0; 0];
r_twr7 = [6378e3;  0; 0];
cfg7   = revgnss.ConfigFactory.defaultConfig();
cfg7.effects.lightTime.model = 'iterative';

[~, c7] = models.corrections.RangeCorrections.correctedPseudorange(r_rx7, r_twr7, cfg7, 'model', pi/4);
assert(c7.tau_s > 0.1, 'T7 FAILED: tau_s=%.4f s, expected > 0.1 s for GEO', c7.tau_s);
assert(~isempty(c7.t_tx_s), 'T7 FAILED: t_tx_s should not be empty in iterative mode');
fprintf('    iterative tau_s=%.4f s (>0.1 s): PASS\n', c7.tau_s);

fprintf('=== test_stage7a_validation: ALL PASS ===\n');
