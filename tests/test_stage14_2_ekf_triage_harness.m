% test_stage14_2_ekf_triage_harness

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_stage14_2_ekf_triage_harness ===\n');

fprintf('  T1: factory returns at least 8 cases ...\n');
cases = revgnss.TriageScenarioFactory.buildCases();
assert(numel(cases) >= 8, 'Expected at least 8 triage cases.');
fprintf('    PASS\n');

fprintf('  T2: case names are unique ...\n');
names = {cases.name};
assert(numel(unique(names)) == numel(names), 'Case names must be unique.');
fprintf('    PASS\n');

fprintf('  T3: clean baseline disables carrier and ZWD ...\n');
c1 = cases(1).cfg;
assert(strcmp(c1.measurements.carrierMode, 'off'), 'Baseline carrierMode must be off.');
assert(~c1.measurements.carrierPhase.enable, 'Baseline carrier generation must be disabled.');
assert(strcmp(c1.estimation.troposphereMode, 'none'), 'Baseline ZWD must be disabled.');
fprintf('    PASS\n');

fprintf('  T4: carrier multi-receiver case is present ...\n');
ixCarrierMulti = find(strcmp(names, 'case_06_carrier_ekf_three_receivers'), 1);
assert(~isempty(ixCarrierMulti), 'Missing multi-receiver carrier EKF case.');
assert(cases(ixCarrierMulti).cfg.scenario.nReceivers == 3, 'Carrier multi case must use 3 receivers.');
assert(strcmp(cases(ixCarrierMulti).cfg.measurements.carrierMode, 'ekfFloat'), 'Carrier multi case must use ekfFloat.');
fprintf('    PASS\n');

fprintf('  T5: ZWD case is present ...\n');
ixZwd = find(strcmp(names, 'case_07_zwd_code_doppler_three_receivers'), 1);
assert(~isempty(ixZwd), 'Missing ZWD case.');
assert(strcmp(cases(ixZwd).cfg.estimation.troposphereMode, 'perTowerZwd'), 'ZWD case must enable perTowerZwd.');
fprintf('    PASS\n');

fprintf('  T6: analyzer classifies synthetic PASS/FAIL metrics ...\n');
m = syntheticMetrics_();
[statusPass, flagsPass] = revgnss.TriageAnalyzer.classifyMetrics(m);
assert(strcmp(statusPass, 'PASS'), 'Synthetic clean metrics should PASS.');
assert(isempty(flagsPass), 'Synthetic clean metrics should not set flags.');
m.finalPositionError_m = 20000;
[statusFail, ~] = revgnss.TriageAnalyzer.classifyMetrics(m);
assert(strcmp(statusFail, 'FAIL'), 'Large divergence should FAIL.');
fprintf('    PASS\n');

fprintf('  T7: analyzer detects residual-state inconsistency ...\n');
m = syntheticMetrics_();
m.finalPostFitRms_m = 0.2;
m.finalPositionError_m = 2000;
m.residualStateMismatchRatio = m.finalPositionError_m / m.finalPostFitRms_m;
[statusWarn, flagsWarn] = revgnss.TriageAnalyzer.classifyMetrics(m);
assert(any(strcmp(flagsWarn, 'RESIDUAL-STATE INCONSISTENCY')), 'Expected residual-state inconsistency flag.');
assert(any(strcmp(statusWarn, {'WARN','FAIL'})), 'Residual-state inconsistency must not PASS.');
fprintf('    PASS\n');

fprintf('  T8: extractor returns required fields from fake history ...\n');
fake = struct();
fake.cfg = cases(1).cfg;
fake.runtime_s = 0.1;
fake.history.time_s = (0:4)';
fake.history.positionError_m = [100; 80; 60; 55; 50];
fake.history.clockBiasError_m = [10; 8; 6; 5; 4];
metrics = revgnss.TriageResultExtractor.extract(cases(1), fake);
required = {'caseName','success','runtime_s','nEpochs','nTowers','nReceivers', ...
    'nStates','nCodeRowsMax','nDopplerRowsMax','nCarrierRowsMax','nZwdStates', ...
    'nAmbiguityStates','initialPositionError_m','finalPositionError_m', ...
    'rmsPositionError_m','maxPositionError_m','initialClockError_m', ...
    'finalClockError_m','rmsClockError_m','finalClockDriftError_mps', ...
    'rmsClockDriftError_mps','finalPreFitRms_m','finalPostFitRms_m', ...
    'medianPreFitRms_m','medianPostFitRms_m','maxPreFitRms_m','maxPostFitRms_m', ...
    'medianNIS','maxNIS','medianNEES_pos','maxNEES_pos','medianPDOP','maxPDOP', ...
    'medianGDOP','maxGDOP','clockObsRankPhysical','clockObsRankGauged', ...
    'clockObsCondPhysical','clockObsCondGauged','zwdRms_m','ambiguityRms_m', ...
    'carrierSlipCount','covarianceMinEig','covarianceMaxEig','covarianceCondition', ...
    'hasNaN','hasInf','positionImprovementRatio','clockImprovementRatio', ...
    'residualStateMismatchRatio','clockStateMismatchRatio'};
for k = 1:numel(required)
    assert(isfield(metrics, required{k}), 'Missing metric field: %s', required{k});
end
assert(metrics.finalPositionError_m == 50, 'Extractor final position mismatch.');
fprintf('    PASS\n');

fprintf('=== test_stage14_2_ekf_triage_harness PASS ===\n');

function m = syntheticMetrics_()
m = struct();
m.success = true;
m.hasNaN = false;
m.hasInf = false;
m.initialPositionError_m = 1000;
m.finalPositionError_m = 900;
m.initialClockError_m = 100;
m.finalClockError_m = 90;
m.finalPostFitRms_m = 2;
m.residualStateMismatchRatio = 450;
m.medianPDOP = 5;
m.zwdRms_m = 0;
m.ambiguityRms_m = 0;
m.maxNIS = 100;
m.covarianceMinEig = 1e-6;
end
