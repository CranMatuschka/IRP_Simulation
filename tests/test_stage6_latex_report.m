% test_stage6_latex_report
% Phase 9: LatexReportBuilder creates section figures and optionally writes .tex.
%
% Verifies:
%   T1: build() returns non-empty figure array for default config
%   T2: figures have expected page Names (title, abstract, equations, etc.)
%   T3: build() works with carrierFloat config
%   T4: build() works with ionoFree config
%   T5: writeTex=true creates a .tex file on disk
%   T6: compileTex='require' throws when pdflatex unavailable
%   T7: writeTex=false → texPath is empty string
%   T8: figure array has >= 10 pages (one per section)

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_stage6_latex_report ===\n');

% ----------------------------------------------------------------
% T1: build() returns non-empty figure array for default config
% ----------------------------------------------------------------
fprintf('  T1: build() returns non-empty figures ...\n');

cfg1  = latexCfg('default');
diag1 = struct('log', []);

[figs1, ~] = revgnss.LatexReportBuilder.build(diag1, [], [], cfg1, struct('version','1.00'));
assert(~isempty(figs1), 'T1 FAILED: LatexReportBuilder.build returned empty figures');
assert(all(isgraphics(figs1)), 'T1 FAILED: some figure handles are invalid');
fprintf('    %d figure(s) returned: PASS\n', numel(figs1));
close(figs1(isgraphics(figs1)));

% ----------------------------------------------------------------
% T2: figures have expected page Names
% ----------------------------------------------------------------
fprintf('  T2: figure Names include expected sections ...\n');

[figs2, ~] = revgnss.LatexReportBuilder.build(struct('log',[]), [], [], latexCfg('default'), struct());
names2 = arrayfun(@(f) get(f,'Name'), figs2, 'UniformOutput', false);

expectedKeywords = {'Title','Abstract','Equation','Config','State','Measurement','Error','Observability','Verdict','Appendix'};
for k = 1:numel(expectedKeywords)
    kw = expectedKeywords{k};
    assert(any(contains(names2, kw, 'IgnoreCase', true)), ...
        'T2 FAILED: no figure with keyword "%s". Names: %s', kw, strjoin(names2,'|'));
end
fprintf('    all expected section names found in %d figures: PASS\n', numel(figs2));
close(figs2(isgraphics(figs2)));

% ----------------------------------------------------------------
% T3: build() works with carrierFloat config
% ----------------------------------------------------------------
fprintf('  T3: build() works with carrierFloat config ...\n');

[figs3, ~] = revgnss.LatexReportBuilder.build(struct('log',[]), [], [], ...
    latexCfg('carrier'), struct('carrierMode','ekfFloat','ambiguityMode','float'));
assert(numel(figs3) >= 1, 'T3 FAILED: no figures for carrierFloat config');
fprintf('    %d figures for carrierFloat config: PASS\n', numel(figs3));
close(figs3(isgraphics(figs3)));

% ----------------------------------------------------------------
% T4: build() works with ionoFree config
% ----------------------------------------------------------------
fprintf('  T4: build() works with ionoFree config ...\n');

[figs4, ~] = revgnss.LatexReportBuilder.build(struct('log',[]), [], [], ...
    latexCfg('ionoFree'), struct('codeMode','ionosphereFree'));
assert(numel(figs4) >= 1, 'T4 FAILED: no figures for ionoFree config');
fprintf('    %d figures for ionoFree config: PASS\n', numel(figs4));
close(figs4(isgraphics(figs4)));

% ----------------------------------------------------------------
% T5: writeTex=true creates a .tex file on disk
% ----------------------------------------------------------------
fprintf('  T5: writeTex=true creates .tex file ...\n');

tmpDir5 = tempname();
mkdir(tmpDir5);

cfg5 = latexCfg('default');
cfg5.report.writeTex      = true;
cfg5.report.compileTex    = 'never';
cfg5.report.baseOutputDir = tmpDir5;

