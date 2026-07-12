% test_ionosphere_truth_realism
% tecGaussMarkov ionosphere TRUTH: diurnal VTEC mean, uplink topside fraction,
% thin-shell obliquity, first-order dispersion, and backward compatibility.
%
% Verified physics:
%   I = 40.308*STEC/f^2 -> K_L1 = 40.308e16/f_L1^2 ~ 0.162 m/TECU at L1
%   thin-shell M(e), dispersive (f_L1/f)^2, uplink f_seen in [0,1].

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_ionosphere_truth_realism ===\n');

fL1 = 1575.42e6; fL2 = 1227.60e6;
K_L1 = 40.308e16 / fL1^2;   % ~0.16241 m per TECU
el90 = pi/2; el30 = deg2rad(30);

% --- Backward compatibility: diurnal off, f_seen defaults to 1.0
env = models.errors.EnvironmentModel(ionoCfg(struct()), 1);
env.ionoState(1).tecResidualTruth_m = 0.3;
dT90 = env.getIonoDelay(1, el90, 'truth', fL1, fL1);
assert(abs(dT90 - (5.0 + 0.3)) < 1e-12, ...
    'default (f_seen=1, no diurnal) must be (vdel+res)*M(90)=5.3, got %.6f', dT90);

% --- Topside fraction scales the whole truth column linearly
o = struct(); o.topsideFraction = 0.7;
envF = models.errors.EnvironmentModel(ionoCfg(o), 1);
envF.ionoState(1).tecResidualTruth_m = 0.3;
dF90 = envF.getIonoDelay(1, el90, 'truth', fL1, fL1);
assert(abs(dF90 - 0.7*(5.3)) < 1e-12, 'topsideFraction=0.7 should give 0.7*5.3, got %.6f', dF90);

% --- Exponential-topside parameterisation ~0.73 at 550 km (illustrative)
o2 = struct(); o2.topside = struct('enable', true, 'B',0.30,'T',0.55,'hPeak_km',350,'Htop_km',100,'hSat_km',550);
envT = models.errors.EnvironmentModel(ionoCfg(o2), 1);
fSeen = envT.getIonoDelay(1, el90, 'truth', fL1, fL1) / 5.0;   % residual 0, vdel 5.0
assert(abs(fSeen - (0.30 + 0.55*(1-exp(-2)))) < 1e-9, 'exponential f_seen mismatch: %.4f', fSeen);
assert(fSeen > 0.70 && fSeen < 0.80, 'f_seen(550 km) should be ~0.73, got %.4f', fSeen);

% --- Diurnal VTEC: daytime (14:00 LT) delay exceeds nighttime (02:00 LT)
o3 = struct();
o3.truth.diurnal = struct('enable', true, 'vtecDay_TECU', 40, 'vtecNight_TECU', 5, 'peakLocalTime_h', 14);
envD = models.errors.EnvironmentModel(ionoCfg(o3), 1);   % tower at lon 0 -> LT = tNow/3600
envD.tNow_s = 14*3600;                                     % 14:00 LT
dDay = envD.getIonoDelay(1, el90, 'truth', fL1, fL1);
envD.tNow_s = 2*3600;                                      % 02:00 LT
dNight = envD.getIonoDelay(1, el90, 'truth', fL1, fL1);
assert(abs(dDay - 40*K_L1) < 1e-9, 'daytime vertical delay = VTEC_day*K_L1, got %.4f', dDay);
assert(abs(dNight - 5*K_L1) < 1e-9, 'nighttime vertical delay = VTEC_night*K_L1, got %.4f', dNight);
assert(dDay > 3*dNight, 'day/night diurnal contrast too small (%.3f vs %.3f)', dDay, dNight);

% --- Dispersion: delay(L2)/delay(L1) = (f_L1/f_L2)^2
dL1 = env.getIonoDelay(1, el90, 'truth', fL1, fL1);
dL2 = env.getIonoDelay(1, el90, 'truth', fL2, fL1);
assert(abs(dL2/dL1 - (fL1/fL2)^2) < 1e-9, 'iono dispersion must scale as (f1/f2)^2, got %.5f', dL2/dL1);

% --- Obliquity: thin-shell slant/zenith ratio at 30 deg
r = env.getIonoDelay(1, el30, 'truth', fL1, fL1) / env.getIonoDelay(1, el90, 'truth', fL1, fL1);
Mref = models.atmosphere.MappingFunctions.ionosphere(el30, 'thinShell', 350e3);
assert(abs(r - Mref) < 1e-9, 'slant/zenith ratio must equal thin-shell M(30)=%.4f, got %.4f', Mref, r);

fprintf('  K_L1=%.5f m/TECU | dDay=%.4f dNight=%.4f | f_seen(550km)=%.4f | M(30)=%.4f\n', ...
    K_L1, dDay, dNight, fSeen, Mref);
fprintf('  PASS\n');


function cfg = ionoCfg(icExtra)
    cfg = struct();
    cfg.towers = struct('id',1,'name','t','lat_rad',0,'lon_rad',0,'alt_m',0, ...
        'antennaOffset_enu_m',[0;0;0],'hardwareDelay_m',0);
    cfg.errors.troposphere.modelType = 'simpleMapped';
    ic = struct();
    ic.modelType = 'tecGaussMarkov';
    ic.truth.verticalDelayL1_m = 5.0;
    ic.model.verticalDelayL1_m = 5.0;
    % Merge caller overrides (topsideFraction / topside / truth.diurnal)
    fn = fieldnames(icExtra);
    for i = 1:numel(fn)
        if isstruct(icExtra.(fn{i})) && isfield(ic, fn{i}) && isstruct(ic.(fn{i}))
            sub = fieldnames(icExtra.(fn{i}));
            for j = 1:numel(sub); ic.(fn{i}).(sub{j}) = icExtra.(fn{i}).(sub{j}); end
        else
            ic.(fn{i}) = icExtra.(fn{i});
        end
    end
    cfg.errors.ionosphere = ic;
    cfg.effects.ionosphere.mappingModel = 'thinShell';
    cfg.effects.ionosphere.shellHeight_m = 350e3;
end
