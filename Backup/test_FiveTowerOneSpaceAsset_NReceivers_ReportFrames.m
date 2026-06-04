% test_FiveTowerOneSpaceAsset_NReceivers_ReportFrames.m
% =========================================================================
% SIMPLIFIED REVERSE-GNSS SATELLITE-RX TEST SCENARIO
% =========================================================================
% Five fixed ground towers transmit upward to one GEO-like satellite receiver.
% The EKF estimates ECI spacecraft position/velocity, body-to-ECI attitude
% error, Body-frame angular rate, and one shared onboard RX clock.

clear; clc; close all;

%% USER CONTROLS
N_RECEIVERS = 4;
SPACE_ASSET_CLOCK_TYPE = 'Cesium1';
RUN_TIME_HOURS = 1.0;
SAMPLE_TIME_S = 1.0;
RECEIVER_BASELINE_M = 2.0;
RECEIVER_PSEUDORANGE_SIGMA_M = 0.30;
ENABLE_MEASUREMENT_NOISE = false;
ENABLE_ELEVATION_MASK = true;
ELEVATION_MASK_DEG = 5.0;

COMPILE_PDF = true;
RANDOM_SEED = 20260528;
REPORT_VERSION = 001;

RUN_DATE_TAG = string(datetime("now", ...
    "TimeZone", "UTC", ...
    "Format", "yyyyMMdd"));

RUN_NAME_FOLDER = sprintf("Reports_%s", RUN_DATE_TAG);
RUN_NAME_FILE = sprintf("Clock_%s_v%03d", RUN_DATE_TAG, REPORT_VERSION);
SPACE_ASSET_LAT_DEG = 0.0;
SPACE_ASSET_LON_DEG = 23.0;
SPACE_ASSET_ALTITUDE_M = 35786000.0;

%% PATH SETUP
thisFile = mfilename('fullpath');
thisDir = fileparts(thisFile);
if isempty(thisDir)
    thisDir = pwd;
end
addpath(thisDir);
ProjectPathManager.addProjectPaths();

fprintf('\n=== Simplified reverse-GNSS satellite-RX test ===\n');
fprintf('Receivers on SpaceAsset: %d\n', N_RECEIVERS);
fprintf('SpaceAsset clock: %s\n', SPACE_ASSET_CLOCK_TYPE);
fprintf('Run time: %.2f h, sample time: %.3f s\n', RUN_TIME_HOURS, SAMPLE_TIME_S);

%% BUILD CONFIG OVERRIDES
receivers = buildReceiverConfigs(N_RECEIVERS, RECEIVER_BASELINE_M, RECEIVER_PSEUDORANGE_SIGMA_M);

simConfigOverride = struct();
simConfigOverride.randomSeed = RANDOM_SEED;
simConfigOverride.simulation.dt_s = SAMPLE_TIME_S;
simConfigOverride.simulation.totalTime_h = RUN_TIME_HOURS;
simConfigOverride.simulation.startUtc = datetime(2026, 5, 27, 23, 0, 0, 'TimeZone', 'UTC');

scenarioOverride = struct();
scenarioOverride.name = RUN_NAME_FILE;
scenarioOverride.spaceAsset.name = "GEO-1";
scenarioOverride.spaceAsset.startLatitude_deg = SPACE_ASSET_LAT_DEG;
scenarioOverride.spaceAsset.startLongitude_deg = SPACE_ASSET_LON_DEG;
scenarioOverride.spaceAsset.geoAltitude_m = SPACE_ASSET_ALTITUDE_M;
scenarioOverride.spaceAsset.clock.clockType = SPACE_ASSET_CLOCK_TYPE;
scenarioOverride.numReceivers = N_RECEIVERS;
scenarioOverride.receiverBaseline_m = RECEIVER_BASELINE_M;
scenarioOverride.receivers = receivers;
scenarioOverride.measurement.pseudorangeSigma_m = RECEIVER_PSEUDORANGE_SIGMA_M;
scenarioOverride.measurement.enableMeasurementNoise = ENABLE_MEASUREMENT_NOISE;
scenarioOverride.measurement.enableNoise = ENABLE_MEASUREMENT_NOISE;
scenarioOverride.measurement.enableElevationMask = ENABLE_ELEVATION_MASK;
scenarioOverride.measurement.elevationMask_deg = ELEVATION_MASK_DEG;

