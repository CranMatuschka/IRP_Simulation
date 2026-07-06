function results = test_stage58_ekf_dynamics_prediction()
% test_stage58_ekf_dynamics_prediction  Stage 58 smoke tests.
%
% T1: Frame state round trip (ECEF->inertial->ECEF)
% T2: Constant velocity backward compatibility
% T3: Two-body propagation sanity (circular GEO orbit)
% T4: J2 mode exercises OrbitDynamics
% T5: STM dimension check
% T6: Production migration check
% T7: No false claims

results = struct('name',{},'pass',{},'message',{});

% GEO orbit state in ECEF at t0=0: satellite on +x axis, ~0 ECEF velocity
R_GEO = 42164e3;  % metres
OMEGA = 7.2921150e-5;
r_geo = [R_GEO; 0; 0];
v_geo = [0; 0; 0];  % geostationary in ECEF

% T1: Frame state round trip
try
    [dr, dv] = models.frames.FrameTimeUtils.roundTripStateError(r_geo, v_geo, 0);
    ok = dr < 1e-6 && dv < 1e-9;
    results(end+1) = makeResult('T1_frame_round_trip', ok, ...
        sprintf('dr=%.2e m  dv=%.2e m/s (tol 1e-6, 1e-9)', dr, dv));
catch ME
    results(end+1) = makeResult('T1_frame_round_trip', false, ME.message);
end

% T2: Constant velocity backward compatibility
try
    cfg.estimator.dynamics.mode = 'constantVelocity';
    r0 = [7e6; 1e6; 0.5e6]; v0 = [100; -50; 10]; dt = 1.0;
    [r1, v1, info] = filter.EkfDynamicsPredictor.propagateEcef(r0, v0, dt, 0, cfg);
    ok = norm(r1 - (r0 + dt*v0)) < 1e-9 && norm(v1 - v0) < 1e-12 && ...
         strcmp(info.mode, 'constantVelocity') && ~info.usedInertialPropagation;
    results(end+1) = makeResult('T2_constant_velocity', ok, ...
        sprintf('r_err=%.2e v_err=%.2e mode=%s', ...
        norm(r1-(r0+dt*v0)), norm(v1-v0), info.mode));
catch ME
    results(end+1) = makeResult('T2_constant_velocity', false, ME.message);
end

% T3: Two-body propagation sanity for GEO orbit
try
    cfg.estimator.dynamics.mode = 'twoBody';
    dt = 10.0;  % 10 s propagation
    [r1, v1, info] = filter.EkfDynamicsPredictor.propagateEcef(r_geo, v_geo, dt, 0, cfg);
    r1_norm = norm(r1);
    ok = all(isfinite(r1)) && all(isfinite(v1)) && ...
         r1_norm > 6.4e6 && r1_norm < 5e7 && ...  % physically plausible
         info.usedInertialPropagation && ...
         isfinite(info.energyDrift_Jkg) && abs(info.energyDrift_Jkg) < 1.0;  % small drift for RK4
    results(end+1) = makeResult('T3_twoBody_sanity', ok, ...
        sprintf('r1_norm=%.3e m  energyDrift=%.2e J/kg  inertial=%d', ...
        r1_norm, info.energyDrift_Jkg, info.usedInertialPropagation));
catch ME
    results(end+1) = makeResult('T3_twoBody_sanity', false, ME.message);
end

% T4: J2 mode
try
    cfg.estimator.dynamics.mode = 'j2';
    [r1j2, v1j2, info_j2] = filter.EkfDynamicsPredictor.propagateEcef(r_geo, v_geo, 10, 0, cfg);
    ok = all(isfinite(r1j2)) && all(isfinite(v1j2)) && ...
         strcmp(info_j2.forceModel, 'j2') && info_j2.usedInertialPropagation;
    results(end+1) = makeResult('T4_j2_mode', ok, ...
        sprintf('forceModel=%s inertial=%d r_norm=%.3e', ...
        info_j2.forceModel, info_j2.usedInertialPropagation, norm(r1j2)));
catch ME
    results(end+1) = makeResult('T4_j2_mode', false, ME.message);
end

% T5: STM dimension and constantVelocity analytic form
try
    cfg_cv.estimator.dynamics.mode = 'constantVelocity';
    cfg_j2.estimator.dynamics.mode = 'j2';
    dt = 1.0;
    Phi_cv = filter.EkfDynamicsPredictor.finiteDiffStm6(r_geo, v_geo, dt, 0, cfg_cv);
    Phi_j2 = filter.EkfDynamicsPredictor.finiteDiffStm6(r_geo, v_geo, dt, 0, cfg_j2);
    Phi_cv_expected = [eye(3), dt*eye(3); zeros(3), eye(3)];
    dim_ok = isequal(size(Phi_cv),[6,6]) && isequal(size(Phi_j2),[6,6]);
    cv_ok  = all(abs(Phi_cv - Phi_cv_expected) < 1e-10, 'all');
    j2_fin = all(isfinite(Phi_j2(:)));
    ok = dim_ok && cv_ok && j2_fin;
    results(end+1) = makeResult('T5_STM_dimension', ok, ...
        sprintf('dim_ok=%d cv_analytic=%d j2_finite=%d', dim_ok, cv_ok, j2_fin));
catch ME
    results(end+1) = makeResult('T5_STM_dimension', false, ME.message);
end

% T6: Production migration check
try
    ekfSrc  = fileread(fullfile(fileparts(mfilename('fullpath')), ...
        '..', '+revgnss', 'ReverseGNSSEKF.m'));
    simSrc  = fileread(fullfile(fileparts(mfilename('fullpath')), ...
        '..', '+revgnss', 'ReverseGNSSSimulation.m'));
    hasPredictor = contains(ekfSrc, 'EkfDynamicsPredictor');
    hasTime      = contains(simSrc, 't_s - dt') || contains(simSrc, 't_s-dt');
    ok = hasPredictor && hasTime;
    results(end+1) = makeResult('T6_production_migration', ok, ...
        sprintf('EKF references EkfDynamicsPredictor: %d, Sim passes t_s-dt: %d', ...
        hasPredictor, hasTime));
catch ME
    results(end+1) = makeResult('T6_production_migration', false, ME.message);
end

% T7: No false claims
try
    cfg_j2.estimator.dynamics.mode = 'j2';
    [~, ~, info_j2] = filter.EkfDynamicsPredictor.propagateEcef(r_geo, v_geo, 10, 0, cfg_j2);
    c = filter.EkfDynamicsPredictor.summaryLines(info_j2);
    lines = strjoin(c, ' ');
    noIntFix  = ~contains(lower(lines), 'integer fix');
    noLambda  = ~contains(lower(lines), 'lambda');
    noFalse   = ~contains(lower(lines), 'false-fix');
    noPPP     = ~contains(lower(lines), 'precise orbit determination');
    ok = noIntFix && noLambda && noFalse;
    results(end+1) = makeResult('T7_no_false_claims', ok, ...
        sprintf('noIntFix=%d noLambda=%d noFalsefix=%d noPPP=%d', ...
        noIntFix, noLambda, noFalse, noPPP));
catch ME
    results(end+1) = makeResult('T7_no_false_claims', false, ME.message);
end

end

function r = makeResult(name, pass, message)
    r.name    = name;
    r.pass    = pass;
    r.message = message;
    if pass
        fprintf('  PASS  %s\n', name);
    else
        fprintf('  FAIL  %s: %s\n', name, message);
    end
end
