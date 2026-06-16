classdef TowerClockCorrectionProvider
    % TowerClockCorrectionProvider  Computes per-measurement tower clock corrections.
    %
    % Extracted from MeasurementModel.computeMeasurements (Stage 12A Step 3).
    % All physics are preserved exactly — this is a pure structural refactor.

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
                % predictedProduct is the more realistic product model.
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
            t_available = t_s - latency_s;
            if updateInterval_s > 0
                t_prod = floor(t_available / updateInterval_s) * updateInterval_s;
            else
                t_prod = t_available;
            end
            if t_prod < 0
                warning('revgnss:productEpoch', ...
                    'Product epoch negative at t=%.1f s; clamping to 0.', t_s);
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
end
