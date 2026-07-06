% test_stage13_dual_frequency_ionosphere
%
% Stage 13: dual-frequency and ionosphere-capable measurement architecture.
%
% T-P13a: Default config is single-frequency L1 with singleFrequency codeMode
%         and ionosphere.mode = 'off'. No numerical change from Stage 12.
% T-P13b: SignalDefinition.get('L1') returns valid frequency and wavelength.
% T-P13c: L2 ionosphere scale differs from L1 and follows 1/f^2.
% T-P13d: Code ionosphere sign is positive (group delay adds to range).
% T-P13e: Carrier ionosphere sign is negative (phase advance reduces range).
% T-P13f: IF coefficients satisfy c1+c2=1 and c1/f1^2 + c2/f2^2 = 0.
% T-P13g: codeMode=ionosphereFree with only one signal fails clearly.
% T-P13h: codeMode=ionosphereFree + txCodeBias.useInEKF=true fails (no per-signal delays).
% T-P13i: Carrier IF EKF request fails or stays diagnostic-only.
% T-P13j: Report includes ionosphere sign-convention documentation (Troposphere and ZWD Architecture subsection).

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_stage13_dual_frequency_ionosphere ===\n');

% ----------------------------------------------------------------
% T-P13a: Default config remains single-frequency L1
% ----------------------------------------------------------------
fprintf('  T-P13a: defaultConfig is single-frequency L1 with singleFrequency codeMode ...\n');

cfg_a = revgnss.ConfigFactory.defaultConfig();

assert(isfield(cfg_a,'signals') && isfield(cfg_a.signals,'enabled'), ...
    'T-P13a FAILED: cfg.signals.enabled missing');
assert(numel(cfg_a.signals.enabled) == 1 && strcmpi(cfg_a.signals.enabled{1},'L1'), ...
    'T-P13a FAILED: default signals.enabled must be {''L1''}');

assert(isfield(cfg_a,'measurements') && isfield(cfg_a.measurements,'codeMode'), ...
    'T-P13a FAILED: cfg.measurements.codeMode missing');
assert(strcmp(cfg_a.measurements.codeMode,'singleFrequency'), ...
    'T-P13a FAILED: default codeMode must be ''singleFrequency''');

assert(isfield(cfg_a,'ionosphere') && isfield(cfg_a.ionosphere,'mode'), ...
    'T-P13a FAILED: cfg.ionosphere.mode missing');
assert(strcmp(cfg_a.ionosphere.mode,'off'), ...
    'T-P13a FAILED: default ionosphere.mode must be ''off''');

assert(isfield(cfg_a,'signals') && isfield(cfg_a.signals,'primary'), ...
    'T-P13a FAILED: cfg.signals.primary missing');
assert(strcmp(cfg_a.signals.primary,'L1'), ...
    'T-P13a FAILED: signals.primary must be ''L1''');

fprintf('    PASS (singleFrequency L1, ionosphere.mode=off, primary=L1)\n');

% ----------------------------------------------------------------
% T-P13b: SignalDefinition.get('L1') returns valid freq and wavelength
% ----------------------------------------------------------------
fprintf('  T-P13b: SignalDefinition.get(''L1'') frequency and wavelength ...\n');

sig_L1 = revgnss.SignalDefinition.get('L1');

assert(isfield(sig_L1,'frequency_Hz'), 'T-P13b FAILED: missing frequency_Hz');
assert(isfield(sig_L1,'wavelength_m'),  'T-P13b FAILED: missing wavelength_m');
assert(isfield(sig_L1,'ionoScaleRelativeToL1'), 'T-P13b FAILED: missing ionoScaleRelativeToL1');

f_L1_expected = 1575.42e6;
assert(abs(sig_L1.frequency_Hz - f_L1_expected) < 1e3, ...
    'T-P13b FAILED: L1 frequency wrong (got %.4e, expected %.4e)', ...
    sig_L1.frequency_Hz, f_L1_expected);

