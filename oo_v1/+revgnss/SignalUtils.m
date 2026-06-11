classdef SignalUtils
    % SignalUtils  Signal / frequency configuration helpers.
    %
    % Methods:
    %   getEnabledSignals        Return struct array of enabled signals from cfg
    %   getFrequencyScaleToL1    Return (f_L1 / f_sig)^2 scale factor

    methods (Static)

        function signals = getEnabledSignals(cfg)
            % getEnabledSignals  Return struct array for all enabled signals.
            %
            % Each element has fields:
            %   name           string   e.g. 'L1'
            %   frequency_Hz   double   carrier frequency [Hz]
            %   lambda_m       double   wavelength [m]
            %   codeSigma0_m   double   baseline code noise sigma [m]
            %
            % Falls back to L1-only if cfg.signals is missing or empty.

            f_L1_default   = 1575.42e6;
            f_L2_default   = 1227.60e6;
            c              = 299792458;

            defaultL1 = struct('name','L1', ...
                               'frequency_Hz',  f_L1_default, ...
                               'lambda_m',      c / f_L1_default, ...
                               'codeSigma0_m',  0.30);
            defaultL2 = struct('name','L2', ...
                               'frequency_Hz',  f_L2_default, ...
                               'lambda_m',      c / f_L2_default, ...
                               'codeSigma0_m',  0.45);

            % Determine enabled signal names
            if ~isfield(cfg, 'signals') || ~isfield(cfg.signals, 'enabled')
                enabledNames = {'L1'};
            else
                enabledNames = cfg.signals.enabled;
                if ischar(enabledNames)
                    enabledNames = {enabledNames};
                end
            end

            nSig = numel(enabledNames);
            signals = repmat(defaultL1, nSig, 1);  % pre-allocate with L1 template

            for k = 1:nSig
                nm = enabledNames{k};
                switch upper(nm)
                    case 'L1'
                        if isfield(cfg,'signals') && isfield(cfg.signals,'L1')
                            s = cfg.signals.L1;
                            signals(k) = struct( ...
                                'name',          nm, ...
                                'frequency_Hz',  getfld_(s, 'frequency_Hz', f_L1_default), ...
                                'lambda_m',      getfld_(s, 'lambda_m',     c / f_L1_default), ...
                                'codeSigma0_m',  getfld_(s, 'codeSigma0_m', 0.30));
                        else
                            signals(k) = defaultL1;
                            signals(k).name = nm;
                        end
                    case 'L2'
                        if isfield(cfg,'signals') && isfield(cfg.signals,'L2')
                            s = cfg.signals.L2;
                            signals(k) = struct( ...
                                'name',          nm, ...
                                'frequency_Hz',  getfld_(s, 'frequency_Hz', f_L2_default), ...
                                'lambda_m',      getfld_(s, 'lambda_m',     c / f_L2_default), ...
                                'codeSigma0_m',  getfld_(s, 'codeSigma0_m', 0.45));
                        else
                            signals(k) = defaultL2;
                            signals(k).name = nm;
                        end
                    otherwise
                        % Unknown signal name: use defaults with f_L1
                        warning('SignalUtils:unknownSignal', ...
                            'Unknown signal name ''%s''; using L1 defaults.', nm);
                        signals(k) = defaultL1;
                        signals(k).name = nm;
                end
            end
        end

        function scale = getFrequencyScaleToL1(signal, cfg)
            % getFrequencyScaleToL1  Return (f_L1 / f_signal)^2.
            %
            % Used for ionospheric dispersive scaling between frequencies.
            % For L1: scale = 1.0 exactly.
            %
            % Inputs:
            %   signal   struct   element from getEnabledSignals()
            %   cfg      struct   simulation config (for f_L1 override)

            f_L1 = 1575.42e6;
            if isfield(cfg,'signals') && isfield(cfg.signals,'L1') && ...
                    isfield(cfg.signals.L1,'frequency_Hz')
                f_L1 = cfg.signals.L1.frequency_Hz;
            end
            scale = (f_L1 / signal.frequency_Hz)^2;
        end

    end
end

% ============================================================
%  File-scope helper (not accessible from outside)
% ============================================================
function v = getfld_(s, fname, default)
    if isfield(s, fname)
        v = s.(fname);
    else
        v = default;
    end
end
