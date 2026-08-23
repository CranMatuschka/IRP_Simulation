% test_stage36_attitude_scenario_readiness  Smoke tests for Stage 36.
%
% T1: One receiver / zero lever arm -> not-ready-single-receiver or not-ready-zero-lever-arm.
% T2: Two receivers, nonzero lever arms -> weak-two-receiver-baseline or diagnostic-ready,
%     but NOT carrier-float-ready (carrier not active in T2 cfg).
% T3: Three non-collinear receivers + carrier float -> diagnostic-ready or carrier-float-ready,
%     but never 'fixed', 'precise', or 'operational' in classification string.
% T4: ReportStatus stage >= 36.

fprintf('test_stage36_attitude_scenario_readiness\n');

c1 = struct(); c2 = struct(); c3 = struct();

% --- T1: single receiver -> early readiness failure ---
c1.scenario.nReceivers = 1;
c1.asset.receiverLeverArm_body_m = [0; 0; 0];
s1 = revgnss.AttitudeScenarioReadiness.assess(struct(), c1);
earlyFail = {'not-ready-single-receiver', 'not-ready-zero-lever-arm', 'unavailable'};
assert(ismember(s1.classification, earlyFail), ...
    sprintf('T1: expected early-failure class, got ''%s''', s1.classification));
assert(s1.readyLevel <= 1, sprintf('T1: readyLevel should be <= 1, got %d', s1.readyLevel));
fprintf('T1 PASS: single/zero-lever cfg -> class=''%s''\n', s1.classification);

% --- T2: two nonzero receivers, no carrier -> not carrier-float-ready ---
c2.scenario.nReceivers = 2;
c2.asset.receiverLeverArms_body_m = [1 -1; 0 0; 0 0];  % 3x2, nonzero but collinear -> rank 1
s2 = revgnss.AttitudeScenarioReadiness.assess(struct(), c2);
forbidden2 = 'carrier-float-ready';
assert(~strcmp(s2.classification, forbidden2), ...
    sprintf('T2: should not be carrier-float-ready without carrier cfg, got ''%s''', s2.classification));
assert(s2.nReceivers == 2, sprintf('T2: nReceivers should be 2, got %d', s2.nReceivers));
fprintf('T2 PASS: two receivers, no carrier -> class=''%s'' (not carrier-float-ready)\n', s2.classification);

% --- T3: three non-collinear + carrier float -> diagnostic-ready or carrier-float-ready ---
c3.scenario.nReceivers = 3;
c3.asset.receiverLeverArms_body_m = [1 -1 0; 0.5 0.5 -1; 0 0 0];
c3.measurements.carrierPhase.enable = true;
c3.measurements.carrierMode         = 'ekfFloat';
c3.estimation.ambiguityMode         = 'floatPerTowerReceiverSignal';
c3.estimator.attitudeCarrierMode    = 'calibratedDifferentialAmbiguity';
c3.estimator.runKnownAmbiguityValidation = false;
s3 = revgnss.AttitudeScenarioReadiness.assess(struct(), c3);
allowed3 = {'diagnostic-ready', 'carrier-float-ready', 'weak-two-receiver-baseline', ...
            'validation-known-ambiguity-only', 'weak-code-only'};
assert(ismember(s3.classification, allowed3), ...
    sprintf('T3: unexpected classification ''%s''', s3.classification));
% Never claims fixed / precise / operational
badWords = {'fixed', 'precise', 'operational'};
for bw = 1:numel(badWords)
    assert(~contains(s3.classification, badWords{bw}), ...
        sprintf('T3: classification ''%s'' contains forbidden word ''%s''', ...
        s3.classification, badWords{bw}));
end
assert(s3.receiverGeometryRank >= 2, ...
    sprintf('T3: expected geometry rank >= 2, got %d', s3.receiverGeometryRank));
fprintf('T3 PASS: 3 receivers + carrier -> class=''%s'', rank=%d\n', ...
    s3.classification, s3.receiverGeometryRank);

% --- T4: ReportStatus stage >= 36 ---
rs = revgnss.ReportStatus.current();
assert(str2double(char(rs.stage)) >= 36, ...
    sprintf('T4: stage should be >= 36, got ''%s''', char(rs.stage)));
fprintf('T4 PASS: ReportStatus.current().stage = ''%s'' (>= 36)\n', char(rs.stage));

fprintf('\ntest_stage36_attitude_scenario_readiness: all 4 tests passed.\n');
