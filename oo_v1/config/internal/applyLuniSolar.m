function cfg = applyLuniSolar(cfg)
%APPLYLUNISOLAR  Truth-side Sun/Moon and SRP reduced-dynamics stressor.
%   cfg = applyLuniSolar(cfg)
%
%   No-op unless cfg.perturbations.sunMoon.enable is true (default false, set in masterConfig).
%   The truth receives the named perturbations. The estimator retains its lower-order
%   dynamics and carries residual-acceleration process uncertainty.
%
%   See also: masterConfig, realismGradeConfig, +models/+orbit/OrbitPerturbations.

    on = false;
    try; on = logical(cfg.perturbations.sunMoon.enable); catch; end
    if ~on; return; end

    cfg.estimator.processNoise.modelMismatch.enable     = true;
    cfg.estimator.processNoise.modelMismatch.sigma_mps2 = 1e-5;
    cfg.orbit.truth.perturbations.luniSolar.enable = true;
    cfg.orbit.truth.perturbations.srp.enable       = true;
    cfg.estimator.dynamics.perturbations.luniSolar.enable = false;
    cfg.estimator.dynamics.perturbations.srp.enable = false;
    eph = 'mg';
    try; eph = char(cfg.perturbations.sunMoon.ephemeris); catch; end
    cfg.orbit.truth.perturbations.ephemeris = eph;
end
