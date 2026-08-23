% test_clock_noise_master_span  Gate: clock.noiseMasterSpan.enable
%
% ClockModel.precomputeNoise synthesises the WPM/FPM/FFM colour by FFT spectral
% shaping. The DFT bin spacing is 1/T for a span T, and every output sample is a sum
% over ALL bins, so with the legacy default the realisation is a function of the ARC
% LENGTH: one seed run for 2 h and for 6 h gives two DIFFERENT clocks over their
% common span. That makes a duration study impossible, because "how long is the arc"
% and "which clock did I draw" cannot be separated.
%
% The gate synthesises once on a FIXED grid and gives each run its leading window,
% so one seed defines one clock and a longer arc merely observes more of it.
%
% Asserted here:
%   1. gate OFF reproduces the legacy arc-length dependence (the defect is real)
%   2. gate ON makes the common span BIT-IDENTICAL across arc lengths
%   3. gate ON also pins the post-synthesis stream position (step() draws agree)
%   4. gate ON refuses a run longer than the master span, and a non-zero start
%   5. gate ON leaves the Allan deviation on the flicker floor
%   6. ScenarioFactory.clockNoiseMasterSpan resolves the config correctly

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_clock_noise_master_span ===\n');

DT    = 1.0;
T2    = 7200;      % 2 h
T6    = 21600;     % 6 h
SPAN  = 86400;     % 24 h master grid
n2    = T2/DT + 1;
HM1   = 1e-25;     % flicker FM, the only synthesised term for a catalogue oscillator

mkClock = @(sd) models.clocks.ClockModel(struct( ...
    'name','probe','clockType','CESIUM1','seed',sd,'deterministic',false, ...
    'bias_s',0,'fracFreq',0, ...
    'noiseCoeffs', struct('h2',0,'h1',0,'h0',1e-19,'hMinus1',HM1,'hMinus2',2e-32)));

