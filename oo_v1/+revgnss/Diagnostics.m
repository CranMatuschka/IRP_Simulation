classdef Diagnostics < handle
    % Diagnostics  Accumulates per-epoch simulation diagnostics.
    %
    % Each call to record() appends one entry to obj.log.
    %
    % Stored per epoch (entry fields):
    %   time_s
    %   truth.*              truth state
    %   estimate.*           EKF state
    %   measurements.*       z, h, innovations, residuals
    %   errors.*             per-source error chain breakdown
    %   R, H, NIS
    %   positionError_m        scalar position error norm
    %   positionErrorVec_m     [3x1] ECEF position error components
    %   attitudeError_rad      [3x1] attitude error components
    %   clockBiasError_m       scalar
    %   clockDriftError_mps    scalar
    %   fracFreqError          scalar
    %   numVisibleTowers       scalar
    %   prefitInnovationRMS    scalar
    %   postfitResidualRMS     scalar
    %   perSourceTruthRMS      struct with one field per error source
    %   perSourceModelRMS      struct
    %   towerClockTruth_m      [M x 1] (visible towers this epoch)
    %   towerClockModel_m      [M x 1]
    %   towerClockCorrectionError_m [M x 1]
    %   attitudeJacobianNorm   scalar (Frobenius norm of H attitude columns)
    %   measurementRank        scalar
    %   conditionNumberS       scalar
    %   estimatedPositionSigma_m  scalar  1-sigma from P diagonal
    %   estimatedAttitudeSigma_rad scalar

    properties
        log     (:,1) struct
        nEpochs (1,1) double = 0
        % Receiver hardware-bias architecture metadata (Stage 12)
        % Set once during construction from cfg; constant across epochs.
        rxCodeBiasMode                  char   = 'absorbedInReceiverClock'
        rxCodeBiasModel_m               double = 0.0
        rxCodeBiasIdentifiabilityStatus char   = 'safe: collinear term absorbed into receiver clock'
        rxCarrierBiasMode               char   = 'notImplemented'
        rxCarrierBiasIdentifiabilityStatus char = 'safe: constant phase bias absorbed in float ambiguity'
    end

    properties (Access = private)
        clockObsBuf_
        clockObsEnable_  (1,1) logical = true
        clockObsWinLen_  (1,1) double  = 60
        clockObsMinWin_  (1,1) double  = 5
        clockObsRankTol_
    end

    methods
        function obj = Diagnostics(cfg)
            obj.log = struct([]);
            obj.clockObsBuf_     = struct('H_phys', {{}}, 'Rd_phys', {{}}, ...
                                          'H_gauge', {{}}, 'Rd_gauge', {{}});
            obj.clockObsRankTol_ = [];
            if nargin > 0 && ~isempty(cfg)
                obj.configureCfg(cfg);
            end
        end

        function configureCfg(obj, cfg)
            if isfield(cfg,'diagnostics') && isfield(cfg.diagnostics,'clockObservability')
                co = cfg.diagnostics.clockObservability;
                if isfield(co,'enable');             obj.clockObsEnable_ = co.enable;             end
                if isfield(co,'windowLengthEpochs'); obj.clockObsWinLen_ = co.windowLengthEpochs; end
                if isfield(co,'minWindowEpochs');    obj.clockObsMinWin_ = co.minWindowEpochs;    end
                if isfield(co,'rankTolerance');      obj.clockObsRankTol_ = co.rankTolerance;     end
            end

            % --- Stage 12: receiver bias architecture metadata ---------------
            if isfield(cfg,'hardware') && isfield(cfg.hardware,'rxCodeBias')
                rxcb = cfg.hardware.rxCodeBias;
                if isfield(rxcb,'mode')
                    obj.rxCodeBiasMode = rxcb.mode;
                end
                switch obj.rxCodeBiasMode
                    case {'fixed','externalCalibration'}
                        if isfield(rxcb,'fixedValue_m')
                            obj.rxCodeBiasModel_m = rxcb.fixedValue_m;
                        end
                        obj.rxCodeBiasIdentifiabilityStatus = ...
                            'safe: fixed/external calibration applied as model correction';
                    case 'absorbedInReceiverClock'
                        obj.rxCodeBiasIdentifiabilityStatus = ...
                            'safe: collinear term absorbed into receiver clock bias';
                    case 'off'
                        obj.rxCodeBiasIdentifiabilityStatus = ...
                            'safe: correction disabled; collinear term absorbed into receiver clock';
                    otherwise
                        obj.rxCodeBiasIdentifiabilityStatus = ...
                            sprintf('unknown mode ''%s''', obj.rxCodeBiasMode);
                end
            end
            if isfield(cfg,'hardware') && isfield(cfg.hardware,'rxCarrierBias')
                rxcb2 = cfg.hardware.rxCarrierBias;
                if isfield(rxcb2,'mode')
                    obj.rxCarrierBiasMode = rxcb2.mode;
                end
                switch obj.rxCarrierBiasMode
                    case 'absorbedInAmbiguity'
                        obj.rxCarrierBiasIdentifiabilityStatus = ...
                            'safe: phase bias declared absorbed into float ambiguity';
                    case 'notImplemented'
                        obj.rxCarrierBiasIdentifiabilityStatus = ...
                            'safe: constant phase bias absorbed in float ambiguity (implicit)';
                    case {'fixed','externalCalibration'}
                        obj.rxCarrierBiasIdentifiabilityStatus = ...
                            'safe: fixed/external carrier phase calibration';
                    otherwise
                        obj.rxCarrierBiasIdentifiabilityStatus = ...
                            sprintf('unknown mode ''%s''', obj.rxCarrierBiasMode);
                end
            end
        end

        % ----------------------------------------------------------------
        function record(obj, t_s, asset, ekf, z, h, H, R, NIS, errStruct, ...
                visibleTowerIds, elevations_rad, postfitResidual)

            sm = ekf.stateMap;
            x  = ekf.x;
            c  = revgnss.Constants.SPEED_OF_LIGHT_MPS;

            entry.time_s = t_s;

            % --- Truth state -------------------------------------------
            entry.truth.r_cm_ecef_m       = asset.r_ecef_m;
            entry.truth.v_cm_ecef_mps     = asset.v_ecef_mps;
            entry.truth.euler_rad         = asset.attitude_euler_rad;
            entry.truth.omega_body_radps  = asset.angularRate_body_radps;
            entry.truth.r_ant_ecef_m      = asset.getAntennaPositionECEF();
            entry.truth.rxClockBias_m     = asset.clock.getBiasMeters();
            entry.truth.rxClockBias_s     = asset.clock.getBiasSeconds();
            entry.truth.rxFracFreq        = asset.clock.getFractionalFrequency();
            entry.truth.rxClockDrift_mps  = asset.clock.getDriftMetersPerSecond();

            % --- Estimate state ----------------------------------------
            entry.estimate.x                 = x;
            entry.estimate.P                 = ekf.P;
            entry.estimate.r_cm_ecef_m       = x(sm.r_idx);
            entry.estimate.v_cm_ecef_mps     = x(sm.v_idx);
            entry.estimate.euler_rad         = x(sm.euler_idx);
            entry.estimate.omega_body_radps  = x(sm.omega_idx);
            entry.estimate.rxClockBias_m     = x(sm.b_rx_idx);
            entry.estimate.rxClockDrift_mps  = x(sm.bdot_rx_idx);
            entry.estimate.r_ant_ecef_m      = revgnss.AttitudeKinematics.applyLeverArm( ...
                x(sm.r_idx), x(sm.euler_idx), asset.receiverLeverArm_body_m);

            % --- Measurements ------------------------------------------
            if ~isempty(z)
                entry.measurements.z                = z;
                entry.measurements.h                = h;
                entry.measurements.prefitInnovation = z - h;
                if nargin >= 13 && ~isempty(postfitResidual)
                    entry.measurements.postfitResidual = postfitResidual;
                else
                    entry.measurements.postfitResidual = z - h;  % fallback
                end
                entry.measurements.visibleTowerIds  = visibleTowerIds;
                entry.measurements.elevation_rad    = elevations_rad;
            else
                entry.measurements.z                = [];
                entry.measurements.h                = [];
                entry.measurements.prefitInnovation = [];
                entry.measurements.postfitResidual  = [];
                entry.measurements.visibleTowerIds  = [];
                entry.measurements.elevation_rad    = [];
            end

            % --- Error chain -------------------------------------------
            if ~isempty(errStruct)
                entry.errors.truthTotal_m = errStruct.truthTotal_m;
                entry.errors.modelTotal_m = errStruct.modelTotal_m;
                entry.errors.bySource     = errStruct.bySource;

                % Tower clock truth/model corrections (stored per visible tower)
                if isfield(errStruct,'towerClockTruth_m')
                    entry.towerClockTruth_m  = errStruct.towerClockTruth_m;
                    entry.towerClockModel_m  = errStruct.towerClockModel_m;
                    entry.towerClockCorrectionError_m = ...
                        errStruct.towerClockTruth_m - errStruct.towerClockModel_m;
                else
                    entry.towerClockTruth_m  = [];
                    entry.towerClockModel_m  = [];
                    entry.towerClockCorrectionError_m = [];
                end

                % Doppler prefit RMS (if enabled)
                if isfield(errStruct,'doppler') && isfield(errStruct.doppler,'prefit') && ...
                        ~isempty(errStruct.doppler.prefit)
                    entry.dopplerPrefitRMS_mps = sqrt(mean(errStruct.doppler.prefit.^2));
                else
                    entry.dopplerPrefitRMS_mps = 0;
                end

                % Range-correction diagnostics (sagnac, shapiro)
                if isfield(errStruct,'sagnacTruth_m')
                    diff_s = errStruct.sagnacTruth_m - errStruct.sagnacModel_m;
                    entry.sagnacDiffRMS_m  = sqrt(mean(diff_s.^2));
                    entry.shapiroDiffRMS_m = sqrt(mean((errStruct.shapiroTruth_m - errStruct.shapiroModel_m).^2));
                else
                    entry.sagnacDiffRMS_m  = 0;
                    entry.shapiroDiffRMS_m = 0;
                end

                % Per-source RMS(truth_m - model_m) for this epoch.
                % getPerSourceErrorRMS() returns these as "Truth - Model" residual RMS.
                labels = {'code','trop','iono','hwDelay','mp'};
                for j = 1:numel(labels)
                    lbl = labels{j};
                    if isfield(errStruct.bySource,'truth_m') && ...
                            isfield(errStruct.bySource.truth_m, lbl)
                        t_k = errStruct.bySource.truth_m.(lbl);
                        m_k = errStruct.bySource.model_m.(lbl);
                        if ~isempty(t_k)
                            diff_k = t_k - m_k;
                            entry.perSourceTruthRMS.(lbl) = sqrt(mean(diff_k.^2));  % truth-model
                            entry.perSourceModelRMS.(lbl) = sqrt(mean(m_k.^2));
                        else
                            entry.perSourceTruthRMS.(lbl) = 0;
                            entry.perSourceModelRMS.(lbl) = 0;
                        end
                    else
                        entry.perSourceTruthRMS.(lbl) = 0;
                        entry.perSourceModelRMS.(lbl) = 0;
                    end
                end
            else
                entry.errors.truthTotal_m = [];
                entry.errors.modelTotal_m = [];
                entry.errors.bySource     = struct();
                entry.towerClockTruth_m   = [];
                entry.towerClockModel_m   = [];
                entry.towerClockCorrectionError_m = [];
                entry.sagnacDiffRMS_m  = 0;
                entry.shapiroDiffRMS_m = 0;
                entry.dopplerPrefitRMS_mps = 0;
                labels = {'code','trop','iono','hwDelay','mp'};
                for j = 1:numel(labels)
                    entry.perSourceTruthRMS.(labels{j}) = 0;
                    entry.perSourceModelRMS.(labels{j}) = 0;
                end
            end

            entry.R   = R;
            entry.H   = H;
            entry.NIS = NIS;

            % --- Scalar error metrics ----------------------------------
            r_err = x(sm.r_idx) - asset.r_ecef_m;
            entry.positionError_m    = norm(r_err);
            entry.positionErrorVec_m = r_err;

            eul_err = revgnss.AttitudeKinematics.wrapEuler( ...
                x(sm.euler_idx) - asset.attitude_euler_rad);
            entry.attitudeError_rad = eul_err;

            entry.clockBiasError_m     = x(sm.b_rx_idx) - asset.clock.getBiasMeters();
            entry.clockDriftError_mps  = x(sm.bdot_rx_idx) - asset.clock.getDriftMetersPerSecond();
            entry.fracFreqError        = entry.clockDriftError_mps / c;

            entry.numVisibleTowers = numel(visibleTowerIds);

            % Pseudorange count (EKF measurement rows without Doppler).
            % Total EKF rows = numel(z) (may include Doppler if useInEKF=true).
            if ~isempty(errStruct) && isfield(errStruct,'nPseudorange')
                M_pr = errStruct.nPseudorange;
            else
                M_pr = numel(z);
            end
            entry.numPseudorangeMeasurements = M_pr;
            entry.numMeasurements            = M_pr;   % pseudorange count for observation plot
            entry.numMeasurementRows         = numel(z); % total EKF z dimension

            % --- Innovation / residual RMS split by measurement type -------
            % Use measType_perRow when available to separate code/Doppler/carrier.
            M_dop_rows = 0;
            if ~isempty(errStruct) && isfield(errStruct,'measType_perRow')
                mtype = errStruct.measType_perRow;
                M_dop_rows = sum(strcmp(mtype,'doppler'));
            elseif ~isempty(errStruct) && isfield(errStruct,'doppler') && ...
                    isfield(errStruct.doppler,'z') && ~isempty(errStruct.doppler.z)
                M_dop_rows = numel(errStruct.doppler.z);
            end

            if ~isempty(z) && M_pr > 0 && numel(z) >= M_pr
                innPR = z(1:M_pr) - h(1:M_pr);
                entry.prefitPseudorangeRMS_m  = sqrt(mean(innPR.^2));
                entry.prefitInnovationRMS     = entry.prefitPseudorangeRMS_m;
                if M_dop_rows > 0 && numel(z) >= M_pr + M_dop_rows
                    innDop = z(M_pr+1:M_pr+M_dop_rows) - h(M_pr+1:M_pr+M_dop_rows);
                    entry.prefitDopplerRMS_mps = sqrt(mean(innDop.^2));
                else
                    entry.prefitDopplerRMS_mps = 0;
                end
            else
                entry.prefitPseudorangeRMS_m  = 0;
                entry.prefitInnovationRMS     = 0;
                entry.prefitDopplerRMS_mps    = 0;
            end

            if nargin >= 13 && ~isempty(postfitResidual) && numel(postfitResidual) >= M_pr
                resPR = postfitResidual(1:M_pr);
                entry.postfitPseudorangeRMS_m = sqrt(mean(resPR.^2));
                entry.postfitResidualRMS      = entry.postfitPseudorangeRMS_m;
                if M_dop_rows > 0 && numel(postfitResidual) >= M_pr + M_dop_rows
                    resDop = postfitResidual(M_pr+1:M_pr+M_dop_rows);
                    entry.postfitDopplerRMS_mps = sqrt(mean(resDop.^2));
                else
                    entry.postfitDopplerRMS_mps = 0;
                end
            else
                entry.postfitPseudorangeRMS_m = 0;
                entry.postfitResidualRMS      = 0;
                entry.postfitDopplerRMS_mps   = 0;
            end

            % Doppler diagnostic prefit (even when Doppler is not in EKF)
            if ~isempty(errStruct) && isfield(errStruct,'doppler') && ...
                    isfield(errStruct.doppler,'prefit') && ~isempty(errStruct.doppler.prefit)
                entry.dopplerPrefitRMS_mps = sqrt(mean(errStruct.doppler.prefit.^2));
            else
                entry.dopplerPrefitRMS_mps = entry.prefitDopplerRMS_mps;
            end

            % --- Per-type NIS (normalized by R diagonal, not full S) -------
            % Diagnostic: sum((z_k - h_k)^2 / R_kk) per measurement type.
            % MeasurementModel labels: 'code' or 'ifCode' (code pseudorange),
            %                          'doppler', 'carrier'.
            % These use prefit innovations and R diagonal — not the full
            % innovation covariance S = H*P*H'+R.  Useful for per-type
            % chi-squared sanity checks.  E[NIS_k / dof_k] = 1 only
            % approximately (missing H*P*H' contribution).
            entry.NIS_code    = 0;
            entry.NIS_doppler = 0;
            entry.NIS_carrier = 0;
            if ~isempty(z) && ~isempty(h) && ~isempty(R) && numel(z) == numel(h)
                inn_all = z - h;
                Rdiag   = max(diag(R), 1e-20);
                if ~isempty(errStruct) && isfield(errStruct,'measType_perRow') && ...
                        numel(errStruct.measType_perRow) == numel(z)
                    mtype_r = errStruct.measType_perRow;
                    % 'code' and 'ifCode' are both code pseudorange rows
                    prMask  = strcmp(mtype_r,'code') | strcmp(mtype_r,'ifCode');
                    dopMask = strcmp(mtype_r, 'doppler');
                    carMask = strcmp(mtype_r, 'carrier');
                    if any(prMask)
                        entry.NIS_code    = sum(inn_all(prMask).^2  ./ Rdiag(prMask));
                    end
                    if any(dopMask)
                        entry.NIS_doppler = sum(inn_all(dopMask).^2 ./ Rdiag(dopMask));
                    end
                    if any(carMask)
                        entry.NIS_carrier = sum(inn_all(carMask).^2 ./ Rdiag(carMask));
                    end
                elseif M_pr > 0 && numel(z) >= M_pr
                    entry.NIS_code = sum(inn_all(1:M_pr).^2 ./ Rdiag(1:M_pr));
                end
            end

            % --- NEES: position error normalized by EKF covariance ----------
            % NEES_pos = r_err' * P_pos^{-1} * r_err / 3.
            % Under a consistent filter, E[NEES_pos] = 1.
            entry.NEES_pos = NaN;
            try
                P_pos = ekf.P(sm.r_idx, sm.r_idx);
                if rcond(P_pos) > 1e-15
                    entry.NEES_pos = (r_err' * (P_pos \ r_err)) / 3;
                end
            catch; end

            % --- Clock gauge diagnostics ------------------------------------
            % gaugeInfo is populated by ReverseGNSSEKF.appendClockGaugeRows
            % and attached to errStruct.gaugeInfo by ReverseGNSSSimulation.
            entry.clockGaugeRowsAdded        = 0;
            entry.clockGaugeBiasResidual_m   = NaN;
            entry.clockGaugeDriftResidual_mps = NaN;
            entry.clockSubspaceRank          = NaN;
            entry.clockSubspaceCondNum       = NaN;
            if ~isempty(errStruct) && isfield(errStruct,'gaugeInfo')
                gi = errStruct.gaugeInfo;
                if isfield(gi,'rowsAdded')
                    entry.clockGaugeRowsAdded = gi.rowsAdded;
                end
                if isfield(gi,'biasResidual_m')
                    entry.clockGaugeBiasResidual_m = gi.biasResidual_m;
                end
                if isfield(gi,'driftResidual_mps')
                    entry.clockGaugeDriftResidual_mps = gi.driftResidual_mps;
                end
                if isfield(gi,'clockSubspaceRank')
                    entry.clockSubspaceRank = gi.clockSubspaceRank;
                end
                if isfield(gi,'clockSubspaceCondNum')
                    entry.clockSubspaceCondNum = gi.clockSubspaceCondNum;
                end
            end

            % --- Tx code bias gauge diagnostics ----------------------------
            % txGaugeInfo is populated by ReverseGNSSEKF.appendTxDelayGaugeRows
            % and attached to errStruct.txGaugeInfo by ReverseGNSSSimulation.
            entry.txCodeBiasGaugeRowsAdded  = 0;
            entry.txCodeBiasGaugeResidual_m = NaN;
            entry.txCodeBiasStatesEnabled   = false;
            entry.nTxCodeBiasStates         = 0;
            if ~isempty(errStruct) && isfield(errStruct,'txGaugeInfo')
                tgi = errStruct.txGaugeInfo;
                if isfield(tgi,'rowsAdded')
                    entry.txCodeBiasGaugeRowsAdded = tgi.rowsAdded;
                end
                if isfield(tgi,'gaugeResidual_m')
                    entry.txCodeBiasGaugeResidual_m = tgi.gaugeResidual_m;
                end
            end
            % Use ekf state to know whether states are active
            if ~isempty(ekf) && isprop(ekf,'estimateTxCodeBias')
                entry.txCodeBiasStatesEnabled = ekf.estimateTxCodeBias;
                entry.nTxCodeBiasStates       = ekf.nTxCodeBiasStates;
            end

            % --- Carrier slip diagnostics (Stage 14) -----------------------
            entry.carrierSlipNSlips       = 0;
            entry.carrierSlipTotalJump_m  = 0;
            if ~isempty(errStruct) && isfield(errStruct,'slipInfo') && ...
                    isstruct(errStruct.slipInfo)
                si14 = errStruct.slipInfo;
                if isfield(si14,'nSlips'); entry.carrierSlipNSlips = si14.nSlips; end
                if isfield(si14,'jumpMags_m') && ~isempty(si14.jumpMags_m)
                    entry.carrierSlipTotalJump_m = sum(si14.jumpMags_m);
                end
            end

            % --- ZWD state estimates (Stage 15) ----------------------------
            entry.zwdEstimated = false;
            entry.nZwdStates   = 0;
            entry.zwdEst_m     = [];
            if ~isempty(ekf) && isprop(ekf,'estimateZwd') && ekf.estimateZwd
                entry.zwdEstimated = true;
                entry.nZwdStates   = ekf.nZwdStates;
                if isfield(sm,'zwdIdx')
                    active = sm.zwdIdx(sm.zwdIdx > 0);
                    if ~isempty(active)
                        entry.zwdEst_m = x(active);
                    end
                end
            end

            % --- Windowed clock observability Gramian ----------------------
            % Build a sliding epoch buffer (physical H + gauge H restricted to
            % clock columns) and compute the weighted observability Gramian.
            % Physical-only rank reveals the persistent one-way pseudorange nullspace;
            % gauged rank should equal n_clk when the gauge removes that nullspace.
            entry.clockObsRankPhysical = NaN;
            entry.clockObsRankGauged   = NaN;
            entry.clockObsCondPhysical = NaN;
            entry.clockObsCondGauged   = NaN;
            entry.clockObsWeakPhysical = NaN;
            entry.clockObsWeakGauged   = NaN;
            if obj.clockObsEnable_
                clkIdx10 = [sm.b_rx_idx; sm.bdot_rx_idx];
                if isfield(sm,'towerClockIdx')
                    % towerClockIdx is [N×2]: col1=bias_idx, col2=drift_idx.
                    % Interleave row-by-row to match kron STM pair ordering:
                    % [b_rx; bdot_rx; b_twr1; bdot_twr1; ...]
                    tci10    = sm.towerClockIdx;
                    flat10   = reshape(tci10', [], 1);   % [2N × 1] interleaved
                    clkIdx10 = [clkIdx10; flat10(flat10 > 0)];
                end
                clkIdx10 = clkIdx10(clkIdx10 > 0);

                if ~isempty(H) && ~isempty(R) && ~isempty(clkIdx10) && size(H,2) >= max(clkIdx10)
                    H_clk10  = H(:, clkIdx10);
                    Rd10     = diag(R);
                else
                    H_clk10  = zeros(0, numel(clkIdx10));
                    Rd10     = zeros(0, 1);
                end

                H_gauge10 = zeros(0, numel(clkIdx10));
                Rd_g10    = zeros(0, 1);
                if ~isempty(errStruct) && isfield(errStruct,'gaugeInfo')
                    gi10 = errStruct.gaugeInfo;
                    if isfield(gi10,'H_gauge') && ~isempty(gi10.H_gauge) && ...
                            ~isempty(clkIdx10) && size(gi10.H_gauge,2) >= max(clkIdx10)
                        H_gauge10 = gi10.H_gauge(:, clkIdx10);
                    end
                    if isfield(gi10,'R_gauge_diag') && ~isempty(gi10.R_gauge_diag)
                        Rd_g10 = gi10.R_gauge_diag;
                    end
                end

                buf10 = obj.clockObsBuf_;
                buf10.H_phys{end+1}   = H_clk10;
                buf10.Rd_phys{end+1}  = Rd10;
                buf10.H_gauge{end+1}  = H_gauge10;
                buf10.Rd_gauge{end+1} = Rd_g10;
                wl10 = obj.clockObsWinLen_;
                if numel(buf10.H_phys) > wl10
                    buf10.H_phys  = buf10.H_phys(end-wl10+1:end);
                    buf10.Rd_phys = buf10.Rd_phys(end-wl10+1:end);
                    buf10.H_gauge = buf10.H_gauge(end-wl10+1:end);
                    buf10.Rd_gauge = buf10.Rd_gauge(end-wl10+1:end);
                end
                obj.clockObsBuf_ = buf10;

                if numel(buf10.H_phys) >= obj.clockObsMinWin_ && ...
                        ~isempty(clkIdx10) && mod(numel(clkIdx10), 2) == 0
                    if obj.nEpochs >= 1
                        dt10 = t_s - obj.log(obj.nEpochs).time_s;
                    else
                        dt10 = 1;
                    end
                    if dt10 <= 0; dt10 = 1; end
                    try
                        obs10 = revgnss.ObservabilityDiagnostics.computeClockWindowObservability( ...
                            buf10.H_phys, buf10.Rd_phys, buf10.H_gauge, buf10.Rd_gauge, ...
                            dt10, sm, obj.clockObsRankTol_);
                        entry.clockObsRankPhysical = obs10.rankPhysical;
                        entry.clockObsRankGauged   = obs10.rankGauged;
                        entry.clockObsCondPhysical = obs10.conditionPhysical;
                        entry.clockObsCondGauged   = obs10.conditionGauged;
                        entry.clockObsWeakPhysical = obs10.weakStatesPhysical;
                        entry.clockObsWeakGauged   = obs10.weakStatesGauged;
                    catch
                        % Leave as NaN — Gramian failed (e.g. no clock states)
                    end
                end
            end

            % --- Jacobian diagnostics ----------------------------------
            if ~isempty(H) && size(H,2) >= 9
                H_att = H(:, sm.euler_idx);
                entry.attitudeJacobianNorm = norm(H_att, 'fro');
                % Warn only when attitude estimation from pseudorange is expected but
                % the Jacobian is near-zero (i.e. lever arm/geometry problem).
                % Suppress when estimateAttitudeFromPseudorange = false (by design).
                if entry.attitudeJacobianNorm < 1e-10 && ~isempty(H) && ...
                        mod(obj.nEpochs+1,500) == 1
                    H_omg = H(:, sm.omega_idx);
                    if norm(H_omg,'fro') > 1e-10
                        warning('Diagnostics:zeroAttJac', ...
                            'Attitude Jacobian is near-zero at t=%.0f s. Check lever arm.', t_s);
                    end
                end

                % CHANGED: v3→v4 — Issue 8
                % Attitude observability via SVD rank (not just max singular value).
                % Using only maxSV cannot distinguish partial (1-2 axis) from full
                % 3-axis sensitivity.
                sv_att       = svd(H_att);
                tol_sv       = max(sv_att) * 1e-6;  % relative tolerance
                attRank      = sum(sv_att > tol_sv);
                switch attRank
                    case 0
                        attStatus = 'unobservable';
                    case {1,2}
                        attStatus = 'partial';
                    case 3
                        attStatus = 'full';
                    otherwise
                        attStatus = 'full';
                end
                entry.attitudeRank   = attRank;
                entry.attitudeStatus = attStatus;
                if attRank >= 2
                    entry.attitudeCondNum = max(sv_att(1:attRank)) / min(sv_att(1:attRank));
                else
                    entry.attitudeCondNum = NaN;
                end

                % Attitude-ambiguity separability (Stage 14.9).
                % With one float ambiguity per carrier row, H_amb spans R^M so H_att is
                % never separable.  This computes the diagnostic to confirm analytically.
                entry.attitudeSeparable     = false;
                entry.attitudeAmbCorrMaxAbs = NaN;
                if isfield(sm,'ambiguityIdx3d')
                    ambFlat = nonzeros(sm.ambiguityIdx3d(:));
                    if ~isempty(ambFlat) && max(ambFlat) <= size(H,2)
                        Hb_all  = H(:, ambFlat);
                        carRows = any(Hb_all ~= 0, 2);
                        if sum(carRows) > 0
                            Hac  = H_att(carRows, :);
                            Hbc  = Hb_all(carRows, :);
                            tolR = 1e-6 * max(norm(Hac,'fro'), norm(Hbc,'fro'));
                            rB   = rank(Hbc, tolR);
                            rAB  = rank([Hac Hbc], tolR);
                            entry.attitudeSeparable = (rAB > rB);
                            nHac = norm(Hac,'fro');
                            if nHac > 1e-15
                                nn   = max(vecnorm(Hbc), 1e-15);
                                Ccc  = abs(Hbc' * Hac) ./ nn' ./ max(vecnorm(Hac), 1e-15);
                                entry.attitudeAmbCorrMaxAbs = max(Ccc(:));
                            end
                        end
                    end
                end
            else
                entry.attitudeJacobianNorm  = 0;
                entry.attitudeRank          = 0;
                entry.attitudeStatus        = 'unobservable';
                entry.attitudeCondNum       = NaN;
                entry.attitudeSeparable     = false;
                entry.attitudeAmbCorrMaxAbs = NaN;
            end

            if ~isempty(H)
                entry.measurementRank = rank(H);
            else
                entry.measurementRank = 0;
            end

            if ~isempty(H) && ~isempty(R)
                S_mat = H * ekf.P * H' + R;
                entry.conditionNumberS = cond(S_mat);
            else
                entry.conditionNumberS = NaN;
            end

            % --- Geometry / DOPS diagnostics --------------------------------
            % Project pseudorange rows onto [x, y, z, b_rx] columns.
            % This is a geometry-only quality metric independent of P or error models.
            % gdopLike = sqrt(trace(Q)) where Q = (H_pc' * R_pr^-1 * H_pc)^-1
            entry.geometryRank           = NaN;
            entry.gdopLike               = NaN;
            entry.pdopLike               = NaN;
            entry.tdopLike               = NaN;
            entry.positionClockCondition = NaN;
            posClkIdx = [sm.r_idx(:); sm.b_rx_idx]';   % [1 2 3 13] for default state
            if ~isempty(H) && ~isempty(R) && M_pr >= 4 && numel(posClkIdx) == 4 && ...
                    size(H, 2) >= max(posClkIdx)
                H_pr = H(1:M_pr, :);
                R_pr = R(1:M_pr, 1:M_pr);
                H_pc = H_pr(:, posClkIdx);
                entry.geometryRank = rank(H_pc);
                if entry.geometryRank >= 4
                    try
                        invR_pr  = R_pr \ eye(M_pr);
                        N_geom   = H_pc' * invR_pr * H_pc;
                        Q_geom   = N_geom \ eye(4);
                        entry.gdopLike               = sqrt(max(trace(Q_geom),          0));
                        entry.pdopLike               = sqrt(max(trace(Q_geom(1:3,1:3)), 0));
                        entry.tdopLike               = sqrt(max(Q_geom(4,4),            0));
                        entry.positionClockCondition = cond(N_geom);
                    catch
                        % ill-conditioned geometry — leave as NaN
                    end
                end
            end

            % --- Per-effect contribution RMS --------------------------------
            % Format: cnt.effectName.{truthRMS_m, modelRMS_m, mismatchRMS_m}
            % Doppler uses _mps suffix; carrier phase uses _cycles suffix.
            rms3m   = @(t,m) struct( ...
                'truthRMS_m',      sqrt(mean(t.^2)), ...
                'modelRMS_m',      sqrt(mean(m.^2)), ...
                'mismatchRMS_m',   sqrt(mean((t-m).^2)));
            rms3mps = @(t,m) struct( ...
                'truthRMS_mps',    sqrt(mean(t.^2)), ...
                'modelRMS_mps',    sqrt(mean(m.^2)), ...
                'mismatchRMS_mps', sqrt(mean((t-m).^2)));

            z3m   = struct('truthRMS_m',      0, 'modelRMS_m',      0, 'mismatchRMS_m',      0);
            z3mps = struct('truthRMS_mps',    0, 'modelRMS_mps',    0, 'mismatchRMS_mps',    0);
            z3cyc = struct('truthRMS_cycles', 0, 'modelRMS_cycles', 0, 'mismatchRMS_cycles', 0);

            cnt = struct();
            cnt.codeNoise             = z3m;
            cnt.troposphere           = z3m;
            cnt.ionosphere            = z3m;
            cnt.hardwareDelay         = z3m;
            cnt.multipath             = z3m;
            cnt.scintillationCodeNoise = z3m;
            cnt.sagnac                = z3m;
            cnt.shapiro               = z3m;
            cnt.towerSurvey           = z3m;
            cnt.receiverPCO           = z3m;
            cnt.towerPCO              = z3m;
            cnt.pcv                   = z3m;
            cnt.towerClock            = z3m;
            cnt.correlatedCommonMode  = z3m;
            cnt.correlatedSameTower   = z3m;
            cnt.correlatedIndependent = z3m;
            cnt.total                 = z3m;
            cnt.dopplerRangeRate      = z3mps;
            cnt.dopplerTowerClockDrift = z3mps;
            cnt.dopplerNoise          = z3mps;
            cnt.carrierPhaseCycles    = z3cyc;
            cnt.carrierPhaseMeters    = z3m;

            if ~isempty(errStruct)
                % --- ErrorChain per-source (code, trop, iono, hwDelay, mp) ----
                if isfield(errStruct,'bySource') && isfield(errStruct.bySource,'truth_m')
                    bst = errStruct.bySource.truth_m;
                    bsm = errStruct.bySource.model_m;
                    srcMap = {'code','codeNoise'; 'trop','troposphere'; ...
                              'iono','ionosphere'; 'hwDelay','hardwareDelay'; 'mp','multipath'};
                    for si = 1:size(srcMap,1)
                        src = srcMap{si,1}; fld = srcMap{si,2};
                        if isfield(bst,src) && ~isempty(bst.(src))
                            cnt.(fld) = rms3m(bst.(src), bsm.(src));
                        end
                    end
                    % Scintillation
                    if isfield(bst,'scintillation') && ~isempty(bst.scintillation)
                        scintModel = zeros(size(bst.scintillation));
                        if isfield(bsm,'scintillation')
                            scintModel = bsm.scintillation;
                        end
                        cnt.scintillationCodeNoise = rms3m(bst.scintillation, scintModel);
                    end
                end

                % --- Sagnac / Shapiro / PCV ------------------------------------
                if isfield(errStruct,'sagnacTruth_m') && ~isempty(errStruct.sagnacTruth_m)
                    cnt.sagnac  = rms3m(errStruct.sagnacTruth_m,  errStruct.sagnacModel_m);
                    cnt.shapiro = rms3m(errStruct.shapiroTruth_m, errStruct.shapiroModel_m);
                    cnt.pcv     = rms3m(errStruct.pcvTruth_m,     errStruct.pcvModel_m);
                end

                % --- Tower survey / Receiver PCO / Tower PCO ------------------
                if isfield(errStruct,'towerSurveyTruth_m') && ~isempty(errStruct.towerSurveyTruth_m)
                    cnt.towerSurvey = rms3m(errStruct.towerSurveyTruth_m, errStruct.towerSurveyModel_m);
                end
                if isfield(errStruct,'receiverPCOTruth_m') && ~isempty(errStruct.receiverPCOTruth_m)
                    cnt.receiverPCO = rms3m(errStruct.receiverPCOTruth_m, errStruct.receiverPCOModel_m);
                end
                if isfield(errStruct,'towerPCOTruth_m') && ~isempty(errStruct.towerPCOTruth_m)
                    cnt.towerPCO = rms3m(errStruct.towerPCOTruth_m, errStruct.towerPCOModel_m);
                end

                % --- Tower clock (subtracted in z/h, so negate for range domain)
                if isfield(errStruct,'towerClockTruth_m') && ~isempty(errStruct.towerClockTruth_m)
                    cnt.towerClock = rms3m( ...
                        -errStruct.towerClockTruth_m, -errStruct.towerClockModel_m);
                end

                % --- Correlated noise (truth only; model = 0) -----------------
                if isfield(errStruct,'correlatedNoise')
                    cn = errStruct.correlatedNoise;
                    Mv = numel(cn.common_m);
                    if Mv > 0
                        zv = zeros(Mv,1);
                        cnt.correlatedCommonMode  = rms3m(cn.common_m,      zv);
                        cnt.correlatedSameTower   = rms3m(cn.sameTower_m,   zv);
                        cnt.correlatedIndependent = rms3m(cn.independent_m, zv);
                    end
                end

                % --- Total (all truth/model effects summed) -------------------
                if isfield(errStruct,'sagnacTruth_m') && ~isempty(errStruct.truthTotal_m)
                    tt = errStruct.truthTotal_m + errStruct.sagnacTruth_m + ...
                         errStruct.shapiroTruth_m + errStruct.pcvTruth_m;
                    tm = errStruct.modelTotal_m + errStruct.sagnacModel_m + ...
                         errStruct.shapiroModel_m + errStruct.pcvModel_m;
                    if isfield(errStruct,'towerSurveyTruth_m')
                        tt = tt + errStruct.towerSurveyTruth_m;
                        tm = tm + errStruct.towerSurveyModel_m;
                    end
                    if isfield(errStruct,'receiverPCOTruth_m')
                        tt = tt + errStruct.receiverPCOTruth_m;
                        tm = tm + errStruct.receiverPCOModel_m;
                    end
                    if isfield(errStruct,'towerPCOTruth_m')
                        tt = tt + errStruct.towerPCOTruth_m;
                        tm = tm + errStruct.towerPCOModel_m;
                    end
                    if isfield(errStruct,'correlatedNoise')
                        cn2 = errStruct.correlatedNoise;
                        tt = tt + cn2.common_m + cn2.sameTower_m + cn2.independent_m;
                    end
                    cnt.total = rms3m(tt, tm);
                end

                % --- Doppler (full zd/hd as truth/model proxies) --------------
                if isfield(errStruct,'doppler') && isfield(errStruct.doppler,'z') && ...
                        ~isempty(errStruct.doppler.z)
                    cnt.dopplerRangeRate = rms3mps(errStruct.doppler.z, errStruct.doppler.h);
                    if isfield(errStruct.doppler,'towerClockDriftTruth_mps') && ...
                            ~isempty(errStruct.doppler.towerClockDriftTruth_mps)
                        cnt.dopplerTowerClockDrift = rms3mps( ...
                            errStruct.doppler.towerClockDriftTruth_mps, ...
                            errStruct.doppler.towerClockDriftModel_mps);
                    end
                end

                % --- Carrier phase (truth only; no model in v1) ---------------
                if isfield(errStruct,'carrierPhase') && ...
                        isfield(errStruct.carrierPhase,'phi_cycles') && ...
                        ~isempty(errStruct.carrierPhase.phi_cycles)
                    phi = errStruct.carrierPhase.phi_cycles;
                    lam = errStruct.carrierPhase.lambda_m;
                    cnt.carrierPhaseCycles = struct( ...
                        'truthRMS_cycles',    sqrt(mean(phi.^2)), ...
                        'modelRMS_cycles',    0, ...
                        'mismatchRMS_cycles', sqrt(mean(phi.^2)));
                    cnt.carrierPhaseMeters = rms3m(phi * lam, zeros(size(phi)));
                end
            end

            % --- Per-signal breakdown (L1/L2 separate stats) ---------------
            cnt.bySignal = struct();
            if ~isempty(errStruct) && isfield(errStruct,'signalIdx_perMeas') && ...
                    ~isempty(errStruct.signalIdx_perMeas) && ...
                    isfield(errStruct,'bySource') && isfield(errStruct.bySource,'truth_m')
                bst3 = errStruct.bySource.truth_m;
                bsm3 = errStruct.bySource.model_m;
                sigIdxAll = errStruct.signalIdx_perMeas;
                sigNamAll = errStruct.signalName_perMeas;
                uSigs = unique(sigIdxAll);
                for si = 1:numel(uSigs)
                    mask = (sigIdxAll == uSigs(si));
                    nm   = matlab.lang.makeValidName(sigNamAll{find(mask,1)});
                    cnts = struct();
                    if isfield(bst3,'code') && ~isempty(bst3.code)
                        cnts.codeNoise   = rms3m(bst3.code(mask),  bsm3.code(mask));
                    end
                    if isfield(bst3,'iono') && ~isempty(bst3.iono)
                        cnts.ionosphere  = rms3m(bst3.iono(mask),  bsm3.iono(mask));
                    end
                    if isfield(bst3,'trop') && ~isempty(bst3.trop)
                        cnts.troposphere = rms3m(bst3.trop(mask),  bsm3.trop(mask));
                    end
                    if isfield(errStruct.bySource,'sigma_m') && ...
                            isfield(errStruct.bySource.sigma_m,'code') && ...
                            ~isempty(errStruct.bySource.sigma_m.code)
                        cnts.codeSigma_m = mean(errStruct.bySource.sigma_m.code(mask));
                    end
                    cnt.bySignal.(nm) = cnts;
                end
            end
            entry.contributions = cnt;

            % --- 1-sigma position bound from P diagonal ---------------
            Pdiag = diag(ekf.P);
            entry.estimatedPositionSigma_m   = sqrt(sum(Pdiag(sm.r_idx)));
            entry.estimatedAttitudeSigma_rad = sqrt(sum(Pdiag(sm.euler_idx)));

            % --- Stage 15: differential carrier attitude rows (optional) ---
            if isfield(errStruct,'diffAttRows') && isstruct(errStruct.diffAttRows)
                da = errStruct.diffAttRows;
                entry.diffAttNRows    = da.nRows;
                entry.diffAttResidRMS = da.residualRMS_m;
                entry.diffAttActive   = da.active;
                entry.diffAttActiveBaselines = revgnss.Diagnostics.fieldOr_(da,'activeBaselines',0);
                entry.diffAttLostBaselines = revgnss.Diagnostics.fieldOr_(da,'lostBaselines',0);
                entry.diffAttRecalibratedBaselines = revgnss.Diagnostics.fieldOr_(da,'recalibratedBaselines',0);
                entry.diffAttRejectedRows = revgnss.Diagnostics.fieldOr_(da,'rejectedRows',0);
            else
                entry.diffAttNRows    = 0;
                entry.diffAttResidRMS = NaN;
                entry.diffAttActive   = false;
                entry.diffAttActiveBaselines = 0;
                entry.diffAttLostBaselines = 0;
                entry.diffAttRecalibratedBaselines = 0;
                entry.diffAttRejectedRows = 0;
            end

            % --- Stage 16: absolute attitude initialization diagnostics ---
            entry.attitudeInitMode = 'none';
            entry.attitudeInitClass = 'CALIBRATED_TRACKING';
            entry.attitudeInitMessage = '';
            entry.attitudeInitCandidates = 0;
            entry.attitudeInitDiffRows = 0;
            entry.attitudeInitBestResidual = NaN;
            entry.attitudeInitSecondResidual = NaN;
            entry.attitudeInitRatio = NaN;
            entry.attitudeInitError_deg = NaN;
            entry.attitudeInitConfidenceClass = 'NO_ATTITUDE_INFORMATION';
            entry.attitudeInitAcceptedByEkf = false;
            entry.attitudeInitDecisionReason = '';
            entry.attitudeInitPriorEuler_deg = [NaN; NaN; NaN];
            entry.attitudeInitTruthEuler_deg = [NaN; NaN; NaN];
            entry.attitudeInitBestEuler_deg = [NaN; NaN; NaN];
            entry.attitudeInitSecondEuler_deg = [NaN; NaN; NaN];
            entry.attitudeInitTopEuler_deg = NaN(3,0);
            entry.attitudeInitTopResidualCycles = NaN(1,0);
            entry.attitudeInitBestSecondDistance_deg = NaN;
            entry.attitudeInitPriorError_deg = NaN;
            entry.attitudeInitCandidateError_deg = NaN;
            entry.attitudeInitCandidateImprovementRatio = NaN;
            entry.attitudeInitCandidateImprovement_deg = NaN;
            entry.attitudeInitNBaselines = 0;
            entry.attitudeInitNTowers = 0;
            entry.attitudeInitShadowMode = 'DISABLED';
            if isfield(errStruct,'attitudeInit') && isstruct(errStruct.attitudeInit)
                ai16 = errStruct.attitudeInit;
                if isfield(ai16,'mode'); entry.attitudeInitMode = ai16.mode; end
                if isfield(ai16,'classification'); entry.attitudeInitClass = ai16.classification; end
                if isfield(ai16,'message'); entry.attitudeInitMessage = ai16.message; end
                if isfield(ai16,'nCandidates'); entry.attitudeInitCandidates = ai16.nCandidates; end
                if isfield(ai16,'nDiffRows'); entry.attitudeInitDiffRows = ai16.nDiffRows; end
                if isfield(ai16,'nBaselines'); entry.attitudeInitNBaselines = ai16.nBaselines; end
                if isfield(ai16,'nTowers'); entry.attitudeInitNTowers = ai16.nTowers; end
                if isfield(ai16,'bestResidual'); entry.attitudeInitBestResidual = ai16.bestResidual; end
                if isfield(ai16,'secondBestResidual'); entry.attitudeInitSecondResidual = ai16.secondBestResidual; end
                if isfield(ai16,'ratio'); entry.attitudeInitRatio = ai16.ratio; end
                if isfield(ai16,'initializedAttitudeError_deg')
                    entry.attitudeInitError_deg = ai16.initializedAttitudeError_deg;
                end
                if isfield(ai16,'confidenceClass'); entry.attitudeInitConfidenceClass = ai16.confidenceClass; end
                if isfield(ai16,'acceptedByEkf'); entry.attitudeInitAcceptedByEkf = ai16.acceptedByEkf; end
                if isfield(ai16,'decisionReason'); entry.attitudeInitDecisionReason = ai16.decisionReason; end
                if isfield(ai16,'priorEuler_deg'); entry.attitudeInitPriorEuler_deg = ai16.priorEuler_deg; end
                if isfield(ai16,'truthEuler_deg'); entry.attitudeInitTruthEuler_deg = ai16.truthEuler_deg; end
                if isfield(ai16,'bestCandidateEuler_deg'); entry.attitudeInitBestEuler_deg = ai16.bestCandidateEuler_deg; end
                if isfield(ai16,'secondCandidateEuler_deg'); entry.attitudeInitSecondEuler_deg = ai16.secondCandidateEuler_deg; end
                if isfield(ai16,'topCandidateEuler_deg'); entry.attitudeInitTopEuler_deg = ai16.topCandidateEuler_deg; end
                if isfield(ai16,'topResidualCycles'); entry.attitudeInitTopResidualCycles = ai16.topResidualCycles; end
                if isfield(ai16,'bestSecondAngularDistance_deg'); entry.attitudeInitBestSecondDistance_deg = ai16.bestSecondAngularDistance_deg; end
                if isfield(ai16,'priorAttitudeError_deg'); entry.attitudeInitPriorError_deg = ai16.priorAttitudeError_deg; end
                if isfield(ai16,'candidateAttitudeError_deg'); entry.attitudeInitCandidateError_deg = ai16.candidateAttitudeError_deg; end
                if isfield(ai16,'candidateImprovementRatio'); entry.attitudeInitCandidateImprovementRatio = ai16.candidateImprovementRatio; end
                if isfield(ai16,'candidateImprovement_deg'); entry.attitudeInitCandidateImprovement_deg = ai16.candidateImprovement_deg; end
                if isfield(ai16,'shadowMode'); entry.attitudeInitShadowMode = ai16.shadowMode; end
            end

            % --- Append to log ----------------------------------------
            obj.nEpochs = obj.nEpochs + 1;
            if obj.nEpochs == 1
                obj.log = entry;
            else
                obj.log(obj.nEpochs) = entry;
            end
        end

        % ================================================================
        %  GETTERS
        % ================================================================

        function t = getTimeVector(obj)
            t = [obj.log.time_s]';
        end

        function e = getPositionErrors(obj)
            e = [obj.log.positionError_m]';
        end

        function e = getPositionErrorVecs(obj)
            % Returns [3 x nEpochs] matrix
            e = cell2mat({obj.log.positionErrorVec_m});
        end

        function e = getClockBiasErrors(obj)
            e = [obj.log.clockBiasError_m]';
        end

        function e = getClockDriftErrors(obj)
            e = [obj.log.clockDriftError_mps]';
        end

        function e = getFractionalFrequencyErrors(obj)
            e = [obj.log.fracFreqError]';
        end

        function n = getNIS(obj)
            n = [obj.log.NIS]';
        end

        function nu = getPrefitInnovationRMS(obj)
            nu = [obj.log.prefitInnovationRMS]';
        end

        function res = getPostfitResidualRMS(obj)
            res = [obj.log.postfitResidualRMS]';
        end

        function nv = getNumVisibleTowers(obj)
            nv = [obj.log.numVisibleTowers]';
        end

        function nm = getNumMeasurements(obj)
            nm = [obj.log.numMeasurements]';   % pseudorange count
        end

        function nr = getNumMeasurementRows(obj)
            % getNumMeasurementRows  Total EKF z dimension (PR + Doppler if in EKF).
            nr = [obj.log.numMeasurementRows]';
        end

        function [sumNIS, dof, passes] = accumulatedNISTest(obj, nSigma)
            % accumulatedNISTest  Chi-squared NIS consistency check (Issue 7).
            %
            % CHANGED: v3→v4 — Issue 7
            % Under correct filter: sumNIS ~ chi²(dof) where dof = sum of per-epoch M_k.
            % E[sumNIS] = dof,  Var[sumNIS] = 2*dof
            % Test: |sumNIS - dof| < nSigma * sqrt(2*dof)
            % Reference: Bar-Shalom et al., "Estimation with Applications to
            %   Tracking and Navigation", 2001.
            %
            % Mean NIS per epoch is NOT used for the formal test because
            % NIS_k / M_k ≈ 1 only approximately when M_k varies.
            if nargin < 2; nSigma = 3; end
            nisVec  = obj.getNIS();
            mVec    = obj.getNumMeasurementRows();
            valid   = isfinite(nisVec) & isfinite(mVec) & mVec > 0;
            sumNIS  = sum(nisVec(valid));
            dof     = sum(mVec(valid));
            if dof > 0
                passes = abs(sumNIS - dof) < nSigma * sqrt(2 * dof);
            else
                passes = false;
            end
        end

        function v = getPrefitPseudorangeRMS(obj)
            v = [obj.log.prefitPseudorangeRMS_m]';
        end

        function v = getPostfitPseudorangeRMS(obj)
            v = [obj.log.postfitPseudorangeRMS_m]';
        end

        function v = getPrefitDopplerRMS(obj)
            v = [obj.log.prefitDopplerRMS_mps]';
        end

        function v = getPostfitDopplerRMS(obj)
            v = [obj.log.postfitDopplerRMS_mps]';
        end

        function C = getContributionSeries(obj)
            % getContributionSeries  Per-effect contribution time series.
            %
            % Returns nested struct:
            %   C.effectName.truthRMS_m    [nEpochs x 1]
            %   C.effectName.modelRMS_m    [nEpochs x 1]
            %   C.effectName.mismatchRMS_m [nEpochs x 1]
            %   (Doppler: _mps suffix; carrier: _cycles suffix)
            if obj.nEpochs == 0; C = struct(); return; end
            C = struct();
            effects = fieldnames(obj.log(1).contributions);
            for ei = 1:numel(effects)
                eff = effects{ei};
                if strcmp(eff, 'bySignal'); continue; end  % handled by getBySignalContributions
                sflds = fieldnames(obj.log(1).contributions.(eff));
                for fi = 1:numel(sflds)
                    fld  = sflds{fi};
                    vals = zeros(obj.nEpochs, 1);
                    for k = 1:obj.nEpochs
                        v = obj.log(k).contributions.(eff).(fld);
                        if ~isempty(v) && isnumeric(v); vals(k) = v(1); end
                    end
                    C.(eff).(fld) = vals;
                end
            end
        end

        function B = getBySignalContributions(obj)
            % getBySignalContributions  Per-signal contribution time series.
            %
            % Returns nested struct:
            %   B.L1.codeNoise.truthRMS_m    [nEpochs x 1]
            %   B.L1.ionosphere.mismatchRMS_m
            %   B.L1.codeSigma_m             [nEpochs x 1]  (scalar per epoch, not rms3m)
            %   etc.
            if obj.nEpochs == 0; B = struct(); return; end
            B = struct();
            bs = obj.log(1).contributions.bySignal;
            if isempty(fieldnames(bs)); return; end
            sigNames = fieldnames(bs);
            for si = 1:numel(sigNames)
                nm   = sigNames{si};
                effs = fieldnames(bs.(nm));
                for ei = 1:numel(effs)
                    eff = effs{ei};
                    v1  = bs.(nm).(eff);
                    if isstruct(v1)
                        % rms3m struct: iterate sub-fields
                        sflds = fieldnames(v1);
                        for fi = 1:numel(sflds)
                            fld  = sflds{fi};
                            vals = zeros(obj.nEpochs, 1);
                            for k = 1:obj.nEpochs
                                try
                                    v = obj.log(k).contributions.bySignal.(nm).(eff).(fld);
                                    if ~isempty(v) && isnumeric(v); vals(k) = v(1); end
                                catch; end
                            end
                            B.(nm).(eff).(fld) = vals;
                        end
                    elseif isnumeric(v1)
                        vals = zeros(obj.nEpochs, 1);
                        for k = 1:obj.nEpochs
                            try
                                v = obj.log(k).contributions.bySignal.(nm).(eff);
                                if ~isempty(v) && isnumeric(v); vals(k) = v(1); end
                            catch; end
                        end
                        B.(nm).(eff) = vals;
                    end
                end
            end
        end

        function v = getSagnacDiffRMS(obj)
            v = [obj.log.sagnacDiffRMS_m]';
        end

        function v = getShapiroDiffRMS(obj)
            v = [obj.log.shapiroDiffRMS_m]';
        end

        function e = getAttitudeErrorVecs(obj)
            % Returns [3 x nEpochs] matrix of attitude errors [rad]
            e = cell2mat({obj.log.attitudeError_rad});
        end

        function perSrc = getPerSourceErrorRMS(obj)
            % getPerSourceErrorRMS  RMS(truth_m - model_m) per source per epoch [m].
            % Title: "Truth - Model" residual RMS.
            labels = {'code','trop','iono','hwDelay','mp'};
            for j = 1:numel(labels)
                lbl = labels{j};
                vals = zeros(obj.nEpochs, 1);
                for k = 1:obj.nEpochs
                    ps = obj.log(k).perSourceTruthRMS;
                    if isfield(ps, lbl)
                        vals(k) = ps.(lbl);
                    end
                end
                perSrc.(lbl) = vals;
            end
        end

        function M = getTowerClockBiasMatrix(obj)
            % Returns cell array [nEpochs x 1] of tower clock truth biases [m].
            % Each cell contains [M_visible x 1] vector (visible towers that epoch).
            M = cell(obj.nEpochs, 1);
            for k = 1:obj.nEpochs
                M{k} = obj.log(k).towerClockTruth_m;
            end
        end

        function v = getGDOPLike(obj)
            v = [obj.log.gdopLike]';
        end

        function v = getPDOPLike(obj)
            v = [obj.log.pdopLike]';
        end

        function v = getTDOPLike(obj)
            v = [obj.log.tdopLike]';
        end

        function v = getGeometryRank(obj)
            v = [obj.log.geometryRank]';
        end

        function v = getAttitudeRank(obj)
            % CHANGED: v3→v4 — Issue 8
            v = [obj.log.attitudeRank]';
        end

        function v = getAttitudeStatus(obj)
            % CHANGED: v3→v4 — Issue 8
            v = {obj.log.attitudeStatus}';
        end

        function C = getNISByType(obj)
            % getNISByType  Per-type normalized innovation series [nEpochs x 1].
            %
            % Returns struct with fields: code, doppler, carrier.
            % Each is sum((inn_k)^2 / R_kk) for the relevant measurement type.
            % These are prefit chi-squared diagnostics, NOT the full EKF NIS
            % (which uses S = H*P*H'+R).  E[NIS_k/dof_k] approx 1 in steady state.
            C.code    = [obj.log.NIS_code]';
            C.doppler = [obj.log.NIS_doppler]';
            C.carrier = [obj.log.NIS_carrier]';
        end

        function v = getNEES(obj)
            % getNEES  Position NEES (Normalized Estimation Error Squared) [nEpochs x 1].
            %
            % NEES_pos = r_err' * P_pos^{-1} * r_err / 3.
            % Under a consistent filter, E[NEES_pos] = 1.
            % Values >> 1: filter is too optimistic (P too small).
            % Values << 1: filter is too pessimistic (P too large).
            v = [obj.log.NEES_pos]';
        end

        function v = getClockGaugeRowsAdded(obj)
            % getClockGaugeRowsAdded  Number of gauge pseudo-rows inserted per epoch.
            % Zero when tower clocks are not in EKF or gauge is 'externalTowerCorrections'.
            if isempty(obj.log); v = []; return; end
            v = [obj.log.clockGaugeRowsAdded]';
        end

        function v = getClockSubspaceRank(obj)
            % getClockSubspaceRank  Numerical rank of H restricted to clock columns.
            % Should equal nClockStates when gauge removes the nullspace.
            if isempty(obj.log); v = []; return; end
            v = [obj.log.clockSubspaceRank]';
        end

        function v = getClockSubspaceCondNum(obj)
            % getClockSubspaceCondNum  Condition number of H_clock (sv_max / sv_min).
            if isempty(obj.log); v = []; return; end
            v = [obj.log.clockSubspaceCondNum]';
        end

        function v = getClockGaugeBiasResiduals(obj)
            % getClockGaugeBiasResiduals  Tower clock bias gauge residual per epoch [m].
            % fixReferenceTower: reference tower bias state value.
            % meanGroundClockGauge: mean of all tower bias states.
            if isempty(obj.log); v = []; return; end
            v = [obj.log.clockGaugeBiasResidual_m]';
        end

        function v = getClockGaugeDriftResiduals(obj)
            % getClockGaugeDriftResiduals  Tower clock drift gauge residual per epoch [m/s].
            if isempty(obj.log); v = []; return; end
            v = [obj.log.clockGaugeDriftResidual_mps]';
        end

        function v = getClockObsRankPhysical(obj)
            % getClockObsRankPhysical  Clock-subspace Gramian rank (physical meas only) per epoch.
            % NaN before the sliding window fills (minWindowEpochs).
            % Should equal n_clk-1 for one-way pseudorange (common bias nullspace persists).
            if isempty(obj.log); v = []; return; end
            v = [obj.log.clockObsRankPhysical]';
        end

        function v = getClockObsRankGauged(obj)
            % getClockObsRankGauged  Clock-subspace Gramian rank (physical + gauge) per epoch.
            % Should equal n_clk when the gauge removes the common-bias nullspace.
            if isempty(obj.log); v = []; return; end
            v = [obj.log.clockObsRankGauged]';
        end

        function v = getClockObsCondPhysical(obj)
            % getClockObsCondPhysical  Gramian condition number (physical only) per epoch.
            if isempty(obj.log); v = []; return; end
            v = [obj.log.clockObsCondPhysical]';
        end

        function v = getClockObsCondGauged(obj)
            % getClockObsCondGauged  Gramian condition number (physical + gauge) per epoch.
            if isempty(obj.log); v = []; return; end
            v = [obj.log.clockObsCondGauged]';
        end

        function v = getClockObsWeakStatesPhysical(obj)
            % getClockObsWeakStatesPhysical  Number of clock states below rank tolerance (physical only).
            if isempty(obj.log); v = []; return; end
            v = [obj.log.clockObsWeakPhysical]';
        end

        function v = getClockObsWeakStatesGauged(obj)
            % getClockObsWeakStatesGauged  Number of clock states below rank tolerance (gauged).
            % Should be 0 when the gauge fully constrains the clock subspace.
            if isempty(obj.log); v = []; return; end
            v = [obj.log.clockObsWeakGauged]';
        end

        % --- Tx code bias gauge getters ------------------------------------

        function v = getTxCodeBiasGaugeRowsAdded(obj)
            % getTxCodeBiasGaugeRowsAdded  Tx-code-delay gauge rows inserted per epoch.
            % 0 when estimateTxCodeBias is off; 1 when fixReferenceTower gauge is active.
            if isempty(obj.log); v = []; return; end
            v = [obj.log.txCodeBiasGaugeRowsAdded]';
        end

        function v = getTxCodeBiasGaugeResiduals(obj)
            % getTxCodeBiasGaugeResiduals  Tx code delay gauge residual per epoch [m].
            % fixReferenceTower: reference-tower delay state value (should converge near 0).
            % meanGroundDelayGauge: mean of all tower delay states.
            if isempty(obj.log); v = []; return; end
            v = [obj.log.txCodeBiasGaugeResidual_m]';
        end

        function v = getTxCodeBiasStatesEnabled(obj)
            % getTxCodeBiasStatesEnabled  True when tx code bias states are in the EKF.
            if isempty(obj.log); v = []; return; end
            v = [obj.log.txCodeBiasStatesEnabled]';
        end

        function v = getNTxCodeBiasStates(obj)
            % getNTxCodeBiasStates  Number of tx code bias states per epoch.
            if isempty(obj.log); v = []; return; end
            v = [obj.log.nTxCodeBiasStates]';
        end

        % --- Carrier slip getters (Stage 14) --------------------------------

        function v = getCarrierSlipNSlips(obj)
            % getCarrierSlipNSlips  Number of cycle slips detected per epoch.
            if isempty(obj.log); v = []; return; end
            v = [obj.log.carrierSlipNSlips]';
        end

        function v = getCarrierSlipTotalJump(obj)
            % getCarrierSlipTotalJump  Sum of jump magnitudes per epoch [m].
            if isempty(obj.log); v = []; return; end
            v = [obj.log.carrierSlipTotalJump_m]';
        end

        function v = isZwdEstimated(obj)
            % isZwdEstimated  True when any epoch logged a ZWD state.
            if isempty(obj.log); v = false; return; end
            v = any([obj.log.zwdEstimated]);
        end

        function v = getZwdEstimates(obj)
            % getZwdEstimates  Per-epoch ZWD estimates [epochs × nTowers] or empty.
            if isempty(obj.log); v = []; return; end
            all_v = {obj.log.zwdEst_m};
            nonempty = find(~cellfun(@isempty, all_v), 1);
            if isempty(nonempty); v = []; return; end
            n = numel(all_v{nonempty});
            v = zeros(numel(all_v), n);
            for k = 1:numel(all_v)
                if ~isempty(all_v{k}) && numel(all_v{k}) == n
                    v(k,:) = all_v{k}';
                end
            end
        end

        function v = getZwdEstimateRms(obj)
            % getZwdEstimateRms  Per-tower RMS of ZWD estimates [m].
            v = [];
            zwd = obj.getZwdEstimates();
            if isempty(zwd); return; end
            v = sqrt(mean(zwd.^2, 1))';
        end

    end

    methods (Static)
        function v = fieldOr_(s, f, def)
            if isstruct(s) && isfield(s, f)
                v = s.(f);
            else
                v = def;
            end
        end
    end
end
