function cfg = applyLuniSolar(cfg)
%APPLYLUNISOLAR  Matched Sun+Moon third-body + SRP force model on truth AND EKF (gated).
%   cfg = applyLuniSolar(cfg)
%
%   No-op unless cfg.perturbations.sunMoon.enable is true (default false, set in masterConfig).
%   When enabled it is a COUPLED unit: it turns on both the truth-side and the EKF-side luni-solar
%   + SRP perturbations with matched epoch / Cr / area-to-mass and retunes the residual-
%   acceleration process-noise (SNC) to 1e-6, so it can never manufacture a one-sided force gap.
%   This is the standalone equivalent of realismGradeConfig's include.luniSolar block, callable by
%   a run script after masterConfig() (mirrors how realismGradeConfig is applied). Gated + default
%   off keeps the frozen goldens byte-identical.
%
%   See also: masterConfig, realismGradeConfig, +models/+orbit/OrbitPerturbations.

    on = false;
    try; on = logical(cfg.perturbations.sunMoon.enable); catch; end
    if ~on; return; end

    cfg.estimator.processNoise.modelMismatch.enable     = true;
    cfg.estimator.processNoise.modelMismatch.sigma_mps2 = 1e-6;
    % Truth-side forces:
    cfg.orbit.truth.perturbations.luniSolar.enable = true;
    cfg.orbit.truth.perturbations.srp.enable       = true;
    % EKF-side forces (matched to the truth so no gap):
    cfg.estimator.dynamics.perturbations.luniSolar.enable     = true;
    cfg.estimator.dynamics.perturbations.srp.enable           = true;
    cfg.estimator.dynamics.perturbations.epochJD_TT           = cfg.orbit.truth.perturbations.epochJD_TT;
    cfg.estimator.dynamics.perturbations.srp.Cr               = cfg.orbit.truth.perturbations.srp.Cr;
    cfg.estimator.dynamics.perturbations.srp.areaToMass_m2pkg = cfg.orbit.truth.perturbations.srp.areaToMass_m2pkg;
    % Sun/Moon ephemeris source ('mg' analytic default | 'de440' via the Orekit bridge),
    % matched on truth AND EKF so it never manufactures a one-sided gap. Default 'mg'.
    eph = 'mg';
    try; eph = char(cfg.perturbations.sunMoon.ephemeris); catch; end
    cfg.orbit.truth.perturbations.ephemeris        = eph;
    cfg.estimator.dynamics.perturbations.ephemeris = eph;
end
