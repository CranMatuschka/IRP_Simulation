% test_stage7a_iono_mapping
% Task 2: Ionosphere thin-shell mapping model.
%
% Verifies:
%   T1: simpleSecant at zenith returns 1.0 (1/sin(90))
%   T2: thinShell at zenith returns 1.0 exactly
%   T3: thinShell at 10 deg < simpleSecant at 10 deg (thin-shell < secant at low elevation)
%   T4: simpleSecant backward compatibility — EnvironmentModel still produces correct delay
%   T5: no magic constant 1.57 in ionosphere mapping code paths
%   T6: EnvironmentModel uses config-driven mappingModel

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_stage7a_iono_mapping ===\n');

% ----------------------------------------------------------------
% T1: simpleSecant at zenith = 1/sin(90) = 1.0
% ----------------------------------------------------------------
fprintf('  T1: simpleSecant at zenith ...\n');
m_zen = revgnss.MappingFunctions.ionosphere(pi/2, 'simpleSecant');
assert(abs(m_zen - 1.0) < 1e-12, 'T1 FAILED: simpleSecant at zenith=%.10f, expected 1.0', m_zen);
fprintf('    simpleSecant at 90 deg = %.10f: PASS\n', m_zen);

% ----------------------------------------------------------------
% T2: thinShell at zenith returns exactly 1.0
% ----------------------------------------------------------------
fprintf('  T2: thinShell at zenith = 1.0 ...\n');
m_ts_zen = revgnss.MappingFunctions.ionosphere(pi/2, 'thinShell', 350e3);
% At zenith, cos(90) = 0, so arg = 0, sqrt(1-0) = 1, M = 1
assert(abs(m_ts_zen - 1.0) < 1e-10, 'T2 FAILED: thinShell at zenith=%.10f, expected 1.0', m_ts_zen);
fprintf('    thinShell at 90 deg = %.10f: PASS\n', m_ts_zen);

% ----------------------------------------------------------------
% T3: thinShell(10 deg) < simpleSecant(10 deg)
% The thin-shell model accounts for the shell height; the mapping
% factor is smaller than the flat-Earth 1/sin approximation.
% ----------------------------------------------------------------
fprintf('  T3: thinShell < simpleSecant at low elevation ...\n');
el_low = 10 * pi/180;
m_sec = revgnss.MappingFunctions.ionosphere(el_low, 'simpleSecant');
m_ts  = revgnss.MappingFunctions.ionosphere(el_low, 'thinShell', 350e3);
assert(m_ts < m_sec, 'T3 FAILED: thinShell(10 deg)=%.4f should be < simpleSecant(10 deg)=%.4f', m_ts, m_sec);
fprintf('    thinShell(10 deg)=%.4f < simpleSecant(10 deg)=%.4f: PASS\n', m_ts, m_sec);

% ----------------------------------------------------------------
% T4: simpleSecant backward compatibility via EnvironmentModel
% ----------------------------------------------------------------
fprintf('  T4: simpleSecant in EnvironmentModel backward compatibility ...\n');
cfg4 = revgnss.ConfigFactory.defaultConfig();
% Default should be simpleSecant
cfg4.effects.ionosphere.mappingModel = 'simpleSecant';
cfg4.errors.ionosphere.truth.enable  = true;
cfg4.errors.ionosphere.truth.verticalDelayL1_m = 5.0;
env4 = revgnss.EnvironmentModel(cfg4, 1);

el_45 = 45 * pi/180;
f_L1 = 1575.42e6;
delay4 = env4.getIonoDelay(1, el_45, 'truth', f_L1, f_L1);
% Expected: 5.0 / sin(45) = 5.0 * sqrt(2) ≈ 7.071
expected4 = 5.0 / sin(el_45);
assert(abs(delay4 - expected4) < 1e-6, ...
    'T4 FAILED: simpleSecant delay=%.6f, expected %.6f', delay4, expected4);
fprintf('    delay(45 deg, simpleSecant) = %.4f m (expected %.4f): PASS\n', delay4, expected4);

% ----------------------------------------------------------------
% T5: thinShell via EnvironmentModel — delay differs from secant
% ----------------------------------------------------------------
fprintf('  T5: thinShell via EnvironmentModel differs from simpleSecant ...\n');
cfg5 = cfg4;
cfg5.effects.ionosphere.mappingModel  = 'thinShell';
cfg5.effects.ionosphere.shellHeight_m = 350e3;
env5 = revgnss.EnvironmentModel(cfg5, 1);
delay5 = env5.getIonoDelay(1, el_low, 'truth', f_L1, f_L1);
delay5_sec = 5.0 / sin(el_low);
% thinShell delay should differ meaningfully from secant at low elevation
assert(abs(delay5 - delay5_sec) / delay5_sec > 0.1, ...
    'T5 FAILED: thinShell and simpleSecant differ by only %.2f%% at 10 deg', ...
    abs(delay5-delay5_sec)/delay5_sec*100);
fprintf('    thinShell(10 deg)=%.4f vs secant=%.4f, diff=%.1f%%: PASS\n', ...
    delay5, delay5_sec, abs(delay5-delay5_sec)/delay5_sec*100);

% ----------------------------------------------------------------
% T6: no magic constant 1.57 in mapping code paths
% ----------------------------------------------------------------
fprintf('  T6: no magic 1.57 in MappingFunctions.ionosphere ...\n');
src = fileread(which('revgnss.MappingFunctions'));
% The critical check: 1.57 was a bogus approximation used in some Klobuchar code
% Our thin-shell uses only Earth radius, shell height, and sqrt/cos
assert(~contains(src, '1.57'), ...
    'T6 FAILED: magic constant 1.57 found in MappingFunctions — verify no Klobuchar constant');
fprintf('    No magic constant 1.57 found: PASS\n');

fprintf('=== test_stage7a_iono_mapping: ALL PASS ===\n');
