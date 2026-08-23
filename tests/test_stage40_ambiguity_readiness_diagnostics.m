% test_stage40_ambiguity_readiness_diagnostics  Smoke tests for Stage 40.
%
% T1: no carrier/ambiguity -> classification unavailable or not-ready-no-ambiguity-states.
%     integerFixingImplemented=false. lambdaReady=false.
% T2: summary-estimated ambiguities -> ambiguityStateCount=12, source='summary-estimate'.
%     classification must not claim integer readiness.
% T3: known ambiguity validation enabled -> knownAmbiguityValidationEnabled=true.
%     integerFixingImplemented=false.

fprintf('test_stage40_ambiguity_readiness_diagnostics\n');

% --- T1: empty out/cfg -> unavailable or not-ready-no-ambiguity-states ---
s1 = revgnss.AmbiguityReadinessDiagnostics.assess(struct(), struct());
validT1 = {'unavailable', 'not-ready-no-ambiguity-states', 'not-ready-carrier-disabled'};
assert(ismember(s1.classification, validT1), ...
    sprintf('T1: expected not-ready/unavailable class, got ''%s''', s1.classification));
assert(~s1.integerFixingImplemented, 'T1: integerFixingImplemented must be false');
assert(~s1.lambdaReady,              'T1: lambdaReady must be false');
fprintf('T1 PASS: classification=''%s'', integerFixing=false, lambdaReady=false\n', s1.classification);

% --- T2: summary-estimated ambiguities ---
out2 = struct();
out2.summary.nTowers             = 4;
out2.summary.nReceivers          = 3;
out2.summary.totalCarrierRows    = 12;
out2.summary.totalDiffAttRows    = 6;
out2.summary.carrierUsedInEkf    = true;
out2.summary.carrierDiagnosticOnly = false;
out2.summary.maxEKFRows          = 30;

cfg2 = struct();
cfg2.measurements.carrierPhase.enable = true;
cfg2.measurements.carrierMode         = 'ekfFloat';
cfg2.estimation.ambiguityMode         = 'floatPerTowerReceiverSignal';

s2 = revgnss.AmbiguityReadinessDiagnostics.assess(out2, cfg2);
assert(isfinite(s2.ambiguityStateCount) && s2.ambiguityStateCount == 12, ...
    sprintf('T2: expected ambiguityStateCount=12, got %g', s2.ambiguityStateCount));
assert(strcmp(s2.ambiguityStateCountSource, 'summary-estimate'), ...
    sprintf('T2: expected source=''summary-estimate'', got ''%s''', s2.ambiguityStateCountSource));
intReadinessCls = {'integer-fixed','integer-ready','lambda-ready','fixed-ambiguity'};
for k = 1:numel(intReadinessCls)
    assert(~contains(lower(s2.classification), intReadinessCls{k}), ...
        sprintf('T2: classification must not claim integer readiness, got ''%s''', s2.classification));
end
assert(~s2.lambdaReady, 'T2: lambdaReady must be false');
assert(~s2.integerFixingImplemented, 'T2: integerFixingImplemented must be false');
fprintf('T2 PASS: ambiguityStateCount=12, source=''%s'', classification=''%s''\n', ...
    s2.ambiguityStateCountSource, s2.classification);

% --- T3: known ambiguity validation enabled ---
out3 = out2;
cfg3 = cfg2;
cfg3.estimator.runKnownAmbiguityValidation = true;

s3 = revgnss.AmbiguityReadinessDiagnostics.assess(out3, cfg3);
assert(s3.knownAmbiguityValidationEnabled, 'T3: knownAmbiguityValidationEnabled must be true');
assert(~s3.integerFixingImplemented, 'T3: integerFixingImplemented must be false');
validT3 = {'not-ready-summary-only','not-ready-no-covariance','not-ready-poor-conditioning', ...
           'validation-known-ambiguity-only','not-ready-no-ambiguity-states'};
assert(ismember(s3.classification, validT3), ...
    sprintf('T3: unexpected classification ''%s''', s3.classification));
fprintf('T3 PASS: knownAmbValEnabled=true, integerFixing=false, classification=''%s''\n', ...
    s3.classification);

fprintf('\ntest_stage40_ambiguity_readiness_diagnostics: all 3 tests passed.\n');
