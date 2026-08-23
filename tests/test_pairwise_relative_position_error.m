function test_pairwise_relative_position_error()
% Pin the all-pairs relative position error: the swarm-internal accuracy metric.
%
% T1 analytic correctness  - a known displacement of one satellite produces exactly
%                            that displacement on every pair containing it, and zero
%                            on every pair that does not.
% T2 symmetry / self       - the pair enumeration and pairRow round-trip are consistent.
% T3 translation-invariant - NEGATIVE CONTROL. Displacing the WHOLE formation leaves
%                            every pairwise value bit-identical while the absolute
%                            error changes. This invariance is the whole point of the
%                            metric; without it the test suite would not distinguish a
%                            relative metric from an Earth-referenced one.
% T4 vector vs scalar      - the vector error is >= |scalar length error|, strictly
%                            greater when the error is perpendicular to the baseline.
%                            Guards the confusion that these two are interchangeable.
% T5 consistency           - for pairs containing the reference asset, the new value
%                            equals the existing reference-anchored
%                            relativeBaselineError_m row exactly.
% T6 mandatory             - a real multi-asset run publishes the field with all
%                            N*(N-1)/2 rows, with no toggle involved.

root = fileparts(fileparts(mfilename('fullpath')));
addpath(root);
addpath(fullfile(root,'config'));
addpath(fullfile(root,'config','internal'));

nAssets = 5;
nEpoch = 12;
rng(11);
truth = 1e7*randn(3,nAssets,nEpoch);
names = arrayfun(@(a) sprintf('SAT%d',a),1:nAssets,'UniformOutput',false);

% ---------------------------------------------------------------- T1
displacedAsset = 3;
displacement_m = [4; -3; 12];          % norm 13 exactly
estimate = truth;
estimate(:,displacedAsset,:) = estimate(:,displacedAsset,:) + displacement_m;

payload = revgnss.PairwiseRelativePositionError.fromEpochArrays( ...
    1:nEpoch,estimate,truth,names,'unitTest','estimateEpochGrid');
assert(payload.available,'Payload must be available for a well-formed input.');
assert(payload.nPairs == nAssets*(nAssets-1)/2, ...
    'Expected %d pairs, got %d.',nAssets*(nAssets-1)/2,payload.nPairs);

for pairIndex = 1:payload.nPairs
    i = payload.pairIndex(pairIndex,1);
    k = payload.pairIndex(pairIndex,2);
    touchesDisplaced = (i == displacedAsset) || (k == displacedAsset);
    observed = payload.relativePositionError_m(pairIndex,:);
    if touchesDisplaced
        assert(max(abs(observed - norm(displacement_m))) < 1e-6, ...
            ['Pair %s contains the displaced satellite so every epoch must read ' ...
             '%.6f m; got max deviation %.3e.'], ...
            payload.pairLabels{pairIndex},norm(displacement_m), ...
            max(abs(observed - norm(displacement_m))));
    else
        assert(max(abs(observed)) < 1e-6, ...
            'Pair %s does not contain the displaced satellite and must read 0.', ...
            payload.pairLabels{pairIndex});
    end
end

% ---------------------------------------------------------------- T2
pairs = revgnss.PairwiseRelativePositionError.pairList(nAssets);
assert(isequal(pairs,payload.pairIndex),'pairList must match the payload enumeration.');
for pairIndex = 1:size(pairs,1)
    i = pairs(pairIndex,1); k = pairs(pairIndex,2);
    assert(revgnss.PairwiseRelativePositionError.pairRow(nAssets,i,k) == pairIndex, ...
        'pairRow(%d,%d) must be row %d.',i,k,pairIndex);
    assert(revgnss.PairwiseRelativePositionError.pairRow(nAssets,k,i) == pairIndex, ...
        'pairRow must be order-insensitive: (%d,%d) and (%d,%d) are one pair.',i,k,k,i);
end

% ---------------------------------------------------------------- T3 (negative control)
commonTranslation_m = [-250; 900; 40];
translatedEstimate = estimate + commonTranslation_m;
translatedPayload = revgnss.PairwiseRelativePositionError.fromEpochArrays( ...
    1:nEpoch,translatedEstimate,truth,names,'unitTest','estimateEpochGrid');
