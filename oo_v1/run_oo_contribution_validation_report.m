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
%  21  one page per contribution (Truth/Model/Mismatch lines or text page)
%  ----
%  41  total
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
%   'pcv_toy'               PCV truth only
%   'troposphere_mismatch'  Troposphere truth only
%   'ionosphere_mismatch'   Ionosphere truth only
%   'correlated_noise'      Correlated noise enabled
%   'doppler_diag_only'     Doppler diagnostic (not in EKF)
%   'doppler_ekf'           Doppler in EKF
%   'carrier_diag_only'     Carrier phase diagnostic
%   'all_contributions_matched' All deterministic effects matched — validates cancellation
%   'all_contributions_demo' Mixed matched/mismatched — default, for diagnostics
%   'dual_frequency_baseline'           L1+L2 baseline — code noise only, both signals
%   'ionosphere_dual_frequency_mismatch' Dual-freq iono truth only — visible freq-scaled mismatch
%   'ionosphere_dual_frequency_matched'  Dual-freq iono truth=model — should mostly cancel
%   'stochastic_environment_validation'  Trop GM + iono TEC GM, no model correction
%   'clock_noise_validation'             Stochastic clocks + noisy correction
%   'custom'                Edit buildReportCase below
REPORT_CASE = 'all_contributions_matched';

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
%  CONSOLE VALIDATION TABLE — contribution RMS summary
% ======================================================================
printContributionTable(REPORT_CASE, d);

% ======================================================================
%  LOCAL FUNCTIONS
% ======================================================================

function cfg = buildReportCase(caseName, duration_s, showFigures)
    % Delegate all named cases to ValidationCaseFactory so both scripts
    % share the same single source of truth.  'custom' is handled locally.
    if strcmp(caseName, 'custom')
        cfg = revgnss.ConfigFactory.defaultConfig();
        % Add custom modifications below:
        cfg.simulation.duration_s       = duration_s;
        cfg.plots.enable                = true;
        cfg.plots.showFigures           = showFigures;
        cfg.plots.savePdf               = false;
        cfg.plots.saveFigures           = false;
        cfg.plots.saveIndividualFigures = false;
        cfg.report.enable               = false;
    else
        cfg = revgnss.ValidationCaseFactory.buildCase(caseName, duration_s, showFigures);
    end
end

function fig = makeSummaryFig(caseName, cfg, d, pdfPath, showFigures)
    vis = 'off';
    if showFigures; vis = 'on'; end
    fig = figure('Name', ['Summary: ' caseName], 'Visible', vis, ...
        'NumberTitle','off', 'Position',[100 100 800 500]);

    posErr  = d.getPositionErrors();
    nisVec  = d.getNIS();
    m_rows  = d.getNumMeasurementRows();
    nRx     = 3;
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

    eff  = collectEffectCategories(cfg);
    tStr = strjoin(eff.truth,      ', '); if isempty(tStr); tStr = 'none'; end
    mStr = strjoin(eff.model,      ', '); if isempty(mStr); mStr = 'none'; end
    xStr = strjoin(eff.mismatched, ', '); if isempty(xStr); xStr = 'none'; end
    desc = getCaseDescription(caseName);

    axes('Position',[0 0 1 1],'Visible','off'); %#ok<LAXES>

    lines_ = { ...
        '\bfContribution Validation Report — ONE simulation run only'; ...
        ''; ...
        sprintf('\\bfCase:\\rm  %s', strrep(caseName,'_',' ')); ...
        sprintf('\\bfType:\\rm  %s', desc); ...
        ''; ...
        sprintf('Duration:              %.0f s', cfg.simulation.duration_s); ...
        sprintf('Towers:                %d', nTowers); ...
        sprintf('Receivers:             %d', nRx); ...
        sprintf('Max PR meas/epoch:     %d', maxMeas); ...
        sprintf('Max EKF rows/epoch:    %d', maxRows); ...
        sprintf('Final pos error:       %.4f m', finalPos); ...
        sprintf('Pos RMS (last 20%%):   %.4f m', posRms); ...
        sprintf('Mean NIS:              %.2f   (E[NIS] ~ %.0f)', meanNIS, mean(m_rows,'omitnan')); ...
        ''; ...
        sprintf('\\bfTruth effects:\\rm    %s', tStr); ...
        sprintf('\\bfModel effects:\\rm    %s', mStr); ...
        sprintf('\\bfMismatched:\\rm       %s', xStr); ...
        ''; ...
        sprintf('\\bfOutput PDF:\\rm  %s', pdfPath) };

    text(0.03, 0.97, lines_, 'Units','normalized', ...
        'VerticalAlignment','top','FontSize',10,'Interpreter','tex');
