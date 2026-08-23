% test_tower_clock_product_age_wander_in_R
%
% THE DEFECT THIS PINS: the broadcast-product sigma added to R charged only the product's
% OWN error -- sigmaBias_m (its estimate error at its own epoch) and age^2*sigmaDrift_mps^2
% (the uncertainty of its drift term). It never charged the tower oscillator's free-running
% wander between the product epoch and the measurement, because until 2026-08-09 the tower
% clocks were deterministic and there was no wander to charge for.
%
% With the oscillators switched on (cfg.clock.tower.deterministic = false) that omission is
% not academic: on jowTable2p1 the OCXO wanders ~2.5 m over a full 34 s product age against
% a 0.106 m product sigma, i.e. R optimistic by ~24x -- a filter-consistency defect strictly
% worse than the provenance problem the flip was meant to fix.
%
% NOTE ON AGE: the correction age is NOT latency+updateInterval. compute() quantises the
% product epoch to t_prod = floor((t_s-latency)/dT)*dT and uses age = t_s - t_prod, so the
% age SAWTOOTHS from latency (just after a new product) up to latency+dT-1 (just before the
% next). Every expectation below derives the age from that same formula rather than assuming
% the worst case -- getting this wrong is what made the first draft of this test fail.
%
%   T1  the wander term is present and correctly sized for a STOCHASTIC tower clock
%   T2  it is EXACTLY zero for a deterministic tower clock (old fixtures byte-identical)
%   T3  it scales with the oscillator class -- a TCXO is charged more than a caesium
%   T4  it grows with the product age (a staler correction is trusted less)

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));
addpath(fullfile(thisDir, '..', 'config'));
addpath(fullfile(thisDir, '..', 'config', 'internal'));

fprintf('=== test_tower_clock_product_age_wander_in_R ===\n');

c_mps = revgnss.Constants.SPEED_OF_LIGHT_MPS;

ov = struct(); ov.plots.enable = false; ov.report.enable = false;
cfgBase = resolveSimulationConfig('golden_baseline.json', ov);
p       = cfgBase.clocks.tower.product;

% Freshest and stalest points of one product cycle (see NOTE ON AGE above).
tFresh = p.updateInterval_s + p.latency_s;          % age == latency
tStale = p.updateInterval_s + p.latency_s - 1;      % age == latency + dT - 1

% ---------------------------------------------------------------------------
% T1: stochastic tower clock -> the wander term is present and correctly sized
% ---------------------------------------------------------------------------
fprintf('  T1: stochastic tower clock charges its wander to R ...\n');
o = ov; o.clock.tower.clockType = 'OCXO'; o.clock.tower.deterministic = false;
cfgS = resolveSimulationConfig('golden_baseline.json', o);
assert(strcmp(cfgS.estimator.towerClockMode, 'truthHistoryProductNoisy'), ...
    'T1 fixture wrong: towerClockMode=%s, this test only covers truthHistoryProductNoisy', ...
    cfgS.estimator.towerClockMode);

[sigS, ageS]      = i_sigmaAt(cfgS, tStale);
[expS, prodS, wS] = i_expected(cfgS, p, ageS, c_mps);

assert(abs(sigS - expS) < 1e-9 * max(1, expS), ...
    ['T1 FAILED: at age %.0f s, R sigma = %.6g m, expected ' ...
     'sqrt(product^2 + wander^2) = %.6g m (product %.4g m, wander %.4g m)'], ...
    ageS, sigS, expS, prodS, wS);
assert(wS / prodS > 10, ...
    ['T1 FAILED: the fixture no longer exhibits the defect -- wander %.4g m is not ' ...
     'dominant over the product sigma %.4g m, so this test would pass vacuously'], ...
    wS, prodS);
fprintf('    age %.0f s:  product %.4g m  +  wander %.4g m  ->  R sigma %.4g m (%.1fx)\n', ...
    ageS, prodS, wS, sigS, sigS / prodS);

% ---------------------------------------------------------------------------
% T2: deterministic tower clock -> EXACTLY the old formula, no drift in old fixtures
% ---------------------------------------------------------------------------
fprintf('  T2: deterministic tower clock is charged nothing extra ...\n');
o = ov; o.clock.tower.clockType = 'OCXO'; o.clock.tower.deterministic = true;
cfgD = resolveSimulationConfig('golden_baseline.json', o);
[sigD, ageD] = i_sigmaAt(cfgD, tStale);
prodD = sqrt(p.sigmaBias_m^2 + ageD^2 * p.sigmaDrift_mps^2 + 2 * ageD * p.covBiasDrift);
assert(abs(sigD - prodD) < 1e-12 * max(1, prodD), ...
    ['T2 FAILED: a DETERMINISTIC tower clock changed R from %.12g to %.12g m. ' ...
     'The wander term must be identically zero there or every deterministic-tower ' ...
     'golden shifts for no physical reason.'], prodD, sigD);
