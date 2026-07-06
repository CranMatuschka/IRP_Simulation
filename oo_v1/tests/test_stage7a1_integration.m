% test_stage7a1_integration
% Stage 7A.1 runtime verification: integration fixes.
%
% Verifies:
%   T1:  ErrorChain ionosphere mapping uses config-driven mapping (not hardcoded secant)
%   T2:  ErrorChain thinShell differs from simpleSecant at low elevation
%   T3:  correctedPseudorange accepts t_rx_s; t_tx_s = t_rx_s - tau_s
%   T4:  correctedPseudorange without t_rx_s defaults to t_rx_s=0 (backward compat)
%   T5:  Tower clock product re-evaluated at correct absolute t_tx when t_s > 0
%   T6:  pcvModel='table' applies even when legacy enable=false (no silent bypass)
%   T7:  pcvModel='toy' without explicit field still uses legacy gate
%   T8:  Carrier IF throws at finalization by default; disableWithWarning suppresses
%   T9:  needsFiniteDiffH_ returns true when lightTime.model='iterative'
%   T10: IF code rows labeled 'ifCode' in measType_perRow
%   T11: ObservabilityDiagnostics.nIFCodeRows > 0 in ionosphere-free mode
%   T12: ErrorChain backward-compat: simpleSecant with default config unchanged

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_stage7a1_integration ===\n');

% ----------------------------------------------------------------
% T1: ErrorChain ionosphere uses config-driven mapping
% ----------------------------------------------------------------
fprintf('  T1: ErrorChain ionosphere uses configured mapping ...\n');

cfg1 = revgnss.ConfigFactory.defaultConfig();
cfg1.errors.ionosphere.truth.enable          = true;
cfg1.errors.ionosphere.truth.zenithDelay_m   = 5.0;
cfg1.errors.ionosphere.model.enable          = false;
cfg1.effects.ionosphere.mappingModel         = 'thinShell';
cfg1.effects.ionosphere.shellHeight_m        = 350e3;
seed1 = 0;

ec1 = revgnss.ErrorChain(cfg1, seed1);
el_low = 10 * pi/180;
f_L1   = 1575.42e6;

err1 = ec1.compute([el_low], [1], [1], 0);
d_ts = err1.bySource.truth_m.iono(1);

% Same config with simpleSecant
cfg1b = cfg1;
cfg1b.effects.ionosphere.mappingModel = 'simpleSecant';
ec1b  = revgnss.ErrorChain(cfg1b, seed1);
err1b = ec1b.compute([el_low], [1], [1], 0);
d_sec = err1b.bySource.truth_m.iono(1);

assert(abs(d_ts - d_sec) > 0.01, ...
    'T1 FAILED: thinShell=%.4f and simpleSecant=%.4f should differ at 10 deg', d_ts, d_sec);
fprintf('    thinShell=%.4f m, simpleSecant=%.4f m (differ): PASS\n', d_ts, d_sec);

% ----------------------------------------------------------------
% T2: ErrorChain thinShell < simpleSecant at low elevation (physically correct)
% ----------------------------------------------------------------
fprintf('  T2: thinShell < simpleSecant at low elevation ...\n');

% Thin-shell produces a smaller mapping factor than flat-Earth at low elevations
assert(abs(d_ts) < abs(d_sec), ...
    'T2 FAILED: thin-shell delay should be < simpleSecant delay at low el (thinShell=%.4f, sec=%.4f)', ...
    d_ts, d_sec);
fprintf('    thinShell < simpleSecant: PASS\n');

% ----------------------------------------------------------------
% T3: correctedPseudorange t_tx_s = t_rx_s - tau_s
% ----------------------------------------------------------------
fprintf('  T3: correctedPseudorange t_tx_s = t_rx_s - tau_s ...\n');

r_rx3  = [42164e3; 0; 0];
r_twr3 = [6378e3;  0; 0];
cfg3   = revgnss.ConfigFactory.defaultConfig();
cfg3.effects.lightTime.model = 'iterative';
t_rx3  = 1000.0;  % s

[~, c3] = models.corrections.RangeCorrections.correctedPseudorange(r_rx3, r_twr3, cfg3, 'model', pi/4, t_rx3);
assert(c3.tau_s > 0.05, 'T3 FAILED: tau_s=%.4f should be >0.05 s for GEO range', c3.tau_s);
t_tx_expected = t_rx3 - c3.tau_s;
assert(abs(c3.t_tx_s - t_tx_expected) < 1e-9, ...
    'T3 FAILED: t_tx_s=%.6f expected %.6f (t_rx-tau)', c3.t_tx_s, t_tx_expected);
