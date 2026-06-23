classdef CodeMeasurementBuilder
    % CodeMeasurementBuilder  Builds pseudorange EKF rows (z, h, R).
    %
    % Extracted from MeasurementModel.computeMeasurements (Stage 12A Step 4).
    % Covers: single-signal pseudorange loop, multi-signal expansion,
    % ionosphere-free IF combination, and correlated noise application.
    % All physics are preserved exactly — pure structural refactor.

    methods (Static)

        function [z, h, R, errStruct, twr_list, ant_list, M, N_sig] = build( ...
                cfg, errorChain, rngCorr, asset, towers, ...
                twr_list, ant_list, elv_list, leverArms, leverArms_model, ...
                r_ants_truth, r_ants_est, x_est, stateMap, ...
                towerClkTruth, towerClkModel, towerClkSigma, towerClkMode, t_prod, ...
                errStruct, t_s)
            % build  Build pseudorange measurement rows [z, h, R] and updated errStruct.
            %
            % Handles single-frequency, multi-frequency, and ionosphere-free combination.
            % Returns updated twr_list/ant_list/M/N_sig (may differ from input for multi-sig).

            M  = numel(twr_list);

            r_cm_true = asset.r_ecef_m;
            euler_true = asset.attitude_euler_rad;
            b_rx_true = asset.clock.getBiasMeters();

            r_est     = x_est(stateMap.r_idx);
            euler_est = x_est(stateMap.euler_idx);
            b_rx_est  = x_est(stateMap.b_rx_idx);

            sigmaFloor = cfg.measurement.sigmaFloor_m;

            % ----- Build z, h, R_diag (single-signal pseudoranges) --------
            z      = zeros(M,1);
            h      = zeros(M,1);
            R_diag = zeros(M,1);

            sagnacTruth_m  = zeros(M,1);
            sagnacModel_m  = zeros(M,1);
            shapiroTruth_m = zeros(M,1);
            shapiroModel_m = zeros(M,1);
            pcvTruth_m     = zeros(M,1);
            pcvModel_m     = zeros(M,1);
            towerSurveyTruth_m  = zeros(M,1);
            towerSurveyModel_m  = zeros(M,1);
            receiverPCOTruth_m  = zeros(M,1);
            receiverPCOModel_m  = zeros(M,1);
            towerPCOTruth_m     = zeros(M,1);
            towerPCOModel_m     = zeros(M,1);
            lightTimeTruth_s    = zeros(M,1);
            lightTimeModel_s    = zeros(M,1);
            transmitTimeTruth_s = NaN(M,1);
            transmitTimeModel_s = NaN(M,1);

            for mi = 1:M
                ti  = twr_list(mi);
                ai  = ant_list(mi);
                elv = elv_list(mi);

                % Nominal tower position (no survey, no PCO) for contribution baseline
                r_twr_nom = towers{ti}.getAntennaPositionECEF();

                % Stage 2: truth and model tower positions (survey error only, no PCO yet)
                r_twr_survey_truth = revgnss.MeasurementModelUtils.towerPositionEcef(cfg, towers{ti}, ti, 'truth');
                r_twr_survey_model = revgnss.MeasurementModelUtils.towerPositionEcef(cfg, towers{ti}, ti, 'model');

                % Tower survey range contribution (truth-model mismatch in range domain)
                towerSurveyTruth_m(mi) = norm(r_ants_truth(:,ai) - r_twr_survey_truth) - ...
                                         norm(r_ants_truth(:,ai) - r_twr_nom);
                towerSurveyModel_m(mi) = norm(r_ants_est(:,ai)   - r_twr_survey_model) - ...
                                         norm(r_ants_est(:,ai)   - r_twr_nom);

                % Start with survey-shifted positions for PCO application
                r_twr_truth = r_twr_survey_truth;
                r_twr_model = r_twr_survey_model;

                % Stage 3: tower PCO on top of survey-shifted position
                if isfield(cfg,'effects') && isfield(cfg.effects,'antennaPCO')
                    pco = cfg.effects.antennaPCO;
                    if isfield(pco,'truth') && pco.truth.enable
                        tOff = pco.towerOffset_enu_m(:);
                        R_ENU = revgnss.GeometryUtils.enu2ecef(towers{ti}.lat_rad, towers{ti}.lon_rad);
                        r_twr_truth = r_twr_truth + R_ENU * tOff;
                    end
                    if isfield(pco,'model') && pco.model.enable
                        tOff = pco.towerOffset_enu_m(:);
                        R_ENU = revgnss.GeometryUtils.enu2ecef(towers{ti}.lat_rad, towers{ti}.lon_rad);
                        r_twr_model = r_twr_model + R_ENU * tOff;
                    end
                end

                % Tower PCO range contribution (before PCO vs after PCO positions)
                towerPCOTruth_m(mi) = norm(r_ants_truth(:,ai) - r_twr_truth) - ...
                                      norm(r_ants_truth(:,ai) - r_twr_survey_truth);
                towerPCOModel_m(mi) = norm(r_ants_est(:,ai)   - r_twr_model) - ...
                                      norm(r_ants_est(:,ai)   - r_twr_survey_model);

                % Receiver PCO range contribution (antenna with vs without PCO offset)
                if isfield(cfg,'effects') && isfield(cfg.effects,'antennaPCO')
                    pco = cfg.effects.antennaPCO;
                    if isfield(pco,'truth') && pco.truth.enable
                        r_ant_no_pco = revgnss.AttitudeKinematics.applyLeverArm( ...
                            r_cm_true, euler_true, leverArms(:,ai));
                        receiverPCOTruth_m(mi) = norm(r_ants_truth(:,ai) - r_twr_truth) - ...
                                                  norm(r_ant_no_pco      - r_twr_truth);
                    end
                    if isfield(pco,'model') && pco.model.enable
                        r_ant_no_pco_est = revgnss.AttitudeKinematics.applyLeverArm( ...
                            r_est, euler_est, leverArms(:,ai));
                        receiverPCOModel_m(mi) = norm(r_ants_est(:,ai)  - r_twr_model) - ...
                                                  norm(r_ant_no_pco_est - r_twr_model);
                    end
                end

                % Truth pseudorange with corrections + toy PCV (Stage 3)
                [rho_true, cTruth] = revgnss.RangeCorrections.correctedPseudorange( ...
                    r_ants_truth(:,ai), r_twr_truth, cfg, 'truth', elv, t_s);
                sagnacTruth_m(mi)  = cTruth.sagnac;
                shapiroTruth_m(mi) = cTruth.shapiro;
                pcvTruth_m(mi)     = cTruth.pcv;
                lightTimeTruth_s(mi) = cTruth.tau_s;
                if ~isempty(cTruth.t_tx_s); transmitTimeTruth_s(mi) = cTruth.t_tx_s; end

                % Stage 7A: transmit-time tower clock for truth side
                b_twr_truth_h = towerClkTruth(mi);
                if ~isempty(cTruth.t_tx_s)
                    tau_truth = t_s - cTruth.t_tx_s;
                    bdot_twr  = towers{ti}.getClockDriftMetersPerSecond();
                    b_twr_truth_h = b_twr_truth_h - bdot_twr * tau_truth;
                end
                z(mi) = rho_true + b_rx_true - b_twr_truth_h + errStruct.truthTotal_m(mi);

                % Predicted pseudorange with corrections
                [rho_est, cModel] = revgnss.RangeCorrections.correctedPseudorange( ...
                    r_ants_est(:,ai), r_twr_model, cfg, 'model', elv, t_s);
                sagnacModel_m(mi)  = cModel.sagnac;
                shapiroModel_m(mi) = cModel.shapiro;
                pcvModel_m(mi)     = cModel.pcv;
                lightTimeModel_s(mi) = cModel.tau_s;
                if ~isempty(cModel.t_tx_s); transmitTimeModel_s(mi) = cModel.t_tx_s; end

                % Stage 7A: transmit-time tower clock for model side
                if ~isempty(cModel.t_tx_s) && ...
                        ~(isfield(stateMap,'towerClockIdx') && ti <= size(stateMap.towerClockIdx,1) && ...
                          stateMap.towerClockIdx(ti,1) > 0)
                    t_tx_model = cModel.t_tx_s;
                    switch towerClkMode
                        case 'product'
                            if isfield(cfg,'towerClock') && ...
                                    isfield(cfg.towerClock,'products') && ...
                                    ti <= numel(cfg.towerClock.products)
                                [b_reev, ~] = revgnss.TowerClockCorrectionProvider.evalProductStruct( ...
                                    cfg, ti, t_tx_model);
                                towerClkModel(mi) = b_reev;
                            end
                        case 'productNoisy'
                            if isfield(cfg,'towerClock') && ...
                                    isfield(cfg.towerClock,'products') && ...
                                    ti <= numel(cfg.towerClock.products)
                                [b_reev, sig_reev] = revgnss.TowerClockCorrectionProvider.evalProductStruct( ...
                                    cfg, ti, t_tx_model);
                                towerClkModel(mi) = b_reev;
                                towerClkSigma(mi) = sig_reev;
                            end
                        case 'truthProduct'
                            [b_p, bd_p] = revgnss.TowerClockCorrectionProvider.clockAtProductEpoch( ...
                                towers{ti}, t_prod);
                            towerClkModel(mi) = b_p + bd_p * (t_tx_model - t_prod);
                    end
                end

                % Tower clock model — use EKF state if estimated, else product
                if isfield(stateMap,'towerClockIdx') && ti <= size(stateMap.towerClockIdx,1) && ...
                        stateMap.towerClockIdx(ti,1) > 0
                    b_twr_h = x_est(stateMap.towerClockIdx(ti,1));
                else
                    b_twr_h = towerClkModel(mi);
                end

                h(mi) = rho_est + b_rx_est - b_twr_h + errStruct.modelTotal_m(mi);

                % ZWD state contribution to predicted pseudorange
                if isfield(stateMap,'zwdIdx') && ti <= numel(stateMap.zwdIdx) && ...
                        stateMap.zwdIdx(ti) > 0
                    mf_h = revgnss.MappingFunctions.troposphere(elv, ...
                        revgnss.MeasurementModelUtils.zwdMappingKind(cfg));
                    h(mi) = h(mi) + mf_h * x_est(stateMap.zwdIdx(ti));
                end

                % Tx code hardware-delay state contribution (+1 sign: delay increases PR)
                if isfield(stateMap,'txCodeBiasIdx') && ti <= numel(stateMap.txCodeBiasIdx) && ...
                        stateMap.txCodeBiasIdx(ti) > 0
                    h(mi) = h(mi) + x_est(stateMap.txCodeBiasIdx(ti));
                end

                % Receiver code hardware-delay model correction
                d_rx_code_h = revgnss.MeasurementModelUtils.rxCodeBiasModel(cfg);
                if d_rx_code_h ~= 0
                    h(mi) = h(mi) + d_rx_code_h;
                end

                sigma_i = sqrt(errStruct.sigmaTotal_m(mi)^2 + towerClkSigma(mi)^2);
                R_diag(mi) = max(sigma_i, sigmaFloor)^2;
            end

            % Attach diagnostics
            errStruct.sagnacTruth_m  = sagnacTruth_m;
            errStruct.sagnacModel_m  = sagnacModel_m;
            errStruct.shapiroTruth_m = shapiroTruth_m;
            errStruct.shapiroModel_m = shapiroModel_m;
            errStruct.pcvTruth_m     = pcvTruth_m;
            errStruct.pcvModel_m     = pcvModel_m;
            errStruct.towerSurveyTruth_m  = towerSurveyTruth_m;
            errStruct.towerSurveyModel_m  = towerSurveyModel_m;
            errStruct.receiverPCOTruth_m  = receiverPCOTruth_m;
            errStruct.receiverPCOModel_m  = receiverPCOModel_m;
            errStruct.towerPCOTruth_m     = towerPCOTruth_m;
            errStruct.towerPCOModel_m     = towerPCOModel_m;
            errStruct.lightTimeTruth_s    = lightTimeTruth_s;
            errStruct.lightTimeModel_s    = lightTimeModel_s;
            errStruct.transmitTimeTruth_s = transmitTimeTruth_s;
            errStruct.transmitTimeModel_s = transmitTimeModel_s;

            % ----- Multi-signal expansion ----------------------------------
            signals = revgnss.SignalUtils.getEnabledSignals(cfg);
            N_sig   = numel(signals);

            % Stage 78: use canonical cfg.signals.frequencyHz (set by finalizeConfig)
            % or SignalDefinition; no hardcoded frequency fallback constant.
            if isfield(cfg,'signals') && isfield(cfg.signals,'frequencyHz') && ...
                    numel(cfg.signals.frequencyHz) >= 1
                f_L1 = cfg.signals.frequencyHz(1);
            else
                f_L1 = revgnss.SignalDefinition.get('L1').frequency_Hz;
            end

            if N_sig > 1
                % NOTE on hardware/code biases (DCB):
                % Signal-dependent hardware delays on L1 and L2 do NOT cancel in the
                % IF combination.  HW_IF = alpha*HW_L1 - beta*HW_L2.
                % In this v1 simulation hardware delays are set to zero (simplified).
                % LIMITATION: DCB calibration is not implemented.
                M_pairs = M;
                M       = M_pairs * N_sig;

                z_new      = zeros(M,1);
                h_new      = zeros(M,1);
                R_diag_new = zeros(M,1);

                flds  = {'code','trop','iono','hwDelay','mp','scintillation'};
                btOut = struct(); bmOut = struct(); bsOut = struct();
                for fi = 1:numel(flds)
                    btOut.(flds{fi}) = zeros(M,1);
                    bmOut.(flds{fi}) = zeros(M,1);
                end
                bsOut.code = zeros(M,1);

                sigIdx   = zeros(M,1);
                sigNames = cell(M,1);
                freqHz   = zeros(M,1);

                scintExpF = 1.0;
                if isfield(cfg,'errors') && isfield(cfg.errors,'ionosphere') && ...
                        isfield(cfg.errors.ionosphere,'scintillation') && ...
                        isfield(cfg.errors.ionosphere.scintillation,'frequencyExponent')
                    scintExpF = cfg.errors.ionosphere.scintillation.frequencyExponent;
                end

                for si = 1:N_sig
                    sigCfg    = signals(si);
                    freqScale = (f_L1 / sigCfg.frequency_Hz)^2;
                    offset    = (si-1) * M_pairs;

                    for pi = 1:M_pairs
                        mi = offset + pi;
                        sigIdx(mi)   = si;
                        sigNames{mi} = sigCfg.name;
                        freqHz(mi)   = sigCfg.frequency_Hz;

                        scintSigL1_pi = errStruct.scintSigmaL1_m(pi);
                        scintSig_si   = scintSigL1_pi * (f_L1 / sigCfg.frequency_Hz)^scintExpF;
                        scint_t       = scintSig_si * randn(errorChain.rngStream, 1, 1);

                        if si == 1
                            z_new(mi)      = z(pi) + scint_t;
                            h_new(mi)      = h(pi);
                            R_diag_new(mi) = R_diag(pi) + scintSig_si^2;
                            for fi = 1:numel(flds)
                                fn = flds{fi};
                                if isfield(errStruct.bySource.truth_m, fn)
                                    btOut.(fn)(mi) = errStruct.bySource.truth_m.(fn)(pi);
                                end
                                if isfield(errStruct.bySource.model_m, fn)
                                    bmOut.(fn)(mi) = errStruct.bySource.model_m.(fn)(pi);
                                end
                            end
                            btOut.scintillation(mi) = scint_t;
                            elv_pi = errStruct.elevations_rad(pi);
                            sigma_code_si = revgnss.MeasurementModelUtils.codeSignalSigma(sigCfg, elv_pi, cfg);
                            bsOut.code(mi) = sigma_code_si;
                        else
                            elv_pi        = errStruct.elevations_rad(pi);
                            sigma_code_si = revgnss.MeasurementModelUtils.codeSignalSigma(sigCfg, elv_pi, cfg);
                            code_t        = sigma_code_si * randn(errorChain.rngStream, 1, 1);

                            iono_t_si = 0; iono_m_si = 0;
                            if isfield(errStruct.bySource.truth_m,'iono')
                                iono_t_si = errStruct.bySource.truth_m.iono(pi) * freqScale;
                            end
                            if isfield(errStruct.bySource.model_m,'iono')
                                iono_m_si = errStruct.bySource.model_m.iono(pi) * freqScale;
                            end

                            trop_t = 0; trop_m = 0; hw_t = 0; hw_m = 0; mp_t = 0;
                            if isfield(errStruct.bySource.truth_m,'trop'),    trop_t = errStruct.bySource.truth_m.trop(pi);    end
                            if isfield(errStruct.bySource.model_m,'trop'),    trop_m = errStruct.bySource.model_m.trop(pi);    end
                            if isfield(errStruct.bySource.truth_m,'hwDelay'), hw_t   = errStruct.bySource.truth_m.hwDelay(pi); end
                            if isfield(errStruct.bySource.model_m,'hwDelay'), hw_m   = errStruct.bySource.model_m.hwDelay(pi); end
                            if isfield(errStruct.bySource.truth_m,'mp'),      mp_t   = errStruct.bySource.truth_m.mp(pi);      end

                            % Geometry + clocks (strips L1 error terms from Phase-1 z/h)
                            z_geom_pi = z(pi) - errStruct.truthTotal_m(pi);
                            h_geom_pi = h(pi) - errStruct.modelTotal_m(pi);

                            z_new(mi) = z_geom_pi + trop_t + iono_t_si + hw_t + mp_t + code_t + scint_t;
                            h_new(mi) = h_geom_pi + trop_m + iono_m_si + hw_m;

                            sigma_extra_pi = errStruct.sigmaExtra_m(pi);
                            R_diag_new(mi) = max(sigma_code_si, sigmaFloor)^2 + ...
                                             scintSig_si^2 + sigma_extra_pi^2 + towerClkSigma(pi)^2;

                            btOut.trop(mi)          = trop_t;
                            bmOut.trop(mi)          = trop_m;
                            btOut.iono(mi)          = iono_t_si;
                            bmOut.iono(mi)          = iono_m_si;
                            btOut.hwDelay(mi)       = hw_t;
                            bmOut.hwDelay(mi)       = hw_m;
                            btOut.mp(mi)            = mp_t;
                            btOut.code(mi)          = code_t;
                            btOut.scintillation(mi) = scint_t;
                            bsOut.code(mi)          = sigma_code_si;
                        end
                    end
                end

                z        = z_new;
                h        = h_new;
                R_diag   = R_diag_new;
                twr_list = repmat(twr_list, N_sig, 1);
                ant_list = repmat(ant_list, N_sig, 1);

                errStruct.bySource.truth_m = btOut;
                errStruct.bySource.model_m = bmOut;

                % Tile non-code sigma fields; override code sigma with signal-specific
                sigFlds = fieldnames(errStruct.bySource.sigma_m);
                for fi2 = 1:numel(sigFlds)
                    fn = sigFlds{fi2};
                    if ~isempty(errStruct.bySource.sigma_m.(fn))
                        errStruct.bySource.sigma_m.(fn) = repmat(errStruct.bySource.sigma_m.(fn)(:), N_sig, 1);
                    end
                end
                errStruct.bySource.sigma_m.code = bsOut.code;

                % Tile scalar errStruct arrays
                tileFields = {'towerClockTruth_m','towerClockModel_m','towerClockModelSigma_m', ...
                              'sagnacTruth_m','sagnacModel_m','shapiroTruth_m','shapiroModel_m', ...
                              'pcvTruth_m','pcvModel_m','towerSurveyTruth_m','towerSurveyModel_m', ...
                              'receiverPCOTruth_m','receiverPCOModel_m','towerPCOTruth_m','towerPCOModel_m', ...
                              'elevations_rad','scintSigmaL1_m','sigmaExtra_m','sigmaTotal_m'};
                for fi2 = 1:numel(tileFields)
                    fn = tileFields{fi2};
                    if isfield(errStruct, fn) && ~isempty(errStruct.(fn))
                        errStruct.(fn) = repmat(errStruct.(fn)(:), N_sig, 1);
                    end
                end

                errStruct.towerIdx_perMeas   = twr_list;
                errStruct.antennaIdx_perMeas = ant_list;
                errStruct.nPseudorange       = M;

                % Rebuild truthTotal and modelTotal at M level
                errStruct.truthTotal_m = zeros(M,1);
                errStruct.modelTotal_m = zeros(M,1);
                for fi2 = 1:numel(flds)
                    fn = flds{fi2};
                    errStruct.truthTotal_m = errStruct.truthTotal_m + btOut.(fn);
                    if isfield(bmOut, fn)
                        errStruct.modelTotal_m = errStruct.modelTotal_m + bmOut.(fn);
                    end
                end

                errStruct.signalIdx_perMeas   = sigIdx;
                errStruct.signalName_perMeas  = sigNames;
                errStruct.frequencyHz_perMeas = freqHz;
            else
                % Single frequency: add signal metadata, keep everything else unchanged
                errStruct.signalIdx_perMeas   = ones(M,1);
                errStruct.signalName_perMeas  = repmat({'L1'}, M, 1);
                if isfield(cfg,'signals') && isfield(cfg.signals,'L1')
                    errStruct.frequencyHz_perMeas = ...
                        cfg.signals.L1.frequency_Hz * ones(M,1);
                else
                    errStruct.frequencyHz_perMeas = f_L1 * ones(M,1);
                end

                % Add scintillation to bySource (L1 only)
                if isfield(errStruct,'scintSigmaL1_m') && any(errStruct.scintSigmaL1_m > 0)
                    scintTruth = errStruct.scintSigmaL1_m .* randn(errorChain.rngStream, M, 1);
                    z = z + scintTruth;
                    errStruct.bySource.truth_m.scintillation = scintTruth;
                    errStruct.bySource.model_m.scintillation = zeros(M,1);
                    R_diag = R_diag + errStruct.scintSigmaL1_m.^2;
                else
                    errStruct.bySource.truth_m.scintillation = zeros(M,1);
                    errStruct.bySource.model_m.scintillation = zeros(M,1);
                end
            end

            % ----- IF combination (ionosphereFree codeMode) ---------------
            % When codeMode='ionosphereFree' and N_sig==2: combine stacked L1+L2
            % rows into M_pairs IF rows.
            codeMode_v = '';
            if isfield(cfg,'measurements') && isfield(cfg.measurements,'codeMode')
                codeMode_v = cfg.measurements.codeMode;
            end
            % Stage 45: ionosphereFreeRows toggle maps to existing codeMode path.
            if isempty(codeMode_v) && N_sig == 2
                try
                    ifEnable = cfg.measurements.code.ionosphereFreeRows.enable;
                    ifInEkf  = cfg.measurements.code.ionosphereFreeRows.useInEkf;
                    if ifEnable && ifInEkf; codeMode_v = 'ionosphereFree'; end
                catch; end
            end
            M_pairs_if = round(M / max(N_sig, 1));
            if strcmp(codeMode_v,'ionosphereFree') && N_sig == 2 && M == M_pairs_if * 2
                signals_if = revgnss.SignalUtils.getEnabledSignals(cfg);
                f_L2_if    = signals_if(2).frequency_Hz;
                [alpha_if, beta_if] = revgnss.IonoFreeCombination.coefficients(f_L1, f_L2_if);

                idx1 = 1:M_pairs_if;
                idx2 = M_pairs_if+1 : 2*M_pairs_if;

                z_if    = alpha_if * z(idx1)         + beta_if * z(idx2);
                h_if    = alpha_if * h(idx1)         + beta_if * h(idx2);
                R_if    = alpha_if^2 * R_diag(idx1)  + beta_if^2 * R_diag(idx2);

                z = z_if;
                h = h_if;
                R_diag   = R_if;
                twr_list = twr_list(idx1);
                ant_list = ant_list(idx1);
                M        = M_pairs_if;
                N_sig    = 1;

                % Compress errStruct per-row fields to M_pairs IF rows
                ifTileFields = {'towerClockTruth_m','towerClockModel_m','towerClockModelSigma_m', ...
                    'sagnacTruth_m','sagnacModel_m','shapiroTruth_m','shapiroModel_m', ...
                    'pcvTruth_m','pcvModel_m','towerSurveyTruth_m','towerSurveyModel_m', ...
                    'receiverPCOTruth_m','receiverPCOModel_m','towerPCOTruth_m','towerPCOModel_m', ...
                    'elevations_rad','scintSigmaL1_m','sigmaExtra_m','sigmaTotal_m', ...
                    'truthTotal_m','modelTotal_m','signalIdx_perMeas','frequencyHz_perMeas'};
                for fi3 = 1:numel(ifTileFields)
                    fn = ifTileFields{fi3};
                    if isfield(errStruct,fn) && numel(errStruct.(fn)) >= M_pairs_if
                        errStruct.(fn) = errStruct.(fn)(idx1);
                    end
                end
                if isfield(errStruct,'signalName_perMeas') && numel(errStruct.signalName_perMeas) >= M_pairs_if
                    errStruct.signalName_perMeas = repmat({'IF'}, M_pairs_if, 1);
                end
                errStruct.towerIdx_perMeas   = twr_list;
                errStruct.antennaIdx_perMeas = ant_list;
                errStruct.nPseudorange       = M;
                errStruct.ifCombination      = true;
            end

            % ----- Correlated noise + full R matrix -----------------------
            [z, R, correlNoise] = revgnss.MeasurementModelUtils.correlatedNoise( ...
                cfg, rngCorr, z, R_diag, twr_list, M);
            errStruct.correlatedNoise = correlNoise;

            % Stage 74: block covariance for shared tower clock product errors.
            % The same tower clock product error is common to all code rows that
            % reference the same tower at the same product epoch.  Treating it as
            % independent (diagonal-only) makes the EKF too confident.
            % Fix: R_ij += sigma_twr^2 for all (i,j) pairs from the same tower
            % (i != j only — diagonal already contains sigma_twr^2 from R_diag).
            % Result: R = diag(sigma_tracking^2) + sum_t(sigma_t^2 * ones(k_t))
            % which is symmetric positive definite whenever all sigma_tracking > 0.
            sharedErrEnable_ = false;
            sharedErrCode_   = false;
            try
                sharedErrEnable_ = cfg.covariance.sharedErrors.enable;
                sharedErrCode_   = cfg.covariance.sharedErrors.applyTowerClockToCode;
            catch; end
            cbc_.applied     = false;
            cbc_.nBlocks     = 0;
            cbc_.blockSizes  = zeros(0,1);
            cbc_.jitterAdded = false;
            cbc_.spd         = true;
            if sharedErrEnable_ && sharedErrCode_
                jitter_m2_ = 1e-12;
                try; jitter_m2_ = cfg.covariance.sharedErrors.jitter_m2; catch; end
                % Per-row tower clock sigma after multi-signal expansion
                sigTwr_ = zeros(M,1);
                if isfield(errStruct,'towerClockModelSigma_m') && ...
                        numel(errStruct.towerClockModelSigma_m) == M
                    sigTwr_ = errStruct.towerClockModelSigma_m;
                end
                uniqT_ = unique(twr_list);
                for kt_ = 1:numel(uniqT_)
                    idx_ = find(twr_list == uniqT_(kt_));
                    if numel(idx_) < 2; continue; end
                    sig_t_ = mean(sigTwr_(idx_));
                    if sig_t_ <= 0; continue; end
                    % Off-diagonal only: diagonal already has sigma_twr^2 in R_diag
                    cov_add_ = sig_t_^2 * (ones(numel(idx_)) - eye(numel(idx_)));
                    R(idx_,idx_) = R(idx_,idx_) + cov_add_;
                    cbc_.nBlocks = cbc_.nBlocks + 1;
                    cbc_.blockSizes(end+1) = numel(idx_);
                end
                % SPD guard (should never trigger for sigma_tracking > 0)
                [~, pfail_] = chol(R);
                if pfail_ ~= 0
                    R = R + jitter_m2_ * eye(size(R,1));
                    cbc_.jitterAdded = true;
                    [~, pfail2_] = chol(R);
                    cbc_.spd = (pfail2_ == 0);
                end
                cbc_.applied = true;
            end
            errStruct.codeBlockCov = cbc_;

            % R validity guard
            rDiag = diag(R);
            if any(~isfinite(rDiag)) || any(rDiag <= 0)
                nBad = sum(~isfinite(rDiag) | rDiag <= 0);
                error('MeasurementModel:invalidR', ...
                    ['R has %d invalid diagonal values (NaN/Inf/<=0). ' ...
                     'Check cfg.errors.codeNoise.sigma_m, cfg.effects, and cfg.errors toggles.'], nBad);
            end
        end

    end  % Static methods
end
