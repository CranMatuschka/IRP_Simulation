% test_datastore_physical_tower_count
% Commit 5: physical tower count must not be overwritten by expanded
% measurement-row tower-clock vectors.

fprintf('=== test_datastore_physical_tower_count ===\n');
thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

cfg = revgnss.ConfigFactory.defaultConfig();
cfg.scenario.nTowers = 5;
cfg.scenario.nReceivers = 4;

store = data.SimulationDataStore(cfg, 2, struct(), 5, 4);
entry = struct();
entry.time_s = 0;
entry.towerClockTruth_m = (1:20).';
entry.towerClockModel_m = (1:20).' + 0.25;

store.storeEntry_(1, entry);
m = store.getMeta();
d = store.getData();

expectedTruth = mean(reshape((1:20).', 5, []), 2, 'omitnan');
expectedModel = expectedTruth + 0.25;

assert(m.nTowers == 5, 'T1 FAILED: meta.nTowers must remain physical tower count 5.');
assert(m.nTowersPhysical == 5, 'T1 FAILED: meta.nTowersPhysical must be 5.');
assert(m.nTowerClockRowsStored == 20, ...
    'T1 FAILED: expanded tower-clock row count must be stored separately as 20.');
assert(size(d.towerClock.truth_m, 1) == 5, ...
    'T1 FAILED: towerClock.truth_m must be stored by physical tower, not expanded row.');
assert(d.towerClock.nPhysicalTowers == 5, ...
    'T1 FAILED: data towerClock physical count must be 5.');
assert(d.towerClock.nRowsStored == 20, ...
    'T1 FAILED: data towerClock expanded row count must be 20.');
assert(max(abs(d.towerClock.truth_m(:,1) - expectedTruth)) < 1e-12, ...
    'T1 FAILED: expanded tower-clock truth rows were not collapsed by tower order.');
assert(max(abs(d.towerClock.model_m(:,1) - expectedModel)) < 1e-12, ...
    'T1 FAILED: expanded tower-clock model rows were not collapsed by tower order.');
fprintf('  T1 expanded clock rows preserve physical nTowers: PASS\n');

badStore = data.SimulationDataStore(cfg, 1, struct(), 5, 4);
badEntry = struct('time_s', 0, 'towerClockTruth_m', (1:18).', 'towerClockModel_m', (1:18).');
threw = false;
try
    badStore.storeEntry_(1, badEntry);
catch ME
    threw = strcmp(ME.identifier, 'SimulationDataStore:towerClockRowExpansion');
end
assert(threw, 'T2 FAILED: non-divisible expanded tower-clock vector must error.');
fprintf('  T2 non-divisible expansion guard: PASS\n');

fprintf('=== test_datastore_physical_tower_count: ALL PASS ===\n');
