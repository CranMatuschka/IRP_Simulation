% run_oo_v1  THE oo_v1 runner: load masterConfig -> simulate -> post -> report.
%
% Phase 6 (fixes C-6): one clean runner, NO environment-variable control. The config
% is config/masterConfig.m, full stop — the run's physics never depends on shell state.
% (The legacy run_oo_reverse_gnss_report.m + OO_V1_* validation tooling is retained for
% the validation test suite; retiring it fully is a separate coordinated migration.)
%
% Output (naming contract):
%   output/<configName>_YYYYMMDD_HHMM.pdf
%   output/<configName>_YYYYMMDD_HHMM.mat
%   output/latest_<configName>.{pdf,mat}   (stable pointers to the most recent run)
close all;

thisDir = fileparts(mfilename('fullpath'));
addpath(thisDir);
addpath(fullfile(thisDir, 'config'));

% ---- Load THE config -------------------------------------------------------
cfg = masterConfig();

% ---- Output naming contract: <configName>_YYYYMMDD_HHMM in output/ ---------
configName = cfg.scenario.name;
stamp      = datestr(now, 'yyyymmdd_HHMM');            %#ok<TNOW1,DATST>
outputDir  = fullfile(thisDir, 'output');
if ~isfolder(outputDir); mkdir(outputDir); end
cfg.report.reportFolder = outputDir;                  % no Report-YYYYMMDD subfolder
cfg.report.stem         = sprintf('%s_%s', configName, stamp);

% ---- Run the pipeline (truth -> estimation -> post -> report) --------------
out = revgnss.ReportRunner.runSingle(cfg);

% ---- Stable latest_* pointers ----------------------------------------------
if cfg.report.writePdf && isfile(out.pdfPath)
    copyfile(out.pdfPath, fullfile(outputDir, sprintf('latest_%s.pdf', configName)));
    fprintf('\nPDF: %s\n', out.pdfPath);
    try; open(out.pdfPath); catch; end
end
if cfg.report.writeMat && isfile(out.matPath)
    copyfile(out.matPath, fullfile(outputDir, sprintf('latest_%s.mat', configName)));
    fprintf('MAT: %s\n', out.matPath);
end

assignin('base', 'oo_v1_last_out', out);
assignin('base', 'oo_v1_last_cfg', cfg);
