function cfg = applyInjectTruthSideDynamics(cfg)
%APPLYINJECTTRUTHSIDEDYNAMICS  Guard B: one-sided truth-side SRP + luni-solar gap for a
%   swarm 'position' run. No-op unless cfg.multiAsset.injectTruthSideDynamics=true AND
%   estimateMode=='position' AND nSpaceAssets>=2. Gated + default-off keeps the frozen
%   goldens byte-identical (golden pins nSpaceAssets=1).
%
%   Turns on the EXISTING truth-side luni-solar + cannonball SRP (cfg.orbit.truth.
%   perturbations.*) while leaving the EKF at J2, so the truth propagator (which
%   propagates the primary chief AND every helix secondary through the same OrbitPropagator)
%   carries a force the EKF does not model -> a genuine per-satellite dynamic gap. The
%   secondary-orbit SNC is sized to the gap via its own knob so the primary r/v block is
%   not re-tuned.
    on = false; try; on = logical(cfg.multiAsset.injectTruthSideDynamics); catch; end
    if ~on; return; end
    mode = 'off'; try; mode = char(cfg.multiAsset.estimateMode); catch; end
    if ~strcmp(mode,'position'); return; end               % only mode with a per-sat dynamic gap
    nA = 1; try; nA = max(1, round(cfg.scenario.nSpaceAssets)); catch; end
    if nA < 2; return; end                                 % swarm-only: golden nSpaceAssets=1 -> no-op

    % DEFENSIVE one-sidedness: refuse if the EKF-side forces are already matched-on (gap
    % closed -> inflated SNC would masquerade as a gap run that isn't). Closes the applier-
    % ordering hole that validateMasterConfig cannot see when a run script skips validation.
    ekfLS = false; ekfSRP = false;
    try; ekfLS  = logical(cfg.estimator.dynamics.perturbations.luniSolar.enable); catch; end
    try; ekfSRP = logical(cfg.estimator.dynamics.perturbations.srp.enable);       catch; end
    if ekfLS || ekfSRP
        error('applyInjectTruthSideDynamics:notOneSided', ...
            ['EKF-side luni-solar/SRP already enabled (e.g. applyLuniSolar ran): the gap is ' ...
             'closed. Guard B requires the EKF to stay J2. Do not combine matched + one-sided.']);
    end

    % Truth-side forces ON (primary chief AND every helix secondary ride the same orbitProp):
    cfg.orbit.truth.perturbations.luniSolar.enable = true;
    cfg.orbit.truth.perturbations.srp.enable       = true;
    % EKF stays J2 (do NOT touch cfg.estimator.dynamics.perturbations) -> the gap is REAL.

    g = 1e-5; try; g = cfg.multiAsset.truthSideDynamics.sncSigma_mps2; catch; end
    % Secondary block via its own knob (does not move the primary):
    cfg.multiAsset.secondaryOrbit.sigma_accel_mps2 = g;
    % Primary block via the modelMismatch channel (it also rides the gap); separate knob so
    % it can be lowered later without touching the secondary:
    cur = 0; try; cur = cfg.estimator.processNoise.modelMismatch.sigma_mps2; catch; end
    cfg.estimator.processNoise.modelMismatch.enable     = true;
    cfg.estimator.processNoise.modelMismatch.sigma_mps2 = max(cur, g);
end
