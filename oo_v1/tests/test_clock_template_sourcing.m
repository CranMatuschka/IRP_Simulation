% test_clock_template_sourcing  WP4 acceptance test: clock h-coefficient templates can
% be sourced from the optimistic legacy table or the re-anchored JOW Table 2.1 table.
%
% The legacy OCXO random-walk-FM coefficient hMinus2 = 2e-29 (which dominates the Allan
% deviation at long averaging times and drives clock-bias variance growth between
% updates) is optimistic versus the project primary source JOW Table 2.1 (OCXO2
% hMinus2 = 2.51e-22). Legacy CESIUM1 h0 = 1e-26 behaves like an idealised maser rather
% than a caesium beam (JOW Cesium1 h0 = 1e-19). cfg.clock.templateSource selects the
% table; the default is 'legacy' (bit-identical reproducibility of past results).

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));
addpath(fullfile(thisDir, '..', 'config'));

fprintf('=== test_clock_template_sourcing ===\n');

% ================================================================
% Part A: template values (jow re-anchored; legacy unchanged)
% ================================================================
fprintf('  A. template h-coefficients ...\n');
oL = revgnss.ConfigFactory.getClockTemplate_('OCXO',    'legacy');
oJ = revgnss.ConfigFactory.getClockTemplate_('OCXO',    'jowTable2p1');
cL = revgnss.ConfigFactory.getClockTemplate_('CESIUM1', 'legacy');
cJ = revgnss.ConfigFactory.getClockTemplate_('CESIUM1', 'jowTable2p1');

% jow OCXO hMinus2 == the JOW value and no longer the optimistic 2e-29.
assert(oJ.hMinus2 == 2.51e-22, 'Part A FAILED: jow OCXO hMinus2=%.3e != 2.51e-22', oJ.hMinus2);
assert(oJ.hMinus2 >= 1e-23,    'Part A FAILED: jow OCXO hMinus2 still optimistic (%.3e)', oJ.hMinus2);
% jow CESIUM h0 re-anchored to a caesium beam.
assert(cJ.h0 >= 1e-20, 'Part A FAILED: jow CESIUM h0=%.3e < 1e-20', cJ.h0);
assert(cJ.h0 == 1e-19, 'Part A FAILED: jow CESIUM h0=%.3e != 1e-19 (JOW Cesium1)', cJ.h0);

% Reproducibility guard: legacy returns the ORIGINAL numbers exactly.
assert(oL.hMinus2 == 2e-29 && oL.h0 == 2e-25 && oL.hMinus1 == 7e-27, ...
    'Part A FAILED: legacy OCXO values changed');
assert(cL.h0 == 1e-26 && cL.hMinus1 == 1e-28 && cL.hMinus2 == 1e-30, ...
    'Part A FAILED: legacy CESIUM values changed');

% Invalid source -> namespaced error.
threw = false;
try; revgnss.ConfigFactory.getClockTemplate_('OCXO','bogus'); catch ME
    threw = contains(ME.identifier,'invalidTemplateSource'); end
assert(threw, 'Part A FAILED: invalid templateSource not rejected');

% Default remains legacy (backward compatible).
cfgDef = revgnss.ConfigFactory.defaultConfig();
assert(strcmp(cfgDef.clock.templateSource, 'legacy'), ...
    'Part A FAILED: default templateSource should be legacy, got %s', cfgDef.clock.templateSource);
fprintf('    OCXO hMinus2: legacy=%.2e jow=%.2e | CESIUM h0: legacy=%.2e jow=%.2e | default=legacy\n', ...
    oL.hMinus2, oJ.hMinus2, cL.h0, cJ.h0);
fprintf('    PASS\n');

% ================================================================
% Part B: theoretical Allan deviation of the re-anchored OCXO
% ================================================================
fprintf('  B. theoretical ADEV: re-anchored OCXO is less stable long-term ...\n');
tau = [1, 1000];
clkL = models.clocks.ClockModel(revgnss.ConfigFactory.makeClockConfig( ...
    'OCXO', 42, struct(), struct('templateSource','legacy')));
clkJ = models.clocks.ClockModel(revgnss.ConfigFactory.makeClockConfig( ...
    'OCXO', 42, struct(), struct('templateSource','jowTable2p1')));
[~, aL] = clkL.theoreticalAllanDeviation(tau);
[~, aJ] = clkJ.theoreticalAllanDeviation(tau);
assert(all(isfinite(aL)) && all(aL > 0) && all(isfinite(aJ)) && all(aJ > 0), ...
    'Part B FAILED: non-finite/non-positive ADEV');
% The re-anchor raises the long-term (RWFM-dominated) Allan deviation.
assert(aJ(2) > aL(2), 'Part B FAILED: jow OCXO not less stable at 1000 s (%.2e vs %.2e)', aJ(2), aL(2));
% ... to a conservative level, not the optimistic ~5e-13.
assert(aJ(2) >= 1e-10, 'Part B FAILED: jow OCXO ADEV@1000s=%.2e still optimistic', aJ(2));
fprintf('    OCXO ADEV @1000s: legacy=%.2e  jow=%.2e  (jow > legacy, conservative)\n', aL(2), aJ(2));
fprintf('    PASS\n');

% ================================================================
% Part C: WP-4 exposure. masterConfig exposes the realism string as a one-line knob;
% both frozen goldens PIN the idealised 'legacy' clock; the realistic CESIUM is noisier.
% ================================================================
fprintf('  C. masterConfig exposes templateSource; goldens pin legacy ...\n');
addpath(fullfile(thisDir, 'regression'));
assert(strcmp(masterConfig().clock.templateSource, 'legacy'), ...
    'Part C FAILED: masterConfig default templateSource must be ''legacy''.');
assert(strcmp(goldenScenarioConfig().clock.templateSource, 'legacy'), ...
    'Part C FAILED: single-antenna golden must pin templateSource=''legacy''.');
assert(strcmp(goldenHeadlineScenarioConfig().clock.templateSource, 'legacy'), ...
    'Part C FAILED: headline golden must pin templateSource=''legacy''.');

% Sensitivity: the realistic caesium receiver clock is noisier than legacy at tau=1 s.
cLl = revgnss.ConfigFactory.makeClockConfig('CESIUM1', 100, struct(), struct('templateSource','legacy'));
cLj = revgnss.ConfigFactory.makeClockConfig('CESIUM1', 100, struct(), struct('templateSource','jowTable2p1'));
clkCl = models.clocks.ClockModel(cLl);
clkCj = models.clocks.ClockModel(cLj);
[~, adCl] = clkCl.theoreticalAllanDeviation([1 1000]);
[~, adCj] = clkCj.theoreticalAllanDeviation([1 1000]);
assert(adCj(1) > adCl(1), ...
    'Part C FAILED: realistic CESIUM not noisier @1s (%.2e vs %.2e)', adCj(1), adCl(1));
fprintf('    masterConfig=legacy; goldens pinned; realistic CESIUM ADEV@1s=%.2e > legacy %.2e\n', ...
    adCj(1), adCl(1));
fprintf('    PASS\n');

fprintf('=== test_clock_template_sourcing: ALL PASS ===\n');
