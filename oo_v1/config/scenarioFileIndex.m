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

    if nargin < 1 || isempty(repositoryRoot)
        repositoryRoot = fileparts(fileparts(mfilename('fullpath')));
    end

    configDir = fullfile(repositoryRoot, 'config');
    ladderDir = fullfile(configDir, 'ladder');

    directories = {configDir};
    entries = dir(ladderDir);
    ladderNames = sort({entries([entries.isdir]).name});
    for index = 1:numel(ladderNames)
        if startsWith(ladderNames{index}, '.'); continue; end
        directories{end + 1} = fullfile(ladderDir, ladderNames{index}); %#ok<AGROW>
    end

    files = dir(fullfile(directories{1}, '*.json'));
    files = files([]);
    for index = 1:numel(directories)
        found = dir(fullfile(directories{index}, '*.json'));
        [~, order] = sort({found.name});
        files = [files; found(order)]; %#ok<AGROW>
    end
end
