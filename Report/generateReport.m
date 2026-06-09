function generateReport(ctx, reportConfig, reportToggles)
    %GENERATEREPORT Build the Reverse-GNSS LaTeX/PDF report.
    % =========================================================================
    % GENERAL OPT-IN LATEX REPORT GENERATOR
    % =========================================================================
    % This function expects prepared ctx, reportConfig, and reportToggles
    % structures. By default all report toggles are disabled unless explicitly
    % enabled by the caller.
    
    %% Report Setup

    reportDir = string(fileparts(mfilename('fullpath')));
    projectRoot = string(fileparts(char(reportDir)));

    addpath(char(projectRoot));
    ProjectPathManager.addProjectPaths();
    
    if nargin < 3 || ~isstruct(reportToggles)
        reportToggles = struct();
    end
    
    reportToggles = mergeStructDefaults(reportToggles, defaultReportToggles());
    
    if ~reportToggles.generatePdf
        fprintf('generateReport: report generation is disabled. Set reportToggles.generatePdf = true from the scenario script to generate a PDF.\n');
        return;
    end
    
    if nargin < 1 || ~isstruct(ctx)
        error("generateReport:MissingData", ...
            "ctx must be provided when report generation is enabled.");
    end
    
    if nargin < 2 || ~isstruct(reportConfig)
        reportConfig = struct();
    end
 
    reportConfig = mergeStructDefaults(reportConfig, defaultReportConfig(reportDir));
    
    required_fields = [
        "time_vec"
        "total_time_hours"
        "dt"
        "num_towers"
        "R_earth"
        "oscillators"
        "towers"
        "ekf_pos_error_m"
        "ekf_pos_sigma_m"
        "ekf_clock_error_ps"
        "ekf_clock_sigma_ps"
        "true_clock_bias_ps"
        "est_clock_bias_ps"
        "innovation_rms_m"
        "nis_history"
        "sat_pos_history_m"
        "towers_eci_first_m"
        "tau_profile_s"
        "tau_sim_s"
        "sim_adev"
        "final_position_error_m"
        "final_clock_error_ps"
        "final_innovation_rms_m"
        "selected_allan_deviation_1s"
    ];
    if isfield(ctx, "sim")
        ctx = prepareReportContext(ctx.sim);
    end

    validateRequiredFields(ctx, required_fields);
    ctx = ensureReportMetrics(ctx);
    ctx = ensureReportTables(ctx);
    history = ctx.history;
    errors = history.errors;
    diags = history.diagnostics;

    report_root = char(reportConfig.reportRoot);
    figure_dir = fullfile(report_root, "figures");
    if ~exist(report_root, "dir")
        mkdir(report_root);
    end
    if ~exist(figure_dir, "dir")
        mkdir(figure_dir);
    end
    
    fprintf('generateReport: creating LaTeX/PDF report...\n');
    
    interactive_report_plots = true;
    if isfield(reportConfig, "interactivePlots")
        interactive_report_plots = logical(reportConfig.interactivePlots);
    end
    setappdata(0, 'generateReportInteractivePlots', interactive_report_plots);
    safeFigureOutputBaseName = sanitizeLatexFileStem( ...
        string(reportConfig.outputBaseName));
    
    setappdata(0, 'generateReportOutputBaseName', safeFigureOutputBaseName);
    
    %% Report Figure Generation
    plot_paths = struct();
    plot_paths.position_error = exportPlot(figure_dir, "position_error.pdf", ...
        @() plotPositionError(ctx.time_vec, ctx.ekf_pos_error_m));
    plot_paths.position_covariance = exportPlot(figure_dir, "position_covariance.pdf", ...
        @() plotPositionCovariance(ctx.time_vec, ctx.ekf_pos_sigma_m));
    
    if isfield(ctx, "attitude_est_deg") && isfield(ctx, "attitude_truth_deg")
        plot_paths.attitude_states = exportPlot(figure_dir, "attitude_states.pdf", ...
            @() plotAttitudeStates(ctx.time_vec, ctx.attitude_truth_deg, ...
            ctx.attitude_est_deg, ctx.attitude_error_deg, ...
            ctx.attitude_sigma_deg, ctx.attitude_state_names, ...
            ctx.attitude_frame));
    
        plot_paths.attitude_covariance = exportPlot(figure_dir, "attitude_covariance.pdf", ...
            @() plotAttitudeCovariance(ctx.time_vec, ctx.attitude_sigma_deg, ...
            ctx.attitude_state_names, ctx.attitude_frame));
    else
        plot_paths.attitude_states = "";
        plot_paths.attitude_covariance = "";
    end
    
    if isfield(ctx, "angular_velocity_est_degps") && isfield(ctx, "angular_velocity_truth_degps")
        plot_paths.angular_velocity_states = exportPlot(figure_dir, "angular_velocity_states.pdf", ...
            @() plotAngularVelocityStates(ctx.time_vec, ...
            ctx.angular_velocity_truth_degps, ...
            ctx.angular_velocity_est_degps, ...
            ctx.angular_velocity_error_degps, ...
            ctx.angular_velocity_sigma_degps, ...
            ctx.angular_velocity_state_names, ...
            ctx.attitude_frame));
    else
        plot_paths.angular_velocity_states = "";
    end
    
    plot_paths.clock_error = exportPlot(figure_dir, "clock_error.pdf", ...
        @() plotClockError(ctx.time_vec, ctx.ekf_clock_error_ps, ctx.ekf_clock_sigma_ps));
    plot_paths.clock_bias = exportPlot(figure_dir, "clock_bias_tracking.pdf", ...
        @() plotClockBias(ctx.time_vec, ctx.true_clock_bias_ps, ctx.est_clock_bias_ps));
    if isfield(ctx, "true_ground_clock_bias_ps")
        plot_paths.ground_clock_bias = exportPlot(figure_dir, "ground_clock_bias.pdf", ...
            @() plotGroundClockBias(ctx.time_vec, ctx.true_ground_clock_bias_ps, ctx.towers));
    else
        plot_paths.ground_clock_bias = "";
    end
    if isfield(ctx, "tower_clock_correction_s")
        plot_paths.ground_clock_correction = exportPlot(figure_dir, "ground_clock_correction.pdf", ...
            @() plotGroundClockCorrection(ctx.time_vec, ctx.true_ground_clock_bias_ps, ...
            ctx.tower_clock_correction_s, ctx.tower_clock_correction_residual_s, ...
            ctx.tower_clock_correction_sigma_s, ctx.towers));
    else
        plot_paths.ground_clock_correction = "";
    end
    if isfield(ctx, "est_ground_clock_bias_ps") && any(isfinite(ctx.est_ground_clock_bias_ps(:)))
        plot_paths.ground_clock_estimate = exportPlot(figure_dir, "ground_clock_estimate.pdf", ...
            @() plotGroundClockEstimate(ctx.time_vec, ctx.true_ground_clock_bias_ps, ctx.est_ground_clock_bias_ps, ctx.towers));
    else
        plot_paths.ground_clock_estimate = "";
    end
    if isfield(ctx, "est_ground_clock_bias_ps_gauge_aligned") && any(isfinite(ctx.est_ground_clock_bias_ps_gauge_aligned(:)))
        plot_paths.ground_clock_gauge_aligned = exportPlot(figure_dir, "ground_clock_gauge_aligned.pdf", ...
            @() plotGroundClockEstimate(ctx.time_vec, ctx.true_ground_clock_bias_ps, ctx.est_ground_clock_bias_ps_gauge_aligned, ctx.towers));
    else
        plot_paths.ground_clock_gauge_aligned = "";
    end
    if isfield(ctx, "prefit_residual_by_tower_m")
        plot_paths.residual_by_tower = exportPlot(figure_dir, "residual_by_tower.pdf", ...
            @() plotResidualByTower(ctx.time_vec, ctx.prefit_residual_by_tower_m, ctx.postfit_residual_by_tower_m, ctx.towers));
    else
        plot_paths.residual_by_tower = "";
    end
    if isfield(ctx, "prefit_residual_by_receiver_tower_m")
        plot_paths.per_receiver_prefit_rms = exportPlot(figure_dir, "per_receiver_prefit_rms.pdf", ...
            @() plotPerReceiverResidualRms(ctx.time_vec, ctx.prefit_residual_by_receiver_tower_m, ctx.receiver_names, "Pre-fit pseudorange residual RMS [m]"));
        plot_paths.per_receiver_postfit_rms = exportPlot(figure_dir, "per_receiver_postfit_rms.pdf", ...
            @() plotPerReceiverResidualRms(ctx.time_vec, ctx.postfit_residual_by_receiver_tower_m, ctx.receiver_names, "Post-fit pseudorange residual RMS [m]"));
        plot_paths.receiver_residual_heatmaps = exportPlot(figure_dir, "receiver_residual_heatmaps.pdf", ...
            @() plotReceiverResidualHeatmaps(ctx.time_vec, ctx.prefit_residual_by_receiver_tower_m, ...
            ctx.postfit_residual_by_receiver_tower_m, ctx.receiver_names, ctx.tower_names));
       plot_paths.differential_residuals = "";
    else
        plot_paths.per_receiver_prefit_rms = "";
        plot_paths.per_receiver_postfit_rms = "";
        plot_paths.receiver_residual_heatmaps = "";
        plot_paths.differential_residuals = "";
    end
    if isfield(ctx, "pseudorange_error_by_receiver_tower_m")
        plot_paths.receiver_pseudorange_error = exportPlot(figure_dir, "receiver_pseudorange_error.pdf", ...
            @() plotPerReceiverResidualRms(ctx.time_vec, ctx.pseudorange_error_by_receiver_tower_m, ...
            ctx.receiver_names, "Pseudorange minus geometric range RMS [m]"));
    else
        plot_paths.receiver_pseudorange_error = "";
    end
    plot_paths.baseline_projection = "";
    plot_paths.differential_observable = "";
    plot_paths.receiver_subset_position = "";
    plot_paths.receiver_subset_covariance = "";
    plot_paths.receiver_subset_residuals = "";
    if isfield(ctx, "R_total_m2")
        plot_paths.R_breakdown = exportPlot(figure_dir, "measurement_covariance_breakdown.pdf", ...
            @() plotMeasurementCovarianceBreakdown(ctx.time_vec, ctx));
    else
        plot_paths.R_breakdown = "";
    end
    atmosphereSectionEnabled = reportToggles.ionosphere || reportToggles.troposphere;
    atmospherePlotsEnabled = ...
        atmosphereSectionEnabled && ...
        arraysHaveFiniteData({ ...
        errors.atmosphere.truth_m, ...
        errors.troposphere.deterministicTruth_m, ...
        errors.ionosphere.deterministicTruth_m, ...
        errors.atmosphere.model_m, ...
        errors.troposphere.model_m, ...
        errors.ionosphere.model_m});
    atmosphereResidualPlotsEnabled = ...
        atmosphereSectionEnabled && ...
        arraysHaveFiniteData({ ...
        errors.atmosphere.residual_m, ...
        errors.troposphere.residual_m, ...
        errors.ionosphere.residual_m});

    if atmospherePlotsEnabled
        plot_paths.atmosphere_components = exportPlot( ...
            figure_dir, ...
            "atmosphere_components.pdf", ...
            @() plotAtmosphereComponents(ctx.time_vec, errors));
    else
        plot_paths.atmosphere_components = "";
    end

    if atmosphereResidualPlotsEnabled
        plot_paths.atmosphere_residual_components = exportPlot( ...
            figure_dir, ...
            "atmosphere_residual_components.pdf", ...
            @() plotAtmosphereResidualComponents(ctx.time_vec, errors));
    else
        plot_paths.atmosphere_residual_components = "";
    end

    ionosphereMapPlotsEnabled = ...
        reportToggles.ionosphere && ...
        arraysHaveFiniteData({ ...
        diags.atmosphere.truth.ionosphere.vtec_TECU, ...
        diags.atmosphere.model.ionosphere.vtec_TECU, ...
        diags.atmosphere.truth.ionosphere.stec_TECU, ...
        diags.atmosphere.model.ionosphere.stec_TECU, ...
        diags.atmosphere.truth.ionosphere.mapping_factor, ...
        diags.atmosphere.model.ionosphere.mapping_factor});

    if ionosphereMapPlotsEnabled
        plot_paths.ionosphere_map_diagnostics = exportPlot( ...
            figure_dir, ...
            "ionosphere_map_diagnostics.pdf", ...
            @() plotIonosphereMapDiagnostics(ctx.time_vec, diags));
    else
        plot_paths.ionosphere_map_diagnostics = "";
    end

    troposphereProfilePlotsEnabled = ...
        reportToggles.troposphere && ...
        arraysHaveFiniteData({ ...
        diags.atmosphere.truth.troposphere.zhd_m, ...
        diags.atmosphere.model.troposphere.zhd_m, ...
        diags.atmosphere.truth.troposphere.zwd_m, ...
        diags.atmosphere.model.troposphere.zwd_m, ...
        diags.atmosphere.truth.troposphere.slant_hydrostatic_m, ...
        diags.atmosphere.model.troposphere.slant_hydrostatic_m, ...
        diags.atmosphere.truth.troposphere.slant_wet_m, ...
        diags.atmosphere.model.troposphere.slant_wet_m});

    if troposphereProfilePlotsEnabled
        plot_paths.troposphere_profile_diagnostics = exportPlot( ...
            figure_dir, ...
            "troposphere_profile_diagnostics.pdf", ...
            @() plotTroposphereProfileDiagnostics(ctx.time_vec, diags));
    else
        plot_paths.troposphere_profile_diagnostics = "";
    end

    stochasticTruthResidualPlotsEnabled = ...
        atmosphereSectionEnabled && ...
        arraysHaveFiniteData({ ...
        errors.atmosphere.stochasticResidualByTower_m, ...
        errors.troposphere.stochasticResidualByTower_m, ...
        errors.ionosphere.stochasticResidualByTower_m});

    if stochasticTruthResidualPlotsEnabled
        plot_paths.stochastic_truth_residuals = exportPlot( ...
            figure_dir, ...
            "stochastic_truth_atmosphere_residuals.pdf", ...
            @() plotStochasticTruthAtmosphereResiduals( ...
            ctx.time_vec, ...
            errors));
    else
        plot_paths.stochastic_truth_residuals = "";
    end    
    
    
    if isfield(ctx, "visible_tower_count")
        plot_paths.visible_towers = exportPlot(figure_dir, "visible_towers.pdf", ...
            @() plotVisibleTowers(ctx.time_vec, ctx.visible_tower_count, ctx.num_towers));
    else
        plot_paths.visible_towers = "";
    end
    plot_paths.innovation = exportPlot(figure_dir, "innovation_rms.pdf", ...
        @() plotInnovation(ctx.time_vec, ctx.innovation_rms_m, ctx.postfit_innovation_rms_m));
    if isfield(ctx, "nis_degrees_of_freedom")
        plot_paths.nis = exportPlot(figure_dir, "nis.pdf", ...
            @() plotNis(ctx.time_vec, ctx.nis_history, ctx.num_towers, ctx.nis_degrees_of_freedom));
    else
        plot_paths.nis = exportPlot(figure_dir, "nis.pdf", ...
            @() plotNis(ctx.time_vec, ctx.nis_history, ctx.num_towers));
    end
    if isfield(ctx, "normalized_innovation_rms") && ...
            isfield(ctx, "innovation_covariance_mean_sigma_m")
        plot_paths.innovation_covariance_consistency = exportPlot( ...
            figure_dir, ...
            "innovation_covariance_consistency.pdf", ...
            @() plotInnovationCovarianceConsistency( ...
            ctx.time_vec, ...
            ctx));
    else
        plot_paths.innovation_covariance_consistency = "";
    end

    plot_paths.geometry = exportPlot(figure_dir, "geometry.pdf", ...
        @() plotGeometry(ctx.R_earth, ctx.sat_pos_history_m, ctx.towers_eci_first_m, ctx.towers));
    if isfield(ctx, "clock_allan_names") && isfield(ctx, "sim_adev_by_clock")
        plot_paths.allan = exportPlot(figure_dir, "allan_deviation.pdf", ...
            @() plotAllanDeviation(ctx.oscillators, reportConfig.selectedOscillatorName, ...
            ctx.tau_profile_s, ctx.tau_sim_s, ctx.sim_adev, ctx.dt, ...
            ctx.clock_allan_names, ctx.sim_adev_by_clock));
    else
        plot_paths.allan = exportPlot(figure_dir, "allan_deviation.pdf", ...
            @() plotAllanDeviation(ctx.oscillators, reportConfig.selectedOscillatorName, ...
            ctx.tau_profile_s, ctx.tau_sim_s, ctx.sim_adev, ctx.dt));
    end
    
    %% LaTeX Report Assembly
    report = {};
    report = appendLine(report, "\documentclass[11pt,a4paper]{article}");
    report = appendLine(report, "\usepackage[margin=1.7cm]{geometry}");
    report = appendLine(report, "\usepackage{amsmath}");
    report = appendLine(report, "\usepackage{geometry}");
    report = appendLine(report, "\usepackage{graphicx}");
    report = appendLine(report, "\usepackage{longtable}");
    report = appendLine(report, "\usepackage{array}");
    report = appendLine(report, "\usepackage{booktabs}");
    report = appendLine(report, "\usepackage{xcolor}");
    report = appendLine(report, "\usepackage{hyperref}");
    report = appendLine(report, "\setlength{\parindent}{0pt}");
    report = appendLine(report, "\setlength{\tabcolsep}{3pt}");
    report = appendLine(report, "\renewcommand{\arraystretch}{1.18}");
    report = appendLine(report, "\hypersetup{colorlinks=true,linkcolor=black,urlcolor=blue}");
    report = appendLine(report, "\begin{document}");
    report = appendLine(report, "\begin{center}");
    report = appendLine(report, sprintf("{\\Large \\textbf{%s}}\\\\[4pt]", latexEscape(reportConfig.title)));
    report = appendLine(report, sprintf("{\\large Scenario: \\textbf{%s}}\\\\[4pt]", latexEscape(reportConfig.scenarioName)));
    report = appendLine(report, sprintf("{\\large Selected satellite oscillator: \\textbf{%s}}\\\\[4pt]", latexEscape(reportConfig.selectedOscillatorName)));
    report_timestamp = char(string(datetime("now", "Format", "yyyy-MM-dd HH:mm:ss")));
    report = appendLine(report, sprintf("{\\small Generated by \\texttt{%s} on %s}", latexEscape(reportConfig.generatedBy), report_timestamp));
    report = appendLine(report, "\end{center}");
    report = appendLine(report, "\vspace{0.3cm}");
    
    has_first_page_tables = isfield(ctx, "assumption_table") || ...
        isfield(ctx, "noise_error_table") || ...
        isfield(ctx, "covariance_table") || ...
        isfield(ctx, "initial_state_table") || ...
        isfield(ctx, "final_state_table") || ...
        isfield(ctx, "observability_table") || ...
        isfield(ctx, "first_page_summary_table");
    if has_first_page_tables
        report = appendLine(report, "\section{Run Assumptions and Initial Conditions}");
        report = appendOptionalTable(report, "First-Page Configuration Snapshot", ctx, "first_page_summary_table", 12);
        report = appendOptionalTable(report, "Scenario Assumptions", ctx, "assumption_table", 18);
        report = appendOptionalTable(report, "Noise and Error Inputs", ctx, "noise_error_table", 24);
        report = appendOptionalTable(report, "Covariance and Process Inputs", ctx, "covariance_table", 24);
        report = appendOptionalTable(report, "Initial Kalman Filter State Vector", ctx, "initial_state_table", 40);
        report = appendOptionalTable(report, "Final Kalman Filter State Vector", ctx, "final_state_table", 40);
        report = appendOptionalTable(report, "Accumulated Linearised Observability", ctx, "observability_table", 40);
    end
    
    report = appendLine(report, "\section{Scenario Summary}");
    summary_format = [ ...
        'This report documents the current validation scenario. ' ...
        'The ground segment transmits reverse-GNSS pseudorange observations to a satellite receiver. ' ...
        'Each SpaceAsset carries fixed mounted RX phase centres that share the parent RX clock. ' ...
        'The EKF estimates local orbital receiver navigation, configured RX clock states, and configured transmitter signal-delay states using %s for the internal clock sub-state. ' ...
        'The run length is %.2f hours with %.1f second sampling and %d ground stations.'];
    if isfield(ctx, "ekf_clock_state_units")
        clock_state_units_text = ctx.ekf_clock_state_units;
    else
        clock_state_units_text = 'native clock seconds';
    end
    report = appendParagraph(report, sprintf(summary_format, ...
        char(string(clock_state_units_text)), ...
        ctx.total_time_hours, ctx.dt, ctx.num_towers));
    if isfield(ctx, "clock_estimation_mode")
        clock_mode_text = string(ctx.clock_estimation_mode);
        if clock_mode_text == "spacecraftOnly" || clock_mode_text == "spacecraftReceiverClockOnly"
            mode_description = ['Clock-estimation mode is %s. ' ...
                'The EKF estimates the spacecraft receiver clock only. Tower transmitter residual clocks may be generated in the truth measurements, but they are not EKF states and are not inserted into the predicted pseudorange unless represented by an explicit correction.'];
        elseif clock_mode_text == "receiverClockAndTxSignalDelays"
            mode_description = ['Clock-estimation mode is %s. ' ...
                'The EKF estimates the satellite RX clock and one range-equivalent transmitter signal-delay state per tower; the pseudorange Jacobian has positive RX clock-bias sensitivity and negative sensitivity to the transmitting tower delay.'];
        else
            mode_description = ['Clock-estimation mode is %s. ' ...
                'See the scenario notes for which clock terms are estimated states and which are applied truth-side residuals or corrections.'];
        end
        report = appendParagraph(report, sprintf(mode_description, char(clock_mode_text)));
    end
    if isfield(ctx, "clockGaugeMode")
        gauge_text = string(ctx.clockGaugeMode);
        if gauge_text == "fixReferenceTxDelay"
            gauge_description = sprintf( ...
                'Reference ambiguity handling is %s. TX signal delays are range-equivalent relative delays, with reference tower %s fixed to zero.', ...
                char(gauge_text), char(string(ctx.referenceTowerName)));
        elseif gauge_text == "externalTimeTransfer"
            gauge_description = sprintf( ...
                'Clock gauge mode is %s. Tower clock pseudo-measurements provide an external time-transfer reference with configured sigma %.3g ps, so reported clock states are referenced to that external network time scale.', ...
                char(gauge_text), ctx.externalClockCorrectionSigma_ps);
        elseif gauge_text == "fixReferenceTower"
            gauge_description = sprintf( ...
                'Clock gauge mode is %s. Reported spacecraft and tower clock estimates are relative to reference tower %s; no absolute UTC or GNSS system-time solution is claimed.', ...
                char(gauge_text), char(string(ctx.referenceTowerName)));
        elseif gauge_text == "externalTowerCorrections"
            gauge_description = sprintf( ...
                'Clock gauge mode is %s. Tower transmitter clocks are simulated in truth and corrected before the spacecraft-only EKF update; residual correction uncertainty is represented in R.', ...
                char(gauge_text));
        elseif gauge_text == "groundClockResidualsGeneratedButNotEstimated"
            gauge_description = sprintf( ...
                ['Clock gauge mode is %s. Tower transmitter residual clocks are generated on the truth side after any configured external correction, ' ...
                 'but they are not EKF states. If ground correction is disabled, these transmitter-side residuals appear in the pseudorange innovations rather than being removed from the prediction model.'], ...
                char(gauge_text));
        else
            gauge_description = sprintf( ...
                'Clock gauge mode is %s. Absolute joint tower/spacecraft clock solution is unobservable from one-way pseudorange only unless an explicit reference or constraint is present.', ...
                char(gauge_text));
        end
        report = appendParagraph(report, gauge_description);
    end
    if isfield(ctx, "measurementNoiseEnabled") && ~ctx.measurementNoiseEnabled
        report = appendParagraph(report, ['Measurement noise injection is disabled. Innovation RMS remains useful as a deterministic residual diagnostic, ' ...
            'but NIS is not statistically meaningful and should not be interpreted as a chi-square consistency result.']);
    end
    if isfield(ctx, "observability_note")
        report = appendParagraph(report, ctx.observability_note);
    end
    
    % 1.1 Receiver Clock Architectue Interpretation
    if isfield(ctx, "receiver_architecture_note")
        report = appendLine(report, "\subsection{Receiver Clock Architecture Interpretation}");
        report = appendParagraph(report, ctx.receiver_architecture_note);
    end
    report = appendOptionalTable(report, "Receiver Architecture Comparison", ctx, "receiver_architecture_comparison_table", 12);
    report = appendOptionalTable(report, "Receiver Geometry Diagnostic", ctx, "receiver_geometry_comparison_table", 12);
    
    % 1.2 Scenario Geometriy and Receiver Architecture
    if isfield(ctx, "signal_model_note")
        report = appendLine(report, "\subsection{Scenario Geometry and Receiver Architecture}");
        report = appendParagraph(report, ctx.signal_model_note);

        if isfield(ctx, "propagation_frame_note")
            report = appendParagraph(report, ctx.propagation_frame_note);
        end

        if isfield(ctx, "relativity_note")
            report = appendParagraph(report, ctx.relativity_note);
        end
    end
    
    report = appendOptionalTable(report, "Scenario Geometry and Receiver Architecture", ...
        ctx, "scenario_geometry_table", 20);
    
    % 1.3 EKF State Vector
    if isfield(ctx, "state_vector_table")
        report = appendLine(report, "\subsection{EKF State Vector}");
        report = appendParagraph(report, ['The filter is an error-state / MEKF-style estimator. ' ...
            'The nominal spacecraft position, velocity, attitude quaternion, body angular rate, and receiver clock are corrected by the estimated error state after each measurement update.']);
        report = appendOptionalTable(report, "", ctx, "state_vector_table", 14);
    end
    
    
    % 1.4 Pseudorange Measurement Model and Observation Matrix
    if isfield(ctx, "measurement_model_equation") || ...
            isfield(ctx, "observation_matrix_equation") || ...
            isfield(ctx, "measurement_model_table")
        report = appendLine(report, "\subsection{Pseudorange Measurement Model and Observation Matrix}");
        if isfield(ctx, "measurement_model_equation")
            report = appendLine(report, "\[");
            equation_lines = string(ctx.measurement_model_equation);
            for idx_equation_line = 1:numel(equation_lines)
                report = appendLine(report, equation_lines(idx_equation_line));
            end
            report = appendLine(report, "\]");
        end
        if isfield(ctx, "observation_matrix_equation")
            report = appendLine(report, "\[");
            equation_lines = string(ctx.observation_matrix_equation);
            for idx_equation_line = 1:numel(equation_lines)
                report = appendLine(report, equation_lines(idx_equation_line));
            end
            report = appendLine(report, "\]");
        end
        report = appendOptionalTable(report, "", ctx, "measurement_model_table", 12);
        report = appendOptionalTable(report, ...
            "H-matrix factor observability by EKF state block", ...
            ctx, ...
            "h_factor_observability_table", ...
            12);
        
        report = appendOptionalTable(report, ...
            "Observation matrix dimensions and rank diagnostics", ...
            ctx, ...
            "observation_matrix_diagnostics_table", ...
            12);
    end
    
    report = appendOptionalTable(report, "Starting Positions", ...
        ctx, "starting_position_table", 20);
    
    report = appendLine(report, "\begin{center}");
    report = appendLine(report, "\begin{tabular}{p{0.39\textwidth}p{0.18\textwidth}p{0.34\textwidth}}");
    report = appendLine(report, "\toprule");
    report = appendLine(report, "\textbf{Component or scenario} & \textbf{Status} & \textbf{Report action}\\");
    report = appendLine(report, "\midrule");
    report = appendStatusRow(report, "Ground segment geometry", reportToggles.groundSegment);
    report = appendStatusRow(report, "Perfect ground transmitter clocks", reportToggles.perfectGroundClocks);
    report = appendStatusRow(report, "Ground transmitter clock error", reportToggles.groundClockError);
    if isfield(reportToggles, "groundTimingNetworkCorrection")
        report = appendStatusRow(report, "Ground timing network correction", reportToggles.groundTimingNetworkCorrection);
    end
    if isfield(reportToggles, "towerClocksEstimatedInEkf")
        report = appendStatusRow(report, "TX signal delays estimated in EKF", reportToggles.towerClocksEstimatedInEkf);
    end
    report = appendStatusRow(report, "SpaceAsset onboard clock error", reportToggles.satelliteClockError);
    report = appendStatusRow(report, "EKF orbit and clock estimation", reportToggles.ekfOrbitClockEstimation);
    report = appendStatusRow(report, "Measurement noise", reportToggles.measurementNoise);
    if isfield(reportToggles, "clockCovarianceFloor")
        report = appendStatusRow(report, "Clock covariance floor", reportToggles.clockCovarianceFloor);
    end
    report = appendStatusRow(report, "J2 perturbation", reportToggles.j2Perturbation);
    report = appendStatusRow(report, "Relativistic clock term", reportToggles.relativisticClockTerm);
    report = appendStatusRow(report, "Ionosphere", reportToggles.ionosphere);
    report = appendStatusRow(report, "Troposphere", reportToggles.troposphere);
    report = appendStatusRow(report, "Multipath", reportToggles.multipath);
    report = appendStatusRow(report, "Receiver thermal noise", reportToggles.receiverThermalNoise);
    report = appendStatusRow(report, "Antenna bias", reportToggles.antennaBias);
    report = appendStatusRow(report, "Hardware delay", reportToggles.hardwareDelay);
    report = appendLine(report, "\bottomrule");
    report = appendLine(report, "\end{tabular}");
    report = appendLine(report, "\end{center}");
    
    %% 2. State Estimation Validation
    report = appendLine(report, "\clearpage");
    report = appendLine(report, "\section{State Estimation Validation}");
    if isfield(ctx, "attitude_filter_note")
        report = appendParagraph(report, ctx.attitude_filter_note);
    end
    report = beginPlotTable(report);
    
    report = appendReportRow(report, reportToggles.ekfOrbitClockEstimation, plot_paths.position_error, ...
        "Combined EKF Local Position Error", ...
        ["The plot compares the EKF local East/North/Vertical position estimate with truth in all three local axes and as a 3D norm. " ...
         "The diagnostic is deterministic truth differencing; no measurement noise is injected unless the measurement-noise toggle is enabled."]);
    
    report = appendReportRow(report, reportToggles.ekfOrbitClockEstimation, plot_paths.position_covariance, ...
        "EKF Position Covariance", ...
        ["The plot shows the square root of the EKF posterior covariance diagonal for the three position states. " ...
         "The statistical approach is covariance propagation through the linearized two-body dynamics and correction by pseudorange observations."]);
    
    report = appendReportRow(report, isfield(ctx, "attitude_est_deg") && strlength(string(plot_paths.attitude_states)) > 0, plot_paths.attitude_states, ...
        "EKF Attitude States: Roll, Pitch, Yaw", ...
        ["The plot compares true and estimated Euler-321 attitude states and shows attitude error with the covariance envelope. " ...
         "Attitude is observable only through the mounted receiver phase-centre lever arms and the line-of-sight geometry."]);
    
    report = appendReportRow(report, isfield(ctx, "angular_velocity_est_degps") && strlength(string(plot_paths.angular_velocity_states)) > 0, plot_paths.angular_velocity_states, ...
        "EKF Angular Velocity States", ...
        ["Angular velocity is not an instantaneous pseudorange observable. " ...
         "It is coupled indirectly through attitude propagation, so a zero-rate truth case should remain nearly constant. " ...
         "Use this plot as a dynamic-coupling diagnostic, not as proof of direct angular-rate observability."]);
    
    report = appendReportRow(report, reportToggles.ekfOrbitClockEstimation && reportToggles.satelliteClockError, plot_paths.clock_error, ...
        "Clock Synchronisation Error", ...
        ["The plot shows SpaceAsset onboard clock estimation error against the EKF clock covariance envelope. " ...
         "The clock process follows the selected oscillator power-law noise model."]);
    
    report = appendReportRow(report, reportToggles.ekfOrbitClockEstimation && reportToggles.satelliteClockError, plot_paths.clock_bias, ...
        "SpaceAsset Onboard Clock Bias Tracking", ...
        ["The plot compares the true simulated SpaceAsset onboard clock bias with the EKF clock-bias estimate. " ...
         "The approach is state-estimation consistency against known truth in a controlled scenario."]);
    
    report = endPlotTable(report);
    
    if isfield(ctx, "final_H_rows") && ...
            isfield(ctx, "final_H_columns") && ...
            isfield(ctx, "final_H_rank") && ...
            isfield(ctx, "final_H_rank_to_state_dim")
    
        report = appendLine(report, "\subsection{Instantaneous Measurement Jacobian Rank}");
    
        hRankPercent = 100.0 * ctx.final_H_rank_to_state_dim;
    
        report = appendParagraph(report, sprintf([ ...
            'The final measurement Jacobian contains %d measurement rows and %d EKF state columns. ' ...
            'Its instantaneous rank is %d, corresponding to %.1f%% of the EKF state dimension. ' ...
            'This means that all pseudorange rows may be used, but they provide only %d independent measurement directions at this epoch. ' ...
            'For the current pseudorange-only model, this is expected when the geometry mainly observes spacecraft position and receiver clock bias, ' ...
            'while velocity, angular rate, and clock drift are observable only through time propagation.'], ...
            ctx.final_H_rows, ...
            ctx.final_H_columns, ...
            ctx.final_H_rank, ...
            hRankPercent, ...
            ctx.final_H_rank));
    end
    if isfield(ctx, "final_H_pos_rank") && ...
            isfield(ctx, "final_H_att_rank") && ...
            isfield(ctx, "final_H_pos_att_clock_rank")
    
        report = appendParagraph(report, sprintf([ ...
            'Final block ranks: position block rank = %d, attitude block rank = %d, ' ...
            'combined position-attitude-clock-bias rank = %d.'], ...
            ctx.final_H_pos_rank, ...
            ctx.final_H_att_rank, ...
            ctx.final_H_pos_att_clock_rank));
    end
    %% 3. Measurement and Geometry Validation
    report = appendLine(report, "\clearpage");
    report = appendLine(report, "\section{Measurement and Geometry Validation}");
    report = appendParagraph(report, [ ...
        'Scientific interpretation: pre-fit residuals test the consistency of the predicted measurement model before correction. ' ...
        'Post-fit residuals test how much residual measurement error remains after the EKF update. ' ...
        'RMS residuals are useful compact diagnostics, but they are not by themselves a proof of statistical consistency. ' ...
        'NIS is a chi-square consistency diagnostic only when the injected measurement noise is stochastic, zero-mean, independent, and represented correctly by R. ' ...
        'In deterministic or partly deterministic validation runs, NIS should be interpreted as a numerical conditioning and model-coupling diagnostic.']);
    report = beginPlotTable(report);
    report = appendReportRow(report, reportToggles.ekfOrbitClockEstimation, plot_paths.innovation, ...
        "Pseudorange Pre-Fit and Post-Fit Residual RMS", ...
        ["The plot separates the pre-fit innovation before the EKF correction from the post-fit residual after the correction. " ...
         "With measurement noise disabled this is a deterministic diagnostic for geometry, clock-state coupling, numerical consistency, and estimator convergence."]);
    report = appendReportRow(report, isfield(ctx, "prefit_residual_by_tower_m"), plot_paths.residual_by_tower, ...
        "Per-Tower Measurement Residuals", ...
        ["The plot keeps pre-fit and post-fit residuals separated by tower. " ...
         "Blank intervals indicate epochs where that tower was not visible and was excluded from the EKF update."]);
    report = appendReportRow(report, isfield(ctx, "R_total_m2"), plot_paths.R_breakdown, ...
        "Measurement Covariance Contribution", ...
        ["The plot shows the per-row root-variance contributions represented in the measurement covariance. " ...
         "Receiver tracking noise is independent by row; ground-timing and atmospheric residual terms may also enter the full R matrix as tower-common correlations across receivers. " ...
         "Physical contributions are kept separate from any tiny numerical regularisation floor used to keep the innovation covariance nonsingular in ideal zero-noise runs."]);
    if atmosphereSectionEnabled
        atmosphere_components_description = withDataUnavailableNote( ...
            ["The plot separates deterministic truth and estimator-model atmospheric code-delay components. " ...
             "Troposphere and ionosphere are shown independently so that enabled propagation models can be inspected directly."], ...
            atmosphereSectionEnabled, ...
            atmospherePlotsEnabled, ...
            "finite atmosphere component data are unavailable.");
        report = appendReportRow(report, true, ...
            plot_paths.atmosphere_components, ...
            "Ionosphere and Troposphere Delay Components", ...
            atmosphere_components_description);

        atmosphere_residual_description = withDataUnavailableNote( ...
            ["The plot shows the remaining atmospheric contribution after subtracting the estimator model from the truth model. " ...
             "This is the diagnostic residual that can drive pseudorange innovations when truth and estimator atmosphere differ."], ...
            atmosphereSectionEnabled, ...
            atmosphereResidualPlotsEnabled, ...
            "finite atmosphere residual data are unavailable.");
        report = appendReportRow(report, true, ...
            plot_paths.atmosphere_residual_components, ...
            "Atmosphere Truth Minus Model Residual Components", ...
            atmosphere_residual_description);
    end

    if reportToggles.ionosphere
        ionosphere_map_description = withDataUnavailableNote( ...
            ["The plot shows ionospheric diagnostics evaluated at the thin-shell pierce point. " ...
             "For scalar thin-shell VTEC, VTEC comes from the configured scalar value. For IONEX, VTEC is interpolated from the configured map provider. " ...
             "STEC is VTEC multiplied by the shell mapping factor."], ...
            reportToggles.ionosphere, ...
            ionosphereMapPlotsEnabled, ...
            "finite ionosphere pierce-point data are unavailable.");
        report = appendReportRow(report, true, ...
            plot_paths.ionosphere_map_diagnostics, ...
            "Ionosphere Pierce-Point VTEC, STEC, and Mapping Diagnostics", ...
            ionosphere_map_description);
    end

    if reportToggles.troposphere
        troposphere_profile_description = withDataUnavailableNote( ...
            ["The plot shows neutral-atmosphere profile diagnostics separated into hydrostatic and wet components. " ...
             "ZHD and ZWD are zenith delays; slant hydrostatic and slant wet delays are formed with the configured troposphere mapping function."], ...
            reportToggles.troposphere, ...
            troposphereProfilePlotsEnabled, ...
            "finite troposphere profile data are unavailable.");
        report = appendReportRow(report, true, ...
            plot_paths.troposphere_profile_diagnostics, ...
            "Troposphere Profile Hydrostatic and Wet Diagnostics", ...
            troposphere_profile_description);
    end

    if atmosphereSectionEnabled
        stochastic_truth_residual_description = withDataUnavailableNote( ...
            ["The plot shows the tower-common stochastic truth atmosphere residuals injected into truth pseudoranges. " ...
             "Troposphere and ionosphere residual samples are generated independently, and their sum is the total truth atmosphere residual. " ...
             "These samples belong to the truth data-generation path, not the deterministic estimator atmosphere correction."], ...
            atmosphereSectionEnabled, ...
            stochasticTruthResidualPlotsEnabled, ...
            "finite stochastic truth atmosphere residual data are unavailable.");
        report = appendReportRow(report, true, ...
            plot_paths.stochastic_truth_residuals, ...
            "Stochastic Truth Atmosphere Residuals", ...
            stochastic_truth_residual_description);
    end
    
    if isfield(ctx, "measurementNoiseEnabled") && ~ctx.measurementNoiseEnabled
        nis_description = ["The plot shows NIS computed from the full EKF update innovation and covariance. " ...
            "Because range measurement noise injection is disabled in this deterministic validation, the curve is a numerical diagnostic only. " ...
            "It should not be interpreted as a chi-square consistency result."];
    else
        nis_description = ["The plot shows NIS computed from the full EKF update innovation and covariance. " ...
            "It may be interpreted as a chi-square consistency statistic only when all stochastic measurement channels are injected according to the same covariance used in R."];
    end
    report = appendReportRow(report, reportToggles.ekfOrbitClockEstimation, plot_paths.nis, ...
        "Normalised Innovation Squared", nis_description);
    report = appendReportRow(report, ...
        strlength(string(plot_paths.innovation_covariance_consistency)) > 0, ...
        plot_paths.innovation_covariance_consistency, ...
        "Innovation Covariance Consistency", ...
        ["The plot compares the pre-fit innovation RMS with the square root of the mean innovation covariance diagonal. " ...
         "It also shows NIS per degree of freedom and its square-root form. " ...
         "This is a statistical consistency diagnostic only when the injected stochastic errors match the covariance represented in R and S."]);
    if isfield(ctx, "enableElevationMask") && ctx.enableElevationMask
        visibility_description = ["The plot shows how many ground towers pass the tower-side elevation mask and are used by the EKF at each epoch. " ...
            sprintf("Elevation mask: %.2f deg.", ctx.elevationMask_deg)];
    else
        visibility_description = ["The plot shows how many tower rows are used by the EKF at each epoch. " ...
            "Elevation-mask visibility filtering is disabled."];
    end
    
    report = appendReportRow(report, isfield(ctx, "visible_tower_count"), plot_paths.visible_towers, ...
        "Tower Rows Used by the EKF", visibility_description);
    report = appendReportRow(report, reportToggles.groundSegment, plot_paths.geometry, ...
        "Ground-to-Space Geometry", ...
        ["The plot shows Earth, the selected ground segment, the GEO truth trajectory, and initial ground-to-space ranging paths. " ...
         "This component uses deterministic ECEF-to-ECI geometry and no stochastic propagation channel."]);
    report = appendReportRow(report, reportToggles.measurementNoise, "", ...
        "Measurement Noise Model", ...
        "Measurement noise is not part of the current clock-only validation scenario.");
    report = endPlotTable(report);

    if isfield(ctx, "innovation_covariance_summary_table")
        report = appendOptionalTable(report, ...
            "Innovation Covariance Summary", ...
            ctx, ...
            "innovation_covariance_summary_table", ...
            20);
    end

    if isfield(ctx, "stochastic_truth_residual_summary_table")
        report = appendOptionalTable(report, ...
            "Stochastic Truth Atmosphere Residual Summary", ...
            ctx, ...
            "stochastic_truth_residual_summary_table", ...
            20);
    end

    if atmosphereSectionEnabled
        report = appendOptionalTable(report, ...
            "Atmosphere Propagation Summary", ...
            ctx, ...
            "atmosphere_summary_table", ...
            20);

        if isfield(ctx, "ionosphere_map_summary_table")
            report = appendOptionalTable(report, ...
                "Ionosphere Pierce-Point TEC Diagnostics", ...
                ctx, ...
                "ionosphere_map_summary_table", ...
                20);
        end
        
        if isfield(ctx, "troposphere_profile_summary_table")
            report = appendOptionalTable(report, ...
                "Troposphere Profile Hydrostatic and Wet Diagnostics", ...
                ctx, ...
                "troposphere_profile_summary_table", ...
                20);
        end
    end
    %% 4. Per-Receiver Measurement Diagnostics
    report = appendLine(report, "\clearpage");
    report = appendLine(report, "\section{Per-Receiver Measurement Diagnostics}");
    report = appendParagraph(report, ['Receiver rows are generated dynamically from the enabled RX phase centres mounted on the SpaceAsset. ' ...
        'Receiver offsets are known local-frame geometry; receiver clocks, RF hardware delays, attitude, and antenna-offset states are not estimated in the active measurement path.']);
    report = beginPlotTable(report);
    report = appendReportRow(report, strlength(string(plot_paths.per_receiver_prefit_rms)) > 0, plot_paths.per_receiver_prefit_rms, ...
        "Per-Receiver Pre-Fit Pseudorange Residual RMS", ...
        ["Each curve is the tower-wise RMS pre-fit pseudorange residual for one receiver element. " ...
         "These are measurement-level residuals, not raw RF signal errors."]);
    report = appendReportRow(report, strlength(string(plot_paths.per_receiver_postfit_rms)) > 0, plot_paths.per_receiver_postfit_rms, ...
        "Per-Receiver Post-Fit Pseudorange Residual RMS", ...
        ["Each curve is the tower-wise RMS post-fit pseudorange residual for one receiver element after the EKF update. " ...
         "The fused EKF uses all enabled receiver/tower rows in the same update."]);
    report = appendReportRow(report, strlength(string(plot_paths.receiver_residual_heatmaps)) > 0, plot_paths.receiver_residual_heatmaps, ...
        "Per-Receiver Per-Tower Residual Heatmaps", ...
        ["The heatmaps keep RX1 and RX2 residuals separated by tower and epoch. " ...
         "Blank samples are non-visible or unused tower/receiver links."]);
    report = appendReportRow(report, strlength(string(plot_paths.receiver_pseudorange_error)) > 0, plot_paths.receiver_pseudorange_error, ...
        "Per-Receiver Pseudorange-Minus-Geometric Range", ...
        ["This plot shows the measurement-level pseudorange excess over geometric range. " ...
         "It contains clock terms and any generated noise; it is not a waveform-domain signal error."]);
    report = endPlotTable(report);
    
    %%  5. Oscillator Stability Validation
    report = appendLine(report, "\clearpage");
    report = appendLine(report, "\section{Oscillator Stability Validation}");
    report = beginPlotTable(report);
    if isfield(ctx, "clock_allan_names") && isfield(ctx, "sim_adev_by_clock")
        allan_description = ["The plot compares theoretical Allan deviation profiles with simulated result points for the spacecraft oscillator and every tower oscillator. " ...
            "The statistical approach is overlapping Allan deviation applied to independently simulated clock time-error records across the displayed averaging-time range."];
    else
        allan_description = ["The plot compares theoretical Allan deviation profiles with simulated result points for the selected satellite oscillator. " ...
            "The statistical approach is overlapping Allan deviation applied to independently simulated clock time-error records across the displayed averaging-time range."];
    end
    report = appendReportRow(report, reportToggles.allanDeviationValidation && reportToggles.satelliteClockError, plot_paths.allan, ...
        "Oscillator Stability Check", allan_description);
    if reportToggles.groundClockError
        if isfield(ctx, "est_ground_clock_bias_ps") && any(isfinite(ctx.est_ground_clock_bias_ps(:)))
            ground_clock_description = ["Ground transmitter clock error is enabled. " ...
                "The plot shows the true station-specific transmitter clock biases used in the pseudorange truth generation. " ...
                "The EKF is configured to estimate individual tower clock states, so tower-clock sensitivity is included in the measurement Jacobian."];
        else
            if isfield(ctx, "tower_clock_correction_s")
                ground_clock_description = ["Ground transmitter clock error is enabled. " ...
                    "The plot shows the true station-specific transmitter clock biases used in the raw pseudorange truth generation. " ...
                    "The spacecraft EKF does not estimate these tower clocks. The truth measurement contains the residual after any configured external correction; if correction is disabled, that residual is unmodelled in the EKF prediction."];
            else
                ground_clock_description = ["Ground transmitter clock error is enabled. " ...
                    "The plot shows the true station-specific transmitter clock biases used in the pseudorange truth generation. " ...
                    "These ground clock states are not estimated separately by the EKF in this scenario, so their effect appears through the ranging residuals and estimated receiver state."];
            end
        end
    else
        ground_clock_description = "Ground-clock error is intentionally not part of the current scenario because ground transmitter clocks are ideal references.";
    end
    report = appendReportRow(report, reportToggles.groundClockError, plot_paths.ground_clock_bias, ...
        "Ground Clock Error", ground_clock_description);
    if isfield(ctx, "tower_clock_correction_s")
        ground_timing_correction_description = ...
            ["The plot separates raw tower clock error, applied ground timing correction, and residual correction error. " ...
             "In externalTowerCorrections mode this is a Stage-1 abstraction: an external tower-clock correction product, not a physical GNSS common-view, TWSTFT, fiber, White Rabbit, or UTC(k) timing network."];
    else
        ground_timing_correction_description = ...
            "This scenario does not provide an external tower-clock correction product.";
    end
    report = appendReportRow(report, isfield(ctx, "tower_clock_correction_s"), plot_paths.ground_clock_correction, ...
        "External Ground Timing Correction", ground_timing_correction_description);
    report = appendReportRow(report, strlength(string(plot_paths.ground_clock_estimate)) > 0, plot_paths.ground_clock_estimate, ...
        "Tower Clock State Estimates", ...
        ["The plot compares true tower transmitter clock biases with EKF-estimated tower clock biases when tower-clock estimation is enabled. " ...
         "If estimation is disabled the plot is omitted and tower clocks act as transmitter-side measurement errors."]);
    if strlength(string(plot_paths.ground_clock_gauge_aligned)) > 0
        report = appendReportRow(report, true, plot_paths.ground_clock_gauge_aligned, ...
            "Gauge-Aligned Tower Clock State Estimates", ...
            ["The plot removes only the post-simulation common clock mode between the true and estimated network clocks. " ...
             "This diagnostic is not used in the EKF update; it shows the observable relative tower-clock modes for one-way pseudorange data."]);
    end
    report = endPlotTable(report);
    
    %% 6. Disabled Components
    report = appendLine(report, "\clearpage");
    report = appendLine(report, "\section{Disabled Components}");
    report = beginPlotTable(report);
    report = appendReportRow(report, reportToggles.j2Perturbation, "", "J2 Perturbation", "J2 perturbation is not part of the current clock-only validation scenario.");
    report = appendReportRow(report, reportToggles.relativisticClockTerm, "", "Relativistic Clock Term", "Relativistic clock modelling is not part of the current clock-only validation scenario.");
    if ~reportToggles.ionosphere
        report = appendReportRow(report, false, "", ...
            "Ionosphere", ...
            "Ionospheric propagation is disabled in this scenario.");
    end

    if ~reportToggles.troposphere
        report = appendReportRow(report, false, "", ...
            "Troposphere", ...
            "Tropospheric propagation is disabled in this scenario.");
    end
    report = appendReportRow(report, reportToggles.multipath, "", "Multipath", "Multipath and NLOS effects are not part of the current clock-only validation scenario.");
    report = appendReportRow(report, reportToggles.receiverThermalNoise, "", "Receiver Thermal Noise", "Receiver thermal noise is not part of the current clock-only validation scenario.");
    report = appendReportRow(report, reportToggles.antennaBias, "", "Antenna Bias", "Antenna phase-center and group-delay effects are not part of the current clock-only validation scenario.");
    report = appendReportRow(report, reportToggles.hardwareDelay, "", "Hardware Delay", "Transmitter and receiver hardware delay states are not part of the current clock-only validation scenario.");
    report = endPlotTable(report);
    
    %% 7. Numerical Summary
    report = appendLine(report, "\clearpage");
    report = appendLine(report, "\section{Numerical Summary}");
    report = appendParagraph(report, sprintf([ ...
        'The final-sample values are retained as endpoint diagnostics, but they should not be used alone to rank oscillator performance. ' ...
        'The run-level statistics below separate the full record, the period after the first %.2f hours, and the final %.2f hours.'], ...
        ctx.convergence_skip_seconds / 3600, ...
        ctx.final_window_seconds / 3600));
    if isfield(ctx, "clock_covariance_floor_enabled") && ctx.clock_covariance_floor_enabled
        report = appendParagraph(report, sprintf([ ...
            'Clock covariance regularisation is enabled for this run. ' ...
            'The EKF keeps a minimum estimated clock phase standard deviation of %.3g ps and a minimum estimated clock frequency standard deviation of %.3g ps/s. ' ...
            'This does not change the truth oscillator; it provides a lower bound for estimator covariance if the clock sub-state collapses numerically.'], ...
            ctx.clock_phase_covariance_floor_ps, ctx.clock_frequency_covariance_floor_ps_per_s));
    end
    if isfield(ctx, "numerical_measurement_sigma_floor_m") && ctx.numerical_measurement_sigma_floor_m > 0
        report = appendParagraph(report, sprintf([ ...
            'A %.3g m measurement covariance floor is applied only as numerical regularisation for the zero-noise ideal-product validation. ' ...
            'It is not receiver tracking noise, tower timing residual noise, atmosphere, multipath, or hardware delay.'], ...
            ctx.numerical_measurement_sigma_floor_m));
    end
    report = appendLine(report, "\begin{center}");
    report = appendLine(report, "\begin{tabular}{p{0.52\textwidth}p{0.25\textwidth}}");
    report = appendLine(report, "\toprule");
    report = appendLine(report, "\textbf{Quantity} & \textbf{Value}\\");
    report = appendLine(report, "\midrule");
    report = appendFinalValueRow(report, "Final 3D position estimation error", ctx.final_position_error_m, "m");
    report = appendFinalValueRow(report, "Final satellite clock estimation error", ctx.final_clock_error_ps, "ps");
    report = appendFinalValueRow(report, "Final satellite clock range-equivalent error", ctx.final_clock_range_equivalent_m, "m");
    if isfield(ctx, "final_attitude_error_norm_deg")
        report = appendFinalValueRow(report, "Final attitude error norm", ctx.final_attitude_error_norm_deg, "deg");
    end
    
    if isfield(ctx, "final_angular_velocity_error_norm_degps")
        report = appendFinalValueRow(report, "Final angular velocity error norm", ctx.final_angular_velocity_error_norm_degps, "deg/s");
    end
    report = appendFinalValueRow(report, "Final pre-fit pseudorange innovation RMS", ctx.final_prefit_innovation_rms_m, "m");
    report = appendFinalValueRow(report, "Final post-fit pseudorange residual RMS", ctx.final_postfit_residual_rms_m, "m");

    if isfield(ctx, "mean_truth_atmosphere_delay_m")
        report = appendFinalValueRow(report, ...
            "Mean truth atmospheric code delay", ...
            ctx.mean_truth_atmosphere_delay_m, ...
            "m");
    end

    if isfield(ctx, "mean_model_atmosphere_delay_m")
        report = appendFinalValueRow(report, ...
            "Mean estimator atmospheric correction", ...
            ctx.mean_model_atmosphere_delay_m, ...
            "m");
    end

    if isfield(ctx, "mean_atmosphere_model_residual_m")
        report = appendFinalValueRow(report, ...
            "Mean truth minus model atmospheric residual", ...
            ctx.mean_atmosphere_model_residual_m, ...
            "m");
    end

    if isfield(ctx, "truth_atmosphere_residual_sigma_m")
        report = appendFinalValueRow(report, ...
            "Truth atmospheric residual sigma", ...
            ctx.truth_atmosphere_residual_sigma_m, ...
            "m");
    end

    if isfield(ctx, "model_atmosphere_residual_sigma_m")
        report = appendFinalValueRow(report, ...
            "Estimator atmospheric residual sigma used in R", ...
            ctx.model_atmosphere_residual_sigma_m, ...
            "m");
    end

    if isfield(ctx, "ground_clock_range_rms_m")
        report = appendFinalValueRow(report, "Final ground transmitter clock range RMS", ctx.ground_clock_range_rms_m(end), "m");
    end
    if isfield(ctx, "final_tower_clock_rms_ps")
        if isfield(ctx, "clockGaugeMode") && string(ctx.clockGaugeMode) == "fixReferenceTxDelay"
            tower_clock_label = "Final TX signal-delay time-equivalent RMS";
        elseif isfield(ctx, "clockGaugeMode") && string(ctx.clockGaugeMode) == "externalTimeTransfer"
            tower_clock_label = "Final externally referenced tower clock RMS";
        else
            tower_clock_label = "Final relative tower clock RMS";
        end
        report = appendFinalValueRow(report, tower_clock_label, ctx.final_tower_clock_rms_ps, "ps");
    end
    if isfield(ctx, "final_H_rank")
        report = appendFinalValueRow(report, "Final measurement Jacobian rank", ctx.final_H_rank, "-");
    end
    if isfield(ctx, "final_observability_rank")
        report = appendFinalValueRow(report, "Final sliding-window observability rank", ctx.final_observability_rank, "-");
    end
    if isfield(ctx, "final_common_mode_residual_norm")
        report = appendFinalValueRow(report, "Final pseudorange common-mode null residual", ctx.final_common_mode_residual_norm, "-");
    end
    if isfield(ctx, "final_covariance_condition_number")
        report = appendFinalValueRow(report, "Final EKF covariance condition number", ctx.final_covariance_condition_number, "-");
    end
    if isfield(ctx, "final_innovation_condition_number")
        report = appendFinalValueRow(report, "Final innovation covariance condition number", ctx.final_innovation_condition_number, "-");
    end
    if isfield(ctx, "nis_mean_final_window")
        report = appendFinalValueRow(report, "Final-window NIS mean", ctx.nis_mean_final_window, "-");
    end
    if isfield(ctx, "nis_expected_dof_final_window")
        report = appendFinalValueRow(report, "Final-window mean measurement DoF", ctx.nis_expected_dof_final_window, "-");
    end
    if isfield(ctx, "final_raw_tower_clock_residual_rms_m")
        report = appendFinalValueRow(report, "Final raw tower-clock effect RMS before correction", ctx.final_raw_tower_clock_residual_rms_m, "m");
    end
    if isfield(ctx, "final_corrected_tower_clock_residual_rms_m")
        report = appendFinalValueRow(report, "Final corrected tower-clock effect RMS after correction", ctx.final_corrected_tower_clock_residual_rms_m, "m");
    end
    if isfield(ctx, "final_ground_timing_residual_rms_m")
        report = appendFinalValueRow(report, "Final residual ground timing correction RMS", ctx.final_ground_timing_residual_rms_m, "m");
    end
    if isfield(ctx, "clock_allan_names") && isfield(ctx, "clock_allan_deviation_1s")
        for idx_clock = 1:numel(ctx.clock_allan_names)
            allan_label = sprintf("%s Allan deviation at 1 s", char(string(ctx.clock_allan_names(idx_clock))));
            report = appendLine(report, sprintf("%s & %s\\\\", ...
                latexEscape(allan_label), formatEngineering(ctx.clock_allan_deviation_1s(idx_clock), "")));
        end
    else
        report = appendLine(report, sprintf("Selected oscillator Allan deviation at 1 s & %s\\\\", formatEngineering(ctx.selected_allan_deviation_1s, "")));
    end
    report = appendLine(report, "\bottomrule");
    report = appendLine(report, "\end{tabular}");
    report = appendLine(report, "\end{center}");
    
    report = appendLine(report, "\vspace{0.25cm}");
    report = appendLine(report, "\begin{center}");
    report = appendLine(report, "\scriptsize");
    report = appendLine(report, "\begin{tabular}{p{0.28\textwidth}p{0.13\textwidth}p{0.13\textwidth}p{0.13\textwidth}p{0.13\textwidth}}");
    report = appendLine(report, "\toprule");
    report = appendLine(report, "\textbf{Metric} & \textbf{Full RMS} & \textbf{After 1 h RMS} & \textbf{Final h RMS} & \textbf{Final h 95\% abs.}\\");
    report = appendLine(report, "\midrule");
    report = appendSummaryMetricRow(report, "3D position error [m]", ctx.position_error_summary_m, ctx.position_error_final_window_summary_m);
    report = appendSummaryMetricRow(report, "Clock estimation error [ps]", ctx.clock_error_summary_ps, ctx.clock_error_final_window_summary_ps);
    report = appendSummaryMetricRow(report, "Clock range-equivalent error [m]", ctx.clock_error_range_summary_m, ctx.clock_error_range_final_window_summary_m);
    report = appendSummaryMetricRow(report, "Pre-fit innovation RMS [m]", ctx.prefit_innovation_summary_m, ctx.prefit_innovation_final_window_summary_m);
    report = appendSummaryMetricRow(report, "Post-fit residual RMS [m]", ctx.postfit_innovation_summary_m, ctx.postfit_innovation_final_window_summary_m);
    if isfield(ctx, "ground_clock_range_summary_m")
        report = appendSummaryMetricRow(report, "Ground clock range RMS [m]", ctx.ground_clock_range_summary_m, ctx.ground_clock_range_final_window_summary_m);
    end
    if isfield(ctx, "raw_tower_clock_residual_summary_m")
        report = appendSummaryMetricRow(report, "Raw tower-clock effect RMS [m]", ctx.raw_tower_clock_residual_summary_m, ctx.raw_tower_clock_residual_final_window_summary_m);
    end
    if isfield(ctx, "corrected_tower_clock_residual_summary_m")
        report = appendSummaryMetricRow(report, "Corrected tower-clock effect RMS [m]", ctx.corrected_tower_clock_residual_summary_m, ctx.corrected_tower_clock_residual_final_window_summary_m);
    end
    if isfield(ctx, "ground_clock_correction_residual_summary_m")
        report = appendSummaryMetricRow(report, "Ground timing residual RMS [m]", ctx.ground_clock_correction_residual_summary_m, ctx.ground_clock_correction_residual_final_window_summary_m);
    end
    report = appendSummaryMetricRow(report, "EKF covariance condition [-]", ctx.covariance_condition_summary, ctx.covariance_condition_final_window_summary);
    report = appendSummaryMetricRow(report, "Innovation covariance condition [-]", ctx.innovation_condition_summary, ctx.innovation_condition_final_window_summary);
    report = appendLine(report, "\bottomrule");
    report = appendLine(report, "\end{tabular}");
    report = appendLine(report, "\end{center}");
    report = appendLine(report, "\end{document}");
    
    output_base_name = char(string(reportConfig.outputBaseName));
    tex_file_name = [output_base_name '.tex'];
    pdf_file_name = [output_base_name '.pdf'];
    tex_path = fullfile(report_root, tex_file_name);
    writeTextFile(tex_path, report);
    
    if reportConfig.compilePdf
        old_dir = pwd;
        cd(report_root);
        pdflatex_command = findPdfLatex(reportConfig);
        if strlength(pdflatex_command) > 0
            compile_command = sprintf('"%s" -interaction=nonstopmode -halt-on-error "%s"', char(pdflatex_command), tex_file_name);
            [compile_status, compile_output] = system(compile_command);
            if compile_status ~= 0
                cd(old_dir);
                error("generateReport:LatexCompileFailed", "%s", compile_output);
            end
            fprintf('generateReport: report PDF created:\n%s\n', fullfile(report_root, pdf_file_name));
        else
            fprintf('generateReport: pdflatex not found. Wrote LaTeX file:\n%s\n', tex_path);
        end
        cd(old_dir);
    else
        fprintf('generateReport: wrote LaTeX file:\n%s\n', tex_path);
    end
