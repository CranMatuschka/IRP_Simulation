function out = runGoldenScenario(durationOverride_s, seed)
%RUNGOLDENSCENARIO  Deterministically run the frozen Stage-85 golden scenario.
%   Pins the global RNG (default seed 42) so the stray attitude-reference randn in
%   ReverseGNSSSimulation is reproducible, builds the frozen goldenScenarioConfig,
%   and runs ReportRunner.runSingle with the report/PDF build disabled.
%
%   out = runGoldenScenario()            % full 3600 s
%   out = runGoldenScenario(120)         % 120 s smoke
%   out = runGoldenScenario(120, 7)      % custom seed
    if nargin < 2 || isempty(seed); seed = 42; end
    if nargin < 1; durationOverride_s = []; end
    thisDir = fileparts(mfilename('fullpath'));
    addpath(thisDir);                        % harness helpers
    addpath(fullfile(thisDir, '..', '..'));  % oo_v1 root, for +revgnss
    rng(seed, 'twister');
    cfg = goldenScenarioConfig(durationOverride_s);
    out = revgnss.ReportRunner.runSingle(cfg);
end
