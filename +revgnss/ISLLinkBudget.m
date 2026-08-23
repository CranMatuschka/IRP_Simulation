classdef ISLLinkBudget
    % ISLLinkBudget  Distance- and frequency-derived ISL ranging sigma.
    %
    % Replaces a hand-typed constant (e.g. cfg.multiAsset.twoWayISL.sigma_m = 0.01,
    % commented "cm-class wideband crosslink") with a value DERIVED from the link:
    %
    %   L_fs   = 20*log10(4*pi*d*f/c)            free-space path loss [dB]
    %   C/N0   = EIRP + G/T - L_fs - k_boltz     received carrier-to-noise [dB-Hz]
    %   sigma  = sigma0 * 10^(-(C/N0 - C/N0_ref)/20)
    %
    % Mirrors the C/N0 code-noise model already used for the ground link
    % (models.measurements.MeasurementModelUtils.codeSignalSigma, case 'cn0'), with
    % distance and frequency as the drivers instead of elevation.
    %
    % ANCHORED, NOT ABSOLUTE. sigma0 is defined AT refDistance_m, so the model returns
    % EXACTLY sigma0 there and only the RATIO moves it elsewhere. Two consequences:
    %   * it is a perturbation around the number you already trust, not a new absolute claim;
    %   * with model='fixed' (the default) it returns sigma0 unchanged -> golden-safe.
    %
    % THE ANTENNA ASSUMPTION IS THE SCIENCE, AND IT IS NOT OPTIONAL TO STATE:
    %   'fixedGain'     antenna gain [dBi] held constant  -> C/N0 falls as f^2, so
    %                   sigma GROWS with frequency. Represents small/patch antennas.
    %   'fixedAperture' a dish of fixed diameter has G ~ f^2, which EXACTLY CANCELS the
    %                   f^2 path loss -> sigma is frequency-INDEPENDENT. Represents
    %                   steerable dishes. This is the default because it is the honest
    %                   choice for a crosslink dish, and because claiming Ka is
    %                   automatically noisier than L-band would be wrong.
    % Distance dependence (sigma ~ d) is unambiguous and applies to BOTH models.

    methods (Static)

        function s = sigma(cfg, distance_m, basePath, sigma0Default)
            % sigma  Ranging sigma [m] for a link of the given length.
            %
            % basePath: config path prefix, e.g. {'multiAsset','twoWayISL'}. The knobs
            % live under <basePath>.linkBudget.*; sigma0 is <basePath>.sigma_m.
            if nargin < 4 || isempty(sigma0Default); sigma0Default = 0.01; end
            b = revgnss.ISLLinkBudget.cfg_(cfg, basePath, sigma0Default);
            s = b.sigma0;
            if ~strcmp(b.model, 'linkBudget'); return; end          % 'fixed' -> unchanged
            if ~isfinite(distance_m) || distance_m <= 0; return; end
            dC = revgnss.ISLLinkBudget.cn0Delta_dB(b, distance_m);
            s  = b.sigma0 * 10^(-dC/20);
        end

        function dC = cn0Delta_dB(b, distance_m)
            % cn0Delta_dB  C/N0 at distance_m MINUS C/N0 at the reference distance.
            % Negative => weaker link => larger sigma.
            %
            %   fixedGain     : dC = -20*log10(d/d_ref)  (frequency enters via the anchor
            %                   only, since both terms share the same f)
            %   fixedAperture : identical in d; the f^2 path loss is cancelled by the
            %                   f^2 aperture gain, so frequency drops out entirely.
            dC = -20 * log10(distance_m / b.refDistance_m);
        end

        function s = sigmaAtFrequency(b, distance_m, freq_Hz)
            % sigmaAtFrequency  Explicit frequency dependence, for the fixedGain model.
            % Provided so a study can show the f-dependence rather than assume it away.
            dC = revgnss.ISLLinkBudget.cn0Delta_dB(b, distance_m);
            if strcmp(b.antennaModel, 'fixedGain')
                dC = dC - 20 * log10(freq_Hz / b.refFrequency_Hz);
            end
            s = b.sigma0 * 10^(-dC/20);
        end

        function info = describe(cfg, basePath, sigma0Default)
            % describe  What the model is doing, for the report layer.
            if nargin < 3 || isempty(sigma0Default); sigma0Default = 0.01; end
            info = revgnss.ISLLinkBudget.cfg_(cfg, basePath, sigma0Default);
            info.frequencyDependent = strcmp(info.antennaModel, 'fixedGain');
            if strcmp(info.model,'fixed')
                info.note = 'fixed sigma (link budget disabled) -- the legacy constant';
            elseif info.frequencyDependent
                info.note = 'sigma ~ d and ~ f (fixed antenna GAIN: f^2 path loss uncompensated)';
            else
                info.note = 'sigma ~ d, frequency-INDEPENDENT (fixed APERTURE: G~f^2 cancels the f^2 path loss)';
            end
        end

    end

    methods (Static, Access = private)

        function b = cfg_(cfg, basePath, sigma0Default)
            b = struct('model','fixed','antennaModel','fixedAperture', ...
                'sigma0', sigma0Default, 'refDistance_m', 1000, ...
                'refFrequency_Hz', 26e9, 'EIRP_dBW', 15, 'GT_dBK', 5);
            b.sigma0 = revgnss.ISLLinkBudget.num_(cfg, [basePath {'sigma_m'}], sigma0Default);
            lb = [basePath {'linkBudget'}];
            b.model         = revgnss.ISLLinkBudget.str_(cfg, [lb {'model'}], b.model);
            b.antennaModel  = revgnss.ISLLinkBudget.str_(cfg, [lb {'antennaModel'}], b.antennaModel);
            b.refDistance_m = revgnss.ISLLinkBudget.num_(cfg, [lb {'refDistance_m'}], b.refDistance_m);
            b.refFrequency_Hz = revgnss.ISLLinkBudget.num_(cfg, [lb {'refFrequency_Hz'}], b.refFrequency_Hz);
            b.EIRP_dBW      = revgnss.ISLLinkBudget.num_(cfg, [lb {'EIRP_dBW'}], b.EIRP_dBW);
            b.GT_dBK        = revgnss.ISLLinkBudget.num_(cfg, [lb {'GT_dBK'}], b.GT_dBK);
        end

        function v = num_(cfg, path, dflt)
            v = cfg;
            for k = 1:numel(path)
                if isstruct(v) && isfield(v, path{k}); v = v.(path{k}); else; v = dflt; return; end
            end
            if ~(isnumeric(v) && isscalar(v) && isfinite(v)); v = dflt; end
        end

        function v = str_(cfg, path, dflt)
            v = cfg;
            for k = 1:numel(path)
                if isstruct(v) && isfield(v, path{k}); v = v.(path{k}); else; v = dflt; return; end
            end
            if ~(ischar(v) || isstring(v)); v = dflt; else; v = char(v); end
        end

    end
end
