% test_rac_sigma_and_pertype_nis_correctness
%
% Locks in two reporting-layer fixes found by the stochastic-correctness audit
% (project_stochastic_audit_rac3sigma):
%
% FIX 1 -- RAC +-3sigma band: revgnss.ClockExactReportBuilder.racPositionSigma_ used to
%   project only diag(P) into the RAC frame (sqrt(sum basis_i^2 * Pii)), dropping the
%   position cross-covariance. It now reconstructs the full 3x3 from Pdiag +
%   PposOffDiag_m2 and projects the FULL quadratic form (sqrt(basis' * P * basis)),
%   which is rotation-invariant -- the diagonal-only formula was not. Falls back to the
%   diagonal-only formula when PposOffDiag_m2 is unavailable (older cached report data).
%
% FIX 2 -- per-type NIS: entry.NIS_code/doppler/carrier used to normalise by R alone
%   (localNis_), always biased high vs the correct S=HPH'+R normalisation. They now
%   source from Stage-57's EkfInnovationAccounting (already S-based), falling back to
%   the R-only computation only when errStruct.ekfAccounting57 isn't populated.

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_rac_sigma_and_pertype_nis_correctness ===\n');

% =========================================================================
% T1: racPositionSigma_ uses the FULL covariance, not just the diagonal.
%   Two epochs use the SAME physical ellipse rigidly rotated by 43 deg (matching
%   the anisotropic P measured in project_stochastic_audit_rac3sigma's Probe A,
%   sub-longitude 23 deg -> 66 deg). The full projection must be IDENTICAL at both
%   epochs (rotation-invariant); the retired diagonal-only formula was not.
% =========================================================================
fprintf('  T1: racPositionSigma_ returns the full-covariance (rotation-invariant) sigma ...\n');

Re = 42164e3;
lam1 = 23; lam2 = 66;   % deg; lam2 = lam1 + 43 (near the worst diag/full ratio)
P1  = [10.7630 4.5500 -0.3042; 4.5500 2.7599 0.0109; -0.3042 0.0109 0.6987]; % measured, Probe A
Rz  = @(d) [cosd(d) -sind(d) 0; sind(d) cosd(d) 0; 0 0 1];
P2  = Rz(lam2-lam1) * P1 * Rz(lam2-lam1)';

r1 = Re*[cosd(lam1); sind(lam1); 0]; r2 = Re*[cosd(lam2); sind(lam2); 0];
w = revgnss.Constants.EARTH_OMEGA_RADPS;
v1 = cross([0;0;w], r1); v2 = cross([0;0;w], r2);   % v_ecef=0 (GEO); v_eff = omega x r

rEcef = [r1 r2]; vEcef = [v1 v2];
Pdiag = [diag(P1) diag(P2)];
Xoff  = [ [P1(1,2);P1(1,3);P1(2,3)], [P2(1,2);P2(1,3);P2(2,3)] ];

fakeDiagFull = struct('getData', @() struct('Pdiag',Pdiag,'PposOffDiag_m2',Xoff));
racSigFull = revgnss.ClockExactReportBuilder.racPositionSigma_(fakeDiagFull, rEcef, vEcef, 2);

[rH1,~,~,ok1] = revgnss.OrbitFrame.racBasis(r1, v1);
[rH2,~,~,ok2] = revgnss.OrbitFrame.racBasis(r2, v2);
assert(ok1 && ok2, 'T1 FAILED: degenerate RAC basis in synthetic setup');
sigFullExpected1 = sqrt(rH1' * P1 * rH1);
sigFullExpected2 = sqrt(rH2' * P2 * rH2);
sigDiagExpected1 = sqrt((rH1.^2)' * diag(P1));   % the retired (wrong) formula

tol = 1e-9;
assert(abs(racSigFull(1,1) - sigFullExpected1) < tol, ...
    'T1 FAILED: epoch 1 radial sigma does not match the full-covariance projection');
assert(abs(racSigFull(1,2) - sigFullExpected2) < tol, ...
    'T1 FAILED: epoch 2 radial sigma does not match the full-covariance projection');
assert(abs(racSigFull(1,1) - racSigFull(1,2)) < tol, ...
    'T1 FAILED: full-covariance radial sigma is not rotation-invariant (regressed to diagonal-only?)');
assert(abs(racSigFull(1,1) - sigDiagExpected1) > 0.1, ...
    'T1 FAILED: radial sigma matches the retired diagonal-only value, not the full projection');
fprintf('    sigma_radial (full, epoch1=lam%d) = %.6g m ; (epoch2=lam%d) = %.6g m (invariant, as expected)\n', ...
    lam1, racSigFull(1,1), lam2, racSigFull(1,2));
fprintf('    PASS\n');

% =========================================================================
% T2: racPositionSigma_ still degrades gracefully (diagonal-only) when
%   PposOffDiag_m2 is unavailable -- e.g. report data cached before this fix.
% =========================================================================
fprintf('  T2: racPositionSigma_ fallback (no PposOffDiag_m2) reproduces the diagonal-only sigma ...\n');
fakeDiagNoXoff = struct('getData', @() struct('Pdiag',Pdiag));
racSigFallback = revgnss.ClockExactReportBuilder.racPositionSigma_(fakeDiagNoXoff, rEcef, vEcef, 2);
assert(abs(racSigFallback(1,1) - sigDiagExpected1) < tol, ...
    'T2 FAILED: fallback path does not reproduce the diagonal-only formula');
fprintf('    sigma_radial (fallback, diagonal-only) = %.6g m\n', racSigFallback(1,1));
fprintf('    PASS\n');

% =========================================================================
% T3: per-type NIS (code/doppler/carrier) tracks the authoritative S-based NIS.
%   Short real sim (fast: ConfigFactory.defaultConfig, no report/plots, matching
%   test_stage8_doppler_in_ekf's lightweight pattern).
% =========================================================================
fprintf('  T3: per-type NIS (S-based) tracks the authoritative overall NIS ...\n');

cfg = revgnss.ConfigFactory.defaultConfig();
cfg.scenario.nTowers     = 5;
cfg.scenario.nReceivers  = 1;
cfg.simulation.duration_s = 300;
cfg.simulation.dt_s       = 1;
cfg.plots.enable  = false;
cfg.report.enable = false;

sim = revgnss.ReverseGNSSSimulation(cfg);
sim.run();
diagObj = sim.diag;

nisS = diagObj.getNIS();  nisS = nisS(:);
bt   = diagObj.getNISByType();
nisR = zerofix_(bt.code) + zerofix_(bt.doppler) + zerofix_(bt.carrier);
N = numel(nisS);
i0 = floor(0.3*N) + 1;   % post-burn-in
idx = (i0:N)';
ok = idx(isfinite(nisS(idx)) & isfinite(nisR(idx)) & nisS(idx) > 0);
assert(numel(ok) >= 20, 'T3 FAILED: too few valid post-burn-in epochs to judge consistency');

ratio = nisR(ok) ./ nisS(ok);
medRatio = median(ratio);
fprintf('    median (per-type sum)/(authoritative S-based) = %.5f  [pre-fix was ~1.01-1.02, up to 1.2]\n', medRatio);
assert(abs(medRatio - 1) < 0.05, ...
    sprintf('T3 FAILED: per-type NIS departs from the authoritative S-based NIS by %.1f%% (expected <5%%; R-based bias would read higher)', ...
    100*abs(medRatio-1)));
fprintf('    PASS\n');

fprintf('=== test_rac_sigma_and_pertype_nis_correctness: ALL PASS ===\n');

function v = zerofix_(x)
    v = x(:); v(~isfinite(v)) = 0;
end
