% test_wpI_tower_clock_R_double_count  WP-I: complete tower-clock product-sigma R guard.
%
% When a tower clock is an EKF state (estimateTowerClocks=true) its uncertainty lives in
% the state covariance P, so its broadcast-product sigma must NOT also be charged into the
% measurement covariance R -- otherwise the same variance is counted twice (F1 double-count,
% reachable via clock.mode='includeTowerClocksInEKF' + a noisy product mode). The guard was
% previously present only on the single-frequency code diagonal; WP-I routes ALL sinks
% (L2/multi-sig, ionosphere-free, shared-tower block, Doppler drift, carrier drift, cross-
% stack) through one helper. This test locks the guard logic and the two under-count traps.
%
%   T1  helper masks the addressed column only, per tower, retaining gauge/non-estimated towers
%   T2  COLUMN DISCIPLINE: a bias-only state model must NOT mask the drift sigma (and vice versa)
%   T3  GOLDEN SAFETY: identity when no tower-clock states exist (towerClockIdx all zero)
%   T4  FUNCTIONAL: includeTowerClocksInEKF + noisy product + gauge runs (double-count path exercised)

fprintf('=== test_wpI_tower_clock_R_double_count ===\n');
thisDir = fileparts(mfilename('fullpath'));
oo = fileparts(thisDir);
addpath(oo); addpath(fullfile(oo,'config'));
mask = @models.measurements.CodeMeasurementBuilder.maskStateTowerSigma_;

% ---- T1: per-tower / per-column masking, gauge tower retained --------------
% tower1 = bias+drift states; tower2 = gauge/reference (no states); tower3 = bias+drift states.
sm.towerClockIdx = [11 12; 0 0; 15 16];
sig = [0.01; 0.02; 0.03];
biasMasked  = mask(sig, [1;2;3], sm, 1);
driftMasked = mask(sig, [1;2;3], sm, 2);
assert(isequal(biasMasked,  [0; 0.02; 0]), 'T1 FAILED: bias mask (col 1) wrong or gauge tower not retained.');
assert(isequal(driftMasked, [0; 0.02; 0]), 'T1 FAILED: drift mask (col 2) wrong or gauge tower not retained.');
fprintf('  T1 per-tower/per-column mask, gauge tower retained: PASS\n');

% ---- T2: column discipline (the primary under-count trap) ------------------
% Bias estimated, drift NOT (towerClockIdx(:,2)==0): the drift residual is un-modelled by
% P, so R legitimately needs its sigma -> masking on the drift column must be a NO-OP.
smBiasOnly.towerClockIdx = [11 0; 21 0];
assert(isequal(mask([0.01;0.02], [1;2], smBiasOnly, 2), [0.01;0.02]), ...
    'T2 FAILED: drift sigma must NOT be masked when only the bias is a state (under-count trap).');
assert(isequal(mask([0.01;0.02], [1;2], smBiasOnly, 1), [0;0]), ...
    'T2 FAILED: bias sigma must be masked when the bias is a state.');
fprintf('  T2 column discipline (bias-only model keeps drift sigma): PASS\n');

% ---- T3: golden safety (identity when no tower-clock states) ---------------
smNone.towerClockIdx = zeros(3,2);
assert(isequal(mask(sig, [1;2;3], smNone, 1), sig) && isequal(mask(sig, [1;2;3], smNone, 2), sig), ...
    'T3 FAILED: guard must be identity when no tower clock is a state (golden byte-identical).');
assert(isequal(mask(sig, [1;2;3], struct(), 1), sig), 'T3 FAILED: missing towerClockIdx must be identity.');
fprintf('  T3 golden safety (identity when no tower states): PASS\n');

% ---- T4: functional -- the previously double-counting path now runs --------
% Code-only base (as tests/test_stage9_clock_gauge_ekf.m): estimate tower clocks with a
% NOISY product mode (nonzero bias+drift product sigma) + a datum gauge -> exactly the
% F1 double-count trigger. The masked builders must run and stay finite.
cfg = revgnss.ConfigFactory.defaultConfig();
cfg.scenario.nTowers    = 5;
cfg.scenario.nReceivers = 1;
cfg.simulation.duration_s = 60; cfg.simulation.dt_s = 1;
cfg.plots.enable = false; cfg.report.enable = false;
cfg.clock.mode = 'includeTowerClocksInEKF';           % tower clocks become EKF states
cfg.clock.gauge.mode = 'fixReferenceTower';           % datum constraint
cfg.clock.gauge.referenceTowerIndex = 1;
cfg.clock.gauge.sigmaBias_m = 1e-4; cfg.clock.gauge.sigmaDrift_mps = 1e-7;
cfg.towerClock.correctionMode = 'truthHistoryProductNoisy';   % nonzero product sigma -> the trigger
cfg.measurements.doppler.enable = true; cfg.measurements.doppler.useInEKF = true;  % exercise drift sinks
sim = revgnss.ReverseGNSSSimulation(cfg);
sim.run();
clkErr = sim.simData.getClockBiasErrors();
assert(~isempty(clkErr) && all(isfinite(clkErr)), 'T4 FAILED: clock error non-finite (double-count path unstable).');
assert(sim.ekf.estimateTowerClocks, 'T4 FAILED: tower clocks were not estimated (path not exercised).');
assert(any(sim.ekf.stateMap.towerClockIdx(:) > 0), 'T4 FAILED: no tower-clock states allocated.');
fprintf('  T4 functional includeTowerClocksInEKF + noisy product + gauge runs (finite): PASS\n');

fprintf('=== test_wpI_tower_clock_R_double_count: ALL PASSED ===\n');
