classdef AmbiguityFixingReadinessGate
    % AmbiguityFixingReadinessGate  Stage 50 ambiguity fixing readiness gate.
    %
    % Combines ambiguity pair metadata (Stage 48), Pamb covariance (Stage 41),
    % wide-lane/narrow-lane diagnostics (Stage 49), arc-quality availability
    % (slip detection), and residual/NIS availability into a single readiness
    % classification.
    %
    % Hard facts in v1 (always false):
    %   phaseBiasProductsAvailable, integerStrategyAvailable,
    %   integerFixingImplemented, lambdaImplemented, falseFixRiskControlled.
    %
    % Usage:
    %   s     = revgnss.AmbiguityFixingReadinessGate.assess(summary, cfg);
    %   lines = revgnss.AmbiguityFixingReadinessGate.summaryLines(s);

    methods (Static)

        function s = assess(summary, cfg)
            % assess  Return readiness gate struct.
            s = revgnss.AmbiguityFixingReadinessGate.blank_();
            if ~revgnss.AmbiguityFixingReadinessGate.toggleEnabled_(cfg)
                return
            end
            s.enabled = true;

            % Soft prerequisite 1: ambiguity pair metadata (Stage 48)
            pairCount     = 0;
            pairMetaAvail = false;
            try
                if isfield(summary,'carrierIfAmbiguityPairCount') && ...
                        isnumeric(summary.carrierIfAmbiguityPairCount)
                    pairCount = summary.carrierIfAmbiguityPairCount;
                end
                if isfield(summary,'carrierIfPairMetadataAvailable')
                    pairMetaAvail = logical(summary.carrierIfPairMetadataAvailable);
                end
            catch; end
            s.pairCount           = pairCount;
            s.pairMetadataAvailable = pairMetaAvail;
            if ~pairMetaAvail || pairCount == 0
                s.classification = 'not-ready-no-ambiguity-metadata';
                s.blockers{end+1} = 'No carrier IF ambiguity pair metadata available (Stage 48 required).';
                return
            end

            % Soft prerequisite 2: ambiguity covariance (Stage 41 Pamb)
            hasPamb = false;
            try
                if isfield(summary,'ambiguityCovarianceSummary') && ...
                        isstruct(summary.ambiguityCovarianceSummary) && ...
                        isfield(summary.ambiguityCovarianceSummary,'Pamb') && ...
                        ~isempty(summary.ambiguityCovarianceSummary.Pamb)
                    hasPamb = true;
                end
            catch; end
            s.covarianceAvailable = hasPamb;
            if ~hasPamb
                s.classification = 'not-ready-no-covariance';
                s.blockers{end+1} = 'Ambiguity covariance sub-block (Pamb) unavailable (Stage 41 required).';
                return
            end

            % Soft prerequisite 3: WL/NL diagnostics active (Stage 49)
            wlnlClass = 'disabled';
            try
                if isfield(summary,'wideLaneNarrowLaneClassification')
                    wlnlClass = summary.wideLaneNarrowLaneClassification;
                end
            catch; end
            s.wideLaneNarrowLaneClassification = wlnlClass;
            s.wideLaneNarrowLaneReady = strcmp(wlnlClass,'active-float-diagnostics');
            if ~s.wideLaneNarrowLaneReady
                s.classification = 'not-ready-no-wide-lane-narrow-lane';
                s.blockers{end+1} = sprintf( ...
                    'Wide-lane/narrow-lane diagnostics not active (classification: %s).', wlnlClass);
                return
            end

            % Soft prerequisite 4: arc quality (slip detection enabled)
            arcStatus = revgnss.AmbiguityFixingReadinessGate.arcQuality_(cfg);
            s.arcQualityStatus = arcStatus;
            if strcmp(arcStatus,'unavailable')
                s.classification = 'not-ready-arc-quality-unavailable';
                s.blockers{end+1} = 'Arc quality unavailable: cycle-slip detection not enabled.';
                return
            end

            % Soft prerequisite 5: residual/NIS consistency
            residStatus = revgnss.AmbiguityFixingReadinessGate.residualConsistency_(summary);
            s.residualConsistencyStatus = residStatus;
            if strcmp(residStatus,'unavailable')
                s.classification = 'not-ready-residual-consistency-unavailable';
                s.blockers{end+1} = 'Residual/NIS consistency information unavailable.';
                return
            end

            % All soft prerequisites met; hard blockers are always present in v1.
            s.blockers   = revgnss.AmbiguityFixingReadinessGate.blockerList_();
            s.classification = 'float-diagnostics-ready-integer-blocked';
        end

        function status = arcQuality_(cfg)
            % arcQuality_  Return 'available' when slip detection is enabled.
            status = 'unavailable';
            try
                if isfield(cfg,'measurements') && ...
                        isfield(cfg.measurements,'carrier') && ...
                        isfield(cfg.measurements.carrier,'slipDetection') && ...
                        isfield(cfg.measurements.carrier.slipDetection,'enable') && ...
                        logical(cfg.measurements.carrier.slipDetection.enable)
                    status = 'available';
                end
            catch; end
        end

        function status = residualConsistency_(summary)
            % residualConsistency_  Return 'available' when NIS or prefit RMS is finite.
            status = 'unavailable';
            try
                if isfield(summary,'meanNIS') && isfinite(summary.meanNIS)
                    status = 'available'; return
                end
                if isfield(summary,'finalPrefitRMS_m') && isfinite(summary.finalPrefitRMS_m)
                    status = 'available';
                end
            catch; end
        end

        function lines = summaryLines(s)
            % summaryLines  Formatted cell array for embedding in report.
            lines = {};
            lines{end+1} = 'AmbiguityFixingReadinessGate (Stage 50):';
            lines{end+1} = sprintf('  Classification         : %s', s.classification);
            lines{end+1} = sprintf('  PairCount              : %d', s.pairCount);
            lines{end+1} = sprintf('  PairMetadata           : %s', mat2str(s.pairMetadataAvailable));
            lines{end+1} = sprintf('  CovarianceAvailable    : %s', mat2str(s.covarianceAvailable));
            lines{end+1} = sprintf('  WL/NL Ready            : %s  (%s)', ...
                mat2str(s.wideLaneNarrowLaneReady), s.wideLaneNarrowLaneClassification);
            lines{end+1} = sprintf('  ArcQuality             : %s', s.arcQualityStatus);
            lines{end+1} = sprintf('  ResidualConsistency    : %s', s.residualConsistencyStatus);
            lines{end+1} = sprintf('  PhaseBiasProducts      : false');
            lines{end+1} = sprintf('  IntegerStrategy        : false');
            lines{end+1} = sprintf('  IntegerFixingImpl      : false');
            lines{end+1} = sprintf('  LAMBDA/MLAMBDA         : false');
            lines{end+1} = sprintf('  FalseFixRiskControlled : false');
        end

    end

    methods (Static, Access = private)

        function ok = toggleEnabled_(cfg)
            ok = false;
            try; ok = logical(cfg.diagnostics.ambiguityFixingReadiness.enable); catch; end
        end

        function bl = blockerList_()
            bl = {};
            bl{end+1} = ['Phase-bias products (OSB/WL-FCB) not available; ' ...
                'required for integer ambiguity resolution.'];
            bl{end+1} = 'No integer ambiguity strategy implemented (LAMBDA/MLAMBDA not available in v1).';
            bl{end+1} = 'Integer fixing not implemented in v1.';
            bl{end+1} = ['False-fix-risk control not implemented ' ...
                '(ratio test and residual validation absent).'];
        end

        function s = blank_()
            s.enabled                      = false;
            s.classification               = 'disabled';
            s.pairCount                    = 0;
            s.pairMetadataAvailable        = false;
            s.covarianceAvailable          = false;
            s.wideLaneNarrowLaneReady      = false;
            s.wideLaneNarrowLaneClassification = 'disabled';
            s.arcQualityStatus             = 'unavailable';
            s.residualConsistencyStatus    = 'unavailable';
            s.phaseBiasProductsAvailable   = false;
            s.integerStrategyAvailable     = false;
            s.integerFixingImplemented     = false;
            s.lambdaImplemented            = false;
            s.falseFixRiskControlled       = false;
            s.blockers                     = {};
        end

    end
end
