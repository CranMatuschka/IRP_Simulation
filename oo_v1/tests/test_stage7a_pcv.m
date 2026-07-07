% test_stage7a_pcv
% Task 6: PCV semantics — pcvModel is authoritative.
%
% Verifies:
%   T1: pcvModel='none' always zero (even with legacy enable=true)
%   T2: pcvModel='toy' returns non-zero at low elevation
%   T3: pcvModel='table' with no table throws pcvTableMissing
%   T4: pcvModel='table' with valid table interpolates correctly
%   T5: pcvModel='table' with azDeg field throws pcvAzimuthUnsupported
%   T6: pcvModel='table' with 1 elevation point throws pcvTableTooShort

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_stage7a_pcv ===\n');

r_rx  = [42164e3; 0; 0];
r_twr = [6378e3;  0; 0];
el_low = 10 * pi/180;

% ----------------------------------------------------------------
% T1: pcvModel='none' always zero
% ----------------------------------------------------------------
fprintf('  T1: pcvModel=''none'' always zero ...\n');

cfg1 = revgnss.ConfigFactory.defaultConfig();
cfg1.effects.antenna.pcvModel         = 'none';
cfg1.effects.antennaPCV.truth.enable  = true;   % legacy ON — should be ignored
cfg1.effects.antennaPCV.model.enable  = true;

for side = {'truth','model'}
    [~, c1] = models.corrections.RangeCorrections.correctedPseudorange(r_rx, r_twr, cfg1, side{1}, el_low);
    assert(abs(c1.pcv) < 1e-12, 'T1 FAILED: pcvModel=none side=%s pcv=%.2e', side{1}, c1.pcv);
    fprintf('    side=%-5s pcv=%.2e (zero): PASS\n', side{1}, c1.pcv);
end

% ----------------------------------------------------------------
% T2: pcvModel='toy' non-zero at low elevation
% ----------------------------------------------------------------
fprintf('  T2: pcvModel=''toy'' non-zero at low elevation ...\n');

cfg2 = revgnss.ConfigFactory.defaultConfig();
cfg2.effects.antenna.pcvModel         = 'toy';
cfg2.effects.antennaPCV.truth.enable  = true;
cfg2.effects.antennaPCV.amplitude_m   = 0.05;

[~, c2] = models.corrections.RangeCorrections.correctedPseudorange(r_rx, r_twr, cfg2, 'truth', el_low);
assert(abs(c2.pcv) > 1e-4, 'T2 FAILED: toy PCV at 10 deg should be non-zero, got %.2e', c2.pcv);
fprintf('    toy PCV(10 deg) = %.4f m (non-zero): PASS\n', c2.pcv);

% ----------------------------------------------------------------
% T3: pcvModel='table' with no table throws
% ----------------------------------------------------------------
fprintf('  T3: pcvModel=''table'' with no table throws ...\n');

cfg3 = revgnss.ConfigFactory.defaultConfig();
cfg3.effects.antenna.pcvModel        = 'table';
cfg3.effects.antennaPCV.truth.enable = true;
% Remove the default receiverPcvTable so the 'table' mode has no table
cfg3.effects.antenna = rmfield(cfg3.effects.antenna, 'receiverPcvTable');

threw3 = false;
try
    models.corrections.RangeCorrections.correctedPseudorange(r_rx, r_twr, cfg3, 'truth', el_low);
catch ME
    threw3 = true;
    assert(contains(ME.identifier,'pcvTableMissing') || contains(ME.identifier,'RangeCorrections'), ...
        'T3 FAILED: wrong error id: %s', ME.identifier);
    fprintf('    caught: %s\n', ME.identifier);
end
assert(threw3, 'T3 FAILED: missing table should throw');
fprintf('    PASS\n');

% ----------------------------------------------------------------
% T4: pcvModel='table' valid table interpolates at 30 deg
% ----------------------------------------------------------------
fprintf('  T4: pcvModel=''table'' valid interpolation at 30 deg ...\n');

cfg4 = revgnss.ConfigFactory.defaultConfig();
cfg4.effects.antenna.pcvModel        = 'table';
cfg4.effects.antennaPCV.truth.enable = true;
cfg4.effects.antenna.receiverPcvTable.elDeg = [0 30 60 90];
cfg4.effects.antenna.receiverPcvTable.pcv_m = [0.020 0.010 0.005 0.000];

el30 = 30 * pi/180;
[~, c4] = models.corrections.RangeCorrections.correctedPseudorange(r_rx, r_twr, cfg4, 'truth', el30);
assert(abs(c4.pcv - 0.010) < 1e-8, 'T4 FAILED: PCV(30 deg)=%.6f, expected 0.010', c4.pcv);
fprintf('    PCV(30 deg) = %.4f m (expected 0.010): PASS\n', c4.pcv);

% ----------------------------------------------------------------
% T5: pcvModel='table' with azDeg throws pcvAzimuthUnsupported
% ----------------------------------------------------------------
fprintf('  T5: pcvModel=''table'' with azDeg throws unsupported ...\n');

cfg5 = cfg4;
cfg5.effects.antenna.receiverPcvTable.azDeg = 0:10:350;  % azimuth field

threw5 = false;
try
    models.corrections.RangeCorrections.correctedPseudorange(r_rx, r_twr, cfg5, 'truth', el30);
catch ME
    threw5 = true;
    assert(contains(ME.identifier,'pcvAzimuth') || contains(ME.identifier,'RangeCorrections'), ...
        'T5 FAILED: wrong error id: %s', ME.identifier);
    fprintf('    caught: %s\n', ME.identifier);
end
assert(threw5, 'T5 FAILED: azimuth table should throw pcvAzimuthUnsupported');
fprintf('    PASS\n');

% ----------------------------------------------------------------
% T6: pcvModel='table' with 1 elevation point throws
% ----------------------------------------------------------------
fprintf('  T6: pcvModel=''table'' with 1-point table throws ...\n');

cfg6 = revgnss.ConfigFactory.defaultConfig();
cfg6.effects.antenna.pcvModel        = 'table';
cfg6.effects.antennaPCV.truth.enable = true;
cfg6.effects.antenna.receiverPcvTable.elDeg = [30];
cfg6.effects.antenna.receiverPcvTable.pcv_m = [0.010];

threw6 = false;
try
    models.corrections.RangeCorrections.correctedPseudorange(r_rx, r_twr, cfg6, 'truth', el30);
catch ME
    threw6 = true;
    assert(contains(ME.identifier,'pcvTable') || contains(ME.identifier,'RangeCorrections'), ...
        'T6 FAILED: wrong error id: %s', ME.identifier);
    fprintf('    caught: %s\n', ME.identifier);
end
assert(threw6, 'T6 FAILED: 1-point table should throw pcvTableTooShort');
fprintf('    PASS\n');

fprintf('=== test_stage7a_pcv: ALL PASS ===\n');
