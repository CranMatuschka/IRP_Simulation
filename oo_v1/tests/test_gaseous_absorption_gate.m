% test_gaseous_absorption_gate
% The gaseous-absorption gate is OFF by default, is NOT inert when on, and survives
% _extends inheritance.
%
% WHY ALL THREE. This repo makes inert toggles routinely -- the toggle audit counted
% about 70, and the feat ablation rungs (feat001/002/006/007/009/014) resolve
% master 0 / truth 1 and disable nothing, so every "effect X contributes Y m" read off
% them measured noise. Two specific traps:
%
%   * NO PHYSICS READER. A flag can resolve perfectly and be read by nobody. Only
%     assertion 2 catches that, and it is the one usually not written.
%   * _extends INHERITANCE IS RECORDED AS OWNERSHIP, so resolveEnablePairsPostMerge
%     skips the truth/model pair and a rung looks configured while being inert. Only
%     assertion 3 catches that.
%
% Assertion 1 (off == baseline) is the one everybody writes, and on its own it proves
% only that nothing leaked, never that anything works.
%
% This test drives the SHARED C/N0 helper directly rather than a full run, so it is fast
% and pins the exact arithmetic the measurement builders use.

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_gaseous_absorption_gate ===\n');

nFail = 0;
MMU   = @models.measurements.MeasurementModelUtils.cn0CodeSigma;

% ---- 0. The deleted placeholder stays deleted ------------------------------
% weatherLossScale_dB was a 2 dB scalar with no model behind it and no reader. Removed
% in the same change that added real absorption, so that two knobs which look
% equivalent -- one of which lied -- cannot coexist.
cfgM = masterConfig();
nFail = nFail + chk(~isfield(cfgM.measurements.codeNoise.cn0, 'weatherLossScale_dB'), ...
    'weatherLossScale_dB is gone from masterConfig');
nFail = nFail + chk(isfield(cfgM.atmosphere, 'gaseousAbsorption') && ...
                    islogical(cfgM.atmosphere.gaseousAbsorption.enable) && ...
                    ~cfgM.atmosphere.gaseousAbsorption.enable, ...
    'gaseousAbsorption.enable exists and defaults to FALSE');

% ---- 1. OFF is bit-identical to the pre-absorption arithmetic ---------------
% The baseline is computed here in closed form, NOT by calling the code under test, so
% this cannot pass by both sides sharing a bug.
cfgOff = i_cn0Cfg(false);
el     = deg2rad([90 45 20 10 5]);
worst  = 0;
for k = 1:numel(el)
    got  = MMU(0.30, el(k), cfgOff, 1575.42e6);
    cn0  = 45 + 6*sin(el(k));
    want = 0.30 * 10^(-(cn0 - 45)/20);
    worst = max(worst, abs(got - want));
end
nFail = nFail + chk(worst == 0, ...
    sprintf('gate OFF reproduces the baseline EXACTLY (worst diff %.3e)', worst));

% A cfg with no atmosphere field at all must also return the baseline, because some
% unit tests build reduced structs.
cfgBare = struct();
cfgBare.measurements.codeNoise.cn0.base_dBHz = 45;
cfgBare.measurements.codeNoise.cn0.elevationGain_dB = 6;
gotBare = MMU(0.30, deg2rad(30), cfgBare, 1575.42e6);
wantBare = 0.30 * 10^(-(6*sin(deg2rad(30)))/20);
nFail = nFail + chk(abs(gotBare - wantBare) == 0, ...
    'a cfg with no atmosphere field returns the baseline exactly');

% ---- 2. ON is NOT INERT, and moves by the RIGHT amount ----------------------
% The expected shift is derived from the frozen table independently of the helper.
cfgOn = i_cn0Cfg(true);
for f = [1.57542e9, 24.125e9, 61.25e9]
    for elDeg = [90 10]
        elr  = deg2rad(elDeg);
        sOff = MMU(0.30, elr, cfgOff, f);
        sOn  = MMU(0.30, elr, cfgOn,  f);
        A    = models.atmosphere.GaseousAbsorption.slantAttenuation_dB(f, elr);
        want = 10^(A/20);
        % RELATIVE tolerance: at 61.25 GHz the ratio is ~1e8 at zenith and ~1e46 at
        % 10 deg, where an absolute 1e-12 is not representable.
        nFail = nFail + chk(abs(sOn/sOff - want) <= 1e-12 * max(1, abs(want)), ...
            sprintf('%.3f GHz at %d deg: ON/OFF ratio %.10g, expected %.10g', ...
                    f/1e9, elDeg, sOn/sOff, want));
        nFail = nFail + chk(sOn > sOff, ...
            sprintf('%.3f GHz at %d deg: absorption must RAISE sigma', f/1e9, elDeg));
    end
