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

            % --- Stage 31: attitude observability audit ---
            diag.attitude = revgnss.AttitudeObservability.audit(H, stateMap, cfg, measTypePerRow);
            diag.warnings = [diag.warnings, diag.attitude.warnings];
        end

        % ============================================================
        function obs = computeClockWindowObservability( ...
                H_phys_win, Rd_phys_win, H_gauge_win, Rd_gauge_win, ...
                dt_s, stateMap, rankTol)
            % computeClockWindowObservability  Windowed clock-subspace observability Gramian.
            %
            % Computes a weighted observability Gramian over a sliding time window:
            %
            %   W = sum_k  Phi_{k,K}' * H_clk_k' * R_k^{-1} * H_clk_k * Phi_{k,K}
            %
            % where Phi_{k,K} is the clock-state STM from epoch k to the newest epoch K.
            % For receiver+tower clocks, the STM is block-diagonal with [1 dt; 0 1] blocks.
            %
            % Physical-only W uses code/Doppler/carrier H rows restricted to clock columns.
            % Gauged W adds the gauge pseudo-rows to detect whether the gauge removes the
            % clock-datum nullspace that persists in one-way pseudorange.
            %
            % Inputs:
            %   H_phys_win   {K×1 cell} of [M_k × n_clk] physical H clock-column slices
            %   Rd_phys_win  {K×1 cell} of [M_k × 1]    physical R diagonal
            %   H_gauge_win  {K×1 cell} of [ng_k × n_clk] gauge H clock-column slices
            %   Rd_gauge_win {K×1 cell} of [ng_k × 1]   gauge R diagonal
            %   dt_s         scalar timestep [s]
            %   stateMap     struct from ReverseGNSSEKF.buildStateMap_()
            %   rankTol      [] for auto, or explicit tolerance
            %
            % Output (obs struct):
            %   clockStateIndices, clockStateNames
            %   rankPhysical, rankGauged
            %   conditionPhysical, conditionGauged
            %   singularValuesPhysical, singularValuesGauged
            %   weakStatesPhysical, weakStatesGauged
            %   gaugeImprovement.rankDelta, .conditionRatio
            %   windowLength, numRowsPhysical, numRowsGauged

            if nargin < 7; rankTol = []; end

            % Clock state column indices in the full state vector.
            % IMPORTANT: must be in interleaved pair order [b_rx;bdot_rx;b_twr1;bdot_twr1;...]
            % so that kron(eye(n_pairs),[1 dt;0 1]) correctly represents clock dynamics.
            % towerClockIdx is [N×2] (col1=bias, col2=drift); reshape' gives row-interleaved.
            clkIdx = [stateMap.b_rx_idx; stateMap.bdot_rx_idx];
            if isfield(stateMap,'towerClockIdx')
                tci    = stateMap.towerClockIdx;          % [N × 2]
                flat   = reshape(tci', [], 1);             % [2N × 1] interleaved
                clkIdx = [clkIdx; flat(flat > 0)];
            end
            clkIdx = clkIdx(clkIdx > 0);
            n_clk  = numel(clkIdx);

            % Clock state names for weak-state reporting
            clkNames = cell(n_clk, 1);
            clkNames{1} = 'b_rx';
            if n_clk >= 2; clkNames{2} = 'bdot_rx'; end
            if isfield(stateMap,'towerClockIdx')
                nT = size(stateMap.towerClockIdx, 1);
                for ti = 1:nT
                    bi = stateMap.towerClockIdx(ti,1);
                    di = stateMap.towerClockIdx(ti,2);
                    bpos = find(clkIdx == bi, 1);
                    dpos = find(clkIdx == di, 1);
                    if ~isempty(bpos); clkNames{bpos} = sprintf('b_twr%d', ti); end
                    if ~isempty(dpos); clkNames{dpos} = sprintf('bdot_twr%d', ti); end
                end
            end

            % Clock-subspace STM: block-diagonal [1 dt; 0 1] per clock pair
            n_pairs  = n_clk / 2;
            F_pair   = [1, dt_s; 0, 1];
            Phi_clk  = kron(eye(n_pairs), F_pair);

            % Build physical and gauge-extra Gramians
            K = numel(H_phys_win);
            W_phys  = zeros(n_clk);
            W_gauge = zeros(n_clk);   % gauge-only extra

            nRowsPhys  = 0;
            nRowsGauge = 0;

            Phi_acc = eye(n_clk);   % Phi_{k,K}: from newest (I) to oldest (Phi^(K-k))

            for i = K:-1:1          % newest to oldest
                Hp  = H_phys_win{i};
                Rdp = Rd_phys_win{i};
                if ~isempty(Hp) && ~isempty(Rdp) && numel(Rdp) == size(Hp,1) && all(Rdp > 0)
                    HtRH    = (Hp ./ Rdp)' * Hp;    % n_clk × n_clk
                    W_phys  = W_phys + Phi_acc' * HtRH * Phi_acc;
                    nRowsPhys = nRowsPhys + size(Hp,1);
                end

                Hg  = H_gauge_win{i};
                Rdg = Rd_gauge_win{i};
                if ~isempty(Hg) && ~isempty(Rdg) && numel(Rdg) == size(Hg,1) && all(Rdg > 0)
                    HtRH_g = (Hg ./ Rdg)' * Hg;
                    W_gauge = W_gauge + Phi_acc' * HtRH_g * Phi_acc;
                    nRowsGauge = nRowsGauge + size(Hg,1);
                end

                Phi_acc = Phi_clk * Phi_acc;         % one step further back
            end

            W_gauged = W_phys + W_gauge;

            % SVD rank and condition
            [obs.rankPhysical,  obs.conditionPhysical, obs.singularValuesPhysical, ...
             obs.weakStatesPhysical]  = revgnss.ObservabilityDiagnostics.svdRankCond_(W_phys,   n_clk, rankTol);
            [obs.rankGauged,    obs.conditionGauged,   obs.singularValuesGauged, ...
             obs.weakStatesGauged]    = revgnss.ObservabilityDiagnostics.svdRankCond_(W_gauged, n_clk, rankTol);

            obs.clockStateIndices = clkIdx;
            obs.clockStateNames   = clkNames;
            obs.windowLength      = K;
            obs.numRowsPhysical   = nRowsPhys;
            obs.numRowsGauged     = nRowsPhys + nRowsGauge;

            obs.gaugeImprovement.rankDelta = obs.rankGauged - obs.rankPhysical;
            if isfinite(obs.conditionPhysical) && obs.conditionGauged > 0
                obs.gaugeImprovement.conditionRatio = obs.conditionPhysical / obs.conditionGauged;
            else
                obs.gaugeImprovement.conditionRatio = NaN;
            end
        end

    end

    methods (Static, Access = private)

        function [rk, cond_num, sv, nWeak] = svdRankCond_(W, n_states, tol_override)
            % svdRankCond_  SVD-based rank, condition, and weak-state count.
            sv = svd(W, 'econ');
            if isempty(sv) || max(sv) == 0
                rk = 0; cond_num = Inf; sv = []; nWeak = n_states;
                return;
            end
            if nargin < 3 || isempty(tol_override)
                tol = max(n_states, size(W,1)) * eps(max(sv));
            else
                tol = tol_override;
            end
            sv_pos   = sv(sv > tol);
            rk       = numel(sv_pos);
            nWeak    = n_states - rk;
            if isempty(sv_pos)
                cond_num = Inf;
            else
                cond_num = sv_pos(1) / sv_pos(end);
            end
        end

    end
end
