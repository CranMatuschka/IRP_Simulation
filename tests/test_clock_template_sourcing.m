% test_clock_template_sourcing  ONE oscillator table, extensible and overridable as DATA.
%
% REWRITTEN 2026-08-10. This test used to gate cfg.clock.templateSource, the selector
% between a 'legacy' and a 'jowTable2p1' h-coefficient table. Both the selector and the
% second table are gone, and the reason is worth recording: the "jowTable2p1" table was
% not the sourced table it claimed to be. Of its four classes only CESIUM1 actually
% carried Winkel's values; OCXO took one of three coefficients from the source; TCXO and
% RUBIDIUM were unchanged legacy numbers under comments reading "Aligned to JOW Table 2.1"
% -- which is why those two resolved BYTE-IDENTICALLY in both tables and any ladder rung
% sweeping the selector on them measured nothing at all.
%
% What is gated now:
%   A  the single table carries Winkel (2003) Table 2.1 EXACTLY, all eight classes
%   B  an unknown oscillator ERRORS instead of silently becoming OCXO
%   C  a NEW oscillator can be added purely as data, with no source edit
%   D  a custom entry OVERRIDES a built-in of the same name
%   E  the removed selector is rejected loudly, not ignored
%   F  the documented back-compat aliases still resolve

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));
addpath(fullfile(thisDir, '..', 'config'));
addpath(fullfile(thisDir, '..', 'config', 'internal'));

fprintf('=== test_clock_template_sourcing ===\n');

% ================================================================
% Part A: the table IS the source, coefficient for coefficient
% ================================================================
fprintf('  A. single table matches Winkel (2003) Table 2.1 ...\n');
% Winkel, J. Ó. (2003). Modeling and simulating GNSS signal structures and receivers
%   [Doctoral dissertation, Universität der Bundeswehr München]. Table 2.1, p. 100.
% {name, h0, hMinus1, hMinus2} transcribed from the source, independently of the code.
SRC = { ...
    'QUARTZ',    2e-19,    7e-21,    2e-20   ; ...
    'TCXO',      1e-21,    1e-20,    2e-20   ; ...
    'OCXO1',     8e-20,    2e-21,    4e-23   ; ...
    'OCXO2',     2.51e-26, 2.51e-23, 2.51e-22; ...
    'RUBIDIUM1', 2e-20,    7e-24,    4e-29   ; ...
    'RUBIDIUM2', 1e-23,    1e-22,    1.3e-26 ; ...
    'CESIUM1',   1e-19,    1e-25,    2e-32   ; ...
    'CESIUM2',   2e-20,    7e-23,    4e-29   };

cat_ = revgnss.ConfigFactory.oscillatorCatalog_();
for r = 1:size(SRC,1)
    nm = SRC{r,1};
    assert(isfield(cat_, nm), 'Part A FAILED: catalogue is missing %s', nm);
    t = revgnss.ConfigFactory.getClockTemplate_(nm);
    assert(t.h0 == SRC{r,2} && t.hMinus1 == SRC{r,3} && t.hMinus2 == SRC{r,4}, ...
        ['Part A FAILED: %s is (%g, %g, %g) but the source says (%g, %g, %g). ' ...
         'The table must be the source, not a hand-tuned neighbour of it.'], ...
        nm, t.h0, t.hMinus1, t.hMinus2, SRC{r,2}, SRC{r,3}, SRC{r,4});
    % The source table has no white/flicker PHASE noise; those stay zero.
    assert(t.h2 == 0 && t.h1 == 0, 'Part A FAILED: %s has nonzero h2/h1', nm);
end
assert(isfield(cat_,'ZERO'), 'Part A FAILED: the explicit ZERO entry is missing');
z = revgnss.ConfigFactory.getClockTemplate_('ZERO');
assert(z.h0 == 0 && z.hMinus1 == 0 && z.hMinus2 == 0, 'Part A FAILED: ZERO is not zero');

% ================================================================
% Part B: an unknown name ERRORS
% ================================================================
fprintf('  B. unknown oscillator errors, never substitutes ...\n');
threw = false;
try
    revgnss.ConfigFactory.getClockTemplate_('AtomicLike');
catch me
    threw = strcmp(me.identifier, 'ConfigFactory:unknownOscillator');
end
assert(threw, ...
    ['Part B FAILED: an unknown oscillator was accepted. It used to WARN and silently ' ...
     'substitute OCXO, which is exactly how clockDiversityConfig ran OCXO on three ' ...
     'towers while reporting an atomic standard on one of them.']);