c = 299792458;
lambda_expected = c / f_L1_expected;
assert(abs(sig_L1.wavelength_m - lambda_expected) < 1e-12, ...
    'T-P13b FAILED: L1 wavelength wrong (got %.6e, expected %.6e)', ...
    sig_L1.wavelength_m, lambda_expected);

assert(abs(sig_L1.ionoScaleRelativeToL1 - 1.0) < 1e-14, ...
    'T-P13b FAILED: L1 ionoScaleRelativeToL1 must be 1.0');

% Also test wavelength() convenience wrapper
lam_b = revgnss.SignalDefinition.wavelength('L1');
assert(abs(lam_b - lambda_expected) < 1e-12, 'T-P13b FAILED: wavelength() mismatch');

fprintf('    f=%.4e Hz  lambda=%.6f m  ionoScale=%.4f  PASS\n', ...
    sig_L1.frequency_Hz, sig_L1.wavelength_m, sig_L1.ionoScaleRelativeToL1);

% ----------------------------------------------------------------
% T-P13c: L2 iono scale follows 1/f^2 relative to L1
% ----------------------------------------------------------------
fprintf('  T-P13c: L2 ionosphere scale follows 1/f^2 relative to L1 ...\n');

sig_L2 = revgnss.SignalDefinition.get('L2');
f_L2 = sig_L2.frequency_Hz;

scale_L2_expected = (f_L1_expected / f_L2)^2;
scale_L2_got = revgnss.SignalDefinition.ionoScale('L2','L1');
assert(abs(scale_L2_got - scale_L2_expected) < 1e-12, ...
    'T-P13c FAILED: L2 iono scale wrong (got %.8f, expected %.8f)', ...
    scale_L2_got, scale_L2_expected);

assert(scale_L2_got > 1.0, 'T-P13c FAILED: L2 iono scale must be > 1 (L2 < L1 freq)');

% Check IonosphereModel.scaleForSignal agrees
scale_via_model = models.atmosphere.IonosphereModel.scaleForSignal('L2','L1');
assert(abs(scale_via_model - scale_L2_expected) < 1e-12, ...
    'T-P13c FAILED: IonosphereModel.scaleForSignal L2 mismatch');

% L5 should have even larger iono scale
scale_L5 = revgnss.SignalDefinition.ionoScale('L5','L1');
assert(scale_L5 > scale_L2_got, 'T-P13c FAILED: L5 iono scale must exceed L2 (L5 < L2 freq)');

fprintf('    L2 iono scale = %.6f (> 1.0 as expected)  L5 scale = %.6f  PASS\n', ...
    scale_L2_got, scale_L5);

% ----------------------------------------------------------------
% T-P13d: Code ionosphere sign is positive
% ----------------------------------------------------------------
fprintf('  T-P13d: Code ionosphere sign is positive (group delay) ...\n');

I_L1 = 5.0;  % 5 m L1 iono delay

% L1/L1: scale = 1, sign = positive
code_delay_L1 = models.atmosphere.IonosphereModel.applyCodeSign(I_L1, 'L1', 'L1');
assert(code_delay_L1 > 0, 'T-P13d FAILED: code iono delay on L1 must be positive');
assert(abs(code_delay_L1 - I_L1) < 1e-12, ...
    'T-P13d FAILED: code iono on L1 must equal I_L1 (scale=1)');

% L2/L1: scaled up by (f1/f2)^2 > 1
code_delay_L2 = models.atmosphere.IonosphereModel.applyCodeSign(I_L1, 'L2', 'L1');
assert(code_delay_L2 > I_L1, ...
    'T-P13d FAILED: L2 code iono delay must exceed L1 (larger scale)');

fprintf('    L1 code iono = +%.4f m  L2 code iono = +%.4f m  PASS\n', ...
    code_delay_L1, code_delay_L2);

% ----------------------------------------------------------------
% T-P13e: Carrier ionosphere sign is negative
% ----------------------------------------------------------------
fprintf('  T-P13e: Carrier ionosphere sign is negative (phase advance) ...\n');

