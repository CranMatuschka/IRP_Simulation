% capture_all_golden  Regenerate the Phase-0 golden references (smoke + full).
%   One-time / re-baseline use. Run from a clean, validated checkout. Suppresses
%   the verbose simulation console and prints only confirmations plus the full-run
%   headline metrics so the operator can confirm the validated Stage-85 envelope.
thisDir = fileparts(mfilename('fullpath'));
addpath(thisDir);                        % harness helpers
addpath(fullfile(thisDir, '..', '..'));  % oo_v1 root, for +revgnss

L1 = evalc("captureGolden('smoke')");
L2 = evalc("captureGolden('full')");
for L = {L1, L2}
    lines = strsplit(L{1}, newline);
    for i = 1:numel(lines)
        if contains(lines{i}, {'Saved', 'core metrics', 'finite metrics'})
            fprintf('%s\n', lines{i});
        end
    end
end

G = load(fullfile(thisDir, 'golden', 'golden_full.mat'));
show = {'finalPositionRMS_m', 'finalPositionError_m', 'finalClockBiasRMS_m', ...
        'meanNIS', 'expectedNIS', 'initialAttitudeError_deg', 'finalAttitudeError_deg', ...
        'attitudeImprovementRatio', 'knownAmbImprovementRatio'};
fprintf('\n--- FULL 3600s headline (confirm vs validated Stage-85 envelope) ---\n');
for i = 1:numel(show)
    j = find(strcmp(G.metricNames, show{i}), 1);
    if ~isempty(j); fprintf('  %-28s = %.6g\n', show{i}, G.metricValues(j)); end
end
fprintf('\nGOLDEN CAPTURE COMPLETE (smoke + full).\n');
