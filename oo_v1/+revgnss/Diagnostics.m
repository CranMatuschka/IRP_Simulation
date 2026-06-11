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
    end

    methods
        function obj = Diagnostics()
            obj.log = struct([]);
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
            % Pseudorange rows [m] and Doppler rows [m/s] are NEVER mixed.
            if ~isempty(z) && M_pr > 0 && numel(z) >= M_pr
                innPR = z(1:M_pr) - h(1:M_pr);
                entry.prefitPseudorangeRMS_m  = sqrt(mean(innPR.^2));
                entry.prefitInnovationRMS     = entry.prefitPseudorangeRMS_m;
                if numel(z) > M_pr
                    innDop = z(M_pr+1:end) - h(M_pr+1:end);
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
                if numel(postfitResidual) > M_pr
                    resDop = postfitResidual(M_pr+1:end);
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

            % --- Jacobian diagnostics ----------------------------------
            if ~isempty(H) && size(H,2) >= 9
                H_att = H(:, sm.euler_idx);
                entry.attitudeJacobianNorm = norm(H_att, 'fro');
                % Warn only when attitude estimation from pseudorange is expected but
                % the Jacobian is near-zero (i.e. lever arm/geometry problem).
                % Suppress when estimateAttitudeFromPseudorange = false (by design).
                % Note: Diagnostics has no direct access to cfg; the EKF carries the flag.
                % We use the heuristic: if every euler_idx column of H is exactly zero
                % AND the omega_idx columns are also zero, the filter zeroed them on purpose.
                % A simple epoch-throttled warning is only emitted when the H columns
                % are non-trivially structured (rank > 0 excluding att columns) but att
                % columns are still zero — meaning something unexpected happened.
                % In practice, for the default config we simply skip the warning.
                if entry.attitudeJacobianNorm < 1e-10 && ~isempty(H) && ...
                        mod(obj.nEpochs+1,500) == 1
                    % Check whether omega columns are also zero (expected in gated mode)
                    H_omg = H(:, sm.omega_idx);
                    if norm(H_omg,'fro') > 1e-10
                        % Omega columns nonzero but euler columns zero — unexpected
                        warning('Diagnostics:zeroAttJac', ...
                            'Attitude Jacobian is near-zero at t=%.0f s. Check lever arm.', t_s);
                    end
                    % else: both euler and omega columns zero = intentional gating, no warn
                end
            else
                entry.attitudeJacobianNorm = 0;
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

            % --- Per-effect contribution RMS --------------------------------
            % All values are RMS of the truth-model mismatch vector for that effect.
            % Fields are zero when the effect is disabled or data is absent.
            cnt = struct();
            cnt.codeNoise_rms_m          = 0;
            cnt.troposphere_rms_m        = 0;
            cnt.ionosphere_rms_m         = 0;
            cnt.hardwareDelay_rms_m      = 0;
            cnt.multipath_rms_m          = 0;
            cnt.sagnacTruthMinusModel_rms_m      = 0;
            cnt.shapiroTruthMinusModel_rms_m     = 0;
            cnt.towerSurveyTruthMinusModel_rms_m = 0;
            cnt.receiverPCOTruthMinusModel_rms_m = 0;
            cnt.towerPCOTruthMinusModel_rms_m    = 0;
            cnt.pcvTruthMinusModel_rms_m         = 0;
            cnt.towerClockCorrectionError_rms_m  = 0;
            cnt.correlatedCommonMode_rms_m       = 0;
            cnt.correlatedSameTower_rms_m        = 0;
            cnt.correlatedIndependent_rms_m      = 0;
            cnt.totalTruthMinusModel_rms_m       = 0;
            cnt.dopplerPrefit_rms_mps                        = 0;
            cnt.dopplerTowerClockDriftTruthMinusModel_rms_mps = 0;
            cnt.carrierPhase_rms_cycles = 0;
            cnt.carrierPhase_rms_m      = 0;

            if ~isempty(errStruct)
                % ErrorChain per-source (truth - model) contributions
                if isfield(errStruct,'bySource') && isfield(errStruct.bySource,'truth_m')
                    bst = errStruct.bySource.truth_m;
                    bsm = errStruct.bySource.model_m;
                    srcMap = {'code','codeNoise'; 'trop','troposphere'; ...
                              'iono','ionosphere'; 'hwDelay','hardwareDelay'; 'mp','multipath'};
                    for si = 1:size(srcMap,1)
                        src = srcMap{si,1}; fld = srcMap{si,2};
                        if isfield(bst,src) && ~isempty(bst.(src))
                            diff_v = bst.(src) - bsm.(src);
                            cnt.([fld '_rms_m']) = sqrt(mean(diff_v.^2));
                        end
                    end
                end
                % Sagnac / Shapiro
                cnt.sagnacTruthMinusModel_rms_m  = entry.sagnacDiffRMS_m;
                cnt.shapiroTruthMinusModel_rms_m = entry.shapiroDiffRMS_m;
                % PCV
                if isfield(errStruct,'pcvTruth_m') && ~isempty(errStruct.pcvTruth_m)
                    pcv_diff = errStruct.pcvTruth_m - errStruct.pcvModel_m;
                    cnt.pcvTruthMinusModel_rms_m = sqrt(mean(pcv_diff.^2));
                end
                % Tower survey
                if isfield(errStruct,'towerSurveyTruth_m') && ~isempty(errStruct.towerSurveyTruth_m)
                    sv_diff = errStruct.towerSurveyTruth_m - errStruct.towerSurveyModel_m;
                    cnt.towerSurveyTruthMinusModel_rms_m = sqrt(mean(sv_diff.^2));
                end
                % Receiver PCO
                if isfield(errStruct,'receiverPCOTruth_m') && ~isempty(errStruct.receiverPCOTruth_m)
                    rp_diff = errStruct.receiverPCOTruth_m - errStruct.receiverPCOModel_m;
                    cnt.receiverPCOTruthMinusModel_rms_m = sqrt(mean(rp_diff.^2));
                end
                % Tower PCO
                if isfield(errStruct,'towerPCOTruth_m') && ~isempty(errStruct.towerPCOTruth_m)
                    tp_diff = errStruct.towerPCOTruth_m - errStruct.towerPCOModel_m;
                    cnt.towerPCOTruthMinusModel_rms_m = sqrt(mean(tp_diff.^2));
                end
                % Tower clock correction error
                if ~isempty(entry.towerClockCorrectionError_m)
                    cnt.towerClockCorrectionError_rms_m = ...
                        sqrt(mean(entry.towerClockCorrectionError_m.^2));
                end
                % Correlated noise components
                if isfield(errStruct,'correlatedNoise')
                    cn = errStruct.correlatedNoise;
                    if isfield(cn,'common_m')
                        cnt.correlatedCommonMode_rms_m = sqrt(mean(cn.common_m.^2));
                    end
                    if isfield(cn,'sameTower_m')
                        cnt.correlatedSameTower_rms_m = sqrt(mean(cn.sameTower_m.^2));
                    end
                    if isfield(cn,'independent_m')
                        cnt.correlatedIndependent_rms_m = sqrt(mean(cn.independent_m.^2));
                    end
                end
                % Total truth-model deterministic mismatch
                if ~isempty(errStruct.truthTotal_m)
                    total_diff = (errStruct.truthTotal_m - errStruct.modelTotal_m) + ...
                        (errStruct.sagnacTruth_m - errStruct.sagnacModel_m) + ...
                        (errStruct.shapiroTruth_m - errStruct.shapiroModel_m) + ...
                        (errStruct.pcvTruth_m - errStruct.pcvModel_m);
                    if isfield(errStruct,'towerSurveyTruth_m')
                        total_diff = total_diff + errStruct.towerSurveyTruth_m - errStruct.towerSurveyModel_m;
                    end
                    if isfield(errStruct,'receiverPCOTruth_m')
                        total_diff = total_diff + errStruct.receiverPCOTruth_m - errStruct.receiverPCOModel_m;
                    end
                    if isfield(errStruct,'towerPCOTruth_m')
                        total_diff = total_diff + errStruct.towerPCOTruth_m - errStruct.towerPCOModel_m;
                    end
                    cnt.totalTruthMinusModel_rms_m = sqrt(mean(total_diff.^2));
                end
                % Doppler
                cnt.dopplerPrefit_rms_mps = entry.dopplerPrefitRMS_mps;
                if isfield(errStruct,'doppler') && ...
                        isfield(errStruct.doppler,'towerClockDriftTruth_mps') && ...
                        ~isempty(errStruct.doppler.towerClockDriftTruth_mps)
                    bdot_diff = errStruct.doppler.towerClockDriftTruth_mps - ...
                                errStruct.doppler.towerClockDriftModel_mps;
                    cnt.dopplerTowerClockDriftTruthMinusModel_rms_mps = sqrt(mean(bdot_diff.^2));
                end
                % Carrier phase
                if isfield(errStruct,'carrierPhase') && ...
                        isfield(errStruct.carrierPhase,'phi_cycles') && ...
                        ~isempty(errStruct.carrierPhase.phi_cycles)
                    phi = errStruct.carrierPhase.phi_cycles;
                    lam = errStruct.carrierPhase.lambda_m;
                    cnt.carrierPhase_rms_cycles = sqrt(mean(phi.^2));
                    cnt.carrierPhase_rms_m      = cnt.carrierPhase_rms_cycles * lam;
                end
            end
            entry.contributions = cnt;

            % --- 1-sigma position bound from P diagonal ---------------
            Pdiag = diag(ekf.P);
            entry.estimatedPositionSigma_m   = sqrt(sum(Pdiag(sm.r_idx)));
            entry.estimatedAttitudeSigma_rad = sqrt(sum(Pdiag(sm.euler_idx)));

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

        function cs = getContributionSeries(obj)
            % getContributionSeries  All contribution time series as struct of vectors.
            if obj.nEpochs == 0; cs = struct(); return; end
            flds = fieldnames(obj.log(1).contributions);
            for fi = 1:numel(flds)
                f = flds{fi};
                vals = zeros(obj.nEpochs, 1);
                for k = 1:obj.nEpochs
                    v = obj.log(k).contributions.(f);
                    if ~isempty(v); vals(k) = v; end
                end
                cs.(f) = vals;
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

    end
end