end

function desc = getCaseDescription(caseName)
    switch caseName
        case 'baseline';             desc = 'Baseline — code noise only, no physics effects';
        case 'all_contributions_demo';  desc = 'Mixed diagnostic — Sagnac/Shapiro matched; atmosphere/survey/PCO/PCV mismatched';
        case 'all_contributions_matched'; desc = 'Matched validation — all deterministic effects matched (expect mismatch < 0.05 m)';
        case 'sagnac_mismatch';      desc = 'Single-effect mismatch — Sagnac truth only, model off';
        case 'tower_survey_mismatch'; desc = 'Single-effect mismatch — tower survey offset truth only, model off';
        case 'pco_mismatch';         desc = 'Single-effect mismatch — receiver PCO truth only, model off';
        case 'pcv_toy';              desc = 'Single-effect mismatch — PCV truth only, model off';
        case 'troposphere_mismatch'; desc = 'Single-effect mismatch — troposphere truth only, model off';
        case 'ionosphere_mismatch';  desc = 'Single-effect mismatch — ionosphere truth only, model off';
        case 'realistic_matched';    desc = 'Realistic — Sagnac + Shapiro truth+model matched';
        case 'correlated_noise';     desc = 'Stochastic — correlated noise only';
        case 'doppler_diag_only';    desc = 'Diagnostic — Doppler measurements recorded, not used in EKF';
        case 'doppler_ekf';          desc = 'EKF augmentation — Doppler measurements fed into EKF';
        case 'carrier_diag_only';    desc = 'Diagnostic — carrier phase recorded, not used in EKF';
        case 'multi_receiver_att';   desc = 'Attitude estimation — multiple receivers';
        case 'dual_frequency_baseline'; desc = 'Dual-frequency (L1+L2) baseline — code noise only';
        case 'ionosphere_dual_frequency_mismatch'; desc = 'Dual-freq — ionosphere truth only, frequency-scaled mismatch';
        case 'ionosphere_dual_frequency_matched';  desc = 'Dual-freq — ionosphere truth=model, should cancel';
        case 'stochastic_environment_validation';  desc = 'Stochastic — troposphere GM + ionosphere TEC GM, no model correction';
        case 'clock_noise_validation'; desc = 'Stochastic — clock noise validation with noisy correction';
        case 'custom';               desc = 'Custom — user-defined configuration';
        otherwise;                   desc = strrep(caseName, '_', ' ');
    end
end

function eff = collectEffectCategories(cfg)
    eff.truth      = {};
    eff.model      = {};
    eff.mismatched = {};

    % {displayName, truth-path-cell, model-path-cell}
    % Empty model path = stochastic/diagnostic (no model cancellation expected)
    checks = { ...
        'Sagnac',      {'physics','sagnac','truth','enable'},                  {'physics','sagnac','model','enable'}; ...
        'Shapiro',     {'physics','relativity','shapiro','truth','enable'},     {'physics','relativity','shapiro','model','enable'}; ...
        'Trop',        {'errors','troposphere','truth','enable'},               {'errors','troposphere','model','enable'}; ...
        'Iono',        {'errors','ionosphere','truth','enable'},                {'errors','ionosphere','model','enable'}; ...
        'HWDelay',     {'errors','hardwareDelay','truth','enable'},             {'errors','hardwareDelay','model','enable'}; ...
        'Multipath',   {'errors','multipath','truth','enable'},                 {'errors','multipath','model','enable'}; ...
        'TowerSurvey', {'effects','towerSurvey','truth','enable'},              {'effects','towerSurvey','model','enable'}; ...
        'PCO',         {'effects','antennaPCO','truth','enable'},               {'effects','antennaPCO','model','enable'}; ...
        'PCV',         {'effects','antennaPCV','truth','enable'},               {'effects','antennaPCV','model','enable'}; ...
        'CorrNoise',   {'effects','correlatedNoise','enable'},                  {}; ...
        'Doppler',     {'measurements','doppler','enable'},                     {}; ...
        'Carrier',     {'measurements','carrierPhase','enable'},                {} };

    for k = 1:size(checks, 1)
        name  = checks{k,1};
        tPath = checks{k,2};
        mPath = checks{k,3};
        tOn   = safeField_(cfg, tPath);
        mOn   = ~isempty(mPath) && safeField_(cfg, mPath);
        if tOn
            eff.truth{end+1} = name;
            if ~isempty(mPath) && ~mOn
                eff.mismatched{end+1} = name;
            end
        end
        if mOn
            eff.model{end+1} = name;
        end
    end
