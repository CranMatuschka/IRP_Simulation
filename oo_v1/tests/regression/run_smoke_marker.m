% run_smoke_marker  Run the Stage-85 smoke regression and write a marker file so
% the PASS/FAIL survives an MCP request timeout. Report-only refactors must not
% move the frozen scientific metrics.
thisDir = fileparts(mfilename('fullpath'));
addpath(thisDir); addpath(fullfile(thisDir, '..', '..'));
marker = fullfile(thisDir, 'smoke_marker.txt');
if isfile(marker); delete(marker); end
fid = fopen(marker, 'w');
try
    r = run_oo_v1_regression('smoke');
    fprintf(fid, 'PASS=%d\n', r.pass);
    fprintf(fid, 'nShared=%d nCoreFail=%d nNonCoreFail=%d\n', ...
        r.nShared, numel(r.coreFail), numel(r.nonCoreFail));
    if ~isempty(r.coreFail); fprintf(fid, 'CORE: %s\n', strjoin(r.coreFail, ' | ')); end
catch ME
    fprintf(fid, 'ERROR: %s\n%s\n', ME.identifier, ME.message);
end
fclose(fid);
fprintf('smoke marker written\n');
