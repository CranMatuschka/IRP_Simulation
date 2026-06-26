function analyse_oo_reverse_gnss_ladder_sweep(sweepDir)
% analyse_oo_reverse_gnss_ladder_sweep
%
% Reads all per-case *_compact.mat files from a ladder sweep and creates
% comparative metrics, rankings, and plots for:
%   - position
%   - velocity
%   - clock bias/drift
%   - attitude
%   - full EKF state vector x
%   - covariance diagonal Pdiag
%
% The script is designed for outputs created by:
%   run_oo_reverse_gnss_ladder_sweep_real_report_fixed.m
%
% It does not load native full ReportRunner MAT files.
% It only uses compact per-case MAT files.
%
% Run:
%   cd oo_v1
%   analyse_oo_reverse_gnss_ladder_sweep
%
% Optional:
%   analyse_oo_reverse_gnss_ladder_sweep('/path/to/Sweep_YYYYMMDD_HHMMSS')

    clc;

    if nargin < 1 || isempty(sweepDir)
        sweepDir = uigetdir(pwd, 'Select ladder sweep folder');
        if isequal(sweepDir, 0)
            fprintf('No folder selected. Aborting.\n');
            return;
        end
    end

    if exist(sweepDir, 'dir') ~= 7
        error('Sweep folder does not exist: %s', sweepDir);
    end

    analysisDir = fullfile(sweepDir, 'analysis');
    plotDir = fullfile(analysisDir, 'plots');
    mkdirIfMissing_(analysisDir);
    mkdirIfMissing_(plotDir);

    fprintf('\n=== Ladder sweep analysis ===\n');
    fprintf('Sweep folder: %s\n', sweepDir);
    fprintf('Analysis dir:  %s\n', analysisDir);

    compactFiles = findCompactFiles_(sweepDir);
    if isempty(compactFiles)
        error('No *_compact.mat files found under: %s', sweepDir);
    end

    fprintf('Found compact MAT files: %d\n', numel(compactFiles));

    cases = loadCases_(compactFiles);
    cases = sortCases_(cases);

    metrics = buildMetricsTable_(cases);
    impacts = buildIncrementalImpactTable_(metrics);

    metricsCsv = fullfile(analysisDir, 'ladder_case_metrics.csv');
    impactsCsv = fullfile(analysisDir, 'ladder_incremental_impacts.csv');

    writetable(metrics, metricsCsv);
    writetable(impacts, impactsCsv);

    writeRankingTables_(analysisDir, impacts);

    fprintf('\nWrote:\n');
    fprintf('  %s\n', metricsCsv);
    fprintf('  %s\n', impactsCsv);

    makeAllPlots_(plotDir, cases, metrics, impacts);

    fprintf('\n=== Analysis complete ===\n');
    fprintf('Open this folder:\n  %s\n', analysisDir);

    printShortRanking_(impacts);
end

% ========================================================================
% Discovery / loading
% ========================================================================
function files = findCompactFiles_(root)
    dd = dir(fullfile(root, '**', '*_compact.mat'));
    files = strings(0,1);

    for i = 1:numel(dd)
        p = fullfile(dd(i).folder, dd(i).name);

        % Avoid accidentally reading analysis products.
        if contains(p, [filesep 'analysis' filesep])
            continue;
        end

        files(end+1,1) = string(p); %#ok<AGROW>
    end
end

function cases = loadCases_(files)
    cases = repmat(emptyCase_(), 0, 1);

    for i = 1:numel(files)
        p = char(files(i));

        try
            S = load(p, 'compact');
            if ~isfield(S, 'compact')
                warning('Skipping %s: no variable "compact".', p);
                continue;
            end

            c = S.compact;
            rec = emptyCase_();

            rec.path = string(p);
            rec.folder = string(fileparts(p));
            rec.ok = getField_(c, 'ok', true);
            rec.caseIndex = double(getField_(c, 'caseIndex', i));
            rec.caseName = string(getField_(c, 'caseName', fileStem_(p)));
            rec.caseNote = string(getField_(c, 'caseNote', ''));
            rec.compact = c;

            rec.phase = classifyPhase_(rec.caseName);
            rec.shortName = shortCaseName_(rec.caseName);

            cases(end+1,1) = rec; %#ok<AGROW>

        catch ME
            warning('Could not load %s: %s', p, ME.message);
        end
    end
end

