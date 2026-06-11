% run_oo_contribution_validation_report.m
%
% Runs selected test cases and produces ONE consolidated PDF:
%   oo_v1/output/effect_contribution_validation_report.pdf
%
% No per-case PDFs.  No individual PNG/FIG files by default.
%
% Each case generates:
%   - A one-page case summary figure (name, config, final metrics)
%   - Standard diagnostic figures (17-figure Plotter suite)
%   - Contribution overview figure (all effects on one axes)
%   - Per-effect contribution figures (one per effect, including disabled=zero)
%
% All figures are appended into a single PDF at the end.
%
% Usage:
%   cd oo_v1
%   run_oo_contribution_validation_report

clear; close all; clc;

thisDir = fileparts(mfilename('fullpath'));
addpath(thisDir);

% ======================================================================
%  CASE FLAGS
% ======================================================================
RUN_BASELINE              = true;
RUN_MULTI_RECEIVER_ATT    = true;
RUN_REALISTIC_MATCHED     = true;
RUN_SAGNAC_MISMATCH       = true;
RUN_TOWER_SURVEY_MISMATCH = true;
RUN_PCO_MISMATCH          = true;
RUN_PCV_TOY               = true;
RUN_TROPOSPHERE_MISMATCH  = true;
RUN_IONOSPHERE_MISMATCH   = true;
RUN_CORRELATED_NOISE      = true;
RUN_DOPPLER_DIAG_ONLY     = true;
RUN_DOPPLER_EKF           = false;   % heavier; off by default
RUN_CARRIER_DIAG_ONLY     = true;

duration_s  = 600;
showFigures = false;

singlePdf = fullfile(thisDir, 'output', 'effect_contribution_validation_report.pdf');

% Ensure output directory exists
if ~exist(fullfile(thisDir, 'output'), 'dir')
    mkdir(fullfile(thisDir, 'output'));
end

% Delete stale PDF before first append
if exist(singlePdf, 'file')
    delete(singlePdf);
end

% ======================================================================
%  RUN ALL CASES
% ======================================================================

if RUN_BASELINE
    cfg = baseCfgSilent(duration_s, showFigures);
    runAndCollect('01_baseline', cfg, singlePdf, showFigures);
end

if RUN_MULTI_RECEIVER_ATT
    cfg = revgnss.ConfigFactory.multiAntennaAttitudeConfig();
    cfg = silencePlots(cfg, duration_s, showFigures);
    runAndCollect('02_multi_receiver_att', cfg, singlePdf, showFigures);
end

if RUN_REALISTIC_MATCHED
    cfg = revgnss.ConfigFactory.realisticPseudorangeConfig();
    cfg = silencePlots(cfg, duration_s, showFigures);
    runAndCollect('03_realistic_matched', cfg, singlePdf, showFigures);
end

if RUN_SAGNAC_MISMATCH
    cfg = baseCfgSilent(duration_s, showFigures);
    cfg.physics.sagnac.truth.enable = true;
    cfg.physics.sagnac.model.enable = false;
    runAndCollect('04_sagnac_mismatch', cfg, singlePdf, showFigures);
end

if RUN_TOWER_SURVEY_MISMATCH
    cfg = baseCfgSilent(duration_s, showFigures);
    cfg.effects.towerSurvey.truth.enable = true;
    cfg.effects.towerSurvey.model.enable = false;
    cfg.effects.towerSurvey.sigmaENU_m   = [0.05; 0.05; 0.10];
    runAndCollect('05_tower_survey_mismatch', cfg, singlePdf, showFigures);
end

if RUN_PCO_MISMATCH
    cfg = baseCfgSilent(duration_s, showFigures);
    cfg.effects.antennaPCO.truth.enable          = true;
    cfg.effects.antennaPCO.model.enable          = false;
    cfg.effects.antennaPCO.receiverOffset_body_m = [0.05; 0.0; 0.02];
    runAndCollect('06_pco_mismatch', cfg, singlePdf, showFigures);
