% test_clock_truth_matches_filter_q  The TRUTH clock and the EKF's Q must be the SAME process.
%
% WHY THIS TEST EXISTS. Until 2026-08-09 they were not, and the disagreement was
% per-oscillator: jow CESIUM1 was the ONE template where the channel that drives the
% measurement (Q11) happened to match. Found while auditing the config/ladder/clock axis.
%
% SCOPE -- READ THIS BEFORE CITING THE TEST. The mismatch was real and is MEASURED below,
% but it is NOT the cause of that axis's NIS blow-up (78 for caesium against 389-1397 for
% OCXO/rubidium, expected 105). Fixing both defects moved NIS by less than 0.1 in all six
% controlled runs: caesium 102.1 -> 102.1, OCXO 410.8 -> 410.9, rubidium 615.0 -> 615.0
% (errors off), and 75.9/384.5/588.7 -> 75.9/384.6/588.6 (errors on). The reason is that
% Q11 was already correct in magnitude -- the TRUTH was the under-noisy side -- so making
% the truth exact adds real noise without changing the filter's covariance. This test
% guards a correctness property of the clock pairing, nothing more. The NIS pattern has a
% separate, still-unidentified cause; do not close that investigation on the strength of
% this test passing.
%
% Two defects, both fixed:
%   1. ClockModel.step was forward Euler: the RWFM frequency kick landed only on the NEXT
%      step, so the truth never generated the within-step q2*dt^3/3 phase term (nor the
%      q2*dt^2/2 cross-covariance) that getProcessNoiseQ charges. sqrt(Q11)/empirical was
%      0.01 for jow OCXO -- the filter charging 100x a process noise its truth never made.
%   2. Flicker FM (hMinus1) is synthesised by precomputeNoise but had no representation in Q
%      beyond an unsourced term, leaving Q22 50-921x too small for flicker-dominated clocks.
%      It is now carried as its Allan-equivalent random walk.
%
% The test compares Q against the truth's OWN two-state prediction residual. NOTE the metric:
% e_b must have the tracked frequency predicted out, e_b = b(k+1) - b(k) - bdot(k)*dt. A
% naive std(diff(b)) charges Q for the bdot state the filter already estimates and reports a
% spurious 12x on OCXO -- that mistake was made once and must not be repeated here.

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));
addpath(fullfile(thisDir, '..', 'config'));
addpath(fullfile(thisDir, '..', 'config', 'internal'));

fprintf('=== test_clock_truth_matches_filter_q ===\n');

N = 901; dt = 1.0; tVec = (0:N-1)'*dt; nSeed = 8;
factors = struct('biasFactor',1,'freqFactor',1,'noiseFactor',1,'roleNoiseFactor',1, ...
                 'h2Factor',1,'h1Factor',1,'h0Factor',1,'hMinus1Factor',1,'hMinus2Factor',1);