function c = emptyCase_()
    c = struct();
    c.path = "";
    c.folder = "";
    c.ok = false;
    c.caseIndex = NaN;
    c.caseName = "";
    c.shortName = "";
    c.caseNote = "";
    c.phase = "";
    c.compact = struct();
end

function cases = sortCases_(cases)
    idx = [cases.caseIndex];
    [~, order] = sort(idx);
    cases = cases(order);
end

function phase = classifyPhase_(caseName)
    s = lower(char(caseName));

    if contains(s, 'a_iso') || contains(s, 'phasea_iso') || contains(s, 'iso_')
        phase = "A_isolated_raw";
    elseif contains(s, 'a_cum') || contains(s, 'phasea_cum') || contains(s, 'cum_')
        phase = "A_cumulative_raw";
    elseif contains(s, 'b_iso') || contains(s, 'phaseb')
        phase = "B_isolated_ekfuse";
    elseif contains(s, 'c_cum') || contains(s, 'phasec')
        phase = "C_cumulative_ekfuse";
    elseif contains(s, 'final')
        phase = "Final";
    else
        phase = "Unknown";
    end
end

function s = shortCaseName_(name)
    s = string(name);
    s = regexprep(s, '^case\d+_', '');
    s = regexprep(s, '^A_', 'A ');
    s = regexprep(s, '^B_', 'B ');
    s = regexprep(s, '^C_', 'C ');
    s = strrep(s, '_', ' ');
end

% ========================================================================
% Metrics
% ========================================================================
function T = buildMetricsTable_(cases)
    rows = [];

    for i = 1:numel(cases)
        c = cases(i).compact;
        d = getField_(c, 'data', struct());

        r = struct();

        r.caseIndex = cases(i).caseIndex;
        r.caseName = cases(i).caseName;
        r.shortName = cases(i).shortName;
        r.phase = cases(i).phase;
        r.ok = logical(getField_(c, 'ok', true));
        r.file = cases(i).path;

        r.nEpochs = getNumeric_(d, {'nEpochs'}, NaN);
        r.nState = getNumeric_(d, {'nState'}, NaN);

        posNorm = getSeries_(d, {'error','positionNorm_m'});
        posVec  = getMatrix_(d, {'error','positionVec_m'});

        velTruth = getMatrix_(d, {'truth','v_mps'});
        velEst   = getMatrix_(d, {'estimate','v_mps'});
        velErr   = velEst - velTruth;
        velNorm  = rowNorm_(velErr);

        clkBias = getSeries_(d, {'error','clockBias_m'});
        clkDrift = getSeries_(d, {'error','clockDrift_mps'});

        attRad = getMatrix_(d, {'error','attitude_rad'});
        attDeg = rad2deg(attRad);
        attNorm = rowNorm_(attDeg);

        X = getMatrix_(d, {'x'});
        Pdiag = getMatrix_(d, {'Pdiag'});

        r.posFinal_m = lastFinite_(posNorm);
        r.posRms_m = rmsFinite_(posNorm);
        r.posP95_m = prctileFinite_(posNorm, 95);
        r.posMax_m = maxFinite_(posNorm);

        r.posXFinal_m = lastFiniteCol_(posVec, 1);
        r.posYFinal_m = lastFiniteCol_(posVec, 2);
        r.posZFinal_m = lastFiniteCol_(posVec, 3);
        r.posXRms_m = rmsFiniteCol_(posVec, 1);
        r.posYRms_m = rmsFiniteCol_(posVec, 2);
        r.posZRms_m = rmsFiniteCol_(posVec, 3);

        r.velFinal_mps = lastFinite_(velNorm);
        r.velRms_mps = rmsFinite_(velNorm);
        r.velP95_mps = prctileFinite_(velNorm, 95);

        r.clockFinal_m = lastFinite_(abs(clkBias));
        r.clockRms_m = rmsFinite_(clkBias);
        r.clockP95_m = prctileFinite_(abs(clkBias), 95);
        r.clockDriftFinal_mps = lastFinite_(abs(clkDrift));
        r.clockDriftRms_mps = rmsFinite_(clkDrift);

        r.attFinal_deg = lastFinite_(attNorm);
        r.attRms_deg = rmsFinite_(attNorm);
        r.attP95_deg = prctileFinite_(attNorm, 95);
        r.rollFinal_deg = lastFiniteCol_(attDeg, 1);
        r.pitchFinal_deg = lastFiniteCol_(attDeg, 2);
        r.yawFinal_deg = lastFiniteCol_(attDeg, 3);
        r.rollRms_deg = rmsFiniteCol_(attDeg, 1);
        r.pitchRms_deg = rmsFiniteCol_(attDeg, 2);
        r.yawRms_deg = rmsFiniteCol_(attDeg, 3);

        r.stateRms = rmsFiniteAll_(X);
        r.stateFinalNorm = normFinite_(lastFiniteRow_(X));
        r.stateMaxAbs = maxFinite_(abs(X(:)));

        r.sigmaFinalMedian = medianFinite_(sqrt(abs(lastFiniteRow_(Pdiag))));
        r.sigmaFinalMax = maxFinite_(sqrt(abs(lastFiniteRow_(Pdiag))));
        r.sigmaRmsMedian = medianFinite_(sqrt(abs(Pdiag(:))));

        r.numRowsMean = meanFinite_(getSeries_(d, {'meas','numRows'}));
        r.numCodeRowsMean = meanFinite_(getSeries_(d, {'meas','numPseudoRows'}));
        r.numCarrierRowsMean = meanFinite_(getSeries_(d, {'meas','numCarrierRows'}));
        r.numDopplerRowsMean = meanFinite_(getSeries_(d, {'meas','numDopplerRows'}));

        r.nisMean = meanFinite_(getSeries_(d, {'consistency','NIS'}));
        r.neesPosMean = meanFinite_(getSeries_(d, {'consistency','NEES_pos'}));
        r.neesClkMean = meanFinite_(getSeries_(d, {'consistency','NEES_clk'}));
        r.neesAttMean = meanFinite_(getSeries_(d, {'consistency','NEES_att'}));

        rows = appendStruct_(rows, r);
    end

    T = struct2table(rows);

    % Add compact combined scores.
    T.navigationScore = normalizeScore_(T.posRms_m) ...
                      + normalizeScore_(T.clockRms_m) ...
                      + normalizeScore_(T.attRms_deg);

    T.positionClockScore = normalizeScore_(T.posRms_m) ...
                         + normalizeScore_(T.clockRms_m);
