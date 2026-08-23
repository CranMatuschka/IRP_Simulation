% run_oo_effect_toggle_tests.m
%
% Manual toggle test file for the reverse-GNSS simulator.
% Each case exercises one effect or combination of effects.
%
% Usage:
%   Set the RUN_* flags below, then run this script.
%   Output PDFs go to output/<caseName>.pdf
%   Output figures go to output/figures/<caseName>/
%
% Truth/model mismatch principle:
%   truth=true, model=false  → innovation shows deterministic bias.
%   truth=true, model=true   → effect mostly cancels; near-baseline performance.
%   R contains stochastic uncertainty only — deterministic mismatches appear in residuals.

clear; close all; clc;
thisDir = fileparts(mfilename('fullpath'));
addpath(thisDir);

% ======================================================================
%  CASE FLAGS — set to true/false to enable/disable each test case
% ======================================================================
RUN_BASELINE              = true;
RUN_MULTI_RECEIVER_ATT    = true;
RUN_REALISTIC_MATCHED     = true;
RUN_SAGNAC_MISMATCH       = true;
RUN_SHAPIRO_MISMATCH      = false;
RUN_TOWER_SURVEY_MISMATCH = true;
RUN_PCO_MISMATCH          = true;
RUN_PCV_TOY               = false;
RUN_TROPOSPHERE_MISMATCH  = true;
RUN_IONOSPHERE_MISMATCH   = true;
RUN_CORRELATED_NOISE      = true;
RUN_DOPPLER_DIAG_ONLY     = true;
RUN_DOPPLER_EKF           = false;
RUN_CARRIER_DIAG_ONLY     = true;

duration_s  = 600;
showFigures = false;
savePdf     = true;

% Storage for summary
summaryNames = {};
summaryCfgs  = {};
summaryRes   = {};

% ======================================================================
%  CASE 1 — Baseline (all effects off)
% ======================================================================
if RUN_BASELINE
    cfg = baseCfg('01_baseline', duration_s, showFigures, savePdf);
    results = runCase('01_baseline', cfg);
    summaryNames{end+1} = '01_baseline';
    summaryCfgs{end+1}  = cfg;
    summaryRes{end+1}   = results;
end

% ======================================================================
%  CASE 2 — Multi-receiver attitude estimation
% ======================================================================
if RUN_MULTI_RECEIVER_ATT
    cfg = revgnss.ConfigFactory.multiAntennaAttitudeConfig();
    cfg.simulation.duration_s = duration_s;
    cfg.plots.showFigures = showFigures;
    cfg.plots.savePdf     = savePdf;
    cfg.report.outputPdf  = fullfile('output', '02_multi_receiver_att.pdf');
    cfg.plots.outputDir   = fullfile('output', 'figures', '02_multi_receiver_att');
    results = runCase('02_multi_receiver_att', cfg);
    summaryNames{end+1} = '02_multi_receiver_att';
    summaryCfgs{end+1}  = cfg;
    summaryRes{end+1}   = results;
end

% ======================================================================
%  CASE 3 — Realistic matched (Sagnac + Shapiro truth=model=true)
%  Corrections mostly cancel; performance similar to baseline.
% ======================================================================
if RUN_REALISTIC_MATCHED
    cfg = revgnss.ConfigFactory.realisticPseudorangeConfig();
    cfg.simulation.duration_s = duration_s;
    cfg.plots.showFigures = showFigures;
    cfg.plots.savePdf     = savePdf;
    cfg.report.outputPdf  = fullfile('output', '03_realistic_matched.pdf');
    cfg.plots.outputDir   = fullfile('output', 'figures', '03_realistic_matched');
    results = runCase('03_realistic_matched', cfg);
    summaryNames{end+1} = '03_realistic_matched';
    summaryCfgs{end+1}  = cfg;
    summaryRes{end+1}   = results;
end

% ======================================================================
%  CASE 4 — Sagnac mismatch (truth on, model off)
%  Expected: Sagnac truth-model bias visible in prefit innovation.
% ======================================================================
if RUN_SAGNAC_MISMATCH
    cfg = baseCfg('04_sagnac_mismatch', duration_s, showFigures, savePdf);
    cfg.physics.sagnac.truth.enable = true;
    cfg.physics.sagnac.model.enable = false;
    results = runCase('04_sagnac_mismatch', cfg);
    summaryNames{end+1} = '04_sagnac_mismatch';
    summaryCfgs{end+1}  = cfg;
    summaryRes{end+1}   = results;
end

% ======================================================================
%  CASE 5 — Shapiro mismatch (truth on, model off)
%  Expected: ~0.01 m relativistic bias in residuals.
% ======================================================================
if RUN_SHAPIRO_MISMATCH
    cfg = baseCfg('05_shapiro_mismatch', duration_s, showFigures, savePdf);
    cfg.physics.relativity.shapiro.truth.enable = true;
    cfg.physics.relativity.shapiro.model.enable = false;
    results = runCase('05_shapiro_mismatch', cfg);
    summaryNames{end+1} = '05_shapiro_mismatch';
    summaryCfgs{end+1}  = cfg;
    summaryRes{end+1}   = results;
