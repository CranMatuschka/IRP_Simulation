classdef CodeJacobianBuilder
    % CodeJacobianBuilder  Builds the pseudorange measurement Jacobian H.
    %
    % Extracted from MeasurementModel.computeJacobian_ (Stage 12A Step 5).
    % Stage 56: geometry/Jacobian paths delegated to LinkGeometry.

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

            doFD   = revgnss.MeasurementModelUtils.needsFiniteDiffH_(cfg);
            step_e = attitudeJacStep_rad;

            for mi = 1:M
                ti = twr_list(mi);
                ai = ant_list(mi);

                % Shared analytic geometry — used for diagnostic, ZWD elevation, and
                % analytic position Jacobian when corrections are off.
                g = revgnss.LinkGeometry.analyticLosJacobian( ...
                    cfg, towers, ti, ai, r_cm_est, euler_est, leverArms_model);

                % Lever-arm ratio diagnostic (Issue 13)
                leverNorm = norm(leverArms_model(:, ai));
                if g.range_m > 0 && leverNorm / g.range_m > 1e-4 && ...
                        leverNorm > 1e-9 && mod(mi, max(1, numel(twr_list))) == 1
                    warning('revgnss:leverArmRatio', ...
                        'Lever arm / slant range = %.2e; atmosphere attitude derivatives may not be negligible.', ...
                        leverNorm / g.range_m);
                end

                % Position Jacobian (FD accounts for all corrections; analytic for clean geometry)
                if doFD
                    H(mi, stateMap.r_idx) = revgnss.LinkGeometry.finiteDiffPositionJacobian( ...
                        cfg, towers, ti, ai, r_cm_est, euler_est, leverArms_model, 1.0);
                else
                    H(mi, stateMap.r_idx) = g.losRow;
                end

                % Attitude FD (gated by config + non-zero lever)
                attGate = revgnss.LinkGeometry.shouldUseAttitudePartials(cfg, 'code');
                if attGate.enabled && leverNorm > 1e-9
                    H(mi, stateMap.euler_idx) = revgnss.LinkGeometry.finiteDiffAttitudeJacobian( ...
                        cfg, towers, ti, ai, r_cm_est, euler_est, leverArms_model, step_e);
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

                % ZWD Jacobian: H(mi, zwdIdx) = mapping_factor (same sign as code)
                if isfield(stateMap,'zwdIdx') && ...
                        ti <= numel(stateMap.zwdIdx) && stateMap.zwdIdx(ti) > 0
                    mf_z = revgnss.MappingFunctions.troposphere(g.elevation_rad, ...
                        revgnss.MeasurementModelUtils.zwdMappingKind(cfg));
                    H(mi, stateMap.zwdIdx(ti)) = mf_z;
                end
            end
        end

    end  % Static methods
end