end

function impacts = buildIncrementalImpactTable_(metrics)
    rows = [];

    if isempty(metrics)
        impacts = table();
        return;
    end

    baselineIdx = find(metrics.caseIndex == min(metrics.caseIndex), 1, 'first');

    for i = 1:height(metrics)
        r = struct();

        r.caseIndex = metrics.caseIndex(i);
        r.caseName = metrics.caseName(i);
        r.shortName = metrics.shortName(i);
        r.phase = metrics.phase(i);

        % Reference logic:
        % - isolated cases compare to baseline
        % - cumulative cases compare to previous case
        % - unknown/final compare to previous case
        if contains(metrics.phase(i), "isolated")
            ref = baselineIdx;
            r.referenceType = "baseline";
        else
            ref = max(1, i-1);
            r.referenceType = "previous_case";
        end

        r.referenceCaseIndex = metrics.caseIndex(ref);
        r.referenceCaseName = metrics.caseName(ref);

        r.dPosRms_m = metrics.posRms_m(i) - metrics.posRms_m(ref);
        r.dPosFinal_m = metrics.posFinal_m(i) - metrics.posFinal_m(ref);
        r.dPosP95_m = metrics.posP95_m(i) - metrics.posP95_m(ref);

        r.dClockRms_m = metrics.clockRms_m(i) - metrics.clockRms_m(ref);
        r.dClockFinal_m = metrics.clockFinal_m(i) - metrics.clockFinal_m(ref);

        r.dAttRms_deg = metrics.attRms_deg(i) - metrics.attRms_deg(ref);
        r.dAttFinal_deg = metrics.attFinal_deg(i) - metrics.attFinal_deg(ref);

        r.dVelRms_mps = metrics.velRms_mps(i) - metrics.velRms_mps(ref);
        r.dStateRms = metrics.stateRms(i) - metrics.stateRms(ref);
        r.dSigmaFinalMedian = metrics.sigmaFinalMedian(i) - metrics.sigmaFinalMedian(ref);

        r.absImpactPosition = abs(r.dPosRms_m);
        r.absImpactClock = abs(r.dClockRms_m);
        r.absImpactAttitude = abs(r.dAttRms_deg);

        rows = appendStruct_(rows, r);
    end

    impacts = struct2table(rows);
end

