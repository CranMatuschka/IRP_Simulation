% test_battery_label_semantics
%
% Battery group names and manifest fields must describe active physics:
%   baseline  : realism off, realistic atmosphere
%   idealised : realism off, matched atmosphere
%   realism   : realism-grade or honest-covariance overlay

thisDir = fileparts(mfilename('fullpath'));
ooRoot = fileparts(thisDir);
addpath(ooRoot);
addpath(fullfile(ooRoot, 'config'));

fprintf('=== test_battery_label_semantics ===\n');

tmpRoot = tempname();
mkdir(tmpRoot);
cleanup = onCleanup(@() cleanupDir_(tmpRoot)); %#ok<NASGU>

mBase = run_oo_v1_battery('Duration', 1, 'Towers', 5, 'SR', {[1 1]}, 'TW', 0, ...
    'Realism', false, 'Atmosphere', 'realistic', 'WritePdf', false, ...
    'Analyze', false, 'OutRoot', tmpRoot, 'DryRun', true);
assert(strcmp(mBase(1).runClass, 'baseline'), 'T1 FAILED: default-atmosphere runClass must be baseline.');
assert(strcmp(mBase(1).groupName, 'Battery_baseline'), ...
    'T1 FAILED: default-atmosphere non-realism run must use Battery_baseline.');
assert(~contains(mBase(1).groupName, 'idealised'), ...
    'T1 FAILED: realistic atmosphere must not be labelled idealised.');
assert(strcmp(mBase(1).atmosphereMode, 'realistic'), 'T1 FAILED: atmosphereMode missing.');
fprintf('  T1 realistic non-realism -> Battery_baseline: PASS\n');

mIdeal = run_oo_v1_battery('Duration', 1, 'Towers', 5, 'SR', {[1 1]}, 'TW', 0, ...
    'Realism', false, 'Atmosphere', 'matched', 'WritePdf', false, ...
    'Analyze', false, 'OutRoot', tmpRoot, 'DryRun', true);
assert(strcmp(mIdeal(1).runClass, 'idealised'), 'T2 FAILED: matched-atmosphere runClass must be idealised.');
assert(strcmp(mIdeal(1).groupName, 'Battery_idealised'), ...
    'T2 FAILED: matched-atmosphere run must use Battery_idealised.');
fprintf('  T2 matched atmosphere -> Battery_idealised: PASS\n');

mReal = run_oo_v1_battery('Duration', 1, 'Towers', 5, 'SR', {[1 1]}, 'TW', 0, ...
    'Realism', true, 'Atmosphere', 'realistic', 'WritePdf', false, ...
    'Analyze', false, 'OutRoot', tmpRoot, 'DryRun', true);
assert(strcmp(mReal(1).runClass, 'realism'), 'T3 FAILED: realism runClass must be realism.');
assert(strcmp(mReal(1).groupName, 'Battery_realism'), ...
    'T3 FAILED: realism run must use Battery_realism.');
fprintf('  T3 realism-grade -> Battery_realism: PASS\n');

mTw = run_oo_v1_battery('Duration', 1, 'Towers', 5, 'SR', {[1 1]}, 'TW', [0 1], ...
    'Realism', false, 'Atmosphere', 'realistic', 'WritePdf', false, ...
    'Analyze', false, 'OutRoot', tmpRoot, 'DryRun', true);
assert(numel(mTw) == 2, 'T4 FAILED: expected two TW dry-run manifest rows.');
assert(~mTw(1).twoWayTimeTransferInEkf && mTw(2).twoWayTimeTransferInEkf, ...
    'T4 FAILED: manifest twoWayTimeTransferInEkf must track the active TWTT EKF switch.');
assert(all(~[mTw.twstftDiagnosticsEnabled]), ...
    'T4 FAILED: TWSTFT diagnostics should remain separate from active TWTT by default.');
assert(isfield(mTw, 'runClass') && isfield(mTw, 'atmosphereMode') && ...
       isfield(mTw, 'twoWayTimeTransferInEkf') && isfield(mTw, 'twstftDiagnosticsEnabled'), ...
       'T4 FAILED: required manifest semantic fields missing.');
fprintf('  T4 manifest active TWTT and diagnostic TWSTFT fields: PASS\n');

fprintf('=== test_battery_label_semantics: ALL PASS ===\n');

function cleanupDir_(pathToRemove)
try
    if isfolder(pathToRemove)
        rmdir(pathToRemove, 's');
    end
catch
end
end
