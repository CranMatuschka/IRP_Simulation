% test_carrier_sigma_and_slip_threshold_follow_band
%   Carrier R and the cycle-slip threshold are physically specified in CYCLES but stored in
%   metres, so a fixed metre value silently rescales with the band. Measured across
%   config/ladder/freq/freq009..013 at the historical fixed values:
%       carrier sigma 5 mm    -> 0.026 cycles at GPS L1, 1.02 cycles at 61.25 GHz
%       slip threshold 0.10 m -> 0.53  cycles at GPS L1, 20.4 cycles at 61.25 GHz
%   At 1.02 cycles R asserts a whole wavelength of noise, which makes the ambiguity and the
%   noise indistinguishable; at 20.4 cycles the slip detector is effectively blind.
%
%   Two opt-in handles, both resolved in ConfigFactory.finalizeConfig once lambda is known,
%   with the metre field left canonical so no downstream reader changes:
%       cfg.measurements.carrier.sigma_cycles  -> sigma_m    = cycles * lambda
%       cfg.carrierSlip.threshold_cycles       -> threshold_m = cycles * lambda
%       cfg.carrierSlip.threshold_m = NaN      -> AUTO 5*sqrt(2)*sigma (the ISL idiom)
%
%   Guards:
%     1. DEFAULT UNCHANGED — masterConfig ships both *_cycles as NaN, so the resolved metre
%        values are exactly the historical ones and the frozen goldens cannot move;
%     2. sigma_cycles tracks the band, and sigma_m == cycles * lambda exactly;
%     3. threshold_cycles tracks the band likewise;
%     4. threshold_m = NaN auto-derives 5*sqrt(2)*sigma, and follows a derived sigma;
%     5. the runtime field CarrierTrackManager reads stays in sync with the canonical one;
%     6. an explicitly scenario-owned metre value still wins over the cycles form;
%     7. auto mode emits no spurious "canonical slip threshold wins" validation warning.

testDirectory  = fileparts(mfilename('fullpath'));
repositoryRoot = fileparts(testDirectory);
addpath(repositoryRoot);
addpath(fullfile(repositoryRoot, 'config'));
addpath(fullfile(repositoryRoot, 'config', 'internal'));

fprintf('=== test_carrier_sigma_and_slip_threshold_follow_band ===\n');

warningState = warning('query', 'ConfigFactory:rxCarrierBiasAbsorbed');
warning('off', 'ConfigFactory:rxCarrierBiasAbsorbed');
warningCleanup = onCleanup(@() warning(warningState.state, ...
    'ConfigFactory:rxCarrierBiasAbsorbed'));   %#ok<NASGU>

shortRun = struct('simulation', struct('duration_s', 600));

% ---- 1: default unchanged on every ladder file ----------------------------
% This is the golden-safety guard: opting in must be the ONLY way to move these. The
% historical values are NOT one constant -- realism's honest floor raises carrier sigma to
% 1 cm on the graded scenarios -- so assert against each file's OWN pre-resolution value.
% With both *_cycles unset, finalizeConfig must leave the metre fields exactly as the
% config chain handed them over.
defaultFiles = {'golden_baseline.json','golden_baseline_multi.json', ...
                'freq009_ism915_2450.json','freq013_ism24125_61250.json'};
for k = 1:numel(defaultFiles)
    [cfg, meta] = resolveSimulationConfig(defaultFiles{k}, shortRun);
    pre = meta.preResolutionConfig;
    preSigma = pre.measurements.carrier.sigma_m;
    preThr   = pre.carrierSlip.threshold_m;

    assert(cfg.measurements.carrier.sigma_m == preSigma, ...
        ['%s: carrier.sigma_m moved from %.17g m to %.17g m during finalizeConfig. ' ...
         'With sigma_cycles unset nothing may be derived, or the frozen goldens shift.'], ...
        defaultFiles{k}, preSigma, cfg.measurements.carrier.sigma_m);
    assert(cfg.carrierSlip.threshold_m == preThr, ...
        ['%s: carrierSlip.threshold_m moved from %.17g m to %.17g m during finalizeConfig.'], ...
        defaultFiles{k}, preThr, cfg.carrierSlip.threshold_m);
    fprintf('  %-30s defaults unmoved (sigma %.4f m, threshold %.3f m)  OK\n', ...
        defaultFiles{k}, cfg.measurements.carrier.sigma_m, cfg.carrierSlip.threshold_m);
