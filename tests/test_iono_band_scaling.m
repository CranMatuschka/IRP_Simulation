% test_iono_band_scaling
% Ionosphere climatology amplitudes are anchored at 1575.42 MHz and must be CONVERTED
% to the scenario's reference band, not relabelled as if they were already there.
%
% THE DEFECT THIS PINS. cfg.errors.ionosphere.*.verticalDelayL1_m (5.0 m) and the
% Klobuchar amp/DC (20 ns / 5 ns) are physical L1 quantities. The chain applies
% (f_ref/f_signal)^2 in EnvironmentModel.getIonoDelay and again in the per-signal
% expansion, but f_ref is the RESOLVED band -- so for the primary signal both factors
% are identically 1.0. The freq009-013 rungs retune signals.L1 itself (up to 61.25 GHz),
% so 5.0 m of L1 delay was applied verbatim at every band. freq011's own _id predicts
% 0.0738x the L1 ionosphere = (1.57542/5.8)^2; the code delivered 1.0x.
%
% Verified here:
%   1. anchorScale is EXACTLY 1.0 at the canonical band (the golden zero-diff invariant)
%   2. the delay at a FIXED signal frequency is INDEPENDENT of the reference band
%      -- this is the property the defect broke, and it also catches double-conversion
%      of the diurnal branch, whose K_L1 already carries 1/f_ref^2
%   3. the absolute delay follows the 1/f^2 law across the rung catalogue
%   4. the guard rejects a non-physical reference frequency

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_iono_band_scaling ===\n');

fCanon = revgnss.Constants.IONO_ANCHOR_L1_HZ;
assert(abs(fCanon - 1575.42e6) < 1e-3, 'canonical anchor must be 1575.42 MHz, got %g', fCanon);

el90  = pi/2;
VDEL  = 5.0;          % metres of vertical delay AT 1575.42 MHz
nFail = 0;

% Reference bands: canonical L1 plus every carrier the freq009-013 rungs retune to.
bands_Hz = [fCanon, 915e6, 2450e6, 5200e6, 5800e6, 24125e6, 61250e6];
bandName = {'L1', '915M', '2450M', '5200M', '5800M', '24125M', '61250M'};

% ---- 1. Zero-diff invariant: exactly 1.0 at the canonical band --------------
s1 = models.atmosphere.IonosphereModel.climatologyAnchorScale(fCanon);
nFail = nFail + chk(s1 == 1.0, sprintf('anchorScale(L1) is EXACTLY 1.0 (got %.20g)', s1));

% ---- 2. Delay at a fixed signal frequency is reference-band invariant -------
% The reference band is a bookkeeping choice. Physics depends on the SIGNAL
% frequency only, so sweeping f_ref with f_sig held fixed must change nothing.
%
% Constant-climatology branch (diurnal off):
fProbe   = 2450e6;
dConst   = zeros(1, numel(bands_Hz));
for i = 1:numel(bands_Hz)
    env = models.errors.EnvironmentModel(bandCfg(false), 1);
    dConst(i) = env.getIonoDelay(1, el90, 'truth', fProbe, bands_Hz(i));
end
spreadConst = max(abs(dConst - dConst(1)));
nFail = nFail + chk(spreadConst < 1e-12, ...
    sprintf('constant branch: delay@2450MHz independent of reference band (spread %.3e m)', spreadConst));

% Diurnal branch (K_L1 already carries 1/f_ref^2 -- must NOT be scaled again):
dDiur = zeros(1, numel(bands_Hz));
for i = 1:numel(bands_Hz)
    envD = models.errors.EnvironmentModel(bandCfg(true), 1);
    envD.tNow_s = 14*3600;
    dDiur(i) = envD.getIonoDelay(1, el90, 'truth', fProbe, bands_Hz(i));
end
spreadDiur = max(abs(dDiur - dDiur(1)));
nFail = nFail + chk(spreadDiur < 1e-12, ...
    sprintf('diurnal branch: delay@2450MHz independent of reference band (spread %.3e m) -- a failure here means the K_L1 mean was double-converted', spreadDiur));

