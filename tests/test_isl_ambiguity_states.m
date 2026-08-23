% test_isl_ambiguity_states
% Phase 1b (feature/ISL-LAMBDA): ISL carrier-ambiguity states in the EKF.
%
% Proves:
%   T1  default OFF -> nx and the state map are byte-identical to the pre-ISL layout
%   T2  enabling allocates exactly nLinks*nSignals states, appended strictly LAST
%   T3  P0 is seeded from the ISL sigma (NOT left at 0, which would freeze the state)
%   T4  the ISL sigma is INDEPENDENT of the ground ambiguity sigma (both directions)
%   T5  the nx arithmetic and the state-map walk agree (the new consistency assert)
%   T6  nSpaceAssets=1 -> no ISL links -> no states even when the flag is on
%
% The ambiguity is stored in METRES, so a carrier row's Jacobian column is +1.

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_isl_ambiguity_states ===\n');

% Helper: a swarm config with ISL enabled; ambiguity gate controlled by the caller.
i_islCfg = @(ambOn, nSats) i_buildIslCfg(ambOn, nSats);

% ----------------------------------------------------------------
% T1: default OFF is inert (no ISL states, flag false)
% ----------------------------------------------------------------
fprintf('  T1: default OFF allocates no ISL states ...\n');

cfg_off = i_islCfg(false, 6);
[~, ~, ekf_off] = revgnss.ScenarioFactory.build(cfg_off);

assert(~ekf_off.estimateIslAmbiguities, 'T1 FAILED: estimateIslAmbiguities true when gate off');
assert(ekf_off.nIslAmbiguities == 0, 'T1 FAILED: nIslAmbiguities=%d, expected 0', ...
    ekf_off.nIslAmbiguities);
assert(isfield(ekf_off.stateMap,'islAmbiguityIdx') && isempty(ekf_off.stateMap.islAmbiguityIdx), ...
    'T1 FAILED: islAmbiguityIdx not the empty sentinel when off');
nx_off = ekf_off.nx;
fprintf('    nx=%d, no ISL states, empty sentinel: PASS\n', nx_off);

% ----------------------------------------------------------------
% T2: enabling appends exactly nLinks*nSignals states, strictly LAST
% ----------------------------------------------------------------
fprintf('  T2: enabling appends nLinks*nSignals states at the END ...\n');

cfg_on = i_islCfg(true, 6);
[~, ~, ekf_on] = revgnss.ScenarioFactory.build(cfg_on);

nLinks_exp = numel(revgnss.ISLMeasurementBuilder.transmitterList(cfg_on));
assert(nLinks_exp > 0, 'T2 FAILED: expected >0 ISL links for nSpaceAssets=6');
assert(ekf_on.estimateIslAmbiguities, 'T2 FAILED: estimateIslAmbiguities false when gate on');
assert(ekf_on.nIslAmbiguities == nLinks_exp, ...
    'T2 FAILED: nIslAmbiguities=%d, expected %d links', ekf_on.nIslAmbiguities, nLinks_exp);

islIdx_on = ekf_on.stateMap.islAmbiguityIdx;
assert(numel(islIdx_on) == nLinks_exp, 'T2 FAILED: islAmbiguityIdx has %d entries, expected %d', ...
    numel(islIdx_on), nLinks_exp);

% nx grew by exactly the ISL block, and the block occupies the TOP of the vector.
assert(ekf_on.nx == nx_off + nLinks_exp, ...
    'T2 FAILED: nx %d -> %d, expected +%d', nx_off, ekf_on.nx, nLinks_exp);
assert(max(islIdx_on(:)) == ekf_on.nx, ...
    'T2 FAILED: highest ISL index %d != nx %d (block is not last)', ...
    max(islIdx_on(:)), ekf_on.nx);
assert(min(islIdx_on(:)) == nx_off + 1, ...
    'T2 FAILED: lowest ISL index %d != nx_off+1 %d (block does not start after the old end)', ...
    min(islIdx_on(:)), nx_off + 1);
fprintf('    %d links, nx %d -> %d, indices %d..%d strictly last: PASS\n', ...
    nLinks_exp, nx_off, ekf_on.nx, min(islIdx_on(:)), max(islIdx_on(:)));

% ----------------------------------------------------------------
% T3: P0 seeded from the ISL sigma (a zero here would freeze the state)
% ----------------------------------------------------------------
fprintf('  T3: P0 uses the ISL initialSigma_m ...\n');

sig_isl = cfg_on.measurements.isl.carrier.ambiguity.initialSigma_m;
for k_t3 = 1:numel(islIdx_on)
    idx_t3 = islIdx_on(k_t3);
    p_t3   = ekf_on.P(idx_t3, idx_t3);
    assert(abs(p_t3 - sig_isl^2) < 1e-9, ...
        'T3 FAILED: P0(%d,%d)=%.6g, expected %.6g (sigma=%g)', ...
        idx_t3, idx_t3, p_t3, sig_isl^2, sig_isl);
end
fprintf('    P0 = (%g m)^2 on all %d ISL states: PASS\n', sig_isl, numel(islIdx_on));

