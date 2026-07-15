% capture_all_golden  Regenerate the Phase-0 golden references (smoke + full).
%   One-time / re-baseline use. Run from a clean, validated checkout. Suppresses
%   the verbose simulation console and prints only confirmations plus the full-run
%   headline metrics so the operator can confirm the validated Stage-85 envelope.
thisDir = fileparts(mfilename('fullpath'));
addpath(thisDir);                        % harness helpers
addpath(fullfile(thisDir, '..', '..'));  % oo_v1 root, for +revgnss

L1 = evalc("captureGolden('smoke')");
L2 = evalc("captureGolden('full')");
L3 = evalc("captureGolden('smoke','headline')");
L4 = evalc("captureGolden('full','headline')");
L5 = evalc("captureGolden('smoke','realism')");
L6 = evalc("captureGolden('full','realism')");
for L = {L1, L2, L3, L4, L5, L6}
    lines = strsplit(L{1}, newline);
    for i = 1:numel(lines)
        if contains(lines{i}, {'Saved', 'core metrics', 'finite metrics'})
            fprintf('%s\n', lines{i});
        end
    end
end

show = {'finalPositionRMS_m', 'finalPositionError_m', 'finalClockBiasRMS_m', ...
        'meanNIS', 'expectedNIS', 'initialAttitudeError_deg', 'finalAttitudeError_deg', ...
        'attitudeImprovementRatio', 'knownAmbImprovementRatio', 'nStates'};
tables = {fullfile(thisDir,'golden','golden_full.mat'), ...
              'FULL 3600s single-antenna golden (confirm vs validated Stage-85 envelope)'; ...
          fullfile(thisDir,'golden','golden_headline_full.mat'), ...
              'FULL 3600s 4-antenna HEADLINE golden (attitude path)'; ...
          fullfile(thisDir,'golden','golden_realism_full.mat'), ...
              'FULL 4-antenna REALISM-GRADE golden (de-optimised v4 config: JOW clock, C/N0, multipath/DCB, luni-solar, EOP/tide)'};
for t = 1:size(tables,1)
    G = load(tables{t,1});
    fprintf('\n--- %s ---\n', tables{t,2});
    for i = 1:numel(show)
        j = find(strcmp(G.metricNames, show{i}), 1);
        if ~isempty(j); fprintf('  %-28s = %.6g\n', show{i}, G.metricValues(j)); end
    end
end
fprintf('\nGOLDEN CAPTURE COMPLETE (single + headline + realism, smoke + full).\n');