end

if RUN_PCV_TOY
    cfg = baseCfgSilent(duration_s, showFigures);
    cfg.effects.antennaPCV.truth.enable = true;
    cfg.effects.antennaPCV.model.enable = true;   % matched: mostly cancels
    cfg.effects.antennaPCV.amplitude_m  = 0.01;
    runAndCollect('07_pcv_toy', cfg, singlePdf, showFigures);
end

if RUN_TROPOSPHERE_MISMATCH
    cfg = baseCfgSilent(duration_s, showFigures);
    cfg.errors.troposphere.truth.enable        = true;
    cfg.errors.troposphere.truth.zenithDelay_m = 2.3;
    cfg.errors.troposphere.model.enable        = false;
    runAndCollect('08_troposphere_mismatch', cfg, singlePdf, showFigures);
end

if RUN_IONOSPHERE_MISMATCH
    cfg = baseCfgSilent(duration_s, showFigures);
    cfg.errors.ionosphere.truth.enable        = true;
    cfg.errors.ionosphere.truth.zenithDelay_m = 5.0;
    cfg.errors.ionosphere.model.enable        = false;
    runAndCollect('09_ionosphere_mismatch', cfg, singlePdf, showFigures);
end

if RUN_CORRELATED_NOISE
    cfg = baseCfgSilent(duration_s, showFigures);
    cfg.effects.correlatedNoise.enable             = true;
    cfg.effects.correlatedNoise.commonModeSigma_m  = 0.15;
    cfg.effects.correlatedNoise.sameTowerSigma_m   = 0.10;
    cfg.effects.correlatedNoise.independentSigma_m = 0.05;
    runAndCollect('10_correlated_noise', cfg, singlePdf, showFigures);
end

if RUN_DOPPLER_DIAG_ONLY
    cfg = baseCfgSilent(duration_s, showFigures);
    cfg.measurements.doppler.enable    = true;
    cfg.measurements.doppler.useInEKF  = false;
    cfg.measurements.doppler.sigma_mps = 0.01;
    cfg.physics.doppler.truth.enable   = true;
    cfg.physics.doppler.model.enable   = true;
    runAndCollect('11_doppler_diag_only', cfg, singlePdf, showFigures);
end

if RUN_DOPPLER_EKF
    cfg = baseCfgSilent(duration_s, showFigures);
    cfg.measurements.doppler.enable    = true;
    cfg.measurements.doppler.useInEKF  = true;
    cfg.measurements.doppler.sigma_mps = 0.01;
    cfg.physics.doppler.truth.enable   = true;
    cfg.physics.doppler.model.enable   = true;
    runAndCollect('12_doppler_ekf', cfg, singlePdf, showFigures);
end

if RUN_CARRIER_DIAG_ONLY
    cfg = baseCfgSilent(duration_s, showFigures);
    cfg.measurements.carrierPhase.enable   = true;
    cfg.measurements.carrierPhase.useInEKF = false;
    runAndCollect('13_carrier_diag_only', cfg, singlePdf, showFigures);
end

% ======================================================================
%  FINAL REPORT
% ======================================================================
if exist(singlePdf, 'file')
    fprintf('\n=============================================\n');
    fprintf('  Validation PDF written to:\n  %s\n', singlePdf);
    fprintf('=============================================\n\n');
else
    warning('run_oo_contribution_validation_report:noPdf', ...
        'No cases were run — PDF not created.');
end

% ======================================================================
%  LOCAL FUNCTIONS
% ======================================================================

function cfg = baseCfgSilent(duration_s, showFigures)
    cfg = revgnss.ConfigFactory.defaultConfig();
    cfg = silencePlots(cfg, duration_s, showFigures);
end

function cfg = silencePlots(cfg, duration_s, showFigures)
    cfg.simulation.duration_s       = duration_s;
    cfg.plots.showFigures           = showFigures;
    cfg.plots.savePdf               = false;
    cfg.plots.saveIndividualFigures = false;
    cfg.plots.saveFigures           = false;
    cfg.report.enable               = false;