end

function v = safeField_(s, fields)
    v = false;
    try
        for k = 1:numel(fields)
            s = s.(fields{k});
        end
        v = ~isempty(s) && logical(s);
    catch
        % missing field → false
    end
end

function printContributionTable(caseName, d)
    cs = d.getContributionSeries();
    if isempty(fieldnames(cs))
        fprintf('No contribution data available.\n');
        return;
    end
    isMatchedCase = strcmp(caseName, 'all_contributions_matched');
    WARN_THRESH_M = 0.05;

    fprintf('\n=== Contribution Validation Table: %s ===\n', caseName);
    fprintf('%-28s  %10s  %10s  %10s\n', 'Effect', 'TruthRMS_m', 'ModelRMS_m', 'MismatchRMS_m');
    fprintf('%s\n', repmat('-', 1, 66));

    effOrder  = {'total','codeNoise','scintillationCodeNoise','troposphere','ionosphere', ...
                 'hardwareDelay','multipath','sagnac','shapiro','towerSurvey','receiverPCO', ...
                 'towerPCO','pcv','towerClock','correlatedCommonMode','correlatedSameTower', ...
                 'correlatedIndependent'};
    effLabels = {'TOTAL','Code Noise','Scintillation Noise','Troposphere','Ionosphere', ...
                 'HW Delay','Multipath','Sagnac','Shapiro','Tower Survey','Rx PCO', ...
                 'Tower PCO','PCV','Tower Clock','Corr CM','Corr ST','Corr Ind'};

    % Stochastic effects (truth=random draw, model=0); never trigger matched-case WARN.
    stochasticEffs = {'total', 'codeNoise', 'scintillationCodeNoise'};

    anyWarn = false;
    for k = 1:numel(effOrder)
        eff = effOrder{k};
        if ~isfield(cs, eff); continue; end
        ef = cs.(eff);
        if ~isfield(ef, 'truthRMS_m'); continue; end
        n      = numel(ef.truthRMS_m);
        iStart = max(1, round(0.8 * n));
        tRms   = mean(ef.truthRMS_m(iStart:end));
        mRms   = 0; if isfield(ef,'modelRMS_m');    mRms = mean(ef.modelRMS_m(iStart:end));    end
        dRms   = 0; if isfield(ef,'mismatchRMS_m'); dRms = mean(ef.mismatchRMS_m(iStart:end)); end
        warnStr = '';
        isDeterministic = ~ismember(eff, stochasticEffs);
        if isMatchedCase && isDeterministic && dRms > WARN_THRESH_M
            warnStr  = '  <<< WARN';
            anyWarn  = true;
        end
        fprintf('%-28s  %10.4f  %10.4f  %10.4f%s\n', effLabels{k}, tRms, mRms, dRms, warnStr);
    end
    fprintf('%s\n', repmat('-', 1, 66));
    if isMatchedCase
        if anyWarn
            fprintf('WARN: matched case has contributions > %.2f m. Check truth/model parameters.\n\n', WARN_THRESH_M);
        else
            fprintf('PASS: all matched contributions below %.2f m threshold.\n\n', WARN_THRESH_M);
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
