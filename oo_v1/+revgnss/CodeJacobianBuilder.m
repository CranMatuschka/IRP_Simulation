classdef CodeJacobianBuilder
    % CodeJacobianBuilder  Builds the pseudorange measurement Jacobian H.
    %
    % Extracted from MeasurementModel.computeJacobian_ (Stage 12A Step 5).
    % All physics are preserved exactly — pure structural refactor.

    methods (Static)

        function H = build(cfg, attitudeJacStep_rad, towers, twr_list, ant_list, ...
                r_cm_est, euler_est, leverArms_model, x_est, stateMap, nx)
            % build  Measurement Jacobian (analytic or finite-difference).
            %
            % If any model-side correction is on (Sagnac, Shapiro, PCV, PCO)
            % OR cfg.estimator.forceFiniteDifferenceH=true, use FD for r and euler columns.
            % Clock columns remain analytic: b_rx=+1, b_twr=-1.
            %
            % V1 APPROXIMATION: Attitude derivatives of tropospheric and
            % ionospheric corrections through lever-arm-induced elevation changes
            % are ignored.  This is valid when:
            %     leverArmLength_m << slantRange_m   AND
            %     atmospheric correction gradient is small.

            M = numel(twr_list);
            H = zeros(M, nx);

            doFD = revgnss.MeasurementModel.needsFiniteDiffH_(cfg);

            doAttJac = isfield(cfg.estimator, 'estimateAttitude') && ...
                       cfg.estimator.estimateAttitude && ...
                       isfield(cfg.estimator, 'estimateAttitudeFromPseudorange') && ...
                       cfg.estimator.estimateAttitudeFromPseudorange;

            step_e = attitudeJacStep_rad;

            for mi = 1:M
                ti    = twr_list(mi);
                ai    = ant_list(mi);
                lever = leverArms_model(:, ai);

                if doFD
                    % Finite-difference position columns (accounts for all corrections)
                    step_r = 1.0;
                    for ki = 1:3
                        r_p = r_cm_est; r_p(ki) = r_p(ki) + step_r;
                        r_m = r_cm_est; r_m(ki) = r_m(ki) - step_r;
                        hp = revgnss.MeasurementModel.modelRangeOnly( ...
                            cfg, towers, ti, ai, r_p, euler_est, leverArms_model);
                        hm = revgnss.MeasurementModel.modelRangeOnly( ...
                            cfg, towers, ti, ai, r_m, euler_est, leverArms_model);
                        H(mi, stateMap.r_idx(ki)) = (hp - hm) / (2*step_r);
                    end
                else
                    % Analytic position Jacobian: u' using model tower position + PCO lever
                    r_twr = revgnss.MeasurementModel.towerPositionEcef(cfg, towers{ti}, ti, 'model');
                    r_ant = revgnss.AttitudeKinematics.applyLeverArm(r_cm_est, euler_est, lever);
                    delta = r_ant - r_twr;
                    rho   = norm(delta); if rho < 1; rho = 1; end
                    H(mi, stateMap.r_idx) = (delta / rho)';
                end

                % Lever-arm ratio diagnostic (Issue 13)
                r_twr_diag = revgnss.MeasurementModel.towerPositionEcef(cfg, towers{ti}, ti, 'model');
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
                        hp = revgnss.MeasurementModel.modelRangeOnly( ...
                            cfg, towers, ti, ai, r_cm_est, eul_p, leverArms_model);
                        hm = revgnss.MeasurementModel.modelRangeOnly( ...
                            cfg, towers, ti, ai, r_cm_est, eul_m, leverArms_model);
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

                % Tx code hardware-delay Jacobian: +1
                if isfield(stateMap,'txCodeBiasIdx') && ...
                        ti <= numel(stateMap.txCodeBiasIdx) && ...
                        stateMap.txCodeBiasIdx(ti) > 0
                    H(mi, stateMap.txCodeBiasIdx(ti)) = 1;
                end
            end
        end

    end  % Static methods
end
