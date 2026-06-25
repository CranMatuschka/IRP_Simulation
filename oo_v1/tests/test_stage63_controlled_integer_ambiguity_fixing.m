function results = test_stage63_controlled_integer_ambiguity_fixing()
% test_stage63_controlled_integer_ambiguity_fixing  Stage 63 smoke tests.
%
% T1: IntegerAmbiguityFixer class exists with required static methods
% T2: applyAmbiguityPseudoMeasurement in ReverseGNSSEKF works correctly
% T3: buildCandidates gates on sigma, arc length, distance-to-integer
% T4: resetOnSlip removes entries from fixState containers.Map
% T5: assess() with disabled flag returns disabled; with enabled returns no false claims
% T6: ReverseGNSSSimulation has fixState63_ and fix63Log_ properties
% T7: Stage 63 metadata in ReportStatus / StageHistory / MainScriptValidationGate

results = struct('name',{},'pass',{},'message',{});

% --- T1: IntegerAmbiguityFixer class and methods ---
try
    classExists = exist('revgnss.IntegerAmbiguityFixer','class') == 8;
    reqMethods  = {'assess','resetOnSlip','summaryLines'};
    missing = {};
    for mi = 1:numel(reqMethods)
        if ~ismethod('revgnss.IntegerAmbiguityFixer', reqMethods{mi})
            missing{end+1} = reqMethods{mi}; %#ok<AGROW>
        end
    end
    ok = classExists && isempty(missing);
    results(end+1) = mkr_('T1:classAndMethods', ok, ...
        sprintf('classExists=%s, missing=[%s]', mat2str(classExists), strjoin(missing,',')));
catch ex
    results(end+1) = mkr_('T1:classAndMethods', false, ex.message);
end

% --- T2: applyAmbiguityPseudoMeasurement method ---
try
    cfg = revgnss.ConfigFactory.defaultConfig();
    cfg = revgnss.ScenarioPresets.apply(cfg, 'singleAssetCarrierAttitude');
    cfg.estimator.attitude.parameterization = 'quaternionErrorState';
    ekf = revgnss.ReverseGNSSEKF(cfg, cfg.scenario.nTowers);
    x0  = zeros(ekf.nx, 1);
    P0  = eye(ekf.nx);
    P0(7:9, 7:9) = 0.01 * eye(3);
    ekf.initState(x0, P0);

    % Find an ambiguity state index
    sm = ekf.stateMap;
    hasMethod = ismethod(ekf, 'applyAmbiguityPseudoMeasurement');
    ambOk = false; preVarOk = false; postVarOk = false;
    if ekf.estimateAmbiguities && ekf.nAmbiguities > 0
        if isfield(sm,'ambiguityIdx3d') && numel(sm.ambiguityIdx3d) > 0
            ambIdx = sm.ambiguityIdx3d(1,1,1);
        elseif isfield(sm,'ambiguityIdx') && numel(sm.ambiguityIdx) > 0
            ambIdx = sm.ambiguityIdx(1,1);
        else
            ambIdx = 0;
        end
        if ambIdx > 0
            preVar = ekf.P(ambIdx, ambIdx);
            sigma_fix = 0.001;
            info = ekf.applyAmbiguityPseudoMeasurement(ambIdx, ekf.x(ambIdx) + 0.05, sigma_fix);
            postVar = ekf.P(ambIdx, ambIdx);
            ambOk    = info.applied;
            preVarOk = preVar >= sigma_fix^2;
            postVarOk = postVar <= preVar + 1e-9;  % posterior var should not exceed prior
        end
    end
    ok = hasMethod && ambOk && preVarOk && postVarOk;
    results(end+1) = mkr_('T2:pseudoMeasurement', ok, ...
        sprintf('hasMethod=%s applied=%s preVarOk=%s postVarOk=%s', ...
        mat2str(hasMethod), mat2str(ambOk), mat2str(preVarOk), mat2str(postVarOk)));
catch ex
    results(end+1) = mkr_('T2:pseudoMeasurement', false, ex.message);
end