assert(isequal(translatedPayload.relativePositionError_m, ...
    payload.relativePositionError_m), ...
    ['A common translation of the entire formation must leave EVERY pairwise value ' ...
     'bit-identical. It did not, so this is not a swarm-internal metric.']);
assert(isequal(translatedPayload.baselineLengthError_m,payload.baselineLengthError_m), ...
    'A common translation must also leave the scalar length error unchanged.');
% ...and prove the control is not vacuous: the ABSOLUTE error genuinely moved.
absoluteBefore = norm(estimate(:,1,1) - truth(:,1,1));
absoluteAfter = norm(translatedEstimate(:,1,1) - truth(:,1,1));
assert(abs(absoluteAfter - absoluteBefore) > 100, ...
    ['Negative control is vacuous: the common translation did not change the ' ...
     'absolute error either (%.3f -> %.3f m).'],absoluteBefore,absoluteAfter);

% ---------------------------------------------------------------- T4
assert(all(payload.relativePositionError_m(:) >= ...
    abs(payload.baselineLengthError_m(:)) - 1e-9), ...
    'The vector error can never be smaller than the scalar length error.');
% A displacement perpendicular to a baseline changes the vector error but barely the
% length: construct that case explicitly so the inequality is known to be strict.
twoAssetTruth = zeros(3,2,1);
twoAssetTruth(:,2,1) = [1000;0;0];
twoAssetEstimate = twoAssetTruth;
twoAssetEstimate(:,2,1) = twoAssetEstimate(:,2,1) + [0;10;0];   % pure cross-baseline
perpendicular = revgnss.PairwiseRelativePositionError.fromEpochArrays( ...
    1,twoAssetEstimate,twoAssetTruth,{'A','B'},'unitTest','estimateEpochGrid');
assert(abs(perpendicular.relativePositionError_m(1) - 10) < 1e-9, ...
    'A 10 m cross-baseline offset must give a 10 m vector error.');
assert(abs(perpendicular.baselineLengthError_m(1)) < 0.06, ...
    ['A 10 m offset perpendicular to a 1000 m baseline changes its LENGTH by only ' ...
     '~0.05 m (got %.4f). This is exactly why the scalar metric flatters a filter ' ...
     'whose error is cross-baseline.'],perpendicular.baselineLengthError_m(1));

% ---------------------------------------------------------------- T5 + T6 (live run)
cfg = resolveSimulationConfig('test003_jointCoherentTwoWayCode.json');
cfg.simulation.duration_s = 60;
cfg.report.enable = false;
cfg.report.writePdf = false;
cfg.report.writeMat = false;
cfg.plots.enable = false;
warning('off','ReverseGNSSEKF:update');
runOutput = revgnss.ReportRunner.runSingle(cfg);
summary = runOutput.summary;

assert(isfield(summary,'pairwiseRelativePositionError'), ...
    ['A multi-asset run MUST publish summary.pairwiseRelativePositionError. It is ' ...
     'mandatory and not behind any toggle.']);
live = summary.pairwiseRelativePositionError;
assert(live.available,'Live payload must be available: %s',live.reason);
expectedPairs = live.nAssets*(live.nAssets-1)/2;
assert(live.nPairs == expectedPairs, ...
    ['All %d pairs must be reported, not just the %d against the reference asset ' ...
     '(got %d).'],expectedPairs,live.nAssets-1,live.nPairs);
assert(numel(live.pairLabels) == live.nPairs && size(live.pairIndex,1) == live.nPairs, ...
    'Pair labels and indices must cover every pair.');

joint = summary.jointFormationDiagnostics;
for followerIndex = 1:(live.nAssets - 1)
    pairRow = revgnss.PairwiseRelativePositionError.pairRow( ...
        live.nAssets,1,followerIndex + 1);
    referenceAnchored = joint.relativeBaselineError_m(followerIndex,:);
    perPairRow = live.relativePositionError_m(pairRow,:);
    assert(numel(referenceAnchored) == numel(perPairRow), ...
        'Reference-anchored and per-pair series must share the epoch grid.');
    assert(max(abs(referenceAnchored - perPairRow)) < 1e-9, ...
        ['Pair (1,%d) must reproduce the existing relativeBaselineError_m row ' ...
         'exactly; max difference %.3e m.'], ...
        followerIndex+1,max(abs(referenceAnchored - perPairRow)));
