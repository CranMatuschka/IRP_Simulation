% test_tower_clock_all_modes_charge_wander  Phase 3: EVERY tower-clock correction mode
% must account for the oscillator's free-running wander, not just the default one.
%
% WHY THIS TEST EXISTS. The 2026-08-10 wander terms
% (TowerClockCorrectionProvider.extrapolationWanderVar_ / frequencyWanderVar_) were wired
% into ONE mode, 'truthHistoryProductNoisy', because that is what every shipped fixture
% resolves to. The other modes have the same structure -- they predict the tower clock
% forward from a product epoch -- and therefore the same error, but charged nothing for it:
%
%   truthProduct   extrapolates b_p + bd_p*age and set towerClkSigma = 0 outright
%   product        never set towerClkSigma at all
%   productNoisy   charged the product struct's own sigmas only
%   none           applies no correction, so the FULL clock bias sits in the residual
%
% The Doppler path was worse, and in a way nothing could have caught: bdot_truth was left
% at the product epoch (truthProduct) or never assigned at all (product / productNoisy /
% noisyCorrection), so the tower clock cancelled identically out of the range-rate
% residual. With DETERMINISTIC tower clocks every one of those quantities is exactly zero,
% which is why the defect survived every gate until the oscillators were switched on.
%
%   T1  compute(): truthProduct charges the wander
%   T2  compute(): product and productNoisy charge the wander
%   T3  compute(): 'none' is REJECTED with a stochastic tower clock
%   T4  computeDrift(): truth is anchored at the MEASUREMENT epoch in every mode
%   T5  a deterministic tower clock is charged nothing extra in ANY mode

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));
addpath(fullfile(thisDir, '..', 'config'));
addpath(fullfile(thisDir, '..', 'config', 'internal'));

fprintf('=== test_tower_clock_all_modes_charge_wander ===\n');

c_mps = revgnss.Constants.SPEED_OF_LIGHT_MPS;
T_S   = 64;      % measurement epoch; with latency 5 / interval 30 this gives age = 34 s

% ---------------------------------------------------------------------------
% T1: truthProduct charges the wander it creates
% ---------------------------------------------------------------------------
fprintf('  T1: truthProduct charges the oscillator wander ...\n');
cfg = i_stochasticTowerCfg('truthProduct');
[sig, age] = i_sigmaAt(cfg, T_S);
w = i_wander(cfg, age, c_mps);
assert(age > 0, 'T1 fixture wrong: age = %g', age);
assert(abs(sig - w) < 1e-9 * max(1, w), ...
    ['T1 FAILED: truthProduct charged %.6g m at age %.0f s; the oscillator wander it ' ...
     'cannot correct is %.6g m. This mode has no product noise of its own, so the ' ...
     'wander is the ENTIRE error and R must equal it.'], sig, age, w);
fprintf('    age %.0f s: wander %.4g m -> R sigma %.4g m\n', age, w, sig);

% ---------------------------------------------------------------------------
% T2: the explicit-product modes charge it on top of their own sigmas
% ---------------------------------------------------------------------------
fprintf('  T2: product / productNoisy charge the wander ...\n');
for m = {'product','productNoisy'}
    cfgP = i_stochasticTowerCfg(m{1});
    [sigP, ageP] = i_sigmaAt(cfgP, T_S);
    wP = i_wander(cfgP, ageP, c_mps);
    assert(sigP >= wP * (1 - 1e-9), ...
        ['T2 FAILED: %s charged %.6g m, which is below the %.6g m of oscillator wander ' ...
         'alone. The explicit product struct describes the PRODUCT''s uncertainty; it ' ...
         'cannot know what the oscillator did after the product epoch.'], ...
        m{1}, sigP, wP);
    fprintf('    %-13s wander %.4g m -> R sigma %.4g m\n', m{1}, wP, sigP);
end

% ---------------------------------------------------------------------------
% T3: 'none' must be rejected, not silently run with R = 0
% ---------------------------------------------------------------------------
fprintf('  T3: ''none'' is rejected for a stochastic tower clock ...\n');
threw = false;
try
    cfgN = i_stochasticTowerCfg('none');
    i_sigmaAt(cfgN, T_S);
catch me
    threw = strcmp(me.identifier, 'TowerClockCorrectionProvider:uncorrectedStochasticClock');
end
assert(threw, ...
    ['T3 FAILED: correctionMode=''none'' ran against a stochastic tower clock. The ' ...
     'residual is then the RAW clock bias, a random walk with no stationary variance, ' ...
     'so no finite R is correct. It is only a valid mode against a deterministic clock.']);

