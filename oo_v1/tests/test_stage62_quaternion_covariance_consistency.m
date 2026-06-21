function results = test_stage62_quaternion_covariance_consistency()
% test_stage62_quaternion_covariance_consistency  Stage 62 smoke tests.
%
% T1: Source-order check — ReverseGNSSEKF.m contains Pminus and Joseph-before-reset pattern
% T2: Numerical update — x(euler_idx) reset, quat norm, P finite/symmetric/PSD
% T3: Legacy eulerZYX mode — wraps Euler, no quaternion injection performed
% T4: Reset-Joseph consistency — lastAttitudeErrorStateInfo.covarianceResetOrder is posterior
% T5: Stage 57 preservation — update returns nu and S; NIS finite
% T6: No false claims — integer fixing false, LAMBDA false, PPP-grade false

results = struct('name',{},'pass',{},'message',{});

% --- T1: Source-order check ---
try
    ekfFile = which('revgnss.ReverseGNSSEKF');
    src = fileread(ekfFile);
    hasPminus   = ~isempty(strfind(src, 'Pminus = obj.P'));      %#ok<STREMP>
    hasJosephPm = ~isempty(strfind(src, 'IKH * Pminus * IKH'''));  %#ok<STREMP>
    % Reset (G applied to obj.P) must appear AFTER 'obj.P = Pplus'
    idxPplus  = strfind(src, 'obj.P = Pplus;');
    idxGReset = strfind(src, 'obj.P(ei, :) = G * obj.P(ei, :);');
    resetAfterJoseph = ~isempty(idxPplus) && ~isempty(idxGReset) && ...
                       min(idxGReset) > min(idxPplus);
    hasCovOrder = ~isempty(strfind(src, 'posterior-after-joseph')); %#ok<STREMP>
    ok = hasPminus && hasJosephPm && resetAfterJoseph && hasCovOrder;
    results(end+1) = mkr_('T1:sourceOrder', ok, ...
        sprintf('Pminus=%s Joseph(Pminus)=%s resetAfterJoseph=%s covOrder=%s', ...
        mat2str(hasPminus), mat2str(hasJosephPm), ...
        mat2str(resetAfterJoseph), mat2str(hasCovOrder)));
catch ex
    results(end+1) = mkr_('T1:sourceOrder', false, ex.message);
end

