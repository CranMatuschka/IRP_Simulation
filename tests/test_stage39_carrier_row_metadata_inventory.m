% test_stage39_carrier_row_metadata_inventory  Smoke tests for Stage 39.
%
% T1: summary-only fallback -> classification='summary-only', carrierRowCount=12.
% T2: ambiguity fallback -> nAmbiguities=12, source contains 'estimate' or 'summary'.
% T3: no false claims -> l2=false, intFix=false, classification has no bad terms.

fprintf('test_stage39_carrier_row_metadata_inventory\n');

% --- shared synthetic out/cfg ---
out0 = struct();
out0.summary.nTowers             = 4;
out0.summary.nReceivers          = 3;
out0.summary.totalCarrierRows    = 12;
out0.summary.totalDiffAttRows    = 6;
out0.summary.carrierUsedInEkf    = true;
out0.summary.carrierDiagnosticOnly = false;
out0.summary.maxEKFRows          = 30;

cfg0 = struct();
cfg0.measurements.carrierPhase.enable = true;
cfg0.measurements.carrierMode         = 'ekfFloat';
cfg0.estimation.ambiguityMode         = 'floatPerTowerReceiverSignal';

s = revgnss.CarrierRowMetadataInventory.inventory(out0, cfg0);

% --- T1: summary-only classification, correct carrier row count ---
assert(strcmp(s.classification, 'summary-only'), ...
    sprintf('T1: expected ''summary-only'', got ''%s''', s.classification));
assert(s.carrierRowCount == 12, ...
    sprintf('T1: expected carrierRowCount=12, got %g', s.carrierRowCount));
assert(s.differentialAttitudeRowCount == 6, ...
    sprintf('T1: expected diffAttRowCount=6, got %g', s.differentialAttitudeRowCount));
fprintf('T1 PASS: classification=summary-only, carrierRowCount=12, diffAttRows=6\n');

% --- T2: ambiguity fallback count and source ---
assert(isfinite(s.ambiguityStateCount) && s.ambiguityStateCount == 12, ...
    sprintf('T2: expected ambiguityStateCount=12, got %g', s.ambiguityStateCount));
src = lower(s.ambiguityStateCountSource);
assert(contains(src,'estimate') || contains(src,'summary'), ...
    sprintf('T2: source should say estimate/summary, got ''%s''', s.ambiguityStateCountSource));
fprintf('T2 PASS: ambiguityStateCount=12, source=''%s''\n', s.ambiguityStateCountSource);

% --- T3: no false claims ---
assert(~s.l2CarrierEkfImplemented,  'T3: l2CarrierEkfImplemented must be false');
assert(~s.integerFixingImplemented, 'T3: integerFixingImplemented must be false');
badTerms = {'fixed','precise','operational'};
for k = 1:numel(badTerms)
    assert(~contains(lower(s.classification), badTerms{k}), ...
        sprintf('T3: classification must not contain ''%s''', badTerms{k}));
end
fprintf('T3 PASS: l2=false, intFix=false, classification clean\n');

fprintf('\ntest_stage39_carrier_row_metadata_inventory: all 3 tests passed.\n');
