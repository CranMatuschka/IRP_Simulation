% run_oo_contribution_validation_report.m
%
% Creates ONE PDF from ONE simulation run.
% Not a case sweep.  No repeated standard plots.  No hundreds of pages.
%
% Output:
%   oo_v1/output/effect_contribution_validation_report.pdf
%
% Expected figure count:
%   1  summary page
%  17  standard diagnostic figures  (INCLUDE_ALL_STANDARD_PLOTS = true)
%   2  contribution overview (Truth RMS + Mismatch RMS bar charts)
%  20  one page per contribution (Truth/Model/Mismatch lines or text page)
%  ----
%  40  total
%
% Hard limits: error if < 10 or > 60 figures.
%
% Usage:
%   cd oo_v1
%   run_oo_contribution_validation_report

clear; close all; clc;
scriptStart = datetime('now');

thisDir = fileparts(mfilename('fullpath'));
addpath(thisDir);

% ======================================================================
%  CONFIGURATION — edit these lines
% ======================================================================
% Select one scenario to validate:
%   'baseline'              defaultConfig — code noise only
%   'multi_receiver_att'    4 antennas, attitude estimation
%   'realistic_matched'     Sagnac + Shapiro truth+model matched
%   'sagnac_mismatch'       Sagnac truth only  (innovation bias visible)
%   'tower_survey_mismatch' Tower survey truth only
%   'pco_mismatch'          Receiver PCO truth only
%   'pcv_toy'               PCV truth+model (mostly cancels)
%   'troposphere_mismatch'  Troposphere truth only
%   'ionosphere_mismatch'   Ionosphere truth only
%   'correlated_noise'      Correlated noise enabled
%   'doppler_diag_only'     Doppler diagnostic (not in EKF)
%   'doppler_ekf'           Doppler in EKF
%   'carrier_diag_only'     Carrier phase diagnostic
%   'all_contributions_demo' Mixed matched/mismatched — default, for diagnostics
%   'custom'                Edit buildReportCase below
REPORT_CASE = 'all_contributions_demo';

% If true: include all 17 standard diagnostic figures from Plotter.plotAll.
% If false: include a compact 8-figure subset (position/attitude/clock/NIS/RMS).
INCLUDE_ALL_STANDARD_PLOTS = true;

duration_s  = 600;
showFigures = false;

% ======================================================================
%  OUTPUT PATH
% ======================================================================
singlePdf = fullfile(thisDir, 'output', 'effect_contribution_validation_report.pdf');

% ======================================================================
%  BUILD + RUN ONE SCENARIO  — do NOT add loops here
% ======================================================================
fprintf('\n=== Contribution Validation Report: %s  (ONE simulation run only) ===\n', REPORT_CASE);

cfg = buildReportCase(REPORT_CASE, duration_s, showFigures);

sim = revgnss.ReverseGNSSSimulation(cfg);
sim.initialize();
sim.run();

% Use finalized config (finalizeConfig runs inside initialize)
cfg = sim.cfg;
d   = sim.diag;
t   = d.getTimeVector();

% ======================================================================
%  ASSEMBLE FIGURES
% ======================================================================
allFigHandles = gobjects(0);

% 1) Summary page
figSum = makeSummaryFig(REPORT_CASE, cfg, d, singlePdf, showFigures);
allFigHandles = [allFigHandles; figSum];

% 2) Standard diagnostic plots (once)
if INCLUDE_ALL_STANDARD_PLOTS
    stdFigs = revgnss.Plotter.plotAll(d, sim.asset, sim.towers, cfg);
    allFigHandles = [allFigHandles; stdFigs(:)];
else
    compactStd = plotCompactStandardSubset(d, sim.asset, sim.towers, cfg, t);
    allFigHandles = [allFigHandles; compactStd(:)];
end

% 3) Contribution pages: 1 overview + 20 per-effect pages
contribFigs = revgnss.ContributionPlotter.plotSingleCaseContributionPages(d, cfg);
allFigHandles = [allFigHandles; contribFigs(:)];

% ======================================================================
%  VALIDATE FIGURE COUNT — hard limits
% ======================================================================
nFigs = sum(isgraphics(allFigHandles));
fprintf('Figure count: %d\n', nFigs);

