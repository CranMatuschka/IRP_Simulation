% test_saastamoinen_guards  Input guards for Saastamoinen standard atmosphere (T10).
%
% T10a: h=-600 warns and clamps to -500.
% T10b: h=15000 warns and clamps to 11000.
% T10c: RH=1.5 clamped to 1.0.
% T10d: Output ZHD/ZWD is always finite.
%
% CHANGED: v3→v4 — Issue 14

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_saastamoinen_guards (T10) ===\n');

% ----------------------------------------------------------------
% T10a: h = -600 m → warn and clamp to -500
% ----------------------------------------------------------------
fprintf('  T10a: h=-600 m (below validity range) → warn + clamp ...\n');
cfg_low = revgnss.ConfigFactory.defaultConfig();
cfg_low.plots.enable  = false;
cfg_low.report.enable = false;
cfg_low.errors.troposphere.modelType = 'localWeatherGM';
cfg_low.errors.troposphere.truth.enable = true;
cfg_low.errors.troposphere.model.enable = true;
cfg_low.errors.troposphere.stochastic.enable = false;
for k = 1:numel(cfg_low.towers)
    cfg_low.towers(k).alt_m = -600;
end

lastwarn('');
env_low = revgnss.EnvironmentModel(cfg_low, cfg_low.scenario.nTowers);
[wmsg, wid] = lastwarn();
hasWarn_low = contains(wid, 'saastHeight') || contains(wmsg, 'Saastamoinen') || ...
              contains(wmsg, 'validity') || contains(wmsg, 'clamping');
assert(hasWarn_low, 'T10a FAILED: no Saastamoinen height warning for h=-600');
for k = 1:cfg_low.scenario.nTowers
    assert(isfinite(env_low.weatherState(k).ZHD_m), 'T10a FAILED: ZHD is NaN for tower %d', k);
    assert(isfinite(env_low.weatherState(k).ZWD_m), 'T10a FAILED: ZWD is NaN for tower %d', k);
end
fprintf('    PASS (warning caught, output finite)\n');

% ----------------------------------------------------------------
% T10b: h = 15000 m → warn and clamp to 11000
% ----------------------------------------------------------------
fprintf('  T10b: h=15000 m (above validity range) → warn + clamp ...\n');
cfg_high = revgnss.ConfigFactory.defaultConfig();
cfg_high.plots.enable  = false;
cfg_high.report.enable = false;
cfg_high.errors.troposphere.modelType = 'localWeatherGM';
cfg_high.errors.troposphere.truth.enable = true;
cfg_high.errors.troposphere.model.enable = true;
cfg_high.errors.troposphere.stochastic.enable = false;
for k = 1:numel(cfg_high.towers)
    cfg_high.towers(k).alt_m = 15000;
end

lastwarn('');
env_high = revgnss.EnvironmentModel(cfg_high, cfg_high.scenario.nTowers);
[wmsg2, wid2] = lastwarn();
hasWarn_high = contains(wid2, 'saastHeight') || contains(wmsg2, 'Saastamoinen') || ...
               contains(wmsg2, 'validity') || contains(wmsg2, 'clamping');
assert(hasWarn_high, 'T10b FAILED: no Saastamoinen height warning for h=15000');
for k = 1:cfg_high.scenario.nTowers
    assert(isfinite(env_high.weatherState(k).ZHD_m), 'T10b FAILED: ZHD NaN for tower %d', k);
    assert(isfinite(env_high.weatherState(k).ZWD_m), 'T10b FAILED: ZWD NaN for tower %d', k);
end
fprintf('    PASS (warning caught, output finite)\n');

% ----------------------------------------------------------------
% T10c: RH = 1.5 → clamped to 1.0 (test ZWD is finite)
% ----------------------------------------------------------------
fprintf('  T10c: RH=1.5 → clamped to 1.0, output finite ...\n');
cfg_rh = revgnss.ConfigFactory.defaultConfig();
cfg_rh.plots.enable  = false;
cfg_rh.report.enable = false;
cfg_rh.errors.troposphere.modelType = 'localWeatherGM';
cfg_rh.errors.troposphere.truth.enable = true;
cfg_rh.errors.troposphere.model.enable = true;
cfg_rh.errors.troposphere.stochastic.enable = false;
for k = 1:numel(cfg_rh.towers)
    cfg_rh.towers(k).alt_m = 0;
end
cfg_rh.environment.weather.defaultRelativeHumidity = 1.5;

env_rh = revgnss.EnvironmentModel(cfg_rh, cfg_rh.scenario.nTowers);
for k = 1:cfg_rh.scenario.nTowers
    assert(isfinite(env_rh.weatherState(k).ZWD_m), 'T10c FAILED: ZWD NaN for tower %d', k);
    assert(env_rh.weatherState(k).ZWD_m <= 0.15 * 1.0 + 0.01, ...
        'T10c FAILED: ZWD %.4f exceeds value at RH=1.0 + tolerance', ...
        env_rh.weatherState(k).ZWD_m);
end
fprintf('    PASS (ZWD finite and bounded)\n');

% ----------------------------------------------------------------
% T10d: Normal altitude → always finite
% ----------------------------------------------------------------
fprintf('  T10d: Normal altitude h=500 m → always finite ...\n');
cfg_ok = revgnss.ConfigFactory.defaultConfig();
cfg_ok.plots.enable  = false;
cfg_ok.report.enable = false;
cfg_ok.errors.troposphere.modelType = 'localWeatherGM';
cfg_ok.errors.troposphere.truth.enable = true;
cfg_ok.errors.troposphere.model.enable = true;
cfg_ok.errors.troposphere.stochastic.enable = false;
for k = 1:numel(cfg_ok.towers)
    cfg_ok.towers(k).alt_m = 500;
end

env_ok = revgnss.EnvironmentModel(cfg_ok, cfg_ok.scenario.nTowers);
for k = 1:cfg_ok.scenario.nTowers
    assert(isfinite(env_ok.weatherState(k).ZHD_m), 'T10d FAILED: ZHD NaN for tower %d', k);
    assert(isfinite(env_ok.weatherState(k).ZWD_m), 'T10d FAILED: ZWD NaN for tower %d', k);
end
fprintf('    PASS\n');

fprintf('=== test_saastamoinen_guards: ALL PASS ===\n');
