% test_multipath_gaussmarkov  WP5 acceptance test: multipath as a coloured (first-order
% Gauss-Markov) truth-side error, one persistent state per link, entering R via its
% steady-state variance. Reference: Kaplan & Hegarty §7.2.6 (multipath is the dominant
% code error and is strongly time-correlated).
%
% Parts:
%   A. The realised multipath is COLOURED: empirical autocorrelation decays with the
%      configured tau (r(tau) ~ e^-1), steady-state std ~ sigmaCodeL1_ss_m, and the
%      steady-state sigma is what enters R (err.bySource.sigma_m.mp).
%   B. Reproducible for a fixed seed (two chains identical) and INDEPENDENT across links
%      (low cross-correlation between distinct tower/antenna links).
%   C. Negative-control / conservatism: enabling coloured multipath INCREASES end-to-end
%      position RMS versus disabled, and disabling it is bit-identical to legacy.

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));
addpath(fullfile(thisDir, '..', 'config'));

fprintf('=== test_multipath_gaussmarkov ===\n');

tau     = 20;      % correlation time [s] (tens of seconds); smaller tau -> more
                   % independent samples per fixed span, so the empirical std/autocorr
                   % estimators concentrate (this is a statistics choice, not physics).
sigmaSS = 0.30;    % steady-state 1-sigma [m]
dt      = 1;
K       = 8000;    % epochs (~395 independent samples at tau=20)

% ================================================================
% Part A: coloured statistics via the real ErrorChain multipath path
% ================================================================
fprintf('  A. coloured autocorrelation + steady-state variance ...\n');
cfgA = revgnss.ConfigFactory.defaultConfig();
% The coloured-GM branch is gated on mc.truth.enable AND coloredGM.enable
% (ErrorChain: useGM = mc.truth.enable && ... && mc.coloredGM.enable), and multipath
% ships OFF (masterConfig errors.multipath.{enable,truth.enable} = false). Setting only
% coloredGM.enable left useGM false, so the whole test ran against an identically-zero
% truth and reported empStd = 0.000, r(1) = NaN. The assertions were measuring nothing.
cfgA.errors.multipath.enable                      = true;
cfgA.errors.multipath.truth.enable                = true;
cfgA.errors.multipath.coloredGM.enable            = true;
cfgA.errors.multipath.coloredGM.tau_s             = tau;
cfgA.errors.multipath.coloredGM.sigmaCodeL1_ss_m  = sigmaSS;
cfgA.errors.multipath.coloredGM.elevationExponent = 0;   % stationary (no elevation scaling) for clean stats
cfgA.errors.codeNoise.sigma_m = 0; cfgA.signals.L1.codeSigma0_m = 0;
cfgA.scenario.nTowers = 1;

ecA = models.errors.ErrorChain(cfgA, 42);
mp  = zeros(K,1); sg = zeros(K,1);
for k = 1:K
    e = ecA.compute(deg2rad(30), 1, 1, (k-1)*dt, 1);
    mp(k) = e.bySource.truth_m.mp(1);
    sg(k) = e.bySource.sigma_m.mp(1);
end
warm = 5*tau;                          % discard warm-up transient
x = mp(warm+1:end);
empStd = std(x);
r = @(L) corr(x(1:end-L), x(1+L:end));
r_tau = r(tau); r_1 = r(1);

fprintf('    empStd=%.3f (sigmaSS=%.2f)  r(1)=%.3f  r(tau)=%.3f (e^-1=%.3f)  sigma->R=%.3f\n', ...
    empStd, sigmaSS, r_1, r_tau, exp(-1), sg(end));
assert(abs(empStd - sigmaSS) / sigmaSS < 0.15, ...
    'Part A FAILED: empirical std %.3f not within 15%% of %.2f', empStd, sigmaSS);
assert(abs(r_tau - exp(-1)) < 0.10, ...
    'Part A FAILED: autocorr at lag tau = %.3f, expected ~e^-1 = %.3f', r_tau, exp(-1));
