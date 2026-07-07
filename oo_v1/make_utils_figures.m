function make_utils_figures()
% make_utils_figures  Generate scenario-independent reference figures into output/utils/.
%
%   These are static illustrations that do not depend on a specific run's results
%   (currently the spacecraft / reference-frame schematic). The report references
%   output/utils/spacecraft_frames.pdf instead of regenerating it every run.
%
%   Run this once (or after changing the schematic); then run the report normally.
    thisDir = fileparts(mfilename('fullpath'));   % .../oo_v1
    addpath(thisDir); addpath(fullfile(thisDir, 'config'));

    cfg = masterConfig();
    baseDir = fullfile(thisDir, 'output');
    try; baseDir = cfg.report.baseOutputDir; catch; end
    utilsDir = fullfile(baseDir, 'utils');
    if ~exist(utilsDir, 'dir'); mkdir(utilsDir); end

    outPath = revgnss.ClockExactReportBuilder.tryPlot3D_( ...
        utilsDir, 'spacecraft_frames.pdf', ...
        @() revgnss.ClockExactReportBuilder.plotSpacecraftFrames_(cfg));

    if isempty(outPath)
        warning('make_utils_figures:failed', 'spacecraft_frames.pdf was not generated.');
    else
        fprintf('Wrote %s\n', outPath);
    end
end
