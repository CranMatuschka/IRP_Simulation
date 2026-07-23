% test_wpGH_doppler_partial_iono_guard  WP-G/H: Doppler position partial + iono oracle guard.
%
%   T1  analytic d(rhoDot)/dr matches a finite-difference of the range-rate model (tower vel on)
%   T2  ...and with the tower rotational velocity excluded
%   T3  golden safety: the Doppler position partial is OFF by default
%   T4  ionosphere modelResidual.mode='sameAsTruth' is rejected as a forbidden oracle read

fprintf('=== test_wpGH_doppler_partial_iono_guard ===\n');
thisDir = fileparts(mfilename('fullpath'));
oo = fileparts(thisDir);
addpath(oo); addpath(fullfile(oo,'config'));

% GEO-class geometry: tower near the equator, spacecraft at GEO radius.
r_tx = [6378137 + 100; 0; 0];
r_rx = [42164137; 1.0e6; 5.0e5];
v_rx = [0.10; -0.20; 0.05];
fdPart = @(r,v,tx,c) local_fd_(r,v,tx,c);   % handle to the local FD function at file end

cfg = masterConfig();

% ---- T1: analytic == FD, tower rotational velocity INCLUDED -----------------
cfg.measurements.doppler.includeTowerRotationalVelocity = true;
an1 = revgnss.OneWayRangeRateModel.positionPartial(r_rx, v_rx, r_tx, cfg);
fd1 = fdPart(r_rx, v_rx, r_tx, cfg);
assert(max(abs(an1 - fd1)) < 1e-9, ...
    'T1 FAILED: analytic d(rhoDot)/dr disagrees with finite difference (tower vel on): max err %.2e', max(abs(an1-fd1)));
assert(max(abs(an1)) > 0, 'T1 FAILED: partial is identically zero (expected O(1e-5)).');
fprintf('  T1 analytic d(rhoDot)/dr == FD (tower vel on), |partial|~%.2e: PASS\n', max(abs(an1)));

% ---- T2: analytic == FD, tower rotational velocity EXCLUDED ------------------
cfg.measurements.doppler.includeTowerRotationalVelocity = false;
an2 = revgnss.OneWayRangeRateModel.positionPartial(r_rx, v_rx, r_tx, cfg);
fd2 = fdPart(r_rx, v_rx, r_tx, cfg);
assert(max(abs(an2 - fd2)) < 1e-9, ...
    'T2 FAILED: analytic vs FD disagree (tower vel off): max err %.2e', max(abs(an2-fd2)));
fprintf('  T2 analytic == FD (tower vel off): PASS\n');

% ---- T3: golden safety -- position partial OFF by default -------------------
cfgD = masterConfig();
assert(~cfgD.measurements.doppler.includePositionPartial, ...
    'T3 FAILED: Doppler position partial must be OFF by default (golden byte-identical).');
fprintf('  T3 Doppler position partial OFF by default: PASS\n');

% ---- T4: ionosphere sameAsTruth oracle guard -------------------------------
cfgO = revgnss.ConfigFactory.finalizeConfig(masterConfig());
cfgO.errors.ionosphere.stochastic.modelResidual.enable = true;
cfgO.errors.ionosphere.stochastic.modelResidual.mode   = 'sameAsTruth';
nT = cfgO.scenario.nTowers;
threw = false; gotId = '';
try
    em = models.errors.EnvironmentModel(cfgO, nT, []);
    em.step(1.0, 0.0);
catch me
    gotId = me.identifier; threw = strcmp(me.identifier, 'revgnss:oracleIonoModelResidual');
end
assert(threw, 'T4 FAILED: ionosphere sameAsTruth must throw revgnss:oracleIonoModelResidual (got "%s").', gotId);
fprintf('  T4 ionosphere sameAsTruth oracle guard rejected: PASS\n');

fprintf('=== test_wpGH_doppler_partial_iono_guard: ALL PASSED ===\n');

% ---- local FD of the range-rate model d(rhoDot)/dr --------------------------
function fd = local_fd_(r, v, tx, cfg)
    fd = zeros(1,3); h = 1.0;
    for j = 1:3
        rp = r; rp(j) = rp(j) + h;  rm = r; rm(j) = rm(j) - h;
        rrp = revgnss.OneWayRangeRateModel.compute(rp, v, tx, cfg);
        rrm = revgnss.OneWayRangeRateModel.compute(rm, v, tx, cfg);
        fd(j) = (rrp - rrm) / (2*h);
    end
end
