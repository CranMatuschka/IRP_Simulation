% test_orekit_lambda_integer_crossvalidation
%
% LEVEL C (part 1) -- integer ambiguity resolution: the sim's LAMBDA path
% (revgnss.integer.LambdaResolver -> TU Delft LAMBDA 4.0) vs Orekit 13.1.7's own
% independent integer-least-squares implementations
% (org.orekit.estimation.measurements.gnss.LambdaMethod / ModifiedLambdaMethod).
%
% WHY THIS IS A SHARP TEST: integer least squares has a UNIQUE answer. Given the same
% float vector aHat and the same covariance Qa, every correct ILS implementation must
% return the SAME integer vector and the SAME squared distance. There is no tolerance
% argument and no model-choice defence -- a disagreement is a bug in one of the two.
% Both sides also decorrelate first (LAMBDA's Z-transform; Orekit's LTDL reduction), so
% this exercises the reduction, the search tree, and the objective, not just rounding.
%
%   PART A -- ILS agreement over randomised problems: dimensions 2..8, strongly
%     correlated covariances built as Q = L*D*L' with a wide eigenvalue spread, so that
%     naive per-component rounding is often WRONG. The count of trials where rounding
%     disagrees with ILS is reported and asserted non-zero -- otherwise the comparison
%     would be trivially satisfied by both sides rounding, and would prove nothing.
%
%   PART B -- the runner-up candidate: LAMBDA's second-best squared norm feeds the
%     resolver's ratio (discrimination) test, so it is compared against Orekit's
%     second IntegerLeastSquareSolution. A wrong runner-up silently mis-scales every
%     accept/reject decision the resolver makes. Because a majority vote between two
%     libraries cannot settle a disagreement, an independent THIRD arbiter is used for
%     n <= 6: exhaustive enumeration of every integer vector in a +/-3 box around the
%     float solution, scored directly as (a-aHat)'*inv(Qa)*(a-aHat). That is ground
%     truth, not another search heuristic.
%
%     MEASURED RESULT: the TU Delft toolbox reproduces the exhaustive top-2 exactly in
%     every trial. Orekit's LambdaMethod always returns the correct BEST solution, but in
%     ~2% of the hard 6-D problems its SECOND candidate is the true third-best -- its
%     multi-candidate search dropped the genuine runner-up. Consequence, for the record:
%     a runner-up that is too EXPENSIVE inflates the ratio sqnorm(2)/sqnorm(1) and makes a
%     ratio test more permissive, i.e. it biases toward accepting false fixes. The sim's
%     path is the correct one here, so this is documented, not worked around.
%
%   PART C -- the production entry point: revgnss.integer.LambdaResolver.resolve()
%     itself (not raw LAMBDA), with its gates opened, must return Orekit's integer vector.
%     This validates the wrapper -- cycle scaling, symmetrisation, candidate ordering --
%     rather than only the toolbox underneath it.
%
% REQUIREMENTS / SKIP: JVM-enabled MATLAB (`matlab -batch`, not the -nojvm MCP session),
% the Orekit bridge at ~/orekit-bridge, AND the TU Delft LAMBDA 4.0 toolbox (an external
% dependency, see docs/LAMBDA_SETUP.md). Skips cleanly if any is absent.

fprintf('test_orekit_lambda_integer_crossvalidation\n');

% ---------------------------------------------------------------------------
% Bridge locations + skip guards
% ---------------------------------------------------------------------------
libDir  = fullfile(getenv('HOME'), 'orekit-bridge', 'lib');
dataDir = fullfile(getenv('HOME'), 'orekit-bridge', 'data', 'orekit-data-main');
if ~usejava('jvm')
    fprintf('SKIP: no JVM. Run via `matlab -batch` rather than a -nojvm session.\n'); return
end
if ~isfolder(libDir) || isempty(dir(fullfile(libDir, '*.jar'))) || ~isfolder(dataDir)
    fprintf('SKIP: Orekit bridge not installed.\n      jars: %s\n      data: %s\n', libDir, dataDir); return
