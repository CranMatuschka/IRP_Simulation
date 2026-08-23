% test_code_dcb_active_path
%
% Verifies configured deterministic code DCB is active in measurement rows:
%   T1 raw L1/L2 rows receive their own truth/model DCB terms.
%   T2 IF rows carry alpha*DCB_L1 + beta*DCB_L2 without adding stochastic R.
%   T3 realism-grade DCB is nonzero in active code rows and modelled as zero.

thisDir = fileparts(mfilename('fullpath'));
ooRoot = fileparts(thisDir);
addpath(ooRoot);
addpath(fullfile(ooRoot, 'config'));

fprintf('=== test_code_dcb_active_path ===\n');

tL1 = 0.30;
tL2 = 0.45;
mL1 = 0.05;
mL2 = -0.02;

cfgRaw0 = buildCfg_('dualFrequencyStacked', 0, 0, 0, 0);
cfgRaw  = buildCfg_('dualFrequencyStacked', tL1, tL2, mL1, mL2);
[zRaw0, hRaw0, ~, RRaw0, errRaw0] = oneEpoch_(cfgRaw0);
[zRaw,  hRaw,  ~, RRaw,  errRaw]  = oneEpoch_(cfgRaw);

assert(~isempty(zRaw) && numel(zRaw) == errRaw.nPseudorange, ...
    'T1 FAILED: raw code rows missing.');
assert(isfield(errRaw.bySource.truth_m, 'dcb'), 'T1 FAILED: raw truth DCB source missing.');
assert(isfield(errRaw.bySource.model_m, 'dcb'), 'T1 FAILED: raw model DCB source missing.');
assert(isfield(errRaw.bySource.sigma_m, 'dcb'), 'T1 FAILED: raw sigma DCB source missing.');
assert(ismember('dcb', errRaw.labels), 'T1 FAILED: raw DCB label missing.');

nRaw = errRaw.nPseudorange;
assert(mod(nRaw, 2) == 0, 'T1 FAILED: raw L1/L2 rows are not paired.');
nPairs = nRaw / 2;
idx1 = 1:nPairs;
idx2 = nPairs+1:2*nPairs;
assert(all(strcmp(errRaw.signalName_perMeas(idx1), 'L1')) && ...
       all(strcmp(errRaw.signalName_perMeas(idx2), 'L2')), ...
       'T1 FAILED: expected stacked L1 rows followed by L2 rows.');

assertNear_(errRaw.bySource.truth_m.dcb(idx1), tL1, 1e-12, 'T1 truth L1 DCB');
assertNear_(errRaw.bySource.truth_m.dcb(idx2), tL2, 1e-12, 'T1 truth L2 DCB');
assertNear_(errRaw.bySource.model_m.dcb(idx1), mL1, 1e-12, 'T1 model L1 DCB');
assertNear_(errRaw.bySource.model_m.dcb(idx2), mL2, 1e-12, 'T1 model L2 DCB');
assertNear_(errRaw.bySource.sigma_m.dcb, 0, 1e-12, 'T1 DCB sigma');
assertNear_(zRaw(idx1) - zRaw0(idx1), tL1, 1e-8, 'T1 z L1 DCB');
assertNear_(zRaw(idx2) - zRaw0(idx2), tL2, 1e-8, 'T1 z L2 DCB');
assertNear_(hRaw(idx1) - hRaw0(idx1), mL1, 1e-8, 'T1 h L1 DCB');
assertNear_(hRaw(idx2) - hRaw0(idx2), mL2, 1e-8, 'T1 h L2 DCB');
assertNear_(diag(RRaw) - diag(RRaw0), 0, 1e-12, 'T1 DCB must not alter raw R');
assertNear_(errRaw0.bySource.truth_m.dcb, 0, 1e-12, 'T1 zero-config truth DCB');
fprintf('  T1 raw L1/L2 deterministic DCB path: PASS\n');

cfgIF0 = buildCfg_('ionosphereFree', 0, 0, 0, 0);
cfgIF  = buildCfg_('ionosphereFree', tL1, tL2, mL1, mL2);
[zIF0, hIF0, ~, RIF0, ~] = oneEpoch_(cfgIF0);
[zIF,  hIF,  ~, RIF,  errIF] = oneEpoch_(cfgIF);

assert(errIF.ifCombination, 'T2 FAILED: IF combination flag missing.');
assert(all(strcmp(errIF.signalName_perMeas, 'IF')), 'T2 FAILED: IF signal labels missing.');
assert(isfield(errIF.bySource.truth_m, 'dcb'), 'T2 FAILED: IF truth DCB source missing.');
assert(isfield(errIF.bySource.model_m, 'dcb'), 'T2 FAILED: IF model DCB source missing.');
assert(isfield(errIF.bySource.sigma_m, 'dcb'), 'T2 FAILED: IF sigma DCB source missing.');
assert(ismember('dcb', errIF.labels), 'T2 FAILED: IF DCB label missing.');

