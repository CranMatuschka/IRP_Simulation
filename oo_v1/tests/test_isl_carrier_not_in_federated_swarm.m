% test_isl_carrier_not_in_federated_swarm
% Phase 3-5 (feature/ISL-LAMBDA): pins WHERE the ISL carrier work is and is not active.
%
% WHY THIS TEST EXISTS -- it prevents a silent misreading of swarm results.
%
% There are two multi-asset paths and they treat ISL oppositely:
%
%   1. SINGLE-ASSET AIDED (revgnss.ReverseGNSSSimulation directly). One estimated asset,
%      aided by represented secondaries. The ISL carrier row, ambiguity states, arcs and
%      Route-B AR from this feature ARE active here.
%
%   2. FEDERATED SWARM (revgnss.ReportRunner, i.e. what run_oo_v1 produces for
%      nSpaceAssets > 1). ReportRunner.stripSwarmEstimation_ sets
%      measurements.isl.enable = false on EVERY per-asset EKF config, BY DESIGN: the
%      federated architecture keeps ground pseudoranges and the ISL relative
%      layer) on DISJOINT measurements so they cannot double-count
%      (see the SwarmRelativeSolver header). Consequently NONE of this feature's ISL
%      carrier machinery runs inside a federated swarm report.
%
% So a swarm PDF produced with cfg.measurements.isl.carrier.useInEKF = true does NOT
% contain any ISL carrier contribution. Reading its shape/baseline numbers as evidence
% that "the ISL carrier improved the formation" would be WRONG. This test makes that
% structural fact executable.
%
% It also records the second half of the reason the relative/shape benefit is currently
% unmeasurable: the secondary-asset EKF state blocks (secondaryOrbitIdx / secondaryClockIdx)
% were RETIRED with the federated pivot (ReverseGNSSEKF.m ~:636, "RETIRED ... W4-4b"), so a
% single EKF estimates exactly ONE asset position -- there is no multi-asset shape to
% observe from it either.
%
% Proves:
%   T1  the un-stripped config DOES want ISL ambiguity states
%   T2  stripSwarmEstimation_ removes them (isl.enable -> false)
%   T3  a per-asset EKF built from the stripped config has NO ISL ambiguity states
%   T4  the secondary-asset orbit/clock state blocks are absent (retired)

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir, '..');
addpath(rootDir); addpath(fullfile(rootDir, 'config'));

fprintf('=== test_isl_carrier_not_in_federated_swarm ===\n');

cfg = masterConfig();
cfg.scenario.nSpaceAssets = 4;
cfg.scenario.nReceivers   = 1;
cfg.measurements.isl.enable = true;
cfg.measurements.isl.transmitters = 'all';
cfg.measurements.isl.receiverAssetIndex = 1;
cfg.measurements.isl.code.enable    = true;  cfg.measurements.isl.code.useInEKF    = true;
cfg.measurements.isl.carrier.enable = true;  cfg.measurements.isl.carrier.useInEKF = true;
cfg.measurements.isl.carrier.ambiguity.enable = true;
cfg.measurements.isl.warmup_s = 300;

% ----------------------------------------------------------------
% T1: un-stripped config wants ISL ambiguity states
% ----------------------------------------------------------------
fprintf('  T1: un-stripped config wants ISL ambiguity states ...\n');

nWant = revgnss.ISLMeasurementBuilder.ambiguityStateCount(cfg);
assert(nWant > 0, 'T1 FAILED: expected > 0 ISL ambiguity states, got %d', nWant);
fprintf('    %d states wanted (single-asset aided path): PASS\n', nWant);

% ----------------------------------------------------------------
% T2: the federated strip disables ISL
% ----------------------------------------------------------------
fprintf('  T2: stripSwarmEstimation_ disables ISL ...\n');

cStrip = revgnss.ReportRunner.stripSwarmEstimation_(cfg);
assert(~cStrip.measurements.isl.enable, ...
    'T2 FAILED: measurements.isl.enable survived the strip');
nWantStrip = revgnss.ISLMeasurementBuilder.ambiguityStateCount(cStrip);
assert(nWantStrip == 0, ...
    ['T2 FAILED: %d ISL ambiguity states still wanted after the strip. The gate must AND ' ...
     'on isl.enable so the feature degrades cleanly instead of half-running.'], nWantStrip);
fprintf('    isl.enable -> false, states wanted %d -> %d: PASS\n', nWant, nWantStrip);

% ----------------------------------------------------------------
% T3: a per-asset EKF from the stripped config has no ISL ambiguities
% ----------------------------------------------------------------
fprintf('  T3: per-asset EKF has no ISL ambiguity states ...\n');

cStrip.plots.enable = false; cStrip.report.enable = false;
[~, ~, ekfStrip] = revgnss.ScenarioFactory.build(cStrip);
assert(~ekfStrip.estimateIslAmbiguities, 'T3 FAILED: estimateIslAmbiguities true after strip');
assert(isempty(ekfStrip.stateMap.islAmbiguityIdx), 'T3 FAILED: islAmbiguityIdx not empty');
fprintf('    nx=%d, estimateIslAmbiguities=false, index empty: PASS\n', ekfStrip.nx);

% ----------------------------------------------------------------
% T4: secondary-asset state blocks are retired (no multi-asset shape in one EKF)
% ----------------------------------------------------------------
fprintf('  T4: secondary-asset orbit/clock state blocks are absent ...\n');

cPos = cfg; cPos.plots.enable = false; cPos.report.enable = false;
[~, ~, ekfPos] = revgnss.ScenarioFactory.build(cPos);
smPos = ekfPos.stateMap;
assert(~isfield(smPos,'secondaryOrbitIdx') || isempty(smPos.secondaryOrbitIdx), ...
    ['T4 FAILED: secondaryOrbitIdx is populated. If secondary orbits became estimable ' ...
     'again, a single-EKF formation shape IS observable and the relative/shape benefit ' ...
     'of the ISL carrier should be measured -- update this test and the plan appendix.']);
assert(~isfield(smPos,'secondaryClockIdx') || isempty(smPos.secondaryClockIdx), ...
    'T4 FAILED: secondaryClockIdx is populated (see the message above).');
fprintf('    no secondary orbit/clock states -> one estimated asset -> no shape: PASS\n');

fprintf('=== test_isl_carrier_not_in_federated_swarm: ALL PASS ===\n');
