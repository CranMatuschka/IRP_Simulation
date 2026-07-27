function out = run_oo_v1(configPath)
%RUN_OO_V1  THE oo_v1 runner: masterConfig (optionally overlaid by a JSON) -> simulate -> report.
%
% One clean entry point, NO environment-variable control. The base config is
% config/masterConfig.m; an optional JSON file DEEP-OVERLAYS it (only the fields the JSON
% lists are changed), so a run is fully described by masterConfig + one small JSON.
% JSON files are direct cfg overlays; this runner does not apply per-JSON MATLAB translators.
%
%   run_oo_v1                      % masterConfig only (today's default single-asset run)
%   run_oo_v1('run.json')         % masterConfig, then overlay the fields in run.json
%   run_oo_v1('realism.json')     % resolves to config/scenarios/realism.json if needed
%   run_oo_v1('config/scenarios/swarm.json')% e.g. a JSON that sets scenario.nSpaceAssets = 6
%   out = run_oo_v1(...)          % returns the ReportRunner output struct
%
% For a swarm (scenario.nSpaceAssets > 1) ReportRunner runs the N independent single-asset
% EKFs + the ISL/TWSTFT relative layer and writes ONE unified swarm .mat + PDF (see
% docs/federated_swarm_architecture.md). Every run writes a .mat and (unless report.writePdf
% is false) a PDF -- no separate hand-called runner.
%
% Output (per-run folder):
%   output/Report_YYYYMMDD/Report_v###_G#S#R#_TW#/Report_v###_ts#_G#S#R#_TW#.{pdf,mat,out,tex}
%   output/latest/latest_<configName>.{pdf,mat}  (pointers to the most recent run)

    close all;
    thisDir = fileparts(mfilename('fullpath'));
    addpath(thisDir);
    addpath(fullfile(thisDir, 'config'));
    addpath(fullfile(thisDir, 'config', 'internal'));

    % ---- Load THE config (masterConfig, optionally overlaid by a JSON) ------
    cfg = masterConfig();
    if nargin >= 1 && ~isempty(configPath)
        jsonPath = configPath;
        if ~isfile(jsonPath); jsonPath = fullfile(thisDir, configPath); end
        if ~isfile(jsonPath); jsonPath = fullfile(thisDir, 'config', 'scenarios', configPath); end
        if ~isfile(jsonPath)
            [~, scenarioName, scenarioExt] = fileparts(configPath);
            jsonPath = fullfile(thisDir, 'config', 'scenarios', [scenarioName scenarioExt]);
        end
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
    [folderName, fileStem] = revgnss.RunLabelUtils.reportNameParts(cfg, verTag);
    outputDir  = fullfile(thisDir, 'output');
    runFolder  = fullfile(outputDir, ['Report_' dateStr], folderName);
    if ~isfolder(runFolder); mkdir(runFolder); end
    cfg.report.reportFolder = runFolder;
    cfg.report.stem         = fileStem;

    % ---- Run the pipeline (single-asset OR federated swarm, chosen inside) --
    out = revgnss.ReportRunner.runSingle(cfg);

    % ---- Convenience latest_* pointers in output/latest/ -------------------
    % Copies only; a cloud-sync copy timeout must NOT fail the run (the primary
    % report is already written in runFolder).
    latestDir = fullfile(outputDir, 'latest');
    if ~isfolder(latestDir); mkdir(latestDir); end
    fprintf('\nRun folder: %s\n', runFolder);
    if cfg.report.writePdf && isfield(out,'pdfPath') && isfile(out.pdfPath)
        try; copyfile(out.pdfPath, fullfile(latestDir, sprintf('latest_%s.pdf', configName)));
        catch me; fprintf('latest_ PDF copy skipped: %s\n', me.message); end
        fprintf('PDF: %s\n', out.pdfPath);
        try; open(out.pdfPath); catch; end
    end
    if cfg.report.writeMat && isfield(out,'matPath') && isfile(out.matPath)
        try; copyfile(out.matPath, fullfile(latestDir, sprintf('latest_%s.mat', configName)));
        catch me; fprintf('latest_ MAT copy skipped: %s\n', me.message); end
        fprintf('MAT: %s\n', out.matPath);
    end

    % ---- Atmosphere-only residual diagnostics (single-asset only) ----------
    nS = 1;
    try; nS = cfg.scenario.nSpaceAssets; catch; end
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
