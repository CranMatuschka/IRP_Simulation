% test_clock_allan_model  Verify ClockModel Allan deviation matches noise type.
%
% Three configurations are tested:
%   1. Dominant White FM (h0):    slope should be approximately -0.5 on log-log
%   2. Dominant RWFM (hMinus2):   slope should be approximately +0.5 on log-log
%   3. OCXO mix:                  ADEV curves differ between the three configs
%
% The test is qualitative (slope direction), not metrology-grade.

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_clock_allan_model ===\n');

DUR = 3600;  % long enough for meaningful ADEV
DT  = 1.0;
tVec = 0:DT:DUR;

% --- Config 1: White FM dominant ----------------------------------------
cfg1 = struct('name','WFM','clockType','WFM', ...
    'noiseCoeffs', struct('h2',0,'h1',0,'h0',1e-20,'hMinus1',0,'hMinus2',0), ...
    'deterministic', false, 'seed', 11, 'bias_s', 0, 'fracFreq', 0);
clk1 = models.clocks.ClockModel(cfg1);
clk1.precomputeNoise(tVec);
for k=1:numel(tVec); clk1.step(DT); end

% --- Config 2: RWFM dominant --------------------------------------------
cfg2 = struct('name','RWFM','clockType','RWFM', ...
    'noiseCoeffs', struct('h2',0,'h1',0,'h0',0,'hMinus1',0,'hMinus2',1e-20), ...
    'deterministic', false, 'seed', 22, 'bias_s', 0, 'fracFreq', 0);
clk2 = models.clocks.ClockModel(cfg2);
clk2.precomputeNoise(tVec);
for k=1:numel(tVec); clk2.step(DT); end

% --- Config 3: OCXO mix -------------------------------------------------
cfg3 = struct('name','OCXO','clockType','OCXO', ...
    'noiseCoeffs', struct('h2',0,'h1',0,'h0',2e-25,'hMinus1',7e-27,'hMinus2',2e-29), ...
    'deterministic', false, 'seed', 33, 'bias_s', 0, 'fracFreq', 0);
clk3 = models.clocks.ClockModel(cfg3);
clk3.precomputeNoise(tVec);
for k=1:numel(tVec); clk3.step(DT); end

% --- Compute ADEV -------------------------------------------------------
tauV = logspace(0, log10(DUR/4), 20);

[~, adev1] = clk1.allanDeviation(tauV);
[~, adev2] = clk2.allanDeviation(tauV);
[~, adev3] = clk3.allanDeviation(tauV);

% Estimate slope on valid points
validIdx = ~isnan(adev1) & adev1 > 0;
if sum(validIdx) >= 4
    slope1 = polyfit(log10(tauV(validIdx)), log10(adev1(validIdx)), 1);
    fprintf('  WFM dominant slope  : %.2f (expected ~ -0.5)\n', slope1(1));
else
    slope1(1) = NaN;
    fprintf('  WFM: insufficient valid ADEV points\n');
end

validIdx2 = ~isnan(adev2) & adev2 > 0;
if sum(validIdx2) >= 4
    slope2 = polyfit(log10(tauV(validIdx2)), log10(adev2(validIdx2)), 1);
    fprintf('  RWFM dominant slope : %.2f (expected ~ +0.5)\n', slope2(1));
else
    slope2(1) = NaN;
    fprintf('  RWFM: insufficient valid ADEV points\n');
end

% Assert 1: WFM slope is decreasing (negative)
if ~isnan(slope1(1))
    assert(slope1(1) < 0, ...
        'test_clock_allan_model FAILED: WFM slope should be < 0, got %.2f', slope1(1));
end

% Assert 2: RWFM slope is increasing (positive)
if ~isnan(slope2(1))
    assert(slope2(1) > 0, ...
        'test_clock_allan_model FAILED: RWFM slope should be > 0, got %.2f', slope2(1));
end

% Assert 3: ADEV values differ between the three configurations
valid = ~isnan(adev1) & ~isnan(adev2) & ~isnan(adev3) & adev1>0 & adev3>0;
assert(sum(valid) >= 3, ...
    'test_clock_allan_model FAILED: too few valid ADEV points for comparison');
ratio13 = mean(adev1(valid)) / mean(adev3(valid));
assert(abs(log10(ratio13)) > 1, ...
    'test_clock_allan_model FAILED: WFM and OCXO ADEV curves are suspiciously similar');

fprintf('  All three clock types have distinct ADEV curves: PASS\n');

% --- Magnitude check (WP-8): theoretical RWFM ADEV matches the empirical curve
% After the coefficient fix the theoretical overlay uses sigma_y^2 = (2*pi^2/3) h_-2 tau,
% which matches the empirical RWFM ADEV; the old (8*pi^2/6 = 4*pi^2/3) was sqrt(2) high,
% so the median theoretical/empirical ratio would sit near 1.41 instead of ~1.
[~, adev2_th] = clk2.theoreticalAllanDeviation(tauV);
at = adev2_th(:); ae = adev2(:); tv = tauV(:);
midMask = tv >= 3 & tv <= DUR/8 & ae > 0 & ~isnan(ae) & isfinite(at) & at > 0;
assert(sum(midMask) >= 4, ...
    'test_clock_allan_model FAILED: too few valid RWFM points for the magnitude check');
medRatio = median(at(midMask) ./ ae(midMask));
fprintf('  RWFM theoretical/empirical ADEV median ratio: %.3f (expect ~1, not ~1.41)\n', medRatio);
assert(medRatio > 0.6 && medRatio < 1.25, ...
    ['test_clock_allan_model FAILED: RWFM theoretical ADEV magnitude off ' ...
     '(median ratio %.3f); check the RWFM coefficient (WP-8: 2*pi^2/3).'], medRatio);

fprintf('=== test_clock_allan_model PASS ===\n');
