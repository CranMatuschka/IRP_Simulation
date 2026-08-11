% test_wpD_relativistic_clock  WP-D: relativistic clock-rate offset on the truth clock.
%
%   T1  revgnss.Relativity helper returns the correct GEO offset + numeric bound
%   T2  a ClockModel with relativisticFracFreq accumulates a LINEAR bias ramp at c*y_rel,
%       and the offset IS INCLUDED in the reported fractional frequency / drift, so the
%       reported drift equals the slope of the bias ramp (the two truth channels agree)
%   T3  golden safety: default config resolves relativity.clock OFF and injects no offset
%   T5  ANTI-INERTNESS: physics.relativity.clock.model.enable must reach a real consumer.
%       This is the defect class that produced the bug -- the model gate existed and was
%       set true in golden_baseline.json but had NO READER anywhere, so the estimator never
%       applied the correction and 13 m of position error was attributed to oscillator
%       quality. A gate with no consumer must fail here, not in a ladder six months later.

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
% The offset MUST appear in the reported fractional frequency and drift.
%
% INVERTED 2026-08-09. This test previously asserted the OPPOSITE -- that the relativistic
% offset must not reach getFractionalFrequency()/getDriftMetersPerSecond() -- and that
% assertion was enforcing a defect. The offset is a genuine frequency offset: the oscillator
% runs fast by y_rel, so it belongs in the clock's RATE exactly as it belongs, integrated, in
% its phase. Excluding it made the TRUTH internally inconsistent, because
% DopplerMeasurementBuilder builds truth range-rate from this accessor while the pseudorange
% builders use getBiasMeters(): the truth range ramped at c*y_rel while the truth Doppler
% reported a clock rate of zero.
%
% The EKF propagates b_rx' = bdot_rx and so cannot satisfy both channels. MEASURED on
% G5S1R4 / 3600 s with every error source disabled: 13.07 m of position error on an OCXO
% clock Q against 0.20 m on a caesium Q, with the position error vector parallel to the
% common-mode Kalman-gain direction K*1 (cos = 0.9997) and the reported position sigma
% identical to 4 s.f. in both -- an err/sigma of 34 that no covariance could have flagged.
assert(abs(clk.getFractionalFrequency() - y) < 1e-6*abs(y), ...
    'T2 FAILED: relativistic offset missing from the reported fractional frequency.');
assert(abs(clk.getDriftMetersPerSecond() - c*y) < 1e-6*abs(c*y), ...
    'T2 FAILED: relativistic offset missing from the reported drift.');
% Consistency of the two truth channels is the property that actually matters: the reported
% drift must equal the phase ramp's own slope, or the 2-state clock model cannot represent
% the truth at all.
slope_mps = (clk.getBiasMeters() - clk2.getBiasMeters()) / 50;
assert(abs(slope_mps - clk.getDriftMetersPerSecond()) < 1e-9, ...
    'T2 FAILED: reported drift does not equal the slope of the clock-bias ramp.');
fprintf(['  T2 linear bias ramp (%.1f m at 100 s), drift %.6f m/s == ramp slope ' ...
    '%.6f m/s: PASS\n'], biasM_100, clk.getDriftMetersPerSecond(), slope_mps);

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

% ---- T5: ANTI-INERTNESS -- the model gate must reach a real consumer -------
% THE DEFECT THIS GUARDS. physics.relativity.clock.model.enable was set true in
% golden_baseline.json and had NO READER anywhere in the repository. Nothing removed the
% offset from h, so the estimated clock states had to absorb the whole c*y_rel*t ramp --
% which a two-state clock cannot do while the truth Doppler says the rate is zero. The
% result was 13.07 m of position error on an OCXO clock Q against 0.20 m on a caesium Q,
% attributed for months to oscillator quality. A gate with no consumer must fail HERE.

% (a) gate OFF -> identically zero on both channels, so relativity-off runs are untouched.
cfgOff = masterConfig();
assert(models.clocks.RelativisticClockCorrection.bias_m(cfgOff, 3600) == 0 && models.clocks.RelativisticClockCorrection.rate_mps(cfgOff) == 0, ...
    'T5 FAILED: model correction is non-zero with the gate off (breaks golden byte-identity).');

% (b) gate ON -> both channels non-zero, equal to the published constant, and the RANGE
%     correction is the exact time integral of the RATE correction. If those two ever
%     disagree the estimator re-creates the original defect with the sign flipped.
assert(cfgOn.physics.relativity.clock.model.enable, 'T5 FAILED: model gate did not survive finalize.');
rate = models.clocks.RelativisticClockCorrection.rate_mps(cfgOn);
bias = models.clocks.RelativisticClockCorrection.bias_m(cfgOn, 3600);
assert(abs(rate - c*y) < 1e-9, 'T5 FAILED: model rate correction != c*y_rel.');
assert(abs(bias - rate*3600) < 1e-6, ...
    'T5 FAILED: model range correction is not the time integral of the rate correction.');

% (c) the resolved config must RECORD the constant it applied (traceability), and it must
%     match the truth-side value when both are derived from the same orbit.
assert(abs(cfgOn.physics.relativity.clock.model.fracFreq - ...
           cfgOn.asset.clock.relativisticFracFreq) < 5e-13, ...
    'T5 FAILED: model fracFreq was not resolved, or disagrees with the truth-side value.');

% (d) the correction must be state-INDEPENDENT: it is published knowledge, not an unknown.
%     A non-zero derivative here would mean someone modelled it as a state and H/R would
%     need to change with it.
assert(models.clocks.RelativisticClockCorrection.bias_m(cfgOn, 0) == 0, 'T5 FAILED: correction must vanish at the reference epoch.');
assert(abs(models.clocks.RelativisticClockCorrection.bias_m(cfgOn, 7200) - 2*models.clocks.RelativisticClockCorrection.bias_m(cfgOn, 3600)) < 1e-6, ...
    'T5 FAILED: range correction is not linear in time.');
fprintf(['  T5 anti-inertness: gate off -> 0/0; gate on -> rate %.6f m/s, range %.2f m at ' ...
    '3600 s (= rate*t), resolved fracFreq matches truth: PASS\n'], rate, bias);

fprintf('=== test_wpD_relativistic_clock: ALL PASSED ===\n');
