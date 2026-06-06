classdef ResultBuilder
    %RESULTBUILDER Builds the simulation results struct.
    %
    % This class owns the mapping from completed simulation state/history into
    % the saved results struct. It does not run the simulation and does not
    % create report-specific data.

    methods (Static)
        function results = fromSimulation(sim)
            towerClockEkfEnabled = ResultBuilder.towerClockEkfEnabled(sim);

            results = struct();

            results.time_s = sim.time_s;
            results.state_est = sim.history.x;
            results.state_truth = sim.history.truth;
            results.covariance_diag = sim.history.covariance_diag;

            results.innovation_rms_m = sim.history.innovation_rms_m;
            results.postfit_innovation_rms_m = sim.history.postfit_innovation_rms_m;
            results.nis_history = sim.history.nis_history;
            results.H_rank_history = sim.history.H_rank_history;

            results.receiver_names = sim.receiverNames;
            results.receiver_offsets_body_m = sim.receiverOffsetsBody_m;
            results.num_receivers = sim.numReceivers;
            results.scenario_name = sim.scenarioName;

            results.state_names = StateIndexFactory.stateNames( ...
                sim.towerNames, towerClockEkfEnabled);
            
            results.observability = ObservabilityAnalyzer.analyzeNormalMatrix( ...
                sim.observabilityNormalMatrix, results.state_names);
            results.ground_clock_true_m = sim.history.ground_clock_true_m;
            results.ground_clock_correction_m = sim.history.ground_clock_correction_m;
            results.ground_clock_residual_m = sim.history.ground_clock_residual_m;

            results.clock_bias_truth_m = sim.history.truth(sim.idx.rxClockBias, :);
            results.clock_bias_est_m = sim.history.x(sim.idx.rxClockBias, :);

            results.pseudorange_by_receiver_tower_m = ...
                sim.history.pseudorange_by_receiver_tower_m;

            results.true_range_by_receiver_tower_m = ...
                sim.history.true_range_by_receiver_tower_m;
            
            results.atmosphere_truth_delay_by_receiver_tower_m = ...
                sim.history.atmosphere_truth_delay_by_receiver_tower_m;

            results.atmosphere_truth_troposphere_by_receiver_tower_m = ...
                sim.history.atmosphere_truth_troposphere_by_receiver_tower_m;

            results.atmosphere_truth_ionosphere_by_receiver_tower_m = ...
                sim.history.atmosphere_truth_ionosphere_by_receiver_tower_m;
            results.atmosphere_truth_ionosphere_ipp_lat_deg_by_receiver_tower = ...
                sim.history.atmosphere_truth_ionosphere_ipp_lat_deg_by_receiver_tower;

            results.atmosphere_truth_ionosphere_ipp_lon_deg_by_receiver_tower = ...
                sim.history.atmosphere_truth_ionosphere_ipp_lon_deg_by_receiver_tower;

            results.atmosphere_truth_ionosphere_vtec_TECU_by_receiver_tower = ...
                sim.history.atmosphere_truth_ionosphere_vtec_TECU_by_receiver_tower;

            results.atmosphere_truth_ionosphere_stec_TECU_by_receiver_tower = ...
                sim.history.atmosphere_truth_ionosphere_stec_TECU_by_receiver_tower;

            results.atmosphere_truth_ionosphere_mapping_factor_by_receiver_tower = ...
                sim.history.atmosphere_truth_ionosphere_mapping_factor_by_receiver_tower;

            results.atmosphere_truth_troposphere_residual_by_tower_m = ...
                sim.history.atmosphere_truth_troposphere_residual_by_tower_m;

            results.atmosphere_truth_ionosphere_residual_by_tower_m = ...
                sim.history.atmosphere_truth_ionosphere_residual_by_tower_m;

            results.atmosphere_truth_troposphere_total_by_receiver_tower_m = ...
                sim.history.atmosphere_truth_troposphere_total_by_receiver_tower_m;

            results.atmosphere_truth_ionosphere_total_by_receiver_tower_m = ...
                sim.history.atmosphere_truth_ionosphere_total_by_receiver_tower_m; 

            results.atmosphere_truth_residual_by_tower_m = ...
                sim.history.atmosphere_truth_residual_by_tower_m;

            results.atmosphere_truth_total_by_receiver_tower_m = ...
                sim.history.atmosphere_truth_total_by_receiver_tower_m;

            results.atmosphere_model_delay_by_receiver_tower_m = ...
                sim.history.atmosphere_model_delay_by_receiver_tower_m;

            results.atmosphere_model_troposphere_by_receiver_tower_m = ...
                sim.history.atmosphere_model_troposphere_by_receiver_tower_m;

            results.atmosphere_model_ionosphere_by_receiver_tower_m = ...
                sim.history.atmosphere_model_ionosphere_by_receiver_tower_m;

            results.atmosphere_model_ionosphere_ipp_lat_deg_by_receiver_tower = ...
                sim.history.atmosphere_model_ionosphere_ipp_lat_deg_by_receiver_tower;

            results.atmosphere_model_ionosphere_ipp_lon_deg_by_receiver_tower = ...
                sim.history.atmosphere_model_ionosphere_ipp_lon_deg_by_receiver_tower;

            results.atmosphere_model_ionosphere_vtec_TECU_by_receiver_tower = ...
                sim.history.atmosphere_model_ionosphere_vtec_TECU_by_receiver_tower;

            results.atmosphere_model_ionosphere_stec_TECU_by_receiver_tower = ...
                sim.history.atmosphere_model_ionosphere_stec_TECU_by_receiver_tower;

            results.atmosphere_model_ionosphere_mapping_factor_by_receiver_tower = ...
                sim.history.atmosphere_model_ionosphere_mapping_factor_by_receiver_tower;
            results.enableTowerClockEKF = towerClockEkfEnabled;

            if towerClockEkfEnabled
                results.tower_clock_bias_est_m = ...
                    sim.history.x(sim.idx.towerClockBias, :);

                results.tower_clock_bias_truth_m = ...
                    sim.history.truth(sim.idx.towerClockBias, :);

                results.tower_clock_drift_est_mps = ...
                    sim.history.x(sim.idx.towerClockDrift, :);

                results.tower_clock_drift_truth_mps = ...
                    sim.history.truth(sim.idx.towerClockDrift, :);
            end
        end
    end

    methods (Static, Access = private)

        function tf = towerClockEkfEnabled(sim)
            tf = logical(ResultBuilder.getFieldOrDefault( ...
                sim.cfg, 'enableTowerClockEKF', false));
        end

        function value = getFieldOrDefault(s, fieldName, defaultValue)
            if isstruct(s) && isfield(s, fieldName) && ~isempty(s.(fieldName))
                value = s.(fieldName);
            else
                value = defaultValue;
            end
        end
    end
end