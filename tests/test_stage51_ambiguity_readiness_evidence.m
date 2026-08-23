function results = test_stage51_ambiguity_readiness_evidence()
% test_stage51_ambiguity_readiness_evidence
% Stage 51: Ambiguity Readiness Evidence Hardening v1 tests.
%
% T1: non-early-return — multiple missing prerequisites produce multiple blockers
% T2: arc-quality unavailable — slip detector on but no arc counts in summary
% T3: residual consistency — finite NIS and prefit RMS -> available
% T4: hard no-false-claims — hard flags always false; no forbidden terms in classification
% T5: status command check — ReportStatus does not reference OO_V1_VALIDATION_STAGE='49' or '50'

results = struct('name', {}, 'passed', {}, 'message', {});

%% T1: non-early-return evidence collection
try
    cfg = struct();
    cfg.diagnostics.ambiguityFixingReadiness.enable = true;
    cfg.measurements.carrier.slipDetection.enable   = true;

    % Summary with some fields present, some missing
    summ = struct();
    summ.carrierIfPairMetadataAvailable = false;   % no pair metadata
    summ.carrierIfAmbiguityPairCount    = 0;
    summ.meanNIS                        = 3.5;     % residual IS available
    summ.finalPrefitRMS_m               = 0.05;

    s = revgnss.AmbiguityFixingReadinessGate.assess(summ, cfg);

    % Must NOT stop at first missing item: residual evidence should still be collected
    assert(s.residualDiagnosticsAvailable, ...
        'residualDiagnosticsAvailable must be true even when pair metadata is missing');
    assert(isfinite(s.nisMean), 'nisMean must be collected even without pair metadata');

    % Must have multiple blockers (not just one for missing metadata)
    assert(numel(s.blockers) > 2, ...
        sprintf('Expected >2 blockers (non-early-return), got %d', numel(s.blockers)));

    % Classification is still conservative
    assert(strcmp(s.classification,'not-ready-no-ambiguity-metadata'), ...
        sprintf('Expected not-ready-no-ambiguity-metadata, got %s', s.classification));

    results(end+1) = struct('name','T1_non_early_return','passed',true,'message','');
catch ex
    results(end+1) = struct('name','T1_non_early_return','passed',false,'message',ex.message);
end

%% T2: arc-quality unavailable when slip detector on but no arc counts
try
    cfg = struct();
    cfg.measurements.carrier.slipDetection.enable = true;

    summ = struct();
    % No slip/arc fields in summary

    aq = revgnss.AmbiguityFixingReadinessGate.arcQuality(summ, cfg);
    assert(~aq.available, 'available must be false when no arc counts exist');
    assert(strcmp(aq.classification,'unavailable'), ...
        sprintf('classification must be unavailable, got %s', aq.classification));
    assert(~isempty(aq.warnings), 'warnings must be non-empty explaining missing arc summary');

    results(end+1) = struct('name','T2_arc_quality_unavailable','passed',true,'message','');
catch ex
    results(end+1) = struct('name','T2_arc_quality_unavailable','passed',false,'message',ex.message);
end

%% T3: residual consistency when NIS and prefit RMS are finite
try
    summ = struct();
    summ.meanNIS          = 4.2;
    summ.expectedNIS      = 5.0;
    summ.finalPrefitRMS_m = 0.08;

    rc = revgnss.AmbiguityFixingReadinessGate.residualConsistency(summ, struct());
    assert(rc.available, 'available must be true when NIS and prefit RMS are finite');
    assert(strcmp(rc.classification,'residuals-and-nis-available'), ...
        sprintf('Expected residuals-and-nis-available, got %s', rc.classification));
    assert(abs(rc.nisMean - 4.2) < 1e-10,      'nisMean mismatch');
    assert(abs(rc.residualRms_m - 0.08) < 1e-10, 'residualRms_m mismatch');
    assert(abs(rc.expectedNis - 5.0) < 1e-10,   'expectedNis mismatch');

    results(end+1) = struct('name','T3_residual_consistency','passed',true,'message','');
catch ex
    results(end+1) = struct('name','T3_residual_consistency','passed',false,'message',ex.message);
end

%% T4: hard no-false-claims
try
    % Disabled state
    s0 = revgnss.AmbiguityFixingReadinessGate.assess(struct(), struct());
    assert(~s0.phaseBiasProductsAvailable,  'phaseBiasProductsAvailable must always be false');
    assert(~s0.integerStrategyAvailable,    'integerStrategyAvailable must always be false');
    assert(~s0.integerFixingImplemented,    'integerFixingImplemented must always be false');
    assert(~s0.lambdaImplemented,           'lambdaImplemented must always be false');
    assert(~s0.falseFixRiskControlled,      'falseFixRiskControlled must always be false');

    % Enabled state with some prereqs
    cfg = struct();
    cfg.diagnostics.ambiguityFixingReadiness.enable = true;
    s1 = revgnss.AmbiguityFixingReadinessGate.assess(struct(), cfg);
    assert(~s1.integerFixingImplemented,    'integerFixingImplemented must be false when enabled');
    assert(~s1.lambdaImplemented,           'lambdaImplemented must be false when enabled');
    assert(~s1.falseFixRiskControlled,      'falseFixRiskControlled must be false when enabled');

    % Classification must not contain forbidden terms
    forbidden = {'fixed','precise','PPP','operational','integer-ready'};
    for k = 1:numel(forbidden)
        assert(isempty(strfind(s1.classification, forbidden{k})), ...
            sprintf('classification must not contain ''%s''', forbidden{k}));
    end

    results(end+1) = struct('name','T4_no_false_claims','passed',true,'message','');
catch ex
    results(end+1) = struct('name','T4_no_false_claims','passed',false,'message',ex.message);
end

%% T5: ReportStatus does not reference stale stage 49 or 50 validation command
try
    s = revgnss.ReportStatus.current();

    % Collect all warning text
    allText = '';
    for k = 1:numel(s.validationWarnings)
        allText = [allText, s.validationWarnings{k}]; %#ok<AGROW>
    end

    assert(isempty(strfind(allText, 'OO_V1_VALIDATION_STAGE'',''49''')), ...
        'ReportStatus warning must not reference OO_V1_VALIDATION_STAGE=49');
    assert(isempty(strfind(allText, 'OO_V1_VALIDATION_STAGE'',''50''')), ...
        'ReportStatus warning must not reference OO_V1_VALIDATION_STAGE=50');

    % Stage must be 51
    assert(str2double(s.stage) >= 51, ...
        sprintf('ReportStatus stage must be >= 51, got %s', s.stage));

    results(end+1) = struct('name','T5_status_command_check','passed',true,'message','');
catch ex
    results(end+1) = struct('name','T5_status_command_check','passed',false,'message',ex.message);
end

%% Print summary
nPass = sum([results.passed]);
nTot  = numel(results);
fprintf('\n--- test_stage51_ambiguity_readiness_evidence: %d/%d passed ---\n', nPass, nTot);
for k = 1:nTot
    if results(k).passed
        fprintf('  PASS  %s\n', results(k).name);
    else
        fprintf('  FAIL  %s: %s\n', results(k).name, results(k).message);
    end
end