end
%% Report Table Builders
function ctx = prepareReportContext(sim)
    history = sim.history;
    errors = history.errors;
    diags = history.diagnostics;
    xHist = history.x;
    truthHist = history.truth;
    Pdiag = history.covariance_diag;

    ctx = struct();
    ctx.sim = sim;
    ctx.history = history;
    ctx.error_budget_status = ResultBuilder.errorBudgetStatus(sim);
    ctx.time_vec = sim.time_s;
    ctx.total_time_hours = max(sim.time_s) / 3600.0;
    ctx.dt = sim.dt;
    ctx.c = sim.c;
    ctx.num_towers = sim.numTowers;
    ctx.R_earth = sim.constants.earthRadius_m;
    ctx.oscillators = sim.simConfig.clockLibrary;
    ctx.towers = reportTowersLocal(sim);
    ctx.tower_names = sim.towerNames;
    ctx.receiver_names = sim.receiverNames;

    ctx.asset_name = string(sim.assetConfig.name);
    ctx.state_names = StateIndexFactory.stateNames( ...
        sim.towerNames, GroundTimingNetwork.towerClockEkfEnabled(sim.cfg));
    ctx.state_dim = sim.stateDim;
    ctx.state_index = sim.idx;
    ctx.enable_tower_clock_ekf = GroundTimingNetwork.towerClockEkfEnabled(sim.cfg);
    ctx.num_receivers = sim.numReceivers;
    ctx.receiver_offsets_body_m = sim.receiverOffsetsBody_m;
    ctx.initial_truth_position_eci_m = sim.initialTruth0(sim.idx.pos);
    ctx.initial_est_position_eci_m = sim.initialX0(sim.idx.pos);
    ctx.observability_normal_matrix = sim.observabilityNormalMatrix;

    ctx.ekf_pos_error_m = xHist(sim.idx.pos, :) - truthHist(sim.idx.pos, :);
    ctx.ekf_pos_sigma_m = sqrt(max(Pdiag(sim.idx.pos, :), 0));
    ctx.ekf_clock_error_ps = ...
        (xHist(sim.idx.rxClockBias, :) - truthHist(sim.idx.rxClockBias, :)) ./ sim.c .* 1e12;
    ctx.ekf_clock_sigma_ps = ...
        sqrt(max(Pdiag(sim.idx.rxClockBias, :), 0)) ./ sim.c .* 1e12;
    ctx.true_clock_bias_ps = truthHist(sim.idx.rxClockBias, :) ./ sim.c .* 1e12;
    ctx.est_clock_bias_ps = xHist(sim.idx.rxClockBias, :) ./ sim.c .* 1e12;

    if GroundTimingNetwork.towerClockEkfEnabled(sim.cfg)
        ctx.est_tower_clock_bias_ps = ...
            xHist(sim.idx.towerClockBias, :) ./ sim.c .* 1e12;
        ctx.true_tower_clock_bias_ps = ...
            truthHist(sim.idx.towerClockBias, :) ./ sim.c .* 1e12;
        ctx.est_tower_clock_drift_psps = ...
            xHist(sim.idx.towerClockDrift, :) ./ sim.c .* 1e12;
        ctx.true_tower_clock_drift_psps = ...
            truthHist(sim.idx.towerClockDrift, :) ./ sim.c .* 1e12;
    end

    ctx.innovation_rms_m = history.innovation_rms_m;
    ctx.postfit_innovation_rms_m = history.postfit_innovation_rms_m;
    ctx.nis_history = history.nis_history;
    ctx.innovation_covariance_mean_variance_m2 = ...
        history.innovation_covariance_mean_variance_m2;
    ctx.innovation_covariance_min_variance_m2 = ...
        history.innovation_covariance_min_variance_m2;
    ctx.innovation_covariance_max_variance_m2 = ...
        history.innovation_covariance_max_variance_m2;
    ctx.nis_per_degree_of_freedom = history.nis_per_degree_of_freedom;
    ctx.measurement_covariance_range_mean_variance_m2 = ...
        history.measurement_covariance_range_mean_variance_m2;
    ctx.measurement_covariance_range_max_offdiag_m2 = ...
        history.measurement_covariance_range_max_offdiag_m2;
    ctx.measurement_covariance_range_dimension = ...
        history.measurement_covariance_range_dimension;
    ctx.measurement_covariance_update_mean_variance_m2 = ...
        history.measurement_covariance_update_mean_variance_m2;
    ctx.measurement_covariance_update_max_offdiag_m2 = ...
        history.measurement_covariance_update_max_offdiag_m2;
    ctx.measurement_covariance_update_dimension = ...
        history.measurement_covariance_update_dimension;
    ctx.normalized_innovation_rms = history.normalized_innovation_rms;
    ctx.sat_pos_history_m = history.sat_pos_history_m;
    ctx.nis_degrees_of_freedom = history.measurement_count;

    ctx.innovation_covariance_mean_sigma_m = ...
        sqrt(max(ctx.innovation_covariance_mean_variance_m2, 0.0));
    ctx.innovation_covariance_min_sigma_m = ...
        sqrt(max(ctx.innovation_covariance_min_variance_m2, 0.0));
    ctx.innovation_covariance_max_sigma_m = ...
        sqrt(max(ctx.innovation_covariance_max_variance_m2, 0.0));

    ctx.towers_eci_first_m = sim.towersEciFirst_m;
    ctx.final_position_error_m = norm(ctx.ekf_pos_error_m(:, end));
    ctx.final_clock_error_ps = ctx.ekf_clock_error_ps(end);
    ctx.final_innovation_rms_m = history.innovation_rms_m(end);

    ctx.attitude_truth_deg = rad2deg(truthHist(sim.idx.att, :));
    ctx.attitude_est_deg = rad2deg(xHist(sim.idx.att, :));
    ctx.attitude_error_deg = rad2deg( ...
        FrameGeometry.wrapToPi(xHist(sim.idx.att, :) - truthHist(sim.idx.att, :)));
    ctx.attitude_sigma_deg = rad2deg(sqrt(max(Pdiag(sim.idx.att, :), 0)));
    ctx.attitude_state_names = ["roll"; "pitch"; "yaw"];
    ctx.attitude_frame = "body-to-ECI Euler view of q_BI";

    ctx.angular_velocity_truth_degps = rad2deg(truthHist(sim.idx.omega, :));
    ctx.angular_velocity_est_degps = rad2deg(xHist(sim.idx.omega, :));
    ctx.angular_velocity_error_degps = ...
        rad2deg(xHist(sim.idx.omega, :) - truthHist(sim.idx.omega, :));
    ctx.angular_velocity_sigma_degps = ...
        rad2deg(sqrt(max(Pdiag(sim.idx.omega, :), 0)));
    ctx.angular_velocity_state_names = ["omega_x"; "omega_y"; "omega_z"];
    ctx.final_attitude_error_norm_deg = norm(ctx.attitude_error_deg(:, end));
    ctx.final_angular_velocity_error_norm_degps = ...
        norm(ctx.angular_velocity_error_degps(:, end));

    ctx.final_H_pos_rank = history.H_pos_rank_history(end);
    ctx.final_H_att_rank = history.H_att_rank_history(end);
    ctx.final_H_pos_att_clock_rank = history.H_pos_att_clock_rank_history(end);
    ctx.final_H_pos_column_norm = history.H_pos_column_norm_history(:, end);
    ctx.final_H_att_column_norm = history.H_att_column_norm_history(:, end);
    ctx.final_H_rx_clock_bias_column_norm = ...
        history.H_rx_clock_bias_column_norm_history(end);
    ctx.H_rank_history = history.H_rank_history;
    ctx.H_pos_rank_history = history.H_pos_rank_history;
    ctx.H_att_rank_history = history.H_att_rank_history;
    ctx.H_pos_att_clock_rank_history = history.H_pos_att_clock_rank_history;
    ctx.H_rx_clock_bias_column_norm_history = ...
        history.H_rx_clock_bias_column_norm_history;
    ctx.pseudorange_measurement_count = history.pseudorange_measurement_count;
    ctx.final_H_rank = history.H_rank_history(end);
    ctx.H_row_count_history = history.measurement_count;
    ctx.H_column_count_history = sim.stateDim * ones(1, sim.numSteps);
    ctx.H_rank_to_state_dim_history = ...
        history.H_rank_history ./ max(sim.stateDim, 1);
    ctx.H_state_deficiency_history = sim.stateDim - history.H_rank_history;
    ctx.final_H_rows = history.measurement_count(end);
    ctx.final_H_columns = sim.stateDim;
    ctx.final_H_rank_to_state_dim = ctx.final_H_rank / max(sim.stateDim, 1);
    ctx.final_H_state_deficiency = sim.stateDim - ctx.final_H_rank;

    ctx.true_ground_clock_bias_ps = history.ground_clock_true_m ./ sim.c .* 1e12;
    ctx.tower_clock_correction_s = history.ground_clock_correction_m ./ sim.c;
    ctx.tower_clock_correction_residual_s = history.ground_clock_residual_m ./ sim.c;
    ctx.tower_clock_correction_sigma_s = ...
        ones(sim.numTowers, sim.numSteps) .* ...
        sqrt(GroundTimingNetwork.residualVariance_m2(sim.cfg, sim.c)) ./ sim.c;

    ctx.prefit_residual_by_receiver_tower_m = ...
        history.prefit_residual_by_receiver_tower_m;
    ctx.postfit_residual_by_receiver_tower_m = ...
        history.postfit_residual_by_receiver_tower_m;
    ctx.pseudorange_by_receiver_tower_m = history.pseudorange_by_receiver_tower_m;
    ctx.true_range_by_receiver_tower_m = history.true_range_by_receiver_tower_m;
    ctx.los_unit_eci_by_receiver_tower = history.los_unit_eci_by_receiver_tower;
    ctx.covariance_condition_number = history.covariance_condition_number;
    ctx.innovation_condition_number = history.innovation_condition_number;
    ctx.visible_tower_count = history.visible_tower_count;

    ctx = addAtmosphereReportSummaries(ctx, sim, errors, diags);

    ctx.pseudorange_error_by_receiver_tower_m = ...
        history.pseudorange_by_receiver_tower_m - history.true_range_by_receiver_tower_m;
    ctx.receiver_offset_body_by_receiver_m = sim.receiverOffsetsBody_m;
    ctx.used_tower_count = history.visible_tower_count;
    ctx.measurementNoiseEnabled = sim.measurementModel.measurementNoiseEnabled();
    ctx.numerical_measurement_sigma_floor_m = ...
        sim.measurementModel.effectiveNumericalMeasurementSigma_m();
    ctx.enableElevationMask = sim.measurementModel.elevationMaskEnabled();
    ctx.elevationMask_deg = sim.measurementModel.elevationMaskDeg();

    if GroundTimingNetwork.towerClockEkfEnabled(sim.cfg)
        ctx.clockGaugeMode = "towerClockEKF_meanGroundClockGauge";
        ctx.referenceTowerName = "Mean ground-network clock";
        ctx.clock_estimation_mode = 'spacecraftReceiverClockPlusTowerClockEKF';
    else
        if GroundTimingNetwork.groundClockCorrectionEnabled(sim.cfg)
            ctx.clockGaugeMode = "externalTowerCorrections";
            ctx.referenceTowerName = "External ground timing product";
        else
            ctx.clockGaugeMode = "groundClockResidualsGeneratedButNotEstimated";
            ctx.referenceTowerName = "";
        end
        ctx.clock_estimation_mode = 'spacecraftReceiverClockOnly';
    end

    ctx.ekf_clock_state_units = 'metres and metres per second';
    ctx.receiver_architecture_note = sprintf( ...
        'N=%d onboard receiver phase centres share one receiver oscillator. Lever arms are Body-frame vectors rotated by q_BI into ECI.', ...
        sim.numReceivers);
    if GroundTimingNetwork.towerClockEkfEnabled(sim.cfg)
        ctx.signal_model_note = [ ...
            'Truth code pseudorange: P = rho(r_sc_I + C_BI l_a_B, r_g_I) + b_rx_true - b_g_true + d_truth + noise. ' ...
            'Estimator prediction: P_hat = rho(rhat_sc_I + Chat_BI l_a_B, r_g_I) + bhat_rx - bhat_g + d_model. ' ...
            'Tower clocks are EKF states and the mean ground-network clock defines the time gauge.'];
    else
        ctx.signal_model_note = [ ...
            'Truth code pseudorange: P = rho(r_sc_I + C_BI l_a_B, r_g_I) + b_rx_true - b_g_res_true + d_truth + noise. ' ...
            'Estimator prediction: P_hat = rho(rhat_sc_I + Chat_BI l_a_B, r_g_I) + bhat_rx + d_model. ' ...
            'In spacecraftReceiverClockOnly mode, b_g_res is not an EKF state and d_model is supplied by the configured estimator atmosphere model.'];
    end
    ctx.attitude_observability_note = ...
        ['Attitude remains in the EKF for every receiver count. Its pseudorange sensitivity is ' ...
         '-g^T C_BI skew(l_a_B), where g = u + grad_r(d_model); zero lever arms produce zero attitude sensitivity naturally.'];
    ctx.attitude_filter_note = ...
        'MEKF-style attitude update uses a body-frame small-angle error injected multiplicatively into q_BI.';
    ctx.propagation_frame_note = sprintf( ...
        ['Range geometry frame: %s. Current geometry uses ECI ', ...
         'transmitter and receiver positions evaluated at the receiver epoch; ', ...
         'optional inertial iterative light-time is guarded against ', ...
         'legacy scalar Sagnac double counting.'], ...
        char(sim.measurementModel.propagationFrame));
    ctx.relativity_note = ...
        ['Relativistic path delay and relativistic clock correction are explicit ', ...
         'zero-valued diagnostics when disabled. Enabling either flag currently ', ...
         'raises an error until a physical path/clock implementation is added.'];
    ctx.measurement_model_equation = [ ...
        "\begin{aligned}"; ...
        "P_{g,a}^{truth}"; ...
        "&= \left\| \mathbf{r}_{sc,I} + \mathbf{C}_{BI}\mathbf{l}_{a,B} - \mathbf{r}_{g,I} \right\|"; ...
        "&= + b_{rx}^{true} - b_{g,res}^{true} + d_{truth} + \nu \\"; ...
        "\hat{P}_{g,a}"; ...
        "&= \left\| \hat{\mathbf{r}}_{sc,I} + \hat{\mathbf{C}}_{BI}\mathbf{l}_{a,B} - \mathbf{r}_{g,I} \right\|"; ...
        "&= + \hat{b}_{rx} + d_{model}"; ...
        "\end{aligned}" ...
        ];
    ctx.observation_matrix_equation = [...
        "\begin{aligned}"; ...
        "\mathbf{g} = \mathbf{u} + \nabla_{\mathbf{r}_{rx,I}} d_{model}, \qquad H_{g,a}";...
        " &= \left[ \mathbf{g}^{T} \quad \mathbf{0}_{1\times3} \quad \mathbf{g}^{T}(-\mathbf{C}_{BI}" + ...
        " \mathbf{l}_{a,B}]_{\times}) \quad \mathbf{0}_{1\times3} \quad 1 \quad 0 \right]";...
        "\end{aligned}" ...
        ];

    ctx.prefit_residual_by_tower_m = ...
        squeeze(mean(history.prefit_residual_by_receiver_tower_m, 1));
    ctx.postfit_residual_by_tower_m = ...
        squeeze(mean(history.postfit_residual_by_receiver_tower_m, 1));

    nRows = sim.numReceivers * sim.numTowers;
    receiverR2 = sim.cfg.measurement.pseudorangeSigma_m^2 * ...
        double(sim.measurementModel.measurementNoiseEnabled());
    groundR2 = GroundTimingNetwork.residualVariance_m2(sim.cfg, sim.c);
    if GroundTimingNetwork.towerClockEkfEnabled(sim.cfg)
        appliedGroundR2 = 0.0;
    else
        appliedGroundR2 = groundR2;
    end
    atmosphereR2 = sim.measurementModel.atmosphereResidualVariance_m2();
    actualR2 = sim.measurementModel.measurementVariance( ...
        GroundTimingNetwork.towerClockEkfEnabled(sim.cfg), groundR2);
    ctx.R_receiver_m2 = ones(nRows, sim.numSteps) * receiverR2;
    ctx.R_tower_clock_m2 = ones(nRows, sim.numSteps) * appliedGroundR2;
    ctx.R_atmosphere_m2 = ones(nRows, sim.numSteps) * atmosphereR2;
    ctx.R_hardware_m2 = zeros(nRows, sim.numSteps);
    ctx.R_multipath_m2 = zeros(nRows, sim.numSteps);
    ctx.R_numerical_regularization_m2 = ...
        ones(nRows, sim.numSteps) * ...
        max(actualR2 - receiverR2 - appliedGroundR2 - atmosphereR2, 0.0);
    ctx.R_total_m2 = ctx.R_receiver_m2 + ctx.R_tower_clock_m2 + ...
        ctx.R_atmosphere_m2 + ctx.R_numerical_regularization_m2;
    ctx.innovation_covariance_summary_table = ...
        buildInnovationCovarianceSummaryTable(ctx);

    obs = ObservabilityAnalyzer.analyzeNormalMatrix( ...
        sim.observabilityNormalMatrix, ctx.state_names);
    ctx.final_observability_rank = obs.rank;
    ctx.weak_observability_state_names = obs.weakStateNames;
    ctx.observability_note = sprintf( ...
        'Column-normalized accumulated pseudorange observability rank is %d of %d states. Weak states: %s.', ...
        obs.rank, sim.stateDim, strjoin(string(obs.weakStateNames), ', '));

    selectedOsc = sim.simConfig.clockLibrary.(char(sim.assetConfig.clock.clockType));
    selectedClock = Clock(selectedOsc.h0, selectedOsc.hm1, selectedOsc.hm2, sim.dt);
    nAllan = floor(sim.simConfig.validation.allanValidationSamples);
    ctx.tau_profile_s = validTauForSamplesLocal( ...
        sim.simConfig.validation.tauProfile_s, sim.dt, nAllan);
    clockValidationList = [{selectedClock}, GroundNode.clocks(sim.towers)];
    clockNames = ["SpaceAsset RX", sim.towerNames];
    nClock = numel(clockValidationList);
    clockAdev1s = NaN(1, nClock);
    simAdevByClock = NaN(nClock, 0);

    for idxClock = 1:nClock
        [tauThis_s, adevThis, sigmaThis, edfThis] = ...
            runClockAllanValidationLocal( ...
            clockValidationList{idxClock}, ...
            sim.simConfig.validation.tauSimulation_s, ...
            sim.dt, nAllan, sim.validationClockStream);

        if idxClock == 1
            ctx.tau_sim_s = tauThis_s;
            ctx.sim_adev = adevThis;
            ctx.sim_adev_sigma = sigmaThis;
            ctx.sim_adev_edf = edfThis;
            simAdevByClock = NaN(nClock, numel(tauThis_s));
        end

        simAdevByClock(idxClock, :) = adevThis;
        clockAdev1s(idxClock) = ...
            clockValidationList{idxClock}.theoreticalAllanDeviation(1.0);
    end

    ctx.selected_allan_deviation_1s = ...
        selectedClock.theoreticalAllanDeviation(1.0);
    ctx.clock_allan_names = clockNames;
    ctx.clock_allan_deviation_1s = clockAdev1s;
    ctx.sim_adev_by_clock = simAdevByClock;
    ctx.seedConfig = sim.seedConfig;
    ctx.source_references = {sprintf('Generated by %s.', sim.entryPointName)};