end

here      = fileparts(mfilename('fullpath'));
oo_v1Root = fileparts(here);
addpath(oo_v1Root);
addpath(fullfile(oo_v1Root, 'config'));
addpath(fullfile(oo_v1Root, 'config', 'internal'));

% LAMBDA 4.0 is user-installed and not vendored; look in the documented places.
lambdaPath = '';
cands = { getenv('LAMBDA_TOOLBOX_PATH'), ...
          fullfile(getenv('HOME'), 'tools', 'LAMBD4-master_2024_10_01'), ...
          fullfile(getenv('HOME'), 'Downloads', 'LAMBD4-master_2024_10_01') };
for k = 1:numel(cands)
    if ~isempty(cands{k}) && isfile(fullfile(cands{k}, 'LAMBDA.m'))
        lambdaPath = cands{k}; break
    end
end
if isempty(lambdaPath)
    fprintf(['SKIP: TU Delft LAMBDA 4.0 not found (external dependency, see ' ...
             'docs/LAMBDA_SETUP.md).\n      Set LAMBDA_TOOLBOX_PATH or install to ~/tools.\n']);
    return
end

jars = dir(fullfile(libDir, '*.jar'));
for k = 1:numel(jars); javaaddpath(fullfile(libDir, jars(k).name)); end
dpm = org.orekit.data.DataContext.getDefault().getDataProvidersManager();
dpm.addProvider(org.orekit.data.DirectoryCrawler(java.io.File(dataDir)));

cfg = struct();
cfg.estimator.lambda = struct( ...
    'enable', true, 'method', 3, 'nCands', 2, ...   % method 3 = full ILS
    'minSuccessRate', 0, 'ratioThreshold', 1.0, ... % gates opened: compare the SEARCH
    'toolboxPath', lambdaPath);
revgnss.integer.LambdaResolver.addToPath(cfg);
assert(revgnss.integer.LambdaResolver.isAvailable(cfg), 'LAMBDA toolbox found but not callable');
fprintf('LAMBDA 4.0: %s\n', lambdaPath);

ils  = org.orekit.estimation.measurements.gnss.LambdaMethod();
mils = org.orekit.estimation.measurements.gnss.ModifiedLambdaMethod();

% ===========================================================================
% PART A -- ILS agreement over randomised, strongly correlated problems
% ===========================================================================
fprintf('\n== PART A: ILS integer solution  LAMBDA 4.0 vs Orekit LambdaMethod ==\n');

rs   = RandStream('mt19937ar', 'Seed', 20260802);   % fixed: reproducible problem set
dims = [2 3 4 6 8];
nTrialsPerDim = 20;

BRUTE_MAX_N = 6;    % exhaustive arbitration up to this dimension (7^6 = 117649 vectors)