% Both shipped tables, every template that carries noise. ZERO is excluded (no noise to match).
for src = {'legacy','jowTable2p1'}
    scaling = struct('templateSource',src{1},'globalBiasFactor',1, ...
                     'globalFreqFactor',1,'globalNoiseFactor',1);
    for tt = {'CESIUM1','RUBIDIUM','OCXO','TCXO'}
        rb = zeros(1,nSeed); rd = zeros(1,nSeed);
        for r = 1:nSeed
            cc = revgnss.ConfigFactory.makeClockConfig(tt{1}, 7000+137*r, factors, scaling);
            cc.deterministic = false; cc.bias_s = 0; cc.fracFreq = 0;
            clk = models.clocks.ClockModel(cc);
            clk.precomputeNoise(tVec);          % arm the coloured path exactly as the sim does
            b = zeros(1,N); d = zeros(1,N);
            for i = 2:N
                clk.step(dt);
                b(i) = clk.getBiasMeters();
                d(i) = clk.getDriftMetersPerSecond();
            end
            Q = clk.getProcessNoiseQ(dt, 'meters');
            e_b = b(3:end) - b(2:end-1) - d(2:end-1)*dt;   % predict the tracked bdot out
            e_d = d(3:end) - d(2:end-1);
            rb(r) = std(e_b) / sqrt(Q(1,1));
            rd(r) = std(e_d) / sqrt(Q(2,2));
        end
        mb = mean(rb); md = mean(rd);
        fprintf('  %-12s %-11s phase %.3f  freq %.3f\n', src{1}, tt{1}, mb, md);

        % Band: Q must be neither optimistic nor wildly conservative. The upper bound is the
        % one that matters for filter consistency (Q too small -> NIS blows up); the lower
        % bound catches a Q inflated to hide a modelling error. Flicker is not exactly a
        % random walk, so the equivalence is deliberately ~10% conservative on the frequency
        % channel -- hence the asymmetric floor.
        assert(mb > 0.75 && mb < 1.30, ...
            ['PHASE channel FAILED for %s/%s: sqrt(Q11) vs truth ratio %.3f. ' ...
             'Q11 and ClockModel.step must implement the same discretisation ' ...
             '(q1*dt + q2*dt^3/3); a forward-Euler step gives ~0.01 here for RWFM-dominated ' ...
             'templates.'], src{1}, tt{1}, mb);
        assert(md > 0.75 && md < 1.30, ...
            ['FREQUENCY channel FAILED for %s/%s: sqrt(Q22) vs truth ratio %.3f. ' ...
             'Q22 must carry flicker FM as its Allan-equivalent random walk ' ...
             '(6*ln(2)*hMinus1/dt); without it this is 50-921x for flicker-dominated ' ...
             'templates.'], src{1}, tt{1}, md);
    end
end

% ---- The equivalence is a derivation, not a tuning constant: check the algebra ----------
% RWFM sigma_y^2(tau) = (2*pi^2/3)*hMinus2*tau  ==  flicker sigma_y^2 = 2*ln(2)*hMinus1
% at tau = dt  =>  q2_ffm = 2*pi^2*hMinus2_eq = 6*ln(2)*hMinus1/dt.
cc = revgnss.ConfigFactory.makeClockConfig('CESIUM1', 11, factors, ...
        struct('templateSource','jowTable2p1','globalBiasFactor',1, ...
               'globalFreqFactor',1,'globalNoiseFactor',1));
clk = models.clocks.ClockModel(cc);
c_mps = revgnss.Constants.SPEED_OF_LIGHT_MPS;
for dtTest = [0.1 1 10]
    Q = clk.getProcessNoiseQ(dtTest, 'seconds');
    h = cc.noiseCoeffs;
    q2_expected = 2*pi^2*h.hMinus2 + 6*log(2)*h.hMinus1/dtTest;
    assert(abs(Q(2,2) - q2_expected*dtTest) <= 1e-12*abs(Q(2,2)) + realmin, ...
        'Q22 does not equal q2_eff*dt at dt=%g (%.6e vs %.6e).', ...
        dtTest, Q(2,2), q2_expected*dtTest);
    assert(abs(Q(1,2) - q2_expected*dtTest^2/2) <= 1e-12*abs(max(Q(1,2),realmin)) + realmin, ...
        'Q12 does not equal q2_eff*dt^2/2 at dt=%g.', dtTest);
    % Meters representation is the same matrix scaled by c^2.
    Qm = clk.getProcessNoiseQ(dtTest, 'meters');
    assert(abs(Qm(2,2) - Q(2,2)*c_mps^2) <= 1e-9*abs(Qm(2,2)), ...
        'meters/seconds representations disagree at dt=%g.', dtTest);
end

% ---- A deterministic clock must still be exactly noiseless ------------------------------
cc.deterministic = true; cc.bias_s = 0; cc.fracFreq = 0;
clkDet = models.clocks.ClockModel(cc);
clkDet.precomputeNoise(tVec);
bDet = zeros(1,N);
for i = 2:N; clkDet.step(dt); bDet(i) = clkDet.getBiasMeters(); end
assert(max(abs(bDet)) == 0, ...
    'A deterministic clock produced |b|max = %.3e m; it must be identically zero.', ...
    max(abs(bDet)));

fprintf('=== test_clock_truth_matches_filter_q PASSED ===\n');