carr_delay_L1 = models.atmosphere.IonosphereModel.applyCarrierSign(I_L1, 'L1', 'L1');
assert(carr_delay_L1 < 0, 'T-P13e FAILED: carrier iono delay on L1 must be negative');
assert(abs(carr_delay_L1 + I_L1) < 1e-12, ...
    'T-P13e FAILED: carrier iono on L1 must equal -I_L1');

% Carrier and code have opposite signs but same magnitude at L1
assert(abs(code_delay_L1 + carr_delay_L1) < 1e-12, ...
    'T-P13e FAILED: code + carrier iono must sum to zero at L1');

carr_delay_L2 = models.atmosphere.IonosphereModel.applyCarrierSign(I_L1, 'L2', 'L1');
assert(carr_delay_L2 < carr_delay_L1, ...
    'T-P13e FAILED: L2 carrier iono must be more negative than L1');

fprintf('    L1 carrier iono = %.4f m  L2 carrier iono = %.4f m  PASS\n', ...
    carr_delay_L1, carr_delay_L2);

% ----------------------------------------------------------------
% T-P13f: IF coefficients satisfy c1+c2=1 and c1/f1^2 + c2/f2^2 = 0
% ----------------------------------------------------------------
fprintf('  T-P13f: IF coefficients satisfy c1+c2=1 and c1/f1^2+c2/f2^2=0 ...\n');

f1 = 1575.42e6;
f2 = 1227.60e6;
[c1, c2] = models.atmosphere.IonosphereModel.ionoFreeCoefficients(f1, f2);

tol = 1e-12;
assert(abs(c1 + c2 - 1) < tol, ...
    'T-P13f FAILED: c1+c2 must equal 1 (got %.4e, err=%.2e)', c1+c2, abs(c1+c2-1));

ionomix = c1/f1^2 + c2/f2^2;
assert(abs(ionomix) < tol, ...
    'T-P13f FAILED: c1/f1^2 + c2/f2^2 must be 0 (got %.2e)', ionomix);

assert(c1 > 1, 'T-P13f FAILED: c1 must be > 1 for GPS L1/L2');
assert(c2 < 0, 'T-P13f FAILED: c2 must be < 0 for GPS L1/L2');

% Cross-check with IonoFreeCombination.coefficients (existing helper)
[alpha, beta] = revgnss.IonoFreeCombination.coefficients(f1, f2);
assert(abs(c1 - alpha) < tol, 'T-P13f FAILED: IonosphereModel c1 != IonoFreeCombination alpha');
assert(abs(c2 - beta)  < tol, 'T-P13f FAILED: IonosphereModel c2 != IonoFreeCombination beta');

fprintf('    c1=%.6f  c2=%.6f  c1+c2=%.1f  c1/f1^2+c2/f2^2=%.2e  PASS\n', ...
    c1, c2, c1+c2, ionomix);

% ----------------------------------------------------------------
% T-P13g: ionosphereFree codeMode with only one signal fails clearly
% ----------------------------------------------------------------
fprintf('  T-P13g: codeMode=ionosphereFree with one signal fails clearly ...\n');

cfg_g = revgnss.ConfigFactory.defaultConfig();
cfg_g.measurements.codeMode     = 'ionosphereFree';
cfg_g.signals.twoFrequency.enable = false;  % only L1

threw_g = false;
try
    revgnss.ConfigFactory.finalizeConfig(cfg_g);
catch ME_g
    threw_g = true;
    assert(contains(ME_g.message,'L1') || contains(ME_g.message,'requir') || ...
           contains(ME_g.message,'two') || contains(ME_g.message,'dual') || ...
           contains(ME_g.message,'freq'), ...
        'T-P13g FAILED: error message should mention frequency/L1/L2 (got: %s)', ME_g.message);
end
assert(threw_g, 'T-P13g FAILED: no error thrown for ionosphereFree with only L1');
fprintf('    PASS (ConfigFactory threw on ionosphereFree with single signal)\n');

% ----------------------------------------------------------------
% T-P13h: ionosphereFree + txCodeBias.useInEKF=true fails
% ----------------------------------------------------------------
fprintf('  T-P13h: codeMode=ionosphereFree + txCodeBias.useInEKF=true fails ...\n');

