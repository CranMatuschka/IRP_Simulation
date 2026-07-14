function cfg = validateMasterConfig(cfg)
%VALIDATEMASTERCONFIG  Contract checks for the master config.
%   Asserts the assembled config satisfies the clarity-refactor contract (scenario
%   set, deterministic master seed, positive timing, claim discipline) and returns
%   cfg UNCHANGED. Value DERIVATIONS remain in ConfigFactory.finalizeConfig, the
%   single derivation step run by the simulation at initialize() time; this function
%   only validates, it does not derive or mutate values.
%
%   Note: fully folding finalizeConfig's derivations into this file (per the brief)
%   is deferred - finalizeConfig is a deeply-integrated ~1250-line engine invoked by
%   ReverseGNSSSimulation; extracting it is its own equivalence-critical effort. For
%   now it stays the one derivation step, and this is the one contract-check step.

    % --- Hard invariants (error) ---
    assert(isfield(cfg,'scenario') && isfield(cfg.scenario,'name') && ~isempty(cfg.scenario.name), ...
        'validateMasterConfig:scenario', 'cfg.scenario.name must be set.');
    assert(isfield(cfg,'simulation') && isfield(cfg.simulation,'seed') && ...
        isnumeric(cfg.simulation.seed) && isscalar(cfg.simulation.seed), ...
        'validateMasterConfig:seed', 'cfg.simulation.seed must be a scalar numeric master seed.');
    assert(isfield(cfg.simulation,'duration_s') && cfg.simulation.duration_s > 0, ...
        'validateMasterConfig:duration', 'cfg.simulation.duration_s must be > 0.');
    assert(isfield(cfg.simulation,'dt_s') && cfg.simulation.dt_s > 0, ...
        'validateMasterConfig:dt', 'cfg.simulation.dt_s must be > 0.');

    % --- RNG stream-independence contract (guarded: legacy configs may omit) ---
    if isfield(cfg,'rng') && isfield(cfg.rng,'independentStreams')
        is = cfg.rng.independentStreams;
        if isfield(is,'enable')
            assert(islogical(is.enable) && isscalar(is.enable), ...
                'validateMasterConfig:rngEnable', ...
                'cfg.rng.independentStreams.enable must be a logical scalar.');
        end
        if isfield(is,'engine')
            supported = {'threefry','philox','mrg32k3a','mlfg6331_64','mt19937ar'};
            assert(ischar(is.engine) && any(strcmp(is.engine, supported)), ...
                'validateMasterConfig:rngEngine', ...
                'cfg.rng.independentStreams.engine must be one of: %s.', strjoin(supported, ', '));
        end
    end

    % --- Claim discipline (warn; brief section 0.9: synthetic only) ---
    if isfield(cfg,'scientificProfile') && isfield(cfg.scientificProfile,'allowRealWorldClaim') ...
            && cfg.scientificProfile.allowRealWorldClaim
        warning('validateMasterConfig:realWorldClaim', ...
            'allowRealWorldClaim is true; synthetic-only discipline expects false until real parsers exist.');
    end

    % --- Sanity: representative noise sigma non-negative (warn) ---
    if isfield(cfg,'clocks') && isfield(cfg.clocks,'tower') && isfield(cfg.clocks.tower,'product') ...
            && isfield(cfg.clocks.tower.product,'sigmaBias_m') && cfg.clocks.tower.product.sigmaBias_m < 0
        warning('validateMasterConfig:negativeSigma', ...
            'cfg.clocks.tower.product.sigmaBias_m is negative.');
    end

    % --- Warn when hardware delay is enabled but leaves NO residual ---
    % Enabled with truth==model (matched default_m) and residualStochastic off contributes
    % exactly 0 to z-h -- flag it so it is not silently treated as an active imperfection.
    % Off by default -> never fires on the shipped/golden run. (The analogous PCO case is
    % on-by-default-but-matched, so it is handled by the honest audit relabeling, not a warn.)
    if revgnss.ImperfectionAudit.hwDelayEnabled(cfg) && ~revgnss.ImperfectionAudit.hwDelayLeavesResidual(cfg)
        warning('validateMasterConfig:hwDelayNoResidual', ...
            ['cfg.errors.hardwareDelay is enabled but truth==model (matched default_m) and ' ...
             'residualStochastic is off -> it contributes EXACTLY 0 to z-h. Use differing ' ...
             'truth/model default_m, or residualStochastic.enable=true with sigma_m>0.']);
    end
end
