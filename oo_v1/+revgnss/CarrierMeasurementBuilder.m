classdef CarrierMeasurementBuilder
    % CarrierMeasurementBuilder  Builds carrier-phase EKF rows (float-ambiguity mode).
    %
    % Extracted from MeasurementModel.computeCarrierEkfRows_ (Stage 12A Step 2).
    % All physics are preserved exactly — this is a pure structural refactor.

    methods (Static)

        function [z_phi, h_phi, H_phi, R_phi, cpInfo] = buildEkfRows( ...
                cfg, errorChain, floatAmbiguityTruth_m, ...
                asset, towers, twr_pairs, ant_pairs, r_ants_truth, r_ants_est, ...
                leverArms_model, x_est, stateMap, nx, errStruct, ...
                towerClkTruth, towerClkModel, ~, t_s)
            % buildEkfRows  Carrier EKF measurement rows.
            %
            % z_phi = rho_true + b_rx_true - b_twr_true + trop_true - iono_true + B_true + noise
            % h_phi = rho_est  + b_rx_est  - b_twr_model + trop_model - iono_model + B_est
            %
            % CRITICAL: ionosphere sign is NEGATIVE for carrier (phase advance),
            % opposite to +iono for code (group delay).
            % B_phi states are float, in metres, one per (tower, sigIdx=1) arc.
            %
            % floatAmbiguityTruth_m is a containers.Map (handle class).
            % Keys added here persist in the caller's obj.floatAmbiguityTruth_m.
            if nargin < 18 || isempty(t_s); t_s = 0; end

            Mp = numel(twr_pairs);

            % Carrier IF not implemented in oo_v1.
            if isfield(cfg,'measurements') && ...
                    isfield(cfg.measurements,'carrierCombinationMode') && ...
                    strcmp(cfg.measurements.carrierCombinationMode,'ionosphereFree')
                policy = '';
                if isfield(cfg,'validation') && ...
                        isfield(cfg.validation,'unsupportedFeaturePolicy')
                    policy = cfg.validation.unsupportedFeaturePolicy;
                end
                if ~strcmp(policy,'disableWithWarning')
                    error('MeasurementModel:carrierIFNotImplemented', ...
                        ['Carrier ionosphere-free combination is NOT implemented in oo_v1. ' ...
                         'Only raw L1 float carrier EKF is supported. ' ...
                         'Use code IF (codeMode=''ionosphereFree'') or disable carrier EKF. ' ...
                         'To suppress this error and use raw L1, set: ' ...
                         'cfg.validation.unsupportedFeaturePolicy = ''disableWithWarning''.']);
                else
                    warning('MeasurementModel:carrierIFNotImplemented', ...
                        'carrierCombinationMode=ionosphereFree not implemented. Using raw L1 carrier instead.');
                end
            end

            sigma_phi = 0.005;
            if isfield(cfg,'measurements') && isfield(cfg.measurements,'carrier') && ...
                    isfield(cfg.measurements.carrier,'sigma_m')
                sigma_phi = cfg.measurements.carrier.sigma_m;
            end

            sigIdx    = 1;   % carrier rows use signal index 1 (L1) in v1
            b_rx_true = asset.clock.getBiasMeters();
            b_rx_est  = x_est(stateMap.b_rx_idx);

            z_phi = zeros(Mp, 1);
            h_phi = zeros(Mp, 1);
            H_phi = zeros(Mp, nx);
            R_phi = sigma_phi^2 * eye(Mp);

            cpInfo.towerIdx   = twr_pairs;
            cpInfo.antennaIdx = ant_pairs;
            cpInfo.phi_m      = zeros(Mp, 1);
            cpInfo.prefit_m   = zeros(Mp, 1);

            for mi = 1:Mp
                ti  = twr_pairs(mi);
                ai  = ant_pairs(mi);
                elv = errStruct.elevations_rad(mi);

                % True float ambiguity — initialised once per arc
                key = int32(ti * 1000 + ai);
                if ~isKey(floatAmbiguityTruth_m, key)
                    initSig = 100;
                    if isfield(cfg,'estimation') && isfield(cfg.estimation,'ambiguity') && ...
                            isfield(cfg.estimation.ambiguity,'initialSigma_m')
                        initSig = cfg.estimation.ambiguity.initialSigma_m;
                    end
                    floatAmbiguityTruth_m(key) = initSig * errorChain.drawNormal(1,1);
                end
                B_true = floatAmbiguityTruth_m(key);

                % EKF ambiguity state (0 until EKF initialises it via P_0)
                B_est = 0;
                if isfield(stateMap,'ambiguityIdx') && ...
                        ti <= size(stateMap.ambiguityIdx,1) && ...
                        sigIdx <= size(stateMap.ambiguityIdx,2) && ...
                        stateMap.ambiguityIdx(ti,sigIdx) > 0
                    B_est = x_est(stateMap.ambiguityIdx(ti,sigIdx));
                end

                % Tower clock
                b_twr_t = towerClkTruth(mi);
                b_twr_m = towerClkModel(mi);

                % Ionosphere — NEGATIVE for carrier (opposite to +iono for code)
                iono_t = 0; iono_m = 0;
                if isfield(errStruct,'bySource')
                    bt = errStruct.bySource.truth_m;
                    bm = errStruct.bySource.model_m;
                    if isfield(bt,'iono') && mi <= numel(bt.iono); iono_t = bt.iono(mi); end
                    if isfield(bm,'iono') && mi <= numel(bm.iono); iono_m = bm.iono(mi); end
                end

                % Troposphere — same sign as code
                trop_t = 0; trop_m = 0;
                if isfield(errStruct,'bySource')
                    bt = errStruct.bySource.truth_m;
                    bm = errStruct.bySource.model_m;
                    if isfield(bt,'trop') && mi <= numel(bt.trop); trop_t = bt.trop(mi); end
                    if isfield(bm,'trop') && mi <= numel(bm.trop); trop_m = bm.trop(mi); end
                end

                % Truth geometric range (survey + PCO + corrections)
                r_twr_t = revgnss.MeasurementModel.towerPositionEcef(cfg, towers{ti}, ti, 'truth');
                if isfield(cfg,'effects') && isfield(cfg.effects,'antennaPCO')
                    pco = cfg.effects.antennaPCO;
                    if isfield(pco,'truth') && pco.truth.enable
                        tOff = pco.towerOffset_enu_m(:);
                        R_ENU = revgnss.GeometryUtils.enu2ecef(towers{ti}.lat_rad, towers{ti}.lon_rad);
                        r_twr_t = r_twr_t + R_ENU * tOff;
                    end
                end
                rho_t = revgnss.RangeCorrections.correctedPseudorange( ...
                    r_ants_truth(:,ai), r_twr_t, cfg, 'truth', elv, t_s);

                % Model geometric range
                r_ant_e    = r_ants_est(:, ai);
                r_twr_e    = revgnss.MeasurementModel.towerPositionEcef(cfg, towers{ti}, ti, 'model');
                delta_e    = r_ant_e - r_twr_e;
                rho_e_geom = norm(delta_e); if rho_e_geom < 1; rho_e_geom = 1; end
                rho_e = revgnss.RangeCorrections.correctedPseudorange( ...
                    r_ant_e, r_twr_e, cfg, 'model', elv, t_s);

                noise_phi = sigma_phi * errorChain.drawNormal(1,1);

                % z: +trop, -iono (carrier ionosphere is OPPOSITE sign to code)
                z_phi(mi) = rho_t + b_rx_true - b_twr_t + trop_t - iono_t + B_true + noise_phi;

                % h: +trop_model, -iono_model + ZWD state
                h_phi(mi) = rho_e + b_rx_est - b_twr_m + trop_m - iono_m + B_est;
                if isfield(stateMap,'zwdIdx') && ti <= numel(stateMap.zwdIdx) && ...
                        stateMap.zwdIdx(ti) > 0
                    mf_phi = revgnss.MappingFunctions.troposphere(elv, ...
                        revgnss.MeasurementModel.zwdMappingKind(cfg));
                    h_phi(mi) = h_phi(mi) + mf_phi * x_est(stateMap.zwdIdx(ti));
                end

                cpInfo.phi_m(mi)    = z_phi(mi);
                cpInfo.prefit_m(mi) = z_phi(mi) - h_phi(mi);

                % ---- H: position columns (analytic or finite-difference) ------
                r_cm_est  = x_est(stateMap.r_idx);
                euler_est = x_est(stateMap.euler_idx);
                doFD = revgnss.MeasurementModel.needsFiniteDiffH_(cfg);

                if doFD
                    % Central finite-difference position Jacobian.
                    % Uses modelRangeOnly — same function as the h_phi range term.
                    step_r = 1.0;
                    for ki = 1:3
                        rp = r_cm_est; rp(ki) = rp(ki) + step_r;
                        rm = r_cm_est; rm(ki) = rm(ki) - step_r;
                        hp = revgnss.MeasurementModel.modelRangeOnly( ...
                            cfg, towers, ti, ai, rp, euler_est, leverArms_model);
                        hm = revgnss.MeasurementModel.modelRangeOnly( ...
                            cfg, towers, ti, ai, rm, euler_est, leverArms_model);
                        H_phi(mi, stateMap.r_idx(ki)) = (hp - hm) / (2*step_r);
                    end
                else
                    % Analytic unit vector (pure geometry, no range corrections)
                    H_phi(mi, stateMap.r_idx) = (delta_e / rho_e_geom)';
                end

                % ---- H: clock, ambiguity, ZWD (always analytic) ---------------
                H_phi(mi, stateMap.b_rx_idx) = 1;

                if isfield(stateMap,'towerClockIdx') && ...
                        ti <= size(stateMap.towerClockIdx,1) && ...
                        stateMap.towerClockIdx(ti,1) > 0
                    H_phi(mi, stateMap.towerClockIdx(ti,1)) = -1;
                end

                if isfield(stateMap,'ambiguityIdx') && ...
                        ti <= size(stateMap.ambiguityIdx,1) && ...
                        sigIdx <= size(stateMap.ambiguityIdx,2) && ...
                        stateMap.ambiguityIdx(ti,sigIdx) > 0
                    H_phi(mi, stateMap.ambiguityIdx(ti,sigIdx)) = 1;
                end

                % ZWD column: +mf (same sign for carrier and code)
                if isfield(stateMap,'zwdIdx') && ...
                        ti <= numel(stateMap.zwdIdx) && stateMap.zwdIdx(ti) > 0
                    mf = revgnss.MappingFunctions.troposphere(elv, ...
                        revgnss.MeasurementModel.zwdMappingKind(cfg));
                    H_phi(mi, stateMap.zwdIdx(ti)) = mf;
                end
            end
        end

    end  % Static methods
end
