function make_utils_figures()
% make_utils_figures  Generate scenario-independent reference figures into output/utils/.
%
%   These are static illustrations that do not depend on a specific run's results.
%   Each figure has its own editable script under utils/; this is just the
%   aggregator that runs them all. The report references the resulting PDFs
%   (e.g. output/utils/spacecraft_frames.pdf) instead of regenerating them.
%
%   Run this once (or after editing a utils/ script); then run the report normally.
%
%   Figures:
%     utils/make_spacecraft_frames.m -> output/utils/spacecraft_frames.pdf
    thisDir = fileparts(mfilename('fullpath'));   % .../oo_v1
    addpath(thisDir); addpath(fullfile(thisDir, 'config'));
    addpath(fullfile(thisDir, 'utils'));

    cfg = masterConfig();

    make_spacecraft_frames(cfg);
end
