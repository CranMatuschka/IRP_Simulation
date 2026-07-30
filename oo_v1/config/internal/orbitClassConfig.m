function cfg = orbitClassConfig(cfg)
%ORBITCLASSCONFIG  Apply orbit-class-specific orbit geometry + EKF tuning.
%   ONE switch selects the orbit class: cfg.scenario.orbitClass, set in
%   config/masterConfig.m to 'GEO' | 'MEO' | 'LEO'. masterConfig calls this
%   applier after the scenario assembly, so changing that single string moves
%   the whole run between orbit classes -- no other edit is needed.
%
%   'GEO' (default) is a STRICT NO-OP so the frozen baseline is preserved
%   byte-identical. 'MEO'/'LEO' override altitude, inclination, RAAN, initial
%   true anomaly and the residual-acceleration process noise (SNC). Truth and
%   the EKF use the same J2 force family (cfg.orbit.truth.mode / dynamics.mode are
%   set in masterConfig); only the geometry and tuning change here.
%
%   Initial elements are chosen so the sub-satellite point starts over the
%   existing 23 deg-E tower network (~26 deg E, ~32 deg N at t=0):
%     lon = atan2(sin(nu0) cos(inc), cos(nu0)),  lat = asin(sin(nu0) sin(inc))
%   (RAAN=0, epochGMST=0). At 20 200 km the MEO footprint (~76 deg radius) keeps
%   the whole network in view for the run; a 600 km LEO (~24 deg footprint)
%   overflies the cluster and loses continuous visibility away from it.
%
%   DOCUMENTED GAPS (not modelled here):
%     * Atmospheric drag -- the dominant non-gravitational force below ~600 km.
%       The truth propagator is J2-only (+models/+orbit/OrbitPropagator), so a
%       physical LEO truth needs a drag term in +models/+orbit/OrbitPerturbations.
%       For a same-force-family convergence test this is acceptable because both omit
%       it); it is a realism gap, not a convergence blocker.
%     * Global tower network -- the default sites cluster around 23 deg E, so a
%       fast LEO loses continuous visibility. Use nTowers=12 (the wide real
%       network) and/or a globally distributed set for sustained LEO coverage.
    oc = 'GEO';
    if isfield(cfg,'scenario') && isfield(cfg.scenario,'orbitClass') && ...
            ~isempty(cfg.scenario.orbitClass)
        oc = upper(char(cfg.scenario.orbitClass));
    end

    switch oc
        case 'GEO'
            return   % headline / frozen-golden GEO: leave every value untouched

        case 'MEO'
            cfg.orbit.altitudeMean_m   = 20200e3;         % ~GPS MEO shell
            cfg.orbit.inclination_rad  = deg2rad(55);
            cfg.orbit.raan_rad         = 0;
            cfg.orbit.trueAnomaly0_rad = deg2rad(40);     % sub-sat ~26E/32N at t=0
            % Same J2 force family, faster geometry than GEO; a modest SNC bump
            % covers the larger 1-s linearisation step (GEO baseline is 1e-6).
            cfg.estimator.sigma_accel_mps2 = 5e-6;

        case 'LEO'
            cfg.orbit.altitudeMean_m   = 600e3;
            cfg.orbit.inclination_rad  = deg2rad(53);
            cfg.orbit.raan_rad         = 0;
            cfg.orbit.trueAnomaly0_rad = deg2rad(40);     % sub-sat ~26E/32N at t=0
            % LEO moves ~7.5 km/s with strong J2; larger SNC for the fast dynamics.
            cfg.estimator.sigma_accel_mps2 = 5e-5;
            % A 600 km LEO overflies any regional cluster in minutes, so it needs a
            % GLOBALLY distributed ground network for sustained visibility. Rebuild
            % cfg.towers here with ~20 worldwide sites (first 5 = golden set) and set
            % nTowers to match. GEO/MEO keep the default 23 deg-E network untouched.
            cfg = i_applyGlobalTowerNetwork_(cfg);

        otherwise
            error('orbitClassConfig:unknownClass', ...
                'cfg.scenario.orbitClass must be GEO | MEO | LEO (got "%s").', oc);
    end

    % Keep the propagator run-mode consistent with the truth mode chosen upstream.
    if isfield(cfg,'orbit') && isfield(cfg.orbit,'truth') && ...
            isfield(cfg.orbit.truth,'mode') && ~isempty(cfg.orbit.truth.mode)
        cfg.orbit.mode = cfg.orbit.truth.mode;
    end