% ----------------------------------------------------------------
% T4: ISL and GROUND ambiguity sigmas are INDEPENDENT (both directions)
% ----------------------------------------------------------------
fprintf('  T4: ISL sigma independent of the ground ambiguity sigma ...\n');

cfg_ind = i_islCfg(true, 6);
cfg_ind.measurements.carrierMode                      = 'ekfFloat';
cfg_ind.estimation.ambiguityMode                      = 'floatPerTowerSignal';
cfg_ind.estimation.ambiguity.initialSigma_m           = 55;    % ground
cfg_ind.measurements.isl.carrier.ambiguity.initialSigma_m = 190;  % ISL, deliberately different

[~, ~, ekf_ind] = revgnss.ScenarioFactory.build(cfg_ind);
sm_ind = ekf_ind.stateMap;

% ISL states carry the ISL sigma...
islIdx_ind = sm_ind.islAmbiguityIdx;
assert(~isempty(islIdx_ind), 'T4 FAILED: no ISL states allocated');
for k_t4 = 1:numel(islIdx_ind)
    p_t4 = ekf_ind.P(islIdx_ind(k_t4), islIdx_ind(k_t4));
    assert(abs(p_t4 - 190^2) < 1e-9, ...
        'T4 FAILED: ISL P0=%.6g, expected %.6g (ground sigma leaked in?)', p_t4, 190^2);
end
% ...and the GROUND states still carry the ground sigma.
gndIdx_ind = sm_ind.ambiguityIdx(sm_ind.ambiguityIdx > 0);
assert(~isempty(gndIdx_ind), 'T4 FAILED: no ground ambiguity states to compare against');
for k_t4b = 1:numel(gndIdx_ind)
    p_t4b = ekf_ind.P(gndIdx_ind(k_t4b), gndIdx_ind(k_t4b));
    assert(abs(p_t4b - 55^2) < 1e-9, ...
        'T4 FAILED: ground P0=%.6g, expected %.6g (ISL sigma leaked in?)', p_t4b, 55^2);
end
% The two families must not share a single state index.
assert(isempty(intersect(islIdx_ind(:), gndIdx_ind(:))), ...
    'T4 FAILED: ISL and ground ambiguity index sets overlap');
fprintf('    ground=(55 m)^2 on %d states, ISL=(190 m)^2 on %d states, disjoint: PASS\n', ...
    numel(gndIdx_ind), numel(islIdx_ind));

% ----------------------------------------------------------------
% T5: nx arithmetic == state-map walk (the new consistency assert)
% ----------------------------------------------------------------
fprintf('  T5: nx arithmetic agrees with the state-map walk ...\n');

% ScenarioFactory.build would have thrown ReverseGNSSEKF:stateMapSizeMismatch if the
% two implementations disagreed; assert the sizes actually line up as well.
assert(size(ekf_ind.P,1) == ekf_ind.nx && numel(ekf_ind.x) == ekf_ind.nx, ...
    'T5 FAILED: P is %dx%d and x is %d for nx=%d', ...
    size(ekf_ind.P,1), size(ekf_ind.P,2), numel(ekf_ind.x), ekf_ind.nx);
allIdx_t5 = [islIdx_ind(:); gndIdx_ind(:)];
assert(all(allIdx_t5 >= 1 & allIdx_t5 <= ekf_ind.nx), ...
    'T5 FAILED: an ambiguity index falls outside [1, nx=%d]', ekf_ind.nx);
fprintf('    nx=%d consistent across x, P and both index families: PASS\n', ekf_ind.nx);

% ----------------------------------------------------------------
% T6: no ISL links (single asset) -> no states even with the flag ON
% ----------------------------------------------------------------
fprintf('  T6: nSpaceAssets=1 -> no ISL states despite the flag ...\n');

cfg_solo = i_islCfg(true, 1);
[~, ~, ekf_solo] = revgnss.ScenarioFactory.build(cfg_solo);
assert(ekf_solo.nIslAmbiguities == 0, ...
    'T6 FAILED: nIslAmbiguities=%d for a single asset', ekf_solo.nIslAmbiguities);
assert(~ekf_solo.estimateIslAmbiguities, 'T6 FAILED: estimateIslAmbiguities true with no links');
fprintf('    single asset -> 0 ISL states: PASS\n');

fprintf('=== test_isl_ambiguity_states: ALL PASS ===\n');

% ----------------------------------------------------------------
function cfg = i_buildIslCfg(ambOn, nSats)
    cfg = revgnss.ConfigFactory.defaultConfig();
    cfg.plots.enable  = false;
    cfg.report.enable = false;
    cfg.scenario.nSpaceAssets = nSats;
    if nSats >= 2
        cfg.measurements.isl.enable       = true;
        cfg.measurements.isl.transmitters = 'all';
        cfg.measurements.isl.receiverAssetIndex = 1;
        cfg.measurements.isl.code.enable  = true;
    end
    cfg.measurements.isl.carrier.enable            = true;
    cfg.measurements.isl.carrier.useInEKF          = false;  % Phase 1c flips this
    cfg.measurements.isl.carrier.ambiguity.enable  = ambOn;
    cfg.measurements.isl.carrier.ambiguity.nSignals = 1;
    cfg.measurements.isl.carrier.ambiguity.initialSigma_m = 100;
end
