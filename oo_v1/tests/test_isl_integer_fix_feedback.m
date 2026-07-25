% test_isl_integer_fix_feedback
% Phase 3-4b (feature/ISL-LAMBDA): injecting the DIFFERENCED integer fix into the filter.
%
% Route B fixes dN = N_i - N_ref, so the feedback is a LINEAR CONSTRAINT on several
% ambiguity states at once, not a per-state pseudo-measurement:
%     z = lambda*dN_fixed,  h = D*x(islAmb),  H(:,islAmb) = D
% Routed through the Joseph-form update(), which makes it the conditional mixed-integer
% update (Teunissen 1995): the cross-covariance carries the correction into position and
% clock, and covariance PD is preserved by the existing machinery.
%
% Proves:
%   T1  the constraint is applied and TIGHTENS the ambiguity covariance
%   T2  the differenced combination actually MOVES to lambda*dN
%   T3  the correction propagates through cross-covariance to the other states
%   T4  DOUBLE-COUNT GUARD: the constraint is deterministic, so re-applying it keeps
%       shrinking P. This is the correctness reason the caller must hold the fix per arc.
%   T5  malformed input is refused, not silently applied

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir, '..');
addpath(rootDir); addpath(fullfile(rootDir, 'config'));

fprintf('=== test_isl_integer_fix_feedback ===\n');

cfg = revgnss.ConfigFactory.defaultConfig();
cfg.plots.enable = false; cfg.report.enable = false;
cfg.scenario.nSpaceAssets = 4;
cfg.measurements.isl.enable = true;
cfg.measurements.isl.transmitters = 'all';
cfg.measurements.isl.receiverAssetIndex = 1;
cfg.measurements.isl.code.enable = true;
cfg.measurements.isl.carrier.enable = true;
cfg.measurements.isl.carrier.ambiguity.enable = true;
cfg.measurements.isl.carrier.ambiguity.initialSigma_m = 100;

[~, ~, ekf] = revgnss.ScenarioFactory.build(cfg);
sm  = ekf.stateMap;
idx = sm.islAmbiguityIdx(:)';
idx = idx(idx > 0);
assert(numel(idx) >= 2, 'setup FAILED: need >= 2 ISL ambiguity states, got %d', numel(idx));
nL  = numel(idx);
lam = revgnss.SignalDefinition.get('L1').wavelength_m;
D   = revgnss.integer.IslDoubleDifference.transform(nL, 1);

% Give the ambiguities a realistic converged covariance + a cross-covariance to b_rx,
% so T3 can show the correction propagating.
for k = 1:nL; ekf.P(idx(k), idx(k)) = 0.05^2; end
ekf.P(idx(1), sm.b_rx_idx) = 0.01; ekf.P(sm.b_rx_idx, idx(1)) = 0.01;
ekf.x(idx) = lam * [10; 20; 30];                       % float sitting exactly on integers
% Shift ONE difference by a cycle. NOT [1;-1]: with a symmetric cross-covariance that
% innovation direction is exactly orthogonal to K(b_rx,:), so the state correction
% cancels to precisely zero and T3 would fail on a degenerate test setup rather than a
% real defect (observed while writing this test).
dNfix = D * [10; 20; 30] + [1; 0];

% ----------------------------------------------------------------
% T1: applied, and the ambiguity covariance tightens
% ----------------------------------------------------------------
fprintf('  T1: constraint applied and tightens P(islAmb) ...\n');

bRxBefore = ekf.x(sm.b_rx_idx);
info1 = ekf.applyIslDifferencedAmbiguityFix(D, dNfix, lam, 1e-3);
assert(info1.applied, 'T1 FAILED: not applied (%s)', info1.warning);
assert(info1.nConstraints == nL-1, 'T1 FAILED: %d constraints, expected %d', ...
    info1.nConstraints, nL-1);
assert(info1.traceAfter < info1.traceBefore, ...
    'T1 FAILED: trace(P) %.6g -> %.6g did not decrease', info1.traceBefore, info1.traceAfter);
fprintf('    %d constraints, trace(P_amb) %.4g -> %.4g: PASS\n', ...
    info1.nConstraints, info1.traceBefore, info1.traceAfter);

% ----------------------------------------------------------------
% T2: the differenced combination moves to lambda*dN
% ----------------------------------------------------------------
fprintf('  T2: differenced combination matches lambda*dN ...\n');

resid_t2 = max(abs(D * ekf.x(idx) - lam * dNfix));
assert(resid_t2 < 0.01, ...
    'T2 FAILED: |D*x - lambda*dN| = %.4g m, expected << 1 cm for a 1 mm constraint', resid_t2);
fprintf('    residual %.3e m: PASS\n', resid_t2);

% ----------------------------------------------------------------
% T3: the correction propagates to correlated states
% ----------------------------------------------------------------
fprintf('  T3: correction propagates through cross-covariance ...\n');

dbRx = abs(ekf.x(sm.b_rx_idx) - bRxBefore);
assert(dbRx > 0, ...
    ['T3 FAILED: b_rx did not move despite a nonzero P(amb,b_rx). The conditional ' ...
     'update must carry the ambiguity correction into correlated states.']);
fprintf('    b_rx moved %.4e m via P(amb,b_rx): PASS\n', dbRx);

% ----------------------------------------------------------------
% T4: DOUBLE-COUNT GUARD -- re-applying keeps shrinking P
% ----------------------------------------------------------------
fprintf('  T4: re-applying the SAME constraint shrinks P again (why it must be held) ...\n');

tr_before_t4 = trace(ekf.P(idx, idx));
for rep = 1:5
    ekf.applyIslDifferencedAmbiguityFix(D, dNfix, lam, 1e-3);
end
tr_after_t4 = trace(ekf.P(idx, idx));
assert(tr_after_t4 < tr_before_t4, ...
    ['T4 FAILED: repeated application did NOT shrink P further. If that were true the ' ...
     'hold would be unnecessary -- re-check the test, not the guard.']);
fprintf(['    trace %.4g -> %.4g after 5 re-applications: PASS\n' ...
         '      (deterministic constraint => caller MUST apply once per arc; ' ...
         'ReverseGNSSSimulation holds it)\n'], tr_before_t4, tr_after_t4);

% ----------------------------------------------------------------
% T5: malformed input refused
% ----------------------------------------------------------------
fprintf('  T5: malformed input refused, not silently applied ...\n');

badD = zeros(2, nL + 3);
i_bad1 = ekf.applyIslDifferencedAmbiguityFix(badD, [1;2], lam, 1e-3);
assert(~i_bad1.applied && contains(i_bad1.warning,'columns'), ...
    'T5 FAILED: wrong-width D was accepted');
i_bad2 = ekf.applyIslDifferencedAmbiguityFix(D, [1;2;3;4;5], lam, 1e-3);
assert(~i_bad2.applied, 'T5 FAILED: wrong-length dN was accepted');
fprintf('    bad D -> refused; bad dN -> refused: PASS\n');

fprintf('=== test_isl_integer_fix_feedback: ALL PASS ===\n');