% ---- 3. Absolute 1/f^2 law across the rung catalogue -----------------------
% Evaluate each band as its OWN primary (f_signal = f_ref), which is the configuration
% the freq rungs actually run: the primary previously received the full 5.0 m.
fprintf('  band        delay [m]      expected [m]\n');
for i = 1:numel(bands_Hz)
    f   = bands_Hz(i);
    env = models.errors.EnvironmentModel(bandCfg(false), 1);
    d   = env.getIonoDelay(1, el90, 'truth', f, f);
    exp_m = VDEL * (fCanon / f)^2;
    fprintf('  %-8s  %12.6f   %12.6f\n', bandName{i}, d, exp_m);
    nFail = nFail + chk(abs(d - exp_m) < 1e-12 * max(1, abs(exp_m)), ...
        sprintf('%s: vertical delay follows 1/f^2 (got %.6g, want %.6g)', bandName{i}, d, exp_m));
end

% The headline consequence: 61.25 GHz must be sub-millimetre, not 5 m.
envHi = models.errors.EnvironmentModel(bandCfg(false), 1);
dHi   = envHi.getIonoDelay(1, el90, 'truth', 61250e6, 61250e6);
nFail = nFail + chk(dHi < 5e-3, ...
    sprintf('61.25 GHz vertical iono is sub-5 mm (got %.6f m)', dHi));

% ---- 3b. Scintillation sigma is L1-anchored too, and lands in R ------------
% sigmaCodeL1_m is a physical 1575.42 MHz amplitude. Same invariant: the sigma at a
% fixed signal frequency must not depend on the reference band, and the absolute value
% must follow (f_canonical/f_signal)^frequencyExponent.
SIGMA_L1 = 0.3; FREQ_EXP = 1.0;
sProbe = zeros(1, numel(bands_Hz));
for i = 1:numel(bands_Hz)
    envS = models.errors.EnvironmentModel(scintCfg(SIGMA_L1, FREQ_EXP), 1);
    envS.scintAmplitude = 1.0;
    sProbe(i) = envS.getScintillationSigma(el90, fProbe, bands_Hz(i));
end
spreadScint = max(abs(sProbe - sProbe(1)));
nFail = nFail + chk(spreadScint < 1e-12, ...
    sprintf('scintillation sigma@2450MHz independent of reference band (spread %.3e m)', spreadScint));

envS  = models.errors.EnvironmentModel(scintCfg(SIGMA_L1, FREQ_EXP), 1);
envS.scintAmplitude = 1.0;
sHi   = envS.getScintillationSigma(el90, 61250e6, 61250e6);
sWant = SIGMA_L1 * (fCanon / 61250e6)^FREQ_EXP;
nFail = nFail + chk(abs(sHi - sWant) < 1e-12, ...
    sprintf('61.25 GHz scintillation sigma follows 1/f^%.1f (got %.6g, want %.6g)', ...
    FREQ_EXP, sHi, sWant));

% ---- 4. Guard rejects a non-physical reference frequency -------------------
for bad = {0, -1, inf, nan}
    ok = false;
    try
        models.atmosphere.IonosphereModel.climatologyAnchorScale(bad{1});
    catch ME
        ok = strcmp(ME.identifier, 'IonosphereModel:badReferenceFrequency');
    end
    nFail = nFail + chk(ok, sprintf('guard rejects reference frequency %g', bad{1}));
end

if nFail > 0
    error('test_iono_band_scaling:FAIL', '%d assertion(s) failed', nFail);
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

function cfg = scintCfg(sigmaL1_m, freqExp)
    cfg = bandCfg(false);
    cfg.errors.ionosphere.scintillation = struct( ...
        'enable', true, 'model', 'legacy', ...
        'sigmaCodeL1_m', sigmaL1_m, 'frequencyExponent', freqExp);
end

function cfg = bandCfg(useDiurnal)
    cfg = struct();
    cfg.towers = struct('id',1,'name','t','lat_rad',0,'lon_rad',0,'alt_m',0, ...
        'antennaOffset_enu_m',[0;0;0],'hardwareDelay_m',0);
    cfg.errors.troposphere.modelType = 'simpleMapped';
    ic = struct();
    ic.modelType = 'tecGaussMarkov';
    ic.truth.verticalDelayL1_m = 5.0;
    ic.model.verticalDelayL1_m = 5.0;
    if useDiurnal
        ic.truth.diurnal = struct('enable', true, 'vtecDay_TECU', 40, ...
            'vtecNight_TECU', 5, 'peakLocalTime_h', 14);
    end
    cfg.errors.ionosphere = ic;
    cfg.effects.ionosphere.mappingModel = 'thinShell';
    cfg.effects.ionosphere.shellHeight_m = 350e3;
end