nTot = 0; nAgree = 0; nAgreeM = 0; nRoundDiffers = 0;
dSqMax = 0; dSq2Max = 0; nRunnerUp = 0; nAgreeRunnerUp = 0;
nBrute = 0; nBruteBestOk = 0; nBruteRunnerUpOk = 0; nOrekitMissedRunnerUp = 0;
simRunnerUpNeverWorse = true; worstRatioInflation = 1;
fprintf('   n  trials  agree(LambdaMethod)  agree(ModifiedLambda)  rounding!=ILS  max|d sqnorm|\n');
for n = dims
    aTot = 0; aOk = 0; aOkM = 0; aRound = 0; dSqDim = 0;
    for trial = 1:nTrialsPerDim
        [aHat, Qa, ~] = makeProblem_(rs, n);

        % --- sim side: TU Delft LAMBDA 4.0 (raw, method 3 = full ILS) ---
        [aCand, sqnorm] = LAMBDA(aHat, Qa, 3, 2);
        simFix  = round(aCand(:,1));
        simSq   = sqnorm(1);

        % --- Orekit side: independent LTDL reduction + discrete search ---
        [oreFix, oreSq] = orekitILS_(ils, aHat, Qa, 2);
        [oreFixM, ~]    = orekitILS_(mils, aHat, Qa, 2);

        aTot = aTot + 1; nTot = nTot + 1;
        if isequal(simFix, oreFix);  aOk  = aOk  + 1; nAgree  = nAgree  + 1; end
        if isequal(simFix, oreFixM); aOkM = aOkM + 1; nAgreeM = nAgreeM + 1; end
        if ~isequal(simFix, round(aHat)); aRound = aRound + 1; nRoundDiffers = nRoundDiffers + 1; end

        d = abs(simSq - oreSq(1));
        dSqDim = max(dSqDim, d); dSqMax = max(dSqMax, d);

        % runner-up (drives the resolver's ratio test)
        if numel(sqnorm) >= 2 && numel(oreSq) >= 2
            nRunnerUp = nRunnerUp + 1;
            d2 = abs(sqnorm(2) - oreSq(2));
            dSq2Max = max(dSq2Max, d2);
            if d2 <= 1e-9 * max(1, abs(sqnorm(2))); nAgreeRunnerUp = nAgreeRunnerUp + 1; end
            % A missed candidate can only make a runner-up MORE expensive. Track whether
            % the sim ever reports the worse of the two, and how far the ratio test would
            % be inflated by taking Orekit's value instead.
            if sqnorm(2) > oreSq(2) + 1e-9*max(1,abs(oreSq(2)))
                simRunnerUpNeverWorse = false;
            end
            if simSq > 0
                worstRatioInflation = max(worstRatioInflation, (oreSq(2)/simSq) / (sqnorm(2)/simSq));
            end
        end

        % --- independent arbiter: exhaustive enumeration (ground truth) ---
        if n <= BRUTE_MAX_N
            [bFix, bSq] = bruteForceILS_(aHat, Qa, 3);
            nBrute = nBrute + 1;
            if isequal(simFix, bFix); nBruteBestOk = nBruteBestOk + 1; end
            if numel(sqnorm) >= 2 && abs(sqnorm(2) - bSq(2)) <= 1e-9*max(1,abs(bSq(2)))
                nBruteRunnerUpOk = nBruteRunnerUpOk + 1;
            end
            if numel(oreSq) >= 2 && abs(oreSq(2) - bSq(2)) > 1e-9*max(1,abs(bSq(2)))
                nOrekitMissedRunnerUp = nOrekitMissedRunnerUp + 1;
            end
        end
    end
    fprintf('  %2d  %6d  %19d  %21d  %13d  %13.3e\n', n, aTot, aOk, aOkM, aRound, dSqDim);
end
fprintf('  TOTAL %d trials: LambdaMethod agrees %d, ModifiedLambdaMethod agrees %d\n', ...
    nTot, nAgree, nAgreeM);
fprintf('  naive rounding differs from ILS in %d of %d trials (the search is being exercised)\n', ...
    nRoundDiffers, nTot);
fprintf('  max |d squared-distance| = %.3e\n', dSqMax);

% ===========================================================================
% PART B -- runner-up candidate (the ratio test's denominator)
% ===========================================================================
fprintf('\n== PART B: second-best candidate (feeds the resolver ratio test) ==\n');
fprintf('  sim vs Orekit: runner-up available in %d trials, agrees in %d, max |d sqnorm2| = %.3e\n', ...
    nRunnerUp, nAgreeRunnerUp, dSq2Max);
fprintf('  exhaustive arbitration (n <= %d, +/-3 box, %d trials):\n', BRUTE_MAX_N, nBrute);
fprintf('    sim best   == brute-force best   : %d / %d\n', nBruteBestOk, nBrute);
fprintf('    sim 2nd    == brute-force 2nd    : %d / %d\n', nBruteRunnerUpOk, nBrute);
fprintf('    Orekit 2nd != brute-force 2nd    : %d / %d  (Orekit dropped the true runner-up)\n', ...
    nOrekitMissedRunnerUp, nBrute);
fprintf('    worst ratio-test inflation if Orekit''s runner-up were used: x%.3f\n', worstRatioInflation);

% ===========================================================================
% PART C -- the production entry point, not just the toolbox underneath it
% ===========================================================================
fprintf('\n== PART C: revgnss.integer.LambdaResolver.resolve() vs Orekit ==\n');
rs2 = RandStream('mt19937ar', 'Seed', 7727);
nRes = 0; nResAgree = 0; nAccepted = 0;
fprintf('   n   decision              SR        ratio    matches Orekit\n');
for n = [3 4 6]
    for trial = 1:6
        [aHat, Qa, ~] = makeProblem_(rs2, n);
        [aFix, info]  = revgnss.integer.LambdaResolver.resolve(aHat, Qa, cfg);
        [oreFix, ~]   = orekitILS_(ils, aHat, Qa, 2);
        nRes = nRes + 1;
        ok = false;
        if info.accepted
            nAccepted = nAccepted + 1;
            ok = isequal(round(aFix), oreFix);
            if ok; nResAgree = nResAgree + 1; end
        end
        if trial <= 2
            fprintf('  %2d   %-20s  %.6f  %7.3f   %d\n', n, info.decision, info.successRate, ...
                info.ratio, ok);
        end
    end
end
fprintf('  resolve() accepted %d of %d, and every accepted fix matched Orekit: %d\n', ...
    nAccepted, nRes, nResAgree);

% ---------------------------------------------------------------------------
% Assertions
%
%   A: ILS is unique -> agreement must be 100%, not "usually". Both Orekit variants
%      (plain LAMBDA reduction and the modified/MLAMBDA reduction) must land on the same
%      integer vector as the TU Delft toolbox, and the objective value must match to
%      numerical precision. The rounding-differs counter guards against a vacuous pass.
%   B: the sim's runner-up is asserted against EXHAUSTIVE ENUMERATION, not against Orekit,
%      because the two libraries disagree there and a two-way comparison cannot say which
%      is right. The sim must reproduce brute force exactly, and must never report the
%      more expensive of the two runner-ups (a missed candidate can only cost more, and
%      would make the resolver's ratio test too permissive). Orekit's misses are counted
%      and reported rather than asserted away.
%   C: the wrapper the production code actually calls must inherit that agreement.
% ---------------------------------------------------------------------------
assert(nTot > 0, 'A FAIL: no trials ran');
assert(nRoundDiffers > 0, ...
    ['A FAIL: naive rounding equalled ILS in every trial -- the problem set is too easy ' ...
     'to distinguish the two implementations, so agreement proves nothing']);
assert(nAgree == nTot, 'A FAIL: LAMBDA vs Orekit LambdaMethod disagreed in %d of %d trials', ...
    nTot - nAgree, nTot);
assert(nAgreeM == nTot, 'A FAIL: LAMBDA vs Orekit ModifiedLambdaMethod disagreed in %d of %d trials', ...
    nTot - nAgreeM, nTot);
assert(dSqMax < 1e-9, 'A FAIL: ILS squared distance differs by %.3e (objective mismatch)', dSqMax);
assert(nBrute > 0, 'A FAIL: exhaustive arbitration never ran');
assert(nBruteBestOk == nBrute, ...
    'A FAIL: sim ILS best solution differs from exhaustive enumeration in %d of %d trials', ...
    nBrute - nBruteBestOk, nBrute);

assert(nRunnerUp > 0, 'B FAIL: no runner-up candidates produced');
assert(nBruteRunnerUpOk == nBrute, ...
    'B FAIL: sim runner-up differs from exhaustive enumeration in %d of %d trials', ...
    nBrute - nBruteRunnerUpOk, nBrute);
assert(simRunnerUpNeverWorse, ...
    ['B FAIL: the sim reported a MORE expensive runner-up than Orekit in at least one ' ...
     'trial -- that means the sim search dropped a genuine candidate, which would make ' ...
     'the resolver ratio test too permissive']);

assert(nAccepted > 0, 'C FAIL: resolve() never accepted a fix -- gates not actually open');
assert(nResAgree == nAccepted, 'C FAIL: %d accepted fixes did not match Orekit', ...
    nAccepted - nResAgree);

fprintf(['\ntest_orekit_lambda_integer_crossvalidation: PASS -- %d/%d ILS problems agree with ' ...
         'both Orekit reductions (objective to %.1e), including %d where rounding would have ' ...
         'been wrong; the sim reproduces exhaustive enumeration on best AND runner-up in ' ...
         'all %d arbitrated trials (Orekit dropped the true runner-up in %d); resolve() ' ...
         'reproduced Orekit on all %d accepted fixes.\n'], ...
         nAgree, nTot, dSqMax, nRoundDiffers, nBrute, nOrekitMissedRunnerUp, nAccepted);

% ===========================================================================
% Local helpers
% ===========================================================================
function [aHat, Qa, aTrue] = makeProblem_(rs, n)
    % A deliberately HARD integer-least-squares problem: Q = L*D*L' with a unit lower
    % triangular L carrying strong off-diagonal coupling and D spanning several orders of
    % magnitude. That is the regime real carrier-phase ambiguity covariances live in --
    % highly elongated, highly correlated search ellipsoids where per-component rounding
    % is not the ILS solution, so the decorrelation step is genuinely under test.
    L = eye(n);
    for i = 2:n
        for j = 1:i-1
            L(i,j) = 2*(rs.rand() - 0.5) * 1.5;
        end
    end
    d  = 10.^(-1 + 2*rs.rand(n,1));          % eigenvalue-ish spread ~1e-1 .. 1e1
    Qa = L * diag(d) * L';
    Qa = 0.5*(Qa + Qa');                      % exact symmetry

    aTrue = round(10 * (rs.rand(n,1) - 0.5));
    % Float solution: truth plus a correlated perturbation drawn from Qa, scaled so the
    % answer sits near -- but not on -- a decision boundary.
    aHat  = aTrue + 0.35 * (chol(Qa, 'lower') * rs.randn(n,1));
end

function [bestFix, bestSq] = bruteForceILS_(aHat, Qa, halfWidth)
    % Exhaustive integer least squares: score EVERY integer vector in a box around the
    % rounded float solution with the objective (a - aHat)' * inv(Qa) * (a - aHat), and
    % return the two cheapest. No reduction, no search tree, no heuristic -- this is the
    % definition of the problem, so it arbitrates between two competing implementations.
    n  = numel(aHat);
    Qi = inv(Qa);
    c0 = round(aHat(:));
    grids = cell(n,1);
    for i = 1:n; grids{i} = (c0(i)-halfWidth):(c0(i)+halfWidth); end
    G = cell(1,n);
    [G{:}] = ndgrid(grids{:});
    A = zeros(numel(G{1}), n);
    for i = 1:n; A(:,i) = G{i}(:); end
    D    = A - aHat(:)';
    cost = sum((D*Qi).*D, 2);
    [cs, idx] = sort(cost);
    bestFix = A(idx(1),:)';
    bestSq  = cs(1:min(2,numel(cs)))';
end

function [fix, sq] = orekitILS_(solver, aHat, Qa, nSol)
    % Orekit's IntegerLeastSquareSolver:
    %   solveILS(int nSol, double[] floats, int[] indirection, RealMatrix covariance)
    % indirection selects which entries of the (possibly larger) covariance participate;
    % here the whole matrix does, so it is simply 0..n-1.
    n   = numel(aHat);
    cov = org.hipparchus.linear.MatrixUtils.createRealMatrix(Qa);
    sols = solver.solveILS(int32(nSol), aHat(:)', int32(0:n-1), cov);
    m   = numel(sols);
    sq  = zeros(1, m);
    fix = [];
    for k = 1:m
        sq(k) = sols(k).getSquaredDistance();
        if k == 1
            fix = double(sols(k).getSolution())';
            fix = fix(:);
        end
    end
end
