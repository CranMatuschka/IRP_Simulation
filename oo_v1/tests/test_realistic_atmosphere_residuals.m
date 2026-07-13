% test_realistic_atmosphere_residuals
% Acceptance test for realisticAtmosphereConfig: with the physically-realistic
% atmosphere the troposphere and ionosphere truth-model residuals are NON-ZERO,
% physically sized, and grow toward low elevation / vary diurnally -- unlike the
% matched default where they cancel to machine precision.

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));
addpath(fullfile(thisDir, '..', 'config'));

fprintf('=== test_realistic_atmosphere_residuals ===\n');

cfg = masterConfig();
cfg = realisticAtmosphereConfig(cfg);

% --- Config wired as intended
assert(strcmp(cfg.errors.troposphere.modelType, 'localWeatherGM'), 'trop modelType');
assert(strcmp(cfg.errors.troposphere.truth.mappingType, 'niell'), 'trop niell mapping');
assert(strcmp(cfg.estimation.troposphereMode, 'perTowerZwd'), 'ZWD EKF model');
assert(strcmp(cfg.errors.ionosphere.modelType, 'tecGaussMarkov'), 'iono modelType');
assert(strcmp(cfg.errors.ionosphere.model.correction, 'klobuchar'), 'iono Klobuchar model');
assert(cfg.errors.ionosphere.truth.diurnal.enable, 'iono diurnal truth');
assert(strcmp(cfg.effects.ionosphere.mappingModel, 'thinShell'), 'thin-shell obliquity');

% --- Residuals at the ErrorChain level, swept over a full day and a range of elevations
ec  = models.errors.ErrorChain(cfg, 42);
el  = deg2rad([10 25 45 70 85]).';
N   = numel(el);
tid = (1:N).'; tidx = (1:N).';
ts  = 0:3600:86400;                       % 25 epochs across a day
tropMis = zeros(1,numel(ts));
ionoMis = zeros(1,numel(ts));
ionoTruthZen = zeros(1,numel(ts));
tropMisLow = zeros(1,numel(ts));          % low-elevation (10 deg) trop residual
tropMisZen = zeros(1,numel(ts));          % high-elevation (85 deg) trop residual
for k = 1:numel(ts)
    err = ec.compute(el, tid, tidx, ts(k));
    dTrop = err.bySource.truth_m.trop - err.bySource.model_m.trop;
    dIono = err.bySource.truth_m.iono - err.bySource.model_m.iono;
    tropMis(k) = rms(dTrop);
    ionoMis(k) = rms(dIono);
    tropMisLow(k) = abs(dTrop(1));        % 10 deg
    tropMisZen(k) = abs(dTrop(end));      % 85 deg
    ionoTruthZen(k) = abs(err.bySource.truth_m.iono(end));
end

% skip epoch 1 (dt=0, GM states not yet stepped)
tropMean = mean(tropMis(2:end));
ionoMean = mean(ionoMis(2:end));

% Troposphere: cm-level, physically bounded, and non-zero (no longer cancels)
assert(tropMean > 0.005, 'trop residual should be > 5 mm (was ~0), got %.4f m', tropMean);
assert(tropMean < 1.0,   'trop residual should be < 1 m (physical), got %.4f m', tropMean);

% Ionosphere: single-frequency Klobuchar residual is dm-to-m level, bounded
assert(ionoMean > 0.05, 'iono residual should be > 5 cm (was ~0), got %.4f m', ionoMean);
assert(ionoMean < 20,   'iono residual should be < 20 m (physical), got %.4f m', ionoMean);

% Troposphere residual grows toward low elevation (mapping amplification)
assert(mean(tropMisLow(2:end)) > 2*mean(tropMisZen(2:end)), ...
    'trop residual should grow toward low elevation (low %.4f vs zenith %.4f)', ...
    mean(tropMisLow(2:end)), mean(tropMisZen(2:end)));

% Ionosphere truth varies diurnally (day/night contrast)
assert(max(ionoTruthZen) > 1.5*min(ionoTruthZen), ...
    'iono truth should show a diurnal day/night contrast (max %.3f min %.3f)', ...
    max(ionoTruthZen), min(ionoTruthZen));

% --- Before/after contrast: the matched DEFAULT atmosphere cancels to ~0
ecDef = models.errors.ErrorChain(masterConfig(), 42);   % simpleMapped, matched truth/model
defTrop = 0; defIono = 0;
for k = 1:numel(ts)
    err = ecDef.compute(el, tid, tidx, ts(k));
    if isfield(err.bySource.truth_m,'trop')
        defTrop = max(defTrop, rms(err.bySource.truth_m.trop - err.bySource.model_m.trop));
    end
    if isfield(err.bySource.truth_m,'iono')
        defIono = max(defIono, rms(err.bySource.truth_m.iono - err.bySource.model_m.iono));
    end
end
assert(defTrop < 1e-9 && defIono < 1e-9, ...
    'matched default residuals must cancel to ~0 (trop %.2e, iono %.2e)', defTrop, defIono);

fprintf('  trop residual RMS = %.4f m (low-el %.3f, zenith %.3f) | iono residual RMS = %.4f m\n', ...
    tropMean, mean(tropMisLow(2:end)), mean(tropMisZen(2:end)), ionoMean);
fprintf('  iono truth zenith range = [%.3f, %.3f] m (diurnal)\n', min(ionoTruthZen), max(ionoTruthZen));
fprintf('  matched default (before): trop %.2e m, iono %.2e m (cancels)\n', defTrop, defIono);
fprintf('  PASS\n');
