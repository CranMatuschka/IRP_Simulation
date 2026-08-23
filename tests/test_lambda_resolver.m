% test_lambda_resolver
% Phase 3-1 (feature/ISL-LAMBDA): the LAMBDA 4.0 wrapper.
%
% revgnss.integer.LambdaResolver turns an EKF float-ambiguity block into an integer-fixed
% vector with an explicit accept/reject decision. The ILS search is NOT reimplemented --
% the TU Delft toolbox is called as a black box.
%
% EXTERNAL DEPENDENCY: the toolbox is not vendored (TU Delft copyright, no licence grant),
% so the tests that need it SKIP when cfg.estimator.lambda.toolboxPath is unset or the
% folder is missing. The wrapper-contract tests (T1-T4, T8) always run.
%
% Proves:
%   T1  no toolbox -> FLOAT returned, decision reported, NO error (graceful degradation)
%   T2  disabled by config -> float, reported
%   T3  metres->cycles transform is correct for the vector AND the FULL covariance
%   T4  a non-PD / non-finite covariance is refused, not fixed
%   T5  [needs toolbox] a well-conditioned integer problem is FIXED correctly
%   T6  [needs toolbox] a low-success-rate problem is REJECTED (false-fix protection)
%   T7  [needs toolbox] MLAMBDA (independent McGill implementation) agrees -- oracle check
%   T8  the integer-parametrisation precondition is enforced explicitly

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir, '..');
addpath(rootDir); addpath(fullfile(rootDir, 'config'));

fprintf('=== test_lambda_resolver ===\n');

% Locate an optional local copy of the toolbox (never required to pass).
tbCandidates = { getenv('LAMBDA_TOOLBOX_PATH'), ...
                 fullfile(getenv('HOME'), 'Downloads', 'LAMBD4-master_2024_10_01') };
tbPath = '';
for c_ = 1:numel(tbCandidates)
    p_ = tbCandidates{c_};
    if ~isempty(p_) && isfolder(p_) && isfile(fullfile(p_, 'LAMBDA.m')); tbPath = p_; break; end
end
haveTb = ~isempty(tbPath);

% ----------------------------------------------------------------
% T1: no toolbox -> graceful float fallback
% ----------------------------------------------------------------
fprintf('  T1: missing toolbox degrades to float, no error ...\n');

cfg_t1 = i_lamCfg('/nonexistent/path/to/lambda', true);
aHat_t1 = [0.2; -0.3; 1.1];
Qa_t1   = diag([0.01 0.01 0.01]);
[aFix_t1, info_t1] = revgnss.integer.LambdaResolver.resolve(aHat_t1, Qa_t1, cfg_t1);
assert(~info_t1.accepted, 'T1 FAILED: accepted a fix with no toolbox');
assert(strcmp(info_t1.decision,'unavailable-toolbox'), ...
    'T1 FAILED: decision=''%s''', info_t1.decision);
assert(isequal(aFix_t1, aHat_t1), 'T1 FAILED: did not return the float vector unchanged');
fprintf('    decision=%s, float returned: PASS\n', info_t1.decision);

% ----------------------------------------------------------------
% T2: disabled by config
% ----------------------------------------------------------------
fprintf('  T2: disabled by config -> float ...\n');

cfg_t2 = i_lamCfg(tbPath, false);
[aFix_t2, info_t2] = revgnss.integer.LambdaResolver.resolve(aHat_t1, Qa_t1, cfg_t2);
assert(strcmp(info_t2.decision,'disabled-by-config'), ...
    'T2 FAILED: decision=''%s''', info_t2.decision);
assert(isequal(aFix_t2, aHat_t1), 'T2 FAILED: float not returned');
fprintf('    decision=%s: PASS\n', info_t2.decision);

% ----------------------------------------------------------------
% T3: metres -> cycles, vector AND full covariance
% ----------------------------------------------------------------
fprintf('  T3: metres->cycles transform (full covariance) ...\n');

lam_t3  = [0.1903; 0.2442];                 % L1, L2-ish
aM_t3   = [1.903; 2.442];                   % exactly 10 cycles each
QaM_t3  = [4e-4, 1e-4; 1e-4, 9e-4];
[aC_t3, QaC_t3] = revgnss.integer.LambdaResolver.toCycles(aM_t3, QaM_t3, lam_t3);

assert(max(abs(aC_t3 - [10;10])) < 1e-9, ...
    'T3 FAILED: cycles vector %s, expected [10;10]', mat2str(round(aC_t3,6)));
D_t3 = diag(1./lam_t3);
QaExp_t3 = D_t3 * QaM_t3 * D_t3';
assert(max(abs(QaC_t3(:) - QaExp_t3(:))) < 1e-12, 'T3 FAILED: covariance transform wrong');
% the OFF-diagonal must survive -- ILS decorrelation depends on it
assert(abs(QaC_t3(1,2)) > 1e-9, 'T3 FAILED: off-diagonal lost in the transform');
assert(abs(QaC_t3(1,2) - QaC_t3(2,1)) < 1e-15, 'T3 FAILED: result not symmetric');
fprintf('    a=[10 10] cyc, off-diagonal preserved (%.4g): PASS\n', QaC_t3(1,2));

% ----------------------------------------------------------------
% T4: degenerate covariance refused
% ----------------------------------------------------------------
fprintf('  T4: non-PD / non-finite covariance refused ...\n');

cfg_t4 = i_lamCfg(tbPath, true);
[~, i_npd] = revgnss.integer.LambdaResolver.resolve([0.1;0.2], [1 1; 1 1], cfg_t4);
[~, i_nan] = revgnss.integer.LambdaResolver.resolve([0.1;NaN], eye(2)*0.01, cfg_t4);
if haveTb
    assert(strcmp(i_npd.decision,'reject-notPositiveDefinite'), ...
        'T4 FAILED: singular Qa gave ''%s''', i_npd.decision);
    assert(strcmp(i_nan.decision,'reject-nonfinite'), ...
        'T4 FAILED: NaN input gave ''%s''', i_nan.decision);
