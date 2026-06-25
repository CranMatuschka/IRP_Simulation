function results = test_stage44_if_consistency_bias_budget()
% test_stage44_if_consistency_bias_budget  Stage 44 SignalConfigResolver and IF bias budget tests.
%
% T1: SignalConfigResolver detects L2 from twoFrequency.enable=true (no signals.enabled).
% T2: SignalConfigResolver detects L2 from l2EkfRows.enable=true.
% T3: IFCombinationDiagnostics.assess gives diagnostic-if-available when twoFrequency.enable=true.
% T4: IonosphereFreeBiasBudget residual = alpha*(tL1-mL1)+beta*(tL2-mL2); noise amp > 1.
% T5: No false claims (ekfIfRows/integerFixing/biasProducts all false; no PPP/fixed/operational).

results = struct('name', {}, 'passed', {}, 'message', {});
results = addTest(results, 'T1_resolver_twoFrequency', @t1_resolver_twoFrequency);
results = addTest(results, 'T2_resolver_l2EkfRows',    @t2_resolver_l2EkfRows);
results = addTest(results, 'T3_if_assess_twoFrequency',@t3_if_assess_twoFrequency);
results = addTest(results, 'T4_bias_residual_formula', @t4_bias_residual_formula);
results = addTest(results, 'T5_no_false_claims',       @t5_no_false_claims);
end

% -----------------------------------------------------------------------

function t1_resolver_twoFrequency()
% Resolver must detect L2 when twoFrequency.enable=true and signals.enabled is absent.
cfg = struct();
cfg.signals.twoFrequency.enable = true;

r = revgnss.SignalConfigResolver.resolve(cfg);
assert(r.l2Enabled,         'T1: l2Enabled must be true');
assert(r.twoFrequencyEnabled,'T1: twoFrequencyEnabled must be true');
assert(r.l1Enabled,         'T1: l1Enabled must always be true');
assert(ismember('L1', r.enabledSignalIds), 'T1: enabledSignalIds must contain L1');
assert(ismember('L2', r.enabledSignalIds), 'T1: enabledSignalIds must contain L2');
assert(~isempty(r.sourceFields),           'T1: sourceFields must be non-empty');
assert(any(contains(r.sourceFields, 'twoFrequency')), ...
    'T1: sourceFields must name twoFrequency');
assert(revgnss.SignalConfigResolver.hasL2(cfg), 'T1: hasL2 must return true');
end

function t2_resolver_l2EkfRows()
% Resolver must detect L2 from l2EkfRows.enable=true even without twoFrequency.
cfg = struct();
cfg.measurements.carrier.l2EkfRows.enable = true;

r = revgnss.SignalConfigResolver.resolve(cfg);
assert(r.l2Enabled,          'T2: l2Enabled must be true');
assert(r.l2CarrierRowsEnabled,'T2: l2CarrierRowsEnabled must be true');
assert(~r.twoFrequencyEnabled,'T2: twoFrequencyEnabled should be false');
assert(any(contains(r.sourceFields, 'l2EkfRows')), ...
    'T2: sourceFields must name l2EkfRows');
end

function t3_if_assess_twoFrequency()
% Stage 43 assess must return diagnostic-if-available when twoFrequency.enable=true
% (uses SignalConfigResolver internally after Stage 44 fix).
cfg = struct();
cfg.signals.twoFrequency.enable = true;

s = revgnss.IonosphereFreeCombinationDiagnostics.assess([], cfg);
assert(s.l2Enabled,                           'T3: l2Enabled must be true');
assert(strcmp(s.classification,'diagnostic-if-available'), ...
    sprintf('T3: expected diagnostic-if-available, got %s', s.classification));
assert(isfinite(s.alpha) && s.alpha > 1,      'T3: alpha must be > 1');
assert(isfinite(s.beta)  && s.beta  < 0,      'T3: beta must be < 0');
assert(abs(s.codeIonoResidualCheck_m) < 1e-9, 'T3: code iono residual must be < 1e-9 m');
end

function t4_bias_residual_formula()
% IF residual = alpha*(tL1-mL1) + beta*(tL2-mL2) matches IonosphereFreeBiasBudget.
cfg = struct();
cfg.signals.twoFrequency.enable = true;
tL1 = 2.0;  tL2 = 3.0;
mL1 = 1.5;  mL2 = 2.5;
cfg.biases.interFrequency.code.truth.L1_m = tL1;
cfg.biases.interFrequency.code.truth.L2_m = tL2;
cfg.biases.interFrequency.code.model.L1_m = mL1;
cfg.biases.interFrequency.code.model.L2_m = mL2;

s = revgnss.IonosphereFreeBiasBudget.assess(cfg);
assert(s.l2Enabled, 'T4: l2Enabled must be true');

co = revgnss.IonosphereFreeCombinationDiagnostics.coefficients('L1','L2');
expectedResidual = co.alpha*(tL1-mL1) + co.beta*(tL2-mL2);
assert(abs(s.codeIfResidualBias_m - expectedResidual) < 1e-12, ...
    sprintf('T4: code IF residual mismatch: got %.6f, expected %.6f', ...
    s.codeIfResidualBias_m, expectedResidual));
assert(s.equalSigmaNoiseAmplification > 1, ...
    'T4: noise amplification must be > 1');
assert(s.equalSigmaNoiseAmplification > 2, ...
    sprintf('T4: expected amplification > 2, got %.4f', s.equalSigmaNoiseAmplification));
end

function t5_no_false_claims()
% Budget struct must carry all false flags; classification must not claim PPP/integer etc.
cfg = struct();
cfg.signals.twoFrequency.enable = true;

s = revgnss.IonosphereFreeBiasBudget.assess(cfg);
assert(~s.ekfIfRowsImplemented,     'T5: ekfIfRowsImplemented must be false');
assert(~s.integerFixingImplemented,  'T5: integerFixingImplemented must be false');
assert(~s.biasProductsAvailable,     'T5: biasProductsAvailable must be false');
forbidden = {'ppp','fixed','precise','operational','calibrated','integer-ready','integer_ready'};
for k = 1:numel(forbidden)
    assert(isempty(strfind(lower(s.classification), forbidden{k})), ...
        sprintf('T5: classification must not contain "%s"; got: %s', forbidden{k}, s.classification));
end
% Also check Stage 43 no-false-claims
s43 = revgnss.IonosphereFreeCombinationDiagnostics.assess([], cfg);
assert(~s43.ionosphereFreeCombinationImplementedInEkf, 'T5: IF not in EKF');
assert(~s43.integerFixingImplemented,                  'T5: no integer fixing');
for k = 1:numel(forbidden)
    assert(isempty(strfind(lower(s43.classification), forbidden{k})), ...
        sprintf('T5: s43.classification must not contain "%s"; got: %s', forbidden{k}, s43.classification));
end
end

% -----------------------------------------------------------------------

function results = addTest(results, name, fn)
try
    fn();
    results(end+1) = struct('name', name, 'passed', true, 'message', '');
catch ex
    results(end+1) = struct('name', name, 'passed', false, 'message', ex.message);
end
end
