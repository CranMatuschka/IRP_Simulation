function test_rng_seed_independence()
%TEST_RNG_SEED_INDEPENDENCE  Guarantees for the identity-keyed RNG refactor.
%
% Verifies the properties that motivate models.noise.RngRegistry and the
% cfg.rng.independentStreams path:
%   A. ErrorChain order-independence: a tower's noise realization is a pure
%      function of its identity, invariant to its position in the visible list
%      (ON). The legacy shared-stream path (OFF) is order-DEPENDENT, which this
%      test also demonstrates so the ON guarantee is not vacuous.
%   B. RngRegistry: same key -> identical stream; different keys -> independent;
%      persistentStream advances across calls (GM continuity); epochStream is a
%      pure function of (identity, epoch).
%   C. Secondary space-asset clocks receive distinct seeds (300+ai), fixing the
%      latent bug where every swarm clock cloned the primary's seed (100).
%
% The finalizeConfig duplicate-clock-seed guard is exercised (non-false-firing)
% by the preset sweep in the validation campaign; it is defensive against future
% changes to the seed scheme and is not unit-tested here.
%
% Run: test_rng_seed_independence   (errors on any failure)

    thisDir = fileparts(mfilename('fullpath'));
    root    = fullfile(thisDir, '..');
    addpath(root); addpath(fullfile(root,'config'));

    fprintf('== test_rng_seed_independence ==\n');
    tol = 1e-14;

    % ---- A. ErrorChain order-independence (ON) vs order-dependence (OFF) ----
    cfg0 = revgnss.ConfigFactory.finalizeConfig(masterConfig());
    elev = [0.5; 0.6; 0.7];
    tid  = [1; 2; 3];
    ant  = [1; 1; 1];
    perm = [2 1 3];                 % moves tower 2 from position 2 -> position 1

    cfgOn = cfg0; cfgOn.rng.independentStreams.enable = true;
    eA = models.errors.ErrorChain(cfgOn, cfgOn.simulation.seed);
    rA = eA.compute(elev, tid, tid, 0, ant);
    eB = models.errors.ErrorChain(cfgOn, cfgOn.simulation.seed);
    rB = eB.compute(elev(perm), tid(perm), tid(perm), 0, ant);
    dOn = abs(rA.bySource.truth_m.code(tid==2) - rB.bySource.truth_m.code(tid(perm)==2));
    assert(dOn < tol, 'ON path must be order-independent (tower2 code dz=%.3e)', dOn);

    cfgOff = cfg0; cfgOff.rng.independentStreams.enable = false;
    oA = models.errors.ErrorChain(cfgOff, cfgOff.simulation.seed);
    qA = oA.compute(elev, tid, tid, 0, ant);
    oB = models.errors.ErrorChain(cfgOff, cfgOff.simulation.seed);
    qB = oB.compute(elev(perm), tid(perm), tid(perm), 0, ant);
    dOff = abs(qA.bySource.truth_m.code(tid==2) - qB.bySource.truth_m.code(tid(perm)==2));
    assert(dOff > 1e-6, ...
        'Legacy path should be order-dependent so the ON guarantee is non-vacuous (dz=%.3e)', dOff);
    fprintf('  [A] order-independence: ON dz=%.2e (invariant), OFF dz=%.2e (order-dependent)  PASS\n', dOn, dOff);

    % ---- B. RngRegistry guarantees ----
    reg1 = models.noise.RngRegistry(42, 'threefry');
    reg2 = models.noise.RngRegistry(42, 'threefry');
    src  = models.noise.RngSource.IONO_RESID;
    a1 = randn(reg1.epochStream(src, 5, 0, 0, 7), 4, 1);
    a2 = randn(reg2.epochStream(src, 5, 0, 0, 7), 4, 1);   % same key, fresh registry
    b  = randn(reg2.epochStream(src, 6, 0, 0, 7), 4, 1);   % different node
    c  = randn(reg2.epochStream(src, 5, 0, 0, 8), 4, 1);   % different epoch
    assert(isequal(a1, a2), 'epochStream must be a pure function of identity+epoch');
    assert(~isequal(a1, b), 'different node must give independent stream');
    assert(~isequal(a1, c), 'different epoch must give independent stream');
    % persistentStream advances across calls (continuity), replayable across registries
    reg3 = models.noise.RngRegistry(42, 'threefry');
    p1 = randn(reg1.persistentStream(models.noise.RngSource.MP_GM, 2, 1), 1, 1);
    p2 = randn(reg1.persistentStream(models.noise.RngSource.MP_GM, 2, 1), 1, 1);
    q1 = randn(reg3.persistentStream(models.noise.RngSource.MP_GM, 2, 1), 1, 1);
    q2 = randn(reg3.persistentStream(models.noise.RngSource.MP_GM, 2, 1), 1, 1);
    assert(p1 ~= p2, 'persistentStream must advance across calls (GM continuity)');
    assert(isequal([p1 p2], [q1 q2]), 'persistentStream must be replayable for a fixed seed');
    fprintf('  [B] registry determinism/independence/continuity  PASS\n');

    % ---- C. Secondary space-asset clock seeds are distinct ----
    cfgMA = masterConfig(); cfgMA.scenario.nSpaceAssets = 3;
    cfgMA = revgnss.ConfigFactory.finalizeConfig(cfgMA);
    seeds = arrayfun(@(a) a.clock.seed, cfgMA.assets);
    assert(numel(unique(seeds)) == numel(seeds), ...
        'Secondary asset clock seeds must be distinct; got [%s]', num2str(seeds));
    assert(seeds(1) == 100, 'primary receiver clock seed must be 100');
    assert(all(seeds(2:end) == 300 + (2:numel(seeds))), 'secondary seeds must be 300+ai');
    fprintf('  [C] secondary clock seeds distinct: [%s]  PASS\n', num2str(seeds));

    fprintf('== ALL PASS ==\n');
end
