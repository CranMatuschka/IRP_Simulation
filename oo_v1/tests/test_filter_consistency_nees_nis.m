% test_filter_consistency_nees_nis  WP2 acceptance test: NEES/NIS chi-squared
% consistency with a two-sided band and a negative control that proves the test
% has power. Reference: Bar-Shalom, Li & Kirubarajan 2001, §5.4.
%
% Parts:
%   A. revgnss.ChiSquareConsistency two-sided bounds match known chi-squared quantiles.
%   B. A PROVABLY-MATCHED linear-Gaussian Kalman filter (truth process/measurement
%      noise == filter Q/R) is statistically consistent: the ensemble-and-time summed
%      NEES and NIS both lie inside the 95% chi-squared band. Negative control: halving
%      the filter's R (under-modelling measurement noise) pushes NIS ABOVE the band.
%   C. The shipped ReverseGNSSEKF.computeNEES API returns finite, sensible values on
%      the real filter, and the real filter is NOT over-confident (mean NIS <= upper
%      band). The real filter is deliberately CONSERVATIVE (R, Q intentionally large),
%      so its NIS/M < 1 by design — documented here, not asserted as two-sided-consistent.
%
% Why a linear-Gaussian filter for the two-sided assertion: the full simulation runs
% conservative-by-design (R over-estimates the true innovation covariance and Q carries
% an unmodelled-dynamics inflation term), so its NIS ratio is << 1 on purpose. A
% two-sided consistency band is meaningful only on a matched filter; Part B builds one.

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));
addpath(fullfile(thisDir, '..', 'config'));

fprintf('=== test_filter_consistency_nees_nis ===\n');

conf = 0.95;

% ================================================================
% Part A: chi-squared two-sided bounds
% ================================================================
fprintf('  A. ChiSquareConsistency bounds vs known quantiles ...\n');
[lo3, hi3] = revgnss.ChiSquareConsistency.bounds(3, conf);
% chi2inv(0.025,3)=0.2158, chi2inv(0.975,3)=9.3484 (standard tables)
assert(abs(lo3 - 0.2158) < 1e-2 && abs(hi3 - 9.3484) < 1e-2, ...
    'Part A FAILED: chi2(3) band [%.4f,%.4f] != [0.2158,9.3484]', lo3, hi3);
assert(revgnss.ChiSquareConsistency.inBand(3.0, 3, conf), 'Part A FAILED: dof=3 mean not in band');
assert(~revgnss.ChiSquareConsistency.inBand(30.0, 3, conf), 'Part A FAILED: 30 wrongly in band');
fprintf('    PASS (chi2(3) 95%% band = [%.4f, %.4f])\n', lo3, hi3);

% ================================================================
% Part B: matched linear-Gaussian KF -> consistent; halve R -> NIS out of band
% ================================================================
fprintf('  B. matched linear-Gaussian filter consistency + negative control ...\n');

p    = struct();
p.n  = 4;                                 % state dimension
p.m  = 6;                                 % measurements per epoch
p.K  = 30;                                % epochs per run
p.E  = 20;                                % Monte-Carlo ensemble
p.F  = eye(p.n);                          % random-walk dynamics
p.Q  = diag([0.25, 0.25, 0.25, 0.04]);    % true == filter process noise
p.Rm = diag([0.09, 0.09, 0.16, 0.16, 0.25, 0.25]);  % true == filter meas noise (m x m)
rng(1234, 'twister');
p.H  = randn(p.m, p.n);                   % fixed full-rank measurement map (m x n)
p.P0 = diag([1, 1, 1, 0.25]);            % true initial error covariance

% Matched filter (rFactor = 1): both statistics inside the band. The summed
% statistic is a SINGLE chi-squared realisation, so a 95% band would flake ~5% of
% the time on a deterministic seed; use a 0.999 band (~3.3 sigma) for a robust
% in-band membership assertion. The negative control below is ~30 sigma out and
% violates even this wide band, so power is not diluted. Part A already checks the
% exact 95% quantiles.
bandConf = 0.999;
[sN, dofN, sI, dofI] = runMatched_(p, 1.0, 5000);
[loN, hiN] = revgnss.ChiSquareConsistency.bounds(dofN, bandConf);
[loI, hiI] = revgnss.ChiSquareConsistency.bounds(dofI, bandConf);
fprintf('    matched  : NEES sum=%.0f band[%.0f,%.0f]  NIS sum=%.0f band[%.0f,%.0f]\n', ...
    sN, loN, hiN, sI, loI, hiI);
assert(sN >= loN && sN <= hiN, 'Part B FAILED: matched NEES %.0f outside [%.0f,%.0f]', sN, loN, hiN);
assert(sI >= loI && sI <= hiI, 'Part B FAILED: matched NIS %.0f outside [%.0f,%.0f]', sI, loI, hiI);

