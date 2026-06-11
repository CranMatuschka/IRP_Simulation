% run_oo_contribution_validation_report.m
%
% Creates one compact contribution validation PDF for one selected scenario.
% This is not a full case sweep.
%
% Output:
%   oo_v1/output/effect_contribution_validation_report.pdf
%
% Page budget (default):
%   1   summary page
%  17   standard diagnostic plots  (INCLUDE_FULL_STANDARD_PLOTS = true)
%   7   compact contribution plots
%   2   comparison summary (only if RUN_COMPARISON_SUMMARY = true)
%  ---
%  ~25  total
%
% Usage:
%   cd oo_v1
%   run_oo_contribution_validation_report

clear; close all; clc;

thisDir = fileparts(mfilename('fullpath'));
addpath(thisDir);

% ======================================================================
%  CONFIGURATION
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
%   'carrier_diag_only'     Carrier phase diagnostic
%   'custom'                Edit buildCaseConfig below
REPORT_CASE = 'baseline';

% If true: include all 17 standard diagnostic figures from Plotter.plotAll.
% If false: include a compact 8-figure subset (position/attitude/clock/NIS/RMS).
INCLUDE_FULL_STANDARD_PLOTS = false;

% If true: run 6 additional comparison cases and append a summary table/plot.
% No full per-case plots — only scalar metrics.
RUN_COMPARISON_SUMMARY = false;

duration_s  = 600;
showFigures = false;

% ======================================================================
%  OUTPUT PATH
% ======================================================================
singlePdf = fullfile(thisDir, 'output', 'effect_contribution_validation_report.pdf');
if ~exist(fullfile(thisDir, 'output'), 'dir')
    mkdir(fullfile(thisDir, 'output'));
end

% ======================================================================
%  BUILD + RUN ONE SCENARIO
% ======================================================================
cfg = buildCaseConfig(REPORT_CASE, duration_s, showFigures);

fprintf('\n=== Contribution Validation Report: %s ===\n', REPORT_CASE);
sim = revgnss.ReverseGNSSSimulation(cfg);
sim.initialize();
sim.run();

d = sim.diag;
t = d.getTimeVector();

% ======================================================================
%  ASSEMBLE FIGURES
% ======================================================================
allFigHandles = gobjects(0);

% 1) Case summary
figSum = makeSummaryFig(REPORT_CASE, cfg, d, showFigures);
allFigHandles = [allFigHandles; figSum];

% 2) Standard diagnostic plots
if INCLUDE_FULL_STANDARD_PLOTS
    stdFigs = revgnss.Plotter.plotAll(d, sim.asset, sim.towers, cfg);
    allFigHandles = [allFigHandles; stdFigs(:)];
    % Doppler RMS (separate unit — only include if Doppler configured)
    if isDopplerEnabled(cfg)
        figDop = revgnss.Plotter.plotDopplerRMS(d, t, cfg);
        allFigHandles = [allFigHandles; figDop];
    end
else
    compactStd = plotCompactStandardSubset(d, sim.asset, sim.towers, cfg, t);
    allFigHandles = [allFigHandles; compactStd(:)];
end

% 3) Compact contribution plots (7 grouped figures)
contribFigs = revgnss.ContributionPlotter.plotCompactContributionReport(d, cfg);
allFigHandles = [allFigHandles; contribFigs(:)];

% 4) Optional comparison summary (scalar metrics only, no per-case full reports)
if RUN_COMPARISON_SUMMARY
    compFigs = runComparisonSummary(duration_s, showFigures);
    allFigHandles = [allFigHandles; compFigs(:)];
end

% ======================================================================
%  WRITE SINGLE PDF
% ======================================================================
nFigs = numel(allFigHandles);
fprintf('Contribution validation report pages: %d figures\n', nFigs);
if nFigs > 40
    warning('run_oo_contribution_validation_report:tooLarge', ...
        'Report too large: expected compact report, got %d figures', nFigs);
end

revgnss.ReportWriter.write(singlePdf, allFigHandles, cfg);
fprintf('Written: %s\n\n', singlePdf);

% ======================================================================
%  LOCAL FUNCTIONS
% ======================================================================