end

function ctx = addAtmosphereReportSummaries(ctx, sim, errors, diags)
    totalResidualByTower_m = errors.atmosphere.stochasticResidualByTower_m;
    tropoResidualByTower_m = errors.troposphere.stochasticResidualByTower_m;
    ionoResidualByTower_m = errors.ionosphere.stochasticResidualByTower_m;

    ctx.truth_atmosphere_residual_mean_m = mean(totalResidualByTower_m(:), 'omitnan');
    ctx.truth_atmosphere_residual_std_m = std(totalResidualByTower_m(:), 0, 'omitnan');
    ctx.truth_atmosphere_residual_rms_m = sqrt(mean(totalResidualByTower_m(:).^2, 'omitnan'));
    ctx.truth_atmosphere_residual_max_abs_m = max(abs(totalResidualByTower_m(:)), [], 'omitnan');
    ctx.truth_troposphere_residual_mean_m = mean(tropoResidualByTower_m(:), 'omitnan');
    ctx.truth_troposphere_residual_std_m = std(tropoResidualByTower_m(:), 0, 'omitnan');
    ctx.truth_troposphere_residual_rms_m = sqrt(mean(tropoResidualByTower_m(:).^2, 'omitnan'));
    ctx.truth_troposphere_residual_max_abs_m = max(abs(tropoResidualByTower_m(:)), [], 'omitnan');
    ctx.truth_ionosphere_residual_mean_m = mean(ionoResidualByTower_m(:), 'omitnan');
    ctx.truth_ionosphere_residual_std_m = std(ionoResidualByTower_m(:), 0, 'omitnan');
    ctx.truth_ionosphere_residual_rms_m = sqrt(mean(ionoResidualByTower_m(:).^2, 'omitnan'));
    ctx.truth_ionosphere_residual_max_abs_m = max(abs(ionoResidualByTower_m(:)), [], 'omitnan');

    ctx.truth_troposphere_residual_config_sigma_m = ...
        double(sim.truthAtmosphere.residualTroposphereSigma_m) * ...
        double(sim.truthAtmosphere.enableTroposphere);
    ctx.truth_ionosphere_residual_config_sigma_m = ...
        double(sim.truthAtmosphere.residualIonosphereSigma_m) * ...
        double(sim.truthAtmosphere.enableIonosphere);
    ctx.truth_total_residual_config_sigma_m = hypot( ...
        ctx.truth_troposphere_residual_config_sigma_m, ...
        ctx.truth_ionosphere_residual_config_sigma_m);

    ctx.mean_truth_atmosphere_delay_m = mean(errors.atmosphere.truth_m(:), 'omitnan');
    ctx.mean_model_atmosphere_delay_m = mean(errors.atmosphere.model_m(:), 'omitnan');
    ctx.mean_atmosphere_model_residual_m = mean(errors.atmosphere.residual_m(:), 'omitnan');
    ctx.model_atmosphere_residual_sigma_m = ...
        sim.measurementModel.modelAtmosphere.residualCodeSigma_m();
    ctx.truth_atmosphere_residual_sigma_m = ...
        sim.measurementModel.truthAtmosphere.residualCodeSigma_m();
    ctx.mean_deterministic_atmosphere_model_residual_m = ...
        mean(errors.atmosphere.deterministicResidual_m(:), 'omitnan');
    ctx.model_atmosphere_residual_variance_m2 = ...
        mean(errors.atmosphere.variance_m2(:), 'omitnan');
    ctx.model_atmosphere_covariance_structure = string(errors.atmosphere.correlationModel);

    ctx.atmosphere_summary_table = buildAtmosphereSummaryTable(sim, ctx);
    ctx.stochastic_truth_residual_summary_table = ...
        buildStochasticTruthResidualSummaryTable(ctx);
    ctx.ionosphere_map_summary_table = buildIonosphereMapSummaryTable(sim, diags);
    ctx.troposphere_profile_summary_table = ...
        buildTroposphereProfileSummaryTable(sim, diags);