end

% ---------------------------------------------------------------- T7 (LaTeX compiles)
% The report section writes LaTeX by hand. MATLAB does not escape-process
% single-quoted literals -- only fprintf's FORMAT argument is processed -- so a row
% emitted via '%s' silently ships literal "\\" and "\n" into the .tex and pdflatex
% rejects the document. Catch that here in seconds instead of after a 3601-epoch run.
scratchDir = tempname;
mkdir(scratchDir);
cleanupScratch = onCleanup(@() rmdir(scratchDir,'s')); %#ok<NASGU>
fragmentPath = fullfile(scratchDir,'fragment.tex');
fragmentId = fopen(fragmentPath,'w');
assert(fragmentId > 0,'Could not open a scratch file for the LaTeX fragment.');
revgnss.report.relativeFormationPairs(fragmentId,cfg,summary,@localEscape_);
fclose(fragmentId);

fragmentText = fileread(fragmentPath);
assert(contains(fragmentText,'Inter-Satellite Relative Position Error'), ...
    'The section must be emitted for a multi-asset run.');
% A legitimate LaTeX row break "\\" is always followed by a newline. An unprocessed
% format string leaves "\\" glued to a letter -- "\\sigma", "\\footnotesize", "\\n" --
% which is the exact signature of a literal passed through %s. (Do NOT simply search
% for "\n": \noindent starts with those characters and is perfectly valid.)
leakedEscape = regexp(fragmentText,'\\\\[A-Za-z]','match','once');
assert(isempty(leakedEscape), ...
    ['The fragment contains "%s": a double backslash glued to a letter. A format ' ...
     'string was passed through %%s instead of being escape-processed by fprintf, ' ...
     'so pdflatex will reject the document.'],leakedEscape);
assert(count(fragmentText,'\\') >= live.nPairs, ...
    'Every pair row must end with a LaTeX row break.');

documentPath = fullfile(scratchDir,'probe.tex');
documentId = fopen(documentPath,'w');
% Mirror ClockExactReportBuilder's real preamble (:1181-1189) so this compile check
% reflects the document the section is actually emitted into. A probe with fewer
% packages would either miss a genuine failure or invent one.
fprintf(documentId,'\\documentclass{article}\n');
fprintf(documentId,'\\usepackage{amsmath}\n\\usepackage{amssymb}\n');
fprintf(documentId,'\\usepackage{longtable}\n\\usepackage{array}\n');
fprintf(documentId,'\\usepackage{booktabs}\n');
fprintf(documentId,'\\begin{document}\n');
fprintf(documentId,'%s',fragmentText);
fprintf(documentId,'\\end{document}\n');
fclose(documentId);

pdflatexBinary = '/Library/TeX/texbin/pdflatex';
if isfile(pdflatexBinary)
    command = sprintf('cd %s && %s -interaction=nonstopmode -halt-on-error probe.tex', ...
        scratchDir,pdflatexBinary);
    [status,output] = system(command);
    assert(status == 0, ...
        'pdflatex rejected the per-pair table:\n%s',output(max(1,end-1200):end));
    assert(isfile(fullfile(scratchDir,'probe.pdf')),'pdflatex produced no PDF.');
else
    fprintf('  (pdflatex not found at %s; compile check skipped)\n',pdflatexBinary);
end

fprintf(['test_pairwise_relative_position_error: PASS ' ...
    '(%d assets, %d pairs, worst %s at %.4f m)\n'], ...
    live.nAssets,live.nPairs,live.worstPairLabel,live.worstPairTailRms_m);
end

function out = localEscape_(in)
% Minimal LaTeX escape standing in for ClockExactReportBuilder.esc_.
out = strrep(char(in),'\','\textbackslash{}');
for token = {'&','%','$','#','_','{','}'}
    out = strrep(out,token{1},['\' token{1}]);
end
end
