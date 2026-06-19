classdef CarrierIonoFreeAmbiguityTraceability
    % Stage 48: Carrier ionosphere-free ambiguity traceability.
    %
    % Each carrier ionosphere-free (IF) EKF row observes the non-integer linear
    % combination B_IF = alpha*B_L1 + beta*B_L2.  The EKF updates both the L1
    % and L2 ambiguity states jointly through a single innovation.  This helper
    % traces the pair of EKF states behind each IF row, propagates the IF
    % ambiguity variance from the Stage 41 covariance export, and classifies the
    % result for the report.
    %
    % Physics:
    %   B_IF = alpha*B_L1 + beta*B_L2   (not an integer)
    %   Var(B_IF) = [alpha beta] * P_pair * [alpha; beta]
    %
    % Key limitation:
    %   Var(B_IF) is provided for diagnostics only; it is not an integer-fixing
    %   criterion.  Integer fixing, LAMBDA/MLAMBDA are NOT implemented in v1.
    %
    % Pair ordering assumption (floatPerTowerReceiverSignal mode, nSignals=2):
    %   Ambiguity states ordered T->R->S (innermost=signal).
    %   L1 at positions 2k-1, L2 at positions 2k in Pamb (k=1..nPairs).
    %
    % classifications:
    %   'disabled'                  -- carrier IF EKF rows not used
    %   'metadata-unavailable'      -- Stage 41 ambiguity metadata absent
    %   'pairs-found-no-covariance' -- pairs inferred; Pamb not exported
    %   'active-float-traceability' -- pairs found and covariance propagated

    methods (Static)

        function s = assess(summary, cfg) %#ok<INUSD>
            % assess  Carrier IF ambiguity traceability from summary fields.
            s = revgnss.CarrierIonoFreeAmbiguityTraceability.blank_();

            % Carrier IF EKF rows must be active
            if ~(isstruct(summary) && isfield(summary,'carrierIonoFreeRowsUsedInEkf') && ...
                    summary.carrierIonoFreeRowsUsedInEkf)
                s.classification = 'disabled';
                return
            end

            % IF combination coefficients
            try
                sigL1 = revgnss.SignalDefinition.get('L1');
                sigL2 = revgnss.SignalDefinition.get('L2');
                [s.alpha, s.beta] = revgnss.IonoFreeCombination.coefficients( ...
                    sigL1.frequency_Hz, sigL2.frequency_Hz);
            catch ex
                s.warnings{end+1} = ['Signal lookup failed: ' ex.message];
                s.classification = 'metadata-unavailable';
                return
            end

            % Stage 41 ambiguity state metadata required
            hasMeta = isfield(summary,'ambiguityStateMetadata') && ...
                isstruct(summary.ambiguityStateMetadata) && ...
                isfield(summary.ambiguityStateMetadata,'nAmbiguities') && ...
                isnumeric(summary.ambiguityStateMetadata.nAmbiguities) && ...
                summary.ambiguityStateMetadata.nAmbiguities > 0;
            if ~hasMeta
                s.warnings{end+1} = ['Ambiguity state metadata unavailable. ' ...
                    'Enable cfg.diagnostics.ambiguityStateMetadata.enable.'];
                s.classification = 'metadata-unavailable';
                return
            end

            nAmb = summary.ambiguityStateMetadata.nAmbiguities;
            if mod(nAmb, 2) ~= 0
                s.warnings{end+1} = sprintf( ...
                    'nAmbiguities=%d is odd; L1/L2 pairing requires even count.', nAmb);
                s.classification = 'metadata-unavailable';
                return
            end

            nPairs = nAmb / 2;
            s.pairCount = nPairs;
            s.pairMetadataAvailable = true;
            % L1 at positions 2k-1, L2 at 2k in Pamb (T->R->S ordering)
            s.pairIndices = [(1:2:nAmb)', (2:2:nAmb)'];  % nPairs x 2

            % Covariance propagation from Stage 41 Pamb export
            hasPamb = isfield(summary,'ambiguityCovarianceSummary') && ...
                isstruct(summary.ambiguityCovarianceSummary) && ...
                isfield(summary.ambiguityCovarianceSummary,'Pamb') && ...
                ~isempty(summary.ambiguityCovarianceSummary.Pamb);

            if hasPamb
                try
                    Pamb = summary.ambiguityCovarianceSummary.Pamb;
                    s.ifAmbiguityStdDev = ...
                        revgnss.CarrierIonoFreeAmbiguityTraceability.computeIfAmbiguityStd( ...
                            s.pairIndices, Pamb, [], s.alpha, s.beta);
                    s.ifAmbiguityStdDevAvailable = true;
                    s.classification = 'active-float-traceability';
                catch ex
                    s.warnings{end+1} = ['Covariance propagation failed: ' ex.message];
                    s.classification = 'pairs-found-no-covariance';
                end
            else
                s.warnings{end+1} = ['Pamb not exported. Check nAmbiguities<=100 and ' ...
                    'cfg.diagnostics.ambiguityStateMetadata.enable.'];
                s.classification = 'pairs-found-no-covariance';
            end
        end

        function stdVec = computeIfAmbiguityStd(pairIdx, Pamb, stateIndices, alpha, beta)
            % computeIfAmbiguityStd  Propagate IF ambiguity std for each L1/L2 pair.
            %
            %   pairIdx      : nPairs x 2 row/col positions in Pamb (1-based),
            %                  or EKF state indices when stateIndices is provided
            %   Pamb         : ambiguity covariance sub-block (nAmb x nAmb)
            %   stateIndices : [] to use pairIdx directly as Pamb row/col;
            %                  or nAmb-vector mapping EKF states to Pamb positions
            %   alpha, beta  : IF combination coefficients
            %
            % Var(B_IF) = [alpha beta] * P_pair * [alpha; beta]'
            % Returns nPairs x 1 vector of IF ambiguity standard deviations (metres).

            nPairs = size(pairIdx, 1);
            w = [alpha, beta];
            stdVec = NaN(nPairs, 1);

            for k = 1:nPairs
                if isempty(stateIndices)
                    ri = pairIdx(k, 1);
                    ci = pairIdx(k, 2);
                else
                    [tf1, ri] = ismember(pairIdx(k,1), stateIndices);
                    [tf2, ci] = ismember(pairIdx(k,2), stateIndices);
                    if ~tf1 || ~tf2; continue; end
                end
                if ri < 1 || ci < 1 || ri > size(Pamb,1) || ci > size(Pamb,1)
                    continue
                end
                P_pair = Pamb([ri ci], [ri ci]);
                v = w * P_pair * w';
                if isfinite(v) && v >= 0
                    stdVec(k) = sqrt(v);
                end
            end
        end

        function s = fromSummary(summary, cfg)
            % fromSummary  Thin wrapper for report integration.
            s = revgnss.CarrierIonoFreeAmbiguityTraceability.assess(summary, cfg);
        end

        function lines = summaryLines(s)
            if ~isstruct(s) || ~isfield(s,'classification')
                lines = {'CarrierIonoFreeAmbiguityTraceability: no summary.'}; return
            end
            lines = {};
            lines{end+1} = sprintf('Classification       : %s', s.classification);
            lines{end+1} = sprintf('PairMetadataAvail    : %s', mat2str(s.pairMetadataAvailable));
            if s.pairCount > 0
                lines{end+1} = sprintf('IF Ambig pairs       : %d', s.pairCount);
            end
            if isfinite(s.alpha)
                lines{end+1} = sprintf('Alpha (L1 weight)    : %.6f', s.alpha);
                lines{end+1} = sprintf('Beta  (L2 weight)    : %.6f', s.beta);
            end
            lines{end+1} = sprintf('StdDevAvailable      : %s', mat2str(s.ifAmbiguityStdDevAvailable));
            if s.ifAmbiguityStdDevAvailable && ~isempty(s.ifAmbiguityStdDev)
                lines{end+1} = sprintf('StdDev min (m)       : %.4f', min(s.ifAmbiguityStdDev));
                lines{end+1} = sprintf('StdDev max (m)       : %.4f', max(s.ifAmbiguityStdDev));
            end
            lines{end+1} = 'B_IF is non-integer  : true (float only)';
            lines{end+1} = 'IntegerFixingImpl    : false';
            lines{end+1} = 'LambdaImpl           : false';
        end

    end

    methods (Static, Access = private)

        function s = blank_()
            s.classification            = 'disabled';
            s.pairMetadataAvailable     = false;
            s.pairCount                 = 0;
            s.pairIndices               = zeros(0, 2);
            s.alpha                     = NaN;
            s.beta                      = NaN;
            s.ifAmbiguityStdDevAvailable = false;
            s.ifAmbiguityStdDev         = [];
            s.integerAmbiguityIsNonInteger = true;
            s.integerFixingImplemented   = false;
            s.lambdaImplemented          = false;
            s.warnings                   = {};
        end

    end
end
