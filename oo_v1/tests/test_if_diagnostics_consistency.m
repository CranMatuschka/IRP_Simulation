% test_if_diagnostics_consistency
% Two IF (ionosphere-free) diagnostic fixes:
%   A. Postfit residuals must not exceed the prefit (a consistent KF update reduces the
%      innovation). Previously the postfit recompute did not re-apply the IF combination,
%      so it subtracted a single-frequency-model h (with the model ionosphere) from an
%      IF-combined z, inflating the postfit above the prefit.
%   B. codeResidualRms57_m must be finite under codeMode='ionosphereFree' (its rows are
%      tagged 'ifCode'; the reported code residual now covers raw + IF code rows).

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));
addpath(fullfile(thisDir, '..', 'config'));

fprintf('=== test_if_diagnostics_consistency ===\n');

cfg = realisticAtmosphereConfig(masterConfig());
cfg.measurements.codeMode = 'ionosphereFree';
cfg.simulation.duration_s = 300;
cfg.estimator.runKnownAmbiguityValidation = false;
cfg.report.writePdf = false; cfg.report.writeMat = false; cfg.report.compileTex = 'never';
cfg.plots.showFigures = false;

s = struct();
outTxt = evalc("out = revgnss.ReportRunner.runSingle(cfg); s = out.summary;"); %#ok<NASGU>

% A. Postfit consistency: postfit must not blow up above prefit (allow small FP margin).
assert(isfinite(s.finalPrefitRMS_m) && isfinite(s.finalPostfitRMS_m), 'prefit/postfit must be finite');
assert(s.finalPostfitRMS_m <= s.finalPrefitRMS_m * 1.05 + 1e-6, ...
    'IF postfit (%.3f) must not exceed prefit (%.3f) — postfit recompute must re-apply IF', ...
    s.finalPostfitRMS_m, s.finalPrefitRMS_m);

% B. Code residual must be finite under IF (rows are 'ifCode').
assert(isfinite(s.codeResidualRms57_m) && s.codeResidualRms57_m > 0, ...
    'codeResidualRms57_m must be finite under ionosphereFree, got %g', s.codeResidualRms57_m);

% Confirm this run actually used the IF path
assert(s.codeIonoFreeRowsUsedInEkf == true || s.totalCodeIonoFreeRows > 0, ...
    'sanity: this scenario should exercise the IF code path');

fprintf('  IF prefit=%.3f postfit=%.3f (postfit<=prefit) | codeResid=%.3f m (finite)\n', ...
    s.finalPrefitRMS_m, s.finalPostfitRMS_m, s.codeResidualRms57_m);
fprintf('  PASS\n');
