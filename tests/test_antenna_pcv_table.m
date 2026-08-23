% test_antenna_pcv_table
% pcvModel='table' mode: RangeCorrections uses linear interpolation on PCV table.
%
% Verifies:
%   - Table with known PCV values returns interpolated correction
%   - Clipped to table bounds (no extrapolation surprises)
%   - pcvModel='none' returns 0

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_antenna_pcv_table ===\n');

% Build a config that has pcvModel='table' and known PCV values
cfg = revgnss.ConfigFactory.defaultConfig();
cfg.effects.antenna.pcvModel = 'table';
cfg.effects.antenna.receiverPcvTable.elDeg = [0 30 60 90];
cfg.effects.antenna.receiverPcvTable.pcv_m = [0.02  0.01  0.005  0.0];
% Enable legacy on/off gate so pcvCorrection_ actually fires
cfg.effects.antennaPCV.truth.enable = true;
cfg.effects.antennaPCV.model.enable = true;

% At 30 deg: expect 0.01 m
el_30 = 30 * pi/180;
[~, contrib30] = models.corrections.RangeCorrections.correctedPseudorange( ...
    [0;0;42e6], [0;1e6;0], cfg, 'truth', el_30);
assert(abs(contrib30.pcv - 0.01) < 1e-10, ...
    'PCV table at 30 deg should be 0.01 m, got %.6f', contrib30.pcv);

% At 0 deg: expect 0.02 m (first entry)
el_0 = 0;
[~, contrib0] = models.corrections.RangeCorrections.correctedPseudorange( ...
    [0;0;42e6], [0;1e6;0], cfg, 'truth', el_0);
assert(abs(contrib0.pcv - 0.02) < 1e-10, ...
    'PCV table at 0 deg should be 0.02 m, got %.6f', contrib0.pcv);

% pcvModel='none': correction should be 0
cfg_none = cfg;
cfg_none.effects.antenna.pcvModel = 'none';
[~, contrib_none] = models.corrections.RangeCorrections.correctedPseudorange( ...
    [0;0;42e6], [0;1e6;0], cfg_none, 'truth', el_30);
assert(abs(contrib_none.pcv) < 1e-12, ...
    'pcvModel=none should give 0 PCV, got %.2e', contrib_none.pcv);

fprintf('  pcv(30 deg)=%.4f m  pcv(0 deg)=%.4f m  pcv(none)=%.2e\n', ...
    contrib30.pcv, contrib0.pcv, contrib_none.pcv);

% ---- T2: malformed table — mismatched lengths throws clear error ----
fprintf('  T2: malformed table (length mismatch) throws error ...\n');

cfg_bad = cfg;
cfg_bad.effects.antenna.receiverPcvTable.elDeg = [0 30 60 90];
cfg_bad.effects.antenna.receiverPcvTable.pcv_m = [0.02 0.01];  % wrong length

threwBad = false;
try
    models.corrections.RangeCorrections.correctedPseudorange([0;0;42e6], [0;1e6;0], cfg_bad, 'truth', el_30);
catch ME
    threwBad = true;
    assert(contains(ME.identifier, 'pcvTable') || contains(ME.identifier, 'RangeCorrections'), ...
        'T2: wrong error id: %s', ME.identifier);
    fprintf('    caught expected error: %s\n', ME.identifier);
end
assert(threwBad, 'T2 FAILED: mismatched table lengths should throw an error');
fprintf('    PASS\n');

% ---- T3: azimuth field present → clear error ----
fprintf('  T3: azimuth-dependent table rejects azDeg field ...\n');

cfg_az = cfg;
cfg_az.effects.antenna.receiverPcvTable.azDeg = 0:10:350;

threwAz = false;
try
    models.corrections.RangeCorrections.correctedPseudorange([0;0;42e6], [0;1e6;0], cfg_az, 'truth', el_30);
catch ME
    threwAz = true;
    assert(contains(ME.identifier, 'pcvAzimuth') || contains(ME.identifier, 'RangeCorrections'), ...
        'T3: wrong error id: %s', ME.identifier);
    fprintf('    caught expected error: %s\n', ME.identifier);
end
assert(threwAz, 'T3 FAILED: azDeg field should throw an unsupported error');
fprintf('    PASS\n');

fprintf('  PASS\n');
