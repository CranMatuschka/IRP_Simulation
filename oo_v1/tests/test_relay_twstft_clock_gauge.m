function test_relay_twstft_clock_gauge()
% test_relay_twstft_clock_gauge  Plan Section 4.5 physics core. Verifies the exact closed-form
% combiner in revgnss.GroundRelaySessionObservableBuilder.combine
% (clockDifferenceValue_s = 0.5*((DeltaF-tauF)-(DeltaR-tauR))), the REALIZABLE classical
% relay-TWSTFT combination classicalReciprocityValue_s = 0.5*(DeltaF-DeltaR) (combined review B1),
% the truth/calibration net station-delay correction (combined review M4), and the
% clockClaim='relativeBiasOnly' justification (common-mode blindness, differential sensitivity,
% relay marginalized out).

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir,'..');
addpath(rootDir);
addpath(fullfile(rootDir,'config'));
addpath(fullfile(rootDir,'config','internal'));

fprintf('=== test_relay_twstft_clock_gauge ===\n');
i_test_static_symmetric_zero_bias_();
i_test_injected_clock_offset_sign_and_units_();
i_test_moving_relay_exact_closure_();
i_test_common_mode_blindness_();
i_test_differential_sensitivity_();
i_test_relay_marginalized_out_weak_();
i_test_relay_marginalized_out_structural_();
i_test_relay_asymmetry_moves_classical_not_clockDifference_();
i_test_perfectly_calibrated_delay_zero_bias_();
i_test_station_delay_symmetric_cancellation_and_asymmetric_survival_();
i_test_config_hard_refusals_();
fprintf('=== test_relay_twstft_clock_gauge: ALL PASS ===\n');
end

% ================================================================================================
function i_test_static_symmetric_zero_bias_()
observable = i_buildObservable_(0,0,i_hardware_());
assert(abs(observable.clockDifferenceValue_s) < 1e-9, ...
    'FAIL: static, symmetric, zero-bias case must give clockDifferenceValue_s~0, got %.3e.', ...
    observable.clockDifferenceValue_s);
fprintf('  PASS static symmetric zero-bias case: clockDifferenceValue_s=%.3e s\n',observable.clockDifferenceValue_s);
end

% ================================================================================================
function i_test_injected_clock_offset_sign_and_units_()
% bias_A=+500ns, bias_B=0 -> remoteMinusOwner (B-A) = -500ns.
observable = i_buildObservable_(500e-9*299792458,0,i_hardware_());
assert(abs(observable.clockDifferenceValue_s - (-500e-9)) < 1e-9, ...
    'FAIL: expected clockDifferenceValue_s=-500e-9 (remoteMinusOwner), got %.3e.', ...
    observable.clockDifferenceValue_s);
c = revgnss.Constants.SPEED_OF_LIGHT_MPS;
assert(abs(observable.clockDifferenceValue_m - c*observable.clockDifferenceValue_s) < 1e-6);
fprintf('  PASS injected +500ns bias_A: clockDifferenceValue_s=%.6e (remoteMinusOwner sign correct)\n', ...
    observable.clockDifferenceValue_s);
end

% ================================================================================================
function i_test_moving_relay_exact_closure_()
% Nonzero relay velocity -> tauF~=tauR (verified nonzero) -- the TRUTH-GEOMETRY-ASSISTED
% clockDifferenceValue_s must still recover the injected bias EXACTLY (to solver tolerance), the
% direct test of the exact-formula derivation (combined review B1's header now documents
% precisely WHY this is exact -- it requires tauF/tauR, ground truth no real receiver has).
[recordForward,recordReturn,hardware] = i_biasedRecords_(700e-9*299792458,0);
tauF_s = recordForward.coordinateTimeEvents_s(4) - recordForward.coordinateTimeEvents_s(1);
tauR_s = recordReturn.coordinateTimeEvents_s(4) - recordReturn.coordinateTimeEvents_s(1);
assert(abs(tauF_s-tauR_s) > 1e-9,'FAIL: fixture must have a genuinely moving relay (tauF~=tauR).');
observable = revgnss.GroundRelaySessionObservableBuilder.combine( ...
    recordForward, recordReturn, hardware, i_hardwareCalibration_(), 0, 0, zeros(0,0), {}, ...
    sessionIdentifier='sess:1');