end

% The 61.25 GHz shift must be enormous, not marginal. If a future edit quietly made the
% table small there, the ch8 claim that the band does not close would break silently.
s61off = MMU(0.30, pi/2, cfgOff, 61.25e9);
s61on  = MMU(0.30, pi/2, cfgOn,  61.25e9);
nFail = nFail + chk(s61on/s61off > 1e6, ...
    sprintf('61.25 GHz sigma ratio is %.3e, expected > 1e6 (link does not close)', ...
            s61on/s61off));

% L1 must move by only a few tenths of a percent at zenith -- big enough to prove the
% gate is live, small enough to justify keeping it out of realism grade.
sL1off = MMU(0.30, pi/2, cfgOff, 1.57542e9);
sL1on  = MMU(0.30, pi/2, cfgOn,  1.57542e9);
rL1    = sL1on/sL1off;
nFail = nFail + chk(rL1 > 1.0 && rL1 < 1.01, ...
    sprintf('L1 zenith ratio is %.6f, expected in (1.000, 1.010)', rL1));

% ---- 3. The flag survives _extends inheritance ------------------------------
% Inheriting the flag from a parent must reach the physics, not merely resolve. This is
% the assertion the repo keeps missing: a rung can look configured while being inert
% because _extends inheritance is recorded as OWNERSHIP.
ladderDir = fullfile(thisDir, '..', 'config', 'ladder');
tmpDir    = fullfile(ladderDir, 'tmp_gastest');
parentF   = fullfile(tmpDir, 'gastest_parent.json');
childF    = fullfile(tmpDir, 'gastest_child.json');
cleanup   = onCleanup(@() i_rmdir(tmpDir));
if ~exist(tmpDir, 'dir'); mkdir(tmpDir); end

i_write(parentF, ['{\n  "_id": "gastest_parent",\n' ...
    '  "atmosphere": { "gaseousAbsorption": { "enable": true } },\n' ...
    '  "measurements": { "codeNoise": { "model": "cn0" } }\n}\n']);
i_write(childF, ['{\n  "_id": "gastest_child",\n' ...
    '  "_extends": "gastest_parent.json",\n' ...
    '  "simulation": { "duration_s": 60 }\n}\n']);

inheritedOk = false;
try
    cfgChild = resolveSimulationConfig('gastest_child.json');
    inheritedOk = isfield(cfgChild,'atmosphere') && ...
                  isfield(cfgChild.atmosphere,'gaseousAbsorption') && ...
                  cfgChild.atmosphere.gaseousAbsorption.enable;
    nFail = nFail + chk(inheritedOk, 'the flag RESOLVES true through _extends');

    if inheritedOk
        % Resolving is not enough. Drive the physics with the INHERITED cfg and confirm
        % it actually changes the number.
        sInh = MMU(0.30, pi/2, cfgChild, 24.125e9);
        sBas = MMU(0.30, pi/2, cfgOff,   24.125e9);
        nFail = nFail + chk(sInh > sBas * 1.001, ...
            sprintf('the INHERITED flag reaches the physics (%.6f vs %.6f)', sInh, sBas));
    end
catch ME
    nFail = nFail + chk(false, ...
        sprintf('_extends inheritance check errored: %s (%s)', ME.message, ME.identifier));
end

if nFail > 0
    error('test_gaseous_absorption_gate:FAIL', '%d assertion(s) failed', nFail);
end
fprintf('  PASS\n');


function cfg = i_cn0Cfg(absorptionOn)
    cfg = struct();
    cfg.measurements.codeNoise.model             = 'cn0';
    cfg.measurements.codeNoise.cn0.base_dBHz     = 45;
    cfg.measurements.codeNoise.cn0.elevationGain_dB = 6;
    cfg.measurements.codeNoise.cn0.sigmaAt45dBHz_m  = 0.30;
    cfg.atmosphere.gaseousAbsorption.enable      = absorptionOn;
    cfg.atmosphere.gaseousAbsorption.mappingKind = 'simple';
end

function i_write(f, s)
    fid = fopen(f, 'w');
    assert(fid > 0, 'could not open %s for writing', f);
    fprintf(fid, s);
    fclose(fid);
end

function i_rmdir(d)
    if exist(d, 'dir'); rmdir(d, 's'); end
end

function n = chk(cond, msg)
    if cond
        n = 0;
    else
        n = 1;
        fprintf('  FAIL: %s\n', msg);
    end
end
