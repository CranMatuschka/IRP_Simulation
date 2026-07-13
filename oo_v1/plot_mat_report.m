function figOut = plot_mat_report(matPath)
%PLOT_MAT_REPORT  Load an oo_v1 report .mat and show its diagnostics in ONE tabbed window.
%
%   The main runner (run_oo_v1.m / run_ladder.m) saves a report .mat containing
%   the diagnostics store (a data.SimulationDataStore) and the cfg used. This
%   script reloads that .mat and draws the diagnostics into a SINGLE window that
%   has one TAB per topic, each tab holding at most 2 related subplots.
%
%   USAGE
%     plot_mat_report                 % pick a .mat with a file dialog (default)
%     plot_mat_report('pick')         % same, explicit
%     plot_mat_report('latest')       % newest report .mat under output/
%     plot_mat_report(PATH_TO_MAT)    % a specific .mat file
%     plot_mat_report(FOLDER)         % newest report .mat inside FOLDER
%     fig = plot_mat_report(...)      % also return the window handle
%
%   TABS (each <= 2 subplots)
%     Position (RAC)   radial/along/cross error   +  position error norm
%     Attitude         roll/pitch/yaw error       +  attitude error norm
%     Clock bias       truth vs estimate          +  bias error
%     Clock drift      frac-freq truth vs est     +  drift error
%     PR residuals     prefit innovation RMS      +  postfit residual RMS
%     Doppler & NIS    Doppler prefit/postfit RMS +  NIS
%     Measurements     visible towers             +  total measurements
%
%   Reuses the diagnostics store accessors (the same data source as
%   revgnss.Plotter) and revgnss.OrbitFrame for the RAC projection.
%
%   See also: run_oo_v1, run_ladder, revgnss.OrbitFrame

    thisDir = fileparts(mfilename('fullpath'));
    addpath(thisDir);                       % +revgnss / +data packages
    addpath(fullfile(thisDir, 'config'));

    % ---- Resolve the .mat path (DEFAULT = file picker) ---------------------
    outputDir = fullfile(thisDir, 'output');
    if nargin < 1 || isempty(matPath) || strcmpi(matPath, 'pick')
        matPath = i_pickMat(outputDir);
    elseif strcmpi(matPath, 'latest')
        matPath = i_latestMat(outputDir);
    elseif isfolder(matPath)
        matPath = i_latestMat(matPath);
    end
    if isempty(matPath) || ~isfile(matPath)
        error('plot_mat_report:noMat', 'No report .mat found (looked at: %s).', ...
            char(string(matPath)));
    end
    fprintf('plot_mat_report: loading\n  %s\n', matPath);

    % ---- Load and validate --------------------------------------------------
    S = load(matPath);
    if ~isfield(S, 'diagnostics') || isempty(S.diagnostics)
        error('plot_mat_report:notReportMat', ...
            ['%s does not contain a ''diagnostics'' variable. It is not an oo_v1 ', ...
             'report .mat (produced by run_oo_v1 / run_ladder).'], matPath);
    end
    diag = S.diagnostics;
    if isfield(S, 'cfg'); cfg = S.cfg; else; cfg = struct(); end %#ok<NASGU>

    % ---- Build the tabbed window -------------------------------------------
    [~, stem] = fileparts(matPath);
    figOut = i_buildTabs(diag, i_titleFor(stem, S));

    nTabs = numel(findobj(figOut, 'type', 'uitab'));
    fprintf('plot_mat_report: done -> one window, %d tab(s).\n', nTabs);

    if nargout == 0; clear figOut; end
end

% ===========================================================================
%  WINDOW / TABS
% ===========================================================================

