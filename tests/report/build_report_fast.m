function outInfo = build_report_fast(durationOverride_s, doCompilePdf)
% build_report_fast  Fast report-iteration harness for the readability refactor.
%   Builds the clockExact .tex (and optionally the PDF) from masterConfig with a
%   short duration, writing to a fixed scratch folder so the generated .tex can be
%   diffed/grepped between edits without waiting for a full-length run.
%
%   outInfo = build_report_fast()            % 60 s sim, .tex only (no pdflatex)
%   outInfo = build_report_fast(120, true)   % 120 s sim, compile PDF too
%
%   Returns struct with .texPath, .pdfPath, .outDir. Never uses the golden path.
    if nargin < 1 || isempty(durationOverride_s); durationOverride_s = 60; end
    if nargin < 2 || isempty(doCompilePdf);        doCompilePdf = false;    end

    thisDir = fileparts(mfilename('fullpath'));      % .../oo_v1/tests/report
    root    = fullfile(thisDir, '..', '..');         % .../oo_v1
    addpath(root); addpath(fullfile(root, 'config'));

    rng(20260705, 'twister');
    cfg = masterConfig();
    cfg.simulation.duration_s = durationOverride_s;

    outDir = fullfile(tempdir, 'oo_v1_report_iter');
    if ~isfolder(outDir); mkdir(outDir); end
    cfg.report.reportFolder = outDir;
    cfg.report.stem         = 'iter';
    cfg.report.writePdf     = true;
    cfg.report.writeMat     = false;
    cfg.report.writeTex     = true;
    if doCompilePdf
        cfg.report.compileTex = 'require';
    else
        cfg.report.compileTex = 'never';
    end
    % Faster: skip the known-ambiguity validation replay for iteration.
    try; cfg.estimator.runKnownAmbiguityValidation = false; catch; end

    evalc('out = revgnss.ReportRunner.runSingle(cfg);'); %#ok<NASGU>

    outInfo = struct();
    outInfo.outDir  = outDir;
    outInfo.texPath = fullfile(outDir, 'iter.tex');
    outInfo.pdfPath = fullfile(outDir, 'iter.pdf');
    fprintf('TEX=%s\n', outInfo.texPath);
    if isfile(outInfo.texPath)
        info = dir(outInfo.texPath);
        fprintf('TEX_BYTES=%d\n', info.bytes);
    else
        fprintf('TEX_MISSING\n');
    end
    if doCompilePdf
        if isfile(outInfo.pdfPath)
            info = dir(outInfo.pdfPath);
            fprintf('PDF_BYTES=%d\n', info.bytes);
        else
            fprintf('PDF_MISSING\n');
        end
    end
end
