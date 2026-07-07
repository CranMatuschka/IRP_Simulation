function make_utils_figures()
% make_utils_figures  Generate scenario-independent reference figures into output/utils/.
%
%   These are static illustrations that do not depend on a specific run's results.
%   Each figure has its own editable script alongside this one in output/utils/;
%   this is just the aggregator that runs them all. The report references the
%   resulting PDFs (e.g. output/utils/spacecraft_frames.pdf) instead of regenerating.
%
%   This script and its figures live together in output/utils/. Run it from the
%   repo root with:  run('output/utils/make_utils_figures.m')  (or cd here first).
%   Run it once (or after editing a figure script); then run the report normally.
%
%   Figures:
%     make_spacecraft_frames.m -> output/utils/spacecraft_frames.pdf
    thisDir = fileparts(mfilename('fullpath'));       % .../oo_v1/output/utils
    rootDir = fileparts(fileparts(thisDir));          % .../oo_v1
    addpath(rootDir); addpath(fullfile(rootDir, 'config'));
    addpath(thisDir);                                 % sibling figure scripts

    cfg = masterConfig();

    make_spacecraft_frames(cfg);
end