function fig = i_buildTabs(diag, ttl)
    t = diag.getTimeVector();
    t = t(:)';

    fig = figure('Name', ttl, 'NumberTitle', 'off', 'Color', 'w', ...
        'Units', 'normalized', 'Position', [0.08 0.08 0.80 0.82]);
    tg = uitabgroup(fig, 'Units', 'normalized', 'Position', [0 0 1 1]);

    % Each tab is built by its own helper. Guarded so one bad accessor cannot
    % kill the whole window.
    tabs = { ...
        'Position (RAC)', @() i_tabPositionRac(tg, diag, t); ...
        'Attitude',       @() i_tabAttitude(tg, diag, t);   ...
        'Clock bias',     @() i_tabClockBias(tg, diag, t);  ...
        'Clock drift',    @() i_tabClockDrift(tg, diag, t); ...
        'PR residuals',   @() i_tabResiduals(tg, diag, t);  ...
        'Doppler & NIS',  @() i_tabDopplerNis(tg, diag, t); ...
        'Measurements',   @() i_tabMeasurements(tg, diag, t); ...
    };
    for k = 1:size(tabs, 1)
        try
            tabs{k, 2}();
        catch ME
            tl = i_tab(tg, tabs{k, 1}, 1);
            ax = nexttile(tl);
            text(ax, 0.5, 0.5, sprintf('%s unavailable:\n%s', tabs{k, 1}, ME.message), ...
                'Units', 'normalized', 'HorizontalAlignment', 'center', ...
                'Color', [0.6 0.2 0.2], 'Interpreter', 'none');
            axis(ax, 'off');
            fprintf('  [skip tab] %-14s (%s)\n', tabs{k, 1}, ME.message);
        end
    end
end

function tl = i_tab(tg, name, nrows)
    % A tab holding a vertical stack of nrows (<= 2) tiles.
    tab = uitab(tg, 'Title', name);
    tl  = tiledlayout(tab, nrows, 1, 'Padding', 'compact', 'TileSpacing', 'compact');
end

% ===========================================================================
%  TAB BUILDERS  (each <= 2 subplots)
% ===========================================================================