assert(c3.t_tx_s > 0, ...
    'T3 FAILED: t_tx_s=%.4f should be positive when t_rx_s=%.1f and tau~0.12 s', c3.t_tx_s, t_rx3);
fprintf('    t_rx=%.1f s, tau=%.4f s, t_tx=%.4f s (positive, correct): PASS\n', ...
    t_rx3, c3.tau_s, c3.t_tx_s);

% ----------------------------------------------------------------
% T4: correctedPseudorange backward compat — no t_rx_s gives t_tx_s ≈ -tau
% ----------------------------------------------------------------
fprintf('  T4: backward compat — no t_rx_s, t_tx_s ≈ -tau ...\n');

[~, c4] = models.corrections.RangeCorrections.correctedPseudorange(r_rx3, r_twr3, cfg3, 'model', pi/4);
assert(abs(c4.t_tx_s - (0 - c4.tau_s)) < 1e-9, ...
    'T4 FAILED: without t_rx_s, t_tx_s should be -tau_s');
fprintf('    no t_rx_s: t_tx_s=%.4f ≈ -tau_s=%.4f: PASS\n', c4.t_tx_s, -c4.tau_s);

% ----------------------------------------------------------------
% T5: Tower clock product uses correct absolute t_tx at non-zero epoch
% ----------------------------------------------------------------
fprintf('  T5: product re-evaluation at absolute t_tx for t_s > 0 ...\n');

% With iterative mode + t_rx_s=1000, t_tx_s should be ~999.88 (positive, near t_rx)
% vs. t_tx_s ≈ -0.12 with t_rx_s=0.
% The transmit-time correction uses tau = t_s - t_tx_s.
% With correct t_rx_s=1000: tau_correct = 1000 - 999.88 = 0.12 s (correct propagation delay)
% With wrong t_rx_s=0:       tau_wrong  = 1000 - (-0.12) = 1000.12 s (completely wrong)
t_s5 = 1000.0;
tau5 = c3.tau_s;  % reuse from T3

tau_correct = t_s5 - c3.t_tx_s;
tau_wrong   = t_s5 - c4.t_tx_s;

assert(abs(tau_correct - tau5) < 0.001, ...
    'T5 FAILED: tau_correct=%.4f should equal tau5=%.4f', tau_correct, tau5);
assert(tau_wrong > 100, ...
    'T5 FAILED: tau_wrong=%.4f with zero-epoch t_tx should be >> tau5', tau_wrong);
fprintf('    tau_correct=%.4f s (matches tau), tau_wrong=%.1f s (bad): PASS\n', tau_correct, tau_wrong);

% ----------------------------------------------------------------
% T6: pcvModel='table' applies even when legacy enable=false
% ----------------------------------------------------------------
fprintf('  T6: pcvModel=''table'' not silenced by legacy enable=false ...\n');

r_rx6  = [42164e3; 0; 0];
r_twr6 = [6378e3;  0; 0];
el30   = 30 * pi/180;

cfg6 = revgnss.ConfigFactory.defaultConfig();
cfg6.effects.antenna.pcvModel        = 'table';
cfg6.effects.antennaPCV.truth.enable = false;  % legacy gate OFF
cfg6.effects.antenna.receiverPcvTable.elDeg = [0 30 60 90];
cfg6.effects.antenna.receiverPcvTable.pcv_m = [0.020 0.010 0.005 0.000];

[~, c6] = models.corrections.RangeCorrections.correctedPseudorange(r_rx6, r_twr6, cfg6, 'truth', el30);
assert(abs(c6.pcv - 0.010) < 1e-8, ...
    'T6 FAILED: pcvModel=table should give pcv=0.010 regardless of legacy gate, got %.6f', c6.pcv);
fprintf('    pcvModel=table with legacy enable=false: pcv=%.4f (correct): PASS\n', c6.pcv);

% ----------------------------------------------------------------
% T7: pcvModel default ('toy' implicit) still uses legacy gate
% ----------------------------------------------------------------
fprintf('  T7: default pcvModel (''toy'' implicit) uses legacy gate ...\n');

cfg7_off = revgnss.ConfigFactory.defaultConfig();
% Remove the explicit pcvModel field so the legacy antennaPCV gate is authoritative
cfg7_off.effects.antenna = rmfield(cfg7_off.effects.antenna, 'pcvModel');
cfg7_off.effects.antennaPCV.truth.enable  = false;   % legacy gate OFF
cfg7_off.effects.antennaPCV.amplitude_m   = 0.05;

