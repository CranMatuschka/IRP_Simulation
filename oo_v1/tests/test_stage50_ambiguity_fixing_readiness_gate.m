function results = test_stage50_ambiguity_fixing_readiness_gate()
% test_stage50_ambiguity_fixing_readiness_gate
% Stage 50: Ambiguity Fixing Readiness Gate v1 tests.
%
% T1: disabled state — classification='disabled', all hard flags false
% T2: classification chain — missing prerequisites produce correct not-ready states
% T3: no false claims — hard flags always false in active state
% T4: full gate pass — all soft prerequisites met -> 'float-diagnostics-ready-integer-blocked'

results = struct('name', {}, 'passed', {}, 'message', {});

%% T1: disabled state
try
    s = revgnss.AmbiguityFixingReadinessGate.assess(struct(), struct());
    assert(strcmp(s.classification,'disabled'),        'classification must be disabled');
    assert(~s.phaseBiasProductsAvailable,  'phaseBiasProductsAvailable must be false');
    assert(~s.integerStrategyAvailable,    'integerStrategyAvailable must be false');
    assert(~s.integerFixingImplemented,    'integerFixingImplemented must be false');
    assert(~s.lambdaImplemented,           'lambdaImplemented must be false');
    assert(~s.falseFixRiskControlled,      'falseFixRiskControlled must be false');
    assert(~s.enabled,                     'enabled must be false when toggle off');

    results(end+1) = struct('name','T1_disabled_state','passed',true,'message','');
catch ex
    results(end+1) = struct('name','T1_disabled_state','passed',false,'message',ex.message);
end

%% T2: classification chain
try
    cfg = struct();
    cfg.diagnostics.ambiguityFixingReadiness.enable = true;
    cfg.diagnostics.wideLaneNarrowLane.enable       = true;
    cfg.measurements.carrier.slipDetection.enable   = true;

    % No pair metadata -> not-ready-no-ambiguity-metadata
    summ = struct();
    summ.carrierIfPairMetadataAvailable = false;
    summ.carrierIfAmbiguityPairCount    = 0;
    s1 = revgnss.AmbiguityFixingReadinessGate.assess(summ, cfg);
    assert(strcmp(s1.classification,'not-ready-no-ambiguity-metadata'), ...
        sprintf('Expected not-ready-no-ambiguity-metadata, got %s', s1.classification));

    % Pair metadata but no covariance -> not-ready-no-covariance
    summ.carrierIfPairMetadataAvailable = true;
    summ.carrierIfAmbiguityPairCount    = 2;
    s2 = revgnss.AmbiguityFixingReadinessGate.assess(summ, cfg);
    assert(strcmp(s2.classification,'not-ready-no-covariance'), ...
        sprintf('Expected not-ready-no-covariance, got %s', s2.classification));

    % Add covariance but WL/NL not active -> not-ready-no-wide-lane-narrow-lane
    P_pair = [4 1; 1 9];
    summ.ambiguityCovarianceSummary.Pamb = blkdiag(P_pair, P_pair);
    summ.wideLaneNarrowLaneClassification = 'disabled';
    s3 = revgnss.AmbiguityFixingReadinessGate.assess(summ, cfg);
    assert(strcmp(s3.classification,'not-ready-no-wide-lane-narrow-lane'), ...
        sprintf('Expected not-ready-no-wide-lane-narrow-lane, got %s', s3.classification));

    % WL/NL active but slip detection off -> not-ready-arc-quality-unavailable
    summ.wideLaneNarrowLaneClassification = 'active-float-diagnostics';
    cfg2 = cfg;
    cfg2.measurements.carrier.slipDetection.enable = false;
    s4 = revgnss.AmbiguityFixingReadinessGate.assess(summ, cfg2);
    assert(strcmp(s4.classification,'not-ready-arc-quality-unavailable'), ...
        sprintf('Expected not-ready-arc-quality-unavailable, got %s', s4.classification));

    % Arc quality available but no NIS -> not-ready-residual-consistency-unavailable
    summ.meanNIS = NaN;
    s5 = revgnss.AmbiguityFixingReadinessGate.assess(summ, cfg);
    assert(strcmp(s5.classification,'not-ready-residual-consistency-unavailable'), ...
        sprintf('Expected not-ready-residual-consistency-unavailable, got %s', s5.classification));

    results(end+1) = struct('name','T2_classification_chain','passed',true,'message','');
