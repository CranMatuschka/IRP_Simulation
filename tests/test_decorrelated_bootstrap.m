% test_decorrelated_bootstrap  Verify the native integer ambiguity estimator against brute
% force, because everything Phase F reports rests on it.
%
% revgnss.integer.DecorrelatedBootstrap exists because the canonical TU Delft LAMBDA toolbox
% carries no licence grant and is therefore not vendored -- cfg.estimator.lambda.toolboxPath is
% empty on a fresh checkout, so an ambiguity-resolution stage that depended on it would be
% unreachable, which is precisely the defect class (delayCal.estimate.enable,
% assumedShapeSigma_m) this whole work has been cleaning up.
%
% A decorrelation with a convention error does not crash. It produces a WRONG SUCCESS RATE --
% and in the dangerous direction, because a badly-ordered LDL' makes the conditional variances
% look smaller than they are. These tests therefore check the algebra, not the plumbing:
%   1. the transformation invariant Z'QZ = LDL' with Z unimodular
%   2. the integer least-squares solution against EXHAUSTIVE enumeration on small problems
%   3. that decorrelation cannot decrease the bootstrapped success rate
%   4. that the success rate is a real probability -- measured against Monte Carlo

fprintf('== test_decorrelated_bootstrap ==\n');
thisDir = fileparts(mfilename('fullpath'));
root    = fileparts(thisDir);
addpath(root);

rs = RandStream('mt19937ar','Seed',20260805);

