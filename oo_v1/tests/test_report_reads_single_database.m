% test_report_reads_single_database
%
% Verifies that ReportRunner.runSingle() returns out.data and out.dataMeta
% from SimulationDataStore (not from a legacy diag.log).
%
% T1: out.data is non-empty and has flat schema v3.
% T2: out.dataMeta.storageBackend == 'SimulationDataStore'.
% T3: out.dataMeta.schemaVersion == 3.
% T4: out.simData is the same SimulationDataStore used by the simulation.
% T5: out.data.t_s length matches out.dataMeta.nEpochs.

fprintf('test_report_reads_single_database\n');

function cfg = buildCfg_()
    cfg = revgnss.ConfigFactory.defaultConfig();
    cfg = revgnss.ScenarioPresets.singleAssetCarrierAttitude(cfg);
    cfg.simulation.duration_s = 60;
    cfg.simulation.dt_s       = 10;
    cfg.report.enable         = true;
    cfg.report.compileTex     = 'never';
    cfg.plots.enable          = false;
    cfg.report.layout         = 'clockExact';
end

outDir = tempname();
mkdir(outDir);
cfg = buildCfg_();
out = revgnss.ReportRunner.runSingle(cfg, outDir);

% =========================================================================
% T1: out.data is non-empty with flat schema v3
% =========================================================================
fprintf('\nT1: out.data present with schemaVersion=3...\n');
assert(isstruct(out.data), 'T1 FAIL: out.data is not a struct');
assert(~isempty(out.data), 'T1 FAIL: out.data is empty');
assert(isfield(out.data,'t_s'), 'T1 FAIL: out.data.t_s missing');
assert(isfield(out.data,'schemaVersion'), 'T1 FAIL: out.data.schemaVersion missing');
assert(out.data.schemaVersion == 3, ...
    sprintf('T1 FAIL: schemaVersion=%d, expected 3', out.data.schemaVersion));
fprintf('T1 PASS: out.data present with schemaVersion=3\n');

% =========================================================================
% T2: out.dataMeta.storageBackend == 'SimulationDataStore'
% =========================================================================
fprintf('\nT2: out.dataMeta.storageBackend...\n');
assert(isstruct(out.dataMeta), 'T2 FAIL: out.dataMeta is not a struct');
assert(isfield(out.dataMeta,'storageBackend'), 'T2 FAIL: out.dataMeta.storageBackend missing');
assert(strcmp(out.dataMeta.storageBackend,'SimulationDataStore'), ...
    sprintf('T2 FAIL: storageBackend=%s, expected SimulationDataStore', out.dataMeta.storageBackend));
fprintf('T2 PASS: out.dataMeta.storageBackend = %s\n', out.dataMeta.storageBackend);

% =========================================================================
% T3: out.dataMeta.schemaVersion == 3
% =========================================================================
fprintf('\nT3: out.dataMeta.schemaVersion...\n');
assert(isfield(out.dataMeta,'schemaVersion'), 'T3 FAIL: out.dataMeta.schemaVersion missing');
assert(out.dataMeta.schemaVersion == 3, ...
    sprintf('T3 FAIL: dataMeta.schemaVersion=%d, expected 3', out.dataMeta.schemaVersion));
assert(isfield(out.dataMeta,'schemaName'), 'T3 FAIL: out.dataMeta.schemaName missing');
assert(strcmp(out.dataMeta.schemaName,'FlatSimulationDataStore'), ...
    sprintf('T3 FAIL: schemaName=%s', out.dataMeta.schemaName));
fprintf('T3 PASS: schemaVersion=3, schemaName=%s\n', out.dataMeta.schemaName);

% =========================================================================
% T4: out.simData is a SimulationDataStore
% =========================================================================
fprintf('\nT4: out.simData class...\n');
assert(isfield(out,'simData') || isprop(out,'simData'), 'T4 FAIL: out.simData missing');
assert(isa(out.simData, 'revgnss.SimulationDataStore'), ...
    sprintf('T4 FAIL: out.simData class=%s', class(out.simData)));
fprintf('T4 PASS: out.simData is revgnss.SimulationDataStore\n');

% =========================================================================
% T5: out.data.t_s length matches out.dataMeta.nEpochs
% =========================================================================
fprintf('\nT5: out.data.t_s length matches out.dataMeta.nEpochs...\n');
assert(isfield(out.dataMeta,'nEpochs'), 'T5 FAIL: out.dataMeta.nEpochs missing');
assert(numel(out.data.t_s) == out.dataMeta.nEpochs, ...
    sprintf('T5 FAIL: t_s length=%d, dataMeta.nEpochs=%d', ...
    numel(out.data.t_s), out.dataMeta.nEpochs));
fprintf('T5 PASS: t_s has %d entries matching nEpochs\n', out.dataMeta.nEpochs);

% Cleanup
try; rmdir(outDir,'s'); catch; end

fprintf('\ntest_report_reads_single_database: ALL TESTS PASSED\n');
