% test_ground_clock_type_knob  cfg.clock.tower.{clockType,deterministic} is the only
% scenario-JSON route to the GROUND oscillator, and it must not be silently inert.
%
% WHY THIS TEST EXISTS. The config/ladder/clock axis sweeps the oscillator class on both
% segments. The space side was already reachable (cfg.asset.clockType). The ground side was
% not: cfg.towers is a STRUCT ARRAY, so a JSON "towers" key hits deepMergeConfig's
% struct-array branch and REPLACES the whole array, dropping every site's lat/lon/alt.
% Worse, even a per-tower clockType set in code was INERT, because masterConfig leaves every
% tower clock deterministic and a deterministic models.clocks.ClockModel returns identically
% zero bias -- no h-coefficient is ever read, so every oscillator class produced the same
% run. That is the same class of defect as the six feat rungs that disabled nothing (see
% resolveEnablePairsPostMerge). Parts C and D pin the inertness so it cannot come back
% unnoticed: if someone makes tower clocks stochastic by default, Part C fails loudly rather
% than silently re-scoring every past ground rung.

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));
addpath(fullfile(thisDir, '..', 'config'));
addpath(fullfile(thisDir, '..', 'config', 'internal'));

fprintf('=== test_ground_clock_type_knob ===\n');

ov = struct('simulation', struct('duration_s', 600));

% ================================================================
% Part A: the default is byte-identical -- the knob is an OVERRIDE, not a rewrite
% ================================================================
fprintf('  A. default leaves every tower alone ...\n');
base = masterConfig();
assert(isfield(base.clock, 'tower') && isfield(base.clock.tower, 'clockType') && ...
       isfield(base.clock.tower, 'deterministic'), ...
    'Part A FAILED: cfg.clock.tower.{clockType,deterministic} missing from masterConfig');
