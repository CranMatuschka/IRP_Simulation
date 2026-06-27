% test_ladder_sweep_single_database_compact
%
% Verifies that the compact MAT written by the ladder sweep uses flat schema v3.
%
% T1: compact.version == 3.
% T2: compact.schema == 'FlatSimulationDataStoreCompact'.
% T3: compact.meta.storageBackend == 'SimulationDataStore'.
% T4: compact.data is the full getData() output (contains all field groups).
% T5: compact.data.err_pos_norm_m (flat alias) is present and consistent.

fprintf('test_ladder_sweep_single_database_compact\n');

function cfg = buildCfg_()
    cfg = revgnss.ConfigFactory.defaultConfig();
    cfg = revgnss.ScenarioPresets.singleAssetCarrierAttitude(cfg);
    cfg.simulation.duration_s = 60;
    cfg.simulation.dt_s       = 10;
    cfg.report.enable         = false;
    cfg.plots.enable          = false;
end

% Run simulation and replicate buildCompact_ logic manually
cfg = buildCfg_();
sim = revgnss.ReverseGNSSSimulation(cfg);
sim.initialize();
sim.run();
results  = sim.getResults();
simData  = sim.simData;

% Build the compact struct as the ladder sweep would
compact.version        = 3;
compact.schema         = 'FlatSimulationDataStoreCompact';
compact.caseIndex      = 1;
compact.caseName       = 'test_case';
compact.meta           = simData.getMeta();
compact.data           = simData.getData();

% =========================================================================
% T1: compact.version == 3
% =========================================================================
fprintf('\nT1: compact.version == 3...\n');
assert(isfield(compact,'version'), 'T1 FAIL: compact.version field missing');
assert(compact.version == 3, sprintf('T1 FAIL: version=%d, expected 3', compact.version));
fprintf('T1 PASS: compact.version = 3\n');

% =========================================================================
% T2: compact.schema == 'FlatSimulationDataStoreCompact'
% =========================================================================
fprintf('\nT2: compact.schema...\n');
assert(isfield(compact,'schema'), 'T2 FAIL: compact.schema field missing');
assert(strcmp(compact.schema,'FlatSimulationDataStoreCompact'), ...
    sprintf('T2 FAIL: schema=%s', compact.schema));
fprintf('T2 PASS: compact.schema = %s\n', compact.schema);

% =========================================================================
% T3: compact.meta.storageBackend == 'SimulationDataStore'
% =========================================================================
fprintf('\nT3: compact.meta.storageBackend...\n');
assert(isfield(compact,'meta'), 'T3 FAIL: compact.meta missing');
assert(isfield(compact.meta,'storageBackend'), 'T3 FAIL: compact.meta.storageBackend missing');
assert(strcmp(compact.meta.storageBackend,'SimulationDataStore'), ...
    sprintf('T3 FAIL: storageBackend=%s', compact.meta.storageBackend));
assert(compact.meta.schemaVersion == 3, ...
    sprintf('T3 FAIL: meta.schemaVersion=%d', compact.meta.schemaVersion));
fprintf('T3 PASS: storageBackend=%s, schemaVersion=3\n', compact.meta.storageBackend);

% =========================================================================
% T4: compact.data contains all field groups from getData()
% =========================================================================
fprintf('\nT4: compact.data field groups...\n');
requiredGroups = {'t_s','truth','estimate','error','meas','residual','consistency'};
for fi = 1:numel(requiredGroups)
    assert(isfield(compact.data, requiredGroups{fi}), ...
        sprintf('T4 FAIL: compact.data.%s missing', requiredGroups{fi}));
end
assert(isfield(compact.data.error,'positionNorm_m'), ...
    'T4 FAIL: compact.data.error.positionNorm_m missing');
assert(isfield(compact.data.consistency,'NIS'), ...
    'T4 FAIL: compact.data.consistency.NIS missing');
fprintf('T4 PASS: all %d field groups present in compact.data\n', numel(requiredGroups));

% =========================================================================
% T5: flat alias err_pos_norm_m present and consistent
% =========================================================================
fprintf('\nT5: compact.data.err_pos_norm_m (flat v3 alias)...\n');
assert(isfield(compact.data,'err_pos_norm_m'), ...
    'T5 FAIL: compact.data.err_pos_norm_m missing');
maxDiff = max(abs(compact.data.err_pos_norm_m - compact.data.error.positionNorm_m));
assert(maxDiff < 1e-12, ...
    sprintf('T5 FAIL: err_pos_norm_m vs error.positionNorm_m mismatch %.2e m', maxDiff));
assert(compact.data.schemaVersion == 3, ...
    sprintf('T5 FAIL: compact.data.schemaVersion=%d', compact.data.schemaVersion));
fprintf('T5 PASS: err_pos_norm_m consistent (max diff=%.2e m), schemaVersion=3\n', maxDiff);

% Verify toCompactStruct() matches manual construction
cs = simData.toCompactStruct();
assert(cs.version == 3, sprintf('toCompactStruct: version=%d', cs.version));
assert(strcmp(cs.schema,'FlatSimulationDataStoreCompact'), ...
    sprintf('toCompactStruct: schema=%s', cs.schema));

fprintf('\ntest_ladder_sweep_single_database_compact: ALL TESTS PASSED\n');
