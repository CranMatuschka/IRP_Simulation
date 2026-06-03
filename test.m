% test_StateIsolation_Test1_to_Test3.m
% =========================================================================
% Isolated EKF validation tests:
%   Test 1: position + receiver clock bias only
%   Test 2: receiver clock bias + receiver clock drift only
%   Test 3: attitude only, with exaggerated receiver baselines
% =========================================================================

clear; clc; close all;

thisFile = mfilename('fullpath');
thisDir = fileparts(thisFile);
if isempty(thisDir)
    thisDir = pwd;
end
addpath(thisDir);

fprintf('\n=== Reverse-GNSS isolated EKF validation ===\n');

runTest1_PositionClock(thisDir);
runTest2_ClockBiasDrift(thisDir);
runTest3_AttitudeOnly(thisDir);

fprintf('\nAll isolated tests finished.\n');

%% ------------------------------------------------------------------------
function runTest1_PositionClock(thisDir)
    fprintf('\n--- Test 1: position + receiver clock bias only ---\n');

    override = baseOverride("Test1_PositionClock");

    override.simulation.totalTime_h = 0.10;
    override.simulation.dt_s = 1.0;

    scenario = override.scenarios.reverseGnssClockNavigationScenario;

    scenario.numReceivers = 1;
    scenario.receiverBaseline_m = 0.0;
    scenario.receivers = buildReceiverConfigs(1, 0.0, 1e-3);

    scenario.ekf.initialPositionError_m = [100.0; -50.0; 25.0];
    scenario.ekf.initialVelocityError_mps = [0.0; 0.0; 0.0];
    scenario.ekf.initialAttitudeError_deg = [0.0; 0.0; 0.0];
    scenario.ekf.initialAngularVelocityError_degps = [0.0; 0.0; 0.0];

    scenario.ekf.initialClockBiasError_m = 100.0;
    scenario.ekf.initialClockFrequencyError_mps = 0.0;

    scenario.ekf.initialPositionSigma_m = 500.0;
    scenario.ekf.initialVelocitySigma_mps = 1e-12;
    scenario.ekf.initialAttitudeSigma_deg = 1e-12;
    scenario.ekf.initialAngularVelocitySigma_degps = 1e-12;
    scenario.ekf.initialClockBiasSigma_m = 500.0;
    scenario.ekf.initialClockFrequencySigma_mps = 1e-12;

    scenario.ekf.estimatePosition = true;
    scenario.ekf.estimateVelocity = false;
    scenario.ekf.estimateAttitude = false;
    scenario.ekf.estimateAngularRate = false;
    scenario.ekf.estimateReceiverClockBias = true;
    scenario.ekf.estimateReceiverClockDrift = false;

    override.scenarios.reverseGnssClockNavigationScenario = scenario;

    sim = runOneSimulation(thisDir, override);
    printFinalErrors(sim);
end

%% ------------------------------------------------------------------------
function runTest2_ClockBiasDrift(thisDir)
    fprintf('\n--- Test 2: receiver clock bias + receiver clock drift only ---\n');

    override = baseOverride("Test2_ClockBiasDrift");

    override.simulation.totalTime_h = 0.50;
    override.simulation.dt_s = 1.0;

    scenario = override.scenarios.reverseGnssClockNavigationScenario;

    scenario.numReceivers = 1;
    scenario.receiverBaseline_m = 0.0;
    scenario.receivers = buildReceiverConfigs(1, 0.0, 1e-3);

    scenario.ekf.initialPositionError_m = [0.0; 0.0; 0.0];
    scenario.ekf.initialVelocityError_mps = [0.0; 0.0; 0.0];
    scenario.ekf.initialAttitudeError_deg = [0.0; 0.0; 0.0];
    scenario.ekf.initialAngularVelocityError_degps = [0.0; 0.0; 0.0];

    scenario.ekf.initialClockBiasError_m = 100.0;
    scenario.ekf.initialClockFrequencyError_mps = 0.05;

    scenario.ekf.initialPositionSigma_m = 1e-12;
    scenario.ekf.initialVelocitySigma_mps = 1e-12;
    scenario.ekf.initialAttitudeSigma_deg = 1e-12;
    scenario.ekf.initialAngularVelocitySigma_degps = 1e-12;
    scenario.ekf.initialClockBiasSigma_m = 500.0;
    scenario.ekf.initialClockFrequencySigma_mps = 0.5;

    scenario.ekf.estimatePosition = false;
    scenario.ekf.estimateVelocity = false;
    scenario.ekf.estimateAttitude = false;
    scenario.ekf.estimateAngularRate = false;
    scenario.ekf.estimateReceiverClockBias = true;
    scenario.ekf.estimateReceiverClockDrift = true;

    override.scenarios.reverseGnssClockNavigationScenario = scenario;

    sim = runOneSimulation(thisDir, override);
    printFinalErrors(sim);
