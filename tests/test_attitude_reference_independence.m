% test_attitude_reference_independence  Differential attitude uses no truth-derived reference.

testDirectory = fileparts(mfilename('fullpath'));
repositoryRoot = fileparts(testDirectory);
addpath(repositoryRoot);
addpath(fullfile(repositoryRoot, 'config'));
addpath(fullfile(repositoryRoot, 'config', 'internal'));

[defaultConfig, ~] = resolveSimulationConfig('default.json');
[realismConfig, ~] = resolveSimulationConfig('realism.json');
for config = {defaultConfig, realismConfig}
    current = config{1};
    assert(~current.estimator.integerAmbiguity.enable);
    assert(~current.estimator.diffAtt.ambiguityResolution.enable);
    assert(~current.estimator.runKnownAmbiguityValidation);
    assert(strcmp(current.estimator.diffAtt.ambiguityResolution. ...
        partialFixPolicy, 'mixedFixedFloat'));
    assert(strcmp(current.estimator.diffAtt.referenceMode, 'selfCalibrated'));
end

unsupportedConfig = masterConfig();
unsupportedConfig.estimator.diffAtt.referenceMode = ...
    'externalInitialAttitude';
externalModeRejected = false;
try
    revgnss.DiffAttitudeBuilder.init( ...
        unsupportedConfig, unsupportedConfig.scenario.nTowers);
catch exception
    externalModeRejected = strcmp(exception.identifier, ...
        'DiffAttitudeBuilder:externalReferenceUnavailable');
end
assert(externalModeRejected, ...
    'The unavailable external attitude product mode did not hard-error.');

truthInitializationConfig = masterConfig();
truthInitializationConfig.estimator.attitudeInitMode = ...
    'knownAttitudeCalibration';
truthInitializationRejected = false;
try
    revgnss.ConfigFactory.finalizeConfig(truthInitializationConfig);
catch exception
    truthInitializationRejected = strcmp(exception.identifier, ...
        'ConfigFactory:truthAttitudeInitializationUnavailable');
end
assert(truthInitializationRejected, ...
    'Simulated truth was accepted as an attitude estimator input.');

initializerConfig = revgnss.ConfigFactory.defaultConfig();
initializerConfig.scenario.nReceivers = 4;
initializerConfig.signals.twoFrequency.enable = false;
initializerConfig.measurements.carrierPhase.enable = true;
initializerConfig.measurements.carrierMode = 'ekfFloat';
initializerConfig.estimation.ambiguityMode = ...
    'floatPerTowerReceiverSignal';
initializerConfig.estimator.attitude.parameterization = ...
    'quaternionErrorState';
initializerConfig.estimator.attitudeInitMode = ...
    'coarseBaselineIntegerSearch';
initializerConfig.estimator.attitudeInit.search.windowDeg = [1;1;1];
initializerConfig.estimator.attitudeInit.search.stepDeg = [1;1;1];
initializerConfig.estimator.attitudeInit.search.maxCandidates = 27;
initializerConfig.estimator.attitudeInit.search.ratioThreshold = 0;
initializerConfig.estimator.attitudeInit.search. ...
    improvementRatioThreshold = 0;
initializerConfig.estimator.attitudeInit.search.maxRmsCycles = 1;
initializerConfig = revgnss.ConfigFactory.finalizeConfig(initializerConfig);
[truthAsset,towers,initializerEkf,measurementModel] = ...
    revgnss.ScenarioFactory.build(initializerConfig);
[~,~,~,~,measurementInfo] = measurementModel.computeMeasurements( ...
    truthAsset,towers,initializerEkf.getMeasurementState(),0, ...
    initializerEkf.stateMap);
[alternateTruthAsset,alternateTowers,alternateEkf] = ...
    revgnss.ScenarioFactory.build(initializerConfig);
alternateTruthAsset.attitude_euler_rad = ...
    alternateTruthAsset.attitude_euler_rad+deg2rad([20;-10;30]);
noSlip = struct('nSlips',0);
[initializerEkf,initializerInfo] = revgnss.AttitudeInitializer.run( ...
    initializerConfig,truthAsset,towers,initializerEkf, ...
    measurementInfo.carrierPhase,noSlip);
[alternateEkf,alternateInfo] = revgnss.AttitudeInitializer.run( ...
    initializerConfig,alternateTruthAsset,alternateTowers,alternateEkf, ...
    measurementInfo.carrierPhase,noSlip);
assert(strcmp(initializerInfo.classification, ...
    alternateInfo.classification) && ...
    initializerInfo.acceptedByEkf == alternateInfo.acceptedByEkf && ...
    norm(initializerInfo.bestCandidateEuler_deg- ...
    alternateInfo.bestCandidateEuler_deg) < 1e-12 && ...
    norm(initializerEkf.getReportEulerRad(1)- ...
    alternateEkf.getReportEulerRad(1)) < 1e-12, ...
    'Coarse attitude initialization decision depends on simulated truth.');
assert(initializerInfo.acceptedByEkf && ...
    norm(initializerEkf.x(initializerEkf.stateMap.euler_idx)) == 0 && ...
    norm(initializerEkf.getReportEulerRad(1)- ...
    deg2rad(initializerInfo.bestCandidateEuler_deg)) < 1e-12, ...
    'Accepted coarse initialization did not replace the MEKF nominal attitude.');

simulationConfig = masterConfig();
simulationConfig.simulation.duration_s = 90;
simulationConfig.scenario.nReceivers = 4;
simulationConfig.estimator.attitudeCarrierMode = ...
    'calibratedDifferentialAmbiguity';
simulationConfig.report.enable = false;
simulationConfig.report.writePdf = false;
simulationConfig.report.writeMat = false;
simulationConfig.plots.enable = false;
simulationConfig.estimator.runKnownAmbiguityValidation = false;
simulationConfig.estimator.enforceCarrierArcConsistency.enable = false;
simulationConfig.diagnostics.carrierArcConsistencyEnforcement.enable = false;
simulationConfig.measurements.carrier.ionosphereFreeRows.enable = false;
simulationConfig.measurements.carrier.ionosphereFreeRows.useInEkf = false;
simulation = revgnss.ReverseGNSSSimulation(simulationConfig);
simulation.initialize();
simulation.run();

rowCounts = simulation.diag.getDiffAttNRows();
assert(any(rowCounts > 0), ...
    'Float differential-attitude rows disappeared when fixing was disabled.');
assert(~simulation.diffAttStore.integerFixAttempted);
assert(~simulation.diffAttStore.externalRefUsedAsSearchCenter);
assert(~simulation.diffAttStore.externalRefUsedForCalibration);
assert(isempty(simulation.diffAttStore.referenceAttitude_euler_rad));
assert(strcmp(simulation.diffAttStore.solutionInterpretation, ...
    'relativeAttitudeTrackingConditionedOnInitialPrior'));
assert(all(strcmp(simulation.diffAttStore.ambiguityStatus(:), ...
    'floatSelfCalibrated')));

source = fileread(fullfile(repositoryRoot, '+revgnss', ...
    'ReverseGNSSSimulation.m'));
assert(~contains(source, 'refEuler') && ~contains(source, 'RngSource.ATT_REF'), ...
    'Simulation initialization still synthesizes an attitude reference.');

fprintf('test_attitude_reference_independence: PASS\n');