function cfg = buildCaseConfig(caseName, duration_s, showFigures)
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
            cfg.effects.antennaPCV.model.enable = true;
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

        case 'carrier_diag_only'
            cfg = revgnss.ConfigFactory.defaultConfig();
            cfg.measurements.carrierPhase.enable   = true;
            cfg.measurements.carrierPhase.useInEKF = false;

        case 'custom'
            % Modify here for custom runs
            cfg = revgnss.ConfigFactory.defaultConfig();

        otherwise
            error('run_oo_contribution_validation_report:unknownCase', ...
                'Unknown REPORT_CASE: ''%s''. See header for valid options.', caseName);
    end
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

function tf = isDopplerEnabled(cfg)
    tf = isfield(cfg,'measurements') && ...
         isfield(cfg.measurements,'doppler') && ...
         isfield(cfg.measurements.doppler,'enable') && ...
         cfg.measurements.doppler.enable;
end

function fig = makeSummaryFig(caseName, cfg, d, showFigures)
    vis = 'off';
    if showFigures; vis = 'on'; end
    fig = figure('Name', ['Summary: ' caseName], 'Visible', vis, ...
        'NumberTitle','off', 'Position',[100 100 700 420]);

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
    posRms   = rms(posErr(max(1,round(0.8*numel(posErr))):end));

    % Collect enabled effects as a string
    effects = collectEnabledEffects(cfg);
    effectStr = strjoin(effects, ', ');
    if isempty(effectStr); effectStr = 'none (baseline)'; end

    nTowers = 0;
    if isfield(cfg,'scenario') && isfield(cfg.scenario,'nTowers')
        nTowers = cfg.scenario.nTowers;
    elseif isfield(cfg,'towers')
        nTowers = numel(cfg.towers);
    end

    axes('Position',[0 0 1 1],'Visible','off'); %#ok<LAXES>
    title('Contribution Validation Report — Case Summary');

    lines_ = { ...
        sprintf('\\bfCase:\\rm  %s', strrep(caseName,'_',' ')); ...
        ''; ...
        sprintf('Duration:              %.0f s', cfg.simulation.duration_s); ...
        sprintf('Towers:                %d', nTowers); ...
        sprintf('Receivers:             %d', nRx); ...
        sprintf('Max PR meas/epoch:     %d', maxMeas); ...
        sprintf('Max EKF rows/epoch:    %d', maxRows); ...
        sprintf('Final pos error:       %.4f m', finalPos); ...
        sprintf('Pos RMS (last 20%%):   %.4f m', posRms); ...
        sprintf('Mean NIS:              %.2f   (E[NIS] ~ %.0f)', ...
            meanNIS, mean(m_rows,'omitnan')); ...
        ''; ...
        sprintf('\\bfEnabled effects:\\rm  %s', effectStr) };

    text(0.05, 0.92, lines_, 'Units','normalized', ...
        'VerticalAlignment','top','FontSize',11, ...
        'Interpreter','tex');
end

function effects = collectEnabledEffects(cfg)
    effects = {};
    if isfield(cfg,'physics')
        p = cfg.physics;
        if isfield(p,'sagnac') && isfield(p.sagnac,'truth') && ...
                isfield(p.sagnac.truth,'enable') && p.sagnac.truth.enable
            effects{end+1} = 'Sagnac-truth';
        end
        if isfield(p,'sagnac') && isfield(p.sagnac,'model') && ...
                isfield(p.sagnac.model,'enable') && p.sagnac.model.enable
            effects{end+1} = 'Sagnac-model';
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
                isfield(cfg.measurements.doppler,'enable') && ...
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
end

function figs = plotCompactStandardSubset(d, asset, towers, cfg, t)
    % 8 essential figures when INCLUDE_FULL_STANDARD_PLOTS = false
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

