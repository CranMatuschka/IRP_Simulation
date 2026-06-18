classdef AttitudeEvidenceReport
    % AttitudeEvidenceReport  Stage 35 single-asset attitude evidence report.
    %
    % Collects Stage 31-34 diagnostics with run-level truth/estimate histories.
    % Evidence reporting only: not an attitude accuracy claim, not a new estimator,
    % and not integer ambiguity fixing.
    %
    % Classifications (in priority order):
    %   'unavailable'                  -- truth or estimate histories absent
    %   'inconsistent'                 -- finite-diff Jacobian inconsistency detected
    %   'weak-evidence'                -- observability audit weak or unavailable
    %   'validation-known-ambiguity-only' -- convergence visible only in KAV run
    %   'bounded-float-evidence'       -- carrier float/differential active, no contradictions
    %   'diagnostic-only'              -- fallback when carrier float not confirmed active
    %
    % Usage:
    %   s     = revgnss.AttitudeEvidenceReport.summarize(out, cfg)
    %   h     = revgnss.AttitudeEvidenceReport.findAttitudeHistories(out)
    %   lines = revgnss.AttitudeEvidenceReport.summaryLines(s)
    %
    % summarize(out, cfg): out must have out.diag (Diagnostics handle) and
    %   optionally out.summary (ReportRunner summary struct).
    %   Alternatively, pass out.errVecs_rad [3xN] for synthetic/test use.

    methods (Static)

        function s = summarize(out, cfg)
            % summarize  Collect attitude evidence from run output and config.
            s = revgnss.AttitudeEvidenceReport.blankStruct_();

            if isfield(cfg,'diagnostics') && isfield(cfg.diagnostics,'attitudeEvidence') && ...
                    isfield(cfg.diagnostics.attitudeEvidence,'enable')
                s.enabled = logical(cfg.diagnostics.attitudeEvidence.enable);
            end

            % Convention (always available)
            try
                cv = revgnss.AttitudeKinematics.convention();
                s.attitudeConventionName = cv.name;
                s.limitations{end+1}     = cv.limitation;
            catch; end

            % Receiver geometry (from cfg)
            try
                g = revgnss.ReceiverGeometry.fromConfig(cfg);
                s.receiverGeometrySummary = sprintf('%d receivers, max lever %.3f m', ...
                    g.nReceiversGeometry, g.leverArmMaxNorm_m);
                if ~g.hasNonzeroLeverArm
                    s.warnings{end+1} = 'All lever arms zero: attitude structurally unobservable.';
                end
            catch
                s.receiverGeometrySummary = 'unavailable';
            end

            % Stage 31 observability classification
            try
                ao = out.diag.getLastAttitudeAudit();
                if isstruct(ao) && isfield(ao,'classification')
                    s.observabilityClassification = ao.classification;
                end
            catch; end

            % Stage 34 Jacobian audit classification
            try
                ja = out.diag.getLastAttitudeJacobianAudit();
                if isstruct(ja) && isfield(ja,'classification')
                    s.jacobianAuditClassification = ja.classification;
                end
            catch; end

            % Attitude histories
            h = revgnss.AttitudeEvidenceReport.findAttitudeHistories(out);
            s.nEpochs              = h.nEpochs;
            s.hasTruthAttitude     = h.hasTruth;
            s.hasEstimatedAttitude = h.hasEstimate;

            if ~h.available
                s.available      = false;
                s.classification = 'unavailable';
                s.warnings{end+1} = 'Attitude truth/estimate histories unavailable in this run output.';
                return
            end
            s.available = true;

            % Error metrics (errors are wrap-safe from Diagnostics.record)
            errNorms        = sqrt(sum(h.errVecs_rad .^ 2, 1)) * 180/pi;
            s.finalErrorDeg = errNorms(end);
            s.rmsErrorDeg   = rms(errNorms);
            s.maxErrorDeg   = max(errNorms);

            if ~isempty(h.sigmaVec_rad)
                sigDeg            = h.sigmaVec_rad * 180/pi;
                s.finalCovSqrtDeg = sigDeg(end);
                s.rmsCovSqrtDeg   = rms(sigDeg);
            end

            % Pull runner summary if present
            summ = struct();
            if isfield(out,'summary'); summ = out.summary; end

            s.classification = revgnss.AttitudeEvidenceReport.classify_(s, summ);

            % Standard limitations
            s.limitations{end+1} = ...
                'Attitude float carrier: not integer-fixed; ambiguities floating unless calibrated differential mode active.';
            s.limitations{end+1} = ...
                'Finite-diff Jacobian consistency requires per-row LOS metadata; production path uses H-only summary.';
        end

        function h = findAttitudeHistories(out)
            % findAttitudeHistories  Robustly extract attitude histories from run output.
            %
            % Accepts either:
            %   out.diag  — real Diagnostics handle (production)
            %   out.errVecs_rad  [3xN]  — synthetic injection (tests)
            h.nEpochs     = 0;   h.hasTruth    = false;
            h.hasEstimate = false; h.available  = false;
            h.errVecs_rad = [];   h.sigmaVec_rad = [];

            if ~isstruct(out); return; end

            % Synthetic injection path (test harness)
            if isfield(out,'errVecs_rad') && ~isempty(out.errVecs_rad)
                h.errVecs_rad = out.errVecs_rad;
                h.nEpochs     = size(out.errVecs_rad, 2);
                h.hasTruth    = true;
                h.hasEstimate = true;
                h.available   = true;
                if isfield(out,'sigmaVec_rad') && numel(out.sigmaVec_rad) == h.nEpochs
                    h.sigmaVec_rad = out.sigmaVec_rad;
                end
                return
            end

            % Normal path via Diagnostics handle
            if ~isfield(out,'diag') || isempty(out.diag); return; end
            diag = out.diag;
            if ~isobject(diag) || ~isprop(diag,'nEpochs') || diag.nEpochs < 1; return; end
            h.nEpochs = diag.nEpochs;

            try
                ev = diag.getAttitudeErrorVecs();
                if ~isempty(ev) && size(ev,2) == h.nEpochs
                    h.errVecs_rad = ev;
                    h.hasTruth    = true;
                    h.hasEstimate = true;
                end
            catch; end

            try
                sv = [diag.log.estimatedAttitudeSigma_rad];
                if numel(sv) == h.nEpochs
                    h.sigmaVec_rad = sv;
                end
            catch; end

            h.available = h.hasTruth && h.hasEstimate && ~isempty(h.errVecs_rad);
        end

        function lines = summaryLines(s)
            % summaryLines  Concise cell array for embedding in report or console.
            lines = {};
            lines{end+1} = sprintf('Classification  : %s', s.classification);
            lines{end+1} = sprintf('Available       : %s', mat2str(s.available));
            lines{end+1} = sprintf('Epochs          : %d', s.nEpochs);
            if isfinite(s.finalErrorDeg)
                lines{end+1} = sprintf('Final att error : %.3f deg', s.finalErrorDeg);
                lines{end+1} = sprintf('RMS att error   : %.3f deg', s.rmsErrorDeg);
                lines{end+1} = sprintf('Max att error   : %.3f deg', s.maxErrorDeg);
            end
            if isfinite(s.finalCovSqrtDeg)
                lines{end+1} = sprintf('Final cov sqrt  : %.3f deg', s.finalCovSqrtDeg);
            end
            lines{end+1} = sprintf('Observability   : %s', s.observabilityClassification);
            lines{end+1} = sprintf('Jacobian audit  : %s', s.jacobianAuditClassification);
            lines{end+1} = sprintf('Convention      : %s', s.attitudeConventionName);
            lines{end+1} = sprintf('Geometry        : %s', s.receiverGeometrySummary);
        end

    end

    methods (Static, Access = private)

        function cls = classify_(s, summ)
            % classify_  Evidence classification in priority order.

            % Jacobian inconsistency overrides everything
            if strcmp(s.jacobianAuditClassification, 'finite-diff-inconsistent')
                cls = 'inconsistent'; return
            end

            % Weak Stage 31 observability
            weakStage31 = ismember(s.observabilityClassification, ...
                {'unavailable','not-estimated','unobservable-zero-lever-arm', ...
                 'unobservable-zero-attitude-columns','zero-lever-arm-zero-sensitivity', ...
                 'weak-code-only','weak-rank-deficient','diagnostic-only'});

            % Weak ReportRunner observability class
            weakRunner = isfield(summ,'attitudeObsClass') && ismember(summ.attitudeObsClass, ...
                {'UNOBSERVABLE','INVALID_CONFIG','WEAKLY_OBSERVABLE','NON_CONVERGENT', ...
                 'CALIBRATION_FAILED','AMBIGUITY_ABSORBED'});

            if weakStage31 || weakRunner
                cls = 'weak-evidence'; return
            end

            % KAV-only evidence (convergence visible only under known ambiguities)
            kavOnly = isfield(summ,'knownAmbFinalError_deg') && ...
                      isfinite(summ.knownAmbFinalError_deg) && ...
                      ~(isfield(summ,'attitudeObsClass') && ...
                        ismember(summ.attitudeObsClass, {'CONVERGED','BOUNDED_WEAK_GEOMETRY'}));
            if kavOnly
                cls = 'validation-known-ambiguity-only'; return
            end

            % Carrier float or calibrated differential active
            hasCarrier = (isfield(summ,'carrierAttJacActive') && summ.carrierAttJacActive) || ...
                         (isfield(summ,'diffAttCalibrated')   && summ.diffAttCalibrated);
            if hasCarrier
                cls = 'bounded-float-evidence'; return
            end

            cls = 'diagnostic-only';
        end

        function s = blankStruct_()
            s.enabled                    = false;
            s.available                  = false;
            s.classification             = 'unavailable';
            s.nEpochs                    = 0;
            s.hasTruthAttitude           = false;
            s.hasEstimatedAttitude       = false;
            s.finalErrorDeg              = NaN;
            s.rmsErrorDeg                = NaN;
            s.maxErrorDeg                = NaN;
            s.finalCovSqrtDeg            = NaN;
            s.rmsCovSqrtDeg              = NaN;
            s.observabilityClassification  = 'unavailable';
            s.receiverGeometrySummary    = 'unavailable';
            s.attitudeConventionName     = 'ZYX Euler roll-pitch-yaw';
            s.jacobianAuditClassification  = 'unavailable';
            s.limitations                = {};
            s.warnings                   = {};
        end

    end
end
