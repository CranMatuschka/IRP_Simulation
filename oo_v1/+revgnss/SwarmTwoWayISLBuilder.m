classdef SwarmTwoWayISLBuilder
    % SwarmTwoWayISLBuilder  P2' all-pairs symmetric two-way inter-satellite ranging.
    %
    % Same-epoch two-way ranging between a pair of ESTIMATED assets cancels both clocks,
    % so the observable is the clock-free BASELINE LENGTH |r_i - r_k|:
    %     z = |r_i_truth - r_k_truth| + delayCalBias_ik + thermal      (BOTH truth endpoints)
    %     h = |r_i_est   - r_k_est|                                     (BOTH estimated states)
    %     H: +u_ik' on r_i,  -u_ik' on r_k     (u_ik = (r_i - r_k)/|.|, points k->i)
    % No clock column (clocks cancel), no velocity column (range, not range-rate). Because the
    % two position blocks are equal-and-opposite, the row is BLIND to any rigid motion
    % (translation AND rotation) -- two-way ISL fixes the formation SHAPE, never its absolute
    % position or orientation. The absolute stays governed by the ground rows + Guard C NEES.
    %
    % FUSION, not replacement: these rows are ADDED on top of the P1' one-way ISL + WP5 ground
    % rows. The noise is drawn from independent identity-keyed streams (RngSource 22/23), and
    % one-way (range + clock difference) vs two-way (clock-free baseline) observe overlapping
    % functions of the SAME estimated state through INDEPENDENT measurements -> adds Fisher
    % information, not double-counting. (The legacy TwoWayISLMeasurementBuilder derives its row
    % FROM one-way samples -> that one has a genuine double-count guard; this builder does not.)
    %
    % Honesty: the real floor is per-link transponder turn-around + antenna PCO/PCV DELAY
    % CALIBRATION (33 ps = 1 cm), a slowly-varying bias (constant + random walk) injected
    % truth-side into z and charged into R with an nCorr inflation so the sequential white-R
    % filter cannot average it below ~sqrt(N). Sagnac/Shapiro, motion non-reciprocity (~0.7 um)
    % and clock-rate x light-time (~20 nm) are negligible for a ~1 km GEO baseline and not modelled.

    methods (Static)
        function [zAdd, hAdd, HAdd, RAdd, info] = build(cfg, errorChain, assets, x, stateMap, nx, t_s)
            if nargin < 7; t_s = 0; end
            info = struct('enabled',false,'nRows',0,'pairs',zeros(0,2),'rowCols',{{}}, ...
                          'ekfRowTypes',{{}},'prefitRms',NaN);
            zAdd = []; hAdd = []; HAdd = zeros(0, nx); RAdd = zeros(0, 0);

            if ~revgnss.SwarmTwoWayISLBuilder.getBool_(cfg, {'multiAsset','twoWayISL','enable'}, false)
                return;
            end
            E = revgnss.SwarmTwoWayISLBuilder.estimatedSet_(assets, stateMap);
            if numel(E) < 2; return; end
            info.enabled = true;

            g = @(p,d) revgnss.SwarmTwoWayISLBuilder.getNum_(cfg, p, d);
            sThermal = g({'multiAsset','twoWayISL','sigma_m'}, 0.01);
            sConst   = g({'multiAsset','twoWayISL','delayCal','sigma_const_m'}, 0.01);
            sRW      = g({'multiAsset','twoWayISL','delayCal','sigma_rw_m'}, 0.003);
            tau      = g({'multiAsset','twoWayISL','delayCal','tau_s'}, 3600);
            nCap     = g({'multiAsset','twoWayISL','delayCal','nCorrCap'}, 60);
            dt       = g({'simulation','dt_s'}, 1);
            epochIdx = 0; if dt > 0; epochIdx = round(t_s / dt); end
            nCorr    = min(max(tau/max(dt,eps),1), nCap);
            Rbias    = nCorr * (sConst^2 + sRW^2);

            pairs = revgnss.SwarmTwoWayISLBuilder.pairList_(cfg, E);
            rowCols = cell(1, size(pairs,1)); rt = cell(1, size(pairs,1));
            for p = 1:size(pairs,1)
                i = pairs(p,1); k = pairs(p,2);                  % i < k, canonical
                pI = revgnss.SwarmTwoWayISLBuilder.assetPosIdx_(stateMap, i);
                pK = revgnss.SwarmTwoWayISLBuilder.assetPosIdx_(stateMap, k);
                if isempty(pI) || isempty(pK); continue; end
                rI = x(pI); rI = rI(:);   rK = x(pK); rK = rK(:);
                d_est = rI - rK; rho_est = norm(d_est); if rho_est < 1; rho_est = 1; end
                u = d_est / rho_est;                             % 3x1, points k->i
                rho_truth = norm(assets{i}.r_ecef_m(:) - assets{k}.r_ecef_m(:));

                node    = i*64 + k;                              % unordered-pair id (i<k<=63)
                thermal = sThermal * errorChain.drawKeyed( ...
                    models.noise.RngSource.ISL_TWOWAY_THERMAL, node, 0, 0, epochIdx, 1, 1);
                delayB  = revgnss.SwarmTwoWayISLBuilder.delayBias_(errorChain, node, t_s, tau, sConst, sRW);

                z = rho_truth + delayB + thermal;
                h = rho_est;
                row = zeros(1, nx); row(pI) = u(:)'; row(pK) = -u(:)';   % +u' on r_i, -u' on r_k
                Rii = sThermal^2 + Rbias;

                zAdd(end+1,1) = z;   hAdd(end+1,1) = h;   HAdd(end+1,:) = row; %#ok<AGROW>
                RAdd = blkdiag(RAdd, Rii);
                rowCols{p} = [pI(:)' pK(:)']; rt{p} = 'islSwarmBaseline';
            end
            info.pairs       = pairs;
            info.rowCols     = rowCols(~cellfun(@isempty, rowCols));
            info.ekfRowTypes = rt(~cellfun(@isempty, rt));
            info.nRows       = numel(zAdd);
            if info.nRows > 0; info.prefitRms = sqrt(mean((zAdd - hAdd).^2)); end
        end

        function h = predictEkfRows(~, ~, x, stateMap, info)
            % predictEkfRows  Recompute h = rho_est for each stored pair from the update-time
            % estimate -- BOTH endpoints from x (never from *.r_ecef_m truth). Postfit-diagnostic.
            h = [];
            if isempty(info) || ~isfield(info,'pairs') || isempty(info.pairs); return; end
            for p = 1:size(info.pairs,1)
                pI = revgnss.SwarmTwoWayISLBuilder.assetPosIdx_(stateMap, info.pairs(p,1));
                pK = revgnss.SwarmTwoWayISLBuilder.assetPosIdx_(stateMap, info.pairs(p,2));
                if isempty(pI) || isempty(pK); continue; end
                d = x(pI) - x(pK); d = d(:); rho = norm(d); if rho < 1; rho = 1; end
                h(end+1,1) = rho; %#ok<AGROW>
            end
        end

        function validateConfig(cfg)
            if ~revgnss.SwarmTwoWayISLBuilder.getBool_(cfg, {'multiAsset','twoWayISL','enable'}, false); return; end
            mode = 'off';
            if isfield(cfg,'multiAsset') && isfield(cfg.multiAsset,'estimateMode') && ischar(cfg.multiAsset.estimateMode)
                mode = cfg.multiAsset.estimateMode;
            end
            if ~strcmp(mode,'position')
                error('SwarmTwoWayISLBuilder:positionModeRequired', ...
                    'cfg.multiAsset.twoWayISL.enable requires estimateMode=''position'' (both endpoints must be estimated states).');
            end
            nA = revgnss.SwarmTwoWayISLBuilder.getNum_(cfg, {'scenario','nSpaceAssets'}, 1);
            if nA < 2
                error('SwarmTwoWayISLBuilder:assetCount', 'twoWayISL requires cfg.scenario.nSpaceAssets>=2.');
            end
            if nA > 63
                error('SwarmTwoWayISLBuilder:assetIndexRange', 'twoWayISL supports up to 63 assets (pair-node encoding).');
            end
            if ~revgnss.SwarmTwoWayISLBuilder.getBool_(cfg, {'multiAsset','towersObserveSecondaries'}, false)
                error('SwarmTwoWayISLBuilder:needsGroundAnchor', ...
                    'twoWayISL requires cfg.multiAsset.towersObserveSecondaries=true (clock/absolute anchor; two-way is rigid-motion blind).');
            end
            if revgnss.SwarmTwoWayISLBuilder.getBool_(cfg, {'measurements','isl','twoWay','range','useInEKF'}, false)
                error('SwarmTwoWayISLBuilder:legacyTwoWayConflict', ...
                    'twoWayISL conflicts with the legacy cfg.measurements.isl.twoWay.range.useInEKF (circular stub). Enable only one.');
            end
            if ~revgnss.SwarmTwoWayISLBuilder.getBool_(cfg, {'rng','independentStreams','enable'}, true)
                error('SwarmTwoWayISLBuilder:needsIndependentStreams', ...
                    'twoWayISL requires cfg.rng.independentStreams.enable=true (order-independent per-pair thermal stream).');
            end
        end
    end

    methods (Static, Access = private)
        function idx = assetPosIdx_(stateMap, ai)
            % 1x3 position-state columns for asset ai, or [] if not estimated.
            if ai == 1; idx = stateMap.r_idx(:)'; return; end
            idx = [];
            si = ai - 1;
            if isfield(stateMap,'secondaryOrbitIdx') && ~isempty(stateMap.secondaryOrbitIdx) && ...
                    si <= size(stateMap.secondaryOrbitIdx,1)
                idx = stateMap.secondaryOrbitIdx(si, 1:3);
            end
        end

        function E = estimatedSet_(assets, stateMap)
            % Estimated-asset index set: primary (always) + secondaries with an orbit block.
            E = 1;
            for ai = 2:numel(assets)
                if ~isempty(revgnss.SwarmTwoWayISLBuilder.assetPosIdx_(stateMap, ai))
                    E(end+1) = ai; %#ok<AGROW>
                end
            end
        end

        function pairs = pairList_(cfg, E)
            % Canonical i<k pairs from E. 'all' -> every pair; else a filtered/canonicalized list.
            sel = 'all';
            if isfield(cfg,'multiAsset') && isfield(cfg.multiAsset,'twoWayISL') && ...
                    isfield(cfg.multiAsset.twoWayISL,'links')
                sel = cfg.multiAsset.twoWayISL.links;
            end
            if (ischar(sel) || isstring(sel)) && strcmpi(char(sel),'all')
                pairs = nchoosek(sort(E(:)), 2);
                return;
            end
            pairs = zeros(0,2);
            if isnumeric(sel) && size(sel,2) == 2
                inE = @(a) any(E == a);
                for r = 1:size(sel,1)
                    a = round(sel(r,1)); b = round(sel(r,2));
                    if a == b || ~inE(a) || ~inE(b); continue; end
                    pairs(end+1,:) = [min(a,b) max(a,b)]; %#ok<AGROW>
                end
                pairs = unique(pairs, 'rows');
            end
        end

        function b = delayBias_(ec, node, t_s, tau, sConst, sRW)
            % Per-link delay-cal bias: dominant constant + interval-correlated random walk.
            % Both parts use drawKeyedInterval (ALWAYS identity-keyed -> order-independent).
            src = models.noise.RngSource.ISL_TWOWAY_DELAYCAL;
            b0  = ec.drawKeyedInterval(src, node, 0, 0, 0);         % sig=0 -> constant (interval 0)
            k   = floor(t_s/tau); f = t_s/tau - k;
            u0  = ec.drawKeyedInterval(src, node, 0, 1, k);         % sig=1 -> RW interval k
            u1  = ec.drawKeyedInterval(src, node, 0, 1, k+1);       %          interval k+1
            gRW = ((1-f)*u0 + f*u1) / sqrt((1-f)^2 + f^2);
            b   = sConst*b0 + sRW*gRW;
        end

        function v = getNum_(cfg, path, dflt)
            v = cfg;
            for j = 1:numel(path)
                if isstruct(v) && isfield(v, path{j}); v = v.(path{j}); else; v = dflt; return; end
            end
            if ~(isnumeric(v) && isscalar(v)); v = dflt; end
        end

        function tf = getBool_(cfg, path, dflt)
            v = cfg;
            for j = 1:numel(path)
                if isstruct(v) && isfield(v, path{j}); v = v.(path{j}); else; tf = dflt; return; end
            end
            tf = islogical(v) && isscalar(v) && v;
        end
    end
end
