%% GSNSCClockScenarioNReceivers_dynamic_corrected
% Dynamic entry script for ReverseGnssSimulation.m.
%
% This script contains the user-facing controls for the compact OOP
% simulation. The actual simulation workflow lives in ReverseGnssSimulation.
%
% Important:
%   - Change settings here before sim.configure().
%   - After configure(), the EKF, clocks, towers, and receivers already exist.
%   - For receiver geometry and tower definitions, prefer SimulationConfig.m.
%   - Use N_RECEIVERS here only to select the first N configured receivers.
clearvars -except simConfigOverride simConfigOverrides;
close all;
clc;

%% ------------------------------------------------------------------------
%  USER CONTROLS
%  Change these values for each run.
%  External variables with the same names can still override these defaults.
% -------------------------------------------------------------------------

% Receiver selection
if ~exist('N_RECEIVERS', 'var') || isempty(N_RECEIVERS)
    N_RECEIVERS = 4;                 % use first N receivers from SimulationConfig.m
end

% Clock selection
if ~exist('selected_oscillator_name', 'var') || isempty(selected_oscillator_name)
    selected_oscillator_name = "Cesium1";   % must exist in simConfig.clockLibrary
end

% Simulation execution switches
RUN_SIMULATION  = true;
SAVE_RESULTS    = true;
RUN_REPORT      = true;              % report still depends on report.generatePdf below

% Optional custom output directory. Leave empty to use the default report path.
CUSTOM_OUTPUT_DIR = "";

%% ------------------------------------------------------------------------
%  CONFIG OVERRIDES
%  These override values inside SimulationConfig.m.
%  Keep this section explicit and readable.
% -------------------------------------------------------------------------

if ~exist('simConfigOverride', 'var') || isempty(simConfigOverride)
    simConfigOverride = struct();
end

% Simulation-level settings
simConfigOverride.simulation.totalTime_h = 24;                   % hours
simConfigOverride.simulation.dt_s = 1;                          % seconds
% simConfigOverride.simulation.startUtc = datetime(2026,1,1,0,0,0,'TimeZone','UTC');

% Random seed. Uncomment to force deterministic repeatability from here.
% simConfigOverride.randomSeed = 42;

% Scenario shortcut
scenarioOverride = struct();

% Clock process model used by the EKF clock states.
% Typical values depend on your Clock.aggregateBiasDriftModel implementation.
% Keep this aligned with your existing SimulationConfig.m names.
scenarioOverride.clockModel = "brownHwang";
scenarioOverride.clockGaussMarkovCorrelationTime_s = 3600;
scenarioOverride.spaceAssets.attitudeFrame = "LVLH";

% Measurement settings
scenarioOverride.measurement.enableNoise = false;
scenarioOverride.measurement.enableMeasurementNoise = false;
scenarioOverride.measurement.pseudorangeSigma_m = 0.30;

% EKF settings
scenarioOverride.ekf.initialPositionSigma_m = 10;
scenarioOverride.ekf.initialVelocitySigma_mps = 0.01;
scenarioOverride.ekf.initialClockBiasSigma_m = 100;
scenarioOverride.ekf.initialClockDriftSigma_mps = 1;
scenarioOverride.ekf.orbitProcessVariance = 1e-6;

% Report settings
scenarioOverride.report.generatePdf = true;        % set true when the simulation is stable
scenarioOverride.report.compilePdf = true;         % true requires working LaTeX installation
scenarioOverride.report.interactivePlots = false;   % false avoids opening many figures

% Number of receivers can also be stored in cfg, but runtimeOptions.N_RECEIVERS
% below is the preferred control because it directly selects the first N receivers.
scenarioOverride.numReceiversToUse = N_RECEIVERS;

% Attach scenario override to the main config override.
simConfigOverride.scenarios.vsnscToReceivers = scenarioOverride;

% Optional second override struct. This lets you layer experiment-specific
% overrides from the MATLAB workspace without editing this file.
if ~exist('simConfigOverrides', 'var') || isempty(simConfigOverrides)
    simConfigOverrides = struct();
end

%% ------------------------------------------------------------------------
%  BUILD RUNTIME OPTIONS FOR ReverseGnssSimulation
% -------------------------------------------------------------------------

runtimeOptions = struct();
runtimeOptions.entryPointName = "GSNSCClockScenarioNReceivers";
runtimeOptions.N_RECEIVERS = N_RECEIVERS;
runtimeOptions.selected_oscillator_name = selected_oscillator_name;
runtimeOptions.simConfigOverride = simConfigOverride;
runtimeOptions.simConfigOverrides = simConfigOverrides;

%% ------------------------------------------------------------------------
%  RUN
% -------------------------------------------------------------------------

sim = ReverseGnssSimulation(runtimeOptions);

% Safety fix for older ReverseGnssSimulation.m versions where idx is declared
% as an empty struct property without a 1x1 default value.
sim.idx = struct();

sim.configure();

if strlength(CUSTOM_OUTPUT_DIR) > 0
    sim.outputDir = CUSTOM_OUTPUT_DIR;
end

if RUN_SIMULATION
    sim.run();
end

if SAVE_RESULTS
    sim.saveResults();
end

if RUN_REPORT
    sim.generateReport();
end

%% ------------------------------------------------------------------------
%  QUICK ACCESS AFTER RUNNING
% -------------------------------------------------------------------------

results = sim.results;
history = sim.history;

fprintf('\nSimulation object is available as variable: sim\n');
fprintf('Results struct is available as variable: results\n');
fprintf('History struct is available as variable: history\n');