function figs = runComparisonSummary(duration_s, showFigures)
    % Run 6 cases and collect only scalar metrics — no per-case full plots.
    cases = {'baseline', 'realistic_matched', 'sagnac_mismatch', ...
             'troposphere_mismatch', 'ionosphere_mismatch', 'correlated_noise'};
    nCases = numel(cases);

    results = struct();
    results.name            = cases;
    results.finalPosErr_m   = zeros(1, nCases);
    results.meanNIS         = zeros(1, nCases);
    results.meanPostfitRMS_m = zeros(1, nCases);
    results.maxContrib_m    = zeros(1, nCases);
    results.maxPRMeas       = zeros(1, nCases);

    for ci = 1:nCases
        try
            cfg = buildCaseConfig(cases{ci}, duration_s, false);
            cfg.plots.enable = false;   % suppress all plotting
            sim = revgnss.ReverseGNSSSimulation(cfg);
            sim.initialize();
            sim.run();
            d = sim.diag;

            posErr = d.getPositionErrors();
            nis    = d.getNIS();
            cs     = d.getContributionSeries();

            results.finalPosErr_m(ci)    = posErr(end);
            results.meanNIS(ci)          = mean(nis,'omitnan');
            results.meanPostfitRMS_m(ci) = mean(d.getPostfitPseudorangeRMS(),'omitnan');
            results.maxPRMeas(ci)        = max(d.getNumMeasurements());

            if isfield(cs,'totalTruthMinusModel_rms_m')
                results.maxContrib_m(ci) = max(cs.totalTruthMinusModel_rms_m);
            end
        catch ME
            fprintf('  WARNING: comparison case "%s" failed: %s\n', cases{ci}, ME.message);
        end
    end

    figs = gobjects(0);
    figs = [figs; makeComparisonTableFig(results, showFigures)];
    figs = [figs; makeComparisonBarFig(results, showFigures)];
end

function fig = makeComparisonTableFig(results, showFigures)
    vis = 'off'; if showFigures; vis = 'on'; end
    fig = figure('Name','Comparison Summary Table','Visible',vis,'NumberTitle','off');
    axes('Position',[0.02 0.02 0.96 0.96],'Visible','off'); %#ok<LAXES>

    hdr = sprintf('%-28s %12s %10s %12s %12s %8s', ...
        'Case', 'FinalPos[m]', 'MeanNIS', 'PostfitRMS[m]', 'MaxContrib[m]', 'MaxMeas');
    sep  = repmat('-', 1, 88);
    rows = {'\bfComparison Summary (scalar metrics only)'; ' '; hdr; sep};

    for ci = 1:numel(results.name)
        rows{end+1} = sprintf('%-28s %12.4f %10.2f %12.4f %12.4f %8d', ...
            results.name{ci}, ...
            results.finalPosErr_m(ci), ...
            results.meanNIS(ci), ...
            results.meanPostfitRMS_m(ci), ...
            results.maxContrib_m(ci), ...
            results.maxPRMeas(ci)); %#ok<AGROW>
    end

    text(0.02, 0.97, rows, ...
        'Units','normalized','VerticalAlignment','top', ...
        'FontSize',8,'FontName','Courier','Interpreter','tex');
end

function fig = makeComparisonBarFig(results, showFigures)
    vis = 'off'; if showFigures; vis = 'on'; end
    fig = figure('Name','Comparison Bar Chart','Visible',vis,'NumberTitle','off');
    nCases     = numel(results.name);
    shortNames = cellfun(@(s) strrep(s,'_','-'), results.name, 'UniformOutput', false);
    xIdx       = 1:nCases;

    subplot(2,1,1);
    bar(xIdx, [results.finalPosErr_m; results.meanPostfitRMS_m; results.maxContrib_m]', 'grouped');
    set(gca, 'XTick', xIdx, 'XTickLabel', shortNames, 'XTickLabelRotation', 20);
    legend('Final pos err [m]','Postfit RMS [m]','Max contrib [m]','Location','best','FontSize',7);
    ylabel('Metres'); title('Position & Pseudorange Metrics'); grid on;

    subplot(2,1,2);
    bar(xIdx, results.meanNIS, 'b');
    set(gca, 'XTick', xIdx, 'XTickLabel', shortNames, 'XTickLabelRotation', 20);
    ylabel('Mean NIS'); title('Mean NIS per Case'); grid on;

    sgtitle('Case Comparison Summary');
end
