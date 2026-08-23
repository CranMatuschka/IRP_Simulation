% test_baseline_ambiguity_lambda
% Phase 3-3 (feature/ISL-LAMBDA): LAMBDA applied to the attitude-baseline fix (Route A).
%
% Between-antenna single differencing cancels BOTH the receiver and the tower clock, so the
% differential ambiguity dN is a TRUE INTEGER -- the only integer-ready parametrisation in
% this codebase, and therefore the right place to exercise the LAMBDA engine on live data.
%
% THE SCIENTIFIC POINT OF THIS TEST (read before "improving" anything):
%   BaselineCarrierAmbiguityResolver resolves each (tower, baseline) INDEPENDENTLY, so the
%   float ambiguities have a DIAGONAL covariance. For a diagonal Qa, integer least squares
%   provably degenerates to bootstrapping and to plain ROUNDING -- the Z-transformation has
%   nothing to decorrelate. LAMBDA therefore CANNOT return different integers here, and any
%   claim that "adding LAMBDA improved the attitude fix" would be false.
%   T2 PINS that agreement instead of hoping for it.
%
%   The real contribution is what the existing resolver explicitly lacks: it reports
%   falseFixClassification='screenedNotFormal' (gates, but no formal false-fix probability).
%   Ps_LAMBDA supplies a rigorous bootstrapped success rate + failure rate, upgrading the
%   decision from heuristic screening to quantified risk. T3 pins that.
%
% Proves:
%   T1  default OFF -> inert, and the ground gate is INDEPENDENT of the ISL gate
%   T2  [needs toolbox] LAMBDA agrees with the existing per-baseline fix (diagonal Qa)
%   T3  [needs toolbox] a FORMAL success/failure rate is produced (the actual upgrade)
%   T4  [needs toolbox] a noisy (low-SR) baseline set is REJECTED, not fixed
%   T5  the covariance structure is honestly declared as diagonal/separable

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir, '..');
addpath(rootDir); addpath(fullfile(rootDir, 'config'));

fprintf('=== test_baseline_ambiguity_lambda ===\n');

tbCandidates = { getenv('LAMBDA_TOOLBOX_PATH'), ...
                 fullfile(getenv('HOME'), 'Downloads', 'LAMBD4-master_2024_10_01') };
tbPath = '';
for c_ = 1:numel(tbCandidates)
    p_ = tbCandidates{c_};
    if ~isempty(p_) && isfolder(p_) && isfile(fullfile(p_, 'LAMBDA.m')); tbPath = p_; break; end
end
haveTb = ~isempty(tbPath);

lamL1 = revgnss.SignalDefinition.get('L1').wavelength_m;

% ----------------------------------------------------------------
% T1: default OFF, and ground/ISL gates are independent
% ----------------------------------------------------------------
fprintf('  T1: default OFF; ground gate independent of ISL gate ...\n');

store_t1 = i_store([3 -7 12 5], lamL1, 0.004, 200);

cfg_off = i_cfg(tbPath, false, false, false);
s_off = revgnss.integer.BaselineAmbiguityLambda.assess(store_t1, cfg_off);
assert(~s_off.enabled, 'T1 FAILED: enabled with the master gate off');
assert(strcmp(s_off.classification,'disabled-by-config'), ...
    'T1 FAILED: classification=''%s''', s_off.classification);

% ISL gate ON but GROUND gate OFF -> the ground assessment must stay inert
cfg_islOnly = i_cfg(tbPath, true, false, true);
s_islOnly = revgnss.integer.BaselineAmbiguityLambda.assess(store_t1, cfg_islOnly);
assert(~s_islOnly.enabled, ...
    'T1 FAILED: ground assessment ran while only the ISL gate was on (gates not independent)');

% GROUND gate ON -> runs regardless of the ISL gate
cfg_gndOnly = i_cfg(tbPath, true, true, false);
s_gndOnly = revgnss.integer.BaselineAmbiguityLambda.assess(store_t1, cfg_gndOnly);
assert(s_gndOnly.enabled, 'T1 FAILED: ground gate on but assessment did not run');
fprintf('    master OFF inert; ISL-only inert; ground-only runs: PASS\n');

% ----------------------------------------------------------------
% T5 (checked early, needs no toolbox): honest covariance declaration
% ----------------------------------------------------------------
fprintf('  T5: covariance structure declared as diagonal/separable ...\n');
assert(strcmp(s_gndOnly.covarianceStructure,'diagonal-separablePerBaseline'), ...
    'T5 FAILED: covarianceStructure=''%s''', s_gndOnly.covarianceStructure);
fprintf('    ''%s'': PASS\n', s_gndOnly.covarianceStructure);

if ~haveTb
    fprintf('  T2-T4: LAMBDA toolbox not found -> SKIP (external dependency)\n');
    fprintf('         set LAMBDA_TOOLBOX_PATH to enable these checks.\n');
    fprintf('=== test_baseline_ambiguity_lambda: ALL PASS ===\n');
    return
end

cfg_on = i_cfg(tbPath, true, true, false);

% ----------------------------------------------------------------
% T2: LAMBDA agrees with the existing per-baseline fix (diagonal Qa)
% ----------------------------------------------------------------
fprintf('  T2: LAMBDA agrees with the existing rounding fix (diagonal Qa) ...\n');

