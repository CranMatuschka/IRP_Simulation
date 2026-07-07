function tex = reportTexFingerprint(durationOverride_s)
%REPORTTEXFINGERPRINT  Normalized .tex of the canonical ClockExact report (Phase 7).
%   Runs the canonical masterConfig report at a fixed rng + short duration with
%   compileTex='never' (writes the .tex, skips pdflatex, keeps the .tex), reads it,
%   and strips the nondeterministic tokens (timestamp, git SHA, stage number). Used to
%   byte-verify that each report-section extraction is SECTION-EQUIVALENT: the
%   normalized .tex must be identical before vs after.
    if nargin < 1 || isempty(durationOverride_s); durationOverride_s = 300; end
    thisDir = fileparts(mfilename('fullpath'));
    root    = fullfile(thisDir, '..', '..');
    addpath(root);
    addpath(fullfile(root, 'config'));
    secDir = fullfile(root, 'report', 'sections');
    if isfolder(secDir); addpath(secDir); end   % extracted sections, once they exist

    rng(20260705, 'twister');
    cfg = masterConfig();
    cfg.simulation.duration_s = durationOverride_s;

    tmp = fullfile(tempdir, 'oo_v1_phase7_harness');
    if ~isfolder(tmp); mkdir(tmp); end
    cfg.report.reportFolder = tmp;
    cfg.report.stem         = 'harness';
    cfg.report.writePdf     = true;      % triggers the clockExact .tex path
    cfg.report.writeMat     = false;
    cfg.report.compileTex   = 'never';   % write .tex, no pdflatex, .tex retained

    evalc('out = revgnss.ReportRunner.runSingle(cfg);'); %#ok<NASGU>

    texPath = fullfile(tmp, 'harness.tex');
    assert(isfile(texPath), 'reportTexFingerprint: .tex not produced at %s', texPath);
    raw = fileread(texPath);

    % Normalize nondeterministic tokens (see writeTexFile_ title block).
    tex = raw;
    tex = regexprep(tex, 'on \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}', 'on <TS>');
    tex = regexprep(tex, 'Commit: [0-9a-fA-F]+', 'Commit: <SHA>');
    tex = regexprep(tex, 'Stage \d+', 'Stage <N>');
end
