classdef MeasurementModel < handle
    % MeasurementModel  Pseudorange measurement equations for reverse-GNSS.
    %
    % Responsibilities:
    %   - Compute truth pseudorange z from truth state + ErrorChain + effects
    %   - Compute predicted pseudorange h from estimated state
    %   - Compute measurement Jacobian H (analytic or finite-difference)
    %   - Compute visibility mask (elevation filter)
    %   - Assemble measurement covariance R (diagonal or correlated)
    %
    % -----------------------------------------------------------------------
    % TRUTH/MODEL SEPARATION
    %
    % Truth measurement:
    %   z_i = rho_ant_true_i + b_rx_true - b_twr_true_i + eps_chain_i
    %         + truth-side corrections (Sagnac, Shapiro, PCO, PCV, survey)
    %
    % Predicted measurement:
    %   h_i = rho_ant_est_i  + b_rx_est  - b_twr_model_i + model_chain_i
    %         + model-side corrections
    %
    % Truth effects affect z only; model effects affect h (and H via FD when enabled).
    % If truth=true and model=false, innovation shows the mismatch deterministically.
    %
    % Tower clock corrections are computed ONCE per epoch (at the start of
    % computeMeasurements) and stored in errStruct to prevent repeated noise draws.
    %
    % -----------------------------------------------------------------------
    % JACOBIAN
    %   Default (no corrections): analytic  H(r_idx) = u'
    %   Any model-side correction on: finite-difference H(r_idx) and H(euler_idx)
    %   cfg.estimator.forceFiniteDifferenceH = true: always use FD
    %   Clock columns: b_rx = +1, tower clock = -1 (always analytic)
    %   Doppler columns: H_v = u', H_bdot = 1 (always analytic)

    properties
        cfg             (1,1) struct
        errorChain      revgnss.ErrorChain
        elevMask_rad    (1,1) double = 5 * pi/180
        attitudeJacStep_rad (1,1) double = 1e-6
        ambiguityMap                       % containers.Map: (tower*1000+antenna) → integer N (diagnostic)
        floatAmbiguityTruth_m              % containers.Map: (tower*1000+ant) → float B_phi [m] (ekfFloat)
        rngCorr                            % RandStream for correlated noise (Stage 4)
    end

    methods
        function obj = MeasurementModel(cfg, errorChain)
            if nargin == 0; return; end
            obj.cfg          = cfg;
            obj.errorChain   = errorChain;
            obj.ambiguityMap = [];
            if isfield(cfg,'elevationMask_rad')
                obj.elevMask_rad = cfg.elevationMask_rad;
            end
            if isfield(cfg.estimator,'attitudeJacobianStep_rad')
                obj.attitudeJacStep_rad = cfg.estimator.attitudeJacobianStep_rad;
            end
            % Stage 4: correlated noise RNG
            if isfield(cfg,'effects') && isfield(cfg.effects,'correlatedNoise') && ...
                    isfield(cfg.effects.correlatedNoise,'seed')
                obj.rngCorr = RandStream('mt19937ar','Seed', cfg.effects.correlatedNoise.seed);
            end
        end

        % ----------------------------------------------------------------
        function [visible, elevations_rad] = computeVisibility(obj, towers, r_ant_ecef_m)
            % computeVisibility  Return logical mask and elevation angles.
            N = numel(towers);
            elevations_rad = zeros(N,1);
            for k = 1:N
                elevations_rad(k) = revgnss.GeometryUtils.elevationAngle( ...
                    towers{k}.r_ecef_m, r_ant_ecef_m);
            end
            visible = elevations_rad >= obj.elevMask_rad;
        end

        % ----------------------------------------------------------------
        function [z, h, H, R, errStruct] = computeMeasurements(obj, ...
                asset, towers, x_est, t_s, stateMap)
            % computeMeasurements  Main measurement function (multi-antenna capable).
            %
            % Loops over all visible (tower, antenna) pairs.  Default config has
            % N_ant=1 with a zero lever arm, recovering the single-antenna case.

            % ----- All lever arms (3 x N_ant) --------------------------
            leverArms = asset.receiverLeverArms_body_m;
            N_ant = size(leverArms, 2);

            % ----- Truth state -----------------------------------------
            r_cm_true  = asset.r_ecef_m;
            euler_true = asset.attitude_euler_rad;
            b_rx_true  = asset.clock.getBiasMeters();

            % ----- EKF state extraction --------------------------------
            r_est     = x_est(stateMap.r_idx);
            euler_est = x_est(stateMap.euler_idx);
            b_rx_est  = x_est(stateMap.b_rx_idx);

            % ----- Effective lever arms with PCO offset ----------------
            % Stage 3: receiverOffset_body_m is extra common body-frame offset
            % added to all antennas on truth/model side independently.
            leverArms_truth = leverArms;
            leverArms_model = leverArms;
            if isfield(obj.cfg,'effects') && isfield(obj.cfg.effects,'antennaPCO')
                pco = obj.cfg.effects.antennaPCO;
                if isfield(pco,'truth') && pco.truth.enable
                    off = pco.receiverOffset_body_m(:);
                    leverArms_truth = leverArms + off * ones(1, N_ant);
                end
                if isfield(pco,'model') && pco.model.enable
                    off = pco.receiverOffset_body_m(:);
                    leverArms_model = leverArms + off * ones(1, N_ant);
                end
            end

            % ----- Truth and estimated antenna positions ---------------
            r_ants_truth = asset.getAntennaPositionsECEF(r_cm_true, euler_true, leverArms_truth);
            r_ants_est   = asset.getAntennaPositionsECEF(r_est,     euler_est,  leverArms_model);

            nx    = numel(x_est);
            N_twr = numel(towers);

            % ----- Build (tower, antenna) pair visibility list ---------
            twr_list = zeros(N_twr * N_ant, 1);
            ant_list = zeros(N_twr * N_ant, 1);
            elv_list = zeros(N_twr * N_ant, 1);
            cnt = 0;
            for ti = 1:N_twr
                r_twr_nom = towers{ti}.getAntennaPositionECEF();
                for ai = 1:N_ant
                    elv = revgnss.GeometryUtils.elevationAngle(r_twr_nom, r_ants_truth(:,ai));
                    if elv >= obj.elevMask_rad
                        cnt = cnt + 1;
                        twr_list(cnt) = ti;
                        ant_list(cnt) = ai;
                        elv_list(cnt) = elv;
                    end
                end
            end
            twr_list = twr_list(1:cnt);
            ant_list = ant_list(1:cnt);
            elv_list = elv_list(1:cnt);
            M = cnt;

            if M == 0
                z = []; h = []; H = zeros(0,nx); R = []; errStruct = [];
                return
            end

            % ----- Error chain (per measurement) -----------------------
            towerIds = arrayfun(@(ti) towers{ti}.id, twr_list);
            errStruct = obj.errorChain.compute(elv_list, towerIds, twr_list, t_s);

            % ----- Tower clock corrections — generated ONCE per epoch --
            towerClkMode  = obj.getTowerClockMode_();
            towerClkTruth = zeros(M,1);
            towerClkModel = zeros(M,1);
            towerClkSigma = zeros(M,1);

            noiseSigma = obj.cfg.estimator.towerClockCorrectionSigma_m;
            if isfield(obj.cfg,'towerClockCorrectionSigma_m')
                noiseSigma = obj.cfg.towerClockCorrectionSigma_m;
            end
            if strcmp(towerClkMode,'noisyCorrection')
                % CHANGED: v3→v4 — Issue 5
                % SIMULATION NOTE: noisyCorrection is a truth-based simulated external
                % correction product.  It is NOT a model of what a real receiver
                % produces; it adds zero-mean Gaussian noise to the true tower clock.
                % Use for Monte Carlo bias/sigma studies only.
                % predictedProduct is the more realistic product model.
                corrNoise_m = noiseSigma * obj.errorChain.drawNormal(M, 1);
            else
                corrNoise_m = zeros(M,1);
            end

            % TASK 6: Product epoch computed ONCE before measurement loop so
            % 'product' and 'productNoisy' modes can evaluate b_hat(t_s) =
            % b(t_prod) + bdot(t_prod) * (t_s - t_prod) per tower.
            updateInterval_s = 300;
            latency_s        = 0;
            if isfield(obj.cfg,'errors') && isfield(obj.cfg.errors,'towerClock')
                tc2 = obj.cfg.errors.towerClock;
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
                switch towerClkMode
                    case 'none'
                        % No correction. EKF must estimate or accept clock bias as error.
                        towerClkModel(mi) = 0;
                    case 'perfectCorrection'
                        % Validation/test use only. Uses truth clock directly.
                        towerClkModel(mi) = b_t;
                    case 'noisyCorrection'
                        % Truth-based simulated correction + Gaussian noise (truthHistoryProductNoisy).
                        towerClkModel(mi) = b_t + corrNoise_m(mi);
                        towerClkSigma(mi) = noiseSigma;
                    case 'truthProduct'
                        % Stage 7A: truthHistoryProduct — history-based linear prediction.
                        % Does NOT require cfg.towerClock.products struct.
                        [b_p, bd_p] = obj.getClockAtProductEpoch_(towers{ti}, t_prod);
                        towerClkModel(mi) = b_p + bd_p * (t_s - t_prod);
                    case 'product'
                        % Stage 7A: explicit cfg.towerClock.products struct REQUIRED.
                        % NO fallback to truth history. Throws if struct is missing.
                        hasProd = isfield(obj.cfg,'towerClock') && ...
                                  isfield(obj.cfg.towerClock,'products') && ...
                                  ti <= numel(obj.cfg.towerClock.products);
                        if ~hasProd
                            nProd = 0;
                            if isfield(obj.cfg,'towerClock') && isfield(obj.cfg.towerClock,'products')
                                nProd = numel(obj.cfg.towerClock.products);
                            end
                            error('MeasurementModel:productStructMissing', ...
                                ['correctionMode=''product'' requires cfg.towerClock.products(%d) ' ...
                                 'to be set. Found only %d product struct(s). ' ...
                                 'Use correctionMode=''truthHistoryProduct'' for history-based mode.'], ...
                                ti, nProd);
                        end
                        [b_hat, ~] = obj.evalProductStruct_(ti, t_s);
                        towerClkModel(mi) = b_hat;
                    case 'productNoisy'
                        % Stage 7A: explicit struct REQUIRED + uncertainty added to R.
                        % NO fallback to truth history. Throws if struct is missing.
                        hasProd = isfield(obj.cfg,'towerClock') && ...
                                  isfield(obj.cfg.towerClock,'products') && ...
                                  ti <= numel(obj.cfg.towerClock.products);
                        if ~hasProd
                            nProd = 0;
                            if isfield(obj.cfg,'towerClock') && isfield(obj.cfg.towerClock,'products')
                                nProd = numel(obj.cfg.towerClock.products);
                            end
                            error('MeasurementModel:productStructMissing', ...
                                ['correctionMode=''productNoisy'' requires cfg.towerClock.products(%d) ' ...
                                 'to be set. Found only %d product struct(s). ' ...
                                 'Use correctionMode=''truthHistoryProductNoisy'' for history-based mode.'], ...
                                ti, nProd);
                        end
                        [b_hat, sig_corr] = obj.evalProductStruct_(ti, t_s);
                        towerClkModel(mi) = b_hat;
                        towerClkSigma(mi) = sig_corr;
                    otherwise
                        towerClkModel(mi) = 0;
                end
            end

            errStruct.towerClockTruth_m      = towerClkTruth;
            errStruct.towerClockModel_m      = towerClkModel;
            errStruct.towerClockModelSigma_m = towerClkSigma;
            errStruct.towerIdx_perMeas       = twr_list;
            errStruct.antennaIdx_perMeas     = ant_list;
            errStruct.nPseudorange           = M;   % 0.4: for postfit split

            % CHANGED: v3→v4 — Issue 6: extended product correction cache.
            % Postfit recomputation must reuse exactly these values (not re-query or re-draw).
            errStruct.towerClockCorrection_m      = towerClkModel;    % correction applied
            errStruct.towerClockCorrectionSigma_m = towerClkSigma;    % sigma used in R
            errStruct.towerClockCorrNoise_m       = corrNoise_m;      % noise realization

            errStruct.towerClockProductEpoch_s = t_prod;
            errStruct.towerClockProductAge_s   = t_s - t_prod;

            % ----- Build z, h, R_diag ----------------------------------
            z      = zeros(M,1);
            h      = zeros(M,1);
            R_diag = zeros(M,1);

            sigmaFloor = obj.cfg.measurement.sigmaFloor_m;

            sagnacTruth_m  = zeros(M,1);
            sagnacModel_m  = zeros(M,1);
            shapiroTruth_m = zeros(M,1);
            shapiroModel_m = zeros(M,1);
            pcvTruth_m     = zeros(M,1);
            pcvModel_m     = zeros(M,1);
            % Contribution arrays for diagnostics (first-order range difference per effect)
            towerSurveyTruth_m  = zeros(M,1);
            towerSurveyModel_m  = zeros(M,1);
            receiverPCOTruth_m  = zeros(M,1);
            receiverPCOModel_m  = zeros(M,1);
            towerPCOTruth_m     = zeros(M,1);
            towerPCOModel_m     = zeros(M,1);

            for mi = 1:M
                ti  = twr_list(mi);
                ai  = ant_list(mi);
                elv = elv_list(mi);

                % Nominal tower position (no survey, no PCO) for contribution baseline
                r_twr_nom = towers{ti}.getAntennaPositionECEF();

                % Stage 2: truth and model tower positions (survey error only, no PCO yet)
                r_twr_survey_truth = obj.getTowerPosition_(towers{ti}, ti, 'truth');
                r_twr_survey_model = obj.getTowerPosition_(towers{ti}, ti, 'model');

                % Tower survey range contribution (truth-model mismatch in range domain)
                towerSurveyTruth_m(mi) = norm(r_ants_truth(:,ai) - r_twr_survey_truth) - ...
                                         norm(r_ants_truth(:,ai) - r_twr_nom);
                towerSurveyModel_m(mi) = norm(r_ants_est(:,ai)   - r_twr_survey_model) - ...
                                         norm(r_ants_est(:,ai)   - r_twr_nom);

                % Start with survey-shifted positions for PCO application
                r_twr_truth = r_twr_survey_truth;
                r_twr_model = r_twr_survey_model;

                % Stage 3: tower PCO on top of survey-shifted position
                if isfield(obj.cfg,'effects') && isfield(obj.cfg.effects,'antennaPCO')
                    pco = obj.cfg.effects.antennaPCO;
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
                if isfield(obj.cfg,'effects') && isfield(obj.cfg.effects,'antennaPCO')
                    pco = obj.cfg.effects.antennaPCO;
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
                % Stage 7A.1: pass t_s so t_tx_s = t_s - tau_s is an absolute epoch.
                [rho_true, cTruth] = revgnss.RangeCorrections.correctedPseudorange( ...
                    r_ants_truth(:,ai), r_twr_truth, obj.cfg, 'truth', elv, t_s);
                sagnacTruth_m(mi)  = cTruth.sagnac;
                shapiroTruth_m(mi) = cTruth.shapiro;
                pcvTruth_m(mi)     = cTruth.pcv;

                % Stage 7A: transmit-time tower clock for truth side.
                % When iterative light-time is active, the tower clock should be
                % evaluated at t_tx = t_rx - tau, not at t_rx.
                % Use first-order approximation: b(t_tx) ≈ b(t_rx) - bdot * tau.
                b_twr_truth_h = towerClkTruth(mi);
                if ~isempty(cTruth.t_tx_s)
                    tau_truth = t_s - cTruth.t_tx_s;
                    bdot_twr  = towers{ti}.clock.getClockDriftMetersPerSecond();
                    b_twr_truth_h = b_twr_truth_h - bdot_twr * tau_truth;
                end
                z(mi) = rho_true + b_rx_true - b_twr_truth_h + errStruct.truthTotal_m(mi);

                % Predicted pseudorange with corrections + toy PCV
                % Stage 7A.1: pass t_s so t_tx_s is an absolute epoch for product re-eval.
                [rho_est, cModel] = revgnss.RangeCorrections.correctedPseudorange( ...
                    r_ants_est(:,ai), r_twr_model, obj.cfg, 'model', elv, t_s);
                sagnacModel_m(mi)  = cModel.sagnac;
                shapiroModel_m(mi) = cModel.shapiro;
                pcvModel_m(mi)     = cModel.pcv;

                % Stage 7A: transmit-time tower clock for model side.
                % If iterative light-time is active, re-evaluate product at t_tx_s.
                % If EKF estimates the clock, the EKF state is used (no re-evaluation).
                if ~isempty(cModel.t_tx_s) && ...
                        ~(isfield(stateMap,'towerClockIdx') && ti <= size(stateMap.towerClockIdx,1) && ...
                          stateMap.towerClockIdx(ti,1) > 0)
                    % Re-evaluate tower clock at transmit time for product modes.
                    t_tx_model = cModel.t_tx_s;
                    switch towerClkMode
                        case 'product'
                            if isfield(obj.cfg,'towerClock') && ...
                                    isfield(obj.cfg.towerClock,'products') && ...
                                    ti <= numel(obj.cfg.towerClock.products)
                                [b_reev, ~] = obj.evalProductStruct_(ti, t_tx_model);
                                towerClkModel(mi) = b_reev;
                            end
                        case 'productNoisy'
                            if isfield(obj.cfg,'towerClock') && ...
                                    isfield(obj.cfg.towerClock,'products') && ...
                                    ti <= numel(obj.cfg.towerClock.products)
                                [b_reev, sig_reev] = obj.evalProductStruct_(ti, t_tx_model);
                                towerClkModel(mi) = b_reev;
                                towerClkSigma(mi) = sig_reev;  % R epoch-consistent with bias
                            end
                        case 'truthProduct'
                            [b_p, bd_p] = obj.getClockAtProductEpoch_(towers{ti}, t_prod);
                            towerClkModel(mi) = b_p + bd_p * (t_tx_model - t_prod);
                    end
                end

                % Tower clock model — use EKF state if estimated, else product.
                if isfield(stateMap,'towerClockIdx') && ti <= size(stateMap.towerClockIdx,1) && ...
                        stateMap.towerClockIdx(ti,1) > 0
                    b_twr_h = x_est(stateMap.towerClockIdx(ti,1));
                else
                    b_twr_h = towerClkModel(mi);
                end

                h(mi) = rho_est + b_rx_est - b_twr_h + errStruct.modelTotal_m(mi);

                % TASK 2: ZWD state contribution to predicted pseudorange
                if isfield(stateMap,'zwdIdx') && ti <= numel(stateMap.zwdIdx) && ...
                        stateMap.zwdIdx(ti) > 0
                    mf_h = revgnss.MappingFunctions.troposphere(elv, obj.zwdMappingKind_());
                    h(mi) = h(mi) + mf_h * x_est(stateMap.zwdIdx(ti));
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

            % ----- Direct tower × antenna × signal measurement generation -----
            signals = revgnss.SignalUtils.getEnabledSignals(obj.cfg);
            N_sig   = numel(signals);

            f_L1 = 1575.42e6;
            if isfield(obj.cfg,'signals') && isfield(obj.cfg.signals,'L1') && ...
                    isfield(obj.cfg.signals.L1,'frequency_Hz')
                f_L1 = obj.cfg.signals.L1.frequency_Hz;
            end

            if N_sig > 1
                % CHANGED: v3→v4 — Issue 9
                % NOTE on hardware/code biases (DCB):
                % Signal-dependent hardware delays on L1 and L2 do NOT cancel in the
                % IF combination.  HW_IF = alpha*HW_L1 - beta*HW_L2.
                % In this v1 simulation hardware delays are set to zero (simplified).
                % LIMITATION: DCB calibration is not implemented.  In a real receiver
                % or precise point positioning system, DCBs must be estimated or
                % corrected using IGS DCB products (see Schaer 1999, Montenbruck 2014).
                %
                % Phase 2: build z/h/R directly for each (signal, pair)
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
                if isfield(obj.cfg,'errors') && isfield(obj.cfg.errors,'ionosphere') && ...
                        isfield(obj.cfg.errors.ionosphere,'scintillation') && ...
                        isfield(obj.cfg.errors.ionosphere.scintillation,'frequencyExponent')
                    scintExpF = obj.cfg.errors.ionosphere.scintillation.frequencyExponent;
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
                        scint_t       = scintSig_si * randn(obj.errorChain.rngStream, 1, 1);

                        if si == 1
                            % L1: copy Phase-1 z/h/R, add scintillation
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
                            sigma_code_si = obj.computeCodeSigmaForSignal_(sigCfg, elv_pi, obj.cfg);
                            bsOut.code(mi) = sigma_code_si;
                        else
                            % L2+: compute from geometry base + per-signal errors
                            elv_pi        = errStruct.elevations_rad(pi);
                            sigma_code_si = obj.computeCodeSigmaForSignal_(sigCfg, elv_pi, obj.cfg);
                            code_t        = sigma_code_si * randn(obj.errorChain.rngStream, 1, 1);

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
                if isfield(obj.cfg,'signals') && isfield(obj.cfg.signals,'L1')
                    errStruct.frequencyHz_perMeas = ...
                        obj.cfg.signals.L1.frequency_Hz * ones(M,1);
                else
                    errStruct.frequencyHz_perMeas = f_L1 * ones(M,1);
                end

                % Add scintillation to bySource (L1 only)
                if isfield(errStruct,'scintSigmaL1_m') && any(errStruct.scintSigmaL1_m > 0)
                    scintTruth = errStruct.scintSigmaL1_m .* randn(obj.errorChain.rngStream, M, 1);
                    z = z + scintTruth;
                    errStruct.bySource.truth_m.scintillation = scintTruth;
                    errStruct.bySource.model_m.scintillation = zeros(M,1);
                    R_diag = R_diag + errStruct.scintSigmaL1_m.^2;
                else
                    errStruct.bySource.truth_m.scintillation = zeros(M,1);
                    errStruct.bySource.model_m.scintillation = zeros(M,1);
                end
            end

            % ----- TASK 3: IF combination (ionosphereFree codeMode) --------
            % When codeMode='ionosphereFree' and N_sig==2: combine stacked L1+L2
            % rows into M_pairs IF rows.  Uses IonoFreeCombination coefficients
            % so iono cancels algebraically.  R is combined assuming uncorrelated signals.
            codeMode_v = '';
            if isfield(obj.cfg,'measurements') && isfield(obj.cfg.measurements,'codeMode')
                codeMode_v = obj.cfg.measurements.codeMode;
            end
            if strcmp(codeMode_v,'ionosphereFree') && N_sig == 2 && M == M_pairs * 2
                signals_if = revgnss.SignalUtils.getEnabledSignals(obj.cfg);
                f_L2_if    = signals_if(2).frequency_Hz;
                [alpha_if, beta_if] = revgnss.IonoFreeCombination.coefficients(f_L1, f_L2_if);

                idx1 = 1:M_pairs;
                idx2 = M_pairs+1 : 2*M_pairs;

                z_if    = alpha_if * z(idx1)      + beta_if * z(idx2);
                h_if    = alpha_if * h(idx1)      + beta_if * h(idx2);
                R_if    = alpha_if^2 * R_diag(idx1) + beta_if^2 * R_diag(idx2);

                z = z_if;
                h = h_if;
                R_diag   = R_if;
                twr_list = twr_list(idx1);
                ant_list = ant_list(idx1);
                M        = M_pairs;
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
                    if isfield(errStruct,fn) && numel(errStruct.(fn)) >= M_pairs
                        errStruct.(fn) = errStruct.(fn)(idx1);
                    end
                end
                if isfield(errStruct,'signalName_perMeas') && numel(errStruct.signalName_perMeas) >= M_pairs
                    errStruct.signalName_perMeas = repmat({'IF'}, M_pairs, 1);
                end
                errStruct.towerIdx_perMeas   = twr_list;
                errStruct.antennaIdx_perMeas = ant_list;
                errStruct.nPseudorange       = M;
                errStruct.ifCombination      = true;
            end

            % ----- Stage 4: correlated measurement noise ---------------
            % Adds truth-side correlated noise to z and builds full R.
            % correlNoise.common_m / sameTower_m / independent_m stored for contribution diagnostics.
            [z, R, correlNoise] = obj.applyCorrelatedNoise_(z, R_diag, twr_list, M);
            errStruct.correlatedNoise = correlNoise;

            % R validity guard
            rDiag = diag(R);
            if any(~isfinite(rDiag)) || any(rDiag <= 0)
                nBad = sum(~isfinite(rDiag) | rDiag <= 0);
                error('MeasurementModel:invalidR', ...
                    ['R has %d invalid diagonal values (NaN/Inf/<=0). ' ...
                     'Check cfg.errors.codeNoise.sigma_m, cfg.effects, and cfg.errors toggles.'], nBad);
            end

            % ----- Jacobian H (pseudorange) ----------------------------
            H_pr = obj.computeJacobian_(towers, twr_list, ant_list, ...
                r_est, euler_est, leverArms_model, x_est, stateMap, nx);

            % ZWD Jacobian columns (perTowerZwd): H(mi, zwdIdx(ti)) = mf(elv)
            if isfield(stateMap,'zwdIdx') && ~isempty(stateMap.zwdIdx)
                mfKind = obj.zwdMappingKind_();
                for mi_z = 1:M
                    ti_z = twr_list(mi_z);
                    if ti_z <= numel(stateMap.zwdIdx) && stateMap.zwdIdx(ti_z) > 0
                        mf_z = revgnss.MappingFunctions.troposphere( ...
                            errStruct.elevations_rad(mi_z), mfKind);
                        H_pr(mi_z, stateMap.zwdIdx(ti_z)) = mf_z;
                    end
                end
            end

            % ----- Doppler rows (0.5 + 0.6) ----------------------------
            doCfg = isfield(obj.cfg,'measurements') && ...
                    isfield(obj.cfg.measurements,'doppler') && ...
                    obj.cfg.measurements.doppler.enable;

            if doCfg
                % 0.5: physics flag checks
                doTruth = isfield(obj.cfg,'physics') && isfield(obj.cfg.physics,'doppler') && ...
                          isfield(obj.cfg.physics.doppler,'truth') && obj.cfg.physics.doppler.truth.enable;
                doModel = isfield(obj.cfg,'physics') && isfield(obj.cfg.physics,'doppler') && ...
                          isfield(obj.cfg.physics.doppler,'model') && obj.cfg.physics.doppler.model.enable;
                useInEKF = obj.cfg.measurements.doppler.useInEKF;

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

                % CHANGED: v3→v4 — Issue 2
                % V1 LIMITATION: In ionoFreeCode mode, Doppler rows are not
                % combined.  They are passed through only if the ionosphere model
                % does not include rate terms (dot{TEC} = 0 in this simulation).
                % Doppler DOES carry a frequency-dependent ionospheric rate term in
                % reality (d/dt of first-order iono delay).  If iono-rate modeling
                % is ever added, either implement a Doppler IF combination or disable
                % Doppler in ionoFreeCode mode.
                %
                % Guard: if iono rate term is enabled, exclude Doppler rows (Issue 2)
                ionoRateEnabled = isfield(obj.cfg,'errors') && ...
                    isfield(obj.cfg.errors,'ionosphere') && ...
                    isfield(obj.cfg.errors.ionosphere,'includeRateTerm') && ...
                    obj.cfg.errors.ionosphere.includeRateTerm;
                if ionoRateEnabled
                    warning('revgnss:ionoFreeCode', ...
                        ['ionosphere.includeRateTerm is enabled but no Doppler ' ...
                         'IF combination model exists. ' ...
                         'Doppler rows are excluded to avoid unmodelled dispersive bias.']);
                    % Skip Doppler EKF rows this epoch
                    errStruct.doppler = struct('z',[],'h',[],'prefit',[], ...
                        'towerClockDriftTruth_mps',[],'towerClockDriftModel_mps',[]);
                    H = H_pr;
                    return
                end

                v_rx_true = asset.v_ecef_mps;
                v_rx_est  = x_est(stateMap.v_idx);
                bdot_rx_true = asset.clock.getDriftMetersPerSecond();
                bdot_rx_est  = x_est(stateMap.bdot_rx_idx);
                sigma_dop = obj.cfg.measurements.doppler.sigma_mps;

                zd      = zeros(M,1);
                hd      = zeros(M,1);
                Hd      = zeros(M,nx);
                % CHANGED: v3→v4 — Issue 10
                % V1 SIMPLIFICATION: Doppler R is diagonal.
                % Clock-drift product uncertainty (driftCorrSigma_m_per_s) is NOT
                % included here.  This is acceptable when drift product errors are
                % small compared to Doppler noise sigma, or when tower clocks are
                % assumed stable.
                % LIMITATION: If clock-drift corrections are active, add
                %   cfg.errors.towerClock.driftCorrSigma_m_per_s
                % as a shared term per tower or document that it remains unmodelled.
                Rd_diag = sigma_dop^2 * ones(M,1);
                towerClockDriftTruth_mps = zeros(M,1);
                towerClockDriftModel_mps = zeros(M,1);

                for mi = 1:M
                    ti  = twr_list(mi);
                    ai  = ant_list(mi);

                    % 0.6: tower clock drift in Doppler
                    bdot_twr = towers{ti}.getClockDriftMetersPerSecond();
                    towerClockDriftTruth_mps(mi) = bdot_twr;
                    if strcmp(towerClkMode, 'perfectCorrection')
                        bdot_twr_model = bdot_twr;   % known drift → cancel in h
                    else
                        bdot_twr_model = 0;  % drift correction unavailable
                    end
                    towerClockDriftModel_mps(mi) = bdot_twr_model;

                    r_twr_t = obj.getTowerPosition_(towers{ti}, ti, 'truth');
                    delta_t = r_ants_truth(:,ai) - r_twr_t;
                    rho_t   = norm(delta_t); if rho_t < 1; rho_t = 1; end
                    u_t     = delta_t / rho_t;

                    if doTruth
                        rhoDot_true = u_t' * v_rx_true;
                        zd(mi) = rhoDot_true + bdot_rx_true - bdot_twr + ...
                                 sigma_dop * obj.errorChain.drawNormal(1,1);
                    % else: zd(mi) = 0 (zero-filled, warned above)
                    end

                    r_twr_e = obj.getTowerPosition_(towers{ti}, ti, 'model');
                    delta_e = r_ants_est(:,ai) - r_twr_e;
                    rho_e   = norm(delta_e); if rho_e < 1; rho_e = 1; end
                    u_e     = delta_e / rho_e;

                    if doModel
                        rhoDot_est = u_e' * v_rx_est;
                        hd(mi) = rhoDot_est + bdot_rx_est - bdot_twr_model;
                    end

                    Hd(mi, stateMap.v_idx)       = u_e';
                    Hd(mi, stateMap.bdot_rx_idx) = 1;
                end

                errStruct.doppler.z     = zd;
                errStruct.doppler.h     = hd;
                errStruct.doppler.prefit = zd - hd;
                errStruct.doppler.towerClockDriftTruth_mps = towerClockDriftTruth_mps;
                errStruct.doppler.towerClockDriftModel_mps = towerClockDriftModel_mps;

                if useInEKF
                    % CHANGED: v3→v4 — Issue 11
                    % LIMITATION: Cross-covariance between pseudorange and Doppler rows
                    % arising from a shared tower-clock product error is ignored in v1.
                    % The off-diagonal blocks of R between pseudorange and Doppler are
                    % set to zero.  This is valid only when clock product errors are
                    % small relative to independent noise terms, or when clock states
                    % are estimated in the EKF (absorbing the correlation).
                    z    = [z;    zd];
                    h    = [h;    hd];
                    H_pr = [H_pr; Hd];
                    % Append diagonal Doppler variances to whatever R shape was built
                    if size(R,1) == M
                        R = blkdiag(R, diag(Rd_diag));
                    else
                        R = diag([diag(R); Rd_diag]);
                    end
                end
            else
                errStruct.doppler = struct();
            end

            H = H_pr;

            % ----- Carrier phase (ekfFloat or diagnostic) --------------
            carrierMode_v = 'none';
            if isfield(obj.cfg,'measurements')
                if isfield(obj.cfg.measurements,'carrierMode')
                    carrierMode_v = obj.cfg.measurements.carrierMode;
                elseif isfield(obj.cfg.measurements,'carrierPhase') && ...
                        isfield(obj.cfg.measurements.carrierPhase,'enable') && ...
                        obj.cfg.measurements.carrierPhase.enable
                    carrierMode_v = 'diagnostic';
                end
            end

            M_pairs_c = round(M / max(N_sig, 1));

            switch carrierMode_v
                case 'ekfFloat'
                    [z_phi, h_phi, H_phi, R_phi, cpInfo] = obj.computeCarrierEkfRows_( ...
                        asset, towers, twr_list(1:M_pairs_c), ant_list(1:M_pairs_c), ...
                        r_ants_truth, r_ants_est, leverArms_model, x_est, stateMap, nx, ...
                        errStruct, towerClkTruth, towerClkModel, towerClkSigma, t_s);
                    if ~isempty(z_phi)
                        z = [z; z_phi];
                        h = [h; h_phi];
                        H = [H; H_phi];
                        R = blkdiag(R, R_phi);
                    end
                    errStruct.carrierPhase = cpInfo;

                case 'diagnostic'
                    doCpCfg = isfield(obj.cfg.measurements,'carrierPhase') && ...
                              isfield(obj.cfg.measurements.carrierPhase,'enable') && ...
                              obj.cfg.measurements.carrierPhase.enable;
                    if doCpCfg
                        % carrierMode='diagnostic': carrier for diagnostics only.
                        % finalizeConfig resets legacy useInEKF=true to false when
                        % carrierMode is set. MeasurementModel does not re-check it.
                        errStruct.carrierPhase = obj.computeCarrierPhase_( ...
                            asset, towers, twr_list, ant_list, r_ants_truth);
                    else
                        errStruct.carrierPhase = struct();
                    end

                otherwise  % 'none' or unknown
                    errStruct.carrierPhase = struct();
            end

            % ----- Observability diagnostics ---------------------------
            if isfield(obj.cfg,'diagnostics') && ...
                    isfield(obj.cfg.diagnostics,'observability') && ...
                    obj.cfg.diagnostics.observability.enabled
                % Build measType_perRow before passing so diagnostics see row types
                M_rows_obs = size(H, 1);
                M_dop_obs  = 0;
                if doCfg && isfield(errStruct,'doppler') && isstruct(errStruct.doppler) && ...
                        isfield(errStruct.doppler,'z') && ~isempty(errStruct.doppler.z) && ...
                        obj.cfg.measurements.doppler.useInEKF
                    M_dop_obs = numel(errStruct.doppler.z);
                end
                % Stage 7A.1: label IF-combined code rows as 'ifCode' so
                % ObservabilityDiagnostics.nIFCodeRows is non-zero in IF mode.
                isIFCodeObs = isfield(errStruct,'ifCombination') && errStruct.ifCombination;
                mTypeObs = cell(M_rows_obs, 1);
                for mi_o = 1:M_rows_obs
                    if mi_o <= M
                        if isIFCodeObs
                            mTypeObs{mi_o} = 'ifCode';
                        else
                            mTypeObs{mi_o} = 'code';
                        end
                    elseif mi_o <= M + M_dop_obs
                        mTypeObs{mi_o} = 'doppler';
                    else
                        mTypeObs{mi_o} = 'carrier';
                    end
                end
                errStruct.observability = revgnss.ObservabilityDiagnostics.analyze( ...
                    H, stateMap, obj.cfg, mTypeObs);
            else
                errStruct.observability = struct();
            end

            % ----- Measurement type metadata per EKF row ---------------
            M_rows     = size(H, 1);
            M_dop_rows = 0;
            if doCfg && isfield(errStruct,'doppler') && isstruct(errStruct.doppler) && ...
                    isfield(errStruct.doppler,'z') && ~isempty(errStruct.doppler.z) && ...
                    obj.cfg.measurements.doppler.useInEKF
                M_dop_rows = numel(errStruct.doppler.z);
            end
            % Stage 7A.1: label IF rows as 'ifCode' so downstream diagnostics count them.
            isIFCode = isfield(errStruct,'ifCombination') && errStruct.ifCombination;
            mType = cell(M_rows, 1);
            for mi_t = 1:M_rows
                if mi_t <= M
                    if isIFCode
                        mType{mi_t} = 'ifCode';
                    else
                        mType{mi_t} = 'code';
                    end
                elseif mi_t <= M + M_dop_rows
                    mType{mi_t} = 'doppler';
                else
                    mType{mi_t} = 'carrier';
                end
            end
            errStruct.measType_perRow = mType;
        end

        % ----------------------------------------------------------------
        function H = computeJacobian_(obj, towers, twr_list, ant_list, ...
                r_cm_est, euler_est, leverArms_model, x_est, stateMap, nx)
            % computeJacobian_  Measurement Jacobian (analytic or FD).
            %
            % Stage 5: if any model-side correction is on (Sagnac, Shapiro, PCV, PCO)
            % OR cfg.estimator.forceFiniteDifferenceH=true, use FD for r and euler columns.
            % Clock columns remain analytic: b_rx=+1, b_twr=-1.
            %
            % CHANGED: v3→v4 — Issue 13
            % V1 APPROXIMATION: Attitude derivatives of tropospheric and
            % ionospheric corrections through lever-arm-induced elevation changes
            % are ignored.  This is valid when:
            %     leverArmLength_m << slantRange_m   AND
            %     atmospheric correction gradient is small.
            % Add a diagnostic warning if leverArmLength / slantRange > 1e-4.

            M = numel(twr_list);
            H = zeros(M, nx);

            doFD = revgnss.MeasurementModel.needsFiniteDiffH_(obj.cfg);

            doAttJac = isfield(obj.cfg.estimator, 'estimateAttitude') && ...
                       obj.cfg.estimator.estimateAttitude && ...
                       isfield(obj.cfg.estimator, 'estimateAttitudeFromPseudorange') && ...
                       obj.cfg.estimator.estimateAttitudeFromPseudorange;

            step_e = obj.attitudeJacStep_rad;

            for mi = 1:M
                ti    = twr_list(mi);
                ai    = ant_list(mi);
                lever = leverArms_model(:, ai);

                if doFD
                    % Finite-difference position columns (accounts for all corrections)
                    step_r = 1.0;   % 1 m FD step for position
                    for ki = 1:3
                        r_p = r_cm_est; r_p(ki) = r_p(ki) + step_r;
                        r_m = r_cm_est; r_m(ki) = r_m(ki) - step_r;
                        hp = obj.computeModelRangeOnly_(towers, ti, ai, r_p, euler_est, leverArms_model);
                        hm = obj.computeModelRangeOnly_(towers, ti, ai, r_m, euler_est, leverArms_model);
                        H(mi, stateMap.r_idx(ki)) = (hp - hm) / (2*step_r);
                    end
                else
                    % Analytic position Jacobian: u' using model tower position + PCO lever
                    r_twr = obj.getTowerPosition_(towers{ti}, ti, 'model');
                    r_ant = revgnss.AttitudeKinematics.applyLeverArm(r_cm_est, euler_est, lever);
                    delta = r_ant - r_twr;
                    rho   = norm(delta); if rho < 1; rho = 1; end
                    H(mi, stateMap.r_idx) = (delta / rho)';
                end

                % Lever-arm ratio diagnostic (Issue 13)
                r_twr_diag = obj.getTowerPosition_(towers{ti}, ti, 'model');
                r_ant_diag = revgnss.AttitudeKinematics.applyLeverArm(r_cm_est, euler_est, lever);
                slantRange_diag = norm(r_ant_diag - r_twr_diag);
                leverNorm_diag  = norm(lever);
                if slantRange_diag > 0 && leverNorm_diag / slantRange_diag > 1e-4 && ...
                        leverNorm_diag > 1e-9 && mod(mi, max(1, numel(twr_list))) == 1
                    warning('revgnss:leverArmRatio', ...
                        'Lever arm / slant range = %.2e; atmosphere attitude derivatives may not be negligible.', ...
                        leverNorm_diag / slantRange_diag);
                end

                % Attitude FD (gated by config + non-zero lever)
                if doAttJac && norm(lever) > 1e-9
                    for ke = 1:3
                        eul_p = euler_est; eul_p(ke) = eul_p(ke) + step_e;
                        eul_m = euler_est; eul_m(ke) = eul_m(ke) - step_e;
                        hp = obj.computeModelRangeOnly_(towers, ti, ai, r_cm_est, eul_p, leverArms_model);
                        hm = obj.computeModelRangeOnly_(towers, ti, ai, r_cm_est, eul_m, leverArms_model);
                        H(mi, stateMap.euler_idx(ke)) = (hp - hm) / (2*step_e);
                    end
                end

                % Receiver clock: +1 (analytic, independent of corrections)
                H(mi, stateMap.b_rx_idx) = 1;

                % Tower clock state: -1 if estimated
                if isfield(stateMap,'towerClockIdx') && ...
                        ti <= size(stateMap.towerClockIdx,1) && ...
                        stateMap.towerClockIdx(ti,1) > 0
                    H(mi, stateMap.towerClockIdx(ti,1)) = -1;
                end
            end
        end

        % ----------------------------------------------------------------
        function mode = getTowerClockMode_(obj)
            mode = 'none';
            if isfield(obj.cfg,'estimator') && isfield(obj.cfg.estimator,'towerClockMode')
                mode = obj.cfg.estimator.towerClockMode;
            elseif isfield(obj.cfg,'towerClockMode')
                mode = obj.cfg.towerClockMode;
            end
        end

        % ----------------------------------------------------------------
        function cp = computeCarrierPhase_(obj, asset, towers, twr_list, ant_list, r_ants_true)
            % computeCarrierPhase_  Truth carrier phase observables (diagnostic only).
            %
            % z_phi_cycles = (rho + b_rx - b_twr) / lambda + N_ia + noise
            % N_ia: constant integer ambiguity per (tower, antenna) arc.
            %
            % What is included: geometry + clocks + ambiguity + carrier noise.
            % What is NOT included: atmosphere.
            %   Troposphere delays carrier like code (same sign).
            %   Ionosphere ADVANCES carrier (OPPOSITE sign to code, sign = -1).
            % ErrorChain truthTotal_m is NOT used here to avoid applying iono
            % with wrong sign.  If atmosphere is later added, apply:
            %   rho + trop_m - iono_m   (trop positive, iono negative for carrier).
            % No cycle slips in v1.
            cpc    = obj.cfg.measurements.carrierPhase;
            lambda = cpc.lambda_m;
            sigma  = cpc.sigma_cycles;
            M      = numel(twr_list);

            if isempty(obj.ambiguityMap)
                rngAmb = RandStream('mt19937ar','Seed', cpc.seed);
                obj.ambiguityMap = containers.Map('KeyType','int32','ValueType','double');
                for mi2 = 1:M
                    key = int32(twr_list(mi2) * 1000 + ant_list(mi2));
                    if ~isKey(obj.ambiguityMap, key)
                        switch cpc.initialAmbiguityMode
                            case 'randomInteger'
                                obj.ambiguityMap(key) = round(randn(rngAmb,1,1) * 1e4);
                            otherwise
                                obj.ambiguityMap(key) = 0;
                        end
                    end
                end
            end

            b_rx_true = asset.clock.getBiasMeters();
            phi   = zeros(M,1);
            ambig = zeros(M,1);
            for mi = 1:M
                ti    = twr_list(mi);
                ai    = ant_list(mi);
                r_twr = towers{ti}.getAntennaPositionECEF();
                b_twr = towers{ti}.getClockBiasMeters();
                rho   = norm(r_ants_true(:,ai) - r_twr);
                key   = int32(ti * 1000 + ai);
                N_ia  = obj.ambiguityMap(key);
                ambig(mi) = N_ia;
                % Geometry + clocks + ambiguity + carrier noise (no atmosphere).
                phi(mi) = (rho + b_rx_true - b_twr) / lambda + N_ia + ...
                          sigma * obj.errorChain.drawNormal(1,1);
            end
            cp.phi_cycles    = phi;
            cp.ambiguity_int = ambig;
            cp.lambda_m      = lambda;
            cp.towerIdx      = twr_list;
            cp.antennaIdx    = ant_list;
        end

        % ----------------------------------------------------------------
        function b_model = getTowerClockModel_(obj, twr, cfg)
            % getTowerClockModel_  Legacy single-tower clock correction helper.
            % NOTE: use stored errStruct.towerClockModel_m in main loop to avoid
            % repeated noise draws.  This method is for test/standalone use only.
            towerClockMode = obj.getTowerClockMode_();
            noiseSigma = 0.5;
            if isfield(cfg,'estimator') && isfield(cfg.estimator,'towerClockCorrectionSigma_m')
                noiseSigma = cfg.estimator.towerClockCorrectionSigma_m;
            end
            switch towerClockMode
                case 'none'
                    b_model = 0;
                case 'perfectCorrection'
                    b_model = twr.getClockBiasMeters();
                case 'noisyCorrection'
                    % CHANGED: v3→v4 — Issue 5
                    % SIMULATION NOTE: noisyCorrection is a truth-based simulated external
                    % correction product.  It is NOT a model of what a real receiver
                    % produces; it adds zero-mean Gaussian noise to the true tower clock.
                    % Use for Monte Carlo bias/sigma studies only.
                    b_model = twr.getClockBiasMeters() + noiseSigma * obj.errorChain.drawNormal(1,1);
                otherwise
                    b_model = 0;
            end
        end

        % ----------------------------------------------------------------
        function h_pr = computePseudorangeModelOnly(obj, asset, towers, x_state, errStruct, stateMap, t_s)
            % computePseudorangeModelOnly  Recompute h_pr with updated EKF state.
            if nargin < 7 || isempty(t_s); t_s = 0; end
            %
            % Exact same model-side path as computeMeasurements (h side):
            %   - PCO-adjusted lever arms (model)
            %   - getTowerPosition_(..., 'model') with survey error
            %   - Model tower PCO if enabled
            %   - correctedPseudorange(..., 'model', el) — Sagnac, Shapiro, PCV
            %   - Receiver + tower clock from state / errStruct
            %   - errStruct.modelTotal_m — frozen ErrorChain corrections
            %
            % Used by ReverseGNSSSimulation.computePostfitResiduals_ so postfit
            % uses the exact same model path as the EKF h, not a simplified version.

            leverArms = asset.receiverLeverArms_body_m;
            N_ant = size(leverArms, 2);

            % Model-side lever arms with receiver PCO if enabled
            leverArms_model = leverArms;
            if isfield(obj.cfg,'effects') && isfield(obj.cfg.effects,'antennaPCO')
                pco = obj.cfg.effects.antennaPCO;
                if isfield(pco,'model') && pco.model.enable
                    off = pco.receiverOffset_body_m(:);
                    leverArms_model = leverArms + off * ones(1, N_ant);
                end
            end

            r_est     = x_state(stateMap.r_idx);
            euler_est = x_state(stateMap.euler_idx);
            b_rx_est  = x_state(stateMap.b_rx_idx);

            r_ants_est = asset.getAntennaPositionsECEF(r_est, euler_est, leverArms_model);

            twr_list = errStruct.towerIdx_perMeas;
            ant_list = errStruct.antennaIdx_perMeas;
            M_pr     = errStruct.nPseudorange;

            h_pr = zeros(M_pr, 1);

            for mi = 1:M_pr
                ti = twr_list(mi);
                ai = ant_list(mi);

                % Model tower position (with survey error if model.enable)
                r_twr_model = obj.getTowerPosition_(towers{ti}, ti, 'model');

                % Tower PCO (model side)
                if isfield(obj.cfg,'effects') && isfield(obj.cfg.effects,'antennaPCO')
                    pco = obj.cfg.effects.antennaPCO;
                    if isfield(pco,'model') && pco.model.enable
                        tOff = pco.towerOffset_enu_m(:);
                        R_ENU = revgnss.GeometryUtils.enu2ecef( ...
                            towers{ti}.lat_rad, towers{ti}.lon_rad);
                        r_twr_model = r_twr_model + R_ENU * tOff;
                    end
                end

                % Elevation angle from updated positions (for PCV)
                r_ant = r_ants_est(:, ai);
                elv = revgnss.GeometryUtils.elevationAngle(r_twr_model, r_ant);

                % Corrected range (Sagnac, Shapiro, PCV all on model side)
                rho_est = revgnss.RangeCorrections.correctedPseudorange( ...
                    r_ant, r_twr_model, obj.cfg, 'model', elv, t_s);

                % Tower clock: EKF state if estimated, else frozen model correction
                if isfield(stateMap,'towerClockIdx') && ti <= size(stateMap.towerClockIdx,1) && ...
                        stateMap.towerClockIdx(ti,1) > 0
                    b_twr = x_state(stateMap.towerClockIdx(ti,1));
                elseif mi <= numel(errStruct.towerClockModel_m)
                    b_twr = errStruct.towerClockModel_m(mi);
                else
                    b_twr = 0;
                end

                % Frozen ErrorChain model correction (same realization as original h)
                model_total = 0;
                if isfield(errStruct,'modelTotal_m') && mi <= numel(errStruct.modelTotal_m)
                    model_total = errStruct.modelTotal_m(mi);
                end

                h_pr(mi) = rho_est + b_rx_est - b_twr + model_total;

                % TASK 2: ZWD state contribution (same as in computeMeasurements h path)
                if isfield(stateMap,'zwdIdx') && ti <= numel(stateMap.zwdIdx) && ...
                        stateMap.zwdIdx(ti) > 0
                    mf_h = revgnss.MappingFunctions.troposphere(elv, obj.zwdMappingKind_());
                    h_pr(mi) = h_pr(mi) + mf_h * x_state(stateMap.zwdIdx(ti));
                end
            end
        end

        % ----------------------------------------------------------------
        function h_phi = computeCarrierModelOnly(obj, asset, towers, x_state, errStruct, stateMap, t_s)
            % computeCarrierModelOnly  Recompute carrier h with updated EKF state.
            if nargin < 7 || isempty(t_s); t_s = 0; end
            %
            % Returns h_phi for each carrier row (one per visible tower) evaluated
            % at x_state (the post-update EKF state).  Used by
            % ReverseGNSSSimulation.computePostfitResiduals_ to produce true
            % postfit residuals rather than prefit residuals.
            %
            % Formula (Phase 2):
            %   h_phi = rho_est + b_rx_est - b_twr_model
            %           + trop_model - iono_model + B_est + zwd_contribution
            %
            % All error-chain corrections are frozen from errStruct (same realization
            % as original h).  Only the state-dependent terms (r, b_rx, B, ZWD) are
            % re-evaluated from x_state.

            if ~isfield(errStruct,'carrierPhase') || ...
                    ~isstruct(errStruct.carrierPhase) || ...
                    ~isfield(errStruct.carrierPhase,'towerIdx') || ...
                    isempty(errStruct.carrierPhase.towerIdx)
                h_phi = [];
                return
            end

            cp = errStruct.carrierPhase;
            twr_pairs = cp.towerIdx;
            ant_pairs = cp.antennaIdx;
            Mp = numel(twr_pairs);

            leverArms = asset.receiverLeverArms_body_m;
            N_ant = size(leverArms, 2);

            % Model-side lever arms with receiver PCO if enabled
            leverArms_model = leverArms;
            if isfield(obj.cfg,'effects') && isfield(obj.cfg.effects,'antennaPCO')
                pco = obj.cfg.effects.antennaPCO;
                if isfield(pco,'model') && pco.model.enable
                    off = pco.receiverOffset_body_m(:);
                    leverArms_model = leverArms + off * ones(1, N_ant);
                end
            end

            r_est     = x_state(stateMap.r_idx);
            euler_est = x_state(stateMap.euler_idx);
            b_rx_est  = x_state(stateMap.b_rx_idx);

            r_ants_est = asset.getAntennaPositionsECEF(r_est, euler_est, leverArms_model);

            sigIdx = 1;   % L1 only in v1
            h_phi  = zeros(Mp, 1);
            mfKind = obj.zwdMappingKind_();

            for mi = 1:Mp
                ti  = twr_pairs(mi);
                ai  = ant_pairs(mi);

                % Model tower position (survey + PCO, same as computeMeasurements)
                r_twr_e = obj.getTowerPosition_(towers{ti}, ti, 'model');
                if isfield(obj.cfg,'effects') && isfield(obj.cfg.effects,'antennaPCO')
                    pco = obj.cfg.effects.antennaPCO;
                    if isfield(pco,'model') && pco.model.enable
                        tOff = pco.towerOffset_enu_m(:);
                        R_ENU = revgnss.GeometryUtils.enu2ecef(towers{ti}.lat_rad, towers{ti}.lon_rad);
                        r_twr_e = r_twr_e + R_ENU * tOff;
                    end
                end

                % Updated elevation for ZWD mapping
                elv = revgnss.GeometryUtils.elevationAngle(r_twr_e, r_ants_est(:, ai));

                % Corrected geometric range (same path as code)
                rho_e = revgnss.RangeCorrections.correctedPseudorange( ...
                    r_ants_est(:, ai), r_twr_e, obj.cfg, 'model', elv, t_s);

                % Tower clock: EKF state if estimated, else frozen model correction
                if isfield(stateMap,'towerClockIdx') && ti <= size(stateMap.towerClockIdx,1) && ...
                        stateMap.towerClockIdx(ti,1) > 0
                    b_twr = x_state(stateMap.towerClockIdx(ti,1));
                elseif isfield(errStruct,'towerClockModel_m') && mi <= numel(errStruct.towerClockModel_m)
                    b_twr = errStruct.towerClockModel_m(mi);
                else
                    b_twr = 0;
                end

                % Float ambiguity state (updated)
                B_est = 0;
                if isfield(stateMap,'ambiguityIdx') && ...
                        ti <= size(stateMap.ambiguityIdx,1) && ...
                        sigIdx <= size(stateMap.ambiguityIdx,2) && ...
                        stateMap.ambiguityIdx(ti,sigIdx) > 0
                    B_est = x_state(stateMap.ambiguityIdx(ti,sigIdx));
                end

                % Frozen troposphere and ionosphere (same realization as original h)
                trop_m = 0; iono_m = 0;
                if isfield(errStruct,'bySource')
                    bm = errStruct.bySource.model_m;
                    if isfield(bm,'trop') && mi <= numel(bm.trop); trop_m = bm.trop(mi); end
                    if isfield(bm,'iono') && mi <= numel(bm.iono); iono_m = bm.iono(mi); end
                end

                h_phi(mi) = rho_e + b_rx_est - b_twr + trop_m - iono_m + B_est;

                % ZWD state (updated)
                if isfield(stateMap,'zwdIdx') && ti <= numel(stateMap.zwdIdx) && ...
                        stateMap.zwdIdx(ti) > 0
                    mf = revgnss.MappingFunctions.troposphere(elv, mfKind);
                    h_phi(mi) = h_phi(mi) + mf * x_state(stateMap.zwdIdx(ti));
                end
            end
        end

    end  % public methods

    methods (Access = private)

        % ----------------------------------------------------------------
        function sigma = computeCodeSigmaForSignal_(obj, sigCfg, elv, cfg)
            % computeCodeSigmaForSignal_  Per-signal code noise sigma at given elevation.
            %
            % Uses signal codeSigma0_m and the configured code noise model.

            elvFloor = revgnss.Constants.ELEVATION_FLOOR_RAD;
            sigma0   = sigCfg.codeSigma0_m;

            codeModel = 'constant';
            if isfield(cfg,'measurements') && isfield(cfg.measurements,'codeNoise') && ...
                    isfield(cfg.measurements.codeNoise,'model')
                codeModel = cfg.measurements.codeNoise.model;
            end

            switch lower(codeModel)
                case 'constant'
                    sigma = sigma0;
                case 'elevation'
                    p = 1.0;
                    if isfield(cfg,'measurements') && ...
                            isfield(cfg.measurements,'codeNoise') && ...
                            isfield(cfg.measurements.codeNoise,'elevationExponent')
                        p = cfg.measurements.codeNoise.elevationExponent;
                    end
                    mapping = 1 / max(sin(elv), sin(elvFloor));
                    sigma   = sigma0 * mapping^p;
                otherwise
                    sigma = sigma0;
            end
        end

        % ----------------------------------------------------------------
        function r_twr = getTowerPosition_(obj, tower, towerIdx, side)
            % getTowerPosition_  Tower antenna position for truth or model side.
            %
            % Stage 2: if cfg.effects.towerSurvey.(side).enable, adds the
            % survey ENU error stored in cfg.towers(towerIdx).surveyError_ENU_m.
            % Does NOT mutate tower.r_ecef_m — computes on-the-fly.

            r_nom = tower.getAntennaPositionECEF();

            if ~isfield(obj.cfg,'effects') || ~isfield(obj.cfg.effects,'towerSurvey')
                r_twr = r_nom; return;
            end
            ts = obj.cfg.effects.towerSurvey;
            if ~isfield(ts, side) || ~ts.(side).enable
                r_twr = r_nom; return;
            end

            % Survey error (generated once in finalizeConfig, same for truth+model)
            if towerIdx <= numel(obj.cfg.towers) && ...
                    isfield(obj.cfg.towers(towerIdx),'surveyError_ENU_m')
                enu_err = obj.cfg.towers(towerIdx).surveyError_ENU_m;
                r_twr = r_nom + revgnss.GeometryUtils.enu2ecef_vector( ...
                    tower.lat_rad, tower.lon_rad, enu_err);
            else
                r_twr = r_nom;
            end
        end

        % ----------------------------------------------------------------
        function [b_m, bdot_mps] = getClockAtProductEpoch_(obj, tower, t_prod_s)
            % getClockAtProductEpoch_  Return tower clock bias and drift at product epoch.
            %
            % For 'truthHistoryProduct'/'product'/'productNoisy' modes that do NOT have
            % an explicit cfg.towerClock.products struct, this reads from tower history.
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

        % ----------------------------------------------------------------
        function [b_hat, sigma_corr] = evalProductStruct_(obj, ti, t_eval_s)
            % evalProductStruct_  Evaluate explicit per-tower product struct.
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

            if ~isfield(obj.cfg,'towerClock') || ~isfield(obj.cfg.towerClock,'products')
                error('MeasurementModel:productStructMissing', ...
                    ['evalProductStruct_: cfg.towerClock.products is required for explicit ' ...
                     'product/productNoisy modes but is missing. ' ...
                     'Provide a products struct array or use truthHistoryProduct instead.']);
            end
            products = obj.cfg.towerClock.products;
            if ti > numel(products)
                error('MeasurementModel:productStructMissing', ...
                    ['evalProductStruct_: tower index %d exceeds products array length %d. ' ...
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
                if isfield(obj.cfg.towerClock,'productValidityPolicy')
                    policy = obj.cfg.towerClock.productValidityPolicy;
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

        % ----------------------------------------------------------------
        function [z_out, R_out, noiseComp] = applyCorrelatedNoise_(obj, z_in, R_diag, twr_list, M)
            % applyCorrelatedNoise_  Stage 4: add correlated truth noise and build full R.
            %
            % Returns optional third output noiseComp with per-component noise vectors
            % (same length as z) for contribution diagnostics.
            %
            % If cfg.effects.correlatedNoise.enable=false, returns z unchanged and
            % R = diag(R_diag) and noiseComp with zero arrays.
            %
            % If enabled:
            %   Truth noise draws (added to z only):
            %     commonMode: one sample shared by all M measurements.
            %     sameTower:  one sample per unique tower, shared across antennas.
            %     independent: one sample per measurement.
            %   Full R = diag(R_diag + independentSigma^2)
            %            + commonModeSigma^2 * ones(M,M)
            %            + sameTowerSigma^2 blocks per tower group.

            noiseComp.common_m      = zeros(M,1);
            noiseComp.sameTower_m   = zeros(M,1);
            noiseComp.independent_m = zeros(M,1);

            z_out = z_in;
            if ~isfield(obj.cfg,'effects') || ~isfield(obj.cfg.effects,'correlatedNoise') || ...
                    ~obj.cfg.effects.correlatedNoise.enable
                R_out = diag(R_diag);
                return
            end

            cn  = obj.cfg.effects.correlatedNoise;
            rng = obj.rngCorr;

            % Common-mode noise
            if cn.commonModeSigma_m > 0
                common = cn.commonModeSigma_m * randn(rng, 1, 1);
                noiseComp.common_m = common * ones(M,1);
                z_out = z_out + noiseComp.common_m;
            end

            % Same-tower noise
            if cn.sameTowerSigma_m > 0
                uniqTwrs = unique(twr_list);
                for k = 1:numel(uniqTwrs)
                    tNoise = cn.sameTowerSigma_m * randn(rng, 1, 1);
                    mask = (twr_list == uniqTwrs(k));
                    noiseComp.sameTower_m(mask) = tNoise;
                    z_out(mask) = z_out(mask) + tNoise;
                end
            end

            % Independent correlated-noise component
            if cn.independentSigma_m > 0
                noiseComp.independent_m = cn.independentSigma_m * randn(rng, M, 1);
                z_out = z_out + noiseComp.independent_m;
            end

            % Build full R
            R_out = diag(R_diag + cn.independentSigma_m^2 * ones(M,1));
            R_out = R_out + cn.commonModeSigma_m^2 * ones(M,M);
            if cn.sameTowerSigma_m > 0
                uniqTwrs = unique(twr_list);
                for k = 1:numel(uniqTwrs)
                    idx = find(twr_list == uniqTwrs(k));
                    R_out(idx,idx) = R_out(idx,idx) + cn.sameTowerSigma_m^2 * ones(numel(idx));
                end
            end
        end

        % ----------------------------------------------------------------
        function [z_phi, h_phi, H_phi, R_phi, cpInfo] = computeCarrierEkfRows_( ...
                obj, asset, towers, twr_pairs, ant_pairs, r_ants_truth, r_ants_est, ...
                leverArms_model, x_est, stateMap, nx, errStruct, ...
                towerClkTruth, towerClkModel, towerClkSigma, t_s)
            % computeCarrierEkfRows_  Build carrier EKF rows with float ambiguity states.
            if nargin < 17 || isempty(t_s); t_s = 0; end
            %
            % z_phi = rho_true + b_rx_true - b_twr_true + trop_true - iono_true + B_true + noise
            % h_phi = rho_est  + b_rx_est  - b_twr_model + trop_model - iono_model + B_est
            %
            % CRITICAL: ionosphere sign is NEGATIVE for carrier (phase advance).
            % This is opposite to +iono for code (group delay).
            % B_phi states are float, in metres, one per (tower, sigIdx=1) arc.
            %
            % Stage 7A — Carrier H position Jacobian:
            % When range corrections (Sagnac, Shapiro, PCV, PCO) are active the
            % geometric unit vector dρ/dr = u' is insufficient.  If
            % needsFiniteDiffH_ is true, we use central finite difference on
            % computeModelRangeOnly_ (identical function used for h_phi range).
            % Clock, ambiguity, and ZWD columns remain analytic.

            cfg    = obj.cfg;
            Mp     = numel(twr_pairs);

            % Defensive guard: carrier IF must be caught by ConfigFactory.finalizeConfig.
            % If it survives to here, throw unless user explicitly opted into silent fallback.
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

            sigIdx   = 1;   % carrier rows use signal index 1 (L1) in v1
            b_rx_true = asset.clock.getBiasMeters();
            b_rx_est  = x_est(stateMap.b_rx_idx);

            % Lazy-init float ambiguity truth map (metres)
            if isempty(obj.floatAmbiguityTruth_m)
                obj.floatAmbiguityTruth_m = containers.Map('KeyType','int32','ValueType','double');
            end

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
                if ~isKey(obj.floatAmbiguityTruth_m, key)
                    initSig = 100;
                    if isfield(cfg,'estimation') && isfield(cfg.estimation,'ambiguity') && ...
                            isfield(cfg.estimation.ambiguity,'initialSigma_m')
                        initSig = cfg.estimation.ambiguity.initialSigma_m;
                    end
                    obj.floatAmbiguityTruth_m(key) = initSig * obj.errorChain.drawNormal(1,1);
                end
                B_true = obj.floatAmbiguityTruth_m(key);

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

                % Truth and model geometric range (same path as code: survey + PCO + corrections)
                % Phase 3: use getTowerPosition_ so survey error is included on truth side
                r_twr_t = obj.getTowerPosition_(towers{ti}, ti, 'truth');
                % Tower PCO (truth side) — mirrors code path in computeMeasurements
                if isfield(obj.cfg,'effects') && isfield(obj.cfg.effects,'antennaPCO')
                    pco = obj.cfg.effects.antennaPCO;
                    if isfield(pco,'truth') && pco.truth.enable
                        tOff = pco.towerOffset_enu_m(:);
                        R_ENU = revgnss.GeometryUtils.enu2ecef(towers{ti}.lat_rad, towers{ti}.lon_rad);
                        r_twr_t = r_twr_t + R_ENU * tOff;
                    end
                end
                rho_t = revgnss.RangeCorrections.correctedPseudorange( ...
                    r_ants_truth(:,ai), r_twr_t, obj.cfg, 'truth', elv, t_s);

                r_ant_e  = r_ants_est(:, ai);
                r_twr_e  = obj.getTowerPosition_(towers{ti}, ti, 'model');
                delta_e  = r_ant_e - r_twr_e;
                rho_e_geom = norm(delta_e); if rho_e_geom < 1; rho_e_geom = 1; end
                rho_e = revgnss.RangeCorrections.correctedPseudorange( ...
                    r_ant_e, r_twr_e, obj.cfg, 'model', elv, t_s);

                noise_phi = sigma_phi * obj.errorChain.drawNormal(1,1);

                % z: +trop, -iono (carrier ionosphere is OPPOSITE sign to code)
                z_phi(mi) = rho_t + b_rx_true - b_twr_t + trop_t - iono_t + B_true + noise_phi;

                % h: +trop_model, -iono_model + ZWD state (TASK 2)
                h_phi(mi) = rho_e + b_rx_est - b_twr_m + trop_m - iono_m + B_est;
                if isfield(stateMap,'zwdIdx') && ti <= numel(stateMap.zwdIdx) && ...
                        stateMap.zwdIdx(ti) > 0
                    mf_phi = revgnss.MappingFunctions.troposphere(elv, obj.zwdMappingKind_());
                    h_phi(mi) = h_phi(mi) + mf_phi * x_est(stateMap.zwdIdx(ti));
                end

                cpInfo.phi_m(mi)    = z_phi(mi);
                cpInfo.prefit_m(mi) = z_phi(mi) - h_phi(mi);

                % ---- H: position columns (analytic or FD) -------------------
                r_cm_est  = x_est(stateMap.r_idx);
                euler_est = x_est(stateMap.euler_idx);
                doFD = revgnss.MeasurementModel.needsFiniteDiffH_(obj.cfg);

                if doFD
                    % Central finite-difference position Jacobian.
                    % Uses computeModelRangeOnly_ — same function as h_phi range term.
                    step_r = 1.0;  % 1 m step
                    for ki = 1:3
                        rp = r_cm_est; rp(ki) = rp(ki) + step_r;
                        rm = r_cm_est; rm(ki) = rm(ki) - step_r;
                        hp = obj.computeModelRangeOnly_(towers, ti, ai, rp, euler_est, leverArms_model);
                        hm = obj.computeModelRangeOnly_(towers, ti, ai, rm, euler_est, leverArms_model);
                        H_phi(mi, stateMap.r_idx(ki)) = (hp - hm) / (2*step_r);
                    end
                else
                    % Analytic unit vector (pure geometry, no range corrections)
                    H_phi(mi, stateMap.r_idx) = (delta_e / rho_e_geom)';
                end

                % ---- H: clock, ambiguity, ZWD (always analytic) -------------
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
                    mf = revgnss.MappingFunctions.troposphere(elv, obj.zwdMappingKind_());
                    H_phi(mi, stateMap.zwdIdx(ti)) = mf;
                end
            end
        end

        % ----------------------------------------------------------------
        function rho = computeModelRangeOnly_(obj, towers, ti, ai, r_cm, euler, leverArms_model)
            % computeModelRangeOnly_  Model geometric range for FD Jacobian.
            %
            % Includes model-side corrections (Sagnac, Shapiro, PCV) but NOT
            % clock terms or ErrorChain corrections (constants w.r.t. position/attitude).
            lever = leverArms_model(:, ai);
            r_ant = revgnss.AttitudeKinematics.applyLeverArm(r_cm, euler, lever);
            r_twr = obj.getTowerPosition_(towers{ti}, ti, 'model');

            % Tower PCO (model side)
            if isfield(obj.cfg,'effects') && isfield(obj.cfg.effects,'antennaPCO')
                pco = obj.cfg.effects.antennaPCO;
                if isfield(pco,'model') && pco.model.enable
                    tOff = pco.towerOffset_enu_m(:);
                    R_ENU = revgnss.GeometryUtils.enu2ecef(towers{ti}.lat_rad, towers{ti}.lon_rad);
                    r_twr = r_twr + R_ENU * tOff;
                end
            end

            % Use PCV with elevation from current geometry
            elv = revgnss.GeometryUtils.elevationAngle(r_twr, r_ant);
            rho = revgnss.RangeCorrections.correctedPseudorange(r_ant, r_twr, obj.cfg, 'model', elv);
        end

    end  % private methods

    methods (Access = private)

        % ----------------------------------------------------------------
        function kind = zwdMappingKind_(obj)
            % zwdMappingKind_  Return the configured ZWD troposphere mapping kind.
            %
            % Reads cfg.effects.troposphere.mappingModel (preferred) or
            % cfg.errors.troposphere.mappingModel (legacy path).
            % Defaults to 'simple' if neither is set.
            % Valid values: 'simple' | 'continuedFraction'
            kind = 'simple';
            if isfield(obj.cfg,'effects') && isfield(obj.cfg.effects,'troposphere') && ...
                    isfield(obj.cfg.effects.troposphere,'mappingModel')
                kind = obj.cfg.effects.troposphere.mappingModel;
            elseif isfield(obj.cfg,'errors') && isfield(obj.cfg.errors,'troposphere') && ...
                    isfield(obj.cfg.errors.troposphere,'mappingModel')
                kind = obj.cfg.errors.troposphere.mappingModel;
            end
        end

    end  % private (ZWD helper) methods

    methods (Static)

        function [z_isl, h_isl, H_isl] = computeISLMeasurements(asset_rx, asset_tx, ~, ~)
            % computeISLMeasurements  Future-work stub. ISL is NOT implemented in oo_v1.
            %
            % Returns empty z/h/H — no EKF rows, no measurement effect.
            % Do NOT advertise ISL as supported functionality.
            %
            % Candidate future one-way range observable:
            %   z_{rx,tx} = rho_{rx,tx} + b_rx - b_tx + noise
            % Sign convention: receiver clock adds positively, transmitter subtracts.
            z_isl = [];
            h_isl = [];
            H_isl = zeros(0, 0);
        end

        function need = needsFiniteDiffH_(cfg)
            % needsFiniteDiffH_  True when any model-side position-affecting correction is on.
            %
            % Sagnac and Shapiro add explicit terms to dh/dr.  PCO and PCV change the
            % effective antenna positions used in the range computation.
            % Tower survey offsets do NOT require FD (they shift the baseline h but the
            % Jacobian structure d(rho)/d(r) = u' is unchanged).
            need = false;
            if isfield(cfg,'estimator') && isfield(cfg.estimator,'forceFiniteDifferenceH') && ...
                    cfg.estimator.forceFiniteDifferenceH
                need = true; return;
            end
            if isfield(cfg,'physics')
                if isfield(cfg.physics,'sagnac') && isfield(cfg.physics.sagnac,'model') && ...
                        cfg.physics.sagnac.model.enable
                    need = true; return;
                end
                if isfield(cfg.physics,'relativity') && ...
                        isfield(cfg.physics.relativity,'shapiro') && ...
                        isfield(cfg.physics.relativity.shapiro,'model') && ...
                        cfg.physics.relativity.shapiro.model.enable
                    need = true; return;
                end
            end
            if isfield(cfg,'effects')
                if isfield(cfg.effects,'antennaPCO') && ...
                        isfield(cfg.effects.antennaPCO,'model') && ...
                        cfg.effects.antennaPCO.model.enable
                    need = true; return;
                end
                if isfield(cfg.effects,'antennaPCV') && ...
                        isfield(cfg.effects.antennaPCV,'model') && ...
                        cfg.effects.antennaPCV.model.enable
                    need = true; return;
                end
                % Stage 7A.1: iterative light-time rotates the tower position by
                % omega_E*tau; the geometric Jacobian dρ/dr = u' is then wrong.
                % Use finite-difference H when iterative light-time is active.
                if isfield(cfg.effects,'lightTime') && ...
                        isfield(cfg.effects.lightTime,'model') && ...
                        strcmp(cfg.effects.lightTime.model,'iterative')
                    need = true; return;
                end
            end
        end

    end  % static methods

end