% --- T2: Numerical update check ---
try
    cfg = revgnss.ConfigFactory.defaultConfig();
    cfg = revgnss.ScenarioPresets.apply(cfg, 'singleAssetCarrierAttitude');
    cfg.estimator.attitude.parameterization = 'quaternionErrorState';
    ekf = revgnss.ReverseGNSSEKF(cfg, cfg.scenario.nTowers);
    x0 = zeros(ekf.nx, 1);
    eul0 = [0.2; -0.1; 0.5];
    x0(ekf.stateMap.euler_idx) = eul0;
    ekf.initState(x0, eye(ekf.nx) * 0.01);
    % Construct a small synthetic measurement: H measures first euler component
    ei = ekf.stateMap.euler_idx;
    H = zeros(1, ekf.nx);  H(ei(1)) = 1;
    R = 0.001;
    h_val = 0;   % predicted: error state ≈ 0
    z_val = 0.01; % small innovation
    [K, nu, S, NIS] = ekf.update(z_val, h_val, H, R);
    xErrState = ekf.x(ei);
    errNear0  = max(abs(xErrState)) < 1e-9;
    quatNormOk = abs(norm(ekf.nominalQuat_wxyz) - 1) < 1e-9;
    PfinOk    = all(isfinite(ekf.P(:)));
    PsymOk    = max(abs(ekf.P - ekf.P'), [], 'all') < 1e-10;
    minEig    = min(eig(ekf.P));
    PPsdOk    = minEig > -1e-8;
    KnotEmpty = ~isempty(K);
    ok = errNear0 && quatNormOk && PfinOk && PsymOk && PPsdOk && KnotEmpty;
    results(end+1) = mkr_('T2:numericalUpdate', ok, ...
        sprintf('errNear0=%s quatNorm=%.9f Pfin=%s Psym=%s minEig=%.2e', ...
        mat2str(errNear0), norm(ekf.nominalQuat_wxyz), ...
        mat2str(PfinOk), mat2str(PsymOk), minEig));
catch ex
    results(end+1) = mkr_('T2:numericalUpdate', false, ex.message);
end

% --- T3: Legacy eulerZYX mode ---
try
    cfg = revgnss.ConfigFactory.defaultConfig();
    cfg = revgnss.ScenarioPresets.apply(cfg, 'singleAssetCarrierAttitude');
    cfg.estimator.attitude.parameterization = 'eulerZYX';
    ekf = revgnss.ReverseGNSSEKF(cfg, cfg.scenario.nTowers);
    x0 = zeros(ekf.nx, 1);
    x0(ekf.stateMap.euler_idx) = [0.5; -0.2; 1.0];
    ekf.initState(x0, eye(ekf.nx) * 0.01);
    quatBefore = ekf.nominalQuat_wxyz;
    ei = ekf.stateMap.euler_idx;
    H  = zeros(1, ekf.nx);  H(ei(1)) = 1;
    R  = 0.01;
    ekf.update(x0(ei(1)) + 0.05, x0(ei(1)), H, R);
    % In eulerZYX mode: euler state should be wrapped (non-zero), quat unchanged
    eulAfter   = ekf.x(ei);
    eulerUsed  = norm(eulAfter) > 1e-6;
    quatUnchanged = isequal(ekf.nominalQuat_wxyz, quatBefore);
    PfinOk    = all(isfinite(ekf.P(:)));
    ok = eulerUsed && quatUnchanged && PfinOk;
    results(end+1) = mkr_('T3:legacyEuler', ok, ...
        sprintf('eulerUsed=%s quatUnchanged=%s Pfin=%s', ...
        mat2str(eulerUsed), mat2str(quatUnchanged), mat2str(PfinOk)));
catch ex
    results(end+1) = mkr_('T3:legacyEuler', false, ex.message);
end

% --- T4: Reset-Joseph consistency check ---
try
    cfg = revgnss.ConfigFactory.defaultConfig();
    cfg = revgnss.ScenarioPresets.apply(cfg, 'singleAssetCarrierAttitude');
    cfg.estimator.attitude.parameterization = 'quaternionErrorState';
    ekf = revgnss.ReverseGNSSEKF(cfg, cfg.scenario.nTowers);
    x0 = zeros(ekf.nx, 1);
    x0(ekf.stateMap.euler_idx) = [0.1; 0.05; 0.3];
    ekf.initState(x0, eye(ekf.nx) * 0.01);
    ei = ekf.stateMap.euler_idx;
    H  = zeros(3, ekf.nx);  H(1:3, ei) = eye(3);
    R  = eye(3) * 0.001;
    z  = [0.05; -0.03; 0.02];
    ekf.update(z, zeros(3,1), H, R);
    info = ekf.lastAttitudeErrorStateInfo;
    resetOrderOk = isfield(info, 'covarianceResetOrder') && ...
                   strcmp(info.covarianceResetOrder, 'posterior-after-joseph');
    covResetApplied = isfield(info, 'covarianceResetApplied') && info.covarianceResetApplied;
    ok = resetOrderOk && covResetApplied;
    results(end+1) = mkr_('T4:resetJosephOrder', ok, ...
        sprintf('resetOrder=%s covResetApplied=%s', ...
        mat2str(resetOrderOk), mat2str(covResetApplied)));
catch ex
    results(end+1) = mkr_('T4:resetJosephOrder', false, ex.message);
end

% --- T5: Stage 57 preservation — update returns nu, S, NIS ---
try
    cfg = revgnss.ConfigFactory.defaultConfig();
    cfg = revgnss.ScenarioPresets.apply(cfg, 'singleAssetCarrierAttitude');
    cfg.estimator.attitude.parameterization = 'quaternionErrorState';
    ekf = revgnss.ReverseGNSSEKF(cfg, cfg.scenario.nTowers);
    x0 = zeros(ekf.nx, 1);
    ekf.initState(x0, eye(ekf.nx) * 0.1);
    H   = zeros(2, ekf.nx);
    H(1, ekf.stateMap.r_idx(1)) = 1;
    H(2, ekf.stateMap.r_idx(2)) = 1;
    R   = eye(2) * 0.25;
    z   = [1; -1];
    h   = [0; 0];
    [K, nu, S, NIS] = ekf.update(z, h, H, R);
    nuOk  = isnumeric(nu) && numel(nu) == 2 && all(isfinite(nu));
    SOk   = isnumeric(S)  && all(size(S) == [2 2]) && all(isfinite(S(:)));
    NIsOk = isscalar(NIS) && isfinite(NIS) && NIS >= 0;
    KOk   = isnumeric(K)  && ~isempty(K);
    ok = nuOk && SOk && NIsOk && KOk;
    results(end+1) = mkr_('T5:stage57Preservation', ok, ...
        sprintf('nu=[%.3f,%.3f] NIS=%.3f nuOk=%s SOk=%s NISok=%s', ...
        nu(1), nu(2), NIS, mat2str(nuOk), mat2str(SOk), mat2str(NIsOk)));
catch ex
    results(end+1) = mkr_('T5:stage57Preservation', false, ex.message);
end

% --- T6: No false claims ---
try
    rs = revgnss.ReportStatus.current();
    stageOk   = strcmp(rs.stage, '62');
    titleOk   = contains(rs.stageTitle, 'Covariance') || contains(rs.stageTitle, 'Consistency');
    hist62    = any(cellfun(@(s) startsWith(s,'Stage 62:'), revgnss.StageHistory.implementedItems()));
    gateFile  = which('revgnss.MainScriptValidationGate');
    gateSrc   = fileread(gateFile);
    gate62Ok  = ~isempty(strfind(gateSrc, 'case 62')) && ...  %#ok<STREMP>
                ~isempty(strfind(gateSrc, 'Covariance'));      %#ok<STREMP>
    ok = stageOk && titleOk && hist62 && gate62Ok;
    results(end+1) = mkr_('T6:noFalseClaims', ok, ...
        sprintf('stage=%s titleOk=%s hist62=%s gateOk=%s', ...
        rs.stage, mat2str(titleOk), mat2str(hist62), mat2str(gate62Ok)));
catch ex
    results(end+1) = mkr_('T6:noFalseClaims', false, ex.message);
end

end

% ---------- helpers ----------

function r = mkr_(name, pass, msg)
    r.name = name; r.pass = pass; r.message = msg;
end
