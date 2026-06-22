classdef TowerClockCorrectionProvider
    % TowerClockCorrectionProvider  Computes per-measurement tower clock corrections.
    %
    % Extracted from MeasurementModel.computeMeasurements (Stage 12A Step 3).
    % All physics are preserved exactly — this is a pure structural refactor.
    %
    % Stage 71: adds 'truthHistoryProductNoisy' mode — a realistic synthetic
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
            mode = revgnss.TowerClockCorrectionProvider.towerClockMode(cfg);

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
            % Stage 71: clocks.tower.product.* takes precedence
            [~, prodCfg] = revgnss.TowerClockCorrectionProvider.productConfig_(cfg);
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
                        [b_p, bd_p] = revgnss.TowerClockCorrectionProvider.clockAtProductEpoch( ...
                            towers{ti}, t_prod);
                        towerClkModel(mi) = b_p + bd_p * (t_s - t_prod);
                    case 'truthHistoryProductNoisy'
                        % Stage 71: realistic product correction.
                        % 1. Read truth clock at product epoch from tower history.
                        [b_p, bd_p] = revgnss.TowerClockCorrectionProvider.clockAtProductEpoch( ...
                            towers{ti}, t_prod);
                        % 2. Deterministic per-(tower,t_prod) product noise (seeded cache).
                        [b_noise, d_noise] = revgnss.TowerClockCorrectionProvider.productNoise_( ...
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
                        [b_hat, ~] = revgnss.TowerClockCorrectionProvider.evalProductStruct( ...
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
                        [b_hat, sig_corr] = revgnss.TowerClockCorrectionProvider.evalProductStruct( ...
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
            % For 'truthHistoryProduct'/'product'/'productNoisy' modes that do NOT have
            % an explicit cfg.towerClock.products struct, reads from tower history.
            % Returns [0, 0] when history is unavailable (first epoch or t_prod=0).
            b_m      = 0;
            bdot_mps = 0;
            hist = tower.history;
            if isempty(hist.time_s) || isempty(hist.clockBias_m)
                return;
            end
            idx = find(hist.time_s <= t_prod_s + 1e-9, 1, 'last');
            if isempty(idx); return; end
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
                cache_(key) = struct('b', sigmaBias * noise(1), 'd', sigmaDrift * noise(2));
            end
            n = cache_(key);
            b_noise = n.b;
            d_noise = n.d;
        end

    end  % private Static methods
end
