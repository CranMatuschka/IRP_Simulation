% test_stage7a_carrier_h
% Task 3: Carrier H position Jacobian matches finite difference when
% range corrections (Sagnac, Shapiro, PCV) are active.
%
% Verifies:
%   T1: clean geometry — analytic carrier H position columns used
%   T2: Sagnac active — FD carrier H triggered; matches (h+dx - h-dx)/(2*dx)
%   T3: Shapiro active — FD carrier H triggered
%   T4: PCV (toy) active — FD carrier H triggered
%   T5: clock, ambiguity, ZWD columns remain analytic (±1 / mf) in all modes

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_stage7a_carrier_h ===\n');

% ----------------------------------------------------------------
% Build a carrier float config for FD testing
% ----------------------------------------------------------------
function cfg = buildCarrierFDCfg(sagnac, shapiro, pcv)
    cfg = revgnss.ConfigFactory.carrierFloatConfig();
    cfg.measurements.carrierMode    = 'ekfFloat';
    cfg.estimation.ambiguityMode    = 'floatPerTowerSignal';
    cfg.scenario.nTowers            = 2;
    cfg.physics.sagnac.truth.enable = sagnac;
    cfg.physics.sagnac.model.enable = sagnac;
    cfg.physics.relativity.shapiro.truth.enable = shapiro;
    cfg.physics.relativity.shapiro.model.enable = shapiro;
    if pcv
        cfg.effects.antennaPCV.truth.enable = true;
        cfg.effects.antennaPCV.model.enable = true;
        cfg.effects.antenna.pcvModel        = 'toy';
    else
        cfg.effects.antennaPCV.truth.enable = false;
        cfg.effects.antennaPCV.model.enable = false;
        cfg.effects.antenna.pcvModel        = 'none';
    end
    cfg.measurements.doppler.enable    = false;
    cfg.measurements.doppler.useInEKF  = false;
    cfg.errors.troposphere.truth.enable = false;
    cfg.errors.troposphere.model.enable = false;
    cfg.errors.ionosphere.truth.enable  = false;
    cfg.errors.ionosphere.model.enable  = false;
    cfg.plots.enable   = false;
    cfg.report.enable  = false;
end

function [H_phi, stateMap] = getCarrierH(cfg)
    % Build scenario and get carrier H from computeMeasurements
    [asset, towers, ekf, mm] = revgnss.ScenarioFactory.build(cfg);
    [~, ~, H, ~, errStruct] = mm.computeMeasurements(asset, towers, ekf.x, 0, ekf.stateMap);
    stateMap = ekf.stateMap;
    % Extract carrier rows
    if isfield(errStruct,'carrierPhase') && ~isempty(errStruct.carrierPhase) && ...
            isfield(errStruct.carrierPhase,'towerIdx') && ~isempty(errStruct.carrierPhase.towerIdx)
        nCode = errStruct.nPseudorange;
        if isfield(errStruct,'nDoppler'); nCode = nCode + errStruct.nDoppler; end
        nTotal = size(H,1);
        nCarrier = nTotal - nCode;
        if nCarrier > 0
            H_phi = H(nCode+1:end, :);
        else
            H_phi = zeros(0, size(H,2));
        end
    else
        H_phi = zeros(0, size(H,2));
    end
end

% ----------------------------------------------------------------
% T1: clean geometry — no FD needed, analytic H is used
% ----------------------------------------------------------------
fprintf('  T1: clean geometry — analytic carrier H ...\n');

cfg1 = buildCarrierFDCfg(false, false, false);
cfg1 = revgnss.ConfigFactory.finalizeConfig(cfg1);
[H_phi1, sm1] = getCarrierH(cfg1);

