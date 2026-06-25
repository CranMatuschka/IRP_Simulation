classdef AmbiguityArcState
    % AmbiguityArcState  Stage 53 arc-separated float ambiguity metadata.
    %
    % Collects per-row arc state from cpInfo (after trackMgr.process()) and
    % produces compact summary fields for use by ReportRunner and the
    % AmbiguityFixingReadinessGate.
    %
    % Key limitations:
    %   Arc metadata is diagnostic only.  No ambiguity is fixed or rounded.
    %   LAMBDA/MLAMBDA, calibrated phase-bias products, and false-fix-risk
    %   control are NOT implemented in v1.  Arc separation is structural
    %   metadata only; the EKF resets (via applyAmbiguityResets) handle
    %   covariance inflation on slip.

    methods (Static)

        function s = fromCpInfo(cpInfo)
            % fromCpInfo  Build arc state summary from cpInfo (Stage 53 fields).
            %
            % cpInfo is the carrier phase info struct from errStruct.carrierPhase.
            % If Stage 53 arc fields (arcId, currentArcEpoch, slipCount) are
            % present they are used directly; otherwise returns unavailable.
            s = revgnss.AmbiguityArcState.blank_();
            if isempty(cpInfo) || ~isstruct(cpInfo)
                return
            end
            if ~isfield(cpInfo,'arcId') || isempty(cpInfo.arcId)
                s.limitations{end+1} = 'arcId field missing from cpInfo (Stage 53 wiring disabled).';
                return
            end
            nRows = numel(cpInfo.arcId);
            s.nRows = nRows;
            s.arcMetadataAvailable = true;

            arcIds = cpInfo.arcId;
            s.nRowsMissingArcId = sum(arcIds == 0);
            validMask = arcIds > 0;
            if any(validMask)
                s.nUniqueArcIds = numel(unique(arcIds(validMask)));
            end

            if isfield(cpInfo,'currentArcEpoch') && numel(cpInfo.currentArcEpoch) == nRows
                ep = cpInfo.currentArcEpoch;
                ep = ep(validMask);
                if ~isempty(ep)
                    s.minArcEpoch  = min(ep);
                    s.meanArcEpoch = mean(ep);
                    s.maxArcEpoch  = max(ep);
                end
            else
                s.nRowsMissingArcId = s.nRowsMissingArcId + nRows;
            end

            if isfield(cpInfo,'slipCount') && numel(cpInfo.slipCount) == nRows
                sc = cpInfo.slipCount(validMask);
                s.totalSlipEvents = sum(sc);
            end

            % IF arc consistency (requires ionoFreeCombined flag and arcIdL1/L2).
            if isfield(cpInfo,'ionoFreeCombined') && cpInfo.ionoFreeCombined && ...
                    isfield(cpInfo,'arcIdL1') && isfield(cpInfo,'arcIdL2')
                arcL1 = cpInfo.arcIdL1;
                arcL2 = cpInfo.arcIdL2;
                nIF   = min(numel(arcL1), numel(arcL2));
                if nIF > 0
                    consistent = (arcL1(1:nIF) == arcL2(1:nIF)) & ...
                                 (arcL1(1:nIF) > 0) & (arcL2(1:nIF) > 0);
                    s.nArcConsistentIfPairs   = sum(consistent);
                    s.nArcInconsistentIfPairs = nIF - s.nArcConsistentIfPairs;
                    if s.nArcInconsistentIfPairs == 0
                        s.ifArcConsistencyClassification = 'all-consistent';
                    elseif s.nArcConsistentIfPairs == 0
                        s.ifArcConsistencyClassification = 'all-inconsistent';
                    else
                        s.ifArcConsistencyClassification = 'partial-inconsistency';
                    end
                end
            end

            s.classification = revgnss.AmbiguityArcState.classify_(s);
        end

        function s = summarize(arcState, cpInfo)
            % summarize  Build arc state summary from getArcStateForRows output.
            %
            % arcState is the output of CarrierTrackManager.getArcStateForRows().
            % cpInfo is the (possibly IF-combined) carrier phase info struct.
            s = revgnss.AmbiguityArcState.blank_();
            if isempty(arcState) || ~isstruct(arcState) || arcState.nRows == 0
                return
            end

            % Attach arc fields from arcState into cpInfo copy for fromCpInfo.
            cpInfoAug = cpInfo;
            cpInfoAug.arcId           = arcState.arcId;
            cpInfoAug.currentArcEpoch = arcState.currentArcEpoch;
            cpInfoAug.slipCount       = arcState.slipCount;

            s = revgnss.AmbiguityArcState.fromCpInfo(cpInfoAug);
        end

        function lines = summaryLines(s)
            % summaryLines  Formatted cell array of arc state summary lines.
            if ~isstruct(s) || ~isfield(s,'classification')
                lines = {'AmbiguityArcState: no summary.'}; return
            end
            lines = {};
            lines{end+1} = sprintf('Classification       : %s', s.classification);
            lines{end+1} = sprintf('ArcMetadataAvail     : %s', mat2str(s.arcMetadataAvailable));
            if s.nRows > 0
                lines{end+1} = sprintf('NRows                : %d', s.nRows);
            end
            if s.arcMetadataAvailable
                lines{end+1} = sprintf('NUniqueArcIds        : %d', s.nUniqueArcIds);
                lines{end+1} = sprintf('NRowsMissingArcId    : %d', s.nRowsMissingArcId);
                if isfinite(s.minArcEpoch)
                    lines{end+1} = sprintf('ArcEpoch min/mean/max: %d / %.1f / %d', ...
                        s.minArcEpoch, s.meanArcEpoch, s.maxArcEpoch);
                end
                if ~isnan(s.totalSlipEvents)
                    lines{end+1} = sprintf('TotalSlipEvents      : %d', s.totalSlipEvents);
                end
                lines{end+1} = sprintf('IFConsistentPairs    : %d', s.nArcConsistentIfPairs);
                lines{end+1} = sprintf('IFInconsistentPairs  : %d', s.nArcInconsistentIfPairs);
                lines{end+1} = sprintf('IFConsistency        : %s', s.ifArcConsistencyClassification);
            end
            lines{end+1} = 'IntegerFixingImpl    : false';
            lines{end+1} = 'LambdaImpl           : false';
            lines{end+1} = 'FalseFixRiskCtrl     : false';
        end

    end

    methods (Static, Access = private)

        function s = blank_()
            s.arcMetadataAvailable          = false;
            s.classification                = 'unavailable';
            s.nRows                         = 0;
            s.nUniqueArcIds                 = 0;
            s.nRowsMissingArcId             = 0;
            s.minArcEpoch                   = NaN;
            s.meanArcEpoch                  = NaN;
            s.maxArcEpoch                   = NaN;
            s.totalSlipEvents               = NaN;
            s.nArcConsistentIfPairs         = 0;
            s.nArcInconsistentIfPairs       = 0;
            s.ifArcConsistencyClassification = 'unavailable';
            s.integerFixingImplemented      = false;
            s.lambdaImplemented             = false;
            s.falseFixRiskControlled        = false;
            s.warnings                      = {};
            s.limitations                   = {
                'Arc separation is structural metadata only; no ambiguity fixing.'
                'LAMBDA/MLAMBDA not implemented in v1.'
                'Calibrated phase-bias products not available.'
                'False-fix-risk control not implemented in v1.'
            };
        end

        function cls = classify_(s)
            if ~s.arcMetadataAvailable;             cls = 'unavailable';              return; end
            if s.nRowsMissingArcId == s.nRows;      cls = 'all-rows-missing-arc-id';  return; end
            if s.nArcInconsistentIfPairs > 0;       cls = 'arc-inconsistency-present'; return; end
            cls = 'arc-metadata-available';
        end

    end
end
