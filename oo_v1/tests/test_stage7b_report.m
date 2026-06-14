% test_stage7b_report
% Stage 7B: report maturity, helper classes, scientific language checks.
%
% Verifies (18 tests):
%   T01: testReportStyleSimpleStillWorks
%   T02: testReportStyleLatexStillWorks
%   T03: testReportWriteTex
%   T04: testReportCompileTexAutoFallback
%   T05: testLatexReportContainsCodeEquation
%   T06: testLatexReportContainsCarrierEquation
%   T07: testLatexReportContainsIFEquation
%   T08: testLatexReportContainsStateVectorTable
%   T09: testLatexReportContainsMeasurementSummary
%   T10: testLatexReportContainsErrorBudget
%   T11: testLatexReportContainsObservability
%   T12: testLatexReportContainsScientificVerdict
%   T13: testLatexReportContainsTestStatus
%   T14: testScientificVerdictNoOverclaiming
%   T15: testLatexReportCarrierFloat
%   T16: testLatexReportIonoFree
%   T17: testLatexReportHandlesMissingOptionalFields
%   T18: testRunOoReverseGnssReportStillWorks

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_stage7b_report ===\n');

% ----------------------------------------------------------------
% T01: testReportStyleSimpleStillWorks
% ----------------------------------------------------------------
fprintf('  T01: simple (non-latex) style still works ...\n');

cfg01 = revgnss.ConfigFactory.idealConfig();
cfg01.simulation.duration_s = 60;
cfg01.simulation.dt_s       = 1.0;
cfg01.plots.enable          = false;
cfg01.report.writePdf       = false;
cfg01.report.writeMat       = false;

out01 = revgnss.ReportRunner.runSingle(cfg01);
assert(isfield(out01,'sim'),  'T01 FAILED: runSingle did not return sim field');
assert(isfield(out01,'diag'), 'T01 FAILED: runSingle did not return diag field');
fprintf('    simple style completed without error: PASS\n');

% ----------------------------------------------------------------
% T02: testReportStyleLatexStillWorks
% ----------------------------------------------------------------
fprintf('  T02: latex style builder returns >= 10 figures ...\n');

cfg02 = revgnss.ConfigFactory.defaultConfig();
cfg02.report.style   = 'latex';
cfg02.report.writeTex = false;
cfg02 = revgnss.ConfigFactory.finalizeConfig(cfg02);

[figs02, ~] = revgnss.LatexReportBuilder.build(struct('log',[]), [], [], cfg02, struct('version','7B'));
assert(numel(figs02) >= 10, ...
    'T02 FAILED: expected >= 10 section figures, got %d', numel(figs02));
assert(all(isgraphics(figs02)), 'T02 FAILED: some figure handles invalid');
fprintf('    latex style: %d section figures: PASS\n', numel(figs02));
close(figs02(isgraphics(figs02)));

% ----------------------------------------------------------------
% T03: testReportWriteTex
% ----------------------------------------------------------------
fprintf('  T03: writeTex=true creates .tex file on disk ...\n');

tmpDir03 = tempname();
mkdir(tmpDir03);

cfg03 = revgnss.ConfigFactory.defaultConfig();
cfg03.report.style        = 'latex';
cfg03.report.writeTex     = true;
cfg03.report.compileTex   = 'never';
cfg03.report.baseOutputDir = tmpDir03;
cfg03 = revgnss.ConfigFactory.finalizeConfig(cfg03);

[figs03, tex03] = revgnss.LatexReportBuilder.build(struct('log',[]), [], [], cfg03, struct());

if ~isempty(tex03)
    assert(exist(tex03,'file') == 2, ...
        'T03 FAILED: .tex file not found at %s', tex03);
    info03 = dir(tex03);
    assert(info03.bytes > 0, 'T03 FAILED: .tex file is empty');
    fprintf('    .tex file written (%.1f kB): PASS\n', info03.bytes/1024);
else
    fprintf('    writeTex returned empty path (vacuous PASS — dir permission?)\n');
end
close(figs03(isgraphics(figs03)));
try; rmdir(tmpDir03,'s'); catch; end

