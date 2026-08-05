classdef SharedAtmosphereRng
    % SharedAtmosphereRng  Formation-wide root for the stochastic atmosphere streams.
    %
    % WHY THIS EXISTS
    %   Every swarm member builds its own models.errors.ErrorChain -> its own
    %   models.errors.EnvironmentModel -> its own models.noise.RngRegistry rooted at
    %   that asset's cfg.simulation.seed (offset per asset in ReportRunner's federated
    %   fan-out). RngRegistry's substream key is
    %       idx = src*2^44 + node*2^28 + ant*2^24 + sig*2^20 + ep
    %   which has NO asset field, so the ONLY thing separating two assets' atmosphere
    %   realisations is that master seed. Two satellites 2 km apart at GEO therefore
    %   draw statistically INDEPENDENT troposphere / ionosphere / scintillation.
    %
    %   That is wrong physics for a formation. Their ray paths to one tower diverge by
    %   2000/36e6 rad = 11 arcsec: ~0.5 m of separation at the top of the troposphere
    %   and ~18 m at a 350 km ionospheric pierce point, both far inside the decorrelation
    %   scale (km for tropo, tens of km for iono) and well inside the L-band Fresnel
    %   scale sqrt(lambda*z) ~ 260 m that sets scintillation coherence. Physically they
    %   look through ONE air column; the delay is common-mode and cancels in a
    %   between-satellite single difference to ~0.006-1.6 mm. The independent-draw model
    %   instead injects sqrt(2) x (tropo GM + iono GM + scintillation) into that same
    %   difference -- 2-3 orders of magnitude too large -- which invalidates any
    %   between-satellite differenced ground observable built on top of it.
    %
    % WHAT THIS DOES
    %   Resolves cfg.atmosphere.sharedAcrossFormation and, when enabled, builds an
    %   RngRegistry rooted at a FORMATION-WIDE constant seed instead of the per-asset
    %   cfg.simulation.seed. Every asset then keys the same (source, tower, epoch)
    %   identity into the same root and gets a byte-identical atmosphere realisation,
    %   while all other noise (receiver thermal, clocks, multipath, hardware) stays
    %   rooted at its own per-asset seed and remains genuinely independent.
    %
    %   Re-rooting -- not an extra "asset" field in the substream key -- is the correct
    %   lever precisely BECAUSE the key has no asset field: adding one and pinning it to
    %   a constant would leave the per-asset master seeds still separating the streams.
    %
    % RELATION TO cfg.rng.independentStreams
    %   Setting cfg.rng.independentStreams.enable=false also happens to give every asset
    %   a byte-identical atmosphere (EnvironmentModel then falls back to a single envRng
    %   seeded from cfg.environment.weather.seed, which is not offset per asset). That is
    %   a GLOBAL RNG flag that also collapses receiver noise, multipath and clock streams
    %   onto one shared draw order, so it is not a usable scientific control. This class
    %   is the targeted one: it works whether independentStreams is on or off, and it
    %   touches nothing but the atmosphere.
    %
    % Config:
    %   cfg.atmosphere.sharedAcrossFormation.enable  (default false -> inert)
    %   cfg.atmosphere.sharedAcrossFormation.seed    (default cfg.environment.weather.seed,
    %                                                 else 7201)
    %   Engine follows cfg.rng.independentStreams.engine (default 'threefry').

    properties (Constant)
        DEFAULT_SEED = 7201    % matches cfg.environment.weather.seed / the legacy envRng seed
    end

    methods (Static)

        function tf = isEnabled(cfg)
            % isEnabled  True when the formation-shared atmosphere gate is on.
            tf = false;
            if ~isstruct(cfg) || ~isfield(cfg,'atmosphere'); return; end
            a = cfg.atmosphere;
            if ~isfield(a,'sharedAcrossFormation'); return; end
            s = a.sharedAcrossFormation;
            if isstruct(s) && isfield(s,'enable')
                tf = logical(s.enable);
            elseif islogical(s) || isnumeric(s)
                tf = logical(s);   % tolerate a bare scalar shorthand
            end
        end

        function seed = seed(cfg)
            % seed  Formation-wide atmosphere root seed (NOT offset per asset).
            seed = models.noise.SharedAtmosphereRng.DEFAULT_SEED;
            if isstruct(cfg) && isfield(cfg,'environment') && ...
                    isfield(cfg.environment,'weather') && isfield(cfg.environment.weather,'seed')
                seed = cfg.environment.weather.seed;
            end
            if isstruct(cfg) && isfield(cfg,'atmosphere') && ...
                    isfield(cfg.atmosphere,'sharedAcrossFormation')
                s = cfg.atmosphere.sharedAcrossFormation;
                if isstruct(s) && isfield(s,'seed') && ~isempty(s.seed)
                    seed = s.seed;
                end
            end
        end

        function reg = build(cfg)
            % build  RngRegistry rooted at the formation-wide seed, or [] when disabled.
            reg = [];
            if ~models.noise.SharedAtmosphereRng.isEnabled(cfg); return; end
            eng = 'threefry';
            if isstruct(cfg) && isfield(cfg,'rng') && isfield(cfg.rng,'independentStreams') && ...
                    isfield(cfg.rng.independentStreams,'engine') && ...
                    ~isempty(cfg.rng.independentStreams.engine)
                eng = cfg.rng.independentStreams.engine;
            end
            reg = models.noise.RngRegistry( ...
                models.noise.SharedAtmosphereRng.seed(cfg), eng);
        end

    end
end