% ================================================================
% Part C: add a NEW oscillator as data
% ================================================================
fprintf('  C. a new oscillator is addable without touching source ...\n');
ov = struct('simulation', struct('duration_s', 600));
o = ov;
o.clock.customOscillators.MYMASER = struct('h0',1e-23,'hMinus1',3e-26,'hMinus2',5e-33);
o.asset.clockType = 'MYMASER';
c = resolveSimulationConfig('golden_baseline.json', o);
assert(strcmp(c.asset.clock.clockType,'MYMASER'), ...
    'Part C FAILED: the custom oscillator name did not reach the resolved clock');
assert(c.asset.clock.noiseCoeffs.h0 == 1e-23 && ...
       c.asset.clock.noiseCoeffs.hMinus1 == 3e-26 && ...
       c.asset.clock.noiseCoeffs.hMinus2 == 5e-33, ...
    'Part C FAILED: custom coefficients (%g,%g,%g) did not survive to the clock', ...
    c.asset.clock.noiseCoeffs.h0, c.asset.clock.noiseCoeffs.hMinus1, ...
    c.asset.clock.noiseCoeffs.hMinus2);
% It must also be usable on the GROUND segment, through the tower knob.
o2 = ov;
o2.clock.customOscillators.MYMASER = struct('h0',1e-23,'hMinus1',3e-26,'hMinus2',5e-33);
o2.clock.tower.clockType = 'MYMASER';
o2.clock.tower.deterministic = false;
c2 = resolveSimulationConfig('golden_baseline.json', o2);
for k = 1:numel(c2.towers)
    assert(c2.towers(k).clock.noiseCoeffs.h0 == 1e-23, ...
        'Part C FAILED: tower %d did not receive the custom oscillator', k);
end
% A custom entry missing a required coefficient must be rejected, not defaulted.
threw = false;
try
    o3 = ov;
    o3.clock.customOscillators.BAD = struct('h0',1e-20);   % no hMinus1 / hMinus2
    o3.asset.clockType = 'BAD';
    resolveSimulationConfig('golden_baseline.json', o3);
catch me
    threw = strcmp(me.identifier, 'ConfigFactory:incompleteOscillator');
end
assert(threw, 'Part C FAILED: an incomplete custom oscillator was silently completed');

% ================================================================
% Part D: a custom entry OVERRIDES a built-in of the same name
% ================================================================
fprintf('  D. a custom entry overrides a built-in ...\n');
o = ov;
o.clock.customOscillators.CESIUM1 = struct('h0',1e-26,'hMinus1',1e-28,'hMinus2',1e-30);
c = resolveSimulationConfig('golden_baseline.json', o);
assert(c.asset.clock.noiseCoeffs.h0 == 1e-26, ...
    ['Part D FAILED: the built-in CESIUM1 (h0 = 1e-19) beat the caller''s override ' ...
     '(got h0 = %g). Overriding a shipped oscillator is how config/ladder/clock/' ...
     'clk002_refLegacyHTable reproduces the retired optimistic numbers.'], ...
    c.asset.clock.noiseCoeffs.h0);
% ... and the shipped table is not mutated by it.
assert(revgnss.ConfigFactory.getClockTemplate_('CESIUM1').h0 == 1e-19, ...
    'Part D FAILED: an override leaked into the shipped catalogue');

% ================================================================
% Part E: the removed selector is rejected, not ignored
% ================================================================
fprintf('  E. templateSource is rejected loudly ...\n');
threw = false;
try
    o = ov; o.clock.templateSource = 'legacy';
    resolveSimulationConfig('golden_baseline.json', o);
catch
    threw = true;   % deepMergeConfig:unknownConfigPath or ConfigFactory:templateSourceRemoved
end
assert(threw, ...
    ['Part E FAILED: clock.templateSource was accepted. A removed knob that is silently ' ...
     'ignored is the inert-toggle defect this codebase keeps rediscovering.']);

% ================================================================
% Part F: documented aliases still resolve
% ================================================================
fprintf('  F. OCXO / RUBIDIUM aliases resolve ...\n');
a = revgnss.ConfigFactory.getClockTemplate_('OCXO');
b = revgnss.ConfigFactory.getClockTemplate_('OCXO2');
assert(isequal(a,b), 'Part F FAILED: ''OCXO'' does not resolve to OCXO2');
a = revgnss.ConfigFactory.getClockTemplate_('RUBIDIUM');
b = revgnss.ConfigFactory.getClockTemplate_('RUBIDIUM1');
assert(isequal(a,b), 'Part F FAILED: ''RUBIDIUM'' does not resolve to RUBIDIUM1');

fprintf('=== test_clock_template_sourcing PASSED ===\n');