assert(abs(observable.clockDifferenceValue_s - (-700e-9)) < 1e-9, ...
    'FAIL: exact combiner must recover the injected bias despite tauF~=tauR, got %.3e.', ...
    observable.clockDifferenceValue_s);
fprintf('  PASS moving-relay exact closure: |tauF-tauR|=%.3e s, clockDifferenceValue_s=%.6e (expect -700e-9)\n', ...
    abs(tauF_s-tauR_s),observable.clockDifferenceValue_s);
end

% ================================================================================================
function i_test_common_mode_blindness_()
observable0 = i_buildObservable_(0,0,i_hardware_());
observableShifted = i_buildObservable_(1000,1000,i_hardware_()); % same +1000m shift on both stations
assert(abs(observable0.clockDifferenceValue_s - observableShifted.clockDifferenceValue_s) < 1e-12, ...
    'FAIL: shifting both station clock biases by the same constant must leave the output unchanged.');
fprintf('  PASS common-mode blindness: identical +1000m shift on both stations leaves output unchanged\n');
end

% ================================================================================================
function i_test_differential_sensitivity_()
observable0 = i_buildObservable_(0,0,i_hardware_());
observableShifted = i_buildObservable_(0,100,i_hardware_()); % +100m bias on station B only
delta_s = 100/299792458;
gotDelta_s = observableShifted.clockDifferenceValue_s - observable0.clockDifferenceValue_s;
assert(abs(gotDelta_s - delta_s) < 1e-9, ...
    'FAIL: shifting only bias_B by delta must change the output by exactly +delta, got %.3e vs expected %.3e.', ...
    gotDelta_s,delta_s);
fprintf('  PASS differential sensitivity: +100m shift on stationB alone changes output by exactly +delta\n');
end

% ================================================================================================
function i_test_relay_marginalized_out_weak_()
% Perturbing the relay's own clock bias leaves the output unchanged -- its slot(2)/slot(3) tags
% are computed for chain-shape compliance but never enter the combiner formula.
observableBase = i_buildObservableRelayBias_(0,i_hardware_());
observablePerturbed = i_buildObservableRelayBias_(1e9,i_hardware_()); % huge relay clock bias
assert(abs(observableBase.clockDifferenceValue_s - observablePerturbed.clockDifferenceValue_s) < 1e-12, ...
    'FAIL: an arbitrarily large relay clock bias must leave clockDifferenceValue_s unchanged.');
fprintf('  PASS relay marginalized out (weak form): huge relay clock bias has zero effect\n');
end

