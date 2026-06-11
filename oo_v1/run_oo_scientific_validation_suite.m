% run_oo_scientific_validation_suite.m
%
% Compact scientific validation suite for the reverse-GNSS EKF simulator.
%
% Checks whether the simulator is scientifically coherent across:
%   - Baseline (code noise only)
%   - All-matched (every deterministic effect truth=model → zero mismatch)
%   - One-effect mismatch (effect visible in residuals when unmodelled)
%   - Diagnostic-only (Doppler / carrier diagnostic without EKF modification)
%
% Outputs:
%   output/scientific_validation_summary.pdf    5-6 page compact report
%   output/scientific_validation_summary.csv    metric table (one row per case)
%   output/scientific_validation_results.mat    full results + git info
%
% Carrier-phase TODO: split into noise/ambiguity/residual/iono-sign/phase-wind-up sub-cases
% Doppler TODO: split into geometric-range-rate/rx-clock-drift/tower-clock-drift/noise/Sagnac
%
% Usage:
%   cd oo_v1
%   run_oo_scientific_validation_suite

clear; close all; clc;
suiteStart = datetime('now');

% --- Toggle flags (edit here) -----------------------------------------------
SUITE_DURATION_S = 600;     % seconds per case
RUN_DOPPLER_EKF  = false;   % true to also run doppler_ekf case
RUN_CARRIER_DIAG = false;   % true to also run carrier_diag_only case
RUN_DUAL_FREQUENCY_CASES   = true;   % dual-frequency L1+L2 cases
RUN_STOCHASTIC_ENV_CASE    = true;   % stochastic trop + iono GM case
RUN_CLOCK_NOISE_VALIDATION = true;   % stochastic clocks + noisyCorrection

thisDir = fileparts(mfilename('fullpath'));
addpath(thisDir);

% --- Output paths -----------------------------------------------------------
outDir  = fullfile(thisDir, 'output');
pdfPath = fullfile(outDir, 'scientific_validation_summary.pdf');
csvPath = fullfile(outDir, 'scientific_validation_summary.csv');
matPath = fullfile(outDir, 'scientific_validation_results.mat');
if ~exist(outDir, 'dir'); mkdir(outDir); end

% --- Case list --------------------------------------------------------------
SUITE_CASES = {'baseline', ...
               'all_contributions_matched', ...
               'all_contributions_demo', ...
               'sagnac_mismatch', ...
               'troposphere_mismatch', ...
               'ionosphere_mismatch', ...
               'tower_survey_mismatch', ...
               'pco_mismatch', ...
               'pcv_toy', ...
               'correlated_noise', ...
               'doppler_diag_only'};
if RUN_DOPPLER_EKF;  SUITE_CASES{end+1} = 'doppler_ekf';      end
if RUN_CARRIER_DIAG; SUITE_CASES{end+1} = 'carrier_diag_only'; end
if RUN_DUAL_FREQUENCY_CASES
    SUITE_CASES{end+1} = 'dual_frequency_baseline';
    SUITE_CASES{end+1} = 'ionosphere_dual_frequency_mismatch';
    SUITE_CASES{end+1} = 'ionosphere_dual_frequency_matched';
end
if RUN_STOCHASTIC_ENV_CASE;    SUITE_CASES{end+1} = 'stochastic_environment_validation'; end
if RUN_CLOCK_NOISE_VALIDATION; SUITE_CASES{end+1} = 'clock_noise_validation'; end

nCases = numel(SUITE_CASES);
fprintf('\n=== Scientific Validation Suite: %d cases × %d s ===\n\n', nCases, SUITE_DURATION_S);

% --- Run cases --------------------------------------------------------------
caseResults = cell(nCases, 1);
for c = 1:nCases
    caseName = SUITE_CASES{c};
    fprintf('  [%2d/%2d] %-28s ...', c, nCases, caseName);
    t0  = tic;
    cfg = revgnss.ValidationCaseFactory.buildCase(caseName, SUITE_DURATION_S, false);
    sim = revgnss.ReverseGNSSSimulation(cfg);
    sim.initialize();
    sim.run();
    caseResults{c} = collectMetrics(caseName, sim.cfg, sim.diag);
    elapsed = toc(t0);
    fprintf(' posErr=%7.3f m  (%.1f s)\n', caseResults{c}.finalPositionError_m, elapsed);
end

% --- Apply validation rules -------------------------------------------------
baselinePosErr = caseResults{1}.finalPositionError_m;
for c = 1:nCases
    caseResults{c} = applyRules(caseResults{c}, baselinePosErr);
end

% --- Console summary --------------------------------------------------------
printSummary(caseResults);

