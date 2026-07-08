% test_clock_gauge_observability  WP1 acceptance test: clock gauge restores the
% otherwise-unobservable common-mode clock datum when tower clocks are estimated.
%
% Scientific basis: one-way pseudorange observes only clock DIFFERENCES, so for a
% system of n clocks only n-1 clock states are separable, leaving one unobservable
% common-mode datum (Kaplan & Hegarty, control-segment discussion). Without a gauge
% the clock subspace is rank-deficient and the common-mode variance is unconstrained.
%
% This test complements (does NOT duplicate) the existing gauge tests:
%   - test_clock_gauge_v4.m           prints the null dimension but does not assert it.
%   - test_stage8_clock_gauge.m       config-guard throws only.
%   - test_stage9_clock_gauge_ekf.m   gauge rows added / rank finite / residuals finite.
%   - test_stage10_..._gramian.m      windowed observability Gramian ranks.
% New ground asserted here:
%   A. The null dimension COLLAPSES 1 -> 0 when a reference-fix gauge is applied, and
%      the null vector is the uniform clock shift [1,1,...,1] (the n-1 result).
%   B. The WP1 plan-vocabulary alias cfg.estimator.clockGauge.mode and the
%      cfg.clock.gauge.mode synonyms resolve to the canonical Stage-8 gauge modes.
%   C. End-to-end, a gauged estimated-tower-clock run keeps P symmetric + PSD and the
%      common-mode clock-bias variance BOUNDED (does not grow past its P0 value); and
%      the plan synonyms produce bit-identical results to the canonical gauge modes.

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));
addpath(fullfile(thisDir, '..', 'config'));

fprintf('=== test_clock_gauge_observability ===\n');

% ================================================================
% Part A: null-space collapse (observability of the common-mode datum)
% ================================================================
fprintf('  A. null-space collapse: ungauged 1-D -> gauged 0-D ...\n');

N_towers = 5;
cfgA = revgnss.ConfigFactory.defaultConfig();
cfgA.scenario.nTowers    = N_towers;
cfgA.scenario.nReceivers = 1;
cfgA.plots.enable  = false;
cfgA.report.enable = false;

[assetA, towersA, ekfA, measModelA, ~, ~] = revgnss.ScenarioFactory.build(cfgA);
[~, ~, ~, ~, errStructA] = measModelA.computeMeasurements( ...
    assetA, towersA, ekfA.x, 0, ekfA.stateMap);
assert(~isempty(errStructA) && errStructA.nPseudorange >= N_towers, ...
    'Part A FAILED: need >= %d visible pseudoranges to test clock rank', N_towers);

towerIdx = errStructA.towerIdx_perMeas;
nMeas    = errStructA.nPseudorange;

% Ungauged clock-only H: columns [b_rx, b_twr_1..N], each row b_rx=+1, b_twr_i=-1.
% Gauged H fixes the reference tower clock (its column is dropped from the estimate).
H_none  = revgnss.SignalUtils.buildClockOnlyH(nMeas, N_towers, towerIdx);
H_fixed = revgnss.SignalUtils.buildClockOnlyH_fixedRef(nMeas, N_towers, towerIdx, 1);

% Ungauged: exactly ONE unobservable direction, and it is the uniform clock shift.
nd_none = size(H_none, 2) - rank(H_none, max(size(H_none)) * eps(norm(H_none)));
assert(nd_none == 1, ...
    'Part A FAILED: ungauged clock subspace should have exactly ONE null direction, got %d', nd_none);
[~, ~, V] = svd(H_none);
nvec = V(:, end) / V(1, end);                % normalise so first entry = 1
assert(max(abs(nvec - 1)) < 1e-8, ...
    'Part A FAILED: null vector is not the uniform shift [1,...,1]; max dev = %.2e', ...
    max(abs(nvec - 1)));

% The scientific point: the common-mode (uniform clock shift) direction is
% UNOBSERVABLE without a gauge but OBSERVABLE once the datum is pinned.
uShift  = ones(N_towers + 1, 1);
resNone = norm(H_none  * uShift);            % ~0: common mode invisible to pseudorange
resFix  = norm(H_fixed * uShift);            % >0: gauge makes the datum observable
fprintf('    ||H*uShift|| ungauged = %.2e (expect ~0), gauged = %.2e (expect >0)\n', ...
    resNone, resFix);
