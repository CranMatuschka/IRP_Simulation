function test_coherent_two_way_code_attitude_jacobian_basis()
% Pin the BASIS of the coherent two-way ISL range attitude Jacobian columns.
%
% Under cfg.estimator.attitude.parameterization = 'quaternionErrorState' the three
% euler slots of an asset block do NOT hold ZYX Euler angles. They hold a body-frame
% small-angle error vector deltaTheta that filter/ReverseGNSSEKF.update injects as
%   q <- q (x) deltaQuat(deltaTheta)
% before resetting the slots to zero. The measurement Jacobian columns that multiply
% those slots must therefore be d(rho)/d(deltaTheta), not d(rho)/d(euler). The two
% differ by the Euler-rate mapping T(euler), which is the identity only at zero
% attitude and singular at gimbal lock.
%
% The test is a direct behavioural check rather than a formula comparison: perturb
% the attitude exactly the way the EKF injects it, re-evaluate the predicted range,
% and require the Jacobian to predict the observed change. A builder that returned
% Euler-basis columns fails this by the T(euler) factor.
%
% A negative control asserts the test is discriminating. Note the algebra carefully:
% a small Euler change de produces a body rotation deltaTheta = T*de, so the pre-fix
% builder returned H_euler = H_tangent*T. The control therefore forms H*inv(T), which
% is NOT the pre-fix row -- it is the row that WOULD be correct if H were already in
% the Euler basis. That is deliberate, and it is the stronger choice: on a full revert
% the shipped columns become H_tangent*T, so H*inv(T) recovers exactly H_tangent and
% beats them, tripping this assertion. Using H*T instead would leave both candidates
% wrong on a revert and the control would pass blind.

root = fileparts(fileparts(mfilename('fullpath')));
addpath(root);
addpath(fullfile(root,'config'));
addpath(fullfile(root,'config','internal'));

cfg = resolveSimulationConfig('test003_jointCoherentTwoWayCode.json');
cfg.simulation.duration_s = 1;
cfg.report.enable = false;
cfg.report.writePdf = false;
cfg.report.writeMat = false;
cfg.plots.enable = false;
assert(strcmp(cfg.estimator.attitude.parameterization,'quaternionErrorState'), ...
    'This test targets the quaternionErrorState path.');

simulation = revgnss.ReverseGNSSSimulation(cfg);
simulation.initialize();
stateMap = simulation.ekf.stateMap;
nx = simulation.ekf.nx;
t_s = 0;
x = simulation.ekf.getMeasurementState();

[observations,~,info] = ...
    revgnss.TwoWayISLMeasurementBuilder.generateObservations( ...
    cfg,simulation.asset,simulation.assets,t_s);

% A non-trivial nominal attitude is required: at euler = 0 the two bases coincide
% and the test would be vacuous. Confirm the scenario supplies one.
maximumNominalAttitude_rad = 0;
for assetIndex = 1:numel(stateMap.asset)
    attitudeIdx = stateMap.asset(assetIndex).euler;
    if isempty(attitudeIdx); continue; end
    maximumNominalAttitude_rad = ...
        max(maximumNominalAttitude_rad,norm(x(attitudeIdx)));
end
assert(maximumNominalAttitude_rad > 1e-3, ...
    ['The nominal attitude is ~0, so the Euler and tangent bases coincide and ' ...
     'this test cannot discriminate. Choose a scenario with a real attitude.']);