% --- Write outputs ----------------------------------------------------------
if exist(pdfPath, 'file'); delete(pdfPath); end
figs = makeSummaryFigures(caseResults);
writeResultsPDF(pdfPath, figs);
writeCSV(caseResults, csvPath);
writeMAT(caseResults, matPath, SUITE_DURATION_S, suiteStart);

% --- Verify outputs ---------------------------------------------------------
assert(exist(pdfPath,'file') == 2 && dir(pdfPath).bytes > 1000, ...
    'PDF not created or too small: %s', pdfPath);
assert(exist(csvPath,'file') == 2, 'CSV not created: %s', csvPath);

fprintf('\nOutputs written:\n');
fprintf('  PDF: %s  (%.1f kB)\n', pdfPath, dir(pdfPath).bytes/1024);
fprintf('  CSV: %s\n', csvPath);
fprintf('  MAT: %s\n\n', matPath);

% ============================================================================
%  LOCAL FUNCTIONS
% ============================================================================

% --- Metric collection -------------------------------------------------------
function r = collectMetrics(caseName, cfg, d)
    r.caseName   = caseName;
    r.duration_s = cfg.simulation.duration_s;
    r.nReceivers = 1;
    try; r.nReceivers = cfg.scenario.nReceivers; catch; end

    n  = d.nEpochs;
    iS = max(1, round(0.8 * n));   % last-20% steady-state window

    posErr = d.getPositionErrors();
    clkErr = d.getClockBiasErrors();
    nisVec = d.getNIS();
    mRows  = d.getNumMeasurementRows();
    pfPR   = d.getPrefitPseudorangeRMS();
    poPR   = d.getPostfitPseudorangeRMS();
    pfDop  = d.getPrefitDopplerRMS();

    r.finalPositionError_m        = posErr(end);
    r.positionRMS_last20_m        = rms(posErr(iS:end));
    r.finalClockBiasError_m       = clkErr(end);
    r.clockBiasRMS_last20_m       = rms(clkErr(iS:end));
    r.maxPseudorangeMeasurements  = max(d.getNumMeasurements());
    r.maxMeasurementRows          = max(mRows);
    r.meanNIS                     = mean(nisVec(iS:end), 'omitnan');
    r.expectedNIS                 = mean(double(mRows(iS:end)), 'omitnan');
    r.meanPrefitPseudorangeRMS_m  = mean(pfPR(iS:end));
    r.meanPostfitPseudorangeRMS_m = mean(poPR(iS:end));
    r.meanDopplerRMS_mps          = mean(pfDop(iS:end));

    gdop = d.getGDOPLike();
    pdop = d.getPDOPLike();
    tdop = d.getTDOPLike();
    grnk = d.getGeometryRank();
    r.meanGDOPLike       = mean(gdop(isfinite(gdop)), 'omitnan');
    r.meanPDOPLike       = mean(pdop(isfinite(pdop)), 'omitnan');
    r.meanTDOPLike       = mean(tdop(isfinite(tdop)), 'omitnan');
    r.meanGeometryRank   = mean(double(grnk(isfinite(grnk))), 'omitnan');

    cs = d.getContributionSeries();

    r.maxTotalTruthRMS_m              = csGet_(cs, 'total',       'truthRMS_m',    iS, 'max');
    r.maxTotalModelRMS_m              = csGet_(cs, 'total',       'modelRMS_m',    iS, 'max');
    r.maxTotalMismatchRMS_m           = csGet_(cs, 'total',       'mismatchRMS_m', iS, 'max');
    r.meanTotalMismatchRMS_last20_m   = csGet_(cs, 'total',       'mismatchRMS_m', iS, 'mean');

    r.maxSagnacMismatch_m       = csGet_(cs, 'sagnac',       'mismatchRMS_m', iS, 'max');
    r.maxShapiroMismatch_m      = csGet_(cs, 'shapiro',      'mismatchRMS_m', iS, 'max');
    r.maxTroposphereMismatch_m  = csGet_(cs, 'troposphere',  'mismatchRMS_m', iS, 'max');
    r.maxIonosphereMismatch_m   = csGet_(cs, 'ionosphere',   'mismatchRMS_m', iS, 'max');
    r.maxTowerSurveyMismatch_m  = csGet_(cs, 'towerSurvey',  'mismatchRMS_m', iS, 'max');
    r.maxReceiverPCOMismatch_m  = csGet_(cs, 'receiverPCO',  'mismatchRMS_m', iS, 'max');
    r.maxTowerPCOMismatch_m     = csGet_(cs, 'towerPCO',     'mismatchRMS_m', iS, 'max');
    r.maxPCVMismatch_m          = csGet_(cs, 'pcv',          'mismatchRMS_m', iS, 'max');

    r.maxCorrelatedNoiseMismatch_m = max([ ...
        csGet_(cs, 'correlatedCommonMode',  'mismatchRMS_m', iS, 'max'), ...
        csGet_(cs, 'correlatedSameTower',   'mismatchRMS_m', iS, 'max'), ...
        csGet_(cs, 'correlatedIndependent', 'mismatchRMS_m', iS, 'max')]);

    % --- New metrics: dual-frequency and stochastic environment --------
    try
        signals = revgnss.SignalUtils.getEnabledSignals(cfg);
        r.nSignals = numel(signals);
    catch
        r.nSignals = 1;
    end
    try
        r.enabledSignals = strjoin(cfg.signals.enabled, '+');
    catch
        r.enabledSignals = 'L1';
    end
    r.maxMeasurements    = max(d.getNumMeasurements());
    r.maxMeasurementRows = max(d.getNumMeasurementRows());
    r.meanScintillationRMS_m = csGet_(cs, 'scintillationCodeNoise', 'truthRMS_m', iS, 'mean');
    r.maxIonoMismatchL1_m  = 0;
    r.maxIonoMismatchL2_m  = 0;
    r.ionoL2overL1Ratio    = NaN;
    % Clock bias/drift RMS (last 20%)
    clkDrift = d.getClockDriftErrors();
    r.clockDriftRMS_last20_mps = rms(clkDrift(iS:end));

    r.status   = 'UNKNOWN';
    r.notes    = '';
    r.passFail = false;
