function test_attitude_sensor_foundation()
%TEST_ATTITUDE_SENSOR_FOUNDATION  Frame-safe gyro and star-tracker controls.

    root = fileparts(fileparts(mfilename('fullpath')));
    addpath(root);

    % An Earth-fixed body still rotates relative to inertial space.
    gyroCfg = struct('angleRandomWalk_rad_per_sqrt_s', 0, ...
        'biasRandomWalk_radps_per_sqrt_s', 0, ...
        'initialBiasSigma_radps', 0, 'seed', 14);
    gyro = models.sensors.GyroscopeMeasurementModel(gyroCfg);
    gyroObservation = gyro.sampleFromEarthRelative(zeros(3,1), [1;0;0;0], 1, 0);
    expectedEarthRate = models.frames.FrameTimeUtils.omegaEcef_radps();
    assert(norm(gyroObservation.omega_B_I_meas_body_radps-expectedEarthRate) < 1e-15, ...
        'An Earth-fixed body must have nonzero inertial angular rate.');
    q_E_B_rotated = revgnss.AttitudeQuaternion.fromRotationVector([pi/2;0;0]);
    transformedRate = models.sensors.GyroscopeMeasurementModel. ...
        inertialRateFromEarthRelative(zeros(3,1), q_E_B_rotated, expectedEarthRate);
    expectedTransformedRate = ...
        revgnss.AttitudeQuaternion.toDcm(q_E_B_rotated).'*expectedEarthRate;
    assert(norm(transformedRate-expectedTransformedRate) < 1e-15, ...
        'Earth rate must be transformed from Earth-fixed axes into body axes.');

    % Gyro propagation preserves an unknown initial absolute-attitude offset.
    [rateForPropagation, gyroModel] = gyro.estimatorInput(gyroObservation, zeros(3,1));
    assert(norm(gyroModel.directInitialAttitudeJacobian, 'fro') == 0, ...
        'Gyroscope rate must not be presented as an absolute-attitude observation.');
    qA = [1;0;0;0];
    qB = revgnss.AttitudeQuaternion.fromRotationVector(deg2rad([8;-3;4]));
    initialSeparation = revgnss.AttitudeQuaternion.geodesicDistance(qA, qB);
    for k = 1:120
        qA = revgnss.AttitudeQuaternion.propagateBodyRate(qA, rateForPropagation, 1);
        qB = revgnss.AttitudeQuaternion.propagateBodyRate(qB, rateForPropagation, 1);
    end
    finalSeparation = revgnss.AttitudeQuaternion.geodesicDistance(qA, qB);
    assert(abs(finalSeparation-initialSeparation) < 1e-12, ...
        'Gyro alone must not collapse the initial absolute-attitude separation.');

    % Noise-free star-tracker residual follows the declared right-error convention.
    q_B_S = revgnss.AttitudeQuaternion.fromRotationVector(deg2rad([0.3;-0.2;0.1]));
    calibration = struct('identifier', 'ST-A:alignment-v1', ...
        'q_B_S_wxyz', q_B_S, 'covariance_rad2', (20e-6)^2*eye(3), ...
        'validFrom_s', 0, 'validUntil_s', 1000, ...
        'treatment', 'considerParameter', ...
        'driftProcessNoise_rad2ps', (0.1e-6)^2*eye(3));
    trackerCfg = struct('sensorIdentifier', 'ST-A', 'updatePeriod_s', 1, ...
        'whiteAngularCovariance_rad2', zeros(3), ...
        'fixedAlignmentBias_rad', zeros(3,1), 'seed', 22);
    tracker = models.sensors.StarTrackerMeasurementModel(trackerCfg, calibration);
    qEstimate_I_B = revgnss.AttitudeQuaternion.fromRotationVector(deg2rad([5;2;-7]));
    deltaTheta_B = deg2rad([0.01;-0.02;0.015]);
    qTruth_I_B = revgnss.AttitudeQuaternion.multiply(qEstimate_I_B, ...
        revgnss.AttitudeQuaternion.fromRotationVector(deltaTheta_B));
    starObservation = tracker.sampleFromInertialAttitude(qTruth_I_B, 0, true);
    [innovation, starModel] = tracker.linearizedResidual( ...
        qEstimate_I_B, starObservation);
    expectedInnovation = revgnss.AttitudeQuaternion.toDcm(q_B_S).'*deltaTheta_B;
    assert(norm(innovation-expectedInnovation) < 1e-12, ...
        'Star-tracker tangent residual or frame mapping is inconsistent.');
    assert(isequal(size(starObservation.whiteAngularCovariance_rad2), [3,3]), ...
        'Star-tracker uncertainty must be three-dimensional tangent covariance.');
    assert(isequal(starModel.attitudeErrorJacobian, ...
        revgnss.AttitudeQuaternion.toDcm(q_B_S).'), ...
        'Star-tracker attitude-error Jacobian is inconsistent.');
    assert(strcmp(starModel.alignmentParameterIdentifier, 'ST-A:alignment-v1'), ...
        'Alignment parameter identity must persist across observations.');
    assert(norm(starModel.whiteAngularCovariance_rad2, 'fro') == 0, ...
        'Persistent alignment covariance must not be folded into white R.');
    assert(contains(starModel.correlationPolicy, 'persistent calibration parameter'), ...
        'Alignment-error temporal correlation policy is missing.');

    % A hidden fixed alignment error appears in the innovation, not as truth metadata.
    bias = deg2rad([0.02;-0.01;0.03]);
    trackerCfg.fixedAlignmentBias_rad = bias;
    biasedTracker = models.sensors.StarTrackerMeasurementModel(trackerCfg, calibration);
    biasedObservation = biasedTracker.sampleFromInertialAttitude([1;0;0;0], 0, true);
    biasedInnovation = biasedTracker.linearizedResidual([1;0;0;0], biasedObservation);
    assert(norm(biasedInnovation-bias) < 1e-12, ...
        'Fixed sensor-to-body alignment error is not represented correctly.');

    % Slow alignment drift is correlated state evolution, not repeated white noise.
    driftRate = [0.2e-6;-0.1e-6;0.05e-6];
    driftTrackerCfg = trackerCfg;
    driftTrackerCfg.fixedAlignmentBias_rad = zeros(3,1);
    driftTrackerCfg.alignmentDriftRate_radps = driftRate;
    driftTracker = models.sensors.StarTrackerMeasurementModel( ...
        driftTrackerCfg, calibration);
    driftTracker.sampleFromInertialAttitude([1;0;0;0], 0, true);
    driftObservation = driftTracker.sampleFromInertialAttitude([1;0;0;0], 10, true);
    driftInnovation = driftTracker.linearizedResidual( ...
        [1;0;0;0], driftObservation);
    assert(norm(driftInnovation-driftRate*10) < 1e-12, ...
        'Slow alignment drift is not propagated as a persistent rotation.');

    % Estimator-facing observations contain measurements and products, never truth attitude.
    assertNoTruthProperty_(gyroObservation);
    assertNoTruthProperty_(starObservation);
    calibrationFields = lower(string(fieldnames(starObservation.alignmentCalibration)));
    assert(~any(contains(calibrationFields, 'truth')), ...
        'Estimator calibration product must not expose a truth realization.');

    % Invalid/outage samples are explicit and carry no synthetic attitude.
    outageTracker = models.sensors.StarTrackerMeasurementModel(trackerCfg, calibration);
    outageObservation = outageTracker.sampleFromInertialAttitude([1;0;0;0], 0, false);
    assert(~outageObservation.valid && all(isnan(outageObservation.q_I_S_meas_wxyz)), ...
        'Star-tracker outage must produce an explicit invalid observation.');

    convention = revgnss.AttitudeQuaternion.convention();
    assert(contains(convention.bodyRate, 'omega_B/I'), ...
        'Quaternion/rate convention was not declared.');
    fprintf('test_attitude_sensor_foundation: PASS\n');
end

function assertNoTruthProperty_(observation)
    names = lower(string(properties(observation)));
    assert(~any(contains(names, 'truth')), ...
        'Estimator-facing observation exposes truth state.');
end