end

%% ------------------------------------------------------------------------
function runTest3_AttitudeOnly(thisDir)
    fprintf('\n--- Test 3: attitude only, exaggerated baseline ---\n');

    override = baseOverride("Test3_AttitudeOnly");

    override.simulation.totalTime_h = 0.10;
    override.simulation.dt_s = 1.0;

    scenario = override.scenarios.reverseGnssClockNavigationScenario;

    scenario.numReceivers = 4;
    scenario.receiverBaseline_m = 100.0;
    scenario.receivers = buildReceiverConfigs(4, 100.0, 1e-3);

    scenario.measurement.pseudorangeSigma_m = 1e-3;
    scenario.measurement.sigma_numerical_floor_m = 1e-6;
    scenario.measurement.deterministicSigma_m = 1e-6;

    scenario.ekf.initialPositionError_m = [0.0; 0.0; 0.0];
    scenario.ekf.initialVelocityError_mps = [0.0; 0.0; 0.0];
    scenario.ekf.initialAttitudeError_deg = [1.0; -0.5; 0.8];
    scenario.ekf.initialAngularVelocityError_degps = [0.0; 0.0; 0.0];

    scenario.ekf.initialClockBiasError_m = 0.0;
    scenario.ekf.initialClockFrequencyError_mps = 0.0;

    scenario.ekf.initialPositionSigma_m = 1e-12;
    scenario.ekf.initialVelocitySigma_mps = 1e-12;
    scenario.ekf.initialAttitudeSigma_deg = 5.0;
    scenario.ekf.initialAngularVelocitySigma_degps = 1e-12;
    scenario.ekf.initialClockBiasSigma_m = 1e-12;
    scenario.ekf.initialClockFrequencySigma_mps = 1e-12;

    scenario.ekf.estimatePosition = false;
    scenario.ekf.estimateVelocity = false;
    scenario.ekf.estimateAttitude = true;
    scenario.ekf.estimateAngularRate = false;
    scenario.ekf.estimateReceiverClockBias = false;
    scenario.ekf.estimateReceiverClockDrift = false;

    override.scenarios.reverseGnssClockNavigationScenario = scenario;

    sim = runOneSimulation(thisDir, override);
    printFinalErrors(sim);
end