cfg_h = revgnss.ConfigFactory.defaultConfig();
cfg_h.measurements.codeMode              = 'ionosphereFree';
cfg_h.signals.twoFrequency.enable        = true;
cfg_h.hardware.txCodeBias.useInEKF       = true;
cfg_h.hardware.txCodeBias.mode           = 'perTowerL1';

threw_h = false;
try
    revgnss.ConfigFactory.finalizeConfig(cfg_h);
catch ME_h
    threw_h = true;
    assert(~isempty(ME_h.message), 'T-P13h FAILED: empty error message');
end
assert(threw_h, 'T-P13h FAILED: no error for ionosphereFree + txCodeBias.useInEKF=true');
fprintf('    PASS (error thrown: %s)\n', ME_h.identifier);

% ----------------------------------------------------------------
% T-P13i: Carrier IF EKF request fails or stays diagnostic-only
% ----------------------------------------------------------------
fprintf('  T-P13i: Carrier IF EKF request fails or stays diagnostic-only ...\n');

cfg_i = revgnss.ConfigFactory.defaultConfig();
cfg_i.measurements.carrierMode             = 'ekfFloat';
cfg_i.measurements.carrierCombinationMode  = 'ionosphereFree';
cfg_i.estimation.ambiguityMode             = 'floatPerTowerSignal';
cfg_i.estimation.ambiguity.initialSigma_m  = 100;
cfg_i.measurements.doppler.enable          = true;
cfg_i.measurements.doppler.useInEKF        = true;
cfg_i.physics.doppler.truth.enable         = true;
cfg_i.physics.doppler.model.enable         = true;

threw_i = false; disabled_i = false;
try
    cfg_i_fin = revgnss.ConfigFactory.finalizeConfig(cfg_i);
    % Allowed outcome: IF carrier downgraded to 'raw' with warning
    if isfield(cfg_i_fin,'measurements') && isfield(cfg_i_fin.measurements,'carrierCombinationMode')
        disabled_i = strcmp(cfg_i_fin.measurements.carrierCombinationMode,'raw');
    end
catch
    threw_i = true;
end
assert(threw_i || disabled_i, ...
    'T-P13i FAILED: carrier IF EKF must either throw or be downgraded to raw');

if threw_i
    fprintf('    PASS (error thrown for carrier IF EKF)\n');
else
    fprintf('    PASS (carrier IF downgraded to raw, IF EKF not active)\n');
end

% ----------------------------------------------------------------
% T-P13j: Report includes ionosphere sign-convention documentation
% (Stage 65+: 'Signal and Ionosphere Architecture' section was merged into
% Troposphere and ZWD Architecture; check for Iono sign convention instead.)
% ----------------------------------------------------------------
fprintf('  T-P13j: ClockExactReportBuilder .tex includes iono sign-convention documentation ...\n');

cfg_j = revgnss.ConfigFactory.defaultConfig();
cfg_j.report.style          = 'latex';
cfg_j.report.layout         = 'clockExact';
cfg_j.report.writeTex       = true;
cfg_j.report.compileTex     = 'never';
cfg_j.report.writePdf       = false;
cfg_j.report.writeMat       = false;
cfg_j.report.baseOutputDir  = fullfile(tempdir(), 'revgnss_test_stage13');

try
    diag_j = revgnss.Diagnostics(cfg_j);
catch
    diag_j = struct();
end
res_j = revgnss.ClockExactReportBuilder.build(diag_j, [], [], cfg_j, struct());
assert(isfield(res_j,'texPath') && isfile(res_j.texPath), ...
    'T-P13j FAILED: ClockExactReportBuilder did not produce a .tex file');

src_j = fileread(res_j.texPath);
assert(contains(src_j, 'Iono sign convention'), ...
    'T-P13j FAILED: .tex missing iono sign-convention documentation (Troposphere and ZWD Architecture)');

try; delete(res_j.texPath); catch; end

fprintf('    PASS (.tex contains iono sign-convention documentation)\n');

% ----------------------------------------------------------------
fprintf('=== test_stage13_dual_frequency_ionosphere: ALL PASS ===\n');