end

% ======================================================================
%  CASE 6 — Tower survey mismatch (truth on, model off)
%  Expected: deterministic position bias from tower location error.
% ======================================================================
if RUN_TOWER_SURVEY_MISMATCH
    cfg = baseCfg('06_tower_survey_mismatch', duration_s, showFigures, savePdf);
    cfg.effects.towerSurvey.truth.enable = true;
    cfg.effects.towerSurvey.model.enable = false;
    cfg.effects.towerSurvey.sigmaENU_m   = [0.05; 0.05; 0.10];
    results = runCase('06_tower_survey_mismatch', cfg);
    summaryNames{end+1} = '06_tower_survey_mismatch';
    summaryCfgs{end+1}  = cfg;
    summaryRes{end+1}   = results;
end

% ======================================================================
%  CASE 7 — Antenna PCO mismatch (truth on, model off)
%  Expected: geometry-dependent bias from unmodelled PCO offset.
% ======================================================================
if RUN_PCO_MISMATCH
    cfg = baseCfg('07_pco_mismatch', duration_s, showFigures, savePdf);
    cfg.effects.antennaPCO.truth.enable          = true;
    cfg.effects.antennaPCO.model.enable          = false;
    cfg.effects.antennaPCO.receiverOffset_body_m = [0.05; 0.0; 0.02];
    results = runCase('07_pco_mismatch', cfg);
    summaryNames{end+1} = '07_pco_mismatch';
    summaryCfgs{end+1}  = cfg;
    summaryRes{end+1}   = results;
end

% ======================================================================
%  CASE 8 — Toy PCV (truth=model, cancels; for diagnostic only)
%  NOT calibrated ANTEX — toy elevation model only.
% ======================================================================
if RUN_PCV_TOY
    cfg = baseCfg('08_pcv_toy', duration_s, showFigures, savePdf);
    cfg.effects.antennaPCV.truth.enable = true;
    cfg.effects.antennaPCV.model.enable = true;   % matched: should mostly cancel
    cfg.effects.antennaPCV.modelType    = 'toyAzEl';
    cfg.effects.antennaPCV.amplitude_m  = 0.01;
    results = runCase('08_pcv_toy', cfg);
    summaryNames{end+1} = '08_pcv_toy';
    summaryCfgs{end+1}  = cfg;
    summaryRes{end+1}   = results;
end

% ======================================================================
%  CASE 9 — Troposphere mismatch (truth on, model off)
%  Expected: elevation-dependent innovation bias, worse at low elevations.
% ======================================================================
if RUN_TROPOSPHERE_MISMATCH
    cfg = baseCfg('09_troposphere_mismatch', duration_s, showFigures, savePdf);
    cfg.errors.troposphere.truth.enable        = true;
    cfg.errors.troposphere.truth.zenithDelay_m = 2.3;
    cfg.errors.troposphere.model.enable        = false;
    results = runCase('09_troposphere_mismatch', cfg);
    summaryNames{end+1} = '09_troposphere_mismatch';
    summaryCfgs{end+1}  = cfg;
    summaryRes{end+1}   = results;
end

% ======================================================================
%  CASE 10 — Ionosphere mismatch (truth on, model off)
%  Expected: larger innovation bias (ionosphere > troposphere at zenith).
% ======================================================================
if RUN_IONOSPHERE_MISMATCH
    cfg = baseCfg('10_ionosphere_mismatch', duration_s, showFigures, savePdf);
    cfg.errors.ionosphere.truth.enable        = true;
    cfg.errors.ionosphere.truth.zenithDelay_m = 5.0;
    cfg.errors.ionosphere.model.enable        = false;
    results = runCase('10_ionosphere_mismatch', cfg);
    summaryNames{end+1} = '10_ionosphere_mismatch';
    summaryCfgs{end+1}  = cfg;
    summaryRes{end+1}   = results;
end

% ======================================================================
%  CASE 11 — Correlated noise (Stage 4)
%  Expected: off-diagonal R; EKF still works; NIS may change.
% ======================================================================
if RUN_CORRELATED_NOISE
    cfg = baseCfg('11_correlated_noise', duration_s, showFigures, savePdf);
    cfg.effects.correlatedNoise.enable            = true;
    cfg.effects.correlatedNoise.commonModeSigma_m = 0.15;
    cfg.effects.correlatedNoise.sameTowerSigma_m  = 0.10;
    cfg.effects.correlatedNoise.independentSigma_m = 0.05;
    results = runCase('11_correlated_noise', cfg);
    % Verify R is non-diagonal (off-diagonal entries should be > 0)
    r = results.diag;
    R1 = r.log(min(10, r.nEpochs)).R;
    if size(R1,1) > 1
        offDiagSum = sum(abs(R1(:))) - sum(abs(diag(R1)));
        fprintf('  Correlated R off-diagonal sum at epoch 10: %.4f m^2\n', offDiagSum);
        if offDiagSum < 1e-10
            warning('run_oo_effect_toggle_tests:correlatedNoise', ...
                'R appears diagonal despite correlatedNoise.enable=true.');
        end
    end
    summaryNames{end+1} = '11_correlated_noise';
    summaryCfgs{end+1}  = cfg;
    summaryRes{end+1}   = results;
