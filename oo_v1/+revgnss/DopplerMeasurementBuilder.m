classdef DopplerMeasurementBuilder
    % DopplerMeasurementBuilder  Constructs Doppler EKF measurement rows.
    %
    % Stage 83 upgrade: frame-consistent one-way range-rate model.
    %   - Adds tower ECI rotational velocity (sagnacRate term) to both truth
    %     and model; captures the Sagnac-rate effect consistently.
    %   - Tower clock product drift model used (not zeroed in product modes).
    %   - Doppler R includes product-drift covariance blocks (same tower/epoch).
    %   - Sagnac rate guard: capturedByTowerVelocityTerm (no double count).
    %   - Light-time rate derivative: metadataOnlyV1 (simplified).

    methods (Static)

        function [rows, dopplerInfo] = build(cfg, errorChain, asset, towers, ...
                twr_list, ant_list, r_ants_truth, r_ants_est, x_est, stateMap, ...
                towerClkMode, t_s)
            % build  Construct Doppler measurement rows from a pre-built visibility list.

            if nargin < 12 || isempty(t_s); t_s = 0; end

            M  = numel(twr_list);
            nx = numel(x_est);

            rows.z              = [];
            rows.h              = [];
            rows.H              = zeros(0, nx);
            rows.R              = zeros(0, 0);
            rows.useInEKF       = false;
            rows.ionoRateExclusion = false;

            dopplerInfo = struct();

            doCfg = isfield(cfg,'measurements') && ...
                    isfield(cfg.measurements,'doppler') && ...
                    cfg.measurements.doppler.enable;

            if ~doCfg
                return
            end

            doTruth  = isfield(cfg,'physics') && isfield(cfg.physics,'doppler') && ...
                       isfield(cfg.physics.doppler,'truth') && cfg.physics.doppler.truth.enable;
            doModel  = isfield(cfg,'physics') && isfield(cfg.physics,'doppler') && ...
                       isfield(cfg.physics.doppler,'model') && cfg.physics.doppler.model.enable;
            useInEKF = cfg.measurements.doppler.useInEKF;

            if ~doTruth && mod(round(t_s), 300) == 0
                warning('MeasurementModel:dopplerNoTruth', ...
                    ['Doppler enabled but physics.doppler.truth.enable=false. ' ...
                     'Doppler z will be zeros. Enable physics.doppler.truth for realistic Doppler.']);
            end
            if ~doModel && useInEKF
                error('MeasurementModel:dopplerNoModel', ...
                    ['Doppler useInEKF=true requires physics.doppler.model.enable=true. ' ...
                     'Cannot build h model without physics.doppler.model.enable.']);
            end

            ionoRateEnabled = isfield(cfg,'errors') && ...
                isfield(cfg.errors,'ionosphere') && ...
                isfield(cfg.errors.ionosphere,'includeRateTerm') && ...
                cfg.errors.ionosphere.includeRateTerm;
            if ionoRateEnabled
                warning('revgnss:ionoFreeCode', ...
                    ['ionosphere.includeRateTerm is enabled but no Doppler ' ...
                     'IF combination model exists. ' ...
                     'Doppler rows are excluded to avoid unmodelled dispersive bias.']);
                dopplerInfo = struct('z',[],'h',[],'prefit',[], ...
                    'towerClockDriftTruth_mps',[],'towerClockDriftModel_mps',[]);
                rows.ionoRateExclusion = true;
                return
            end

            % --- Stage 83: read config flags ---
            includeTowerVel     = true;
            try; includeTowerVel = cfg.measurements.doppler.includeTowerRotationalVelocity; catch; end
            includeProdDrift    = true;
            try; includeProdDrift = cfg.measurements.doppler.includeTowerClockProductDrift; catch; end
            applyDopplerProdCov = true;
            try; applyDopplerProdCov = cfg.covariance.productClock.applyToDoppler; catch; end

            v_rx_true    = asset.v_ecef_mps;
            v_rx_est     = x_est(stateMap.v_idx);
            bdot_rx_true = asset.clock.getDriftMetersPerSecond();
            bdot_rx_est  = x_est(stateMap.bdot_rx_idx);
            sigma_dop    = cfg.measurements.doppler.sigma_mps;

            zd      = zeros(M,1);
            hd      = zeros(M,1);
            Hd      = zeros(M,nx);
            Rd_diag = sigma_dop^2 * ones(M,1);

            towerClockDriftTruth_mps = zeros(M,1);
            towerClockDriftModel_mps = zeros(M,1);

            % Stage 83: product drift for all towers (shared cache; consistent with compute())
            twr_drift_model  = zeros(M,1);
            twr_drift_sigma  = zeros(M,1);
            t_prod_per_row   = zeros(M,1);
            driftMeta_ = struct('driftAnchorStatus','unknown','driftProductMode','unknown', ...
                'driftSigmaSource','zero','explicitProductDriftUsed',false, ...
                'truthHistoryProductDriftUsed',false);
            if includeProdDrift
                try
                    [~, bdot_mod_vec, dsig_vec, tprod_vec, driftMeta_] = ...
                        revgnss.TowerClockCorrectionProvider.computeDrift( ...
                        cfg, towers, twr_list, t_s);
                    twr_drift_model = bdot_mod_vec;
                    twr_drift_sigma = dsig_vec;
                    t_prod_per_row  = tprod_vec;
                catch
                    for mi2 = 1:M
                        ti2 = twr_list(mi2);
                        if strcmp(towerClkMode, 'perfectCorrection')
                            twr_drift_model(mi2) = towers{ti2}.getClockDriftMetersPerSecond();
                        end
                    end
                end
            else
                for mi2 = 1:M
                    ti2 = twr_list(mi2);
                    if strcmp(towerClkMode, 'perfectCorrection')
                        twr_drift_model(mi2) = towers{ti2}.getClockDriftMetersPerSecond();
                    end
                end
            end

            sagnacRateVec  = zeros(M,1);
            towerRotSpeeds = zeros(M,1);

            for mi = 1:M
                ti = twr_list(mi);
                ai = ant_list(mi);

                bdot_twr = towers{ti}.getClockDriftMetersPerSecond();
                towerClockDriftTruth_mps(mi) = bdot_twr;
                towerClockDriftModel_mps(mi) = twr_drift_model(mi);

                % Truth side
                r_twr_t = revgnss.MeasurementModelUtils.towerPositionEcef(cfg, towers{ti}, ti, 'truth');
                delta_t = r_ants_truth(:,ai) - r_twr_t;
                rho_t   = norm(delta_t); if rho_t < 1; rho_t = 1; end
                u_t     = delta_t / rho_t;

                if doTruth
                    if includeTowerVel
                        [rhoDot_true, ~, ~, sagnac_t, ~] = revgnss.OneWayRangeRateModel.compute( ...
                            r_ants_truth(:,ai), v_rx_true, r_twr_t, cfg);
                        sagnacRateVec(mi) = sagnac_t;
                    else
                        rhoDot_true = u_t' * v_rx_true;
                    end
                    zd(mi) = rhoDot_true + bdot_rx_true - bdot_twr + ...
                             sigma_dop * errorChain.drawNormal(1,1);
                end

                % Model side
                r_twr_e = revgnss.MeasurementModelUtils.towerPositionEcef(cfg, towers{ti}, ti, 'model');
                delta_e = r_ants_est(:,ai) - r_twr_e;
                rho_e   = norm(delta_e); if rho_e < 1; rho_e = 1; end
                u_e     = delta_e / rho_e;

                if doModel
                    if includeTowerVel
                        [rhoDot_est, ~, v_twr_eci, ~, ~] = revgnss.OneWayRangeRateModel.compute( ...
                            r_ants_est(:,ai), v_rx_est, r_twr_e, cfg);
                        towerRotSpeeds(mi) = norm(v_twr_eci);
                    else
                        rhoDot_est = u_e' * v_rx_est;
                    end
                    hd(mi) = rhoDot_est + bdot_rx_est - twr_drift_model(mi);
                end

                Hd(mi, stateMap.v_idx)       = u_e';
                Hd(mi, stateMap.bdot_rx_idx) = 1;
            end

            % Stage 84: Doppler R diagonal policy — product drift variance counted exactly once.
            % addDopplerDriftBlock adds the full block (diagonal + off-diagonal) for same-tower/epoch rows.
            % When that helper is NOT called, add drift variance to diagonal only.
            Rd = diag(Rd_diag);  % tracking noise only at this point

            doppCovInfo = struct('dopplerProductCovApplied',false,'dopplerProductCovBlocks',0, ...
                'dopplerProductCovMaxSigma_mps',0,'dopplerProductCovSPD',false,'dopplerRCondition',NaN);
            dopplerDriftDiagPolicy = 'trackingOnlyNoProductDrift';

            if applyDopplerProdCov && any(twr_drift_sigma > 0) && M > 0
                % Block + diagonal: let addDopplerDriftBlock own the full drift contribution.
                % Do NOT pre-add drift sigma to Rd_diag — that would double-count.
                try
                    [Rd, doppCovInfo] = revgnss.ProductClockCovarianceBuilder.addDopplerDriftBlock( ...
                        Rd, twr_list, t_prod_per_row, twr_drift_sigma, cfg);
                    dopplerDriftDiagPolicy = 'trackingOnlyPlusBlock';
                catch; end
            elseif any(twr_drift_sigma > 0)
                % Product cov disabled: add diagonal-only drift contribution (no block).
                Rd = Rd + diag(twr_drift_sigma.^2);
                dopplerDriftDiagPolicy = 'diagonalOnlyProductDrift';
            end

            dopplerInfo.z       = zd;
            dopplerInfo.h       = hd;
            dopplerInfo.prefit  = zd - hd;
            dopplerInfo.towerClockDriftTruth_mps        = towerClockDriftTruth_mps;
            dopplerInfo.towerClockDriftModel_mps        = towerClockDriftModel_mps;
            dopplerInfo.towerIdx                         = twr_list(:);
            dopplerInfo.productEpoch_s                   = t_prod_per_row(:);
            dopplerInfo.sigmaDrift_mps                   = twr_drift_sigma(:);
            dopplerInfo.sagnacRateVec_mps               = sagnacRateVec;
            dopplerInfo.sagnacRateMax_mps               = max(abs(sagnacRateVec));
            dopplerInfo.towerRotSpeeds_mps              = towerRotSpeeds;
            dopplerInfo.meanTowerRotSpeed_mps           = mean(towerRotSpeeds(towerRotSpeeds > 0));
            dopplerInfo.maxTowerRotSpeed_mps            = max(towerRotSpeeds);
            dopplerInfo.dopplerModelLevel               = 'frameConsistentV2';
            dopplerInfo.towerRotationalVelocityIncluded = includeTowerVel;
            dopplerInfo.sagnacRateHandling              = 'capturedByTowerVelocityTerm';
            dopplerInfo.lightTimeRateHandling           = 'metadataOnlyV1';
            dopplerInfo.towerClockProductDriftInDoppler = includeProdDrift;
            dopplerInfo.dopplerProductCovApplied        = doppCovInfo.dopplerProductCovApplied;
            dopplerInfo.dopplerProductCovBlocks         = doppCovInfo.dopplerProductCovBlocks;
            dopplerInfo.dopplerProductCovMaxSigma_mps   = doppCovInfo.dopplerProductCovMaxSigma_mps;
            dopplerInfo.dopplerProductCovSPD            = doppCovInfo.dopplerProductCovSPD;
            dopplerInfo.dopplerRCondition               = doppCovInfo.dopplerRCondition;
            dopplerInfo.dopplerDriftVarianceDiagonalPolicy = dopplerDriftDiagPolicy;
            dopplerInfo.driftAnchorStatus                = driftMeta_.driftAnchorStatus;
            dopplerInfo.driftProductMode                 = driftMeta_.driftProductMode;
            dopplerInfo.driftSigmaSource                 = driftMeta_.driftSigmaSource;
            dopplerInfo.explicitProductDriftUsed         = driftMeta_.explicitProductDriftUsed;
            dopplerInfo.truthHistoryProductDriftUsed     = driftMeta_.truthHistoryProductDriftUsed;
            dopplerInfo.codeDopplerCrossCovStatus       = 'notImplementedGuarded';

            rows.useInEKF = useInEKF;
            if useInEKF
                rows.z = zd;
                rows.h = hd;
                rows.H = Hd;
                rows.R = Rd;
            end
        end

    end
end