fprintf('    deterministic R sigma %.6g m == product-only %.6g m\n', sigD, prodD);

% ---------------------------------------------------------------------------
% T3: the charge tracks the oscillator class
% ---------------------------------------------------------------------------
fprintf('  T3: EVERY registered oscillator is charged its own wander ...\n');
% Derived from the catalogue, not a hardcoded list, so a class added to
% ConfigFactory.oscillatorCatalog_ -- or a CUSTOM one supplied through
% cfg.clock.customOscillators -- is covered by this gate the moment it exists.
allNames = fieldnames(revgnss.ConfigFactory.oscillatorCatalog_())';
allNames = allNames(~strcmp(allNames,'ZERO'));      % no wander to charge
sigByType = struct();
for ni = 1:numel(allNames)
    tt = allNames{ni};
    o = ov; o.clock.tower.clockType = tt; o.clock.tower.deterministic = false;
    cfgT = resolveSimulationConfig('golden_baseline.json', o);
    [sg, ageT]  = i_sigmaAt(cfgT, tStale);
    [ex, ~, wr] = i_expected(cfgT, p, ageT, c_mps);
    sigByType.(tt) = sg;
    assert(abs(sg - ex) < 1e-9 * max(1, ex), ...
        'T3 FAILED: %s charged %.6g m, expected %.6g m', tt, sg, ex);
    fprintf('    %-10s wander %10.4g m  ->  R sigma %10.4g m\n', tt, wr, sg);
end
% A CUSTOM oscillator must be charged too -- otherwise "add a clock as data" would ship a
% clock the covariance silently ignores.
oc = ov;
oc.clock.customOscillators.PROBEOSC = struct('h0',1e-20,'hMinus1',1e-23,'hMinus2',1e-26);
oc.clock.tower.clockType = 'PROBEOSC'; oc.clock.tower.deterministic = false;
cfgC = resolveSimulationConfig('golden_baseline.json', oc);
[sgC, ageC]   = i_sigmaAt(cfgC, tStale);
[exC, prC, ~] = i_expected(cfgC, p, ageC, c_mps);
assert(abs(sgC - exC) < 1e-9 * max(1, exC), ...
    'T3 FAILED: a CUSTOM oscillator was charged %.6g m, expected %.6g m', sgC, exC);
assert(sgC > prC, ...
    'T3 FAILED: a custom oscillator added nothing to R over the bare product sigma');
fprintf('    %-10s (custom) R sigma %10.4g m\n', 'PROBEOSC', sgC);
% Expected ordering at a ~34 s correction age on jowTable2p1:
%     TCXO  >  OCXO  >  CESIUM1  >  RUBIDIUM
% The last pair is deliberately NOT "caesium is best". At this age the charge is white-FM
% dominated (sigma_y = sqrt(h0/2tau)), and JOW's caesium beam carries h0 = 1e-19 against
% rubidium's 1e-22 -- so the beam tube is ~30x noisier over half a minute even though it
% wins by orders of magnitude at long tau. That is the real short-term behaviour of a
% caesium standard, and it is the mechanism behind the ground-clock sweep finding that
% caesium is the WORSE ground oscillator: the broadcast product re-anchors every 30 s, so
% the ground segment only ever samples the short-tau end of the Allan curve where the beam
% tube is at its weakest. Anyone re-deriving that ranking from long-tau intuition will get
% it backwards; this assertion is here to stop that.
assert(sigByType.TCXO > sigByType.OCXO2, ...
    'T3 FAILED: TCXO (%.4g) is not charged more than OCXO2 (%.4g)', ...
    sigByType.TCXO, sigByType.OCXO2);
assert(sigByType.OCXO2 > sigByType.CESIUM1, ...
    'T3 FAILED: OCXO2 (%.4g) is not charged more than caesium (%.4g)', ...
    sigByType.OCXO2, sigByType.CESIUM1);
assert(sigByType.CESIUM1 > sigByType.RUBIDIUM1, ...
    ['T3 FAILED: caesium (%.4g) is not charged more than rubidium (%.4g) at this ' ...
     'correction age. If the table changed so that caesium now wins at short tau, ' ...
     'the ground-clock sweep ranking must be re-derived, not just re-run.'], ...
    sigByType.CESIUM1, sigByType.RUBIDIUM1);

