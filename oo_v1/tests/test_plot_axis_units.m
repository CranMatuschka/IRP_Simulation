% test_plot_axis_units
% No report plot may render a scientific-notation axis multiplier ("x10^-3").
%
% Suppressing the multiplier alone is NOT the fix -- it would leave "0.000001" on the ticks.
% The data is rescaled into a sensible unit (m -> cm/mm/nm, s -> ms/us/ns/ps) and the unit is
% stated in the axis label.
%
% Proves:
%   T1  the unit ladder picks sane scales and never invents a prefix for an unknown unit
%   T2  rescaling is VALUE-PRESERVING: data x factor matches the new unit exactly
%   T3  a figure that WOULD show a multiplier does not after normalisation
%   T4  defensive bail-outs leave an axes untouched (no label, unknown unit, yyaxis) rather
%       than corrupting it -- a wrong rescale is far worse than an ugly axis
%   T5  every direct-export plot producer is hooked, not just the tryPlot_ chokepoint

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir, '..');
addpath(rootDir); addpath(fullfile(rootDir,'config'));

fprintf('=== test_plot_axis_units ===\n');
CE = revgnss.ClockExactReportBuilder;

% ----------------------------------------------------------------
fprintf('  T1: unit ladder ...\n');
cases = { 5e-3,'m',   1e3,'mm'; ...
          0.4,  'm',   1e2,'cm'; ...
          12,   'm',   1,  'm';  ...
          3e-10,'s',   1e12,'ps'; ...
          2e-7, 's',   1e9, 'ns'; ...
          0.5,  'deg', 1e3, 'mdeg'; ...
          7e-4, 'cycles', 1, 'cycles' };   % unknown unit -> no invented prefix
for k = 1:size(cases,1)
    [f, u] = CE.pickUnitScale_(cases{k,1}, cases{k,2});
    assert(f == cases{k,3} && strcmp(u, cases{k,4}), ...
        'T1 FAILED: %g [%s] -> factor %g [%s], expected %g [%s]', ...
        cases{k,1}, cases{k,2}, f, u, cases{k,3}, cases{k,4});
end
fprintf('    %d ladder cases incl. unknown-unit passthrough: PASS\n', size(cases,1));

% ----------------------------------------------------------------
fprintf('  T2/T3: normalisation rescales values and removes the multiplier ...\n');
f1 = figure('Visible','off');
ax = axes(f1); y = [1e-3 2e-3 3.5e-3];
plot(ax, 1:3, y); ylabel(ax, 'Position error [m]');
CE.normalizeAxisUnits_(f1);
ln = findall(ax,'Type','line');
assert(max(abs(ln.YData - y*1e3)) < 1e-12, ...
    'T2 FAILED: YData is %s, expected the mm-scaled %s', mat2str(ln.YData), mat2str(y*1e3));
assert(contains(ax.YLabel.String,'[mm]'), ...
    'T2 FAILED: label not updated to mm: "%s"', ax.YLabel.String);
assert(ax.YAxis.Exponent == 0, 'T3 FAILED: axis still carries exponent %d', ax.YAxis.Exponent);
fprintf('    1e-3 m -> mm, label "%s", exponent 0: PASS\n', ax.YLabel.String);
close(f1);

% ----------------------------------------------------------------
fprintf('  T4: defensive bail-outs leave the axes untouched ...\n');
% (a) no unit in the label
f2 = figure('Visible','off'); a2 = axes(f2); y2 = [1e-6 2e-6];
plot(a2, 1:2, y2); ylabel(a2, 'no unit here');
CE.normalizeAxisUnits_(f2);
l2 = findall(a2,'Type','line');
assert(isequal(l2.YData, y2), 'T4a FAILED: rescaled despite an unparseable unit');
close(f2);
% (b) unknown unit -> data untouched, but the multiplier is still suppressed
f3 = figure('Visible','off'); a3 = axes(f3); y3 = [1e-4 3e-4];
plot(a3, 1:2, y3); ylabel(a3, 'Ratio [cycles]');
CE.normalizeAxisUnits_(f3);
l3 = findall(a3,'Type','line');
assert(isequal(l3.YData, y3), 'T4b FAILED: invented a prefix for an unknown unit');
assert(a3.YAxis.Exponent == 0, 'T4b FAILED: multiplier not suppressed for the unknown unit');
close(f3);
% (c) yyaxis: two units on one axes, must never be rescaled
f4 = figure('Visible','off'); a4 = axes(f4);
yyaxis(a4,'left');  plot(a4, 1:3, [1e-3 2e-3 3e-3]); ylabel(a4,'A [m]');
yyaxis(a4,'right'); plot(a4, 1:3, [1 2 3]);
yyaxis(a4,'left');
lL = findall(a4,'Type','line');
before = arrayfun(@(h) sum(h.YData), lL);
CE.normalizeAxisUnits_(f4);
after  = arrayfun(@(h) sum(h.YData), findall(a4,'Type','line'));
assert(isequal(sort(before), sort(after)), ...
    'T4c FAILED: a yyaxis pair was rescaled; the two axes carry different units');
close(f4);
fprintf('    no-label / unknown-unit / yyaxis all bail safely: PASS\n');

% ----------------------------------------------------------------
fprintf('  T5: direct-export plot producers are hooked ...\n');
for f = {'FederatedSwarmReport','AtmosphereResidualPlots'}
    src = fileread(fullfile(rootDir,'+revgnss',[f{1} '.m']));
    nExp  = numel(regexp(src, 'exportgraphics\(', 'start'));
    nNorm = numel(regexp(src, 'normalizeAxisUnits_\(', 'start'));
    assert(nNorm >= nExp, ...
        ['T5 FAILED: %s has %d exportgraphics calls but only %d normalisations. Those figures ' ...
         'bypass tryPlot_, so they need the hook explicitly.'], f{1}, nExp, nNorm);
end
src = fileread(fullfile(rootDir,'+revgnss','ClockExactReportBuilder.m'));
assert(~isempty(regexp(src, 'normalizeAxisUnits_\(fig\)', 'once')), ...
    'T5 FAILED: tryPlot_ does not normalise; the main report plots would keep their multipliers');
fprintf('    tryPlot_ + both direct-export producers hooked: PASS\n');

fprintf('=== test_plot_axis_units: ALL PASS ===\n');