function writeRankingTables_(analysisDir, impacts)
    if isempty(impacts)
        return;
    end

    P = sortrows(impacts, 'absImpactPosition', 'descend');
    C = sortrows(impacts, 'absImpactClock', 'descend');
    A = sortrows(impacts, 'absImpactAttitude', 'descend');

    writetable(P, fullfile(analysisDir, 'ladder_ranked_impacts_position.csv'));
    writetable(C, fullfile(analysisDir, 'ladder_ranked_impacts_clock.csv'));
    writetable(A, fullfile(analysisDir, 'ladder_ranked_impacts_attitude.csv'));
end

% ========================================================================
% Plots
% ========================================================================
function makeAllPlots_(plotDir, cases, metrics, impacts)
    close all force;
    set(0, 'DefaultFigureVisible', 'off');

    plotFinalMetrics_(plotDir, metrics);
    plotRmsMetrics_(plotDir, metrics);
    plotIncrementalBars_(plotDir, impacts);
    plotSelectedTimeOverlays_(plotDir, cases, metrics);
    plotStateMetrics_(plotDir, cases, metrics);
    plotSigmaHeatmap_(plotDir, cases);
end

function plotFinalMetrics_(plotDir, T)
    fig = safeFig_('Final metrics by case');
    tiledlayout(3,1,'Padding','compact','TileSpacing','compact');

    nexttile;
    plot(T.caseIndex, T.posFinal_m, '-o', 'LineWidth', 1.1);
    grid on; ylabel('Position final [m]');

    nexttile;
    plot(T.caseIndex, T.clockFinal_m, '-o', 'LineWidth', 1.1);
    grid on; ylabel('Clock final |m|');

    nexttile;
    plot(T.caseIndex, T.attFinal_deg, '-o', 'LineWidth', 1.1);
    grid on; ylabel('Attitude final [deg]');
    xlabel('Case index');

    savePng_(fig, fullfile(plotDir, '01_final_metrics_by_case.png'));
end

function plotRmsMetrics_(plotDir, T)
    fig = safeFig_('RMS metrics by case');
    tiledlayout(4,1,'Padding','compact','TileSpacing','compact');

    nexttile;
    plot(T.caseIndex, T.posRms_m, '-o', 'LineWidth', 1.1);
    grid on; ylabel('Pos RMS [m]');

    nexttile;
    plot(T.caseIndex, T.clockRms_m, '-o', 'LineWidth', 1.1);
    grid on; ylabel('Clock RMS [m]');

    nexttile;
    plot(T.caseIndex, T.attRms_deg, '-o', 'LineWidth', 1.1);
    grid on; ylabel('Att RMS [deg]');

    nexttile;
    plot(T.caseIndex, T.velRms_mps, '-o', 'LineWidth', 1.1);
    grid on; ylabel('Vel RMS [m/s]');
    xlabel('Case index');

    savePng_(fig, fullfile(plotDir, '02_rms_metrics_by_case.png'));
end

function plotIncrementalBars_(plotDir, impacts)
    if isempty(impacts)
        return;
    end

    makeImpactBar_(plotDir, impacts, 'dPosRms_m', ...
        'Position RMS incremental impact [m]', ...
        '03_incremental_position_impact.png');

    makeImpactBar_(plotDir, impacts, 'dClockRms_m', ...
        'Clock RMS incremental impact [m]', ...
        '04_incremental_clock_impact.png');

    makeImpactBar_(plotDir, impacts, 'dAttRms_deg', ...
        'Attitude RMS incremental impact [deg]', ...
        '05_incremental_attitude_impact.png');
end

function makeImpactBar_(plotDir, impacts, field, titleText, fname)
    y = impacts.(field);

    fig = safeFig_(titleText);
    bar(impacts.caseIndex, y);
    grid on;
    xlabel('Case index');
    ylabel(field, 'Interpreter','none');
    title(titleText, 'Interpreter','none');

    savePng_(fig, fullfile(plotDir, fname));
end

function plotSelectedTimeOverlays_(plotDir, cases, metrics)
    idx = selectRepresentativeCases_(metrics);

    plotOverlay_(plotDir, cases(idx), 'position', ...
        '06_position_time_overlay_selected.png');

    plotOverlay_(plotDir, cases(idx), 'clock', ...
        '07_clock_time_overlay_selected.png');

    plotOverlay_(plotDir, cases(idx), 'attitude', ...
        '08_attitude_time_overlay_selected.png');
end