% Ground clock policy:
% Tower clocks are generated in truth and corrected by an external timing product.
% They are NOT states in the spacecraft navigation EKF.
scenarioOverride.enableTowerClockEKF = false;

scenarioOverride.enableGroundClockErrors = true;
scenarioOverride.enableGroundClockCorrection = true;
scenarioOverride.enableGroundClockCorrectionNoise = false;
scenarioOverride.groundClockCorrectionSigma_ps = 50.0;

scenarioOverride.towerClockGaugeMode = "externalTowerCorrections";

% Clock isolation test: remove geometry ambiguity first.
scenarioOverride.ekf.initialPositionError_m = [1.0; 0.0; 0.0];
scenarioOverride.ekf.initialVelocityError_mps = [0.0; 0.0; 0.0];
scenarioOverride.ekf.initialAttitudeError_deg = [0.0; 0.0; 0.0];
scenarioOverride.ekf.initialAngularVelocityError_degps = [0.0; 0.0; 0.0];

scenarioOverride.ekf.initialPositionSigma_m = 0.10;
scenarioOverride.ekf.initialVelocitySigma_mps = 1e-4;
scenarioOverride.ekf.initialAttitudeSigma_deg = 0.01;
scenarioOverride.ekf.initialAngularVelocitySigma_degps = 1e-5;

scenarioOverride.ekf.initialClockBiasError_m = 100.0;
scenarioOverride.ekf.initialClockFrequencyError_mps = 0.0;
scenarioOverride.ekf.initialClockBiasSigma_m = 200.0;
scenarioOverride.ekf.initialClockFrequencySigma_mps = 0.1;
scenarioOverride.ekf.freezeNavigationStates = false;
scenarioOverride.process.eciAccelerationPsd_m2ps3 = 0.0;
scenarioOverride.process.attitudeAngularAccelerationPsd_rad2ps3 = 0.0;

scenarioOverride.report.generatePdf = true;
scenarioOverride.report.compilePdf = COMPILE_PDF;
scenarioOverride.report.interactivePlots = false;

simConfigOverride.scenarios.reverseGnssClockNavigationScenario = scenarioOverride;

runtimeOptions = struct();
runtimeOptions.entryPointName = mfilename;
runtimeOptions.N_RECEIVERS = N_RECEIVERS;
runtimeOptions.simConfigOverride = simConfigOverride;

%% RUN SIMULATION
sim = ReverseGnssSimulation(runtimeOptions);
sim.configure();
sim.outputDir = string(fullfile(thisDir, ...
    "reports", ...
    RUN_NAME_FOLDER, ...
    RUN_NAME_FILE));
if ~exist(char(sim.outputDir), "dir")
    mkdir(char(sim.outputDir));
end

sim.run();
sim.saveResults();

%% FRAME TRANSFORM VALIDATION
frameDiagnostics = buildFrameTransformDiagnostics(sim);
if ~exist(char(sim.outputDir), 'dir')
    mkdir(char(sim.outputDir));
end
save(fullfile(char(sim.outputDir), ...
    sprintf('%s_frame_transform_diagnostics.mat', char(RUN_NAME_FILE))), ...
    'frameDiagnostics');

writetable(frameDiagnostics.snapshotTable, ...
    fullfile(char(sim.outputDir), ...
    sprintf('%s_frame_transform_snapshot.csv', char(RUN_NAME_FILE))));

writetable(frameDiagnostics.roundtripTable, ...
    fullfile(char(sim.outputDir), ...
    sprintf('%s_frame_transform_roundtrip_validation.csv', char(RUN_NAME_FILE))));

fprintf('\nFrame transform validation:\n');
disp(frameDiagnostics.roundtripTable);

%% LATEX/PDF REPORT
sim.generateReport();

fprintf('\nOutputs written to:\n%s\n', char(sim.outputDir));
fprintf('Main report base name: %s_report.tex/.pdf\n', char(sim.scenarioName));

%% LOCAL FUNCTIONS
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

