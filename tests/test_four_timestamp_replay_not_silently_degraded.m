% test_four_timestamp_replay_not_silently_degraded
%
% WHY THIS TEST EXISTS. revgnss.SwarmRelativeSolver.fourTimestampObservables_ has FIVE
% returns that hand back an empty observable plus a reason, and the callers then fall back
% to the SYNTHETIC observable and carry on. There is no error() anywhere in that file. Two
% of the five are self-validation failures -- a sign check and a metre-level range check --
% so the code can DETECT that it got the physics wrong and still downgrade silently.
%
% That is not hypothetical. Commit 889dcf6: revgnss.TruthEndpointReplayClock lacked
% getOscillatorDriftMetersPerSecond, which ReciprocalEndpointTruthProvider.spacecraft calls
% on the proper-time path. It threw "Unrecognized method" for EVERY pair and EVERY epoch,
% the catch swallowed it, and the federated relative layer ran on the synthetic observable
% throughout -- "The real four-timestamp physics had never once run." The run honestly
% recorded shapeObservationSource = 'syntheticTwoWayISL' the whole time and nobody read it.
%
% WHY THE EXISTING TESTS DID NOT CATCH IT.
%   - tests/test_swarm_two_way_isl_gating.m:37 asserts the source string equals
%     'syntheticTwoWayISL'. That is correct for ITS fixture (which supplies no truthVelTraj,
%     so the replay is legitimately unusable) but it pins the DEGRADED value, so it stays
%     green even when the real chain is broken for every input.
%   - tests/regression/run_swarm_relative_regression.m digests only numeric fields -- no
%     source string, no reason -- and is not collected by tests/run_all_tests.m, which globs
%     tests/test_*.m only. Its baseline was captured while the path was falling back.
%   - The numbers barely move either way (889dcf6 measured shape 0.0457 m with and without,
%     relative clock 0.0218 -> 0.0239 m), so a bit-exact numeric digest is a poor proxy gate
%     for "did the real physics run".
%
% WHAT THIS TEST PINS. On a REAL federated run of the shipped multi-asset baseline, the
% relative layer must reach the four-timestamp observable and say so. It asserts the
% POSITIVE label rather than the absence of an exception, because the failure mode is a
% successful run carrying a quietly wrong provenance.
%
% It deliberately runs the real pipeline (ReportRunner.runFederatedEstimation +
% SwarmRelativeSolver.solve) rather than a synthetic fixture: the defect it guards was a
% MISSING METHOD on a replay object, which only a real payload exercises. Report and PDF
% writing are bypassed, so the cost is the simulation alone.

fprintf('=== test_four_timestamp_replay_not_silently_degraded ===\n');

thisDir = fileparts(mfilename('fullpath'));
root    = fileparts(thisDir);
addpath(root, fullfile(root,'config'), fullfile(root,'config','internal'));

DURATION_S = 120;   % short arc: the label is what is under test, not the accuracy

cfg = resolveSimulationConfig('golden_baseline_multi.json');
cfg.simulation.duration_s = DURATION_S;
cfg = revgnss.ConfigFactory.finalizeConfig(cfg);

% Precondition: this scenario must actually run the relative layer. Without this the
% assertions below would pass vacuously the day someone turns the gate off -- the source
% would read 'disabled' and T2 would fail for a misleading reason, or a future edit that
% relaxes T2 would silently certify nothing. This is the shape gate solve() itself reads
% (SwarmRelativeSolver.solve: multiAsset.twoWayISL.enable).
assert(isfield(cfg,'multiAsset') && isfield(cfg.multiAsset,'twoWayISL') && ...
       isfield(cfg.multiAsset.twoWayISL,'enable') && cfg.multiAsset.twoWayISL.enable, ...
    ['T0 FAILED: multiAsset.twoWayISL.enable is not set in the resolved ' ...
     'golden_baseline_multi.json, so the relative layer would report ''disabled'' and this ' ...
     'test would certify nothing.']);

results = revgnss.ReportRunner.runFederatedEstimation(cfg);
rel     = revgnss.SwarmRelativeSolver.solve(cfg, results);

% ---- T1: the solve actually ran ------------------------------------------------------
% NOTE: SwarmRelativeSolver.solve does NOT return a 'reason' field -- the 'reason' that
% appears in the *_relerror.mat is written downstream. 'applicable' is the solver's own
% statement that it produced a solution, so that is what is asserted here.
assert(isfield(rel,'applicable') && rel.applicable, ...
    'T1 FAILED: relative solve returned applicable=false; there is no solution to check.');

% ---- T2: the SHAPE observable is the four-timestamp two-way range, not the fallback --
src = i_str(rel,'shapeObservationSource');
assert(strcmp(src,'fourTimestampTwoWayRange'), ...
    ['T2 FAILED: shapeObservationSource = ''%s'', expected ''fourTimestampTwoWayRange''.\n' ...
     'The four-timestamp replay fell back to the synthetic observable. Fallback reason: ''%s''.\n' ...
     'This is the 889dcf6 failure mode: the run succeeds and the physics silently did not.'], ...
    src, i_str(rel,'shapeFallbackReason'));

% ---- T3: no fallback reason was recorded ---------------------------------------------
assert(isempty(i_str(rel,'shapeFallbackReason')), ...
    'T3 FAILED: shapeFallbackReason is non-empty (''%s'') while the source claims the real chain.', ...
    i_str(rel,'shapeFallbackReason'));

% ---- T4: the relative-clock observable, when its gate is on, must match --------------
% relClockGateOn = 0 in the shipped baseline, so this is conditional by design rather than
% asserted unconditionally -- an unconditional assert would fail for the wrong reason.
if isfield(rel,'relClockGateOn') && ~isempty(rel.relClockGateOn) && rel.relClockGateOn
    csrc = i_str(rel,'relClockObservableSource');
    assert(strcmp(csrc,'fourTimestampClockDifference'), ...
        ['T4 FAILED: relClockObservableSource = ''%s'', expected ' ...
         '''fourTimestampClockDifference''. Fallback reason: ''%s''.'], ...
        csrc, i_str(rel,'relClockFallbackReason'));
    assert(isempty(i_str(rel,'relClockFallbackReason')), ...
        'T4 FAILED: relClockFallbackReason is non-empty (''%s'').', ...
        i_str(rel,'relClockFallbackReason'));
    fprintf('  T4 relative-clock observable: %s\n', csrc);
else
    fprintf('  T4 skipped: relClockGateOn = 0 in this scenario (shape path still asserted).\n');
end

fprintf('  T1 applicable             : true\n');
fprintf('  T2 shapeObservationSource : %s\n', src);
fprintf('  T3 shapeFallbackReason    : <empty>\n');
if isfield(rel,'shapeErrSolved_m') && ~isempty(rel.shapeErrSolved_m)
    e = rel.shapeErrSolved_m(:); e = e(~isnan(e));
    if ~isempty(e); fprintf('  (context) shape solved    : %.6f m mean\n', mean(e)); end
end
fprintf('=== test_four_timestamp_replay_not_silently_degraded: ALL PASS ===\n');

function v = i_str(s, f)
% i_str  Field as char, '' when absent or empty. Never errors, so the assertion messages
% above can quote a field that may not exist without masking the real failure.
    v = '';
    if isstruct(s) && isfield(s, f) && ~isempty(s.(f))
        try; v = char(string(s.(f))); catch; v = '<unprintable>'; end
    end
end