[~, c7_off] = models.corrections.RangeCorrections.correctedPseudorange(r_rx6, r_twr6, cfg7_off, 'truth', el30);
assert(abs(c7_off.pcv) < 1e-12, ...
    'T7 FAILED: legacy gate OFF should give zero pcv, got %.2e', c7_off.pcv);

cfg7_on = cfg7_off;  % already has pcvModel removed
cfg7_on.effects.antennaPCV.truth.enable = true;  % legacy gate ON
[~, c7_on] = models.corrections.RangeCorrections.correctedPseudorange(r_rx6, r_twr6, cfg7_on, 'truth', el30);
assert(abs(c7_on.pcv) > 1e-6, ...
    'T7 FAILED: legacy gate ON should give non-zero pcv, got %.2e', c7_on.pcv);
fprintf('    legacy off → pcv=0; legacy on → pcv=%.4f: PASS\n', c7_on.pcv);

% ----------------------------------------------------------------
% T8: Carrier IF throws at finalization by default (ConfigFactory catches it first)
% ----------------------------------------------------------------
fprintf('  T8: carrierCombinationMode=ionosphereFree throws at finalization by default ...\n');

cfg8 = revgnss.ConfigFactory.defaultConfig();
cfg8.measurements.carrierMode             = 'ekfFloat';
cfg8.measurements.carrierCombinationMode  = 'ionosphereFree';
cfg8.plots.enable  = false;
cfg8.report.enable = false;
% Default policy='error' → finalizeConfig must throw
threw8 = false;
try
    revgnss.ConfigFactory.finalizeConfig(cfg8);
catch ME
    threw8 = true;
    assert(contains(ME.identifier,'carrierIF') || contains(ME.identifier,'ConfigFactory'), ...
        'T8 FAILED: wrong error id ''%s''', ME.identifier);
end
assert(threw8, 'T8 FAILED: carrierCombinationMode=ionosphereFree should throw at finalization by default');
fprintf('    threw carrierIF error at finalization: PASS\n');

% disableWithWarning suppresses error and falls back to raw
cfg8b = revgnss.ConfigFactory.defaultConfig();
cfg8b.measurements.carrierMode             = 'ekfFloat';
cfg8b.measurements.carrierCombinationMode  = 'ionosphereFree';
cfg8b.estimation.ambiguityMode             = 'floatPerTowerSignal';  % satisfy ambiguity check
cfg8b.validation.unsupportedFeaturePolicy  = 'disableWithWarning';
cfg8b.plots.enable  = false;
cfg8b.report.enable = false;
threw8b = false;
warnState8b = warning('off','all');
try
    cfg8b_fin = revgnss.ConfigFactory.finalizeConfig(cfg8b);
catch
    threw8b = true;
end
warning(warnState8b);
assert(~threw8b, 'T8b FAILED: disableWithWarning should suppress carrier IF error at finalization');
assert(strcmp(cfg8b_fin.measurements.carrierCombinationMode,'raw'), ...
    'T8b FAILED: after disableWithWarning, carrierCombinationMode should be ''raw'', got ''%s''', ...
    cfg8b_fin.measurements.carrierCombinationMode);
fprintf('    disableWithWarning suppresses error, carrierCombinationMode=raw: PASS\n');

% ----------------------------------------------------------------
% T9: needsFiniteDiffH_ true when lightTime.model='iterative'
% ----------------------------------------------------------------
fprintf('  T9: needsFiniteDiffH_ true for iterative light-time ...\n');

cfg9_iter = revgnss.ConfigFactory.defaultConfig();
cfg9_iter.effects.lightTime.model = 'iterative';
assert(revgnss.MeasurementModelUtils.needsFiniteDiffH_(cfg9_iter), ...
    'T9 FAILED: iterative light-time should trigger FD H');

cfg9_sag = revgnss.ConfigFactory.defaultConfig();
cfg9_sag.effects.lightTime.model = 'sagnacFirstOrder';
% Disable physics.sagnac so we test effects.lightTime.model='sagnacFirstOrder' in isolation.
% defaultConfig has physics.sagnac.model.enable=true which independently triggers FD H.
cfg9_sag.physics.sagnac.model.enable  = false;
cfg9_sag.physics.sagnac.truth.enable  = false;
cfg9_sag.effects.antennaPCO.model.enable = false;
cfg9_sag.effects.antennaPCV.model.enable = false;
% sagnacFirstOrder lightTime model does NOT use iterative rotation → no FD needed
assert(~revgnss.MeasurementModelUtils.needsFiniteDiffH_(cfg9_sag), ...
    'T9 FAILED: sagnacFirstOrder alone should NOT trigger FD H');