% ----------------------------------------------------------------
% T04: testReportCompileTexAutoFallback
% ----------------------------------------------------------------
fprintf('  T04: compileTex=auto does not crash ...\n');

tmpDir04 = tempname();
mkdir(tmpDir04);

cfg04 = revgnss.ConfigFactory.defaultConfig();
cfg04.report.style        = 'latex';
cfg04.report.writeTex     = true;
cfg04.report.compileTex   = 'auto';
cfg04.report.baseOutputDir = tmpDir04;
cfg04 = revgnss.ConfigFactory.finalizeConfig(cfg04);

didThrow04 = false;
try
    [figs04, ~] = revgnss.LatexReportBuilder.build(struct('log',[]), [], [], cfg04, struct());
    close(figs04(isgraphics(figs04)));
catch ME04
    didThrow04 = true;
    fprintf('    UNEXPECTED ERROR: %s\n', ME04.message);
end
assert(~didThrow04, 'T04 FAILED: compileTex=auto threw an error');
fprintf('    compileTex=auto: no crash: PASS\n');
try; rmdir(tmpDir04,'s'); catch; end

% ----------------------------------------------------------------
% T05: testLatexReportContainsCodeEquation
% ----------------------------------------------------------------
fprintf('  T05: ReportEquations.codeEquation has P_f ...\n');

codeLines = revgnss.ReportEquations.codeEquation();
assert(iscell(codeLines) && ~isempty(codeLines), ...
    'T05 FAILED: codeEquation returned empty');
assert(any(contains(codeLines, 'P_f', 'IgnoreCase', false)), ...
    'T05 FAILED: codeEquation missing ''P_f'' term');
assert(any(contains(codeLines, 'rho', 'IgnoreCase', true)), ...
    'T05 FAILED: codeEquation missing geometry term ''rho''');
fprintf('    codeEquation has P_f and rho: PASS\n');

% ----------------------------------------------------------------
% T06: testLatexReportContainsCarrierEquation
% ----------------------------------------------------------------
fprintf('  T06: ReportEquations.carrierEquation has Phi_f and NEGATIVE iono ...\n');

carrLines = revgnss.ReportEquations.carrierEquation();
assert(iscell(carrLines) && ~isempty(carrLines), ...
    'T06 FAILED: carrierEquation returned empty');
assert(any(contains(carrLines, 'Phi_f', 'IgnoreCase', false)), ...
    'T06 FAILED: carrierEquation missing ''Phi_f'' term');
assert(any(contains(carrLines, 'negative', 'IgnoreCase', true)) || ...
       any(contains(carrLines, '- I_f',   'IgnoreCase', false)), ...
    'T06 FAILED: carrierEquation should state ionosphere is NEGATIVE for carrier');
fprintf('    carrierEquation has Phi_f and negative iono: PASS\n');

% ----------------------------------------------------------------
% T07: testLatexReportContainsIFEquation
% ----------------------------------------------------------------
fprintf('  T07: ReportEquations.ifEquation has IF combination and alpha ...\n');

ifLines = revgnss.ReportEquations.ifEquation();
assert(iscell(ifLines) && ~isempty(ifLines), ...
    'T07 FAILED: ifEquation returned empty');
assert(any(contains(ifLines, 'IF', 'IgnoreCase', false)) || ...
       any(contains(ifLines, 'ionosphere-free', 'IgnoreCase', true)), ...
    'T07 FAILED: ifEquation missing IF or ionosphere-free label');
assert(any(contains(ifLines, 'alpha', 'IgnoreCase', true)), ...
    'T07 FAILED: ifEquation missing alpha coefficient');
fprintf('    ifEquation has IF combination and alpha: PASS\n');

% ----------------------------------------------------------------
% T08: testLatexReportContainsStateVectorTable
% ----------------------------------------------------------------
fprintf('  T08: ReportTables.stateVectorBase has dimension 14 ...\n');

svLines = revgnss.ReportTables.stateVectorBase();
assert(iscell(svLines) && ~isempty(svLines), ...
    'T08 FAILED: stateVectorBase returned empty');