end

% ======================================================================
% i_applyGlobalTowerNetwork_  Replace cfg.towers with a globally distributed
%   ground network so a fast LEO keeps towers in view around the whole orbit.
%   The first 5 sites match the frozen-golden network (continuity); the rest
%   span all longitudes and +-65 deg latitude (real tracking/geodetic sites).
%   Towers are rebuilt from the existing tower(1) template + re-seeded
%   deterministic OCXO clocks, exactly as config/masterConfig i_baseDefaults does.
%
%   MEASURED (600 km LEO, code+Doppler, 3600 s single-antenna density sweep):
%   this 20-site list yields only ~0.3 satellites-in-view/epoch -- INSUFFICIENT;
%   the EKF coasts and drifts (~km). A LEO footprint is ~3% of Earth, so a
%   continuous fix needs a MUCH denser network: ~150 well-distributed sites
%   (mean ~4 in view) converges to ~15-40 m / ~38 ns; 60 sites (mean ~1.8) is
%   still unstable. This 20-site set is an honest illustrative starting point,
%   not a working continuous-coverage network. The one-way radial<->clock
%   degeneracy persists for LEO too (clock stuck at tens of ns).
% ======================================================================
function cfg = i_applyGlobalTowerNetwork_(cfg)
    towerDefs = { ...
        'Tenerife',        28.3,      -16.5,     0.0; ...   % 1  golden set
        'Stockholm',       59.3,       18.1,     0.0; ...   % 2  golden set
        'Hartebeesthoek', -25.9,       27.7,     0.0; ...   % 3  golden set
        'Bengaluru',       13.0,       77.6,     0.0; ...   % 4  golden set
        'Libreville',       0.0355,    -9.4496,  0.0; ...   % 5  golden set
        'Goldstone',       35.43,    -116.89,    0.0; ...   % 6  N America (Mojave)
        'Kourou',           5.10,     -52.65,    0.0; ...   % 7  S America (equ. Atlantic)
        'Santiago',       -33.15,     -70.67,    0.0; ...   % 8  S America (Andes)
        'Perth',          -31.80,     115.89,    0.0; ...   % 9  W Australia
        'Kashima',         35.95,     140.66,    0.0; ...   % 10 Japan / W Pacific
        'Fairbanks',       64.98,    -147.51,    0.0; ...   % 11 Alaska (high N)
        'Kokee',           22.13,    -159.66,    0.0; ...   % 12 Hawaii (mid Pacific)
        'Papeete',        -17.58,    -149.61,    0.0; ...   % 13 Tahiti (S Pacific)
        'Wettzell',        49.14,      12.88,    0.0; ...   % 14 Europe
        'Yellowknife',     62.48,    -114.48,    0.0; ...   % 15 N Canada
        'Ascension',       -7.95,     -14.41,    0.0; ...   % 16 S Atlantic
        'DiegoGarcia',     -7.27,      72.37,    0.0; ...   % 17 Indian Ocean
        'Guam',            13.59,     144.86,    0.0; ...   % 18 W Pacific
        'EasterIsland',   -27.15,    -109.38,    0.0; ...   % 19 SE Pacific
        'Dunedin',        -45.87,     170.50,    0.0 };     % 20 New Zealand (high S)

    tpl    = cfg.towers(1);                    % field template (offsets, clockFactors, ...)
    towers = repmat(tpl, 1, size(towerDefs,1));
    for k = 1:size(towerDefs,1)
        towers(k).id      = k;
        towers(k).name    = towerDefs{k,1};
        towers(k).lat_rad = towerDefs{k,2} * pi/180;
        towers(k).lon_rad = towerDefs{k,3} * pi/180;
        towers(k).alt_m   = towerDefs{k,4};
        towers(k).antennaOffset_enu_m = [0; 0; 0];
        towers(k).hardwareDelay_m     = 0.0;
        towers(k).clockName = 'GroundClock';
        towers(k).clockType = 'OCXO';
        towers(k).clock = revgnss.ConfigFactory.makeClockConfig( ...
            towers(k).clockType, 200 + k, tpl.clockFactors, cfg.clockScaling);
        towers(k).clock.name          = sprintf('GroundClock_%s', towerDefs{k,1});
        towers(k).clock.deterministic = true;
        towers(k).clock.bias_s        = 0.0;
        towers(k).clock.fracFreq      = 0.0;
    end
    cfg.towers           = towers;
    cfg.scenario.nTowers = size(towerDefs,1);
end
