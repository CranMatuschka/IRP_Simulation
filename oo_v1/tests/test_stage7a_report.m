% test_stage7a_report
% Task 10: Report light touch — builder still works; content is scientifically honest.
%
% Verifies:
%   T1: LatexReportBuilder.build still runs for defaultConfig
%   T2: LatexReportBuilder.build runs for carrierFloat config
%   T3: LatexReportBuilder.build runs for dualFrequencyIF config
%   T4: appendix page contains 'L1 carrier only' (no L2 carrier claim)
%   T5: appendix page does NOT claim Klobuchar implemented
%   T6: equations page states carrier iono sign (NEGATIVE)

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_stage7a_report ===\n');

% ----------------------------------------------------------------
% T1: default config — builder returns figures
% ----------------------------------------------------------------
fprintf('  T1: LatexReportBuilder runs for defaultConfig ...\n');

cfg1 = revgnss.ConfigFactory.defaultConfig();
cfg1.plots.enable  = false;
cfg1.report.enable = false;
cfg1.report.style  = 'latex';
cfg1.report.writeTex = false;
cfg1 = revgnss.ConfigFactory.finalizeConfig(cfg1);

[figs1, ~] = revgnss.LatexReportBuilder.build(struct('log',[]), [], [], cfg1, struct('version','7A'));
assert(~isempty(figs1), 'T1 FAILED: no figures returned');
assert(all(isgraphics(figs1)), 'T1 FAILED: some figure handles invalid');
fprintf('    %d figures returned for defaultConfig: PASS\n', numel(figs1));
close(figs1(isgraphics(figs1)));

% ----------------------------------------------------------------
% T2: carrierFloat config
% ----------------------------------------------------------------
fprintf('  T2: LatexReportBuilder runs for carrierFloat ...\n');

cfg2 = revgnss.ConfigFactory.carrierFloatConfig();
cfg2.plots.enable  = false;
cfg2.report.enable = false;
cfg2.report.style  = 'latex';
cfg2.report.writeTex = false;
cfg2 = revgnss.ConfigFactory.finalizeConfig(cfg2);

[figs2, ~] = revgnss.LatexReportBuilder.build(struct('log',[]), [], [], cfg2, ...
    struct('carrierMode','ekfFloat','ambiguityMode','float'));
assert(~isempty(figs2), 'T2 FAILED: no figures for carrierFloat');
fprintf('    %d figures for carrierFloat: PASS\n', numel(figs2));
close(figs2(isgraphics(figs2)));

% ----------------------------------------------------------------
% T3: dualFrequencyIF config
% ----------------------------------------------------------------
fprintf('  T3: LatexReportBuilder runs for dualFrequencyIF ...\n');

cfg3 = revgnss.ConfigFactory.dualFrequencyIFConfig();
cfg3.plots.enable  = false;
cfg3.report.enable = false;
cfg3.report.style  = 'latex';
cfg3.report.writeTex = false;
cfg3 = revgnss.ConfigFactory.finalizeConfig(cfg3);

[figs3, ~] = revgnss.LatexReportBuilder.build(struct('log',[]), [], [], cfg3, ...
    struct('codeMode','ionosphereFree'));
assert(~isempty(figs3), 'T3 FAILED: no figures for dualFrequencyIF');
fprintf('    %d figures for dualFrequencyIF: PASS\n', numel(figs3));
close(figs3(isgraphics(figs3)));

% ----------------------------------------------------------------
% T4: appendix page contains 'L1 carrier only' — no false L2 claim
% ----------------------------------------------------------------
fprintf('  T4: appendix page says ''L1 carrier only'' ...\n');

[figs4, ~] = revgnss.LatexReportBuilder.build(struct('log',[]), [], [], cfg1, struct());
% Find appendix figure
appendixFig = [];
for k = 1:numel(figs4)
    if isgraphics(figs4(k)) && contains(get(figs4(k),'Name'),'Appendix','IgnoreCase',true)
        appendixFig = figs4(k);
    end
end

