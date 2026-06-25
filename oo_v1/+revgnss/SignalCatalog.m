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

            sigs = repmat(revgnss.SignalDefinition.get(names{idx(1)}), 1, numel(idx));
            for k = 2:numel(idx)
                sigs(k) = revgnss.SignalDefinition.get(names{idx(k)});
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
