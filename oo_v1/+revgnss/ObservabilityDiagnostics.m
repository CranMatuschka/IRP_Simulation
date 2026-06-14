classdef ObservabilityDiagnostics
    % ObservabilityDiagnostics  Runtime H-matrix rank, condition, and state-connectivity diagnostics.
    %
    % Use to detect underdetermined geometry, unconnected states, or
    % near-singular measurement configurations each epoch.

    methods (Static)

        function diag = analyze(H, stateMap, cfg, measTypePerRow)
            % analyze  Compute rank, condition number, row/state counts, and connectivity.
            %
            % Inputs:
            %   H               [M x nx]   measurement Jacobian
            %   stateMap        struct     from ReverseGNSSEKF.buildStateMap_()
            %   cfg             struct     simulation config
            %   measTypePerRow  cell(M,1)  optional row type labels ('code','doppler','carrier')
            %
            % Output diag fields:
            %   nMeas           total active rows
            %   nCodeRows       rows labelled 'code' (or total if no labels)
            %   nDopplerRows    rows labelled 'doppler'
            %   nCarrierRows    rows labelled 'carrier'
            %   nx              state dimension
            %   nBaseStates     base 14-state count
            %   nTowerClockStates  tower clock state count
            %   nAmbiguityStates   ambiguity state count
            %   nZwdStates         ZWD state count
            %   rank            numerical rank of H
            %   condNum         condition number of H
            %   warnings        cell array of warning strings (non-fatal)
            %   errors          cell array of error strings (fatal if strict mode)

            if nargin < 4; measTypePerRow = {}; end

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

            % --- Row counts by type ---
            diag.nIFCodeRows = 0;  % IF combination code rows
            if ~isempty(measTypePerRow) && numel(measTypePerRow) == M
                diag.nCodeRows    = sum(strcmp(measTypePerRow,'code'));
                diag.nIFCodeRows  = sum(strcmp(measTypePerRow,'ifCode'));
                diag.nDopplerRows = sum(strcmp(measTypePerRow,'doppler'));
                diag.nCarrierRows = sum(strcmp(measTypePerRow,'carrier'));
            else
                % Approximate: count rows where any ambiguity column is non-zero as carrier
                if isfield(stateMap,'ambiguityIdx') && ~isempty(stateMap.ambiguityIdx)
                    ambCols = stateMap.ambiguityIdx(:)';
                    ambCols = ambCols(ambCols > 0 & ambCols <= nx);
                    isCarrier = any(H(:, ambCols) ~= 0, 2);
                    diag.nCarrierRows = sum(isCarrier);
                    diag.nCodeRows    = M - diag.nCarrierRows;
                else
                    diag.nCarrierRows = 0;
                    diag.nCodeRows    = M;
                end
                diag.nDopplerRows = 0;
            end

            % --- State counts by type ---
            diag.nBaseStates       = 14;   % fixed base
            diag.nTowerClockStates = 0;
            diag.nAmbiguityStates  = 0;
            diag.nZwdStates        = 0;
            if isfield(stateMap,'towerClockIdx') && ~isempty(stateMap.towerClockIdx)
                diag.nTowerClockStates = sum(stateMap.towerClockIdx(:) > 0);
            end
            if isfield(stateMap,'ambiguityIdx') && ~isempty(stateMap.ambiguityIdx)
                diag.nAmbiguityStates = sum(stateMap.ambiguityIdx(:) > 0);
            end
            if isfield(stateMap,'zwdIdx') && ~isempty(stateMap.zwdIdx)
                diag.nZwdStates = sum(stateMap.zwdIdx(:) > 0);
            end

            if M == 0 || nx == 0
                diag.warnings{end+1} = 'Empty H matrix: no measurements or no states.';
                return
            end

            % --- Numerical rank and condition ---
            if isempty(rankTol)
                rankTol = max(M, nx) * eps(norm(H, 'fro'));
            end
            sv           = svd(H);
            diag.rank    = sum(sv > rankTol);
            diag.condNum = sv(1) / max(sv(end), eps);

            % --- Position + receiver clock submatrix ---
            posClkIdx = [stateMap.r_idx(:)', stateMap.b_rx_idx];
            posClkIdx = posClkIdx(posClkIdx <= nx);
            if ~isempty(posClkIdx)
                Hsub    = H(:, posClkIdx);
                rankSub = rank(Hsub, rankTol);
                if rankSub < min(M, numel(posClkIdx))
                    msg = sprintf('Position+clock H submatrix rank %d < %d. Check tower geometry.', ...
                        rankSub, numel(posClkIdx));
                    diag.warnings{end+1} = msg;
                    if doWarn; warning('ObservabilityDiagnostics:lowRankPosClk', '%s', msg); end
                end
            end

            % --- Minimum code measurements ---
            if diag.nCodeRows < 4
                msg = sprintf('Only %d code rows; need >= 4 for position+clock observability.', diag.nCodeRows);
                diag.warnings{end+1} = msg;
                if doWarn; warning('ObservabilityDiagnostics:fewCodeMeas', '%s', msg); end
            end

            % --- Unconnected ambiguity states ---
            if isfield(stateMap,'ambiguityIdx') && ~isempty(stateMap.ambiguityIdx)
                ambIdx = stateMap.ambiguityIdx(:)';
                ambIdx = ambIdx(ambIdx > 0 & ambIdx <= nx);
                for ai = ambIdx
                    if all(H(:, ai) == 0)
                        msg = sprintf('Ambiguity state %d has zero H column — unconnected to any carrier measurement.', ai);
                        diag.errors{end+1} = msg;
                        if doWarn; warning('ObservabilityDiagnostics:disconnectedAmbiguity', '%s', msg); end
                    end
                end
            end

            % --- ZWD states without code/carrier rows ---
            if isfield(stateMap,'zwdIdx') && ~isempty(stateMap.zwdIdx)
                zwdIdx = stateMap.zwdIdx(:)';
                zwdIdx = zwdIdx(zwdIdx > 0 & zwdIdx <= nx);
                for zi = zwdIdx
                    if all(H(:, zi) == 0)
                        msg = sprintf('ZWD state %d has zero H column — no code/carrier rows contribute.', zi);
                        diag.warnings{end+1} = msg;
                        if doWarn; warning('ObservabilityDiagnostics:disconnectedZwd', '%s', msg); end
                    end
                end
            end

            % --- Tower-clock gauge freedom warning ---
            % When tower clocks are NOT estimated, the tower clock biases are
            % absorbed into the receiver clock and create gauge freedom unless
            % external corrections are applied.
            if isfield(stateMap,'towerClockIdx') && ~isempty(stateMap.towerClockIdx)
                estimatesClocks = any(stateMap.towerClockIdx(:) > 0);
            else
                estimatesClocks = false;
            end
            if ~estimatesClocks
                towerClkMode = '';
                if isfield(cfg,'estimator') && isfield(cfg.estimator,'towerClockMode')
                    towerClkMode = cfg.estimator.towerClockMode;
                end
                if strcmp(towerClkMode,'none')
                    msg = ['Tower clocks not estimated and no external correction applied. ' ...
                           'Tower clock biases create gauge freedom in the receiver clock solution.'];
                    diag.warnings{end+1} = msg;
                    if doWarn; warning('ObservabilityDiagnostics:towerClockGauge', '%s', msg); end
                end
            end

            % --- Carrier float ambiguity observability note ---
            if diag.nCarrierRows > 0 && diag.nAmbiguityStates > 0
                msg = ['Carrier float ambiguity states are observable only relative to other ' ...
                       'states; they do NOT provide absolute range information at a single epoch.'];
                diag.warnings{end+1} = msg;
                if doWarn; warning('ObservabilityDiagnostics:carrierAmbiguityRelative', '%s', msg); end
            end

            % --- Condition number warning ---
            if isfinite(diag.condNum) && diag.condNum > 1e12
                msg = sprintf('H condition number %.2e > 1e12. Near-singular geometry or unobservable states.', diag.condNum);
                diag.warnings{end+1} = msg;
                if doWarn; warning('ObservabilityDiagnostics:highCondNum', '%s', msg); end
            end
        end

    end
end
