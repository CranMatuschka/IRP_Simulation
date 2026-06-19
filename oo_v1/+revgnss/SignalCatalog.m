classdef SignalCatalog
    % SignalCatalog  Stage 42 carrier signal catalog for EKF ambiguity state sizing.
    %
    % Thin facade over SignalDefinition. Provides:
    %   carrierSignalsFromConfig(cfg)  — ordered struct array of active carrier EKF signals
    %   nCarrierSignals(cfg)           — number of active carrier EKF signals (1 or 2)
    %   signalId(si)                   — 'L1' or 'L2' for signal index si (1-based)
    %   signalFromIndex(si, cfg)       — signal struct for EKF carrier index si
    %
    % Only L1 and L2 are in scope for v1. L5 is not supported.
    % Ionosphere-free carrier combination and integer ambiguity resolution
    % are not implemented in v1.
    %
    % Usage:
    %   sigs = revgnss.SignalCatalog.carrierSignalsFromConfig(cfg);  % [1x1] or [1x2]
    %   n    = revgnss.SignalCatalog.nCarrierSignals(cfg);           % 1 or 2
    %   id   = revgnss.SignalCatalog.signalId(2);                    % 'L2'

    methods (Static)

        function sigs = carrierSignalsFromConfig(cfg)
            % carrierSignalsFromConfig  Return ordered struct array of active carrier EKF signals.
            % Always includes L1. Includes L2 if cfg.measurements.carrier.l2EkfRows.enable=true.
            sigs = revgnss.SignalDefinition.get('L1');
            if revgnss.SignalCatalog.l2EkfEnabled_(cfg)
                sigs(2) = revgnss.SignalDefinition.get('L2');
            end
        end

        function n = nCarrierSignals(cfg)
            % nCarrierSignals  Number of active carrier EKF signals (1 or 2).
            n = 1;
            if revgnss.SignalCatalog.l2EkfEnabled_(cfg)
                n = 2;
            end
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
                sig = revgnss.SignalDefinition.get('L1');
            end
        end

    end

    methods (Static, Access = private)

        function ok = l2EkfEnabled_(cfg)
            ok = isfield(cfg,'measurements') && ...
                 isfield(cfg.measurements,'carrier') && ...
                 isfield(cfg.measurements.carrier,'l2EkfRows') && ...
                 isfield(cfg.measurements.carrier.l2EkfRows,'enable') && ...
                 cfg.measurements.carrier.l2EkfRows.enable;
        end

    end
end
