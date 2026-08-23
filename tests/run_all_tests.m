function run_all_tests(mode)
% run_all_tests  Run the test_*.m files in tests/.
%
%   run_all_tests()        FAST tests only -- skips everything in i_slowTests_() (default)
%   run_all_tests('all')   every test, including the slow ones
%   run_all_tests('slow')  ONLY the slow ones
%
% Why a default skip: measured 2026-08-06, the full suite took 147 min and ONE test
% (test_main_script_creates_pdf_v4, a full end-to-end PDF build) accounted for 97 of them.
% A suite that costs 2.5 h does not get run, so it stops catching anything. The fast set is
% the one you run per change; the slow set is the one you run before a merge.
%
% The skip is always REPORTED, never silent -- see the SKIPPED line in the summary.
%
% THE PATH MUST NOT INCLUDE .claude/worktrees, AND THIS IS NOT HYGIENE.
% Measured 2026-08-05: a leftover git worktree at oo_v1/.claude/worktrees/sad-franklin-bc2f7e/
% held a full older copy of the tree, and a plain addpath(genpath('.')) made MATLAB resolve BOTH
% masterConfig AND run_all_tests itself to that copy -- so the suite silently tested the
% worktree. It surfaced only because the stale masterConfig had
% estimator.enforceCarrierArcConsistency.enable = true where the working tree has false, and
% ConfigFactory.finalizeConfig threw on configs that were perfectly valid. Had the two copies
% merely differed in a tolerance, the suite would have gone green while testing nothing.
% run_oo_v1 is unaffected: it adds only config/ explicitly.
%
% The same trap bites from INSIDE a test: measured 2026-08-06, three tests called
% addpath(genpath(repoRoot)) unfiltered, which prepends the worktree and makes every LATER
% test in the run resolve to the STALE copy of itself -- 48 bogus failures that all passed
% when re-run alone. If you add a genpath to a test, filter .claude the same way.
if nargin < 1 || isempty(mode); mode = 'fast'; end
mode = validatestring(mode, {'fast','all','slow'});

pathParts = strsplit(genpath(pwd), pathsep);
pathParts = pathParts(~cellfun(@isempty, pathParts));
pathParts = pathParts(~contains(pathParts, [filesep '.claude' filesep]));
addpath(strjoin(pathParts, pathsep));
resolved = which('masterConfig');
assert(contains(resolved, fullfile('config','masterConfig.m')) && ...
       ~contains(resolved, [filesep '.claude' filesep]), ...
    ['masterConfig resolved to %s. The path is shadowed -- a suite run from here would ' ...
     'test that copy, not this one. Remove the shadowing directory or run from the ' ...
     'repository root.'], resolved);

tmp   = dir(fullfile('tests', 'test_*.m'));
names = cellfun(@(f) f(1:end-2), {tmp.name}, 'UniformOutput', false);

[slowNames, slowSecs] = i_slowTests_();
% A slow entry naming a test that no longer exists is list rot -- say so rather than
% skipping something that silently stopped existing.
missing = slowNames(~ismember(slowNames, names));
for k = 1:numel(missing)
    warning('run_all_tests:staleSlowEntry', ...
        'i_slowTests_() lists "%s", which no longer exists in tests/. Remove it.', missing{k});
end

isSlow = ismember(names, slowNames);
switch mode
    case 'fast', run = ~isSlow;
    case 'slow', run =  isSlow;
    case 'all',  run = true(size(isSlow));
end

nPass = 0; nFail = 0; failed = {}; nSkip = 0; skipSecs = 0;
slowSeen = zeros(1, numel(names));
for k = 1:numel(names)
    name = names{k};
    if ~run(k)
        nSkip = nSkip + 1;
        % In 'slow' mode the skipped tests are the FAST ones, which carry no measured
        % cost -- guard, or skipSecs collapses to [] and the summary line breaks.
        iSlow_ = strcmp(slowNames, name);
        if any(iSlow_); skipSecs = skipSecs + slowSecs(iSlow_); end
        continue;
    end
    t0 = tic;
    [ok, msg] = runOneTest_(name);
    slowSeen(k) = toc(t0);
    if ok
        nPass = nPass + 1;
    else
        nFail = nFail + 1;
        failed{end+1} = sprintf('%s: %s', name, msg); %#ok<AGROW>
    end
end

fprintf('\n=== TOTAL: %d / %d passed ===\n', nPass, nPass + nFail);
if nSkip > 0
    fprintf('=== SKIPPED: %d slow tests (~%.0f min). Use run_all_tests(''all'') to include them. ===\n', ...
        nSkip, skipSecs/60);
end
for k = 1:numel(failed)
    fprintf('FAIL: %s\n', failed{k});
end

% Surface newly-slow tests so the list stays honest as the code grows.
thr = i_slowThresholdSeconds_();
newSlow = find(slowSeen >= thr & ~isSlow);
if ~isempty(newSlow)
    fprintf('\n=== NEWLY SLOW (>= %g s, not yet in i_slowTests_()) ===\n', thr);
    for k = newSlow
        fprintf('  %7.1f s  %s\n', slowSeen(k), names{k});
    end
end
end

% ---------------------------------------------------------------------------------
function s = i_slowThresholdSeconds_()
% A test at or above this is worth quarantining out of the per-change run.
s = 60;
end

function [names, secs] = i_slowTests_()
% Tests excluded from the default run, with their MEASURED wall-clock cost.
% Measured 2026-08-06 on the main checkout, one test per fresh filtered path.
% Keep this sorted by cost. To re-measure, time each test with tic/toc around evalin.
% Measured full sweep: 339 tests, 54.7 min EXCLUDING test_main_script_creates_pdf_v4.
% These 11 are 3.2% of the tests and ~116 min of the ~152 min total. Quarantining them
% takes the default run to ~36 min; the other 328 tests average 6.5 s each.
tbl = {
% name                                        seconds  why it costs what it costs
  'test_main_script_creates_pdf_v4'            5820   % end-to-end ReportRunner.runSingle + PDF build
  'test_scenario_override_invariance'           199   % resolves EVERY scenario JSON and diffs owned leaves
  'test_report_pdf_created'                     160   % full report build
  'test_report_works_for_iono_free'             140   % full report build, iono-free rows
  'test_report_works_for_carrier_float'         138   % full report build, carrier float rows
  'test_stage7b1_report'                        108   % full report build
  'test_mc_consistency_harness'                 103   % Monte-Carlo consistency ensemble
  'test_formation_rank_deficiency'               82   % multi-asset formation solve
  'test_srp_coefficient_state'                   72   % long-arc EKF run to observe the SRP scale state
  'test_tower_clock_product_cache_order'         69   % repeated tower-clock product builds
  'test_pairwise_relative_position_error'        63   % pairwise relative solve over the full arc
};
names = tbl(:,1).';
secs  = cell2mat(tbl(:,2)).';
end

function [ok, msg] = runOneTest_(name)
% runOneTest_  Execute one test in the base workspace.
%
% evalin('base',...) runs the script in the base workspace.  Any variable
% modifications by the script (or by sub-scripts it runs) stay in the base
% workspace and cannot overwrite ok/msg in this function's workspace.
%
% NOTE: all tests share ONE MATLAB session, so state leaks between them (figure handles,
% onCleanup handlers, path changes, globals). A FAIL here is a lead, not a verdict --
% reproduce it standalone before believing the message.
ok = true; msg = '';
try
    evalin('base', name);
catch e
    ok = false;
    msg = e.message;
    if numel(msg) > 160; msg = msg(1:160); end
end
end
