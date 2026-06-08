classdef HistoryRecorder
    %HISTORYRECORDER Allocates and records the single simulation history log.

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
            history.innovation_covariance_mean_variance_m2 = NaN(1, sim.numSteps);
            history.innovation_covariance_min_variance_m2 = NaN(1, sim.numSteps);
            history.innovation_covariance_max_variance_m2 = NaN(1, sim.numSteps);
            history.measurement_covariance_range_mean_variance_m2 = NaN(1, sim.numSteps);
            history.measurement_covariance_range_max_offdiag_m2 = NaN(1, sim.numSteps);
            history.measurement_covariance_range_dimension = zeros(1, sim.numSteps);
            history.measurement_covariance_update_mean_variance_m2 = NaN(1, sim.numSteps);
            history.measurement_covariance_update_max_offdiag_m2 = NaN(1, sim.numSteps);
            history.measurement_covariance_update_dimension = zeros(1, sim.numSteps);
            history.nis_per_degree_of_freedom = NaN(1, sim.numSteps);
            history.normalized_innovation_rms = NaN(1, sim.numSteps);

            history.H_rank_history = NaN(1, sim.numSteps);
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

            rtSize = [sim.numReceivers, sim.numTowers, sim.numSteps];
            history.prefit_residual_by_receiver_tower_m = NaN(rtSize);
            history.postfit_residual_by_receiver_tower_m = NaN(rtSize);
            history.pseudorange_by_receiver_tower_m = NaN(rtSize);
            history.true_range_by_receiver_tower_m = NaN(rtSize);
            history.los_unit_eci_by_receiver_tower = ...
                NaN(3, sim.numReceivers, sim.numTowers, sim.numSteps);
            history.visibility_mask_by_receiver_tower = ...
                false(sim.numReceivers, sim.numTowers, sim.numSteps);
            history.elevation_deg_by_receiver_tower = NaN(rtSize);

            history.errors = HistoryRecorder.initializeErrors(sim);
            history.diagnostics = HistoryRecorder.initializeDiagnostics(sim);
        end

        function [history, observabilityNormalMatrix] = record( ...
                sim, history, observabilityNormalMatrix, ...
                k, epoch, truth, model, ~, filterStats)

            if isfield(epoch, 'index')
                k = epoch.index;
            end

            history.x(:, k) = filterStats.estimateVector;
            history.truth(:, k) = filterStats.truthVector;
            history.covariance_diag(:, k) = filterStats.Pdiag;
            history.innovation_rms_m(k) = MeasurementAlgebra.rms(filterStats.innovation);
            history.postfit_innovation_rms_m(k) = MeasurementAlgebra.rms(filterStats.postfit);
            history.nis_history(k) = filterStats.nisValue;
            history.covariance_condition_number(k) = ...
                MeasurementAlgebra.safeConditionNumber(filterStats.P);
            history.innovation_condition_number(k) = ...
                MeasurementAlgebra.safeConditionNumber(filterStats.S);
            history = HistoryRecorder.recordInnovationCovariance(history, k, filterStats.S);
            history = HistoryRecorder.recordMeasurementCovariance(sim, history, k);
            history = HistoryRecorder.recordHDiagnostics( ...
                sim, history, k, filterStats.H);

            Hmapped = filterStats.H * sim.transitionFromInitial;
            observabilityNormalMatrix = observabilityNormalMatrix + Hmapped.' * Hmapped;

            visibilityMask = truth.visibilityMask;
            history.measurement_count(k) = size(filterStats.H, 1);
            history.pseudorange_measurement_count(k) = numel(truth.y);
            history.visible_tower_count(k) = sum(any(visibilityMask, 1));
            history.sat_pos_history_m(:, k) = sim.truthAsset.pos_ECI_m;
            history.receiver_eci_by_receiver(:, :, k) = truth.receiverEci;
            history.tower_eci_by_tower(:, :, k) = epoch.towersEci;
            history.ground_clock_true_m(:, k) = epoch.groundTrue_m(:);
            history.ground_clock_correction_m(:, k) = epoch.groundCorrection_m(:);
            history.ground_clock_residual_m(:, k) = epoch.groundResidual_m(:);

            if ~isempty(sim.truthAsset.clock)
                history.clock_phase_history_s(k) = sim.truthAsset.clock.total_bias_sec;
            end

            history.prefit_residual_by_receiver_tower_m(:, :, k) = ...
                sim.measurementModel.vectorToReceiverTowerMatrix( ...
                filterStats.innovation, visibilityMask);
            history.postfit_residual_by_receiver_tower_m(:, :, k) = ...
                sim.measurementModel.vectorToReceiverTowerMatrix( ...
                filterStats.postfit, visibilityMask);
            history.pseudorange_by_receiver_tower_m(:, :, k) = ...
                sim.measurementModel.vectorToReceiverTowerMatrix(truth.y, visibilityMask);
            history.true_range_by_receiver_tower_m(:, :, k) = truth.trueRange_rt;
            history.los_unit_eci_by_receiver_tower(:, :, :, k) = truth.los_rt;
            history.visibility_mask_by_receiver_tower(:, :, k) = visibilityMask;
            history.elevation_deg_by_receiver_tower(:, :, k) = truth.elevation_rt;

            history = HistoryRecorder.recordAtmosphere(sim, history, k, truth, model);
            history = HistoryRecorder.recordNonAtmospheric(history, k, truth, model);
            history = HistoryRecorder.recordPropagation(history, k, truth, model);
            history = HistoryRecorder.recordAtmosphereDiagnostics(history, k, truth, model);
        end
    end

    methods (Static, Access = private)
        function errors = initializeErrors(sim)
            rtSize = [sim.numReceivers, sim.numTowers, sim.numSteps];
            towerSize = [sim.numTowers, sim.numSteps];
            errors = struct();

            componentNames = ["atmosphere", "troposphere", "ionosphere", ...
                "hardware", "antenna", "multipath", "towerSurvey", ...
                "legacySagnac", "lightTime"];
            for componentName = componentNames
                errors.(char(componentName)) = ...
                    HistoryRecorder.emptyErrorComponent(rtSize);
            end

            errors.atmosphere.deterministicTruth_m = NaN(rtSize);
            errors.atmosphere.deterministicResidual_m = NaN(rtSize);
            errors.atmosphere.stochasticResidual_m = NaN(rtSize);
            errors.atmosphere.stochasticResidualByTower_m = NaN(towerSize);
            errors.atmosphere.sigma_m = NaN(1, sim.numSteps);
            errors.atmosphere.variance_m2 = NaN(1, sim.numSteps);
            errors.atmosphere.correlationModel = "sameTower";

            for componentName = ["troposphere", "ionosphere"]
                name = char(componentName);
                errors.(name).deterministicTruth_m = NaN(rtSize);
                errors.(name).stochasticResidual_m = NaN(rtSize);
                errors.(name).stochasticResidualByTower_m = NaN(towerSize);
                errors.(name).sigma_m = NaN(1, sim.numSteps);
                errors.(name).variance_m2 = NaN(1, sim.numSteps);
                errors.(name).correlationModel = "sameTower";
            end

            errors.relativity = struct( ...
                'pathTruth_m', NaN(rtSize), ...
                'pathModel_m', NaN(rtSize), ...
                'pathResidual_m', NaN(rtSize));
        end

        function component = emptyErrorComponent(rtSize)
            component = struct( ...
                'truth_m', NaN(rtSize), ...
                'model_m', NaN(rtSize), ...
                'residual_m', NaN(rtSize), ...
                'sigma_m', NaN(rtSize), ...
                'variance_m2', NaN(rtSize));
        end

        function diagnostics = initializeDiagnostics(sim)
            diagnostics = struct();
            diagnostics.propagation.frame_used = "ECI_static_receive_epoch";
            measurementModel = [];
            if isstruct(sim) && isfield(sim, 'measurementModel')
                measurementModel = sim.measurementModel;
            elseif isobject(sim) && isprop(sim, 'measurementModel')
                measurementModel = sim.measurementModel;
            end

            if ~isempty(measurementModel)
                diagnostics.propagation.frame_used = ...
                    measurementModel.propagationFrame;
            end
            diagnostics.atmosphere.truth.ionosphere = ...
                HistoryRecorder.emptyIonosphereDiagnostics(sim);
            diagnostics.atmosphere.model.ionosphere = ...
                HistoryRecorder.emptyIonosphereDiagnostics(sim);
            diagnostics.atmosphere.truth.troposphere = ...
                HistoryRecorder.emptyTroposphereDiagnostics(sim);
            diagnostics.atmosphere.model.troposphere = ...
                HistoryRecorder.emptyTroposphereDiagnostics(sim);
        end

        function diagnostics = emptyIonosphereDiagnostics(sim)
            rtSize = [sim.numReceivers, sim.numTowers, sim.numSteps];
            diagnostics = struct( ...
                'ipp_lat_deg', NaN(rtSize), ...
                'ipp_lon_deg', NaN(rtSize), ...
                'vtec_TECU', NaN(rtSize), ...
                'stec_TECU', NaN(rtSize), ...
                'mapping_factor', NaN(rtSize), ...
                'frequency_Hz', NaN(rtSize));
        end

        function diagnostics = emptyTroposphereDiagnostics(sim)
            rtSize = [sim.numReceivers, sim.numTowers, sim.numSteps];
            diagnostics = struct( ...
                'pressure_hPa', NaN(rtSize), ...
                'temperature_K', NaN(rtSize), ...
                'relative_humidity_fraction', NaN(rtSize), ...
                'water_vapor_pressure_hPa', NaN(rtSize), ...
                'zhd_m', NaN(rtSize), ...
                'zwd_m', NaN(rtSize), ...
                'mapping_hydrostatic', NaN(rtSize), ...
                'mapping_wet', NaN(rtSize), ...
                'slant_hydrostatic_m', NaN(rtSize), ...
                'slant_wet_m', NaN(rtSize));
        end

        function history = recordInnovationCovariance(history, k, S)
            if isempty(S)
                diagonal_m2 = [];
            else
                diagonal_m2 = diag(S);
                diagonal_m2 = diagonal_m2(isfinite(diagonal_m2) & diagonal_m2 >= 0.0);
            end

            if isempty(diagonal_m2)
                history.innovation_covariance_mean_variance_m2(k) = NaN;
                history.innovation_covariance_min_variance_m2(k) = NaN;
                history.innovation_covariance_max_variance_m2(k) = NaN;
            else
                history.innovation_covariance_mean_variance_m2(k) = ...
                    mean(diagonal_m2, 'omitnan');
                history.innovation_covariance_min_variance_m2(k) = ...
                    min(diagonal_m2, [], 'omitnan');
                history.innovation_covariance_max_variance_m2(k) = ...
                    max(diagonal_m2, [], 'omitnan');
            end

            dof = size(S, 1);
            if isfinite(history.nis_history(k)) && dof > 0
                history.nis_per_degree_of_freedom(k) = history.nis_history(k) / dof;
                history.normalized_innovation_rms(k) = ...
                    sqrt(max(history.nis_per_degree_of_freedom(k), 0.0));
            end
        end

        function history = recordMeasurementCovariance(sim, history, k)
            latestRrange = [];
            latestRupdate = [];
            if isprop(sim, 'latestRrange')
                latestRrange = sim.latestRrange;
            end
            if isprop(sim, 'latestRupdate')
                latestRupdate = sim.latestRupdate;
            end

            [rangeMean_m2, rangeOffdiag_m2, rangeDim] = ...
                MeasurementAlgebra.covarianceSummary(latestRrange);
            [updateMean_m2, updateOffdiag_m2, updateDim] = ...
                MeasurementAlgebra.covarianceSummary(latestRupdate);

            history.measurement_covariance_range_mean_variance_m2(k) = rangeMean_m2;
            history.measurement_covariance_range_max_offdiag_m2(k) = rangeOffdiag_m2;
            history.measurement_covariance_range_dimension(k) = rangeDim;
            history.measurement_covariance_update_mean_variance_m2(k) = updateMean_m2;
            history.measurement_covariance_update_max_offdiag_m2(k) = updateOffdiag_m2;
            history.measurement_covariance_update_dimension(k) = updateDim;
        end

        function history = recordHDiagnostics(sim, history, k, H)
            if isempty(H)
                hRank = 0;
                hRows = 0;
                hCols = sim.stateDim;
                Hpos = zeros(0, numel(sim.idx.pos));
                Hatt = zeros(0, numel(sim.idx.att));
                Hclk = zeros(0, 1);
            else
                hRank = rank(H);
                hRows = size(H, 1);
                hCols = size(H, 2);
                Hpos = H(:, sim.idx.pos);
                Hatt = H(:, sim.idx.att);
                Hclk = H(:, sim.idx.rxClockBias);
            end

            history.H_rank_history(k) = hRank;
            history.H_row_count_history(k) = hRows;
            history.H_column_count_history(k) = hCols;
            history.H_rank_to_state_dim_history(k) = hRank / max(hCols, 1);
            history.H_state_deficiency_history(k) = hCols - hRank;
            history.H_pos_rank_history(k) = rank(Hpos);
            history.H_att_rank_history(k) = rank(Hatt);
            history.H_pos_att_clock_rank_history(k) = rank([Hpos, Hatt, Hclk]);
            history.H_pos_column_norm_history(:, k) = vecnorm(Hpos, 2, 1).';
            history.H_att_column_norm_history(:, k) = vecnorm(Hatt, 2, 1).';
            history.H_rx_clock_bias_column_norm_history(k) = norm(Hclk);
        end

        function history = recordAtmosphere(sim, history, k, truth, model)
            truthResidualTower_m = truth.atmosphere.residualByTower_m(:);
            tropoResidualTower_m = truth.atmosphere.troposphereResidualByTower_m(:);
            ionoResidualTower_m = truth.atmosphere.ionosphereResidualByTower_m(:);

            truthResidualRt_m = repmat(truthResidualTower_m.', sim.numReceivers, 1);
            tropoResidualRt_m = repmat(tropoResidualTower_m.', sim.numReceivers, 1);
            ionoResidualRt_m = repmat(ionoResidualTower_m.', sim.numReceivers, 1);

            atmosphereTruth_m = truth.atmosphere.delay_rt_m + truthResidualRt_m;
            tropoTruth_m = truth.atmosphere.troposphere_rt_m + tropoResidualRt_m;
            ionoTruth_m = truth.atmosphere.ionosphere_rt_m + ionoResidualRt_m;

            history.errors.atmosphere.truth_m(:, :, k) = atmosphereTruth_m;
            history.errors.atmosphere.model_m(:, :, k) = model.atmosphere.delay_rt_m;
            history.errors.atmosphere.residual_m(:, :, k) = ...
                atmosphereTruth_m - model.atmosphere.delay_rt_m;
            history.errors.atmosphere.deterministicTruth_m(:, :, k) = ...
                truth.atmosphere.delay_rt_m;
            history.errors.atmosphere.deterministicResidual_m(:, :, k) = ...
                truth.atmosphere.delay_rt_m - model.atmosphere.delay_rt_m;
            history.errors.atmosphere.stochasticResidual_m(:, :, k) = ...
                truthResidualRt_m;
            history.errors.atmosphere.stochasticResidualByTower_m(:, k) = ...
                truthResidualTower_m;

            history = HistoryRecorder.recordAtmosphereComponent( ...
                history, k, 'troposphere', tropoTruth_m, ...
                truth.atmosphere.troposphere_rt_m, tropoResidualRt_m, ...
                tropoResidualTower_m, model.atmosphere.troposphere_rt_m);
            history = HistoryRecorder.recordAtmosphereComponent( ...
                history, k, 'ionosphere', ionoTruth_m, ...
                truth.atmosphere.ionosphere_rt_m, ionoResidualRt_m, ...
                ionoResidualTower_m, model.atmosphere.ionosphere_rt_m);

            covariance = HistoryRecorder.atmosphereCovarianceForEpoch(sim);
            history.errors.atmosphere.sigma_m(k) = covariance.sigma_m;
            history.errors.atmosphere.variance_m2(k) = covariance.variance_m2;
            history.errors.troposphere.sigma_m(k) = covariance.residualTroposphereSigma_m;
            history.errors.troposphere.variance_m2(k) = ...
                covariance.residualTroposphereSigma_m^2;
            history.errors.ionosphere.sigma_m(k) = covariance.residualIonosphereSigma_m;
            history.errors.ionosphere.variance_m2(k) = ...
                covariance.residualIonosphereSigma_m^2;
        end

        function history = recordAtmosphereComponent( ...
                history, k, name, truthTotal_m, deterministicTruth_m, ...
                stochasticResidual_m, stochasticResidualByTower_m, model_m)
            history.errors.(name).truth_m(:, :, k) = truthTotal_m;
            history.errors.(name).model_m(:, :, k) = model_m;
            history.errors.(name).residual_m(:, :, k) = truthTotal_m - model_m;
            history.errors.(name).deterministicTruth_m(:, :, k) = deterministicTruth_m;
            history.errors.(name).stochasticResidual_m(:, :, k) = stochasticResidual_m;
            history.errors.(name).stochasticResidualByTower_m(:, k) = ...
                stochasticResidualByTower_m;
        end

        function history = recordNonAtmospheric(history, k, truth, model)
            names = ["hardware", "antenna", "multipath", ...
                "towerSurvey", "legacySagnac"];
            for name = names
                field = char(name);
                truthComponent = truth.nonAtmospheric.(field);
                modelComponent = model.nonAtmospheric.(field);
                history.errors.(field).truth_m(:, :, k) = truthComponent.truth_m;
                history.errors.(field).model_m(:, :, k) = modelComponent.model_m;
                history.errors.(field).residual_m(:, :, k) = ...
                    truthComponent.truth_m - modelComponent.model_m;
                history.errors.(field).sigma_m(:, :, k) = truthComponent.sigma_m;
                history.errors.(field).variance_m2(:, :, k) = truthComponent.variance_m2;
            end
        end

        function history = recordPropagation(history, k, truth, model)
            history.errors.lightTime.truth_m(:, :, k) = ...
                truth.propagation.lightTime.truth_m;
            history.errors.lightTime.model_m(:, :, k) = ...
                model.propagation.lightTime.model_m;
            history.errors.lightTime.residual_m(:, :, k) = ...
                truth.propagation.lightTime.truth_m - ...
                model.propagation.lightTime.model_m;

            history.errors.relativity.pathTruth_m(:, :, k) = ...
                truth.propagation.relativity.pathTruth_m;
            history.errors.relativity.pathModel_m(:, :, k) = ...
                model.propagation.relativity.pathModel_m;
            history.errors.relativity.pathResidual_m(:, :, k) = ...
                truth.propagation.relativity.pathTruth_m - ...
                model.propagation.relativity.pathModel_m;
        end

        function history = recordAtmosphereDiagnostics(history, k, truth, model)
            history = HistoryRecorder.recordIonosphereDiagnostics( ...
                history, k, 'truth', truth.atmosphere.ionosphereDiagnostics);
            history = HistoryRecorder.recordIonosphereDiagnostics( ...
                history, k, 'model', model.atmosphere.ionosphereDiagnostics);
            history = HistoryRecorder.recordTroposphereDiagnostics( ...
                history, k, 'truth', truth.atmosphere.troposphereDiagnostics);
            history = HistoryRecorder.recordTroposphereDiagnostics( ...
                history, k, 'model', model.atmosphere.troposphereDiagnostics);
        end

        function history = recordIonosphereDiagnostics(history, k, side, source)
            names = fieldnames(history.diagnostics.atmosphere.(side).ionosphere);
            for idx = 1:numel(names)
                name = names{idx};
                history.diagnostics.atmosphere.(side).ionosphere.(name)(:, :, k) = ...
                    source.(name);
            end
        end

        function history = recordTroposphereDiagnostics(history, k, side, source)
            names = fieldnames(history.diagnostics.atmosphere.(side).troposphere);
            for idx = 1:numel(names)
                name = names{idx};
                history.diagnostics.atmosphere.(side).troposphere.(name)(:, :, k) = ...
                    source.(name);
            end
        end

        function covariance = atmosphereCovarianceForEpoch(sim)
            covariance = struct( ...
                'residualTroposphereSigma_m', 0.0, ...
                'residualIonosphereSigma_m', 0.0, ...
                'sigma_m', 0.0, ...
                'variance_m2', 0.0);

            if isempty(sim.measurementModel) || isempty(sim.measurementModel.modelAtmosphere)
                return;
            end

            modelAtmosphere = sim.measurementModel.modelAtmosphere;
            if modelAtmosphere.enableTroposphere
                covariance.residualTroposphereSigma_m = ...
                    double(modelAtmosphere.residualTroposphereSigma_m);
            end
            if modelAtmosphere.enableIonosphere
                covariance.residualIonosphereSigma_m = ...
                    double(modelAtmosphere.residualIonosphereSigma_m);
            end
            covariance.variance_m2 = covariance.residualTroposphereSigma_m^2 + ...
                covariance.residualIonosphereSigma_m^2;
            covariance.sigma_m = sqrt(covariance.variance_m2);
        end
    end
end
