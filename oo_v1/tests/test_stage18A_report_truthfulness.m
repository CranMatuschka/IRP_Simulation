% test_stage18A_report_truthfulness
%
% Stage 18A: the LaTeX report must reflect the actual model state.

thisDir = fileparts(mfilename('fullpath'));
rootDir = fullfile(thisDir, '..');
addpath(rootDir);

fprintf('=== test_stage18A_report_truthfulness ===\n');

outDir = fullfile(rootDir, 'output', 'stage18A_report_truthfulness');
if ~exist(outDir, 'dir'); mkdir(outDir); end

% ----------------------------------------------------------------
% T1: report source contains actual model reality and attitude plots
% ----------------------------------------------------------------
fprintf('  T1: generated report source is consistent with active model ...\n');
cfg1 = mkCfg_(rootDir, outDir);
w1 = warning('off','all');
out1 = revgnss.ReportRunner.runSingle(cfg1);
warning(w1);
tex1 = fileread(out1.texPath);

assert(contains(tex1, 'Model Reality Check'), ...
    'T1 FAILED: Model Reality Check section missing');
assert(contains(tex1, 'Reverse-GNSS Spacecraft Multi-Observable EKF Report'), ...
    'T1 FAILED: stale code-only report title still present');
assert(contains(tex1, 'Attitude Error Components: Roll, Pitch, Yaw'), ...
    'T1 FAILED: attitude component plot row missing');
assert(contains(tex1, '3D Attitude Error Norm'), ...
    'T1 FAILED: attitude norm plot row missing');
assert(contains(tex1, 'Attitude Covariance Sigma'), ...
    'T1 FAILED: attitude covariance plot row missing');
assert(contains(tex1, 'B_{\phi,L1,t3,r2}'), ...
    'T1 FAILED: receiver-indexed ambiguity labels missing');
assert(~contains(tex1, 'B_{\phi,\mathrm{twr}'), ...
    'T1 FAILED: stale tower-only ambiguity labels present');
assert(~contains(tex1, 'Carrier phase is computed but not fed into the EKF'), ...
    'T1 FAILED: carrier diagnostic-only text contradicts ekfFloat mode');
assert(contains(tex1, 'Independent Attitude Candidate Search'), ...
    'T1 FAILED: independent attitude candidate section missing');
assert(contains(tex1, 'Accepted by main EKF'), ...
    'T1 FAILED: attitude acceptance decision missing');
assert(contains(tex1, 'Carrier generated / used in EKF / diagnostic only'), ...
    'T1 FAILED: carrier status reality row missing');
assert(isfile(fullfile(fileparts(out1.texPath), 'figures', 'oo_v1_GEO_1_attitude_components.pdf')), ...
    'T1 FAILED: attitude component figure not written');
fprintf('    PASS\n');

% ----------------------------------------------------------------
% T2: report builder rejects contradictory carrier status summaries
% ----------------------------------------------------------------
fprintf('  T2: contradictory carrier status fails before PDF generation ...\n');
badSummary = out1.summary;
badSummary.carrierUsedInEkf = false;
badSummary.totalCarrierRows = 0;
didThrow = false;
try
    revgnss.ClockExactReportBuilder.build(out1.diag, out1.sim.asset, ...
        out1.sim.towers, out1.cfg, badSummary);
catch ME
    didThrow = contains(ME.identifier, 'carrierStatusContradiction');
end
assert(didThrow, 'T2 FAILED: carrier contradiction was not rejected');
fprintf('    PASS\n');

% ----------------------------------------------------------------
% T3: ambiguity-state count follows tower x receiver indexing
% ----------------------------------------------------------------
fprintf('  T3: receiver-indexed ambiguity count is exposed ...\n');
expectedAmb = out1.cfg.scenario.nTowers * out1.cfg.scenario.nReceivers;
assert(out1.summary.nAmbiguityStates == expectedAmb, ...
    'T3 FAILED: nAmbiguityStates=%d expected=%d', ...
    out1.summary.nAmbiguityStates, expectedAmb);
assert(out1.summary.nStates == 14 + expectedAmb, ...
    'T3 FAILED: nStates=%d expected=%d', out1.summary.nStates, 14 + expectedAmb);
fprintf('    PASS (nStates=%d, nAmb=%d)\n', out1.summary.nStates, out1.summary.nAmbiguityStates);

fprintf('=== test_stage18A_report_truthfulness: ALL PASS ===\n');

function cfg = mkCfg_(rootDir, outDir)
    cfg = revgnss.ConfigFactory.defaultConfig();
    cfg.scenario.nReceivers = 3;
    cfg.simulation.duration_s = 20;
    cfg.simulation.dt_s = 1;
    cfg.signals.twoFrequency.enable = false;
    cfg.measurements.doppler.enable = true;
    cfg.measurements.doppler.useInEKF = true;
    cfg.physics.doppler.truth.enable = true;
    cfg.physics.doppler.model.enable = true;
    cfg.measurements.carrierPhase.enable = true;
    cfg.measurements.carrierMode = 'ekfFloat';
    cfg.measurements.carrier.sigma_m = 0.002;
    cfg.estimation.ambiguityMode = 'floatPerTowerReceiverSignal';
    cfg.estimation.ambiguity.initialSigma_m = 100;
    cfg.measurements.carrier.slipDetection.enable = true;
    cfg.measurements.carrier.slipDetection.threshold_m = 0.1;
    cfg.measurements.carrier.slipDetection.minEpochsBeforeDetect = 3;
    cfg.measurements.carrier.slipDetection.action = 'resetAndSkip';
    cfg.estimation.troposphereMode = 'none';
    cfg.estimator.attitudeCarrierMode = 'calibratedDifferentialAmbiguity';
    cfg.estimator.diffAtt.calibWin_s = 5;
    cfg.estimator.attitudeInitMode = 'coarseBaselineIntegerSearch';
    cfg.estimator.attitudeInit.search.windowDeg = [1; 1; 1];
    cfg.estimator.attitudeInit.search.stepDeg = [1; 1; 1];
    cfg.estimator.attitudeInit.search.maxCandidates = 27;
    cfg.estimator.attitudeInit.search.ratioThreshold = 1.20;
    cfg.estimator.attitudeInitShadow.enable = false;
    cfg.plots.enable = false;
    cfg.report.enable = true;
    cfg.report.writePdf = true;
    cfg.report.writeMat = false;
    cfg.report.writeTex = true;
    cfg.report.compileTex = 'never';
    cfg.report.style = 'latex';
    cfg.report.layout = 'clockExact';
    cfg.report.version = 'stage18A-test';
    cfg.report.baseOutputDir = outDir;
    cfg.report.overwrite = true;
    cfg.validation.unsupportedFeaturePolicy = 'disableWithWarning';
    addpath(rootDir);
end
