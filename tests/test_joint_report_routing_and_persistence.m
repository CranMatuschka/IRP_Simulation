function test_joint_report_routing_and_persistence()
% ReportRunner must retain joint estimation instead of routing to fast mode.

reportFolder = tempname(tempdir);
mkdir(reportFolder);
cleanup = onCleanup(@() i_removeFolder(reportFolder)); %#ok<NASGU>

cfg = revgnss.ConfigFactory.defaultConfig();
cfg.simulation.duration_s = 1;
cfg.simulation.dt_s = 1;
cfg.scenario.nSpaceAssets = 2;
cfg.multiAsset.mode = 'joint';
cfg.multiAsset.recordTruth = true;
cfg.estimator.estimateAttitude = true;
cfg.estimator.attitude.parameterization = 'quaternionErrorState';
cfg.estimator.attitudeCarrierMode = 'off';
cfg.estimator.attitude.useCarrierPartials = false;
cfg.estimator.attitude.useCodePartials = false;
cfg.estimator.starTracker.enable = true;
cfg.estimator.starTracker.useInEKF = true;
cfg.estimator.imu.enable = true;
cfg.measurements.isl.enable = true;
cfg.measurements.isl.twoWay.enable = true;
cfg.measurements.isl.twoWay.range.enable = true;
cfg.measurements.isl.twoWay.range.useInEKF = true;
cfg.report.reportFolder = reportFolder;
cfg.report.stem = 'joint-report-test';
cfg.report.writePdf = false;
cfg.report.writeMat = true;
cfg.report.overwrite = true;
cfg.report.layout = 'clockExact';

out = revgnss.ReportRunner.runSingle(cfg);
assert(out.sim.ekf.jointMultiAssetEnabled);
assert(numel(out.sim.ekf.stateMap.asset) == 2);
assert(out.summary.multiAssetSupported);
assert(out.summary.nSpaceAssetsSupported == 2);
assert(strcmp(out.summary.dimensionContractStatus, ...
    'active_jointMultiAsset_nTowersNReceiversVariable'));
assert(strcmp(out.cfg.report.layout,'clockExact'));
assert(strcmp(out.summary.reportLayoutResolved,'clockExact'));
assert(strcmp(out.summary.estimatorArchitecture, ...
    'centralizedJointErrorStateEKF'));
assert(out.summary.nEstimatedAssets == 2);
assert(out.summary.nConfiguredAssets == 2);
assert(out.summary.stateVectorDimension == out.sim.ekf.nx);
assert(out.summary.nStates == out.sim.ekf.nx);
assert(numel(out.summary.estimatorStateMap.asset) == 2);
assert(strcmp(out.summary.validationInterpretation, ...
    'singleRunDiagnosticNotStatisticalAcceptance'));

sectionPath = fullfile(reportFolder,'joint-scenario-section.tex');
sectionHandle = fopen(sectionPath,'wt');
assert(sectionHandle >= 0);
sectionCleanup = onCleanup(@() fclose(sectionHandle)); %#ok<NASGU>
revgnss.report.scenarioSummary(sectionHandle,out.cfg,out.summary, ...
    out.simData,out.summary.nTowers,out.summary.nReceivers, ...
    out.cfg.simulation.duration_s,out.cfg.simulation.dt_s, ...
    @(value) char(string(value)),struct(),'','');
clear sectionCleanup
sectionText = fileread(sectionPath);
assert(contains(sectionText,'centralized joint error-state EKF'));
assert(contains(sectionText,'runtime joint EKF state dimension'));
assert(~contains(sectionText,'single GEO-class space asset'));
assert(~contains(sectionText,'The 14 base states'));
for assetIndex = 1:out.summary.nEstimatedAssets
    assert(contains(sectionText,out.summary.estimatedAssetNames{assetIndex}));
end

assert(out.summary.starTrackerAttitudeUpdateActive);
assert(out.summary.gyroscopeAttitudePropagationActive);
assert(strcmp(out.summary.attitudeObsClass,'CONVERGED'));
assert(exist(out.matPath,'file') == 2);