%% ------------------------------------------------------------------------
function simConfigOverride = baseOverride(testName)
    simConfigOverride = struct();

    simConfigOverride.randomSeed = 20260603;
    simConfigOverride.enableReportGeneration = false;

    simConfigOverride.clockLibrary.PerfectClock = struct( ...
        'h0', 0.0, ...
        'hm1', 0.0, ...
        'hm2', 0.0);

    simConfigOverride.simulation.dt_s = 1.0;
    simConfigOverride.simulation.totalTime_h = 0.10;
    simConfigOverride.simulation.startUtc = datetime(2026, 5, 27, 23, 0, 0, 'TimeZone', 'UTC');

    scenario = struct();
    scenario.name = string(testName);

    scenario.spaceAsset.name = "GEO-1";
    scenario.spaceAsset.startLatitude_deg = 0.0;
    scenario.spaceAsset.startLongitude_deg = 23.0;
    scenario.spaceAsset.geoAltitude_m = 35786000.0;
    scenario.spaceAsset.clock.clockType = 'PerfectClock';
    scenario.spaceAsset.clock.initialBias_ps = 0.0;
    scenario.spaceAsset.clock.initialDrift_ps_per_s = 0.0;
    scenario.spaceAsset.trueInitialAttitudeEuler321_deg = [0.0; 0.0; 0.0];
    scenario.spaceAsset.trueAngularVelocity_degps = [0.0; 0.0; 0.0];

    scenario.numReceivers = 1;
    scenario.receiverBaseline_m = 0.0;
    scenario.receivers = buildReceiverConfigs(1, 0.0, 1e-3);

    scenario.measurement.pseudorangeSigma_m = 1e-3;
    scenario.measurement.sigma_numerical_floor_m = 1e-6;
    scenario.measurement.deterministicSigma_m = 1e-6;
    scenario.measurement.enableMeasurementNoise = false;
    scenario.measurement.enableNoise = false;
    scenario.measurement.enableIonosphereDelay = false;
    scenario.measurement.enableTroposphereDelay = false;
    scenario.measurement.enableHardwareDelay = false;
    scenario.measurement.enableMultipathDelay = false;
    scenario.measurement.enableAntennaDelay = false;
    scenario.measurement.enableSagnacCorrection = false;
    scenario.measurement.enableElevationMask = false;
    scenario.measurement.elevationMask_deg = -90.0;
    scenario.measurement.ionosphereDelay_m = 0.0;
    scenario.measurement.troposphereDelay_m = 0.0;
    scenario.measurement.txHardwareDelay_m = 0.0;
    scenario.measurement.rxHardwareDelay_m = 0.0;
    scenario.measurement.multipathDelay_m = 0.0;
    scenario.measurement.antennaDelay_m = 0.0;
    scenario.measurement.sagnacCorrection_m = 0.0;

    scenario.enableTowerClockEKF = false;
    scenario.enableGroundClockErrors = false;
    scenario.enableGroundClockCorrection = false;
    scenario.enableGroundClockCorrectionNoise = false;
    scenario.groundClockCorrectionSigma_ps = 0.0;
    scenario.towerClockGaugeMode = "externalTowerCorrections";

    scenario.process.eciAccelerationPsd_m2ps3 = 0.0;
    scenario.process.attitudeAngularAccelerationPsd_rad2ps3 = 0.0;
    scenario.process.clockModel = "brownHwang";
    scenario.process.clockCorrelationTime_s = 3600.0;
    scenario.process.towerClockModel = "brownHwang";
    scenario.process.towerClockCorrelationTime_s = 3600.0;

    scenario.ekf = struct();
    scenario.ekf.lockedStateVariance = 1e-24;
    scenario.ekf.covarianceFloor = 0.0;
    scenario.ekf.freezeNavigationStates = false;

    scenario.ekf.initialTowerClockBiasError_m = 0.0;
    scenario.ekf.initialTowerClockDriftError_mps = 0.0;
    scenario.ekf.initialTowerClockBiasSigma_m = 1e-12;
    scenario.ekf.initialTowerClockDriftSigma_mps = 1e-12;
    scenario.ekf.towerClockGaugeBiasSigma_m = 1e-4;
    scenario.ekf.towerClockGaugeDriftSigma_mps = 1e-6;

    scenario.report.enable = false;
    scenario.report.generatePdf = false;
    scenario.report.compilePdf = false;
    scenario.report.interactivePlots = false;
    scenario.report.enableAllanDeviationValidation = false;

    simConfigOverride.scenarios.reverseGnssClockNavigationScenario = scenario;
end

