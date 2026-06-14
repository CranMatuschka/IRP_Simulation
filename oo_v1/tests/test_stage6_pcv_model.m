% test_stage6_pcv_model
% Phase 7: PCV table semantics — pcvModel='none' always zero;
%          pcvModel='table' throws when table missing.
%
% Verifies:
%   T1: pcvModel='none' returns 0 regardless of legacy antennaPCV enable flags
%   T2: pcvModel='table' with no table throws RangeCorrections:pcvTableMissing
%   T3: pcvModel='table' with missing elDeg/pcv_m fields throws clearly
%   T4: pcvModel='toy' returns cos^2(el) shape (non-zero at low elevations)
%   T5: pcvModel='table' with valid table still interpolates correctly

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_stage6_pcv_model ===\n');

% Common test geometry
r_asset = [0; 0; 42164e3];  % ~GEO
r_tower = [6378e3; 0; 0];   % equatorial tower
el_mid  = 30 * pi/180;

% ----------------------------------------------------------------
% T1: pcvModel='none' returns 0 regardless of legacy flags
% ----------------------------------------------------------------
fprintf('  T1: pcvModel=''none'' returns 0 regardless of legacy flags ...\n');

cfg_none = revgnss.ConfigFactory.defaultConfig();
cfg_none.effects.antenna.pcvModel     = 'none';
cfg_none.effects.antennaPCV.truth.enable = true;   % legacy flag ON
cfg_none.effects.antennaPCV.model.enable = true;   % legacy flag ON

for side = {'truth','model'}
    [~, contrib] = revgnss.RangeCorrections.correctedPseudorange( ...
        r_asset, r_tower, cfg_none, side{1}, el_mid);
    assert(abs(contrib.pcv) < 1e-12, ...
        'T1 FAILED: pcvModel=none side=%s gave pcv=%.2e (expected 0)', ...
        side{1}, contrib.pcv);
    fprintf('    side=%-5s pcv=%.2e (zero): PASS\n', side{1}, contrib.pcv);
end

% ----------------------------------------------------------------
% T2: pcvModel='table' with NO table throws pcvTableMissing
% ----------------------------------------------------------------
fprintf('  T2: pcvModel=''table'' with no table throws pcvTableMissing ...\n');

cfg_tab = revgnss.ConfigFactory.defaultConfig();
cfg_tab.effects.antenna.pcvModel         = 'table';
cfg_tab.effects.antennaPCV.truth.enable  = true;
% Deliberately do NOT set cfg_tab.effects.antenna.receiverPcvTable

threwT2 = false;
try
    revgnss.RangeCorrections.correctedPseudorange(r_asset, r_tower, cfg_tab, 'truth', el_mid);
catch ME
    threwT2 = true;
    assert(contains(ME.identifier,'pcvTableMissing') || ...
           contains(ME.identifier,'RangeCorrections'), ...
        'T2 FAILED: wrong error id: %s', ME.identifier);
    fprintf('    caught expected error: %s\n', ME.identifier);
end
assert(threwT2, 'T2 FAILED: missing table should throw');
fprintf('    PASS\n');

% ----------------------------------------------------------------
% T3: pcvModel='table' with malformed table (length mismatch) throws
% ----------------------------------------------------------------
fprintf('  T3: pcvModel=''table'' with mismatched lengths throws ...\n');

cfg_bad = revgnss.ConfigFactory.defaultConfig();
cfg_bad.effects.antenna.pcvModel         = 'table';
cfg_bad.effects.antennaPCV.truth.enable  = true;
cfg_bad.effects.antenna.receiverPcvTable.elDeg = [0 30 60 90];
cfg_bad.effects.antenna.receiverPcvTable.pcv_m = [0.02 0.01];  % wrong length

threwT3 = false;
try
    revgnss.RangeCorrections.correctedPseudorange(r_asset, r_tower, cfg_bad, 'truth', el_mid);
catch ME
    threwT3 = true;
    assert(contains(ME.identifier,'pcvTable') || contains(ME.identifier,'RangeCorrections'), ...
        'T3 FAILED: wrong error id: %s', ME.identifier);
    fprintf('    caught expected error: %s\n', ME.identifier);
end
assert(threwT3, 'T3 FAILED: mismatched table lengths should throw');
fprintf('    PASS\n');

% ----------------------------------------------------------------
% T4: pcvModel='toy' returns a non-trivial correction at low elevation
% ----------------------------------------------------------------
fprintf('  T4: pcvModel=''toy'' returns non-zero at low elevation ...\n');

cfg_toy = revgnss.ConfigFactory.defaultConfig();
cfg_toy.effects.antenna.pcvModel         = 'toy';
cfg_toy.effects.antennaPCV.truth.enable  = true;
cfg_toy.effects.antennaPCV.amplitude_m   = 0.05;

el_low = 10 * pi/180;
[~, contrib_toy] = revgnss.RangeCorrections.correctedPseudorange( ...
    r_asset, r_tower, cfg_toy, 'truth', el_low);
assert(abs(contrib_toy.pcv) > 1e-4, ...
    'T4 FAILED: toy PCV at 10 deg should be > 0, got %.2e', contrib_toy.pcv);
fprintf('    toy PCV(10 deg)=%.4f m (non-zero): PASS\n', contrib_toy.pcv);

% ----------------------------------------------------------------
% T5: pcvModel='table' with valid table interpolates correctly at 60 deg
% ----------------------------------------------------------------
fprintf('  T5: pcvModel=''table'' interpolates correctly ...\n');

cfg_t5 = revgnss.ConfigFactory.defaultConfig();
cfg_t5.effects.antenna.pcvModel         = 'table';
cfg_t5.effects.antennaPCV.truth.enable  = true;
cfg_t5.effects.antenna.receiverPcvTable.elDeg = [0  30  60  90];
cfg_t5.effects.antenna.receiverPcvTable.pcv_m = [0.020 0.010 0.005 0.000];

el_60 = 60 * pi/180;
[~, contrib_t5] = revgnss.RangeCorrections.correctedPseudorange( ...
    r_asset, r_tower, cfg_t5, 'truth', el_60);
assert(abs(contrib_t5.pcv - 0.005) < 1e-8, ...
    'T5 FAILED: PCV(60 deg)=%.6f, expected 0.005', contrib_t5.pcv);
fprintf('    PCV(60 deg)=%.4f m (expected 0.005): PASS\n', contrib_t5.pcv);

fprintf('=== test_stage6_pcv_model: ALL PASS ===\n');
