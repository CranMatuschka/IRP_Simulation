classdef ReportDataBuilder
    %REPORTDATABUILDER Builds reportData from a completed ReverseGnssSimulation.
    %
    % This class owns the mapping from simulation state/history/results into
    % the reportData struct consumed by generateReport.m. It should not create
    % final report tables or figures.

    methods (Static)
        function reportData = fromSimulation(sim)
            xHist = sim.history.x;
            truthHist = sim.history.truth;
            Pdiag = sim.history.covariance_diag;

            reportData = struct();

            reportData.time_vec = sim.time_s;
            reportData.total_time_hours = max(sim.time_s) / 3600.0;
            reportData.dt = sim.dt;
            reportData.c = sim.c;
            reportData.num_towers = sim.numTowers;
            reportData.R_earth = sim.constants.earthRadius_m;
            reportData.oscillators = sim.simConfig.clockLibrary;
            reportData.towers = ReportDataBuilder.reportTowers(sim);
            reportData.tower_names = sim.towerNames;
            reportData.receiver_names = sim.receiverNames;

            % Raw inputs used by generateReport.m to build report-specific tables.
            reportData.asset_name = string(sim.assetConfig.name);
            reportData.state_names = ReportDataBuilder.stateNames(sim);
            reportData.state_dim = sim.stateDim;
            reportData.state_index = sim.idx;
            reportData.enable_tower_clock_ekf = ReportDataBuilder.towerClockEkfEnabled(sim);
            reportData.num_receivers = sim.numReceivers;
            reportData.receiver_offsets_body_m = sim.receiverOffsetsBody_m;
            reportData.initial_truth_position_eci_m = sim.initialTruth0(sim.idx.pos);
            reportData.initial_est_position_eci_m = sim.initialX0(sim.idx.pos);
            reportData.observability_normal_matrix = sim.observabilityNormalMatrix;

            reportData.ekf_pos_error_m = xHist(sim.idx.pos, :) - truthHist(sim.idx.pos, :);
            reportData.ekf_pos_sigma_m = sqrt(max(Pdiag(sim.idx.pos, :), 0));
            reportData.ekf_clock_error_ps = ...
                (xHist(sim.idx.rxClockBias, :) - truthHist(sim.idx.rxClockBias, :)) ./ sim.c .* 1e12;
            reportData.ekf_clock_sigma_ps = ...
                sqrt(max(Pdiag(sim.idx.rxClockBias, :), 0)) ./ sim.c .* 1e12;
            reportData.true_clock_bias_ps = truthHist(sim.idx.rxClockBias, :) ./ sim.c .* 1e12;
            reportData.est_clock_bias_ps = xHist(sim.idx.rxClockBias, :) ./ sim.c .* 1e12;

            if ReportDataBuilder.towerClockEkfEnabled(sim)
                reportData.est_tower_clock_bias_ps = ...
                    xHist(sim.idx.towerClockBias, :) ./ sim.c .* 1e12;

                reportData.true_tower_clock_bias_ps = ...
                    truthHist(sim.idx.towerClockBias, :) ./ sim.c .* 1e12;

                reportData.est_tower_clock_drift_psps = ...
                    xHist(sim.idx.towerClockDrift, :) ./ sim.c .* 1e12;

                reportData.true_tower_clock_drift_psps = ...
                    truthHist(sim.idx.towerClockDrift, :) ./ sim.c .* 1e12;
            end

            reportData.innovation_rms_m = sim.history.innovation_rms_m;
            reportData.postfit_innovation_rms_m = sim.history.postfit_innovation_rms_m;
            reportData.nis_history = sim.history.nis_history;
            reportData.nis_degrees_of_freedom = sim.history.measurement_count;
            reportData.sat_pos_history_m = sim.history.sat_pos_history_m;
            reportData.towers_eci_first_m = sim.towersEciFirst_m;
            reportData.final_position_error_m = norm(reportData.ekf_pos_error_m(:, end));
            reportData.final_clock_error_ps = reportData.ekf_clock_error_ps(end);
            reportData.final_innovation_rms_m = sim.history.innovation_rms_m(end);

            reportData.attitude_truth_deg = rad2deg(truthHist(sim.idx.att, :));
            reportData.attitude_est_deg = rad2deg(xHist(sim.idx.att, :));
            reportData.attitude_error_deg = rad2deg( ...
                FrameGeometry.wrapToPi(xHist(sim.idx.att, :) - truthHist(sim.idx.att, :)));
            reportData.attitude_sigma_deg = rad2deg(sqrt(max(Pdiag(sim.idx.att, :), 0)));
            reportData.attitude_state_names = ["roll"; "pitch"; "yaw"];
            reportData.attitude_frame = "body-to-ECI Euler view of q_BI";

            reportData.angular_velocity_truth_degps = rad2deg(truthHist(sim.idx.omega, :));
            reportData.angular_velocity_est_degps = rad2deg(xHist(sim.idx.omega, :));
            reportData.angular_velocity_error_degps = ...
                rad2deg(xHist(sim.idx.omega, :) - truthHist(sim.idx.omega, :));
            reportData.angular_velocity_sigma_degps = ...
                rad2deg(sqrt(max(Pdiag(sim.idx.omega, :), 0)));
            reportData.angular_velocity_state_names = ["omega_x"; "omega_y"; "omega_z"];
            reportData.final_attitude_error_norm_deg = norm(reportData.attitude_error_deg(:, end));
            reportData.final_angular_velocity_error_norm_degps = ...
                norm(reportData.angular_velocity_error_degps(:, end));

            reportData.final_H_pos_rank = sim.history.H_pos_rank_history(end);
            reportData.final_H_att_rank = sim.history.H_att_rank_history(end);
            reportData.final_H_pos_att_clock_rank = sim.history.H_pos_att_clock_rank_history(end);
            reportData.final_H_pos_column_norm = sim.history.H_pos_column_norm_history(:, end);
            reportData.final_H_att_column_norm = sim.history.H_att_column_norm_history(:, end);
            reportData.final_H_rx_clock_bias_column_norm = ...
                sim.history.H_rx_clock_bias_column_norm_history(end);

            reportData.H_rank_history = sim.history.H_rank_history;
            reportData.H_pos_rank_history = sim.history.H_pos_rank_history;
            reportData.H_att_rank_history = sim.history.H_att_rank_history;
            reportData.H_pos_att_clock_rank_history = sim.history.H_pos_att_clock_rank_history;
            reportData.H_rx_clock_bias_column_norm_history = ...
                sim.history.H_rx_clock_bias_column_norm_history;
            reportData.pseudorange_measurement_count = sim.history.pseudorange_measurement_count;

            reportData.final_H_rank = sim.history.H_rank_history(end);
            reportData.H_row_count_history = sim.history.measurement_count;
            reportData.H_column_count_history = sim.stateDim * ones(1, sim.numSteps);
            reportData.H_rank_to_state_dim_history = ...
                sim.history.H_rank_history ./ max(sim.stateDim, 1);
            reportData.H_state_deficiency_history = ...
                sim.stateDim - sim.history.H_rank_history;
            reportData.final_H_rows = sim.history.measurement_count(end);
            reportData.final_H_columns = sim.stateDim;
            reportData.final_H_rank_to_state_dim = reportData.final_H_rank / max(sim.stateDim, 1);
            reportData.final_H_state_deficiency = sim.stateDim - reportData.final_H_rank;

            reportData.true_ground_clock_bias_ps = sim.history.ground_clock_true_m ./ sim.c .* 1e12;
            reportData.tower_clock_correction_s = sim.history.ground_clock_correction_m ./ sim.c;
            reportData.tower_clock_correction_residual_s = ...
                sim.history.ground_clock_residual_m ./ sim.c;
            reportData.tower_clock_correction_sigma_s = ...
                ones(sim.numTowers, sim.numSteps) .* ...
                sqrt(ReportDataBuilder.groundClockResidualVariance_m2(sim)) ./ sim.c;

            reportData.prefit_residual_by_receiver_tower_m = ...
                sim.history.prefit_residual_by_receiver_tower_m;
            reportData.postfit_residual_by_receiver_tower_m = ...
                sim.history.postfit_residual_by_receiver_tower_m;
            reportData.pseudorange_by_receiver_tower_m = ...
                sim.history.pseudorange_by_receiver_tower_m;
            reportData.true_range_by_receiver_tower_m = ...
                sim.history.true_range_by_receiver_tower_m;
            reportData.los_unit_eci_by_receiver_tower = ...
                sim.history.los_unit_eci_by_receiver_tower;
            reportData.pseudorange_error_by_receiver_tower_m = ...
                sim.history.pseudorange_by_receiver_tower_m - ...
                sim.history.true_range_by_receiver_tower_m;

            reportData.receiver_offset_body_by_receiver_m = sim.receiverOffsetsBody_m;
            reportData.covariance_condition_number = sim.history.covariance_condition_number;
            reportData.innovation_condition_number = sim.history.innovation_condition_number;

            reportData.visible_tower_count = sim.history.visible_tower_count;
            reportData.used_tower_count = sim.history.visible_tower_count;
            reportData.measurementNoiseEnabled = sim.measurementModel.measurementNoiseEnabled();
            reportData.numerical_measurement_sigma_floor_m = ...
                sim.measurementModel.effectiveNumericalMeasurementSigma_m();
            reportData.enableElevationMask = sim.measurementModel.elevationMaskEnabled();
            reportData.elevationMask_deg = sim.measurementModel.elevationMaskDeg();

            if ReportDataBuilder.towerClockEkfEnabled(sim)
                reportData.clockGaugeMode = "towerClockEKF_meanGroundClockGauge";
                reportData.referenceTowerName = "Mean ground-network clock";
                reportData.clock_estimation_mode = 'spacecraftReceiverClockPlusTowerClockEKF';
            else
                if ReportDataBuilder.groundClockCorrectionEnabled(sim)
                    reportData.clockGaugeMode = "externalTowerCorrections";
                    reportData.referenceTowerName = "External ground timing product";
                else
                    reportData.clockGaugeMode = "groundClockResidualsGeneratedButNotEstimated";
                    reportData.referenceTowerName = "";
                end

                reportData.clock_estimation_mode = 'spacecraftReceiverClockOnly';
            end

            reportData.ekf_clock_state_units = 'metres and metres per second';
            reportData.receiver_architecture_note = sprintf( ...
                'N=%d onboard receiver phase centres share one receiver oscillator. Lever arms are Body-frame vectors rotated by q_BI into ECI.', ...
                sim.numReceivers);

            if ReportDataBuilder.towerClockEkfEnabled(sim)
                reportData.signal_model_note = [ ...
                    'Truth code pseudorange: P = rho(r_sc_I + C_BI l_a_B, r_g_I) + b_rx_true - b_g_true + d_truth + noise. ' ...
                    'Estimator prediction: P_hat = rho(rhat_sc_I + Chat_BI l_a_B, r_g_I) + bhat_rx - bhat_g. ' ...
                    'Tower clocks are EKF states and the mean ground-network clock defines the time gauge.'];
            else
                reportData.signal_model_note = [ ...
                    'Truth code pseudorange: P = rho(r_sc_I + C_BI l_a_B, r_g_I) + b_rx_true - b_g_res_true + d_truth + noise. ' ...
                    'Estimator prediction: P_hat = rho(rhat_sc_I + Chat_BI l_a_B, r_g_I) + bhat_rx + d_model. ' ...
                    'In spacecraftReceiverClockOnly mode, b_g_res is not an EKF state and d_model is zero.'];
            end

            reportData.attitude_observability_note = ...
                ['Attitude remains in the EKF for every receiver count. Its pseudorange sensitivity is ' ...
                 '-u^T C_BI skew(l_a_B); zero lever arms produce zero attitude sensitivity naturally.'];
            reportData.attitude_filter_note = ...
                'MEKF-style attitude update uses a body-frame small-angle error injected multiplicatively into q_BI.';

            reportData.measurement_model_equation = [ ...
                "\begin{aligned}"; ...
                "P_{g,a}^{truth}"; ...
                "&= \left\| \mathbf{r}_{sc,I} + \mathbf{C}_{BI}\mathbf{l}_{a,B} - \mathbf{r}_{g,I} \right\|"; ...
                "&= + b_{rx}^{true} - b_{g,res}^{true} + d_{truth} + \nu \\"; ...
                "\hat{P}_{g,a}"; ...
                "&= \left\| \hat{\mathbf{r}}_{sc,I} + \hat{\mathbf{C}}_{BI}\mathbf{l}_{a,B} - \mathbf{r}_{g,I} \right\|"; ...
                "&= + \hat{b}_{rx} + d_{model}, \quad d_{model} = 0"; ...
                "\end{aligned}" ...
                ];

            reportData.observation_matrix_equation = ...
                "H_{g,a} = \left[ \mathbf{u}^{T} \quad \mathbf{0}_{1\times3} \quad \mathbf{u}^{T}(-\mathbf{C}_{BI}[\mathbf{l}_{a,B}]_{\times}) \quad \mathbf{0}_{1\times3} \quad 1 \quad 0 \right]";

            prefitByTower = squeeze(mean(sim.history.prefit_residual_by_receiver_tower_m, 1));
            postfitByTower = squeeze(mean(sim.history.postfit_residual_by_receiver_tower_m, 1));
            reportData.prefit_residual_by_tower_m = prefitByTower;
            reportData.postfit_residual_by_tower_m = postfitByTower;

            nRows = sim.numReceivers * sim.numTowers;
            receiverR2 = sim.cfg.measurement.pseudorangeSigma_m^2 * ...
                double(sim.measurementModel.measurementNoiseEnabled());
            groundR2 = ReportDataBuilder.groundClockResidualVariance_m2(sim);
            actualR2 = sim.measurementModel.measurementVariance( ...
                ReportDataBuilder.towerClockEkfEnabled(sim), ...
                ReportDataBuilder.groundClockResidualVariance_m2(sim));

            reportData.R_receiver_m2 = ones(nRows, sim.numSteps) * receiverR2;
            reportData.R_tower_clock_m2 = ones(nRows, sim.numSteps) * groundR2;
            reportData.R_atmosphere_m2 = zeros(nRows, sim.numSteps);
            reportData.R_hardware_m2 = zeros(nRows, sim.numSteps);
            reportData.R_multipath_m2 = zeros(nRows, sim.numSteps);
            reportData.R_numerical_regularization_m2 = ...
                ones(nRows, sim.numSteps) * max(actualR2 - receiverR2 - groundR2, 0.0);
            reportData.R_total_m2 = reportData.R_receiver_m2 + ...
                reportData.R_tower_clock_m2 + reportData.R_numerical_regularization_m2;

            obs = ReportDataBuilder.observabilityDiagnostics(sim);
            reportData.final_observability_rank = obs.rank;
            reportData.weak_observability_state_names = obs.weakStateNames;
            reportData.observability_note = sprintf( ...
                'Column-normalized accumulated pseudorange observability rank is %d of %d states. Weak states: %s.', ...
                obs.rank, sim.stateDim, strjoin(string(obs.weakStateNames), ', '));

            selectedOsc = sim.simConfig.clockLibrary.(char(sim.assetConfig.clock.clockType));
            selectedClock = Clock(selectedOsc.h0, selectedOsc.hm1, selectedOsc.hm2, sim.dt);
            nAllan = floor(sim.simConfig.validation.allanValidationSamples);

            reportData.tau_profile_s = ReportDataBuilder.validTauForSamples( ...
                sim.simConfig.validation.tauProfile_s, sim.dt, nAllan);

            clockValidationList = [{selectedClock}, GroundNode.clocks(sim.towers)];
            clockNames = ["SpaceAsset RX", sim.towerNames];
            nClock = numel(clockValidationList);
            clockAdev1s = NaN(1, nClock);

            for idxClock = 1:nClock
                [tauThis_s, adevThis, sigmaThis, edfThis] = ...
                    ReportDataBuilder.runClockAllanValidation( ...
                    clockValidationList{idxClock}, ...
                    sim.simConfig.validation.tauSimulation_s, ...
                    sim.dt, nAllan, sim.validationClockStream);

                if idxClock == 1
                    reportData.tau_sim_s = tauThis_s;
                    reportData.sim_adev = adevThis;
                    reportData.sim_adev_sigma = sigmaThis;
                    reportData.sim_adev_edf = edfThis;
                    simAdevByClock = NaN(nClock, numel(tauThis_s));
                end

                simAdevByClock(idxClock, :) = adevThis;
                clockAdev1s(idxClock) = ...
                    clockValidationList{idxClock}.theoreticalAllanDeviation(1.0);
            end

            reportData.selected_allan_deviation_1s = ...
                selectedClock.theoreticalAllanDeviation(1.0);
            reportData.clock_allan_names = clockNames;
            reportData.clock_allan_deviation_1s = clockAdev1s;
            reportData.sim_adev_by_clock = simAdevByClock;
            reportData.seedConfig = sim.seedConfig;
            reportData.source_references = {sprintf('Generated by %s.', sim.entryPointName)};
        end
    end

    methods (Static, Access = private)
        function towers = reportTowers(sim)
            towers = repmat( ...
                struct('name', '', 'lat_deg', 0, 'lon_deg', 0, 'alt_m', 0, 'enabled', true), ...
                1, sim.numTowers);

            for k = 1:sim.numTowers
                towers(k).name = char(sim.towerNames(k));
                towers(k).lat_deg = sim.activeTowerConfig(k).lat_deg;
                towers(k).lon_deg = sim.activeTowerConfig(k).lon_deg;
                towers(k).alt_m = sim.activeTowerConfig(k).alt_m;
                towers(k).enabled = true;
            end
        end

        function names = stateNames(sim)
            names = ["ECI X position [m]"; "ECI Y position [m]"; "ECI Z position [m]"; ...
                "ECI X velocity [m/s]"; "ECI Y velocity [m/s]"; "ECI Z velocity [m/s]"; ...
                "Body attitude error x [rad]"; "Body attitude error y [rad]"; "Body attitude error z [rad]"; ...
                "Body omega x [rad/s]"; "Body omega y [rad/s]"; "Body omega z [rad/s]"; ...
                "RX clock bias relative to ground clock gauge [m]"; ...
                "RX clock drift relative to ground clock gauge [m/s]"];

            if ReportDataBuilder.towerClockEkfEnabled(sim)
                for twr = 1:sim.numTowers
                    names(end + 1, 1) = sprintf( ...
                        '%s clock bias relative to mean ground clock [m]', sim.towerNames(twr));
                    names(end + 1, 1) = sprintf( ...
                        '%s clock drift relative to mean ground clock [m/s]', sim.towerNames(twr));
                end
            end
        end

        function obs = observabilityDiagnostics(sim)
            W = 0.5 * (sim.observabilityNormalMatrix + sim.observabilityNormalMatrix.');
            columnNorm = sqrt(max(diag(W), 0));
            scale = columnNorm;
            scale(scale == 0) = Inf;

            Wn = W ./ (scale * scale.');
            Wn(~isfinite(Wn)) = 0.0;

            s = svd(Wn);
            weak = columnNorm < max(columnNorm) * 1e-8;
            names = ReportDataBuilder.stateNames(sim);

            obs = struct( ...
                'rank', sum(s > 1e-8), ...
                'normalizedSingularValues', s, ...
                'columnNorm', columnNorm, ...
                'weak', weak, ...
                'weakStateNames', names(weak));
        end

        function tauOut = validTauForSamples(tauIn, dt, n)
            m = unique(round(tauIn(:).' ./ dt));
            m = m(isfinite(m) & m >= 1 & 2 .* m < n);
            tauOut = m .* dt;

            if isempty(tauOut)
                tauOut = dt;
            end
        end

        function [tauValid_s, adev, adevSigma, edf] = runClockAllanValidation( ...
                clockTemplate, tauRequested_s, dt, nSamples, validationClockStream)

            nSamples = max(3, floor(double(nSamples)));
            tauValid_s = ReportDataBuilder.validTauForSamples(tauRequested_s, dt, nSamples);

            validationClock = Clock( ...
                clockTemplate.h_0, ...
                clockTemplate.h_minus_1, ...
                clockTemplate.h_minus_2, ...
                dt);

            validationClock.randomStream = validationClockStream;

            phase_s = NaN(nSamples, 1);
            phase_s(1) = validationClock.total_bias_sec;

            for k = 2:nSamples
                validationClock.update(dt);
                phase_s(k) = validationClock.total_bias_sec;
            end

            adev = NaN(1, numel(tauValid_s));
            adevSigma = NaN(1, numel(tauValid_s));
            edf = NaN(1, numel(tauValid_s));

            for k = 1:numel(tauValid_s)
                [adev(k), ~, edf(k), adevSigma(k)] = ...
                    Clock.computeOverlappingAllanDeviation(phase_s, tauValid_s(k), dt);
            end
        end

        function tf = towerClockEkfEnabled(sim)
            tf = logical(ReportDataBuilder.getFieldOrDefault( ...
                sim.cfg, 'enableTowerClockEKF', false));
        end

        function tf = groundClockErrorsEnabled(sim)
            tf = logical(ReportDataBuilder.getFieldOrDefault( ...
                sim.cfg, 'enableGroundClockErrors', false));
        end

        function tf = groundClockCorrectionEnabled(sim)
            tf = logical(ReportDataBuilder.getFieldOrDefault( ...
                sim.cfg, 'enableGroundClockCorrection', true));
        end

        function tf = groundClockCorrectionNoiseEnabled(sim)
            tf = logical(ReportDataBuilder.getFieldOrDefault( ...
                sim.cfg, 'enableGroundClockCorrectionNoise', false));
        end

        function sigma_m = groundClockCorrectionSigma_m(sim)
            sigma_ps = ReportDataBuilder.getScalarField( ...
                sim.cfg, ...
                'groundClockCorrectionSigma_ps', ...
                ReportDataBuilder.getScalarField(sim.cfg, 'externalClockCorrectionSigma_ps', 0.0));

            sigma_m = sim.c * sigma_ps * 1e-12;
        end

        function var_m2 = groundClockResidualVariance_m2(sim)
            if ReportDataBuilder.groundClockErrorsEnabled(sim) && ...
                    ReportDataBuilder.groundClockCorrectionEnabled(sim) && ...
                    ReportDataBuilder.groundClockCorrectionNoiseEnabled(sim)
                var_m2 = ReportDataBuilder.groundClockCorrectionSigma_m(sim)^2;
            else
                var_m2 = 0.0;
            end
        end

        function value = getFieldOrDefault(s, fieldName, defaultValue)
            if isstruct(s) && isfield(s, fieldName)
                value = s.(fieldName);
            else
                value = defaultValue;
            end
        end

        function value = getScalarField(s, fieldName, defaultValue)
            if isstruct(s) && isfield(s, fieldName) && ~isempty(s.(fieldName))
                value = double(s.(fieldName));
            else
                value = double(defaultValue);
            end
        end
    end
end