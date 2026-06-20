classdef CarrierArcEvidence
    % CarrierArcEvidence  Stage 52 carrier arc and cycle-slip evidence.
    %
    % Exports compact arc evidence from CarrierTrackManager: which arcs exist,
    % arc durations, slip/reset counts, valid carrier row counts.
    % No integer fixing, no LAMBDA/MLAMBDA. Diagnostic and evidence only.
    % Arc lengths reflect the current continuous arc per track (since last slip).
    %
    % Usage:
    %   ae    = revgnss.CarrierArcEvidence.fromTrackManager(tm, cfg);
    %   ae    = revgnss.CarrierArcEvidence.fromSummary(summary);
    %   lines = revgnss.CarrierArcEvidence.summaryLines(ae);

    methods (Static)

        function ae = fromTrackManager(tm, cfg)
            % fromTrackManager  Extract arc evidence directly from track manager.
            ae = revgnss.CarrierArcEvidence.blank_();
            if isempty(tm) || ~isa(tm, 'revgnss.CarrierTrackManager')
                ae.warnings{end+1} = 'Track manager unavailable or wrong type.'; return
            end
            dt_s = revgnss.CarrierArcEvidence.dtFromCfg_(cfg);
            try
                ev = tm.getArcEvidence(dt_s);
                ae.available          = ev.available;
                ae.nActiveTracks      = ev.nActiveTracks;
                ae.nArcs              = ev.nArcs;
                ae.nSlipEvents        = ev.nSlipEvents;
                ae.totalCarrierEpochs = ev.totalCarrierEpochs;
                ae.minArcLength_s     = ev.minArcLength_s;
                ae.meanArcLength_s    = ev.meanArcLength_s;
                ae.maxArcLength_s     = ev.maxArcLength_s;
                ae.classification     = revgnss.CarrierArcEvidence.classify_(ae);
            catch ex
                ae.warnings{end+1} = ['getArcEvidence: ' ex.message];
            end
        end

        function ae = fromSummary(summary)
            % fromSummary  Reconstruct arc evidence from compact summary fields.
            ae = revgnss.CarrierArcEvidence.blank_();
            if ~isstruct(summary); return; end
            try
                if isfield(summary,'carrierArcEvidenceAvailable') && ...
                        summary.carrierArcEvidenceAvailable
                    ae.available = true;
                    if isfield(summary,'carrierArcNActiveTracks')
                        ae.nActiveTracks      = summary.carrierArcNActiveTracks;   end
                    if isfield(summary,'carrierArcNArcs')
                        ae.nArcs              = summary.carrierArcNArcs;           end
                    if isfield(summary,'carrierArcNSlipEvents')
                        ae.nSlipEvents        = summary.carrierArcNSlipEvents;     end
                    if isfield(summary,'carrierArcTotalEpochs')
                        ae.totalCarrierEpochs = summary.carrierArcTotalEpochs;     end
                    if isfield(summary,'carrierArcMinLength_s')
                        ae.minArcLength_s     = summary.carrierArcMinLength_s;     end
                    if isfield(summary,'carrierArcMeanLength_s')
                        ae.meanArcLength_s    = summary.carrierArcMeanLength_s;    end
                    if isfield(summary,'carrierArcMaxLength_s')
                        ae.maxArcLength_s     = summary.carrierArcMaxLength_s;     end
                    if isfield(summary,'carrierArcEvidenceClassification')
                        ae.classification = summary.carrierArcEvidenceClassification;
                    else
                        ae.classification = revgnss.CarrierArcEvidence.classify_(ae);
                    end
                end
            catch ex
                ae.warnings{end+1} = ['fromSummary: ' ex.message];
            end
        end

        function lines = summaryLines(ae)
            % summaryLines  Formatted cell array for report embedding.
            lines = {};
            if ~ae.available
                lines{end+1} = 'CarrierArcEvidence: unavailable'; return
            end
            lines{end+1} = sprintf('Classification   : %s', ae.classification);
            lines{end+1} = sprintf('Active tracks    : %d', ae.nActiveTracks);
            lines{end+1} = sprintf('Total arcs       : %d', ae.nArcs);
            if isfinite(ae.nSlipEvents)
                lines{end+1} = sprintf('Slip events      : %d', ae.nSlipEvents);
            end
            lines{end+1} = sprintf('Total epochs     : %d', ae.totalCarrierEpochs);
            if isfinite(ae.minArcLength_s)
                lines{end+1} = sprintf('Min arc (s)      : %.1f', ae.minArcLength_s);
                lines{end+1} = sprintf('Mean arc (s)     : %.1f', ae.meanArcLength_s);
                lines{end+1} = sprintf('Max arc (s)      : %.1f', ae.maxArcLength_s);
            end
            lines{end+1} = 'Integer fixing   : false (not implemented in v1)';
        end

    end

    methods (Static, Access = private)

        function ae = blank_()
            ae.available          = false;
            ae.classification     = 'unavailable';
            ae.nActiveTracks      = 0;
            ae.nArcs              = 0;
            ae.nSlipEvents        = NaN;
            ae.totalCarrierEpochs = 0;
            ae.minArcLength_s     = NaN;
            ae.meanArcLength_s    = NaN;
            ae.maxArcLength_s     = NaN;
            ae.warnings           = {};
            ae.limitations        = {
                'Integer ambiguity fixing not implemented in v1.'
                'Arc evidence is diagnostic only; no integer resolution criterion.'
                'Arc lengths reflect current continuous arc per track only.'
            };
        end

        function cls = classify_(ae)
            if ~ae.available;     cls = 'unavailable'; return; end
            if ae.nArcs == 0;     cls = 'no-arcs';     return; end
            if ~isfinite(ae.nSlipEvents) || ae.nSlipEvents == 0
                cls = 'arcs-exported';
            else
                cls = 'arcs-exported-with-slips';
            end
        end

        function dt_s = dtFromCfg_(cfg)
            dt_s = 1.0;
            try
                if isfield(cfg,'simulation') && isfield(cfg.simulation,'dt_s')
                    dt_s = cfg.simulation.dt_s;
                elseif isfield(cfg,'dt_s')
                    dt_s = cfg.dt_s;
                end
            catch; end
        end

    end
end
