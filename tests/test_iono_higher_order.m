% test_iono_higher_order  WP6 acceptance test (Branch A): second/third-order ionospheric
% residuals that SURVIVE the ionosphere-free (L3) combination.
%
% The dual-frequency IF combination cancels the first-order 40.3*TEC/f^2 term exactly,
% but the second-order (~f^-3) and third-order (~f^-4) residuals do NOT cancel and are
% cm-level at L1 under high solar activity. Modelled as a bounded truth-side residual.
%
% Parts:
%   A. Frequency scaling: second-order ~ f^-3, third-order ~ f^-4 (L1 vs L2 ratio).
%   B. IF survival: the first-order term cancels to ~0 under the L3 combination, but the
%      higher-order residual is RETAINED at the cm level (the key correctness check).
%   C. Conservative magnitudes (cm at L1) and scaling with TEC (the first-order delay).
%   D. Integration: enabling adds a nonzero HO residual to truth and R via ErrorChain;
%      disabled yields exactly zero (bit-identical, complementing the golden gate).

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));
addpath(fullfile(thisDir, '..', 'config'));

fprintf('=== test_iono_higher_order ===\n');

HOI = @models.errors.HigherOrderIonosphere;
f1  = revgnss.SignalDefinition.get('L1').frequency_Hz;
f2  = revgnss.SignalDefinition.get('L2').frequency_Hz;
ho  = struct('secondOrderFractionL1',0.003, 'secondOrderCap_m',0.05, ...
             'thirdOrderCoeff_perm',5e-5, 'thirdOrderCap_m',0.005);
I_L1 = 10;   % first-order L1 slant delay [m]

% ================================================================
% Part A: frequency scaling f^-3 / f^-4
% ================================================================
fprintf('  A. second-order ~ f^-3, third-order ~ f^-4 ...\n');
d2_1 = models.errors.HigherOrderIonosphere.secondOrderDelay(I_L1, f1, f1, ho.secondOrderFractionL1, ho.secondOrderCap_m);
d2_2 = models.errors.HigherOrderIonosphere.secondOrderDelay(I_L1, f2, f1, ho.secondOrderFractionL1, ho.secondOrderCap_m);
d3_1 = models.errors.HigherOrderIonosphere.thirdOrderDelay(I_L1, f1, f1, ho.thirdOrderCoeff_perm, ho.thirdOrderCap_m);
d3_2 = models.errors.HigherOrderIonosphere.thirdOrderDelay(I_L1, f2, f1, ho.thirdOrderCoeff_perm, ho.thirdOrderCap_m);
ratio2 = d2_2 / d2_1;  exp2 = (f1/f2)^3;
ratio3 = d3_2 / d3_1;  exp3 = (f1/f2)^4;
fprintf('    2nd L2/L1=%.4f (f1/f2)^3=%.4f | 3rd L2/L1=%.4f (f1/f2)^4=%.4f\n', ratio2, exp2, ratio3, exp3);
assert(abs(ratio2 - exp2) < 1e-9, 'Part A FAILED: second-order not f^-3');
assert(abs(ratio3 - exp3) < 1e-9, 'Part A FAILED: third-order not f^-4');
fprintf('    PASS\n');

% ================================================================
% Part B: IF survival (first-order cancels; higher-order retained)
% ================================================================
fprintf('  B. IF (L3) combination: first-order cancels, higher-order survives ...\n');
% First-order: I_L2 = I_L1 * (f1/f2)^2 (the injection convention).
I_L2 = I_L1 * (f1/f2)^2;
res1 = revgnss.IonoFreeCombination.combine(I_L1, I_L2, f1, f2);
% Higher-order combined across the two frequencies.
[hoT1] = models.errors.HigherOrderIonosphere.totalDelay(I_L1, f1, f1, ho);
[hoT2] = models.errors.HigherOrderIonosphere.totalDelay(I_L1, f2, f1, ho);
resHO = revgnss.IonoFreeCombination.combine(hoT1, hoT2, f1, f2);
fprintf('    IF residual: first-order=%.3e m (cancels)  higher-order=%.4f m (survives)\n', res1, resHO);
assert(abs(res1) < 1e-6, 'Part B FAILED: first-order did not cancel in L3 (%.3e)', res1);
assert(abs(resHO) > 0.005, 'Part B FAILED: higher-order did not survive L3 at cm level (%.4f)', resHO);
fprintf('    PASS\n');

% ================================================================
% Part C: conservative magnitudes + TEC scaling
% ================================================================
fprintf('  C. cm-level magnitudes at L1 + scaling with TEC ...\n');
d2_lo = models.errors.HigherOrderIonosphere.secondOrderDelay(5,  f1, f1, ho.secondOrderFractionL1, ho.secondOrderCap_m);
d2_hi = models.errors.HigherOrderIonosphere.secondOrderDelay(10, f1, f1, ho.secondOrderFractionL1, ho.secondOrderCap_m);
fprintf('    2nd-order at L1: I=5m -> %.4f m, I=10m -> %.4f m (cm-level; scales with TEC)\n', d2_lo, d2_hi);
assert(abs(d2_hi) >= 0.005 && abs(d2_hi) <= 0.05, 'Part C FAILED: 2nd-order not cm-level (%.4f)', d2_hi);
assert(abs(d2_hi) > abs(d2_lo) * 1.5, 'Part C FAILED: 2nd-order does not scale with TEC');
fprintf('    PASS\n');

% ================================================================
% Part D: ErrorChain integration (enabled adds residual; disabled = 0)
% ================================================================
fprintf('  D. ErrorChain injection (enabled nonzero -> truth + R; disabled zero) ...\n');
cfgOff = revgnss.ConfigFactory.defaultConfig();
cfgOff.errors.ionosphere.truth.enable = true;   % need first-order iono for HO to derive from
cfgOff.errors.ionosphere.model.enable = true;
cfgOff.scenario.nTowers = 1;
cfgOn = cfgOff;
cfgOn.errors.ionosphere.higherOrder.enable = true;

ecOff = models.errors.ErrorChain(cfgOff, 7);
ecOn  = models.errors.ErrorChain(cfgOn,  7);
eOff = ecOff.compute(deg2rad(30), 1, 1, 0, 1);
eOn  = ecOn.compute(deg2rad(30), 1, 1, 0, 1);
hoOff = eOff.bySource.truth_m.ionoHO(1);
hoOn  = eOn.bySource.truth_m.ionoHO(1);
sgOn  = eOn.bySource.sigma_m.ionoHO(1);
fprintf('    ionoHO truth: off=%.4f m  on=%.4f m  (R sigma on=%.4f m)\n', hoOff, hoOn, sgOn);
assert(hoOff == 0, 'Part D FAILED: HO should be exactly 0 when disabled');
assert(abs(hoOn) > 0, 'Part D FAILED: HO should be nonzero when enabled');
assert(abs(sgOn - abs(hoOn)) < 1e-12, 'Part D FAILED: HO magnitude should enter R');
% Disabled config leaves the default OFF (backward compatible).
assert(~cfgOff.errors.ionosphere.higherOrder.enable, 'Part D FAILED: default should be disabled');
fprintf('    PASS\n');

fprintf('=== test_iono_higher_order: ALL PASS ===\n');
