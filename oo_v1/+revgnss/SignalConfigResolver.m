classdef SignalConfigResolver
    % SignalConfigResolver  Stage 44 single consistent L1/L2 enablement resolver.
    %
    % Resolves whether L2 is enabled from any of these config fields:
    %   cfg.signals.twoFrequency.enable
    %   cfg.measurements.carrier.l2EkfRows.enable
    %   cfg.diagnostics.l2CarrierArchitecture.enable
    %   cfg.diagnostics.ionosphereFreeCombination.enable + twoFrequency
    %   cfg.signals.enabled (explicit list)
    %
    % Usage:
    %   r    = revgnss.SignalConfigResolver.resolve(cfg);
    %   sigs = revgnss.SignalConfigResolver.carrierSignals(cfg);
    %   ok   = revgnss.SignalConfigResolver.hasL2(cfg);
    %   lns  = revgnss.SignalConfigResolver.summaryLines(r);

    methods (Static)

        function r = resolve(cfg)
            % resolve  Return struct describing resolved signal enablement.
            r.enabledSignalIds            = {'L1'};
            r.l1Enabled                   = true;
            r.l2Enabled                   = false;
            r.twoFrequencyEnabled         = false;
            r.l2CarrierRowsEnabled        = false;
            r.ionosphereFreeDiagnosticEnabled = false;
            r.sourceFields                = {};
            r.warnings                    = {};

            if nargin < 1 || isempty(cfg)
                r.warnings{end+1} = 'cfg empty; defaulting to L1-only.'; return
            end

            % --- twoFrequency toggle ---
            try
                if isfield(cfg,'signals') && isfield(cfg.signals,'twoFrequency') && ...
                        isfield(cfg.signals.twoFrequency,'enable') && ...
                        cfg.signals.twoFrequency.enable
                    r.twoFrequencyEnabled = true;
                    r.l2Enabled = true;
                    r.sourceFields{end+1} = 'signals.twoFrequency.enable';
                end
            catch; end

            % --- l2EkfRows toggle ---
            try
                if isfield(cfg,'measurements') && isfield(cfg.measurements,'carrier') && ...
                        isfield(cfg.measurements.carrier,'l2EkfRows') && ...
                        isfield(cfg.measurements.carrier.l2EkfRows,'enable') && ...
                        cfg.measurements.carrier.l2EkfRows.enable
                    r.l2CarrierRowsEnabled = true;
                    r.l2Enabled = true;
                    r.sourceFields{end+1} = 'measurements.carrier.l2EkfRows.enable';
                end
            catch; end

            % --- l2CarrierArchitecture diagnostic toggle ---
            try
                if isfield(cfg,'diagnostics') && isfield(cfg.diagnostics,'l2CarrierArchitecture') && ...
                        isfield(cfg.diagnostics.l2CarrierArchitecture,'enable') && ...
                        cfg.diagnostics.l2CarrierArchitecture.enable
                    r.l2Enabled = true;
                    r.sourceFields{end+1} = 'diagnostics.l2CarrierArchitecture.enable';
                end
            catch; end

            % --- ionosphereFreeCombination toggle (only with twoFrequency) ---
            try
                if isfield(cfg,'diagnostics') && isfield(cfg.diagnostics,'ionosphereFreeCombination') && ...
                        isfield(cfg.diagnostics.ionosphereFreeCombination,'enable') && ...
                        cfg.diagnostics.ionosphereFreeCombination.enable
                    r.ionosphereFreeDiagnosticEnabled = true;
                    if r.twoFrequencyEnabled
                        r.sourceFields{end+1} = 'diagnostics.ionosphereFreeCombination.enable+twoFrequency';
                    end
                end
            catch; end

            % --- explicit signals.enabled list ---
            try
                if isfield(cfg,'signals') && isfield(cfg.signals,'enabled')
                    en = cfg.signals.enabled;
                    l2InList = false;
                    if ischar(en); l2InList = strcmpi(en,'L2');
                    elseif iscell(en); l2InList = any(cellfun(@(x) strcmpi(x,'L2'), en)); end
                    if l2InList && ~r.l2Enabled
                        r.l2Enabled = true;
                        r.sourceFields{end+1} = 'signals.enabled';
                    end
                    % Warn if explicit list conflicts with twoFrequency
                    if ~l2InList && r.twoFrequencyEnabled
                        r.warnings{end+1} = ...
                            'cfg.signals.enabled does not contain L2 but twoFrequency.enable=true; resolver uses twoFrequency.';
                    end
                end
            catch; end

            if r.l2Enabled
                r.enabledSignalIds = {'L1','L2'};
            end
        end

        function sigs = carrierSignals(cfg)
            % carrierSignals  Signal structs for resolved enabled signals.
            r = revgnss.SignalConfigResolver.resolve(cfg);
            sigs = revgnss.SignalDefinition.get('L1');
            if r.l2Enabled
                sigs(2) = revgnss.SignalDefinition.get('L2');
            end
        end

        function ok = hasL2(cfg)
            % hasL2  True if L2 is enabled by any config field.
            ok = revgnss.SignalConfigResolver.resolve(cfg).l2Enabled;
        end

        function lines = summaryLines(r)
            % summaryLines  Concise cell array for report embedding.
            lines = {};
            lines{end+1} = sprintf('Enabled signals   : %s', strjoin(r.enabledSignalIds,', '));
            lines{end+1} = sprintf('L2 enabled        : %s', mat2str(r.l2Enabled));
            lines{end+1} = sprintf('twoFrequency      : %s', mat2str(r.twoFrequencyEnabled));
            lines{end+1} = sprintf('l2CarrierRows     : %s', mat2str(r.l2CarrierRowsEnabled));
            if ~isempty(r.sourceFields)
                lines{end+1} = sprintf('Source fields     : %s', strjoin(r.sourceFields, '; '));
            end
            if ~isempty(r.warnings)
                for i = 1:numel(r.warnings)
                    lines{end+1} = sprintf('WARNING           : %s', r.warnings{i});
                end
            end
        end

    end
end
