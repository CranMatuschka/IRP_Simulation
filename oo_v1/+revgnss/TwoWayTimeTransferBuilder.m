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
    %   round trip (optional, see includeReciprocityResidual).
    %
    % WHY THIS BREAKS THE DEGENERACY -- AND WHICH AXIS IT ACTUALLY FIXES
    %   A one-way pseudorange row is  H_i = [ u_hat_i' | +1 ] : the position partial
    %   is the tower->s/c line-of-sight (LOS) unit vector, and the receiver clock
    %   enters EVERY row with the same +1 -- a common-mode, rank-1 term. A clock
    %   shift is therefore indistinguishable from the ONE position shift that also
    %   perturbs every row equally: the component along the *mean* LOS. From GEO the
    %   whole Earth subtends a cone of half-angle arcsin(R_earth/r_GEO) = 8.7 deg, so
    %   every tower LOS lies within 8.7 deg of nadir and the mean LOS ~= RADIAL.
    %   Hence one-way aliases the clock onto the RADIAL axis specifically -- measured
    %   corr(radial,clock) = -1.000, and STRUCTURAL (it persists into steady state).
    %   Along-track / cross-track perturb the rows DIFFERENTIALLY (opposite sign
    %   across the network), so they stay separable from the clock; they are merely
    %   weakly observed (small parallax), NOT degenerate with it.
    %
    %   The two-way row (see build, below) is
    %       H_i = [ 0_pos | +1 on b_rx | -1 on b_tower if that clock is an EKF state ]
    %   i.e. it observes the clock directly. The optional first-order
    %   reciprocity term adds small position and velocity partials, so it
    %   (a) pins the clock to the reciprocity/noise floor and (b) frees the RADIAL
    %   axis, since the clock can no longer absorb a radial shift. (With
    %   remains dominated by the clock-difference columns.
    %
    % SCOPE -- WHAT TWO-WAY DOES NOT FIX (honest limitation; do not over-read it)
    %   Two-way is a CLOCK observable: it sharpens the clock and the radial axis
    %   ONLY. Along-track and cross-track are set by horizontal PARALLAX (the spread
    %   of LOS directions, itself bounded by the same 8.7 deg cone) -- an independent
    %   weak-observability floor that a zero-position-column measurement cannot
    %   touch. Empirically, enabling two-way collapses the radial error by ~1-2
    %   orders and the clock by ~2-4 orders of magnitude, while the along/cross floor
    %   (a few metres) is unchanged. Curing that needs geometric diversity (non-GEO
    %   relative motion, or ISL / swarm baselines), NOT a better time-transfer link.
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

            mode      = revgnss.TwoWayTimeTransferBuilder.getStr_(cfg, ...
                {'measurements','twoWayTimeTransfer','mode'}, ...
                revgnss.ReciprocalTimeTransferModel.FirstOrderMode);
            if strcmp(mode,'fourTimestampClockDifference')
                % Plan Section 4.4: the direct four-timestamp physical mode, dispatched here rather
                % than through revgnss.ReciprocalTimeTransferModel (that class's own
                % PhysicalTimestampMode='fourTimestampPhysical' names a DIFFERENT, still-reserved
                % raw-tag scheme -- see revgnss.FourTimestampClockDifferenceObservable's header).
                [zAdd, hAdd, HAdd, RAdd, info] = revgnss.FourTimestampGroundSpaceTimeTransferBuilder.build( ...
                    cfg, errorChain, asset, towers, x, stateMap, nx, t_s);
                return
            end
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
            % rigorous alternative is a per-tower product-bias EKF state.
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
            [~, towerClkModelVec, towerClkSigmaVec, ~, t_prod_2w] = ...
                models.clocks.TowerClockCorrectionProvider.compute(cfg, errorChain, towers, visTowers(:), t_s);
            % Age of the broadcast correction, needed to split towerClkSigmaVec into its
            % piecewise-constant product part and its sawtooth oscillator-wander part below.
            age_2w = max(t_s - t_prod_2w, 0);

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
                truthReference = struct('position_m',r_twr_t, ...
                    'velocity_mps',zeros(3,1),'clockBias_m',b_tw_true);
                truthRemote = struct('position_m',r_sat_t, ...
                    'velocity_mps',v_sat_t,'clockBias_m',b_rx_true);
                modelReference = struct('position_m',r_twr_e, ...
                    'velocity_mps',zeros(3,1),'clockBias_m',b_tw_model);
                modelRemote = struct('position_m',r_sat_e, ...
                    'velocity_mps',v_sat_e,'clockBias_m',b_rx_est);
                truthResult = revgnss.ReciprocalTimeTransferModel.evaluate( ...
                    truthReference,truthRemote,mode,recipOn);
                modelResult = revgnss.ReciprocalTimeTransferModel.evaluate( ...
                    modelReference,modelRemote,mode,recipOn);

                % --- Measurement noise (identity-keyed truth draw) ---------------
                n = sigma_m * revgnss.TwoWayTimeTransferBuilder.draw_(errorChain, ti, epochIdx);

                zi = truthResult.value_m + n;
                hi = modelResult.value_m;

                Hi = zeros(1, nx);
                Hi(stateMap.b_rx_idx) = modelResult.remoteClockPartial;
                if towerCol > 0
                    Hi(towerCol) = modelResult.referenceClockPartial;
                end
                if recipOn
                    Hi(stateMap.r_idx) = Hi(stateMap.r_idx) + ...
                        modelResult.remotePositionPartial;
                    Hi(stateMap.v_idx) = Hi(stateMap.v_idx) + ...
                        modelResult.remoteVelocityPartial;
                end

                Ri = sigma_m^2;
                if addProductVar
                    % n_corr inflates ONLY the piecewise-constant product error, which is
                    % what the rationale above is about. Since 2026-08-10 towerClkSigmaVec
                    % also carries the oscillator's free-running WANDER, and that is a
                    % sawtooth -- zero at the product epoch, maximal just before the next --
                    % so it is not shared across the interval's rows and must not be
                    % inflated. Charging n_corr = 30 copies of it took the two-way row from
                    % 2.42 m to 13.25 m of sigma at age 34 s: a 24x de-weighting of the ONE
                    % observable that breaks the GEO radial-clock degeneracy.
                    sConst_    = models.clocks.TowerClockCorrectionProvider.productOnlySigma(cfg, age_2w);
                    wanderVar_ = max(sig_prod^2 - sConst_^2, 0);
                    Ri = Ri + nCorr * sConst_^2 + wanderVar_;
                end
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
                    'towerClockModel_m', b_tw_model, ...
                    'towerClockStateColumn', towerCol, ...
                    'prefit_m', zi - hi, 'sigma_m', sqrt(Ri), ...
                    'towerClockIsState', towerCol > 0, 'productSigma_m', sig_prod, ...
                    'reciprocity_m', truthResult.reciprocity_m, ...
                    'reciprocityModel_m', modelResult.reciprocity_m, ...
                    'modelMode',mode);
                if isempty(rowsMeta); rowsMeta = meta; else; rowsMeta(end+1) = meta; end %#ok<AGROW>

                obsRow = revgnss.ObservableRowDescriptor.create( ...
                    0, 'twoWayTimeTransfer', sprintf('link:twtt:t%03d:sat', ti), 'TWTT', ...
                    ti, 1, revgnss.TwoWayTimeTransferBuilder.stateCols_(stateMap, towerCol, recipOn), ...
                    'tower-spacecraft first-order reciprocal clock-difference observable', ...
                    revgnss.TwoWayTimeTransferBuilder.role_(useInEKF));
                obsRow = revgnss.ObservableRowDescriptor.withFlags(obsRow, useInEKF, false);
                info.observableRows(end+1) = obsRow;
            end

            info.rows        = rowsMeta;
            info.nRows       = numel(rowsMeta);
            info.nEkfRows    = double(useInEKF) * numel(rowsMeta);
            info.conservativeProductCorrelation = consProdCorr;
            info.productCorrelationN = nCorr;   % epochs/interval the product bias is shared over
            if ~isempty(zAdd); info.prefitRms_m = sqrt(mean((zAdd - hAdd).^2)); end
        end

        function [hPred, HPred, rows] = predictEkfRows(cfg, asset, towers, x, stateMap, info, t_s)
            % predictEkfRows  Recompute TWTT h from the post-update EKF state.
            %
            % Uses row metadata captured by build(), especially the tower-clock product
            % value used at measurement time. It does not redraw noise or rebuild z.
            if nargin < 7 || isempty(t_s); t_s = 0; end
            nx = numel(x);
            hPred = [];
            HPred = zeros(0, nx);
            rows = struct([]);
            if isempty(info) || ~isstruct(info) || ~isfield(info,'useInEKF') || ~info.useInEKF || ...
                    ~isfield(info,'rows') || isempty(info.rows)
                return
            end

            mode = revgnss.TwoWayTimeTransferBuilder.walk_(cfg, ...
                {'measurements','twoWayTimeTransfer','mode'}, ...
                revgnss.ReciprocalTimeTransferModel.FirstOrderMode);
            if strcmp(mode,'fourTimestampClockDifference')
                [hPred, HPred, rows] = revgnss.FourTimestampGroundSpaceTimeTransferBuilder.predictEkfRows( ...
                    cfg, asset, towers, x, stateMap, info, t_s);
                return
            end
            recipOn = revgnss.TwoWayTimeTransferBuilder.getBool_(cfg, ...
                {'measurements','twoWayTimeTransfer','includeReciprocityResidual'}, false);
            r_sat_e = x(stateMap.r_idx);
            v_sat_e = x(stateMap.v_idx);
            b_rx_e  = x(stateMap.b_rx_idx);

            for jj = 1:numel(info.rows)
                rowInfo = info.rows(jj);
                ti = rowInfo.towerIdx;
                towerCol = revgnss.TwoWayTimeTransferBuilder.rowTowerColumn_(rowInfo, stateMap, ti);
                if towerCol > 0
                    b_tw_model = x(towerCol);
                elseif isfield(rowInfo,'towerClockModel_m') && isfinite(rowInfo.towerClockModel_m)
                    b_tw_model = rowInfo.towerClockModel_m;
                else
                    b_tw_model = b_rx_e - rowInfo.clockDiffModel_m;
                end

                r_twr_e = models.measurements.MeasurementModelUtils. ...
                    towerPositionEcef(cfg,towers{ti},ti,'model');
                modelReference = struct('position_m',r_twr_e, ...
                    'velocity_mps',zeros(3,1),'clockBias_m',b_tw_model);
                modelRemote = struct('position_m',r_sat_e, ...
                    'velocity_mps',v_sat_e,'clockBias_m',b_rx_e);
                modelResult = revgnss.ReciprocalTimeTransferModel.evaluate( ...
                    modelReference,modelRemote,mode,recipOn);

                Hi = zeros(1, nx);
                Hi(stateMap.b_rx_idx) = modelResult.remoteClockPartial;
                if towerCol > 0
                    Hi(towerCol) = modelResult.referenceClockPartial;
                end
                if recipOn
                    Hi(stateMap.r_idx) = Hi(stateMap.r_idx) + ...
                        modelResult.remotePositionPartial;
                    Hi(stateMap.v_idx) = Hi(stateMap.v_idx) + ...
                        modelResult.remoteVelocityPartial;
                end

                hPred(end+1,1) = modelResult.value_m; %#ok<AGROW>
                HPred(end+1,:) = Hi; %#ok<AGROW>
                if isempty(rows); rows = rowInfo; else; rows(end+1) = rowInfo; end %#ok<AGROW>
            end
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
            mode = revgnss.TwoWayTimeTransferBuilder.getStr_(cfg, ...
                {'measurements','twoWayTimeTransfer','mode'}, ...
                revgnss.ReciprocalTimeTransferModel.FirstOrderMode);
            if strcmp(mode,'fourTimestampClockDifference')
                % Deliberately NOT routed through revgnss.ReciprocalTimeTransferModel.validateMode:
                % that class's own vocabulary is frozen to 'firstOrderReciprocal' and the reserved
                % (still-unimplemented) 'fourTimestampPhysical' string -- neither names this mode.
                % Combined-review m5: includeReciprocityResidual is a legacy-mode-only concept
                % (revgnss.ReciprocalTimeTransferModel.evaluate's reciprocity term) that
                % revgnss.FourTimestampGroundSpaceTimeTransferBuilder never reads at all -- refuse
                % a nonzero declaration rather than silently ignore it, mirroring the ISL
                % sanctioned tuple's own equivalent guard
                % (+revgnss/IndependentFleetCoordinator.m's reciprocityTermUnavailableForDistributedRow).
                if revgnss.TwoWayTimeTransferBuilder.getBool_( ...
                        cfg,{'measurements','twoWayTimeTransfer','includeReciprocityResidual'},false)
                    error('TwoWayTimeTransferBuilder:reciprocityTermUnavailableForFourTimestampMode', ...
                        ['measurements.twoWayTimeTransfer.includeReciprocityResidual=true is not ' ...
                        'supported under mode=fourTimestampClockDifference: it is a legacy-mode-' ...
                        'only concept that this mode''s physics never reads.']);
                end
                revgnss.FourTimestampGroundSpaceTimeTransferBuilder.validateConfig(cfg);
                return
            end
            revgnss.ReciprocalTimeTransferModel.validateMode(mode);
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
            if recipOn
                cols = [cols,stateMap.r_idx(:)',stateMap.v_idx(:)'];
            end
        end

        function towerCol = rowTowerColumn_(rowInfo, stateMap, ti)
            towerCol = 0;
            if isfield(rowInfo,'towerClockStateColumn') && isfinite(rowInfo.towerClockStateColumn)
                towerCol = rowInfo.towerClockStateColumn;
            elseif isfield(stateMap,'towerClockIdx') && ~isempty(stateMap.towerClockIdx) && ...
                    ti <= size(stateMap.towerClockIdx,1)
                towerCol = stateMap.towerClockIdx(ti,1);
            end
            if isempty(towerCol) || ~isfinite(towerCol) || towerCol < 1
                towerCol = 0;
            end
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

        function v = getStr_(cfg, path, def)
            v = revgnss.TwoWayTimeTransferBuilder.walk_(cfg, path, def);
            if ~(ischar(v) || (isstring(v) && isscalar(v)))
                v = def;
            end
            v = char(v);
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
