function out = run_oo_v1(configPath)
%RUN_OO_V1 Resolve masterConfig, overlay one JSON, then simulate and report.
%
%   run_oo_v1                      % masterConfig overlaid by default.json
%   run_oo_v1('realism.json')     % masterConfig overlaid by realism.json
%   run_oo_v1('run.json')         % masterConfig overlaid by run.json
%   out = run_oo_v1(...)          % returns the ReportRunner output struct

    close all;
    thisDir = fileparts(mfilename('fullpath'));
    addpath(thisDir);
    addpath(fullfile(thisDir, 'config'));
    addpath(fullfile(thisDir, 'config', 'internal'));

    % ---- Resolve masterConfig through exactly one selected JSON -------------
    if nargin < 1 || isempty(configPath)
        configPath = 'default.json';
    end
    [cfg, configMetadata] = resolveSimulationConfig(configPath);
    fprintf('Config overlay applied: %s  (%d scenario-owned keys)\n', ...
        configMetadata.sourcePath, numel(configMetadata.explicitPaths));

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
