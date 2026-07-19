classdef SecondaryTwoWayTimeTransferBuilder
    % SecondaryTwoWayTimeTransferBuilder  Per-SECONDARY ground<->satellite two-way
    % time transfer (P3'). The per-asset twin of TwoWayTimeTransferBuilder (WP-A).
    %
    % PURPOSE
    %   WP5 anchors each secondary's clock b_tx through a ONE-WAY ground pseudorange, in
    %   which the clock is coupled to the near-radial range (the same radial<->clock wall
    %   the primary suffers). This builder adds the missing TWO-WAY (reciprocal) exchange
    %   between a ground tower and a SECONDARY, which cancels the range and observes the
    %   CLOCK DIFFERENCE directly -- H has +1 on the secondary clock state and NO position
    %   column, so it pins b_tx decoupled from the secondary radial. It is the only lever
    %   that meaningfully improves the per-satellite ABSOLUTE clock (and, via decoupling,
    %   the radial through the WP5 range row).
    %
    % PHYSICS (mirror of WP-A, per secondary si = asset ai = si+1)
    %   z (truth) = (b_sec_true - b_tower_true) + recip_true + noise
    %                 b_sec_true   = assets{ai}.clock.getBiasMeters()   (SAME source as ISL)
    %                 b_tower_true = towers{ti}.getClockBiasMeters()
    %   h (model) = (x(secClkIdx) - b_tower_model) + recip_est
    %                 b_tower_model = EKF tower-clock STATE if estimated, else broadcast product
    %   H: +1 on secClkIdx, -1 on the tower-clock state (if any). No position column.
    %
    % REVERSE-GNSS PREMISE
    %   This REQUIRES the secondary to TRANSMIT (a two-way exchange), which the baseline
    %   reverse-GNSS uplink scenario does not assume. It is therefore an explicit
    %   "with per-satellite two-way time transfer" enhancement: DEFAULT OFF, and the
    %   result must be labelled as such (it is not the plain reverse-GNSS geometry).
    %
    % FUSION / DOUBLE-COUNT SAFETY (same argument as WP-A vs the one-way pseudorange)
    %   The WP5 ground row and this two-way row both involve (b_sec - b_tower_i), but they
    %   are INDEPENDENT measurements (different signals/noise draws) -> fusion, not double
    %   counting; the clock is SUPPOSED to be observed by both. The one genuine trap, the
    %   tower-clock PRODUCT variance, is charged into R here ONLY when the tower clock is
    %   NOT an EKF state (mirror of the one-way guard) -> never counted in both P and R.
    %
    % GOLDEN SAFETY
    %   Disabled by default; also a no-op unless the secondary clocks are EKF states
    %   (estimateMode 'clocks'/'position'). Off -> empty stacks -> byte-identical.
    %
    %   [z,h,H,R,info] = revgnss.SecondaryTwoWayTimeTransferBuilder.build( ...
    %       cfg, errorChain, assets, towers, x, stateMap, nx, t_s);
    %   revgnss.SecondaryTwoWayTimeTransferBuilder.validateConfig(cfg);

    methods (Static)
        function [zAdd, hAdd, HAdd, RAdd, info] = build(cfg, errorChain, assets, towers, x, stateMap, nx, t_s)
            if nargin < 8 || isempty(t_s); t_s = 0; end
            g  = @(p,d) revgnss.SecondaryTwoWayTimeTransferBuilder.getNum_(cfg, p, d);
            gb = @(p,d) revgnss.SecondaryTwoWayTimeTransferBuilder.getBool_(cfg, p, d);
            info = struct('enabled', gb({'measurements','secondaryTwoWayTimeTransfer','enable'}, false), ...
                'useInEKF', false, 'nRows', 0, 'nEkfRows', 0, 'prefitRms_m', NaN, ...
                'note', '', 'productCorrelationN', 1, 'rows', struct([]));
            zAdd = []; hAdd = []; HAdd = zeros(0, nx); RAdd = zeros(0, 0);

            if ~info.enabled; return; end
            % Needs estimated secondary clock STATES to pin (else nothing to observe).
            if ~isfield(stateMap,'secondaryClockIdx') || isempty(stateMap.secondaryClockIdx); return; end
            useInEKF = gb({'measurements','secondaryTwoWayTimeTransfer','useInEKF'}, false);
            info.useInEKF = useInEKF;

            warmup_s = g({'measurements','secondaryTwoWayTimeTransfer','warmup_s'}, 0);
            if t_s < warmup_s; info.note = 'within warmup window; no rows'; return; end

            c        = revgnss.Constants.SPEED_OF_LIGHT_MPS;
            sigma_m  = g({'measurements','secondaryTwoWayTimeTransfer','sigma_m'}, 0.03);
            recipOn  = gb({'measurements','secondaryTwoWayTimeTransfer','includeReciprocityResidual'}, false);
            recipSig = g({'measurements','secondaryTwoWayTimeTransfer','reciprocitySigma_m'}, 0.005);
            elevMask = g({'estimator','elevationMask_rad'}, 5*pi/180);

            % Conservative tower-product correlation (mirror WP-A): inflate the product
            % variance by the number of correlated epochs per broadcast interval so the
            % sequential filter cannot average the piecewise-constant product bias below
            % the reference-clock floor.
            nCorr = 1;
            if gb({'measurements','secondaryTwoWayTimeTransfer','conservativeProductCorrelation'}, true)
                updInt = g({'clocks','tower','product','updateInterval_s'}, 30);
                dt_s   = g({'simulation','dt_s'}, 1);
                if isfinite(updInt) && isfinite(dt_s) && dt_s > 0; nCorr = max(1, round(updInt/dt_s)); end
            end
            info.productCorrelationN = nCorr;

            estTowerClocks = gb({'estimator','estimateTowerClocks'}, false);
            hasTowerState  = estTowerClocks && isfield(stateMap,'towerClockIdx') && ~isempty(stateMap.towerClockIdx);

            nT      = numel(towers);
            capable = revgnss.SecondaryTwoWayTimeTransferBuilder.capableTowers_(cfg, nT);
            epochIdx = 0; try; epochIdx = errorChain.epochIdx_; catch; end

            secIdx = stateMap.secondaryClockIdx;      % [(N-1) x >=1]
            nSec   = size(secIdx, 1);
            rowsMeta = struct([]);
            for si = 1:nSec
                ai = si + 1;
                if numel(assets) < ai || isempty(assets{ai}); continue; end
                clkCol = secIdx(si, 1);
                if clkCol <= 0; continue; end

                sec      = assets{ai};
                r_sec_t  = sec.r_ecef_m(:);   v_sec_t = sec.v_ecef_mps(:);
                b_sec_true = sec.clock.getBiasMeters();
                b_sec_est  = x(clkCol);

                % Estimated secondary position/velocity for the reciprocity model, used ONLY
                % when the orbit is an EKF state (position mode). In clocks mode there is no
                % orbit state, so the reciprocity model is omitted below (no truth enters h).
                r_sec_e = []; v_sec_e = []; hasOrbitState = false; orbVelCols = [];
                if isfield(stateMap,'secondaryOrbitIdx') && ~isempty(stateMap.secondaryOrbitIdx) && ...
                        si <= size(stateMap.secondaryOrbitIdx,1)
                    oi = stateMap.secondaryOrbitIdx(si,:);
                    r_sec_e = x(oi(1:3)); r_sec_e = r_sec_e(:);
                    v_sec_e = x(oi(4:6)); v_sec_e = v_sec_e(:);
                    hasOrbitState = true; orbVelCols = oi(4:6);
                end

                for ti = capable(:)'
                    r_twr_t = models.measurements.MeasurementModelUtils.towerPositionEcef(cfg, towers{ti}, ti, 'truth', t_s);
                    if models.frames.GeometryUtils.elevationAngle(r_twr_t, r_sec_t) < elevMask; continue; end
                    r_twr_e = models.measurements.MeasurementModelUtils.towerPositionEcef(cfg, towers{ti}, ti, 'model');
                    elev    = models.frames.GeometryUtils.elevationAngle(r_twr_t, r_sec_t);

                    % Tower clock: state (-1 column, no product var) or product (charge var).
                    b_tw_true = towers{ti}.getClockBiasMeters();
                    towerCol = 0; sig_prod = 0; addProductVar = false;
                    if hasTowerState && ti <= size(stateMap.towerClockIdx,1) && stateMap.towerClockIdx(ti,1) > 0
                        towerCol   = stateMap.towerClockIdx(ti,1);
                        b_tw_model = x(towerCol);
                    else
                        [~, tcv, tsv] = models.clocks.TowerClockCorrectionProvider.compute(cfg, errorChain, towers, ti, t_s);
                        b_tw_model = tcv(1); sig_prod = tsv(1); addProductVar = true;
                        if ~isfinite(b_tw_model); b_tw_model = 0; end
                        if ~isfinite(sig_prod);   sig_prod = 0;   end
                    end

                    % Optional reciprocity residual (secondary moving during the round trip).
                    % recip_t (truth) enters z. recip_e (model) enters h ONLY when the secondary
                    % geometry is an ESTIMATED state (position mode) -- keeping h free of any truth
                    % quantity. In clocks mode the model omits reciprocity (recip_e=0) and its
                    % recipSig^2 in R covers the unmodelled residual.
                    recip_t = 0; recip_e = 0; velRow = zeros(1,3);
                    if recipOn
                        rhoDot_t = revgnss.OneWayRangeRateModel.compute(r_sec_t, v_sec_t, r_twr_t, cfg);
                        rho_t    = max(norm(r_sec_t - r_twr_t), 1);
                        recip_t  = -(rhoDot_t * rho_t) / c;
                        if hasOrbitState
                            rhoDot_e = revgnss.OneWayRangeRateModel.compute(r_sec_e, v_sec_e, r_twr_e, cfg);
                            d_e = r_sec_e - r_twr_e; rho_e = max(norm(d_e),1); u_e = d_e/rho_e;
                            recip_e  = -(rhoDot_e * rho_e) / c;
                            velRow   = -(rho_e / c) * u_e';
                        end
                    end

                    node = ti * 64 + ai;   % identity key (tower + asset)
                    n = sigma_m * revgnss.SecondaryTwoWayTimeTransferBuilder.draw_(errorChain, node, epochIdx);

                    zi = (b_sec_true - b_tw_true)  + recip_t + n;
                    hi = (b_sec_est  - b_tw_model) + recip_e;

                    Hi = zeros(1, nx);
                    Hi(clkCol) = 1;                          % secondary clock: +1 (range cancels)
                    if towerCol > 0; Hi(towerCol) = -1; end
                    if recipOn && hasOrbitState; Hi(orbVelCols) = Hi(orbVelCols) + velRow; end

                    Ri = sigma_m^2;
                    if addProductVar; Ri = Ri + nCorr * sig_prod^2; end
                    if recipOn;       Ri = Ri + recipSig^2; end

                    if useInEKF
                        zAdd(end+1,1) = zi; hAdd(end+1,1) = hi; HAdd(end+1,:) = Hi; %#ok<AGROW>
                        RAdd = blkdiag(RAdd, Ri);
                    end
                    meta = struct('assetIdx', ai, 'towerIdx', ti, 'elevation_rad', elev, ...
                        'clockDiffTruth_m', b_sec_true - b_tw_true, 'clockDiffModel_m', b_sec_est - b_tw_model, ...
                        'prefit_m', zi - hi, 'sigma_m', sqrt(Ri), 'towerClockIsState', towerCol > 0);
                    if isempty(rowsMeta); rowsMeta = meta; else; rowsMeta(end+1) = meta; end %#ok<AGROW>
                end
            end

            info.rows     = rowsMeta;
            info.nRows    = numel(rowsMeta);
            info.nEkfRows = double(useInEKF) * numel(rowsMeta);
            if ~isempty(zAdd); info.prefitRms_m = sqrt(mean((zAdd - hAdd).^2)); end
        end

        function validateConfig(cfg)
            gb = @(p,d) revgnss.SecondaryTwoWayTimeTransferBuilder.getBool_(cfg, p, d);
            en = gb({'measurements','secondaryTwoWayTimeTransfer','enable'}, false);
            ui = gb({'measurements','secondaryTwoWayTimeTransfer','useInEKF'}, false);
            if ui && ~en
                error('SecondaryTwoWayTimeTransferBuilder:useGuard', ...
                    'secondaryTwoWayTimeTransfer.useInEKF=true requires .enable=true.');
            end
            if ~en; return; end
            sg = revgnss.SecondaryTwoWayTimeTransferBuilder.getNum_(cfg, {'measurements','secondaryTwoWayTimeTransfer','sigma_m'}, 0.03);
            if ~(isfinite(sg) && sg > 0)
                error('SecondaryTwoWayTimeTransferBuilder:sigma', ...
                    'secondaryTwoWayTimeTransfer.sigma_m must be a positive scalar.');
            end
            % Needs estimated secondary clocks to have anything to pin.
            if revgnss.MultiAssetConfig.secondaryClockCount(cfg) < 1
                error('SecondaryTwoWayTimeTransferBuilder:needsSecondaryClocks', ...
                    ['secondaryTwoWayTimeTransfer requires estimated secondary clocks ' ...
                     '(cfg.multiAsset.estimateMode ''clocks'' or ''position'', nSpaceAssets>=2).']);
            end
            if ui && ~gb({'rng','independentStreams','enable'}, true)
                error('SecondaryTwoWayTimeTransferBuilder:needsIndependentStreams', ...
                    'secondaryTwoWayTimeTransfer.useInEKF requires cfg.rng.independentStreams.enable=true.');
            end
        end
    end

    methods (Static, Access = private)
        function idx = capableTowers_(cfg, nT)
            tw = revgnss.SecondaryTwoWayTimeTransferBuilder.walk_(cfg, {'measurements','secondaryTwoWayTimeTransfer','towers'}, 'all');
            if (ischar(tw) || isstring(tw)) && strcmpi(char(tw),'all')
                idx = 1:nT;
            else
                idx = round(tw(:)'); idx = idx(idx >= 1 & idx <= nT);
            end
        end

        function v = draw_(errorChain, node, epochIdx)
            if ~isempty(errorChain) && isprop(errorChain,'useIndependentStreams') && errorChain.useIndependentStreams
                v = errorChain.drawKeyed(models.noise.RngSource.SEC_TWSTFT_TWOWAY, node, 0, 0, epochIdx, 1, 1);
            elseif ~isempty(errorChain)
                v = errorChain.drawNormal(1, 1);
            else
                v = 0;
            end
        end

        function tf = getBool_(cfg, path, def)
            v = revgnss.SecondaryTwoWayTimeTransferBuilder.walk_(cfg, path, def);
            tf = islogical(v) && isscalar(v) && v;
        end

        function v = getNum_(cfg, path, def)
            v = revgnss.SecondaryTwoWayTimeTransferBuilder.walk_(cfg, path, def);
            if ~isnumeric(v) || ~isscalar(v); v = def; end
        end

        function v = walk_(cfg, path, def)
            v = cfg;
            for k = 1:numel(path)
                if isstruct(v) && isfield(v, path{k}); v = v.(path{k}); else; v = def; return; end
            end
        end
    end
end
