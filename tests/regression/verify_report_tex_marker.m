% verify_report_tex_marker  Build the clockExact report .tex once (short run, no pdflatex),
% check for the truth-estimation separation audit content, and write a marker file so the
% result survives an MCP request timeout.
thisDir = fileparts(mfilename('fullpath'));
root    = fullfile(thisDir, '..', '..');
addpath(root); addpath(fullfile(root,'config'));
marker  = fullfile(thisDir, 'verify_report_marker.txt');
if isfile(marker); delete(marker); end
fid = fopen(marker,'w');
try
    rng(20260705,'twister');
    cfg = masterConfig();
    cfg.simulation.duration_s = 60;
    outDir = fullfile(tempdir, 'oo_v1_tesep_verify');
    if ~isfolder(outDir); mkdir(outDir); end
    cfg.report.reportFolder = outDir;
    cfg.report.stem         = 'tesep';
    cfg.report.writePdf     = true;
    cfg.report.writeMat     = false;
    cfg.report.compileTex   = 'never';
    cfg.report.writeTex     = true;
    cfg.estimator.runKnownAmbiguityValidation = false;   % faster; KAV label checked separately
    evalc('out = revgnss.ReportRunner.runSingle(cfg);');
    texPath = fullfile(outDir, 'tesep.tex');
    tex = fileread(texPath);
    % The "Appendix: Simulation Physics and Configuration" (which carried the truth-estimation
    % separation audit markers) was intentionally removed from the report. Verify it is now
    % absent rather than present.
    removed = {'Appendix: Simulation Physics and Configuration', ...
               'Truth-estimation separation audit','truth/EKF dynamics family', ...
               'J2 dynamics policy','Realistic synthetic TE comparison'};
    fprintf(fid,'BUILD_OK\ntexPath=%s\n', texPath);
    for i=1:numel(removed)
        fprintf(fid,'absent[%s]=%d\n', removed{i}, isempty(strfind(tex,removed{i}))); %#ok<STREMP>
    end
catch ME
    fprintf(fid,'BUILD_ERROR\n%s\n%s\n', ME.identifier, ME.message);
    for k=1:numel(ME.stack)
        fprintf(fid,'  at %s (line %d)\n', ME.stack(k).name, ME.stack(k).line);
    end
end
fclose(fid);
fprintf('marker written\n');