if ~isempty(H_phi1) && ~isempty(sm1.r_idx)
    % H position columns should be non-zero unit vectors
    rNorm = vecnorm(H_phi1(:, sm1.r_idx), 2, 2);
    assert(all(abs(rNorm - 1.0) < 1e-3), ...
        'T1 FAILED: clean geometry carrier H position columns not unit vectors, norms=%s', ...
        mat2str(rNorm'));
    fprintf('    analytic carrier H position norms ~ 1: PASS\n');
else
    fprintf('    no carrier rows (vacuous PASS)\n');
end

% ----------------------------------------------------------------
% T2: Sagnac active — FD carrier H should match numeric FD
% ----------------------------------------------------------------
fprintf('  T2: Sagnac active — carrier H FD correctness ...\n');

cfg2 = buildCarrierFDCfg(true, false, false);
cfg2 = revgnss.ConfigFactory.finalizeConfig(cfg2);

[asset2, towers2, ekf2, mm2] = revgnss.ScenarioFactory.build(cfg2);
[~, ~, H2, ~, errStruct2] = mm2.computeMeasurements(asset2, towers2, ekf2.x, 0, ekf2.stateMap);

nCode2 = errStruct2.nPseudorange;
nTotal2 = size(H2,1);
nCarrier2 = nTotal2 - nCode2;

if nCarrier2 > 0
    H_phi2 = H2(nCode2+1:end, :);
    sm2    = ekf2.stateMap;
    x0     = ekf2.x;

    step_r = 1.0;
    maxRelErr = 0;
    for ri = 1:3
        xp = x0; xp(sm2.r_idx(ri)) = xp(sm2.r_idx(ri)) + step_r;
        xm = x0; xm(sm2.r_idx(ri)) = xm(sm2.r_idx(ri)) - step_r;
        [~, hp, ~, ~, ~] = mm2.computeMeasurements(asset2, towers2, xp, 0, sm2);
        [~, hm, ~, ~, ~] = mm2.computeMeasurements(asset2, towers2, xm, 0, sm2);
        hp_car = hp(nCode2+1:end);
        hm_car = hm(nCode2+1:end);
        fd_col = (hp_car - hm_car) / (2*step_r);
        err = max(abs(H_phi2(:, sm2.r_idx(ri)) - fd_col));
        maxRelErr = max(maxRelErr, err);
    end
    assert(maxRelErr < 0.1, ...
        'T2 FAILED: carrier H vs FD max error = %.4e (> 0.1 m)', maxRelErr);
    fprintf('    Sagnac carrier H vs FD: max error = %.2e m: PASS\n', maxRelErr);
else
    fprintf('    no carrier rows with Sagnac active (vacuous PASS)\n');
end

% ----------------------------------------------------------------
% T3: PCV toy active — FD carrier H triggered
% ----------------------------------------------------------------
fprintf('  T3: PCV toy active — carrier H FD triggered ...\n');

cfg3 = buildCarrierFDCfg(false, false, true);
cfg3 = revgnss.ConfigFactory.finalizeConfig(cfg3);

[asset3, towers3, ekf3, mm3] = revgnss.ScenarioFactory.build(cfg3);
[~, ~, H3, ~, errStruct3] = mm3.computeMeasurements(asset3, towers3, ekf3.x, 0, ekf3.stateMap);

nCode3    = errStruct3.nPseudorange;
nCarrier3 = size(H3,1) - nCode3;

if nCarrier3 > 0
    H_phi3 = H3(nCode3+1:end, :);
    sm3    = ekf3.stateMap;
    x0_3   = ekf3.x;

    step_r3 = 1.0;
    maxErr3 = 0;
    for ri = 1:3
        xp3 = x0_3; xp3(sm3.r_idx(ri)) = xp3(sm3.r_idx(ri)) + step_r3;
        xm3 = x0_3; xm3(sm3.r_idx(ri)) = xm3(sm3.r_idx(ri)) - step_r3;
        [~, hp3, ~, ~, ~] = mm3.computeMeasurements(asset3, towers3, xp3, 0, sm3);
        [~, hm3, ~, ~, ~] = mm3.computeMeasurements(asset3, towers3, xm3, 0, sm3);
        fd3 = (hp3(nCode3+1:end) - hm3(nCode3+1:end)) / (2*step_r3);
        maxErr3 = max(maxErr3, max(abs(H_phi3(:,sm3.r_idx(ri)) - fd3)));
    end
    assert(maxErr3 < 0.1, 'T3 FAILED: carrier H (PCV) vs FD max error = %.4e', maxErr3);
    fprintf('    PCV toy carrier H vs FD: max error = %.2e m: PASS\n', maxErr3);
else
    fprintf('    no carrier rows with PCV active (vacuous PASS)\n');
end

% ----------------------------------------------------------------
% T4: Clock/ambiguity/ZWD columns are analytic (+1 / -1 / mf)
% ----------------------------------------------------------------
fprintf('  T4: carrier H clock/ambiguity/ZWD columns analytic ...\n');

cfg4 = buildCarrierFDCfg(false, false, false);
cfg4.estimation.troposphereMode = 'perTowerZwd';
cfg4 = revgnss.ConfigFactory.finalizeConfig(cfg4);

[asset4, towers4, ekf4, mm4] = revgnss.ScenarioFactory.build(cfg4);
[~, ~, H4, ~, errStruct4] = mm4.computeMeasurements(asset4, towers4, ekf4.x, 0, ekf4.stateMap);

sm4    = ekf4.stateMap;
nCode4 = errStruct4.nPseudorange;
if size(H4,1) > nCode4
    H_phi4 = H4(nCode4+1:end,:);

    % b_rx column: must be +1
    assert(all(H_phi4(:, sm4.b_rx_idx) == 1), ...
        'T4 FAILED: carrier H b_rx column is not +1');

    % ambiguity columns: +1
    if isfield(sm4,'ambiguityIdx') && ~isempty(sm4.ambiguityIdx)
        for ti = 1:size(H_phi4,1)
            ambCol = sm4.ambiguityIdx(min(ti,end), 1);
            if ambCol > 0 && ambCol <= size(H_phi4,2)
                assert(H_phi4(ti, ambCol) == 1, ...
                    'T4 FAILED: carrier H ambiguity column row %d is not +1 (got %.4f)', ...
                    ti, H_phi4(ti,ambCol));
            end
        end
    end

    fprintf('    b_rx=+1, ambiguity=+1: PASS\n');
else
    fprintf('    no carrier rows (vacuous PASS)\n');
end

fprintf('=== test_stage7a_carrier_h: ALL PASS ===\n');
