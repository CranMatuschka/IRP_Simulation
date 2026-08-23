% test_ground_orientation_estimator_contract  The properties the ground-referenced orientation
% stages must hold regardless of which run they are pointed at
% (docs/ground_referenced_orientation_execution_plan.md, acceptance tests T3, T4, T5, T9, T10).
%
% These are all cheap: none of them runs a simulation. They exercise the estimator classes
% directly on synthetic geometry, or read the source, which is what makes them suitable for
% run_all_tests. The expensive end-to-end assertions live in test_golden_ground_orientation.
%
% WHAT IS BEING PROTECTED, IN ORDER OF HOW BADLY IT WOULD HURT TO LOSE IT:
%   T9  no estimator path reads a truth-derived quantity. This is the one that decides whether
%       the whole result is defensible; a truth-set prior or a truth-gated guard invalidates
%       every number downstream of it.
%   T3  the observable and the prediction are referenced to the SAME point. An asymmetry here is
%       baseline-linear and therefore aliases onto rotation instead of averaging away.
%   T5  a stage refuses when its estimate is not significant, rather than applying it.
%   T4  the observable shape subspace is measured and reported, not assumed.
%   T10 a disabled gate is absent, not merely harmless.

fprintf('== test_ground_orientation_estimator_contract ==\n');

thisDir = fileparts(mfilename('fullpath'));
root    = fileparts(thisDir);
addpath(root); addpath(fullfile(root,'config')); addpath(fullfile(root,'config','internal'));

%% ---- T9: no truth in any estimator path ------------------------------------------------
% The two named leaks were rel.shapeErrSolved_m (computed against truthK) being used as a
% prior weight in the joint solver and as the guard input in the 3-parameter solver. Grep for
% the pattern rather than for the string, so a rename does not silently retire the test.
estimatorFiles = {'+revgnss/JointGeometrySolver.m', ...
                  '+revgnss/GroundDifferencedRotationSolver.m'};
truthTokens = {'shapeErrSolved_m', 'baselineErrSolved_m', 'truthK', 'truthTraj'};
for i = 1:numel(estimatorFiles)
    txt = fileread(fullfile(root, estimatorFiles{i}));
    lines = strsplit(txt, newline);
    for L = 1:numel(lines)
        s = strtrim(lines{L});
        if isempty(s) || startsWith(s, '%'); continue; end     % comments may NAME the defect
        for t = 1:numel(truthTokens)
            assert(~contains(s, truthTokens{t}), ...
                ['T9 FAILED: %s:%d reads the truth-derived quantity "%s" in executable code.\n' ...
                 '  %s\n' ...
                 'An estimator may consume the observable and its own formal covariance. It may ' ...
                 'not consume a quantity computed against truth, even as a weight, and least of ' ...
                 'all as a guard that decides whether an estimate is used.'], ...
                estimatorFiles{i}, L, truthTokens{t}, s);
        end
    end
end
fprintf('  ok   T9: no truth-derived quantity in either estimator''s executable code\n');

%% ---- T9b: an unset prior is a hard failure, not a silent default -------------------------
cfg = struct();
cfg.multiAsset.jointGeometry.enable = true;
rel = struct('solvedPos', zeros(3,6,20), 'time_s', 0:19);      % no formalShapeSigma_m
outNoPrior = revgnss.JointGeometrySolver.solve(cfg, struct('asset',{{}}), rel);
assert(~outNoPrior.applicable, 'T9b FAILED: the joint solve ran without a prior');
fprintf('  ok   T9b: joint solve refuses without a prior (%s)\n', ...
    outNoPrior.reason(1:min(60,numel(outNoPrior.reason))));

