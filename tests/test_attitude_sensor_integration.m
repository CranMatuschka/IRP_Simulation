function test_attitude_sensor_integration()
%TEST_ATTITUDE_SENSOR_INTEGRATION  Active EKF gyro/star-tracker controls.

    root = fileparts(fileparts(mfilename('fullpath')));
    addpath(root);
    addpath(fullfile(root,'config'));
    addpath(fullfile(root,'config','internal'));

    % A star-tracker epoch corrects an absolute initial attitude error.
    cfgStar = baseConfig_(1);
    cfgStar.estimator.initialError.euler_deg = [1;-0.5;0.25];
    cfgStar.estimator.starTracker.enable = true;
    cfgStar.estimator.starTracker.useInEKF = true;
    cfgStar.estimator.starTracker.whiteAngularSigma_rad = 1e-8;
    simulationStar = revgnss.ReverseGNSSSimulation(cfgStar);
    simulationStar.initialize();
    qTruth = truthQuaternion_(simulationStar.assets{1});
    initialError = revgnss.AttitudeQuaternion.geodesicDistance( ...
        simulationStar.ekf.nominalQuat_wxyz(:,1),qTruth);
    simulationStar.step(1);
    finalError = revgnss.AttitudeQuaternion.geodesicDistance( ...
        simulationStar.ekf.nominalQuat_wxyz(:,1),qTruth);
    assert(initialError > deg2rad(1), ...
        'The star-tracker control did not start with the declared attitude error.');
    assert(finalError < 1e-6 && finalError < initialError/1000, ...
        'The active star-tracker row did not correct absolute attitude.');
    mainNis = simulationStar.simData.getNIS();
    starNis = simulationStar.simData.getStarTrackerNIS();
    starDof = simulationStar.simData.getStarTrackerNISDof();
    assert(isnan(mainNis(1)), ...
        'The skipped main measurement update unexpectedly acquired a NIS value.');
    assert(isfinite(starNis(1)) && starDof(1) == 3, ...
        'The separate star-tracker update NIS or DOF was not persisted.');
    starResults = simulationStar.getResults();
    assert(starResults.starTrackerConsistency.sequentialUpdate && ...
        starResults.starTrackerConsistency.dof(1) == 3 && ...
        isfinite(starResults.data.consistency.NIS_starTracker(1)), ...
        'Results did not retain separate star-tracker consistency statistics.');

    % Gyro-only propagation retains the unknown absolute initial attitude.
    cfgGyro = baseConfig_(1);
    cfgGyro.simulation.duration_s = 10;
    cfgGyro.estimator.initialError.euler_deg = [1;-0.5;0.25];
    cfgGyro.estimator.imu.enable = true;
    cfgGyro.estimator.imu.truth.arw_rad_per_sqrt_s = 0;
    cfgGyro.estimator.imu.truth.rrw_rad_per_s_sqrt_s = 0;
    cfgGyro.estimator.imu.truth.bias0Sigma_radps = 0;
    cfgGyro.estimator.imu.filter.arw_rad_per_sqrt_s = 0;
    cfgGyro.estimator.imu.filter.rrw_rad_per_s_sqrt_s = 0;
    cfgGyro.estimator.imu.filter.P0_bias_radps = 0;
    simulationGyro = revgnss.ReverseGNSSSimulation(cfgGyro);
    simulationGyro.initialize();
    gyroInitialError = revgnss.AttitudeQuaternion.geodesicDistance( ...
        simulationGyro.ekf.nominalQuat_wxyz(:,1), ...
        truthQuaternion_(simulationGyro.assets{1}));
    for epochIdx = 1:simulationGyro.nEpochs
        simulationGyro.step(epochIdx);
    end
    gyroFinalError = revgnss.AttitudeQuaternion.geodesicDistance( ...
        simulationGyro.ekf.nominalQuat_wxyz(:,1), ...
        truthQuaternion_(simulationGyro.assets{1}));
    assert(abs(gyroFinalError-gyroInitialError) < 2e-7, ...
        'Gyro-only propagation incorrectly acquired absolute attitude information.');
    assert(~isprop(simulationGyro.attitudeSensors,'gyroscopes'), ...
        'The attitude suite must not own a second physical gyro model.');
    assert(numel(simulationGyro.asset.imu.history) == simulationGyro.nEpochs, ...
        'The physical IMU was not sampled exactly once per simulation epoch.');
    assert(isequal([simulationGyro.asset.imu.history.t_s], ...
        simulationGyro.tVec.'), ...
        'Physical IMU samples do not carry the simulation epoch timestamps.');
    storedBias = simulationGyro.simData.getGyroBiasTrue();
    assert(norm(storedBias(:,end)-simulationGyro.asset.imu.gyroBias_radps) < 1e-15, ...
        'The data store did not log the bias from the gyro that drove the EKF.');
    gyroData = simulationGyro.simData.getData();
    assert(norm(gyroData.truth.physicalGyroBias_radps(:,end)- ...
        simulationGyro.asset.imu.gyroBias_radps) < 1e-15 && ...
        strcmp(gyroData.estimate.omegaStateInterpretation, ...
        'derived from inertial gyroscope, estimated bias, and nominal Earth rate'), ...
        'Gyro truth or derived angular-rate semantics were not persisted.');
    gyroBlock = simulationGyro.ekf.stateMap.asset(1);
    assert(size(simulationGyro.ekf.history.attitudeErrorCovariance_rad2,4) == ...
        simulationGyro.nEpochs && ...
        size(simulationGyro.ekf.history.gyroBiasCovariance_rad2ps2,4) == ...
        simulationGyro.nEpochs);
    assert(norm(simulationGyro.ekf.history. ...
        attitudeErrorCovariance_rad2(:,:,1,end) - ...
        simulationGyro.ekf.P(gyroBlock.euler,gyroBlock.euler),'fro') < 1e-15);
    assert(norm(simulationGyro.ekf.history. ...
        gyroBiasCovariance_rad2ps2(:,:,1,end) - ...
        simulationGyro.ekf.P(gyroBlock.gyroBias,gyroBlock.gyroBias),'fro') < 1e-15);

    % A spacecraft fixed in ECEF still measures Earth rotation as omega_B/I.
    cfgStationary = baseConfig_(1);
    cfgStationary.estimator.imu.enable = true;
    cfgStationary.estimator.imu.truth.arw_rad_per_sqrt_s = 0;
    cfgStationary.estimator.imu.truth.rrw_rad_per_s_sqrt_s = 0;
    cfgStationary.estimator.imu.truth.bias0Sigma_radps = 0;
    cfgStationary.asset.angularRate_body_radps = zeros(3,1);
    simulationStationary = revgnss.ReverseGNSSSimulation(cfgStationary);
    simulationStationary.initialize();
    simulationStationary.attitudeSensors.generate( ...
        simulationStationary.assets,0,cfgStationary.simulation.dt_s);
    stationaryObservation = ...
        simulationStationary.attitudeSensors.gyroscopeObservations{1};
    C_E_B_truth = revgnss.AttitudeQuaternion.toDcm( ...
        truthQuaternion_(simulationStationary.asset));
    expectedInertialRate = C_E_B_truth.'* ...
        models.frames.FrameTimeUtils.omegaEcef_radps();
    assert(norm(stationaryObservation.omega_B_I_meas_body_radps- ...
        expectedInertialRate) < 1e-15, ...
        'The physical gyro did not measure inertial body rate.');
    assert(norm(simulationStationary.ekf.inertialGyroscopeToEarthRelative( ...
        stationaryObservation,1)) < 1e-15, ...
        'Nominal-frame Earth-rate removal did not recover zero ECEF-relative rate.');

    % Joint mode produces one correctly-owned tangent row block per spacecraft.
    cfgJoint = baseConfig_(3);
    cfgJoint.estimator.starTracker.enable = true;
    cfgJoint.estimator.starTracker.useInEKF = true;
    cfgJoint.estimator.starTracker.whiteAngularSigma_rad = 1e-5;
    cfgJoint.estimator.imu.enable = true;
    cfgJoint.estimator.imu.truth.arw_rad_per_sqrt_s = 0;
    cfgJoint.estimator.imu.truth.rrw_rad_per_s_sqrt_s = 0;
    cfgJoint.estimator.imu.truth.bias0Sigma_radps = 0;
    simulationJoint = revgnss.ReverseGNSSSimulation(cfgJoint);
    simulationJoint.initialize();
    simulationJoint.attitudeSensors.generate( ...
        simulationJoint.assets,0,cfgJoint.simulation.dt_s);
    for assetIdx = 1:3
        assert(~isempty(simulationJoint.assets{assetIdx}.imu), ...
            'A joint-estimated spacecraft has no physical IMU.');
        observationBefore = ...
            simulationJoint.attitudeSensors.gyroscopeObservations{assetIdx};
        nSamplesBefore = numel(simulationJoint.assets{assetIdx}.imu.history);
        observationCached = simulationJoint.assets{assetIdx}. ...
            sampleInertialSensors(0,cfgJoint.simulation.dt_s);
        assert(numel(simulationJoint.assets{assetIdx}.imu.history) == ...
            nSamplesBefore && ...
            isequal(observationCached.omega_B_I_meas_body_radps, ...
            observationBefore.omega_B_I_meas_body_radps), ...
            'A repeated request at one epoch created a second physical IMU sample.');
    end
    sensorIdentifiers = cellfun(@(asset) asset.imu.sensorIdentifier, ...
        simulationJoint.assets,'UniformOutput',false);
    assert(numel(unique(sensorIdentifiers)) == 3, ...
        'Joint spacecraft gyroscopes do not have unique physical identities.');
    [zJoint,~,HJoint,RJoint,infoJoint] = ...
        simulationJoint.attitudeSensors.buildStarTrackerRows( ...
        simulationJoint.ekf,0);
    [jointEarthRelativeRates,jointInertialRates] = ...
        simulationJoint.attitudeSensors.gyroscopeInputsForFilter( ...
        simulationJoint.ekf);
    assert(isequal(size(jointEarthRelativeRates),[3,3]) && ...
        isequal(size(jointInertialRates),[3,3]), ...
        'Joint mode did not generate a gyroscope input for every estimated spacecraft.');
    assert(numel(zJoint) == 9 && infoJoint.nRows == 9 && ...
        infoJoint.nValid == 3, ...
        'Joint mode did not create three tangent rows per spacecraft.');
    assert(all(simulationJoint.attitudeSensors.history.starTrackerValid(:,end)) && ...
        all(simulationJoint.attitudeSensors.history.starTrackerRows(:,end) == 3), ...
        'Per-spacecraft star-tracker update status was not retained.');
    biasTruthSize = size(simulationJoint.attitudeSensors.history. ...
        physicalGyroBiasTruth_radps);
    assert(biasTruthSize(1) == 3 && biasTruthSize(2) == 3 && ...
        size(simulationJoint.attitudeSensors.history. ...
        physicalGyroBiasTruth_radps,3) == 1, ...
        'Per-spacecraft physical gyro-bias truth was not retained.');
    assert(isequal(size(RJoint),[9,9]) && min(eig(RJoint)) > 0, ...
        'Joint star-tracker covariance is missing or non-positive.');
    for assetIdx = 1:3
        rows = (3*(assetIdx-1)+1):(3*assetIdx);
        ownAttitude = simulationJoint.ekf.stateMap.asset(assetIdx).euler;
        assert(norm(HJoint(rows,ownAttitude)-eye(3),'fro') < 1e-12, ...
            'Star-tracker row does not select its spacecraft attitude block.');
        otherColumns = true(1,simulationJoint.ekf.nx);
        otherColumns(ownAttitude) = false;
        assert(norm(HJoint(rows,otherColumns),'fro') == 0, ...
            'Star-tracker row leaks into another spacecraft state block.');
    end

    % Covariance grows during a tracker outage and contracts after reacquisition.
    cfgOutage = baseConfig_(1);
    cfgOutage.simulation.duration_s = 8;
    cfgOutage.estimator.starTracker.enable = true;
    cfgOutage.estimator.starTracker.useInEKF = true;
    cfgOutage.estimator.starTracker.whiteAngularSigma_rad = 1e-5;
    cfgOutage.estimator.starTracker.outages_s = [2,5];
    cfgOutage.estimator.imu.enable = true;
    cfgOutage.estimator.imu.truth.arw_rad_per_sqrt_s = 5e-5;
    cfgOutage.estimator.imu.truth.rrw_rad_per_s_sqrt_s = 1e-6;
    cfgOutage.estimator.imu.filter.arw_rad_per_sqrt_s = 5e-5;
    cfgOutage.estimator.imu.filter.rrw_rad_per_s_sqrt_s = 1e-6;
    simulationOutage = revgnss.ReverseGNSSSimulation(cfgOutage);
    simulationOutage.initialize();
    attitudeVariance = zeros(1,simulationOutage.nEpochs);
    attitudeError = zeros(1,simulationOutage.nEpochs);
    truthOutage = truthQuaternion_(simulationOutage.asset);
    attitudeIndices = simulationOutage.ekf.stateMap.asset(1).euler;
    for epochIdx = 1:simulationOutage.nEpochs
        simulationOutage.step(epochIdx);
        attitudeVariance(epochIdx) = ...
            trace(simulationOutage.ekf.P(attitudeIndices,attitudeIndices));
        attitudeError(epochIdx) = revgnss.AttitudeQuaternion.geodesicDistance( ...
            simulationOutage.ekf.nominalQuat_wxyz(:,1),truthOutage);
    end
    assert(all(simulationOutage.attitudeSensors.history. ...
        starTrackerRows(1,3:6) == 0));
    assert(simulationOutage.attitudeSensors.history.starTrackerRows(1,7) == 3);
    assert(attitudeVariance(6) > attitudeVariance(2));
    assert(attitudeVariance(7) < attitudeVariance(6));
    assert(attitudeError(7) < attitudeError(6));

    % Fast multi-asset mode equips only the primary estimated spacecraft.
    cfgFast = baseConfig_(3);
    cfgFast.multiAsset.mode = 'fast';
    cfgFast.estimator.imu.enable = true;
    cfgFast = revgnss.ConfigFactory.finalizeConfig(cfgFast);
    assert(cfgFast.assets(1).imu.enable && ...
        ~any(arrayfun(@(asset) logical(asset.imu.enable), ...
        cfgFast.assets(2:end))), ...
        'Fast mode must not instantiate IMUs on represented-only spacecraft.');

    % Re-finalization must remove derived IMU activation when the master is off.
    cfgToggle = baseConfig_(1);
    cfgToggle.estimator.imu.enable = true;
    cfgToggle = revgnss.ConfigFactory.finalizeConfig(cfgToggle);
    cfgToggle.estimator.imu.enable = false;
    cfgToggle = revgnss.ConfigFactory.finalizeConfig(cfgToggle);
    assert(~cfgToggle.estimator.estimateGyroBias && ...
        ~cfgToggle.asset.imu.enable, ...
        'Turning off the IMU left a stale gyro-bias state or physical sensor active.');

    % Exact fixed calibration cannot hide an unestimated alignment process.
    cfgAlignment = baseConfig_(1);
    cfgAlignment.estimator.starTracker.enable = true;
    cfgAlignment.estimator.starTracker.useInEKF = true;
    hiddenAlignmentCases = { ...
        {'fixedAlignmentBias_rad',deg2rad([0.01;0;0])}, ...
        {'alignmentDriftRate_radps',[1e-7;0;0]}, ...
        {'alignmentDriftRandomWalk_rad_per_sqrt_s',1e-7}, ...
        {'drawAlignmentFromCalibrationCovariance',true}};
    for caseIndex = 1:numel(hiddenAlignmentCases)
        current = cfgAlignment;
        fieldName = hiddenAlignmentCases{caseIndex}{1};
        current.estimator.starTracker.truth.(fieldName) = ...
            hiddenAlignmentCases{caseIndex}{2};
        rejected = false;
        try
            revgnss.AttitudeSensorSuite.validateConfig(current);
        catch exception
            rejected = strcmp(exception.identifier, ...
                'AttitudeSensorSuite:unmodeledFixedAlignment');
        end
        assert(rejected, ...
            'fixedCalibration accepted hidden truth field %s.',fieldName);
    end

    fprintf('test_attitude_sensor_integration: PASS\n');
end

function cfg = baseConfig_(nAssets)
    cfg = revgnss.ConfigFactory.defaultConfig();
    cfg.simulation.duration_s = 2;
    cfg.simulation.dt_s = 1;
    cfg.scenario.nSpaceAssets = nAssets;
    cfg.scenario.nReceivers = 4;
    cfg.multiAsset.mode = 'fast';
    if nAssets > 1
        cfg.multiAsset.mode = 'joint';
    end
    cfg.estimator.estimateAttitude = true;
    cfg.estimator.estimateAngularRate = false;
    cfg.estimator.estimateAttitudeFromPseudorange = false;
    cfg.estimator.attitude.parameterization = 'quaternionErrorState';
    cfg.estimator.attitudeCarrierMode = 'off';
    cfg.estimator.attitude.useCarrierPartials = false;
    cfg.estimator.attitude.useCodePartials = false;
    cfg.estimator.minMeasurementsForUpdate = 1e9;
    cfg.estimator.P0_euler_rad = deg2rad(5);
    cfg.estimator.P0_omega_radps = 1e-12;
    cfg.estimator.initialError.pos_m = zeros(3,1);
    cfg.estimator.initialError.vel_mps = zeros(3,1);
    cfg.estimator.initialError.euler_deg = zeros(3,1);
    cfg.estimator.initialError.omega_radps = zeros(3,1);
    cfg.estimator.initialError.clockBias_m = 0;
    cfg.estimator.initialError.clockDrift_mps = 0;
    cfg.estimator.starTracker.enable = false;
    cfg.estimator.starTracker.useInEKF = true;
    cfg.estimator.starTracker.calibration.treatment = 'fixedCalibration';
    cfg.estimator.starTracker.calibration.covariance_rad2 = zeros(3);
    cfg.estimator.starTracker.calibration.driftProcessNoise_rad2ps = zeros(3);
    cfg.estimator.starTracker.truth.fixedAlignmentBias_rad = zeros(3,1);
    cfg.estimator.starTracker.truth.alignmentDriftRate_radps = zeros(3,1);
    cfg.estimator.starTracker.truth.alignmentDriftRandomWalk_rad_per_sqrt_s = 0;
    cfg.estimator.starTracker.truth.drawAlignmentFromCalibrationCovariance = false;
    cfg.estimator.imu.enable = false;
    cfg.measurements.carrierMode = 'off';
    cfg.measurements.carrierPhase.enable = false;
    cfg.measurements.doppler.enable = false;
    cfg.measurements.doppler.useInEKF = false;
    cfg.physics.doppler.truth.enable = false;
    cfg.physics.doppler.model.enable = false;
    cfg.plots.enable = false;
    cfg.report.enable = false;
    cfg.report.writePdf = false;
    cfg.report.writeMat = false;
end

function q_E_B = truthQuaternion_(asset)
    q_E_B = revgnss.AttitudeErrorStateKinematics.eulerToQuatZYX( ...
        asset.attitude_euler_rad);
end