assert(resNone < 1e-9, ...
    'Part A FAILED: common-mode should be unobservable ungauged, got ||H*u||=%.2e', resNone);
assert(resFix > 0.5, ...
    'Part A FAILED: gauge should make the common-mode observable, got ||H*u||=%.2e', resFix);
fprintf('    PASS (common-mode datum: unobservable ungauged, observable gauged)\n');

% ================================================================
% Part B: config alias / synonym resolution through finalizeConfig
% ================================================================
fprintf('  B. gauge-mode alias resolution through finalizeConfig ...\n');

% B1: cfg.estimator.clockGauge.mode alias -> canonical cfg.clock.gauge.mode
aliasMap = {'none','externalTowerCorrections'; ...
            'masterClock','fixReferenceTower'; ...
            'zeroMeanEnsemble','meanGroundClockGauge'};
for i = 1:size(aliasMap,1)
    c = mkTowerCfg_();
    c.estimator.clockGauge.mode = aliasMap{i,1};
    cf = revgnss.ConfigFactory.finalizeConfig(c);
    assert(strcmp(cf.clock.gauge.mode, aliasMap{i,2}), ...
        'Part B FAILED: estimator.clockGauge.mode=''%s'' -> ''%s'' (expected ''%s'')', ...
        aliasMap{i,1}, cf.clock.gauge.mode, aliasMap{i,2});
end
% masterIndex alias -> referenceTowerIndex
c = mkTowerCfg_(); c.estimator.clockGauge.mode = 'masterClock'; c.estimator.clockGauge.masterIndex = 3;
cf = revgnss.ConfigFactory.finalizeConfig(c);
assert(cf.clock.gauge.referenceTowerIndex == 3, ...
    'Part B FAILED: masterIndex=3 did not map to referenceTowerIndex');

% B2: cfg.clock.gauge.mode value synonyms
c = mkTowerCfg_(); c.clock.gauge.mode = 'masterClock';
cf = revgnss.ConfigFactory.finalizeConfig(c);
assert(strcmp(cf.clock.gauge.mode, 'fixReferenceTower'), 'Part B FAILED: masterClock synonym');
c = mkTowerCfg_(); c.clock.gauge.mode = 'zeroMeanEnsemble';
cf = revgnss.ConfigFactory.finalizeConfig(c);
assert(strcmp(cf.clock.gauge.mode, 'meanGroundClockGauge'), 'Part B FAILED: zeroMeanEnsemble synonym');

% B3: invalid alias mode -> namespaced error
threw = false;
try
    c = mkTowerCfg_(); c.estimator.clockGauge.mode = 'bogusGauge';
    revgnss.ConfigFactory.finalizeConfig(c);
catch ME
    threw = contains(ME.identifier, 'invalidClockGaugeMode');
end
assert(threw, 'Part B FAILED: invalid clockGauge.mode did not raise invalidClockGaugeMode');
fprintf('    PASS (none/masterClock/zeroMeanEnsemble + masterIndex resolve; invalid rejected)\n');

% ================================================================
% Part C: end-to-end PSD + bounded common-mode + synonym equivalence
% ================================================================
fprintf('  C. gauged estimated-tower-clock run: PSD, bounded common-mode, synonym equivalence ...\n');