%% ---- T10: both stages are inert when their gate is off ----------------------------------
cfgOff = struct();
cfgOff.multiAsset.jointGeometry.enable = false;
cfgOff.multiAsset.groundDifferencedRotation.enable = false;
cfgOff.multiAsset.groundCarrierProbe.enable = false;
relAny = struct('solvedPos', randn(3,6,20), 'time_s', 0:19, 'formalShapeSigma_m', 0.1);
j = revgnss.JointGeometrySolver.solve(cfgOff, struct(), relAny);
g = revgnss.GroundDifferencedRotationSolver.solve(cfgOff, struct(), relAny);
c = revgnss.GroundCarrierAmbiguityProbe.run(cfgOff, struct(), relAny);
assert(strcmp(j.reason,'gateOff') && isempty(j.solvedPos), 'T10 FAILED: joint stage not inert');
assert(strcmp(g.reason,'gateOff') && isempty(g.solvedPos), 'T10 FAILED: rotation stage not inert');
assert(strcmp(c.reason,'gateOff'), 'T10 FAILED: carrier probe not inert');
fprintf('  ok   T10: all three gates return gateOff and touch nothing\n');

%% ---- T3: the lever arm is applied on the prediction side, symmetrically ------------------
% predictedAntenna is the single point where a centre-of-mass geometry becomes the antenna
% geometry the observable is referenced to. Assert it actually moves the prediction, and that
% an observable built without a lever leaves it alone.
N = 6; nEp = 4;
Pk = 1000*randn(3,N);
lever = repmat([0.8;0.2;0.3], 1, N, nEp);
obsWith = struct('leverPred_ecef', lever);
obsNone = struct('leverPred_ecef', []);
A1 = revgnss.GroundDifferencedRotationSolver.predictedAntenna(obsWith, Pk, 2);
A0 = revgnss.GroundDifferencedRotationSolver.predictedAntenna(obsNone, Pk, 2);
assert(norm(A1(:) - Pk(:)) > 0.5, 'T3 FAILED: predictedAntenna did not apply the lever arm');
assert(isequal(A0, Pk), 'T3 FAILED: predictedAntenna moved a lever-free prediction');
assert(max(abs(vecnorm(A1-Pk,2,1) - norm([0.8;0.2;0.3]))) < 1e-9, ...
    'T3 FAILED: the applied offset is not the configured lever arm');
fprintf('  ok   T3: predictedAntenna applies exactly the configured lever, or nothing\n');

% And that every consumer of the observable goes through it -- an added consumer that indexes
% towerPos directly would reintroduce the asymmetry silently.
consumers = {'+revgnss/JointGeometrySolver.m', ...
             '+revgnss/GroundDifferencedRotationSolver.m', ...
             '+revgnss/GroundCarrierAmbiguityProbe.m'};
for i = 1:numel(consumers)
    txt = fileread(fullfile(root, consumers{i}));
    assert(contains(txt, 'predictedAntenna'), ...
        'T3 FAILED: %s forms a prediction without going through predictedAntenna', consumers{i});
end
fprintf('  ok   T3: all three consumers predict at the antenna phase centre\n');

%% ---- T4/T5: the joint solve reports its rank and refuses an insignificant step -----------
% A rigid formation, a tiny arc, and an observable the solver cannot see: the acceptance guard
% must decline and the geometry must come back untouched.
cfgJ = struct();
cfgJ.multiAsset.jointGeometry.enable = true;
cfgJ.multiAsset.jointGeometry.shapePriorSigma_m = 0.5;
relJ = struct('solvedPos', repmat(1000*randn(3,6), 1, 1, 30), 'time_s', 0:29);
outJ = revgnss.JointGeometrySolver.solve(cfgJ, struct('asset',{{}}), relJ);
assert(~outJ.accepted, 'T5 FAILED: the joint solve accepted a step it could not have measured');
assert(isfield(outJ,'observableShapeDof'), 'T4 FAILED: observableShapeDof is not reported');
assert(isfield(outJ,'separationPenaltyFree'), ...
    'T4 FAILED: the shape-free separation penalty is not reported');
fprintf('  ok   T4/T5: rank and separation penalty reported; insignificant step refused\n');

