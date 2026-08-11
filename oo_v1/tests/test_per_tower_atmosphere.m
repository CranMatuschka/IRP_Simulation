% test_per_tower_atmosphere
% Each tower's slant path towards space carries its OWN atmosphere, and gaseous
% absorption uses the same humidity the troposphere uses at that site.
%
% THE DEFECT THIS PINS. ZWD = 0.15*RH*exp(-alt/2000) with ONE global relative humidity
% and every golden tower at sea level gave the whole network an IDENTICAL 0.07500 m
% zenith wet delay -- Libreville at 0.04 deg N and Stockholm at 59.3 deg N modelled as
% equally humid. Separately, the frozen ITU-R P.676 table was integrated over P.835's
% reference atmosphere (ZWD_REF_M = 0.095669 m), so absorption silently assumed a
% humidity 22% WETTER than the troposphere it shares a sky with. Two atmospheres in one
% model, which is the defect class the design set out to avoid.
%
% Verified here:
%   1. empty perTowerRelativeHumidity reproduces the old behaviour EXACTLY
%   2. a per-tower vector gives each tower its own ZWD, and the size guard bites
%   3. absorption scales with the TOWER's humidity, not the table's reference
%   4. the wet column moves and the dry column does NOT
%   5. the magnitude is right where it matters: ~18% off at 24 GHz, negligible at L1

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_per_tower_atmosphere ===\n');

nFail = 0;
GA    = @(f,el,o) models.atmosphere.GaseousAbsorption.slantAttenuation_dB(f,el,o);
ZREF  = models.atmosphere.GaseousAbsorption.ZWD_REF_M;

% ---- 1. Default is inert: every tower keeps the historic single humidity ----
cfgM = masterConfig();
nFail = nFail + chk(isfield(cfgM.environment.weather,'perTowerRelativeHumidity') && ...
                    isempty(cfgM.environment.weather.perTowerRelativeHumidity), ...
    'perTowerRelativeHumidity exists and defaults to EMPTY');

w = warning('off','all');
cfg0 = resolveSimulationConfig('golden_baseline.json');
warning(w);
em0  = models.errors.EnvironmentModel(cfg0, numel(cfg0.towers));
z0   = arrayfun(@(k) em0.zenithWetDelay_m(k), 1:numel(cfg0.towers));

nFail = nFail + chk(all(abs(z0 - 0.075) < 1e-12), ...
    sprintf('default: every tower ZWD is 0.07500 m (got %s)', mat2str(round(z0,6))));
nFail = nFail + chk(max(z0) - min(z0) == 0, ...
    'default: the network is uniform, i.e. the historic behaviour is unchanged');

% ---- 2. A per-tower vector individuates the network -------------------------
nT   = numel(cfg0.towers);
RH   = linspace(0.20, 0.90, nT);          % dry high-latitude .. humid equatorial
cfg1 = cfg0;
cfg1.environment.weather.perTowerRelativeHumidity = RH;
em1  = models.errors.EnvironmentModel(cfg1, nT);
z1   = arrayfun(@(k) em1.zenithWetDelay_m(k), 1:nT);

nFail = nFail + chk(all(abs(z1 - 0.15*RH) < 1e-12), ...
    sprintf('per-tower ZWD follows 0.15*RH (got %s)', mat2str(round(z1,5))));
nFail = nFail + chk(numel(unique(round(z1,9))) == nT, ...
    'every tower now has a DISTINCT zenith wet delay');

% Size guard: a mismatched vector must be refused, not silently recycled.
ok = false;
try
    cfgBad = cfg0;
    cfgBad.environment.weather.perTowerRelativeHumidity = [0.3 0.4];
    models.errors.EnvironmentModel(cfgBad, nT);
catch ME
    ok = strcmp(ME.identifier, 'EnvironmentModel:perTowerHumiditySize');
end
nFail = nFail + chk(ok, 'a wrong-length humidity vector is refused');

% ---- 3. Absorption follows the TOWER, not the table's reference -------------
% At 24.125 GHz water vapour is 81% of the total, so the tower's humidity must move it.
f24 = 24.125e9;
el  = pi/2;
Aref = GA(f24, el, struct());                                  % table reference humidity
for k = 1:nT
    Ak = GA(f24, el, struct('ZWD_m', z1(k)));
    [d, wcol] = models.atmosphere.GaseousAbsorption.zenithDryWet(f24);
    want = d + wcol * (z1(k)/ZREF);
    nFail = nFail + chk(abs(Ak - want) < 1e-12, ...
        sprintf('tower %d at 24 GHz: %.6f, expected %.6f', k, Ak, want));
end
spread = GA(f24, el, struct('ZWD_m', max(z1))) - GA(f24, el, struct('ZWD_m', min(z1)));
nFail = nFail + chk(spread > 0.15, ...
    sprintf('24 GHz absorption varies across the network by %.4f dB', spread));

% ---- 4. Only the WET column responds to humidity ----------------------------
[dry24, wet24] = models.atmosphere.GaseousAbsorption.zenithDryWet(f24);
A_dryOnly = GA(f24, el, struct('ZWD_m', 0));
nFail = nFail + chk(abs(A_dryOnly - dry24) < 1e-12, ...
    'zero humidity leaves exactly the dry column');
nFail = nFail + chk(wet24/(dry24+wet24) > 0.75, ...
    'and the wet column is the dominant term at 24 GHz, which is why this matters');

% ---- 5. The correction has the size the analysis predicted ------------------
% The repo default (ZWD 0.0750) is 22% drier than the table's reference (0.095669).
ratio = 0.075 / ZREF;
nFail = nFail + chk(abs(ratio - 0.784) < 1e-3, ...
    sprintf('repo default is %.3f of the table reference humidity', ratio));

A24_ref = GA(f24, el, struct());
A24_rep = GA(f24, el, struct('ZWD_m', 0.075));
relChange = A24_rep/A24_ref - 1;
nFail = nFail + chk(relChange < -0.15 && relChange > -0.20, ...
    sprintf('24 GHz total falls %.1f%% once the real humidity is used', 100*relChange));

fL1 = 1.57542e9;
L1_ref = GA(fL1, el, struct());
L1_rep = GA(fL1, el, struct('ZWD_m', 0.075));
nFail = nFail + chk(abs(L1_rep/L1_ref - 1) < 0.005, ...
    sprintf('L1 barely moves (%.4f%%), so no L-band result is disturbed', ...
            100*(L1_rep/L1_ref - 1)));

if nFail > 0
    error('test_per_tower_atmosphere:FAIL', '%d assertion(s) failed', nFail);
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