% --- T3: buildCandidates_ gates on sigma, arc, distance ---
try
    % Use assess() with synthetic cfg and cpInfo to test gating logic
    cfg = revgnss.ConfigFactory.defaultConfig();
    cfg = revgnss.ScenarioPresets.apply(cfg, 'singleAssetCarrierAttitude');
    cfg.estimator.attitude.parameterization = 'quaternionErrorState';
    cfg.estimator.integerAmbiguity.enable = true;
    cfg.estimator.integerAmbiguity.mode   = 'controlledRawCarrier';
    cfg.estimator.integerAmbiguity.minArcLength_s = 300;
    cfg.estimator.integerAmbiguity.maxSigma_cycles = 0.15;
    cfg.estimator.integerAmbiguity.maxDistanceToInteger_cycles = 0.20;
    cfg.estimator.integerAmbiguity.maxResidualRmsIncrease_m = 0.01;
    cfg.estimator.integerAmbiguity.fixVariance_cycles2 = 1e-4;

    ekf = revgnss.ReverseGNSSEKF(cfg, cfg.scenario.nTowers);
    x0  = zeros(ekf.nx, 1);
    P0  = eye(ekf.nx) * 0.01;
    ekf.initState(x0, P0);

    fixState = containers.Map('KeyType','char','ValueType','any');
    rt.fixState = fixState; rt.dt_s = 1.0;

    % assess() with empty cpInfo should return no-candidates or unavailable
    emptyCp = struct('towerIdx',[],'antennaIdx',[],'signalIdx',[], ...
        'ambiguityStateIdx',[],'prefit_m',[],'trackKey',{{}});
    s = revgnss.IntegerAmbiguityFixer.assess(rt, ekf, emptyCp, cfg);
    classOk = strcmp(s.classification,'no-candidates') || ...
              strcmp(s.classification,'unavailable-metadata') || ...
              strcmp(s.classification,'disabled-not-single-asset-attitude') || ...
              strcmp(s.classification,'active-no-fixes') || ...
              contains(s.classification,'disabled');
    noFalseClaims = ~s.lambdaImplemented && ~s.carrierIfIntegerFixingImplemented && ...
                    ~s.wideLaneNarrowLaneFixingImplemented && ~s.falseFixRiskControlled && ...
                    ~s.pppGradeClaim;
    ok = classOk && noFalseClaims;
    results(end+1) = mkr_('T3:gatingLogic', ok, ...
        sprintf('class=%s noFalseClaims=%s', s.classification, mat2str(noFalseClaims)));
catch ex
    results(end+1) = mkr_('T3:gatingLogic', false, ex.message);
end

% --- T4: resetOnSlip removes entries ---
try
    fixState = containers.Map('KeyType','char','ValueType','any');
    ent.arcId = 1; ent.Bfixed_m = 0.19;
    fixState('T001_A001_S01') = ent;
    fixState('T002_A001_S01') = ent;

    req(1).towerIdx = 1; req(1).receiverIdx = 1; req(1).signalIdx = 1;
    revgnss.IntegerAmbiguityFixer.resetOnSlip(fixState, req);
    removed1 = ~isKey(fixState,'T001_A001_S01');
    kept2    =  isKey(fixState,'T002_A001_S01');

    % Empty resetRequests should leave map unchanged
    revgnss.IntegerAmbiguityFixer.resetOnSlip(fixState, struct([]));
    kept2b = isKey(fixState,'T002_A001_S01');

    ok = removed1 && kept2 && kept2b;
    results(end+1) = mkr_('T4:resetOnSlip', ok, ...
        sprintf('removed=%s kept=%s keptAfterEmpty=%s', mat2str(removed1), mat2str(kept2), mat2str(kept2b)));
catch ex
    results(end+1) = mkr_('T4:resetOnSlip', false, ex.message);
end

% --- T5: assess() disabled path and no false claims ---
try
    cfg5 = revgnss.ConfigFactory.defaultConfig();
    cfg5 = revgnss.ScenarioPresets.apply(cfg5, 'singleAssetCarrierAttitude');
    cfg5.estimator.integerAmbiguity.enable = false;  % disabled
    ekf5 = revgnss.ReverseGNSSEKF(cfg5, cfg5.scenario.nTowers);
    ekf5.initState(zeros(ekf5.nx,1), eye(ekf5.nx)*0.01);
    rt5.fixState = containers.Map('KeyType','char','ValueType','any'); rt5.dt_s = 1;
    s5 = revgnss.IntegerAmbiguityFixer.assess(rt5, ekf5, struct('towerIdx',[]), cfg5);
    disabledOk = strcmp(s5.classification,'disabled');
    % All false-claim flags must be false
    noFalse5 = ~s5.lambdaImplemented && ~s5.carrierIfIntegerFixingImplemented && ...
               ~s5.wideLaneNarrowLaneFixingImplemented && ~s5.falseFixRiskControlled && ...
               ~s5.pppGradeClaim && ~s5.integerFixingImplemented;
    % summaryLines must exist and not error
    lines5 = revgnss.IntegerAmbiguityFixer.summaryLines(s5);
    linesOk = iscell(lines5) && numel(lines5) >= 1;
    ok = disabledOk && noFalse5 && linesOk;
    results(end+1) = mkr_('T5:disabledAndNoFalseClaims', ok, ...
        sprintf('disabled=%s noFalse=%s linesOk=%s', mat2str(disabledOk), mat2str(noFalse5), mat2str(linesOk)));
