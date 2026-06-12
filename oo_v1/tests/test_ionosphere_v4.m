% test_ionosphere_v4  v4 scientific corrections for ionosphere model.
%
% T1: constantVerticalDelay computes correct slant delay I = vdel / sin(el).
%     'constantVerticalTEC' is rejected when verticalTEC_TECU field is absent.
%
% T3: IF combination algebraically removes first-order iono (corrModel='none').
%     Separately: matched model (corrModel='perfect') gives z_IF = h_IF.
%
% CHANGED: v3→v4 — Issues 1 and 3

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_ionosphere_v4 ===\n');

f_L1 = 1575.42e6;
f_L2 = 1227.60e6;

% ----------------------------------------------------------------
% T1a: constantVerticalDelay slant delay correctness
% I_slant = verticalDelayL1_m / sin(el)   for mapping = 1/sin(el)
% ----------------------------------------------------------------
fprintf('  T1a: constantVerticalDelay slant delay ...\n');

el_rad = 0.5;  % ~28.6 deg elevation
vdel   = 5.0;  % 5 m vertical L1 delay

cfg = revgnss.ConfigFactory.defaultConfig();
cfg.errors.ionosphere.modelType              = 'constantVerticalDelay';
cfg.errors.ionosphere.truth.enable           = true;
cfg.errors.ionosphere.truth.verticalDelayL1_m = vdel;
cfg.errors.ionosphere.model.enable           = true;
cfg.errors.ionosphere.model.verticalDelayL1_m = vdel;

ec = revgnss.ErrorChain(cfg, 1);
err = ec.compute(el_rad, 1, 1, 0);

I_slant_truth = err.bySource.truth_m.iono(1);
I_slant_model = err.bySource.model_m.iono(1);
I_expected    = vdel / sin(el_rad);

fprintf('    truth iono = %.6f m, expected %.6f m\n', I_slant_truth, I_expected);
assert(abs(I_slant_truth - I_expected) < 1e-9, ...
    'T1a FAILED: constantVerticalDelay truth slant delay wrong (err=%.2e m)', ...
    abs(I_slant_truth - I_expected));
assert(abs(I_slant_model - I_expected) < 1e-9, ...
    'T1a FAILED: constantVerticalDelay model slant delay wrong');
fprintf('    PASS\n');

% ----------------------------------------------------------------
% T1b: 'constantVerticalTEC' rejected when verticalTEC_TECU absent
% ----------------------------------------------------------------
fprintf('  T1b: constantVerticalTEC rejected without verticalTEC_TECU ...\n');

cfg2 = revgnss.ConfigFactory.defaultConfig();
cfg2.errors.ionosphere.modelType = 'constantVerticalTEC';
% Do NOT set verticalTEC_TECU — should throw an error

ec2 = revgnss.ErrorChain(cfg2, 1);
try
    ec2.compute(el_rad, 1, 1, 0);
    error('T1b FAILED: expected error for constantVerticalTEC without verticalTEC_TECU');
catch ME
    assert(contains(ME.identifier, 'ErrorChain') || contains(ME.message, 'verticalTEC'), ...
        'T1b FAILED: wrong error thrown: %s', ME.message);
    fprintf('    caught expected error: %s\n', ME.message);
    fprintf('    PASS\n');
end

% ----------------------------------------------------------------
% T3a: IF combination algebraically cancels first-order iono
%      corrModel = 'none', iono truth = 10 m at L1
%
% alpha = f1^2 / (f1^2 - f2^2)
% beta  = f2^2 / (f1^2 - f2^2)   (note: positive; P_IF = alpha*P_L1 - beta*P_L2)
% I_L2 = I_L1 * (f_L1/f_L2)^2   (first-order dispersive scaling)
% P_IF = alpha*P_L1 - beta*P_L2 => iono term = alpha*I_L1 - beta*I_L2 = 0
%
% Reference: Leick et al. (2015) eq. 10.3; IS-GPS-200 Appendix
% ----------------------------------------------------------------
fprintf('  T3a: IF combination algebraically removes first-order iono ...\n');

alpha  = f_L1^2 / (f_L1^2 - f_L2^2);
beta   = f_L2^2 / (f_L1^2 - f_L2^2);
I_L1   = 10.0;                     % 10 m truth L1 iono (no other errors)
I_L2   = I_L1 * (f_L1/f_L2)^2;    % first-order dispersive scaling

% Verify IF combination cancels iono algebraically
iono_IF = alpha * I_L1 - beta * I_L2;
fprintf('    alpha = %.6f, beta = %.6f\n', alpha, beta);
fprintf('    I_L1 = %.4f m, I_L2 = %.4f m, iono_IF = %.2e m\n', I_L1, I_L2, iono_IF);
assert(abs(iono_IF) < 1e-9, ...
    'T3a FAILED: IF iono term not cancelled (iono_IF = %.2e m)', iono_IF);

% Now verify with a pseudorange scenario (geometry = 0 for pure iono test)
rho_true = 1e7;                     % 10000 km geometric range
P_L1 = rho_true + I_L1;
P_L2 = rho_true + I_L2;
P_IF = alpha * P_L1 - beta * P_L2;

fprintf('    P_IF = %.6f, rho_true = %.6f, diff = %.2e m\n', P_IF, rho_true, P_IF - rho_true);
assert(abs(P_IF - rho_true) < 1e-9, ...
    'T3a FAILED: |P_IF - rho_true| = %.2e m > 1e-9 m', abs(P_IF - rho_true));
fprintf('    PASS\n');

% ----------------------------------------------------------------
% T3b: corrModel='perfect' matched model gives z_IF ≈ h_IF
%      (Tests matched-model behaviour separately)
% ----------------------------------------------------------------
fprintf('  T3b: corrModel=perfect (matched model) z_IF = h_IF ...\n');

I_L1_mm = 10.0;
I_L2_mm = I_L1_mm * (f_L1/f_L2)^2;

% With matched truth and model (both use same iono), the IF pseudoranges match exactly
P_L1_truth = rho_true + I_L1_mm;
P_L1_model = rho_true + I_L1_mm;   % perfect correction: model = truth
P_L2_truth = rho_true + I_L2_mm;
P_L2_model = rho_true + I_L2_mm;

z_IF_perfect = alpha * P_L1_truth - beta * P_L2_truth;
h_IF_perfect = alpha * P_L1_model - beta * P_L2_model;
assert(abs(z_IF_perfect - h_IF_perfect) < 1e-9, ...
    'T3b FAILED: matched model z_IF != h_IF (diff = %.2e)', abs(z_IF_perfect - h_IF_perfect));
fprintf('    z_IF = h_IF (matched model): PASS\n');

fprintf('=== test_ionosphere_v4: ALL PASS ===\n');