end

function tableOut = buildInnovationCovarianceSummaryTable(ctx)
    Quantity = [ ...
        "Mean pre-fit innovation RMS [m]"; ...
        "Mean post-fit innovation RMS [m]"; ...
        "Mean innovation covariance sigma [m]"; ...
        "Minimum innovation covariance sigma [m]"; ...
        "Maximum innovation covariance sigma [m]"; ...
        "Mean NIS [-]"; ...
        "Mean NIS per degree of freedom [-]"; ...
        "Mean normalised innovation RMS [-]"; ...
        "Mean receiver-noise R contribution sigma [m]"; ...
        "Mean tower-clock R contribution sigma [m]"; ...
        "Mean atmosphere R contribution sigma [m]"; ...
        "Mean numerical-regularisation R contribution sigma [m]"; ...
        "Mean total diagonal R contribution sigma [m]" ...
        ];

    Value = [ ...
        scalarText(mean(ctx.innovation_rms_m(:), 'omitnan')); ...
        scalarText(mean(ctx.postfit_innovation_rms_m(:), 'omitnan')); ...
        scalarText(mean(ctx.innovation_covariance_mean_sigma_m(:), 'omitnan')); ...
        scalarText(mean(ctx.innovation_covariance_min_sigma_m(:), 'omitnan')); ...
        scalarText(mean(ctx.innovation_covariance_max_sigma_m(:), 'omitnan')); ...
        scalarText(mean(ctx.nis_history(:), 'omitnan')); ...
        scalarText(mean(ctx.nis_per_degree_of_freedom(:), 'omitnan')); ...
        scalarText(mean(ctx.normalized_innovation_rms(:), 'omitnan')); ...
        scalarText(sqrt(mean(ctx.R_receiver_m2(:), 'omitnan'))); ...
        scalarText(sqrt(mean(ctx.R_tower_clock_m2(:), 'omitnan'))); ...
        scalarText(sqrt(mean(ctx.R_atmosphere_m2(:), 'omitnan'))); ...
        scalarText(sqrt(mean(ctx.R_numerical_regularization_m2(:), 'omitnan'))); ...
        scalarText(sqrt(mean(ctx.R_total_m2(:), 'omitnan'))) ...
        ];

    tableOut = table(Quantity, Value);
end

function tableOut = buildStochasticTruthResidualSummaryTable(ctx)
    Quantity = [ ...
        "Configured truth troposphere residual sigma [m]"; ...
        "Configured truth ionosphere residual sigma [m]"; ...
        "Configured truth total residual sigma [m]"; ...
        "Sample mean total truth residual [m]"; ...
        "Sample std total truth residual [m]"; ...
        "Sample RMS total truth residual [m]"; ...
        "Sample max abs total truth residual [m]"; ...
        "Sample mean troposphere truth residual [m]"; ...
        "Sample std troposphere truth residual [m]"; ...
        "Sample RMS troposphere truth residual [m]"; ...
        "Sample max abs troposphere truth residual [m]"; ...
        "Sample mean ionosphere truth residual [m]"; ...
        "Sample std ionosphere truth residual [m]"; ...
        "Sample RMS ionosphere truth residual [m]"; ...
        "Sample max abs ionosphere truth residual [m]" ...
        ];

    Value = [ ...
        scalarText(ctx.truth_troposphere_residual_config_sigma_m); ...
        scalarText(ctx.truth_ionosphere_residual_config_sigma_m); ...
        scalarText(ctx.truth_total_residual_config_sigma_m); ...
        scalarText(ctx.truth_atmosphere_residual_mean_m); ...
        scalarText(ctx.truth_atmosphere_residual_std_m); ...
        scalarText(ctx.truth_atmosphere_residual_rms_m); ...
        scalarText(ctx.truth_atmosphere_residual_max_abs_m); ...
        scalarText(ctx.truth_troposphere_residual_mean_m); ...
        scalarText(ctx.truth_troposphere_residual_std_m); ...
        scalarText(ctx.truth_troposphere_residual_rms_m); ...
        scalarText(ctx.truth_troposphere_residual_max_abs_m); ...
        scalarText(ctx.truth_ionosphere_residual_mean_m); ...
        scalarText(ctx.truth_ionosphere_residual_std_m); ...
        scalarText(ctx.truth_ionosphere_residual_rms_m); ...
        scalarText(ctx.truth_ionosphere_residual_max_abs_m) ...
        ];

    tableOut = table(Quantity, Value);
end

function tableOut = buildAtmosphereSummaryTable(sim, ctx)
    Quantity = [ ...
        "Truth troposphere enabled"; ...
        "Truth troposphere model"; ...
        "Truth ionosphere enabled"; ...
        "Truth ionosphere model"; ...
        "Estimator troposphere enabled"; ...
        "Estimator troposphere model"; ...
        "Estimator ionosphere enabled"; ...
        "Estimator ionosphere model"; ...
        "Truth constant troposphere delay [m]"; ...
        "Truth constant ionosphere delay [m]"; ...
        "Estimator constant troposphere delay [m]"; ...
        "Estimator constant ionosphere delay [m]"; ...
        "Mean truth atmosphere total [m]"; ...
        "Mean estimator atmosphere correction [m]"; ...
        "Mean truth minus model atmosphere [m]"; ...
        "Mean deterministic truth minus model atmosphere [m]"; ...
        "Stochastic truth residual enabled"; ...
        "Truth atmosphere residual sigma [m]"; ...
        "Truth residual troposphere sigma [m]"; ...
        "Truth residual ionosphere sigma [m]"; ...
        "Estimator atmosphere residual sigma [m]"; ...
        "Estimator residual troposphere sigma [m]"; ...
        "Estimator residual ionosphere sigma [m]"; ...
        "Estimator residual variance in R [m^2]"; ...
        "R covariance structure" ...
        ];

    Value = [ ...
        string(sim.truthAtmosphere.enableTroposphere); ...
        string(sim.truthAtmosphere.troposphereModel); ...
        string(sim.truthAtmosphere.enableIonosphere); ...
        string(sim.truthAtmosphere.ionosphereModel); ...
        string(sim.modelAtmosphere.enableTroposphere); ...
        string(sim.modelAtmosphere.troposphereModel); ...
        string(sim.modelAtmosphere.enableIonosphere); ...
        string(sim.modelAtmosphere.ionosphereModel); ...
        scalarText(sim.truthAtmosphere.constantTroposphereDelay_m); ...
        scalarText(sim.truthAtmosphere.constantIonosphereDelay_m); ...
        scalarText(sim.modelAtmosphere.constantTroposphereDelay_m); ...
        scalarText(sim.modelAtmosphere.constantIonosphereDelay_m); ...
        scalarText(ctx.mean_truth_atmosphere_delay_m); ...
        scalarText(ctx.mean_model_atmosphere_delay_m); ...
        scalarText(ctx.mean_atmosphere_model_residual_m); ...
        scalarText(ctx.mean_deterministic_atmosphere_model_residual_m); ...
        string( ...
            (sim.truthAtmosphere.enableTroposphere && ...
            sim.truthAtmosphere.residualTroposphereSigma_m > 0.0) || ...
            (sim.truthAtmosphere.enableIonosphere && ...
            sim.truthAtmosphere.residualIonosphereSigma_m > 0.0)); ...
        scalarText(ctx.truth_atmosphere_residual_sigma_m); ...
        scalarText(sim.truthAtmosphere.residualTroposphereSigma_m); ...
        scalarText(sim.truthAtmosphere.residualIonosphereSigma_m); ...
        scalarText(ctx.model_atmosphere_residual_sigma_m); ...
        scalarText(sim.modelAtmosphere.residualTroposphereSigma_m); ...
        scalarText(sim.modelAtmosphere.residualIonosphereSigma_m); ...
        scalarText(ctx.model_atmosphere_residual_variance_m2); ...
        ctx.model_atmosphere_covariance_structure ...
        ];

    tableOut = table(Quantity, Value);
end

