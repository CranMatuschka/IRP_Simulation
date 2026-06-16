classdef TriageScenarioFactory
    % TriageScenarioFactory  Controlled EKF convergence toggle ladder.

    methods (Static)
        function cases = buildCases()
            base = revgnss.TriageScenarioFactory.cleanBase_();
            cases = repmat(revgnss.TriageScenarioFactory.case_( ...
                '', '', base, '', ''), 8, 1);

            c = base;
            cases(1) = revgnss.TriageScenarioFactory.case_( ...
                'case_01_baseline_code_only', ...
                'Clean single-receiver pseudorange EKF geometry and clock.', ...
                c, 'Basic code geometry should not diverge.', ...
                'code,L1,oneReceiver');

            c = revgnss.TriageScenarioFactory.enableDoppler_(base);
            cases(2) = revgnss.TriageScenarioFactory.case_( ...
                'case_02_code_plus_doppler', ...
                'Single receiver code plus Doppler used in EKF.', ...
                c, 'Velocity and clock-drift aiding should remain stable.', ...
                'code,doppler,L1,oneReceiver');

            c = revgnss.TriageScenarioFactory.setReceivers_(c, 3);
            cases(3) = revgnss.TriageScenarioFactory.case_( ...
                'case_03_code_doppler_three_receivers', ...
                'Three receiver phase centres with code and Doppler only.', ...
                c, 'Multi-receiver code/Doppler geometry should remain stable.', ...
                'code,doppler,L1,threeReceivers');

            c = revgnss.TriageScenarioFactory.enableCarrierDiagnostic_(c);
            cases(4) = revgnss.TriageScenarioFactory.case_( ...
                'case_04_carrier_diagnostic_three_receivers', ...
                'Carrier generated for diagnostics only, not used by EKF.', ...
                c, 'Carrier truth generation should not affect EKF state.', ...
                'code,doppler,carrierDiagnostic,L1,threeReceivers');

            c = revgnss.TriageScenarioFactory.enableCarrierEkf_( ...
                revgnss.TriageScenarioFactory.enableDoppler_(base));
            cases(5) = revgnss.TriageScenarioFactory.case_( ...
                'case_05_carrier_ekf_one_receiver', ...
                'Carrier float EKF in single-receiver dimensional baseline.', ...
                c, 'Float L1 carrier should be dimensionally clean.', ...
                'code,doppler,carrierEkfFloat,slipDetection,L1,oneReceiver');

            c = revgnss.TriageScenarioFactory.setReceivers_( ...
                revgnss.TriageScenarioFactory.enableDoppler_(base), 3);
            c = revgnss.TriageScenarioFactory.enableCarrierEkf_(c);
            cases(6) = revgnss.TriageScenarioFactory.case_( ...
                'case_06_carrier_ekf_three_receivers', ...
                'Carrier float EKF with three receiver phase centres.', ...
                c, 'Must fail clearly or be classified invalid if ambiguities are not receiver-indexed.', ...
                'code,doppler,carrierEkfFloat,slipDetection,L1,threeReceivers');

            c = revgnss.TriageScenarioFactory.setReceivers_( ...
                revgnss.TriageScenarioFactory.enableDoppler_(base), 3);
            c = revgnss.TriageScenarioFactory.enableZwd_(c);
            cases(7) = revgnss.TriageScenarioFactory.case_( ...
                'case_07_zwd_code_doppler_three_receivers', ...
                'Per-tower ZWD EKF states with code and Doppler only.', ...
                c, 'ZWD states should not absorb clock/range errors silently.', ...
                'code,doppler,perTowerZwd,L1,threeReceivers');

            c = revgnss.TriageScenarioFactory.reportSmokeConfig_();
            cases(8) = revgnss.TriageScenarioFactory.case_( ...
                'case_08_full_supported_report_smoke', ...
                'Compatible everything-on report-smoke configuration.', ...
                c, 'Reproduce suspicious report behaviour for comparison.', ...
                'code,doppler,carrierEkfFloat,perTowerZwd,L1L2,threeReceivers');
        end
    end

    methods (Static, Access = private)
        function cfg = cleanBase_()
            cfg = revgnss.ConfigFactory.cleanConfig();
            cfg.simulation.duration_s = 600;
            cfg.simulation.dt_s = 1;
            cfg.scenario.nReceivers = 1;
            cfg.signals.twoFrequency.enable = false;
            cfg.signals.enabled = {'L1'};
            cfg.measurements.codeMode = 'singleFrequency';
            cfg.measurements.observableMode = 'code';
            cfg.measurements.doppler.enable = false;
            cfg.measurements.doppler.useInEKF = false;
            cfg.physics.doppler.truth.enable = false;
            cfg.physics.doppler.model.enable = false;
            cfg.measurements.carrierPhase.enable = false;
            cfg.measurements.carrierMode = 'off';
            cfg.measurements.carrier.slipDetection.enable = false;
            cfg.estimation.ambiguityMode = 'none';
            cfg.estimation.troposphereMode = 'none';
            cfg.errors.troposphere.stochastic.enable = false;
            cfg.errors.ionosphere.stochastic.enable = false;
            cfg.errors.ionosphere.scintillation.enable = false;
            cfg.errors.codeNoise.sigma_m = 0;
            cfg.measurements.codeNoise.model = 'constant';
            cfg.clock.receiver.deterministic = true;
            cfg.errors.towerClockCorrection.mode = 'perfectCorrection';
            cfg.towerClock.correctionMode = 'perfectTruth';
            cfg.clock.mode = 'spacecraftReceiverClockOnly';
            cfg.clock.gauge.mode = 'externalTowerCorrections';
            cfg.hardware.txCodeBias.enable = false;
            cfg.hardware.txCodeBias.useInEKF = false;
            cfg.hardware.rxCodeBias.enable = false;
            cfg.hardware.rxCodeBias.mode = 'absorbedInReceiverClock';
            cfg.hardware.rxCarrierBias.enable = false;
            cfg.hardware.rxCarrierBias.mode = 'notImplemented';
            cfg.report.writePdf = false;
            cfg.report.writeMat = false;
            cfg.plots.enable = false;
            cfg.plots.showFigures = false;
            cfg.validation.unsupportedFeaturePolicy = 'disableWithWarning';
        end

        function cfg = enableDoppler_(cfg)
            cfg.measurements.observableMode = 'code+doppler';
            cfg.measurements.doppler.enable = true;
            cfg.measurements.doppler.useInEKF = true;
            cfg.physics.doppler.truth.enable = true;
            cfg.physics.doppler.model.enable = true;
        end

        function cfg = setReceivers_(cfg, nReceivers)
            cfg.scenario.nReceivers = nReceivers;
        end

        function cfg = enableCarrierDiagnostic_(cfg)
            cfg.measurements.observableMode = 'code+doppler+carrier';
            cfg.measurements.carrierPhase.enable = true;
            cfg.measurements.carrierMode = 'diagnostic';
            cfg.estimation.ambiguityMode = 'none';
        end

        function cfg = enableCarrierEkf_(cfg)
            cfg.measurements.observableMode = 'code+doppler+carrier';
            cfg.measurements.carrierPhase.enable = true;
            cfg.measurements.carrierMode = 'ekfFloat';
            cfg.measurements.carrierCombinationMode = 'raw';
            cfg.estimation.ambiguityMode = 'floatPerTowerSignal';
            cfg.measurements.carrier.slipDetection.enable = true;
            cfg.measurements.carrier.slipDetection.threshold_m = 0.1;
            cfg.measurements.carrier.slipDetection.minEpochsBeforeDetect = 3;
            cfg.measurements.carrier.slipDetection.resetSigma_m = 100;
            cfg.measurements.carrier.slipDetection.action = 'resetAndSkip';
            cfg.hardware.rxCarrierBias.mode = 'absorbedInAmbiguity';
        end

        function cfg = enableZwd_(cfg)
            cfg.errors.troposphere.truth.enable = true;
            cfg.errors.troposphere.model.enable = true;
            cfg.errors.troposphere.stochastic.enable = true;
            cfg.estimation.troposphereMode = 'perTowerZwd';
            cfg.estimation.tropoZwd.initialSigma_m = 0.3;
            cfg.estimation.tropoZwd.sigma_ss_m = 0.05;
            cfg.estimation.tropoZwd.tau_s = 3600;
        end

        function cfg = reportSmokeConfig_()
            cfg = revgnss.ConfigFactory.defaultConfig();
            cfg.simulation.duration_s = 600;
            cfg.simulation.dt_s = 1;
            cfg.report.writePdf = false;
            cfg.report.writeMat = false;
            cfg.plots.enable = false;
            cfg.plots.showFigures = false;
            cfg.scenario.nReceivers = 3;
            cfg.signals.twoFrequency.enable = true;
            cfg.physics.sagnac.truth.enable = true;
            cfg.physics.sagnac.model.enable = true;
            cfg.physics.lightTime.truth.enable = true;
            cfg.physics.lightTime.model.enable = true;
            cfg.physics.relativity.shapiro.truth.enable = true;
            cfg.physics.relativity.shapiro.model.enable = true;
            cfg.physics.relativity.clock.truth.enable = true;
            cfg.physics.relativity.clock.model.enable = true;
            cfg.errors.troposphere.truth.enable = true;
            cfg.errors.troposphere.model.enable = true;
            cfg.errors.troposphere.modelType = 'simpleMapped';
            cfg.errors.troposphere.stochastic.enable = true;
            cfg.errors.ionosphere.truth.enable = true;
            cfg.errors.ionosphere.model.enable = true;
            cfg.errors.ionosphere.modelType = 'simpleMapped';
            cfg.errors.ionosphere.stochastic.enable = true;
            cfg.errors.ionosphere.scintillation.enable = true;
            cfg.errors.hardwareDelay.truth.enable = false;
            cfg.errors.hardwareDelay.model.enable = false;
            cfg.errors.multipath.truth.enable = false;
            cfg.errors.multipath.model.enable = false;
            cfg.clock.receiver.deterministic = true;
            cfg.errors.towerClockCorrection.mode = 'perfectCorrection';
            cfg.measurements.doppler.enable = true;
            cfg.measurements.doppler.useInEKF = true;
            cfg.physics.doppler.truth.enable = true;
            cfg.physics.doppler.model.enable = true;
            cfg.measurements.carrierPhase.enable = true;
            cfg.measurements.carrierMode = 'ekfFloat';
            cfg.estimation.ambiguityMode = 'floatPerTowerSignal';
            cfg.measurements.carrier.slipDetection.enable = true;
            cfg.measurements.carrier.slipDetection.action = 'resetAndSkip';
            cfg.estimation.troposphereMode = 'perTowerZwd';
            cfg.estimation.tropoZwd.initialSigma_m = 0.3;
            cfg.estimation.tropoZwd.sigma_ss_m = 0.05;
            cfg.estimation.tropoZwd.tau_s = 3600;
            cfg.validation.unsupportedFeaturePolicy = 'disableWithWarning';
        end

        function s = case_(name, description, cfg, expectedBehavior, features)
            s = struct('name', name, 'description', description, 'cfg', cfg, ...
                'expectedBehavior', expectedBehavior, 'enabledFeatures', features);
        end
    end
end
