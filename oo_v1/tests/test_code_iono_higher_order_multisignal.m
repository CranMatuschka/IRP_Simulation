% test_code_iono_higher_order_multisignal
%
% Verifies higher-order ionosphere survives the active code measurement path:
%   T1 raw L1/L2 rows carry signal-scaled ionoHO truth/model/sigma diagnostics.
%   T2 IF row ionoHO equals the signed alpha/beta combination of raw rows.
%   T3 IF R charges higher-order ionosphere only when the row carries that source.

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));

fprintf('=== test_code_iono_higher_order_multisignal ===\n');

cfgRaw = buildCfg_('dualFrequencyStacked');
[zRaw, hRaw, ~, RRaw, errRaw] = oneEpoch_(cfgRaw);
assert(~isempty(zRaw) && numel(zRaw) == errRaw.nPseudorange, 'T1 FAILED: raw rows missing.');
assert(isfield(errRaw.bySource.truth_m,'ionoHO'), 'T1 FAILED: raw truth ionoHO missing.');
assert(isfield(errRaw.bySource.model_m,'ionoHO'), 'T1 FAILED: raw model ionoHO missing.');
assert(isfield(errRaw.bySource.sigma_m,'ionoHO'), 'T1 FAILED: raw sigma ionoHO missing.');

nRows = errRaw.nPseudorange;
assert(mod(nRows,2) == 0, 'T1 FAILED: expected paired L1/L2 rows.');
nPairs = nRows / 2;
idx1 = 1:nPairs;
idx2 = nPairs+1:2*nPairs;
sigNames = errRaw.signalName_perMeas;
assert(all(strcmp(sigNames(idx1),'L1')) && all(strcmp(sigNames(idx2),'L2')), ...
    'T1 FAILED: raw signal labels are not stacked L1 then L2.');

f1 = revgnss.SignalDefinition.get('L1').frequency_Hz;
f2 = revgnss.SignalDefinition.get('L2').frequency_Hz;
ho = cfgRaw.errors.ionosphere.higherOrder;
expectedL2 = models.errors.HigherOrderIonosphere.totalDelay( ...
    errRaw.bySource.truth_m.iono(idx1), f2, f1, ho);
assert(max(abs(errRaw.bySource.truth_m.ionoHO(idx2) - expectedL2)) < 1e-12, ...
    'T1 FAILED: L2 ionoHO is not frequency-scaled through the configured HO model.');
assert(any(abs(errRaw.bySource.truth_m.ionoHO(idx1)) > 0), ...
    'T1 FAILED: L1 ionoHO truth contribution is zero.');
assert(any(abs(errRaw.bySource.truth_m.ionoHO(idx2)) > abs(errRaw.bySource.truth_m.ionoHO(idx1))), ...
    'T1 FAILED: L2 ionoHO should exceed L1 for lower L2 frequency.');
assert(any(diag(RRaw) > 0) && all(isfinite(zRaw-hRaw)), 'T1 FAILED: raw R/residual invalid.');
fprintf('  T1 raw L1/L2 ionoHO truth/model/sigma diagnostics: PASS\n');

cfgIF = buildCfg_('ionosphereFree');
[~, ~, ~, RIF, errIF] = oneEpoch_(cfgIF);
assert(errIF.ifCombination, 'T2 FAILED: IF combination flag missing.');
assert(errIF.nPseudorange == nPairs, 'T2 FAILED: IF row count not one row per pair.');
assert(all(strcmp(errIF.signalName_perMeas,'IF')), 'T2 FAILED: IF signal labels missing.');
assert(isfield(errIF.bySource.truth_m,'ionoHO'), 'T2 FAILED: IF truth ionoHO missing.');
assert(isfield(errIF.bySource.sigma_m,'ionoHO'), 'T2 FAILED: IF sigma ionoHO missing.');

[alpha, beta] = revgnss.IonoFreeCombination.coefficients(f1, f2);
expectedIF = alpha * errRaw.bySource.truth_m.ionoHO(idx1) + ...
             beta  * errRaw.bySource.truth_m.ionoHO(idx2);
assert(max(abs(errIF.bySource.truth_m.ionoHO - expectedIF)) < 1e-10, ...
    'T2 FAILED: IF ionoHO truth is not alpha*L1 + beta*L2.');
assert(max(abs(errIF.bySource.sigma_m.ionoHO - abs(expectedIF))) < 1e-10, ...
    'T2 FAILED: IF ionoHO sigma is not the correlated signed-source magnitude.');

truthSum = zeros(size(errIF.truthTotal_m));
modelSum = zeros(size(errIF.modelTotal_m));
for k = 1:numel(errIF.labels)
    lbl = errIF.labels{k};
    truthSum = truthSum + errIF.bySource.truth_m.(lbl);
    modelSum = modelSum + errIF.bySource.model_m.(lbl);
end
assert(norm(truthSum - errIF.truthTotal_m) < 1e-9, ...
    'T2 FAILED: IF truth source sum does not reconstruct truthTotal.');
assert(norm(modelSum - errIF.modelTotal_m) < 1e-9, ...
    'T2 FAILED: IF model source sum does not reconstruct modelTotal.');
fprintf('  T2 IF ionoHO signed combination and totals: PASS\n');

assert(all(diag(RIF) >= errIF.bySource.sigma_m.ionoHO.^2), ...
    'T3 FAILED: IF R diagonal is smaller than ionoHO variance contribution.');
assert(all(errIF.bySource.sigma_m.ionoHO > 0) && all(abs(errIF.bySource.truth_m.ionoHO) > 0), ...
    'T3 FAILED: IF R charges ionoHO without an active row source.');
fprintf('  T3 IF R charges only active ionoHO source rows: PASS\n');

fprintf('=== test_code_iono_higher_order_multisignal: ALL PASS ===\n');

function cfg = buildCfg_(codeMode)
cfg = revgnss.ConfigFactory.defaultConfig();
cfg.signals.names = {'L1','L2'};
cfg.signals.enabledMask = [true,true];
cfg.signals.enabled = {'L1','L2'};
cfg.measurements.codeMode = codeMode;
cfg.measurements.observableMode = 'code';
cfg.measurements.doppler.enable = false;
cfg.measurements.doppler.useInEKF = false;
cfg.errors.troposphere.truth.enable = false;
cfg.errors.troposphere.model.enable = false;
cfg.errors.ionosphere.truth.enable = true;
cfg.errors.ionosphere.model.enable = false;
cfg.errors.ionosphere.truth.verticalDelayL1_m = 8.0;
cfg.errors.ionosphere.truth.zenithDelay_m = 8.0;
cfg.errors.ionosphere.higherOrder.enable = true;
cfg.errors.ionosphere.higherOrder.secondOrderFractionL1 = 0.004;
cfg.errors.ionosphere.higherOrder.secondOrderCap_m = 0.08;
cfg.errors.ionosphere.higherOrder.thirdOrderCoeff_perm = 7e-5;
cfg.errors.ionosphere.higherOrder.thirdOrderCap_m = 0.008;
cfg.errors.ionosphere.scintillation.enable = false;
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