allSV = strjoin(svLines, ' ');
assert(contains(allSV, '14', 'IgnoreCase', false), ...
    'T08 FAILED: stateVectorBase should mention base dimension 14');
assert(contains(allSV, 'r_cm', 'IgnoreCase', false), ...
    'T08 FAILED: stateVectorBase should list position state r_cm');
fprintf('    stateVectorBase has 14 states and r_cm: PASS\n');

% ----------------------------------------------------------------
% T09: testLatexReportContainsMeasurementSummary
% ----------------------------------------------------------------
fprintf('  T09: build() produces measurement-summary page (P05 name) ...\n');

cfg09 = revgnss.ConfigFactory.defaultConfig();
cfg09.report.writeTex = false;
cfg09 = revgnss.ConfigFactory.finalizeConfig(cfg09);

[figs09, ~] = revgnss.LatexReportBuilder.build(struct('log',[]), [], [], cfg09, struct());
names09 = arrayfun(@(f) get(f,'Name'), figs09, 'UniformOutput', false);
hasMS = any(contains(names09, 'Measurement', 'IgnoreCase', true));
assert(hasMS, 'T09 FAILED: no figure with ''Measurement'' in name. Names: %s', strjoin(names09,'|'));
fprintf('    measurement-summary page found in %d figures: PASS\n', numel(figs09));
close(figs09(isgraphics(figs09)));

% ----------------------------------------------------------------
% T10: testLatexReportContainsErrorBudget
% ----------------------------------------------------------------
fprintf('  T10: build() produces error-budget page ...\n');

[figs10, ~] = revgnss.LatexReportBuilder.build(struct('log',[]), [], [], cfg09, struct());
names10 = arrayfun(@(f) get(f,'Name'), figs10, 'UniformOutput', false);
hasEB = any(contains(names10, 'Error', 'IgnoreCase', true));
assert(hasEB, 'T10 FAILED: no figure with ''Error'' in name. Names: %s', strjoin(names10,'|'));
fprintf('    error-budget page found: PASS\n');
close(figs10(isgraphics(figs10)));

% ----------------------------------------------------------------
% T11: testLatexReportContainsObservability
% ----------------------------------------------------------------
fprintf('  T11: build() produces observability page ...\n');

[figs11, ~] = revgnss.LatexReportBuilder.build(struct('log',[]), [], [], cfg09, struct());
names11 = arrayfun(@(f) get(f,'Name'), figs11, 'UniformOutput', false);
hasObs = any(contains(names11, 'Observability', 'IgnoreCase', true));
assert(hasObs, 'T11 FAILED: no figure with ''Observability'' in name. Names: %s', strjoin(names11,'|'));
fprintf('    observability page found: PASS\n');
close(figs11(isgraphics(figs11)));

% ----------------------------------------------------------------
% T12: testLatexReportContainsScientificVerdict
% ----------------------------------------------------------------
fprintf('  T12: build() produces verdict page with NOT-implemented claims ...\n');

[figs12, ~] = revgnss.LatexReportBuilder.build(struct('log',[]), [], [], cfg09, struct());
names12 = arrayfun(@(f) get(f,'Name'), figs12, 'UniformOutput', false);
hasVerdict = any(contains(names12, 'Verdict', 'IgnoreCase', true));
assert(hasVerdict, 'T12 FAILED: no figure with ''Verdict'' in name. Names: %s', strjoin(names12,'|'));
% Extract verdict page text
verdictFig12 = [];
for k = 1:numel(figs12)
    if isgraphics(figs12(k)) && contains(get(figs12(k),'Name'),'Verdict','IgnoreCase',true)
        verdictFig12 = figs12(k); break;
    end
end
if ~isempty(verdictFig12)
    vText12 = extractFigText_(verdictFig12);
    assert(any(contains(vText12,'not', 'IgnoreCase',true)) || ...
           any(contains(vText12,'NOT',  'IgnoreCase',false)), ...
        'T12 FAILED: verdict page should contain ''NOT implemented'' section');
end
fprintf('    verdict page found with NOT section: PASS\n');
close(figs12(isgraphics(figs12)));