saved = load(out.matPath,'jointEstimate','multiAssetTruth', ...
    'interSatelliteObservations','interSatelliteTruthDiagnostics');
assert(isfield(saved,'jointEstimate') && saved.jointEstimate.nAssets == 2);
assert(isequal(saved.jointEstimate.estimatedIndices,1:2));
assert(size(saved.jointEstimate.finalCovariance,1) == out.sim.ekf.nx);
assert(size(saved.jointEstimate.asset(2).r_ecef_m,2) == ...
    numel(saved.jointEstimate.time_s));
assert(isequal(size(saved.jointEstimate. ...
    relativePositionCovarianceToReference_m2), ...
    [3,3,1,numel(saved.jointEstimate.time_s)]));
assert(size(saved.jointEstimate.asset(2).q_E_B_wxyz,1) == 4);
assert(size(saved.jointEstimate.asset(2).euler_rad,1) == 3);
assert(size(saved.jointEstimate.asset(2).derivedOmega_B_E_body_radps,1) == 3);
assert(contains(saved.jointEstimate.asset(2).omegaStateInterpretation, ...
    'derived from inertial gyroscope'));
assert(size(saved.jointEstimate.asset(2).attitudeErrorVariance_rad2,1) == 3);
assert(isempty(saved.jointEstimate.asset(2).angularRateStateVariance_rad2ps2), ...
    'A derived gyroscope control was reported with an unrelated state covariance.');
assert(size(saved.jointEstimate.asset(2).gyroBias_radps,1) == 3);
assert(size(saved.jointEstimate.asset(2).gyroBiasVariance_rad2ps2,1) == 3);
assert(isequal(size(saved.jointEstimate.asset(2).attitudeErrorCovariance_rad2), ...
    [3,3,numel(saved.jointEstimate.time_s)]));
assert(isequal(size(saved.jointEstimate.asset(2).gyroBiasCovariance_rad2ps2), ...
    [3,3,numel(saved.jointEstimate.time_s)]));
assert(size(saved.jointEstimate.asset(2).physicalGyroBiasTruth_radps,2) == ...
    numel(saved.jointEstimate.time_s));
secondaryBlock = out.sim.ekf.stateMap.asset(2);
assert(norm(saved.jointEstimate.asset(2).attitudeErrorCovariance_rad2(:,:,end) - ...
    out.sim.ekf.P(secondaryBlock.euler,secondaryBlock.euler),'fro') < 1e-15);
assert(norm(saved.jointEstimate.asset(2).gyroBiasCovariance_rad2ps2(:,:,end) - ...
    out.sim.ekf.P(secondaryBlock.gyroBias,secondaryBlock.gyroBias),'fro') < 1e-15);
assert(norm(saved.jointEstimate.asset(2).physicalGyroBiasTruth_radps(:,end) - ...
    out.sim.assets{2}.imu.gyroBias_radps) < 1e-15);
assert(isfield(saved.jointEstimate,'attitudeSensorHistory'));
assert(all(saved.jointEstimate.attitudeSensorHistory.gyroscopeValid(:,end)));
assert(all(saved.jointEstimate.attitudeSensorHistory.starTrackerRows(:,end) == 3));
assert(isfield(saved,'multiAssetTruth') && ...
    isequal(saved.multiAssetTruth.estimatedIndices,1:2));
assert(size(saved.multiAssetTruth.asset(2).physicalGyroBiasTruth_radps,1) == 3);
assert(numel(saved.interSatelliteObservations) == 2);
assert(numel(saved.interSatelliteTruthDiagnostics) == 2);
observation = saved.interSatelliteObservations{1};
truthDiagnostic = saved.interSatelliteTruthDiagnostics{1};
assert(~isfield(observation,'forwardGeometricRange_m'));
assert(isfield(truthDiagnostic,'forwardGeometricRange_m'));

fprintf('test_joint_report_routing_and_persistence: PASS\n');
end

function i_removeFolder(folder)
if exist(folder,'dir') == 7
    rmdir(folder,'s');
end
end
