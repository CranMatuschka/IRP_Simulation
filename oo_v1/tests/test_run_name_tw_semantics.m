% test_run_name_tw_semantics
%
% The TW# run-name tag is reserved for active two-way time-transfer EKF rows.
% TWSTFT diagnostics are a separate switch and must not produce TW1 by themselves.

thisDir = fileparts(mfilename('fullpath'));
ooRoot = fileparts(thisDir);
addpath(ooRoot);
addpath(fullfile(ooRoot, 'config'));

fprintf('=== test_run_name_tw_semantics ===\n');

cfg = revgnss.ConfigFactory.defaultConfig();
cfg.scenario.nTowers = 5;
cfg.scenario.nSpaceAssets = 1;
cfg.scenario.nReceivers = 4;
cfg.simulation.duration_s = 120;

cfg.measurements.twstft.enable = true;
cfg.measurements.twoWayTimeTransfer.enable = false;
cfg.measurements.twoWayTimeTransfer.useInEKF = false;
[folder0, stem0, tw0] = revgnss.RunLabelUtils.reportNameParts(cfg, 'v777');
assert(~tw0, 'T1 FAILED: TWSTFT diagnostics alone must not set TW active.');
assert(contains(folder0, '_TW0') && contains(stem0, '_TW0'), ...
    'T1 FAILED: inactive TWTT EKF path must produce TW0 report names.');
assert(revgnss.RunLabelUtils.twstftDiagnosticsEnabled(cfg), ...
    'T1 FAILED: diagnostic TWSTFT switch should still be discoverable separately.');
fprintf('  T1 TWSTFT diagnostic switch alone -> TW0: PASS\n');

cfg.measurements.twoWayTimeTransfer.enable = true;
cfg.measurements.twoWayTimeTransfer.useInEKF = false;
[folderUse0, stemUse0, twUse0] = revgnss.RunLabelUtils.reportNameParts(cfg, 'v777');
assert(~twUse0, 'T2 FAILED: enabled-but-not-in-EKF TWTT must not set TW active.');
assert(contains(folderUse0, '_TW0') && contains(stemUse0, '_TW0'), ...
    'T2 FAILED: TWTT disabled from EKF must produce TW0 report names.');
fprintf('  T2 TWTT enable=true/useInEKF=false -> TW0: PASS\n');

cfg.measurements.twoWayTimeTransfer.useInEKF = true;
[folder1, stem1, tw1] = revgnss.RunLabelUtils.reportNameParts(cfg, 'v777');
assert(tw1, 'T3 FAILED: active TWTT EKF rows must set TW active.');
assert(contains(folder1, '_TW1') && contains(stem1, '_TW1'), ...
    'T3 FAILED: active TWTT EKF path must produce TW1 report names.');
fprintf('  T3 TWTT enable=true/useInEKF=true -> TW1: PASS\n');

runSrc = fileread(fullfile(ooRoot, 'run_oo_v1.m'));
assert(contains(runSrc, 'RunLabelUtils.reportNameParts'), ...
    'T4 FAILED: run_oo_v1 must use the shared semantic report-name helper.');
assert(~contains(runSrc, 'cfg.measurements.twstft.enable'), ...
    'T4 FAILED: run_oo_v1 must not derive TW tags from the TWSTFT diagnostic switch.');
fprintf('  T4 run_oo_v1 uses semantic TW naming helper: PASS\n');

fprintf('=== test_run_name_tw_semantics: ALL PASS ===\n');
