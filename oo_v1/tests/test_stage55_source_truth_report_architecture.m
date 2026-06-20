function results = test_stage55_source_truth_report_architecture()
% test_stage55_source_truth_report_architecture  Stage 55 source-truth tests.
%
% T1: ReportStatus.current() returns stage='55' with correct title
% T2: ReportStatus validation warning references '55', not '51'/'52'/'53'/'54'
% T3: DiagnosticPluginRegistry.list() contains at least one Stage 52-54 plugin
% T4: DiagnosticPluginRegistry.collectAll() preserves existing summary fields
% T5: README current validation section mentions Stage 55 / seed 55, not seed 51

results = struct('name', {}, 'passed', {}, 'message', {});

%% T1: ReportStatus stage and title
try
    s1 = revgnss.ReportStatus.current();
    assert(strcmp(s1.stage, '55'), ...
        sprintf('T1: stage must be 55, got %s', s1.stage));
    assert(contains(s1.stageTitle, 'Source Truth'), ...
        sprintf('T1: stageTitle must contain "Source Truth", got: %s', s1.stageTitle));
    results(end+1) = struct('name','T1_report_status_stage_55','passed',true,'message','');
catch ex
    results(end+1) = struct('name','T1_report_status_stage_55','passed',false,'message',ex.message);
end

%% T2: Stale validation command not referencing stages 51-54 as current
try
    s2 = revgnss.ReportStatus.current();
    warnText = strjoin(s2.validationWarnings, ' ');
    staleNums = {'51','52','53','54'};
    for k = 1:numel(staleNums)
        pat = ['VALIDATION_STAGE'',''' staleNums{k} ''''];
        assert(~contains(warnText, pat), ...
            ['T2: stale stage reference in validation warning: ' pat]);
    end
    % If the artifact is stale, the warning must reference 55
    if ~s2.validationArtifactFresh
        assert(contains(warnText,'55'), ...
            'T2: stale-artifact warning must reference stage 55');
    end
    results(end+1) = struct('name','T2_no_stale_validation_command','passed',true,'message','');
catch ex
    results(end+1) = struct('name','T2_no_stale_validation_command','passed',false,'message',ex.message);
end

%% T3: DiagnosticPluginRegistry contains Stage 52-54 plugins
try
    cfg3.diagnostics.carrierArcEvidence.enable = true;
    cfg3.diagnostics.arcSeparatedAmbiguities.enable = true;
    cfg3.estimator.enforceCarrierArcConsistency.enable = true;
    plugins3 = revgnss.DiagnosticPluginRegistry.list(cfg3);
    assert(~isempty(plugins3), 'T3: plugin list must be non-empty');
    names3 = revgnss.DiagnosticPluginRegistry.names(cfg3);
    knownNames = {'carrierArcEvidence','arcSeparatedAmbiguities','enforcedCarrierArcConsistency'};
    foundAny = any(cellfun(@(n) ismember(n, knownNames), names3));
    assert(foundAny, 'T3: at least one of the Stage 52-54 plugins must appear in enabled names');
    assert(numel(names3) >= 1, 'T3: at least 1 enabled plugin expected');
    results(end+1) = struct('name','T3_plugin_registry_has_known_plugins','passed',true,'message','');
catch ex
    results(end+1) = struct('name','T3_plugin_registry_has_known_plugins','passed',false,'message',ex.message);
end

%% T4: collectAll preserves existing fields; adds diagnosticPlugins
try
    sum4.existingField = 99;
    sum4.carrierArcEvidenceAvailable    = false;
    sum4.ambiguityArcMetadataAvailable  = false;
    sum4.carrierArcConsistencyEnforced  = false;
    cfg4.diagnostics.carrierArcEvidence.enable = false;
    cfg4.diagnostics.arcSeparatedAmbiguities.enable = false;
    cfg4.estimator.enforceCarrierArcConsistency.enable = false;
    out4 = revgnss.DiagnosticPluginRegistry.collectAll(sum4, [], cfg4);
    assert(isfield(out4,'existingField'),      'T4: existingField must be preserved');
    assert(out4.existingField == 99,           'T4: existingField value must be unchanged');
    assert(isfield(out4,'diagnosticPlugins'),  'T4: diagnosticPlugins must be added');
    assert(isstruct(out4.diagnosticPlugins),   'T4: diagnosticPlugins must be a struct');
    results(end+1) = struct('name','T4_collect_all_preserves_fields','passed',true,'message','');
catch ex
    results(end+1) = struct('name','T4_collect_all_preserves_fields','passed',false,'message',ex.message);
end

%% T5: README current validation section mentions Stage 55 / seed 55; not seed 51
try
    thisDir = fileparts(fileparts(mfilename('fullpath')));
    readmePath = fullfile(thisDir, 'README_oo_v1.md');
    txt = fileread(readmePath);
    assert(contains(txt,'Stage 55'),  'T5: README must mention Stage 55');
    assert(contains(txt,'seed 55'),   'T5: README current validation must mention seed 55');
    assert(~contains(txt,'seed 51'),  'T5: README must not say "seed 51"');
    results(end+1) = struct('name','T5_readme_seed_consistency','passed',true,'message','');
catch ex
    results(end+1) = struct('name','T5_readme_seed_consistency','passed',false,'message',ex.message);
end

end