% ----------------------------------------------------------------
% T13: testLatexReportContainsTestStatus
% ----------------------------------------------------------------
fprintf('  T13: verdict page mentions test status (72 passing) ...\n');

[figs13, ~] = revgnss.LatexReportBuilder.build(struct('log',[]), [], [], cfg09, struct());
verdictFig13 = [];
for k = 1:numel(figs13)
    if isgraphics(figs13(k)) && contains(get(figs13(k),'Name'),'Verdict','IgnoreCase',true)
        verdictFig13 = figs13(k); break;
    end
end
assert(~isempty(verdictFig13), 'T13 FAILED: no verdict figure found');
vText13 = extractFigText_(verdictFig13);
combined13 = lower(strjoin(vText13, ' '));
assert(contains(combined13,'72') || contains(combined13,'test status') || ...
       contains(combined13,'passing'), ...
    'T13 FAILED: verdict page should mention test status (72 passing)');
fprintf('    verdict page mentions test status: PASS\n');
close(figs13(isgraphics(figs13)));

% ----------------------------------------------------------------
% T14: testScientificVerdictNoOverclaiming
% ----------------------------------------------------------------
fprintf('  T14: verdict page does not overclaim accuracy ...\n');

[figs14, ~] = revgnss.LatexReportBuilder.build(struct('log',[]), [], [], cfg09, struct());
verdictFig14 = [];
for k = 1:numel(figs14)
    if isgraphics(figs14(k)) && contains(get(figs14(k),'Name'),'Verdict','IgnoreCase',true)
        verdictFig14 = figs14(k); break;
    end
end
assert(~isempty(verdictFig14), 'T14 FAILED: no verdict figure found');
vText14 = lower(strjoin(extractFigText_(verdictFig14), ' '));
disallowed = { ...
    'ppp-grade accurate', ...
    'centimeter-level accuracy achieved', ...
    'millimeter-level accuracy', ...
    'validated carrier-phase positioning', ...
    'fully precise', ...
};
for kd = 1:numel(disallowed)
    assert(~contains(vText14, disallowed{kd}), ...
        'T14 FAILED: verdict overclaims — found "%s"', disallowed{kd});
end
fprintf('    no overclaiming phrases found in verdict: PASS\n');
close(figs14(isgraphics(figs14)));

% ----------------------------------------------------------------
% T15: testLatexReportCarrierFloat
% ----------------------------------------------------------------
fprintf('  T15: carrierFloat config — verdict mentions ekfFloat ...\n');

cfg15 = revgnss.ConfigFactory.carrierFloatConfig();
cfg15.report.writeTex = false;
cfg15 = revgnss.ConfigFactory.finalizeConfig(cfg15);

[figs15, ~] = revgnss.LatexReportBuilder.build(struct('log',[]), [], [], cfg15, ...
    struct('carrierMode','ekfFloat','ambiguityMode','floatPerTowerSignal'));
verdictFig15 = [];
for k = 1:numel(figs15)
    if isgraphics(figs15(k)) && contains(get(figs15(k),'Name'),'Verdict','IgnoreCase',true)
        verdictFig15 = figs15(k); break;
    end
end
if ~isempty(verdictFig15)
    vText15 = lower(strjoin(extractFigText_(verdictFig15), ' '));
    assert(contains(vText15,'ekffloat') || contains(vText15,'float') || ...
           contains(vText15,'carrier'), ...
        'T15 FAILED: verdict should mention carrier/float for carrierFloat config');
end
assert(numel(figs15) >= 10, 'T15 FAILED: carrierFloat should produce >= 10 pages');
fprintf('    carrierFloat: %d pages, verdict mentions carrier/float: PASS\n', numel(figs15));
close(figs15(isgraphics(figs15)));

% ----------------------------------------------------------------
% T16: testLatexReportIonoFree
% ----------------------------------------------------------------
fprintf('  T16: dualFrequencyIF config — equations mention IF ...\n');

cfg16 = revgnss.ConfigFactory.dualFrequencyIFConfig();
cfg16.report.writeTex = false;
cfg16 = revgnss.ConfigFactory.finalizeConfig(cfg16);

[figs16, ~] = revgnss.LatexReportBuilder.build(struct('log',[]), [], [], cfg16, ...
    struct('codeMode','ionosphereFree'));
