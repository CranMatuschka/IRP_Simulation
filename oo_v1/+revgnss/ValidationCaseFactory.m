classdef ValidationCaseFactory
    % ValidationCaseFactory  Builds named simulation configs for the validation suite.
    %
    % Centralises the case-configuration logic shared by the contribution
    % report and the scientific validation suite so that both scripts draw
    % from the same definitions.
    %
    % Usage:
    %   cfg = revgnss.ValidationCaseFactory.buildCase('baseline', 600, false);
    %
    % After buildCase() returns, common output flags are already set:
    %   cfg.simulation.duration_s       = duration_s
    %   cfg.plots.enable                = true
    %   cfg.plots.showFigures           = showFigures
    %   cfg.plots.savePdf               = false
    %   cfg.plots.saveFigures           = false
    %   cfg.plots.saveIndividualFigures = false
    %   cfg.report.enable               = false
    %
    % Valid case names:
    %   baseline              defaultConfig, code noise only
    %   multi_receiver_att    4 antennas, attitude estimation
    %   realistic_matched     Sagnac + Shapiro truth+model matched
    %   sagnac_mismatch       Sagnac truth only (not in model)
    %   tower_survey_mismatch TowerSurvey truth only
    %   pco_mismatch          Receiver PCO truth only
    %   pcv_toy               PCV truth only (small amplitude)
    %   troposphere_mismatch  Troposphere truth only
    %   ionosphere_mismatch   Ionosphere truth only
    %   correlated_noise      Correlated noise enabled
    %   doppler_diag_only     Doppler diagnostic (NOT in EKF)
    %   doppler_ekf           Doppler in EKF
    %   carrier_diag_only     Carrier phase diagnostic (NOT in EKF)
    %   all_contributions_matched  All deterministic effects matched truth=model
    %   all_contributions_demo     Mixed matched/mismatched effects

    methods (Static)

        function cfg = buildCase(caseName, duration_s, showFigures)
            % buildCase  Return a fully-configured struct for the named case.
            switch caseName

                case 'baseline'
                    cfg = revgnss.ConfigFactory.defaultConfig();

                case 'multi_receiver_att'
                    cfg = revgnss.ConfigFactory.multiAntennaAttitudeConfig();

                case 'realistic_matched'
                    cfg = revgnss.ConfigFactory.realisticPseudorangeConfig();

                case 'sagnac_mismatch'
                    cfg = revgnss.ConfigFactory.defaultConfig();
                    cfg.physics.sagnac.truth.enable = true;
                    cfg.physics.sagnac.model.enable = false;

                case 'tower_survey_mismatch'
                    cfg = revgnss.ConfigFactory.defaultConfig();
                    cfg.effects.towerSurvey.truth.enable = true;
                    cfg.effects.towerSurvey.model.enable = false;
                    cfg.effects.towerSurvey.sigmaENU_m   = [0.05; 0.05; 0.10];

                case 'pco_mismatch'
                    cfg = revgnss.ConfigFactory.defaultConfig();
                    cfg.effects.antennaPCO.truth.enable          = true;
                    cfg.effects.antennaPCO.model.enable          = false;
                    cfg.effects.antennaPCO.receiverOffset_body_m = [0.05; 0.0; 0.02];

                case 'pcv_toy'
                    cfg = revgnss.ConfigFactory.defaultConfig();
                    cfg.effects.antennaPCV.truth.enable = true;
                    cfg.effects.antennaPCV.model.enable = false;
                    cfg.effects.antennaPCV.amplitude_m  = 0.01;

                case 'troposphere_mismatch'
                    cfg = revgnss.ConfigFactory.defaultConfig();
                    cfg.errors.troposphere.truth.enable        = true;
                    cfg.errors.troposphere.truth.zenithDelay_m = 2.3;
                    cfg.errors.troposphere.model.enable        = false;

                case 'ionosphere_mismatch'
                    cfg = revgnss.ConfigFactory.defaultConfig();
                    cfg.errors.ionosphere.truth.enable        = true;
                    cfg.errors.ionosphere.truth.zenithDelay_m = 5.0;
                    cfg.errors.ionosphere.model.enable        = false;

                case 'correlated_noise'
                    cfg = revgnss.ConfigFactory.defaultConfig();
                    cfg.effects.correlatedNoise.enable             = true;
                    cfg.effects.correlatedNoise.commonModeSigma_m  = 0.15;
                    cfg.effects.correlatedNoise.sameTowerSigma_m   = 0.10;
                    cfg.effects.correlatedNoise.independentSigma_m = 0.05;

                case 'doppler_diag_only'
                    cfg = revgnss.ConfigFactory.defaultConfig();
                    cfg.measurements.doppler.enable    = true;
                    cfg.measurements.doppler.useInEKF  = false;
                    cfg.measurements.doppler.sigma_mps = 0.01;
                    cfg.physics.doppler.truth.enable   = true;
                    cfg.physics.doppler.model.enable   = true;

                case 'doppler_ekf'
                    cfg = revgnss.ConfigFactory.defaultConfig();
                    cfg.measurements.doppler.enable    = true;
                    cfg.measurements.doppler.useInEKF  = true;
                    cfg.measurements.doppler.sigma_mps = 0.01;
                    cfg.physics.doppler.truth.enable   = true;
                    cfg.physics.doppler.model.enable   = true;

                case 'carrier_diag_only'
                    cfg = revgnss.ConfigFactory.defaultConfig();
                    cfg.measurements.carrierPhase.enable   = true;
                    cfg.measurements.carrierPhase.useInEKF = false;

                case 'all_contributions_matched'
                    cfg = revgnss.ConfigFactory.defaultConfig();
                    cfg.physics.sagnac.truth.enable               = true;
                    cfg.physics.sagnac.model.enable               = true;
                    cfg.physics.relativity.shapiro.truth.enable   = true;
                    cfg.physics.relativity.shapiro.model.enable   = true;
                    cfg.errors.troposphere.truth.enable           = true;
                    cfg.errors.troposphere.model.enable           = true;
                    cfg.errors.troposphere.truth.zenithDelay_m    = 2.3;
                    cfg.errors.troposphere.model.zenithDelay_m    = 2.3;
                    cfg.errors.ionosphere.truth.enable            = true;
                    cfg.errors.ionosphere.model.enable            = true;
                    cfg.errors.ionosphere.truth.zenithDelay_m     = 5.0;
                    cfg.errors.ionosphere.model.zenithDelay_m     = 5.0;
                    cfg.effects.towerSurvey.truth.enable          = true;
                    cfg.effects.towerSurvey.model.enable          = true;
                    cfg.effects.towerSurvey.sigmaENU_m            = [0.05; 0.05; 0.10];
                    cfg.effects.antennaPCO.truth.enable           = true;
                    cfg.effects.antennaPCO.model.enable           = true;
                    cfg.effects.antennaPCO.receiverOffset_body_m  = [0.05; 0.0; 0.02];
                    cfg.effects.antennaPCO.towerOffset_enu_m      = [0.05; 0.0; 0.02];
                    cfg.effects.antennaPCV.truth.enable           = true;
                    cfg.effects.antennaPCV.model.enable           = true;
                    cfg.effects.antennaPCV.amplitude_m            = 0.01;
                    cfg.effects.correlatedNoise.enable            = false;
                    cfg.measurements.doppler.enable               = false;
                    cfg.measurements.carrierPhase.enable          = false;

                case 'all_contributions_demo'
                    cfg = revgnss.ConfigFactory.defaultConfig();
                    cfg.physics.sagnac.truth.enable               = true;
                    cfg.physics.sagnac.model.enable               = true;
                    cfg.physics.relativity.shapiro.truth.enable   = true;
                    cfg.physics.relativity.shapiro.model.enable   = true;
                    cfg.errors.troposphere.truth.enable           = true;
                    cfg.errors.troposphere.truth.zenithDelay_m    = 2.3;
                    cfg.errors.troposphere.model.enable           = false;
                    cfg.errors.ionosphere.truth.enable            = true;
                    cfg.errors.ionosphere.truth.zenithDelay_m     = 5.0;
                    cfg.errors.ionosphere.model.enable            = false;
                    cfg.effects.towerSurvey.truth.enable          = true;
                    cfg.effects.towerSurvey.model.enable          = false;
                    cfg.effects.towerSurvey.sigmaENU_m            = [0.05; 0.05; 0.10];
                    cfg.effects.antennaPCO.truth.enable           = true;
                    cfg.effects.antennaPCO.model.enable           = false;
                    cfg.effects.antennaPCO.receiverOffset_body_m  = [0.05; 0.0; 0.02];
                    cfg.effects.antennaPCO.towerOffset_enu_m      = [0.03; 0.02; 0.05];
                    cfg.effects.antennaPCV.truth.enable           = true;
                    cfg.effects.antennaPCV.model.enable           = false;
                    cfg.effects.antennaPCV.amplitude_m            = 0.01;
                    cfg.effects.correlatedNoise.enable            = true;
                    cfg.effects.correlatedNoise.commonModeSigma_m  = 0.15;
                    cfg.effects.correlatedNoise.sameTowerSigma_m   = 0.10;
                    cfg.effects.correlatedNoise.independentSigma_m = 0.05;
                    cfg.measurements.doppler.enable               = true;
                    cfg.measurements.doppler.useInEKF             = false;
                    cfg.measurements.doppler.sigma_mps            = 0.01;
                    cfg.physics.doppler.truth.enable              = true;
                    cfg.physics.doppler.model.enable              = true;
                    cfg.measurements.carrierPhase.enable          = true;
                    cfg.measurements.carrierPhase.useInEKF        = false;

                case 'dual_frequency_baseline'
                    % Dual-frequency (L1+L2) baseline: code noise only, both signals
                    cfg = revgnss.ConfigFactory.defaultConfig();
                    cfg.signals.twoFrequency.enable = true;

                case 'ionosphere_dual_frequency_mismatch'
                    % Dual-frequency with ionosphere truth on, model off — visible mismatch
                    cfg = revgnss.ConfigFactory.defaultConfig();
                    cfg.signals.twoFrequency.enable           = true;
                    cfg.errors.ionosphere.truth.enable        = true;
                    cfg.errors.ionosphere.truth.zenithDelay_m = 5.0;
                    cfg.errors.ionosphere.model.enable        = false;

                case 'ionosphere_dual_frequency_matched'
                    % Dual-frequency with matched iono truth=model — should mostly cancel
                    cfg = revgnss.ConfigFactory.defaultConfig();
                    cfg.signals.twoFrequency.enable           = true;
                    cfg.errors.ionosphere.truth.enable        = true;
                    cfg.errors.ionosphere.truth.zenithDelay_m = 5.0;
                    cfg.errors.ionosphere.model.enable        = true;
                    cfg.errors.ionosphere.model.zenithDelay_m = 5.0;

                case 'stochastic_environment_validation'
                    % Stochastic troposphere + ionosphere GM; no model correction
                    cfg = revgnss.ConfigFactory.defaultConfig();
                    cfg.errors.troposphere.modelType                = 'localWeatherGM';
                    cfg.errors.troposphere.truth.enable             = true;
                    cfg.errors.troposphere.model.enable             = false;
                    cfg.errors.troposphere.stochastic.enable        = true;
                    cfg.errors.troposphere.stochastic.tau_s         = 3600;
                    cfg.errors.troposphere.stochastic.sigmaWet_ss_m = 0.05;
                    cfg.errors.ionosphere.modelType                 = 'tecGaussMarkov';
                    cfg.errors.ionosphere.truth.enable              = true;
                    cfg.errors.ionosphere.model.enable              = false;
                    cfg.errors.ionosphere.stochastic.enable         = true;
                    cfg.errors.ionosphere.stochastic.tau_s          = 1800;
                    cfg.errors.ionosphere.stochastic.sigmaVDelayL1_ss_m = 1.0;

                case 'clock_noise_validation'
                    % Stochastic clocks + noisyCorrection (same as clockNoiseConfig)
                    cfg = revgnss.ConfigFactory.clockNoiseConfig();

                otherwise
                    error('revgnss:ValidationCaseFactory:unknownCase', ...
                        'Unknown case: ''%s''. See classdef header for valid cases.', caseName);
            end

            cfg.simulation.duration_s       = duration_s;
            cfg.plots.enable                = true;
            cfg.plots.showFigures           = showFigures;
            cfg.plots.savePdf               = false;
            cfg.plots.saveFigures           = false;
            cfg.plots.saveIndividualFigures = false;
            cfg.report.enable               = false;
        end

    end
end
