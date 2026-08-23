% test_link_closure_and_s4_frequency
% WP4 (resolve-time link-closure refusal) and WP3 (S4 dispersive power law).
%
% WP4: a band whose ZENITH C/N0 falls below the tracking threshold is refused at CONFIG
% RESOLVE, with the number, instead of running a simulation that produces nothing. The
% zenith test is the BEST case, so this refuses only the genuinely impossible.
%
% WP3: S4zen is an L1-anchored climatology amplitude and gets the same anchor conversion
% as the delay constants, with its own exponent. Default 0 => exactly 1.0 => bit-identical.
%
% ⚠ THE TRAP THIS PINS. S4 ~ f^-1.5 and L2 is BELOW L1, so the law makes L2 scintillation
% WORSE by 45%, not better. Anyone reading "add the frequency law" as "high bands get
% cleaner" will not expect that, and with the min(0.7) clamp already active it pushes L2
% rows into the pinned 2.121 m regime. Assertion 4 states the direction explicitly so a
% future change cannot quietly flip it.

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_link_closure_and_s4_frequency ===\n');

nFail = 0;

% ---- 1. The knobs exist with inert defaults --------------------------------
cfgM = masterConfig();
nFail = nFail + chk(isfield(cfgM.measurements.codeNoise.cn0,'minTrackable_dBHz') && ...
                    cfgM.measurements.codeNoise.cn0.minTrackable_dBHz == 25, ...
    'cn0.minTrackable_dBHz exists and defaults to 25 dB-Hz');
nFail = nFail + chk(isfield(cfgM.errors.ionosphere.scintillation,'s4FrequencyExponent') && ...
                    cfgM.errors.ionosphere.scintillation.s4FrequencyExponent == 0, ...
    's4FrequencyExponent exists and defaults to 0 (inert)');

% ---- 2. WP4: the guard is INERT unless absorption AND cn0 are both on -------
% Three of the four corners must resolve cleanly even at a band that cannot close.
corners = { false, 'constant'; false, 'cn0'; true, 'constant' };
for k = 1:size(corners,1)
    ok = true;
    try
        i_resolve(61.25e9, corners{k,1}, corners{k,2});
    catch ME
        ok = false;
        msg = ME.message;
    end
    nFail = nFail + chk(ok, sprintf(...
        'guard inert at 61.25 GHz with absorption=%d model=%s%s', ...
        corners{k,1}, corners{k,2}, i_tail(ok, exist('msg','var'))));
    clear msg
end

% ---- 3. WP4: 61.25 GHz IS refused, and the message carries the number -------
refused = false; msg61 = '';
try
    i_resolve(61.25e9, true, 'cn0');
catch ME
    refused = strcmp(ME.identifier, 'ConfigFactory:linkDoesNotClose');
    msg61   = ME.message;
end
nFail = nFail + chk(refused, '61.25 GHz is REFUSED at resolve time with linkDoesNotClose');
if refused
    % The refusal must be quantitative, not a bare "unsupported band".
    nFail = nFail + chk(contains(msg61,'161.') && contains(msg61,'dB-Hz'), ...
        'the refusal message states the absorption in dB and the C/N0 in dB-Hz');
    nFail = nFail + chk(contains(msg61,'physical result'), ...
        'the message says this is a physical result, not a misconfiguration');
end

% A band that DOES close must still resolve with absorption on. 5.8 GHz costs 0.04 dB.
ok58 = true;
try
    i_resolve(5.8e9, true, 'cn0');
catch
    ok58 = false;
end
nFail = nFail + chk(ok58, '5.8 GHz still resolves with absorption on (0.04 dB, closes easily)');

% 24.125 GHz costs 0.39 dB, nowhere near the 26 dB of margin, so it must survive too.
ok24 = true;
try
    i_resolve(24.125e9, true, 'cn0');
catch
    ok24 = false;
end
nFail = nFail + chk(ok24, '24.125 GHz still resolves (0.39 dB against 26 dB of margin)');

% ---- 4. WP3: the exponent is inert at 0 and has the RIGHT SIGN at 1.5 -------
% Computed from the shared helper rather than a full run, so this pins the arithmetic.
fL1 = revgnss.Constants.IONO_ANCHOR_L1_HZ;
fL2 = 1227.60e6;

s0 = i_s4Scale(fL1, fL2, 0);
nFail = nFail + chk(s0 == 1.0, ...
    sprintf('exponent 0 gives EXACTLY 1.0 at L2 (got %.20g)', s0));

s0p = i_s4Scale(fL1, fL1, 1.5);
nFail = nFail + chk(s0p == 1.0, ...
    sprintf('the primary band is EXACTLY 1.0 whatever the exponent (got %.20g)', s0p));

% THE DIRECTION. L2 is BELOW L1, so f^-1.5 makes L2 scintillation WORSE.
s15 = i_s4Scale(fL1, fL2, 1.5);
want = (fL1/fL2)^1.5;
nFail = nFail + chk(abs(s15 - want) < 1e-12, ...
    sprintf('L2 scale at exponent 1.5 is %.10f, expected %.10f', s15, want));
nFail = nFail + chk(s15 > 1.44 && s15 < 1.46, ...
    sprintf('L2 scintillation is RAISED ~45%% (scale %.4f), not lowered', s15));

% High bands go the other way and collapse, which is the useful half of the law.
s61 = i_s4Scale(fL1, 61.25e9, 1.5);
nFail = nFail + chk(s61 < 0.005, ...
    sprintf('61.25 GHz S4 scale is %.6f, i.e. scintillation effectively gone', s61));

if nFail > 0
    error('test_link_closure_and_s4_frequency:FAIL', '%d assertion(s) failed', nFail);
end
fprintf('  PASS\n');


function cfg = i_resolve(f_Hz, absorptionOn, codeModel)
    % Minimal single-signal config resolved through the real finalizeConfig path.
    cfg = masterConfig();
    cfg.signals.L1.frequency_Hz = f_Hz;
    cfg.signals.L1.lambda_m     = revgnss.Constants.SPEED_OF_LIGHT_MPS / f_Hz;
    cfg.signals.frequencyHz     = f_Hz;
    cfg.measurements.codeNoise.model        = codeModel;
    cfg.atmosphere.gaseousAbsorption.enable = absorptionOn;
    cfg.report.writePdf = false; cfg.report.writeMat = false;
    cfg.report.compileTex = 'never';
    cfg.plots.enable = false; cfg.plots.showFigures = false;
    cfg = evalc_('revgnss.ConfigFactory.finalizeConfig', cfg);
end

function out = evalc_(fn, cfg)
    % finalizeConfig emits sanitization warnings that would drown the test output.
    w = warning('off','all');
    c = onCleanup(@() warning(w));
    out = feval(str2func(fn), cfg);
end

function s = i_s4Scale(f_ref_Hz, f_signal_Hz, exponent)
    % The same composition EnvironmentModel applies to S4zen:
    %   (f_canon/f_ref)^n * (f_ref/f_signal)^n = (f_canon/f_signal)^n
    s = models.atmosphere.IonosphereModel.climatologyAnchorScale(f_ref_Hz, exponent) ...
        * (f_ref_Hz / f_signal_Hz)^exponent;
end

function t = i_tail(ok, hasMsg)
    if ok || ~hasMsg; t = ''; else; t = ' (threw)'; end
end

function n = chk(cond, msg)
    if cond
        n = 0;
    else
        n = 1;
        fprintf('  FAIL: %s\n', msg);
    end
end