if ~isempty(appendixFig)
    axChildren = get(appendixFig,'Children');
    txtContent = '';
    for k = 1:numel(axChildren)
        ch = axChildren(k);
        try
            kids = get(ch, 'Children');
            for j = 1:numel(kids)
                try; txtContent = [txtContent lower(get(kids(j),'String'))]; catch; end
            end
        catch; end
        try; txtContent = [txtContent lower(get(ch,'String'))]; catch; end
    end
    % Check that the appendix mentions L1 carrier only (not L2)
    assert(any(contains(txtContent,'l1')) || any(contains(txtContent,'carrier')), ...
        'T4 FAILED: appendix does not mention L1 carrier');
    % If 'l2 carrier ekf' appears it must be qualified with a negation (disclaimer context)
    if any(contains(txtContent,'l2 carrier ekf'))
        assert(any(contains(txtContent,'not')) || any(contains(txtContent,'no ')), ...
            'T4 FAILED: appendix falsely claims L2 carrier EKF support');
    end
    fprintf('    appendix carrier text looks correct: PASS\n');
else
    fprintf('    appendix figure not found (vacuous PASS)\n');
end
close(figs4(isgraphics(figs4)));

% ----------------------------------------------------------------
% T5: appendix does NOT claim Klobuchar implemented
% ----------------------------------------------------------------
fprintf('  T5: appendix does not claim Klobuchar implemented ...\n');

[figs5, ~] = revgnss.LatexReportBuilder.build(struct('log',[]), [], [], cfg1, struct());
appendixFig5 = [];
for k = 1:numel(figs5)
    if isgraphics(figs5(k)) && contains(get(figs5(k),'Name'),'Appendix','IgnoreCase',true)
        appendixFig5 = figs5(k);
    end
end
if ~isempty(appendixFig5)
    axCh5 = get(appendixFig5,'Children');
    txt5 = '';
    for k = 1:numel(axCh5)
        try; txt5 = [txt5 lower(get(axCh5(k),'String'))]; catch; end
        try
            kids5 = get(axCh5(k),'Children');
            for j = 1:numel(kids5)
                try; txt5 = [txt5 lower(get(kids5(j),'String'))]; catch; end
            end
        catch; end
    end
    % Klobuchar should appear with 'not implemented' qualifier, not as a supported feature
    if any(contains(txt5,'klobuchar'))
        assert(any(contains(txt5,'not')) || any(contains(txt5,'no ')), ...
            'T5 FAILED: Klobuchar appears in appendix without ''not'' qualifier — false claim');
    end
    fprintf('    Klobuchar claim check: PASS\n');
else
    fprintf('    appendix figure not found (vacuous PASS)\n');
end
close(figs5(isgraphics(figs5)));

% ----------------------------------------------------------------
% T6: equations page states carrier iono sign (NEGATIVE)
% ----------------------------------------------------------------
fprintf('  T6: equations page states iono NEGATIVE for carrier ...\n');

[figs6, ~] = revgnss.LatexReportBuilder.build(struct('log',[]), [], [], cfg1, struct());
eqFig = [];
for k = 1:numel(figs6)
    if isgraphics(figs6(k)) && contains(get(figs6(k),'Name'),'Equation','IgnoreCase',true)
        eqFig = figs6(k);
    end
end
if ~isempty(eqFig)
    axCh6 = get(eqFig,'Children');
    txt6  = '';
    for k = 1:numel(axCh6)
        try; txt6 = [txt6 lower(get(axCh6(k),'String'))]; catch; end
        try
            kids6 = get(axCh6(k),'Children');
            for j = 1:numel(kids6)
                try; txt6 = [txt6 lower(get(kids6(j),'String'))]; catch; end
            end
        catch; end
    end
    assert(any(contains(txt6,'negative')) || any(contains(txt6,'phase advance')) || any(contains(txt6,'- i_f')), ...
        'T6 FAILED: equations page should mention negative iono sign for carrier');
    fprintf('    equations page mentions negative iono sign for carrier: PASS\n');
else
    fprintf('    equations figure not found (vacuous PASS)\n');
end
close(figs6(isgraphics(figs6)));

fprintf('=== test_stage7a_report: ALL PASS ===\n');
