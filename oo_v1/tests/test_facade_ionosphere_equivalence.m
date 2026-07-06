% test_facade_ionosphere_equivalence  Phase 5: the models/atmosphere/ionosphere façade
%   must produce output BIT-FOR-BIT identical to models.atmosphere.IonosphereModel. The façade is a
%   pure delegation layer, so equivalence is asserted with isequaln (no tolerance).
thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));                          % +revgnss
addpath(fullfile(thisDir, '..', 'models', 'atmosphere'));  % façade under test
fprintf('=== test_facade_ionosphere_equivalence ===\n');

signals = {'L1', 'L2'};
delays  = [0, 1.0, 5.0, -3.2, 12.7];
fL1 = 1575.42e6; fL2 = 1227.60e6;
nCheck = 0;

% ---- 'model' mode: code + carrier signed delay ----
for s = 1:numel(signals)
    for d = delays
        a = struct('delayPrimary_m', d, 'signalName', signals{s}, 'primaryName', 'L1');
        o = ionosphere('model', a);
        assert(isequaln(o.codeDelay_m,    models.atmosphere.IonosphereModel.applyCodeSign(d, signals{s}, 'L1')), ...
            'model.codeDelay mismatch (%s, %g)', signals{s}, d);
        assert(isequaln(o.carrierDelay_m, models.atmosphere.IonosphereModel.applyCarrierSign(d, signals{s}, 'L1')), ...
            'model.carrierDelay mismatch (%s, %g)', signals{s}, d);
        nCheck = nCheck + 2;
    end
end

% ---- 'diagnostic' mode: iono scale ----
for s = 1:numel(signals)
    o = ionosphere('diagnostic', struct('signalName', signals{s}, 'primaryName', 'L1'));
    assert(isequaln(o.scale, models.atmosphere.IonosphereModel.scaleForSignal(signals{s}, 'L1')), ...
        'diagnostic.scale mismatch (%s)', signals{s});
    nCheck = nCheck + 1;
end

% ---- 'covariance' mode: IF coefficients ----
o = ionosphere('covariance', struct('f1_Hz', fL1, 'f2_Hz', fL2));
[c1, c2] = models.atmosphere.IonosphereModel.ionoFreeCoefficients(fL1, fL2);
assert(isequaln(o.c1, c1) && isequaln(o.c2, c2), 'covariance coefficient mismatch');
nCheck = nCheck + 2;

% ---- mode guards ----
threw = false;
try; ionosphere('truth', struct()); catch ME; threw = strcmp(ME.identifier, 'ionosphere:truthNotHere'); end
assert(threw, 'truth mode must error with ionosphere:truthNotHere');
threw = false;
try; ionosphere('bogus', struct()); catch ME; threw = strcmp(ME.identifier, 'ionosphere:badMode'); end
assert(threw, 'unknown mode must error with ionosphere:badMode');

fprintf('  %d bit-for-bit equivalence checks + 2 mode guards: PASS\n', nCheck);
fprintf('=== test_facade_ionosphere_equivalence: PASS ===\n');
