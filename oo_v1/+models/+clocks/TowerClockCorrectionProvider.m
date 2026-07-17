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
                corrNoise_m = noiseSigma * errorChain.drawNormal(M, 1);
            else
                corrNoise_m = zeros(M,1);
            end

            % TASK 6: Product epoch computed ONCE before measurement loop so
            % 'product' and 'productNoisy' modes can evaluate b_hat(t_s) =
            % b(t_prod) + bdot(t_prod) * (t_s - t_prod) per tower.
            updateInterval_s = 300;
            latency_s        = 0;
            if isfield(cfg,'errors') && isfield(cfg.errors,'towerClock')
                tc2 = cfg.errors.towerClock;
                if isfield(tc2,'updateInterval_s'); updateInterval_s = tc2.updateInterval_s; end
                if isfield(tc2,'latency_s');        latency_s        = tc2.latency_s;        end
            end
            % clocks.tower.product.* takes precedence
            [~, prodCfg] = models.clocks.TowerClockCorrectionProvider.productConfig_(cfg);
            if prodCfg.updateInterval_s > 0
                updateInterval_s = prodCfg.updateInterval_s;
            end
            if prodCfg.latency_s >= 0
                latency_s = prodCfg.latency_s;
            end

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
                        towerClkModel(mi) = 0;
                    case 'perfectCorrection'
                        towerClkModel(mi) = b_t;
                    case 'noisyCorrection'
                        towerClkModel(mi) = b_t + corrNoise_m(mi);
                        towerClkSigma(mi) = noiseSigma;
                    case 'truthProduct'
                        [b_p, bd_p] = models.clocks.TowerClockCorrectionProvider.clockAtProductEpoch( ...
                            towers{ti}, t_prod);
                        towerClkModel(mi) = b_p + bd_p * (t_s - t_prod);
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
                        var_corr = prodCfg.sigmaBias_m^2 + ...
                                   age^2 * prodCfg.sigmaDrift_mps^2 + ...
                                   2 * age * prodCfg.covBiasDrift;
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
                        [b_hat, ~] = models.clocks.TowerClockCorrectionProvider.evalProductStruct( ...
                            cfg, ti, t_s);
                        towerClkModel(mi) = b_hat;
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
                        towerClkSigma(mi) = sig_corr;
                    otherwise
                        towerClkModel(mi) = 0;
                end
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

            % Product epoch scalar — same logic as compute()
            updateInterval_s = pc.updateInterval_s;
            latency_s        = pc.latency_s;
            try
                tc2 = cfg.errors.towerClock;
                if isfield(tc2,'updateInterval_s') && pc.updateInterval_s <= 0
                    updateInterval_s = tc2.updateInterval_s;
                end
                if isfield(tc2,'latency_s') && pc.latency_s < 0
                    latency_s = tc2.latency_s;
                end
            catch; end
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
                        % Use product-epoch truth drift to be consistent with bias path.
                        [~, bd_p] = models.clocks.TowerClockCorrectionProvider.clockAtProductEpoch( ...
                            towers{ti}, t_prod_scalar);
                        bdot_truth(mi)  = bd_p;
                        bdot_model(mi)  = bd_p;
                        drift_sigma(mi) = 0;
                        driftAnchorStatus = 'productEpochTruth';
                        driftSigmaSource_out = 'zero';

                    case 'truthHistoryProductNoisy'
                        % Anchor at product-epoch truth drift (not current-epoch).
                        % Consistent with bias path in compute() which uses clockAtProductEpoch.
                        [~, bd_p] = models.clocks.TowerClockCorrectionProvider.clockAtProductEpoch( ...
                            towers{ti}, t_prod_scalar);
                        [~, d_noise] = models.clocks.TowerClockCorrectionProvider.productNoise_( ...
                            ti, t_prod_scalar, pc.sigmaBias_m, pc.sigmaDrift_mps);
                        bdot_truth(mi)  = bd_p;  % product-epoch truth
                        bdot_model(mi)  = bd_p + d_noise;
                        drift_sigma(mi) = pc.sigmaDrift_mps;
                        truthHistoryProductDriftUsed = true;
                        driftAnchorStatus = 'productEpochTruth';
                        driftSigmaSource_out = 'productConfig';

                    case 'truthProduct'
                        % Pure history-based product drift, no noise.
                        [~, bd_p] = models.clocks.TowerClockCorrectionProvider.clockAtProductEpoch( ...
                            towers{ti}, t_prod_scalar);
                        bdot_truth(mi)  = bd_p;
                        bdot_model(mi)  = bd_p;
                        drift_sigma(mi) = 0;
                        truthHistoryProductDriftUsed = true;
                        driftAnchorStatus = 'productEpochTruth';
                        driftSigmaSource_out = 'zero';

                    case {'product', 'productNoisy'}
                        % Explicit product struct required; no truth-history fallback.
                        hasProd = isfield(cfg,'towerClock') && ...
                                  isfield(cfg.towerClock,'products') && ...
                                  ti <= numel(cfg.towerClock.products);
                        if hasProd
                            prod = cfg.towerClock.products(ti);
                            if isfield(prod,'drift_mps')
                                bdot_model(mi) = prod.drift_mps;
                            end
                            if strcmp(mode,'productNoisy') && isfield(prod,'sigmaDrift_mps')
                                drift_sigma(mi) = prod.sigmaDrift_mps;
                            elseif strcmp(mode,'productNoisy')
                                drift_sigma(mi) = pc.sigmaDrift_mps;
                            end
                            if isfield(prod,'epoch_s')
                                t_prod_out(mi) = prod.epoch_s;
                            end
                            explicitProductDriftUsed = true;
                            driftAnchorStatus = 'explicitProductStruct';
                            driftSigmaSource_out = 'explicitProduct';
                        else
                            % Missing explicit product — use zero drift, report clearly.
                            bdot_model(mi)  = 0;
                            drift_sigma(mi) = 0;
                            driftAnchorStatus = 'missingExplicitProductFallbackZero';
                            driftSigmaSource_out = 'zero';
                        end

                    case 'noisyCorrection'
                        % noisyCorrection is a bias-only toy correction; no drift noise modelled.
                        bdot_model(mi)  = 0;
                        drift_sigma(mi) = 0;
                        driftAnchorStatus = 'notApplicableNoisyCorrection';
                        driftSigmaSource_out = 'zero';

                    otherwise  % 'none'
                        bdot_model(mi)  = 0;
                        drift_sigma(mi) = 0;
                        driftAnchorStatus = 'notApplicableNoCorrection';
                        driftSigmaSource_out = 'zero';
                end
            end

            meta.mode                        = mode;
            meta.driftProductMode            = driftProductMode_out;
            meta.driftAnchorStatus           = driftAnchorStatus;
            meta.driftSigmaSource            = driftSigmaSource_out;
            meta.explicitProductDriftUsed    = explicitProductDriftUsed;
            meta.truthHistoryProductDriftUsed = truthHistoryProductDriftUsed;
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

        function [b_noise, d_noise] = productNoise_(ti, t_prod, sigmaBias, sigmaDrift)
            % productNoise_  Deterministic per-(tower,t_prod) product noise.
            %
            % Uses a seeded RNG with per-(ti,t_prod) seed so the same product
            % epoch always yields the same noise regardless of call order.
            % The global RNG state is saved and restored.
            % This models a real broadcast product: the error is fixed at broadcast
            % time and does not redraw for every measurement epoch.
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
