classdef ObservabilityDiagnostics
    % ObservabilityDiagnostics  Runtime H-matrix rank and condition diagnostics.
    %
    % Use to detect underdetermined geometry, unconnected states, or
    % near-singular measurement configurations each epoch.

    methods (Static)

        function diag = analyze(H, stateMap, cfg)
            % analyze  Compute rank, condition number and issue warnings.
            %
            % Inputs:
            %   H        [M x nx]   measurement Jacobian
            %   stateMap struct     from ReverseGNSSEKF.buildStateMap_()
            %   cfg      struct     simulation config
            %
            % Output diag fields:
            %   nMeas          number of active rows
            %   nx             state dimension
            %   rank           numerical rank of H
            %   condNum        condition number of H
            %   warnings       cell array of warning strings (non-fatal)
            %   errors         cell array of error strings (fatal if strict mode)

            doWarn  = true;
            rankTol = [];
            if isfield(cfg,'diagnostics') && isfield(cfg.diagnostics,'observability')
                od = cfg.diagnostics.observability;
                if isfield(od,'warn');          doWarn  = od.warn;          end
                if isfield(od,'rankTolerance'); rankTol = od.rankTolerance; end
            end

            [M, nx] = size(H);
            diag.nMeas   = M;
            diag.nx      = nx;
            diag.rank    = NaN;
            diag.condNum = NaN;
            diag.warnings = {};
            diag.errors   = {};

            if M == 0 || nx == 0
                diag.warnings{end+1} = 'Empty H matrix: no measurements or no states.';
                return
            end

            % Numerical rank
            if isempty(rankTol)
                rankTol = max(M, nx) * eps(norm(H, 'fro'));
            end
            sv       = svd(H);
            diag.rank    = sum(sv > rankTol);
            diag.condNum = sv(1) / max(sv(end), eps);

            % Position + receiver clock submatrix (columns 1:3, 13)
            posClkIdx = [stateMap.r_idx(:)', stateMap.b_rx_idx];
            posClkIdx = posClkIdx(posClkIdx <= nx);
            if numel(posClkIdx) > 0
                Hsub = H(:, posClkIdx);
                rankSub = rank(Hsub, rankTol);
                if rankSub < min(M, numel(posClkIdx))
                    msg = sprintf('Position+clock H submatrix rank %d < %d. Check tower geometry.', ...
                        rankSub, numel(posClkIdx));
                    diag.warnings{end+1} = msg;
                    if doWarn; warning('ObservabilityDiagnostics:lowRankPosClk', '%s', msg); end
                end
            end

            % Minimum 4 code-like measurements for position+clock
            nCodeRows = M;
            if isfield(stateMap,'ambiguityIdx')
                nCodeRows = M - sum(any(H(:, stateMap.ambiguityIdx(:)) ~= 0, 2));
            end
            if nCodeRows < 4
                msg = sprintf('Only %d code-like measurements; need >= 4 for position+clock.', nCodeRows);
                diag.warnings{end+1} = msg;
                if doWarn; warning('ObservabilityDiagnostics:fewCodeMeas', '%s', msg); end
            end

            % Ambiguity states: must be connected to carrier rows
            if isfield(stateMap,'ambiguityIdx') && ~isempty(stateMap.ambiguityIdx)
                ambIdx = stateMap.ambiguityIdx(:)';
                ambIdx = ambIdx(ambIdx > 0 & ambIdx <= nx);
                for ai = ambIdx
                    if all(H(:, ai) == 0)
                        msg = sprintf('Ambiguity state %d has zero H column — not connected to any measurement.', ai);
                        diag.errors{end+1} = msg;
                        if doWarn; warning('ObservabilityDiagnostics:disconnectedAmbiguity', '%s', msg); end
                    end
                end
            end

            % Condition number warning
            if isfinite(diag.condNum) && diag.condNum > 1e12
                msg = sprintf('H condition number %.2e > 1e12. Near-singular geometry or unobservable states.', diag.condNum);
                diag.warnings{end+1} = msg;
                if doWarn; warning('ObservabilityDiagnostics:highCondNum', '%s', msg); end
            end
        end

    end
end