end

% ======================================================================
%  CASE 12 — Doppler diagnostic only (not used in EKF)
%  Expected: doppler prefit stored; measurement count unchanged.
% ======================================================================
if RUN_DOPPLER_DIAG_ONLY
    cfg = baseCfg('12_doppler_diag_only', duration_s, showFigures, savePdf);
    cfg.measurements.doppler.enable   = true;
    cfg.measurements.doppler.useInEKF = false;
    cfg.measurements.doppler.sigma_mps = 0.01;
    cfg.physics.doppler.truth.enable  = true;
    cfg.physics.doppler.model.enable  = true;
    results = runCase('12_doppler_diag_only', cfg);
    summaryNames{end+1} = '12_doppler_diag_only';
    summaryCfgs{end+1}  = cfg;
    summaryRes{end+1}   = results;
end

% ======================================================================
%  CASE 13 — Doppler in EKF (stacked with pseudorange)
%  Expected: measurement count = 2 × pseudorange count; postfit split correctly.
% ======================================================================
if RUN_DOPPLER_EKF
    cfg = baseCfg('13_doppler_ekf', duration_s, showFigures, savePdf);
    cfg.measurements.doppler.enable   = true;
    cfg.measurements.doppler.useInEKF = true;
    cfg.measurements.doppler.sigma_mps = 0.01;
    cfg.physics.doppler.truth.enable  = true;
    cfg.physics.doppler.model.enable  = true;
    results = runCase('13_doppler_ekf', cfg);
    summaryNames{end+1} = '13_doppler_ekf';
    summaryCfgs{end+1}  = cfg;
    summaryRes{end+1}   = results;
end

% ======================================================================
%  CASE 14 — Carrier phase diagnostic only (not in EKF)
%  Expected: carrier phi stored per epoch; EKF state unchanged.
% ======================================================================
if RUN_CARRIER_DIAG_ONLY
    cfg = baseCfg('14_carrier_diag_only', duration_s, showFigures, savePdf);
    cfg.measurements.carrierPhase.enable   = true;
    cfg.measurements.carrierPhase.useInEKF = false;
    results = runCase('14_carrier_diag_only', cfg);
    summaryNames{end+1} = '14_carrier_diag_only';
    summaryCfgs{end+1}  = cfg;
    summaryRes{end+1}   = results;
end

% ======================================================================
%  SUMMARY TABLE
% ======================================================================
if ~isempty(summaryNames)
    fprintf('\n');
    fprintf('===============================================================\n');
    fprintf('  EFFECT TOGGLE TEST SUMMARY\n');
    fprintf('===============================================================\n');
    fprintf('%-32s %4s %8s %12s %8s %9s %10s\n', ...
        'Case', 'nRx', 'maxMeas', 'finalPos[m]', 'meanNIS', 'prefitRMS', 'postfitRMS');
    fprintf('%s\n', repmat('-',1,87));
    for k = 1:numel(summaryNames)
        nm  = summaryNames{k};
        cfg = summaryCfgs{k};
        res = summaryRes{k};
        d   = res.diag;

        nRx       = cfg.scenario.nReceivers;
        maxMeas   = max(d.getNumMeasurements());
        finalPos  = d.getPositionErrors();
        finalPos  = finalPos(end);
        nisVec    = d.getNIS();
        meanNIS   = mean(nisVec, 'omitnan');
        pfRMS     = mean(d.getPrefitInnovationRMS());
        poRMS     = mean(d.getPostfitResidualRMS());

        fprintf('%-32s %4d %8d %12.3f %8.2f %9.4f %10.4f\n', ...
            nm, nRx, maxMeas, finalPos, meanNIS, pfRMS, poRMS);
    end
    fprintf('%s\n', repmat('-',1,87));
    fprintf('\n');
end

% ======================================================================
%  HELPER FUNCTIONS
% ======================================================================

function cfg = baseCfg(caseName, duration_s, showFigures, savePdf)
    cfg = revgnss.ConfigFactory.defaultConfig();
    cfg.simulation.duration_s = duration_s;
    cfg.plots.showFigures     = showFigures;
    cfg.plots.savePdf         = savePdf;
    cfg.report.outputPdf      = fullfile('output', [caseName '.pdf']);
    cfg.plots.outputDir       = fullfile('output', 'figures', caseName);
end

function results = runCase(caseName, cfg)
    fprintf('\n===== CASE: %s =====\n', caseName);
    sim = revgnss.ReverseGNSSSimulation(cfg);
    sim.initialize();
    sim.run();
    figs = sim.plot();
    sim.writeReport(figs);
    results = sim.getResults();
    assignin('base', ['results_' caseName], results);
    fprintf('===== DONE: %s =====\n', caseName);
end
