classdef TowerClockCorrectionProvider
    % TowerClockCorrectionProvider  Computes per-measurement tower clock corrections.
    %
    % Extracted from MeasurementModel.computeMeasurements.
    % All physics are preserved exactly — this is a pure structural refactor.
    %
    % Realistic synthetic tower clock correction mode 'truthHistoryProductNoisy':
    % broadcast-product-like clock correction using:
    %   1. Delayed/quantised product epoch: t_prod = floor((t-lat)/dT)*dT
    %   2. Truth clock state at t_prod from tower history
    %   3. Deterministic per-(tower,t_prod) product bias/drift noise (seeded cache)
    %   4. Linear prediction: b_model(t) = (b_true+b_noise) + (bdot_true+d_noise)*age
    %   5. Prediction sigma: sqrt(sigmaBias^2 + age^2*sigmaDrift^2 + 2*age*covBD)
    %   6. Sigma added to measurement R via towerClkSigma return value
    % Unlike 'noisyCorrection', the noise is NOT re-drawn every epoch — it is
    % fixed per product epoch, consistent with a real broadcast product.

    methods (Static)

        function [towerClkTruth, towerClkModel, towerClkSigma, corrNoise_m, t_prod, mode] = ...
                compute(cfg, errorChain, towers, twr_list, t_s)
            % compute  Build per-measurement tower clock correction vectors.
            %
            % Returns:
            %   towerClkTruth   [M×1] truth tower clock bias [m]
            %   towerClkModel   [M×1] correction applied (mode-dependent) [m]
            %   towerClkSigma   [M×1] correction sigma (added to R diagonal) [m]
            %   corrNoise_m     [M×1] noise realisation drawn for noisyCorrection mode
            %   t_prod          product epoch [s]
            %   mode            mode string (towerClockMode from cfg)
            M    = numel(twr_list);
            mode = models.clocks.TowerClockCorrectionProvider.towerClockMode(cfg);

            towerClkTruth = zeros(M,1);
            towerClkModel = zeros(M,1);
            towerClkSigma = zeros(M,1);

            noiseSigma = cfg.estimator.towerClockCorrectionSigma_m;
            if isfield(cfg,'towerClockCorrectionSigma_m')
                noiseSigma = cfg.towerClockCorrectionSigma_m;
            end
            if strcmp(mode,'noisyCorrection')
                % SIMULATION NOTE: noisyCorrection is a truth-based simulated external
                % correction product.  It is NOT a model of what a real receiver
                % produces; it adds zero-mean Gaussian noise to the true tower clock.
                % Use for Monte Carlo bias/sigma studies only.
                % truthHistoryProductNoisy is the more realistic product model.
                %
                % ONE draw per UNIQUE tower per epoch, not per (tower,antenna) row. A tower
                % has one clock, so its broadcast correction noise is one realisation --
                % CodeMeasurementBuilder's shared off-diagonal block (:~890-901) already
                % installs it across every row of that tower on exactly that assumption.
                % drawNormal(M,1) drew M independent values, one per ROW; that only agreed
                % with "one per tower" because every committed noisyCorrection fixture has
                % nReceivers=1, where M == the visible tower count and rows and towers
                % coincide 1:1. At nReceivers>1 it would silently charge an off-diagonal
                % correlation for rows whose noise was never actually shared. unique(twr_list)
                % is ascending and twr_list is built tower-major (ti outer loop in
                % MeasurementModel), so at nReceivers=1 this draws in the SAME order as the
                % old per-row call -- byte-identical on golden_smoke/golden_full.
                corrNoise_m = zeros(M,1);
                uniqTwrNC_ = unique(twr_list);
                for ktNC_ = 1:numel(uniqTwrNC_)
                    idxNC_ = find(twr_list == uniqTwrNC_(ktNC_));
                    corrNoise_m(idxNC_) = noiseSigma * errorChain.drawNormal(1, 1);
                end
            else
                corrNoise_m = zeros(M,1);
            end

            % TASK 6: Product epoch computed ONCE before measurement loop so
            % 'product' and 'productNoisy' modes can evaluate b_hat(t_s) =
            % b(t_prod) + bdot(t_prod) * (t_s - t_prod) per tower.
            % Diagnosis C: this used to seed local 300/0 defaults and let a
            % cfg.errors.towerClock.{updateInterval_s,latency_s} fallback override
            % them before clocks.tower.product.* took final precedence. That
            % fallback was dead code -- productConfig_'s OWN internal defaults are
            % 30 (>0) and 5 (>=0), so prodCfg always won regardless of what
            % cfg.errors.towerClock held or whether it existed at all. Removed;
            % cfg.clocks.tower.product is the sole owner of the product grid.
            [~, prodCfg] = models.clocks.TowerClockCorrectionProvider.productConfig_(cfg);
            updateInterval_s = prodCfg.updateInterval_s;
            latency_s        = prodCfg.latency_s;

            t_available = t_s - latency_s;
            if updateInterval_s > 0
                t_prod = floor(t_available / updateInterval_s) * updateInterval_s;
            else
                t_prod = t_available;
            end
            if t_prod < 0
                t_prod = 0;
            end

            for mi = 1:M
                ti  = twr_list(mi);
                b_t = towers{ti}.getClockBiasMeters();
                towerClkTruth(mi) = b_t;
                switch mode
                    case 'none'
                        % No correction is applied, so the residual IS the raw tower clock
                        % bias. For a stochastic oscillator that is a random walk: no
                        % stationary variance, so no finite R covers it, and charging zero
                        % makes the filter arbitrarily overconfident as the arc lengthens.
                        % Legal only against a deterministic (identically zero) clock.
                        % Opt-out for DIAGNOSTIC callers that want to observe the uncorrected
                        % bias in the innovation without running a filter on it (e.g.
                        % tests/test_tower_clock_correction_product T5). It is an explicit
                        % acknowledgement that R is knowingly wrong, never a default.
                        allowUncorrected_ = false;
                        try
                            allowUncorrected_ = logical(cfg.towerClock.allowUncorrectedStochasticClock);
                        catch
                        end
                        if ~towers{ti}.clock.deterministic && ~allowUncorrected_
                            error('TowerClockCorrectionProvider:uncorrectedStochasticClock', ...
                                ['towerClockMode=''none'' applies no tower clock correction, ' ...
                                 'but tower %d carries a STOCHASTIC %s clock. The raw clock ' ...
                                 'bias then enters the residual unbounded and uncharged, so ' ...
                                 'no finite R is correct. Use a correction mode, make the ' ...
                                 'tower clock silent (cfg.clock.tower.deterministic = true, ' ...
                                 'or clockType ''ZERO''), or set ' ...
                                 'cfg.towerClock.allowUncorrectedStochasticClock = true if ' ...
                                 'you are deliberately inspecting the uncorrected residual.'], ...
                                ti, towers{ti}.clock.clockType);
                        end
                        towerClkModel(mi) = 0;
                    case 'perfectCorrection'
                        towerClkModel(mi) = b_t;
                    case 'noisyCorrection'
                        towerClkModel(mi) = b_t + corrNoise_m(mi);
                        towerClkSigma(mi) = noiseSigma;
                    case 'truthProduct'
                        [b_p, bd_p] = models.clocks.TowerClockCorrectionProvider.clockAtProductEpoch( ...
                            towers{ti}, t_prod);
                        ageTP = t_s - t_prod;
                        towerClkModel(mi) = b_p + bd_p * ageTP;
                        % This mode has NO product noise of its own -- the product is exact
                        % at t_prod -- so the oscillator's wander over the age is the ENTIRE
                        % error and R must equal it. It charged zero until 2026-08-10.
                        towerClkSigma(mi) = sqrt(models.clocks.TowerClockCorrectionProvider. ...
                            extrapolationWanderVar_(cfg, towers{ti}.clock, ageTP));
                    case 'truthHistoryProductNoisy'
                        % Realistic product correction.
                        % 1. Read truth clock at product epoch from tower history.
                        [b_p, bd_p] = models.clocks.TowerClockCorrectionProvider.clockAtProductEpoch( ...
                            towers{ti}, t_prod);
                        % 2. Deterministic per-(tower,t_prod) product noise (seeded cache).
                        [b_noise, d_noise] = models.clocks.TowerClockCorrectionProvider.productNoise_( ...
                            ti, t_prod, prodCfg.sigmaBias_m, prodCfg.sigmaDrift_mps);
                        % 3. Linear prediction to measurement time.
                        age = t_s - t_prod;
                        towerClkModel(mi) = (b_p + b_noise) + (bd_p + d_noise) * age;
                        % 4. Prediction uncertainty sigma (added to R by caller).
                        % The first three terms are the PRODUCT's own error. The fourth is
                        % the oscillator's free-running wander between t_prod and t_s, which
                        % the product cannot know about and which was missing entirely: with
                        % stochastic tower clocks on jowTable2p1 it is 2.5 m against a 0.106 m
                        % product sigma, i.e. R was optimistic by ~24x. Zero for a
                        % deterministic tower clock, so this is a no-op on those fixtures.
                        var_corr = prodCfg.sigmaBias_m^2 + ...
                                   age^2 * prodCfg.sigmaDrift_mps^2 + ...
                                   2 * age * prodCfg.covBiasDrift + ...
                                   models.clocks.TowerClockCorrectionProvider. ...
                                       extrapolationWanderVar_(cfg, towers{ti}.clock, age);
                        towerClkSigma(mi) = sqrt(max(var_corr, 0));
                    case 'product'
                        hasProd = isfield(cfg,'towerClock') && ...
                                  isfield(cfg.towerClock,'products') && ...
                                  ti <= numel(cfg.towerClock.products);
                        if ~hasProd
                            nProd = 0;
                            if isfield(cfg,'towerClock') && isfield(cfg.towerClock,'products')
                                nProd = numel(cfg.towerClock.products);
                            end
                            error('MeasurementModel:productStructMissing', ...
                                ['correctionMode=''product'' requires cfg.towerClock.products(%d) ' ...
                                 'to be set. Found only %d product struct(s). ' ...
                                 'Use correctionMode=''truthHistoryProduct'' for history-based mode.'], ...
                                ti, nProd);
                        end
                        [b_hat, sig_p] = models.clocks.TowerClockCorrectionProvider.evalProductStruct( ...
                            cfg, ti, t_s);
                        towerClkModel(mi) = b_hat;
                        % 'product' assigned NO sigma at all before 2026-08-10 -- the mode
                        % ran with R = 0 on a correction that is wrong by both the product's
                        % own error and the oscillator's wander since the product epoch.
                        towerClkSigma(mi) = sqrt(sig_p^2 + ...
                            models.clocks.TowerClockCorrectionProvider.explicitProductWanderVar_( ...
                                cfg, ti, towers{ti}.clock, t_s));
                    case 'productNoisy'
                        hasProd = isfield(cfg,'towerClock') && ...
                                  isfield(cfg.towerClock,'products') && ...
                                  ti <= numel(cfg.towerClock.products);
                        if ~hasProd
                            nProd = 0;
                            if isfield(cfg,'towerClock') && isfield(cfg.towerClock,'products')
                                nProd = numel(cfg.towerClock.products);
                            end
                            error('MeasurementModel:productStructMissing', ...
                                ['correctionMode=''productNoisy'' requires cfg.towerClock.products(%d) ' ...
                                 'to be set. Found only %d product struct(s). ' ...
                                 'Use correctionMode=''truthHistoryProductNoisy'' for history-based mode.'], ...
                                ti, nProd);
                        end
                        [b_hat, sig_corr] = models.clocks.TowerClockCorrectionProvider.evalProductStruct( ...
                            cfg, ti, t_s);
                        towerClkModel(mi) = b_hat;
                        % The explicit product struct describes the PRODUCT's uncertainty at
                        % its own epoch. It cannot know what the oscillator did afterwards,
                        % so the wander over the product age is charged on top of it.
                        towerClkSigma(mi) = sqrt(sig_corr^2 + ...
                            models.clocks.TowerClockCorrectionProvider.explicitProductWanderVar_( ...
                                cfg, ti, towers{ti}.clock, t_s));
                    otherwise
                        towerClkModel(mi) = 0;
                end
            end
            % Diagnosis A #7: cfg.clocks.tower.product.addToR (default true, prodCfg
            % already resolved at :82) had NO reader anywhere -- a live-looking R switch
            % that never touched R. Wired here as the R-ONLY master: it zeros the sigma
            % this function RETURNS, never the correction VALUE (towerClkModel above) or
            % the product epoch/age (t_prod, resolved unconditionally above and still
            % returned as-is) -- zeroing those would INFLATE R exactly as the
            % productClock.enable gate once did (age growing from the true 5..34 s to
            % the whole elapsed arc). config/ladder/test/test001_idealFlat.json and
            % test002 set addToR=false and are the two rungs whose whole purpose is an R
            % with nothing in it; they were silently NOT getting one.
            if ~prodCfg.addToR
                towerClkSigma(:) = 0;
            end
        end

        function mode = towerClockMode(cfg)
            % towerClockMode  Return the configured tower clock correction mode.
            mode = 'none';
            if isfield(cfg,'estimator') && isfield(cfg.estimator,'towerClockMode')
                mode = cfg.estimator.towerClockMode;
            elseif isfield(cfg,'towerClockMode')
                mode = cfg.towerClockMode;
            end
        end

        function [b_m, bdot_mps] = clockAtProductEpoch(tower, t_prod_s)
            % clockAtProductEpoch  Tower clock bias and drift at the product epoch.
            %
            % Reads from tower history (GroundTower initialises history at t=0
            % so t_prod=0 always has a valid entry).
            %
            % Fallback: when history is empty or predates t_prod, the current
            % tower state is returned with zero effective prediction age.  This
            % is equivalent to the product epoch being "now" — safe because
            % tower clocks initialise at (0,0) and the prediction error from a
            % wrong age anchor would be larger than this approximation.
            b_m      = 0;
            bdot_mps = 0;
            hist = tower.history;
            if isempty(hist.time_s) || isempty(hist.clockBias_m)
                % History not yet populated (edge case; GroundTower init at t=0
                % prevents this in normal operation).
                b_m      = tower.getClockBiasMeters();
                bdot_mps = tower.getClockDriftMetersPerSecond();
                return;
            end
            idx = find(hist.time_s <= t_prod_s + 1e-9, 1, 'last');
            if isempty(idx)
                % All recorded history is AFTER t_prod (startup before first step).
                % Use current state rather than projecting from a later anchor —
                % projecting forward from the earliest entry would apply an extra
                % age = (t_earliest - t_prod) that overcorrects the prediction.
                b_m      = tower.getClockBiasMeters();
                bdot_mps = tower.getClockDriftMetersPerSecond();
                return;
            end
            b_m      = hist.clockBias_m(idx);
            bdot_mps = hist.clockDrift_mps(idx);
        end

        function [b_hat, sigma_corr] = evalProductStruct(cfg, ti, t_eval_s)
            % evalProductStruct  Evaluate explicit per-tower product struct.
            %
            % Reads cfg.towerClock.products(ti) and returns the linearly-predicted
            % clock bias at t_eval_s together with the product prediction uncertainty.
            %
            %   b_hat = bias_m + drift_mps * dt         [m]
            %   sigma_corr^2 = sigmaBias^2 + dt^2*sigmaDrift^2 + 2*dt*covBiasDrift
            %
            % where dt = t_eval_s - epoch_s.
            % If validity_s is set and |dt| > validity_s, applies productValidityPolicy.
            b_hat      = 0;
            sigma_corr = 0;

            if ~isfield(cfg,'towerClock') || ~isfield(cfg.towerClock,'products')
                error('MeasurementModel:productStructMissing', ...
                    ['evalProductStruct: cfg.towerClock.products is required for explicit ' ...
                     'product/productNoisy modes but is missing. ' ...
                     'Provide a products struct array or use truthHistoryProduct instead.']);
            end
            products = cfg.towerClock.products;
            if ti > numel(products)
                error('MeasurementModel:productStructMissing', ...
                    ['evalProductStruct: tower index %d exceeds products array length %d. ' ...
                     'Ensure cfg.towerClock.products has one entry per tower.'], ...
                    ti, numel(products));
            end
            prod = products(ti);

            epoch_s   = 0;  if isfield(prod,'epoch_s');   epoch_s   = prod.epoch_s;   end
            bias_m    = 0;  if isfield(prod,'bias_m');    bias_m    = prod.bias_m;    end
            drift_mps = 0;  if isfield(prod,'drift_mps'); drift_mps = prod.drift_mps; end

            dt = t_eval_s - epoch_s;

            % Validity check
            if isfield(prod,'validity_s') && prod.validity_s > 0 && abs(dt) > prod.validity_s
                policy = 'warn';
                if isfield(cfg.towerClock,'productValidityPolicy')
                    policy = cfg.towerClock.productValidityPolicy;
                end
                msg = sprintf(['Tower %d product validity exceeded: |dt|=%.1f s > %.1f s. ' ...
                               'Prediction accuracy may be degraded.'], ti, abs(dt), prod.validity_s);
                if strcmp(policy,'error')
                    error('MeasurementModel:productValidityExceeded', '%s', msg);
                else
                    warning('MeasurementModel:productValidityExceeded', '%s', msg);
                end
            end

            b_hat = bias_m + drift_mps * dt;

            % R contribution: sigma_corr^2 = sigmaBias^2 + dt^2*sigmaDrift^2 + 2*dt*cov
            sBias  = 0; if isfield(prod,'sigmaBias_m');    sBias  = prod.sigmaBias_m;    end
            sDrift = 0; if isfield(prod,'sigmaDrift_mps'); sDrift = prod.sigmaDrift_mps; end
            cov    = 0; if isfield(prod,'covBiasDrift');   cov    = prod.covBiasDrift;   end
            var_corr = sBias^2 + dt^2 * sDrift^2 + 2*dt*cov;
            sigma_corr = sqrt(max(var_corr, 0));
        end

        function sig_m = productOnlySigma(cfg, age_s)
            % productOnlySigma  The PIECEWISE-CONSTANT part of the tower-clock correction
            % sigma [m]: the broadcast product's own error, WITHOUT the oscillator's
            % free-running wander.
            %
            % Exists so consumers can treat the two parts differently, because they have
            % opposite time structure and a treatment correct for one is wrong for the
            % other:
            %   product error   piecewise CONSTANT across an update interval -- N rows in
            %                   one interval share it, so a sequential filter that treats
            %                   them as independent averages it down by sqrt(N)
            %   oscillator wander  a SAWTOOTH -- zero at the product epoch, maximal just
            %                   before the next one, then reset. It does not survive
            %                   averaging in the same way and must not be inflated as if it
            %                   did.
            % revgnss.TwoWayTimeTransferBuilder inflates the first by n_corr = interval/dt;
            % applying that same factor to the wander over-charged the two-way rows by up to
            % 24x in sigma (MEASURED 13.25 m against a true 2.42 m at age 34 s), which
            % de-weighted the one observable that breaks the GEO radial-clock degeneracy.
            [~, pc] = models.clocks.TowerClockCorrectionProvider.productConfig_(cfg);
            a = max(age_s, 0);
            var_m2 = pc.sigmaBias_m^2 + a^2 * pc.sigmaDrift_mps^2 + 2 * a * pc.covBiasDrift;
            sig_m  = sqrt(max(var_m2, 0));
        end

        function var_m2 = carrierBiasWanderVar(cfg, clk, age_s)
            % carrierBiasWanderVar  Oscillator wander variance [m^2] the carrier carries,
            % at the row's OWN correction age -- identical to what the code path charges.
            %
            % The carrier's float ambiguity is a CONSTANT fitted across the arc, so what
            % survives into the residual is the correction error relative to that constant
            % -- the whole sawtooth the correction traces between product updates, not its
            % value at one instant. Max age bounds that sawtooth.
            %
            % This REPLACES an "excess over the instantaneous age" variant, because the
            % carrier no longer derives its bias sigma by subtracting the drift term (see
            % CarrierMeasurementBuilder): it now owns the whole wander outright, once.
            % THE ROW'S OWN INSTANTANEOUS AGE -- the same quantity the code path charges.
            %
            % This deliberately does NOT use a max-age or mean-over-sawtooth sizing. Both
            % were tried; both are wrong once the code<->carrier cross-covariance exists.
            % A code row and a carrier row of one tower at one epoch see the IDENTICAL
            % clock error, so R must charge them the identical sigma: only then is the
            % cross term s_code*s_car an identity and the code-minus-carrier difference
            % direction correctly given ZERO tower-clock variance. Any disagreement d
            % leaves residual variance d^2 in exactly the channel the filter uses to cancel
            % the clock -- Cauchy-Schwarz keeps R positive semi-definite, but the filter
            % then over-trusts that difference. MEASURED: with the mean-over-sawtooth
            % sizing and the cross term present, aggregate NIS went 1.019 -> 1.715.
            %
            % The earlier mean-over-sawtooth was calibrated to bring NIS to 0.908 against an
            % R whose cross term was short by ~1e3x. That calibration fitted the wrong
            % model and is retired rather than re-tuned.
            var_m2 = 0;
            if isempty(clk) || clk.deterministic || nargin < 3 || age_s <= 0; return; end
            % cfg now genuinely used: Diagnosis A #8's includeOscillatorWander gate is
            % applied INSIDE extrapolationWanderVar_, so the carrier and code paths share
            % the identical gate and can never disagree on whether the wander is charged.
            var_m2 = models.clocks.TowerClockCorrectionProvider.extrapolationWanderVar_(cfg, clk, age_s);
        end

        function [bdot_truth, bdot_model, drift_sigma, t_prod_out, meta] = ...
                computeDrift(cfg, towers, twr_list, t_s)
            % computeDrift  Tower clock drift for Doppler model.
            %
            % Returns per-measurement drift truth, product model, sigma, and product epoch.
            % Compatible with all tower clock modes. Uses the same persistent product-noise
            % cache as compute(), so noise is deterministic and consistent across callers.
            %
            % Outputs:
            %   bdot_truth  [M×1] tower truth drift [m/s]
            %   bdot_model  [M×1] product-model drift (mode-dependent) [m/s]
            %   drift_sigma [M×1] product drift sigma [m/s]
            %   t_prod_out  [M×1] product epoch per measurement [s]
            %   meta        struct (mode string)

            M    = numel(twr_list);
            mode = models.clocks.TowerClockCorrectionProvider.towerClockMode(cfg);
            [~, pc] = models.clocks.TowerClockCorrectionProvider.productConfig_(cfg);

            bdot_truth  = zeros(M,1);
            bdot_model  = zeros(M,1);
            drift_sigma = zeros(M,1);
            t_prod_out  = zeros(M,1);

            % Product epoch scalar — same logic as compute(). Diagnosis C: the
            % cfg.errors.towerClock fallback this used to consult here (mirroring
            % compute()'s, now removed at :74-84) was equally dead -- pc.
            % updateInterval_s/latency_s default to 30/5 inside productConfig_
            % itself, never <=0/<0, so the fallback branch could not fire.
            updateInterval_s = pc.updateInterval_s;
            latency_s        = pc.latency_s;
            t_avail = t_s - latency_s;
            if updateInterval_s > 0
                t_prod_scalar = floor(t_avail / updateInterval_s) * updateInterval_s;
            else
                t_prod_scalar = t_avail;
            end
            if t_prod_scalar < 0; t_prod_scalar = 0; end

            explicitProductDriftUsed  = false;
            truthHistoryProductDriftUsed = false;
            driftAnchorStatus         = 'notApplicable';
            driftProductMode_out      = mode;
            driftSigmaSource_out      = 'zero';

            for mi = 1:M
                ti = twr_list(mi);
                % Default: use current truth drift (fallback)
                bdot_truth_current = towers{ti}.getClockDriftMetersPerSecond();
                bdot_truth(mi) = bdot_truth_current;
                t_prod_out(mi) = t_prod_scalar;

                switch mode
                    case 'perfectCorrection'
                        % ORACLE mode. Its defining property is a ZERO residual, and the bias
                        % path delivers that literally: compute() sets towerClkModel = the
                        % truth bias at t_s, and CodeMeasurementBuilder back-propagates it
                        % with the TRUTH drift. The rate-domain analogue is the same: truth
                        % == model, both at t_s, sigma 0.
                        %
                        % This USED TO anchor the MODEL at the product epoch (bd_p) while
                        % DopplerMeasurementBuilder builds z from the drift at t_s (:174/:192)
                        % and h from this value (:211) -- so the oscillator's full frequency
                        % excursion over the correction age survived in the residual while R
                        % charged zero for it. MEASURED: aggregate ratio f_dop=0.362..0.370
                        % (predicted 1/3 for a 5-tower single-signal stack) reproduced across
                        % a 500x span in h_-2 on four of nine crystals -- exactly the RWFM/FFM
                        % frequency-excursion signature and nothing else. Same fix as the
                        % 'noisyCorrection' branch below, for the same reason.
                        bdot_truth(mi)  = towers{ti}.getClockDriftMetersPerSecond();
                        bdot_model(mi)  = bdot_truth(mi);
                        drift_sigma(mi) = 0;
                        driftAnchorStatus = 'measurementEpochTruth';
                        driftSigmaSource_out = 'zero';

                    case 'truthHistoryProductNoisy'
                        % TRUTH is the drift at t_s; the MODEL is extrapolated from t_prod.
                        %
                        % This REVERSES the Stage-84 change (see revgnss.StageHistory), which
                        % moved bdot_truth to the product epoch and justified it as "consistent
                        % with bias path in compute()". That misreads the bias path: there,
                        % truth is towers{ti}.getClockBiasMeters() at t_s (line 84) and only the
                        % MODEL is anchored at t_prod. Anchoring both at t_prod made the tower
                        % clock contribution cancel identically out of the Doppler residual.
                        %
                        % Physically a range-rate observable at t_s depends on the tower
                        % oscillator's fractional frequency AT t_s; a 30 s old frequency has no
                        % mechanism by which to enter it. The product epoch is a property of the
                        % CORRECTION, not of the measurement.
                        %
                        % Stage 84 could not have caught this: with deterministic tower clocks
                        % bd_p and the drift at t_s are both identically zero, so every gate it
                        % ran passed on a difference that could not appear.
                        [~, bd_p] = models.clocks.TowerClockCorrectionProvider.clockAtProductEpoch( ...
                            towers{ti}, t_prod_scalar);
                        [~, d_noise] = models.clocks.TowerClockCorrectionProvider.productNoise_( ...
                            ti, t_prod_scalar, pc.sigmaBias_m, pc.sigmaDrift_mps);
                        bdot_truth(mi)  = towers{ti}.getClockDriftMetersPerSecond();  % at t_s
                        bdot_model(mi)  = bd_p + d_noise;
                        % R must now cover the FREQUENCY excursion over the correction age, the
                        % rate-domain twin of extrapolationWanderVar_ on the bias path. Allan
                        % deviation IS the rms fractional-frequency change over tau, so the
                        % drift error over the age is c*sigma_y(age) [m/s]. Zero for a
                        % deterministic tower clock.
                        age_d = t_s - t_prod_scalar;
                        drift_sigma(mi) = sqrt(pc.sigmaDrift_mps^2 + ...
                            models.clocks.TowerClockCorrectionProvider. ...
                                frequencyWanderVar_(cfg, towers{ti}.clock, age_d));
                        truthHistoryProductDriftUsed = true;
                        driftAnchorStatus = 'measurementEpochTruth';
                        driftSigmaSource_out = 'productConfigPlusOscillatorWander';

                    case 'truthProduct'
                        % Pure history-based product drift, no product noise.
                        % Truth is the drift at t_s, NOT at the product epoch -- same fix as
                        % the truthHistoryProductNoisy branch above. Anchoring both sides at
                        % t_prod made the tower oscillator cancel identically out of the
                        % range-rate residual, which no gate could see while the clocks were
                        % deterministic (both values then being exactly zero).
                        [~, bd_p] = models.clocks.TowerClockCorrectionProvider.clockAtProductEpoch( ...
                            towers{ti}, t_prod_scalar);
                        bdot_truth(mi)  = towers{ti}.getClockDriftMetersPerSecond();  % at t_s
                        bdot_model(mi)  = bd_p;
                        % No product noise in this mode, so the frequency excursion over the
                        % age is the entire drift error.
                        age_tp = t_s - t_prod_scalar;
                        drift_sigma(mi) = sqrt(models.clocks.TowerClockCorrectionProvider. ...
                            frequencyWanderVar_(cfg, towers{ti}.clock, age_tp));
                        truthHistoryProductDriftUsed = true;
                        driftAnchorStatus = 'measurementEpochTruth';
                        driftSigmaSource_out = 'oscillatorWander';

                    case {'product', 'productNoisy'}
                        % Explicit product struct required; no truth-history fallback.
                        hasProd = isfield(cfg,'towerClock') && ...
                                  isfield(cfg.towerClock,'products') && ...
                                  ti <= numel(cfg.towerClock.products);
                        if hasProd
                            prod = cfg.towerClock.products(ti);
                            % bdot_truth was NEVER assigned here, so it stayed 0 while the
                            % model carried the product's drift -- the tower oscillator was
                            % invisible to the range-rate residual. Invisible in the wrong
                            % direction too: with a stochastic clock the truth drift at t_s
                            % is real and nonzero.
                            bdot_truth(mi) = towers{ti}.getClockDriftMetersPerSecond();
                            if isfield(prod,'drift_mps')
                                bdot_model(mi) = prod.drift_mps;
                            end
                            epoch_p = 0;
                            if isfield(prod,'epoch_s'); epoch_p = prod.epoch_s; end
                            sig_d = 0;
                            if strcmp(mode,'productNoisy') && isfield(prod,'sigmaDrift_mps')
                                sig_d = prod.sigmaDrift_mps;
                            elseif strcmp(mode,'productNoisy')
                                sig_d = pc.sigmaDrift_mps;
                            end
                            % Frequency excursion since the product epoch, charged for BOTH
                            % explicit-product modes: 'product' has no sigma of its own, so
                            % this is the only thing standing between it and R = 0.
                            drift_sigma(mi) = sqrt(sig_d^2 + ...
                                models.clocks.TowerClockCorrectionProvider.frequencyWanderVar_( ...
                                    cfg, towers{ti}.clock, max(t_s - epoch_p, 0)));
                            if isfield(prod,'epoch_s')
                                t_prod_out(mi) = prod.epoch_s;
                            end
                            explicitProductDriftUsed = true;
                            driftAnchorStatus = 'measurementEpochTruth';
                            driftSigmaSource_out = 'explicitProductPlusOscillatorWander';
                        else
                            % Missing explicit product — use zero drift, report clearly.
                            bdot_model(mi)  = 0;
                            drift_sigma(mi) = 0;
                            driftAnchorStatus = 'missingExplicitProductFallbackZero';
                            driftSigmaSource_out = 'zero';
                        end

                    case 'noisyCorrection'
                        % noisyCorrection is a bias-only toy correction: in the bias domain
                        % it KNOWS the truth and adds noise, so the rate-domain analogue is
                        % truth == model and a zero residual. Both are anchored at t_s and
                        % reported honestly; bdot_truth used to be left at 0, which made the
                        % REPORTED truth wrong even though the residual was right.
                        bdot_truth(mi)  = towers{ti}.getClockDriftMetersPerSecond();
                        bdot_model(mi)  = bdot_truth(mi);
                        drift_sigma(mi) = 0;
                        driftAnchorStatus = 'measurementEpochTruth';
                        driftSigmaSource_out = 'zero';

                    otherwise  % 'none'
                        bdot_model(mi)  = 0;
                        drift_sigma(mi) = 0;
                        driftAnchorStatus = 'notApplicableNoCorrection';
                        driftSigmaSource_out = 'zero';
                end
            end

            % Diagnosis A #7: same R-only master as compute() above (pc.addToR, pc
            % resolved at :419). Zeros ONLY the sigma this function returns; bdot_truth,
            % bdot_model and t_prod_out (the correction VALUES and epoch/age) stay
            % unconditional -- zeroing those would inflate R instead of emptying it.
            if ~pc.addToR
                drift_sigma(:) = 0;
            end

            meta.mode                        = mode;
            meta.driftProductMode            = driftProductMode_out;
            meta.driftAnchorStatus           = driftAnchorStatus;
            meta.driftSigmaSource            = driftSigmaSource_out;
            meta.explicitProductDriftUsed    = explicitProductDriftUsed;
            meta.truthHistoryProductDriftUsed = truthHistoryProductDriftUsed;
        end

        function pc = productSigmaConfig(cfg)
            % productSigmaConfig  Public accessor for the product bias/drift/
            % cross-covariance sigma triple (sigmaBias_m, sigmaDrift_mps,
            % covBiasDrift), so every consumer that builds R from these three
            % numbers resolves cfg.clocks.tower.product.* through the SAME
            % defaults and the SAME isfield fallback as this class's own
            % compute()/computeDrift(). Diagnosis C: before this existed,
            % models.clocks.ProductClockCovarianceBuilder carried its own
            % literal fallback defaults (0.10 m / 1e-3 m/s) that disagreed with
            % productConfig_'s (0.05 m / 0.001 m/s) here, which disagreed with
            % masterConfig's shipped value (0.01 m / 0.0002 m/s) -- three homes
            % for one physical quantity, reachable only when a cfg omits
            % cfg.clocks.tower.product entirely (masterConfig always declares
            % it, so the isfield override wins on every shipped path and this
            % does not move the default). See ProductClockCovarianceBuilder.
            % productCfg_, the sole remaining caller.
            [~, pc] = models.clocks.TowerClockCorrectionProvider.productConfig_(cfg);
        end

    end  % Static methods

    methods (Static, Access = private)

        function [hasProductCfg, pc] = productConfig_(cfg)
            % productConfig_  Parse cfg.clocks.tower.product.* for truthHistoryProductNoisy.
            % Defaults match a moderate-quality synthetic broadcast product.
            pc.sigmaBias_m          = 0.05;   % ~0.15 ns — high-quality ground tracking network
            pc.sigmaDrift_mps       = 0.001;  % ~0.003 ppb/s
            pc.covBiasDrift         = 0;
            pc.updateInterval_s     = 30;
            pc.latency_s            = 5;
            pc.validity_s           = 120;
            pc.addToR               = true;
            % sharedErrorCorrelation is currently inert: read here and nowhere else consumed
            % except a SimulationToggleManifest report row. See config/masterConfig.m's own
            % comment at this field's declaration (plan Section 3.3) for what actually gates
            % cross-fleet sharing today (productNoise_'s correction residual is a DETERMINISTIC
            % function of (towerIndex,productEpoch), identical for every real consumer of that
            % pair -- not merely cached -- whenever towerClockMode~='perfectCorrection') and what
            % currently prevents it in an untreated multi-asset independent fleet with an enabled
            % correlation network
            % (revgnss.IndependentFleetCoordinator:towerClockProductReachableButRejected).
            pc.sharedErrorCorrelation = true;
            hasProductCfg = false;
            try
                tp = cfg.clocks.tower.product;
                hasProductCfg = true;
                if isfield(tp,'sigmaBias_m');          pc.sigmaBias_m          = tp.sigmaBias_m;          end
                if isfield(tp,'sigmaDrift_mps');       pc.sigmaDrift_mps       = tp.sigmaDrift_mps;       end
                if isfield(tp,'covBiasDrift');         pc.covBiasDrift         = tp.covBiasDrift;         end
                if isfield(tp,'updateInterval_s');     pc.updateInterval_s     = tp.updateInterval_s;     end
                if isfield(tp,'latency_s');            pc.latency_s            = tp.latency_s;            end
                if isfield(tp,'validity_s');           pc.validity_s           = tp.validity_s;           end
                if isfield(tp,'addToR');               pc.addToR               = tp.addToR;               end
                if isfield(tp,'sharedErrorCorrelation'); pc.sharedErrorCorrelation = tp.sharedErrorCorrelation; end
            catch
            end
        end

        function var_m2 = explicitProductWanderVar_(cfg, ti, clk, t_s)
            % explicitProductWanderVar_  Wander variance [m^2] for the EXPLICIT-product
            % modes, whose age is measured from the product struct's own epoch_s rather
            % than from the quantised broadcast grid the history modes use.
            %
            % D12: an empty catch here defaulted epoch_p to 0 on ANY failure, making
            % age = t_s - 0 the WHOLE ELAPSED ARC (up to 3600 s) instead of the true
            % product age -- the identical pathology measured on the carrier path
            % (age 10 s -> 40 s, sigma 0.386 m -> 3.083 m), an R that gets knowingly
            % WRONG rather than empty. Both callers ('product'/'productNoisy' cases in
            % compute()) already guard hasProd before reaching here, so the only way in
            % is a product struct missing its epoch_s field -- fail loud, there is no
            % honest fallback for an unknown product epoch.
            if ~(isfield(cfg,'towerClock') && isfield(cfg.towerClock,'products') && ...
                    ti <= numel(cfg.towerClock.products) && ...
                    isfield(cfg.towerClock.products(ti), 'epoch_s'))
                error('TowerClockCorrectionProvider:productEpochUnavailable', ...
                    ['cfg.towerClock.products(%d).epoch_s is unavailable; epoch_p would ' ...
                     'default to 0 and the wander age would become the whole elapsed arc, ' ...
                     'inflating R. Refusing to build a knowingly wrong R.'], ti);
            end
            epoch_p = cfg.towerClock.products(ti).epoch_s;
            var_m2 = models.clocks.TowerClockCorrectionProvider.extrapolationWanderVar_( ...
                cfg, clk, max(t_s - epoch_p, 0));
        end

        function var_m2 = extrapolationWanderVar_(cfg, clk, age_s)
            % extrapolationWanderVar_  Variance [m^2] of the tower oscillator's OWN wander
            % over the age of the broadcast correction.
            %
            % The product pins the clock at t_prod. Between t_prod and the measurement the
            % oscillator runs free, and that excursion is invisible to the product: it is
            % not in sigmaBias_m (the product's estimate error at its own epoch) nor in
            % age^2*sigmaDrift_mps^2 (the uncertainty of the product's DRIFT term). Sizing
            % it from the oscillator's own Allan deviation at tau = age is the product-age
            % growth a real PPP user applies to a broadcast clock correction:
            %     x(tau) ~ sigma_y(tau) * tau  [s]   ->   c * sigma_y(age) * age  [m]
            %
            % Uses the THEORETICAL ADEV (from the h-coefficients), not the empirical one:
            % the empirical history is only as long as the run so far, and R must be right
            % from epoch 1.
            %
            % A deterministic tower clock does not wander at all, so the term is exactly
            % zero and every deterministic-tower fixture is byte-identical to before -- this
            % gate is ORTHOGONAL to that (Diagnosis A #8): includeOscillatorWander controls
            % whether the wander is CHARGED TO R for a genuinely stochastic clock; it must
            % never be inferred from, or substitute for, cfg.clock.tower.deterministic.
            var_m2 = 0;
            if isempty(clk) || age_s <= 0 || clk.deterministic
                return
            end
            includeWander_ = true;
            try; includeWander_ = logical(cfg.covariance.productClock.includeOscillatorWander); catch; end
            if ~includeWander_
                return
            end
            [~, adev] = clk.theoreticalAllanDeviation(age_s);
            var_m2 = (revgnss.Constants.SPEED_OF_LIGHT_MPS * adev * age_s)^2;
        end

        function var_m2s2 = frequencyWanderVar_(cfg, clk, age_s)
            % frequencyWanderVar_  Variance [(m/s)^2] of the tower oscillator's FREQUENCY
            % excursion between the product epoch and the measurement.
            %
            % REPLACES a first attempt that used (c*sigma_y(age))^2. That was wrong twice,
            % in opposite directions, and both errors are measurable against the truth
            % generator (see T6 of tests/test_tower_clock_product_age_wander_in_R.m):
            %
            %  1. Allan variance is defined on adjacent tau-AVERAGES. The drift residual is
            %     a difference of INSTANTANEOUS frequencies, and for random-walk FM those
            %     differ by exactly 3x in variance:
            %         Var(y(t+tau) - y(t)) = 2*pi^2*h_-2*tau        (this term)
            %         Asigma_y^2(tau)      = (2*pi^2/3)*h_-2*tau    (Winkel eq. 2.156)
            %     MEASURED sqrt-ratio for the crystals: OCXO2 1.81/1.75, TCXO 1.83/1.78,
            %     QUARTZ 1.72/1.81 -- all sqrt(3) = 1.732. R was optimistic by 3x in
            %     variance on exactly the oscillators the ground segment uses.
            %
            %  2. The Allan formula's h0/(2*tau) white-FM term does not belong here AT ALL.
            %     ClockModel.step applies h0 as a PHASE jump (n_bias_wfm -> bias_s), never
            %     to the frequency state, so it cannot appear in a frequency difference.
            %     Including it over-charged the atomic classes ~37x (CESIUM1 measured
            %     0.017 of the charge) -- conservative, but wrong, and it would have hidden
            %     a real defect behind a huge R.
            %
            % The flicker coefficient is CALIBRATED, not derived: flicker FM has no
            % stationary variance, so Var(Delta y) over tau has no clean closed form. 16*ln2
            % matches the generator to within +-5% across all eight classes at both the
            % half-age and full-age product points, and T6 pins that.
            % Enabled 2026-08-10 once CarrierMeasurementBuilder stopped deriving its bias
            % sigma by SUBTRACTING this term. While that subtraction existed, making this
            % term correct drove it negative (age*dsig 4.19 m against a 2.42 m bias sigma),
            % clamped the carrier bias to zero and destabilised R assembly. The two were
            % locked together; the subtraction had to go first.
            var_m2s2 = 0;
            if isempty(clk) || age_s <= 0 || clk.deterministic; return; end
            % Diagnosis A #8: same includeOscillatorWander gate as extrapolationWanderVar_,
            % orthogonal to clk.deterministic (see its comment). Default true -> unchanged.
            includeWander_ = true;
            try; includeWander_ = logical(cfg.covariance.productClock.includeOscillatorWander); catch; end
            if ~includeWander_; return; end
            h = clk.noiseCoeffs;
            % Diagnosis B: h2 (WPM) and h1 (FPM) are excluded from this charge, and that
            % exclusion is CORRECT, not an oversight -- but only because ClockModel.step
            % never lets them reach the frequency state (h0 is the only phase-noise
            % branch it draws for the bias increment; :291/:331 there). precomputeNoise
            % (ClockModel.m:223), by contrast, DOES fold h2/h1 into the synthesised
            % fractional-frequency series alongside hMinus1, so a nonzero h2/h1 WOULD
            % show up in a truth frequency difference by the same mechanism hMinus1 uses
            % above -- this function would then be knowingly wrong (R optimistic), not
            % merely incomplete. No shipped oscillator class sets h2/h1 (ConfigFactory
            % oscillatorCatalog_); the only route in is cfg.clock.customOscillators. An
            % exact charge needs the synthesis grid's Nyquist frequency (ClockModel.m:
            % 216-218), which this function does not receive, so refuse rather than
            % guess -- same "won't build a knowingly wrong R" stance as
            % explicitProductWanderVar_ above.
            if h.h2 ~= 0 || h.h1 ~= 0
                policy_ = 'error';
                try; policy_ = cfg.validation.unsupportedFeaturePolicy; catch; end
                msg_ = ['Oscillator has nonzero h2/h1 (WPM/FPM), which precomputeNoise ' ...
                    'folds into the truth frequency state (ClockModel.m:223) but ' ...
                    'frequencyWanderVar_ has no implemented rate-domain charge for -- R ' ...
                    'would be knowingly optimistic. Set ' ...
                    'cfg.validation.unsupportedFeaturePolicy = ''disableWithWarning'' to ' ...
                    'proceed anyway (h2/h1 stay uncharged), or zero h2/h1 on this ' ...
                    'oscillator.'];
                if strcmp(policy_, 'disableWithWarning')
                    persistent warnedH2H1_
                    if isempty(warnedH2H1_); warnedH2H1_ = false; end
                    if ~warnedH2H1_
                        warning('TowerClockCorrectionProvider:h2h1Uncharged', '%s', msg_);
                        warnedH2H1_ = true;
                    end
                else
                    error('TowerClockCorrectionProvider:h2h1Uncharged', '%s', msg_);
                end
            end
            var_y = 2*pi^2 * h.hMinus2 * age_s ...   % RWFM, exact (3x the Allan term)
                  + 16*log(2) * h.hMinus1;           % FFM, calibrated against the generator
            var_m2s2 = (revgnss.Constants.SPEED_OF_LIGHT_MPS)^2 * max(var_y, 0);
        end

        function [b_noise, d_noise] = productNoise_(ti, t_prod, sigmaBias, sigmaDrift)
            % productNoise_  Deterministic per-(tower,t_prod) product noise.
            %
            % Uses a seeded RNG with per-(ti,t_prod) seed so the same product
            % epoch always yields the same noise regardless of call order.
            % The global RNG state is saved and restored.
            % This models a real broadcast product: the error is fixed at broadcast
            % time and does not redraw for every measurement epoch.
            %
            % The seed below is a pure, deterministic function of (ti,t_prod) only -- no asset
            % dimension, no process/session state. Every real consumer of the same tower/product
            % epoch computes the IDENTICAL noise by construction, whether or not this persistent
            % cache_ is populated: the cache is memoization of that deterministic value (keyed
            % ONLY by (ti,t_prod)), not the source of the sharing -- clearing it would still
            % reproduce the same number. This is a raw MATLAB persistent, not routed through the
            % RNG registry, so rng.independentStreams cannot isolate it either. This is real
            % cross-fleet sharing, physically correct for a genuinely shared broadcast product,
            % but currently untreated by the correlation network. See config/masterConfig.m's
            % sharedErrorCorrelation comment and revgnss.IndependentFleetCoordinator.
            % validateConfig's towerClockProductReachableButRejected guard (plan Section 3.3).
            persistent cache_;
            if isempty(cache_)
                cache_ = containers.Map('KeyType','char','ValueType','any');
            end
            key = sprintf('%d_%.4f', ti, t_prod);
            if ~isKey(cache_, key)
                seed = mod(uint64(ti) * uint64(2654435761) + uint64(round(abs(t_prod)*100)) * uint64(2246822519), uint64(2^31));
                s0 = rng();
                rng(double(seed), 'twister');
                noise = randn(2,1);
                rng(s0);
                cache_(key) = struct('b', noise(1), 'd', noise(2));
            end
            n = cache_(key);
            b_noise = sigmaBias  * n.b;
            d_noise = sigmaDrift * n.d;
        end

    end  % private Static methods
end
