% test_gaseous_absorption
% The frozen ITU-R P.676-13 Annex 1 zenith table and its slant composition.
%
% WHAT THIS PINS, and why each one is here rather than being obvious:
%
%   1. the table reproduces the generator's output exactly -- if someone edits
%      GaseousAbsorption.TABLE_* by hand instead of re-running the generator, the
%      published values below stop matching and this fails
%   2. off-table frequencies HARD ERROR. Absorption is non-smooth near the 22.235 GHz
%      water line and through the 54-66 GHz oxygen complex, so a silently interpolated
%      value would be indistinguishable from a computed one
%   3. at zenith with reference humidity the slant value is EXACTLY A_dry + A_wet.
%      This is the identity the whole two-column design rests on
%   4. the wet column, and ONLY the wet column, follows tower humidity. A bug that
%      scaled the total would be invisible at L-band (wet is 0.6% there) and would
%      corrupt 24 GHz (wet is 81%)
%   5. attenuation grows towards the horizon, and 'niell' splits m_h from m_w. If the
%      two mappings were accidentally identical the dry/wet split would buy nothing
%   6. the three physical conclusions the plan draws: negligible below 6 GHz, ~4.6% on
%      sigma at 24 GHz, and NO LINK at 61.25 GHz. If a future table edit breaks one of
%      these, the ch8 claim built on it breaks with it
%   7. the guards reject non-physical input
%
% Published-value cross-checks come from the generator's own validation against an
% independent P.676 transcription (analysis/compare_p676_implementations.m), which gets
% EXACTLY zero relative error on the dry path. This test does not need the toolbox.

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_gaseous_absorption ===\n');

GA    = 'models.atmosphere.GaseousAbsorption';
nFail = 0;
el90  = pi/2;

% ---- 1. The frozen table is what the generator produced --------------------
% Spot values, transcribed from analysis/generate_gas_absorption_table.m output.
% dry, wet, in dB.
expect = { ...
    0.915e9,   0.030157, 0.000072; ...
    1.57542e9, 0.033786, 0.000213; ...
    5.800e9,   0.037373, 0.003009; ...
    24.125e9,  0.073387, 0.317082; ...
    61.250e9,  161.194782, 0.272657};

for k = 1:size(expect,1)
    [d, w] = models.atmosphere.GaseousAbsorption.zenithDryWet(expect{k,1});
    nFail = nFail + chk(abs(d - expect{k,2}) < 1e-9, ...
        sprintf('A_dry at %.3f GHz is %.6f, expected %.6f', expect{k,1}/1e9, d, expect{k,2}));
    nFail = nFail + chk(abs(w - expect{k,3}) < 1e-9, ...
        sprintf('A_wet at %.3f GHz is %.6f, expected %.6f', expect{k,1}/1e9, w, expect{k,3}));
end

% The table's three arrays must stay the same length or the lookup silently
% pairs a frequency with the wrong attenuation.
nF = numel(models.atmosphere.GaseousAbsorption.TABLE_F_HZ);
nD = numel(models.atmosphere.GaseousAbsorption.TABLE_A_DRY_DB);
nW = numel(models.atmosphere.GaseousAbsorption.TABLE_A_WET_DB);
nFail = nFail + chk(nF == nD && nF == nW, ...
    sprintf('table columns disagree in length (f %d, dry %d, wet %d)', nF, nD, nW));

% ---- 2. Off-table frequencies are refused, not interpolated ----------------
offTable = {1.2e9, 10e9, 22.235e9, 60e9, 100e9};
for k = 1:numel(offTable)
    ok = false;
    try
        models.atmosphere.GaseousAbsorption.zenithDryWet(offTable{k});
    catch ME
        ok = strcmp(ME.identifier, 'GaseousAbsorption:frequencyNotTabulated');
    end
    nFail = nFail + chk(ok, sprintf('off-table %.3f GHz is refused', offTable{k}/1e9));
end

% isTabulated agrees with what zenithDryWet will do, rather than being a second opinion.
nFail = nFail + chk(models.atmosphere.GaseousAbsorption.isTabulated(1.57542e9), ...
    'isTabulated true for L1');
