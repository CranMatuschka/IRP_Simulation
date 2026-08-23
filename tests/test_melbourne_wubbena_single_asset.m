% test_melbourne_wubbena_single_asset  Gate, liveness and non-interference for the
% single-asset Melbourne-Wubbena wide lane (revgnss.MelbourneWubbenaArcEstimator).
%
% THE FOUR THINGS THIS HAS TO PROVE, in the order they can fail:
%
%   T1 GATE OFF IS INERT. cfg.diagnostics.melbourneWubbena.enable defaults false and, with
%      it off, no truth ambiguity is published into cpInfo and the accumulator does nothing.
%      This is the check that catches a "gated" commit leaking into the default path.
%
%   T2 THE TOGGLE IS LIVE. With the gate on, the accumulator actually consumes epochs and
%      arcs. This repo has a documented history of toggles that are declared, merged
%      without error, and then read by nobody -- deepMergeConfig validates the PATH, never
%      the consumer -- so a declaration is not evidence and the count is.
%
%   T3 GATE ON CHANGES NO EKF NUMBER. The estimator is read-only over the measurement stack.
%      Running the same seed with the gate on and off must give bit-identical position,
%      clock and NIS. If this fails, the accumulator is perturbing the RNG or the rows.
%
%   T4 THE COMBINATION IS ACTUALLY GEOMETRY-FREE. An algebraic check on synthetic rows: a
%      metre-class change in range, receiver clock and ionosphere must leave MW unmoved,
%      and the wide-lane phase combination must annihilate a wind-up term exactly.
%
% Runs a 60 s arc, which is enough for T1-T3. T4 needs no simulation at all.
%
% EVERYTHING LIVES IN LOCAL FUNCTIONS ON PURPOSE. run_all_tests executes each test with
% evalin('base', name), so every variable a test script assigns lands in the shared base
% workspace and stays there for the next 300-odd tests. This file therefore assigns nothing
% at script level -- names like c, f1, fields and off would otherwise shadow builtins and
% leak across the suite, which is exactly the order-contamination that makes a suite FAIL
% line a lead rather than a verdict.

i_mwMain();


% =====================================================================================
function i_mwMain()
fprintf('== test_melbourne_wubbena_single_asset ==\n');

thisDir = fileparts(mfilename('fullpath'));
root    = fileparts(thisDir);
addpath(root); addpath(fullfile(root,'config')); addpath(fullfile(root,'config','internal'));
addpath(fullfile(root,'tests','regression'));

nFail = 0;
DUR_S = 60;

% ---------------------------------------------------------------------------------
% T4 first: pure algebra, no simulation, so a failure here is unambiguous.
% ---------------------------------------------------------------------------------
c    = 299792458;
f1   = 1575.42e6;  f2 = 1227.60e6;
lam1 = c/f1;       lam2 = c/f2;
lamWL = c/(f1-f2);
mw = @(L1,L2,P1,P2) (f1*L1 - f2*L2)/(f1-f2) - (f1*P1 + f2*P2)/(f1+f2);

N1 = 137; N2 = -412;
rho = 3.8e7; brx = 12.34; trop = 2.7; ionoL1 = 5.5;    % L1-equivalent slant delay
r2  = (f1/f2)^2;
buildL = @(rho_,brx_,I_) deal(rho_ + brx_ + trop - I_    + lam1*N1, ...
                              rho_ + brx_ + trop - I_*r2 + lam2*N2);
buildP = @(rho_,brx_,I_) deal(rho_ + brx_ + trop + I_, ...
                              rho_ + brx_ + trop + I_*r2);

[L1a,L2a] = buildL(rho, brx, ionoL1);
[P1a,P2a] = buildP(rho, brx, ionoL1);
mwA = mw(L1a,L2a,P1a,P2a);

% Move range by 1 km, the receiver clock by 300 m and the ionosphere by 4 m. MW must not move.
[L1b,L2b] = buildL(rho+1000, brx+300, ionoL1+4);
[P1b,P2b] = buildP(rho+1000, brx+300, ionoL1+4);
mwB = mw(L1b,L2b,P1b,P2b);

if abs(mwA - mwB) > 1e-6
    fprintf('  T4 FAIL: MW moved by %.3e m under a range/clock/iono change (must be 0).\n', ...
        abs(mwA-mwB)); nFail = nFail + 1;
else
    fprintf('  T4a PASS: MW is geometry-, clock- and ionosphere-free (moved %.2e m).\n', ...
        abs(mwA-mwB));