end

function runAndCollect(caseName, cfg, singlePdf, showFigures)
    fprintf('\n===== CASE: %s =====\n', caseName);
    sim = revgnss.ReverseGNSSSimulation(cfg);
    sim.initialize();
    sim.run();

    d = sim.diag;

    % Case summary figure
    figSum = makeSummaryFig(caseName, cfg, d, showFigures);
    figs   = figSum;

    % Standard diagnostic figures (no PDF, no saves)
    stdFigs = revgnss.Plotter.plotAll(d, sim.asset, sim.towers, cfg);
    figs = [figs; stdFigs(:)];

    % Optional Doppler RMS figure (separate unit)
    if isfield(cfg,'measurements') && isfield(cfg.measurements,'doppler') && ...
            isfield(cfg.measurements.doppler,'enable') && ...
            cfg.measurements.doppler.enable
        t = d.getTimeVector();
        figDop = revgnss.Plotter.plotDopplerRMS(d, t, cfg);
        figs = [figs; figDop];
    end

    % Contribution overview + per-effect figures
    contribFigs = revgnss.ContributionPlotter.plotAllContributions(d, cfg);
    figs = [figs; contribFigs(:)];

    % Append to PDF and close immediately to keep memory low
    appendFigsToPdf(figs, singlePdf);
    for k = 1:numel(figs)
        if isgraphics(figs(k)) && isvalid(figs(k))
            close(figs(k));
        end
    end

    fprintf('===== DONE: %s =====\n', caseName);
end

