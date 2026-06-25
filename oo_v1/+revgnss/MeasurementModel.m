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
            [towerClkTruth, towerClkModel, towerClkSigma, corrNoise_m, t_prod, towerClkMode] = ...
                revgnss.TowerClockCorrectionProvider.compute( ...
                    obj.cfg, obj.errorChain, towers, twr_list, t_s);

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

            % ----- Code/pseudorange measurements ----------------------
            [z, h, R, errStruct, twr_list, ant_list, M, N_sig] = ...
                revgnss.CodeMeasurementBuilder.build( ...
                    obj.cfg, obj.errorChain, obj.rngCorr, asset, towers, ...
                    twr_list, ant_list, elv_list, leverArms, leverArms_model, ...
                    r_ants_truth, r_ants_est, x_est, stateMap, ...
                    towerClkTruth, towerClkModel, towerClkSigma, towerClkMode, t_prod, ...
                    errStruct, t_s);


            % ----- Jacobian H (pseudorange) ----------------------------
            H_pr = revgnss.CodeJacobianBuilder.build( ...
                obj.cfg, obj.attitudeJacStep_rad, towers, twr_list, ant_list, ...
                r_est, euler_est, leverArms_model, x_est, stateMap, nx);

            % ZWD Jacobian columns (perTowerZwd): H(mi, zwdIdx(ti)) = mf(elv)
            if isfield(stateMap,'zwdIdx') && ~isempty(stateMap.zwdIdx)
                mfKind = revgnss.MeasurementModelUtils.zwdMappingKind(obj.cfg);
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
            [dopplerRows, dopplerInfo] = revgnss.DopplerMeasurementBuilder.build( ...
                obj.cfg, obj.errorChain, asset, towers, twr_list, ant_list, ...
                r_ants_truth, r_ants_est, x_est, stateMap, towerClkMode, t_s);
            errStruct.doppler = dopplerInfo;
            if dopplerRows.ionoRateExclusion
                H = H_pr;
                return
            end
            if dopplerRows.useInEKF && ~isempty(dopplerRows.z)
                z    = [z;    dopplerRows.z];
                h    = [h;    dopplerRows.h];
                H_pr = [H_pr; dopplerRows.H];
                if size(R,1) == M
                    R = blkdiag(R, dopplerRows.R);
                else
                    R = diag([diag(R); diag(dopplerRows.R)]);
                end
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
                    if isempty(obj.floatAmbiguityTruth_m)
                        obj.floatAmbiguityTruth_m = containers.Map('KeyType','int32','ValueType','double');
                    end
                    [z_phi, h_phi, H_phi, R_phi, cpInfo] = revgnss.CarrierMeasurementBuilder.buildEkfRows( ...
                        obj.cfg, obj.errorChain, obj.floatAmbiguityTruth_m, ...
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
                        [errStruct.carrierPhase, obj.ambiguityMap] = ...
                            revgnss.CarrierMeasurementBuilder.buildDiagnostic( ...
                                obj.cfg, obj.errorChain, obj.ambiguityMap, ...
                                asset, towers, twr_list, ant_list, r_ants_truth);
                    else
                        errStruct.carrierPhase = struct();
                    end

                otherwise  % 'none' or unknown
                    errStruct.carrierPhase = struct();
            end

            % ----- Stack metadata and observability --------------------
            errStruct = revgnss.MeasurementStackMetadata.annotate( ...
                obj.cfg, H, M, errStruct, stateMap);
        end

        % ----------------------------------------------------------------
        function h_pr = computePseudorangeModelOnly(obj, asset, towers, x_state, errStruct, stateMap, t_s)
            % computePseudorangeModelOnly  Thin wrapper — implementation in PseudorangeModelOnlyBuilder.
            if nargin < 7 || isempty(t_s); t_s = 0; end
            h_pr = revgnss.PseudorangeModelOnlyBuilder.compute( ...
                obj.cfg, asset, towers, x_state, errStruct, stateMap, t_s);
        end

        % ----------------------------------------------------------------
        function h_phi = computeCarrierModelOnly(obj, asset, towers, x_state, errStruct, stateMap, t_s)
            % computeCarrierModelOnly  Thin wrapper — implementation in CarrierModelOnlyBuilder.
            if nargin < 7 || isempty(t_s); t_s = 0; end
            h_phi = revgnss.CarrierModelOnlyBuilder.compute( ...
                obj.cfg, asset, towers, x_state, errStruct, stateMap, t_s);
        end

    end  % public methods

    methods (Static)

        % Implementations live in MeasurementModelUtils (Stage 12A.2).
        % These one-line wrappers preserve backward compatibility.

        function varargout = computeISLMeasurements(varargin)
            [varargout{1:nargout}] = revgnss.MeasurementModelUtils.computeISLMeasurements(varargin{:});
        end
        function need = needsFiniteDiffH_(cfg)
            need = revgnss.MeasurementModelUtils.needsFiniteDiffH_(cfg);
        end
        function r_twr = towerPositionEcef(cfg, tower, towerIdx, side)
            r_twr = revgnss.MeasurementModelUtils.towerPositionEcef(cfg, tower, towerIdx, side);
        end
        function kind = zwdMappingKind(cfg)
            kind = revgnss.MeasurementModelUtils.zwdMappingKind(cfg);
        end
        function rho = modelRangeOnly(cfg, towers, ti, ai, r_cm, euler, leverArms_model)
            rho = revgnss.MeasurementModelUtils.modelRangeOnly(cfg, towers, ti, ai, r_cm, euler, leverArms_model);
        end
        function sigma = codeSignalSigma(sigCfg, elv, cfg)
            sigma = revgnss.MeasurementModelUtils.codeSignalSigma(sigCfg, elv, cfg);
        end
        function d = rxCodeBiasModel(cfg)
            d = revgnss.MeasurementModelUtils.rxCodeBiasModel(cfg);
        end
        function [z_out, R_out, noiseComp] = correlatedNoise(cfg, rngCorr, z_in, R_diag, twr_list, M)
            [z_out, R_out, noiseComp] = revgnss.MeasurementModelUtils.correlatedNoise( ...
                cfg, rngCorr, z_in, R_diag, twr_list, M);
        end

    end  % static methods

end