else
    assert(~i_npd.accepted && ~i_nan.accepted, 'T4 FAILED: accepted a degenerate problem');
end
fprintf('    singular -> %s, NaN -> %s: PASS\n', i_npd.decision, i_nan.decision);

% ----------------------------------------------------------------
% T5-T7 need the external toolbox
% ----------------------------------------------------------------
if ~haveTb
    fprintf('  T5-T7: LAMBDA toolbox not found -> SKIP (external dependency)\n');
    fprintf('         set LAMBDA_TOOLBOX_PATH to enable these checks.\n');
else
    cfg_tb = i_lamCfg(tbPath, true);
    assert(revgnss.integer.LambdaResolver.isAvailable(cfg_tb), ...
        'setup FAILED: toolbox at %s not detected', tbPath);

    % ---- T5: a well-conditioned integer problem is fixed correctly ----
    fprintf('  T5: well-conditioned problem is fixed correctly ...\n');
    nTrue_t5 = [3; -7; 12; 5];
    Qa_t5 = 1e-4 * [ 1.0 0.2 0.1 0.0
                     0.2 1.0 0.2 0.1
                     0.1 0.2 1.0 0.2
                     0.0 0.1 0.2 1.0 ];          % ~1 cm-level, mildly correlated
    aHat_t5 = nTrue_t5 + [0.08; -0.06; 0.05; -0.09];   % sub-half-cycle float errors
    [aFix_t5, info_t5] = revgnss.integer.LambdaResolver.resolve(aHat_t5, Qa_t5, cfg_tb);
    assert(info_t5.accepted, 'T5 FAILED: not accepted (decision=%s, SR=%.6f)', ...
        info_t5.decision, info_t5.successRate);
    assert(isequal(round(aFix_t5), nTrue_t5), ...
        'T5 FAILED: fixed %s, expected %s', mat2str(round(aFix_t5)'), mat2str(nTrue_t5'));
    fprintf('    fixed %s, SR=%.6f, ratio=%.2f: PASS\n', ...
        mat2str(round(aFix_t5)'), info_t5.successRate, info_t5.ratio);

    % ---- T6: low success rate is REJECTED (false-fix protection) ----
    fprintf('  T6: low-success-rate problem is rejected ...\n');
    Qa_t6   = 0.25 * eye(4);                  % sigma = 0.5 cycles -> hopeless
    aHat_t6 = [0.5; 0.5; 0.5; 0.5];
    [aFix_t6, info_t6] = revgnss.integer.LambdaResolver.resolve(aHat_t6, Qa_t6, cfg_tb);
    assert(~info_t6.accepted, 'T6 FAILED: accepted a fix at SR=%.6f', info_t6.successRate);
    assert(strcmp(info_t6.decision,'reject-lowSuccessRate'), ...
        'T6 FAILED: decision=''%s'' (expected reject-lowSuccessRate)', info_t6.decision);
    assert(isequal(aFix_t6, aHat_t6), 'T6 FAILED: float not returned on rejection');
    fprintf('    SR=%.4f < %.3f -> %s: PASS\n', ...
        info_t6.successRate, info_t6.minSuccessRate, info_t6.decision);

    % ---- T7: MLAMBDA oracle cross-check ----
    fprintf('  T7: MLAMBDA (independent implementation) agrees ...\n');
    if isempty(which('mlambda'))
        fprintf('    mlambda.m not on path: SKIP\n');
    else
        Xm_t7 = mlambda(Qa_t5, aHat_t5, 1);
        assert(isequal(round(Xm_t7(:,1)), round(aFix_t5)), ...
            ['T7 FAILED: LAMBDA fixed %s but MLAMBDA fixed %s -- two independent ILS ' ...
             'implementations disagree.'], ...
            mat2str(round(aFix_t5)'), mat2str(round(Xm_t7(:,1))'));
        fprintf('    LAMBDA == MLAMBDA == %s: PASS\n', mat2str(round(Xm_t7(:,1))'));
    end
end

% ----------------------------------------------------------------
% T8: the integer-parametrisation precondition is explicit
% ----------------------------------------------------------------
fprintf('  T8: non-integer parametrisation is refused at the call site ...\n');

threw_t8 = false; id_t8 = '';
try
    revgnss.integer.LambdaResolver.assertIntegerParametrisation(false, ...
        'undifferenced ISL ambiguity');
catch ME_t8
    threw_t8 = true; id_t8 = ME_t8.identifier;
end
assert(threw_t8, 'T8 FAILED: undifferenced vector was not refused');
assert(strcmp(id_t8,'LambdaResolver:nonIntegerParametrisation'), ...
    'T8 FAILED: identifier ''%s''', id_t8);
revgnss.integer.LambdaResolver.assertIntegerParametrisation(true, 'between-antenna DD');
fprintf('    threw %s for undifferenced, passed for DD: PASS\n', id_t8);

fprintf('=== test_lambda_resolver: ALL PASS ===\n');

% ----------------------------------------------------------------
function cfg = i_lamCfg(tbPath, enable)
    cfg = struct();
    cfg.estimator.lambda.enable         = enable;
    cfg.estimator.lambda.toolboxPath    = tbPath;
    cfg.estimator.lambda.method         = 3;
    cfg.estimator.lambda.nCands         = 2;
    cfg.estimator.lambda.minSuccessRate = 0.999;
    cfg.estimator.lambda.ratioThreshold = 2.0;
end
