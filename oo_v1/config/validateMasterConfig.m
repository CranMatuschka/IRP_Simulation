function cfg = validateMasterConfig(cfg)
%VALIDATEMASTERCONFIG  Contract checks for the master config (Phase 1.4).
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
end