% ---------------------------------------------------------------------------
% T4: a staler correction is trusted less
% ---------------------------------------------------------------------------
fprintf('  T4: R grows with correction age ...\n');
[sFresh, aFresh] = i_sigmaAt(cfgS, tFresh);
[sStale, aStale] = i_sigmaAt(cfgS, tStale);
assert(aStale > aFresh, ...
    'T4 fixture wrong: age did not increase (%.0f -> %.0f s)', aFresh, aStale);
assert(sStale > sFresh, ...
    ['T4 FAILED: R sigma did not grow with correction age (%.6g m at age %.0f s, ' ...
     '%.6g m at age %.0f s). The product-age growth is the whole point of the term.'], ...
    sFresh, aFresh, sStale, aStale);
fprintf('    age %.0f s -> %.4g m   |   age %.0f s -> %.4g m\n', ...
    aFresh, sFresh, aStale, sStale);

% ---------------------------------------------------------------------------
% T5: the approximation the whole R term rests on is MEASURED, not assumed
% ---------------------------------------------------------------------------
% extrapolationWanderVar_ sizes the charge as (c * sigma_y(age) * age)^2, i.e. it uses
% x_rms(tau) ~ sigma_y(tau)*tau. That is a standard engineering approximation, exact only
% up to an O(1) factor that depends on WHICH noise type dominates -- so on a clock with an
% unusual h-profile it could be wrong in either direction. This subtest measures it against
% the truth generator's own linear-prediction residual, which is exactly the quantity the
% broadcast product fails to correct:
%       err = b(t0+age) - [ b(t0) + bdot(t0)*age ]
% Ratio measured/theoretical is printed per class so the approximation quality is a
% recorded number rather than a claim. The band is deliberately wide (0.4 .. 2.5): this
% gate exists to catch an approximation that is WRONG, not one that is imprecise.
fprintf('  T5: theoretical wander vs the truth generator''s own residual ...\n');
nSeed = 24; age5 = 30; N5 = 400; t0i = 200;   % settle before sampling the residual
fprintf('    %-11s %12s %12s %8s\n','oscillator','theory [m]','measured [m]','ratio');
for ni = 1:numel(allNames)
    tt = allNames{ni};
    err = zeros(1,nSeed);
    for r = 1:nSeed
        cc = revgnss.ConfigFactory.makeClockConfig(tt, 31000+911*r, struct(), ...
                struct('globalBiasFactor',1,'globalFreqFactor',1,'globalNoiseFactor',1));
        cc.deterministic = false; cc.bias_s = 0; cc.fracFreq = 0;
        clk = models.clocks.ClockModel(cc);
        clk.precomputeNoise((0:N5-1)'*1.0);
        b = zeros(1,N5); d = zeros(1,N5);
        for i = 2:N5
            clk.step(1.0); b(i) = clk.getBiasMeters(); d(i) = clk.getDriftMetersPerSecond();
        end
        err(r) = b(t0i+age5) - (b(t0i) + d(t0i)*age5);
    end
    measured = std(err);
    clkRef = models.clocks.ClockModel(revgnss.ConfigFactory.makeClockConfig(tt, 1, struct(), ...
                struct('globalBiasFactor',1,'globalFreqFactor',1,'globalNoiseFactor',1)));
    [~, ad5] = clkRef.theoreticalAllanDeviation(age5);
    theory = c_mps * ad5 * age5;
    ratio  = measured / theory;
    fprintf('    %-11s %12.4g %12.4g %8.3f\n', tt, theory, measured, ratio);
    assert(ratio > 0.4 && ratio < 2.5, ...
        ['T5 FAILED for %s: the truth generator''s linear-prediction residual is %.4g m ' ...
         'against a theoretical %.4g m (ratio %.3f). x_rms(tau) ~ sigma_y(tau)*tau does ' ...
         'not hold for this h-profile, so extrapolationWanderVar_ is charging R the wrong ' ...
         'amount for it.'], tt, measured, theory, ratio);
end

% ---------------------------------------------------------------------------
% T6: the FREQUENCY charge is measured too, and it is NOT the Allan deviation
% ---------------------------------------------------------------------------
% frequencyWanderVar_ charges Var(y(t+age) - y(t)), the excursion of the INSTANTANEOUS
% fractional frequency. That is not sigma_y(age): the Allan variance is defined on
% adjacent tau-AVERAGES. Two consequences, both measured here:
%
%   1. For random-walk FM  Var(Delta y) = 2*pi^2*h_-2*tau  while
%      Asigma_y^2(tau) = (2*pi^2/3)*h_-2*tau -- a factor 3, sqrt(3) = 1.732 in sigma.
%      MEASURED against the generator before the fix: OCXO2 1.81/1.75, TCXO 1.83/1.78,
%      QUARTZ 1.72/1.81. R was optimistic by 3x in variance on the crystals, which is
%      what the ground segment actually uses.
%   2. The h0/(2*tau) white-FM term does not belong at all -- ClockModel.step applies h0
%      as a PHASE jump, never to the frequency state -- and including it over-charged the
%      atomic classes ~37x (CESIUM1 measured 0.017 of the charge).
%
% The flicker coefficient (16*ln2) is CALIBRATED, not derived: flicker FM has no
% stationary variance so Var(Delta y) has no clean closed form. This subtest is what
% makes that honest -- it holds the calibration to the generator across every class.
fprintf('  T6: frequency-wander charge vs the generator''s own excursion ...\n');
nSeed6 = 24; N6 = 400; t06 = 200;
fprintf('    %-11s %5s %12s %12s %8s\n','oscillator','age','charge[m/s]','measured','ratio');
for ni = 1:numel(allNames)
    tt = allNames{ni};
    for age6 = [15 30]
        d6 = zeros(1,nSeed6);
        for r = 1:nSeed6
            cc = revgnss.ConfigFactory.makeClockConfig(tt, 61000+523*r, struct(), ...
                    struct('globalBiasFactor',1,'globalFreqFactor',1,'globalNoiseFactor',1));
            cc.deterministic = false; cc.bias_s = 0; cc.fracFreq = 0;
            clk6 = models.clocks.ClockModel(cc);
            clk6.precomputeNoise((0:N6-1)'*1.0);
            y6 = zeros(1,N6);
            for i = 2:N6
                clk6.step(1.0); y6(i) = clk6.getDriftMetersPerSecond();
            end
            d6(r) = y6(t06+age6) - y6(t06);
        end
        measured6 = std(d6);
        h6 = cc.noiseCoeffs;
        charge6 = c_mps * sqrt(2*pi^2*h6.hMinus2*age6 + 16*log(2)*h6.hMinus1);
        ratio6  = measured6 / max(charge6, realmin);
        fprintf('    %-11s %5g %12.4g %12.4g %8.3f\n', tt, age6, charge6, measured6, ratio6);
        assert(ratio6 > 0.5 && ratio6 < 2.0, ...
            ['T6 FAILED for %s at age %g s: the generator''s frequency excursion is ' ...
             '%.4g m/s against a charge of %.4g m/s (ratio %.3f). frequencyWanderVar_ ' ...
             'is charging the Doppler rows the wrong amount for this h-profile.'], ...
            tt, age6, measured6, charge6, ratio6);
    end
end

fprintf('=== test_tower_clock_product_age_wander_in_R PASSED ===\n');

% ===========================================================================
function [sig, age] = i_sigmaAt(cfg, t_s)
    % Build towers from cfg, step them to t_s, and return the R sigma compute() hands back,
    % plus the correction age it actually used.
    % errorChain is [] deliberately: it is consumed only by the 'noisyCorrection' branch,
    % which this fixture never takes.
    towers = cell(numel(cfg.towers), 1);
    for k = 1:numel(cfg.towers)
        towers{k} = revgnss.GroundTower(cfg.towers(k));
        towers{k}.clock.precomputeNoise(0:1:max(t_s, 1));
    end
    for i = 1:t_s
        for k = 1:numel(towers); towers{k}.stepClock(1.0); end
    end
    [~, ~, towerClkSigma, ~, t_prod] = models.clocks.TowerClockCorrectionProvider.compute( ...
        cfg, [], towers, 1, t_s);
    sig = towerClkSigma(1);
    age = t_s - t_prod;
end

function [expSigma, prodSigma, wander] = i_expected(cfg, p, age, c_mps)
    % Independent re-derivation of what R should be, from the config alone.
    prodSigma = sqrt(p.sigmaBias_m^2 + age^2 * p.sigmaDrift_mps^2 + 2 * age * p.covBiasDrift);
    clkRef    = models.clocks.ClockModel(cfg.towers(1).clock);
    [~, adev] = clkRef.theoreticalAllanDeviation(age);
    wander    = c_mps * adev * age;
    expSigma  = sqrt(prodSigma^2 + wander^2);
end
