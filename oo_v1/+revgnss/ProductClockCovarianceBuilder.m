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

    end

    methods (Static, Access = private)

        function R = spdGuard_(R, jitter_m2)
            R = (R + R') / 2;
            R = R + jitter_m2 * eye(size(R));
        end

        function rc = rcond_(R)
            try; rc = rcond(R); catch; rc = NaN; end
        end

    end
end
