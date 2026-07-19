classdef SwarmTwoWayTimeTransferBuilder
    % SwarmTwoWayTimeTransferBuilder  All-pairs satellite<->satellite two-way TIME transfer.
    %
    % The DUAL of P2' (SwarmTwoWayISLBuilder): a same-epoch two-way exchange between two
    % ESTIMATED satellites yields BOTH the two-way SUM (range, clocks cancel -> P2' baseline)
    % and the two-way DIFFERENCE (range cancels -> CLOCK DIFFERENCE). P2' uses the sum (shape);
    % this builder uses the difference to observe the inter-satellite clock offset directly and
    % pin the swarm's RELATIVE clocks to each other (a mesh sync), independent of the ground:
    %
    %     z = (b_i_true - b_k_true) + delayCalBias_ik + thermal      (BOTH truth clocks)
    %     h = (x(clk_i) - x(clk_k))                                  (BOTH estimated clock states)
    %     H: +1 on clk_i, -1 on clk_k.  NO position/velocity column (range cancelled).
    %
    % Clock nodes = the primary receiver clock (b_rx) + every secondary whose clock is an EKF
    % state (secondaryClockIdx). Needs >=1 estimated secondary clock (estimateMode 'clocks' or
    % 'position') so there is a second clock to difference against the primary.
    %
    % REVERSE-GNSS PREMISE: a two-way sat<->sat exchange needs BOTH satellites to transmit AND
    % receive (a full crosslink transceiver), which the baseline uplink scenario does not assume.
    % DEFAULT OFF, and results must be labelled "with inter-satellite two-way time transfer".
    %
    % FUSION / DOUBLE-COUNT SAFETY (same argument as P2'/P3'): the one-way ISL and this two-way
    % row both involve (b_i - b_k), but they are INDEPENDENT measurements (own RngSource streams)
    % -> fusion, not double counting. The turn-around DELAY-CAL bias (per link, constant + random
    % walk) is injected truth-side into z and charged into R with an nCorr inflation so the
    % sequential white-R filter cannot average it below the reference-clock floor (a delay-cal
    % STATE would be the rigorous alternative; deferred). Sagnac/relativistic terms are negligible
    % for a ~1 km GEO crosslink and not modelled.
    %
    % GOLDEN SAFETY: disabled by default; also a no-op unless there are >=2 estimated clocks.
    % Off -> empty stacks -> byte-identical.
    %
    %   [z,h,H,R,info] = revgnss.SwarmTwoWayTimeTransferBuilder.build( ...
    %       cfg, errorChain, assets, x, stateMap, nx, t_s);
    %   revgnss.SwarmTwoWayTimeTransferBuilder.validateConfig(cfg);

    methods (Static)
        function [zAdd, hAdd, HAdd, RAdd, info] = build(cfg, errorChain, assets, x, stateMap, nx, t_s)
            if nargin < 7; t_s = 0; end
            info = struct('enabled',false,'useInEKF',false,'nRows',0,'pairs',zeros(0,2), ...
                          'prefitRms_m',NaN,'rows',struct([]));
            zAdd = []; hAdd = []; HAdd = zeros(0, nx); RAdd = zeros(0, 0);

            g  = @(p,d) revgnss.SwarmTwoWayTimeTransferBuilder.getNum_(cfg, p, d);
            gb = @(p,d) revgnss.SwarmTwoWayTimeTransferBuilder.getBool_(cfg, p, d);
            if ~gb({'multiAsset','twoWayTimeTransferISL','enable'}, false); return; end
            info.enabled = true;
            useInEKF = gb({'multiAsset','twoWayTimeTransferISL','useInEKF'}, false);
            info.useInEKF = useInEKF;

            % Clock nodes: primary (b_rx) + secondaries with an estimated clock state.
            [nodeAi, nodeClk] = revgnss.SwarmTwoWayTimeTransferBuilder.clockNodes_(assets, stateMap);
            if numel(nodeAi) < 2; return; end   % need >=2 clocks to difference

            warmup_s = g({'multiAsset','twoWayTimeTransferISL','warmup_s'}, 0);
            if t_s < warmup_s; return; end

            sThermal = g({'multiAsset','twoWayTimeTransferISL','sigma_m'}, 0.03);       % ~100 ps
            sConst   = g({'multiAsset','twoWayTimeTransferISL','delayCal','sigma_const_m'}, 0.01);
            sRW      = g({'multiAsset','twoWayTimeTransferISL','delayCal','sigma_rw_m'}, 0.003);
            tau      = g({'multiAsset','twoWayTimeTransferISL','delayCal','tau_s'}, 3600);
            nCap     = g({'multiAsset','twoWayTimeTransferISL','delayCal','nCorrCap'}, 60);
            dt       = g({'simulation','dt_s'}, 1);
            epochIdx = 0; if dt > 0; epochIdx = round(t_s / dt); end
            nCorr    = min(max(tau/max(dt,eps),1), nCap);
            Rbias    = nCorr * (sConst^2 + sRW^2);

            pairs = revgnss.SwarmTwoWayTimeTransferBuilder.pairList_(cfg, nodeAi);
            rowsMeta = struct([]);
            for p = 1:size(pairs,1)
                ai = pairs(p,1); ak = pairs(p,2);                 % ai < ak, asset indices
                clkI = nodeClk(nodeAi == ai); clkK = nodeClk(nodeAi == ak);
                if isempty(clkI) || isempty(clkK); continue; end
                clkI = clkI(1); clkK = clkK(1);
                if numel(assets) < ak || isempty(assets{ai}) || isempty(assets{ak}); continue; end

                b_i_true = assets{ai}.clock.getBiasMeters();
                b_k_true = assets{ak}.clock.getBiasMeters();

                node    = ai*64 + ak;                             % unordered-pair id (ai<ak<=63)
                thermal = sThermal * errorChain.drawKeyed( ...
                    models.noise.RngSource.ISL_TWSTFT_THERMAL, node, 0, 0, epochIdx, 1, 1);
                delayB  = revgnss.SwarmTwoWayTimeTransferBuilder.delayBias_(errorChain, node, t_s, tau, sConst, sRW);

                zi = (b_i_true - b_k_true) + delayB + thermal;
                hi = x(clkI) - x(clkK);
                row = zeros(1, nx); row(clkI) = 1; row(clkK) = -1;   % +1 on clk_i, -1 on clk_k
                Rii = sThermal^2 + Rbias;

                if useInEKF
                    zAdd(end+1,1) = zi; hAdd(end+1,1) = hi; HAdd(end+1,:) = row; %#ok<AGROW>
                    RAdd = blkdiag(RAdd, Rii);
                end
                meta = struct('assetI', ai, 'assetK', ak, 'clockDiffTruth_m', b_i_true - b_k_true, ...
                    'clockDiffModel_m', x(clkI) - x(clkK), 'prefit_m', zi - hi, 'sigma_m', sqrt(Rii));
                if isempty(rowsMeta); rowsMeta = meta; else; rowsMeta(end+1) = meta; end %#ok<AGROW>
            end
            info.rows  = rowsMeta;
            info.pairs = pairs;
            info.nRows = numel(rowsMeta);
            if ~isempty(zAdd); info.prefitRms_m = sqrt(mean((zAdd - hAdd).^2)); end
        end

        function validateConfig(cfg)
            gb = @(p,d) revgnss.SwarmTwoWayTimeTransferBuilder.getBool_(cfg, p, d);
            gn = @(p,d) revgnss.SwarmTwoWayTimeTransferBuilder.getNum_(cfg, p, d);
            if ~gb({'multiAsset','twoWayTimeTransferISL','enable'}, false); return; end
            % Independent per-pair streams are required whenever ENABLED (mirror P2'): the
            % thermal/delay draws happen every epoch for the diagnostic meta even with
            % useInEKF=false, so a shared legacy stream would be silently perturbed.
            if ~gb({'rng','independentStreams','enable'}, true)
                error('SwarmTwoWayTimeTransferBuilder:needsIndependentStreams', ...
                    'twoWayTimeTransferISL requires cfg.rng.independentStreams.enable=true (order-independent per-pair stream).');
            end
            % Pair-node encoding node=ai*64+ak is a bijection only for ak<=63 (mirror P2').
            if gn({'scenario','nSpaceAssets'}, 1) > 63
                error('SwarmTwoWayTimeTransferBuilder:assetIndexRange', ...
                    'twoWayTimeTransferISL supports up to 63 assets (pair-node encoding).');
            end
            if gb({'multiAsset','twoWayTimeTransferISL','useInEKF'}, false)
                if revgnss.MultiAssetConfig.secondaryClockCount(cfg) < 1
                    error('SwarmTwoWayTimeTransferBuilder:needsSecondaryClocks', ...
                        ['twoWayTimeTransferISL.useInEKF requires estimated secondary clocks ' ...
                         '(cfg.multiAsset.estimateMode ''clocks'' or ''position'') so there is a ' ...
                         'second clock to difference against the primary.']);
                end
            end
            sg = gn({'multiAsset','twoWayTimeTransferISL','sigma_m'}, 0.03);
            if ~(isfinite(sg) && sg > 0)
                error('SwarmTwoWayTimeTransferBuilder:sigma', 'twoWayTimeTransferISL.sigma_m must be a positive scalar.');
            end
        end
    end

    methods (Static, Access = private)
        function [ais, clks] = clockNodes_(assets, stateMap)
            % Estimated-clock nodes: primary (b_rx) always; secondaries with a clock state.
            ais = 1; clks = stateMap.b_rx_idx;
            if isfield(stateMap,'secondaryClockIdx') && ~isempty(stateMap.secondaryClockIdx)
                for si = 1:size(stateMap.secondaryClockIdx,1)
                    ci = stateMap.secondaryClockIdx(si,1);
                    if ci > 0 && numel(assets) >= si+1 && ~isempty(assets{si+1})
                        ais(end+1) = si + 1; clks(end+1) = ci; %#ok<AGROW>
                    end
                end
            end
        end

        function pairs = pairList_(cfg, ais)
            sel = 'all';
            if isfield(cfg,'multiAsset') && isfield(cfg.multiAsset,'twoWayTimeTransferISL') && ...
                    isfield(cfg.multiAsset.twoWayTimeTransferISL,'links')
                sel = cfg.multiAsset.twoWayTimeTransferISL.links;
            end
            if (ischar(sel) || isstring(sel)) && strcmpi(char(sel),'all')
                pairs = nchoosek(sort(ais(:)), 2); return;
            end
            pairs = zeros(0,2);
            if isnumeric(sel) && size(sel,2) == 2
                inSet = @(a) any(ais == a);
                for r = 1:size(sel,1)
                    a = round(sel(r,1)); b = round(sel(r,2));
                    if a == b || ~inSet(a) || ~inSet(b); continue; end
                    pairs(end+1,:) = [min(a,b) max(a,b)]; %#ok<AGROW>
                end
                pairs = unique(pairs, 'rows');
            end
        end

        function b = delayBias_(ec, node, t_s, tau, sConst, sRW)
            % Per-link turn-around delay-cal bias: dominant constant + interval-correlated RW.
            src = models.noise.RngSource.ISL_TWSTFT_DELAYCAL;
            b0  = ec.drawKeyedInterval(src, node, 0, 0, 0);
            k   = floor(t_s/tau); f = t_s/tau - k;
            u0  = ec.drawKeyedInterval(src, node, 0, 1, k);
            u1  = ec.drawKeyedInterval(src, node, 0, 1, k+1);
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
