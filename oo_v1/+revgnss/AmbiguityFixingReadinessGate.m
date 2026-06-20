classdef AmbiguityFixingReadinessGate
    % AmbiguityFixingReadinessGate  Stage 50/51 ambiguity fixing readiness gate.
    % Stage 51: collects ALL evidence without early return; arcQuality and
    % residualConsistency are public; explicit blockerList and readinessScore.
    % Hard facts always false: phaseBiasProductsAvailable, integerStrategyAvailable,
    %   integerFixingImplemented, lambdaImplemented, falseFixRiskControlled.

    methods (Static)

        function s = assess(summary, cfg)
            s = revgnss.AmbiguityFixingReadinessGate.blank_();
            s.requested = revgnss.AmbiguityFixingReadinessGate.enabled_(cfg);
            if ~s.requested; return; end
            s.enabled = true;
            % 1. Ambiguity pair metadata (Stage 48)
            try
                if isfield(summary,'carrierIfAmbiguityPairCount') && isnumeric(summary.carrierIfAmbiguityPairCount)
                    s.pairCount = summary.carrierIfAmbiguityPairCount;
                end
                if isfield(summary,'carrierIfPairMetadataAvailable') && ...
                        logical(summary.carrierIfPairMetadataAvailable) && s.pairCount > 0
                    s.ambiguityMetadataAvailable = true;
                end
            catch ex; s.warnings{end+1} = ['metadata: ' ex.message]; end
            % 2. Ambiguity covariance (Stage 41)
            try
                if isfield(summary,'ambiguityCovarianceSummary') && ...
                        isstruct(summary.ambiguityCovarianceSummary) && ...
                        isfield(summary.ambiguityCovarianceSummary,'Pamb') && ...
                        ~isempty(summary.ambiguityCovarianceSummary.Pamb)
                    s.ambiguityCovarianceAvailable = true;
                end
            catch ex; s.warnings{end+1} = ['covariance: ' ex.message]; end
            % 3. Carrier IF traceability (Stage 48)
            try
                if isfield(summary,'carrierIfPairMetadataAvailable')
                    s.carrierIonoFreeTraceabilityAvailable = logical(summary.carrierIfPairMetadataAvailable);
                end
            catch; end
            % 4. WL/NL diagnostics (Stage 49)
            try
                wlClass = 'disabled';
                if isfield(summary,'wideLaneNarrowLaneClassification')
                    wlClass = summary.wideLaneNarrowLaneClassification;
                end
                s.wideLaneNarrowLaneAvailable = strcmp(wlClass,'active-float-diagnostics');
                if isfield(summary,'wideLaneSigmaCyclesMean');   s.wideLaneSigmaCyclesMean  = summary.wideLaneSigmaCyclesMean;  end %#ok<SEPEX>
                if isfield(summary,'narrowLaneSigmaCyclesMean'); s.narrowLaneSigmaCyclesMean = summary.narrowLaneSigmaCyclesMean; end %#ok<SEPEX>
                if isfield(summary,'wideLaneNarrowLaneMaxAbsCorr'); s.maxAbsWideNarrowCorr = summary.wideLaneNarrowLaneMaxAbsCorr; end %#ok<SEPEX>
            catch ex; s.warnings{end+1} = ['wlnl: ' ex.message]; end
            % 5. Arc quality
            aq = revgnss.AmbiguityFixingReadinessGate.arcQuality(summary, cfg);
            s.cycleSlipMetadataAvailable = aq.available;
            s.slipCount                  = aq.slipCount;
            s.minArcLength_s             = aq.minArcLength_s;
            s.arcQualityClassification   = aq.classification;
            s.warnings                   = [s.warnings, aq.warnings];
            % 6. Residual/NIS
            rc = revgnss.AmbiguityFixingReadinessGate.residualConsistency(summary, cfg);
            s.residualDiagnosticsAvailable = rc.available;
            s.residualRms_m = rc.residualRms_m;
            s.nisMean       = rc.nisMean;
            s.expectedNis   = rc.expectedNis;
            s.warnings      = [s.warnings, rc.warnings];
            % 7. Stage 53/54: arc-separated ambiguity metadata blockers.
            try
                if isfield(summary,'ambiguityArcRowsMissingArcId') && ...
                        isnumeric(summary.ambiguityArcRowsMissingArcId)
                    s.ambiguityArcRowsMissingArcId = summary.ambiguityArcRowsMissingArcId;
                end
                if isfield(summary,'carrierIonoFreeArcInconsistentPairs') && ...
                        isnumeric(summary.carrierIonoFreeArcInconsistentPairs)
                    s.carrierIonoFreeArcInconsistentPairs = summary.carrierIonoFreeArcInconsistentPairs;
                end
                % Stage 54: arc-skipped pairs and WL/NL arc-blocked flag.
                if isfield(summary,'carrierIonoFreeArcSkippedPairs') && ...
                        isnumeric(summary.carrierIonoFreeArcSkippedPairs)
                    s.carrierIonoFreeArcSkippedPairs = summary.carrierIonoFreeArcSkippedPairs;
                end
                if isfield(summary,'wideLaneNarrowLaneArcBlocked') && ...
                        logical(summary.wideLaneNarrowLaneArcBlocked)
                    s.wideLaneNarrowLaneArcBlocked = true;
                end
            catch; end
            % Score, blockers, classification
            s.readinessScore = double(s.ambiguityMetadataAvailable) + ...
                double(s.ambiguityCovarianceAvailable) + ...
                double(s.carrierIonoFreeTraceabilityAvailable) + ...
                double(s.wideLaneNarrowLaneAvailable) + ...
                double(s.cycleSlipMetadataAvailable) + ...
                double(s.residualDiagnosticsAvailable);
            s.blockers       = revgnss.AmbiguityFixingReadinessGate.blockerList(s);
            s.classification = revgnss.AmbiguityFixingReadinessGate.classify_(s);
            % Populate Stage 50 report alias fields.
            s.pairMetadataAvailable           = s.ambiguityMetadataAvailable;
            s.covarianceAvailable             = s.ambiguityCovarianceAvailable;
            s.wideLaneNarrowLaneReady         = s.wideLaneNarrowLaneAvailable;
            s.wideLaneNarrowLaneClassification = ...
                revgnss.AmbiguityFixingReadinessGate.wlnlClass_(s);
            s.arcQualityStatus                = s.arcQualityClassification;
            s.residualConsistencyStatus       = ...
                revgnss.AmbiguityFixingReadinessGate.residualClass_(s);
        end

        function aq = arcQuality(summary, cfg)
            aq.available = false; aq.slipCount = NaN; aq.minArcLength_s = NaN;
            aq.classification = 'unavailable'; aq.warnings = {};
            slipOn = false;
            try
                if isfield(cfg,'measurements') && isfield(cfg.measurements,'carrier') && ...
                        isfield(cfg.measurements.carrier,'slipDetection') && ...
                        isfield(cfg.measurements.carrier.slipDetection,'enable') && ...
                        logical(cfg.measurements.carrier.slipDetection.enable)
                    slipOn = true;
                end
            catch; end
            if ~slipOn; return; end
            % Stage 52: prefer carrierArcEvidence compact fields when available.
            if isfield(summary,'carrierArcEvidenceAvailable') && summary.carrierArcEvidenceAvailable
                aq.available = true;
                if isfield(summary,'carrierArcNSlipEvents') && isfinite(summary.carrierArcNSlipEvents)
                    aq.slipCount = summary.carrierArcNSlipEvents;
                end
                if isfield(summary,'carrierArcMinLength_s') && isfinite(summary.carrierArcMinLength_s)
                    aq.minArcLength_s = summary.carrierArcMinLength_s;
                end
                if ~isnan(aq.slipCount) && aq.slipCount == 0;     aq.classification = 'no-slips-reported';
                elseif ~isnan(aq.slipCount) && aq.slipCount > 0;  aq.classification = 'slips-present';
                else;                                               aq.classification = 'arc-quality-usable';
                end
                return
            end
            for fld = {'slipCount','cycleSlipCount','carrierSlipCount','nCycleSlips'}
                if isfield(summary,fld{1}) && isfinite(summary.(fld{1}))
                    aq.slipCount = summary.(fld{1}); break
                end
            end
            for fld = {'minArcLength_s','carrierArcLength_s'}
                if isfield(summary,fld{1}) && isfinite(summary.(fld{1}))
                    aq.minArcLength_s = summary.(fld{1}); break
                end
            end
            if isnan(aq.slipCount) && isnan(aq.minArcLength_s)
                aq.warnings{end+1} = 'Cycle-slip detector enabled, but no arc-quality summary exists.';
                return
            end
            aq.available = true;
            if ~isnan(aq.slipCount) && aq.slipCount == 0;     aq.classification = 'no-slips-reported';
            elseif ~isnan(aq.slipCount) && aq.slipCount > 0;  aq.classification = 'slips-present';
            else;                                               aq.classification = 'arc-quality-usable';
            end
        end

        function rc = residualConsistency(summary, ~)
            rc.available = false; rc.residualRms_m = NaN; rc.nisMean = NaN;
            rc.expectedNis = NaN; rc.classification = 'unavailable'; rc.warnings = {};
            hasR = false; hasN = false;
            try
                if isfield(summary,'finalPrefitRMS_m') && isfinite(summary.finalPrefitRMS_m)
                    rc.residualRms_m = summary.finalPrefitRMS_m; hasR = true;
                elseif isfield(summary,'finalPostfitRMS_m') && isfinite(summary.finalPostfitRMS_m)
                    rc.residualRms_m = summary.finalPostfitRMS_m; hasR = true;
                end
            catch; end
            try
                if isfield(summary,'meanNIS') && isfinite(summary.meanNIS)
                    rc.nisMean = summary.meanNIS; hasN = true;
                end
                if isfield(summary,'expectedNIS') && isfinite(summary.expectedNIS)
                    rc.expectedNis = summary.expectedNIS;
                end
            catch; end
            if hasR && hasN;     rc.available = true; rc.classification = 'residuals-and-nis-available';
            elseif hasN;         rc.available = true; rc.classification = 'nis-available';
            elseif hasR;         rc.available = true; rc.classification = 'residuals-available';
            end
        end

        function bl = blockerList(s)
            bl = {};
            if ~isfield(s,'ambiguityMetadataAvailable')   || ~s.ambiguityMetadataAvailable
                bl{end+1} = 'No ambiguity pair metadata (enable Stage 48 carrier IF traceability).'; end
            if ~isfield(s,'ambiguityCovarianceAvailable')  || ~s.ambiguityCovarianceAvailable
                bl{end+1} = 'Ambiguity covariance (Pamb) unavailable (enable Stage 41 metadata).'; end
            if ~isfield(s,'wideLaneNarrowLaneAvailable')   || ~s.wideLaneNarrowLaneAvailable
                bl{end+1} = 'Wide-lane/narrow-lane diagnostics not active (enable Stage 49).'; end
            if ~isfield(s,'cycleSlipMetadataAvailable')    || ~s.cycleSlipMetadataAvailable
                bl{end+1} = 'Arc quality: no slip/arc count summary available in v1.'; end
            if ~isfield(s,'residualDiagnosticsAvailable')  || ~s.residualDiagnosticsAvailable
                bl{end+1} = 'Residual/NIS consistency unavailable.'; end
            % Stage 53: arc-separated ambiguity metadata blockers.
            if isfield(s,'ambiguityArcRowsMissingArcId') && s.ambiguityArcRowsMissingArcId > 0
                bl{end+1} = sprintf('Arc metadata: %d row(s) missing arc ID (enable Stage 53 arc separation).', ...
                    s.ambiguityArcRowsMissingArcId);
            end
            if isfield(s,'carrierIonoFreeArcInconsistentPairs') && ...
                    s.carrierIonoFreeArcInconsistentPairs > 0
                bl{end+1} = sprintf('Arc consistency: %d carrier IF pair(s) span incompatible arcs.', ...
                    s.carrierIonoFreeArcInconsistentPairs);
            end
            % Stage 54: arc enforcement blockers.
            if isfield(s,'carrierIonoFreeArcSkippedPairs') && s.carrierIonoFreeArcSkippedPairs > 0
                bl{end+1} = sprintf('Arc enforcement: %d carrier IF pair(s) skipped (arc-inconsistent).', ...
                    s.carrierIonoFreeArcSkippedPairs);
            end
            if isfield(s,'wideLaneNarrowLaneArcBlocked') && s.wideLaneNarrowLaneArcBlocked
                bl{end+1} = 'WL/NL diagnostics blocked by arc-inconsistent carrier IF pairs.';
            end
            bl{end+1} = 'Phase-bias products (OSB/WL-FCB) not available; required for integer resolution.';
            bl{end+1} = 'No integer strategy implemented (LAMBDA/MLAMBDA not available in v1).';
            bl{end+1} = 'Integer fixing not implemented in v1.';
            bl{end+1} = 'False-fix-risk control not implemented (ratio test absent).';
        end

        function lines = summaryLines(s)
            lines = {'AmbiguityFixingReadinessGate (Stage 50/51):'};
            lines{end+1} = sprintf('  Classification     : %s', s.classification);
            lines{end+1} = sprintf('  ReadinessScore     : %d / 6', s.readinessScore);
            lines{end+1} = sprintf('  AmbiguityMetadata  : %s', mat2str(s.ambiguityMetadataAvailable));
            lines{end+1} = sprintf('  CovarianceAvail    : %s', mat2str(s.ambiguityCovarianceAvailable));
            lines{end+1} = sprintf('  WL/NL Available    : %s', mat2str(s.wideLaneNarrowLaneAvailable));
            lines{end+1} = sprintf('  ArcQuality         : %s  (%s)', ...
                mat2str(s.cycleSlipMetadataAvailable), s.arcQualityClassification);
            lines{end+1} = sprintf('  ResidualAvail      : %s', mat2str(s.residualDiagnosticsAvailable));
            lines{end+1} = '  IntegerFixing      : false | LAMBDA/MLAMBDA: false | FalseFixRisk: false';
        end

    end

    methods (Static, Access = private)

        function ok = enabled_(cfg)
            ok = false;
            try; ok = logical(cfg.diagnostics.ambiguityFixingReadiness.enable); catch; end
        end

        function cls = wlnlClass_(s)
            if s.wideLaneNarrowLaneAvailable; cls = 'active-float-diagnostics';
            elseif ~s.enabled;                cls = 'disabled';
            else;                             cls = 'unavailable'; end
        end

        function cls = residualClass_(s)
            if s.residualDiagnosticsAvailable; cls = 'residuals-available';
            else;                              cls = 'unavailable'; end
        end

        function cls = classify_(s)
            if ~s.enabled;                      cls = 'disabled';                                    return; end
            if ~s.ambiguityMetadataAvailable;   cls = 'not-ready-no-ambiguity-metadata';             return; end
            if ~s.ambiguityCovarianceAvailable; cls = 'not-ready-no-covariance';                     return; end
            if ~s.wideLaneNarrowLaneAvailable;  cls = 'not-ready-no-wide-lane-narrow-lane';          return; end
            if ~s.cycleSlipMetadataAvailable;   cls = 'not-ready-arc-quality-unavailable';           return; end
            if ~s.residualDiagnosticsAvailable; cls = 'not-ready-residual-consistency-unavailable';  return; end
            cls = 'float-diagnostics-ready-integer-blocked';
        end

        function s = blank_()
            s.enabled=false; s.requested=false; s.classification='disabled';
            s.ambiguityMetadataAvailable=false; s.ambiguityCovarianceAvailable=false;
            s.carrierIonoFreeTraceabilityAvailable=false; s.wideLaneNarrowLaneAvailable=false;
            s.pairCount=0; s.wideLaneSigmaCyclesMean=NaN; s.narrowLaneSigmaCyclesMean=NaN;
            s.maxAbsWideNarrowCorr=NaN; s.cycleSlipMetadataAvailable=false;
            s.slipCount=NaN; s.minArcLength_s=NaN; s.arcQualityClassification='unavailable';
            s.residualDiagnosticsAvailable=false; s.residualRms_m=NaN; s.nisMean=NaN;
            s.expectedNis=NaN; s.phaseBiasProductsAvailable=false;
            s.integerStrategyAvailable=false; s.integerFixingImplemented=false;
            s.lambdaImplemented=false; s.falseFixRiskControlled=false;
            s.readinessScore=0; s.blockers={}; s.warnings={};
            % Stage 53/54: arc metadata blocker fields.
            s.ambiguityArcRowsMissingArcId        = 0;
            s.carrierIonoFreeArcInconsistentPairs = 0;
            s.carrierIonoFreeArcSkippedPairs      = 0;
            s.wideLaneNarrowLaneArcBlocked        = false;
            % Stage 50 ClockExactReportBuilder alias fields (legacy compatibility).
            s.pairMetadataAvailable       = false;
            s.covarianceAvailable         = false;
            s.wideLaneNarrowLaneReady     = false;
            s.wideLaneNarrowLaneClassification = 'unavailable';
            s.arcQualityStatus            = 'unavailable';
            s.residualConsistencyStatus   = 'unavailable';
            s.limitations={'Float readiness gate only; no ambiguity fixing.'
                'LAMBDA/MLAMBDA not implemented in v1.'
                'Calibrated phase-bias products not available.'
                'False-fix-risk control not implemented in v1.'};
        end

    end
end