function i_tabPositionRac(tg, diag, t)
    ev  = diag.getPositionErrorVecs();          % 3 x N ECEF error [m]
    rTr = diag.getTruthPositionVecs();          % 3 x N ECEF [m]
    vTr = diag.getTruthVelocityVecs();          % 3 x N ECEF [m/s]
    rac = revgnss.OrbitFrame.ecefToRacGeo(ev, rTr, vTr);   % 3 x N [R;A;C]

    tl = i_tab(tg, 'Position (RAC)', 2);

    ax1 = nexttile(tl); hold(ax1, 'on');
    plot(ax1, t, rac(1, :), 'Color', 'b',        'LineWidth', 1.2, 'DisplayName', 'Radial');
    plot(ax1, t, rac(2, :), 'Color', 'r',        'LineWidth', 1.2, 'DisplayName', 'Along-track');
    plot(ax1, t, rac(3, :), 'Color', [0 0.6 0],  'LineWidth', 1.2, 'DisplayName', 'Cross-track');
    grid(ax1, 'on'); ylabel(ax1, 'Error [m]');
    title(ax1, 'Position Error — Radial / Along-track / Cross-track (RAC)');
    legend(ax1, 'Location', 'best');

    ax2 = nexttile(tl);
    pn = diag.getPositionErrors();              % ||dr|| per epoch [m]
    plot(ax2, t, pn(:)', 'b', 'LineWidth', 1.5);
    grid(ax2, 'on'); xlabel(ax2, 'Time [s]'); ylabel(ax2, '||dr|| [m]');
    title(ax2, 'Position Error Norm');
end

function i_tabAttitude(tg, diag, t)
    eul = diag.getAttitudeErrorVecs() * 180/pi; % 3 x N [deg]
    tl  = i_tab(tg, 'Attitude', 2);

    ax1 = nexttile(tl);
    if isempty(eul) || all(~isfinite(eul(:)))
        i_noteAxes(ax1, 'No attitude data in this run.');
    else
        hold(ax1, 'on');
        plot(ax1, t, eul(1, :), 'Color', 'b',       'LineWidth', 1.2, 'DisplayName', 'Roll');
        plot(ax1, t, eul(2, :), 'Color', 'r',       'LineWidth', 1.2, 'DisplayName', 'Pitch');
        plot(ax1, t, eul(3, :), 'Color', [0 0.6 0], 'LineWidth', 1.2, 'DisplayName', 'Yaw');
        grid(ax1, 'on'); ylabel(ax1, 'Error [deg]');
        title(ax1, 'Attitude Error — Roll / Pitch / Yaw');
        legend(ax1, 'Location', 'best');
    end

    ax2 = nexttile(tl);
    if isempty(eul) || all(~isfinite(eul(:)))
        i_noteAxes(ax2, 'Attitude is unobservable here (e.g. single antenna).');
    else
        nrm = sqrt(sum(eul.^2, 1));
        plot(ax2, t, nrm(:)', 'b', 'LineWidth', 1.5);
        grid(ax2, 'on'); xlabel(ax2, 'Time [s]'); ylabel(ax2, '||dEuler|| [deg]');
        title(ax2, 'Attitude Error Norm');
    end
end

function i_tabClockBias(tg, diag, t)
    c   = revgnss.Constants.SPEED_OF_LIGHT_MPS;
    d   = diag.getData();
    tr  = d.truth.rxClockBias_m(:)';
    es  = d.estimate.rxClockBias_m(:)';
    er  = d.error.clockBias_m(:)';

    tl = i_tab(tg, 'Clock bias', 2);

    ax1 = nexttile(tl); hold(ax1, 'on');
    plot(ax1, t, tr / c * 1e9, 'b',   'LineWidth', 1.2, 'DisplayName', 'Truth');
    plot(ax1, t, es / c * 1e9, 'r--', 'LineWidth', 1.2, 'DisplayName', 'Estimate');
    grid(ax1, 'on'); ylabel(ax1, 'Clock bias [ns]');
    title(ax1, 'Receiver Clock Bias — Truth vs Estimate');
    legend(ax1, 'Location', 'best');

    ax2 = nexttile(tl);
    plot(ax2, t, er / c * 1e9, 'k', 'LineWidth', 1.2);
    grid(ax2, 'on'); xlabel(ax2, 'Time [s]'); ylabel(ax2, 'Error [ns]');
    title(ax2, 'Receiver Clock Bias Error');
end

function i_tabClockDrift(tg, diag, t)
    c   = revgnss.Constants.SPEED_OF_LIGHT_MPS;
    d   = diag.getData();
    tr  = d.truth.rxFracFreq(:)';
    es  = d.estimate.rxClockDrift_mps(:)' / c;
    er  = d.error.clockDrift_mps(:)';

    tl = i_tab(tg, 'Clock drift', 2);

    ax1 = nexttile(tl); hold(ax1, 'on');
    plot(ax1, t, tr, 'b',   'LineWidth', 1.2, 'DisplayName', 'Truth');
    plot(ax1, t, es, 'r--', 'LineWidth', 1.2, 'DisplayName', 'Estimate');
    grid(ax1, 'on'); ylabel(ax1, 'Frac freq [-]');
    title(ax1, 'Receiver Fractional Frequency — Truth vs Estimate');
    legend(ax1, 'Location', 'best');

    ax2 = nexttile(tl);
    plot(ax2, t, er / c * 1e12, 'k', 'LineWidth', 1.2);
    grid(ax2, 'on'); xlabel(ax2, 'Time [s]'); ylabel(ax2, 'Drift error [ps/s]');
    title(ax2, 'Receiver Clock Drift Error');
end

function i_tabResiduals(tg, diag, t)
    tl = i_tab(tg, 'PR residuals', 2);

    ax1 = nexttile(tl);
    plot(ax1, t, diag.getPrefitPseudorangeRMS(), 'b', 'LineWidth', 1.5);
    grid(ax1, 'on'); ylabel(ax1, 'RMS [m]');
    title(ax1, 'Pseudorange Prefit Innovation RMS');

    ax2 = nexttile(tl);
    plot(ax2, t, diag.getPostfitPseudorangeRMS(), 'b', 'LineWidth', 1.5);
    grid(ax2, 'on'); xlabel(ax2, 'Time [s]'); ylabel(ax2, 'RMS [m]');
    title(ax2, 'Pseudorange Postfit Residual RMS');
end

function i_tabDopplerNis(tg, diag, t)
    tl = i_tab(tg, 'Doppler & NIS', 2);

    ax1 = nexttile(tl);
    pf  = diag.getPrefitDopplerRMS();
    pof = diag.getPostfitDopplerRMS();
    if any(pf > 0) || any(pof > 0)
        hold(ax1, 'on');
        plot(ax1, t, pf,  'b',   'LineWidth', 1.5, 'DisplayName', 'Prefit');
        plot(ax1, t, pof, 'r--', 'LineWidth', 1.5, 'DisplayName', 'Postfit');
        legend(ax1, 'Location', 'best');
    else
        i_noteAxes(ax1, 'No Doppler in the EKF this run.');
    end
    grid(ax1, 'on'); ylabel(ax1, 'Doppler RMS [m/s]');
    title(ax1, 'Doppler Prefit / Postfit RMS');

    ax2 = nexttile(tl);
    NIS    = diag.getNIS();
    m_mean = mean(diag.getNumMeasurementRows());
    plot(ax2, t, NIS, 'b', 'LineWidth', 1.2); hold(ax2, 'on');
    if m_mean > 0
        yline(ax2, m_mean,   'r--', 'LineWidth', 1.2);
        yline(ax2, 3*m_mean, 'k:',  'LineWidth', 1.0);
        legend(ax2, {'NIS', sprintf('E[NIS]\\approx%.0f', m_mean), '3\times E[NIS]'}, ...
            'Location', 'best');
    end
    grid(ax2, 'on'); xlabel(ax2, 'Time [s]'); ylabel(ax2, 'NIS');
    title(ax2, 'Normalised Innovation Squared (NIS)');
end

function i_tabMeasurements(tg, diag, t)
    nv = diag.getNumVisibleTowers();
    nm = diag.getNumMeasurements();
    tl = i_tab(tg, 'Measurements', 2);

    ax1 = nexttile(tl);
    plot(ax1, t, nv, 'b.', 'MarkerSize', 6); hold(ax1, 'on');
    yline(ax1, mean(nv), 'b--', 'LineWidth', 1.0, 'DisplayName', sprintf('Mean %.1f', mean(nv)));
    grid(ax1, 'on'); ylabel(ax1, 'Count'); ylim(ax1, [0, max(max(nv)+1, 2)]);
    title(ax1, 'Visible Ground Towers per Epoch');

    ax2 = nexttile(tl);
    plot(ax2, t, nm, 'r.', 'MarkerSize', 6); hold(ax2, 'on');
    yline(ax2, max(nm), 'r--', 'LineWidth', 1.0, 'DisplayName', sprintf('Max %d', max(nm)));
    grid(ax2, 'on'); xlabel(ax2, 'Time [s]'); ylabel(ax2, 'Count'); ylim(ax2, [0, max(max(nm)+1, 2)]);
    title(ax2, 'Total Pseudorange Measurements per Epoch');
end

% ===========================================================================
%  HELPERS
% ===========================================================================

function i_noteAxes(ax, msg)
    text(ax, 0.5, 0.5, msg, 'Units', 'normalized', 'HorizontalAlignment', 'center', ...
        'FontSize', 10, 'Color', [0.5 0.5 0.5]);
    axis(ax, 'off');
end

function p = i_latestMat(rootDir)
    % Newest report .mat anywhere under rootDir (recursive). Ignores triage files.
    p = '';
    if ~isfolder(rootDir); return; end
    L = dir(fullfile(rootDir, '**', '*.mat'));
    if isempty(L); return; end
    L = L(~[L.isdir]);
    L = L(~contains({L.name}, 'triage_summary', 'IgnoreCase', true));
    if isempty(L); return; end
    [~, idx] = max([L.datenum]);
    p = fullfile(L(idx).folder, L(idx).name);
end

function p = i_pickMat(startDir)
    if ~isfolder(startDir); startDir = pwd; end
    [f, d] = uigetfile({'*.mat', 'oo_v1 report MAT (*.mat)'}, ...
        'Select a report .mat', fullfile(startDir, filesep));
    if isequal(f, 0); error('plot_mat_report:cancelled', 'No file selected.'); end
    p = fullfile(d, f);
end

function ttl = i_titleFor(stem, S)
    bits = {stem};
    try
        if isfield(S, 'cfg') && isfield(S.cfg, 'scenario') && isfield(S.cfg.scenario, 'name')
            bits{end+1} = char(S.cfg.scenario.name);
        end
    catch
    end
    try
        sc = S.cfg.scenario;
        bits{end+1} = sprintf('G%dS%dR%d', i_get(sc, 'nTowers', 0), ...
            i_get(sc, 'nSpaceAssets', 1), i_get(sc, 'nReceivers', 1));
    catch
    end
    try
        bits{end+1} = sprintf('%gs', S.cfg.simulation.duration_s);
    catch
    end
    ttl = sprintf('oo_v1 report  |  %s', strjoin(bits, '  |  '));
end

function v = i_get(s, f, dflt)
    if isstruct(s) && isfield(s, f) && ~isempty(s.(f)); v = s.(f); else; v = dflt; end
end
