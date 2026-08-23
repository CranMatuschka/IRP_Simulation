% run_full_gate_marker  Run the full 3600s regression gate and write a marker file so a
% long run's PASS/FAIL survives an MCP request timeout. Poll the marker from the shell.
thisDir = fileparts(mfilename('fullpath'));
addpath(thisDir); addpath(fullfile(thisDir,'..','..')); addpath(fullfile(thisDir,'..','..','config'));
marker = fullfile(thisDir, 'full_gate_marker.txt');
if isfile(marker); delete(marker); end
rf = run_oo_v1_regression('full');
fid = fopen(marker, 'w');
fprintf(fid, 'pass=%d\ncoreFail=%d\nnonCoreFail=%d\nnShared=%d\nwallSec=%.1f\n', ...
    rf.pass, numel(rf.coreFail), numel(rf.nonCoreFail), rf.nShared, rf.wallSec);
if ~isempty(rf.coreFail); fprintf(fid, 'CORE:\n%s\n', strjoin(rf.coreFail, newline)); end
fclose(fid);
fprintf('MARKER WRITTEN: pass=%d\n', rf.pass);