%% ---- C1b: a rotation may NEVER be applied without its shape partner ----------------------
% THE INVARIANT THIS PROTECTS, and the measurement that forced it. At N = 4 over 300 s the joint
% solve returned a 31 m shape step and an 8.66 deg rotation whose formal sigma was 0.21 deg. The
% rotation guard passed by 1260 % (SNR 40.8) while the shape guard failed by 1683 %. Treating the
% two as independent switches applied the rotation alone and moved the geometry by 171 m.
%
% The rotation was never a standalone estimate: it was the partner of a shape step the estimator
% itself rejects, and the pair only fitted the data together. There is also no safe fallback --
% a rotation-only solve IS the 3-parameter solver, measured to leak at 0.30 deg per metre.
truthTable = { ...
    % rotationPassed, shapePassed, nDof, expectShape, expectRotation
      true,  true,  6, true,  true  ; ...   % both fine
      true,  false, 6, false, false ; ...   % THE FAILURE CASE: rotation must not survive alone
      false, true,  6, true,  false ; ...   % the Phase F cascade branch: shape only
      false, false, 6, false, false ; ...   % nothing
      true,  true,  0, false, false };      % no observable shape DOF -> nothing is meaningful
for r = 1:size(truthTable,1)
    [aS, aR] = revgnss.JointGeometrySolver.acceptance( ...
        truthTable{r,1}, truthTable{r,2}, truthTable{r,3});
    assert(aS == truthTable{r,4} && aR == truthTable{r,5}, ...
        ['C1b FAILED, row %d (rotationPassed=%d shapePassed=%d dof=%d): got shape=%d ' ...
         'rotation=%d, expected shape=%d rotation=%d'], r, truthTable{r,1}, ...
        truthTable{r,2}, truthTable{r,3}, aS, aR, truthTable{r,4}, truthTable{r,5});
    assert(~(aR && ~aS), ...
        'C1b FAILED, row %d: the rotation was accepted without its shape partner', r);
end
fprintf('  ok   C1b: rotation is never accepted without its shape (5-row truth table)\n');

%% ---- G2: the rotation lever is sqrt(2/3)*R_rms, not the bare radius ----------------------
b = revgnss.OrientationCoherenceBudget.fromRotation(1e-4, 2102.8, 20, [2.1e9 1.2e9 400e6]);
assert(b.available, 'G2 FAILED: the coherence budget did not compute');
assert(abs(b.rotationLever_m - sqrt(2/3)*2102.8) < 1e-6, ...
    'G2 FAILED: lever %.4f m, expected %.4f m', b.rotationLever_m, sqrt(2/3)*2102.8);
% PREDICTED-VS-MEASURED REGISTER. The execution plan quotes sqrt(2/3)*2102.8 = 1705.7 m. It is
% 1716.9 m: the plan's own arithmetic is 0.65 % low. The FORMULA is what is asserted here,
% because it is the thing that can be derived; the quoted value is corrected in
% docs/ground_referenced_orientation_execution_plan.md rather than encoded as a target.
assert(abs(b.rotationLever_m - 1716.9) < 0.5, ...
    'G2 FAILED: run22 multiRingHelix lever should be 1716.9 m, got %.1f m', b.rotationLever_m);
% The expected coherent gain can never fall below the incoherent floor of -10*log10(N).
floorDb = -10*log10(20);
assert(all(b.gainLoss_dB >= floorDb - 1e-9), ...
    'G2 FAILED: expected gain below the incoherent floor, which no array can do');
fprintf('  ok   G2: lever = sqrt(2/3)*R_rms = %.1f m; gain bounded by the %.2f dB floor\n', ...
    b.rotationLever_m, floorDb);

%% ---- G5: array size cancels in the mispointing flowdown ----------------------------------
% mispointing in beamwidths = 2*sigma_abs/(lambda*sqrt(N)): a formation twice the size has half
% the angular error and half the beamwidth, so the ratio is unchanged. Check it explicitly,
% because "make the array bigger" is the intuitive and wrong remedy.
sigmaAbs = 2.6;                      % per-satellite independent error [m]
mp = @(R) (sigmaAbs/sqrt(6)/R) / (revgnss.Constants.SPEED_OF_LIGHT_MPS/2.1e9/(2*R));
assert(abs(mp(1000) - mp(4000)) < 1e-9, ...
    'G5 FAILED: mispointing in beamwidths depends on array size; it must not');
fprintf('  ok   G5: mispointing in beamwidths is independent of array size (%.2f bw)\n', mp(1000));

fprintf('test_ground_orientation_estimator_contract PASSED\n');
