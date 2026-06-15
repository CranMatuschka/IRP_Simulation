% test_stage8_clock_gauge  Clock gauge formalization validation (Stage 8).
%
% T-P3a: clock.mode='includeTowerClocksInEKF' + gauge.mode='free'
%         → finalizeConfig must throw ConfigFactory:clockGaugeRequired
% T-P3b: clock.mode='includeTowerClocksInEKF' + gauge.mode='externalTowerCorrections'
%         → finalizeConfig succeeds; estimateTowerClocks=true
% T-P3c: clock.mode='spacecraftReceiverClockOnly' (default)
%         → finalizeConfig succeeds; estimateTowerClocks=false
% T-P3d: invalid clock.mode → must throw ConfigFactory:invalidClockMode
% T-P3e: cfg.clock.gauge.mode present in defaultConfig output

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_stage8_clock_gauge ===\n');

% ----------------------------------------------------------------
% T-P3a: 'includeTowerClocksInEKF' + 'free' → must error
% ----------------------------------------------------------------
fprintf('  T-P3a: includeTowerClocksInEKF + gauge=free → error ...\n');
cfg_bad = revgnss.ConfigFactory.defaultConfig();
cfg_bad.clock.mode        = 'includeTowerClocksInEKF';
cfg_bad.clock.gauge.mode  = 'free';

threw = false;
try
    revgnss.ConfigFactory.finalizeConfig(cfg_bad);
catch ME
    if strcmp(ME.identifier, 'ConfigFactory:clockGaugeRequired')
        threw = true;
    else
        rethrow(ME);
    end
end
assert(threw, 'T-P3a FAILED: expected ConfigFactory:clockGaugeRequired error');
fprintf('    PASS (error thrown for unobservable clock config)\n');

% ----------------------------------------------------------------
% T-P3b: 'includeTowerClocksInEKF' + 'externalTowerCorrections' → OK
% ----------------------------------------------------------------
fprintf('  T-P3b: includeTowerClocksInEKF + externalTowerCorrections → OK ...\n');
cfg_ok = revgnss.ConfigFactory.defaultConfig();
cfg_ok.clock.mode        = 'includeTowerClocksInEKF';
cfg_ok.clock.gauge.mode  = 'externalTowerCorrections';
cfg_ok.plots.enable  = false;
cfg_ok.report.enable = false;

cfg_fin = revgnss.ConfigFactory.finalizeConfig(cfg_ok);
assert(cfg_fin.estimator.estimateTowerClocks == true, ...
    'T-P3b FAILED: includeTowerClocksInEKF should set estimateTowerClocks=true');
fprintf('    PASS (estimateTowerClocks=true, no error)\n');

% ----------------------------------------------------------------
% T-P3c: 'spacecraftReceiverClockOnly' (default) → estimateTowerClocks=false
% ----------------------------------------------------------------
fprintf('  T-P3c: spacecraftReceiverClockOnly → estimateTowerClocks=false ...\n');
cfg_sc = revgnss.ConfigFactory.defaultConfig();
% cfg_sc.clock.mode is already 'spacecraftReceiverClockOnly' by default
cfg_sc.plots.enable  = false;
cfg_sc.report.enable = false;

cfg_fin2 = revgnss.ConfigFactory.finalizeConfig(cfg_sc);
assert(cfg_fin2.estimator.estimateTowerClocks == false, ...
    'T-P3c FAILED: spacecraftReceiverClockOnly should set estimateTowerClocks=false');
fprintf('    PASS (estimateTowerClocks=false)\n');

% ----------------------------------------------------------------
% T-P3d: invalid clock.mode → must throw
% ----------------------------------------------------------------
fprintf('  T-P3d: invalid clock.mode → error ...\n');
cfg_inv = revgnss.ConfigFactory.defaultConfig();
cfg_inv.clock.mode = 'someInvalidMode';

threw2 = false;
try
    revgnss.ConfigFactory.finalizeConfig(cfg_inv);
catch ME2
    if strcmp(ME2.identifier, 'ConfigFactory:invalidClockMode')
        threw2 = true;
    else
        rethrow(ME2);
    end
end
assert(threw2, 'T-P3d FAILED: expected ConfigFactory:invalidClockMode error');
fprintf('    PASS (error thrown for invalid clock.mode)\n');

% ----------------------------------------------------------------
% T-P3e: defaultConfig has cfg.clock.mode and cfg.clock.gauge.mode
% ----------------------------------------------------------------
fprintf('  T-P3e: defaultConfig has clock.mode and clock.gauge.mode ...\n');
cfg_def = revgnss.ConfigFactory.defaultConfig();
assert(isfield(cfg_def,'clock'), 'T-P3e FAILED: defaultConfig missing cfg.clock');
assert(isfield(cfg_def.clock,'mode'), 'T-P3e FAILED: defaultConfig missing cfg.clock.mode');
assert(isfield(cfg_def.clock,'gauge'), 'T-P3e FAILED: defaultConfig missing cfg.clock.gauge');
assert(isfield(cfg_def.clock.gauge,'mode'), 'T-P3e FAILED: defaultConfig missing cfg.clock.gauge.mode');
assert(strcmp(cfg_def.clock.mode,'spacecraftReceiverClockOnly'), ...
    'T-P3e FAILED: default clock.mode should be spacecraftReceiverClockOnly');
assert(strcmp(cfg_def.clock.gauge.mode,'externalTowerCorrections'), ...
    'T-P3e FAILED: default clock.gauge.mode should be externalTowerCorrections');
fprintf('    clock.mode = %s\n', cfg_def.clock.mode);
fprintf('    clock.gauge.mode = %s\n', cfg_def.clock.gauge.mode);
fprintf('    PASS\n');

% ----------------------------------------------------------------
% T-P3f: NEES getter exists and returns finite values after a short run
% ----------------------------------------------------------------
fprintf('  T-P3f: NEES_pos getter returns finite values ...\n');
cfg_nees = revgnss.ConfigFactory.defaultConfig();
cfg_nees.scenario.nTowers     = 5;   % 5 towers → >=4 measurements/epoch → EKF updates
cfg_nees.scenario.nReceivers  = 1;
cfg_nees.simulation.duration_s = 20;
cfg_nees.simulation.dt_s       = 1;
cfg_nees.plots.enable  = false;
cfg_nees.report.enable = false;
cfg_nees.errors.codeNoise.sigma_m = 0;

sim_n = revgnss.ReverseGNSSSimulation(cfg_nees);
sim_n.run();
nees = sim_n.diag.getNEES();
assert(~isempty(nees), 'T-P3f FAILED: getNEES() returned empty');
nees_fin = nees(isfinite(nees));
assert(~isempty(nees_fin), 'T-P3f FAILED: all NEES values are NaN/Inf');
assert(all(nees_fin >= 0), 'T-P3f FAILED: NEES values should be non-negative');
fprintf('    Median NEES_pos: %.4f (expect ~1 for consistent filter)\n', median(nees_fin));
fprintf('    PASS\n');

fprintf('=== test_stage8_clock_gauge: ALL PASS ===\n');