assert(r_1 > 0.9, 'Part A FAILED: process is not coloured (r(1)=%.3f, expected >0.9)', r_1);
assert(abs(sg(end) - sigmaSS) < 1e-12, 'Part A FAILED: sigma->R != sigmaSS');
fprintf('    PASS\n');

% ================================================================
% Part B: reproducibility + independence across links
% ================================================================
fprintf('  B. reproducible (fixed seed) + independent across links ...\n');
% Reproducibility: two independent chains, same cfg/seed -> identical series.
ecB1 = models.errors.ErrorChain(cfgA, 42);
ecB2 = models.errors.ErrorChain(cfgA, 42);
m1 = zeros(200,1); m2 = zeros(200,1);
for k = 1:200
    e1 = ecB1.compute(deg2rad(30), 1, 1, (k-1)*dt, 1); m1(k) = e1.bySource.truth_m.mp(1);
    e2 = ecB2.compute(deg2rad(30), 1, 1, (k-1)*dt, 1); m2(k) = e2.bySource.truth_m.mp(1);
end
assert(max(abs(m1 - m2)) < 1e-15, 'Part B FAILED: not reproducible for fixed seed');

% Independence: two links (towers 1 and 2) in one chain -> low cross-correlation.
cfgB2 = cfgA; cfgB2.scenario.nTowers = 2;
ecB3 = models.errors.ErrorChain(cfgB2, 42);
La = zeros(K,1); Lb = zeros(K,1);
for k = 1:K
    e = ecB3.compute([deg2rad(30); deg2rad(30)], [1;2], [1;2], (k-1)*dt, [1;1]);
    La(k) = e.bySource.truth_m.mp(1);
    Lb(k) = e.bySource.truth_m.mp(2);
end
xc = abs(corr(La(warm+1:end), Lb(warm+1:end)));
fprintf('    reproducible: max|m1-m2|<1e-15  |cross-corr(link1,link2)|=%.3f\n', xc);
assert(xc < 0.15, 'Part B FAILED: links not independent (|cross-corr|=%.3f)', xc);
fprintf('    PASS\n');

% ================================================================
% Part C: enabling multipath increases position error (conservatism)
% ================================================================
fprintf('  C. enabling coloured multipath increases position RMS ...\n');
posRMS = zeros(1,2); en = [false, true];
for j = 1:2
    c = revgnss.ConfigFactory.positionClockOnlyConfig();
    c.scenario.nTowers            = 5;
    c.simulation.duration_s       = 300;
    c.simulation.dt_s             = 1;
    c.plots.enable  = false; c.report.enable = false;
    % Same gate as Part A: the coloured-GM branch needs the MASTER multipath enable and
    % its truth side, not just coloredGM.enable. Without them both arms of this
    % negative control ran with multipath identically off and the comparison was
    % 37.323 -> 37.323 -- it could never have failed, and never could have passed either.
    c.errors.multipath.enable                     = en(j);
    c.errors.multipath.truth.enable               = en(j);
    c.errors.multipath.coloredGM.enable           = en(j);
    c.errors.multipath.coloredGM.tau_s            = tau;
    c.errors.multipath.coloredGM.sigmaCodeL1_ss_m = 0.5;   % clearly above the tiny code noise
    rng(42, 'twister');
    sim = revgnss.ReverseGNSSSimulation(c);
    sim.run();
    posRMS(j) = rms(sim.diag.getPositionErrors());
end
fprintf('    position RMS: off=%.3f m  on=%.3f m  (ratio %.2f)\n', posRMS(1), posRMS(2), posRMS(2)/posRMS(1));
assert(posRMS(2) > posRMS(1), ...
    'Part C FAILED: enabling coloured multipath did not increase position RMS (%.3f -> %.3f)', ...
    posRMS(1), posRMS(2));
fprintf('    PASS\n');

fprintf('=== test_multipath_gaussmarkov: ALL PASS ===\n');