if nFigs < 10
    error('run_oo_contribution_validation_report:tooFew', ...
        'Only %d figures — report generation failed before PDF writing.', nFigs);
end

if nFigs > 60
    error('run_oo_contribution_validation_report:tooMany', ...
        ['%d figures exceeds limit of 60. This script runs ONE case only. ' ...
         'Check that no loops were added.'], nFigs);
end

% ======================================================================
%  WRITE PDF — bulletproof
% ======================================================================
outDir = fileparts(singlePdf);
if ~exist(outDir, 'dir')
    mkdir(outDir);
end

% Delete stale file so we can verify the new one by timestamp
if exist(singlePdf, 'file')
    delete(singlePdf);
end

% Build write config: savePdf MUST be true or ReportWriter silently skips
cfgReport                             = cfg;
cfgReport.plots.savePdf               = true;
cfgReport.plots.saveFigures           = false;
cfgReport.plots.saveIndividualFigures = false;
cfgReport.report.enable               = true;
cfgReport.report.outputPdf            = singlePdf;

fprintf('Writing PDF with %d figures...\n', nFigs);
revgnss.ReportWriter.write(singlePdf, allFigHandles, cfgReport);

% ======================================================================
%  VERIFY — must exist, nonzero, newly written
% ======================================================================
if ~exist(singlePdf, 'file')
    error('run_oo_contribution_validation_report:writeFailed', ...
        'PDF was not created: %s', singlePdf);
end

info = dir(singlePdf);
if info.bytes <= 0
    error('run_oo_contribution_validation_report:emptyPdf', ...
        'PDF exists but is empty: %s', singlePdf);
end

modTime = datetime(info.datenum, 'ConvertFrom', 'datenum');
if modTime < scriptStart - seconds(30)
    error('run_oo_contribution_validation_report:stalePdf', ...
        ['PDF timestamp (%s) predates script start (%s). ' ...
         'The file was not newly written: %s'], ...
        char(modTime), char(scriptStart), singlePdf);
end

fprintf('\nPDF created: %s\n(%.1f kB, %d figures)\n\n', ...
    singlePdf, info.bytes/1024, nFigs);

% ======================================================================
%  LOCAL FUNCTIONS
% ======================================================================

