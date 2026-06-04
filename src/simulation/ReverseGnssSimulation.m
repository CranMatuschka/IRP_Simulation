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
            ProjectPathManager.addProjectPaths();
        end

        function configure(obj)
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
            
            obj.results = ResultBuilder.fromSimulation(obj);
            
            fprintf('Done. Final ECI position error: %.3f m\n', ...
                norm(obj.history.x(obj.idx.pos, end) - obj.history.truth(obj.idx.pos, end)));
            fprintf('Mean pseudorange innovation RMS: %.3f m over %.0f measurements/epoch\n', ...
                mean(obj.history.innovation_rms_m, 'omitnan'), mean(obj.history.pseudorange_measurement_count));
        end

        function saveResults(obj)
            if isempty(fieldnames(obj.results))
                obj.results = ResultBuilder.fromSimulation(obj);
            end

            SimulationOutputManager.ensureOutputDirectory(obj);
            SimulationOutputManager.saveResultsStruct( ...
                obj.results, obj.outputDir, obj.scenarioName);
        end

        function generateReport(obj)
            if ~isfield(obj.cfg, 'report') || ...
                    ~logical(obj.getFieldOrDefault(obj.cfg.report, 'generatePdf', false))
                return;
            end

            SimulationOutputManager.ensureOutputDirectory(obj);

            reportData = ReportDataBuilder.fromSimulation(obj);
            reportToggles = ReportConfigBuilder.togglesFromSimulation(obj);
            reportConfig = ReportConfigBuilder.configFromSimulation(obj);
            
            generateReport(reportData, reportConfig, reportToggles);
        end
    end

    methods (Access = private)
        
        function loadConfig(obj)
            if isfield(obj.runtimeOptions, 'simConfigOverride')
                simConfigOverride = obj.runtimeOptions.simConfigOverride; %#ok<NASGU>
            end
            if isfield(obj.runtimeOptions, 'simConfigOverrides')
                simConfigOverrides = obj.runtimeOptions.simConfigOverrides; %#ok<NASGU>
            end
            run(char(ProjectPathManager.simulationConfigFile()));
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
            obj.cfg = GroundTimingNetwork.applyTowerClockEkfConfiguration(obj.cfg); 
        end

        function setupTime(obj)
            obj.dt = double(obj.simConfig.simulation.dt_s);
            obj.numSteps = max(2, floor(obj.simConfig.simulation.totalTime_h * 3600 / obj.dt) + 1);
            obj.time_s = (0:obj.numSteps - 1) * obj.dt;
            obj.jd0 = Clock.julianDateFromDatetime(obj.simConfig.simulation.startUtc);
        end

        function setupGroundNodes(obj)
            [obj.towers, obj.activeTowerConfig, obj.towerNames] = ...
                GroundTimingNetwork.buildGroundNodes( ...
                obj.cfg.towers, ...
                obj.simConfig, ...
                obj.assetConfig, ...
                obj.dt, ...
                obj.seedConfig, ...
                obj.c);

            obj.numTowers = numel(obj.towers);
            obj.towersEciFirst_m = GroundNode.positionsECI(obj.towers, obj.jd0);
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
                    GroundTimingNetwork.truthGaugeVectors(obj.towers, obj.cfg);
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
            [obj.idx, obj.stateDim] = StateIndexFactory.create( ...
                obj.numTowers, obj.towerClockEkfEnabled());

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

            P0 = StateLockPolicy.applyToCovariance( ...
                P0, obj.cfg.ekf, obj.idx, obj.stateDim, ...
                obj.towerClockEkfEnabled());

            obj.initialX0 = obj.physicalEstimateVector();
            obj.initialTruth0 = obj.physicalTruthVector();
            obj.initialP0 = P0;

            obj.Q = EkfDynamicsModel.buildProcessNoise(obj);
            obj.R = eye(obj.numReceivers * obj.numTowers) * ...
                obj.measurementModel.measurementVariance( ...
                obj.towerClockEkfEnabled(), ...
                GroundTimingNetwork.residualVariance_m2(obj.cfg, obj.c));
            obj.ekf = ExtendedKalmanFilter(x0, P0, obj.Q, obj.R);

            obj.transitionFromInitial = eye(obj.stateDim);
            obj.observabilityNormalMatrix = zeros(obj.stateDim);
        end

        function setupHistory(obj)
            obj.history = HistoryRecorder.initialize(obj);
            obj.outputDir = SimulationOutputManager.defaultOutputDirectory(obj);
        end
        %%
        function step(obj, k)
            if k > 1
                obj.propagateTruth();
                obj.propagateNominalEstimate();

                F = EkfDynamicsModel.buildStateTransition(obj);
                obj.ekf.predict(zeros(obj.stateDim, 1), F, obj.Q);
                
                obj.ekf.P = StateLockPolicy.applyToCovariance( ...
                    obj.ekf.P, obj.cfg.ekf, obj.idx, obj.stateDim, obj.towerClockEkfEnabled());
                
                obj.transitionFromInitial = F * obj.transitionFromInitial;
            end

            jd = obj.jd0 + obj.time_s(k) / 86400.0;
            towersEci = GroundNode.positionsECI(obj.towers, jd);

            [groundResidual_m, groundTrue_m, groundCorrection_m] = ...
                GroundTimingNetwork.residualMeters( ...
                obj.towers, ...
                obj.cfg, ...
                obj.c, ...
                obj.measurementStream, ...
                obj.towerClockEkfEnabled());

            groundResidualTruth_m = groundResidual_m;
            groundResidualModel_m = zeros(obj.numTowers, 1);

            [yRange, Rrange, trueRangeRt, losRt, receiverEci, visibilityMask, elevationRt_deg] = ...
                obj.measurementModel.makePseudoranges( ...
                jd, towersEci, groundResidualTruth_m, ...
                obj.truthAsset, ...
                obj.towerClockEkfEnabled(), ...
                GroundTimingNetwork.residualVariance_m2(obj.cfg, obj.c));

            [ypRange, Hrange] = ...
                obj.measurementModel.predictPseudorangesWithJacobian( ...
                towersEci, groundResidualModel_m, visibilityMask, ...
                obj.estAsset, obj.estTowerClockBias_m, ...
                obj.idx, obj.stateDim, obj.towerClockEkfEnabled());

            innovationRange = yRange - ypRange;

            [yUpdate, ypUpdate, Hupdate, Rupdate] = ...
                ClockGaugeConstraint.append( ...
                yRange, ypRange, Hrange, Rrange, ...
                obj.estTowerClockBias_m, obj.estTowerClockDrift_mps, ...
                obj.idx, obj.stateDim, obj.towerClockEkfEnabled(), ...
                obj.cfg, obj.cfg.ekf, obj.numTowers);

            S = Hupdate * obj.ekf.P * Hupdate' + Rupdate;

            if isempty(yUpdate)
                nisValue = NaN;
            else
                [~, nisValue] = obj.ekf.update(yUpdate, ypUpdate, Hupdate, Rupdate);
            end

            obj.injectErrorState(obj.ekf.X);
            obj.ekf.X(:) = 0.0;

            obj.ekf.P = obj.applyCovarianceFloor(obj.ekf.P);

            obj.ekf.P = StateLockPolicy.applyToCovariance( ...
                obj.ekf.P, obj.cfg.ekf, obj.idx, ...
                obj.stateDim, obj.towerClockEkfEnabled());
            
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

            [obj.history, obj.observabilityNormalMatrix] = HistoryRecorder.record( ...
                obj, ...
                obj.history, ...
                obj.observabilityNormalMatrix, ...
                obj.physicalEstimateVector(), ...
                obj.physicalTruthVector(), ...
                diag(obj.ekf.P), ...
                obj.ekf.P, ...
                k, ...
                y, ...
                innovation, ...
                postfit, ...
                S, ...
                H, ...
                nisValue, ...
                trueRangeRt, ...
                losRt, ...
                receiverEci, ...
                towersEci, ...
                groundResidual_m, ...
                groundTrue_m, ...
                groundCorrection_m, ...
                visibilityMask, ...
                elevationRt_deg);
        end
        
        function propagateTruth(obj)
            obj.truthAsset.propagateTruth(obj.mu, obj.dt);

            for twr = 1:obj.numTowers
                obj.towers{twr}.updateClock(obj.dt);
            end
        end

        function propagateNominalEstimate(obj)
            [clockPhi, ~] = EkfDynamicsModel.clockBiasDriftMatrices(obj, obj.dt);
            obj.estAsset.propagateNominal(obj.mu, obj.dt, clockPhi);

            if obj.towerClockEkfEnabled()
                for twr = 1:obj.numTowers
                    [towerPhi, ~] = EkfDynamicsModel.towerClockBiasDriftMatrices( ...
                        obj, twr, obj.dt);

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

            lockedIdx = StateLockPolicy.lockedStateIndices( ...
                obj.cfg.ekf, obj.idx, obj.stateDim, obj.towerClockEkfEnabled());
            
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

        function tf = towerClockEkfEnabled(obj)
            tf = logical(obj.getFieldOrDefault(obj.cfg, 'enableTowerClockEKF', false));
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
                    GroundTimingNetwork.truthGaugeVectors(obj.towers, obj.cfg);

                x(obj.idx.rxClockBias) = obj.truthAsset.getClockBias_m() - meanTowerBias_m;
                x(obj.idx.rxClockDrift) = obj.truthAsset.getClockDrift_mps() - meanTowerDrift_mps;
                x(obj.idx.towerClockBias) = towerBiasGauge_m;
                x(obj.idx.towerClockDrift) = towerDriftGauge_mps;
            else
                x(obj.idx.rxClockBias) = obj.truthAsset.getClockBias_m();
                x(obj.idx.rxClockDrift) = obj.truthAsset.getClockDrift_mps();
            end
        end

        function value = getFieldOrDefault(~, s, fieldName, defaultValue)
            if isstruct(s) && isfield(s, fieldName), value = s.(fieldName); else, value = defaultValue; end
        end

        function value = getScalarField(~, s, fieldName, defaultValue)
            if isstruct(s) && isfield(s, fieldName) && ~isempty(s.(fieldName)), value = double(s.(fieldName)); else, value = double(defaultValue); end
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

    end
end
