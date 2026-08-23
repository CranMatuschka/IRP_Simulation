% test_tower_clock_product_cache_order
%
% Guards the invariant: a run's result must NOT depend on what ran BEFORE it in the same
% MATLAB process.
%
% REGRESSION FOR: models.clocks.TowerClockCorrectionProvider.productNoise_ cached the
% SIGMA-SCALED product noise under a key of (towerIndex, productEpoch) only. The cache is a
% `persistent`, so it lives for the whole MATLAB process. The first config to run therefore
% froze the tower-clock product noise realisation at ITS sigma, and every later run in that
% process silently reused it while its OWN sigma still flowed live into R. With
% cfg.clocks.tower.product.sigmaBias_m = 0.01 (masterConfig default) vs 0.10 (realism grade),
% a realism run that followed a default run in one process was injected 10x-too-quiet noise
% against a correctly-sized R -- a mistuned filter that NO config file can produce, and which
% the stored cfg in the .mat did not reveal (it recorded the requested sigma, not the used one).
%
% The fix caches the UNIT NORMALS (config-independent) and scales by sigma at read time.
%
% This test runs the SAME config twice: once after a different-sigma run has warmed the cache,
% and once with a cold cache. The two must agree exactly.

oo = fileparts(fileparts(mfilename('fullpath')));
addpath(oo); addpath(fullfile(oo,'config'));

SIG_DEFAULT = 0.01;   % masterConfig default (IGS-class)
SIG_REALISM = 0.10;   % realism grade (IGS-RTS class)

% 1. Warm the persistent cache with the DEFAULT sigma.
i_run(SIG_DEFAULT);

% 2. Same process, cache warm: run with the REALISM sigma.
warmChecksum = i_run(SIG_REALISM);

% 3. Drop the persistent cache, then run the REALISM sigma with a COLD cache.
clear functions %#ok<CLFUNC>
coldChecksum = i_run(SIG_REALISM);

% 4. Control: a different sigma must actually change the result (guards against the test
%    passing because sigma is inert everywhere).
clear functions %#ok<CLFUNC>
otherChecksum = i_run(SIG_DEFAULT);

fprintf('warm-cache  sigma=%.2f : %.17g\n', SIG_REALISM, warmChecksum);
fprintf('cold-cache  sigma=%.2f : %.17g\n', SIG_REALISM, coldChecksum);
fprintf('cold-cache  sigma=%.2f : %.17g\n', SIG_DEFAULT, otherChecksum);

if ~isequal(warmChecksum, coldChecksum)
    error('test_tower_clock_product_cache_order:orderDependent', ...
        ['Tower-clock product noise is EXECUTION-ORDER DEPENDENT: the same config gave %.17g ' ...
         'after a sigma=%.2f run warmed the cache, but %.17g with a cold cache. ' ...
         'productNoise_ must cache config-independent unit normals and scale by sigma at read.'], ...
        warmChecksum, SIG_DEFAULT, coldChecksum);
end
if isequal(coldChecksum, otherChecksum)
    error('test_tower_clock_product_cache_order:sigmaInert', ...
        ['Control failed: sigmaBias_m = %.2f and %.2f produced identical results, so this test ' ...
         'cannot detect the cache bug. Check that the product path is active.'], ...
        SIG_REALISM, SIG_DEFAULT);
end

fprintf('test_tower_clock_product_cache_order: PASS (order-independent; sigma is live)\n');

% ------------------------------------------------------------------------------------------
function s = i_run(sigmaBias_m)
    cfg = masterConfig();
    cfg.scenario.nTowers      = 5;
    cfg.scenario.nSpaceAssets = 1;
    cfg.scenario.nReceivers   = 1;
    cfg.simulation.duration_s = 120;                 % short: the cache bites from the first epoch
    cfg.report.writePdf       = false;
    cfg.report.writeMat       = false;
    cfg.plots.showFigures     = false;
    cfg.estimator.runKnownAmbiguityValidation = false;
    cfg.clocks.tower.product.sigmaBias_m = sigmaBias_m;
    out = revgnss.ReportRunner.runSingle(cfg);
    e = out.simData.getPositionErrorVecs();
    s = sum(abs(e(:)), 'omitnan');
end
