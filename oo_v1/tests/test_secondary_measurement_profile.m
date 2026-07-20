% test_secondary_measurement_profile
%
% Phase 3b-2 C2: models.measurements.SecondaryMeasurementProfile.forAsset(cfg,i) is the per-asset
% behaviour selector the shared builders will consult. T1: assetIdx=1 is the CHIEF sentinel
% (isChief, chief sources, Doppler on, ErrorChain, real product clock). T2: assetIdx>=2 reproduces
% the retired SecondaryGroundMeasurementBuilder parameters EXACTLY (dedicated RNG sources at
% node=ti*32+ai, flat sigma, matched clock, Guard-A atmosphere, 'simple' ZWD, Doppler off, R-pad).

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir, '..');
addpath(rootDir); addpath(fullfile(rootDir, 'config'));
fprintf('=== test_secondary_measurement_profile ===\n');

cfg = masterConfig();
P = @(i) models.measurements.SecondaryMeasurementProfile.forAsset(cfg, i);
RS = @(n) models.noise.RngSource.(n);

% ---------------------------------------------------------------------
% T1: chief profile (assetIdx=1) == today's chief selections
% ---------------------------------------------------------------------
fprintf('  T1: chief sentinel ...\n');
c = P(1);
assert(c.isChief == true,            'T1 FAILED: assetIdx=1 not isChief');
assert(c.emitDoppler == true,        'T1 FAILED: chief must emit Doppler');
assert(c.useErrorChain == true,      'T1 FAILED: chief must use ErrorChain');
assert(strcmp(c.towerClockMode, 'realProduct'), 'T1 FAILED: chief tower clock');
assert(strcmp(c.atmosphereMode, 'errorChain'),  'T1 FAILED: chief atmosphere');
assert(c.code.source == RS('CODE'),  'T1 FAILED: chief code source');
assert(c.carrier.ambSource == RS('CARR_AMB') && c.carrier.phaseSource == RS('CARR_PHASE'), ...
    'T1 FAILED: chief carrier sources');
assert(c.rPad.enable == false,       'T1 FAILED: chief must not R-pad');
fprintf('    PASS\n');

% ---------------------------------------------------------------------
% T2: secondary profile (assetIdx>=2) == the retired builder's exact parameters
% ---------------------------------------------------------------------
fprintf('  T2: secondary profile matches retired builder ...\n');
ts = cfg.multiAsset.towerSecondary;
s = P(2);
assert(s.isChief == false,           'T2 FAILED: assetIdx=2 must not be chief');
assert(s.emitDoppler == ts.doppler.enable, 'T2 FAILED: secondary emitDoppler must follow cfg (default ON)');
assert(s.doppler.source == RS('SEC_DOPPLER'), 'T2 FAILED: secondary Doppler source');
assert(s.doppler.sigma_mps == ts.doppler.sigma_mps && s.doppler.sigma_mps >= 0.01, 'T2 FAILED: secondary Doppler sigma');
assert(s.doppler.towerClkDriftSigma_mps == ts.towerClkDriftSigma_mps, 'T2 FAILED: secondary Doppler drift pad');
assert(s.useErrorChain == false,     'T2 FAILED: secondary must NOT use ErrorChain');
assert(strcmp(s.towerClockMode, 'matched'),   'T2 FAILED: secondary matched clock');
assert(strcmp(s.zwdMappingKind, 'simple'),    'T2 FAILED: secondary ZWD mapping');
assert(s.code.source == RS('TOWER_SECONDARY'), 'T2 FAILED: secondary code source');
assert(strcmp(s.code.sigmaModel, 'flat') && s.code.flatSigma_m == ts.code.sigma_m, ...
    'T2 FAILED: secondary flat code sigma');
assert(strcmp(s.code.nodeScheme, 'towerAsset32'), 'T2 FAILED: secondary code node scheme');
assert(s.carrier.ambSource == RS('SEC_CARR_AMB') && s.carrier.phaseSource == RS('SEC_CARR_PHASE'), ...
    'T2 FAILED: secondary carrier sources');
assert(s.carrier.sigma_m == ts.carrier.sigma_m, 'T2 FAILED: secondary carrier sigma');
assert(s.carrier.ambStd_m == min(ts.carrier.initialSigma_m, 10), 'T2 FAILED: secondary ambStd');
assert(s.carrier.lambda_m == cfg.signals.L1.lambda_m, 'T2 FAILED: secondary lambda');
assert(s.rPad.enable == true && s.rPad.nCorr == ts.productNCorr && ...
    s.rPad.towerClkSigma_m == ts.towerClkSigma_m, 'T2 FAILED: secondary R-pad');
fprintf('    PASS\n');

% ---------------------------------------------------------------------
% T3: atmosphereMode follows the Guard-A gate (atmosphere.enable)
% ---------------------------------------------------------------------
fprintf('  T3: Guard-A atmosphere gate ...\n');
cfgA = cfg; cfgA.multiAsset.towerSecondary.atmosphere.enable = true;
sa = models.measurements.SecondaryMeasurementProfile.forAsset(cfgA, 2);
assert(strcmp(sa.atmosphereMode, 'guardAUplink'), 'T3 FAILED: atmosphere.enable -> guardAUplink');
cfgB = cfg; cfgB.multiAsset.towerSecondary.atmosphere.enable = false;
sb = models.measurements.SecondaryMeasurementProfile.forAsset(cfgB, 2);
assert(strcmp(sb.atmosphereMode, 'none'), 'T3 FAILED: atmosphere off -> none');
fprintf('    PASS\n');

fprintf('=== test_secondary_measurement_profile: ALL PASS ===\n');
