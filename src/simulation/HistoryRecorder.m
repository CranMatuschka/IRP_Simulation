classdef HistoryRecorder
    %HISTORYRECORDER Allocates and records Reverse-GNSS simulation history.
    %
    % This class owns history struct shape and per-epoch logging. It does not
    % run simulation dynamics, generate measurements, update the EKF, or create
    % reports.

    methods (Static)
        function history = initialize(sim)
            history = struct();

            history.x = NaN(sim.stateDim, sim.numSteps);
            history.truth = NaN(sim.stateDim, sim.numSteps);
            history.covariance_diag = NaN(sim.stateDim, sim.numSteps);

            history.innovation_rms_m = NaN(1, sim.numSteps);
            history.postfit_innovation_rms_m = NaN(1, sim.numSteps);
            history.nis_history = NaN(1, sim.numSteps);
            history.covariance_condition_number = NaN(1, sim.numSteps);
            history.innovation_condition_number = NaN(1, sim.numSteps);

            history.H_row_count_history = NaN(1, sim.numSteps);
            history.H_column_count_history = NaN(1, sim.numSteps);
            history.H_rank_to_state_dim_history = NaN(1, sim.numSteps);
            history.H_state_deficiency_history = NaN(1, sim.numSteps);

            history.H_pos_rank_history = NaN(1, sim.numSteps);
            history.H_att_rank_history = NaN(1, sim.numSteps);
            history.H_pos_att_clock_rank_history = NaN(1, sim.numSteps);
            history.H_pos_column_norm_history = NaN(3, sim.numSteps);
            history.H_att_column_norm_history = NaN(3, sim.numSteps);
            history.H_rx_clock_bias_column_norm_history = NaN(1, sim.numSteps);

            history.measurement_count = zeros(1, sim.numSteps);
            history.pseudorange_measurement_count = zeros(1, sim.numSteps);
            history.visible_tower_count = zeros(1, sim.numSteps);

            history.sat_pos_history_m = NaN(3, sim.numSteps);
            history.receiver_eci_by_receiver = NaN(3, sim.numReceivers, sim.numSteps);
            history.tower_eci_by_tower = NaN(3, sim.numTowers, sim.numSteps);

            history.ground_clock_true_m = NaN(sim.numTowers, sim.numSteps);
            history.ground_clock_correction_m = NaN(sim.numTowers, sim.numSteps);
            history.ground_clock_residual_m = NaN(sim.numTowers, sim.numSteps);
            history.clock_phase_history_s = NaN(1, sim.numSteps);

            history.prefit_residual_by_receiver_tower_m = ...
                NaN(sim.numReceivers, sim.numTowers, sim.numSteps);
            history.postfit_residual_by_receiver_tower_m = ...
                NaN(sim.numReceivers, sim.numTowers, sim.numSteps);
            history.pseudorange_by_receiver_tower_m = ...
                NaN(sim.numReceivers, sim.numTowers, sim.numSteps);
            history.true_range_by_receiver_tower_m = ...
                NaN(sim.numReceivers, sim.numTowers, sim.numSteps);

            history.los_unit_eci_by_receiver_tower = ...
                NaN(3, sim.numReceivers, sim.numTowers, sim.numSteps);
            history.visibility_mask_by_receiver_tower = ...
                false(sim.numReceivers, sim.numTowers, sim.numSteps);
            history.elevation_deg_by_receiver_tower = ...
                NaN(sim.numReceivers, sim.numTowers, sim.numSteps);
        end

        function [history, observabilityNormalMatrix] = record( ...
                sim, history, observabilityNormalMatrix, ...
                estimateVector, truthVector, covarianceDiag, covarianceMatrix, ...
                k, y, innovation, postfit, S, H, nisValue, ...
                trueRangeRt, losRt, receiverEci, towersEci, ...
                groundResidual_m, groundTrue_m, groundCorrection_m, ...
                visibilityMask, elevationRt_deg)

            history.x(:, k) = estimateVector;
            history.truth(:, k) = truthVector;
            history.covariance_diag(:, k) = covarianceDiag;

            history.innovation_rms_m(k) = HistoryRecorder.computeRms(innovation);
            history.postfit_innovation_rms_m(k) = HistoryRecorder.computeRms(postfit);
            history.nis_history(k) = nisValue;
            history.covariance_condition_number(k) = cond(covarianceMatrix);

            if isempty(S)
                history.innovation_condition_number(k) = NaN;
            else
                history.innovation_condition_number(k) = cond(S);
            end

            if isempty(H)
                hRank = 0;
                hRows = 0;
                hCols = sim.stateDim;
            else
                hRank = rank(H);
                hRows = size(H, 1);
                hCols = size(H, 2);
            end

            history.H_rank_history(k) = hRank;
            history.H_row_count_history(k) = hRows;
            history.H_column_count_history(k) = hCols;
            history.H_rank_to_state_dim_history(k) = hRank / max(hCols, 1);
            history.H_state_deficiency_history(k) = hCols - hRank;

            if isempty(H)
                history.H_pos_rank_history(k) = 0;
                history.H_att_rank_history(k) = 0;
                history.H_pos_att_clock_rank_history(k) = 0;
                history.H_pos_column_norm_history(:, k) = 0;
                history.H_att_column_norm_history(:, k) = 0;
                history.H_rx_clock_bias_column_norm_history(k) = 0;
            else
                Hpos = H(:, sim.idx.pos);
                Hatt = H(:, sim.idx.att);
                Hclk = H(:, sim.idx.rxClockBias);

                history.H_pos_rank_history(k) = rank(Hpos);
                history.H_att_rank_history(k) = rank(Hatt);
                history.H_pos_att_clock_rank_history(k) = rank([Hpos, Hatt, Hclk]);

                history.H_pos_column_norm_history(:, k) = vecnorm(Hpos, 2, 1).';
                history.H_att_column_norm_history(:, k) = vecnorm(Hatt, 2, 1).';
                history.H_rx_clock_bias_column_norm_history(k) = norm(Hclk);
            end

            observabilityNormalMatrix = observabilityNormalMatrix + ...
                (H * sim.transitionFromInitial).' * (H * sim.transitionFromInitial);

            history.measurement_count(k) = size(H, 1);
            history.pseudorange_measurement_count(k) = numel(y);
            history.visible_tower_count(k) = sum(any(visibilityMask, 1));

            history.sat_pos_history_m(:, k) = sim.truthAsset.pos_ECI_m;
            history.receiver_eci_by_receiver(:, :, k) = receiverEci;
            history.tower_eci_by_tower(:, :, k) = towersEci;

            history.ground_clock_true_m(:, k) = groundTrue_m(:);
            history.ground_clock_correction_m(:, k) = groundCorrection_m(:);
            history.ground_clock_residual_m(:, k) = groundResidual_m(:);

            if ~isempty(sim.truthAsset.clock)
                history.clock_phase_history_s(k) = sim.truthAsset.clock.total_bias_sec;
            else
                history.clock_phase_history_s(k) = NaN;
            end

            history.prefit_residual_by_receiver_tower_m(:, :, k) = ...
                sim.measurementModel.vectorToReceiverTowerMatrix(innovation, visibilityMask);

            history.postfit_residual_by_receiver_tower_m(:, :, k) = ...
                sim.measurementModel.vectorToReceiverTowerMatrix(postfit, visibilityMask);

            history.pseudorange_by_receiver_tower_m(:, :, k) = ...
                sim.measurementModel.vectorToReceiverTowerMatrix(y, visibilityMask);

            history.true_range_by_receiver_tower_m(:, :, k) = trueRangeRt;
            history.los_unit_eci_by_receiver_tower(:, :, :, k) = losRt;
            history.visibility_mask_by_receiver_tower(:, :, k) = visibilityMask;
            history.elevation_deg_by_receiver_tower(:, :, k) = elevationRt_deg;
        end
    end

    methods (Static, Access = private)
        function value = computeRms(x)
            x = x(:);
            value = sqrt(mean(x.^2, 'omitnan'));
        end
    end
end