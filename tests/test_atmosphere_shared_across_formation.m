function test_atmosphere_shared_across_formation()
%TEST_ATMOSPHERE_SHARED_ACROSS_FORMATION  Gated per-tower atmosphere shared by the swarm.
%
% Covers cfg.atmosphere.sharedAcrossFormation.enable (default FALSE).
%
% The artefact it fixes: every asset builds its own models.errors.ErrorChain ->
% models.errors.EnvironmentModel -> models.noise.RngRegistry rooted at that asset's
% cfg.simulation.seed (offset per asset by ReportRunner's federated fan-out, and the
% RngRegistry substream key has no asset field). Two satellites 2 km apart at GEO
% therefore draw INDEPENDENT troposphere / ionosphere / scintillation, even though
% their 11 arcsec ray divergence puts them deep inside the decorrelation scale of
% both layers. The between-satellite single difference then carries metres of
% atmosphere instead of the ~mm the geometry justifies.
%
% Cases:
%   A. Gate OFF (default): two differently-seeded assets get DIFFERENT atmosphere
%      states, and their differenced ground observable carries that difference.
%      (Keeps every ON assertion below non-vacuous.)
%   B. Gate ON: all four stochastic states (tropo wet GM, iono TEC GM, scintillation
%      amplitude GM, phase-scintillation GM) are byte-identical across assets, and the
%      differenced truth atmosphere cancels EXACTLY.
%   C. Gate ON: epoch anchoring -- an asset that SKIPS epochs (no visible towers ->
%      MeasurementModel returns before ErrorChain.compute) still lands on the same
%      state as one that stepped every epoch.
%   D. Gate ON is independent of cfg.rng.independentStreams, and shares ONLY the
%      atmosphere: per-asset receiver code noise stays independent.
%   E. Golden safety: gate OFF is byte-identical to a config that has never heard of
%      the field, and distinct TOWERS keep independent atmospheres either way.
%   F. Gate ON shares the per-measurement scintillation truth draw as well as the
%      states (it is the term that dominates the differenced budget).
%
% Run: test_atmosphere_shared_across_formation   (errors on any failure)

    thisDir = fileparts(mfilename('fullpath'));
    root    = fullfile(thisDir, '..');
    addpath(root); addpath(fullfile(root,'config'));

    fprintf('== test_atmosphere_shared_across_formation ==\n');

    tol   = 1e-14;
    nT    = 3;
    dt    = 1.0;
    nEp   = 40;
    elev  = [0.30; 0.55; 0.80];
    tid   = (1:nT)';
    ant   = ones(nT,1);

    % Two swarm members exactly as the federated fan-out seeds them
    % (ReportRunner.assetConfigForIndex_: baseSeed + 100000*(ai-1)).
    seedA = 42;
    seedB = 42 + 100000;

    % Ask for the stochastic atmosphere EXPLICITLY rather than relying on the default.
    % cfg.atmosphere.realistic shipped as true when this test was written and is false at
    % HEAD, which made the assert below fire on a config drift rather than a real defect.
    raw_ = masterConfig();
    raw_.atmosphere.realistic = true;
    base = revgnss.ConfigFactory.finalizeConfig(raw_);
    base.scenario.nTowers  = nT;
    base.simulation.dt_s   = dt;
    assert(strcmp(base.errors.troposphere.modelType,'localWeatherGM') && ...
           strcmp(base.errors.ionosphere.modelType,'tecGaussMarkov'), ...
        ['This test needs the stochastic atmosphere (cfg.atmosphere.realistic=true -> ' ...
         'localWeatherGM + tecGaussMarkov); got trop=%s iono=%s.'], ...
        base.errors.troposphere.modelType, base.errors.ionosphere.modelType);
    assert(base.errors.ionosphere.scintillation.enable, 'This test needs scintillation on.');

    cfgOff = base; cfgOff.atmosphere.sharedAcrossFormation.enable = false;
    cfgOn  = base; cfgOn.atmosphere.sharedAcrossFormation.enable  = true;

    % ---- A. Gate OFF: assets draw INDEPENDENT atmospheres (the artefact) ----
    [offA, dOffA] = i_runChain(cfgOff, seedA, elev, tid, ant, dt, nEp, []);
    [offB, dOffB] = i_runChain(cfgOff, seedB, elev, tid, ant, dt, nEp, []);

    dTropOff  = max(abs(offA.trop  - offB.trop));
    dIonoOff  = max(abs(offA.iono  - offB.iono));
    dScintOff = abs(offA.scint - offB.scint);
    dPhOff    = max(abs(offA.phase - offB.phase));
    assert(dTropOff  > 1e-3, 'OFF path should give independent tropo (d=%.3e m)',  dTropOff);
    assert(dIonoOff  > 1e-3, 'OFF path should give independent iono (d=%.3e m)',   dIonoOff);
    assert(dScintOff > 1e-6, 'OFF path should give independent scint amplitude (d=%.3e)', dScintOff);
    assert(dPhOff    > 1e-6, 'OFF path should give independent phase scint (d=%.3e)', dPhOff);

    % The differenced ground observable the artefact invalidates.
    sdOff = max(abs((dOffA.trop + dOffA.iono) - (dOffB.trop + dOffB.iono)));
    assert(sdOff > 1e-3, ...
        'OFF path single difference should carry the atmosphere (%.3e m)', sdOff);
    fprintf(['  [A] OFF (default): independent per asset -- trop d=%.3e m, iono d=%.3e m, ' ...
             'scint d=%.3e; SD carries %.4f m  PASS\n'], dTropOff, dIonoOff, dScintOff, sdOff);

    % ---- B. Gate ON: per-tower states shared across the formation ----
    [onA, dOnA] = i_runChain(cfgOn, seedA, elev, tid, ant, dt, nEp, []);
    [onB, dOnB] = i_runChain(cfgOn, seedB, elev, tid, ant, dt, nEp, []);

    assert(max(abs(onA.trop  - onB.trop))  < tol, 'ON: tropo wet GM must be shared');
    assert(max(abs(onA.iono  - onB.iono))  < tol, 'ON: iono TEC GM must be shared');
    assert(abs(onA.scint - onB.scint)      < tol, 'ON: scint amplitude GM must be shared');
    assert(max(abs(onA.phase - onB.phase)) < tol, 'ON: phase-scint GM must be shared');

    % Non-degenerate: the shared states are actually moving, not pinned at zero.
    assert(max(abs(onA.trop)) > 1e-4 && max(abs(onA.iono)) > 1e-4, ...
        'ON: shared GM states must be non-trivial (trop=%.3e, iono=%.3e)', ...
        max(abs(onA.trop)), max(abs(onA.iono)));

    sdOn = max(abs((dOnA.trop + dOnA.iono) - (dOnB.trop + dOnB.iono)));
    assert(sdOn < 1e-12, ...
        'ON: differenced truth atmosphere must cancel exactly (got %.3e m)', sdOn);
    fprintf(['  [B] ON: states byte-identical across assets; SD atmosphere %.3e m ' ...
             '(was %.4f m)  PASS\n'], sdOn, sdOff);

    % ---- C. Gate ON: epoch-anchored, so a skipped epoch cannot desynchronise ----
    % Asset B computes only on a sparse subset of epochs, as it would if the tower set
    % went momentarily invisible; the replay must still land it on A's state.
    skipMask       = true(1, nEp);
    skipMask(5:9)  = false;
    skipMask(21)   = false;
    [onSkip, ~] = i_runChain(cfgOn, seedB, elev, tid, ant, dt, nEp, skipMask);
    assert(max(abs(onA.trop  - onSkip.trop))  < tol, 'ON: skipped epochs must not desync tropo');
    assert(max(abs(onA.iono  - onSkip.iono))  < tol, 'ON: skipped epochs must not desync iono');
    assert(abs(onA.scint - onSkip.scint)      < tol, 'ON: skipped epochs must not desync scint');
    assert(max(abs(onA.phase - onSkip.phase)) < tol, 'ON: skipped epochs must not desync phase scint');

    % Same probe under the OFF path desyncs -- i.e. the epoch anchoring is doing work.
    [offSkip, ~] = i_runChain(cfgOff, seedA, elev, tid, ant, dt, nEp, skipMask);
    assert(max(abs(offA.trop - offSkip.trop)) > 1e-6, ...
        'OFF path should be call-count dependent, making the ON anchoring non-vacuous');
    fprintf('  [C] ON: 6 skipped epochs replayed exactly (max d=%.3e m)  PASS\n', ...
        max(abs(onA.trop - onSkip.trop)));

    % ---- D. Independent of the global RNG flag; shares ONLY the atmosphere ----
    cfgOnLegacyRng = cfgOn; cfgOnLegacyRng.rng.independentStreams.enable = false;
    [lgA, ~] = i_runChain(cfgOnLegacyRng, seedA, elev, tid, ant, dt, nEp, []);
    [lgB, ~] = i_runChain(cfgOnLegacyRng, seedB, elev, tid, ant, dt, nEp, []);
    assert(max(abs(lgA.trop - lgB.trop)) < tol && max(abs(lgA.iono - lgB.iono)) < tol, ...
        'ON must share the atmosphere regardless of cfg.rng.independentStreams');

    % Receiver code noise is NOT atmosphere: it must stay per-asset independent.
    dCode = max(abs(onA.code - onB.code));
    assert(dCode > 1e-6, ...
        'ON must share ONLY the atmosphere; receiver code noise stayed shared (d=%.3e m)', dCode);
    fprintf(['  [D] ON works with independentStreams=false; code noise still ' ...
             'per-asset (d=%.3e m)  PASS\n'], dCode);

    % ---- E. Golden safety + towers stay independent of each other ----
    cfgBare = base;
    if isfield(cfgBare,'atmosphere') && isfield(cfgBare.atmosphere,'sharedAcrossFormation')
        cfgBare.atmosphere = rmfield(cfgBare.atmosphere, 'sharedAcrossFormation');
    end
    [bareA, ~] = i_runChain(cfgBare, seedA, elev, tid, ant, dt, nEp, []);
    assert(isequal(bareA.trop,  offA.trop)  && isequal(bareA.iono,  offA.iono) && ...
           isequal(bareA.scint, offA.scint) && isequal(bareA.phase, offA.phase) && ...
           isequal(bareA.code,  offA.code), ...
        'Gate OFF must be byte-identical to a config without the field (golden safety)');

    assert(abs(onA.trop(1) - onA.trop(2)) > 1e-4 && abs(onA.iono(1) - onA.iono(2)) > 1e-4, ...
        'Distinct TOWERS must keep independent atmospheres (they are hundreds of km apart)');

    % The flag is set in masterConfig, i.e. BEFORE finalizeConfig resolves the config.
    % finalizeConfig is known to override masterConfig values, so assert it survives.
    cfgPre = masterConfig();
    cfgPre.atmosphere.sharedAcrossFormation.enable = true;
    cfgPost = revgnss.ConfigFactory.finalizeConfig(cfgPre);
    assert(models.noise.SharedAtmosphereRng.isEnabled(cfgPost), ...
        'cfg.atmosphere.sharedAcrossFormation.enable must survive ConfigFactory.finalizeConfig');
    assert(models.noise.SharedAtmosphereRng.seed(cfgPost) == cfgPost.environment.weather.seed, ...
        'Default shared-atmosphere seed should resolve to the formation-wide weather seed');
    fprintf(['  [E] gate OFF byte-identical to a field-free config; towers stay independent; ' ...
             'flag survives finalizeConfig  PASS\n']);

    % ---- F. The per-measurement scintillation truth draw is shared too ----
    ecOnA  = models.errors.ErrorChain(cfgOn,  seedA);
    ecOnB  = models.errors.ErrorChain(cfgOn,  seedB);
    ecOffA = models.errors.ErrorChain(cfgOff, seedA);
    ecOffB = models.errors.ErrorChain(cfgOff, seedB);
    src = models.noise.RngSource.SCINT_TRUTH;
    sOnA  = ecOnA.drawKeyedAtmosphere(src, 2, 1, 1, int64(11), 5, 1);
    sOnB  = ecOnB.drawKeyedAtmosphere(src, 2, 1, 1, int64(11), 5, 1);
    sOffA = ecOffA.drawKeyedAtmosphere(src, 2, 1, 1, int64(11), 5, 1);
    sOffB = ecOffB.drawKeyedAtmosphere(src, 2, 1, 1, int64(11), 5, 1);
    assert(isequal(sOnA, sOnB), 'ON: scintillation truth draw must be shared across assets');
    assert(~isequal(sOffA, sOffB), 'OFF: scintillation truth draw must stay per-asset');
    assert(isequal(sOffA, ecOffA.drawKeyed(src, 2, 1, 1, int64(11), 5, 1)), ...
        'Gate OFF: drawKeyedAtmosphere must delegate to drawKeyed byte-identically');
    % Different tower / epoch stay independent even when shared across assets.
    assert(~isequal(sOnA, ecOnA.drawKeyedAtmosphere(src, 3, 1, 1, int64(11), 5, 1)) && ...
           ~isequal(sOnA, ecOnA.drawKeyedAtmosphere(src, 2, 1, 1, int64(12), 5, 1)), ...
        'ON: shared draw must still be keyed by tower and epoch');
    fprintf('  [F] scintillation truth draw: shared when ON, per-asset when OFF  PASS\n');

    fprintf('== ALL PASS ==\n');
