function out = runGoldenScenario(durationOverride_s, seed, scenario)
%RUNGOLDENSCENARIO  Deterministically run a frozen Stage-85 golden scenario.
%   Pins the global RNG (default seed 42) so the stray attitude-reference randn in
%   ReverseGNSSSimulation is reproducible, builds the frozen scenario config, and runs
%   ReportRunner.runSingle with the report/PDF build disabled.
%
%   out = runGoldenScenario()                       % single-antenna golden, full 3600 s
%   out = runGoldenScenario(120)                    % 120 s smoke
%   out = runGoldenScenario(120, 7)                 % custom seed
%   out = runGoldenScenario([], [], 'headline')     % 4-antenna headline golden, full
%
%   scenario: 'single' (default, single-antenna golden) | 'headline' (4-antenna cross).
    if nargin < 3 || isempty(scenario); scenario = 'single'; end
    if nargin < 2 || isempty(seed); seed = 42; end
    if nargin < 1; durationOverride_s = []; end
    thisDir = fileparts(mfilename('fullpath'));
    addpath(thisDir);                        % harness helpers
    addpath(fullfile(thisDir, '..', '..'));  % oo_v1 root, for +revgnss
    rng(seed, 'twister');
    switch lower(scenario)
        case 'single';   cfg = goldenScenarioConfig(durationOverride_s);
        case 'headline'; cfg = goldenHeadlineScenarioConfig(durationOverride_s);
        case 'realism';  cfg = goldenRealismScenarioConfig(durationOverride_s);
        case 'feat024';  cfg = goldenFeat024ScenarioConfig(durationOverride_s);
        otherwise
            error('runGoldenScenario:scenario', ...
                ['scenario must be ''single'', ''headline'', ''realism'' or ''feat024'' ' ...
                 '(got ''%s'').'], scenario);
    end
    out = revgnss.ReportRunner.runSingle(cfg);
end
