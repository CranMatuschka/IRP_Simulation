classdef WideLaneNarrowLaneDiagnostics
    % Wide-lane / narrow-lane float ambiguity-combination diagnostics.
    %
    % Computes float wide-lane and narrow-lane ambiguity combination diagnostics
    % from the L1/L2 ambiguity covariance exported by the ambiguity state metadata.
    %
    % Let N1 = B_L1/lambda1, N2 = B_L2/lambda2 (cycle-domain ambiguities).
    %
    %   N_WL = N1 - N2  (wide-lane,   lambda_WL = c/(f1-f2) ~86.2 cm for GPS L1/L2)
    %   N_NL = N1 + N2  (narrow-lane, lambda_NL = c/(f1+f2) ~10.7 cm for GPS L1/L2)
    %
    % Covariance from metre-domain P_B (m^2) to cycle-domain P_N:
    %   D = [1/lambda1, -1/lambda2; 1/lambda1, 1/lambda2]
    %   P_N = D * P_pair * D'
    %
    % Key limitations:
    %   Float diagnostics only.  No ambiguity is fixed or rounded.
    %   LAMBDA/MLAMBDA, calibrated phase-bias products, and false-fix-risk
    %   control are NOT implemented in v1.
    %
    % classifications:
    %   'disabled'                  -- toggle not enabled
    %   'requested-no-pairs'        -- no L1/L2 pair metadata available
    %   'requested-no-covariance'   -- pair metadata present; Pamb unavailable
    %   'active-float-diagnostics'  -- pairs and covariance available
    %   'inconsistent'              -- dimension or frequency error

    methods (Static)

        function s = assess(summary, cfg)
            % assess  Wide-lane / narrow-lane float diagnostics from summary.
            s = revgnss.WideLaneNarrowLaneDiagnostics.blank_();

            s.requested = revgnss.WideLaneNarrowLaneDiagnostics.toggleEnabled_(cfg);
            if ~s.requested
                s.classification = 'disabled'; return
            end
            s.enabled = true;

            % Signal frequencies and WL/NL wavelengths
            try
                sigL1 = revgnss.SignalDefinition.get('L1');
                sigL2 = revgnss.SignalDefinition.get('L2');
                s.l1Frequency_Hz     = sigL1.frequency_Hz;
                s.l2Frequency_Hz     = sigL2.frequency_Hz;
                s.lambda1_m          = sigL1.wavelength_m;
                s.lambda2_m          = sigL2.wavelength_m;
                c_                   = 299792458;
                s.lambdaWideLane_m   = c_ / (sigL1.frequency_Hz - sigL2.frequency_Hz);
                s.lambdaNarrowLane_m = c_ / (sigL1.frequency_Hz + sigL2.frequency_Hz);
            catch ex
                s.warnings{end+1} = ['Signal lookup failed: ' ex.message];
                s.classification = 'inconsistent'; return
            end

            % Pair metadata
            hasPairs = isstruct(summary) && ...
                isfield(summary,'carrierIfPairMetadataAvailable') && ...
                summary.carrierIfPairMetadataAvailable && ...
                isfield(summary,'carrierIfAmbiguityPairCount') && ...
                isnumeric(summary.carrierIfAmbiguityPairCount) && ...
                summary.carrierIfAmbiguityPairCount > 0;
            if ~hasPairs
                s.warnings{end+1} = ['No L1/L2 pair metadata. Enable carrier IF EKF rows, ' ...
                    'Stage 41 ambiguity state metadata, and Stage 48 traceability.'];
                s.classification = 'requested-no-pairs'; return
            end

            nPairs = summary.carrierIfAmbiguityPairCount;
            s.pairMetadataAvailable = true;
            s.pairCount = nPairs;
            nAmb = 2 * nPairs;
            pairIdx = [(1:2:nAmb)', (2:2:nAmb)'];  % L1 at 2k-1, L2 at 2k

            % Covariance from the ambiguity state metadata
            hasPamb = isfield(summary,'ambiguityCovarianceSummary') && ...
                isstruct(summary.ambiguityCovarianceSummary) && ...
                isfield(summary.ambiguityCovarianceSummary,'Pamb') && ...
                ~isempty(summary.ambiguityCovarianceSummary.Pamb);
            if ~hasPamb
                s.warnings{end+1} = ['Pamb not available. Check nAmbiguities<=100 and ' ...
                    'cfg.diagnostics.ambiguityStateMetadata.enable.'];
                s.classification = 'requested-no-covariance'; return
            end

            s.covarianceAvailable = true;
            Pamb = summary.ambiguityCovarianceSummary.Pamb;
            try
                m = revgnss.WideLaneNarrowLaneDiagnostics.computePairMetrics( ...
                    pairIdx, Pamb, [], s.l1Frequency_Hz, s.l2Frequency_Hz);
                s.warnings = [s.warnings, m.warnings];

                vWL = m.sigmaWideLaneCycles(isfinite(m.sigmaWideLaneCycles));
                if ~isempty(vWL)
                    s.sigmaWideLaneCyclesMin  = min(vWL);
                    s.sigmaWideLaneCyclesMean = mean(vWL);
                    s.sigmaWideLaneCyclesMax  = max(vWL);
                    vWLm = m.sigmaWideLaneMetres(isfinite(m.sigmaWideLaneMetres));
                    if ~isempty(vWLm); s.sigmaWideLaneMetresMean = mean(vWLm); end
                end
                vNL = m.sigmaNarrowLaneCycles(isfinite(m.sigmaNarrowLaneCycles));
                if ~isempty(vNL)
                    s.sigmaNarrowLaneCyclesMin  = min(vNL);
                    s.sigmaNarrowLaneCyclesMean = mean(vNL);
                    s.sigmaNarrowLaneCyclesMax  = max(vNL);
                    vNLm = m.sigmaNarrowLaneMetres(isfinite(m.sigmaNarrowLaneMetres));
                    if ~isempty(vNLm); s.sigmaNarrowLaneMetresMean = mean(vNLm); end
                end
                vC = m.corrWideNarrow(isfinite(m.corrWideNarrow));
                if ~isempty(vC); s.maxAbsWideNarrowCorr = max(abs(vC)); end

                s.classification = 'active-float-diagnostics';
            catch ex
                s.warnings{end+1} = ['computePairMetrics failed: ' ex.message];
                s.classification = 'inconsistent';
            end

            % Arc consistency from summary fields (if available).
            if isfield(summary,'carrierIonoFreeArcConsistentPairs') && ...
                    isnumeric(summary.carrierIonoFreeArcConsistentPairs)
                s.arcMetadataAvailable = true;
                s.nArcConsistentPairs   = summary.carrierIonoFreeArcConsistentPairs;
                s.nArcInconsistentPairs = 0;
                if isfield(summary,'carrierIonoFreeArcInconsistentPairs') && ...
                        isnumeric(summary.carrierIonoFreeArcInconsistentPairs)
                    s.nArcInconsistentPairs = summary.carrierIonoFreeArcInconsistentPairs;
                end
                if s.nArcInconsistentPairs == 0
                    s.arcConsistencyClassification = 'all-consistent';
                elseif s.nArcConsistentPairs == 0
                    s.arcConsistencyClassification = 'all-inconsistent';
                else
                    s.arcConsistencyClassification = 'partial-inconsistency';
                end
            end
            % Block classification when enforcement is active and
            % arc-inconsistent pairs were present before filtering.
            try
                if isfield(summary,'carrierArcConsistencyEnforced') && ...
                        logical(summary.carrierArcConsistencyEnforced)
                    s.arcConsistencyEnforced = true;
                end
                if isfield(summary,'carrierIonoFreeArcSkippedPairs') && ...
                        isnumeric(summary.carrierIonoFreeArcSkippedPairs)
                    s.nArcSkippedPairs = summary.carrierIonoFreeArcSkippedPairs;
                end
                if isfield(summary,'carrierIonoFreeArcConsistentPairs') && ...
                        isnumeric(summary.carrierIonoFreeArcConsistentPairs)
                    s.nArcUsablePairs = summary.carrierIonoFreeArcConsistentPairs;
                end
                if s.arcConsistencyEnforced && s.nArcInconsistentPairs > 0
                    s.arcConsistencyBlocksDiagnostics = true;
                    s.classification = 'blocked-arc-inconsistent-pairs';
                end
            catch; end
        end

        function m = computePairMetrics(pairIdx, Pamb, stateIndices, f1_Hz, f2_Hz)
            % computePairMetrics  Per-pair WL/NL cycle-domain covariance propagation.
            %
            % D = [1/lambda1, -1/lambda2; 1/lambda1, 1/lambda2]
            % P_N = D * P_pair * D'   (cycle^2)
            % Does not assume diagonal covariance.

            c_   = 299792458;
            lam1 = c_ / f1_Hz;
            lam2 = c_ / f2_Hz;
            D    = [1/lam1, -1/lam2; 1/lam1, 1/lam2];
            lambdaWL = c_ / (f1_Hz - f2_Hz);
            lambdaNL = c_ / (f1_Hz + f2_Hz);

            nP = size(pairIdx, 1);
            m.sigmaWideLaneCycles   = NaN(nP, 1);
            m.sigmaNarrowLaneCycles = NaN(nP, 1);
            m.sigmaWideLaneMetres   = NaN(nP, 1);
            m.sigmaNarrowLaneMetres = NaN(nP, 1);
            m.corrWideNarrow        = NaN(nP, 1);
            m.lambdaWideLane_m      = lambdaWL;
            m.lambdaNarrowLane_m    = lambdaNL;
            m.warnings              = {};

            for k = 1:nP
                if isempty(stateIndices)
                    ri = pairIdx(k, 1);  ci = pairIdx(k, 2);
                else
                    [tf1, ri] = ismember(pairIdx(k,1), stateIndices);
                    [tf2, ci] = ismember(pairIdx(k,2), stateIndices);
                    if ~tf1 || ~tf2; continue; end
                end
                if ri < 1 || ci < 1 || ri > size(Pamb,1) || ci > size(Pamb,1); continue; end
                P_pair = Pamb([ri ci], [ri ci]);
                P_N    = D * P_pair * D';
                vWL = P_N(1,1);  vNL = P_N(2,2);
                if isfinite(vWL) && vWL >= 0
                    m.sigmaWideLaneCycles(k) = sqrt(vWL);
                    m.sigmaWideLaneMetres(k) = lambdaWL * m.sigmaWideLaneCycles(k);
                end
                if isfinite(vNL) && vNL >= 0
                    m.sigmaNarrowLaneCycles(k) = sqrt(vNL);
                    m.sigmaNarrowLaneMetres(k) = lambdaNL * m.sigmaNarrowLaneCycles(k);
                end
                if isfinite(m.sigmaWideLaneCycles(k)) && isfinite(m.sigmaNarrowLaneCycles(k)) && ...
                        m.sigmaWideLaneCycles(k) > 0 && m.sigmaNarrowLaneCycles(k) > 0
                    m.corrWideNarrow(k) = P_N(1,2) / ...
                        (m.sigmaWideLaneCycles(k) * m.sigmaNarrowLaneCycles(k));
                end
            end
        end

        function lines = summaryLines(s)
            if ~isstruct(s) || ~isfield(s,'classification')
                lines = {'WideLaneNarrowLaneDiagnostics: no summary.'}; return
            end
            lines = {};
            lines{end+1} = sprintf('Classification       : %s', s.classification);
            lines{end+1} = sprintf('Requested            : %s', mat2str(s.requested));
            if isfinite(s.lambdaWideLane_m)
                lines{end+1} = sprintf('LambdaWideLane (m)   : %.4f', s.lambdaWideLane_m);
                lines{end+1} = sprintf('LambdaNarrowLane (m) : %.5f', s.lambdaNarrowLane_m);
            end
            lines{end+1} = sprintf('PairMetadataAvail    : %s', mat2str(s.pairMetadataAvailable));
            if s.pairCount > 0
                lines{end+1} = sprintf('PairCount            : %d', s.pairCount);
            end
            lines{end+1} = sprintf('CovarianceAvail      : %s', mat2str(s.covarianceAvailable));
            if isfinite(s.sigmaWideLaneCyclesMean)
                lines{end+1} = sprintf('WL sigma mean (cyc)  : %.4f', s.sigmaWideLaneCyclesMean);
                lines{end+1} = sprintf('NL sigma mean (cyc)  : %.4f', s.sigmaNarrowLaneCyclesMean);
            end
            lines{end+1} = 'IntegerFixingImpl    : false';
            lines{end+1} = 'LambdaImpl           : false';
            lines{end+1} = 'FalseFixRiskCtrl     : false';
            lines{end+1} = 'PhaseBiasProducts    : false';
        end

    end

    methods (Static, Access = private)

        function ok = toggleEnabled_(cfg)
            ok = false;
            try; ok = logical(cfg.diagnostics.wideLaneNarrowLane.enable); catch; end
        end

        function s = blank_()
            s.enabled                    = false;
            s.requested                  = false;
            s.classification             = 'disabled';
            s.l1Frequency_Hz             = NaN;
            s.l2Frequency_Hz             = NaN;
            s.lambda1_m                  = NaN;
            s.lambda2_m                  = NaN;
            s.lambdaWideLane_m           = NaN;
            s.lambdaNarrowLane_m         = NaN;
            s.pairMetadataAvailable      = false;
            s.pairCount                  = 0;
            s.covarianceAvailable        = false;
            s.sigmaWideLaneCyclesMin     = NaN;
            s.sigmaWideLaneCyclesMean    = NaN;
            s.sigmaWideLaneCyclesMax     = NaN;
            s.sigmaNarrowLaneCyclesMin   = NaN;
            s.sigmaNarrowLaneCyclesMean  = NaN;
            s.sigmaNarrowLaneCyclesMax   = NaN;
            s.sigmaWideLaneMetresMean    = NaN;
            s.sigmaNarrowLaneMetresMean  = NaN;
            s.maxAbsWideNarrowCorr       = NaN;
            % Arc consistency fields.
            s.arcMetadataAvailable         = false;
            s.nArcConsistentPairs          = 0;
            s.nArcInconsistentPairs        = 0;
            s.arcConsistencyClassification = 'unavailable';
            % Enforcement fields.
            s.arcConsistencyEnforced          = false;
            s.nArcUsablePairs                 = 0;
            s.nArcSkippedPairs                = 0;
            s.arcConsistencyBlocksDiagnostics = false;
            s.integerFixingImplemented   = false;
            s.lambdaImplemented          = false;
            s.falseFixRiskControlled     = false;
            s.phaseBiasProductsAvailable = false;
            s.warnings                   = {};
            s.limitations                = {
                'Float wide-lane/narrow-lane diagnostics only; no ambiguity fixing.'
                'LAMBDA/MLAMBDA not implemented in v1.'
                'Calibrated fractional cycle bias / phase-bias products not available.'
                'False-fix-risk control not implemented in v1.'
            };
        end

    end
end