f1 = revgnss.SignalDefinition.get('L1').frequency_Hz;
f2 = revgnss.SignalDefinition.get('L2').frequency_Hz;
[alpha, beta] = revgnss.IonoFreeCombination.coefficients(f1, f2);
expectedTruthIF = alpha * tL1 + beta * tL2;
expectedModelIF = alpha * mL1 + beta * mL2;
assertNear_(errIF.bySource.truth_m.dcb, expectedTruthIF, 1e-10, 'T2 truth IF DCB');
assertNear_(errIF.bySource.model_m.dcb, expectedModelIF, 1e-10, 'T2 model IF DCB');
assertNear_(errIF.bySource.sigma_m.dcb, 0, 1e-12, 'T2 IF DCB sigma');
assertNear_(zIF - zIF0, expectedTruthIF, 5e-8, 'T2 z IF DCB');
assertNear_(hIF - hIF0, expectedModelIF, 5e-8, 'T2 h IF DCB');
assertNear_(diag(RIF) - diag(RIF0), 0, 1e-12, 'T2 DCB must not alter IF R');
fprintf('  T2 IF DCB signed alpha/beta combination: PASS\n');

cfgRealism = realismGradeConfig(revgnss.ConfigFactory.defaultConfig());
cfgRealism = forceCodeOnlyDualFreq_(cfgRealism, 'dualFrequencyStacked');
[~, ~, ~, ~, errRealism] = oneEpoch_(cfgRealism);
assert(isfield(errRealism.bySource.truth_m, 'dcb'), ...
    'T3 FAILED: realism-grade DCB source missing.');
assert(any(abs(errRealism.bySource.truth_m.dcb) > 0), ...
    'T3 FAILED: realism-grade configured DCB did not reach active rows.');
assertNear_(errRealism.bySource.model_m.dcb, 0, 1e-12, ...
    'T3 realism-grade model DCB should remain zero by default');
cfgRealismFinal = revgnss.ConfigFactory.finalizeConfig(cfgRealism);
manifest = revgnss.SimulationToggleManifest.fromConfig(cfgRealismFinal);
paths = {manifest.cfgPath};
dcbRows = manifest(strcmp(paths, 'cfg.biases.interFrequency.code truth/model'));
assert(~isempty(dcbRows) && strcmp(dcbRows(1).status, 'active'), ...
    'T3 FAILED: manifest does not mark configured code DCB active.');
manifestText = strjoin([{manifest.cfgPath}, {manifest.value}, {manifest.notes}], ' ');
assert(~contains(manifestText, 'DCB modelled as zero') && ...
       ~contains(manifestText, 'zero (v1)'), ...
       'T3 FAILED: manifest still contains stale zero-DCB v1 wording.');
fprintf('  T3 realism-grade DCB reaches active rows and manifest: PASS\n');

fprintf('=== test_code_dcb_active_path: ALL PASS ===\n');

function cfg = buildCfg_(codeMode, truthL1, truthL2, modelL1, modelL2)
cfg = revgnss.ConfigFactory.defaultConfig();
cfg = forceCodeOnlyDualFreq_(cfg, codeMode);
cfg.biases.interFrequency.code.truth.L1_m = truthL1;
cfg.biases.interFrequency.code.truth.L2_m = truthL2;
cfg.biases.interFrequency.code.model.L1_m = modelL1;
cfg.biases.interFrequency.code.model.L2_m = modelL2;
end

function cfg = forceCodeOnlyDualFreq_(cfg, codeMode)
cfg.signals.names = {'L1', 'L2'};
cfg.signals.enabledMask = [true, true];
cfg.signals.enabled = {'L1', 'L2'};
cfg.measurements.codeMode = codeMode;
cfg.measurements.observableMode = 'code';
cfg.measurements.doppler.enable = false;
cfg.measurements.doppler.useInEKF = false;
cfg.measurements.carrierMode = 'off';
cfg.measurements.carrierPhase.enable = false;
cfg.errors.troposphere.truth.enable = false;
cfg.errors.troposphere.model.enable = false;
cfg.errors.ionosphere.truth.enable = false;
cfg.errors.ionosphere.model.enable = false;
cfg.errors.ionosphere.higherOrder.enable = false;
cfg.errors.ionosphere.scintillation.enable = false;
cfg.errors.hardwareDelay.enable = false;
cfg.errors.hardwareDelay.truth.enable = false;
cfg.errors.hardwareDelay.model.enable = false;
cfg.errors.hardwareDelay.residualStochastic.enable = false;
cfg.errors.multipath.enable = false;
cfg.errors.multipath.truth.enable = false;
cfg.errors.multipath.coloredGM.enable = false;
cfg.effects.correlatedNoise.enable = false;
cfg.covariance.sharedErrors.enable = false;
cfg.report.writePdf = false;
cfg.report.writeMat = false;
cfg.report.enable = false;
cfg.plots.enable = false;
cfg.plots.showFigures = false;
end

function [z, h, H, R, errStruct] = oneEpoch_(cfg)
[asset, towers, ekf, measModel] = revgnss.ScenarioFactory.build(cfg);
[z, h, H, R, errStruct] = measModel.computeMeasurements(asset, towers, ekf.x, 0, ekf.stateMap);
end

function assertNear_(actual, expected, tol, label)
if isscalar(expected)
    expected = expected * ones(size(actual));
end
delta = max(abs(actual(:) - expected(:)));
assert(delta <= tol, '%s mismatch: max |delta| %.3e > %.3e.', label, delta, tol);
end
