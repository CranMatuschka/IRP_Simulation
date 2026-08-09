classdef SignalCatalog
    % SignalCatalog  Carrier signal catalog for EKF ambiguity state sizing.
    %
    % Thin facade over SignalDefinition. Provides:
    %   carrierSignalsFromConfig(cfg)  — ordered struct array of active carrier EKF signals
    %   nCarrierSignals(cfg)           — number of active carrier EKF signals
    %   signalId(si)                   — signal name for signal index si (1-based)
    %   signalFromIndex(si, cfg)       — signal struct for EKF carrier index si
    %
    % cfg.signals.names plus cfg.signals.enabledMask is the canonical signal
    % list. cfg.measurements.carrier.enabledByFrequency selects which enabled
    % signals enter carrier EKF rows. L1/L2 raw rows are supported in v1;
    % ionosphere-free carrier rows and global integer ambiguity resolution are
    % explicitly unsupported.
    %
    % Usage:
    %   sigs = revgnss.SignalCatalog.carrierSignalsFromConfig(cfg);  % [1x1] or [1x2]
    %   n    = revgnss.SignalCatalog.nCarrierSignals(cfg);           % 1 or 2
    %   id   = revgnss.SignalCatalog.signalId(2);                    % 'L2'

    methods (Static)

        function sigs = carrierSignalsFromConfig(cfg)
            % carrierSignalsFromConfig  Return ordered struct array of active carrier EKF signals.
            if nargin < 1 || isempty(cfg)
                sigs = revgnss.SignalDefinition.get('L1');
                return
            end

            [names, activeMask] = revgnss.SignalCatalog.carrierMask_(cfg);
            idx = find(activeMask);
            if isempty(idx)
                sigs = repmat(revgnss.SignalDefinition.get('L1'), 1, 0);
                return
            end

            % SignalDefinition is keyed by NAME, so get('L1') returns the canonical
            % 1575.42 MHz however the scenario retuned the band -- see resolveBand_.
            sigs = repmat(revgnss.SignalCatalog.resolveBand_( ...
                revgnss.SignalDefinition.get(names{idx(1)}), cfg, idx(1), names), 1, numel(idx));
            for k = 2:numel(idx)
                sigs(k) = revgnss.SignalCatalog.resolveBand_( ...
                    revgnss.SignalDefinition.get(names{idx(k)}), cfg, idx(k), names);
            end
        end

        function n = nCarrierSignals(cfg)
            % nCarrierSignals  Number of active carrier EKF signals.
            n = numel(revgnss.SignalCatalog.carrierSignalsFromConfig(cfg));
        end

        function id = signalId(si)
            % signalId  Signal name string for EKF carrier signal index si (1-based).
            switch si
                case 1;   id = 'L1';
                case 2;   id = 'L2';
                otherwise; id = sprintf('S%d', si);
            end
        end

        function sig = signalFromIndex(si, cfg)
            % signalFromIndex  Signal metadata struct for EKF carrier signal index si.
            sigs = revgnss.SignalCatalog.carrierSignalsFromConfig(cfg);
            if si >= 1 && si <= numel(sigs)
                sig = sigs(si);
            else
                error('SignalCatalog:invalidSignalIndex', ...
                    'Carrier signal index %d is invalid for %d active carrier signal(s).', ...
                    si, numel(sigs));
            end
        end

    end

    methods (Static, Access = private)

        function sig = resolveBand_(sig, cfg, sigIdx, names)
            % resolveBand_  Overlay the RESOLVED band onto a canonical signal struct.
            %
            % SignalDefinition is keyed by NAME. A scenario that retunes a band while keeping
            % the name -- the licence-exempt ladder moves "L1" from 1575.42 MHz to as much as
            % 61.25 GHz -- was silently stamped back to the canonical L-band here, so the
            % carrier EKF rows in CarrierMeasurementBuilder were built at 190.29 mm while the
            % code path (CodeMeasurementBuilder, cfg.signals.frequencyHz(1)) used the real
            % band. Measured across config/ladder/freq/freq009..013: every rung returned
            % 190.29367 mm from this catalog, up to a 39x wavelength error.
            %
            % cfg.signals.frequencyHz/.wavelength_m are ConfigFactory.finalizeConfig's
            % canonical resolved arrays, and finalizeConfig itself builds them from
            % SignalDefinition.get -- so the process-local setFrequencyOverride used by
            % run_oo_v1_freqbattery is already folded into them and still propagates. This
            % only ADDS the JSON-driven path (cfg.signals.<name>.frequency_Hz), which the
            % override mechanism never covered.
            %
            % ionoScaleRelativeToL1 is RECOMPUTED from the resolved pair rather than carried
            % over: SignalDefinition's value is (f_L1_canonical/f_canonical)^2, which for
            % freq011's 5.8/5.2 GHz pair would charge the GPS L1/L2 ratio 1.6469 instead of
            % the true 1.2440.
            %
            % GOLDEN-SAFE: with no scenario retune the resolved arrays hold exactly the
            % canonical doubles, so frequency/wavelength are unchanged and the recomputed
            % (f_L1/f)^2 is the identical expression on the identical inputs -- bit-identical.
            fSig = revgnss.SignalCatalog.resolvedFrequency_(cfg, sigIdx, names);
            if isempty(fSig); fSig = sig.frequency_Hz; end
            if fSig == sig.frequency_Hz
                lamSig = sig.wavelength_m;
            else
                lamSig = 299792458 / fSig;      % c [m/s], as SignalDefinition
            end
            % Prefer finalizeConfig's own wavelength array so this and cfg.signals.<name>
            % .lambda_m can never differ in the last bit.
            if isfield(cfg,'signals') && isfield(cfg.signals,'wavelength_m')
                w = cfg.signals.wavelength_m;
                if isnumeric(w) && numel(w) >= sigIdx && isfinite(w(sigIdx)) && w(sigIdx) > 0
                    lamSig = w(sigIdx);
                end
            end

            % Iono reference is the resolved L1 (first entry when the list has no L1).
            primIdx = find(strcmpi(names, 'L1'), 1);
            if isempty(primIdx); primIdx = 1; end
            fPrim = revgnss.SignalCatalog.resolvedFrequency_(cfg, primIdx, names);
            if isempty(fPrim)
                % Nothing resolved: fall back to the canonical table, as before.
                fPrim = revgnss.SignalDefinition.get(names{primIdx}).frequency_Hz;
            end

            sig.frequency_Hz          = fSig;
            sig.wavelength_m          = lamSig;
            sig.ionoScaleRelativeToL1 = (fPrim / fSig)^2;
        end

        function f = resolvedFrequency_(cfg, sigIdx, names)
            % resolvedFrequency_  Resolved carrier frequency [Hz] for signal SIGIDX, or []
            % when the config carries none (caller falls back to the canonical table).
            %   Canonical array first (finalizeConfig has run), then the per-signal alias
            %   (a raw config that has not been finalised).
            f = [];
            if ~isfield(cfg,'signals'); return; end
            if isfield(cfg.signals,'frequencyHz')
                fa = cfg.signals.frequencyHz;
                if isnumeric(fa) && numel(fa) >= sigIdx && isfinite(fa(sigIdx)) && fa(sigIdx) > 0
                    f = fa(sigIdx);
                    return
                end
            end
            if sigIdx <= numel(names)
                nm = names{sigIdx};
                if isvarname(nm) && isfield(cfg.signals, nm) && ...
                        isfield(cfg.signals.(nm), 'frequency_Hz')
                    fo = cfg.signals.(nm).frequency_Hz;
                    if isnumeric(fo) && isscalar(fo) && isfinite(fo) && fo > 0
                        f = fo;
                    end
                end
            end
        end

        function [names, activeMask] = carrierMask_(cfg)
            names = {'L1'};
            if isfield(cfg,'signals') && isfield(cfg.signals,'names')
                names = cfg.signals.names;
                if ischar(names); names = {names}; end
            end
            n = numel(names);

            signalMask = true(1,n);
            if isfield(cfg,'signals') && isfield(cfg.signals,'enabledMask')
                signalMask = logical(cfg.signals.enabledMask(:)).';
            end
            if numel(signalMask) ~= n
                error('SignalCatalog:signalMaskSize', ...
                    'cfg.signals.enabledMask length (%d) must match cfg.signals.names length (%d).', ...
                    numel(signalMask), n);
            end

            carrierMask = signalMask;
            if isfield(cfg,'measurements') && isfield(cfg.measurements,'carrier') && ...
                    isfield(cfg.measurements.carrier,'enabledByFrequency')
                carrierMask = logical(cfg.measurements.carrier.enabledByFrequency(:)).';
            end
            if numel(carrierMask) ~= n
                error('SignalCatalog:carrierMaskSize', ...
                    'cfg.measurements.carrier.enabledByFrequency length (%d) must match cfg.signals.names length (%d).', ...
                    numel(carrierMask), n);
            end
            activeMask = signalMask & carrierMask;
        end

    end
end
