function run_all_tests()
% run_all_tests  Run every test_*.m in the tests/ directory.
%
% Each test is run via evalin('base',...) so that workspace mutations by
% the test script (or scripts it invokes via evalc/run) cannot affect the
% loop's function-local variables.
addpath(genpath('.'));
tmp  = dir(fullfile('tests', 'test_*.m'));
names = cellfun(@(f) f(1:end-2), {tmp.name}, 'UniformOutput', false);
nPass = 0; nFail = 0; failed = {};
for k = 1:numel(names)
    name = names{k};
    [ok, msg] = runOneTest_(name);
    if ok
        nPass = nPass + 1;
    else
        nFail = nFail + 1;
        failed{end+1} = sprintf('%s: %s', name, msg);
    end
end
fprintf('\n=== TOTAL: %d / %d passed ===\n', nPass, nPass + nFail);
for k = 1:numel(failed)
    fprintf('FAIL: %s\n', failed{k});
end
end

function [ok, msg] = runOneTest_(name)
% runOneTest_  Execute one test in the base workspace.
%
% evalin('base',...) runs the script in the base workspace.  Any variable
% modifications by the script (or by sub-scripts it runs) stay in the base
% workspace and cannot overwrite ok/msg in this function's workspace.
ok = true; msg = '';
try
    evalin('base', name);
catch e
    ok = false;
    msg = e.message;
    if numel(msg) > 160; msg = msg(1:160); end
end
end