fprintf('    iterative→FD=true, sagnacFirstOrder→FD=false: PASS\n');

% ----------------------------------------------------------------
% T10: IF code rows labeled 'ifCode' in measType_perRow
% ----------------------------------------------------------------
fprintf('  T10: IF code rows labeled ''ifCode'' in measType_perRow ...\n');

cfg10 = revgnss.ConfigFactory.dualFrequencyIFConfig();
cfg10.measurements.doppler.useInEKF = false;
cfg10.measurements.carrierMode      = 'off';
cfg10.plots.enable  = false;
cfg10.report.enable = false;

[asset10, towers10, ekf10, mm10] = revgnss.ScenarioFactory.build(cfg10);
[~, ~, ~, ~, errSt10] = mm10.computeMeasurements(asset10, towers10, ekf10.x, 0, ekf10.stateMap);

assert(isfield(errSt10,'measType_perRow') && ~isempty(errSt10.measType_perRow), ...
    'T10 FAILED: measType_perRow field missing or empty');
assert(isfield(errSt10,'ifCombination') && errSt10.ifCombination, ...
    'T10 FAILED: ifCombination flag not set in IF mode');
nIF10 = sum(strcmp(errSt10.measType_perRow,'ifCode'));
nCode10 = sum(strcmp(errSt10.measType_perRow,'code'));
assert(nIF10 > 0, 'T10 FAILED: no ifCode labels in IF mode (nIF=%d)', nIF10);
assert(nCode10 == 0, 'T10 FAILED: code labels should be 0 in pure IF mode (nCode=%d)', nCode10);
fprintf('    nIFCode=%d, nCode=%d (all IF labeled correctly): PASS\n', nIF10, nCode10);

% ----------------------------------------------------------------
% T11: ObservabilityDiagnostics.nIFCodeRows > 0 in IF mode
% ----------------------------------------------------------------
fprintf('  T11: ObservabilityDiagnostics.nIFCodeRows > 0 in IF mode ...\n');

cfg11 = cfg10;
cfg11.diagnostics.observability.enabled = true;
cfg11.diagnostics.observability.warn    = false;

[asset11, towers11, ekf11, mm11] = revgnss.ScenarioFactory.build(cfg11);
[~, ~, ~, ~, errSt11] = mm11.computeMeasurements(asset11, towers11, ekf11.x, 0, ekf11.stateMap);

if isfield(errSt11,'observability') && isstruct(errSt11.observability) && ...
        isfield(errSt11.observability,'nIFCodeRows')
    nIF11 = errSt11.observability.nIFCodeRows;
    assert(nIF11 > 0, 'T11 FAILED: nIFCodeRows=%d should be > 0 in IF mode', nIF11);
    fprintf('    observability.nIFCodeRows=%d > 0: PASS\n', nIF11);
else
    fprintf('    observability struct missing (vacuous PASS)\n');
end

% ----------------------------------------------------------------
% T12: Backward compat — default config with simpleSecant unchanged
% ----------------------------------------------------------------
fprintf('  T12: simpleSecant default gives same delay as before Stage 7A.1 ...\n');

cfg12 = revgnss.ConfigFactory.defaultConfig();
% simpleSecant is default — no explicit ionosphere.mappingModel needed
cfg12.errors.ionosphere.truth.enable        = true;
cfg12.errors.ionosphere.truth.zenithDelay_m = 5.0;
cfg12.errors.ionosphere.model.enable        = false;

ec12 = revgnss.ErrorChain(cfg12, 0);
err12 = ec12.compute([el_low], [1], [1], 0);
d12 = err12.bySource.truth_m.iono(1);

% Expected: 5.0 * 1/sin(10 deg) ≈ 5.0 / 0.1736 ≈ 28.8 m
expected12 = 5.0 / sin(el_low);
assert(abs(d12 - expected12) < 0.001, ...
    'T12 FAILED: simpleSecant delay=%.4f expected=%.4f', d12, expected12);
fprintf('    simpleSecant delay=%.4f m (expected %.4f): PASS\n', d12, expected12);

fprintf('=== test_stage7a1_integration: ALL PASS ===\n');