%% ------------------------------------------------------------------------
function sim = runOneSimulation(thisDir, simConfigOverride)
    runtimeOptions = struct();
    runtimeOptions.entryPointName = mfilename;
    runtimeOptions.simConfigOverride = simConfigOverride;

    scenarioName = char(simConfigOverride.scenarios.reverseGnssClockNavigationScenario.name);
    runtimeOptions.N_RECEIVERS = simConfigOverride.scenarios.reverseGnssClockNavigationScenario.numReceivers;

    sim = ReverseGnssSimulation(runtimeOptions);
    sim.configure();

    sim.outputDir = string(fullfile(thisDir, "reports", "StateIsolation", scenarioName));
    if ~exist(char(sim.outputDir), "dir")
        mkdir(char(sim.outputDir));
    end

    sim.run();
    sim.saveResults();
end

%% ------------------------------------------------------------------------
function printFinalErrors(sim)
    finalEstimate = sim.history.x(:, end);
    finalTruth = sim.history.truth(:, end);
    finalError = finalEstimate - finalTruth;

    posErr_m = norm(finalError(sim.idx.pos));
    velErr_mps = norm(finalError(sim.idx.vel));
    attErr_deg = rad2deg(norm(finalError(sim.idx.att)));
    omegaErr_degps = rad2deg(norm(finalError(sim.idx.omega)));
    clkBiasErr_m = finalError(sim.idx.rxClockBias);
    clkDriftErr_mps = finalError(sim.idx.rxClockDrift);
    postfitRms_m = sim.history.postfit_innovation_rms_m(end);

    fprintf('Final position error [m]:        %.6g\n', posErr_m);
    fprintf('Final velocity error [m/s]:      %.6g\n', velErr_mps);
    fprintf('Final attitude error [deg]:      %.6g\n', attErr_deg);
    fprintf('Final omega error [deg/s]:       %.6g\n', omegaErr_degps);
    fprintf('Final clock bias error [m]:      %.6g\n', clkBiasErr_m);
    fprintf('Final clock drift error [m/s]:   %.6g\n', clkDriftErr_mps);
    fprintf('Final postfit RMS [m]:           %.6g\n', postfitRms_m);
    fprintf('Final H rank:                    %.0f\n', sim.history.H_rank_history(end));
end

%% ------------------------------------------------------------------------
function receivers = buildReceiverConfigs(nReceivers, baseline_m, measurementSigma_m)
    offsets = canonicalReceiverOffsets(nReceivers, baseline_m);

    template = struct( ...
        'id', 1, ...
        'name', '', ...
        'enabled', true, ...
        'mode', "RX", ...
        'offsetBody_m', zeros(3, 1), ...
        'leverArmBody_m', zeros(3, 1), ...
        'pco_m', zeros(3, 1), ...
        'pcvMap', [], ...
        'measurementSigma_m', measurementSigma_m, ...
        'pseudorangeSigma_m', measurementSigma_m);

    receivers = repmat(template, 1, nReceivers);

    for k = 1:nReceivers
        receivers(k).id = k;
        receivers(k).name = sprintf('GEO-1-RX%02d', k);
        receivers(k).offsetBody_m = offsets(:, k);
        receivers(k).leverArmBody_m = offsets(:, k);
    end
end

%% ------------------------------------------------------------------------
function offsets = canonicalReceiverOffsets(nReceivers, baseline_m)
    base = baseline_m;

    canonical = [ ...
        0, base, 0, -base, 0, 0, 0, base, -base, base, -base, base; ...
        0, 0, base, 0, -base, 0, 0, base, base, -base, -base, 0; ...
        0, 0, 0, 0, 0, base, -base, 0, 0, 0, 0, base];

    offsets = zeros(3, nReceivers);
    nCopy = min(nReceivers, size(canonical, 2));
    offsets(:, 1:nCopy) = canonical(:, 1:nCopy);

    for k = (nCopy + 1):nReceivers
        angle = 2.0 * pi * (k - nCopy - 1) / max(1, nReceivers - nCopy);
        offsets(:, k) = base * [cos(angle); sin(angle); 0.5 * (-1)^k];
    end
end