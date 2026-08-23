function test_imu_gyro_bias_states()
%TEST_IMU_GYRO_BIAS_STATES  Gated IMU/gyro-bias EKF states: dims, F-sign, Q growth, golden-safety.
%   Verifies (a) the 3 gyro-bias states are appended ONLY when cfg.estimator.imu.enable (so nStates
%   is unchanged when off), (b) the strapdown propagation sign (omega = omega_gyro - b_g), and
%   (c) the bias/attitude process-noise blocks. Run: matlab -batch "test_imu_gyro_bias_states".

    oo = fileparts(fileparts(mfilename('fullpath')));
    addpath(oo); addpath(fullfile(oo,'config'));
    tol = 1e-3;

    % ---- 1. Dimension gating (off vs on) --------------------------------------------------
    cOff = revgnss.ConfigFactory.finalizeConfig(i_cfg(false));
    cOn  = revgnss.ConfigFactory.finalizeConfig(i_cfg(true));
    eOff = filter.ReverseGNSSEKF(cOff, 5, []);
    eOn  = filter.ReverseGNSSEKF(cOn,  5, []);
    assert(eOff.estimateGyroBias == false, 'off: estimateGyroBias should be false');
    assert(eOn.estimateGyroBias  == true,  'on: estimateGyroBias should be true');
    assert(isempty(eOff.stateMap.gyroBiasIdx), 'off: gyroBiasIdx must be empty');
    assert(numel(eOn.stateMap.gyroBiasIdx) == 3, 'on: 3 gyro-bias indices');
    assert(eOn.nx == eOff.nx + 3, 'on: nx must grow by exactly 3');
    assert(all(eOn.stateMap.gyroBiasIdx(:)' == (eOff.nx+1:eOff.nx+3)), 'gyro states appended last');

    % ---- 2. Strapdown propagation sign: d(roll)/d(b_gx) = -dt -----------------------------
    dt = 1.0; wg = [0.01;0;0]; ep = 1e-4;
    ri = eOn.stateMap.r_idx; vi = eOn.stateMap.v_idx; gb = eOn.stateMap.gyroBiasIdx;
    x0 = zeros(eOn.nx,1); x0(ri) = [42164e3;0;0]; x0(vi) = [0;3075;0];
    eOn.x = x0; eOn.P = eye(eOn.nx); eOn.nominalQuat_wxyz = [1;0;0;0];
    eOn.predict(dt, [], 0, wg);  qa = eOn.nominalQuat_wxyz;
    x1 = x0; x1(gb) = [ep;0;0];
    eOn.x = x1; eOn.P = eye(eOn.nx); eOn.nominalQuat_wxyz = [1;0;0;0];
    eOn.predict(dt, [], 0, wg);  qb = eOn.nominalQuat_wxyz;
    ea = revgnss.AttitudeErrorStateKinematics.quatToEulerZYX(qa);
    eb = revgnss.AttitudeErrorStateKinematics.quatToEulerZYX(qb);
    dRoll_dbg = (eb(1) - ea(1)) / ep;
    assert(abs(dRoll_dbg + dt) < tol, ...
        sprintf('F sign wrong: d(roll)/d(b_gx)=%.4f, expected -dt=%.4f', dRoll_dbg, -dt));

    % ---- 3. Process noise: bias var grows by RRW^2*dt, euler<->bias coupling appears -------
    eOn.x = x0; eOn.P = eye(eOn.nx); eOn.nominalQuat_wxyz = [1;0;0;0];
    P0bg = eOn.P(gb(1), gb(1));
    eOn.predict(dt, [], 0, wg);
    dP = eOn.P(gb(1), gb(1)) - P0bg;
    assert(abs(dP - eOn.imuRrw_^2 * dt) < 1e-14, 'bias var must grow by RRW^2*dt');
    assert(abs(eOn.P(eOn.stateMap.euler_idx(1), gb(1))) > 0, 'euler<->bias cross-cov must be nonzero');

    fprintf('test_imu_gyro_bias_states: PASS (nx %d->%d, F-sign OK, Q OK)\n', eOff.nx, eOn.nx);
end

function cfg = i_cfg(imuOn)
    cfg = masterConfig();
    cfg.scenario.nReceivers   = 4;              % 4-antenna -> attitude observable
    cfg.estimator.imu.enable  = imuOn;
end
