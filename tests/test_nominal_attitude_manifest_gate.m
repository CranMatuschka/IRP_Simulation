function test_nominal_attitude_manifest_gate()
% Deterministic nominal check for the declared attitude convergence target.

root = fileparts(fileparts(mfilename('fullpath')));
addpath(root);
addpath(fullfile(root,'config'));
addpath(fullfile(root,'config','internal'));

cfg = resolveSimulationConfig('default.json');
manifest = cfg.validation.manifest.attitude;
cfg.simulation.duration_s = manifest.maximumConvergenceTime_s;
cfg.estimator.initialError.euler_deg = manifest.initialError_deg;
cfg.estimator.minMeasurementsForUpdate = 1e9;
cfg.measurements.carrierMode = 'off';
cfg.measurements.carrierPhase.enable = false;
cfg.measurements.doppler.enable = false;
cfg.measurements.doppler.useInEKF = false;
cfg.physics.doppler.truth.enable = false;
cfg.physics.doppler.model.enable = false;
cfg.report.enable = false;
cfg.report.writePdf = false;
cfg.report.writeMat = false;
cfg.plots.enable = false;

simulation = revgnss.ReverseGNSSSimulation(cfg);
simulation.initialize();
for epochIndex = 1:simulation.nEpochs
    simulation.step(epochIndex);
end

history = simulation.ekf.history;
truthEuler = simulation.asset.history.euler_rad;
nEpochs = min(size(history.nominalQuat_wxyz,3),size(truthEuler,2));
attitudeError_deg = zeros(1,nEpochs);
for epochIndex = 1:nEpochs
    qEstimate = history.nominalQuat_wxyz(:,1,epochIndex);
    qTruth = revgnss.AttitudeErrorStateKinematics.eulerToQuatZYX( ...
        truthEuler(:,epochIndex));
    attitudeError_deg(epochIndex) = rad2deg( ...
        revgnss.AttitudeQuaternion.geodesicDistance(qEstimate,qTruth));
end

convergedIndex = find(attitudeError_deg <= ...
    manifest.maximumFinalError_deg,1,'first');
assert(~isempty(convergedIndex), ...
    'The nominal star-tracker/gyro attitude did not meet the declared accuracy.');
assert(history.time_s(convergedIndex) <= ...
    manifest.maximumConvergenceTime_s);
assert(attitudeError_deg(end) <= manifest.maximumFinalError_deg);

finalCovariance = history.attitudeErrorCovariance_rad2(:,:,1,end);
assert(norm(finalCovariance-finalCovariance','fro') < 1e-14 && ...
    min(eig(finalCovariance)) >= -1e-14);
assert(all(isfinite(simulation.simData.getStarTrackerNIS())) && ...
    all(simulation.simData.getStarTrackerNISDof() == 3));

fprintf('test_nominal_attitude_manifest_gate: PASS\n');
end