nFail = nFail + chk(~models.atmosphere.GaseousAbsorption.isTabulated(10e9), ...
    'isTabulated false for 10 GHz');

% ---- 3. Zenith identity: A = A_dry + A_wet exactly -------------------------
% 'simple' mapping is 1/sin(el), which is exactly 1 at el = 90 deg, and the default
% ZWD is the reference, so the wet ratio is exactly 1. Any deviation means the
% composition is not the one documented.
for k = 1:size(expect,1)
    f      = expect{k,1};
    [d, w] = models.atmosphere.GaseousAbsorption.zenithDryWet(f);
    A      = models.atmosphere.GaseousAbsorption.slantAttenuation_dB(f, el90);
    nFail  = nFail + chk(abs(A - (d+w)) < 1e-12 * max(1, d+w), ...
        sprintf('zenith slant at %.3f GHz is %.9f, expected %.9f', f/1e9, A, d+w));
end

% ---- 4. Humidity scales the WET column only --------------------------------
% Doubling the tower ZWD must add exactly one more A_wet at zenith and leave A_dry
% untouched. Getting this wrong is invisible at L1 and ruinous at 24 GHz.
zwdRef = models.atmosphere.GaseousAbsorption.ZWD_REF_M;
for f = [1.57542e9, 24.125e9]
    [d, w] = models.atmosphere.GaseousAbsorption.zenithDryWet(f);
    A2     = models.atmosphere.GaseousAbsorption.slantAttenuation_dB( ...
                 f, el90, struct('ZWD_m', 2*zwdRef));
    nFail  = nFail + chk(abs(A2 - (d + 2*w)) < 1e-12 * max(1, d + 2*w), ...
        sprintf('double ZWD at %.3f GHz gives %.9f, expected %.9f', f/1e9, A2, d + 2*w));

    A0 = models.atmosphere.GaseousAbsorption.slantAttenuation_dB(f, el90, struct('ZWD_m', 0));
    nFail = nFail + chk(abs(A0 - d) < 1e-12 * max(1, d), ...
        sprintf('zero ZWD at %.3f GHz gives %.9f, expected the dry column %.9f', f/1e9, A0, d));
end

% ---- 5. Obliquity: grows towards the horizon, and niell splits m_h from m_w -
fL1  = 1.57542e9;
els  = deg2rad([90 60 30 10 5]);
prev = -inf;
mono = true;
for e = els
    A = models.atmosphere.GaseousAbsorption.slantAttenuation_dB(fL1, e);
    if A < prev; mono = false; end
    prev = A;
end
nFail = nFail + chk(mono, 'slant attenuation increases monotonically towards the horizon');

A90 = models.atmosphere.GaseousAbsorption.slantAttenuation_dB(fL1, el90);
A10 = models.atmosphere.GaseousAbsorption.slantAttenuation_dB(fL1, deg2rad(10));
nFail = nFail + chk(abs(A10/A90 - 1/sin(deg2rad(10))) < 1e-9, ...
    sprintf('simple mapping at 10 deg gives ratio %.6f, expected %.6f', ...
            A10/A90, 1/sin(deg2rad(10))));

% Niell must NOT collapse to the simple form, or the two-column design is pointless.
optsN = struct('mappingKind','niell','latitude_rad',0.4,'doy',180,'height_km',0.1);
An    = models.atmosphere.GaseousAbsorption.slantAttenuation_dB(fL1, deg2rad(10), optsN);
nFail = nFail + chk(abs(An - A10) > 1e-6 * A10, ...
    sprintf('niell mapping differs from simple at 10 deg (simple %.6f, niell %.6f)', A10, An));

