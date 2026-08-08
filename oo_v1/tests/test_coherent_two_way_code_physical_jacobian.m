function test_coherent_two_way_code_physical_jacobian()
% Compare the active EKF row with a closed-form constant-velocity oracle.

root = fileparts(fileparts(mfilename('fullpath')));
addpath(root);
addpath(fullfile(root,'config'));
addpath(fullfile(root,'config','internal'));

cfg = resolveSimulationConfig( ...
    'test003_jointCoherentTwoWayCode.json');
cfg.scenario.nSpaceAssets = 2;
cfg.measurements.isl.twoWay.links = ...
    cfg.measurements.isl.twoWay.links(1);
cfg.simulation.duration_s = 1;
cfg.report.enable = false;
cfg.report.writePdf = false;
cfg.report.writeMat = false;
cfg.plots.enable = false;
cfg = revgnss.ConfigFactory.applyMultiAssetMode(cfg);

simulation = revgnss.ReverseGNSSSimulation(cfg);
simulation.initialize();
t_s = 0;
[observation,~,generationInfo] = ...
    revgnss.TwoWayISLMeasurementBuilder.generateObservation( ...
    simulation.cfg,simulation.asset,simulation.assets,t_s);
generationInfo.truthDiagnostic = [];
x = simulation.ekf.getMeasurementState();
[~,~,activeRow,~,~] = ...
    revgnss.TwoWayISLMeasurementBuilder.linearizeRecordedObservation( ...
    simulation.cfg,observation,x,simulation.ekf.stateMap, ...
    simulation.ekf.nx,t_s,generationInfo);

blockA = simulation.ekf.stateMap.asset(1);
blockB = simulation.ekf.stateMap.asset(2);
columns = [blockA.r;blockA.v;blockA.euler;blockA.b;blockA.bdot; ...
    blockB.r;blockB.v;blockB.euler;blockB.b;blockB.bdot];
steps = [repmat(0.25,3,1);repmat(0.025,3,1);repmat(5e-4,3,1); ...
    5;0.005;repmat(0.25,3,1);repmat(0.025,3,1); ...
    repmat(5e-4,3,1);5;0.005];

% The euler slots do not hold Euler angles under 'quaternionErrorState': they hold a
% body-frame small-angle error vector that ReverseGNSSEKF.update injects with
% injectRight. The oracle must therefore differentiate the attitude columns in that
% same basis, otherwise it validates d(rho)/d(euler) and silently pins the wrong
% convention. Implemented here independently of the builder, via the DCM form
% C <- C*Exp([delta]x), so this stays a genuine cross-check.
tangentBasis = strcmp(simulation.cfg.estimator.attitude.parameterization, ...
    'quaternionErrorState');
eulerBlocks = {blockA.euler(:),blockB.euler(:)};

oracleRow = zeros(size(activeRow));
for columnIndex = 1:numel(columns)
    stateIndex = columns(columnIndex);
    step = steps(columnIndex);
    eulerIdx = [];
    if tangentBasis
        for blockIndex = 1:numel(eulerBlocks)
            if any(eulerBlocks{blockIndex} == stateIndex)
                eulerIdx = eulerBlocks{blockIndex};
                break
            end
        end
    end
    xp2 = tangentPerturbed_(x,eulerIdx,stateIndex,2*step);
    xp1 = tangentPerturbed_(x,eulerIdx,stateIndex,step);
    xm1 = tangentPerturbed_(x,eulerIdx,stateIndex,-step);
    xm2 = tangentPerturbed_(x,eulerIdx,stateIndex,-2*step);
    oracleRow(stateIndex) = ( ...
        -oraclePrediction_(simulation.cfg,observation,xp2, ...
            simulation.ekf.stateMap,t_s) + ...
        8*oraclePrediction_(simulation.cfg,observation,xp1, ...
            simulation.ekf.stateMap,t_s) - ...
        8*oraclePrediction_(simulation.cfg,observation,xm1, ...
            simulation.ekf.stateMap,t_s) + ...
        oraclePrediction_(simulation.cfg,observation,xm2, ...
            simulation.ekf.stateMap,t_s))/(12*step);
end

absoluteTolerance = simulation.cfg.validation.manifest. ...
    jacobian.maximumAbsoluteError;
relativeTolerance = simulation.cfg.validation.manifest. ...
    jacobian.maximumRelativeError;
scale = max(abs(activeRow(columns)),abs(oracleRow(columns)));
errorMagnitude = abs(activeRow(columns)-oracleRow(columns));
if any(errorMagnitude > absoluteTolerance+relativeTolerance.*scale)
    disp(table(columns(:),activeRow(columns)',oracleRow(columns)', ...
        errorMagnitude(:),'VariableNames', ...
        {'stateIndex','active','oracle','absoluteError'}));
end
assert(all(errorMagnitude <= absoluteTolerance+relativeTolerance.*scale), ...
    'The active physical two-way Jacobian disagrees with the independent oracle.');
