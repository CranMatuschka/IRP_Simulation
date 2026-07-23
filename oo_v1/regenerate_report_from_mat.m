function pdfPath = regenerate_report_from_mat(matPath, outFolder)
%REGENERATE_REPORT_FROM_MAT  Rebuild the PDF report from a saved report .mat -- NO sim re-run.
%
%   The runner (run_oo_v1 / ReportRunner) saves a report .mat holding cfg + the diagnostics
%   store (data.SimulationDataStore) + the summary. That is everything the report builder needs,
%   so the PDF can be regenerated WITHOUT re-running the simulation: this loads the .mat,
%   reconstructs the asset/towers from cfg, and drives revgnss.ClockExactReportBuilder to write
%   the LaTeX and compile the PDF (requires pdflatex on PATH).
%
%   USAGE
%     regenerate_report_from_mat(PATH_TO_MAT)             % PDF written next to the .mat
%     regenerate_report_from_mat(PATH_TO_MAT, OUTFOLDER)  % PDF written into OUTFOLDER
%     regenerate_report_from_mat('latest')                % newest report .mat under output/
%     pdf = regenerate_report_from_mat(...)               % returns the PDF path
%
%   See also: run_oo_v1, plot_mat_report, revgnss.ClockExactReportBuilder

    thisDir = fileparts(mfilename('fullpath'));
    addpath(thisDir); addpath(fullfile(thisDir,'config'));

    if nargin < 1 || isempty(matPath) || strcmpi(matPath,'latest')
        matPath = i_newestMat(fullfile(thisDir,'output'));
    end
    assert(isfile(matPath), 'regenerate_report_from_mat:noMat', 'No .mat at: %s', matPath);

    S = load(matPath);
    for req = {'cfg','diagnostics','summary'}
        assert(isfield(S, req{1}), 'regenerate_report_from_mat:badMat', ...
            '.mat missing "%s" -- not an oo_v1 report .mat: %s', req{1}, matPath);
    end
    cfg     = S.cfg;
    simData = S.diagnostics;
    summary = S.summary;

    % Reconstruct the (static) asset + towers from the finalized cfg -- no sim.
    asset = revgnss.SpaceAsset(cfg.asset);
    nT = numel(cfg.towers);
    towers = cell(1, nT);
    for k = 1:nT; towers{k} = revgnss.GroundTower(cfg.towers(k)); end

    [matDir, matName] = fileparts(matPath);
    if nargin < 2 || isempty(outFolder); outFolder = matDir; end
    if ~isfolder(outFolder); mkdir(outFolder); end

    cfg.report.reportFolder = outFolder;
    cfg.report.stem         = [matName '_regen'];
    cfg.report.writePdf     = true;
    cfg.report.compileTex   = 'require';   % needs pdflatex

    fprintf('Regenerating report from %s (no sim re-run)\n', matPath);
    ce = revgnss.ClockExactReportBuilder.build( ...
        simData, simData.getMeta(), asset, towers, cfg, summary);

    if ce.success && ~isempty(ce.pdfPath) && isfile(ce.pdfPath)
        pdfPath = ce.pdfPath;
        info = dir(pdfPath);
        fprintf('>>> PDF regenerated: %s  (%.1f kB)\n', pdfPath, info.bytes/1024);
    else
        pdfPath = '';
        fprintf('>>> PDF NOT produced (success=%d, msg=%s). .tex at: %s\n', ...
            ce.success, i_get(ce,'message'), ce.texPath);
    end
end

function p = i_newestMat(outRoot)
    L = dir(fullfile(outRoot, '**', '*.mat'));
    L = L(~[L.isdir]);
    assert(~isempty(L), 'regenerate_report_from_mat:noMats', 'No .mat files under %s', outRoot);
    [~, ix] = max([L.datenum]);
    p = fullfile(L(ix).folder, L(ix).name);
end

function v = i_get(s, f); if isfield(s,f); v = s.(f); else; v = ''; end; end
