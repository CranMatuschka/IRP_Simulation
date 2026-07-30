% test_default_attitude_resolution
% The nominal profile estimates attitude from the star tracker and gyro with
% one co-located GNSS antenna. Four antennas remain an explicit lever-arm mode.
%
% Verifies:
%   - default:      one zero lever arm, sensor-based attitude active
%   - nReceivers=4: non-coplanar four-point geometry with attitude active

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));
addpath(fullfile(thisDir, '..', 'config'));

fprintf('=== test_default_attitude_resolution ===\n');

% --- Resolved nominal profile: one GNSS antenna, sensor attitude ----------
cfg = masterConfig();
cfg.report.writePdf   = false; cfg.report.writeMat = false;
cfg.report.compileTex = 'never'; cfg.plots.showFigures = false;
res = revgnss.ConfigFactory.finalizeConfig(cfg);

assert(res.scenario.nReceivers == 1, ...
    'Resolved nominal nReceivers=%d, expected 1.', res.scenario.nReceivers);
assert(islogical(res.estimator.estimateAttitude) && res.estimator.estimateAttitude, ...
    'Resolved nominal attitude estimation must be active.');
arm = res.asset.receiverLeverArm_body_m;
assert(norm(arm) == 0 && res.estimator.starTracker.enable && ...
    res.estimator.starTracker.useInEKF && res.estimator.imu.enable, ...
    'Nominal attitude must use the star tracker and gyro, not a GNSS lever arm.');
fprintf('  nominal: nReceivers=1, star tracker + gyro, zero lever arm\n');

% --- Explicit four-antenna mode -------------------------------------------
cfg4 = masterConfig();
cfg4.report.writePdf   = false; cfg4.report.writeMat = false;
cfg4.report.compileTex = 'never'; cfg4.plots.showFigures = false;
cfg4.scenario.nReceivers = 4;
res4 = revgnss.ConfigFactory.finalizeConfig(cfg4);

arms4 = res4.asset.receiverLeverArms_body_m;
assert(res4.scenario.nReceivers == 4 && size(arms4,2) == 4 && ...
    rank(arms4-mean(arms4,2),1e-12) == 3 && ...
    res4.estimator.estimateAttitude, ...
    'The explicit four-antenna mode is not non-coplanar and attitude-active.');
fprintf('  explicit: nReceivers=4, non-coplanar lever-arm geometry\n');

fprintf('  PASS\n');
