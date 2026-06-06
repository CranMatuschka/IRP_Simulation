classdef ReportConfigBuilder
    %REPORTCONFIGBUILDER Builds report config and toggle structs.
    %
    % Keeps report-specific configuration mapping out of ReverseGnssSimulation.

    methods (Static)
        function reportToggles = togglesFromSimulation(sim)
            reportToggles = struct();

            atmosphereCfg = ReportConfigBuilder.getFieldOrDefault( ...
                sim.cfg, 'atmosphere', struct());

            truthAtmosphereCfg = ReportConfigBuilder.getFieldOrDefault( ...
                atmosphereCfg, 'truth', struct());
            
            modelAtmosphereCfg = ReportConfigBuilder.getFieldOrDefault( ...
                atmosphereCfg, 'model', struct());

            reportToggles.generatePdf = true;
            reportToggles.groundSegment = true;

            reportToggles.perfectGroundClocks = ...
                ~GroundTimingNetwork.groundClockErrorsEnabled(sim.cfg);
            
            reportToggles.groundClockError = ...
                GroundTimingNetwork.groundClockErrorsEnabled(sim.cfg);
            
            reportToggles.groundTimingNetworkCorrection = ...
                GroundTimingNetwork.groundClockCorrectionEnabled(sim.cfg);
            
            reportToggles.towerClocksEstimatedInEkf = ...
                GroundTimingNetwork.towerClockEkfEnabled(sim.cfg);

            reportToggles.satelliteClockError = true;
            reportToggles.ekfOrbitClockEstimation = true;
            reportToggles.measurementNoise = ...
                sim.measurementModel.measurementNoiseEnabled();

            reportToggles.allanDeviationValidation = logical( ...
                ReportConfigBuilder.getFieldOrDefault( ...
                sim.cfg.report, 'enableAllanDeviationValidation', true));

            reportToggles.ionosphere = ...
                ReportConfigBuilder.atmosphereComponentEnabled( ...
                truthAtmosphereCfg, ...
                modelAtmosphereCfg, ...
                'enableIonosphere', ...
                'residualIonosphereSigma_m');

            reportToggles.troposphere = ...
                ReportConfigBuilder.atmosphereComponentEnabled( ...
                truthAtmosphereCfg, ...
                modelAtmosphereCfg, ...
                'enableTroposphere', ...
                'residualTroposphereSigma_m');

            reportToggles.multipath = logical( ...
                ReportConfigBuilder.getFieldOrDefault( ...
                sim.cfg.measurement, 'enableMultipathDelay', false));

            reportToggles.antennaBias = logical( ...
                ReportConfigBuilder.getFieldOrDefault( ...
                sim.cfg.measurement, 'enableAntennaDelay', false));

            reportToggles.hardwareDelay = logical( ...
                ReportConfigBuilder.getFieldOrDefault( ...
                sim.cfg.measurement, 'enableHardwareDelay', false));
        end

        function reportConfig = configFromSimulation(sim)
            reportConfig = struct();

            reportConfig.title = ...
                'Reverse-GNSS Spacecraft Code-Pseudorange EKF Report';

            reportConfig.scenarioName = char(sim.scenarioName);
            reportConfig.selectedOscillatorName = ...
                string(sim.assetConfig.clock.clockType);

            reportConfig.reportRoot = char(sim.outputDir);
            reportConfig.outputBaseName = ...
                sprintf('%s_report', char(sim.scenarioName));

            reportConfig.compilePdf = logical( ...
                ReportConfigBuilder.getFieldOrDefault( ...
                sim.cfg.report, 'compilePdf', true));

            reportConfig.interactivePlots = logical( ...
                ReportConfigBuilder.getFieldOrDefault( ...
                sim.cfg.report, 'interactivePlots', false));

            reportConfig.closeFiguresAfterExport = ...
                ~reportConfig.interactivePlots;

            reportConfig.generatedBy = char(sim.entryPointName);
        end
    end

    methods (Static, Access = private)
        
        function tf = atmosphereComponentEnabled( ...
                truthCfg, modelCfg, enableField, sigmaField)

            truthEnabled = logical(ReportConfigBuilder.getFieldOrDefault( ...
                truthCfg, enableField, false));

            modelEnabled = logical(ReportConfigBuilder.getFieldOrDefault( ...
                modelCfg, enableField, false));

            truthSigma_m = ReportConfigBuilder.getScalarField( ...
                truthCfg, sigmaField, 0.0);

            modelSigma_m = ReportConfigBuilder.getScalarField( ...
                modelCfg, sigmaField, 0.0);

            tf = truthEnabled || modelEnabled || ...
                truthSigma_m > 0.0 || modelSigma_m > 0.0;
        end

        function value = getScalarField(s, fieldName, defaultValue)
            if isstruct(s) && isfield(s, fieldName) && ~isempty(s.(fieldName))
                value = double(s.(fieldName));
            else
                value = double(defaultValue);
            end
        end
 
        function value = getFieldOrDefault(s, fieldName, defaultValue)
            if isstruct(s) && isfield(s, fieldName) && ~isempty(s.(fieldName))
                value = s.(fieldName);
            else
                value = defaultValue;
            end
        end
    end
end