end

% --- Validation rules --------------------------------------------------------
function r = applyRules(r, baselinePosErr)
    ok = true;
    nn = {};

    switch r.caseName

        case 'baseline'
            if r.finalPositionError_m > 50
                ok = false;
                nn{end+1} = sprintf('posErr %.2f > 50 m', r.finalPositionError_m);
            end
            [nisOk, nisNote] = checkNIS_(r);
            if ~nisOk; ok = false; nn{end+1} = nisNote; end
            r.status = iff_(ok, 'PASS', 'FAIL');

        case 'all_contributions_matched'
            thresh = max(50, 3 * baselinePosErr);
            if r.finalPositionError_m > thresh
                ok = false;
                nn{end+1} = sprintf('posErr %.2f > %.1f m', r.finalPositionError_m, thresh);
            end
            % Total mismatch includes code noise (~0.3 m); deterministic effects
            % are validated individually below.  Only flag catastrophic failures here.
            if r.meanTotalMismatchRMS_last20_m > 1.0
                ok = false;
                nn{end+1} = sprintf('meanTotalMismatch %.4f m > 1.0 m', r.meanTotalMismatchRMS_last20_m);
            end
            detFlds = {'maxSagnacMismatch_m','maxShapiroMismatch_m', ...
                       'maxTroposphereMismatch_m','maxIonosphereMismatch_m', ...
                       'maxTowerSurveyMismatch_m','maxReceiverPCOMismatch_m', ...
                       'maxTowerPCOMismatch_m','maxPCVMismatch_m'};
            for k = 1:numel(detFlds)
                val = r.(detFlds{k});
                if val > 0.01
                    ok = false;
                    nn{end+1} = sprintf('%s %.5f m > 0.01 m', detFlds{k}, val);
                end
            end
            r.status = iff_(ok, 'PASS', 'FAIL');

        case 'all_contributions_demo'
            r.status = 'INFO';
            nn{end+1} = 'mixed mismatch demo — large residuals expected';
            ok = true;

        case 'sagnac_mismatch'
            ok = r.maxSagnacMismatch_m > 1;
            if ~ok
                nn{end+1} = sprintf('Sagnac mismatch %.4f m < 1 m', r.maxSagnacMismatch_m);
            end
            r.status = iff_(ok, 'PASS', 'FAIL');

        case 'troposphere_mismatch'
            ok = r.maxTroposphereMismatch_m > 1;
            if ~ok
                nn{end+1} = sprintf('Trop mismatch %.4f m < 1 m', r.maxTroposphereMismatch_m);
            end
            r.status = iff_(ok, 'PASS', 'FAIL');

        case 'ionosphere_mismatch'
            ok = r.maxIonosphereMismatch_m > 1;
            if ~ok
                nn{end+1} = sprintf('Iono mismatch %.4f m < 1 m', r.maxIonosphereMismatch_m);
            end
            r.status = iff_(ok, 'PASS', 'FAIL');

        case 'tower_survey_mismatch'
            ok = r.maxTowerSurveyMismatch_m > 0.01;
            if ~ok
                nn{end+1} = sprintf('TwrSvy mismatch %.5f m < 0.01 m', r.maxTowerSurveyMismatch_m);
            end
            r.status = iff_(ok, 'PASS', 'FAIL');

        case 'pco_mismatch'
            pcoMax = max(r.maxReceiverPCOMismatch_m, r.maxTowerPCOMismatch_m);
            ok = pcoMax > 0.005;
            if ~ok
                nn{end+1} = sprintf('PCO mismatch %.5f m < 0.005 m', pcoMax);
            end
            r.status = iff_(ok, 'PASS', 'FAIL');

        case 'pcv_toy'
            ok = r.maxPCVMismatch_m > 0.001;
            if ~ok
                nn{end+1} = sprintf('PCV mismatch %.6f m < 0.001 m', r.maxPCVMismatch_m);
            end
            r.status = iff_(ok, 'PASS', 'FAIL');

        case 'correlated_noise'
            ok = r.maxCorrelatedNoiseMismatch_m > 0.01;
            if ~ok
                nn{end+1} = sprintf('CorrNoise mismatch %.5f m < 0.01 m', r.maxCorrelatedNoiseMismatch_m);
            end
            r.status = iff_(ok, 'PASS', 'FAIL');

        case 'doppler_diag_only'
            r.status = 'INFO';
            nn{end+1} = 'Doppler diagnostic — not in EKF, no pass/fail rule';
            ok = true;

        case 'doppler_ekf'
            r.status = 'INFO';
            nn{end+1} = 'Doppler in EKF — validation rules TBD';
            ok = true;

        case 'carrier_diag_only'
            r.status = 'INFO';
            nn{end+1} = 'Carrier phase diagnostic — full rules TBD';
            ok = true;

        case 'dual_frequency_baseline'
            % Dual-frequency: expect N_sig × measurement rows
            if r.maxMeasurementRows < 2
                ok = false;
                nn{end+1} = sprintf('dual-freq maxMeasRows=%d < 2', r.maxMeasurementRows);
            end
            [nisOk, nisNote] = checkNIS_(r);
            if ~nisOk; ok = false; nn{end+1} = nisNote; end
            if r.finalPositionError_m > 100
                ok = false;
                nn{end+1} = sprintf('posErr %.2f m > 100 m', r.finalPositionError_m);
            end
            nn{end+1} = sprintf('nSignals=%d maxRows=%d', r.nSignals, r.maxMeasurementRows);
            r.status = iff_(ok, 'PASS', 'FAIL');

        case 'ionosphere_dual_frequency_mismatch'
            % L2 iono delay should be larger than L1 (ratio ≈ (f_L1/f_L2)^2 ≈ 1.647)
            ok = r.maxIonosphereMismatch_m > 1;
            if ~ok
                nn{end+1} = sprintf('iono mismatch %.4f m < 1 m', r.maxIonosphereMismatch_m);
            end
            nn{end+1} = sprintf('nSignals=%d enabledSigs=%s', r.nSignals, r.enabledSignals);
            r.status = iff_(ok, 'PASS', 'FAIL');

        case 'ionosphere_dual_frequency_matched'
            % Matched iono truth=model: mismatch should be near zero
            if r.maxIonosphereMismatch_m > 0.1
                ok = false;
                nn{end+1} = sprintf('matched iono mismatch %.4f m > 0.1 m', r.maxIonosphereMismatch_m);
            end
            nn{end+1} = sprintf('nSignals=%d', r.nSignals);
            r.status = iff_(ok, 'PASS', 'FAIL');

        case 'stochastic_environment_validation'
            % Stochastic GM models: mark INFO (no strict NIS rule — R may not match stochastic)
            r.status = 'INFO';
            nn{end+1} = 'stochastic GM trop+iono — NIS rule relaxed';
            ok = true;
            if isnan(r.meanNIS) || isinf(r.meanNIS)
                ok = false;
                r.status = 'FAIL';
                nn{end+1} = 'NIS is NaN/Inf';
            end
            if r.finalPositionError_m > 5e4
                ok = false;
                r.status = 'FAIL';
                nn{end+1} = sprintf('posErr %.2f m >> 50 km', r.finalPositionError_m);
            end

        case 'clock_noise_validation'
            r.status = 'INFO';
            nn{end+1} = sprintf('stochastic clocks noisyCorrection — posErr=%.2f m', ...
                r.finalPositionError_m);
            ok = true;

        otherwise
            r.status = 'SKIP';
            ok = false;
            nn{end+1} = 'no rule defined for this case';
    end

    r.passFail = ok;
    r.notes    = strjoin(nn, '; ');