end

% ---------------------------------------------------------------------------
function [st, delays] = i_runChain(cfg, seed, elev, tid, ant, dt, nEp, computeMask)
% i_runChain  Step one asset's ErrorChain over nEp epochs and return its atmosphere.
%
%   computeMask  [] or 1 x nEp logical. false entries SKIP compute() for that epoch,
%                emulating an epoch with no visible towers (MeasurementModel returns
%                before ErrorChain.compute).
%
% Returns:
%   st      final per-tower GM states + the last epoch's code-noise draw
%   delays  last epoch's truth tropo / iono slant delays (the differenced observable)

    ec = models.errors.ErrorChain(cfg, seed);
    nT = numel(elev);
    delays = struct('trop', zeros(nT,1), 'iono', zeros(nT,1));
    code   = zeros(nT,1);

    for k = 0:(nEp-1)
        if ~isempty(computeMask) && ~computeMask(k+1); continue; end
        err = ec.compute(elev, tid, tid, k*dt, ant);
        delays.trop = err.bySource.truth_m.trop;
        delays.iono = err.bySource.truth_m.iono;
        code        = err.bySource.truth_m.code;
    end

    st = struct();
    st.trop  = arrayfun(@(s) s.wetResidualTruth_m, ec.envModel.tropState(:));
    st.iono  = arrayfun(@(s) s.tecResidualTruth_m, ec.envModel.ionoState(:));
    st.scint = ec.envModel.scintAmplitude;
    st.phase = ec.envModel.phaseScintState(:);
    st.code  = code;
end
