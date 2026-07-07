% test_simdata_freeze  Phase 4a: SimulationDataStore is immutable after freeze().
%
% Realizes confusion fix C-10: the central store is frozen after the simulation
% stage, so post-processing and report can only READ it. Every write method must
% throw SimulationDataStore:frozen once freeze() has been called.
thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));
addpath(fullfile(thisDir, '..', 'config'));
fprintf('=== test_simdata_freeze ===\n');

cfg   = revgnss.ConfigFactory.defaultConfig();
store = data.SimulationDataStore(cfg, 10);

% Before freeze the store is writable; recordOrbitCache is a harmless write.
store.recordOrbitCache(struct('enabled', false));

store.freeze();
store.freeze();   % idempotent — must not error

writes = { ...
    'recordEpoch',      @() store.recordEpoch(1, 0, [], [], [], [], [], [], 0, struct(), [], [], []); ...
    'recordOrbitCache', @() store.recordOrbitCache(struct('enabled', true)); ...
    'storeSnapshot',    @() store.storeSnapshot(0, 1, [], [], [], [], []) };
for i = 1:size(writes, 1)
    threw = false;
    try
        writes{i, 2}();
    catch ME
        threw = strcmp(ME.identifier, 'SimulationDataStore:frozen');
    end
    assert(threw, ...
        'test_simdata_freeze FAILED: %s did not throw SimulationDataStore:frozen after freeze()', writes{i, 1});
end
fprintf('  frozen store rejects %d write methods: PASS\n', size(writes, 1));

% Reads must still work on a frozen store.
m = store.getMeta();
assert(isstruct(m) && isfield(m, 'schemaName'), 'test_simdata_freeze FAILED: getMeta broken after freeze');
fprintf('  reads (getMeta) still work after freeze: PASS\n');
fprintf('=== test_simdata_freeze: PASS ===\n');
