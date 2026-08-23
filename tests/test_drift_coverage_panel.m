% test_drift_coverage_panel
% WP-6: the receiver clock-drift +-3 sigma coverage is a computable diagnostic from the
% already-stored sigma + error series (revgnss.Plotter.driftCoverage). For the Cesium +
% Doppler default this documents a FUNDAMENTAL observability under-coverage (drift wander
% << Doppler resolution), not a filter bug. This turns the qualitative claim into a
% measured baseline and asserts the metric is well-formed.

thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..'));
addpath(fullfile(thisDir, '..', 'config'));

fprintf('=== test_drift_coverage_panel ===\n');

cfg = masterConfig();
cfg.report.writePdf = false; cfg.report.writeMat = false;
cfg.report.compileTex = 'never'; cfg.plots.showFigures = false;
cfg.simulation.duration_s = 200;
cfg.scenario.nReceivers = 1;   % single antenna: fast; drift is a receiver-clock property

out = revgnss.ReportRunner.runSingle(cfg);
d_  = out.simData.getData();
driftErr = d_.error.clockDrift_mps(:)';

[coverPct, nrms, s3] = revgnss.Plotter.driftCoverage(d_, driftErr);
assert(~isempty(s3), 'WP-6: drift +-3 sigma series must be available from the stored sigma.');
assert(isfinite(coverPct) && coverPct >= 0 && coverPct <= 100, ...
    'WP-6: coverage must be a valid percentage (got %.3g).', coverPct);
assert(isfinite(nrms) && nrms > 0, ...
    'WP-6: normalised RMS must be finite and positive (got %.3g).', nrms);

fprintf('  drift +-3sigma coverage = %.1f%%, normalised RMS = %.2f (measured baseline)\n', ...
    coverPct, nrms);
fprintf('  PASS\n');
