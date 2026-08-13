function result = run_oo_v1_regression(tier, scenario)
%RUN_OO_V1_REGRESSION  Stage-85 equivalence gate versus a frozen Phase-0 golden.
%   result = run_oo_v1_regression('smoke')               % single-antenna, 120 s
%   result = run_oo_v1_regression('full')                % single-antenna, 3600 s
%   result = run_oo_v1_regression('smoke','headline')    % 4-antenna headline, 120 s
%
%   scenario: 'single' (default) | 'headline' (4-antenna cross); the headline gate
%   diffs against golden/golden_headline_<tier>.mat.
%
%   Re-runs the frozen golden scenario, extracts the ReportRunner summary metrics,
%   and diffs them against tests/regression/golden/golden_<tier>.mat.
%
%   PASS iff every CORE scientific metric (coreMetricNames) matches within
%   tolerance AND no core metric appeared or disappeared. Non-core metric changes
%   are reported for visibility but do not fail the gate, so intended diagnostic
%   restructuring in later phases stays visible without falsely blocking.
%
%   The gate certifies "done" — not any edit or model. Deviation = bug. NEVER
%   loosen rtol/atol or trim coreMetricNames to make a change pass.
    if nargin < 1 || isempty(tier); tier = 'smoke'; end
    if nargin < 2 || isempty(scenario); scenario = 'single'; end
    tier = lower(tier); scenario = lower(scenario);
    thisDir = fileparts(mfilename('fullpath'));
    addpath(thisDir);                        % harness helpers
    addpath(fullfile(thisDir, '..', '..'));  % oo_v1 root, for +revgnss

    rtol = 1e-9;    % relative tolerance: allows only FP-reassociation noise
    atol = 1e-12;   % absolute floor for near-zero metrics

    switch scenario
        case 'single';   goldName = ['golden_' tier '.mat'];
        case 'headline'; goldName = ['golden_headline_' tier '.mat'];
        case 'realism';  goldName = ['golden_realism_' tier '.mat'];
        case 'feat024';  goldName = ['golden_feat024_' tier '.mat'];
        case 'correlated'; goldName = ['golden_correlated_' tier '.mat'];
        otherwise; error('run_oo_v1_regression:scenario', ...
            ['scenario must be ''single'', ''headline'', ''realism'', ''feat024'' or ' ...
             '''correlated'' (got ''%s'').'], scenario);
    end
    goldFile = fullfile(thisDir, 'golden', goldName);
    assert(isfile(goldFile), 'run_oo_v1_regression:noGolden', ...
        'Golden reference missing: %s\nRun captureGolden(''%s'',''%s'') from the validated Phase-0 state first.', ...
        goldFile, tier, scenario);
    G = load(goldFile);

    dur = [];
    if strcmp(tier, 'smoke'); dur = 120; end

    t0  = tic;
    out = runGoldenScenario(dur, [], scenario);
    cur = extractMetrics(out.summary);
    wall = toc(t0);

    goldNames = G.metricNames(:);
    goldVals  = G.metricValues(:);
    goldMap   = containers.Map(goldNames, num2cell(goldVals));
    curNames  = keys(cur)';
    coreNames = G.coreNames(:);
    isCore    = @(nm) any(strcmp(nm, coreNames));

    % ---- structural changes (finiteness transitions) ----
    missing = setdiff(goldNames, curNames);   % golden had finite, now absent/NaN
    added   = setdiff(curNames, goldNames);   % newly finite
    missingCore = missing(cellfun(isCore, missing));
    addedCore   = added(cellfun(isCore, added));

    % ---- numeric diffs on shared metrics ----
    shared = intersect(goldNames, curNames);
    coreFail = {}; nonCoreFail = {}; worstCoreRel = 0; worstCore = '';
    for i = 1:numel(shared)
        nm = shared{i};
        a = goldMap(nm); b = cur(nm);
        da = abs(a - b); dr = da / max(abs(a), atol);
        if da > atol && dr > rtol
            line = sprintf('%s: golden=%.12g current=%.12g relDiff=%.3e', nm, a, b, dr);
            if isCore(nm)
                coreFail{end+1} = line; %#ok<AGROW>
                if dr > worstCoreRel; worstCoreRel = dr; worstCore = nm; end
            else
                nonCoreFail{end+1} = line; %#ok<AGROW>
            end
        end
    end

    corePass = isempty(missingCore) && isempty(addedCore) && isempty(coreFail);

    % ---- report ----
    fprintf('\n===== OO_V1 REGRESSION GATE [%s / %s] =====\n', upper(tier), upper(scenario));
    fprintf('golden: dur=%gs epochs=%d MATLAB %s\n', G.duration_s, G.capturedEpochs, G.matlabVersion);
    fprintf('metrics: golden=%d current=%d shared=%d | tol rel=%.0e abs=%.0e | wall=%.1fs\n', ...
        numel(goldNames), numel(curNames), numel(shared), rtol, atol, wall);
    if ~isempty(missing); fprintf('[info] no-longer-finite metrics (%d): %s\n', numel(missing), joinTrunc_(missing)); end
    if ~isempty(added);   fprintf('[info] newly-finite metrics (%d): %s\n', numel(added), joinTrunc_(added)); end
    if ~isempty(nonCoreFail)
        fprintf('[warn] %d non-core metric(s) changed:\n', numel(nonCoreFail));
        printLines_(nonCoreFail, 15);
    end
    if ~corePass
        fprintf('\n*** CORE CONTRACT VIOLATED ***\n');
        if ~isempty(missingCore); fprintf('  core metrics disappeared: %s\n', strjoin(missingCore, ', ')); end
        if ~isempty(addedCore);   fprintf('  core metrics appeared: %s\n', strjoin(addedCore, ', ')); end
        if ~isempty(coreFail)
            fprintf('  core numeric deviations (%d; worst %s rel=%.3e):\n', numel(coreFail), worstCore, worstCoreRel);
            printLines_(coreFail, 40);
        end
    end

    result = struct('pass', corePass, 'tier', tier, 'scenario', scenario, 'nMetrics', numel(goldNames), ...
        'nShared', numel(shared), 'coreFail', {coreFail}, 'nonCoreFail', {nonCoreFail}, ...
        'missing', {missing}, 'added', {added}, 'wallSec', wall);

    if corePass
        fprintf('\nRESULT: PASS - Stage-85 numbers unchanged vs frozen golden.\n');
    else
        fprintf('\nRESULT: FAIL - equivalence broken (deviation = bug; do not weaken the gate).\n');
    end
end

function s = joinTrunc_(c)
    n = numel(c); k = min(n, 12);
    s = strjoin(c(1:k), ', ');
    if n > k; s = sprintf('%s, ...(+%d)', s, n - k); end
end

function printLines_(c, k)
    for i = 1:min(numel(c), k); fprintf('    %s\n', c{i}); end
    if numel(c) > k; fprintf('    ...(+%d more)\n', numel(c) - k); end
end
