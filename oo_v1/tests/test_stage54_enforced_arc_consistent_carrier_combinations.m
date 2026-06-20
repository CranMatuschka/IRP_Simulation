function results = test_stage54_enforced_arc_consistent_carrier_combinations()
% test_stage54_enforced_arc_consistent_carrier_combinations  Stage 54 tests.
%
% T1: buildFromStack with consistent arcIds and enforcement → all pairs kept
% T2: buildFromStack with incompatible arcIds and enforcement → all pairs skipped, empty output
% T3a: missing arcId + enforcement + disableWithWarning → falls back, rows produced
% T3b: missing arcId + enforcement + error policy → throws arcMetadataUnavailable
% T4: WideLaneNarrowLaneDiagnostics blocked when enforcement active + inconsistent pairs
% T5: No false integer-fixing or LAMBDA claims in cpInfo_IF with enforcement enabled

results = struct('name', {}, 'passed', {}, 'message', {});

Mp  = 2;
nSt = 8;

% Shared carrier stack inputs (2 L1 rows + 2 L2 rows)
z_   = [0.10; 0.20; 0.15; 0.25];
h_   = [0.09; 0.19; 0.14; 0.24];
H_   = eye(4, nSt);
R_   = 0.01 * eye(4);
cp_base.towerIdx          = [1;1;1;1];
cp_base.antennaIdx        = [1;1;1;1];
cp_base.signalIdx         = [1;1;2;2];
cp_base.phi_m             = z_;
cp_base.prefit_m          = z_ - h_;
cp_base.trackKey          = {'T001_A001_S01','T002_A001_S01', ...
                              'T001_A001_S02','T002_A001_S02'};
cp_base.ambiguityStateIdx = [1;2;3;4];

%% T1: Consistent arcIds + enforcement → 2 IF rows, nArcSkippedPairs=0
try
    cp1 = cp_base;
    cp1.arcId = [1;1;1;1];   % L1 arcs=[1,1], L2 arcs=[1,1] → both consistent
    cfg1.estimator.enforceCarrierArcConsistency.enable = true;
    cfg1.signals.twoFrequency.enable = true;
    [z1,h1,H1,R1,ci1] = revgnss.CarrierIonoFreeRowBuilder.buildFromStack( ...
        z_, h_, H_, R_, cp1, Mp, cfg1);
    assert(numel(z1) == Mp,          'T1: z_IF must have Mp rows when all arcs consistent');
    assert(size(H1,1) == Mp,         'T1: H_IF rows must equal Mp');
    assert(size(R1,1) == Mp,         'T1: R_IF must be Mp x Mp');
    assert(ci1.nArcSkippedPairs == 0, 'T1: nArcSkippedPairs must be 0');
    assert(ci1.arcConsistencyEnforced, 'T1: arcConsistencyEnforced must be true');
    assert(ci1.nArcConsistentPairs == Mp, 'T1: nArcConsistentPairs must equal Mp');
    results(end+1) = struct('name','T1_consistent_pairs_kept','passed',true,'message','');
catch ex
    results(end+1) = struct('name','T1_consistent_pairs_kept','passed',false,'message',ex.message);
end

%% T2: Incompatible arcIds + enforcement → empty output, nArcSkippedPairs=Mp
try
    cp2 = cp_base;
    cp2.arcId = [1;2;2;1];   % pair1: L1=1,L2=2 inconsistent; pair2: L1=2,L2=1 inconsistent
    cfg2.estimator.enforceCarrierArcConsistency.enable = true;
    cfg2.signals.twoFrequency.enable = true;
    [z2,h2,H2,R2,ci2] = revgnss.CarrierIonoFreeRowBuilder.buildFromStack( ...
        z_, h_, H_, R_, cp2, Mp, cfg2);
    assert(isempty(z2),                     'T2: z_IF must be empty when all pairs skipped');
    assert(isempty(h2),                     'T2: h_IF must be empty');
    assert(size(H2,1) == 0,                 'T2: H_IF must have 0 rows');
    assert(size(R2,1) == 0,                 'T2: R_IF must be 0x0');
    assert(ci2.nArcSkippedPairs == Mp,      'T2: nArcSkippedPairs must equal Mp');
    assert(ci2.arcConsistencyEnforced,      'T2: arcConsistencyEnforced must be true');
    assert(ci2.nArcConsistentPairs == 0,    'T2: nArcConsistentPairs must be 0');
    results(end+1) = struct('name','T2_inconsistent_pairs_skipped','passed',true,'message','');
catch ex
    results(end+1) = struct('name','T2_inconsistent_pairs_skipped','passed',false,'message',ex.message);
end

