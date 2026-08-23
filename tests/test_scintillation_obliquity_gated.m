% test_scintillation_obliquity_gated
% The Conker S4 elevation scaling S4 = |A|*S4zen*sec^0.9 hardcoded a flat-Earth
% 1/sin(el) obliquity while cfg.effects.ionosphere.mappingModel selects 'thinShell'
% for the first-order slant delay that pierces the SAME shell. This gates the choice:
%   (A) absent knob and 'simpleSecant' reproduce the legacy expression EXACTLY;
%   (B) 'thinShell' matches MappingFunctions.ionosphere at the configured shell height;
%   (C) 'matchIonoMapping' follows cfg.effects.ionosphere.mappingModel;
%   (D) at zenith every option agrees (both obliquities are 1) -- the gate is elevation-only;
%   (E) at Stockholm's GEO elevation the legacy path CLAMPS and the thin-shell path does not.

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_scintillation_obliquity_gated ===\n');
fL1     = 1575.42e6;
elStock = deg2rad(22.58);    % Stockholm -> GEO at 23 deg E, the network minimum
S4zen   = 0.3;

legacySigma = @(el) 0.3 / sqrt(1 - 2*min(0.7, S4zen*(1/max(sin(el), sin(deg2rad(5))))^0.9)^2);

% ---------- (A) Default and explicit 'simpleSecant' are the legacy expression ----------
envDefault = models.errors.EnvironmentModel(obliqCfg([]), 1);            % knob absent
envSecant  = models.errors.EnvironmentModel(obliqCfg('simpleSecant'), 1);
for el = deg2rad([5.1, 10, 22.58, 35.76, 59.3, 90])
    sD = envDefault.getScintillationSigma(el, fL1, fL1);
    sS = envSecant.getScintillationSigma(el, fL1, fL1);
    assert(sD == legacySigma(el), ...
        'absent knob must be BIT-identical to legacy at %.2f deg (%.17g vs %.17g)', ...
        rad2deg(el), sD, legacySigma(el));
    assert(sS == sD, 'explicit simpleSecant must equal the default at %.2f deg', rad2deg(el));
end

% ---------- (B) 'thinShell' matches the shared mapping function ----------
envShell = models.errors.EnvironmentModel(obliqCfg('thinShell'), 1);
for el = deg2rad([10, 22.58, 35.76, 59.3, 90])
    sec  = models.atmosphere.MappingFunctions.ionosphere(el, 'thinShell', 350e3);
    want = 0.3 / sqrt(1 - 2*min(0.7, S4zen*sec^0.9)^2);
    got  = envShell.getScintillationSigma(el, fL1, fL1);
    assert(abs(got - want) < 1e-12, ...
        'thinShell sigma mismatch at %.2f deg: %.6f vs %.6f', rad2deg(el), got, want);
end

% ---------- (C) 'matchIonoMapping' follows cfg.effects.ionosphere.mappingModel ----------
cfgMatchShell = obliqCfg('matchIonoMapping');
cfgMatchShell.effects.ionosphere.mappingModel  = 'thinShell';
cfgMatchShell.effects.ionosphere.shellHeight_m = 350e3;
envMatchShell = models.errors.EnvironmentModel(cfgMatchShell, 1);
assert(abs(envMatchShell.getScintillationSigma(elStock, fL1, fL1) - ...
           envShell.getScintillationSigma(elStock, fL1, fL1)) < 1e-12, ...
    'matchIonoMapping under thinShell must equal explicit thinShell');

cfgMatchSecant = obliqCfg('matchIonoMapping');
cfgMatchSecant.effects.ionosphere.mappingModel = 'simpleSecant';
envMatchSecant = models.errors.EnvironmentModel(cfgMatchSecant, 1);
assert(envMatchSecant.getScintillationSigma(elStock, fL1, fL1) == legacySigma(elStock), ...
    'matchIonoMapping under simpleSecant must be BIT-identical to legacy');

% cfg.effects entirely absent -> falls back to the legacy secant, never errors
cfgNoEffects = obliqCfg('matchIonoMapping');
envNoEffects = models.errors.EnvironmentModel(cfgNoEffects, 1);
assert(envNoEffects.getScintillationSigma(elStock, fL1, fL1) == legacySigma(elStock), ...
    'matchIonoMapping with no cfg.effects must fall back to the legacy secant');

% ---------- (D) Zenith is a no-op: both obliquities are exactly 1 ----------
assert(abs(envShell.getScintillationSigma(pi/2, fL1, fL1) - ...
           envDefault.getScintillationSigma(pi/2, fL1, fL1)) < 1e-12, ...
    'the gate must not move the zenith sigma');

% ---------- (E) The clamp: legacy pins at Stockholm, thin-shell does not ----------
secLegacy = 1 / sin(elStock);
secShell  = models.atmosphere.MappingFunctions.ionosphere(elStock, 'thinShell', 350e3);
S4legacy  = S4zen * secLegacy^0.9;
S4shell   = S4zen * secShell^0.9;
assert(S4legacy > 0.7, 'legacy S4 at Stockholm must exceed the clamp, got %.4f', S4legacy);
assert(S4shell  < 0.7, 'thin-shell S4 at Stockholm must clear the clamp, got %.4f', S4shell);

sigLegacy = envDefault.getScintillationSigma(elStock, fL1, fL1);
sigShell  = envShell.getScintillationSigma(elStock, fL1, fL1);
assert(abs(sigLegacy - 0.3/sqrt(1 - 2*0.49)) < 1e-12, ...
    'clamped legacy sigma must be exactly 0.30/sqrt(0.02), got %.4f', sigLegacy);
assert(sigShell < sigLegacy/3, ...
    'clearing the clamp must cut sigma by more than 3x (%.4f vs %.4f)', sigShell, sigLegacy);

fprintf('  Stockholm %.2f deg: S4 %.4f (clamped) -> %.4f ; sigma %.4f m -> %.4f m (%.2fx)\n', ...
    rad2deg(elStock), S4legacy, S4shell, sigLegacy, sigShell, sigLegacy/sigShell);
fprintf('PASS test_scintillation_obliquity_gated\n');

% ---------------------------------------------------------------------------
function cfg = obliqCfg(obliquityModel)
    cfg = struct();
    cfg.towers = struct('id',1,'name','t','lat_rad',0,'lon_rad',0,'alt_m',0, ...
        'antennaOffset_enu_m',[0;0;0],'hardwareDelay_m',0);
    cfg.errors.troposphere.modelType = 'simpleMapped';
    ic = struct();
    ic.modelType = 'simpleMapped';
    sc = struct('enable', true, 'model', 'conker', 'S4zen', 0.3, ...
        'sigmaCodeL1_m', 0.3, 'frequencyExponent', 1.0, 'tau_s', 30);
    if ~isempty(obliquityModel)
        sc.obliquityModel = obliquityModel;
    end
    ic.scintillation = sc;
    cfg.errors.ionosphere = ic;
end