function tableOut = buildIonosphereMapSummaryTable(sim, diags)
    ionoTruth = diags.atmosphere.truth.ionosphere;
    ionoModel = diags.atmosphere.model.ionosphere;
    Quantity = [ ...
        "Truth ionosphere provider"; ...
        "Estimator ionosphere provider"; ...
        "Mean truth IPP latitude [deg]"; ...
        "Mean truth IPP longitude [deg]"; ...
        "Mean truth VTEC [TECU]"; ...
        "Mean truth STEC [TECU]"; ...
        "Mean truth mapping factor"; ...
        "Mean truth frequency [Hz]"; ...
        "Mean estimator IPP latitude [deg]"; ...
        "Mean estimator IPP longitude [deg]"; ...
        "Mean estimator VTEC [TECU]"; ...
        "Mean estimator STEC [TECU]"; ...
        "Mean estimator mapping factor"; ...
        "Mean estimator frequency [Hz]" ...
        ];

    Value = [ ...
        string(sim.truthAtmosphere.ionosphereProviderType); ...
        string(sim.modelAtmosphere.ionosphereProviderType); ...
        scalarText(mean(ionoTruth.ipp_lat_deg(:), 'omitnan')); ...
        scalarText(mean(ionoTruth.ipp_lon_deg(:), 'omitnan')); ...
        scalarText(mean(ionoTruth.vtec_TECU(:), 'omitnan')); ...
        scalarText(mean(ionoTruth.stec_TECU(:), 'omitnan')); ...
        scalarText(mean(ionoTruth.mapping_factor(:), 'omitnan')); ...
        scalarText(mean(ionoTruth.frequency_Hz(:), 'omitnan')); ...
        scalarText(mean(ionoModel.ipp_lat_deg(:), 'omitnan')); ...
        scalarText(mean(ionoModel.ipp_lon_deg(:), 'omitnan')); ...
        scalarText(mean(ionoModel.vtec_TECU(:), 'omitnan')); ...
        scalarText(mean(ionoModel.stec_TECU(:), 'omitnan')); ...
        scalarText(mean(ionoModel.mapping_factor(:), 'omitnan')); ...
        scalarText(mean(ionoModel.frequency_Hz(:), 'omitnan')) ...
        ];

    tableOut = table(Quantity, Value);
end

function tableOut = buildTroposphereProfileSummaryTable(sim, diags)
    tropoTruth = diags.atmosphere.truth.troposphere;
    tropoModel = diags.atmosphere.model.troposphere;
    Quantity = [ ...
        "Truth troposphere provider"; ...
        "Estimator troposphere provider"; ...
        "Truth mapping function"; ...
        "Estimator mapping function"; ...
        "Mean truth pressure [hPa]"; ...
        "Mean truth temperature [K]"; ...
        "Mean truth relative humidity [-]"; ...
        "Mean truth water vapour pressure [hPa]"; ...
        "Mean truth ZHD [m]"; ...
        "Mean truth ZWD [m]"; ...
        "Mean truth slant hydrostatic [m]"; ...
        "Mean truth slant wet [m]"; ...
        "Mean estimator pressure [hPa]"; ...
        "Mean estimator temperature [K]"; ...
        "Mean estimator relative humidity [-]"; ...
        "Mean estimator water vapour pressure [hPa]"; ...
        "Mean estimator ZHD [m]"; ...
        "Mean estimator ZWD [m]"; ...
        "Mean estimator slant hydrostatic [m]"; ...
        "Mean estimator slant wet [m]" ...
        ];

    Value = [ ...
        string(sim.truthAtmosphere.troposphereProviderType); ...
        string(sim.modelAtmosphere.troposphereProviderType); ...
        string(sim.truthAtmosphere.troposphereMappingFunction); ...
        string(sim.modelAtmosphere.troposphereMappingFunction); ...
        scalarText(mean(tropoTruth.pressure_hPa(:), 'omitnan')); ...
        scalarText(mean(tropoTruth.temperature_K(:), 'omitnan')); ...
        scalarText(mean(tropoTruth.relative_humidity_fraction(:), 'omitnan')); ...
        scalarText(mean(tropoTruth.water_vapor_pressure_hPa(:), 'omitnan')); ...
        scalarText(mean(tropoTruth.zhd_m(:), 'omitnan')); ...
        scalarText(mean(tropoTruth.zwd_m(:), 'omitnan')); ...
        scalarText(mean(tropoTruth.slant_hydrostatic_m(:), 'omitnan')); ...
        scalarText(mean(tropoTruth.slant_wet_m(:), 'omitnan')); ...
        scalarText(mean(tropoModel.pressure_hPa(:), 'omitnan')); ...
        scalarText(mean(tropoModel.temperature_K(:), 'omitnan')); ...
        scalarText(mean(tropoModel.relative_humidity_fraction(:), 'omitnan')); ...
        scalarText(mean(tropoModel.water_vapor_pressure_hPa(:), 'omitnan')); ...
        scalarText(mean(tropoModel.zhd_m(:), 'omitnan')); ...
        scalarText(mean(tropoModel.zwd_m(:), 'omitnan')); ...
        scalarText(mean(tropoModel.slant_hydrostatic_m(:), 'omitnan')); ...
        scalarText(mean(tropoModel.slant_wet_m(:), 'omitnan')) ...
        ];

    tableOut = table(Quantity, Value);
end

function textValue = scalarText(value)
    value = double(value);
    if ~isfinite(value)
        textValue = "not available";
    else
        textValue = string(sprintf("%.6g", value));
    end
end

function towers = reportTowersLocal(sim)
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