end

% --- Console summary ---------------------------------------------------------
function printSummary(caseResults)
    nC = numel(caseResults);
    fprintf('\n=== Validation Results ===\n');
    fprintf('%-28s  %9s  %9s  %7s  %7s  %9s  %6s\n', ...
        'Case', 'PosErr_m', 'PosRMS_m', 'NIS', 'ExpNIS', 'Mismatch', 'Status');
    fprintf('%s\n', repmat('-', 1, 85));
    for c = 1:nC
        r = caseResults{c};
        fprintf('%-28s  %9.3f  %9.3f  %7.2f  %7.1f  %9.4f  %6s\n', ...
            r.caseName, r.finalPositionError_m, r.positionRMS_last20_m, ...
            r.meanNIS, r.expectedNIS, r.meanTotalMismatchRMS_last20_m, r.status);
    end
    fprintf('%s\n', repmat('-', 1, 85));
    nPass = sum(cellfun(@(r) r.passFail,             caseResults));
    nFail = sum(cellfun(@(r) strcmp(r.status,'FAIL'), caseResults));
    nInfo = sum(cellfun(@(r) strcmp(r.status,'INFO'), caseResults));
    fprintf('  PASS: %d   FAIL: %d   INFO: %d   (Total: %d)\n\n', nPass, nFail, nInfo, nC);