assert(dot(activeRow(blockA.r),activeRow(blockB.r)) < -0.8);
assert(norm(activeRow(blockA.v)) > 0 && norm(activeRow(blockB.v)) > 0);
assert(abs(activeRow(blockB.b)) <= absoluteTolerance);
assert(abs(activeRow(blockB.bdot)) <= absoluteTolerance, ...
    'A coherent turnaround must not depend on the remote free-running clock.');

fprintf('test_coherent_two_way_code_physical_jacobian: PASS\n');
end

function xPerturbed = tangentPerturbed_(x,eulerIdx,stateIndex,offset)
% Offset one column. For an attitude column under 'quaternionErrorState' the offset
% is a body-frame rotation applied as C <- C*Exp([delta]x); the result is converted
% back to ZYX Euler angles by inverting Rz(yaw)*Ry(pitch)*Rx(roll) directly, so this
% shares no code with the builder under test.
xPerturbed = x;
component = [];
if ~isempty(eulerIdx)
    component = find(eulerIdx(:) == stateIndex,1);
end
if isempty(component)
    xPerturbed(stateIndex) = xPerturbed(stateIndex)+offset;
    return
end
deltaTheta = zeros(3,1);
deltaTheta(component) = offset;
nominalRotation = revgnss.AttitudeKinematics.bodyToEcefRotation(x(eulerIdx));
perturbedRotation = revgnss.AttitudeErrorStateKinematics. ...
    smallAnglePerturbedDcm(nominalRotation,deltaTheta);
xPerturbed(eulerIdx) = [ ...
    atan2(perturbedRotation(3,2),perturbedRotation(3,3)); ...
    asin(max(-1,min(1,-perturbedRotation(3,1)))); ...
    atan2(perturbedRotation(2,1),perturbedRotation(1,1))];
end

function predictedRange_m = oraclePrediction_(cfg,observation,x,stateMap,t_s)
c = 299792458;
initiatorIndex = sscanf(observation.initiatorAssetIdentifier,'asset:%d');
transponderIndex = sscanf(observation.transponderAssetIdentifier,'asset:%d');
blockA = stateMap.asset(initiatorIndex);
blockB = stateMap.asset(transponderIndex);

[rA_m,vA_mps,rotationA] = endpointState_( ...
    cfg,x,blockA,initiatorIndex,t_s);
[rB_m,vB_mps,rotationB] = endpointState_( ...
    cfg,x,blockB,transponderIndex,t_s);
txArm = cfg.measurements.isl.twoWay.terminalGeometry. ...
    transmitPhaseCentreOffset_body_m(:);
rxArm = cfg.measurements.isl.twoWay.terminalGeometry. ...
    receivePhaseCentreOffset_body_m(:);

rateA = 1+x(blockA.bdot)/c;
properRateB = properTimeRate_(rB_m,vB_mps);
localReferenceA_s = t_s+x(blockA.b)/c;
t4_s = t_s+(observation.referenceLocalClockTag_s-localReferenceA_s)/rateA;
turnaroundProper_s = cfg.measurements.isl.twoWay.turnaroundProperTime_s;

spec.referenceCoordinateTime_s = t_s;
spec.finalReceptionCoordinateTime_s = t4_s;
spec.coordinateTurnaroundDelay_s = turnaroundProper_s/properRateB;
spec.initiatorTransmit = phaseCentre_(rA_m+rotationA*txArm,vA_mps);
spec.initiatorReceive = phaseCentre_(rA_m+rotationA*rxArm,vA_mps);
spec.transponderReceive = phaseCentre_(rB_m+rotationB*rxArm,vB_mps);
spec.transponderTransmit = phaseCentre_(rB_m+rotationB*txArm,vB_mps);
events = revgnss.ConstantVelocityFourEventLightTimeOracle.solve(spec);

predictedRange_m = 0.5*c*( ...
    rateA*(events.t4_s-events.t1_s)- ...
    rateA/properRateB*turnaroundProper_s);
if isfield(stateMap,'twoWayCodeCalibrationBiasIdx') && ...
        ~isempty(stateMap.twoWayCodeCalibrationBiasIdx)
    predictedRange_m = predictedRange_m+ ...
        x(stateMap.twoWayCodeCalibrationBiasIdx);
end
end

function [rInertial_m,vInertial_mps,bodyToInertial] = ...
        endpointState_(cfg,x,block,assetIndex,t_s)
[rInertial_m,vInertial_mps] = ...
    models.frames.FrameTimeUtils.ecefStateToInertial( ...
    x(block.r),x(block.v),t_s);
bodyToInertial = models.frames.FrameTimeUtils.rotMatEcefToInertial(t_s)* ...
    revgnss.AttitudeKinematics.bodyToEcefRotation(x(block.euler));
assert(numel(cfg.assets) >= assetIndex);
end

function phaseCentre = phaseCentre_(position_m,velocity_mps)
phaseCentre = struct('positionAtReference_m',position_m, ...
    'velocity_mps',velocity_mps);
end

function rate = properTimeRate_(rInertial_m,vInertial_mps)
c = 299792458;
muEarth_m3ps2 = 3.986004418e14;
rate = 1-(muEarth_m3ps2/norm(rInertial_m)+ ...
    0.5*dot(vInertial_mps,vInertial_mps))/c^2;
end