function cfg = buildReportCase(caseName, duration_s, showFigures)
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
            cfg.physics.sagnac.model.enable = true;

        case 'tower_survey_mismatch'
            cfg = revgnss.ConfigFactory.defaultConfig();
            cfg.effects.towerSurvey.truth.enable = true;
            cfg.effects.towerSurvey.model.enable = true;
            cfg.effects.towerSurvey.sigmaENU_m   = [0.05; 0.05; 0.10];

        case 'pco_mismatch'
            cfg = revgnss.ConfigFactory.defaultConfig();
            cfg.effects.antennaPCO.truth.enable          = true;
            cfg.effects.antennaPCO.model.enable          = true;
            cfg.effects.antennaPCO.receiverOffset_body_m = [0.05; 0.0; 0.02];

        case 'pcv_toy'
            cfg = revgnss.ConfigFactory.defaultConfig();
            cfg.effects.antennaPCV.truth.enable = true;
            cfg.effects.antennaPCV.model.enable = true;
            cfg.effects.antennaPCV.amplitude_m  = 0.01;

        case 'troposphere_mismatch'
            cfg = revgnss.ConfigFactory.defaultConfig();
            cfg.errors.troposphere.truth.enable        = true;
            cfg.errors.troposphere.truth.zenithDelay_m = 2.3;
            cfg.errors.troposphere.model.enable        = true;

        case 'ionosphere_mismatch'
            cfg = revgnss.ConfigFactory.defaultConfig();
            cfg.errors.ionosphere.truth.enable        = true;
            cfg.errors.ionosphere.truth.zenithDelay_m = 5.0;
            cfg.errors.ionosphere.model.enable        = true;

        case 'correlated_noise'
            cfg = revgnss.ConfigFactory.defaultConfig();
            cfg.effects.correlatedNoise.enable             = true;
            cfg.effects.correlatedNoise.commonModeSigma_m  = 0.15;
            cfg.effects.correlatedNoise.sameTowerSigma_m   = 0.10;
            cfg.effects.correlatedNoise.independentSigma_m = 0.05;

        case 'doppler_diag_only'
            cfg = revgnss.ConfigFactory.defaultConfig();
            cfg.measurements.doppler.enable    = true;
            cfg.measurements.doppler.useInEKF  = true;
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
            cfg.measurements.carrierPhase.useInEKF = true;

        case 'all_contributions_demo'
            % Demo case: mixed matched/mismatched effects for contribution diagnostics.
            % Matched: Sagnac, Shapiro  — truth and model both nonzero, mismatch near zero.
            % Mismatched: atmosphere, survey, PCO, PCV  — truth nonzero, model zero.
            % Stochastic: code noise, correlated noise  — truth nonzero, model = 0.
            % Diagnostic: Doppler, carrier phase  — not in EKF.
            cfg = revgnss.ConfigFactory.defaultConfig();
            % Matched geometry
            cfg.physics.sagnac.truth.enable = true;
            cfg.physics.sagnac.model.enable = true;
            cfg.physics.relativity.shapiro.truth.enable = true;
            cfg.physics.relativity.shapiro.model.enable = true;
            % Mismatched atmosphere
            cfg.errors.troposphere.truth.enable        = true;
            cfg.errors.troposphere.truth.zenithDelay_m = 2.3;
            cfg.errors.troposphere.model.enable        = false;
            cfg.errors.ionosphere.truth.enable         = true;
            cfg.errors.ionosphere.truth.zenithDelay_m  = 5.0;
            cfg.errors.ionosphere.model.enable         = false;
            % Mismatched survey/antenna
            cfg.effects.towerSurvey.truth.enable = true;
            cfg.effects.towerSurvey.model.enable = false;
            cfg.effects.towerSurvey.sigmaENU_m   = [0.05; 0.05; 0.10];
            cfg.effects.antennaPCO.truth.enable          = true;
            cfg.effects.antennaPCO.model.enable          = false;
            cfg.effects.antennaPCO.receiverOffset_body_m = [0.05; 0.0; 0.02];
            cfg.effects.antennaPCO.towerOffset_enu_m     = [0.03; 0.02; 0.05];
            cfg.effects.antennaPCV.truth.enable = true;
            cfg.effects.antennaPCV.model.enable = false;
            cfg.effects.antennaPCV.amplitude_m  = 0.01;
            % Correlated noise (truth only)
            cfg.effects.correlatedNoise.enable             = true;
            cfg.effects.correlatedNoise.commonModeSigma_m  = 0.15;
            cfg.effects.correlatedNoise.sameTowerSigma_m   = 0.10;
            cfg.effects.correlatedNoise.independentSigma_m = 0.05;
            % Doppler diagnostic only
            cfg.measurements.doppler.enable    = true;
            cfg.measurements.doppler.useInEKF  = false;
            cfg.measurements.doppler.sigma_mps = 0.01;
            cfg.physics.doppler.truth.enable   = true;
            cfg.physics.doppler.model.enable   = true;
            % Carrier diagnostic only
            cfg.measurements.carrierPhase.enable   = true;
            cfg.measurements.carrierPhase.useInEKF = false;

        case 'custom'
            cfg = revgnss.ConfigFactory.defaultConfig();
            % Add custom modifications below:

        otherwise
            error('run_oo_contribution_validation_report:unknownCase', ...
                'Unknown REPORT_CASE: ''%s''. See header for valid options.', caseName);
    end

    cfg.simulation.duration_s       = duration_s;
    cfg.plots.enable                = true;   % allow figure creation
    cfg.plots.showFigures           = showFigures;
    cfg.plots.savePdf               = false;  % suppress auto-save during run
    cfg.plots.saveFigures           = false;
    cfg.plots.saveIndividualFigures = false;
    cfg.report.enable               = false;  % suppress auto-report during run
end