function idx = selectRepresentativeCases_(metrics)
    idx = [];

    if isempty(metrics)
        return;
    end

    idx(end+1) = 1;

    phases = unique(metrics.phase, 'stable');
    for p = 1:numel(phases)
        rows = find(metrics.phase == phases(p));
        if ~isempty(rows)
            idx(end+1) = rows(end); %#ok<AGROW>
        end
    end

    idx(end+1) = height(metrics);

    idx = unique(idx);
    idx = idx(idx >= 1 & idx <= height(metrics));
end

function plotOverlay_(plotDir, selectedCases, kind, fname)
    fig = safeFig_(['Overlay ' kind]);
    hold on; grid on;

    for i = 1:numel(selectedCases)
        d = getField_(selectedCases(i).compact, 'data', struct());
        t = getSeries_(d, {'t_s'});

        switch kind
            case 'position'
                y = getSeries_(d, {'error','positionNorm_m'});
                ylab = 'Position error [m]';
            case 'clock'
                y = abs(getSeries_(d, {'error','clockBias_m'}));
                ylab = 'Clock bias error |m|';
            case 'attitude'
                att = getMatrix_(d, {'error','attitude_rad'});
                y = rowNorm_(rad2deg(att));
                ylab = 'Attitude error norm [deg]';
            otherwise
                y = [];
                ylab = '';
        end

        if ~isempty(t) && ~isempty(y)
            plot(t, y, 'LineWidth', 1.1, ...
                'DisplayName', sprintf('%03d %s', ...
                selectedCases(i).caseIndex, selectedCases(i).shortName));
        end
    end

    xlabel('Time [s]');
    ylabel(ylab);
    legend('Location','eastoutside', 'Interpreter','none');
    title(['Selected case overlay: ' kind], 'Interpreter','none');

    savePng_(fig, fullfile(plotDir, fname));
end

function plotStateMetrics_(plotDir, cases, metrics)
    fig = safeFig_('State RMS by case');

    plot(metrics.caseIndex, metrics.stateRms, '-o', 'LineWidth', 1.1);
    grid on;
    xlabel('Case index');
    ylabel('RMS over all saved state entries');
    title('Full EKF state-vector RMS by case');

    savePng_(fig, fullfile(plotDir, '09_state_rms_by_case.png'));
end

function plotSigmaHeatmap_(plotDir, cases)
    maxNx = 0;
    for i = 1:numel(cases)
        d = getField_(cases(i).compact, 'data', struct());
        Pdiag = getMatrix_(d, {'Pdiag'});
        maxNx = max(maxNx, size(Pdiag,2));
    end

    if maxNx == 0
        return;
    end

    S = NaN(numel(cases), maxNx);

    for i = 1:numel(cases)
        d = getField_(cases(i).compact, 'data', struct());
        Pdiag = getMatrix_(d, {'Pdiag'});
        row = sqrt(abs(lastFiniteRow_(Pdiag)));
        S(i,1:numel(row)) = row;
    end

    fig = safeFig_('Final state sigma heatmap');
    imagesc(log10(S));
    colorbar;
    xlabel('State index');
    ylabel('Case index');
    title('log10 final sqrt(Pdiag) by case');

    savePng_(fig, fullfile(plotDir, '10_state_sigma_final_heatmap.png'));
end

% ========================================================================
% Console summary
% ========================================================================
function printShortRanking_(impacts)
    if isempty(impacts)
        return;
    end

    fprintf('\nMost position-impacting cases by |Δ position RMS|:\n');
    P = sortrows(impacts, 'absImpactPosition', 'descend');
    printTop_(P, 'dPosRms_m');

    fprintf('\nMost clock-impacting cases by |Δ clock RMS|:\n');
    C = sortrows(impacts, 'absImpactClock', 'descend');
    printTop_(C, 'dClockRms_m');

    fprintf('\nMost attitude-impacting cases by |Δ attitude RMS|:\n');
    A = sortrows(impacts, 'absImpactAttitude', 'descend');
    printTop_(A, 'dAttRms_deg');
end

function printTop_(T, field)
    n = min(10, height(T));
    for i = 1:n
        fprintf('  %3d  %+12.5g  %s\n', ...
            T.caseIndex(i), T.(field)(i), T.shortName(i));
    end
end

% ========================================================================
% Helpers: data access
% ========================================================================
function v = getField_(s, name, defaultValue)
    if isstruct(s) && isfield(s, name)
        v = s.(name);
    else
        v = defaultValue;
    end
end