catch ex
    results(end+1) = struct('name','T2_classification_chain','passed',false,'message',ex.message);
end

%% T3: no false claims (active gate always has hard flags = false)
try
    cfg = struct();
    cfg.diagnostics.ambiguityFixingReadiness.enable = true;

    s = revgnss.AmbiguityFixingReadinessGate.assess(struct(), cfg);
    % Even when enabled but no prereqs, hard flags must be false
    assert(~s.phaseBiasProductsAvailable,  'phaseBiasProductsAvailable must always be false');
    assert(~s.integerStrategyAvailable,    'integerStrategyAvailable must always be false');
    assert(~s.integerFixingImplemented,    'integerFixingImplemented must always be false');
    assert(~s.lambdaImplemented,           'lambdaImplemented must always be false');
    assert(~s.falseFixRiskControlled,      'falseFixRiskControlled must always be false');

    results(end+1) = struct('name','T3_no_false_claims','passed',true,'message','');
catch ex
    results(end+1) = struct('name','T3_no_false_claims','passed',false,'message',ex.message);
end

%% T4: full gate pass -> 'float-diagnostics-ready-integer-blocked'
try
    cfg = struct();
    cfg.diagnostics.ambiguityFixingReadiness.enable = true;
    cfg.diagnostics.wideLaneNarrowLane.enable       = true;
    cfg.measurements.carrier.slipDetection.enable   = true;

    P_pair = [4 1; 1 9];
    summ = struct();
    summ.carrierIfPairMetadataAvailable       = true;
    summ.carrierIfAmbiguityPairCount          = 2;
    summ.ambiguityCovarianceSummary.Pamb      = blkdiag(P_pair, P_pair);
    summ.wideLaneNarrowLaneClassification     = 'active-float-diagnostics';
    summ.meanNIS                              = 3.5;

    s = revgnss.AmbiguityFixingReadinessGate.assess(summ, cfg);
    assert(strcmp(s.classification,'float-diagnostics-ready-integer-blocked'), ...
        sprintf('Expected float-diagnostics-ready-integer-blocked, got %s', s.classification));
    assert(s.enabled,                   'enabled should be true');
    assert(s.pairMetadataAvailable,     'pairMetadataAvailable should be true');
    assert(s.covarianceAvailable,       'covarianceAvailable should be true');
    assert(s.wideLaneNarrowLaneReady,   'wideLaneNarrowLaneReady should be true');
    assert(strcmp(s.arcQualityStatus,'available'),        'arcQualityStatus should be available');
    assert(strcmp(s.residualConsistencyStatus,'available'),'residualConsistencyStatus should be available');
    assert(~isempty(s.blockers),        'blockers should be non-empty (hard blockers always present)');
    assert(~s.integerFixingImplemented, 'integerFixingImplemented must be false');
    assert(~s.lambdaImplemented,        'lambdaImplemented must be false');

    % summaryLines must not error
    lines = revgnss.AmbiguityFixingReadinessGate.summaryLines(s);
    assert(~isempty(lines), 'summaryLines must return non-empty cell array');

    results(end+1) = struct('name','T4_full_gate_pass','passed',true,'message','');
catch ex
    results(end+1) = struct('name','T4_full_gate_pass','passed',false,'message',ex.message);
end

%% Print summary
nPass = sum([results.passed]);
nTot  = numel(results);
fprintf('\n--- test_stage50_ambiguity_fixing_readiness_gate: %d/%d passed ---\n', nPass, nTot);
for k = 1:nTot
    if results(k).passed
        fprintf('  PASS  %s\n', results(k).name);
    else
        fprintf('  FAIL  %s: %s\n', results(k).name, results(k).message);
    end
end
