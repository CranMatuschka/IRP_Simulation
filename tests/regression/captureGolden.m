function captureGolden(tier, scenario)
%CAPTUREGOLDEN  Capture and save a frozen Phase-0 golden reference.
%   captureGolden('smoke')             % single-antenna, 120 s   -> golden_smoke.mat
%   captureGolden('full')              % single-antenna, 14400 s -> golden_full.mat
%   captureGolden('full','headline')   % 4-antenna, 14400 s -> golden_headline_full.mat
%   captureGolden('full','feat024')    % realism + scint obliquity -> golden_feat024_full.mat
%
%   THE 'full' TIER IS 4 HOURS, NOT ONE. It passes an empty duration, meaning "whatever
%   the fixture defaults to", and every fixture builds from masterConfig() directly --
%   whose own simulation.duration_s default is 14400 s. Only run_oo_v1 imposes the 3600 s
%   default, and no fixture goes through it. Verified across all four families: every
%   golden_*_full.mat carries duration_s = 14400 / 14401 epochs. Do not compare a
%   golden_*_full number against a run_oo_v1(..., 3600) number -- different arcs.
%
%   scenario: 'single' (default) | 'headline' (4-antenna cross) | 'realism' | 'feat024'. Stores the full
%   resolved cfg and summary struct (provenance) plus the finite scalar metric vector
%   the gate compares against. Run ONCE from the validated Phase-0 state; thereafter
%   the gate re-runs and diffs against these files.
    if nargin < 2 || isempty(scenario); scenario = 'single'; end
    scenario = lower(scenario);
    thisDir = fileparts(mfilename('fullpath'));
    addpath(thisDir);                        % harness helpers
    addpath(fullfile(thisDir, '..', '..'));  % oo_v1 root, for +revgnss
    dur = tierDuration_(tier);
    fprintf('Capturing golden [%s / %s] (%s)...\n', tier, scenario, durStr_(dur));

    t0  = tic;
    out = runGoldenScenario(dur, [], scenario);
    M   = extractMetrics(out.summary);

    golden = struct();
    golden.tier           = lower(tier);
    golden.scenario       = scenario;
    golden.duration_s     = out.cfg.simulation.duration_s;
    golden.dt_s           = out.cfg.simulation.dt_s;
    golden.seed           = 42;
    golden.metricNames    = keys(M)';
    golden.metricValues   = cell2mat(values(M))';
    golden.coreNames      = coreMetricNames();
    golden.summary        = out.summary;   % full provenance
    golden.cfg            = out.cfg;        % frozen resolved config
    golden.matlabVersion  = version;
    golden.capturedEpochs = out.sim.simData.nEpochs;
    golden.captureWallSec = toc(t0);

    switch scenario
        case 'headline'; outFile = fullfile(thisDir, 'golden', ['golden_headline_' golden.tier '.mat']);
        case 'realism';  outFile = fullfile(thisDir, 'golden', ['golden_realism_'  golden.tier '.mat']);
        case 'feat024';  outFile = fullfile(thisDir, 'golden', ['golden_feat024_'  golden.tier '.mat']);
        case 'correlated'; outFile = fullfile(thisDir, 'golden', ['golden_correlated_' golden.tier '.mat']);
        otherwise;       outFile = fullfile(thisDir, 'golden', ['golden_'          golden.tier '.mat']);
    end
    if ~isfolder(fullfile(thisDir,'golden')); mkdir(fullfile(thisDir,'golden')); end
    save(outFile, '-struct', 'golden');

    fprintf('Saved %s\n  %d finite metrics, %d epochs, wall=%.1fs, MATLAB %s\n', ...
        outFile, numel(golden.metricNames), golden.capturedEpochs, golden.captureWallSec, golden.matlabVersion);
    missingCore = setdiff(golden.coreNames, golden.metricNames(:));
    if ~isempty(missingCore)
        warning('captureGolden:missingCore', ...
            'Core metrics absent from capture (fix coreMetricNames): %s', strjoin(missingCore, ', '));
    else
        fprintf('  all %d core metrics present.\n', numel(golden.coreNames));
    end
end

function dur = tierDuration_(tier)
    switch lower(tier)
        case 'smoke'; dur = 120;
        case 'full';  dur = [];     % fixture default = masterConfig's 14400 s (NOT 3600)
        otherwise; error('captureGolden:tier', 'tier must be ''smoke'' or ''full''');
    end
end

function s = durStr_(dur)
    if isempty(dur); s = '3600 s full'; else; s = sprintf('%g s', dur); end
end
