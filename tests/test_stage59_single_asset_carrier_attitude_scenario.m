function results = test_stage59_single_asset_carrier_attitude_scenario()
% test_stage59_single_asset_carrier_attitude_scenario  Stage 59 smoke tests.
%
% T1: Scenario preset — key config fields after apply()
% T2: Lever-arm geometry — non-collinear, rank >= 2
% T3: Attitude partial controls — carrier on, Doppler off, code explicit
% T4: Dynamics consistency — CV mode for static-ECEF truth
% T5: Scenario report helper — assess() on synthetic summary returns correct flags
% T6: Source migration check — main script and report builder reference Stage 59

results = struct('name',{},'pass',{},'message',{});

% --- T1: Scenario preset ---
try
    cfg = revgnss.ConfigFactory.defaultConfig();
    cfg = revgnss.ScenarioPresets.apply(cfg, 'singleAssetCarrierAttitude');

    nameOk   = isfield(cfg,'scenario') && isfield(cfg.scenario,'name') && ...
               strcmp(cfg.scenario.name, 'singleAssetCarrierAttitude');
    nAssetOk = isfield(cfg,'scenario') && isfield(cfg.scenario,'nSpaceAssets') && ...
               cfg.scenario.nSpaceAssets == 1;
    nRxOk    = isfield(cfg,'scenario') && isfield(cfg.scenario,'nReceivers') && ...
               cfg.scenario.nReceivers >= 3;
    islOff   = ~isfield(cfg,'measurements') || ~isfield(cfg.measurements,'isl') || ...
               ~cfg.measurements.isl.enable;
    carrOk   = isfield(cfg,'measurements') && isfield(cfg.measurements,'carrierPhase') && ...
               cfg.measurements.carrierPhase.enable;
    modeOk   = isfield(cfg,'measurements') && isfield(cfg.measurements,'carrierMode') && ...
               strcmp(cfg.measurements.carrierMode, 'ekfFloat');
    ambOk    = isfield(cfg,'estimation') && isfield(cfg.estimation,'ambiguityMode') && ...
               strcmp(cfg.estimation.ambiguityMode, 'floatPerTowerReceiverSignal');

    ok = nameOk && nAssetOk && nRxOk && islOff && carrOk && modeOk && ambOk;
    results(end+1) = makeResult('T1_scenario_preset', ok, ...
        sprintf('name=%d nAssets=%d nRx=%d islOff=%d carr=%d mode=%d amb=%d', ...
        nameOk, nAssetOk, nRxOk, islOff, carrOk, modeOk, ambOk));
catch ME
    results(end+1) = makeResult('T1_scenario_preset', false, ME.message);
end

% --- T2: Lever-arm geometry ---
try
    cfg = revgnss.ConfigFactory.defaultConfig();
    cfg = revgnss.ScenarioPresets.apply(cfg, 'singleAssetCarrierAttitude');

    arms = cfg.asset.receiverLeverArms_body_m;
    armsExist  = ~isempty(arms) && size(arms,1) == 3 && size(arms,2) >= 3;
    notAllZero = any(arms(:) ~= 0);
    rk   = revgnss.SingleAssetAttitudeScenarioReport.baselineRank(cfg);
    rankOk = rk >= 2;

    ok = armsExist && notAllZero && rankOk;
    results(end+1) = makeResult('T2_lever_arm_geometry', ok, ...
        sprintf('arms=[%dx%d] notAllZero=%d rank=%d', ...
        size(arms,1), size(arms,2), notAllZero, rk));
catch ME
    results(end+1) = makeResult('T2_lever_arm_geometry', false, ME.message);
end

% --- T3: Attitude partial controls ---
try
    cfg = revgnss.ConfigFactory.defaultConfig();
    cfg = revgnss.ScenarioPresets.apply(cfg, 'singleAssetCarrierAttitude');

    carrOn  = isfield(cfg,'estimator') && isfield(cfg.estimator,'attitude') && ...
              isfield(cfg.estimator.attitude,'useCarrierPartials') && ...
              logical(cfg.estimator.attitude.useCarrierPartials);
    doppOff = isfield(cfg,'estimator') && isfield(cfg.estimator,'attitude') && ...
              isfield(cfg.estimator.attitude,'useDopplerPartials') && ...
              ~logical(cfg.estimator.attitude.useDopplerPartials);
    codeSet = isfield(cfg,'estimator') && isfield(cfg.estimator,'attitude') && ...
              isfield(cfg.estimator.attitude,'useCodePartials');  % must be explicitly set

    ok = carrOn && doppOff && codeSet;
    results(end+1) = makeResult('T3_attitude_partial_controls', ok, ...
        sprintf('carrierOn=%d dopplerOff=%d codeExplicitlySet=%d', carrOn, doppOff, codeSet));
