function out = ionosphere(mode, args, cfg)
%IONOSPHERE  Single entry point for first-order ionosphere façade.
%   Delegates VERBATIM to models.atmosphere.IonosphereModel — there is no physics here. The
%   Validated math stays in the class; this is the discoverable one-file-per-
%   effect entry point (models/<domain>/<effect>.m) with a uniform mode-dispatched API.
%   Standalone: not yet wired into the sim, so it cannot move the regression golden.
%
%   out = ionosphere(mode, args[, cfg])
%     mode = 'model'       -> out.codeDelay_m, out.carrierDelay_m : signed L-band delay
%                             args: delayPrimary_m, signalName, primaryName
%     mode = 'covariance'  -> out.c1, out.c2 : ionosphere-free combination coefficients
%                             args: f1_Hz, f2_Hz
%     mode = 'diagnostic'  -> out.scale : (f_primary/f_signal)^2 first-order iono scale
%                             args: signalName, primaryName
%     mode = 'truth'       -> UNSUPPORTED: first-order ionosphere TRUTH is drawn inside
%                             the stateful models.errors.ErrorChain per-epoch pass, not
%                             reachable as an isolated stateless call. Use the sim.
%   cfg is REQUIRED for 'model' and 'diagnostic': the (f_primary/f_signal)^2 scale is
%   resolved from cfg.signals, the one owner of a carrier frequency.
    if nargin < 3; cfg = struct(); end
    switch mode
        case 'model'
            out.codeDelay_m    = models.atmosphere.IonosphereModel.applyCodeSign( ...
                cfg, args.delayPrimary_m, args.signalName, args.primaryName);
            out.carrierDelay_m = models.atmosphere.IonosphereModel.applyCarrierSign( ...
                cfg, args.delayPrimary_m, args.signalName, args.primaryName);
        case 'covariance'
            [out.c1, out.c2] = models.atmosphere.IonosphereModel.ionoFreeCoefficients( ...
                args.f1_Hz, args.f2_Hz);
        case 'diagnostic'
            out.scale = models.atmosphere.IonosphereModel.scaleForSignal( ...
                cfg, args.signalName, args.primaryName);
        case 'truth'
            error('ionosphere:truthNotHere', ...
                ['First-order ionosphere TRUTH is realized inside models.errors.ErrorChain ', ...
                 '(stateful, per-epoch), not via this stateless façade — run the simulation.']);
        otherwise
            error('ionosphere:badMode', ...
                'mode must be ''model'', ''covariance'', ''diagnostic'' or ''truth''; got ''%s''.', ...
                char(string(mode)));
    end
end
