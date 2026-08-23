classdef AttitudeScenarioReadiness
    % AttitudeScenarioReadiness  single-asset attitude scenario readiness gate.
    %
    % Combines receiver geometry rank, measurement modes, attitude observability,
    % Jacobian audit, and evidence classification into a readiness assessment.
    % This is a readiness gate only: not an attitude accuracy claim, not integer
    % ambiguity fixing, and not operational certification.
    %
    % Allowed classifications:
    %   'unavailable'                    -- receiver geometry unavailable
    %   'not-ready-single-receiver'      -- nReceivers < 2; no geometry basis
    %   'not-ready-zero-lever-arm'       -- all lever arms zero
    %   'weak-two-receiver-baseline'     -- geometry rank < 2 or only one baseline
    %   'weak-code-only'                 -- code-only measurement mode
    %   'inconsistent'                   -- Jacobian audit finite-diff inconsistency
    %   'validation-known-ambiguity-only'-- convergence only in KAV run
    %   'carrier-float-ready'            -- carrier float/differential active
    %   'diagnostic-ready'               -- geometry present, no contradictions
    %
    % Usage:
    %   s     = revgnss.AttitudeScenarioReadiness.assess(out, cfg)
    %   rk    = revgnss.AttitudeScenarioReadiness.geometryRank(g)
    %   m     = revgnss.AttitudeScenarioReadiness.measurementModeSummary(cfg)
    %   lines = revgnss.AttitudeScenarioReadiness.summaryLines(s)

    methods (Static)

        function s = assess(out, cfg)
            % assess  Classify single-asset attitude scenario readiness.
            s = revgnss.AttitudeScenarioReadiness.blank_();

            if isfield(cfg,'diagnostics') && isfield(cfg.diagnostics,'attitudeScenarioReadiness') && ...
                    isfield(cfg.diagnostics.attitudeScenarioReadiness,'enable')
                s.enabled = logical(cfg.diagnostics.attitudeScenarioReadiness.enable);
            end

            s.measurementModes = revgnss.AttitudeScenarioReadiness.measurementModeSummary(cfg);

            % Receiver geometry
            gOk = false;
            try
                g = revgnss.ReceiverGeometry.fromConfig(cfg);
                s.nReceivers             = g.nReceiversGeometry;
                s.hasNonzeroLeverArm     = g.hasNonzeroLeverArm;
                s.baselineCount          = numel(g.baselineLengths_m);
                if ~isempty(g.baselineLengths_m)
                    s.baselineMin_m = g.baselineMin_m;
                    s.baselineMax_m = g.baselineMax_m;
                end
                s.receiverGeometryRank   = revgnss.AttitudeScenarioReadiness.geometryRank(g);
                s.hasNoncollinearGeometry = (s.receiverGeometryRank >= 2);
                gOk = true;
            catch ex
                s.warnings{end+1} = sprintf('Receiver geometry unavailable: %s', ex.message);
                s.classification  = 'unavailable';
                s.readyLevel      = 0;
                s.readinessScore  = 0;
                return
            end

            % Observability
            try
                ao = out.diag.getLastAttitudeAudit();
                if isstruct(ao) && isfield(ao,'classification')
                    s.observabilityClassification = ao.classification;
                end
            catch; end

            % Jacobian audit
            try
                ja = out.diag.getLastAttitudeJacobianAudit();
                if isstruct(ja) && isfield(ja,'classification')
                    s.jacobianAuditClassification = ja.classification;
                end
            catch; end

            % Evidence
            try
                tmp.diag    = out.diag;
                tmp.summary = out.summary;
                aev = revgnss.AttitudeEvidenceReport.summarize(tmp, cfg);
                s.evidenceClassification = aev.classification;
            catch; end

            s.classification = revgnss.AttitudeScenarioReadiness.classify_(s);
            s.readyLevel     = revgnss.AttitudeScenarioReadiness.levelFor_(s.classification);
            s.readinessScore = revgnss.AttitudeScenarioReadiness.score_(s);

            s.limitations{end+1} = ...
                'This is a readiness gate only. It is not an attitude accuracy claim, not integer ambiguity fixing, and not operational certification.';
            if s.nReceivers == 2
                s.limitations{end+1} = ...
                    'Two receivers provide one baseline; this constrains some attitude components but is not full 3-axis attitude.';
            end
            if s.receiverGeometryRank < 3
                s.limitations{end+1} = sprintf( ...
                    'Geometry rank %d < 3: not a full 3-axis rigid-body attitude basis.', ...
                    s.receiverGeometryRank);
            end
            if s.measurementModes.hasCarrierFloat
                s.limitations{end+1} = ...
                    'Carrier-float attitude: ambiguities floating, not integer-fixed.';
            end
        end

        function rk = geometryRank(g)
            % geometryRank  SVD rank of lever arms centered on their centroid.
            rk = 0;
            if ~isfield(g,'leverArms_body_m') || size(g.leverArms_body_m,2) < 1; return; end
            A  = g.leverArms_body_m - g.centroid_body_m;
            if all(A(:) == 0); return; end
            sv  = svd(A);
            tol = max(max(size(A)) * eps(max(sv)), 1e-9);
            rk  = sum(sv > tol);
        end

        function m = measurementModeSummary(cfg)
            % measurementModeSummary  Extract measurement mode flags from cfg.
            m.codeEnabled      = true;
            m.dopplerEnabled   = false;
            m.carrierEnabled   = false;
            m.carrierMode      = 'none';
            m.ambiguityMode    = 'none';
            m.attitudeCarrierMode         = 'none';
            m.knownAmbiguityValidation    = false;
            m.hasCarrierFloat             = false;
            m.hasKnownAmbiguityValidationOnly = false;
            try
                if isfield(cfg,'measurements')
                    mm = cfg.measurements;
                    if isfield(mm,'doppler')    && isfield(mm.doppler,'enable')
                        m.dopplerEnabled = logical(mm.doppler.enable); end
                    if isfield(mm,'carrierPhase') && isfield(mm.carrierPhase,'enable')
                        m.carrierEnabled = logical(mm.carrierPhase.enable); end
                    if isfield(mm,'carrierMode')
                        m.carrierMode = char(mm.carrierMode); end
                end
                if isfield(cfg,'estimation') && isfield(cfg.estimation,'ambiguityMode')
                    m.ambiguityMode = char(cfg.estimation.ambiguityMode); end
                if isfield(cfg,'estimator')
                    est = cfg.estimator;
                    if isfield(est,'attitudeCarrierMode')
                        m.attitudeCarrierMode = char(est.attitudeCarrierMode); end
                    if isfield(est,'runKnownAmbiguityValidation')
                        m.knownAmbiguityValidation = logical(est.runKnownAmbiguityValidation); end
                end
                m.hasCarrierFloat = m.carrierEnabled && ...
                    (strcmp(m.carrierMode,'ekfFloat') || strcmp(m.carrierMode,'floatCarrier'));
                m.hasKnownAmbiguityValidationOnly = m.knownAmbiguityValidation && ~m.hasCarrierFloat;
            catch; end
        end

        function lines = summaryLines(s)
            % summaryLines  Concise cell array for embedding in report or console.
            lines = {};
            lines{end+1} = sprintf('Classification         : %s', s.classification);
            lines{end+1} = sprintf('Ready level            : %d', s.readyLevel);
            lines{end+1} = sprintf('Readiness score        : %d', s.readinessScore);
            lines{end+1} = sprintf('Receivers              : %d', s.nReceivers);
            lines{end+1} = sprintf('Geometry rank          : %d', s.receiverGeometryRank);
            lines{end+1} = sprintf('Baselines              : %d', s.baselineCount);
            if isfinite(s.baselineMin_m) && isfinite(s.baselineMax_m)
                lines{end+1} = sprintf('Baseline min/max (m)   : %.3f / %.3f', ...
                    s.baselineMin_m, s.baselineMax_m);
            end
            lines{end+1} = sprintf('Nonzero lever arm      : %s', mat2str(s.hasNonzeroLeverArm));
            lines{end+1} = sprintf('Noncollinear geometry  : %s', mat2str(s.hasNoncollinearGeometry));
            lines{end+1} = sprintf('Carrier float active   : %s', mat2str(s.measurementModes.hasCarrierFloat));
            lines{end+1} = sprintf('Carrier mode           : %s', s.measurementModes.carrierMode);
            lines{end+1} = sprintf('Attitude carrier mode  : %s', s.measurementModes.attitudeCarrierMode);
            lines{end+1} = sprintf('Observability          : %s', s.observabilityClassification);
            lines{end+1} = sprintf('Jacobian audit         : %s', s.jacobianAuditClassification);
            lines{end+1} = sprintf('Evidence               : %s', s.evidenceClassification);
        end

    end

    methods (Static, Access = private)

        function cls = classify_(s)
            if s.nReceivers < 2
                cls = 'not-ready-single-receiver'; return
            end
            if ~s.hasNonzeroLeverArm
                cls = 'not-ready-zero-lever-arm'; return
            end
            if s.receiverGeometryRank < 2 || s.baselineCount < 2
                cls = 'weak-two-receiver-baseline'; return
            end
            if strcmp(s.observabilityClassification, 'weak-code-only')
                cls = 'weak-code-only'; return
            end
            if strcmp(s.jacobianAuditClassification, 'finite-diff-inconsistent')
                cls = 'inconsistent'; return
            end
            if strcmp(s.evidenceClassification, 'validation-known-ambiguity-only')
                cls = 'validation-known-ambiguity-only'; return
            end
            if s.measurementModes.hasCarrierFloat || ...
               strcmp(s.evidenceClassification, 'bounded-float-evidence')
                cls = 'carrier-float-ready'; return
            end
            cls = 'diagnostic-ready';
        end

        function lv = levelFor_(cls)
            switch cls
                case {'unavailable','inconsistent'};             lv = 0;
                case {'not-ready-single-receiver','not-ready-zero-lever-arm'}; lv = 1;
                case {'weak-two-receiver-baseline','weak-code-only'};          lv = 2;
                case {'diagnostic-ready','validation-known-ambiguity-only'};   lv = 3;
                case 'carrier-float-ready';                      lv = 4;
                otherwise;                                       lv = 0;
            end
        end

        function sc = score_(s)
            sc = 0;
            if s.nReceivers >= 2;                   sc = sc + 1; end
            if s.hasNonzeroLeverArm;                sc = sc + 1; end
            if s.receiverGeometryRank >= 2;         sc = sc + 1; end
            if s.baselineCount >= 3;                sc = sc + 1; end
            if s.hasNoncollinearGeometry;           sc = sc + 1; end
            if s.measurementModes.carrierEnabled;   sc = sc + 1; end
            if s.measurementModes.hasCarrierFloat;  sc = sc + 1; end
        end

        function s = blank_()
            s.enabled                     = false;
            s.classification              = 'unavailable';
            s.readyLevel                  = 0;
            s.readinessScore              = 0;
            s.nReceivers                  = 0;
            s.receiverGeometryRank        = 0;
            s.baselineCount               = 0;
            s.baselineMin_m               = NaN;
            s.baselineMax_m               = NaN;
            s.hasNonzeroLeverArm          = false;
            s.hasNoncollinearGeometry     = false;
            s.measurementModes            = struct();
            s.observabilityClassification = 'unavailable';
            s.jacobianAuditClassification = 'unavailable';
            s.evidenceClassification      = 'unavailable';
            s.limitations                 = {};
            s.warnings                    = {};
        end

    end
end