% --- 1. Gate OFF: the legacy arc-length dependence is still there --------
a = mkClock(201); a.precomputeNoise((0:DT:T2)');
b = mkClock(201); b.precomputeNoise((0:DT:T6)');
legacyDiff = max(abs(a.noiseBias_s_vec - b.noiseBias_s_vec(1:n2)));
fprintf('  gate OFF, 2 h vs first 2 h of 6 h : max|diff| = %.4g s\n', legacyDiff);
assert(legacyDiff > 0, ...
    ['test_clock_noise_master_span FAILED: the legacy path is expected to depend on ' ...
     'the arc length. If this now passes trivially the default was flipped without ' ...
     'updating this test.']);

% --- 2. Gate ON: the common span is bit-identical ------------------------
c = mkClock(201); c.noiseMasterSpan_s = SPAN; c.precomputeNoise((0:DT:T2)');
d = mkClock(201); d.noiseMasterSpan_s = SPAN; d.precomputeNoise((0:DT:T6)');
gatedBias = max(abs(c.noiseBias_s_vec     - d.noiseBias_s_vec(1:n2)));
gatedFreq = max(abs(c.noiseFracFreq_vec   - d.noiseFracFreq_vec(1:n2)));
fprintf('  gate ON,  2 h vs first 2 h of 6 h : max|diff| = %.4g s (bias), %.4g (frac)\n', ...
    gatedBias, gatedFreq);
assert(gatedBias == 0 && gatedFreq == 0, ...
    ['test_clock_noise_master_span FAILED: the master grid must make the common span ' ...
     'exactly equal (bias %g, frac %g).'], gatedBias, gatedFreq);

% --- 3. Gate ON: the post-synthesis stream position is pinned too --------
% precomputeNoise consumes 2N draws before step() begins. With N tied to the run
% length, the WFM/RWFM draws in step() also shift with the arc; on the master grid
% N is constant, so they must agree epoch for epoch.
e = mkClock(202); e.noiseMasterSpan_s = SPAN; e.precomputeNoise((0:DT:T2)');
f = mkClock(202); f.noiseMasterSpan_s = SPAN; f.precomputeNoise((0:DT:T6)');
for k = 1:300; e.step(DT); f.step(DT); end
stepDiff = max(abs([e.getBiasSeconds() - f.getBiasSeconds(), ...
                    e.getFractionalFrequency() - f.getFractionalFrequency()]));
fprintf('  gate ON,  after 300 step() calls  : max|diff| = %.4g\n', stepDiff);
assert(stepDiff == 0, ...
    ['test_clock_noise_master_span FAILED: the stochastic state must also be ' ...
     'arc-length independent under the gate (diff %g).'], stepDiff);

% --- 4. Gate ON: the two misuse guards ----------------------------------
g = mkClock(203); g.noiseMasterSpan_s = 600;
threw = false;
try
    g.precomputeNoise((0:DT:1200)');            % run longer than the master span
catch me
    threw = strcmp(me.identifier, 'ClockModel:precomputeNoise');
end
assert(threw, ...
    'test_clock_noise_master_span FAILED: a run longer than the master span must error.');

h = mkClock(204); h.noiseMasterSpan_s = SPAN;
threw = false;
try
    h.precomputeNoise((100:DT:1200)');          % window must be the leading one
catch me
    threw = strcmp(me.identifier, 'ClockModel:precomputeNoise');
end
assert(threw, ...
    'test_clock_noise_master_span FAILED: a grid not starting at 0 must error.');
fprintf('  gate ON,  both misuse guards fire  : PASS\n');

% --- 5. Gate ON: the Allan deviation stays on the flicker floor ---------
% Flicker FM has a flat ADEV at sqrt(2 ln2 h_-1). Averaged over seeds, the windowed
% series must sit on it as closely as the legacy one does.
theory = sqrt(2*log(2)*HM1);
tProbe = [10 60 300];
tV2    = (0:DT:T2)';
accOff = []; accOn = [];
for sd = 211:222
    p = models.clocks.ClockModel(struct('name','p','clockType','CESIUM1','seed',sd, ...
        'deterministic',false,'bias_s',0,'fracFreq',0, ...
        'noiseCoeffs',struct('h2',0,'h1',0,'h0',0,'hMinus1',HM1,'hMinus2',0)));
    q = models.clocks.ClockModel(struct('name','q','clockType','CESIUM1','seed',sd, ...
        'deterministic',false,'bias_s',0,'fracFreq',0, ...
        'noiseCoeffs',struct('h2',0,'h1',0,'h0',0,'hMinus1',HM1,'hMinus2',0)));
    p.precomputeNoise(tV2);
    q.noiseMasterSpan_s = SPAN; q.precomputeNoise(tV2);
    dOff = revgnss.AllanDeviation.compute(p.noiseBias_s_vec, tV2);
    dOn  = revgnss.AllanDeviation.compute(q.noiseBias_s_vec, tV2);
    accOff(end+1,:) = interp1(dOff.tau, dOff.sigma_y, tProbe, 'linear', NaN); %#ok<AGROW>
    accOn(end+1,:)  = interp1(dOn.tau,  dOn.sigma_y,  tProbe, 'linear', NaN); %#ok<AGROW>
end
rOff = mean(accOff,1,'omitnan') / theory;
rOn  = mean(accOn, 1,'omitnan') / theory;
fprintf('  ADEV/theory at tau = [10 60 300] s: OFF %.3f %.3f %.3f | ON %.3f %.3f %.3f\n', ...
    rOff, rOn);
assert(all(rOn > 0.85 & rOn < 1.15), ...
    ['test_clock_noise_master_span FAILED: the windowed series left the flicker floor ' ...
     '(ratios %.3f %.3f %.3f).'], rOn);

% --- 6. The config resolver --------------------------------------------
cfgOff = struct('clock', struct('noiseMasterSpan', struct('enable', false, 'span_s', SPAN)));
assert(revgnss.ScenarioFactory.clockNoiseMasterSpan(cfgOff) == 0, ...
    'test_clock_noise_master_span FAILED: a disabled gate must resolve to 0.');
assert(revgnss.ScenarioFactory.clockNoiseMasterSpan(struct()) == 0, ...
    'test_clock_noise_master_span FAILED: an absent gate must resolve to 0.');
cfgOn = cfgOff; cfgOn.clock.noiseMasterSpan.enable = true;
assert(revgnss.ScenarioFactory.clockNoiseMasterSpan(cfgOn) == SPAN, ...
    'test_clock_noise_master_span FAILED: an enabled gate must resolve to span_s.');
cfgBad = cfgOn; cfgBad.clock.noiseMasterSpan.span_s = 0;
threw = false;
try
    revgnss.ScenarioFactory.clockNoiseMasterSpan(cfgBad);
catch me
    threw = strcmp(me.identifier, 'ScenarioFactory:clockNoiseMasterSpan');
end
assert(threw, ...
    'test_clock_noise_master_span FAILED: an enabled gate with span_s <= 0 must error.');
fprintf('  config resolver off/absent/on/bad  : PASS\n');

% --- 7. END TO END (opt-in: OO_V1_CLOCK_SPAN_E2E=1) ---------------------
% The clock was the ONLY arc-length-dependent stochastic source in the simulation:
% every other stream is either identity-keyed on the absolute epoch or drawn
% sequentially one epoch at a time, and the truth orbit is a deterministic
% integration. So with the gate on the whole EKF state, not just the clock, must be
% reproducible across arc lengths. MEASURED at epoch 121: 5.34 m apart with the gate
% off, exactly 0 with it on. Four scenario builds, so it is opt-in.
if strcmp(getenv('OO_V1_CLOCK_SPAN_E2E'), '1')
    fprintf('  end-to-end (4 scenario builds) ...\n');
    % resolveSimulationConfig needs BOTH config folders, not just the repo root.
    addpath(fullfile(thisDir, '..', 'config'));
    addpath(fullfile(thisDir, '..', 'config', 'internal'));
    runTo = @(dur, kStop, gateOn) i_runTo(dur, kStop, gateOn, SPAN);
    xOffShort = runTo(120, 121, false);
    xOffLong  = runTo(600, 121, false);
    xOnShort  = runTo(120, 121, true);
    xOnLong   = runTo(600, 121, true);
    dOff = max(abs(xOffShort - xOffLong));
    dOn  = max(abs(xOnShort  - xOnLong));
    fprintf('  state at epoch 121, 120 s vs 600 s: OFF %.4g m | ON %.4g m\n', dOff, dOn);
    assert(dOff > 0, ...
        'test_clock_noise_master_span FAILED: the legacy path should differ across arcs.');
    assert(dOn == 0, ...
        ['test_clock_noise_master_span FAILED: with the gate on the whole state must be ' ...
         'arc-length independent (got %g m). A NEW arc-length-dependent stochastic ' ...
         'source has been introduced somewhere other than the clock.'], dOn);
end

fprintf('=== test_clock_noise_master_span PASS ===\n');

% ------------------------------------------------------------------------
function x = i_runTo(dur_s, kStop, gateOn, span_s)
    % One scenario built at dur_s, stepped to kStop, returning the EKF state.
    ov  = struct('simulation', struct('duration_s', dur_s));
    cfg = resolveSimulationConfig('golden_baseline.json', ov);
    cfg.report.writePdf              = false;
    cfg.report.monteCarlo.enable     = false;
    cfg.clock.noiseMasterSpan.enable = gateOn;
    cfg.clock.noiseMasterSpan.span_s = span_s;
    sim = revgnss.ReverseGNSSSimulation(cfg);
    sim.initialize();
    for k = 1:kStop; sim.step(k); end
    x = sim.ekf.x;
end
