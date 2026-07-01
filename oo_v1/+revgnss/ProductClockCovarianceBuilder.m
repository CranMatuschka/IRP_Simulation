classdef ProductClockCovarianceBuilder
    % ProductClockCovarianceBuilder  Shared product-clock covariance blocks (Stage 83).
    %
    % Centralises block-covariance construction for Doppler and carrier rows
    % that share a common tower-product-clock drift error.
    %
    % Doppler policy (sharedClockDriftProductBlock):
    %   R(i,j) += sigmaDrift_i * sigmaDrift_j
    %   for rows i,j from the same (tower, productEpoch).
    %   Diagonal: sigma_dop^2 (tracking) + sigmaDrift^2 (product drift).
    %
    % Carrier policy (timeVaryingProductResidualOnly):
    %   R(i,j) += age_i * age_j * sigmaDrift^2
    %   for rows i,j from the same (tower, productEpoch).
    %   Constant product bias is absorbed by float ambiguity; only the
    %   time-varying drift residual (from arc start) enters carrier R.
    %
    % All outputs are SPD-guarded via a small diagonal jitter.

    methods (Static)

        function [R, info] = addDopplerDriftBlock(R, towerIdx, t_prod, sigmaDrift, cfg)
            % addDopplerDriftBlock  Add product drift covariance to Doppler R.
            %
            % Inputs:
            %   R          [M×M] current Doppler R (must already have tracking diagonal)
            %   towerIdx   [M×1] tower index per Doppler row
            %   t_prod     [M×1] product epoch [s] per Doppler row
            %   sigmaDrift [M×1] product drift sigma [m/s] per Doppler row
            %   cfg        simulation config (for jitter_m2, ensureSPD)
            %
            % Output:
            %   R    [M×M] updated covariance (symmetric PSD)
            %   info struct diagnostics

            jitter_m2 = 1e-12;
            try; jitter_m2 = cfg.covariance.productClock.jitter_m2; catch; end
            doSPD = true;
            try; doSPD = cfg.covariance.productClock.ensureSPD; catch; end

            M = size(R, 1);
            nBlocks = 0;
            maxSigma = 0;

            % Group by (towerIdx, productEpoch) — rows in the same group share drift error
            groupKey = arrayfun(@(i) sprintf('%d_%.3f', towerIdx(i), t_prod(i)), (1:M)', ...
                'UniformOutput', false);
            uniqueKeys = unique(groupKey);

            for k = 1:numel(uniqueKeys)
                g = find(strcmp(groupKey, uniqueKeys{k}));
                if numel(g) < 1; continue; end
                sd = sigmaDrift(g(1));
                if sd <= 0; continue; end
                % Add shared drift covariance block: sd^2 * ones(|g|,|g|)
                R(g, g) = R(g, g) + sd^2 * ones(numel(g), numel(g));
                nBlocks = nBlocks + 1;
                maxSigma = max(maxSigma, sd);
            end

            if doSPD && nBlocks > 0
                R = revgnss.ProductClockCovarianceBuilder.spdGuard_(R, jitter_m2);
            end

            info.dopplerProductCovApplied     = nBlocks > 0;
            info.dopplerProductCovBlocks       = nBlocks;
            info.dopplerProductCovMaxSigma_mps = maxSigma;
            info.dopplerProductCovSPD          = doSPD;
            info.dopplerRCondition             = revgnss.ProductClockCovarianceBuilder.rcond_(R);
        end

        function [R, info] = addCarrierDriftBlock(R, towerIdx, t_prod, age, sigmaDrift, cfg)
            % addCarrierDriftBlock  Add time-varying product drift covariance to carrier R.
            %
            % Policy: timeVaryingProductResidualOnly
            %   Cov(i,j) += age_i * age_j * sigmaDrift^2
            %   for rows i,j from the same (tower, productEpoch).
            %   Constant product bias is NOT included (absorbed by float ambiguity).
            %
            % Inputs:
            %   R          [Mp×Mp] current carrier R (diagonal tracking noise)
            %   towerIdx   [Mp×1] tower index per carrier row
            %   t_prod     [Mp×1] product epoch [s] per row
            %   age        [Mp×1] product age = t_s - t_prod [s] per row
            %   sigmaDrift [Mp×1] product drift sigma [m/s] per row
            %   cfg        simulation config

            jitter_m2 = 1e-12;
            try; jitter_m2 = cfg.covariance.productClock.jitter_m2; catch; end
            doSPD = true;
            try; doSPD = cfg.covariance.productClock.ensureSPD; catch; end

            Mp = size(R, 1);
            nBlocks = 0;
            maxSigma = 0;

            groupKey = arrayfun(@(i) sprintf('%d_%.3f', towerIdx(i), t_prod(i)), (1:Mp)', ...
                'UniformOutput', false);
            uniqueKeys = unique(groupKey);

            for k = 1:numel(uniqueKeys)
                g = find(strcmp(groupKey, uniqueKeys{k}));
                if numel(g) < 1; continue; end
                sd = sigmaDrift(g(1));
                if sd <= 0; continue; end
                % age outer product: C(i,j) = age_i * age_j * sd^2
                age_g = age(g);
                R(g, g) = R(g, g) + (age_g * age_g') * sd^2;
                nBlocks = nBlocks + 1;
                maxSigma = max(maxSigma, sd * max(abs(age_g)));
            end

            if doSPD && nBlocks > 0
                R = revgnss.ProductClockCovarianceBuilder.spdGuard_(R, jitter_m2);
            end

            info.carrierProductCovApplied       = nBlocks > 0;
            info.carrierProductCovBlocks         = nBlocks;
            info.carrierProductCovMaxSigma_m     = maxSigma;
            info.carrierProductCovSPD            = doSPD;
            info.carrierProductBiasTermIncluded  = false;
            info.carrierProductDriftTermIncluded = nBlocks > 0;
            info.carrierProductBoundaryHandling  = 'withinProductEpochOnlyV1';
            info.carrierRCondition               = revgnss.ProductClockCovarianceBuilder.rcond_(R);
        end

        function [R, info] = addSharedProductClockStack(R, errStruct, cfg)
            % addSharedProductClockStack  Add cross-observable product-clock covariance.
            %
            % Row order is the MeasurementModel physical stack:
            %   code/IF code rows, then Doppler rows, then carrier rows.
            % Within-observable code, Doppler, and carrier blocks are owned by their
            % existing builders. This helper fills the cross-observable terms that
            % blkdiag would otherwise force to zero.

            info = struct('applied',false,'nCrossTerms',0,'jitterAdded_m2',0, ...
                'spd',true,'condition',NaN,'policy','perProductEpochBiasDriftV1');
            if isempty(R) || ~isnumeric(R); return; end

            enable = false;
            try; enable = cfg.covariance.productClock.enable; catch; end
            if ~enable; return; end

            applyCode = false; applyDop = false; applyCar = false; crossCodeDop = false;
            try; applyCode = cfg.covariance.productClock.applyToCode; catch; end
            try; applyDop = cfg.covariance.productClock.applyToDoppler; catch; end
            try; applyCar = cfg.covariance.productClock.applyToCarrier; catch; end
            try; crossCodeDop = cfg.covariance.productClock.crossCodeDoppler; catch; end
            if ~(applyCode && (applyDop || applyCar)); return; end

            M_code = 0;
            try; M_code = double(errStruct.nPseudorange); catch; end
            M_dop = 0;
            try; M_dop = numel(errStruct.doppler.z); catch; end
            M_car = 0;
            try; M_car = numel(errStruct.carrierPhase.towerIdx); catch; end
            nRows = size(R,1);
            if M_code <= 0 || nRows ~= M_code + M_dop + M_car; return; end

            pc = revgnss.ProductClockCovarianceBuilder.productCfg_(cfg);

            codeRows = (1:M_code)';
            codeTower = zeros(M_code,1);
            try; codeTower = errStruct.towerIdx_perMeas(:); catch; end
            if numel(codeTower) ~= M_code; codeTower = zeros(M_code,1); end
            codeEpoch = revgnss.ProductClockCovarianceBuilder.expand_( ...
                revgnss.ProductClockCovarianceBuilder.fieldOr_(errStruct,'towerClockProductEpoch_s',0), M_code);
            codeAge = revgnss.ProductClockCovarianceBuilder.expand_( ...
                revgnss.ProductClockCovarianceBuilder.fieldOr_(errStruct,'towerClockProductAge_s',0), M_code);

            if applyDop && M_dop > 0 && crossCodeDop
                dopRows = (M_code + (1:M_dop))';
                dopTower = revgnss.ProductClockCovarianceBuilder.fieldOr_(errStruct.doppler,'towerIdx',zeros(M_dop,1));
                dopEpoch = revgnss.ProductClockCovarianceBuilder.fieldOr_(errStruct.doppler,'productEpoch_s',zeros(M_dop,1));
                dopSigma = revgnss.ProductClockCovarianceBuilder.fieldOr_(errStruct.doppler,'sigmaDrift_mps',zeros(M_dop,1));
                for i = 1:M_code
                    for j = 1:M_dop
                        if codeTower(i) == dopTower(j) && abs(codeEpoch(i)-dopEpoch(j)) < 1e-6
                            cov_ij = pc.covBiasDrift + codeAge(i) * dopSigma(j)^2;
                            if cov_ij ~= 0
                                R(codeRows(i), dopRows(j)) = R(codeRows(i), dopRows(j)) + cov_ij;
                                R(dopRows(j), codeRows(i)) = R(codeRows(i), dopRows(j));
                                info.nCrossTerms = info.nCrossTerms + 2;
                            end
                        end
                    end
                end
            end

            if applyCar && M_car > 0
                carRows = (M_code + M_dop + (1:M_car))';
                cp = errStruct.carrierPhase;
                carTower = revgnss.ProductClockCovarianceBuilder.fieldOr_(cp,'towerIdx',zeros(M_car,1));
                carEpoch = revgnss.ProductClockCovarianceBuilder.fieldOr_(cp,'productEpoch_s',zeros(M_car,1));
                carAge = revgnss.ProductClockCovarianceBuilder.fieldOr_(cp,'productAge_s',zeros(M_car,1));
                carSigma = revgnss.ProductClockCovarianceBuilder.fieldOr_(cp,'sigmaDrift_mps',zeros(M_car,1));
                for i = 1:M_code
                    for j = 1:M_car
                        if codeTower(i) == carTower(j) && abs(codeEpoch(i)-carEpoch(j)) < 1e-6
                            cov_ij = codeAge(i) * carAge(j) * carSigma(j)^2;
                            if cov_ij ~= 0
                                R(codeRows(i), carRows(j)) = R(codeRows(i), carRows(j)) + cov_ij;
                                R(carRows(j), codeRows(i)) = R(codeRows(i), carRows(j));
                                info.nCrossTerms = info.nCrossTerms + 2;
                            end
                        end
                    end
                end
            end

            R = (R + R') / 2;
            jitter = 1e-12;
            doSPD = true;
            try; jitter = cfg.covariance.productClock.jitter_m2; catch; end
            try; doSPD = cfg.covariance.productClock.ensureSPD; catch; end
            if doSPD
                [~, p] = chol(R);
                if p ~= 0
                    minEig = min(eig(R));
                    addJitter = max(jitter, -minEig + jitter);
                    R = R + addJitter * eye(size(R,1));
                    info.jitterAdded_m2 = addJitter;
                    [~, p2] = chol(R);
                    info.spd = (p2 == 0);
                end
            end
            info.applied = info.nCrossTerms > 0;
            info.condition = revgnss.ProductClockCovarianceBuilder.rcond_(R);
        end

    end

    methods (Static, Access = private)

        function R = spdGuard_(R, jitter_m2)
            R = (R + R') / 2;
            R = R + jitter_m2 * eye(size(R));
        end

        function rc = rcond_(R)
            try; rc = rcond(R); catch; rc = NaN; end
        end

        function v = fieldOr_(s, f, d)
            v = d;
            try
                if isfield(s,f); v = s.(f); end
            catch
            end
            v = v(:);
        end

        function v = expand_(x, n)
            if isempty(x); v = zeros(n,1); return; end
            x = x(:);
            if numel(x) == 1
                v = repmat(x, n, 1);
            elseif numel(x) >= n
                v = x(1:n);
            else
                v = [x; repmat(x(end), n-numel(x), 1)];
            end
        end

        function pc = productCfg_(cfg)
            pc.sigmaBias_m = 0.10;
            pc.sigmaDrift_mps = 1e-3;
            pc.covBiasDrift = 0;
            try
                tp = cfg.clocks.tower.product;
                if isfield(tp,'sigmaBias_m'); pc.sigmaBias_m = tp.sigmaBias_m; end
                if isfield(tp,'sigmaDrift_mps'); pc.sigmaDrift_mps = tp.sigmaDrift_mps; end
                if isfield(tp,'covBiasDrift'); pc.covBiasDrift = tp.covBiasDrift; end
            catch
            end
        end

    end
end