end

% --- Build all summary figures -----------------------------------------------
function figs = makeSummaryFigures(caseResults)
    nC    = numel(caseResults);
    names = cellfun(@(r) strrep(r.caseName, '_', '-'), caseResults, 'UniformOutput', false);

    clrs = zeros(nC, 3);
    for c = 1:nC
        clrs(c,:) = statusColor_(caseResults{c}.status);
    end

    posErr   = cellfun(@(r) r.finalPositionError_m,          caseResults);
    mismatch = cellfun(@(r) r.meanTotalMismatchRMS_last20_m, caseResults);
    nisRatio = cellfun(@(r) r.meanNIS / max(r.expectedNIS, 0.01), caseResults);

    figs(1) = makeSummaryTable_(caseResults, names);
    figs(2) = makeBarFig_(names, posErr,   clrs, 'Final Position Error by Case',         'Position Error [m]',      true);
    figs(3) = makeBarFig_(names, mismatch, clrs, 'Mean Total Mismatch RMS by Case (last 20%)', 'Mismatch RMS [m]', false);
    figs(4) = makeMatchedDetail_(caseResults);
    figs(5) = makeMismatchDetail_(caseResults);
    figs(6) = makeNISFig_(names, nisRatio, clrs);
end

% --- Figure 1: summary table -------------------------------------------------
function fig = makeSummaryTable_(caseResults, names)
    nC  = numel(caseResults);
    fig = figure('Visible','off','Name','Validation Summary Table', ...
        'NumberTitle','off','Position',[50 50 960 640]);
    axes('Position',[0 0 1 1],'Visible','off');

    lines = {'=== Scientific Validation Suite — Numerical Summary ==='; ''};
    hdr   = sprintf('%-28s  %9s  %9s  %7s  %7s  %9s  %6s', ...
        'Case', 'PosErr_m', 'PosRMS_m', 'NIS', 'ExpNIS', 'MismRMS', 'Status');
    lines{end+1} = hdr;
    lines{end+1} = repmat('-', 1, 82);
    for c = 1:nC
        r = caseResults{c};
        lines{end+1} = sprintf('%-28s  %9.3f  %9.3f  %7.2f  %7.1f  %9.4f  %6s', ...
            names{c}, r.finalPositionError_m, r.positionRMS_last20_m, ...
            r.meanNIS, r.expectedNIS, r.meanTotalMismatchRMS_last20_m, r.status);
    end
    lines{end+1} = repmat('-', 1, 82);
    nPass = sum(cellfun(@(r) r.passFail,             caseResults));
    nFail = sum(cellfun(@(r) strcmp(r.status,'FAIL'), caseResults));
    nInfo = sum(cellfun(@(r) strcmp(r.status,'INFO'), caseResults));
    lines{end+1} = '';
    lines{end+1} = sprintf('PASS: %d   FAIL: %d   INFO: %d   (Total: %d)', nPass, nFail, nInfo, nC);

    text(0.02, 0.97, lines, 'Units','normalized', ...
        'VerticalAlignment','top','FontSize',8.5,'FontName','FixedWidth', ...
        'Interpreter','none');
end

