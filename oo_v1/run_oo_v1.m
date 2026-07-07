% run_oo_v1  THE oo_v1 runner: load masterConfig -> simulate -> post -> report.
%
% Phase 6 (fixes C-6): one clean runner, NO environment-variable control. The config
% is config/masterConfig.m, full stop — the run's physics never depends on shell state.
% (The legacy run_oo_reverse_gnss_report.m + OO_V1_* validation tooling is retained for
% the validation test suite; retiring it fully is a separate coordinated migration.)
%
% Output (per-run folder):
%   output/Report_YYYYMMDD/Report_v###_HHMM/<configName>_v###_HHMM.{pdf,mat,tex}
%     (### = cfg.report.runVersion, set in config/masterConfig.m)
%   output/latest_<configName>.{pdf,mat}   (convenience pointers to the most recent run)
close all;

thisDir = fileparts(mfilename('fullpath'));
addpath(thisDir);
addpath(fullfile(thisDir, 'config'));

% ---- Load THE config -------------------------------------------------------
cfg = masterConfig();

% ---- Per-run output folder: output/Report_YYYYMMDD/Report_v###_HHMM/ -------
% Every run gets its OWN folder (no more overwriting two files). The version tag
% is cfg.report.runVersion (part of the config): numeric -> v%03d, else as-is.
configName = cfg.scenario.name;
nowClock   = now;                                     %#ok<TNOW1>
dateStr    = datestr(nowClock, 'yyyymmdd');           %#ok<DATST>
timeStr    = datestr(nowClock, 'HHMM');               %#ok<DATST>
if isnumeric(cfg.report.runVersion)
    verTag = sprintf('v%03d', round(cfg.report.runVersion));
else
    verTag = ['v' regexprep(char(cfg.report.runVersion), '[^A-Za-z0-9._-]', '_')];
end
outputDir  = fullfile(thisDir, 'output');
runFolder  = fullfile(outputDir, ['Report_' dateStr], ['Report_' verTag '_' timeStr]);
if isfolder(runFolder)                                % avoid clobber on same-minute reruns
    runFolder = [runFolder '_' datestr(nowClock, 'ss')];  %#ok<DATST>
end
if ~isfolder(runFolder); mkdir(runFolder); end
cfg.report.reportFolder = runFolder;                  % PDF + MAT (+ TEX) land in the run folder
cfg.report.stem         = sprintf('%s_%s_%s', configName, verTag, timeStr);

% ---- Run the pipeline (truth -> estimation -> post -> report) --------------
out = revgnss.ReportRunner.runSingle(cfg);

% ---- Convenience latest_* pointers at the output root ----------------------
fprintf('\nRun folder: %s\n', runFolder);
if cfg.report.writePdf && isfile(out.pdfPath)
    copyfile(out.pdfPath, fullfile(outputDir, sprintf('latest_%s.pdf', configName)));
    fprintf('PDF: %s\n', out.pdfPath);
    try; open(out.pdfPath); catch; end
end
if cfg.report.writeMat && isfile(out.matPath)
    copyfile(out.matPath, fullfile(outputDir, sprintf('latest_%s.mat', configName)));
    fprintf('MAT: %s\n', out.matPath);
end

assignin('base', 'oo_v1_last_out', out);
assignin('base', 'oo_v1_last_cfg', cfg);
