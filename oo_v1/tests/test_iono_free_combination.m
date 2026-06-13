% test_iono_free_combination
% IonoFreeCombination class: coefficients and combine methods.
%
% Verifies:
%   - alpha + beta = 1 (unbiased combination)
%   - alpha > 1, beta < 0 for GPS L1/L2
%   - combine() returns alpha*x1 + beta*x2

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_iono_free_combination ===\n');

f1 = 1575.42e6;  % GPS L1
f2 = 1227.60e6;  % GPS L2

[alpha, beta] = revgnss.IonoFreeCombination.coefficients(f1, f2);

% alpha + beta = 1 (IF combination is unbiased for non-dispersive terms)
assert(abs(alpha + beta - 1) < 1e-12, ...
    'alpha+beta must equal 1, got %.6f', alpha + beta);

% alpha > 1, beta < 0 (GPS L1/L2 geometry)
assert(alpha > 1, 'alpha must be > 1 for L1/L2, got %.4f', alpha);
assert(beta  < 0, 'beta must be < 0 for L1/L2, got %.4f', beta);

% combine() matches manual formula
x1 = 100; x2 = 120;
x_IF = revgnss.IonoFreeCombination.combine(x1, x2, f1, f2);
x_IF_expected = alpha * x1 + beta * x2;
assert(abs(x_IF - x_IF_expected) < 1e-10, ...
    'combine() mismatch: got %.6f, expected %.6f', x_IF, x_IF_expected);

% combineVariance with uncorrelated inputs
var1 = 4; var2 = 9; cov12 = 0;
var_IF = revgnss.IonoFreeCombination.combineVariance(var1, var2, cov12, f1, f2);
var_IF_expected = alpha^2 * var1 + beta^2 * var2;
assert(abs(var_IF - var_IF_expected) < 1e-12, ...
    'combineVariance mismatch for cov12=0');

fprintf('  alpha=%.6f  beta=%.6f  alpha+beta=%.1f\n', alpha, beta, alpha+beta);
fprintf('  combine(x1=%.0f, x2=%.0f) = %.6f\n', x1, x2, x_IF);
fprintf('  PASS\n');
