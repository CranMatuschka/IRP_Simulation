function results = test_stage46_code_if_consistency_traceability()
% test_stage46_code_if_consistency_traceability  Stage 46 code IF EKF consistency tests.
%
% T1: Row count consistency check — nTowers=5, nReceivers=3, IF rows=15 → consistent.
% T2: H compatibility — no bias states → assumption-compatible; txBias → risk warning.
% T3: Explicit H combination via combineJacobians and combineRows hExplicitlyCombined.
% T4: No false claims — all false flags, classification not PPP/fixed/precise/operational.

results = struct('name', {}, 'passed', {}, 'message', {});
results = addTest(results, 'T1_row_count_consistency',  @t1_row_count_consistency);
results = addTest(results, 'T2_h_compatibility',        @t2_h_compatibility);
results = addTest(results, 'T3_explicit_h_combination', @t3_explicit_h_combination);
results = addTest(results, 'T4_no_false_claims',        @t4_no_false_claims);
end

% -----------------------------------------------------------------------

function t1_row_count_consistency()
cfg = struct();
cfg.signals.twoFrequency.enable = true;
cfg.measurements.code.ionosphereFreeRows.enable  = true;
cfg.measurements.code.ionosphereFreeRows.useInEkf = true;

sm = struct('nTowers',5,'nReceivers',3,'totalCodeIonoFreeRows',15,'totalCodeRows',15);
rc = revgnss.CodeIonoFreeConsistencyDiagnostics.checkRowCounts(sm, cfg);
assert(rc.nCodeL1Rows == 15, 'T1: nCodeL1Rows must be 15');
assert(rc.nCodeL2Rows == 15, 'T1: nCodeL2Rows must be 15');
assert(rc.nCodeIfRows == 15, 'T1: nCodeIfRows must be 15');
assert(rc.ifRowsPresent,     'T1: ifRowsPresent must be true');
assert(rc.consistent,        'T1: rowCountConsistent must be true');

% Also via full assess
s = revgnss.CodeIonoFreeConsistencyDiagnostics.assess(sm, cfg);
assert(s.rowCountConsistent, 'T1: assess rowCountConsistent must be true');
assert(s.nCodeL1Rows == 15, 'T1: assess nCodeL1Rows must be 15');
end

function t2_h_compatibility()
cfg = struct();
cfg.signals.twoFrequency.enable = true;
cfg.measurements.code.ionosphereFreeRows.enable  = true;
cfg.measurements.code.ionosphereFreeRows.useInEkf = true;

sm = struct('nTowers',5,'nReceivers',3,'totalCodeIonoFreeRows',15,'totalCodeRows',15);

% No bias states → assumption-compatible
hc = revgnss.CodeIonoFreeConsistencyDiagnostics.hCompatibility(cfg, sm);
assert(strcmp(hc.class, 'assumption-compatible'), ...
    sprintf('T2: expected assumption-compatible, got %s', hc.class));
assert(isempty(hc.warnings), 'T2: no warnings expected without bias states');

% With Tx code bias state active → unsafe or warning
cfg2 = cfg;
cfg2.estimator.estimateTxCodeBias = true;
hc2 = revgnss.CodeIonoFreeConsistencyDiagnostics.hCompatibility(cfg2, sm);
assert(strcmp(hc2.class, 'unsafe-bias-states-active'), ...
    sprintf('T2: expected unsafe-bias-states-active, got %s', hc2.class));
assert(~isempty(hc2.warnings), 'T2: warnings expected with active bias states');

% Full assess with bias states → classification reflects risk
s2 = revgnss.CodeIonoFreeConsistencyDiagnostics.assess(sm, cfg2);
assert(strcmp(s2.codeBiasStateRisk, 'medium-tx-code-bias-not-signal-specific-in-IF'), ...
    sprintf('T2: expected medium bias-state risk, got %s', s2.codeBiasStateRisk));
end

function t3_explicit_h_combination()
nx = 7;
H_L1 = ones(1,nx);
H_L2 = 2*ones(1,nx);

sigL1 = revgnss.SignalDefinition.get('L1');
sigL2 = revgnss.SignalDefinition.get('L2');
[alpha, beta] = revgnss.IonoFreeCombination.coefficients(sigL1.frequency_Hz, sigL2.frequency_Hz);
H_expected = alpha*H_L1 + beta*H_L2;

H_IF = revgnss.CodeIonoFreeRowBuilder.combineJacobians(H_L1, H_L2);
assert(norm(H_IF - H_expected) < 1e-9, ...
    sprintf('T3: combineJacobians result mismatch; max err=%.2e', max(abs(H_IF - H_expected))));

% Dimension mismatch must throw
threw = false;
try
    revgnss.CodeIonoFreeRowBuilder.combineJacobians(ones(1,5), ones(1,7));
catch
    threw = true;
end
assert(threw, 'T3: combineJacobians must throw on H dimension mismatch');

% combineRows must set hExplicitlyCombined=true
cfg = struct();
cfg.signals.twoFrequency.enable = true;
rowL1 = struct('z',1.0,'h',1.0,'H',H_L1,'R',4.0,'metadata',struct());
rowL2 = struct('z',1.0,'h',1.0,'H',H_L2,'R',9.0,'metadata',struct());
rowIF = revgnss.CodeIonoFreeRowBuilder.combineRows(rowL1, rowL2, cfg);
assert(rowIF.metadata.hExplicitlyCombined == true, ...
    'T3: combineRows must set hExplicitlyCombined=true');
assert(strcmp(rowIF.metadata.hCombination,'alphaH1_betaH2'), ...
    'T3: hCombination must be alphaH1_betaH2');
end

function t4_no_false_claims()
cfg = struct();
cfg.signals.twoFrequency.enable = true;
cfg.measurements.code.ionosphereFreeRows.enable  = true;
cfg.measurements.code.ionosphereFreeRows.useInEkf = true;

sm = struct('nTowers',5,'nReceivers',3,'totalCodeIonoFreeRows',15,'totalCodeRows',15);
s = revgnss.CodeIonoFreeConsistencyDiagnostics.assess(sm, cfg);

assert(~s.carrierIfRowsImplemented,        'T4: carrierIfRowsImplemented must be false');
assert(~s.integerFixingImplemented,        'T4: integerFixingImplemented must be false');
assert(~s.calibratedBiasProductsAvailable, 'T4: calibratedBiasProductsAvailable must be false');

forbidden = {'ppp','fixed','precise','operational','integer-ready','integer_ready'};
for k = 1:numel(forbidden)
    assert(isempty(strfind(lower(s.classification), forbidden{k})), ...
        sprintf('T4: classification must not contain "%s"; got: %s', forbidden{k}, s.classification));
end

validClasses = {'disabled','diagnostic-only','requested-no-l2','requested-no-if-rows', ...
    'summary-unavailable','active-code-if-ekf-consistent', ...
    'active-code-if-ekf-needs-h-audit','active-code-if-ekf-inconsistent'};
assert(ismember(s.classification, validClasses), ...
    sprintf('T4: classification "%s" not in allowed set', s.classification));
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