end
% ...and it recovers lam_WL * (N1 - N2).
nwlErr = abs(mwA/lamWL - (N1 - N2));
if nwlErr > 1e-6
    fprintf('  T4 FAIL: MW/lam_WL = %.6f, expected N1-N2 = %d.\n', mwA/lamWL, N1-N2);
    nFail = nFail + 1;
else
    fprintf('  T4b PASS: MW/lam_WL recovers N1-N2 = %d exactly (err %.2e cyc).\n', ...
        N1-N2, nwlErr);
end
% Phase wind-up: identical CYCLES on both bands, so lam_j*w in metres. The wide-lane phase
% combination must annihilate it because f1*lam1 = f2*lam2 = c.
w = 0.37;
leak = (f1*lam1*w - f2*lam2*w)/(f1-f2);
if abs(leak) > 1e-9
    fprintf('  T4 FAIL: wind-up leaks %.3e m into the wide lane (must cancel).\n', abs(leak));
    nFail = nFail + 1;
else
    fprintf('  T4c PASS: phase wind-up cancels exactly in the wide lane (leak %.2e m).\n', ...
        abs(leak));
end

% ---------------------------------------------------------------------------------
% T1 / T2 / T3: two runs of the same fixture, gate off then gate on.
% ---------------------------------------------------------------------------------
runOne = @(enable) i_runFixture(DUR_S, enable);

fprintf('  running fixture with the gate OFF ...\n');
off = runOne(false);
fprintf('  running fixture with the gate ON  ...\n');
on  = runOne(true);

% T1 -- gate off publishes nothing extra.
if off.hasTruthField
    fprintf(['  T1 FAIL: cpInfo.ambiguityTruth_m was published with the gate OFF. The ' ...
             'default path must allocate nothing.\n']); nFail = nFail + 1;
elseif off.mwEpochsUsed ~= 0 || ~strcmp(off.mwClassification, 'disabled')
    fprintf('  T1 FAIL: gate off but accumulator ran (%d epochs, classification %s).\n', ...
        off.mwEpochsUsed, off.mwClassification); nFail = nFail + 1;
else
    fprintf('  T1 PASS: gate off is inert (no truth field, 0 epochs, classification disabled).\n');
end

% T2 -- the toggle is live.
if on.mwEpochsUsed <= 0
    fprintf(['  T2 FAIL: gate ON but the accumulator consumed 0 epochs (classification ' ...
             '%s). A declared toggle that nothing reads is the failure this asserts ' ...
             'against.\n'], on.mwClassification); nFail = nFail + 1;
elseif ~on.hasTruthField
    fprintf('  T2 FAIL: gate ON but cpInfo.ambiguityTruth_m was not published.\n');
    nFail = nFail + 1;
else
    fprintf('  T2 PASS: gate on is LIVE (%d epochs used, %d arcs, classification %s).\n', ...
        on.mwEpochsUsed, on.mwArcsSeen, on.mwClassification);
end

% T3 -- no EKF quantity moves.
ekfFields = {'finalPositionRMS_m','finalClockBiasRMS_m','meanNIS','finalPostfitRMS_m','nStates'};
worst = 0; worstName = '';
for i = 1:numel(ekfFields)
    fn = ekfFields{i};
    if ~isfield(off.metrics, fn) || ~isfield(on.metrics, fn); continue; end
    a = off.metrics.(fn); b = on.metrics.(fn);
    if ~isnumeric(a) || ~isnumeric(b) || ~isscalar(a) || ~isscalar(b); continue; end
    d = abs(a - b);
    if d > worst; worst = d; worstName = fn; end
end
if worst > 0
    fprintf(['  T3 FAIL: the gate moved an EKF metric. Worst: %s by %.3e. The estimator ' ...
             'must be read-only over the measurement stack.\n'], worstName, worst);
    nFail = nFail + 1;
else
    fprintf('  T3 PASS: every EKF metric is bit-identical with the gate on and off.\n');
end

% Informational: the number the whole feature exists to produce.
if isfinite(on.mwSigmaMean)
    fprintf(['  [info] wide-lane float sigma %.4f cyc (%.4f m), mode %s, %d arcs, %d blocks, ' ...
             'shrinkage %.3f\n'], on.mwSigmaMean, on.mwSigmaMean*lamWL, on.mwMode, ...
             on.mwArcsUsed, on.mwBlocks, on.mwShrinkage);
    fprintf('  [info] a 1/sqrt(n) covariance would have been %.2fx too optimistic\n', ...
        1/max(on.mwOverstate, eps));
    fprintf('  [info] mean |fractional part| %.4f cyc  (the residual bias)\n', on.mwFrac);
    fprintf('  [info] wind-up leak into the wide lane: %.3e m\n', on.mwWindupLeak);
