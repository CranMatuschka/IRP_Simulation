function results = run_ladder(idx)
%RUN_LADDER  Execute the step-wise scenario ladder (see RUN_PLAN_scenario_ladder.md).
%
%   run_ladder            % run ALL scenarios in order (long; the last is 24 h)
%   run_ladder(k)         % run only scenario k (1..10)
%   run_ladder([1 2 3])   % run a subset, in order
%
%   Each scenario starts from the canonical config (masterConfig), applies the
%   ladder deltas below, and runs the SAME pipeline the main script uses
%   (revgnss.ReportRunner.runSingle). Only scenario CONFIG VALUES change between
%   runs; no physics/pipeline code is touched. Every run writes the full report
%   (PDF + MAT + TEX) into its own output/Report_*/ folder (self-describing
%   G#S#R# name), and a one-line metric is appended to output/ladder_results.txt.
%
%   Ladder (5 ground towers throughout, "all toggles on"):
%     A1..A4  1 space asset, receivers 1..4          (3600 s)
%     B2..B6  receivers 4,   space assets 2..6        (3600 s)
%     C1      6 assets, 4 receivers                   (86400 s = 24 h)
%
%   See also: run_oo_v1, plot_mat_report, RUN_PLAN_scenario_ladder.

    thisDir = fileparts(mfilename('fullpath'));
    addpath(thisDir);
    addpath(fullfile(thisDir, 'config'));

    % tag        nSpaceAssets  nReceivers  duration_s
    ladder = { ...
        'S1R1',      1,           1,          3600;  ...   % A1
        'S1R2',      1,           2,          3600;  ...   % A2
        'S1R3',      1,           3,          3600;  ...   % A3
        'S1R4',      1,           4,          3600;  ...   % A4
        'S2R4',      2,           4,          3600;  ...   % B2
        'S3R4',      3,           4,          3600;  ...   % B3
        'S4R4',      4,           4,          3600;  ...   % B4
        'S5R4',      5,           4,          3600;  ...   % B5
        'S6R4',      6,           4,          3600;  ...   % B6
        'S6R4-24h',  6,           4,          86400; ...   % C1 (24 h)
    };

    if nargin < 1 || isempty(idx); idx = 1:size(ladder,1); end

    resultsFile = fullfile(thisDir, 'output', 'ladder_results.txt');
    results = struct('tag',{},'ok',{},'folder',{},'posErr_m',{},'clkErr_ns',{}, ...
                     'attErr_deg',{},'wall_s',{},'message',{});

    for ii = 1:numel(idx)
        k   = idx(ii);
        tag = ladder{k,1}; nS = ladder{k,2}; nR = ladder{k,3}; dur = ladder{k,4};
        fprintf('\n===== LADDER %d/%d : %s  (G5 S%d R%d, %g s) =====\n', ...
            k, size(ladder,1), tag, nS, nR, dur);

        close all force;
        r = struct('tag',tag,'ok',false,'folder','','posErr_m',NaN, ...
                   'clkErr_ns',NaN,'attErr_deg',NaN,'wall_s',NaN,'message','');
        tStart = tic;
        try
            cfg = i_buildCfg(nS, nR, dur, tag);
            out = revgnss.ReportRunner.runSingle(cfg);

            r.folder = out.reportFolder;
            m = i_metrics(out);
            r.posErr_m   = m.posErr_m;
            r.clkErr_ns  = m.clkErr_ns;
            r.attErr_deg = m.attErr_deg;
            r.ok = true;
            fprintf('  DONE %s  pos=%.3f m  clk=%.3f ns  att=%.4f deg\n', ...
                tag, r.posErr_m, r.clkErr_ns, r.attErr_deg);
            fprintf('  folder: %s\n', r.folder);
        catch ME
            r.message = ME.message;
            fprintf('  FAILED %s : %s\n', tag, ME.message);
            for s = 1:numel(ME.stack)
                fprintf('     at %s line %d\n', ME.stack(s).name, ME.stack(s).line);
            end
        end
        r.wall_s = toc(tStart);
        i_appendResult(resultsFile, k, nS, nR, dur, r);
        results(end+1) = r; %#ok<AGROW>
    end
end

% ===========================================================================
function cfg = i_buildCfg(nSpaceAssets, nReceivers, duration_s, tag)
    % Start from the canonical config, then apply the ladder deltas.
    cfg = masterConfig();

    % --- "All toggles on": the five error-source effects that are off by default.
    cfg.errors.hardwareDelay.enable    = true;
    cfg.errors.multipath.enable        = true;
    cfg.effects.towerSurvey.enable     = true;
    cfg.effects.antennaPCV.enable      = true;
    cfg.effects.correlatedNoise.enable = true;
    % Re-slave the truth/model pair for the effects that carry one, so truth==model
    % (no manufactured mismatch). correlatedNoise is a single-flag effect.
    cfg = expandEnableToggles(cfg, { ...
        'errors.hardwareDelay', 'errors.multipath', ...
        'effects.towerSurvey',  'effects.antennaPCV' });

    % --- Ladder knobs.
    cfg.scenario.nSpaceAssets = nSpaceAssets;
    cfg.scenario.nReceivers   = nReceivers;   % finalizeConfig rebuilds lever arms
                                              % from this and sets attitude on/off.
    cfg.simulation.duration_s = duration_s;
    cfg.report.runVersion     = tag;

    % masterConfig's scenario assembly wired the ISL swarm for its default (6 assets).
    % Overriding nSpaceAssets afterwards does NOT re-run that branch, so mirror it here:
    % a single asset is the ground-only golden path with no inter-satellite links.
    if nSpaceAssets <= 1
        cfg.measurements.isl.enable                  = false;
        cfg.measurements.isl.timing.enable           = false;
        cfg.measurements.isl.twoWay.enable           = false;
        cfg.measurements.isl.twoWay.range.enable     = false;
        cfg.measurements.isl.twoWay.range.useInEKF   = false;
        cfg.measurements.isl.twoWay.doppler.enable   = false;
        cfg.measurements.isl.twoWay.doppler.useInEKF = false;
    end

    % Long run: keep the MAT bounded by sampling snapshots less often.
    if duration_s >= 86400
        cfg.diagnostics.storage.snapshot.interval_s = 900;
    end

    % Set the per-run output folder explicitly (mirrors run_oo_v1). This bypasses
    % ReportRunner's native naming, whose %03d assumes a NUMERIC runVersion and would
    % otherwise mangle the string tag. Folder name carries the full topology.
    base    = cfg.report.baseOutputDir;
    dateStr = datestr(now, 'yyyymmdd');                 %#ok<TNOW1,DATST>
    timeStr = datestr(now, 'HHMMSS');                   %#ok<TNOW1,DATST>
    runFolder = fullfile(base, ['Report_' dateStr], ...
        sprintf('Report_%s_%s_G5S%dR%d', timeStr, tag, nSpaceAssets, nReceivers));
    if isfolder(runFolder); runFolder = [runFolder '_' timeStr]; end
    cfg.report.reportFolder = runFolder;
    cfg.report.stem         = 'report';
end

% ===========================================================================
function m = i_metrics(out)
    % Final-window (last 10 %) summary metrics from the diagnostics store.
    m = struct('posErr_m',NaN,'clkErr_ns',NaN,'attErr_deg',NaN);
    d = out.simData;
    tail = @(v) v(max(1,floor(0.9*numel(v))):end);
    try
        pe = d.getPositionErrors();               % ||dr|| per epoch [m]
        m.posErr_m = mean(tail(pe(:)), 'omitnan');
    catch; end
    try
        c  = revgnss.Constants.SPEED_OF_LIGHT_MPS;
        cb = abs(d.getClockBiasErrors());          % [m]
        m.clkErr_ns = mean(tail(cb(:)), 'omitnan') / c * 1e9;
    catch; end
    try
        eul = d.getAttitudeErrorVecs() * 180/pi;   % 3 x N [deg]
        if ~isempty(eul)
            nrm = sqrt(sum(eul.^2, 1));
            m.attErr_deg = mean(tail(nrm(:)), 'omitnan');
        end
    catch; end
end

% ===========================================================================
function i_appendResult(resultsFile, k, nS, nR, dur, r)
    if ~isfolder(fileparts(resultsFile)); mkdir(fileparts(resultsFile)); end
    fid = fopen(resultsFile, 'a');
    if fid < 0; return; end
    stamp = datestr(now, 'yyyy-mm-dd HH:MM:SS'); %#ok<TNOW1,DATST>
    if r.ok; status = 'OK'; else; status = 'FAIL'; end
    fprintf(fid, ['%s | #%02d %-9s | G5 S%d R%d %6gs | %-4s | ' ...
        'pos=%8.3f m  clk=%9.3f ns  att=%8.4f deg | %6.0f s | %s | %s\n'], ...
        stamp, k, r.tag, nS, nR, dur, status, ...
        r.posErr_m, r.clkErr_ns, r.attErr_deg, r.wall_s, r.folder, r.message);
    fclose(fid);
end
