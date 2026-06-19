function results = test_stage45_code_iono_free_rows()
% test_stage45_code_iono_free_rows  Stage 45 guarded code IF EKF row tests.
%
% T1: Synthetic L1/L2 row combination matches alpha/beta formula; R_IF > R_L1, R_L2.
% T2: Mismatched H dimensions must throw — no silent mismatch.
% T3: CodeIonoFreeEkfDiagnostics carries all false flags; classification in allowed set.
% T4: With twoFrequency.enable=true + ionosphereFreeRows.enable=true, hasL2=true.

results = struct('name', {}, 'passed', {}, 'message', {});
results = addTest(results, 'T1_synthetic_combination',  @t1_synthetic_combination);
results = addTest(results, 'T2_dimension_guard',        @t2_dimension_guard);
results = addTest(results, 'T3_no_false_claims',        @t3_no_false_claims);
results = addTest(results, 'T4_config_compatibility',   @t4_config_compatibility);
end

% -----------------------------------------------------------------------

function t1_synthetic_combination()
nx    = 5;
cfg   = struct();
cfg.signals.twoFrequency.enable = true;
cfg.measurements.code.ionosphereFreeRows.useInEkf = true;

rowL1 = struct('z', 1234.5, 'h', 1234.0, 'H', ones(1,nx), 'R', 4.0, 'metadata', struct());
rowL2 = struct('z', 1234.3, 'h', 1233.8, 'H', ones(1,nx), 'R', 9.0, 'metadata', struct());

rowIF = revgnss.CodeIonoFreeRowBuilder.combineRows(rowL1, rowL2, cfg);

sigL1 = revgnss.SignalDefinition.get('L1');
sigL2 = revgnss.SignalDefinition.get('L2');
[alpha, beta] = revgnss.IonoFreeCombination.coefficients(sigL1.frequency_Hz, sigL2.frequency_Hz);

assert(abs(rowIF.z - (alpha*rowL1.z + beta*rowL2.z)) < 1e-9, 'T1: z_IF mismatch');
assert(abs(rowIF.h - (alpha*rowL1.h + beta*rowL2.h)) < 1e-9, 'T1: h_IF mismatch');
assert(norm(rowIF.H - (alpha*rowL1.H + beta*rowL2.H)) < 1e-9, 'T1: H_IF mismatch');

R_IF_expected = alpha^2 * rowL1.R + beta^2 * rowL2.R;
assert(abs(rowIF.R - R_IF_expected) < 1e-12, ...
    sprintf('T1: R_IF mismatch: got %.6f, expected %.6f', rowIF.R, R_IF_expected));
assert(rowIF.R > rowL1.R, 'T1: R_IF must exceed R_L1 (noise amplification)');
assert(rowIF.R > rowL2.R, 'T1: R_IF must exceed R_L2 (noise amplification)');
assert(strcmp(rowIF.metadata.rowType, 'codeIonoFree'), ...
    sprintf('T1: rowType must be codeIonoFree, got %s', rowIF.metadata.rowType));
assert(rowIF.alpha > 1, 'T1: alpha must be > 1');
assert(rowIF.beta  < 0, 'T1: beta must be < 0');
end

function t2_dimension_guard()
cfg   = struct();
cfg.signals.twoFrequency.enable = true;
rowL1 = struct('z', 1.0, 'h', 1.0, 'H', ones(1,5), 'R', 4.0, 'metadata', struct());
rowL2 = struct('z', 1.0, 'h', 1.0, 'H', ones(1,7), 'R', 9.0, 'metadata', struct());

threw = false;
try
    revgnss.CodeIonoFreeRowBuilder.combineRows(rowL1, rowL2, cfg);
catch
    threw = true;
end
assert(threw, 'T2: combineRows must throw on H dimension mismatch');
end

function t3_no_false_claims()
cfg = struct();
cfg.signals.twoFrequency.enable = true;
cfg.measurements.code.ionosphereFreeRows.enable = true;
cfg.measurements.code.ionosphereFreeRows.useInEkf = true;

% Synthetic summary with IF rows present
sm = struct('nTowers',5,'nReceivers',3,'totalCodeIonoFreeRows',15,'totalCodeRows',15);

s = revgnss.CodeIonoFreeEkfDiagnostics.assess(sm, cfg);
assert(~s.carrierIfRowsImplemented,        'T3: carrierIfRowsImplemented must be false');
assert(~s.integerFixingImplemented,         'T3: integerFixingImplemented must be false');
assert(~s.higherOrderIonosphereImplemented, 'T3: higherOrderIonosphereImplemented must be false');
assert(~s.calibratedBiasProductsAvailable,  'T3: calibratedBiasProductsAvailable must be false');

forbidden = {'ppp','fixed','precise','operational','integer-ready','integer_ready'};
for k = 1:numel(forbidden)
    assert(isempty(strfind(lower(s.classification), forbidden{k})), ...
        sprintf('T3: classification must not contain "%s"; got: %s', forbidden{k}, s.classification));
end

validClasses = {'disabled','requested-no-l2','requested-no-l2-code-rows', ...
    'requested-metadata-unavailable','active-code-if-ekf','diagnostic-only','inconsistent'};
assert(ismember(s.classification, validClasses), ...
    sprintf('T3: classification "%s" not in allowed set', s.classification));
end

function t4_config_compatibility()
cfg = struct();
cfg.signals.twoFrequency.enable = true;
cfg.measurements.code.ionosphereFreeRows.enable = true;
cfg.measurements.code.ionosphereFreeRows.useInEkf = true;

assert(revgnss.SignalConfigResolver.hasL2(cfg), 'T4: hasL2 must be true');

s = revgnss.CodeIonoFreeEkfDiagnostics.assess(struct(), cfg);
assert(s.l2Enabled, 'T4: l2Enabled must be true');
assert(s.requested, 'T4: requested must be true');
assert(s.usedInEkf, 'T4: usedInEkf must be true');
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
