% test_klobuchar_correction
% Klobuchar single-frequency broadcast model and its wiring as the ionosphere
% MODEL correction. Verifies the IS-GPS-200 half-cosine algorithm and that, against
% a smooth diurnal truth, it removes a substantial (but not perfect) fraction of the
% first-order ionospheric range error -- a physical residual, not a hand-scaled one.

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_klobuchar_correction ===\n');

KB = @models.atmosphere.Klobuchar;
c  = revgnss.Constants.SPEED_OF_LIGHT_MPS;
amp_s = 20e-9; per_s = 86400; dc_s = 5e-9;

% --- Algorithm: peak at 14:00, night floor, positivity, half-cosine shape
Ipeak  = models.atmosphere.Klobuchar.verticalDelaySeconds(50400, amp_s, per_s, dc_s);  % 14:00
Inight = models.atmosphere.Klobuchar.verticalDelaySeconds(2*3600, amp_s, per_s, dc_s); % 02:00
Imid   = models.atmosphere.Klobuchar.verticalDelaySeconds(10*3600, amp_s, per_s, dc_s);% 10:00
assert(abs(Ipeak - (dc_s + amp_s)) < 1e-15, 'peak (14:00) must equal DC+AMP');
assert(abs(Inight - dc_s) < 1e-15, 'night must equal the 5 ns floor');
assert(Ipeak > Imid && Imid > Inight, 'delay must fall monotonically from the 14:00 peak into night');
% Sweep: always positive and never below the floor
for h = 0:0.5:24
    Iv = models.atmosphere.Klobuchar.verticalDelaySeconds(h*3600, amp_s, per_s, dc_s);
    assert(Iv >= dc_s - 1e-18 && Iv <= dc_s + amp_s + 1e-18, 'Klobuchar out of [DC, DC+AMP] at %.1f h', h);
end
assert(abs(models.atmosphere.Klobuchar.verticalDelayMetres(50400, amp_s, per_s, dc_s) - c*Ipeak) < 1e-9, ...
    'metres accessor must equal c*seconds');

% --- Period floor (>= 20 h) is enforced
Ilow = models.atmosphere.Klobuchar.verticalDelaySeconds(50400, amp_s, 3600, dc_s);  % per clamped to 72000
assert(abs(Ilow - (dc_s + amp_s)) < 1e-15, 'sub-floor period must be clamped, peak unchanged');

% --- Wired MODEL correction: model delay tracks the Klobuchar climatology
fL1 = 1575.42e6;
env = models.errors.EnvironmentModel(klobCfg(), 1);      % tower at lon 0
env.tNow_s = 50400;                                       % 14:00 LT
dModelDay = env.getIonoDelay(1, pi/2, 'model', fL1, fL1);
assert(abs(dModelDay - c*(dc_s+amp_s)) < 1e-6, 'wired klobuchar model (14:00, zenith) mismatch: %.4f', dModelDay);
env.tNow_s = 2*3600;                                      % 02:00 LT
dModelNight = env.getIonoDelay(1, pi/2, 'model', fL1, fL1);
assert(dModelDay > 3*dModelNight, 'model must show a day/night contrast');

% --- Against a smooth diurnal truth, the Klobuchar residual is substantial but partial.
% truth: full-cosine VTEC diurnal; model: Klobuchar half-cosine. Compare over 24 h at zenith.
K_L1 = 40.308e16 / fL1^2;
vtecDay = 40; vtecNight = 5; peakLT = 14;
hours = 0:0.25:24; tr = zeros(size(hours)); md = zeros(size(hours));
for i = 1:numel(hours)
    LT = hours(i);
    vtec = vtecNight + (vtecDay - vtecNight)*max(0, cos(2*pi*(LT-peakLT)/24));
    tr(i) = vtec * K_L1;                                          % truth vertical [m]
    md(i) = models.atmosphere.Klobuchar.verticalDelayMetres(LT*3600, amp_s, per_s, dc_s);
end
rmsTruth = sqrt(mean(tr.^2));
rmsResid = sqrt(mean((tr - md).^2));
frac = rmsResid / rmsTruth;
assert(frac > 0.15 && frac < 0.85, ...
    'Klobuchar residual should be a substantial partial fraction of the raw error, got %.2f', frac);

% --- Backward compatibility: default correction (unset) == legacy biasFraction constant
env2 = models.errors.EnvironmentModel(biasCfg(), 1);
env2.ionoState(1).tecResidualModel_m = 0;
dLegacy = env2.getIonoDelay(1, pi/2, 'model', fL1, fL1);
assert(abs(dLegacy - 5.0) < 1e-12, 'default model correction must equal legacy (verticalDelayL1=5.0), got %.6f', dLegacy);

fprintf('  peak=%.2f m night=%.2f m | Klobuchar residual fraction vs cosine truth = %.2f\n', ...
    c*Ipeak, c*Inight, frac);
fprintf('  PASS\n');


function cfg = klobCfg()
    cfg = struct();
    cfg.towers = struct('id',1,'name','t','lat_rad',0,'lon_rad',0,'alt_m',0, ...
        'antennaOffset_enu_m',[0;0;0],'hardwareDelay_m',0);
    cfg.errors.troposphere.modelType = 'simpleMapped';
    cfg.errors.ionosphere.modelType  = 'tecGaussMarkov';
    cfg.errors.ionosphere.model.correction = 'klobuchar';
    cfg.errors.ionosphere.model.klobuchar  = struct('amplitude_ns',20,'period_h',24,'dc_ns',5);
    cfg.effects.ionosphere.mappingModel  = 'thinShell';
    cfg.effects.ionosphere.shellHeight_m = 350e3;
end

function cfg = biasCfg()
    cfg = struct();
    cfg.towers = struct('id',1,'name','t','lat_rad',0,'lon_rad',0,'alt_m',0, ...
        'antennaOffset_enu_m',[0;0;0],'hardwareDelay_m',0);
    cfg.errors.troposphere.modelType = 'simpleMapped';
    cfg.errors.ionosphere.modelType  = 'tecGaussMarkov';
    cfg.errors.ionosphere.model.verticalDelayL1_m = 5.0;
    cfg.effects.ionosphere.mappingModel  = 'thinShell';
    cfg.effects.ionosphere.shellHeight_m = 350e3;
end
