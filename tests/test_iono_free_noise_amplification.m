% test_iono_free_noise_amplification  WP8 acceptance test: the ionosphere-free (L3)
% combination's noise-amplification cost is modelled (not hidden), the combined variance
% equals the analytic (f1^4 s1^2 + f2^4 s2^2)/(f1^2-f2^2)^2, and the WP6 higher-order
% residual survives L3 while the first-order term cancels.

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_iono_free_noise_amplification ===\n');

f1 = revgnss.SignalDefinition.get('L1').frequency_Hz;
f2 = revgnss.SignalDefinition.get('L2').frequency_Hz;
[alpha, beta] = revgnss.IonoFreeCombination.coefficients(f1, f2);

% ---- combined variance equals the closed-form (f1^4 s1^2 + f2^4 s2^2)/(f1^2-f2^2)^2 ----
s1 = 0.30; s2 = 0.45;   % per-frequency code sigma [m]
varIF   = revgnss.IonoFreeCombination.combineVariance(s1^2, s2^2, 0, f1, f2);
varAnal = (f1^4*s1^2 + f2^4*s2^2) / (f1^2 - f2^2)^2;
assert(abs(varIF - varAnal) / varAnal < 1e-12, ...
    'FAILED: combined variance %.6g != analytic %.6g', varIF, varAnal);

% ---- noise amplification for equal sigmas: sigma_IF ~ 2.98 * sigma (a real cost) ----
amp = sqrt(alpha^2 + beta^2);        % sigma_IF / sigma when s1 == s2
fprintf('  alpha=%.4f beta=%.4f | sigma_IF/sigma = %.3f (variance x%.2f)\n', alpha, beta, amp, amp^2);
assert(abs(amp - 2.978) < 0.02, 'FAILED: L3 noise amplification %.3f != ~2.98', amp);
assert(amp > 2.5, 'FAILED: L3 noise amplification not modelled as a real cost');

% ---- first-order cancels; higher-order (WP6) survives L3 ----
I_L1 = 8;                            % first-order L1 slant delay [m]
res1 = revgnss.IonoFreeCombination.combine(I_L1, I_L1*(f1/f2)^2, f1, f2);
ho   = struct('secondOrderFractionL1',0.003,'secondOrderCap_m',0.05, ...
              'thirdOrderCoeff_perm',5e-5,'thirdOrderCap_m',0.005);
hoT1 = models.errors.HigherOrderIonosphere.totalDelay(I_L1, f1, f1, ho);
hoT2 = models.errors.HigherOrderIonosphere.totalDelay(I_L1, f2, f1, ho);
resHO = revgnss.IonoFreeCombination.combine(hoT1, hoT2, f1, f2);
fprintf('  L3 residual: first-order=%.3e m (cancels)  higher-order=%.4f m (survives)\n', res1, resHO);
assert(abs(res1) < 1e-6, 'FAILED: first-order did not cancel in L3');
assert(abs(resHO) > 0.005, 'FAILED: higher-order did not survive L3');

fprintf('  PASS\n');
fprintf('=== test_iono_free_noise_amplification: ALL PASS ===\n');
