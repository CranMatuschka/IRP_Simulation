% test_observability_diagnostics
% ObservabilityDiagnostics.analyze: rank, condition number, warnings.
%
% Verifies:
%   - Full-rank H returns rank = nx
%   - Identity H: rank = nx, condNum = 1
%   - Rank-deficient H: rank < nx, condNum large

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_observability_diagnostics ===\n');

clear cfg
cfg.diagnostics.observability.enabled      = true;
cfg.diagnostics.observability.warn         = false;   % suppress warnings in test
cfg.diagnostics.observability.rankTolerance = 1e-10;

% Minimal stateMap (explicitly fresh struct to avoid batch-run state pollution)
clear stateMap
stateMap.r_idx      = [1 2 3];
stateMap.v_idx      = [4 5 6];
stateMap.euler_idx  = [7 8 9];
stateMap.omega_idx  = [10 11 12];
stateMap.b_rx_idx   = 13;
stateMap.bdot_rx_idx = 14;

% --- Test 1: Full-rank identity H
nx = 4;
H_id = eye(nx);
stateMap2 = stateMap;
stateMap2.r_idx   = [1 2 3];
stateMap2.b_rx_idx = 4;
d = revgnss.ObservabilityDiagnostics.analyze(H_id, stateMap2, cfg);
assert(d.rank == nx, 'Identity H should have full rank %d, got %d', nx, d.rank);
assert(abs(d.condNum - 1) < 1e-10, 'Identity H condNum should be 1, got %.4e', d.condNum);

% --- Test 2: Rank-deficient H (last row = first row)
H_def = [1 0 0 0; 0 1 0 0; 0 0 1 0; 1 0 0 0];
d2 = revgnss.ObservabilityDiagnostics.analyze(H_def, stateMap2, cfg);
assert(d2.rank < nx, 'Rank-deficient H should have rank < %d, got %d', nx, d2.rank);
assert(d2.condNum > 100, 'Rank-deficient H should have large condNum, got %.4e', d2.condNum);

% --- Test 3: Empty H
H_empty = zeros(0, nx);
d3 = revgnss.ObservabilityDiagnostics.analyze(H_empty, stateMap2, cfg);
assert(~isempty(d3.warnings), 'Empty H should produce warnings');

fprintf('  Full-rank: rank=%d  condNum=%.4e\n', d.rank, d.condNum);
fprintf('  Rank-deficient: rank=%d  condNum=%.4e\n', d2.rank, d2.condNum);
fprintf('  Empty: %d warning(s)\n', numel(d3.warnings));
fprintf('  PASS\n');
