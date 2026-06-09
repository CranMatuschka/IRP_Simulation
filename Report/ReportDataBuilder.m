classdef ReportDataBuilder
    %REPORTDATABUILDER Provides the thin report context for generateReport.

    methods (Static)
        function ctx = fromSimulation(sim)
            ctx = struct();
            ctx.sim = sim;
            ctx.history = sim.history;
            ctx.cfg = sim.cfg;
            ctx.c = sim.c;
            ctx.constants = sim.constants;
            ctx.idx = sim.idx;
            ctx.time_s = sim.time_s;
            ctx.numSteps = sim.numSteps;
            ctx.towers = sim.activeTowerConfig;
            ctx.towerNames = sim.towerNames;
            ctx.receiverNames = sim.receiverNames;
            ctx.scenarioName = sim.scenarioName;
            ctx.outputDir = sim.outputDir;
            ctx.toggles = ReportConfigBuilder.togglesFromSimulation(sim);
            ctx.config = ReportConfigBuilder.configFromSimulation(sim);
            ctx.simConfig = sim.simConfig;
            ctx.assetConfig = sim.assetConfig;
            ctx.truthAtmosphere = sim.truthAtmosphere;
            ctx.modelAtmosphere = sim.modelAtmosphere;
        end
    end
end
