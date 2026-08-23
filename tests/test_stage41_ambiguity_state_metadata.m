% test_stage41_ambiguity_state_metadata  Smoke tests for Stage 41.
%
% T1: fromEkf with mock EKF struct (6 ambiguities) -> 6 rows, cov available.
% T2: attachToSummary adds ambiguityStateMetadata and ambiguityCovarianceSummary.
% T3: no false claims -- export does not imply integer readiness.

fprintf('test_stage41_ambiguity_state_metadata\n');

% --- shared mock EKF struct ---
% nTowers=2, nReceivers=3, nSignals=1, floatPerTowerReceiverSignal -> 6 states
% Base states 1..14, then 6 ambiguity states at indices 15..20
ekf.estimateAmbiguities  = true;
ekf.ambiguityMode        = 'floatPerTowerReceiverSignal';
ekf.nAmbiguities         = 6;
ekf.ambiguityNSignals    = 1;
ekf.ambiguityNReceivers  = 3;
ekf.nTowers              = 2;
ekf.nx                   = 20;
ekf.stateMap.ambiguityIdx3d = reshape(int32(15:20), 2, 3, 1);
ekf.stateMap.ambiguityIdx   = zeros(2, 1, 'int32');
% P: 20x20 diagonal positive definite (std = 10 m for ambiguity states)
P = diag([ones(14,1); 100*ones(6,1)]);
ekf.P = P;

% --- T1: fromEkf returns 6 rows; covarianceFromEkf available ---
meta = revgnss.AmbiguityStateMetadata.fromEkf(ekf);
assert(meta.available,          'T1: meta.available must be true');
assert(numel(meta.ambiguityTable) == 6, ...
    sprintf('T1: expected 6 table rows, got %d', numel(meta.ambiguityTable)));
assert(numel(meta.stateIndices) == 6, ...
    sprintf('T1: expected 6 stateIndices, got %d', numel(meta.stateIndices)));

cov = revgnss.AmbiguityStateMetadata.covarianceFromEkf(ekf);
assert(cov.available,               'T1: cov.available must be true');
assert(all(isfinite(cov.std_m)),    'T1: std_m must be finite');
assert(isfinite(cov.condition),     'T1: condition must be finite');
fprintf('T1 PASS: 6 metadata rows, cov.available=true, std=%.2f m, cond=%.2e\n', ...
    cov.std_m(1), cov.condition);

% --- T2: attachToSummary adds expected fields ---
s0 = struct();
s1 = revgnss.AmbiguityStateMetadata.attachToSummary(s0, meta, cov);
assert(isfield(s1,'ambiguityStateMetadata'),    'T2: ambiguityStateMetadata missing');
assert(isfield(s1,'ambiguityCovarianceSummary'),'T2: ambiguityCovarianceSummary missing');
assert(s1.ambiguityStateMetadata.available,         'T2: metadata.available must be true');
assert(s1.ambiguityCovarianceSummary.available,     'T2: covSummary.available must be true');
assert(s1.ambiguityStateMetadata.nAmbiguities == 6, 'T2: nAmbiguities must be 6');
fprintf('T2 PASS: attachToSummary added both fields, nAmbiguities=%d\n', ...
    s1.ambiguityStateMetadata.nAmbiguities);

% --- T3: no false claims ---
badTerms = {'integer-fixed','integer-ready','lambda-ready','fixed-ambiguity','operational'};
for k = 1:numel(badTerms)
    assert(~contains(lower(meta.ambiguityMode), badTerms{k}), ...
        sprintf('T3: ambiguityMode must not claim integer readiness, got ''%s''', meta.ambiguityMode));
    for j = 1:numel(meta.labels)
        assert(~contains(lower(meta.labels{j}), badTerms{k}), ...
            sprintf('T3: label ''%s'' must not claim integer readiness', meta.labels{j}));
    end
end
assert(~isfield(s1,'integerFixingImplemented') || ~s1.integerFixingImplemented, ...
    'T3: integerFixingImplemented must not be true');
fprintf('T3 PASS: no false integer-readiness claims in metadata, mode=''%s''\n', ...
    meta.ambiguityMode);

fprintf('\ntest_stage41_ambiguity_state_metadata: all 3 tests passed.\n');
