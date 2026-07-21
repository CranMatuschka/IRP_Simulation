function out = run_oo_v1(configPath)
%RUN_OO_V1  THE oo_v1 runner: masterConfig (optionally overlaid by a JSON) -> simulate -> report.
%
% One clean entry point, NO environment-variable control. The base config is
% config/masterConfig.m; an optional JSON file DEEP-OVERLAYS it (only the fields the JSON
% lists are changed), so a run is fully described by masterConfig + one small JSON.
%
%   run_oo_v1                      % masterConfig only (today's default single-asset run)
%   run_oo_v1('run.json')         % masterConfig, then overlay the fields in run.json
%   run_oo_v1('config/swarm.json')% e.g. a JSON that sets scenario.nSpaceAssets = 6
%   out = run_oo_v1(...)          % returns the ReportRunner output struct
%
% For a swarm (scenario.nSpaceAssets > 1) ReportRunner runs the N independent single-asset
% EKFs + the ISL/TWSTFT relative layer and writes ONE unified swarm .mat + PDF (see
% docs/federated_swarm_architecture.md). Every run writes a .mat and (unless report.writePdf
% is false) a PDF -- no separate hand-called runner.
%
% Output (per-run folder):
%   output/Report_YYYYMMDD/Report_v###_G#S#R#_TW#/Report_v###_ts#_G#S#R#_TW#.{pdf,mat,out,tex}
%   output/latest_<configName>.{pdf,mat}   (convenience pointers to the most recent run)

    close all;
    thisDir = fileparts(mfilename('fullpath'));
    addpath(thisDir);
    addpath(fullfile(thisDir, 'config'));

    % ---- Load THE config (masterConfig, optionally overlaid by a JSON) ------
    cfg = masterConfig();
    if nargin >= 1 && ~isempty(configPath)
        jsonPath = configPath;
        if ~isfile(jsonPath); jsonPath = fullfile(thisDir, configPath); end
        assert(isfile(jsonPath), 'run_oo_v1:noJson', 'Config JSON not found: %s', configPath);
        ov  = jsondecode(fileread(jsonPath));
        cfg = i_deepMerge(cfg, ov);
        fprintf('Config overlay applied: %s\n', jsonPath);
    end

    % ---- Per-run output folder: output/Report_YYYYMMDD/Report_v###_G#S#R#/ --
    configName = cfg.scenario.name;
    dateStr    = datestr(now, 'yyyymmdd');                %#ok<TNOW1,DATST>
    if isnumeric(cfg.report.runVersion)
        verTag = sprintf('v%03d', round(cfg.report.runVersion));
    else
        verTag = ['v' regexprep(char(cfg.report.runVersion), '[^A-Za-z0-9._-]', '_')];
    end
    nG = 0; try; nG = cfg.scenario.nTowers;      catch; end %#ok<*NASGU>
    nS = 1; try; nS = cfg.scenario.nSpaceAssets; catch; end
    nR = 1; try; nR = cfg.scenario.nReceivers;   catch; end
    durS = 0; try; durS = round(cfg.simulation.duration_s); catch; end
    tw = 0; try; tw = double(logical(cfg.measurements.twstft.enable)); catch; end
    folderName = sprintf('Report_%s_G%dS%dR%d_TW%d', verTag, nG, nS, nR, tw);
    fileStem   = sprintf('Report_%s_ts%d_G%dS%dR%d_TW%d', verTag, durS, nG, nS, nR, tw);
    outputDir  = fullfile(thisDir, 'output');
    runFolder  = fullfile(outputDir, ['Report_' dateStr], folderName);
    if ~isfolder(runFolder); mkdir(runFolder); end
    cfg.report.reportFolder = runFolder;
    cfg.report.stem         = fileStem;

    % ---- Run the pipeline (single-asset OR federated swarm, chosen inside) --
    out = revgnss.ReportRunner.runSingle(cfg);

    % ---- Convenience latest_* pointers at the output root ------------------
    fprintf('\nRun folder: %s\n', runFolder);
    if cfg.report.writePdf && isfield(out,'pdfPath') && isfile(out.pdfPath)
        copyfile(out.pdfPath, fullfile(outputDir, sprintf('latest_%s.pdf', configName)));
        fprintf('PDF: %s\n', out.pdfPath);
        try; open(out.pdfPath); catch; end
    end
    if cfg.report.writeMat && isfield(out,'matPath') && isfile(out.matPath)
        copyfile(out.matPath, fullfile(outputDir, sprintf('latest_%s.mat', configName)));
        fprintf('MAT: %s\n', out.matPath);
    end

    % ---- Atmosphere-only residual diagnostics (single-asset only) ----------
    if nS <= 1
        try
            revgnss.AtmosphereResidualPlots.generate(cfg, runFolder);
            fprintf('Atmosphere residual diagnostics: %s\n', ...
                fullfile(runFolder, 'atmosphere_residuals_time.png'));
        catch me
            fprintf('Atmosphere diagnostics skipped: %s\n', me.message);
        end
    end

    assignin('base', 'oo_v1_last_out', out);
    assignin('base', 'oo_v1_last_cfg', cfg);
end

% ---------------------------------------------------------------------------- %
function base = i_deepMerge(base, ov)
    % i_deepMerge  Recursively overlay struct OV onto struct BASE. Scalar-struct fields
    % recurse; everything else (values, arrays, cells, struct arrays) is replaced by OV's.
    if ~isstruct(ov); base = ov; return; end
    fn = fieldnames(ov);
    for i = 1:numel(fn)
        f = fn{i};
        if isfield(base, f) && isstruct(base.(f)) && isstruct(ov.(f)) && ...
                isscalar(base.(f)) && isscalar(ov.(f))
            base.(f) = i_deepMerge(base.(f), ov.(f));
        else
            base.(f) = ov.(f);
        end
    end
end
