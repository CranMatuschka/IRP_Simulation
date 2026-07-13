% test_default_attitude_resolution
% WP-1/WP-11: the resolved DEFAULT config exercises the >=4-antenna attitude
% objective, and the single-antenna knob (nReceivers=1) still resolves to
% attitude OFF. Asserts on the RESOLVED config (post-finalizeConfig), because
% finalizeConfig is where the literal masterConfig value is turned into the
% operative attitude/lever-arm state.
%
% Verifies:
%   - default:        nReceivers==4, estimateAttitude==true, non-zero lever arm,
%                     4-column lever-arm cross present
%   - nReceivers=1:   estimateAttitude==false, zero lever arm (knob still works)

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));
addpath(fullfile(thisDir, '..', 'config'));

fprintf('=== test_default_attitude_resolution ===\n');

% --- Resolved DEFAULT: 4-antenna cross, attitude ON -------------------------
cfg = masterConfig();
cfg.report.writePdf   = false; cfg.report.writeMat = false;
cfg.report.compileTex = 'never'; cfg.plots.showFigures = false;
res = revgnss.ConfigFactory.finalizeConfig(cfg);

assert(res.scenario.nReceivers == 4, ...
    'Resolved default nReceivers=%d, expected 4 (WP-1).', res.scenario.nReceivers);
assert(islogical(res.estimator.estimateAttitude) && res.estimator.estimateAttitude, ...
    'Resolved default estimateAttitude must be true (the attitude objective).');
arm = res.asset.receiverLeverArm_body_m;
assert(norm(arm) > 0, ...
    'Resolved default lever arm must be non-zero; got [%g %g %g].', arm(1), arm(2), arm(3));
assert(size(res.asset.receiverLeverArms_body_m, 2) == 4, ...
    'Resolved default must carry a 4-column lever-arm cross (got %d columns).', ...
    size(res.asset.receiverLeverArms_body_m, 2));
fprintf('  default: nReceivers=4, attitude ON, |leverArm(:,1)|=%.3f m\n', norm(arm));

% --- Single-antenna knob: nReceivers=1 -> attitude OFF ----------------------
cfg1 = masterConfig();
cfg1.report.writePdf   = false; cfg1.report.writeMat = false;
cfg1.report.compileTex = 'never'; cfg1.plots.showFigures = false;
cfg1.scenario.nReceivers = 1;
res1 = revgnss.ConfigFactory.finalizeConfig(cfg1);

assert(res1.scenario.nReceivers == 1, ...
    'nReceivers=1 knob did not hold (got %d).', res1.scenario.nReceivers);
assert(~res1.estimator.estimateAttitude, ...
    'nReceivers=1 must resolve estimateAttitude=false.');
assert(norm(res1.asset.receiverLeverArm_body_m) == 0, ...
    'nReceivers=1 must resolve a zero lever arm.');
fprintf('  knob:    nReceivers=1, attitude OFF, zero lever arm\n');

fprintf('  PASS\n');
