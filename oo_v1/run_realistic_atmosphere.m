% run_realistic_atmosphere  Run the single-asset scenario with the physically-realistic
% atmosphere (non-cancelling troposphere/ionosphere truth-model residuals).
%
% This overlays realisticAtmosphereConfig on the canonical masterConfig, so the
% troposphere and ionosphere produce physically-sized residuals (cm-level wet delay,
% Klobuchar/second-order ionosphere) instead of the matched synthetic models whose
% residual cancels to zero. The Stage-85 golden default is unaffected -- this is a
% separate opt-in scenario. Produces the usual PDF/MAT report under output/.

addpath(genpath(fileparts(mfilename('fullpath'))));

cfg = masterConfig();
cfg = realisticAtmosphereConfig(cfg);

fprintf('Running realistic-atmosphere scenario (localWeatherGM + tecGaussMarkov/Klobuchar)...\n');
out = revgnss.ReportRunner.runSingle(cfg);
fprintf('Done. Report summary position RMS (last 20%%): %.3f m\n', ...
    out.summary.positionRmsLast20_m);