assert(isempty(base.clock.tower.clockType), ...
    'Part A FAILED: the default clock.tower.clockType must be '''' (inherit per-tower)');
assert(base.clock.tower.deterministic == true, ...
    'Part A FAILED: the default clock.tower.deterministic must be true (current behaviour)');

cGold = resolveSimulationConfig('golden_baseline.json', ov);
for k = 1:numel(cGold.towers)
    assert(strcmp(cGold.towers(k).clockType, 'OCXO'), ...
        'Part A FAILED: tower %d resolved to %s, not the historical OCXO', ...
        k, cGold.towers(k).clockType);
    assert(cGold.towers(k).clock.deterministic == true, ...
        'Part A FAILED: tower %d is no longer deterministic by default', k);
end

% An empty clockType must NOT flatten a deliberate per-tower mix.
cDiv = revgnss.ConfigFactory.clockDiversityConfig();
cDiv.clock.tower.clockType = '';
cDiv = revgnss.ConfigFactory.finalizeConfig(cDiv);
types = arrayfun(@(k) string(cDiv.towers(k).clockType), 1:numel(cDiv.towers));
assert(numel(unique(types)) > 1, ...
    'Part A FAILED: an empty clock.tower.clockType flattened clockDiversityConfig''s per-tower mix');

% ================================================================
% Part B: a non-empty override reaches EVERY tower, through the JSON merge
% ================================================================
fprintf('  B. override reaches every tower ...\n');
for spec = {{'RUBIDIUM', false}, {'CESIUM1', false}, {'OCXO', true}}
    want = spec{1}{1}; det = spec{1}{2};
    o = ov;
    o.clock.tower.clockType     = want;
    o.clock.tower.deterministic = det;
    c = resolveSimulationConfig('golden_baseline.json', o);
    for k = 1:numel(c.towers)
        assert(strcmp(c.towers(k).clockType, want), ...
            'Part B FAILED: tower %d is %s, expected %s', k, c.towers(k).clockType, want);
        assert(c.towers(k).clock.deterministic == det, ...
            'Part B FAILED: tower %d deterministic=%d, expected %d', ...
            k, c.towers(k).clock.deterministic, det);
    end
    % The h-coefficients must actually be REBUILT from the new type, not just relabelled.
    tmpl = revgnss.ConfigFactory.getClockTemplate_(want, c.clock.templateSource);
    assert(c.towers(1).clock.noiseCoeffs.h0 == tmpl.h0 && ...
           c.towers(1).clock.noiseCoeffs.hMinus2 == tmpl.hMinus2, ...
        'Part B FAILED: %s h-coefficients were not rebuilt (h0=%.3e hm2=%.3e vs template %.3e/%.3e)', ...
        want, c.towers(1).clock.noiseCoeffs.h0, c.towers(1).clock.noiseCoeffs.hMinus2, ...
        tmpl.h0, tmpl.hMinus2);
    % Per-tower seeds must stay distinct so five towers are not one common realisation.
    seeds = arrayfun(@(k) c.towers(k).clock.seed, 1:numel(c.towers));
    assert(numel(unique(seeds)) == numel(seeds), ...
        'Part B FAILED: tower clock seeds collapsed to %s', mat2str(seeds));
    % ... and the SPACE clock must not land on a tower seed.
    assert(~any(seeds == c.asset.clock.seed), ...
        'Part B FAILED: the spacecraft clock seed %d collides with a tower seed %s', ...
        c.asset.clock.seed, mat2str(seeds));
end

% Uniform ARCHITECTURE, distinct REALISATION. The intended design is one oscillator
% class per segment (every tower identical, the spacecraft free to differ) with a
% different RNG seed per clock -- so the h-coefficients and clockFactors must be equal
% across towers while the realisations must not be.
c = resolveSimulationConfig('clk012_spaceRubidiumGroundRubidium.json', ov);
h0s = arrayfun(@(k) c.towers(k).clock.noiseCoeffs.h0, 1:numel(c.towers));
assert(numel(uniquetol(h0s, 0)) == 1, ...
    'Part B FAILED: towers do not share one oscillator architecture (h0 = %s)', mat2str(h0s));
facs = arrayfun(@(k) jsonencode(c.towers(k).clockFactors), 1:numel(c.towers), ...
    'UniformOutput', false);
assert(numel(unique(facs)) == 1, ...
    'Part B FAILED: tower clockFactors differ across towers; the segment is not uniform');

% ================================================================
% Part B2: distinct seeds are distinct STREAMS, not just distinct labels
% ================================================================
fprintf('  B2. distinct seeds give independent realisations ...\n');
N = 1801;
B = zeros(numel(c.towers), N);
for k = 1:numel(c.towers)
    clkK = models.clocks.ClockModel(c.towers(k).clock);
    for i = 2:N
        clkK.step(1.0);
        B(k,i) = clkK.getBiasMeters();
    end
end
% Correlate the INCREMENTS, never the levels: a clock bias is a random walk, and the
% sample correlation of two INDEPENDENT random walks does not converge to zero (it is
% the classic spurious-regression statistic -- measured ~0.99 here on genuinely
% independent streams). The increments are the driving noise and must decorrelate.
D  = diff(B, 1, 2);
Rd = corrcoef(D');
off = abs(Rd(~eye(size(Rd))));
assert(max(off) < 0.2, ...
    ['Part B2 FAILED: max |increment correlation| between tower clock streams is %.3f. ' ...
     'Independent streams sit near +-%.3f; a value approaching 1 means two towers are ' ...
     'sharing one RNG realisation despite distinct seed values.'], ...
    max(off), 1.96/sqrt(size(D,2)));
% Seeds must actually be honoured: same seed reproduces, different seed does not.
assert(~any(arrayfun(@(a) any(arrayfun(@(b) a < b && isequal(B(a,:), B(b,:)), ...
    1:size(B,1))), 1:size(B,1))), ...
    'Part B2 FAILED: two tower clock realisations are byte-identical');

% ================================================================
% Part C: THE TRAP -- a deterministic tower clock is inert for EVERY class
% ================================================================
fprintf('  C. deterministic tower clock is inert (pinned) ...\n');
factors = struct('biasFactor',1,'freqFactor',1,'noiseFactor',1,'roleNoiseFactor',1, ...
                 'h2Factor',1,'h1Factor',1,'h0Factor',1,'hMinus1Factor',1,'hMinus2Factor',1);
scaling = struct('templateSource','jowTable2p1','globalBiasFactor',1, ...
                 'globalFreqFactor',1,'globalNoiseFactor',1);
biasFor = @(tt, det) i_runClock(tt, det, factors, scaling);

for tt = {'OCXO','RUBIDIUM','CESIUM1','TCXO'}
    b = biasFor(tt{1}, true);
    assert(max(abs(b)) == 0, ...
        ['Part C FAILED: a DETERMINISTIC %s tower clock produced |b|max = %.3e m. ' ...
         'It used to be identically zero, which is why the ground oscillator was inert ' ...
         'and why every clock rung sets clock.tower.deterministic=false. If this is an ' ...
         'intended change, every past ground rung must be re-run.'], tt{1}, max(abs(b)));
end

% ================================================================
% Part D: stochastic tower clocks separate the classes, in the expected order
% ================================================================
fprintf('  D. stochastic tower clocks separate the classes ...\n');
bO = biasFor('OCXO',     false);
bR = biasFor('RUBIDIUM', false);
bC = biasFor('CESIUM1',  false);
assert(rms(bO) > 0 && rms(bR) > 0 && rms(bC) > 0, ...
    'Part D FAILED: a stochastic tower clock still produced zero bias');
% JOW OCXO2's random walk (hMinus2 = 2.51e-22) dominates over an hour, so the crystal must
% be far worse free-running than either atomic standard. This is the free-running ordering;
% the SHORT-horizon ordering after the broadcast product is a different question and is what
% the config/ladder/clock ground rungs measure.
assert(rms(bO) > 100 * rms(bR) && rms(bO) > 100 * rms(bC), ...
    ['Part D FAILED: free-running OCXO rms %.3e m is not far worse than rubidium %.3e / ' ...
     'caesium %.3e -- the h-coefficients are not reaching the ClockModel'], ...
    rms(bO), rms(bR), rms(bC));

% ================================================================
% Part E: a typo is rejected, not silently substituted with OCXO
% ================================================================
fprintf('  E. typo is rejected ...\n');
threw = false;
try
    o = ov; o.clock.tower.clockType = 'RUBIDUIM';   % transposed letters
    resolveSimulationConfig('golden_baseline.json', o);
catch me
    threw = strcmp(me.identifier, 'validateMasterConfig:unknownModeValue');
end
assert(threw, ...
    ['Part E FAILED: a mistyped clock.tower.clockType was accepted. ' ...
     'getClockTemplate_ only WARNS and substitutes OCXO, so the run would silently ' ...
     'have used the wrong oscillator while the report named the typo.']);

fprintf('=== test_ground_clock_type_knob PASSED ===\n');

% ================================================================
function b = i_runClock(clockType, deterministic, factors, scaling)
% One tower clock, stepped over an hour at 1 s; returns the bias history in metres.
cc = revgnss.ConfigFactory.makeClockConfig(clockType, 201, factors, scaling);
cc.deterministic = deterministic;
cc.bias_s   = 0;
cc.fracFreq = 0;
clk = models.clocks.ClockModel(cc);
b = zeros(1, 3601);
for i = 2:3601
    clk.step(1.0);
    b(i) = clk.getBiasMeters();
end
end
