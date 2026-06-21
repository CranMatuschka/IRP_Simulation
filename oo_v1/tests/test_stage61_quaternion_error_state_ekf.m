function results = test_stage61_quaternion_error_state_ekf()
% test_stage61_quaternion_error_state_ekf  Stage 61 smoke tests.
%
% T1: AttitudeErrorStateKinematics class exists with required static methods
% T2: eulerToQuatZYX / quatToEulerZYX round-trip accuracy
% T3: injectRight: after injection + reset, quaternion norm stays unit
% T4: smallAnglePerturbedDcm: perturbed DCM is near-orthogonal
% T5: ReverseGNSSEKF accepts quaternionErrorState parameterization
% T6: getMeasurementState returns nominal euler (not near-zero error state)
% T7: Stage 61 metadata updated in ReportStatus/StageHistory/MainScriptValidationGate

results = struct('name',{},'pass',{},'message',{});

% --- T1: AttitudeErrorStateKinematics class and methods ---
try
    classExists = exist('revgnss.AttitudeErrorStateKinematics','class') == 8;
    reqMethods  = {'quatNormalize','eulerToQuatZYX','quatToEulerZYX','quatToDcm', ...
                   'deltaQuat','injectRight','propagateQuatBodyRate', ...
                   'smallAnglePerturbedDcm','wrapEulerError_deg','summaryLines'};
    missing = {};
    for mi = 1:numel(reqMethods)
        if ~ismethod('revgnss.AttitudeErrorStateKinematics', reqMethods{mi})
            missing{end+1} = reqMethods{mi}; %#ok<AGROW>
        end
    end
    ok = classExists && isempty(missing);
    results(end+1) = mkr_('T1:classAndMethods', ok, ...
        sprintf('classExists=%s, missing=[%s]', mat2str(classExists), strjoin(missing,',')));
catch ex
    results(end+1) = mkr_('T1:classAndMethods', false, ex.message);
end

% --- T2: eulerToQuatZYX / quatToEulerZYX round-trip ---
try
    euler_in = [0.3; -0.15; 1.2];  % arbitrary roll/pitch/yaw in rad
    q = revgnss.AttitudeErrorStateKinematics.eulerToQuatZYX(euler_in);
    euler_out = revgnss.AttitudeErrorStateKinematics.quatToEulerZYX(q);
    roundTripErr = max(abs(euler_out - euler_in));
    normOk  = abs(norm(q) - 1) < 1e-12;
    errSmall = roundTripErr < 1e-9;
    % Also verify DCM from quat vs DCM from euler match
    C_quat  = revgnss.AttitudeErrorStateKinematics.quatToDcm(q);
    C_euler = revgnss.AttitudeKinematics.bodyToEcefRotation(euler_in);
    dcmDiff = max(abs(C_quat(:) - C_euler(:)));
    dcmOk   = dcmDiff < 1e-9;
    ok = normOk && errSmall && dcmOk;
    results(end+1) = mkr_('T2:roundTrip', ok, ...
        sprintf('roundTripErr=%.2e, normErr=%.2e, dcmDiff=%.2e', ...
        roundTripErr, abs(norm(q)-1), dcmDiff));
catch ex
    results(end+1) = mkr_('T2:roundTrip', false, ex.message);
end

% --- T3: injectRight quaternion norm preservation ---
try
    q0 = revgnss.AttitudeErrorStateKinematics.eulerToQuatZYX([0.2; 0.1; 0.5]);
    % Simulate 10 inject-and-reset cycles with random perturbations
    q = q0;
    maxNormDev = 0;
    for k = 1:10
        delta = 0.05 * randn(3,1);  % ~3 deg random
        [q, ~] = revgnss.AttitudeErrorStateKinematics.injectRight(q, delta);
        maxNormDev = max(maxNormDev, abs(norm(q) - 1));
    end
    ok = maxNormDev < 1e-10;
    results(end+1) = mkr_('T3:injectNorm', ok, ...
        sprintf('maxNormDeviation=%.2e after 10 injections', maxNormDev));
catch ex
    results(end+1) = mkr_('T3:injectNorm', false, ex.message);
end