% --- Figure 2/3: generic bar chart -------------------------------------------
function fig = makeBarFig_(names, values, clrs, titleStr, ylabelStr, useLogScale)
    nC  = numel(names);
    fig = figure('Visible','off','Name',titleStr,'NumberTitle','off', ...
        'Position',[50 50 920 500]);
    ax = axes('Parent', fig);
    hold(ax, 'on');
    for c = 1:nC
        v = max(values(c), 0);
        bar(ax, c, v, 'FaceColor', clrs(c,:), 'EdgeColor', [0.25 0.25 0.25], 'LineWidth', 0.5);
    end
    hold(ax, 'off');
    set(ax, 'XTick', 1:nC, 'XTickLabel', names, 'XTickLabelRotation', 38, ...
        'TickLabelInterpreter', 'none');
    ylabel(ax, ylabelStr);
    title(ax, titleStr, 'Interpreter', 'none');
    grid(ax, 'on');
    xlim(ax, [0.5, nC+0.5]);
    if useLogScale
        valid = values(values > 0);
        if ~isempty(valid) && max(valid)/min(valid) > 50
            set(ax, 'YScale', 'log');
        end
    end
    % Status legend
    hold(ax, 'on');
    legH(1) = bar(ax, NaN, 0, 'FaceColor', [0.35 0.70 0.20], 'DisplayName', 'PASS');
    legH(2) = bar(ax, NaN, 0, 'FaceColor', [0.85 0.33 0.10], 'DisplayName', 'FAIL');
    legH(3) = bar(ax, NaN, 0, 'FaceColor', [0.40 0.60 0.85], 'DisplayName', 'INFO');
    hold(ax, 'off');
    legend(legH, {'PASS','FAIL','INFO'}, 'Location','northeast');
end

% --- Figure 4: matched-correction cancellation detail ------------------------
function fig = makeMatchedDetail_(caseResults)
    fig = figure('Visible','off','Name','Matched-Correction Cancellation', ...
        'NumberTitle','off','Position',[50 50 820 500]);
    ax = axes('Parent', fig);

    mIdx = find(cellfun(@(r) strcmp(r.caseName,'all_contributions_matched'), caseResults), 1);
    if isempty(mIdx)
        text(0.5, 0.5, 'all\_contributions\_matched case not in suite', ...
            'Units','normalized','HorizontalAlignment','center','FontSize',12);
        title(ax, 'Matched-Correction Cancellation');
        return;
    end

    r     = caseResults{mIdx};
    THRESH = 0.01;
    effNames = {'Sagnac','Shapiro','Trop','Iono','TwrSvy','RxPCO','TwrPCO','PCV'};
    effVals  = [r.maxSagnacMismatch_m, r.maxShapiroMismatch_m, ...
                r.maxTroposphereMismatch_m, r.maxIonosphereMismatch_m, ...
                r.maxTowerSurveyMismatch_m, r.maxReceiverPCOMismatch_m, ...
                r.maxTowerPCOMismatch_m,    r.maxPCVMismatch_m];
    nE = numel(effNames);
    hold(ax, 'on');
    for k = 1:nE
        clr = iff_(effVals(k) > THRESH, [0.85 0.33 0.10], [0.35 0.70 0.20]);
        bar(ax, k, max(effVals(k),0), 'FaceColor', clr);
    end
    hold(ax, 'off');
    yline(ax, THRESH, 'r--', sprintf('Threshold: %.3f m', THRESH), ...
        'LineWidth', 1.5, 'LabelVerticalAlignment', 'bottom', 'Interpreter', 'none');
    set(ax, 'XTick', 1:nE, 'XTickLabel', effNames);
    ylabel(ax, 'Max Mismatch RMS [m]');
    title(ax, 'Matched-Correction Cancellation (all\_contributions\_matched)', ...
        'Interpreter', 'none');
    grid(ax, 'on');
end

