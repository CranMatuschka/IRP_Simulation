classdef ProjectPathManager
    %PROJECTPATHMANAGER Centralizes repository path discovery and setup.
    %
    % Keep this file in the repository root. Source files may later be moved
    % into subfolders without changing path logic throughout the codebase.

    methods (Static)
        function root = projectRoot()
            root = string(fileparts(mfilename('fullpath')));
        end

        function addProjectPaths()
            folders = ProjectPathManager.sourceFolders();

            for k = 1:numel(folders)
                addpath(char(folders(k)));
            end
        end

        function folders = sourceFolders()
            root = ProjectPathManager.projectRoot();

            candidates = [ ...
                root; ...
                fullfile(root, "Report"); ...
                fullfile(root, "config"); ...
                fullfile(root, "src", "simulation"); ...
                fullfile(root, "src", "models"); ...
                fullfile(root, "src", "measurement"); ...
                fullfile(root, "src", "estimation"); ...
                fullfile(root, "src", "io") ...
                ];

            folders = candidates(isfolder(candidates));
        end

        function configPath = simulationConfigFile()
            root = ProjectPathManager.projectRoot();

            candidates = [ ...
                fullfile(root, "config", "SimulationConfig.m"); ...
                fullfile(root, "SimulationConfig.m") ...
                ];

            idx = find(isfile(candidates), 1, 'first');

            if isempty(idx)
                error('ProjectPathManager:MissingSimulationConfig', ...
                    'Could not find SimulationConfig.m in the project root or config folder.');
            end

            configPath = candidates(idx);
        end
    end
end