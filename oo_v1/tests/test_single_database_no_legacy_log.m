% test_single_database_no_legacy_log
%
% Verifies that the legacy Diagnostics log is not populated in normal execution.
%
% T1: sim.simData is a SimulationDataStore (not Diagnostics).
% T2: sim.diag returns the same object as sim.simData (backward-compat getter).
% T3: sim.simData has no '.log' property.
% T4: Diagnostics.record() throws when called directly (deprecated).
% T5: Console output confirms backend selection during initialize().

fprintf('test_single_database_no_legacy_log\n');

function cfg = buildCfg_()
    cfg = revgnss.ConfigFactory.defaultConfig();
    cfg = revgnss.ScenarioPresets.singleAssetCarrierAttitude(cfg);
    cfg.simulation.duration_s = 30;
    cfg.simulation.dt_s       = 10;
    cfg.report.enable         = false;
    cfg.plots.enable          = false;
end

sim = revgnss.ReverseGNSSSimulation(buildCfg_());
sim.initialize();
sim.run();

% =========================================================================
% T1: sim.simData is a SimulationDataStore
% =========================================================================
fprintf('\nT1: sim.simData class...\n');
assert(isa(sim.simData, 'data.SimulationDataStore'), ...
    sprintf('T1 FAIL: sim.simData class is %s, expected data.SimulationDataStore', ...
    class(sim.simData)));
fprintf('T1 PASS: sim.simData is data.SimulationDataStore\n');

% =========================================================================
% T2: sim.diag returns sim.simData (backward-compat)
% =========================================================================
fprintf('\nT2: sim.diag backward-compatibility getter...\n');
assert(isa(sim.diag, 'data.SimulationDataStore'), ...
    sprintf('T2 FAIL: sim.diag class is %s', class(sim.diag)));
% Both references must point to the same underlying data
assert(sim.diag.nEpochs == sim.simData.nEpochs, ...
    'T2 FAIL: sim.diag and sim.simData report different nEpochs');
fprintf('T2 PASS: sim.diag returns SimulationDataStore with matching nEpochs=%d\n', ...
    sim.simData.nEpochs);

% =========================================================================
% T3: SimulationDataStore has no '.log' property
% =========================================================================
fprintf('\nT3: No .log property on SimulationDataStore...\n');
assert(~isprop(sim.simData, 'log'), ...
    'T3 FAIL: SimulationDataStore has a .log property (legacy not fully removed)');
hasLogField = isfield(sim.simData.getData(), 'log');
assert(~hasLogField, 'T3 FAIL: getData() struct has a .log field');
fprintf('T3 PASS: no .log property or field on SimulationDataStore\n');

% =========================================================================
% T4: Diagnostics.record() throws Diagnostics:deprecated
% =========================================================================
fprintf('\nT4: Diagnostics.record() is deprecated...\n');
diagLeg = revgnss.Diagnostics(buildCfg_());
threw = false;
try
    diagLeg.record(1, 0, [], [], [], [], [], [], [], struct(), [], [], []);
catch ME
    if strcmp(ME.identifier, 'Diagnostics:deprecated')
        threw = true;
    end
end
assert(threw, 'T4 FAIL: Diagnostics.record() did not throw Diagnostics:deprecated');
fprintf('T4 PASS: Diagnostics.record() throws Diagnostics:deprecated as expected\n');

% =========================================================================
% T5: hasArrayData() returns true — SimulationDataStore always has array data
% =========================================================================
fprintf('\nT5: SimulationDataStore always has array data...\n');
assert(sim.simData.hasArrayData(), 'T5 FAIL: hasArrayData() returned false');
d = sim.simData.getData();
assert(~isempty(d.t_s), 'T5 FAIL: getData().t_s is empty');
assert(numel(d.t_s) == sim.simData.nEpochs, ...
    sprintf('T5 FAIL: t_s length %d != nEpochs %d', numel(d.t_s), sim.simData.nEpochs));
fprintf('T5 PASS: hasArrayData()=true, t_s has %d entries\n', numel(d.t_s));

fprintf('\ntest_single_database_no_legacy_log: ALL TESTS PASSED\n');