end

% ---- 2+3: the cycles forms track the band ---------------------------------
% freq013 is the extreme rung: lambda 4.895 mm against GPS L1's 190.294 mm.
bandFiles = {'golden_baseline.json', 'freq011_unii5200_5800.json', 'freq013_ism24125_61250.json'};
SIG_CYC = 0.01;
THR_CYC = 0.5;
for k = 1:numel(bandFiles)
    cfg = resolveSimulationConfig(bandFiles{k}, struct( ...
        'simulation',   struct('duration_s', 600), ...
        'measurements', struct('carrier', struct('sigma_cycles', SIG_CYC, 'sigmaFloor_m', 0)), ...
        'carrierSlip',  struct('threshold_cycles', THR_CYC)));
    lam = cfg.signals.L1.lambda_m;

    % Floor explicitly zeroed here so this guard tests the BAND SCALING alone; the floor
    % itself is guarded in section 8.
    assert(cfg.measurements.carrier.sigma_m == SIG_CYC * lam, ...
        ['%s: sigma_cycles=%g at lambda %.6f mm must give sigma_m = %.9g m, got %.9g m.'], ...
        bandFiles{k}, SIG_CYC, lam*1e3, SIG_CYC*lam, cfg.measurements.carrier.sigma_m);
    assert(cfg.carrierSlip.threshold_m == THR_CYC * lam, ...
        ['%s: threshold_cycles=%g at lambda %.6f mm must give threshold_m = %.9g m, got %.9g m.'], ...
        bandFiles{k}, THR_CYC, lam*1e3, THR_CYC*lam, cfg.carrierSlip.threshold_m);

    % 5: the runtime field must agree with the canonical one.
    assert(cfg.measurements.carrier.slipDetection.threshold_m == cfg.carrierSlip.threshold_m, ...
        ['%s: slipDetection.threshold_m (%.9g) is out of sync with the canonical ' ...
         'carrierSlip.threshold_m (%.9g). CarrierTrackManager reads the former at runtime, ' ...
         'so a stale value silently governs slip detection.'], ...
        bandFiles{k}, cfg.measurements.carrier.slipDetection.threshold_m, ...
        cfg.carrierSlip.threshold_m);

    fprintf('  %-30s lambda %8.4f mm -> sigma %9.6f mm, threshold %9.5f mm  OK\n', ...
        bandFiles{k}, lam*1e3, cfg.measurements.carrier.sigma_m*1e3, ...
        cfg.carrierSlip.threshold_m*1e3);
end

% ---- 4: threshold_m = NaN auto-derives 5*sqrt(2)*sigma --------------------
cfgAuto = resolveSimulationConfig('golden_baseline.json', struct( ...
    'simulation',  struct('duration_s', 600), ...
    'carrierSlip', struct('threshold_m', NaN)));
% Chain off the sigma actually in force for this scenario, not a hard-coded constant.
expectedAuto = 5 * sqrt(2) * cfgAuto.measurements.carrier.sigma_m;
assert(cfgAuto.carrierSlip.threshold_m == expectedAuto, ...
    ['AUTO threshold must be 5*sqrt(2)*sigma = %.9g m, got %.9g m.'], ...
    expectedAuto, cfgAuto.carrierSlip.threshold_m);
assert(cfgAuto.measurements.carrier.slipDetection.threshold_m == expectedAuto, ...
    'AUTO threshold did not reach the runtime slipDetection field.');