catch ME
    results(end+1) = makeResult('T3_attitude_partial_controls', false, ME.message);
end

% --- T4: Dynamics consistency ---
try
    cfg = revgnss.ConfigFactory.defaultConfig();
    cfg = revgnss.ScenarioPresets.apply(cfg, 'singleAssetCarrierAttitude');

    ekfMode = '';
    if isfield(cfg,'estimator') && isfield(cfg.estimator,'dynamics') && ...
            isfield(cfg.estimator.dynamics,'mode')
        ekfMode = cfg.estimator.dynamics.mode;
    end
    % Truth-estimation separation: singleAssetCarrierAttitude uses j2Rk4 truth + j2 EKF
    % (SAME model family). The EKF dynamics mode must be 'j2', matching the truth family.
    truthMode = '';
    if isfield(cfg,'orbit') && isfield(cfg.orbit,'truth') && isfield(cfg.orbit.truth,'mode')
        truthMode = cfg.orbit.truth.mode;
    end
    sameFamilyOk = strcmp(ekfMode, 'j2') && strcmp(truthMode, 'j2Rk4');

    ok = sameFamilyOk;
    results(end+1) = makeResult('T4_dynamics_consistency', ok, ...
        sprintf('truthMode=%s ekfMode=%s  sameFamilyJ2=%d', truthMode, ekfMode, sameFamilyOk));
catch ME
    results(end+1) = makeResult('T4_dynamics_consistency', false, ME.message);
end

% --- T5: Scenario report helper ---
try
    cfg = revgnss.ConfigFactory.defaultConfig();
    cfg = revgnss.ScenarioPresets.apply(cfg, 'singleAssetCarrierAttitude');

    % Minimal synthetic summary (no real simulation run).
    summary.finalAttitudeError_deg    = 1.5;
    summary.carrierResidualRms57_m    = 0.002;
    summary.physicalNIS               = 15.0;
    summary.physicalDof               = 10;

    s = revgnss.SingleAssetAttitudeScenarioReport.assess(summary, cfg);

    enabledOk       = s.enabled == true;
    nAssetsOk       = s.nSpaceAssets == 1;
    nRxOk           = s.nReceivers >= 3;
    intFixFalse     = s.integerFixingImplemented == false;
    lambdaFalse     = s.lambdaImplemented == false;
    falseFixFalse   = s.falseFixRiskControlled == false;

    % Classification must not claim PPP/fixed/integer-ready/precise/operational.
    cls = lower(s.classification);
    noBadClaim = ~contains(cls,'ppp') && ~contains(cls,'precise') && ...
                 ~contains(cls,'fixed') && ~contains(cls,'operational') && ...
                 ~contains(cls,'integer-ready');

    ok = enabledOk && nAssetsOk && nRxOk && intFixFalse && lambdaFalse && ...
         falseFixFalse && noBadClaim;
    results(end+1) = makeResult('T5_scenario_report_helper', ok, ...
        sprintf('enabled=%d nAssets=%d nRx=%d intFix=%d lam=%d ffr=%d cls=%s', ...
        enabledOk, nAssetsOk, nRxOk, ~intFixFalse, ~lambdaFalse, ~falseFixFalse, s.classification));
catch ME
    results(end+1) = makeResult('T5_scenario_report_helper', false, ME.message);
end

% --- T6: Source migration check ---
try
    baseDir  = fileparts(mfilename('fullpath'));
    mainSrc  = fileread(fullfile(baseDir, '..', 'run_oo_reverse_gnss_report.m'));
    reportSrc = fileread(fullfile(baseDir, '..', '+revgnss', 'ReportRunner.m'));
    builderSrc = fileread(fullfile(baseDir, '..', '+revgnss', 'ClockExactReportBuilder.m'));

    mainHasScen   = contains(mainSrc, 'singleAssetCarrierAttitude');
    reportHasStg  = contains(reportSrc, 'SingleAssetAttitudeScenarioReport') || ...
                    contains(builderSrc, 'SingleAssetAttitudeScenarioReport');
    builderHas59  = contains(builderSrc, 'Stage~59') || contains(builderSrc, 'Stage 59');

    ok = mainHasScen && reportHasStg && builderHas59;
    results(end+1) = makeResult('T6_source_migration_check', ok, ...
        sprintf('mainScript=%d reportOrBuilder=%d builder59=%d', ...
        mainHasScen, reportHasStg, builderHas59));
catch ME
    results(end+1) = makeResult('T6_source_migration_check', false, ME.message);
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