% ---------------------------------------------------------------------------
% T4: the Doppler truth is the drift at the MEASUREMENT epoch, in every mode
% ---------------------------------------------------------------------------
fprintf('  T4: Doppler truth is anchored at t_s in every mode ...\n');
% 'perfectCorrection' was omitted here until 2026-08-10, which is exactly why its
% computeDrift regression (product-epoch-anchored MODEL *and* TRUTH, drift_sigma=0)
% went undetected: the mode this test exists to police was never asked about.
for m = {'truthProduct','product','productNoisy','noisyCorrection','truthHistoryProductNoisy','perfectCorrection'}
    cfgD = i_stochasticTowerCfg(m{1});
    towers = i_buildTowers(cfgD, T_S);
    bdotAtTs = towers{1}.getClockDriftMetersPerSecond();
    [bdot_truth, ~, ~] = models.clocks.TowerClockCorrectionProvider.computeDrift( ...
        cfgD, towers, 1, T_S);
    assert(abs(bdot_truth(1) - bdotAtTs) < 1e-12 * max(1, abs(bdotAtTs)), ...
        ['T4 FAILED for %s: computeDrift reported bdot_truth = %.6g m/s but the tower ' ...
         'oscillator''s drift at t_s is %.6g m/s. A range-rate observable at t_s depends ' ...
         'on the fractional frequency AT t_s; a stale or zero truth makes the tower clock ' ...
         'cancel out of the residual entirely.'], m{1}, bdot_truth(1), bdotAtTs);
    fprintf('    %-26s bdot_truth = %+.4e m/s\n', m{1}, bdot_truth(1));
end
assert(abs(bdotAtTs) > 0, ...
    'T4 would pass vacuously: the fixture''s tower drift at t_s is exactly zero.');

% ---------------------------------------------------------------------------
% T5: a DETERMINISTIC tower clock is charged nothing extra, in any mode
% ---------------------------------------------------------------------------
fprintf('  T5: deterministic tower clocks are unaffected in every mode ...\n');
for m = {'truthProduct','product','productNoisy','truthHistoryProductNoisy','none'}
    cfgDet = i_stochasticTowerCfg(m{1});
    for k = 1:numel(cfgDet.towers); cfgDet.towers(k).clock.deterministic = true; end
    [sigDet, ageDet] = i_sigmaAt(cfgDet, T_S);
    wDet = i_wander(cfgDet, ageDet, c_mps);
    assert(wDet == 0, ...
        'T5 FAILED for %s: a deterministic clock reported %.6g m of wander', m{1}, wDet);
    assert(isfinite(sigDet), 'T5 FAILED for %s: R sigma is not finite', m{1});
end
fprintf('    all modes: wander term is identically zero when deterministic\n');

% ---------------------------------------------------------------------------
% T6: 'none' gates on SILENCE, not on the deterministic flag
% ---------------------------------------------------------------------------
% T3 asserts the guard fires; this asserts it fires for the right reason. The first
% version tested ~clock.deterministic alone, which conflates two different routes to a
% zero bias: the flag SUPPRESSES the draws, while clockType='ZERO' has no noise to draw
% (every h coefficient is zero). So ZERO with deterministic=false is provably silent --
% measured, its bias moves 0 m over 64 s where CESIUM1 moves 0.133 m -- and was refused
% anyway, by an error message that recommends clockType 'ZERO' as the remedy.
% The converse hole is a clock the flag does NOT silence: driftRate_fracPerSec is a
% DETERMINISTIC ramp, unsuppressed by the flag and just as uncovered by a finite R as a
% random walk. No shipped fixture sets it, so it never showed up as a failure.
fprintf('  T6: ''none'' gates on silence, not on the deterministic flag ...\n');
silenceCases = { ...
    'ZERO',    false, 0,     true,  'ZERO has no noise to draw; the flag is irrelevant'; ...
    'ZERO',    true,  0,     true,  'silent by both routes at once'; ...
    'CESIUM1', false, 0,     false, 'genuinely stochastic'; ...
    'CESIUM1', true,  0,     true,  'flag suppresses the draws'; ...
    'ZERO',    true,  1e-14, false, 'deterministic ramp the flag does not suppress'};