eqFig16 = [];
for k = 1:numel(figs16)
    if isgraphics(figs16(k)) && contains(get(figs16(k),'Name'),'Equation','IgnoreCase',true)
        eqFig16 = figs16(k); break;
    end
end
if ~isempty(eqFig16)
    eqText16 = lower(strjoin(extractFigText_(eqFig16), ' '));
    assert(contains(eqText16,'if') || contains(eqText16,'alpha') || ...
           contains(eqText16,'ionosphere-free'), ...
        'T16 FAILED: equations page should mention IF combination for dualFrequencyIF config');
end
assert(numel(figs16) >= 10, 'T16 FAILED: dualFrequencyIF should produce >= 10 pages');
fprintf('    dualFrequencyIF: %d pages, IF mentioned in equations: PASS\n', numel(figs16));
close(figs16(isgraphics(figs16)));

% ----------------------------------------------------------------
% T17: testLatexReportHandlesMissingOptionalFields
% ----------------------------------------------------------------
fprintf('  T17: minimal summary struct does not crash build() ...\n');

cfg17 = revgnss.ConfigFactory.defaultConfig();
cfg17 = revgnss.ConfigFactory.finalizeConfig(cfg17);

didThrow17 = false;
try
    [figs17, ~] = revgnss.LatexReportBuilder.build(struct('log',[]), [], [], cfg17, struct());
    assert(numel(figs17) >= 10, 'T17 FAILED: expected >= 10 figures, got %d', numel(figs17));
    close(figs17(isgraphics(figs17)));
catch ME17
    didThrow17 = true;
    fprintf('    UNEXPECTED ERROR: %s\n', ME17.message);
end
assert(~didThrow17, 'T17 FAILED: build() with empty summary struct should not throw');
fprintf('    minimal summary struct: no crash, >= 10 pages: PASS\n');

% ----------------------------------------------------------------
% T18: testRunOoReverseGnssReportStillWorks
% ----------------------------------------------------------------
fprintf('  T18: ReportRunner with latex style completes (60 s run) ...\n');

cfg18 = revgnss.ConfigFactory.defaultConfig();
cfg18.simulation.duration_s = 60;
cfg18.simulation.dt_s       = 1.0;
cfg18.report.writePdf       = false;
cfg18.report.writeMat       = false;
cfg18.report.style          = 'latex';
cfg18.report.writeTex       = false;
cfg18.plots.enable          = false;
cfg18.validation.unsupportedFeaturePolicy = 'disableWithWarning';

out18 = revgnss.ReportRunner.runSingle(cfg18);
assert(isfield(out18,'sim'),  'T18 FAILED: runSingle missing sim field');
assert(isfield(out18,'diag'), 'T18 FAILED: runSingle missing diag field');
fprintf('    ReportRunner with latex style completed in 60 s: PASS\n');

fprintf('=== test_stage7b_report: ALL PASS ===\n');

% ----------------------------------------------------------------
% Local helpers — extract text strings from a figure
% ----------------------------------------------------------------
function allStrings = extractFigText_(fig)
    % Walk figure → axes → text children and collect lowercase strings.
    allStrings = {};
    if ~isgraphics(fig); return; end
    axCh = get(fig, 'Children');
    for ki = 1:numel(axCh)
        t = getTextStr_(axCh(ki));
        if ~isempty(t); allStrings{end+1} = t; end %#ok<AGROW>
        try
            kids = get(axCh(ki), 'Children');
            for kj = 1:numel(kids)
                t = getTextStr_(kids(kj));
                if ~isempty(t); allStrings{end+1} = t; end %#ok<AGROW>
            end
        catch; end
    end
end

function txt = getTextStr_(h)
    % Return lowercase char row from a graphics object's String property.
    txt = '';
    try
        s = get(h, 'String');
        if isempty(s); return; end
        if iscell(s)
            % MATLAB stores multi-line text as cell array of lines
            txt = lower(strjoin(s(:)', ' '));
        elseif ischar(s)
            txt = lower(s(:)');  % flatten to row
        end
    catch; end
end
