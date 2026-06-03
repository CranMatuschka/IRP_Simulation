classdef ReverseGnssSimulation < handle
    %REVERSEGNSSSIMULATION Reverse-GNSS pseudorange MEKF coordinator.
    %
    % Nominal state:
    %   r_sc_I, v_sc_I, q_BI, omega_B, b_rx_m, bdot_rx_mps
    %
    % EKF error state when enableTowerClockEKF = false:
    %   [dr_I(3); dv_I(3); dtheta_B(3); domega_B(3); db_rx_m; dbdot_rx_mps]
    %
    % EKF error state when enableTowerClockEKF = true:
    %   [dr_I(3); dv_I(3); dtheta_B(3); domega_B(3);
    %    db_rx_m; dbdot_rx_mps;
    %    db_g1_m; dbdot_g1_mps; ...; db_gN_m; dbdot_gN_mps]
    %
    % In tower-clock-EKF mode the receiver clock and tower clocks are
    % estimated relative to the mean ground-network clock gauge:
    %   mean(b_g) = 0
    %   mean(bdot_g) = 0
    %
    % q_BI maps Body vectors to ECI. Code pseudorange rows use ECI geometry:
    %   P_g,a = norm(r_sc_I + C_BI*l_a_B - r_g_I) + b_rx_m - b_g_res_m

    properties
        runtimeOptions = struct();
        scriptDir string;
        projectRoot string;
        entryPointName string = "ReverseGnssSimulation";

        simConfig;
        cfg;
        constants;
        c double = 299792458.0;
        mu double = 398600.4418e9;

        dt double = 1.0;
        numSteps double = 2;
        time_s double = [];
        jd0 double = NaN;

        clockStream = [];
        measurementStream = [];
        towerClockStream = [];
        validationClockStream = [];
        measurementModel;
        seedConfig = struct();

        towers cell = {};
        activeTowerConfig = struct([]);
        towerNames string = strings(1, 0);
        numTowers double = 0;
        towersEciFirst_m double = [];

        truthAsset;
        estAsset;

        assetConfig;
        receiverConfig = struct([]);
        receiverNames string = strings(1, 0);
        receiverOffsetsBody_m double = zeros(3, 0);
        receiverOffsetsLocal_m double = zeros(3, 0);
        numReceivers double = 0;

        estTowerClockBias_m double = zeros(0, 1);
        estTowerClockDrift_mps double = zeros(0, 1);

        idx = struct();
        stateDim double = 14;
        ekf;
        Q double = [];
        R double = [];
        transitionFromInitial double = eye(14);
        observabilityNormalMatrix double = zeros(14);

        initialX0 double = [];
        initialP0 double = [];
        initialTruth0 double = [];
        scenarioName string = "reverseGnssClockNavigationScenario";
        outputDir string = "";
        history struct = struct();
        results struct = struct();
    end

    methods
        function obj = ReverseGnssSimulation(runtimeOptions)
            if nargin >= 1 && ~isempty(runtimeOptions)
                obj.runtimeOptions = runtimeOptions;
            end
            if isfield(obj.runtimeOptions, 'entryPointName')
                obj.entryPointName = string(obj.runtimeOptions.entryPointName);
            end
            obj.scriptDir = string(fileparts(mfilename('fullpath')));
            obj.projectRoot = string(fileparts(char(obj.scriptDir)));
        end

        function configure(obj)
            obj.setupPaths();
            obj.loadConfig();
            obj.setupTime();
            obj.setupGroundNodes();
            obj.setupSpaceAssetAndReceivers();
            obj.setupMeasurementModel();
            obj.setupEkf();
            obj.setupHistory();
        end

        function run(obj)
            fprintf('%s: %d receivers, %d towers, %d EKF error states\n', ...
                char(obj.scenarioName), obj.numReceivers, obj.numTowers, obj.stateDim);
            for k = 1:obj.numSteps
                obj.step(k);
            end
            obj.buildResults();
            fprintf('Done. Final ECI position error: %.3f m\n', ...
                norm(obj.history.x(obj.idx.pos, end) - obj.history.truth(obj.idx.pos, end)));
            fprintf('Mean pseudorange innovation RMS: %.3f m over %.0f measurements/epoch\n', ...
                mean(obj.history.innovation_rms_m, 'omitnan'), mean(obj.history.pseudorange_measurement_count));
        end

        function saveResults(obj)
            if isempty(fieldnames(obj.results))
                obj.buildResults();
            end
            if strlength(obj.outputDir) == 0
                obj.outputDir = string(fullfile(char(obj.scriptDir), "reports", char(obj.entryPointName), char(obj.scenarioName)));
            end
            if ~exist(char(obj.outputDir), "dir")
                mkdir(char(obj.outputDir));
            end
            results = obj.results; %#ok<NASGU>
            save(fullfile(char(obj.outputDir), sprintf('%s_results.mat', char(obj.scenarioName))), 'results');
        end

        function generateReport(obj)
            if ~isfield(obj.cfg, 'report') || ...
                    ~logical(obj.getFieldOrDefault(obj.cfg.report, 'generatePdf', false))
                return;
            end

            if isempty(fieldnames(obj.results))
                obj.buildResults();
            end

            if strlength(obj.outputDir) == 0
                obj.outputDir = string(fullfile(char(obj.scriptDir), ...
                    "reports", char(obj.entryPointName), char(obj.scenarioName)));
            end

            if ~exist(char(obj.outputDir), "dir")
                mkdir(char(obj.outputDir));
            end

            reportData = obj.buildGenerateReportData();
            reportToggles = obj.buildReportToggles();
            reportConfig = obj.buildReportConfig();

            generateReport(reportData, reportConfig, reportToggles);
        end
    end

    methods (Access = private)
        function setupPaths(obj)
            addpath(char(obj.scriptDir));
            
            reportDir = fullfile(char(obj.scriptDir), 'Report');
            if isfolder(reportDir)
                addpath(reportDir);
            end

            if isfolder(char(obj.projectRoot))
                addpath(char(obj.projectRoot));
            end
        end

        function loadConfig(obj)
            if isfield(obj.runtimeOptions, 'simConfigOverride')
                simConfigOverride = obj.runtimeOptions.simConfigOverride; %#ok<NASGU>
            end
            if isfield(obj.runtimeOptions, 'simConfigOverrides')
                simConfigOverrides = obj.runtimeOptions.simConfigOverrides; %#ok<NASGU>
            end
            run(char(fullfile(char(obj.scriptDir), 'SimulationConfig.m')));
            obj.simConfig = simConfig;
            obj.cfg = obj.simConfig.scenarios.reverseGnssClockNavigationScenario;
            obj.constants = obj.simConfig.constants;
            obj.assetConfig = obj.cfg.spaceAsset;
            obj.c = obj.constants.speedOfLight_mps;
            obj.mu = obj.constants.earthMu_m3ps2;
            obj.scenarioName = string(obj.cfg.name);

            baseSeed = double(obj.simConfig.randomSeed);
            obj.seedConfig = obj.simConfig.seeds;
            if ~isfield(obj.seedConfig, 'towerClocks')
                obj.seedConfig.towerClocks = baseSeed + 3001;
            end
            rng(baseSeed, 'twister');
            obj.clockStream = RandStream('mt19937ar', 'Seed', obj.seedConfig.clockTruth);
            obj.measurementStream = RandStream('mt19937ar', 'Seed', obj.seedConfig.measurementNoise);
            obj.towerClockStream = RandStream('mt19937ar', 'Seed', obj.seedConfig.towerClocks);
            obj.validationClockStream = RandStream('mt19937ar', 'Seed', obj.seedConfig.allanValidation);
            obj.applyTowerClockEkfConfiguration();
        end

        function setupTime(obj)
            obj.dt = double(obj.simConfig.simulation.dt_s);
            obj.numSteps = max(2, floor(obj.simConfig.simulation.totalTime_h * 3600 / obj.dt) + 1);
            obj.time_s = (0:obj.numSteps - 1) * obj.dt;
            obj.jd0 = Clock.julianDateFromDatetime(obj.simConfig.simulation.startUtc);
        end

        function setupGroundNodes(obj)
            towerCfg = obj.cfg.towers;

            enabled = true(1, numel(towerCfg));
            if isfield(towerCfg, 'enabled')
                enabled = [towerCfg.enabled];
            end

            obj.activeTowerConfig = towerCfg(enabled);
            obj.numTowers = numel(obj.activeTowerConfig);
            obj.towerNames = string({obj.activeTowerConfig.name});
            obj.towers = cell(1, obj.numTowers);

            for k = 1:obj.numTowers
                tc = obj.activeTowerConfig(k);
                clk = obj.makeTowerClock(tc, k);
                obj.towers{k} = GroundNode(tc, clk);
            end

            obj.towersEciFirst_m = obj.towerPositionsEci(obj.jd0);
        end

        function setupSpaceAssetAndReceivers(obj)
            obj.assetConfig = obj.cfg.spaceAsset;

            state0 = SpaceAsset.initialGeoState(obj.assetConfig, obj.jd0, obj.mu);

            qTruth0 = obj.getQuaternionFromConfig( ...
                obj.assetConfig, 'trueInitialAttitude', [1; 0; 0; 0]);

            omegaTruth_B = obj.getRateVectorFromConfig( ...
                obj.assetConfig, 'trueAngularVelocity', zeros(3, 1));

            receiverCfg = obj.cfg.receivers;

            if isfield(obj.runtimeOptions, 'N_RECEIVERS')
                receiverCfg = receiverCfg(1:min(double(obj.runtimeOptions.N_RECEIVERS), numel(receiverCfg)));
            else
                receiverCfg = receiverCfg(1:min(double(obj.cfg.numReceivers), numel(receiverCfg)));
            end

            for k = 1:numel(receiverCfg)
                receiverCfg(k).enabled = true;
                receiverCfg(k).mode = "RX";
            end

            obj.receiverConfig = receiverCfg;

            receiverAntennas = SpaceAsset.buildAntennaArray(receiverCfg);

            osc = obj.simConfig.clockLibrary.(char(obj.assetConfig.clock.clockType));
            truthClock = Clock(osc.h0, osc.hm1, osc.hm2, obj.dt);
            truthClock.randomStream = obj.clockStream;
            truthClock.reset([ ...
                obj.assetConfig.clock.initialBias_ps * 1e-12; ...
                obj.assetConfig.clock.initialDrift_ps_per_s * 1e-12; ...
                0.0; ...
                0.0]);

            obj.truthAsset = SpaceAsset( ...
                1, obj.assetConfig.name, state0, qTruth0, omegaTruth_B, ...
                receiverAntennas, truthClock, "ECI");

            estState0 = state0;
            estState0(1:3) = estState0(1:3) + ...
                obj.vectorFieldOrDefault(obj.cfg.ekf, 'initialPositionError_m', [1000; 0; 0], 3);

            estState0(4:6) = estState0(4:6) + ...
                obj.vectorFieldOrDefault(obj.cfg.ekf, 'initialVelocityError_mps', [0.5; 0; 0], 3);

            dq0 = FrameGeometry.smallAngleQuat( ...
                obj.getAttitudeVectorFromConfig(obj.cfg.ekf, ...
                'initialAttitudeError', deg2rad([3; -2; 5])));

            qEst0 = FrameGeometry.quatMultiply(obj.truthAsset.q_BI, dq0);

            omegaEst_B = omegaTruth_B + ...
                obj.getRateVectorFromConfig(obj.cfg.ekf, ...
                'initialAngularVelocityError', zeros(3, 1));

            obj.estAsset = SpaceAsset( ...
                1, obj.assetConfig.name + "-EST", estState0, qEst0, omegaEst_B, ...
                receiverAntennas, [], "ECI");

            obj.estTowerClockBias_m = zeros(obj.numTowers, 1);
            obj.estTowerClockDrift_mps = zeros(obj.numTowers, 1);

            if obj.towerClockEkfEnabled()
                [towerBiasGauge_m, towerDriftGauge_mps, meanTowerBias_m, meanTowerDrift_mps] = ...
                    obj.towerClockTruthGaugeVectors();

                obj.estAsset.setNominalClockState( ...
                    obj.truthAsset.getClockBias_m() - meanTowerBias_m + ...
                    obj.getScalarField(obj.cfg.ekf, 'initialClockBiasError_m', 100.0), ...
                    obj.truthAsset.getClockDrift_mps() - meanTowerDrift_mps + ...
                    obj.getScalarField(obj.cfg.ekf, 'initialClockFrequencyError_mps', 0.0));

                obj.estTowerClockBias_m = towerBiasGauge_m + ...
                    obj.vectorOrScalarField(obj.cfg.ekf, ...
                    'initialTowerClockBiasError_m', 0.0, obj.numTowers);

                obj.estTowerClockDrift_mps = towerDriftGauge_mps + ...
                    obj.vectorOrScalarField(obj.cfg.ekf, ...
                    'initialTowerClockDriftError_mps', 0.0, obj.numTowers);
            else
                obj.estAsset.setNominalClockState( ...
                    obj.truthAsset.getClockBias_m() + ...
                    obj.getScalarField(obj.cfg.ekf, 'initialClockBiasError_m', 100.0), ...
                    obj.truthAsset.getClockDrift_mps() + ...
                    obj.getScalarField(obj.cfg.ekf, 'initialClockFrequencyError_mps', 0.0));
            end

            obj.numReceivers = numel(obj.truthAsset.getEnabledAntennas());
            obj.receiverNames = obj.truthAsset.receiverNames();
            obj.receiverOffsetsBody_m = obj.truthAsset.receiverOffsetsBody_m();
            obj.receiverOffsetsLocal_m = obj.receiverOffsetsBody_m;

            fprintf('\nReceiver lever arms in Body frame [m]:\n');
            for k = 1:obj.numReceivers
                fprintf('%s: [% .3f % .3f % .3f]\n', ...
                    char(obj.receiverNames(k)), obj.receiverOffsetsBody_m(:, k));
            end
        end

        function setupMeasurementModel(obj)
            obj.measurementModel = MeasurementModel( ...
                obj.cfg, ...
                obj.c, ...
                obj.towers, ...
                obj.truthAsset.getEnabledAntennas(), ...
                obj.measurementStream);
        end

        function setupEkf(obj)
            obj.idx = struct();

            obj.idx.pos = 1:3;
            obj.idx.vel = 4:6;
            obj.idx.att = 7:9;
            obj.idx.omega = 10:12;
            obj.idx.rxClockBias = 13;
            obj.idx.rxClockDrift = 14;
            obj.idx.rxClock = 13:14;

            if obj.towerClockEkfEnabled()
                obj.idx.towerClockBias = zeros(1, obj.numTowers);
                obj.idx.towerClockDrift = zeros(1, obj.numTowers);

                nextIdx = 15;
                for twr = 1:obj.numTowers
                    obj.idx.towerClockBias(twr) = nextIdx;
                    obj.idx.towerClockDrift(twr) = nextIdx + 1;
                    nextIdx = nextIdx + 2;
                end

                obj.idx.towerClock = sort([obj.idx.towerClockBias, obj.idx.towerClockDrift]);
                obj.stateDim = 14 + 2 * obj.numTowers;
            else
                obj.idx.towerClockBias = [];
                obj.idx.towerClockDrift = [];
                obj.idx.towerClock = [];
                obj.stateDim = 14;
            end

            x0 = zeros(obj.stateDim, 1);
            P0 = zeros(obj.stateDim);

            P0(obj.idx.pos, obj.idx.pos) = ...
                eye(3) * obj.cfg.ekf.initialPositionSigma_m^2;

            P0(obj.idx.vel, obj.idx.vel) = ...
                eye(3) * obj.cfg.ekf.initialVelocitySigma_mps^2;

            P0(obj.idx.att, obj.idx.att) = ...
                eye(3) * obj.getScalarField(obj.cfg.ekf, ...
                'initialAttitudeSigma_rad', ...
                deg2rad(obj.getScalarField(obj.cfg.ekf, ...
                'initialAttitudeSigma_deg', 10.0)))^2;

            P0(obj.idx.omega, obj.idx.omega) = ...
                eye(3) * obj.getScalarField(obj.cfg.ekf, ...
                'initialAngularVelocitySigma_radps', ...
                deg2rad(obj.getScalarField(obj.cfg.ekf, ...
                'initialAngularVelocitySigma_degps', 0.05)))^2;

            P0(obj.idx.rxClockBias, obj.idx.rxClockBias) = ...
                obj.cfg.ekf.initialClockBiasSigma_m^2;

            P0(obj.idx.rxClockDrift, obj.idx.rxClockDrift) = ...
                obj.cfg.ekf.initialClockFrequencySigma_mps^2;
           

            if obj.towerClockEkfEnabled()
                towerBiasSigma_m = obj.getScalarField(obj.cfg.ekf, ...
                    'initialTowerClockBiasSigma_m', ...
                    obj.cfg.ekf.initialClockBiasSigma_m);

                towerDriftSigma_mps = obj.getScalarField(obj.cfg.ekf, ...
                    'initialTowerClockDriftSigma_mps', ...
                    obj.cfg.ekf.initialClockFrequencySigma_mps);

                for twr = 1:obj.numTowers
                    P0(obj.idx.towerClockBias(twr), obj.idx.towerClockBias(twr)) = ...
                        towerBiasSigma_m^2;

                    P0(obj.idx.towerClockDrift(twr), obj.idx.towerClockDrift(twr)) = ...
                        towerDriftSigma_mps^2;
                end
            end

            P0 = obj.applyStateLocksToCovariance(P0);
            obj.initialX0 = obj.physicalEstimateVector();
            obj.initialTruth0 = obj.physicalTruthVector();
            obj.initialP0 = P0;

            obj.Q = obj.buildProcessNoise();
            obj.R = eye(obj.numReceivers * obj.numTowers) * ...
                obj.measurementModel.measurementVariance( ...
                obj.towerClockEkfEnabled(), obj.groundClockResidualVariance_m2());
            obj.ekf = ExtendedKalmanFilter(x0, P0, obj.Q, obj.R);

            obj.transitionFromInitial = eye(obj.stateDim);
            obj.observabilityNormalMatrix = zeros(obj.stateDim);
        end

        function setupHistory(obj)
            obj.history = struct();
            obj.history.x = NaN(obj.stateDim, obj.numSteps);
            obj.history.truth = NaN(obj.stateDim, obj.numSteps);
            obj.history.covariance_diag = NaN(obj.stateDim, obj.numSteps);
            obj.history.innovation_rms_m = NaN(1, obj.numSteps);
            obj.history.postfit_innovation_rms_m = NaN(1, obj.numSteps);
            obj.history.nis_history = NaN(1, obj.numSteps);
            obj.history.covariance_condition_number = NaN(1, obj.numSteps);
            obj.history.innovation_condition_number = NaN(1, obj.numSteps);
            obj.history.H_row_count_history = NaN(1, obj.numSteps);
            obj.history.H_column_count_history = NaN(1, obj.numSteps);
            obj.history.H_rank_to_state_dim_history = NaN(1, obj.numSteps);
            obj.history.H_state_deficiency_history = NaN(1, obj.numSteps);
            
            obj.history.H_pos_rank_history = NaN(1, obj.numSteps);
            obj.history.H_att_rank_history = NaN(1, obj.numSteps);
            obj.history.H_pos_att_clock_rank_history = NaN(1, obj.numSteps);
            obj.history.H_pos_column_norm_history = NaN(3, obj.numSteps);
            obj.history.H_att_column_norm_history = NaN(3, obj.numSteps);
            obj.history.H_rx_clock_bias_column_norm_history = NaN(1, obj.numSteps);
            
            obj.history.measurement_count = zeros(1, obj.numSteps);
            obj.history.pseudorange_measurement_count = zeros(1, obj.numSteps);
            obj.history.visible_tower_count = zeros(1, obj.numSteps);
            obj.history.sat_pos_history_m = NaN(3, obj.numSteps);
            obj.history.receiver_eci_by_receiver = NaN(3, obj.numReceivers, obj.numSteps);
            obj.history.tower_eci_by_tower = NaN(3, obj.numTowers, obj.numSteps);
            obj.history.ground_clock_true_m = NaN(obj.numTowers, obj.numSteps);
            obj.history.ground_clock_correction_m = NaN(obj.numTowers, obj.numSteps);
            obj.history.ground_clock_residual_m = NaN(obj.numTowers, obj.numSteps);
            obj.history.clock_phase_history_s = NaN(1, obj.numSteps);
            obj.history.prefit_residual_by_receiver_tower_m = NaN(obj.numReceivers, obj.numTowers, obj.numSteps);
            obj.history.postfit_residual_by_receiver_tower_m = NaN(obj.numReceivers, obj.numTowers, obj.numSteps);
            obj.history.pseudorange_by_receiver_tower_m = NaN(obj.numReceivers, obj.numTowers, obj.numSteps);
            obj.history.true_range_by_receiver_tower_m = NaN(obj.numReceivers, obj.numTowers, obj.numSteps);
            obj.history.los_unit_eci_by_receiver_tower = NaN(3, obj.numReceivers, obj.numTowers, obj.numSteps);
            obj.history.visibility_mask_by_receiver_tower = false(obj.numReceivers, obj.numTowers, obj.numSteps);
            obj.history.elevation_deg_by_receiver_tower = NaN(obj.numReceivers, obj.numTowers, obj.numSteps);
            
            obj.outputDir = string(fullfile(char(obj.scriptDir), "reports", char(obj.entryPointName), char(obj.scenarioName)));
            
        end

        %%
        function step(obj, k)
            if k > 1
                obj.propagateTruth();
                obj.propagateNominalEstimate();

                F = obj.buildStateTransition();
                obj.ekf.predict(zeros(obj.stateDim, 1), F, obj.Q);
                obj.ekf.P = obj.applyStateLocksToCovariance(obj.ekf.P);
                obj.transitionFromInitial = F * obj.transitionFromInitial;
            end

            jd = obj.jd0 + obj.time_s(k) / 86400.0;
            towersEci = obj.towerPositionsEci(jd);

            [groundResidual_m, groundTrue_m, groundCorrection_m] = obj.groundClockResidual_m();

            groundResidualTruth_m = groundResidual_m;
            groundResidualModel_m = zeros(obj.numTowers, 1);

            [yRange, Rrange, trueRangeRt, losRt, receiverEci, visibilityMask, elevationRt_deg] = ...
                obj.measurementModel.makePseudoranges( ...
                jd, towersEci, groundResidualTruth_m, ...
                obj.truthAsset, ...
                obj.towerClockEkfEnabled(), obj.groundClockResidualVariance_m2());

            [ypRange, Hrange] = ...
                obj.measurementModel.predictPseudorangesWithJacobian( ...
                towersEci, groundResidualModel_m, visibilityMask, ...
                obj.estAsset, obj.estTowerClockBias_m, ...
                obj.idx, obj.stateDim, obj.towerClockEkfEnabled());

            innovationRange = yRange - ypRange;

            [yUpdate, ypUpdate, Hupdate, Rupdate] = ...
                obj.measurementModel.appendTowerClockGaugeConstraint( ...
                yRange, ypRange, Hrange, Rrange, ...
                obj.estTowerClockBias_m, obj.estTowerClockDrift_mps, ...
                obj.idx, obj.stateDim, obj.towerClockEkfEnabled(), obj.cfg.ekf);

            S = Hupdate * obj.ekf.P * Hupdate' + Rupdate;

            if isempty(yUpdate)
                nisValue = NaN;
            else
                [~, nisValue] = obj.ekf.update(yUpdate, ypUpdate, Hupdate, Rupdate);
            end

            obj.injectErrorState(obj.ekf.X);
            obj.ekf.X(:) = 0.0;

            obj.ekf.P = obj.applyCovarianceFloor(obj.ekf.P);
            obj.ekf.P = obj.applyStateLocksToCovariance(obj.ekf.P);

            [ypPostRange, ~] = ...
                obj.measurementModel.predictPseudorangesWithJacobian( ...
                towersEci, groundResidualModel_m, visibilityMask, ...
                obj.estAsset, obj.estTowerClockBias_m, ...
                obj.idx, obj.stateDim, obj.towerClockEkfEnabled());

            postfitRange = yRange - ypPostRange;

            obj.recordHistory(k, yRange, innovationRange, postfitRange, S, Hupdate, ...
                nisValue, trueRangeRt, losRt, ...
                receiverEci, towersEci, groundResidualTruth_m, groundTrue_m, ...
                groundCorrection_m, visibilityMask, elevationRt_deg);
        end

        function recordHistory(obj, k, y, innovation, postfit, S, H, ...
                nisValue, trueRangeRt, losRt, receiverEci, towersEci, ...
                groundResidual_m, groundTrue_m, groundCorrection_m, ...
                visibilityMask, elevationRt_deg)

            obj.history.x(:, k) = obj.physicalEstimateVector();
            obj.history.truth(:, k) = obj.physicalTruthVector();
            obj.history.covariance_diag(:, k) = diag(obj.ekf.P);
            obj.history.innovation_rms_m(k) = obj.computeRms(innovation);
            obj.history.postfit_innovation_rms_m(k) = obj.computeRms(postfit);
            obj.history.nis_history(k) = nisValue;
            obj.history.covariance_condition_number(k) = cond(obj.ekf.P);
            if isempty(S)
                obj.history.innovation_condition_number(k) = NaN;
            else
                obj.history.innovation_condition_number(k) = cond(S);
            end
            
            if isempty(H)
                hRank = 0;
                hRows = 0;
                hCols = obj.stateDim;
            else
                hRank = rank(H);
                hRows = size(H, 1);
                hCols = size(H, 2);
            end
            
            obj.history.H_rank_history(k) = hRank;
            obj.history.H_row_count_history(k) = hRows;
            obj.history.H_column_count_history(k) = hCols;
            obj.history.H_rank_to_state_dim_history(k) = hRank / max(hCols, 1);
            obj.history.H_state_deficiency_history(k) = hCols - hRank;
            
            if isempty(H)
                obj.history.H_pos_rank_history(k) = 0;
                obj.history.H_att_rank_history(k) = 0;
                obj.history.H_pos_att_clock_rank_history(k) = 0;
                obj.history.H_pos_column_norm_history(:, k) = 0;
                obj.history.H_att_column_norm_history(:, k) = 0;
                obj.history.H_rx_clock_bias_column_norm_history(k) = 0;
            else
                Hpos = H(:, obj.idx.pos);
                Hatt = H(:, obj.idx.att);
                Hclk = H(:, obj.idx.rxClockBias);
            
                obj.history.H_pos_rank_history(k) = rank(Hpos);
                obj.history.H_att_rank_history(k) = rank(Hatt);
                obj.history.H_pos_att_clock_rank_history(k) = rank([Hpos, Hatt, Hclk]);
            
                obj.history.H_pos_column_norm_history(:, k) = vecnorm(Hpos, 2, 1).';
                obj.history.H_att_column_norm_history(:, k) = vecnorm(Hatt, 2, 1).';
                obj.history.H_rx_clock_bias_column_norm_history(k) = norm(Hclk);
            end

            obj.observabilityNormalMatrix = obj.observabilityNormalMatrix + (H * obj.transitionFromInitial).' * (H * obj.transitionFromInitial);
            obj.history.measurement_count(k) = size(H, 1);
            obj.history.pseudorange_measurement_count(k) = numel(y);
            obj.history.visible_tower_count(k) = sum(any(visibilityMask, 1));
            obj.history.sat_pos_history_m(:, k) = obj.truthAsset.pos_ECI_m;
            obj.history.receiver_eci_by_receiver(:, :, k) = receiverEci;
            obj.history.tower_eci_by_tower(:, :, k) = towersEci;
            obj.history.ground_clock_true_m(:, k) = groundTrue_m(:);
            obj.history.ground_clock_correction_m(:, k) = groundCorrection_m(:);
            obj.history.ground_clock_residual_m(:, k) = groundResidual_m(:);
            obj.history.clock_phase_history_s(k) = obj.truthAsset.clock.total_bias_sec;
            obj.history.prefit_residual_by_receiver_tower_m(:, :, k) = ...
                obj.measurementModel.vectorToReceiverTowerMatrix(innovation, visibilityMask);
            
            obj.history.postfit_residual_by_receiver_tower_m(:, :, k) = ...
                obj.measurementModel.vectorToReceiverTowerMatrix(postfit, visibilityMask);
            
            obj.history.pseudorange_by_receiver_tower_m(:, :, k) = ...
                obj.measurementModel.vectorToReceiverTowerMatrix(y, visibilityMask);
            obj.history.true_range_by_receiver_tower_m(:, :, k) = trueRangeRt;
            obj.history.los_unit_eci_by_receiver_tower(:, :, :, k) = losRt;
            obj.history.visibility_mask_by_receiver_tower(:, :, k) = visibilityMask;
            obj.history.elevation_deg_by_receiver_tower(:, :, k) = elevationRt_deg;
        end

        function buildResults(obj)
            obj.results = struct();
            obj.results.time_s = obj.time_s;
            obj.results.state_est = obj.history.x;
            obj.results.state_truth = obj.history.truth;
            obj.results.covariance_diag = obj.history.covariance_diag;
            obj.results.innovation_rms_m = obj.history.innovation_rms_m;
            obj.results.postfit_innovation_rms_m = obj.history.postfit_innovation_rms_m;
            obj.results.nis_history = obj.history.nis_history;
            obj.results.H_rank_history = obj.history.H_rank_history;
            obj.results.receiver_names = obj.receiverNames;
            obj.results.receiver_offsets_body_m = obj.receiverOffsetsBody_m;
            obj.results.num_receivers = obj.numReceivers;
            obj.results.scenario_name = obj.scenarioName;
            obj.results.state_names = obj.stateNames();
            obj.results.observability = obj.observabilityDiagnostics();
            obj.results.ground_clock_true_m = obj.history.ground_clock_true_m;
            obj.results.ground_clock_correction_m = obj.history.ground_clock_correction_m;
            obj.results.ground_clock_residual_m = obj.history.ground_clock_residual_m;
            obj.results.clock_bias_truth_m = obj.history.truth(obj.idx.rxClockBias, :);
            obj.results.clock_bias_est_m = obj.history.x(obj.idx.rxClockBias, :);
            obj.results.pseudorange_by_receiver_tower_m = obj.history.pseudorange_by_receiver_tower_m;
            obj.results.true_range_by_receiver_tower_m = obj.history.true_range_by_receiver_tower_m;
            obj.results.enableTowerClockEKF = obj.towerClockEkfEnabled();

            if obj.towerClockEkfEnabled()
                obj.results.tower_clock_bias_est_m = obj.history.x(obj.idx.towerClockBias, :);
                obj.results.tower_clock_bias_truth_m = obj.history.truth(obj.idx.towerClockBias, :);
                obj.results.tower_clock_drift_est_mps = obj.history.x(obj.idx.towerClockDrift, :);
                obj.results.tower_clock_drift_truth_mps = obj.history.truth(obj.idx.towerClockDrift, :);
            end
        end

        function reportData = buildGenerateReportData(obj)
            reportData = ReportDataBuilder.fromSimulation(obj);
        end

        function reportToggles = buildReportToggles(obj)
            reportToggles = struct();

            reportToggles.generatePdf = true;
            reportToggles.groundSegment = true;
            reportToggles.perfectGroundClocks = ~obj.groundClockErrorsEnabled();
            reportToggles.groundClockError = obj.groundClockErrorsEnabled();
            reportToggles.groundTimingNetworkCorrection = obj.groundClockCorrectionEnabled();
            reportToggles.towerClocksEstimatedInEkf = obj.towerClockEkfEnabled();

            reportToggles.satelliteClockError = true;
            reportToggles.ekfOrbitClockEstimation = true;
            reportToggles.measurementNoise = obj.measurementModel.measurementNoiseEnabled();

            reportToggles.allanDeviationValidation = logical(obj.getFieldOrDefault( ...
                obj.cfg.report, 'enableAllanDeviationValidation', true));

            reportToggles.ionosphere = logical(obj.cfg.measurement.enableIonosphereDelay);
            reportToggles.troposphere = logical(obj.cfg.measurement.enableTroposphereDelay);
            reportToggles.multipath = logical(obj.cfg.measurement.enableMultipathDelay);
            reportToggles.antennaBias = logical(obj.cfg.measurement.enableAntennaDelay);
            reportToggles.hardwareDelay = logical(obj.cfg.measurement.enableHardwareDelay);
        end
        
        function reportConfig = buildReportConfig(obj)
            reportConfig = struct();

            reportConfig.title = 'Reverse-GNSS Spacecraft Code-Pseudorange EKF Report';
            reportConfig.scenarioName = char(obj.scenarioName);
            reportConfig.selectedOscillatorName = string(obj.assetConfig.clock.clockType);
            reportConfig.reportRoot = char(obj.outputDir);
            reportConfig.outputBaseName = sprintf('%s_report', char(obj.scenarioName));

            reportConfig.compilePdf = logical(obj.getFieldOrDefault( ...
                obj.cfg.report, 'compilePdf', true));

            reportConfig.interactivePlots = logical(obj.getFieldOrDefault( ...
                obj.cfg.report, 'interactivePlots', false));

            reportConfig.closeFiguresAfterExport = ~reportConfig.interactivePlots;
            reportConfig.generatedBy = char(obj.entryPointName);
        end
        
        function F = buildStateTransition(obj)
            F = eye(obj.stateDim);
            dtLocal = obj.dt;
        
            phiRv = SpaceAsset.twoBodyPhiFirstOrder(obj.estAsset.state_ECI, obj.mu, dtLocal);
            rvIdx = [obj.idx.pos obj.idx.vel];
            F(rvIdx, rvIdx) = phiRv;
            F(obj.idx.att, obj.idx.omega) = eye(3) * dtLocal;
        
            [clockPhi, ~] = obj.clockBiasDriftMatrices(dtLocal);
            F(obj.idx.rxClock, obj.idx.rxClock) = clockPhi;
            if obj.towerClockEkfEnabled()
                for twr = 1:obj.numTowers
                    [towerPhi, ~] = obj.towerClockBiasDriftMatrices(twr, dtLocal);
                    idxPair = [obj.idx.towerClockBias(twr), obj.idx.towerClockDrift(twr)];
                    F(idxPair, idxPair) = towerPhi;
                end
            end
            F = obj.applyStateLocksToTransition(F);
        end

        function Q = buildProcessNoise(obj)
            Q = zeros(obj.stateDim);
            dtLocal = obj.dt;
            qAcc = obj.getScalarField(obj.cfg.process, 'eciAccelerationPsd_m2ps3', obj.getScalarField(obj.cfg.process, 'localAccelerationPsd_m2ps3', 1e-6));
            qBlock = qAcc .* [dtLocal^3/3, dtLocal^2/2; dtLocal^2/2, dtLocal];
            for axis = 1:3
                idxPair = [obj.idx.pos(axis), obj.idx.vel(axis)];
                Q(idxPair, idxPair) = qBlock;
            end
            qOmega = obj.getScalarField(obj.cfg.process, 'attitudeAngularAccelerationPsd_rad2ps3', deg2rad(1e-4)^2);
            qAttBlock = qOmega .* [dtLocal^3/3, dtLocal^2/2; dtLocal^2/2, dtLocal];
            for axis = 1:3
                idxPair = [obj.idx.att(axis), obj.idx.omega(axis)];
                Q(idxPair, idxPair) = qAttBlock;
            end
           
            [~, qClockBlock] = obj.clockBiasDriftMatrices(dtLocal);
            Q(obj.idx.rxClock, obj.idx.rxClock) = qClockBlock;
            if obj.towerClockEkfEnabled()
                for twr = 1:obj.numTowers
                    [~, qTowerClockBlock] = obj.towerClockBiasDriftMatrices(twr, dtLocal);
                    idxPair = [obj.idx.towerClockBias(twr), obj.idx.towerClockDrift(twr)];
                    Q(idxPair, idxPair) = qTowerClockBlock;
                end
            end   
            Q = 0.5 * (Q + Q');
            Q = obj.applyStateLocksToProcessNoise(Q);
        end

        function [clockPhi, clockQ] = clockBiasDriftMatrices(obj, dtLocal)
            osc = obj.simConfig.clockLibrary.(char(obj.assetConfig.clock.clockType));
        
            clockModel = string(obj.getFieldOrDefault(obj.cfg.process, ...
                'clockModel', "brownHwang"));
        
            clockCorrelationTime_s = obj.getScalarField(obj.cfg.process, ...
                'clockCorrelationTime_s', 3600.0);
        
            [clockPhi, clockQ] = Clock.aggregateBiasDriftModel( ...
                osc.h0, osc.hm1, osc.hm2, dtLocal, obj.c, ...
                clockModel, clockCorrelationTime_s);
        end

        function [clockPhi, clockQ] = towerClockBiasDriftMatrices(obj, towerIndex, dtLocal)
            tc = obj.activeTowerConfig(towerIndex);

            clockType = char(obj.getTowerField(tc, ...
                'clockType', obj.assetConfig.clock.clockType));

            if ~isfield(obj.simConfig.clockLibrary, clockType)
                clockType = char(obj.assetConfig.clock.clockType);
            end

            osc = obj.simConfig.clockLibrary.(clockType);

            clockModel = string(obj.getFieldOrDefault(obj.cfg.process, ...
                'towerClockModel', ...
                obj.getFieldOrDefault(obj.cfg.process, 'clockModel', "brownHwang")));

            clockCorrelationTime_s = obj.getScalarField(obj.cfg.process, ...
                'towerClockCorrelationTime_s', ...
                obj.getScalarField(obj.cfg.process, 'clockCorrelationTime_s', 3600.0));

            [clockPhi, clockQ] = Clock.aggregateBiasDriftModel( ...
                osc.h0, osc.hm1, osc.hm2, dtLocal, obj.c, ...
                clockModel, clockCorrelationTime_s);
        end

        function propagateTruth(obj)
            obj.truthAsset.propagateTruth(obj.mu, obj.dt);

            for twr = 1:obj.numTowers
                obj.towers{twr}.updateClock(obj.dt);
            end
        end

        function propagateNominalEstimate(obj)
            [clockPhi, ~] = obj.clockBiasDriftMatrices(obj.dt);
            obj.estAsset.propagateNominal(obj.mu, obj.dt, clockPhi);

            if obj.towerClockEkfEnabled()
                for twr = 1:obj.numTowers
                    [towerPhi, ~] = obj.towerClockBiasDriftMatrices(twr, obj.dt);

                    towerClockState = towerPhi * [ ...
                        obj.estTowerClockBias_m(twr); ...
                        obj.estTowerClockDrift_mps(twr)];

                    obj.estTowerClockBias_m(twr) = towerClockState(1);
                    obj.estTowerClockDrift_mps(twr) = towerClockState(2);
                end
            end
        end

        function injectErrorState(obj, dx)
            dx = dx(:);

            lockedIdx = obj.lockedStateIndices();
            if ~isempty(lockedIdx)
                dx(lockedIdx) = 0.0;
            end

            obj.estAsset.injectErrorState(dx, obj.idx);

            if obj.towerClockEkfEnabled()
                for twr = 1:obj.numTowers
                    obj.estTowerClockBias_m(twr) = ...
                        obj.estTowerClockBias_m(twr) + dx(obj.idx.towerClockBias(twr));

                    obj.estTowerClockDrift_mps(twr) = ...
                        obj.estTowerClockDrift_mps(twr) + dx(obj.idx.towerClockDrift(twr));
                end
            end
        end
        
        function P = applyCovarianceFloor(obj, P)
            floorVal = obj.getScalarField(obj.cfg.ekf, 'covarianceFloor', 0.0);
            P = 0.5 * (P + P');
            if floorVal > 0
                d = max(diag(P), floorVal);
                P(1:obj.stateDim+1:end) = d;
            end
            P = 0.5 * (P + P');
        end

        function towersEci = towerPositionsEci(obj, jd)
            towersEci = GroundNode.positionsECI(obj.towers, jd);
        end

        function [residual_m, trueBias_m, correction_m] = groundClockResidual_m(obj)
            residual_m = zeros(obj.numTowers, 1);
            trueBias_m = zeros(obj.numTowers, 1);
            correction_m = zeros(obj.numTowers, 1);
        
            if ~obj.groundClockErrorsEnabled()
                return;
            end

            if obj.groundClockErrorsEnabled() && ...
                    ~obj.groundClockCorrectionEnabled() && ...
                    ~obj.towerClockEkfEnabled()
                error('ReverseGnssSimulation:UnmodelledTowerClockResidual', ...
                    ['Ground clock errors are enabled, but tower clocks are neither externally corrected ', ...
                     'nor estimated. This makes transmitter clock residuals unmodelled pseudorange biases. ', ...
                     'Enable ground clock correction or explicitly run a separate ground-network timing estimator.']);
            end
        
            for k = 1:obj.numTowers
                trueBias_m(k) = obj.towers{k}.clockBias_m();
        
                if obj.groundClockCorrectionEnabled()
                    correction_m(k) = trueBias_m(k);
        
                    if obj.groundClockCorrectionNoiseEnabled()
                        correction_m(k) = correction_m(k) + ...
                            obj.groundClockCorrectionSigma_m() * randn(obj.measurementStream);
                    end
                end
        
                residual_m(k) = trueBias_m(k) - correction_m(k);
            end
        end

        function tf = groundClockErrorsEnabled(obj)
            tf = logical(obj.getFieldOrDefault(obj.cfg, 'enableGroundClockErrors', false));
        end

        function tf = groundClockCorrectionEnabled(obj)
            tf = logical(obj.getFieldOrDefault(obj.cfg, 'enableGroundClockCorrection', true));
        end

        function tf = groundClockCorrectionNoiseEnabled(obj)
            tf = logical(obj.getFieldOrDefault(obj.cfg, 'enableGroundClockCorrectionNoise', false));
        end
        
        function applyTowerClockEkfConfiguration(obj)
            if ~obj.towerClockEkfEnabled()
                return;
            end

            if obj.towerClockEkfEnabled() && ...
                    logical(obj.getFieldOrDefault(obj.cfg, 'spacecraftNavigationFilterOnly', true))
                error('ReverseGnssSimulation:TowerClockStatesNotSpacecraftStates', ...
                    ['enableTowerClockEKF=true adds ground-network clock states to the spacecraft navigation filter. ', ...
                     'For this architecture, tower clocks must be supplied as external measurement corrections ', ...
                     'or estimated in a separate ground timing-network filter.']);
            end

            if ~obj.groundClockErrorsEnabled()
                warning('ReverseGnssSimulation:TowerClockEKFEnablesGroundClocks', ...
                    ['enableTowerClockEKF=true requires physical tower clock errors. ', ...
                     'Setting enableGroundClockErrors=true.']);
                obj.cfg.enableGroundClockErrors = true;
            end

            if obj.groundClockCorrectionEnabled()
                warning('ReverseGnssSimulation:TowerClockEKFDisablesExternalCorrection', ...
                    ['enableTowerClockEKF=true estimates tower clocks inside the EKF. ', ...
                     'Disabling external ground clock correction to avoid double correction.']);
                obj.cfg.enableGroundClockCorrection = false;
                obj.cfg.enableGroundClockCorrectionNoise = false;
            end
        end

        function sigma_m = groundClockCorrectionSigma_m(obj)
            sigma_ps = obj.getScalarField(obj.cfg, 'groundClockCorrectionSigma_ps', obj.getScalarField(obj.cfg, 'externalClockCorrectionSigma_ps', 0.0));
            sigma_m = obj.c * sigma_ps * 1e-12;
        end

        function var_m2 = groundClockResidualVariance_m2(obj)
            if obj.groundClockErrorsEnabled() && obj.groundClockCorrectionEnabled() && obj.groundClockCorrectionNoiseEnabled()
                var_m2 = obj.groundClockCorrectionSigma_m()^2;
            else
                var_m2 = 0.0;
            end
        end

        function clk = makeTowerClock(obj, tc, towerIndex)
            clockType = char(obj.getTowerField(tc, 'clockType', obj.assetConfig.clock.clockType));
            if ~isfield(obj.simConfig.clockLibrary, clockType)
                clockType = char(obj.assetConfig.clock.clockType);
            end
            osc = obj.simConfig.clockLibrary.(clockType);
            clk = Clock(osc.h0, osc.hm1, osc.hm2, obj.dt);
            clk.randomStream = RandStream('mt19937ar', 'Seed', double(obj.seedConfig.towerClocks) + towerIndex);
            bias_m = double(obj.getTowerField(tc, 'initialClockBias_m', 0.0));
            drift_mps = double(obj.getTowerField(tc, 'initialClockDrift_mps', 0.0));
            clk.reset([bias_m / obj.c; drift_mps / obj.c; 0.0; 0.0]);
        end

        function [biasGauge_m, driftGauge_mps, meanBias_m, meanDrift_mps] = towerClockTruthGaugeVectors(obj)
            biasAbs_m = zeros(obj.numTowers, 1);
            driftAbs_mps = zeros(obj.numTowers, 1);

            for twr = 1:obj.numTowers
                if obj.groundClockErrorsEnabled()
                    biasAbs_m(twr) = obj.towers{twr}.clockBias_m();
                    driftAbs_mps(twr) = obj.towers{twr}.clockDrift_mps();
                end
            end

            meanBias_m = mean(biasAbs_m);
            meanDrift_mps = mean(driftAbs_mps);

            biasGauge_m = biasAbs_m - meanBias_m;
            driftGauge_mps = driftAbs_mps - meanDrift_mps;
        end        
        
        function tf = towerClockEkfEnabled(obj)
            tf = logical(obj.getFieldOrDefault(obj.cfg, 'enableTowerClockEKF', false));
        end
        
        function tf = freezeNavigationStates(obj)
            tf = logical(obj.getFieldOrDefault(obj.cfg.ekf, ...
                'freezeNavigationStates', false));
        end

        function idxLocked = lockedStateIndices(obj)
            idxLocked = [];
        
            if obj.freezeNavigationStates()
                idxLocked = [idxLocked, obj.idx.pos, obj.idx.vel, obj.idx.att, obj.idx.omega];
            else
                if ~obj.estimateStateGroup('estimatePosition', true)
                    idxLocked = [idxLocked, obj.idx.pos];
                end
        
                if ~obj.estimateStateGroup('estimateVelocity', true)
                    idxLocked = [idxLocked, obj.idx.vel];
                end
        
                if ~obj.estimateStateGroup('estimateAttitude', true)
                    idxLocked = [idxLocked, obj.idx.att];
                end
        
                if ~obj.estimateStateGroup('estimateAngularRate', true)
                    idxLocked = [idxLocked, obj.idx.omega];
                end
            end
        
            if ~obj.estimateStateGroup('estimateReceiverClockBias', true)
                idxLocked = [idxLocked, obj.idx.rxClockBias];
            end
        
            if ~obj.estimateStateGroup('estimateReceiverClockDrift', true)
                idxLocked = [idxLocked, obj.idx.rxClockDrift];
            end
        
            if obj.towerClockEkfEnabled()
                if ~obj.estimateStateGroup('estimateTowerClockBias', true)
                    idxLocked = [idxLocked, obj.idx.towerClockBias];
                end
        
                if ~obj.estimateStateGroup('estimateTowerClockDrift', true)
                    idxLocked = [idxLocked, obj.idx.towerClockDrift];
                end
            end
        
            idxLocked = unique(idxLocked(:).');
            idxLocked = idxLocked(idxLocked >= 1 & idxLocked <= obj.stateDim);
        end
        
        function tf = estimateStateGroup(obj, fieldName, defaultValue)
            tf = logical(obj.getFieldOrDefault(obj.cfg.ekf, fieldName, defaultValue));
        end
        
        function lockedVar = lockedStateVariance(obj)
            lockedVar = obj.getScalarField(obj.cfg.ekf, 'lockedStateVariance', 1e-24);
        end
        
        function P = applyStateLocksToCovariance(obj, P)
            lockedIdx = obj.lockedStateIndices();
        
            P = 0.5 * (P + P');
        
            if isempty(lockedIdx)
                return;
            end
        
            lockedVar = obj.lockedStateVariance();
            
            P(lockedIdx, :) = 0.0;
            P(:, lockedIdx) = 0.0;
            P(sub2ind(size(P), lockedIdx, lockedIdx)) = lockedVar;
        
            P = 0.5 * (P + P');
        end
        
        function Q = applyStateLocksToProcessNoise(obj, Q)
            lockedIdx = obj.lockedStateIndices();
        
            Q = 0.5 * (Q + Q');
        
            if isempty(lockedIdx)
                return;
            end
        
            Q(lockedIdx, :) = 0.0;
            Q(:, lockedIdx) = 0.0;
        
            Q = 0.5 * (Q + Q');
        end
        
        function F = applyStateLocksToTransition(obj, F)
            lockedIdx = obj.lockedStateIndices();
        
            if isempty(lockedIdx)
                return;
            end
        
            F(lockedIdx, :) = 0.0;
            F(:, lockedIdx) = 0.0;
        
            for kk = lockedIdx
                F(kk, kk) = 1.0;
            end
        end
        
        function x = physicalEstimateVector(obj)
            x = zeros(obj.stateDim, 1);

            x(obj.idx.pos) = obj.estAsset.pos_ECI_m;
            x(obj.idx.vel) = obj.estAsset.vel_ECI_mps;
            x(obj.idx.att) = FrameGeometry.dcmToEuler321(obj.estAsset.C_BI);
            x(obj.idx.omega) = obj.estAsset.omega_B_radps;
            x(obj.idx.rxClockBias) = obj.estAsset.getClockBias_m();
            x(obj.idx.rxClockDrift) = obj.estAsset.getClockDrift_mps();

            if obj.towerClockEkfEnabled()
                x(obj.idx.towerClockBias) = obj.estTowerClockBias_m;
                x(obj.idx.towerClockDrift) = obj.estTowerClockDrift_mps;
            end
        end

        function x = physicalTruthVector(obj)
            x = zeros(obj.stateDim, 1);

            x(obj.idx.pos) = obj.truthAsset.pos_ECI_m;
            x(obj.idx.vel) = obj.truthAsset.vel_ECI_mps;
            x(obj.idx.att) = FrameGeometry.dcmToEuler321(obj.truthAsset.C_BI);
            x(obj.idx.omega) = obj.truthAsset.omega_B_radps;

            if obj.towerClockEkfEnabled()
                [towerBiasGauge_m, towerDriftGauge_mps, meanTowerBias_m, meanTowerDrift_mps] = ...
                    obj.towerClockTruthGaugeVectors();

                x(obj.idx.rxClockBias) = obj.truthAsset.getClockBias_m() - meanTowerBias_m;
                x(obj.idx.rxClockDrift) = obj.truthAsset.getClockDrift_mps() - meanTowerDrift_mps;
                x(obj.idx.towerClockBias) = towerBiasGauge_m;
                x(obj.idx.towerClockDrift) = towerDriftGauge_mps;
            else
                x(obj.idx.rxClockBias) = obj.truthAsset.getClockBias_m();
                x(obj.idx.rxClockDrift) = obj.truthAsset.getClockDrift_mps();
            end
        end

        function names = stateNames(obj)
            names = ["ECI X position [m]"; "ECI Y position [m]"; "ECI Z position [m]"; ...
                "ECI X velocity [m/s]"; "ECI Y velocity [m/s]"; "ECI Z velocity [m/s]"; ...
                "Body attitude error x [rad]"; "Body attitude error y [rad]"; "Body attitude error z [rad]"; ...
                "Body omega x [rad/s]"; "Body omega y [rad/s]"; "Body omega z [rad/s]"; ...
                "RX clock bias relative to ground clock gauge [m]"; ...
                "RX clock drift relative to ground clock gauge [m/s]"];

            if obj.towerClockEkfEnabled()
                for twr = 1:obj.numTowers
                    names(end + 1, 1) = sprintf('%s clock bias relative to mean ground clock [m]', obj.towerNames(twr));
                    names(end + 1, 1) = sprintf('%s clock drift relative to mean ground clock [m/s]', obj.towerNames(twr));
                end
            end
        end

        function towers = reportTowers(obj)
            towers = repmat(struct('name', '', 'lat_deg', 0, 'lon_deg', 0, 'alt_m', 0, 'enabled', true), 1, obj.numTowers);
            for k = 1:obj.numTowers
                towers(k).name = char(obj.towerNames(k));
                towers(k).lat_deg = obj.activeTowerConfig(k).lat_deg;
                towers(k).lon_deg = obj.activeTowerConfig(k).lon_deg;
                towers(k).alt_m = obj.activeTowerConfig(k).alt_m;
                towers(k).enabled = true;
            end
        end

        function tauOut = validTauForSamples(~, tauIn, dt, n)
            m = unique(round(tauIn(:).' ./ dt));
            m = m(isfinite(m) & m >= 1 & 2 .* m < n);
            tauOut = m .* dt;
            if isempty(tauOut), tauOut = dt; end
        end
 
        function [tauValid_s, adev, adevSigma, edf] = runClockAllanValidation(obj, clockTemplate, tauRequested_s, dt, nSamples)
            nSamples = max(3, floor(double(nSamples)));
            tauValid_s = obj.validTauForSamples(tauRequested_s, dt, nSamples);
            validationClock = Clock(clockTemplate.h_0, clockTemplate.h_minus_1, clockTemplate.h_minus_2, dt);
            validationClock.randomStream = obj.validationClockStream;
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
                [adev(k), ~, edf(k), adevSigma(k)] = Clock.computeOverlappingAllanDeviation(phase_s, tauValid_s(k), dt);
            end
        end

        function obs = observabilityDiagnostics(obj)
            W = 0.5 * (obj.observabilityNormalMatrix + obj.observabilityNormalMatrix.');
            columnNorm = sqrt(max(diag(W), 0));
            scale = columnNorm; scale(scale == 0) = Inf;
            Wn = W ./ (scale * scale.'); Wn(~isfinite(Wn)) = 0.0;
            s = svd(Wn);
            weak = columnNorm < max(columnNorm) * 1e-8;
            names = obj.stateNames();
            obs = struct('rank', sum(s > 1e-8), 'normalizedSingularValues', s, ...
                'columnNorm', columnNorm, 'weak', weak, 'weakStateNames', names(weak));
        end

        function value = getFieldOrDefault(~, s, fieldName, defaultValue)
            if isstruct(s) && isfield(s, fieldName), value = s.(fieldName); else, value = defaultValue; end
        end

        function value = getScalarField(~, s, fieldName, defaultValue)
            if isstruct(s) && isfield(s, fieldName) && ~isempty(s.(fieldName)), value = double(s.(fieldName)); else, value = double(defaultValue); end
        end

        function value = getTowerField(~, towerStruct, fieldName, defaultValue)
            if isstruct(towerStruct) && isfield(towerStruct, fieldName), value = towerStruct.(fieldName); else, value = defaultValue; end
        end

        function vec = vectorFieldOrDefault(~, s, fieldName, defaultValue, n)
            if isstruct(s) && isfield(s, fieldName) && ~isempty(s.(fieldName))
                raw = s.(fieldName);
                vec = double(raw(:));
            else
                vec = double(defaultValue(:));
            end
            if numel(vec) < n, vec(end+1:n, 1) = 0.0; end
            vec = vec(1:n);
        end

        function vec = vectorOrScalarField(~, s, fieldName, defaultValue, n)
            if isstruct(s) && isfield(s, fieldName) && ~isempty(s.(fieldName))
                raw = double(s.(fieldName));
            else
                raw = double(defaultValue);
            end

            if isscalar(raw)
                vec = repmat(raw, n, 1);
            else
                vec = raw(:);
                if numel(vec) < n
                    vec(end+1:n, 1) = 0.0;
                end
                vec = vec(1:n);
            end
        end

        function att = getAttitudeVectorFromConfig(~, s, baseName, defaultRad)
            att = defaultRad(:); degField = [char(baseName) '_deg']; radField = [char(baseName) '_rad'];
            if isstruct(s) && isfield(s, radField)
                raw = s.(radField);
                att = double(raw(:));
            elseif isstruct(s) && isfield(s, degField)
                raw = s.(degField);
                att = deg2rad(double(raw(:)));
            end
            if numel(att) < 3, att(end+1:3, 1) = 0.0; end
            att = att(1:3);
        end

        function rate = getRateVectorFromConfig(~, s, baseName, defaultRadps)
            rate = defaultRadps(:); degField = [char(baseName) '_degps']; radField = [char(baseName) '_radps'];
            if isstruct(s) && isfield(s, radField)
                raw = s.(radField);
                rate = double(raw(:));
            elseif isstruct(s) && isfield(s, degField)
                raw = s.(degField);
                rate = deg2rad(double(raw(:)));
            end
            if numel(rate) < 3, rate(end+1:3, 1) = 0.0; end
            rate = rate(1:3);
        end

        function q = getQuaternionFromConfig(obj, s, baseName, defaultQ)
            q = defaultQ(:);
            qField = [char(baseName) '_q_BI'];
            if isstruct(s) && isfield(s, qField)
                raw = s.(qField);
                q = double(raw(:));
            else
                eul = obj.getAttitudeVectorFromConfig(s, [char(baseName) 'Euler321'], zeros(3, 1));
                if any(eul ~= 0), q = FrameGeometry.dcmToQuat(SpaceAsset.euler321(eul)); end
            end
            q = FrameGeometry.normalizeQuat(q);
        end

        function value = computeRms(~, x)
            x = x(:);
            value = sqrt(mean(x.^2, 'omitnan'));
        end

    end
end