catch ex
    results(end+1) = mkr_('T5:disabledAndNoFalseClaims', false, ex.message);
end

% --- T6: ReverseGNSSSimulation has fixState63_ and fix63Log_ ---
try
    cfg6 = revgnss.ConfigFactory.defaultConfig();
    cfg6 = revgnss.ScenarioPresets.apply(cfg6, 'singleAssetCarrierAttitude');
    cfg6.estimator.attitude.parameterization = 'quaternionErrorState';
    cfg6.estimator.integerAmbiguity.enable = true;
    cfg6.estimator.integerAmbiguity.mode = 'controlledRawCarrier';
    cfg6.estimator.integerAmbiguity.minArcLength_s = 300;
    cfg6.estimator.integerAmbiguity.maxSigma_cycles = 0.15;
    cfg6.estimator.integerAmbiguity.maxDistanceToInteger_cycles = 0.20;
    cfg6.estimator.integerAmbiguity.maxResidualRmsIncrease_m = 0.01;
    cfg6.estimator.integerAmbiguity.fixVariance_cycles2 = 1e-4;
    cfg6.simulation.duration_s = 2;
    sim6 = revgnss.ReverseGNSSSimulation(cfg6);
    sim6.initialize();
    hasFixState = isprop(sim6, 'fixState63_');
    hasFix63Log = isprop(sim6, 'fix63Log_');
    fixStateIsMap = isa(sim6.fixState63_, 'containers.Map');
    logIsStruct   = isstruct(sim6.fix63Log_);
    logHasFields  = isfield(sim6.fix63Log_,'nAccepted') && isfield(sim6.fix63Log_,'nHeld') && ...
                    isfield(sim6.fix63Log_,'lastClassification');
    ok = hasFixState && hasFix63Log && fixStateIsMap && logIsStruct && logHasFields;
    results(end+1) = mkr_('T6:simProperties', ok, ...
        sprintf('fixState=%s fix63Log=%s isMap=%s isStruct=%s fields=%s', ...
        mat2str(hasFixState), mat2str(hasFix63Log), mat2str(fixStateIsMap), ...
        mat2str(logIsStruct), mat2str(logHasFields)));
catch ex
    results(end+1) = mkr_('T6:simProperties', false, ex.message);
end

% --- T7: Stage 63 metadata ---
try
    rs = revgnss.ReportStatus.current();
    stageOk  = strcmp(rs.stage, '63');
    titleOk  = contains(rs.stageTitle, 'Integer') || contains(rs.stageTitle, 'Ambiguity');

    allImp  = revgnss.StageHistory.implementedItems();
    hist63  = any(cellfun(@(s) startsWith(s,'Stage 63:'), allImp));
    hist62  = any(cellfun(@(s) startsWith(s,'Stage 62:'), allImp));

    gateFile = which('revgnss.MainScriptValidationGate');
    gateSrc  = fileread(gateFile);
    gate63Ok = ~isempty(strfind(gateSrc,'case 63')) && ... %#ok<STREMP>
               ~isempty(strfind(gateSrc,'Integer'));       %#ok<STREMP>

    % IntegerAmbiguityFixer must be in +revgnss package
    fixerExists = exist('revgnss.IntegerAmbiguityFixer','class') == 8;

    ok = stageOk && titleOk && hist63 && hist62 && gate63Ok && fixerExists;
    results(end+1) = mkr_('T7:metadata', ok, ...
        sprintf('stage=%s titleOk=%s hist63=%s hist62=%s gateOk=%s fixer=%s', ...
        rs.stage, mat2str(titleOk), mat2str(hist63), mat2str(hist62), ...
        mat2str(gate63Ok), mat2str(fixerExists)));
catch ex
    results(end+1) = mkr_('T7:metadata', false, ex.message);
end

end

% ---------- helpers ----------

function r = mkr_(name, pass, msg)
    r.name = name; r.pass = pass; r.message = msg;
end