function diagnostics = buildFrameTransformDiagnostics(sim)
    epochIndex = unique([1, max(1, round(sim.numSteps / 2)), sim.numSteps]);
    rows = cell(0, 12);
    ecefRoundtripMax_m = 0.0;
    localRoundtripMax_m = 0.0;

    for q = 1:numel(epochIndex)
        k = epochIndex(q);
        if k == 1
            epochLabel = "start";
        elseif k == sim.numSteps
            epochLabel = "final";
        else
            epochLabel = "mid";
        end

        jd = sim.jd0 + sim.time_s(k) / 86400.0;
        theta = GroundNode.gmstRad(jd);
        R_ecef_to_eci = rot3Local(theta);
        R_eci_to_ecef = R_ecef_to_eci.';

        nominalState = [sim.history.sat_pos_history_m(:, k); sim.history.truth(sim.idx.vel, k)];
        C_local_to_eci = localFrameFromRv(nominalState(1:3), nominalState(4:6));
        C_eci_to_local = C_local_to_eci.';

        satEci = sim.history.sat_pos_history_m(:, k);
        satEcef = R_eci_to_ecef * satEci;
        rows(end + 1, :) = makeFrameRow(epochLabel, "SpaceAsset", string(sim.assetConfig.name), satEci, satEcef, [0; 0; 0]); %#ok<AGROW>

        for idxRx = 1:sim.numReceivers
            rxEci = sim.history.receiver_eci_by_receiver(:, idxRx, k);
            rxEcef = R_eci_to_ecef * rxEci;
            rxLocal = C_eci_to_local * (rxEci - nominalState(1:3));
            rows(end + 1, :) = makeFrameRow(epochLabel, "Receiver", sim.receiverNames(idxRx), rxEci, rxEcef, rxLocal); %#ok<AGROW>
            ecefRoundtripMax_m = max(ecefRoundtripMax_m, norm(R_ecef_to_eci * rxEcef - rxEci));
            localRoundtripMax_m = max(localRoundtripMax_m, norm(nominalState(1:3) + C_local_to_eci * rxLocal - rxEci));
        end

        for idxTower = 1:sim.numTowers
            towerEci = sim.history.tower_eci_by_tower(:, idxTower, k);
            towerEcef = R_eci_to_ecef * towerEci;
            towerLocal = C_eci_to_local * (towerEci - nominalState(1:3));
            rows(end + 1, :) = makeFrameRow(epochLabel, "Tower", sim.towerNames(idxTower), towerEci, towerEcef, towerLocal); %#ok<AGROW>
            ecefRoundtripMax_m = max(ecefRoundtripMax_m, norm(R_ecef_to_eci * towerEcef - towerEci));
            localRoundtripMax_m = max(localRoundtripMax_m, norm(nominalState(1:3) + C_local_to_eci * towerLocal - towerEci));
        end
    end

    diagnostics = struct();
    diagnostics.snapshotTable = cell2table(rows, 'VariableNames', {'Epoch','ObjectType','Name', ...
        'ECI_X_km','ECI_Y_km','ECI_Z_km','ECEF_X_km','ECEF_Y_km','ECEF_Z_km', ...
        'Local_East_km','Local_North_km','Local_Vertical_km'});
    diagnostics.roundtripTable = table(["ECEF_to_ECI_to_ECEF"; "ECI_to_Local_to_ECI"], ...
        [ecefRoundtripMax_m; localRoundtripMax_m], ...
        'VariableNames', {'Transform','MaxRoundTripError_m'});
end

function row = makeFrameRow(epochLabel, objectType, objectName, eci_m, ecef_m, local_m)
    row = {char(epochLabel), char(objectType), char(objectName), ...
        eci_m(1) / 1000.0, eci_m(2) / 1000.0, eci_m(3) / 1000.0, ...
        ecef_m(1) / 1000.0, ecef_m(2) / 1000.0, ecef_m(3) / 1000.0, ...
        local_m(1) / 1000.0, local_m(2) / 1000.0, local_m(3) / 1000.0};
end

function C = localFrameFromRv(r_I, v_I)
    vertical = r_I(:) ./ norm(r_I);
    north = cross(r_I(:), v_I(:));
    north = north ./ norm(north);
    east = cross(north, vertical);
    east = east ./ norm(east);
    C = [east, north, vertical];
end

function R = rot3Local(angle_rad)
    R = [cos(angle_rad), -sin(angle_rad), 0.0; ...
         sin(angle_rad),  cos(angle_rad), 0.0; ...
         0.0,             0.0,            1.0];
end
