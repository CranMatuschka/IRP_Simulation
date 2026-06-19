% test_stage38_carrier_attitude_preparation  Smoke tests for Stage 38.
%
% T1: carrier disabled -> 'not-ready-carrier-disabled', readyLevel == 1.
% T2: carrier float + 3 receivers -> l2/intFix both false, valid classification,
%     ambiguityInventory returns nAmbiguities == nTowers * nReceivers.
% T3: ReportStatus.current().stage >= 38.

fprintf('test_stage38_carrier_attitude_preparation\n');

% --- shared minimal out stub ---
out0 = struct();
out0.summary.nTowers    = 4;
out0.summary.nReceivers = 3;
out0.summary.totalCarrierRows = 12;
out0.summary.totalDiffAttRows = 8;

% --- T1: carrier disabled -> 'not-ready-carrier-disabled' ---
cfg1 = struct();
cfg1.measurements.carrierPhase.enable = false;
cfg1.measurements.carrierMode         = 'none';
cfg1.estimation.ambiguityMode         = 'floatPerTowerSignal';
cfg1.scenario.nReceivers              = 3;
cfg1.estimator.attitudeCarrierMode    = 'none';
cfg1.estimator.runKnownAmbiguityValidation = false;
s1 = revgnss.CarrierAttitudePreparation.assess(out0, cfg1);
assert(strcmp(s1.classification, 'not-ready-carrier-disabled'), ...
    sprintf('T1: expected not-ready-carrier-disabled, got ''%s''', s1.classification));
assert(s1.readyLevel == 1, ...
    sprintf('T1: readyLevel should be 1, got %d', s1.readyLevel));
assert(s1.enabled, 'T1: enabled should be true when out and cfg provided');
fprintf('T1 PASS: classification=not-ready-carrier-disabled, readyLevel=1\n');

% --- T2: carrier float + 3 receivers ---
cfg2 = struct();
cfg2.measurements.carrierPhase.enable = true;
cfg2.measurements.carrierMode         = 'ekfFloat';
cfg2.estimation.ambiguityMode         = 'floatPerTowerReceiverSignal';
cfg2.scenario.nReceivers              = 3;
cfg2.estimator.attitudeCarrierMode    = 'calibratedDifferentialAmbiguity';
cfg2.estimator.runKnownAmbiguityValidation = true;
s2 = revgnss.CarrierAttitudePreparation.assess(out0, cfg2);
assert(~s2.l2CarrierEkfImplemented,  'T2: l2CarrierEkfImplemented must be false');
assert(~s2.integerFixingImplemented, 'T2: integerFixingImplemented must be false');
validCls = {'diagnostic-float-carrier','calibrated-differential-only', ...
    'validation-known-ambiguity-only','not-ready-no-baseline-geometry','inconsistent'};
assert(ismember(s2.classification, validCls), ...
    sprintf('T2: unexpected classification ''%s''', s2.classification));
assert(s2.ambInv.ambiguityMetadataAvailable, 'T2: ambiguityMetadataAvailable should be true');
assert(s2.ambInv.nAmbiguities == 4*3, ...
    sprintf('T2: expected nAmbiguities=12, got %d', s2.ambInv.nAmbiguities));
assert(s2.rowInv.carrierRowMetadataAvailable, 'T2: carrierRowMetadataAvailable should be true');
assert(s2.rowInv.carrierRowCount == 12, ...
    sprintf('T2: expected carrierRowCount=12, got %d', s2.rowInv.carrierRowCount));
fprintf('T2 PASS: classification=%s, l2=false, intFix=false, nAmb=%d\n', ...
    s2.classification, s2.ambInv.nAmbiguities);

% --- T3: ReportStatus stage >= 38 ---
rs = revgnss.ReportStatus.current();
assert(str2double(char(rs.stage)) >= 38, ...
    sprintf('T3: stage should be >= 38, got ''%s''', char(rs.stage)));
fprintf('T3 PASS: ReportStatus.current().stage = ''%s'' (>= 38)\n', char(rs.stage));

fprintf('\ntest_stage38_carrier_attitude_preparation: all 3 tests passed.\n');