function tauOut = validTauForSamplesLocal(tauIn, dt, n)
    m = unique(round(tauIn(:).' ./ dt));
    m = m(isfinite(m) & m >= 1 & 2 .* m < n);
    tauOut = m .* dt;
    if isempty(tauOut)
        tauOut = dt;
    end
end

function [tauValid_s, adev, adevSigma, edf] = runClockAllanValidationLocal( ...
        clockTemplate, tauRequested_s, dt, nSamples, validationClockStream)
    nSamples = max(3, floor(double(nSamples)));
    tauValid_s = validTauForSamplesLocal(tauRequested_s, dt, nSamples);
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

function ctx = ensureReportTables(ctx)
    if ~isfield(ctx, "measurement_model_table")
        ctx.measurement_model_table = buildMeasurementModelReportTable();
    end

    if ~isfield(ctx, "state_vector_table")
        ctx.state_vector_table = buildStateVectorReportTable(ctx);
    end

    if ~isfield(ctx, "h_factor_observability_table")
        ctx.h_factor_observability_table = buildHFactorObservabilityTable(ctx);
    end

    if ~isfield(ctx, "observation_matrix_diagnostics_table")
        ctx.observation_matrix_diagnostics_table = ...
            buildObservationMatrixDiagnosticsTable(ctx);
    end

    if ~isfield(ctx, "starting_position_table")
        ctx.starting_position_table = buildStartingPositionTable(ctx);
    end
end

function tableOut = buildStartingPositionTable(ctx)
    objectType = strings(0, 1);
    objectName = strings(0, 1);
    positionFrame = strings(0, 1);
    position1 = strings(0, 1);
    position2 = strings(0, 1);
    position3 = strings(0, 1);

    if isfield(ctx, "initial_truth_position_eci_m") && ...
            numel(ctx.initial_truth_position_eci_m) >= 3
        r0_I = ctx.initial_truth_position_eci_m(:);
    elseif isfield(ctx, "sat_pos_history_m") && ...
            size(ctx.sat_pos_history_m, 1) >= 3
        r0_I = ctx.sat_pos_history_m(1:3, 1);
    else
        r0_I = [NaN; NaN; NaN];
    end

    assetName = "SpaceAsset";
    if isfield(ctx, "asset_name")
        assetName = string(ctx.asset_name);
    end

    appendRow("SpaceAsset", assetName, "ECI initial center of mass", ...
        sprintf("X %.6g m", r0_I(1)), ...
        sprintf("Y %.6g m", r0_I(2)), ...
        sprintf("Z %.6g m", r0_I(3)));

    if isfield(ctx, "receiver_offsets_body_m")
        receiverOffsets = ctx.receiver_offsets_body_m;
    elseif isfield(ctx, "receiver_offset_body_by_receiver_m")
        receiverOffsets = ctx.receiver_offset_body_by_receiver_m;
    else
        receiverOffsets = zeros(3, 0);
    end

    receiverNames = strings(1, size(receiverOffsets, 2));
    if isfield(ctx, "receiver_names")
        receiverNames = string(ctx.receiver_names);
    end

    for rx = 1:size(receiverOffsets, 2)
        off = receiverOffsets(:, rx);
        receiverName = sprintf("RX%d", rx);
        if rx <= numel(receiverNames)
            receiverName = receiverNames(rx);
        end

        appendRow("Receiver", receiverName, "Body lever arm", ...
            sprintf("X %.6g m", off(1)), ...
            sprintf("Y %.6g m", off(2)), ...
            sprintf("Z %.6g m", off(3)));
    end

    if isfield(ctx, "towers")
        towers = ctx.towers;
        for twr = 1:numel(towers)
            appendRow("Tower", string(towers(twr).name), "Fixed geodetic/ECEF source", ...
                sprintf("Lat %.6g deg", towers(twr).lat_deg), ...
                sprintf("Lon %.6g deg", towers(twr).lon_deg), ...
                sprintf("Alt %.6g m", towers(twr).alt_m));
        end
    end

    tableOut = table(objectType, objectName, positionFrame, ...
        position1, position2, position3, ...
        'VariableNames', {'ObjectType','Name','Frame','Position1','Position2','Position3'});

    function appendRow(typeValue, nameValue, frameValue, pos1, pos2, pos3)
        objectType(end + 1, 1) = string(typeValue);
        objectName(end + 1, 1) = string(nameValue);
        positionFrame(end + 1, 1) = string(frameValue);
        position1(end + 1, 1) = string(pos1);
        position2(end + 1, 1) = string(pos2);
        position3(end + 1, 1) = string(pos3);
    end
end

function tableOut = buildObservationMatrixDiagnosticsTable(ctx)
    measCount = NaN;
    if isfield(ctx, "pseudorange_measurement_count")
        measCount = ctx.pseudorange_measurement_count(:);
    elseif isfield(ctx, "nis_degrees_of_freedom")
        measCount = ctx.nis_degrees_of_freedom(:);
    elseif isfield(ctx, "H_row_count_history")
        measCount = ctx.H_row_count_history(:);
    end

    validMeas = measCount(isfinite(measCount));
    if isempty(validMeas)
        finalPseudorangeRows = NaN;
        meanPseudorangeRows = NaN;
        minPseudorangeRows = NaN;
        maxPseudorangeRows = NaN;
    else
        finalPseudorangeRows = validMeas(end);
        meanPseudorangeRows = mean(validMeas);
        minPseudorangeRows = min(validMeas);
        maxPseudorangeRows = max(validMeas);
    end

    gaugeRows = 0;
    if isfield(ctx, "enable_tower_clock_ekf") && ctx.enable_tower_clock_ekf
        gaugeRows = 2;
    end

    finalHRows = finalPseudorangeRows + gaugeRows;

    hColumns = NaN;
    if isfield(ctx, "state_dim")
        hColumns = ctx.state_dim;
    elseif isfield(ctx, "final_H_columns")
        hColumns = ctx.final_H_columns;
    end

    hRank = getReportVector(ctx, "H_rank_history");
    hRankValid = hRank(isfinite(hRank));

    if isempty(hRankValid)
        finalRankH = NaN;
        minRankH = NaN;
        maxRankH = NaN;
    else
        finalRankH = hRankValid(end);
        minRankH = min(hRankValid);
        maxRankH = max(hRankValid);
    end

    finalRankDeficiency = hColumns - finalRankH;

    hPosRank = getReportVector(ctx, "H_pos_rank_history");
    hAttRank = getReportVector(ctx, "H_att_rank_history");
    hCombinedRank = getReportVector(ctx, "H_pos_att_clock_rank_history");

    if all(isnan(hPosRank)) && isfield(ctx, "final_H_pos_rank")
        hPosRank = ctx.final_H_pos_rank;
    end
    if all(isnan(hAttRank)) && isfield(ctx, "final_H_att_rank")
        hAttRank = ctx.final_H_att_rank;
    end
    if all(isnan(hCombinedRank)) && isfield(ctx, "final_H_pos_att_clock_rank")
        hCombinedRank = ctx.final_H_pos_att_clock_rank;
    end

    finalPosRank = lastFiniteLocal(hPosRank);
    finalAttRank = lastFiniteLocal(hAttRank);
    finalCombinedRank = lastFiniteLocal(hCombinedRank);

    Quantity = [ ...
        "final H rows"; ...
        "H columns / EKF state dimension"; ...
        "final rank(H)"; ...
        "rank deficiency, n_x - rank(H)"; ...
        "minimum rank(H) over run"; ...
        "maximum rank(H) over run"; ...
        "final pseudorange rows"; ...
        "mean pseudorange rows"; ...
        "minimum pseudorange rows"; ...
        "maximum pseudorange rows"; ...
        "extra gauge rows"; ...
        "final position-column rank"; ...
        "final attitude-column rank"; ...
        "final position/attitude/clock rank" ...
        ];

    Value = [ ...
        formatNumberLocal(finalHRows); ...
        formatNumberLocal(hColumns); ...
        formatNumberLocal(finalRankH); ...
        formatNumberLocal(finalRankDeficiency); ...
        formatNumberLocal(minRankH); ...
        formatNumberLocal(maxRankH); ...
        formatNumberLocal(finalPseudorangeRows); ...
        sprintf("%.2f", meanPseudorangeRows); ...
        formatNumberLocal(minPseudorangeRows); ...
        formatNumberLocal(maxPseudorangeRows); ...
        formatNumberLocal(gaugeRows); ...
        formatNumberLocal(finalPosRank); ...
        formatNumberLocal(finalAttRank); ...
        formatNumberLocal(finalCombinedRank) ...
        ];

    Meaning = [ ...
        "Number of scalar rows in the final EKF update matrix H"; ...
        "Number of estimated EKF error states"; ...
        "Numerical rank of the final observation matrix H"; ...
        "Unobservable dimension remaining in final H"; ...
        "Worst instantaneous H rank during the run"; ...
        "Best instantaneous H rank during the run"; ...
        "Visible pseudorange measurements at final epoch"; ...
        "Average visible pseudorange measurements per epoch"; ...
        "Minimum visible pseudorange measurements in one epoch"; ...
        "Maximum visible pseudorange measurements in one epoch"; ...
        "Additional clock-gauge constraint rows added to H"; ...
        "Rank of H columns corresponding to position states"; ...
        "Rank of H columns corresponding to attitude-error states"; ...
        "Rank of combined position, attitude, and receiver-clock columns" ...
        ];

    tableOut = table(Quantity, Value, Meaning);
end

function tableOut = buildStateVectorReportTable(ctx)
    names = string(ctx.state_names);
    n = numel(names);

    Index = (1:n).';
    Symbol = strings(n, 1);
    Description = strings(n, 1);
    Unit = strings(n, 1);
    DynamicCouplingNote = strings(n, 1);

    baseSymbol = ["delta r_I,x"; "delta r_I,y"; "delta r_I,z"; ...
        "delta v_I,x"; "delta v_I,y"; "delta v_I,z"; ...
        "delta theta_B,x"; "delta theta_B,y"; "delta theta_B,z"; ...
        "delta omega_B,x"; "delta omega_B,y"; "delta omega_B,z"; ...
        "delta b_rx"; "delta bdot_rx"];

    baseUnit = ["m"; "m"; "m"; ...
        "m/s"; "m/s"; "m/s"; ...
        "rad"; "rad"; "rad"; ...
        "rad/s"; "rad/s"; "rad/s"; ...
        "m"; "m/s"];

    baseCount = min(14, n);
    Symbol(1:baseCount) = baseSymbol(1:baseCount);
    Unit(1:baseCount) = baseUnit(1:baseCount);
    Description(1:baseCount) = names(1:baseCount);

    if n >= 14
        DynamicCouplingNote(1:3) = "Coupled to velocity through dynamics";
        DynamicCouplingNote(4:6) = "Affects future position through dynamics";
        DynamicCouplingNote(7:9) = "Zero when receiver lever arm is zero";
        DynamicCouplingNote(10:12) = "Affects future attitude through dynamics";
        DynamicCouplingNote(13) = "Directly estimated at measurement epoch";
        DynamicCouplingNote(14) = "Affects future receiver clock bias through clock transition model";
    end

    towerClockEnabled = isfield(ctx, "enable_tower_clock_ekf") && ...
        ctx.enable_tower_clock_ekf;

    towerNames = strings(0, 1);
    if isfield(ctx, "tower_names")
        towerNames = string(ctx.tower_names);
    end

    if towerClockEnabled && n > 14
        row = 15;
        twr = 1;
        while row <= n
            towerName = sprintf("Tower %d", twr);
            if twr <= numel(towerNames)
                towerName = towerNames(twr);
            end

            Symbol(row) = sprintf('delta b_g,%d', twr);
            Description(row) = sprintf('%s tower clock bias', towerName);
            Unit(row) = "m";
            DynamicCouplingNote(row) = "Estimated relative to mean ground-network clock gauge";
            row = row + 1;

            if row <= n
                Symbol(row) = sprintf('delta bdot_g,%d', twr);
                Description(row) = sprintf('%s tower clock drift', towerName);
                Unit(row) = "m/s";
                DynamicCouplingNote(row) = "Affects future tower clock bias through clock transition model";
                row = row + 1;
            end

            twr = twr + 1;
        end
    end

    tableOut = table(Index, Symbol, Description, Unit, DynamicCouplingNote);
end

function tableOut = buildHFactorObservabilityTable(ctx)
    hRankHistory = getReportVector(ctx, "H_rank_history");
    kFinal = find(isfinite(hRankHistory), 1, 'last');
    if isempty(kFinal)
        kFinal = numel(hRankHistory);
    end
    if isempty(kFinal) || kFinal < 1
        kFinal = 1;
    end

    hRowsHistory = getReportVector(ctx, "H_row_count_history");
    hColsHistory = getReportVector(ctx, "H_column_count_history");

    hRows = getVectorValue(hRowsHistory, kFinal, getFieldOrDefaultLocal(ctx, "final_H_rows", NaN));
    hCols = getVectorValue(hColsHistory, kFinal, getFieldOrDefaultLocal(ctx, "final_H_columns", NaN));
    hRank = getVectorValue(hRankHistory, kFinal, getFieldOrDefaultLocal(ctx, "final_H_rank", NaN));
    hDef = hCols - hRank;

    W = zeros(getFieldOrDefaultLocal(ctx, "state_dim", 0));
    if isfield(ctx, "observability_normal_matrix")
        W = ctx.observability_normal_matrix;
    end
    W = 0.5 * (W + W.');

    colNorm = sqrt(max(diag(W), 0.0));
    if isempty(colNorm)
        colNorm = zeros(getFieldOrDefaultLocal(ctx, "state_dim", 0), 1);
    end

    scale = colNorm;
    scale(scale == 0.0) = Inf;

    Wn = W ./ (scale * scale.');
    Wn(~isfinite(Wn)) = 0.0;

    stateNames = string(ctx.state_names);
    if isempty(colNorm)
        weakTol = 0.0;
    else
        weakTol = max(colNorm) * 1e-8;
    end

    idx = ctx.state_index;

    Block = strings(0, 1);
    StateColumns = strings(0, 1);
    HFactor = strings(0, 1);
    DirectRankFinalEpoch = strings(0, 1);
    AccumulatedDynamicRank = strings(0, 1);
    Interpretation = strings(0, 1);

    appendBlock("position error dr_I", idx.pos, ...
        "u^T", ...
        getVectorValue(getReportVector(ctx, "H_pos_rank_history"), kFinal, ...
        getFieldOrDefaultLocal(ctx, "final_H_pos_rank", NaN)), ...
        "Directly observed as line-of-sight range sensitivity. Full 3D rank needs diverse LOS geometry.");

    appendBlock("velocity error dv_I", idx.vel, ...
        "0", ...
        0, ...
        "Not directly observed by code pseudorange. It becomes observable only because velocity propagates into future position.");

    appendBlock("attitude error dtheta_B", idx.att, ...
        "u^T*(-C_BI*skew(l_a_B))", ...
        getVectorValue(getReportVector(ctx, "H_att_rank_history"), kFinal, ...
        getFieldOrDefaultLocal(ctx, "final_H_att_rank", NaN)), ...
        "Observed only through non-zero receiver lever arms. A receiver at the center of mass gives zero attitude sensitivity.");

    appendBlock("body angular-rate error domega_B", idx.omega, ...
        "0", ...
        0, ...
        "Not directly observed by code pseudorange. It becomes observable only because angular rate propagates into future attitude.");

    appendBlock("receiver clock bias db_rx", idx.rxClockBias, ...
        "1", ...
        double(getVectorValue(getReportVector(ctx, "H_rx_clock_bias_column_norm_history"), ...
        kFinal, getFieldOrDefaultLocal(ctx, "final_H_rx_clock_bias_column_norm", 0.0)) > 0.0), ...
        "Directly observed as a common range offset across all pseudoranges.");

    appendBlock("receiver clock drift dbdot_rx", idx.rxClockDrift, ...
        "0", ...
        0, ...
        "Not directly observed by pseudorange. It becomes observable only because clock drift propagates into future clock bias.");

    towerClockEnabled = isfield(ctx, "enable_tower_clock_ekf") && ...
        ctx.enable_tower_clock_ekf;

    if towerClockEnabled && isfield(idx, "towerClockBias") && isfield(idx, "towerClockDrift")
        visibleTowerHistory = getReportVector(ctx, "visible_tower_count");
        visibleTowers = getVectorValue(visibleTowerHistory, kFinal, ...
            getFieldOrDefaultLocal(ctx, "num_towers", NaN));

        appendBlock("tower clock biases db_g", idx.towerClockBias, ...
            "-1 for the transmitting tower, plus mean-clock gauge row", ...
            min(getFieldOrDefaultLocal(ctx, "num_towers", numel(idx.towerClockBias)), visibleTowers + 1), ...
            "Directly observed only for visible towers. The mean-clock gauge fixes the otherwise arbitrary network clock reference.");

        appendBlock("tower clock drifts dbdot_g", idx.towerClockDrift, ...
            "0 in pseudorange rows, mean-drift gauge row only", ...
            1, ...
            "Not directly observed by pseudorange. The gauge constrains the mean; time propagation couples drift into tower clock bias.");
    end

    appendBlock("full instantaneous H", 1:getFieldOrDefaultLocal(ctx, "state_dim", numel(stateNames)), ...
        "all active H columns", ...
        hRank, ...
        sprintf("Final H has %s rows, %s columns, rank %s, deficiency %s. This is instantaneous rank only.", ...
        formatNumberLocal(hRows), formatNumberLocal(hCols), ...
        formatNumberLocal(hRank), formatNumberLocal(hDef)));

    tableOut = table(Block, StateColumns, HFactor, ...
        DirectRankFinalEpoch, AccumulatedDynamicRank, Interpretation, ...
        'VariableNames', {'Block','Cols','HFactor','DirectRank','DynamicRank','Interpretation'});

    function appendBlock(blockName, idxBlock, hFactorText, directRank, interpretationText)
        idxBlock = idxBlock(:).';

        if isempty(idxBlock)
            accumulatedRank = NaN;
            weakStateText = "n/a";
            colText = "n/a";
        else
            if isempty(Wn)
                accumulatedRank = NaN;
            else
                accumulatedRank = rank(Wn(idxBlock, idxBlock), 1e-8);
            end

            weakLocal = idxBlock(colNorm(idxBlock) < weakTol);

            if isempty(weakLocal)
                weakStateText = "none";
            else
                weakStateText = strjoin(string(stateNames(weakLocal)), ", ");
            end

            colText = sprintf("%d", idxBlock(1));
            for ii = 2:numel(idxBlock)
                colText = colText + sprintf(", %d", idxBlock(ii));
            end
        end

        Block(end + 1, 1) = string(blockName);
        StateColumns(end + 1, 1) = string(colText);
        HFactor(end + 1, 1) = string(hFactorText);
        DirectRankFinalEpoch(end + 1, 1) = string(formatRankLocal(directRank, numel(idxBlock)));
        AccumulatedDynamicRank(end + 1, 1) = string(formatRankLocal(accumulatedRank, numel(idxBlock)));

        if weakStateText == "none"
            Interpretation(end + 1, 1) = string(interpretationText);
        else
            Interpretation(end + 1, 1) = string(interpretationText) + ...
                " Weak accumulated states: " + weakStateText + ".";
        end
    end
end

function v = getReportVector(ctx, fieldName)
    fieldName = char(fieldName);
    if isfield(ctx, fieldName) && ~isempty(ctx.(fieldName))
        v = ctx.(fieldName)(:);
    else
        v = NaN;
    end
end

function value = getVectorValue(values, index, defaultValue)
    values = values(:);
    if index >= 1 && index <= numel(values) && isfinite(values(index))
        value = values(index);
    else
        value = defaultValue;
    end
end

function value = getFieldOrDefaultLocal(s, fieldName, defaultValue)
    fieldName = char(fieldName);
    if isstruct(s) && isfield(s, fieldName) && ~isempty(s.(fieldName))
        value = s.(fieldName);
    else
        value = defaultValue;
    end
end

function y = lastFiniteLocal(x)
    x = x(:);
    x = x(isfinite(x));

    if isempty(x)
        y = NaN;
    else
        y = x(end);
    end
end

function s = formatNumberLocal(x)
    if isempty(x) || ~isfinite(x)
        s = "n/a";
    elseif abs(x - round(x)) < 1e-12
        s = sprintf("%d", round(x));
    else
        s = sprintf("%.3g", x);
    end
end

function s = formatRankLocal(r, n)
    if isempty(r) || ~isfinite(r)
        s = "n/a";
    else
        s = sprintf("%d of %d", round(r), n);
    end
end
%% Default Configuration Helpers
function toggles = defaultReportToggles()
    toggles = struct();
    toggles.generatePdf = false;
    toggles.groundSegment = false;
    toggles.perfectGroundClocks = false;
    toggles.groundClockError = false;
    toggles.groundTimingNetworkCorrection = false;
    toggles.towerClocksEstimatedInEkf = false;
    toggles.satelliteClockError = false;
    toggles.ekfOrbitClockEstimation = false;
    toggles.measurementNoise = false;
    toggles.allanDeviationValidation = false;
    toggles.j2Perturbation = false;
    toggles.relativisticClockTerm = false;
    toggles.ionosphere = false;
    toggles.troposphere = false;
    toggles.multipath = false;
    toggles.receiverThermalNoise = false;
    toggles.antennaBias = false;
    toggles.hardwareDelay = false;
end

function config = defaultReportConfig(report_script_dir)
    config = struct();
    config.title = 'Clock-Only Ground-to-Space EKF Validation Report';
    config.scenarioName = 'Unnamed scenario';
    config.selectedOscillatorName = 'Unknown oscillator';
    config.reportRoot = fullfile(report_script_dir, "clock_only_ekf_report");
    config.outputBaseName = "clock_only_ekf_report_" + string(datetime("now", "Format", "yyyy-MM-dd"));
    config.compilePdf = true;
    config.generatedBy = 'scenario script';
    config.pdflatexCommand = "";
end

function out = mergeStructDefaults(in, defaults)
    out = defaults;
    names = fieldnames(in);
    for idx = 1:numel(names)
        out.(names{idx}) = in.(names{idx});
    end
end

function validateRequiredFields(data, required_fields)
    for idx = 1:numel(required_fields)
        if ~isfield(data, required_fields(idx))
            error("generateReport:MissingField", ...
                "ctx.%s is required for report generation.", required_fields(idx));
        end
    end
end

function tf = reportFieldsHaveFiniteData(data, field_names)
    tf = hasReportFields(data, field_names);
    if ~tf
        return;
    end

    for idx = 1:numel(field_names)
        values = data.(field_names(idx));
        if ~(isnumeric(values) || islogical(values)) || ...
                ~any(isfinite(double(values(:))))
            tf = false;
            return;
        end
    end
end

function tf = arraysHaveFiniteData(arrays)
    tf = true;
    for idx = 1:numel(arrays)
        values = arrays{idx};
        if ~(isnumeric(values) || islogical(values)) || ...
                ~any(isfinite(double(values(:))))
            tf = false;
            return;
        end
    end
end

function tf = hasReportFields(data, field_names)
    tf = true;
    for idx = 1:numel(field_names)
        if ~isfield(data, field_names(idx))
            tf = false;
            return;
        end
    end
end

function description = withDataUnavailableNote( ...
        description, section_enabled, plot_enabled, note_text)
    if section_enabled && ~plot_enabled
        description = [description " Data unavailable: " + string(note_text)];
    end
end

function data = ensureReportMetrics(data)
    if ~isfield(data, "postfit_innovation_rms_m")
        data.postfit_innovation_rms_m = NaN(size(data.innovation_rms_m));
    end
    if ~isfield(data, "covariance_condition_number")
        data.covariance_condition_number = NaN(size(data.innovation_rms_m));
    end
    if ~isfield(data, "innovation_condition_number")
        data.innovation_condition_number = NaN(size(data.innovation_rms_m));
    end

    if ~isfield(data, "convergence_skip_seconds")
        data.convergence_skip_seconds = min(3600, 0.1 * max(data.time_vec));
    end
    if ~isfield(data, "final_window_seconds")
        data.final_window_seconds = min(3600, 0.1 * max(data.time_vec));
    end

    steady_state_idx = data.time_vec >= data.convergence_skip_seconds;
    if nnz(steady_state_idx) < 2
        steady_state_idx = true(size(data.time_vec));
    end
    final_window_idx = data.time_vec >= (max(data.time_vec) - data.final_window_seconds);
    if nnz(final_window_idx) < 2
        final_window_idx = true(size(data.time_vec));
    end

    position_error_norm_m = sqrt(sum(data.ekf_pos_error_m.^2, 1));
    speed_of_light_mps = 299792458.0;
    if isfield(data, "c")
        speed_of_light_mps = data.c;
    end
    clock_error_range_equiv_m = data.ekf_clock_error_ps * 1e-12 * speed_of_light_mps;

    if ~isfield(data, "position_error_summary_m")
        data.position_error_summary_m = buildErrorSummary(position_error_norm_m, steady_state_idx);
    end
    if ~isfield(data, "clock_error_summary_ps")
        data.clock_error_summary_ps = buildErrorSummary(data.ekf_clock_error_ps, steady_state_idx);
    end
    if ~isfield(data, "clock_error_range_summary_m")
        data.clock_error_range_summary_m = buildErrorSummary(clock_error_range_equiv_m, steady_state_idx);
    end
    if ~isfield(data, "prefit_innovation_summary_m")
        data.prefit_innovation_summary_m = buildErrorSummary(data.innovation_rms_m, steady_state_idx);
    end
    if ~isfield(data, "postfit_innovation_summary_m")
        data.postfit_innovation_summary_m = buildErrorSummary(data.postfit_innovation_rms_m, steady_state_idx);
    end
    if ~isfield(data, "covariance_condition_summary")
        data.covariance_condition_summary = buildErrorSummary(data.covariance_condition_number, steady_state_idx);
    end
    if ~isfield(data, "innovation_condition_summary")
        data.innovation_condition_summary = buildErrorSummary(data.innovation_condition_number, steady_state_idx);
    end
    if ~isfield(data, "position_error_final_window_summary_m")
        data.position_error_final_window_summary_m = buildErrorSummary(position_error_norm_m, final_window_idx);
    end
    if ~isfield(data, "clock_error_final_window_summary_ps")
        data.clock_error_final_window_summary_ps = buildErrorSummary(data.ekf_clock_error_ps, final_window_idx);
    end
    if ~isfield(data, "clock_error_range_final_window_summary_m")
        data.clock_error_range_final_window_summary_m = buildErrorSummary(clock_error_range_equiv_m, final_window_idx);
    end
    if ~isfield(data, "prefit_innovation_final_window_summary_m")
        data.prefit_innovation_final_window_summary_m = buildErrorSummary(data.innovation_rms_m, final_window_idx);
    end
    if ~isfield(data, "postfit_innovation_final_window_summary_m")
        data.postfit_innovation_final_window_summary_m = buildErrorSummary(data.postfit_innovation_rms_m, final_window_idx);
    end
    if ~isfield(data, "covariance_condition_final_window_summary")
        data.covariance_condition_final_window_summary = buildErrorSummary(data.covariance_condition_number, final_window_idx);
    end
    if ~isfield(data, "innovation_condition_final_window_summary")
        data.innovation_condition_final_window_summary = buildErrorSummary(data.innovation_condition_number, final_window_idx);
    end
    if ~isfield(data, "final_clock_range_equivalent_m")
        data.final_clock_range_equivalent_m = clock_error_range_equiv_m(end);
    end
    if ~isfield(data, "final_prefit_innovation_rms_m")
        data.final_prefit_innovation_rms_m = data.innovation_rms_m(end);
    end
    if ~isfield(data, "final_postfit_residual_rms_m")
        data.final_postfit_residual_rms_m = data.postfit_innovation_rms_m(end);
    end
end

function summary = buildErrorSummary(values, steady_state_idx)
    values = values(:);
    steady_values = values(steady_state_idx(:));

    summary = struct();
    summary.final = values(end);
    summary.finalAbs = abs(values(end));
    summary.fullRunRms = sqrt(mean(values.^2, 'omitnan'));
    summary.steadyStateRms = sqrt(mean(steady_values.^2, 'omitnan'));
    summary.fullRunMeanAbs = mean(abs(values), 'omitnan');
    summary.steadyStateMeanAbs = mean(abs(steady_values), 'omitnan');
    summary.fullRunP95Abs = localPercentile(abs(values), 95);
    summary.steadyStateP95Abs = localPercentile(abs(steady_values), 95);
    summary.fullRunMaxAbs = max(abs(values), [], 'omitnan');
    summary.steadyStateMaxAbs = max(abs(steady_values), [], 'omitnan');
end

function value = localPercentile(values, percentile)
    values = sort(values(:));
    values = values(isfinite(values));
    if isempty(values)
        value = NaN;
        return;
    end

    rank_position = 1 + (percentile / 100) * (numel(values) - 1);
    lower_index = floor(rank_position);
    upper_index = ceil(rank_position);
    if lower_index == upper_index
        value = values(lower_index);
    else
        weight = rank_position - lower_index;
        value = (1 - weight) * values(lower_index) + weight * values(upper_index);
    end
end

function pdflatex_command = findPdfLatex(reportConfig)
    candidates = strings(0, 1);
    if isfield(reportConfig, "pdflatexCommand") && strlength(string(reportConfig.pdflatexCommand)) > 0
        candidates(end+1, 1) = string(reportConfig.pdflatexCommand);
    end
    candidates(end+1, 1) = "pdflatex";
    candidates(end+1, 1) = "/Library/TeX/texbin/pdflatex";
    candidates(end+1, 1) = "/usr/local/texlive/2025/bin/universal-darwin/pdflatex";
    candidates(end+1, 1) = "/usr/local/texlive/2024/bin/universal-darwin/pdflatex";

    pdflatex_command = "";
    for idx = 1:numel(candidates)
        candidate = candidates(idx);
        if contains(candidate, filesep) && ~isfile(candidate)
            continue;
        end
        test_command = sprintf('"%s" -version', char(candidate));
        [status, ~] = system(test_command);
        if status == 0
            pdflatex_command = candidate;
            return;
        end
    end
end

%% Plot Helpers
function path_out = exportPlot(figure_dir, file_name, plot_function)
    interactive_report_plots = getappdata(0, 'generateReportInteractivePlots');
    if isempty(interactive_report_plots)
        interactive_report_plots = true;
    end
    visible_state = 'on';
    if ~interactive_report_plots
        visible_state = 'off';
    end

    fig = figure('Visible', visible_state, 'Color', 'w', 'Position', [100 100 900 520]);
    cleanup_obj = onCleanup(@() closeFigureIfNeeded(fig, interactive_report_plots));
    plot_function();
    report_base = getappdata(0, 'generateReportOutputBaseName');
    
    if ~isempty(report_base)
        [~, base_name, ext] = fileparts(file_name);
        file_name = sprintf('%s_%s%s', char(report_base), base_name, ext);
    end
    
    path_out = fullfile(figure_dir, file_name);
    exportgraphics(fig, path_out, 'ContentType', 'image', 'Resolution', 220);
end

function closeFigureIfNeeded(fig, interactive_report_plots)
    if ~interactive_report_plots && isvalid(fig)
        close(fig);
    end
end

function plotPositionError(time_vec, ekf_pos_error_m)
    plot(time_vec / 3600, ekf_pos_error_m(1, :), 'r-', 'LineWidth', 1.2, 'DisplayName', 'X error');
    hold on;
    plot(time_vec / 3600, ekf_pos_error_m(2, :), 'g-', 'LineWidth', 1.2, 'DisplayName', 'Y error');
    plot(time_vec / 3600, ekf_pos_error_m(3, :), 'b-', 'LineWidth', 1.2, 'DisplayName', 'Z error');
    plot(time_vec / 3600, sqrt(sum(ekf_pos_error_m.^2, 1)), 'k--', 'LineWidth', 1.2, 'DisplayName', '3D norm');
    grid on;
    legend('Location', 'best');
    xlabel('Time [Hours]', 'FontWeight', 'bold');
    ylabel('Position Error [Meters]', 'FontWeight', 'bold');
    title('Combined EKF Result Using Enabled RX Measurements', 'FontSize', 12);
end

function plotPositionCovariance(time_vec, ekf_pos_sigma_m)
    plot(time_vec / 3600, ekf_pos_sigma_m(1, :), 'r-', 'LineWidth', 1.0, 'DisplayName', 'X sigma');
    hold on;
    plot(time_vec / 3600, ekf_pos_sigma_m(2, :), 'g-', 'LineWidth', 1.0, 'DisplayName', 'Y sigma');
    plot(time_vec / 3600, ekf_pos_sigma_m(3, :), 'b-', 'LineWidth', 1.0, 'DisplayName', 'Z sigma');
    grid on;
    legend('Location', 'best');
    xlabel('Time [Hours]', 'FontWeight', 'bold');
    ylabel('Position Sigma [Meters]', 'FontWeight', 'bold');
    title('EKF Position Covariance', 'FontSize', 12);
end

function plotAttitudeStates(time_vec, attitude_truth_deg, attitude_est_deg, attitude_error_deg, attitude_sigma_deg, attitude_state_names, attitude_frame)
    if nargin < 6 || isempty(attitude_state_names)
        attitude_state_names = ["roll", "pitch", "yaw"];
    end
    if nargin < 7 || isempty(attitude_frame)
        attitude_frame = "body";
    end

    labels = upper(string(attitude_state_names));
    time_h = time_vec(:).' / 3600;

    tiledlayout(3, 1, 'TileSpacing', 'compact', 'Padding', 'compact');

    nexttile;
    plot(time_h, attitude_truth_deg.', '-', 'LineWidth', 1.0);
    hold on;
    plot(time_h, attitude_est_deg.', '--', 'LineWidth', 1.0);
    grid on;
    xlabel('Time [Hours]');
    ylabel('Angle [deg]');
    title(sprintf('Euler-321 Attitude States in %s Frame', char(attitude_frame)));
    legend([cellstr(labels + " truth"), cellstr(labels + " EKF")], 'Location', 'bestoutside');

    nexttile;
    plot(time_h, attitude_error_deg.', 'LineWidth', 1.0);
    grid on;
    xlabel('Time [Hours]');
    ylabel('Error [deg]');
    title('Attitude State Error');
    legend(cellstr(labels + " error"), 'Location', 'bestoutside');

    nexttile;
    plot(time_h, attitude_sigma_deg.', ':', 'LineWidth', 1.0);
    grid on;
    xlabel('Time [Hours]');
    ylabel('1\sigma [deg]');
    title('Attitude Posterior Standard Deviation');
    legend(cellstr(labels + " sigma"), 'Location', 'bestoutside');
end

function plotAttitudeCovariance(time_vec, attitude_sigma_deg, attitude_state_names, attitude_frame)
    if nargin < 3 || isempty(attitude_state_names)
        attitude_state_names = ["roll", "pitch", "yaw"];
    end
    if nargin < 4 || isempty(attitude_frame)
        attitude_frame = "body";
    end

    labels = upper(string(attitude_state_names));
    plot(time_vec(:).' / 3600, attitude_sigma_deg.', 'LineWidth', 1.2);
    grid on;
    xlabel('Time [Hours]', 'FontWeight', 'bold');
    ylabel('Attitude Sigma [deg]', 'FontWeight', 'bold');
    title(sprintf('Attitude Covariance in %s Frame', char(attitude_frame)), 'FontSize', 12);
    legend(cellstr(labels), 'Location', 'best');
end

function plotAngularVelocityStates(time_vec, omega_truth_degps, omega_est_degps, omega_error_degps, omega_sigma_degps, omega_state_names, attitude_frame)
    if nargin < 6 || isempty(omega_state_names)
        omega_state_names = ["roll rate", "pitch rate", "yaw rate"];
    end
    if nargin < 7 || isempty(attitude_frame)
        attitude_frame = "body";
    end

    labels = string(omega_state_names);
    time_h = time_vec(:).' / 3600;

    tiledlayout(3, 1, 'TileSpacing', 'compact', 'Padding', 'compact');

    nexttile;
    plot(time_h, omega_truth_degps.', '-', 'LineWidth', 1.0);
    hold on;
    plot(time_h, omega_est_degps.', '--', 'LineWidth', 1.0);
    grid on;
    xlabel('Time [Hours]');
    ylabel('Rate [deg/s]');
    title(sprintf('Angular Velocity States in %s Frame', char(attitude_frame)));
    legend([cellstr(labels + " truth"), cellstr(labels + " EKF")], 'Location', 'bestoutside');

    nexttile;
    plot(time_h, omega_error_degps.', 'LineWidth', 1.0);
    grid on;
    xlabel('Time [Hours]');
    ylabel('Error [deg/s]');
    title('Angular Velocity State Error');
    legend(cellstr(labels + " error"), 'Location', 'bestoutside');

    nexttile;
    plot(time_h, omega_sigma_degps.', ':', 'LineWidth', 1.0);
    grid on;
    xlabel('Time [Hours]');
    ylabel('1\sigma [deg/s]');
    title('Angular Velocity Posterior Standard Deviation');
    legend(cellstr(labels + " sigma"), 'Location', 'bestoutside');
end

function plotClockError(time_vec, ekf_clock_error_ps, ekf_clock_sigma_ps)
    plot(time_vec / 3600, ekf_clock_error_ps, 'b-', 'LineWidth', 1.2, 'DisplayName', 'Clock error');
    hold on;
    plot(time_vec / 3600, 3 * ekf_clock_sigma_ps, 'k:', 'LineWidth', 1.0, 'DisplayName', '+3 sigma');
    plot(time_vec / 3600, -3 * ekf_clock_sigma_ps, 'k:', 'LineWidth', 1.0, 'DisplayName', '-3 sigma');
    yline(100, 'r--', 'Target Bound (+100ps)', 'LineWidth', 1.2);
    yline(-100, 'r--', 'Target Bound (-100ps)', 'LineWidth', 1.2);
    grid on;
    legend('Location', 'best');
    xlabel('Time [Hours]', 'FontWeight', 'bold');
    ylabel('Clock Sync Error [Picoseconds]', 'FontWeight', 'bold');
    title('EKF Clock Synchronisation Error', 'FontSize', 12);
end

function plotClockBias(time_vec, true_clock_bias_ps, est_clock_bias_ps)
    plot(time_vec / 3600, true_clock_bias_ps, 'b-', ...
        'LineWidth', 1.2, ...
        'DisplayName', 'True SpaceAsset clock bias');
    hold on;

    plot(time_vec / 3600, est_clock_bias_ps, 'r--', ...
        'LineWidth', 1.5, ...
        'DisplayName', 'EKF estimated clock bias');

    yline(100, 'k:', 'Target Bound (+100ps)', 'LineWidth', 1.0);
    yline(-100, 'k:', 'Target Bound (-100ps)', 'LineWidth', 1.0);

    % Cut the plot to the true SpaceAsset clock-bias range +/- 0.1 ps.
    true_valid_ps = true_clock_bias_ps(isfinite(true_clock_bias_ps));
    if ~isempty(true_valid_ps)
        margin_ps = 1.1;
        y_min_ps = min(true_valid_ps)*margin_ps;
        y_max_ps = max(true_valid_ps)*margin_ps;

        if y_min_ps == y_max_ps
            y_min_ps = y_min_ps - margin_ps;
            y_max_ps = y_max_ps + margin_ps;
        end

        ylim([y_min_ps, y_max_ps]);
    end

    grid on;
    legend('Location', 'best');
    xlabel('Time [Hours]', 'FontWeight', 'bold');
    ylabel('Clock Bias [Picoseconds]', 'FontWeight', 'bold');
    title('EKF Tracking SpaceAsset Onboard Clock Bias', 'FontSize', 12);
end

function plotGroundClockBias(time_vec, true_ground_clock_bias_ps, towers)
    if size(true_ground_clock_bias_ps, 2) ~= numel(time_vec)
        true_ground_clock_bias_ps = true_ground_clock_bias_ps';
    end

    for idx = 1:size(true_ground_clock_bias_ps, 1)
        station_name = sprintf('Station %d', idx);
        if idx <= numel(towers)
            station_name = towers(idx).name;
        end
        plot(time_vec / 3600, true_ground_clock_bias_ps(idx, :), ...
            'LineWidth', 1.1, 'DisplayName', station_name);
        hold on;
    end
    grid on;
    legend('Location', 'best');
    xlabel('Time [Hours]', 'FontWeight', 'bold');
    ylabel('Ground Clock Bias [Picoseconds]', 'FontWeight', 'bold');
    title('Ground Transmitter Clock Biases', 'FontSize', 12);
end

function plotGroundClockCorrection(time_vec, true_ground_clock_bias_ps, correction_s, residual_s, sigma_s, towers)
    if size(true_ground_clock_bias_ps, 2) ~= numel(time_vec)
        true_ground_clock_bias_ps = true_ground_clock_bias_ps';
    end
    correction_ps = correction_s * 1e12;
    residual_ps = residual_s * 1e12;
    sigma_ps = sigma_s * 1e12;
    if size(correction_ps, 2) ~= numel(time_vec)
        correction_ps = correction_ps';
    end
    if size(residual_ps, 2) ~= numel(time_vec)
        residual_ps = residual_ps';
    end
    if size(sigma_ps, 2) ~= numel(time_vec)
        sigma_ps = sigma_ps';
    end

    tiledlayout(2, 1, 'TileSpacing', 'compact', 'Padding', 'compact');
    nexttile;
    colors = lines(size(true_ground_clock_bias_ps, 1));
    for idx = 1:size(true_ground_clock_bias_ps, 1)
        station_name = sprintf('Station %d', idx);
        if idx <= numel(towers)
            station_name = towers(idx).name;
        end
        plot(time_vec / 3600, true_ground_clock_bias_ps(idx, :), ...
            '-', 'Color', colors(idx, :), 'LineWidth', 1.0, ...
            'DisplayName', [station_name ' raw']);
        hold on;
        plot(time_vec / 3600, correction_ps(idx, :), ...
            '--', 'Color', colors(idx, :), 'LineWidth', 0.9, ...
            'HandleVisibility', 'off');
    end
    grid on;
    legend('Location', 'best');
    ylabel('Clock Correction [ps]', 'FontWeight', 'bold');
    title('Raw Tower Clock Bias and Applied Correction', 'FontSize', 12);

    nexttile;
    plot(time_vec / 3600, residual_ps', 'LineWidth', 0.9);
    hold on;
    sigma_envelope = sqrt(mean(sigma_ps.^2, 1, 'omitnan'));
    plot(time_vec / 3600, 3 * sigma_envelope, 'k:', 'LineWidth', 1.0, 'DisplayName', '+3 sigma RMS');
    plot(time_vec / 3600, -3 * sigma_envelope, 'k:', 'LineWidth', 1.0, 'DisplayName', '-3 sigma RMS');
    grid on;
    xlabel('Time [Hours]', 'FontWeight', 'bold');
    ylabel('Residual [ps]', 'FontWeight', 'bold');
    title('Residual Ground Timing Correction Error', 'FontSize', 12);
end

function plotGroundClockEstimate(time_vec, true_ground_clock_bias_ps, est_ground_clock_bias_ps, towers)
    if size(true_ground_clock_bias_ps, 2) ~= numel(time_vec)
        true_ground_clock_bias_ps = true_ground_clock_bias_ps';
    end
    if size(est_ground_clock_bias_ps, 2) ~= numel(time_vec)
        est_ground_clock_bias_ps = est_ground_clock_bias_ps';
    end

    colors = lines(size(true_ground_clock_bias_ps, 1));
    for idx = 1:size(true_ground_clock_bias_ps, 1)
        station_name = sprintf('Station %d', idx);
        if idx <= numel(towers)
            station_name = towers(idx).name;
        end
        plot(time_vec / 3600, true_ground_clock_bias_ps(idx, :), ...
            '-', 'Color', colors(idx, :), 'LineWidth', 1.0, ...
            'DisplayName', [station_name ' truth']);
        hold on;
        plot(time_vec / 3600, est_ground_clock_bias_ps(idx, :), ...
            '--', 'Color', colors(idx, :), 'LineWidth', 1.0, ...
            'DisplayName', [station_name ' EKF']);
    end
    grid on;
    legend('Location', 'best');
    xlabel('Time [Hours]', 'FontWeight', 'bold');
    ylabel('Tower Clock Bias [Picoseconds]', 'FontWeight', 'bold');
    title('Tower Clock Truth and EKF Estimates', 'FontSize', 12);
end

function plotInnovation(time_vec, innovation_rms_m, postfit_innovation_rms_m)
    plot(time_vec / 3600, innovation_rms_m, 'k', 'LineWidth', 1.2, 'DisplayName', 'Pre-fit innovation RMS');
    hold on;
    plot(time_vec / 3600, postfit_innovation_rms_m, 'b--', 'LineWidth', 1.1, 'DisplayName', 'Post-fit residual RMS');
    grid on;
    legend('Location', 'best');
    xlabel('Time [Hours]', 'FontWeight', 'bold');
    ylabel('Pseudorange RMS [Meters]', 'FontWeight', 'bold');
    title('Pseudorange Pre-Fit and Post-Fit Residuals', 'FontSize', 12);
end

function plotMeasurementCovarianceBreakdown(time_vec, ctx)
    receiver_sigma = rmsVarianceComponent(ctx, "R_receiver_m2");
    tower_sigma = rmsVarianceComponent(ctx, "R_tower_clock_m2");
    atmosphere_sigma = rmsVarianceComponent(ctx, "R_atmosphere_m2");
    hardware_sigma = rmsVarianceComponent(ctx, "R_hardware_m2");
    multipath_sigma = rmsVarianceComponent(ctx, "R_multipath_m2");
    numerical_sigma = zeros(size(receiver_sigma));
    if isfield(ctx, "R_numerical_regularization_m2")
        numerical_sigma = rmsVarianceComponent(ctx, "R_numerical_regularization_m2");
    end
    total_sigma = rmsVarianceComponent(ctx, "R_total_m2");

    plot(time_vec / 3600, total_sigma, 'k-', 'LineWidth', 1.4, 'DisplayName', 'Total');
    hold on;
    plot(time_vec / 3600, receiver_sigma, 'b-', 'LineWidth', 1.0, 'DisplayName', 'Receiver tracking');
    plot(time_vec / 3600, tower_sigma, 'r-', 'LineWidth', 1.0, 'DisplayName', 'Ground timing residual');
    plot(time_vec / 3600, atmosphere_sigma, 'Color', [0.3 0.6 0.3], 'LineWidth', 1.0, 'DisplayName', 'Atmospheric residual');
    plot(time_vec / 3600, hardware_sigma, 'Color', [0.7 0.3 0.7], 'LineWidth', 1.0, 'DisplayName', 'Hardware placeholder');
    plot(time_vec / 3600, multipath_sigma, 'Color', [0.9 0.5 0.1], 'LineWidth', 1.0, 'DisplayName', 'Multipath placeholder');
    plot(time_vec / 3600, numerical_sigma, 'Color', [0.2 0.2 0.2], ...
        'LineStyle', ':', 'LineWidth', 1.0, 'DisplayName', 'Numerical floor');
    grid on;
    legend('Location', 'best');
    xlabel('Time [Hours]', 'FontWeight', 'bold');
    ylabel('R Component Sigma [Meters]', 'FontWeight', 'bold');
    title('Measurement Covariance Breakdown', 'FontSize', 12);
end

function plotAtmosphereComponents(time_vec, errors)
    truthTroposphere = rmsByEpoch( ...
        errors.troposphere.deterministicTruth_m);

    truthIonosphere = rmsByEpoch( ...
        errors.ionosphere.deterministicTruth_m);

    truthTotal = rmsByEpoch( ...
        errors.atmosphere.truth_m);

    modelTroposphere = rmsByEpoch( ...
        errors.troposphere.model_m);

    modelIonosphere = rmsByEpoch( ...
        errors.ionosphere.model_m);

    modelTotal = rmsByEpoch( ...
        errors.atmosphere.model_m);

    plot(time_vec / 3600, truthTotal, 'k-', ...
        'LineWidth', 1.4, 'DisplayName', 'Truth total');

    hold on;

    plot(time_vec / 3600, truthTroposphere, 'b-', ...
        'LineWidth', 1.0, 'DisplayName', 'Truth troposphere');

    plot(time_vec / 3600, truthIonosphere, 'r-', ...
        'LineWidth', 1.0, 'DisplayName', 'Truth ionosphere');

    plot(time_vec / 3600, modelTotal, 'k--', ...
        'LineWidth', 1.2, 'DisplayName', 'Model total');

    plot(time_vec / 3600, modelTroposphere, 'b--', ...
        'LineWidth', 0.9, 'DisplayName', 'Model troposphere');

    plot(time_vec / 3600, modelIonosphere, 'r--', ...
        'LineWidth', 0.9, 'DisplayName', 'Model ionosphere');

    grid on;
    legend('Location', 'best');
    xlabel('Time [Hours]', 'FontWeight', 'bold');
    ylabel('Atmosphere Code Delay RMS [Meters]', 'FontWeight', 'bold');
    title('Ionosphere and Troposphere Code-Delay Components', 'FontSize', 12);
end

function plotAtmosphereResidualComponents(time_vec, errors)
    totalResidual = rmsByEpoch( ...
        errors.atmosphere.residual_m);

    troposphereResidual = rmsByEpoch( ...
        errors.troposphere.residual_m);

    ionosphereResidual = rmsByEpoch( ...
        errors.ionosphere.residual_m);

    plot(time_vec / 3600, totalResidual, 'k-', ...
        'LineWidth', 1.4, 'DisplayName', 'Total atmosphere residual');

    hold on;

    plot(time_vec / 3600, troposphereResidual, 'b-', ...
        'LineWidth', 1.0, 'DisplayName', 'Troposphere residual');

    plot(time_vec / 3600, ionosphereResidual, 'r-', ...
        'LineWidth', 1.0, 'DisplayName', 'Ionosphere residual');

    grid on;
    legend('Location', 'best');
    xlabel('Time [Hours]', 'FontWeight', 'bold');
    ylabel('Truth Minus Model RMS [Meters]', 'FontWeight', 'bold');
    title('Atmospheric Model Residual Components', 'FontSize', 12);
end

function plotIonosphereMapDiagnostics(time_vec, diags)
    truthVtec = meanByEpoch( ...
        diags.atmosphere.truth.ionosphere.vtec_TECU);

    modelVtec = meanByEpoch( ...
        diags.atmosphere.model.ionosphere.vtec_TECU);

    truthStec = meanByEpoch( ...
        diags.atmosphere.truth.ionosphere.stec_TECU);

    modelStec = meanByEpoch( ...
        diags.atmosphere.model.ionosphere.stec_TECU);

    truthMapping = meanByEpoch( ...
        diags.atmosphere.truth.ionosphere.mapping_factor);

    modelMapping = meanByEpoch( ...
        diags.atmosphere.model.ionosphere.mapping_factor);

    tiledlayout(2, 1, 'TileSpacing', 'compact', 'Padding', 'compact');

    nexttile;

    plot(time_vec / 3600, truthVtec, 'b-', ...
        'LineWidth', 1.1, 'DisplayName', 'Truth VTEC');

    hold on;

    plot(time_vec / 3600, modelVtec, 'b--', ...
        'LineWidth', 1.0, 'DisplayName', 'Model VTEC');

    plot(time_vec / 3600, truthStec, 'r-', ...
        'LineWidth', 1.1, 'DisplayName', 'Truth STEC');

    plot(time_vec / 3600, modelStec, 'r--', ...
        'LineWidth', 1.0, 'DisplayName', 'Model STEC');

    grid on;
    legend('Location', 'best');
    xlabel('Time [Hours]', 'FontWeight', 'bold');
    ylabel('TEC [TECU]', 'FontWeight', 'bold');
    title('Ionosphere VTEC and Slant TEC at Pierce Point', 'FontSize', 12);

    nexttile;

    plot(time_vec / 3600, truthMapping, 'k-', ...
        'LineWidth', 1.1, 'DisplayName', 'Truth mapping factor');

    hold on;

    plot(time_vec / 3600, modelMapping, 'k--', ...
        'LineWidth', 1.0, 'DisplayName', 'Model mapping factor');

    grid on;
    legend('Location', 'best');
    xlabel('Time [Hours]', 'FontWeight', 'bold');
    ylabel('Mapping Factor [-]', 'FontWeight', 'bold');
    title('Thin-Shell Ionosphere Mapping Factor', 'FontSize', 12);
end

function plotTroposphereProfileDiagnostics(time_vec, diags)
    truthZhd = meanByEpoch( ...
        diags.atmosphere.truth.troposphere.zhd_m);

    modelZhd = meanByEpoch( ...
        diags.atmosphere.model.troposphere.zhd_m);

    truthZwd = meanByEpoch( ...
        diags.atmosphere.truth.troposphere.zwd_m);

    modelZwd = meanByEpoch( ...
        diags.atmosphere.model.troposphere.zwd_m);

    truthSlantHydrostatic = meanByEpoch( ...
        diags.atmosphere.truth.troposphere.slant_hydrostatic_m);

    modelSlantHydrostatic = meanByEpoch( ...
        diags.atmosphere.model.troposphere.slant_hydrostatic_m);

    truthSlantWet = meanByEpoch( ...
        diags.atmosphere.truth.troposphere.slant_wet_m);

    modelSlantWet = meanByEpoch( ...
        diags.atmosphere.model.troposphere.slant_wet_m);

    tiledlayout(2, 1, ...
        'TileSpacing', 'compact', ...
        'Padding', 'compact');

    nexttile;

    plot(time_vec / 3600, truthZhd, 'b-', ...
        'LineWidth', 1.1, ...
        'DisplayName', 'Truth ZHD');

    hold on;

    plot(time_vec / 3600, modelZhd, 'b--', ...
        'LineWidth', 1.0, ...
        'DisplayName', 'Model ZHD');

    plot(time_vec / 3600, truthZwd, 'r-', ...
        'LineWidth', 1.1, ...
        'DisplayName', 'Truth ZWD');

    plot(time_vec / 3600, modelZwd, 'r--', ...
        'LineWidth', 1.0, ...
        'DisplayName', 'Model ZWD');

    grid on;
    legend('Location', 'best');
    xlabel('Time [Hours]', 'FontWeight', 'bold');
    ylabel('Zenith Delay [Meters]', 'FontWeight', 'bold');
    title('Troposphere Zenith Hydrostatic and Wet Delay', ...
        'FontSize', 12);

    nexttile;

    plot(time_vec / 3600, truthSlantHydrostatic, 'b-', ...
        'LineWidth', 1.1, ...
        'DisplayName', 'Truth slant hydrostatic');

    hold on;

    plot(time_vec / 3600, modelSlantHydrostatic, 'b--', ...
        'LineWidth', 1.0, ...
        'DisplayName', 'Model slant hydrostatic');

    plot(time_vec / 3600, truthSlantWet, 'r-', ...
        'LineWidth', 1.1, ...
        'DisplayName', 'Truth slant wet');

    plot(time_vec / 3600, modelSlantWet, 'r--', ...
        'LineWidth', 1.0, ...
        'DisplayName', 'Model slant wet');

    grid on;
    legend('Location', 'best');
    xlabel('Time [Hours]', 'FontWeight', 'bold');
    ylabel('Slant Delay [Meters]', 'FontWeight', 'bold');
    title('Troposphere Slant Hydrostatic and Wet Delay', ...
        'FontSize', 12);
end

function plotStochasticTruthAtmosphereResiduals(time_vec, errors)
    time_h = time_vec(:).' / 3600.0;

    totalResidualByTower_m = ...
        errors.atmosphere.stochasticResidualByTower_m;

    troposphereResidualByTower_m = ...
        errors.troposphere.stochasticResidualByTower_m;

    ionosphereResidualByTower_m = ...
        errors.ionosphere.stochasticResidualByTower_m;

    totalSamples_m = totalResidualByTower_m(:);
    totalSamples_m = totalSamples_m(isfinite(totalSamples_m));

    tiledlayout(2, 1, ...
        'TileSpacing', 'compact', ...
        'Padding', 'compact');

    nexttile;

    numTowers = size(totalResidualByTower_m, 1);
    colors = lines(max(numTowers, 1));

    for twr = 1:numTowers
        plot(time_h, totalResidualByTower_m(twr, :), ...
            '-', ...
            'Color', colors(twr, :), ...
            'LineWidth', 1.1, ...
            'DisplayName', sprintf('Tower %d total', twr));

        hold on;

        plot(time_h, troposphereResidualByTower_m(twr, :), ...
            '--', ...
            'Color', colors(twr, :), ...
            'LineWidth', 0.8, ...
            'HandleVisibility', 'off');

        plot(time_h, ionosphereResidualByTower_m(twr, :), ...
            ':', ...
            'Color', colors(twr, :), ...
            'LineWidth', 0.8, ...
            'HandleVisibility', 'off');
    end

    grid on;
    legend('Location', 'best');
    xlabel('Time [Hours]', 'FontWeight', 'bold');
    ylabel('Residual [Meters]', 'FontWeight', 'bold');
    title('Tower-Common Truth Atmosphere Residual Samples', ...
        'FontSize', 12);

    nexttile;

    if isempty(totalSamples_m)
        plot(NaN, NaN);
    else
        histogram(totalSamples_m, ...
            'Normalization', 'pdf');
    end

    grid on;
    xlabel('Total Truth Atmosphere Residual [Meters]', ...
        'FontWeight', 'bold');
    ylabel('Probability Density [-]', ...
        'FontWeight', 'bold');
    title('Distribution of Total Truth Atmosphere Residual Samples', ...
        'FontSize', 12);
end

function series = rmsByEpoch(data_by_receiver_tower_time)
    numEpochs = size(data_by_receiver_tower_time, 3);
    flattened = reshape(data_by_receiver_tower_time, [], numEpochs);
    series = sqrt(mean(flattened.^2, 1, 'omitnan'));
end

function series = meanByEpoch(data_by_receiver_tower_time)
    numEpochs = size(data_by_receiver_tower_time, 3);
    flattened = reshape(data_by_receiver_tower_time, [], numEpochs);
    series = mean(flattened, 1, 'omitnan');
end

function sigma = rmsVarianceComponent(ctx, field_name)
    values = ctx.(field_name);
    sigma = sqrt(mean(values, 1, 'omitnan'));
end

function plotResidualByTower(time_vec, prefit_residual_by_tower_m, postfit_residual_by_tower_m, towers)
    if size(prefit_residual_by_tower_m, 2) ~= numel(time_vec)
        prefit_residual_by_tower_m = prefit_residual_by_tower_m';
    end
    if size(postfit_residual_by_tower_m, 2) ~= numel(time_vec)
        postfit_residual_by_tower_m = postfit_residual_by_tower_m';
    end

    colors = lines(size(prefit_residual_by_tower_m, 1));
    for idx = 1:size(prefit_residual_by_tower_m, 1)
        station_name = sprintf('Station %d', idx);
        if idx <= numel(towers)
            station_name = towers(idx).name;
        end
        plot(time_vec / 3600, prefit_residual_by_tower_m(idx, :), ...
            '-', 'Color', colors(idx, :), 'LineWidth', 1.0, ...
            'DisplayName', [station_name ' pre-fit']);
        hold on;
        plot(time_vec / 3600, postfit_residual_by_tower_m(idx, :), ...
            '--', 'Color', colors(idx, :), 'LineWidth', 0.8, ...
            'HandleVisibility', 'off');
    end
    grid on;
    legend('Location', 'best');
    xlabel('Time [Hours]', 'FontWeight', 'bold');
    ylabel('Residual [Meters]', 'FontWeight', 'bold');
    title('Per-Tower Pseudorange Residuals', 'FontSize', 12);
end

function plotPerReceiverResidualRms(time_vec, data_by_receiver_tower_m, receiver_names, ylabel_text)
    num_receivers = size(data_by_receiver_tower_m, 1);
    [num_rows, num_cols] = receiverTileGrid(num_receivers);

    tiledlayout(num_rows, num_cols, 'TileSpacing', 'compact', 'Padding', 'compact');

    for idx_receiver = 1:num_receivers
        nexttile;

        values = squeeze(sqrt(mean(data_by_receiver_tower_m(idx_receiver, :, :).^2, 2, 'omitnan')));
        values = values(:).';

        plot(time_vec / 3600, values, 'LineWidth', 1.2);
        grid on;

        xlabel('Time [Hours]');
        ylabel(ylabel_text);
        title(char(string(receiver_names(idx_receiver))), 'Interpreter', 'none');
    end
end

function plotReceiverResidualHeatmaps(time_vec, prefit_by_receiver_tower_m, postfit_by_receiver_tower_m, receiver_names, tower_names)
    num_receivers = size(prefit_by_receiver_tower_m, 1);

    tiledlayout(num_receivers, 2, 'TileSpacing', 'compact', 'Padding', 'compact');

    for idx_receiver = 1:num_receivers
        nexttile;
        imagesc(time_vec / 3600, 1:numel(tower_names), squeeze(prefit_by_receiver_tower_m(idx_receiver, :, :)));
        set(gca, 'YTick', 1:numel(tower_names), 'YTickLabel', cellstr(string(tower_names)));
        xlabel('Time [Hours]');
        ylabel('Tower');
        title(sprintf('%s pre-fit [m]', char(string(receiver_names(idx_receiver)))), 'Interpreter', 'none');
        colorbar;

        nexttile;
        imagesc(time_vec / 3600, 1:numel(tower_names), squeeze(postfit_by_receiver_tower_m(idx_receiver, :, :)));
        set(gca, 'YTick', 1:numel(tower_names), 'YTickLabel', cellstr(string(tower_names)));
        xlabel('Time [Hours]');
        ylabel('Tower');
        title(sprintf('%s post-fit [m]', char(string(receiver_names(idx_receiver)))), 'Interpreter', 'none');
        colorbar;
    end
end

function [num_rows, num_cols] = receiverTileGrid(num_receivers)
    num_cols = ceil(sqrt(num_receivers));
    num_rows = ceil(num_receivers / num_cols);
end

function plotRx2MinusRx1Residuals(time_vec, prefit_by_receiver_tower_m, postfit_by_receiver_tower_m, tower_names)
    if size(prefit_by_receiver_tower_m, 1) < 2
        text(0.05, 0.5, 'RX2-RX1 residual diagnostics require at least two receivers.');
        axis off;
        return;
    end
    delta_prefit = squeeze(prefit_by_receiver_tower_m(2, :, :) - prefit_by_receiver_tower_m(1, :, :));
    delta_postfit = squeeze(postfit_by_receiver_tower_m(2, :, :) - postfit_by_receiver_tower_m(1, :, :));
    tiledlayout(2, 1, 'TileSpacing', 'compact', 'Padding', 'compact');
    nexttile;
    plot(time_vec / 3600, delta_prefit', 'LineWidth', 0.9);
    grid on;
    xlabel('Time [Hours]');
    ylabel('\Delta pre-fit [m]');
    title('RX2 minus RX1 same-tower pre-fit residuals');
    legend(cellstr(string(tower_names)), 'Location', 'bestoutside');
    nexttile;
    plot(time_vec / 3600, sqrt(mean(delta_prefit.^2, 1, 'omitnan')), 'k-', 'LineWidth', 1.2);
    hold on;
    plot(time_vec / 3600, sqrt(mean(delta_postfit.^2, 1, 'omitnan')), 'b--', 'LineWidth', 1.2);
    grid on;
    xlabel('Time [Hours]');
    ylabel('RMS [m]');
    title('RX2 minus RX1 differential residual RMS');
    legend('Pre-fit', 'Post-fit', 'Location', 'best');
end

function plotBaselineProjection(time_vec, true_range_by_receiver_tower_m, los_unit_eci_by_receiver_tower, receiver_offset_body_by_receiver_m, tower_names)
    if size(true_range_by_receiver_tower_m, 1) < 2
        text(0.05, 0.5, 'Baseline projection diagnostics require at least two receivers.');
        axis off;
        return;
    end
    baseline_body_m = receiver_offset_body_by_receiver_m(:, 2) - receiver_offset_body_by_receiver_m(:, 1);
    delta_exact = squeeze(true_range_by_receiver_tower_m(2, :, :) - true_range_by_receiver_tower_m(1, :, :));
    los_rx1 = squeeze(los_unit_eci_by_receiver_tower(:, 1, :, :));
    delta_approx = squeeze(sum(los_rx1 .* reshape(baseline_body_m, 3, 1, 1), 1));
    projection_error = delta_exact - delta_approx;
    tiledlayout(2, 1, 'TileSpacing', 'compact', 'Padding', 'compact');
    nexttile;
    plot(time_vec / 3600, delta_exact', 'LineWidth', 0.9);
    hold on;
    plot(time_vec / 3600, delta_approx', '--', 'LineWidth', 0.9);
    grid on;
    xlabel('Time [Hours]');
    ylabel('\Delta\rho [m]');
    title('Exact RX2-RX1 Range Difference and LOS Projection');
    legend([cellstr(string(tower_names)); cellstr(string(tower_names) + " approx")], 'Location', 'bestoutside');
    nexttile;
    plot(time_vec / 3600, projection_error', 'LineWidth', 0.9);
    grid on;
    xlabel('Time [Hours]');
    ylabel('Exact - approx [m]');
    title('First-Order Baseline Projection Residual');
end

function plotDifferentialObservable(time_vec, pseudorange_by_receiver_tower_m, true_range_by_receiver_tower_m, tower_names)
    if size(pseudorange_by_receiver_tower_m, 1) < 2
        text(0.05, 0.5, 'Differential observable diagnostics require at least two receivers.');
        axis off;
        return;
    end
    delta_z = squeeze(pseudorange_by_receiver_tower_m(2, :, :) - pseudorange_by_receiver_tower_m(1, :, :));
    delta_rho = squeeze(true_range_by_receiver_tower_m(2, :, :) - true_range_by_receiver_tower_m(1, :, :));
    consistency = delta_z - delta_rho;
    tiledlayout(2, 1, 'TileSpacing', 'compact', 'Padding', 'compact');
    nexttile;
    plot(time_vec / 3600, delta_z', 'LineWidth', 0.9);
    hold on;
    plot(time_vec / 3600, delta_rho', '--', 'LineWidth', 0.9);
    grid on;
    xlabel('Time [Hours]');
    ylabel('\Delta [m]');
    title('RX2-RX1 Differential Pseudorange and Geometry');
    legend([cellstr(string(tower_names)); cellstr(string(tower_names) + " geom")], 'Location', 'bestoutside');
    nexttile;
    plot(time_vec / 3600, consistency', 'LineWidth', 0.9);
    grid on;
    xlabel('Time [Hours]');
    ylabel('\Delta z - \Delta\rho [m]');
    title('Clock-Cancelled Differential Observable Residual');
end

function plotReceiverSubsetComparison(time_vec, values_by_case, case_labels, ylabel_text)
    plot(time_vec / 3600, values_by_case', 'LineWidth', 1.2);
    grid on;
    xlabel('Time [Hours]', 'FontWeight', 'bold');
    ylabel(ylabel_text, 'FontWeight', 'bold');
    title('RX1 Only, RX2 Only, and RX1+RX2 Fused EKF Comparison', 'FontSize', 12);
    legend(cellstr(string(case_labels)), 'Location', 'best');
end

function plotReceiverSubsetResiduals(time_vec, diagnostics)
    plot(time_vec / 3600, diagnostics.prefit_rms_m', 'LineWidth', 1.0);
    hold on;
    plot(time_vec / 3600, diagnostics.postfit_rms_m', '--', 'LineWidth', 1.0);
    grid on;
    xlabel('Time [Hours]', 'FontWeight', 'bold');
    ylabel('Residual RMS [m]', 'FontWeight', 'bold');
    legend([cellstr(string(diagnostics.case_labels) + " pre"); cellstr(string(diagnostics.case_labels) + " post")], ...
        'Location', 'best');
    title('Receiver-Subset Pre-Fit and Post-Fit Residual RMS', 'FontSize', 12);
end

function plotVisibleTowers(time_vec, visible_tower_count, num_towers)
    stairs(time_vec / 3600, visible_tower_count, 'k-', 'LineWidth', 1.4);
    grid on;
    ylim([0, max(num_towers, max(visible_tower_count, [], 'omitnan')) + 0.5]);
    xlabel('Time [Hours]', 'FontWeight', 'bold');
    ylabel('Tower Rows Used [-]', 'FontWeight', 'bold');
    title('Number of Tower Rows Used by the EKF', 'FontSize', 12);
end

function plotNis(time_vec, nis_history, num_towers, nis_degrees_of_freedom)
    time_vec = time_vec(:).';
    nis_history = nis_history(:).';
    if nargin < 4 || isempty(nis_degrees_of_freedom)
        nis_degrees_of_freedom = num_towers * ones(size(time_vec));
    elseif isscalar(nis_degrees_of_freedom)
        nis_degrees_of_freedom = nis_degrees_of_freedom * ones(size(time_vec));
    else
        nis_degrees_of_freedom = nis_degrees_of_freedom(:).';
    end
    h_nis = plot(time_vec / 3600, nis_history, 'b', 'LineWidth', 1.2, ...
        'DisplayName', 'NIS');
    hold on;
    h_mean = plot(time_vec / 3600, nis_degrees_of_freedom, 'k--', 'LineWidth', 1.0, ...
        'DisplayName', 'Expected mean if noise is injected');
    upper95 = arrayfun(@chiSquareApprox95, nis_degrees_of_freedom);
    h_upper = plot(time_vec / 3600, upper95, 'r:', 'LineWidth', 1.0, ...
        'DisplayName', 'Approx. 95% upper bound');
    grid on;
    legend([h_nis h_mean h_upper], 'Location', 'best');
    xlabel('Time [Hours]', 'FontWeight', 'bold');
    ylabel('NIS [-]', 'FontWeight', 'bold');
    title('Innovation Consistency Check', 'FontSize', 12);
end

function plotInnovationCovarianceConsistency(time_vec, ctx)
    time_h = time_vec(:).' / 3600.0;

    innovationRms_m = ctx.innovation_rms_m(:).';
    innovationSigma_m = ctx.innovation_covariance_mean_sigma_m(:).';

    nisPerDof = ctx.nis_per_degree_of_freedom(:).';
    normalizedInnovationRms = ctx.normalized_innovation_rms(:).';

    tiledlayout(2, 1, ...
        'TileSpacing', 'compact', ...
        'Padding', 'compact');

    nexttile;

    plot(time_h, innovationRms_m, ...
        'LineWidth', 1.2, ...
        'DisplayName', 'Pre-fit innovation RMS');

    hold on;

    plot(time_h, innovationSigma_m, ...
        '--', ...
        'LineWidth', 1.2, ...
        'DisplayName', 'Mean sqrt(diag(S))');

    grid on;
    legend('Location', 'best');
    xlabel('Time [Hours]', 'FontWeight', 'bold');
    ylabel('Meters', 'FontWeight', 'bold');
    title('Innovation Magnitude Compared with Innovation Covariance', ...
        'FontSize', 12);

    nexttile;

    plot(time_h, nisPerDof, ...
        'LineWidth', 1.2, ...
        'DisplayName', 'NIS / DOF');

    hold on;

    plot(time_h, normalizedInnovationRms, ...
        '--', ...
        'LineWidth', 1.2, ...
        'DisplayName', 'sqrt(NIS / DOF)');

    yline(1.0, ...
        'k:', ...
        'Expected value for consistent stochastic model', ...
        'LineWidth', 1.0);

    grid on;
    legend('Location', 'best');
    xlabel('Time [Hours]', 'FontWeight', 'bold');
    ylabel('Normalised value [-]', 'FontWeight', 'bold');
    title('Normalised Innovation Consistency', ...
        'FontSize', 12);
end

function value = chiSquareApprox95(degrees_of_freedom)
    if ~isfinite(degrees_of_freedom) || degrees_of_freedom <= 0
        value = NaN;
        return;
    end
    z95 = 1.64485362695147;
    value = degrees_of_freedom * (1 - 2 / (9 * degrees_of_freedom) + ...
        z95 * sqrt(2 / (9 * degrees_of_freedom)))^3;
end

function plotGeometry(R_earth, sat_pos_history_m, towers_eci_first_m, towers)
    [xe, ye, ze] = sphere(40);
    surf(R_earth * xe, R_earth * ye, R_earth * ze, ...
        'FaceColor', [0.75 0.85 1.0], 'EdgeColor', 'none', 'FaceAlpha', 0.35);
    hold on;
    plot3(sat_pos_history_m(1, :), sat_pos_history_m(2, :), sat_pos_history_m(3, :), ...
        'k-', 'LineWidth', 1.5, 'DisplayName', 'Space asset trajectory');
    scatter3(towers_eci_first_m(1, :), towers_eci_first_m(2, :), towers_eci_first_m(3, :), ...
        60, 'r', 'filled', 'DisplayName', 'Ground segment at start');
    for i = 1:length(towers)
        plot3([towers_eci_first_m(1, i), sat_pos_history_m(1, 1)], ...
              [towers_eci_first_m(2, i), sat_pos_history_m(2, 1)], ...
              [towers_eci_first_m(3, i), sat_pos_history_m(3, 1)], ...
              'm--', 'LineWidth', 1.0, 'HandleVisibility', 'on');
        text(towers_eci_first_m(1, i), towers_eci_first_m(2, i), towers_eci_first_m(3, i), ...
            ['  ' towers(i).name], 'FontSize', 8);
    end
    axis equal;
    grid on;
    xlabel('ECI X [m]', 'FontWeight', 'bold');
    ylabel('ECI Y [m]', 'FontWeight', 'bold');
    zlabel('ECI Z [m]', 'FontWeight', 'bold');
    title('Ground-to-Space Measurement Geometry', 'FontSize', 12);
    legend('Location', 'best');
    view(35, 25);
end

function plotAllanDeviation(oscillators, selected_oscillator_name, tau_profile_s, tau_sim_s, sim_adev, dt, clock_allan_names, sim_adev_by_clock)

    if nargin < 7 || isempty(clock_allan_names)
        clock_allan_names = string(selected_oscillator_name);
    end

    if nargin < 8 || isempty(sim_adev_by_clock)
        sim_adev_by_clock = sim_adev(:).';
    end

    clock_allan_names = string(clock_allan_names);

    oscillator_plot_styles = { ...
        'TCXO',           [1.00 0.00 0.00], '-',  'Allan deviation for TCXO'; ...
        'StandardQuartz', [0.00 0.80 0.00], '--', 'Allan deviation for a quartz'; ...
        'OCXO1',          [0.00 0.00 1.00], ':',  'Allan deviation for OCXO 1'; ...
        'Rubidium1',      [1.00 0.00 1.00], ':',  'Allan deviation for Rubidium'; ...
        'Cesium1',        [0.00 0.85 0.85], '-.', 'Allan deviation for a Cesium'; ...
        'OCXO2',          [1.00 0.90 0.00], '--', 'Allan deviation for a OCXO2' ...
    };

    hold on;

    x_all = [];
    y_all = [];

    % ---------------------------------------------------------------------
    % 1) Full theoretical Allan deviation curves
    % ---------------------------------------------------------------------
    for i = 1:size(oscillator_plot_styles, 1)
        osc_name = oscillator_plot_styles{i, 1};

        if ~isfield(oscillators, osc_name)
            continue;
        end

        line_color = oscillator_plot_styles{i, 2};
        line_style = oscillator_plot_styles{i, 3};
        legend_name = oscillator_plot_styles{i, 4};

        osc_clock = Clock( ...
            oscillators.(osc_name).h0, ...
            oscillators.(osc_name).hm1, ...
            oscillators.(osc_name).hm2, ...
            dt);

        y_theory = osc_clock.theoreticalAllanDeviation(tau_profile_s);

        valid_theory = isfinite(tau_profile_s) & tau_profile_s > 0 & ...
                       isfinite(y_theory) & y_theory > 0;

        loglog(tau_profile_s(valid_theory), y_theory(valid_theory), ...
            line_style, ...
            'LineWidth', 1.5, ...
            'Color', line_color, ...
            'DisplayName', legend_name);

        x_all = [x_all, tau_profile_s(valid_theory)]; %#ok<AGROW>
        y_all = [y_all, y_theory(valid_theory)];      %#ok<AGROW>
    end

    % ---------------------------------------------------------------------
    % 2) Simulated overlapping Allan deviation points
    % ---------------------------------------------------------------------
    marker_symbols = {'s', 'o', '^', 'v', 'd', 'p', 'h', 'x', '+', '*'};

    if size(sim_adev_by_clock, 1) ~= numel(clock_allan_names)
        sim_adev_by_clock = reshape(sim_adev_by_clock, 1, []);
        clock_allan_names = string(selected_oscillator_name);
    end

    point_colors = lines(max(1, size(sim_adev_by_clock, 1)));

    for idx_clock = 1:size(sim_adev_by_clock, 1)

        valid_sim = isfinite(tau_sim_s) & tau_sim_s > 0 & ...
                    isfinite(sim_adev_by_clock(idx_clock, :)) & ...
                    sim_adev_by_clock(idx_clock, :) > 0;

        if ~any(valid_sim)
            continue;
        end

        marker_idx = 1 + mod(idx_clock - 1, numel(marker_symbols));

        loglog(tau_sim_s(valid_sim), sim_adev_by_clock(idx_clock, valid_sim), ...
            marker_symbols{marker_idx}, ...
            'LineStyle', 'none', ...
            'MarkerEdgeColor', point_colors(idx_clock, :), ...
            'MarkerFaceColor', 'w', ...
            'MarkerSize', 5, ...
            'LineWidth', 1.1, ...
            'DisplayName', ['Simulated points: ' char(clock_allan_names(idx_clock))]);

        x_all = [x_all, tau_sim_s(valid_sim)];                         %#ok<AGROW>
        y_all = [y_all, sim_adev_by_clock(idx_clock, valid_sim)];      %#ok<AGROW>
    end

    % ---------------------------------------------------------------------
    % 3) Full automatic scale from BOTH theory and simulation
    % ---------------------------------------------------------------------
    grid on;

    ax = gca;
    ax.XScale = 'log';
    ax.YScale = 'log';

    x_all = x_all(isfinite(x_all) & x_all > 0);
    y_all = y_all(isfinite(y_all) & y_all > 0);

    if ~isempty(x_all)
        ax.XLim = [10^floor(log10(min(x_all))), 10^ceil(log10(max(x_all)))];
    end

    if ~isempty(y_all)
        ax.YLim = [10^floor(log10(min(y_all))), 10^ceil(log10(max(y_all)))];
    end

    ax.XMinorGrid = 'on';
    ax.YMinorGrid = 'on';
    ax.GridLineStyle = ':';

    xlabel('Time [s]', 'FontWeight', 'bold');
    ylabel('Allan deviation \sigma_y(\tau) [-]', 'FontWeight', 'bold');
    title('Oscillator Stability Check', 'FontSize', 12);

    legend('Location', 'southwest', 'FontSize', 6);
    legend boxoff;

    hold off;
end

%% LaTeX Formatting Helpers
function report = appendLine(report, line)
    report{end+1, 1} = char(line);
end

function report = appendParagraph(report, text_value)
    report = appendLine(report, latexEscape(text_value));
    report = appendLine(report, "");
end

function report = appendOptionalTable(report, title_text, data, field_name, max_rows)
    if ~isfield(data, field_name)
        return;
    end
    tbl = data.(field_name);
    if isempty(tbl)
        return;
    end
    if ~istable(tbl)
        error("generateReport:InvalidReportTable", ...
            "ctx.%s must be a MATLAB table.", field_name);
    end
    if height(tbl) == 0
        return;
    end
    if nargin < 5 || isempty(max_rows)
        max_rows = height(tbl);
    end

    if strlength(string(title_text)) > 0
        report = appendLine(report, sprintf("\\subsection{%s}", latexEscape(title_text)));
    end
    report = appendLine(report, "\begin{center}");
    report = appendLine(report, "\scriptsize");
    column_spec = compactTableColumnSpec(width(tbl), field_name);
    report = appendLine(report, sprintf("\\begin{longtable}{%s}", column_spec));
    report = appendLine(report, "\toprule");
    report = appendLine(report, latexTableHeader(tbl));
    report = appendLine(report, "\midrule");
    row_limit = min(height(tbl), max_rows);
    for idx_row = 1:row_limit
        report = appendLine(report, latexTableRow(tbl, idx_row));
    end
    if height(tbl) > row_limit
        omitted = height(tbl) - row_limit;
        report = appendLine(report, sprintf("\\multicolumn{%d}{l}{\\textit{%d additional rows omitted for first-page compactness.}}\\\\", ...
            width(tbl), omitted));
    end
    report = appendLine(report, "\bottomrule");
    report = appendLine(report, "\end{longtable}");
    report = appendLine(report, "\normalsize");
    report = appendLine(report, "\end{center}");
end

function column_spec = compactTableColumnSpec(num_columns, field_name)
    if nargin < 2 || isempty(field_name)
        field_name = "";
    end

    if num_columns <= 0
        column_spec = "@{}p{0.9\textwidth}@{}";
        return;
    end

    % Custom layout for the EKF state-vector table.
    % Sum is deliberately below 1.0 because LaTeX also adds inter-column padding.
    if string(field_name) == "state_vector_table" && num_columns == 5
        widths = [0.055, 0.175, 0.295, 0.070, 0.270];
    else
        total_width_fraction = 0.82;
        widths = repmat(total_width_fraction / num_columns, 1, num_columns);
    end

    columns = strings(1, num_columns);
    for idx_col = 1:num_columns
        columns(idx_col) = sprintf(">{\\raggedright\\arraybackslash}p{%.3f\\textwidth}", widths(idx_col));
    end

    % @{} removes left/right outer table padding.
    column_spec = char("@{}" + strjoin(columns, "") + "@{}");
end

function header_line = latexTableHeader(tbl)
    names = string(tbl.Properties.VariableNames);
    header_cells = strings(1, numel(names));
    for idx_col = 1:numel(names)
        header_name = regexprep(char(names(idx_col)), '(?<=[a-z])(?=[A-Z])', ' ');
        header_cells(idx_col) = "\textbf{" + string(latexEscape(header_name)) + "}";
    end
    header_line = char(strjoin(header_cells, " & ") + "\\");
end

function row_line = latexTableRow(tbl, idx_row)
    names = string(tbl.Properties.VariableNames);
    row_cells = strings(1, numel(names));
    for idx_col = 1:numel(names)
        value = tbl{idx_row, idx_col};
        row_cells(idx_col) = string(latexEscape(tableCellToText(value)));
    end
    row_line = char(strjoin(row_cells, " & ") + "\\");
end

function text_value = tableCellToText(value)
    if iscell(value)
        if isempty(value)
            text_value = "";
            return;
        end
        value = value{1};
    end

    if isstring(value)
        if isempty(value)
            text_value = "";
        else
            value(ismissing(value)) = "";
            text_value = strjoin(value(:).', ", ");
        end

    elseif ischar(value)
        text_value = string(value);

    elseif isnumeric(value)
        if isempty(value)
            text_value = "";
        elseif isscalar(value)
            if isfinite(value)
                text_value = string(sprintf("%.6g", value));
            else
                text_value = "";
            end
        else
            text_value = string(mat2str(value, 6));
        end

    elseif islogical(value)
        text_value = string(value);

    elseif isdatetime(value)
        if ismissing(value)
            text_value = "";
        else
            text_value = string(value);
        end

    elseif isduration(value)
        if ismissing(value)
            text_value = "";
        else
            text_value = string(value);
        end

    else
        try
            text_value = string(value);
            text_value(ismissing(text_value)) = "";
        catch
            text_value = "<unprintable>";
        end
    end
end

function report = beginPlotTable(report)
    report = appendLine(report, "\begin{longtable}{@{}p{0.46\textwidth}p{0.48\textwidth}@{}}");
    report = appendLine(report, "\toprule");
    report = appendLine(report, "\textbf{Plot} & \textbf{Description and statistical approach}\\");
    report = appendLine(report, "\midrule");
end

function report = endPlotTable(report)
    report = appendLine(report, "\bottomrule");
    report = appendLine(report, "\end{longtable}");
end

function report = appendReportRow(report, is_enabled, plot_path, title_text, description_text)
    if is_enabled
        if strlength(string(plot_path)) > 0
            plot_ref = relativeLatexPath(plot_path);
            left_content = sprintf("\\includegraphics[width=\\linewidth]{%s}", plot_ref);
        else
            left_content = "\textit{No plot generated for this enabled configuration item.}";
        end
    else
        left_content = "\textit{No plot generated.}";
    end

    right_content = sprintf( ...
        "\\textbf{%s}\\par\\vspace{3pt}%s", ...
        latexEscape(title_text), ...
        latexEscape(description_text));

    left_cell = topAlignedTableCell(left_content);
    right_cell = topAlignedTableCell(right_content);

    report = appendLine(report, sprintf("%s & %s\\\\", left_cell, right_cell));
    report = appendLine(report, "\midrule");
end

function cell_text = topAlignedTableCell(content)
    cell_text = sprintf( ...
        "\\begin{minipage}[t]{\\linewidth}\\vspace{0pt}%s\\end{minipage}", ...
        char(string(content)));
end

function report = appendStatusRow(report, component_name, is_enabled)
    if is_enabled
        status = "\textcolor{green!45!black}{Enabled}";
        action = "Included in this report.";
    else
        status = "\textcolor{gray}{Disabled}";
        action = "Not part of the current clock-only validation scenario.";
    end
    report = appendLine(report, sprintf("%s & %s & %s\\\\", ...
        latexEscape(component_name), status, latexEscape(action)));
end

function report = appendFinalValueRow(report, quantity_name, value, unit_name)
    report = appendLine(report, sprintf("%s & %s\\\\", ...
        latexEscape(quantity_name), formatEngineering(value, unit_name)));
end

function report = appendSummaryMetricRow(report, metric_name, summary, final_window_summary)
    report = appendLine(report, sprintf("%s & %s & %s & %s & %s\\\\", ...
        latexEscape(metric_name), ...
        formatEngineering(summary.fullRunRms, ""), ...
        formatEngineering(summary.steadyStateRms, ""), ...
        formatEngineering(final_window_summary.steadyStateRms, ""), ...
        formatEngineering(final_window_summary.steadyStateP95Abs, "")));
end

function out = formatEngineering(value, unit_name)
    if isnan(value)
        number_text = "not available";
    elseif isinf(value)
        number_text = string(value);
    elseif value == 0
        number_text = "0";
    elseif abs(value) < 1e-3 || abs(value) >= 1e4
        number_text = string(sprintf('%.6e', value));
    else
        number_text = string(sprintf('%.6f', value));
    end

    if strlength(string(unit_name)) > 0 && number_text ~= "not available"
        out = char(number_text + " " + string(unit_name));
    else
        out = char(number_text);
    end
end

function tableOut = buildMeasurementModelReportTable()
    Term = ["geometric range"; "receiver clock bias"; "receiver clock drift"; ...
        "ground residual clock"; "extra delay"; "measurement noise"];

    Expression = ["rho = norm(r_sc,I + C_BI*l_a,B - r_g,I)"; "+b_rx"; "bdot_rx"; ...
        "-b_g_res"; "d_extra"; "nu"];

    Meaning = ["Receiver phase-center to tower range"; ...
        "Shared spacecraft receiver clock range-equivalent bias"; ...
        "Propagated clock drift"; ...
        "Transmitter-side residual after any external correction"; ...
        "Atmosphere/hardware/multipath/antenna/Sagnac terms"; ...
        "Pseudorange noise"];

    tableOut = table(Term, Expression, Meaning);
end

function out = latexEscape(in)
    if nargin == 0 || isempty(in)
        out = "";
        return;
    end

    raw_string = string(in);
    raw_string(ismissing(raw_string)) = "";

    if numel(raw_string) > 1
        raw_string = strjoin(raw_string, "");
    end

    raw = char(raw_string);

    out = "";
    for idx = 1:length(raw)
        ch = raw(idx);
        switch ch
            case '\'
                out = out + "\textbackslash{}";
            case '&'
                out = out + "\&";
            case '%'
                out = out + "\%";
            case '$'
                out = out + "\$";
            case '#'
                out = out + "\#";
            case '_'
                out = out + "\_";
            case '{'
                out = out + "\{";
            case '}'
                out = out + "\}";
            case '~'
                out = out + "\textasciitilde{}";
            case '^'
                out = out + "\textasciicircum{}";
            otherwise
                out = out + string(ch);
        end
    end

    out = char(out);
end

function safeStem = sanitizeLatexFileStem(fileStem)
    safeStem = string(fileStem);
    safeStem(ismissing(safeStem)) = "report";

    % Keep LaTeX/pdfTeX graphics filenames simple. Older graphicx versions
    % can misinterpret dots inside the filename stem as part of the extension.
    safeStem = regexprep(safeStem, '[^A-Za-z0-9_-]', '_');

    if strlength(safeStem) == 0
        safeStem = "report";
    end
end

function path_out = relativeLatexPath(path_in)
    [~, file_name, ext] = fileparts(char(string(path_in)));
    path_out = char("figures/" + string(file_name) + string(ext));
end

function writeTextFile(path_out, lines)
    fid = fopen(path_out, 'w');
    cleanup = onCleanup(@() fclose(fid));
    for i = 1:numel(lines)
        fprintf(fid, '%s\n', lines{i});
    end
end