end

if nFail == 0
    fprintf('== test_melbourne_wubbena_single_asset PASSED ==\n');
else
    fprintf('== test_melbourne_wubbena_single_asset FAILED (%d) ==\n', nFail);
    error('test_melbourne_wubbena_single_asset:failed', '%d check(s) failed.', nFail);
end
end


% =====================================================================================
function r = i_runFixture(dur_s, enableMw)
% i_runFixture  One short single-asset run, gate on or off, with the report suppressed.
    cfg = goldenScenarioConfig(dur_s);
    cfg.diagnostics.melbourneWubbena.enable = enableMw;
    % A 60 s arc cannot supply 8 blocks of 300 s. Shorten the block so the covariance path
    % is actually EXERCISED by the test rather than short-circuited by the refusal branch.
    cfg.diagnostics.melbourneWubbena.blockLength_s      = 10;
    cfg.diagnostics.melbourneWubbena.minSamplesPerBlock = 5;
    cfg.diagnostics.melbourneWubbena.minBlocks          = 4;
    cfg.diagnostics.melbourneWubbena.minEpochsPerArc    = 20;

    sim = revgnss.ReverseGNSSSimulation(cfg);
    sim.initialize();
    sim.run();

    r = struct();
    r.hasTruthField = false;
    r.mwEpochsUsed  = 0;
    r.mwArcsSeen    = 0;
    r.mwArcsUsed    = 0;
    r.mwBlocks      = 0;
    r.mwShrinkage   = NaN;
    r.mwSigmaMean   = NaN;
    r.mwOverstate   = NaN;
    r.mwFrac        = NaN;
    r.mwWindupLeak  = NaN;
    r.mwMode        = '';
    r.mwClassification = 'absent';

    % Did the builder publish the truth register? Rebuild ONE epoch's measurements from the
    % finished sim, which is the only way to see cpInfo without persisting it.
    d = sim.simData.getData();
    if isfield(d, 'errStruct') && ~isempty(d.errStruct)
        es = d.errStruct(1);
        if isstruct(es) && isfield(es, 'carrierPhase')
            cp = es.carrierPhase;
            if isfield(cp, 'floatRows') && isstruct(cp.floatRows); cp = cp.floatRows; end
            r.hasTruthField = isfield(cp, 'ambiguityTruth_m');
        end
    end
    if ~r.hasTruthField
        % Fall back to asking the live accumulator, which sees the same field.
        r.hasTruthField = ~isempty(sim.mwEstimator_) && sim.mwEstimator_.truthRegisterAvailable;
    end

    if ~isempty(sim.mwEstimator_)
        mwOut = sim.mwEstimator_.finalize(cfg);
        r.mwEpochsUsed     = mwOut.nEpochsUsed;
        r.mwArcsSeen       = mwOut.nArcsSeen;
        r.mwArcsUsed       = mwOut.nArcsUsed;
        r.mwBlocks         = mwOut.nBlocksUsed;
        r.mwShrinkage      = mwOut.shrinkageIntensity;
        r.mwSigmaMean      = mwOut.wideLaneFloatSigmaMean_cyc;
        r.mwOverstate      = mwOut.whiteOverstatementFactor;
        r.mwFrac           = mwOut.meanAbsFractionalPart_cyc;
        r.mwWindupLeak     = mwOut.windupLeakMax_m;
        r.mwMode           = mwOut.mode;
        r.mwClassification = mwOut.classification;
    end

    % The EKF quantities that must not move. Taken straight off the store rather than
    % through ReportRunner, so this comparison does not depend on the report path.
    r.metrics = struct();
    r.metrics.nStates = numel(sim.ekf.x);
    posErr = nan(sim.nEpochs, 1);
    clkErr = nan(sim.nEpochs, 1);
    nis    = nan(sim.nEpochs, 1);
    if isfield(d, 'posErrNorm_m') && ~isempty(d.posErrNorm_m)
        posErr = d.posErrNorm_m(:);
    end
    if isfield(d, 'NIS') && ~isempty(d.NIS); nis = d.NIS(:); end
    if isfield(d, 'clockBiasErr_m') && ~isempty(d.clockBiasErr_m)
        clkErr = d.clockBiasErr_m(:);
    end
    r.metrics.finalPositionRMS_m  = sqrt(mean(posErr(isfinite(posErr)).^2));
    r.metrics.finalClockBiasRMS_m = sqrt(mean(clkErr(isfinite(clkErr)).^2));
    r.metrics.meanNIS             = mean(nis(isfinite(nis)));
    r.metrics.finalPostfitRMS_m   = NaN;
end
