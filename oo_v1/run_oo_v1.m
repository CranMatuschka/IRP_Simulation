function out = run_oo_v1(configPath, duration_s)
%RUN_OO_V1 Resolve masterConfig, overlay one JSON, then simulate and report.
%
%   run_oo_v1                              % default.json, 3600 s
%   run_oo_v1('scene008_G5S1R4_TW1_golden.json')
%   run_oo_v1('isl004_sigma0p050golden.json', 7200)   % same scenario, 2 h arc
%   out = run_oo_v1(...)                   % returns the ReportRunner output struct
%
%   DURATION IS OWNED HERE, NOT BY THE SCENARIO. No scenario JSON sets
%   simulation.duration_s any more: the arc length is a property of the run, so
%   one file can be swept over durations without being edited. DURATION_S
%   defaults to 3600 and is injected before validation and finalisation, so
%   everything derived from it is derived from the value actually used.
%
%   The scenario JSONs live in
%       config/                 masterConfig's companions: golden_baseline*,
%                               default.json, realism.json
%       config/ladder/scene/    scene###  formation ladder (opt vs golden, TW0/TW1)
%       config/ladder/feat/     feat###   one feature toggled per file
%       config/ladder/ISL/      isl###    crosslink sigma / configuration / frequency
%       config/ladder/freq/     freq###   L1 / L2 / L5 combinations
%       config/ladder/clock/    clk###    oscillator class on the space and ground
%                               segments (OCXO / rubidium / caesium), plus the
%                               legacy-vs-JOW h-coefficient table
%       config/ladder/test/     test###   fixtures owned by the test suite
%   and are found by name alone, so the folder never has to be spelled out.

    close all;
    thisDir = fileparts(mfilename('fullpath'));
    addpath(thisDir);
    addpath(fullfile(thisDir, 'config'));
    addpath(fullfile(thisDir, 'config', 'internal'));

    % ---- Resolve masterConfig through exactly one selected JSON -------------
    if nargin < 1 || isempty(configPath)
        configPath = 'default.json';
    end
    if nargin < 2 || isempty(duration_s)
        duration_s = 3600;
    end
    assert(isnumeric(duration_s) && isscalar(duration_s) && duration_s > 0, ...
        'run_oo_v1:duration', 'duration_s must be a positive scalar (seconds).');

    runOverrides = struct('simulation', struct('duration_s', double(duration_s)));
    [cfg, configMetadata] = resolveSimulationConfig(configPath, runOverrides);
    fprintf('Config overlay applied: %s  (%d scenario-owned keys)\n', ...
        configMetadata.sourcePath, numel(configMetadata.explicitPaths));
    if numel(configMetadata.extendsChain) > 1
        fprintf('Built on: %s\n', strjoin(configMetadata.extendsChain, ' -> '));
    end
    fprintf('Duration: %g s (run argument, not scenario-owned)\n', ...
        cfg.simulation.duration_s);

    % ---- Per-run output folder: output/Report_YYYYMMDD/Report_<prefix>_... --
    % The report is labelled by the FILE PREFIX (scene008, isl004, feat017, ...)
    % so a report can be traced back to the exact JSON that produced it.
    configName = cfg.scenario.name;
    dateStr    = datestr(now, 'yyyymmdd');                %#ok<TNOW1,DATST>
    verTag     = runLabelTag_(configPath, cfg);
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

function tag = runLabelTag_(configPath, cfg)
%RUNLABELTAG_ The report label: the ladder file prefix when there is one.
%   A ladder file is named <axis><NNN>_<label>.json, so scene008_G5S1R4_TW1_golden
%   labels its report Report_scene008_ts3600_G5S1R4_TW1. Files outside the ladder
%   (default.json, golden_baseline.json) have no numbered prefix and keep the
%   historical v-prefixed report.runVersion tag.
    [~, fileName] = fileparts(char(configPath));
    token = regexp(fileName, '^([A-Za-z]+\d{3})(?:_|$)', 'tokens', 'once');
    if ~isempty(token)
        tag = token{1};
        return
    end
    if isnumeric(cfg.report.runVersion)
        tag = sprintf('v%03d', round(cfg.report.runVersion));
    else
        tag = ['v' regexprep(char(cfg.report.runVersion), '[^A-Za-z0-9._-]', '_')];
    end
end
