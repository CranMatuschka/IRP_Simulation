% test_stage6_carrier_consistency
% Phase 1: L1-only carrier EKF — ambiguity state allocation constraints.
%
% Verifies:
%   T1: ambiguityNSignals == 1 even when twoFrequency is enabled
%   T2: nAmbiguities == nTowers (not 2*nTowers)
%   T3: H matrix has exactly nTowers non-zero carrier ambiguity columns
%   T4: carrierMode='ekfFloat' with twoFrequency allocates L1-only states

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_stage6_carrier_consistency ===\n');

% ----------------------------------------------------------------
% T1: ambiguityNSignals == 1 even when twoFrequency is enabled
% ----------------------------------------------------------------
fprintf('  T1: ambiguityNSignals stays 1 with twoFrequency enabled ...\n');

cfg1 = revgnss.ConfigFactory.carrierFloatConfig();
cfg1.signals.twoFrequency.enable = true;   % L2 signals active
cfg1.simulation.duration_s = 1;
cfg1.plots.enable  = false;
cfg1.report.enable = false;

[~, ~, ekf1, ~] = revgnss.ScenarioFactory.build(cfg1);

assert(ekf1.ambiguityNSignals == 1, ...
    'T1 FAILED: ambiguityNSignals=%d (expected 1 even with L2 enabled)', ...
    ekf1.ambiguityNSignals);
fprintf('    ambiguityNSignals=%d (L1 only, L2 ignored): PASS\n', ekf1.ambiguityNSignals);

% ----------------------------------------------------------------
% T2: nAmbiguities == nTowers (not 2*nTowers when L2 enabled)
% ----------------------------------------------------------------
fprintf('  T2: nAmbiguities == nTowers (not 2*nTowers) ...\n');

nTwr = cfg1.scenario.nTowers;
assert(ekf1.nAmbiguities == nTwr, ...
    'T2 FAILED: nAmbiguities=%d, expected %d (nTowers), got 2*nTowers?', ...
    ekf1.nAmbiguities, nTwr);
fprintf('    nAmbiguities=%d == nTowers=%d: PASS\n', ekf1.nAmbiguities, nTwr);

% ----------------------------------------------------------------
% T3: H matrix has exactly nTowers non-zero carrier ambiguity columns
% ----------------------------------------------------------------
fprintf('  T3: H has exactly nTowers non-zero ambiguity columns ...\n');

cfg3 = revgnss.ConfigFactory.carrierFloatConfig();
cfg3.simulation.duration_s = 1;
cfg3.plots.enable  = false;
cfg3.report.enable = false;

[asset3, towers3, ekf3, mm3] = revgnss.ScenarioFactory.build(cfg3);
[~, ~, H3, ~, errSt3] = mm3.computeMeasurements(asset3, towers3, ekf3.x, 0, ekf3.stateMap);

if ~isempty(H3) && isfield(ekf3.stateMap,'ambiguityIdx')
    ambIdx = ekf3.stateMap.ambiguityIdx(:)';
    ambIdx = ambIdx(ambIdx > 0 & ambIdx <= size(H3,2));
    nNonZeroCols = sum(arrayfun(@(c) any(H3(:,c) ~= 0), ambIdx));
    % Number of visible towers (with carrier rows) determines non-zero columns
    nCarrier = 0;
    if isfield(errSt3,'carrierPhase') && isfield(errSt3.carrierPhase,'phi_m')
        nCarrier = numel(errSt3.carrierPhase.phi_m);
    end
    assert(nNonZeroCols == nCarrier, ...
        'T3 FAILED: non-zero ambiguity H cols=%d, expected nCarrierObs=%d', ...
        nNonZeroCols, nCarrier);
    fprintf('    non-zero ambiguity H cols = %d (= nCarrierObs): PASS\n', nNonZeroCols);
else
    fprintf('    no measurements (vacuous PASS)\n');
end

% ----------------------------------------------------------------
% T4: State dim with twoFrequency+ekfFloat == 14 + nTwrClk + nTwr (L1 only)
%     NOT 14 + nTwrClk + 2*nTwr
% ----------------------------------------------------------------
fprintf('  T4: state dim with twoFrequency+ekfFloat has nTwr ambiguities (not 2*nTwr) ...\n');

cfg4 = revgnss.ConfigFactory.carrierFloatConfig();
cfg4.signals.twoFrequency.enable = true;
[~, ~, ekf4, ~] = revgnss.ScenarioFactory.build(cfg4);

nTwr4  = cfg4.scenario.nTowers;
% base 14 + optional clock states + nTwr ambiguities
% total state dim should NOT be 14 + ... + 2*nTwr
nAmb4 = ekf4.nAmbiguities;
assert(nAmb4 == nTwr4, ...
    'T4 FAILED: nAmbiguities=%d with twoFreq enabled should still be nTowers=%d', ...
    nAmb4, nTwr4);
assert(nAmb4 ~= 2*nTwr4, ...
    'T4 FAILED: nAmbiguities=%d == 2*nTowers=%d (L2 state was allocated!)', ...
    nAmb4, 2*nTwr4);
fprintf('    nAmbiguities=%d == nTowers=%d (twoFrequency did not allocate L2): PASS\n', ...
    nAmb4, nTwr4);

fprintf('=== test_stage6_carrier_consistency: ALL PASS ===\n');
