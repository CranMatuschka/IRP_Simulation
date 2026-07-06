% test_facade_troposphere_equivalence  Phase 5: the models/atmosphere/troposphere façade
%   must produce output BIT-FOR-BIT identical to revgnss.TroposphereModel (pure delegation).
thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));
addpath(fullfile(thisDir, '..', 'models', 'atmosphere'));
addpath(fullfile(thisDir, '..', 'config'));
fprintf('=== test_facade_troposphere_equivalence ===\n');

cfg = revgnss.ConfigFactory.defaultConfig();
n = 0;

% ---- 'model': mapping factor over an elevation sweep ----
for elDeg = [5, 10, 30, 45, 89]
    el = deg2rad(elDeg);
    o  = troposphere('model', struct('elevation_rad', el), cfg);
    assert(isequaln(o.mappingFactor, revgnss.TroposphereModel.mapping(el, cfg)), ...
        'mapping mismatch (%g deg)', elDeg);
    n = n + 1;
end

% ---- 'covariance': ZWD Gauss-Markov process parameters ----
o = troposphere('covariance', struct(), cfg);
[p, t, i] = revgnss.TroposphereModel.zwdProcessParams(cfg);
assert(isequaln(o.sigma_ss_m, p) && isequaln(o.tau_s, t) && isequaln(o.initialSigma_m, i), ...
    'zwd process params mismatch');
n = n + 3;

% ---- 'diagnostic': architecture struct + weak-observability note ----
elevs = deg2rad([10, 12, 14]);   % low diversity -> weak-observability note fires
o = troposphere('diagnostic', struct('stateMap', struct(), 'elevations_rad', elevs), cfg);
assert(isequaln(o.describe, revgnss.TroposphereModel.describe(cfg, struct())), 'describe mismatch');
assert(isequaln(o.weakObsNote, revgnss.TroposphereModel.weakObservabilityNote(elevs)), 'weakObsNote mismatch');
n = n + 2;

% ---- mode guards ----
threw = false;
try; troposphere('truth', struct(), cfg); catch ME; threw = strcmp(ME.identifier, 'troposphere:truthNotHere'); end
assert(threw, 'truth mode must error with troposphere:truthNotHere');
threw = false;
try; troposphere('bogus', struct(), cfg); catch ME; threw = strcmp(ME.identifier, 'troposphere:badMode'); end
assert(threw, 'unknown mode must error with troposphere:badMode');

fprintf('  %d bit-for-bit equivalence checks + 2 mode guards: PASS\n', n);
fprintf('=== test_facade_troposphere_equivalence: PASS ===\n');
