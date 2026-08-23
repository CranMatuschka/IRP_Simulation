classdef AmbiguityReadinessDiagnostics
    % AmbiguityReadinessDiagnostics  Float ambiguity readiness diagnostics.
    %
    % Assesses readiness for future integer ambiguity work using carrier-row
    % inventory, ambiguity count/source, covariance availability,
    % slip detection status, and known-ambiguity validation state.
    % Readiness diagnostics only — no integer fixing, no LAMBDA/MLAMBDA.
    %
    % Usage:
    %   s     = revgnss.AmbiguityReadinessDiagnostics.assess(out, cfg);
    %   lines = revgnss.AmbiguityReadinessDiagnostics.summaryLines(s);

    methods (Static)

        function s = assess(out, cfg)
            % assess  Return ambiguity readiness diagnostics struct.
            s = revgnss.AmbiguityReadinessDiagnostics.blank_();
            s.l2CarrierEkfImplemented  = false;
            s.integerFixingImplemented = false;
            s.lambdaReady              = false;
            s.falseFixRiskControlled   = false;
            if nargin < 2 || isempty(out) || isempty(cfg)
                s.warnings{end+1} = 'out or cfg empty.'; return
            end
            s.enabled = true;

            % Inventory for row/ambiguity counts
            inv = revgnss.CarrierRowMetadataInventory.inventory(out, cfg);
            s.carrierInventoryClassification = inv.classification;
            s.carrierRowCount                = inv.carrierRowCount;
            s.differentialAttitudeRowCount   = inv.differentialAttitudeRowCount;
            s.rowMetadataCompleteness        = inv.rowMetadataCompleteness;
            s.ambiguityStateCount            = inv.ambiguityStateCount;
            s.ambiguityStateCountSource      = inv.ambiguityStateCountSource;
            s.ambiguityMetadataAvailable     = inv.ambiguityMetadataAvailable;
            s.warnings = [s.warnings, inv.warnings];

            % Covariance inventory
            cv = revgnss.AmbiguityReadinessDiagnostics.covarianceInventory(out, cfg);
            s.ambiguityCovarianceAvailable   = cv.ambiguityCovarianceAvailable;
            s.ambiguityCovarianceCondition   = cv.condition;
            s.ambiguityCorrelationMaxAbs     = cv.correlationMaxAbs;
            s.warnings = [s.warnings, cv.warnings];

            % Slip detection from cfg
            try
                if isfield(cfg,'measurements') && isfield(cfg.measurements,'carrier') && ...
                        isfield(cfg.measurements.carrier,'slipDetection')
                    s.slipDetectionEnabled = ...
                        logical(cfg.measurements.carrier.slipDetection.enable);
                end
            catch; end

            % Known ambiguity validation
            try
                if isfield(cfg,'estimator') && ...
                        isfield(cfg.estimator,'runKnownAmbiguityValidation')
                    s.knownAmbiguityValidationEnabled = ...
                        logical(cfg.estimator.runKnownAmbiguityValidation);
                end
            catch; end

            s.blockers       = revgnss.AmbiguityReadinessDiagnostics.blockerList(s);
            % Append gate blockers if available in out.summary
            try
                if isfield(out,'summary') && ...
                        isfield(out.summary,'ambiguityFixingReadinessGate') && ...
                        isfield(out.summary.ambiguityFixingReadinessGate,'blockers') && ...
                        iscell(out.summary.ambiguityFixingReadinessGate.blockers)
                    s.blockers = [s.blockers, ...
                        out.summary.ambiguityFixingReadinessGate.blockers];
                end
            catch; end
            try
                if isfield(out,'summary') && ...
                        isfield(out.summary,'ambiguityReadinessEvidenceGate') && ...
                        isfield(out.summary.ambiguityReadinessEvidenceGate,'blockers') && ...
                        iscell(out.summary.ambiguityReadinessEvidenceGate.blockers)
                    s.blockers = [s.blockers, ...
                        out.summary.ambiguityReadinessEvidenceGate.blockers];
                end
            catch; end
            s.classification = revgnss.AmbiguityReadinessDiagnostics.classify_(s);
            s.readinessScore = revgnss.AmbiguityReadinessDiagnostics.score_(s);
            s.limitations    = revgnss.AmbiguityReadinessDiagnostics.limitations_();
        end

        function cv = covarianceInventory(out, cfg) %#ok<INUSD>
            % covarianceInventory  Check ambiguity covariance availability.
            % Prefers exported covariance summary if present in out.summary.
            cv.ambiguityCovarianceAvailable = false;
            cv.condition                    = NaN;
            cv.correlationMaxAbs            = NaN;
            cv.warnings                     = {};
            try
                if isfield(out,'summary') && isfield(out.summary,'ambiguityCovarianceSummary') && ...
                        isfield(out.summary.ambiguityCovarianceSummary,'available') && ...
                        out.summary.ambiguityCovarianceSummary.available
                    cs = out.summary.ambiguityCovarianceSummary;
                    cv.ambiguityCovarianceAvailable = true;
                    cv.condition         = cs.condition;
                    cv.correlationMaxAbs = cs.correlationMaxAbs;
                    return
                end
                cv.warnings{end+1} = ['Ambiguity covariance export not found. ' ...
                    'Enable cfg.diagnostics.ambiguityStateMetadata.enable for Stage 41 export.'];
            catch ex
                cv.warnings{end+1} = ['covarianceInventory: ' ex.message];
            end
        end

        function bl = blockerList(s)
            % blockerList  Return concise blockers for integer ambiguity readiness.
            bl = {};
            if ~isfinite(s.ambiguityStateCount) || s.ambiguityStateCount == 0
                bl{end+1} = 'No ambiguity states identified.';
            end
            if strcmp(s.ambiguityStateCountSource,'summary-estimate') || ...
                    strcmp(s.ambiguityStateCountSource,'unavailable')
                bl{end+1} = 'Ambiguity count is summary-estimated; EKF state map not persisted.';
            end
            if ~s.ambiguityCovarianceAvailable
                bl{end+1} = 'Ambiguity covariance sub-block unavailable.';
            end
            if ~strcmp(s.rowMetadataCompleteness,'row-metadata-complete')
                bl{end+1} = 'Per-row receiver/tower/signal metadata incomplete.';
            end
            if s.knownAmbiguityValidationEnabled
                bl{end+1} = 'Known-ambiguity validation is validation-only, not operational.';
            end
            bl{end+1} = 'Carrier IF ambiguity is non-integer (float only); integer fixing not implemented in v1.';
            bl{end+1} = 'Wide-lane/narrow-lane diagnostics are float diagnostics only; integer fixing still requires calibrated phase-bias products and controlled false-fix validation.';
            bl{end+1} = 'Integer ambiguity fixing not implemented in v1.';
        end

        function lines = summaryLines(s)
            % summaryLines  Formatted cell array for report embedding.
            lines = {};
            if ~s.enabled
                lines{end+1} = 'AmbiguityReadinessDiagnostics: unavailable'; return
            end
            lines{end+1} = sprintf('Classification           : %s', s.classification);
            lines{end+1} = sprintf('Readiness score          : %d', s.readinessScore);
            lines{end+1} = sprintf('CarrierInventory         : %s', s.carrierInventoryClassification);
            lines{end+1} = sprintf('RowMetadataCompleteness  : %s', s.rowMetadataCompleteness);
            if isfinite(s.carrierRowCount)
                lines{end+1} = sprintf('CarrierRows              : %d', s.carrierRowCount);
            end
            if s.ambiguityMetadataAvailable && isfinite(s.ambiguityStateCount)
                lines{end+1} = sprintf('AmbiguityStates          : %d (%s)', ...
                    s.ambiguityStateCount, s.ambiguityStateCountSource);
            else
                lines{end+1} = 'AmbiguityStates          : unavailable';
            end
            lines{end+1} = sprintf('CovarianceAvailable      : %s', ...
                mat2str(s.ambiguityCovarianceAvailable));
            lines{end+1} = sprintf('SlipDetectionEnabled     : %s', ...
                mat2str(s.slipDetectionEnabled));
            lines{end+1} = sprintf('KnownAmbValEnabled       : %s', ...
                mat2str(s.knownAmbiguityValidationEnabled));
            lines{end+1} = sprintf('LambdaReady              : %s', mat2str(s.lambdaReady));
            lines{end+1} = sprintf('FalseFixRiskControlled   : %s', ...
                mat2str(s.falseFixRiskControlled));
            lines{end+1} = sprintf('IntegerFixingImpl        : %s', ...
                mat2str(s.integerFixingImplemented));
        end

    end

    methods (Static, Access = private)

        function cls = classify_(s)
            m = s.carrierInventoryClassification;
            if strcmp(m,'unavailable') || (~isfinite(s.carrierRowCount) && ...
                    strcmp(s.ambiguityStateCountSource,'unavailable'))
                cls = 'unavailable'; return
            end
            if isfinite(s.carrierRowCount) && s.carrierRowCount == 0
                cls = 'not-ready-carrier-disabled'; return
            end
            if ~isfinite(s.ambiguityStateCount) || s.ambiguityStateCount == 0
                cls = 'not-ready-no-ambiguity-states'; return
            end
            if s.knownAmbiguityValidationEnabled
                cls = 'validation-known-ambiguity-only'; return
            end
            if strcmp(s.ambiguityStateCountSource,'summary-estimate') || ...
                    strcmp(s.ambiguityStateCountSource,'unavailable')
                cls = 'not-ready-summary-only'; return
            end
            if ~s.ambiguityCovarianceAvailable
                cls = 'not-ready-no-covariance'; return
            end
            if isfinite(s.ambiguityCovarianceCondition) && s.ambiguityCovarianceCondition > 1e6
                cls = 'not-ready-poor-conditioning'; return
            end
            if strcmp(m,'diagnostic-float-only') || strcmp(m,'summary-only')
                cls = 'diagnostic-float-only'; return
            end
            cls = 'ready-for-controlled-float-analysis';
        end

        function sc = score_(s)
            sc = 0;
            if isfinite(s.carrierRowCount)    && s.carrierRowCount > 0;          sc=sc+1; end
            if strcmp(s.carrierInventoryClassification,'summary-only') || ...
               (isfinite(s.carrierRowCount)   && s.carrierRowCount > 0);          sc=sc+1; end
            if isfinite(s.ambiguityStateCount) && s.ambiguityStateCount > 0;      sc=sc+1; end
            if ~strcmp(s.ambiguityStateCountSource,'summary-estimate') && ...
               ~strcmp(s.ambiguityStateCountSource,'unavailable');                 sc=sc+1; end
            if s.ambiguityCovarianceAvailable;                                     sc=sc+1; end
            if s.slipDetectionEnabled;                                             sc=sc+1; end
            if s.knownAmbiguityValidationEnabled;                                  sc=sc+1; end
        end

        function lims = limitations_()
            lims = {
                'Integer ambiguity fixing not implemented in v1.'
                'LAMBDA/MLAMBDA not implemented in v1.'
                'Carrier IF ambiguity is non-integer (B_IF=alpha*B_L1+beta*B_L2); use wide-lane/narrow-lane or explicit integer strategy in later stage.'
                'Carrier ionosphere-free ambiguity covariance is traceability-only; it is not an integer-fixing criterion by itself.'
                'Per-row receiver/tower/signal metadata not available in current architecture.'
            };
        end

        function s = blank_()
            s.enabled=false; s.classification='unavailable'; s.readinessScore=0;
            s.carrierInventoryClassification='unavailable';
            s.ambiguityStateCount=NaN; s.ambiguityStateCountSource='unavailable';
            s.ambiguityMetadataAvailable=false;
            s.ambiguityCovarianceAvailable=false;
            s.ambiguityCovarianceCondition=NaN; s.ambiguityCorrelationMaxAbs=NaN;
            s.rowMetadataCompleteness='none';
            s.carrierRowCount=NaN; s.differentialAttitudeRowCount=NaN;
            s.slipDetectionEnabled=false; s.knownAmbiguityValidationEnabled=false;
            s.l2CarrierEkfImplemented=false; s.integerFixingImplemented=false;
            s.lambdaReady=false; s.falseFixRiskControlled=false;
            s.blockers={}; s.warnings={}; s.limitations={};
        end

    end
end
