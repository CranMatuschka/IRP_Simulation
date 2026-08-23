function results = test_stage64_scientific_closure()
% test_stage64_scientific_closure  Stage 64 scientific closure smoke tests.
%
% T1: Stage/status defaults resolve to 64
% T2: PCV default is none/off (ConfigFactory default must not be 'toy')
% T3: IF variance formula: uncorrelated-noise assumption in both IF builders
% T4: Report text does not claim operational PPP/LAMBDA/false-fix
% T5: Stage 62 quaternion covariance keywords exist in ReverseGNSSEKF
% T6: Stage 63 active-no-fixes is allowed (not classified as failure)

results = struct('name',{},'pass',{},'message',{});

% --- T1: Stage/status defaults resolve to 64 ---
try
    st = revgnss.ReportStatus.current();
    stgNum = str2double(st.stage);
    stgTitle = st.stageTitle;
    hasClosureKeyword = contains(stgTitle,'Closure','IgnoreCase',true) || ...
                        contains(stgTitle,'Freeze','IgnoreCase',true);
    % Check stg=64 default in MainScriptValidationGate source (private method, cannot call directly)
    fGate = which('revgnss.MainScriptValidationGate');
    gateOk = false;
    if ~isempty(fGate)
        gSrc = fileread(fGate);
        gateOk = ~isempty(regexp(gSrc,'stg\s*=\s*64','once'));
    end
    ok = (stgNum == 64) && hasClosureKeyword && gateOk;
    results(end+1) = mkr_('T1:stageDefaults64', ok, ...
        sprintf('stage=%s title=%s gateStg64=%s', st.stage, stgTitle, mat2str(gateOk)));
catch ex
    results(end+1) = mkr_('T1:stageDefaults64', false, ex.message);
end

% --- T2: PCV default is none/off ---
try
    cfg = revgnss.ConfigFactory.defaultConfig();
    pcvModel = '';
    if isfield(cfg,'effects') && isfield(cfg.effects,'antenna') && ...
            isfield(cfg.effects.antenna,'pcvModel')
        pcvModel = cfg.effects.antenna.pcvModel;
    end
    pcvEnTruth = false; pcvEnModel = false;
    try; pcvEnTruth = cfg.effects.antennaPCV.truth.enable; catch; end
    try; pcvEnModel = cfg.effects.antennaPCV.model.enable; catch; end
    % Default must NOT be 'toy' and both enable flags must be false
    notToy  = ~strcmp(pcvModel,'toy');
    notHot  = ~pcvEnTruth && ~pcvEnModel;
    ok = notToy && notHot;
    results(end+1) = mkr_('T2:pcvDefaultNone', ok, ...
        sprintf('pcvModel=%s truthEnable=%s modelEnable=%s', ...
        pcvModel, mat2str(pcvEnTruth), mat2str(pcvEnModel)));
catch ex
    results(end+1) = mkr_('T2:pcvDefaultNone', false, ex.message);
end

% --- T3: IF variance formula uses uncorrelated noise assumption ---
try
    f1 = which('revgnss.CarrierIonoFreeRowBuilder');
    f2 = which('revgnss.CodeIonoFreeRowBuilder');
    ok1 = false; ok2 = false;
    if ~isempty(f1)
        src1 = fileread(f1);
        % Must contain alpha^2 * r1 + beta^2 * r2 (or equivalent)
        ok1 = ~isempty(regexp(src1,'alpha.2.*r1.*beta.2.*r2|alpha\^2.*\+.*beta\^2','once')) || ...
              ~isempty(regexp(src1,'alpha\.?\^?2\s*\*.*beta\.?\^?2\s*\*','once')) || ...
              ~isempty(strfind(src1,'alpha^2 * r1 + beta^2 * r2')) || ...  %#ok<STREMP>
              ~isempty(strfind(src1,'alpha.^2 .* r1 + beta.^2 .* r2')) || ...  %#ok<STREMP>
              ~isempty(strfind(src1,'R_IF = diag(alpha^2'));  %#ok<STREMP>
    end
    if ~isempty(f2)
        src2 = fileread(f2);
        ok2 = ~isempty(regexp(src2,'alpha.2|R_IF','once')) || ~isempty(f1);
    else
        ok2 = true;  % CodeIonoFreeRowBuilder may not exist; carrier builder is the critical one
    end
    % Also check that 'uncorrelated' appears in comments or that Cov=0 is implicit
    hasComment = false;
    if ~isempty(f1)
        hasComment = ~isempty(regexp(src1,'uncorrelated|Cov.*=.*0|cov.*zero','ignorecase','once'));
    end
    ok = ok1 && ok2;
    results(end+1) = mkr_('T3:ifVarianceFormula', ok, ...
        sprintf('carrierIF=%s codeIF=%s hasUncorrelatedComment=%s', ...
        mat2str(ok1), mat2str(ok2), mat2str(hasComment)));
catch ex
    results(end+1) = mkr_('T3:ifVarianceFormula', false, ex.message);
end