function fig = makeSummaryFig(caseName, cfg, d, pdfPath, showFigures)
    vis = 'off';
    if showFigures; vis = 'on'; end
    fig = figure('Name', ['Summary: ' caseName], 'Visible', vis, ...
        'NumberTitle','off', 'Position',[100 100 720 440]);

    posErr  = d.getPositionErrors();
    nisVec  = d.getNIS();
    m_rows  = d.getNumMeasurementRows();
    nRx     = 1;
    nTowers = 0;
    if isfield(cfg,'scenario')
        if isfield(cfg.scenario,'nReceivers'); nRx     = cfg.scenario.nReceivers; end
        if isfield(cfg.scenario,'nTowers');    nTowers = cfg.scenario.nTowers;    end
    end
    if nTowers == 0 && isfield(cfg,'towers')
        nTowers = numel(cfg.towers);
    end

    maxMeas  = max(d.getNumMeasurements());
    maxRows  = max(m_rows);
    meanNIS  = mean(nisVec,'omitnan');
    finalPos = posErr(end);
    posRms   = rms(posErr(max(1, round(0.8*numel(posErr))):end));

    effects  = collectEnabledEffects(cfg);
    fxStr    = strjoin(effects, ', ');
    if isempty(fxStr); fxStr = 'none (baseline)'; end

    axes('Position',[0 0 1 1],'Visible','off'); %#ok<LAXES>

    lines_ = { ...
        '\bfContribution Validation Report — ONE simulation run only'; ...
        ''; ...
        sprintf('\\bfCase:\\rm  %s', strrep(caseName,'_',' ')); ...
        sprintf('Duration:              %.0f s', cfg.simulation.duration_s); ...
        sprintf('Towers:                %d', nTowers); ...
        sprintf('Receivers:             %d', nRx); ...
        sprintf('Max PR meas/epoch:     %d', maxMeas); ...
        sprintf('Max EKF rows/epoch:    %d', maxRows); ...
        sprintf('Final pos error:       %.4f m', finalPos); ...
        sprintf('Pos RMS (last 20%%):   %.4f m', posRms); ...
        sprintf('Mean NIS:              %.2f   (E[NIS] ~ %.0f)', meanNIS, mean(m_rows,'omitnan')); ...
        ''; ...
        sprintf('\\bfEnabled effects:\\rm  %s', fxStr); ...
        ''; ...
        sprintf('\\bfOutput PDF:\\rm  %s', pdfPath) };

    text(0.05, 0.95, lines_, 'Units','normalized', ...
        'VerticalAlignment','top','FontSize',11,'Interpreter','tex');
end

function effects = collectEnabledEffects(cfg)
    effects = {};
    if isfield(cfg,'physics')
        p = cfg.physics;
        if isfield(p,'sagnac')
            if isfield(p.sagnac,'truth') && isfield(p.sagnac.truth,'enable') && p.sagnac.truth.enable
                effects{end+1} = 'Sagnac-truth';
            end
            if isfield(p.sagnac,'model') && isfield(p.sagnac.model,'enable') && p.sagnac.model.enable
                effects{end+1} = 'Sagnac-model';
            end
        end
        if isfield(p,'relativity') && isfield(p.relativity,'shapiro') && ...
                isfield(p.relativity.shapiro,'truth') && ...
                isfield(p.relativity.shapiro.truth,'enable') && ...
                p.relativity.shapiro.truth.enable
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
        if isfield(cfg.measurements,'doppler') && ...
                isfield(cfg.measurements.doppler,'enable') && cfg.measurements.doppler.enable
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
end

function figs = plotCompactStandardSubset(d, ~, ~, cfg, t)
    % 8 essential figures when INCLUDE_ALL_STANDARD_PLOTS = false
    figs = gobjects(0);
    if ~isfield(cfg,'plots') || ~cfg.plots.enable; return; end

    f = gobjects(1,8);
    f(1) = revgnss.Plotter.plotPositionErrorComponents(d, t, cfg);
    f(2) = revgnss.Plotter.plotPositionErrorNorm(d, t, cfg);
    f(3) = revgnss.Plotter.plotAttitudeErrorComponents(d, t, cfg);
    f(4) = revgnss.Plotter.plotRxClockBias(d, t, cfg);
    f(5) = revgnss.Plotter.plotPrefitInnovationRMS(d, t, cfg);
    f(6) = revgnss.Plotter.plotPostfitResidualRMS(d, t, cfg);
    f(7) = revgnss.Plotter.plotNIS(d, t, cfg);
    f(8) = revgnss.Plotter.plotMeasurementCount(d, t, cfg);

    valid = isgraphics(f);
    figs  = f(valid);
    isFig = arrayfun(@(g) strcmp(get(g,'Type'),'figure'), figs);
    figs  = figs(isFig);
end
