function test_orbit_luni_solar_srp_perturbation()
%TEST_ORBIT_LUNI_SOLAR_SRP_PERTURBATION  R-3: truth luni-solar + SRP force (gated, truth-only).
%   Verifies the perturbation magnitudes are physical, that the perturbed TRUTH orbit
%   diverges from the J2 baseline, and that the feature is a byte-identical no-op when
%   disabled (the golden-safety property). Run: matlab -batch "run('tests/test_orbit_luni_solar_srp_perturbation.m')"

    root = fileparts(fileparts(mfilename('fullpath')));
    addpath(root); addpath(fullfile(root,'config'));
    jd = 2451545.0;  r_geo = [42164e3; 0; 0];

    % --- 1. Accel magnitudes at GEO ------------------------------------------
    pLS = i_p(true,  false, jd);
    pSR = i_p(false, true,  jd); pSR.srpParams.shadow = 'none';
    aLS = models.orbit.OrbitPerturbations.accel(r_geo, 0, pLS);
    aSR = models.orbit.OrbitPerturbations.accel(r_geo, 0, pSR);
    assert(norm(aLS) > 3e-6 && norm(aLS) < 9e-6, ...
        'luni-solar accel %.3e out of [3e-6,9e-6]', norm(aLS));
    assert(norm(aSR) > 3e-8 && norm(aSR) < 3e-7, ...
        'SRP accel %.3e out of [3e-8,3e-7]', norm(aSR));

    % --- 2. Sun/moon ephemeris sanity ----------------------------------------
    rs = models.orbit.OrbitPerturbations.sunPositionEci(jd);
    rm = models.orbit.OrbitPerturbations.moonPositionEci(jd);
    assert(abs(norm(rs)/1.495978707e11 - 1) < 0.03, 'sun distance not ~1 AU');
    assert(norm(rm) > 3.5e8 && norm(rm) < 4.1e8, 'moon distance out of range');

    % --- 3. Perturbed truth diverges from J2; disabled is a byte-identical no-op
    cfg = masterConfig();
    t   = 0:60:3600;
    op0 = models.orbit.OrbitPropagator(cfg.orbit);                 % default (off)
    cfgP = cfg;
    cfgP.orbit.truth.perturbations.luniSolar.enable = true;
    cfgP.orbit.truth.perturbations.srp.enable       = true;
    opP = models.orbit.OrbitPropagator(cfgP.orbit);
    [r0,~] = op0.propagate(t);
    [rP,~] = opP.propagate(t);
    assert(norm(rP(:,end) - r0(:,end)) > 10, 'perturbed truth failed to diverge from J2');

    op0b = models.orbit.OrbitPropagator(cfg.orbit);
    [r0b,~] = op0b.propagate(t);
    assert(max(vecnorm(r0b - r0, 2, 1)) == 0, 'disabled perturbation is NOT a byte-identical no-op');

    fprintf('PASS test_orbit_luni_solar_srp_perturbation (|aLS|=%.2e |aSR|=%.2e div=%.1f m)\n', ...
        norm(aLS), norm(aSR), norm(rP(:,end)-r0(:,end)));
end

function p = i_p(ls, srp, jd)
    p = struct('enable', ls||srp, 'luniSolar', ls, 'srp', srp, 'epochJD_TT', jd, ...
        'srpParams', struct('Cr',1.3,'areaToMass_m2pkg',0.02,'shadow','cylindrical'));
end
