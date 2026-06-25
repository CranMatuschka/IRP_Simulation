classdef SignalConfigResolver
    % SignalConfigResolver  Single consistent signal enablement resolver.
    %
    % Stage 79 source of truth:
    %   cfg.signals.names
    %   cfg.signals.enabledMask
    %   cfg.measurements.carrier.enabledByFrequency
    %
    % Legacy aliases are reported but do not override the canonical masks.
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

            % --- canonical signal mask ---
            canonicalResolved = false;
            try
                if isfield(cfg,'signals') && isfield(cfg.signals,'names') && ...
                        isfield(cfg.signals,'enabledMask')
                    names = cfg.signals.names;
                    if ischar(names); names = {names}; end
                    mask = logical(cfg.signals.enabledMask(:)).';
                    if numel(mask) ~= numel(names)
                        error('SignalConfigResolver:maskSize', ...
                            'cfg.signals.enabledMask length (%d) must match cfg.signals.names length (%d).', ...
                            numel(mask), numel(names));
                    end
                    enabled = names(mask);
                    r.enabledSignalIds = enabled;
                    r.l1Enabled = any(strcmpi(enabled,'L1'));
                    r.l2Enabled = any(strcmpi(enabled,'L2'));
                    r.twoFrequencyEnabled = nnz(mask) > 1;
                    r.sourceFields{end+1} = 'signals.names+signals.enabledMask';
                    canonicalResolved = true;
                end
            catch; end

            % --- carrier frequency mask ---
            try
                if isfield(cfg,'measurements') && isfield(cfg.measurements,'carrier') && ...
                        isfield(cfg.measurements.carrier,'enabledByFrequency') && ...
                        isfield(cfg,'signals') && isfield(cfg.signals,'names')
                    names = cfg.signals.names;
                    if ischar(names); names = {names}; end
                    carrierMask = logical(cfg.measurements.carrier.enabledByFrequency(:)).';
                    signalMask = true(1,numel(names));
                    if isfield(cfg.signals,'enabledMask')
                        signalMask = logical(cfg.signals.enabledMask(:)).';
                    end
                    active = signalMask & carrierMask;
                    r.l2CarrierRowsEnabled = any(active & strcmpi(names,'L2'));
                    r.sourceFields{end+1} = 'measurements.carrier.enabledByFrequency';
                end
            catch; end

            % --- legacy aliases: warn on disagreement; only used pre-finalize ---
            try
                legacyTwo = isfield(cfg,'signals') && isfield(cfg.signals,'twoFrequency') && ...
                    isfield(cfg.signals.twoFrequency,'enable') && cfg.signals.twoFrequency.enable;
                legacyL2Rows = isfield(cfg,'measurements') && isfield(cfg.measurements,'carrier') && ...
                    isfield(cfg.measurements.carrier,'l2EkfRows') && ...
                    isfield(cfg.measurements.carrier.l2EkfRows,'enable') && ...
                    cfg.measurements.carrier.l2EkfRows.enable;
                if canonicalResolved
                    if legacyTwo ~= r.twoFrequencyEnabled
                        r.warnings{end+1} = 'signals.twoFrequency.enable disagrees with canonical enabledMask; canonical mask wins.';
                    end
                    if legacyL2Rows ~= r.l2CarrierRowsEnabled
                        r.warnings{end+1} = 'measurements.carrier.l2EkfRows.enable disagrees with carrier.enabledByFrequency; canonical carrier mask wins.';
                    end
                else
                    r.twoFrequencyEnabled = legacyTwo;
                    r.l2Enabled = legacyTwo || legacyL2Rows;
                    r.l2CarrierRowsEnabled = legacyL2Rows;
                    r.sourceFields{end+1} = 'legacy aliases';
                end
            catch; end

            % --- ionosphereFreeCombination diagnostic toggle ---
            try
                if isfield(cfg,'diagnostics') && isfield(cfg.diagnostics,'ionosphereFreeCombination') && ...
                        isfield(cfg.diagnostics.ionosphereFreeCombination,'enable') && ...
                        cfg.diagnostics.ionosphereFreeCombination.enable
                    r.ionosphereFreeDiagnosticEnabled = true;
                    r.sourceFields{end+1} = 'diagnostics.ionosphereFreeCombination.enable';
                end
            catch; end

            % --- explicit signals.enabled list consistency ---
            try
                if isfield(cfg,'signals') && isfield(cfg.signals,'enabled')
                    en = cfg.signals.enabled;
                    l2InList = false;
                    if ischar(en); l2InList = strcmpi(en,'L2');
                    elseif iscell(en); l2InList = any(cellfun(@(x) strcmpi(x,'L2'), en)); end
                    if canonicalResolved && l2InList ~= r.l2Enabled
                        r.warnings{end+1} = ...
                            'cfg.signals.enabled disagrees with canonical enabledMask; canonical mask wins.';
                    elseif ~canonicalResolved && l2InList && ~r.l2Enabled
                        r.l2Enabled = true;
                        r.sourceFields{end+1} = 'signals.enabled';
                    end
                end
            catch; end

            if r.l2Enabled
                r.enabledSignalIds = {'L1','L2'};
            elseif isempty(r.enabledSignalIds)
                r.enabledSignalIds = {'L1'};
            end
        end

        function sigs = carrierSignals(cfg)
            % carrierSignals  Signal structs for resolved enabled signals.
            sigs = revgnss.SignalCatalog.carrierSignalsFromConfig(cfg);
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