% ================================================================================================
function i_test_relay_marginalized_out_structural_()
% Stronger structural property: perturbing relayGroupDelayNominal_s/relayGroupDelayAsymmetry_s
% (not just the relay's clock bias) leaves clockDifferenceValue_s -- the TRUTH-GEOMETRY-ASSISTED
% value -- unchanged given driftless station clocks: only t1 moves in response to
% turnaroundProperTime_s, and delta_source(t1) is independent of t1 whenever localClockRate=1.
% (classicalReciprocityValue_s -- the REALIZABLE value -- DOES move with relayGroupDelayAsymmetry_s;
% see i_test_relay_asymmetry_moves_classical_not_clockDifference_ below, combined review B1.)
hwBase = i_hardware_();
hwPerturbed = revgnss.GroundRelaySessionHardwareModel( ...
    parameterSource='physicalTruth',physicalChainIdentifier='chain-1', ...
    calibrationProductIdentifier='cal-1',relayGroupDelayNominal_s=50e-3,relayGroupDelayAsymmetry_s=10e-3);
observableBase = i_buildObservable_(0,0,hwBase);
observablePerturbed = i_buildObservable_(0,0,hwPerturbed);
assert(abs(observableBase.clockDifferenceValue_s - observablePerturbed.clockDifferenceValue_s) < 1e-9, ...
    'FAIL: relay group delay/asymmetry must be near-inert on clockDifferenceValue_s under driftless station clocks.');
fprintf('  PASS relay marginalized out (structural form): relayGroupDelayNominal/Asymmetry near-inert on clockDifferenceValue_s\n');
end

% ================================================================================================
function i_test_relay_asymmetry_moves_classical_not_clockDifference_()
% Combined review B1: relayGroupDelayAsymmetry_s must move classicalReciprocityValue_s (the
% REALIZABLE classical value) by exactly +asymmetry/2 in the static-relay limit -- the genuine
% physical content the un-reviewed first cut's single-value design made structurally impossible to
% observe (relayGroupDelayAsymmetry_s was, and remains, structurally inert on
% clockDifferenceValue_s -- see the structural test above; that inertness is a deliberate, real
% property of the TRUTH-ASSISTED value, not a defect in general). A genuinely MOVING relay (this
% file's usual i_relay_/i_buildObservable_ fixture, v=3074 m/s) adds a real, small, second-order
% correction from the asymmetry-induced t1 shift interacting with relay motion (measured ~3.3e-8s
% on a 5e-3s effect, i.e. ~7 ppm) -- physically genuine, not a bug, but it would make this specific
% "exactly +asymmetry/2" claim only approximately true; a dedicated STATIC-relay fixture isolates
% the exact algebraic claim unambiguously.
geom = i_geom_();
stationA = revgnss.ReciprocalEndpointTruthProvider.fixedStation([6378137;0;0],0,0,'station:A',geom,10);
stationB = revgnss.ReciprocalEndpointTruthProvider.fixedStation([0;6378137;0],0,0,'station:B',geom,10);
staticRelayAsset = struct('r_ecef_m',[42164000;0;0],'v_ecef_mps',[0;0;0],'attitude_euler_rad',[0;0;0], ...
    'clock',struct('getBiasMeters',@() 0,'getDriftMetersPerSecond',@() 0,'getOscillatorDriftMetersPerSecond',@() 0));
relay = revgnss.ReciprocalEndpointTruthProvider.spacecraft(staticRelayAsset,1,geom,10);
hwCal = i_hardwareCalibration_();
optsF = i_baseOptions_('fwd:1'); optsR = i_baseOptions_('ret:1');

hwBase = i_hardware_();
hwBaseF = hwBase.asEventSolverHardware('forward'); hwBaseR = hwBase.asEventSolverHardware('return');
recFB = revgnss.GroundRelayOneWayPassRecordBuilder.buildOneWayPass(stationA,relay,stationB,hwBaseF,10,[],optsF{:});
recRB = revgnss.GroundRelayOneWayPassRecordBuilder.buildOneWayPass(stationB,relay,stationA,hwBaseR,20,[],optsR{:});
observableBase = revgnss.GroundRelaySessionObservableBuilder.combine( ...
    recFB, recRB, hwBase, hwCal, 0, 0, zeros(0,0), {}, sessionIdentifier='sess:1');

hwAsymmetric = revgnss.GroundRelaySessionHardwareModel( ...
    parameterSource='physicalTruth',physicalChainIdentifier='chain-1', ...
    calibrationProductIdentifier='cal-1',relayGroupDelayNominal_s=50e-3,relayGroupDelayAsymmetry_s=10e-3);
hwAsymF = hwAsymmetric.asEventSolverHardware('forward'); hwAsymR = hwAsymmetric.asEventSolverHardware('return');
recFA = revgnss.GroundRelayOneWayPassRecordBuilder.buildOneWayPass(stationA,relay,stationB,hwAsymF,10,[],optsF{:});
recRA = revgnss.GroundRelayOneWayPassRecordBuilder.buildOneWayPass(stationB,relay,stationA,hwAsymR,20,[],optsR{:});
observableAsymmetric = revgnss.GroundRelaySessionObservableBuilder.combine( ...
    recFA, recRA, hwAsymmetric, hwCal, 0, 0, zeros(0,0), {}, sessionIdentifier='sess:1');

gotDelta_s = observableAsymmetric.classicalReciprocityValue_s - observableBase.classicalReciprocityValue_s;
expectedDelta_s = 10e-3/2;
assert(abs(gotDelta_s - expectedDelta_s) < 1e-9, ...
    'FAIL: relayGroupDelayAsymmetry_s=10ms must move classicalReciprocityValue_s by exactly +5ms under a static relay, got %.6e.', ...
    gotDelta_s);
assert(abs(observableAsymmetric.clockDifferenceValue_s - observableBase.clockDifferenceValue_s) < 1e-9, ...
    'FAIL: clockDifferenceValue_s must remain unaffected by the same perturbation.');
fprintf('  PASS relayGroupDelayAsymmetry_s moves classicalReciprocityValue_s by exactly +asymmetry/2 (static relay), clockDifferenceValue_s unaffected\n');
end

% ================================================================================================
function i_test_perfectly_calibrated_delay_zero_bias_()
% Combined review M4: a station delay that is PERFECTLY KNOWN (hardwareCalibration carries the
% SAME nominal value as hardwareTruth, truth.*Error_s==0 in effect) must produce EXACTLY ZERO bias
% on both reported values -- only the UNCALIBRATED residual (hardwareTruth minus
% hardwareCalibration) should ever bias the output. An un-reviewed first cut always used the same
% single hardware object for both roles, so a "perfectly known" 300ns delay incorrectly biased the
% result by its own full nominal value (150ns after the +-0.5 combiner weighting).
hwZero = i_hardware_();
hwZeroCal = i_hardwareCalibration_();
observableBase = i_buildObservable_(0,0,hwZero,hwZeroCal);

hwKnownTruth = revgnss.GroundRelaySessionHardwareModel( ...
    parameterSource='physicalTruth',physicalChainIdentifier='chain-1', ...
    calibrationProductIdentifier='cal-1',relayGroupDelayNominal_s=1e-3,stationATransmitDelay_s=300e-9);
hwKnownCal = revgnss.GroundRelaySessionHardwareModel( ...
    parameterSource='calibrationProduct',physicalChainIdentifier='chain-1', ...
    calibrationProductIdentifier='cal-1',relayGroupDelayNominal_s=1e-3,stationATransmitDelay_s=300e-9);
observableKnown = i_buildObservable_(0,0,hwKnownTruth,hwKnownCal);

assert(abs(observableKnown.clockDifferenceValue_s - observableBase.clockDifferenceValue_s) < 1e-12, ...
    'FAIL: a perfectly-calibrated 300ns stationA TX delay must produce zero bias on clockDifferenceValue_s.');
assert(abs(observableKnown.classicalReciprocityValue_s - observableBase.classicalReciprocityValue_s) < 1e-12, ...
    'FAIL: a perfectly-calibrated 300ns stationA TX delay must produce zero bias on classicalReciprocityValue_s.');
fprintf('  PASS a perfectly-known, fully-calibrated 300ns station delay produces exactly zero bias on both reported values\n');
end

% ================================================================================================
function i_test_station_delay_symmetric_cancellation_and_asymmetric_survival_()
hwSymmetric = revgnss.GroundRelaySessionHardwareModel( ...
    parameterSource='physicalTruth',physicalChainIdentifier='chain-1', ...
    calibrationProductIdentifier='cal-1',relayGroupDelayNominal_s=1e-3, ...
    stationATransmitDelay_s=200e-9,stationAReceiveDelay_s=200e-9, ...
    stationBTransmitDelay_s=50e-9,stationBReceiveDelay_s=50e-9);
observableBase = i_buildObservable_(0,0,i_hardware_());
observableSymmetric = i_buildObservable_(0,0,hwSymmetric);
assert(abs(observableBase.clockDifferenceValue_s - observableSymmetric.clockDifferenceValue_s) < 1e-12, ...
    'FAIL: equal TX/RX station delays (both stations) must have zero effect on the output (provably inert).');

% combine()'s own algebra (net = hardwareTruth - hardwareCalibration; hardwareCalibration is the
% all-zero i_hardwareCalibration_() baseline for every case below, so net == the hardwareTruth
% value declared here): deltaF = rawDeltaF + txA + rxB; deltaR = rawDeltaR + rxA + txB, so
% deltaF-deltaR = (rawDeltaF-rawDeltaR) + (txA-rxA) - (txB-rxB); station hardware delays never
% touch solveRelayTransit (they are RAW-TAGS-ONLY corrections applied only in combine()), so
% rawDeltaF/rawDeltaR/tauF/tauR are identical between every fixture below and the all-zero
% baseline -- the bias is therefore exactly 0.5*[(txA-rxA)-(txB-rxB)] in every case (T2: covers
% stationA-only (already above), stationB-only, and both-stations-asymmetric, so a TX/RX swap bug
% on EITHER station would be caught).
hwAsymmetricA = revgnss.GroundRelaySessionHardwareModel( ...
    parameterSource='physicalTruth',physicalChainIdentifier='chain-1', ...
    calibrationProductIdentifier='cal-1',relayGroupDelayNominal_s=1e-3, ...
    stationATransmitDelay_s=300e-9,stationAReceiveDelay_s=100e-9, ...
    stationBTransmitDelay_s=50e-9,stationBReceiveDelay_s=50e-9);
observableAsymmetricA = i_buildObservable_(0,0,hwAsymmetricA);
expectedBiasA_s = 0.5*((300e-9-100e-9) - (50e-9-50e-9));
gotBiasA_s = observableAsymmetricA.clockDifferenceValue_s - observableBase.clockDifferenceValue_s;
assert(abs(gotBiasA_s - expectedBiasA_s) < 1e-9, ...
    'FAIL: asymmetric stationA TX/RX delay must produce a real, hand-computable bias, got %.3e vs expected %.3e.', ...
    gotBiasA_s,expectedBiasA_s);

hwAsymmetricB = revgnss.GroundRelaySessionHardwareModel( ...
    parameterSource='physicalTruth',physicalChainIdentifier='chain-1', ...
    calibrationProductIdentifier='cal-1',relayGroupDelayNominal_s=1e-3, ...
    stationATransmitDelay_s=50e-9,stationAReceiveDelay_s=50e-9, ...
    stationBTransmitDelay_s=300e-9,stationBReceiveDelay_s=100e-9);
observableAsymmetricB = i_buildObservable_(0,0,hwAsymmetricB);
expectedBiasB_s = 0.5*((50e-9-50e-9) - (300e-9-100e-9)); % note the MINUS sign on the B term
gotBiasB_s = observableAsymmetricB.clockDifferenceValue_s - observableBase.clockDifferenceValue_s;
assert(abs(gotBiasB_s - expectedBiasB_s) < 1e-9, ...
    'FAIL: asymmetric stationB TX/RX delay must produce the OPPOSITE-signed hand-computable bias (a TX/RX swap on B would flip this), got %.3e vs expected %.3e.', ...
    gotBiasB_s,expectedBiasB_s);
assert(sign(gotBiasA_s) ~= sign(gotBiasB_s), ...
    'FAIL: stationA-only and stationB-only asymmetric delays of the same magnitude/sign must produce OPPOSITE-signed biases.');

hwAsymmetricBoth = revgnss.GroundRelaySessionHardwareModel( ...
    parameterSource='physicalTruth',physicalChainIdentifier='chain-1', ...
    calibrationProductIdentifier='cal-1',relayGroupDelayNominal_s=1e-3, ...
    stationATransmitDelay_s=300e-9,stationAReceiveDelay_s=100e-9, ...
    stationBTransmitDelay_s=300e-9,stationBReceiveDelay_s=100e-9);
observableAsymmetricBoth = i_buildObservable_(0,0,hwAsymmetricBoth);
expectedBiasBoth_s = 0.5*((300e-9-100e-9) - (300e-9-100e-9)); % identical asymmetry on both -> cancels
gotBiasBoth_s = observableAsymmetricBoth.clockDifferenceValue_s - observableBase.clockDifferenceValue_s;
assert(abs(gotBiasBoth_s - expectedBiasBoth_s) < 1e-9, ...
    'FAIL: identical TX/RX asymmetry on both stations must cancel exactly (bias=0), got %.3e.',gotBiasBoth_s);
fprintf('  PASS station TX/RX symmetric cancellation (exact); stationA-only, stationB-only (opposite sign), and both-stations-identical (cancels) asymmetric survival all hand-computed\n');
end

% ================================================================================================
function i_test_config_hard_refusals_()
cfg = i_baseCfg_();
cfg.measurements.groundRelayTimeTransfer.hardware.relayFrequencyTranslationRatio = 1.5;
threw = false;
try
    revgnss.GroundRelayPhysicalLinkConfig.requireCompleteSessionConfig(cfg);
catch ME
    threw = strcmp(ME.identifier,'GroundRelayPhysicalLinkConfig:relayFrequencyTranslationUnsupported');
end
assert(threw,'FAIL: relayFrequencyTranslationRatio~=1 must be hard-refused.');

cfg2 = i_baseCfg_();
cfg2.measurements.groundRelayTimeTransfer.useInEKF = true;
threw2 = false;
try
    revgnss.GroundRelayPhysicalLinkConfig.requireCompleteSessionConfig(cfg2);
catch ME2
    threw2 = strcmp(ME2.identifier,'GroundRelayPhysicalLinkConfig:useInEKFUnsupported');
end
assert(threw2,'FAIL: useInEKF=true must be hard-refused this stage.');
fprintf('  PASS relayFrequencyTranslationRatio~=1 and useInEKF=true are both hard-refused\n');
end

% ================================================================================================
function cfg = i_baseCfg_()
cfg = masterConfig();
cfg.measurements.groundRelayTimeTransfer.enable = true;
cfg.measurements.groundRelayTimeTransfer.session.stationATowerIndex = 1;
cfg.measurements.groundRelayTimeTransfer.session.stationBTowerIndex = 2;
cfg.measurements.groundRelayTimeTransfer.session.relaySpaceAssetIndex = 1;
cfg.measurements.groundRelayTimeTransfer.schedule.forwardReceptionEpoch_s = 10;
cfg.measurements.groundRelayTimeTransfer.schedule.returnReceptionEpoch_s = 20;
end

% ================================================================================================
function hardware = i_hardware_()
hardware = revgnss.GroundRelaySessionHardwareModel( ...
    parameterSource='physicalTruth',physicalChainIdentifier='chain-1', ...
    calibrationProductIdentifier='cal-1',relayGroupDelayNominal_s=1e-3);
end

% ================================================================================================
function hardware = i_hardwareCalibration_()
% i_hardwareCalibration_  All-zero-station-delay calibrationProduct-sourced hardware, the
% "nothing known/calibrated" baseline combine() requires as its second argument (combined review
% M4). Paired with i_hardware_() (physicalTruth) this reproduces the exact pre-M4-fix numeric
% behaviour (net delay == hardwareTruth's full nominal value) for tests that are not specifically
% about calibration-vs-truth separation.
hardware = revgnss.GroundRelaySessionHardwareModel( ...
    parameterSource='calibrationProduct',physicalChainIdentifier='chain-1', ...
    calibrationProductIdentifier='cal-1',relayGroupDelayNominal_s=1e-3);
end

% ================================================================================================
function geom = i_geom_()
geom = struct('transmitOffset_body_m',zeros(3,1),'receiveOffset_body_m',zeros(3,1), ...
    'transmitTerminalIdentifier','tx','receiveTerminalIdentifier','rx', ...
    'transmitAntennaIdentifier','txa','receiveAntennaIdentifier','rxa');
end

% ================================================================================================
function relay = i_relay_(clockBiasMeters)
relayAsset = struct('r_ecef_m',[42164000;0;0],'v_ecef_mps',[0;3074;0], ...
    'attitude_euler_rad',[0;0;0], ...
    'clock',struct('getBiasMeters',@() clockBiasMeters,'getDriftMetersPerSecond',@() 0,'getOscillatorDriftMetersPerSecond',@() 0));
relay = revgnss.ReciprocalEndpointTruthProvider.spacecraft(relayAsset,1,i_geom_(),10);
end

% ================================================================================================
function opts = i_baseOptions_(exchangeId)
opts = {'exchangeIdentifier',exchangeId,'sessionIdentifier','sess:1', ...
    'protocolIdentifier','classicalRelayTwstft','signalIdentifier','TWSTFT-RELAY', ...
    'channelIdentifier','relay-1','carrierFrequency_Hz',14e9, ...
    'counterTagSigma_s',zeros(1,4),'counterTagLabels',{'t1','t2','t3','t4'}, ...
    'applyAtmosphere',false};
end

% ================================================================================================
function [recordForward, recordReturn, hardware] = i_biasedRecords_(stationABiasMeters, stationBBiasMeters)
% Fixture with a MOVING relay (nonzero velocity, so tauF~=tauR) plus optional station clock biases.
geom = i_geom_();
stationA = revgnss.ReciprocalEndpointTruthProvider.fixedStation( ...
    [6378137;0;0],stationABiasMeters,0,'station:A',geom,10);
stationB = revgnss.ReciprocalEndpointTruthProvider.fixedStation( ...
    [0;6378137;0],stationBBiasMeters,0,'station:B',geom,10);
relay = i_relay_(0);
hardware = i_hardware_();
hwForward = hardware.asEventSolverHardware('forward');
hwReturn = hardware.asEventSolverHardware('return');
optsF = i_baseOptions_('fwd:1'); optsR = i_baseOptions_('ret:1');
recordForward = revgnss.GroundRelayOneWayPassRecordBuilder.buildOneWayPass( ...
    stationA, relay, stationB, hwForward, 10, [], optsF{:});
recordReturn = revgnss.GroundRelayOneWayPassRecordBuilder.buildOneWayPass( ...
    stationB, relay, stationA, hwReturn, 20, [], optsR{:});
end

% ================================================================================================
function observable = i_buildObservable_(stationABiasMeters, stationBBiasMeters, hardwareTruth, hardwareCalibration)
if nargin < 4
    hardwareCalibration = i_hardwareCalibration_();
end
geom = i_geom_();
stationA = revgnss.ReciprocalEndpointTruthProvider.fixedStation( ...
    [6378137;0;0],stationABiasMeters,0,'station:A',geom,10);
stationB = revgnss.ReciprocalEndpointTruthProvider.fixedStation( ...
    [0;6378137;0],stationBBiasMeters,0,'station:B',geom,10);
relay = i_relay_(0);
hwForward = hardwareTruth.asEventSolverHardware('forward');
hwReturn = hardwareTruth.asEventSolverHardware('return');
optsF = i_baseOptions_('fwd:1'); optsR = i_baseOptions_('ret:1');
recordForward = revgnss.GroundRelayOneWayPassRecordBuilder.buildOneWayPass( ...
    stationA, relay, stationB, hwForward, 10, [], optsF{:});
recordReturn = revgnss.GroundRelayOneWayPassRecordBuilder.buildOneWayPass( ...
    stationB, relay, stationA, hwReturn, 20, [], optsR{:});
observable = revgnss.GroundRelaySessionObservableBuilder.combine( ...
    recordForward, recordReturn, hardwareTruth, hardwareCalibration, 0, 0, zeros(0,0), {}, ...
    sessionIdentifier='sess:1');
end

% ================================================================================================
function observable = i_buildObservableRelayBias_(relayClockBiasMeters, hardwareTruth, hardwareCalibration)
if nargin < 3
    hardwareCalibration = i_hardwareCalibration_();
end
geom = i_geom_();
stationA = revgnss.ReciprocalEndpointTruthProvider.fixedStation([6378137;0;0],0,0,'station:A',geom,10);
stationB = revgnss.ReciprocalEndpointTruthProvider.fixedStation([0;6378137;0],0,0,'station:B',geom,10);
relay = i_relay_(relayClockBiasMeters);
hwForward = hardwareTruth.asEventSolverHardware('forward');
hwReturn = hardwareTruth.asEventSolverHardware('return');
optsF = i_baseOptions_('fwd:1'); optsR = i_baseOptions_('ret:1');
recordForward = revgnss.GroundRelayOneWayPassRecordBuilder.buildOneWayPass( ...
    stationA, relay, stationB, hwForward, 10, [], optsF{:});
recordReturn = revgnss.GroundRelayOneWayPassRecordBuilder.buildOneWayPass( ...
    stationB, relay, stationA, hwReturn, 20, [], optsR{:});
observable = revgnss.GroundRelaySessionObservableBuilder.combine( ...
    recordForward, recordReturn, hardwareTruth, hardwareCalibration, 0, 0, zeros(0,0), {}, ...
    sessionIdentifier='sess:1');
end