function fig = makeSummaryFig(caseName, cfg, d, showFigures)
    vis = 'off';
    if showFigures; vis = 'on'; end
    fig = figure('Name', ['Summary: ' caseName], 'Visible', vis, ...
        'NumberTitle','off', 'Position',[100 100 700 400]);

    posErr  = d.getPositionErrors();
    nisVec  = d.getNIS();
    m_rows  = d.getNumMeasurementRows();
    nRx     = 1;
    if isfield(cfg,'scenario') && isfield(cfg.scenario,'nReceivers')
        nRx = cfg.scenario.nReceivers;
    end
    maxMeas  = max(d.getNumMeasurements());
    maxRows  = max(m_rows);
    meanNIS  = mean(nisVec,'omitnan');
    finalPos = posErr(end);

    % Collect active effects
    effects = {};
    if isfield(cfg,'physics')
        if isfield(cfg.physics,'sagnac') && isfield(cfg.physics.sagnac,'truth') && ...
                isfield(cfg.physics.sagnac.truth,'enable') && ...
                cfg.physics.sagnac.truth.enable
            effects{end+1} = 'Sagnac-truth';
        end
        if isfield(cfg.physics,'sagnac') && isfield(cfg.physics.sagnac,'model') && ...
                isfield(cfg.physics.sagnac.model,'enable') && ...
                cfg.physics.sagnac.model.enable
            effects{end+1} = 'Sagnac-model';
        end
        if isfield(cfg.physics,'relativity') && ...
                isfield(cfg.physics.relativity,'shapiro') && ...
                isfield(cfg.physics.relativity.shapiro,'truth') && ...
                cfg.physics.relativity.shapiro.truth.enable
            effects{end+1} = 'Shapiro-truth';
        end
    end
    if isfield(cfg,'effects')
        e = cfg.effects;
        if isfield(e,'towerSurvey') && ...
                ((isfield(e.towerSurvey,'truth') && isfield(e.towerSurvey.truth,'enable') && e.towerSurvey.truth.enable) || ...
                 (isfield(e.towerSurvey,'model') && isfield(e.towerSurvey.model,'enable') && e.towerSurvey.model.enable))
            effects{end+1} = 'TowerSurvey';
        end
        if isfield(e,'antennaPCO') && ...
                ((isfield(e.antennaPCO,'truth') && isfield(e.antennaPCO.truth,'enable') && e.antennaPCO.truth.enable) || ...
                 (isfield(e.antennaPCO,'model') && isfield(e.antennaPCO.model,'enable') && e.antennaPCO.model.enable))
            effects{end+1} = 'PCO';
        end
        if isfield(e,'antennaPCV') && ...
                ((isfield(e.antennaPCV,'truth') && isfield(e.antennaPCV.truth,'enable') && e.antennaPCV.truth.enable) || ...
                 (isfield(e.antennaPCV,'model') && isfield(e.antennaPCV.model,'enable') && e.antennaPCV.model.enable))
            effects{end+1} = 'PCV';
        end
        if isfield(e,'correlatedNoise') && isfield(e.correlatedNoise,'enable') && ...
                e.correlatedNoise.enable
            effects{end+1} = 'CorrNoise';
        end
    end
    if isfield(cfg,'errors')
        er = cfg.errors;
        if isfield(er,'troposphere') && isfield(er.troposphere,'truth') && ...
                isfield(er.troposphere.truth,'enable') && er.troposphere.truth.enable
            effects{end+1} = 'Trop';
        end
        if isfield(er,'ionosphere') && isfield(er.ionosphere,'truth') && ...
                isfield(er.ionosphere.truth,'enable') && er.ionosphere.truth.enable
            effects{end+1} = 'Iono';
        end
    end
    if isfield(cfg,'measurements')
        if isfield(cfg.measurements,'doppler') && isfield(cfg.measurements.doppler,'enable') && ...
                cfg.measurements.doppler.enable
            if isfield(cfg.measurements.doppler,'useInEKF') && cfg.measurements.doppler.useInEKF
                effects{end+1} = 'Doppler-EKF';
            else
                effects{end+1} = 'Doppler-diag';
            end
        end
        if isfield(cfg.measurements,'carrierPhase') && ...
                isfield(cfg.measurements.carrierPhase,'enable') && ...
                cfg.measurements.carrierPhase.enable
            effects{end+1} = 'Carrier-diag';
        end
    end
    effectStr = strjoin(effects, ', ');
    if isempty(effectStr); effectStr = 'none (baseline)'; end

    axes('Position',[0 0 1 1],'Visible','off'); %#ok<LAXES>
    lines_ = { ...
        sprintf('\\bf%s', strrep(caseName,'_',' ')); ...
        ''; ...
        sprintf('nReceivers: %d', nRx); ...
        sprintf('Max pseudorange measurements/epoch: %d', maxMeas); ...
        sprintf('Max EKF measurement rows/epoch: %d', maxRows); ...
        sprintf('Final position error: %.3f m', finalPos); ...
        sprintf('Mean NIS: %.2f  (E[NIS] ~ %.0f)', meanNIS, mean(m_rows,'omitnan')); ...
        ''; ...
        sprintf('Active effects: %s', effectStr) };
    text(0.05, 0.95, lines_, 'Units','normalized', ...
        'VerticalAlignment','top','FontSize',11, ...
        'Interpreter','tex');
end

function appendFigsToPdf(figs, pdfPath)
    for k = 1:numel(figs)
        if ~isgraphics(figs(k)) || ~isvalid(figs(k)); continue; end
        if ~strcmp(get(figs(k),'Type'),'figure'); continue; end
        try
            if exist(pdfPath,'file')
                exportgraphics(figs(k), pdfPath, 'Append', true, 'Resolution', 100);
            else
                exportgraphics(figs(k), pdfPath, 'Resolution', 100);
            end
        catch
            try
                if exist(pdfPath,'file')
                    print(figs(k), '-dpdf', '-append', pdfPath);
                else
                    print(figs(k), '-dpdf', pdfPath);
                end
            catch ME_pr
                warning('run_oo_contribution_validation_report:appendFail', ...
                    'Could not append figure to PDF: %s', ME_pr.message);
            end
        end
    end
end
