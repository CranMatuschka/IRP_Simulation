% test_wpD_relativistic_clock  WP-D: relativistic clock-rate offset on the truth clock.
%
%   T1  revgnss.Relativity helper returns the correct GEO offset + numeric bound
%   T2  a ClockModel with relativisticFracFreq accumulates a LINEAR bias ramp at c*y_rel,
%       and the offset is EXCLUDED from the reported fractional frequency / drift
%   T3  golden safety: default config resolves relativity.clock OFF and injects no offset

fprintf('=== test_wpD_relativistic_clock ===\n');
thisDir = fileparts(mfilename('fullpath'));
oo = fileparts(thisDir);
addpath(oo); addpath(fullfile(oo,'config'));
c = revgnss.Constants.SPEED_OF_LIGHT_MPS;

% ---- T1: helper value + numeric bound --------------------------------------
y    = revgnss.Relativity.geoClockFracFreq(35786000);          % with ground-rotation term
ySat = revgnss.Relativity.geoClockFracFreq(35786000, false);   % satellite terms only
assert(abs(y    - 5.3877e-10) < 5e-13, 'T1 FAILED: GEO offset (with ground) wrong.');
assert(abs(ySat - 5.3757e-10) < 5e-13, 'T1 FAILED: GEO offset (sat-only) wrong.');
assert(abs(c*y - 0.16152) < 1e-3, 'T1 FAILED: clock-range rate wrong.');
b = revgnss.Relativity.clockBudget(35786000, 14400);
assert(abs(b.microsecPerDay - 46.55) < 0.1, 'T1 FAILED: us/day wrong.');
assert(abs(b.rangeOverRun_m - 2325.9) < 2.0, 'T1 FAILED: range over 14400 s wrong.');
assert(b.periodicResidual_m == 0, 'T1 FAILED: periodic residual must be 0 for a circular orbit.');
fprintf('  T1 helper: y=%.4e (%.2f us/day, %.0f m over 14400 s), periodic=0: PASS\n', ...
    y, b.microsecPerDay, b.rangeOverRun_m);

% ---- T2: linear bias ramp; offset excluded from reported drift/frac ---------
cfgClk = struct('name','relTest','clockType','CESIUM1','deterministic',true,'seed',1, ...
    'noiseCoeffs',struct('h2',0,'h1',0,'h0',0,'hMinus1',0,'hMinus2',0), ...
    'relativisticFracFreq', y);
clk = models.clocks.ClockModel(cfgClk);
clk.precomputeNoise(0:1:100);
for k = 1:100; clk.step(1.0); end
biasM_100 = clk.getBiasMeters();
expected  = 100 * c * y;                       % linear: b(t) = c*y_rel*t
assert(abs(biasM_100 - expected) < 1e-6*abs(expected) + 1e-9, ...
    'T2 FAILED: clock bias did not accumulate linearly at c*y_rel.');
% Halfway check confirms linearity (not quadratic — would fail if injected via driftRate).
clk2 = models.clocks.ClockModel(cfgClk); clk2.precomputeNoise(0:1:100);
for k = 1:50; clk2.step(1.0); end
assert(abs(clk2.getBiasMeters() - 0.5*expected) < 1e-6*abs(expected)+1e-9, ...
    'T2 FAILED: bias not linear in time (relativistic offset must not be a frequency drift).');
% The offset must NOT leak into the reported fractional frequency / drift (so the EKF
% drift-state seed from getDriftMetersPerSecond() is unchanged -> genuine truth signature).
assert(abs(clk.getFractionalFrequency()) < 1e-15, 'T2 FAILED: offset leaked into fractional frequency.');
assert(abs(clk.getDriftMetersPerSecond()) < 1e-9, 'T2 FAILED: offset leaked into reported drift.');
fprintf('  T2 linear bias ramp (%.1f m at 100 s), drift/frac exclude offset: PASS\n', biasM_100);

% ---- T3: golden safety -- default OFF, no injection ------------------------
cfg  = masterConfig();
assert(~cfg.physics.relativity.clock.enable, 'T3 FAILED: master relativity.clock must default OFF.');
cfg2 = revgnss.ConfigFactory.finalizeConfig(cfg);
truthOn = false;
try; truthOn = cfg2.physics.relativity.clock.truth.enable; catch; end
assert(~truthOn, 'T3 FAILED: resolved relativity.clock.truth must be OFF by default.');
relFF = 0;   % absent field => ClockModel default 0 (golden byte-identical)
try; relFF = cfg2.asset.clock.relativisticFracFreq; catch; end
assert(relFF == 0, ...
    'T3 FAILED: no relativistic offset must be injected into the receiver clock by default.');
fprintf('  T3 golden safety (default OFF, no injection): PASS\n');

% ---- T4: enabled path injects the offset into the receiver clock ----------
cfgOn = masterConfig();
cfgOn.physics.relativity.clock.enable = true;
cfgOn = expandEnableToggles(cfgOn, {'physics.relativity.clock'});   % slave master -> truth/model
cfgOn = revgnss.ConfigFactory.finalizeConfig(cfgOn);
assert(cfgOn.physics.relativity.clock.truth.enable, 'T4 FAILED: enabling did not survive finalize.');
assert(abs(cfgOn.asset.clock.relativisticFracFreq - y) < 5e-13, ...
    'T4 FAILED: enabled path did not inject the relativistic offset into the receiver clock.');
fprintf('  T4 enabled path injects offset (%.4e) into receiver clock: PASS\n', ...
    cfgOn.asset.clock.relativisticFracFreq);

fprintf('=== test_wpD_relativistic_clock: ALL PASSED ===\n');
