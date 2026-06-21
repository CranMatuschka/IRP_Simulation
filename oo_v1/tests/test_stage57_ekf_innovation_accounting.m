function results = test_stage57_ekf_innovation_accounting()
% test_stage57_ekf_innovation_accounting  Stage 57 smoke tests.
%
% T1: NIS split math — physical + gauge decomposition
% T2: DOF split — physical and gauge DOF sum to augmented DOF
% T3: Residual RMS split — physical and gauge RMS computable
% T4: Empty masks — graceful handling when no gauge or no rows of a type
% T5: No false claims — verify Stage 57 flags in compact output
% T6: Source migration — EkfInnovationAccounting class exists and has required methods

results = struct('name',{},'pass',{},'message',{});

% T1: NIS split math
try
    y_phys  = [1; -2; 0.5];
    y_gauge = [0.1; -0.3];
    y_aug   = [y_phys; y_gauge];
    S_aug   = eye(5);  % identity for simple NIS = y'*y

    rowClass = revgnss.EkfInnovationAccounting.classifyRows({'code','doppler','carrier'}, 3, 2);
    acc      = revgnss.EkfInnovationAccounting.compute(y_aug, S_aug, rowClass);

    expected_phys = y_phys' * y_phys;
    expected_aug  = y_aug'  * y_aug;

    ok = abs(acc.physicalNIS  - expected_phys) < 1e-10 && ...
         abs(acc.augmentedNIS - expected_aug)  < 1e-10 && ...
         isfinite(acc.gaugeNIS);
    results(end+1) = makeResult('T1_NIS_split_math', ok, ...
        sprintf('physNIS=%.4f (exp %.4f) augNIS=%.4f (exp %.4f)', ...
        acc.physicalNIS, expected_phys, acc.augmentedNIS, expected_aug));
catch ME
    results(end+1) = makeResult('T1_NIS_split_math', false, ME.message);
end

% T2: DOF split
try
    nPhys  = 4;
    nGauge = 2;
    mtype  = {'code','code','doppler','carrier'};
    rc     = revgnss.EkfInnovationAccounting.classifyRows(mtype, nPhys, nGauge);
    y      = randn(6, 1);
    S      = eye(6) * 0.5;
    acc    = revgnss.EkfInnovationAccounting.compute(y, S, rc);

    ok = (acc.physicalDof == nPhys) && (acc.gaugeDof == nGauge) && ...
         (acc.augmentedDof == nPhys + nGauge) && ...
         (acc.codeDof == 2) && (acc.dopplerDof == 1) && (acc.carrierDof == 1);
    results(end+1) = makeResult('T2_DOF_split', ok, ...
        sprintf('physDof=%d gaugeDof=%d augDof=%d codeDof=%d', ...
        acc.physicalDof, acc.gaugeDof, acc.augmentedDof, acc.codeDof));
catch ME
    results(end+1) = makeResult('T2_DOF_split', false, ME.message);
end

% T3: Residual RMS split
try
    y_aug  = [1; 2; -3; 0.5; -0.5];
    mtype  = {'code','carrier','doppler'};
    rc     = revgnss.EkfInnovationAccounting.classifyRows(mtype, 3, 2);
    rms_   = revgnss.EkfInnovationAccounting.residualRms(y_aug, rc);

    exp_phys = sqrt(mean([1;2;-3].^2));
    exp_aug  = sqrt(mean(y_aug.^2));
    ok = abs(rms_.physicalRms - exp_phys) < 1e-10 && ...
         abs(rms_.augmentedRms - exp_aug) < 1e-10 && ...
         isfinite(rms_.gaugeRms) && isfinite(rms_.codeRms);
    results(end+1) = makeResult('T3_residual_RMS_split', ok, ...
        sprintf('physRms=%.4f (exp %.4f) augRms=%.4f (exp %.4f)', ...
        rms_.physicalRms, exp_phys, rms_.augmentedRms, exp_aug));
catch ME
    results(end+1) = makeResult('T3_residual_RMS_split', false, ME.message);
end

% T4: Empty masks — no gauge rows
try
    mtype  = {'code','code'};
    rc     = revgnss.EkfInnovationAccounting.classifyRows(mtype, 2, 0);
    y_aug  = [1; -1];
    S_aug  = eye(2);
    acc    = revgnss.EkfInnovationAccounting.compute(y_aug, S_aug, rc);
    rms_   = revgnss.EkfInnovationAccounting.residualRms(y_aug, rc);
    c      = revgnss.EkfInnovationAccounting.compact(acc, rms_);

    ok = rc.nGauge == 0 && acc.gaugeDof == 0 && isnan(acc.gaugeNIS) && ...
         ~c.gaugeRowsPresent && isfinite(acc.physicalNIS) && isnan(rms_.gaugeRms);
    results(end+1) = makeResult('T4_empty_masks', ok, ...
        sprintf('gaugeDof=%d gaugeNIS=%s gaugeRowsPresent=%d', ...
        rc.gaugeDof, mat2str(acc.gaugeNIS), c.gaugeRowsPresent));
catch ME
    results(end+1) = makeResult('T4_empty_masks', false, ME.message);
end

% T5: No false claims — compact output has correct flags
try
    mtype  = {'code','doppler'};
    rc     = revgnss.EkfInnovationAccounting.classifyRows(mtype, 2, 1);
    y_aug  = [0.5; -0.2; 0.01];
    S_aug  = diag([0.04, 0.01, 0.0001]);
    acc    = revgnss.EkfInnovationAccounting.compute(y_aug, S_aug, rc);
    rms_   = revgnss.EkfInnovationAccounting.residualRms(y_aug, rc);
    c      = revgnss.EkfInnovationAccounting.compact(acc, rms_);

    % Stage 57 must never claim integer fixing, LAMBDA, or PPP
    hasIntFix   = isfield(c,'integerFixing')   && c.integerFixing;
    hasLambda   = isfield(c,'lambdaEnabled')   && c.lambdaEnabled;
    hasFalsefix = isfield(c,'falseFixRisk')    && c.falseFixRisk;
    noFalseClaims = ~hasIntFix && ~hasLambda && ~hasFalsefix;

    ok = noFalseClaims && c.gaugeRowsPresent && ...
         ischar(c.accountingClassification) && ...
         strcmp(c.accountingClassification, 'physical-plus-gauge');
    results(end+1) = makeResult('T5_no_false_claims', ok, ...
        sprintf('noFalseClaims=%d gaugePresent=%d class=%s', ...
        noFalseClaims, c.gaugeRowsPresent, c.accountingClassification));
catch ME
    results(end+1) = makeResult('T5_no_false_claims', false, ME.message);
end

% T6: Source migration — EkfInnovationAccounting has required static methods
try
    m = meta.class.fromName('revgnss.EkfInnovationAccounting');
    ok = ~isempty(m);
    if ok
        names = {m.MethodList.Name};
        ok = all(ismember({'classifyRows','compute','residualRms','compact'}, names));
    end
    results(end+1) = makeResult('T6_class_has_required_methods', ok, ...
        'EkfInnovationAccounting has classifyRows/compute/residualRms/compact');
catch ME
    results(end+1) = makeResult('T6_class_has_required_methods', false, ME.message);
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