% ...and it must follow a sigma that was itself derived from cycles, INCLUDING the floor --
% the auto threshold has to track the sigma actually in force, not the pre-floor cycles term.
cfgAuto2 = resolveSimulationConfig('freq013_ism24125_61250.json', struct( ...
    'simulation',   struct('duration_s', 600), ...
    'measurements', struct('carrier', struct('sigma_cycles', SIG_CYC)), ...
    'carrierSlip',  struct('threshold_m', NaN)));
lam13 = cfgAuto2.signals.L1.lambda_m;
expectedAuto2 = 5 * sqrt(2) * cfgAuto2.measurements.carrier.sigma_m;
assert(cfgAuto2.carrierSlip.threshold_m == expectedAuto2, ...
    ['AUTO threshold must chain off the sigma IN FORCE (%.9g m expected, got %.9g m); ' ...
     'if it does not, the two desynchronise exactly as the ISL path documents.'], ...
    expectedAuto2, cfgAuto2.carrierSlip.threshold_m);
% Guard the chain explicitly: the floored sigma must exceed the bare cycles term, so this
% assertion would fail if the auto path silently used the unfloored value.
assert(cfgAuto2.measurements.carrier.sigma_m > SIG_CYC * lam13, ...
    'The floor did not raise the freq013 sigma, so the chain guard above proves nothing.');
fprintf('  AUTO threshold: %.5f mm at L1, %.6f mm at 61.25 GHz w/ derived sigma  OK\n', ...
    cfgAuto.carrierSlip.threshold_m*1e3, cfgAuto2.carrierSlip.threshold_m*1e3);