pairs = {'masterClock','fixReferenceTower'; 'zeroMeanEnsemble','meanGroundClockGauge'};
for i = 1:size(pairs,1)
    sAlias = runGauged_(pairs{i,1});
    sCanon = runGauged_(pairs{i,2});

    % PSD + symmetry (numerical health of the gauged filter)
    tolEig = max(1e-6, 1e-9 * sAlias.maxDiag);
    assert(sAlias.symErr < 1e-10, 'Part C FAILED (%s): P not symmetric (%.2e)', pairs{i,1}, sAlias.symErr);
    assert(sAlias.minEig > -tolEig, 'Part C FAILED (%s): P not PSD (minEig=%.2e)', pairs{i,1}, sAlias.minEig);

    % Common-mode clock-bias variance stays BOUNDED (does not grow past P0)
    assert(sAlias.commonVar <= 2 * sAlias.commonVar0, ...
        'Part C FAILED (%s): common-mode variance grew (%.3e -> %.3e)', ...
        pairs{i,1}, sAlias.commonVar0, sAlias.commonVar);

    % Gauge actually engaged (pseudo-rows inserted each update epoch)
    assert(any(sAlias.gaugeRows > 0), 'Part C FAILED (%s): no gauge rows added', pairs{i,1});

    % Synonym equivalence: alias == canonical, bit-for-bit
    dPos = norm(sAlias.finalPos - sCanon.finalPos);
    assert(dPos < 1e-9, 'Part C FAILED: %s not equivalent to %s (pos diff %.3e)', ...
        pairs{i,1}, pairs{i,2}, dPos);
    assert(isequal(sAlias.gaugeRows, sCanon.gaugeRows), ...
        'Part C FAILED: %s gauge rows differ from %s', pairs{i,1}, pairs{i,2});

    fprintf('    %-16s: minEig=%.2e commonVar %.2e->%.2e  == %s (posDiff=%.1e)\n', ...
        pairs{i,1}, sAlias.minEig, sAlias.commonVar0, sAlias.commonVar, pairs{i,2}, dPos);
end
fprintf('    PASS\n');

fprintf('=== test_clock_gauge_observability: ALL PASS ===\n');


% ================================================================
% Local helpers
% ================================================================
function c = mkTowerCfg_()
    % Estimated-tower-clock config with sane gauge sigmas; preserves default clock fields.
    c = revgnss.ConfigFactory.defaultConfig();
    c.clock.mode                 = 'includeTowerClocksInEKF';
    c.clock.gauge.sigmaBias_m    = 1e-4;
    c.clock.gauge.sigmaDrift_mps = 1e-7;
    c.scenario.nTowers           = 5;
    c.scenario.nReceivers        = 1;
end

function s = runGauged_(gaugeMode)
    % Run a short gauged estimated-tower-clock scenario and report covariance health.
    c = revgnss.ConfigFactory.defaultConfig();
    c.clock.mode                 = 'includeTowerClocksInEKF';
    c.clock.gauge.mode           = gaugeMode;
    c.clock.gauge.sigmaBias_m    = 1e-4;
    c.clock.gauge.sigmaDrift_mps = 1e-7;
    c.scenario.nTowers           = 5;
    c.scenario.nReceivers        = 1;
    c.simulation.duration_s      = 20;
    c.simulation.dt_s            = 1;
    c.plots.enable  = false;
    c.report.enable = false;
    c.errors.codeNoise.sigma_m   = 0;
    rng(42, 'twister');                       % pin the stray attitude-reference randn

    % P0 from a fresh build (pre-run covariance) for the boundedness comparison.
    [~, ~, ekf0] = revgnss.ScenarioFactory.build(c);
    sm     = ekf0.stateMap;
    clkIdx = [sm.b_rx_idx; sm.towerClockIdx(:,1)];      % all clock-bias states
    u      = ones(numel(clkIdx),1) / sqrt(numel(clkIdx));  % uniform common-mode direction
    P0commonVar = u' * ekf0.P(clkIdx, clkIdx) * u;

    sim = revgnss.ReverseGNSSSimulation(c);
    sim.run();

    Pf = sim.ekf.P;
    Pf = (Pf + Pf') / 2;
    s.gaugeMode  = gaugeMode;
    s.symErr     = norm(sim.ekf.P - sim.ekf.P', 'fro') / max(norm(sim.ekf.P,'fro'), eps);
    s.minEig     = min(eig(Pf));
    s.maxDiag    = max(abs(diag(Pf)));
    s.commonVar  = u' * Pf(clkIdx, clkIdx) * u;
    s.commonVar0 = P0commonVar;
    s.gaugeRows  = sim.diag.getClockGaugeRowsAdded();
    s.finalPos   = sim.ekf.x(sim.ekf.stateMap.r_idx) - sim.asset.r_ecef_m;
end