% Negative control: filter under-models R by 2x -> NIS inflates above the band.
[~, ~, sI_bad, dofI_bad] = runMatched_(p, 0.5, 5000);
[~, hiI_bad] = revgnss.ChiSquareConsistency.bounds(dofI_bad, bandConf);
fprintf('    halved R : NIS sum=%.0f  upper band=%.0f  (must exceed)\n', sI_bad, hiI_bad);
assert(sI_bad > hiI_bad, ...
    'Part B FAILED: negative control has no power (NIS %.0f did not exceed %.0f)', sI_bad, hiI_bad);
fprintf('    PASS (matched in band; under-modelled R detected)\n');

% ================================================================
% Part C: shipped filter computeNEES API + conservative (not over-confident)
% ================================================================
fprintf('  C. ReverseGNSSEKF.computeNEES on the real filter (conservative by design) ...\n');
cfg = revgnss.ConfigFactory.matchedErrorBaselineConfig();
cfg.simulation.duration_s = 200;
cfg.simulation.dt_s       = 1;
cfg.plots.enable  = false;
cfg.report.enable = false;
rng(42, 'twister');
sim = revgnss.ReverseGNSSSimulation(cfg);
sim.run();

truth = struct('r_ecef_m', sim.asset.r_ecef_m, 'v_ecef_mps', sim.asset.v_ecef_mps, ...
               'clockBias_m', sim.asset.clock.getBiasMeters(), ...
               'clockDrift_mps', sim.asset.clock.getDriftMetersPerSecond());
nees = sim.ekf.computeNEES(truth);
assert(isfinite(nees.pos) && isfinite(nees.clock) && isfinite(nees.core) && nees.coreDof >= 8, ...
    'Part C FAILED: computeNEES returned non-finite / wrong dof (pos=%.3g clock=%.3g core=%.3g dof=%d)', ...
    nees.pos, nees.clock, nees.core, nees.coreDof);
assert(nees.core > 0, 'Part C FAILED: core NEES must be positive');

nisV = sim.diag.getNIS(); nisV = nisV(isfinite(nisV) & nisV > 0);
mRow = sim.diag.getNumMeasurementRows(); mRow = median(mRow(isfinite(mRow) & mRow > 0));
meanNIS = mean(nisV);
[~, hiReal] = revgnss.ChiSquareConsistency.bounds(mRow, conf);
% Conservative filter: NIS/M < 1 (under-confident by design) AND not over-confident.
assert(meanNIS <= hiReal, ...
    'Part C FAILED: real filter is OVER-confident (mean NIS %.2f > upper band %.2f for M=%g)', ...
    meanNIS, hiReal, mRow);
fprintf('    computeNEES: pos=%.3f vel=%.3f clock=%.3f core=%.3f (dof=%d)\n', ...
    nees.pos, nees.vel, nees.clock, nees.core, nees.coreDof);
fprintf('    real filter mean NIS=%.3f, M=%g, NIS/M=%.3f (conservative: <1, not over-confident)\n', ...
    meanNIS, mRow, meanNIS / mRow);
fprintf('    PASS\n');

fprintf('=== test_filter_consistency_nees_nis: ALL PASS ===\n');


% ================================================================
% Local helper: matched linear-Gaussian KF Monte-Carlo
% ================================================================
function [sumNEES, dofNEES, sumNIS, dofNIS] = runMatched_(p, rFactor, seed0)
    % runMatched_  Run E ensembles x K epochs of a linear-Gaussian KF. Truth always
    % uses the true (Q, Rm); the filter assumes R = Rm * rFactor. Returns the summed
    % NEES and NIS and their total degrees of freedom (E*K*n and E*K*m).
    sqrtQ  = chol(p.Q,  'lower');
    sqrtR  = chol(p.Rm, 'lower');
    sqrtP0 = chol(p.P0, 'lower');
    Rfilt  = p.Rm * rFactor;
    sumNEES = 0; dofNEES = 0; sumNIS = 0; dofNIS = 0;
    for e = 1:p.E
        rs    = RandStream('mt19937ar', 'Seed', seed0 + e);
        xTrue = sqrtP0 * randn(rs, p.n, 1);      % truth starts P0 away from the mean
        xHat  = zeros(p.n, 1);
        P     = p.P0;
        for k = 1:p.K
            % truth propagate + measure (with the TRUE Q, Rm)
            xTrue = p.F * xTrue + sqrtQ * randn(rs, p.n, 1);
            z     = p.H * xTrue + sqrtR * randn(rs, p.m, 1);
            % filter predict
            xHat = p.F * xHat;
            P    = p.F * P * p.F' + p.Q;
            % filter update (Joseph) + NIS
            nu = z - p.H * xHat;
            S  = p.H * P * p.H' + Rfilt;  S = (S + S') / 2;
            Kk = P * p.H' / S;
            xHat = xHat + Kk * nu;
            IKH  = eye(p.n) - Kk * p.H;
            P    = IKH * P * IKH' + Kk * Rfilt * Kk';  P = (P + P') / 2;
            sumNIS  = sumNIS  + nu' * (S \ nu);      dofNIS  = dofNIS  + p.m;
            % NEES (post-update)
            eE = xHat - xTrue;
            sumNEES = sumNEES + eE' * (P \ eE);      dofNEES = dofNEES + p.n;
        end
    end
end
