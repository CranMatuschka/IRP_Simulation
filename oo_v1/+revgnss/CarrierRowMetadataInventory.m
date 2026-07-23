classdef CarrierRowMetadataInventory
    % CarrierRowMetadataInventory  Carrier row metadata inventory.
    %
    % Inventories carrier rows, differential-attitude rows, receiver/tower/signal
    % associations, and ambiguity states from existing metadata.
    % Metadata/inventory only — no L2 EKF, no integer fixing.
    %
    % Usage:
    %   s     = revgnss.CarrierRowMetadataInventory.inventory(out, cfg);
    %   lines = revgnss.CarrierRowMetadataInventory.summaryLines(s);

    methods (Static)

        function s = inventory(out, cfg)
            % inventory  Return carrier row metadata inventory struct.
            s = revgnss.CarrierRowMetadataInventory.blank_();
            s.l2CarrierEkfImplemented  = false;
            s.integerFixingImplemented = false;
            if nargin < 2 || isempty(out) || isempty(cfg)
                s.warnings{end+1} = 'out or cfg empty.'; return
            end
            s.enabled = true;
            try
                if isfield(cfg,'measurements') && isfield(cfg.measurements,'carrierMode')
                    s.carrierMode = cfg.measurements.carrierMode;
                end
                if isfield(cfg,'estimation') && isfield(cfg.estimation,'ambiguityMode')
                    s.ambiguityMode = cfg.estimation.ambiguityMode;
                end
            catch; end

            ri = revgnss.CarrierRowMetadataInventory.rowInventory(out);
            s.carrierRowCount              = ri.carrierRowCount;
            s.differentialAttitudeRowCount = ri.differentialAttitudeRowCount;
            s.diagnosticCarrierRowCount    = ri.diagnosticCarrierRowCount;
            s.ekfCarrierRowCount           = ri.ekfCarrierRowCount;
            s.totalRows                    = ri.totalRows;
            s.rowMetadataAvailable         = ri.rowMetadataAvailable;
            s.rowMetadataCompleteness      = ri.rowMetadataCompleteness;
            s.receiverIds                  = ri.receiverIds;
            s.towerIds                     = ri.towerIds;
            s.signalIds                    = ri.signalIds;
            s.nReceiversObserved           = numel(unique(ri.receiverIds));
            s.nTowersObserved              = numel(unique(ri.towerIds));
            s.nSignalsObserved             = numel(unique(ri.signalIds));
            s.warnings                     = [s.warnings, ri.warnings];

            ai = revgnss.CarrierRowMetadataInventory.ambiguityInventory(out, cfg);
            s.ambiguityStateCount        = ai.ambiguityStateCount;
            s.ambiguityStateCountSource  = ai.source;
            s.ambiguityMetadataAvailable = isfinite(ai.ambiguityStateCount) && ...
                ~strcmp(ai.source,'unavailable');
            s.warnings                   = [s.warnings, ai.warnings];

            try
                s.l2RowsPresent = revgnss.SignalCatalog.nCarrierSignals(cfg) > 1;
            catch
                s.l2RowsPresent = false;
            end
            s.available     = s.rowMetadataAvailable;
            s.classification = revgnss.CarrierRowMetadataInventory.classify_(s);
            s.limitations    = revgnss.CarrierRowMetadataInventory.limitations_(s);
        end

        function ri = rowInventory(out)
            % rowInventory  Extract carrier row counts from existing metadata.
            ri.carrierRowCount             = NaN;
            ri.differentialAttitudeRowCount = NaN;
            ri.diagnosticCarrierRowCount    = NaN;
            ri.ekfCarrierRowCount           = NaN;
            ri.totalRows                    = NaN;
            ri.rowMetadataAvailable         = false;
            ri.rowMetadataCompleteness      = 'none';
            ri.receiverIds = {}; ri.towerIds = {}; ri.signalIds = {};
            ri.warnings    = {};
            try
                sm = out.summary;
                if isfield(sm,'totalCarrierRows')
                    ri.carrierRowCount         = sm.totalCarrierRows;
                    ri.rowMetadataAvailable    = true;
                    ri.rowMetadataCompleteness = 'summary-level';
                end
                if isfield(sm,'totalDiffAttRows')
                    ri.differentialAttitudeRowCount = sm.totalDiffAttRows;
                end
                if isfield(sm,'maxEKFRows') && isfinite(sm.maxEKFRows)
                    ri.totalRows = sm.maxEKFRows;
                end
                diagOnly = isfield(sm,'carrierDiagnosticOnly') && sm.carrierDiagnosticOnly;
                inEkf    = isfield(sm,'carrierUsedInEkf')    && sm.carrierUsedInEkf;
                if diagOnly
                    ri.diagnosticCarrierRowCount = ri.carrierRowCount;
                    ri.ekfCarrierRowCount        = 0;
                elseif inEkf
                    ri.ekfCarrierRowCount        = ri.carrierRowCount;
                    ri.diagnosticCarrierRowCount = 0;
                end
            catch ex
                ri.warnings{end+1} = ['rowInventory: ' ex.message];
            end
            ri.warnings{end+1} = ...
                'Per-row receiver/tower/signal IDs unavailable in current architecture.';
        end

        function ai = ambiguityInventory(out, cfg)
            % ambiguityInventory  Derive ambiguity state count; prefer state-map metadata.
            ai.ambiguityStateCount = NaN;
            ai.source              = 'unavailable';
            ai.warnings            = {};
            try
                sm = out.summary;
                % Prefer state-map export if present.
                if isfield(sm,'ambiguityStateMetadata') && ...
                        isfield(sm.ambiguityStateMetadata,'available') && ...
                        sm.ambiguityStateMetadata.available
                    ai.ambiguityStateCount = sm.ambiguityStateMetadata.nAmbiguities;
                    ai.source              = 'state-map';
                    return
                end
                % Fallback: summary estimate from topology.
                mode = '';
                if isfield(cfg,'estimation') && isfield(cfg.estimation,'ambiguityMode')
                    mode = cfg.estimation.ambiguityMode;
                end
                if isfield(sm,'nTowers') && isfield(sm,'nReceivers')
                    nT = sm.nTowers; nR = sm.nReceivers;
                    if strcmp(mode,'floatPerTowerReceiverSignal')
                        ai.ambiguityStateCount = nT * nR;
                    else
                        ai.ambiguityStateCount = nT;
                    end
                    ai.source = 'summary-estimate';
                    ai.warnings{end+1} = ...
                        'Ambiguity count is a summary estimate; not from EKF state map.';
                end
            catch ex
                ai.warnings{end+1} = ['ambiguityInventory: ' ex.message];
            end
        end

        function lines = summaryLines(s)
            % summaryLines  Formatted cell array for report embedding.
            lines = {};
            if ~s.enabled
                lines{end+1} = 'CarrierRowMetadataInventory: unavailable'; return
            end
            lines{end+1} = sprintf('Classification          : %s', s.classification);
            lines{end+1} = sprintf('CarrierMode             : %s', s.carrierMode);
            lines{end+1} = sprintf('AmbiguityMode           : %s', s.ambiguityMode);
            lines{end+1} = sprintf('RowMetadataCompleteness : %s', s.rowMetadataCompleteness);
            if isfinite(s.carrierRowCount)
                lines{end+1} = sprintf('CarrierRows             : %d', s.carrierRowCount);
            else
                lines{end+1} = 'CarrierRows             : unavailable';
            end
            if isfinite(s.differentialAttitudeRowCount)
                lines{end+1} = sprintf('DiffAttRows             : %d', s.differentialAttitudeRowCount);
            end
            if isfinite(s.ekfCarrierRowCount)
                lines{end+1} = sprintf('EKF carrier rows        : %d', s.ekfCarrierRowCount);
            end
            if isfinite(s.diagnosticCarrierRowCount)
                lines{end+1} = sprintf('Diagnostic carrier rows : %d', s.diagnosticCarrierRowCount);
            end
            if s.ambiguityMetadataAvailable
                lines{end+1} = sprintf('AmbiguityStates         : %d (%s)', ...
                    s.ambiguityStateCount, s.ambiguityStateCountSource);
            else
                lines{end+1} = 'AmbiguityStates         : unavailable';
            end
            lines{end+1} = sprintf('L2CarrierEKFImpl        : %s', mat2str(s.l2CarrierEkfImplemented));
            lines{end+1} = sprintf('IntegerFixingImpl       : %s', mat2str(s.integerFixingImplemented));
        end

    end

    methods (Static, Access = private)

        function cls = classify_(s)
            if ~s.rowMetadataAvailable;               cls = 'unavailable';           return; end
            if ~isnan(s.diagnosticCarrierRowCount) && ...
               s.diagnosticCarrierRowCount > 0 && ...
               (isnan(s.ekfCarrierRowCount) || s.ekfCarrierRowCount == 0)
                                                      cls = 'diagnostic-only';       return; end
            if strcmp(s.rowMetadataCompleteness,'summary-level') && ...
               isempty(s.receiverIds)
                                                      cls = 'summary-only';          return; end
            if ~isempty(s.receiverIds) && ~isempty(s.towerIds) && ~isempty(s.signalIds)
                                                      cls = 'row-metadata-complete'; return; end
            if ~isempty(s.receiverIds) || ~isempty(s.towerIds)
                                                      cls = 'row-metadata-partial';  return; end
            cls = 'summary-only';
        end

        function lims = limitations_(s)
            lims = {
                'Per-row receiver/tower/signal IDs not available in current architecture.'
                'L2 carrier EKF rows are selected by cfg.measurements.carrier.enabledByFrequency after canonical signal-mask finalization.'
                'Integer ambiguity fixing not implemented in v1.'
            };
            if ~isnan(s.ambiguityStateCount) && strcmp(s.ambiguityStateCountSource,'summary-estimate')
                lims{end+1} = 'Ambiguity count is a summary estimate, not from EKF state map.';
            end
        end

        function s = blank_()
            s.enabled=false; s.available=false; s.classification='unavailable';
            s.totalRows=NaN; s.carrierRowCount=NaN; s.differentialAttitudeRowCount=NaN;
            s.diagnosticCarrierRowCount=NaN; s.ekfCarrierRowCount=NaN;
            s.receiverIds={}; s.towerIds={}; s.signalIds={};
            s.nReceiversObserved=0; s.nTowersObserved=0; s.nSignalsObserved=0;
            s.rowMetadataAvailable=false; s.rowMetadataCompleteness='none';
            s.ambiguityMetadataAvailable=false; s.ambiguityStateCount=NaN;
            s.ambiguityStateCountSource='unavailable'; s.ambiguityMode='unknown';
            s.carrierMode='unknown'; s.l2RowsPresent=false;
            s.l2CarrierEkfImplemented=false; s.integerFixingImplemented=false;
            s.warnings={}; s.limitations={};
        end

    end
end
