% test_iono_free_cancels_iono
% IF combination of L1 and L2 pseudoranges cancels first-order ionosphere.
%
% Model:  z_L1 = rho + I,   z_L2 = rho + (f1/f2)^2 * I
% IF:     z_IF = alpha*z_L1 + beta*z_L2 = rho  (iono cancels)
%
% Verifies: residual iono in z_IF is < 1e-6 m for I_L1 = 5 m.

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_iono_free_cancels_iono ===\n');

f1 = 1575.42e6;
f2 = 1227.60e6;

rho  = 2.0e7;   % typical GEO slant range [m]
I_L1 = 5.0;     % first-order iono delay on L1 [m]
I_L2 = (f1/f2)^2 * I_L1;   % first-order iono delay on L2 (dispersive scaling)

z_L1 = rho + I_L1;
z_L2 = rho + I_L2;

z_IF = revgnss.IonoFreeCombination.combine(z_L1, z_L2, f1, f2);

residualIono = z_IF - rho;
assert(abs(residualIono) < 1e-6, ...
    'IF combination should cancel iono; residual = %.2e m (threshold 1e-6 m)', residualIono);

fprintf('  I_L1=%.2f m  I_L2=%.4f m  z_IF-rho=%.2e m\n', I_L1, I_L2, residualIono);
fprintf('  PASS\n');
