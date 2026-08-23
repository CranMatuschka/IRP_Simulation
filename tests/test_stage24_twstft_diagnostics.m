% test_stage24_twstft_diagnostics
%
% Restored Stage 24 guard: TWSTFT is diagnostic-only in this codebase. It may
% append observable metadata rows, but it must not create EKF rows or inflate
% physical measurement counts.

thisDir = fileparts(mfilename('fullpath'));
ooRoot = fileparts(thisDir);
addpath(ooRoot);
addpath(fullfile(ooRoot, 'config'));

fprintf('=== test_stage24_twstft_diagnostics ===\n');

cfg = masterConfig();
cfg.scenario.nSpaceAssets = 2;
cfg.scenario.nReceivers = 1;
cfg.signals.names = {'L1', 'L2'};
cfg.signals.enabledMask = [true, true];
cfg.measurements.carrierMode = 'off';
cfg.measurements.carrierPhase.enable = false;
cfg.measurements.carrier.enabledByFrequency = [false, false];
cfg.estimator.estimateAttitude = false;
cfg.measurements.isl.timing.enable = true;
cfg.measurements.twstft.enable = true;
cfg.measurements.twstft.code.enable = true;
cfg.measurements.twstft.code.useInEKF = false;
cfg.measurements.twstft.requireIslTiming = true;
cfg.measurements.twstft.referenceAssetIndex = 1;
cfg.measurements.twstft.remoteAssetIndex = 2;
revgnss.TWSTFTDiagnosticBuilder.validateConfig(cfg);

twoWayInfo.linkEvents = [ ...
    event_('forwardLeg', 1.20, 0.25), ...
    event_('returnLeg', 0.90, 0.15)];
twstftDiag = revgnss.TWSTFTDiagnosticBuilder.build(cfg, struct(), twoWayInfo);
assert(twstftDiag.enabled, 'T1 FAILED: diagnostic should be enabled.');
assert(strcmp(twstftDiag.diagnosticClassification, 'diagnosticOnlyApproximation'), ...
    'T1 FAILED: expected diagnosticOnlyApproximation classification.');
assert(~twstftDiag.useInEKF && twstftDiag.twstftEkfRows == 0, ...
    'T1 FAILED: TWSTFT diagnostic must not claim EKF rows.');
assert(~twstftDiag.relayTransponderImplemented && ~twstftDiag.islCarrierEkfUsed, ...
    'T1 FAILED: TWSTFT diagnostic must not claim relay/transponder or carrier EKF.');
assert(numel(twstftDiag.rows) == 1 && strcmp(twstftDiag.rows(1).role, 'diagnosticOnly'), ...
    'T1 FAILED: TWSTFT metadata row must be diagnosticOnly.');
fprintf('  T1 builder emits diagnostic-only TWSTFT metadata: PASS\n');

baseRow = revgnss.ObservableRowDescriptor.create(1, 'code', 'derived:test:code', ...
    'L1', 1, 1, 13, 'synthetic base physical code row', 'physicalEKF');
stack0 = revgnss.ObservableStackDescriptor.create(struct([]), struct([]), baseRow);
stack = revgnss.ReverseGnssObservableAdapter.addTWSTFTDiagnosticRows(stack0, twstftDiag);
assert(stack.rowsByType.twstftCodeDiagnostic == 1, ...
    'T2 FAILED: expected one twstftCodeDiagnostic metadata row.');
physicalRows = stack.rowsByType.code + stack.rowsByType.doppler + stack.rowsByType.carrier;
assert(physicalRows == 1, 'T2 FAILED: TWSTFT diagnostic row inflated physical row counts.');
fprintf('  T2 observable stack keeps TWSTFT out of physical EKF counts: PASS\n');

summary = struct();
summary.twstftDiag = twstftDiag;
summary.observableStack = stack;
summary.totalCodeRows = 1;
summary.totalDopplerRows = 0;
summary.totalCarrierRows = 0;
summary.carrierUsedInEkf = false;
summary.nAmbiguityStates = 0;
summary.nZwdStates = 0;
summary.nIonoStates = 0;
summary.nStates = NaN;
diag = struct('nEpochs', 0);
revgnss.ReportRealityHelper.validateConsistency(cfg, summary, diag, struct());
fprintf('  T3 report reality guard accepts diagnostic-only TWSTFT and rejects physical leakage: PASS\n');

cfgBad = cfg;
cfgBad.measurements.twstft.code.useInEKF = true;
threw = false;
try
    revgnss.TWSTFTDiagnosticBuilder.validateConfig(cfgBad);
catch
    threw = true;
end
assert(threw, 'T4 FAILED: TWSTFT code useInEKF=true must be blocked.');
fprintf('  T4 useInEKF guard blocks TWSTFT physical rows: PASS\n');

fprintf('=== test_stage24_twstft_diagnostics: ALL PASS ===\n');

function ev = event_(role, rxClock_m, txClock_m)
ev = struct( ...
    'eventRole', role, ...
    'receiverClockBiasAtReceive_m', rxClock_m, ...
    'transmitterClockBiasAtTransmit_m', txClock_m);
end