function v = getPath_(s, path, defaultValue)
    v = defaultValue;
    try
        tmp = s;
        for i = 1:numel(path)
            if ~isstruct(tmp) || ~isfield(tmp, path{i})
                return;
            end
            tmp = tmp.(path{i});
        end
        v = tmp;
    catch
        v = defaultValue;
    end
end

function x = getNumeric_(s, path, defaultValue)
    x = getPath_(s, path, defaultValue);
    if ~(isnumeric(x) && isscalar(x))
        x = defaultValue;
    end
end

function x = getSeries_(s, path)
    x = getPath_(s, path, []);
    if isempty(x) || ~isnumeric(x)
        x = [];
        return;
    end
    x = x(:);
end

function M = getMatrix_(s, path)
    M = getPath_(s, path, []);
    if isempty(M) || ~isnumeric(M)
        M = [];
    end
end

function n = rowNorm_(M)
    if isempty(M)
        n = [];
        return;
    end

    if size(M,2) == 3
        n = sqrt(sum(M.^2, 2));
    elseif size(M,1) == 3
        n = sqrt(sum(M.^2, 1)).';
    else
        n = sqrt(sum(M.^2, 2));
    end
end

function y = lastFinite_(x)
    y = NaN;
    if isempty(x)
        return;
    end
    idx = find(isfinite(x), 1, 'last');
    if ~isempty(idx)
        y = x(idx);
    end
end

function y = lastFiniteCol_(M, col)
    y = NaN;
    if isempty(M) || size(M,2) < col
        return;
    end
    y = lastFinite_(M(:,col));
end

function r = lastFiniteRow_(M)
    r = NaN(1, max(1,size(M,2)));
    if isempty(M)
        return;
    end

    for i = size(M,1):-1:1
        if any(isfinite(M(i,:)))
            r = M(i,:);
            return;
        end
    end
end

function y = rmsFinite_(x)
    x = x(isfinite(x));
    if isempty(x)
        y = NaN;
    else
        y = sqrt(mean(x.^2));
    end
end

function y = rmsFiniteCol_(M, col)
    y = NaN;
    if isempty(M) || size(M,2) < col
        return;
    end
    y = rmsFinite_(M(:,col));
end

function y = rmsFiniteAll_(M)
    if isempty(M)
        y = NaN;
        return;
    end
    x = M(:);
    y = rmsFinite_(x);
end

function y = prctileFinite_(x, p)
    x = x(isfinite(x));
    if isempty(x)
        y = NaN;
    else
        y = prctile(x, p);
    end
end

function y = maxFinite_(x)
    x = x(isfinite(x));
    if isempty(x)
        y = NaN;
    else
        y = max(x);
    end
end

function y = meanFinite_(x)
    x = x(isfinite(x));
    if isempty(x)
        y = NaN;
    else
        y = mean(x);
    end
end

function y = medianFinite_(x)
    x = x(isfinite(x));
    if isempty(x)
        y = NaN;
    else
        y = median(x);
    end
end

function y = normFinite_(x)
    x = x(isfinite(x));
    if isempty(x)
        y = NaN;
    else
        y = norm(x);
    end
end

function score = normalizeScore_(x)
    score = NaN(size(x));
    ok = isfinite(x);
    if nnz(ok) < 2
        score(ok) = 0;
        return;
    end

    xmin = min(x(ok));
    xmax = max(x(ok));
    if xmax == xmin
        score(ok) = 0;
    else
        score(ok) = (x(ok) - xmin) ./ (xmax - xmin);
    end
end

function arr = appendStruct_(arr, row)
    if isempty(arr)
        arr = row;
    else
        arr(end+1,1) = row; %#ok<AGROW>
    end
end

function s = fileStem_(p)
    [~, s, ~] = fileparts(p);
    s = string(s);
end

% ========================================================================
% Files / plotting
% ========================================================================
function mkdirIfMissing_(p)
    if exist(p, 'dir') ~= 7
        mkdir(p);
    end
end

function fig = safeFig_(name)
    fig = figure('Visible','off', 'Color','white', 'Name', name);
    set(fig, 'Renderer', 'opengl');
    set(fig, 'InvertHardcopy', 'off');
end

function savePng_(fig, path)
    try
        set(fig, 'Visible','off');
        print(fig, path, '-dpng', '-r180');
    catch ME
        warning('Could not save plot %s: %s', path, ME.message);
    end

    try
        close(fig);
    catch
    end

    try
        drawnow limitrate;
    catch
    end
end