% --- Figure 5: one-effect mismatch visibility --------------------------------
function fig = makeMismatchDetail_(caseResults)
    fig = figure('Visible','off','Name','Single-Effect Mismatch Visibility', ...
        'NumberTitle','off','Position',[50 50 820 500]);
    ax = axes('Parent', fig);

    mCases = {'sagnac_mismatch','troposphere_mismatch','ionosphere_mismatch', ...
              'tower_survey_mismatch','pco_mismatch','pcv_toy','correlated_noise'};
    mLabels = {'Sagnac','Trop','Iono','TwrSvy','PCO','PCV','CorrNoise'};
    mFields = {'maxSagnacMismatch_m','maxTroposphereMismatch_m','maxIonosphereMismatch_m', ...
               'maxTowerSurveyMismatch_m','maxReceiverPCOMismatch_m', ...
               'maxPCVMismatch_m','maxCorrelatedNoiseMismatch_m'};

    nE = numel(mCases);
    vals  = zeros(nE, 1);
    clrs  = repmat([0.60 0.60 0.60], nE, 1);  % gray = case not in suite
    for k = 1:nE
        idx = find(cellfun(@(r) strcmp(r.caseName, mCases{k}), caseResults), 1);
        if ~isempty(idx)
            r = caseResults{idx};
            if strcmp(mCases{k}, 'pco_mismatch')
                vals(k) = max(r.maxReceiverPCOMismatch_m, r.maxTowerPCOMismatch_m);
            else
                vals(k) = r.(mFields{k});
            end
            clrs(k,:) = iff_(r.passFail, [0.35 0.70 0.20], [0.85 0.33 0.10]);
        end
    end

    hold(ax, 'on');
    for k = 1:nE
        bar(ax, k, max(vals(k),0), 'FaceColor', clrs(k,:));
    end
    hold(ax, 'off');
    set(ax, 'XTick', 1:nE, 'XTickLabel', mLabels);
    ylabel(ax, 'Max Mismatch RMS [m]');
    title(ax, 'Single-Effect Mismatch Visibility');
    grid(ax, 'on');
    if any(vals > 0)
        ylim(ax, [0, max(vals) * 1.15]);
    end
end

% --- Figure 6: NIS ratio -----------------------------------------------------
function fig = makeNISFig_(names, nisRatio, clrs)
    nC  = numel(names);
    fig = figure('Visible','off','Name','NIS Ratio','NumberTitle','off', ...
        'Position',[50 50 920 500]);
    ax = axes('Parent', fig);
    hold(ax, 'on');
    for c = 1:nC
        if isfinite(nisRatio(c))
            bar(ax, c, nisRatio(c), 'FaceColor', clrs(c,:));
        end
    end
    hold(ax, 'off');
    yline(ax, 1.0, 'k-',  'Expected = 1',     'LineWidth', 2, 'LabelVerticalAlignment', 'bottom', 'Interpreter', 'none');
    yline(ax, 0.2, 'b--', 'Lower bound (0.2)', 'LineWidth', 1, 'Interpreter', 'none');
    yline(ax, 5.0, 'r--', 'Upper bound (5)',   'LineWidth', 1, 'Interpreter', 'none');
    set(ax, 'XTick', 1:nC, 'XTickLabel', names, 'XTickLabelRotation', 38, ...
        'TickLabelInterpreter', 'none');
    ylabel(ax, 'NIS / Expected NIS');
    title(ax, 'Normalised Innovation Squared Ratio by Case');
    grid(ax, 'on');
    xlim(ax, [0.5, nC+0.5]);
    validR = nisRatio(isfinite(nisRatio) & nisRatio > 0);
    if ~isempty(validR)
        ylim(ax, [0, min(max(validR)*1.2, 12)]);
    end
end

% --- Write PDF ---------------------------------------------------------------
function writeResultsPDF(pdfPath, figs)
    first = true;
    for k = 1:numel(figs)
        fh = figs(k);
        if ~isgraphics(fh); continue; end
        if first
            exportgraphics(fh, pdfPath, 'ContentType','vector');
            first = false;
        else
            exportgraphics(fh, pdfPath, 'ContentType','vector', 'Append', true);
        end
        close(fh);
    end
    fprintf('  PDF saved: %s  (%.1f kB)\n', pdfPath, dir(pdfPath).bytes/1024);
end