for i = 1:size(silenceCases, 1)
    [tc, det, drift, wantAccept, why] = silenceCases{i,:};
    cfgS = i_stochasticTowerCfg('none', tc, det);
    if drift ~= 0
        % driftRate_fracPerSec IS a genuine ClockModel field, copied at construction,
        % so unlike clockType this post-resolution assignment does reach the physics.
        for k = 1:numel(cfgS.towers)
            cfgS.towers(k).clock.driftRate_fracPerSec = drift;
        end
    end
    accepted = true;
    try
        i_sigmaAt(cfgS, T_S);
    catch me
        if ~strcmp(me.identifier, 'TowerClockCorrectionProvider:uncorrectedStochasticClock')
            rethrow(me);
        end
        accepted = false;
    end
    assert(accepted == wantAccept, ...
        ['T6 FAILED: %s with deterministic=%d, drift=%g was %s by the ''none'' guard, ' ...
         'but it is %s (%s). The guard must test whether the clock bias is identically ' ...
         'zero for all time, not whether one suppression flag happens to be set.'], ...
        tc, det, drift, i_verb(accepted), i_verb(wantAccept), why);
    fprintf('    %-8s det=%d drift=%-6g -> %-8s  (%s)\n', ...
        tc, det, drift, i_verb(accepted), why);
end

% The escape hatch must survive the config system, not just direct struct assignment.
% It was previously read through a try/catch on a field masterConfig never declared, so
% the remedy the error message names was rejected with deepMergeConfig:unknownConfigPath.
cfgOpt = i_stochasticTowerCfg('none');
cfgOpt.towerClock.allowUncorrectedStochasticClock = true;
[sigOpt, ~] = i_sigmaAt(cfgOpt, T_S);
assert(isfinite(sigOpt), 'T6 FAILED: the documented escape hatch did not admit the run.');
assert(isfield(masterConfig().towerClock, 'allowUncorrectedStochasticClock'), ...
    ['T6 FAILED: allowUncorrectedStochasticClock is not declared in masterConfig, so ' ...
     'the escape hatch the error message recommends cannot be set through a scenario ' ...
     'JSON or an overrides struct -- deepMergeConfig rejects it as an unknown path.']);
fprintf('    escape hatch is declared in masterConfig and admits the run\n');

fprintf('=== test_tower_clock_all_modes_charge_wander PASSED ===\n');

function v = i_verb(accepted)
    if accepted; v = 'ACCEPT'; else; v = 'REFUSE'; end
end

% ===========================================================================
function cfg = i_stochasticTowerCfg(mode, clockType, deterministic)
    % Golden-baseline error model, stochastic OCXO2 towers, one correction mode selected.
    % Explicit product structs are supplied so 'product'/'productNoisy' are reachable.
    %
    % The oscillator is selected through the RESOLVER, not by assigning clockType on the
    % returned cfg. ClockModel copies cfg.noiseCoeffs verbatim and treats clockType as a
    % label, so a post-resolution assignment renames the clock and leaves its h
    % coefficients untouched -- the fixture would then test a caesium clock wearing a
    % 'ZERO' nameplate.
    if nargin < 2 || isempty(clockType);     clockType     = 'OCXO2'; end
    if nargin < 3 || isempty(deterministic); deterministic = false;   end
    ov = struct(); ov.plots.enable = false; ov.report.enable = false;
    ov.clock.tower.clockType = clockType;
    ov.clock.tower.deterministic = deterministic;
    cfg = resolveSimulationConfig('golden_baseline.json', ov);
    cfg.towerClock.correctionMode        = mode;
    cfg.towerClock.productValidityPolicy = 'warn';
    cfg.estimator.towerClockMode         = mode;
    for k = 1:numel(cfg.towers)
        cfg.towerClock.products(k).bias_m         = 0.0;
        cfg.towerClock.products(k).drift_mps      = 0.0;
        cfg.towerClock.products(k).epoch_s        = 30.0;
        cfg.towerClock.products(k).sigmaBias_m    = 0.1;
        cfg.towerClock.products(k).sigmaDrift_mps = 1e-4;
        cfg.towerClock.products(k).covBiasDrift   = 0.0;
        cfg.towerClock.products(k).validity_s     = 600;
    end
end

function towers = i_buildTowers(cfg, t_s)
    towers = cell(numel(cfg.towers), 1);
    for k = 1:numel(cfg.towers)
        towers{k} = revgnss.GroundTower(cfg.towers(k));
        towers{k}.clock.precomputeNoise(0:1:max(t_s, 1));
    end
    for i = 1:t_s
        for k = 1:numel(towers); towers{k}.stepClock(1.0); end
    end
end

function [sig, age] = i_sigmaAt(cfg, t_s)
    towers = i_buildTowers(cfg, t_s);
    [~, ~, towerClkSigma, ~, t_prod] = ...
        models.clocks.TowerClockCorrectionProvider.compute(cfg, [], towers, 1, t_s);
    sig = towerClkSigma(1);
    age = t_s - t_prod;
end

function w = i_wander(cfg, age, c_mps)
    clk = models.clocks.ClockModel(cfg.towers(1).clock);
    if clk.deterministic || age <= 0; w = 0; return; end
    [~, adev] = clk.theoreticalAllanDeviation(age);
    w = c_mps * adev * age;
end