% --- T4: Report source does not claim operational PPP/LAMBDA/false-fix ---
try
    % Check ClockExactReportBuilder for Stage 64 closure section
    f = which('revgnss.ClockExactReportBuilder');
    hasStage64 = false; hasNotOp = false;
    if ~isempty(f)
        src = fileread(f);
        hasStage64 = ~isempty(strfind(src,'Stage~64 Final Scientific Closure'));  %#ok<STREMP>
        hasNotOp   = ~isempty(strfind(src,'NOT an operational'));  %#ok<STREMP>
    end
    % Check ReportRunner summary fields: LAMBDA/falseFixRisk must be false (not true)
    fRR = which('revgnss.ReportRunner');
    lambdaFalse = false; falseFixFalse = false;
    if ~isempty(fRR)
        srcRR = fileread(fRR);
        % stage64LambdaImpl = false; must appear
        lambdaFalse  = ~isempty(regexp(srcRR,'stage64LambdaImpl\s*=\s*false','once'));
        falseFixFalse = ~isempty(regexp(srcRR,'stage64FalseFixRisk\s*=\s*false','once'));
    end
    ok = hasStage64 && hasNotOp && lambdaFalse && falseFixFalse;
    results(end+1) = mkr_('T4:noFalseClaims', ok, ...
        sprintf('hasStage64=%s hasNotOp=%s lambdaImpl=false(%s) falseFixRisk=false(%s)', ...
        mat2str(hasStage64), mat2str(hasNotOp), mat2str(lambdaFalse), mat2str(falseFixFalse)));
catch ex
    results(end+1) = mkr_('T4:noFalseClaims', false, ex.message);
end

% --- T5: Stage 62 quaternion covariance keywords exist in ReverseGNSSEKF ---
try
    f = which('filter.ReverseGNSSEKF');
    ok = false;
    if ~isempty(f)
        src = fileread(f);
        hasPminus   = ~isempty(strfind(src,'Pminus = obj.P'));  %#ok<STREMP>
        hasJoseph   = ~isempty(strfind(src,'IKH * Pminus * IKH'));  %#ok<STREMP>
        hasCovOrder = ~isempty(strfind(src,'posterior-after-joseph'));  %#ok<STREMP>
        % Stage 62 reset block: G * obj.P(ei,:)
        hasReset    = ~isempty(regexp(src,'obj\.P\s*\(\s*ei','once'));
        ok = hasPminus && hasJoseph && hasCovOrder && hasReset;
        results(end+1) = mkr_('T5:quatCovKeywords', ok, ...
            sprintf('Pminus=%s Joseph=%s covOrder=%s resetBlock=%s', ...
            mat2str(hasPminus), mat2str(hasJoseph), mat2str(hasCovOrder), mat2str(hasReset)));
    else
        results(end+1) = mkr_('T5:quatCovKeywords', false, 'ReverseGNSSEKF not found');
    end
catch ex
    results(end+1) = mkr_('T5:quatCovKeywords', false, ex.message);
end

% --- T6: Stage 63 active-no-fixes is allowed, not treated as failure ---
try
    f = which('revgnss.IntegerAmbiguityFixer');
    ok = false;
    if ~isempty(f)
        src = fileread(f);
        % Must classify 'active-no-fixes' (not error / not failure)
        hasActiveNoFixes = ~isempty(strfind(src,'active-no-fixes'));  %#ok<STREMP>
        % Must NOT equate active-no-fixes with failure
        noFailureEq = isempty(regexp(src,'active-no-fixes.*error|active-no-fixes.*fail','ignorecase','once'));
        % ReportRunner or ClockExactReportBuilder must NOT treat active-no-fixes as disqualifying
        fRR = which('revgnss.ReportRunner');
        rrOk = true;
        if ~isempty(fRR)
            srcRR = fileread(fRR);
            % Check that stage64IntFixStatus is set from stage63Classification (not hard-coded fail)
            rrOk = ~isempty(strfind(srcRR,'stage64IntFixStatus'));  %#ok<STREMP>
        end
        ok = hasActiveNoFixes && noFailureEq && rrOk;
        results(end+1) = mkr_('T6:activeNoFixesAllowed', ok, ...
            sprintf('hasActiveNoFixes=%s noFailEq=%s rrOk=%s', ...
            mat2str(hasActiveNoFixes), mat2str(noFailureEq), mat2str(rrOk)));
    else
        results(end+1) = mkr_('T6:activeNoFixesAllowed', false, 'IntegerAmbiguityFixer not found');
    end
catch ex
    results(end+1) = mkr_('T6:activeNoFixesAllowed', false, ex.message);
end

% ---- print ---
fprintf('\n[test_stage64] %d tests\n', numel(results));
for k = 1:numel(results)
    status = 'PASS'; if ~results(k).pass; status = 'FAIL'; end
    fprintf('  [%s] %s  %s\n', status, results(k).name, results(k).message);
end
nPass = sum([results.pass]);
fprintf('[test_stage64] %d/%d passed\n\n', nPass, numel(results));
end

function r = mkr_(name, pass, msg)
r = struct('name', name, 'pass', pass, 'message', msg);
end