% ---- 6: the cycles form wins over an owned metre value, and says so -------
% golden_baseline.json declares measurements.carrier.sigma_m = 0.01 and every ladder file
% inherits it via _extends, so a metre-wins rule would make the cycles knob inert on every
% scenario in the repo. Cycles wins; the override must be recorded, never silent.
PINNED_SIGMA = 0.012;
PINNED_THR   = 0.25;
% Floor zeroed so this guard tests PRECEDENCE alone (the floor is section 8's job).
cfgPin = resolveSimulationConfig('freq013_ism24125_61250.json', struct( ...
    'simulation',   struct('duration_s', 600), ...
    'measurements', struct('carrier', struct('sigma_m', PINNED_SIGMA, ...
                                             'sigma_cycles', SIG_CYC, 'sigmaFloor_m', 0)), ...
    'carrierSlip',  struct('threshold_m', PINNED_THR, 'threshold_cycles', THR_CYC)));
lamPin = cfgPin.signals.L1.lambda_m;
assert(cfgPin.measurements.carrier.sigma_m == SIG_CYC * lamPin, ...
    ['sigma_cycles must win over an owned sigma_m (%.9g m expected, got %.9g m); ' ...
     'otherwise the knob is inert on every scenario that inherits golden_baseline.'], ...
    SIG_CYC * lamPin, cfgPin.measurements.carrier.sigma_m);
assert(cfgPin.carrierSlip.threshold_m == THR_CYC * lamPin, ...
    ['threshold_cycles must win over an owned threshold_m (%.9g m expected, got %.9g m).'], ...
    THR_CYC * lamPin, cfgPin.carrierSlip.threshold_m);

pinWarn = '';
if isfield(cfgPin,'validation') && isfield(cfgPin.validation,'warnings')
    pinWarn = strjoin(cfgPin.validation.warnings, ' | ');
end
assert(contains(pinWarn, 'sigma_cycles') && contains(pinWarn, 'overrides'), ...
    ['Overriding a scenario-owned sigma_m must record a validation warning; ' ...
     'a silent override of a documented error budget is exactly the failure mode ' ...
     'this whole exercise started from. Warnings were: %s'], pinWarn);
assert(contains(pinWarn, 'threshold_cycles'), ...
    'Overriding a scenario-owned threshold_m must record a validation warning. Warnings: %s', ...
    pinWarn);
fprintf('  cycles form wins over owned metre values, override warned  OK\n');

% ---- 7: auto mode must not emit the canonical-sync warning ----------------
% x ~= NaN is always true, so an unguarded compare warns on every auto run.
warnText = '';
if isfield(cfgAuto,'validation') && isfield(cfgAuto.validation,'warnings')
    warnText = strjoin(cfgAuto.validation.warnings, ' | ');
end
assert(~contains(warnText, 'canonical slip threshold wins'), ...
    ['AUTO threshold emitted the canonical-sync warning, which is meaningless here: ' ...
     'NaN is "resolve me later", not a disagreement. Warnings were: %s'], warnText);
fprintf('  AUTO mode emits no spurious canonical-sync warning  OK\n');

% ---- 8: the non-dispersive floor, added in quadrature ---------------------
% A cycles-only sigma models the DISPERSIVE error. The non-dispersive part (troposphere,
% oscillator, antenna phase-centre stability, PCV residual) is constant in METRES, so a
% cycles-only figure understates it more and more as the band rises: 0.01 cycles at
% 61.25 GHz is 0.049 mm, 204x below the 1 cm real-world guard realismGradeConfig declares
% and GeoRealWorldScenarioGuard enforces. The floor must make that impossible.
floorFiles = {'golden_baseline.json', 'freq013_ism24125_61250.json'};
for k = 1:numel(floorFiles)
    cfgF = resolveSimulationConfig(floorFiles{k}, struct( ...
        'simulation',   struct('duration_s', 600), ...
        'measurements', struct('carrier', struct('sigma_cycles', SIG_CYC))));
    lamF   = cfgF.signals.L1.lambda_m;
    floorF = cfgF.measurement.sigmaFloor_m;          % inherited general floor
    expect = sqrt((SIG_CYC*lamF)^2 + floorF^2);

    assert(cfgF.measurements.carrier.sigma_m == expect, ...
        ['%s: expected sqrt((%g*%g)^2 + %g^2) = %.9g m, got %.9g m. The floor must be ' ...
         'added in quadrature, and must be inherited from measurement.sigmaFloor_m.'], ...
        floorFiles{k}, SIG_CYC, lamF, floorF, expect, cfgF.measurements.carrier.sigma_m);

    % The point of the floor: never below the general floor, at any band.
    assert(cfgF.measurements.carrier.sigma_m >= floorF, ...
        ['%s: derived carrier sigma %.9g m fell below the general floor %.9g m. ' ...
         'That silently undercuts the repository''s own realism policy.'], ...
        floorFiles{k}, cfgF.measurements.carrier.sigma_m, floorF);

    fprintf('  %-30s floor %6.3f mm -> sigma %8.5f mm (cycles term %8.5f mm)  OK\n', ...
        floorFiles{k}, floorF*1e3, cfgF.measurements.carrier.sigma_m*1e3, SIG_CYC*lamF*1e3);
end

% A scenario-stated carrier floor overrides the inherited general one.
CARRIER_FLOOR = 0.02;
cfgCF = resolveSimulationConfig('freq013_ism24125_61250.json', struct( ...
    'simulation',   struct('duration_s', 600), ...
    'measurements', struct('carrier', struct('sigma_cycles', SIG_CYC, ...
                                             'sigmaFloor_m', CARRIER_FLOOR))));
lamCF = cfgCF.signals.L1.lambda_m;
assert(cfgCF.measurements.carrier.sigma_m == sqrt((SIG_CYC*lamCF)^2 + CARRIER_FLOOR^2), ...
    'A carrier-specific sigmaFloor_m must override the inherited measurement.sigmaFloor_m.');

% And the floor must NOT touch the default path -- goldens depend on that.
cfgNoCyc = resolveSimulationConfig('golden_baseline.json', shortRun);
assert(cfgNoCyc.measurements.carrier.sigma_m == 0.01, ...
    ['With sigma_cycles unset the floor must not be applied at all (got %.9g m); ' ...
     'otherwise every existing scenario shifts.'], cfgNoCyc.measurements.carrier.sigma_m);
fprintf('  carrier-specific floor overrides; default path untouched by the floor  OK\n');

fprintf('PASS: test_carrier_sigma_and_slip_threshold_follow_band\n');