% --- T4: smallAnglePerturbedDcm orthogonality ---
try
    C = revgnss.AttitudeKinematics.bodyToEcefRotation([0.1; 0.2; 0.3]);
    delta = [0.001; 0; 0];  % small perturbation about roll axis
    Cpert = revgnss.AttitudeErrorStateKinematics.smallAnglePerturbedDcm(C, delta);
    orth_err = max(abs(Cpert*Cpert' - eye(3)), [], 'all');
    det_err  = abs(det(Cpert) - 1);
    % Lever arm rotation: should shift antenna position by ~delta x lever
    lever = [1; 0; 0];
    r_orig = C * lever;
    r_pert = Cpert * lever;
    shift  = norm(r_pert - r_orig);
    ok = orth_err < 1e-4 && det_err < 1e-4 && shift < 0.01;
    results(end+1) = mkr_('T4:pertDcmOrth', ok, ...
        sprintf('orthErr=%.2e, detErr=%.2e, leverShift=%.4f m', ...
        orth_err, det_err, shift));
catch ex
    results(end+1) = mkr_('T4:pertDcmOrth', false, ex.message);
end

% --- T5: ReverseGNSSEKF accepts quaternionErrorState parameterization ---
try
    cfg = revgnss.ConfigFactory.defaultConfig();
    cfg = revgnss.ScenarioPresets.apply(cfg, 'singleAssetCarrierAttitude');
    cfg.estimator.attitude.parameterization = 'quaternionErrorState';
    ekf = revgnss.ReverseGNSSEKF(cfg, cfg.scenario.nTowers);
    paramOk  = strcmp(ekf.attitudeParameterization, 'quaternionErrorState');
    hasQuatProp = isnumeric(ekf.nominalQuat_wxyz) && numel(ekf.nominalQuat_wxyz) == 4;
    % initState should initialize nominal quaternion from euler
    x0 = zeros(ekf.nx, 1);
    eul0 = [0.3; -0.1; 0.8];
    x0(ekf.stateMap.euler_idx) = eul0;
    ekf.initState(x0, eye(ekf.nx));
    xErrState = ekf.x(ekf.stateMap.euler_idx);
    errStateNear0 = max(abs(xErrState)) < 1e-12;  % error state reset to zero
    quatNorm = norm(ekf.nominalQuat_wxyz);
    quatNormOk = abs(quatNorm - 1) < 1e-10;
    ok = paramOk && hasQuatProp && errStateNear0 && quatNormOk;
    results(end+1) = mkr_('T5:ekfInit', ok, ...
        sprintf('paramOk=%s, quatNorm=%.9f, errStateNear0=%s', ...
        mat2str(paramOk), quatNorm, mat2str(errStateNear0)));
catch ex
    results(end+1) = mkr_('T5:ekfInit', false, ex.message);
end

% --- T6: getMeasurementState returns nominal euler, not error state ---
try
    cfg = revgnss.ConfigFactory.defaultConfig();
    cfg = revgnss.ScenarioPresets.apply(cfg, 'singleAssetCarrierAttitude');
    cfg.estimator.attitude.parameterization = 'quaternionErrorState';
    ekf = revgnss.ReverseGNSSEKF(cfg, cfg.scenario.nTowers);
    x0 = zeros(ekf.nx, 1);
    eul0 = [0.25; -0.12; 1.1];
    x0(ekf.stateMap.euler_idx) = eul0;
    ekf.initState(x0, eye(ekf.nx));
    % x(euler_idx) is now zero (error state), but getMeasurementState
    % should return nominal euler (reconstructed from quaternion)
    xMeas = ekf.getMeasurementState();
    measEul = xMeas(ekf.stateMap.euler_idx);
    roundErr = max(abs(measEul - eul0));
    xRaw = ekf.x(ekf.stateMap.euler_idx);
    rawNear0 = max(abs(xRaw)) < 1e-12;
    measNearEul0 = roundErr < 1e-9;
    % getReportEulerRad must also match
    reportEul = ekf.getReportEulerRad();
    reportErr = max(abs(reportEul - eul0));
    ok = rawNear0 && measNearEul0 && reportErr < 1e-9;
    results(end+1) = mkr_('T6:getMeasState', ok, ...
        sprintf('rawNear0=%s, measRoundErr=%.2e, reportErr=%.2e', ...
        mat2str(rawNear0), roundErr, reportErr));
catch ex
    results(end+1) = mkr_('T6:getMeasState', false, ex.message);
end

% --- T7: Stage 61 implemented (historical metadata; current stage may be >= 61) ---
try
    rs = revgnss.ReportStatus.current();
    % Stage 61 may be historical (current stage >= 61) — check implemented, not current
    stageGeq61 = str2double(rs.stage) >= 61;
    titleOk    = contains(rs.stageTitle, 'Quaternion') || ...
                 contains(rs.stageTitle, 'Covariance') || ...
                 contains(rs.stageTitle, 'Error-State') || ...
                 contains(rs.stageTitle, 'Closure');

    allImp  = revgnss.StageHistory.implementedItems();
    hist61  = any(cellfun(@(s) startsWith(s,'Stage 61:'), allImp));

    % MainScriptValidationGate source must reference stage 61
    gateFile = which('revgnss.MainScriptValidationGate');
    gateSrc  = fileread(gateFile);
    gateTitleOk = ~isempty(strfind(gateSrc, 'case 61')) && ...
                  ~isempty(strfind(gateSrc, 'Quaternion')); %#ok<STREMP>

    % AttitudeErrorStateKinematics must be in +revgnss package
    aeskClass = exist('revgnss.AttitudeErrorStateKinematics','class') == 8;

    ok = stageGeq61 && titleOk && hist61 && gateTitleOk && aeskClass;
    results(end+1) = mkr_('T7:metadata', ok, ...
        sprintf('stage=%s (>=61)=%s hist61=%s gateOk=%s class=%s', ...
        rs.stage, mat2str(stageGeq61), mat2str(hist61), ...
        mat2str(gateTitleOk), mat2str(aeskClass)));
catch ex
    results(end+1) = mkr_('T7:metadata', false, ex.message);
end

end

% ---------- helpers ----------

function r = mkr_(name, pass, msg)
    r.name = name; r.pass = pass; r.message = msg;
end
