% test_nis_accumulated_dof  NIS consistency via accumulated chi-squared DOF form.
%
% CHANGED: v3→v4 — Issue 7
%
% The existing mean(NIS) ~ M test is only valid when M is constant.
% This test uses the accumulated DOF form:
%   sumNIS = sum(NIS_k)
%   dof    = sum(M_k)    % per-epoch measurement dimension
%   Under correct filter: sumNIS ~ chi²(dof)
%   Test: |sumNIS - dof| < 3 * sqrt(2 * dof)
%
% Reference: Bar-Shalom et al., "Estimation with Applications to
%   Tracking and Navigation", Wiley-Interscience, 2001.

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_nis_accumulated_dof ===\n');

cfg = revgnss.ConfigFactory.idealConfig();
cfg.simulation.duration_s = 600;
cfg.simulation.dt_s       = 1.0;
cfg.plots.enable          = false;
cfg.report.enable         = false;

sim = revgnss.ReverseGNSSSimulation(cfg);
sim.initialize();
sim.run();

[sumNIS, dof, passes] = sim.diag.accumulatedNISTest(3);

nisVec = sim.diag.getNIS();
mVec   = sim.diag.getNumMeasurementRows();
N_valid = sum(isfinite(nisVec) & mVec > 0);

fprintf('  N valid epochs: %d\n', N_valid);
fprintf('  sumNIS = %.2f,  dof = %.0f\n', sumNIS, dof);
fprintf('  3*sqrt(2*dof) = %.2f\n', 3 * sqrt(2 * dof));
fprintf('  |sumNIS - dof| = %.2f\n', abs(sumNIS - dof));

if dof > 0
    assert(passes, ...
        'test_nis_accumulated_dof FAILED: |sumNIS - dof| = %.2f > 3*sqrt(2*dof) = %.2f', ...
        abs(sumNIS - dof), 3 * sqrt(2 * dof));
    fprintf('  PASS (NIS consistent with chi^2(%d))\n', dof);
else
    fprintf('  No valid NIS epochs — vacuous PASS\n');
end

fprintf('=== test_nis_accumulated_dof: PASS ===\n');
