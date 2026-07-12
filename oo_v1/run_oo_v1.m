% run_oo_v1  THE oo_v1 runner: load masterConfig -> simulate -> post -> report.
%
% Phase 6 (fixes C-6): one clean runner, NO environment-variable control. The config
% is config/masterConfig.m, full stop — the run's physics never depends on shell state.
% (The legacy run_oo_reverse_gnss_report.m + OO_V1_* validation tooling is retained for
% the validation test suite; retiring it fully is a separate coordinated migration.)
%
% Output (per-run folder):
%   output/Report_YYYYMMDD/Report_v###_G#S#R#/Report_v###_G#S#R#.{pdf,mat,out,tex}
%     v### = cfg.report.runVersion (numeric -> v%03d, else sanitised as-is);
%     G/S/R = ground towers / space assets / receivers.
%   The PDF, MAT, .out and .tex share the folder's name; only figures keep their own.
%   output/latest_<configName>.{pdf,mat}   (convenience pointers to the most recent run)
close all;

thisDir = fileparts(mfilename('fullpath'));
addpath(thisDir);
addpath(fullfile(thisDir, 'config'));

% ---- Load THE config -------------------------------------------------------
% ALL configuration lives in config/masterConfig.m (atmosphere realism and
% ionosphere handling included, via cfg.atmosphere.*). This runner adds NO physics
% toggles of its own — change the run by editing masterConfig, never here.
cfg = masterConfig();

% ---- Per-run output folder: output/Report_YYYYMMDD/Report_v###_G#S#R#/ ------
% Self-describing per-run folder + file stem. The version tag is
% cfg.report.runVersion (numeric -> v%03d, else sanitised); the topology suffix
% G#S#R# is read from the resolved scenario, so the name is fully deterministic.
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
runName    = sprintf('Report_%s_G%dS%dR%d', verTag, nG, nS, nR);
outputDir  = fullfile(thisDir, 'output');
runFolder  = fullfile(outputDir, ['Report_' dateStr], runName);
if ~isfolder(runFolder); mkdir(runFolder); end
cfg.report.reportFolder = runFolder;                  % PDF + MAT (+ TEX + .out) land here
cfg.report.stem         = runName;                    % files: Report_v###_G#S#R#.{pdf,mat,out,tex}

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

% ---- Atmosphere-only residual diagnostics (log-scale, own axis) ------------
% Write the atmosphere truth-model residual figures (vs time and vs elevation) next to
% the report, so the physically-sized troposphere/ionosphere residuals are visible on
% their own scale rather than buried under the code-noise floor. Never fatal to the run.
try
    revgnss.AtmosphereResidualPlots.generate(cfg, runFolder);
    fprintf('Atmosphere residual diagnostics: %s\n', ...
        fullfile(runFolder, 'atmosphere_residuals_time.png'));
catch me
    fprintf('Atmosphere diagnostics skipped: %s\n', me.message);
end

assignin('base', 'oo_v1_last_out', out);
assignin('base', 'oo_v1_last_cfg', cfg);