nTrue_t2 = [3 -7 12 5 -2 9];
store_t2 = i_store(nTrue_t2, lamL1, 0.004, 200);    % 4 mm scatter, 200 epochs -> tight
s_t2 = revgnss.integer.BaselineAmbiguityLambda.assess(store_t2, cfg_on);

assert(s_t2.available, 'T2 FAILED: toolbox not detected at %s', tbPath);
assert(s_t2.accepted, 'T2 FAILED: not accepted (%s, SR=%.6f)', s_t2.decision, s_t2.successRate);
assert(isequal(s_t2.lambdaIntegers, nTrue_t2), ...
    'T2 FAILED: LAMBDA fixed %s, truth %s', mat2str(s_t2.lambdaIntegers), mat2str(nTrue_t2));
assert(s_t2.agrees, ...
    ['T2 FAILED: LAMBDA %s disagrees with the existing fix %s. For a DIAGONAL Qa, ILS ' ...
     'provably equals rounding -- a disagreement means one of them is wrong.'], ...
    mat2str(s_t2.lambdaIntegers), mat2str(s_t2.existingIntegers));
assert(strcmp(s_t2.classification,'agrees-formalSuccessRate'), ...
    'T2 FAILED: classification=''%s''', s_t2.classification);
fprintf('    LAMBDA == existing == %s (%d baselines): PASS\n', ...
    mat2str(s_t2.lambdaIntegers), s_t2.n);

% ----------------------------------------------------------------
% T3: a FORMAL success/failure rate is produced (the actual upgrade)
% ----------------------------------------------------------------
fprintf('  T3: formal success/failure rate replaces ''screenedNotFormal'' ...\n');

assert(isfinite(s_t2.successRate) && s_t2.successRate > 0 && s_t2.successRate <= 1, ...
    'T3 FAILED: successRate=%.6g is not a probability', s_t2.successRate);
assert(isfinite(s_t2.failureRate) && s_t2.failureRate >= 0, ...
    'T3 FAILED: failureRate=%.6g invalid', s_t2.failureRate);
assert(s_t2.successRate >= 0.999, ...
    'T3 FAILED: SR=%.6f below the configured floor for a tight problem', s_t2.successRate);
assert(isfinite(s_t2.meanSigma_cycles) && s_t2.meanSigma_cycles > 0, ...
    'T3 FAILED: sigma not reported');
fprintf('    SR=%.6f FR=%.2e, sigma mean %.5f cyc: PASS\n', ...
    s_t2.successRate, s_t2.failureRate, s_t2.meanSigma_cycles);

% ----------------------------------------------------------------
% T4: a low-success-rate baseline set is REJECTED, not fixed
% ----------------------------------------------------------------
fprintf('  T4: noisy baselines are rejected, not fixed ...\n');

store_t4 = i_store(nTrue_t2, lamL1, 0.9 * lamL1, 3);   % ~0.9 cycle scatter, 3 epochs
s_t4 = revgnss.integer.BaselineAmbiguityLambda.assess(store_t4, cfg_on);
assert(~s_t4.accepted, ...
    'T4 FAILED: accepted a fix at SR=%.6f (sigma %.3f cyc)', ...
    s_t4.successRate, s_t4.meanSigma_cycles);
assert(contains(s_t4.classification,'notFixed'), ...
    'T4 FAILED: classification=''%s''', s_t4.classification);
fprintf('    sigma %.3f cyc -> SR=%.4f -> %s: PASS\n', ...
    s_t4.meanSigma_cycles, s_t4.successRate, s_t4.decision);

fprintf('=== test_baseline_ambiguity_lambda: ALL PASS ===\n');

% ----------------------------------------------------------------
function store = i_store(nTrue, lam, sigma_m, nEp)
    % Synthetic DiffAttitudeBuilder-shaped accumulator store: one tower row, one
    % baseline per element of nTrue, with S1/S2 consistent with nEp samples of
    % (lam*N + noise) at the given per-epoch scatter.
    nB = numel(nTrue);
    store = struct();
    store.nTowers    = 1;
    store.nBaselines = nB;
    store.accumN     = repmat(nEp, 1, nB);
    store.accumSum   = zeros(1, nB);
    store.accumSumSq = zeros(1, nB);
    store.N_int      = zeros(1, nB);
    for b = 1:nB
        mu = lam * nTrue(b);                 % true differential ambiguity [m]
        store.accumSum(1,b)   = nEp * mu;                       % sum of samples
        store.accumSumSq(1,b) = nEp * (mu^2 + sigma_m^2);       % sum of squares
        store.N_int(1,b)      = nTrue(b);    % what the existing resolver fixed
    end
end

function cfg = i_cfg(tbPath, masterOn, groundOn, islOn)
    cfg = struct();
    % A carrier frequency has ONE owner and it is the config (there is deliberately no
    % canonical-catalogue fallback any more -- that fallback is what let the freq ladder
    % run five bands at one wavelength). A hand-built config must therefore declare its
    % signals, so take them from the owner rather than restating a frequency here.
    cfg.signals = masterConfig().signals;
    cfg.estimator.lambda.enable         = masterOn;
    cfg.estimator.lambda.ground.enable  = groundOn;
    cfg.estimator.lambda.isl.enable     = islOn;
    cfg.estimator.lambda.toolboxPath    = tbPath;
    cfg.estimator.lambda.method         = 3;
    cfg.estimator.lambda.nCands         = 2;
    cfg.estimator.lambda.minSuccessRate = 0.999;
    cfg.estimator.lambda.ratioThreshold = 2.0;
end
