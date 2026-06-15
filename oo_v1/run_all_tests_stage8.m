function run_all_tests_stage8()
% run_all_tests_stage8  Run all tests in tests/ folder and report pass/fail.
%
% Uses a helper function (runSingle_) so that test scripts that call
% 'clear' only affect the helper's local workspace, not this runner.

addpath(pwd);
testDir = fullfile(pwd,'tests');
addpath(testDir);

files = dir(fullfile(testDir,'test_*.m'));
nPass = 0; nFail = 0; failList = {};

for k = 1:numel(files)
    tName = files(k).name(1:end-2);
    try
        runSingle_(tName);
        nPass = nPass + 1;
    catch ME
        nFail = nFail + 1;
        msg = ME.message;
        if numel(msg) > 120; msg = msg(1:120); end
        failList{end+1} = sprintf('%s: %s', tName, msg); %#ok<AGROW>
    end
end

fprintf('\n=== RESULTS: %d pass, %d fail ===\n', nPass, nFail);
for k = 1:numel(failList)
    fprintf('  FAIL: %s\n', failList{k});
end
if nFail > 0
    error('run_all_tests_stage8:failures', '%d test(s) failed.', nFail);
end
end

function runSingle_(name)
% Isolated scope: clear in the test only wipes this function's workspace.
feval(name);
end