%% T3a: Missing arcId + disableWithWarning → falls back, produces IF rows
try
    cp3 = cp_base;   % no arcId field
    cfg3.estimator.enforceCarrierArcConsistency.enable = true;
    cfg3.validation.unsupportedFeaturePolicy = 'disableWithWarning';
    cfg3.signals.twoFrequency.enable = true;
    [z3,~,~,~,ci3] = revgnss.CarrierIonoFreeRowBuilder.buildFromStack( ...
        z_, h_, H_, R_, cp3, Mp, cfg3);
    assert(numel(z3) == Mp,       'T3a: fall-back must produce Mp IF rows when no arcId');
    assert(~ci3.arcConsistencyEnforced, 'T3a: enforcement must be false when arc metadata absent');
    results(end+1) = struct('name','T3a_missing_arcId_fallback','passed',true,'message','');
catch ex
    results(end+1) = struct('name','T3a_missing_arcId_fallback','passed',false,'message',ex.message);
end

%% T3b: Missing arcId + error policy → throws CarrierIonoFreeRowBuilder:arcMetadataUnavailable
try
    cp3b = cp_base;  % no arcId field
    cfg3b.estimator.enforceCarrierArcConsistency.enable = true;
    cfg3b.validation.unsupportedFeaturePolicy = 'error';
    cfg3b.signals.twoFrequency.enable = true;
    threw3b = false;
    try
        revgnss.CarrierIonoFreeRowBuilder.buildFromStack( ...
            z_, h_, H_, R_, cp3b, Mp, cfg3b);
    catch ex3b
        threw3b = strcmp(ex3b.identifier, 'CarrierIonoFreeRowBuilder:arcMetadataUnavailable');
    end
    assert(threw3b, 'T3b: error policy must throw arcMetadataUnavailable');
    results(end+1) = struct('name','T3b_error_policy_throws','passed',true,'message','');
catch ex
    results(end+1) = struct('name','T3b_error_policy_throws','passed',false,'message',ex.message);
end

%% T4: WideLaneNarrowLaneDiagnostics → blocked-arc-inconsistent-pairs classification
try
    % Build a summary with pair metadata, covariance, and arc inconsistency present.
    sigL1 = revgnss.SignalDefinition.get('L1');
    sigL2 = revgnss.SignalDefinition.get('L2');
    nPairs4 = 2;
    sum4.carrierIfPairMetadataAvailable = true;
    sum4.carrierIfAmbiguityPairCount    = nPairs4;
    sum4.ambiguityCovarianceSummary.Pamb = diag([1;1;1;1]);
    sum4.carrierIonoFreeArcConsistentPairs   = 0;
    sum4.carrierIonoFreeArcInconsistentPairs = nPairs4;
    sum4.carrierArcConsistencyEnforced       = true;
    sum4.carrierIonoFreeArcSkippedPairs      = nPairs4;
    cfg4.diagnostics.wideLaneNarrowLane.enable = true;
    s4 = revgnss.WideLaneNarrowLaneDiagnostics.assess(sum4, cfg4);
    assert(strcmp(s4.classification, 'blocked-arc-inconsistent-pairs'), ...
        ['T4: expected blocked-arc-inconsistent-pairs, got ' s4.classification]);
    assert(s4.arcConsistencyEnforced, 'T4: arcConsistencyEnforced must be true');
    assert(s4.arcConsistencyBlocksDiagnostics, 'T4: arcConsistencyBlocksDiagnostics must be true');
    results(end+1) = struct('name','T4_wlnl_blocked_arc_inconsistent','passed',true,'message','');
catch ex
    results(end+1) = struct('name','T4_wlnl_blocked_arc_inconsistent','passed',false,'message',ex.message);
end

%% T5: No false integer-fixing or LAMBDA claims in cpInfo_IF with enforcement
try
    cp5 = cp_base;
    cp5.arcId = [1;1;1;1];  % consistent
    cfg5.estimator.enforceCarrierArcConsistency.enable = true;
    cfg5.signals.twoFrequency.enable = true;
    [~,~,~,~,ci5] = revgnss.CarrierIonoFreeRowBuilder.buildFromStack( ...
        z_, h_, H_, R_, cp5, Mp, cfg5);
    assert(~ci5.integerFixingImplemented, 'T5: integerFixingImplemented must be false');
    assert(~ci5.lambdaImplemented,        'T5: lambdaImplemented must be false');
    assert(all(~ci5.ambiguityIsInteger),  'T5: ambiguityIsInteger must all be false');
    assert(ci5.nArcSkippedPairs == 0,     'T5: no pairs skipped when arcs are consistent');
    assert(ci5.arcConsistencyEnforced,    'T5: arcConsistencyEnforced must be true');
    results(end+1) = struct('name','T5_no_false_claims','passed',true,'message','');
catch ex
    results(end+1) = struct('name','T5_no_false_claims','passed',false,'message',ex.message);
end

end