% --- Write CSV ---------------------------------------------------------------
function writeCSV(caseResults, csvPath)
    caseNames  = cellfun(@(r) r.caseName,                       caseResults, 'UniformOutput', false)';
    posErr     = cellfun(@(r) r.finalPositionError_m,           caseResults)';
    posRMS     = cellfun(@(r) r.positionRMS_last20_m,           caseResults)';
    clkErr     = cellfun(@(r) r.finalClockBiasError_m,          caseResults)';
    meanNIS    = cellfun(@(r) r.meanNIS,                        caseResults)';
    expNIS     = cellfun(@(r) r.expectedNIS,                    caseResults)';
    mismatch   = cellfun(@(r) r.meanTotalMismatchRMS_last20_m,  caseResults)';
    gdop       = cellfun(@(r) r.meanGDOPLike,                   caseResults)';
    sagnac     = cellfun(@(r) r.maxSagnacMismatch_m,            caseResults)';
    shapiro    = cellfun(@(r) r.maxShapiroMismatch_m,           caseResults)';
    trop       = cellfun(@(r) r.maxTroposphereMismatch_m,       caseResults)';
    iono       = cellfun(@(r) r.maxIonosphereMismatch_m,        caseResults)';
    twrSvy     = cellfun(@(r) r.maxTowerSurveyMismatch_m,       caseResults)';
    rxPCO      = cellfun(@(r) r.maxReceiverPCOMismatch_m,       caseResults)';
    twrPCO     = cellfun(@(r) r.maxTowerPCOMismatch_m,          caseResults)';
    pcv        = cellfun(@(r) r.maxPCVMismatch_m,               caseResults)';
    corrNoise  = cellfun(@(r) r.maxCorrelatedNoiseMismatch_m,   caseResults)';
    statusStr  = cellfun(@(r) r.status,                         caseResults, 'UniformOutput', false)';
    notesStr   = cellfun(@(r) r.notes,                          caseResults, 'UniformOutput', false)';

    nSig        = cellfun(@(r) r.nSignals,                       caseResults)';
    enabledSigs = cellfun(@(r) r.enabledSignals,                 caseResults, 'UniformOutput', false)';
    maxMeasRows = cellfun(@(r) r.maxMeasurementRows,             caseResults)';
    scintRMS    = cellfun(@(r) r.meanScintillationRMS_m,         caseResults)';
    clkDriftRMS = cellfun(@(r) r.clockDriftRMS_last20_mps,       caseResults)';

    T = table(caseNames, posErr, posRMS, clkErr, meanNIS, expNIS, mismatch, gdop, ...
        sagnac, shapiro, trop, iono, twrSvy, rxPCO, twrPCO, pcv, corrNoise, ...
        nSig, enabledSigs, maxMeasRows, scintRMS, clkDriftRMS, ...
        statusStr, notesStr, ...
        'VariableNames', { ...
            'caseName','finalPositionError_m','positionRMS_last20_m','finalClockBiasError_m', ...
            'meanNIS','expectedNIS','meanTotalMismatch_m','meanGDOPLike', ...
            'maxSagnacMismatch_m','maxShapiroMismatch_m','maxTropMismatch_m','maxIonoMismatch_m', ...
            'maxTwrSvyMismatch_m','maxRxPCOMismatch_m','maxTwrPCOMismatch_m','maxPCVMismatch_m', ...
            'maxCorrNoiseMismatch_m','nSignals','enabledSignals','maxMeasurementRows', ...
            'meanScintillationRMS_m','clockDriftRMS_last20_mps','status','notes'});

    writetable(T, csvPath);
    fprintf('  CSV saved: %s\n', csvPath);
end

% --- Write MAT ---------------------------------------------------------------
function writeMAT(caseResults, matPath, duration_s, suiteStart)
    nC = numel(caseResults);
    resultsStruct(nC) = caseResults{nC};
    for k = 1:nC-1
        resultsStruct(k) = caseResults{k};
    end

    gitInfo = struct('branch','?','hash','?');
    try
        [~, b] = system('git rev-parse --abbrev-ref HEAD');
        [~, h] = system('git rev-parse --short HEAD');
        gitInfo.branch = strtrim(b);
        gitInfo.hash   = strtrim(h);
    catch
    end

    timestamp        = suiteStart;
    SUITE_DURATION_S = duration_s; %#ok<NASGU>
    save(matPath, 'caseResults', 'resultsStruct', 'gitInfo', 'timestamp', 'SUITE_DURATION_S');
    fprintf('  MAT saved: %s\n', matPath);
end

% ============================================================================
%  PRIVATE HELPERS
% ============================================================================

function v = csGet_(cs, effName, fldName, iS, mode)
    v = 0;
    if ~isfield(cs, effName); return; end
    eff = cs.(effName);
    if ~isfield(eff, fldName); return; end
    arr = eff.(fldName);
    if isempty(arr); return; end
    switch mode
        case 'max';  v = max(arr);
        case 'mean'; v = mean(arr(iS:end));
    end
end

function [ok, note] = checkNIS_(r)
    lo   = 0.2 * r.expectedNIS;
    hi   = 5.0 * r.expectedNIS;
    ok   = r.meanNIS >= lo && r.meanNIS <= hi;
    note = '';
    if ~ok
        note = sprintf('NIS=%.2f outside [%.2f, %.2f]', r.meanNIS, lo, hi);
    end
end

function out = iff_(cond, a, b)
    if cond; out = a; else; out = b; end
end

function c = statusColor_(status)
    switch status
        case 'PASS';    c = [0.35 0.70 0.20];
        case 'FAIL';    c = [0.85 0.33 0.10];
        case 'INFO';    c = [0.40 0.60 0.85];
        case 'WARN';    c = [0.93 0.65 0.13];
        otherwise;      c = [0.60 0.60 0.60];
    end
end