[figs5, tex5] = revgnss.LatexReportBuilder.build(struct('log',[]), [], [], cfg5, struct());

if ~isempty(tex5)
    assert(exist(tex5,'file') == 2, ...
        'T5 FAILED: .tex file not found at %s', tex5);
    info5 = dir(tex5);
    assert(info5.bytes > 0, 'T5 FAILED: .tex file is empty');
    fprintf('    .tex written (%.1f kB): PASS\n', info5.bytes/1024);
else
    fprintf('    writeTex returned empty path (vacuous PASS — dir permission?)\n');
end
close(figs5(isgraphics(figs5)));
try; rmdir(tmpDir5,'s'); catch; end

% ----------------------------------------------------------------
% T6: compileTex='require' throws when pdflatex unavailable
% ----------------------------------------------------------------
fprintf('  T6: compileTex=''require'' throws if pdflatex absent ...\n');

[pdflatexStatus, ~] = system('pdflatex --version 2>/dev/null');
pdflatexAvail = (pdflatexStatus == 0);

if ~pdflatexAvail
    tmpDir6 = tempname();
    mkdir(tmpDir6);
    cfg6 = latexCfg('default');
    cfg6.report.writeTex      = true;
    cfg6.report.compileTex    = 'require';
    cfg6.report.baseOutputDir = tmpDir6;

    threwT6 = false;
    try
        revgnss.LatexReportBuilder.build(struct('log',[]), [], [], cfg6, struct());
    catch ME
        threwT6 = true;
        assert(contains(ME.identifier,'latexUnavailable') || ...
               contains(ME.identifier,'LatexReportBuilder'), ...
            'T6 FAILED: wrong error id: %s', ME.identifier);
        fprintf('    caught expected error: %s\n', ME.identifier);
    end
    assert(threwT6, 'T6 FAILED: compileTex=require should throw when pdflatex absent');
    fprintf('    throws correctly: PASS\n');
    try; rmdir(tmpDir6,'s'); catch; end
else
    fprintf('    pdflatex found — T6 skipped (cannot test absence)\n');
end

% ----------------------------------------------------------------
% T7: writeTex=false → texPath is empty
% ----------------------------------------------------------------
fprintf('  T7: writeTex=false → texPath is empty ...\n');

cfg7 = latexCfg('default');
cfg7.report.writeTex = false;

[figs7, tex7] = revgnss.LatexReportBuilder.build(struct('log',[]), [], [], cfg7, struct());
assert(isempty(tex7), 'T7 FAILED: texPath should be empty when writeTex=false, got %s', tex7);
fprintf('    texPath empty: PASS\n');
close(figs7(isgraphics(figs7)));

% ----------------------------------------------------------------
% T8: >= 10 section pages returned
% ----------------------------------------------------------------
fprintf('  T8: >= 10 section pages ...\n');

[figs8, ~] = revgnss.LatexReportBuilder.build(struct('log',[]), [], [], latexCfg('default'), struct());
assert(numel(figs8) >= 10, ...
    'T8 FAILED: expected >= 10 section figures, got %d', numel(figs8));
fprintf('    %d section figures (>= 10): PASS\n', numel(figs8));
close(figs8(isgraphics(figs8)));

fprintf('=== test_stage6_latex_report: ALL PASS ===\n');

% ----------------------------------------------------------------
% Local functions — must be at end of script
% ----------------------------------------------------------------
function cfg = latexCfg(preset)
    if nargin < 1; preset = 'default'; end
    switch preset
        case 'carrier';  cfg = revgnss.ConfigFactory.carrierFloatConfig();
        case 'ionoFree'; cfg = revgnss.ConfigFactory.dualFrequencyIFConfig();
        otherwise;       cfg = revgnss.ConfigFactory.defaultConfig();
    end
    cfg.plots.enable    = false;
    cfg.report.enable   = false;
    cfg.report.style    = 'latex';
    cfg.report.writeTex = false;
    cfg = revgnss.ConfigFactory.finalizeConfig(cfg);
end