%% ---- 1. The transformation invariant ------------------------------------------------------
for trial = 1:20
    n = randi(rs, [2 8]);
    A = randn(rs, n, n+3);
    Q = A*A.'/ (n+3) + 0.01*eye(n);
    Q = (Q+Q.')/2;
    [Z, L, d, ok] = revgnss.integer.DecorrelatedBootstrap.reduce_(Q);
    assert(ok, 'reduce_ failed on a well-conditioned SPD matrix (trial %d)', trial);
    assert(revgnss.integer.DecorrelatedBootstrap.verifyTransform(Q, Z, L, d, 1e-8), ...
        ['INVARIANT VIOLATED on trial %d: Z is not unimodular or Z''QZ ~= LDL''. ' ...
         'Every success rate this class reports is computed from d, so a broken ' ...
         'decorrelation reports a probability that is not a property of the problem.'], trial);
    assert(istriu(L.') && all(abs(diag(L)-1) < 1e-12), 'L is not unit lower triangular');
end
fprintf('  ok   invariant Z''QZ = LDL'' with |det Z| = 1, over 20 random SPD matrices\n');

%% ---- 2. ILS against exhaustive enumeration ------------------------------------------------
% Small n only: enumeration is (2*w+1)^n. This is the check that the search actually finds the
% minimiser and not merely a good candidate.
nBad = 0;
for trial = 1:12
    n = randi(rs, [2 4]);
    A = randn(rs, n, n+1);
    Q = A*A.'/(n+1) + 0.02*eye(n);
    Q = (Q+Q.')/2;
    aHat = 5*randn(rs, n, 1);

    opts = struct('minSuccessRate', 0, 'ratioThreshold', 0, 'nodeBudget', 500000);
    [aFix, info] = revgnss.integer.DecorrelatedBootstrap.resolve(aHat, Q, opts);
    assert(info.accepted, 'resolve refused with no gates set (trial %d): %s', ...
        trial, info.decision);

    % Brute force over a generous box around the float.
    % inv() is deliberate here: the same Qi multiplies thousands of candidate vectors, so
    % factorising once beats a backslash per candidate, and the matrices are 4x4 and well
    % conditioned by construction.
    Qi = inv(Q);                                                              %#ok<MINV>
    w = 4;
    base = round(aHat);
    bestC = Inf; bestA = base;
    grids = cell(1,n);
    for k = 1:n; grids{k} = base(k)+(-w:w); end
    [G{1:n}] = ndgrid(grids{:});
    cand = zeros(numel(G{1}), n);
    for k = 1:n; cand(:,k) = G{k}(:); end
    for r = 1:size(cand,1)
        e = aHat - cand(r,:).';
        c = e.'*Qi*e;
        if c < bestC; bestC = c; bestA = cand(r,:).'; end
    end
    if ~isequal(aFix(:), bestA(:))
        eF = aHat - aFix(:);  cF = eF.'*Qi*eF;
        if cF > bestC*(1+1e-9)
            nBad = nBad + 1;
            fprintf(2, '  trial %d: ILS cost %.6g > brute force %.6g\n', trial, cF, bestC);
        end
    end
end
assert(nBad == 0, '%d ILS solutions were not the integer least-squares minimiser', nBad);
fprintf('  ok   ILS matches exhaustive enumeration on 12 random problems\n');

%% ---- 3. Decorrelation cannot make bootstrapping worse -------------------------------------
% The whole point of the reduction. If this fails the reduction is actively harmful and the
% class should not be used.
worse = 0;
for trial = 1:20
    n = randi(rs, [3 8]);
    A = randn(rs, n, n+1);
    Q = A*A.'/(n+1) + 0.01*eye(n); Q = (Q+Q.')/2;
    srPlain = localBootstrapSr(Q);
    [~, ~, d] = revgnss.integer.DecorrelatedBootstrap.reduce_(Q);
    srRed = prod(2*localNormcdf(1./(2*sqrt(max(d,realmin)))) - 1);
    if srRed < srPlain - 1e-9; worse = worse + 1; end
end
assert(worse == 0, 'decorrelation reduced the bootstrapped success rate in %d cases', worse);
fprintf('  ok   decorrelation never lowered the bootstrapped success rate (20 cases)\n');

%% ---- 4. The success rate is a probability, not a score -------------------------------------
% Draw float vectors from N(0, Q) around a known integer and count how often bootstrapping
% recovers it. This is what makes P(false fix) quotable for a fix with no truth behind it.
% Scaled so the success rate lands in a range where the test can actually discriminate. With
% cycle-level sigmas the rate is ~1 % and any bound passes; at the ~0.1 cycle sigma a real
% wide-lane double difference carries, a wrong formula shows up immediately.
n = 5;
A = randn(rs, n, n+2); Q = 0.02*(A*A.'/(n+2) + 0.05*eye(n)); Q = (Q+Q.')/2;
[~, ~, d] = revgnss.integer.DecorrelatedBootstrap.reduce_(Q);
srPred = prod(2*localNormcdf(1./(2*sqrt(max(d,realmin)))) - 1);
nTrial = 4000; nOk = 0;
C = chol(Q, 'lower');
aTrue = round(10*randn(rs, n, 1));
opts = struct('minSuccessRate', 0, 'ratioThreshold', 0, 'nodeBudget', 200000);
for t = 1:nTrial
    aHat = aTrue + C*randn(rs, n, 1);
    aFix = revgnss.integer.DecorrelatedBootstrap.resolve(aHat, Q, opts);
    nOk = nOk + isequal(round(aFix(:)), aTrue(:));
end
srMeas = nOk/nTrial;
% The predicted rate is for BOOTSTRAPPING; resolve() returns the ILS answer, which is at least
% as good. So measured >= predicted is the correct one-sided expectation.
tol = 4*sqrt(max(srPred*(1-srPred),1e-6)/nTrial);
assert(srMeas >= srPred - tol, ...
    ['MEASURED success %.4f is below the PREDICTED bootstrapped lower bound %.4f ' ...
     '(tolerance %.4f). The reported success rate is not a valid bound.'], ...
    srMeas, srPred, tol);
fprintf('  ok   predicted bootstrapped SR %.4f is a lower bound on the measured %.4f (n=%d)\n', ...
    srPred, srMeas, nTrial);

fprintf('test_decorrelated_bootstrap PASSED\n');

function p = localNormcdf(x)
p = 0.5*erfc(-x/sqrt(2));
end

function sr = localBootstrapSr(Q)
n = size(Q,1); d = zeros(n,1); A = Q;
for k = 1:n
    d(k) = A(k,k);
    if k < n
        l = A(k+1:n,k)/d(k);
        A(k+1:n,k+1:n) = A(k+1:n,k+1:n) - l*d(k)*l.';
    end
end
sr = prod(2*localNormcdf(1./(2*sqrt(max(d,realmin)))) - 1);
end
