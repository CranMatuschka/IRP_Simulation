classdef TwoWayTimeTransferBuilder
    % TwoWayTimeTransferBuilder  Tower<->spacecraft two-way time-transfer EKF rows.
    %
    % PURPOSE (scientific-completeness gap closed)
    %   Every sub-100 ps result in the project reference set (Merlo & Nanzer 2023;
    %   the sub-picosecond SDR receiver; EM-WaTT/TWSTFT; T2L2) is achieved by a
    %   TWO-WAY (reciprocal) link, because two-way exchange cancels the propagation
    %   path and the common-mode geometry, leaving the clock difference directly.
    %   The default oo_v1 scenario is a ONE-WAY uplink, in which the receiver clock
    %   is nearly degenerate with the GEO radial position (a radial shift looks like
    %   a clock shift). This builder adds the missing two-way observable so the EKF
    %   can observe the receiver clock DIRECTLY, decoupled from radial position.
    %
    % PHYSICS (first-order reciprocal TWSTFT)
    %   A two-way exchange between ground tower i (clock b_tower_i) and the
    %   spacecraft (receiver clock b_rx) yields, after the standard forward/return
    %   differencing, a range-cancelled measurement of the CLOCK DIFFERENCE:
    %
    %       Delta_i = (b_rx - b_tower_i) + recip_i        [metres]
    %
    %   The geometric range cancels by reciprocity; recip_i is the small residual
    %   non-reciprocity from spacecraft/tower relative motion during the ~2*rho/c
    %   round trip (optional, see includeReciprocityResidual). The Jacobian has
    %   NO position column (range cancelled) -> this is exactly what breaks the
    %   radial<->clock degeneracy.
    %
    % TRUTH / ESTIMATION SEPARATION (the boundary this project enforces)
    %   z (truth)  = (b_rx_true - b_tower_true) + recip_true + noise
    %                  b_rx_true    = asset.clock.getBiasMeters()      (truth)
    %                  b_tower_true = towers{ti}.getClockBiasMeters()  (truth)
    %                  noise        = sigma_m * identity-keyed white draw (RngSource.TWSTFT_TWOWAY)
    %   h (model)  = (b_rx_est - b_tower_model) + recip_est
    %                  b_rx_est     = x(b_rx_idx)                       (estimate)
    %                  b_tower_model= EKF tower-clock STATE if estimated, else the
    %                                 broadcast product (the SAME model the one-way
    %                                 code path uses -> consistent, no oracle)
    %   No truth quantity enters h or H. recip_true uses truth geometry; recip_est
    %   uses the estimated state, so the modelled reciprocity cancels to the level
    %   of the state error.
    %
    % DOUBLE-COUNTING SAFETY
    %   The two-way and the one-way pseudorange both involve (b_rx - b_tower_i), but
    %   they are INDEPENDENT measurements (different signals/noise) -- the clock is
    %   SUPPOSED to be observed by both; that is fusion, not double counting. The one
    %   genuine trap is the tower-clock PRODUCT variance: it is charged into R here
    %   ONLY when the tower clock is NOT an EKF state (mirror of the one-way guard in
    %   CodeMeasurementBuilder), so it is never counted in both P and R. The cross-
    %   covariance between the one-way and two-way rows of the same tower (shared
    %   product error) is neglected (block-diagonal R) -- the same documented v1
    %   simplification already stated in masterConfig for PR/Doppler.
    %
    % GOLDEN SAFETY
    %   Disabled by default (cfg.measurements.twoWayTimeTransfer.enable=false).
    %   When disabled the build returns empty stacks, so the measurement vector is
    %   byte-identical and both frozen goldens are unaffected.
    %
    % Usage:
    %   [z,h,H,R,info] = revgnss.TwoWayTimeTransferBuilder.build( ...
    %       cfg, errorChain, asset, towers, x, stateMap, nx, t_s);
    %   revgnss.TwoWayTimeTransferBuilder.validateConfig(cfg);   % called by finalizeConfig

    methods (Static)

        function [zAdd, hAdd, HAdd, RAdd, info] = build(cfg, errorChain, asset, towers, x, stateMap, nx, t_s)
            if nargin < 8 || isempty(t_s); t_s = 0; end
            info = revgnss.TwoWayTimeTransferBuilder.emptyInfo_(cfg);
            zAdd = []; hAdd = []; HAdd = zeros(0, nx); RAdd = zeros(0, 0);

            if ~revgnss.TwoWayTimeTransferBuilder.getBool_(cfg, {'measurements','twoWayTimeTransfer','enable'}, false)
                return
            end
            useInEKF = revgnss.TwoWayTimeTransferBuilder.getBool_(cfg, {'measurements','twoWayTimeTransfer','useInEKF'}, false);
            info.enabled  = true;
            info.useInEKF = useInEKF;

            warmup_s = revgnss.TwoWayTimeTransferBuilder.getNum_(cfg, {'measurements','twoWayTimeTransfer','warmup_s'}, 0);
            if t_s < warmup_s
                info.note = 'within warmup window; no rows';
                return
            end

            c         = revgnss.Constants.SPEED_OF_LIGHT_MPS;
            sigma_m   = revgnss.TwoWayTimeTransferBuilder.getNum_(cfg, {'measurements','twoWayTimeTransfer','sigma_m'}, 0.03);
            recipOn   = revgnss.TwoWayTimeTransferBuilder.getBool_(cfg, {'measurements','twoWayTimeTransfer','includeReciprocityResidual'}, false);
            recipSig  = revgnss.TwoWayTimeTransferBuilder.getNum_(cfg, {'measurements','twoWayTimeTransfer','reciprocitySigma_m'}, 0.005);
            elevMask  = revgnss.TwoWayTimeTransferBuilder.getNum_(cfg, {'estimator','elevationMask_rad'}, 5*pi/180);

            % CONSERVATIVE product-error correlation (default ON). The reference-tower
            % broadcast-product error is piecewise-CONSTANT over each update interval, so
            % the ~(interval/dt) two-way rows of a tower within one interval share the
            % SAME product bias. A sequential EKF that treats them as independent averages
            % that shared error down by ~sqrt(N) and drives the clock BELOW the reference-
            % clock floor (optimistic). We instead inflate the product variance by N_corr,
            % the number of correlated epochs per interval, so within-interval averaging
            % lands back at the true product sigma (the honest reference-clock floor) while
            % legitimate cross-interval averaging still applies. This is a conservative
            % (never under-confident) treatment of the time-correlated product error; the
            % rigorous alternative is a per-tower product-bias EKF state (future WP).
            consProdCorr = revgnss.TwoWayTimeTransferBuilder.getBool_(cfg, ...
                {'measurements','twoWayTimeTransfer','conservativeProductCorrelation'}, true);
            nCorr = 1;
            if consProdCorr
                updInt = revgnss.TwoWayTimeTransferBuilder.getNum_(cfg, {'clocks','tower','product','updateInterval_s'}, 30);
                dt_s   = revgnss.TwoWayTimeTransferBuilder.getNum_(cfg, {'simulation','dt_s'}, 1);
                if isfinite(updInt) && isfinite(dt_s) && dt_s > 0
                    nCorr = max(1, round(updInt / dt_s));
                end
            end

            estTowerClocks = revgnss.TwoWayTimeTransferBuilder.getBool_(cfg, {'estimator','estimateTowerClocks'}, false);
            hasTowerState  = estTowerClocks && isfield(stateMap,'towerClockIdx') && ~isempty(stateMap.towerClockIdx);

            nT       = numel(towers);
            capable  = revgnss.TwoWayTimeTransferBuilder.capableTowers_(cfg, nT);

            % Truth and estimated spacecraft states (clock common to all antennas).
            r_sat_t = asset.r_ecef_m(:);   v_sat_t = asset.v_ecef_mps(:);
            r_sat_e = x(stateMap.r_idx);    v_sat_e = x(stateMap.v_idx);
            b_rx_true = asset.clock.getBiasMeters();
            b_rx_est  = x(stateMap.b_rx_idx);

            epochIdx = 0;
            try; epochIdx = errorChain.epochIdx_; catch; end

            % --- Pass 1: elevation visibility (truth geometry) ------------------
            visTowers = [];
            for ti = capable(:)'
                r_twr_t = models.measurements.MeasurementModelUtils.towerPositionEcef(cfg, towers{ti}, ti, 'truth', t_s);
                if models.frames.GeometryUtils.elevationAngle(r_twr_t, r_sat_t) >= elevMask
                    visTowers(end+1) = ti; %#ok<AGROW>
                end
            end
            if isempty(visTowers); return; end

            % --- Model tower clock: SAME provider path as the one-way code h ----
            % (truthHistoryProductNoisy / product / etc.) so the two-way h is
            % consistent with the pseudorange model. Product uncertainty -> R.
            [~, towerClkModelVec, towerClkSigmaVec] = ...
                models.clocks.TowerClockCorrectionProvider.compute(cfg, errorChain, towers, visTowers(:), t_s);

            rowsMeta = struct([]);
            for jj = 1:numel(visTowers)
                ti = visTowers(jj);
                r_twr_t = models.measurements.MeasurementModelUtils.towerPositionEcef(cfg, towers{ti}, ti, 'truth', t_s);
                r_twr_e = models.measurements.MeasurementModelUtils.towerPositionEcef(cfg, towers{ti}, ti, 'model');
                elev    = models.frames.GeometryUtils.elevationAngle(r_twr_t, r_sat_t);

                % --- Clock difference (the observable) --------------------------
                b_tw_true = towers{ti}.getClockBiasMeters();
                towerCol  = 0; addProductVar = false; sig_prod = 0;
                if hasTowerState && ti <= size(stateMap.towerClockIdx,1) && stateMap.towerClockIdx(ti,1) > 0
                    % Tower clock is an EKF state: read the state, add a -1 column,
                    % and do NOT charge the product variance (state carries it).
                    % Mirrors the one-way tower-clock R guard -> no P-and-R double count.
                    towerCol   = stateMap.towerClockIdx(ti,1);
                    b_tw_model = x(towerCol);
                else
                    % Tower clock is the broadcast product (same model as one-way h):
                    % charge its prediction uncertainty into R (reference-clock floor).
                    b_tw_model = towerClkModelVec(jj);
                    sig_prod   = towerClkSigmaVec(jj);
                    addProductVar = true;
                    if ~isfinite(b_tw_model); b_tw_model = 0; end
                    if ~isfinite(sig_prod);   sig_prod   = 0; end
                end

                % --- Optional reciprocity residual (motion non-reciprocity) ------
                % recip = -(rhoDot * rho)/c : the leading two-way asymmetry from the
                % spacecraft moving during the round trip. Modelled on BOTH sides so
                % it cancels to the state-error level; residual covered by recipSig.
                recip_t = 0; recip_e = 0; velRow = zeros(1,3);
                if recipOn
                    [rhoDot_t] = revgnss.OneWayRangeRateModel.compute(r_sat_t, v_sat_t, r_twr_t, cfg);
                    rho_t   = max(norm(r_sat_t - r_twr_t), 1);
                    recip_t = -(rhoDot_t * rho_t) / c;
                    [rhoDot_e] = revgnss.OneWayRangeRateModel.compute(r_sat_e, v_sat_e, r_twr_e, cfg);
                    d_e   = r_sat_e - r_twr_e; rho_e = max(norm(d_e), 1); u_e = d_e / rho_e;
                    recip_e = -(rhoDot_e * rho_e) / c;
                    velRow  = -(rho_e / c) * u_e';   % d(recip)/dv (dominant partial)
                end

                % --- Measurement noise (identity-keyed truth draw) ---------------
                n = sigma_m * revgnss.TwoWayTimeTransferBuilder.draw_(errorChain, ti, epochIdx);

                zi = (b_rx_true - b_tw_true)  + recip_t + n;
                hi = (b_rx_est  - b_tw_model) + recip_e;

                Hi = zeros(1, nx);
                Hi(stateMap.b_rx_idx) = 1;              % receiver clock: +1 (range cancels)
                if towerCol > 0; Hi(towerCol) = -1; end % tower clock state: -1 (if estimated)
                if recipOn; Hi(stateMap.v_idx) = Hi(stateMap.v_idx) + velRow; end

                Ri = sigma_m^2;
                if addProductVar; Ri = Ri + nCorr * sig_prod^2; end   % conservative: correlated product error
                if recipOn;       Ri = Ri + recipSig^2; end

                if useInEKF
                    zAdd = [zAdd; zi];        %#ok<AGROW>
                    hAdd = [hAdd; hi];        %#ok<AGROW>
                    HAdd = [HAdd; Hi];        %#ok<AGROW>
                    RAdd = blkdiag(RAdd, Ri);
                end

                meta = struct('towerIdx', ti, 'elevation_rad', elev, ...
                    'clockDiffTruth_m', b_rx_true - b_tw_true, ...
                    'clockDiffModel_m', b_rx_est - b_tw_model, ...
                    'prefit_m', zi - hi, 'sigma_m', sqrt(Ri), ...
                    'towerClockIsState', towerCol > 0, 'productSigma_m', sig_prod, ...
                    'reciprocity_m', recip_t);
                if isempty(rowsMeta); rowsMeta = meta; else; rowsMeta(end+1) = meta; end %#ok<AGROW>

                info.observableRows(end+1) = revgnss.ObservableRowDescriptor.create( ...
                    0, 'twoWayTimeTransfer', sprintf('link:twtt:t%03d:sat', ti), 'TWTT', ...
                    ti, 1, revgnss.TwoWayTimeTransferBuilder.stateCols_(stateMap, towerCol, recipOn), ...
                    'Tower<->spacecraft two-way time transfer (WP-A)', ...
                    revgnss.TwoWayTimeTransferBuilder.role_(useInEKF));
            end

            info.rows        = rowsMeta;
            info.nRows       = numel(rowsMeta);
            info.nEkfRows    = double(useInEKF) * numel(rowsMeta);
            info.conservativeProductCorrelation = consProdCorr;
            info.productCorrelationN = nCorr;   % epochs/interval the product bias is shared over
            if ~isempty(zAdd); info.prefitRms_m = sqrt(mean((zAdd - hAdd).^2)); end
        end

        function validateConfig(cfg)
            % validateConfig  Guard two-way time-transfer config (called by finalizeConfig).
            % No-op when disabled -> golden configs are untouched.
            en = revgnss.TwoWayTimeTransferBuilder.getBool_(cfg, {'measurements','twoWayTimeTransfer','enable'}, false);
            ui = revgnss.TwoWayTimeTransferBuilder.getBool_(cfg, {'measurements','twoWayTimeTransfer','useInEKF'}, false);
            if ui && ~en
                error('TwoWayTimeTransferBuilder:useGuard', ...
                    ['cfg.measurements.twoWayTimeTransfer.useInEKF=true requires ' ...
                     'cfg.measurements.twoWayTimeTransfer.enable=true.']);
            end
            if ~en; return; end
            sg = revgnss.TwoWayTimeTransferBuilder.getNum_(cfg, {'measurements','twoWayTimeTransfer','sigma_m'}, 0.03);
            if ~(isfinite(sg) && sg > 0)
                error('TwoWayTimeTransferBuilder:sigma', ...
                    'cfg.measurements.twoWayTimeTransfer.sigma_m must be a positive scalar.');
            end
            tw = revgnss.TwoWayTimeTransferBuilder.walk_(cfg, {'measurements','twoWayTimeTransfer','towers'}, 'all');
            if ~(ischar(tw) && strcmpi(tw,'all')) && ~(isnumeric(tw) && all(tw >= 1))
                error('TwoWayTimeTransferBuilder:towers', ...
                    'cfg.measurements.twoWayTimeTransfer.towers must be ''all'' or a vector of tower indices.');
            end
        end

    end  % public static

    methods (Static, Access = private)

        function idx = capableTowers_(cfg, nT)
            tw = revgnss.TwoWayTimeTransferBuilder.walk_(cfg, {'measurements','twoWayTimeTransfer','towers'}, 'all');
            if ischar(tw) && strcmpi(tw, 'all')
                idx = 1:nT;
            else
                idx = tw(:)';
                idx = idx(idx >= 1 & idx <= nT);
            end
        end

        function v = draw_(errorChain, ti, epochIdx)
            % Identity-keyed white draw (order-independent) with legacy fallback.
            if ~isempty(errorChain) && isprop(errorChain,'useIndependentStreams') && errorChain.useIndependentStreams
                v = errorChain.drawKeyed(models.noise.RngSource.TWSTFT_TWOWAY, ti, 0, 0, epochIdx, 1, 1);
            elseif ~isempty(errorChain)
                v = errorChain.drawNormal(1, 1);
            else
                v = 0;
            end
        end

        function cols = stateCols_(stateMap, towerCol, recipOn)
            cols = stateMap.b_rx_idx;
            if towerCol > 0; cols = [cols, towerCol]; end
            if recipOn; cols = [cols, stateMap.v_idx(:)']; end
        end

        function r = role_(useInEKF)
            r = 'diagnosticOnly'; if useInEKF; r = 'physicalEKF'; end
        end

        function info = emptyInfo_(cfg)
            info = struct();
            info.enabled  = revgnss.TwoWayTimeTransferBuilder.getBool_(cfg, {'measurements','twoWayTimeTransfer','enable'}, false);
            info.useInEKF = false;
            info.nRows    = 0;
            info.nEkfRows = 0;
            info.prefitRms_m = NaN;
            info.note     = '';
            info.rows     = struct([]);
            info.observableRows = repmat( ...
                revgnss.ObservableRowDescriptor.create(0,'','','',NaN,NaN,[],'',''), 0, 1);
        end

        function tf = getBool_(cfg, path, def)
            v = revgnss.TwoWayTimeTransferBuilder.walk_(cfg, path, def);
            tf = islogical(v) && isscalar(v) && v;
        end

        function v = getNum_(cfg, path, def)
            v = revgnss.TwoWayTimeTransferBuilder.walk_(cfg, path, def);
            if ~isnumeric(v) || ~isscalar(v); v = def; end
        end

        function v = walk_(cfg, path, def)
            v = cfg;
            for k = 1:numel(path)
                if isstruct(v) && isfield(v, path{k}); v = v.(path{k});
                else; v = def; return; end
            end
        end

    end  % private static
end
