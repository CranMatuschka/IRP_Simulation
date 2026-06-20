classdef DiagnosticPluginRegistry
    % DiagnosticPluginRegistry  Central registry for optional diagnostic collectors.
    %
    % Stage 55 introduces this registry so future stages can register optional
    % diagnostics without adding procedural blocks directly to ReportRunner.
    % Existing Stage 52-54 collection blocks in ReportRunner are preserved for
    % safety; full migration to plugin-only collection is deferred to a future
    % stage (see StageHistory.implementedItems for the migration note).
    %
    % API:
    %   plugins = revgnss.DiagnosticPluginRegistry.list(cfg)
    %   summary = revgnss.DiagnosticPluginRegistry.collectAll(summary, sim, cfg)
    %   names   = revgnss.DiagnosticPluginRegistry.names(cfg)
    %
    % Plugin struct fields:
    %   name        — identifier string
    %   stage       — originating stage number
    %   enabled     — logical, derived from cfg
    %   description — human-readable string
    %   collectFcn  — @(summary, sim, cfg) → status struct (metadata only)
    %
    % Stage 55 collectFcn behaviour:
    %   Each plugin reads fields already present in summary (populated by the
    %   existing Stage 52-54 ReportRunner blocks) and returns a compact status
    %   struct. The main summary fields are never overwritten.

    methods (Static)

        function plugins = list(cfg)
            % list  Return cell array of plugin descriptor structs.
            plugins = {};

            % Stage 52: carrier arc evidence.
            p52.name        = 'carrierArcEvidence';
            p52.stage       = 52;
            p52.description = 'Carrier arc and cycle-slip evidence export (Stage 52)';
            try; p52.enabled = logical(cfg.diagnostics.carrierArcEvidence.enable); catch; p52.enabled = false; end
            p52.collectFcn  = @(smry,~,~) revgnss.DiagnosticPluginRegistry.statusCarrierArc_(smry);
            plugins{end+1}  = p52;

            % Stage 53: arc-separated float ambiguities.
            p53.name        = 'arcSeparatedAmbiguities';
            p53.stage       = 53;
            p53.description = 'Arc-separated float ambiguity metadata (Stage 53)';
            try; p53.enabled = logical(cfg.diagnostics.arcSeparatedAmbiguities.enable); catch; p53.enabled = false; end
            p53.collectFcn  = @(smry,~,~) revgnss.DiagnosticPluginRegistry.statusArcSep_(smry);
            plugins{end+1}  = p53;

            % Stage 54: enforced arc-consistent carrier IF combinations.
            p54.name        = 'enforcedCarrierArcConsistency';
            p54.stage       = 54;
            p54.description = 'Enforced arc-consistent carrier IF combinations (Stage 54)';
            try; p54.enabled = logical(cfg.estimator.enforceCarrierArcConsistency.enable); catch; p54.enabled = false; end
            p54.collectFcn  = @(smry,~,~) revgnss.DiagnosticPluginRegistry.statusArcEnf_(smry);
            plugins{end+1}  = p54;
        end

        function summary = collectAll(summary, sim, cfg)
            % collectAll  Run enabled plugin collectFcns; add summary.diagnosticPlugins.
            %
            % Existing summary fields are NEVER overwritten. Plugins report status
            % of fields already in summary. On error: rethrows under 'error' policy;
            % records error struct under 'disableWithWarning'.
            plugins  = revgnss.DiagnosticPluginRegistry.list(cfg);
            pResults = struct();
            enabled  = {};
            policy_  = 'disableWithWarning';
            try; policy_ = cfg.validation.unsupportedFeaturePolicy; catch; end

            for k = 1:numel(plugins)
                p = plugins{k};
                if ~p.enabled; continue; end
                enabled{end+1} = p.name; %#ok<AGROW>
                try
                    pResults.(p.name) = p.collectFcn(summary, sim, cfg);
                catch ex
                    if strcmp(policy_,'error'); rethrow(ex); end
                    pResults.(p.name) = struct('name',p.name,'error',ex.message,'available',false);
                end
            end

            summary.diagnosticPlugins.enabledNames  = enabled;
            summary.diagnosticPlugins.count         = numel(enabled);
            summary.diagnosticPlugins.results       = pResults;
            summary.diagnosticPlugins.migrationNote = ...
                'Stage55: existing Stage52-54 ReportRunner blocks preserved; plugin-only migration deferred.';
        end

        function nameList = names(cfg)
            % names  Return cell array of enabled plugin name strings.
            plugins  = revgnss.DiagnosticPluginRegistry.list(cfg);
            nameList = {};
            for k = 1:numel(plugins)
                if plugins{k}.enabled; nameList{end+1} = plugins{k}.name; end %#ok<AGROW>
            end
        end

    end

    methods (Static, Access = private)

        function s = statusCarrierArc_(summary)
            s.name      = 'carrierArcEvidence';
            s.available = isfield(summary,'carrierArcEvidenceAvailable') && ...
                          logical(summary.carrierArcEvidenceAvailable);
            s.source    = 'Stage52-ReportRunner-block';
            if isfield(summary,'carrierArcNSlipEvents')
                s.nSlipEvents = summary.carrierArcNSlipEvents;
            end
        end

        function s = statusArcSep_(summary)
            s.name      = 'arcSeparatedAmbiguities';
            s.available = isfield(summary,'ambiguityArcMetadataAvailable') && ...
                          logical(summary.ambiguityArcMetadataAvailable);
            s.source    = 'Stage53-ReportRunner-block';
            if isfield(summary,'ambiguityArcUniqueCount')
                s.nUniqueArcIds = summary.ambiguityArcUniqueCount;
            end
        end

        function s = statusArcEnf_(summary)
            s.name      = 'enforcedCarrierArcConsistency';
            s.available = isfield(summary,'carrierArcConsistencyEnforced');
            s.enforced  = s.available && logical(summary.carrierArcConsistencyEnforced);
            s.source    = 'Stage54-ReportRunner-block';
            if isfield(summary,'carrierIonoFreeArcSkippedPairs')
                s.arcSkippedPairs = summary.carrierIonoFreeArcSkippedPairs;
            end
        end

    end
end