deltaMagnitude_rad = 1e-4;
checkedEndpoints = 0;
for observationIndex = 1:numel(observations)
    observation = observations{observationIndex};
    if isempty(observation); continue; end
    linkInfo = info.linkInfos{observationIndex};
    linkInfo.truthDiagnostic = [];
    [z,predictedRange,jacobianRow,~,~] = ...
        revgnss.TwoWayISLMeasurementBuilder.linearizeRecordedObservation( ...
        cfg,observation,x,stateMap,nx,t_s,linkInfo);
    if isempty(z); continue; end

    endpointIndices = [linkInfo.receiverAssetIndex,linkInfo.transmitterAssetIndex];
    for endpoint = endpointIndices
        block = revgnss.AssetStateBlock.forAsset(stateMap,endpoint);
        if isempty(block.euler); continue; end
        attitudeColumns = jacobianRow(block.euler);
        assert(norm(attitudeColumns) > 0, ...
            'Attitude columns are identically zero; nothing is being pinned.');

        for component = 1:3
            deltaTheta = zeros(3,1);
            deltaTheta(component) = deltaMagnitude_rad;

            perturbedState = x;
            nominalQuaternion = revgnss.AttitudeErrorStateKinematics. ...
                eulerToQuatZYX(x(block.euler));
            perturbedQuaternion = revgnss.AttitudeErrorStateKinematics. ...
                injectRight(nominalQuaternion,deltaTheta);
            perturbedState(block.euler) = revgnss.AttitudeErrorStateKinematics. ...
                quatToEulerZYX(perturbedQuaternion);

            [~,perturbedRange,~,~,~] = ...
                revgnss.TwoWayISLMeasurementBuilder. ...
                linearizeRecordedObservation( ...
                cfg,observation,perturbedState,stateMap,nx,t_s,linkInfo);

            observedChange = perturbedRange-predictedRange;
            predictedChange = attitudeColumns(:).'*deltaTheta;
            assert(abs(observedChange) > 1e-12, ...
                'The attitude perturbation produced no range change; test is vacuous.');
            relativeError = abs(predictedChange-observedChange)/abs(observedChange);
            assert(relativeError < 0.02, ...
                ['Attitude Jacobian column %d of asset %d does not predict the ' ...
                 'range change under the body-frame injection the EKF actually ' ...
                 'applies (observed %.6e m, predicted %.6e m, %.2f%% error). The ' ...
                 'columns are most likely d(rho)/d(euler) instead of ' ...
                 'd(rho)/d(deltaTheta).'], ...
                component,endpoint,observedChange,predictedChange,100*relativeError);
        end

        % Negative control: the pre-fix Euler-basis columns must FAIL the same check.
        eulerBasisColumns = attitudeColumns(:).'/eulerRateMap_(x(block.euler));
        deltaTheta = deltaMagnitude_rad*[1;1;1]/sqrt(3);
        perturbedState = x;
        nominalQuaternion = revgnss.AttitudeErrorStateKinematics. ...
            eulerToQuatZYX(x(block.euler));
        perturbedState(block.euler) = revgnss.AttitudeErrorStateKinematics. ...
            quatToEulerZYX(revgnss.AttitudeErrorStateKinematics. ...
            injectRight(nominalQuaternion,deltaTheta));
        [~,perturbedRange,~,~,~] = ...
            revgnss.TwoWayISLMeasurementBuilder.linearizeRecordedObservation( ...
            cfg,observation,perturbedState,stateMap,nx,t_s,linkInfo);
        observedChange = perturbedRange-predictedRange;
        tangentError = abs(attitudeColumns(:).'*deltaTheta-observedChange)/ ...
            abs(observedChange);
        eulerError = abs(eulerBasisColumns*deltaTheta-observedChange)/ ...
            abs(observedChange);
        assert(tangentError < eulerError, ...
            ['Negative control failed: the Euler-basis columns are not worse than ' ...
             'the shipped columns (tangent %.4f%%, euler %.4f%%), so this test ' ...
             'does not actually discriminate between the two conventions.'], ...
            100*tangentError,100*eulerError);
        checkedEndpoints = checkedEndpoints+1;
    end
end

assert(checkedEndpoints >= 2, ...
    'Expected at least one link with two attitude-bearing endpoints; checked %d.', ...
    checkedEndpoints);

fprintf(['test_coherent_two_way_code_attitude_jacobian_basis: PASS ' ...
    '(%d endpoints, nominal attitude %.4f rad)\n'], ...
    checkedEndpoints,maximumNominalAttitude_rad);
end

function T = eulerRateMap_(euler_rad)
% deltaTheta_body = T*deltaEuler for C = Rz(yaw)*Ry(pitch)*Rx(roll).
roll = euler_rad(1);
pitch = euler_rad(2);
T = [1, 0,          -sin(pitch); ...
     0, cos(roll),   sin(roll)*cos(pitch); ...
     0, -sin(roll),  cos(roll)*cos(pitch)];
end