% At 24 GHz the wet column dominates, so m_h vs m_w actually matters there: swapping
% humidity must move the niell answer too.
optsWet = optsN;
optsWet.ZWD_m = 2*zwdRef;
An2 = models.atmosphere.GaseousAbsorption.slantAttenuation_dB(24.125e9, deg2rad(10), optsWet);
An1 = models.atmosphere.GaseousAbsorption.slantAttenuation_dB(24.125e9, deg2rad(10), optsN);
nFail = nFail + chk(An2 > An1 * 1.5, ...
    sprintf('doubling ZWD at 24 GHz/10 deg moves the total materially (%.4f -> %.4f)', An1, An2));

% ---- 6. The three physical conclusions the plan is built on ----------------
% (a) negligible below 6 GHz: under 0.5% on code sigma at zenith
for f = [0.915e9 1.17645e9 1.22760e9 1.57542e9 2.45e9 5.2e9 5.8e9]
    A     = models.atmosphere.GaseousAbsorption.slantAttenuation_dB(f, el90);
    sigX  = 10^(A/20);
    nFail = nFail + chk(sigX < 1.005, ...
        sprintf('%.3f GHz zenith sigma factor %.6f is under 1.005', f/1e9, sigX));
end

% (b) 24.125 GHz is the one band where a number moves, and it is water-vapour driven
[d24, w24] = models.atmosphere.GaseousAbsorption.zenithDryWet(24.125e9);
A24        = models.atmosphere.GaseousAbsorption.slantAttenuation_dB(24.125e9, el90);
nFail = nFail + chk(abs(10^(A24/20) - 1.046) < 5e-3, ...
    sprintf('24.125 GHz zenith sigma factor is %.4f, expected ~1.046', 10^(A24/20)));
nFail = nFail + chk(w24/(d24+w24) > 0.75, ...
    sprintf('24.125 GHz is water-vapour dominated (wet fraction %.3f)', w24/(d24+w24)));

% (c) 61.25 GHz does not close. A nominal 45 dB-Hz link with 6 dB of zenith gain
% cannot survive this, and that is the entire point of the exercise.
A61   = models.atmosphere.GaseousAbsorption.slantAttenuation_dB(61.25e9, el90);
cn0   = 45 + 6 - A61;
nFail = nFail + chk(A61 > 100, sprintf('61.25 GHz zenith is %.2f dB, expected > 100', A61));
nFail = nFail + chk(cn0 < 25, ...
    sprintf('61.25 GHz zenith C/N0 is %.1f dB-Hz, below any trackable threshold', cn0));

% ---- 7. Guards --------------------------------------------------------------
badF = {0, -1e9, Inf, NaN, [1e9 2e9]};
for k = 1:numel(badF)
    ok = false;
    try
        models.atmosphere.GaseousAbsorption.zenithDryWet(badF{k});
    catch ME
        ok = strcmp(ME.identifier, 'GaseousAbsorption:badFrequency');
    end
    nFail = nFail + chk(ok, sprintf('guard rejects frequency %s', mat2str(badF{k})));
end

ok = false;
try
    models.atmosphere.GaseousAbsorption.slantAttenuation_dB(fL1, NaN);
catch ME
    ok = strcmp(ME.identifier, 'GaseousAbsorption:badElevation');
end
nFail = nFail + chk(ok, 'guard rejects NaN elevation');

ok = false;
try
    models.atmosphere.GaseousAbsorption.slantAttenuation_dB(fL1, el90, struct('ZWD_m', -1));
catch ME
    ok = strcmp(ME.identifier, 'GaseousAbsorption:badZwd');
end
nFail = nFail + chk(ok, 'guard rejects negative ZWD');

ok = false;
try
    models.atmosphere.GaseousAbsorption.slantAttenuation_dB( ...
        fL1, el90, struct('mappingKind','vmf3'));
catch ME
    ok = strcmp(ME.identifier, 'GaseousAbsorption:unknownMappingKind');
end
nFail = nFail + chk(ok, 'guard rejects an unknown mapping kind');

if nFail > 0
    error('test_gaseous_absorption:FAIL', '%d assertion(s) failed', nFail);
end
fprintf('  PASS\n');


function n = chk(cond, msg)
    if cond
        n = 0;
    else
        n = 1;
        fprintf('  FAIL: %s\n', msg);
    end
end
