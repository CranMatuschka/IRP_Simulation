classdef SimulationOutputManager
    %SIMULATIONOUTPUTMANAGER Handles simulation output paths and file writing.
    %
    % Keeps filesystem/output concerns out of ReverseGnssSimulation.

    methods (Static)
        function outputDir = defaultOutputDirectory(sim)
            outputDir = string(fullfile( ...
                char(ProjectPathManager.projectRoot()), ...
                "reports", ...
                char(sim.entryPointName), ...
                char(sim.scenarioName)));
        end

        function ensureOutputDirectory(sim)
            if strlength(sim.outputDir) == 0
                sim.outputDir = SimulationOutputManager.defaultOutputDirectory(sim);
            end

            if ~exist(char(sim.outputDir), "dir")
                mkdir(char(sim.outputDir));
            end
        end

        function resultPath = saveResultsStruct(results, outputDir, scenarioName)
            if strlength(string(outputDir)) == 0
                error('SimulationOutputManager:MissingOutputDir', ...
                    'outputDir must be set before saving results.');
            end

            if ~exist(char(outputDir), "dir")
                mkdir(char(outputDir));
            end

            resultPath = fullfile(char(outputDir), ...
                sprintf('%s_results.mat', char(scenarioName)));

            save(resultPath, 'results');
        end
    end
end