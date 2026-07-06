function out = troposphere(mode, args, cfg)
%TROPOSPHERE  Single entry point for troposphere / ZWD (Phase 5 façade).
%   Delegates VERBATIM to revgnss.TroposphereModel — no physics here. The stochastic
%   truth/model DELAY draws live in the stateful revgnss.ErrorChain (per-epoch); this
%   façade exposes the deterministic mapping, ZWD process parameters, and the
%   architecture / weak-observability diagnostics only. Standalone (not wired into the
%   sim), so it cannot move the regression golden.
%     mode = 'model'       -> out.mappingFactor : elevation->mapping factor (h multiplier)
%                             args: elevation_rad ; cfg selects the mapping kind
%     mode = 'covariance'  -> out.sigma_ss_m, out.tau_s, out.initialSigma_m : ZWD GM params
%                             cfg: cfg.estimation.tropoZwd (optional)
%     mode = 'diagnostic'  -> out.describe (architecture struct), out.weakObsNote (string)
%                             args: stateMap (optional), elevations_rad (optional)
%     mode = 'truth'       -> UNSUPPORTED: tropo truth delay is realized inside the
%                             stateful revgnss.ErrorChain, not via this stateless façade.
    if nargin < 3; cfg = struct(); end
    switch mode
        case 'model'
            out.mappingFactor = revgnss.TroposphereModel.mapping(args.elevation_rad, cfg);
        case 'covariance'
            [out.sigma_ss_m, out.tau_s, out.initialSigma_m] = ...
                revgnss.TroposphereModel.zwdProcessParams(cfg);
        case 'diagnostic'
            sm = struct(); if isfield(args, 'stateMap');       sm = args.stateMap;       end
            el = [];       if isfield(args, 'elevations_rad'); el = args.elevations_rad; end
            out.describe    = revgnss.TroposphereModel.describe(cfg, sm);
            out.weakObsNote = revgnss.TroposphereModel.weakObservabilityNote(el);
        case 'truth'
            error('troposphere:truthNotHere', ...
                ['Troposphere TRUTH delay is realized inside revgnss.ErrorChain ', ...
                 '(stateful, per-epoch), not via this stateless façade — run the simulation.']);
        otherwise
            error('troposphere:badMode', ...
                'mode must be ''model'', ''covariance'', ''diagnostic'' or ''truth''; got ''%s''.', ...
                char(string(mode)));
    end
end
