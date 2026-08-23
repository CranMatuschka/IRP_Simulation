function [files, directories] = scenarioFileIndex(repositoryRoot)
%SCENARIOFILEINDEX Every scenario JSON the resolver can find, in a stable order.
%   FILES is a dir() struct array over
%       config/*.json               masterConfig's companions
%       config/ladder/<axis>/*.json the numbered ladder files
%   sorted by folder then name, so callers that freeze a baseline over the whole
%   set get the same order on every machine.
%
%   DIRECTORIES is the search path resolveSimulationConfig uses to turn a bare
%   file name into a full path. The two share one definition on purpose: a new
%   ladder axis becomes visible to the runner and to the gates at the same time.
%
%   config/personal/ IS IN DIRECTORIES AND DELIBERATELY NOT IN FILES. Personal
%   scenarios are untracked scratch files written by the config editor, and they
%   have to be findable by bare name so run_oo_v1('mine.json') works the same way
%   it does for a ladder rung. They must NOT join the gate set: FILES is what
%   test_scenario_override_invariance and test_config_mode_enum_validation iterate,
%   so putting them there would let one person's half-finished experiment fail the
%   shared suite on a machine nobody else can reproduce. The split already exists
%   in this function's two outputs, so honouring it costs one extra loop.

    if nargin < 1 || isempty(repositoryRoot)
        repositoryRoot = fileparts(fileparts(mfilename('fullpath')));
    end

    configDir   = fullfile(repositoryRoot, 'config');
    ladderDir   = fullfile(configDir, 'ladder');
    personalDir = fullfile(configDir, 'personal');

    directories = {configDir};
    entries = dir(ladderDir);
    ladderNames = sort({entries([entries.isdir]).name});
    for index = 1:numel(ladderNames)
        if startsWith(ladderNames{index}, '.'); continue; end
        directories{end + 1} = fullfile(ladderDir, ladderNames{index}); %#ok<AGROW>
    end

    trackedCount = numel(directories);

    % FILES is built from the tracked directories only, before config/personal/ joins
    % the lookup path below.
    files = dir(fullfile(directories{1}, '*.json'));
    files = files([]);
    for index = 1:trackedCount
        found = dir(fullfile(directories{index}, '*.json'));
        [~, order] = sort({found.name});
        files = [files; found(order)]; %#ok<AGROW>
    end

    % Personal scenarios, lookup only. The folder is absent on a fresh clone until
    % someone saves into it, and subfolders are honoured so a person can group their
    % own runs the way the ladder groups its axes.
    if isfolder(personalDir)
        directories{end + 1} = personalDir;
        personalEntries = dir(personalDir);
        personalNames = sort({personalEntries([personalEntries.isdir]).name});
        for index = 1:numel(personalNames)
            if startsWith(personalNames{index}, '.'); continue; end
            directories{end + 1} = fullfile(personalDir, personalNames{index}); %#ok<AGROW>
        end
    end
end
